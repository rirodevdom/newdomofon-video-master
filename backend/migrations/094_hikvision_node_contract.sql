BEGIN;

-- The master stores Hikvision devices and synchronized metadata, but never runs
-- ISAPI requests or Hikvision Digest authentication itself.
DO $$
DECLARE constraint_name text;
BEGIN
  FOR constraint_name IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'public.devices'::regclass
       AND contype = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%connection_type%'
  LOOP
    EXECUTE format('ALTER TABLE public.devices DROP CONSTRAINT %I', constraint_name);
  END LOOP;
  ALTER TABLE public.devices
    ADD CONSTRAINT devices_connection_type_check
    CHECK (connection_type IN ('RTSP', 'ONVIF', 'HIKVISION'));
END $$;

ALTER TABLE public.devices ADD COLUMN IF NOT EXISTS isapi_scheme text NOT NULL DEFAULT 'http';
ALTER TABLE public.devices ADD COLUMN IF NOT EXISTS rtsp_port integer NOT NULL DEFAULT 554;
ALTER TABLE public.devices ADD COLUMN IF NOT EXISTS retention_days integer NOT NULL DEFAULT 30;
ALTER TABLE public.devices ADD COLUMN IF NOT EXISTS reject_unauthorized_tls boolean NOT NULL DEFAULT true;
ALTER TABLE public.devices ADD COLUMN IF NOT EXISTS hikvision_channel_overrides jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.devices DROP CONSTRAINT IF EXISTS devices_archive_storage_check;
ALTER TABLE public.devices ADD CONSTRAINT devices_archive_storage_check CHECK (archive_storage IN ('node', 'device'));
ALTER TABLE public.cameras DROP CONSTRAINT IF EXISTS cameras_archive_storage_check;
ALTER TABLE public.cameras ADD CONSTRAINT cameras_archive_storage_check CHECK (archive_storage IN ('node', 'device'));

CREATE TABLE IF NOT EXISTS public.hikvision_node_channels (
  device_id uuid NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
  dvr_server_id uuid NOT NULL REFERENCES public.dvr_servers(id) ON DELETE CASCADE,
  channel_external_id text NOT NULL,
  physical_channel integer NOT NULL,
  name text NOT NULL,
  online boolean,
  enabled boolean NOT NULL DEFAULT true,
  primary_stream_id text NOT NULL,
  archive_storage text NOT NULL CHECK (archive_storage IN ('node', 'device')),
  retention_days integer NOT NULL DEFAULT 30,
  streams jsonb NOT NULL DEFAULT '[]'::jsonb,
  device_info jsonb NOT NULL DEFAULT '{}'::jsonb,
  capabilities jsonb NOT NULL DEFAULT '{}'::jsonb,
  discovered_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (device_id, channel_external_id)
);

CREATE INDEX IF NOT EXISTS hikvision_node_channels_node_idx
  ON public.hikvision_node_channels(dvr_server_id, device_id, physical_channel);

COMMIT;

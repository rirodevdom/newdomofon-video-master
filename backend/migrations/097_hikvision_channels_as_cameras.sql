BEGIN;

-- Hikvision discovery remains vendor-specific, but every discovered channel is
-- represented by a canonical master camera. This lets groups, favorites,
-- managed tokens, links and the ordinary camera UI use the same camera UUIDs
-- regardless of the media transport behind the device.
ALTER TABLE public.hikvision_node_channels
  ADD COLUMN IF NOT EXISTS camera_id uuid REFERENCES public.cameras(id) ON DELETE CASCADE;

CREATE UNIQUE INDEX IF NOT EXISTS uq_hikvision_node_channels_camera_id
  ON public.hikvision_node_channels(camera_id)
  WHERE camera_id IS NOT NULL;

-- Backfill all already discovered channels. The stream name is deterministic
-- and is the same name used by the SmartYard Hikvision compatibility gateway.
INSERT INTO public.cameras(
  name,
  stream_name,
  source_url,
  dvr_server_id,
  device_id,
  archive_storage,
  retention_days,
  is_enabled
)
SELECT
  COALESCE(NULLIF(h.name, ''), d.name || ' · ' || h.physical_channel::text),
  'hik_' || lower(replace(h.device_id::text, '-', '')) || '_' || h.physical_channel::text,
  'hikvision://' || h.channel_external_id,
  h.dvr_server_id,
  h.device_id,
  h.archive_storage,
  h.retention_days,
  h.enabled AND d.is_enabled
FROM public.hikvision_node_channels h
JOIN public.devices d ON d.id = h.device_id
WHERE h.camera_id IS NULL
ON CONFLICT (stream_name) DO NOTHING;

UPDATE public.hikvision_node_channels h
   SET camera_id = c.id,
       updated_at = now()
  FROM public.cameras c
 WHERE h.camera_id IS NULL
   AND c.device_id = h.device_id
   AND c.stream_name = (
     'hik_' || lower(replace(h.device_id::text, '-', '')) || '_' || h.physical_channel::text
   );

CREATE INDEX IF NOT EXISTS hikvision_node_channels_camera_lookup_idx
  ON public.hikvision_node_channels(camera_id, channel_external_id);

COMMIT;

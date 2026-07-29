BEGIN;

-- Preserve existing cameras and RTSP source URLs while removing the vendor-specific
-- runtime type. The future Hikvision node will use a separate service contract.
UPDATE public.devices
   SET connection_type = 'RTSP'
 WHERE connection_type = 'HIKVISION';

-- Generic video nodes own only their local archive.
UPDATE public.devices
   SET archive_storage = 'node'
 WHERE archive_storage IS DISTINCT FROM 'node';

UPDATE public.cameras
   SET archive_storage = 'node'
 WHERE archive_storage IS DISTINCT FROM 'node';

DO $$
DECLARE
  constraint_name text;
BEGIN
  FOR constraint_name IN
    SELECT conname
      FROM pg_constraint
     WHERE conrelid = 'public.devices'::regclass
       AND contype = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%connection_type%'
  LOOP
    EXECUTE format('ALTER TABLE public.devices DROP CONSTRAINT %I', constraint_name);
  END LOOP;

  ALTER TABLE public.devices
    ADD CONSTRAINT devices_connection_type_check
    CHECK (connection_type IN ('RTSP', 'ONVIF'));
END $$;

ALTER TABLE public.devices
  DROP CONSTRAINT IF EXISTS devices_archive_storage_check;
ALTER TABLE public.devices
  ADD CONSTRAINT devices_archive_storage_check
  CHECK (archive_storage = 'node');

ALTER TABLE public.cameras
  DROP CONSTRAINT IF EXISTS cameras_archive_storage_check;
ALTER TABLE public.cameras
  ADD CONSTRAINT cameras_archive_storage_check
  CHECK (archive_storage = 'node');

-- Drop only derived ISAPI indexes. Camera/device rows and their RTSP URLs remain.
DROP TABLE IF EXISTS public.device_archive_sync_state CASCADE;
DROP TABLE IF EXISTS public.device_archive_segments CASCADE;

COMMIT;

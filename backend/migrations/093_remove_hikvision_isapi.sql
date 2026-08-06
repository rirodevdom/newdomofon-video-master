BEGIN;

-- This migration belongs to the legacy transition away from the master-side
-- Hikvision/ISAPI runtime. The current architecture reintroduced HIKVISION as a
-- master-owned configuration type backed by hikvision_node_channels in migration
-- 094. Our migration runner is intentionally idempotent and can execute migration
-- files again during archive updates, so the destructive legacy conversion must
-- never run once the modern Hikvision node contract already exists.
DO $$
DECLARE
  constraint_name text;
BEGIN
  IF to_regclass('public.hikvision_node_channels') IS NOT NULL THEN
    RAISE NOTICE 'Modern Hikvision node contract detected; skipping legacy ISAPI teardown';
    RETURN;
  END IF;

  -- Preserve existing cameras and RTSP source URLs while removing the old
  -- vendor-specific runtime type on a genuinely legacy schema only.
  UPDATE public.devices
     SET connection_type = 'RTSP'
   WHERE connection_type = 'HIKVISION';

  -- Generic video nodes owned only their local archive in the legacy schema.
  UPDATE public.devices
     SET archive_storage = 'node'
   WHERE archive_storage IS DISTINCT FROM 'node';

  UPDATE public.cameras
     SET archive_storage = 'node'
   WHERE archive_storage IS DISTINCT FROM 'node';

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

  -- Drop only derived ISAPI indexes/tables on the legacy transition. Camera and
  -- device rows and their RTSP URLs are intentionally retained.
  DROP TABLE IF EXISTS public.device_archive_sync_state CASCADE;
  DROP TABLE IF EXISTS public.device_archive_segments CASCADE;
END $$;

COMMIT;

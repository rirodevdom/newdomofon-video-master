-- Camera placement and archive policy are owned by the parent device.
-- Managed-token assignments remain single-current-token per camera.

UPDATE cameras AS camera
   SET dvr_server_id = device.dvr_server_id,
       archive_storage = device.archive_storage
  FROM devices AS device
 WHERE camera.device_id = device.id
   AND (
     camera.dvr_server_id IS DISTINCT FROM device.dvr_server_id
     OR camera.archive_storage IS DISTINCT FROM device.archive_storage
   );

CREATE OR REPLACE FUNCTION inherit_camera_placement_from_device()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  placement devices%ROWTYPE;
BEGIN
  SELECT *
    INTO placement
    FROM devices
   WHERE id = NEW.device_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Camera device % does not exist', NEW.device_id
      USING ERRCODE = '23503';
  END IF;

  NEW.dvr_server_id := placement.dvr_server_id;
  NEW.archive_storage := placement.archive_storage;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cameras_inherit_device_placement ON cameras;
CREATE TRIGGER trg_cameras_inherit_device_placement
BEFORE INSERT OR UPDATE OF device_id, dvr_server_id, archive_storage
ON cameras
FOR EACH ROW
EXECUTE FUNCTION inherit_camera_placement_from_device();

CREATE OR REPLACE FUNCTION synchronize_device_camera_placement()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.dvr_server_id IS DISTINCT FROM OLD.dvr_server_id
     OR NEW.archive_storage IS DISTINCT FROM OLD.archive_storage THEN
    UPDATE cameras
       SET dvr_server_id = NEW.dvr_server_id,
           archive_storage = NEW.archive_storage
     WHERE device_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_devices_sync_camera_placement ON devices;
CREATE TRIGGER trg_devices_sync_camera_placement
AFTER UPDATE OF dvr_server_id, archive_storage
ON devices
FOR EACH ROW
EXECUTE FUNCTION synchronize_device_camera_placement();

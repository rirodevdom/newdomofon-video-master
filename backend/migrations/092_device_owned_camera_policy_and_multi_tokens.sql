-- Cameras inherit their node and archive policy from the parent device.
-- Managed tokens return to the original many-to-many model.

DROP INDEX IF EXISTS uq_managed_camera_token_cameras_camera_id;

UPDATE cameras c
   SET dvr_server_id = d.dvr_server_id,
       archive_storage = d.archive_storage
  FROM devices d
 WHERE d.id = c.device_id
   AND (c.dvr_server_id IS DISTINCT FROM d.dvr_server_id
        OR c.archive_storage IS DISTINCT FROM d.archive_storage);

CREATE OR REPLACE FUNCTION enforce_camera_device_policy()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  parent_node uuid;
  parent_archive text;
BEGIN
  SELECT dvr_server_id, archive_storage
    INTO parent_node, parent_archive
    FROM devices
   WHERE id = NEW.device_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Camera device % does not exist', NEW.device_id
      USING ERRCODE = '23503';
  END IF;

  NEW.dvr_server_id := parent_node;
  NEW.archive_storage := parent_archive;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_camera_device_policy ON cameras;
CREATE TRIGGER trg_enforce_camera_device_policy
BEFORE INSERT OR UPDATE OF device_id, dvr_server_id, archive_storage
ON cameras
FOR EACH ROW
EXECUTE FUNCTION enforce_camera_device_policy();

CREATE OR REPLACE FUNCTION propagate_device_camera_policy()
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

DROP TRIGGER IF EXISTS trg_propagate_device_camera_policy ON devices;
CREATE TRIGGER trg_propagate_device_camera_policy
AFTER UPDATE OF dvr_server_id, archive_storage
ON devices
FOR EACH ROW
EXECUTE FUNCTION propagate_device_camera_policy();

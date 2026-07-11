-- Camera placement and archive policy are owned by the parent device.
-- Restore many-to-many managed-token assignments and normalize existing cameras.

DROP INDEX IF EXISTS uq_managed_camera_token_cameras_camera_id;

UPDATE cameras AS camera
   SET dvr_server_id = device.dvr_server_id,
       archive_storage = device.archive_storage
  FROM devices AS device
 WHERE camera.device_id = device.id
   AND (
     camera.dvr_server_id IS DISTINCT FROM device.dvr_server_id
     OR camera.archive_storage IS DISTINCT FROM device.archive_storage
   );

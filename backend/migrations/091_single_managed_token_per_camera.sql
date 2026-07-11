-- A camera has one current managed token. Existing installations may contain
-- several rows because the original link endpoint only inserted assignments.
-- Keep the most recently created assignment before adding the invariant.
WITH ranked_assignments AS (
  SELECT token_id,
         camera_id,
         row_number() OVER (
           PARTITION BY camera_id
           ORDER BY created_at DESC, token_id DESC
         ) AS row_number
    FROM managed_camera_token_cameras
)
DELETE FROM managed_camera_token_cameras assignment
 USING ranked_assignments ranked
 WHERE assignment.token_id = ranked.token_id
   AND assignment.camera_id = ranked.camera_id
   AND ranked.row_number > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uq_managed_camera_token_cameras_camera_id
  ON managed_camera_token_cameras (camera_id);

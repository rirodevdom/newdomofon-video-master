-- Managed camera token assignments are many-to-many.
-- This migration used to delete all but one token per camera and create a
-- unique camera_id index. Migrations are replayed on every deploy, so keeping
-- that behaviour would repeatedly destroy valid user token assignments.

DROP INDEX IF EXISTS uq_managed_camera_token_cameras_camera_id;

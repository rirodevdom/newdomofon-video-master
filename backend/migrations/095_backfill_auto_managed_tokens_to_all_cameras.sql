-- Auto-assignment now means "all cameras": when a user-managed token is
-- created with auto assignment enabled, or later switched into that state,
-- attach it to every camera that already exists. The camera INSERT trigger from
-- migration 094 continues to attach eligible automatic tokens to future cameras.
--
-- Automatic assignments are infrastructure-owned, so created_by stays NULL.
-- Existing assignments are preserved and duplicate pairs are ignored.

CREATE OR REPLACE FUNCTION backfill_auto_managed_token_to_existing_cameras()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.id = '00000000-0000-4000-8000-000000000001'::uuid THEN
    RETURN NEW;
  END IF;

  IF NEW.auto_assign_new_cameras = true
     AND NEW.is_active = true
     AND (NEW.expires_at IS NULL OR NEW.expires_at > now())
     AND NEW.scopes @> ARRAY['camera']::text[]
  THEN
    INSERT INTO managed_camera_token_cameras(token_id, camera_id, created_by, created_at)
    SELECT NEW.id,
           camera.id,
           NULL,
           now()
      FROM cameras camera
    ON CONFLICT (token_id, camera_id) DO NOTHING;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_managed_camera_tokens_backfill_auto_assign
  ON managed_camera_tokens;

CREATE TRIGGER trg_managed_camera_tokens_backfill_auto_assign
AFTER INSERT OR UPDATE OF auto_assign_new_cameras, is_active, expires_at, scopes
ON managed_camera_tokens
FOR EACH ROW
EXECUTE FUNCTION backfill_auto_managed_token_to_existing_cameras();

-- Bring installations that already contain automatic tokens into the new
-- invariant immediately when this migration is deployed.
INSERT INTO managed_camera_token_cameras(token_id, camera_id, created_by, created_at)
SELECT token.id,
       camera.id,
       NULL,
       now()
  FROM managed_camera_tokens token
 CROSS JOIN cameras camera
 WHERE token.id <> '00000000-0000-4000-8000-000000000001'::uuid
   AND token.auto_assign_new_cameras = true
   AND token.is_active = true
   AND (token.expires_at IS NULL OR token.expires_at > now())
   AND token.scopes @> ARRAY['camera']::text[]
ON CONFLICT (token_id, camera_id) DO NOTHING;

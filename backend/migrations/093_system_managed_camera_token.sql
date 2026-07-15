-- One camera has exactly one current managed token.
-- A protected system token is created automatically and is used only as a
-- fallback when an administrator did not select a custom token.

DO $$
DECLARE
  system_token_id constant uuid := '00000000-0000-4000-8000-000000000001'::uuid;
BEGIN
  INSERT INTO managed_camera_tokens(
    id, name, description, generation, scopes, is_active, expires_at, created_by
  ) VALUES (
    system_token_id,
    'Внутренний системный токен',
    'Автоматический бессрочный токен для камер без выбранного пользовательского токена.',
    1,
    ARRAY['camera', 'events']::text[],
    true,
    NULL,
    NULL
  )
  ON CONFLICT (id) DO UPDATE
     SET name = EXCLUDED.name,
         description = EXCLUDED.description,
         scopes = EXCLUDED.scopes,
         is_active = true,
         expires_at = NULL;
END $$;

-- Keep one existing assignment per camera. Prefer a custom token over the
-- system fallback, then keep the newest assignment.
WITH ranked_assignments AS (
  SELECT token_id,
         camera_id,
         row_number() OVER (
           PARTITION BY camera_id
           ORDER BY
             CASE WHEN token_id = '00000000-0000-4000-8000-000000000001'::uuid THEN 1 ELSE 0 END,
             created_at DESC,
             token_id DESC
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

-- Existing cameras without an assignment receive the system fallback.
INSERT INTO managed_camera_token_cameras(token_id, camera_id, created_by, created_at)
SELECT '00000000-0000-4000-8000-000000000001'::uuid,
       camera.id,
       NULL,
       now()
  FROM cameras camera
 WHERE NOT EXISTS (
   SELECT 1
     FROM managed_camera_token_cameras assignment
    WHERE assignment.camera_id = camera.id
 )
ON CONFLICT (camera_id) DO NOTHING;

CREATE OR REPLACE FUNCTION assign_system_managed_token_to_new_camera()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO managed_camera_token_cameras(token_id, camera_id, created_by, created_at)
  VALUES ('00000000-0000-4000-8000-000000000001'::uuid, NEW.id, NULL, now())
  ON CONFLICT (camera_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cameras_assign_system_managed_token ON cameras;
CREATE TRIGGER trg_cameras_assign_system_managed_token
AFTER INSERT ON cameras
FOR EACH ROW
EXECUTE FUNCTION assign_system_managed_token_to_new_camera();

-- The existing API inserts a new assignment. Convert that insert into a
-- replacement so a selected custom token immediately becomes the only current
-- token of the camera.
CREATE OR REPLACE FUNCTION replace_current_managed_camera_token()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('newdomofon.managed_token_replacement', '1', true);

  DELETE FROM managed_camera_token_cameras
   WHERE camera_id = NEW.camera_id
     AND token_id <> NEW.token_id;

  PERFORM set_config('newdomofon.managed_token_replacement', '0', true);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_managed_camera_token_replace_current
  ON managed_camera_token_cameras;
CREATE TRIGGER trg_managed_camera_token_replace_current
BEFORE INSERT ON managed_camera_token_cameras
FOR EACH ROW
EXECUTE FUNCTION replace_current_managed_camera_token();

-- Mark camera deletion so the assignment fallback trigger does not recreate a
-- row that is being removed by ON DELETE CASCADE.
CREATE OR REPLACE FUNCTION mark_camera_delete_for_managed_token_cleanup()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('newdomofon.camera_delete_in_progress', OLD.id::text, true);
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_cameras_mark_managed_token_delete ON cameras;
CREATE TRIGGER trg_cameras_mark_managed_token_delete
BEFORE DELETE ON cameras
FOR EACH ROW
EXECUTE FUNCTION mark_camera_delete_for_managed_token_cleanup();

-- Detaching or deleting a custom token restores the system fallback. Deletes
-- performed internally by the replacement trigger or by camera cascade are
-- intentionally ignored.
CREATE OR REPLACE FUNCTION restore_system_managed_camera_token_after_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_setting('newdomofon.managed_token_replacement', true) = '1' THEN
    RETURN OLD;
  END IF;

  IF current_setting('newdomofon.camera_delete_in_progress', true) = OLD.camera_id::text THEN
    RETURN OLD;
  END IF;

  IF EXISTS (SELECT 1 FROM cameras WHERE id = OLD.camera_id) THEN
    INSERT INTO managed_camera_token_cameras(token_id, camera_id, created_by, created_at)
    VALUES ('00000000-0000-4000-8000-000000000001'::uuid, OLD.camera_id, NULL, now())
    ON CONFLICT (camera_id) DO NOTHING;
  END IF;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_managed_camera_token_restore_system
  ON managed_camera_token_cameras;
CREATE TRIGGER trg_managed_camera_token_restore_system
AFTER DELETE ON managed_camera_token_cameras
FOR EACH ROW
EXECUTE FUNCTION restore_system_managed_camera_token_after_delete();

-- The system token is infrastructure state. It must remain active, permanent
-- and stable so links generated from it survive application restarts.
CREATE OR REPLACE FUNCTION protect_system_managed_camera_token()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.id = '00000000-0000-4000-8000-000000000001'::uuid THEN
      RAISE EXCEPTION 'The internal system managed token cannot be deleted'
        USING ERRCODE = '55000';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.id = '00000000-0000-4000-8000-000000000001'::uuid AND (
       NEW.name IS DISTINCT FROM 'Внутренний системный токен'
       OR NEW.generation IS DISTINCT FROM OLD.generation
       OR NEW.scopes IS DISTINCT FROM ARRAY['camera', 'events']::text[]
       OR NEW.is_active IS DISTINCT FROM true
       OR NEW.expires_at IS NOT NULL
     ) THEN
    RAISE EXCEPTION 'The internal system managed token cannot be changed or rotated'
      USING ERRCODE = '55000';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_managed_camera_tokens_protect_system
  ON managed_camera_tokens;
CREATE TRIGGER trg_managed_camera_tokens_protect_system
BEFORE UPDATE OR DELETE ON managed_camera_tokens
FOR EACH ROW
EXECUTE FUNCTION protect_system_managed_camera_token();

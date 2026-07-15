-- Keep the many-to-many relation between cameras and user-managed tokens.
-- The protected system token is a fallback only: it is present while a camera
-- has no user-managed tokens and is removed as soon as the first custom token
-- is attached.

DROP INDEX IF EXISTS uq_managed_camera_token_cameras_camera_id;

DO $$
DECLARE
  system_token_id constant uuid := '00000000-0000-4000-8000-000000000001'::uuid;
BEGIN
  INSERT INTO managed_camera_tokens(
    id, name, description, generation, scopes, is_active, expires_at, created_by
  ) VALUES (
    system_token_id,
    'Внутренний системный токен',
    'Автоматический бессрочный fallback для камер без пользовательских токенов.',
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

-- Disable older fallback/replacement triggers before normalizing an installation
-- where a previous revision of this migration may already have been applied.
DROP TRIGGER IF EXISTS trg_managed_camera_token_restore_system
  ON managed_camera_token_cameras;
DROP TRIGGER IF EXISTS trg_managed_camera_token_replace_current
  ON managed_camera_token_cameras;
DROP TRIGGER IF EXISTS trg_managed_camera_token_replace_system
  ON managed_camera_token_cameras;

-- Never keep the system fallback together with one or more custom tokens.
DELETE FROM managed_camera_token_cameras system_assignment
 WHERE system_assignment.token_id = '00000000-0000-4000-8000-000000000001'::uuid
   AND EXISTS (
     SELECT 1
       FROM managed_camera_token_cameras custom_assignment
      WHERE custom_assignment.camera_id = system_assignment.camera_id
        AND custom_assignment.token_id <> '00000000-0000-4000-8000-000000000001'::uuid
   );

-- Existing cameras without custom assignments receive the system fallback.
INSERT INTO managed_camera_token_cameras(token_id, camera_id, created_by, created_at)
SELECT '00000000-0000-4000-8000-000000000001'::uuid,
       camera.id,
       NULL,
       now()
  FROM cameras camera
 WHERE NOT EXISTS (
   SELECT 1
     FROM managed_camera_token_cameras custom_assignment
    WHERE custom_assignment.camera_id = camera.id
      AND custom_assignment.token_id <> '00000000-0000-4000-8000-000000000001'::uuid
 )
ON CONFLICT (token_id, camera_id) DO NOTHING;

CREATE OR REPLACE FUNCTION assign_system_managed_token_to_new_camera()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO managed_camera_token_cameras(token_id, camera_id, created_by, created_at)
  VALUES ('00000000-0000-4000-8000-000000000001'::uuid, NEW.id, NULL, now())
  ON CONFLICT (token_id, camera_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_cameras_assign_system_managed_token ON cameras;
CREATE TRIGGER trg_cameras_assign_system_managed_token
AFTER INSERT ON cameras
FOR EACH ROW
EXECUTE FUNCTION assign_system_managed_token_to_new_camera();

-- Custom tokens remain many-to-many. Attaching any custom token removes only
-- the system fallback; existing custom assignments stay untouched.
CREATE OR REPLACE FUNCTION replace_system_managed_camera_token()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.token_id = '00000000-0000-4000-8000-000000000001'::uuid THEN
    IF EXISTS (
      SELECT 1
        FROM managed_camera_token_cameras custom_assignment
       WHERE custom_assignment.camera_id = NEW.camera_id
         AND custom_assignment.token_id <> '00000000-0000-4000-8000-000000000001'::uuid
    ) THEN
      RAISE EXCEPTION 'System fallback cannot be attached while custom tokens exist'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  PERFORM set_config('newdomofon.system_token_replacement', '1', true);
  DELETE FROM managed_camera_token_cameras
   WHERE camera_id = NEW.camera_id
     AND token_id = '00000000-0000-4000-8000-000000000001'::uuid;
  PERFORM set_config('newdomofon.system_token_replacement', '0', true);

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_managed_camera_token_replace_system
BEFORE INSERT ON managed_camera_token_cameras
FOR EACH ROW
EXECUTE FUNCTION replace_system_managed_camera_token();

-- Mark camera deletion so assignment cascade does not recreate the fallback.
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

-- Removing the last custom token restores the system fallback. Removing one of
-- several custom tokens leaves all remaining custom assignments unchanged.
CREATE OR REPLACE FUNCTION restore_system_managed_camera_token_after_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_setting('newdomofon.system_token_replacement', true) = '1' THEN
    RETURN OLD;
  END IF;

  IF current_setting('newdomofon.camera_delete_in_progress', true) = OLD.camera_id::text THEN
    RETURN OLD;
  END IF;

  IF EXISTS (SELECT 1 FROM cameras WHERE id = OLD.camera_id)
     AND NOT EXISTS (
       SELECT 1
         FROM managed_camera_token_cameras custom_assignment
        WHERE custom_assignment.camera_id = OLD.camera_id
          AND custom_assignment.token_id <> '00000000-0000-4000-8000-000000000001'::uuid
     ) THEN
    INSERT INTO managed_camera_token_cameras(token_id, camera_id, created_by, created_at)
    VALUES ('00000000-0000-4000-8000-000000000001'::uuid, OLD.camera_id, NULL, now())
    ON CONFLICT (token_id, camera_id) DO NOTHING;
  END IF;

  RETURN OLD;
END;
$$;

CREATE TRIGGER trg_managed_camera_token_restore_system
AFTER DELETE ON managed_camera_token_cameras
FOR EACH ROW
EXECUTE FUNCTION restore_system_managed_camera_token_after_delete();

-- The fallback is infrastructure state. It remains active and permanent.
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

-- Extend managed camera tokens with two independent capabilities:
--   1. an administrator may choose the exact external token value;
--   2. a user-managed token may be assigned automatically to newly created cameras.
-- Manual values are never stored in plaintext. The backend stores an encrypted
-- value for administrative link generation and an HMAC digest for lookup.

ALTER TABLE managed_camera_tokens
  ADD COLUMN IF NOT EXISTS token_mode text NOT NULL DEFAULT 'generated';

ALTER TABLE managed_camera_tokens
  ADD COLUMN IF NOT EXISTS manual_token_ciphertext text;

ALTER TABLE managed_camera_tokens
  ADD COLUMN IF NOT EXISTS manual_token_digest text;

ALTER TABLE managed_camera_tokens
  ADD COLUMN IF NOT EXISTS auto_assign_new_cameras boolean NOT NULL DEFAULT false;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conname = 'managed_camera_tokens_mode_valid'
       AND conrelid = 'managed_camera_tokens'::regclass
  ) THEN
    ALTER TABLE managed_camera_tokens
      ADD CONSTRAINT managed_camera_tokens_mode_valid
      CHECK (token_mode IN ('generated', 'manual'));
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conname = 'managed_camera_tokens_manual_material_valid'
       AND conrelid = 'managed_camera_tokens'::regclass
  ) THEN
    ALTER TABLE managed_camera_tokens
      ADD CONSTRAINT managed_camera_tokens_manual_material_valid
      CHECK (
        (token_mode = 'generated' AND manual_token_ciphertext IS NULL AND manual_token_digest IS NULL)
        OR
        (token_mode = 'manual' AND manual_token_ciphertext IS NOT NULL AND manual_token_digest IS NOT NULL)
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint
     WHERE conname = 'managed_camera_tokens_auto_assign_requires_camera_scope'
       AND conrelid = 'managed_camera_tokens'::regclass
  ) THEN
    ALTER TABLE managed_camera_tokens
      ADD CONSTRAINT managed_camera_tokens_auto_assign_requires_camera_scope
      CHECK (NOT auto_assign_new_cameras OR scopes @> ARRAY['camera']::text[]);
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_managed_camera_tokens_manual_digest
  ON managed_camera_tokens (manual_token_digest)
  WHERE manual_token_digest IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_managed_camera_tokens_auto_assign
  ON managed_camera_tokens (auto_assign_new_cameras, is_active, expires_at)
  WHERE auto_assign_new_cameras = true;

-- The protected system token remains a special fallback. It is not represented
-- by the ordinary auto-assignment flag because it must only be present when no
-- active user-managed automatic token exists.
UPDATE managed_camera_tokens
   SET token_mode = 'generated',
       manual_token_ciphertext = NULL,
       manual_token_digest = NULL,
       auto_assign_new_cameras = false
 WHERE id = '00000000-0000-4000-8000-000000000001'::uuid;

-- Replace the function used by the existing camera AFTER INSERT trigger.
-- Every active, non-expired user token marked for automatic assignment is added.
-- If there are none, the protected system fallback is added instead.
CREATE OR REPLACE FUNCTION assign_system_managed_token_to_new_camera()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  assigned_count integer := 0;
BEGIN
  INSERT INTO managed_camera_token_cameras(token_id, camera_id, created_by, created_at)
  SELECT token.id,
         NEW.id,
         NULL,
         now()
    FROM managed_camera_tokens token
   WHERE token.id <> '00000000-0000-4000-8000-000000000001'::uuid
     AND token.auto_assign_new_cameras = true
     AND token.is_active = true
     AND (token.expires_at IS NULL OR token.expires_at > now())
     AND token.scopes @> ARRAY['camera']::text[]
  ON CONFLICT (token_id, camera_id) DO NOTHING;

  GET DIAGNOSTICS assigned_count = ROW_COUNT;

  IF assigned_count = 0 THEN
    INSERT INTO managed_camera_token_cameras(token_id, camera_id, created_by, created_at)
    VALUES ('00000000-0000-4000-8000-000000000001'::uuid, NEW.id, NULL, now())
    ON CONFLICT (token_id, camera_id) DO NOTHING;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS managed_camera_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  description text,
  generation integer NOT NULL DEFAULT 1 CHECK (generation >= 1),
  scopes text[] NOT NULL DEFAULT ARRAY['camera', 'events']::text[],
  is_active boolean NOT NULL DEFAULT true,
  expires_at timestamptz,
  created_by uuid REFERENCES users(id) ON DELETE SET NULL,
  last_used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT managed_camera_tokens_name_not_blank CHECK (length(btrim(name)) > 0),
  CONSTRAINT managed_camera_tokens_scopes_valid CHECK (
    cardinality(scopes) > 0
    AND scopes <@ ARRAY['camera', 'events']::text[]
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_managed_camera_tokens_name_lower
  ON managed_camera_tokens (lower(name));

CREATE INDEX IF NOT EXISTS idx_managed_camera_tokens_active
  ON managed_camera_tokens (is_active, expires_at);

CREATE TABLE IF NOT EXISTS managed_camera_token_cameras (
  token_id uuid NOT NULL REFERENCES managed_camera_tokens(id) ON DELETE CASCADE,
  camera_id uuid NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
  created_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (token_id, camera_id)
);

CREATE INDEX IF NOT EXISTS idx_managed_camera_token_cameras_camera
  ON managed_camera_token_cameras (camera_id, token_id);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_managed_camera_tokens_updated_at'
  ) THEN
    CREATE TRIGGER trg_managed_camera_tokens_updated_at
      BEFORE UPDATE ON managed_camera_tokens
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
END $$;

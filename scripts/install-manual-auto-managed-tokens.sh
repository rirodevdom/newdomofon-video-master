#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
WEB_ROOT="${WEB_ROOT:-/var/www/newdomofon-video}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/newdomofon-video-backups/manual-auto-managed-tokens-${STAMP}}"

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Run as root"
[[ -d "$PROJECT_DIR/backend" ]] || fail "Master project not found: $PROJECT_DIR"
[[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"

for command in python3 node npm rsync systemctl curl psql pg_dump; do
  command -v "$command" >/dev/null || fail "$command is required"
done

PATCHER="$PROJECT_DIR/scripts/patch-manual-auto-managed-tokens.py"
COLLISION_FIX="$PROJECT_DIR/scripts/fix-manual-token-resolver-variable.py"
MEDIA_PATCHER="$PROJECT_DIR/scripts/patch-managed-media-gateway.py"
[[ -f "$PATCHER" ]] || fail "Feature patcher is missing: $PATCHER"
[[ -f "$COLLISION_FIX" ]] || fail "Resolver collision fix is missing: $COLLISION_FIX"
[[ -f "$MEDIA_PATCHER" ]] || fail "Managed media patcher is missing: $MEDIA_PATCHER"
[[ -f "$PROJECT_DIR/backend/migrations/094_manual_auto_managed_camera_tokens.sql" ]] \
  || fail "Migration 094 is missing"
[[ -f "$PROJECT_DIR/backend/src/services/manualManagedCameraToken.ts" ]] \
  || fail "Manual token service is missing"

install -d -m 0750 "$BACKUP_ROOT"
cp -a "$ENV_FILE" "$BACKUP_ROOT/app.env"
cp -a "$PROJECT_DIR/backend/src/routes/managedCameraTokens.ts" "$BACKUP_ROOT/managedCameraTokens.ts.before"
cp -a "$PROJECT_DIR/backend/src/routes/internalSmartYard.ts" "$BACKUP_ROOT/internalSmartYard.ts.before"
cp -a "$PROJECT_DIR/backend/src/routes/managedAdminPlayer.ts" "$BACKUP_ROOT/managedAdminPlayer.ts.before"
cp -a "$PROJECT_DIR/frontend/src/views/AdminView.vue" "$BACKUP_ROOT/AdminView.vue.before"
cp -a "$PROJECT_DIR/frontend/src/views/PlayerView.vue" "$BACKUP_ROOT/PlayerView.vue.before"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
[[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL is missing"

log "Backing up PostgreSQL"
pg_dump -Fc "$DATABASE_URL" >"$BACKUP_ROOT/postgresql.dump"

log "Checking and applying source patches"
python3 -m py_compile "$PATCHER" "$COLLISION_FIX" "$MEDIA_PATCHER"
python3 "$COLLISION_FIX" --project-dir "$PROJECT_DIR"
python3 "$PATCHER" --project-dir "$PROJECT_DIR"
python3 "$COLLISION_FIX" --project-dir "$PROJECT_DIR"
python3 "$MEDIA_PATCHER" --project-dir "$PROJECT_DIR"

log "Building and migrating backend"
cd "$PROJECT_DIR/backend"
npm ci --include=dev
npm run build
npm run migrate

log "Building and publishing frontend"
cd "$PROJECT_DIR/frontend"
npm ci --include=dev
npm run build
install -d -m 0755 "$WEB_ROOT"
rsync -a --delete dist/ "$WEB_ROOT/"
chown -R root:root "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 0755 {} +
find "$WEB_ROOT" -type f -exec chmod 0644 {} +

log "Restarting master services"
systemctl restart newdomofon-video-backend.service
if systemctl list-unit-files newdomofon-smartyard-compat.service >/dev/null 2>&1; then
  systemctl restart newdomofon-smartyard-compat.service
fi

for _ in $(seq 1 40); do
  if curl -fsS --max-time 2 http://127.0.0.1:3000/api/health >"$BACKUP_ROOT/backend-health.json"; then
    break
  fi
  sleep 1
done
curl -fsS --max-time 3 http://127.0.0.1:3000/api/health >/dev/null \
  || fail "Backend did not become healthy"

log "Verifying database schema and fallback invariants"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -P pager=off <<'SQL'
SELECT column_name, data_type, is_nullable, column_default
  FROM information_schema.columns
 WHERE table_schema = 'public'
   AND table_name = 'managed_camera_tokens'
   AND column_name IN (
     'token_mode',
     'manual_token_ciphertext',
     'manual_token_digest',
     'auto_assign_new_cameras'
   )
 ORDER BY column_name;

SELECT id, name, token_mode, auto_assign_new_cameras, is_active, scopes
  FROM managed_camera_tokens
 WHERE id = '00000000-0000-4000-8000-000000000001'::uuid;

SELECT id, name, token_mode, auto_assign_new_cameras, is_active, scopes
  FROM managed_camera_tokens
 WHERE auto_assign_new_cameras = true
 ORDER BY name;
SQL

log "Installation completed"
echo "backup=$BACKUP_ROOT"
echo "Open Administration -> Tokens and refresh the page with Ctrl+F5."

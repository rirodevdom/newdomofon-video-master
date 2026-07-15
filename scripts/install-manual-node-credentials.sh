#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
WEB_ROOT="${WEB_ROOT:-/var/www/newdomofon-video}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/newdomofon-video-backups/manual-node-credentials-${STAMP}}"

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Run as root"
[[ -d "$PROJECT_DIR/backend" ]] || fail "Master project not found: $PROJECT_DIR"
[[ -d "$PROJECT_DIR/frontend" ]] || fail "Frontend project not found: $PROJECT_DIR"
[[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"

for command in node npm rsync systemctl curl; do
  command -v "$command" >/dev/null || fail "$command is required"
done

install -d -m 0750 "$BACKUP_ROOT"
cp -a "$ENV_FILE" "$BACKUP_ROOT/app.env"
cp -a "$PROJECT_DIR/backend/src/routes/dvrServers.ts" "$BACKUP_ROOT/dvrServers.ts"
cp -a "$PROJECT_DIR/frontend/src/views/NodesView.vue" "$BACKUP_ROOT/NodesView.vue"
git -C "$PROJECT_DIR" status --short >"$BACKUP_ROOT/git-status.txt" || true
git -C "$PROJECT_DIR" diff --binary >"$BACKUP_ROOT/local-changes.patch" || true

log "Building backend"
cd "$PROJECT_DIR/backend"
umask 022
npm ci --include=dev
npm run build

log "Building frontend"
cd "$PROJECT_DIR/frontend"
npm ci --include=dev
npm run build

log "Publishing frontend"
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
  if curl -fsS --max-time 2 http://127.0.0.1:3000/api/health >"$BACKUP_ROOT/backend-health.json" 2>/dev/null; then
    break
  fi
  sleep 1
done
curl -fsS --max-time 3 http://127.0.0.1:3000/api/health >/dev/null \
  || fail "Backend did not become healthy"

log "Manual node credential UI/API installed"
echo "backup=$BACKUP_ROOT"
echo "Open Administration -> Nodes and refresh with Ctrl+F5."

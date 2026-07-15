#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/newdomofon-video-backups/archive-playback-window-$(date +%Y%m%d-%H%M%S)}"
WEB_ROOT="${WEB_ROOT:-/var/www/newdomofon-video}"

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Run this script as root"
for command in python3 node npm rsync systemctl curl; do
  command -v "$command" >/dev/null || fail "$command is required"
done

PATCHER="$PROJECT_DIR/scripts/patch-managed-media-gateway.py"
ARCHIVE_PATCHER="$PROJECT_DIR/scripts/patch-archive-playback-window.py"
GATEWAY="$PROJECT_DIR/smartyard-compat-proxy/server-node-aware.js"
PLAYER="$PROJECT_DIR/frontend/src/views/PlayerView.vue"

for file in "$PATCHER" "$ARCHIVE_PATCHER" "$GATEWAY" "$PLAYER"; do
  [[ -f "$file" ]] || fail "Required file is missing: $file"
done

install -d -m 0750 "$BACKUP_ROOT"
cp -a "$GATEWAY" "$BACKUP_ROOT/server-node-aware.js.before"
cp -a "$PLAYER" "$BACKUP_ROOT/PlayerView.vue.before"

log "Applying archive ranges and playback-window fixes"
python3 "$PATCHER" --project-dir "$PROJECT_DIR"
node --check "$GATEWAY"

grep -q "node-archive-ranges" "$GATEWAY" \
  || fail "Archive ranges handler was not installed"
grep -q "latestAllowedEndMs" "$PLAYER" \
  || fail "Archive playback end clamp was not installed"
grep -q "requestedSeekMs = Math.min(requestedWindowStartMs" "$PLAYER" \
  || fail "Archive playback start calculation was not installed"

log "Building frontend"
cd "$PROJECT_DIR/frontend"
npm ci --include=dev
npm run build
install -d -m 0755 "$WEB_ROOT"
rsync -a --delete dist/ "$WEB_ROOT/"

log "Restarting composite media gateway"
systemctl restart newdomofon-smartyard-compat.service

for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:3082/health >"$BACKUP_ROOT/gateway-health.json"; then
    break
  fi
  sleep 1
done

curl -fsS --max-time 3 http://127.0.0.1:3082/health >/dev/null \
  || fail "Gateway on 3082 did not become healthy"
curl -fsS --max-time 3 http://127.0.0.1:3084/health >"$BACKUP_ROOT/node-aware-health.json" \
  || fail "Node-aware gateway on 3084 is unavailable"

log "Repair completed"
cat "$BACKUP_ROOT/gateway-health.json"
echo
cat "$BACKUP_ROOT/node-aware-health.json"
echo
printf 'backup=%s\n' "$BACKUP_ROOT"

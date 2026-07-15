#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
UNIT_NAME="newdomofon-smartyard-compat.service"
UNIT_SOURCE="$PROJECT_DIR/deploy/systemd/$UNIT_NAME"
UNIT_TARGET="/etc/systemd/system/$UNIT_NAME"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-/opt/newdomofon-video-backups/managed-media-gateway-service-$STAMP}"

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Run this script as root"
[[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
[[ -f "$UNIT_SOURCE" ]] || fail "Canonical systemd unit not found: $UNIT_SOURCE"
command -v node >/dev/null || fail "node is required"
command -v curl >/dev/null || fail "curl is required"
command -v systemctl >/dev/null || fail "systemctl is required"
command -v ss >/dev/null || fail "ss is required"

install -d -m 0750 "$BACKUP_DIR"

log "Backing up current gateway service state"
systemctl cat "$UNIT_NAME" >"$BACKUP_DIR/systemctl-cat.txt" 2>&1 || true
systemctl show "$UNIT_NAME" -p FragmentPath -p DropInPaths -p ExecStart -p User -p Group \
  >"$BACKUP_DIR/systemctl-show.txt" 2>&1 || true
systemctl --no-pager --full status "$UNIT_NAME" >"$BACKUP_DIR/status-before.txt" 2>&1 || true
journalctl -u "$UNIT_NAME" -n 300 --no-pager >"$BACKUP_DIR/journal-before.txt" 2>&1 || true
ss -ltnp >"$BACKUP_DIR/listeners-before.txt" 2>&1 || true
[[ -f "$UNIT_TARGET" ]] && cp -a "$UNIT_TARGET" "$BACKUP_DIR/unit-before.service"
if [[ -d "/etc/systemd/system/${UNIT_NAME}.d" ]]; then
  cp -a "/etc/systemd/system/${UNIT_NAME}.d" "$BACKUP_DIR/dropins-before"
fi

log "Stopping obsolete split gateway services"
obsolete_services=(
  newdomofon-video-smartyard-gateway.service
  newdomofon-video-node-media-gateway.service
  newdomofon-video-events-gateway.service
  newdomofon-video-preview-gateway.service
)
for service in "${obsolete_services[@]}"; do
  if systemctl list-unit-files "$service" --no-legend 2>/dev/null | grep -q "^${service}"; then
    systemctl disable --now "$service" || true
  else
    systemctl stop "$service" 2>/dev/null || true
  fi
done

# The canonical unit already defines root, EnvironmentFile and the composite
# server-formats-gateway.js entrypoint. Historical overrides commonly replace
# ExecStart/User and prevent the composite gateway from binding ports 3082-3086.
log "Removing stale drop-ins and installing canonical composite unit"
rm -rf "/etc/systemd/system/${UNIT_NAME}.d"
install -o root -g root -m 0644 "$UNIT_SOURCE" "$UNIT_TARGET"

log "Validating gateway JavaScript"
python3 "$PROJECT_DIR/scripts/patch-managed-media-gateway.py" --project-dir "$PROJECT_DIR"
for file in \
  server-node-aware.js \
  server-events-gateway.js \
  server-preview-gateway.js \
  server-formats-gateway.js; do
  node --check "$PROJECT_DIR/smartyard-compat-proxy/$file"
done

log "Starting composite gateway"
systemctl daemon-reload
systemctl reset-failed "$UNIT_NAME" || true
systemctl enable "$UNIT_NAME" >/dev/null
systemctl restart "$UNIT_NAME"

ready=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 http://127.0.0.1:3082/health >"$BACKUP_DIR/health-3082.json" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.5
done

if [[ "$ready" -ne 1 ]]; then
  systemctl --no-pager --full status "$UNIT_NAME" >&2 || true
  journalctl -u "$UNIT_NAME" -n 300 --no-pager >&2 || true
  echo >&2
  echo "Listeners on gateway ports:" >&2
  ss -ltnp | grep -E ':(3082|3083|3084|3085|3086)\b' >&2 || true
  fail "Composite gateway did not open port 3082"
fi

curl -fsS --max-time 3 http://127.0.0.1:3084/health >"$BACKUP_DIR/health-3084.json" \
  || fail "Node-aware inner gateway did not open port 3084"

grep -q 'newdomofon-smartyard-formats-gateway' "$BACKUP_DIR/health-3082.json" \
  || fail "Port 3082 is not the formats gateway"
grep -q 'v301-node-aware-smartyard-gateway' "$BACKUP_DIR/health-3084.json" \
  || fail "Port 3084 is not the node-aware gateway"
grep -q '"internal_secret_configured":true' "$BACKUP_DIR/health-3084.json" \
  || fail "Node-aware gateway has no INTERNAL_DVR_SECRET"

log "Gateway is healthy"
systemctl --no-pager --full status "$UNIT_NAME" | sed -n '1,30p'
echo
cat "$BACKUP_DIR/health-3082.json"
echo
cat "$BACKUP_DIR/health-3084.json"
echo
ss -ltnp | grep -E ':(3082|3083|3084|3085|3086)\b' || true

log "Repair completed. Backup: $BACKUP_DIR"

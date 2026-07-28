#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
CACHE_DIR="${PREVIEW_CACHE_DIR:-/var/cache/newdomofon-video/smartyard-preview}"
SERVICE="${SMARTYARD_SERVICE:-newdomofon-smartyard-compat.service}"

[[ "$(id -u)" -eq 0 ]] || {
  echo "Run as root" >&2
  exit 77
}

for file in \
  "$PROJECT_DIR/scripts/patch-smartyard-flussonic-compat.py" \
  "$PROJECT_DIR/scripts/patch-smartyard-preview-live-fallback.py" \
  "$PROJECT_DIR/smartyard-compat-proxy/server-preview-gateway.js"; do
  [[ -f "$file" ]] || {
    echo "Required file not found: $file" >&2
    exit 66
  }
done

python3 -m py_compile \
  "$PROJECT_DIR/scripts/patch-smartyard-flussonic-compat.py" \
  "$PROJECT_DIR/scripts/patch-smartyard-preview-live-fallback.py"

python3 "$PROJECT_DIR/scripts/patch-smartyard-flussonic-compat.py" \
  --project-dir "$PROJECT_DIR"
python3 "$PROJECT_DIR/scripts/patch-smartyard-preview-live-fallback.py" \
  --project-dir "$PROJECT_DIR"

node --check "$PROJECT_DIR/smartyard-compat-proxy/server-preview-gateway.js"

grep -q 'newdomofon-smartyard-live-snapshot-fallback' \
  "$PROJECT_DIR/smartyard-compat-proxy/server-preview-gateway.js"
grep -q 'fetchLiveSnapshotPreview' \
  "$PROJECT_DIR/smartyard-compat-proxy/server-preview-gateway.js"

install -d -o root -g root -m 0755 "$CACHE_DIR"
find "$CACHE_DIR" -maxdepth 1 -type f -name '*.mp4' -delete

systemctl restart "$SERVICE"

for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:3082/health \
    >/tmp/newdomofon-smartyard-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done

curl -fsS --max-time 5 http://127.0.0.1:3082/health |
  python3 -m json.tool

echo "SmartYard preview live fallback repaired."

#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
SITE_CONF="${SITE_CONF:-/etc/nginx/sites-available/newdomofon-video.conf}"
ENABLED_CONF="${ENABLED_CONF:-/etc/nginx/sites-enabled/newdomofon-video.conf}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/newdomofon-video/nginx}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_DIR/newdomofon-video.conf.pre-deploy-$STAMP.bak"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

ROOT_ONLY_PATCHER="$PROJECT_DIR/scripts/patch-root-only-master-runtime.py"
if [[ -f "$ROOT_ONLY_PATCHER" ]]; then
  python3 "$ROOT_ONLY_PATCHER" --project-dir "$PROJECT_DIR"
fi

install -d -o root -g root -m 0700 "$BACKUP_DIR"

HAD_SITE=0
if [[ -e "$SITE_CONF" ]]; then
  cp -aL "$SITE_CONF" "$BACKUP"
  HAD_SITE=1
  echo "Saved production Nginx config: $BACKUP"
fi

PROJECT_DIR="$PROJECT_DIR" bash "$PROJECT_DIR/scripts/deploy-master.sh" "$@"

if [[ "$HAD_SITE" -eq 1 ]]; then
  install -m 0644 "$BACKUP" "$SITE_CONF"
  ln -sfn "$SITE_CONF" "$ENABLED_CONF"
  nginx -t
  systemctl reload nginx
  echo "Restored production Nginx config after deploy: $SITE_CONF"
fi

# Validate the application directly. The preserved production Nginx vhost can
# legitimately redirect plain http://127.0.0.1 requests to the public HTTPS
# hostname; trying to parse such a redirect/empty body as JSON made otherwise
# successful archive updates report a false failure.
HEALTH_FILE=/tmp/newdomofon-master-backend-health.json
curl -fsS --max-time 5 http://127.0.0.1:3000/api/health >"$HEALTH_FILE"
python3 - "$HEALTH_FILE" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
with path.open('r', encoding='utf-8') as handle:
    payload = json.load(handle)
if payload.get('ok') is not True:
    raise SystemExit(f"Backend health is not ok: {payload}")
print(json.dumps(payload, ensure_ascii=False))
PY

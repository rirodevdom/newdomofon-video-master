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

curl -fsS --max-time 5 http://127.0.0.1/api/health >/tmp/newdomofon-master-public-health.json
python3 -m json.tool </tmp/newdomofon-master-public-health.json

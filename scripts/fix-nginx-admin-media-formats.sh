#!/usr/bin/env bash
set -Eeuo pipefail

SITE="${NGINX_SITE:-/etc/nginx/sites-available/newdomofon-video.conf}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${SITE}.${STAMP}.admin-media-formats.bak"

if [[ ! -f "$SITE" ]]; then
  echo "Nginx site not found: $SITE" >&2
  exit 1
fi

cp -a "$SITE" "$BACKUP"

python3 - "$SITE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "NEWD_ADMIN_MEDIA_FORMATS_V1"

if marker in text:
    print("Nginx media formats route already installed")
    raise SystemExit(0)

replacements = [
    ("m3u8|ts|m4s|mp4", "m3u8|mpd|ts|m4s|mp4|jpg|jpeg"),
    ("m3u8|mpd|ts|m4s|mp4", "m3u8|mpd|ts|m4s|mp4|jpg|jpeg"),
]

changed = False
for old, new in replacements:
    if old in text:
        text = text.replace(old, new, 1)
        changed = True
        break

if not changed:
    raise SystemExit("Could not find the SmartYard media extension list in active Nginx config")

needle = "location ~ ^/[^/]+/(?:.*\\.(?:"
index = text.find(needle)
if index < 0:
    raise SystemExit("Could not find SmartYard media location")

line_start = text.rfind("\n", 0, index) + 1
text = text[:line_start] + "    # NEWD_ADMIN_MEDIA_FORMATS_V1\n" + text[line_start:]
path.write_text(text)
PY

if ! nginx -t; then
  cp -a "$BACKUP" "$SITE"
  nginx -t || true
  echo "Nginx validation failed; restored $BACKUP" >&2
  exit 1
fi

systemctl reload nginx

echo "NGINX ADMIN MEDIA FORMATS INSTALLED"
echo "Backup: $BACKUP"

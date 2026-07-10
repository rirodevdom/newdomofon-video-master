#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG="${NGINX_CONFIG:-/etc/nginx/sites-available/newdomofon-video.conf}"
MARKER="# NEWDOMOFON_SMARTYARD_EVENTS_ROUTE_V1"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${CONFIG}.${STAMP}.bak"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

for command in nginx python3 curl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing command: $command" >&2
    exit 1
  }
done

if [[ ! -f "$CONFIG" ]]; then
  echo "Nginx config not found: $CONFIG" >&2
  exit 1
fi

cp -a "$CONFIG" "$BACKUP"

echo "===== PATCH NGINX EVENTS ROUTE ====="
echo "config=$CONFIG"
echo "backup=$BACKUP"

if grep -Fq "$MARKER" "$CONFIG"; then
  echo "Events route is already installed"
else
  CONFIG="$CONFIG" MARKER="$MARKER" python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["CONFIG"])
marker = os.environ["MARKER"]
text = path.read_text(encoding="utf-8")

snippet = f'''    {marker}
    # SmartYard camera events must be proxied before the SPA fallback.
    # Without this location nginx serves index.html with HTTP 200.
    location ~ ^/[^/]+/(?:events(?:\\.json|/summary)?|events_summary\\.json|motion_events\\.json)$ {{
        proxy_pass http://127.0.0.1:3082;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering off;

        proxy_hide_header Access-Control-Allow-Origin;
        proxy_hide_header Access-Control-Allow-Methods;
        proxy_hide_header Access-Control-Allow-Headers;
        proxy_hide_header Access-Control-Expose-Headers;
        proxy_hide_header Access-Control-Allow-Private-Network;

        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
        add_header Access-Control-Allow-Headers "*" always;
        add_header Access-Control-Allow-Private-Network "true" always;
        add_header Access-Control-Expose-Headers "content-length,content-range,accept-ranges,cache-control,content-type,x-newdomofon-resolved-stream,x-newdomofon-smartyard-compat,x-newdomofon-smartyard-route,x-newdomofon-events-count" always;
    }}

'''

anchors = [
    "    location ~ ^/[^/]+/(?:.*\\.",
    "    location /assets/ {",
    "    location / {",
]

position = -1
for anchor in anchors:
    position = text.find(anchor)
    if position >= 0:
        break

if position < 0:
    raise SystemExit("Could not find a safe insertion point in nginx config")

text = text[:position] + snippet + text[position:]
path.write_text(text, encoding="utf-8")
PY
fi

if ! nginx -t; then
  echo "ERROR: nginx configuration check failed; restoring backup" >&2
  cp -a "$BACKUP" "$CONFIG"
  nginx -t || true
  exit 1
fi

systemctl reload nginx

echo
echo "===== INSTALLED LOCATION ====="
grep -n -A34 -B2 "$MARKER" "$CONFIG"

echo
echo "===== LOCAL GATEWAY ====="
curl -fsS http://127.0.0.1:3082/health
printf '\n'

if [[ -n "${SMARTYARD_URL:-}" ]]; then
  export SMARTYARD_URL

  eval "$(
    python3 - <<'PY'
import os
import shlex
from urllib.parse import parse_qs, urlparse

raw = os.environ["SMARTYARD_URL"]
parsed = urlparse(raw)
token = parse_qs(parsed.query).get("token", [""])[0]
if not token:
    raise SystemExit("SMARTYARD_URL does not contain token")

base = raw.split("?", 1)[0]
print("EVENT_BASE=" + shlex.quote(base))
print("EVENT_TOKEN=" + shlex.quote(token))
PY
  )"

  export EVENT_TOKEN
  TOKEN_Q="$(python3 - <<'PY'
import os
from urllib.parse import quote
print(quote(os.environ["EVENT_TOKEN"], safe=""))
PY
)"

  NOW="$(date +%s)"
  FROM="$((NOW - 3600))"
  EVENT_URL="${EVENT_BASE}events.json?from=${FROM}&to=${NOW}&limit=100&token=${TOKEN_Q}"

  echo
  echo "===== PUBLIC EVENTS ====="
  curl -ksS \
    -D /tmp/newdomofon-events-nginx.headers \
    -o /tmp/newdomofon-events-nginx.json \
    -H 'Origin: https://test.domofon-37.ru' \
    -H 'Access-Control-Request-Private-Network: true' \
    "$EVENT_URL"

  sed -n '1,40p' /tmp/newdomofon-events-nginx.headers

  grep -qi '^content-type: application/json' /tmp/newdomofon-events-nginx.headers || {
    echo "ERROR: public event response is not JSON" >&2
    sed -n '1,20p' /tmp/newdomofon-events-nginx.json >&2
    exit 1
  }

  grep -qi '^access-control-allow-origin: \*' /tmp/newdomofon-events-nginx.headers || {
    echo "ERROR: Access-Control-Allow-Origin is missing" >&2
    exit 1
  }

  grep -qi '^x-newdomofon-smartyard-route: node-events' /tmp/newdomofon-events-nginx.headers || {
    echo "ERROR: request did not reach node-events route" >&2
    exit 1
  }

  python3 -m json.tool /tmp/newdomofon-events-nginx.json | sed -n '1,80p'
fi

echo
echo "NGINX SMARTYARD EVENTS ROUTE INSTALLED"
echo "Backup: $BACKUP"

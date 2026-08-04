#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SITE_CONF="${SITE_CONF:-/etc/nginx/sites-available/newdomofon-video.conf}"
ENABLED_CONF="${ENABLED_CONF:-/etc/nginx/sites-enabled/newdomofon-video.conf}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/newdomofon-video/nginx}"
PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
NORMALIZER="${NORMALIZER:-$PROJECT_DIR/scripts/normalize-smartyard-media-cors.py}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_DIR/newdomofon-video.conf.before-public-media-cors-$STAMP.bak"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

[[ -e "$SITE_CONF" ]] || {
  echo "Nginx site config not found: $SITE_CONF" >&2
  exit 2
}
[[ -f "$NORMALIZER" ]] || {
  echo "SmartYard CORS normalizer not found: $NORMALIZER" >&2
  exit 2
}

command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required" >&2
  exit 2
}
command -v nginx >/dev/null 2>&1 || {
  echo "nginx is required" >&2
  exit 2
}
command -v curl >/dev/null 2>&1 || {
  echo "curl is required" >&2
  exit 2
}

PUBLIC_BASE_URL="${PUBLIC_MEDIA_PROBE_BASE_URL:-}"
if [[ -z "$PUBLIC_BASE_URL" && -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  PUBLIC_BASE_URL="${SMARTYARD_PUBLIC_BASE_URL:-${APP_PUBLIC_URL:-}}"
fi
PUBLIC_BASE_URL="${PUBLIC_BASE_URL%/}"
[[ -n "$PUBLIC_BASE_URL" ]] || PUBLIC_BASE_URL="http://127.0.0.1"

read -r PROBE_SCHEME PROBE_HOST PROBE_PORT < <(
  python3 - "$PUBLIC_BASE_URL" <<'PY'
from urllib.parse import urlparse
import sys

parsed = urlparse(sys.argv[1])
scheme = parsed.scheme or "http"
host = parsed.hostname or "127.0.0.1"
port = parsed.port or (443 if scheme == "https" else 80)
print(scheme, host, port)
PY
)

PROBE_AUTHORITY="$PROBE_HOST"
if [[ ( "$PROBE_SCHEME" == "https" && "$PROBE_PORT" != 443 ) || ( "$PROBE_SCHEME" == "http" && "$PROBE_PORT" != 80 ) ]]; then
  PROBE_AUTHORITY="$PROBE_HOST:$PROBE_PORT"
fi
PROBE_URL="$PROBE_SCHEME://$PROBE_AUTHORITY/__cors_probe__/index.m3u8?token=invalid"

install -d -o root -g root -m 0700 "$BACKUP_DIR"
cp -aL "$SITE_CONF" "$BACKUP"

rollback() {
  local rc=$?
  trap - ERR
  echo "Public media CORS repair failed; restoring $BACKUP" >&2
  install -m 0644 "$BACKUP" "$SITE_CONF"
  ln -sfn "$SITE_CONF" "$ENABLED_CONF"
  nginx -t || true
  systemctl reload nginx || true
  exit "$rc"
}
trap rollback ERR

python3 "$NORMALIZER" "$SITE_CONF"

ln -sfn "$SITE_CONF" "$ENABLED_CONF"
nginx -t
systemctl reload nginx
sleep 1

check_probe() {
  local method="$1"
  local headers
  headers="$(mktemp)"

  local -a args=(
    -sS
    --max-time 10
    --resolve "$PROBE_HOST:$PROBE_PORT:127.0.0.1"
    -X "$method"
    -H 'Origin: https://smartyard-cors-probe.local'
    -D "$headers"
    -o /dev/null
  )

  if [[ "$method" == OPTIONS ]]; then
    args+=(
      -H 'Access-Control-Request-Method: GET'
      -H 'Access-Control-Request-Headers: range,authorization'
      -H 'Access-Control-Request-Private-Network: true'
    )
  fi

  curl "${args[@]}" "$PROBE_URL" || true

  python3 - "$headers" "$method" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
method = sys.argv[2]
headers = {}
for line in path.read_text(encoding="latin-1").splitlines():
    if ":" not in line:
        continue
    name, value = line.split(":", 1)
    headers.setdefault(name.strip().lower(), []).append(value.strip())

expected = {
    "access-control-allow-origin": ["*"],
    "access-control-allow-private-network": ["true"],
}
for name, value in expected.items():
    actual = headers.get(name, [])
    if actual != value:
        raise SystemExit(f"{method}: expected {name}={value}, got {actual}")

methods = ",".join(headers.get("access-control-allow-methods", [])).upper()
if "GET" not in methods or "OPTIONS" not in methods:
    raise SystemExit(f"{method}: incomplete allow-methods: {methods!r}")

print(f"OK {method}: canonical public/private-network CORS")
PY

  rm -f "$headers"
}

check_probe OPTIONS
check_probe GET

trap - ERR

echo "OK: public SmartYard media CORS is canonical"
echo "Probe: $PROBE_SCHEME://$PROBE_AUTHORITY via 127.0.0.1"
echo "Access-Control-Allow-Origin=*"
echo "Access-Control-Allow-Private-Network=true"
echo "backup=$BACKUP"

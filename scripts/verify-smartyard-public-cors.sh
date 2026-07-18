#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BASE_URL="${BASE_URL:-}"
ORIGIN="${ORIGIN:-http://smartyard-vue.local}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

if [[ -z "$BASE_URL" && -r "$ENV_FILE" ]]; then
  BASE_URL="$(sed -n 's/^APP_PUBLIC_URL=//p' "$ENV_FILE" | tail -1)"
fi
BASE_URL="${BASE_URL:-http://127.0.0.1}"

read -r PROBE_SCHEME PROBE_HOST PROBE_PORT < <(
  python3 - "$BASE_URL" <<'PY'
from urllib.parse import urlparse
import sys

parsed = urlparse(sys.argv[1])
if parsed.scheme not in {"http", "https"} or not parsed.hostname:
    raise SystemExit("invalid BASE_URL")
port = parsed.port or (443 if parsed.scheme == "https" else 80)
print(parsed.scheme, parsed.hostname, port)
PY
)

CURL_BASE="${PROBE_SCHEME}://${PROBE_HOST}"
if ! { [[ "$PROBE_SCHEME" == http && "$PROBE_PORT" == 80 ]] || [[ "$PROBE_SCHEME" == https && "$PROBE_PORT" == 443 ]]; }; then
  CURL_BASE="${CURL_BASE}:${PROBE_PORT}"
fi

COMMON_CURL_ARGS=(
  -sS
  --max-time 10
  --resolve "${PROBE_HOST}:${PROBE_PORT}:127.0.0.1"
)
if [[ "$PROBE_SCHEME" == https ]]; then
  COMMON_CURL_ARGS+=(-k)
fi

check_response() {
  local method="$1"
  local path="$2"
  local headers
  headers="$(mktemp)"

  local -a args=(
    "${COMMON_CURL_ARGS[@]}"
    -X "$method"
    -H "Origin: $ORIGIN"
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

  curl "${args[@]}" "${CURL_BASE%/}$path" || true

  python3 - "$headers" "$method" "$path" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
method = sys.argv[2]
url_path = sys.argv[3]
lines = path.read_text(encoding="latin-1").splitlines()

headers = {}
for line in lines:
    if ":" not in line:
        continue
    name, value = line.split(":", 1)
    headers.setdefault(name.strip().lower(), []).append(value.strip())

origins = headers.get("access-control-allow-origin", [])
if origins != ["*"]:
    raise SystemExit(f"{method} {url_path}: expected one ACAO '*', got {origins}")

methods = ",".join(headers.get("access-control-allow-methods", [])).upper()
if "GET" not in methods or "OPTIONS" not in methods:
    raise SystemExit(f"{method} {url_path}: incomplete allow-methods: {methods!r}")

private_network = headers.get("access-control-allow-private-network", [])
if private_network != ["true"]:
    raise SystemExit(
        f"{method} {url_path}: expected one private-network header, got {private_network}"
    )

print(f"OK {method} {url_path}: canonical CORS")
PY

  rm -f "$headers"
}

paths=(
  '/__cors_probe__/index.m3u8?token=invalid'
  '/__cors_probe__/live.ts?token=invalid'
  '/__cors_probe__/recording_status.json?token=invalid'
  '/__cors_probe__/events.json?token=invalid'
)

for path in "${paths[@]}"; do
  check_response OPTIONS "$path"
  check_response GET "$path"
done

echo "SmartYard public CORS smoke test passed."
echo "probe_base=$CURL_BASE"

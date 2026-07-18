#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE_URL="${BASE_URL:-http://127.0.0.1}"
ORIGIN="${ORIGIN:-http://smartyard-vue.local}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

check_response() {
  local method="$1"
  local path="$2"
  local headers
  headers="$(mktemp)"

  local -a args=(
    -sS
    --max-time 10
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

  curl "${args[@]}" "${BASE_URL%/}$path" || true

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

#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BASE_URL="${BASE_URL:-}"
ORIGIN="${ORIGIN:-${CORS_TEST_ORIGIN:-https://client.invalid}}"
PROBE_ADDRESS="${PROBE_ADDRESS:-}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

read_env_value() {
  local key="$1"
  local file="$2"
  [[ -r "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -1 | sed -E 's/^[[:space:]]*["'"']?//; s/["'"']?[[:space:]]*$//'
}

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

if [[ -z "$BASE_URL" && -r "$ENV_FILE" ]]; then
  for key in SMARTYARD_PUBLIC_BASE_URL APP_PUBLIC_URL PUBLIC_BACKEND_BASE_URL CORS_ORIGIN; do
    value="$(read_env_value "$key" "$ENV_FILE")"
    if [[ -n "$value" && "$value" != "*" ]]; then
      BASE_URL="$value"
      break
    fi
  done
fi
BASE_URL="${BASE_URL:-http://127.0.0.1}"

read -r PROBE_SCHEME PROBE_HOST PROBE_PORT < <(
  python3 - "$BASE_URL" <<'PY'
from urllib.parse import urlparse
import sys

raw = sys.argv[1].strip().strip('"').strip("'")
if '://' not in raw:
    raw = 'https://' + raw
parsed = urlparse(raw)
if parsed.scheme not in {'http', 'https'} or not parsed.hostname:
    raise SystemExit('invalid BASE_URL')
port = parsed.port or (443 if parsed.scheme == 'https' else 80)
print(parsed.scheme, parsed.hostname, port)
PY
)

python3 - "$ORIGIN" <<'PY'
from urllib.parse import urlparse
import sys
p = urlparse(sys.argv[1])
if p.scheme not in {'http', 'https'} or not p.hostname:
    raise SystemExit('invalid ORIGIN')
PY

CURL_BASE="${PROBE_SCHEME}://${PROBE_HOST}"
if ! { [[ "$PROBE_SCHEME" == http && "$PROBE_PORT" == 80 ]] || [[ "$PROBE_SCHEME" == https && "$PROBE_PORT" == 443 ]]; }; then
  CURL_BASE="${CURL_BASE}:${PROBE_PORT}"
fi

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

build_probe_candidates() {
  local candidate
  local -A seen=()

  if [[ -n "$PROBE_ADDRESS" ]]; then
    is_ipv4 "$PROBE_ADDRESS" || fail "PROBE_ADDRESS must be an IPv4 address: $PROBE_ADDRESS"
    printf '%s\n' "$PROBE_ADDRESS"
    return
  fi

  for candidate in 127.0.0.1; do
    if [[ -z "${seen[$candidate]:-}" ]]; then
      seen[$candidate]=1
      printf '%s\n' "$candidate"
    fi
  done

  if command -v ip >/dev/null 2>&1; then
    candidate="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1 || true)"
    if [[ -n "$candidate" ]] && is_ipv4 "$candidate" && [[ -z "${seen[$candidate]:-}" ]]; then
      seen[$candidate]=1
      printf '%s\n' "$candidate"
    fi
  fi

  if command -v hostname >/dev/null 2>&1; then
    while read -r candidate; do
      if is_ipv4 "$candidate" && [[ -z "${seen[$candidate]:-}" ]]; then
        seen[$candidate]=1
        printf '%s\n' "$candidate"
      fi
    done < <(hostname -I 2>/dev/null | tr ' ' '\n' | sed '/^$/d' || true)
  fi
}

select_probe_address() {
  local candidate
  local -a args
  local -a attempted=()

  while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    attempted+=("$candidate")
    args=(
      -sS
      --connect-timeout 2
      --max-time 4
      --resolve "${PROBE_HOST}:${PROBE_PORT}:${candidate}"
      -o /dev/null
    )
    if [[ "$PROBE_SCHEME" == https ]]; then
      args+=(-k)
    fi

    if curl "${args[@]}" "${CURL_BASE%/}/" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return
    fi
  done < <(build_probe_candidates)

  fail "cannot connect to ${PROBE_HOST}:${PROBE_PORT} through local addresses: ${attempted[*]:-none}. Set PROBE_ADDRESS to the address where Nginx listens."
}

ACTIVE_PROBE_ADDRESS="$(select_probe_address)"

COMMON_CURL_ARGS=(
  -sS
  --connect-timeout 3
  --max-time 10
  --resolve "${PROBE_HOST}:${PROBE_PORT}:${ACTIVE_PROBE_ADDRESS}"
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

  if ! curl "${args[@]}" "${CURL_BASE%/}$path"; then
    rm -f "$headers"
    fail "$method $path: connection failed via ${ACTIVE_PROBE_ADDRESS}:${PROBE_PORT} for host ${PROBE_HOST}"
  fi

  python3 - "$headers" "$method" "$path" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
method = sys.argv[2]
url_path = sys.argv[3]
lines = path.read_text(encoding='latin-1').splitlines()

headers = {}
for line in lines:
    if ':' not in line:
        continue
    name, value = line.split(':', 1)
    headers.setdefault(name.strip().lower(), []).append(value.strip())

origins = headers.get('access-control-allow-origin', [])
if origins != ['*']:
    raise SystemExit(f"{method} {url_path}: expected one ACAO '*', got {origins}")

methods = ','.join(headers.get('access-control-allow-methods', [])).upper()
if 'GET' not in methods or 'OPTIONS' not in methods:
    raise SystemExit(f'{method} {url_path}: incomplete allow-methods: {methods!r}')

private_network = headers.get('access-control-allow-private-network', [])
if private_network != ['true']:
    raise SystemExit(
        f'{method} {url_path}: expected one private-network header, got {private_network}'
    )

print(f'OK {method} {url_path}: canonical CORS')
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
echo "probe_address=$ACTIVE_PROBE_ADDRESS"
echo "test_origin=$ORIGIN"

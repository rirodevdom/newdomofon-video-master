#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SITE_CONF="${SITE_CONF:-/etc/nginx/sites-available/newdomofon-video.conf}"
ENABLED_CONF="${ENABLED_CONF:-/etc/nginx/sites-enabled/newdomofon-video.conf}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/newdomofon-video/public-https}"
PUBLIC_URL="${PUBLIC_URL:-}"
DOMAIN="${DOMAIN:-}"
PROBE_ADDRESS="${PROBE_ADDRESS:-}"
CORS_TEST_ORIGIN="${CORS_TEST_ORIGIN:-${ORIGIN:-https://client.invalid}}"
HSTS_MAX_AGE="${HSTS_MAX_AGE:-31536000}"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Repair NewDomofon public HTTPS settings without a built-in deployment domain.

The public URL is resolved in this order:
1. --public-url / PUBLIC_URL
2. --domain / DOMAIN (compatibility option; HTTPS is assumed)
3. SMARTYARD_PUBLIC_BASE_URL from the production environment
4. APP_PUBLIC_URL from the production environment
5. PUBLIC_BACKEND_BASE_URL from the production environment
6. CORS_ORIGIN from the production environment

The resolved hostname is used to select the TLS Nginx vhost. If no matching
server_name exists and there is exactly one TLS vhost, that vhost is selected
and the hostname is added to its server_name directive.

Usage:
  sudo bash scripts/repair-public-https-origin.sh [options]

Options:
  --public-url URL       Canonical public URL, for example https://video.example.com
  --domain NAME          Compatibility shorthand for --public-url https://NAME
  --probe-address IP     Local address where Nginx listens on the public port
  --test-origin URL      Browser origin used only for the CORS smoke test
  --env-file PATH        Master environment file
  --site-conf PATH       Active Nginx site file
  --enabled-conf PATH    Enabled Nginx symlink
  --backup-dir PATH      Backup root
  --hsts-max-age SEC     HSTS max-age, default 31536000
  --dry-run              Patch temporary copies and validate only
  -h, --help             Show this help
EOF
}

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

while (($#)); do
  case "$1" in
    --public-url) PUBLIC_URL="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --probe-address) PROBE_ADDRESS="${2:-}"; shift 2 ;;
    --test-origin) CORS_TEST_ORIGIN="${2:-}"; shift 2 ;;
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --site-conf) SITE_CONF="${2:-}"; shift 2 ;;
    --enabled-conf) ENABLED_CONF="${2:-}"; shift 2 ;;
    --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
    --hsts-max-age) HSTS_MAX_AGE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

[[ "$HSTS_MAX_AGE" =~ ^[0-9]+$ ]] || fail "HSTS max-age must be an integer"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

if [[ "$DRY_RUN" != "true" ]]; then
  [[ "$(id -u)" -eq 0 ]] || fail "Run as root"
  command -v nginx >/dev/null 2>&1 || fail "nginx is required"
  command -v curl >/dev/null 2>&1 || fail "curl is required"
fi

[[ -f "$ENV_FILE" ]] || fail "environment file not found: $ENV_FILE"
[[ -f "$SITE_CONF" ]] || fail "Nginx site config not found: $SITE_CONF"

if [[ -z "$PUBLIC_URL" && -n "$DOMAIN" ]]; then
  PUBLIC_URL="https://${DOMAIN#http://}"
  PUBLIC_URL="${PUBLIC_URL/https:\/\/https:\/\/}"
fi

if [[ -z "$PUBLIC_URL" ]]; then
  for key in SMARTYARD_PUBLIC_BASE_URL APP_PUBLIC_URL PUBLIC_BACKEND_BASE_URL CORS_ORIGIN; do
    value="$(read_env_value "$key" "$ENV_FILE")"
    if [[ -n "$value" && "$value" != "*" ]]; then
      PUBLIC_URL="$value"
      break
    fi
  done
fi

[[ -n "$PUBLIC_URL" ]] || fail "public URL cannot be determined; use --public-url or configure APP_PUBLIC_URL"

read -r PUBLIC_ORIGIN PUBLIC_HOST PUBLIC_PORT < <(
  python3 - "$PUBLIC_URL" <<'PY'
from urllib.parse import urlparse
import ipaddress
import sys

raw = sys.argv[1].strip().strip('"').strip("'")
if '://' not in raw:
    raw = 'https://' + raw
parsed = urlparse(raw)
if parsed.scheme not in {'http', 'https'} or not parsed.hostname:
    raise SystemExit('invalid public URL')

host = parsed.hostname
try:
    ip = ipaddress.ip_address(host)
    authority_host = f'[{host}]' if ip.version == 6 else host
except ValueError:
    authority_host = host

# This repair is specifically for HTTPS publication. Preserve an explicit
# non-default port, otherwise use the standard HTTPS port.
port = parsed.port
if port in {None, 80, 443}:
    port = 443
    origin = f'https://{authority_host}'
else:
    origin = f'https://{authority_host}:{port}'

print(origin, host, port)
PY
)

python3 - "$CORS_TEST_ORIGIN" <<'PY'
from urllib.parse import urlparse
import sys
p = urlparse(sys.argv[1])
if p.scheme not in {'http', 'https'} or not p.hostname:
    raise SystemExit('invalid CORS test origin')
PY

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

WORK_ENV="$TMP_DIR/app.env"
WORK_CONF="$TMP_DIR/newdomofon-video.conf"
cp -a "$ENV_FILE" "$WORK_ENV"
cp -aL "$SITE_CONF" "$WORK_CONF"

python3 - "$WORK_ENV" "$WORK_CONF" "$PUBLIC_ORIGIN" "$PUBLIC_HOST" "$HSTS_MAX_AGE" <<'PY'
from pathlib import Path
import re
import sys

ENV_PATH = Path(sys.argv[1])
CONF_PATH = Path(sys.argv[2])
ORIGIN = sys.argv[3]
HOST = sys.argv[4]
MAX_AGE = sys.argv[5]
HSTS = f'add_header Strict-Transport-Security "max-age={MAX_AGE}" always;'


def update_env(path: Path) -> None:
    text = path.read_text(encoding='utf-8')
    lines = text.splitlines()
    wanted = {
        'APP_PUBLIC_URL': ORIGIN,
        'SMARTYARD_PUBLIC_BASE_URL': ORIGIN,
        'CORS_ORIGIN': ORIGIN,
    }
    seen: set[str] = set()
    output: list[str] = []
    for line in lines:
        match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=', line)
        if match and match.group(1) in wanted:
            key = match.group(1)
            if key not in seen:
                output.append(f'{key}={wanted[key]}')
                seen.add(key)
            continue
        output.append(line)
    for key, value in wanted.items():
        if key not in seen:
            output.append(f'{key}={value}')
    path.write_text('\n'.join(output).rstrip('\n') + '\n', encoding='utf-8')


def block_end(source: str, opening: int) -> int:
    depth = 0
    for index in range(opening, len(source)):
        char = source[index]
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return index + 1
    raise RuntimeError('unterminated Nginx block')


def server_blocks(text: str):
    for match in re.finditer(r'(?m)^\s*server\s*\{', text):
        opening = text.find('{', match.start(), match.end())
        end = block_end(text, opening)
        yield match.start(), end, text[match.start():end]


def has_tls_listener(block: str) -> bool:
    return bool(re.search(
        r'(?m)^\s*listen\s+(?:[0-9.]+:|\[[^\]]+\]:)?443\b[^;]*\bssl\b[^;]*;',
        block,
    ))


def select_server(text: str) -> tuple[int, int, str]:
    tls = []
    for start, end, block in server_blocks(text):
        if not has_tls_listener(block):
            continue
        tls.append((start, end, block))
        names = re.findall(r'(?m)^\s*server_name\s+([^;]+);', block)
        if names and HOST in names[0].split():
            return start, end, block
    if len(tls) == 1:
        return tls[0]
    if not tls:
        raise RuntimeError('no TLS Nginx server block was found')
    raise RuntimeError(
        f'no TLS server_name matches {HOST!r} and multiple TLS vhosts exist'
    )


def ensure_server_name(block: str) -> str:
    match = re.search(r'(?m)^(\s*)server_name\s+([^;]+);', block)
    if not match:
        raise RuntimeError('server_name directive was not found in selected TLS vhost')
    names = match.group(2).split()
    if HOST in names:
        return block
    replacement = f'{match.group(1)}server_name {HOST} {" ".join(names)};'
    return block[:match.start()] + replacement + block[match.end():]


def add_server_hsts(block: str) -> str:
    lines = block.splitlines(keepends=True)
    depth = 0
    server_name_index = None
    for index, line in enumerate(lines):
        current_depth = depth
        stripped = line.strip()
        if current_depth == 1 and stripped.startswith('server_name '):
            server_name_index = index
        if current_depth == 1 and stripped.startswith('add_header Strict-Transport-Security '):
            return block
        depth += line.count('{') - line.count('}')
    if server_name_index is None:
        raise RuntimeError('server_name directive was not found in selected TLS vhost')
    indent = re.match(r'^(\s*)', lines[server_name_index]).group(1)
    lines.insert(server_name_index + 1, f'{indent}{HSTS}\n')
    return ''.join(lines)


def add_location_hsts(block: str) -> str:
    matches: list[tuple[int, int, str]] = []
    for match in re.finditer(r'(?m)^\s*location\s+[^\n{]+\{', block):
        opening = block.find('{', match.start(), match.end())
        end = block_end(block, opening)
        location = block[match.start():end]
        if (
            'proxy_pass http://127.0.0.1:3082' in location
            and 'add_header Access-Control-Allow-Origin' in location
        ):
            matches.append((match.start(), end, location))

    for start, end, location in reversed(matches):
        if HSTS in location:
            continue
        proxy = re.search(r'(?m)^(\s*)proxy_pass\s+http://127\.0\.0\.1:3082\s*;', location)
        if not proxy:
            raise RuntimeError('3082 location has no canonical proxy_pass line')
        insertion = proxy.start()
        indent = proxy.group(1)
        location = location[:insertion] + f'{indent}{HSTS}\n\n' + location[insertion:]
        block = block[:start] + location + block[end:]
    return block


def update_nginx(path: Path) -> None:
    text = path.read_text(encoding='utf-8')
    start, end, block = select_server(text)
    block = ensure_server_name(block)
    block = add_server_hsts(block)
    block = add_location_hsts(block)
    path.write_text(text[:start] + block + text[end:], encoding='utf-8')


update_env(ENV_PATH)
update_nginx(CONF_PATH)

for key in ('APP_PUBLIC_URL', 'SMARTYARD_PUBLIC_BASE_URL', 'CORS_ORIGIN'):
    expected = f'{key}={ORIGIN}'
    actual = ENV_PATH.read_text(encoding='utf-8').splitlines().count(expected)
    if actual != 1:
        raise RuntimeError(f'{expected!r} count={actual}, expected=1')

nginx_text = CONF_PATH.read_text(encoding='utf-8')
if HSTS not in nginx_text:
    raise RuntimeError('HSTS header was not installed')

print(f'public_origin={ORIGIN}')
print(f'public_host={HOST}')
print(f'hsts={HSTS}')
PY

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN passed"
  echo "env_file=$ENV_FILE"
  echo "site_conf=$SITE_CONF"
  echo "SmartYard-Vue changed=false"
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_DIR/$STAMP"
install -d -m 0700 "$BACKUP"
cp -a "$ENV_FILE" "$BACKUP/app.env.before"
cp -aL "$SITE_CONF" "$BACKUP/newdomofon-video.conf.before"

rollback() {
  local rc=$?
  trap - ERR
  echo "Public HTTPS repair failed; restoring backup $BACKUP" >&2
  cp -a "$BACKUP/app.env.before" "$ENV_FILE"
  cp -a "$BACKUP/newdomofon-video.conf.before" "$SITE_CONF"
  ln -sfn "$SITE_CONF" "$ENABLED_CONF"
  nginx -t || true
  systemctl reload nginx || true
  systemctl restart newdomofon-video-backend.service || true
  systemctl restart newdomofon-smartyard-compat.service || true
  exit "$rc"
}
trap rollback ERR

cp -a "$WORK_ENV" "$ENV_FILE"
cp -a "$WORK_CONF" "$SITE_CONF"
ln -sfn "$SITE_CONF" "$ENABLED_CONF"

nginx -t
systemctl reload nginx
systemctl restart newdomofon-video-backend.service
systemctl restart newdomofon-smartyard-compat.service

systemctl is-active --quiet nginx.service
systemctl is-active --quiet newdomofon-video-backend.service
systemctl is-active --quiet newdomofon-smartyard-compat.service

VERIFY_SCRIPT="/opt/newdomofon-video-master/scripts/verify-smartyard-public-cors.sh"
[[ -x "$VERIFY_SCRIPT" ]] || VERIFY_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/verify-smartyard-public-cors.sh"

VERIFY_ARGS=(
  "BASE_URL=$PUBLIC_ORIGIN"
  "ORIGIN=$CORS_TEST_ORIGIN"
)
if [[ -n "$PROBE_ADDRESS" ]]; then
  VERIFY_ARGS+=("PROBE_ADDRESS=$PROBE_ADDRESS")
fi

env "${VERIFY_ARGS[@]}" bash "$VERIFY_SCRIPT"

HSTS_HEADERS="$(mktemp)"
CURL_ARGS=(-ksS --max-time 10 -D "$HSTS_HEADERS" -o /dev/null)
if [[ -n "$PROBE_ADDRESS" ]]; then
  CURL_ARGS+=(--resolve "$PUBLIC_HOST:$PUBLIC_PORT:$PROBE_ADDRESS")
fi
curl "${CURL_ARGS[@]}" "$PUBLIC_ORIGIN/"

tr -d '\r' < "$HSTS_HEADERS" |
  grep -Eiq "^Strict-Transport-Security:[[:space:]]*max-age=$HSTS_MAX_AGE([[:space:]]*;.*)?$" ||
  fail "HSTS header was not returned by $PUBLIC_ORIGIN/"
rm -f "$HSTS_HEADERS"

trap - ERR

echo "Public HTTPS origin repair completed"
echo "origin=$PUBLIC_ORIGIN"
echo "backup=$BACKUP"

#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SITE_CONF="${SITE_CONF:-/etc/nginx/sites-available/newdomofon-video.conf}"
ENABLED_CONF="${ENABLED_CONF:-/etc/nginx/sites-enabled/newdomofon-video.conf}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/newdomofon-video/public-https}"
DOMAIN="${DOMAIN:-new-video.domofon-37.ru}"
PROBE_ADDRESS="${PROBE_ADDRESS:-}"
HSTS_MAX_AGE="${HSTS_MAX_AGE:-31536000}"
DRY_RUN="false"

usage() {
  cat <<'EOF'
Repair NewDomofon public media URLs after HTTPS is enabled.

This script changes only the NewDomofon master:
- APP_PUBLIC_URL and SMARTYARD_PUBLIC_BASE_URL become https://<domain>;
- the TLS Nginx vhost emits HSTS on the root and media/event locations;
- backend, SmartYard compatibility gateway, and Nginx are restarted/reloaded;
- HTTPS CORS and HSTS are verified locally.

Usage:
  sudo bash scripts/repair-public-https-origin.sh [options]

Options:
  --domain NAME          Public media hostname
  --probe-address IP     Local address where Nginx listens on 443
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

while (($#)); do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --probe-address) PROBE_ADDRESS="${2:-}"; shift 2 ;;
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

[[ -n "$DOMAIN" ]] || fail "domain is empty"
[[ "$HSTS_MAX_AGE" =~ ^[0-9]+$ ]] || fail "HSTS max-age must be an integer"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

if [[ "$DRY_RUN" != "true" ]]; then
  [[ "$(id -u)" -eq 0 ]] || fail "Run as root"
  command -v nginx >/dev/null 2>&1 || fail "nginx is required"
  command -v curl >/dev/null 2>&1 || fail "curl is required"
fi

[[ -f "$ENV_FILE" ]] || fail "environment file not found: $ENV_FILE"
[[ -f "$SITE_CONF" ]] || fail "Nginx site config not found: $SITE_CONF"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

WORK_ENV="$TMP_DIR/app.env"
WORK_CONF="$TMP_DIR/newdomofon-video.conf"
cp -a "$ENV_FILE" "$WORK_ENV"
cp -aL "$SITE_CONF" "$WORK_CONF"

python3 - "$WORK_ENV" "$WORK_CONF" "$DOMAIN" "$HSTS_MAX_AGE" <<'PY'
from pathlib import Path
import re
import sys

ENV_PATH = Path(sys.argv[1])
CONF_PATH = Path(sys.argv[2])
DOMAIN = sys.argv[3]
MAX_AGE = sys.argv[4]
ORIGIN = f"https://{DOMAIN}"
HSTS = f'add_header Strict-Transport-Security "max-age={MAX_AGE}" always;'


def update_env(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    wanted = {
        "APP_PUBLIC_URL": ORIGIN,
        "SMARTYARD_PUBLIC_BASE_URL": ORIGIN,
    }
    seen: set[str] = set()
    output: list[str] = []
    for line in lines:
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
        if match and match.group(1) in wanted:
            key = match.group(1)
            if key not in seen:
                output.append(f"{key}={wanted[key]}")
                seen.add(key)
            continue
        output.append(line)
    for key, value in wanted.items():
        if key not in seen:
            output.append(f"{key}={value}")
    path.write_text("\n".join(output).rstrip("\n") + "\n", encoding="utf-8")


def block_end(source: str, opening: int) -> int:
    depth = 0
    for index in range(opening, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    raise RuntimeError("unterminated Nginx block")


def server_for_domain(text: str) -> tuple[int, int, str]:
    for match in re.finditer(r"(?m)^\s*server\s*\{", text):
        opening = text.find("{", match.start(), match.end())
        end = block_end(text, opening)
        block = text[match.start():end]
        names = re.findall(r"(?m)^\s*server_name\s+([^;]+);", block)
        if names and DOMAIN in names[0].split():
            return match.start(), end, block
    raise RuntimeError(f"Nginx server block for {DOMAIN} was not found")


def has_tls_listener(block: str) -> bool:
    return bool(re.search(
        r"(?m)^\s*listen\s+(?:[0-9.]+:|\[[^\]]+\]:)?443\b[^;]*\bssl\b[^;]*;",
        block,
    ))


def add_server_hsts(block: str) -> str:
    lines = block.splitlines(keepends=True)
    depth = 0
    server_hsts = False
    server_name_index = None
    for index, line in enumerate(lines):
        current_depth = depth
        stripped = line.strip()
        if current_depth == 1 and stripped.startswith("server_name "):
            server_name_index = index
        if current_depth == 1 and stripped.startswith("add_header Strict-Transport-Security "):
            server_hsts = True
        depth += line.count("{") - line.count("}")
    if server_hsts:
        return block
    if server_name_index is None:
        raise RuntimeError("server_name directive was not found in selected server block")
    indent = re.match(r"^(\s*)", lines[server_name_index]).group(1)
    lines.insert(server_name_index + 1, f"{indent}{HSTS}\n")
    return "".join(lines)


def add_location_hsts(block: str) -> str:
    matches: list[tuple[int, int, str]] = []
    for match in re.finditer(r"(?m)^\s*location\s+[^\n{]+\{", block):
        opening = block.find("{", match.start(), match.end())
        end = block_end(block, opening)
        location = block[match.start():end]
        if (
            "proxy_pass http://127.0.0.1:3082" in location
            and "add_header Access-Control-Allow-Origin" in location
        ):
            matches.append((match.start(), end, location))

    for start, end, location in reversed(matches):
        if HSTS in location:
            continue
        proxy = re.search(r"(?m)^(\s*)proxy_pass\s+http://127\.0\.0\.1:3082\s*;", location)
        if not proxy:
            raise RuntimeError("3082 location has no canonical proxy_pass line")
        insertion = proxy.start()
        indent = proxy.group(1)
        location = location[:insertion] + f"{indent}{HSTS}\n\n" + location[insertion:]
        block = block[:start] + location + block[end:]
    return block


def update_nginx(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    start, end, block = server_for_domain(text)
    if not has_tls_listener(block):
        raise RuntimeError(
            f"TLS listener for {DOMAIN}:443 was not found; enable HTTPS before applying HSTS"
        )
    block = add_server_hsts(block)
    block = add_location_hsts(block)
    path.write_text(text[:start] + block + text[end:], encoding="utf-8")


update_env(ENV_PATH)
update_nginx(CONF_PATH)

for key in ("APP_PUBLIC_URL", "SMARTYARD_PUBLIC_BASE_URL"):
    expected = f"{key}={ORIGIN}"
    actual = ENV_PATH.read_text(encoding="utf-8").splitlines().count(expected)
    if actual != 1:
        raise RuntimeError(f"{expected!r} count={actual}, expected=1")

nginx_text = CONF_PATH.read_text(encoding="utf-8")
if HSTS not in nginx_text:
    raise RuntimeError("HSTS header was not installed")

print(f"public_origin={ORIGIN}")
print(f"hsts={HSTS}")
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

install -o root -g root -m 0640 "$WORK_ENV" "$ENV_FILE"
install -o root -g root -m 0644 "$WORK_CONF" "$SITE_CONF"
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
  "BASE_URL=https://$DOMAIN"
  "ORIGIN=https://test.domofon-37.ru"
)
if [[ -n "$PROBE_ADDRESS" ]]; then
  VERIFY_ARGS+=("PROBE_ADDRESS=$PROBE_ADDRESS")
fi

env "${VERIFY_ARGS[@]}" bash "$VERIFY_SCRIPT"

HSTS_HEADERS="$(mktemp)"
CURL_ARGS=(-ksS --max-time 10 -D "$HSTS_HEADERS" -o /dev/null)
if [[ -n "$PROBE_ADDRESS" ]]; then
  CURL_ARGS+=(--resolve "$DOMAIN:443:$PROBE_ADDRESS")
fi
curl "${CURL_ARGS[@]}" "https://$DOMAIN/"

tr -d '\r' < "$HSTS_HEADERS" |
  grep -Eiq "^Strict-Transport-Security:[[:space:]]*max-age=$HSTS_MAX_AGE([[:space:]]*;.*)?$" ||
  fail "HSTS header was not returned by https://$DOMAIN/"
rm -f "$HSTS_HEADERS"

trap - ERR

echo "Public HTTPS origin repair completed"
echo "origin=https://$DOMAIN"
echo "backup=$BACKUP"
echo "Open https://$DOMAIN/ once in each browser profile, then reload SmartYard."

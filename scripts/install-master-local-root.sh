#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALLER_VERSION="2026.07-local-root-v1"

SOURCE_DIR="${SOURCE_DIR:-}"
PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
MASTER_DOMAIN="${MASTER_DOMAIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
ADMIN_LOGIN="${ADMIN_LOGIN:-admin}"
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
TLS_MODE="${TLS_MODE:-auto}"
REGENERATE_SECRETS="${REGENERATE_SECRETS:-false}"
INSTALL_RTSP="${INSTALL_RTSP:-true}"
REQUIRE_RTSP="${REQUIRE_RTSP:-false}"
MEDIAMTX_ARCHIVE="${MEDIAMTX_ARCHIVE:-}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-/opt/newdomofon-video-migration-backups/local-root-master-${STAMP}}"
LOG_FILE="${LOG_FILE:-/root/newdomofon-master-local-root-${STAMP}.log}"
SUMMARY_FILE="${SUMMARY_FILE:-/root/newdomofon-master-access.txt}"
JSON_FILE="${JSON_FILE:-/root/newdomofon-master-access.json}"
CURRENT_STEP="initialization"
OLD_PROJECT_BACKUP=""

usage() {
  cat <<'EOF'
NewDomofon Video Master local root installer

Usage:
  bash scripts/install-master-local-root.sh [options]

The extracted project must be inside /root. No git commands are used.
No custom Linux users are created. NewDomofon application services run as root.
PostgreSQL and Nginx keep their standard package service accounts.

Options:
  --source-dir PATH          Extracted project directory. Auto-detected in /root.
  --domain DOMAIN_OR_IP      Public master domain or IP.
  --email EMAIL              Let's Encrypt contact email.
  --admin-login LOGIN        Web administrator login. Default: admin.
  --no-tls                   Do not request a certificate.
  --tls                      Require/attempt TLS when a DNS name is used.
  --regenerate-secrets       Generate new application secrets and passwords.
  --skip-rtsp                Do not install MediaMTX.
  --require-rtsp             Fail the whole installation if RTSP cannot be installed.
  --mediamtx-archive PATH    Local mediamtx_*_linux_<arch>.tar.gz package.
  -h, --help                 Show this help.

Examples:
  cd /root/newdomofon-video-master-main
  bash scripts/install-master-local-root.sh

  bash /root/newdomofon-video-master-main/scripts/install-master-local-root.sh \
    --source-dir /root/newdomofon-video-master-main \
    --domain video.example.ru \
    --email admin@example.ru

For a server without public DNS:
  bash scripts/install-master-local-root.sh --domain 10.106.1.30 --no-tls
EOF
}

while (($#)); do
  case "$1" in
    --source-dir)
      SOURCE_DIR="${2:-}"
      shift 2
      ;;
    --domain)
      MASTER_DOMAIN="${2:-}"
      shift 2
      ;;
    --email)
      CERTBOT_EMAIL="${2:-}"
      shift 2
      ;;
    --admin-login)
      ADMIN_LOGIN="${2:-}"
      shift 2
      ;;
    --no-tls)
      TLS_MODE=no
      shift
      ;;
    --tls)
      TLS_MODE=yes
      shift
      ;;
    --regenerate-secrets)
      REGENERATE_SECRETS=true
      shift
      ;;
    --skip-rtsp)
      INSTALL_RTSP=false
      shift
      ;;
    --require-rtsp)
      REQUIRE_RTSP=true
      shift
      ;;
    --mediamtx-archive)
      MEDIAMTX_ARCHIVE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this installer as root." >&2
  exit 77
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

on_error() {
  local rc=$?
  local line="${1:-unknown}"
  trap - ERR
  echo
  echo "============================================================"
  echo "INSTALLATION FAILED"
  echo "Step:      $CURRENT_STEP"
  echo "Line:      $line"
  echo "Exit code: $rc"
  echo "Log:       $LOG_FILE"
  echo "Backup:    $BACKUP_DIR"
  [[ -n "$OLD_PROJECT_BACKUP" ]] && echo "Old project: $OLD_PROJECT_BACKUP"
  echo "============================================================"
  systemctl --no-pager --full status newdomofon-video-backend.service 2>/dev/null || true
  journalctl -u newdomofon-video-backend.service -n 120 --no-pager 2>/dev/null || true
  exit "$rc"
}
trap 'on_error $LINENO' ERR

log_step() {
  CURRENT_STEP="$1"
  echo
  echo "============================================================"
  echo "$CURRENT_STEP"
  echo "============================================================"
}

is_true() {
  [[ "${1:-}" =~ ^(1|true|yes|on)$ ]]
}

is_project_root() {
  local root="$1"
  [[ -d "$root" &&
     -f "$root/backend/package.json" &&
     -f "$root/frontend/package.json" &&
     -f "$root/deploy/nginx/newdomofon-video.conf" &&
     -f "$root/deploy/systemd/newdomofon-video-backend.service" &&
     -f "$root/smartyard-compat-proxy/server-formats-gateway.js" ]]
}

discover_source_dir() {
  local script_dir script_root candidate backend_file
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  script_root="$(cd "$script_dir/.." && pwd)"

  if [[ -n "$SOURCE_DIR" ]]; then
    candidate="$(readlink -f "$SOURCE_DIR")"
    is_project_root "$candidate" || {
      echo "Specified source is not a NewDomofon Video Master project: $candidate" >&2
      exit 65
    }
    SOURCE_DIR="$candidate"
    return
  fi

  if [[ "$script_root" == /root/* || "$script_root" == /root ]] &&
     is_project_root "$script_root"; then
    SOURCE_DIR="$script_root"
    return
  fi

  backend_file="$(
    find /root -mindepth 2 -maxdepth 7 -type f \
      -path '*/backend/package.json' \
      -not -path '/root/newdomofon-local-install.*/*' \
      -printf '%T@ %p\n' 2>/dev/null |
      sort -nr |
      while read -r _ path; do
        candidate="$(dirname "$(dirname "$path")")"
        if is_project_root "$candidate"; then
          printf '%s\n' "$candidate"
          break
        fi
      done
  )"

  [[ -n "$backend_file" ]] || {
    echo "No extracted NewDomofon Video Master project was found under /root." >&2
    echo "Use --source-dir /root/<project-folder>." >&2
    exit 66
  }

  SOURCE_DIR="$(readlink -f "$backend_file")"
}

primary_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

normalize_domain() {
  MASTER_DOMAIN="${MASTER_DOMAIN#http://}"
  MASTER_DOMAIN="${MASTER_DOMAIN#https://}"
  MASTER_DOMAIN="${MASTER_DOMAIN%%/*}"
  MASTER_DOMAIN="${MASTER_DOMAIN%/}"
}

is_ip_address() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress
import sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
}

env_value() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -1
}

set_env_value() {
  local key="$1"
  local value="$2"
  local file="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

random_hex() {
  openssl rand -hex "${1:-32}"
}

preserve_secret() {
  local key="$1"
  local bytes="$2"
  local min_length="$3"
  local existing=""

  if [[ -f "$ENV_FILE" ]] && ! is_true "$REGENERATE_SECRETS"; then
    existing="$(env_value "$key" "$ENV_FILE")"
  fi

  if [[ ${#existing} -ge $min_length ]] &&
     [[ ! "$existing" =~ ^(CHANGE|change|REPLACE|replace|dev-secret) ]]; then
    printf '%s' "$existing"
  else
    random_hex "$bytes"
  fi
}

wait_http_json_ok() {
  local url="$1"
  local output="$2"
  local timeout="${3:-60}"
  local service="${4:-}"

  for ((second=0; second<timeout; second++)); do
    if curl -fsS --max-time 3 "$url" >"$output" 2>/dev/null &&
       jq -e '.ok == true' "$output" >/dev/null 2>&1; then
      echo "Health check passed after ${second}s: $url"
      return 0
    fi
    sleep 1
  done

  echo "Health check failed: $url" >&2
  if [[ -n "$service" ]]; then
    systemctl --no-pager --full status "$service" >&2 || true
    journalctl -u "$service" -n 300 --no-pager >&2 || true
  fi
  return 1
}

ensure_root_unit() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  if grep -q '^User=' "$file"; then
    sed -i 's/^User=.*/User=root/' "$file"
  else
    sed -i '/^\[Service\]/a User=root' "$file"
  fi

  if grep -q '^Group=' "$file"; then
    sed -i 's/^Group=.*/Group=root/' "$file"
  else
    sed -i '/^\[Service\]/a Group=root' "$file"
  fi
}

discover_source_dir

if [[ -z "$MASTER_DOMAIN" ]]; then
  if [[ -t 0 ]]; then
    DEFAULT_DOMAIN="$(hostname -f 2>/dev/null || true)"
    [[ -n "$DEFAULT_DOMAIN" && "$DEFAULT_DOMAIN" != localhost ]] ||
      DEFAULT_DOMAIN="$(primary_ip)"
    read -r -p "Master domain or IP [${DEFAULT_DOMAIN}]: " MASTER_DOMAIN
    MASTER_DOMAIN="${MASTER_DOMAIN:-$DEFAULT_DOMAIN}"
  else
    echo "MASTER_DOMAIN or --domain is required for non-interactive installation." >&2
    exit 64
  fi
fi

normalize_domain
[[ -n "$MASTER_DOMAIN" ]] || {
  echo "Master domain/IP is empty." >&2
  exit 64
}
[[ "$MASTER_DOMAIN" =~ ^[A-Za-z0-9._:-]+$ ]] || {
  echo "Invalid master domain/IP: $MASTER_DOMAIN" >&2
  exit 64
}
[[ "$ADMIN_LOGIN" =~ ^[A-Za-z0-9_.@-]+$ ]] || {
  echo "Invalid administrator login." >&2
  exit 64
}
case "$TLS_MODE" in
  auto|yes|no) ;;
  *)
    echo "TLS mode must be auto, yes or no." >&2
    exit 64
    ;;
esac

if [[ -z "$CERTBOT_EMAIL" && -t 0 && "$TLS_MODE" != no ]] &&
   ! is_ip_address "$MASTER_DOMAIN"; then
  read -r -p "Email for Let's Encrypt (optional): " CERTBOT_EMAIL
fi

install -d -o root -g root -m 0700 "$BACKUP_DIR"

echo "NewDomofon Video Master monolithic local installer"
echo "Installer version: $INSTALLER_VERSION"
echo "Source:            $SOURCE_DIR"
echo "Production:        $PROJECT_DIR"
echo "Domain/IP:         $MASTER_DOMAIN"
echo "Timezone:          $TIMEZONE"
echo "TLS mode:          $TLS_MODE"
echo "Application user:  root"
echo "Custom users:      none"
echo "Log:               $LOG_FILE"
echo "Backup:            $BACKUP_DIR"

log_step "1/15 Installing Debian packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates curl gnupg rsync jq nginx ffmpeg \
  postgresql postgresql-contrib build-essential openssl python3 \
  certbot python3-certbot-nginx systemd-timesyncd tar gzip xz-utils

for command in curl jq rsync openssl python3 psql pg_dump runuser nginx ffmpeg systemctl; do
  command -v "$command" >/dev/null || {
    echo "Required command was not installed: $command" >&2
    exit 69
  }
done

if ! command -v node >/dev/null 2>&1 ||
   ! node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22 || (a===22 && b>=12) ? 0 : 1)' 2>/dev/null; then
  echo "Installing Node.js 22 from NodeSource..."
  curl -fsSL --retry 8 --retry-all-errors --connect-timeout 20 \
    https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi

node --version
npm --version
psql --version
nginx -v
ffmpeg -version | head -1

log_step "2/15 Configuring Moscow time and system services"
timedatectl set-timezone "$TIMEZONE"
systemctl enable --now systemd-timesyncd || true
systemctl enable --now postgresql
systemctl enable --now nginx
date '+%Y-%m-%d %H:%M:%S %Z %z'

log_step "3/15 Backing up current installation"
for path in \
  "$ENV_FILE" \
  /etc/nginx/sites-available/newdomofon-video.conf \
  /etc/systemd/system/newdomofon-video-backend.service \
  /etc/systemd/system/newdomofon-public-events-proxy.service \
  /etc/systemd/system/newdomofon-smartyard-compat.service \
  /etc/systemd/system/newdomofon-video-rtsp-gateway.service \
  /etc/newdomofon-video/mediamtx.yml; do
  if [[ -e "$path" ]]; then
    safe_name="$(echo "$path" | sed 's#^/##; s#/#__#g')"
    cp -a "$path" "$BACKUP_DIR/$safe_name.before"
  fi
done

DB_PREEXISTS="$(
  runuser -u postgres -- psql -d postgres -Atqc \
    "SELECT 1 FROM pg_database WHERE datname='newdomofon_video';"
)"
if [[ "$DB_PREEXISTS" == 1 ]]; then
  runuser -u postgres -- pg_dump -Fc -d newdomofon_video \
    >"$BACKUP_DIR/postgresql-before.dump"
fi

for service in \
  newdomofon-video-rtsp-gateway.service \
  newdomofon-smartyard-compat.service \
  newdomofon-public-events-proxy.service \
  newdomofon-video-backend.service; do
  systemctl stop "$service" 2>/dev/null || true
done

log_step "4/15 Installing local project source without Git"
STAGING_DIR="${PROJECT_DIR}.staging-${STAMP}"
rm -rf "$STAGING_DIR"
install -d -o root -g root -m 0700 "$STAGING_DIR"

rsync -a --delete \
  --exclude '/.git/' \
  --exclude '/.github/' \
  --exclude '**/node_modules/' \
  --exclude '**/dist/' \
  --exclude '/backups/' \
  --exclude '*.log' \
  "$SOURCE_DIR/" "$STAGING_DIR/"

is_project_root "$STAGING_DIR" || {
  echo "Copied source does not contain the expected project structure." >&2
  exit 74
}

chown -R root:root "$STAGING_DIR"
chmod -R u+rwX,go-rwx "$STAGING_DIR"
chmod 0700 "$STAGING_DIR"

if [[ -e "$PROJECT_DIR" ]]; then
  OLD_PROJECT_BACKUP="${PROJECT_DIR}.before-local-root-${STAMP}"
  mv "$PROJECT_DIR" "$OLD_PROJECT_BACKUP"
fi
mv "$STAGING_DIR" "$PROJECT_DIR"

SOURCE_FINGERPRINT="$(
  {
    sha256sum "$PROJECT_DIR/backend/package.json"
    [[ -f "$PROJECT_DIR/backend/package-lock.json" ]] &&
      sha256sum "$PROJECT_DIR/backend/package-lock.json"
    sha256sum "$PROJECT_DIR/frontend/package.json"
    [[ -f "$PROJECT_DIR/frontend/package-lock.json" ]] &&
      sha256sum "$PROJECT_DIR/frontend/package-lock.json"
  } | sha256sum | awk '{print $1}'
)"

echo "Installed local source fingerprint: $SOURCE_FINGERPRINT"
[[ -n "$OLD_PROJECT_BACKUP" ]] && echo "Previous project saved as: $OLD_PROJECT_BACKUP"

log_step "5/15 Preparing PostgreSQL credentials and application secrets"
install -d -o root -g root -m 0700 "$(dirname "$ENV_FILE")"

DB_PASSWORD=""
if [[ -f "$ENV_FILE" ]] && ! is_true "$REGENERATE_SECRETS"; then
  DB_PASSWORD="$(
    python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
from urllib.parse import urlparse, unquote
import sys

value = ""
for raw in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if raw.startswith("DATABASE_URL="):
        value = raw.split("=", 1)[1].strip().strip('"').strip("'")
if value:
    parsed = urlparse(value)
    if parsed.password:
        print(unquote(parsed.password))
PY
  )"
fi
[[ "$DB_PASSWORD" =~ ^[A-Za-z0-9._~-]{16,}$ ]] || DB_PASSWORD="$(random_hex 24)"

JWT_SECRET="$(preserve_secret JWT_SECRET 48 32)"
ADMIN_PASSWORD="$(preserve_secret ADMIN_PASSWORD 24 16)"
NODE_REGISTRATION_TOKEN="$(preserve_secret NODE_REGISTRATION_TOKEN 32 32)"
INTERNAL_DVR_SECRET="$(preserve_secret INTERNAL_DVR_SECRET 32 32)"
MANAGED_CAMERA_TOKEN_SECRET="$(preserve_secret MANAGED_CAMERA_TOKEN_SECRET 48 32)"
RTSP_GATEWAY_SHARED_SECRET="$(preserve_secret RTSP_GATEWAY_SHARED_SECRET 32 32)"
RTSP_RELAY_PUBLISH_SECRET="$(preserve_secret RTSP_RELAY_PUBLISH_SECRET 32 32)"

if [[ -f "$ENV_FILE" ]] && ! is_true "$REGENERATE_SECRETS"; then
  EXISTING_ADMIN_LOGIN="$(env_value ADMIN_LOGIN "$ENV_FILE")"
  if [[ "$ADMIN_LOGIN" == admin && -n "$EXISTING_ADMIN_LOGIN" ]]; then
    ADMIN_LOGIN="$EXISTING_ADMIN_LOGIN"
  fi
fi

log_step "6/15 Configuring PostgreSQL database"
ROLE_EXISTS="$(
  runuser -u postgres -- psql -d postgres -Atqc \
    "SELECT 1 FROM pg_roles WHERE rolname='newdomofon';"
)"
if [[ "$ROLE_EXISTS" != 1 ]]; then
  runuser -u postgres -- createuser --login newdomofon
fi

runuser -u postgres -- psql -d postgres \
  -v ON_ERROR_STOP=1 \
  -v db_password="$DB_PASSWORD" <<'SQL'
ALTER ROLE newdomofon WITH LOGIN PASSWORD :'db_password';
SQL

DB_EXISTS="$(
  runuser -u postgres -- psql -d postgres -Atqc \
    "SELECT 1 FROM pg_database WHERE datname='newdomofon_video';"
)"
if [[ "$DB_EXISTS" != 1 ]]; then
  runuser -u postgres -- createdb --owner=newdomofon newdomofon_video
fi

runuser -u postgres -- psql -d postgres -v ON_ERROR_STOP=1 <<'SQL'
ALTER DATABASE newdomofon_video OWNER TO newdomofon;
GRANT ALL PRIVILEGES ON DATABASE newdomofon_video TO newdomofon;
SQL

runuser -u postgres -- psql -d newdomofon_video -v ON_ERROR_STOP=1 <<'SQL'
ALTER SCHEMA public OWNER TO newdomofon;
GRANT ALL ON SCHEMA public TO newdomofon;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO newdomofon;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO newdomofon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL PRIVILEGES ON TABLES TO newdomofon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL PRIVILEGES ON SEQUENCES TO newdomofon;
SQL

PGPASSWORD="$DB_PASSWORD" psql \
  -h 127.0.0.1 \
  -U newdomofon \
  -d newdomofon_video \
  -v ON_ERROR_STOP=1 \
  -Atqc 'SELECT current_database(), current_user;' \
  >"$BACKUP_DIR/postgresql-connect-test.txt"

log_step "7/15 Writing root-only application environment"
PUBLIC_SCHEME=http
PUBLIC_BASE_URL="http://${MASTER_DOMAIN}"
DATABASE_URL="postgres://newdomofon:${DB_PASSWORD}@127.0.0.1:5432/newdomofon_video"

cat >"$ENV_FILE" <<EOF
NODE_ENV=production
BACKEND_PORT=3000
DATABASE_URL=${DATABASE_URL}
JWT_SECRET=${JWT_SECRET}
MANAGED_CAMERA_TOKEN_SECRET=${MANAGED_CAMERA_TOKEN_SECRET}
ADMIN_LOGIN=${ADMIN_LOGIN}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
CORS_ORIGIN=${PUBLIC_BASE_URL}
TRUST_PROXY=true

SMARTYARD_PUBLIC_BASE_URL=${PUBLIC_BASE_URL}
APP_PUBLIC_URL=${PUBLIC_BASE_URL}
MEDIA_PUBLIC_BASE_URL=/api/media
PLAYBACK_TOKEN_TTL_SECONDS=900

NODE_REGISTRATION_TOKEN=${NODE_REGISTRATION_TOKEN}
INTERNAL_DVR_SECRET=${INTERNAL_DVR_SECRET}

MASTER_APPLICATION_RUNTIME_USER=root
MASTER_DISK_GUARD_PATHS=/:/var/lib/postgresql:/var/log/newdomofon-video
MASTER_DISK_MIN_FREE_BYTES=2147483648
MASTER_DISK_MIN_FREE_PERCENT=5
MASTER_DISK_RESUME_FREE_BYTES=4294967296
MASTER_DISK_RESUME_FREE_PERCENT=10
MASTER_DISK_MIN_FREE_INODES_PERCENT=5
MASTER_DISK_RESUME_FREE_INODES_PERCENT=8
MASTER_JOURNAL_MAX_SIZE=512M
MASTER_JOURNAL_MAX_AGE=7d
MASTER_DISK_STALE_TMP_MINUTES=60
MASTER_DISK_APT_CLEAN_ON_CRITICAL=true

PUBLIC_EVENTS_INCLUDE_PASSIVE=false
ONVIF_EVENT_SUPPRESS_REPEATED_STATE=true

DVR_ENGINE_URL=http://127.0.0.1:3010

RTSP_GATEWAY_ENABLED=false
RTSP_PUBLIC_HOST=${MASTER_DOMAIN}
RTSP_PUBLIC_PORT=8554
RTSP_AUTO_OPEN_FIREWALL=true
RTSP_MEDIAMTX_VERSION=
RTSP_GATEWAY_SHARED_SECRET=${RTSP_GATEWAY_SHARED_SECRET}
RTSP_RELAY_PUBLISH_SECRET=${RTSP_RELAY_PUBLISH_SECRET}
RTSP_GATEWAY_BACKEND_URL=http://127.0.0.1:3000
RTSP_RELAY_FFMPEG_LOGLEVEL=warning
EOF

chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"

# Build, migrations and seed must use the exact production environment that
# systemd will use later. The project does not read /etc/newdomofon-video/app.env
# automatically when npm commands are launched from a shell.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

log_step "8/15 Building backend, migrations and frontend"
cd "$PROJECT_DIR/backend"
npm ci --include=dev
npm run build
npm run migrate
npm run seed
npm prune --omit=dev

DATABASE_URL="$DATABASE_URL" \
ADMIN_LOGIN="$ADMIN_LOGIN" \
ADMIN_PASSWORD="$ADMIN_PASSWORD" \
node --input-type=module <<'NODE'
import bcrypt from 'bcryptjs';
import pg from 'pg';

const { Pool } = pg;
const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const hash = await bcrypt.hash(process.env.ADMIN_PASSWORD, 12);

await pool.query(
  `INSERT INTO users(login, password_hash, role, is_active)
   VALUES ($1, $2, 'super_admin', true)
   ON CONFLICT (login) DO UPDATE SET
     password_hash = EXCLUDED.password_hash,
     role = 'super_admin',
     is_active = true`,
  [process.env.ADMIN_LOGIN, hash],
);

await pool.query(
  `INSERT INTO camera_groups(name)
   VALUES ('Default')
   ON CONFLICT DO NOTHING`,
);

await pool.end();
NODE

cd "$PROJECT_DIR/frontend"
npm ci --include=dev
npm run build

install -d -o root -g root -m 0755 /var/www/newdomofon-video
rsync -a --delete "$PROJECT_DIR/frontend/dist/" /var/www/newdomofon-video/
chown -R root:root /var/www/newdomofon-video
find /var/www/newdomofon-video -type d -exec chmod 0755 {} +
find /var/www/newdomofon-video -type f -exec chmod 0644 {} +

if [[ -d "$PROJECT_DIR/public-events-proxy" ]]; then
  cd "$PROJECT_DIR/public-events-proxy"
  if [[ -f package-lock.json ]]; then
    npm ci --omit=dev
  else
    npm install --omit=dev
  fi
fi

chown -R root:root "$PROJECT_DIR"
chmod -R u+rwX,go-rwx "$PROJECT_DIR"
chmod 0700 "$PROJECT_DIR"

install -d -o root -g root -m 0755 \
  /var/lib/newdomofon-video \
  /var/cache/newdomofon-video \
  /var/cache/newdomofon-video/smartyard-preview \
  /var/cache/newdomofon-video/install \
  /var/log/newdomofon-video \
  /run/newdomofon-video

log_step "9/15 Installing root systemd services and Nginx"
install -d -o root -g root -m 0755 /etc/systemd/system
for unit in \
  newdomofon-video-backend.service \
  newdomofon-public-events-proxy.service \
  newdomofon-smartyard-compat.service; do
  source_unit="$PROJECT_DIR/deploy/systemd/$unit"
  [[ -f "$source_unit" ]] || {
    echo "Required systemd unit is missing: $source_unit" >&2
    exit 66
  }
  install -m 0644 "$source_unit" "/etc/systemd/system/$unit"
  ensure_root_unit "/etc/systemd/system/$unit"
done

install -m 0644 \
  "$PROJECT_DIR/deploy/nginx/newdomofon-video.conf" \
  /etc/nginx/sites-available/newdomofon-video.conf

sed -i \
  "0,/server_name[[:space:]]\\+_[[:space:]]*;/s//server_name ${MASTER_DOMAIN};/" \
  /etc/nginx/sites-available/newdomofon-video.conf

ln -sfn \
  /etc/nginx/sites-available/newdomofon-video.conf \
  /etc/nginx/sites-enabled/newdomofon-video.conf
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

systemctl daemon-reload
for service in \
  newdomofon-video-backend.service \
  newdomofon-public-events-proxy.service \
  newdomofon-smartyard-compat.service; do
  systemctl reset-failed "$service" 2>/dev/null || true
  systemctl enable "$service"
  systemctl restart "$service"
done

wait_http_json_ok \
  http://127.0.0.1:3000/api/health \
  /tmp/newdomofon-local-root-backend-health.json \
  90 \
  newdomofon-video-backend.service

wait_http_json_ok \
  http://127.0.0.1:3082/health \
  /tmp/newdomofon-local-root-gateway-health.json \
  90 \
  newdomofon-smartyard-compat.service

log_step "10/15 Installing master disk guard"
install -m 0755 \
  "$PROJECT_DIR/scripts/master-disk-guard.sh" \
  /usr/local/sbin/newdomofon-master-disk-guard

install -m 0644 \
  "$PROJECT_DIR/deploy/systemd/newdomofon-video-master-disk-guard.service" \
  /etc/systemd/system/newdomofon-video-master-disk-guard.service

install -m 0644 \
  "$PROJECT_DIR/deploy/systemd/newdomofon-video-master-disk-guard.timer" \
  /etc/systemd/system/newdomofon-video-master-disk-guard.timer

install -d -o root -g root -m 0755 /etc/systemd/journald.conf.d
if [[ -f "$PROJECT_DIR/deploy/journald/99-newdomofon-video.conf" ]]; then
  install -m 0644 \
    "$PROJECT_DIR/deploy/journald/99-newdomofon-video.conf" \
    /etc/systemd/journald.conf.d/99-newdomofon-video.conf
  systemctl try-restart systemd-journald.service || true
fi

systemctl daemon-reload
systemctl enable --now newdomofon-video-master-disk-guard.timer
systemctl start newdomofon-video-master-disk-guard.service || true

install_mediamtx() {
  local arch asset_arch tag asset tmp release_json asset_url asset_digest
  local expected_sha actual_sha checksum_url public_host rtsp_template auth_status
  local mediamtx_binary="/usr/local/bin/mediamtx"
  local version_file="/usr/local/share/newdomofon-video/mediamtx-version"
  local cache_dir="/var/cache/newdomofon-video/install"
  local config_file="/etc/newdomofon-video/mediamtx.yml"
  local relay_file="/usr/local/lib/newdomofon-video/rtsp-relay-on-demand.sh"
  local unit_file="/etc/systemd/system/newdomofon-video-rtsp-gateway.service"
  local rtsp_port=8554

  install -d -o root -g root -m 0755 \
    "$cache_dir" \
    /usr/local/bin \
    /usr/local/lib/newdomofon-video \
    /usr/local/share/newdomofon-video

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) asset_arch=amd64 ;;
    aarch64|arm64) asset_arch=arm64 ;;
    armv7l|armv7) asset_arch=armv7 ;;
    *)
      echo "Unsupported MediaMTX architecture: $arch" >&2
      return 65
      ;;
  esac

  tag=""
  if [[ -x "$mediamtx_binary" && -s "$version_file" && -z "$MEDIAMTX_ARCHIVE" ]]; then
    tag="$(tr -d '[:space:]' <"$version_file")"
    echo "Using already installed MediaMTX: $tag"
  else
    if [[ -z "$MEDIAMTX_ARCHIVE" ]]; then
      local search_roots=(/root "$cache_dir")
      [[ -d "$SOURCE_DIR/vendor" ]] && search_roots+=("$SOURCE_DIR/vendor")
      MEDIAMTX_ARCHIVE="$(
        find "${search_roots[@]}" \
          -maxdepth 3 -type f \
          -name "mediamtx_*_linux_${asset_arch}.tar.gz" \
          -printf '%T@ %p\n' 2>/dev/null |
          sort -nr |
          head -1 |
          cut -d' ' -f2-
      )"
    fi

    tmp="$(mktemp -d)"
    if [[ -n "$MEDIAMTX_ARCHIVE" && -f "$MEDIAMTX_ARCHIVE" ]]; then
      asset="$(basename "$MEDIAMTX_ARCHIVE")"
      tag="${asset#mediamtx_}"
      tag="${tag%_linux_${asset_arch}.tar.gz}"
      [[ -n "$tag" && "$tag" != "$asset" ]] || {
        rm -rf "$tmp"
        echo "Unexpected MediaMTX archive name: $asset" >&2
        return 64
      }
      cp -a "$MEDIAMTX_ARCHIVE" "$tmp/$asset"
      echo "Using local MediaMTX archive: $MEDIAMTX_ARCHIVE"
      if [[ -f "${MEDIAMTX_ARCHIVE}.sha256" ]]; then
        expected_sha="$(awk '{print $1; exit}' "${MEDIAMTX_ARCHIVE}.sha256")"
        actual_sha="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
        [[ "$actual_sha" == "$expected_sha" ]] || {
          rm -rf "$tmp"
          echo "Local MediaMTX SHA256 mismatch." >&2
          return 74
        }
      else
        echo "Local MediaMTX SHA256: $(sha256sum "$tmp/$asset" | awk '{print $1}')"
      fi
    else
      echo "No local MediaMTX package found; attempting network download..."
      release_json="$tmp/release.json"
      if ! curl -fsSL --retry 8 --retry-all-errors --connect-timeout 20 \
        -H 'accept: application/vnd.github+json' \
        -H 'user-agent: newdomofon-local-root-installer' \
        https://api.github.com/repos/bluenviron/mediamtx/releases/latest \
        >"$release_json"; then
        rm -rf "$tmp"
        return 69
      fi

      tag="$(jq -er '.tag_name' "$release_json")" || {
        rm -rf "$tmp"
        return 74
      }
      asset="mediamtx_${tag}_linux_${asset_arch}.tar.gz"
      asset_url="$(
        jq -er --arg name "$asset" \
          '.assets[] | select(.name == $name) | .browser_download_url' \
          "$release_json"
      )" || {
        rm -rf "$tmp"
        return 74
      }
      asset_digest="$(
        jq -r --arg name "$asset" \
          '.assets[] | select(.name == $name) | (.digest // empty)' \
          "$release_json"
      )"

      if ! curl -fL --retry 8 --retry-all-errors --connect-timeout 20 \
        "$asset_url" -o "$tmp/$asset"; then
        rm -rf "$tmp"
        return 69
      fi

      expected_sha=""
      if [[ "$asset_digest" == sha256:* ]]; then
        expected_sha="${asset_digest#sha256:}"
      else
        checksum_url="$(
          jq -r \
            '.assets[] | select(.name | test("(?i)(checksums|sha256)")) | .browser_download_url' \
            "$release_json" |
            head -1
        )"
        if [[ -n "$checksum_url" && "$checksum_url" != null ]]; then
          curl -fL --retry 4 --retry-all-errors --connect-timeout 20 \
            "$checksum_url" -o "$tmp/checksums.txt" || true
          if [[ -f "$tmp/checksums.txt" ]]; then
            expected_sha="$(
              awk -v name="$asset" \
                '$2 == name || $2 == "*" name {print $1; exit}' \
                "$tmp/checksums.txt"
            )"
          fi
        fi
      fi

      actual_sha="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
      if [[ -n "$expected_sha" && "$actual_sha" != "$expected_sha" ]]; then
        rm -rf "$tmp"
        echo "Downloaded MediaMTX SHA256 mismatch." >&2
        return 74
      fi
      [[ -n "$expected_sha" ]] || expected_sha="$actual_sha"

      cp -a "$tmp/$asset" "$cache_dir/$asset"
      printf '%s  %s\n' "$expected_sha" "$asset" \
        >"$cache_dir/$asset.sha256"
      chown root:root "$cache_dir/$asset" "$cache_dir/$asset.sha256"
      chmod 0600 "$cache_dir/$asset" "$cache_dir/$asset.sha256"
    fi

    tar -xzf "$tmp/$asset" -C "$tmp"
    [[ -x "$tmp/mediamtx" ]] || {
      rm -rf "$tmp"
      echo "MediaMTX binary is missing from archive." >&2
      return 74
    }

    install -m 0755 "$tmp/mediamtx" "$mediamtx_binary"
    printf '%s\n' "$tag" >"$version_file"
    chown root:root "$version_file"
    chmod 0644 "$version_file"
    rm -rf "$tmp"
  fi

  [[ -f "$PROJECT_DIR/scripts/rtsp-relay-on-demand.sh" ]] || {
    echo "RTSP relay script is missing from the project." >&2
    return 66
  }
  install -m 0755 \
    "$PROJECT_DIR/scripts/rtsp-relay-on-demand.sh" \
    "$relay_file"

  public_host="$MASTER_DOMAIN"
  if [[ "$public_host" == *:* && "$public_host" != \[*\] ]]; then
    public_host="[$public_host]"
  fi
  rtsp_template="rtsp://token:{token}@${public_host}:${rtsp_port}/{stream}"

  set_env_value RTSP_GATEWAY_ENABLED true "$ENV_FILE"
  set_env_value RTSP_PUBLIC_HOST "$public_host" "$ENV_FILE"
  set_env_value RTSP_PUBLIC_PORT "$rtsp_port" "$ENV_FILE"
  set_env_value RTSP_PUBLIC_URL_TEMPLATE "$rtsp_template" "$ENV_FILE"
  set_env_value RTSP_MEDIAMTX_VERSION "$tag" "$ENV_FILE"
  set_env_value RTSP_GATEWAY_SHARED_SECRET "$RTSP_GATEWAY_SHARED_SECRET" "$ENV_FILE"
  set_env_value RTSP_RELAY_PUBLISH_SECRET "$RTSP_RELAY_PUBLISH_SECRET" "$ENV_FILE"
  chown root:root "$ENV_FILE"
  chmod 0600 "$ENV_FILE"

  cat >"$config_file" <<EOF
logLevel: info
logDestinations: [stdout]
logStructured: false
readTimeout: 15s
writeTimeout: 15s
writeQueueSize: 1024

authMethod: http
authHTTPAddress: "http://127.0.0.1:3000/api/internal/rtsp/auth?gateway_secret=${RTSP_GATEWAY_SHARED_SECRET}"
authHTTPExclude:
  - action: api
  - action: metrics
  - action: pprof

api: true
apiAddress: 127.0.0.1:9997
metrics: false
pprof: false
playback: false

rtsp: true
rtspTransports: [tcp]
rtspEncryption: "no"
rtspAddress: :${rtsp_port}

rtmp: false
hls: false
webrtc: false
srt: false

pathDefaults:
  source: publisher
  runOnDemand: ${relay_file}
  runOnDemandRestart: true
  runOnDemandStartTimeout: 25s
  runOnDemandCloseAfter: 10s

paths:
  all_others:
EOF
  chown root:root "$config_file"
  chmod 0600 "$config_file"

  [[ -f "$PROJECT_DIR/deploy/systemd/newdomofon-video-rtsp-gateway.service" ]] || {
    echo "RTSP systemd unit is missing from project." >&2
    return 66
  }
  install -m 0644 \
    "$PROJECT_DIR/deploy/systemd/newdomofon-video-rtsp-gateway.service" \
    "$unit_file"
  ensure_root_unit "$unit_file"

  systemctl daemon-reload
  systemctl restart newdomofon-video-backend.service
  wait_http_json_ok \
    http://127.0.0.1:3000/api/health \
    /tmp/newdomofon-local-root-backend-after-rtsp.json \
    90 \
    newdomofon-video-backend.service

  systemctl enable newdomofon-video-rtsp-gateway.service
  systemctl restart newdomofon-video-rtsp-gateway.service

  for _ in $(seq 1 40); do
    if systemctl is-active --quiet newdomofon-video-rtsp-gateway.service &&
       timeout 1 bash -c "</dev/tcp/127.0.0.1/${rtsp_port}" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  systemctl is-active --quiet newdomofon-video-rtsp-gateway.service || {
    journalctl -u newdomofon-video-rtsp-gateway.service -n 200 --no-pager >&2
    return 1
  }
  timeout 1 bash -c "</dev/tcp/127.0.0.1/${rtsp_port}" 2>/dev/null || {
    journalctl -u newdomofon-video-rtsp-gateway.service -n 200 --no-pager >&2
    return 1
  }

  auth_status="$(
    curl -sS --retry 3 --retry-connrefused \
      -o /dev/null \
      -w '%{http_code}' \
      -H 'content-type: application/json' \
      --data '{"action":"read","protocol":"rtsp","path":"healthcheck","user":"","password":""}' \
      "http://127.0.0.1:3000/api/internal/rtsp/auth?gateway_secret=${RTSP_GATEWAY_SHARED_SECRET}"
  )"
  [[ "$auth_status" == 401 ]] || {
    echo "Unexpected RTSP auth preflight status: $auth_status" >&2
    return 1
  }

  if command -v ufw >/dev/null &&
     ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${rtsp_port}/tcp" comment 'NewDomofon RTSP gateway' >/dev/null || true
  elif command -v firewall-cmd >/dev/null &&
       systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${rtsp_port}/tcp" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
  fi

  echo "MediaMTX installed: $tag"
  echo "RTSP template: $rtsp_template"
  return 0
}

log_step "11/15 Installing automatic RTSP gateway"
RTSP_STATUS="skipped"
if is_true "$INSTALL_RTSP"; then
  set +e
  (
    set -Eeuo pipefail
    trap - ERR
    install_mediamtx
  )
  RTSP_RC=$?
  set -e

  if [[ "$RTSP_RC" -eq 0 ]]; then
    RTSP_STATUS="installed"
  else
    RTSP_STATUS="failed (exit ${RTSP_RC}); core master remains installed"
    systemctl disable --now newdomofon-video-rtsp-gateway.service 2>/dev/null || true
    set_env_value RTSP_GATEWAY_ENABLED false "$ENV_FILE"
    chown root:root "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    echo "WARNING: RTSP installation failed. $RTSP_STATUS" >&2
    echo "Place mediamtx_*_linux_<arch>.tar.gz in /root and rerun this installer." >&2
    if is_true "$REQUIRE_RTSP"; then
      exit "$RTSP_RC"
    fi
  fi
fi

log_step "12/15 Configuring firewall and TLS"
if command -v ufw >/dev/null &&
   ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 'Nginx Full' >/dev/null || true
fi

TLS_ACTIVE=false
TLS_STATUS="not requested"
if [[ "$TLS_MODE" != no ]] && ! is_ip_address "$MASTER_DOMAIN"; then
  if getent ahosts "$MASTER_DOMAIN" >/dev/null 2>&1; then
    CERTBOT_ARGS=(
      --nginx
      --non-interactive
      --agree-tos
      --redirect
      --keep-until-expiring
      -d "$MASTER_DOMAIN"
    )
    if [[ -n "$CERTBOT_EMAIL" ]]; then
      CERTBOT_ARGS+=(-m "$CERTBOT_EMAIL")
    else
      CERTBOT_ARGS+=(--register-unsafely-without-email)
    fi

    set +e
    certbot "${CERTBOT_ARGS[@]}"
    CERTBOT_RC=$?
    set -e

    if [[ "$CERTBOT_RC" -eq 0 ]]; then
      TLS_ACTIVE=true
      TLS_STATUS="enabled with Let's Encrypt"
      PUBLIC_SCHEME=https
      PUBLIC_BASE_URL="https://${MASTER_DOMAIN}"
      set_env_value CORS_ORIGIN "$PUBLIC_BASE_URL" "$ENV_FILE"
      set_env_value SMARTYARD_PUBLIC_BASE_URL "$PUBLIC_BASE_URL" "$ENV_FILE"
      set_env_value APP_PUBLIC_URL "$PUBLIC_BASE_URL" "$ENV_FILE"
      chown root:root "$ENV_FILE"
      chmod 0600 "$ENV_FILE"
      systemctl restart newdomofon-video-backend.service
      systemctl restart newdomofon-smartyard-compat.service
      wait_http_json_ok \
        http://127.0.0.1:3000/api/health \
        /tmp/newdomofon-local-root-backend-after-tls.json \
        90 \
        newdomofon-video-backend.service
    else
      TLS_STATUS="certificate request failed; HTTP remains available"
      if [[ "$TLS_MODE" == yes ]]; then
        echo "WARNING: TLS was requested but certificate issuance failed." >&2
      fi
    fi
  else
    TLS_STATUS="DNS does not resolve; HTTP remains available"
  fi
elif [[ "$TLS_MODE" == yes ]] && is_ip_address "$MASTER_DOMAIN"; then
  TLS_STATUS="Let's Encrypt is not available for the configured IP address"
fi

nginx -t
systemctl reload nginx

log_step "13/15 Disabling recorder on strict master"
if systemctl list-unit-files newdomofon-video-dvr.service >/dev/null 2>&1 ||
   systemctl status newdomofon-video-dvr.service >/dev/null 2>&1; then
  systemctl disable --now newdomofon-video-dvr.service || true
fi

log_step "14/15 Final health and runtime checks"
wait_http_json_ok \
  http://127.0.0.1:3000/api/health \
  /tmp/newdomofon-local-root-final-backend.json \
  90 \
  newdomofon-video-backend.service

wait_http_json_ok \
  http://127.0.0.1:3082/health \
  /tmp/newdomofon-local-root-final-gateway.json \
  90 \
  newdomofon-smartyard-compat.service

for service in \
  newdomofon-video-backend.service \
  newdomofon-public-events-proxy.service \
  newdomofon-smartyard-compat.service \
  postgresql.service \
  nginx.service; do
  systemctl is-active --quiet "$service" || {
    systemctl --no-pager --full status "$service" >&2 || true
    exit 1
  }
done

for service in \
  newdomofon-video-backend.service \
  newdomofon-public-events-proxy.service \
  newdomofon-smartyard-compat.service; do
  actual_user="$(systemctl show -p User --value "$service")"
  [[ "$actual_user" == root ]] || {
    echo "$service is not configured to run as root: $actual_user" >&2
    exit 1
  }
done

if [[ "$RTSP_STATUS" == installed ]]; then
  systemctl is-active --quiet newdomofon-video-rtsp-gateway.service
  [[ "$(systemctl show -p User --value newdomofon-video-rtsp-gateway.service)" == root ]]
fi

if [[ "$TLS_ACTIVE" == true ]]; then
  curl -kfsS --resolve "${MASTER_DOMAIN}:443:127.0.0.1" \
    "https://${MASTER_DOMAIN}/api/health" \
    >/tmp/newdomofon-local-root-public-health.json
else
  curl -fsS -H "Host: ${MASTER_DOMAIN}" \
    http://127.0.0.1/api/health \
    >/tmp/newdomofon-local-root-public-health.json
fi
jq -e '.ok == true' /tmp/newdomofon-local-root-public-health.json >/dev/null

log_step "15/15 Writing and printing access data"
RTSP_TEMPLATE="$(env_value RTSP_PUBLIC_URL_TEMPLATE "$ENV_FILE")"
RTSP_VERSION="$(env_value RTSP_MEDIAMTX_VERSION "$ENV_FILE")"
WEB_URL="${PUBLIC_SCHEME}://${MASTER_DOMAIN}"

cp -a "$ENV_FILE" "$SUMMARY_FILE"
cat >>"$SUMMARY_FILE" <<EOF

INSTALLER_VERSION=${INSTALLER_VERSION}
INSTALL_COMPLETED_AT=$(date '+%Y-%m-%d_%H:%M:%S_%Z_%z')
INSTALL_TIMEZONE=${TIMEZONE}
INSTALL_TLS_STATUS=${TLS_STATUS}
INSTALL_RTSP_STATUS=${RTSP_STATUS}
SYSTEM_USERS_CREATED_BY_INSTALLER=none
MASTER_APPLICATION_RUNTIME_USER=root
POSTGRESQL_SERVICE_RUNTIME_USER=postgres
NGINX_WORKER_RUNTIME_USER=www-data

MASTER_WEB_URL=${WEB_URL}
MASTER_ADMIN_URL=${WEB_URL}/admin
MASTER_API_HEALTH_URL=${WEB_URL}/api/health

POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
POSTGRES_DATABASE=newdomofon_video
POSTGRES_USER=newdomofon
POSTGRES_PASSWORD=${DB_PASSWORD}

RTSP_PUBLIC_URL_TEMPLATE=${RTSP_TEMPLATE}
RTSP_PUBLIC_PORT=8554
MEDIAMTX_VERSION=${RTSP_VERSION}

SOURCE_DIRECTORY=${SOURCE_DIR}
SOURCE_FINGERPRINT=${SOURCE_FINGERPRINT}
PROJECT_DIRECTORY=${PROJECT_DIR}
PREVIOUS_PROJECT_BACKUP=${OLD_PROJECT_BACKUP}
INSTALL_LOG=${LOG_FILE}
INSTALL_BACKUP=${BACKUP_DIR}
EOF

chown root:root "$SUMMARY_FILE"
chmod 0600 "$SUMMARY_FILE"

jq -Rn '
  reduce inputs as $line ({};
    if ($line | test("^[A-Za-z_][A-Za-z0-9_]*=")) then
      ($line | capture("^(?<key>[^=]+)=(?<value>.*)$")) as $item |
      .[$item.key] = $item.value
    else
      .
    end
  )
' <"$SUMMARY_FILE" >"$JSON_FILE"

chown root:root "$JSON_FILE"
chmod 0600 "$JSON_FILE"

echo
echo "============================================================"
echo "INSTALLATION COMPLETED"
echo "============================================================"
cat "$SUMMARY_FILE"
echo
echo "Services:"
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-public-events-proxy.service
systemctl is-active newdomofon-smartyard-compat.service
[[ "$RTSP_STATUS" == installed ]] &&
  systemctl is-active newdomofon-video-rtsp-gateway.service || true
systemctl is-active postgresql.service
systemctl is-active nginx.service

echo
echo "Runtime users:"
for service in \
  newdomofon-video-backend.service \
  newdomofon-public-events-proxy.service \
  newdomofon-smartyard-compat.service; do
  printf '%-48s user=%s\n' \
    "$service" \
    "$(systemctl show -p User --value "$service")"
done
if [[ "$RTSP_STATUS" == installed ]]; then
  printf '%-48s user=%s\n' \
    newdomofon-video-rtsp-gateway.service \
    "$(systemctl show -p User --value newdomofon-video-rtsp-gateway.service)"
fi

echo
echo "Access file: $SUMMARY_FILE"
echo "JSON file:   $JSON_FILE"
echo "Log file:    $LOG_FILE"
echo "Backup:      $BACKUP_DIR"
echo
echo "No custom Linux user was created by this installer."
echo "PostgreSQL uses its standard package account 'postgres'."
echo "Nginx workers use the standard package account 'www-data'."
echo "All NewDomofon Master application services run as root."

trap - ERR

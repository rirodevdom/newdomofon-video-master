#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO_URL="${REPO_URL:-https://github.com/rirodevdom/newdomofon-video-master.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
MASTER_DOMAIN="${MASTER_DOMAIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
ADMIN_LOGIN="${ADMIN_LOGIN:-admin}"
TLS_MODE="${TLS_MODE:-auto}"
REGENERATE_SECRETS="${REGENERATE_SECRETS:-false}"
INSTALL_STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_FILE:-/root/newdomofon-master-install-${INSTALL_STAMP}.log}"
SUMMARY_FILE="${SUMMARY_FILE:-/root/newdomofon-master-access.txt}"
CREDENTIALS_JSON="${CREDENTIALS_JSON:-/root/newdomofon-master-access.json}"
BACKUP_DIR="${BACKUP_DIR:-/opt/newdomofon-video-migration-backups/one-shot-master-${INSTALL_STAMP}}"
CURRENT_STEP="initialization"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

fail() {
  local rc=$?
  local line="${1:-unknown}"
  trap - ERR
  echo
  echo "INSTALLATION FAILED"
  echo "Step: $CURRENT_STEP"
  echo "Line: $line"
  echo "Exit code: $rc"
  echo "Log: $LOG_FILE"
  echo "Backup: $BACKUP_DIR"
  exit "$rc"
}
trap 'fail $LINENO' ERR

is_true() { [[ "${1:-}" =~ ^(1|true|yes|on)$ ]]; }
is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
random_hex() { openssl rand -hex "${1:-32}"; }
get_env() {
  [[ -f "$2" ]] || return 0
  sed -n "s/^${1}=//p" "$2" | tail -1
}
set_env() {
  if grep -qE "^${1}=" "$3"; then
    sed -i "s|^${1}=.*|${1}=${2}|" "$3"
  else
    printf '%s=%s\n' "$1" "$2" >>"$3"
  fi
}
preserve_secret() {
  local key="$1" bytes="$2" min_length="$3" existing=""
  if [[ "$EXISTING_ENV" == true ]] && ! is_true "$REGENERATE_SECRETS"; then
    existing="$(get_env "$key" "$ENV_FILE")"
  fi
  if [[ ${#existing} -ge $min_length ]] &&
     [[ ! "$existing" =~ ^(CHANGE|change|REPLACE|replace|dev-secret) ]]; then
    printf '%s' "$existing"
  else
    random_hex "$bytes"
  fi
}

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root" >&2; exit 77; }
[[ -n "$MASTER_DOMAIN" ]] || { echo "MASTER_DOMAIN is required" >&2; exit 64; }
[[ "$MASTER_DOMAIN" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid domain/IP" >&2; exit 64; }
[[ "$ADMIN_LOGIN" =~ ^[A-Za-z0-9_.@-]+$ ]] || { echo "Invalid admin login" >&2; exit 64; }
case "$TLS_MODE" in auto|yes|no) ;; *) echo "TLS_MODE must be auto, yes or no" >&2; exit 64;; esac

install -d -m 0750 "$BACKUP_DIR"
for path in \
  /etc/newdomofon-video/app.env \
  /etc/nginx/sites-available/newdomofon-video.conf \
  /etc/systemd/system/newdomofon-video-backend.service \
  /etc/systemd/system/newdomofon-public-events-proxy.service \
  /etc/systemd/system/newdomofon-smartyard-compat.service \
  /etc/systemd/system/newdomofon-video-rtsp-gateway.service; do
  [[ -e "$path" ]] && cp -a "$path" "$BACKUP_DIR/$(basename "$path").before"
done

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  [[ "${ID:-}" == debian && "${VERSION_ID:-}" == 12* ]] ||
    echo "WARNING: validated for Debian 12; detected ${PRETTY_NAME:-unknown}."
fi

echo "NewDomofon Video Master one-shot installation"
echo "Domain/IP: $MASTER_DOMAIN"
echo "Project: $PROJECT_DIR"
echo "Timezone: $TIMEZONE"
echo "TLS mode: $TLS_MODE"
echo "Log: $LOG_FILE"

CURRENT_STEP="installing Debian packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates curl gnupg git unzip rsync jq nginx ffmpeg sudo \
  postgresql postgresql-contrib build-essential openssl python3 \
  certbot python3-certbot-nginx systemd-timesyncd

if ! command -v node >/dev/null 2>&1 ||
   ! node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a > 22 || (a === 22 && b >= 12) ? 0 : 1)' 2>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi

CURRENT_STEP="configuring account and time"
id newdomofon >/dev/null 2>&1 ||
  useradd --system --home "$PROJECT_DIR" --shell /usr/sbin/nologin newdomofon
install -d -o root -g newdomofon -m 0750 /etc/newdomofon-video
install -d -o newdomofon -g newdomofon -m 0755 \
  /var/www/newdomofon-video /var/lib/newdomofon-video \
  /var/cache/newdomofon-video /var/cache/newdomofon-video/smartyard-preview \
  /var/log/newdomofon-video

timedatectl set-timezone "$TIMEZONE"
systemctl enable --now systemd-timesyncd || true
systemctl enable --now postgresql
systemctl enable --now nginx

CURRENT_STEP="checking out repository"
if [[ -d "$PROJECT_DIR/.git" ]]; then
  git -C "$PROJECT_DIR" status --short >"$BACKUP_DIR/git-status-before.txt" || true
  git -C "$PROJECT_DIR" diff --binary >"$BACKUP_DIR/worktree-before.patch" || true
  git -C "$PROJECT_DIR" rev-parse HEAD >"$BACKUP_DIR/git-commit-before.txt" || true
  git -C "$PROJECT_DIR" stash push -u -m "before-one-shot-master-${INSTALL_STAMP}" || true
  git -C "$PROJECT_DIR" fetch origin "$REPO_BRANCH"
  git -C "$PROJECT_DIR" switch -C "$REPO_BRANCH" "origin/$REPO_BRANCH"
elif [[ -e "$PROJECT_DIR" ]]; then
  mv "$PROJECT_DIR" "${PROJECT_DIR}.before-${INSTALL_STAMP}"
  git clone --branch "$REPO_BRANCH" --single-branch "$REPO_URL" "$PROJECT_DIR"
else
  install -d -m 0755 "$(dirname "$PROJECT_DIR")"
  git clone --branch "$REPO_BRANCH" --single-branch "$REPO_URL" "$PROJECT_DIR"
fi

CURRENT_STEP="preparing secrets"
EXISTING_ENV=false
if [[ -f "$ENV_FILE" ]]; then
  EXISTING_ENV=true
  cp -a "$ENV_FILE" "$BACKUP_DIR/app.env.before"
fi

DB_PASSWORD=""
if [[ "$EXISTING_ENV" == true ]] && ! is_true "$REGENERATE_SECRETS"; then
  DB_PASSWORD="$(python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
from urllib.parse import urlparse, unquote
import sys
value = ''
for raw in Path(sys.argv[1]).read_text(encoding='utf-8').splitlines():
    if raw.startswith('DATABASE_URL='):
        value = raw.split('=', 1)[1].strip().strip('"').strip("'")
if value:
    parsed = urlparse(value)
    if parsed.password:
        print(unquote(parsed.password))
PY
)"
fi
[[ "$DB_PASSWORD" =~ ^[A-Za-z0-9._~-]+$ ]] || DB_PASSWORD="$(random_hex 24)"

JWT_SECRET="$(preserve_secret JWT_SECRET 48 32)"
ADMIN_PASSWORD="$(preserve_secret ADMIN_PASSWORD 18 12)"
NODE_REGISTRATION_TOKEN="$(preserve_secret NODE_REGISTRATION_TOKEN 32 32)"
INTERNAL_DVR_SECRET="$(preserve_secret INTERNAL_DVR_SECRET 32 32)"
RTSP_GATEWAY_SHARED_SECRET="$(preserve_secret RTSP_GATEWAY_SHARED_SECRET 32 32)"
RTSP_RELAY_PUBLISH_SECRET="$(preserve_secret RTSP_RELAY_PUBLISH_SECRET 32 32)"
RTSP_MEDIAMTX_VERSION=""
if [[ "$EXISTING_ENV" == true ]] && ! is_true "$REGENERATE_SECRETS"; then
  RTSP_MEDIAMTX_VERSION="$(get_env RTSP_MEDIAMTX_VERSION "$ENV_FILE")"
  EXISTING_LOGIN="$(get_env ADMIN_LOGIN "$ENV_FILE")"
  [[ "$ADMIN_LOGIN" != admin || -z "$EXISTING_LOGIN" ]] || ADMIN_LOGIN="$EXISTING_LOGIN"
fi

CURRENT_STEP="configuring PostgreSQL"
cd /tmp
ROLE_EXISTS="$(sudo -u postgres psql -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname='newdomofon';")"
[[ "$ROLE_EXISTS" == 1 ]] || sudo -u postgres createuser --login newdomofon
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -v db_password="$DB_PASSWORD" <<'SQL'
ALTER ROLE newdomofon WITH LOGIN PASSWORD :'db_password';
SQL
DB_EXISTS="$(sudo -u postgres psql -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='newdomofon_video';")"
[[ "$DB_EXISTS" == 1 ]] || sudo -u postgres createdb --owner=newdomofon newdomofon_video
sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 <<'SQL'
ALTER DATABASE newdomofon_video OWNER TO newdomofon;
GRANT ALL PRIVILEGES ON DATABASE newdomofon_video TO newdomofon;
SQL
PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U newdomofon -d newdomofon_video \
  -v ON_ERROR_STOP=1 -Atqc 'SELECT current_database(), current_user;' \
  >"$BACKUP_DIR/postgresql-connect-test.txt"
if [[ "$DB_EXISTS" == 1 ]]; then
  PGPASSWORD="$DB_PASSWORD" pg_dump -Fc -h 127.0.0.1 -U newdomofon \
    -d newdomofon_video >"$BACKUP_DIR/postgresql-before.dump"
fi

CURRENT_STEP="writing environment"
PUBLIC_SCHEME=http
PUBLIC_BASE_URL="http://${MASTER_DOMAIN}"
DATABASE_URL="postgres://newdomofon:${DB_PASSWORD}@127.0.0.1:5432/newdomofon_video"
cat >"$ENV_FILE" <<EOF
NODE_ENV=production
BACKEND_PORT=3000
DATABASE_URL=${DATABASE_URL}
JWT_SECRET=${JWT_SECRET}
ADMIN_LOGIN=${ADMIN_LOGIN}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
CORS_ORIGIN=${PUBLIC_BASE_URL}
TRUST_PROXY=true
SMARTYARD_PUBLIC_BASE_URL=${PUBLIC_BASE_URL}
APP_PUBLIC_URL=${PUBLIC_BASE_URL}
INTERNAL_DVR_SECRET=${INTERNAL_DVR_SECRET}
NODE_REGISTRATION_TOKEN=${NODE_REGISTRATION_TOKEN}
PLAYBACK_TOKEN_TTL_SECONDS=900
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
RTSP_GATEWAY_ENABLED=false
RTSP_PUBLIC_PORT=8554
RTSP_AUTO_OPEN_FIREWALL=true
RTSP_MEDIAMTX_VERSION=${RTSP_MEDIAMTX_VERSION}
RTSP_GATEWAY_SHARED_SECRET=${RTSP_GATEWAY_SHARED_SECRET}
RTSP_RELAY_PUBLISH_SECRET=${RTSP_RELAY_PUBLISH_SECRET}
DVR_ENGINE_URL=http://127.0.0.1:3010
MEDIA_PUBLIC_BASE_URL=/api/media
EOF
chown root:newdomofon "$ENV_FILE"
chmod 0640 "$ENV_FILE"

CURRENT_STEP="deploying master"
PROJECT_DIR="$PROJECT_DIR" ENV_FILE="$ENV_FILE" \
INSTALL_DISK_GUARD=1 INSTALL_JOURNAL_LIMITS=1 INSTALL_RTSP_GATEWAY=1 \
  bash "$PROJECT_DIR/scripts/deploy-master.sh"

CURRENT_STEP="synchronizing administrator"
cd "$PROJECT_DIR/backend"
DATABASE_URL="$DATABASE_URL" ADMIN_LOGIN="$ADMIN_LOGIN" ADMIN_PASSWORD="$ADMIN_PASSWORD" \
node --input-type=module <<'NODE'
import bcrypt from 'bcryptjs';
import pg from 'pg';
const { Pool } = pg;
const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const hash = await bcrypt.hash(process.env.ADMIN_PASSWORD, 12);
await pool.query(
  `INSERT INTO users(login, password_hash, role, is_active)
   VALUES ($1, $2, 'super_admin', true)
   ON CONFLICT (login) DO UPDATE SET password_hash=EXCLUDED.password_hash,
   role='super_admin', is_active=true`,
  [process.env.ADMIN_LOGIN, hash],
);
await pool.end();
NODE
systemctl restart newdomofon-video-backend.service

CURRENT_STEP="configuring Nginx"
NGINX_SITE=/etc/nginx/sites-available/newdomofon-video.conf
cp -a "$NGINX_SITE" "$BACKUP_DIR/newdomofon-video.conf.before-domain"
sed -i "s/server_name _;/server_name ${MASTER_DOMAIN};/" "$NGINX_SITE"
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 'Nginx Full' >/dev/null || true
fi

CURRENT_STEP="requesting TLS"
TLS_ACTIVE=false
TLS_MESSAGE="not requested"
if [[ "$TLS_MODE" != no ]] && ! is_ipv4 "$MASTER_DOMAIN"; then
  if getent ahosts "$MASTER_DOMAIN" >/dev/null 2>&1; then
    CERTBOT_ARGS=(--nginx --non-interactive --agree-tos --redirect --keep-until-expiring -d "$MASTER_DOMAIN")
    [[ -n "$CERTBOT_EMAIL" ]] && CERTBOT_ARGS+=(-m "$CERTBOT_EMAIL") || CERTBOT_ARGS+=(--register-unsafely-without-email)
    if certbot "${CERTBOT_ARGS[@]}"; then
      TLS_ACTIVE=true
      TLS_MESSAGE="enabled with Let's Encrypt"
    else
      TLS_MESSAGE="certificate request failed; HTTP remains available"
    fi
  else
    TLS_MESSAGE="DNS does not resolve yet; HTTP remains available"
  fi
elif [[ "$TLS_MODE" == yes ]] && is_ipv4 "$MASTER_DOMAIN"; then
  TLS_MESSAGE="Let's Encrypt is not attempted for an IP address"
fi
nginx -t
systemctl reload nginx

if [[ "$TLS_ACTIVE" == true ]]; then
  PUBLIC_SCHEME=https
  PUBLIC_BASE_URL="https://${MASTER_DOMAIN}"
  set_env CORS_ORIGIN "$PUBLIC_BASE_URL" "$ENV_FILE"
  set_env SMARTYARD_PUBLIC_BASE_URL "$PUBLIC_BASE_URL" "$ENV_FILE"
  set_env APP_PUBLIC_URL "$PUBLIC_BASE_URL" "$ENV_FILE"
  chown root:newdomofon "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
  systemctl restart newdomofon-video-backend.service
  systemctl restart newdomofon-smartyard-compat.service
fi

CURRENT_STEP="health checks"
for _ in $(seq 1 60); do
  curl -fsS --max-time 3 http://127.0.0.1:3000/api/health \
    >/tmp/newdomofon-master-health.json 2>/dev/null && break
  sleep 1
done
jq -e '.ok == true' /tmp/newdomofon-master-health.json >/dev/null
curl -fsS http://127.0.0.1:3082/health >/tmp/newdomofon-gateway-health.json
nginx -t
for service in newdomofon-video-backend newdomofon-smartyard-compat \
  newdomofon-video-rtsp-gateway postgresql nginx; do
  systemctl is-active --quiet "$service"
done

if [[ "$TLS_ACTIVE" == true ]]; then
  curl -kfsS --resolve "${MASTER_DOMAIN}:443:127.0.0.1" \
    "https://${MASTER_DOMAIN}/api/health" >/tmp/newdomofon-public-health.json
else
  curl -fsS -H "Host: ${MASTER_DOMAIN}" http://127.0.0.1/api/health \
    >/tmp/newdomofon-public-health.json
fi
jq -e '.ok == true' /tmp/newdomofon-public-health.json >/dev/null

export PUBLIC_SCHEME PUBLIC_BASE_URL DATABASE_URL DB_PASSWORD JWT_SECRET ADMIN_PASSWORD
export NODE_REGISTRATION_TOKEN INTERNAL_DVR_SECRET RTSP_GATEWAY_SHARED_SECRET
export RTSP_RELAY_PUBLISH_SECRET TLS_MESSAGE LOG_FILE SUMMARY_FILE CREDENTIALS_JSON
export BACKUP_DIR ENV_FILE TIMEZONE MASTER_DOMAIN ADMIN_LOGIN PROJECT_DIR
export RTSP_TEMPLATE="$(get_env RTSP_PUBLIC_URL_TEMPLATE "$ENV_FILE")"
export RTSP_VERSION="$(get_env RTSP_MEDIAMTX_VERSION "$ENV_FILE")"
export GIT_COMMIT="$(git -C "$PROJECT_DIR" rev-parse HEAD)"

CURRENT_STEP="writing access report"
bash "$PROJECT_DIR/scripts/lib/master-one-shot-report.sh"

trap - ERR

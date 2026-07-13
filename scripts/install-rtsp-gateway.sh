#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SERVICE="newdomofon-video-rtsp-gateway.service"
BACKEND_SERVICE="newdomofon-video-backend.service"
CONFIG_FILE="/etc/newdomofon-video/mediamtx.yml"
BINARY="/usr/local/bin/mediamtx"
RELAY_SCRIPT="/usr/local/lib/newdomofon-video/rtsp-relay-on-demand.sh"
UNIT_FILE="/etc/systemd/system/$SERVICE"
VERSION_FILE="/usr/local/share/newdomofon-video/mediamtx-version"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-migration-backups/rtsp-gateway-$STAMP"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

for command in curl jq openssl sha256sum tar install systemctl python3 ffmpeg; do
  command -v "$command" >/dev/null || {
    echo "Required command is missing: $command" >&2
    exit 69
  }
done

[[ -f "$ENV_FILE" ]] || {
  echo "Environment file not found: $ENV_FILE" >&2
  exit 66
}

install -d -m 0750 "$BACKUP"

backup_one() {
  local path="$1"
  local name="$2"
  if [[ -e "$path" ]]; then
    cp -a "$path" "$BACKUP/$name"
  else
    : >"$BACKUP/$name.missing"
  fi
}

backup_one "$ENV_FILE" app.env
backup_one "$BINARY" mediamtx
backup_one "$CONFIG_FILE" mediamtx.yml
backup_one "$RELAY_SCRIPT" rtsp-relay-on-demand.sh
backup_one "$UNIT_FILE" "$SERVICE"
backup_one "$VERSION_FILE" mediamtx-version

rollback() {
  local rc=$?
  trap - ERR
  echo "RTSP gateway installation failed; restoring backup" >&2
  systemctl stop "$SERVICE" 2>/dev/null || true

  restore_one() {
    local path="$1"
    local name="$2"
    if [[ -e "$BACKUP/$name" ]]; then
      install -d -m 0755 "$(dirname "$path")"
      cp -a "$BACKUP/$name" "$path"
    elif [[ -e "$BACKUP/$name.missing" ]]; then
      rm -f "$path"
    fi
  }

  restore_one "$ENV_FILE" app.env
  restore_one "$BINARY" mediamtx
  restore_one "$CONFIG_FILE" mediamtx.yml
  restore_one "$RELAY_SCRIPT" rtsp-relay-on-demand.sh
  restore_one "$UNIT_FILE" "$SERVICE"
  restore_one "$VERSION_FILE" mediamtx-version

  systemctl daemon-reload || true
  systemctl restart "$BACKEND_SERVICE" 2>/dev/null || true
  if [[ -f "$UNIT_FILE" ]]; then systemctl restart "$SERVICE" 2>/dev/null || true; fi
  echo "Backup: $BACKUP" >&2
  exit "$rc"
}
trap rollback ERR

set_env() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
  fi
}

get_env() {
  local key="$1"
  sed -n "s/^${key}=//p" "$ENV_FILE" | tail -1
}

random_secret() {
  openssl rand -hex 32
}

GATEWAY_SECRET="$(get_env RTSP_GATEWAY_SHARED_SECRET)"
PUBLISH_SECRET="$(get_env RTSP_RELAY_PUBLISH_SECRET)"
[[ ${#GATEWAY_SECRET} -ge 32 ]] || GATEWAY_SECRET="$(random_secret)"
[[ ${#PUBLISH_SECRET} -ge 32 ]] || PUBLISH_SECRET="$(random_secret)"

RTSP_PORT_VALUE="${RTSP_PUBLIC_PORT:-$(get_env RTSP_PUBLIC_PORT)}"
RTSP_PORT_VALUE="${RTSP_PORT_VALUE:-8554}"
if [[ ! "$RTSP_PORT_VALUE" =~ ^[0-9]+$ ]] || (( RTSP_PORT_VALUE < 1024 || RTSP_PORT_VALUE > 65535 )); then
  echo "RTSP_PUBLIC_PORT must be an unprivileged TCP port between 1024 and 65535" >&2
  exit 64
fi

# Derive the public RTSP host from the already configured public HTTPS origin.
PUBLIC_HOST="${RTSP_PUBLIC_HOST:-$(get_env RTSP_PUBLIC_HOST)}"
if [[ -z "$PUBLIC_HOST" ]]; then
  PUBLIC_HOST="$(python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
from urllib.parse import urlparse
import sys

values = {}
for raw in Path(sys.argv[1]).read_text().splitlines():
    raw = raw.strip()
    if not raw or raw.startswith('#') or '=' not in raw:
        continue
    key, value = raw.split('=', 1)
    values[key.strip()] = value.strip().strip('"').strip("'")

for key in ('SMARTYARD_PUBLIC_BASE_URL', 'APP_PUBLIC_URL', 'PUBLIC_BACKEND_BASE_URL', 'CORS_ORIGIN'):
    for candidate in values.get(key, '').split(','):
        candidate = candidate.strip()
        if not candidate or candidate == '*':
            continue
        parsed = urlparse(candidate if '://' in candidate else 'https://' + candidate)
        if parsed.hostname:
            host = parsed.hostname
            if ':' in host and not host.startswith('['):
                host = f'[{host}]'
            print(host)
            raise SystemExit(0)
raise SystemExit(1)
PY
)" || {
    echo "Cannot derive public RTSP host. Configure SMARTYARD_PUBLIC_BASE_URL or CORS_ORIGIN first." >&2
    exit 78
  }
fi

RTSP_TEMPLATE="rtsp://token:{token}@${PUBLIC_HOST}:${RTSP_PORT_VALUE}/{stream}"
set_env RTSP_GATEWAY_ENABLED true
set_env RTSP_PUBLIC_HOST "$PUBLIC_HOST"
set_env RTSP_PUBLIC_PORT "$RTSP_PORT_VALUE"
set_env RTSP_PUBLIC_URL_TEMPLATE "$RTSP_TEMPLATE"
set_env RTSP_GATEWAY_SHARED_SECRET "$GATEWAY_SECRET"
set_env RTSP_RELAY_PUBLISH_SECRET "$PUBLISH_SECRET"
set_env RTSP_GATEWAY_BACKEND_URL http://127.0.0.1:3000
set_env RTSP_RELAY_FFMPEG_LOGLEVEL warning

chown root:newdomofon "$ENV_FILE"
chmod 0640 "$ENV_FILE"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ASSET_ARCH=amd64 ;;
  aarch64|arm64) ASSET_ARCH=arm64 ;;
  armv7l|armv7) ASSET_ARCH=armv7 ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 65 ;;
esac

REQUESTED_VERSION="${MEDIAMTX_VERSION:-$(get_env RTSP_MEDIAMTX_VERSION)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -n "$REQUESTED_VERSION" ]]; then
  RELEASE_API="https://api.github.com/repos/bluenviron/mediamtx/releases/tags/${REQUESTED_VERSION}"
else
  RELEASE_API="https://api.github.com/repos/bluenviron/mediamtx/releases/latest"
fi

curl -fsSL --retry 3 --connect-timeout 15 \
  -H 'accept: application/vnd.github+json' \
  -H 'user-agent: newdomofon-video-rtsp-installer' \
  "$RELEASE_API" >"$TMP/release.json"

TAG="$(jq -er '.tag_name' "$TMP/release.json")"
ASSET="mediamtx_${TAG}_linux_${ASSET_ARCH}.tar.gz"
ASSET_URL="$(jq -er --arg name "$ASSET" '.assets[] | select(.name == $name) | .browser_download_url' "$TMP/release.json")"
ASSET_DIGEST="$(jq -r --arg name "$ASSET" '.assets[] | select(.name == $name) | (.digest // empty)' "$TMP/release.json")"

curl -fL --retry 3 --connect-timeout 15 "$ASSET_URL" -o "$TMP/$ASSET"

EXPECTED_SHA=""
if [[ "$ASSET_DIGEST" == sha256:* ]]; then
  EXPECTED_SHA="${ASSET_DIGEST#sha256:}"
else
  CHECKSUM_URL="$(jq -r '.assets[] | select(.name | test("(?i)(checksums|sha256)")) | .browser_download_url' "$TMP/release.json" | head -1)"
  if [[ -n "$CHECKSUM_URL" && "$CHECKSUM_URL" != null ]]; then
    curl -fL --retry 3 --connect-timeout 15 "$CHECKSUM_URL" -o "$TMP/checksums.txt"
    EXPECTED_SHA="$(awk -v name="$ASSET" '$2 == name || $2 == "*" name {print $1; exit}' "$TMP/checksums.txt")"
  fi
fi

if [[ -z "$EXPECTED_SHA" ]]; then
  if [[ ! "${RTSP_ALLOW_UNVERIFIED_MEDIAMTX:-false}" =~ ^(1|true|yes|on)$ ]]; then
    echo "MediaMTX release does not expose a SHA256 digest for $ASSET" >&2
    exit 74
  fi
  echo "WARNING: installing MediaMTX without checksum verification" >&2
else
  ACTUAL_SHA="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
  [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || {
    echo "MediaMTX SHA256 mismatch" >&2
    exit 74
  }
fi

tar -xzf "$TMP/$ASSET" -C "$TMP"
[[ -x "$TMP/mediamtx" ]] || { echo "MediaMTX binary missing from release archive" >&2; exit 74; }

install -d -m 0755 /usr/local/bin /usr/local/lib/newdomofon-video /usr/local/share/newdomofon-video
install -m 0755 "$TMP/mediamtx" "$BINARY"
install -m 0750 -o root -g newdomofon "$PROJECT_DIR/scripts/rtsp-relay-on-demand.sh" "$RELAY_SCRIPT"
printf '%s\n' "$TAG" >"$VERSION_FILE"
chmod 0644 "$VERSION_FILE"
set_env RTSP_MEDIAMTX_VERSION "$TAG"

install -d -m 0750 -o root -g newdomofon /etc/newdomofon-video
cat >"$CONFIG_FILE" <<EOF
logLevel: info
logDestinations: [stdout]
logStructured: false
readTimeout: 15s
writeTimeout: 15s
writeQueueSize: 1024

authMethod: http
authHTTPAddress: "http://127.0.0.1:3000/api/internal/rtsp/auth?gateway_secret=${GATEWAY_SECRET}"
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
rtspAddress: :${RTSP_PORT_VALUE}

rtmp: false
hls: false
webrtc: false
srt: false

pathDefaults:
  source: publisher
  runOnDemand: /usr/local/lib/newdomofon-video/rtsp-relay-on-demand.sh
  runOnDemandRestart: true
  runOnDemandStartTimeout: 25s
  runOnDemandCloseAfter: 10s

paths:
  all_others:
EOF
chown root:newdomofon "$CONFIG_FILE"
chmod 0640 "$CONFIG_FILE"

install -m 0644 "$PROJECT_DIR/deploy/systemd/newdomofon-video-rtsp-gateway.service" "$UNIT_FILE"
systemctl daemon-reload
systemctl restart "$BACKEND_SERVICE"
systemctl enable --now "$SERVICE"

for _ in $(seq 1 40); do
  if systemctl is-active --quiet "$SERVICE" && timeout 1 bash -c "</dev/tcp/127.0.0.1/${RTSP_PORT_VALUE}" 2>/dev/null; then
    break
  fi
  sleep 1
done

systemctl is-active --quiet "$SERVICE" || {
  journalctl -u "$SERVICE" -n 200 --no-pager >&2
  exit 1
}
timeout 1 bash -c "</dev/tcp/127.0.0.1/${RTSP_PORT_VALUE}" 2>/dev/null || {
  journalctl -u "$SERVICE" -n 200 --no-pager >&2
  exit 1
}

AUTH_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' \
  -H 'content-type: application/json' \
  --data '{"action":"read","protocol":"rtsp","path":"healthcheck","user":"","password":""}' \
  "http://127.0.0.1:3000/api/internal/rtsp/auth?gateway_secret=${GATEWAY_SECRET}")"
[[ "$AUTH_STATUS" == 401 ]] || {
  echo "Unexpected RTSP auth preflight status: $AUTH_STATUS" >&2
  exit 1
}

if [[ "${RTSP_AUTO_OPEN_FIREWALL:-true}" =~ ^(1|true|yes|on)$ ]]; then
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${RTSP_PORT_VALUE}/tcp" comment 'NewDomofon RTSP gateway' >/dev/null
  elif command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${RTSP_PORT_VALUE}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
  fi
fi

trap - ERR
rm -rf "$TMP"
trap - EXIT

echo "RTSP GATEWAY INSTALLED"
echo "MediaMTX: $TAG"
echo "Listen: 0.0.0.0:${RTSP_PORT_VALUE}/tcp"
echo "Public template: $RTSP_TEMPLATE"
echo "Backup: $BACKUP"

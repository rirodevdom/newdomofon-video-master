#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
INSTALL_DISK_GUARD="${INSTALL_DISK_GUARD:-1}"
INSTALL_JOURNAL_LIMITS="${INSTALL_JOURNAL_LIMITS:-1}"
INSTALL_RTSP_GATEWAY="${INSTALL_RTSP_GATEWAY:-1}"
BACKEND_HEALTH_TIMEOUT_SECONDS="${BACKEND_HEALTH_TIMEOUT_SECONDS:-60}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo PROJECT_DIR=$PROJECT_DIR bash scripts/deploy-master.sh" >&2
  exit 1
fi

wait_for_backend() {
  local waited=0
  local health_url="http://127.0.0.1:3000/api/health"

  while (( waited < BACKEND_HEALTH_TIMEOUT_SECONDS )); do
    if curl -fsS --max-time 3 "$health_url" >/tmp/newdomofon-backend-deploy-health.json 2>/dev/null; then
      if jq -e '.ok == true' /tmp/newdomofon-backend-deploy-health.json >/dev/null 2>&1; then
        echo "Backend health check passed after ${waited}s"
        return 0
      fi
    fi
    sleep 1
    ((waited += 1))
  done

  echo "Backend did not become healthy within ${BACKEND_HEALTH_TIMEOUT_SECONDS}s" >&2
  systemctl --no-pager --full status newdomofon-video-backend.service >&2 || true
  journalctl -u newdomofon-video-backend.service -n 300 --no-pager >&2 || true
  return 1
}

normalize_project_permissions() {
  local normalizer="$PROJECT_DIR/scripts/lib/normalize-project-permissions.sh"

  [[ -f "$normalizer" ]] || {
    echo "Project permission normalizer not found: $normalizer" >&2
    return 1
  }

  PROJECT_DIR="$PROJECT_DIR" \
    bash "$normalizer"
}

cd "$PROJECT_DIR"
install -d -m 0750 "$(dirname "$ENV_FILE")"
if [[ ! -f "$ENV_FILE" ]]; then
  cp deploy/env/master.env.example "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
  echo "Created $ENV_FILE. Edit secrets and rerun this script."
  exit 2
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

if [[ "$INSTALL_DISK_GUARD" =~ ^(1|true|yes|on)$ ]]; then
  NEWDOMOFON_ENV_FILE="$ENV_FILE" bash "$PROJECT_DIR/scripts/master-disk-guard.sh"
  if [[ -e /run/newdomofon-video/master-disk-critical ]]; then
    echo "Deployment aborted before npm/migrations: master disk guard is critical." >&2
    cat /run/newdomofon-video/master-disk-state.json >&2 2>/dev/null || true
    exit 75
  fi
fi

cd "$PROJECT_DIR/backend"
npm ci --include=dev
npm run build
npm run migrate
npm run seed
npm prune --omit=dev

cd "$PROJECT_DIR/frontend"
npm ci --include=dev
npm run build
rsync -a --delete dist/ /var/www/newdomofon-video/
chown -R newdomofon:newdomofon /var/www/newdomofon-video

if [[ -d "$PROJECT_DIR/public-events-proxy" ]]; then
  cd "$PROJECT_DIR/public-events-proxy"
  if [[ -f package-lock.json ]]; then
    npm ci --omit=dev
  else
    npm install --omit=dev
  fi
fi

install -d -o newdomofon -g newdomofon -m 0755 \
  /var/lib/newdomofon-video \
  /var/cache/newdomofon-video \
  /var/cache/newdomofon-video/smartyard-preview \
  /var/log/newdomofon-video

# Archive/directory installs use a root-only temporary source and umask 077.
# Normalize the production checkout before systemd starts services as the
# unprivileged newdomofon user. This prevents status=200/CHDIR failures.
normalize_project_permissions

cp "$PROJECT_DIR/deploy/systemd/newdomofon-video-backend.service" /etc/systemd/system/
cp "$PROJECT_DIR/deploy/systemd/newdomofon-public-events-proxy.service" /etc/systemd/system/
if [[ -f "$PROJECT_DIR/deploy/systemd/newdomofon-smartyard-compat.service" ]]; then
  cp "$PROJECT_DIR/deploy/systemd/newdomofon-smartyard-compat.service" /etc/systemd/system/
fi
cp "$PROJECT_DIR/deploy/nginx/newdomofon-video.conf" /etc/nginx/sites-available/newdomofon-video.conf
ln -sf /etc/nginx/sites-available/newdomofon-video.conf /etc/nginx/sites-enabled/newdomofon-video.conf

systemctl daemon-reload
systemctl enable newdomofon-video-backend
systemctl restart newdomofon-video-backend
systemctl enable newdomofon-public-events-proxy
systemctl restart newdomofon-public-events-proxy
if [[ -f /etc/systemd/system/newdomofon-smartyard-compat.service ]]; then
  systemctl enable newdomofon-smartyard-compat
  systemctl restart newdomofon-smartyard-compat
fi

# The RTSP installer performs an HTTP authentication preflight against the
# backend. On a fresh server systemd can need several seconds to start Node.js,
# load the environment and connect to PostgreSQL. Never run the RTSP installer
# until the backend health endpoint is actually ready.
wait_for_backend

if [[ "$INSTALL_RTSP_GATEWAY" =~ ^(1|true|yes|on)$ ]]; then
  PROJECT_DIR="$PROJECT_DIR" ENV_FILE="$ENV_FILE" \
    bash "$PROJECT_DIR/scripts/install-rtsp-gateway.sh"
fi

if [[ "$INSTALL_DISK_GUARD" =~ ^(1|true|yes|on)$ ]]; then
  PROJECT_DIR="$PROJECT_DIR" INSTALL_JOURNAL_LIMITS="$INSTALL_JOURNAL_LIMITS" \
    bash "$PROJECT_DIR/scripts/install-master-disk-guard.sh"
fi

# Strict master/node deployment rule: master must not record cameras.
# A stale DVR service on the master can open RTSP/ONVIF sessions and compete
# with the assigned video node, causing live stalls and duplicate collectors.
if systemctl list-unit-files newdomofon-video-dvr.service >/dev/null 2>&1 || systemctl status newdomofon-video-dvr.service >/dev/null 2>&1; then
  systemctl disable --now newdomofon-video-dvr.service || true
fi

nginx -t
systemctl reload nginx

echo "Master deployed. DVR service is disabled on strict master deployments."
if [[ "$INSTALL_DISK_GUARD" =~ ^(1|true|yes|on)$ ]]; then
  echo "Disk guard: cat /run/newdomofon-video/master-disk-state.json"
fi
if [[ "$INSTALL_RTSP_GATEWAY" =~ ^(1|true|yes|on)$ ]]; then
  echo "RTSP gateway: systemctl status newdomofon-video-rtsp-gateway.service"
fi

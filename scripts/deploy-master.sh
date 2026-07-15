#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
INSTALL_DISK_GUARD="${INSTALL_DISK_GUARD:-1}"
INSTALL_JOURNAL_LIMITS="${INSTALL_JOURNAL_LIMITS:-1}"
INSTALL_RTSP_GATEWAY="${INSTALL_RTSP_GATEWAY:-1}"
BACKEND_HEALTH_TIMEOUT_SECONDS="${BACKEND_HEALTH_TIMEOUT_SECONDS:-60}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: PROJECT_DIR=$PROJECT_DIR bash scripts/deploy-master.sh" >&2
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

  PROJECT_DIR="$PROJECT_DIR" bash "$normalizer"
}

ensure_runtime_secrets() {
  command -v openssl >/dev/null || {
    echo "openssl is required to generate runtime secrets" >&2
    return 1
  }

  if ! grep -qE '^MANAGED_CAMERA_TOKEN_SECRET=.+$' "$ENV_FILE"; then
    [[ -n "${JWT_SECRET:-}" ]] || {
      echo "JWT_SECRET is required to initialize MANAGED_CAMERA_TOKEN_SECRET" >&2
      return 1
    }
    sed -i '/^MANAGED_CAMERA_TOKEN_SECRET=/d' "$ENV_FILE"
    printf '\nMANAGED_CAMERA_TOKEN_SECRET=%s\n' "$JWT_SECRET" >>"$ENV_FILE"
  fi

  if ! grep -qE '^INTERNAL_DVR_SECRET=.+$' "$ENV_FILE"; then
    sed -i '/^INTERNAL_DVR_SECRET=/d' "$ENV_FILE"
    printf '\nINTERNAL_DVR_SECRET=%s\n' "$(openssl rand -hex 32)" >>"$ENV_FILE"
  fi

  chown root:root "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
}

apply_managed_token_runtime_patches() {
  local patcher="$PROJECT_DIR/scripts/patch-manual-auto-managed-tokens.py"
  local collision_fix="$PROJECT_DIR/scripts/fix-manual-token-resolver-variable.py"

  [[ -f "$patcher" ]] || {
    echo "Managed-token patcher is missing: $patcher" >&2
    return 1
  }
  [[ -f "$collision_fix" ]] || {
    echo "Managed-token resolver collision fix is missing: $collision_fix" >&2
    return 1
  }

  command -v python3 >/dev/null || {
    echo "python3 is required for managed-token runtime integration" >&2
    return 1
  }

  python3 -m py_compile "$patcher" "$collision_fix"
  python3 "$collision_fix" --project-dir "$PROJECT_DIR"
  python3 "$patcher" --project-dir "$PROJECT_DIR"
  python3 "$collision_fix" --project-dir "$PROJECT_DIR"

  grep -q "manualManagedCameraTokenDigest(body.token)" \
    "$PROJECT_DIR/backend/src/routes/internalSmartYard.ts"
  grep -q "rawManagedPlayerToken(access)" \
    "$PROJECT_DIR/backend/src/routes/managedAdminPlayer.ts"
  grep -q "auto_assign_new_cameras" \
    "$PROJECT_DIR/backend/src/routes/managedCameraTokens.ts"
}

cd "$PROJECT_DIR"
install -d -o root -g root -m 0700 "$(dirname "$ENV_FILE")"
if [[ ! -f "$ENV_FILE" ]]; then
  cp deploy/env/master.env.example "$ENV_FILE"
  chown root:root "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  echo "Created $ENV_FILE. Edit secrets and rerun this script."
  exit 2
fi
chown root:root "$ENV_FILE"
chmod 0600 "$ENV_FILE"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

ensure_runtime_secrets
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

apply_managed_token_runtime_patches

cd "$PROJECT_DIR/backend"
npm ci --include=dev
npm run build
npm run migrate
npm run seed
npm prune --omit=dev

if [[ -f "$PROJECT_DIR/scripts/patch-system-managed-token-ui.py" ]]; then
  command -v python3 >/dev/null || {
    echo "python3 is required for managed-token UI patch" >&2
    exit 1
  }
  python3 "$PROJECT_DIR/scripts/patch-system-managed-token-ui.py" --project-dir "$PROJECT_DIR"
fi

if [[ -f "$PROJECT_DIR/scripts/patch-managed-media-gateway.py" ]]; then
  command -v python3 >/dev/null || {
    echo "python3 is required for managed media gateway patch" >&2
    exit 1
  }
  python3 "$PROJECT_DIR/scripts/patch-managed-media-gateway.py" --project-dir "$PROJECT_DIR"
  node --check "$PROJECT_DIR/smartyard-compat-proxy/server-node-aware.js"
  node --check "$PROJECT_DIR/smartyard-compat-proxy/server-events-gateway.js"
  node --check "$PROJECT_DIR/smartyard-compat-proxy/server-preview-gateway.js"
  node --check "$PROJECT_DIR/smartyard-compat-proxy/server-formats-gateway.js"
fi

cd "$PROJECT_DIR/frontend"
npm ci --include=dev
npm run build
install -d -o root -g root -m 0755 /var/www/newdomofon-video
rsync -a --delete dist/ /var/www/newdomofon-video/
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

install -d -o root -g root -m 0755 \
  /var/lib/newdomofon-video \
  /var/cache/newdomofon-video \
  /var/cache/newdomofon-video/smartyard-preview \
  /var/log/newdomofon-video

# All NewDomofon Master application units run as root. Keep the project tree
# root-only and normalize local ZIP/directory checkouts before systemd starts.
normalize_project_permissions

install -m 0644 "$PROJECT_DIR/deploy/systemd/newdomofon-video-backend.service" /etc/systemd/system/
install -m 0644 "$PROJECT_DIR/deploy/systemd/newdomofon-public-events-proxy.service" /etc/systemd/system/
if [[ -f "$PROJECT_DIR/deploy/systemd/newdomofon-smartyard-compat.service" ]]; then
  install -m 0644 "$PROJECT_DIR/deploy/systemd/newdomofon-smartyard-compat.service" /etc/systemd/system/
fi
install -m 0644 "$PROJECT_DIR/deploy/nginx/newdomofon-video.conf" /etc/nginx/sites-available/newdomofon-video.conf
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
if systemctl list-unit-files newdomofon-video-dvr.service >/dev/null 2>&1 || systemctl status newdomofon-video-dvr.service >/dev/null 2>&1; then
  systemctl disable --now newdomofon-video-dvr.service || true
fi

nginx -t
systemctl reload nginx

echo "Master deployed. NewDomofon application services run as root."
echo "PostgreSQL remains under postgres and Nginx workers remain under www-data."
if [[ "$INSTALL_DISK_GUARD" =~ ^(1|true|yes|on)$ ]]; then
  echo "Disk guard: cat /run/newdomofon-video/master-disk-state.json"
fi
if [[ "$INSTALL_RTSP_GATEWAY" =~ ^(1|true|yes|on)$ ]]; then
  echo "RTSP gateway: systemctl status newdomofon-video-rtsp-gateway.service"
fi

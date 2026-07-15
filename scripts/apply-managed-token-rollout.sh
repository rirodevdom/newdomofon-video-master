#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${1:-auto}"
MASTER_DIR="${MASTER_DIR:-/opt/newdomofon-video-master}"
NODE_DIR="${NODE_DIR:-/opt/newdomofon-video-node}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/newdomofon-video-backups/managed-token-rollout-${STAMP}}"
TARGET_REF="${TARGET_REF:-main}"

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Run this script as root"
command -v git >/dev/null || fail "git is required"
command -v curl >/dev/null || fail "curl is required"
command -v systemctl >/dev/null || fail "systemctl is required"

if [[ "$ROLE" == auto ]]; then
  if [[ -d "$MASTER_DIR/.git" ]] && systemctl list-unit-files newdomofon-video-backend.service >/dev/null 2>&1; then
    ROLE=master
  elif [[ -d "$NODE_DIR/.git" ]] && systemctl list-unit-files newdomofon-video-dvr.service >/dev/null 2>&1; then
    ROLE=node
  else
    fail "Cannot detect role. Use: $0 master  or  $0 node"
  fi
fi

install -d -m 0750 "$BACKUP_ROOT"

update_checkout() {
  local dir="$1"
  local remote_ref="refs/remotes/origin/${TARGET_REF}"
  [[ -d "$dir/.git" ]] || fail "Git checkout not found: $dir"
  git -C "$dir" status --short >"$BACKUP_ROOT/$(basename "$dir")-git-status.txt"
  git -C "$dir" diff --binary >"$BACKUP_ROOT/$(basename "$dir")-worktree.patch"
  git -C "$dir" stash push -u -m "before-managed-token-rollout-$STAMP" || true
  git -C "$dir" stash list >"$BACKUP_ROOT/$(basename "$dir")-git-stash-list.txt"

  # Fetch explicitly into a remote-tracking ref so slash branch names also work
  # on minimal production clones whose fetch refspec covers only the main branch.
  git -C "$dir" fetch --prune origin \
    "+refs/heads/${TARGET_REF}:${remote_ref}"
  git -C "$dir" show-ref --verify --quiet "$remote_ref" \
    || fail "Remote branch origin/${TARGET_REF} was not fetched"

  git -C "$dir" switch -C "$TARGET_REF" "$remote_ref"
  git -C "$dir" reset --hard "$remote_ref"
  git -C "$dir" log -1 --oneline
}

case "$ROLE" in
  master)
    command -v python3 >/dev/null || fail "python3 is required"
    command -v npm >/dev/null || fail "npm is required"
    command -v node >/dev/null || fail "node is required"
    command -v rsync >/dev/null || fail "rsync is required"
    command -v pg_dump >/dev/null || fail "pg_dump is required"
    command -v psql >/dev/null || fail "psql is required"
    command -v nginx >/dev/null || fail "nginx is required"
    command -v openssl >/dev/null || fail "openssl is required"

    log "Backing up master configuration and PostgreSQL"
    [[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
    cp -a "$ENV_FILE" "$BACKUP_ROOT/app.env"
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
    [[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL is missing"
    pg_dump -Fc "$DATABASE_URL" >"$BACKUP_ROOT/postgresql.dump"

    log "Updating master checkout"
    update_checkout "$MASTER_DIR"

    log "Preserving managed-token and internal gateway secrets"
    if ! grep -qE '^MANAGED_CAMERA_TOKEN_SECRET=.+$' "$ENV_FILE"; then
      [[ -n "${JWT_SECRET:-}" ]] || fail "JWT_SECRET is missing"
      sed -i '/^MANAGED_CAMERA_TOKEN_SECRET=/d' "$ENV_FILE"
      printf '\nMANAGED_CAMERA_TOKEN_SECRET=%s\n' "$JWT_SECRET" >>"$ENV_FILE"
    fi
    if ! grep -qE '^INTERNAL_DVR_SECRET=.+$' "$ENV_FILE"; then
      sed -i '/^INTERNAL_DVR_SECRET=/d' "$ENV_FILE"
      printf '\nINTERNAL_DVR_SECRET=%s\n' "$(openssl rand -hex 32)" >>"$ENV_FILE"
    fi
    chown root:root "$ENV_FILE"
    chmod 0600 "$ENV_FILE"

    log "Applying managed-token UI and media-gateway source patches"
    python3 "$MASTER_DIR/scripts/patch-system-managed-token-ui.py" --project-dir "$MASTER_DIR"
    python3 "$MASTER_DIR/scripts/patch-managed-media-gateway.py" --project-dir "$MASTER_DIR"
    node --check "$MASTER_DIR/smartyard-compat-proxy/server-node-aware.js"
    node --check "$MASTER_DIR/smartyard-compat-proxy/server-events-gateway.js"
    node --check "$MASTER_DIR/smartyard-compat-proxy/server-preview-gateway.js"
    node --check "$MASTER_DIR/smartyard-compat-proxy/server-formats-gateway.js"

    log "Building backend and frontend"
    cd "$MASTER_DIR/backend"
    npm ci --include=dev
    npm run build
    npm run migrate

    cd "$MASTER_DIR/frontend"
    npm ci --include=dev
    npm run build
    install -d -m 0755 /var/www/newdomofon-video
    rsync -a --delete dist/ /var/www/newdomofon-video/

    log "Installing and restarting master services"
    install -m 0644 \
      "$MASTER_DIR/deploy/systemd/newdomofon-smartyard-compat.service" \
      /etc/systemd/system/newdomofon-smartyard-compat.service
    systemctl daemon-reload
    systemctl restart newdomofon-video-backend.service
    systemctl enable newdomofon-smartyard-compat.service >/dev/null 2>&1 || true
    systemctl restart newdomofon-smartyard-compat.service
    for service in \
      newdomofon-video-smartyard-gateway.service \
      newdomofon-video-node-media-gateway.service \
      newdomofon-video-events-gateway.service \
      newdomofon-video-preview-gateway.service \
      newdomofon-video-rtsp-gateway.service; do
      systemctl list-unit-files "$service" >/dev/null 2>&1 && systemctl restart "$service" || true
    done
    nginx -t
    systemctl reload nginx

    log "Verifying master and managed media gateway"
    systemctl --no-pager --full status newdomofon-video-backend.service | sed -n '1,20p'
    systemctl --no-pager --full status newdomofon-smartyard-compat.service | sed -n '1,24p'
    curl -fsS http://127.0.0.1:3000/api/health
    echo
    curl -fsS http://127.0.0.1:3082/health | tee "$BACKUP_ROOT/smartyard-health.json"
    echo
    curl -fsS http://127.0.0.1:3084/health | tee "$BACKUP_ROOT/smartyard-node-aware-health.json"
    echo
    grep -q 'v301-node-aware-smartyard-gateway' "$BACKUP_ROOT/smartyard-node-aware-health.json" \
      || fail "Port 3084 is not running the node-aware SmartYard gateway"
    grep -q '"internal_secret_configured":true' "$BACKUP_ROOT/smartyard-node-aware-health.json" \
      || fail "Node-aware SmartYard gateway has no INTERNAL_DVR_SECRET"

    set -a
    . "$ENV_FILE"
    set +a
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "
      SELECT t.id, t.name, t.is_active, t.expires_at,
             count(a.camera_id) AS fallback_cameras
        FROM managed_camera_tokens t
        LEFT JOIN managed_camera_token_cameras a ON a.token_id = t.id
       WHERE t.id = '00000000-0000-4000-8000-000000000001'::uuid
       GROUP BY t.id, t.name, t.is_active, t.expires_at;

      SELECT c.id AS camera_without_any_token, c.name, c.stream_name
        FROM cameras c
       WHERE NOT EXISTS (
         SELECT 1 FROM managed_camera_token_cameras a WHERE a.camera_id = c.id
       );

      SELECT a.camera_id AS camera_with_system_and_custom
        FROM managed_camera_token_cameras a
       GROUP BY a.camera_id
      HAVING bool_or(a.token_id = '00000000-0000-4000-8000-000000000001'::uuid)
         AND bool_or(a.token_id <> '00000000-0000-4000-8000-000000000001'::uuid);
    "
    ;;

  node)
    command -v npm >/dev/null || fail "npm is required"

    log "Backing up node configuration"
    [[ -f "$ENV_FILE" ]] && cp -a "$ENV_FILE" "$BACKUP_ROOT/app.env"

    log "Updating node checkout"
    update_checkout "$NODE_DIR"

    log "Deploying node"
    PROJECT_DIR="$NODE_DIR" \
    ENV_FILE="$ENV_FILE" \
    INSTALL_DISK_GUARD=1 \
    INSTALL_JOURNAL_LIMITS=1 \
    INSTALL_ARCHIVE_EVENT_SYNC=1 \
      bash "$NODE_DIR/scripts/deploy-node.sh"

    log "Verifying node"
    systemctl --no-pager --full status newdomofon-video-dvr.service | sed -n '1,24p'
    curl -fsS http://127.0.0.1:3010/health
    echo
    ;;

  *)
    fail "Unknown role '$ROLE'. Use master, node or auto"
    ;;
esac

log "Rollout completed. Backup: $BACKUP_ROOT"

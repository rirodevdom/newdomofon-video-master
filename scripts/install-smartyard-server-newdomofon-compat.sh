#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

RBT_DIR="/opt/rbt/server"
TARGET_FILE=""
SERVICE_NAME="${SMARTYARD_SERVICE:-}"
BACKUP_ROOT="/var/backups/newdomofon-video/smartyard-server"
DRY_RUN="false"
NO_RESTART="false"

usage() {
  cat <<'EOF'
Install server-side NewDomofon compatibility into AXIOSTV SmartYard-Server.

No SmartYard-Vue source or built frontend is changed.

Usage:
  sudo bash scripts/install-smartyard-server-newdomofon-compat.sh [options]

Options:
  --rbt-dir PATH       SmartYard server directory (default: /opt/rbt/server)
  --target PATH        Exact smartyard.py path
  --service UNIT       systemd service to restart after validation
  --backup-root PATH   Backup directory
  --dry-run            Validate against a temporary copy only
  --no-restart         Patch and validate without restarting a service
  -h, --help           Show this help
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --rbt-dir) RBT_DIR="${2:-}"; shift 2 ;;
    --target) TARGET_FILE="${2:-}"; shift 2 ;;
    --service) SERVICE_NAME="${2:-}"; shift 2 ;;
    --backup-root) BACKUP_ROOT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --no-restart) NO_RESTART="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

if [[ "$DRY_RUN" != "true" ]]; then
  [[ "$(id -u)" -eq 0 ]] || fail "Run as root"
fi
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

RBT_DIR="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$RBT_DIR")"
if [[ -z "$TARGET_FILE" ]]; then
  TARGET_FILE="$RBT_DIR/smartyard.py"
fi
TARGET_FILE="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$TARGET_FILE")"

PATCHER="$PROJECT_DIR/scripts/patch-smartyard-server-newdomofon-media.py"
MODULE_SOURCE="$PROJECT_DIR/integrations/smartyard-server/newdomofon_media_compat.py"
MODULE_TARGET="$(dirname "$TARGET_FILE")/newdomofon_media_compat.py"

[[ -f "$TARGET_FILE" ]] || fail "SmartYard server source not found: $TARGET_FILE"
[[ -f "$PATCHER" ]] || fail "Patcher not found: $PATCHER"
[[ -f "$MODULE_SOURCE" ]] || fail "Compatibility module not found: $MODULE_SOURCE"

python3 -m py_compile "$PATCHER" "$MODULE_SOURCE"

if [[ "$DRY_RUN" == "true" ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cp -a "$TARGET_FILE" "$TMP/smartyard.py"
  cp -a "$MODULE_SOURCE" "$TMP/newdomofon_media_compat.py"

  python3 "$PATCHER" --target "$TMP/smartyard.py"
  python3 "$PATCHER" --target "$TMP/smartyard.py"
  python3 -m py_compile "$TMP/smartyard.py" "$TMP/newdomofon_media_compat.py"

  echo "DRY RUN passed"
  echo "target=$TARGET_FILE"
  echo "SmartYard-Vue changed=false"
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_ROOT/$STAMP"
install -d -m 0700 "$BACKUP"

cp -a "$TARGET_FILE" "$BACKUP/smartyard.py.before"
if [[ -f "$MODULE_TARGET" ]]; then
  cp -a "$MODULE_TARGET" "$BACKUP/newdomofon_media_compat.py.before"
fi

rollback() {
  local rc=$?
  trap - ERR
  echo "Compatibility install failed; restoring backup" >&2
  cp -a "$BACKUP/smartyard.py.before" "$TARGET_FILE"
  if [[ -f "$BACKUP/newdomofon_media_compat.py.before" ]]; then
    cp -a "$BACKUP/newdomofon_media_compat.py.before" "$MODULE_TARGET"
  else
    rm -f "$MODULE_TARGET"
  fi
  python3 -m py_compile "$TARGET_FILE" || true
  if [[ -n "$SERVICE_NAME" ]] && systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    systemctl restart "$SERVICE_NAME" || true
  fi
  exit "$rc"
}
trap rollback ERR

TARGET_UID="$(stat -c '%u' "$TARGET_FILE")"
TARGET_GID="$(stat -c '%g' "$TARGET_FILE")"
install -o "$TARGET_UID" -g "$TARGET_GID" -m 0644 \
  "$MODULE_SOURCE" "$MODULE_TARGET"
python3 "$PATCHER" --target "$TARGET_FILE"
python3 "$PATCHER" --target "$TARGET_FILE"
chown "$TARGET_UID:$TARGET_GID" "$TARGET_FILE" "$MODULE_TARGET"
python3 -m py_compile "$TARGET_FILE" "$MODULE_TARGET"

if [[ "$NO_RESTART" != "true" ]]; then
  if [[ -z "$SERVICE_NAME" ]]; then
    mapfile -t candidates < <(
      systemctl list-units --type=service --state=running --no-legend 2>/dev/null |
        awk '{print $1}' |
        grep -Ei '(^|[-_.])(rbt|smartyard)([-_.]|$)' || true
    )
    if ((${#candidates[@]} == 1)); then
      SERVICE_NAME="${candidates[0]}"
    else
      echo "Active SmartYard/RBT service was not uniquely detected." >&2
      printf 'Candidate: %s\n' "${candidates[@]:-none}" >&2
      fail "Run again with --service UNIT or use --no-restart"
    fi
  fi

  systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 ||
    fail "systemd service not found: $SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
  systemctl is-active --quiet "$SERVICE_NAME" ||
    fail "service is not active after restart: $SERVICE_NAME"
fi

trap - ERR

echo "SmartYard server compatibility installed"
echo "target=$TARGET_FILE"
echo "module=$MODULE_TARGET"
echo "service=${SERVICE_NAME:-not-restarted}"
echo "backup=$BACKUP"
echo "SmartYard-Vue changed=false"

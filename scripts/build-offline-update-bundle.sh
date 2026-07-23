#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/offline-bundles}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d /tmp/newdomofon-master-offline-build-XXXXXX)}"
KEEP_WORK="${KEEP_WORK:-false}"
COMMIT="${SOURCE_COMMIT:-${GITHUB_SHA:-}}"

cleanup() {
  if [[ "$KEEP_WORK" != true && -n "$WORK_ROOT" && -d "$WORK_ROOT" ]]; then
    rm -rf "$WORK_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

show_failure() {
  local title="$1"
  local logfile="$2"
  echo >&2
  echo "===== FAILED: $title =====" >&2
  tail -n 250 "$logfile" >&2 || true
  fail "$title"
}

for command in git node npm python3 tar sha256sum find; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

if [[ -z "$COMMIT" ]]; then
  COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
fi
git -C "$ROOT" cat-file -e "${COMMIT}^{commit}"

SHORT_COMMIT="${COMMIT:0:12}"
BUNDLE_NAME="newdomofon-video-master-offline-${SHORT_COMMIT}"
STAGE_PARENT="$WORK_ROOT/stage"
STAGE="$STAGE_PARENT/$BUNDLE_NAME"
CACHE="$WORK_ROOT/npm-cache"
LOG_DIR="$WORK_ROOT/logs"
PACKAGE_DIRS=(backend frontend public-events-proxy)

mkdir -p "$STAGE" "$CACHE" "$OUTPUT_DIR" "$LOG_DIR"
git -C "$ROOT" archive --format=tar "$COMMIT" | tar -xf - -C "$STAGE"

export npm_config_cache="$CACHE"
export npm_config_audit=false
export npm_config_fund=false
export npm_config_update_notifier=false

prepare_source() {
  local logfile="$LOG_DIR/prepare-source.log"
  if ! PROJECT_DIR="$STAGE" bash "$STAGE/scripts/prepare-master-runtime-source.sh" >"$logfile" 2>&1; then
    show_failure "prepare runtime source" "$logfile"
  fi
  tail -n 20 "$logfile"
}

install_packages() {
  local offline="$1"
  local phase="online"
  if [[ "$offline" == true ]]; then
    phase="offline"
    export npm_config_offline=true
    export npm_config_prefer_offline=true
    unset npm_config_prefer_online || true
  else
    unset npm_config_offline || true
    unset npm_config_prefer_offline || true
    export npm_config_prefer_online=true
  fi

  local dir logfile
  for dir in "${PACKAGE_DIRS[@]}"; do
    [[ -f "$STAGE/$dir/package.json" ]] || fail "Missing $dir/package.json"
    [[ -f "$STAGE/$dir/package-lock.json" ]] || fail "Missing $dir/package-lock.json"
    rm -rf "$STAGE/$dir/node_modules"
    logfile="$LOG_DIR/npm-ci-${phase}-${dir}.log"
    echo "npm ci ($phase): $dir"
    if ! (
      cd "$STAGE/$dir"
      npm ci --include=dev --loglevel=error
    ) >"$logfile" 2>&1; then
      show_failure "npm ci ($phase): $dir" "$logfile"
    fi
  done
}

build_sources() {
  local phase="$1"
  local logfile="$LOG_DIR/build-${phase}-backend.log"
  echo "build ($phase): backend"
  if ! (
    cd "$STAGE/backend"
    rm -rf dist
    npm run build --silent
  ) >"$logfile" 2>&1; then
    show_failure "build ($phase): backend" "$logfile"
  fi

  logfile="$LOG_DIR/build-${phase}-frontend.log"
  echo "build ($phase): frontend"
  if ! (
    cd "$STAGE/frontend"
    rm -rf dist
    npm run build --silent
  ) >"$logfile" 2>&1; then
    show_failure "build ($phase): frontend" "$logfile"
  fi

  node --check "$STAGE/smartyard-compat-proxy/server-node-aware.js"
  node --check "$STAGE/smartyard-compat-proxy/server-formats-gateway.js"
}

echo "Preparing runtime source for $COMMIT"
prepare_source

echo "Populating npm cache"
install_packages false
build_sources online

echo "Verifying a second clean build with npm network disabled"
install_packages true
build_sources offline

for dir in "${PACKAGE_DIRS[@]}"; do
  rm -rf "$STAGE/$dir/node_modules"
done
rm -rf "$STAGE/backend/dist" "$STAGE/frontend/dist"
mkdir -p "$STAGE/.offline-update"

tar -C "$WORK_ROOT" -czf "$STAGE/.offline-update/npm-cache.tar.gz" npm-cache
(
  cd "$STAGE/.offline-update"
  sha256sum npm-cache.tar.gz > npm-cache.tar.gz.sha256
)

cat >"$STAGE/.offline-update/manifest.env" <<EOF
project_type=master
source_commit=$COMMIT
source_short_commit=$SHORT_COMMIT
created_at=$(date --iso-8601=seconds)
platform=$(node -p 'process.platform')
architecture=$(node -p 'process.arch')
node_version=$(node -p 'process.versions.node')
npm_version=$(npm --version)
cache_format=npm-cacache-tar-gzip-v1
EOF

bash -n "$STAGE/offline-update.sh"
bash -n "$STAGE/update-installed-project.sh"

FINAL_ARCHIVE="$OUTPUT_DIR/${BUNDLE_NAME}.tar.gz"
tar -C "$STAGE_PARENT" -czf "$FINAL_ARCHIVE" "$BUNDLE_NAME"
sha256sum "$FINAL_ARCHIVE" >"$FINAL_ARCHIVE.sha256"

cat >"$OUTPUT_DIR/${BUNDLE_NAME}.txt" <<EOF
project_type=master
source_commit=$COMMIT
archive=$(basename "$FINAL_ARCHIVE")
sha256=$(sha256sum "$FINAL_ARCHIVE" | awk '{print $1}')
platform=$(node -p 'process.platform')
architecture=$(node -p 'process.arch')
node_version=$(node -p 'process.versions.node')
npm_version=$(npm --version)
EOF

printf '\nOffline master bundle created:\n  %s\n  %s\n' \
  "$FINAL_ARCHIVE" "$FINAL_ARCHIVE.sha256"

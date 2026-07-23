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

for command in git node npm python3 tar sha256sum; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

if [[ -z "$COMMIT" ]]; then
  COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
fi
git -C "$ROOT" cat-file -e "${COMMIT}^{commit}"

SHORT_COMMIT="${COMMIT:0:12}"
BUNDLE_NAME="newdomofon-video-master-offline-${SHORT_COMMIT}"
ONLINE_STAGE="$WORK_ROOT/online/$BUNDLE_NAME"
OFFLINE_STAGE="$WORK_ROOT/offline/$BUNDLE_NAME"
SHIP_PARENT="$WORK_ROOT/stage"
SHIP_STAGE="$SHIP_PARENT/$BUNDLE_NAME"
CACHE="$WORK_ROOT/npm-cache"
LOG_DIR="$WORK_ROOT/logs"
PACKAGE_DIRS=(backend frontend public-events-proxy)

mkdir -p "$CACHE" "$OUTPUT_DIR" "$LOG_DIR"

extract_commit() {
  local destination="$1"
  rm -rf "$destination"
  mkdir -p "$destination"
  git -C "$ROOT" archive --format=tar "$COMMIT" | tar -xf - -C "$destination"
}

export npm_config_cache="$CACHE"
export npm_config_audit=false
export npm_config_fund=false
export npm_config_update_notifier=false

prepare_source() {
  local stage="$1"
  local phase="$2"
  local logfile="$LOG_DIR/prepare-source-${phase}.log"
  if ! PROJECT_DIR="$stage" bash "$stage/scripts/prepare-master-runtime-source.sh" >"$logfile" 2>&1; then
    show_failure "prepare runtime source ($phase)" "$logfile"
  fi
  tail -n 20 "$logfile"
}

install_packages() {
  local stage="$1"
  local phase="$2"
  local offline="$3"

  if [[ "$offline" == true ]]; then
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
    [[ -f "$stage/$dir/package.json" ]] || fail "Missing $dir/package.json"
    [[ -f "$stage/$dir/package-lock.json" ]] || fail "Missing $dir/package-lock.json"
    rm -rf "$stage/$dir/node_modules"
    logfile="$LOG_DIR/npm-ci-${phase}-${dir}.log"
    echo "npm ci ($phase): $dir"
    if ! (
      cd "$stage/$dir"
      npm ci --include=dev --loglevel=error
    ) >"$logfile" 2>&1; then
      show_failure "npm ci ($phase): $dir" "$logfile"
    fi
  done
}

build_sources() {
  local stage="$1"
  local phase="$2"
  local logfile="$LOG_DIR/build-${phase}-backend.log"

  echo "build ($phase): backend"
  if ! (
    cd "$stage/backend"
    rm -rf dist
    npm run build --silent
  ) >"$logfile" 2>&1; then
    show_failure "build ($phase): backend" "$logfile"
  fi

  logfile="$LOG_DIR/build-${phase}-frontend.log"
  echo "build ($phase): frontend"
  if ! (
    cd "$stage/frontend"
    rm -rf dist
    npm run build --silent
  ) >"$logfile" 2>&1; then
    show_failure "build ($phase): frontend" "$logfile"
  fi

  node --check "$stage/smartyard-compat-proxy/server-node-aware.js"
  node --check "$stage/smartyard-compat-proxy/server-formats-gateway.js"
}

echo "Populating npm cache from exact commit $COMMIT"
extract_commit "$ONLINE_STAGE"
prepare_source "$ONLINE_STAGE" online
install_packages "$ONLINE_STAGE" online false
build_sources "$ONLINE_STAGE" online

echo "Verifying a fresh checkout with npm network disabled"
extract_commit "$OFFLINE_STAGE"
prepare_source "$OFFLINE_STAGE" offline
install_packages "$OFFLINE_STAGE" offline true
build_sources "$OFFLINE_STAGE" offline

# Ship a third, pristine archive of the exact commit. Production updater/deploy
# applies runtime patchers once in its normal order. This avoids shipping source
# already mutated by verification builds and proves the package starts clean.
extract_commit "$SHIP_STAGE"
mkdir -p "$SHIP_STAGE/.offline-update"

tar -C "$WORK_ROOT" -czf "$SHIP_STAGE/.offline-update/npm-cache.tar.gz" npm-cache
(
  cd "$SHIP_STAGE/.offline-update"
  sha256sum npm-cache.tar.gz > npm-cache.tar.gz.sha256
)

cat >"$SHIP_STAGE/.offline-update/manifest.env" <<EOF
project_type=master
source_commit=$COMMIT
source_short_commit=$SHORT_COMMIT
created_at=$(date --iso-8601=seconds)
platform=$(node -p 'process.platform')
architecture=$(node -p 'process.arch')
node_version=$(node -p 'process.versions.node')
npm_version=$(npm --version)
cache_format=npm-cacache-tar-gzip-v1
offline_verification=fresh-checkout-build-passed
EOF

bash -n "$SHIP_STAGE/offline-update.sh"
bash -n "$SHIP_STAGE/update-installed-project.sh"

FINAL_ARCHIVE="$OUTPUT_DIR/${BUNDLE_NAME}.tar.gz"
FINAL_NAME="$(basename "$FINAL_ARCHIVE")"
tar -C "$SHIP_PARENT" -czf "$FINAL_ARCHIVE" "$BUNDLE_NAME"
(
  cd "$OUTPUT_DIR"
  sha256sum "$FINAL_NAME" >"${FINAL_NAME}.sha256"
)

cat >"$OUTPUT_DIR/${BUNDLE_NAME}.txt" <<EOF
project_type=master
source_commit=$COMMIT
archive=$FINAL_NAME
sha256=$(sha256sum "$FINAL_ARCHIVE" | awk '{print $1}')
platform=$(node -p 'process.platform')
architecture=$(node -p 'process.arch')
node_version=$(node -p 'process.versions.node')
npm_version=$(npm --version)
offline_verification=fresh-checkout-build-passed
EOF

printf '\nOffline master bundle created:\n  %s\n  %s\n' \
  "$FINAL_ARCHIVE" "$FINAL_ARCHIVE.sha256"

#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 77
fi

[[ -d "$PROJECT_DIR" ]] || {
  echo "Project directory not found: $PROJECT_DIR" >&2
  exit 66
}

# All NewDomofon Master application services run as root. Keep the production
# source tree root-only so local ZIP/directory installs cannot inherit unusable
# ownership or expose source/configuration to other Linux users.
chown -R root:root "$PROJECT_DIR"
chmod -R u+rwX,go-rwx "$PROJECT_DIR"
chmod 0700 "$PROJECT_DIR"

for required in \
  "$PROJECT_DIR/backend" \
  "$PROJECT_DIR/backend/dist" \
  "$PROJECT_DIR/backend/dist/index.js" \
  "$PROJECT_DIR/public-events-proxy" \
  "$PROJECT_DIR/smartyard-compat-proxy"; do
  [[ -e "$required" ]] || continue
  test -r "$required"
done

test -x "$PROJECT_DIR/backend"
test -x "$PROJECT_DIR/backend/dist"
test -r "$PROJECT_DIR/backend/dist/index.js"

echo "Project runtime permissions normalized for root: $PROJECT_DIR"
namei -l "$PROJECT_DIR/backend/dist/index.js"

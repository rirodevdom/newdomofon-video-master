#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
RUNTIME_USER="${RUNTIME_USER:-newdomofon}"
RUNTIME_GROUP="${RUNTIME_GROUP:-newdomofon}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 77
fi

[[ -d "$PROJECT_DIR" ]] || {
  echo "Project directory not found: $PROJECT_DIR" >&2
  exit 66
}

getent passwd "$RUNTIME_USER" >/dev/null || {
  echo "Runtime user not found: $RUNTIME_USER" >&2
  exit 67
}

getent group "$RUNTIME_GROUP" >/dev/null || {
  echo "Runtime group not found: $RUNTIME_GROUP" >&2
  exit 67
}

# Local archive/directory installation runs with umask 077 and creates a
# temporary root-only Git source. Git can therefore create the production
# checkout with mode 0700/0600. systemd services run as newdomofon and must be
# able to traverse directories and read application files.
chown -R root:"$RUNTIME_GROUP" "$PROJECT_DIR"
chmod -R g+rX,o-rwx "$PROJECT_DIR"
chmod 0750 "$PROJECT_DIR"

# Git metadata is not needed by runtime services. Keep it root-only while the
# application tree stays readable by the newdomofon group.
if [[ -d "$PROJECT_DIR/.git" ]]; then
  chown -R root:root "$PROJECT_DIR/.git"
  chmod -R go-rwx "$PROJECT_DIR/.git"
fi

for required in \
  "$PROJECT_DIR/backend" \
  "$PROJECT_DIR/backend/dist" \
  "$PROJECT_DIR/public-events-proxy" \
  "$PROJECT_DIR/smartyard-compat-proxy"; do
  [[ -e "$required" ]] || continue
  sudo -u "$RUNTIME_USER" test -x "$required"
done

sudo -u "$RUNTIME_USER" test -r "$PROJECT_DIR/backend/dist/index.js"

echo "Project runtime permissions normalized: $PROJECT_DIR"
namei -l "$PROJECT_DIR/backend/dist/index.js"

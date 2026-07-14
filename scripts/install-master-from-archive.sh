#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
PUBLIC_REPO_URL="${PUBLIC_REPO_URL:-https://github.com/rirodevdom/newdomofon-video-master.git}"
SOURCE_ARCHIVE="${SOURCE_ARCHIVE:-}"
SOURCE_DIRECTORY="${SOURCE_DIRECTORY:-${SOURCE_DIR:-}}"
STAMP="$(date +%Y%m%d-%H%M%S)"

PASSTHROUGH_ARGS=()
while (($#)); do
  case "$1" in
    --archive)
      SOURCE_ARCHIVE="${2:-}"
      shift 2
      ;;
    --source-dir)
      SOURCE_DIRECTORY="${2:-}"
      shift 2
      ;;
    --project-dir)
      PROJECT_DIR="${2:-}"
      PASSTHROUGH_ARGS+=("$1" "$2")
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  install-master-from-archive.sh --archive /root/project.zip [installer options]
  install-master-from-archive.sh --source-dir /root/project [installer options]

Source options:
  --archive PATH      Use a local ZIP/TAR archive.
  --source-dir PATH   Use an already extracted project directory.

All other options are passed to install-master-one-shot.sh, for example:
  --domain DOMAIN --email EMAIL --admin-login LOGIN --no-tls
EOF
      exit 0
      ;;
    *)
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 77
fi

if [[ -n "$SOURCE_ARCHIVE" && -n "$SOURCE_DIRECTORY" ]]; then
  echo "Use either --archive or --source-dir, not both" >&2
  exit 64
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates git rsync unzip tar findutils

WORK_DIR="$(mktemp -d /root/newdomofon-local-install.XXXXXX)"
OLD_PROJECT_BACKUP=""
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

find_source_root() {
  local search_root="$1"
  local helper

  [[ -d "$search_root" ]] || return 1

  if [[ -f "$search_root/scripts/lib/master-one-shot-install.sh" ]]; then
    printf '%s\n' "$(cd "$search_root" && pwd)"
    return 0
  fi

  helper="$(find "$search_root" -maxdepth 6 -type f \
    -path '*/scripts/lib/master-one-shot-install.sh' \
    -print -quit 2>/dev/null)"
  [[ -n "$helper" ]] || return 1
  dirname "$(dirname "$(dirname "$helper")")"
}

find_extracted_source_in_root() {
  local helper

  if [[ -f /root/scripts/lib/master-one-shot-install.sh ]]; then
    printf '%s\n' /root
    return 0
  fi

  helper="$(find /root -mindepth 2 -maxdepth 6 -type f \
    -path '*/scripts/lib/master-one-shot-install.sh' \
    -not -path '/root/newdomofon-local-install.*/*' \
    -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | head -1 \
    | cut -d' ' -f2-)"
  [[ -n "$helper" ]] || return 1
  dirname "$(dirname "$(dirname "$helper")")"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT=""
SOURCE_DESCRIPTION=""

if [[ -n "$SOURCE_DIRECTORY" ]]; then
  [[ -d "$SOURCE_DIRECTORY" ]] || {
    echo "Source directory not found: $SOURCE_DIRECTORY" >&2
    exit 66
  }

  SOURCE_ROOT="$(find_source_root "$SOURCE_DIRECTORY")" || {
    echo "The directory does not contain NewDomofon Video Master sources: $SOURCE_DIRECTORY" >&2
    exit 65
  }
  SOURCE_DESCRIPTION="directory:${SOURCE_ROOT}"
  echo "Using already extracted project directory: $SOURCE_ROOT"
elif [[ -n "$SOURCE_ARCHIVE" ]]; then
  [[ -f "$SOURCE_ARCHIVE" ]] || {
    echo "Archive not found: $SOURCE_ARCHIVE" >&2
    exit 66
  }

  echo "Using local project archive: $SOURCE_ARCHIVE"
  case "$SOURCE_ARCHIVE" in
    *.zip)
      unzip -q "$SOURCE_ARCHIVE" -d "$WORK_DIR/extracted"
      ;;
    *.tar.gz|*.tgz)
      install -d -m 0700 "$WORK_DIR/extracted"
      tar -xzf "$SOURCE_ARCHIVE" -C "$WORK_DIR/extracted"
      ;;
    *.tar)
      install -d -m 0700 "$WORK_DIR/extracted"
      tar -xf "$SOURCE_ARCHIVE" -C "$WORK_DIR/extracted"
      ;;
    *)
      echo "Supported archives: .zip, .tar.gz, .tgz, .tar" >&2
      exit 64
      ;;
  esac
  SOURCE_ROOT="$(find_source_root "$WORK_DIR/extracted")" || {
    echo "The archive does not contain NewDomofon Video Master sources" >&2
    exit 65
  }
  SOURCE_DESCRIPTION="archive:${SOURCE_ARCHIVE}"
elif [[ -f "$CURRENT_SOURCE_ROOT/scripts/lib/master-one-shot-install.sh" ]]; then
  SOURCE_ROOT="$CURRENT_SOURCE_ROOT"
  SOURCE_DESCRIPTION="directory:${SOURCE_ROOT}"
  echo "Using the extracted project that contains this installer: $SOURCE_ROOT"
else
  SOURCE_ROOT="$(find_extracted_source_in_root || true)"
  if [[ -n "$SOURCE_ROOT" ]]; then
    SOURCE_DESCRIPTION="directory:${SOURCE_ROOT}"
    echo "Automatically found extracted project directory: $SOURCE_ROOT"
  else
    SOURCE_ARCHIVE="$(find /root -maxdepth 1 -type f \
      \( -name 'newdomofon-video-master*.zip' \
         -o -name 'newdomofon-video-master*.tar.gz' \
         -o -name 'newdomofon-video-master*.tgz' \
         -o -name 'newdomofon-video-master*.tar' \) \
      -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
    [[ -n "$SOURCE_ARCHIVE" ]] || {
      echo "No extracted project directory or project archive was found in /root" >&2
      echo "Use --source-dir /root/<folder> or --archive /root/<archive>.zip" >&2
      exit 66
    }
    exec bash "$0" --archive "$SOURCE_ARCHIVE" "${PASSTHROUGH_ARGS[@]}"
  fi
fi

for required in \
  backend/package.json \
  frontend/package.json \
  scripts/deploy-master.sh \
  scripts/install-master-one-shot.sh \
  scripts/lib/master-one-shot-install.sh; do
  [[ -e "$SOURCE_ROOT/$required" ]] || {
    echo "Missing required project file: $required" >&2
    exit 65
  }
done

LOCAL_REPO="$WORK_DIR/local-repository"
install -d -m 0700 "$LOCAL_REPO"
rsync -a --delete \
  --exclude '.git/' \
  --exclude 'node_modules/' \
  --exclude 'dist/' \
  "$SOURCE_ROOT/" "$LOCAL_REPO/"

cd "$LOCAL_REPO"
git init -q -b main
git config user.name 'NewDomofon Local Installer'
git config user.email 'local-installer@localhost'
git add -A
git commit -q -m 'Local source installation snapshot'
LOCAL_COMMIT="$(git rev-parse HEAD)"

if [[ -e "$PROJECT_DIR" ]]; then
  OLD_PROJECT_BACKUP="${PROJECT_DIR}.before-local-source-${STAMP}"
  echo "Moving existing project to: $OLD_PROJECT_BACKUP"
  mv "$PROJECT_DIR" "$OLD_PROJECT_BACKUP"
fi

export REPO_URL="file://${LOCAL_REPO}"
export REPO_BRANCH=main
export PROJECT_DIR

set +e
bash "$LOCAL_REPO/scripts/install-master-one-shot.sh" "${PASSTHROUGH_ARGS[@]}"
RC=$?
set -e

if [[ -d "$PROJECT_DIR/.git" ]]; then
  git -C "$PROJECT_DIR" remote set-url origin "$PUBLIC_REPO_URL" || true
  {
    printf '%s\n' "local-source-commit=${LOCAL_COMMIT}"
    printf '%s\n' "local-source=${SOURCE_DESCRIPTION}"
  } >"$PROJECT_DIR/.installed-from-local-source"
fi

if (( RC != 0 )); then
  echo
  echo "Local source installation failed with exit code $RC" >&2
  [[ -n "$OLD_PROJECT_BACKUP" ]] && \
    echo "Previous project backup: $OLD_PROJECT_BACKUP" >&2
  exit "$RC"
fi

echo
echo "LOCAL SOURCE MASTER INSTALLATION COMPLETED"
echo "Source: $SOURCE_DESCRIPTION"
echo "Installed project: $PROJECT_DIR"
echo "Local source commit: $LOCAL_COMMIT"
[[ -n "$OLD_PROJECT_BACKUP" ]] && echo "Previous project backup: $OLD_PROJECT_BACKUP"

#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SOURCE_DIRECTORY="${SOURCE_DIRECTORY:-${SOURCE_DIR:-}}"
PASSTHROUGH_ARGS=()

while (($#)); do
  case "$1" in
    --source-dir)
      SOURCE_DIRECTORY="${2:-}"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  install-master-from-directory.sh [--source-dir /root/project] [installer options]

If --source-dir is omitted, the script uses its own project directory or
automatically finds the newest extracted NewDomofon Video Master directory
inside /root.

Examples:
  bash scripts/install-master-from-directory.sh
  bash scripts/install-master-from-directory.sh --domain video.example.com
  bash /root/install-master-from-directory.sh --source-dir /root/newdomofon-video-master-main --domain video.example.com
EOF
      exit 0
      ;;
    *)
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || {
  echo "Run as root" >&2
  exit 77
}

find_project_root() {
  local search_root="$1"
  local helper

  [[ -d "$search_root" ]] || return 1

  if [[ -f "$search_root/scripts/install-master-from-archive.sh" &&
        -f "$search_root/scripts/lib/master-one-shot-install.sh" ]]; then
    printf '%s\n' "$(cd "$search_root" && pwd)"
    return 0
  fi

  helper="$(find "$search_root" -maxdepth 6 -type f \
    -path '*/scripts/install-master-from-archive.sh' \
    -print -quit 2>/dev/null)"
  [[ -n "$helper" ]] || return 1
  dirname "$(dirname "$helper")"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_SOURCE=""

if [[ -n "$SOURCE_DIRECTORY" ]]; then
  PROJECT_SOURCE="$(find_project_root "$SOURCE_DIRECTORY")" || {
    echo "The specified directory does not contain NewDomofon Video Master: $SOURCE_DIRECTORY" >&2
    exit 65
  }
elif [[ -f "$SCRIPT_PROJECT_ROOT/scripts/lib/master-one-shot-install.sh" ]]; then
  PROJECT_SOURCE="$SCRIPT_PROJECT_ROOT"
else
  HELPER="$(find /root -mindepth 2 -maxdepth 6 -type f \
    -path '*/scripts/install-master-from-archive.sh' \
    -not -path '/root/newdomofon-local-install.*/*' \
    -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | head -1 \
    | cut -d' ' -f2-)"

  [[ -n "$HELPER" ]] || {
    echo "No extracted NewDomofon Video Master directory was found in /root" >&2
    echo "Use --source-dir /root/<folder>" >&2
    exit 66
  }
  PROJECT_SOURCE="$(dirname "$(dirname "$HELPER")")"
fi

echo "Using extracted project directory: $PROJECT_SOURCE"

exec bash "$PROJECT_SOURCE/scripts/install-master-from-archive.sh" \
  --source-dir "$PROJECT_SOURCE" \
  "${PASSTHROUGH_ARGS[@]}"

#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Установка NewDomofon Video Master из локального ZIP/TAR или уже
# распакованной папки. Git и доступ к репозиторию не используются.

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
SOURCE_ARCHIVE="${SOURCE_ARCHIVE:-}"
SOURCE_DIRECTORY="${SOURCE_DIRECTORY:-${SOURCE_DIR:-}}"
PASSTHROUGH_ARGS=()
WORK_DIR=""

usage() {
  cat <<'EOF'
Установка NewDomofon Video Master без Git, только из локального архива
или уже распакованной папки.

Использование:
  sudo bash scripts/install-master-from-archive.sh \
    --source-dir /root/newdomofon-video-master-main [опции]

  sudo bash scripts/install-master-from-archive.sh \
    --archive /root/newdomofon-video-master-main.zip [опции]

Источник:
  --archive PATH      Локальный ZIP/TAR архив.
  --source-dir PATH   Уже распакованный проект.
  --project-dir PATH  Каталог установки.
                      По умолчанию: /opt/newdomofon-video-master

Остальные параметры передаются в install-master-local-root.sh:
  --domain DOMAIN --email EMAIL --admin-login LOGIN --no-tls
  --tls --regenerate-secrets --skip-rtsp --require-rtsp
  --mediamtx-archive PATH
EOF
}

cleanup() {
  [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

is_project_root() {
  local root="$1"
  [[ -d "$root" ]] &&
  [[ -f "$root/backend/package.json" ]] &&
  [[ -f "$root/frontend/package.json" ]] &&
  [[ -f "$root/scripts/install-master-local-root.sh" ]]
}

find_source_root() {
  local search_root="$1"
  local helper=""

  if is_project_root "$search_root"; then
    printf '%s\n' "$(cd "$search_root" && pwd)"
    return 0
  fi

  helper="$(
    find "$search_root" -maxdepth 7 -type f \
      -path '*/scripts/install-master-local-root.sh' \
      -print -quit 2>/dev/null
  )"
  [[ -n "$helper" ]] || return 1

  local root
  root="$(dirname "$(dirname "$helper")")"
  is_project_root "$root" || return 1
  printf '%s\n' "$(cd "$root" && pwd)"
}

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
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || {
  echo "Запустите установщик от root" >&2
  exit 77
}

if [[ -n "$SOURCE_ARCHIVE" && -n "$SOURCE_DIRECTORY" ]]; then
  echo "Используйте только один источник: --archive или --source-dir" >&2
  exit 64
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates rsync unzip tar findutils python3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT=""

if [[ -n "$SOURCE_DIRECTORY" ]]; then
  [[ -d "$SOURCE_DIRECTORY" ]] || {
    echo "Папка не найдена: $SOURCE_DIRECTORY" >&2
    exit 66
  }
  SOURCE_ROOT="$(find_source_root "$SOURCE_DIRECTORY")" || {
    echo "В папке не найден проект Master: $SOURCE_DIRECTORY" >&2
    exit 65
  }
elif [[ -n "$SOURCE_ARCHIVE" ]]; then
  [[ -f "$SOURCE_ARCHIVE" ]] || {
    echo "Архив не найден: $SOURCE_ARCHIVE" >&2
    exit 66
  }

  WORK_DIR="$(mktemp -d /root/newdomofon-master-archive.XXXXXX)"
  install -d -m 0700 "$WORK_DIR/extracted"

  case "$SOURCE_ARCHIVE" in
    *.zip)
      unzip -q "$SOURCE_ARCHIVE" -d "$WORK_DIR/extracted"
      ;;
    *.tar.gz|*.tgz)
      tar -xzf "$SOURCE_ARCHIVE" -C "$WORK_DIR/extracted"
      ;;
    *.tar)
      tar -xf "$SOURCE_ARCHIVE" -C "$WORK_DIR/extracted"
      ;;
    *)
      echo "Поддерживаются .zip, .tar.gz, .tgz и .tar" >&2
      exit 64
      ;;
  esac

  SOURCE_ROOT="$(find_source_root "$WORK_DIR/extracted")" || {
    echo "Архив не содержит проект NewDomofon Video Master" >&2
    exit 65
  }
elif is_project_root "$CURRENT_SOURCE_ROOT"; then
  SOURCE_ROOT="$CURRENT_SOURCE_ROOT"
else
  SOURCE_ROOT="$(
    find /root -mindepth 1 -maxdepth 7 -type f \
      -path '*/scripts/install-master-local-root.sh' \
      -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    while read -r _ helper; do
      root="$(dirname "$(dirname "$helper")")"
      if is_project_root "$root"; then
        printf '%s\n' "$root"
        break
      fi
    done
  )"

  [[ -n "$SOURCE_ROOT" ]] || {
    echo "Распакованный проект не найден в /root" >&2
    echo "Используйте --source-dir или --archive" >&2
    exit 66
  }
fi

SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd)"
PROJECT_DIR="$(
  python3 - "$PROJECT_DIR" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
)"

echo "Источник: $SOURCE_ROOT"
echo "Каталог установки: $PROJECT_DIR"
echo "Git и доступ к репозиторию не используются."

SOURCE_DIR="$SOURCE_ROOT" \
PROJECT_DIR="$PROJECT_DIR" \
  bash "$SOURCE_ROOT/scripts/install-master-local-root.sh" \
    --source-dir "$SOURCE_ROOT" \
    "${PASSTHROUGH_ARGS[@]}"

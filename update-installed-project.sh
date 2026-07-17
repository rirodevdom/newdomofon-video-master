#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Обновляет уже установленный NewDomofon Video Master данными из того
# распакованного архива, в котором находится этот файл.
#
# Обычный запуск после распаковки ZIP/TAR из GitHub:
#   cd /root/newdomofon-video-master-main
#   sudo bash update-installed-project.sh

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/newdomofon-video-migration-backups}"
PRESERVE_NGINX=true
DRY_RUN=false
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=""
UPDATE_LOG=""

usage() {
  cat <<'EOF'
Безопасное обновление установленного NewDomofon Video Master из текущей
распакованной папки проекта.

Использование:
  sudo bash update-installed-project.sh [опции]

Опции:
  --project-dir PATH       Установленный master.
                           По умолчанию: /opt/newdomofon-video-master
  --env-file PATH          Runtime env.
                           По умолчанию: /etc/newdomofon-video/app.env
  --backup-root PATH       Каталог резервных копий.
                           По умолчанию: /opt/newdomofon-video-migration-backups
  --use-archive-nginx      Установить Nginx-конфиг из архива вместо сохранения
                           действующего production-конфига.
  --dry-run                Показать изменения файлов без обновления сервера.
  -h, --help               Показать справку.

Пример:
  cd /root/newdomofon-video-master-main
  sudo bash update-installed-project.sh
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" >&2
}

fail() {
  printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Не найдена обязательная команда: $1"
}

canonical_path() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).expanduser().resolve(strict=False))
PY
}

copy_if_exists() {
  local source="$1"
  local destination="$2"
  if [[ -e "$source" || -L "$source" ]]; then
    cp -aL "$source" "$destination"
  fi
}

validate_source() {
  local required
  for required in \
    backend/package.json \
    frontend/package.json \
    scripts/deploy-master.sh; do
    [[ -f "$SOURCE_ROOT/$required" ]] ||
      fail "Архив не содержит master-файл: $required"
  done
}

validate_installed_project() {
  [[ -d "$PROJECT_DIR" ]] ||
    fail "Установленный master не найден: $PROJECT_DIR"
  [[ -f "$PROJECT_DIR/scripts/deploy-master.sh" ]] ||
    fail "Каталог не похож на установленный master: $PROJECT_DIR"
}

rsync_source() {
  local -a args=(
    -a
    --delete-delay
    --itemize-changes
    --exclude=.git/
    --exclude=node_modules/
    --exclude=dist/
    --exclude=.env
    --exclude='*.env'
    --exclude=.installed-from-extracted-source
    --exclude='*.log'
  )

  if [[ "$DRY_RUN" == true ]]; then
    args+=(--dry-run)
  fi

  log "Синхронизация $SOURCE_ROOT -> $PROJECT_DIR"
  rsync "${args[@]}" "$SOURCE_ROOT/" "$PROJECT_DIR/"
}

backup_git_state() {
  [[ -d "$PROJECT_DIR/.git" ]] || return 0

  git -C "$PROJECT_DIR" rev-parse HEAD \
    >"$BACKUP_DIR/git-head-before.txt" 2>/dev/null || true
  git -C "$PROJECT_DIR" status --short \
    >"$BACKUP_DIR/git-status-before.txt" 2>/dev/null || true
  git -C "$PROJECT_DIR" diff --binary \
    >"$BACKUP_DIR/git-working-tree-before.patch" 2>/dev/null || true
  git -C "$PROJECT_DIR" diff --binary --cached \
    >"$BACKUP_DIR/git-index-before.patch" 2>/dev/null || true
}

backup_project_source() {
  install -d -m 0700 "$BACKUP_DIR/project-source-before"
  rsync -a \
    --exclude=.git/ \
    --exclude=node_modules/ \
    --exclude=dist/ \
    --exclude='*.log' \
    "$PROJECT_DIR/" \
    "$BACKUP_DIR/project-source-before/"
}

backup_master() {
  log "Создание резервной копии master"

  [[ -f "$ENV_FILE" ]] || fail "Не найден env: $ENV_FILE"
  copy_if_exists "$ENV_FILE" "$BACKUP_DIR/app.env.before"
  copy_if_exists \
    /etc/nginx/sites-available/newdomofon-video.conf \
    "$BACKUP_DIR/newdomofon-video.conf.before"

  if [[ -d /var/www/newdomofon-video ]]; then
    install -d -m 0700 "$BACKUP_DIR/web-root-before"
    rsync -a /var/www/newdomofon-video/ "$BACKUP_DIR/web-root-before/"
  fi

  set +u
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  set -u

  [[ -n "${DATABASE_URL:-}" ]] ||
    fail "В $ENV_FILE отсутствует DATABASE_URL"

  require_command pg_dump
  pg_dump -Fc "$DATABASE_URL" >"$BACKUP_DIR/postgresql-before.dump"
}

restore_production_nginx() {
  local backup="$BACKUP_DIR/newdomofon-video.conf.before"
  [[ "$PRESERVE_NGINX" == true ]] || return 0
  [[ -f "$backup" ]] || return 0

  log "Восстановление действующего production-конфига Nginx"
  cp -a "$backup" /etc/nginx/sites-available/newdomofon-video.conf
  ln -sfn \
    /etc/nginx/sites-available/newdomofon-video.conf \
    /etc/nginx/sites-enabled/newdomofon-video.conf
  nginx -t
  systemctl reload nginx
}

run_deploy() {
  local deploy_script="$PROJECT_DIR/scripts/deploy-master.sh"

  if [[ "$PRESERVE_NGINX" == true && \
        -f "$PROJECT_DIR/scripts/deploy-master-preserve-nginx.sh" ]]; then
    deploy_script="$PROJECT_DIR/scripts/deploy-master-preserve-nginx.sh"
  fi

  log "Запуск штатного deploy: $deploy_script"

  PROJECT_DIR="$PROJECT_DIR" \
  ENV_FILE="$ENV_FILE" \
  INSTALL_DISK_GUARD=1 \
  INSTALL_JOURNAL_LIMITS=1 \
  INSTALL_RTSP_GATEWAY=1 \
  BACKEND_HEALTH_TIMEOUT_SECONDS=120 \
    bash "$deploy_script"

  restore_production_nginx

  if [[ -f "$PROJECT_DIR/scripts/repair-public-media-cors.sh" ]]; then
    log "Проверка и исправление CORS media-маршрутов"
    SITE_CONF=/etc/nginx/sites-available/newdomofon-video.conf \
    ENABLED_CONF=/etc/nginx/sites-enabled/newdomofon-video.conf \
    BACKUP_DIR=/var/backups/newdomofon-video/nginx \
      bash "$PROJECT_DIR/scripts/repair-public-media-cors.sh"
  fi
}

write_marker() {
  cat >"$PROJECT_DIR/.installed-from-extracted-source" <<EOF
project_type=master
updated_at=$(date --iso-8601=seconds)
source_root=$SOURCE_ROOT
backup_dir=$BACKUP_DIR
EOF
  chmod 0600 "$PROJECT_DIR/.installed-from-extracted-source"
}

verify_result() {
  curl -fsS --max-time 5 \
    http://127.0.0.1:3000/api/health \
    >"$BACKUP_DIR/backend-health-after.json"
  curl -fsS --max-time 5 \
    http://127.0.0.1/api/health \
    >"$BACKUP_DIR/public-health-after.json"

  systemctl is-active --quiet newdomofon-video-backend.service ||
    fail "newdomofon-video-backend.service не активен"

  nginx -t
}

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  trap - ERR

  if [[ -n "$BACKUP_DIR" && "$PRESERVE_NGINX" == true ]]; then
    restore_production_nginx || true
  fi

  echo >&2
  echo "ОБНОВЛЕНИЕ MASTER ЗАВЕРШИЛОСЬ ОШИБКОЙ" >&2
  echo "Код: $rc; строка: $line" >&2
  [[ -n "$BACKUP_DIR" ]] && echo "Backup: $BACKUP_DIR" >&2
  [[ -n "$UPDATE_LOG" ]] && echo "Лог: $UPDATE_LOG" >&2
  echo "Автоматический откат PostgreSQL не выполнялся, чтобы не потерять новые данные." >&2
  exit "$rc"
}

while (($#)); do
  case "$1" in
    --project-dir)
      PROJECT_DIR="${2:-}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --backup-root)
      BACKUP_ROOT="${2:-}"
      shift 2
      ;;
    --use-archive-nginx)
      PRESERVE_NGINX=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Неизвестный параметр: $1"
      ;;
  esac
done

for command in python3 rsync find sort dirname curl; do
  require_command "$command"
done

SOURCE_ROOT="$(canonical_path "$SOURCE_ROOT")"
PROJECT_DIR="$(canonical_path "$PROJECT_DIR")"
ENV_FILE="$(canonical_path "$ENV_FILE")"
BACKUP_ROOT="$(canonical_path "$BACKUP_ROOT")"

validate_source
validate_installed_project

[[ "$SOURCE_ROOT" != "$PROJECT_DIR" ]] ||
  fail "Нельзя обновлять проект из его установленного каталога"

case "$SOURCE_ROOT/" in
  "$PROJECT_DIR"/*)
    fail "Распакованный архив нельзя размещать внутри $PROJECT_DIR"
    ;;
esac

case "$PROJECT_DIR/" in
  "$SOURCE_ROOT"/*)
    fail "Установленный master не должен находиться внутри распакованного архива"
    ;;
esac

log "Источник архива: $SOURCE_ROOT"
log "Установленный master: $PROJECT_DIR"

if [[ "$DRY_RUN" == true ]]; then
  log "DRY RUN: сервер изменён не будет"
  rsync_source
  log "DRY RUN завершён"
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || fail "Запустите скрипт от root"
for command in flock tee systemctl nginx git; do
  require_command "$command"
done

install -d -m 0755 /run/lock
exec 9>/run/lock/newdomofon-master-archive-update.lock
flock -n 9 || fail "Уже выполняется другое обновление master"

BACKUP_DIR="$BACKUP_ROOT/master-archive-update-$STAMP"
install -d -m 0700 "$BACKUP_DIR"
UPDATE_LOG="$BACKUP_DIR/update.log"
exec > >(tee -a "$UPDATE_LOG") 2>&1
trap on_error ERR

log "Backup: $BACKUP_DIR"
backup_git_state
backup_project_source
backup_master

cat >"$BACKUP_DIR/source-info.txt" <<EOF
project_type=master
source_root=$SOURCE_ROOT
project_dir=$PROJECT_DIR
env_file=$ENV_FILE
started_at=$(date --iso-8601=seconds)
preserve_nginx=$PRESERVE_NGINX
EOF

rsync_source
run_deploy
verify_result
write_marker

date --iso-8601=seconds >"$BACKUP_DIR/completed-at.txt"
trap - ERR

echo
echo "MASTER УСПЕШНО ОБНОВЛЁН"
echo "Источник: $SOURCE_ROOT"
echo "Проект:   $PROJECT_DIR"
echo "Backup:   $BACKUP_DIR"
echo "Проверка: curl -fsS http://127.0.0.1:3000/api/health | jq"

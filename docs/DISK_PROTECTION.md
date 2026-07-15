# Защита master от заполнения диска

Master не хранит основной DVR-архив, но может стать недоступным при заполнении filesystem с PostgreSQL, journald, Nginx logs, package cache или temporary files.

`newdomofon-video-master-disk-guard.timer` запускается независимо от backend раз в минуту.

Полный справочник параметров: [ENVIRONMENT.md](ENVIRONMENT.md#4-master-disk-guard).

## Поведение по умолчанию

- проверяет `/`, `/var/lib/postgresql` и `/var/log/newdomofon-video`;
- входит в critical ниже `max(2 GiB, 5%)` свободного места;
- выходит из critical только выше `max(4 GiB, 10%)`;
- проверяет bytes и inode;
- ограничивает/vacuum journald;
- удаляет только stale project/npm temporary directories;
- опционально запускает `apt-get clean`;
- не удаляет PostgreSQL files или application data;
- пишет state в `/run/newdomofon-video/master-disk-state.json`;
- создаёт marker `/run/newdomofon-video/master-disk-critical`.

Пока marker существует, backend сохраняет health/auth/read/media resolution, но отклоняет изменяющие API requests с HTTP `507 Insufficient Storage`.

## Установка

Обычно guard устанавливает общий deploy:

```bash
cd /opt/newdomofon-video-master

PROJECT_DIR=/opt/newdomofon-video-master \
ENV_FILE=/etc/newdomofon-video/app.env \
INSTALL_DISK_GUARD=1 \
  bash scripts/deploy-master.sh
```

Отдельная установка:

```bash
cd /opt/newdomofon-video-master
bash scripts/install-master-disk-guard.sh
systemctl restart newdomofon-video-backend.service
```

Отключить изменение journald policy:

```bash
INSTALL_JOURNAL_LIMITS=0 \
  bash scripts/install-master-disk-guard.sh
```

## Переменные

```env
# Проверяемые пути, разделённые двоеточием.
MASTER_DISK_GUARD_PATHS=/:/var/lib/postgresql:/var/log/newdomofon-video

# Critical ниже max(bytes, percent).
MASTER_DISK_MIN_FREE_BYTES=2147483648
MASTER_DISK_MIN_FREE_PERCENT=5

# Resume выше max(bytes, percent).
MASTER_DISK_RESUME_FREE_BYTES=4294967296
MASTER_DISK_RESUME_FREE_PERCENT=10

# Inode thresholds.
MASTER_DISK_MIN_FREE_INODES_PERCENT=5
MASTER_DISK_RESUME_FREE_INODES_PERCENT=8

# Journald limits.
MASTER_JOURNAL_MAX_SIZE=512M
MASTER_JOURNAL_MAX_AGE=7d

# Cleanup policy.
MASTER_DISK_STALE_TMP_MINUTES=60
MASTER_DISK_APT_CLEAN_ON_CRITICAL=true
```

Если PostgreSQL находится на другом filesystem, добавьте его реальный data path в `MASTER_DISK_GUARD_PATHS`.

## Статус

```bash
systemctl status newdomofon-video-master-disk-guard.timer --no-pager
systemctl status newdomofon-video-master-disk-guard.service --no-pager
journalctl -u newdomofon-video-master-disk-guard.service -n 200 --no-pager
cat /run/newdomofon-video/master-disk-state.json | jq
curl -fsS http://127.0.0.1:3000/api/health | jq
```

## Безопасная проверка

Не создавайте большой filler file на production. Временно установите threshold немного выше текущего свободного места, запустите oneshot, убедитесь, что marker появился и administrative write возвращает 507, затем верните production thresholds и запустите guard ещё раз.

```bash
systemctl start newdomofon-video-master-disk-guard.service
cat /run/newdomofon-video/master-disk-state.json | jq
ls -l /run/newdomofon-video/master-disk-critical 2>/dev/null || true
```

## Ограничение

Software guard не может исправить PostgreSQL filesystem, который уже полностью заполнен. Используйте внешний мониторинг и alert до critical threshold.
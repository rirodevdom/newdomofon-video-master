# Установка Video Master из локального архива от root

Этот сценарий предназначен для Debian 12, когда source archive master уже распакован внутри `/root` и Git не используется.

Рекомендуемый запускаемый файл:

```text
scripts/install-master-manual-local-root.sh
```

Wrapper использует монолитный root-only installer, но отключает legacy self-registration:

```text
NODE_REGISTRATION_TOKEN=
```

Credentials video node master не генерирует. После установки node оператор вводит её значения через `Администрирование → Ноды → Создать node`.

Обычная установка с systemd user `newdomofon` предпочтительнее. Root-only вариант используйте только осознанно.

## 1. Пользователи

Root-only application services работают от `root`:

```text
newdomofon-video-backend.service
newdomofon-public-events-proxy.service
newdomofon-smartyard-compat.service
newdomofon-video-rtsp-gateway.service
master disk guard
```

PostgreSQL server остаётся `postgres`, Nginx worker — `www-data`. PostgreSQL role `newdomofon` не является Linux-пользователем.

## 2. Распакуйте archive

Пример:

```text
/root/newdomofon-video-master-main/
```

Проверка:

```bash
SOURCE_DIR=/root/newdomofon-video-master-main

test -f "$SOURCE_DIR/backend/package.json"
test -f "$SOURCE_DIR/frontend/package.json"
test -f "$SOURCE_DIR/scripts/install-master-manual-local-root.sh"
test -f "$SOURCE_DIR/scripts/install-master-local-root.sh"
test -f "$SOURCE_DIR/deploy/systemd/newdomofon-video-backend.service"
```

## 3. Необязательный локальный MediaMTX package

Для полностью локальной RTSP-установки положите подходящий archive в `/root`:

```text
/root/mediamtx_vX.Y.Z_linux_amd64.tar.gz
/root/mediamtx_vX.Y.Z_linux_arm64.tar.gz
```

Или передайте:

```text
--mediamtx-archive /root/mediamtx_vX.Y.Z_linux_amd64.tar.gz
```

Без package installer попробует скачать MediaMTX. `--require-rtsp` делает ошибку RTSP фатальной; без него core master может завершить установку без RTSP.

## 4. Интерактивная установка

```bash
cd /root/newdomofon-video-master-main

bash scripts/install-master-manual-local-root.sh
```

Сценарий запросит domain/IP и при необходимости email Let's Encrypt.

## 5. Неинтерактивная установка

С DNS/TLS:

```bash
bash /root/newdomofon-video-master-main/scripts/install-master-manual-local-root.sh \
  --domain video.example.ru \
  --email admin@example.ru \
  --admin-login admin
```

По IP без TLS:

```bash
bash /root/newdomofon-video-master-main/scripts/install-master-manual-local-root.sh \
  --domain 10.106.1.30 \
  --no-tls \
  --admin-login admin
```

Source directory wrapper определяет по своему расположению. Не передавайте другой `--source-dir` wrapper самостоятельно добавляет корректный source root.

## 6. Что делает installer

- устанавливает Debian packages и Node.js 22;
- задаёт `Europe/Moscow`;
- запускает PostgreSQL/Nginx;
- сохраняет backup БД и конфигурации;
- копирует source из `/root` в `/opt/newdomofon-video-master`;
- создаёт/обновляет PostgreSQL role и database;
- генерирует master-only passwords/secrets;
- принудительно оставляет `NODE_REGISTRATION_TOKEN` пустым;
- создаёт `root:root 0600` `app.env`;
- собирает backend/frontend;
- применяет migrations и seed;
- синхронизирует web admin password;
- устанавливает Nginx, gateways и root systemd units;
- устанавливает disk guard и MediaMTX;
- пытается выпустить TLS certificate;
- проверяет backend/media health.

## 7. Какие secrets генерируются

Master installer создаёт только master-level secrets:

```text
PostgreSQL password
JWT_SECRET
ADMIN_PASSWORD
MANAGED_CAMERA_TOKEN_SECRET
INTERNAL_DVR_SECRET
RTSP_GATEWAY_SHARED_SECRET
RTSP_RELAY_PUBLISH_SECRET
```

Он **не создаёт**:

```text
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
```

Эти значения выбираются на каждой video node.

## 8. Файлы после установки

```text
/etc/newdomofon-video/app.env
/root/newdomofon-master-access.txt
/root/newdomofon-master-access.json
/root/newdomofon-master-local-root-*.log
/opt/newdomofon-video-migration-backups/local-root-master-*
```

Access reports должны показывать:

```text
NODE_REGISTRATION_TOKEN=DISABLED_MANUAL_NODE_REGISTRATION
```

и не содержать рабочий legacy registration token.

## 9. Проверка `.env`

Без вывода secrets:

```bash
for key in \
  DATABASE_URL JWT_SECRET ADMIN_PASSWORD INTERNAL_DVR_SECRET; do
  if grep -qE "^${key}=.+" /etc/newdomofon-video/app.env; then
    echo "$key=SET"
  else
    echo "$key=MISSING"
  fi
done

grep '^NODE_REGISTRATION_TOKEN=' /etc/newdomofon-video/app.env
```

Ожидается пустое значение:

```text
NODE_REGISTRATION_TOKEN=
```

Полное назначение каждой настройки: [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md).

## 10. Проверка services

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-public-events-proxy.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active postgresql.service
systemctl is-active nginx.service

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1:3082/health | jq

ss -lntp | grep -E ':(3000|3057|3082|3083|3084|3085|3086|5432|8554|9997)\b'
```

Application units в root-only сценарии должны показывать `User=root`.

## 11. Добавление video node

Node сначала разворачивается сама и создаёт:

```text
/root/newdomofon-node-master-registration.env
```

На master откройте:

```text
Администрирование → Ноды → Создать node
```

Введите:

```text
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

Master сохраняет введённый UUID, hash agent token и media secret; ничего не генерирует.

## 12. Повторный запуск

По умолчанию сохраняются существующие PostgreSQL/master secrets и база. Не используйте `--regenerate-secrets` без необходимости: это может завершить sessions и нарушить managed/RTSP integrations.

Legacy node registration token после каждого запуска wrapper снова очищается.

## 13. Интернет-зависимости

Source GitHub не требуется. Интернет может понадобиться для:

- Debian APT;
- NodeSource;
- npm registry;
- Let's Encrypt;
- MediaMTX, если package отсутствует локально.

Для полностью offline установки подготовьте package/cache заранее.

## 14. Диагностика

```bash
LOG="$(ls -t /root/newdomofon-master-local-root-*.log | head -1)"
tail -300 "$LOG"

systemctl --no-pager --full status newdomofon-video-backend.service
journalctl -u newdomofon-video-backend.service -n 300 --no-pager

systemctl --no-pager --full status newdomofon-video-rtsp-gateway.service
journalctl -u newdomofon-video-rtsp-gateway.service -n 300 --no-pager
```

## 15. Устаревший прямой запуск

Не используйте для новой установки напрямую:

```text
scripts/install-master-local-root.sh
```

Он оставлен как внутренний engine wrapper. Запускайте `install-master-manual-local-root.sh`, который отключает legacy self-registration.
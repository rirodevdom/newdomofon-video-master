# NewDomofon Video Master

Центральный **control plane** NewDomofon Video: Vue/Vuetify admin UI, backend API, PostgreSQL, пользователи/RBAC, устройства, камеры, video node records, managed tokens, SmartYard compatibility, HTTPS media gateways и MediaMTX RTSP gateway.

Этот репозиторий устанавливается **только на master**. Запись камер, live, DVR-архив и локальные события выполняются на video node из `rirodevdom/newdomofon-video-node`.

> Production: Debian 12, Node.js 22, PostgreSQL 15, Nginx, FFmpeg, systemd и MediaMTX. Docker не требуется.

## Главное изменение регистрации node

Master больше не генерирует:

```text
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
```

Правильный порядок:

1. развернуть video node;
2. вручную выбрать на node `DVR_MASTER_URL`, UUID, agent token, media secret и URLs;
3. получить `/root/newdomofon-node-master-registration.env`;
4. открыть `Администрирование → Ноды → Создать node`;
5. ввести все значения посимвольно;
6. дождаться heartbeat.

Подробно: [docs/MANUAL_NODE_REGISTRATION.md](docs/MANUAL_NODE_REGISTRATION.md).

## Документация

- [Развёртывание master на Debian 12](docs/BAREMETAL_DEBIAN12.md)
- [Ручная регистрация video node](docs/MANUAL_NODE_REGISTRATION.md)
- [Все переменные master `.env`](docs/ENVIRONMENT.md)
- `deploy/env/master.env.example` — комментированный шаблон runtime config

## Архитектура

```text
Браузер / SmartYard / VLC / FFplay
                 |
        HTTPS 443|          RTSP 8554
                 v               v
+------------------------------------------------------+
| MASTER                                               |
| Nginx + Vue frontend                                 |
| Backend API :3000 + PostgreSQL                       |
| SmartYard/media/events gateways                      |
| MediaMTX RTSP gateway                                |
+------------------------------------------------------+
                 |
                 | node-agent config/commands
                 | short-lived internal tokens
                 v
+------------------------------------------------------+
| VIDEO NODE                                           |
| DVR engine :3010                                     |
| FFmpeg recorder                                      |
| HLS / MPEG-TS / DASH / JPEG / archive / events       |
+------------------------------------------------------+
                 |
                 | RTSP / ONVIF / Hikvision
                 v
              Камеры / NVR
```

Master отвечает за:

- PostgreSQL и административную конфигурацию;
- пользователей, роли и аудит;
- устройства, камеры и placement;
- node records и heartbeat;
- managed tokens many-to-many;
- HTTPS media/events/preview gateways;
- SmartYard compatibility;
- automatic RTSP через MediaMTX;
- выпуск короткоживущих внутренних node tokens;
- master disk guard.

Master не должен:

- записывать камеры;
- хранить основной DVR archive;
- запускать strict node recorder;
- генерировать credentials video node;
- принимать внешние managed tokens непосредственно на node.

## Модель устройств и камер

Устройство хранит:

```text
connection_type: RTSP / ONVIF / HIKVISION
network address и credentials
назначенную video node
archive_storage
channels/cameras
```

Все камеры устройства наследуют node и archive placement. Перемещение устройства переносит все его камеры.

## Managed tokens

Модель many-to-many:

```text
одна камера → несколько пользовательских токенов
один токен → несколько камер
```

Внешний managed token проверяется на master. После проверки master выпускает короткоживущий внутренний token конкретной node.

Интерфейс:

```text
Администрирование
├── Пользователи
├── Токены
├── Ссылки
└── Ноды
```

## Публичные форматы

| Формат | Назначение |
|---|---|
| HLS | браузеры, HLS.js, SmartYard |
| MPEG-TS | VLC/FFmpeg/relay |
| DASH | MPEG-DASH player |
| JPEG | snapshot/preview |
| RTSP | VLC/NVR/FFplay через MediaMTX |
| Preview MP4 | SmartYard preview |
| Archive HLS | timeline/archive |
| Events JSON | timeline событий |

## Production-пути

```text
/opt/newdomofon-video-master/                    Git checkout
/etc/newdomofon-video/app.env                    runtime config и secrets
/etc/newdomofon-video/mediamtx.yml               MediaMTX config
/var/www/newdomofon-video/                       frontend
/var/cache/newdomofon-video/smartyard-preview/   preview cache
/var/log/newdomofon-video/
/run/newdomofon-video/master-disk-state.json
/etc/nginx/sites-available/newdomofon-video.conf
/etc/systemd/system/newdomofon-*.service
```

## Порты

Публичные:

```text
22/tcp    SSH только доверенным адресам
80/tcp    redirect/ACME
443/tcp   frontend/API/media/events/archive
8554/tcp  RTSP gateway, желательно VPN/allowlist
```

Loopback/private:

```text
127.0.0.1:3000  backend
127.0.0.1:3082  formats gateway
127.0.0.1:3083  legacy compatibility
127.0.0.1:3084  node-aware media
127.0.0.1:3085  camera events
127.0.0.1:3086  preview
127.0.0.1:5432  PostgreSQL
127.0.0.1:9997  MediaMTX API
```

## Быстрое развёртывание

Полная инструкция: [docs/BAREMETAL_DEBIAN12.md](docs/BAREMETAL_DEBIAN12.md).

### 1. Debian

```bash
apt-get update
apt-get dist-upgrade -y
apt-get install -y git ca-certificates curl openssl jq rsync

timedatectl set-timezone Europe/Moscow
systemctl enable --now systemd-timesyncd
```

### 2. Repository и prerequisites

```bash
git clone \
  https://github.com/rirodevdom/newdomofon-video-master.git \
  /opt/newdomofon-video-master

cd /opt/newdomofon-video-master
bash scripts/install-debian12-prereqs.sh
```

### 3. PostgreSQL и `.env`

Создайте PostgreSQL role/database и подготовьте:

```text
/etc/newdomofon-video/app.env
```

Шаблон:

```text
deploy/env/master.env.example
```

Полное назначение каждой строки: [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md).

Обязательная особенность новой схемы:

```text
NODE_REGISTRATION_TOKEN=
```

Legacy self-registration отключена. Credentials отдельных node не хранятся в master `app.env`.

### 4. Deploy

```bash
cd /opt/newdomofon-video-master

PROJECT_DIR=/opt/newdomofon-video-master \
ENV_FILE=/etc/newdomofon-video/app.env \
INSTALL_DISK_GUARD=1 \
INSTALL_JOURNAL_LIMITS=1 \
INSTALL_RTSP_GATEWAY=1 \
  bash scripts/deploy-master.sh
```

### 5. Проверка

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active newdomofon-video-rtsp-gateway.service

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1:3082/health | jq

nginx -t
ss -lntp | grep -E ':(3000|3082|3083|3084|3085|3086|8554|9997)\b'
```

На strict master recorder должен быть отключён:

```bash
systemctl disable --now newdomofon-video-dvr.service 2>/dev/null || true
```

## `.env`

Рабочий файл:

```text
/etc/newdomofon-video/app.env
```

Права:

```bash
chown root:newdomofon /etc/newdomofon-video/app.env
chmod 0640 /etc/newdomofon-video/app.env
```

Не публикуйте файл: он содержит PostgreSQL URL, JWT secret, admin password и internal gateway secrets.

После backend-изменений:

```bash
systemctl restart newdomofon-video-backend.service
```

Все параметры разделены на группы и объяснены в [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md).

## Регистрация заранее развёрнутой node

На node:

```bash
cat /root/newdomofon-node-master-registration.env
```

На master:

```text
Администрирование → Ноды → Создать node
```

Поля:

```text
Название
DVR_MASTER_URL
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
Активна
```

Backend master:

- сохраняет UUID как `dvr_servers.id`;
- сохраняет SHA-256 хеш agent token;
- сохраняет media secret;
- сохраняет master URL в metadata;
- отклоняет duplicate UUID;
- не возвращает и не генерирует secret values.

После heartbeat node должна стать `online`.

## Ручная смена node credentials

1. задайте одинаковые новые `DVR_NODE_TOKEN` и `DVR_NODE_MEDIA_SECRET` в `app.env` node;
2. в master выберите «Действия → Задать новые credentials»;
3. введите те же значения;
4. перезапустите DVR node.

Master не генерирует replacements при rotation.

## Добавление устройств и камер

```text
1. Устройства → Добавить устройство.
2. Выбрать RTSP / ONVIF / HIKVISION.
3. Указать network credentials.
4. Выбрать node.
5. Выбрать archive_storage.
6. Открыть камеры устройства.
7. Добавить/найти channels.
8. Проверить recorder на node.
```

## RTSP gateway

```bash
cd /opt/newdomofon-video-master

PROJECT_DIR=/opt/newdomofon-video-master \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/install-rtsp-gateway.sh
```

Проверка:

```bash
systemctl status newdomofon-video-rtsp-gateway.service --no-pager
ss -lntp | grep ':8554'
grep -E '^RTSP_(GATEWAY_ENABLED|PUBLIC_HOST|PUBLIC_PORT|PUBLIC_URL_TEMPLATE|MEDIAMTX_VERSION)=' \
  /etc/newdomofon-video/app.env
```

Сначала обновляйте node, затем master.

## Master disk guard

Проверка:

```bash
cat /run/newdomofon-video/master-disk-state.json | jq
test ! -e /run/newdomofon-video/master-disk-critical
```

При critical backend может запрещать изменяющие операции и возвращать HTTP `507`.

## Безопасное обновление

Порядок:

```text
1. Обновить все video node.
2. Проверить node health/recorders/heartbeat.
3. Обновить master.
4. Проверить backend/gateways.
5. Проверить ссылки и RTSP.
```

```bash
cd /opt/newdomofon-video-master

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-migration-backups/master-update-$STAMP"
install -d -m 0750 "$BACKUP"

cp -a /etc/newdomofon-video/app.env "$BACKUP/app.env"
cp -a /etc/nginx/sites-available/newdomofon-video.conf "$BACKUP/" 2>/dev/null || true

set -a
. /etc/newdomofon-video/app.env
set +a
pg_dump -Fc "$DATABASE_URL" >"$BACKUP/postgresql.dump"

git status --short >"$BACKUP/git-status.txt"
git diff --binary >"$BACKUP/worktree.patch"
git stash push -u -m "before-master-update-$STAMP" || true

git fetch --prune origin
git switch main
git reset --hard origin/main

PROJECT_DIR=/opt/newdomofon-video-master \
ENV_FILE=/etc/newdomofon-video/app.env \
INSTALL_DISK_GUARD=1 \
INSTALL_JOURNAL_LIMITS=1 \
INSTALL_RTSP_GATEWAY=1 \
  bash scripts/deploy-master.sh
```

Старый stash не восстанавливайте автоматически.

## Backup

```bash
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-backups/master-$STAMP"
install -d -m 0750 "$BACKUP"

cp -a /etc/newdomofon-video "$BACKUP/"
cp -a /etc/nginx/sites-available/newdomofon-video.conf "$BACKUP/" 2>/dev/null || true

set -a
. /etc/newdomofon-video/app.env
set +a
pg_dump -Fc "$DATABASE_URL" >"$BACKUP/newdomofon_video.dump"

git -C /opt/newdomofon-video-master rev-parse HEAD \
  >"$BACKUP/git-commit.txt"
```

## Диагностика

```bash
systemctl --no-pager --full status newdomofon-video-backend.service
journalctl -u newdomofon-video-backend.service -n 300 --no-pager
journalctl -u newdomofon-smartyard-compat.service -n 300 --no-pager
journalctl -u newdomofon-video-rtsp-gateway.service -n 300 --no-pager
curl -fsS http://127.0.0.1:3000/api/health | jq
nginx -t
```

### Node warning/offline

Master UI считает node:

```text
online   heartbeat моложе 60 секунд
warning  heartbeat 60–180 секунд
оffline  heartbeat старше 180 секунд или отсутствует
```

Сначала проверяйте DVR service, local health и agent logs на node. Затем проверяйте `last_seen_at` в `dvr_servers`.

## Безопасность

- не публикуйте `app.env` и database backups;
- ограничьте PostgreSQL loopback/private network;
- разрешайте node `3010` только master;
- ограничьте RTSP `8554` VPN/allowlist;
- не включайте legacy `NODE_REGISTRATION_TOKEN` без отдельной необходимости;
- не запускайте `npm audit fix` автоматически на production;
- при утечке node credentials задайте одинаковые новые значения на node и master.

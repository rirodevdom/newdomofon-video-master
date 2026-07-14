# NewDomofon Video Master

Центральный **control plane** системы NewDomofon Video: административная панель, PostgreSQL, управление устройствами и камерами, регистрация video node, управляемые токены, HTTPS media gateway, SmartYard compatibility и автоматический RTSP gateway.

Этот репозиторий устанавливается **только на master-сервер**. Запись камер, live HLS, локальный архив и события выполняются на отдельных video node из репозитория `rirodevdom/newdomofon-video-node`.

> Production: Debian 12, Node.js 22, PostgreSQL 15, Nginx, systemd, FFmpeg и MediaMTX. Docker не требуется.

---

## Содержание

1. [Текущая архитектура](#текущая-архитектура)
2. [Модель устройств, камер и статусов](#модель-устройств-камер-и-статусов)
3. [Управляемые токены и вкладка «Ссылки»](#управляемые-токены-и-вкладка-ссылки)
4. [Поддерживаемые форматы](#поддерживаемые-форматы)
5. [Порты и production-пути](#порты-и-production-пути)
6. [Требования](#требования)
7. [Полная установка master](#полная-установка-master)
8. [Регистрация video node](#регистрация-video-node)
9. [Добавление устройств и камер](#добавление-устройств-и-камер)
10. [Автоматический RTSP gateway](#автоматический-rtsp-gateway)
11. [Проверка media-ссылок](#проверка-media-ссылок)
12. [Безопасное обновление](#безопасное-обновление)
13. [Backup и восстановление](#backup-и-восстановление)
14. [Диагностика](#диагностика)
15. [Безопасность](#безопасность)

---

# Текущая архитектура

```text
Браузер / SmartYard / VLC / FFplay
                 |
        HTTPS 443|         RTSP TCP 8554
                 v               v
+------------------------------------------------------+
| MASTER                                               |
| Nginx                                                |
| Vue/Vuetify frontend                                 |
| Backend API :3000 + PostgreSQL                       |
| SmartYard formats gateway :3082                      |
| Preview gateway :3086                                |
| Events gateway :3085                                 |
| Node-aware media gateway :3084                       |
| Legacy compatibility gateway :3083                   |
| MediaMTX RTSP gateway :8554                          |
+------------------------------------------------------+
                 |
                 | node-agent config/commands
                 | short-lived HMAC media/event tokens
                 | private HTTP 3010 или node HTTPS
                 v
+------------------------------------------------------+
| VIDEO NODE                                           |
| DVR engine :3010                                     |
| FFmpeg recorder                                      |
| HLS / MPEG-TS / DASH / JPEG / archive / MP4 export   |
| SQLite/WAL camera events                             |
| disk guard + archive/event synchronizer              |
+------------------------------------------------------+
                 |
                 | RTSP / ONVIF / Hikvision
                 v
              Камеры / NVR
```

Master отвечает за:

- пользователей, роли и RBAC;
- PostgreSQL и административную конфигурацию;
- устройства, камеры и группы;
- регистрацию и heartbeat video node;
- назначение устройства конкретной node;
- хранение управляемых внешних токенов;
- проверку пары «токен ↔ камера»;
- HTTPS media routes и SmartYard compatibility;
- автоматический RTSP gateway через MediaMTX;
- выпуск короткоживущих внутренних node tokens;
- аудит и защиту системного диска.

Master **не записывает камеры** и не хранит основной DVR-архив. На strict master сервис `newdomofon-video-dvr.service` должен быть отключён.

---

# Модель устройств, камер и статусов

## Устройство — владелец конфигурации

Устройство хранит:

- тип подключения: `RTSP`, `ONVIF`, `HIKVISION`;
- адрес, порт и credentials;
- назначенную video node;
- место хранения архива;
- список каналов/камер;
- параметры ONVIF, RTSP или Hikvision.

Все камеры устройства наследуют:

```text
device.dvr_server_id   → camera.dvr_server_id
device.archive_storage → camera.archive_storage
```

Node и место хранения архива нельзя независимо изменить в форме камеры. При изменении устройства backend и PostgreSQL policy синхронизируют все его камеры, после чего затронутые node получают `reload_cameras`.

## Отдельная форма камеры

В разделе **«Камеры»** редактируется только:

```text
Камера включена: да / нет
```

Полная настройка потока выполняется внутри:

```text
Устройства → открыть устройство → Камеры устройства
```

## Статусы

Ручное редактирование искусственного поля `status` не используется.

Интерфейс показывает фактические признаки:

- устройство включено/выключено;
- камера включена/выключена;
- node online/offline по heartbeat;
- наличие recorder;
- результаты ONVIF/Hikvision проверки;
- состояние disk guard.

---

# Управляемые токены и вкладка «Ссылки»

## Модель many-to-many

```text
одна камера → несколько токенов
один токен → несколько камер
```

Добавление нового токена к камере **не удаляет** предыдущие привязки.

У каждого токена доступны:

- имя и описание;
- scopes `camera` и/или `events`;
- срок действия;
- включение/выключение;
- ротация;
- список всех привязанных камер.

Новые токены имеют компактный формат:

```text
m1.<payload-and-mac>
```

После ротации старое значение перестаёт работать, но связи с камерами сохраняются.

## Интерфейс

```text
Администрирование
├── Пользователи
├── Токены
└── Ссылки
```

Во вкладке **«Ссылки»**:

1. раскройте нужную камеру;
2. выберите уже привязанный токен или добавьте новый;
3. нажмите **«Показать ссылки»**;
4. скопируйте подходящий URL;
5. при необходимости отвяжите только один конкретный токен.

---

# Поддерживаемые форматы

Для потока `entrance_main` и токена `m1...` master формирует:

| Формат | Пример | Назначение |
|---|---|---|
| HLS | `https://video.example.com/entrance_main/index.m3u8?token=...` | браузеры, HLS.js, SmartYard |
| MPEG-TS | `https://video.example.com/entrance_main/live.ts?token=...` | VLC, FFmpeg, relay |
| DASH | `https://video.example.com/entrance_main/live.mpd?token=...` | MPEG-DASH players |
| JPEG | `https://video.example.com/entrance_main/snapshot.jpg?token=...` | snapshot/preview |
| RTSP | `rtsp://token:<token>@video.example.com:8554/entrance_main` | VLC, NVR, FFplay |
| Preview MP4 | `https://video.example.com/entrance_main/preview.mp4?token=...` | SmartYard preview |
| Archive HLS | URL template с `start` и `end` | timeline/archive |
| Events JSON | URL template с `start` и `end` | события камеры |

HLS, MPEG-TS, DASH и JPEG проходят через HTTPS formats gateway. RTSP обслуживает MediaMTX на master.

---

# Порты и production-пути

## Публичные порты master

```text
22/tcp    SSH, только доверенные адреса
80/tcp    HTTP redirect и ACME
443/tcp   frontend, API, HLS, MPEG-TS, DASH, JPEG, preview, archive, events
8554/tcp  RTSP gateway, желательно ограничить доверенными IP/VPN
```

## Локальные порты master

```text
127.0.0.1:3000  backend API
127.0.0.1:3057  public-events proxy
127.0.0.1:3082  formats gateway
127.0.0.1:3083  legacy compatibility
127.0.0.1:3084  node-aware media
127.0.0.1:3085  camera events
127.0.0.1:3086  preview
127.0.0.1:5432  PostgreSQL
127.0.0.1:9997  MediaMTX control API
0.0.0.0:8554     MediaMTX RTSP
```

## Production-пути

```text
/opt/newdomofon-video-master/                    Git checkout
/etc/newdomofon-video/app.env                    secrets/runtime config
/etc/newdomofon-video/mediamtx.yml               MediaMTX config
/usr/local/bin/mediamtx                          MediaMTX binary
/usr/local/lib/newdomofon-video/rtsp-relay-on-demand.sh
/var/www/newdomofon-video/                       frontend
/var/cache/newdomofon-video/smartyard-preview/   preview cache
/var/log/newdomofon-video/
/run/newdomofon-video/master-disk-state.json
/run/newdomofon-video/master-disk-critical
/etc/nginx/sites-available/newdomofon-video.conf
/etc/systemd/system/newdomofon-*.service
```

---

# Требования

Минимум для небольшого объекта:

```text
Debian 12 x86_64
2–4 vCPU
4–8 GB RAM
20–40 GB SSD
Node.js 22
PostgreSQL 15
Nginx
FFmpeg
DNS A/AAAA record на master
```

Master и node должны иметь синхронизированное время.

```bash
timedatectl set-timezone UTC
systemctl enable --now systemd-timesyncd
timedatectl status
```

---

# Полная установка master

Все команды выполняются от `root`.

## 1. Переменные

```bash
export MASTER_DOMAIN="video.example.com"
export MASTER_REPO="https://github.com/rirodevdom/newdomofon-video-master.git"
export MASTER_DIR="/opt/newdomofon-video-master"
export ADMIN_LOGIN="admin"
```

## 2. Debian и repository

```bash
apt-get update
apt-get dist-upgrade -y
apt-get install -y git ca-certificates curl openssl

install -d -m 0755 /opt
git clone "$MASTER_REPO" "$MASTER_DIR"
cd "$MASTER_DIR"
git switch main
git pull --ff-only origin main
```

## 3. Зависимости

```bash
bash scripts/install-debian12-prereqs.sh

node --version
npm --version
psql --version
nginx -v
ffmpeg -version | head -1
```

## 4. PostgreSQL

```bash
DB_PASSWORD="$(openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-')"

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE newdomofon LOGIN PASSWORD '${DB_PASSWORD}';
CREATE DATABASE newdomofon_video OWNER newdomofon;
SQL
```

Если role/database уже существуют, не создавайте их повторно — используйте существующие credentials.

## 5. Environment

```bash
JWT_SECRET="$(openssl rand -hex 48)"
ADMIN_PASSWORD="$(openssl rand -base64 36 | tr -d '\n')"
NODE_REGISTRATION_TOKEN="$(openssl rand -hex 32)"
INTERNAL_DVR_SECRET="$(openssl rand -hex 32)"

install -d -o root -g newdomofon -m 0750 /etc/newdomofon-video

cat >/etc/newdomofon-video/app.env <<EOF
NODE_ENV=production
BACKEND_PORT=3000
DATABASE_URL=postgres://newdomofon:${DB_PASSWORD}@127.0.0.1:5432/newdomofon_video
JWT_SECRET=${JWT_SECRET}
ADMIN_LOGIN=${ADMIN_LOGIN}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
CORS_ORIGIN=https://${MASTER_DOMAIN}
TRUST_PROXY=true

SMARTYARD_PUBLIC_BASE_URL=https://${MASTER_DOMAIN}
APP_PUBLIC_URL=https://${MASTER_DOMAIN}
INTERNAL_DVR_SECRET=${INTERNAL_DVR_SECRET}
NODE_REGISTRATION_TOKEN=${NODE_REGISTRATION_TOKEN}
PLAYBACK_TOKEN_TTL_SECONDS=900

MASTER_DISK_GUARD_PATHS=/:/var/lib/postgresql:/var/log/newdomofon-video
MASTER_DISK_MIN_FREE_BYTES=2147483648
MASTER_DISK_MIN_FREE_PERCENT=5
MASTER_DISK_RESUME_FREE_BYTES=4294967296
MASTER_DISK_RESUME_FREE_PERCENT=10
MASTER_DISK_MIN_FREE_INODES_PERCENT=5
MASTER_DISK_RESUME_FREE_INODES_PERCENT=8
MASTER_JOURNAL_MAX_SIZE=512M
MASTER_JOURNAL_MAX_AGE=7d
MASTER_DISK_STALE_TMP_MINUTES=60
MASTER_DISK_APT_CLEAN_ON_CRITICAL=true

PUBLIC_EVENTS_INCLUDE_PASSIVE=false
ONVIF_EVENT_SUPPRESS_REPEATED_STATE=true

RTSP_GATEWAY_ENABLED=false
RTSP_PUBLIC_PORT=8554
RTSP_AUTO_OPEN_FIREWALL=true
RTSP_MEDIAMTX_VERSION=
EOF

chown root:newdomofon /etc/newdomofon-video/app.env
chmod 0640 /etc/newdomofon-video/app.env
```

`install-rtsp-gateway.sh` автоматически добавит:

```text
RTSP_GATEWAY_ENABLED=true
RTSP_PUBLIC_HOST=<master-domain>
RTSP_PUBLIC_URL_TEMPLATE=rtsp://token:{token}@<master-domain>:8554/{stream}
RTSP_GATEWAY_SHARED_SECRET=<generated>
RTSP_RELAY_PUBLISH_SECRET=<generated>
```

## 6. Первый deploy

```bash
cd "$MASTER_DIR"

PROJECT_DIR="$MASTER_DIR" \
ENV_FILE=/etc/newdomofon-video/app.env \
INSTALL_DISK_GUARD=1 \
INSTALL_JOURNAL_LIMITS=1 \
INSTALL_RTSP_GATEWAY=1 \
  bash scripts/deploy-master.sh
```

Deploy:

- собирает backend и frontend;
- применяет migrations и seed;
- устанавливает systemd units;
- устанавливает Nginx template;
- запускает SmartYard gateways;
- устанавливает master disk guard;
- скачивает и проверяет MediaMTX;
- создаёт автоматический RTSP gateway;
- отключает DVR recorder на master.

## 7. Nginx domain и TLS

```bash
sed -i \
  "s/server_name _;/server_name ${MASTER_DOMAIN};/" \
  /etc/nginx/sites-available/newdomofon-video.conf

nginx -t
systemctl reload nginx

apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d "$MASTER_DOMAIN"
certbot renew --dry-run
```

После Certbot не заменяйте production Nginx template без backup. Для новых media extensions используйте repository patcher:

```bash
NGINX_SITE=/etc/nginx/sites-available/newdomofon-video.conf \
  bash "$MASTER_DIR/scripts/fix-nginx-admin-media-formats.sh"
```

## 8. Проверка

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active newdomofon-video-rtsp-gateway.service

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1:3082/health | jq

ss -lntp | grep -E ':(3000|3082|3083|3084|3085|3086|8554|9997)\b'
nginx -t
```

---

# Регистрация video node

## Через UI

```text
Администрирование → Nodes → Добавить node
```

Сохраните выданные:

```text
node_id
agent_token
media_secret
```

Они показываются только при создании/ротации.

После запуска node:

```bash
curl -fsS \
  -H "Authorization: Bearer <ADMIN_JWT>" \
  "https://${MASTER_DOMAIN}/api/dvr-servers" \
  | jq '.items[] | {name,status,last_seen_at,camera_count,storage}'
```

Ожидается `status=online`.

---

# Добавление устройств и камер

Рекомендуемый порядок:

```text
1. Устройства → Добавить устройство.
2. Выбрать RTSP / ONVIF / HIKVISION.
3. Указать credentials.
4. Выбрать node.
5. Выбрать archive_storage.
6. Открыть камеры устройства.
7. Найти/добавить каналы.
8. Проверить recorder на node.
```

Перемещение устройства на другую node переносит все его камеры.

Не назначайте отдельную node из формы камеры: устройство является единственным источником placement policy.

---

# Автоматический RTSP gateway

## Как работает

```text
RTSP client
   |
   | rtsp://token:<managed-token>@master:8554/<stream>
   v
MediaMTX
   |
   | HTTP auth → backend
   | проверка active/expiry/scope/assignment
   v
runOnDemand
   |
   | backend resolve assigned node
   | short-lived scope=live token
   v
node /cameras/<stream>/rtsp-relay.ts
   |
   | FFmpeg copy
   v
MediaMTX local publisher → RTSP client
```

Relay создаётся только при первом читателе и останавливается после отключения последнего.

## Ручная повторная установка

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

RTSP gateway требует актуальную node, содержащую endpoint `/cameras/:stream/rtsp-relay.ts`. Поэтому при обновлении сначала обновляется node, затем master.

---

# Проверка media-ссылок

## HLS

```bash
curl -ksS "$HLS_URL" | head
```

Ожидается `#EXTM3U`.

## MPEG-TS

```bash
timeout 8 curl -ksS "$MPEG_TS_URL" -o /tmp/live.ts || true
file /tmp/live.ts
ls -lh /tmp/live.ts
```

## DASH

```bash
curl -ksS "$DASH_URL" -o /tmp/live.mpd
grep -m1 '<MPD' /tmp/live.mpd
```

## JPEG

```bash
curl -ksS "$JPEG_URL" -o /tmp/snapshot.jpg
file /tmp/snapshot.jpg
```

## RTSP

```bash
timeout 30 ffprobe \
  -v error \
  -rtsp_transport tcp \
  -show_entries stream=index,codec_type,codec_name,width,height \
  -of json \
  "$RTSP_URL" | jq
```

---

# Безопасное обновление

Порядок при изменениях media/RTSP:

```text
1. Обновить все video node.
2. Проверить node health и recorder.
3. Обновить master.
4. Проверить backend/gateways.
5. Проверить ссылки из «Администрирование → Ссылки».
```

Обновление master:

```bash
cd /opt/newdomofon-video-master

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-migration-backups/master-update-$STAMP"
install -d -m 0750 "$BACKUP"

cp -a /etc/newdomofon-video/app.env "$BACKUP/"
cp -a /etc/nginx/sites-available/newdomofon-video.conf "$BACKUP/"

set -a
. /etc/newdomofon-video/app.env
set +a
pg_dump -Fc "$DATABASE_URL" >"$BACKUP/postgresql.dump"

git status --short >"$BACKUP/git-status.txt"
git diff --binary >"$BACKUP/worktree.patch"

git stash push -u -m "before-master-update-$STAMP" || true
git fetch origin main
git switch main
git reset --hard origin/main

PROJECT_DIR=/opt/newdomofon-video-master \
ENV_FILE=/etc/newdomofon-video/app.env \
INSTALL_DISK_GUARD=1 \
INSTALL_JOURNAL_LIMITS=1 \
INSTALL_RTSP_GATEWAY=1 \
  bash scripts/deploy-master.sh
```

Проверяйте итоговый commit:

```bash
git log -1 --oneline
git status --short
```

---

# Backup и восстановление

Минимальный backup master:

```bash
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-backups/master-$STAMP"
install -d -m 0750 "$BACKUP"

cp -a /etc/newdomofon-video "$BACKUP/"
cp -a /etc/nginx/sites-available/newdomofon-video.conf "$BACKUP/"
cp -a /etc/systemd/system/newdomofon-*.service "$BACKUP/" 2>/dev/null || true

set -a
. /etc/newdomofon-video/app.env
set +a
pg_dump -Fc "$DATABASE_URL" >"$BACKUP/newdomofon_video.dump"

git -C /opt/newdomofon-video-master rev-parse HEAD \
  >"$BACKUP/git-commit.txt"
```

Не публикуйте backup: он содержит токены, пароли и database dump.

---

# Диагностика

## Сервисы

```bash
systemctl --no-pager --full status \
  newdomofon-video-backend.service \
  newdomofon-smartyard-compat.service \
  newdomofon-video-rtsp-gateway.service

journalctl -u newdomofon-video-backend.service -n 300 --no-pager
journalctl -u newdomofon-smartyard-compat.service -n 300 --no-pager
journalctl -u newdomofon-video-rtsp-gateway.service -n 300 --no-pager
```

## Preview 502

```bash
SMARTYARD_URL='https://video.example.com/stream/?token=...' \
  bash /opt/newdomofon-video-master/scripts/diagnose-smartyard-preview.sh
```

## RTSP не открывается

```bash
ss -lntp | grep ':8554'
systemctl is-active newdomofon-video-rtsp-gateway.service
grep '^RTSP_PUBLIC_URL_TEMPLATE=' /etc/newdomofon-video/app.env
journalctl -u newdomofon-video-rtsp-gateway.service --since "15 minutes ago" --no-pager
```

Во внешнем firewall/NAT должен быть разрешён TCP `8554`.

## Disk guard

```bash
cat /run/newdomofon-video/master-disk-state.json | jq
test ! -e /run/newdomofon-video/master-disk-critical
```

При critical backend может переходить в read-only и возвращать HTTP `507` для изменяющих запросов.

---

# Безопасность

- не публикуйте `app.env`;
- не выводите токены в общие логи и чаты;
- ограничьте PostgreSQL loopback/private network;
- порт node `3010` разрешайте только master;
- RTSP `8554` ограничьте VPN или доверенными IP;
- обычный RTSP не шифрует credentials и media;
- регулярно ротируйте admin password, node agent token, node media secret и managed tokens;
- после публикации токена в открытом канале выполните rotation;
- храните backups с `chmod 0600/0750`;
- не запускайте `npm audit fix` автоматически на production без проверки diff.

---

## Актуальные production-компоненты

```text
Master backend + PostgreSQL
Device-owned camera placement
Automatic node heartbeat/config generation
Managed camera tokens many-to-many
Administration → Links
HLS / MPEG-TS / DASH / JPEG / preview / archive / events
Automatic MediaMTX RTSP gateway
Master/node disk guards
Node-local SQLite events
Archive/event lifecycle synchronizer
```

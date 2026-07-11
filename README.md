# NewDomofon Video Master

Центральный **control plane**, API-шлюз, административная панель и пользовательский web-интерфейс системы NewDomofon Video.

Этот репозиторий предназначен только для **master-сервера**. Видеоархив, FFmpeg recorder и локальная история событий камер работают на отдельных video node из репозитория [`rirodevdom/newdomofon-video-node`](https://github.com/rirodevdom/newdomofon-video-node).

> Production-платформа: Debian 12, Node.js 22, PostgreSQL 15, Nginx, systemd. Docker не требуется.

---

## Содержание

1. [Архитектура](#архитектура)
2. [Компоненты и каталоги](#компоненты-и-каталоги)
3. [Требования к серверу](#требования-к-серверу)
4. [Порты и сетевой доступ](#порты-и-сетевой-доступ)
5. [Быстрый план установки](#быстрый-план-установки)
6. [Полная установка master на чистый Debian 12](#полная-установка-master-на-чистый-debian-12)
7. [Регистрация первой video node](#регистрация-первой-video-node)
8. [Добавление устройства и камеры](#добавление-устройства-и-камеры)
9. [Управляемые токены и ссылки камер](#управляемые-токены-и-ссылки-камер)
10. [SmartYard-Vue: live, архив, события и preview](#smartyard-vue-live-архив-события-и-preview)
11. [Защита master от заполнения диска](#защита-master-от-заполнения-диска)
12. [Проверка после установки](#проверка-после-установки)
13. [Безопасное обновление production](#безопасное-обновление-production)
14. [Backup и восстановление](#backup-и-восстановление)
15. [Диагностика](#диагностика)
16. [Безопасность](#безопасность)
17. [Разработка и разделение репозиториев](#разработка-и-разделение-репозиториев)

---

# Архитектура

## Общая схема

```text
Браузер / SmartYard-Vue
          |
          | HTTPS 443
          v
+-----------------------------+
| MASTER                      |
| Nginx                       |
| Vue/Vuetify frontend        |
| Node.js backend :3000       |
| PostgreSQL                  |
| SmartYard gateway :3082     |
+-----------------------------+
          |
          | node-agent API, media/event HMAC tokens
          | private HTTP 3010 или public HTTPS 443
          v
+-----------------------------+
| VIDEO NODE                  |
| DVR engine :3010            |
| FFmpeg recorder             |
| HLS / archive / MP4 export  |
| SQLite/WAL camera events    |
+-----------------------------+
          |
          | RTSP / ONVIF / Hikvision
          v
       Камеры / NVR
```

## Master отвечает за

- пользователей, роли и RBAC;
- устройства, камеры и группы камер;
- регистрацию и управление video node;
- назначение камер конкретным node;
- хранение управляющей конфигурации в PostgreSQL;
- административный и пользовательский web UI;
- проверку прав пользователя на камеру;
- выпуск короткоживущих внутренних media/event token для node;
- управляемые внешние токены камер;
- маршрутизацию live, archive, events и preview на назначенную node;
- SmartYard-compatible URL;
- аудит административных действий;
- защиту master от критического заполнения диска.

## Master не должен

- запускать FFmpeg recorder для удалённых камер;
- хранить основной DVR-архив;
- хранить ONVIF/Hikvision/video-motion события камер;
- читать SQLite node напрямую;
- подключаться к камерам по RTSP/ONVIF;
- запускать `newdomofon-video-dvr.service`.

При strict master deployment старый DVR unit автоматически отключается.

## Где хранятся данные

```text
Master PostgreSQL:
  пользователи, роли, устройства, камеры, node, токены, назначения, аудит

Video node filesystem:
  HLS/live, архивные сегменты, MP4 export, SQLite/WAL событий
```

Frontend запрашивает timeline через master. Master проверяет RBAC, определяет назначенную node, подписывает короткоживущий `scope=events` token и проксирует запрос. Event payload на master не копируется.

## Контракты master/node

```text
contracts/node-agent-api-v1.md
contracts/node-events-api-v1.md
```

При несовместимом изменении сначала обновляется контракт и обратно совместимый master, затем node.

---

# Компоненты и каталоги

## Состав репозитория

```text
backend/                  Node.js + TypeScript API, PostgreSQL, auth, RBAC
frontend/                 Vue 3 + Vuetify web portal
public-events-proxy/      legacy/public event compatibility
smartyard-compat-proxy/   media, events и preview gateway для SmartYard
media-public-proxy/       media compatibility helpers
archive-policy-api/       archive policy helper
contracts/                versioned master/node contracts
deploy/env/               примеры environment
deploy/nginx/             Nginx templates
deploy/systemd/           systemd units
deploy/journald/          лимиты systemd-journald
scripts/                  install, deploy, disk guard и diagnostics
```

## Production-пути

```text
/opt/newdomofon-video-master/                   Git checkout
/etc/newdomofon-video/app.env                   secrets и runtime config
/var/www/newdomofon-video/                      собранный frontend
/var/cache/newdomofon-video/smartyard-preview/  кеш preview.mp4
/var/log/newdomofon-video/                      application logs/runtime path
/run/newdomofon-video/master-disk-state.json    состояние disk guard
/run/newdomofon-video/master-disk-critical      critical marker
/etc/nginx/sites-available/newdomofon-video.conf
/etc/systemd/system/newdomofon-*.service
```

Не помещайте `app.env`, database dumps, cache или runtime-файлы в Git.

---

# Требования к серверу

## Рекомендуемая конфигурация

Минимум для небольшого объекта:

```text
OS:       Debian 12 x86_64
CPU:      2 vCPU
RAM:      4 GB
Disk:     20 GB SSD
Node.js:  22.12+
DB:       PostgreSQL 15
Proxy:    Nginx
Time:     chrony или systemd-timesyncd
```

Для большого количества пользователей, камер и частых timeline-запросов рекомендуется:

```text
CPU:      4+ vCPU
RAM:      8+ GB
Disk:     40+ GB SSD/NVMe
Postgres: отдельный filesystem или отдельный DB server
```

Master не хранит основной видеоархив, поэтому ему не нужен многотерабайтный DVR-диск.

## DNS

Подготовьте DNS A/AAAA record, например:

```text
video.example.com -> публичный IP master
```

Проверка:

```bash
getent ahosts video.example.com
```

## Время

Рекомендуется UTC:

```bash
timedatectl set-timezone UTC
systemctl enable --now systemd-timesyncd

timedatectl status
```

Master и все node должны иметь синхронизированное время, иначе HMAC token могут считаться ещё не действующими или истёкшими.

---

# Порты и сетевой доступ

## Публичные порты

```text
22/tcp   SSH; только административные адреса
80/tcp   HTTP, redirect и ACME challenge
443/tcp  HTTPS frontend, API и SmartYard media routes
```

## Локальные master-порты

```text
127.0.0.1:3000  backend API
127.0.0.1:3057  public-events-proxy
127.0.0.1:3082  внешний SmartYard preview/media/events gateway
127.0.0.1:3083  внутренний legacy compatibility gateway
127.0.0.1:3084  внутренний node-aware media gateway
127.0.0.1:3085  внутренний camera-events gateway
127.0.0.1:5432  PostgreSQL
```

Порты `3083–3085` не следует публиковать наружу. Они являются внутренними слоями одного SmartYard compatibility stack.

На strict master порт `3010` слушать не должен.

## Связь с node

Master должен иметь доступ к каждой node:

```text
предпочтительно: http://PRIVATE_NODE_IP:3010
fallback:        https://video-node.example.com
```

Node должна иметь исходящий HTTPS-доступ к master для heartbeat, config и commands.

---

# Быстрый план установки

```text
1. Подготовить Debian 12 и DNS.
2. Клонировать master repository.
3. Запустить install-debian12-prereqs.sh.
4. Создать PostgreSQL role/database.
5. Создать /etc/newdomofon-video/app.env.
6. Запустить deploy-master.sh.
7. Настроить server_name и TLS.
8. Проверить backend, gateways и disk guard.
9. Создать video node на master.
10. Установить node из отдельного node repository.
11. Добавить device/camera и назначить node.
12. Создать managed token и получить SmartYard URL.
```

---

# Полная установка master на чистый Debian 12

Все команды ниже выполняются от `root`, если не указано иное.

## 1. Задайте переменные установки

Замените примерные значения:

```bash
export MASTER_DOMAIN="video.example.com"
export MASTER_REPO="https://github.com/rirodevdom/newdomofon-video-master.git"
export MASTER_DIR="/opt/newdomofon-video-master"
export ADMIN_LOGIN="admin"
```

Проверка:

```bash
printf 'domain=%s\nrepo=%s\ndir=%s\n' \
  "$MASTER_DOMAIN" "$MASTER_REPO" "$MASTER_DIR"

getent ahosts "$MASTER_DOMAIN"
```

## 2. Обновите Debian

```bash
apt-get update
apt-get dist-upgrade -y
apt-get install -y git ca-certificates curl openssl
reboot
```

После повторного входа:

```bash
uname -a
cat /etc/debian_version
```

## 3. Клонируйте master repository

Для чистой установки:

```bash
install -d -m 0755 /opt

git clone "$MASTER_REPO" "$MASTER_DIR"
cd "$MASTER_DIR"
git switch main
git pull --ff-only origin main

git log -1 --oneline
git status --short
```

Не используйте старый объединённый monorepo и не помещайте master/node в один checkout.

## 4. Установите системные зависимости

```bash
cd "$MASTER_DIR"
bash scripts/install-debian12-prereqs.sh
```

Скрипт устанавливает:

- Git, curl, jq, rsync;
- Nginx;
- PostgreSQL и `postgresql-contrib`;
- FFmpeg;
- build tools;
- Node.js 22 при отсутствии подходящей версии;
- system user `newdomofon`;
- базовые runtime-каталоги.

Проверка:

```bash
node --version
npm --version
psql --version
ffmpeg -version | head -1
nginx -v
id newdomofon
```

Ожидается Node.js `v22.x` или новее.

## 5. Создайте PostgreSQL role и database

Создадим случайный hex-пароль, который не требует URL encoding в `DATABASE_URL`:

```bash
umask 077
DB_PASSWORD="$(openssl rand -hex 24)"

sudo -u postgres psql \
  -v ON_ERROR_STOP=1 \
  --set=db_password="$DB_PASSWORD" <<'SQL'
SELECT 'CREATE ROLE newdomofon LOGIN'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = 'newdomofon'
) \gexec

ALTER ROLE newdomofon PASSWORD :'db_password';

SELECT 'CREATE DATABASE newdomofon_video OWNER newdomofon'
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = 'newdomofon_video'
) \gexec

ALTER DATABASE newdomofon_video OWNER TO newdomofon;
SQL

printf '%s\n' "$DB_PASSWORD" \
  > /root/newdomofon-master-db-password.txt
chmod 600 /root/newdomofon-master-db-password.txt
```

Проверка:

```bash
PGPASSWORD="$DB_PASSWORD" \
  psql -h 127.0.0.1 \
  -U newdomofon \
  -d newdomofon_video \
  -c 'select current_database(), current_user, now();'
```

PostgreSQL не должен слушать публичный интерфейс:

```bash
ss -ltnp | grep ':5432'
```

## 6. Сгенерируйте secrets

```bash
umask 077

JWT_SECRET="$(openssl rand -hex 48)"
ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
NODE_REGISTRATION_TOKEN="$(openssl rand -hex 32)"
INTERNAL_DVR_SECRET="$(openssl rand -hex 32)"
MANAGED_CAMERA_TOKEN_SECRET="$(openssl rand -hex 48)"
```

`MANAGED_CAMERA_TOKEN_SECRET` используется для коротких внешних managed token формата `m1.…`. Не меняйте его без необходимости: смена секрета немедленно инвалидирует все managed camera links.

## 7. Создайте production environment

```bash
install -d -o root -g newdomofon -m 0750 \
  /etc/newdomofon-video

cat > /etc/newdomofon-video/app.env <<EOF
NODE_ENV=production
BACKEND_PORT=3000
DATABASE_URL=postgres://newdomofon:${DB_PASSWORD}@127.0.0.1:5432/newdomofon_video

JWT_SECRET=${JWT_SECRET}
ADMIN_LOGIN=${ADMIN_LOGIN}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
MANAGED_CAMERA_TOKEN_SECRET=${MANAGED_CAMERA_TOKEN_SECRET}

CORS_ORIGIN=https://${MASTER_DOMAIN}
TRUST_PROXY=true
APP_PUBLIC_URL=https://${MASTER_DOMAIN}
SMARTYARD_PUBLIC_BASE_URL=https://${MASTER_DOMAIN}

NODE_REGISTRATION_TOKEN=${NODE_REGISTRATION_TOKEN}
INTERNAL_DVR_SECRET=${INTERNAL_DVR_SECRET}

MEDIA_PUBLIC_BASE_URL=/api/media
PLAYBACK_TOKEN_TTL_SECONDS=900
NODE_COMMAND_POLL_LIMIT=20
NODE_EVENT_PROXY_TIMEOUT_MS=15000
NODE_EVENT_QUERY_MAX_SECONDS=2678400

# Пользовательский timeline: passive false/inactive snapshots скрыты.
PUBLIC_EVENTS_INCLUDE_PASSIVE=false
ONVIF_EVENT_SUPPRESS_REPEATED_STATE=true
EVENT_LOGICAL_DEDUP_MS=2000

# Strict master не использует локальный DVR. Значение оставлено только для
# внутренних compatibility fallback routes.
DVR_ENGINE_URL=http://127.0.0.1:3010

# Master disk guard.
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
EOF

chown root:newdomofon /etc/newdomofon-video/app.env
chmod 0640 /etc/newdomofon-video/app.env
```

Сохраните bootstrap credentials отдельно:

```bash
cat > /root/newdomofon-master-bootstrap-secrets.txt <<EOF
MASTER_DOMAIN=${MASTER_DOMAIN}
ADMIN_LOGIN=${ADMIN_LOGIN}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
NODE_REGISTRATION_TOKEN=${NODE_REGISTRATION_TOKEN}
DATABASE_PASSWORD=${DB_PASSWORD}
EOF

chmod 600 /root/newdomofon-master-bootstrap-secrets.txt
```

Проверка прав без вывода секретов:

```bash
namei -l /etc/newdomofon-video/app.env
sudo -u newdomofon test -r /etc/newdomofon-video/app.env
echo "app_env_readable_rc=$?"
```

Должно быть `app_env_readable_rc=0`.

## 8. Уточните PostgreSQL data path для disk guard

```bash
PG_DATA="$(sudo -u postgres psql -Atqc 'show data_directory' postgres)"
echo "PostgreSQL data directory: $PG_DATA"
```

Если путь отличается от `/var/lib/postgresql`, замените строку:

```bash
sed -i \
  "s#^MASTER_DISK_GUARD_PATHS=.*#MASTER_DISK_GUARD_PATHS=/:${PG_DATA}:/var/log/newdomofon-video#" \
  /etc/newdomofon-video/app.env
```

## 9. Выполните первый deploy

```bash
cd "$MASTER_DIR"

PROJECT_DIR="$MASTER_DIR" \
ENV_FILE=/etc/newdomofon-video/app.env \
INSTALL_DISK_GUARD=1 \
INSTALL_JOURNAL_LIMITS=1 \
  bash scripts/deploy-master.sh
```

Deploy выполняет:

1. preflight disk guard;
2. `npm ci` и TypeScript build backend;
3. PostgreSQL migrations;
4. seed административного пользователя;
5. build frontend;
6. публикацию frontend в `/var/www/newdomofon-video`;
7. установку public-events dependencies;
8. установку systemd units;
9. установку Nginx template;
10. запуск backend, public-events и SmartYard gateway;
11. установку master disk guard и journald limits;
12. отключение старого DVR unit на master.

Не запускайте `npm audit fix` автоматически на production.

## 10. Укажите production domain в Nginx

При первом deploy устанавливается template с `server_name _;`:

```bash
sed -i \
  "s/server_name _;/server_name ${MASTER_DOMAIN};/" \
  /etc/nginx/sites-available/newdomofon-video.conf

nginx -t
systemctl reload nginx
```

Проверка:

```bash
grep -n 'server_name' \
  /etc/nginx/sites-available/newdomofon-video.conf
```

## 11. Выпустите TLS-сертификат

```bash
apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d "$MASTER_DOMAIN"
certbot renew --dry-run
```

После Certbot сохраните backup Nginx-файла:

```bash
cp -a \
  /etc/nginx/sites-available/newdomofon-video.conf \
  /root/newdomofon-video.nginx-with-tls.conf
```

> `deploy-master.sh` копирует Nginx template заново. При последующих обновлениях используйте раздел «Безопасное обновление production» и всегда сохраняйте TLS-конфигурацию.

## 12. Ограничьте firewall

Сначала убедитесь, что SSH-доступ работает по ключу. Не применяйте правила вслепую.

Публично нужны только:

```text
22/tcp  от административных IP
80/tcp  от клиентов/ACME
443/tcp от клиентов
```

PostgreSQL и порты `3000`, `3057`, `3082–3085` должны слушать localhost.

## 13. Проверьте master

```bash
systemctl is-active postgresql
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-public-events-proxy.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active newdomofon-video-master-disk-guard.timer

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1:3082/health | jq
curl -kfsS "https://${MASTER_DOMAIN}/api/health" | jq

ss -ltnp | grep -E ':(3000|3057|3082|3083|3084|3085|5432)([[:space:]]|$)'
```

Убедитесь, что DVR на master не запущен:

```bash
systemctl is-active newdomofon-video-dvr.service 2>/dev/null || true
ss -ltnp | grep ':3010 ' || echo 'OK: strict master does not run DVR'
```

## 14. Войдите в web UI

Откройте:

```text
https://video.example.com
```

Используйте `ADMIN_LOGIN` и `ADMIN_PASSWORD` из bootstrap-файла.

После первого входа создайте отдельного администратора или смените bootstrap password согласно внутренней политике.

---

# Регистрация первой video node

Node создаётся через:

```text
Администрирование → Video nodes
```

или API.

## 1. Получите admin JWT

```bash
export MASTER_URL="https://${MASTER_DOMAIN}"
export ADMIN_LOGIN="admin"
read -rsp 'Admin password: ' ADMIN_PASSWORD
echo

AUTH_TOKEN="$(
  curl -fsS \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc \
      --arg login "$ADMIN_LOGIN" \
      --arg password "$ADMIN_PASSWORD" \
      '{login:$login,password:$password}')" \
    "$MASTER_URL/api/auth/login" \
  | jq -r '.token // empty'
)"

test -n "$AUTH_TOKEN"
echo "JWT received"
```

Не печатайте JWT в общий журнал.

## 2. Создайте запись node

```bash
export NODE_NAME="video-node1"
export NODE_PUBLIC_URL="https://video-node1.example.com"
export NODE_INTERNAL_URL="http://10.0.0.31:3010"

NODE_BOOTSTRAP="$(
  curl -fsS -X POST \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc \
      --arg name "$NODE_NAME" \
      --arg public "$NODE_PUBLIC_URL" \
      --arg internal "$NODE_INTERNAL_URL" \
      '{
        name:$name,
        public_base_url:$public,
        internal_url:$internal,
        is_enabled:true,
        capabilities:{live:true,archive:true,events:true,export:true}
      }')" \
    "$MASTER_URL/api/dvr-servers"
)"

echo "$NODE_BOOTSTRAP" | jq '{node_id,has_agent_token:(.agent_token|length>0),has_media_secret:(.media_secret|length>0)}'
```

Ответ содержит секреты только при создании/ротации:

```text
node_id
agent_token
media_secret
```

Сохраните их:

```bash
printf '%s\n' "$NODE_BOOTSTRAP" \
  > "/root/${NODE_NAME}-bootstrap.json"
chmod 600 "/root/${NODE_NAME}-bootstrap.json"
```

Передайте файл на node через защищённый канал.

## 3. Установите node

Используйте инструкцию из отдельного репозитория:

```text
https://github.com/rirodevdom/newdomofon-video-node
```

После запуска node проверьте heartbeat:

```bash
curl -fsS \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  "$MASTER_URL/api/dvr-servers" \
  | jq '.items[] | {id,name,status,last_seen_at,camera_count,storage,capabilities}'
```

Ожидается:

```text
status=online
last_seen_at регулярно обновляется
```

## Ротация node credentials

```bash
NODE_ID="$(echo "$NODE_BOOTSTRAP" | jq -r '.node_id')"

curl -fsS -X POST \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"rotate_media_secret":true}' \
  "$MASTER_URL/api/dvr-servers/$NODE_ID/rotate-token" \
  | jq
```

После ротации сразу обновите `DVR_NODE_TOKEN` и `DVR_NODE_MEDIA_SECRET` на node и перезапустите DVR service. Старые значения перестают работать.

---

# Добавление устройства и камеры

Рекомендуемый способ — web UI. API-примеры ниже полезны для автоматизации.

## Важные понятия

```text
Device  = физическая камера/NVR и её credentials
Camera  = конкретный видеопоток с уникальным stream_name
Node    = сервер, который записывает Camera
```

`stream_name` допускает только:

```text
A-Z a-z 0-9 _ -
```

Он должен быть уникальным.

## ONVIF device через API

```bash
NODE_ID="PASTE_NODE_UUID"

DEVICE_ID="$(
  curl -fsS -X POST \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc \
      --arg node "$NODE_ID" \
      '{
        name:"Entrance camera",
        connection_type:"ONVIF",
        archive_storage:"node",
        dvr_server_id:$node,
        host:"192.168.10.20",
        port:80,
        username:"operator",
        password:"CHANGE_CAMERA_PASSWORD",
        comment:"Main entrance",
        status:"unknown",
        is_enabled:true
      }')" \
    "$MASTER_URL/api/devices" \
  | jq -r '.id'
)"

echo "DEVICE_ID=$DEVICE_ID"
```

Не вставляйте реальные пароли в shell history на shared server. Для production лучше создать JSON-файл с `chmod 600` или использовать UI.

## Camera через API

Камера может вернуть RTSP URI без userinfo. Node безопасно подставляет сохранённые device/ONVIF credentials в памяти при запуске FFmpeg.

```bash
CAMERA_ID="$(
  curl -fsS -X POST \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc \
      --arg device "$DEVICE_ID" \
      --arg node "$NODE_ID" \
      '{
        name:"Entrance stream",
        stream_name:"entrance_main",
        source_url:"rtsp://192.168.10.20:554/Streaming/Channels/101",
        archive_storage:"node",
        device_id:$device,
        dvr_server_id:$node,
        retention_days:14,
        is_enabled:true,
        onvif_xaddr:"http://192.168.10.20/onvif/device_service",
        onvif_port:80,
        onvif_username:"operator",
        onvif_password:"CHANGE_CAMERA_PASSWORD"
      }')" \
    "$MASTER_URL/api/cameras" \
  | jq -r '.id'
)"

echo "CAMERA_ID=$CAMERA_ID"
```

Создание/изменение/удаление камеры увеличивает `config_generation` и ставит node command `reload_cameras`. Обычно node подхватывает камеру без ручного restart.

## Назначение существующих камер node

```bash
CAMERA_IDS_JSON="$(jq -nc --arg id "$CAMERA_ID" '[ $id ]')"

curl -fsS -X POST \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --argjson ids "$CAMERA_IDS_JSON" '{camera_ids:$ids}')" \
  "$MASTER_URL/api/dvr-servers/$NODE_ID/assign-cameras" \
  | jq
```

## Проверка назначения

```bash
curl -fsS \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  "$MASTER_URL/api/cameras" \
  | jq '.items[] | {id,name,stream_name,dvr_server_name,retention_days,is_enabled}'
```

На node:

```bash
curl -fsS http://127.0.0.1:3010/cameras/entrance_main/status | jq
```

Успешный recorder показывает `recording=true`.

---

# Управляемые токены и ссылки камер

## Модель доступа

Управляемый token создаётся один раз в администрировании. Он может быть:

- привязан к одной или нескольким камерам;
- отключён;
- включён;
- ротирован;
- ограничен сроком действия;
- выдан с правом `camera`, `events` или обоими.

Для каждой камеры хранится **одна текущая привязка**. Выбор другого token перепривязывает камеру атомарно. Один token может обслуживать много камер.

Новые token имеют компактный формат:

```text
m1.<payload-and-mac>
```

Обычная длина — 46 символов. Старые `mct1` token остаются обратно совместимыми.

## Через web UI

```text
Администрирование
  → Токены
  → Создать управляемый токен камер
  → Ссылки камер
  → выбрать token
  → Привязать и открыть / Показать ссылки
```

После перезагрузки страницы select камеры восстанавливает текущий token.

## Создание token через API

```bash
MANAGED_TOKEN_RESPONSE="$(
  curl -fsS -X POST \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{
      "name":"SmartYard production",
      "description":"Основная интеграция двора",
      "scopes":["camera","events"],
      "expires_at":null
    }' \
    "$MASTER_URL/api/tokens/managed-camera-tokens"
)"

MANAGED_TOKEN_ID="$(echo "$MANAGED_TOKEN_RESPONSE" | jq -r '.item.id')"

echo "$MANAGED_TOKEN_RESPONSE" \
  | jq '.item | {id,name,generation,scopes,is_active,expires_at,token_length:(.token|length)}'
```

Не публикуйте поле `.token`.

## Получение ссылок камеры

```bash
CAMERA_LINKS="$(
  curl -fsS -X POST \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg id "$MANAGED_TOKEN_ID" '{managed_token_id:$id}')" \
    "$MASTER_URL/api/tokens/camera-links/$CAMERA_ID"
)"

echo "$CAMERA_LINKS" | jq '{
  camera,
  managed_token,
  assignment_changed,
  smartyard_url,
  live_url,
  archive_url_template,
  events_url_template
}'
```

Повторный вызов с тем же token возвращает те же ссылки. Вызов с другим token заменяет текущую привязку.

## Ротация token

```bash
curl -fsS -X POST \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{}' \
  "$MASTER_URL/api/tokens/managed-camera-tokens/$MANAGED_TOKEN_ID/rotate" \
  | jq '.item | {id,name,generation,token_length:(.token|length)}'
```

После ротации старые ссылки этого token перестают работать. Привязки к камерам сохраняются; ссылки нужно открыть и скопировать повторно.

## Отключение token

```bash
curl -fsS -X PATCH \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"is_active":false}' \
  "$MASTER_URL/api/tokens/managed-camera-tokens/$MANAGED_TOKEN_ID" \
  | jq
```

---

# SmartYard-Vue: live, архив, события и preview

Общая ссылка имеет вид:

```text
https://video.example.com/<stream_name>/?token=m1....
```

SmartYard compatibility routes:

```text
/<stream>/index.m3u8
/<stream>/video.m3u8
/<stream>/archive.m3u8
/<stream>/preview.mp4
/<stream>/<unix>-preview.mp4
/<stream>/events.json
/<stream>/motion_events.json
/<stream>/events/summary
/<stream>/recording_status.json
/<stream>/media_info.json
```

Master gateway:

1. проверяет managed token и привязку камеры;
2. определяет назначенную node;
3. выпускает короткий внутренний node token;
4. получает media/events/export с node;
5. возвращает данные SmartYard-Vue.

Preview берётся из последнего доступного архивного диапазона node, формируется через короткий MP4 export, кешируется на master и отдаётся с HTTP Range (`200` или `206`).

## Диагностика preview

```bash
cd /opt/newdomofon-video-master

read -rsp 'SmartYard camera URL: ' SMARTYARD_URL
echo

SMARTYARD_URL="$SMARTYARD_URL" \
  bash scripts/diagnose-smartyard-preview.sh
```

Успешный результат:

```text
http=200                  # 206 также допустим
content_type=video/mp4
route=node-preview-export # или node-preview-cache
compat=v303-node-preview-gateway
SMARTYARD PREVIEW VERIFIED
```

## Health SmartYard gateway

```bash
curl -fsS http://127.0.0.1:3082/health | jq
```

Проверьте внутренние порты:

```bash
ss -ltnp | grep -E ':(3082|3083|3084|3085)([[:space:]]|$)'
```

## Event API

Logical timeline по умолчанию:

- оставляет активные motion events;
- скрывает passive `false/inactive` snapshots;
- объединяет близкие эквивалентные ONVIF topics;
- не удаляет raw-события на node.

Для диагностики backend API поддерживает raw mode там, где он предусмотрен маршрутом.

---

# Защита master от заполнения диска

Master disk guard запускается systemd timer и проверяет:

```text
/
PostgreSQL data filesystem
/var/log/newdomofon-video
```

По умолчанию critical возникает, если свободно меньше более строгого значения:

```text
max(2 GiB, 5% filesystem)
```

Возврат из warning/critical требует:

```text
max(4 GiB, 10% filesystem)
```

Также контролируются свободные inode:

```text
critical: <5%
recovery: >=8%
```

Guard безопасно очищает:

- старый journald в заданных пределах;
- временные `newdomofon-*`, `nd-export-*`, `npm-*` каталоги;
- APT cache при critical.

Guard **не удаляет PostgreSQL data files**.

При critical создаётся:

```text
/run/newdomofon-video/master-disk-critical
```

Backend сохраняет health/read-only операции, а изменяющие административные запросы могут получить:

```text
HTTP 507 Insufficient Storage
Retry-After: 60
```

## Проверка состояния

```bash
cat /run/newdomofon-video/master-disk-state.json | jq

systemctl status \
  newdomofon-video-master-disk-guard.timer \
  --no-pager -l

journalctl \
  -u newdomofon-video-master-disk-guard.service \
  -n 200 --no-pager
```

## Ручной запуск

```bash
NEWDOMOFON_ENV_FILE=/etc/newdomofon-video/app.env \
  /usr/local/sbin/newdomofon-master-disk-guard
```

## Проверка filesystem

```bash
PG_DATA="$(sudo -u postgres psql -Atqc 'show data_directory' postgres)"

df -hT / "$PG_DATA" /var/log/newdomofon-video
df -ih / "$PG_DATA" /var/log/newdomofon-video
journalctl --disk-usage
```

---

# Проверка после установки

## Все сервисы

```bash
systemctl status postgresql --no-pager -l
systemctl status newdomofon-video-backend.service --no-pager -l
systemctl status newdomofon-public-events-proxy.service --no-pager -l
systemctl status newdomofon-smartyard-compat.service --no-pager -l
systemctl status newdomofon-video-master-disk-guard.timer --no-pager -l
```

## HTTP checks

```bash
curl -i http://127.0.0.1:3000/api/health
curl -i http://127.0.0.1:3082/health
curl -kI "https://${MASTER_DOMAIN}/"
curl -kfsS "https://${MASTER_DOMAIN}/api/health" | jq
```

## PostgreSQL tables

```bash
set -a
. /etc/newdomofon-video/app.env
set +a

psql "$DATABASE_URL" -P pager=off -c '\dt'

psql "$DATABASE_URL" -P pager=off -c '
SELECT name,status,last_seen_at,public_base_url,internal_url
FROM dvr_servers
ORDER BY name;
'
```

## Managed token assignments

```bash
psql "$DATABASE_URL" -P pager=off -c '
SELECT
  c.name AS camera,
  c.stream_name,
  t.name AS managed_token,
  a.created_at AS assigned_at
FROM managed_camera_token_cameras a
JOIN cameras c ON c.id = a.camera_id
JOIN managed_camera_tokens t ON t.id = a.token_id
ORDER BY c.name;
'
```

Для одной камеры должна существовать не более чем одна текущая строка assignment.

## Nginx route check

```bash
nginx -t
nginx -T 2>/dev/null \
  | grep -nE 'server_name|3082|events\.json|preview\.mp4' \
  | head -100
```

---

# Безопасное обновление production

## Важно про Nginx и Certbot

`scripts/deploy-master.sh` копирует repository Nginx template в `/etc/nginx/sites-available/newdomofon-video.conf`. После того как Certbot добавил TLS, повторный полный deploy может заменить production-файл.

Для регулярного обновления рекомендуется application-only процедура ниже. Nginx/systemd templates обновляйте отдельно после просмотра diff.

## 1. Создайте backup

```bash
set +e
set +u
set +E
set +o pipefail

PROJECT="/opt/newdomofon-video-master"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-migration-backups/master-update-$STAMP"

install -d -m 0750 "$BACKUP"

cp -a /etc/newdomofon-video "$BACKUP/etc-newdomofon-video"
cp -a /etc/nginx/sites-available/newdomofon-video.conf \
  "$BACKUP/nginx.conf"
cp -a /etc/systemd/system/newdomofon-*.service \
  "$BACKUP/" 2>/dev/null || true
cp -a /etc/systemd/system/newdomofon-*.timer \
  "$BACKUP/" 2>/dev/null || true

git -C "$PROJECT" status --short > "$BACKUP/git-status.txt"
git -C "$PROJECT" rev-parse HEAD > "$BACKUP/git-commit.txt"
git -C "$PROJECT" diff --binary > "$BACKUP/worktree.patch" || true

set -a
. /etc/newdomofon-video/app.env
set +a

pg_dump -Fc "$DATABASE_URL" > "$BACKUP/postgresql.dump"
rsync -a /var/www/newdomofon-video/ "$BACKUP/web-root/"
```

## 2. Обновите checkout

```bash
git -C "$PROJECT" stash push -u \
  -m "production-before-update-$STAMP" || true

git -C "$PROJECT" fetch origin main
git -C "$PROJECT" switch main
git -C "$PROJECT" reset --hard origin/main

git -C "$PROJECT" log -1 --oneline
```

## 3. Disk preflight

```bash
NEWDOMOFON_ENV_FILE=/etc/newdomofon-video/app.env \
  bash "$PROJECT/scripts/master-disk-guard.sh"

cat /run/newdomofon-video/master-disk-state.json | jq

test ! -e /run/newdomofon-video/master-disk-critical
```

## 4. Соберите backend и frontend до restart

```bash
cd "$PROJECT/backend"
npm ci --include=dev
npm run build
npm run migrate
npm run seed
npm prune --omit=dev

cd "$PROJECT/frontend"
npm ci --include=dev
npm run build

rsync -a --delete dist/ /var/www/newdomofon-video/
chown -R newdomofon:newdomofon /var/www/newdomofon-video
```

## 5. Обновите systemd units при необходимости

Сначала сравните:

```bash
diff -u \
  /etc/systemd/system/newdomofon-video-backend.service \
  "$PROJECT/deploy/systemd/newdomofon-video-backend.service" || true

diff -u \
  /etc/systemd/system/newdomofon-smartyard-compat.service \
  "$PROJECT/deploy/systemd/newdomofon-smartyard-compat.service" || true
```

После проверки:

```bash
install -m 0644 \
  "$PROJECT/deploy/systemd/newdomofon-video-backend.service" \
  /etc/systemd/system/newdomofon-video-backend.service

install -m 0644 \
  "$PROJECT/deploy/systemd/newdomofon-public-events-proxy.service" \
  /etc/systemd/system/newdomofon-public-events-proxy.service

install -m 0644 \
  "$PROJECT/deploy/systemd/newdomofon-smartyard-compat.service" \
  /etc/systemd/system/newdomofon-smartyard-compat.service

systemctl daemon-reload
```

## 6. Проверьте Nginx template без слепой замены

```bash
diff -u \
  /etc/nginx/sites-available/newdomofon-video.conf \
  "$PROJECT/deploy/nginx/newdomofon-video.conf" || true
```

Переносите новые `location` вручную либо после backup снова примените domain/TLS через Certbot. Не копируйте template поверх production TLS-конфига без проверки.

## 7. Перезапустите services

```bash
systemctl restart newdomofon-video-backend.service
systemctl restart newdomofon-public-events-proxy.service
systemctl restart newdomofon-smartyard-compat.service

for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:3000/api/health >/tmp/master-health.json; then
    break
  fi
  sleep 1
done

jq . /tmp/master-health.json
curl -fsS http://127.0.0.1:3082/health | jq
nginx -t
```

Не применяйте сохранённый stash автоматически. Сначала сравните его с новым `main`.

---

# Backup и восстановление

## Что обязательно сохранять

```text
/etc/newdomofon-video/
/etc/nginx/sites-available/newdomofon-video.conf
/etc/systemd/system/newdomofon-*.service
/etc/systemd/system/newdomofon-*.timer
/var/www/newdomofon-video/
PostgreSQL database newdomofon_video
текущий Git commit
```

## PostgreSQL backup

```bash
set -a
. /etc/newdomofon-video/app.env
set +a

install -d -m 0700 /var/backups/newdomofon-video

pg_dump -Fc "$DATABASE_URL" \
  > "/var/backups/newdomofon-video/master-$(date +%Y%m%d-%H%M%S).dump"
```

Проверка dump:

```bash
pg_restore --list /var/backups/newdomofon-video/master-*.dump \
  | head -30
```

## Пример восстановления в тестовую database

```bash
sudo -u postgres createdb \
  -O newdomofon \
  newdomofon_video_restore_test

pg_restore \
  --clean --if-exists \
  --no-owner \
  --dbname=postgres://newdomofon:${DB_PASSWORD}@127.0.0.1:5432/newdomofon_video_restore_test \
  /var/backups/newdomofon-video/MASTER_DUMP.dump
```

Сначала всегда проверяйте восстановление в отдельной database.

## Rollback приложения

```bash
PROJECT="/opt/newdomofon-video-master"
OLD_COMMIT="PASTE_PREVIOUS_COMMIT"

git -C "$PROJECT" reset --hard "$OLD_COMMIT"

cd "$PROJECT/backend"
npm ci --include=dev
npm run build
npm prune --omit=dev

cd "$PROJECT/frontend"
npm ci --include=dev
npm run build
rsync -a --delete dist/ /var/www/newdomofon-video/
chown -R newdomofon:newdomofon /var/www/newdomofon-video

systemctl restart newdomofon-video-backend.service
systemctl restart newdomofon-smartyard-compat.service

curl -fsS http://127.0.0.1:3000/api/health | jq
```

Если новая версия изменила schema/data, используйте соответствующий PostgreSQL dump.

---

# Диагностика

## Backend не запускается

```bash
systemctl status newdomofon-video-backend.service --no-pager -l
journalctl -u newdomofon-video-backend.service -n 300 --no-pager
```

Частые причины:

- `JWT_SECRET` отсутствует или короче 32 символов;
- `ADMIN_PASSWORD` короче 12 символов;
- неверный `DATABASE_URL`;
- PostgreSQL не запущен;
- `app.env` недоступен пользователю `newdomofon`;
- build `backend/dist/index.js` отсутствует.

Проверка env без вывода secrets:

```bash
sudo -u newdomofon bash -c '
set -a
. /etc/newdomofon-video/app.env
set +a
printf "DATABASE_URL=%s\n" "$([ -n "${DATABASE_URL:-}" ] && echo configured || echo missing)"
printf "JWT_SECRET_LENGTH=%s\n" "${#JWT_SECRET}"
printf "ADMIN_PASSWORD_LENGTH=%s\n" "${#ADMIN_PASSWORD}"
'
```

## SmartYard preview возвращает 502

```bash
journalctl \
  -u newdomofon-smartyard-compat.service \
  --since '15 minutes ago' \
  --no-pager | tail -300

curl -fsS http://127.0.0.1:3082/health | jq
ss -ltnp | grep -E ':(3082|3083|3084|3085)([[:space:]]|$)'
```

Возможные причины:

- node offline;
- node не имеет media secret;
- камера не назначена node;
- на node нет playable archive range;
- node не обновлена до версии, где `camera` scope разрешает preview MP4 export;
- internal secret master/gateway не совпадает.

## Live возвращает 404

Если ответ:

```json
{"error":"Live playlist is not ready","recording":false}
```

маршрут и token работают, но FFmpeg recorder на node не создал `live.m3u8`. Проверяйте node status и journal, а не Nginx master.

## Events возвращают HTML вместо JSON

Проверьте, что event `location` расположен до SPA fallback:

```bash
nginx -T 2>/dev/null \
  | grep -n -A25 -B2 'events_summary'
```

Ответ должен иметь:

```text
content-type: application/json
access-control-allow-origin: *
x-newdomofon-smartyard-route: node-events
```

## HTTP 507

```bash
cat /run/newdomofon-video/master-disk-state.json | jq
df -hT /
df -ih /
journalctl --disk-usage
```

Освободите место безопасно. Не удаляйте PostgreSQL data files вручную.

## Node offline

```bash
set -a
. /etc/newdomofon-video/app.env
set +a

psql "$DATABASE_URL" -P pager=off -c '
SELECT name,status,last_seen_at,internal_url,public_base_url,config_generation
FROM dvr_servers
ORDER BY name;
'
```

На node проверьте `DVR_NODE_ID`, `DVR_NODE_TOKEN`, DNS master и время.

## Полезные журналы

```bash
journalctl -u newdomofon-video-backend.service -n 300 --no-pager
journalctl -u newdomofon-public-events-proxy.service -n 200 --no-pager
journalctl -u newdomofon-smartyard-compat.service -n 300 --no-pager
journalctl -u newdomofon-video-master-disk-guard.service -n 200 --no-pager
```

---

# Безопасность

- Используйте TLS на master и всех публичных node.
- Ограничьте SSH административными IP и используйте ключи.
- Не публикуйте `app.env`, bootstrap JSON, database dumps и media token.
- Не храните token в shell history на shared server.
- PostgreSQL должен слушать localhost/private network.
- Порты `3000`, `3057`, `3082–3085` не должны быть публичными.
- `NODE_REGISTRATION_TOKEN`, agent token и media secret должны быть уникальны.
- Используйте отдельный `MANAGED_CAMERA_TOKEN_SECRET`, не равный `JWT_SECRET`.
- После утечки managed token ротируйте его в администрировании.
- После утечки node media secret ротируйте node credentials и обновите node env.
- После утечки RTSP/ONVIF credentials смените пароль камеры.
- Не публикуйте HAR и browser logs с полными camera links.
- Не включайте raw event payload без необходимости.
- Регулярно проверяйте backup restore, disk guard и Certbot renewal.

---

# Добавление второй и последующих node

Для каждой node:

1. создайте отдельную запись на master;
2. получите отдельные `node_id`, `agent_token`, `media_secret`;
3. используйте отдельный private/internal URL;
4. при необходимости используйте отдельный public DNS URL;
5. установите node из отдельного node repository;
6. назначьте только её камеры;
7. проверьте heartbeat, live, archive, events и preview;
8. не копируйте credentials другой node.

SmartYard gateway сам определяет node по назначению камеры. Override `DVR_ENGINE_URL` на одну удалённую node для современной multi-node схемы не требуется.

---

# Разработка и разделение репозиториев

Control plane изменяется только в:

```text
https://github.com/rirodevdom/newdomofon-video-master
```

Data plane изменяется только в:

```text
https://github.com/rirodevdom/newdomofon-video-node
```

Правила:

- не копировать node recorder в master;
- не подключать node к PostgreSQL master;
- не хранить события камер на master;
- не делать общий production checkout;
- общими считать только versioned contracts;
- сначала сохранять backward compatibility, затем обновлять node;
- удалять legacy endpoint только отдельным major change.

Старый объединённый monorepo не является источником production-кода.

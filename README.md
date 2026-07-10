# NewDomofon Video Master

Центральный **control plane**, API-шлюз и веб-интерфейс NewDomofon Video.

Master управляет пользователями, правами, камерами и video node, но не является владельцем видеоархива и истории событий камер.

## Архитектура и границы ответственности

Master отвечает за:

- пользователей, роли и RBAC;
- устройства, камеры и группы камер;
- регистрацию и управление video node;
- назначение камер конкретным node;
- выпуск короткоживущих media token;
- проверку доступа пользователя к камере;
- проксирование live, archive и event-запросов на назначенную node;
- административный и пользовательский web UI;
- SmartYard compatibility links;
- служебный аудит и управляющие данные.

Master **не должен**:

- запускать FFmpeg для камер, назначенных удалённым node;
- хранить DVR-архив;
- хранить ONVIF/Hikvision/video-motion события;
- читать локальную SQLite или файловую систему node;
- подключаться к камерам по RTSP/ONVIF;
- запускать `newdomofon-video-dvr.service`.

История событий хранится на node в SQLite/WAL. Frontend продолжает обращаться к master API, а master после проверки RBAC подписывает короткоживущий `scope=events` token и проксирует запрос на нужную node.

Контракты взаимодействия:

```text
contracts/node-agent-api-v1.md
contracts/node-events-api-v1.md
```

## Состав репозитория

```text
backend/                  Node.js/TypeScript API, PostgreSQL, auth, RBAC
frontend/                 Vue/Vuetify web portal
public-events-proxy/      public events compatibility
media-public-proxy/       public media compatibility helpers
smartyard-compat-proxy/   SmartYard compatibility proxy
archive-policy-api/       archive policy helper
contracts/                versioned master/node API contracts
deploy/                   systemd, nginx and env examples
scripts/                  installation, deployment and diagnostics
```

## Поддерживаемая платформа

Рекомендуемая production-система:

- Debian 12 x86_64;
- Node.js 22.12 или новее;
- PostgreSQL 15;
- nginx;
- минимум 2 CPU, 4 GB RAM и 20 GB системного диска;
- отдельный DNS-адрес, например `video.example.com`;
- синхронизация времени через systemd-timesyncd или chrony.

Master не требует большого диска под видео. PostgreSQL хранит только управляющие данные.

## Сетевые порты

Наружу:

```text
22/tcp    SSH, только с административных адресов
80/tcp    HTTP и выпуск TLS-сертификата
443/tcp   HTTPS web UI и API
```

Локально:

```text
127.0.0.1:3000   backend
127.0.0.1:3057   public-events-proxy
127.0.0.1:3082   SmartYard compatibility proxy
127.0.0.1:5432   PostgreSQL
```

На чистом master порт `3010` слушать не должен.

# Полное развёртывание на чистом Debian 12

Ниже предполагается выполнение команд от `root`.

## 1. Подготовьте DNS и переменные

Замените значения на свои:

```bash
export MASTER_DOMAIN="video.example.com"
export MASTER_REPO="https://github.com/rirodevdom/newdomofon-video-master.git"
export MASTER_DIR="/opt/newdomofon-video-master"
```

Проверьте DNS:

```bash
getent ahosts "$MASTER_DOMAIN"
```

## 2. Обновите систему и клонируйте репозиторий

```bash
apt-get update
apt-get upgrade -y
apt-get install -y git ca-certificates curl

rm -rf "$MASTER_DIR.new"
git clone "$MASTER_REPO" "$MASTER_DIR.new"

install -d -m 0755 /opt
mv "$MASTER_DIR.new" "$MASTER_DIR"

cd "$MASTER_DIR"
git switch main
git pull --ff-only origin main
```

Если каталог уже существует, не удаляйте его. Используйте раздел «Обновление существующего master» ниже.

## 3. Установите системные зависимости

```bash
cd "$MASTER_DIR"
bash scripts/install-debian12-prereqs.sh
```

Скрипт устанавливает nginx, PostgreSQL, FFmpeg, build tools и Node.js 22, создаёт пользователя `newdomofon` и runtime-каталоги.

Проверка:

```bash
node --version
npm --version
psql --version
nginx -v
id newdomofon
```

## 4. Создайте PostgreSQL role и database

Используется пароль только из hex-символов, поэтому его можно безопасно поместить в `DATABASE_URL` без URL encoding.

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

printf '%s\n' "$DB_PASSWORD" > /root/newdomofon-master-db-password.txt
chmod 600 /root/newdomofon-master-db-password.txt
```

Проверка соединения:

```bash
PGPASSWORD="$DB_PASSWORD" \
  psql -h 127.0.0.1 -U newdomofon -d newdomofon_video \
  -c 'select current_database(), current_user;'
```

## 5. Создайте production env

```bash
umask 077

JWT_SECRET="$(openssl rand -hex 32)"
ADMIN_PASSWORD="$(openssl rand -hex 16)"
NODE_REGISTRATION_TOKEN="$(openssl rand -hex 32)"
INTERNAL_DVR_SECRET="$(openssl rand -hex 32)"

install -d -m 0750 /etc/newdomofon-video

cat > /etc/newdomofon-video/app.env <<EOF
NODE_ENV=production
BACKEND_PORT=3000
DATABASE_URL=postgres://newdomofon:${DB_PASSWORD}@127.0.0.1:5432/newdomofon_video

JWT_SECRET=${JWT_SECRET}
ADMIN_LOGIN=admin
ADMIN_PASSWORD=${ADMIN_PASSWORD}

CORS_ORIGIN=https://${MASTER_DOMAIN}
TRUST_PROXY=true

NODE_REGISTRATION_TOKEN=${NODE_REGISTRATION_TOKEN}
INTERNAL_DVR_SECRET=${INTERNAL_DVR_SECRET}

MEDIA_PUBLIC_BASE_URL=/api/media
PLAYBACK_TOKEN_TTL_SECONDS=900
NODE_EVENT_PROXY_TIMEOUT_MS=15000
NODE_EVENT_QUERY_MAX_SECONDS=2678400

SMARTYARD_PUBLIC_BASE_URL=https://${MASTER_DOMAIN}
DVR_ENGINE_URL=http://127.0.0.1:3010
EOF

chown root:newdomofon /etc/newdomofon-video/app.env
chmod 0640 /etc/newdomofon-video/app.env

cat > /root/newdomofon-master-bootstrap-secrets.txt <<EOF
ADMIN_LOGIN=admin
ADMIN_PASSWORD=${ADMIN_PASSWORD}
NODE_REGISTRATION_TOKEN=${NODE_REGISTRATION_TOKEN}
DATABASE_PASSWORD=${DB_PASSWORD}
EOF
chmod 600 /root/newdomofon-master-bootstrap-secrets.txt
```

`INTERNAL_DVR_SECRET` сохраняется только для оставшихся legacy/internal compatibility routes. События камер через него больше не передаются и на master не сохраняются.

Никогда не добавляйте `app.env` или bootstrap secrets в Git.

## 6. Выполните первый deploy

```bash
cd "$MASTER_DIR"
PROJECT_DIR="$MASTER_DIR" \
  ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/deploy-master.sh
```

Deploy выполняет:

1. установку npm-зависимостей backend;
2. TypeScript build;
3. миграции PostgreSQL;
4. seed административного пользователя;
5. сборку frontend;
6. публикацию frontend в `/var/www/newdomofon-video`;
7. установку systemd units;
8. установку nginx-конфига;
9. запуск backend и compatibility services;
10. принудительное отключение старого DVR-сервиса на master.

Не запускайте `npm audit fix` автоматически на production. Сначала проверяйте предлагаемые изменения в отдельной ветке.

## 7. Укажите DNS-имя в nginx

Deploy устанавливает шаблон с `server_name _;`. Замените его на production-домен:

```bash
sed -i \
  "s/server_name _;/server_name ${MASTER_DOMAIN};/" \
  /etc/nginx/sites-available/newdomofon-video.conf

nginx -t
systemctl reload nginx
```

После повторного deploy проверьте, что `server_name` не вернулся к `_`:

```bash
grep -n 'server_name' /etc/nginx/sites-available/newdomofon-video.conf
```

## 8. Выпустите TLS-сертификат

```bash
apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d "$MASTER_DOMAIN"
```

Проверка автоматического продления:

```bash
certbot renew --dry-run
```

## 9. Проверьте master до подключения node

```bash
systemctl is-active postgresql
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-public-events-proxy.service
systemctl is-active newdomofon-smartyard-compat.service

curl -fsS http://127.0.0.1:3000/api/health
curl -kfsS "https://${MASTER_DOMAIN}/api/health"

ss -ltnp | grep -E ':(3000|3057|3082|5432)([[:space:]]|$)'
```

Ожидается:

```json
{"ok":true,"service":"backend"}
```

Убедитесь, что локальный DVR отключён:

```bash
systemctl is-enabled newdomofon-video-dvr.service 2>/dev/null || true
systemctl is-active newdomofon-video-dvr.service 2>/dev/null || true
ss -ltnp | grep ':3010 ' || echo 'OK: master does not run DVR'
```

# Регистрация video node

Node можно создать через web UI или API. API-вариант удобен для первой установки.

## 10. Получите JWT администратора

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
  | jq -r '.token'
)"

test -n "$AUTH_TOKEN" && test "$AUTH_TOKEN" != null
```

## 11. Создайте запись node

Укажите реальные адреса node:

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
      '{name:$name,public_base_url:$public,internal_url:$internal,is_enabled:true}')" \
    "$MASTER_URL/api/dvr-servers"
)"

echo "$NODE_BOOTSTRAP" | jq
```

Ответ содержит:

```text
node_id
agent_token
media_secret
```

Эти значения показываются в открытом виде при создании/ротации. Сохраните их в защищённом файле и перенесите на node:

```bash
printf '%s\n' "$NODE_BOOTSTRAP" \
  > "/root/${NODE_NAME}-bootstrap.json"
chmod 600 "/root/${NODE_NAME}-bootstrap.json"
```

## 12. Настройте SmartYard compatibility на удалённую node

Текущий systemd template содержит локальный `DVR_ENGINE_URL=http://127.0.0.1:3010`. На разделённом master создайте override.

```bash
install -d \
  /etc/systemd/system/newdomofon-smartyard-compat.service.d

cat > \
  /etc/systemd/system/newdomofon-smartyard-compat.service.d/remote-node.conf <<EOF
[Unit]
After=
After=network-online.target

[Service]
Environment=DVR_ENGINE_URL=${NODE_INTERNAL_URL}
EOF

systemctl daemon-reload
systemctl restart newdomofon-smartyard-compat.service

systemctl show newdomofon-smartyard-compat.service \
  -p Environment --value \
  | tr ' ' '\n' \
  | grep '^DVR_ENGINE_URL='
```

Для нескольких node SmartYard compatibility следует развивать как маршрутизируемый proxy по camera/node assignment. До этого override указывает на node, обслуживающую SmartYard-камеры.

## 13. Назначьте камеры node

В web UI назначьте камеры созданной node. API-вариант:

```bash
export NODE_ID="$(echo "$NODE_BOOTSTRAP" | jq -r '.node_id')"

# Вставьте UUID камер.
CAMERA_IDS_JSON='[
  "00000000-0000-0000-0000-000000000001",
  "00000000-0000-0000-0000-000000000002"
]'

curl -fsS -X POST \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --argjson ids "$CAMERA_IDS_JSON" '{camera_ids:$ids}')" \
  "$MASTER_URL/api/dvr-servers/$NODE_ID/assign-cameras" \
  | jq
```

Node получит новую конфигурацию через node-agent API и команду `reload_cameras`.

# Проверка полной схемы

## Проверка node heartbeat

```bash
curl -fsS \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  "$MASTER_URL/api/dvr-servers" \
  | jq '.items[] | {name,status,last_seen_at,camera_count,storage,capabilities}'
```

## Проверка event proxy

Откройте камеру в web UI и убедитесь, что timeline загружается. Master не должен писать новые строки в PostgreSQL `camera_events`.

Legacy ingest должен быть закрыт:

```bash
set -a
. /etc/newdomofon-video/app.env
set +a

curl -sS -o /tmp/event-ingest.json -w 'HTTP %{http_code}\n' \
  -X POST \
  -H "x-internal-secret: $INTERNAL_DVR_SECRET" \
  -H 'Content-Type: application/json' \
  -d '{"camera_id":"00000000-0000-0000-0000-000000000000","stream_name":"test","event_type":"test","occurred_at":"2026-01-01T00:00:00.000Z"}' \
  http://127.0.0.1:3000/api/internal/events/onvif

cat /tmp/event-ingest.json
```

Ожидается HTTP `410 Gone`.

## Проверка SmartYard-ссылки

В web UI:

```text
Администрирование → Токены → Ссылки камер → Сгенерировать
```

Проверьте общую ссылку, `index.m3u8` и `recording_status.json`.

# Обновление существующего master

Перед обновлением создайте PostgreSQL dump, backup runtime и зафиксируйте текущий commit.

```bash
set -Eeuo pipefail

PROJECT="/opt/newdomofon-video-master"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/newdomofon-video-migration-backups/master-update-$STAMP"

install -d -m 0750 "$BACKUP"

cp -a /etc/newdomofon-video "$BACKUP/etc-newdomofon-video"
cp -a /etc/systemd/system/newdomofon-smartyard-compat.service.d \
  "$BACKUP/" 2>/dev/null || true

git -C "$PROJECT" status --short > "$BACKUP/git-status.txt"
git -C "$PROJECT" rev-parse HEAD > "$BACKUP/git-commit.txt"

set -a
. /etc/newdomofon-video/app.env
set +a

pg_dump -Fc "$DATABASE_URL" \
  > "$BACKUP/postgresql.dump"

rsync -a /var/www/newdomofon-video/ \
  "$BACKUP/web-root/"

git -C "$PROJECT" fetch origin main
git -C "$PROJECT" switch main
git -C "$PROJECT" pull --ff-only origin main

PROJECT_DIR="$PROJECT" \
  ENV_FILE=/etc/newdomofon-video/app.env \
  bash "$PROJECT/scripts/deploy-master.sh"
```

После deploy снова проверьте:

```bash
grep -n 'server_name' /etc/nginx/sites-available/newdomofon-video.conf
systemctl show newdomofon-smartyard-compat.service -p Environment --value
curl -fsS http://127.0.0.1:3000/api/health
nginx -t
```

Не обновляйте master и node одним общим checkout или одним monorepo patch. Каждый проект обновляется только из собственного репозитория.

# Backup

Минимальный backup master:

```text
/etc/newdomofon-video/
/etc/nginx/sites-available/newdomofon-video.conf
/etc/systemd/system/newdomofon-smartyard-compat.service.d/
/var/www/newdomofon-video/
PostgreSQL database newdomofon_video
текущий Git commit
```

PostgreSQL dump:

```bash
set -a
. /etc/newdomofon-video/app.env
set +a

install -d -m 0700 /var/backups/newdomofon-video
pg_dump -Fc "$DATABASE_URL" \
  > "/var/backups/newdomofon-video/master-$(date +%Y%m%d-%H%M%S).dump"
```

Восстановление выполняйте сначала в отдельную тестовую БД.

# Rollback после неудачного обновления

1. Остановите backend.
2. Верните предыдущий Git commit.
3. Пересоберите backend/frontend.
4. При необходимости восстановите PostgreSQL dump.
5. Верните nginx и systemd overrides.
6. Запустите backend и проверьте health.

Пример отката к известному commit без удаления runtime-конфигурации:

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
curl -fsS http://127.0.0.1:3000/api/health
```

# Диагностика

## Состояние сервисов

```bash
systemctl status postgresql --no-pager -l
systemctl status newdomofon-video-backend --no-pager -l
systemctl status newdomofon-public-events-proxy --no-pager -l
systemctl status newdomofon-smartyard-compat --no-pager -l
```

## Журналы

```bash
journalctl -u newdomofon-video-backend -n 300 --no-pager
journalctl -u newdomofon-public-events-proxy -n 200 --no-pager
journalctl -u newdomofon-smartyard-compat -n 200 --no-pager
```

## PostgreSQL

```bash
set -a
. /etc/newdomofon-video/app.env
set +a

psql "$DATABASE_URL" -P pager=off -c '\dt'
psql "$DATABASE_URL" -P pager=off -c \
  'select name,status,last_seen_at,public_base_url,internal_url from dvr_servers order by name;'
```

## Проверка маршрутов

```bash
curl -i http://127.0.0.1:3000/api/health
curl -kI "https://${MASTER_DOMAIN}/"
curl -kfsS "https://${MASTER_DOMAIN}/api/health"
```

# Безопасность

- Используйте TLS на master и всех публичных node.
- Ограничьте SSH по IP и применяйте ключи вместо паролей.
- Не публикуйте `app.env`, database dumps и диагностические логи с RTSP URL.
- Не храните agent token и media secret в shell history.
- После утечки RTSP/ONVIF URL смените пароли камер.
- PostgreSQL не должен слушать публичные интерфейсы.
- Node internal URL должен быть доступен только master и административной сети.
- Не используйте permanent token для `scope=events`; event API принимает только expiring HMAC token.

# Правила разработки

Все изменения control plane выполняются только в:

```text
https://github.com/rirodevdom/newdomofon-video-master
```

Node-код не копируется в master. Общими являются только versioned contracts.

Порядок несовместимого изменения API:

1. обновить contract;
2. добавить обратно совместимую поддержку на master;
3. обновить node;
4. проверить production;
5. удалить старый endpoint только в следующей major-версии контракта.

Старый объединённый monorepo не является источником production-кода.

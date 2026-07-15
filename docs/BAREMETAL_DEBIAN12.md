# Развёртывание video master на Debian 12

Этот документ описывает **отдельный control-plane master**. Master хранит PostgreSQL, пользователей, устройства, камеры, node records, managed tokens и media gateways. Он не записывает камеры и не хранит основной DVR-архив.

Актуальная регистрация node:

1. video node разворачивается первой;
2. credentials выбираются оператором на node;
3. на master создаётся запись с теми же значениями;
4. master ничего не генерирует.

Подробно: [MANUAL_NODE_REGISTRATION.md](MANUAL_NODE_REGISTRATION.md).

Справочник `.env`: [ENVIRONMENT.md](ENVIRONMENT.md).

## 1. Требования

```text
Debian 12 x86_64
Node.js 22
PostgreSQL 15
Nginx
FFmpeg
MediaMTX для RTSP gateway
2–4 vCPU и 4–8 GB RAM — рекомендуемый минимум
20–40 GB system SSD
DNS record на master
Europe/Moscow на master и всех node
```

Публичные порты:

```text
22/tcp    SSH только доверенным адресам
80/tcp    HTTP redirect и ACME
443/tcp   frontend, API и HTTPS media
8554/tcp  RTSP gateway, желательно VPN/allowlist
```

Локальные services используют порты `3000`, `3082–3086`, `5432` и `9997`.

## 2. Подготовка Debian

Команды выполняются от `root`:

```bash
apt-get update
apt-get dist-upgrade -y
apt-get install -y git ca-certificates curl openssl jq rsync

timedatectl set-timezone Europe/Moscow
systemctl enable --now systemd-timesyncd

timedatectl status
date '+%Y-%m-%d %H:%M:%S %Z %z'
```

## 3. Получение проекта

```bash
install -d -m 0755 /opt
git clone \
  https://github.com/rirodevdom/newdomofon-video-master.git \
  /opt/newdomofon-video-master

cd /opt/newdomofon-video-master
git switch main
git pull --ff-only origin main

bash scripts/install-debian12-prereqs.sh
```

Проверка:

```bash
node --version
npm --version
psql --version
nginx -v
ffmpeg -version | head -1
```

## 4. PostgreSQL

Сгенерируйте локальный пароль и создайте role/database. Не публикуйте значение команды:

```bash
DB_PASSWORD="$(openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-')"

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE newdomofon LOGIN PASSWORD '${DB_PASSWORD}';
CREATE DATABASE newdomofon_video OWNER newdomofon;
SQL
```

Если role/database уже существуют, используйте существующие credentials и не выполняйте `CREATE` повторно.

## 5. Production environment

Шаблон:

```text
deploy/env/master.env.example
```

Рабочий файл:

```text
/etc/newdomofon-video/app.env
```

Подготовьте локально минимум:

```text
NODE_ENV=production
BACKEND_PORT=3000
DATABASE_URL=postgres://...
JWT_SECRET=...
ADMIN_LOGIN=admin
ADMIN_PASSWORD=...
CORS_ORIGIN=https://video.example.com
TRUST_PROXY=true
APP_PUBLIC_URL=https://video.example.com
SMARTYARD_PUBLIC_BASE_URL=https://video.example.com
INTERNAL_DVR_SECRET=...
PLAYBACK_TOKEN_TTL_SECONDS=900
NODE_REGISTRATION_TOKEN=
```

`NODE_REGISTRATION_TOKEN` оставляется пустым: legacy self-registration в актуальной ручной схеме не используется.

Node-specific `DVR_NODE_ID`, `DVR_NODE_TOKEN` и `DVR_NODE_MEDIA_SECRET` **не записываются** в master `app.env`; они вводятся через UI и сохраняются в PostgreSQL.

Генерация локальных master secrets:

```bash
JWT_SECRET="$(openssl rand -hex 48)"
ADMIN_PASSWORD="$(openssl rand -base64 36 | tr -d '\n')"
INTERNAL_DVR_SECRET="$(openssl rand -hex 32)"
```

Права:

```bash
install -d -o root -g newdomofon -m 0750 /etc/newdomofon-video
chown root:newdomofon /etc/newdomofon-video/app.env
chmod 0640 /etc/newdomofon-video/app.env
```

Каждая переменная описана в [ENVIRONMENT.md](ENVIRONMENT.md).

## 6. Первый deploy

```bash
cd /opt/newdomofon-video-master

PROJECT_DIR=/opt/newdomofon-video-master \
ENV_FILE=/etc/newdomofon-video/app.env \
INSTALL_DISK_GUARD=1 \
INSTALL_JOURNAL_LIMITS=1 \
INSTALL_RTSP_GATEWAY=1 \
  bash scripts/deploy-master.sh
```

Deploy:

- собирает backend/frontend;
- применяет migrations и seed;
- публикует frontend;
- устанавливает systemd units и Nginx;
- запускает SmartYard/media/events gateways;
- устанавливает disk guard;
- устанавливает MediaMTX RTSP gateway;
- отключает DVR recorder на strict master.

## 7. Nginx, DNS и TLS

```bash
export MASTER_DOMAIN=video.example.com

sed -i \
  "s/server_name _;/server_name ${MASTER_DOMAIN};/" \
  /etc/nginx/sites-available/newdomofon-video.conf

nginx -t
systemctl reload nginx

apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d "$MASTER_DOMAIN"
certbot renew --dry-run
```

После Certbot не заменяйте production site без backup. Проверяйте:

```bash
nginx -t
curl -fsS http://127.0.0.1:3000/api/health | jq
```

## 8. Проверка master

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active newdomofon-video-rtsp-gateway.service

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1:3082/health | jq

ss -lntp | grep -E ':(3000|3082|3083|3084|3085|3086|8554|9997)\b'
nginx -t
```

На strict master должно быть отключено:

```bash
systemctl disable --now newdomofon-video-dvr.service 2>/dev/null || true
```

## 9. Добавление заранее развёрнутой node

На node:

```bash
cat /root/newdomofon-node-master-registration.env
```

В master откройте:

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

Master:

- использует введённый UUID как `dvr_servers.id`;
- хранит SHA-256 хеш agent token;
- хранит media secret для внутренних tokens;
- сохраняет master URL в metadata;
- не показывает и не генерирует replacement credentials.

После следующего heartbeat node должна стать `online`.

## 10. Добавление устройств и камер

```text
1. Устройства → Добавить устройство.
2. Выбрать RTSP / ONVIF / HIKVISION.
3. Указать network credentials устройства.
4. Выбрать video node.
5. Выбрать archive_storage.
6. Открыть камеры устройства.
7. Найти/добавить channels.
8. Проверить recorder на node.
```

Placement принадлежит устройству: все его камеры наследуют node и archive storage.

## 11. RTSP gateway

Повторная установка:

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

Сначала обновляйте node, затем master, потому что MediaMTX использует relay endpoint node.

## 12. Безопасное обновление

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

Не восстанавливайте старый stash автоматически.

## 13. Backup

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

Backup содержит secrets и должен храниться с `0600/0750`.

## 14. Диагностика

```bash
systemctl --no-pager --full status newdomofon-video-backend.service
journalctl -u newdomofon-video-backend.service -n 300 --no-pager
journalctl -u newdomofon-smartyard-compat.service -n 300 --no-pager
journalctl -u newdomofon-video-rtsp-gateway.service -n 300 --no-pager
curl -fsS http://127.0.0.1:3000/api/health | jq
cat /run/newdomofon-video/master-disk-state.json | jq
nginx -t
```

При node `warning/offline` сначала проверяйте DVR service и heartbeat на самой node, затем `last_seen_at` в PostgreSQL master.

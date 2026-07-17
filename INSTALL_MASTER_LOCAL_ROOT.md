# Установка Video Master из локального архива от root

Этот сценарий предназначен для Debian 12, когда master ZIP/TAR уже передан на сервер и распакован внутри `/root`. Git и доступ к репозиторию не используются.

Рекомендуемый запускаемый файл:

```text
scripts/install-master-manual-local-root.sh
```

Wrapper использует монолитный root-only installer и оставляет legacy self-registration отключённой:

```text
NODE_REGISTRATION_TOKEN=
```

Credentials video node master не генерирует. После установки node оператор вводит её значения через `Администрирование → Ноды → Создать node`.

## 1. Распаковать архив

```bash
cd /root
unzip newdomofon-video-master-main.zip
cd /root/newdomofon-video-master-main
```

Проверка source:

```bash
test -f backend/package.json
test -f frontend/package.json
test -f scripts/install-master-manual-local-root.sh
test -f scripts/install-master-local-root.sh
```

## 2. Интерактивная установка

```bash
bash scripts/install-master-manual-local-root.sh
```

## 3. Установка по IP без TLS

```bash
bash scripts/install-master-manual-local-root.sh \
  --domain 10.106.1.30 \
  --no-tls \
  --admin-login admin
```

## 4. Установка с DNS/TLS

```bash
bash scripts/install-master-manual-local-root.sh \
  --domain video.example.ru \
  --email admin@example.ru \
  --admin-login admin \
  --tls
```

Для полностью локальной RTSP-установки можно передать MediaMTX package:

```bash
bash scripts/install-master-manual-local-root.sh \
  --domain 10.106.1.30 \
  --no-tls \
  --mediamtx-archive /root/mediamtx_vX.Y.Z_linux_amd64.tar.gz
```

## 5. Что делает installer

- устанавливает Debian packages и Node.js 22;
- задаёт timezone;
- запускает PostgreSQL и Nginx;
- сохраняет backup БД и конфигурации;
- копирует source из `/root` в `/opt/newdomofon-video-master`;
- создаёт или обновляет PostgreSQL role/database;
- генерирует только master-level secrets;
- оставляет `NODE_REGISTRATION_TOKEN` пустым;
- создаёт root-only `app.env`;
- собирает backend/frontend;
- применяет migrations и seed;
- устанавливает Nginx, gateways, disk guard и MediaMTX;
- проверяет backend/media health.

## 6. Какие secrets генерируются

```text
PostgreSQL password
JWT_SECRET
ADMIN_PASSWORD
MANAGED_CAMERA_TOKEN_SECRET
INTERNAL_DVR_SECRET
RTSP_GATEWAY_SHARED_SECRET
RTSP_RELAY_PUBLISH_SECRET
```

Installer не создаёт:

```text
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
```

## 7. Файлы после установки

```text
/etc/newdomofon-video/app.env
/root/newdomofon-master-access.txt
/root/newdomofon-master-access.json
/root/newdomofon-master-local-root-*.log
/opt/newdomofon-video-migration-backups/local-root-master-*
```

## 8. Проверка

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-public-events-proxy.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active postgresql.service
systemctl is-active nginx.service

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1/api/health | jq
nginx -t

grep '^NODE_REGISTRATION_TOKEN=' /etc/newdomofon-video/app.env
```

Ожидается:

```text
NODE_REGISTRATION_TOKEN=
```

## 9. Обновление

Для последующих обновлений используйте новый распакованный архив:

```bash
cd /root/newdomofon-video-master-main
bash update-installed-project.sh --dry-run
sudo bash update-installed-project.sh
```

Не используйте `--regenerate-secrets` при обычном повторном запуске работающего master.

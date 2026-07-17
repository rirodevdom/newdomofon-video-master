# Развёртывание video master на Debian 12 без Git

Этот документ описывает отдельный control-plane master. Master хранит PostgreSQL, пользователей, устройства, камеры, node records, managed tokens и media gateways. Он не записывает камеры и не хранит основной DVR-архив.

Production-сервер не должен иметь доступ к репозиторию. Установка выполняется только из ZIP/TAR, заранее скачанного на другом компьютере и переданного на сервер.

## 1. Требования

```text
Debian 12 x86_64
2–4 vCPU и 4–8 GB RAM
20–40 GB system SSD
Node.js 22
PostgreSQL 15
Nginx
FFmpeg
MediaMTX для RTSP gateway
Europe/Moscow на master и всех node
```

Публичные порты:

```text
22/tcp    SSH только доверенным адресам
80/tcp    HTTP или ACME
443/tcp   frontend, API и HTTPS media
8554/tcp  RTSP gateway, желательно VPN/allowlist
```

## 2. Подготовка Debian

Команды выполняются от `root`:

```bash
apt-get update
apt-get dist-upgrade -y
apt-get install -y \
  ca-certificates curl openssl jq rsync unzip tar \
  python3 postgresql postgresql-contrib nginx ffmpeg

timedatectl set-timezone Europe/Moscow
systemctl enable --now systemd-timesyncd
```

Git устанавливать не требуется.

## 3. Передать и распаковать архив

Скачайте ZIP проекта вне сервера, затем передайте его в `/root`.

```bash
cd /root
unzip newdomofon-video-master-main.zip
cd /root/newdomofon-video-master-main
```

Не распаковывайте архив внутрь `/opt/newdomofon-video-master`.

## 4. Запустить локальный установщик

Для HTTP по IP:

```bash
bash scripts/install-master-local-root.sh \
  --source-dir /root/newdomofon-video-master-main \
  --domain 10.106.1.30 \
  --no-tls
```

Для DNS и TLS:

```bash
bash scripts/install-master-local-root.sh \
  --source-dir /root/newdomofon-video-master-main \
  --domain video.example.ru \
  --email admin@example.ru \
  --tls
```

Также можно передать ZIP непосредственно архивному установщику:

```bash
bash scripts/install-master-from-archive.sh \
  --archive /root/newdomofon-video-master-main.zip \
  --domain 10.106.1.30 \
  --no-tls
```

Оба установщика работают только с локальными файлами и не обращаются к репозиторию.

## 5. Runtime-конфигурация

Рабочий файл:

```text
/etc/newdomofon-video/app.env
```

Он содержит PostgreSQL URL, JWT secret, admin password и internal gateway secrets. Не выводите его в общие логи.

Справочник: [ENVIRONMENT.md](ENVIRONMENT.md).

## 6. Проверка

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active newdomofon-video-rtsp-gateway.service

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1/api/health | jq
nginx -t
```

На strict master recorder отключён:

```bash
systemctl disable --now newdomofon-video-dvr.service 2>/dev/null || true
```

## 7. Регистрация node

1. Сначала установите video node.
2. На node откройте `/root/newdomofon-node-master-registration.env`.
3. На master откройте `Администрирование → Ноды → Создать node`.
4. Введите те же UUID, agent token, media secret и URL.
5. Дождитесь heartbeat.

Master ничего не генерирует для уже развёрнутой node. Подробно: [MANUAL_NODE_REGISTRATION.md](MANUAL_NODE_REGISTRATION.md).

## 8. Обновление

Сначала обновляются все node, затем master.

```bash
cd /root/newdomofon-video-master-main
bash update-installed-project.sh --dry-run
sudo bash update-installed-project.sh
```

Подробно: [UPDATE_FROM_ARCHIVE.md](UPDATE_FROM_ARCHIVE.md).

## 9. Production-пути

```text
/opt/newdomofon-video-master/                    установленная копия проекта
/etc/newdomofon-video/app.env                    runtime config и secrets
/var/www/newdomofon-video/                       frontend
/var/cache/newdomofon-video/smartyard-preview/   preview cache
/var/log/newdomofon-video/
/etc/nginx/sites-available/newdomofon-video.conf
/etc/systemd/system/newdomofon-*.service
```

## 10. Безопасность

- не используйте Git-команды на production-сервере;
- не публикуйте `app.env` и database backups;
- ограничьте PostgreSQL loopback/private network;
- разрешайте node `3010` только master;
- ограничьте RTSP `8554` VPN/allowlist;
- не запускайте `npm audit fix` автоматически на production.

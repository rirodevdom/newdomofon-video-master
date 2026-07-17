# NewDomofon Video Master

Центральный **control plane** NewDomofon Video: Vue/Vuetify admin UI, backend API, PostgreSQL, пользователи/RBAC, устройства, камеры, video node records, managed tokens, SmartYard compatibility, media/events gateways и MediaMTX RTSP gateway.

Этот репозиторий устанавливается **только на master**. Запись камер, live, DVR-архив и локальные события выполняются на video node из проекта `newdomofon-video-node`.

> Production: Debian 12, Node.js 22, PostgreSQL 15, Nginx, FFmpeg, systemd и MediaMTX. Docker не требуется.

## Серверы без доступа к репозиторию

Установка и обновление production-сервера выполняются только из ZIP/TAR, который:

1. скачан на другом компьютере;
2. передан на сервер;
3. распакован в отдельную папку, например `/root/newdomofon-video-master-main`.

Git на сервере не требуется и не используется. Нельзя применять `clone`, `fetch`, `pull`, `reset` или другие Git-команды для production-установки и обновления.

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
- media/events/preview gateways;
- SmartYard compatibility;
- RTSP gateway через MediaMTX;
- master disk guard.

Master не должен записывать камеры или хранить основной DVR-архив.

## Регистрация video node

Master больше не генерирует:

```text
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
```

Правильный порядок:

1. установить video node из распакованного node-архива;
2. получить `/root/newdomofon-node-master-registration.env`;
3. открыть `Администрирование → Ноды → Создать node`;
4. ввести значения из файла;
5. дождаться heartbeat.

Подробно: [docs/MANUAL_NODE_REGISTRATION.md](docs/MANUAL_NODE_REGISTRATION.md).

## Установка master из распакованного архива

После передачи и распаковки ZIP:

```bash
cd /root/newdomofon-video-master-main
bash scripts/install-master-local-root.sh --domain 10.106.1.30 --no-tls
```

Установщик:

- использует файлы текущей распакованной папки;
- не обращается к репозиторию;
- устанавливает зависимости Debian;
- создаёт PostgreSQL и runtime-конфигурацию;
- собирает backend и frontend;
- устанавливает systemd, Nginx и gateways;
- сохраняет secrets в `/etc/newdomofon-video/app.env`.

Можно передать сам архив установщику:

```bash
bash scripts/install-master-from-archive.sh \
  --archive /root/newdomofon-video-master-main.zip \
  --domain 10.106.1.30 \
  --no-tls
```

## Обновление master

Сначала обновите все video node, затем master.

Из корня нового распакованного архива:

```bash
cd /root/newdomofon-video-master-main
bash update-installed-project.sh --dry-run
sudo bash update-installed-project.sh
```

Updater создаёт backup исходников, `app.env`, Nginx, frontend и PostgreSQL, затем синхронизирует файлы архива и запускает штатный deploy. Версия архива фиксируется SHA-256 отпечатком содержимого.

Подробно: [docs/UPDATE_FROM_ARCHIVE.md](docs/UPDATE_FROM_ARCHIVE.md).

## Managed tokens

Модель many-to-many:

```text
одна камера → несколько пользовательских токенов
один токен → несколько камер
```

Токен с режимом автоматического назначения привязывается ко всем существующим и новым камерам. Управление привязками находится на странице «Камеры», а готовые ссылки каждого назначенного токена — на странице просмотра камеры.

## Production-пути

```text
/opt/newdomofon-video-master/                    установленная копия проекта
/etc/newdomofon-video/app.env                    runtime config и secrets
/etc/newdomofon-video/mediamtx.yml               MediaMTX config
/var/www/newdomofon-video/                       frontend
/var/cache/newdomofon-video/smartyard-preview/   preview cache
/var/log/newdomofon-video/
/run/newdomofon-video/master-disk-state.json
/etc/nginx/sites-available/newdomofon-video.conf
/etc/systemd/system/newdomofon-*.service
```

## Проверка

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active newdomofon-video-rtsp-gateway.service

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1/api/health | jq
nginx -t
```

На strict master recorder должен быть отключён:

```bash
systemctl disable --now newdomofon-video-dvr.service 2>/dev/null || true
```

## Документация

- [Установка на Debian 12 без Git](docs/BAREMETAL_DEBIAN12.md)
- [Обновление из распакованного архива](docs/UPDATE_FROM_ARCHIVE.md)
- [Ручная регистрация video node](docs/MANUAL_NODE_REGISTRATION.md)
- [Все переменные master `.env`](docs/ENVIRONMENT.md)
- [Автоматический RTSP gateway](docs/AUTOMATIC_RTSP_GATEWAY.md)
- [Защита диска](docs/DISK_PROTECTION.md)

## Безопасность

- не публикуйте `app.env` и database backups;
- не распаковывайте архив внутрь `/opt/newdomofon-video-master`;
- не запускайте updater из установленного каталога;
- ограничьте PostgreSQL loopback/private network;
- разрешайте node `3010` только master;
- ограничьте RTSP `8554` VPN/allowlist;
- не запускайте `npm audit fix` автоматически на production.

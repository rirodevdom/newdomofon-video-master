# NewDomofon Video Master

Центральный **control plane** NewDomofon Video: Vue/Vuetify admin UI, backend API, PostgreSQL, пользователи/RBAC, устройства, камеры, video node records, managed tokens, SmartYard compatibility, media/events gateways и MediaMTX RTSP gateway.

Этот репозиторий устанавливается **только на master**. Запись камер, live, локальный DVR-архив и события выполняются на универсальной video node из проекта `newdomofon-video-node`.

> Production: Debian 12, Node.js 22, PostgreSQL 15, Nginx, FFmpeg, systemd и MediaMTX. Docker не требуется.

## Граница ответственности

Master и обычная video node поддерживают только vendor-neutral контракты:

- RTSP-потоки;
- ONVIF discovery, profile lookup и PullPoint events;
- локальную запись, live, ranges и MP4 export;
- managed tokens и SmartYard-compatible media gateway.

В этих двух проектах нет Hikvision ISAPI, `alertStream`, vendor-specific поиска каналов, поиска записей NVR и воспроизведения архива устройства. Эти возможности будут реализованы отдельным сервисом и отдельным репозиторием Hikvision-node, который не входит в runtime master или обычной video node.

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
                 | RTSP / ONVIF
                 v
              Камеры / NVR
```

Master отвечает за PostgreSQL, RBAC, аудит, устройства, камеры, placement, node heartbeat, managed tokens, media/events/preview gateways, SmartYard compatibility, MediaMTX и disk guard. Master не записывает камеры и не хранит основной DVR-архив.

## Серверы без доступа к GitHub

Production устанавливается и обновляется только из ZIP/TAR, скачанного на другом компьютере и распакованного отдельно, например:

```text
/root/newdomofon-video-master-main
```

Git на production-сервере не требуется.

## Установка master

```bash
cd /root/newdomofon-video-master-main
bash scripts/install-master-local-root.sh --domain 10.106.1.30 --no-tls
```

Или из архива:

```bash
bash scripts/install-master-from-archive.sh \
  --archive /root/newdomofon-video-master-main.zip \
  --domain 10.106.1.30 \
  --no-tls
```

## Регистрация video node

1. Установите обычную video node из её архива.
2. Получите `/root/newdomofon-node-master-registration.env`.
3. Откройте `Администрирование → Ноды → Создать node`.
4. Введите `node_id`, agent token, media secret и URL.
5. Дождитесь heartbeat.

Подробно: [docs/MANUAL_NODE_REGISTRATION.md](docs/MANUAL_NODE_REGISTRATION.md).

## Обновление master

Сначала обновляются все обычные video node, затем master:

```bash
cd /root/newdomofon-video-master-main
bash update-installed-project.sh --dry-run
bash update-installed-project.sh
```

Updater создаёт backup исходников, `app.env`, Nginx, frontend и PostgreSQL, затем синхронизирует архив и запускает штатный deploy. Миграция удаления vendor-specific runtime сохраняет камеры и RTSP URL, переводит прежний тип устройства в `RTSP`, оставляет только локальный архив node и удаляет производные таблицы индекса архива устройства.

## Managed tokens

```text
одна камера → несколько пользовательских токенов
один токен → несколько камер
```

Управление привязками находится на странице «Камеры», готовые ссылки — на странице просмотра камеры.

## Production-пути

```text
/opt/newdomofon-video-master/
/etc/newdomofon-video/app.env
/etc/newdomofon-video/mediamtx.yml
/var/www/newdomofon-video/
/var/cache/newdomofon-video/smartyard-preview/
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
- [Граница репозиториев](docs/REPOSITORY_SPLIT.md)
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

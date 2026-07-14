# Установка NewDomofon Video Master из локального архива

Этот способ предназначен для серверов с нестабильным доступом к GitHub.

Исходный код проекта не клонируется и не обновляется через `git fetch`. Установщик берёт файлы из ZIP/TAR.GZ, который заранее скопирован в `/root`.

Поддерживаются:

```text
.zip
.tar.gz
.tgz
.tar
```

## Что всё ещё требует интернета

Локальный архив устраняет обращения к GitHub за исходным кодом проекта. Для чистого Debian интернет всё ещё нужен для:

- Debian APT repositories;
- NodeSource, если Node.js 22.12+ ещё не установлен;
- npm registry для `npm ci`;
- Let's Encrypt;
- MediaMTX, только если его архив отсутствует локально и в кеше.

MediaMTX можно также положить в `/root` заранее:

```text
/root/mediamtx_vX.Y.Z_linux_amd64.tar.gz
```

Установщик автоматически найдёт его. После первой успешной загрузки MediaMTX сохраняется в:

```text
/var/cache/newdomofon-video/install/
```

Повторная установка использует кеш и больше не скачивает тот же архив.

## 1. Скопируйте архив проекта

Пример:

```text
/root/newdomofon-video-master-main.zip
```

Проверьте:

```bash
ls -lh /root/newdomofon-video-master*
```

## 2. Извлеките только локальный установщик

```bash
apt-get update
apt-get install -y unzip

ARCHIVE="/root/newdomofon-video-master-main.zip"
INSTALLER="/root/install-newdomofon-master-from-archive.sh"

MEMBER="$(
  unzip -Z1 "$ARCHIVE" |
  grep -E '(^|/)scripts/install-master-from-archive\.sh$' |
  head -1
)"

test -n "$MEMBER"

unzip -p "$ARCHIVE" "$MEMBER" >"$INSTALLER"
chmod 700 "$INSTALLER"

bash -n "$INSTALLER"
```

## 3. Запустите установку

Интерактивно:

```bash
bash /root/install-newdomofon-master-from-archive.sh \
  --archive /root/newdomofon-video-master-main.zip
```

Скрипт спросит домен/IP и email для Let's Encrypt.

Неинтерактивно:

```bash
bash /root/install-newdomofon-master-from-archive.sh \
  --archive /root/newdomofon-video-master-main.zip \
  --domain new-video.domofon-37.ru \
  --email admin@example.com \
  --admin-login admin
```

По IP без TLS:

```bash
bash /root/install-newdomofon-master-from-archive.sh \
  --archive /root/newdomofon-video-master-main.zip \
  --domain 10.106.1.30 \
  --no-tls
```

## Что делает archive installer

1. Проверяет локальный архив.
2. Распаковывает его во временный root-only каталог.
3. Проверяет наличие backend, frontend и deployment scripts.
4. Создаёт временный локальный Git repository.
5. Использует `file://...` как источник — без обращения к GitHub.
6. Сохраняет предыдущий `/opt/newdomofon-video-master`.
7. Запускает полный one-shot installer.
8. Устанавливает PostgreSQL, backend, frontend, Nginx и gateways.
9. Ждёт реальный health backend перед установкой RTSP.
10. Использует существующий MediaMTX, локальный архив или постоянный кеш.
11. Выполняет финальные health checks.
12. Печатает все данные доступа.

## Исправление ошибки порта 3000

Ранее RTSP installer выполнял auth preflight сразу после:

```text
systemctl restart newdomofon-video-backend.service
```

Backend ещё не успевал открыть `127.0.0.1:3000`, поэтому появлялось:

```text
curl: (7) Failed to connect to 127.0.0.1 port 3000
```

Теперь deployment и RTSP installer ждут `/api/health` до 60 секунд. Если backend действительно не запускается, установка выводит `systemctl status` и последние 300 строк `journalctl`.

## Итоговые данные

После успеха:

```text
/root/newdomofon-master-access.txt
/root/newdomofon-master-access.json
```

Просмотр:

```bash
cat /root/newdomofon-master-access.txt
jq . /root/newdomofon-master-access.json
```

Там находятся:

- web URL;
- web login/password;
- PostgreSQL URL и credentials;
- node registration token;
- RTSP template;
- пути к логу и backup.

Права файлов — `0600`.

## Логи

```bash
ls -lt /root/newdomofon-master-install-*.log | head

tail -300 "$(
  ls -t /root/newdomofon-master-install-*.log |
  head -1
)"
```

## Backup старого проекта

Если `/opt/newdomofon-video-master` уже существовал, он переносится в:

```text
/opt/newdomofon-video-master.before-local-archive-YYYYMMDD-HHMMSS
```

База PostgreSQL не удаляется. Перед миграциями существующая база сохраняется в migration backup.

## Повторный запуск

Повторный запуск безопасен:

- существующая роль PostgreSQL не создаётся повторно;
- база не удаляется;
- secrets сохраняются, если не указан `--regenerate-secrets`;
- MediaMTX используется из установленного binary или кеша;
- старый checkout сохраняется.

Не используйте `--regenerate-secrets` без необходимости на рабочем сервере.

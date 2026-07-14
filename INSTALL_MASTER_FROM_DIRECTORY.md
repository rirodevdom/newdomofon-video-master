# Установка NewDomofon Video Master из распакованной папки

Этот способ предназначен для случая, когда архив проекта уже самостоятельно распакован в `/root`.

Исходный код не загружается через `git clone` или `git fetch`. Установщик берёт все файлы из указанной локальной папки, создаёт временный локальный Git source и разворачивает production-копию в:

```text
/opt/newdomofon-video-master
```

## Поддерживаемое расположение

Рекомендуемый вариант:

```text
/root/newdomofon-video-master-main/
```

Имя папки может быть любым, например:

```text
/root/newdomofon-master-20260715/
/root/video-master-source/
```

Также поддерживается распаковка непосредственно в `/root`, если там находятся:

```text
/root/backend/
/root/frontend/
/root/scripts/
/root/deploy/
```

## Проверка распакованной папки

Пример:

```bash
SOURCE_DIR="/root/newdomofon-video-master-main"

test -f "$SOURCE_DIR/backend/package.json"
test -f "$SOURCE_DIR/frontend/package.json"
test -f "$SOURCE_DIR/scripts/install-master-from-directory.sh"
test -f "$SOURCE_DIR/scripts/lib/master-one-shot-install.sh"

echo "Project directory is valid: $SOURCE_DIR"
```

## Самый простой запуск из папки проекта

```bash
cd /root/newdomofon-video-master-main

chmod 700 \
  scripts/install-master-from-directory.sh \
  scripts/install-master-from-archive.sh \
  scripts/install-master-one-shot.sh \
  scripts/lib/master-one-shot-install.sh \
  scripts/lib/master-one-shot-report.sh

bash scripts/install-master-from-directory.sh
```

Скрипт спросит:

```text
Master domain or IP:
Email for Let's Encrypt (optional):
```

## Неинтерактивная установка

```bash
cd /root/newdomofon-video-master-main

bash scripts/install-master-from-directory.sh \
  --domain video.example.ru \
  --email admin@example.ru \
  --admin-login admin
```

## Явное указание папки

Команду можно запустить из любого каталога:

```bash
bash /root/newdomofon-video-master-main/scripts/install-master-from-directory.sh \
  --source-dir /root/newdomofon-video-master-main \
  --domain video.example.ru \
  --email admin@example.ru \
  --admin-login admin
```

## По IP без TLS

```bash
bash /root/newdomofon-video-master-main/scripts/install-master-from-directory.sh \
  --source-dir /root/newdomofon-video-master-main \
  --domain 10.106.1.30 \
  --no-tls \
  --admin-login admin
```

## Автоматический поиск папки

Если отдельный установщик скопирован в `/root`, но `--source-dir` не указан, он автоматически ищет последнюю распакованную копию проекта внутри `/root`.

Поиск выполняется по обязательным файлам, а не только по имени каталога. Поэтому папка может называться произвольно.

## Что происходит с исходной папкой

Распакованная папка в `/root` не изменяется и не удаляется.

Установщик:

1. проверяет структуру исходников;
2. копирует их во временный root-only каталог;
3. исключает `.git`, `node_modules` и старые `dist`;
4. создаёт локальный Git snapshot;
5. устанавливает рабочую копию в `/opt/newdomofon-video-master`;
6. выполняет полный one-shot deploy;
7. сохраняет данные доступа.

Если `/opt/newdomofon-video-master` уже существует, он переносится в:

```text
/opt/newdomofon-video-master.before-local-source-YYYYMMDD-HHMMSS
```

PostgreSQL не удаляется. Существующая база сохраняется перед миграциями.

## Итоговые данные

После успешной установки:

```text
/root/newdomofon-master-access.txt
/root/newdomofon-master-access.json
```

Просмотр:

```bash
cat /root/newdomofon-master-access.txt
jq . /root/newdomofon-master-access.json
```

Там находятся web URL, login/password, PostgreSQL credentials, node registration token, RTSP template, журнал и backup.

## Проверка сервисов

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-public-events-proxy.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active newdomofon-video-rtsp-gateway.service
systemctl is-active postgresql
systemctl is-active nginx

curl -fsS http://127.0.0.1:3000/api/health | jq .
curl -fsS http://127.0.0.1:3082/health | jq .

ss -lntp | grep -E ':(3000|3057|3082|3083|3084|3085|3086|5432|8554|9997)\b'
nginx -t
```

## Интернет-зависимости

Исходники проекта не загружаются с GitHub. На чистом сервере интернет всё ещё может требоваться для:

- Debian APT;
- NodeSource, если Node.js 22.12+ отсутствует;
- npm registry;
- Let's Encrypt;
- MediaMTX, если его archive/binary/cache отсутствует.

MediaMTX можно заранее положить в `/root` или в папку проекта `vendor/`.

## Ошибка установки

Последний журнал:

```bash
tail -300 "$(ls -t /root/newdomofon-master-install-*.log | head -1)"
```

Backend:

```bash
systemctl --no-pager --full status newdomofon-video-backend.service
journalctl -u newdomofon-video-backend.service -n 300 --no-pager
```

Не используйте `--regenerate-secrets` при обычном повторном запуске на уже работающем master.

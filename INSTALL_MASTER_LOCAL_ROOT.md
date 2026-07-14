# Установка NewDomofon Video Master одним локальным root-скриптом

Эта инструкция предназначена для Debian 12, когда архив проекта уже скачан на другом компьютере и распакован в каталог внутри `/root`.

Используется только один запускаемый файл:

```text
scripts/install-master-local-root.sh
```

Он не выполняет `git clone`, `git fetch`, `git pull` и другие Git-команды. Он также не вызывает `deploy-master.sh`, `install-rtsp-gateway.sh`, `install-master-from-directory.sh` или другие установщики.

## Пользователи

Установщик не выполняет `useradd` или `groupadd` и не создаёт отдельного Linux-пользователя `newdomofon`.

Все процессы приложения NewDomofon Video Master запускаются как `root`:

```text
newdomofon-video-backend.service        root
newdomofon-public-events-proxy.service  root
newdomofon-smartyard-compat.service     root
newdomofon-video-rtsp-gateway.service   root
master disk guard                       root
```

Системные пакеты сохраняют штатные аккаунты:

```text
PostgreSQL server  postgres
Nginx worker       www-data
```

Это стандартные системные аккаунты пакетов Debian. Установщик их не создаёт вручную.

PostgreSQL role `newdomofon` является пользователем базы данных, а не Linux-пользователем.

---

# 1. Распакуйте архив

Пример:

```text
/root/newdomofon-video-master-main/
```

Проверьте структуру:

```bash
SOURCE_DIR=/root/newdomofon-video-master-main

test -f "$SOURCE_DIR/backend/package.json"
test -f "$SOURCE_DIR/frontend/package.json"
test -f "$SOURCE_DIR/scripts/install-master-local-root.sh"
test -f "$SOURCE_DIR/deploy/systemd/newdomofon-video-backend.service"

echo "Source is ready: $SOURCE_DIR"
```

Имя папки не имеет значения. При необходимости передайте её через `--source-dir`.

---

# 2. Необязательно положите MediaMTX рядом

Для полностью локальной установки RTSP положите в `/root` подходящий пакет:

```text
/root/mediamtx_vX.Y.Z_linux_amd64.tar.gz
```

Для ARM64:

```text
/root/mediamtx_vX.Y.Z_linux_arm64.tar.gz
```

Установщик автоматически найдёт пакет. Также можно явно указать:

```text
--mediamtx-archive /root/mediamtx_vX.Y.Z_linux_amd64.tar.gz
```

Если локального пакета и уже установленного MediaMTX нет, сценарий попробует скачать его с повторными попытками. Если загрузка недоступна, основной master всё равно будет установлен, а в отчёте появится:

```text
INSTALL_RTSP_STATUS=failed ... core master remains installed
```

Чтобы считать отсутствие RTSP фатальной ошибкой, используйте `--require-rtsp`.

---

# 3. Запустите один скрипт

```bash
cd /root/newdomofon-video-master-main

chmod 700 scripts/install-master-local-root.sh

bash scripts/install-master-local-root.sh
```

Сценарий спросит:

```text
Master domain or IP:
Email for Let's Encrypt (optional):
```

Указывайте домен без `https://`.

Пример:

```text
video.example.ru
```

## Полностью неинтерактивный запуск

```bash
bash /root/newdomofon-video-master-main/scripts/install-master-local-root.sh \
  --source-dir /root/newdomofon-video-master-main \
  --domain video.example.ru \
  --email admin@example.ru \
  --admin-login admin
```

## Установка по IP без TLS

```bash
bash /root/newdomofon-video-master-main/scripts/install-master-local-root.sh \
  --source-dir /root/newdomofon-video-master-main \
  --domain 10.106.1.30 \
  --no-tls \
  --admin-login admin
```

---

# Что выполняет один файл

Сценарий самостоятельно:

1. проверяет запуск от `root`;
2. находит распакованный проект в `/root`;
3. устанавливает Debian-пакеты;
4. устанавливает Node.js 22.12+, если он отсутствует;
5. задаёт `Europe/Moscow`;
6. запускает PostgreSQL и Nginx;
7. архивирует существующую БД и конфигурацию;
8. копирует локальные исходники в `/opt/newdomofon-video-master` через `rsync`;
9. не переносит `.git`, `.github`, `node_modules` и старые `dist`;
10. сохраняет предыдущую production-папку;
11. создаёт либо обновляет PostgreSQL role и database;
12. генерирует либо сохраняет пароли и секреты;
13. создаёт `/etc/newdomofon-video/app.env` с правами `root:root 0600`;
14. устанавливает зависимости backend;
15. собирает TypeScript;
16. применяет migrations и seed;
17. синхронизирует пароль web-администратора;
18. собирает frontend;
19. устанавливает public-events proxy;
20. создаёт root systemd units;
21. устанавливает Nginx-конфигурацию;
22. запускает backend и ждёт `/api/health`;
23. устанавливает master disk guard;
24. устанавливает MediaMTX/RTSP при доступности пакета;
25. пытается выпустить сертификат Let's Encrypt;
26. выполняет итоговые health-checks;
27. проверяет, что application units действительно работают как `root`;
28. выводит все данные доступа.

---

# Повторный запуск

По умолчанию повторный запуск сохраняет:

- базу PostgreSQL;
- пароль базы;
- web login/password;
- JWT secret;
- managed-token secret;
- node registration token;
- internal DVR secret;
- RTSP secrets.

Не используйте без необходимости:

```text
--regenerate-secrets
```

Предыдущий проект сохраняется как:

```text
/opt/newdomofon-video-master.before-local-root-YYYYMMDD-HHMMSS
```

Backup конфигурации и базы:

```text
/opt/newdomofon-video-migration-backups/local-root-master-YYYYMMDD-HHMMSS
```

---

# Данные после установки

Текстовый файл:

```bash
cat /root/newdomofon-master-access.txt
```

JSON:

```bash
jq . /root/newdomofon-master-access.json
```

Файлы имеют права `0600` и содержат:

```text
MASTER_WEB_URL
MASTER_ADMIN_URL
ADMIN_LOGIN
ADMIN_PASSWORD
DATABASE_URL
POSTGRES_HOST
POSTGRES_PORT
POSTGRES_DATABASE
POSTGRES_USER
POSTGRES_PASSWORD
NODE_REGISTRATION_TOKEN
INTERNAL_DVR_SECRET
RTSP_PUBLIC_URL_TEMPLATE
INSTALL_TLS_STATUS
INSTALL_RTSP_STATUS
SOURCE_DIRECTORY
SOURCE_FINGERPRINT
INSTALL_LOG
INSTALL_BACKUP
SYSTEM_USERS_CREATED_BY_INSTALLER=none
MASTER_APPLICATION_RUNTIME_USER=root
```

---

# Проверка

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-public-events-proxy.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active postgresql.service
systemctl is-active nginx.service
```

Health:

```bash
curl -fsS http://127.0.0.1:3000/api/health | jq .
curl -fsS http://127.0.0.1:3082/health | jq .
```

Проверка runtime-пользователей:

```bash
for service in \
  newdomofon-video-backend.service \
  newdomofon-public-events-proxy.service \
  newdomofon-smartyard-compat.service \
  newdomofon-video-rtsp-gateway.service; do
  if systemctl cat "$service" >/dev/null 2>&1; then
    printf '%-48s user=%s\n' \
      "$service" \
      "$(systemctl show -p User --value "$service")"
  fi
done
```

Для application units ожидается:

```text
user=root
```

Порты:

```bash
ss -lntp | grep -E ':(3000|3057|3082|3083|3084|3085|3086|5432|8554|9997)\b'
```

---

# Интернет-зависимости

GitHub не используется для загрузки исходников проекта.

На чистом сервере интернет всё ещё может понадобиться для:

- Debian APT repositories;
- NodeSource, если Node.js 22 отсутствует;
- npm registry;
- Let's Encrypt;
- MediaMTX, только если локальный пакет не положен в `/root`.

Для полностью автономной установки нужно отдельно подготовить APT/npm cache и локальный пакет MediaMTX.

---

# Журнал ошибок

Последний журнал:

```bash
LOG="$(ls -t /root/newdomofon-master-local-root-*.log | head -1)"
echo "$LOG"
tail -300 "$LOG"
```

Backend:

```bash
systemctl --no-pager --full status newdomofon-video-backend.service
journalctl -u newdomofon-video-backend.service -n 300 --no-pager
```

RTSP:

```bash
systemctl --no-pager --full status newdomofon-video-rtsp-gateway.service
journalctl -u newdomofon-video-rtsp-gateway.service -n 300 --no-pager
```

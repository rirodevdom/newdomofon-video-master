# Установка Video Master из распакованной папки

Этот способ используется, когда master ZIP/TAR уже передан на сервер и распакован внутри `/root`. Git и доступ к репозиторию не используются.

Запускайте:

```text
scripts/install-master-manual-local-root.sh
```

Wrapper устанавливает strict master, отключает legacy self-registration и не генерирует credentials video node.

## 1. Расположение source

Рекомендуется:

```text
/root/newdomofon-video-master-main/
```

Проверка:

```bash
SOURCE_DIR=/root/newdomofon-video-master-main

test -f "$SOURCE_DIR/backend/package.json"
test -f "$SOURCE_DIR/frontend/package.json"
test -f "$SOURCE_DIR/scripts/install-master-manual-local-root.sh"
test -f "$SOURCE_DIR/scripts/install-master-local-root.sh"
```

Source directory должен находиться вне `/opt/newdomofon-video-master`.

## 2. Интерактивный запуск

```bash
cd "$SOURCE_DIR"
bash scripts/install-master-manual-local-root.sh
```

## 3. DNS/TLS

```bash
cd "$SOURCE_DIR"

bash scripts/install-master-manual-local-root.sh \
  --domain video.example.ru \
  --email admin@example.ru \
  --admin-login admin \
  --tls
```

## 4. IP без TLS

```bash
cd "$SOURCE_DIR"

bash scripts/install-master-manual-local-root.sh \
  --domain 10.106.1.30 \
  --no-tls \
  --admin-login admin
```

Wrapper сам передаёт корректный `--source-dir` внутреннему installer.

## 5. Что происходит с source

Распакованная папка не удаляется. Installer:

- копирует source в `/opt/newdomofon-video-master`;
- исключает служебные metadata, `node_modules` и старые `dist`;
- сохраняет предыдущую production copy;
- сохраняет PostgreSQL/config backup;
- устанавливает backend/frontend/gateways;
- оставляет `NODE_REGISTRATION_TOKEN` пустым.

## 6. Runtime

Application units в этом сценарии работают от `root`. PostgreSQL остаётся `postgres`, Nginx worker — `www-data`.

## 7. Проверка результата

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-public-events-proxy.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active postgresql
systemctl is-active nginx

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1/api/health | jq
nginx -t

grep '^NODE_REGISTRATION_TOKEN=' /etc/newdomofon-video/app.env
```

Ожидается:

```text
NODE_REGISTRATION_TOKEN=
```

## 8. Файлы доступа

```text
/root/newdomofon-master-access.txt
/root/newdomofon-master-access.json
```

Файлы содержат реальные passwords/secrets и должны оставаться `0600`.

## 9. Регистрация video node

Node разворачивается отдельно и создаёт:

```text
/root/newdomofon-node-master-registration.env
```

Все значения из него вводятся в:

```text
Администрирование → Ноды → Создать node
```

Master не генерирует ID/token/media secret.

## 10. Обновление

```bash
cd /root/newdomofon-video-master-main
bash update-installed-project.sh --dry-run
sudo bash update-installed-project.sh
```

Полный справочник `.env`: [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md).

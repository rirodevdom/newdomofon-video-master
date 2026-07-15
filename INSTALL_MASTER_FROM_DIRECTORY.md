# Установка Video Master из распакованной папки

Этот способ используется, когда source master уже распакован внутри `/root` и Git не нужен.

Для актуальной схемы запускайте:

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

Source directory должен находиться внутри `/root`.

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
  --admin-login admin
```

## 4. IP без TLS

```bash
cd "$SOURCE_DIR"

bash scripts/install-master-manual-local-root.sh \
  --domain 10.106.1.30 \
  --no-tls \
  --admin-login admin
```

Wrapper сам передаёт корректный `--source-dir` внутреннему installer. Не добавляйте второй `--source-dir` вручную.

## 5. Что происходит с source

Распакованная папка не удаляется. Installer:

- копирует source в `/opt/newdomofon-video-master`;
- исключает `.git`, `.github`, `node_modules` и старые `dist`;
- сохраняет предыдущую production copy;
- сохраняет PostgreSQL/config backup;
- устанавливает backend/frontend/gateways;
- оставляет `NODE_REGISTRATION_TOKEN` пустым.

## 6. Runtime user

Этот специальный сценарий запускает application units от `root`. PostgreSQL остаётся `postgres`, Nginx worker — `www-data`.

Обычная установка из Git с пользователем `newdomofon` предпочтительнее. Подробно: [ROOT_RUNTIME_MASTER.md](ROOT_RUNTIME_MASTER.md).

## 7. Проверка результата

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-public-events-proxy.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active postgresql
systemctl is-active nginx

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1:3082/health | jq
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

Wrapper редактирует marker legacy token на:

```text
DISABLED_MANUAL_NODE_REGISTRATION
```

Файлы содержат другие реальные passwords/secrets и должны оставаться `0600`.

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

## 10. `.env`

Полный справочник: [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md).

## 11. Диагностика

```bash
LOG="$(ls -t /root/newdomofon-master-local-root-*.log | head -1)"
tail -300 "$LOG"

systemctl --no-pager --full status newdomofon-video-backend.service
journalctl -u newdomofon-video-backend.service -n 300 --no-pager
```

Не используйте `--regenerate-secrets` при обычном повторном запуске работающего master.
# Установка Video Master из локального архива

Этот способ используется, когда source archive заранее скопирован на Debian 12 и GitHub недоступен для загрузки исходников.

Актуальная схема не использует старый archive one-shot installer, который мог генерировать legacy node registration token. Распакуйте source и запустите:

```text
scripts/install-master-manual-local-root.sh
```

Он устанавливает strict master и оставляет:

```text
NODE_REGISTRATION_TOKEN=
```

Credentials video node создаются на самой node и позже вводятся через UI master.

## 1. Поддерживаемые archives

```text
.zip
.tar.gz
.tgz
.tar
```

Пример:

```text
/root/newdomofon-video-master-main.zip
```

## 2. Распаковка ZIP

```bash
apt-get update
apt-get install -y unzip

ARCHIVE=/root/newdomofon-video-master-main.zip
DEST=/root/newdomofon-video-master-main

rm -rf "$DEST"
unzip -q "$ARCHIVE" -d /root
```

Проверьте фактический каталог после распаковки:

```bash
find /root -maxdepth 3 -type f \
  -path '*/scripts/install-master-manual-local-root.sh' \
  -print
```

## 3. Распаковка TAR

```bash
ARCHIVE=/root/newdomofon-video-master-main.tar.gz
DEST=/root/newdomofon-video-master-main

rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$ARCHIVE" -C "$DEST" --strip-components=1
```

Для `.tar` используйте `tar -xf`, для `.tgz` — `tar -xzf`.

## 4. Проверка source

```bash
SOURCE_DIR=/root/newdomofon-video-master-main

test -f "$SOURCE_DIR/backend/package.json"
test -f "$SOURCE_DIR/frontend/package.json"
test -f "$SOURCE_DIR/scripts/install-master-manual-local-root.sh"
test -f "$SOURCE_DIR/scripts/install-master-local-root.sh"
```

## 5. Необязательный MediaMTX archive

Для offline RTSP положите рядом подходящий package:

```text
/root/mediamtx_vX.Y.Z_linux_amd64.tar.gz
/root/mediamtx_vX.Y.Z_linux_arm64.tar.gz
```

## 6. Запуск

Интерактивно:

```bash
cd "$SOURCE_DIR"
bash scripts/install-master-manual-local-root.sh
```

С DNS/TLS:

```bash
cd "$SOURCE_DIR"

bash scripts/install-master-manual-local-root.sh \
  --domain video.example.ru \
  --email admin@example.ru \
  --admin-login admin
```

По IP без TLS:

```bash
cd "$SOURCE_DIR"

bash scripts/install-master-manual-local-root.sh \
  --domain 10.106.1.30 \
  --no-tls \
  --admin-login admin
```

## 7. Интернет-зависимости

Локальный source archive устраняет обращение к GitHub. На чистом сервере интернет всё ещё может требоваться для:

- Debian APT;
- NodeSource;
- npm registry;
- Let's Encrypt;
- MediaMTX при отсутствии локального package.

Для полностью offline deployment подготовьте APT/npm cache и MediaMTX package.

## 8. Результат

```text
/opt/newdomofon-video-master
/etc/newdomofon-video/app.env
/root/newdomofon-master-access.txt
/root/newdomofon-master-access.json
/root/newdomofon-master-local-root-*.log
```

Проверьте:

```bash
grep '^NODE_REGISTRATION_TOKEN=' /etc/newdomofon-video/app.env
```

Ожидается:

```text
NODE_REGISTRATION_TOKEN=
```

## 9. Проверка services

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active postgresql
systemctl is-active nginx

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1:3082/health | jq
nginx -t
```

## 10. Добавление node

После отдельного развёртывания node получите:

```text
/root/newdomofon-node-master-registration.env
```

Введите все шесть значений в `Администрирование → Ноды → Создать node`. Master ничего не генерирует.

Подробно: [docs/MANUAL_NODE_REGISTRATION.md](docs/MANUAL_NODE_REGISTRATION.md).

## 11. `.env`

Все master settings: [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md).

Не публикуйте access reports, `app.env` и backups.
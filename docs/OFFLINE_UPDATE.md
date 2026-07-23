# Полностью offline-обновление Video Master

Обычный source ZIP и `update-installed-project.sh` не используют Git, но штатный deploy выполняет `npm ci` для backend, frontend и public-events proxy. Поэтому один source ZIP не гарантирует обновление сервера без доступа к npm registry.

Для изолированных серверов используется специальный **offline bundle**. Он содержит:

- исходники конкретного GitHub commit;
- все `package-lock.json` из этого commit;
- полный npm cache для production и build-зависимостей;
- `offline-update.sh`, принудительно включающий `npm_config_offline=true`;
- SHA-256 пакета и внутреннего npm cache;
- manifest с commit, платформой, архитектурой и версиями Node/npm.

## Получение пакета

В GitHub Actions откройте workflow:

```text
Offline master update bundle
```

Запустите `Run workflow` на ветке `main` или скачайте artifact последнего успешного запуска после обновления `main`.

Artifact содержит:

```text
newdomofon-video-master-offline-<commit>.tar.gz
newdomofon-video-master-offline-<commit>.tar.gz.sha256
newdomofon-video-master-offline-<commit>.txt
```

Скачивание выполняется на компьютере с доступом к GitHub. Затем все три файла переносятся на master через SCP, USB-носитель или внутреннее файловое хранилище.

## Проверка на сервере

```bash
cd /root
sha256sum -c newdomofon-video-master-offline-*.tar.gz.sha256
```

Распаковка:

```bash
tar -xzf newdomofon-video-master-offline-*.tar.gz
cd /root/newdomofon-video-master-offline-*
```

Проверьте commit:

```bash
cat .offline-update/manifest.env
```

## Dry-run

```bash
bash offline-update.sh --dry-run
```

Dry-run не изменяет сервисы и БД. Он проверяет платформу, архитектуру, Node.js, checksum npm cache и показывает rsync-изменения.

## Обновление

```bash
sudo bash offline-update.sh
```

Чтобы намеренно заменить старый Nginx-конфиг текущей версией из пакета:

```bash
sudo bash offline-update.sh --use-archive-nginx
```

По умолчанию production Nginx сохраняется. Исходники, backend/frontend runtime, migrations и systemd units обновляются из пакета; `app.env`, PostgreSQL и рабочие данные сохраняются.

## Порядок обновления системы

Сначала обновите и проверьте все video node. Master обновляется последним.

Проверка master:

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active nginx.service
curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1:3082/health | jq
nginx -t
cat /opt/newdomofon-video-master/.installed-from-extracted-source
```

## Что означает «соответствует GitHub»

Offline bundle фиксирует конкретный `source_commit`. После успешного deploy application source, lockfiles, собранные backend/frontend, production dependencies, migrations и systemd units соответствуют этому commit.

Намеренно не заменяются эксплуатационные данные:

- `/etc/newdomofon-video/app.env`;
- PostgreSQL data;
- администраторы, камеры, устройства и токены;
- production Nginx, если не передан `--use-archive-nginx`;
- TLS-сертификаты и локальные секреты.

Поэтому сервер функционально приводится к версии указанного commit, но не становится побайтовой копией чистой установки.

## Требования

На сервере уже должны быть установлены компоненты существующей production-инсталляции:

- Debian 12;
- Node.js не ниже 22.12.0;
- npm;
- PostgreSQL client (`pg_dump`);
- Python 3;
- rsync, tar, sha256sum;
- Nginx и systemd.

Сам update не обращается к GitHub, npm registry или другим внешним источникам. Let's Encrypt и APT во время update не используются.

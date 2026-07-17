# Обновление Master из распакованного архива

Используйте этот способ, когда ZIP/TAR проекта скачивается из GitHub вручную и распаковывается непосредственно на сервере.

> Сначала обновите все video node и проверьте их health/recorders. Master обновляется последним.

## 1. Скачать и распаковать архив

Пример для GitHub ZIP:

```bash
cd /root
unzip newdomofon-video-master-main.zip
cd /root/newdomofon-video-master-main
```

Имя распакованной папки может отличаться. Главное — запускать файл из корня распакованного master-проекта.

## 2. Предварительная проверка

```bash
bash update-installed-project.sh --dry-run
```

Dry-run показывает, какие файлы будут синхронизированы в:

```text
/opt/newdomofon-video-master
```

Сервер, база и сервисы при этом не изменяются.

## 3. Обновление

```bash
sudo bash update-installed-project.sh
```

Скрипт автоматически:

- использует исходники из текущей распакованной папки;
- сохраняет `/etc/newdomofon-video/app.env`;
- создаёт дамп PostgreSQL;
- сохраняет действующий Nginx и опубликованный frontend;
- сохраняет текущие исходники установленного проекта;
- синхронизирует новую версию без `.git`, `node_modules`, `dist` и env-файлов;
- запускает штатный master deploy;
- сохраняет production Nginx по умолчанию;
- повторно нормализует media CORS;
- проверяет backend и публичный health.

Backup и полный журнал создаются в:

```text
/opt/newdomofon-video-migration-backups/master-archive-update-ДАТА-ВРЕМЯ/
```

## 4. Проверка

```bash
curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1/api/health | jq
systemctl is-active newdomofon-video-backend.service
```

## Production Nginx

По умолчанию действующий Nginx сохраняется, чтобы архив не вернул старый домен, TLS или CORS-конфигурацию.

Только для намеренной замены конфигурации версией из архива:

```bash
sudo bash update-installed-project.sh --use-archive-nginx
```

## Важные ограничения

- Не распаковывайте архив внутрь `/opt/newdomofon-video-master`.
- Не запускайте updater из самого установленного каталога.
- Не удаляйте backup до проверки live, archive, токенов, CORS и node heartbeat.
- При ошибке база автоматически не откатывается: это защищает данные, появившиеся после начала обновления.

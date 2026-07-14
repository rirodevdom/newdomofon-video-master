# NewDomofon Video Master: запуск приложения под root

Актуальный master deployment запускает все application-компоненты NewDomofon от системного пользователя `root`:

```text
newdomofon-video-backend.service        root
newdomofon-public-events-proxy.service  root
newdomofon-smartyard-compat.service     root
newdomofon-video-rtsp-gateway.service   root
newdomofon-video-srs.service            root (если используется)
newdomofon-video-master-disk-guard      root
```

Системные инфраструктурные службы сохраняют штатных пользователей:

```text
PostgreSQL server  postgres
Nginx worker       www-data
```

PostgreSQL role `newdomofon` — это пользователь базы данных, а не Linux runtime-пользователь приложения.

## Почему введён root runtime

Установка из локального ZIP или распакованной папки работает с `umask 077` и временным root-only Git source. При запуске Node.js от отдельного Linux-пользователя production checkout мог оказаться недоступным, что приводило к:

```text
status=200/CHDIR
Changing to the requested working directory failed: Permission denied
```

В root runtime проект хранится как:

```text
owner: root:root
mode:  0700 для корня проекта
```

Sensitive environment:

```text
/etc/newdomofon-video/app.env
owner: root:root
mode:  0600
```

Frontend остаётся читаемым Nginx:

```text
/var/www/newdomofon-video
directories: 0755
files:       0644
owner:       root:root
```

## Новая установка

Запускайте directory/archive installer от root. `deploy-master.sh` автоматически устанавливает root units и нормализует права до запуска systemd.

## Перевод существующего master

После установки свежего source archive:

```bash
PROJECT_DIR=/opt/newdomofon-video-master \
  bash /opt/newdomofon-video-master/scripts/repair-master-project-permissions.sh
```

Скрипт:

1. останавливает application services;
2. переводит project и environment в `root:root`;
3. устанавливает root systemd units;
4. выполняет `daemon-reload`;
5. запускает backend, events, SmartYard и RTSP;
6. ждёт backend health;
7. печатает фактического пользователя каждого unit.

Проверка:

```bash
for service in \
  newdomofon-video-backend.service \
  newdomofon-public-events-proxy.service \
  newdomofon-smartyard-compat.service \
  newdomofon-video-rtsp-gateway.service; do
  printf '%-48s ' "$service"
  systemctl show -p User --value "$service"
done
```

Ожидается `root` для каждого application service.

Health:

```bash
curl -fsS http://127.0.0.1:3000/api/health | jq .
curl -fsS http://127.0.0.1:3082/health | jq .
```

## Безопасность

Root runtime устраняет межпользовательские проблемы прав, но повышает последствия уязвимости в приложении. Поэтому обязательно:

- не публикуйте `app.env`;
- сохраняйте `NoNewPrivileges`, `ProtectSystem`, `ProtectHome` и другие systemd sandbox directives;
- ограничьте порт node и RTSP firewall-правилами;
- своевременно обновляйте зависимости;
- не запускайте сторонние скрипты внутри project tree;
- храните project tree с mode `0700`.

# Video Master: специальный root-only runtime

Обычная production-установка из Git должна использовать systemd units и права, установленные `deploy-master.sh`. Root-only runtime применяется только для локальной установки из распакованного source tree через:

```text
scripts/install-master-manual-local-root.sh
```

Он нужен там, где production project намеренно хранится как root-only и application services должны работать от `root`.

## Runtime users

Root-only application services:

```text
newdomofon-video-backend.service        root
newdomofon-public-events-proxy.service  root
newdomofon-smartyard-compat.service     root
newdomofon-video-rtsp-gateway.service   root
master disk guard                       root
```

Системные services сохраняют package accounts:

```text
PostgreSQL server  postgres
Nginx worker       www-data
```

PostgreSQL role `newdomofon` — database user, а не Linux runtime user.

## Когда root-only режим нужен

- source доставляется archive и распаковывается в `/root`;
- Git не используется;
- project tree намеренно имеет `root:root 0700`;
- требуется единый монолитный installer без отдельного Linux application user.

Для обычного сетевого production-развёртывания предпочтительнее стандартный deploy и ограниченный runtime user.

## Project и environment

```text
/opt/newdomofon-video-master
owner: root:root
mode: 0700
```

```text
/etc/newdomofon-video/app.env
owner: root:root
mode: 0600
```

Frontend остаётся читаемым Nginx:

```text
/var/www/newdomofon-video
owner: root:root
directories: 0755
files: 0644
```

## Node registration в root-only master

Root-only wrapper принудительно отключает legacy self-registration:

```text
NODE_REGISTRATION_TOKEN=
```

Video node credentials master не генерирует. Они выбираются на node и вводятся через UI.

## Установка

```bash
cd /root/newdomofon-video-master-main
bash scripts/install-master-manual-local-root.sh
```

Подробно: [INSTALL_MASTER_LOCAL_ROOT.md](INSTALL_MASTER_LOCAL_ROOT.md).

## Проверка runtime users

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

Ожидается `user=root` только в этом специальном сценарии.

Health:

```bash
curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1:3082/health | jq
```

## Переход существующего root-only master

Запустите новый wrapper поверх свежего source archive. Он создаст backup существующей production copy, БД и `app.env`, затем переустановит units и очистит legacy registration token.

Не используйте старый `repair-master-project-permissions.sh` как способ перевести обычную установку в root runtime без полного понимания последствий.

## Безопасность

Root runtime повышает последствия уязвимости. Обязательно:

- не публикуйте `app.env` и access reports;
- храните project tree `0700`;
- сохраняйте systemd sandbox directives;
- ограничьте PostgreSQL loopback/private network;
- ограничьте RTSP firewall/VPN;
- не запускайте сторонние scripts внутри project tree;
- своевременно обновляйте dependencies;
- не включайте `NODE_REGISTRATION_TOKEN`;
- не используйте root-only режим без явной эксплуатационной причины.

Все `.env` параметры: [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md).
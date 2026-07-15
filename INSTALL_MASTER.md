# Установка NewDomofon Video Master

Актуальный master — отдельный strict control plane без DVR recorder. Он не генерирует credentials video node.

Основные инструкции:

- обычная установка из Git: [docs/BAREMETAL_DEBIAN12.md](docs/BAREMETAL_DEBIAN12.md);
- установка из распакованного локального source от root: [INSTALL_MASTER_LOCAL_ROOT.md](INSTALL_MASTER_LOCAL_ROOT.md);
- все параметры `/etc/newdomofon-video/app.env`: [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md);
- регистрация node: [docs/MANUAL_NODE_REGISTRATION.md](docs/MANUAL_NODE_REGISTRATION.md).

## Поддерживаемая схема

```text
1. Установить master.
2. Оставить NODE_REGISTRATION_TOKEN пустым.
3. Отдельно развернуть video node.
4. Выбрать credentials на самой node.
5. Ввести их в Администрирование → Ноды → Создать node.
```

Master генерирует только собственные passwords/secrets: PostgreSQL, JWT, admin, managed-token и RTSP gateway. Он не создаёт:

```text
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
```

## Обычная установка из Git

```bash
git clone \
  https://github.com/rirodevdom/newdomofon-video-master.git \
  /opt/newdomofon-video-master

cd /opt/newdomofon-video-master
bash scripts/install-debian12-prereqs.sh
```

Подготовьте `/etc/newdomofon-video/app.env` по шаблону:

```text
deploy/env/master.env.example
```

Затем:

```bash
PROJECT_DIR=/opt/newdomofon-video-master \
ENV_FILE=/etc/newdomofon-video/app.env \
INSTALL_DISK_GUARD=1 \
INSTALL_JOURNAL_LIMITS=1 \
INSTALL_RTSP_GATEWAY=1 \
  bash scripts/deploy-master.sh
```

## Установка из локальной распакованной папки

Используйте только wrapper актуальной схемы:

```bash
cd /root/newdomofon-video-master-main
bash scripts/install-master-manual-local-root.sh
```

Он принудительно оставляет:

```text
NODE_REGISTRATION_TOKEN=
```

и не создаёт legacy self-registration token.

## Проверка

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active newdomofon-video-rtsp-gateway.service
systemctl is-active postgresql
systemctl is-active nginx

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1:3082/health | jq
nginx -t
```

Strict master recorder:

```bash
systemctl disable --now newdomofon-video-dvr.service 2>/dev/null || true
```

## Устаревший one-shot installer

Не используйте старую опубликованную команду, которая скачивает `scripts/install-master-one-shot.sh` из `main`, пока новая схема не слита в `main`. Старый one-shot может генерировать `NODE_REGISTRATION_TOKEN` и описывать master-generated node credentials.

Для текущей feature-версии используйте checkout branch и `deploy-master.sh` либо локальный `install-master-manual-local-root.sh`.

## Данные доступа

`app.env`, access reports и PostgreSQL backups содержат реальные secrets. Храните их с правами `0600/0750` и не отправляйте в общие чаты.
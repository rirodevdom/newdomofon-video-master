# Установка NewDomofon Video Master

Актуальный master — отдельный strict control plane без DVR recorder. Он не генерирует credentials video node.

Production-сервер устанавливается только из локального ZIP/TAR или уже распакованной папки. Git и доступ к репозиторию на сервере не используются.

## Основные инструкции

- установка на Debian 12 из распакованного архива: [docs/BAREMETAL_DEBIAN12.md](docs/BAREMETAL_DEBIAN12.md);
- локальный root-installer: [INSTALL_MASTER_LOCAL_ROOT.md](INSTALL_MASTER_LOCAL_ROOT.md);
- установка непосредственно из ZIP/TAR: [INSTALL_MASTER_FROM_ARCHIVE.md](INSTALL_MASTER_FROM_ARCHIVE.md);
- установка из готовой папки: [INSTALL_MASTER_FROM_DIRECTORY.md](INSTALL_MASTER_FROM_DIRECTORY.md);
- обновление установленного master: [docs/UPDATE_FROM_ARCHIVE.md](docs/UPDATE_FROM_ARCHIVE.md);
- все параметры `/etc/newdomofon-video/app.env`: [docs/ENVIRONMENT.md](docs/ENVIRONMENT.md);
- регистрация node: [docs/MANUAL_NODE_REGISTRATION.md](docs/MANUAL_NODE_REGISTRATION.md).

## Поддерживаемая схема

```text
1. Передать ZIP/TAR master на сервер.
2. Распаковать проект в /root.
3. Запустить локальный installer.
4. Оставить NODE_REGISTRATION_TOKEN пустым.
5. Отдельно развернуть video node.
6. Выбрать credentials на самой node.
7. Ввести их в Администрирование → Ноды → Создать node.
```

Master генерирует только собственные passwords/secrets: PostgreSQL, JWT, admin, managed-token и RTSP gateway. Он не создаёт:

```text
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
```

## Установка из распакованной папки

```bash
cd /root/newdomofon-video-master-main
bash scripts/install-master-manual-local-root.sh \
  --domain 10.106.1.30 \
  --no-tls
```

Wrapper устанавливает strict master и принудительно оставляет:

```text
NODE_REGISTRATION_TOKEN=
```

## Установка непосредственно из ZIP

```bash
bash /root/newdomofon-video-master-main/scripts/install-master-from-archive.sh \
  --archive /root/newdomofon-video-master-main.zip \
  --domain 10.106.1.30 \
  --no-tls
```

Архивный installer распаковывает локальный файл и передаёт найденный source в `install-master-local-root.sh`. Репозиторий не используется.

## Обновление

Сначала обновляются все video node, затем master.

```bash
cd /root/newdomofon-video-master-main
bash update-installed-project.sh --dry-run
sudo bash update-installed-project.sh
```

## Проверка

```bash
systemctl is-active newdomofon-video-backend.service
systemctl is-active newdomofon-smartyard-compat.service
systemctl is-active newdomofon-video-rtsp-gateway.service
systemctl is-active postgresql
systemctl is-active nginx

curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1/api/health | jq
nginx -t
```

Strict master recorder:

```bash
systemctl disable --now newdomofon-video-dvr.service 2>/dev/null || true
```

## Данные доступа

`app.env`, access reports и PostgreSQL backups содержат реальные secrets. Храните их с правами `0600/0750` и не отправляйте в общие чаты.

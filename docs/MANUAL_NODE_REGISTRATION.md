# Регистрация node с credentials, выбранными на самой node

Master больше не создаёт `DVR_NODE_ID`, `DVR_NODE_TOKEN` и `DVR_NODE_MEDIA_SECRET`.

Правильный порядок:

1. развернуть node;
2. вручную выбрать UUID, agent token и media secret;
3. сохранить значения на node;
4. создать на master запись с точно такими же значениями;
5. дождаться heartbeat.

## 1. Получение значений с node

После запуска `scripts/deploy-node.sh` на node создаётся root-only файл:

```text
/root/newdomofon-node-master-registration.env
```

Содержимое:

```text
DVR_MASTER_URL=...
DVR_NODE_ID=...
DVR_NODE_TOKEN=...
DVR_NODE_MEDIA_SECRET=...
DVR_NODE_PUBLIC_BASE_URL=...
DVR_NODE_INTERNAL_URL=...
```

Просмотр:

```bash
sudo cat /root/newdomofon-node-master-registration.env
```

## 2. Создание записи на master

Откройте:

```text
Администрирование → Ноды → Создать node
```

Введите все значения из файла регистрации:

- название node;
- `DVR_MASTER_URL`;
- `DVR_NODE_ID`;
- `DVR_NODE_TOKEN`;
- `DVR_NODE_MEDIA_SECRET`;
- `DVR_NODE_PUBLIC_BASE_URL`;
- `DVR_NODE_INTERNAL_URL`;
- признак активности.

Поле `DVR_MASTER_URL` предварительно заполняется адресом открытого master, но остаётся редактируемым. Введённое значение сохраняется в metadata записи node для проверки конфигурации.

## 3. Хранение credentials

Master сохраняет:

- введённый `DVR_NODE_ID` как UUID записи `dvr_servers.id`;
- SHA-256 хеш введённого `DVR_NODE_TOKEN` в `agent_token_hash`;
- введённый `DVR_NODE_MEDIA_SECRET` в `media_secret`;
- введённый `DVR_MASTER_URL` в `capabilities.manual_registration.master_url`.

Исходный agent token не хранится и не может быть восстановлен из master.

## 4. Проверка совпадения

На node:

```bash
set -a
. /etc/newdomofon-video/app.env
set +a

printf 'DVR_MASTER_URL=%s\n' "$DVR_MASTER_URL"
printf 'DVR_NODE_ID=%s\n' "$DVR_NODE_ID"
printf 'DVR_NODE_PUBLIC_BASE_URL=%s\n' "$DVR_NODE_PUBLIC_BASE_URL"
printf 'DVR_NODE_INTERNAL_URL=%s\n' "$DVR_NODE_INTERNAL_URL"
```

Секреты не выводите в общий журнал.

После создания записи на master:

```bash
systemctl restart newdomofon-video-dvr.service
journalctl -u newdomofon-video-dvr.service -f --no-pager
```

Node должна перейти в `online` после следующего успешного heartbeat.

## 5. Ручная смена credentials

Master не генерирует новые credentials при ротации.

1. выберите новый `DVR_NODE_TOKEN` и `DVR_NODE_MEDIA_SECRET`;
2. внесите их в `/etc/newdomofon-video/app.env` на node;
3. в master откройте действие «Задать новые credentials»;
4. введите те же значения;
5. перезапустите DVR-сервис node.

Agent token и media secret должны совпадать посимвольно.

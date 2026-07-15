# Регистрация node с credentials, выбранными на самой node

Master больше не создаёт `DVR_NODE_ID`, `DVR_NODE_TOKEN` и `DVR_NODE_MEDIA_SECRET`.

Правильный порядок:

1. развернуть node;
2. вручную выбрать на node master URL, UUID, agent token, media secret и URLs;
3. сохранить значения в `app.env` node;
4. создать на master запись с точно такими же значениями;
5. дождаться heartbeat.

Master `.env`: [ENVIRONMENT.md](ENVIRONMENT.md).

Node `.env` подробно описан в `newdomofon-video-node/docs/ENVIRONMENT.md`.

## 1. Получите значения с node

После `scripts/deploy-node.sh` на node создаётся root-only файл:

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

Права должны быть:

```text
root:root 0600
```

Просмотр:

```bash
cat /root/newdomofon-node-master-registration.env
```

Не отправляйте файл в общий чат, тикет или незащищённое хранилище.

## 2. Создайте запись на master

Откройте:

```text
Администрирование → Ноды → Создать node
```

Введите:

| Поле | Что вводить |
|---|---|
| Название node | Понятное имя, например `video-node1`. |
| `DVR_MASTER_URL` | Точное значение из node `app.env`. Поле предварительно заполнено текущим origin, но редактируется. |
| `DVR_NODE_ID` | UUID, выбранный при установке node. |
| `DVR_NODE_TOKEN` | Agent token из node. |
| `DVR_NODE_MEDIA_SECRET` | Media secret из node. |
| `DVR_NODE_PUBLIC_BASE_URL` | Публичный/base URL node. |
| `DVR_NODE_INTERNAL_URL` | Private URL DVR engine, обычно `http://IP:3010`. |
| Активна | Включить для приёма heartbeat/config. |

Все значения должны совпадать посимвольно.

## 3. Что сохраняет master

Master сохраняет:

- `DVR_NODE_ID` как UUID `dvr_servers.id`;
- SHA-256 хеш `DVR_NODE_TOKEN` в `agent_token_hash`;
- `DVR_NODE_MEDIA_SECRET` в `media_secret`;
- `DVR_MASTER_URL` в `capabilities.manual_registration.master_url`;
- public/internal URL и название node.

Master не сохраняет исходный agent token и не может восстановить его из хеша.

Master не возвращает и не генерирует replacement credentials.

## 4. Что не нужно добавлять в master `app.env`

Не добавляйте туда:

```text
DVR_NODE_ID
DVR_NODE_TOKEN
DVR_NODE_MEDIA_SECRET
DVR_NODE_PUBLIC_BASE_URL
DVR_NODE_INTERNAL_URL
```

Это параметры конкретной записи node в PostgreSQL, а не глобальная конфигурация master.

Legacy:

```text
NODE_REGISTRATION_TOKEN=
```

оставляется пустым, потому что self-registration не используется.

## 5. Проверка node без вывода secret

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

Проверка наличия secret без вывода:

```bash
for key in DVR_NODE_TOKEN DVR_NODE_MEDIA_SECRET; do
  if grep -qE "^${key}=.+" /etc/newdomofon-video/app.env; then
    echo "$key=SET"
  else
    echo "$key=MISSING"
  fi
done
```

## 6. Проверка heartbeat

На node:

```bash
systemctl restart newdomofon-video-dvr.service
sleep 25

systemctl is-active newdomofon-video-dvr.service
curl -fsS http://127.0.0.1:3010/health | jq
journalctl -u newdomofon-video-dvr.service --since '-5 minutes' --no-pager
```

В master UI должны обновиться:

```text
status=online
last_seen_at
version
storage
capabilities
```

Порог UI:

```text
online   heartbeat моложе 60 секунд
warning  60–180 секунд
offline  старше 180 секунд или отсутствует
```

## 7. Если node не становится online

На node найдите:

```bash
journalctl \
  -u newdomofon-video-dvr.service \
  --since '-10 minutes' \
  --no-pager \
  | grep -Ei 'heartbeat|401|403|404|invalid node|timeout|ECONNREFUSED|ENOTFOUND' \
  || true
```

Причины:

- UUID отличается;
- agent token отличается;
- запись node выключена;
- `DVR_MASTER_URL` неверен;
- DNS/TLS/network недоступны;
- DVR process node не работает.

`DVR_NODE_MEDIA_SECRET` обычно не влияет на heartbeat, но обязан совпадать для media playback.

## 8. Существующая node после обновления master

Не удаляйте и не создавайте её заново. Существующие `id`, `agent_token_hash` и `media_secret` остаются валидными.

Новая форма применяется:

- к следующим node;
- при полном пересоздании записи;
- при ручной смене credentials.

## 9. Ручная смена credentials

Master не генерирует новые credentials при ротации.

Порядок:

1. выберите новый `DVR_NODE_TOKEN`;
2. выберите новый `DVR_NODE_MEDIA_SECRET`;
3. внесите их в `/etc/newdomofon-video/app.env` node;
4. на master откройте «Действия → Задать новые credentials»;
5. введите те же значения;
6. перезапустите DVR node.

```bash
systemctl restart newdomofon-video-dvr.service
```

Чтобы уменьшить разрыв связи, подготовьте обе стороны заранее и выполните изменения последовательно в одной maintenance window.

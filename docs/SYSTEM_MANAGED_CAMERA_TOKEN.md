# Один текущий токен камеры и системный fallback

## Итоговая модель

Каждая камера имеет ровно один текущий managed token.

- Если при создании камеры пользовательский токен не выбран, PostgreSQL автоматически назначает защищённый `Внутренний системный токен`.
- Если пользовательский токен выбран при создании камеры, он заменяет системный и становится единственным текущим токеном.
- Если токен заменён в `Администрирование → Ссылки`, предыдущая привязка удаляется атомарно.
- Если пользовательский токен отвязан или удалён, камера автоматически возвращается на системный токен.
- Системный токен нельзя удалить, отключить, ограничить по scope, сделать временным или ротировать.

Системный token ID:

```text
00000000-0000-4000-8000-000000000001
```

Сам секрет в PostgreSQL не хранится. Публичное значение формируется master из token ID, generation и `MANAGED_CAMERA_TOKEN_SECRET`. Если отдельная переменная отсутствует, backend совместимо использует `JWT_SECRET`.

Managed token никогда не передаётся video node напрямую. Master проверяет токен и назначение камеры, затем выпускает короткоживущий HMAC token конкретной node для live, archive или events.

## Миграция существующей установки

Миграция `093_system_managed_camera_token.sql` выполняется идемпотентно при старте backend:

1. создаёт или восстанавливает системный токен;
2. оставляет одну актуальную привязку на камеру, отдавая приоритет пользовательскому токену;
3. назначает системный токен камерам без привязки;
4. восстанавливает уникальность `camera_id` в таблице назначений;
5. устанавливает триггеры автопривязки, замены, fallback и защиты системного токена.

## Развёртывание на двух серверах

Основной сценарий находится в master repository:

```text
scripts/apply-managed-token-rollout.sh
```

После публикации изменений в `main` сначала обновите node, затем master. На обоих серверах скачайте свежую копию сценария отдельно: он сам сохранит локальные изменения checkout в stash и переключит repository на нужную ветку.

На `video-node1`:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/rirodevdom/newdomofon-video-master/main/scripts/apply-managed-token-rollout.sh \
  -o /root/apply-managed-token-rollout.sh
chmod 700 /root/apply-managed-token-rollout.sh
bash /root/apply-managed-token-rollout.sh node
```

На `video-master`:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/rirodevdom/newdomofon-video-master/main/scripts/apply-managed-token-rollout.sh \
  -o /root/apply-managed-token-rollout.sh
chmod 700 /root/apply-managed-token-rollout.sh
bash /root/apply-managed-token-rollout.sh master
```

Скрипт:

- сохраняет `app.env`, git diff/status и PostgreSQL dump;
- прячет локальные изменения checkout в отдельный git stash;
- обновляет исходники;
- сохраняет совместимость уже выпущенных managed tokens;
- применяет UI-патч выбора токена при создании камеры;
- собирает backend/frontend;
- применяет миграции;
- перезапускает сервисы;
- проверяет health и SQL-инвариант «одна камера — один токен».

Для проверки рабочей ветки до merge скачайте сценарий из ветки и задайте `TARGET_REF`:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/rirodevdom/newdomofon-video-master/agent/system-managed-camera-token/scripts/apply-managed-token-rollout.sh \
  -o /root/apply-managed-token-rollout.sh
chmod 700 /root/apply-managed-token-rollout.sh
TARGET_REF=agent/system-managed-camera-token \
  bash /root/apply-managed-token-rollout.sh master
```

Node repository не содержит логики внешних managed tokens: node принимает только короткоживущий внутренний токен, выпущенный master. Поэтому функциональная правка находится на master, а node-часть rollout выполняет безопасное обновление и health-check совместимой node.

## Проверка инварианта

```sql
SELECT camera_id, count(*) AS token_count
  FROM managed_camera_token_cameras
 GROUP BY camera_id
HAVING count(*) <> 1;
```

Ожидается `0 rows`.

Проверка системного токена:

```sql
SELECT t.id, t.name, t.is_active, t.expires_at, count(a.camera_id) AS assigned_cameras
  FROM managed_camera_tokens t
  LEFT JOIN managed_camera_token_cameras a ON a.token_id = t.id
 WHERE t.id = '00000000-0000-4000-8000-000000000001'::uuid
 GROUP BY t.id, t.name, t.is_active, t.expires_at;
```

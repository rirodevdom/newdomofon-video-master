# Системный fallback и many-to-many токены камер

## Итоговая модель

Связь пользовательских токенов остаётся **many-to-many**:

- к одной камере можно привязать несколько пользовательских токенов;
- один пользовательский токен можно привязать к нескольким камерам;
- добавление нового пользовательского токена не удаляет другие пользовательские токены камеры.

`Внутренний системный токен` используется только как fallback:

- новая камера без выбранного пользовательского токена получает системный fallback;
- если пользовательский токен выбран при создании камеры, после привязки системный fallback удаляется;
- первая последующая пользовательская привязка также удаляет системный fallback;
- дополнительные пользовательские токены добавляются рядом с уже привязанными;
- если удалить последний пользовательский токен камеры, системный fallback возвращается автоматически;
- системный токен нельзя удалить, отключить, ограничить по scope, сделать временным или ротировать.

Системный token ID:

```text
00000000-0000-4000-8000-000000000001
```

Сам секрет в PostgreSQL не хранится. Публичное значение формируется master из token ID, generation и `MANAGED_CAMERA_TOKEN_SECRET`. Если отдельная переменная отсутствует, backend совместимо использует `JWT_SECRET`.

Managed token никогда не передаётся video node напрямую. Master проверяет токен и его связь с камерой, затем выпускает короткоживущий HMAC token конкретной node для live, archive или events.

## Миграция существующей установки

Миграция `093_system_managed_camera_token.sql` выполняется идемпотентно при старте backend:

1. создаёт или восстанавливает системный токен;
2. сохраняет все существующие пользовательские many-to-many связи;
3. удаляет системный fallback у камер, где уже есть хотя бы один пользовательский токен;
4. назначает системный fallback камерам без пользовательских токенов;
5. гарантирует удаление fallback при первой пользовательской привязке;
6. возвращает fallback после удаления последней пользовательской привязки;
7. защищает системный токен от удаления, отключения и ротации.

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
- проверяет health;
- ищет камеры без токена;
- ищет ошибочное одновременное наличие системного и пользовательских токенов.

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

## Проверка инвариантов

Камер без единого токена быть не должно:

```sql
SELECT c.id, c.name, c.stream_name
  FROM cameras c
 WHERE NOT EXISTS (
   SELECT 1 FROM managed_camera_token_cameras a WHERE a.camera_id = c.id
 );
```

Системный fallback не должен находиться рядом с пользовательскими токенами:

```sql
SELECT a.camera_id
  FROM managed_camera_token_cameras a
 GROUP BY a.camera_id
HAVING bool_or(a.token_id = '00000000-0000-4000-8000-000000000001'::uuid)
   AND bool_or(a.token_id <> '00000000-0000-4000-8000-000000000001'::uuid);
```

Оба запроса должны вернуть `0 rows`. При этом несколько пользовательских токенов у одной камеры являются нормальным состоянием.

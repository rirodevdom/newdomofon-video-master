# SmartYard-Vue: события камер NewDomofon

## Почему события не отображаются автоматически

SmartYard-Vue использует два независимых механизма:

1. `address/plogDays` и `address/plog` — журнал доступа SmartYard: звонки, открытия дверей, лица и транспорт.
2. DVR URL камеры — live, архив и экспорт видео.

ONVIF/Hikvision/video-motion события NewDomofon хранятся на назначенной node в локальной SQLite и не являются событиями `plog`. Поэтому стандартный SmartYard-Vue их не запрашивает.

## Новая схема

```text
SmartYard-Vue
  -> https://master/<stream>/events.json?token=...
  -> SmartYard event gateway на master
  -> internal resolver
  -> короткоживущий scope=events token
  -> назначенная node
  -> /cameras/<stream>/events
  -> SQLite/WAL
```

Master не сохраняет event payload и не копирует SQLite.

## Публичные endpoint

### Список событий

```http
GET /<stream>/events.json
    ?token=<permanent-camera-token>
    &from=<unix-seconds-or-ISO>
    &to=<unix-seconds-or-ISO>
    &type=motion
    &limit=1000
```

Ответ:

```json
{
  "stream": "OnvifP",
  "start": "2026-07-10T18:00:00.000Z",
  "end": "2026-07-10T19:00:00.000Z",
  "count": 12,
  "raw_count": 48,
  "items": [
    {
      "id": "...",
      "camera_id": "...",
      "stream_name": "OnvifP",
      "event_type": "motion",
      "event_state": "true",
      "occurred_at": "2026-07-10T18:40:10.000Z",
      "timestamp": 1783708810000,
      "topic": "tns1:VideoSource/MotionAlarm",
      "source_name": "V_SRC_000",
      "data": {}
    }
  ]
}
```

По умолчанию gateway возвращает только активирующие переходы и подавляет эквивалентные motion topics в небольшом окне. Для отладки всех состояний добавьте:

```text
include_inactive=1
```

### Сводка по минутам

```http
GET /<stream>/events_summary.json
    ?token=<permanent-camera-token>
    &from=<unix-seconds-or-ISO>
    &to=<unix-seconds-or-ISO>
```

## Установка gateway на master

После слияния изменения:

```bash
cd /opt/newdomofon-video-master

git fetch origin main
git switch main
git pull --ff-only origin main

cd backend
npm ci --include=dev
npm run build
npm prune --omit=dev

sudo install -m 0644 \
  /opt/newdomofon-video-master/deploy/systemd/newdomofon-smartyard-compat.service \
  /etc/systemd/system/newdomofon-smartyard-compat.service

sudo systemctl daemon-reload
sudo systemctl restart newdomofon-video-backend.service
sudo systemctl restart newdomofon-smartyard-compat.service
```

Проверка портов:

```bash
ss -ltnp | grep -E ':(3000|3082|3083|3084)([[:space:]]|$)'
```

Назначение:

- `3000` — backend master;
- `3082` — public media + event gateway;
- `3083` — legacy compatibility fallback;
- `3084` — internal node-aware media gateway.

## Проверка event endpoint

```bash
cd /opt/newdomofon-video-master
read -rsp 'SmartYard camera URL: ' SMARTYARD_URL
echo
SMARTYARD_URL="$SMARTYARD_URL" HOURS=24 \
  bash scripts/diagnose-smartyard-events.sh
```

Ожидается:

```text
EVENTS_HTTP=200
SUMMARY_HTTP=200
SMARTYARD CAMERA EVENTS VERIFIED
```

## Патч SmartYard-Vue

Скрипт:

- создаёт backup `VideoModal.vue`;
- устанавливает `CameraMotionEvents.vue`;
- добавляет блок событий в боковую панель видеомодалки;
- при выборе события открывает архив от `event - 10 секунд` длительностью 30 секунд;
- повторный запуск безопасен.

```bash
cd /opt/newdomofon-video-master

SMARTYARD_VUE_DIR=/path/to/SmartYard-Vue \
  bash scripts/patch-smartyard-vue-camera-events.sh
```

Сборка отдельной командой:

```bash
cd /path/to/SmartYard-Vue
npm ci --include=dev
npm run build
```

Или сразу со сборкой:

```bash
SMARTYARD_VUE_DIR=/path/to/SmartYard-Vue \
SMARTYARD_VUE_BUILD=1 \
  bash /opt/newdomofon-video-master/scripts/patch-smartyard-vue-camera-events.sh
```

## Rollback SmartYard-Vue

Путь backup выводится скриптом. Для отката:

```bash
cp -a \
  /path/to/SmartYard-Vue/.newdomofon-backups/camera-events-<timestamp>/VideoModal.vue.before \
  /path/to/SmartYard-Vue/src/components/VideoModal.vue

rm -f /path/to/SmartYard-Vue/src/components/CameraMotionEvents.vue
```

Затем пересоберите SmartYard-Vue.

## Безопасность

- permanent camera token остаётся только во внешнем URL;
- master проверяет его по актуальному `media_secret` назначенной node;
- node получает отдельный короткоживущий token со scope `events`;
- `media_secret` в браузер и SmartYard-Server не передаётся;
- полные token нельзя публиковать в логах, issue или чатах.

# Границы репозиториев NewDomofon Video

## Текущие проекты

- `newdomofon-video-master` — control plane, PostgreSQL, RBAC, устройства, камеры, node registry, managed tokens и внешние gateways;
- `newdomofon-video-node` — универсальная RTSP/ONVIF data plane: FFmpeg recording, live, локальный архив, ranges, export и события;
- будущий отдельный репозиторий Hikvision-node — единственное место для Hikvision ISAPI и vendor-specific операций.

Проекты не импортируют исходный код друг друга. Связь выполняется только через версионируемые HTTP-контракты.

## Master

Master владеет:

- пользователями, ролями и доступом к камерам;
- устройствами и камерами как объектами управления;
- реестром node и их состоянием;
- назначением устройств и камер обычным video node;
- managed tokens;
- media/events/preview gateways;
- веб-интерфейсом и аудитом.

Master не должен:

- запускать FFmpeg recorder;
- обращаться к vendor-specific API камер/NVR;
- выполнять поиск каналов или записей на устройстве;
- хранить логические сессии vendor archive playback;
- читать файловую систему node.

## Универсальная video node

Обычная video node владеет:

- FFmpeg-процессами и перезапуском рекордеров;
- RTSP source consumption;
- ONVIF discovery/profile lookup/PullPoint events;
- локальным архивом и retention;
- live/archive/ranges/export HTTP API;
- локальной SQLite событий;
- диагностикой дисков, потоков и камер.

Обычная video node не содержит Hikvision ISAPI, `alertStream`, ContentMgmt search, vendor-specific channel discovery или playback архива устройства.

## Будущая Hikvision-node

Отдельная Hikvision-node будет владеть:

- учётными данными и соединениями с Hikvision ISAPI;
- discovery каналов/треков;
- `alertStream` и vendor-specific событиями;
- поиском записей на NVR;
- подготовкой и обслуживанием временных playback-сессий архива устройства;
- нормализацией vendor-specific ответов в отдельный контракт master.

Она не должна встраиваться обратно в generic video node. Master должен видеть её как отдельный тип сервиса/node с отдельными capabilities и API contract.

## Контракты

Текущий generic node-agent API остаётся `/api/node-agent/...` и передаёт только данные, необходимые RTSP/ONVIF DVR-node. Vendor credentials и параметры архива устройства в generic контракт не входят.

Для Hikvision-node нужен новый major contract, например:

```text
/api/hikvision-node/v1/heartbeat
/api/hikvision-node/v1/config
/api/hikvision-node/v1/events
/api/hikvision-node/v1/archive/ranges
/api/hikvision-node/v1/archive/session
```

Названия приведены как архитектурная заготовка; окончательный контракт проектируется в будущем репозитории до реализации runtime.

## Порядок обновления существующих серверов

1. Обновить все обычные video node до версии без Hikvision runtime.
2. Убедиться, что RTSP recorders, live, локальный архив, ranges, export и ONVIF events работают.
3. Обновить master.
4. Миграция master переводит прежние устройства типа `HIKVISION` в `RTSP`, сохраняя камеры и `source_url`.
5. Миграция принудительно оставляет архив `node` и удаляет только производные таблицы ISAPI-индекса.
6. До появления отдельной Hikvision-node функции поиска каналов, vendor events и архива устройства недоступны.

## Правила дальнейшей разработки

- Изменения master не требуют release generic node, пока не меняется контракт.
- Изменения generic node не требуют release master, пока контракт совместим.
- Hikvision-specific код принимается только в будущем специализированном репозитории.
- Новый контракт сначала фиксируется документально, затем поддерживается master, после чего реализуется соответствующей node.
- Секреты и runtime-данные никогда не переносятся через Git.

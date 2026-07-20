# SmartYard-Vue и NewDomofon: работа только с нашей стороны

Поддерживаемая интеграция не требует и не допускает изменений на сторонних серверах:

- RBT/SmartYard-Server не изменяется;
- оригинальный `rosteleset/SmartYard-Vue` не изменяется и не пересобирается;
- на тестовой странице разрешена только замена штатного видеоплеера нашим плеером;
- все media-функции реализуются NewDomofon master/node.

## Контракт NewDomofon media

Master предоставляет Flussonic-совместимые URL:

```text
/<stream>/preview.mp4?token=...
/<stream>/<unix>-preview.mp4?token=...
/<stream>/snapshot.jpg?token=...
/<stream>/index.m3u8?token=...
/<stream>/index.fmp4.m3u8?token=...
/<stream>/index-<from>-<duration>.m3u8?token=...
/<stream>/index-<from>-<duration>.fmp4.m3u8?token=...
/<stream>/recording_status.json?token=...
/<stream>/archive-<from>-<duration>.mp4?token=...
```

`preview.mp4` формируется как неподвижный одно-кадровый MP4 без аудиодорожки. Это позволяет неизменённому autoplay preview-элементу показывать миниатюру без движения и звука.

Master добавляет canonical CORS и Private Network Access для `OPTIONS` и `GET/HEAD`. Node обслуживает live, snapshot, архивное воспроизведение и MP4-экспорт.

## Тестовая страница с нашим плеером

Наш плеер должен работать напрямую с NewDomofon и не вызывать API RBT для media-функций:

1. Миниатюра: `preview.mp4` или `snapshot.jpg`.
2. Live: `index.m3u8` либо `index.fmp4.m3u8`.
3. Диапазоны архива: `recording_status.json`.
4. Воспроизведение архива: `index-<from>-<duration>.m3u8`.
5. Скачивание: `archive-<from>-<duration>.mp4`.

В тестовом SmartYard-Vue заменяется только реализация плеера. Остальные компоненты, store, API-клиент и структура страницы не патчатся.

## Оригинальный SmartYard-Vue

Preview и live оригинального интерфейса могут работать напрямую через URL камеры NewDomofon, потому что эти запросы направляются на media origin.

Однако при наличии `camera.serverType` оригинальный frontend получает архив и готовит скачивание через API своего SmartYard-Server:

```text
/mobile/cctv/ranges
/mobile/cctv/recPrepare
/mobile/cctv/recDownload
```

Эти запросы уходят на origin RBT, а не на NewDomofon. Наш master/node не могут перехватить, изменить, перенаправить или добавить CORS к ответу другого origin.

Следовательно, без изменений оригинального SmartYard-Vue и без изменений RBT:

- preview и live исправляются с нашей стороны;
- полный архив и скачивание обеспечиваются в нашей тестовой странице через заменённый плеер;
- ошибку `/mobile/cctv/ranges` в оригинальном интерфейсе невозможно исправить только NewDomofon-серверами.

Это жёсткая граница браузерного origin и контракта приложения, а не отсутствующий endpoint NewDomofon.

## Запрещённый сценарий

В репозитории не должно быть установщиков или patcher-скриптов, которые изменяют:

- `/opt/rbt/server/smartyard.py`;
- любой другой SmartYard-Server;
- исходники оригинального SmartYard-Vue;
- собранные assets стороннего SmartYard-Vue.

Подробная фиксация границы находится в `docs/SMARTYARD_OWN_SIDE_ONLY.md`.

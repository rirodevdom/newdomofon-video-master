# Видимая ссылка на подготовленное видео SmartYard

Патч поддерживает оба интерфейса:

1. оригинальный `rosteleset/SmartYard-Vue`, где скачивание запускается из `CustomControls.vue`;
2. интегрированную сборку с NewDomofon Player Kit, где скачивание запускается из `smartyardPlayerKit.ts`.

## Что исправляется

SmartYard-Server может вернуть идентификатор через `/cctv/recPrepare`, а `/cctv/recDownload` некоторое время отвечать `204 No Content`. Старый frontend проверял `recDownload` только один раз. Поэтому готовая позднее ссылка никогда не появлялась в текущем интерфейсе.

После патча frontend:

- показывает постоянную панель «Подготовка видео»;
- опрашивает `/cctv/recDownload` каждые две секунды;
- считает `204`, пустой ответ и временные статусы состоянием подготовки;
- ждёт ссылку до 15 минут;
- показывает постоянную кнопку-ссылку «Скачать подготовленное видео»;
- показывает понятную ошибку, если подготовка не завершилась;
- не содержит production-домена и нормализует относительную ссылку относительно текущего SmartYard origin.

## Применение к исходникам SmartYard-Vue

Сценарий запускается из распакованного репозитория `newdomofon-video-master`:

```bash
python3 scripts/patch-smartyard-download-ready-link.py \
  --project-dir /path/to/SmartYard-Vue
```

Он автоматически определяет присутствующие варианты:

```text
src/components/CustomControls.vue
src/lib/smartyardPlayerKit.ts
```

Если в кастомной сборке присутствуют оба файла, будут исправлены оба.

Перед изменением создаётся backup:

```text
<SmartYard-Vue>/.newdomofon-backups/smartyard-download-ready-link-<UTC timestamp>/
```

После применения:

```bash
cd /path/to/SmartYard-Vue
npm ci
npm run build
```

Затем публикуется штатный каталог `dist` этой установки SmartYard-Vue.

## Изменяемые файлы

Оригинальная сборка:

```text
src/components/CustomControls.vue
src/lib/smartYardRecordingDownload.ts
```

Интегрированная сборка:

```text
src/lib/smartyardPlayerKit.ts
src/lib/smartYardRecordingDownload.ts
```

## Граница ответственности

Патч изменяет только исходники frontend, который владелец установки собирает и публикует самостоятельно. Он не изменяет SmartYard-Server, не подменяет его API и не вносит runtime-инъекции в уже собранные сторонние assets.

Ссылка появится только после успешного формирования MP4 на media node. Node должен использовать канонический `export.mp4`, который ищет сегменты через общий archive storage API и возвращает `Content-Disposition: attachment`.

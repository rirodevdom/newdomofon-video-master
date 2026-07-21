# SmartYard-Vue и NewDomofon: доменно-независимая интеграция

Поддерживаемая интеграция не должна содержать имя конкретного production-домена или IP-адреса:

- public URL master задаётся при установке или в `/etc/newdomofon-video/app.env`;
- SmartYard-Server получает полный HTTPS URL камеры из ответа NewDomofon или из своей конфигурации;
- заменяемый тестовый плеер работает с hostname, полученным из `camera.url`;
- все media-функции реализуются NewDomofon master/node.

## Единственный источник public URL

На master канонический origin задаётся переменными:

```env
APP_PUBLIC_URL=https://video.example.com
SMARTYARD_PUBLIC_BASE_URL=https://video.example.com
CORS_ORIGIN=https://video.example.com
```

Имена выше являются примером. При развёртывании используется реальный домен или адрес установки.

Backend формирует ссылки из этих переменных. Если они отсутствуют, он использует корректные `X-Forwarded-Proto` и `X-Forwarded-Host` текущего запроса. В коде не должно быть fallback на домен конкретной инсталляции.

Для уже установленного master public origin можно исправить без указания домена в команде: сценарий прочитает его из production env.

```bash
sudo bash scripts/repair-public-https-origin.sh
```

Явное переопределение для другой установки:

```bash
sudo bash scripts/repair-public-https-origin.sh \
  --public-url https://video.customer.example \
  --probe-address 192.0.2.10
```

Сценарий:

- обновляет `APP_PUBLIC_URL`, `SMARTYARD_PUBLIC_BASE_URL` и `CORS_ORIGIN`;
- выбирает TLS-vhost по hostname, а при единственном TLS-vhost может добавить hostname в `server_name`;
- добавляет HSTS к корневому HTTPS-ответу и media/event locations;
- создаёт backup и откатывает изменения при неуспешной проверке;
- проверяет HTTPS CORS и HSTS после перезапуска сервисов.

## Контракт NewDomofon media

Master предоставляет Flussonic-совместимые относительные пути:

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

`preview.mp4` формируется как неподвижный одно-кадровый MP4 без аудиодорожки. Master добавляет canonical CORS и Private Network Access для `OPTIONS` и `GET/HEAD`. Node обслуживает live, snapshot, архивное воспроизведение и MP4-экспорт.

## Требование HTTPS для SmartYard

Если SmartYard загружен по HTTPS, значение `camera.url`, принимаемое SmartYard-Server и браузером, также обязано начинаться с HTTPS:

```text
https://<PUBLIC_MASTER_HOST>/<stream>/?token=...
```

HTTP URL нельзя исправить серверным redirect после запуска HLS.js: браузер может заблокировать playlist как active mixed content до обращения к серверу.

Поэтому SmartYard-Server должен сохранять и отдавать именно ссылку, полученную из `SMARTYARD_PUBLIC_BASE_URL`, а не самостоятельно подменять схему или hostname.

## Доменная независимость заменяемого плеера

Плеер не должен сравнивать hostname с конкретной строкой. Нормализация определяется схемой страницы и полученного media URL:

```ts
export function normalizeMediaUrl(rawUrl: string, pageUrl = window.location.href): string {
  const media = new URL(rawUrl, pageUrl)
  const page = new URL(pageUrl)

  if (page.protocol === 'https:' && media.protocol === 'http:') {
    media.protocol = 'https:'
    if (media.port === '80') media.port = ''
  }

  return media.toString()
}
```

Одна нормализованная копия `camera.url` должна использоваться для всех функций:

1. Миниатюра: `preview.mp4` или `snapshot.jpg`.
2. Live: `index.m3u8` либо `index.fmp4.m3u8`.
3. Диапазоны архива: `recording_status.json`.
4. Воспроизведение архива: `index-<from>-<duration>.m3u8`.
5. События: `events.json` и `/public-events/...`.
6. Скачивание: `archive-<from>-<duration>.mp4`.

Такое правило работает с любым hostname и не содержит знания о домене владельца установки.

## Оригинальный SmartYard-Vue

Preview, live и Flussonic-совместимый архив оригинального интерфейса работают, когда SmartYard-Server передаёт браузеру корректный HTTPS URL камеры.

При наличии отдельного `camera.serverType` некоторые сборки оригинального frontend могут получать архив и готовить скачивание через API своего SmartYard-Server:

```text
/mobile/cctv/ranges
/mobile/cctv/recPrepare
/mobile/cctv/recDownload
```

Эти маршруты принадлежат SmartYard-Server. NewDomofon не должен содержать жёстких ссылок на их hostname и не может добавлять CORS к ответу другого origin.

Исторические реализации SmartYard-Server при `recPrepare` добавляют к camera token префикс `100`, хотя live и архивное воспроизведение используют исходный токен. Внутренний resolver NewDomofon сначала проверяет токен без изменений и только после неуспеха пробует вариант без этого точного префикса. Поэтому прямые ссылки заменяемого плеера и обычные camera tokens не меняются, а подготовка MP4 оригинальным SmartYard-Server остаётся совместимой.

После успешного `recDownload` оригинальный SmartYard-Vue должен самостоятельно открыть полученный URL либо получить предусмотренное его установкой уведомление `videoReady`. NewDomofon отвечает за формирование и выдачу MP4, но не может создать push-событие или изменить обработку ответа на стороннем SmartYard origin.

## Запрещённый сценарий

В репозитории не должно быть установщиков или patcher-скриптов, которые:

- содержат production-домен или адрес конкретной инсталляции как fallback;
- изменяют сторонний SmartYard-Server;
- изменяют исходники оригинального SmartYard-Vue;
- изменяют собранные assets стороннего SmartYard-Vue.

Подробная фиксация границы находится в `docs/SMARTYARD_OWN_SIDE_ONLY.md`.

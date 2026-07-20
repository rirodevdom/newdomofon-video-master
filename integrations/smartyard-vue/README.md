# SmartYard-Vue и NewDomofon: совместимость без изменения frontend

Оригинальный `rosteleset/SmartYard-Vue` и локальная сборка с интегрированным плеером должны работать без патчей, пересборки и изменения исходников frontend.

## Поддерживаемый контракт

NewDomofon master предоставляет стандартные Flussonic-совместимые URL:

```text
/<stream>/preview.mp4?token=...
/<stream>/<unix>-preview.mp4?token=...
/<stream>/index.m3u8?token=...
/<stream>/index.fmp4.m3u8?token=...
/<stream>/index-<from>-<duration>.m3u8?token=...
/<stream>/index-<from>-<duration>.fmp4.m3u8?token=...
/<stream>/recording_status.json?token=...
/<stream>/archive-<from>-<duration>.mp4?token=...
```

`preview.mp4` формируется как неподвижный одно-кадровый MP4 без аудиодорожки. Это предотвращает воспроизведение короткого видео со звуком в штатном autoplay preview-элементе SmartYard-Vue.

Master добавляет единый набор CORS и Private Network Access заголовков для OPTIONS и GET/HEAD. Изменять Nginx или JavaScript SmartYard-Vue для live не требуется.

## Почему нужен серверный адаптер RBT

Оригинальный SmartYard-Vue получает архивные диапазоны и готовит скачивание через API SmartYard-Server:

```text
/mobile/cctv/ranges
/mobile/cctv/recPrepare
/mobile/cctv/recDownload
```

Поэтому compatibility layer устанавливается в AXIOSTV SmartYard-Server на RBT-сервере. Он:

- сохраняет штатную авторизацию пользователя;
- добавляет CORS даже для ответов 4xx;
- выдаёт managed token для камер NewDomofon в стандартных ответах camera API;
- получает диапазоны через `recording_status.json`;
- готовит MP4 через `archive-<from>-<duration>.mp4`;
- не меняет поведение остальных Flussonic-камер;
- не изменяет SmartYard-Vue.

## Установка на RBT-сервере

Передайте на RBT-сервер распакованный архив `newdomofon-video-master` и выполните:

```bash
cd /root/newdomofon-video-master-main

bash scripts/install-smartyard-server-newdomofon-compat.sh \
  --rbt-dir /opt/rbt/server \
  --dry-run

sudo bash scripts/install-smartyard-server-newdomofon-compat.sh \
  --rbt-dir /opt/rbt/server \
  --service <RBT_SYSTEMD_UNIT>
```

Git и доступ к репозиторию на сервере не используются.

Installer создаёт backup в:

```text
/var/backups/newdomofon-video/smartyard-server/<timestamp>/
```

и устанавливает рядом со `smartyard.py` модуль:

```text
newdomofon_media_compat.py
```

## Managed token

Если текущий `Users.videotoken` уже содержит `m1.*` или `mct1.*`, дополнительная настройка не нужна.

Иначе создайте root-only mapping:

```text
/etc/newdomofon-video/smartyard-camera-tokens.json
```

Пример находится в:

```text
integrations/smartyard-server/smartyard-camera-tokens.example.json
```

Поддерживается привязка по `camera_id`, имени stream или полному URL. Файл должен иметь права `0600` и не должен попадать в логи или архив исходников.

## Проверка

После перезапуска RBT:

1. Оригинальный SmartYard-Vue должен получать HTTP 200 от `/mobile/cctv/ranges`.
2. Live должен запрашиваться через `/<stream>/index.m3u8` или `index.fmp4.m3u8`.
3. Preview должен оставаться неподвижным и без звука.
4. После выбора архивного диапазона должна появляться штатная кнопка скачивания.
5. `/mobile/cctv/recPrepare` должен вернуть record ID, а `/mobile/cctv/recDownload` — URL готового файла.

Ни исходники, ни собранные assets SmartYard-Vue в этом сценарии не меняются.

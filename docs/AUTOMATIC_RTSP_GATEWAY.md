# Automatic RTSP gateway

NewDomofon Video публикует назначенные камеры через единый RTSP endpoint master. MediaMTX запускает relay только при подключении клиента.

Полный справочник `.env`: [ENVIRONMENT.md](ENVIRONMENT.md#5-rtsp-gateway--mediamtx).

## Архитектура

```text
RTSP client
  → rtsp://token:<managed-token>@master:8554/<stream>
  → MediaMTX на master
  → HTTP auth в backend
  → проверка managed token и camera assignment
  → runOnDemand запускает FFmpeg relay
  → backend определяет назначенную video node
  → node отдаёт authenticated MPEG-TS
  → FFmpeg публикует stream в MediaMTX
  → MediaMTX обслуживает RTSP reader
```

Relay останавливается после отключения последнего reader. Camera/NVR не получает дополнительное постоянное соединение от master: source берётся с назначенной node.

## Authentication

Внешний RTSP URL использует managed camera token как password:

```text
rtsp://token:m1.EXAMPLE@video.example.com:8554/entrance_main
```

MediaMTX вызывает loopback endpoint:

```text
POST http://127.0.0.1:3000/api/internal/rtsp/auth
```

Backend разрешает read только если:

- managed token валиден, активен и не истёк;
- token имеет scope `camera`;
- token назначен requested camera;
- camera и её node включены;
- запрос пришёл от локального MediaMTX;
- указан правильный `RTSP_GATEWAY_SHARED_SECRET`.

Local FFmpeg publisher использует отдельный `RTSP_RELAY_PUBLISH_SECRET` и разрешён только с loopback.

## Переменные `.env`

```env
# Включён ли gateway.
RTSP_GATEWAY_ENABLED=true

# DNS/IP, который выдаётся клиентам.
RTSP_PUBLIC_HOST=video.example.com

# Public/listen TCP port. Ports ниже 1024 не поддерживаются service user.
RTSP_PUBLIC_PORT=8554

# Шаблон внешней ссылки. Обычно создаётся installer автоматически.
RTSP_PUBLIC_URL_TEMPLATE=rtsp://token:{token}@video.example.com:8554/{stream}

# Internal backend ↔ MediaMTX secret. Генерируется installer.
RTSP_GATEWAY_SHARED_SECRET=...

# Internal local FFmpeg publisher secret. Генерируется installer.
RTSP_RELAY_PUBLISH_SECRET=...

# Автоматически открыть port в UFW/firewalld, если firewall уже активен.
RTSP_AUTO_OPEN_FIREWALL=true

# Зафиксированная MediaMTX version; пусто — определить поддерживаемую версию.
RTSP_MEDIAMTX_VERSION=
```

Не публикуйте два internal secret.

## Автоматическая установка

Обычный master deploy:

```bash
cd /opt/newdomofon-video-master

PROJECT_DIR=/opt/newdomofon-video-master \
ENV_FILE=/etc/newdomofon-video/app.env \
INSTALL_RTSP_GATEWAY=1 \
  bash scripts/deploy-master.sh
```

На существующем master:

```bash
cd /opt/newdomofon-video-master

PROJECT_DIR="$PWD" \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/install-rtsp-gateway.sh
```

Installer:

1. определяет public host из `SMARTYARD_PUBLIC_BASE_URL`, `APP_PUBLIC_URL`, `PUBLIC_BACKEND_BASE_URL` или `CORS_ORIGIN`;
2. генерирует два internal secret, если они отсутствуют;
3. создаёт `RTSP_PUBLIC_URL_TEMPLATE`;
4. определяет/использует pinned MediaMTX version;
5. скачивает package и проверяет checksum;
6. устанавливает binary, config, relay helper и systemd unit;
7. перезапускает backend и gateway;
8. открывает TCP port в поддерживаемом активном firewall.

Сгенерированные значения сохраняются в `/etc/newdomofon-video/app.env` с ограниченными правами и не возвращаются public API.

## Изменение public port

Не добавляйте вторую строку через `>>`. Обновите существующую строку безопасно:

```bash
python3 - <<'PY'
from pathlib import Path

path = Path('/etc/newdomofon-video/app.env')
key = 'RTSP_PUBLIC_PORT'
value = '18554'
lines = path.read_text(encoding='utf-8').splitlines()
out = []
written = False
for line in lines:
    if line.startswith(key + '='):
        if not written:
            out.append(f'{key}={value}')
            written = True
    else:
        out.append(line)
if not written:
    out.append(f'{key}={value}')
path.write_text('\n'.join(out) + '\n', encoding='utf-8')
PY

PROJECT_DIR=/opt/newdomofon-video-master \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash /opt/newdomofon-video-master/scripts/install-rtsp-gateway.sh
```

Во внешнем firewall/NAT также откройте новый TCP port.

## Порты

```text
8554/tcp  public RTSP over TCP
9997/tcp  MediaMTX API, только 127.0.0.1
```

Используется TCP transport; отдельный RTP/RTCP UDP range не требуется.

## Проверка

```bash
systemctl status newdomofon-video-rtsp-gateway.service --no-pager -l
ss -lntp | grep ':8554'
curl -fsS http://127.0.0.1:9997/v3/config/global/get | jq
```

В UI:

```text
Администрирование → Ссылки → камера → managed token
```

RTSP должен отображаться доступным без ручного заполнения template.

Проверка FFprobe без сохранения URL в shell history:

```bash
read -rsp 'RTSP URL: ' RTSP_URL
echo

timeout 20 ffprobe \
  -v error \
  -rtsp_transport tcp \
  -show_entries stream=index,codec_type,codec_name,width,height \
  -of json \
  "$RTSP_URL" | jq

unset RTSP_URL
```

## Логи

Master RTSP gateway:

```bash
journalctl -u newdomofon-video-rtsp-gateway.service --since '-15 minutes' --no-pager
```

Backend auth/source resolver:

```bash
journalctl -u newdomofon-video-backend.service --since '-15 minutes' --no-pager \
  | grep -Ei 'internal/rtsp|rtsp-relay|error'
```

Assigned node relay source:

```bash
journalctl -u newdomofon-video-dvr.service --since '-15 minutes' --no-pager \
  | grep -Ei 'rtsp-relay|live-ts|error'
```

## Порядок обновления

Сначала обновляйте все video node и проверяйте endpoint relay, затем master/MediaMTX.

## Безопасность

Plain RTSP не шифрует credentials или media. Ограничивайте public port VPN/allowlist. Rotation, disabling, expiry и unassignment применяются при следующем RTSP connection; уже установленная session может продолжать работать до disconnect.
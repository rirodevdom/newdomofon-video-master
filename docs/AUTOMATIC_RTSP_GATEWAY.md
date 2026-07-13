# Automatic RTSP gateway

NewDomofon Video can publish every assigned camera through a single RTSP endpoint on the master without manually writing `RTSP_PUBLIC_URL_TEMPLATE` and without opening a second RTSP connection to the camera.

## Architecture

```text
RTSP client
  -> rtsp://token:<managed-token>@master.example.com:8554/<stream>
  -> MediaMTX on master
  -> HTTP auth request to master backend
  -> managed-token + camera assignment validation
  -> runOnDemand starts FFmpeg only for the requested stream
  -> backend resolves the camera's currently assigned video node
  -> video node returns one continuous authenticated MPEG-TS response
  -> FFmpeg republishes the stream into MediaMTX
  -> MediaMTX serves RTSP readers
```

The relay is on demand. When the last RTSP reader disconnects, MediaMTX terminates FFmpeg after the configured close delay. The original camera/NVR is still opened only by the recorder on its assigned video node.

## Authentication

A generated link embeds the existing managed camera token as the RTSP password:

```text
rtsp://token:m1.EXAMPLE@video.example.com:8554/CameraStream
```

MediaMTX delegates every RTSP `read` request to:

```text
POST http://127.0.0.1:3000/api/internal/rtsp/auth
```

The backend accepts access only when all conditions are true:

- the compact or legacy managed token signature is valid;
- the token is active and not expired;
- the token has the `camera` scope;
- the token is assigned to the requested camera;
- the camera and its inherited video node are enabled;
- the call originates from the local MediaMTX process and contains the generated gateway secret.

Local FFmpeg publishing is authenticated independently with another generated secret and is allowed only from loopback.

## Automatic installation

The regular master deploy installs the gateway by default:

```bash
PROJECT_DIR=/opt/newdomofon-video-master \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/deploy-master.sh
```

For an existing production master:

```bash
cd /opt/newdomofon-video-master

PROJECT_DIR="$PWD" \
ENV_FILE=/etc/newdomofon-video/app.env \
  bash scripts/install-rtsp-gateway.sh
```

The installer performs these actions:

1. derives the public master hostname from `SMARTYARD_PUBLIC_BASE_URL`, `APP_PUBLIC_URL`, `PUBLIC_BACKEND_BASE_URL`, or `CORS_ORIGIN`;
2. generates `RTSP_GATEWAY_SHARED_SECRET` and `RTSP_RELAY_PUBLISH_SECRET`;
3. creates `RTSP_PUBLIC_URL_TEMPLATE` automatically;
4. resolves the latest MediaMTX release, unless `RTSP_MEDIAMTX_VERSION` is already pinned;
5. downloads the correct Linux architecture archive and verifies SHA256;
6. installs `/usr/local/bin/mediamtx`;
7. installs the on-demand relay helper and systemd unit;
8. renders `/etc/newdomofon-video/mediamtx.yml`;
9. restarts backend and enables `newdomofon-video-rtsp-gateway.service`;
10. opens the configured TCP port when active UFW or firewalld is detected.

Generated settings are stored in `/etc/newdomofon-video/app.env` with mode `0640` and are never returned by the public API.

## Ports

```text
8554/tcp  public RTSP over TCP
9997/tcp  MediaMTX API, bound to 127.0.0.1 only
```

Only TCP transport is enabled. RTP/RTCP UDP port ranges are not required.

Change the public/listen port before installation when needed:

```bash
printf '%s\n' 'RTSP_PUBLIC_PORT=18554' >> /etc/newdomofon-video/app.env
```

The service runs as `newdomofon`, therefore ports below 1024 are intentionally rejected.

## Verification

```bash
systemctl status newdomofon-video-rtsp-gateway.service --no-pager -l
ss -lntp | grep ':8554'
curl -fsS http://127.0.0.1:9997/v3/config/global/get | jq .
```

Open `Administration -> Links`, select a camera and one of its assigned managed tokens. RTSP must be marked available and generated without any manual template.

Test with FFprobe:

```bash
read -rsp 'RTSP URL: ' RTSP_URL
echo

timeout 20 ffprobe \
  -v error \
  -rtsp_transport tcp \
  -show_entries stream=index,codec_type,codec_name,width,height \
  -of json \
  "$RTSP_URL" | jq .
```

Expected video codec is normally H.264 or H.265, depending on the source camera.

## Logs

Master RTSP gateway:

```bash
journalctl -u newdomofon-video-rtsp-gateway.service --since '15 minutes ago' --no-pager
```

Master backend auth/source resolver:

```bash
journalctl -u newdomofon-video-backend.service --since '15 minutes ago' --no-pager \
  | grep -Ei 'internal/rtsp|rtsp-relay|error'
```

Assigned video node relay source:

```bash
journalctl -u newdomofon-video-dvr.service --since '15 minutes ago' --no-pager \
  | grep -Ei 'rtsp-relay|live-ts|error'
```

## Security note

Plain RTSP does not encrypt credentials or media. Restrict port 8554 to trusted networks/VPN when traffic crosses an untrusted network. Token rotation, disabling, expiry, and camera-token unassignment are enforced on the next RTSP connection. Existing established sessions can continue until disconnected because authentication occurs when the RTSP session is created.

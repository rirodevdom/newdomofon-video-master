#!/usr/bin/env bash
set -Eeuo pipefail

STREAM_NAME="${MTX_PATH:-}"
BACKEND_URL="${RTSP_GATEWAY_BACKEND_URL:-http://127.0.0.1:3000}"
GATEWAY_SECRET="${RTSP_GATEWAY_SHARED_SECRET:-}"
PUBLISH_SECRET="${RTSP_RELAY_PUBLISH_SECRET:-}"
RTSP_PORT_VALUE="${RTSP_PUBLIC_PORT:-${RTSP_PORT:-8554}}"
FFMPEG_BIN="${FFMPEG_PATH:-/usr/bin/ffmpeg}"

if [[ ! "$STREAM_NAME" =~ ^[A-Za-z0-9_.-]{1,255}$ ]]; then
  echo "[rtsp-relay] invalid MTX_PATH" >&2
  exit 64
fi

if [[ -z "$GATEWAY_SECRET" || -z "$PUBLISH_SECRET" ]]; then
  echo "[rtsp-relay:$STREAM_NAME] RTSP gateway secrets are not configured" >&2
  exit 78
fi

if [[ ! "$RTSP_PORT_VALUE" =~ ^[0-9]+$ ]] || (( RTSP_PORT_VALUE < 1024 || RTSP_PORT_VALUE > 65535 )); then
  echo "[rtsp-relay:$STREAM_NAME] invalid RTSP port: $RTSP_PORT_VALUE" >&2
  exit 78
fi

if [[ ! -x "$FFMPEG_BIN" ]]; then
  echo "[rtsp-relay:$STREAM_NAME] ffmpeg not found: $FFMPEG_BIN" >&2
  exit 69
fi

payload="$(jq -nc --arg stream "$STREAM_NAME" '{stream_name:$stream}')"
response="$(
  curl -fsS --max-time 10 \
    -H 'content-type: application/json' \
    --data "$payload" \
    "${BACKEND_URL%/}/api/internal/rtsp/source?gateway_secret=${GATEWAY_SECRET}"
)"

source_url="$(jq -er '.source_url | select(type == "string" and length > 0)' <<<"$response")"

# The source is a single continuous MPEG-TS response from the assigned node.
# Its short-lived token is checked only when this connection is established.
# MediaMTX terminates this process when the last RTSP reader leaves.
exec "$FFMPEG_BIN" \
  -hide_banner \
  -loglevel "${RTSP_RELAY_FFMPEG_LOGLEVEL:-warning}" \
  -nostdin \
  -fflags +genpts \
  -i "$source_url" \
  -map 0:v:0 \
  -map '0:a?' \
  -c copy \
  -f rtsp \
  -rtsp_transport tcp \
  -muxdelay 0.1 \
  "rtsp://relay:${PUBLISH_SECRET}@127.0.0.1:${RTSP_PORT_VALUE}/${STREAM_NAME}"

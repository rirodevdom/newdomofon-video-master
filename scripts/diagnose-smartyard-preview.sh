#!/usr/bin/env bash
set -Eeuo pipefail

SMARTYARD_URL="${SMARTYARD_URL:-}"
CURL_INSECURE="${CURL_INSECURE:-0}"

if [[ -z "$SMARTYARD_URL" ]]; then
  read -rsp 'SmartYard camera URL: ' SMARTYARD_URL
  echo
fi

CURL_ARGS=(-sS --max-time 90)
if [[ "$CURL_INSECURE" =~ ^(1|true|yes|on)$ ]]; then
  CURL_ARGS+=(-k)
fi

export SMARTYARD_URL

eval "$(python3 - <<'PY'
import os
import shlex
from urllib.parse import parse_qs, urlparse

raw = os.environ['SMARTYARD_URL'].strip()
parsed = urlparse(raw)
token = parse_qs(parsed.query).get('token', [''])[0]
if not parsed.scheme or not parsed.netloc or not token:
    raise SystemExit('Invalid SmartYard URL or token is missing')
base_path = parsed.path.rstrip('/')
stream = base_path.split('/')[-1]
if not stream:
    raise SystemExit('Stream name is missing from SmartYard URL')
base = f'{parsed.scheme}://{parsed.netloc}{base_path}'
print('PREVIEW_BASE=' + shlex.quote(base))
print('PREVIEW_STREAM=' + shlex.quote(stream))
print('PREVIEW_TOKEN=' + shlex.quote(token))
PY
)"

TOKEN_Q="$(PREVIEW_TOKEN="$PREVIEW_TOKEN" python3 - <<'PY'
import os
from urllib.parse import quote
print(quote(os.environ['PREVIEW_TOKEN'], safe=''))
PY
)"

HEADERS="$(mktemp)"
BODY="$(mktemp --suffix=.mp4)"
trap 'rm -f "$HEADERS" "$BODY"' EXIT

HTTP_CODE="$(curl "${CURL_ARGS[@]}" \
  -D "$HEADERS" \
  -o "$BODY" \
  -w '%{http_code}' \
  -H 'Range: bytes=0-' \
  "${PREVIEW_BASE}/preview.mp4?token=${TOKEN_Q}")"

CONTENT_TYPE="$(awk 'BEGIN{IGNORECASE=1} /^content-type:/{gsub("\r",""); value=$0} END{sub(/^[^:]+:[[:space:]]*/,"",value); print value}' "$HEADERS")"
ROUTE="$(awk 'BEGIN{IGNORECASE=1} /^x-newdomofon-smartyard-route:/{gsub("\r",""); value=$0} END{sub(/^[^:]+:[[:space:]]*/,"",value); print value}' "$HEADERS")"
COMPAT="$(awk 'BEGIN{IGNORECASE=1} /^x-newdomofon-smartyard-compat:/{gsub("\r",""); value=$0} END{sub(/^[^:]+:[[:space:]]*/,"",value); print value}' "$HEADERS")"
SIZE="$(stat -c %s "$BODY")"

printf 'stream=%s\n' "$PREVIEW_STREAM"
printf 'token_length=%s\n' "${#PREVIEW_TOKEN}"
printf 'http=%s\n' "$HTTP_CODE"
printf 'content_type=%s\n' "$CONTENT_TYPE"
printf 'route=%s\n' "$ROUTE"
printf 'compat=%s\n' "$COMPAT"
printf 'bytes=%s\n' "$SIZE"

if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "206" ]]; then
  echo 'Preview request failed:' >&2
  head -c 2000 "$BODY" >&2 || true
  echo >&2
  exit 1
fi

if [[ "$CONTENT_TYPE" != video/mp4* ]]; then
  echo "Unexpected content type: $CONTENT_TYPE" >&2
  exit 1
fi

if (( SIZE < 256 )); then
  echo "Preview is too small: $SIZE bytes" >&2
  exit 1
fi

if command -v ffprobe >/dev/null 2>&1; then
  ffprobe -v error \
    -show_entries stream=codec_name,width,height,duration \
    -show_entries format=duration,size \
    -of json "$BODY" || true
fi

echo 'SMARTYARD PREVIEW VERIFIED'

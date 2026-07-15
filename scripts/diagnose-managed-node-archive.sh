#!/usr/bin/env bash
set -Eeuo pipefail

STREAM_NAME="${STREAM_NAME:-${1:-}}"
START_ISO="${START_ISO:-${2:-}}"
END_ISO="${END_ISO:-${3:-}}"
ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:3000}"

fail() { echo "ERROR: $*" >&2; exit 1; }
section() { printf '\n===== %s =====\n' "$*"; }

[[ -n "$STREAM_NAME" ]] || fail "Usage: STREAM_NAME=name [START_ISO=...] [END_ISO=...] $0"
[[ -f "$ENV_FILE" ]] || fail "Environment file not found: $ENV_FILE"
command -v curl >/dev/null || fail "curl is required"
command -v jq >/dev/null || fail "jq is required"
command -v psql >/dev/null || fail "psql is required"
command -v python3 >/dev/null || fail "python3 is required"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

[[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL is missing"
[[ -n "${INTERNAL_DVR_SECRET:-}" ]] || fail "INTERNAL_DVR_SECRET is missing"

if [[ -z "$END_ISO" ]]; then
  END_ISO="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
fi
if [[ -z "$START_ISO" ]]; then
  START_ISO="$(python3 - "$END_ISO" <<'PY'
from datetime import datetime, timedelta, timezone
import sys
raw = sys.argv[1].replace('Z', '+00:00')
value = datetime.fromisoformat(raw)
if value.tzinfo is None:
    value = value.replace(tzinfo=timezone.utc)
print((value - timedelta(hours=6)).astimezone(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z'))
PY
)"
fi

if [[ -z "${MANAGED_TOKEN:-}" ]]; then
  read -rsp "Managed token: " MANAGED_TOKEN
  echo
fi
[[ -n "$MANAGED_TOKEN" ]] || fail "Managed token is empty"

cleanup() {
  unset MANAGED_TOKEN UPSTREAM_TOKEN RESOLVE_JSON
}
trap cleanup EXIT

section "Database camera and device policy"
psql "$DATABASE_URL" -P pager=off -v ON_ERROR_STOP=1 -v stream="$STREAM_NAME" -c "
SELECT c.id AS camera_id,
       c.name AS camera_name,
       c.stream_name,
       c.archive_storage AS camera_archive_storage,
       d.archive_storage AS device_archive_storage,
       c.retention_days,
       c.is_enabled AS camera_enabled,
       d.is_enabled AS device_enabled,
       ds.id AS node_id,
       ds.name AS node_name,
       ds.status AS node_status,
       ds.internal_url,
       COALESCE(ds.public_base_url, ds.base_url) AS public_url
  FROM cameras c
  JOIN devices d ON d.id = c.device_id
  LEFT JOIN dvr_servers ds ON ds.id = c.dvr_server_id
 WHERE c.stream_name = :'stream';
"

section "Resolve managed token"
REQUEST_JSON="$(jq -nc \
  --arg token "$MANAGED_TOKEN" \
  --arg stream "$STREAM_NAME" \
  '{token:$token,stream_name:$stream,upstream_scope:"camera"}')"

RESOLVE_JSON="$(curl -fsS --max-time 10 \
  -X POST "$BACKEND_URL/api/internal/smartyard/resolve" \
  -H 'content-type: application/json' \
  -H "x-internal-secret: $INTERNAL_DVR_SECRET" \
  --data "$REQUEST_JSON")" || fail "Managed token resolver request failed"

echo "$RESOLVE_JSON" | jq '{
  ok,
  camera,
  node: (.node | {id,name,url}),
  upstream_scope,
  expires_in,
  token_source,
  managed_token
}'

NODE_URL="$(echo "$RESOLVE_JSON" | jq -r '.node.url // empty')"
UPSTREAM_TOKEN="$(echo "$RESOLVE_JSON" | jq -r '.upstream_token // empty')"
[[ -n "$NODE_URL" && -n "$UPSTREAM_TOKEN" ]] || fail "Resolver did not return node.url and upstream_token"
NODE_URL="${NODE_URL%/}"

section "Requested window"
printf 'stream=%s\nstart=%s\nend=%s\nnode=%s\n' "$STREAM_NAME" "$START_ISO" "$END_ISO" "$NODE_URL"

section "Node recorder status"
curl -sS --max-time 10 "$NODE_URL/cameras/$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$STREAM_NAME")/status" | jq . || true

section "Node archive ranges"
RANGES_FILE="$(mktemp)"
RANGES_CODE="$(curl -sS --max-time 30 \
  --get \
  --data-urlencode "start=$START_ISO" \
  --data-urlencode "end=$END_ISO" \
  --data-urlencode "token=$UPSTREAM_TOKEN" \
  -o "$RANGES_FILE" \
  -w '%{http_code}' \
  "$NODE_URL/cameras/$STREAM_NAME/archive/ranges")"
echo "HTTP $RANGES_CODE"
jq . "$RANGES_FILE" 2>/dev/null || sed -n '1,80p' "$RANGES_FILE"
rm -f "$RANGES_FILE"

section "Node archive manifest"
MANIFEST_FILE="$(mktemp)"
MANIFEST_HEADERS="$(mktemp)"
MANIFEST_CODE="$(curl -sS --max-time 30 \
  --get \
  --data-urlencode "start=$START_ISO" \
  --data-urlencode "end=$END_ISO" \
  --data-urlencode "token=$UPSTREAM_TOKEN" \
  -D "$MANIFEST_HEADERS" \
  -o "$MANIFEST_FILE" \
  -w '%{http_code}' \
  "$NODE_URL/cameras/$STREAM_NAME/archive.m3u8")"
echo "HTTP $MANIFEST_CODE"
sed -n '1,30p' "$MANIFEST_HEADERS" | sed -E 's/([?&]token=)[^&[:space:]]+/\1***/g'
sed -n '1,80p' "$MANIFEST_FILE" | sed -E 's/([?&]token=)[^&[:space:]]+/\1***/g'
rm -f "$MANIFEST_FILE" "$MANIFEST_HEADERS"

section "Interpretation"
if [[ "$RANGES_CODE" == "200" ]] && [[ "$(jq -r '(.items // []) | length' 2>/dev/null <<<"$(curl -sS --max-time 30 --get --data-urlencode "start=$START_ISO" --data-urlencode "end=$END_ISO" --data-urlencode "token=$UPSTREAM_TOKEN" "$NODE_URL/cameras/$STREAM_NAME/archive/ranges")")" != "0" ]]; then
  echo "Node reports archive ranges in the selected window. A manifest 404 then indicates a playlist/range boundary bug."
else
  echo "Node reports no archive ranges in the selected window. Inspect the node filesystem and recorder archive_storage mode."
fi

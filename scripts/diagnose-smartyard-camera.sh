#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
SMARTYARD_URL="${SMARTYARD_URL:-${1:-}}"

if [[ -z "$SMARTYARD_URL" ]]; then
  echo "Usage: SMARTYARD_URL='https://master/stream/?token=...' $0" >&2
  exit 2
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Environment file not found: $ENV_FILE" >&2
  exit 2
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

for cmd in python3 psql curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd" >&2; exit 2; }
done

export SMARTYARD_URL

eval "$(
python3 - <<'PY'
import base64
import json
import os
import re
import shlex
from urllib.parse import parse_qs, urlparse

raw = os.environ['SMARTYARD_URL']
parsed = urlparse(raw)
token = parse_qs(parsed.query).get('token', [''])[0]
if not token or token.count('.') != 1:
    raise SystemExit('Invalid SmartYard URL or token')

body, _signature = token.split('.', 1)
body += '=' * (-len(body) % 4)
payload = json.loads(base64.urlsafe_b64decode(body).decode())
camera_id = str(payload.get('camera_id') or '')
stream_name = str(payload.get('stream_name') or '')

if not re.fullmatch(r'[0-9a-fA-F-]{36}', camera_id):
    raise SystemExit('Token camera_id is not a UUID')
if not re.fullmatch(r'[A-Za-z0-9_-]+', stream_name):
    raise SystemExit('Token stream_name is unsafe')

base = raw.split('?', 1)[0]
print('TOKEN=' + shlex.quote(token))
print('CAMERA_ID=' + shlex.quote(camera_id))
print('STREAM_NAME=' + shlex.quote(stream_name))
print('BASE_PATH=' + shlex.quote(base))
PY
)"

export TOKEN CAMERA_ID STREAM_NAME BASE_PATH

echo "camera_id=$CAMERA_ID"
echo "stream_name=$STREAM_NAME"
echo "token_prefix=${TOKEN:0:10}..."

echo
echo "===== MASTER DATABASE ROUTING ====="

psql "$DATABASE_URL" -P pager=off -x -c "
SELECT
    c.id AS camera_id,
    c.name AS camera_name,
    c.stream_name,
    c.is_enabled AS camera_enabled,
    c.onvif_xaddr,
    c.onvif_port,
    CASE WHEN COALESCE(c.onvif_password, '') = '' THEN false ELSE true END AS camera_has_onvif_password,
    c.dvr_server_id,
    ds.name AS node_name,
    ds.status AS node_status,
    ds.is_enabled AS node_enabled,
    ds.internal_url AS node_internal_url,
    ds.base_url AS node_base_url,
    ds.public_base_url AS node_public_url,
    ds.last_seen_at,
    md5(ds.media_secret) AS node_media_secret_fingerprint
FROM cameras c
LEFT JOIN dvr_servers ds ON ds.id = c.dvr_server_id
WHERE c.id = '$CAMERA_ID'::uuid;
"

NODE_ROW="$(
  psql "$DATABASE_URL" -At -F $'\t' -c "
    SELECT
      COALESCE(NULLIF(ds.internal_url, ''), NULLIF(ds.base_url, ''), NULLIF(ds.public_base_url, '')),
      ds.media_secret
    FROM cameras c
    JOIN dvr_servers ds ON ds.id = c.dvr_server_id
    WHERE c.id = '$CAMERA_ID'::uuid
      AND c.stream_name = '$STREAM_NAME'
    LIMIT 1;
  "
)"

NODE_URL="${NODE_ROW%%$'\t'*}"
NODE_SECRET="${NODE_ROW#*$'\t'}"
STATIC_SECRET="${DVR_NODE_MEDIA_SECRET:-${NODE_MEDIA_SECRET:-${MEDIA_TOKEN_SECRET:-}}}"

export NODE_URL NODE_SECRET STATIC_SECRET

echo
echo "===== TOKEN SIGNATURE ====="

python3 - <<'PY'
import base64
import hashlib
import hmac
import os

body, signature = os.environ['TOKEN'].split('.', 1)

def verify(secret):
    if not secret:
        return False
    expected = base64.urlsafe_b64encode(
        hmac.new(secret.encode(), body.encode(), hashlib.sha256).digest()
    ).decode().rstrip('=')
    return hmac.compare_digest(signature, expected)

def fingerprint(secret):
    return hashlib.sha256(secret.encode()).hexdigest()[:16] if secret else 'not-configured'

node_secret = os.environ.get('NODE_SECRET', '')
static_secret = os.environ.get('STATIC_SECRET', '')
print('valid_with_camera_node_secret =', verify(node_secret))
print('valid_with_static_proxy_secret =', verify(static_secret))
print('camera_node_secret_sha256      =', fingerprint(node_secret))
print('static_proxy_secret_sha256     =', fingerprint(static_secret))
PY

TOKEN_Q="$(python3 - <<'PY'
import os
from urllib.parse import quote
print(quote(os.environ['TOKEN'], safe=''))
PY
)"

MASTER_TEST_URL="${BASE_PATH}index.m3u8?token=${TOKEN_Q}"
DIRECT_NODE_URL="${NODE_URL%/}/cameras/${STREAM_NAME}/live.m3u8?token=${TOKEN_Q}"

echo
echo "===== MASTER SMARTYARD ====="
curl -sS --max-time 20 \
  -D /tmp/newdomofon-smartyard-master.headers \
  -o /tmp/newdomofon-smartyard-master.body \
  -w 'MASTER_HTTP=%{http_code}\n' \
  "$MASTER_TEST_URL" || true
sed -n '1,25p' /tmp/newdomofon-smartyard-master.headers 2>/dev/null || true
sed -n '1,12p' /tmp/newdomofon-smartyard-master.body 2>/dev/null || true

echo
echo "===== DIRECT NODE ====="
echo "node_url=$NODE_URL"
curl -sS --max-time 20 \
  -D /tmp/newdomofon-smartyard-node.headers \
  -o /tmp/newdomofon-smartyard-node.body \
  -w 'NODE_HTTP=%{http_code}\n' \
  "$DIRECT_NODE_URL" || true
sed -n '1,25p' /tmp/newdomofon-smartyard-node.headers 2>/dev/null || true
sed -n '1,12p' /tmp/newdomofon-smartyard-node.body 2>/dev/null || true

echo
echo "Diagnostics completed. Full token and secrets were not printed."

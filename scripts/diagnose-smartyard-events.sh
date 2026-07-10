#!/usr/bin/env bash
set -Eeuo pipefail

SMARTYARD_URL="${SMARTYARD_URL:-${1:-}}"
HOURS="${HOURS:-24}"

if [[ -z "$SMARTYARD_URL" ]]; then
  echo "Usage: SMARTYARD_URL='https://master/stream/?token=...' $0" >&2
  exit 2
fi

for cmd in python3 curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd" >&2; exit 2; }
done

export SMARTYARD_URL HOURS

eval "$(
python3 - <<'PY'
import base64
import json
import os
import re
import shlex
import time
from urllib.parse import parse_qs, quote, urlparse

raw = os.environ['SMARTYARD_URL']
parsed = urlparse(raw)
token = parse_qs(parsed.query).get('token', [''])[0]
if not token or token.count('.') != 1:
    raise SystemExit('Invalid SmartYard URL or token')

payload_segment = token.split('.', 1)[0]
payload_segment += '=' * (-len(payload_segment) % 4)
payload = json.loads(base64.urlsafe_b64decode(payload_segment).decode())
stream = str(payload.get('stream_name') or '')
if not re.fullmatch(r'[A-Za-z0-9_-]+', stream):
    raise SystemExit('Unsafe stream name')

hours = max(1, min(24 * 31, int(os.environ.get('HOURS', '24'))))
end = int(time.time())
start = end - hours * 3600
base = raw.split('?', 1)[0]

print('BASE_PATH=' + shlex.quote(base))
print('TOKEN_Q=' + shlex.quote(quote(token, safe='')))
print('STREAM_NAME=' + shlex.quote(stream))
print('START=' + shlex.quote(str(start)))
print('END=' + shlex.quote(str(end)))
PY
)"

export BASE_PATH TOKEN_Q STREAM_NAME START END

EVENTS_URL="${BASE_PATH}events.json?token=${TOKEN_Q}&from=${START}&to=${END}&limit=100"
SUMMARY_URL="${BASE_PATH}events_summary.json?token=${TOKEN_Q}&from=${START}&to=${END}"

echo "stream_name=$STREAM_NAME"
echo "period_hours=$HOURS"
echo

echo "===== EVENTS ====="
EVENT_HTTP="$(curl -sS --max-time 30 \
  -D /tmp/newdomofon-smartyard-events.headers \
  -o /tmp/newdomofon-smartyard-events.json \
  -w '%{http_code}' \
  "$EVENTS_URL")"

echo "EVENTS_HTTP=$EVENT_HTTP"
sed -n '1,25p' /tmp/newdomofon-smartyard-events.headers
python3 - <<'PY'
import json
from pathlib import Path

path = Path('/tmp/newdomofon-smartyard-events.json')
try:
    payload = json.loads(path.read_text(encoding='utf-8'))
except Exception as exc:
    print('invalid_json=', exc)
    print(path.read_text(encoding='utf-8', errors='replace')[:1000])
    raise SystemExit(0)

print('stream=', payload.get('stream'))
print('count=', payload.get('count'))
print('raw_count=', payload.get('raw_count'))
for event in (payload.get('items') or [])[:10]:
    print(event.get('occurred_at'), event.get('event_type'), event.get('event_state'), event.get('topic'))
PY

echo
echo "===== EVENTS SUMMARY ====="
SUMMARY_HTTP="$(curl -sS --max-time 30 \
  -D /tmp/newdomofon-smartyard-events-summary.headers \
  -o /tmp/newdomofon-smartyard-events-summary.json \
  -w '%{http_code}' \
  "$SUMMARY_URL")"

echo "SUMMARY_HTTP=$SUMMARY_HTTP"
sed -n '1,25p' /tmp/newdomofon-smartyard-events-summary.headers
python3 - <<'PY'
import json
from pathlib import Path

path = Path('/tmp/newdomofon-smartyard-events-summary.json')
try:
    payload = json.loads(path.read_text(encoding='utf-8'))
except Exception as exc:
    print('invalid_json=', exc)
    print(path.read_text(encoding='utf-8', errors='replace')[:1000])
    raise SystemExit(0)

items = payload.get('items') or []
print('summary_buckets=', len(items))
for item in items[-10:]:
    print(item)
PY

echo
if [[ "$EVENT_HTTP" == "200" && "$SUMMARY_HTTP" == "200" ]]; then
  echo "SMARTYARD CAMERA EVENTS VERIFIED"
else
  echo "SMARTYARD CAMERA EVENTS FAILED" >&2
  exit 1
fi

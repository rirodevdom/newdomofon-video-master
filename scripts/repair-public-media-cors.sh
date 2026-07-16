#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SITE_CONF="${SITE_CONF:-/etc/nginx/sites-available/newdomofon-video.conf}"
ENABLED_CONF="${ENABLED_CONF:-/etc/nginx/sites-enabled/newdomofon-video.conf}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/newdomofon-video/nginx}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_DIR/newdomofon-video.conf.before-public-media-cors-$STAMP.bak"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

[[ -e "$SITE_CONF" ]] || {
  echo "Nginx site config not found: $SITE_CONF" >&2
  exit 2
}

install -d -o root -g root -m 0700 "$BACKUP_DIR"
cp -aL "$SITE_CONF" "$BACKUP"

rollback() {
  local rc=$?
  trap - ERR
  echo "Public media CORS repair failed; restoring $BACKUP" >&2
  install -m 0644 "$BACKUP" "$SITE_CONF"
  ln -sfn "$SITE_CONF" "$ENABLED_CONF"
  nginx -t || true
  systemctl reload nginx || true
  exit "$rc"
}
trap rollback ERR

python3 - "$SITE_CONF" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

location_start = re.compile(r"(?m)^\s*location\s+[^\n{]+\{")


def block_end(source: str, opening_brace: int) -> int:
    depth = 0
    for index in range(opening_brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    raise RuntimeError("unterminated Nginx location block")

candidate = None
for match in location_start.finditer(text):
    opening = text.find("{", match.start(), match.end())
    end = block_end(text, opening)
    block = text[match.start():end]
    header = block.split("{", 1)[0]
    if (
        "proxy_pass http://127.0.0.1:3082" in block
        and "m3u8" in header
        and "events" not in header
    ):
        candidate = (match.start(), end, block)
        break

if candidate is None:
    raise SystemExit("public media location proxied to 127.0.0.1:3082 was not found")

start, end, block = candidate

# Normalize previous repair attempts inside this location only.
block = re.sub(
    r"\n\s*# The gateway on 3082 already emits CORS\.[^\n]*\n"
    r"\s*# writes the canonical public response, otherwise browsers see \"\*, \*\"\.\n",
    "\n",
    block,
)
block = re.sub(
    r"\n\s*proxy_hide_header\s+Access-Control-Allow-(?:Origin|Methods|Headers|Credentials|Private-Network|Max-Age);",
    "",
    block,
)
block = re.sub(
    r"\n\s*proxy_hide_header\s+Access-Control-Expose-Headers;",
    "",
    block,
)

origin_headers = list(re.finditer(
    r"(?m)^\s*add_header\s+Access-Control-Allow-Origin\s+[^;]+;",
    block,
))
if not origin_headers:
    raise SystemExit("public media location has no canonical Access-Control-Allow-Origin header")

# The first occurrence is normally inside the OPTIONS branch; the final one is
# the public response header for GET/HEAD and is the correct insertion point.
insertion = origin_headers[-1].start()
hide = '''        # The gateway on 3082 already emits CORS. Hide its headers before Nginx
        # writes the canonical public response, otherwise browsers see "*, *".
        proxy_hide_header Access-Control-Allow-Origin;
        proxy_hide_header Access-Control-Allow-Methods;
        proxy_hide_header Access-Control-Allow-Headers;
        proxy_hide_header Access-Control-Allow-Credentials;
        proxy_hide_header Access-Control-Expose-Headers;
        proxy_hide_header Access-Control-Allow-Private-Network;
        proxy_hide_header Access-Control-Max-Age;

'''
block = block[:insertion] + hide + block[insertion:]

required = [
    "proxy_hide_header Access-Control-Allow-Origin;",
    "proxy_hide_header Access-Control-Allow-Methods;",
    "proxy_hide_header Access-Control-Allow-Headers;",
    "proxy_hide_header Access-Control-Expose-Headers;",
]
for marker in required:
    if block.count(marker) != 1:
        raise SystemExit(f"unexpected CORS hide count for {marker}: {block.count(marker)}")

path.write_text(text[:start] + block + text[end:], encoding="utf-8")
PY

ln -sfn "$SITE_CONF" "$ENABLED_CONF"
nginx -t
systemctl reload nginx
sleep 1

HEADERS="$(mktemp)"
trap 'rm -f "$HEADERS"' EXIT

curl -sS --max-time 10 \
  -H 'Origin: http://cors-probe.local' \
  -D "$HEADERS" \
  -o /dev/null \
  'http://127.0.0.1/__cors_probe__/live.m3u8?token=invalid' || true

COUNT="$(awk 'BEGIN { IGNORECASE=1 } /^Access-Control-Allow-Origin:/ { count++ } END { print count+0 }' "$HEADERS")"
VALUE="$(awk 'BEGIN { IGNORECASE=1 } /^Access-Control-Allow-Origin:/ { sub(/^[^:]+:[[:space:]]*/, ""); gsub(/\r/, ""); print }' "$HEADERS")"

if [[ "$COUNT" -ne 1 || "$VALUE" != "*" ]]; then
  echo "Unexpected CORS response after repair" >&2
  echo "Access-Control-Allow-Origin count=$COUNT value=$VALUE" >&2
  cat "$HEADERS" >&2
  exit 3
fi

trap - ERR

echo "OK: public media CORS is canonical and emitted once"
echo "Access-Control-Allow-Origin count=$COUNT value=$VALUE"
echo "backup=$BACKUP"

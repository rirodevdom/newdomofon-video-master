#!/usr/bin/env bash
set -Eeuo pipefail

SITE_CONF="${SITE_CONF:-/etc/nginx/sites-available/newdomofon-video.conf}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-/opt/newdomofon-video-backups/managed-media-nginx-routing-$STAMP}"

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Run this script as root"
[[ -f "$SITE_CONF" ]] || fail "Nginx site config not found: $SITE_CONF"
command -v python3 >/dev/null || fail "python3 is required"
command -v nginx >/dev/null || fail "nginx is required"
command -v curl >/dev/null || fail "curl is required"

install -d -m 0750 "$BACKUP_DIR"
cp -a "$SITE_CONF" "$BACKUP_DIR/$(basename "$SITE_CONF").before"
nginx -T >"$BACKUP_DIR/nginx-before.txt" 2>&1 || true

log "Removing obsolete direct camera-to-node proxy routes"
python3 - "$SITE_CONF" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

managed_start = "# BEGIN NEWDOMOFON MANAGED CAMERA MEDIA GATEWAY"
managed_end = "# END NEWDOMOFON MANAGED CAMERA MEDIA GATEWAY"

# Remove only a previous managed gateway block. Keep the historical generated
# wrapper because it may still contain working /files/ and /device-archive/
# routes; the obsolete camera sub-location inside it is removed below.
text = re.sub(
    rf"\n?\s*{re.escape(managed_start)}\n[\s\S]*?\n\s*{re.escape(managed_end)}\n?",
    "\n",
    text,
)


def iter_location_blocks(src: str):
    pattern = re.compile(r"(^|\n)([ \t]*location\b[^\n{]*\{)", re.MULTILINE)
    pos = 0
    while True:
        match = pattern.search(src, pos)
        if not match:
            break
        start = match.start(2)
        brace = src.find("{", match.start(2), match.end(2) + 1)
        if brace < 0:
            pos = match.end()
            continue
        depth = 0
        i = brace
        quote = None
        escaped = False
        while i < len(src):
            ch = src[i]
            if quote:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == quote:
                    quote = None
            else:
                if ch in ("'", '"'):
                    quote = ch
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        i += 1
                        while i < len(src) and src[i] in " \t\r\n":
                            i += 1
                        yield start, i, src[start:i]
                        pos = i
                        break
            i += 1
        else:
            break


# Remove any historical /cameras/ location that still proxies directly to a
# DVR/node instead of the managed-token gateway on 127.0.0.1:3082.
remove_ranges = []
for start, end, location_block in iter_location_blocks(text):
    header = location_block.split("{", 1)[0]
    if "/cameras/" not in header:
        continue
    proxy_targets = re.findall(r"proxy_pass\s+([^;]+);", location_block)
    if proxy_targets and any("127.0.0.1:3082" not in target for target in proxy_targets):
        remove_ranges.append((start, end))

for start, end in reversed(remove_ranges):
    text = text[:start] + text[end:]

block = r'''    # BEGIN NEWDOMOFON MANAGED CAMERA MEDIA GATEWAY
    # Camera media must pass through the master gateway. It validates external
    # managed tokens (m1/mct1) and mints a short-lived node token internally.
    location ~ ^/cameras/[^/]+/(?:.*\.(?:m3u8|mpd|ts|m4s|mp4|jpg|jpeg)|recording_status\.json|media_info\.json|events(?:\.json|/summary)?|events_summary\.json|motion_events\.json|archive/ranges|device-archive/session|device-archive/ranges)$ {
        if ($request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin "*" always;
            add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
            add_header Access-Control-Allow-Headers "authorization,content-type,range,cache-control,pragma,accept,origin,x-requested-with" always;
            add_header Access-Control-Max-Age "600" always;
            return 204;
        }

        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;
        add_header Access-Control-Allow-Headers "authorization,content-type,range,cache-control,pragma,accept,origin,x-requested-with" always;
        add_header Access-Control-Expose-Headers "content-length,content-range,accept-ranges,cache-control,content-type,x-newdomofon-resolved-stream,x-newdomofon-smartyard-compat,x-newdomofon-smartyard-route" always;

        proxy_pass http://127.0.0.1:3082;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }
    # END NEWDOMOFON MANAGED CAMERA MEDIA GATEWAY

'''

# Regex locations are evaluated in declaration order. Insert this precise route
# before every remaining regex location so no stale direct node route can win.
match = re.search(r"(?m)^\s*location\s+~", text)
if match:
    text = text[:match.start()] + block + text[match.start():]
else:
    marker = "    location /assets/ {"
    if marker not in text:
        marker = "    location / {"
    if marker not in text:
        raise SystemExit("Could not find an insertion point in nginx site config")
    text = text.replace(marker, block + marker, 1)

path.write_text(text, encoding="utf-8")
PY

log "Validating and reloading nginx"
nginx -t
systemctl reload nginx
nginx -T >"$BACKUP_DIR/nginx-after.txt" 2>&1

python3 - "$BACKUP_DIR/nginx-after.txt" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
if "# BEGIN NEWDOMOFON MANAGED CAMERA MEDIA GATEWAY" not in text:
    raise SystemExit("Managed camera media gateway marker was not found")

managed_section = text.split("# BEGIN NEWDOMOFON MANAGED CAMERA MEDIA GATEWAY", 1)[1].split(
    "# END NEWDOMOFON MANAGED CAMERA MEDIA GATEWAY", 1
)[0]
if "proxy_pass http://127.0.0.1:3082;" not in managed_section:
    raise SystemExit("Managed /cameras/<stream>/ route is not using 127.0.0.1:3082")

# A direct camera route to the node is the exact regression this repair removes.
for match in re.finditer(r"location\b[^\n{]*/cameras/[^\n{]*\{", text):
    start = match.start()
    end = text.find("\n    }", start)
    if end < 0:
        end = min(len(text), start + 5000)
    snippet = text[start:end]
    targets = re.findall(r"proxy_pass\s+([^;]+);", snippet)
    if targets and any("127.0.0.1:3082" not in target for target in targets):
        raise SystemExit(f"Direct camera proxy still present: {targets}")
PY

curl -fsS --max-time 3 http://127.0.0.1:3082/health >"$BACKUP_DIR/gateway-health.json" \
  || fail "Managed media gateway on port 3082 is unavailable"

log "Managed camera media routing is active"
grep -nE 'BEGIN NEWDOMOFON MANAGED CAMERA MEDIA GATEWAY|location.*cameras|proxy_pass.*(3010|3082)' \
  "$BACKUP_DIR/nginx-after.txt" | head -120 || true

echo
cat "$BACKUP_DIR/gateway-health.json"
echo
log "Repair completed. Backup: $BACKUP_DIR"

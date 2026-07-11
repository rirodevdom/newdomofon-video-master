#!/usr/bin/env bash
set -Eeuo pipefail

SITE="${NGINX_SITE:-/etc/nginx/sites-available/newdomofon-video.conf}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${SITE}.${STAMP}.admin-media-formats.bak"

if [[ ! -f "$SITE" ]]; then
  echo "Nginx site not found: $SITE" >&2
  exit 1
fi

cp -a "$SITE" "$BACKUP"

python3 - "$SITE" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "NEWD_ADMIN_MEDIA_FORMATS_V2"

if marker in text:
    print("Nginx media formats route already installed")
    raise SystemExit(0)

lines = text.splitlines(keepends=True)


def block_end(start: int) -> int | None:
    depth = 0
    seen = False
    for index in range(start, len(lines)):
        line = lines[index]
        depth += line.count("{")
        if "{" in line:
            seen = True
        depth -= line.count("}")
        if seen and depth == 0:
            return index
    return None


# Find the existing public media location by its upstream rather than by an
# exact extension list. Production configs can differ after Certbot or earlier
# patches, while proxy_pass 127.0.0.1:3082 remains the stable contract.
insert_at = None
indent = "    "
for index, line in enumerate(lines):
    if not re.match(r"^\s*location\b", line):
        continue
    end = block_end(index)
    if end is None:
        continue
    block = "".join(lines[index:end + 1])
    if not re.search(r"proxy_pass\s+http://127\.0\.0\.1:3082(?:/|\s|;)", block):
        continue
    header = line.lower()
    if "m3u8" in header or "preview" in header or "recording_status" in header or "media_info" in header:
        insert_at = index
        indent = re.match(r"^(\s*)", line).group(1)
        break

# Fallback: use the SPA location inside a server block that already proxies to
# the public SmartYard gateway. This keeps the patch usable with custom regexes.
if insert_at is None:
    for server_index, line in enumerate(lines):
        if not re.match(r"^\s*server\s*\{", line):
            continue
        server_end = block_end(server_index)
        if server_end is None:
            continue
        server_block = "".join(lines[server_index:server_end + 1])
        if not re.search(r"proxy_pass\s+http://127\.0\.0\.1:3082(?:/|\s|;)", server_block):
            continue
        for index in range(server_index + 1, server_end):
            if re.match(r"^\s*location\s+/\s*\{", lines[index]):
                insert_at = index
                indent = re.match(r"^(\s*)", lines[index]).group(1)
                break
        if insert_at is not None:
            break

if insert_at is None:
    raise SystemExit(
        "Could not locate the Nginx server/location that proxies public media to 127.0.0.1:3082"
    )

# Add a dedicated exact-format route instead of rewriting the existing regex.
# This preserves custom production and Certbot changes and is safe even when the
# old media extension list has a different order or set of extensions.
route = f'''{indent}# {marker}\n{indent}location ~ ^/[^/]+/(?:live\\.ts|live\\.mpd|snapshot\\.(?:jpg|jpeg)|dash/.*\\.(?:m4s|mp4))$ {{\n{indent}    access_log off;\n{indent}    if ($request_method = OPTIONS) {{\n{indent}        add_header Access-Control-Allow-Origin "*" always;\n{indent}        add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;\n{indent}        add_header Access-Control-Allow-Headers "*" always;\n{indent}        add_header Access-Control-Max-Age "600" always;\n{indent}        return 204;\n{indent}    }}\n\n{indent}    add_header Access-Control-Allow-Origin "*" always;\n{indent}    add_header Access-Control-Allow-Methods "GET,HEAD,OPTIONS" always;\n{indent}    add_header Access-Control-Allow-Headers "*" always;\n{indent}    add_header Access-Control-Expose-Headers "content-length,content-range,accept-ranges,cache-control,content-type,x-newdomofon-resolved-stream,x-newdomofon-smartyard-compat,x-newdomofon-smartyard-route" always;\n\n{indent}    proxy_pass http://127.0.0.1:3082;\n{indent}    proxy_http_version 1.1;\n{indent}    proxy_set_header Host $host;\n{indent}    proxy_set_header X-Real-IP $remote_addr;\n{indent}    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n{indent}    proxy_set_header X-Forwarded-Proto $scheme;\n{indent}    proxy_connect_timeout 10s;\n{indent}    proxy_send_timeout 3600s;\n{indent}    proxy_read_timeout 3600s;\n{indent}    proxy_buffering off;\n{indent}}}\n\n'''

lines.insert(insert_at, route)
path.write_text("".join(lines))
print(f"Inserted dedicated media-format location before line {insert_at + 1}")
PY

if ! nginx -t; then
  cp -a "$BACKUP" "$SITE"
  nginx -t || true
  echo "Nginx validation failed; restored $BACKUP" >&2
  exit 1
fi

systemctl reload nginx

echo "NGINX ADMIN MEDIA FORMATS INSTALLED"
echo "Backup: $BACKUP"

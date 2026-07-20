#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import re


LOCATION_START = re.compile(r"(?m)^\s*location\s+[^\n{]+\{")
PRIVATE_NETWORK_LINE = 'add_header Access-Control-Allow-Private-Network "true" always;'


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
    raise RuntimeError("unterminated Nginx block")


def find_media_location(text: str) -> tuple[int, int, str]:
    for match in LOCATION_START.finditer(text):
        opening = text.find("{", match.start(), match.end())
        end = block_end(text, opening)
        block = text[match.start():end]
        header = block.split("{", 1)[0]
        if (
            "proxy_pass http://127.0.0.1:3082" in block
            and "m3u8" in header
            and "events" not in header
        ):
            return match.start(), end, block
    raise RuntimeError("public SmartYard media location proxied to 127.0.0.1:3082 was not found")


def insert_after_last(block: str, pattern: str, addition: str, label: str) -> str:
    matches = list(re.finditer(pattern, block, flags=re.MULTILINE))
    if not matches:
        raise RuntimeError(f"{label} anchor was not found")
    match = matches[-1]
    return block[:match.end()] + addition + block[match.end():]


def normalize_media_block(block: str) -> str:
    # Remove prior repair output so the operation is idempotent and works with
    # preserved production TLS configs that predate private-network CORS.
    block = re.sub(
        r"\n\s*# The gateway on 3082 already emits CORS\.[^\n]*\n"
        r"\s*# writes the canonical public response, otherwise browsers see \"\*, \*\"\.\n",
        "\n",
        block,
    )
    block = re.sub(
        r"(?m)^\s*proxy_hide_header\s+Access-Control-(?:Allow-(?:Origin|Methods|Headers|Credentials|Private-Network|Max-Age)|Expose-Headers);\s*\n?",
        "",
        block,
    )
    block = re.sub(
        r"(?m)^\s*add_header\s+Access-Control-Allow-Private-Network\s+[^;]+;\s*\n?",
        "",
        block,
    )

    # The first Allow-Headers is inside the OPTIONS branch. Nginx does not
    # inherit outer add_header directives into a nested if that defines its own
    # headers, so PNA must be emitted in both branches.
    allow_headers = list(re.finditer(
        r"(?m)^(\s*)add_header\s+Access-Control-Allow-Headers\s+[^;]+;",
        block,
    ))
    if len(allow_headers) < 2:
        raise RuntimeError(
            "public media location must contain Allow-Headers in OPTIONS and GET/HEAD branches"
        )

    first = allow_headers[0]
    block = (
        block[:first.end()]
        + f"\n{first.group(1)}{PRIVATE_NETWORK_LINE}"
        + block[first.end():]
    )

    # Re-scan because the first insertion changed offsets, then add the public
    # GET/HEAD response header after the final Allow-Headers directive.
    block = insert_after_last(
        block,
        r"(?m)^(\s*)add_header\s+Access-Control-Allow-Headers\s+[^;]+;",
        "\n        " + PRIVATE_NETWORK_LINE,
        "public Allow-Headers",
    )

    origin_headers = list(re.finditer(
        r"(?m)^\s*add_header\s+Access-Control-Allow-Origin\s+[^;]+;",
        block,
    ))
    if not origin_headers:
        raise RuntimeError("public media location has no Access-Control-Allow-Origin header")

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

    for marker in (
        "proxy_hide_header Access-Control-Allow-Origin;",
        "proxy_hide_header Access-Control-Allow-Methods;",
        "proxy_hide_header Access-Control-Allow-Headers;",
        "proxy_hide_header Access-Control-Expose-Headers;",
        "proxy_hide_header Access-Control-Allow-Private-Network;",
    ):
        if block.count(marker) != 1:
            raise RuntimeError(f"unexpected CORS hide count for {marker}: {block.count(marker)}")

    if block.count(PRIVATE_NETWORK_LINE) != 2:
        raise RuntimeError(
            f"expected private-network header in OPTIONS and GET/HEAD branches, got {block.count(PRIVATE_NETWORK_LINE)}"
        )

    return block


def normalize_file(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    start, end, block = find_media_location(text)
    normalized = normalize_media_block(block)
    if normalized == block:
        return False
    path.write_text(text[:start] + normalized + text[end:], encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    args = parser.parse_args()

    path = args.config.resolve()
    if not path.is_file():
        raise SystemExit(f"Nginx config not found: {path}")

    changed = normalize_file(path)
    print(f"SmartYard media CORS normalized: {path}")
    print(f"changed={'true' if changed else 'false'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

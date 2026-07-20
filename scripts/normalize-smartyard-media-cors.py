#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import re


LOCATION_START = re.compile(r"(?m)^\s*location\s+[^\n{]+\{")
ALLOW_HEADERS_RE = re.compile(r"^(\s*)add_header\s+Access-Control-Allow-Headers\s+[^;]+;\s*$")
ALLOW_ORIGIN_RE = re.compile(r"^(\s*)add_header\s+Access-Control-Allow-Origin\s+[^;]+;\s*$")
PRIVATE_NETWORK_RE = re.compile(r"^\s*add_header\s+Access-Control-Allow-Private-Network\s+[^;]+;\s*$")
HIDE_CORS_RE = re.compile(
    r"^\s*proxy_hide_header\s+Access-Control-(?:"
    r"Allow-(?:Origin|Methods|Headers|Credentials|Private-Network|Max-Age)"
    r"|Expose-Headers);\s*$"
)
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


def normalize_media_block(block: str) -> str:
    had_final_newline = block.endswith("\n")
    source_lines = block.splitlines()

    # Rebuild only the canonical CORS fragments. This line-oriented cleanup is
    # intentionally tolerant of preserved production configs and older repair
    # output, and produces byte-identical output on every subsequent run.
    cleaned: list[str] = []
    for line in source_lines:
        stripped = line.strip()
        if stripped.startswith("# The gateway on 3082 already emits CORS."):
            continue
        if stripped.startswith("# writes the canonical public response"):
            continue
        if HIDE_CORS_RE.match(line):
            continue
        if PRIVATE_NETWORK_RE.match(line):
            continue
        cleaned.append(line)

    allow_headers_count = sum(1 for line in cleaned if ALLOW_HEADERS_RE.match(line))
    if allow_headers_count != 2:
        raise RuntimeError(
            "public media location must contain exactly two Allow-Headers lines "
            f"(OPTIONS and GET/HEAD), found {allow_headers_count}"
        )

    with_private_network: list[str] = []
    for line in cleaned:
        with_private_network.append(line)
        match = ALLOW_HEADERS_RE.match(line)
        if match:
            with_private_network.append(f"{match.group(1)}{PRIVATE_NETWORK_LINE}")

    origin_indexes = [
        index for index, line in enumerate(with_private_network)
        if ALLOW_ORIGIN_RE.match(line)
    ]
    if len(origin_indexes) != 2:
        raise RuntimeError(
            "public media location must contain exactly two Allow-Origin lines "
            f"(OPTIONS and GET/HEAD), found {len(origin_indexes)}"
        )

    insertion = origin_indexes[-1]
    origin_match = ALLOW_ORIGIN_RE.match(with_private_network[insertion])
    assert origin_match is not None
    indent = origin_match.group(1)
    hide_lines = [
        f"{indent}# The gateway on 3082 already emits CORS. Hide its headers before Nginx",
        f'{indent}# writes the canonical public response, otherwise browsers see "*, *".',
        f"{indent}proxy_hide_header Access-Control-Allow-Origin;",
        f"{indent}proxy_hide_header Access-Control-Allow-Methods;",
        f"{indent}proxy_hide_header Access-Control-Allow-Headers;",
        f"{indent}proxy_hide_header Access-Control-Allow-Credentials;",
        f"{indent}proxy_hide_header Access-Control-Expose-Headers;",
        f"{indent}proxy_hide_header Access-Control-Allow-Private-Network;",
        f"{indent}proxy_hide_header Access-Control-Max-Age;",
    ]
    normalized_lines = (
        with_private_network[:insertion]
        + hide_lines
        + with_private_network[insertion:]
    )

    normalized = "\n".join(normalized_lines)
    if had_final_newline:
        normalized += "\n"

    required_counts = {
        "proxy_hide_header Access-Control-Allow-Origin;": 1,
        "proxy_hide_header Access-Control-Allow-Methods;": 1,
        "proxy_hide_header Access-Control-Allow-Headers;": 1,
        "proxy_hide_header Access-Control-Expose-Headers;": 1,
        "proxy_hide_header Access-Control-Allow-Private-Network;": 1,
        PRIVATE_NETWORK_LINE: 2,
    }
    for marker, expected in required_counts.items():
        actual = normalized.count(marker)
        if actual != expected:
            raise RuntimeError(
                f"unexpected canonical CORS count for {marker}: {actual}, expected {expected}"
            )

    return normalized


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

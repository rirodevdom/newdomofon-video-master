#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "newdomofon-smartyard-chunked-ranges"


def replace_async_function(src: str, name: str, replacement: str) -> str:
    start = src.find(f"async function {name}")
    if start < 0:
        raise RuntimeError(f"{name} not found")
    brace = src.find("{", start)
    if brace < 0:
        raise RuntimeError(f"{name} opening brace not found")
    depth = 0
    for index in range(brace, len(src)):
        char = src[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return src[:start] + replacement + src[index + 1:]
    raise RuntimeError(f"{name} closing brace not found")


def patch_gateway(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        return False

    replacement = r'''async function handleRecordingStatus(req, res, context, stream, reqUrl) {
  const SMARTYARD_RANGE_MODE = 'newdomofon-smartyard-chunked-ranges';
  const fromRaw = Number(reqUrl.searchParams.get('from') || 0);
  const endMs = Date.now();
  const oldestAllowedMs = endMs - DEFAULT_RANGE_DAYS * 24 * 3600_000;
  const requestedStartMs = Number.isFinite(fromRaw) && fromRaw > 0
    ? fromRaw * 1000
    : oldestAllowedMs;
  const startMs = Math.max(oldestAllowedMs, Math.min(requestedStartMs, endMs - 1000));

  const chunkMs = 24 * 3600_000;
  const rawItems = [];
  let chunkCount = 0;

  for (let cursor = startMs; cursor < endMs; cursor += chunkMs) {
    const chunkEnd = Math.min(endMs, cursor + chunkMs);
    const path = `/cameras/${encodeURIComponent(stream)}/archive/ranges?start=${encodeURIComponent(new Date(cursor).toISOString())}&end=${encodeURIComponent(new Date(chunkEnd).toISOString())}&${queryToken(context.upstream_token)}`;
    const response = await nodeFetch(context, path, req, 30000);
    const raw = await response.text();
    chunkCount += 1;

    if (!response.ok) {
      return sendText(res, response.status, raw, response.headers.get('content-type') || 'application/json; charset=utf-8', {
        'x-newdomofon-resolved-stream': stream,
        'x-newdomofon-smartyard-route': 'node-ranges-chunked',
        'x-newdomofon-ranges-mode': SMARTYARD_RANGE_MODE,
        'x-newdomofon-ranges-chunks': String(chunkCount)
      });
    }

    let payload;
    try { payload = JSON.parse(raw); } catch { payload = { items: [] }; }
    if (Array.isArray(payload?.items)) rawItems.push(...payload.items);
  }

  const ranges = rawItems.map((item) => {
    const from = Math.floor(Date.parse(item.start) / 1000);
    const to = Math.floor(Date.parse(item.end) / 1000);
    return { from, duration: Math.max(0, to - from) };
  }).filter((item) => Number.isFinite(item.from) && item.duration > 0);

  ranges.sort((left, right) => left.from - right.from);

  return sendJson(res, 200, [{ stream, ranges }], {
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-ranges-count': String(ranges.length),
    'x-newdomofon-ranges-raw-count': String(rawItems.length),
    'x-newdomofon-ranges-start': new Date(startMs).toISOString(),
    'x-newdomofon-ranges-end': new Date(endMs).toISOString(),
    'x-newdomofon-ranges-mode': SMARTYARD_RANGE_MODE,
    'x-newdomofon-ranges-chunks': String(chunkCount),
    'x-newdomofon-smartyard-route': 'node-ranges-chunked'
  });
}'''

    text = replace_async_function(text, "handleRecordingStatus", replacement)
    for required in (
        MARKER,
        "'x-newdomofon-ranges-chunks'",
        "node-ranges-chunked",
        "const chunkMs = 24 * 3600_000;",
    ):
        if required not in text:
            raise RuntimeError(f"chunked ranges marker missing: {required}")

    path.write_text(text, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    project = Path(args.project_dir).resolve()
    gateway = project / "smartyard-compat-proxy" / "server-node-aware.js"
    if not gateway.is_file():
        raise SystemExit(f"SmartYard gateway source not found: {gateway}")

    changed = patch_gateway(gateway)
    print("SmartYard chunked archive ranges prepared")
    print("  changed: smartyard-compat-proxy/server-node-aware.js" if changed else "  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

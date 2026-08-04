#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

V1_MARKER = "newdomofon-smartyard-chunked-ranges"
V2_MARKER = "newdomofon-smartyard-parallel-cached-ranges"


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
    if V2_MARKER in text:
        return False

    replacement = r'''async function handleRecordingStatus(req, res, context, stream, reqUrl) {
  // Preserve the v1 marker because patch-managed-media-gateway.py uses it to
  // recognize that Flussonic recording_status compatibility is already owned
  // by this handler on repeated deploy passes.
  const LEGACY_CHUNKED_MARKER = 'newdomofon-smartyard-chunked-ranges';
  const SMARTYARD_RANGE_MODE = 'newdomofon-smartyard-parallel-cached-ranges';
  const RANGE_CACHE_TTL_MS = Math.max(1000, Number(process.env.SMARTYARD_RANGE_CACHE_TTL_MS || 30000));
  const RANGE_CACHE_STALE_MS = Math.max(RANGE_CACHE_TTL_MS, Number(process.env.SMARTYARD_RANGE_CACHE_STALE_MS || 300000));
  const RANGE_CHUNK_CONCURRENCY = Math.max(1, Math.min(8, Number(process.env.SMARTYARD_RANGE_CHUNK_CONCURRENCY || 4)));
  const RANGE_MERGE_GAP_SECONDS = Math.max(0, Number(process.env.SMARTYARD_RANGE_MERGE_GAP_SECONDS || 15));

  const state = handleRecordingStatus.__newdomofonRangeState || (handleRecordingStatus.__newdomofonRangeState = {
    cache: new Map(),
    jobs: new Map()
  });

  const fromRaw = Number(reqUrl.searchParams.get('from') || 0);
  const endMs = Date.now();
  const oldestAllowedMs = endMs - DEFAULT_RANGE_DAYS * 24 * 3600_000;
  const requestedStartMs = Number.isFinite(fromRaw) && fromRaw > 0
    ? fromRaw * 1000
    : oldestAllowedMs;
  const startMs = Math.max(oldestAllowedMs, Math.min(requestedStartMs, endMs - 1000));
  const cacheKey = `${String(context.node.url).replace(/\/+$/, '')}|${stream}|${DEFAULT_RANGE_DAYS}`;

  function mergeRanges(rawItems) {
    const normalized = rawItems.map((item) => {
      const from = Math.floor(Date.parse(item.start) / 1000);
      const to = Math.floor(Date.parse(item.end) / 1000);
      return { from, to };
    }).filter((item) => Number.isFinite(item.from) && Number.isFinite(item.to) && item.to > item.from)
      .sort((left, right) => left.from - right.from);

    const merged = [];
    for (const item of normalized) {
      const last = merged[merged.length - 1];
      if (!last || item.from > last.to + RANGE_MERGE_GAP_SECONDS) {
        merged.push({ from: item.from, to: item.to });
        continue;
      }
      if (item.to > last.to) last.to = item.to;
    }
    return merged.map((item) => ({ from: item.from, duration: item.to - item.from }));
  }

  async function loadRanges() {
    const chunkMs = 24 * 3600_000;
    const chunks = [];
    for (let cursor = startMs; cursor < endMs; cursor += chunkMs) {
      chunks.push({ startMs: cursor, endMs: Math.min(endMs, cursor + chunkMs) });
    }

    const chunkItems = new Array(chunks.length);
    let nextIndex = 0;

    async function worker() {
      for (;;) {
        const index = nextIndex;
        nextIndex += 1;
        if (index >= chunks.length) return;
        const chunk = chunks[index];
        const path = `/cameras/${encodeURIComponent(stream)}/archive/ranges?start=${encodeURIComponent(new Date(chunk.startMs).toISOString())}&end=${encodeURIComponent(new Date(chunk.endMs).toISOString())}&${queryToken(context.upstream_token)}`;
        const response = await nodeFetch(context, path, req, 30000);
        const raw = await response.text();
        if (!response.ok) {
          const error = new Error(`Archive ranges upstream returned ${response.status}`);
          error.status = response.status;
          error.body = raw;
          error.contentType = response.headers.get('content-type') || 'application/json; charset=utf-8';
          throw error;
        }
        let payload;
        try { payload = JSON.parse(raw); } catch { payload = { items: [] }; }
        chunkItems[index] = Array.isArray(payload?.items) ? payload.items : [];
      }
    }

    await Promise.all(Array.from(
      { length: Math.min(RANGE_CHUNK_CONCURRENCY, Math.max(1, chunks.length)) },
      () => worker()
    ));

    const rawItems = chunkItems.flat();
    const value = {
      createdAt: Date.now(),
      startMs,
      endMs,
      ranges: mergeRanges(rawItems),
      rawCount: rawItems.length,
      chunkCount: chunks.length
    };
    state.cache.set(cacheKey, value);
    return value;
  }

  function startLoad() {
    const existing = state.jobs.get(cacheKey);
    if (existing) return existing;
    const job = loadRanges().finally(() => {
      if (state.jobs.get(cacheKey) === job) state.jobs.delete(cacheKey);
    });
    state.jobs.set(cacheKey, job);
    return job;
  }

  function sendValue(value, cacheMode) {
    const requestedFrom = Math.floor(startMs / 1000);
    const ranges = value.ranges.filter((item) => item.from + item.duration >= requestedFrom);
    return sendJson(res, 200, [{ stream, ranges }], {
      'x-newdomofon-resolved-stream': stream,
      'x-newdomofon-ranges-count': String(ranges.length),
      'x-newdomofon-ranges-raw-count': String(value.rawCount),
      'x-newdomofon-ranges-start': new Date(value.startMs).toISOString(),
      'x-newdomofon-ranges-end': new Date(value.endMs).toISOString(),
      'x-newdomofon-ranges-mode': SMARTYARD_RANGE_MODE,
      'x-newdomofon-ranges-chunks': String(value.chunkCount),
      'x-newdomofon-ranges-concurrency': String(RANGE_CHUNK_CONCURRENCY),
      'x-newdomofon-ranges-cache': cacheMode,
      'x-newdomofon-ranges-cache-age-ms': String(Math.max(0, Date.now() - value.createdAt)),
      'x-newdomofon-smartyard-route': 'node-ranges-parallel-cache'
    });
  }

  const cached = state.cache.get(cacheKey);
  if (cached) {
    const age = Date.now() - cached.createdAt;
    if (age <= RANGE_CACHE_TTL_MS) return sendValue(cached, 'fresh');
    if (age <= RANGE_CACHE_STALE_MS) {
      void startLoad().catch((error) => {
        console.warn('[smartyard-node-aware] background ranges refresh failed', {
          stream,
          error: String(error?.message || error)
        });
      });
      return sendValue(cached, 'stale');
    }
  }

  try {
    return sendValue(await startLoad(), 'miss');
  } catch (error) {
    const status = Number(error?.status || 502);
    return sendText(res, status, String(error?.body || error?.message || error), error?.contentType || 'application/json; charset=utf-8', {
      'x-newdomofon-resolved-stream': stream,
      'x-newdomofon-ranges-mode': SMARTYARD_RANGE_MODE,
      'x-newdomofon-ranges-cache': 'error',
      'x-newdomofon-smartyard-route': 'node-ranges-parallel-cache'
    });
  }
}'''

    text = replace_async_function(text, "handleRecordingStatus", replacement)
    for required in (
        V1_MARKER,
        V2_MARKER,
        "RANGE_CHUNK_CONCURRENCY",
        "x-newdomofon-ranges-cache",
        "node-ranges-parallel-cache",
        "Promise.all(Array.from",
    ):
        if required not in text:
            raise RuntimeError(f"ranges performance marker missing: {required}")

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
    print("SmartYard parallel cached archive ranges prepared")
    print("  changed: smartyard-compat-proxy/server-node-aware.js" if changed else "  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

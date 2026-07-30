#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one source block, found {count}")
    return text.replace(old, new, 1)


def patch_backend(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "const ARCHIVE_RANGE_CHUNK_MS = 24 * 60 * 60 * 1000;\nconst ARCHIVE_RANGE_MERGE_GAP_MS = 2000;",
        "const ARCHIVE_RANGE_CHUNK_MS = 24 * 60 * 60 * 1000;\nconst ARCHIVE_RANGE_MERGE_GAP_MS = 2000;\nconst ARCHIVE_RANGE_CONCURRENCY = 2;\nconst ARCHIVE_RANGE_CACHE_MS = 30_000;",
        "archive performance constants",
    )
    marker = "type ArchiveRangeRequestResult"
    if marker not in text:
        insertion = '''type ArchiveRangeRequestResult = {\n  items: ArchiveRangeItem[];\n  chunksAttempted: number;\n  chunksSucceeded: number;\n  chunksNotFound: number;\n};\n\nconst archiveRangeRequests = new Map<string, { expiresAt: number; promise: Promise<ArchiveRangeRequestResult> }>();\n\n'''
        text = text.replace("function normalizeNodeBaseUrl", insertion + "function normalizeNodeBaseUrl", 1)

    old = '''async function loadArchiveRangesChunked(
  channel: HikvisionChannelRow,
  start: Date,
  end: Date
): Promise<{ items: ArchiveRangeItem[]; chunksAttempted: number; chunksSucceeded: number; chunksNotFound: number }> {
  const chunks = archiveChunks(start, end);
  const items: ArchiveRangeItem[] = [];
  let chunksSucceeded = 0;
  let chunksNotFound = 0;
  let lastNotFound: unknown = null;

  for (const chunk of chunks) {
    try {
      const payload = await nodeJson(channel, 'archive', 'archive/ranges', {}, {
        start: chunk.start.toISOString(),
        end: chunk.end.toISOString()
      });
      chunksSucceeded += 1;
      items.push(...((payload.ranges || payload.items || []) as ArchiveRangeItem[]));
    } catch (error) {
      if (errorStatus(error) === 404) {
        chunksNotFound += 1;
        lastNotFound = error;
        continue;
      }
      throw error;
    }
  }

  if (!chunksSucceeded && lastNotFound) {
    throw Object.assign(
      new Error('Hikvision archive ranges endpoint was not found on every configured node URL'),
      { statusCode: 502, cause: lastNotFound }
    );
  }

  return {
    items: mergeArchiveRanges(items),
    chunksAttempted: chunks.length,
    chunksSucceeded,
    chunksNotFound
  };
}'''
    new = '''async function loadArchiveRangesChunked(
  channel: HikvisionChannelRow,
  start: Date,
  end: Date
): Promise<ArchiveRangeRequestResult> {
  const chunks = archiveChunks(start, end);
  const items: ArchiveRangeItem[] = [];
  let chunksSucceeded = 0;
  let chunksNotFound = 0;
  let lastNotFound: unknown = null;
  let cursor = 0;

  const worker = async () => {
    for (;;) {
      const index = cursor;
      cursor += 1;
      const chunk = chunks[index];
      if (!chunk) return;
      try {
        const payload = await nodeJson(channel, 'archive', 'archive/ranges', {}, {
          start: chunk.start.toISOString(),
          end: chunk.end.toISOString()
        });
        chunksSucceeded += 1;
        items.push(...((payload.ranges || payload.items || []) as ArchiveRangeItem[]));
      } catch (error) {
        if (errorStatus(error) === 404) {
          chunksNotFound += 1;
          lastNotFound = error;
          continue;
        }
        throw error;
      }
    }
  };

  await Promise.all(Array.from({ length: Math.min(ARCHIVE_RANGE_CONCURRENCY, Math.max(1, chunks.length)) }, () => worker()));

  if (!chunksSucceeded && lastNotFound) {
    throw Object.assign(
      new Error('Hikvision archive ranges endpoint was not found on every configured node URL'),
      { statusCode: 502, cause: lastNotFound }
    );
  }

  return {
    items: mergeArchiveRanges(items),
    chunksAttempted: chunks.length,
    chunksSucceeded,
    chunksNotFound
  };
}

function loadArchiveRangesCached(channel: HikvisionChannelRow, start: Date, end: Date): Promise<ArchiveRangeRequestResult> {
  const key = `${channel.channel_external_id}|${start.toISOString()}|${end.toISOString()}`;
  const now = Date.now();
  const existing = archiveRangeRequests.get(key);
  if (existing && existing.expiresAt > now) return existing.promise;
  const promise = loadArchiveRangesChunked(channel, start, end);
  archiveRangeRequests.set(key, { expiresAt: now + ARCHIVE_RANGE_CACHE_MS, promise });
  void promise.catch(() => {
    if (archiveRangeRequests.get(key)?.promise === promise) archiveRangeRequests.delete(key);
  });
  return promise;
}'''
    text = replace_once(text, old, new, "parallel cached archive ranges")
    text = replace_once(text, "  const result = await loadArchiveRangesChunked(channel, start, end);", "  const result = await loadArchiveRangesCached(channel, start, end);", "use archive range cache")
    text = replace_once(text, "  res.setHeader('cache-control', 'no-store');", "  res.setHeader('cache-control', 'private, max-age=15');", "archive response cache header")
    path.write_text(text, encoding="utf-8")


def patch_frontend(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "let assetsPromise: Promise<void> | null = null;\nlet latestRanges: Array<{ startMs: number; endMs: number }> = [];",
        "let assetsPromise: Promise<void> | null = null;\nlet latestRanges: Array<{ startMs: number; endMs: number }> = [];\nlet rangesPromise: Promise<Array<{ startMs: number; endMs: number }>> | null = null;\nlet rangesLoadedAt = 0;\nconst RANGE_CACHE_MS = 30_000;",
        "frontend range request state",
    )
    old = '''async function loadArchiveRanges() {
  const end = new Date().toISOString();
  const days = Math.max(1, Number(channel.value?.retention_days || 1));
  const start = new Date(Date.now() - days * 24 * 3600 * 1000).toISOString();
  const { data } = await api.get(`${apiBase.value}/archive/ranges`, { params: { start, end } });
  latestRanges = (data.items || []).map((item: any) => ({
    startMs: new Date(item.start).getTime(),
    endMs: new Date(item.end).getTime()
  })).filter((item: any) => Number.isFinite(item.startMs) && Number.isFinite(item.endMs) && item.endMs > item.startMs);
  return latestRanges;
}'''
    new = '''async function loadArchiveRanges() {
  if (latestRanges.length && Date.now() - rangesLoadedAt < RANGE_CACHE_MS) return latestRanges;
  if (rangesPromise) return rangesPromise;
  const request = (async () => {
    const end = new Date().toISOString();
    const days = Math.max(1, Number(channel.value?.retention_days || 1));
    const start = new Date(Date.now() - days * 24 * 3600 * 1000).toISOString();
    const { data } = await api.get(`${apiBase.value}/archive/ranges`, { params: { start, end } });
    latestRanges = (data.items || []).map((item: any) => ({
      startMs: new Date(item.start).getTime(),
      endMs: new Date(item.end).getTime()
    })).filter((item: any) => Number.isFinite(item.startMs) && Number.isFinite(item.endMs) && item.endMs > item.startMs);
    rangesLoadedAt = Date.now();
    return latestRanges;
  })();
  rangesPromise = request;
  try {
    return await request;
  } finally {
    if (rangesPromise === request) rangesPromise = null;
  }
}'''
    text = replace_once(text, old, new, "deduplicate archive range request")
    text = replace_once(text, "  const initialRanges = await loadArchiveRanges().catch(() => []);", "  // Live must not wait for a seven-day ISAPI archive scan. The player can\n  // request ranges through the deduplicated callback after live bootstrap.\n  const initialRanges = latestRanges;", "nonblocking live bootstrap")
    text = replace_once(text, "  latestRanges = [];\n  try {", "  latestRanges = [];\n  rangesPromise = null;\n  rangesLoadedAt = 0;\n  try {", "reset range cache on reload")
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=".")
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    patch_backend(root / "backend/src/routes/hikvisionPlayer.ts")
    patch_frontend(root / "frontend/src/views/HikvisionPlayerView.vue")
    print("Hikvision response performance prepared")


if __name__ == "__main__":
    main()

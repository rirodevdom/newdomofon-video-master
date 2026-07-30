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


def patch_frontend(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "const RANGE_CACHE_MS = 30_000;",
        '''const RANGE_CACHE_MS = 30_000;
const RANGE_RETRY_DELAYS_MS = [0, 1_000, 2_500, 5_000, 10_000];
const ARCHIVE_RETRY_DELAYS_MS = [0, 2_000];
const TRANSIENT_HIKVISION_STATUSES = new Set([404, 408, 425, 429, 500, 502, 503, 504]);

async function waitForRetry(ms: number, signal?: AbortSignal) {
  if (ms > 0) await new Promise((resolve) => window.setTimeout(resolve, ms));
  if (signal?.aborted) throw new DOMException('Aborted', 'AbortError');
}

function requestStatus(error: any): number {
  return Number(error?.response?.status || error?.statusCode || 0);
}

function isTransientHikvisionError(error: any): boolean {
  return TRANSIENT_HIKVISION_STATUSES.has(requestStatus(error));
}

function mergeKnownRanges(items: Array<{ startMs: number; endMs: number }>) {
  const sorted = items
    .filter((item) => Number.isFinite(item.startMs) && Number.isFinite(item.endMs) && item.endMs > item.startMs)
    .sort((left, right) => left.startMs - right.startMs);
  const merged: Array<{ startMs: number; endMs: number }> = [];
  for (const item of sorted) {
    const current = merged[merged.length - 1];
    if (current && item.startMs <= current.endMs + 2_000) current.endMs = Math.max(current.endMs, item.endMs);
    else merged.push({ ...item });
  }
  return merged;
}''',
        "Hikvision retry helpers",
    )

    old_ranges = '''async function loadArchiveRanges(signal?: AbortSignal) {
  if (latestRanges.length && Date.now() - rangesLoadedAt < RANGE_CACHE_MS) return latestRanges;
  if (rangesPromise) return rangesPromise;
  const request = (async () => {
    const end = new Date().toISOString();
    const days = Math.max(1, Number(channel.value?.retention_days || 1));
    const start = new Date(Date.now() - days * 24 * 3600 * 1000).toISOString();
    const { data } = await api.get(`${apiBase.value}/archive/ranges`, { params: { start, end }, signal });
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
    new_ranges = '''async function loadArchiveRanges(signal?: AbortSignal) {
  if (latestRanges.length && Date.now() - rangesLoadedAt < RANGE_CACHE_MS) return latestRanges;
  if (rangesPromise) return rangesPromise;
  const request = (async () => {
    let lastError: any = null;
    for (const delayMs of RANGE_RETRY_DELAYS_MS) {
      await waitForRetry(delayMs, signal);
      try {
        const end = new Date().toISOString();
        const days = Math.max(1, Number(channel.value?.retention_days || 1));
        const start = new Date(Date.now() - days * 24 * 3600 * 1000).toISOString();
        const { data } = await api.get(`${apiBase.value}/archive/ranges`, { params: { start, end }, signal });
        const loaded = (data.items || []).map((item: any) => ({
          startMs: new Date(item.start).getTime(),
          endMs: new Date(item.end).getTime()
        })).filter((item: any) => Number.isFinite(item.startMs) && Number.isFinite(item.endMs) && item.endMs > item.startMs);
        latestRanges = mergeKnownRanges([...latestRanges, ...loaded]);
        rangesLoadedAt = Date.now();
        return latestRanges;
      } catch (err: any) {
        if (signal?.aborted || err?.name === 'CanceledError' || err?.name === 'AbortError') throw err;
        lastError = err;
        if (!isTransientHikvisionError(err)) throw err;
      }
    }
    // A successfully prepared playback window is still useful as a provisional
    // timeline range while the full-retention search recovers in the background.
    if (latestRanges.length) return latestRanges;
    throw lastError || new Error('Не удалось загрузить диапазоны архива Hikvision');
  })();
  rangesPromise = request;
  try {
    return await request;
  } finally {
    if (rangesPromise === request) rangesPromise = null;
  }
}'''
    text = replace_once(text, old_ranges, new_ranges, "retry archive ranges")

    old_archive = '''                const archive = await api.get(`${apiBase.value}/archive`, {
                  params: { start: new Date(startMs).toISOString(), end: new Date(endMs).toISOString() }
                });
                return archive.data.archiveHls || archive.data.hls_url || archive.data.playback_url;'''
    new_archive = '''                let archive: any = null;
                let archiveError: any = null;
                for (const delayMs of ARCHIVE_RETRY_DELAYS_MS) {
                  await waitForRetry(delayMs);
                  try {
                    archive = await api.get(`${apiBase.value}/archive`, {
                      params: { start: new Date(startMs).toISOString(), end: new Date(endMs).toISOString() },
                      timeout: 95_000
                    });
                    break;
                  } catch (err: any) {
                    archiveError = err;
                    if (!isTransientHikvisionError(err)) throw err;
                  }
                }
                if (!archive) throw archiveError || new Error('Не удалось подготовить архивный фрагмент Hikvision');
                latestRanges = mergeKnownRanges([...latestRanges, { startMs, endMs }]);
                // Force a full-retention refresh after playback starts. If it is
                // still temporarily unavailable, loadArchiveRanges returns this
                // provisional playback range instead of clearing the timeline.
                rangesLoadedAt = 0;
                return archive.data.archiveHls || archive.data.hls_url || archive.data.playback_url;'''
    text = replace_once(text, old_archive, new_archive, "retry archive session and retain provisional range")
    path.write_text(text, encoding="utf-8")


def patch_player_kit(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    old = 'async refreshRanges(e){try{const t=await this.bootstrapData.archive?.loadRanges?.(e??this.abort.signal);t&&(this.ranges=t,this.timeline.setArchiveRanges(t))}catch(t){if(e?.aborted||this.abort.signal.aborted)return;this.caps.archiveGaps=!1,this.timeline.setArchiveRanges([]),this.handleError(t,"archive-ranges")}}'
    new = 'async refreshRanges(e){try{const t=await this.bootstrapData.archive?.loadRanges?.(e??this.abort.signal);t&&(this.ranges=t,this.caps.archiveGaps=!0,this.timeline.setArchiveRanges(t))}catch(t){if(e?.aborted||this.abort.signal.aborted)return;this.logger.warn("archive-ranges",t)}}'
    text = replace_once(text, old, new, "preserve timeline after transient range failure")
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=".")
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    patch_frontend(root / "frontend/src/views/HikvisionPlayerView.vue")
    patch_player_kit(root / "frontend/public/player-kit/newdomofon-player.iife.js")
    print("Hikvision live/archive retries and resilient timeline prepared")


if __name__ == "__main__":
    main()

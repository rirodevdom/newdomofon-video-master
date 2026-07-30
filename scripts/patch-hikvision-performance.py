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
    if "type ArchiveRangeRequestResult" not in text:
        insertion = '''type ArchiveRangeRequestResult = {
  items: ArchiveRangeItem[];
  chunksAttempted: number;
  chunksSucceeded: number;
  chunksNotFound: number;
};

const archiveRangeRequests = new Map<string, { expiresAt: number; promise: Promise<ArchiveRangeRequestResult> }>();

'''
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
    text = replace_once(
        text,
        "  const result = await loadArchiveRangesChunked(channel, start, end);\n  res.setHeader('cache-control', 'no-store');",
        "  const result = await loadArchiveRangesCached(channel, start, end);\n  res.setHeader('cache-control', 'private, max-age=15');",
        "cached archive range route",
    )

    old_status = '''hikvisionPlayerRouter.get('/:channelId/status', asyncHandler(async (req, res) => {
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  res.json({
    recording: channel.online === true && channel.enabled && channel.device_enabled && channel.node_enabled,
    online: channel.online,
    stream_name: channel.primary_stream_id,
    channel_id: channel.channel_external_id,
    node_id: channel.dvr_server_id,
    node_status: channel.node_status,
    archive_storage: channel.archive_storage,
    available_archive_sources: [channel.archive_storage],
    default_archive_source: channel.archive_storage,
    media_transport: 'master-https-proxy',
    upstream_media_auth: 'agent-token-hash'
  });
}));'''
    new_status = '''hikvisionPlayerRouter.get('/:channelId/status', asyncHandler(async (req, res) => {
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });

  let liveProbe = false;
  let liveProbeError: string | null = null;
  try {
    const upstream = await fetchNodeMedia(
      channel,
      'live',
      'live/index.m3u8',
      { method: 'GET', headers: { accept: 'application/vnd.apple.mpegurl' } },
      {},
      5_000
    );
    liveProbe = upstream.ok;
    if (upstream.body) await upstream.body.cancel().catch(() => undefined);
  } catch (error) {
    liveProbeError = error instanceof Error ? error.message : String(error);
  }

  const databaseRecording = channel.online === true && channel.enabled && channel.device_enabled && channel.node_enabled;
  res.setHeader('cache-control', 'no-store');
  res.json({
    recording: liveProbe || databaseRecording,
    online: liveProbe ? true : channel.online,
    live_probe: liveProbe,
    live_probe_error: liveProbe ? null : liveProbeError,
    stream_name: channel.primary_stream_id,
    channel_id: channel.channel_external_id,
    node_id: channel.dvr_server_id,
    node_status: channel.node_status,
    archive_storage: channel.archive_storage,
    available_archive_sources: [channel.archive_storage],
    default_archive_source: channel.archive_storage,
    media_transport: 'master-https-proxy',
    upstream_media_auth: 'agent-token-hash'
  });
}));'''
    text = replace_once(text, old_status, new_status, "runtime-backed Hikvision status")
    path.write_text(text, encoding="utf-8")


def patch_frontend(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "let assetsPromise: Promise<void> | null = null;\nlet latestRanges: Array<{ startMs: number; endMs: number }> = [];",
        "let assetsPromise: Promise<void> | null = null;\nlet latestRanges: Array<{ startMs: number; endMs: number }> = [];\nlet rangesPromise: Promise<Array<{ startMs: number; endMs: number }>> | null = null;\nlet rangesLoadedAt = 0;\nlet reloadSerial = 0;\nlet statusTimer: number | null = null;\nconst RANGE_CACHE_MS = 30_000;",
        "frontend request state",
    )
    old_status = '''async function loadStatus() {
  try {
    const { data } = await api.get(`${apiBase.value}/status`);
    status.value = data;
  } catch (err: any) {
    status.value = { recording: false, error: err.response?.data?.error || err.message };
  }
}'''
    new_status = '''async function loadStatus(serial = reloadSerial) {
  try {
    const { data } = await api.get(`${apiBase.value}/status`);
    if (serial === reloadSerial) status.value = data;
  } catch (err: any) {
    if (serial === reloadSerial) {
      status.value = { recording: false, online: false, error: err.response?.data?.error || err.message };
    }
  }
}'''
    text = replace_once(text, old_status, new_status, "generation-safe status load")

    old_ranges = '''async function loadArchiveRanges() {
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
    new_ranges = '''async function loadArchiveRanges(signal?: AbortSignal) {
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
    text = replace_once(text, old_ranges, new_ranges, "deduplicate archive range request")
    text = replace_once(
        text,
        "  const initialRanges = await loadArchiveRanges().catch(() => []);",
        "  // Start live immediately. The player-kit loads archive ranges in the\n  // background after live playback has been initialized.\n  const initialRanges = latestRanges;",
        "nonblocking live bootstrap",
    )
    text = replace_once(
        text,
        "              try {\n                const requestedMs = fromEpochSec * 1000 + Math.max(1, durationSec) * 500;",
        "              try {\n                if (!latestRanges.length) await loadArchiveRanges();\n                const requestedMs = fromEpochSec * 1000 + Math.max(1, durationSec) * 500;",
        "archive waits for background ranges",
    )

    old_reload = '''async function reloadPlayer() {
  if (!channelId.value) return;
  loading.value = true;
  error.value = '';
  latestRanges = [];
  try {
    destroyPlayer();
    await loadChannel();
    await nextTick();
    await createPlayer();
    await loadStatus();
  } catch (err: any) {
    error.value = err.response?.data?.error || err.message || 'Не удалось запустить Hikvision-плеер';
  } finally {
    loading.value = false;
  }
}'''
    new_reload = '''async function reloadPlayer() {
  if (!channelId.value) return;
  const serial = ++reloadSerial;
  loading.value = true;
  error.value = '';
  status.value = null;
  latestRanges = [];
  rangesPromise = null;
  rangesLoadedAt = 0;
  if (statusTimer != null) {
    window.clearInterval(statusTimer);
    statusTimer = null;
  }
  try {
    destroyPlayer();
    await loadChannel();
    if (serial !== reloadSerial) return;
    void loadStatus(serial);
    statusTimer = window.setInterval(() => { void loadStatus(serial); }, 10_000);
    await nextTick();
    if (serial !== reloadSerial) return;
    await createPlayer();
  } catch (err: any) {
    if (serial === reloadSerial) {
      error.value = err.response?.data?.error || err.message || 'Не удалось запустить Hikvision-плеер';
    }
  } finally {
    if (serial === reloadSerial) loading.value = false;
  }
}'''
    text = replace_once(text, old_reload, new_reload, "nonblocking status and player reload")
    text = replace_once(
        text,
        "onBeforeUnmount(() => { destroyPlayer(); });",
        "onBeforeUnmount(() => {\n  reloadSerial += 1;\n  if (statusTimer != null) window.clearInterval(statusTimer);\n  statusTimer = null;\n  destroyPlayer();\n});",
        "player cleanup",
    )
    path.write_text(text, encoding="utf-8")


def patch_player_kit(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    old = 'this.timeline.setArchiveRanges(this.ranges),await this.loadOptionalLayers(),this.config.startMode==="archive"||!this.caps.live?await this.playArchive(this.config.initialArchiveTimeMs??Date.now()):await this.playLive(),this.notifyState()'
    new = 'this.timeline.setArchiveRanges(this.ranges),this.config.startMode==="archive"||!this.caps.live?(await this.loadOptionalLayers(),await this.playArchive(this.config.initialArchiveTimeMs??Date.now())):(await this.playLive(),void this.loadOptionalLayers()),this.notifyState()'
    text = replace_once(text, old, new, "player-kit live before optional archive layers")
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=".")
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    patch_backend(root / "backend/src/routes/hikvisionPlayer.ts")
    patch_frontend(root / "frontend/src/views/HikvisionPlayerView.vue")
    patch_player_kit(root / "frontend/public/player-kit/newdomofon-player.iife.js")
    print("Hikvision response performance and live-first recovery prepared")


if __name__ == "__main__":
    main()

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
        '''    archive_storage: channel.archive_storage,
    available_sources: [channel.archive_storage],
    ready: true,''',
        '''    archive_storage: channel.archive_storage,
    available_sources: [channel.archive_storage],
    start: session.start || params.start,
    end: session.end || params.end,
    ready: true,''',
        "archive response window metadata",
    )
    path.write_text(text, encoding="utf-8")


def patch_frontend(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "const ARCHIVE_MAX_SECONDS = 10 * 60;",
        "const ARCHIVE_MAX_SECONDS = 5 * 60;",
        "five minute Hikvision session window",
    )
    text = replace_once(
        text,
        "    maxDownloadDurationSec: 3600,\n    onError:",
        "    maxDownloadDurationSec: 3600,\n    defaultArchiveWindowSec: ARCHIVE_MAX_SECONDS,\n    onError:",
        "player archive window duration",
    )
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
                const playbackUrl = archive.data.archiveHls || archive.data.hls_url || archive.data.playback_url;
                if (!playbackUrl) throw new Error('Hikvision archive response does not contain a playback URL');
                const responseStartMs = new Date(String(archive.data.start || '')).getTime();
                const responseEndMs = new Date(String(archive.data.end || '')).getTime();
                const preparedStartMs = Number.isFinite(responseStartMs) ? responseStartMs : startMs;
                const preparedEndMs = Number.isFinite(responseEndMs) && responseEndMs > preparedStartMs ? responseEndMs : endMs;
                latestRanges = mergeKnownRanges([...latestRanges, { startMs: preparedStartMs, endMs: preparedEndMs }]);
                // Force a full-retention refresh after playback starts. If it is
                // still temporarily unavailable, loadArchiveRanges returns this
                // provisional playback range instead of clearing the timeline.
                rangesLoadedAt = 0;
                return { url: playbackUrl, startMs: preparedStartMs, endMs: preparedEndMs };'''
    text = replace_once(text, old_archive, new_archive, "retry archive session and expose actual window")
    path.write_text(text, encoding="utf-8")


def patch_player_kit(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "lastKnownArchiveTimeMs=null;async mount()",
        "lastKnownArchiveTimeMs=null;timelineOverviewInitialized=!1;async mount()",
        "timeline overview state",
    )
    text = replace_once(
        text,
        'this.mode="live",this.currentArchiveWindow=null,',
        'this.mode="live",this.timelineOverviewInitialized=!1,this.currentArchiveWindow=null,',
        "reset archive overview on live",
    )

    old_play_archive = 'async playArchive(e){if(!this.caps.archive||!this.bootstrapData.archive?.buildUrl)return;const t=++this.archiveLoadSeq,i=this.config.autoplay||this.userWantsPlayback||!this.video.paused,s=this.config.defaultArchiveWindowSec??3600,n=e-Math.floor(s*1e3/2),r=Math.floor(n/1e3),o=await this.bootstrapData.archive.buildUrl(r,s);this.mode="archive",this.pendingArchiveSeekMs=e,this.root.dataset.mode="archive",this.syncNativeVideoControls(),this.updateCurrentModeButtons(),this.updateControlsVisibility(),this.updateDownloadButton();const d={startMs:n,endMs:n+s*1e3},l=await this.resolveArchiveManifestTiming(o,t);if(t!==this.archiveLoadSeq||this.abort.signal.aborted)return;const h=l??d;this.loadedArchiveMediaWindow=h,this.archiveMediaBaseMs=h.startMs,this.currentArchiveWindow={...h};const c=e>=h.startMs&&e<=h.endMs?e:h.startMs;this.timeline.setWindow(this.currentArchiveWindow.startMs,this.currentArchiveWindow.endMs),this.timeline.setCurrentTime(c),this.updateDateInput(c),this.pendingArchiveSeekMs=c,this.refreshOptionalForWindow(this.currentArchiveWindow.startMs,this.currentArchiveWindow.endMs);const u=this.hls.load(o);await this.waitForMediaReady(t,u,1e4),!(t!==this.archiveLoadSeq||this.abort.signal.aborted)&&(this.tryApplyPendingArchiveSeek(),this.updateDownloadButton(),i&&await this.safePlay(t,u),this.notifyState())}'
    new_play_archive = 'async playArchive(e){if(!this.caps.archive||!this.bootstrapData.archive?.buildUrl)return;const t=++this.archiveLoadSeq,i=this.config.autoplay||this.userWantsPlayback||!this.video.paused,s=this.config.defaultArchiveWindowSec??300,n=e-Math.floor(s*1e3/2),r=Math.floor(n/1e3),a=await this.bootstrapData.archive.buildUrl(r,s),o=typeof a==="string"?a:a?.url??a?.hlsUrl??a?.playbackUrl;if(!o)throw new Error("Archive adapter did not return a playback URL");const d=typeof a==="object"&&Number.isFinite(Number(a?.startMs))&&Number.isFinite(Number(a?.endMs))&&Number(a.endMs)>Number(a.startMs)?{startMs:Number(a.startMs),endMs:Number(a.endMs)}:null;this.mode="archive",this.pendingArchiveSeekMs=e,this.root.dataset.mode="archive",this.syncNativeVideoControls(),this.updateCurrentModeButtons(),this.updateControlsVisibility(),this.updateDownloadButton();const l=d??{startMs:n,endMs:n+s*1e3},h=d?null:await this.resolveArchiveManifestTiming(o,t);if(t!==this.archiveLoadSeq||this.abort.signal.aborted)return;const c=h??l;this.loadedArchiveMediaWindow=c,this.archiveMediaBaseMs=c.startMs,this.currentArchiveWindow={...c};const u=Math.max(c.startMs,Math.min(c.endMs-250,e));this.ranges=[...this.ranges,{startMs:c.startMs,endMs:c.endMs}].filter(f=>Number.isFinite(f.startMs)&&Number.isFinite(f.endMs)&&f.endMs>f.startMs).sort((f,g)=>f.startMs-g.startMs),this.timeline.setArchiveRanges(this.ranges);if(!this.timelineOverviewInitialized&&this.ranges.length){const f=Math.min(...this.ranges.map(g=>g.startMs)),g=Math.max(...this.ranges.map(y=>y.endMs));Number.isFinite(f)&&Number.isFinite(g)&&g>f&&(this.timeline.setWindow(f,g),g-f>c.endMs-c.startMs+2e3&&(this.timelineOverviewInitialized=!0))}this.timeline.setCurrentTime(u),this.updateDateInput(u),this.pendingArchiveSeekMs=u,this.refreshOptionalForWindow(this.currentArchiveWindow.startMs,this.currentArchiveWindow.endMs);const p=this.hls.load(o);await this.waitForMediaReady(t,p,1e4),!(t!==this.archiveLoadSeq||this.abort.signal.aborted)&&(this.tryApplyPendingArchiveSeek(),this.updateDownloadButton(),i&&await this.safePlay(t,p),this.notifyState())}'
    text = replace_once(text, old_play_archive, new_play_archive, "actual archive session window")

    old_refresh_ranges = 'async refreshRanges(e){try{const t=await this.bootstrapData.archive?.loadRanges?.(e??this.abort.signal);t&&(this.ranges=t,this.timeline.setArchiveRanges(t))}catch(t){if(e?.aborted||this.abort.signal.aborted)return;this.caps.archiveGaps=!1,this.timeline.setArchiveRanges([]),this.handleError(t,"archive-ranges")}}'
    new_refresh_ranges = 'async refreshRanges(e){try{const t=await this.bootstrapData.archive?.loadRanges?.(e??this.abort.signal);if(t){this.ranges=t,this.caps.archiveGaps=!0,this.timeline.setArchiveRanges(t);if(this.mode==="archive"&&!this.timelineOverviewInitialized&&t.length){const i=Math.min(...t.map(s=>s.startMs)),s=Math.max(...t.map(n=>n.endMs));Number.isFinite(i)&&Number.isFinite(s)&&s>i&&(this.timeline.setWindow(i,s),this.timelineOverviewInitialized=!0)}}}catch(t){if(e?.aborted||this.abort.signal.aborted)return;this.logger.warn("archive-ranges",t)}}'
    text = replace_once(text, old_refresh_ranges, new_refresh_ranges, "preserve and expand archive timeline")

    old_seek = 'tryApplyPendingArchiveSeek(){const e=this.loadedArchiveMediaWindow??this.currentArchiveWindow;if(this.pendingArchiveSeekMs==null||this.mode!=="archive"||!e||!this.video)return;const t=this.archiveMediaBaseMs??e.startMs,i=(this.pendingArchiveSeekMs-t)/1e3,s=Math.max(0,(e.endMs-e.startMs)/1e3),n=Number.isFinite(this.video.duration)&&this.video.duration>0?this.video.duration:s,r=n>.5?n-.35:n,o=Math.max(0,Math.min(r,i));if(!(this.video.readyState<HTMLMediaElement.HAVE_METADATA||!Number.isFinite(n)||n<=0))try{(!Number.isFinite(this.video.currentTime)||Math.abs(this.video.currentTime-o)>.18)&&(this.video.currentTime=o);const d=t+o*1e3;this.pendingArchiveSeekMs=null,this.lastKnownArchiveTimeMs=d,this.timeline.setCurrentTime(d),this.updateDateInput(d)}catch{}}'
    new_seek = 'tryApplyPendingArchiveSeek(){const e=this.loadedArchiveMediaWindow??this.currentArchiveWindow;if(this.pendingArchiveSeekMs==null||this.mode!=="archive"||!e||!this.video)return;const t=this.archiveMediaBaseMs??e.startMs,i=(this.pendingArchiveSeekMs-t)/1e3,s=Math.max(0,(e.endMs-e.startMs)/1e3),n=Number.isFinite(this.video.duration)&&this.video.duration>0?this.video.duration:s;if(Number.isFinite(n)&&n>0&&i>n-.35&&n+1<s)return;const r=n>.5?n-.35:n,o=Math.max(0,Math.min(r,i));if(!(this.video.readyState<HTMLMediaElement.HAVE_METADATA||!Number.isFinite(n)||n<=0))try{(!Number.isFinite(this.video.currentTime)||Math.abs(this.video.currentTime-o)>.18)&&(this.video.currentTime=o);const d=t+o*1e3;this.pendingArchiveSeekMs=null,this.lastKnownArchiveTimeMs=d,this.timeline.setCurrentTime(d),this.updateDateInput(d)}catch{}}'
    text = replace_once(text, old_seek, new_seek, "keep pending seek while archive playlist grows")
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=".")
    parser.add_argument("--backend-only", action="store_true")
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    patch_backend(root / "backend/src/routes/hikvisionPlayer.ts")
    if not args.backend_only:
        patch_frontend(root / "frontend/src/views/HikvisionPlayerView.vue")
        patch_player_kit(root / "frontend/public/player-kit/newdomofon-player.iife.js")
    print("Hikvision live/archive retries, exact session windows and timeline recovery prepared")


if __name__ == "__main__":
    main()

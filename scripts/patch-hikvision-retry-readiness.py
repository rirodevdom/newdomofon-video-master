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
        '''                if (!archive) throw archiveError || new Error('Не удалось подготовить архивный фрагмент Hikvision');
                latestRanges = mergeKnownRanges([...latestRanges, { startMs, endMs }]);
                // Force a full-retention refresh after playback starts. If it is
                // still temporarily unavailable, loadArchiveRanges returns this
                // provisional playback range instead of clearing the timeline.
                rangesLoadedAt = 0;
                return archive.data.archiveHls || archive.data.hls_url || archive.data.playback_url;''',
        '''                if (!archive) throw archiveError || new Error('Не удалось подготовить архивный фрагмент Hikvision');
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
                return { url: playbackUrl, startMs: preparedStartMs, endMs: preparedEndMs };''',
        "archive adapter returns actual session window",
    )
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

    old_refresh_ranges = 'async refreshRanges(e){try{const t=await this.bootstrapData.archive?.loadRanges?.(e??this.abort.signal);t&&(this.ranges=t,this.caps.archiveGaps=!0,this.timeline.setArchiveRanges(t))}catch(t){if(e?.aborted||this.abort.signal.aborted)return;this.logger.warn("archive-ranges",t)}}'
    new_refresh_ranges = 'async refreshRanges(e){try{const t=await this.bootstrapData.archive?.loadRanges?.(e??this.abort.signal);if(t){this.ranges=t,this.caps.archiveGaps=!0,this.timeline.setArchiveRanges(t);if(this.mode==="archive"&&!this.timelineOverviewInitialized&&t.length){const i=Math.min(...t.map(s=>s.startMs)),s=Math.max(...t.map(n=>n.endMs));Number.isFinite(i)&&Number.isFinite(s)&&s>i&&(this.timeline.setWindow(i,s),this.timelineOverviewInitialized=!0)}}}catch(t){if(e?.aborted||this.abort.signal.aborted)return;this.logger.warn("archive-ranges",t)}}'
    text = replace_once(text, old_refresh_ranges, new_refresh_ranges, "expand timeline after archive ranges load")

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
    print("Hikvision archive retries, exact session windows and timeline recovery prepared")


if __name__ == "__main__":
    main()

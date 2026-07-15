#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1), True


def patch_gateway(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    marker = "  const archivePlaylist = mediaPath === 'archive.m3u8' ||\n"
    block = """  if (mediaPath === 'archive/ranges') {
    const startRaw = reqUrl.searchParams.get('start');
    const endRaw = reqUrl.searchParams.get('end');
    const startMs = Date.parse(String(startRaw || ''));
    const endMs = Date.parse(String(endRaw || ''));
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs) {
      sendJson(res, 400, { error: 'Invalid start/end' }, {
        'x-newdomofon-resolved-stream': stream,
        'x-newdomofon-smartyard-route': 'node-archive-ranges'
      });
      return true;
    }
    const path = `/cameras/${encodeURIComponent(stream)}/archive/ranges?start=${encodeURIComponent(new Date(startMs).toISOString())}&end=${encodeURIComponent(new Date(endMs).toISOString())}&${queryToken(context.upstream_token)}`;
    const response = await nodeFetch(context, path, req, 30000);
    await sendNodeResponse(req, res, response, stream, externalToken, 'node-archive-ranges');
    return true;
  }

"""
    if "'node-archive-ranges'" in text:
        return False
    if marker not in text:
        raise RuntimeError(f"archive playlist marker not found in {path}")
    text = text.replace(marker, block + marker, 1)
    path.write_text(text, encoding="utf-8")
    return True


def patch_player(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")

    # The v2 seek patch supersedes the first playback-window implementation.
    # Do not try to match and replace the older fragments after v2 is installed.
    if (
        "rawRequestedSeekMs = requestedWindowStartMs + requestedWindowDurationMs / 2" in text
        and "archiveSeekAbortController" in text
    ):
        return False

    changed = False

    old_seek = """                const requestedWindowStartMs = fromEpochSec * 1000;
                const requestedSeekMs = requestedWindowStartMs + durationSec * 500;
                let effectiveStartMs = requestedSeekMs;
                let matchingRange = latestArchiveRanges.find((range) => range.startMs <= requestedSeekMs && range.endMs > requestedSeekMs);
"""
    new_seek = """                const nowMs = Date.now();
                const requestedWindowStartMs = fromEpochSec * 1000;
                const requestedSeekMs = Math.min(requestedWindowStartMs, nowMs - 1000);
                let effectiveStartMs = requestedSeekMs;
                if (!latestArchiveRanges.length) {
                  await loadArchiveRanges(true).catch(() => []);
                }
                let matchingRange = latestArchiveRanges.find((range) => range.startMs <= requestedSeekMs && range.endMs > requestedSeekMs);
"""
    text, did_change = replace_once(text, old_seek, new_seek, "archive requested window")
    changed = changed or did_change

    old_future = """                if (requestedSeekMs > Date.now() + 60_000) {
                  throw new Error('Выбранное время ещё не записано в архив');
                }
"""
    new_future = """                if (requestedWindowStartMs > nowMs + 60_000) {
                  throw new Error('Выбранное время ещё не записано в архив');
                }
"""
    text, did_change = replace_once(text, old_future, new_future, "future archive guard")
    changed = changed or did_change

    old_end = """                const requestedDuration = Math.max(1, Math.min(Math.max(durationSec, minRequestedDuration), maxAvailableDuration, maxRequestedDuration));
                const end = new Date(effectiveStartMs + requestedDuration * 1000).toISOString();
                const archive = await api.get(`/player/${encodeURIComponent(id)}/archive`, {
"""
    new_end = """                const requestedDuration = Math.max(1, Math.min(Math.max(durationSec, minRequestedDuration), maxAvailableDuration, maxRequestedDuration));
                const latestAllowedEndMs = matchingRange ? matchingRange.endMs : nowMs - 1000;
                const effectiveEndMs = Math.min(effectiveStartMs + requestedDuration * 1000, latestAllowedEndMs);
                if (effectiveEndMs <= effectiveStartMs) {
                  throw new Error('В выбранной точке ещё нет завершённого архивного фрагмента');
                }
                const end = new Date(effectiveEndMs).toISOString();
                const archive = await api.get(`/player/${encodeURIComponent(id)}/archive`, {
"""
    text, did_change = replace_once(text, old_end, new_end, "archive end clamp")
    changed = changed or did_change

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    root = Path(args.project_dir).resolve()
    gateway = root / "smartyard-compat-proxy/server-node-aware.js"
    player = root / "frontend/src/views/PlayerView.vue"
    if not gateway.is_file() or not player.is_file():
        raise SystemExit(f"Expected gateway and PlayerView sources under {root}")

    changed: list[str] = []
    if patch_gateway(gateway):
        changed.append(str(gateway.relative_to(root)))
    if patch_player(player):
        changed.append(str(player.relative_to(root)))

    print("Archive playback window patch applied")
    if changed:
        for item in changed:
            print(f"  changed: {item}")
    else:
        print("  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

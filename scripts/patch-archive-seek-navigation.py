#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1), True


def patch_player(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    old_state = "let archiveBuildLock: Promise<string> | null = null;"
    new_state = """let archiveSeekGeneration = 0;
let archiveSeekAbortController: AbortController | null = null;"""
    text, did_change = replace_once(text, old_state, new_state, "archive seek state")
    changed = changed or did_change

    old_destroy = """function destroyPlayer() {
  archivePreparing.value = false;
  archiveBuildLock = null;
  player?.destroy();
"""
    new_destroy = """function destroyPlayer() {
  archiveSeekGeneration += 1;
  archiveSeekAbortController?.abort();
  archiveSeekAbortController = null;
  archivePreparing.value = false;
  player?.destroy();
"""
    text, did_change = replace_once(text, old_destroy, new_destroy, "archive seek cleanup")
    changed = changed or did_change

    old_error = """    onError: (err: unknown, context?: string) => {
      error.value = `${context ? `${context}: ` : ''}${err instanceof Error ? err.message : String(err)}`;
    },
"""
    new_error = """    onError: (err: unknown, context?: string) => {
      const candidate = err as { name?: string; code?: string } | null;
      if (candidate?.name === 'AbortError' || candidate?.name === 'CanceledError' || candidate?.code === 'ERR_CANCELED') return;
      error.value = `${context ? `${context}: ` : ''}${err instanceof Error ? err.message : String(err)}`;
    },
"""
    text, did_change = replace_once(text, old_error, new_error, "archive cancellation error suppression")
    changed = changed or did_change

    build_pattern = re.compile(
        r"            buildUrl: async \(fromEpochSec: number, durationSec: number\) => \{\n"
        r"[\s\S]*?"
        r"\n            \},\n"
        r"            ranges:",
        re.MULTILINE,
    )

    new_build = """            buildUrl: async (fromEpochSec: number, durationSec: number) => {
              const requestGeneration = ++archiveSeekGeneration;
              archiveSeekAbortController?.abort();
              const controller = new AbortController();
              archiveSeekAbortController = controller;
              archivePreparing.value = true;

              try {
                const nowMs = Date.now();
                const requestedWindowStartMs = fromEpochSec * 1000;
                const requestedWindowDurationMs = Math.max(1, Number(durationSec) || 1) * 1000;

                // The external player asks for a window centred on the point the
                // user selected. Treating fromEpochSec as the selected point moves
                // every seek backwards by half of that window.
                const rawRequestedSeekMs = requestedWindowStartMs + requestedWindowDurationMs / 2;
                if (rawRequestedSeekMs > nowMs + 60_000) {
                  throw new Error('Выбранное время ещё не записано в архив');
                }

                const requestedSeekMs = Math.min(rawRequestedSeekMs, nowMs - 1000);
                if (!latestArchiveRanges.length) {
                  await loadArchiveRanges(true).catch(() => []);
                }

                const selectedArchiveSource = archiveSource.value;
                const useDeviceArchive = selectedArchiveSource === 'device' || (selectedArchiveSource === 'auto' && currentArchiveStorage !== 'node');
                const minPlayMs = (useDeviceArchive ? DEVICE_ARCHIVE_MIN_PLAY_SECONDS : NODE_ARCHIVE_MIN_PLAY_SECONDS) * 1000;
                let targetSeekMs = requestedSeekMs;
                let matchingRange = latestArchiveRanges.find((range) => range.startMs <= targetSeekMs && range.endMs > targetSeekMs);

                if (latestArchiveRanges.length && !matchingRange) {
                  const nextRange = latestArchiveRanges.find((range) => range.startMs > targetSeekMs);
                  const previousRange = [...latestArchiveRanges].reverse().find((range) => range.endMs <= targetSeekMs);
                  const isLiveEdgeRequest = targetSeekMs >= nowMs - ARCHIVE_LIVE_EDGE_FALLBACK_SECONDS * 1000;

                  if (nextRange) {
                    matchingRange = nextRange;
                    targetSeekMs = nextRange.startMs;
                    error.value = 'В выбранной точке архива нет, открыт следующий доступный фрагмент';
                  } else if (isLiveEdgeRequest && previousRange) {
                    matchingRange = previousRange;
                    targetSeekMs = Math.max(previousRange.startMs, Math.min(targetSeekMs, previousRange.endMs - 1000));
                    error.value = '';
                  } else {
                    throw new Error('В выбранной точке архива нет');
                  }
                }

                let effectiveStartMs = matchingRange
                  ? Math.max(matchingRange.startMs, targetSeekMs - ARCHIVE_SEEK_PREROLL_SECONDS * 1000)
                  : Math.max(0, targetSeekMs - ARCHIVE_SEEK_PREROLL_SECONDS * 1000);

                if (useDeviceArchive && matchingRange && matchingRange.endMs - effectiveStartMs < minPlayMs && matchingRange.endMs - matchingRange.startMs >= minPlayMs) {
                  effectiveStartMs = Math.max(matchingRange.startMs, matchingRange.endMs - minPlayMs);
                }

                const maxAvailableDuration = matchingRange
                  ? Math.max(1, Math.floor((matchingRange.endMs - effectiveStartMs) / 1000))
                  : Math.max(1, durationSec);
                const minRequestedDuration = useDeviceArchive ? DEVICE_ARCHIVE_MIN_PLAY_SECONDS : NODE_ARCHIVE_MIN_PLAY_SECONDS;
                const maxRequestedDuration = useDeviceArchive ? 300 : NODE_ARCHIVE_MAX_PLAY_SECONDS;
                const requestedDuration = Math.max(1, Math.min(Math.max(durationSec, minRequestedDuration), maxAvailableDuration, maxRequestedDuration));
                const latestAllowedEndMs = Math.min(matchingRange?.endMs ?? nowMs - 1000, nowMs - 1000);
                const effectiveEndMs = Math.min(effectiveStartMs + requestedDuration * 1000, latestAllowedEndMs);

                if (effectiveEndMs <= effectiveStartMs) {
                  throw new Error('В выбранной точке ещё нет завершённого архивного фрагмента');
                }

                const archive = await api.get(`/player/${encodeURIComponent(id)}/archive`, {
                  params: {
                    start: new Date(effectiveStartMs).toISOString(),
                    end: new Date(effectiveEndMs).toISOString(),
                    source: selectedArchiveSource
                  },
                  signal: controller.signal
                });

                if (requestGeneration !== archiveSeekGeneration) {
                  throw new DOMException('Archive seek superseded', 'AbortError');
                }

                return archive.data.archiveHls || archive.data.hls_url || archive.data.playback_url;
              } catch (err: any) {
                if (controller.signal.aborted || requestGeneration !== archiveSeekGeneration || err?.code === 'ERR_CANCELED') {
                  throw new DOMException('Archive seek superseded', 'AbortError');
                }
                throw err;
              } finally {
                if (requestGeneration === archiveSeekGeneration) {
                  archiveSeekAbortController = null;
                  archivePreparing.value = false;
                }
              }
            },
            ranges:"""

    if "const rawRequestedSeekMs = requestedWindowStartMs + requestedWindowDurationMs / 2;" not in text:
        text, count = build_pattern.subn(new_build, text, count=1)
        if count != 1:
            raise RuntimeError("archive buildUrl function was not found")
        changed = True

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    root = Path(args.project_dir).resolve()
    player = root / "frontend/src/views/PlayerView.vue"
    if not player.is_file():
        raise SystemExit(f"PlayerView source not found: {player}")

    changed = patch_player(player)
    print("Archive seek navigation patch applied")
    print(f"  {'changed' if changed else 'already up to date'}: {player.relative_to(root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

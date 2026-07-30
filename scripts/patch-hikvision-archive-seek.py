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
    old = '''                if (!latestRanges.length) await loadArchiveRanges();
                const requestedMs = fromEpochSec * 1000 + Math.max(1, durationSec) * 500;
                let range = latestRanges.find((item) => item.startMs <= requestedMs && item.endMs > requestedMs);
                if (!range) {
                  range = latestRanges.find((item) => item.startMs > requestedMs)
                    || [...latestRanges].reverse().find((item) => item.endMs <= requestedMs);
                }
                if (!range) throw new Error('В выбранном периоде архив не найден');
                const startMs = Math.max(range.startMs, Math.min(requestedMs, range.endMs - 1000) - 10_000);
                const seconds = Math.max(1, Math.min(Math.max(durationSec, ARCHIVE_MIN_SECONDS), ARCHIVE_MAX_SECONDS));
                const endMs = Math.min(range.endMs, startMs + seconds * 1000, Date.now() - 1000);
                if (endMs <= startMs) throw new Error('Архивный фрагмент ещё не завершён');'''
    new = '''                const requestedMs = fromEpochSec * 1000 + Math.max(1, durationSec) * 500;
                const seconds = Math.max(1, Math.min(Math.max(durationSec, ARCHIVE_MIN_SECONDS), ARCHIVE_MAX_SECONDS));
                let startMs = requestedMs - 10_000;
                let endMs = Math.min(startMs + seconds * 1000, Date.now() - 1000);

                // Archive ranges are an optional timeline layer. Never block a
                // concrete archive request on a full-retention range scan.
                if (latestRanges.length) {
                  const range = latestRanges.find((item) => item.startMs <= requestedMs && item.endMs > requestedMs)
                    || latestRanges.find((item) => item.startMs > requestedMs)
                    || [...latestRanges].reverse().find((item) => item.endMs <= requestedMs);
                  if (range) {
                    startMs = Math.max(range.startMs, Math.min(requestedMs, range.endMs - 1000) - 10_000);
                    endMs = Math.min(range.endMs, startMs + seconds * 1000, Date.now() - 1000);
                  }
                }

                if (endMs <= startMs) throw new Error('Архивный фрагмент ещё не завершён');'''
    text = replace_once(text, old, new, "nonblocking Hikvision archive seek")
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=".")
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    patch_frontend(root / "frontend/src/views/HikvisionPlayerView.vue")
    print("Hikvision archive seek no longer waits for full range loading")


if __name__ == "__main__":
    main()

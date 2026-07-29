#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


REQUIRED_MARKERS = (
    "let archiveSeekGeneration = 0;",
    "let archiveSeekAbortController: AbortController | null = null;",
    "const rawRequestedSeekMs = requestedWindowStartMs + requestedWindowDurationMs / 2;",
    "source: 'node'",
    "NODE_ARCHIVE_MIN_PLAY_SECONDS",
)

FORBIDDEN_MARKERS = (
    "DEVICE_ARCHIVE_MIN_PLAY_SECONDS",
    "useDeviceArchive",
    "archiveSource.value",
    "currentArchiveStorage",
)


def validate_player(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    missing = [marker for marker in REQUIRED_MARKERS if marker not in text]
    forbidden = [marker for marker in FORBIDDEN_MARKERS if marker in text]
    if missing or forbidden:
        details = []
        if missing:
            details.append(f"missing={missing}")
        if forbidden:
            details.append(f"forbidden={forbidden}")
        raise RuntimeError(f"PlayerView node-only archive seek validation failed: {'; '.join(details)}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    root = Path(args.project_dir).resolve()
    player = root / "frontend/src/views/PlayerView.vue"
    if not player.is_file():
        raise SystemExit(f"PlayerView source not found: {player}")

    validate_player(player)
    print("Archive seek navigation is node-only and already prepared")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

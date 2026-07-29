#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path

PROJECT_DIR = Path(os.environ.get("PROJECT_DIR", Path(__file__).resolve().parents[1])).resolve()
ENV_FILE = Path(os.environ.get("ENV_FILE", "/etc/newdomofon-video/app.env"))

REMOVED_PREFIXES = (
    "DVR_HIKVISION_",
    "DVR_DEVICE_ARCHIVE_",
    "DEVICE_ARCHIVE_",
)
REMOVED_DIST_FILES = (
    "backend/dist/services/hikvisionChannels.js",
    "backend/dist/services/hikvisionChannels.js.map",
)


def clean_env(path: Path) -> None:
    if not path.is_file():
        return
    original = path.read_text(encoding="utf-8").splitlines()
    kept: list[str] = []
    removed: list[str] = []
    for line in original:
        stripped = line.strip()
        key = stripped.split("=", 1)[0].strip() if "=" in stripped else ""
        if any(key.startswith(prefix) for prefix in REMOVED_PREFIXES):
            removed.append(key)
            continue
        kept.append(line)
    if removed:
        path.write_text("\n".join(kept).rstrip() + "\n", encoding="utf-8")
        print(f"Removed obsolete Hikvision env keys from {path}: {', '.join(sorted(set(removed)))}")


def clean_dist() -> None:
    for relative in REMOVED_DIST_FILES:
        target = PROJECT_DIR / relative
        if target.exists():
            target.unlink()
            print(f"Removed legacy compiled module: {target}")


def main() -> int:
    clean_env(ENV_FILE)
    clean_dist()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

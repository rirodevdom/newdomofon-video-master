#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "newdomofon-smartyard-direct-live-snapshot"


def replace_once(text: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    if old not in text:
        raise RuntimeError(f"{label} anchor was not found")
    return text.replace(old, new, 1), True


def patch_preview(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    if "async function fetchLiveSnapshotPreview(context, stream, outputFile)" not in text:
        raise RuntimeError("live snapshot fallback must be applied first")
    if "newdomofon-smartyard-stale-while-revalidate" not in text:
        raise RuntimeError("stale preview refresh must be applied first")

    constant = f"const DIRECT_LIVE_SNAPSHOT_MARKER = '{MARKER}';\n"
    if constant not in text:
        anchor = "const PREVIEW_STALE_REFRESH_MARKER = 'newdomofon-smartyard-stale-while-revalidate';\n"
        if anchor not in text:
            raise RuntimeError("stale preview marker anchor was not found")
        text = text.replace(anchor, anchor + constant, 1)
        changed = True

    old_fetch_start = """async function fetchPreview(context, stream, targetSec, outputFile) {
  const range = await loadRange(context, stream, targetSec);
  // A newly added camera can have a healthy live stream before its first archive
  // segment is finalized. SmartYard still expects preview.mp4 immediately.
  if (!range && targetSec <= 0) {
    return fetchLiveSnapshotPreview(context, stream, outputFile);
  }
  const window = previewWindow(range, targetSec);
"""
    new_fetch_start = """async function fetchPreview(context, stream, targetSec, outputFile) {
  // Live SmartYard preview is a thumbnail, not archive playback. Going through
  // archive/ranges -> export.mp4 -> FFmpeg made a cold preview take several
  // seconds. Ask the node for its current JPEG first and convert that single
  // frame directly. Timestamp previews keep the archive path below.
  if (targetSec <= 0) {
    try {
      return await fetchLiveSnapshotPreview(context, stream, outputFile);
    } catch (snapshotError) {
      console.warn(`[preview] direct live snapshot failed stream=${stream}; falling back to archive export: ${String(snapshotError?.message || snapshotError)}`);
    }
  }

  const range = await loadRange(context, stream, targetSec);
  const window = previewWindow(range, targetSec);
"""
    text, did = replace_once(text, old_fetch_start, new_fetch_start, "direct live snapshot cold path")
    changed = changed or did

    old_encode = """      '-frames:v', '1',
      '-r', '1',
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-crf', '28',
"""
    new_encode = """      '-vf', 'scale=640:-2',
      '-frames:v', '1',
      '-r', '1',
      '-c:v', 'libx264',
      '-preset', 'ultrafast',
      '-crf', '30',
"""
    text, did = replace_once(text, old_encode, new_encode, "thumbnail-sized H.264 encoding")
    changed = changed or did

    old_mode = """    'x-newdomofon-preview-mode': `${STILL_PREVIEW_MARKER};${LIVE_SNAPSHOT_FALLBACK_MARKER};${PREVIEW_STALE_REFRESH_MARKER}`
"""
    new_mode = """    'x-newdomofon-preview-mode': `${STILL_PREVIEW_MARKER};${LIVE_SNAPSHOT_FALLBACK_MARKER};${PREVIEW_STALE_REFRESH_MARKER};${DIRECT_LIVE_SNAPSHOT_MARKER}`
"""
    text, did = replace_once(text, old_mode, new_mode, "direct snapshot response marker")
    changed = changed or did

    required = (
        f"const DIRECT_LIVE_SNAPSHOT_MARKER = '{MARKER}';",
        "return await fetchLiveSnapshotPreview(context, stream, outputFile);",
        "falling back to archive export",
        "'-vf', 'scale=640:-2'",
        "'-preset', 'ultrafast'",
        "DIRECT_LIVE_SNAPSHOT_MARKER",
    )
    for item in required:
        if item not in text:
            raise RuntimeError(f"fast cold preview marker missing: {item}")

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    project = Path(args.project_dir).resolve()
    preview = project / "smartyard-compat-proxy" / "server-preview-gateway.js"
    if not preview.is_file():
        raise SystemExit(f"SmartYard preview gateway source not found: {preview}")

    changed = patch_preview(preview)
    print("SmartYard direct live snapshot preview prepared")
    print("  changed: smartyard-compat-proxy/server-preview-gateway.js" if changed else "  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

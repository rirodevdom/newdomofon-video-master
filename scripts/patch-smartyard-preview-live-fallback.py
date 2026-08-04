#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "newdomofon-smartyard-live-snapshot-fallback"


def replace_once(text: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    # Later runtime patchers may append their own preview-mode marker to the
    # same response header. Treat the live-fallback response patch as already
    # applied when that header still contains our interpolation marker.
    if label == "preview response mode":
        for line in text.splitlines():
            if "'x-newdomofon-preview-mode':" in line and "${LIVE_SNAPSHOT_FALLBACK_MARKER}" in line:
                return text, False
    if old not in text:
        raise RuntimeError(f"{label} anchor was not found")
    return text.replace(old, new, 1), True


def patch_preview(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    if "async function renderStillPreview(sourceFile, outputFile)" not in text:
        raise RuntimeError("still-preview compatibility must be applied first")

    constant = f"const LIVE_SNAPSHOT_FALLBACK_MARKER = '{MARKER}';\n"
    if constant not in text:
        anchor = "const STILL_PREVIEW_MARKER = 'newdomofon-smartyard-still-preview';\n"
        if anchor not in text:
            raise RuntimeError("still-preview marker anchor was not found")
        text = text.replace(anchor, anchor + constant, 1)
        changed = True

    helper = r'''async function fetchLiveSnapshotPreview(context, stream, outputFile) {
  const query = new URLSearchParams({ token: context.upstream_token });
  const response = await nodeFetch(
    context,
    `/cameras/${encodeURIComponent(stream)}/snapshot.jpg?${query.toString()}`,
    Math.min(EXPORT_TIMEOUT_MS, 20000)
  );
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 1000);
    throw new Error(`Node live snapshot failed (${response.status}): ${detail}`);
  }

  const contentLength = Number(response.headers.get('content-length') || 0);
  if (contentLength > MAX_BYTES) throw new Error('Node live snapshot exceeds size limit');
  const buffer = Buffer.from(await response.arrayBuffer());
  if (buffer.length < 256 || buffer.length > MAX_BYTES) throw new Error('Node live snapshot has invalid size');

  await fsp.mkdir(CACHE_DIR, { recursive: true });
  const nonce = `${process.pid}-${Date.now()}`;
  const source = `${outputFile}.source-${nonce}.jpg`;
  const tmp = `${outputFile}.tmp-${nonce}.mp4`;
  await fsp.writeFile(source, buffer, { mode: 0o640 });
  try {
    await renderStillPreview(source, tmp);
    await fsp.rename(tmp, outputFile);
  } finally {
    await fsp.unlink(source).catch(() => undefined);
    await fsp.unlink(tmp).catch(() => undefined);
  }
  return fsp.stat(outputFile);
}

'''
    if "async function fetchLiveSnapshotPreview(context, stream, outputFile)" not in text:
        anchor = "async function fetchPreview(context, stream, targetSec, outputFile) {\n"
        if anchor not in text:
            raise RuntimeError("preview fetch anchor was not found")
        text = text.replace(anchor, helper + anchor, 1)
        changed = True

    old_start = """async function fetchPreview(context, stream, targetSec, outputFile) {
  const range = await loadRange(context, stream, targetSec);
  const window = previewWindow(range, targetSec);
"""
    new_start = """async function fetchPreview(context, stream, targetSec, outputFile) {
  const range = await loadRange(context, stream, targetSec);
  // A newly added camera can have a healthy live stream before its first archive
  // segment is finalized. SmartYard still expects preview.mp4 immediately.
  if (!range && targetSec <= 0) {
    return fetchLiveSnapshotPreview(context, stream, outputFile);
  }
  const window = previewWindow(range, targetSec);
"""
    text, did = replace_once(text, old_start, new_start, "preview live fallback start")
    changed = changed or did

    old_error = """  if (!response.ok) {
    const detail = (await response.text()).slice(0, 1000);
    throw new Error(`Node preview export failed (${response.status}): ${detail}`);
  }
"""
    new_error = """  if (!response.ok) {
    // The newest archive range can race with segment finalization. For the live
    // preview only, use a current JPEG instead of surfacing a public HTTP 502.
    if (targetSec <= 0 && response.status === 404) {
      return fetchLiveSnapshotPreview(context, stream, outputFile);
    }
    const detail = (await response.text()).slice(0, 1000);
    throw new Error(`Node preview export failed (${response.status}): ${detail}`);
  }
"""
    text, did = replace_once(text, old_error, new_error, "preview export fallback")
    changed = changed or did

    old_mode = """    'x-newdomofon-preview-mode': STILL_PREVIEW_MARKER
"""
    new_mode = """    'x-newdomofon-preview-mode': `${STILL_PREVIEW_MARKER};${LIVE_SNAPSHOT_FALLBACK_MARKER}`
"""
    text, did = replace_once(text, old_mode, new_mode, "preview response mode")
    changed = changed or did

    required = (
        f"const LIVE_SNAPSHOT_FALLBACK_MARKER = '{MARKER}';",
        "async function fetchLiveSnapshotPreview(context, stream, outputFile)",
        "/snapshot.jpg?${query.toString()}",
        "if (!range && targetSec <= 0)",
        "targetSec <= 0 && response.status === 404",
        "LIVE_SNAPSHOT_FALLBACK_MARKER",
    )
    for item in required:
        if item not in text:
            raise RuntimeError(f"preview fallback marker missing: {item}")

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
    print("SmartYard live snapshot preview fallback prepared")
    print("  changed: smartyard-compat-proxy/server-preview-gateway.js" if changed else "  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

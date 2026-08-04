#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "newdomofon-smartyard-stale-while-revalidate"
DIRECT_MARKER = "newdomofon-smartyard-direct-live-snapshot"


def replace_once(text: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    # The fast-cold patch appends its marker to the already-installed preview
    # response header. On repeated clean-install passes the stale semantics are
    # still present even though the exact old/new multiline block changed.
    if label == "stale preview response route" and DIRECT_MARKER in text:
        for line in text.splitlines():
            if "'x-newdomofon-preview-mode':" in line and "${PREVIEW_STALE_REFRESH_MARKER}" in line:
                return text, False
    if old not in text:
        raise RuntimeError(f"{label} anchor was not found")
    return text.replace(old, new, 1), True


def patch_preview(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    if "async function fetchLiveSnapshotPreview(context, stream, outputFile)" not in text:
        raise RuntimeError("live snapshot fallback must be applied first")

    constants = f"""const LIVE_STALE_MAX_AGE_MS = Math.max(LIVE_CACHE_TTL_MS, Number(process.env.PREVIEW_LIVE_STALE_MAX_AGE_MS || 300000));
const PREVIEW_STALE_REFRESH_MARKER = '{MARKER}';
"""
    if f"const PREVIEW_STALE_REFRESH_MARKER = '{MARKER}';" not in text:
        anchor = "const LIVE_SNAPSHOT_FALLBACK_MARKER = 'newdomofon-smartyard-live-snapshot-fallback';\n"
        if anchor not in text:
            raise RuntimeError("live snapshot fallback marker anchor was not found")
        text = text.replace(anchor, anchor + constants, 1)
        changed = True

    camera_jobs = "const previewCameraTails = new Map();\n"
    if camera_jobs not in text:
        anchor = "const previewJobs = new Map();\n"
        if anchor not in text:
            raise RuntimeError("preview jobs anchor was not found")
        text = text.replace(anchor, anchor + camera_jobs, 1)
        changed = True

    helper = r'''async function staleLiveCache(filePath, targetSec) {
  if (targetSec > 0) return null;
  try {
    const stat = await fsp.stat(filePath);
    const ageMs = Date.now() - stat.mtimeMs;
    return stat.isFile() && stat.size > 256 && ageMs <= LIVE_STALE_MAX_AGE_MS ? stat : null;
  } catch {
    return null;
  }
}

function startPreviewJob(context, stream, targetSec, filePath) {
  const key = `${stream}:${targetSec}`;
  const existing = previewJobs.get(key);
  if (existing) return existing;

  // Serialize preview generation per camera. Different preview URLs for the
  // same camera can arrive together from SmartYard; they must not fan out into
  // multiple FFmpeg conversions against the same node/camera simultaneously.
  const previousTail = previewCameraTails.get(stream) || Promise.resolve();
  const job = previousTail
    .catch(() => undefined)
    .then(() => fetchPreview(context, stream, targetSec, filePath));
  const tail = job.catch(() => undefined);

  previewJobs.set(key, job);
  previewCameraTails.set(stream, tail);

  const cleanup = () => {
    if (previewJobs.get(key) === job) previewJobs.delete(key);
    if (previewCameraTails.get(stream) === tail) previewCameraTails.delete(stream);
  };
  job.then(cleanup, cleanup);
  return job;
}

'''
    if "function startPreviewJob(context, stream, targetSec, filePath)" not in text:
        anchor = "async function ensurePreview(context, stream, targetSec) {\n"
        if anchor not in text:
            raise RuntimeError("ensurePreview anchor was not found")
        text = text.replace(anchor, helper + anchor, 1)
        changed = True

    old_ensure = """async function ensurePreview(context, stream, targetSec) {
  const filePath = cacheFile(stream, targetSec);
  const cached = await validCache(filePath, targetSec);
  if (cached) return { filePath, stat: cached, cached: true };

  const key = `${stream}:${targetSec}`;
  if (!previewJobs.has(key)) {
    previewJobs.set(key, fetchPreview(context, stream, targetSec, filePath).finally(() => previewJobs.delete(key)));
  }
  const stat = await previewJobs.get(key);
  return { filePath, stat, cached: false };
}
"""
    new_ensure = """async function ensurePreview(context, stream, targetSec) {
  const filePath = cacheFile(stream, targetSec);
  const cached = await validCache(filePath, targetSec);
  if (cached) return { filePath, stat: cached, cached: true, stale: false };

  const stale = await staleLiveCache(filePath, targetSec);
  const job = startPreviewJob(context, stream, targetSec, filePath);
  if (stale) {
    // Stale-while-revalidate: SmartYard receives the last known good frame
    // immediately. Refresh continues in the background and atomically replaces
    // the cache file when the node/export/FFmpeg pipeline succeeds.
    job.catch((error) => {
      console.error(`[preview] background refresh failed stream=${stream}: ${String(error?.message || error)}`);
    });
    return { filePath, stat: stale, cached: true, stale: true };
  }

  const stat = await job;
  return { filePath, stat, cached: false, stale: false };
}
"""
    text, did = replace_once(text, old_ensure, new_ensure, "stale-while-revalidate ensurePreview")
    changed = changed or did

    old_route = """    'x-newdomofon-smartyard-route': preview.cached ? 'node-preview-still-cache' : 'node-preview-still',
    'x-newdomofon-preview-mode': `${STILL_PREVIEW_MARKER};${LIVE_SNAPSHOT_FALLBACK_MARKER}`
"""
    new_route = """    'x-newdomofon-smartyard-route': preview.stale
      ? 'node-preview-stale-refresh'
      : (preview.cached ? 'node-preview-still-cache' : 'node-preview-still'),
    'x-newdomofon-preview-mode': `${STILL_PREVIEW_MARKER};${LIVE_SNAPSHOT_FALLBACK_MARKER};${PREVIEW_STALE_REFRESH_MARKER}`
"""
    text, did = replace_once(text, old_route, new_route, "stale preview response route")
    changed = changed or did

    required = (
        f"const PREVIEW_STALE_REFRESH_MARKER = '{MARKER}';",
        "const previewCameraTails = new Map();",
        "async function staleLiveCache(filePath, targetSec)",
        "function startPreviewJob(context, stream, targetSec, filePath)",
        "const stale = await staleLiveCache(filePath, targetSec);",
        "job.catch((error) => {",
        "node-preview-stale-refresh",
        "PREVIEW_STALE_REFRESH_MARKER",
    )
    for item in required:
        if item not in text:
            raise RuntimeError(f"stale preview marker missing: {item}")

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
    print("SmartYard stale-while-revalidate preview prepared")
    print("  changed: smartyard-compat-proxy/server-preview-gateway.js" if changed else "  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

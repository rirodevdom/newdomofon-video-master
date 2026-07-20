#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

STILL_MARKER = "newdomofon-smartyard-still-preview"


def replace_once(text: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    if old not in text:
        raise RuntimeError(f"{label} anchor was not found")
    return text.replace(old, new, 1), True


def patch_node_aware(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    old_live = """  if (mediaPath === 'live.m3u8' || mediaPath === 'index.m3u8' || mediaPath === 'video.m3u8') {
    const path = `/cameras/${encodeURIComponent(stream)}/live.m3u8?${queryToken(context.upstream_token)}`;
"""
    new_live = """  const livePlaylist = /^(?:live|index|video)(?:\\.fmp4)?\\.m3u8$/i.test(mediaPath);
  if (livePlaylist) {
    const path = `/cameras/${encodeURIComponent(stream)}/live.m3u8?${queryToken(context.upstream_token)}`;
"""
    text, did = replace_once(text, old_live, new_live, "Flussonic live aliases")
    changed = changed or did

    old_archive = """  const archivePlaylist = mediaPath === 'archive.m3u8' ||
    /^(?:archive|index|video|mono)-\\d+-(?:now|\\d+)\\.m3u8$/i.test(mediaPath) ||
    /^timeshift_(?:abs|rel)-\\d+\\.m3u8$/i.test(mediaPath);
"""
    new_archive = """  const archivePlaylist = /^archive(?:\\.fmp4)?\\.m3u8$/i.test(mediaPath) ||
    /^(?:archive|index|video|mono)-\\d+-(?:now|\\d+)(?:\\.fmp4)?\\.m3u8$/i.test(mediaPath) ||
    /^timeshift_(?:abs|rel)-\\d+(?:\\.fmp4)?\\.m3u8$/i.test(mediaPath);
"""
    text, did = replace_once(text, old_archive, new_archive, "Flussonic archive aliases")
    changed = changed or did

    old_start = """  const fromRaw = Number(reqUrl.searchParams.get('from') || 0);
  const startMs = Number.isFinite(fromRaw) && fromRaw > 0
    ? fromRaw * 1000
    : Date.now() - DEFAULT_RANGE_DAYS * 24 * 3600_000;
  const endMs = Date.now();
"""
    new_start = """  const fromRaw = Number(reqUrl.searchParams.get('from') || 0);
  const endMs = Date.now();
  const oldestAllowedMs = endMs - DEFAULT_RANGE_DAYS * 24 * 3600_000;
  // SmartYard-Server asks Flussonic from a fixed 2018 timestamp. Never forward
  // that multi-year window to a node whose ranges endpoint is intentionally
  // bounded; clamp it to the configured compatibility horizon instead.
  const requestedStartMs = Number.isFinite(fromRaw) && fromRaw > 0
    ? fromRaw * 1000
    : oldestAllowedMs;
  const startMs = Math.max(oldestAllowedMs, Math.min(requestedStartMs, endMs - 1000));
"""
    text, did = replace_once(text, old_start, new_start, "recording_status range clamp")
    changed = changed or did

    required = (
        "const livePlaylist = /^(?:live|index|video)(?:\\.fmp4)?\\.m3u8$/i.test(mediaPath);",
        "(?:\\.fmp4)?\\.m3u8$/i.test(mediaPath)",
        "const oldestAllowedMs = endMs - DEFAULT_RANGE_DAYS * 24 * 3600_000;",
    )
    for marker in required:
        if marker not in text:
            raise RuntimeError(f"node-aware compatibility marker missing: {marker}")

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def patch_preview_gateway(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    import_line = "const { spawn } = require('node:child_process');\n"
    if import_line not in text:
        anchor = "const fs = require('node:fs');\n"
        if anchor not in text:
            raise RuntimeError("preview child_process import anchor was not found")
        text = text.replace(anchor, anchor + import_line, 1)
        changed = True

    constants = f"""const PREVIEW_FFMPEG = String(process.env.SMARTYARD_PREVIEW_FFMPEG || process.env.FFMPEG_PATH || '/usr/bin/ffmpeg');
const STILL_PREVIEW_TIMEOUT_MS = Math.max(3000, Number(process.env.SMARTYARD_STILL_PREVIEW_TIMEOUT_MS || 20000));
const STILL_PREVIEW_MARKER = '{STILL_MARKER}';
"""
    if f"const STILL_PREVIEW_MARKER = '{STILL_MARKER}';" not in text:
        anchor = "const EXPORT_TIMEOUT_MS = Math.max(5000, Number(process.env.PREVIEW_EXPORT_TIMEOUT_MS || 60000));\n"
        if anchor not in text:
            raise RuntimeError("preview constants anchor was not found")
        text = text.replace(anchor, anchor + constants, 1)
        changed = True

    helper = r'''async function renderStillPreview(sourceFile, outputFile) {
  await new Promise((resolve, reject) => {
    const child = spawn(PREVIEW_FFMPEG, [
      '-hide_banner',
      '-loglevel', 'error',
      '-nostdin',
      '-y',
      '-i', sourceFile,
      '-map', '0:v:0',
      '-an',
      '-frames:v', '1',
      '-r', '1',
      '-c:v', 'libx264',
      '-preset', 'veryfast',
      '-crf', '28',
      '-pix_fmt', 'yuv420p',
      '-movflags', '+faststart',
      outputFile
    ], { stdio: ['ignore', 'ignore', 'pipe'] });

    let stderr = '';
    let settled = false;
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve();
    };
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      finish(new Error('Still preview conversion timed out'));
    }, STILL_PREVIEW_TIMEOUT_MS);

    child.stderr.on('data', (chunk) => {
      if (stderr.length < 4000) stderr += String(chunk);
    });
    child.once('error', finish);
    child.once('close', (code) => {
      if (code !== 0) {
        finish(new Error(`Still preview conversion failed (code=${code}): ${stderr.trim().slice(0, 1000)}`));
        return;
      }
      finish();
    });
  });
}

'''
    if "async function renderStillPreview(sourceFile, outputFile)" not in text:
        anchor = "async function fetchPreview(context, stream, targetSec, outputFile) {\n"
        if anchor not in text:
            raise RuntimeError("preview render helper anchor was not found")
        text = text.replace(anchor, helper + anchor, 1)
        changed = True

    old_write = """  await fsp.mkdir(CACHE_DIR, { recursive: true });
  const tmp = `${outputFile}.tmp-${process.pid}-${Date.now()}`;
  await fsp.writeFile(tmp, buffer, { mode: 0o640 });
  await fsp.rename(tmp, outputFile);
  return fsp.stat(outputFile);
"""
    new_write = """  await fsp.mkdir(CACHE_DIR, { recursive: true });
  const nonce = `${process.pid}-${Date.now()}`;
  const source = `${outputFile}.source-${nonce}.mp4`;
  const tmp = `${outputFile}.tmp-${nonce}.mp4`;
  await fsp.writeFile(source, buffer, { mode: 0o640 });
  try {
    // SmartYard renders preview.mp4 in an autoplaying video element. Convert the
    // export to one H.264 frame and remove audio so it behaves as a screenshot.
    await renderStillPreview(source, tmp);
    await fsp.rename(tmp, outputFile);
  } finally {
    await fsp.unlink(source).catch(() => undefined);
    await fsp.unlink(tmp).catch(() => undefined);
  }
  return fsp.stat(outputFile);
"""
    text, did = replace_once(text, old_write, new_write, "still preview output")
    changed = changed or did

    old_route = """    'x-newdomofon-smartyard-route': preview.cached ? 'node-preview-cache' : 'node-preview-export'
"""
    new_route = """    'x-newdomofon-smartyard-route': preview.cached ? 'node-preview-still-cache' : 'node-preview-still',
    'x-newdomofon-preview-mode': STILL_PREVIEW_MARKER
"""
    text, did = replace_once(text, old_route, new_route, "still preview response marker")
    changed = changed or did

    required = (
        "async function renderStillPreview(sourceFile, outputFile)",
        "'-an'",
        "'-frames:v', '1'",
        f"const STILL_PREVIEW_MARKER = '{STILL_MARKER}';",
        "x-newdomofon-preview-mode",
    )
    for marker in required:
        if marker not in text:
            raise RuntimeError(f"preview compatibility marker missing: {marker}")

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    project = Path(args.project_dir).resolve()
    gateway = project / "smartyard-compat-proxy"
    node_aware = gateway / "server-node-aware.js"
    preview = gateway / "server-preview-gateway.js"

    for path in (node_aware, preview):
        if not path.is_file():
            raise SystemExit(f"SmartYard gateway source not found: {path}")

    changed = []
    if patch_node_aware(node_aware):
        changed.append(str(node_aware.relative_to(project)))
    if patch_preview_gateway(preview):
        changed.append(str(preview.relative_to(project)))

    print("SmartYard Flussonic compatibility prepared")
    if changed:
        for item in changed:
            print(f"  changed: {item}")
    else:
        print("  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

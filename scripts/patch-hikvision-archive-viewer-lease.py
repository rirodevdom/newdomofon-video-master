#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "newdomofon-hikvision-archive-viewer-lease"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one source block, found {count}")
    return text.replace(old, new, 1)


def patch_backend(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print("Hikvision archive viewer lease backend already prepared")
        return

    text = replace_once(
        text,
        """  requirePlayable(channel);\n  const browserToken = signMediaToken(channel.node_media_secret, channel.channel_external_id, ['archive']);""",
        """  requirePlayable(channel);\n  // newdomofon-hikvision-archive-viewer-lease\n  const viewerId = String(req.query.viewer_id || '').trim();\n  if (viewerId && !/^[A-Za-z0-9._~-]{8,128}$/.test(viewerId)) {\n    return res.status(400).json({ error: 'Invalid archive viewer id' });\n  }\n  const browserToken = signMediaToken(channel.node_media_secret, channel.channel_external_id, ['archive']);""",
        "archive viewer query validation",
    )

    text = replace_once(
        text,
        """    { method: 'POST', body: JSON.stringify({ start: params.start, end: params.end }) },""",
        """    {\n      method: 'POST',\n      body: JSON.stringify({\n        start: params.start,\n        end: params.end,\n        ...(viewerId ? { viewer_id: viewerId } : {})\n      })\n    },""",
        "forward archive viewer id to node",
    )

    release_route = r'''
hikvisionPlayerRouter.post('/:channelId/archive/release', asyncHandler(async (req, res) => {
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  requirePlayable(channel);
  const viewerId = String(req.body?.viewer_id || req.query.viewer_id || '').trim();
  if (!/^[A-Za-z0-9._~-]{8,128}$/.test(viewerId)) {
    return res.status(400).json({ error: 'Invalid archive viewer id' });
  }
  const result = await nodeJson(
    channel,
    'archive',
    'archive/viewer/release',
    { method: 'POST', body: JSON.stringify({ viewer_id: viewerId }) },
    {},
    30_000
  );
  return res.json({ ok: true, ...(result || {}) });
}));
'''
    anchor = """hikvisionPlayerRouter.get('/:channelId/export', asyncHandler(async (req, res) => {"""
    if "archive/release" not in text:
        count = text.count(anchor)
        if count != 1:
            raise SystemExit(f"archive viewer release route anchor: expected one source block, found {count}")
        text = text.replace(anchor, release_route + "\n" + anchor, 1)

    for required in (MARKER, "viewer_id: viewerId", "archive/viewer/release"):
        if required not in text:
            raise SystemExit(f"Hikvision archive viewer backend marker missing: {required}")
    path.write_text(text, encoding="utf-8")
    print("Hikvision archive viewer lease backend prepared")


def patch_frontend(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print("Hikvision archive viewer lease frontend already prepared")
        return

    text = replace_once(
        text,
        """let latestRanges: Array<{ startMs: number; endMs: number }> = [];""",
        """let latestRanges: Array<{ startMs: number; endMs: number }> = [];\n// newdomofon-hikvision-archive-viewer-lease\nconst archiveViewerId = globalThis.crypto?.randomUUID?.()\n  || `hik-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;\nlet archiveViewerChannelId = '';""",
        "stable archive viewer id",
    )

    old_destroy = """function destroyPlayer() {\n  player?.destroy();\n  player = null;\n  archivePreparing.value = false;\n  if (playerRoot.value) playerRoot.value.innerHTML = '';\n}"""
    new_destroy = """function destroyPlayer() {\n  const releaseChannelId = archiveViewerChannelId;\n  archiveViewerChannelId = '';\n  if (releaseChannelId) {\n    void api.post(`/hikvision-player/${encodeURIComponent(releaseChannelId)}/archive/release`, {\n      viewer_id: archiveViewerId\n    }).catch(() => undefined);\n  }\n  player?.destroy();\n  player = null;\n  archivePreparing.value = false;\n  if (playerRoot.value) playerRoot.value.innerHTML = '';\n}"""
    text = replace_once(text, old_destroy, new_destroy, "release archive viewer on player destroy")

    text = replace_once(
        text,
        """  const nextPlayer = sdk.create({""",
        """  archiveViewerChannelId = channelId.value;\n  const nextPlayer = sdk.create({""",
        "archive viewer channel ownership",
    )

    old_params = """                      params: { start: new Date(startMs).toISOString(), end: new Date(endMs).toISOString() },"""
    new_params = """                      params: {\n                        start: new Date(startMs).toISOString(),\n                        end: new Date(endMs).toISOString(),\n                        viewer_id: archiveViewerId\n                      },"""
    text = replace_once(text, old_params, new_params, "archive viewer id request parameter")

    for required in (MARKER, "archiveViewerId", "archive/release", "viewer_id: archiveViewerId"):
        if required not in text:
            raise SystemExit(f"Hikvision archive viewer frontend marker missing: {required}")
    path.write_text(text, encoding="utf-8")
    print("Hikvision archive viewer lease frontend prepared")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=".")
    parser.add_argument("--backend-only", action="store_true")
    parser.add_argument("--frontend-only", action="store_true")
    args = parser.parse_args()
    if args.backend_only and args.frontend_only:
        raise SystemExit("Choose only one of --backend-only or --frontend-only")
    root = Path(args.project_dir).resolve()
    if not args.frontend_only:
        patch_backend(root / "backend/src/routes/hikvisionPlayer.ts")
    if not args.backend_only:
        patch_frontend(root / "frontend/src/views/HikvisionPlayerView.vue")


if __name__ == "__main__":
    main()

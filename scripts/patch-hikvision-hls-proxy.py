#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import argparse

IMPORT = "import { rewriteHlsPlaylistBrowserToken } from '../utils/hikvisionHls.js';\n"

HELPER = '''\nasync function sendProxyHlsPlaylist(\n  response: globalThis.Response,\n  res: ExpressResponse,\n  browserToken: string\n): Promise<void> {\n  const playlist = await response.text();\n  const rewritten = rewriteHlsPlaylistBrowserToken(playlist, browserToken);\n  res.status(response.status);\n  copyProxyHeaders(response, res);\n  res.removeHeader('content-length');\n  res.setHeader('content-type', response.headers.get('content-type') || 'application/vnd.apple.mpegurl');\n  res.setHeader('content-length', Buffer.byteLength(rewritten, 'utf8'));\n  res.setHeader('cache-control', 'no-store');\n  res.setHeader('x-newdomofon-hikvision-playlist-token', 'browser');\n  res.end(rewritten);\n}\n'''

CALL = '''  if (suffix.endsWith('.m3u8')) {\n    await sendProxyHlsPlaylist(upstream, res, browserToken);\n  } else {\n    streamProxyResponse(upstream, res);\n  }\n'''


def patch(path: Path) -> bool:
    text = path.read_text(encoding='utf-8')
    changed = False

    if IMPORT not in text:
        anchor = "import { asyncHandler } from '../utils/asyncHandler.js';\n"
        if anchor not in text:
            raise RuntimeError('hikvisionPlayer import anchor not found')
        text = text.replace(anchor, anchor + IMPORT, 1)
        changed = True

    if 'async function sendProxyHlsPlaylist(' not in text:
        anchor = "function errorStatus(error: unknown): number {\n"
        if anchor not in text:
            raise RuntimeError('hikvisionPlayer helper anchor not found')
        text = text.replace(anchor, HELPER + '\n' + anchor, 1)
        changed = True

    if CALL not in text:
        old = "  streamProxyResponse(upstream, res);\n" 
        if text.count(old) != 1:
            raise RuntimeError(f'expected one streamProxyResponse call, found {text.count(old)}')
        text = text.replace(old, CALL, 1)
        changed = True

    required = (
        'rewriteHlsPlaylistBrowserToken',
        "x-newdomofon-hikvision-playlist-token",
        "suffix.endsWith('.m3u8')",
        'await sendProxyHlsPlaylist(upstream, res, browserToken)',
    )
    for marker in required:
        if marker not in text:
            raise RuntimeError(f'Hikvision HLS proxy marker missing: {marker}')

    if changed:
        path.write_text(text, encoding='utf-8')
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--project-dir', default=str(Path(__file__).resolve().parents[1]))
    args = parser.parse_args()
    project = Path(args.project_dir).resolve()
    target = project / 'backend/src/routes/hikvisionPlayer.ts'
    if not target.is_file():
        raise SystemExit(f'Hikvision player route not found: {target}')
    changed = patch(target)
    print('Hikvision HLS playlist proxy prepared')
    print(f"  changed={'true' if changed else 'false'}")
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

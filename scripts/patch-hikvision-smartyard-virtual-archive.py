#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = 'v306-hikvision-smartyard-virtual-archive'


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'{label}: expected one source fragment, found {count}')
    return text.replace(old, new, 1)


def patch_gateway(path: Path) -> None:
    text = path.read_text(encoding='utf-8')
    if MARKER in text:
        print('Hikvision SmartYard virtual archive already prepared')
        return

    constant_anchor = "const FFMPEG = String(process.env.SMARTYARD_PREVIEW_FFMPEG || process.env.FFMPEG_PATH || '/usr/bin/ffmpeg');\n"
    constants = constant_anchor + "const VIRTUAL_ARCHIVE_SEGMENT_SECONDS = Math.max(2, Math.min(6, Number(process.env.SMARTYARD_HIK_VIRTUAL_SEGMENT_SECONDS || 4)));\nconst VIRTUAL_ARCHIVE_MAX_SECONDS = Math.max(3600, Number(process.env.SMARTYARD_HIK_VIRTUAL_ARCHIVE_MAX_SECONDS || 21600));\n"
    text = replace_once(text, constant_anchor, constants, 'virtual archive constants')

    helper_anchor = 'async function prepareArchivePlaylist(req, context, range) {'
    helper = r'''// v306-hikvision-smartyard-virtual-archive
function virtualArchivePlaylist(context, range, externalToken) {
  const totalMs = range.endMs - range.startMs;
  if (!Number.isFinite(totalMs) || totalMs <= 0) {
    throw Object.assign(new Error('Invalid Hikvision virtual archive window'), { status: 400 });
  }
  if (totalMs > VIRTUAL_ARCHIVE_MAX_SECONDS * 1000) {
    throw Object.assign(
      new Error(`Hikvision virtual archive window exceeds ${VIRTUAL_ARCHIVE_MAX_SECONDS} seconds`),
      { status: 400 }
    );
  }

  const channelId = String(context.target.channel_id);
  const segmentMs = VIRTUAL_ARCHIVE_SEGMENT_SECONDS * 1000;
  const count = Math.ceil(totalMs / segmentMs);
  const lines = [
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    `#EXT-X-TARGETDURATION:${Math.ceil(VIRTUAL_ARCHIVE_SEGMENT_SECONDS)}`,
    '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-PLAYLIST-TYPE:VOD',
    '#EXT-X-INDEPENDENT-SEGMENTS'
  ];

  for (let index = 0; index < count; index += 1) {
    const startMs = range.startMs + index * segmentMs;
    const durationSeconds = Math.min(VIRTUAL_ARCHIVE_SEGMENT_SECONDS, (range.endMs - startMs) / 1000);
    const params = new URLSearchParams({
      start: new Date(startMs).toISOString(),
      duration: durationSeconds.toFixed(3)
    });
    const upstream = `/api/v1/media/channels/${encodeURIComponent(channelId)}/archive/virtual-segment.ts?${params.toString()}`;
    const opaque = opaqueUpstreamPath(upstream);
    if (index > 0) lines.push('#EXT-X-DISCONTINUITY');
    lines.push(
      `#EXT-X-PROGRAM-DATE-TIME:${new Date(startMs).toISOString()}`,
      `#EXTINF:${durationSeconds.toFixed(3)},`,
      `__hik/${opaque}?token=${encodeURIComponent(externalToken)}`
    );
  }
  lines.push('#EXT-X-ENDLIST', '');
  return lines.join('\n');
}

'''
    text = replace_once(text, helper_anchor, helper + helper_anchor, 'virtual archive playlist helper')

    old_handler = r'''  if (archivePlaylist(mediaPath)) {
    try {
      const upstream = await prepareArchivePlaylist(req, context, parseArchiveWindow(mediaPath, reqUrl));
      const response = await nodeRequest(context, upstream, req, 90000);
      return sendNodeResponse(req, res, response, stream, externalToken, 'hikvision-archive', upstream);
    } catch (error) {
      return sendJson(res, Number(error?.status || 502), { error: String(error?.message || error) }, {
        'x-newdomofon-smartyard-route': 'hikvision-archive-error'
      });
    }
  }'''
    new_handler = r'''  if (archivePlaylist(mediaPath)) {
    try {
      const range = parseArchiveWindow(mediaPath, reqUrl);
      if (String(context.target?.archive_storage || '') === 'device') {
        const playlist = virtualArchivePlaylist(context, range, externalToken);
        return sendText(res, 200, playlist, 'application/vnd.apple.mpegurl; charset=utf-8', {
          'x-newdomofon-resolved-stream': stream,
          'x-newdomofon-smartyard-route': 'hikvision-archive-virtual',
          'x-newdomofon-hikvision-archive-segment-seconds': String(VIRTUAL_ARCHIVE_SEGMENT_SECONDS)
        });
      }
      const upstream = await prepareArchivePlaylist(req, context, range);
      const response = await nodeRequest(context, upstream, req, 90000);
      return sendNodeResponse(req, res, response, stream, externalToken, 'hikvision-archive', upstream);
    } catch (error) {
      return sendJson(res, Number(error?.status || 502), { error: String(error?.message || error) }, {
        'x-newdomofon-smartyard-route': 'hikvision-archive-error'
      });
    }
  }'''
    text = replace_once(text, old_handler, new_handler, 'virtual archive handler')

    if MARKER not in text or 'hikvision-archive-virtual' not in text or 'archive/virtual-segment.ts' not in text:
        raise RuntimeError('Hikvision SmartYard virtual archive markers are incomplete')
    path.write_text(text, encoding='utf-8')
    print('Hikvision SmartYard archive now exposes an immediate seekable virtual HLS timeline')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--project-dir', default='.')
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    patch_gateway(root / 'smartyard-compat-proxy/server-hikvision-gateway.js')


if __name__ == '__main__':
    main()

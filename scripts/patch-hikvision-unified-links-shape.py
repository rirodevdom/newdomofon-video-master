#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = 'hikvision_format_links_v308'


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--project-dir', default='.')
    args = parser.parse_args()
    path = Path(args.project_dir).resolve() / 'backend/src/routes/smartyardLinks.ts'
    text = path.read_text(encoding='utf-8')
    if MARKER in text:
        print('Hikvision full format link response already prepared')
        return

    old = '''  const url = `${origin}/${encodeURIComponent(streamName)}/?token=${encodeURIComponent(token)}`;

  res.json({
    camera: {
      id: channel.channel_external_id,
      name: channel.channel_name,
      stream_name: streamName,
      device_id: channel.device_id,
      device_name: channel.device_name,
      physical_channel: channel.physical_channel,
      archive_storage: channel.archive_storage,
      online: channel.channel_online
    },
    node_name: channel.node_name,
    smartyard_url: url,
    common_url: url,
    camera_url: url,
    camera_token: token,
    permanent: true,
    expires_at: null,
    mode: 'master-smartyard-compat-hikvision'
  });'''

    new = '''  const encodedToken = encodeURIComponent(token);
  const base = `${origin}/${encodeURIComponent(streamName)}`;
  const url = `${base}/?token=${encodedToken}`;
  const formatLinks = [
    { type: 'HLS', label: 'HLS', available: true, url: `${base}/index.m3u8?token=${encodedToken}` },
    { type: 'MPEG-TS', label: 'MPEG-TS', available: false, url: null, note: 'Hikvision SmartYard gateway currently exposes this source as HLS; live.ts is not enabled.' },
    { type: 'DASH', label: 'DASH', available: false, url: null, note: 'Hikvision SmartYard gateway currently exposes this source as HLS; DASH is not enabled.' },
    { type: 'RTSP', label: 'RTSP', available: false, url: null, note: 'The permanent Hikvision SmartYard token is HTTP-gateway scoped; RTSP relay is not enabled for it.' },
    { type: 'JPEG', label: 'JPEG', available: true, url: `${base}/snapshot.jpg?token=${encodedToken}` }
  ];
  // hikvision_format_links_v308
  res.json({
    camera: {
      id: channel.channel_external_id,
      name: channel.channel_name,
      stream_name: streamName,
      device_id: channel.device_id,
      device_name: channel.device_name,
      physical_channel: channel.physical_channel,
      archive_storage: channel.archive_storage,
      online: channel.channel_online
    },
    node_name: channel.node_name,
    smartyard_url: url,
    common_url: url,
    camera_url: url,
    player_url: url,
    primary_url: url,
    camera_token: token,
    live_token: token,
    archive_token: token,
    live_url: `${base}/index.m3u8?token=${encodedToken}`,
    mpeg_ts_url: null,
    dash_url: null,
    rtsp_url: null,
    jpeg_url: `${base}/snapshot.jpg?token=${encodedToken}`,
    format_links: formatLinks,
    archive_url_template: `${base}/archive.m3u8?start=<ISO_START>&end=<ISO_END>&token=${encodedToken}`,
    events_url_template: `${base}/events.json?start=<ISO_START>&end=<ISO_END>&token=${encodedToken}`,
    archive_source: channel.archive_storage,
    permanent: true,
    expires_at: null,
    mode: 'master-smartyard-compat-hikvision'
  });'''

    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'Hikvision link response: expected one source fragment, found {count}')
    text = text.replace(old, new, 1)
    path.write_text(text, encoding='utf-8')
    print('Hikvision permanent SmartYard link response now exposes full format metadata')


if __name__ == '__main__':
    main()

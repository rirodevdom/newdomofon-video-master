#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = 'v308-hikvision-unified-camera-catalog'


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--project-dir', default='.')
    args = parser.parse_args()
    path = Path(args.project_dir).resolve() / 'backend/src/routes/cameras.ts'
    text = path.read_text(encoding='utf-8')
    if MARKER in text:
        print('Hikvision unified camera catalog already prepared')
        return

    old = '''camerasRouter.get('/', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  const baseQuery = `SELECT ${cameraSelect}, cg.name AS group_name, node.name AS dvr_server_name,
                            device.name AS device_name, device.connection_type AS device_connection_type,
                            'node'::text AS device_archive_storage,
                            EXISTS(SELECT 1 FROM user_favorites f WHERE f.camera_id = c.id AND f.user_id = $1) AS favorite
                       FROM cameras c
                       JOIN devices device ON device.id = c.device_id
                       LEFT JOIN camera_groups cg ON cg.id = c.group_id
                       LEFT JOIN dvr_servers node ON node.id = device.dvr_server_id`;

  if (isAdmin(authReq)) {
    const result = await query(`${baseQuery} ORDER BY c.name ASC`, [authReq.user!.id]);
    return res.json({ items: result.rows });
  }

  const result = await query(`${baseQuery} WHERE c.is_enabled = true ORDER BY c.name ASC`, [authReq.user!.id]);
  res.json({ items: result.rows });
}));'''

    new = '''// v308-hikvision-unified-camera-catalog
camerasRouter.get('/', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  const admin = isAdmin(authReq);
  const baseQuery = `SELECT ${cameraSelect}, cg.name AS group_name, node.name AS dvr_server_name,
                            device.name AS device_name, device.connection_type AS device_connection_type,
                            'node'::text AS device_archive_storage,
                            EXISTS(SELECT 1 FROM user_favorites f WHERE f.camera_id = c.id AND f.user_id = $1) AS favorite,
                            'camera'::text AS camera_kind, false AS is_hikvision, NULL::boolean AS online,
                            NULL::integer AS physical_channel, NULL::text AS primary_stream_id
                       FROM cameras c
                       JOIN devices device ON device.id = c.device_id
                       LEFT JOIN camera_groups cg ON cg.id = c.group_id
                       LEFT JOIN dvr_servers node ON node.id = device.dvr_server_id`;

  const normal = await query(
    admin ? `${baseQuery} ORDER BY c.name ASC` : `${baseQuery} WHERE c.is_enabled = true ORDER BY c.name ASC`,
    [authReq.user!.id]
  );
  const hikvision = await query(
    `SELECT h.channel_external_id AS id,
            NULL::uuid AS group_id,
            h.dvr_server_id, h.device_id, h.name,
            ('hik_' || replace(h.device_id::text, '-', '') || '_' || h.physical_channel::text) AS stream_name,
            ''::text AS source_url, h.archive_storage, NULL::text AS rtmp_push_url,
            NULL::double precision AS latitude, NULL::double precision AS longitude,
            NULL::integer AS direction_deg, NULL::integer AS fov_deg, h.retention_days,
            (h.enabled AND device.is_enabled) AS is_enabled,
            h.updated_at AS created_at, h.updated_at,
            NULL::text AS onvif_xaddr, NULL::integer AS onvif_port,
            NULL::text AS onvif_username, NULL::text AS onvif_profile_token,
            NULL::jsonb AS onvif_device_info, NULL::timestamptz AS onvif_last_sync_at,
            false AS is_onvif, NULL::text AS group_name,
            node.name AS dvr_server_name, device.name AS device_name,
            'HIKVISION'::text AS device_connection_type,
            h.archive_storage AS device_archive_storage, false AS favorite,
            'hikvision'::text AS camera_kind, true AS is_hikvision,
            h.online, h.physical_channel, h.primary_stream_id
       FROM hikvision_node_channels h
       JOIN devices device ON device.id = h.device_id
       LEFT JOIN dvr_servers node ON node.id = h.dvr_server_id
      WHERE $1::boolean OR (h.enabled = true AND device.is_enabled = true)
      ORDER BY h.name ASC`,
    [admin]
  );
  const items = [...normal.rows, ...hikvision.rows].sort((left: any, right: any) =>
    String(left.name || '').localeCompare(String(right.name || ''), 'ru')
  );
  res.json({ items });
}));'''

    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'unified cameras GET: expected one source fragment, found {count}')
    path.write_text(text.replace(old, new, 1), encoding='utf-8')
    print('Hikvision channels are projected into the unified cameras API without duplicating cameras table rows')


if __name__ == '__main__':
    main()

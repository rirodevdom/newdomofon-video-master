#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "v310-hikvision-canonical-cameras"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1)


def patch_node_agent(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        return

    schema_anchor = "const hikvisionSyncSchema = z.object({"
    helper = r'''// v310-hikvision-canonical-cameras
function hikvisionCanonicalStreamName(deviceId: string, physicalChannel: number): string {
  const device = String(deviceId || '').replace(/[^A-Za-z0-9]/g, '').toLowerCase();
  return `hik_${device}_${Math.max(1, Math.trunc(Number(physicalChannel) || 1))}`;
}

'''
    text = replace_once(text, schema_anchor, helper + schema_anchor, "Hikvision canonical stream helper")

    old_write = r'''      await query(
        `INSERT INTO hikvision_node_channels(
           device_id, dvr_server_id, channel_external_id, physical_channel, name, online, enabled,
           primary_stream_id, archive_storage, retention_days, streams, device_info, capabilities, discovered_at, updated_at
         ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,now())
         ON CONFLICT (device_id, channel_external_id) DO UPDATE SET
           dvr_server_id = EXCLUDED.dvr_server_id, physical_channel = EXCLUDED.physical_channel,
           name = EXCLUDED.name, online = EXCLUDED.online, enabled = EXCLUDED.enabled,
           primary_stream_id = EXCLUDED.primary_stream_id, archive_storage = EXCLUDED.archive_storage,
           retention_days = EXCLUDED.retention_days, streams = EXCLUDED.streams,
           device_info = EXCLUDED.device_info, capabilities = EXCLUDED.capabilities,
           discovered_at = EXCLUDED.discovered_at, updated_at = now()`,
        [snapshot.config.id, req.node!.id, channel.id, channel.physical_channel, channel.name, channel.online, channel.enabled,
          channel.primary_stream_id, channel.archive_storage, channel.retention_days, JSON.stringify(channel.streams),
          JSON.stringify(snapshot.device_info), JSON.stringify(snapshot.capabilities), channel.discovered_at]
      );
      channelsWritten += 1;'''

    new_write = r'''      const streamName = hikvisionCanonicalStreamName(snapshot.config.id, channel.physical_channel);
      const canonical = await query<{ id: string }>(
        `INSERT INTO cameras(
           name, stream_name, source_url, dvr_server_id, device_id,
           archive_storage, retention_days, is_enabled
         ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
         ON CONFLICT (stream_name) DO UPDATE SET
           source_url = EXCLUDED.source_url,
           dvr_server_id = EXCLUDED.dvr_server_id,
           device_id = EXCLUDED.device_id,
           archive_storage = EXCLUDED.archive_storage,
           retention_days = EXCLUDED.retention_days,
           updated_at = now()
         RETURNING id`,
        [
          channel.name || `Hikvision ${channel.physical_channel}`,
          streamName,
          `hikvision://${channel.id}`,
          req.node!.id,
          snapshot.config.id,
          channel.archive_storage,
          channel.retention_days,
          channel.enabled
        ]
      );
      const cameraId = canonical.rows[0].id;

      await query(
        `INSERT INTO hikvision_node_channels(
           device_id, dvr_server_id, channel_external_id, camera_id, physical_channel, name, online, enabled,
           primary_stream_id, archive_storage, retention_days, streams, device_info, capabilities, discovered_at, updated_at
         ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,now())
         ON CONFLICT (device_id, channel_external_id) DO UPDATE SET
           dvr_server_id = EXCLUDED.dvr_server_id, camera_id = EXCLUDED.camera_id,
           physical_channel = EXCLUDED.physical_channel,
           name = EXCLUDED.name, online = EXCLUDED.online, enabled = EXCLUDED.enabled,
           primary_stream_id = EXCLUDED.primary_stream_id, archive_storage = EXCLUDED.archive_storage,
           retention_days = EXCLUDED.retention_days, streams = EXCLUDED.streams,
           device_info = EXCLUDED.device_info, capabilities = EXCLUDED.capabilities,
           discovered_at = EXCLUDED.discovered_at, updated_at = now()`,
        [snapshot.config.id, req.node!.id, channel.id, cameraId, channel.physical_channel, channel.name, channel.online, channel.enabled,
          channel.primary_stream_id, channel.archive_storage, channel.retention_days, JSON.stringify(channel.streams),
          JSON.stringify(snapshot.device_info), JSON.stringify(snapshot.capabilities), channel.discovered_at]
      );
      channelsWritten += 1;'''
    text = replace_once(text, old_write, new_write, "Hikvision canonical camera upsert")

    old_delete = r'''    await query(
      `DELETE FROM hikvision_node_channels
        WHERE device_id = $1
          AND NOT (channel_external_id = ANY($2::text[]))`,
      [snapshot.config.id, channelIds]
    );'''
    new_delete = r'''    // Remove canonical cameras for channels that disappeared from the DVR.
    // The FK from hikvision_node_channels.camera_id cascades the inventory row.
    await query(
      `DELETE FROM cameras c
        USING hikvision_node_channels h
        WHERE h.device_id = $1
          AND h.camera_id = c.id
          AND NOT (h.channel_external_id = ANY($2::text[]))`,
      [snapshot.config.id, channelIds]
    );
    await query(
      `DELETE FROM hikvision_node_channels
        WHERE device_id = $1
          AND camera_id IS NULL
          AND NOT (channel_external_id = ANY($2::text[]))`,
      [snapshot.config.id, channelIds]
    );'''
    text = replace_once(text, old_delete, new_delete, "Hikvision stale canonical camera cleanup")

    for required in (MARKER, "camera_id, physical_channel", "ON CONFLICT (stream_name)", "DELETE FROM cameras c"):
        if required not in text:
            raise RuntimeError(f"nodeAgent canonical marker missing: {required}")
    path.write_text(text, encoding="utf-8")


def patch_cameras(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "hikvision_channel_external_id" in text and MARKER in text:
        return

    text = replace_once(
        text,
        "  c.name, c.stream_name, c.source_url, 'node'::text AS archive_storage,\n",
        "  c.name, c.stream_name, c.source_url, c.archive_storage,\n",
        "camera archive storage field",
    )

    old_base = r'''  const baseQuery = `SELECT ${cameraSelect}, cg.name AS group_name, node.name AS dvr_server_name,
                            device.name AS device_name, device.connection_type AS device_connection_type,
                            'node'::text AS device_archive_storage,
                            EXISTS(SELECT 1 FROM user_favorites f WHERE f.camera_id = c.id AND f.user_id = $1) AS favorite
                       FROM cameras c
                       JOIN devices device ON device.id = c.device_id
                       LEFT JOIN camera_groups cg ON cg.id = c.group_id
                       LEFT JOIN dvr_servers node ON node.id = device.dvr_server_id`;'''
    new_base = r'''  // v310-hikvision-canonical-cameras
  const baseQuery = `SELECT ${cameraSelect}, cg.name AS group_name, node.name AS dvr_server_name,
                            device.name AS device_name, device.connection_type AS device_connection_type,
                            device.archive_storage AS device_archive_storage,
                            h.channel_external_id AS hikvision_channel_external_id,
                            h.physical_channel AS physical_channel,
                            h.online AS online,
                            (device.connection_type = 'HIKVISION') AS is_hikvision,
                            EXISTS(SELECT 1 FROM user_favorites f WHERE f.camera_id = c.id AND f.user_id = $1) AS favorite
                       FROM cameras c
                       JOIN devices device ON device.id = c.device_id
                       LEFT JOIN camera_groups cg ON cg.id = c.group_id
                       LEFT JOIN dvr_servers node ON node.id = device.dvr_server_id
                       LEFT JOIN hikvision_node_channels h ON h.camera_id = c.id`;'''
    text = replace_once(text, old_base, new_base, "canonical cameras list")

    old_one = r'''    `SELECT ${cameraSelect},
            device.name AS device_name, device.connection_type AS device_connection_type,
            'node'::text AS device_archive_storage, node.name AS dvr_server_name
       FROM cameras c
       JOIN devices device ON device.id = c.device_id
       LEFT JOIN dvr_servers node ON node.id = device.dvr_server_id
      WHERE c.id = $1`,'''
    new_one = r'''    `SELECT ${cameraSelect},
            device.name AS device_name, device.connection_type AS device_connection_type,
            device.archive_storage AS device_archive_storage, node.name AS dvr_server_name,
            h.channel_external_id AS hikvision_channel_external_id,
            h.physical_channel AS physical_channel,
            h.online AS online,
            (device.connection_type = 'HIKVISION') AS is_hikvision
       FROM cameras c
       JOIN devices device ON device.id = c.device_id
       LEFT JOIN dvr_servers node ON node.id = device.dvr_server_id
       LEFT JOIN hikvision_node_channels h ON h.camera_id = c.id
      WHERE c.id = $1`,'''
    text = replace_once(text, old_one, new_one, "canonical camera detail")

    path.write_text(text, encoding="utf-8")


def patch_devices(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    old_count = r'''  ((SELECT count(*) FROM cameras c WHERE c.device_id = d.id) +
   (SELECT count(*) FROM hikvision_node_channels h WHERE h.device_id = d.id))::int AS camera_count
'''
    new_count = r'''  (SELECT count(*)::int FROM cameras c WHERE c.device_id = d.id) AS camera_count
'''
    text = replace_once(text, old_count, new_count, "device canonical camera count")
    text = replace_once(
        text,
        "      `SELECT channel_external_id AS id, physical_channel, name, online, enabled,\n",
        "      `SELECT channel_external_id AS id, camera_id, physical_channel, name, online, enabled,\n",
        "device Hikvision canonical camera id",
    )
    path.write_text(text, encoding="utf-8")


def patch_managed_tokens(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "buildHikvisionFormatLinks" not in text:
        text = replace_once(
            text,
            "  node_media_secret_configured: boolean;\n};",
            "  node_media_secret_configured: boolean;\n  device_connection_type: string;\n};",
            "managed token camera type",
        )
        anchor = "managedCameraTokensRouter.get('/managed-camera-tokens', asyncHandler(async (_req, res) => {"
        helper = r'''function buildHikvisionFormatLinks(base: string, rawToken: string): FormatLink[] {
  const encodedToken = encodeURIComponent(rawToken);
  return [
    {
      type: 'HLS', protocol: 'HTTPS', available: true,
      url: `${base}/index.m3u8?token=${encodedToken}`,
      content_type: 'application/vnd.apple.mpegurl'
    },
    {
      type: 'MPEG-TS', protocol: 'HTTPS', available: false, url: null, content_type: null,
      note: 'Для Hikvision-источника MPEG-TS gateway не включён.'
    },
    {
      type: 'DASH', protocol: 'HTTPS', available: false, url: null, content_type: null,
      note: 'Для Hikvision-источника DASH gateway не включён.'
    },
    {
      type: 'RTSP', protocol: 'RTSP', available: false, url: null, content_type: null,
      note: 'Управляемый токен Hikvision обслуживается HTTPS gateway; RTSP relay для него не используется.'
    },
    {
      type: 'JPEG', protocol: 'HTTPS', available: true,
      url: `${base}/snapshot.jpg?token=${encodedToken}`,
      content_type: 'image/jpeg'
    }
  ];
}

'''
        text = replace_once(text, anchor, helper + anchor, "Hikvision managed format links")

    text = replace_once(
        text,
        "            device.archive_storage AS device_archive_storage,\n            node.name AS node_name,",
        "            device.archive_storage AS device_archive_storage,\n            device.connection_type AS device_connection_type,\n            node.name AS node_name,",
        "managed camera connection type query",
    )
    text = replace_once(
        text,
        "  const formatLinks = buildFormatLinks(base, camera.stream_name, rawToken);",
        "  const formatLinks = camera.device_connection_type === 'HIKVISION'\n    ? buildHikvisionFormatLinks(base, rawToken)\n    : buildFormatLinks(base, camera.stream_name, rawToken);",
        "managed Hikvision format link selection",
    )
    path.write_text(text, encoding="utf-8")


def patch_internal_resolver(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "hikvision_channel_external_id: string | null;" not in text:
        old_type_end = "  managed_token_created_by: string | null;\n};"
        new_type_end = """  managed_token_created_by: string | null;
  device_connection_type: string;
  hikvision_device_id: string | null;
  hikvision_device_enabled: boolean | null;
  hikvision_channel_external_id: string | null;
  hikvision_physical_channel: number | null;
  hikvision_channel_enabled: boolean | null;
  hikvision_channel_online: boolean | null;
  hikvision_archive_storage: 'node' | 'device' | null;
  node_agent_token_hash: string | null;
};"""
        text = replace_once(text, old_type_end, new_type_end, "managed Hikvision resolver type")

    old_select = r'''              c.stream_name,
              c.is_enabled AS camera_enabled,
              ds.id AS node_id,
              ds.name AS node_name,
              ds.is_enabled AS node_enabled,
              ds.internal_url AS node_internal_url,
              ds.base_url AS node_base_url,
              ds.public_base_url AS node_public_url,
              ds.media_secret AS node_media_secret
         FROM managed_camera_tokens t
         JOIN managed_camera_token_cameras mtc ON mtc.token_id = t.id
         JOIN cameras c ON c.id = mtc.camera_id
         JOIN dvr_servers ds ON ds.id = c.dvr_server_id'''
    new_select = r'''              c.stream_name,
              c.is_enabled AS camera_enabled,
              device.connection_type AS device_connection_type,
              device.id::text AS hikvision_device_id,
              device.is_enabled AS hikvision_device_enabled,
              h.channel_external_id AS hikvision_channel_external_id,
              h.physical_channel AS hikvision_physical_channel,
              h.enabled AS hikvision_channel_enabled,
              h.online AS hikvision_channel_online,
              h.archive_storage AS hikvision_archive_storage,
              ds.id AS node_id,
              ds.name AS node_name,
              ds.is_enabled AS node_enabled,
              ds.internal_url AS node_internal_url,
              ds.base_url AS node_base_url,
              ds.public_base_url AS node_public_url,
              ds.media_secret AS node_media_secret,
              ds.agent_token_hash AS node_agent_token_hash
         FROM managed_camera_tokens t
         JOIN managed_camera_token_cameras mtc ON mtc.token_id = t.id
         JOIN cameras c ON c.id = mtc.camera_id
         JOIN devices device ON device.id = c.device_id
         LEFT JOIN hikvision_node_channels h ON h.camera_id = c.id
         JOIN dvr_servers ds ON ds.id = c.dvr_server_id'''
    text = replace_once(text, old_select, new_select, "managed canonical Hikvision resolver query")

    old_return = r'''    return sendResolved(
      res,
      camera,
      body.upstream_scope,
      camera.managed_token_created_by || `managed:${camera.managed_token_id}`,
      'managed',
      { id: camera.managed_token_id, name: camera.managed_token_name }
    );'''
    new_return = r'''    if (camera.device_connection_type === 'HIKVISION') {
      if (!camera.hikvision_channel_external_id || !camera.hikvision_device_id || !camera.hikvision_physical_channel) {
        return res.status(404).json({ error: 'Hikvision camera inventory binding is unavailable' });
      }
      if (camera.hikvision_device_enabled === false || camera.hikvision_channel_enabled === false) {
        return res.status(404).json({ error: 'Hikvision camera or device is disabled' });
      }
      return sendHikvisionResolved(
        res,
        {
          channel_external_id: camera.hikvision_channel_external_id,
          device_id: camera.hikvision_device_id,
          physical_channel: camera.hikvision_physical_channel,
          channel_name: camera.camera_name,
          channel_enabled: camera.hikvision_channel_enabled !== false,
          channel_online: camera.hikvision_channel_online,
          archive_storage: camera.hikvision_archive_storage || 'device',
          device_enabled: camera.hikvision_device_enabled !== false,
          node_id: camera.node_id,
          node_name: camera.node_name,
          node_enabled: camera.node_enabled,
          node_internal_url: camera.node_internal_url,
          node_base_url: camera.node_base_url,
          node_public_url: camera.node_public_url,
          node_media_secret: camera.node_media_secret,
          node_agent_token_hash: camera.node_agent_token_hash
        },
        body.upstream_scope,
        camera.managed_token_created_by || `managed:${camera.managed_token_id}`
      );
    }

    return sendResolved(
      res,
      camera,
      body.upstream_scope,
      camera.managed_token_created_by || `managed:${camera.managed_token_id}`,
      'managed',
      { id: camera.managed_token_id, name: camera.managed_token_name }
    );'''
    text = replace_once(text, old_return, new_return, "managed canonical Hikvision resolve branch")

    if "LEFT JOIN hikvision_node_channels h ON h.camera_id = c.id" not in text:
        raise RuntimeError("canonical Hikvision managed resolver join missing")
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=".")
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()

    patch_node_agent(root / "backend/src/routes/nodeAgent.ts")
    patch_cameras(root / "backend/src/routes/cameras.ts")
    patch_devices(root / "backend/src/routes/devices.ts")
    patch_managed_tokens(root / "backend/src/routes/managedCameraTokens.ts")
    patch_internal_resolver(root / "backend/src/routes/internalSmartYard.ts")

    print("Hikvision discovery now maintains canonical cameras with ordinary master functionality")
    print("Managed tokens resolve canonical Hikvision cameras through the Hikvision node transport")


if __name__ == "__main__":
    main()

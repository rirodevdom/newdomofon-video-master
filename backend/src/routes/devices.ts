import { Router } from 'express';
import { z } from 'zod';
import { query } from '../db.js';
import { requireAuth, requireRole } from '../middleware/auth.js';
import { asyncHandler } from '../utils/asyncHandler.js';
import { audit } from '../utils/audit.js';

export const devicesRouter = Router();
devicesRouter.use(requireAuth);

const nullableString = z.string().nullable().optional();

const deviceSchema = z.object({
  name: z.string().min(1),
  connection_type: z.enum(['RTSP', 'ONVIF', 'HIKVISION']).default('RTSP'),
  dvr_server_id: z.string().uuid().nullable().optional(),
  host: nullableString,
  port: z.number().int().min(1).max(65535).nullable().optional(),
  username: nullableString,
  password: nullableString,
  rtsp_url: nullableString,
  archive_storage: z.enum(['node', 'device']).optional(),
  isapi_scheme: z.enum(['http', 'https']).optional(),
  rtsp_port: z.number().int().min(1).max(65535).optional(),
  retention_days: z.number().int().min(1).max(3650).optional(),
  reject_unauthorized_tls: z.boolean().optional(),
  hikvision_channel_overrides: z.record(z.any()).optional(),
  comment: nullableString,
  is_enabled: z.boolean().default(true)
}).strict();

const deviceUpdateSchema = deviceSchema.partial().strict();

type DeviceRow = {
  id: string;
  name: string;
  connection_type: 'RTSP' | 'ONVIF' | 'HIKVISION';
  dvr_server_id: string | null;
  host: string | null;
  port: number | null;
  username: string | null;
  rtsp_url: string | null;
  archive_storage: 'node' | 'device';
  isapi_scheme: 'http' | 'https';
  rtsp_port: number;
  retention_days: number;
  reject_unauthorized_tls: boolean;
  hikvision_channel_overrides: Record<string, unknown>;
  comment: string | null;
  status: string;
  last_check_at: string | null;
  is_enabled: boolean;
  has_password?: boolean;
  created_at: string;
  updated_at: string;
  node_name?: string | null;
  camera_count?: number;
};

function isConfigured(row: Pick<DeviceRow, 'name' | 'connection_type' | 'dvr_server_id' | 'host' | 'port' | 'rtsp_url'>): boolean {
  if (!row.name || !row.connection_type || !row.dvr_server_id) return false;
  if (row.connection_type === 'RTSP') return Boolean(row.rtsp_url || row.host);
  if (row.connection_type === 'HIKVISION') return Boolean(row.host && row.port && row.dvr_server_id);
  return Boolean(row.host && row.port);
}

function publicDevice(row: DeviceRow) {
  const { has_password, ...safeRow } = row;
  return {
    ...safeRow,
    camera_count: Number(row.camera_count || 0),
    is_configured: isConfigured(row),
    has_password: Boolean(has_password),
    archive_storage: row.archive_storage
  };
}

function uniqueNodeIds(values: Array<string | null | undefined>): string[] {
  return Array.from(new Set(values.map((value) => String(value || '').trim()).filter(Boolean)));
}

async function requireCompatibleNode(nodeId: string | null | undefined, connectionType: 'RTSP' | 'ONVIF' | 'HIKVISION'): Promise<void> {
  if (!nodeId) return;
  const result = await query<{ node_kind: 'video' | 'hikvision' }>(
    `SELECT CASE WHEN capabilities->>'node_kind' = 'hikvision' THEN 'hikvision' ELSE 'video' END AS node_kind
       FROM dvr_servers WHERE id = $1`,
    [nodeId]
  );
  if (!result.rowCount) throw Object.assign(new Error('Назначенная node не найдена'), { statusCode: 400 });
  const expected = connectionType === 'HIKVISION' ? 'hikvision' : 'video';
  if (result.rows[0].node_kind !== expected) {
    throw Object.assign(new Error(connectionType === 'HIKVISION'
      ? 'Hikvision-устройство можно назначить только Hikvision node'
      : 'RTSP/ONVIF-устройство можно назначить только обычной video node'), { statusCode: 409 });
  }
}

async function queueDeviceCameraReload(
  nodeIds: Array<string | null | undefined>,
  payload: Record<string, unknown>
): Promise<number> {
  const ids = uniqueNodeIds(nodeIds);
  if (!ids.length) return 0;

  await query(
    `UPDATE dvr_servers
        SET config_generation = config_generation + 1,
            updated_at = now()
      WHERE id = ANY($1::uuid[])`,
    [ids]
  );

  const commands = await query(
    `INSERT INTO node_commands(dvr_server_id, type, payload)
     SELECT id, 'reload_cameras', $2::jsonb
       FROM dvr_servers
      WHERE id = ANY($1::uuid[])
     RETURNING id`,
    [ids, JSON.stringify(payload)]
  );
  return commands.rowCount || 0;
}

const deviceSelect = `
  d.id, d.name, d.connection_type, d.dvr_server_id, d.host, d.port,
  d.username, d.rtsp_url, d.archive_storage, d.isapi_scheme, d.rtsp_port,
  d.retention_days, d.reject_unauthorized_tls, d.hikvision_channel_overrides, d.comment, d.status, d.last_check_at,
  d.is_enabled, d.created_at, d.updated_at,
  (d.password IS NOT NULL AND d.password <> '') AS has_password,
  node.name AS node_name,
  ((SELECT count(*) FROM cameras c WHERE c.device_id = d.id) +
   (SELECT count(*) FROM hikvision_node_channels h WHERE h.device_id = d.id))::int AS camera_count
`;

devicesRouter.get('/', asyncHandler(async (_req, res) => {
  const result = await query<DeviceRow>(
    `SELECT ${deviceSelect}
       FROM devices d
       LEFT JOIN dvr_servers node ON node.id = d.dvr_server_id
      ORDER BY d.created_at DESC`
  );
  res.json({ items: result.rows.map(publicDevice) });
}));

devicesRouter.get('/:id', asyncHandler(async (req, res) => {
  const result = await query<DeviceRow>(
    `SELECT ${deviceSelect}
       FROM devices d
       LEFT JOIN dvr_servers node ON node.id = d.dvr_server_id
      WHERE d.id = $1`,
    [req.params.id]
  );
  if (!result.rowCount) return res.status(404).json({ error: 'Device not found' });

  const cameras = await query(
    `SELECT c.id, c.group_id, c.device_id, c.name, c.stream_name, c.source_url,
            c.retention_days, c.is_enabled, c.created_at, c.updated_at,
            c.onvif_xaddr, c.onvif_port, c.onvif_username, c.onvif_profile_token,
            c.onvif_device_info, c.onvif_last_sync_at,
            (c.onvif_xaddr IS NOT NULL) AS is_onvif,
            d.dvr_server_id, node.name AS node_name,
            c.archive_storage
       FROM cameras c
       JOIN devices d ON d.id = c.device_id
       LEFT JOIN dvr_servers node ON node.id = d.dvr_server_id
      WHERE c.device_id = $1
      ORDER BY c.name ASC`,
    [req.params.id]
  );

  const hikvisionChannels = result.rows[0].connection_type === 'HIKVISION'
    ? await query(
      `SELECT channel_external_id AS id, physical_channel, name, online, enabled,
              primary_stream_id, archive_storage, retention_days, streams,
              discovered_at, updated_at
         FROM hikvision_node_channels
        WHERE device_id = $1
        ORDER BY physical_channel, channel_external_id`,
      [req.params.id]
    )
    : { rows: [] };

  res.json({ item: publicDevice(result.rows[0]), cameras: cameras.rows, hikvision_channels: hikvisionChannels.rows });
}));

devicesRouter.post('/', requireRole('super_admin', 'operator'), asyncHandler(async (req, res) => {
  const body = deviceSchema.parse(req.body || {});
  await requireCompatibleNode(body.dvr_server_id, body.connection_type);
  const archiveStorage = body.connection_type === 'HIKVISION' ? (body.archive_storage || 'device') : 'node';
  const result = await query<{ id: string }>(
    `INSERT INTO devices(
       name, connection_type, archive_storage, dvr_server_id, host, port, username,
       password, rtsp_url, isapi_scheme, rtsp_port, retention_days,
       reject_unauthorized_tls, hikvision_channel_overrides, comment, status, is_enabled
     ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,'unknown',$16)
     RETURNING id`,
    [
      body.name, body.connection_type, archiveStorage, body.dvr_server_id ?? null,
      body.host ?? null, body.port ?? null, body.username ?? null, body.password ?? null,
      body.rtsp_url ?? null, body.isapi_scheme || 'http', body.rtsp_port || 554,
      body.retention_days || 30, body.reject_unauthorized_tls ?? true,
      JSON.stringify(body.hikvision_channel_overrides || {}), body.comment ?? null, body.is_enabled
    ]
  );
  const reloadCommands = await queueDeviceCameraReload([body.dvr_server_id], {
    reason: 'device_created', device_id: result.rows[0].id, connection_type: body.connection_type
  });
  await audit(req, 'device.create', 'device', result.rows[0].id, {
    connection_type: body.connection_type, archive_storage: archiveStorage, reload_commands: reloadCommands
  });
  res.status(201).json({ id: result.rows[0].id, reload_queued: reloadCommands > 0 });
}));

devicesRouter.patch('/:id', requireRole('super_admin', 'operator'), asyncHandler(async (req, res) => {
  const body = deviceUpdateSchema.parse(req.body || {});
  const before = await query<{
    dvr_server_id: string | null;
    connection_type: 'RTSP' | 'ONVIF' | 'HIKVISION';
    archive_storage: 'node' | 'device';
    camera_count: number;
  }>(
    `SELECT dvr_server_id, connection_type, archive_storage,
            (SELECT count(*)::int FROM cameras WHERE device_id = devices.id) AS camera_count
       FROM devices WHERE id = $1`,
    [req.params.id]
  );
  if (!before.rowCount) return res.status(404).json({ error: 'Device not found' });

  const previous = before.rows[0];
  const connectionType = body.connection_type || previous.connection_type;
  const nodeId = body.dvr_server_id === undefined ? previous.dvr_server_id : body.dvr_server_id;
  if (connectionType !== previous.connection_type && Number(previous.camera_count) > 0) {
    return res.status(409).json({ error: 'Нельзя изменить тип устройства, пока к нему привязаны камеры' });
  }
  await requireCompatibleNode(nodeId, connectionType);

  const normalized = {
    ...body,
    connection_type: connectionType,
    dvr_server_id: nodeId,
    archive_storage: connectionType === 'HIKVISION' ? (body.archive_storage || previous.archive_storage || 'device') : 'node',
    hikvision_channel_overrides: body.hikvision_channel_overrides === undefined
      ? undefined
      : JSON.stringify(body.hikvision_channel_overrides)
  };
  const entries = Object.entries(normalized).filter(([, value]) => value !== undefined);
  const sets = entries.map(([key], index) => `${key} = $${index + 2}`).join(', ');
  await query(`UPDATE devices SET ${sets}, updated_at = now() WHERE id = $1`, [req.params.id, ...entries.map(([, value]) => value)]);

  await query(
    `UPDATE cameras SET dvr_server_id = $2, archive_storage = $3 WHERE device_id = $1`,
    [req.params.id, nodeId, normalized.archive_storage]
  );

  const affectedNodeIds = [previous.dvr_server_id, nodeId];
  const reloadCommands = await queueDeviceCameraReload(affectedNodeIds, {
    reason: 'device_updated', device_id: req.params.id,
    fields: entries.map(([key]) => key), inherited_node_id: nodeId
  });
  await audit(req, 'device.update', 'device', req.params.id, {
    fields: entries.map(([key]) => key), reload_commands: reloadCommands
  });
  res.json({ ok: true, reload_queued: reloadCommands > 0 });
}));

devicesRouter.delete('/:id', requireRole('super_admin'), asyncHandler(async (req, res) => {
  const affected = await query<{ dvr_server_id: string }>(
    `SELECT dvr_server_id FROM devices WHERE id = $1 AND dvr_server_id IS NOT NULL
     UNION
     SELECT DISTINCT dvr_server_id FROM cameras WHERE device_id = $1 AND dvr_server_id IS NOT NULL`,
    [req.params.id]
  );
  await query('DELETE FROM camera_events e USING cameras c WHERE e.camera_id = c.id AND c.device_id = $1', [req.params.id]);
  await query('DELETE FROM playback_access_tokens t USING cameras c WHERE t.camera_id = c.id AND c.device_id = $1', [req.params.id]);
  await query('DELETE FROM cameras WHERE device_id = $1', [req.params.id]);
  const result = await query('DELETE FROM devices WHERE id = $1', [req.params.id]);
  if (!result.rowCount) return res.status(404).json({ error: 'Device not found' });

  const reloadCommands = await queueDeviceCameraReload(affected.rows.map((row) => row.dvr_server_id), {
    reason: 'device_deleted',
    device_id: req.params.id
  });
  await audit(req, 'device.delete', 'device', req.params.id, { reload_commands: reloadCommands });
  res.json({ ok: true, reload_queued: reloadCommands > 0 });
}));

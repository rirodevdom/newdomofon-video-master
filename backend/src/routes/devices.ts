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
  connection_type: z.enum(['RTSP', 'ONVIF']).default('RTSP'),
  dvr_server_id: z.string().uuid().nullable().optional(),
  host: nullableString,
  port: z.number().int().min(1).max(65535).nullable().optional(),
  username: nullableString,
  password: nullableString,
  rtsp_url: nullableString,
  comment: nullableString,
  is_enabled: z.boolean().default(true)
}).strict();

const deviceUpdateSchema = deviceSchema.partial().strict();

type DeviceRow = {
  id: string;
  name: string;
  connection_type: 'RTSP' | 'ONVIF';
  dvr_server_id: string | null;
  host: string | null;
  port: number | null;
  username: string | null;
  rtsp_url: string | null;
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
  return Boolean(row.host && row.port);
}

function publicDevice(row: DeviceRow) {
  const { has_password, ...safeRow } = row;
  return {
    ...safeRow,
    camera_count: Number(row.camera_count || 0),
    is_configured: isConfigured(row),
    has_password: Boolean(has_password),
    archive_storage: 'node'
  };
}

function uniqueNodeIds(values: Array<string | null | undefined>): string[] {
  return Array.from(new Set(values.map((value) => String(value || '').trim()).filter(Boolean)));
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
  d.username, d.rtsp_url, d.comment, d.status, d.last_check_at,
  d.is_enabled, d.created_at, d.updated_at,
  (d.password IS NOT NULL AND d.password <> '') AS has_password,
  node.name AS node_name,
  (SELECT count(*)::int FROM cameras c WHERE c.device_id = d.id) AS camera_count
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
            'node'::text AS archive_storage
       FROM cameras c
       JOIN devices d ON d.id = c.device_id
       LEFT JOIN dvr_servers node ON node.id = d.dvr_server_id
      WHERE c.device_id = $1
      ORDER BY c.name ASC`,
    [req.params.id]
  );

  res.json({ item: publicDevice(result.rows[0]), cameras: cameras.rows });
}));

devicesRouter.post('/', requireRole('super_admin', 'operator'), asyncHandler(async (req, res) => {
  const body = deviceSchema.parse(req.body || {});
  const result = await query<{ id: string }>(
    `INSERT INTO devices(
       name, connection_type, archive_storage, dvr_server_id, host, port, username,
       password, rtsp_url, comment, status, is_enabled
     )
     VALUES ($1,$2,'node',$3,$4,$5,$6,$7,$8,$9,'unknown',$10)
     RETURNING id`,
    [
      body.name,
      body.connection_type,
      body.dvr_server_id ?? null,
      body.host ?? null,
      body.port ?? null,
      body.username ?? null,
      body.password ?? null,
      body.rtsp_url ?? null,
      body.comment ?? null,
      body.is_enabled
    ]
  );
  await audit(req, 'device.create', 'device', result.rows[0].id, { connection_type: body.connection_type });
  res.status(201).json({ id: result.rows[0].id });
}));

devicesRouter.patch('/:id', requireRole('super_admin', 'operator'), asyncHandler(async (req, res) => {
  const body = deviceUpdateSchema.parse(req.body || {});
  const entries = Object.entries(body).filter(([, value]) => value !== undefined);
  if (!entries.length) return res.json({ ok: true, reload_queued: false });

  const before = await query<{ dvr_server_id: string | null }>(
    `SELECT dvr_server_id FROM devices WHERE id = $1`,
    [req.params.id]
  );
  if (!before.rowCount) return res.status(404).json({ error: 'Device not found' });

  const previousCameraNodes = await query<{ dvr_server_id: string }>(
    `SELECT DISTINCT dvr_server_id
       FROM cameras
      WHERE device_id = $1
        AND dvr_server_id IS NOT NULL`,
    [req.params.id]
  );

  const sets = entries.map(([key], index) => `${key} = $${index + 2}`).join(', ');
  await query(`UPDATE devices SET ${sets}, archive_storage = 'node' WHERE id = $1`, [req.params.id, ...entries.map(([, value]) => value)]);

  const current = await query<{ dvr_server_id: string | null }>(
    `SELECT dvr_server_id FROM devices WHERE id = $1`,
    [req.params.id]
  );
  const placement = current.rows[0];

  await query(
    `UPDATE cameras
        SET dvr_server_id = $2,
            archive_storage = 'node'
      WHERE device_id = $1`,
    [req.params.id, placement.dvr_server_id]
  );

  const affectedNodeIds = [
    before.rows[0].dvr_server_id,
    placement.dvr_server_id,
    ...previousCameraNodes.rows.map((row) => row.dvr_server_id)
  ];
  const reloadCommands = await queueDeviceCameraReload(affectedNodeIds, {
    reason: 'device_updated',
    device_id: req.params.id,
    fields: entries.map(([key]) => key),
    inherited_node_id: placement.dvr_server_id
  });

  await audit(req, 'device.update', 'device', req.params.id, {
    fields: entries.map(([key]) => key),
    camera_placement_synchronized: true,
    reload_commands: reloadCommands
  });
  res.json({ ok: true, reload_queued: reloadCommands > 0 });
}));

devicesRouter.delete('/:id', requireRole('super_admin'), asyncHandler(async (req, res) => {
  const affected = await query<{ dvr_server_id: string }>(
    `SELECT DISTINCT dvr_server_id
       FROM cameras
      WHERE device_id = $1
        AND dvr_server_id IS NOT NULL`,
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

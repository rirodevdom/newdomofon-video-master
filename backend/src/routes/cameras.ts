import { Router } from 'express';
import { z } from 'zod';
import { query } from '../db.js';
import { requireAuth, requireRole, isAdmin } from '../middleware/auth.js';
import { asyncHandler } from '../utils/asyncHandler.js';
import { audit } from '../utils/audit.js';
import { canAccessCamera } from '../services/cameraAccess.js';
import type { AuthRequest } from '../types.js';

export const camerasRouter = Router();
camerasRouter.use(requireAuth);

const nullableString = z.string().nullable().optional();

const cameraCreateSchema = z.object({
  name: z.string().min(1),
  stream_name: z.string().regex(/^[a-zA-Z0-9_-]+$/),
  source_url: z.string().min(1),
  device_id: z.string().uuid(),
  group_id: z.string().uuid().nullable().optional(),
  rtmp_push_url: nullableString,
  latitude: z.number().nullable().optional(),
  longitude: z.number().nullable().optional(),
  direction_deg: z.number().int().nullable().optional(),
  fov_deg: z.number().int().nullable().optional(),
  retention_days: z.number().int().min(1).max(365).default(7),
  is_enabled: z.boolean().default(true),
  onvif_xaddr: nullableString,
  onvif_port: z.number().int().min(1).max(65535).nullable().optional(),
  onvif_username: nullableString,
  onvif_password: nullableString,
  onvif_profile_token: nullableString,
  onvif_device_info: z.record(z.any()).nullable().optional(),
  onvif_last_sync_at: z.string().datetime().nullable().optional(),
  _onvif_requery: z.boolean().optional()
}).strict();

const cameraConfigUpdateSchema = cameraCreateSchema
  .omit({ device_id: true })
  .partial()
  .strict();

const cameraEnabledSchema = z.object({
  is_enabled: z.boolean()
}).strict();

type DevicePlacement = {
  id: string;
  dvr_server_id: string | null;
  archive_storage: 'node' | 'device' | 'both';
};

function normalizeBody<T extends Record<string, unknown>>(body: T): T {
  const normalized: Record<string, unknown> = { ...body };
  for (const key of ['group_id', 'onvif_xaddr', 'onvif_port', 'onvif_username', 'onvif_password', 'onvif_profile_token', 'onvif_device_info', 'onvif_last_sync_at']) {
    if (key in body) normalized[key] = body[key] ?? null;
  }
  if ('rtmp_push_url' in body) normalized.rtmp_push_url = body.rtmp_push_url ?? null;
  if ('latitude' in body) normalized.latitude = body.latitude ?? null;
  if ('longitude' in body) normalized.longitude = body.longitude ?? null;
  if ('direction_deg' in body) normalized.direction_deg = body.direction_deg ?? null;
  if ('fov_deg' in body) normalized.fov_deg = body.fov_deg ?? null;
  return normalized as T;
}

function publicFields(input: Record<string, unknown>) {
  const clone: Record<string, unknown> = { ...input };
  delete clone._onvif_requery;
  return clone;
}

function uniqueNodeIds(values: Array<string | null | undefined>): string[] {
  return Array.from(new Set(values.map((value) => String(value || '').trim()).filter(Boolean)));
}

async function queueNodeCameraReload(
  nodeIds: Array<string | null | undefined>,
  payload: Record<string, unknown>
): Promise<number> {
  const ids = uniqueNodeIds(nodeIds);
  if (!ids.length) return 0;

  await query(
    `UPDATE dvr_servers
        SET config_generation = config_generation + 1
      WHERE id = ANY($1::uuid[])`,
    [ids]
  );

  const result = await query(
    `INSERT INTO node_commands(dvr_server_id, type, payload)
     SELECT id, 'reload_cameras', $2::jsonb
       FROM dvr_servers
      WHERE id = ANY($1::uuid[])
     RETURNING id`,
    [ids, JSON.stringify(payload)]
  );

  return result.rowCount || 0;
}

async function loadDevicePlacement(deviceId: string): Promise<DevicePlacement | null> {
  const result = await query<DevicePlacement>(
    `SELECT id, dvr_server_id, archive_storage
       FROM devices
      WHERE id = $1
      LIMIT 1`,
    [deviceId]
  );
  return result.rows[0] || null;
}

const cameraSelect = `
  c.id, c.group_id, device.dvr_server_id AS dvr_server_id, c.device_id,
  c.name, c.stream_name, c.source_url, device.archive_storage AS archive_storage,
  c.rtmp_push_url, c.latitude, c.longitude, c.direction_deg, c.fov_deg, c.retention_days,
  c.is_enabled, c.created_at, c.updated_at, c.onvif_xaddr, c.onvif_port, c.onvif_username,
  c.onvif_profile_token, c.onvif_device_info, c.onvif_last_sync_at,
  (c.onvif_xaddr IS NOT NULL) AS is_onvif
`;

camerasRouter.get('/', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  const baseQuery = `SELECT ${cameraSelect}, cg.name AS group_name, node.name AS dvr_server_name,
                            device.name AS device_name, device.connection_type AS device_connection_type,
                            device.archive_storage AS device_archive_storage,
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
}));

camerasRouter.get('/:id', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  if (!await canAccessCamera(authReq.user!, req.params.id)) return res.status(403).json({ error: 'Forbidden' });
  const result = await query(
    `SELECT ${cameraSelect},
            device.name AS device_name, device.connection_type AS device_connection_type,
            device.archive_storage AS device_archive_storage, node.name AS dvr_server_name
       FROM cameras c
       JOIN devices device ON device.id = c.device_id
       LEFT JOIN dvr_servers node ON node.id = device.dvr_server_id
      WHERE c.id = $1`,
    [req.params.id]
  );
  if (!result.rowCount) return res.status(404).json({ error: 'Camera not found' });
  res.json({ item: result.rows[0] });
}));

camerasRouter.post('/', requireRole('super_admin', 'operator'), asyncHandler(async (req, res) => {
  const body = normalizeBody(cameraCreateSchema.parse(req.body || {}));
  const device = await loadDevicePlacement(body.device_id);
  if (!device) return res.status(400).json({ error: 'Device is required for camera' });

  const result = await query<{ id: string; dvr_server_id: string | null }>(
    `INSERT INTO cameras(
       name, stream_name, source_url, group_id, dvr_server_id, device_id, rtmp_push_url,
       latitude, longitude, direction_deg, fov_deg, archive_storage, retention_days, is_enabled,
       onvif_xaddr, onvif_port, onvif_username, onvif_password, onvif_profile_token, onvif_device_info, onvif_last_sync_at
     )
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21)
     RETURNING id, dvr_server_id`,
    [
      body.name, body.stream_name, body.source_url, body.group_id ?? null,
      device.dvr_server_id, body.device_id, body.rtmp_push_url ?? null,
      body.latitude ?? null, body.longitude ?? null, body.direction_deg ?? null, body.fov_deg ?? null,
      device.archive_storage, body.retention_days, body.is_enabled,
      body.onvif_xaddr ?? null, body.onvif_port ?? null, body.onvif_username ?? null,
      body.onvif_password ?? null, body.onvif_profile_token ?? null,
      body.onvif_device_info ?? null, body.onvif_last_sync_at ?? null
    ]
  );

  const cameraId = result.rows[0].id;
  const reloadCommands = await queueNodeCameraReload([device.dvr_server_id], {
    reason: 'camera_created',
    camera_id: cameraId,
    stream_name: body.stream_name
  });

  await audit(req, 'camera.create', 'camera', cameraId, {
    stream_name: body.stream_name,
    device_id: body.device_id,
    inherited_node_id: device.dvr_server_id,
    inherited_archive_storage: device.archive_storage,
    type: body.onvif_xaddr ? 'onvif' : 'rtsp',
    reload_commands: reloadCommands
  });
  res.status(201).json({ id: cameraId, reload_queued: reloadCommands > 0 });
}));

async function updateCameraConfig(req: AuthRequest, res: any) {
  const raw = cameraConfigUpdateSchema.parse(req.body || {});
  const body = normalizeBody(raw);

  const existingResult = await query<{
    id: string;
    device_id: string;
    source_url: string;
    onvif_xaddr: string | null;
    dvr_server_id: string | null;
    archive_storage: 'node' | 'device' | 'both';
    stream_name: string;
  }>(
    `SELECT c.id, c.device_id, c.source_url, c.onvif_xaddr,
            device.dvr_server_id, device.archive_storage, c.stream_name
       FROM cameras c
       JOIN devices device ON device.id = c.device_id
      WHERE c.id = $1`,
    [req.params.id]
  );

  if (!existingResult.rowCount) return res.status(404).json({ error: 'Camera not found' });
  const existing = existingResult.rows[0];

  if (body.onvif_xaddr && body.source_url !== undefined && raw._onvif_requery !== true) {
    return res.status(409).json({
      error: 'ONVIF camera source_url can be changed only after ONVIF stream lookup.'
    });
  }

  const allowed = publicFields(body);
  const fields = Object.entries(allowed).filter(([, value]) => value !== undefined);
  const sets = fields.map(([key], index) => `${key} = $${index + 4}`);
  sets.push('dvr_server_id = $2', 'archive_storage = $3');

  const updated = await query<{ stream_name: string }>(
    `UPDATE cameras
        SET ${sets.join(', ')}
      WHERE id = $1
      RETURNING stream_name`,
    [req.params.id, existing.dvr_server_id, existing.archive_storage, ...fields.map(([, value]) => value)]
  );

  const currentStreamName = updated.rows[0]?.stream_name || existing.stream_name;
  const reloadCommands = await queueNodeCameraReload([existing.dvr_server_id], {
    reason: 'camera_config_updated',
    camera_id: req.params.id,
    old_stream_name: existing.stream_name,
    stream_name: currentStreamName,
    fields: fields.map(([key]) => key)
  });

  await audit(req, 'camera.config_update', 'camera', req.params.id, {
    device_id: existing.device_id,
    inherited_node_id: existing.dvr_server_id,
    inherited_archive_storage: existing.archive_storage,
    fields: fields.map(([key]) => key),
    reload_commands: reloadCommands
  });
  res.json({ ok: true, reload_queued: reloadCommands > 0 });
}

async function updateCameraEnabled(req: AuthRequest, res: any) {
  const body = cameraEnabledSchema.parse(req.body || {});
  const existing = await query<{
    device_id: string;
    dvr_server_id: string | null;
    archive_storage: 'node' | 'device' | 'both';
    stream_name: string;
  }>(
    `SELECT c.device_id, device.dvr_server_id, device.archive_storage, c.stream_name
       FROM cameras c
       JOIN devices device ON device.id = c.device_id
      WHERE c.id = $1`,
    [req.params.id]
  );
  if (!existing.rowCount) return res.status(404).json({ error: 'Camera not found' });

  const camera = existing.rows[0];
  await query(
    `UPDATE cameras
        SET is_enabled = $2,
            dvr_server_id = $3,
            archive_storage = $4
      WHERE id = $1`,
    [req.params.id, body.is_enabled, camera.dvr_server_id, camera.archive_storage]
  );

  const reloadCommands = await queueNodeCameraReload([camera.dvr_server_id], {
    reason: body.is_enabled ? 'camera_enabled' : 'camera_disabled',
    camera_id: req.params.id,
    stream_name: camera.stream_name
  });

  await audit(req, 'camera.enabled_update', 'camera', req.params.id, {
    is_enabled: body.is_enabled,
    reload_commands: reloadCommands
  });
  res.json({ ok: true, reload_queued: reloadCommands > 0 });
}

camerasRouter.patch('/:id/config', requireRole('super_admin', 'operator'), asyncHandler(updateCameraConfig));
camerasRouter.put('/:id/config', requireRole('super_admin', 'operator'), asyncHandler(updateCameraConfig));
camerasRouter.patch('/:id', requireRole('super_admin', 'operator'), asyncHandler(updateCameraEnabled));
camerasRouter.put('/:id', requireRole('super_admin', 'operator'), asyncHandler(updateCameraEnabled));

camerasRouter.delete('/:id', requireRole('super_admin'), asyncHandler(async (req, res) => {
  const existing = await query<{ dvr_server_id: string | null; stream_name: string }>(
    `SELECT device.dvr_server_id, c.stream_name
       FROM cameras c
       JOIN devices device ON device.id = c.device_id
      WHERE c.id = $1`,
    [req.params.id]
  );
  if (!existing.rowCount) return res.status(404).json({ error: 'Camera not found' });

  await query('DELETE FROM cameras WHERE id = $1', [req.params.id]);
  const reloadCommands = await queueNodeCameraReload([existing.rows[0].dvr_server_id], {
    reason: 'camera_deleted',
    camera_id: req.params.id,
    stream_name: existing.rows[0].stream_name
  });

  await audit(req, 'camera.delete', 'camera', req.params.id, { reload_commands: reloadCommands });
  res.json({ ok: true, reload_queued: reloadCommands > 0 });
}));

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
  retention_days: z.number().int().min(1).max(365).default(7),
  is_enabled: z.boolean().default(true),
  onvif_xaddr: nullableString,
  onvif_port: z.number().int().min(1).max(65535).nullable().optional(),
  onvif_username: nullableString,
  onvif_password: nullableString,
  onvif_profile_token: nullableString,
  onvif_device_info: z.record(z.any()).nullable().optional(),
  onvif_last_sync_at: z.string().datetime().nullable().optional()
});

const cameraConfigSchema = cameraCreateSchema
  .omit({ device_id: true, is_enabled: true })
  .partial()
  .extend({ _onvif_requery: z.boolean().optional() });
const cameraEnabledSchema = z.object({ is_enabled: z.boolean() }).strict();

function normalizeConfig(body: Record<string, unknown>) {
  const normalized: Record<string, unknown> = { ...body };
  delete normalized._onvif_requery;
  for (const key of ['group_id', 'onvif_xaddr', 'onvif_port', 'onvif_username', 'onvif_password', 'onvif_profile_token', 'onvif_device_info', 'onvif_last_sync_at']) {
    if (key in normalized) normalized[key] = normalized[key] ?? null;
  }
  return normalized;
}

function uniqueNodeIds(values: Array<string | null | undefined>): string[] {
  return Array.from(new Set(values.map((value) => String(value || '').trim()).filter(Boolean)));
}

async function queueNodeCameraReload(nodeIds: Array<string | null | undefined>, payload: Record<string, unknown>): Promise<number> {
  const ids = uniqueNodeIds(nodeIds);
  if (!ids.length) return 0;
  await query(
    `UPDATE dvr_servers SET config_generation=config_generation+1, updated_at=now()
      WHERE id=ANY($1::uuid[])`,
    [ids]
  );
  const result = await query(
    `INSERT INTO node_commands(dvr_server_id,type,payload)
     SELECT id,'reload_cameras',$2::jsonb FROM dvr_servers WHERE id=ANY($1::uuid[])
     RETURNING id`,
    [ids, JSON.stringify(payload)]
  );
  return result.rowCount || 0;
}

const cameraSelect = `
  c.id, c.group_id, c.dvr_server_id, c.device_id, c.name, c.stream_name, c.source_url,
  c.archive_storage, c.retention_days, c.is_enabled, c.created_at, c.updated_at,
  c.onvif_xaddr, c.onvif_port, c.onvif_username, c.onvif_profile_token,
  c.onvif_device_info, c.onvif_last_sync_at,
  (c.onvif_xaddr IS NOT NULL) AS is_onvif
`;

camerasRouter.get('/', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  const where = isAdmin(authReq) ? '' : 'WHERE c.is_enabled=true';
  const result = await query(
    `SELECT ${cameraSelect}, cg.name AS group_name,
            d.name AS device_name, d.connection_type AS device_connection_type,
            d.archive_storage AS device_archive_storage, d.dvr_server_id AS device_dvr_server_id,
            ds.name AS dvr_server_name,
            EXISTS(SELECT 1 FROM user_favorites f WHERE f.camera_id=c.id AND f.user_id=$1) AS favorite
       FROM cameras c
       LEFT JOIN camera_groups cg ON cg.id=c.group_id
       JOIN devices d ON d.id=c.device_id
       LEFT JOIN dvr_servers ds ON ds.id=d.dvr_server_id
       ${where}
      ORDER BY c.name ASC`,
    [authReq.user!.id]
  );
  res.json({ items: result.rows });
}));

camerasRouter.get('/:id', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  if (!await canAccessCamera(authReq.user!, req.params.id)) return res.status(403).json({ error: 'Forbidden' });
  const result = await query(
    `SELECT ${cameraSelect}, d.name AS device_name, d.connection_type AS device_connection_type,
            d.archive_storage AS device_archive_storage, d.dvr_server_id AS device_dvr_server_id,
            ds.name AS dvr_server_name
       FROM cameras c
       JOIN devices d ON d.id=c.device_id
       LEFT JOIN dvr_servers ds ON ds.id=d.dvr_server_id
      WHERE c.id=$1`,
    [req.params.id]
  );
  if (!result.rowCount) return res.status(404).json({ error: 'Camera not found' });
  res.json({ item: result.rows[0] });
}));

camerasRouter.post('/', requireRole('super_admin', 'operator'), asyncHandler(async (req, res) => {
  const body = cameraCreateSchema.parse(req.body || {});
  const deviceResult = await query<{ id: string; dvr_server_id: string | null; archive_storage: string }>(
    'SELECT id,dvr_server_id,archive_storage FROM devices WHERE id=$1',
    [body.device_id]
  );
  const device = deviceResult.rows[0];
  if (!device) return res.status(400).json({ error: 'Device is required for camera' });

  const result = await query<{ id: string }>(
    `INSERT INTO cameras(
       name,stream_name,source_url,group_id,dvr_server_id,device_id,archive_storage,
       retention_days,is_enabled,onvif_xaddr,onvif_port,onvif_username,onvif_password,
       onvif_profile_token,onvif_device_info,onvif_last_sync_at
     ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)
     RETURNING id`,
    [body.name, body.stream_name, body.source_url, body.group_id ?? null,
     device.dvr_server_id, body.device_id, device.archive_storage, body.retention_days,
     body.is_enabled, body.onvif_xaddr ?? null, body.onvif_port ?? null,
     body.onvif_username ?? null, body.onvif_password ?? null,
     body.onvif_profile_token ?? null, body.onvif_device_info ?? null,
     body.onvif_last_sync_at ?? null]
  );
  const cameraId = result.rows[0].id;
  const reloadCommands = await queueNodeCameraReload([device.dvr_server_id], {
    reason: 'camera_created', camera_id: cameraId, stream_name: body.stream_name
  });
  await audit(req, 'camera.create', 'camera', cameraId, {
    stream_name: body.stream_name, device_id: body.device_id, reload_commands: reloadCommands
  });
  res.status(201).json({ id: cameraId, reload_queued: reloadCommands > 0 });
}));

camerasRouter.patch('/:id/config', requireRole('super_admin', 'operator'), asyncHandler(async (req, res) => {
  const raw = cameraConfigSchema.parse(req.body || {});
  const existingResult = await query<{
    id: string; stream_name: string; dvr_server_id: string | null; onvif_xaddr: string | null;
  }>('SELECT id,stream_name,dvr_server_id,onvif_xaddr FROM cameras WHERE id=$1', [req.params.id]);
  const existing = existingResult.rows[0];
  if (!existing) return res.status(404).json({ error: 'Camera not found' });
  if (raw.onvif_xaddr && raw.source_url !== undefined && raw._onvif_requery !== true) {
    return res.status(409).json({ error: 'ONVIF source_url can be changed only after ONVIF stream lookup.' });
  }
  const body = normalizeConfig(raw as Record<string, unknown>);
  const fields = Object.entries(body).filter(([, value]) => value !== undefined);
  if (!fields.length) return res.json({ ok: true, reload_queued: false });
  const sets = fields.map(([key], index) => `${key}=$${index + 2}`).join(', ');
  const updated = await query<{ stream_name: string; dvr_server_id: string | null }>(
    `UPDATE cameras SET ${sets} WHERE id=$1 RETURNING stream_name,dvr_server_id`,
    [req.params.id, ...fields.map(([, value]) => value)]
  );
  const current = updated.rows[0];
  const reloadCommands = await queueNodeCameraReload([existing.dvr_server_id, current.dvr_server_id], {
    reason: 'camera_config_updated', camera_id: req.params.id,
    old_stream_name: existing.stream_name, stream_name: current.stream_name,
    fields: fields.map(([key]) => key)
  });
  await audit(req, 'camera.config_update', 'camera', req.params.id, {
    fields: fields.map(([key]) => key), reload_commands: reloadCommands
  });
  res.json({ ok: true, reload_queued: reloadCommands > 0 });
}));

const updateEnabled = asyncHandler(async (req, res) => {
  const body = cameraEnabledSchema.parse(req.body || {});
  const result = await query<{ dvr_server_id: string | null; stream_name: string }>(
    `UPDATE cameras SET is_enabled=$2 WHERE id=$1 RETURNING dvr_server_id,stream_name`,
    [req.params.id, body.is_enabled]
  );
  const camera = result.rows[0];
  if (!camera) return res.status(404).json({ error: 'Camera not found' });
  const reloadCommands = await queueNodeCameraReload([camera.dvr_server_id], {
    reason: body.is_enabled ? 'camera_enabled' : 'camera_disabled',
    camera_id: req.params.id, stream_name: camera.stream_name
  });
  await audit(req, 'camera.enabled_update', 'camera', req.params.id, {
    is_enabled: body.is_enabled, reload_commands: reloadCommands
  });
  res.json({ ok: true, reload_queued: reloadCommands > 0 });
});

camerasRouter.patch('/:id', requireRole('super_admin', 'operator'), updateEnabled);
camerasRouter.put('/:id', requireRole('super_admin', 'operator'), updateEnabled);

camerasRouter.delete('/:id', requireRole('super_admin'), asyncHandler(async (req, res) => {
  const existing = await query<{ dvr_server_id: string | null; stream_name: string }>(
    'SELECT dvr_server_id,stream_name FROM cameras WHERE id=$1', [req.params.id]
  );
  if (!existing.rowCount) return res.status(404).json({ error: 'Camera not found' });
  await query('DELETE FROM cameras WHERE id=$1', [req.params.id]);
  const reloadCommands = await queueNodeCameraReload([existing.rows[0].dvr_server_id], {
    reason: 'camera_deleted', camera_id: req.params.id, stream_name: existing.rows[0].stream_name
  });
  await audit(req, 'camera.delete', 'camera', req.params.id, { reload_commands: reloadCommands });
  res.json({ ok: true, reload_queued: reloadCommands > 0 });
}));

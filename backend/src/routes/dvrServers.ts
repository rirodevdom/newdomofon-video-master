import { Router } from 'express';
import crypto from 'node:crypto';
import { z } from 'zod';
import { query } from '../db.js';
import { requireAuth, requireRole } from '../middleware/auth.js';
import { asyncHandler } from '../utils/asyncHandler.js';
import { audit } from '../utils/audit.js';

export const dvrServersRouter = Router();
dvrServersRouter.use(requireAuth);

const safeSecret = z.string()
  .trim()
  .min(16)
  .max(512)
  .regex(/^[A-Za-z0-9._~-]+$/, 'Use only letters, digits, dot, underscore, tilde and hyphen');

const schema = z.object({
  name: z.string().trim().min(1).max(120),
  base_url: z.string().min(1).optional(),
  public_base_url: z.string().min(1).optional(),
  internal_url: z.string().optional().nullable(),
  is_enabled: z.boolean().optional(),
  capabilities: z.record(z.any()).optional()
}).strict();

const createSchema = schema.extend({
  master_url: z.string().url(),
  node_id: z.string().uuid(),
  agent_token: safeSecret,
  media_secret: safeSecret,
  public_base_url: z.string().url(),
  internal_url: z.string().url()
}).strict();

const rotateSchema = z.object({
  agent_token: safeSecret,
  media_secret: safeSecret
}).strict();

function sha256(raw: string): string {
  return crypto.createHash('sha256').update(raw).digest('hex');
}

dvrServersRouter.get('/', asyncHandler(async (_req, res) => {
  const result = await query(
    `SELECT id, name, base_url, public_base_url, internal_url, status, last_seen_at,
            version, capabilities, storage, is_enabled, config_generation,
            created_at, updated_at,
            EXISTS(SELECT 1 FROM devices d WHERE d.dvr_server_id = dvr_servers.id) AS has_cameras,
            (SELECT count(*)::int
               FROM cameras c
               JOIN devices d ON d.id = c.device_id
              WHERE d.dvr_server_id = dvr_servers.id) AS camera_count,
            (SELECT count(*)::int FROM devices d WHERE d.dvr_server_id = dvr_servers.id) AS device_count
       FROM dvr_servers
      ORDER BY created_at DESC`
  );
  res.json({ items: result.rows });
}));

dvrServersRouter.post('/', requireRole('super_admin', 'operator'), asyncHandler(async (req, res) => {
  const body = createSchema.parse(req.body || {});
  const duplicate = await query<{ id: string; name: string }>(
    'SELECT id, name FROM dvr_servers WHERE id = $1',
    [body.node_id]
  );
  if (duplicate.rowCount) {
    return res.status(409).json({
      error: 'Node с таким DVR_NODE_ID уже существует',
      node: duplicate.rows[0]
    });
  }

  const publicBaseUrl = body.public_base_url;
  const capabilities = {
    ...(body.capabilities || {}),
    manual_registration: {
      master_url: body.master_url,
      credential_source: 'operator_supplied'
    }
  };
  const result = await query<{ id: string }>(
    `INSERT INTO dvr_servers(
       id, name, base_url, public_base_url, internal_url, status,
       agent_token_hash, media_secret, is_enabled, capabilities
     )
     VALUES ($1,$2,$3,$4,$5,'unknown',$6,$7,$8,$9)
     RETURNING id`,
    [
      body.node_id,
      body.name,
      publicBaseUrl,
      publicBaseUrl,
      body.internal_url,
      sha256(body.agent_token),
      body.media_secret,
      body.is_enabled ?? true,
      JSON.stringify(capabilities)
    ]
  );
  await audit(req, 'dvr_server.create', 'dvr_server', result.rows[0].id, {
    credential_source: 'operator_supplied',
    master_url: body.master_url
  });
  res.status(201).json({
    id: result.rows[0].id,
    node_id: result.rows[0].id,
    master_url: body.master_url,
    credential_source: 'operator_supplied'
  });
}));

dvrServersRouter.patch('/:id', requireRole('super_admin', 'operator'), asyncHandler(async (req, res) => {
  const body = schema.partial().parse(req.body || {});
  const normalized = {
    ...body,
    base_url: body.public_base_url || body.base_url,
    public_base_url: body.public_base_url || body.base_url
  };
  const fields = Object.entries(normalized).filter(([, value]) => value !== undefined);
  if (fields.length) {
    const sets = fields.map(([key], index) => `${key} = $${index + 2}`).join(', ');
    const values = fields.map(([key, value]) => key === 'capabilities' ? JSON.stringify(value) : value);
    await query(`UPDATE dvr_servers SET ${sets}, config_generation = config_generation + 1 WHERE id = $1`, [req.params.id, ...values]);
  }
  await audit(req, 'dvr_server.update', 'dvr_server', req.params.id, { fields: fields.map(([key]) => key) });
  res.json({ ok: true });
}));

dvrServersRouter.post('/:id/rotate-token', requireRole('super_admin'), asyncHandler(async (req, res) => {
  const body = rotateSchema.parse(req.body || {});
  const result = await query(
    `UPDATE dvr_servers
        SET agent_token_hash = $2,
            media_secret = $3,
            config_generation = config_generation + 1
      WHERE id = $1
      RETURNING id`,
    [req.params.id, sha256(body.agent_token), body.media_secret]
  );
  if (!result.rowCount) return res.status(404).json({ error: 'Node not found' });
  await audit(req, 'dvr_server.rotate_token', 'dvr_server', req.params.id, {
    credential_source: 'operator_supplied'
  });
  res.json({ ok: true, node_id: req.params.id });
}));

// Camera placement is owned by the parent device. Keep the old endpoint explicit
// so older clients receive a useful error instead of silently creating divergence.
dvrServersRouter.post('/:id/assign-cameras', requireRole('super_admin', 'operator'), asyncHandler(async (_req, res) => {
  res.status(409).json({
    error: 'Камеры наследуют video node от устройства. Измените node в настройках устройства.'
  });
}));

dvrServersRouter.post('/:id/commands', requireRole('super_admin', 'operator'), asyncHandler(async (req, res) => {
  const body = z.object({
    type: z.string().min(1),
    payload: z.record(z.any()).optional()
  }).parse(req.body || {});
  const result = await query<{ id: string }>(
    'INSERT INTO node_commands(dvr_server_id, type, payload) VALUES ($1,$2,$3) RETURNING id',
    [req.params.id, body.type, JSON.stringify(body.payload || {})]
  );
  await audit(req, 'node_command.create', 'dvr_server', req.params.id, { command_id: result.rows[0].id, type: body.type });
  res.status(201).json({ id: result.rows[0].id });
}));

dvrServersRouter.delete('/:id', requireRole('super_admin'), asyncHandler(async (req, res) => {
  const assigned = await query<{ id: string; name: string }>(
    `SELECT id, name FROM devices WHERE dvr_server_id = $1 ORDER BY name LIMIT 20`,
    [req.params.id]
  );
  if (assigned.rowCount) {
    return res.status(409).json({
      error: 'Сначала перенесите или удалите устройства, назначенные этой node.',
      devices: assigned.rows
    });
  }

  const result = await query('DELETE FROM dvr_servers WHERE id = $1 RETURNING id', [req.params.id]);
  if (!result.rowCount) return res.status(404).json({ error: 'Node not found' });
  await audit(req, 'dvr_server.delete', 'dvr_server', req.params.id);
  res.json({ ok: true });
}));

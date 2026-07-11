import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { query } from '../db.js';
import { requireAuth, requireRole } from '../middleware/auth.js';
import { signManagedCameraToken } from '../services/managedCameraToken.js';
import type { AuthRequest } from '../types.js';
import { asyncHandler } from '../utils/asyncHandler.js';

export const managedCameraTokensRouter = Router();

const scopeSchema = z.enum(['camera', 'events']);
const createSchema = z.object({
  name: z.string().trim().min(1).max(120),
  description: z.string().trim().max(500).optional().nullable(),
  scopes: z.array(scopeSchema).min(1).optional().default(['camera', 'events']),
  expires_at: z.string().trim().optional().nullable()
});
const updateSchema = z.object({
  name: z.string().trim().min(1).max(120).optional(),
  description: z.string().trim().max(500).optional().nullable(),
  scopes: z.array(scopeSchema).min(1).optional(),
  is_active: z.boolean().optional(),
  expires_at: z.string().trim().optional().nullable()
});
const cameraLinkSchema = z.object({ managed_token_id: z.string().uuid() });

managedCameraTokensRouter.use(requireAuth, requireRole('super_admin'));

type ManagedTokenRow = {
  id: string;
  name: string;
  description: string | null;
  generation: number;
  scopes: string[];
  is_active: boolean;
  expires_at: string | null;
  created_by: string | null;
  last_used_at: string | null;
  created_at: string;
  updated_at: string;
  assigned_cameras?: Array<{ id: string; name: string; stream_name: string; assigned_at?: string }>;
};

type CameraLinkRow = {
  id: string;
  name: string;
  stream_name: string;
  archive_storage: 'node' | 'device' | 'both';
  device_archive_storage: 'node' | 'device' | 'both' | null;
  node_name: string | null;
  node_enabled: boolean | null;
  node_media_secret_configured: boolean;
};

function parseExpiresAt(value: string | null | undefined): Date | null {
  if (value === undefined || value === null || value === '') return null;
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime())) throw new Error('Invalid expires_at');
  return parsed;
}

function publicOrigin(req: AuthRequest): string {
  const configured = String(
    process.env.SMARTYARD_PUBLIC_BASE_URL ||
    process.env.APP_PUBLIC_URL ||
    process.env.PUBLIC_BACKEND_BASE_URL ||
    ''
  ).replace(/\/+$/, '');
  if (configured) return configured;
  const proto = String(req.headers['x-forwarded-proto'] || req.protocol || 'https').split(',')[0].trim();
  const host = String(req.headers['x-forwarded-host'] || req.headers.host || '').split(',')[0].trim();
  return host ? `${proto}://${host}` : '';
}

function serializeToken(row: ManagedTokenRow) {
  return {
    ...row,
    scopes: Array.isArray(row.scopes) ? row.scopes : [],
    assigned_cameras: Array.isArray(row.assigned_cameras) ? row.assigned_cameras : [],
    token: signManagedCameraToken(row.id, Number(row.generation))
  };
}

async function loadToken(tokenId: string): Promise<ManagedTokenRow | null> {
  const result = await query<ManagedTokenRow>(
    `SELECT id, name, description, generation, scopes, is_active, expires_at,
            created_by, last_used_at, created_at, updated_at
       FROM managed_camera_tokens
      WHERE id = $1
      LIMIT 1`,
    [tokenId]
  );
  return result.rows[0] || null;
}

async function ensureUniqueName(name: string, excludedId?: string) {
  const result = await query(
    `SELECT 1 FROM managed_camera_tokens
      WHERE lower(name) = lower($1)
        AND ($2::uuid IS NULL OR id <> $2::uuid)
      LIMIT 1`,
    [name, excludedId || null]
  );
  if (result.rows.length) {
    const error = new Error('Токен с таким именем уже существует') as Error & { status?: number };
    error.status = 409;
    throw error;
  }
}

managedCameraTokensRouter.get('/managed-camera-tokens', asyncHandler(async (_req, res) => {
  const result = await query<ManagedTokenRow>(
    `SELECT t.id, t.name, t.description, t.generation, t.scopes, t.is_active,
            t.expires_at, t.created_by, t.last_used_at, t.created_at, t.updated_at,
            COALESCE(
              jsonb_agg(
                jsonb_build_object(
                  'id', c.id,
                  'name', c.name,
                  'stream_name', c.stream_name,
                  'assigned_at', mtc.created_at
                ) ORDER BY c.name, c.stream_name, mtc.created_at
              ) FILTER (WHERE c.id IS NOT NULL),
              '[]'::jsonb
            ) AS assigned_cameras
       FROM managed_camera_tokens t
       LEFT JOIN managed_camera_token_cameras mtc ON mtc.token_id = t.id
       LEFT JOIN cameras c ON c.id = mtc.camera_id
      GROUP BY t.id
      ORDER BY t.created_at DESC, t.name ASC`
  );
  res.json({ items: result.rows.map(serializeToken) });
}));

managedCameraTokensRouter.post('/managed-camera-tokens', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  if (!authReq.user) return res.status(401).json({ error: 'Unauthorized' });
  const body = createSchema.parse(req.body || {});
  await ensureUniqueName(body.name);
  const expiresAt = parseExpiresAt(body.expires_at);
  if (expiresAt && expiresAt.getTime() <= Date.now()) {
    return res.status(400).json({ error: 'Срок действия должен быть в будущем' });
  }
  const result = await query<ManagedTokenRow>(
    `INSERT INTO managed_camera_tokens(
       id, name, description, generation, scopes, is_active, expires_at, created_by
     ) VALUES ($1,$2,$3,1,$4,true,$5,$6)
     RETURNING id, name, description, generation, scopes, is_active, expires_at,
               created_by, last_used_at, created_at, updated_at`,
    [crypto.randomUUID(), body.name, body.description || null, body.scopes, expiresAt, authReq.user.id]
  );
  res.status(201).json({ item: serializeToken({ ...result.rows[0], assigned_cameras: [] }) });
}));

managedCameraTokensRouter.patch('/managed-camera-tokens/:tokenId', asyncHandler(async (req, res) => {
  const tokenId = z.string().uuid().parse(req.params.tokenId);
  const body = updateSchema.parse(req.body || {});
  const current = await loadToken(tokenId);
  if (!current) return res.status(404).json({ error: 'Токен не найден' });
  const name = body.name ?? current.name;
  const description = body.description === undefined ? current.description : (body.description || null);
  const scopes = body.scopes ?? current.scopes;
  const isActive = body.is_active ?? current.is_active;
  const expiresAt = body.expires_at === undefined ? current.expires_at : parseExpiresAt(body.expires_at);
  if (body.name !== undefined) await ensureUniqueName(name, tokenId);
  const result = await query<ManagedTokenRow>(
    `UPDATE managed_camera_tokens
        SET name=$2, description=$3, scopes=$4, is_active=$5, expires_at=$6
      WHERE id=$1
      RETURNING id, name, description, generation, scopes, is_active, expires_at,
                created_by, last_used_at, created_at, updated_at`,
    [tokenId, name, description, scopes, isActive, expiresAt]
  );
  res.json({ item: serializeToken({ ...result.rows[0], assigned_cameras: current.assigned_cameras || [] }) });
}));

managedCameraTokensRouter.post('/managed-camera-tokens/:tokenId/rotate', asyncHandler(async (req, res) => {
  const tokenId = z.string().uuid().parse(req.params.tokenId);
  const result = await query<ManagedTokenRow>(
    `UPDATE managed_camera_tokens
        SET generation=generation+1, is_active=true, last_used_at=NULL
      WHERE id=$1
      RETURNING id, name, description, generation, scopes, is_active, expires_at,
                created_by, last_used_at, created_at, updated_at`,
    [tokenId]
  );
  if (!result.rows[0]) return res.status(404).json({ error: 'Токен не найден' });
  res.json({ item: serializeToken({ ...result.rows[0], assigned_cameras: [] }) });
}));

managedCameraTokensRouter.delete('/managed-camera-tokens/:tokenId', asyncHandler(async (req, res) => {
  const tokenId = z.string().uuid().parse(req.params.tokenId);
  const result = await query('DELETE FROM managed_camera_tokens WHERE id=$1 RETURNING id', [tokenId]);
  if (!result.rows[0]) return res.status(404).json({ error: 'Токен не найден' });
  res.status(204).end();
}));

managedCameraTokensRouter.delete('/managed-camera-tokens/:tokenId/cameras/:cameraId', asyncHandler(async (req, res) => {
  const tokenId = z.string().uuid().parse(req.params.tokenId);
  const cameraId = z.string().uuid().parse(req.params.cameraId);
  await query('DELETE FROM managed_camera_token_cameras WHERE token_id=$1 AND camera_id=$2', [tokenId, cameraId]);
  res.status(204).end();
}));

const openCameraLinks = asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  if (!authReq.user) return res.status(401).json({ error: 'Unauthorized' });
  const cameraId = z.string().uuid().parse(req.params.cameraId);
  const body = cameraLinkSchema.parse(req.body || {});
  const token = await loadToken(body.managed_token_id);
  if (!token) return res.status(404).json({ error: 'Выбранный токен не найден' });
  if (!token.is_active) return res.status(409).json({ error: 'Выбранный токен отключён' });
  if (token.expires_at && new Date(token.expires_at).getTime() <= Date.now()) {
    return res.status(409).json({ error: 'Срок действия выбранного токена истёк' });
  }
  if (!token.scopes.includes('camera')) {
    return res.status(409).json({ error: 'Выбранный токен не имеет доступа к видео камеры' });
  }

  const cameraResult = await query<CameraLinkRow>(
    `SELECT c.id, c.name, c.stream_name, c.archive_storage,
            d.archive_storage AS device_archive_storage,
            ds.name AS node_name,
            ds.is_enabled AS node_enabled,
            (ds.media_secret IS NOT NULL AND length(ds.media_secret)>0) AS node_media_secret_configured
       FROM cameras c
       JOIN devices d ON d.id=c.device_id
       LEFT JOIN dvr_servers ds ON ds.id=d.dvr_server_id
      WHERE c.id=$1 AND c.is_enabled=true
      LIMIT 1`,
    [cameraId]
  );
  const camera = cameraResult.rows[0];
  if (!camera) return res.status(404).json({ error: 'Камера не найдена' });
  if (!camera.node_enabled || !camera.node_media_secret_configured) {
    return res.status(409).json({ error: 'Node устройства отключена или не имеет media secret' });
  }

  const origin = publicOrigin(authReq);
  if (!origin) return res.status(500).json({ error: 'Публичный адрес видеосервера не определён' });

  const assignment = await query(
    `INSERT INTO managed_camera_token_cameras(token_id,camera_id,created_by,created_at)
     VALUES ($1,$2,$3,now())
     ON CONFLICT (token_id,camera_id) DO UPDATE
       SET created_by=EXCLUDED.created_by,
           created_at=now()
     RETURNING created_at`,
    [token.id, camera.id, authReq.user.id]
  );

  const rawToken = signManagedCameraToken(token.id, Number(token.generation));
  const encodedToken = encodeURIComponent(rawToken);
  const stream = encodeURIComponent(camera.stream_name);
  const base = `${origin}/${stream}`;
  const cameraUrl = `${base}/?token=${encodedToken}`;
  const effectiveArchive = camera.device_archive_storage === 'both'
    ? 'both'
    : (camera.device_archive_storage || camera.archive_storage || 'node');

  res.json({
    camera: { id: camera.id, name: camera.name, stream_name: camera.stream_name },
    managed_token: {
      id: token.id,
      name: token.name,
      scopes: token.scopes,
      expires_at: token.expires_at,
      generation: token.generation
    },
    assignment_changed: true,
    assignment_created_at: assignment.rows[0]?.created_at || null,
    mode: 'managed-token',
    node_name: camera.node_name,
    camera_token: rawToken,
    live_token: rawToken,
    archive_token: rawToken,
    smartyard_url: cameraUrl,
    common_url: cameraUrl,
    camera_url: cameraUrl,
    player_url: cameraUrl,
    primary_url: cameraUrl,
    live_url: `${base}/index.m3u8?token=${encodedToken}`,
    archive_url_template: `${base}/archive.m3u8?start=<ISO_START>&end=<ISO_END>&token=${encodedToken}`,
    events_url_template: `${base}/events.json?start=<ISO_START>&end=<ISO_END>&token=${encodedToken}`,
    archive_source: effectiveArchive,
    expires_at: token.expires_at,
    permanent: token.expires_at === null,
    note: 'Токен добавлен к камере или его существующая привязка обновлена. Другие токены камеры сохранены.'
  });
});

managedCameraTokensRouter.post('/camera-links/:cameraId', openCameraLinks);
managedCameraTokensRouter.post('/smartyard-links/:cameraId', openCameraLinks);

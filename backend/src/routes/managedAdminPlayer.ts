import { Router } from 'express';
import { z } from 'zod';
import { query } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { canAccessCamera } from '../services/cameraAccess.js';
import { signManagedCameraToken } from '../services/managedCameraToken.js';
import { decryptManualManagedCameraToken } from '../services/manualManagedCameraToken.js';
import type { AuthRequest } from '../types.js';
import { asyncHandler } from '../utils/asyncHandler.js';

export const managedAdminPlayerRouter = Router();

const SYSTEM_MANAGED_TOKEN_ID = '00000000-0000-4000-8000-000000000001';

const archiveSchema = z.object({
  start: z.string().datetime(),
  end: z.string().datetime(),
  source: z.enum(['auto', 'node']).optional()
});

type ManagedPlayerRow = {
  camera_id: string;
  camera_name: string;
  stream_name: string;
  token_id: string;
  token_name: string;
  token_mode: 'generated' | 'manual';
  token_manual_ciphertext: string | null;
  token_generation: number;
  token_expires_at: string | null;
  assignment_created_at: string;
};

function cameraGatewayBase(raw: unknown): string {
  const configured = String(raw || '').trim().replace(/\/+$/, '');
  if (!configured) return '';
  return /\/cameras$/i.test(configured) ? configured : `${configured}/cameras`;
}

function publicCameraBase(req: AuthRequest): string {
  const applicationBase = cameraGatewayBase(
    process.env.APP_PUBLIC_URL ||
    process.env.APP_PUBLIC_BASE_URL ||
    process.env.PUBLIC_BACKEND_BASE_URL ||
    ''
  );
  if (applicationBase) return applicationBase;

  const smartYardBase = cameraGatewayBase(process.env.SMARTYARD_PUBLIC_BASE_URL || '');
  if (smartYardBase) return smartYardBase;

  const proto = String(req.headers['x-forwarded-proto'] || req.protocol || 'https').split(',')[0].trim();
  const host = String(req.headers['x-forwarded-host'] || req.headers.host || '').split(',')[0].trim();
  return host ? `${proto}://${host}/cameras` : '';
}

async function loadManagedPlayerAccess(cameraId: string): Promise<ManagedPlayerRow | null> {
  const result = await query<ManagedPlayerRow>(
    `SELECT c.id AS camera_id,
            c.name AS camera_name,
            c.stream_name,
            token.id AS token_id,
            token.name AS token_name,
            token.token_mode AS token_mode,
            token.manual_token_ciphertext AS token_manual_ciphertext,
            token.generation AS token_generation,
            token.expires_at AS token_expires_at,
            assignment.created_at AS assignment_created_at
       FROM cameras c
       JOIN managed_camera_token_cameras assignment ON assignment.camera_id = c.id
       JOIN managed_camera_tokens token ON token.id = assignment.token_id
      WHERE c.id = $1
        AND c.is_enabled = true
        AND token.is_active = true
        AND (token.expires_at IS NULL OR token.expires_at > now())
        AND token.scopes @> ARRAY['camera']::text[]
      ORDER BY
        CASE WHEN token.id = $2::uuid THEN 1 ELSE 0 END,
        assignment.created_at DESC,
        token.created_at DESC
      LIMIT 1`,
    [cameraId, SYSTEM_MANAGED_TOKEN_ID]
  );
  return result.rows[0] || null;
}

function managedTokenMetadata(row: ManagedPlayerRow) {
  return {
    id: row.token_id,
    name: row.token_name,
    system: row.token_id === SYSTEM_MANAGED_TOKEN_ID,
    expires_at: row.token_expires_at,
    assignment_created_at: row.assignment_created_at
  };
}

function rawManagedPlayerToken(row: ManagedPlayerRow): string {
  return row.token_mode === 'manual'
    ? decryptManualManagedCameraToken(String(row.token_manual_ciphertext || ''))
    : signManagedCameraToken(row.token_id, Number(row.token_generation));
}

managedAdminPlayerRouter.use(requireAuth);

managedAdminPlayerRouter.get('/:cameraId/live', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  if (!authReq.user) return res.status(401).json({ error: 'Unauthorized' });

  const allowed = await canAccessCamera(authReq.user, req.params.cameraId);
  if (!allowed) return res.status(403).json({ error: 'Forbidden' });

  const access = await loadManagedPlayerAccess(req.params.cameraId);
  if (!access) {
    return res.status(409).json({
      error: 'У камеры нет активного managed-токена с доступом к видео'
    });
  }

  const cameraBase = publicCameraBase(authReq);
  if (!cameraBase) return res.status(500).json({ error: 'Публичный адрес media gateway не определён' });

  const rawToken = rawManagedPlayerToken(access);
  const liveUrl = `${cameraBase}/${encodeURIComponent(access.stream_name)}/live.m3u8?token=${encodeURIComponent(rawToken)}`;

  res.setHeader('cache-control', 'no-store');
  return res.json({
    liveHls: liveUrl,
    hls_url: liveUrl,
    playback_url: liveUrl,
    stream_name: access.stream_name,
    token_mode: 'managed-camera',
    managed_token: managedTokenMetadata(access),
    expiresIn: null
  });
}));

managedAdminPlayerRouter.get('/:cameraId/archive', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  if (!authReq.user) return res.status(401).json({ error: 'Unauthorized' });

  const params = archiveSchema.parse(req.query);
  const allowed = await canAccessCamera(authReq.user, req.params.cameraId);
  if (!allowed) return res.status(403).json({ error: 'Forbidden' });

  const access = await loadManagedPlayerAccess(req.params.cameraId);
  if (!access) {
    return res.status(409).json({
      error: 'У камеры нет активного managed-токена с доступом к видео'
    });
  }

  const cameraBase = publicCameraBase(authReq);
  if (!cameraBase) return res.status(500).json({ error: 'Публичный адрес media gateway не определён' });

  const rawToken = rawManagedPlayerToken(access);
  const queryString = new URLSearchParams({
    start: params.start,
    end: params.end,
    token: rawToken
  });
  const archiveUrl = `${cameraBase}/${encodeURIComponent(access.stream_name)}/archive.m3u8?${queryString.toString()}`;

  res.setHeader('cache-control', 'no-store');
  return res.json({
    archiveHls: archiveUrl,
    hls_url: archiveUrl,
    playback_url: archiveUrl,
    stream_name: access.stream_name,
    source: 'node',
    requested_source: params.source || 'node',
    archive_storage: 'node',
    available_sources: ['node'],
    token_mode: 'managed-camera',
    managed_token: managedTokenMetadata(access),
    expiresIn: null
  });
}));

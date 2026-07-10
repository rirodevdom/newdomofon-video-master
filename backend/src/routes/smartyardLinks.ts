import crypto from 'node:crypto';
import { Router } from 'express';
import { query } from '../db.js';
import { requireAuth, requireRole } from '../middleware/auth.js';
import { asyncHandler } from '../utils/asyncHandler.js';
import type { AuthRequest } from '../types.js';

export const smartYardLinksRouter = Router();

smartYardLinksRouter.use(requireAuth, requireRole('super_admin'));

function publicOrigin(req: AuthRequest) {
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

function cameraToken(secret: string, payload: Record<string, unknown>) {
  const encoded = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const signature = crypto.createHmac('sha256', secret).update(encoded).digest('base64url');
  return `${encoded}.${signature}`;
}

smartYardLinksRouter.post('/:cameraId', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  if (!authReq.user) return res.status(401).json({ error: 'Unauthorized' });

  const result = await query<{
    id: string;
    name: string;
    stream_name: string;
    node_name: string | null;
    node_media_secret: string | null;
    node_enabled: boolean | null;
  }>(
    `SELECT c.id, c.name, c.stream_name,
            ds.name AS node_name,
            ds.media_secret AS node_media_secret,
            ds.is_enabled AS node_enabled
       FROM cameras c
       LEFT JOIN dvr_servers ds ON ds.id = c.dvr_server_id
      WHERE c.id = $1
        AND c.is_enabled = true
      LIMIT 1`,
    [req.params.cameraId]
  );
  const camera = result.rows[0];
  if (!camera) return res.status(404).json({ error: 'Camera not found' });
  if (!camera.node_media_secret || camera.node_enabled === false) {
    return res.status(409).json({ error: 'Camera node media secret is not configured' });
  }

  const origin = publicOrigin(authReq);
  if (!origin) return res.status(500).json({ error: 'Public SmartYard base URL cannot be determined' });

  const token = cameraToken(camera.node_media_secret, {
    camera_id: camera.id,
    stream_name: camera.stream_name,
    user_id: authReq.user.id,
    scope: 'camera',
    link_version: String(process.env.PERMANENT_MEDIA_LINK_VERSION || '1')
  });
  const url = `${origin}/${encodeURIComponent(camera.stream_name)}/?token=${encodeURIComponent(token)}`;

  res.json({
    camera: { id: camera.id, name: camera.name, stream_name: camera.stream_name },
    node_name: camera.node_name,
    smartyard_url: url,
    common_url: url,
    camera_url: url,
    camera_token: token,
    permanent: true,
    expires_at: null,
    mode: 'master-smartyard-compat'
  });
}));

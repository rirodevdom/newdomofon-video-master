import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { query } from '../db.js';
import { asyncHandler } from '../utils/asyncHandler.js';

export const internalSmartYardRouter = Router();

const resolveSchema = z.object({
  token: z.string().min(16),
  stream_name: z.string().min(1).max(255).optional()
});

const cameraIdSchema = z.string().uuid();
const streamNameSchema = z.string().regex(/^[A-Za-z0-9_-]+$/).max(255);

type CameraNodeRow = {
  camera_id: string;
  camera_name: string;
  stream_name: string;
  camera_enabled: boolean;
  node_id: string;
  node_name: string;
  node_enabled: boolean;
  node_internal_url: string | null;
  node_base_url: string | null;
  node_public_url: string | null;
  node_media_secret: string;
};

function requireInternal(req: any, res: any, next: any) {
  const expected = String(process.env.INTERNAL_DVR_SECRET || '').trim();
  const actual = String(req.header('x-internal-secret') || '').trim();

  if (!expected) return res.status(500).json({ error: 'INTERNAL_DVR_SECRET is not configured' });
  if (!actual || !safeEqual(actual, expected)) return res.status(403).json({ error: 'Forbidden' });

  return next();
}

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && crypto.timingSafeEqual(ab, bb);
}

function parseToken(rawToken: string): { body: string; signature: string; payload: Record<string, unknown> } | null {
  const parts = rawToken.split('.');
  if (parts.length !== 2 || !parts[0] || !parts[1]) return null;

  try {
    const payload = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null;
    return { body: parts[0], signature: parts[1], payload };
  } catch {
    return null;
  }
}

function verifySignature(body: string, signature: string, secret: string): boolean {
  if (!secret) return false;
  const expected = crypto.createHmac('sha256', secret).update(body).digest('base64url');
  return safeEqual(signature, expected);
}

function legacySecrets(): string[] {
  return [
    process.env.SMARTYARD_LEGACY_MEDIA_SECRET,
    process.env.DVR_NODE_MEDIA_SECRET,
    process.env.NODE_MEDIA_SECRET,
    process.env.MEDIA_TOKEN_SECRET
  ]
    .map((value) => String(value || '').trim())
    .filter((value, index, all) => Boolean(value) && all.indexOf(value) === index);
}

function signUpstreamToken(secret: string, payload: Record<string, unknown>): string {
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const signature = crypto.createHmac('sha256', secret).update(body).digest('base64url');
  return `${body}.${signature}`;
}

internalSmartYardRouter.use(requireInternal);

internalSmartYardRouter.post('/resolve', asyncHandler(async (req, res) => {
  const body = resolveSchema.parse(req.body || {});
  const parsed = parseToken(body.token);
  if (!parsed) return res.status(401).json({ error: 'Invalid playback token' });

  const cameraIdResult = cameraIdSchema.safeParse(String(parsed.payload.camera_id || '').trim());
  const payloadStreamResult = streamNameSchema.safeParse(String(parsed.payload.stream_name || '').trim());
  const payloadScope = String(parsed.payload.scope || '').trim();

  if (!cameraIdResult.success || !payloadStreamResult.success || !['camera', 'live', 'archive'].includes(payloadScope)) {
    return res.status(401).json({ error: 'Invalid playback token payload' });
  }

  const cameraId = cameraIdResult.data;
  const payloadStream = payloadStreamResult.data;

  if (body.stream_name && body.stream_name !== payloadStream) {
    return res.status(403).json({ error: 'Token stream mismatch' });
  }

  const exp = Number(parsed.payload.exp);
  if (Number.isFinite(exp) && exp < Math.floor(Date.now() / 1000)) {
    return res.status(401).json({ error: 'Playback token expired' });
  }

  const result = await query<CameraNodeRow>(
    `SELECT c.id AS camera_id,
            c.name AS camera_name,
            c.stream_name,
            c.is_enabled AS camera_enabled,
            ds.id AS node_id,
            ds.name AS node_name,
            ds.is_enabled AS node_enabled,
            ds.internal_url AS node_internal_url,
            ds.base_url AS node_base_url,
            ds.public_base_url AS node_public_url,
            ds.media_secret AS node_media_secret
       FROM cameras c
       JOIN dvr_servers ds ON ds.id = c.dvr_server_id
      WHERE c.id = $1
        AND c.stream_name = $2
      LIMIT 1`,
    [cameraId, payloadStream]
  );

  const camera = result.rows[0];
  if (!camera || !camera.camera_enabled || !camera.node_enabled || !camera.node_media_secret) {
    return res.status(404).json({ error: 'Camera or assigned node is unavailable' });
  }

  let tokenSource: 'node' | 'legacy' | null = null;
  if (verifySignature(parsed.body, parsed.signature, camera.node_media_secret)) {
    tokenSource = 'node';
  } else if (legacySecrets().some((secret) => verifySignature(parsed.body, parsed.signature, secret))) {
    tokenSource = 'legacy';
  }

  if (!tokenSource) return res.status(401).json({ error: 'Invalid playback token signature' });

  const nodeUrl = String(
    camera.node_internal_url || camera.node_base_url || camera.node_public_url || ''
  ).replace(/\/+$/, '');

  if (!nodeUrl) return res.status(409).json({ error: 'Assigned node URL is not configured' });

  const ttlRaw = Number(process.env.SMARTYARD_UPSTREAM_TOKEN_TTL_SECONDS || 300);
  const ttlSeconds = Number.isFinite(ttlRaw) ? Math.max(30, Math.min(900, Math.floor(ttlRaw))) : 300;
  const now = Math.floor(Date.now() / 1000);

  const upstreamToken = signUpstreamToken(camera.node_media_secret, {
    camera_id: camera.camera_id,
    stream_name: camera.stream_name,
    user_id: String(parsed.payload.user_id || 'smartyard-compat'),
    scope: 'camera',
    iat: now,
    exp: now + ttlSeconds
  });

  res.setHeader('cache-control', 'no-store');
  res.json({
    ok: true,
    camera: {
      id: camera.camera_id,
      name: camera.camera_name,
      stream_name: camera.stream_name
    },
    node: {
      id: camera.node_id,
      name: camera.node_name,
      url: nodeUrl
    },
    upstream_token: upstreamToken,
    expires_in: ttlSeconds,
    token_source: tokenSource
  });
}));

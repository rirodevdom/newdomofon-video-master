import crypto from 'node:crypto';
import { Router } from 'express';
import { query } from '../db.js';
import { verifyManagedCameraToken } from '../services/managedCameraToken.js';
import { signEphemeralNodeMediaToken } from '../services/nodeMediaToken.js';
import { asyncHandler } from '../utils/asyncHandler.js';

export const internalRtspRouter = Router();

type MediaMtxAuthBody = {
  user?: unknown;
  password?: unknown;
  token?: unknown;
  ip?: unknown;
  action?: unknown;
  path?: unknown;
  protocol?: unknown;
  query?: unknown;
};

type ManagedRtspRow = {
  managed_token_id: string;
  managed_token_generation: number;
  managed_token_scopes: string[];
  managed_token_active: boolean;
  managed_token_expires_at: string | null;
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

type RtspSourceRow = {
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

function safeEqual(left: string, right: string): boolean {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function isLoopback(value: string | undefined): boolean {
  const address = String(value || '').toLowerCase();
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1';
}

function gatewaySecret(): string {
  return String(process.env.RTSP_GATEWAY_SHARED_SECRET || '').trim();
}

function relayPublishSecret(): string {
  return String(process.env.RTSP_RELAY_PUBLISH_SECRET || '').trim();
}

function cleanPath(value: unknown): string | null {
  const path = String(value || '').trim().replace(/^\/+/, '').split('?')[0];
  return /^[A-Za-z0-9_.-]{1,255}$/.test(path) ? path : null;
}

function tokenFromQuery(value: unknown): string {
  try {
    return new URLSearchParams(String(value || '').replace(/^\?/, '')).get('token') || '';
  } catch {
    return '';
  }
}

function nodeUrl(row: RtspSourceRow): string {
  return String(row.node_internal_url || row.node_base_url || row.node_public_url || '').replace(/\/+$/, '');
}

function requireGateway(req: any, res: any, next: any) {
  const expected = gatewaySecret();
  const supplied = String(req.query.gateway_secret || '').trim();

  if (!expected) return res.status(503).json({ error: 'RTSP_GATEWAY_SHARED_SECRET is not configured' });
  if (!isLoopback(req.socket?.remoteAddress)) return res.status(403).json({ error: 'RTSP gateway endpoint is local-only' });
  if (!supplied || !safeEqual(supplied, expected)) return res.status(403).json({ error: 'Invalid RTSP gateway secret' });
  return next();
}

async function loadManagedRtspAccess(rawToken: string, streamName: string): Promise<ManagedRtspRow | null> {
  const payload = verifyManagedCameraToken(rawToken);
  if (!payload) return null;

  const result = await query<ManagedRtspRow>(
    `SELECT t.id AS managed_token_id,
            t.generation AS managed_token_generation,
            t.scopes AS managed_token_scopes,
            t.is_active AS managed_token_active,
            t.expires_at AS managed_token_expires_at,
            c.id AS camera_id,
            c.name AS camera_name,
            c.stream_name,
            c.is_enabled AS camera_enabled,
            node.id AS node_id,
            node.name AS node_name,
            node.is_enabled AS node_enabled,
            node.internal_url AS node_internal_url,
            node.base_url AS node_base_url,
            node.public_base_url AS node_public_url,
            node.media_secret AS node_media_secret
       FROM managed_camera_tokens t
       JOIN managed_camera_token_cameras assignment ON assignment.token_id = t.id
       JOIN cameras c ON c.id = assignment.camera_id
       JOIN devices device ON device.id = c.device_id
       JOIN dvr_servers node ON node.id = device.dvr_server_id
      WHERE t.id = $1
        AND t.generation = $2
        AND c.stream_name = $3
      LIMIT 1`,
    [payload.token_id, payload.generation, streamName]
  );

  const row = result.rows[0];
  if (!row) return null;
  if (!row.managed_token_active || !row.camera_enabled || !row.node_enabled || !row.node_media_secret) return null;
  if (!Array.isArray(row.managed_token_scopes) || !row.managed_token_scopes.includes('camera')) return null;
  if (row.managed_token_expires_at && new Date(row.managed_token_expires_at).getTime() <= Date.now()) return null;
  return row;
}

internalRtspRouter.use(requireGateway);

/** MediaMTX external HTTP authentication endpoint. */
internalRtspRouter.post('/auth', asyncHandler(async (req, res) => {
  const body = (req.body || {}) as MediaMtxAuthBody;
  const action = String(body.action || '').toLowerCase();
  const protocol = String(body.protocol || '').toLowerCase();
  const streamName = cleanPath(body.path);

  if (!streamName || protocol !== 'rtsp') return res.status(403).end();

  if (action === 'publish') {
    const user = String(body.user || '');
    const password = String(body.password || '');
    const expected = relayPublishSecret();
    const publisherIp = String(body.ip || '');

    if (!expected || user !== 'relay' || !password || !safeEqual(password, expected) || !isLoopback(publisherIp)) {
      return res.status(403).end();
    }

    const camera = await query(
      `SELECT 1
         FROM cameras c
         JOIN devices device ON device.id = c.device_id
         JOIN dvr_servers node ON node.id = device.dvr_server_id
        WHERE c.stream_name = $1
          AND c.is_enabled = true
          AND node.is_enabled = true
        LIMIT 1`,
      [streamName]
    );
    return camera.rows[0] ? res.status(204).end() : res.status(403).end();
  }

  if (action !== 'read') return res.status(403).end();

  const user = String(body.user || '');
  const passwordToken = String(body.password || '').trim();
  const bearerToken = String(body.token || '').trim();
  const queryToken = tokenFromQuery(body.query);
  const rawToken = passwordToken || bearerToken || queryToken;

  // MediaMTX intentionally calls auth once without credentials so it can learn
  // that the client must be challenged, then repeats with RTSP credentials.
  if (!rawToken) return res.status(401).end();
  if (passwordToken && user && user !== 'token') return res.status(401).end();

  const access = await loadManagedRtspAccess(rawToken, streamName);
  if (!access) return res.status(401).end();

  await query(
    `UPDATE managed_camera_tokens
        SET last_used_at = now()
      WHERE id = $1
        AND (last_used_at IS NULL OR last_used_at < now() - interval '5 minutes')`,
    [access.managed_token_id]
  ).catch(() => undefined);

  return res.status(204).end();
}));

/** Resolve a protected node MPEG-TS source for a local on-demand relay. */
internalRtspRouter.post('/source', asyncHandler(async (req, res) => {
  const streamName = cleanPath(req.body?.stream_name);
  if (!streamName) return res.status(400).json({ error: 'Invalid stream_name' });

  const result = await query<RtspSourceRow>(
    `SELECT c.id AS camera_id,
            c.name AS camera_name,
            c.stream_name,
            c.is_enabled AS camera_enabled,
            node.id AS node_id,
            node.name AS node_name,
            node.is_enabled AS node_enabled,
            node.internal_url AS node_internal_url,
            node.base_url AS node_base_url,
            node.public_base_url AS node_public_url,
            node.media_secret AS node_media_secret
       FROM cameras c
       JOIN devices device ON device.id = c.device_id
       JOIN dvr_servers node ON node.id = device.dvr_server_id
      WHERE c.stream_name = $1
      LIMIT 1`,
    [streamName]
  );

  const camera = result.rows[0];
  const baseUrl = camera ? nodeUrl(camera) : '';
  if (!camera || !camera.camera_enabled || !camera.node_enabled || !camera.node_media_secret || !baseUrl) {
    return res.status(404).json({ error: 'Camera or assigned node is unavailable' });
  }

  const upstreamToken = signEphemeralNodeMediaToken(camera.node_media_secret, {
    camera_id: camera.camera_id,
    stream_name: camera.stream_name,
    user_id: 'rtsp-relay',
    scope: 'live'
  }, 600);

  const sourceUrl = `${baseUrl}/cameras/${encodeURIComponent(camera.stream_name)}/rtsp-relay.ts?token=${encodeURIComponent(upstreamToken)}`;
  res.setHeader('cache-control', 'no-store');
  return res.json({
    ok: true,
    camera: { id: camera.camera_id, name: camera.camera_name, stream_name: camera.stream_name },
    node: { id: camera.node_id, name: camera.node_name, url: baseUrl },
    source_url: sourceUrl,
    expires_in: 600
  });
}));

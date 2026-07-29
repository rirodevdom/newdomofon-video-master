import { Router } from 'express';
import crypto from 'node:crypto';
import { z } from 'zod';
import { config } from '../config.js';
import { query } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { canAccessCamera } from '../services/cameraAccess.js';
import { signNodeMediaToken, type NodeMediaScope } from '../services/nodeMediaToken.js';
import { asyncHandler } from '../utils/asyncHandler.js';
import type { AuthRequest } from '../types.js';

export const playerPublicArchiveRouter = Router();
export const playerRouter = Router();

async function dvrJson(url: string, timeoutMs = 10_000): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

const archiveSchema = z.object({
  start: z.string().datetime(),
  end: z.string().datetime(),
  source: z.enum(['auto', 'node']).optional()
});

function sha256(raw: string) {
  return crypto.createHash('sha256').update(raw).digest('hex');
}

async function createPlaybackToken(userId: string, cameraId: string): Promise<string> {
  const raw = crypto.randomBytes(32).toString('base64url');
  const expires = new Date(Date.now() + config.playbackTokenTtlSeconds * 1000);
  await query(
    'INSERT INTO playback_tokens(user_id, camera_id, token_hash, expires_at) VALUES ($1,$2,$3,$4)',
    [userId, cameraId, sha256(raw), expires]
  );
  return raw;
}

type CameraWithNode = {
  id: string;
  stream_name: string;
  dvr_server_id: string | null;
  node_public_base_url: string | null;
  node_internal_url: string | null;
  node_media_secret: string | null;
  node_status: string | null;
  node_enabled: boolean | null;
};

async function getCameraWithNode(cameraId: string) {
  const result = await query<CameraWithNode>(
    `SELECT c.id, c.stream_name, c.dvr_server_id,
            COALESCE(ds.public_base_url, ds.base_url) AS node_public_base_url,
            ds.internal_url AS node_internal_url,
            ds.media_secret AS node_media_secret,
            ds.status AS node_status,
            ds.is_enabled AS node_enabled
       FROM cameras c
       LEFT JOIN dvr_servers ds ON ds.id = c.dvr_server_id
      WHERE c.id = $1
      LIMIT 1`,
    [cameraId]
  );
  return result.rows[0] || null;
}

function normalizeNodeBaseUrl(raw: string | null | undefined) {
  const trimmed = String(raw || '').trim().replace(/\/+$/, '');
  if (!trimmed) return null;
  return /^https?:\/\//i.test(trimmed) ? trimmed : `http://${trimmed}`;
}

function nodeMediaUrlWithBase(
  baseUrl: string | null,
  camera: CameraWithNode,
  userId: string,
  scope: NodeMediaScope,
  pathSuffix: string,
  params: Record<string, string> = {}
) {
  const base = normalizeNodeBaseUrl(baseUrl);
  if (!base || !camera.node_media_secret || camera.node_enabled === false) return null;
  const token = signNodeMediaToken(camera.node_media_secret, {
    camera_id: camera.id,
    stream_name: camera.stream_name,
    user_id: userId,
    scope
  });
  const qs = new URLSearchParams({ ...params, token });
  return `${base}/cameras/${encodeURIComponent(camera.stream_name)}/${pathSuffix}?${qs.toString()}`;
}

function nodeMediaUrl(
  camera: CameraWithNode,
  userId: string,
  scope: NodeMediaScope,
  pathSuffix: string,
  params: Record<string, string> = {}
) {
  return nodeMediaUrlWithBase(camera.node_public_base_url, camera, userId, scope, pathSuffix, params);
}

function nodeInternalMediaUrl(
  camera: CameraWithNode,
  userId: string,
  scope: NodeMediaScope,
  pathSuffix: string,
  params: Record<string, string> = {}
) {
  return nodeMediaUrlWithBase(camera.node_internal_url || camera.node_public_base_url, camera, userId, scope, pathSuffix, params);
}

playerRouter.use(requireAuth);

playerRouter.get('/:cameraId/live', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  const allowed = await canAccessCamera(authReq.user!, req.params.cameraId);
  if (!allowed) return res.status(403).json({ error: 'Forbidden' });
  const camera = await getCameraWithNode(req.params.cameraId);
  if (!camera) return res.status(404).json({ error: 'Camera not found' });

  const nodeUrl = nodeMediaUrl(camera, authReq.user!.id, 'live', 'live.m3u8');
  if (nodeUrl) {
    return res.json({
      liveHls: nodeUrl,
      hls_url: nodeUrl,
      playback_url: nodeUrl,
      node_id: camera.dvr_server_id,
      stream_name: camera.stream_name,
      expiresIn: config.playbackTokenTtlSeconds
    });
  }

  const token = await createPlaybackToken(authReq.user!.id, camera.id);
  res.json({
    liveHls: `${config.mediaPublicBaseUrl}/${camera.stream_name}/live.m3u8?token=${token}`,
    webrtcUrl: `/webrtc/live/${camera.stream_name}`,
    expiresIn: config.playbackTokenTtlSeconds
  });
}));

async function archiveResponse(req: any, res: any) {
  const authReq = req as AuthRequest;
  const params = archiveSchema.parse(req.query);
  const allowed = await canAccessCamera(authReq.user!, req.params.cameraId);
  if (!allowed) return res.status(403).json({ error: 'Forbidden' });
  const camera = await getCameraWithNode(req.params.cameraId);
  if (!camera) return res.status(404).json({ error: 'Camera not found' });

  const nodeUrl = nodeMediaUrl(camera, authReq.user!.id, 'archive', 'archive.m3u8', {
    start: params.start,
    end: params.end
  });
  if (nodeUrl) {
    return res.json({
      archiveHls: nodeUrl,
      hls_url: nodeUrl,
      playback_url: nodeUrl,
      node_id: camera.dvr_server_id,
      stream_name: camera.stream_name,
      source: 'node',
      requested_source: params.source || 'node',
      archive_storage: 'node',
      available_sources: ['node'],
      ready: true,
      expiresIn: config.playbackTokenTtlSeconds
    });
  }

  const token = await createPlaybackToken(authReq.user!.id, camera.id);
  const q = new URLSearchParams({ start: params.start, end: params.end, token });
  const fallback = `${config.mediaPublicBaseUrl}/${camera.stream_name}/archive.m3u8?${q.toString()}`;
  return res.json({
    archiveHls: fallback,
    hls_url: fallback,
    playback_url: fallback,
    source: 'node',
    requested_source: params.source || 'node',
    archive_storage: 'node',
    available_sources: ['node'],
    ready: true,
    expiresIn: config.playbackTokenTtlSeconds
  });
}

playerRouter.get('/:cameraId/archive', asyncHandler(archiveResponse));
playerRouter.get('/:cameraId/archive/prepare', asyncHandler(archiveResponse));

playerRouter.get('/:cameraId/archive/ranges', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  const params = archiveSchema.parse(req.query);
  const allowed = await canAccessCamera(authReq.user!, req.params.cameraId);
  if (!allowed) return res.status(403).json({ error: 'Forbidden' });
  const camera = await getCameraWithNode(req.params.cameraId);
  if (!camera) return res.status(404).json({ error: 'Camera not found' });

  const nodeUrl = nodeInternalMediaUrl(camera, authReq.user!.id, 'archive', 'archive/ranges', {
    start: params.start,
    end: params.end
  });
  if (!nodeUrl) {
    return res.json({
      items: [],
      source: 'node',
      requested_source: params.source || 'node',
      archive_storage: 'node',
      available_sources: ['node']
    });
  }

  try {
    const response = await dvrJson(nodeUrl, 60_000);
    if (!response.ok) {
      const text = await response.text().catch(() => '');
      return res.status(response.status).json({ error: text || `Node archive ranges HTTP ${response.status}` });
    }
    const data = await response.json() as { items?: Array<{ start: string; end: string; segments?: number }> };
    res.setHeader('cache-control', 'no-store');
    return res.json({
      items: data.items || [],
      source: 'node',
      requested_source: params.source || 'node',
      archive_storage: 'node',
      available_sources: ['node']
    });
  } catch (error) {
    return res.status(502).json({ error: error instanceof Error ? error.message : String(error) });
  }
}));

playerRouter.get('/:cameraId/export', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  const params = archiveSchema.parse(req.query);
  const allowed = await canAccessCamera(authReq.user!, req.params.cameraId);
  if (!allowed) return res.status(403).json({ error: 'Forbidden' });
  const camera = await getCameraWithNode(req.params.cameraId);
  if (!camera) return res.status(404).json({ error: 'Camera not found' });

  const nodeUrl = nodeMediaUrl(camera, authReq.user!.id, 'export', 'export.mp4', {
    start: params.start,
    end: params.end
  });
  if (nodeUrl) {
    return res.json({
      exportMp4: nodeUrl,
      node_id: camera.dvr_server_id,
      source: 'node',
      expiresIn: config.playbackTokenTtlSeconds
    });
  }

  const token = await createPlaybackToken(authReq.user!.id, camera.id);
  const q = new URLSearchParams({ start: params.start, end: params.end, token });
  res.json({
    exportMp4: `${config.mediaPublicBaseUrl}/${camera.stream_name}/export.mp4?${q.toString()}`,
    source: 'node',
    expiresIn: config.playbackTokenTtlSeconds
  });
}));

playerRouter.get('/:cameraId/status', asyncHandler(async (req, res) => {
  const authReq = req as AuthRequest;
  const allowed = await canAccessCamera(authReq.user!, req.params.cameraId);
  if (!allowed) return res.status(403).json({ error: 'Forbidden' });
  const camera = await getCameraWithNode(req.params.cameraId);
  if (!camera) return res.status(404).json({ error: 'Camera not found' });

  const base = normalizeNodeBaseUrl(camera.node_internal_url || camera.node_public_base_url || config.dvrEngineUrl);
  if (!base) {
    return res.json({
      recording: false,
      stream_name: camera.stream_name,
      node_id: camera.dvr_server_id,
      archive_storage: 'node',
      available_archive_sources: ['node'],
      default_archive_source: 'node',
      error: 'Node URL is not configured'
    });
  }

  try {
    const response = await dvrJson(`${base}/cameras/${encodeURIComponent(camera.stream_name)}/status`);
    const text = await response.text();
    let payload: any;
    try { payload = text ? JSON.parse(text) : {}; } catch { payload = { error: text || `HTTP ${response.status}` }; }
    if (!response.ok) {
      return res.json({
        recording: false,
        stream_name: camera.stream_name,
        node_id: camera.dvr_server_id,
        archive_storage: 'node',
        available_archive_sources: ['node'],
        default_archive_source: 'node',
        error: payload.error || `DVR status HTTP ${response.status}`
      });
    }
    res.json({
      ...payload,
      archive_storage: 'node',
      available_archive_sources: ['node'],
      default_archive_source: 'node'
    });
  } catch (error) {
    res.json({
      recording: false,
      stream_name: camera.stream_name,
      node_id: camera.dvr_server_id,
      archive_storage: 'node',
      available_archive_sources: ['node'],
      default_archive_source: 'node',
      error: error instanceof Error ? error.message : String(error)
    });
  }
}));

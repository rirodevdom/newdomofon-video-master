import crypto from 'node:crypto';
import { Router, type Request, type Response, type NextFunction } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query } from '../db.js';
import { asyncHandler } from '../utils/asyncHandler.js';

export const nodeAgentRouter = Router();

type NodeKind = 'video' | 'hikvision';

interface NodeAgentRequest extends Request {
  node?: {
    id: string;
    name: string;
    media_secret: string;
    config_generation: string;
    node_kind: NodeKind;
  };
}

function createSecret(bytes = 32): string {
  return crypto.randomBytes(bytes).toString('base64url');
}

function sha256(raw: string): string {
  return crypto.createHash('sha256').update(raw).digest('hex');
}

function tokenFromRequest(req: Request): string {
  const bearer = String(req.get('authorization') || '');
  if (bearer.startsWith('Bearer ')) return bearer.slice(7).trim();
  return String(req.get('x-node-token') || req.body?.agent_token || req.query.token || '').trim();
}

function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && crypto.timingSafeEqual(ab, bb);
}

async function requireNode(req: NodeAgentRequest, res: Response, next: NextFunction) {
  const nodeId = String(req.get('x-node-id') || req.body?.node_id || req.query.node_id || '').trim();
  const token = tokenFromRequest(req);
  if (!nodeId || !token) return res.status(401).json({ error: 'Missing node credentials' });

  const result = await query<{
    id: string;
    name: string;
    agent_token_hash: string;
    media_secret: string;
    config_generation: string;
    is_enabled: boolean;
    node_kind: NodeKind;
  }>(
    `SELECT id, name, agent_token_hash, media_secret, config_generation::text, is_enabled,
            CASE WHEN capabilities->>'node_kind' = 'hikvision' THEN 'hikvision' ELSE 'video' END AS node_kind
       FROM dvr_servers
      WHERE id = $1
      LIMIT 1`,
    [nodeId]
  );

  const node = result.rows[0];
  if (!node || !node.is_enabled || !node.agent_token_hash || !safeEqual(node.agent_token_hash, sha256(token))) {
    return res.status(401).json({ error: 'Invalid node credentials' });
  }

  req.node = {
    id: node.id,
    name: node.name,
    media_secret: node.media_secret,
    config_generation: node.config_generation,
    node_kind: node.node_kind
  };
  return next();
}

const registerSchema = z.object({
  registration_token: z.string().optional(),
  name: z.string().min(1),
  public_base_url: z.string().min(1).optional(),
  base_url: z.string().min(1).optional(),
  internal_url: z.string().optional().nullable(),
  version: z.string().optional(),
  capabilities: z.record(z.any()).optional()
});

nodeAgentRouter.post('/register', asyncHandler(async (req, res) => {
  const body = registerSchema.parse(req.body || {});
  const registrationToken = body.registration_token || String(req.get('x-node-registration-token') || '');
  if (!config.nodeRegistrationToken) return res.status(403).json({ error: 'NODE_REGISTRATION_TOKEN is not configured on master' });
  if (!registrationToken || !safeEqual(sha256(registrationToken), sha256(config.nodeRegistrationToken))) {
    return res.status(403).json({ error: 'Invalid node registration token' });
  }

  const agentToken = createSecret();
  const mediaSecret = createSecret();
  const publicBaseUrl = body.public_base_url || body.base_url || '';
  const result = await query<{ id: string }>(
    `INSERT INTO dvr_servers(
       name, base_url, public_base_url, internal_url, status,
       agent_token_hash, media_secret, version, capabilities, last_seen_at
     ) VALUES ($1,$2,$3,$4,'online',$5,$6,$7,$8,now()) RETURNING id`,
    [body.name, publicBaseUrl, publicBaseUrl, body.internal_url ?? null, sha256(agentToken), mediaSecret, body.version ?? null, JSON.stringify(body.capabilities || {})]
  );
  res.status(201).json({ node_id: result.rows[0].id, agent_token: agentToken, media_secret: mediaSecret, public_base_url: publicBaseUrl });
}));

nodeAgentRouter.post('/heartbeat', requireNode, asyncHandler(async (req: NodeAgentRequest, res) => {
  const body = req.body || {};
  const claimedKind = String(body.capabilities?.node_kind || req.node!.node_kind);
  if (claimedKind !== req.node!.node_kind) {
    return res.status(409).json({ error: `Node type mismatch: master=${req.node!.node_kind}, agent=${claimedKind}` });
  }

  await query(
    `UPDATE dvr_servers
        SET status = 'online', last_seen_at = now(),
            public_base_url = COALESCE($2, public_base_url), base_url = COALESCE($2, base_url),
            internal_url = COALESCE($3, internal_url), version = COALESCE($4, version),
            capabilities = COALESCE(capabilities, '{}'::jsonb) || COALESCE($5::jsonb, '{}'::jsonb),
            storage = COALESCE($6::jsonb, storage)
      WHERE id = $1`,
    [req.node!.id, body.public_base_url || body.base_url || null, body.internal_url || null, body.version || null,
      body.capabilities ? JSON.stringify(body.capabilities) : null, body.storage ? JSON.stringify(body.storage) : null]
  );
  res.json({ ok: true, node_id: req.node!.id, node_kind: req.node!.node_kind, config_generation: req.node!.config_generation });
}));

nodeAgentRouter.get('/config', requireNode, asyncHandler(async (req: NodeAgentRequest, res) => {
  if (req.node!.node_kind === 'hikvision') {
    const devices = await query(
      `SELECT d.id::text AS id, d.name, d.host,
              COALESCE(d.isapi_scheme, 'http') AS scheme,
              COALESCE(d.port, 80) AS isapi_port,
              COALESCE(d.rtsp_port, 554) AS rtsp_port,
              COALESCE(d.username, '') AS username,
              COALESCE(d.password, '') AS password,
              d.archive_storage,
              COALESCE(d.retention_days, 30) AS retention_days,
              d.is_enabled AS enabled,
              COALESCE(d.reject_unauthorized_tls, true) AS reject_unauthorized_tls,
              COALESCE(d.hikvision_channel_overrides, '{}'::jsonb) AS channel_overrides
         FROM devices d
        WHERE d.dvr_server_id = $1
          AND d.connection_type = 'HIKVISION'
        ORDER BY d.name ASC`,
      [req.node!.id]
    );
    return res.json({
      node_id: req.node!.id,
      node_name: req.node!.name,
      node_kind: 'hikvision',
      media_secret: req.node!.media_secret,
      config_generation: req.node!.config_generation,
      devices: devices.rows,
      cameras: []
    });
  }

  const cameras = await query(
    `SELECT c.id, c.name, c.stream_name, c.source_url,
            c.rtmp_push_url, c.retention_days, c.is_enabled,
            c.device_id, device.connection_type AS device_connection_type,
            device.host AS device_host, device.port AS device_port,
            device.username AS device_username, device.password AS device_password,
            device.rtsp_url AS device_rtsp_url,
            c.onvif_xaddr, c.onvif_port, c.onvif_username, c.onvif_password, c.onvif_profile_token
       FROM cameras c
       JOIN devices device ON device.id = c.device_id
      WHERE device.dvr_server_id = $1
        AND device.connection_type IN ('RTSP', 'ONVIF')
        AND device.is_enabled = true AND c.is_enabled = true
      ORDER BY c.stream_name ASC`,
    [req.node!.id]
  );
  return res.json({ node_id: req.node!.id, node_name: req.node!.name, node_kind: 'video', media_secret: req.node!.media_secret,
    config_generation: req.node!.config_generation, cameras: cameras.rows, devices: [] });
}));

const hikvisionSyncSchema = z.object({
  devices: z.array(z.object({
    config: z.object({ id: z.string().uuid() }).passthrough(),
    device_info: z.record(z.any()).default({}),
    capabilities: z.record(z.any()).default({}),
    channels: z.array(z.object({
      id: z.string().min(1),
      physical_channel: z.number().int().positive(),
      name: z.string(),
      online: z.boolean().nullable(),
      enabled: z.boolean(),
      primary_stream_id: z.string(),
      archive_storage: z.enum(['node', 'device']),
      retention_days: z.number().int().positive(),
      streams: z.array(z.record(z.any())),
      discovered_at: z.string()
    }).passthrough()),
    last_sync_at: z.string().nullable(),
    last_sync_error: z.string().nullable()
  }).passthrough())
});

nodeAgentRouter.post('/hikvision/sync', requireNode, asyncHandler(async (req: NodeAgentRequest, res) => {
  if (req.node!.node_kind !== 'hikvision') return res.status(409).json({ error: 'This endpoint is only for Hikvision nodes' });
  const body = hikvisionSyncSchema.parse(req.body || {});
  let channelsWritten = 0;

  for (const snapshot of body.devices) {
    const assigned = await query<{ id: string }>(
      `SELECT id FROM devices WHERE id = $1 AND dvr_server_id = $2 AND connection_type = 'HIKVISION'`,
      [snapshot.config.id, req.node!.id]
    );
    if (!assigned.rowCount) continue;

    const channelIds: string[] = [];
    for (const channel of snapshot.channels) {
      channelIds.push(channel.id);
      await query(
        `INSERT INTO hikvision_node_channels(
           device_id, dvr_server_id, channel_external_id, physical_channel, name, online, enabled,
           primary_stream_id, archive_storage, retention_days, streams, device_info, capabilities, discovered_at, updated_at
         ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,now())
         ON CONFLICT (device_id, channel_external_id) DO UPDATE SET
           dvr_server_id = EXCLUDED.dvr_server_id, physical_channel = EXCLUDED.physical_channel,
           name = EXCLUDED.name, online = EXCLUDED.online, enabled = EXCLUDED.enabled,
           primary_stream_id = EXCLUDED.primary_stream_id, archive_storage = EXCLUDED.archive_storage,
           retention_days = EXCLUDED.retention_days, streams = EXCLUDED.streams,
           device_info = EXCLUDED.device_info, capabilities = EXCLUDED.capabilities,
           discovered_at = EXCLUDED.discovered_at, updated_at = now()`,
        [snapshot.config.id, req.node!.id, channel.id, channel.physical_channel, channel.name, channel.online, channel.enabled,
          channel.primary_stream_id, channel.archive_storage, channel.retention_days, JSON.stringify(channel.streams),
          JSON.stringify(snapshot.device_info), JSON.stringify(snapshot.capabilities), channel.discovered_at]
      );
      channelsWritten += 1;
    }

    await query(
      `DELETE FROM hikvision_node_channels
        WHERE device_id = $1
          AND NOT (channel_external_id = ANY($2::text[]))`,
      [snapshot.config.id, channelIds]
    );
    await query(
      `UPDATE devices SET status = $2, last_check_at = now() WHERE id = $1`,
      [snapshot.config.id, snapshot.last_sync_error ? 'error' : 'online']
    );
  }

  res.json({ ok: true, devices_received: body.devices.length, channels_written: channelsWritten });
}));

nodeAgentRouter.get('/commands', requireNode, asyncHandler(async (req: NodeAgentRequest, res) => {
  const limit = Math.min(Math.max(Number(req.query.limit || config.nodeCommandPollLimit), 1), 100);
  const result = await query(
    `UPDATE node_commands SET status = 'picked', picked_at = now()
      WHERE id IN (
        SELECT id FROM node_commands
         WHERE dvr_server_id = $1 AND status = 'pending'
         ORDER BY created_at ASC LIMIT $2 FOR UPDATE SKIP LOCKED
      ) RETURNING id, type, payload, created_at, picked_at`,
    [req.node!.id, limit]
  );
  res.json({ items: result.rows });
}));

nodeAgentRouter.post('/commands/:id/result', requireNode, asyncHandler(async (req: NodeAgentRequest, res) => {
  const status = req.body?.status === 'failed' ? 'failed' : 'done';
  const result = req.body?.result || {};
  const updated = await query(
    `UPDATE node_commands SET status = $3, result = $4, finished_at = now()
      WHERE id = $1 AND dvr_server_id = $2 RETURNING id`,
    [req.params.id, req.node!.id, status, JSON.stringify(result)]
  );
  if (!updated.rowCount) return res.status(404).json({ error: 'Command not found' });
  res.json({ ok: true });
}));

import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { asyncHandler } from '../utils/asyncHandler.js';
import type { AuthRequest } from '../types.js';

export const hikvisionPlayerRouter = Router();
hikvisionPlayerRouter.use(requireAuth);

const rangeSchema = z.object({
  start: z.string().datetime(),
  end: z.string().datetime()
});

type HikvisionChannelRow = {
  channel_external_id: string;
  device_id: string;
  dvr_server_id: string;
  physical_channel: number;
  name: string;
  online: boolean | null;
  enabled: boolean;
  primary_stream_id: string;
  archive_storage: 'node' | 'device';
  retention_days: number;
  streams: unknown[];
  discovered_at: string;
  device_name: string;
  device_enabled: boolean;
  node_name: string;
  node_public_base_url: string | null;
  node_internal_url: string | null;
  node_media_secret: string;
  node_status: string;
  node_enabled: boolean;
};

function normalizeNodeBaseUrl(raw: string | null | undefined): string | null {
  const value = String(raw || '').trim().replace(/\/+$/, '');
  if (!value) return null;
  return /^https?:\/\//i.test(value) ? value : `http://${value}`;
}

function signMediaToken(secret: string, channelId: string, scopes: Array<'live' | 'archive' | 'snapshot'>): string {
  const now = Math.floor(Date.now() / 1000);
  const ttl = Math.max(30, Math.min(config.playbackTokenTtlSeconds, 3600));
  const body = Buffer.from(JSON.stringify({ channel_id: channelId, scopes, iat: now, exp: now + ttl })).toString('base64url');
  const signature = crypto.createHmac('sha256', secret).update(body).digest('base64url');
  return `${body}.${signature}`;
}

async function loadChannel(channelId: string): Promise<HikvisionChannelRow | null> {
  const result = await query<HikvisionChannelRow>(
    `SELECT h.channel_external_id, h.device_id, h.dvr_server_id, h.physical_channel,
            h.name, h.online, h.enabled, h.primary_stream_id, h.archive_storage,
            h.retention_days, h.streams, h.discovered_at,
            d.name AS device_name, d.is_enabled AS device_enabled,
            n.name AS node_name,
            COALESCE(n.public_base_url, n.base_url) AS node_public_base_url,
            COALESCE(n.internal_url, n.public_base_url, n.base_url) AS node_internal_url,
            n.media_secret AS node_media_secret, n.status AS node_status,
            n.is_enabled AS node_enabled
       FROM hikvision_node_channels h
       JOIN devices d ON d.id = h.device_id
       JOIN dvr_servers n ON n.id = h.dvr_server_id
      WHERE h.channel_external_id = $1
      LIMIT 1`,
    [channelId]
  );
  return result.rows[0] || null;
}

function requirePlayable(channel: HikvisionChannelRow): void {
  if (!channel.device_enabled) throw Object.assign(new Error('Hikvision device is disabled'), { statusCode: 409 });
  if (!channel.node_enabled) throw Object.assign(new Error('Hikvision node is disabled'), { statusCode: 409 });
  if (!channel.enabled) throw Object.assign(new Error('Hikvision channel is disabled'), { statusCode: 409 });
  if (!channel.node_media_secret) throw Object.assign(new Error('Hikvision node media secret is not configured'), { statusCode: 409 });
}

function directMediaUrl(
  channel: HikvisionChannelRow,
  scope: 'live' | 'archive' | 'snapshot',
  suffix: string,
  params: Record<string, string> = {}
): string {
  requirePlayable(channel);
  const base = normalizeNodeBaseUrl(channel.node_public_base_url);
  if (!base) throw Object.assign(new Error('Hikvision node public URL is not configured'), { statusCode: 409 });
  const token = signMediaToken(channel.node_media_secret, channel.channel_external_id, [scope]);
  const queryString = new URLSearchParams({ ...params, token });
  return `${base}/api/v1/media/channels/${encodeURIComponent(channel.channel_external_id)}/${suffix}?${queryString.toString()}`;
}

async function nodeJson(
  channel: HikvisionChannelRow,
  scope: 'live' | 'archive' | 'snapshot',
  suffix: string,
  init: RequestInit = {},
  params: Record<string, string> = {},
  timeoutMs = 60_000
): Promise<any> {
  requirePlayable(channel);
  const base = normalizeNodeBaseUrl(channel.node_internal_url || channel.node_public_base_url);
  if (!base) throw Object.assign(new Error('Hikvision node internal URL is not configured'), { statusCode: 409 });
  const token = signMediaToken(channel.node_media_secret, channel.channel_external_id, [scope]);
  const queryString = new URLSearchParams({ ...params, token });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(
      `${base}/api/v1/media/channels/${encodeURIComponent(channel.channel_external_id)}/${suffix}?${queryString.toString()}`,
      {
        ...init,
        signal: controller.signal,
        headers: { accept: 'application/json', 'content-type': 'application/json', ...(init.headers || {}) }
      }
    );
    const text = await response.text();
    let payload: any = {};
    try { payload = text ? JSON.parse(text) : {}; } catch { payload = { error: text }; }
    if (!response.ok) {
      throw Object.assign(new Error(payload.error || `Hikvision node HTTP ${response.status}`), { statusCode: response.status });
    }
    return payload;
  } finally {
    clearTimeout(timer);
  }
}

function absoluteNodeUrl(channel: HikvisionChannelRow, relative: string): string {
  const base = normalizeNodeBaseUrl(channel.node_public_base_url);
  if (!base) throw Object.assign(new Error('Hikvision node public URL is not configured'), { statusCode: 409 });
  if (/^https?:\/\//i.test(relative)) return relative;
  return `${base}${relative.startsWith('/') ? '' : '/'}${relative}`;
}

hikvisionPlayerRouter.get('/:channelId', asyncHandler(async (req, res) => {
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  const authReq = req as AuthRequest;
  res.json({
    item: {
      id: channel.channel_external_id,
      name: channel.name || `${channel.device_name} · ${channel.physical_channel}`,
      stream_name: channel.primary_stream_id,
      device_id: channel.device_id,
      device_name: channel.device_name,
      device_connection_type: 'HIKVISION',
      dvr_server_id: channel.dvr_server_id,
      dvr_server_name: channel.node_name,
      retention_days: channel.retention_days,
      archive_storage: channel.archive_storage,
      online: channel.online,
      enabled: channel.enabled,
      physical_channel: channel.physical_channel,
      streams: channel.streams,
      discovered_at: channel.discovered_at,
      viewer_user_id: authReq.user!.id
    }
  });
}));

hikvisionPlayerRouter.get('/:channelId/live', asyncHandler(async (req, res) => {
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  const url = directMediaUrl(channel, 'live', 'live/index.m3u8');
  res.json({ liveHls: url, hls_url: url, playback_url: url, source: 'hikvision-node', expiresIn: config.playbackTokenTtlSeconds });
}));

hikvisionPlayerRouter.get('/:channelId/archive/ranges', asyncHandler(async (req, res) => {
  const params = rangeSchema.parse(req.query);
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  const payload = await nodeJson(channel, 'archive', 'archive/ranges', {}, { start: params.start, end: params.end });
  res.setHeader('cache-control', 'no-store');
  res.json({
    items: payload.ranges || payload.items || [],
    source: payload.source || channel.archive_storage,
    requested_source: channel.archive_storage,
    archive_storage: channel.archive_storage,
    available_sources: [channel.archive_storage]
  });
}));

async function archiveResponse(req: any, res: any) {
  const params = rangeSchema.parse(req.query);
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  const session = await nodeJson(
    channel,
    'archive',
    'archive/session',
    { method: 'POST', body: JSON.stringify({ start: params.start, end: params.end }) },
    {},
    90_000
  );
  const url = absoluteNodeUrl(channel, session.playlist_url);
  return res.json({
    archiveHls: url,
    hls_url: url,
    playback_url: url,
    source: session.source || channel.archive_storage,
    requested_source: channel.archive_storage,
    archive_storage: channel.archive_storage,
    available_sources: [channel.archive_storage],
    ready: true,
    expiresIn: config.playbackTokenTtlSeconds
  });
}

hikvisionPlayerRouter.get('/:channelId/archive', asyncHandler(archiveResponse));
hikvisionPlayerRouter.get('/:channelId/archive/prepare', asyncHandler(archiveResponse));

hikvisionPlayerRouter.get('/:channelId/export', asyncHandler(async (req, res) => {
  const params = rangeSchema.parse(req.query);
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  const url = directMediaUrl(channel, 'archive', 'archive/export.mp4', { start: params.start, end: params.end });
  res.json({ exportMp4: url, source: channel.archive_storage, expiresIn: config.playbackTokenTtlSeconds });
}));

hikvisionPlayerRouter.get('/:channelId/snapshot', asyncHandler(async (req, res) => {
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  const url = directMediaUrl(channel, 'snapshot', 'snapshot.jpg');
  res.json({ snapshotUrl: url, expiresIn: config.playbackTokenTtlSeconds });
}));

hikvisionPlayerRouter.get('/:channelId/status', asyncHandler(async (req, res) => {
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  res.json({
    recording: channel.online === true && channel.enabled && channel.device_enabled && channel.node_enabled,
    online: channel.online,
    stream_name: channel.primary_stream_id,
    channel_id: channel.channel_external_id,
    node_id: channel.dvr_server_id,
    node_status: channel.node_status,
    archive_storage: channel.archive_storage,
    available_archive_sources: [channel.archive_storage],
    default_archive_source: channel.archive_storage
  });
}));

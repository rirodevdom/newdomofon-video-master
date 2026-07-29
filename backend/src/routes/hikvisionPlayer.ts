import crypto from 'node:crypto';
import { Readable } from 'node:stream';
import { Router, type Request, type Response as ExpressResponse } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { asyncHandler } from '../utils/asyncHandler.js';
import type { AuthRequest } from '../types.js';

export const hikvisionPlayerRouter = Router();
export const hikvisionMediaProxyRouter = Router();

const rangeSchema = z.object({
  start: z.string().datetime(),
  end: z.string().datetime()
});

const ARCHIVE_RANGE_CHUNK_MS = 24 * 60 * 60 * 1000;
const ARCHIVE_RANGE_MERGE_GAP_MS = 2000;

type MediaScope = 'live' | 'archive' | 'snapshot';

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
  node_agent_token_hash: string;
  node_status: string;
  node_enabled: boolean;
};

type MediaTokenPayload = {
  channel_id: string;
  scopes: MediaScope[];
  iat: number;
  exp: number;
};

type ArchiveRangeItem = {
  start: string;
  end: string;
  source?: string;
  [key: string]: unknown;
};

function normalizeNodeBaseUrl(raw: string | null | undefined): string | null {
  const value = String(raw || '').trim().replace(/\/+$/, '');
  if (!value) return null;
  return /^https?:\/\//i.test(value) ? value : `http://${value}`;
}

function isLoopbackUrl(raw: string): boolean {
  try {
    const hostname = new URL(raw).hostname.toLowerCase();
    return hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '::1' || hostname === '[::1]';
  } catch {
    return false;
  }
}

function nodeBaseCandidates(channel: HikvisionChannelRow): string[] {
  const internal = normalizeNodeBaseUrl(channel.node_internal_url);
  const publicUrl = normalizeNodeBaseUrl(channel.node_public_base_url);
  const values: string[] = [];
  const add = (value: string | null) => {
    if (value && !values.includes(value)) values.push(value);
  };

  // Prefer a routable internal URL, then public URL. A stale internal address
  // may point to an ordinary video-node service, so every HTTP status that can
  // represent the wrong service is retried against the next candidate.
  if (internal && !isLoopbackUrl(internal)) add(internal);
  add(publicUrl);
  add(internal);
  return values;
}

function safeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function signMediaToken(secret: string, channelId: string, scopes: MediaScope[]): string {
  const now = Math.floor(Date.now() / 1000);
  const ttl = Math.max(30, Math.min(config.playbackTokenTtlSeconds, 3600));
  const body = Buffer.from(JSON.stringify({ channel_id: channelId, scopes, iat: now, exp: now + ttl })).toString('base64url');
  const signature = crypto.createHmac('sha256', secret).update(body).digest('base64url');
  return `${body}.${signature}`;
}

function verifyMediaToken(secret: string, channelId: string, scope: MediaScope, token: string): MediaTokenPayload {
  const [body, signature, extra] = token.split('.');
  if (!body || !signature || extra) {
    throw Object.assign(new Error('Invalid Hikvision media token'), { statusCode: 401 });
  }
  const expected = crypto.createHmac('sha256', secret).update(body).digest('base64url');
  if (!safeEqual(signature, expected)) {
    throw Object.assign(new Error('Invalid Hikvision media token'), { statusCode: 401 });
  }

  let payload: MediaTokenPayload;
  try {
    payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) as MediaTokenPayload;
  } catch {
    throw Object.assign(new Error('Invalid Hikvision media token payload'), { statusCode: 401 });
  }

  const now = Math.floor(Date.now() / 1000);
  if (payload.channel_id !== channelId || !Array.isArray(payload.scopes) || !payload.scopes.includes(scope)) {
    throw Object.assign(new Error('Hikvision media token scope mismatch'), { statusCode: 403 });
  }
  if (!Number.isFinite(payload.exp) || payload.exp < now || !Number.isFinite(payload.iat) || payload.iat > now + 60) {
    throw Object.assign(new Error('Hikvision media token expired'), { statusCode: 401 });
  }
  return payload;
}

function upstreamMediaSecret(channel: HikvisionChannelRow): string {
  const agentHash = String(channel.node_agent_token_hash || '').trim();
  if (/^[a-f0-9]{64}$/i.test(agentHash)) return agentHash;
  return String(channel.node_media_secret || '').trim();
}

async function loadChannel(channelId: string): Promise<HikvisionChannelRow | null> {
  const result = await query<HikvisionChannelRow>(
    `SELECT h.channel_external_id, h.device_id, h.dvr_server_id, h.physical_channel,
            h.name, h.online, h.enabled, h.primary_stream_id, h.archive_storage,
            h.retention_days, h.streams, h.discovered_at,
            d.name AS device_name, d.is_enabled AS device_enabled,
            n.name AS node_name,
            COALESCE(n.public_base_url, n.base_url) AS node_public_base_url,
            n.internal_url AS node_internal_url,
            n.media_secret AS node_media_secret,
            n.agent_token_hash AS node_agent_token_hash,
            n.status AS node_status, n.is_enabled AS node_enabled
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
  if (!upstreamMediaSecret(channel)) throw Object.assign(new Error('Hikvision upstream media credential is not configured'), { statusCode: 409 });
}

function upstreamUrl(
  base: string,
  channelId: string,
  suffix: string,
  token: string,
  params: Record<string, string> = {}
): string {
  const queryString = new URLSearchParams({ ...params, token });
  return `${base}/api/v1/media/channels/${encodeURIComponent(channelId)}/${suffix}?${queryString.toString()}`;
}

async function fetchNodeMedia(
  channel: HikvisionChannelRow,
  scope: MediaScope,
  suffix: string,
  init: RequestInit = {},
  params: Record<string, string> = {},
  timeoutMs = 60_000
): Promise<globalThis.Response> {
  requirePlayable(channel);
  const candidates = nodeBaseCandidates(channel);
  if (!candidates.length) {
    throw Object.assign(new Error('Hikvision node URL is not configured'), { statusCode: 409 });
  }

  // Browser tokens are validated only by master. Upstream requests receive a
  // separate token signed with SHA-256(DVR_NODE_TOKEN), which master already
  // stores as agent_token_hash and the node can derive from its raw token.
  const upstreamToken = signMediaToken(upstreamMediaSecret(channel), channel.channel_external_id, [scope]);
  let lastError: unknown = null;
  const attempts: string[] = [];

  for (let index = 0; index < candidates.length; index += 1) {
    const base = candidates[index]!;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(
        upstreamUrl(base, channel.channel_external_id, suffix, upstreamToken, params),
        { ...init, signal: controller.signal }
      );
      if (response.ok) return response;

      const text = await response.text().catch(() => '');
      attempts.push(`${base} -> HTTP ${response.status}`);
      const error = Object.assign(
        new Error(text || `Hikvision node HTTP ${response.status}`),
        { statusCode: response.status, upstreamAttempts: attempts }
      );
      lastError = error;

      // 401/403 can be returned by a stale internal URL that points to the
      // ordinary video-node service. Try the configured public Hikvision URL
      // before deciding that the credential itself is invalid.
      const retryableStatus = [401, 403, 404, 408, 425, 429, 500, 502, 503, 504].includes(response.status);
      if (!retryableStatus || index === candidates.length - 1) throw error;
    } catch (error) {
      lastError = error;
      if (!attempts.some((item) => item.startsWith(`${base} ->`))) {
        attempts.push(`${base} -> ${error instanceof Error ? error.message : String(error)}`);
      }
      if (index === candidates.length - 1) {
        if (error && typeof error === 'object') (error as any).upstreamAttempts = attempts;
        throw error;
      }
    } finally {
      clearTimeout(timer);
    }
  }

  throw lastError || Object.assign(new Error('Hikvision node is unavailable'), { statusCode: 502, upstreamAttempts: attempts });
}

async function nodeJson(
  channel: HikvisionChannelRow,
  scope: MediaScope,
  suffix: string,
  init: RequestInit = {},
  params: Record<string, string> = {},
  timeoutMs = 60_000
): Promise<any> {
  const response = await fetchNodeMedia(channel, scope, suffix, {
    ...init,
    headers: { accept: 'application/json', 'content-type': 'application/json', ...(init.headers || {}) }
  }, params, timeoutMs);
  const text = await response.text();
  try {
    return text ? JSON.parse(text) : {};
  } catch {
    throw Object.assign(new Error(text || 'Invalid JSON from Hikvision node'), { statusCode: 502 });
  }
}

function proxyMediaUrl(
  channelId: string,
  suffix: string,
  token: string,
  params: Record<string, string> = {}
): string {
  const queryString = new URLSearchParams({ ...params, token });
  return `/api/hikvision-media/channels/${encodeURIComponent(channelId)}/${suffix}?${queryString.toString()}`;
}

function requestedScope(suffix: string): MediaScope | null {
  if (suffix === 'snapshot.jpg') return 'snapshot';
  if (suffix.startsWith('live/')) return 'live';
  if (suffix.startsWith('archive/')) return 'archive';
  return null;
}

function copyProxyHeaders(response: globalThis.Response, res: ExpressResponse): void {
  for (const header of [
    'content-type', 'content-length', 'content-range', 'accept-ranges',
    'cache-control', 'etag', 'last-modified', 'content-disposition'
  ]) {
    const value = response.headers.get(header);
    if (value) res.setHeader(header, value);
  }
  res.setHeader('x-newdomofon-hikvision-media-proxy', 'master');
  res.setHeader('x-newdomofon-hikvision-upstream-auth', 'agent-token-hash');
}

function streamProxyResponse(response: globalThis.Response, res: ExpressResponse): void {
  res.status(response.status);
  copyProxyHeaders(response, res);
  if (!response.body) {
    res.end();
    return;
  }
  const stream = Readable.fromWeb(response.body as any);
  stream.once('error', () => {
    if (!res.writableEnded) res.end();
  });
  res.once('close', () => stream.destroy());
  stream.pipe(res);
}

function errorStatus(error: unknown): number {
  if (!error || typeof error !== 'object') return 0;
  const value = Number((error as { statusCode?: unknown }).statusCode);
  return Number.isInteger(value) ? value : 0;
}

function archiveChunks(start: Date, end: Date): Array<{ start: Date; end: Date }> {
  const chunks: Array<{ start: Date; end: Date }> = [];
  for (let cursor = start.getTime(); cursor < end.getTime(); cursor += ARCHIVE_RANGE_CHUNK_MS) {
    chunks.push({
      start: new Date(cursor),
      end: new Date(Math.min(end.getTime(), cursor + ARCHIVE_RANGE_CHUNK_MS))
    });
  }
  return chunks;
}

function mergeArchiveRanges(items: ArchiveRangeItem[]): ArchiveRangeItem[] {
  const normalized = items.map((item) => {
    const startMs = new Date(item.start).getTime();
    const endMs = new Date(item.end).getTime();
    return { item, startMs, endMs };
  }).filter((entry) => Number.isFinite(entry.startMs) && Number.isFinite(entry.endMs) && entry.endMs > entry.startMs)
    .sort((a, b) => a.startMs - b.startMs);

  const merged: Array<{ startMs: number; endMs: number; source?: string }> = [];
  for (const entry of normalized) {
    const source = String(entry.item.source || '');
    const current = merged[merged.length - 1];
    if (current && String(current.source || '') === source && entry.startMs <= current.endMs + ARCHIVE_RANGE_MERGE_GAP_MS) {
      current.endMs = Math.max(current.endMs, entry.endMs);
    } else {
      merged.push({ startMs: entry.startMs, endMs: entry.endMs, source });
    }
  }

  return merged.map((item) => ({
    start: new Date(item.startMs).toISOString(),
    end: new Date(item.endMs).toISOString(),
    source: item.source || undefined
  }));
}

async function loadArchiveRangesChunked(
  channel: HikvisionChannelRow,
  start: Date,
  end: Date
): Promise<{ items: ArchiveRangeItem[]; chunksAttempted: number; chunksSucceeded: number; chunksNotFound: number }> {
  const chunks = archiveChunks(start, end);
  const items: ArchiveRangeItem[] = [];
  let chunksSucceeded = 0;
  let chunksNotFound = 0;
  let lastNotFound: unknown = null;

  for (const chunk of chunks) {
    try {
      const payload = await nodeJson(channel, 'archive', 'archive/ranges', {}, {
        start: chunk.start.toISOString(),
        end: chunk.end.toISOString()
      });
      chunksSucceeded += 1;
      items.push(...((payload.ranges || payload.items || []) as ArchiveRangeItem[]));
    } catch (error) {
      if (errorStatus(error) === 404) {
        chunksNotFound += 1;
        lastNotFound = error;
        continue;
      }
      throw error;
    }
  }

  if (!chunksSucceeded && lastNotFound) {
    throw Object.assign(
      new Error('Hikvision archive ranges endpoint was not found on every configured node URL'),
      { statusCode: 502, cause: lastNotFound }
    );
  }

  return {
    items: mergeArchiveRanges(items),
    chunksAttempted: chunks.length,
    chunksSucceeded,
    chunksNotFound
  };
}

// Token-authenticated same-origin media gateway. The browser never receives
// an http:// private-node URL, so HTTPS pages do not trigger mixed-content
// blocking. Relative HLS segment paths remain valid because this route mirrors
// the Hikvision-node media path structure.
hikvisionMediaProxyRouter.get(/^\/channels\/([^/]+)\/(.+)$/, asyncHandler(async (req: Request, res: ExpressResponse) => {
  const channelId = decodeURIComponent(String(req.params[0] || ''));
  const suffix = decodeURIComponent(String(req.params[1] || ''));
  if (!channelId || !suffix || suffix.includes('..') || suffix.includes('\\') || suffix.includes('\0')) {
    return res.status(400).json({ error: 'Invalid Hikvision media path' });
  }

  const scope = requestedScope(suffix);
  if (!scope) return res.status(404).json({ error: 'Hikvision media route not found' });
  const channel = await loadChannel(channelId);
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });

  const browserToken = String(req.query.token || '').trim();
  if (!browserToken) return res.status(401).json({ error: 'Missing Hikvision media token' });
  verifyMediaToken(channel.node_media_secret, channel.channel_external_id, scope, browserToken);

  const params: Record<string, string> = {};
  for (const [key, raw] of Object.entries(req.query)) {
    if (key === 'token' || raw === undefined) continue;
    params[key] = Array.isArray(raw) ? String(raw[0] || '') : String(raw);
  }

  const headers: Record<string, string> = {};
  for (const name of ['range', 'if-none-match', 'if-modified-since', 'accept']) {
    const value = req.get(name);
    if (value) headers[name] = value;
  }

  const upstream = await fetchNodeMedia(
    channel,
    scope,
    suffix,
    { method: 'GET', headers },
    params,
    suffix.endsWith('.mp4') ? 10 * 60_000 : 90_000
  );
  streamProxyResponse(upstream, res);
}));

hikvisionPlayerRouter.use(requireAuth);

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
  requirePlayable(channel);
  const token = signMediaToken(channel.node_media_secret, channel.channel_external_id, ['live']);
  const url = proxyMediaUrl(channel.channel_external_id, 'live/index.m3u8', token);
  res.json({ liveHls: url, hls_url: url, playback_url: url, source: 'hikvision-node-via-master', expiresIn: config.playbackTokenTtlSeconds });
}));

hikvisionPlayerRouter.get('/:channelId/archive/ranges', asyncHandler(async (req, res) => {
  const params = rangeSchema.parse(req.query);
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  const start = new Date(params.start);
  const end = new Date(params.end);
  if (end <= start) return res.status(400).json({ error: 'end must be after start' });

  const result = await loadArchiveRangesChunked(channel, start, end);
  res.setHeader('cache-control', 'no-store');
  res.json({
    items: result.items,
    source: channel.archive_storage,
    requested_source: channel.archive_storage,
    archive_storage: channel.archive_storage,
    available_sources: [channel.archive_storage],
    range_query: {
      chunk_seconds: ARCHIVE_RANGE_CHUNK_MS / 1000,
      chunks_attempted: result.chunksAttempted,
      chunks_succeeded: result.chunksSucceeded,
      chunks_not_found: result.chunksNotFound
    }
  });
}));

async function archiveResponse(req: any, res: any) {
  const params = rangeSchema.parse(req.query);
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  requirePlayable(channel);
  const browserToken = signMediaToken(channel.node_media_secret, channel.channel_external_id, ['archive']);
  const session = await nodeJson(
    channel,
    'archive',
    'archive/session',
    { method: 'POST', body: JSON.stringify({ start: params.start, end: params.end }) },
    {},
    90_000
  );
  const sessionId = String(session.id || '').trim();
  if (!sessionId) throw Object.assign(new Error('Hikvision node did not return archive session id'), { statusCode: 502 });
  const url = proxyMediaUrl(
    channel.channel_external_id,
    `archive/sessions/${encodeURIComponent(sessionId)}/index.m3u8`,
    browserToken
  );
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
  requirePlayable(channel);
  const token = signMediaToken(channel.node_media_secret, channel.channel_external_id, ['archive']);
  const url = proxyMediaUrl(channel.channel_external_id, 'archive/export.mp4', token, { start: params.start, end: params.end });
  res.json({ exportMp4: url, source: channel.archive_storage, expiresIn: config.playbackTokenTtlSeconds });
}));

hikvisionPlayerRouter.get('/:channelId/snapshot', asyncHandler(async (req, res) => {
  const channel = await loadChannel(decodeURIComponent(req.params.channelId));
  if (!channel) return res.status(404).json({ error: 'Hikvision channel not found' });
  requirePlayable(channel);
  const token = signMediaToken(channel.node_media_secret, channel.channel_external_id, ['snapshot']);
  const url = proxyMediaUrl(channel.channel_external_id, 'snapshot.jpg', token);
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
    default_archive_source: channel.archive_storage,
    media_transport: 'master-https-proxy',
    upstream_media_auth: 'agent-token-hash'
  });
}));

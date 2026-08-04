import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { query } from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { asyncHandler } from '../utils/asyncHandler.js';

export const hikvisionEventsRouter = Router();

const querySchema = z.object({
  start: z.string().datetime(),
  end: z.string().datetime(),
  type: z.string().min(1).max(128).optional(),
  limit: z.coerce.number().int().min(1).max(5000).optional()
});

type HikvisionEventTarget = {
  channel_external_id: string;
  node_internal_url: string | null;
  node_public_base_url: string | null;
  node_media_secret: string;
  node_agent_token_hash: string;
  node_enabled: boolean;
  node_status: string;
};

function normalizeBase(raw: string | null | undefined): string | null {
  const value = String(raw || '').trim().replace(/\/+$/, '');
  if (!value) return null;
  return /^https?:\/\//i.test(value) ? value : `http://${value}`;
}

function uniqueBases(...values: Array<string | null | undefined>): string[] {
  const result: string[] = [];
  for (const raw of values) {
    const value = normalizeBase(raw);
    if (value && !result.includes(value)) result.push(value);
  }
  return result;
}

async function loadTarget(channelId: string): Promise<HikvisionEventTarget | null> {
  const result = await query<HikvisionEventTarget>(
    `SELECT h.channel_external_id,
            n.internal_url AS node_internal_url,
            COALESCE(n.public_base_url, n.base_url) AS node_public_base_url,
            n.media_secret AS node_media_secret,
            n.agent_token_hash AS node_agent_token_hash,
            n.is_enabled AS node_enabled,
            n.status AS node_status
       FROM hikvision_node_channels h
       JOIN dvr_servers n ON n.id = h.dvr_server_id
      WHERE h.channel_external_id = $1
      LIMIT 1`,
    [channelId]
  );
  return result.rows[0] || null;
}

function upstreamSecret(target: HikvisionEventTarget): string {
  const hash = String(target.node_agent_token_hash || '').trim();
  if (/^[a-f0-9]{64}$/i.test(hash)) return hash;
  return String(target.node_media_secret || '').trim();
}

function signEventsToken(secret: string, channelId: string): string {
  const now = Math.floor(Date.now() / 1000);
  const ttl = Math.max(60, Math.min(900, Number(process.env.HIKVISION_EVENT_TOKEN_TTL_SECONDS || 300)));
  const body = Buffer.from(JSON.stringify({
    channel_id: channelId,
    scopes: ['events'],
    iat: now,
    exp: now + ttl
  })).toString('base64url');
  const signature = crypto.createHmac('sha256', secret).update(body).digest('base64url');
  return `${body}.${signature}`;
}

async function fetchEvents(
  target: HikvisionEventTarget,
  suffix: '' | '/summary',
  params: Record<string, string>
): Promise<{ status: number; contentType: string; body: string }> {
  if (!target.node_enabled) throw Object.assign(new Error('Hikvision node is disabled'), { statusCode: 503 });
  const secret = upstreamSecret(target);
  if (!secret) throw Object.assign(new Error('Hikvision node event credential is not configured'), { statusCode: 503 });
  const bases = uniqueBases(target.node_internal_url, target.node_public_base_url);
  if (!bases.length) throw Object.assign(new Error('Hikvision node URL is not configured'), { statusCode: 503 });

  const token = signEventsToken(secret, target.channel_external_id);
  const search = new URLSearchParams({ ...params, token });
  const timeoutMs = Math.max(1000, Math.min(60_000, Number(process.env.HIKVISION_EVENT_PROXY_TIMEOUT_MS || 15_000)));
  const attempts: string[] = [];

  for (const base of bases) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const url = `${base}/api/v1/events/channels/${encodeURIComponent(target.channel_external_id)}${suffix}?${search.toString()}`;
      const response = await fetch(url, {
        signal: controller.signal,
        headers: { accept: 'application/json', 'x-forwarded-by': 'newdomofon-video-master' }
      });
      const body = await response.text();
      if (response.ok || [400, 413, 422].includes(response.status)) {
        return {
          status: response.status,
          contentType: response.headers.get('content-type') || 'application/json',
          body: body || '{"items":[]}'
        };
      }
      attempts.push(`${base} -> HTTP ${response.status}`);
    } catch (error) {
      attempts.push(`${base} -> ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      clearTimeout(timer);
    }
  }

  console.warn('[hikvision-events-proxy] node request failed', {
    channel_id: target.channel_external_id,
    node_status: target.node_status,
    attempts
  });
  throw Object.assign(new Error(`Hikvision event storage is unavailable: ${attempts.join(' | ')}`), { statusCode: 503 });
}

hikvisionEventsRouter.use(requireAuth);

hikvisionEventsRouter.get('/:channelId/events', asyncHandler(async (req, res) => {
  const q = querySchema.parse(req.query);
  const startMs = Date.parse(q.start);
  const endMs = Date.parse(q.end);
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs) {
    return res.status(400).json({ error: 'Invalid start/end' });
  }
  const channelId = decodeURIComponent(req.params.channelId);
  const target = await loadTarget(channelId);
  if (!target) return res.status(404).json({ error: 'Hikvision channel not found' });
  const result = await fetchEvents(target, '', {
    start: q.start,
    end: q.end,
    ...(q.type ? { type: q.type } : {}),
    limit: String(q.limit || 5000)
  });
  res.setHeader('cache-control', 'no-store');
  res.type(result.contentType);
  return res.status(result.status).send(result.body);
}));

hikvisionEventsRouter.get('/:channelId/events/summary', asyncHandler(async (req, res) => {
  const q = querySchema.pick({ start: true, end: true }).parse(req.query);
  const channelId = decodeURIComponent(req.params.channelId);
  const target = await loadTarget(channelId);
  if (!target) return res.status(404).json({ error: 'Hikvision channel not found' });
  const result = await fetchEvents(target, '/summary', { start: q.start, end: q.end });
  res.setHeader('cache-control', 'no-store');
  res.type(result.contentType);
  return res.status(result.status).send(result.body);
}));

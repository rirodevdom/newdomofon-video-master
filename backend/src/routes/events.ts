import { Router } from 'express';
import { z } from 'zod';
import { requireAuth, isAdmin } from '../middleware/auth.js';
import { asyncHandler } from '../utils/asyncHandler.js';
import type { AuthRequest } from '../types.js';
import { canAccessCamera } from '../services/cameraAccess.js';
import { fetchNodeEvents, getCameraEventTarget } from '../services/nodeEventProxy.js';
import { logicalEventView, type CameraEventRecord } from '../services/logicalEventView.js';

export const eventsRouter = Router();
export const internalEventsRouter = Router();

const paramsSchema = z.object({ cameraId: z.string().uuid() });
const rangeSchema = z.object({
  start: z.string().datetime(),
  end: z.string().datetime()
});
const eventsQuerySchema = rangeSchema.extend({
  type: z.string().min(1).max(128).optional(),
  limit: z.coerce.number().int().min(1).max(5000).optional(),
  mode: z.enum(['logical', 'raw']).optional().default('logical'),
  include_inactive: z.enum(['0', '1', 'false', 'true']).optional(),
  dedup_ms: z.coerce.number().int().min(100).max(10_000).optional()
});

function validateRange(start: string, end: string): void {
  const startMs = Date.parse(start);
  const endMs = Date.parse(end);
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || startMs >= endMs) {
    const error = new Error('Invalid start/end') as Error & { statusCode?: number };
    error.statusCode = 400;
    throw error;
  }

  const maxSeconds = Math.max(60, Number(process.env.NODE_EVENT_QUERY_MAX_SECONDS || 31 * 24 * 60 * 60));
  if (Math.ceil((endMs - startMs) / 1000) > maxSeconds) {
    const error = new Error(`Requested event range is too large. Max ${maxSeconds} seconds.`) as Error & { statusCode?: number };
    error.statusCode = 413;
    throw error;
  }
}

function asFlag(value: string | undefined): boolean {
  return value === '1' || value === 'true';
}

function logicalBody(body: string, includeInactive: boolean, dedupMs: number): string {
  try {
    const parsed = JSON.parse(body) as { items?: CameraEventRecord[]; [key: string]: unknown };
    const rawItems = Array.isArray(parsed.items) ? parsed.items : [];
    const items = logicalEventView(rawItems, { includeInactive, dedupMs });
    return JSON.stringify({
      ...parsed,
      mode: 'logical',
      count: items.length,
      raw_count: rawItems.length,
      items
    });
  } catch {
    return body;
  }
}

async function proxyRoute(
  req: AuthRequest,
  res: any,
  suffix: 'events' | 'events/summary',
  query: Record<string, string>,
  view?: { mode: 'logical' | 'raw'; includeInactive: boolean; dedupMs: number }
) {
  const { cameraId } = paramsSchema.parse(req.params);

  if (!isAdmin(req) && !await canAccessCamera(req.user!, cameraId)) {
    return res.status(403).json({ error: 'No access to camera' });
  }

  const target = await getCameraEventTarget(cameraId);
  if (!target) return res.status(404).json({ error: 'Camera not found' });

  const result = await fetchNodeEvents({
    target,
    userId: req.user!.id,
    suffix,
    query
  });

  const body = result.ok && suffix === 'events' && view?.mode === 'logical'
    ? logicalBody(result.body, view.includeInactive, view.dedupMs)
    : result.body;

  res.setHeader('cache-control', 'no-store');
  res.type(result.contentType);
  return res.status(result.status).send(body);
}

eventsRouter.use(requireAuth);

eventsRouter.get('/cameras/:cameraId/events', asyncHandler(async (req, res) => {
  const q = eventsQuerySchema.parse(req.query);
  validateRange(q.start, q.end);
  return proxyRoute(req as AuthRequest, res, 'events', {
    start: q.start,
    end: q.end,
    ...(q.type ? { type: q.type } : {}),
    ...(q.limit ? { limit: String(q.limit) } : {})
  }, {
    mode: q.mode,
    includeInactive: asFlag(q.include_inactive),
    dedupMs: q.dedup_ms ?? Math.max(100, Math.min(10_000, Number(process.env.EVENT_LOGICAL_DEDUP_MS || 2000)))
  });
}));

eventsRouter.get('/cameras/:cameraId/events/summary', asyncHandler(async (req, res) => {
  const q = rangeSchema.parse(req.query);
  validateRange(q.start, q.end);
  return proxyRoute(req as AuthRequest, res, 'events/summary', {
    start: q.start,
    end: q.end
  });
}));

function requireInternal(req: any, res: any, next: any) {
  const expected = process.env.INTERNAL_DVR_SECRET;
  const actual = req.header('x-internal-secret');
  if (!expected) return res.status(500).json({ error: 'INTERNAL_DVR_SECRET is not configured' });
  if (!actual || actual !== expected) return res.status(403).json({ error: 'Forbidden' });
  return next();
}

internalEventsRouter.use(requireInternal);
internalEventsRouter.get('/cameras/onvif', (_req, res) => {
  res.status(410).json({
    error: 'ONVIF camera discovery moved to node-agent config',
    storage: 'node'
  });
});
internalEventsRouter.post('/events/onvif', (_req, res) => {
  res.status(410).json({
    error: 'Event ingest on master is disabled; events are stored on node',
    storage: 'node'
  });
});

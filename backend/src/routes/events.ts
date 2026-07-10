import { Router } from 'express';
import { z } from 'zod';
import { requireAuth, isAdmin } from '../middleware/auth.js';
import { asyncHandler } from '../utils/asyncHandler.js';
import type { AuthRequest } from '../types.js';
import { canAccessCamera } from '../services/cameraAccess.js';
import { fetchNodeEvents, getCameraEventTarget } from '../services/nodeEventProxy.js';

export const eventsRouter = Router();
export const internalEventsRouter = Router();

const paramsSchema = z.object({ cameraId: z.string().uuid() });
const rangeSchema = z.object({
  start: z.string().datetime(),
  end: z.string().datetime()
});
const eventsQuerySchema = rangeSchema.extend({
  type: z.string().min(1).max(128).optional(),
  limit: z.coerce.number().int().min(1).max(5000).optional()
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

async function proxyRoute(
  req: AuthRequest,
  res: any,
  suffix: 'events' | 'events/summary',
  query: Record<string, string>
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

  res.setHeader('cache-control', 'no-store');
  res.type(result.contentType);
  return res.status(result.status).send(result.body);
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

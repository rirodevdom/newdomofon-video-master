import crypto from 'node:crypto';
import { Router } from 'express';
import { query } from '../db.js';
import { asyncHandler } from '../utils/asyncHandler.js';

export const internalOnvifEventsRouter = Router();

function requireInternalSecret(req: any, res: any, next: any) {
  const expected = process.env.INTERNAL_DVR_SECRET || '';
  const actual = String(req.header('x-internal-secret') || req.header('x-dvr-secret') || '');

  if (!expected || actual !== expected) {
    return res.status(401).json({ error: 'Invalid internal secret' });
  }

  next();
}

function parseRtspCredentials(sourceUrl: string | null | undefined) {
  if (!sourceUrl) return { username: null, password: null };

  try {
    const url = new URL(sourceUrl);
    if (url.protocol !== 'rtsp:') return { username: null, password: null };

    return {
      username: url.username ? decodeURIComponent(url.username) : null,
      password: url.password ? decodeURIComponent(url.password) : null
    };
  } catch {
    return { username: null, password: null };
  }
}

function onvifXaddrFromDevice(host: string | null | undefined, port: number | null | undefined) {
  const raw = String(host || '').trim();
  if (!raw) return '';

  const scheme = raw.toLowerCase().startsWith('https://') ? 'https' : 'http';
  const withoutScheme = raw.replace(/^https?:\/\//i, '');
  const hostname = withoutScheme.split('/')[0].replace(/:\d+$/, '').trim();
  if (!hostname) return '';

  return `${scheme}://${hostname}:${Number(port || 80)}/onvif/device_service`;
}

function stableJson(value: unknown): string {
  if (value === null || value === undefined) return '';

  if (Array.isArray(value)) {
    return `[${value.map((item) => stableJson(item)).join(',')}]`;
  }

  if (typeof value === 'object') {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`).join(',')}}`;
  }

  return JSON.stringify(value);
}

function eventHash(input: {
  camera_id: string;
  stream_name: string;
  event_type: string;
  event_state: string | null;
  occurred_at: Date;
  data: unknown;
}) {
  return crypto
    .createHash('sha256')
    .update([
      input.camera_id,
      input.stream_name,
      input.event_type,
      input.event_state ?? '',
      input.occurred_at.toISOString(),
      stableJson(input.data)
    ].join('|'))
    .digest('hex');
}

internalOnvifEventsRouter.get('/cameras/onvif', requireInternalSecret, asyncHandler(async (req, res) => {
  const nodeId = String(req.header('x-node-id') || '').trim();
  const params: string[] = [];
  let nodeFilter = '';
  if (nodeId) {
    params.push(nodeId);
    nodeFilter = `AND d.dvr_server_id = $${params.length}`;
  }
  const result = await query(
    `SELECT c.id, c.name, c.stream_name, c.source_url,
            c.onvif_xaddr, c.onvif_port, c.onvif_username, c.onvif_password,
            d.connection_type AS device_connection_type,
            d.host AS device_host,
            d.port AS device_port,
            d.username AS device_username,
            d.password AS device_password
       FROM public.cameras c
       JOIN public.devices d ON d.id = c.device_id
      WHERE c.is_enabled = true
        AND d.is_enabled = true
        AND (
          c.onvif_xaddr IS NOT NULL
          OR (d.connection_type = 'ONVIF' AND d.host IS NOT NULL)
        )
        ${nodeFilter}
      ORDER BY c.name ASC`,
    params
  );

  const items = result.rows.map((camera: any) => {
    const rtspCreds = parseRtspCredentials(camera.source_url);
    const deviceXaddr = camera.device_connection_type === 'ONVIF'
      ? onvifXaddrFromDevice(camera.device_host, camera.device_port)
      : '';
    const onvifXaddr = camera.onvif_xaddr || deviceXaddr;

    return {
      id: camera.id,
      name: camera.name,
      stream_name: camera.stream_name,
      source_url: camera.source_url,
      onvif_xaddr: onvifXaddr,
      onvif_port: camera.onvif_port || camera.device_port || 80,
      onvif_username: camera.onvif_username || camera.device_username || rtspCreds.username || '',
      onvif_password: camera.onvif_password || camera.device_password || rtspCreds.password || ''
    };
  }).filter((camera: any) => camera.onvif_xaddr);

  res.json({ items });
}));

internalOnvifEventsRouter.post('/events/onvif', requireInternalSecret, asyncHandler(async (req, res) => {
  const body = req.body || {};

  if (!body.camera_id || !body.stream_name) {
    return res.status(400).json({ error: 'camera_id and stream_name are required' });
  }

  const eventType = String(body.event_type || body.topic || 'onvif.event');
  const eventState = body.event_state === undefined || body.event_state === null
    ? null
    : String(body.event_state);

  const receivedAt = new Date();
  const suppliedOccurredAt = body.occurred_at ? new Date(body.occurred_at) : receivedAt;
  const maxClockSkewMs = Math.max(
    60_000,
    Number(process.env.ONVIF_EVENT_MAX_CLOCK_SKEW_MS || 5 * 60 * 1000)
  );
  const suppliedTime = suppliedOccurredAt.getTime();
  const invalidTime = !Number.isFinite(suppliedTime);
  const clockSkewMs = invalidTime ? Number.POSITIVE_INFINITY : suppliedTime - receivedAt.getTime();
  const normalizeTime = invalidTime || Math.abs(clockSkewMs) > maxClockSkewMs;
  const occurredAt = normalizeTime ? receivedAt : suppliedOccurredAt;
  let data = body.data && typeof body.data === 'object' ? body.data : {};

  if (normalizeTime) {
    data = {
      ...data,
      _newdomofon_time_normalized: true,
      _newdomofon_original_occurred_at: body.occurred_at ?? null,
      _newdomofon_received_at: receivedAt.toISOString(),
      _newdomofon_clock_skew_ms: Number.isFinite(clockSkewMs) ? clockSkewMs : null
    };
    console.warn('[onvif-events] camera timestamp normalized', {
      stream_name: body.stream_name,
      original: body.occurred_at ?? null,
      received_at: receivedAt.toISOString(),
      clock_skew_ms: Number.isFinite(clockSkewMs) ? clockSkewMs : null
    });
  }
  const hash = eventHash({
    camera_id: String(body.camera_id),
    stream_name: String(body.stream_name),
    event_type: eventType,
    event_state: eventState,
    occurred_at: occurredAt,
    data
  });

  const result = await query(
    `INSERT INTO public.camera_events(
       camera_id, stream_name, event_type, event_state, occurred_at, data, event_hash
     )
     VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7)
     ON CONFLICT DO NOTHING
     RETURNING id`,
    [
      body.camera_id,
      body.stream_name,
      eventType,
      eventState,
      occurredAt,
      JSON.stringify(data),
      hash
    ]
  );

  if (result.rowCount) {
    console.log('[onvif-events] stored', {
      stream_name: body.stream_name,
      event_type: eventType,
      event_state: eventState,
      occurred_at: occurredAt.toISOString(),
      event_hash: hash.slice(0, 12)
    });
  } else {
    console.log('[onvif-events] duplicate skipped', {
      stream_name: body.stream_name,
      event_type: eventType,
      event_state: eventState,
      occurred_at: occurredAt.toISOString(),
      event_hash: hash.slice(0, 12)
    });
  }

  res.status(result.rowCount ? 201 : 200).json({ ok: true, inserted: Boolean(result.rowCount) });
}));

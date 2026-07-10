'use strict';

const http = require('node:http');
const { URL } = require('node:url');

const VERSION = 'v302-smartyard-camera-events';
const PUBLIC_PORT = Number(process.env.SMARTYARD_COMPAT_PORT || 3082);
const PUBLIC_HOST = process.env.SMARTYARD_COMPAT_HOST || '127.0.0.1';
const MEDIA_GATEWAY_PORT = Number(process.env.SMARTYARD_MEDIA_GATEWAY_PORT || 3084);
const LEGACY_PORT = Number(process.env.SMARTYARD_LEGACY_PORT || 3083);
const BACKEND_URL = String(process.env.SMARTYARD_BACKEND_URL || 'http://127.0.0.1:3000').replace(/\/+$/, '');
const INTERNAL_SECRET = String(process.env.INTERNAL_DVR_SECRET || '').trim();
const DEFAULT_EVENT_HOURS = Math.max(1, Math.min(24 * 31, Number(process.env.SMARTYARD_EVENT_DEFAULT_HOURS || 24)));
const MAX_EVENT_DAYS = Math.max(1, Math.min(31, Number(process.env.SMARTYARD_EVENT_MAX_DAYS || 31)));
const MOTION_DEDUP_MS = Math.max(100, Math.min(10_000, Number(process.env.SMARTYARD_EVENT_MOTION_DEDUP_MS || 2000)));

// Start the already proven media gateway on an internal port. It keeps the
// legacy compatibility service on LEGACY_PORT. This outer gateway owns the
// public port and intercepts only camera-event paths.
process.env.SMARTYARD_COMPAT_PORT = String(MEDIA_GATEWAY_PORT);
process.env.SMARTYARD_LEGACY_PORT = String(LEGACY_PORT);
require('./server-node-aware.js');
process.env.SMARTYARD_COMPAT_PORT = String(PUBLIC_PORT);

function cors(extra = {}) {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET,HEAD,OPTIONS',
    'access-control-allow-headers': '*',
    'access-control-expose-headers': 'Content-Length,Content-Range,Accept-Ranges,X-Newdomofon-Resolved-Stream,X-Newdomofon-SmartYard-Compat,X-Newdomofon-SmartYard-Route,X-Newdomofon-Events-Count',
    'x-newdomofon-smartyard-compat': VERSION,
    ...extra
  };
}

function sendJson(res, status, body, extra = {}) {
  const text = JSON.stringify(body);
  res.writeHead(status, cors({
    ...extra,
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text)
  }));
  res.end(text);
}

function extractToken(req, reqUrl) {
  const query = reqUrl.searchParams.get('token');
  if (query) return query;

  const authorization = String(req.headers.authorization || '');
  if (/^Bearer\s+/i.test(authorization)) return authorization.replace(/^Bearer\s+/i, '').trim();
  if (/^Basic\s+/i.test(authorization)) {
    try {
      const decoded = Buffer.from(authorization.replace(/^Basic\s+/i, ''), 'base64').toString('utf8');
      const separator = decoded.indexOf(':');
      return separator >= 0 ? decoded.slice(separator + 1) : decoded;
    } catch {
      return '';
    }
  }
  return '';
}

function parseRequestPath(reqUrl) {
  const pathname = decodeURIComponent(reqUrl.pathname || '/');
  let rest = pathname.startsWith('/') ? pathname.slice(1) : pathname;
  if (rest.startsWith('api/media/')) rest = rest.slice('api/media/'.length);
  if (rest.startsWith('api/dvr-archive/')) rest = rest.slice('api/dvr-archive/'.length);
  if (rest.startsWith('dvr-archive/')) rest = rest.slice('dvr-archive/'.length);

  const parts = rest.split('/').filter(Boolean);
  return {
    stream: parts.shift() || '',
    mediaPath: parts.join('/')
  };
}

function safeStream(stream) {
  return /^[A-Za-z0-9_-]+$/.test(String(stream || ''));
}

function isEventsPath(mediaPath) {
  return ['events', 'events.json', 'motion_events.json'].includes(mediaPath);
}

function isEventsSummaryPath(mediaPath) {
  return ['events/summary', 'events_summary.json'].includes(mediaPath);
}

function parseMoment(raw) {
  const value = String(raw || '').trim();
  if (!value) return NaN;

  if (/^\d+(?:\.\d+)?$/.test(value)) {
    const numeric = Number(value);
    if (!Number.isFinite(numeric)) return NaN;
    return numeric > 10_000_000_000 ? numeric : numeric * 1000;
  }

  return Date.parse(value);
}

function parseEventWindow(reqUrl) {
  const startRaw = reqUrl.searchParams.get('start') || reqUrl.searchParams.get('from');
  const endRaw = reqUrl.searchParams.get('end') || reqUrl.searchParams.get('to');

  let endMs = endRaw ? parseMoment(endRaw) : Date.now();
  let startMs = startRaw ? parseMoment(startRaw) : endMs - DEFAULT_EVENT_HOURS * 3600_000;

  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || startMs >= endMs) {
    return { error: 'Invalid event start/end range' };
  }

  const maxMs = MAX_EVENT_DAYS * 24 * 3600_000;
  if (endMs - startMs > maxMs) {
    return { error: `Requested event range is too large. Max ${MAX_EVENT_DAYS} days.` };
  }

  return { startMs, endMs };
}

function parseLimit(reqUrl) {
  const raw = Number(reqUrl.searchParams.get('limit') || 1000);
  return Number.isFinite(raw) ? Math.max(1, Math.min(5000, Math.trunc(raw))) : 1000;
}

async function resolveSmartYardToken(token, stream, upstreamScope) {
  if (!INTERNAL_SECRET || !token || !stream) return null;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5000);
  try {
    const response = await fetch(`${BACKEND_URL}/api/internal/smartyard/resolve`, {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'content-type': 'application/json',
        'x-internal-secret': INTERNAL_SECRET,
        'user-agent': `newdomofon-smartyard-${VERSION}`
      },
      body: JSON.stringify({
        token,
        stream_name: stream,
        upstream_scope: upstreamScope
      })
    });

    const text = await response.text();
    if (!response.ok) {
      return { error_status: response.status, error_body: text };
    }

    let payload;
    try { payload = JSON.parse(text); } catch { return null; }
    if (!payload?.ok || !payload?.node?.url || !payload?.upstream_token) return null;
    return payload;
  } catch (error) {
    console.warn('[smartyard-events] resolver failed', {
      stream,
      upstreamScope,
      error: String(error?.message || error)
    });
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function fetchNodeJson(context, path, timeoutMs = 15000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`${String(context.node.url).replace(/\/+$/, '')}${path}`, {
      signal: controller.signal,
      headers: {
        accept: 'application/json',
        'user-agent': `newdomofon-smartyard-${VERSION}`
      }
    });
    const text = await response.text();
    let body;
    try { body = JSON.parse(text); } catch { body = { error: text || 'Invalid node response' }; }
    return { status: response.status, ok: response.ok, body };
  } finally {
    clearTimeout(timer);
  }
}

function activeState(value) {
  return ['1', 'true', 'on', 'active', 'start', 'started'].includes(String(value || '').toLowerCase());
}

function logicalKey(event) {
  const type = String(event.event_type || event.type || 'unknown').toLowerCase();
  if (type === 'motion') return 'motion';
  return [type, event.source_name || '', event.topic || ''].join('|');
}

function normalizeAndDeduplicateEvents(items, includeInactive) {
  const normalized = [];
  const lastByKey = new Map();

  for (const item of Array.isArray(items) ? items : []) {
    const timestamp = Date.parse(String(item.occurred_at || item.created_at || ''));
    if (!Number.isFinite(timestamp)) continue;

    const state = item.event_state === undefined || item.event_state === null
      ? null
      : String(item.event_state);
    if (!includeInactive && state !== null && !activeState(state)) continue;

    const key = logicalKey(item);
    const previous = lastByKey.get(key);
    if (previous !== undefined && timestamp - previous <= MOTION_DEDUP_MS) continue;
    lastByKey.set(key, timestamp);

    normalized.push({
      id: String(item.id || `${key}-${timestamp}`),
      camera_id: String(item.camera_id || ''),
      stream_name: String(item.stream_name || ''),
      event_type: String(item.event_type || 'unknown'),
      event_state: state,
      occurred_at: new Date(timestamp).toISOString(),
      timestamp,
      topic: item.topic === undefined ? null : item.topic,
      source_name: item.source_name === undefined ? null : item.source_name,
      data: item.data && typeof item.data === 'object' ? item.data : {}
    });
  }

  return normalized;
}

async function handleEvents(req, res, reqUrl, stream, externalToken, summary) {
  const range = parseEventWindow(reqUrl);
  if (range.error) return sendJson(res, 400, { error: range.error });

  const context = await resolveSmartYardToken(externalToken, stream, 'events');
  if (!context) return sendJson(res, 502, { error: 'SmartYard event resolver unavailable' });
  if (context.error_status) {
    let detail = context.error_body;
    try { detail = JSON.parse(context.error_body); } catch { /* keep text */ }
    return sendJson(res, context.error_status, detail || { error: 'Event token rejected' });
  }

  const query = new URLSearchParams({
    start: new Date(range.startMs).toISOString(),
    end: new Date(range.endMs).toISOString(),
    token: context.upstream_token
  });

  if (!summary) {
    query.set('limit', String(parseLimit(reqUrl)));
    const type = String(reqUrl.searchParams.get('type') || '').trim();
    if (type) query.set('type', type);
  }

  const suffix = summary ? 'events/summary' : 'events';
  const nodeResponse = await fetchNodeJson(
    context,
    `/cameras/${encodeURIComponent(stream)}/${suffix}?${query.toString()}`
  );

  if (!nodeResponse.ok) {
    return sendJson(res, nodeResponse.status, nodeResponse.body, {
      'x-newdomofon-resolved-stream': stream,
      'x-newdomofon-smartyard-route': summary ? 'node-events-summary' : 'node-events'
    });
  }

  if (summary) {
    const items = Array.isArray(nodeResponse.body?.items) ? nodeResponse.body.items : [];
    return sendJson(res, 200, {
      stream,
      start: new Date(range.startMs).toISOString(),
      end: new Date(range.endMs).toISOString(),
      items
    }, {
      'x-newdomofon-resolved-stream': stream,
      'x-newdomofon-smartyard-route': 'node-events-summary',
      'x-newdomofon-events-count': String(items.length)
    });
  }

  const rawItems = Array.isArray(nodeResponse.body?.items) ? nodeResponse.body.items : [];
  const includeInactive = ['1', 'true', 'yes', 'on'].includes(
    String(reqUrl.searchParams.get('include_inactive') || '').toLowerCase()
  );
  const items = normalizeAndDeduplicateEvents(rawItems, includeInactive);

  return sendJson(res, 200, {
    stream,
    start: new Date(range.startMs).toISOString(),
    end: new Date(range.endMs).toISOString(),
    count: items.length,
    raw_count: rawItems.length,
    items,
    events: items
  }, {
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-smartyard-route': 'node-events',
    'x-newdomofon-events-count': String(items.length)
  });
}

function proxyMedia(req, res) {
  const upstream = http.request({
    hostname: '127.0.0.1',
    port: MEDIA_GATEWAY_PORT,
    method: req.method,
    path: req.url,
    headers: {
      ...req.headers,
      host: `127.0.0.1:${MEDIA_GATEWAY_PORT}`
    }
  }, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
    upstreamRes.pipe(res);
  });

  upstream.on('error', (error) => {
    sendJson(res, 502, {
      error: 'SmartYard media gateway unavailable',
      message: String(error?.message || error)
    });
  });

  req.pipe(upstream);
}

async function handle(req, res) {
  try {
    const reqUrl = new URL(req.url || '/', 'http://127.0.0.1');

    if (req.method === 'OPTIONS') {
      res.writeHead(204, cors({ 'content-length': '0' }));
      return res.end();
    }

    if (reqUrl.pathname === '/health') {
      return sendJson(res, 200, {
        ok: true,
        service: 'newdomofon-smartyard-events-gateway',
        version: VERSION,
        backend: BACKEND_URL,
        media_gateway_port: MEDIA_GATEWAY_PORT,
        legacy_port: LEGACY_PORT,
        events_enabled: true,
        internal_secret_configured: Boolean(INTERNAL_SECRET)
      });
    }

    const { stream, mediaPath } = parseRequestPath(reqUrl);
    const eventsPath = isEventsPath(mediaPath);
    const summaryPath = isEventsSummaryPath(mediaPath);

    if (!eventsPath && !summaryPath) return proxyMedia(req, res);
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return sendJson(res, 405, { error: 'Method not allowed' });
    }
    if (!safeStream(stream)) return sendJson(res, 400, { error: 'Invalid stream name' });

    const externalToken = extractToken(req, reqUrl);
    if (!externalToken) return sendJson(res, 401, { error: 'Missing playback token' });

    return await handleEvents(req, res, reqUrl, stream, externalToken, summaryPath);
  } catch (error) {
    console.error('[smartyard-events] request failed', error);
    sendJson(res, 502, {
      error: 'SmartYard camera event gateway error',
      message: String(error?.message || error)
    });
  }
}

const server = http.createServer((req, res) => {
  void handle(req, res);
});

server.listen(PUBLIC_PORT, PUBLIC_HOST, () => {
  console.log('[smartyard-events] listening', {
    host: PUBLIC_HOST,
    port: PUBLIC_PORT,
    media_gateway_port: MEDIA_GATEWAY_PORT,
    legacy_port: LEGACY_PORT,
    backend: BACKEND_URL,
    version: VERSION
  });
});

process.on('SIGTERM', () => server.close());
process.on('SIGINT', () => server.close());

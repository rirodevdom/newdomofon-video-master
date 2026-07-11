'use strict';

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const { URL } = require('node:url');

const VERSION = 'v303-node-preview-gateway';
const PUBLIC_PORT = Number(process.env.SMARTYARD_COMPAT_PORT || 3082);
const PUBLIC_HOST = process.env.SMARTYARD_COMPAT_HOST || '127.0.0.1';
const EVENTS_GATEWAY_PORT = Number(process.env.SMARTYARD_EVENTS_GATEWAY_PORT || 3085);
const BACKEND_URL = String(process.env.SMARTYARD_BACKEND_URL || 'http://127.0.0.1:3000').replace(/\/+$/, '');
const INTERNAL_SECRET = String(process.env.INTERNAL_DVR_SECRET || '').trim();
const CACHE_DIR = String(process.env.PREVIEW_CACHE_DIR || '/var/cache/newdomofon-video/smartyard-preview');
const LIVE_CACHE_TTL_MS = Math.max(1000, Number(process.env.PREVIEW_CACHE_TTL_MS || 15000));
const ARCHIVE_CACHE_TTL_MS = Math.max(LIVE_CACHE_TTL_MS, Number(process.env.PREVIEW_ARCHIVE_CACHE_TTL_MS || 3600000));
const SEARCH_HOURS = Math.max(1, Math.min(24 * 31, Number(process.env.PREVIEW_SEARCH_HOURS || 72)));
const DURATION_SECONDS = Math.max(1, Math.min(10, Number(process.env.PREVIEW_DURATION_SECONDS || 3)));
const MAX_BYTES = Math.max(1024 * 1024, Number(process.env.PREVIEW_MAX_BYTES || 32 * 1024 * 1024));
const EXPORT_TIMEOUT_MS = Math.max(5000, Number(process.env.PREVIEW_EXPORT_TIMEOUT_MS || 60000));

// Keep the proven events/media stack on an internal port. This outer layer owns
// the public port and intercepts only SmartYard preview.mp4 requests.
process.env.SMARTYARD_COMPAT_PORT = String(EVENTS_GATEWAY_PORT);
require('./server-events-gateway.js');
process.env.SMARTYARD_COMPAT_PORT = String(PUBLIC_PORT);

const previewJobs = new Map();
let previewRequestCount = 0;

function cors(extra = {}) {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET,HEAD,OPTIONS',
    'access-control-allow-headers': '*',
    'access-control-expose-headers': 'Content-Length,Content-Range,Accept-Ranges,X-Newdomofon-Resolved-Stream,X-Newdomofon-SmartYard-Compat,X-Newdomofon-SmartYard-Route',
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

function previewTarget(mediaPath) {
  if (mediaPath === 'preview.mp4') return { isPreview: true, targetSec: 0 };
  const match = /^(\d+)-preview\.mp4$/i.exec(mediaPath);
  return match ? { isPreview: true, targetSec: Number(match[1]) } : { isPreview: false, targetSec: 0 };
}

function proxyEventsGateway(req, res) {
  const upstream = http.request({
    hostname: '127.0.0.1',
    port: EVENTS_GATEWAY_PORT,
    method: req.method,
    path: req.url,
    headers: {
      ...req.headers,
      host: `127.0.0.1:${EVENTS_GATEWAY_PORT}`
    }
  }, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
    upstreamRes.pipe(res);
  });

  upstream.on('error', (error) => {
    sendJson(res, 502, {
      error: 'SmartYard events/media gateway unavailable',
      message: String(error?.message || error)
    });
  });

  req.pipe(upstream);
}

async function resolveToken(token, stream) {
  if (!INTERNAL_SECRET || !token || !stream) return { status: 401, body: { error: 'Preview token is missing' } };

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
      body: JSON.stringify({ token, stream_name: stream, upstream_scope: 'camera' })
    });
    const text = await response.text();
    let body;
    try { body = JSON.parse(text); } catch { body = { error: text || 'Invalid resolver response' }; }
    if (!response.ok) return { status: response.status, body };
    if (!body?.ok || !body?.node?.url || !body?.upstream_token) {
      return { status: 502, body: { error: 'Preview resolver returned incomplete data' } };
    }
    return { status: 200, body };
  } catch (error) {
    return { status: 502, body: { error: 'Preview resolver unavailable', message: String(error?.message || error) } };
  } finally {
    clearTimeout(timer);
  }
}

async function nodeFetch(context, pathname, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(`${String(context.node.url).replace(/\/+$/, '')}${pathname}`, {
      signal: controller.signal,
      headers: {
        accept: '*/*',
        'user-agent': `newdomofon-smartyard-${VERSION}`
      }
    });
  } finally {
    clearTimeout(timer);
  }
}

function parseRanges(payload) {
  const source = Array.isArray(payload?.items) ? payload.items : (Array.isArray(payload) ? payload : []);
  return source.map((item) => {
    const startMs = Date.parse(String(item.start || ''));
    const endMs = Date.parse(String(item.end || ''));
    return { startMs, endMs };
  }).filter((item) => Number.isFinite(item.startMs) && Number.isFinite(item.endMs) && item.endMs > item.startMs);
}

function chooseRange(ranges, targetMs) {
  if (!ranges.length) return null;
  if (!targetMs) return ranges.slice().sort((a, b) => b.endMs - a.endMs)[0];

  const containing = ranges.find((item) => item.startMs <= targetMs && item.endMs >= targetMs);
  if (containing) return containing;

  return ranges.slice().sort((a, b) => {
    const distanceA = targetMs < a.startMs ? a.startMs - targetMs : targetMs - a.endMs;
    const distanceB = targetMs < b.startMs ? b.startMs - targetMs : targetMs - b.endMs;
    return distanceA - distanceB;
  })[0];
}

async function loadRange(context, stream, targetSec) {
  const now = Date.now();
  const targetMs = targetSec > 0 ? targetSec * 1000 : 0;
  const searchStart = targetMs ? targetMs - 3600_000 : now - SEARCH_HOURS * 3600_000;
  const searchEnd = targetMs ? targetMs + 3600_000 : now;
  const query = new URLSearchParams({
    start: new Date(searchStart).toISOString(),
    end: new Date(searchEnd).toISOString(),
    token: context.upstream_token
  });
  const response = await nodeFetch(
    context,
    `/cameras/${encodeURIComponent(stream)}/archive/ranges?${query.toString()}`,
    15000
  );
  if (!response.ok) return null;
  let payload;
  try { payload = await response.json(); } catch { return null; }
  return chooseRange(parseRanges(payload), targetMs);
}

function previewWindow(range, targetSec) {
  const durationMs = DURATION_SECONDS * 1000;
  if (!range) {
    const endMs = Date.now() - 500;
    return { startMs: endMs - durationMs, endMs };
  }

  if (targetSec > 0) {
    const targetMs = Math.min(range.endMs, Math.max(range.startMs, targetSec * 1000));
    let startMs = Math.max(range.startMs, targetMs - 1000);
    let endMs = Math.min(range.endMs, startMs + durationMs);
    if (endMs - startMs < 1000) {
      endMs = range.endMs;
      startMs = Math.max(range.startMs, endMs - durationMs);
    }
    return { startMs, endMs };
  }

  const endMs = Math.min(range.endMs, Date.now() - 250);
  return { startMs: Math.max(range.startMs, endMs - durationMs), endMs };
}

function cacheFile(stream, targetSec) {
  const suffix = targetSec > 0 ? String(targetSec) : 'live';
  return path.join(CACHE_DIR, `${stream}-${suffix}.mp4`);
}

async function validCache(filePath, targetSec) {
  try {
    const stat = await fsp.stat(filePath);
    const ttl = targetSec > 0 ? ARCHIVE_CACHE_TTL_MS : LIVE_CACHE_TTL_MS;
    return stat.isFile() && stat.size > 256 && Date.now() - stat.mtimeMs <= ttl ? stat : null;
  } catch {
    return null;
  }
}

async function fetchPreview(context, stream, targetSec, outputFile) {
  const range = await loadRange(context, stream, targetSec);
  const window = previewWindow(range, targetSec);
  if (window.endMs - window.startMs < 500) throw new Error('No playable archive window for preview');

  const query = new URLSearchParams({
    start: new Date(window.startMs).toISOString(),
    end: new Date(window.endMs).toISOString(),
    token: context.upstream_token
  });
  const response = await nodeFetch(
    context,
    `/cameras/${encodeURIComponent(stream)}/export.mp4?${query.toString()}`,
    EXPORT_TIMEOUT_MS
  );
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 1000);
    throw new Error(`Node preview export failed (${response.status}): ${detail}`);
  }

  const contentLength = Number(response.headers.get('content-length') || 0);
  if (contentLength > MAX_BYTES) throw new Error('Node preview export exceeds size limit');
  const buffer = Buffer.from(await response.arrayBuffer());
  if (buffer.length < 256 || buffer.length > MAX_BYTES) throw new Error('Node preview export has invalid size');

  await fsp.mkdir(CACHE_DIR, { recursive: true });
  const tmp = `${outputFile}.tmp-${process.pid}-${Date.now()}`;
  await fsp.writeFile(tmp, buffer, { mode: 0o640 });
  await fsp.rename(tmp, outputFile);
  return fsp.stat(outputFile);
}

async function ensurePreview(context, stream, targetSec) {
  const filePath = cacheFile(stream, targetSec);
  const cached = await validCache(filePath, targetSec);
  if (cached) return { filePath, stat: cached, cached: true };

  const key = `${stream}:${targetSec}`;
  if (!previewJobs.has(key)) {
    previewJobs.set(key, fetchPreview(context, stream, targetSec, filePath).finally(() => previewJobs.delete(key)));
  }
  const stat = await previewJobs.get(key);
  return { filePath, stat, cached: false };
}

function sendPreviewFile(req, res, preview, stream) {
  const total = preview.stat.size;
  const range = String(req.headers.range || '');
  const baseHeaders = cors({
    'content-type': 'video/mp4',
    'cache-control': 'private, max-age=5',
    'accept-ranges': 'bytes',
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-smartyard-route': preview.cached ? 'node-preview-cache' : 'node-preview-export'
  });

  const match = /^bytes=(\d*)-(\d*)$/.exec(range);
  if (match) {
    const start = match[1] ? Number(match[1]) : 0;
    const end = match[2] ? Number(match[2]) : total - 1;
    if (Number.isFinite(start) && Number.isFinite(end) && start <= end && start < total) {
      const finalEnd = Math.min(end, total - 1);
      const length = finalEnd - start + 1;
      res.writeHead(206, {
        ...baseHeaders,
        'content-range': `bytes ${start}-${finalEnd}/${total}`,
        'content-length': String(length)
      });
      if (req.method === 'HEAD') return res.end();
      return fs.createReadStream(preview.filePath, { start, end: finalEnd }).pipe(res);
    }
  }

  res.writeHead(200, { ...baseHeaders, 'content-length': String(total) });
  if (req.method === 'HEAD') return res.end();
  return fs.createReadStream(preview.filePath).pipe(res);
}

async function pruneCacheOccasionally() {
  previewRequestCount += 1;
  if (previewRequestCount % 100 !== 0) return;
  const cutoff = Date.now() - 24 * 3600_000;
  let entries;
  try { entries = await fsp.readdir(CACHE_DIR, { withFileTypes: true }); } catch { return; }
  await Promise.all(entries.map(async (entry) => {
    if (!entry.isFile() || !entry.name.endsWith('.mp4')) return;
    const filePath = path.join(CACHE_DIR, entry.name);
    try {
      const stat = await fsp.stat(filePath);
      if (stat.mtimeMs < cutoff) await fsp.unlink(filePath);
    } catch { /* best effort cache cleanup */ }
  }));
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
        service: 'newdomofon-smartyard-preview-gateway',
        version: VERSION,
        events_gateway_port: EVENTS_GATEWAY_PORT,
        preview_cache_dir: CACHE_DIR,
        internal_secret_configured: Boolean(INTERNAL_SECRET)
      });
    }

    const { stream, mediaPath } = parseRequestPath(reqUrl);
    const preview = previewTarget(mediaPath);
    if (!safeStream(stream) || !preview.isPreview) return proxyEventsGateway(req, res);
    if (!['GET', 'HEAD'].includes(String(req.method || 'GET').toUpperCase())) {
      return sendJson(res, 405, { error: 'Method not allowed' }, { allow: 'GET,HEAD,OPTIONS' });
    }

    const token = extractToken(req, reqUrl);
    const resolved = await resolveToken(token, stream);
    if (resolved.status !== 200) return sendJson(res, resolved.status, resolved.body);

    const output = await ensurePreview(resolved.body, stream, preview.targetSec);
    void pruneCacheOccasionally();
    return sendPreviewFile(req, res, output, stream);
  } catch (error) {
    console.error('[smartyard-preview] request failed', error);
    return sendJson(res, 502, {
      error: 'SmartYard camera preview is unavailable',
      message: String(error?.message || error)
    }, { 'x-newdomofon-smartyard-route': 'node-preview-error' });
  }
}

const server = http.createServer((req, res) => {
  void handle(req, res);
});

server.listen(PUBLIC_PORT, PUBLIC_HOST, () => {
  console.log('[smartyard-preview] listening', {
    host: PUBLIC_HOST,
    port: PUBLIC_PORT,
    events_gateway_port: EVENTS_GATEWAY_PORT,
    version: VERSION
  });
});

process.on('SIGTERM', () => server.close());
process.on('SIGINT', () => server.close());

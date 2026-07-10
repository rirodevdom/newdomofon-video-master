'use strict';

const http = require('node:http');
const { Readable } = require('node:stream');
const { URL } = require('node:url');

const VERSION = 'v301-node-aware-smartyard-gateway';
const PUBLIC_PORT = Number(process.env.SMARTYARD_COMPAT_PORT || 3082);
const PUBLIC_HOST = process.env.SMARTYARD_COMPAT_HOST || '127.0.0.1';
const LEGACY_PORT = Number(process.env.SMARTYARD_LEGACY_PORT || 3083);
const BACKEND_URL = String(process.env.SMARTYARD_BACKEND_URL || 'http://127.0.0.1:3000').replace(/\/+$/, '');
const INTERNAL_SECRET = String(process.env.INTERNAL_DVR_SECRET || '').trim();
const DEFAULT_RANGE_DAYS = Math.max(1, Math.min(31, Number(process.env.SMARTYARD_DEFAULT_RANGE_DAYS || 30)));

// Keep the proven legacy implementation on an internal fallback port. The
// public gateway below handles node-owned media and delegates unsupported old
// compatibility paths to the legacy service.
process.env.SMARTYARD_COMPAT_PORT = String(LEGACY_PORT);
require('./server.js');
process.env.SMARTYARD_COMPAT_PORT = String(PUBLIC_PORT);

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
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text),
    ...extra
  }));
  res.end(text);
}

function sendText(res, status, body, contentType, extra = {}) {
  const text = String(body || '');
  res.writeHead(status, cors({
    'content-type': contentType,
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(text),
    ...extra
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

function encodePath(value) {
  return String(value || '')
    .split('/')
    .filter(Boolean)
    .map(encodeURIComponent)
    .join('/');
}

async function resolveSmartYardToken(token, stream) {
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
      body: JSON.stringify({ token, stream_name: stream })
    });

    if (!response.ok) return null;
    const payload = await response.json();
    if (!payload?.ok || !payload?.node?.url || !payload?.upstream_token) return null;
    return payload;
  } catch (error) {
    console.warn('[smartyard-node-aware] resolver failed', {
      stream,
      error: String(error?.message || error)
    });
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function proxyLegacy(req, res) {
  const upstream = http.request({
    hostname: '127.0.0.1',
    port: LEGACY_PORT,
    method: req.method,
    path: req.url,
    headers: {
      ...req.headers,
      host: `127.0.0.1:${LEGACY_PORT}`
    }
  }, (legacyRes) => {
    const headers = { ...legacyRes.headers, ...cors({ 'x-newdomofon-smartyard-route': 'legacy' }) };
    res.writeHead(legacyRes.statusCode || 502, headers);
    legacyRes.pipe(res);
  });

  upstream.on('error', (error) => {
    sendJson(res, 502, {
      error: 'Legacy SmartYard fallback unavailable',
      message: String(error?.message || error)
    });
  });

  req.pipe(upstream);
}

async function nodeFetch(context, pathname, req, timeoutMs = 15000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const headers = {
    accept: String(req.headers.accept || '*/*'),
    'user-agent': `newdomofon-smartyard-${VERSION}`
  };
  if (req.headers.range) headers.range = String(req.headers.range);

  try {
    return await fetch(`${String(context.node.url).replace(/\/+$/, '')}${pathname}`, {
      method: req.method === 'HEAD' ? 'HEAD' : 'GET',
      signal: controller.signal,
      headers
    });
  } finally {
    clearTimeout(timer);
  }
}

function externalPlaylistUri(uri, stream, externalToken) {
  const raw = String(uri || '').trim();
  if (!raw || raw.startsWith('#')) return raw;

  let pathname = raw;
  try {
    pathname = decodeURIComponent(new URL(raw, 'http://node.local').pathname || raw);
  } catch {
    pathname = raw.split('?')[0].split('#')[0];
  }

  const prefixes = [
    `/files/${stream}/`,
    `/cameras/${stream}/files/`,
    `/cameras/${stream}/`,
    `/${stream}/`
  ];

  for (const prefix of prefixes) {
    if (pathname.startsWith(prefix)) {
      pathname = pathname.slice(prefix.length);
      break;
    }
  }

  pathname = pathname.replace(/^\/+/, '');
  const separator = pathname.includes('?') ? '&' : '?';
  return `${pathname}${separator}token=${encodeURIComponent(externalToken)}`;
}

function rewritePlaylist(body, stream, externalToken) {
  return String(body || '')
    .split(/\r?\n/)
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed) return line;
      if (trimmed.startsWith('#')) {
        if (/^#EXT-X-(MAP|KEY):/i.test(trimmed) && /URI="[^"]+"/i.test(line)) {
          return line.replace(/URI="([^"]+)"/i, (_match, uri) => `URI="${externalPlaylistUri(uri, stream, externalToken)}"`);
        }
        return line;
      }
      return externalPlaylistUri(trimmed, stream, externalToken);
    })
    .join('\n') + '\n';
}

function parseArchiveWindow(mediaPath, reqUrl) {
  const queryStart = reqUrl.searchParams.get('start');
  const queryEnd = reqUrl.searchParams.get('end');
  if (queryStart && queryEnd) {
    const startMs = Date.parse(queryStart);
    const endMs = Date.parse(queryEnd);
    if (Number.isFinite(startMs) && Number.isFinite(endMs) && endMs > startMs) return { startMs, endMs };
  }

  let match = /^(?:archive|index|video|mono)-(\d+)-(now|\d+)\.(?:m3u8|mp4)$/i.exec(mediaPath);
  if (match) {
    const from = Number(match[1]);
    const duration = match[2] === 'now' ? Math.floor(Date.now() / 1000) - from : Number(match[2]);
    if (Number.isFinite(from) && Number.isFinite(duration) && duration > 0) {
      return { startMs: from * 1000, endMs: (from + duration) * 1000 };
    }
  }

  match = /^timeshift_abs-(\d+)\.m3u8$/i.exec(mediaPath);
  if (match) return { startMs: Number(match[1]) * 1000, endMs: Date.now() };

  match = /^timeshift_rel-(\d+)\.m3u8$/i.exec(mediaPath);
  if (match) return { startMs: Date.now() - Number(match[1]) * 1000, endMs: Date.now() };

  return { startMs: Date.now() - 3600_000, endMs: Date.now() };
}

function queryToken(token) {
  return `token=${encodeURIComponent(token)}`;
}

async function sendNodeResponse(req, res, response, stream, externalToken, route) {
  const contentType = response.headers.get('content-type') || 'application/octet-stream';
  const headers = cors({
    'content-type': contentType,
    'cache-control': 'no-store',
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-smartyard-route': route
  });

  for (const name of ['content-length', 'content-range', 'accept-ranges', 'content-disposition', 'last-modified']) {
    const value = response.headers.get(name);
    if (value) headers[name] = value;
  }

  if (/mpegurl|m3u8/i.test(contentType)) {
    const body = await response.text();
    const rewritten = response.ok ? rewritePlaylist(body, stream, externalToken) : body;
    return sendText(res, response.status, rewritten, contentType, headers);
  }

  res.writeHead(response.status, headers);
  if (req.method === 'HEAD' || !response.body) return res.end();
  Readable.fromWeb(response.body).pipe(res);
}

async function handleRecordingStatus(req, res, context, stream, reqUrl) {
  const fromRaw = Number(reqUrl.searchParams.get('from') || 0);
  const startMs = Number.isFinite(fromRaw) && fromRaw > 0
    ? fromRaw * 1000
    : Date.now() - DEFAULT_RANGE_DAYS * 24 * 3600_000;
  const endMs = Date.now();
  const path = `/cameras/${encodeURIComponent(stream)}/archive/ranges?start=${encodeURIComponent(new Date(startMs).toISOString())}&end=${encodeURIComponent(new Date(endMs).toISOString())}&${queryToken(context.upstream_token)}`;
  const response = await nodeFetch(context, path, req);
  const raw = await response.text();

  if (!response.ok) {
    return sendText(res, response.status, raw, response.headers.get('content-type') || 'application/json; charset=utf-8', {
      'x-newdomofon-resolved-stream': stream,
      'x-newdomofon-smartyard-route': 'node-ranges'
    });
  }

  let payload;
  try { payload = JSON.parse(raw); } catch { payload = { items: [] }; }
  const ranges = Array.isArray(payload?.items) ? payload.items.map((item) => {
    const from = Math.floor(Date.parse(item.start) / 1000);
    const to = Math.floor(Date.parse(item.end) / 1000);
    return { from, duration: Math.max(0, to - from) };
  }).filter((item) => Number.isFinite(item.from) && item.duration > 0) : [];

  return sendJson(res, 200, [{ stream, ranges }], {
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-ranges-count': String(ranges.length),
    'x-newdomofon-smartyard-route': 'node-ranges'
  });
}

async function handleNodeRequest(req, res, context, stream, mediaPath, reqUrl, externalToken) {
  if (mediaPath === 'media_info.json') {
    sendJson(res, 200, {
      stream,
      name: stream,
      tracks: [
        { content: 'video', codec: 'h264' },
        { content: 'audio', codec: 'aac', optional: true }
      ]
    }, {
      'x-newdomofon-resolved-stream': stream,
      'x-newdomofon-smartyard-route': 'node-static-info'
    });
    return true;
  }

  if (mediaPath === 'recording_status.json') {
    await handleRecordingStatus(req, res, context, stream, reqUrl);
    return true;
  }

  if (mediaPath === 'live.m3u8' || mediaPath === 'index.m3u8' || mediaPath === 'video.m3u8') {
    const path = `/cameras/${encodeURIComponent(stream)}/live.m3u8?${queryToken(context.upstream_token)}`;
    const response = await nodeFetch(context, path, req, 10000);
    await sendNodeResponse(req, res, response, stream, externalToken, 'node-live');
    return true;
  }

  const archivePlaylist = mediaPath === 'archive.m3u8' ||
    /^(?:archive|index|video|mono)-\d+-(?:now|\d+)\.m3u8$/i.test(mediaPath) ||
    /^timeshift_(?:abs|rel)-\d+\.m3u8$/i.test(mediaPath);

  if (archivePlaylist) {
    const range = parseArchiveWindow(mediaPath, reqUrl);
    const path = `/cameras/${encodeURIComponent(stream)}/archive.m3u8?start=${encodeURIComponent(new Date(range.startMs).toISOString())}&end=${encodeURIComponent(new Date(range.endMs).toISOString())}&${queryToken(context.upstream_token)}`;
    const response = await nodeFetch(context, path, req, 20000);
    await sendNodeResponse(req, res, response, stream, externalToken, 'node-archive');
    return true;
  }

  const exportMp4 = mediaPath === 'export.mp4' || /^(?:archive|index|video|mono)-\d+-(?:now|\d+)\.mp4$/i.test(mediaPath);
  if (exportMp4) {
    const range = parseArchiveWindow(mediaPath, reqUrl);
    const path = `/cameras/${encodeURIComponent(stream)}/export.mp4?start=${encodeURIComponent(new Date(range.startMs).toISOString())}&end=${encodeURIComponent(new Date(range.endMs).toISOString())}&${queryToken(context.upstream_token)}`;
    const response = await nodeFetch(context, path, req, 120000);
    await sendNodeResponse(req, res, response, stream, externalToken, 'node-export');
    return true;
  }

  if (mediaPath === 'preview.mp4' || /^\d+-preview\.mp4$/i.test(mediaPath)) return false;
  if (!mediaPath || mediaPath.includes('..') || mediaPath.includes('\\')) return false;

  const path = `/files/${encodeURIComponent(stream)}/${encodePath(mediaPath)}?${queryToken(context.upstream_token)}`;
  const response = await nodeFetch(context, path, req, 30000);
  await sendNodeResponse(req, res, response, stream, externalToken, 'node-file');
  return true;
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
        service: 'newdomofon-smartyard-node-aware',
        version: VERSION,
        backend: BACKEND_URL,
        legacy_port: LEGACY_PORT,
        internal_secret_configured: Boolean(INTERNAL_SECRET)
      });
    }

    const { stream, mediaPath } = parseRequestPath(reqUrl);
    if (!safeStream(stream)) return proxyLegacy(req, res);

    const externalToken = extractToken(req, reqUrl);
    const context = await resolveSmartYardToken(externalToken, stream);
    if (!context) return proxyLegacy(req, res);

    const handled = await handleNodeRequest(req, res, context, stream, mediaPath, reqUrl, externalToken);
    if (!handled) return proxyLegacy(req, res);
  } catch (error) {
    console.error('[smartyard-node-aware] request failed', error);
    sendJson(res, 502, {
      error: 'SmartYard node-aware gateway error',
      message: String(error?.message || error)
    });
  }
}

const server = http.createServer((req, res) => {
  void handle(req, res);
});

server.listen(PUBLIC_PORT, PUBLIC_HOST, () => {
  console.log('[smartyard-node-aware] listening', {
    host: PUBLIC_HOST,
    port: PUBLIC_PORT,
    legacy_port: LEGACY_PORT,
    backend: BACKEND_URL,
    version: VERSION
  });
});

process.on('SIGTERM', () => server.close());
process.on('SIGINT', () => server.close());

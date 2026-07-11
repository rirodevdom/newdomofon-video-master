'use strict';

const http = require('node:http');
const { Readable } = require('node:stream');
const { URL } = require('node:url');

const VERSION = 'v304-admin-media-formats';
const PUBLIC_PORT = Number(process.env.SMARTYARD_COMPAT_PORT || 3082);
const PUBLIC_HOST = process.env.SMARTYARD_COMPAT_HOST || '127.0.0.1';
const INNER_PREVIEW_PORT = Number(process.env.SMARTYARD_PREVIEW_GATEWAY_PORT || 3086);
const BACKEND_URL = String(process.env.SMARTYARD_BACKEND_URL || 'http://127.0.0.1:3000').replace(/\/+$/, '');
const INTERNAL_SECRET = String(process.env.INTERNAL_DVR_SECRET || '').trim();

// Keep the established preview → events → media → legacy chain unchanged.
// This outer layer owns 3082 and intercepts only the additional live formats.
process.env.SMARTYARD_COMPAT_PORT = String(INNER_PREVIEW_PORT);
require('./server-preview-gateway.js');
process.env.SMARTYARD_COMPAT_PORT = String(PUBLIC_PORT);

function cors(extra = {}) {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET,HEAD,OPTIONS',
    'access-control-allow-headers': '*',
    'access-control-expose-headers': 'Content-Length,Content-Range,Accept-Ranges,Cache-Control,Content-Type,X-Newdomofon-Resolved-Stream,X-Newdomofon-SmartYard-Compat,X-Newdomofon-SmartYard-Route',
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

function sendText(res, status, body, contentType, extra = {}) {
  const text = String(body || '');
  res.writeHead(status, cors({
    ...extra,
    'content-type': contentType,
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
  return /^[A-Za-z0-9_.-]+$/.test(String(stream || ''));
}

function isFormatPath(mediaPath) {
  return mediaPath === 'live.ts' ||
    mediaPath === 'live.mpd' ||
    mediaPath === 'snapshot.jpg' ||
    mediaPath === 'snapshot.jpeg' ||
    /^dash\/[A-Za-z0-9_.%$-]+\.m4s$/i.test(mediaPath);
}

function proxyInner(req, res) {
  const upstream = http.request({
    hostname: '127.0.0.1',
    port: INNER_PREVIEW_PORT,
    method: req.method,
    path: req.url,
    headers: {
      ...req.headers,
      host: `127.0.0.1:${INNER_PREVIEW_PORT}`
    }
  }, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
    upstreamRes.pipe(res);
  });

  upstream.on('error', (error) => {
    sendJson(res, 502, {
      error: 'SmartYard preview/media gateway unavailable',
      message: String(error?.message || error)
    });
  });

  req.pipe(upstream);
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
      body: JSON.stringify({
        token,
        stream_name: stream,
        upstream_scope: 'camera'
      })
    });

    const text = await response.text();
    let payload;
    try { payload = text ? JSON.parse(text) : {}; } catch { payload = { error: text }; }
    if (!response.ok) return { error_status: response.status, error_body: payload };
    if (!payload?.ok || !payload?.node?.url || !payload?.upstream_token) return null;
    return payload;
  } catch (error) {
    console.warn('[smartyard-formats] resolver failed', {
      stream,
      error: String(error?.message || error)
    });
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function nodePath(mediaPath, stream, upstreamToken) {
  const token = encodeURIComponent(upstreamToken);
  const encodedStream = encodeURIComponent(stream);

  if (mediaPath === 'live.ts') return `/cameras/${encodedStream}/live.ts?token=${token}`;
  if (mediaPath === 'live.mpd') return `/cameras/${encodedStream}/live.mpd?token=${token}`;
  if (mediaPath === 'snapshot.jpg' || mediaPath === 'snapshot.jpeg') {
    return `/cameras/${encodedStream}/snapshot.jpg?token=${token}`;
  }
  if (/^dash\/[A-Za-z0-9_.%$-]+\.m4s$/i.test(mediaPath)) {
    const filename = mediaPath.slice('dash/'.length);
    return `/cameras/${encodedStream}/dash/${encodeURIComponent(filename)}?token=${token}`;
  }
  return null;
}

async function fetchNode(context, pathname, req) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15_000);
  const headers = {
    accept: String(req.headers.accept || '*/*'),
    'user-agent': `newdomofon-smartyard-${VERSION}`
  };
  if (req.headers.range) headers.range = String(req.headers.range);

  try {
    const response = await fetch(`${String(context.node.url).replace(/\/+$/, '')}${pathname}`, {
      method: req.method === 'HEAD' ? 'HEAD' : 'GET',
      signal: controller.signal,
      headers
    });
    clearTimeout(timer);
    return { response, controller };
  } catch (error) {
    clearTimeout(timer);
    throw error;
  }
}

function rewriteDashManifest(body, externalToken) {
  return String(body || '').replace(/\b(initialization|media)="([^"]+)"/g, (_match, key, uri) => {
    const clean = String(uri || '')
      .replace(/&amp;/g, '&')
      .split('?')[0]
      .replace(/^\/+/, '')
      .replace(/^dash\//, '');
    return `${key}="dash/${clean}?token=${encodeURIComponent(externalToken)}"`;
  });
}

async function sendNodeResponse(req, res, response, controller, stream, mediaPath, externalToken) {
  const contentType = response.headers.get('content-type') || 'application/octet-stream';
  const headers = cors({
    'content-type': contentType,
    'cache-control': response.headers.get('cache-control') || 'no-store',
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-smartyard-route': mediaPath === 'live.ts'
      ? 'node-live-mpegts'
      : mediaPath === 'live.mpd'
        ? 'node-live-dash'
        : mediaPath.startsWith('dash/')
          ? 'node-dash-segment'
          : 'node-snapshot-jpeg'
  });

  for (const name of ['content-length', 'content-range', 'accept-ranges', 'last-modified']) {
    const value = response.headers.get(name);
    if (value) headers[name] = value;
  }

  if (mediaPath === 'live.mpd') {
    const body = await response.text();
    controller.abort();
    const rewritten = response.ok ? rewriteDashManifest(body, externalToken) : body;
    return sendText(res, response.status, rewritten, contentType, headers);
  }

  res.writeHead(response.status, headers);
  if (req.method === 'HEAD' || !response.body) {
    controller.abort();
    return res.end();
  }

  const readable = Readable.fromWeb(response.body);
  const close = () => {
    controller.abort();
    readable.destroy();
  };
  req.once('close', close);
  res.once('close', close);
  readable.pipe(res);
}

async function handleFormat(req, res, reqUrl, stream, mediaPath) {
  const externalToken = extractToken(req, reqUrl);
  if (!externalToken) return sendJson(res, 401, { error: 'Missing media token' });

  const context = await resolveSmartYardToken(externalToken, stream);
  if (!context) return sendJson(res, 502, { error: 'SmartYard media resolver unavailable' });
  if (context.error_status) return sendJson(res, context.error_status, context.error_body || { error: 'Media token rejected' });

  const pathname = nodePath(mediaPath, stream, context.upstream_token);
  if (!pathname) return sendJson(res, 404, { error: 'Unsupported media format' });

  const { response, controller } = await fetchNode(context, pathname, req);
  await sendNodeResponse(req, res, response, controller, stream, mediaPath, externalToken);
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
        service: 'newdomofon-smartyard-formats-gateway',
        version: VERSION,
        preview_gateway_port: INNER_PREVIEW_PORT,
        backend: BACKEND_URL,
        internal_secret_configured: Boolean(INTERNAL_SECRET),
        formats: ['hls', 'mpegts', 'dash', 'jpeg']
      });
    }

    const { stream, mediaPath } = parseRequestPath(reqUrl);
    if (!safeStream(stream) || !isFormatPath(mediaPath)) return proxyInner(req, res);

    await handleFormat(req, res, reqUrl, stream, mediaPath);
  } catch (error) {
    console.error('[smartyard-formats] request failed', error);
    sendJson(res, 502, {
      error: 'SmartYard format gateway error',
      message: String(error?.message || error)
    });
  }
}

const server = http.createServer((req, res) => {
  void handle(req, res);
});

server.listen(PUBLIC_PORT, PUBLIC_HOST, () => {
  console.log('[smartyard-formats] listening', {
    host: PUBLIC_HOST,
    port: PUBLIC_PORT,
    preview_gateway_port: INNER_PREVIEW_PORT,
    backend: BACKEND_URL,
    version: VERSION
  });
});

process.on('SIGTERM', () => server.close());
process.on('SIGINT', () => server.close());

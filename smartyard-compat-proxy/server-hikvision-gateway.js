'use strict';

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { Readable } = require('node:stream');
const { URL } = require('node:url');

const VERSION = 'v305-hikvision-smartyard-gateway';
const PUBLIC_PORT = Number(process.env.SMARTYARD_COMPAT_PORT || 3082);
const PUBLIC_HOST = process.env.SMARTYARD_COMPAT_HOST || '127.0.0.1';
const INNER_PORT = Number(process.env.SMARTYARD_FORMATS_GATEWAY_PORT || 3087);
const BACKEND_URL = String(process.env.SMARTYARD_BACKEND_URL || 'http://127.0.0.1:3000').replace(/\/+$/, '');
const INTERNAL_SECRET = String(process.env.INTERNAL_DVR_SECRET || '').trim();
const DEFAULT_RANGE_DAYS = Math.max(1, Math.min(31, Number(process.env.SMARTYARD_DEFAULT_RANGE_DAYS || 30)));
const RANGE_CACHE_TTL_MS = Math.max(1000, Number(process.env.SMARTYARD_HIK_RANGE_CACHE_TTL_MS || 30000));
const RANGE_CACHE_STALE_MS = Math.max(RANGE_CACHE_TTL_MS, Number(process.env.SMARTYARD_HIK_RANGE_CACHE_STALE_MS || 300000));
const RANGE_CHUNK_CONCURRENCY = Math.max(1, Math.min(4, Number(process.env.SMARTYARD_HIK_RANGE_CONCURRENCY || 1)));
const RANGE_MERGE_GAP_SECONDS = Math.max(0, Number(process.env.SMARTYARD_RANGE_MERGE_GAP_SECONDS || 15));
const EVENT_MAX_DAYS = Math.max(1, Math.min(31, Number(process.env.SMARTYARD_EVENT_MAX_DAYS || 31)));
const EVENT_DEFAULT_HOURS = Math.max(1, Math.min(24 * EVENT_MAX_DAYS, Number(process.env.SMARTYARD_EVENT_DEFAULT_HOURS || 24)));
const MOTION_DEDUP_MS = Math.max(100, Math.min(10000, Number(process.env.SMARTYARD_EVENT_MOTION_DEDUP_MS || 2000)));
const CACHE_DIR = String(process.env.PREVIEW_CACHE_DIR || '/var/cache/newdomofon-video/smartyard-preview');
const LIVE_PREVIEW_TTL_MS = Math.max(1000, Number(process.env.PREVIEW_CACHE_TTL_MS || 15000));
const ARCHIVE_PREVIEW_TTL_MS = Math.max(LIVE_PREVIEW_TTL_MS, Number(process.env.PREVIEW_ARCHIVE_CACHE_TTL_MS || 3600000));
const PREVIEW_TIMEOUT_MS = Math.max(5000, Number(process.env.PREVIEW_EXPORT_TIMEOUT_MS || 60000));
const PREVIEW_MAX_BYTES = Math.max(1024 * 1024, Number(process.env.PREVIEW_MAX_BYTES || 32 * 1024 * 1024));
const FFMPEG = String(process.env.SMARTYARD_PREVIEW_FFMPEG || process.env.FFMPEG_PATH || '/usr/bin/ffmpeg');

// Keep the established generic SmartYard chain completely intact on an inner
// port. This outer adapter intercepts only tokens explicitly marked as a native
// Hikvision channel and proxies every other request byte-for-byte to the old
// formats -> preview -> events -> node-aware -> legacy chain.
process.env.SMARTYARD_COMPAT_PORT = String(INNER_PORT);
require('./server-formats-gateway.js');
process.env.SMARTYARD_COMPAT_PORT = String(PUBLIC_PORT);

const rangeState = { cache: new Map(), jobs: new Map() };
const previewJobs = new Map();

function cors(extra = {}) {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET,HEAD,OPTIONS',
    'access-control-allow-headers': '*',
    'access-control-expose-headers': 'Content-Length,Content-Range,Accept-Ranges,Cache-Control,Content-Type,X-Newdomofon-Resolved-Stream,X-Newdomofon-SmartYard-Compat,X-Newdomofon-SmartYard-Route,X-Newdomofon-Events-Count',
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

function proxyInner(req, res) {
  const upstream = http.request({
    hostname: '127.0.0.1',
    port: INNER_PORT,
    method: req.method,
    path: req.url,
    headers: {
      ...req.headers,
      host: `127.0.0.1:${INNER_PORT}`
    }
  }, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
    upstreamRes.pipe(res);
  });

  upstream.on('error', (error) => {
    sendJson(res, 502, {
      error: 'SmartYard generic compatibility gateway unavailable',
      message: String(error?.message || error)
    });
  });
  req.pipe(upstream);
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

function tokenPayload(rawToken) {
  const [body, signature, extra] = String(rawToken || '').split('.');
  if (!body || !signature || extra) return null;
  try {
    const payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
    return payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : null;
  } catch {
    return null;
  }
}

function isHikvisionToken(rawToken) {
  return String(tokenPayload(rawToken)?.target || '') === 'hikvision';
}

function parseRequestPath(reqUrl) {
  const pathname = decodeURIComponent(reqUrl.pathname || '/');
  let rest = pathname.startsWith('/') ? pathname.slice(1) : pathname;
  for (const prefix of ['api/media/', 'api/dvr-archive/', 'dvr-archive/', 'cameras/']) {
    if (rest.startsWith(prefix)) rest = rest.slice(prefix.length);
  }
  const parts = rest.split('/').filter(Boolean);
  return { stream: parts.shift() || '', mediaPath: parts.join('/') };
}

function safeStream(stream) {
  return /^[A-Za-z0-9_-]+$/.test(String(stream || ''));
}

async function resolveHikvision(token, stream, upstreamScope) {
  if (!INTERNAL_SECRET || !token || !stream) {
    return { error_status: 401, error_body: { error: 'Missing Hikvision SmartYard credentials' } };
  }
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
      body: JSON.stringify({ token, stream_name: stream, upstream_scope: upstreamScope })
    });
    const raw = await response.text();
    let body;
    try { body = raw ? JSON.parse(raw) : {}; } catch { body = { error: raw || `Resolver HTTP ${response.status}` }; }
    if (!response.ok) return { error_status: response.status, error_body: body };
    if (!body?.ok || body?.node?.kind !== 'hikvision' || !body?.node?.url || !body?.target?.channel_id || !body?.upstream_token) {
      return { error_status: 502, error_body: { error: 'Invalid Hikvision SmartYard resolver response' } };
    }
    return body;
  } catch (error) {
    return { error_status: 502, error_body: { error: 'Hikvision SmartYard resolver unavailable', message: String(error?.message || error) } };
  } finally {
    clearTimeout(timer);
  }
}

function queryToken(token) {
  return `token=${encodeURIComponent(token)}`;
}

function withToken(pathname, token) {
  const url = new URL(pathname, 'http://hikvision.local');
  url.searchParams.set('token', token);
  return `${url.pathname}${url.search}`;
}

async function nodeRequest(context, pathname, req, timeoutMs = 30000, init = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const headers = {
    accept: String(req.headers.accept || '*/*'),
    'user-agent': `newdomofon-smartyard-${VERSION}`,
    ...(init.headers || {})
  };
  if (req.headers.range) headers.range = String(req.headers.range);
  try {
    return await fetch(`${String(context.node.url).replace(/\/+$/, '')}${pathname}`, {
      ...init,
      method: init.method || (req.method === 'HEAD' ? 'HEAD' : 'GET'),
      signal: controller.signal,
      headers
    });
  } finally {
    clearTimeout(timer);
  }
}

function opaqueUpstreamPath(rawPath) {
  return Buffer.from(String(rawPath || ''), 'utf8').toString('base64url');
}

function decodeOpaqueUpstreamPath(raw) {
  try {
    const value = Buffer.from(String(raw || ''), 'base64url').toString('utf8');
    const url = new URL(value, 'http://hikvision.local');
    if (!url.pathname.startsWith('/api/v1/media/channels/')) return null;
    url.searchParams.delete('token');
    return `${url.pathname}${url.search}`;
  } catch {
    return null;
  }
}

function externalHikvisionUri(uri, upstreamPlaylistPath, externalToken) {
  const raw = String(uri || '').trim();
  if (!raw || raw.startsWith('#')) return raw;
  try {
    const base = new URL(upstreamPlaylistPath, 'http://hikvision.local');
    const resolved = new URL(raw, base);
    resolved.searchParams.delete('token');
    const opaque = opaqueUpstreamPath(`${resolved.pathname}${resolved.search}`);
    return `__hik/${opaque}?token=${encodeURIComponent(externalToken)}`;
  } catch {
    return raw;
  }
}

function rewriteHikvisionPlaylist(body, upstreamPlaylistPath, externalToken) {
  return String(body || '')
    .split(/\r?\n/)
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed) return line;
      if (trimmed.startsWith('#')) {
        if (/URI="[^"]+"/i.test(line)) {
          return line.replace(/URI="([^"]+)"/gi, (_match, uri) =>
            `URI="${externalHikvisionUri(uri, upstreamPlaylistPath, externalToken)}"`
          );
        }
        return line;
      }
      return externalHikvisionUri(trimmed, upstreamPlaylistPath, externalToken);
    })
    .join('\n') + '\n';
}

async function sendNodeResponse(req, res, response, stream, externalToken, route, upstreamPath) {
  const contentType = response.headers.get('content-type') || 'application/octet-stream';
  const isPlaylist = /mpegurl|m3u8/i.test(contentType) || /\.m3u8(?:\?|$)/i.test(upstreamPath);
  const headers = cors({
    'content-type': contentType,
    'cache-control': response.headers.get('cache-control') || 'no-store',
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-smartyard-route': route
  });
  if (!isPlaylist) {
    for (const name of ['content-length', 'content-range', 'accept-ranges', 'content-disposition', 'last-modified']) {
      const value = response.headers.get(name);
      if (value) headers[name] = value;
    }
  }

  if (isPlaylist) {
    const body = await response.text();
    const rewritten = response.ok ? rewriteHikvisionPlaylist(body, upstreamPath, externalToken) : body;
    return sendText(res, response.status, rewritten, contentType, headers);
  }

  res.writeHead(response.status, headers);
  if (req.method === 'HEAD' || !response.body) return res.end();
  const readable = Readable.fromWeb(response.body);
  const close = () => readable.destroy();
  req.once('close', close);
  res.once('close', close);
  readable.pipe(res);
}

function parseArchiveWindow(mediaPath, reqUrl) {
  const queryStart = reqUrl.searchParams.get('start');
  const queryEnd = reqUrl.searchParams.get('end');
  if (queryStart && queryEnd) {
    const startMs = Date.parse(queryStart);
    const endMs = Date.parse(queryEnd);
    if (Number.isFinite(startMs) && Number.isFinite(endMs) && endMs > startMs) return { startMs, endMs };
  }

  let match = /^(?:archive|index|video|mono)-(\d+)-(now|\d+)\.(?:fmp4\.)?(?:m3u8|mp4)$/i.exec(mediaPath);
  if (match) {
    const from = Number(match[1]);
    const duration = match[2] === 'now' ? Math.floor(Date.now() / 1000) - from : Number(match[2]);
    if (Number.isFinite(from) && Number.isFinite(duration) && duration > 0) {
      return { startMs: from * 1000, endMs: (from + duration) * 1000 };
    }
  }

  match = /^timeshift_abs-(\d+)(?:\.fmp4)?\.m3u8$/i.exec(mediaPath);
  if (match) return { startMs: Number(match[1]) * 1000, endMs: Date.now() };
  match = /^timeshift_rel-(\d+)(?:\.fmp4)?\.m3u8$/i.exec(mediaPath);
  if (match) return { startMs: Date.now() - Number(match[1]) * 1000, endMs: Date.now() };
  return { startMs: Date.now() - 3600000, endMs: Date.now() };
}

function mergeRanges(rawItems) {
  const normalized = rawItems.map((item) => {
    const from = Math.floor(Date.parse(String(item.start || '')) / 1000);
    const to = Math.floor(Date.parse(String(item.end || '')) / 1000);
    return { from, to };
  }).filter((item) => Number.isFinite(item.from) && Number.isFinite(item.to) && item.to > item.from)
    .sort((left, right) => left.from - right.from);

  const merged = [];
  for (const item of normalized) {
    const last = merged[merged.length - 1];
    if (!last || item.from > last.to + RANGE_MERGE_GAP_SECONDS) {
      merged.push({ from: item.from, to: item.to });
      continue;
    }
    if (item.to > last.to) last.to = item.to;
  }
  return merged.map((item) => ({ from: item.from, duration: item.to - item.from }));
}

async function loadArchiveRanges(context, req, startMs, endMs) {
  const channelId = String(context.target.channel_id);
  const chunks = [];
  const chunkMs = 24 * 3600000;
  for (let cursor = startMs; cursor < endMs; cursor += chunkMs) {
    chunks.push({ startMs: cursor, endMs: Math.min(endMs, cursor + chunkMs) });
  }

  const chunkItems = new Array(chunks.length);
  let nextIndex = 0;
  async function worker() {
    for (;;) {
      const index = nextIndex++;
      if (index >= chunks.length) return;
      const chunk = chunks[index];
      const params = new URLSearchParams({
        start: new Date(chunk.startMs).toISOString(),
        end: new Date(chunk.endMs).toISOString(),
        token: context.upstream_token
      });
      const pathname = `/api/v1/media/channels/${encodeURIComponent(channelId)}/archive/ranges?${params.toString()}`;
      const response = await nodeRequest(context, pathname, req, 60000);
      const raw = await response.text();
      if (!response.ok) {
        const error = new Error(raw || `Hikvision archive ranges HTTP ${response.status}`);
        error.status = response.status;
        throw error;
      }
      let payload;
      try { payload = raw ? JSON.parse(raw) : {}; } catch { payload = {}; }
      chunkItems[index] = Array.isArray(payload?.ranges) ? payload.ranges : (Array.isArray(payload?.items) ? payload.items : []);
    }
  }

  await Promise.all(Array.from(
    { length: Math.min(RANGE_CHUNK_CONCURRENCY, Math.max(1, chunks.length)) },
    () => worker()
  ));
  return { ranges: mergeRanges(chunkItems.flat()), rawCount: chunkItems.flat().length, chunkCount: chunks.length };
}

async function handleRecordingStatus(req, res, context, stream, reqUrl) {
  const fromRaw = Number(reqUrl.searchParams.get('from') || 0);
  const endMs = Date.now();
  const oldestAllowedMs = endMs - DEFAULT_RANGE_DAYS * 24 * 3600000;
  const requestedStartMs = Number.isFinite(fromRaw) && fromRaw > 0 ? fromRaw * 1000 : oldestAllowedMs;
  const startMs = Math.max(oldestAllowedMs, Math.min(requestedStartMs, endMs - 1000));
  const cacheKey = `${context.target.channel_id}|${Math.floor(startMs / 3600000)}|${DEFAULT_RANGE_DAYS}`;

  function startLoad() {
    const existing = rangeState.jobs.get(cacheKey);
    if (existing) return existing;
    const job = loadArchiveRanges(context, req, startMs, endMs)
      .then((loaded) => ({ ...loaded, createdAt: Date.now(), startMs, endMs }))
      .finally(() => {
        if (rangeState.jobs.get(cacheKey) === job) rangeState.jobs.delete(cacheKey);
      });
    rangeState.jobs.set(cacheKey, job);
    job.then((value) => rangeState.cache.set(cacheKey, value)).catch(() => undefined);
    return job;
  }

  function sendValue(value, cacheMode) {
    const requestedFrom = Math.floor(startMs / 1000);
    const ranges = value.ranges.filter((item) => item.from + item.duration >= requestedFrom);
    return sendJson(res, 200, [{ stream, ranges }], {
      'x-newdomofon-resolved-stream': stream,
      'x-newdomofon-ranges-count': String(ranges.length),
      'x-newdomofon-ranges-raw-count': String(value.rawCount),
      'x-newdomofon-ranges-chunks': String(value.chunkCount),
      'x-newdomofon-ranges-cache': cacheMode,
      'x-newdomofon-smartyard-route': 'hikvision-ranges'
    });
  }

  const cached = rangeState.cache.get(cacheKey);
  if (cached) {
    const age = Date.now() - cached.createdAt;
    if (age <= RANGE_CACHE_TTL_MS) return sendValue(cached, 'fresh');
    if (age <= RANGE_CACHE_STALE_MS) {
      void startLoad().catch((error) => console.warn('[smartyard-hikvision] background range refresh failed', String(error?.message || error)));
      return sendValue(cached, 'stale');
    }
  }

  try {
    return sendValue(await startLoad(), 'miss');
  } catch (error) {
    return sendJson(res, Number(error?.status || 502), { error: String(error?.message || error) }, {
      'x-newdomofon-smartyard-route': 'hikvision-ranges-error'
    });
  }
}

async function prepareArchivePlaylist(req, context, range) {
  const channelId = String(context.target.channel_id);
  const sessionPath = withToken(`/api/v1/media/channels/${encodeURIComponent(channelId)}/archive/session`, context.upstream_token);
  const response = await nodeRequest(context, sessionPath, req, 90000, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json' },
    body: JSON.stringify({ start: new Date(range.startMs).toISOString(), end: new Date(range.endMs).toISOString() })
  });
  const raw = await response.text();
  if (!response.ok) {
    const error = new Error(raw || `Hikvision archive session HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  let payload;
  try { payload = raw ? JSON.parse(raw) : {}; } catch { payload = {}; }
  const playlistUrl = String(payload?.playlist_url || '').trim();
  if (!playlistUrl) throw Object.assign(new Error('Hikvision node did not return archive playlist_url'), { status: 502 });
  return withToken(playlistUrl, context.upstream_token);
}

function parseMoment(raw) {
  const value = String(raw || '').trim();
  if (!value) return NaN;
  if (/^\d+(?:\.\d+)?$/.test(value)) {
    const numeric = Number(value);
    return numeric > 10000000000 ? numeric : numeric * 1000;
  }
  return Date.parse(value);
}

function eventWindow(reqUrl) {
  const endRaw = reqUrl.searchParams.get('end') || reqUrl.searchParams.get('to');
  const startRaw = reqUrl.searchParams.get('start') || reqUrl.searchParams.get('from');
  const endMs = endRaw ? parseMoment(endRaw) : Date.now();
  const startMs = startRaw ? parseMoment(startRaw) : endMs - EVENT_DEFAULT_HOURS * 3600000;
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || startMs >= endMs) return null;
  if (endMs - startMs > EVENT_MAX_DAYS * 24 * 3600000) return null;
  return { startMs, endMs };
}

function activeState(value) {
  return ['1', 'true', 'on', 'active', 'start', 'started'].includes(String(value || '').toLowerCase());
}

function normalizeEvents(items, stream, channelId, includeInactive) {
  const normalized = [];
  const lastByKey = new Map();
  for (const item of Array.isArray(items) ? items : []) {
    const timestamp = Date.parse(String(item.occurred_at || item.created_at || ''));
    if (!Number.isFinite(timestamp)) continue;
    const state = item.event_state === undefined || item.event_state === null ? null : String(item.event_state);
    if (!includeInactive && state !== null && !activeState(state)) continue;
    const type = String(item.event_type || item.type || 'unknown').toLowerCase();
    const key = type === 'motion' ? 'motion' : [type, item.source_name || '', item.topic || ''].join('|');
    const previous = lastByKey.get(key);
    if (previous !== undefined && timestamp - previous <= MOTION_DEDUP_MS) continue;
    lastByKey.set(key, timestamp);
    normalized.push({
      id: String(item.id || `${key}-${timestamp}`),
      camera_id: channelId,
      stream_name: stream,
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

async function handleEvents(req, res, context, stream, reqUrl, summary) {
  const range = eventWindow(reqUrl);
  if (!range) return sendJson(res, 400, { error: `Invalid event range. Max ${EVENT_MAX_DAYS} days.` });
  const channelId = String(context.target.channel_id);
  const params = new URLSearchParams({
    start: new Date(range.startMs).toISOString(),
    end: new Date(range.endMs).toISOString(),
    token: context.upstream_token
  });
  if (!summary) {
    const limit = Math.max(1, Math.min(5000, Number(reqUrl.searchParams.get('limit') || 1000)));
    params.set('limit', String(Math.trunc(limit)));
    const type = String(reqUrl.searchParams.get('type') || '').trim();
    if (type) params.set('type', type);
  }
  const suffix = summary ? 'summary' : '';
  const pathname = `/api/v1/events/channels/${encodeURIComponent(channelId)}${suffix ? `/${suffix}` : ''}?${params.toString()}`;
  const response = await nodeRequest(context, pathname, req, 30000);
  const raw = await response.text();
  if (!response.ok) return sendText(res, response.status, raw, response.headers.get('content-type') || 'application/json; charset=utf-8', {
    'x-newdomofon-smartyard-route': summary ? 'hikvision-events-summary' : 'hikvision-events'
  });
  let payload;
  try { payload = raw ? JSON.parse(raw) : {}; } catch { payload = {}; }

  if (summary) {
    const items = Array.isArray(payload?.items) ? payload.items : [];
    return sendJson(res, 200, {
      stream,
      start: new Date(range.startMs).toISOString(),
      end: new Date(range.endMs).toISOString(),
      items
    }, {
      'x-newdomofon-events-count': String(items.length),
      'x-newdomofon-smartyard-route': 'hikvision-events-summary'
    });
  }

  const includeInactive = ['1', 'true', 'yes', 'on'].includes(String(reqUrl.searchParams.get('include_inactive') || '').toLowerCase());
  const rawItems = Array.isArray(payload?.items) ? payload.items : [];
  const items = normalizeEvents(rawItems, stream, channelId, includeInactive);
  return sendJson(res, 200, {
    stream,
    start: new Date(range.startMs).toISOString(),
    end: new Date(range.endMs).toISOString(),
    count: items.length,
    raw_count: rawItems.length,
    items,
    events: items
  }, {
    'x-newdomofon-events-count': String(items.length),
    'x-newdomofon-smartyard-route': 'hikvision-events'
  });
}

function previewTarget(mediaPath) {
  if (mediaPath === 'preview.mp4') return { preview: true, targetSec: 0 };
  const match = /^(\d+)-preview\.mp4$/i.exec(mediaPath);
  return match ? { preview: true, targetSec: Number(match[1]) } : { preview: false, targetSec: 0 };
}

function safeCacheName(stream, targetSec) {
  return path.join(CACHE_DIR, `hik-${stream}-${targetSec > 0 ? targetSec : 'live'}.mp4`);
}

async function validPreviewCache(file, targetSec) {
  try {
    const stat = await fsp.stat(file);
    const ttl = targetSec > 0 ? ARCHIVE_PREVIEW_TTL_MS : LIVE_PREVIEW_TTL_MS;
    return stat.isFile() && stat.size > 128 && Date.now() - stat.mtimeMs <= ttl ? stat : null;
  } catch {
    return null;
  }
}

async function responseToFile(response, file) {
  if (!response.ok) throw Object.assign(new Error((await response.text()).slice(0, 1000) || `Hikvision preview HTTP ${response.status}`), { status: response.status });
  const buffer = Buffer.from(await response.arrayBuffer());
  if (buffer.length < 64 || buffer.length > PREVIEW_MAX_BYTES) throw new Error('Hikvision preview source has invalid size');
  await fsp.writeFile(file, buffer, { mode: 0o640 });
}

async function renderStill(source, output) {
  await new Promise((resolve, reject) => {
    const child = spawn(FFMPEG, [
      '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
      '-i', source,
      '-map', '0:v:0', '-an', '-frames:v', '1', '-r', '1',
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '28', '-pix_fmt', 'yuv420p',
      '-movflags', '+faststart', output
    ], { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    const timer = setTimeout(() => child.kill('SIGKILL'), PREVIEW_TIMEOUT_MS);
    child.stderr.on('data', (chunk) => { if (stderr.length < 4000) stderr += String(chunk); });
    child.once('error', (error) => { clearTimeout(timer); reject(error); });
    child.once('close', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(`Hikvision preview ffmpeg failed (${code}): ${stderr.trim().slice(0, 1000)}`));
    });
  });
}

async function buildPreview(context, req, stream, targetSec, output) {
  await fsp.mkdir(CACHE_DIR, { recursive: true });
  const nonce = `${process.pid}-${Date.now()}`;
  const source = `${output}.source-${nonce}${targetSec > 0 ? '.mp4' : '.jpg'}`;
  const tmp = `${output}.tmp-${nonce}.mp4`;
  const channelId = String(context.target.channel_id);
  try {
    let response;
    if (targetSec > 0) {
      const targetMs = targetSec * 1000;
      const params = new URLSearchParams({
        start: new Date(targetMs - 1000).toISOString(),
        end: new Date(targetMs + 2000).toISOString(),
        token: context.upstream_token
      });
      response = await nodeRequest(context, `/api/v1/media/channels/${encodeURIComponent(channelId)}/archive/export.mp4?${params.toString()}`, req, PREVIEW_TIMEOUT_MS);
    } else {
      response = await nodeRequest(context, withToken(`/api/v1/media/channels/${encodeURIComponent(channelId)}/snapshot.jpg`, context.upstream_token), req, 20000);
    }
    await responseToFile(response, source);
    await renderStill(source, tmp);
    await fsp.rename(tmp, output);
    return fsp.stat(output);
  } finally {
    await fsp.unlink(source).catch(() => undefined);
    await fsp.unlink(tmp).catch(() => undefined);
  }
}

async function ensurePreview(context, req, stream, targetSec) {
  const file = safeCacheName(stream, targetSec);
  const cached = await validPreviewCache(file, targetSec);
  if (cached) return { file, stat: cached, cached: true };
  const key = `${stream}:${targetSec}`;
  if (!previewJobs.has(key)) {
    previewJobs.set(key, buildPreview(context, req, stream, targetSec, file).finally(() => previewJobs.delete(key)));
  }
  const stat = await previewJobs.get(key);
  return { file, stat, cached: false };
}

function sendPreview(req, res, preview, stream) {
  const total = preview.stat.size;
  const range = String(req.headers.range || '');
  const headers = cors({
    'content-type': 'video/mp4',
    'cache-control': 'private, max-age=5',
    'accept-ranges': 'bytes',
    'x-newdomofon-resolved-stream': stream,
    'x-newdomofon-smartyard-route': preview.cached ? 'hikvision-preview-cache' : 'hikvision-preview'
  });
  const match = /^bytes=(\d*)-(\d*)$/.exec(range);
  if (match) {
    const start = match[1] ? Number(match[1]) : 0;
    const end = Math.min(match[2] ? Number(match[2]) : total - 1, total - 1);
    if (Number.isFinite(start) && Number.isFinite(end) && start <= end && start < total) {
      res.writeHead(206, { ...headers, 'content-range': `bytes ${start}-${end}/${total}`, 'content-length': String(end - start + 1) });
      if (req.method === 'HEAD') return res.end();
      return fs.createReadStream(preview.file, { start, end }).pipe(res);
    }
  }
  res.writeHead(200, { ...headers, 'content-length': String(total) });
  if (req.method === 'HEAD') return res.end();
  return fs.createReadStream(preview.file).pipe(res);
}

function livePlaylist(mediaPath) {
  return /^(?:live|index|video)(?:\.fmp4)?\.m3u8$/i.test(mediaPath);
}

function archivePlaylist(mediaPath) {
  return /^archive(?:\.fmp4)?\.m3u8$/i.test(mediaPath) ||
    /^(?:archive|index|video|mono)-\d+-(?:now|\d+)(?:\.fmp4)?\.m3u8$/i.test(mediaPath) ||
    /^timeshift_(?:abs|rel)-\d+(?:\.fmp4)?\.m3u8$/i.test(mediaPath);
}

function exportPath(mediaPath) {
  return mediaPath === 'export.mp4' || /^(?:archive|index|video|mono)-\d+-(?:now|\d+)\.mp4$/i.test(mediaPath);
}

function eventsPath(mediaPath) {
  return ['events', 'events.json', 'motion_events.json'].includes(mediaPath);
}

function eventsSummaryPath(mediaPath) {
  return ['events/summary', 'events_summary.json'].includes(mediaPath);
}

async function handleHikvision(req, res, reqUrl, stream, mediaPath, externalToken) {
  const eventRequest = eventsPath(mediaPath) || eventsSummaryPath(mediaPath);
  const context = await resolveHikvision(externalToken, stream, eventRequest ? 'events' : 'camera');
  if (context.error_status) return sendJson(res, context.error_status, context.error_body || { error: 'Hikvision token rejected' });

  const channelId = String(context.target.channel_id);
  if (!mediaPath || mediaPath === 'media_info.json') {
    return sendJson(res, 200, {
      stream,
      name: context.camera?.name || stream,
      provider: 'hikvision',
      tracks: [
        { content: 'video', codec: 'h264' },
        { content: 'audio', codec: 'aac', optional: true }
      ]
    }, { 'x-newdomofon-smartyard-route': 'hikvision-info' });
  }

  if (mediaPath === 'recording_status.json') return handleRecordingStatus(req, res, context, stream, reqUrl);
  if (eventRequest) return handleEvents(req, res, context, stream, reqUrl, eventsSummaryPath(mediaPath));

  const preview = previewTarget(mediaPath);
  if (preview.preview) {
    try {
      return sendPreview(req, res, await ensurePreview(context, req, stream, preview.targetSec), stream);
    } catch (error) {
      return sendJson(res, Number(error?.status || 502), { error: String(error?.message || error) }, {
        'x-newdomofon-smartyard-route': 'hikvision-preview-error'
      });
    }
  }

  if (mediaPath === 'snapshot.jpg' || mediaPath === 'snapshot.jpeg') {
    const upstream = withToken(`/api/v1/media/channels/${encodeURIComponent(channelId)}/snapshot.jpg`, context.upstream_token);
    const response = await nodeRequest(context, upstream, req, 20000);
    return sendNodeResponse(req, res, response, stream, externalToken, 'hikvision-snapshot', upstream);
  }

  if (livePlaylist(mediaPath)) {
    const upstream = withToken(`/api/v1/media/channels/${encodeURIComponent(channelId)}/live/index.m3u8`, context.upstream_token);
    const response = await nodeRequest(context, upstream, req, 20000);
    return sendNodeResponse(req, res, response, stream, externalToken, 'hikvision-live', upstream);
  }

  if (archivePlaylist(mediaPath)) {
    try {
      const upstream = await prepareArchivePlaylist(req, context, parseArchiveWindow(mediaPath, reqUrl));
      const response = await nodeRequest(context, upstream, req, 90000);
      return sendNodeResponse(req, res, response, stream, externalToken, 'hikvision-archive', upstream);
    } catch (error) {
      return sendJson(res, Number(error?.status || 502), { error: String(error?.message || error) }, {
        'x-newdomofon-smartyard-route': 'hikvision-archive-error'
      });
    }
  }

  if (exportPath(mediaPath)) {
    const range = parseArchiveWindow(mediaPath, reqUrl);
    const params = new URLSearchParams({
      start: new Date(range.startMs).toISOString(),
      end: new Date(range.endMs).toISOString(),
      token: context.upstream_token
    });
    const upstream = `/api/v1/media/channels/${encodeURIComponent(channelId)}/archive/export.mp4?${params.toString()}`;
    const response = await nodeRequest(context, upstream, req, 120000);
    return sendNodeResponse(req, res, response, stream, externalToken, 'hikvision-export', upstream);
  }

  if (mediaPath.startsWith('__hik/')) {
    const encoded = mediaPath.slice('__hik/'.length).split('/')[0];
    const decoded = decodeOpaqueUpstreamPath(encoded);
    if (!decoded) return sendJson(res, 400, { error: 'Invalid Hikvision media segment path' });
    const upstream = withToken(decoded, context.upstream_token);
    const response = await nodeRequest(context, upstream, req, 30000);
    return sendNodeResponse(req, res, response, stream, externalToken, 'hikvision-segment', upstream);
  }

  if (mediaPath === 'live.ts' || mediaPath === 'live.mpd' || mediaPath.startsWith('dash/')) {
    return sendJson(res, 404, {
      error: 'This Hikvision SmartYard source is HLS-native; MPEG-TS/DASH compatibility is not enabled'
    }, { 'x-newdomofon-smartyard-route': 'hikvision-format-unsupported' });
  }

  return sendJson(res, 404, { error: 'Unsupported Hikvision SmartYard media path', path: mediaPath }, {
    'x-newdomofon-smartyard-route': 'hikvision-unsupported'
  });
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
        service: 'newdomofon-smartyard-hikvision-gateway',
        version: VERSION,
        inner_gateway_port: INNER_PORT,
        backend: BACKEND_URL,
        hikvision: true,
        generic_passthrough: true,
        internal_secret_configured: Boolean(INTERNAL_SECRET)
      });
    }

    const externalToken = extractToken(req, reqUrl);
    if (!isHikvisionToken(externalToken)) return proxyInner(req, res);
    if (req.method !== 'GET' && req.method !== 'HEAD') return sendJson(res, 405, { error: 'Method not allowed' });

    const { stream, mediaPath } = parseRequestPath(reqUrl);
    if (!safeStream(stream)) return sendJson(res, 400, { error: 'Invalid Hikvision SmartYard stream name' });
    return await handleHikvision(req, res, reqUrl, stream, mediaPath, externalToken);
  } catch (error) {
    console.error('[smartyard-hikvision] request failed', error);
    return sendJson(res, 502, {
      error: 'Hikvision SmartYard compatibility gateway error',
      message: String(error?.message || error)
    });
  }
}

const server = http.createServer((req, res) => { void handle(req, res); });
server.listen(PUBLIC_PORT, PUBLIC_HOST, () => {
  console.log('[smartyard-hikvision] listening', {
    host: PUBLIC_HOST,
    port: PUBLIC_PORT,
    inner_gateway_port: INNER_PORT,
    backend: BACKEND_URL,
    version: VERSION
  });
});

process.on('SIGTERM', () => server.close());
process.on('SIGINT', () => server.close());

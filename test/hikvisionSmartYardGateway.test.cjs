'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const path = require('node:path');
const { spawn } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..');

function json(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(text)
  });
  res.end(text);
}

function text(res, status, body, contentType = 'text/plain') {
  const value = String(body);
  res.writeHead(status, {
    'content-type': contentType,
    'content-length': Buffer.byteLength(value)
  });
  res.end(value);
}

async function body(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

function listen(server, port) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => resolve());
  });
}

function close(server) {
  return new Promise((resolve) => server.close(() => resolve()));
}

async function waitFor(url, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.ok) return response;
      lastError = new Error(`HTTP ${response.status}`);
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw lastError || new Error(`Timed out waiting for ${url}`);
}

function externalToken(stream) {
  const payload = Buffer.from(JSON.stringify({
    target: 'hikvision',
    channel_id: 'hik-device:1',
    stream_name: stream,
    user_id: 'test-user',
    scope: 'camera',
    link_version: 'test'
  })).toString('base64url');
  return `${payload}.test-signature`;
}

function playlistSegment(bodyText) {
  return bodyText.split(/\r?\n/).find((line) => line.startsWith('__hik/')) || '';
}

test('Hikvision SmartYard adapter exposes live, ranges, archive and events', async (t) => {
  const base = 42000 + (process.pid % 1000);
  const OUTER = base;
  const LEGACY = base + 1;
  const MEDIA = base + 2;
  const EVENTS = base + 3;
  const PREVIEW = base + 4;
  const FORMATS = base + 5;
  const BACKEND = base + 6;
  const HIK = base + 7;
  const stream = 'hik_11111111222243338444555555555555_1';
  const token = externalToken(stream);
  const nowMs = Date.now();
  const archiveStartMs = nowMs - 10 * 60 * 1000;
  const archiveEndMs = nowMs - 5 * 60 * 1000;
  const eventAtMs = archiveStartMs + 2 * 60 * 1000;
  const archiveStartIso = new Date(archiveStartMs).toISOString();
  const archiveEndIso = new Date(archiveEndMs).toISOString();
  const eventAtIso = new Date(eventAtMs).toISOString();

  const resolverCalls = [];
  const backend = http.createServer(async (req, res) => {
    if (req.url !== '/api/internal/smartyard/resolve' || req.method !== 'POST') {
      return json(res, 404, { error: 'not found' });
    }
    assert.equal(req.headers['x-internal-secret'], 'test-internal-secret');
    const requestBody = JSON.parse(await body(req));
    resolverCalls.push(requestBody);
    assert.equal(requestBody.stream_name, stream);
    return json(res, 200, {
      ok: true,
      camera: { id: 'hik-device:1', name: 'Hik test', stream_name: stream },
      node: { id: 'node-1', name: 'Hik node', url: `http://127.0.0.1:${HIK}`, kind: 'hikvision' },
      target: {
        kind: 'hikvision',
        channel_id: 'hik-device:1',
        device_id: '11111111-2222-4333-8444-555555555555',
        physical_channel: 1,
        archive_storage: 'device'
      },
      upstream_token: 'native-upstream-token',
      upstream_scope: requestBody.upstream_scope || 'camera',
      expires_in: 300,
      token_source: 'hikvision-node'
    });
  });

  let archiveSessionRequests = 0;
  let rangeRequests = 0;
  let eventRequests = 0;
  const hik = http.createServer(async (req, res) => {
    const requestUrl = new URL(req.url, `http://127.0.0.1:${HIK}`);
    assert.equal(requestUrl.searchParams.get('token'), 'native-upstream-token');

    if (requestUrl.pathname === '/api/v1/media/channels/hik-device%3A1/live/index.m3u8') {
      return text(res, 200,
        '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MAP:URI="init.mp4?token=stale"\n#EXTINF:4.000,\nseg0.m4s?token=stale\n',
        'application/vnd.apple.mpegurl'
      );
    }
    if (requestUrl.pathname.endsWith('/live/init.mp4')) {
      return text(res, 200, 'init-bytes', 'video/mp4');
    }
    if (requestUrl.pathname.endsWith('/live/seg0.m4s')) {
      return text(res, 200, 'live-segment', 'video/iso.segment');
    }
    if (requestUrl.pathname === '/api/v1/media/channels/hik-device%3A1/archive/ranges') {
      rangeRequests += 1;
      return json(res, 200, {
        source: 'device',
        ranges: [{ start: archiveStartIso, end: archiveEndIso, source: 'device' }]
      });
    }
    if (requestUrl.pathname === '/api/v1/media/channels/hik-device%3A1/archive/session' && req.method === 'POST') {
      archiveSessionRequests += 1;
      const requestBody = JSON.parse(await body(req));
      assert.ok(Date.parse(requestBody.start));
      assert.ok(Date.parse(requestBody.end));
      return json(res, 200, {
        id: 'session-1',
        source: 'device',
        playlist_url: '/api/v1/media/channels/hik-device%3A1/archive/sessions/session-1/index.m3u8?token=old'
      });
    }
    if (requestUrl.pathname === '/api/v1/media/channels/hik-device%3A1/archive/sessions/session-1/index.m3u8') {
      return text(res, 200,
        '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MAP:URI="init.mp4?token=old"\n#EXTINF:4.000,\narchive0.m4s?token=old\n#EXT-X-ENDLIST\n',
        'application/vnd.apple.mpegurl'
      );
    }
    if (requestUrl.pathname.endsWith('/archive/sessions/session-1/init.mp4')) {
      return text(res, 200, 'archive-init', 'video/mp4');
    }
    if (requestUrl.pathname.endsWith('/archive/sessions/session-1/archive0.m4s')) {
      return text(res, 200, 'archive-segment', 'video/iso.segment');
    }
    if (requestUrl.pathname === '/api/v1/events/channels/hik-device%3A1') {
      eventRequests += 1;
      return json(res, 200, {
        items: [{
          id: 'event-1',
          event_type: 'motion',
          event_state: 'active',
          occurred_at: eventAtIso,
          source_name: 'hikvision.hcnetsdk.history',
          data: { physical_channel: 1 }
        }]
      });
    }
    return json(res, 404, { error: 'mock Hikvision route not found', path: requestUrl.pathname });
  });

  await listen(backend, BACKEND);
  await listen(hik, HIK);
  t.after(async () => {
    await Promise.all([close(backend), close(hik)]);
  });

  const child = spawn(process.execPath, ['smartyard-compat-proxy/server-hikvision-gateway.js'], {
    cwd: ROOT,
    env: {
      ...process.env,
      SMARTYARD_COMPAT_HOST: '127.0.0.1',
      SMARTYARD_COMPAT_PORT: String(OUTER),
      SMARTYARD_LEGACY_PORT: String(LEGACY),
      SMARTYARD_MEDIA_GATEWAY_PORT: String(MEDIA),
      SMARTYARD_EVENTS_GATEWAY_PORT: String(EVENTS),
      SMARTYARD_PREVIEW_GATEWAY_PORT: String(PREVIEW),
      SMARTYARD_FORMATS_GATEWAY_PORT: String(FORMATS),
      SMARTYARD_BACKEND_URL: `http://127.0.0.1:${BACKEND}`,
      INTERNAL_DVR_SECRET: 'test-internal-secret',
      SMARTYARD_DEFAULT_RANGE_DAYS: '1',
      PREVIEW_CACHE_DIR: `/tmp/newdomofon-hik-smartyard-test-${process.pid}`
    },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let childLog = '';
  child.stdout.on('data', (chunk) => { childLog += String(chunk); });
  child.stderr.on('data', (chunk) => { childLog += String(chunk); });
  t.after(async () => {
    if (child.exitCode === null) child.kill('SIGTERM');
    await new Promise((resolve) => {
      if (child.exitCode !== null) return resolve();
      child.once('exit', resolve);
      setTimeout(() => {
        if (child.exitCode === null) child.kill('SIGKILL');
        resolve();
      }, 3000).unref();
    });
  });

  try {
    const health = await waitFor(`http://127.0.0.1:${OUTER}/health`);
    const healthBody = await health.json();
    assert.equal(healthBody.hikvision, true);
    assert.equal(healthBody.generic_passthrough, true);

    const live = await fetch(`http://127.0.0.1:${OUTER}/${stream}/index.m3u8?token=${encodeURIComponent(token)}`);
    assert.equal(live.status, 200);
    const liveText = await live.text();
    assert.match(liveText, /#EXT-X-MAP:URI="__hik\//);
    const liveSegment = playlistSegment(liveText);
    assert.ok(liveSegment, liveText);
    const liveSegmentResponse = await fetch(new URL(liveSegment, `http://127.0.0.1:${OUTER}/${stream}/index.m3u8`));
    assert.equal(liveSegmentResponse.status, 200);
    assert.equal(await liveSegmentResponse.text(), 'live-segment');

    const ranges = await fetch(`http://127.0.0.1:${OUTER}/${stream}/recording_status.json?from=0&token=${encodeURIComponent(token)}`);
    assert.equal(ranges.status, 200);
    const rangeBody = await ranges.json();
    assert.equal(rangeBody[0].stream, stream);
    assert.equal(rangeBody[0].ranges.length, 1);
    assert.equal(rangeRequests, 1);

    const startSec = Math.floor(archiveStartMs / 1000);
    const archive = await fetch(`http://127.0.0.1:${OUTER}/${stream}/archive-${startSec}-30.m3u8?token=${encodeURIComponent(token)}`);
    assert.equal(archive.status, 200);
    const archiveText = await archive.text();
    const archiveSegment = playlistSegment(archiveText);
    assert.ok(archiveSegment, archiveText);
    assert.equal(archiveSessionRequests, 1);
    const archiveSegmentResponse = await fetch(new URL(archiveSegment, `http://127.0.0.1:${OUTER}/${stream}/archive-${startSec}-30.m3u8`));
    assert.equal(archiveSegmentResponse.status, 200);
    assert.equal(await archiveSegmentResponse.text(), 'archive-segment');

    const events = await fetch(`http://127.0.0.1:${OUTER}/${stream}/events.json?start=${encodeURIComponent(archiveStartIso)}&end=${encodeURIComponent(archiveEndIso)}&token=${encodeURIComponent(token)}`);
    assert.equal(events.status, 200);
    const eventBody = await events.json();
    assert.equal(eventBody.count, 1);
    assert.equal(eventBody.items[0].event_type, 'motion');
    assert.equal(eventRequests, 1);
    assert.ok(resolverCalls.some((call) => call.upstream_scope === 'events'));
  } catch (error) {
    error.message += `\nGateway log:\n${childLog}`;
    throw error;
  }
});

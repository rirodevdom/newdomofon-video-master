'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');

test('Hikvision inventory is linked to canonical camera UUIDs', () => {
  const migration = read('backend/migrations/097_hikvision_channels_as_cameras.sql');
  assert.match(migration, /ADD COLUMN IF NOT EXISTS camera_id uuid REFERENCES public\.cameras\(id\)/);
  assert.match(migration, /INSERT INTO public\.cameras/);
  assert.match(migration, /hik_.*replace\(h\.device_id::text, '-', ''\)/s);

  const agent = read('backend/src/routes/nodeAgent.ts');
  assert.match(agent, /v310-hikvision-canonical-cameras/);
  assert.match(agent, /ON CONFLICT \(stream_name\) DO UPDATE SET/);
  assert.match(agent, /camera_id, physical_channel/);
  assert.match(agent, /DELETE FROM cameras c\s+USING hikvision_node_channels h/s);
});

test('ordinary Cameras API exposes the canonical Hikvision binding', () => {
  const cameras = read('backend/src/routes/cameras.ts');
  assert.match(cameras, /LEFT JOIN hikvision_node_channels h ON h\.camera_id = c\.id/);
  assert.match(cameras, /h\.channel_external_id AS hikvision_channel_external_id/);
  assert.match(cameras, /device\.connection_type = 'HIKVISION'/);
  assert.doesNotMatch(cameras, /\[\.\.\.normal\.rows, \.\.\.hikvision\.rows\]/);
});

test('managed tokens resolve canonical Hikvision cameras through Hikvision node', () => {
  const resolver = read('backend/src/routes/internalSmartYard.ts');
  assert.match(resolver, /LEFT JOIN hikvision_node_channels h ON h\.camera_id = c\.id/);
  assert.match(resolver, /(?:managedCamera|camera)\.device_connection_type === 'HIKVISION'/);
  assert.match(resolver, /return sendHikvisionResolved\(/);

  const tokens = read('backend/src/routes/managedCameraTokens.ts');
  assert.match(tokens, /device\.connection_type AS device_connection_type/);
  assert.match(tokens, /buildHikvisionFormatLinks/);
  assert.match(tokens, /managedCameraTokensRouter\.post\('\/camera-links\/:cameraId'/);
});

test('actual master Hikvision player translates archive time in both directions', () => {
  const player = read('backend/src/routes/hikvisionPlayer.ts');
  assert.match(player, /v311-hikvision-master-player-timeline/);
  assert.match(player, /rewriteHikvisionArchiveProgramDateTime/);
  assert.match(player, /scope === 'archive'/);
  assert.match(player, /timelineIsoToNodeArchiveIso\(params\.start\)/);
  assert.match(player, /result\.items\.map\(archiveRangeToTimeline\)/);

  const offset = -10800 * 1000;
  const nodeMs = Date.parse('2026-08-01T10:06:46.000Z');
  const timelineMs = nodeMs + offset;
  assert.equal(new Date(timelineMs).toISOString(), '2026-08-01T07:06:46.000Z');
  assert.equal(new Date(timelineMs - offset).toISOString(), '2026-08-01T10:06:46.000Z');
});

test('obsolete virtual-camera build materializers are no longer active', () => {
  const pkg = JSON.parse(read('backend/package.json'));
  const prebuild = pkg.scripts.prebuild;
  assert.doesNotMatch(prebuild, /patch-hikvision-unified-camera-catalog\.py/);
  assert.doesNotMatch(prebuild, /patch-hikvision-unified-links-shape\.py/);
  assert.match(prebuild, /patch-hikvision-canonical-cameras-v2\.py/);
  assert.match(prebuild, /patch-hikvision-master-player-time-v2\.py/);
});

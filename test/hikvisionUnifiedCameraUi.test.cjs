'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');

test('Hikvision no longer has a separate navigation catalog', () => {
  const app = read('frontend/src/App.vue');
  const router = read('frontend/src/router.ts');
  assert.doesNotMatch(app, /title="Hikvision-каналы"/);
  assert.doesNotMatch(router, /HikvisionChannelsView/);
  assert.match(router, /path: '\/hikvision', redirect: '\/cameras'/);
});

test('ordinary Cameras UI exposes Hikvision through the normal camera controls', () => {
  const cameras = read('frontend/src/views/CamerasView.vue');
  assert.match(cameras, /device_connection_type === 'HIKVISION'/);
  assert.match(cameras, /:to="`\/cameras\/\$\{camera\.id\}`"/);
  assert.match(cameras, /@click="openTokenDialog\(camera\)"/);
  assert.doesNotMatch(cameras, /openHikvisionLinks/);
});

test('ordinary PlayerView selects Hikvision transport internally', () => {
  const player = read('frontend/src/views/PlayerView.vue');
  assert.match(player, /v312-hikvision-unified-camera-ui/);
  assert.match(player, /function mediaApiPath/);
  assert.match(player, /hikvision_channel_external_id/);
  assert.match(player, /mediaApiPath\('live'\)/);
  assert.match(player, /mediaApiPath\('archive\/ranges'\)/);
  assert.match(player, /mediaApiPath\('archive'\)/);
  assert.match(player, /mediaApiPath\('events'\)/);
  assert.match(player, /mediaApiPath\('export'\)/);
});

test('ordinary PlayerView owns and releases Hikvision archive viewer lease', () => {
  const player = read('frontend/src/views/PlayerView.vue');
  assert.match(player, /v312-hikvision-unified-camera-viewer-lease/);
  assert.match(player, /const archiveViewerId/);
  assert.match(player, /viewer_id: archiveViewerId/);
  assert.match(player, /archive\/release/);
  assert.match(player, /archiveViewerChannelId = isHikvision\.value/);

  const pkg = JSON.parse(read('frontend/package.json'));
  assert.doesNotMatch(pkg.scripts.prebuild, /patch-hikvision-archive-viewer-lease\.py.*frontend-only/);
  assert.match(pkg.scripts.prebuild, /patch-hikvision-unified-camera-ui\.py/);
});

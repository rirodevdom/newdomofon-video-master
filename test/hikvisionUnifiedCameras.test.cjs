'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');

function read(relative) {
  return fs.readFileSync(path.join(root, relative), 'utf8');
}

test('Hikvision channels are projected into the unified cameras catalog', () => {
  const cameras = read('backend/src/routes/cameras.ts');
  assert.match(cameras, /v308-hikvision-unified-camera-catalog/);
  assert.match(cameras, /FROM hikvision_node_channels h/);
  assert.match(cameras, /'hikvision'::text AS camera_kind/);
  assert.match(cameras, /true AS is_hikvision/);
  assert.match(cameras, /'hik_' \|\| replace\(h\.device_id::text, '-', ''\)/);
});

test('Hikvision permanent link endpoint exposes ordinary-camera link shape', () => {
  const links = read('backend/src/routes/smartyardLinks.ts');
  assert.match(links, /hikvision_format_links_v308/);
  assert.match(links, /format_links: formatLinks/);
  assert.match(links, /archive_url_template/);
  assert.match(links, /events_url_template/);
  assert.match(links, /type: 'HLS'.*available: true/);
  assert.match(links, /type: 'JPEG'.*available: true/);
  assert.match(links, /type: 'MPEG-TS'.*available: false/);
});

test('unified patch runs after Hikvision SmartYard link materialization', () => {
  const pkg = JSON.parse(read('backend/package.json'));
  const prebuild = pkg.scripts.prebuild;
  const linkPatch = prebuild.indexOf('patch-hikvision-smartyard-links.py');
  const unifiedPatch = prebuild.indexOf('patch-hikvision-unified-cameras.py');
  assert.ok(linkPatch >= 0);
  assert.ok(unifiedPatch > linkPatch);
});

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
function read(relative) { return fs.readFileSync(path.join(root, relative), 'utf8'); }

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

test('catalog and link shape run after Hikvision SmartYard link materialization', () => {
  const prebuild = JSON.parse(read('backend/package.json')).scripts.prebuild;
  const baseLinks = prebuild.indexOf('patch-hikvision-smartyard-links.py');
  const catalog = prebuild.indexOf('patch-hikvision-unified-camera-catalog.py');
  const linkShape = prebuild.indexOf('patch-hikvision-unified-links-shape.py');
  assert.ok(baseLinks >= 0);
  assert.ok(catalog > baseLinks);
  assert.ok(linkShape > catalog);
});

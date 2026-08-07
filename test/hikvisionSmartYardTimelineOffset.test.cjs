'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createTimelineOffset } = require('../smartyard-compat-proxy/hikvision-timeline-offset.js');
const root = path.resolve(__dirname, '..');

test('02:48 internal maps to 23:48 Hikvision timeline and back', () => {
  const clock = createTimelineOffset(-10800);
  const internal = Date.parse('2026-08-08T02:48:24.000Z');
  const timeline = Date.parse('2026-08-07T23:48:24.000Z');
  assert.equal(clock.internalToTimelineMs(internal), timeline);
  assert.equal(clock.timelineToInternalMs(timeline), internal);
  assert.equal(clock.timelineIso(internal), '2026-08-07T23:48:24.000Z');
});

test('materialized gateway applies offset in both directions', () => {
  const gateway = fs.readFileSync(path.join(root, 'smartyard-compat-proxy/server-hikvision-gateway.js'), 'utf8');
  assert.match(gateway, /v309-hikvision-smartyard-timeline-offset/);
  assert.match(gateway, /internalToTimelineMs/);
  assert.match(gateway, /timelineToInternalMs/);
  assert.match(gateway, /hikvision_timeline_offset_seconds/);
});

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createTimelineOffset } = require('../smartyard-compat-proxy/hikvision-timeline-offset.js');

const root = path.resolve(__dirname, '..');

test('default Hikvision compatibility maps internal 02:48 to external 23:48', () => {
  const clock = createTimelineOffset(-10800);
  const internal = Date.parse('2026-08-08T02:48:24.000Z');
  const timeline = Date.parse('2026-08-07T23:48:24.000Z');
  assert.equal(clock.internalToTimelineMs(internal), timeline);
  assert.equal(clock.timelineToInternalMs(timeline), internal);
  assert.equal(clock.timelineIso(internal), '2026-08-07T23:48:24.000Z');
});

test('offset is configurable and bounded', () => {
  const identity = createTimelineOffset(0);
  const value = Date.parse('2026-08-08T00:00:00.000Z');
  assert.equal(identity.internalToTimelineMs(value), value);
  assert.throws(() => createTimelineOffset(90000), /Invalid Hikvision timeline offset/);
});

test('materialized gateway uses inverse conversions for output and seek', () => {
  const gateway = fs.readFileSync(path.join(root, 'smartyard-compat-proxy/server-hikvision-gateway.js'), 'utf8');
  assert.match(gateway, /v309-hikvision-smartyard-timeline-offset/);
  assert.match(gateway, /internalToTimelineMs/);
  assert.match(gateway, /timelineToInternalMs/);
  assert.match(gateway, /hikvision_timeline_offset_seconds/);
});

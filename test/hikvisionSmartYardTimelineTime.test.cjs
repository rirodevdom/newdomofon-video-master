'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createTimelineClock } = require('../smartyard-compat-proxy/hikvision-timeline-time.js');

test('Europe/Moscow exposes DVR wall clock while preserving UTC round trip', () => {
  const clock = createTimelineClock('Europe/Moscow');
  const utc = Date.parse('2026-08-08T09:15:30.000Z');
  const timeline = clock.utcToTimelineMs(utc);

  assert.equal(new Date(timeline).toISOString(), '2026-08-08T12:15:30.000Z');
  assert.equal(clock.timelineIso(utc), '2026-08-08T12:15:30.000Z');
  assert.equal(clock.timelineToUtcMs(timeline), utc);
  assert.equal(clock.offsetMsAt(utc), 3 * 60 * 60 * 1000);
});

test('Moscow offset is stable in winter and UTC mode remains identity', () => {
  const moscow = createTimelineClock('Europe/Moscow');
  const winter = Date.parse('2026-01-15T01:02:03.000Z');
  assert.equal(moscow.offsetMsAt(winter), 3 * 60 * 60 * 1000);
  assert.equal(moscow.timelineToUtcMs(moscow.utcToTimelineMs(winter)), winter);

  const utcClock = createTimelineClock('UTC');
  assert.equal(utcClock.utcToTimelineMs(winter), winter);
  assert.equal(utcClock.timelineToUtcMs(winter), winter);
});

test('invalid IANA timezone fails immediately', () => {
  assert.throws(() => createTimelineClock('Not/A_Real_Zone'), /time zone|Invalid/i);
});

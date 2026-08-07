'use strict';

function createTimelineClock(timeZone = 'Europe/Moscow') {
  const zone = String(timeZone || 'Europe/Moscow').trim() || 'Europe/Moscow';
  const formatter = new Intl.DateTimeFormat('en-CA', {
    timeZone: zone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23'
  });

  // Validate the IANA zone at startup rather than failing on the first archive request.
  formatter.format(new Date());

  function offsetMsAt(utcMs) {
    const instant = Number(utcMs);
    if (!Number.isFinite(instant)) return NaN;
    const values = {};
    for (const part of formatter.formatToParts(new Date(instant))) {
      if (part.type !== 'literal') values[part.type] = Number(part.value);
    }
    const wallAsUtc = Date.UTC(
      values.year,
      values.month - 1,
      values.day,
      values.hour,
      values.minute,
      values.second
    );
    const instantWholeSecond = Math.floor(instant / 1000) * 1000;
    return wallAsUtc - instantWholeSecond;
  }

  // SmartYard/Flussonic URLs carry unix-like seconds, but this compatibility
  // clock deliberately exposes the DVR/server wall clock in that numeric domain.
  // Example for Europe/Moscow: real 09:00Z is exposed as timeline 12:00Z.
  function utcToTimelineMs(utcMs) {
    const instant = Number(utcMs);
    const offset = offsetMsAt(instant);
    return Number.isFinite(offset) ? instant + offset : NaN;
  }

  // Inverse of utcToTimelineMs. Iteration also keeps this correct for IANA zones
  // with DST transitions instead of assuming Moscow's current fixed UTC+3.
  function timelineToUtcMs(timelineMs) {
    const wall = Number(timelineMs);
    if (!Number.isFinite(wall)) return NaN;
    let candidate = wall;
    for (let index = 0; index < 4; index += 1) {
      const offset = offsetMsAt(candidate);
      if (!Number.isFinite(offset)) return NaN;
      const next = wall - offset;
      if (Math.abs(next - candidate) < 1) return next;
      candidate = next;
    }
    return candidate;
  }

  function timelineIso(utcMs) {
    const shifted = utcToTimelineMs(utcMs);
    if (!Number.isFinite(shifted)) throw new Error(`Invalid UTC timestamp: ${utcMs}`);
    return new Date(shifted).toISOString();
  }

  return {
    timeZone: zone,
    offsetMsAt,
    utcToTimelineMs,
    timelineToUtcMs,
    timelineIso
  };
}

module.exports = { createTimelineClock };

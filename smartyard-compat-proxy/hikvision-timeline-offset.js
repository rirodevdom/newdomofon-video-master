'use strict';

function createTimelineOffset(offsetSeconds = -10800) {
  const seconds = Number(offsetSeconds);
  if (!Number.isFinite(seconds) || Math.abs(seconds) > 24 * 3600) {
    throw new Error(`Invalid Hikvision timeline offset seconds: ${offsetSeconds}`);
  }
  const offsetMs = Math.trunc(seconds * 1000);
  return {
    offsetSeconds: seconds,
    internalToTimelineMs(value) {
      const ms = Number(value);
      return Number.isFinite(ms) ? ms + offsetMs : NaN;
    },
    timelineToInternalMs(value) {
      const ms = Number(value);
      return Number.isFinite(ms) ? ms - offsetMs : NaN;
    },
    timelineIso(value) {
      const shifted = this.internalToTimelineMs(value);
      if (!Number.isFinite(shifted)) throw new Error(`Invalid timeline timestamp: ${value}`);
      return new Date(shifted).toISOString();
    }
  };
}

module.exports = { createTimelineOffset };

#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = 'v307-hikvision-smartyard-timeline-timezone'


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'{label}: expected one source fragment, found {count}')
    return text.replace(old, new, 1)


def patch_gateway(path: Path) -> None:
    text = path.read_text(encoding='utf-8')
    if MARKER in text:
        print('Hikvision SmartYard timeline timezone already prepared')
        return

    text = replace_once(
        text,
        "const { URL } = require('node:url');\n",
        "const { URL } = require('node:url');\nconst { createTimelineClock } = require('./hikvision-timeline-time.js');\n",
        'timeline helper import',
    )

    constant_anchor = "const VIRTUAL_ARCHIVE_MAX_SECONDS = Math.max(3600, Number(process.env.SMARTYARD_HIK_VIRTUAL_ARCHIVE_MAX_SECONDS || 21600));\n"
    constants = constant_anchor + "const HIK_TIMELINE_TIME_ZONE = String(process.env.SMARTYARD_HIK_TIMELINE_TIME_ZONE || 'Europe/Moscow').trim() || 'Europe/Moscow';\nconst HIK_TIMELINE_CLOCK = createTimelineClock(HIK_TIMELINE_TIME_ZONE);\nconst HIK_TIMELINE_TIMEZONE_MARKER = 'v307-hikvision-smartyard-timeline-timezone';\n"
    text = replace_once(text, constant_anchor, constants, 'timeline timezone constants')

    old_parse = r'''function parseArchiveWindow(mediaPath, reqUrl) {
  const queryStart = reqUrl.searchParams.get('start');
  const queryEnd = reqUrl.searchParams.get('end');
  if (queryStart && queryEnd) {
    const startMs = Date.parse(queryStart);
    const endMs = Date.parse(queryEnd);
    if (Number.isFinite(startMs) && Number.isFinite(endMs) && endMs > startMs) return { startMs, endMs };
  }

  let match = /^(?:archive|index|video|mono)-(\d+)-(now|\d+)\.(?:fmp4\.)?(?:m3u8|mp4)$/i.exec(mediaPath);
  if (match) {
    const from = Number(match[1]);
    const duration = match[2] === 'now' ? Math.floor(Date.now() / 1000) - from : Number(match[2]);
    if (Number.isFinite(from) && Number.isFinite(duration) && duration > 0) {
      return { startMs: from * 1000, endMs: (from + duration) * 1000 };
    }
  }

  match = /^timeshift_abs-(\d+)(?:\.fmp4)?\.m3u8$/i.exec(mediaPath);
  if (match) return { startMs: Number(match[1]) * 1000, endMs: Date.now() };
  match = /^timeshift_rel-(\d+)(?:\.fmp4)?\.m3u8$/i.exec(mediaPath);
  if (match) return { startMs: Date.now() - Number(match[1]) * 1000, endMs: Date.now() };
  return { startMs: Date.now() - 3600000, endMs: Date.now() };
}'''
    new_parse = r'''function parseArchiveWindow(mediaPath, reqUrl) {
  const queryStart = reqUrl.searchParams.get('start');
  const queryEnd = reqUrl.searchParams.get('end');
  if (queryStart && queryEnd) {
    const externalStartMs = Date.parse(queryStart);
    const externalEndMs = Date.parse(queryEnd);
    const startMs = HIK_TIMELINE_CLOCK.timelineToUtcMs(externalStartMs);
    const endMs = HIK_TIMELINE_CLOCK.timelineToUtcMs(externalEndMs);
    if (Number.isFinite(startMs) && Number.isFinite(endMs) && endMs > startMs) return { startMs, endMs };
  }

  let match = /^(?:archive|index|video|mono)-(\d+)-(now|\d+)\.(?:fmp4\.)?(?:m3u8|mp4)$/i.exec(mediaPath);
  if (match) {
    const externalFrom = Number(match[1]);
    const startMs = HIK_TIMELINE_CLOCK.timelineToUtcMs(externalFrom * 1000);
    if (match[2] === 'now') {
      if (Number.isFinite(startMs) && Date.now() > startMs) return { startMs, endMs: Date.now() };
    } else {
      const duration = Number(match[2]);
      if (Number.isFinite(startMs) && Number.isFinite(duration) && duration > 0) {
        return { startMs, endMs: startMs + duration * 1000 };
      }
    }
  }

  match = /^timeshift_abs-(\d+)(?:\.fmp4)?\.m3u8$/i.exec(mediaPath);
  if (match) {
    const startMs = HIK_TIMELINE_CLOCK.timelineToUtcMs(Number(match[1]) * 1000);
    if (Number.isFinite(startMs)) return { startMs, endMs: Date.now() };
  }
  match = /^timeshift_rel-(\d+)(?:\.fmp4)?\.m3u8$/i.exec(mediaPath);
  if (match) return { startMs: Date.now() - Number(match[1]) * 1000, endMs: Date.now() };
  return { startMs: Date.now() - 3600000, endMs: Date.now() };
}'''
    text = replace_once(text, old_parse, new_parse, 'archive window Moscow timeline conversion')

    text = replace_once(
        text,
        "  const requestedStartMs = Number.isFinite(fromRaw) && fromRaw > 0 ? fromRaw * 1000 : oldestAllowedMs;",
        "  const requestedStartMs = Number.isFinite(fromRaw) && fromRaw > 0\n    ? HIK_TIMELINE_CLOCK.timelineToUtcMs(fromRaw * 1000)\n    : oldestAllowedMs;",
        'recording status incoming timeline conversion',
    )

    text = replace_once(
        text,
        "    const ranges = value.ranges.filter((item) => item.from + item.duration >= requestedFrom);",
        "    const ranges = value.ranges\n      .filter((item) => item.from + item.duration >= requestedFrom)\n      .map((item) => ({\n        ...item,\n        from: Math.floor(HIK_TIMELINE_CLOCK.utcToTimelineMs(item.from * 1000) / 1000)\n      }));",
        'recording status outgoing timeline conversion',
    )

    text = replace_once(
        text,
        "      `#EXT-X-PROGRAM-DATE-TIME:${new Date(startMs).toISOString()}`,",
        "      `#EXT-X-PROGRAM-DATE-TIME:${HIK_TIMELINE_CLOCK.timelineIso(startMs)}`,",
        'virtual HLS program date timeline conversion',
    )

    text = replace_once(
        text,
        "      const targetMs = targetSec * 1000;",
        "      const targetMs = HIK_TIMELINE_CLOCK.timelineToUtcMs(targetSec * 1000);",
        'archive preview timeline conversion',
    )

    old_event_window = r'''function eventWindow(reqUrl) {
  const endRaw = reqUrl.searchParams.get('end') || reqUrl.searchParams.get('to');
  const startRaw = reqUrl.searchParams.get('start') || reqUrl.searchParams.get('from');
  const endMs = endRaw ? parseMoment(endRaw) : Date.now();
  const startMs = startRaw ? parseMoment(startRaw) : endMs - EVENT_DEFAULT_HOURS * 3600000;
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || startMs >= endMs) return null;
  if (endMs - startMs > EVENT_MAX_DAYS * 24 * 3600000) return null;
  return { startMs, endMs };
}'''
    new_event_window = r'''function eventWindow(reqUrl) {
  const endRaw = reqUrl.searchParams.get('end') || reqUrl.searchParams.get('to');
  const startRaw = reqUrl.searchParams.get('start') || reqUrl.searchParams.get('from');
  const externalEndMs = endRaw ? parseMoment(endRaw) : NaN;
  const externalStartMs = startRaw ? parseMoment(startRaw) : NaN;
  const endMs = endRaw ? HIK_TIMELINE_CLOCK.timelineToUtcMs(externalEndMs) : Date.now();
  const startMs = startRaw
    ? HIK_TIMELINE_CLOCK.timelineToUtcMs(externalStartMs)
    : endMs - EVENT_DEFAULT_HOURS * 3600000;
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || startMs >= endMs) return null;
  if (endMs - startMs > EVENT_MAX_DAYS * 24 * 3600000) return null;
  return { startMs, endMs };
}'''
    text = replace_once(text, old_event_window, new_event_window, 'event window timeline conversion')

    text = replace_once(
        text,
        "    const timestamp = Date.parse(String(item.occurred_at || item.created_at || ''));\n    if (!Number.isFinite(timestamp)) continue;",
        "    const timestamp = Date.parse(String(item.occurred_at || item.created_at || ''));\n    if (!Number.isFinite(timestamp)) continue;\n    const timelineTimestamp = HIK_TIMELINE_CLOCK.utcToTimelineMs(timestamp);",
        'event outgoing timeline timestamp',
    )
    text = replace_once(
        text,
        "      occurred_at: new Date(timestamp).toISOString(),\n      timestamp,",
        "      occurred_at: new Date(timelineTimestamp).toISOString(),\n      timestamp: timelineTimestamp,",
        'event public timestamp conversion',
    )

    # handleEvents has two response envelopes (summary and full events).
    text = text.replace(
        "      start: new Date(range.startMs).toISOString(),\n      end: new Date(range.endMs).toISOString(),",
        "      start: HIK_TIMELINE_CLOCK.timelineIso(range.startMs),\n      end: HIK_TIMELINE_CLOCK.timelineIso(range.endMs),",
    )
    text = text.replace(
        "    start: new Date(range.startMs).toISOString(),\n    end: new Date(range.endMs).toISOString(),",
        "    start: HIK_TIMELINE_CLOCK.timelineIso(range.startMs),\n    end: HIK_TIMELINE_CLOCK.timelineIso(range.endMs),",
    )

    text = replace_once(
        text,
        "        internal_secret_configured: Boolean(INTERNAL_SECRET)",
        "        internal_secret_configured: Boolean(INTERNAL_SECRET),\n        hikvision_timeline_timezone: HIK_TIMELINE_TIME_ZONE",
        'health timeline timezone',
    )

    if MARKER not in text or 'HIK_TIMELINE_CLOCK.timelineToUtcMs' not in text or 'HIK_TIMELINE_CLOCK.timelineIso' not in text:
        raise RuntimeError('Hikvision SmartYard timeline timezone markers are incomplete')
    path.write_text(text, encoding='utf-8')
    print(f'Hikvision SmartYard archive timeline now uses {"Europe/Moscow"} wall-clock compatibility by default')
    print('Hikvision node/HCNetSDK requests remain UTC; only the external SmartYard timeline is shifted')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--project-dir', default='.')
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    patch_gateway(root / 'smartyard-compat-proxy/server-hikvision-gateway.js')


if __name__ == '__main__':
    main()

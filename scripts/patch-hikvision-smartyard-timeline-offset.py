#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = 'v309-hikvision-smartyard-timeline-offset'


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
        print('Hikvision SmartYard timeline offset already prepared')
        return

    text = replace_once(text, "const { URL } = require('node:url');\n", "const { URL } = require('node:url');\nconst { createTimelineOffset } = require('./hikvision-timeline-offset.js');\n", 'offset helper import')
    anchor = "const VIRTUAL_ARCHIVE_MAX_SECONDS = Math.max(3600, Number(process.env.SMARTYARD_HIK_VIRTUAL_ARCHIVE_MAX_SECONDS || 21600));\n"
    text = replace_once(text, anchor, anchor + "const HIK_TIMELINE_OFFSET_SECONDS = Number(process.env.SMARTYARD_HIK_TIMELINE_OFFSET_SECONDS || -10800);\nconst HIK_TIMELINE_OFFSET = createTimelineOffset(HIK_TIMELINE_OFFSET_SECONDS);\nconst HIK_TIMELINE_OFFSET_MARKER = 'v309-hikvision-smartyard-timeline-offset';\n", 'offset constants')

    text = replace_once(text, "    const startMs = Date.parse(queryStart);\n    const endMs = Date.parse(queryEnd);", "    const startMs = HIK_TIMELINE_OFFSET.timelineToInternalMs(Date.parse(queryStart));\n    const endMs = HIK_TIMELINE_OFFSET.timelineToInternalMs(Date.parse(queryEnd));", 'query archive window conversion')
    text = replace_once(text, "    const from = Number(match[1]);\n    const duration = match[2] === 'now' ? Math.floor(Date.now() / 1000) - from : Number(match[2]);", "    const externalFrom = Number(match[1]);\n    const from = HIK_TIMELINE_OFFSET.timelineToInternalMs(externalFrom * 1000) / 1000;\n    const duration = match[2] === 'now' ? Math.floor(Date.now() / 1000) - from : Number(match[2]);", 'path archive window conversion')
    text = replace_once(text, "  if (match) return { startMs: Number(match[1]) * 1000, endMs: Date.now() };", "  if (match) return { startMs: HIK_TIMELINE_OFFSET.timelineToInternalMs(Number(match[1]) * 1000), endMs: Date.now() };", 'absolute timeshift conversion')
    text = replace_once(text, "  const requestedStartMs = Number.isFinite(fromRaw) && fromRaw > 0 ? fromRaw * 1000 : oldestAllowedMs;", "  const requestedStartMs = Number.isFinite(fromRaw) && fromRaw > 0\n    ? HIK_TIMELINE_OFFSET.timelineToInternalMs(fromRaw * 1000)\n    : oldestAllowedMs;", 'recording status incoming conversion')
    text = replace_once(text, "    const ranges = value.ranges.filter((item) => item.from + item.duration >= requestedFrom);", "    const ranges = value.ranges\n      .filter((item) => item.from + item.duration >= requestedFrom)\n      .map((item) => ({ ...item, from: Math.floor(HIK_TIMELINE_OFFSET.internalToTimelineMs(item.from * 1000) / 1000) }));", 'recording status outgoing conversion')
    text = replace_once(text, "      `#EXT-X-PROGRAM-DATE-TIME:${new Date(startMs).toISOString()}`,", "      `#EXT-X-PROGRAM-DATE-TIME:${HIK_TIMELINE_OFFSET.timelineIso(startMs)}`,", 'program date time conversion')
    text = replace_once(text, "      const targetMs = targetSec * 1000;", "      const targetMs = HIK_TIMELINE_OFFSET.timelineToInternalMs(targetSec * 1000);", 'preview conversion')
    text = replace_once(text, "  const endMs = endRaw ? parseMoment(endRaw) : Date.now();\n  const startMs = startRaw ? parseMoment(startRaw) : endMs - EVENT_DEFAULT_HOURS * 3600000;", "  const endMs = endRaw ? HIK_TIMELINE_OFFSET.timelineToInternalMs(parseMoment(endRaw)) : Date.now();\n  const startMs = startRaw ? HIK_TIMELINE_OFFSET.timelineToInternalMs(parseMoment(startRaw)) : endMs - EVENT_DEFAULT_HOURS * 3600000;", 'event incoming conversion')
    text = replace_once(text, "    const timestamp = Date.parse(String(item.occurred_at || item.created_at || ''));\n    if (!Number.isFinite(timestamp)) continue;", "    const timestamp = Date.parse(String(item.occurred_at || item.created_at || ''));\n    if (!Number.isFinite(timestamp)) continue;\n    const timelineTimestamp = HIK_TIMELINE_OFFSET.internalToTimelineMs(timestamp);", 'event timestamp conversion')
    text = replace_once(text, "      occurred_at: new Date(timestamp).toISOString(),\n      timestamp,", "      occurred_at: new Date(timelineTimestamp).toISOString(),\n      timestamp: timelineTimestamp,", 'event outgoing conversion')
    text = text.replace("      start: new Date(range.startMs).toISOString(),\n      end: new Date(range.endMs).toISOString(),", "      start: HIK_TIMELINE_OFFSET.timelineIso(range.startMs),\n      end: HIK_TIMELINE_OFFSET.timelineIso(range.endMs),")
    text = text.replace("    start: new Date(range.startMs).toISOString(),\n    end: new Date(range.endMs).toISOString(),", "    start: HIK_TIMELINE_OFFSET.timelineIso(range.startMs),\n    end: HIK_TIMELINE_OFFSET.timelineIso(range.endMs),")
    text = replace_once(text, "        internal_secret_configured: Boolean(INTERNAL_SECRET)", "        internal_secret_configured: Boolean(INTERNAL_SECRET),\n        hikvision_timeline_offset_seconds: HIK_TIMELINE_OFFSET_SECONDS", 'health offset marker')

    if MARKER not in text or 'HIK_TIMELINE_OFFSET.timelineToInternalMs' not in text or 'HIK_TIMELINE_OFFSET.timelineIso' not in text:
        raise RuntimeError('Hikvision timeline offset markers incomplete')
    path.write_text(text, encoding='utf-8')
    print('Hikvision SmartYard timeline subtracts 10800 seconds by default to match DVR wall-clock labels')
    print('Incoming seeks apply the inverse offset before Hik-node playback')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--project-dir', default='.')
    args = parser.parse_args()
    patch_gateway(Path(args.project_dir).resolve() / 'smartyard-compat-proxy/server-hikvision-gateway.js')


if __name__ == '__main__':
    main()

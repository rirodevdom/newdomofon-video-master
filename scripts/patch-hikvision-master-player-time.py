#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "v311-hikvision-master-player-timeline"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1)


def patch_player(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        return

    anchor = "const ARCHIVE_RANGE_MERGE_GAP_MS = 2000;\n"
    helpers = anchor + r'''
// v311-hikvision-master-player-timeline
// Hikvision DVR archive times on the production devices are encoded three
// hours ahead of the wall-clock overlay. The browser/player then renders an
// absolute epoch in local time, so the master boundary must expose node archive
// time minus three hours and apply the inverse before asking the node to seek.
const HIKVISION_MASTER_TIMELINE_OFFSET_SECONDS = Number(
  process.env.HIKVISION_TIMELINE_OFFSET_SECONDS
  ?? process.env.SMARTYARD_HIK_TIMELINE_OFFSET_SECONDS
  ?? -10800
);
const HIKVISION_MASTER_TIMELINE_OFFSET_MS = Math.trunc(HIKVISION_MASTER_TIMELINE_OFFSET_SECONDS * 1000);

function nodeArchiveMsToTimelineMs(value: number): number {
  return Number(value) + HIKVISION_MASTER_TIMELINE_OFFSET_MS;
}

function timelineMsToNodeArchiveMs(value: number): number {
  return Number(value) - HIKVISION_MASTER_TIMELINE_OFFSET_MS;
}

function timelineIsoToNodeArchiveIso(raw: string): string {
  const value = Date.parse(raw);
  if (!Number.isFinite(value)) throw Object.assign(new Error('Invalid Hikvision timeline timestamp'), { statusCode: 400 });
  return new Date(timelineMsToNodeArchiveMs(value)).toISOString();
}

function nodeArchiveIsoToTimelineIso(raw: string): string {
  const value = Date.parse(raw);
  if (!Number.isFinite(value)) return raw;
  return new Date(nodeArchiveMsToTimelineMs(value)).toISOString();
}

function archiveRangeToTimeline(item: ArchiveRangeItem): ArchiveRangeItem {
  return {
    ...item,
    start: nodeArchiveIsoToTimelineIso(item.start),
    end: nodeArchiveIsoToTimelineIso(item.end)
  };
}

function rewriteHikvisionArchiveProgramDateTime(playlist: string): string {
  return String(playlist || '').replace(
    /(#EXT-X-PROGRAM-DATE-TIME:)([^\r\n]+)/g,
    (_match, prefix: string, raw: string) => `${prefix}${nodeArchiveIsoToTimelineIso(String(raw).trim())}`
  );
}
'''
    text = replace_once(text, anchor, helpers, "Hikvision master timeline helpers")

    old_hls = r'''async function sendProxyHlsPlaylist(
  response: globalThis.Response,
  res: ExpressResponse,
  browserToken: string
): Promise<void> {
  const playlist = await response.text();
  const rewritten = rewriteHlsPlaylistBrowserToken(playlist, browserToken);'''
    new_hls = r'''async function sendProxyHlsPlaylist(
  response: globalThis.Response,
  res: ExpressResponse,
  browserToken: string,
  scope: MediaScope
): Promise<void> {
  const playlist = await response.text();
  const tokenRewritten = rewriteHlsPlaylistBrowserToken(playlist, browserToken);
  const rewritten = scope === 'archive'
    ? rewriteHikvisionArchiveProgramDateTime(tokenRewritten)
    : tokenRewritten;'''
    text = replace_once(text, old_hls, new_hls, "Hikvision archive HLS timeline rewrite")
    text = replace_once(
        text,
        "    await sendProxyHlsPlaylist(upstream, res, browserToken);",
        "    await sendProxyHlsPlaylist(upstream, res, browserToken, scope);",
        "Hikvision HLS scope propagation",
    )

    text = replace_once(
        text,
        "  const start = new Date(params.start);\n  const end = new Date(params.end);",
        "  const start = new Date(timelineMsToNodeArchiveMs(Date.parse(params.start)));\n  const end = new Date(timelineMsToNodeArchiveMs(Date.parse(params.end)));",
        "Hikvision archive range incoming timeline conversion",
    )
    text = replace_once(
        text,
        "    items: result.items,\n    source: channel.archive_storage,",
        "    items: result.items.map(archiveRangeToTimeline),\n    source: channel.archive_storage,",
        "Hikvision archive range outgoing timeline conversion",
    )

    text = replace_once(
        text,
        "    { method: 'POST', body: JSON.stringify({ start: params.start, end: params.end }) },",
        "    { method: 'POST', body: JSON.stringify({\n      start: timelineIsoToNodeArchiveIso(params.start),\n      end: timelineIsoToNodeArchiveIso(params.end)\n    }) },",
        "Hikvision archive seek incoming conversion",
    )
    text = replace_once(
        text,
        "  const url = proxyMediaUrl(channel.channel_external_id, 'archive/export.mp4', token, { start: params.start, end: params.end });",
        "  const url = proxyMediaUrl(channel.channel_external_id, 'archive/export.mp4', token, {\n    start: timelineIsoToNodeArchiveIso(params.start),\n    end: timelineIsoToNodeArchiveIso(params.end)\n  });",
        "Hikvision export incoming conversion",
    )
    text = replace_once(
        text,
        "    upstream_media_auth: 'agent-token-hash'\n  });",
        "    upstream_media_auth: 'agent-token-hash',\n    timeline_offset_seconds: HIKVISION_MASTER_TIMELINE_OFFSET_SECONDS\n  });",
        "Hikvision player timeline health field",
    )

    for required in (
        MARKER,
        "rewriteHikvisionArchiveProgramDateTime",
        "timelineIsoToNodeArchiveIso(params.start)",
        "result.items.map(archiveRangeToTimeline)",
    ):
        if required not in text:
            raise RuntimeError(f"Hikvision master player timeline marker missing: {required}")
    path.write_text(text, encoding="utf-8")


def patch_events(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if "v311-hikvision-master-events-timeline" in text:
        return

    anchor = "export const hikvisionEventsRouter = Router();\n"
    helpers = anchor + r'''

// v311-hikvision-master-events-timeline
const HIKVISION_EVENT_TIMELINE_OFFSET_SECONDS = Number(
  process.env.HIKVISION_TIMELINE_OFFSET_SECONDS
  ?? process.env.SMARTYARD_HIK_TIMELINE_OFFSET_SECONDS
  ?? -10800
);
const HIKVISION_EVENT_TIMELINE_OFFSET_MS = Math.trunc(HIKVISION_EVENT_TIMELINE_OFFSET_SECONDS * 1000);

function eventTimelineIsoToNodeIso(raw: string): string {
  const ms = Date.parse(raw);
  if (!Number.isFinite(ms)) return raw;
  return new Date(ms - HIKVISION_EVENT_TIMELINE_OFFSET_MS).toISOString();
}

function eventNodeIsoToTimelineIso(raw: string): string {
  const ms = Date.parse(raw);
  if (!Number.isFinite(ms)) return raw;
  return new Date(ms + HIKVISION_EVENT_TIMELINE_OFFSET_MS).toISOString();
}

function rewriteEventTimelineBody(raw: string): string {
  let payload: any;
  try { payload = raw ? JSON.parse(raw) : {}; } catch { return raw; }

  const rewriteItem = (item: any) => {
    if (!item || typeof item !== 'object') return item;
    const next = { ...item };
    if (typeof next.occurred_at === 'string') next.occurred_at = eventNodeIsoToTimelineIso(next.occurred_at);
    if (typeof next.created_at === 'string') next.created_at = eventNodeIsoToTimelineIso(next.created_at);
    if (Number.isFinite(Number(next.timestamp))) {
      const value = Number(next.timestamp);
      next.timestamp = Math.abs(value) >= 1e12
        ? value + HIKVISION_EVENT_TIMELINE_OFFSET_MS
        : value + HIKVISION_EVENT_TIMELINE_OFFSET_SECONDS;
    }
    return next;
  };

  if (Array.isArray(payload)) payload = payload.map(rewriteItem);
  if (Array.isArray(payload?.items)) payload.items = payload.items.map(rewriteItem);
  if (Array.isArray(payload?.events)) payload.events = payload.events.map(rewriteItem);
  return JSON.stringify(payload);
}
'''
    text = replace_once(text, anchor, helpers, "Hikvision event timeline helpers")

    text = replace_once(
        text,
        "    start: q.start,\n    end: q.end,",
        "    start: eventTimelineIsoToNodeIso(q.start),\n    end: eventTimelineIsoToNodeIso(q.end),",
        "Hikvision event incoming timeline conversion",
    )
    text = replace_once(
        text,
        "  return res.status(result.status).send(result.body);\n}));\n\nhikvisionEventsRouter.get('/:channelId/events/summary'",
        "  return res.status(result.status).send(rewriteEventTimelineBody(result.body));\n}));\n\nhikvisionEventsRouter.get('/:channelId/events/summary'",
        "Hikvision event outgoing timeline conversion",
    )
    text = replace_once(
        text,
        "  const result = await fetchEvents(target, '/summary', { start: q.start, end: q.end });",
        "  const result = await fetchEvents(target, '/summary', {\n    start: eventTimelineIsoToNodeIso(q.start),\n    end: eventTimelineIsoToNodeIso(q.end)\n  });",
        "Hikvision event summary incoming conversion",
    )
    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=".")
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    patch_player(root / "backend/src/routes/hikvisionPlayer.ts")
    patch_events(root / "backend/src/routes/hikvisionEvents.ts")
    print("Master Hikvision player now exposes DVR archive time in the browser wall-clock domain")
    print("Archive seek/export and events apply the inverse offset before calling Hikvision-node")


if __name__ == "__main__":
    main()

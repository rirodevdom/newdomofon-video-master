#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

MARKER = "newdomofon-hikvision-alertstream-events"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one source block, found {count}")
    return text.replace(old, new, 1)


def patch_view(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print("Hikvision player events already prepared")
        return

    old_events = "          events: { load: async () => [] },"
    new_events = r'''          // newdomofon-hikvision-alertstream-events
          events: {
            load: async (fromMs: number, toMs: number, signal?: AbortSignal) => {
              const { data } = await api.get(`${apiBase.value}/events`, {
                params: {
                  start: new Date(fromMs).toISOString(),
                  end: new Date(toMs).toISOString(),
                  limit: 5000
                },
                signal
              });
              return (data.items || []).map((item: any) => {
                const occurredAtMs = new Date(item.occurred_at || item.occurredAt || item.timestamp || item.time).getTime();
                const rawState = String(item.event_state ?? item.state ?? '').trim().toLowerCase();
                const state = ['active', 'true', '1', 'on', 'start'].includes(rawState)
                  ? true
                  : ['inactive', 'false', '0', 'off', 'stop'].includes(rawState)
                    ? false
                    : null;
                const type = item.event_type || item.type || item.topic || 'hikvision.event';
                return {
                  id: item.id,
                  occurredAtMs,
                  state,
                  type,
                  title: type,
                  source: item.source_name || item.source || 'hikvision.alertStream',
                  raw: item
                };
              }).filter((item: any) => Number.isFinite(item.occurredAtMs));
            }
          },'''
    text = replace_once(text, old_events, new_events, "Hikvision external events adapter")
    text = replace_once(
        text,
        "            events: false,",
        "            events: true,",
        "enable Hikvision player event capability",
    )

    for required in (
        MARKER,
        "`${apiBase.value}/events`",
        "events: true,",
        "source: item.source_name || item.source || 'hikvision.alertStream'",
    ):
        if required not in text:
            raise SystemExit(f"Hikvision event timeline marker missing: {required}")

    path.write_text(text, encoding="utf-8")
    print("Hikvision alertStream events are enabled on the player timeline")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=".")
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    patch_view(root / "frontend/src/views/HikvisionPlayerView.vue")


if __name__ == "__main__":
    main()

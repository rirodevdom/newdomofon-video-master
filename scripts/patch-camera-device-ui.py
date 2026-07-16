#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment, found {count}")
    return text.replace(old, new, 1)


def remove_once(text: str, fragment: str, label: str) -> str:
    count = text.count(fragment)
    if count == 0:
        return text
    if count != 1:
        raise RuntimeError(f"{label}: expected at most one source fragment, found {count}")
    return text.replace(fragment, "", 1)


def patch_player_view(path: Path) -> None:
    text = path.read_text(encoding="utf-8")

    old_status = '''        <v-card class="mb-4">
          <v-card-title>Статус</v-card-title>
          <v-card-text>
            <v-chip :color="status?.recording ? 'success' : 'error'">
              {{ status?.recording ? 'recording' : 'offline' }}
            </v-chip>
            <pre class="mt-4 status-json">{{ status }}</pre>
          </v-card-text>
        </v-card>'''
    new_status = '''        <v-card class="mb-4">
          <v-card-title>Статус камеры</v-card-title>
          <v-card-text>
            <v-chip
              size="large"
              variant="tonal"
              :color="status?.recording ? 'success' : 'error'"
              :prepend-icon="status?.recording ? 'mdi-check-circle' : 'mdi-alert-circle'"
            >
              {{ status?.recording ? 'Запись ведётся' : 'Запись не ведётся' }}
            </v-chip>
          </v-card-text>
        </v-card>'''
    text = replace_once(text, old_status, new_status, "camera status card")

    text = remove_once(
        text,
        '''.status-json {
  max-height: 280px;
  overflow: auto;
  white-space: pre-wrap;
  font-size: 12px;
}

''',
        "obsolete status JSON styles",
    )

    required = (
        "<v-card-title>Статус камеры</v-card-title>",
        "Запись ведётся",
        "Запись не ведётся",
    )
    missing = [marker for marker in required if marker not in text]
    if missing:
        raise RuntimeError(f"player status markers missing: {missing}")
    if "status-json" in text:
        raise RuntimeError("raw camera status JSON is still present")

    path.write_text(text, encoding="utf-8")


def patch_devices_view(path: Path) -> None:
    text = path.read_text(encoding="utf-8")

    text = replace_once(
        text,
        '''            <th>Название</th>
            <th>Тип</th>''',
        '''            <th>Название</th>
            <th>Комментарий</th>
            <th>Тип</th>''',
        "device comment table header",
    )

    text = replace_once(
        text,
        '''            <td>
              <div class="font-weight-medium">{{ device.name || '—' }}</div>
              <div v-if="!device.is_enabled" class="text-caption text-medium-emphasis">Устройство отключено</div>
            </td>
            <td>{{ device.connection_type }}</td>''',
        '''            <td>
              <div class="font-weight-medium">{{ device.name || '—' }}</div>
              <div v-if="!device.is_enabled" class="text-caption text-medium-emphasis">Устройство отключено</div>
            </td>
            <td
              class="device-comment-cell"
              style="min-width: 180px; max-width: 360px; white-space: pre-line; overflow-wrap: anywhere"
            >
              <span :class="{ 'text-medium-emphasis': !device.comment }">{{ device.comment || '—' }}</span>
            </td>
            <td>{{ device.connection_type }}</td>''',
        "device comment table cell",
    )

    text = replace_once(
        text,
        '<td colspan="7" class="text-center text-medium-emphasis py-6">Устройства не найдены</td>',
        '<td colspan="8" class="text-center text-medium-emphasis py-6">Устройства не найдены</td>',
        "device table empty-state colspan",
    )

    text = replace_once(
        text,
        "    [device.name, device.connection_type, device.node_name, device.host, device.rtsp_url]",
        "    [device.name, device.comment, device.connection_type, device.node_name, device.host, device.rtsp_url]",
        "device comment search",
    )

    required = (
        '<th>Комментарий</th>',
        'class="device-comment-cell"',
        "device.comment || '—'",
        "[device.name, device.comment, device.connection_type",
        'colspan="8"',
    )
    missing = [marker for marker in required if marker not in text]
    if missing:
        raise RuntimeError(f"device comment markers missing: {missing}")

    path.write_text(text, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    root = Path(args.project_dir).resolve()
    player_view = root / "frontend/src/views/PlayerView.vue"
    devices_view = root / "frontend/src/views/DevicesView.vue"

    missing = [str(path) for path in (player_view, devices_view) if not path.is_file()]
    if missing:
        raise SystemExit(f"frontend source files are missing: {', '.join(missing)}")

    patch_player_view(player_view)
    patch_devices_view(devices_view)
    print(f"Camera status and device comment UI patch applied under {root}")


if __name__ == "__main__":
    main()

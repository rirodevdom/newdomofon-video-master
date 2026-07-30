#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    if old not in text:
        raise RuntimeError(f"{label} anchor was not found")
    return text.replace(old, new, 1), True


def patch_dashboard(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    old = """  if (row.connection_type === 'RTSP') return Boolean(row.rtsp_url || row.host);
  if (row.connection_type === 'ONVIF') return Boolean(row.host && row.port);
  return false;
"""
    new = """  if (row.connection_type === 'RTSP') return Boolean(row.rtsp_url || row.host);
  if (row.connection_type === 'ONVIF') return Boolean(row.host && row.port);
  if (row.connection_type === 'HIKVISION') return Boolean(row.host && row.port && row.dvr_server_id);
  return false;
"""
    patched, changed = replace_once(text, old, new, "dashboard Hikvision configured state")
    if changed:
        path.write_text(patched, encoding="utf-8")
    return changed


def patch_devices_view(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    old = """watch(() => form.connection_type, (value, previous) => {
  if (value === previous) return;
  form.dvr_server_id = null;
"""
    new = """watch(() => form.connection_type, (value, previous) => {
  if (value === previous) return;
  const editingDevice = editingId.value
    ? devices.value.find((device) => device.id === editingId.value)
    : null;
  // Object.assign() hydrates the edit form reactively. Do not interpret that
  // initial assignment as a user-requested type change and erase saved fields.
  if (editingDevice && value === editingDevice.connection_type) return;
  form.dvr_server_id = null;
"""
    patched, changed = replace_once(text, old, new, "Hikvision edit-form hydration guard")
    if changed:
        path.write_text(patched, encoding="utf-8")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default=str(Path(__file__).resolve().parents[1]))
    args = parser.parse_args()

    project = Path(args.project_dir).resolve()
    dashboard = project / "backend/src/routes/dashboard.ts"
    devices_view = project / "frontend/src/views/DevicesView.vue"
    for path in (dashboard, devices_view):
        if not path.is_file():
            raise SystemExit(f"Required source file not found: {path}")

    changed: list[str] = []
    if patch_dashboard(dashboard):
        changed.append(str(dashboard.relative_to(project)))
    if patch_devices_view(devices_view):
        changed.append(str(devices_view.relative_to(project)))

    print("Hikvision device settings persistence prepared")
    if changed:
        for item in changed:
            print(f"  changed: {item}")
    else:
        print("  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

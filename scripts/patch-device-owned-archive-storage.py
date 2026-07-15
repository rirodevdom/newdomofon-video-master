#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(path: Path, old: str, new: str, label: str) -> bool:
    text = path.read_text(encoding="utf-8")
    if new in text:
        return False
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source fragment in {path}, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()

    backend_managed = root / "backend/src/routes/managedAdminPlayer.ts"
    backend_player = root / "backend/src/routes/player.ts"
    frontend_player = root / "frontend/src/views/PlayerView.vue"

    for path in (backend_managed, backend_player, frontend_player):
        if not path.is_file():
            raise SystemExit(f"Required source file is missing: {path}")

    old_backend = """function effectiveArchiveStorage(row: ManagedPlayerRow): 'node' | 'device' | 'both' {
  if (row.device_archive_storage === 'both') return 'both';
  return row.archive_storage || row.device_archive_storage || 'node';
}"""
    new_backend = """function effectiveArchiveStorage(row: ManagedPlayerRow): 'node' | 'device' | 'both' {
  // Migration 092 makes the parent device the source of truth for placement and
  // archive policy. Keep the camera field only as a compatibility fallback.
  return row.device_archive_storage || row.archive_storage || 'node';
}"""

    old_legacy = """function effectiveArchiveStorage(camera: CameraWithNode): 'node' | 'device' | 'both' {
  if (camera.device_archive_storage === 'both') return 'both';
  return camera.archive_storage || camera.device_archive_storage || 'node';
}"""
    new_legacy = """function effectiveArchiveStorage(camera: CameraWithNode): 'node' | 'device' | 'both' {
  // The parent device owns archive policy; cameras inherit it through migration
  // 092. Use the camera column only for compatibility with older databases.
  return camera.device_archive_storage || camera.archive_storage || 'node';
}"""

    old_frontend = """const archiveStorage = computed<ArchiveStorage>(() => {
  const deviceStorage = normalizeArchiveStorage(camera.value?.device_archive_storage);
  if (deviceStorage === 'both') return 'both';
  return normalizeArchiveStorage(camera.value?.archive_storage || camera.value?.device_archive_storage);
});"""
    new_frontend = """const archiveStorage = computed<ArchiveStorage>(() => {
  const deviceStorage = camera.value?.device_archive_storage;
  if (deviceStorage === 'node' || deviceStorage === 'device' || deviceStorage === 'both') return deviceStorage;
  return normalizeArchiveStorage(camera.value?.archive_storage);
});"""

    changed: list[str] = []
    if replace_once(backend_managed, old_backend, new_backend, "managed player archive policy"):
        changed.append(str(backend_managed.relative_to(root)))
    if replace_once(backend_player, old_legacy, new_legacy, "legacy player archive policy"):
        changed.append(str(backend_player.relative_to(root)))
    if replace_once(frontend_player, old_frontend, new_frontend, "frontend archive policy"):
        changed.append(str(frontend_player.relative_to(root)))

    print("Device-owned archive policy patch applied")
    if changed:
        for item in changed:
            print(f"  changed: {item}")
    else:
        print("  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

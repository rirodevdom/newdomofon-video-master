#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

RUNTIME_BLOCK = '''RUNTIME_GROUP="${NEWD...:-}"
if [[ -z "$RUNTIME_GROUP" ]]; then
  if getent group newdomofon >/dev/null 2>&1; then
    RUNTIME_GROUP=newdomofon
  else
    RUNTIME_GROUP=root
  fi
fi
'''


def patch_rtsp_installer(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    original = text

    # Keep compatibility with installations that still have the historical
    # group, but make root-only masters the default when it is absent.
    if 'RUNTIME_GROUP="${NEWD...:-}"' not in text:
        anchor = 'BACKUP="/opt/newdomofon-video-migration-backups/rtsp-gateway-$STAMP"\n'
        if anchor not in text:
            raise RuntimeError(f"RTSP runtime-group anchor not found in {path}")
        text = text.replace(anchor, anchor + "\n" + RUNTIME_BLOCK, 1)

    replacements = {
        '-g newdomofon': '-g "$RUNTIME_GROUP"',
        'chown root:newdomofon ': 'chown "root:$RUNTIME_GROUP" ',
    }
    for old, new in replacements.items():
        text = text.replace(old, new)

    forbidden = ('-g newdomofon', 'chown root:newdomofon ')
    leftovers = [item for item in forbidden if item in text]
    if leftovers:
        raise RuntimeError(f"Hard-coded runtime group remains in {path}: {leftovers}")

    if text != original:
        path.write_text(text, encoding="utf-8")
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Make master runtime installers work without a newdomofon OS user/group."
    )
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    project = Path(args.project_dir).expanduser().resolve()
    installer = project / "scripts" / "install-rtsp-gateway.sh"
    if not installer.is_file():
        raise SystemExit(f"RTSP installer not found: {installer}")

    changed = patch_rtsp_installer(installer)
    print("Root-only master runtime compatibility prepared")
    print("  changed: scripts/install-rtsp-gateway.sh" if changed else "  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

OLD = "const DEFAULT_RANGE_DAYS = Math.max(1, Math.min(31, Number(process.env.SMARTYARD_DEFAULT_RANGE_DAYS || 30)));\n"
NEW = """// RBT asks recording_status.json with a historical `from` value and expects the
// gateway to return every actually available archive range. Never let a stale
// production env shrink that compatibility horizon below the supported 14-day
// retention used by the deployment. A larger value is still allowed up to the
// node /archive/ranges limit.
const DEFAULT_RANGE_DAYS_RAW = Number(process.env.SMARTYARD_DEFAULT_RANGE_DAYS || 30);
const DEFAULT_RANGE_DAYS = Number.isFinite(DEFAULT_RANGE_DAYS_RAW)
  ? Math.max(14, Math.min(31, DEFAULT_RANGE_DAYS_RAW))
  : 30;
"""
MARKER = "Math.max(14, Math.min(31, DEFAULT_RANGE_DAYS_RAW))"


def patch_gateway(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        return False
    if OLD not in text:
        raise RuntimeError("SmartYard range horizon anchor was not found")
    text = text.replace(OLD, NEW, 1)
    if MARKER not in text:
        raise RuntimeError("SmartYard 14-day range horizon marker was not installed")
    path.write_text(text, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    project = Path(args.project_dir).resolve()
    gateway = project / "smartyard-compat-proxy" / "server-node-aware.js"
    if not gateway.is_file():
        raise SystemExit(f"SmartYard node-aware gateway source not found: {gateway}")

    changed = patch_gateway(gateway)
    print("SmartYard archive range horizon prepared")
    print("  changed: smartyard-compat-proxy/server-node-aware.js" if changed else "  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

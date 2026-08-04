#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

OLD = "const DEFAULT_RANGE_DAYS = Math.max(1, Math.min(31, Number(process.env.SMARTYARD_DEFAULT_RANGE_DAYS || 30)));\n"
NEW = """// RBT asks recording_status.json with a historical `from` value and expects the
// gateway to return every actually available archive range. The compatibility
// default follows the 14-day retention used by the cameras in this deployment;
// an explicit larger value is still allowed up to the node ranges limit.
const DEFAULT_RANGE_DAYS_RAW = Number(process.env.SMARTYARD_DEFAULT_RANGE_DAYS || 14);
const DEFAULT_RANGE_DAYS = Number.isFinite(DEFAULT_RANGE_DAYS_RAW)
  ? Math.max(14, Math.min(31, DEFAULT_RANGE_DAYS_RAW))
  : 14;
"""
MARKER = "Math.max(14, Math.min(31, DEFAULT_RANGE_DAYS_RAW))"


def patch_gateway(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        # Upgrade the first version of this patch, which still defaulted to 30
        # days. This keeps repeated archive updates idempotent while allowing the
        # compatibility default to track the actual 14-day retention policy.
        upgraded = text.replace(
            "Number(process.env.SMARTYARD_DEFAULT_RANGE_DAYS || 30)",
            "Number(process.env.SMARTYARD_DEFAULT_RANGE_DAYS || 14)",
            1,
        ).replace("  : 30;", "  : 14;", 1)
        if upgraded != text:
            path.write_text(upgraded, encoding="utf-8")
            return True
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

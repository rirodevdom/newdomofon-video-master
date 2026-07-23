#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

OLD_EXPORT_FETCH = "    const response = await nodeFetch(context, path, req, 120000);\n"
NEW_EXPORT_FETCH = "    const exportTimeoutMs = Math.max(120000, Number(process.env.SMARTYARD_EXPORT_TIMEOUT_MS || 15 * 60 * 1000));\n    const response = await nodeFetch(context, path, req, exportTimeoutMs);\n"


def patch_gateway(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")

    if NEW_EXPORT_FETCH in text:
        if text.count(NEW_EXPORT_FETCH) != 1:
            raise RuntimeError("unexpected SmartYard export-timeout block count")
        return False

    count = text.count(OLD_EXPORT_FETCH)
    if count != 1:
        raise RuntimeError(f"SmartYard export fetch anchor count={count}")

    text = text.replace(OLD_EXPORT_FETCH, NEW_EXPORT_FETCH, 1)
    path.write_text(text, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Allow the unmodified SmartYard server enough time to receive a prepared MP4 from the assigned node."
    )
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    project = Path(args.project_dir).resolve()
    gateway = project / "smartyard-compat-proxy" / "server-node-aware.js"
    if not gateway.is_file():
        raise SystemExit(f"SmartYard node-aware gateway not found: {gateway}")

    changed = patch_gateway(gateway)
    print("SmartYard server-side export timeout prepared" if changed else "SmartYard server-side export timeout already prepared")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

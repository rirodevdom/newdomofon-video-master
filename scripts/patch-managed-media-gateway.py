#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys

CAMERA_PREFIX_LINE = "  if (rest.startsWith('cameras/')) rest = rest.slice('cameras/'.length);\n"
PATH_FILES = (
    "server-node-aware.js",
    "server-events-gateway.js",
    "server-preview-gateway.js",
    "server-formats-gateway.js",
)


def patch_camera_prefix(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    if CAMERA_PREFIX_LINE in text:
        return False

    anchors = (
        "  if (rest.startsWith('dvr-archive/')) rest = rest.slice('dvr-archive/'.length);\n",
        "  if (rest.startsWith('api/dvr-archive/')) rest = rest.slice('api/dvr-archive/'.length);\n",
        "  if (rest.startsWith('api/media/')) rest = rest.slice('api/media/'.length);\n",
    )
    for anchor in anchors:
        if anchor in text:
            text = text.replace(anchor, anchor + CAMERA_PREFIX_LINE, 1)
            path.write_text(text, encoding="utf-8")
            return True

    raise RuntimeError(f"camera-prefix anchor not found in {path}")


def patch_node_resolver(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    old_resolver = """    if (!response.ok) return null;
    const payload = await response.json();
    if (!payload?.ok || !payload?.node?.url || !payload?.upstream_token) return null;
    return payload;
"""
    new_resolver = """    const raw = await response.text();
    let payload;
    try { payload = raw ? JSON.parse(raw) : {}; } catch { payload = { error: raw || `Resolver HTTP ${response.status}` }; }
    if (!response.ok) return { error_status: response.status, error_body: payload };
    if (!payload?.ok || !payload?.node?.url || !payload?.upstream_token) {
      return { error_status: 502, error_body: { error: 'Invalid SmartYard resolver response' } };
    }
    return payload;
"""
    if old_resolver in text:
        text = text.replace(old_resolver, new_resolver, 1)
        changed = True

    old_handle = """    const externalToken = extractToken(req, reqUrl);
    const context = await resolveSmartYardToken(externalToken, stream);
    if (!context) return proxyLegacy(req, res);

    const handled = await handleNodeRequest(req, res, context, stream, mediaPath, reqUrl, externalToken);
"""
    new_handle = """    const externalToken = extractToken(req, reqUrl);
    const context = await resolveSmartYardToken(externalToken, stream);
    const managedToken = externalToken.startsWith('m1.') || externalToken.startsWith('mct1.');
    if (!context) {
      if (managedToken) return sendJson(res, 502, { error: 'Managed-token resolver unavailable' }, {
        'x-newdomofon-smartyard-route': 'managed-resolver-error'
      });
      return proxyLegacy(req, res);
    }
    if (context.error_status) {
      return sendJson(res, context.error_status, context.error_body || { error: 'Managed token rejected' }, {
        'x-newdomofon-smartyard-route': 'managed-resolver-rejected'
      });
    }

    const handled = await handleNodeRequest(req, res, context, stream, mediaPath, reqUrl, externalToken);
"""
    if old_handle in text:
        text = text.replace(old_handle, new_handle, 1)
        changed = True

    if changed:
        path.write_text(text, encoding="utf-8")
    return changed


def run_patch(project: Path, filename: str) -> None:
    patch = project / "scripts" / filename
    if not patch.is_file():
        raise SystemExit(f"Required patch not found: {patch}")
    subprocess.run(
        [sys.executable, str(patch), "--project-dir", str(project)],
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-dir", default="/opt/newdomofon-video-master")
    args = parser.parse_args()

    project = Path(args.project_dir).resolve()
    gateway_dir = project / "smartyard-compat-proxy"
    if not gateway_dir.is_dir():
        raise SystemExit(f"Gateway directory not found: {gateway_dir}")

    changed_files: list[str] = []
    for filename in PATH_FILES:
        path = gateway_dir / filename
        if not path.is_file():
            raise SystemExit(f"Gateway source not found: {path}")
        if patch_camera_prefix(path):
            changed_files.append(str(path.relative_to(project)))

    node_aware = gateway_dir / "server-node-aware.js"
    if patch_node_resolver(node_aware) and str(node_aware.relative_to(project)) not in changed_files:
        changed_files.append(str(node_aware.relative_to(project)))

    # The archive-ranges patch uses the original archivePlaylist declaration as
    # its insertion anchor. Apply it before replacing that declaration with the
    # wider Flussonic/fMP4-compatible aliases. All patchers remain idempotent.
    run_patch(project, "patch-archive-playback-window.py")
    run_patch(project, "patch-archive-seek-navigation.py")
    run_patch(project, "patch-smartyard-flussonic-compat.py")
    run_patch(project, "patch-smartyard-server-export-timeout.py")

    print("Managed media gateway patch applied")
    if changed_files:
        for item in changed_files:
            print(f"  changed: {item}")
    else:
        print("  already up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

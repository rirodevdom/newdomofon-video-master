#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def patch_runtime(path: Path) -> bool:
    text = path.read_text(encoding='utf-8')
    start = text.find('  const camera = managedResult?.rows[0];')
    if start < 0:
        return False
    end_marker = "\n  if (managedPayload) return res.status(403).json({ error: 'Token is not assigned to this camera' });"
    end = text.find(end_marker, start)
    if end < 0:
        raise RuntimeError('managed resolver block end marker not found')
    block = text[start:end]
    block = block.replace('const camera = managedResult?.rows[0];', 'const managedCamera = managedResult?.rows[0];', 1)
    block = block.replace('camera.', 'managedCamera.')
    block = block.replace('if (camera)', 'if (managedCamera)', 1)
    block = block.replace('      camera,\n', '      managedCamera,\n', 1)
    text = text[:start] + block + text[end:]
    path.write_text(text, encoding='utf-8')
    return True


def patch_generator(path: Path) -> bool:
    text = path.read_text(encoding='utf-8')
    old = '''  const camera = managedResult?.rows[0];
  if (camera) {
    if (!camera.managed_token_active) return res.status(401).json({ error: 'Managed token is disabled' });'''
    new = '''  const managedCamera = managedResult?.rows[0];
  if (managedCamera) {
    if (!managedCamera.managed_token_active) return res.status(401).json({ error: 'Managed token is disabled' });'''
    if new in text:
        return False
    if old not in text:
        raise RuntimeError('generator managed resolver start marker not found')
    text = text.replace(old, new, 1)
    marker = "  if (managedPayload) return res.status(403).json({ error: 'Token is not assigned to this camera' });"
    start = text.find(new)
    end = text.find(marker, start)
    if end < 0:
        raise RuntimeError('generator managed resolver end marker not found')
    block = text[start:end]
    block = block.replace('camera.', 'managedCamera.')
    block = block.replace('      camera,\n', '      managedCamera,\n', 1)
    text = text[:start] + block + text[end:]
    path.write_text(text, encoding='utf-8')
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--project-dir', default='/opt/newdomofon-video-master')
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    changed = []
    runtime = root / 'backend/src/routes/internalSmartYard.ts'
    generator = root / 'scripts/patch-manual-auto-managed-tokens.py'
    if patch_runtime(runtime):
        changed.append(str(runtime.relative_to(root)))
    if patch_generator(generator):
        changed.append(str(generator.relative_to(root)))
    print('Managed resolver variable collision fix applied')
    for item in changed:
        print(f'  changed: {item}')
    if not changed:
        print('  already up to date')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

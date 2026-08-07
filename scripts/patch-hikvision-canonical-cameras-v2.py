#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--project-dir', default='.')
    args = parser.parse_args()
    root = Path(args.project_dir).resolve()
    implementation = root / 'scripts/patch-hikvision-canonical-cameras.py'

    spec = importlib.util.spec_from_file_location('hikvision_canonical_impl', implementation)
    if spec is None or spec.loader is None:
        raise RuntimeError('Unable to load canonical Hikvision camera materializer')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    original_replace_once = module.replace_once

    def replace_compatible(text: str, old: str, new: str, label: str) -> str:
        if label == 'managed canonical Hikvision resolver query':
            # Manual and generated managed-token resolvers intentionally contain
            # the same SELECT shape. Both must resolve a canonical Hikvision
            # camera through hikvision_node_channels.camera_id.
            count = text.count(old)
            if count == 0:
                if new in text:
                    return text
                raise RuntimeError(f'{label}: expected one or more managed resolver fragments, found 0')
            return text.replace(old, new)
        return original_replace_once(text, old, new, label)

    module.replace_once = replace_compatible

    module.patch_node_agent(root / 'backend/src/routes/nodeAgent.ts')
    module.patch_cameras(root / 'backend/src/routes/cameras.ts')
    module.patch_devices(root / 'backend/src/routes/devices.ts')
    module.patch_managed_tokens(root / 'backend/src/routes/managedCameraTokens.ts')
    module.patch_internal_resolver(root / 'backend/src/routes/internalSmartYard.ts')

    print('Hikvision discovery now maintains canonical cameras with ordinary master functionality')
    print('Both generated and manual managed tokens resolve canonical Hikvision cameras through Hikvision-node')


if __name__ == '__main__':
    main()

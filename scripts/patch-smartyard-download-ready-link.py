#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path

HELPER_IMPORT = '''import {
  prepareSmartYardRecordingDownload,
  showSmartYardDownloadError,
  showSmartYardDownloadPending,
  showSmartYardDownloadReady,
} from "@/lib/smartYardRecordingDownload";
'''

ORIGINAL_HANDLER = '''const downloadHandler = async () => {
  const from = dayjs(range.date).add(downloadStart.value, "second").format("YYYY-MM-DD HH:mm:ss");
  const to = dayjs(range.date).add(downloadEnd.value, "second").format("YYYY-MM-DD HH:mm:ss");

  showSmartYardDownloadPending();
  try {
    const url = await prepareSmartYardRecordingDownload({
      apiGet: api.get,
      cameraId: camera.id,
      from,
      to,
    });
    showSmartYardDownloadReady(url);
  } catch (error) {
    showSmartYardDownloadError(error);
  }
}
'''

CUSTOM_HANDLER = '''const startSmartYardDownload = async (
  camera: Camera,
  apiGet: ApiGet,
  fromMs: number,
  toMs: number,
  notifyDownloadStarted?: () => void,
  signal?: AbortSignal,
): Promise<void> => {
  if (signal?.aborted) return;

  const from = dayjs(fromMs).format("YYYY-MM-DD HH:mm:ss");
  const to = dayjs(toMs).format("YYYY-MM-DD HH:mm:ss");

  notifyRecordingPreparation(notifyDownloadStarted);
  showSmartYardDownloadPending();

  try {
    const url = await prepareSmartYardRecordingDownload({
      apiGet,
      cameraId: camera.id,
      from,
      to,
      signal,
    });
    showSmartYardDownloadReady(url);
  } catch (error) {
    if (signal?.aborted) return;
    showSmartYardDownloadError(error);
    throw error;
  }
};
'''


def backup_file(project: Path, file: Path, backup_root: Path) -> None:
    relative = file.relative_to(project)
    target = backup_root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(file, target)


def add_helper_import(text: str) -> tuple[str, bool]:
    if '@/lib/smartYardRecordingDownload' in text:
        return text, False

    matches = list(re.finditer(r'^import .*?;\s*$', text, flags=re.MULTILINE))
    if not matches:
        raise RuntimeError('TypeScript import anchor was not found')

    end = matches[-1].end()
    return text[:end] + '\n' + HELPER_IMPORT.rstrip() + text[end:], True


def patch_original(path: Path) -> bool:
    text = path.read_text(encoding='utf-8')
    original = text
    text, _ = add_helper_import(text)

    text = re.sub(r'^import \{usePushStore\} from "@/store/push\.ts";\s*\n', '', text, flags=re.MULTILINE)
    text = re.sub(r'^import useLocale from "@/hooks/useLocale\.ts";\s*\n', '', text, flags=re.MULTILINE)
    text = re.sub(r'^const push = usePushStore\(\)\s*\n', '', text, flags=re.MULTILINE)
    text = re.sub(r'^const \{t\} = useLocale\(\);\s*\n', '', text, flags=re.MULTILINE)

    pattern = re.compile(
        r'const downloadHandler = (?:async )?\(\) => \{.*?\n\}\s*(?=</script>)',
        flags=re.DOTALL,
    )
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise RuntimeError(f'original CustomControls download handler count={len(matches)}')
    text = pattern.sub(ORIGINAL_HANDLER.rstrip() + '\n', text, count=1)

    if text.count('prepareSmartYardRecordingDownload({') != 1:
        raise RuntimeError('original download preparation helper was not installed exactly once')

    if text != original:
        path.write_text(text, encoding='utf-8')
        return True
    return False


def patch_custom(path: Path) -> bool:
    text = path.read_text(encoding='utf-8')
    original = text
    text, _ = add_helper_import(text)

    pattern = re.compile(
        r'const startSmartYardDownload = async \(.*?\n\};\s*\n(?=export const createSmartYardPlayerConfig)',
        flags=re.DOTALL,
    )
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise RuntimeError(f'custom SmartYard download handler count={len(matches)}')
    text = pattern.sub(CUSTOM_HANDLER.rstrip() + '\n\n', text, count=1)

    if text.count('prepareSmartYardRecordingDownload({') != 1:
        raise RuntimeError('custom download preparation helper was not installed exactly once')

    if text != original:
        path.write_text(text, encoding='utf-8')
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description='Make SmartYard download readiness visible in original and integrated frontends.'
    )
    parser.add_argument('--project-dir', required=True, help='SmartYard-Vue source directory')
    parser.add_argument('--no-backup', action='store_true')
    args = parser.parse_args()

    script_project = Path(__file__).resolve().parents[1]
    helper_source = (
        script_project
        / 'integrations'
        / 'smartyard-vue'
        / 'download-ready-link'
        / 'smartYardRecordingDownload.ts'
    )
    if not helper_source.is_file():
        raise SystemExit(f'Bundled helper not found: {helper_source}')

    project = Path(args.project_dir).expanduser().resolve()
    source_dir = project / 'src'
    if not source_dir.is_dir():
        raise SystemExit(f'SmartYard src directory not found: {source_dir}')

    original_file = source_dir / 'components' / 'CustomControls.vue'
    custom_file = source_dir / 'lib' / 'smartyardPlayerKit.ts'
    helper_target = source_dir / 'lib' / 'smartYardRecordingDownload.ts'

    targets = [file for file in (original_file, custom_file) if file.is_file()]
    if not targets:
        raise SystemExit('Neither original CustomControls.vue nor custom smartyardPlayerKit.ts was found')

    stamp = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')
    backup_root = project / '.newdomofon-backups' / f'smartyard-download-ready-link-{stamp}'
    if not args.no_backup:
        for file in [*targets, *([helper_target] if helper_target.exists() else [])]:
            backup_file(project, file, backup_root)

    helper_target.parent.mkdir(parents=True, exist_ok=True)
    helper_content = helper_source.read_text(encoding='utf-8')
    helper_changed = not helper_target.exists() or helper_target.read_text(encoding='utf-8') != helper_content
    if helper_changed:
        helper_target.write_text(helper_content, encoding='utf-8')

    changed: list[str] = []
    if original_file.is_file() and patch_original(original_file):
        changed.append(str(original_file.relative_to(project)))
    if custom_file.is_file() and patch_custom(custom_file):
        changed.append(str(custom_file.relative_to(project)))
    if helper_changed:
        changed.append(str(helper_target.relative_to(project)))

    print('SmartYard download-ready link patch completed')
    print('Detected modes:', ', '.join(
        mode for mode, file in [('original', original_file), ('custom-player', custom_file)] if file.is_file()
    ))
    print('Changed files:', ', '.join(changed) if changed else 'none (already patched)')
    if not args.no_backup:
        print('Backup:', backup_root)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

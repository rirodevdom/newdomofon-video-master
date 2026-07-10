#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${SMARTYARD_VUE_DIR:-${1:-/opt/rbt/SmartYard-Vue}}"
MASTER_DIR="${NEWDOMOFON_MASTER_DIR:-/opt/newdomofon-video-master}"
SOURCE_COMPONENT="$MASTER_DIR/integrations/smartyard-vue/CameraMotionEvents.vue"
VIDEO_MODAL="$PROJECT_DIR/src/components/VideoModal.vue"
TARGET_COMPONENT="$PROJECT_DIR/src/components/CameraMotionEvents.vue"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${SMARTYARD_VUE_BACKUP_DIR:-$PROJECT_DIR/.newdomofon-backups/camera-events-$STAMP}"

for cmd in python3 install cp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd" >&2; exit 2; }
done

[[ -d "$PROJECT_DIR/src/components" ]] || {
  echo "SmartYard-Vue source directory not found: $PROJECT_DIR" >&2
  exit 2
}
[[ -f "$VIDEO_MODAL" ]] || {
  echo "VideoModal.vue not found: $VIDEO_MODAL" >&2
  exit 2
}
[[ -f "$SOURCE_COMPONENT" ]] || {
  echo "Integration component not found: $SOURCE_COMPONENT" >&2
  exit 2
}

install -d -m 0750 "$BACKUP_DIR"
cp -a "$VIDEO_MODAL" "$BACKUP_DIR/VideoModal.vue.before"
if [[ -f "$TARGET_COMPONENT" ]]; then
  cp -a "$TARGET_COMPONENT" "$BACKUP_DIR/CameraMotionEvents.vue.before"
fi

install -m 0644 "$SOURCE_COMPONENT" "$TARGET_COMPONENT"

python3 - "$VIDEO_MODAL" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
original = text

import_line = 'import CameraMotionEvents from "@/components/CameraMotionEvents.vue";'
if import_line not in text:
    anchor = 'import SpeedControl from "@/components/SpeedControl.vue";'
    if anchor not in text:
        raise SystemExit("VideoModal import anchor was not found")
    text = text.replace(anchor, anchor + "\n" + import_line, 1)

handler = '''
const openCameraEvent = (timestamp: number) => {
  const from = Math.max(0, Math.floor(timestamp / 1000) - 10);
  currentRange.value = {
    from,
    duration: 30,
    date: new Date(from * 1000),
    streamUrl: camera.url,
  };
  isOpenInfo.value = false;
};
'''.strip()

if 'const openCameraEvent = ' not in text:
    anchor = 'onMounted(() => {'
    if anchor not in text:
        raise SystemExit("VideoModal onMounted anchor was not found")
    text = text.replace(anchor, handler + "\n\n" + anchor, 1)

component = '''
        <CameraMotionEvents
          :camera="camera"
          :range="currentRange"
          @select="openCameraEvent"
        />
'''.rstrip()

if '<CameraMotionEvents' not in text:
    anchor = '        <RangeSelect :camera="camera" v-model:modelValue="currentRange"/>'
    if anchor not in text:
        anchor = '        <RangeSelect :camera="camera" v-model:modelValue="currentRange" />'
    if anchor not in text:
        raise SystemExit("VideoModal RangeSelect anchor was not found")
    text = text.replace(anchor, anchor + "\n" + component, 1)

if text == original:
    print("VideoModal.vue already patched")
else:
    path.write_text(text, encoding="utf-8")
    print("VideoModal.vue patched")
PY

if command -v npm >/dev/null 2>&1 && [[ "${SMARTYARD_VUE_BUILD:-0}" == "1" ]]; then
  (
    cd "$PROJECT_DIR"
    npm ci --include=dev
    npm run build
  )
fi

echo
printf 'SMARTYARD VUE CAMERA EVENTS PATCHED\n'
printf 'Project: %s\n' "$PROJECT_DIR"
printf 'Backup:  %s\n' "$BACKUP_DIR"
printf 'Build:   %s\n' "${SMARTYARD_VUE_BUILD:-0}"

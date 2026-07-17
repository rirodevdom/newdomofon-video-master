#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

require_file() {
  local path="$1"
  [[ -f "$path" ]] || {
    echo "Required frontend source preparer is missing: $path" >&2
    exit 1
  }
}

MANUAL_AUTO_PATCH="$PROJECT_DIR/scripts/patch-manual-auto-managed-tokens.py"
SYSTEM_TOKEN_UI_PATCH="$PROJECT_DIR/scripts/patch-system-managed-token-ui.py"
AUTO_ASSIGN_ALL_UI_PATCH="$PROJECT_DIR/scripts/patch-auto-assign-all-cameras-ui.py"
CAMERA_DEVICE_UI_PATCH="$PROJECT_DIR/scripts/patch-camera-device-ui.py"
CAMERA_TOKEN_WORKFLOW_PATCH="$PROJECT_DIR/scripts/patch-camera-token-workflow.py"

require_file "$MANUAL_AUTO_PATCH"
require_file "$SYSTEM_TOKEN_UI_PATCH"
require_file "$AUTO_ASSIGN_ALL_UI_PATCH"
require_file "$CAMERA_DEVICE_UI_PATCH"
require_file "$CAMERA_TOKEN_WORKFLOW_PATCH"
require_file "$PROJECT_DIR/frontend/src/components/CameraTokenLinksPanel.vue"

python3 -m py_compile \
  "$MANUAL_AUTO_PATCH" \
  "$SYSTEM_TOKEN_UI_PATCH" \
  "$AUTO_ASSIGN_ALL_UI_PATCH" \
  "$CAMERA_DEVICE_UI_PATCH" \
  "$CAMERA_TOKEN_WORKFLOW_PATCH"

# The historical managed-token implementation is still materialized by
# idempotent source patchers. Run every UI-related patch in dependency order so
# a frontend-only build from a clean checkout cannot silently drop features.
python3 "$MANUAL_AUTO_PATCH" --project-dir "$PROJECT_DIR"
python3 "$SYSTEM_TOKEN_UI_PATCH" --project-dir "$PROJECT_DIR"
python3 "$AUTO_ASSIGN_ALL_UI_PATCH" --project-dir "$PROJECT_DIR"
python3 "$CAMERA_DEVICE_UI_PATCH" --project-dir "$PROJECT_DIR"
python3 "$CAMERA_TOKEN_WORKFLOW_PATCH" --project-dir "$PROJECT_DIR"

ADMIN_VIEW="$PROJECT_DIR/frontend/src/views/AdminView.vue"
CAMERAS_VIEW="$PROJECT_DIR/frontend/src/views/CamerasView.vue"
PLAYER_VIEW="$PROJECT_DIR/frontend/src/views/PlayerView.vue"
DEVICES_VIEW="$PROJECT_DIR/frontend/src/views/DevicesView.vue"
ADMIN_LINKS="$PROJECT_DIR/frontend/src/components/AdminLinksPanel.vue"
CAMERA_LINKS="$PROJECT_DIR/frontend/src/components/CameraTokenLinksPanel.vue"

for marker in \
  'managedTokenForm.auto_assign_new_cameras' \
  'toggleManagedTokenAutoAssign' \
  'token.auto_assign_new_cameras' \
  'Автоматически назначать всем камерам' \
  'Авто всем камерам' \
  'существующие назначения сохранены'; do
  grep -q "$marker" "$ADMIN_VIEW" || {
    echo "Managed-token UI marker is missing after preparation: $marker" >&2
    exit 1
  }
done

if grep -q 'value="links"' "$ADMIN_VIEW" || grep -q 'AdminLinksPanel' "$ADMIN_VIEW"; then
  echo "Obsolete administration links tab is still present" >&2
  exit 1
fi

grep -q 'Привязка выполняется в разделе «Камеры»' "$ADMIN_VIEW" || {
  echo "Administration token guidance was not updated" >&2
  exit 1
}

grep -q 'SYSTEM_MANAGED_TOKEN_ID' "$ADMIN_LINKS" || {
  echo "System managed-token links compatibility UI was not prepared" >&2
  exit 1
}

grep -q 'Запись ведётся' "$PLAYER_VIEW" || {
  echo "Simplified camera status UI was not prepared" >&2
  exit 1
}

grep -q 'CameraTokenLinksPanel' "$PLAYER_VIEW" || {
  echo "Camera token links panel was not mounted on player page" >&2
  exit 1
}

grep -q 'Ссылки доступа по токенам' "$CAMERA_LINKS" || {
  echo "Camera token links component is incomplete" >&2
  exit 1
}

grep -q 'openTokenDialog(camera)' "$CAMERAS_VIEW" || {
  echo "Camera token assignment management is missing from cameras page" >&2
  exit 1
}

grep -q 'saveTokenAssignments' "$CAMERAS_VIEW" || {
  echo "Camera token assignment save flow is missing" >&2
  exit 1
}

grep -q 'cameraForm.managed_token_ids' "$DEVICES_VIEW" || {
  echo "Camera creation multi-token field was not prepared" >&2
  exit 1
}

grep -q '<th>Комментарий</th>' "$DEVICES_VIEW" || {
  echo "Device comment column was not prepared" >&2
  exit 1
}

echo "Frontend sources prepared with complete camera token workflow and latest UI"

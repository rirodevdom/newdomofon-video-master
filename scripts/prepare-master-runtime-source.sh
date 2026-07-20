#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Приводит распакованные исходники master к той же runtime-версии, которую
# использует штатный deploy-master.sh. Сеть и Git не используются.

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "$PROJECT_DIR/backend" ]] || fail "Backend source is missing: $PROJECT_DIR/backend"
[[ -d "$PROJECT_DIR/frontend" ]] || fail "Frontend source is missing: $PROJECT_DIR/frontend"
[[ -d "$PROJECT_DIR/smartyard-compat-proxy" ]] || fail "SmartYard gateway source is missing"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v node >/dev/null 2>&1 || fail "node is required"

patchers=(
  scripts/fix-manual-token-resolver-variable.py
  scripts/patch-manual-auto-managed-tokens.py
  scripts/patch-auto-token-detach-guard.py
  scripts/patch-system-managed-token-ui.py
  scripts/patch-managed-media-gateway.py
  scripts/patch-smartyard-flussonic-compat.py
)

for relative in "${patchers[@]}"; do
  [[ -f "$PROJECT_DIR/$relative" ]] || fail "Required runtime patcher is missing: $relative"
done

python3 -m py_compile \
  "$PROJECT_DIR/scripts/fix-manual-token-resolver-variable.py" \
  "$PROJECT_DIR/scripts/patch-manual-auto-managed-tokens.py" \
  "$PROJECT_DIR/scripts/patch-auto-token-detach-guard.py" \
  "$PROJECT_DIR/scripts/patch-system-managed-token-ui.py" \
  "$PROJECT_DIR/scripts/patch-managed-media-gateway.py" \
  "$PROJECT_DIR/scripts/patch-smartyard-flussonic-compat.py"

# Сохраняем проверенный порядок production deploy. Collision fix запускается
# повторно после основного patcher, поскольку тот добавляет resolver branches.
python3 "$PROJECT_DIR/scripts/fix-manual-token-resolver-variable.py" --project-dir "$PROJECT_DIR"
python3 "$PROJECT_DIR/scripts/patch-manual-auto-managed-tokens.py" --project-dir "$PROJECT_DIR"
python3 "$PROJECT_DIR/scripts/patch-auto-token-detach-guard.py" --project-dir "$PROJECT_DIR"
python3 "$PROJECT_DIR/scripts/fix-manual-token-resolver-variable.py" --project-dir "$PROJECT_DIR"
python3 "$PROJECT_DIR/scripts/patch-system-managed-token-ui.py" --project-dir "$PROJECT_DIR"
python3 "$PROJECT_DIR/scripts/patch-managed-media-gateway.py" --project-dir "$PROJECT_DIR"

for gateway in \
  server-node-aware.js \
  server-events-gateway.js \
  server-preview-gateway.js \
  server-formats-gateway.js; do
  node --check "$PROJECT_DIR/smartyard-compat-proxy/$gateway"
done

# Эти маркеры обязательны именно для clean install. Без них media-запросы
# могут попасть в legacy fallback, а браузер маскирует upstream 401/404/502
# сообщением CORS.
grep -q "rest.startsWith('cameras/')" \
  "$PROJECT_DIR/smartyard-compat-proxy/server-node-aware.js"
grep -q "rest.startsWith('cameras/')" \
  "$PROJECT_DIR/smartyard-compat-proxy/server-formats-gateway.js"
grep -q "managed-resolver-rejected" \
  "$PROJECT_DIR/smartyard-compat-proxy/server-node-aware.js"
grep -q "const livePlaylist = /^(?:live|index|video)" \
  "$PROJECT_DIR/smartyard-compat-proxy/server-node-aware.js"
grep -q "oldestAllowedMs" \
  "$PROJECT_DIR/smartyard-compat-proxy/server-node-aware.js"
grep -q "newdomofon-smartyard-still-preview" \
  "$PROJECT_DIR/smartyard-compat-proxy/server-preview-gateway.js"
grep -q "'-frames:v', '1'" \
  "$PROJECT_DIR/smartyard-compat-proxy/server-preview-gateway.js"
grep -q "manualManagedCameraTokenDigest(body.token)" \
  "$PROJECT_DIR/backend/src/routes/internalSmartYard.ts"
grep -q "auto_assign_new_cameras" \
  "$PROJECT_DIR/backend/src/routes/managedCameraTokens.ts"
grep -q "Отключите автоматическое назначение токена всем камерам" \
  "$PROJECT_DIR/backend/src/routes/managedCameraTokens.ts"

echo "Master runtime source prepared for clean install."
echo "repository_access_used=false"

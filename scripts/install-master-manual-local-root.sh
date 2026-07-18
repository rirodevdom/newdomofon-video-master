#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TARGET_PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
LEGACY_INSTALLER="$SCRIPT_DIR/install-master-local-root.sh"
RUNTIME_PREPARER="$SCRIPT_DIR/prepare-master-runtime-source.sh"
PATCHED_INSTALLER="$SCRIPT_DIR/.install-master-local-root.manual.$$"

cleanup() {
  rm -f "$PATCHED_INSTALLER"
}
trap cleanup EXIT

[[ -f "$LEGACY_INSTALLER" ]] || {
  echo "ERROR: installer not found: $LEGACY_INSTALLER" >&2
  exit 66
}
[[ -f "$RUNTIME_PREPARER" ]] || {
  echo "ERROR: runtime preparer not found: $RUNTIME_PREPARER" >&2
  exit 66
}

if (($#)) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  cat <<'EOF'
NewDomofon Video Master root-only installer

This wrapper installs the strict master with operator-defined video-node
credentials. Legacy self-registration is disabled and NODE_REGISTRATION_TOKEN
is left empty. Video node UUID/token/media secret are later entered manually in
Administration -> Nodes -> Create node.

Before the build it applies the same managed-token and SmartYard runtime
integration as deploy-master.sh. After installation it validates public media
CORS for HLS, MPEG-TS, recording status and events.
EOF
  echo
  bash "$LEGACY_INSTALLER" --help
  exit 0
fi

# Clean installation previously built the base repository sources directly,
# while deploy-master.sh applied the actual production token/media integration.
# Prepare the extracted archive before it is copied to /opt so both paths are
# identical and SmartYard requests cannot fall back to stale legacy handlers.
PROJECT_DIR="$SOURCE_ROOT" bash "$RUNTIME_PREPARER"

python3 - "$LEGACY_INSTALLER" "$PATCHED_INSTALLER" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
old = 'NODE_REGISTRATION_TOKEN="$(preserve_secret NODE_REGISTRATION_TOKEN 32 32)"'
new = 'NODE_REGISTRATION_TOKEN=""  # Legacy self-registration disabled.'
if old not in source:
    raise SystemExit("Expected legacy NODE_REGISTRATION_TOKEN generator was not found")
source = source.replace(old, new, 1)
Path(sys.argv[2]).write_text(source, encoding="utf-8")
PY

chmod 0700 "$PATCHED_INSTALLER"

PROJECT_DIR="$TARGET_PROJECT_DIR" \
  bash "$PATCHED_INSTALLER" \
    --source-dir "$SOURCE_ROOT" \
    "$@"

ENV_FILE="${ENV_FILE:-/etc/newdomofon-video/app.env}"
if [[ -f "$ENV_FILE" ]]; then
  python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
out = []
written = False
for line in lines:
    if line.startswith("NODE_REGISTRATION_TOKEN="):
        if not written:
            out.append("NODE_REGISTRATION_TOKEN=")
            written = True
    else:
        out.append(line)
if not written:
    out.append("NODE_REGISTRATION_TOKEN=")
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
  chown root:root "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
fi

python3 - <<'PY'
from pathlib import Path
import json

text_path = Path("/root/newdomofon-master-access.txt")
if text_path.exists():
    lines = text_path.read_text(encoding="utf-8").splitlines()
    out = []
    written = False
    for line in lines:
        if line.startswith("NODE_REGISTRATION_TOKEN="):
            if not written:
                out.append("NODE_REGISTRATION_TOKEN=DISABLED_MANUAL_NODE_REGISTRATION")
                written = True
        else:
            out.append(line)
    if not written:
        out.append("NODE_REGISTRATION_TOKEN=DISABLED_MANUAL_NODE_REGISTRATION")
    text_path.write_text("\n".join(out) + "\n", encoding="utf-8")

json_path = Path("/root/newdomofon-master-access.json")
if json_path.exists():
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
        data["NODE_REGISTRATION_TOKEN"] = "DISABLED_MANUAL_NODE_REGISTRATION"
        json_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except Exception:
        pass
PY

systemctl restart newdomofon-video-backend.service
systemctl restart newdomofon-smartyard-compat.service
curl -fsS --max-time 5 http://127.0.0.1:3000/api/health >/dev/null
curl -fsS --max-time 5 http://127.0.0.1:3082/health >/dev/null

# The repository Nginx template already owns public CORS. The smoke test is
# deliberately fatal: a clean install must never finish successfully while
# SmartYard media responses have missing or duplicated headers.
if [[ -f "$TARGET_PROJECT_DIR/scripts/verify-smartyard-public-cors.sh" ]]; then
  ENV_FILE="$ENV_FILE" \
    bash "$TARGET_PROJECT_DIR/scripts/verify-smartyard-public-cors.sh"
fi

echo
echo "Strict master installation completed."
echo "Legacy node self-registration: disabled"
echo "SmartYard runtime integration: prepared and verified"
echo "Create video nodes with exact operator-defined values from the node registration file."

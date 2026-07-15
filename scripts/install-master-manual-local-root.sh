#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LEGACY_INSTALLER="$SCRIPT_DIR/install-master-local-root.sh"
PATCHED_INSTALLER="$SCRIPT_DIR/.install-master-local-root.manual.$$"

cleanup() {
  rm -f "$PATCHED_INSTALLER"
}
trap cleanup EXIT

[[ -f "$LEGACY_INSTALLER" ]] || {
  echo "ERROR: installer not found: $LEGACY_INSTALLER" >&2
  exit 66
}

if (($#)) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  cat <<'EOF'
NewDomofon Video Master root-only installer

This wrapper installs the strict master with operator-defined video-node
credentials. Legacy self-registration is disabled and NODE_REGISTRATION_TOKEN
is left empty. Video node UUID/token/media secret are later entered manually in
Administration -> Nodes -> Create node.
EOF
  echo
  bash "$LEGACY_INSTALLER" --help
  exit 0
fi

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
curl -fsS --max-time 5 http://127.0.0.1:3000/api/health >/dev/null

echo
echo "Strict master installation completed."
echo "Legacy node self-registration: disabled"
echo "Create video nodes with exact operator-defined values from the node registration file."

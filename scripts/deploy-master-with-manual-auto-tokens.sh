#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
PATCHER="$PROJECT_DIR/scripts/patch-manual-auto-managed-tokens.py"
DEPLOY="$PROJECT_DIR/scripts/deploy-master.sh"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
[[ -f "$PATCHER" ]] || { echo "Missing patcher: $PATCHER" >&2; exit 1; }
[[ -f "$DEPLOY" ]] || { echo "Missing deploy script: $DEPLOY" >&2; exit 1; }

python3 -m py_compile "$PATCHER"
python3 "$PATCHER" --project-dir "$PROJECT_DIR"

exec bash "$DEPLOY"

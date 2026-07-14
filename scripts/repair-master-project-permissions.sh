#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
BACKEND_SERVICE="newdomofon-video-backend.service"
PUBLIC_EVENTS_SERVICE="newdomofon-public-events-proxy.service"
SMARTYARD_SERVICE="newdomofon-smartyard-compat.service"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-60}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 77
fi

NORMALIZER="$PROJECT_DIR/scripts/lib/normalize-project-permissions.sh"
[[ -f "$NORMALIZER" ]] || {
  echo "Permission normalizer not found: $NORMALIZER" >&2
  exit 66
}

for service in "$BACKEND_SERVICE" "$PUBLIC_EVENTS_SERVICE" "$SMARTYARD_SERVICE"; do
  systemctl stop "$service" 2>/dev/null || true
done

PROJECT_DIR="$PROJECT_DIR" bash "$NORMALIZER"

systemctl daemon-reload
systemctl reset-failed "$BACKEND_SERVICE" 2>/dev/null || true
systemctl restart "$BACKEND_SERVICE"

for service in "$PUBLIC_EVENTS_SERVICE" "$SMARTYARD_SERVICE"; do
  if systemctl list-unit-files "$service" >/dev/null 2>&1; then
    systemctl restart "$service"
  fi
done

for ((second=0; second<HEALTH_TIMEOUT_SECONDS; second++)); do
  if curl -fsS --max-time 3 http://127.0.0.1:3000/api/health \
    >/tmp/newdomofon-permission-repair-health.json 2>/dev/null; then
    if jq -e '.ok == true' /tmp/newdomofon-permission-repair-health.json >/dev/null 2>&1; then
      echo "Backend health check passed after ${second}s"
      cat /tmp/newdomofon-permission-repair-health.json | jq .
      systemctl --no-pager --full status "$BACKEND_SERVICE" | head -30
      echo "MASTER PROJECT PERMISSIONS REPAIRED"
      exit 0
    fi
  fi
  sleep 1
done

echo "Backend did not become healthy after permission repair" >&2
systemctl --no-pager --full status "$BACKEND_SERVICE" >&2 || true
journalctl -u "$BACKEND_SERVICE" -n 300 --no-pager >&2 || true
exit 1

#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/newdomofon-video-master}"
BACKEND_SERVICE="newdomofon-video-backend.service"
PUBLIC_EVENTS_SERVICE="newdomofon-public-events-proxy.service"
SMARTYARD_SERVICE="newdomofon-smartyard-compat.service"
RTSP_SERVICE="newdomofon-video-rtsp-gateway.service"
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

for service in "$RTSP_SERVICE" "$SMARTYARD_SERVICE" "$PUBLIC_EVENTS_SERVICE" "$BACKEND_SERVICE"; do
  systemctl stop "$service" 2>/dev/null || true
done

PROJECT_DIR="$PROJECT_DIR" bash "$NORMALIZER"

install -d -o root -g root -m 0700 /etc/newdomofon-video
if [[ -f /etc/newdomofon-video/app.env ]]; then
  chown root:root /etc/newdomofon-video/app.env
  chmod 0600 /etc/newdomofon-video/app.env
fi

install -d -o root -g root -m 0755 \
  /var/lib/newdomofon-video \
  /var/cache/newdomofon-video \
  /var/cache/newdomofon-video/smartyard-preview \
  /var/log/newdomofon-video

for unit in \
  newdomofon-video-backend.service \
  newdomofon-public-events-proxy.service \
  newdomofon-smartyard-compat.service \
  newdomofon-video-rtsp-gateway.service; do
  source_unit="$PROJECT_DIR/deploy/systemd/$unit"
  [[ -f "$source_unit" ]] || continue
  install -m 0644 "$source_unit" "/etc/systemd/system/$unit"
done

systemctl daemon-reload
for service in "$BACKEND_SERVICE" "$PUBLIC_EVENTS_SERVICE" "$SMARTYARD_SERVICE" "$RTSP_SERVICE"; do
  systemctl reset-failed "$service" 2>/dev/null || true
  if systemctl list-unit-files "$service" >/dev/null 2>&1; then
    systemctl enable --now "$service"
    systemctl restart "$service"
  fi
done

for ((second=0; second<HEALTH_TIMEOUT_SECONDS; second++)); do
  if curl -fsS --max-time 3 http://127.0.0.1:3000/api/health \
    >/tmp/newdomofon-root-runtime-health.json 2>/dev/null; then
    if jq -e '.ok == true' /tmp/newdomofon-root-runtime-health.json >/dev/null 2>&1; then
      echo "Backend health check passed after ${second}s"
      cat /tmp/newdomofon-root-runtime-health.json | jq .
      break
    fi
  fi
  sleep 1
done

jq -e '.ok == true' /tmp/newdomofon-root-runtime-health.json >/dev/null

for service in "$BACKEND_SERVICE" "$PUBLIC_EVENTS_SERVICE" "$SMARTYARD_SERVICE" "$RTSP_SERVICE"; do
  if systemctl list-unit-files "$service" >/dev/null 2>&1; then
    systemctl is-active --quiet "$service"
    printf '%-48s user=' "$service"
    systemctl show -p User --value "$service"
  fi
done

echo "MASTER APPLICATION SERVICES NOW RUN AS ROOT"

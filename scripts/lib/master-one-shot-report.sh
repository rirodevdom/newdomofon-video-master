#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

WEB_URL="${PUBLIC_SCHEME}://${MASTER_DOMAIN}"
cp -a "$ENV_FILE" "$SUMMARY_FILE"
cat >>"$SUMMARY_FILE" <<EOF

INSTALL_COMPLETED_AT=$(date '+%Y-%m-%d_%H:%M:%S_%Z_%z')
INSTALL_GIT_COMMIT=${GIT_COMMIT}
INSTALL_TIMEZONE=${TIMEZONE}
INSTALL_TLS_STATUS=${TLS_MESSAGE}
MASTER_WEB_URL=${WEB_URL}
MASTER_ADMIN_URL=${WEB_URL}/admin
MASTER_API_HEALTH_URL=${WEB_URL}/api/health
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
POSTGRES_DATABASE=newdomofon_video
POSTGRES_USER=newdomofon
RTSP_PUBLIC_URL_TEMPLATE=${RTSP_TEMPLATE}
RTSP_PUBLIC_PORT=8554
MEDIAMTX_VERSION=${RTSP_VERSION}
PROJECT_DIR=${PROJECT_DIR}
INSTALL_LOG=${LOG_FILE}
INSTALL_BACKUP=${BACKUP_DIR}
EOF
chmod 0600 "$SUMMARY_FILE"

jq -Rn '
  reduce inputs as $line ({};
    if ($line | test("^[A-Za-z_][A-Za-z0-9_]*=")) then
      ($line | capture("^(?<key>[^=]+)=(?<value>.*)$")) as $item |
      .[$item.key] = $item.value
    else . end
  )
' <"$SUMMARY_FILE" >"$CREDENTIALS_JSON"
chmod 0600 "$CREDENTIALS_JSON"

cat "$SUMMARY_FILE"
echo
echo "Installation succeeded."
echo "Access data: $SUMMARY_FILE"
echo "JSON copy: $CREDENTIALS_JSON"
echo "Log: $LOG_FILE"

#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Render runtime configuration from environment variables, then start everything
# under supervisord. Nothing here needs editing; drive it all from the .env file.
# ---------------------------------------------------------------------------

: "${ARI_PASS:?ARI_PASS must be set}"
: "${PROTECT_CAMERA_PATH:?PROTECT_CAMERA_PATH must be set (rtspx://IP:7441/KEY)}"
: "${RX_PORT_FROM_ASTERISK:=9999}"

echo "[entrypoint] Rendering Asterisk ARI password..."
sed -i "s|__ARI_PASS__|${ARI_PASS}|g" /etc/asterisk/ari.conf

echo "[entrypoint] Rendering go2rtc.yaml from PROTECT_CAMERA_PATH..."
# '|' delimiter because the path contains slashes/colons
sed "s|__PROTECT_CAMERA_PATH__|${PROTECT_CAMERA_PATH}|g" \
    /app/go2rtc.yaml.template > /app/go2rtc.yaml

echo "[entrypoint] Rendering SDP for RX port ${RX_PORT_FROM_ASTERISK}..."
sed "s|{{RX_PORT_FROM_ASTERISK}}|${RX_PORT_FROM_ASTERISK}|g" \
    /app/sdp/from_asterisk.sdp.template \
    > "/app/sdp/from_asterisk_${RX_PORT_FROM_ASTERISK}.sdp"

# Asterisk wants to own its runtime dirs
mkdir -p /var/run/asterisk /var/log/asterisk /var/lib/asterisk
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk 2>/dev/null || true

echo "[entrypoint] Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf

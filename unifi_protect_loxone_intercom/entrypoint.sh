#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Render runtime configuration from environment variables, then start everything
# under supervisord. For a normal setup you only set the four PROTECT_* values in
# .env; everything else has a sensible default (baked into the image) and the
# internal secrets below are auto-generated.
# ---------------------------------------------------------------------------

# --- Required user config: the four things only you can know ----------------
missing=0
for v in PROTECT_CAMERA_PATH PROTECT_BASE PROTECT_API_KEY CAMERA_ID; do
  if [ -z "${!v:-}" ] || [[ "${!v:-}" == *CHANGEME* ]]; then
    echo "[entrypoint] ERROR: ${v} is not set (edit your .env)."
    missing=1
  fi
done
if [ "$missing" = "1" ]; then
  echo "[entrypoint] Refusing to start until the PROTECT_* values are filled in."
  exit 1
fi

# --- Auto-generated internal secrets ----------------------------------------
# These never leave the box (ARI is localhost-only; the webhook token only
# matters if you point Protect at the bridge's own ring webhook). Generate them
# once at boot so the user never has to. Export so supervisord's children (the
# bridge, the ARI healthcheck) inherit them.
# base64 of 24 random bytes is ~32 chars; tr drops +// so ~28-32 alnum remain.
# (No trailing `head -c` — closing the pipe early would SIGPIPE under pipefail.)
: "${ARI_PASS:=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')}"
: "${WEBHOOK_TOKEN:=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')}"
export ARI_PASS WEBHOOK_TOKEN

: "${RX_PORT_FROM_ASTERISK:=9999}"
: "${DOORBELL_EXTENSION:=9900}"

echo "[entrypoint] Rendering Asterisk ARI password..."
sed -i "s|__ARI_PASS__|${ARI_PASS}|g" /etc/asterisk/ari.conf

echo "[entrypoint] Rendering dialplan for extension ${DOORBELL_EXTENSION}..."
sed -i "s|__DOORBELL_EXTENSION__|${DOORBELL_EXTENSION}|g" /etc/asterisk/extensions.conf

# Optional remote-access transport settings (#included by pjsip.conf). Empty file
# = LAN/VPN-only. Driven entirely by env so .env / addon options are the single
# point of edit; no need to touch the baked-in pjsip.conf.
echo "[entrypoint] Rendering SIP transport extras..."
{
  if [ -n "${SIP_EXTERNAL_ADDRESS:-}" ]; then
    echo "external_media_address = ${SIP_EXTERNAL_ADDRESS}"
    echo "external_signaling_address = ${SIP_EXTERNAL_ADDRESS}"
  fi
  if [ -n "${SIP_LOCAL_NET:-}" ]; then
    IFS=',' read -ra _nets <<< "${SIP_LOCAL_NET}"
    for _n in "${_nets[@]}"; do
      _n="$(echo "${_n}" | tr -d '[:space:]')"
      [ -n "${_n}" ] && echo "local_net = ${_n}"
    done
  fi
} > /etc/asterisk/pjsip_transport_extra.conf

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

# --- optional SIP/RTP debugging (DEBUG_SIP=true / addon option debug_sip) ----
# Enables the PJSIP packet logger + per-packet RTP debug on the Asterisk
# console once Asterisk is up; everything lands in the container log. VERY
# noisy (every SIP message and RTP packet) — for debugging sessions only.
# Runs in the background so it survives the exec below (children are kept).
if [ "${DEBUG_SIP:-}" = "true" ] || [ "${DEBUG_SIP:-}" = "1" ]; then
  (
    for _ in $(seq 1 60); do
      if asterisk -rx "core waitfullybooted" >/dev/null 2>&1; then
        asterisk -rx "pjsip set logger on" >/dev/null 2>&1
        asterisk -rx "rtp set debug on" >/dev/null 2>&1
        echo "[entrypoint] DEBUG_SIP: pjsip logger + rtp debug ENABLED (expect a very noisy log)"
        exit 0
      fi
      sleep 2
    done
    echo "[entrypoint] DEBUG_SIP: gave up waiting for Asterisk to boot"
  ) &
fi

echo "[entrypoint] Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf

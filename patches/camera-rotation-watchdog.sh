#!/usr/bin/env bash
#==============================================================================
# camera-rotation-watchdog.sh
#
# Keeps the UniFi Doorbell Lite (G6O, Sigmastar Infinity6E) in LANDSCAPE-UPRIGHT.
#
# WHY THIS EXISTS
#   The doorbell firmware hardcodes a 90-degree portrait ("hallway") rotation.
#   Protect cannot turn it off: the camera reports featureFlags.hasHallwayMode=
#   false and ignores the controller's hallwayMode=disabled. So Protect, the
#   recordings and the go2rtc/Loxone feed all get a portrait 1920x2560 image,
#   while every other camera is landscape.
#
#   We override it ON THE CAMERA with two pieces:
#     1. rot90.so  - an LD_PRELOAD shim that interposes the encoder's C++
#        getter ubnt::encoder::VideoEncoderSettings::hallwayMode() and returns
#        HALLWAY_VALUE (0 = disabled). Injected by bind-mounting streamer_wrap.sh
#        over /bin/ubnt_streamer; the wrapper LD_PRELOADs the shim and execs the
#        real binary. hallwayMode=0 makes the encoder emit the native LANDSCAPE
#        sensor frame (which happens to be upside-down for this mount).
#     2. ISP flip+mirror=1 in /etc/persistent/ubnt_isp.conf - a 180-degree turn
#        that corrects the upside-down landscape to upright.
#
# WHY A WATCHDOG (not a one-shot)
#   Neither piece survives a camera reboot: cfgmtd wipes unknown files from
#   /etc/persistent on boot and the bind-mount is volatile. So after any camera
#   reboot the doorbell comes back portrait. This loop re-applies the fix within
#   CHECK_INTERVAL seconds of any drift.
#
# SAFETY
#   - Restarts the streamer with SIGTERM only (graceful; the watchdog tolerates
#     it). NEVER SIGKILL: a -9 on the critical streamer makes the camera's own
#     supervisor reboot the device.
#   - Only restarts a process when its config actually drifted (idempotent).
#   - Runs inside the bridge container, which is on the camera's LAN subnet, so
#     SSH stays local and does not trip the UniFi IPS.
#
# PREREQUISITES
#   - Camera SSH enabled (UDM: /etc/unifi-protect/config.json {"enableSsh":true},
#     restart unifi-protect). Login: ubnt + the camera Recovery Code.
#   - rot90.so + streamer_wrap.sh present next to this script.
#==============================================================================
set -uo pipefail

: "${ROTATION_FIX_ENABLED:=0}"
: "${CAMERA_IP:=}"
: "${CAMERA_SSH_PASS:=}"             # the camera's Recovery Code
: "${HALLWAY_VALUE:=0}"              # 0=disabled=>landscape (firmware default ~1=portrait)
: "${ISP_FLIP:=1}"                   # vertical flip   ) together = 180 deg, to correct
: "${ISP_MIRROR:=1}"                 # horizontal flip ) the upside-down native landscape
: "${ROTATION_CHECK_INTERVAL:=30}"

HERE="$(cd "$(dirname "$0")" && pwd)"
SO_FILE="${HERE}/rot90.so"
WRAP_FILE="${HERE}/streamer_wrap.sh"

log(){ echo "[rotation-watchdog] $*"; }

if [ "$ROTATION_FIX_ENABLED" != "1" ]; then
  log "ROTATION_FIX_ENABLED!=1 -> idling (doorbell stays stock portrait)."
  exec sleep infinity
fi
if [ -z "$CAMERA_IP" ] || [ -z "$CAMERA_SSH_PASS" ]; then
  log "CAMERA_IP / CAMERA_SSH_PASS not set -> idling."
  exec sleep infinity
fi
if [ ! -f "$SO_FILE" ] || [ ! -f "$WRAP_FILE" ]; then
  log "missing $SO_FILE or $WRAP_FILE -> idling."
  exec sleep infinity
fi

export SSHPASS="$CAMERA_SSH_PASS"
SSH="sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 ubnt@${CAMERA_IP}"

SO_B64="$(base64 -w0 "$SO_FILE")"
WRAP_B64="$(base64 -w0 "$WRAP_FILE")"

# --- camera-side CHECK: prints OK or "DRIFT hook=.. flip=.." -------------------
check_script() {
cat <<CHK
PB=/etc/persistent
cur=\$(for p in \$(pidof ubnt_streamer); do tr '\0' '\n' </proc/\$p/environ 2>/dev/null | grep '^HALLWAY='; done | head -1)
hook=0
[ "\$cur" = "HALLWAY=${HALLWAY_VALUE}" ] && [ -f \$PB/rot90.so ] && [ "\$(grep -c ubnt_streamer /proc/mounts)" != "0" ] && hook=1
flip=0
grep -q '"flip": ${ISP_FLIP}' \$PB/ubnt_isp.conf 2>/dev/null && grep -q '"mirror": ${ISP_MIRROR}' \$PB/ubnt_isp.conf 2>/dev/null && flip=1
[ "\$hook" = 1 ] && [ "\$flip" = 1 ] && echo OK || echo "DRIFT hook=\$hook flip=\$flip"
CHK
}

# --- camera-side APPLY: (re)install hook + flip, restart only what changed -----
apply_script() {
cat <<APPLY
PB=/etc/persistent
echo '${SO_B64}'   | base64 -d > \$PB/rot90.so
echo '${WRAP_B64}' | base64 -d > \$PB/streamer_wrap.sh
chmod +x \$PB/streamer_wrap.sh
mkdir -p \$PB/realbin
[ -f \$PB/realbin/ubnt_streamer ] || { cp -f /bin/ubnt_streamer \$PB/realbin/ubnt_streamer; chmod +x \$PB/realbin/ubnt_streamer; }
echo ${HALLWAY_VALUE} > \$PB/hallway_val
ISPC=0
grep -q '"flip": ${ISP_FLIP}'     \$PB/ubnt_isp.conf || { sed -i 's/"flip": [0-9]*/"flip": ${ISP_FLIP}/'     \$PB/ubnt_isp.conf; ISPC=1; }
grep -q '"mirror": ${ISP_MIRROR}' \$PB/ubnt_isp.conf || { sed -i 's/"mirror": [0-9]*/"mirror": ${ISP_MIRROR}/' \$PB/ubnt_isp.conf; ISPC=1; }
[ "\$(grep -c ubnt_streamer /proc/mounts)" = "0" ] && mount -o bind \$PB/streamer_wrap.sh /bin/ubnt_streamer
kill \$(pidof ubnt_streamer) 2>/dev/null         # SIGTERM only - never -9
[ "\$ISPC" = "1" ] && kill \$(pidof ubnt_ispserver) 2>/dev/null
echo APPLIED
APPLY
}

log "starting; camera=${CAMERA_IP} hallway=${HALLWAY_VALUE} flip=${ISP_FLIP} mirror=${ISP_MIRROR} interval=${ROTATION_CHECK_INTERVAL}s"
while true; do
  st="$($SSH "$(check_script)" 2>/dev/null)" || st="UNREACHABLE"
  case "$st" in
    OK)           : ;;  # steady state - stay quiet
    UNREACHABLE)  log "camera unreachable (rebooting?); will retry" ;;
    DRIFT*)       log "drift: $st -> applying"
                  r="$($SSH "$(apply_script)" 2>&1)"
                  log "apply -> ${r:-apply-failed(no output)}" ;;
    *)            log "unexpected check output: $st" ;;
  esac
  sleep "$ROTATION_CHECK_INTERVAL"
done

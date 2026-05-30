#!/usr/bin/env bash
#==============================================================================
# Launch mjpg-streamer on :MJPEG_PORT serving the DELAYED frame
# (/dev/shm/snap/cam_snap.jpg, written by snapshot-delay.sh) so that BOTH
# /?action=snapshot and /?action=stream are ~SNAPSHOT_DELAY_SECS behind. The
# snapshot pre-roll catches the ring moment; the small stream lag is negligible
# for a doorbell. (A dual-input setup to keep the stream live failed on this
# mjpg-streamer build - the second input_file plugin never served.)
# If SNAPSHOT_DELAY_SECS<=0, snapshot-delay.sh just mirrors live (no delay).
#
# Optional HTTP basic auth via output_http's `-c user:pass`. Plain HTTP -> keep
# MJPEG_PORT LAN/VPN-only.
#==============================================================================
set -uo pipefail

: "${MJPEG_PORT:=8080}"
: "${MJPEG_AUTH_USER:=}"
: "${MJPEG_AUTH_PASS:=}"

PLUGINDIR=/usr/local/lib/mjpg-streamer
mkdir -p /dev/shm/snap
IN="${PLUGINDIR}/input_file.so -f /dev/shm/snap -n cam_snap.jpg -d 0.04"
OUT="${PLUGINDIR}/output_http.so -p ${MJPEG_PORT} -w /usr/local/share/mjpg-streamer/www -n"

if [ -n "${MJPEG_AUTH_USER}" ] && [ -n "${MJPEG_AUTH_PASS}" ]; then
  OUT="${OUT} -c ${MJPEG_AUTH_USER}:${MJPEG_AUTH_PASS}"
  echo "[mjpg-serve] basic auth ENABLED (user ${MJPEG_AUTH_USER}) on :${MJPEG_PORT}"
else
  echo "[mjpg-serve] basic auth DISABLED on :${MJPEG_PORT}"
fi

exec /usr/local/bin/mjpg_streamer -i "${IN}" -o "${OUT}"

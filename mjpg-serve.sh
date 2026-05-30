#!/usr/bin/env bash
#==============================================================================
# Launch mjpg-streamer serving /dev/shm/cam.jpg (written by mjpeg-video.sh) at
# :MJPEG_PORT/?action=stream (+ ?action=snapshot).
#
# Optional HTTP basic auth via output_http's built-in `-c user:pass`. Set
# MJPEG_AUTH_USER + MJPEG_AUTH_PASS in .env to enable it; leave either empty to
# serve without auth. NOTE: basic auth here is over plain HTTP, so creds are
# base64 (not encrypted) on the wire - fine for LAN/VPN (8080 is not internet-
# forwarded); put TLS in front (reverse proxy) if you ever expose it publicly.
#==============================================================================
set -uo pipefail

: "${MJPEG_PORT:=8080}"
: "${MJPEG_AUTH_USER:=}"
: "${MJPEG_AUTH_PASS:=}"

PLUGINDIR=/usr/local/lib/mjpg-streamer
IN="${PLUGINDIR}/input_file.so -f /dev/shm -n cam.jpg -d 0.04"
OUT="${PLUGINDIR}/output_http.so -p ${MJPEG_PORT} -w /usr/local/share/mjpg-streamer/www -n"

if [ -n "${MJPEG_AUTH_USER}" ] && [ -n "${MJPEG_AUTH_PASS}" ]; then
  OUT="${OUT} -c ${MJPEG_AUTH_USER}:${MJPEG_AUTH_PASS}"
  echo "[mjpg-serve] basic auth ENABLED (user ${MJPEG_AUTH_USER}) on :${MJPEG_PORT}"
else
  echo "[mjpg-serve] basic auth DISABLED on :${MJPEG_PORT}"
fi

exec /usr/local/bin/mjpg_streamer -i "${IN}" -o "${OUT}"

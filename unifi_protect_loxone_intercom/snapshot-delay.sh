#!/usr/bin/env bash
#==============================================================================
# snapshot-delay.sh
#
# Maintains /dev/shm/cam_snap.jpg as the frame from ~SNAPSHOT_DELAY_SECS ago, so
# mjpg-streamer's default /?action=snapshot is a "pre-roll" image - by the time
# Loxone fetches it after a doorbell ring, the visitor has often moved, so the
# frame from ~1s earlier captures the ring moment better.
#
# mjpg-serve.sh wires this delayed file as mjpg-streamer input 0 (default
# snapshot/stream) and the live /dev/shm/cam.jpg as input 1 (?action=stream_1).
#
# Simple fixed-tick ring buffer: N = delay * fps slots. Each tick we publish the
# slot that was written N ticks ago (= the delay) then overwrite it with the
# current frame. Cheap (small JPEGs on tmpfs). During the first `delay` seconds
# the buffer isn't full yet, so we fall back to the live frame.
#==============================================================================
set -uo pipefail

: "${SNAPSHOT_DELAY_SECS:=1}"
: "${MJPEG_FPS:=10}"
SRC=/dev/shm/cam.jpg
# Own folder: mjpg-streamer runs two input_file plugins; two of them on the SAME
# folder (/dev/shm) interfere, so the delayed frame lives in its own dir.
DST=/dev/shm/snap/cam_snap.jpg
BUF=/dev/shm/snap/buf
mkdir -p /dev/shm/snap

log(){ echo "[snapshot-delay] $*"; }

# delay of 0 -> just mirror the live frame (no buffering)
ZERO=$(awk "BEGIN{print (${SNAPSHOT_DELAY_SECS}<=0)?1:0}")
N=$(awk "BEGIN{n=int(${SNAPSHOT_DELAY_SECS}*${MJPEG_FPS}+0.5); if(n<1)n=1; print n}")
INTERVAL=$(awk "BEGIN{printf \"%.4f\", 1.0/${MJPEG_FPS}}")

mkdir -p "$BUF"; rm -f "$BUF"/*.jpg 2>/dev/null || true

if [ "$ZERO" = "1" ]; then
  log "SNAPSHOT_DELAY_SECS<=0 -> mirroring live frame (no delay)"
  while true; do [ -f "$SRC" ] && cp -f "$SRC" "$DST" 2>/dev/null; sleep "$INTERVAL"; done
fi

log "delay=${SNAPSHOT_DELAY_SECS}s -> ${N} frames @ ${MJPEG_FPS}fps (tick ${INTERVAL}s)"
head=0
while true; do
  slot="$BUF/$head.jpg"
  if [ -f "$slot" ]; then
    cp -f "$slot" "$DST" 2>/dev/null            # frame written N ticks ago = the delay
  elif [ -f "$SRC" ]; then
    cp -f "$SRC" "$DST" 2>/dev/null              # warmup: buffer not full yet -> live
  fi
  [ -f "$SRC" ] && cp -f "$SRC" "$slot" 2>/dev/null
  head=$(( (head + 1) % N ))
  sleep "$INTERVAL"
done

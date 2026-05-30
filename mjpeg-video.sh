#!/usr/bin/env bash
#==============================================================================
# Continuous ffmpeg transcode for the mjpg-streamer video path.
#
# Reads the doorbell's raw H264 video from go2rtc's LOCAL RTSP (so there's still
# only ONE connection to the camera - go2rtc owns it), transcodes to MJPEG and
# overwrites a single JPEG in /dev/shm (tmpfs). mjpg-streamer's input_file polls
# that JPEG and serves it at :MJPEG_PORT/?action=stream.
#
# Because this runs continuously, the stream is ALWAYS WARM -> instant open in
# Loxone (no go2rtc on-demand transcode spin-up).
#
# Tuning mirrors the k3s kamera-vchod-mjpeg pipeline: in-place `-update` write on
# tmpfs (NOT `-atomic_writing`, whose rename gap caps the poller's fps).
#==============================================================================
set -uo pipefail

: "${MJPEG_FPS:=10}"
: "${MJPEG_SCALE_W:=1280}"      # width; height auto (-2) keeps aspect, even
: "${MJPEG_QUALITY:=8}"         # ffmpeg mjpeg -q:v (lower = better quality)
: "${MJPEG_TRANSPOSE:=}"        # rotation: ""=none, 1=90CW, 2=90CCW, 1,1=180
: "${FFMPEG_PATH:=ffmpeg}"

SRC="rtsp://127.0.0.1:8554/unifi_doorbell_video"
OUT="/dev/shm/cam.jpg"

# Scale first (on the landscape source), then rotate, so a 90deg turn yields a
# sensible portrait (e.g. 1280-wide -> 720x1280) instead of an oversized frame.
VF="scale=${MJPEG_SCALE_W}:-2"
if [ -n "${MJPEG_TRANSPOSE}" ]; then
  for t in ${MJPEG_TRANSPOSE//,/ }; do VF="${VF},transpose=${t}"; done
fi

# go2rtc may not be serving RTSP yet at boot; retry until the transcode sticks.
# supervisord also autorestarts us, but loop here to avoid restart churn.
while true; do
  echo "[mjpeg-video] starting transcode ${SRC} -> ${OUT} (vf=${VF} ${MJPEG_FPS}fps q=${MJPEG_QUALITY})"
  # -y -nostdin: never block on the "file exists, overwrite? [y/N]" prompt on
  # restart (that's an interactive hang with no stdin). A stalled/hung ffmpeg
  # that doesn't exit is caught by video-watchdog.sh, which kills it -> this loop
  # restarts it and reconnects to go2rtc.
  "${FFMPEG_PATH}" -hide_banner -nostdin -y -loglevel warning \
    -rtsp_transport tcp -fflags nobuffer -flags low_delay \
    -i "${SRC}" \
    -an -vf "${VF}" -c:v mjpeg -r "${MJPEG_FPS}" -q:v "${MJPEG_QUALITY}" \
    -update 1 -f image2 "${OUT}"
  echo "[mjpeg-video] ffmpeg exited ($?), retrying in 3s (go2rtc RTSP up yet?)"
  sleep 3
done

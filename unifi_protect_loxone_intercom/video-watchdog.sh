#!/usr/bin/env bash
#==============================================================================
# video-watchdog.sh
#
# Keeps the MJPEG feed alive AND correctly shaped. The chain is:
#   camera --RTSPS--> go2rtc --RTSP :8554--> mjpeg-video.sh (ffmpeg) -->
#   /dev/shm/cam.jpg --> mjpg-streamer :MJPEG_PORT
#
# Two failure modes after a camera reboot / rotation change:
#
#  (1) STALL - ffmpeg hangs (alive, producing nothing) -> cam.jpg stops updating
#      and the MJPEG stream hangs "pending". Detected by file freshness.
#
#  (2) STALE GEOMETRY - ffmpeg probed the stream while the camera was still
#      portrait (at boot, before the rotation fix), then the camera flipped to
#      landscape. go2rtc keeps ffmpeg's session open, so ffmpeg never re-probes
#      and squishes landscape frames into the old portrait shape. Frames keep
#      flowing, so freshness can't catch it - we compare the source's aspect to
#      the output's aspect and restart on a mismatch.
#
# Recovery = SIGKILL the transcode (mjpeg-video.sh's loop restarts it -> fresh
# probe + reconnect). GRACE windows stop us killing ffmpeg before it warms up.
# Does NOT restart go2rtc (bridge-spawned/unsupervised; killing it drops audio).
#==============================================================================
set -uo pipefail

: "${MJPEG_STALE_SECS:=20}"           # cam.jpg older than this = dead feed
: "${VIDEO_WATCHDOG_INTERVAL:=5}"     # poll period once healthy
: "${VIDEO_WATCHDOG_GRACE:=25}"       # let ffmpeg connect+keyframe before judging
: "${VIDEO_ORIENT_CHECK_EVERY:=6}"    # source-vs-output aspect check every Nth poll
: "${MJPEG_TRANSPOSE:=}"              # if set, ffmpeg intentionally rotates -> disable
                                      # the aspect check (output aspect != source by design)
FILE=/dev/shm/cam.jpg
SRC_FRAME="http://127.0.0.1:1985/api/frame.jpeg?src=unifi_doorbell_video"

log(){ echo "[video-watchdog] $*"; }
dims(){ ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$1" 2>/dev/null; }
ratio10(){ local s="$1" w h; w=${s%,*}; h=${s#*,}; case "$w$h" in ''|*[!0-9]*) return;; esac; [ "$h" -gt 0 ] && echo $(( w * 10 / h )); }

restart_transcode(){
  log "$1 -> restarting transcode"
  pkill -KILL -f "image2 ${FILE}" 2>/dev/null || true   # -9: kills even a wedged/stopped ffmpeg
  rm -f "$FILE" 2>/dev/null || true                     # fresh ffmpeg -> no overwrite prompt
}

log "starting; stale>${MJPEG_STALE_SECS}s; aspect-check every $(( VIDEO_ORIENT_CHECK_EVERY * VIDEO_WATCHDOG_INTERVAL ))s; grace ${VIDEO_WATCHDOG_GRACE}s"
sleep "$VIDEO_WATCHDOG_GRACE"          # let the initial transcode come up first

miss=0; n=0
while true; do
  now=$(date +%s)
  if [ -f "$FILE" ]; then mt=$(stat -c %Y "$FILE" 2>/dev/null || echo 0); age=$(( now - mt )); else age=99999; fi

  # --- (1) freshness ---------------------------------------------------------
  if [ "$age" -gt "$MJPEG_STALE_SECS" ]; then
    miss=$(( miss + 1 ))
    restart_transcode "frame stale ${age}s (strike ${miss})"
    if [ "$miss" -ge 2 ]; then
      log "still stale after restart -> bouncing mjpg-streamer"
      pkill -KILL -x mjpg_streamer 2>/dev/null || true
      miss=0
    fi
    sleep "$VIDEO_WATCHDOG_GRACE"
    continue
  fi
  miss=0

  # --- (2) geometry: source aspect vs output aspect (periodic) ---------------
  # Only valid when ffmpeg does NOT rotate (then output aspect == source aspect).
  n=$(( n + 1 ))
  if [ -z "$MJPEG_TRANSPOSE" ] && [ "$n" -ge "$VIDEO_ORIENT_CHECK_EVERY" ]; then
    n=0
    out_r=$(ratio10 "$(dims "$FILE")")
    if curl -s -m 10 -o /tmp/_srcprobe.jpg "$SRC_FRAME" 2>/dev/null; then
      src_r=$(ratio10 "$(dims /tmp/_srcprobe.jpg)")
      if [ -n "${src_r:-}" ] && [ -n "${out_r:-}" ]; then
        d=$(( src_r - out_r )); [ "$d" -lt 0 ] && d=$(( -d ))
        if [ "$d" -gt 1 ]; then
          restart_transcode "geometry mismatch (source aspect=${src_r} vs output=${out_r}, e.g. camera flipped)"
          sleep "$VIDEO_WATCHDOG_GRACE"
          continue
        fi
      fi
    fi
  fi

  sleep "$VIDEO_WATCHDOG_INTERVAL"
done

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
#  (3) STUCK go2rtc - go2rtc is alive but has lost the camera: every DESCRIBE
#      of rtsp://127.0.0.1:8554/unifi_doorbell_video gets "404 Not Found"
#      (go2rtc answers 404 when it can't attach a consumer to the stream), so
#      ffmpeg exits in a loop and restarting ffmpeg/mjpg-streamer can't help.
#      Seen in production; only restarting go2rtc recovered it.
#
# Recovery ladder, per consecutive stale strike:
#   every strike  -> SIGKILL the transcode (mjpeg-video.sh's loop restarts it ->
#                    fresh probe + reconnect)
#   strike 2      -> also bounce mjpg-streamer
#   strike N      -> (N = VIDEO_GO2RTC_RESTART_STRIKES) if go2rtc can't serve a
#                    frame itself either, SIGKILL go2rtc. The bridge (index.js)
#                    exits on go2rtc's non-zero exit, supervisord restarts the
#                    bridge, and the bridge spawns a fresh go2rtc. This drops
#                    the bridge's ARI session, so it is skipped while Asterisk
#                    has an active call, and rate-limited by
#                    VIDEO_GO2RTC_RESTART_COOLDOWN (camera really offline ->
#                    no restart churn).
# GRACE windows stop us killing ffmpeg before it warms up.
#==============================================================================
set -uo pipefail

: "${MJPEG_STALE_SECS:=20}"           # cam.jpg older than this = dead feed
: "${VIDEO_WATCHDOG_INTERVAL:=5}"     # poll period once healthy
: "${VIDEO_WATCHDOG_GRACE:=25}"       # let ffmpeg connect+keyframe before judging
: "${VIDEO_ORIENT_CHECK_EVERY:=6}"    # source-vs-output aspect check every Nth poll
: "${MJPEG_TRANSPOSE:=}"              # if set, ffmpeg intentionally rotates -> disable
                                      # the aspect check (output aspect != source by design)
: "${VIDEO_GO2RTC_RESTART_STRIKES:=4}"     # stale strikes before go2rtc restart (0 = never)
: "${VIDEO_GO2RTC_RESTART_COOLDOWN:=300}"   # min seconds between go2rtc restarts
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

# go2rtc can hand out a frame of the source itself -> it still has the camera.
go2rtc_has_frames(){
  curl -sf -m 10 -o /tmp/_g2rprobe.jpg "$SRC_FRAME" 2>/dev/null && [ -s /tmp/_g2rprobe.jpg ]
}

# Active calls according to Asterisk; empty if Asterisk can't be asked.
active_calls(){
  asterisk -rx "core show channels count" 2>/dev/null | sed -n 's/^\([0-9][0-9]*\) active call.*/\1/p'
}

last_go2rtc_restart=0
maybe_restart_go2rtc(){
  local now calls
  now=$(date +%s)
  if go2rtc_has_frames; then
    log "go2rtc still serves source frames -> problem is downstream, not restarting go2rtc"
    return
  fi
  if [ $(( now - last_go2rtc_restart )) -lt "$VIDEO_GO2RTC_RESTART_COOLDOWN" ]; then
    log "go2rtc has no frames either, but restarted it $(( now - last_go2rtc_restart ))s ago (cooldown ${VIDEO_GO2RTC_RESTART_COOLDOWN}s) -> waiting"
    return
  fi
  calls=$(active_calls)
  if [ -n "$calls" ] && [ "$calls" -gt 0 ]; then
    log "go2rtc has no frames either, but ${calls} call(s) active -> not restarting go2rtc mid-call"
    return
  fi
  log "go2rtc has no frames either -> restarting go2rtc (bridge restarts with it)"
  # SIGKILL on purpose: index.js exits only on a NON-zero go2rtc exit, and a
  # graceful SIGTERM exit could be code 0, leaving go2rtc dead and unrespawned.
  pkill -KILL -x go2rtc 2>/dev/null || true
  last_go2rtc_restart=$now
}

log "starting; stale>${MJPEG_STALE_SECS}s; aspect-check every $(( VIDEO_ORIENT_CHECK_EVERY * VIDEO_WATCHDOG_INTERVAL ))s; grace ${VIDEO_WATCHDOG_GRACE}s; go2rtc restart after ${VIDEO_GO2RTC_RESTART_STRIKES} strikes"
sleep "$VIDEO_WATCHDOG_GRACE"          # let the initial transcode come up first

miss=0; strikes=0; n=0
while true; do
  now=$(date +%s)
  if [ -f "$FILE" ]; then mt=$(stat -c %Y "$FILE" 2>/dev/null || echo 0); age=$(( now - mt )); else age=99999; fi

  # --- (1) freshness ---------------------------------------------------------
  if [ "$age" -gt "$MJPEG_STALE_SECS" ]; then
    miss=$(( miss + 1 ))
    strikes=$(( strikes + 1 ))
    restart_transcode "frame stale ${age}s (strike ${strikes})"
    if [ "$miss" -ge 2 ]; then
      log "still stale after restart -> bouncing mjpg-streamer"
      pkill -KILL -x mjpg_streamer 2>/dev/null || true
      miss=0
    fi
    if [ "$VIDEO_GO2RTC_RESTART_STRIKES" -gt 0 ] && [ "$strikes" -ge "$VIDEO_GO2RTC_RESTART_STRIKES" ]; then
      maybe_restart_go2rtc
      strikes=0
    fi
    sleep "$VIDEO_WATCHDOG_GRACE"
    continue
  fi
  miss=0; strikes=0

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

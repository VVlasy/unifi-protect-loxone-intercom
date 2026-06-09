#!/usr/bin/env bash
# ==============================================================================
# Map Home Assistant add-on options (/data/options.json) -> environment for
# entrypoint.sh, then hand over to it.
#
# Outside Home Assistant (standalone docker compose / k8s) /data/options.json
# does not exist: configuration comes from plain env vars and this script is a
# pass-through. The image is ubuntu-based (no bashio), so options are read
# with jq directly.
#
# Empty/unset options are NOT exported — the defaults baked into the image
# (Dockerfile ENV) and the scripts' own fallbacks stay in effect.
# ==============================================================================
set -euo pipefail

if [ -f /data/options.json ]; then
    echo "[run] Home Assistant mode: mapping add-on options to environment"

    opt() {
        jq -r --arg k "$1" \
            'if has($k) and .[$k] != null then .[$k] else empty end' \
            /data/options.json
    }

    # setenv ENV_VAR option_key — export only when non-empty (keep image default)
    setenv() {
        local v
        v="$(opt "$2")"
        [ -n "$v" ] && export "$1=$v" || true
    }

    setenv PROTECT_CAMERA_PATH  protect_camera_path
    setenv PROTECT_BASE         protect_base
    setenv PROTECT_API_KEY      protect_api_key
    setenv CAMERA_ID            camera_id
    setenv DOORBELL_EXTENSION   doorbell_extension
    setenv SIP_EXTERNAL_ADDRESS sip_external_address
    setenv SIP_LOCAL_NET        sip_local_net
    setenv MJPEG_FPS            mjpeg_fps
    setenv MJPEG_SCALE_W        mjpeg_scale_w
    setenv MJPEG_QUALITY        mjpeg_quality
    setenv MJPEG_AUTH_USER      mjpeg_auth_user
    setenv MJPEG_AUTH_PASS      mjpeg_auth_pass
    setenv DUCK_TALK_THRESHOLD  duck_talk_threshold
    setenv DUCK_ATTEN_DB        duck_atten_db
    setenv DUCK_HOLD_MS         duck_hold_ms
    setenv MAX_CALL_SECS        max_call_secs
    setenv DEBUG_SIP            debug_sip

    # mjpeg_rotation dropdown -> ffmpeg transpose chain
    # (transpose=1 is 90° clockwise, 2 is 90° counter-clockwise, "1,1" is 180°)
    case "$(opt mjpeg_rotation)" in
        90cw)    export MJPEG_TRANSPOSE="1" ;;
        90ccw)   export MJPEG_TRANSPOSE="2" ;;
        180)     export MJPEG_TRANSPOSE="1,1" ;;
        none|"") : ;;
        *)       echo "[run] unknown mjpeg_rotation '$(opt mjpeg_rotation)', ignoring" ;;
    esac
else
    echo "[run] no /data/options.json -> standalone mode, using environment as-is"
fi

exec /usr/local/bin/entrypoint.sh

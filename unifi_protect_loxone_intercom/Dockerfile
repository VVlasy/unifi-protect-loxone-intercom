# syntax=docker/dockerfile:1
#==============================================================================
# UniFi Protect doorbell  <->  Asterisk  <->  Loxone Intercom block
#
# One image containing: Asterisk (PBX), the Fusseldieb bridge, go2rtc and
# ffmpeg, supervised together. Doubles as a Home Assistant add-on: the HA
# Supervisor builds this same Dockerfile locally (run.sh maps the add-on
# options to env). Arch (amd64/arm64) is detected at build time from dpkg,
# so plain `docker build`, buildx and the Supervisor builder all work.
#==============================================================================
FROM ubuntu:24.04

# Passed by the HA Supervisor builder; harmless when building standalone.
ARG BUILD_VERSION
ARG BUILD_ARCH
# Pin the bridge to a known-good commit for reproducible builds.
ARG BRIDGE_COMMIT=1a3e8f47338d71be811ac9013483e7fb9d649725
ARG GO2RTC_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        asterisk \
        ffmpeg \
        nodejs \
        npm \
        supervisor \
        curl \
        wget \
        ca-certificates \
        git \
        jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# --- the bridge (pinned) -----------------------------------------------------
RUN git clone https://github.com/Fusseldieb/unifiprotect-sip-bridge.git /app \
    && git -C /app checkout ${BRIDGE_COMMIT} \
    && npm install --omit=dev

# --- local patch: gentler, env-tunable half-duplex ducking -------------------
# Stock bridge HARD-MUTES the doorbell->caller audio whenever talk is detected on
# the caller leg; over a real SIP path that chops the doorbell audio badly. This
# patch replaces the mute with a soft VOLUME(TX) attenuation and makes the talk
# threshold + attenuation tunable via DUCK_TALK_THRESHOLD / DUCK_ATTEN_DB.
# Idempotent (guarded by a /* DUCK_PATCH */ marker).
COPY patches/ /app/patches/
RUN node /app/patches/duck-soft-attenuation.js /app/index.js

# --- go2rtc binary -----------------------------------------------------------
# amd64 -> go2rtc_linux_amd64 ; arm64 -> go2rtc_linux_arm64. Detected from the
# image's own dpkg arch (NOT buildx TARGETARCH) so the HA Supervisor's plain
# docker build picks the right binary too.
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "${ARCH}" in \
        amd64) GO2RTC_FILE=go2rtc_linux_amd64 ;; \
        arm64) GO2RTC_FILE=go2rtc_linux_arm64 ;; \
        *) echo "unsupported arch ${ARCH}" && exit 1 ;; \
    esac; \
    if [ "${GO2RTC_VERSION}" = "latest" ]; then \
        URL="https://github.com/AlexxIT/go2rtc/releases/latest/download/${GO2RTC_FILE}"; \
    else \
        URL="https://github.com/AlexxIT/go2rtc/releases/download/${GO2RTC_VERSION}/${GO2RTC_FILE}"; \
    fi; \
    wget -qO /app/go2rtc "${URL}"; \
    chmod +x /app/go2rtc

# --- mjpg-streamer (compiled) ------------------------------------------------
# Serves the doorbell video as MJPEG at :MJPEG_PORT/?action=stream, fed by a
# continuous ffmpeg transcode (always warm -> instant open). Mirrors the user's
# k3s kamera-vchod-mjpeg pipeline. Not in apt; build the jacksonliam fork.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends cmake build-essential libjpeg-turbo8-dev; \
    git clone https://github.com/jacksonliam/mjpg-streamer.git /tmp/mjpg; \
    make -C /tmp/mjpg/mjpg-streamer-experimental; \
    make -C /tmp/mjpg/mjpg-streamer-experimental install; \
    ldconfig; \
    rm -rf /tmp/mjpg /var/lib/apt/lists/*

# --- our config & glue -------------------------------------------------------
COPY asterisk/         /etc/asterisk/
COPY go2rtc.yaml.template /app/go2rtc.yaml.template
COPY supervisord.conf  /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh     /usr/local/bin/entrypoint.sh
COPY mjpeg-video.sh    /usr/local/bin/mjpeg-video.sh
COPY mjpg-serve.sh     /usr/local/bin/mjpg-serve.sh
COPY video-watchdog.sh /usr/local/bin/video-watchdog.sh
COPY snapshot-delay.sh /usr/local/bin/snapshot-delay.sh
COPY run.sh            /run.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/mjpeg-video.sh /usr/local/bin/mjpg-serve.sh /usr/local/bin/video-watchdog.sh /usr/local/bin/snapshot-delay.sh /run.sh

# Binary/path hints for the bridge (overridable via env)
ENV GO2RTC_PATH=/app/go2rtc \
    GO2RTC_CONFIG=/app/go2rtc.yaml \
    FFMPEG_PATH=ffmpeg

# --- Internal defaults --------------------------------------------------------
# These are implementation details, not user config. They were once in .env but
# never need changing for a normal setup, so they live here to keep .env tiny.
# Anything here can still be overridden via the environment if you really need to.
ENV ARI_URL=http://127.0.0.1:8088 \
    ARI_USER=doorbellari \
    APP_NAME=doorbellbridge \
    RX_PORT_FROM_ASTERISK=9999 \
    DOORBELL_RTSP_AUDIO="rtsp://127.0.0.1:8554/unifi_doorbell?audio" \
    DOORBELL_EXTENSION=9900 \
    RING_ENDPOINTS=PJSIP/101 \
    DOORBELL_CALLERID="Doorbell <9900>" \
    RING_TIMEOUT_MS=45000 \
    NO_ANSWER_TIMEOUT_MS=30000 \
    RING_DELAY_MS=3500 \
    ENABLE_AGC=1 \
    DUCK_TALK_THRESHOLD=180 \
    DUCK_ATTEN_DB=-30 \
    DUCK_HOLD_MS=900 \
    MJPEG_PORT=1984 \
    WEBHOOK_BIND=0.0.0.0 \
    WEBHOOK_PORT=3000 \
    WEBHOOK_PATH=/doorbell/ring

# SIP, RTP, mjpg-streamer MJPEG (1984), go2rtc API (1985)/RTSP (8554), webhook.
# (host networking is strongly recommended; EXPOSE is documentation only in that mode.)
EXPOSE 5060/udp 10000-10200/udp 1984/tcp 1985/tcp 8554/tcp 3000/tcp

LABEL \
  io.hass.version="${BUILD_VERSION}" \
  io.hass.type="app" \
  io.hass.arch="${BUILD_ARCH}"

# run.sh maps HA add-on options -> env when /data/options.json exists, then
# execs entrypoint.sh; standalone (compose/k8s) it is a pure pass-through.
CMD [ "/run.sh" ]

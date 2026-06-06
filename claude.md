# CLAUDE.md — working brief for Claude Code

Agent context for continuing work on this repo. Read this before changing anything.
The human-facing setup steps live in `README.md`; this file is the engineering state,
the risk ledger, and the task backlog.

## What this repo is

A single container that bridges a **UniFi Protect doorbell** (no SIP) to the
**Loxone Door Controller** (SIP-only, anonymous, direct-IP). Components, all
supervised by `supervisord`:

- **Asterisk** — tiny local PBX; terminates the anonymous SIP call from the Loxone app.
- **Fusseldieb `unifiprotect-sip-bridge`** (vendored via `git clone` in the Dockerfile,
  pinned to `BRIDGE_COMMIT=1a3e8f47338d71be811ac9013483e7fb9d649725`) — connects
  Asterisk (ARI) to the doorbell's talkback over Protect's official Integration API.
  It also **spawns go2rtc itself**.
- **go2rtc** — pulls the doorbell RTSPS stream; serves audio to the bridge and an
  MJPEG image to Loxone.

## Current state

- Assembled and **config-validated only** (shell syntax, template renders, YAML parse).
- **Never built or run end-to-end.** No `docker build` was possible in the authoring
  sandbox. Treat first build as a real bring-up.
- Target arch assumed **amd64**; arm64 path exists (`--build-arg TARGETARCH=arm64`) but
  is unverified.

## Data flow (with source anchors in the vendored bridge)

Audio, Loxone → door:
```
Loxone app --anon SIP INVITE--> Asterisk :5060
  --> dialplan [from-loxone] ext 9900 --> Stasis(doorbellbridge,call)
  --> index.js StasisStart handler, mode 'call'        (~line 881)
  --> startTwoWayBridgeForCaller()                     (~line 628)
  --> startTwoWayBridgeForWinner(): ARI externalMedia, format 'ulaw',
      external_host 127.0.0.1:${RX_PORT_FROM_ASTERISK} (~line 569)
  --> caller audio -> node RX (SDP recvonly PCMU/8000) -> 24k mono -> opus
  --> POST talkback-session, X-API-KEY                  (talkbackUrl, ~line 174)
```
Audio, door → Loxone: ffmpeg pulls `DOORBELL_RTSP_AUDIO`
(`rtsp://127.0.0.1:8554/unifi_doorbell?audio`) → PCMU RTP → Asterisk inject port.

Video: go2rtc `unifi_doorbell_video` stream → `http://<host>:1984/api/stream.mjpeg`.

Audio engine constant: `SR=24000`, 20 ms frames (index.js ~line 57). Codec on the
Loxone/Asterisk side is **G.711 PCMU** end to end (sdp template + pjsip `allow=ulaw`).

## Verified-from-source vs inferred

**Verified** (read in index.js / setup.js):
- Official Protect Integration API for talkback (`X-API-KEY`), not the old login API.
- ARI app name `doorbellbridge`; dial-in mode is the `'call'` arg.
- externalMedia uses `ulaw`; RX SDP is PCMU recvonly on `RX_PORT_FROM_ASTERISK`.
- Bridge spawns go2rtc (`GO2RTC_PATH`/`GO2RTC_CONFIG`, index.js ~line 142).
- `RING_ENDPOINTS` is mandatory in code (`.split(',')`); unset → crash. Hence the
  `PJSIP/101` default baked into the Dockerfile `ENV` block.

**Inferred / not published anywhere** (the risk):
- The Loxone→Asterisk hop: anonymous INVITE → PJSIP `anonymous` endpoint → `9900`.
  Pattern matches documented 2N/Grandstream+Loxone, but this exact bridge→Asterisk→
  Loxone chain is untested. **De-risk per README §6 before anything else.**

## Guardrails — do not regress these

1. **Host networking is mandatory.** SIP/RTP embed IP/ports in SDP; symmetric RTP.
   Never move to bridged/NAT networking. K3s: keep `hostNetwork: true` + single-node pin.
2. **Codec stays G.711 (ulaw/alaw).** The Loxone app offers G.711; do not narrow
   `allow=` in pjsip.conf or change the SDP payload type.
3. **ARI bound to 127.0.0.1 only** (http.conf). Don't expose 8088 on the LAN.
4. **`RING_DELAY_MS >= 3000`** — author-documented latency cliff below ~2.5–3 s.
5. Keep the bridge commit **pinned**; this is an unmaintained solo project.

## Refinement backlog (priority order)

1. **Bring-up.** Build, run, and prove `sip:9900@<host>` from a softphone
   (Linphone/Zoiper, anonymous). Success log line: `switched speaker to LIVE audio`.
   Only then wire Loxone. This validates the one inferred hop.
2. **Lock the dialplan.** Once the real "Audio username" Loxone sends is known,
   remove the `_X.` catch-all in `extensions.conf` (currently a convenience).
3. **go2rtc supervision.** The bridge spawns go2rtc but only kills it on shutdown
   (index.js `shutdown()` ~line 944). If go2rtc dies mid-run it is not respawned.
   Either run go2rtc as its own `supervisord` program (and set `GO2RTC_PATH` to a
   no-op/external) or add a watchdog. Decide one; don't double-spawn.
4. **Startup race.** `supervisord.conf` waits for ARI via curl before `node index.js`.
   Confirm this holds on slow nodes; if flaky, gate on a deeper ARI readiness check.
5. **Pin go2rtc.** Dockerfile uses `GO2RTC_VERSION=latest`. Pin to a release tag for
   reproducible builds.
6. **arm64.** Verify go2rtc asset name + Asterisk package on arm64 if any target node
   is ARM, then drop the amd64 assumption note from README.
7. **Remote/external audio (optional).** Loxone "external" fields need a SIP proxy.
   Options: register Asterisk to an external proxy (Antisip-style) and fill the Door
   Controller external host/username; or reverse-proxy 5060. Keep local working first.
8. **Door-open button (optional).** UniFi doorbells have no relay, so Loxone Q1–Q3
   would drive a Loxone-side relay, not the doorbell. Only relevant if a lock is wired
   to the Miniserver. `dtmf_mode=rfc4733` is already set if DTMF is ever needed.
9. **Observability.** Add a container `HEALTHCHECK` (e.g. ARI info + go2rtc API ping)
   and structured logging so failures are diagnosable without attaching to Asterisk.

## How to test / debug

```bash
docker compose up -d --build && docker compose logs -f
# inside the container:
docker exec -it unifi-loxone-doorbell asterisk -rx "pjsip set logger on"
docker exec -it unifi-loxone-doorbell asterisk -rx "ari show apps"      # expect doorbellbridge
docker exec -it unifi-loxone-doorbell asterisk -rx "pjsip show endpoints"
curl -s http://<host>:1984/api/streams                                   # go2rtc health
```

## File map

- `Dockerfile` — Ubuntu 24.04 + asterisk + ffmpeg + node + go2rtc + pinned bridge.
  Holds the internal-default `ENV` block (ARI_*, RING_*, DUCK_*, MJPEG_PORT,
  DOORBELL_EXTENSION, …) that used to live in `.env`.
- `entrypoint.sh` — validates the 4 PROTECT_* values; **auto-generates ARI_PASS /
  WEBHOOK_TOKEN** if unset; renders ari.conf password, extensions.conf
  (`__DOORBELL_EXTENSION__`), go2rtc.yaml, SDP from env; execs supervisord.
- `supervisord.conf` — asterisk (prio 10) + bridge (prio 20, waits for ARI) + rotation-watchdog (prio 40).
- `asterisk/` — pjsip (anonymous→from-loxone; `#include pjsip_transport_extra.conf`,
  which entrypoint renders from `SIP_EXTERNAL_ADDRESS`/`SIP_LOCAL_NET` — empty =
  LAN-only), extensions (rendered `DOORBELL_EXTENSION`→Stasis, default 9900),
  ari/http/rtp/modules. **Every user-facing asterisk setting is now env-driven** (no
  hand-edited files) so .env / a future HA-addon options map is the single source.
- `go2rtc.yaml.template` — audio + video streams from `PROTECT_CAMERA_PATH`.
- `.env.example` — **slimmed to the 4 required PROTECT_* values + an optional block**;
  internal vars are Dockerfile `ENV` defaults (bridge reads env directly; setup.js NOT used).
- `README.md` — public-facing quickstart. `ADVANCED.md` — LXC, remote SIP, fail2ban,
  k8s, and the camera-landscape deep-dive (moved out of the README/old DEPLOYMENT-GUIDE).
- `docker-compose.yml` / `k8s-deployment.yaml` — host-networked deploy.
- `patches/camera-rotation-watchdog.sh` + `rot90.c`/`rot90.so` + `streamer_wrap.sh` — see below.

## Camera rotation (landscape) fix — `patches/camera-rotation-watchdog.sh`

The UniFi **Doorbell Lite (G6O, Sigmastar Infinity6E)** hardcodes a 90° portrait
("hallway") rotation. Protect **cannot** disable it: the camera reports
`featureFlags.hasHallwayMode=false` and ignores the controller's
`hallwayMode=disabled`, so Protect/recordings/go2rtc all get portrait `1920×2560`
while other cameras are landscape. Making it landscape requires overriding it
**on the camera**, and that override is not natively persistent — hence a watchdog.

How landscape-upright is produced (two pieces, both on the camera):
1. **`rot90.so`** — `LD_PRELOAD` shim interposing the encoder's C++ getter
   `ubnt::encoder::VideoEncoderSettings::hallwayMode()` to return `0` (disabled) →
   the encoder emits the native **landscape** sensor frame. Injected by
   bind-mounting `streamer_wrap.sh` over `/bin/ubnt_streamer` (wrapper LD_PRELOADs
   the shim, execs the real binary copied to `/etc/persistent/realbin/`). The
   forced value is read from `/etc/persistent/hallway_val` (NOT baked into the
   wrapper — the bind-mount pins the wrapper inode, so a rewrite wouldn't take).
2. **ISP `flip`+`mirror`=1** in `/etc/persistent/ubnt_isp.conf` → 180°, to correct
   the now upside-down native landscape.

**Hard-won gotchas (do not regress):**
- The streamer **ignores SIGTERM as a no-op restart but** must be restarted with
  plain `kill` (SIGTERM), **NEVER `kill -9`** — SIGKILL on the *critical* streamer
  makes the on-camera supervisor **reboot the whole camera**. Same for ispserver
  (non-critical, safer).
- `/etc/persistent` is wiped by `cfgmtd` on boot except a whitelist; the bind-mount
  is volatile → nothing survives a camera reboot → the watchdog re-applies.
- `rot90.so` must be built against the camera's **glibc 2.30** symbol versions
  (link with the camera's own `libc.so.6`; see header in `rot90.c`). ARMv7 hard-float.
- `MI_VPE_SetChannelRotation` alone does NOT rotate output here; the encoder's
  `hallwayMode` path (with its own dim handling) is the working lever.

**Watchdog:** runs in this container (which is on the camera's LAN subnet, so SSH
stays local and doesn't trip the UniFi IPS — heavy SSH over VPN *does*). Every
`ROTATION_CHECK_INTERVAL`s it SSHes `ubnt@CAMERA_IP` (password = camera **Recovery
Code**), checks the hook+flip, and re-applies on drift. No-op unless
`ROTATION_FIX_ENABLED=1`. **Prerequisite:** camera SSH enabled on the UDM via
`/etc/unifi-protect/config.json` → `{"enableSsh": true}` + restart `unifi-protect`.
If this works at the source, consider dropping `MJPEG_TRANSPOSE` (no double-rotate).
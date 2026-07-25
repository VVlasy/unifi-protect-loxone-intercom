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
- **`sdp-relay`** (`sip_sdp_relay.py`) — userspace SIP relay. With
  `SIP_EXTERNAL_ADDRESS` set it owns UDP :5060 and Asterisk moves to
  127.0.0.1:5070 behind it; it sanitizes malformed inbound SDP (Loxone
  remote-call client bug, see below) and rewrites Asterisk's loopback
  self-references (Contact/Via + SDP c=/o=) to the per-caller LAN/external
  address, replacing Asterisk's external_* transport options. Idle no-op
  otherwise (Asterisk binds :5060 directly). Stdlib Python, no privileges.

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
  Loxone chain is untested. **De-risk per README §5 before anything else.**

**Confirmed from live user captures (2026-07-25):** Loxone's remote/off-LAN
SIP client (`User-Agent: Loxone Pjsua2 Wrapper`, via its cloud relay; seen on
cellular/CGNAT connections) sends SDP bodies with truncated bandwidth lines
(`:=4` instead of `b=AS:4`), which Asterisk correctly rejects
(`PJMEDIA_SDP_EINSDP`/400) — remote calls failed while LAN calls worked. This
is a Loxone client bug, not an Asterisk config bug; there's no PJSIP option
to relax SDP parsing. **1.0.3 tried an NFQUEUE fix — dead end: the HAOS
kernel has no nfnetlink_queue module** (`iptables ... RULE_APPEND failed`
in the boot log), which is why 1.0.4 replaced it with the `sdp-relay`
userspace component above. See ADVANCED.md "Known issue: Loxone's
remote-call client sends invalid SDP". Relay-mode side effect: Asterisk only
sees 127.0.0.1 sources, so fail2ban gained a `doorbell-relay` filter/jail
fed by the relay's own `relay_security` log.

## Guardrails — do not regress these

1. **Host networking is mandatory.** SIP/RTP embed IP/ports in SDP; symmetric RTP.
   Never move to bridged/NAT networking. K3s: keep `hostNetwork: true` + single-node pin.
2. **Codec stays G.711 (ulaw/alaw).** The Loxone app offers G.711; do not narrow
   `allow=` in pjsip.conf or change the SDP payload type.
3. **ARI bound to 127.0.0.1 only** (http.conf). Don't expose 8088 on the LAN.
4. **`RING_DELAY_MS >= 3000`** — author-documented latency cliff below ~2.5–3 s.
5. Keep the bridge commit **pinned**; this is an unmaintained solo project.
6. **Relay mode is all-or-nothing on :5060.** With `SIP_EXTERNAL_ADDRESS`
   set, `sdp-relay` owns :5060 and Asterisk MUST bind 127.0.0.1:5070 (the
   entrypoint renders `__SIP_BIND__` in pjsip.conf accordingly) and Asterisk
   must NOT get external_media_address/external_signaling_address (the relay
   does all rewriting; setting them would corrupt it). Don't "fix" the
   loopback bind back to 0.0.0.0:5060 in relay mode — the two would fight
   over the port — and don't remove the relay without restoring the direct
   bind, or SIP dies entirely. NFQUEUE is a known dead end on HAOS (no
   nfnetlink_queue kernel module); don't reintroduce it.

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

The repo doubles as a **Home Assistant add-on repository** (root
`repository.yaml` + add-on folder `unifi_protect_loxone_intercom/`). All
build assets live INSIDE the add-on folder
(= the build context for both the HA Supervisor and docker-compose);
`.env.example`, `docker-compose.yml`, `k8s-deployment.yaml`, `fail2ban/` and the
docs stay at the root. Paths below are relative to `unifi_protect_loxone_intercom/`.

- `config.yaml` — HA add-on manifest: options/schema (snake_case mirror of the
  env vars), `host_network: true` (required). `translations/en.yaml` = option help
  texts; `DOCS.md` = Documentation tab; `CHANGELOG.md` versioned with `version:`.
- `run.sh` — HA glue: maps `/data/options.json` → env via jq (NO bashio — base
  image is ubuntu), skips empty options so image ENV defaults stay; maps the
  `mjpeg_rotation` dropdown (none/90cw/90ccw/180) → `MJPEG_TRANSPOSE`; execs
  entrypoint.sh. Without options.json it's a pass-through (standalone mode).
- `Dockerfile` — Ubuntu 24.04 + asterisk + ffmpeg + node + go2rtc + pinned bridge.
  Holds the internal-default `ENV` block (ARI_*, RING_*, DUCK_*, MJPEG_PORT,
  DOORBELL_EXTENSION, …) that used to live in `.env`. go2rtc arch comes from
  `dpkg --print-architecture` (works under buildx AND the Supervisor's plain
  docker build). `CMD /run.sh`.
- `entrypoint.sh` — validates the 4 PROTECT_* values; **auto-generates ARI_PASS /
  WEBHOOK_TOKEN** if unset; renders ari.conf password, extensions.conf
  (`__DOORBELL_EXTENSION__`), go2rtc.yaml, SDP from env; execs supervisord.
- `supervisord.conf` — asterisk (prio 10) + bridge (prio 20, waits for ARI) + video pipeline (prio 30/45).
- `asterisk/` — pjsip (anonymous→from-loxone; `#include pjsip_transport_extra.conf`,
  which entrypoint renders from `SIP_EXTERNAL_ADDRESS`/`SIP_LOCAL_NET` — empty =
  LAN-only), extensions (rendered `DOORBELL_EXTENSION`→Stasis, default 9900),
  ari/http/rtp/modules. **Every user-facing asterisk setting is env-driven** (no
  hand-edited files) so .env / the HA options map is the single source.
- `go2rtc.yaml.template` — audio + video streams from `PROTECT_CAMERA_PATH`.
- `sip_sdp_relay.py` — the `sdp-relay` supervisord program; see "Confirmed
  from live user captures" above and ADVANCED.md. Companion fail2ban files:
  `fail2ban/filter.d/doorbell-relay.conf` + the `[doorbell-relay]` jail.
- `.env.example` — **slimmed to the 4 required PROTECT_* values + an optional block**;
  internal vars are Dockerfile `ENV` defaults (bridge reads env directly; setup.js NOT used).
- `README.md` — public-facing quickstart. `ADVANCED.md` — LXC, remote SIP, fail2ban,
  k8s (moved out of the README/old DEPLOYMENT-GUIDE).
- `docker-compose.yml` / `k8s-deployment.yaml` — host-networked deploy.
- `patches/duck-soft-attenuation.js` — build-time patch of the vendored bridge (soft ducking).

## Camera orientation

If the camera's rotation is fixed at the source (camera already outputs
landscape), keep `MJPEG_TRANSPOSE` / `mjpeg_rotation` at none — transposing
would double-rotate. The video-watchdog's orientation check handles the camera
flipping between portrait/landscape at runtime.
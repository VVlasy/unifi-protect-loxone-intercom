# UniFi Protect doorbell → Loxone Intercom (via Asterisk)

A single container that makes a **UniFi Protect doorbell** (G4 Doorbell Lite et al.)
answerable from the **Loxone Intercom / Door Controller** block, with two-way audio
and live video.

UniFi Protect speaks no SIP. Loxone's Door Controller speaks only SIP (anonymous,
direct-IP). This image bridges the gap: it runs Asterisk as a tiny local PBX, the
Fusseldieb `unifiprotect-sip-bridge` to reach the doorbell's talkback over Protect's
official Integration API, and `go2rtc` for the video image.

```
   Loxone app (phone)                          UniFi Protect
        │  anonymous SIP INVITE                  ▲   talkback (official API, X-API-KEY)
        │  to <host>:5060, user 9900             │   + RTSPS stream
        ▼                                        │
   ┌─────────────────────────────────────────────────────┐
   │  this container (host networking)                    │
   │                                                       │
   │  Asterisk ──9900──► Stasis(doorbellbridge) ──► bridge │
   │     ▲  ARI :8088                                  │   │
   │     │                                  go2rtc ◄───┘   │
   │     │                                  :1984 MJPEG ───┼──► Loxone video
   └─────────────────────────────────────────────────────┘
```

Ring notification to Loxone is done separately and more robustly via a Protect
**Alarm Manager webhook → Loxone Virtual Input** (see step 5).

It also includes an **optional** fix to force a portrait-locked UniFi doorbell to
output **landscape** (matching your other cameras) — see section 8.

---

## 1. Prerequisites

- A UniFi Protect controller (UDM/Cloud Key) with the doorbell adopted.
- A host with **host networking**: a Docker host / Proxmox VM or LXC, or a K3s node.
  SIP and RTP put IPs and ports inside the SDP and use symmetric RTP; behind a NAT
  bridge the audio silently dies. This must run on the host network.
- The host's LAN IP is what you give Loxone. Keep it static.

## 2. UniFi Protect setup

1. **RTSP share link** — open the doorbell in Protect → *Settings → Advanced →
   RTSP*, enable a stream, copy the `rtspx://<protect-ip>:7441/<key>` URL. This is
   `PROTECT_CAMERA_PATH`.
2. **Integration API key** — *Protect → Settings → Control Plane → Integrations →*
   create a key. This is `PROTECT_API_KEY`. (This is the official API; it does not
   break on the 2FA/local-account changes that killed older community tools.)
3. **Camera ID** — open the camera in the Protect web UI; the URL is
   `https://<ip>/protect/devices/<CAMERA_ID>`. That last segment is `CAMERA_ID`.
4. **Ring repeat = 1** — in the doorbell's chime/ring settings set repeat to **1**.
   The bridge author notes >1 causes stream issues.

## 3. Configure

```bash
cp .env.example .env
# edit .env: PROTECT_CAMERA_PATH, PROTECT_BASE, PROTECT_API_KEY, CAMERA_ID,
# and a long random ARI_PASS / WEBHOOK_TOKEN.
```

## 4. Build & run

**Docker / Proxmox:**
```bash
docker compose up -d --build
docker compose logs -f          # watch for "ARI and go2rtc are active."
```

**K3s:** build and push the image, then:
```bash
# create the env secret straight from your .env:
kubectl create namespace home
kubectl create secret generic doorbell-bridge-env --from-env-file=.env -n home
# edit k8s-deployment.yaml: set image + nodeSelector hostname, remove the inline
# Secret block if you created it from .env above, then:
kubectl apply -f k8s-deployment.yaml
```
Pin it to one node (`nodeSelector`) so the LAN IP Loxone calls never moves.

## 5. Loxone Config — the part that matters

Create (or reuse) an **Intercom** network device, then a **Door Controller** object
linked to it. Set these properties (the *local* fields; leave *external* blank until
local works):

| Door Controller property            | Value                                                            |
|-------------------------------------|------------------------------------------------------------------|
| **Host for audio (local)**          | `<host LAN IP>`  ← the machine running this container            |
| **Audio username (local)**          | `9900`                                                           |
| **URL video stream**                | `http://<user>:<pass>@<host LAN IP>:1984/?action=stream`         |

Notes:
- The Loxone app sends an **anonymous** call — there is no password field, and you
  do **not** register anything. "Host" is the box's IP, "Audio username" is the
  number being dialled (9900), exactly as with a 2N/Grandstream intercom.
- Video is served by **mjpg-streamer** on `:1984`, fed by a continuous ffmpeg
  transcode (always warm → instant open). Snapshot form: `:1984/?action=snapshot`.
  Basic auth via `MJPEG_AUTH_USER`/`MJPEG_AUTH_PASS` in `.env` (drop both for none).
- go2rtc still runs for the **audio** path (moved to API `:1985`) and serves the raw
  video on RTSP `:8554`; mjpg-streamer reads that local RTSP to build the MJPEG.

**Ring → Loxone notification (separate path):**
1. In Loxone Config add a **Virtual Input** (e.g. `Doorbell`), note its HTTP command
   (`http://<user>:<pass>@<miniserver>/dev/sps/io/<VI>/1`).
2. Wire that Virtual Input to the Door Controller's bell/trigger input.
3. In Protect → *Alarm Manager → Create Alarm*: trigger = doorbell ring, action =
   webhook → that Loxone Virtual Input URL.

Now a press lights up the Door Controller (image + notification); tapping the call
icon opens two-way audio through 9900.

## 6. Test the make-or-break leg FIRST

Before touching Loxone, prove the `9900` audio path with any SIP softphone, because
this Loxone→Asterisk→bridge chain is the one piece nobody has published — it follows
the standard "Loxone + PBX" pattern, but verify it on your gear:

1. Point a softphone (Linphone, Zoiper) at the host as an **anonymous/guest** SIP
   server, or simply dial `sip:9900@<host-ip>` with no registration.
2. You should hear the doorbell mic and be heard at the door.
3. Watch `docker compose logs -f` for `switched speaker to LIVE audio`.

If 9900 works from a softphone, Loxone will work — it makes the same anonymous call.
If it doesn't, the problem is Asterisk/bridge, not Loxone, and the logs will say so.

## 7. Ports (host networking)

| Port            | Proto | Who                                  |
|-----------------|-------|--------------------------------------|
| 5060            | UDP   | Loxone app → Asterisk (SIP)          |
| 10000–10200     | UDP   | RTP media                            |
| 1984            | TCP   | Loxone ← go2rtc (video image)        |
| 8554            | TCP   | internal (bridge ← go2rtc audio)     |
| 3000            | TCP   | Protect → bridge ring webhook (opt.) |
| 8088 / 9999     | TCP/UDP | localhost only (ARI / RTP rx)      |

Open 5060/udp, 10000-10200/udp and 1984/tcp on the host firewall toward your LAN.

## 8. Optional: force the doorbell to landscape

UniFi doorbells are **portrait by design** (a tall view of a person at the door)
and hardcode a 90° "hallway" rotation in firmware. Protect **cannot disable it** for
doorbells — the camera reports `hasHallwayMode=false` and ignores the controller's
`hallwayMode`. If yours watches a wide scene (street, driveway) you may want it
**landscape** like your other cameras. This is an opt-in hack that corrects the
orientation **at the source**, so Protect, recordings *and* the Loxone feed are all
fixed (no per-consumer rotation needed).

**How it works** — entirely on the camera, kept applied by a watchdog:
- `patches/rot90.so` — a tiny `LD_PRELOAD` shim that interposes the encoder's
  hallway-mode getter and forces it to *disabled* → the camera emits its native
  **landscape** frame (upside-down for a typical doorbell mount). Injected by
  bind-mounting `patches/streamer_wrap.sh` over `/bin/ubnt_streamer`.
- ISP `flip`+`mirror` are set (= 180°) to turn that landscape **upright**.
- `patches/camera-rotation-watchdog.sh` runs in this container, SSHes the camera
  every `ROTATION_CHECK_INTERVAL`s and **re-applies** both whenever they drift —
  they don't survive a camera reboot (`/etc/persistent` is wiped on boot and the
  injection is volatile).

**Prerequisites**
1. **Enable camera SSH.** On the UDM, set `{"enableSsh": true}` in the file Protect's
   `overrides` points to — `/etc/unifi-protect/config.json` on current builds (verify
   with `jq .overrides /usr/share/unifi-protect/app/config/default.json`) — then
   `systemctl restart unifi-protect`. The camera then accepts SSH as user `ubnt`
   with the camera's **Recovery Code** as the password.
2. This container is on the camera's **LAN subnet** (host networking), so its SSH to
   the camera stays local — important, since heavy SSH *over a VPN* can trip the
   UniFi IPS and black out the subnet.

**Enable it** — in `.env`:
```
ROTATION_FIX_ENABLED=1
CAMERA_IP=<doorbell LAN IP>
CAMERA_SSH_PASS=<camera Recovery Code>
# defaults: HALLWAY_VALUE=0  ISP_FLIP=1  ISP_MIRROR=1  ROTATION_CHECK_INTERVAL=30
```
Rebuild (`docker compose up -d --build`) and watch `docker compose logs -f
rotation-watchdog`. Once the source is landscape, set **`MJPEG_TRANSPOSE=`** (empty)
so the Loxone feed isn't double-rotated.

**Caveats** — this pokes **undocumented firmware internals** of a specific model
(Doorbell Lite, Sigmastar Infinity6E). The watchdog restarts the camera's streamer
with **SIGTERM only** (a SIGKILL makes the camera reboot itself). It will **not
survive a firmware update** without rebuilding `rot90.so` against the new firmware's
libc (see the header in `patches/rot90.c`). Leave `ROTATION_FIX_ENABLED=0` to keep
the doorbell stock. Treat it as a hack, not a supported feature.

## 9. Troubleshooting

- **Call connects, no audio** → almost always networking. Confirm `network_mode:
  host` / `hostNetwork: true`, and that RTP 10000–10200 isn't firewalled.
- **No video in Loxone** → open the MJPEG URL in a browser. If blank, the RTSP share
  link or `PROTECT_CAMERA_PATH` is wrong, or RTSP isn't enabled on the camera.
- **Bridge keeps restarting** → check `PROTECT_API_KEY` / `CAMERA_ID`; the bridge
  validates the talkback session on connect.
- **Loxone "busy" / rejected** → confirm Asterisk got the INVITE:
  `docker exec -it unifi-loxone-doorbell asterisk -rx "pjsip set logger on"` then
  retry and read the SIP trace.
- **One-way / echo** → toggle `ENABLE_AGC`; the bridge already does half-duplex
  ducking but room acoustics vary.

## 10. Honest caveats

- **Verified from source:** the bridge uses Protect's *official* Integration API for
  talkback, ARI app `doorbellbridge`, extension `9900` → `Stasis(...,call)`, and
  G.711/PCMU audio — which matches what the Loxone app offers.
- **My inference, not published anywhere:** the Loxone→Asterisk hop (anonymous INVITE
  to the `anonymous` endpoint → 9900). It is the same pattern documented for 2N and
  Grandstream with Loxone, so it should hold, but you are the first to wire *this*
  bridge to Loxone. Step 6 is there to de-risk exactly that.
- **Maturity:** the bridge is a solo, low-traffic project whose author says it was
  built for his own setup. Pin the commit (the Dockerfile does), and expect to read
  code if something is off.
- The **landscape fix (section 8)** is the most experimental piece — it overrides
  undocumented camera firmware behaviour and is model-specific. It is fully opt-in
  (`ROTATION_FIX_ENABLED=0` by default) and does not affect the SIP/video bridge.

## License / credit

Bridge: https://github.com/Fusseldieb/unifiprotect-sip-bridge ·
go2rtc: https://github.com/AlexxIT/go2rtc

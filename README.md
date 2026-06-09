# UniFi Protect doorbell → Loxone Intercom

[![Add repository to my Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2FVVlasy%2Funifi-protect-loxone-intercom)

Make a **UniFi Protect doorbell** (G4/G6 Doorbell, Doorbell Lite, …) answerable
from the **Loxone Intercom / Door Controller** block — two-way audio and live
video — with a single container and four lines of config. Runs as a **Home
Assistant app (add-on)** or standalone via docker compose / Kubernetes.

UniFi Protect speaks no SIP. Loxone's Door Controller speaks only SIP (anonymous,
direct-IP). This image bridges the gap: it runs **Asterisk** as a tiny local PBX,
the Fusseldieb [`unifiprotect-sip-bridge`](https://github.com/Fusseldieb/unifiprotect-sip-bridge)
to reach the doorbell's talkback over Protect's official Integration API, and
[`go2rtc`](https://github.com/AlexxIT/go2rtc) + mjpg-streamer for the video image.

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
   │     │                              go2rtc ◄───────┘   │
   │     │                              mjpg-streamer :1984┼──► Loxone video
   └─────────────────────────────────────────────────────┘
```

The doorbell **ring → Loxone** notification is done separately and more robustly
via a Protect **Alarm Manager webhook → Loxone Virtual Input** (see step 6).

---

## 1. What you need

- A **UniFi Protect** controller (UDM/Cloud Key) with the doorbell adopted.
- A host on your LAN that can run Docker with **host networking** — a Docker host,
  a Proxmox VM/LXC, etc. (SIP and RTP put IPs/ports inside the SDP and use
  symmetric RTP; behind a NAT bridge the audio silently dies. This must run on the
  host network.)
- A **Loxone Miniserver** with the Intercom / Door Controller block.

The host's LAN IP is what you give Loxone — keep it static.

## 2. UniFi Protect setup

1. **RTSP share link** — open the doorbell in Protect → *Settings → Advanced →
   RTSP*, enable a stream, copy the URL. For go2rtc use the **`rtspx://`** form:
   `rtspx://<protect-ip>:7441/<key>` → this is `PROTECT_CAMERA_PATH`.
   (A lower-res channel starts/transcodes faster.)
2. **Integration API key** — *Settings → Control Plane → Integrations → Create a
   key*. This is `PROTECT_API_KEY`. It's the official API and survives the
   2FA/local-account changes that broke older community tools.
3. **Camera ID** — open the camera in the Protect web UI; the URL is
   `https://<ip>/protect/devices/<CAMERA_ID>`. That last segment is `CAMERA_ID`.
4. **Ring repeat = 1** — in the doorbell's chime/ring settings set repeat to **1**
   (the bridge author notes >1 causes stream issues).

## 3. Install — Home Assistant (app / add-on)

1. Settings → Apps → App Store → ⋮ → **Repositories** → add
   `https://github.com/VVlasy/unifi-protect-loxone-intercom` (or click the
   badge above).
2. Install **UniFi Protect Loxone Intercom**.
3. Fill in the four `protect_*` options from step 2, start the app, watch
   the log for `ARI and go2rtc are active.`

The app runs on the host network: give Loxone the **Home Assistant host's
IP** as "Host for audio". Ports 5060/udp, 10000-10200/udp, 1984, 8554 must
be free on that host (Frigate / the go2rtc add-on also default to 1984 and
8554). Full details in the app's Documentation tab. Continue at step 5.

## 4. Configure & run — standalone (docker compose)

```bash
cp .env.example .env
# edit .env: set the four PROTECT_* values. That's it.
```

Only four values are required: `PROTECT_CAMERA_PATH`, `PROTECT_BASE`,
`PROTECT_API_KEY`, `CAMERA_ID`. The ARI password and webhook token are generated
automatically at boot; everything else has a sensible default. The optional block
at the bottom of `.env.example` is for tuning and extras.

```bash
docker compose up -d --build
docker compose logs -f          # watch for "ARI and go2rtc are active."
```

That's the whole deployment. Running it inside a Proxmox LXC, on Kubernetes, or
exposing it for remote (off-LAN) access are all covered in **[ADVANCED.md](ADVANCED.md)**.

## 5. Prove the audio leg FIRST (before Loxone)

The Loxone→Asterisk→bridge hop is the make-or-break piece, so verify it on its own
with any SIP softphone (Linphone, Zoiper) before touching Loxone:

1. Point the softphone at the host as an **anonymous/guest** SIP server, or just
   dial `sip:9900@<host-ip>` with no registration.
2. You should hear the doorbell mic and be heard at the door.
3. Watch `docker compose logs -f` for `switched speaker to LIVE audio`.

If `9900` works from a softphone, Loxone will work — it makes the same anonymous
call. If it doesn't, the problem is Asterisk/bridge, not Loxone, and the logs say so.

## 6. Loxone Config

Create (or reuse) an **Intercom** network device, then a **Door Controller** object
linked to it. Set the *local* fields (leave *external* blank until local works):

| Door Controller property   | Value                                                    |
|----------------------------|----------------------------------------------------------|
| **Host for audio (local)** | `<host LAN IP>` — the machine running this container     |
| **Audio username (local)** | `9900`                                                   |
| **URL video stream**       | `http://<host LAN IP>:1984/?action=stream`               |

Notes:
- The Loxone app sends an **anonymous** call — there is no password and nothing
  registers. "Host" is the box's IP, "Audio username" is the number being dialled
  (`9900`), exactly as with a 2N/Grandstream intercom.
- Video is served by **mjpg-streamer** on `:1984`, fed by a continuous ffmpeg
  transcode (always warm → instant open). Snapshot form: `:1984/?action=snapshot`.
- To require auth on the video, set `MJPEG_AUTH_USER`/`MJPEG_AUTH_PASS` in `.env`
  and use `http://<user>:<pass>@<host>:1984/?action=stream`.

**Ring → Loxone notification** (separate path):
1. In Loxone Config add a **Virtual Input** (e.g. `DoorbellRing`, no spaces) and
   wire its output to the Door Controller's bell/ring input. Save → upload.
2. Its trigger URL (use `/Pulse` for a momentary press):
   `http://<user>:<pass>@<miniserver>/dev/sps/io/DoorbellRing/Pulse`
   (use a dedicated, minimal-rights Loxone user).
3. In Protect → *Alarm Manager → Create Alarm*: trigger = doorbell ring, action =
   **Webhook** → that URL. If Protect can't do inline `user:pass@`, send an
   `Authorization: Basic <base64(user:pass)>` header instead.

Now a press lights up the Door Controller (image + notification); tapping the call
icon opens two-way audio through `9900`.

## 7. Ports (host networking)

| Port            | Proto   | Who                                       |
|-----------------|---------|-------------------------------------------|
| 5060            | UDP     | Loxone app → Asterisk (SIP)               |
| 10000–10200     | UDP     | RTP media                                 |
| 1984            | TCP     | Loxone ← mjpg-streamer (video image)      |
| 8554            | TCP     | internal (bridge ← go2rtc audio)          |
| 1985 / 8088     | TCP     | localhost only (go2rtc API / ARI)         |

Open `5060/udp`, `10000-10200/udp` and `1984/tcp` on the host firewall toward your
LAN.

## 8. Troubleshooting

- **Call connects, no audio** → almost always networking. Confirm `network_mode:
  host`, and that RTP `10000–10200/udp` isn't firewalled.
- **No video in Loxone** → open `http://<host>:1984/?action=stream` in a browser. If
  blank, the RTSP share link / `PROTECT_CAMERA_PATH` is wrong, or RTSP isn't enabled
  on the camera.
- **Video rotated the wrong way** → set `MJPEG_TRANSPOSE` (1 ↔ 2, or `1,1` for 180°).
- **Bridge keeps restarting** → check `PROTECT_API_KEY` / `CAMERA_ID`; the bridge
  validates the talkback session on connect.
- **Loxone "busy"/rejected** → confirm Asterisk got the INVITE:
  `docker exec -it unifi-loxone-doorbell asterisk -rx "pjsip set logger on"`, retry,
  read the SIP trace.
- **One-way / echo** → tune `DUCK_ATTEN_DB` / `DUCK_HOLD_MS` (it's a voice-gated
  ducker, not true AEC).

## 9. Honest caveats

- **Verified from source:** the bridge uses Protect's *official* Integration API for
  talkback, ARI app `doorbellbridge`, extension `9900` → `Stasis(...,call)`, and
  G.711/PCMU audio — which matches what the Loxone app offers.
- **The Loxone→Asterisk hop** (anonymous INVITE → `9900`) follows the same pattern
  documented for 2N and Grandstream with Loxone, but this exact bridge→Asterisk→
  Loxone chain is new. Step 5 is there to de-risk it.
- **The bridge** is a solo, low-traffic project; the commit is pinned in the
  Dockerfile. Expect to read code if something is off.

## License / credit

Bridge: https://github.com/Fusseldieb/unifiprotect-sip-bridge ·
go2rtc: https://github.com/AlexxIT/go2rtc ·
mjpg-streamer: https://github.com/jacksonliam/mjpg-streamer

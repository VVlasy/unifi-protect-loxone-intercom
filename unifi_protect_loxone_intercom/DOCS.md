# UniFi Protect Loxone Intercom

Bridges a **UniFi Protect doorbell** to the **Loxone Intercom / Door
Controller** block: the Loxone app's anonymous SIP call is answered by a
local Asterisk, two-way audio reaches the doorbell through Protect's
official Integration API (Fusseldieb `unifiprotect-sip-bridge`), and video
is served to Loxone as an always-warm MJPEG stream (go2rtc + ffmpeg +
mjpg-streamer).

```
   Loxone app (phone)                          UniFi Protect
        │  anonymous SIP INVITE                  ▲   talkback (official API, X-API-KEY)
        │  to <HA host>:5060, user 9900          │   + RTSPS stream
        ▼                                        │
   ┌─────────────────────────────────────────────────────┐
   │  this app (host networking)                          │
   │                                                       │
   │  Asterisk ──9900──► Stasis(doorbellbridge) ──► bridge │
   │     ▲  ARI :8088                                  │   │
   │     │                              go2rtc ◄───────┘   │
   │     │                              mjpg-streamer :1984┼──► Loxone video
   └─────────────────────────────────────────────────────┘
```

The app runs on the **host network** (required: SIP advertises IPs/ports
inside SDP and RTP is symmetric — behind a NAT bridge the audio silently
dies). The Home Assistant host's LAN IP is what you give Loxone — keep it
static.


## Prerequisites (UniFi Protect)

1. **RTSP share link** — doorbell → *Settings → Advanced → RTSP*, enable a
   stream, copy the URL in the **`rtspx://`** form:
   `rtspx://<protect-ip>:7441/<key>` → option `protect_camera_path`.
   (A lower-res channel starts/transcodes faster.)
2. **Integration API key** — *Settings → Control Plane → Integrations →
   Create a key* → option `protect_api_key`.
3. **Camera ID** — open the camera in the Protect web UI; the URL is
   `https://<ip>/protect/devices/<CAMERA_ID>` → option `camera_id`.
4. **Controller URL** — usually `https://<protect-ip>` → option
   `protect_base`.
5. **Ring repeat = 1** — in the doorbell's chime/ring settings (the bridge
   author notes >1 causes stream issues).

Fill those four options, start the app, and watch the log for
`ARI and go2rtc are active.`


## Options

| Option | Meaning |
|---|---|
| `protect_camera_path` | RTSPS share link (`rtspx://…:7441/KEY`) — **required** |
| `protect_base` | Protect controller base URL (`https://<ip>`) — **required** |
| `protect_api_key` | Protect Integration API key — **required** |
| `camera_id` | Doorbell camera id from the Protect URL — **required** |
| `doorbell_extension` | SIP extension Loxone dials ("Audio username"), default `9900` |
| `sip_external_address` / `sip_local_net` | Remote (off-LAN, no-VPN) calling; leave empty for LAN/VPN-only. See `ADVANCED.md` in the repository |
| `mjpeg_fps`, `mjpeg_scale_w`, `mjpeg_quality` | MJPEG stream tuning (default 10 fps, 1280 px, q8) |
| `mjpeg_rotation` | Rotate the Loxone feed: `none`, `90cw`, `90ccw`, `180` |
| `mjpeg_auth_user` / `mjpeg_auth_pass` | Set both to require basic auth on the video stream |
| `duck_talk_threshold`, `duck_atten_db`, `duck_hold_ms` | Echo/ducking tuning (voice-gated attenuation, not true AEC) |

Internal secrets (ARI password, webhook token) are generated automatically
at boot; nothing is persisted.

If your camera already outputs landscape (rotation fixed at the source),
keep `mjpeg_rotation: none` — rotating again would double-rotate.


## Prove the audio leg FIRST (before Loxone)

Verify the Loxone→Asterisk→bridge hop with any SIP softphone (Linphone,
Zoiper) before touching Loxone: dial `sip:9900@<HA host IP>` with no
registration. You should hear the doorbell mic and be heard at the door;
the app log shows `switched speaker to LIVE audio`. If `9900` works from a
softphone, Loxone will work — it makes the same anonymous call.


## Loxone configuration

Create (or reuse) an **Intercom** network device, then a **Door Controller**
object linked to it. Set the *local* fields (leave *external* blank until
local works):

| Door Controller property | Value |
|---|---|
| **Host for audio (local)** | `<HA host LAN IP>` |
| **Audio username (local)** | `9900` (= `doorbell_extension`) |
| **URL video stream** | `http://<HA host LAN IP>:1984/?action=stream` |

Snapshot form: `:1984/?action=snapshot` (a few seconds of pre-roll, so the
ring-moment image shows the visitor, not an empty doorstep). With video
auth enabled use `http://<user>:<pass>@<host>:1984/?action=stream`.

**Ring → Loxone notification** (separate, more robust path):

1. In Loxone Config add a **Virtual Input** (e.g. `DoorbellRing`) and wire
   it to the Door Controller's bell input.
2. Its trigger URL:
   `http://<user>:<pass>@<miniserver>/dev/sps/io/DoorbellRing/Pulse`
   (dedicated, minimal-rights Loxone user).
3. In Protect → *Alarm Manager → Create Alarm*: trigger = doorbell ring,
   action = **Webhook** → that URL.


## Ports (host networking)

| Port | Proto | Who |
|---|---|---|
| 5060 | UDP | Loxone app → Asterisk (SIP) |
| 10000–10200 | UDP | RTP media |
| 1984 | TCP | Loxone ← mjpg-streamer (video) |
| 8554 | TCP | internal (bridge ← go2rtc audio) |
| 1985 / 8088 | TCP | localhost only (go2rtc API / ARI) |

Because the app uses the host network, these ports must be **free on the
Home Assistant host**. Watch out for collisions: Frigate and the go2rtc
add-on also use **1984** and **8554** by default. If another go2rtc runs on
this host, run one of them elsewhere — this app's ports are currently
fixed.


## Troubleshooting

- **Call connects, no audio** → almost always networking. RTP
  `10000–10200/udp` must not be firewalled toward the LAN.
- **No video in Loxone** → open `http://<host>:1984/?action=stream` in a
  browser. If blank, the RTSP share link / `protect_camera_path` is wrong
  or RTSP isn't enabled on the camera.
- **Video rotated the wrong way** → change `mjpeg_rotation`.
- **Bridge keeps restarting** → check `protect_api_key` / `camera_id`; the
  bridge validates the talkback session on connect.
- **Loxone "busy"/rejected** → confirm Asterisk got the INVITE: from the
  host, `docker exec -it addon_<repo>_unifi_protect_loxone_intercom
  asterisk -rx "pjsip set logger on"`, retry, read the SIP trace.
- **One-way audio / echo** → tune `duck_atten_db` / `duck_hold_ms` (it's a
  voice-gated ducker, not true acoustic echo cancellation).


## Caveats

- The bridge is a solo, low-traffic project; its commit is pinned in the
  Dockerfile. Expect to read code if something is off.
- The Loxone→Asterisk hop (anonymous INVITE → `9900`) follows the pattern
  documented for 2N/Grandstream intercoms with Loxone; the softphone test
  above de-risks it.
- Standalone deployment (docker compose / k8s, no Home Assistant) remains
  fully supported — see the repository README.

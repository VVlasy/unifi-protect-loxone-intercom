# Deployment Guide — UniFi Protect doorbell → Loxone Intercom

End-to-end runbook for the deployment as actually built: a single Docker container
(Asterisk + Fusseldieb bridge + go2rtc + mjpg-streamer) running inside a **privileged
LXC on Proxmox**, bridging a UniFi Protect doorbell to a Loxone Door Controller with
two-way audio (local **and** remote), live video, and a ring notification.

> Concrete values below are from the reference deployment — substitute your own.
> Secrets live in `.env` (never commit it); this guide uses placeholders.

| Thing | Reference value |
|---|---|
| Proxmox node | `proxmox-02.vvlasy.cz` (`192.168.21.16`) |
| LXC | CT **101** `doorbell-bridge`, **`192.168.21.9/24`**, gw `192.168.21.254` |
| UniFi UDM / Protect / gateway | `192.168.21.254` |
| Public WAN (for remote SIP) | `vzdalena1.vvlasy.cz` → `93.99.228.38` |
| Split-horizon name for Loxone | `sip.vvlasy.cz` (internal → `.9`, external → WAN) |
| Doorbell SIP extension | `380045110` |

---

## 1. Architecture

```
Loxone app ── anonymous SIP INVITE (5060) ──► Asterisk ──► Stasis(doorbellbridge)
                                                 │                  │
                                          RTP 10000-10200      bridge (ARI)
                                                                    │  talkback (X-API-KEY)
                                                                    ▼
   go2rtc ──audio──► bridge ──► UniFi Protect doorbell ◄── RTSPS stream ──┐
     │  (also serves raw H264 video on local RTSP :8554)                   │
     └──► mjpeg-video.sh (ffmpeg transcode) ──► /dev/shm/cam.jpg ──► mjpg-streamer :8080
                                                                       └─► Loxone video (MJPEG)

Ring: Protect Alarm Manager ── webhook ──► Loxone Virtual Input (Pulse) ──► Door Controller bell
```

- **Host networking is mandatory** — SIP/RTP embed IP/ports in SDP and use symmetric
  RTP; behind NAT the audio silently dies. The container shares the LXC's network
  namespace, so the LXC's LAN IP is what Loxone calls.
- **Everything is rendered from `.env`** at container start; nothing else to edit.

---

## 2. Provision the Proxmox LXC

Docker-in-LXC needs a **privileged** container with nesting + keyctl.

```bash
# On the Proxmox node:
pveam update && pveam download local debian-12-standard_12.12-1_amd64.tar.zst

pct create 101 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname doorbell-bridge \
  --cores 2 --memory 1024 --swap 512 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.21.9/24,gw=192.168.21.254 \
  --nameserver 192.168.21.254 --searchdomain vvlasy.cz \
  --ostype debian --unprivileged 0 \
  --features nesting=1,keyctl=1 \
  --onboot 1
pct start 101
```

Install Docker inside the CT:

```bash
pct exec 101 -- bash -c "apt-get update && apt-get install -y curl ca-certificates && curl -fsSL https://get.docker.com | sh"
pct exec 101 -- docker run --rm hello-world   # sanity check
```

> Pick a **static IP outside your DHCP pool**. This IP (or the split-horizon name
> pointing at it) is what Loxone calls forever.

---

## 3. UniFi Protect setup

1. **RTSP share link** — doorbell → *Settings → Advanced → RTSP*, enable a stream
   (a **lower-res** channel starts/transcodes faster), copy the
   `rtsps://<ip>:7441/<key>?enableSrtp` URL. For go2rtc use the **`rtspx://`** form:
   `rtspx://192.168.21.254:7441/<key>` → this is `PROTECT_CAMERA_PATH`.
2. **Integration API key** — *Settings → Control Plane → Integrations → Create*. This
   is `PROTECT_API_KEY` (official API; survives 2FA/local-account changes).
3. **Camera ID** — open the camera in the Protect web UI; URL is
   `https://<ip>/protect/devices/<CAMERA_ID>`.
4. **Ring repeat = 1** in the doorbell's chime settings (>1 causes stream issues).

---

## 4. Configure `.env`

```bash
cp .env.example .env
```
Set at minimum:
- `PROTECT_CAMERA_PATH` = `rtspx://192.168.21.254:7441/<key>`
- `PROTECT_BASE` = `https://192.168.21.254` (local UDM IP; bridge ignores self-signed cert)
- `PROTECT_API_KEY`, `CAMERA_ID`
- `ARI_PASS` = long random string (`openssl rand -hex 24`)
- `WEBHOOK_BIND=0.0.0.0` (the bridge's own webhook listener — **not** the ring path)

Tunables (defaults are sane):
- **Ducking** (echo control): `DUCK_TALK_THRESHOLD=180`, `DUCK_ATTEN_DB=-30`
  (VOLUME(TX) linear divisor, not dB), `DUCK_HOLD_MS=900`.
- **Video**: `MJPEG_FPS=10`, `MJPEG_SCALE_W=1280`, `MJPEG_QUALITY=8`,
  `MJPEG_TRANSPOSE=1` (rotation: 1=90°CW, 2=90°CCW, ""=none), `MJPEG_PORT=1984`,
  `MJPEG_AUTH_USER`/`MJPEG_AUTH_PASS` (set both to require basic auth on the stream).

---

## 5. Build & run

```bash
# Copy this repo into the CT (e.g. /opt/doorbell), then:
cd /opt/doorbell
docker compose up -d --build
docker compose logs -f          # wait for: "ARI and go2rtc are active."
```

Quick health checks (from inside the CT):
```bash
docker exec unifi-loxone-doorbell asterisk -rx "pjsip show endpoints"   # 'anonymous'
docker exec unifi-loxone-doorbell asterisk -rx "ari show apps"          # doorbellbridge
docker exec unifi-loxone-doorbell curl -s http://127.0.0.1:1985/api/streams   # go2rtc (API moved to 1985)
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:1984/?action=snapshot   # video (401 if auth on)
```

---

## 6. Prove the audio leg FIRST (before Loxone)

The Loxone→Asterisk→bridge hop is the make-or-break piece. Test it with any softphone
(Linphone, anonymous/no-registration): dial `sip:380045110@192.168.21.9`. You should
hear the doorbell mic and be heard at the door. Success log line:
`switched speaker to LIVE audio`. If this works, Loxone will work (it makes the same
anonymous call).

---

## 7. Loxone Config

**Door Controller** (Intercom network device → Door Controller object):

| Property | Value |
|---|---|
| Host for audio (local **and** external) | `sip.vvlasy.cz` |
| Audio username (local and external) | `380045110` |
| URL video stream | `http://<user>:<pass>@sip.vvlasy.cz:1984/?action=stream` |

- The Loxone app sends an **anonymous** call — no password, no registration.
- Video is mjpg-streamer on `:1984` (always-warm → instant open). Snapshot form:
  `:1984/?action=snapshot`. (go2rtc's API moved to `:1985`.)

**Ring notification** (separate webhook path):
1. Add a **Virtual Input** named e.g. `DoorbellRing` (no spaces). Wire its output to
   the Door Controller's bell/ring input. Save → upload.
2. Trigger URL (use **`/Pulse`** for a momentary press, auto on/off):
   `http://<user>:<pass>@miniserver.vvlasy.cz/dev/sps/io/DoorbellRing/Pulse`
   (use a dedicated minimal-rights Loxone user).
3. **Protect → Alarm Manager → Create Alarm**: trigger = doorbell ring, action =
   **Webhook** → that URL. If Protect can't do inline `user:pass@`, add an
   `Authorization: Basic <base64(user:pass)>` header instead.

---

## 8. Remote access (public SIP exposure)

For the Loxone app off-LAN (no VPN). **Trade-off:** opens SIP to the internet; fail2ban
(§9) mitigates scanners. A VPN with always-on on the phone is the more secure alternative.

1. **UDM port-forwards → `192.168.21.9`:** `5060/udp` (SIP) **and** `10000-10200/udp`
   (RTP — the part that's easy to forget; without it the call connects but is silent).
   Do **not** forward `1984` (video) / `1985` (go2rtc) publicly.
2. **Asterisk advertises the public address** — already set in `asterisk/pjsip.conf`:
   ```
   external_media_address = vzdalena1.vvlasy.cz      ; must resolve PUBLIC from the LXC
   external_signaling_address = vzdalena1.vvlasy.cz
   local_net = 192.168.21.0/24
   local_net = 192.168.22.0/24                        ; VPN stays on private IP
   ```
   Use a **public-only** name here (not the split-horizon `sip.vvlasy.cz`, which the
   LXC would resolve to the private IP).
3. **DNS**: `sip.vvlasy.cz` split-horizon — internal → `192.168.21.9`, public → WAN.
   One value works in both Loxone fields.

---

## 9. fail2ban (SIP scanner protection)

Runs in the **LXC** (shares the container's net namespace under host networking, so
iptables bans drop the forwarded SIP/RTP). Asterisk writes a security log that's
bind-mounted out to `/opt/doorbell/asterisk-log/security`.

```bash
pct exec 101 -- apt-get install -y fail2ban iptables
# Install the jail (repo: fail2ban/jail.d/asterisk-doorbell.local):
pct push 101 fail2ban/jail.d/asterisk-doorbell.local /etc/fail2ban/jail.d/asterisk-doorbell.local
# Disable the stock sshd jail (this CT has no /var/log/auth.log):
pct exec 101 -- sed -i 's/^enabled = true/enabled = false/' /etc/fail2ban/jail.d/defaults-debian.conf
pct exec 101 -- systemctl enable --now fail2ban
pct exec 101 -- fail2ban-client status asterisk
```
The jail whitelists LAN + VPN (`192.168.21.0/24`, `192.168.22.0/24`) so it never bans
your own clients or admin SSH.

---

## 10. Operations & tuning

**Apply an `.env` change** (no rebuild): edit `/opt/doorbell/.env`, then
`cd /opt/doorbell && docker compose up -d`.

**Apply a code/config change** (Dockerfile, asterisk/, scripts): `docker compose up -d --build`.

- **Echo too present / too clamped** → adjust `DUCK_ATTEN_DB` (more negative = quieter
  echo) and `DUCK_HOLD_MS` (longer = stays clamped through pauses; ~500 if it feels
  walkie-talkie). It's a voice-gated ducker, not true AEC.
- **Video rotated wrong way** → flip `MJPEG_TRANSPOSE` (1 ↔ 2).
- **Video too heavy / too soft** → `MJPEG_FPS`, `MJPEG_SCALE_W`, `MJPEG_QUALITY`.
- **Rotate video password** → change `MJPEG_AUTH_PASS`, `up -d`, update Loxone URL.

**Logs / debug:**
```bash
docker compose logs -f
docker exec unifi-loxone-doorbell asterisk -rx "pjsip set logger on"   # SIP trace
docker exec unifi-loxone-doorbell asterisk -rx "rtp set debug on"      # RTP trace
```

---

## 11. Gotchas learned the hard way

- **UniFi Threat Management** flags bursty SSH from the VPN as brute-force and blocks
  the source (ping works, TCP 22 times out). Whitelist `192.168.22.0/24` in Threat
  Management. Batch SSH commands to avoid tripping it.
- **Docker-in-LXC** must be privileged + `nesting=1,keyctl=1`.
- **RTP forward** (`10000-10200/udp`) is the usual cause of "remote call connects but
  silent."
- **`external_media_address`** must resolve to the PUBLIC IP *from the LXC* — use a
  public-only name, not a split-horizon one.
- **go2rtc can't emit MJPEG from H264** directly; that's why video goes through the
  ffmpeg → mjpg-streamer path (and that path is always-warm, fixing slow first-frame).
- **Don't expose `1984`/`1985` publicly** — the video basic auth is plain HTTP.
```

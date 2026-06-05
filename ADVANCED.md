# Advanced topics

The [README](README.md) covers the normal case: a Docker host on your LAN, four
`.env` values, `docker compose up`. This document holds the optional extras —
running it inside a Proxmox LXC, exposing it for remote (off-LAN) access,
protecting that exposure with fail2ban, deploying on Kubernetes, and the
experimental camera-landscape fix.

Throughout, substitute your own IPs/subnets for the example values
(`192.168.1.0/24`, etc.).

---

## Running inside a Proxmox LXC

Docker-in-LXC needs a **privileged** container with nesting + keyctl.

```bash
# On the Proxmox node:
pveam update && pveam download local debian-12-standard_12.12-1_amd64.tar.zst

pct create 101 local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst \
  --hostname doorbell-bridge \
  --cores 2 --memory 1024 --swap 512 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.9/24,gw=192.168.1.254 \
  --nameserver 192.168.1.254 \
  --ostype debian --unprivileged 0 \
  --features nesting=1,keyctl=1 \
  --onboot 1
pct start 101

# Install Docker inside the CT:
pct exec 101 -- bash -c "apt-get update && apt-get install -y curl ca-certificates && curl -fsSL https://get.docker.com | sh"
pct exec 101 -- docker run --rm hello-world   # sanity check
```

Pick a **static IP outside your DHCP pool** — this IP is what Loxone calls forever.
Then copy this repo into the CT (e.g. `/opt/doorbell`), set up `.env`, and run
`docker compose up -d --build` as in the README.

---

## Remote access (public SIP exposure)

For the Loxone app **off-LAN without a VPN**. **Trade-off:** this opens SIP to the
internet; the fail2ban section below mitigates scanners, but a VPN with always-on on
the phone is the more secure alternative.

1. **Set a non-obvious extension.** With SIP public, change the dialled number from
   the default `9900` to something long and non-guessable: set
   `DOORBELL_EXTENSION=<your-number>` in `.env`, and use the **same** value as the
   Loxone "Audio username".
2. **Advertise the public address.** Edit `asterisk/pjsip.conf`'s `[transport-udp]`
   to add (use a **public-only** name that resolves to your WAN IP *from the host* —
   not a split-horizon name, which the host would resolve to the private IP):
   ```ini
   external_media_address = your-public-name.example.com
   external_signaling_address = your-public-name.example.com
   local_net = 192.168.1.0/24
   local_net = 192.168.2.0/24    ; e.g. your VPN subnet — keeps on-net clients private
   ```
   Rebuild: `docker compose up -d --build`.
3. **Port-forward on the UDM → the host IP:** `5060/udp` **and** `10000-10200/udp`
   (the RTP range is the part that's easy to forget — without it the call connects
   but is silent). Do **not** forward `1984`/`1985`.
4. **DNS / Loxone fields.** A split-horizon name (internal → host LAN IP, public →
   WAN) lets you put one value in both the local and external Loxone "Host for audio"
   fields.

---

## fail2ban (SIP scanner protection)

Only relevant if you exposed SIP publicly (above). Runs in the **LXC/host** — under
host networking it shares the container's net namespace, so iptables bans drop the
forwarded SIP/RTP. Asterisk writes a security log that's bind-mounted out of the
container.

1. Add the bind mount to `docker-compose.yml` (under the service) and recreate:
   ```yaml
   volumes:
     - ./asterisk-log:/var/log/asterisk
   ```
2. Install and wire the jail (edit the subnets in
   [`fail2ban/jail.d/asterisk-doorbell.local`](fail2ban/jail.d/asterisk-doorbell.local)
   to your LAN/VPN first):
   ```bash
   apt-get install -y fail2ban iptables
   cp fail2ban/jail.d/asterisk-doorbell.local /etc/fail2ban/jail.d/
   # If this host has no /var/log/auth.log, disable the stock sshd jail:
   sed -i 's/^enabled = true/enabled = false/' /etc/fail2ban/jail.d/defaults-debian.conf
   systemctl enable --now fail2ban
   fail2ban-client status asterisk
   ```
The jail's `ignoreip` whitelists your LAN + VPN so it never bans your own clients or
admin SSH.

---

## Kubernetes (K3s)

`hostNetwork: true` is required (same SIP/RTP reason as Docker). Because the pod then
uses a node's real IP, **pin it to one node** so the IP Loxone calls stays stable.

1. Build & push the image to a registry your cluster can pull from.
2. Create the env secret from your `.env`:
   ```bash
   kubectl create namespace home
   kubectl create secret generic doorbell-bridge-env --from-env-file=.env -n home
   ```
3. Edit [`k8s-deployment.yaml`](k8s-deployment.yaml): set the `image`, the
   `nodeSelector` hostname, and remove the inline `Secret` block if you created it
   from `.env` above. Then `kubectl apply -f k8s-deployment.yaml`.

---

## Camera landscape fix

> **Experimental, off by default, model-specific.** This pokes undocumented camera
> firmware internals and does not affect the SIP/video bridge. If you only need
> *Loxone's* view rotated, set `MJPEG_TRANSPOSE` instead and skip all of this.

### Why it exists

The UniFi **Doorbell Lite (Sigmastar Infinity6E)** hardcodes a 90° portrait
("hallway") rotation. Protect **cannot** disable it: the camera reports
`featureFlags.hasHallwayMode=false` and ignores the controller's
`hallwayMode=disabled`, so Protect, the recordings *and* the go2rtc/Loxone feed all
get a portrait image while every other camera is landscape. Making it landscape
requires overriding it **on the camera**, and that override is not natively
persistent — hence a watchdog.

### How landscape-upright is produced (both pieces on the camera)

1. **`rot90.so`** — an `LD_PRELOAD` shim interposing the encoder's C++ getter
   `ubnt::encoder::VideoEncoderSettings::hallwayMode()` to return `0` (disabled) →
   the encoder emits the native **landscape** sensor frame (upside-down for a typical
   doorbell mount). Injected by bind-mounting `patches/streamer_wrap.sh` over
   `/bin/ubnt_streamer`.
2. **ISP `flip`+`mirror`=1** in `/etc/persistent/ubnt_isp.conf` → 180°, to correct
   the upside-down native landscape to upright.

### Watchdog

Neither piece survives a camera reboot (`cfgmtd` wipes unknown files from
`/etc/persistent`; the bind-mount is volatile). `patches/camera-rotation-watchdog.sh`
runs in this container, SSHes the camera every `ROTATION_CHECK_INTERVAL`s and
**re-applies** both whenever they drift. The container is on the camera's LAN subnet,
so the SSH stays local — important, since heavy SSH *over a VPN* can trip the UniFi
IPS and black out the subnet.

### Prerequisites

1. **Enable camera SSH.** On the UDM, set `{"enableSsh": true}` in the file Protect's
   `overrides` points to — `/etc/unifi-protect/config.json` on current builds (verify
   with `jq .overrides /usr/share/unifi-protect/app/config/default.json`) — then
   `systemctl restart unifi-protect`. The camera then accepts SSH as user `ubnt` with
   the camera's **Recovery Code** as the password.
2. This container is on the camera's **LAN subnet** (host networking) so its SSH stays
   local.

### Enable it

In `.env`:
```ini
ROTATION_FIX_ENABLED=1
CAMERA_IP=<doorbell LAN IP>
CAMERA_SSH_PASS=<camera Recovery Code>
# defaults: HALLWAY_VALUE=0  ISP_FLIP=1  ISP_MIRROR=1  ROTATION_CHECK_INTERVAL=30
```
Rebuild (`docker compose up -d --build`) and watch the logs. Once the source is
landscape, set **`MJPEG_TRANSPOSE=`** (empty) so the Loxone feed isn't double-rotated.

### Caveats (do not regress)

- The streamer must be restarted with **SIGTERM only** — a `SIGKILL` on the *critical*
  streamer makes the camera's supervisor **reboot the whole camera**.
- `rot90.so` must be built against the camera's **glibc 2.30** symbol versions (ARMv7
  hard-float; see the header in `patches/rot90.c`). It will **not survive a firmware
  update** without a rebuild.
- Leave `ROTATION_FIX_ENABLED=0` to keep the doorbell stock. Treat it as a hack, not a
  supported feature.

---

## Debugging cheatsheet

```bash
docker compose logs -f
docker exec -it unifi-loxone-doorbell asterisk -rx "pjsip set logger on"      # SIP trace
docker exec -it unifi-loxone-doorbell asterisk -rx "rtp set debug on"         # RTP trace
docker exec -it unifi-loxone-doorbell asterisk -rx "pjsip show endpoints"     # expect 'anonymous'
docker exec -it unifi-loxone-doorbell asterisk -rx "ari show apps"            # expect doorbellbridge
docker exec -it unifi-loxone-doorbell curl -s http://127.0.0.1:1985/api/streams   # go2rtc health
curl -s -o /dev/null -w "%{http_code}\n" http://<host>:1984/?action=snapshot      # video (401 if auth on)
```

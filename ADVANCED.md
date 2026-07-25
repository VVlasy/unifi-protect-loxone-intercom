# Advanced topics

The [README](README.md) covers the normal case: a Docker host on your LAN, four
`.env` values, `docker compose up`. This document holds the optional extras —
running it inside a Proxmox LXC, exposing it for remote (off-LAN) access,
protecting that exposure with fail2ban, and deploying on Kubernetes.

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
2. **Advertise the public address** — set these in `.env` (no file edits; the
   entrypoint renders them into Asterisk). Use a **public-only** name that resolves to
   your WAN IP *from the host* — not a split-horizon name, which the host would
   resolve to the private IP. `SIP_LOCAL_NET` lists your private subnets (LAN, VPN) so
   on-net clients stay on the private path:
   ```ini
   SIP_EXTERNAL_ADDRESS=your-public-name.example.com
   SIP_LOCAL_NET=192.168.1.0/24,192.168.2.0/24
   ```
   Apply: `docker compose up -d`.
3. **Port-forward on the UDM → the host IP:** `5060/udp` **and** `10000-10200/udp`
   (the RTP range is the part that's easy to forget — without it the call connects
   but is silent). Do **not** forward `1984`/`1985`.
4. **DNS / Loxone fields.** A split-horizon name (internal → host LAN IP, public →
   WAN) lets you put one value in both the local and external Loxone "Host for audio"
   fields.

### Known issue: Loxone's remote-call client sends invalid SDP

On the cloud-relayed **off-LAN** call path (i.e. calling in via the settings
above — observed on cellular/CGNAT connections), Loxone's own SIP client
(`User-Agent: Loxone Pjsua2 Wrapper`) has been observed sending truncated SDP
bandwidth lines — e.g. `:=4` instead of `b=AS:4` — which breaks RFC 4566's
`<type>=<value>` line format. Asterisk correctly rejects the whole INVITE
(`PJMEDIA_SDP_EINSDP`, `400 Bad Request`) before the call reaches the
dialplan, so **the call fails from off-LAN while the exact same call works
fine from the LAN**. This is a bug in Loxone's client, not in this project's
Asterisk config — there's no PJSIP option to make SDP parsing lenient (worth
reporting to Loxone support with a `debug_sip: true` capture attached).

As a workaround, setting `SIP_EXTERNAL_ADDRESS` activates **relay mode**:
`sip_sdp_relay.py` (`sdp-relay` under supervisord) takes ownership of UDP
`:5060` and Asterisk moves behind it to `127.0.0.1:5070`. Every caller — LAN
and remote, same port `5060`, no router changes — then passes through the
relay, which:

- strips any SDP body line that isn't a valid `<type>=<value>` line before
  Asterisk parses it (bandwidth lines are advisory, so dropping a malformed
  one is always safe — the codec/media lines are untouched), and
- rewrites Asterisk's loopback self-references (Contact/Via headers, SDP
  `c=`/`o=` lines) on the way out to the address each caller must actually
  use: the host's LAN IP for callers inside `SIP_LOCAL_NET` (or RFC1918 space
  if unset), the resolved `SIP_EXTERNAL_ADDRESS` for everyone else. This
  replaces Asterisk's `external_media_address`/`external_signaling_address`
  mechanism, which the entrypoint no longer renders in relay mode.

RTP is untouched — media still flows directly between the caller and
Asterisk on `10000–10200/udp`. Without `SIP_EXTERNAL_ADDRESS`, the relay
idles and Asterisk binds `:5060` directly, exactly as before — LAN/VPN-only
installs have no new moving parts.

**Trade-off to be aware of:** in relay mode the relay is in the signaling
path of *every* call, LAN included. If it dies, supervisord restarts it
within seconds, but a hard failure would take SIP down entirely (video and
the ring webhook are unaffected). It is ~300 lines of stdlib Python with no
privileges beyond binding a port; still, if you ever need to bisect a
problem, unset `SIP_EXTERNAL_ADDRESS` and you are back to the direct,
relay-free topology.

**History:** 1.0.3 attempted this fix with an NFQUEUE iptables hook, which
turned out not to work on Home Assistant OS (its kernel ships no
`nfnetlink_queue` module) and needed `NET_ADMIN`. 1.0.4 replaced it with the
relay; the capability grant is gone. If you ran 1.0.3 on a host where the
rule *did* install, remove the leftover (it's a harmless no-op, but tidy):
```bash
sudo iptables -t mangle -D PREROUTING -p udp --dport 5060 -j NFQUEUE --queue-num 5060 --queue-bypass
```

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
2. Install and wire the jails (edit the subnets in
   [`fail2ban/jail.d/asterisk-doorbell.local`](fail2ban/jail.d/asterisk-doorbell.local)
   to your LAN/VPN first):
   ```bash
   apt-get install -y fail2ban iptables
   cp fail2ban/jail.d/asterisk-doorbell.local /etc/fail2ban/jail.d/
   cp fail2ban/filter.d/doorbell-relay.conf /etc/fail2ban/filter.d/
   # If this host has no /var/log/auth.log, disable the stock sshd jail:
   sed -i 's/^enabled = true/enabled = false/' /etc/fail2ban/jail.d/defaults-debian.conf
   systemctl enable --now fail2ban
   fail2ban-client status asterisk
   fail2ban-client status doorbell-relay
   ```

**Relay mode caveat:** with `SIP_EXTERNAL_ADDRESS` set (see the known-issue
section above), all SIP reaches Asterisk from `127.0.0.1`, so the `[asterisk]`
jail can no longer see scanner IPs. The `[doorbell-relay]` jail covers that:
the relay logs every 4xx/5xx it forwards to an off-LAN peer (with the real
address) to `relay_security` in the same bind-mounted log directory.
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

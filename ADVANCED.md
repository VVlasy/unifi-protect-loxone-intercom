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
above), Loxone's own SIP client (`User-Agent: Loxone Pjsua2 Wrapper`) has been
observed sending truncated SDP bandwidth lines — e.g. `:=4` instead of
`b=AS:4` — which breaks RFC 4566's `<type>=<value>` line format. Asterisk
correctly rejects the whole INVITE (`PJMEDIA_SDP_EINSDP`, `400 Bad Request`)
before the call reaches the dialplan, so **the call fails from off-LAN while
the exact same call works fine from the LAN**. This is a bug in Loxone's
client, not in this project's Asterisk config — there's no PJSIP option to
make SDP parsing lenient.

As a workaround, `sip_sdp_fixup.py` (`sdp-fixup` under supervisord) sits on an
NFQUEUE hook and strips any SDP body line that isn't a valid `<type>=<value>`
line before Asterisk ever sees it (bandwidth lines are advisory, so dropping a
malformed one is always safe — the codec/media lines are untouched). It:

- **Only activates when `SIP_EXTERNAL_ADDRESS` is set** — the entrypoint
  installs the NFQUEUE iptables rule only then; otherwise the process is
  running but idle.
- **Fails open** — the iptables rule uses `--queue-bypass`, so if the process
  is down, traffic passes through unmodified instead of being blocked.
- **Needs `NET_ADMIN`** to install the rule and bind the queue. Already added
  to `docker-compose.yml` (`cap_add`), `k8s-deployment.yaml`
  (`securityContext.capabilities`), and the add-on's `config.yaml`
  (`privileged:`) — nothing to change if you deploy from this repo as-is.

**Operational note:** because this runs under host networking, the iptables
rule it installs lives in the **host's** netfilter tables, not a
container-private namespace. The entrypoint checks before adding it, so
restarts don't duplicate it, but if you permanently disable remote access or
remove the container, clean it up manually on the host:
```bash
sudo iptables -t mangle -D PREROUTING -p udp --dport 5060 -j NFQUEUE --queue-num 5060 --queue-bypass
```
If it's still there and nothing is bound to queue 5060, `--queue-bypass`
means it's a no-op — but it's tidy to remove it once you no longer need it.

If you'd rather not grant `NET_ADMIN` at all, drop the `sdp-fixup` capability
grants above and remove the `if [ -n "${SIP_EXTERNAL_ADDRESS:-}" ]` block in
`entrypoint.sh`; remote calls will then fail with the `400`/`EINSDP` error
above until Loxone fixes this in their client (worth reporting to Loxone
support with a `debug_sip: true` capture attached).

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

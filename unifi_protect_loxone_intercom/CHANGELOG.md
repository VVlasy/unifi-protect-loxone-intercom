# Changelog

## 1.0.8

- Advertise a numeric public IP to remote callers whenever possible. A live
  capture from a caller stuck at "establishing connection" showed the phone
  CANCELing an already-answered call: the 200 OK never reached it. That call
  path crossed a consumer router whose SIP ALG evidently drops SDP it cannot
  rewrite — and since 1.0.6's split-horizon fallback, the SDP `c=` line
  carried a hostname, which ALGs handle worst of all. The relay now queries
  the public name's A record directly at public resolvers (1.1.1.1 /
  8.8.8.8), sidestepping split-horizon LAN DNS, and only falls back to the
  hostname literal when no public answer is obtainable. New optional
  `SIP_PUBLIC_IP` env var pins the advertised WAN IP explicitly and skips
  all resolution. (Disabling SIP ALG on the remote router is still the
  real fix for that class of breakage.)

## 1.0.7

- Relay call visibility: one log line per new SIP peer
  (`[sdp-relay] new peer <ip>:<port> (local|external): INVITE sip:...`),
  so "did the call even reach this box?" is answerable from the normal app
  log without enabling the noisy `debug_sip` packet trace. A missing line
  for a failing caller means the packet is being lost upstream (router
  SIP ALG, firewall/IPS auto-block, fail2ban ban, port-forward), not here.

## 1.0.6

- Fix zombie calls + "declined" on quick redial in relay mode. The relay
  resolved `sip_external_address` with the host's DNS; with split-horizon
  DNS (public name → LAN IP from inside the network) the Contact handed to
  remote callers pointed at a private address. The call established (that
  path doesn't use Contact), but the caller's 2xx ACK and, on hang-up, its
  BYE went to the unreachable Contact and vanished — the channel lingered
  as a zombie until the 30 s no-RTP timeout, and the bridge declines new
  calls while a session is active, so redialing within that window got
  `603 Decline`. The relay now detects a non-public resolution and
  advertises the hostname itself instead, letting each caller resolve it
  from their own vantage point (correct in both split-horizon and plain
  setups).
- Relay responses now restore the real caller address in the Via
  `received=`/`rport=` parameters instead of leaking the loopback session
  socket (`received=127.0.0.1`), which fed the caller's NAT self-discovery
  nonsense.

## 1.0.5

- Fix 1.0.4 relay mode being dead on arrival: Ubuntu's Asterisk autoloads the
  deprecated legacy `chan_sip` driver, which binds `0.0.0.0:5060` by default.
  Pre-1.0.4 it silently lost that bind race to PJSIP; with PJSIP moved to
  `127.0.0.1:5070` it instead stole `:5060` from the SDP relay (both sockets
  had `SO_REUSEADDR`; on Linux UDP the last binder receives everything) and
  blackholed every call in its empty `public` context — while also answering
  scanners' REGISTER attempts. Two fixes: `chan_sip` is now explicitly
  `noload`ed in `modules.conf`, and the relay binds `:5060` exclusively
  (no `SO_REUSEADDR`) so any future port conflict fails loudly at startup
  instead of silently swallowing calls.

## 1.0.4

- Replace the 1.0.3 NFQUEUE-based SDP fix, which could not work on Home
  Assistant OS (its kernel ships no `nfnetlink_queue` module — the rule
  install failed at boot and the sanitizer never saw a packet), with a
  userspace SIP relay. With `sip_external_address` set, `sip_sdp_relay.py`
  now owns UDP `:5060` and Asterisk moves behind it to `127.0.0.1:5070`;
  callers keep dialing the same host and port, LAN and remote alike, with no
  router changes. The relay strips the malformed SDP lines Loxone's
  remote-call client sends and rewrites Asterisk's loopback self-references
  to the correct LAN/external address per caller (replacing Asterisk's
  `external_media_address`/`external_signaling_address` mechanism). RTP is
  unaffected. Without `sip_external_address`, the relay idles and Asterisk
  binds `:5060` directly, as before.
- The `NET_ADMIN` privilege added in 1.0.3 is no longer needed and has been
  removed again (add-on `config.yaml`, `docker-compose.yml`,
  `k8s-deployment.yaml`).
- New fail2ban companion for relay mode: Asterisk now only sees `127.0.0.1`,
  so the relay logs 4xx/5xx responses to off-LAN peers (real IPs) to
  `relay_security` next to the Asterisk security log; a new
  `doorbell-relay` filter/jail ships in `fail2ban/`. See ADVANCED.md.

## 1.0.3

- Work around a Loxone remote-call SIP client bug: on the cloud-relayed
  off-LAN call path, Loxone's own client ("Loxone Pjsua2 Wrapper") has been
  observed sending truncated SDP bandwidth lines (e.g. `:=4` instead of
  `b=AS:4`), which Asterisk correctly rejects as invalid SDP
  (`PJMEDIA_SDP_EINSDP`, 400 Bad Request) before the call ever reaches the
  dialplan - remote calls would fail while LAN calls worked fine. A new
  `sdp-fixup` NFQUEUE process now strips any non-conforming SDP body line in
  flight before Asterisk parses it. Only activates when `sip_external_address`
  is set; requires the add-on's new `NET_ADMIN` privilege (also added to
  `docker-compose.yml`/`k8s-deployment.yaml` for standalone/k8s deployments).
  See ADVANCED.md > Remote access.

## 1.0.2

- Stuck-call protection, two layers: a 30 s no-RTP timeout on the SIP
  endpoint (caller vanished without a deliverable BYE), and an absolute cap
  on call duration — new `max_call_secs` option, default 600 s, 0 disables —
  for zombie sessions that keep streaming RTP so the no-RTP timeout never
  fires. Either one hangs the channel up, which triggers the bridge's normal
  session cleanup.

## 1.0.1

- New `debug_sip` option: logs every SIP message and RTP packet to the app
  log (PJSIP logger + RTP debug) for diagnosing call/audio problems without
  needing `docker exec`. Extremely noisy — enable only while debugging.

## 1.0.0

- First release as a Home Assistant app (add-on). Same image as the
  standalone docker compose deployment; configuration moves from `.env` to
  the app options UI (`run.sh` maps options to the same environment
  variables, so standalone deployments are unaffected).
- Host networking is enabled in the app config (required for SIP/RTP).
- go2rtc binary arch is now detected from dpkg at build time, so plain
  `docker build` works on both amd64 and aarch64.
- Ships as a prebuilt image from GHCR
  (`ghcr.io/vvlasy/unifi-protect-loxone-intercom`) — installs/updates pull a
  ready image; nothing is compiled on the Home Assistant host.

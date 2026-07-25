# Changelog

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

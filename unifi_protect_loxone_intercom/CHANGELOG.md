# Changelog

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

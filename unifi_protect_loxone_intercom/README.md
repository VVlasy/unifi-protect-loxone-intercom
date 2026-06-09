# UniFi Protect Loxone Intercom

Make a **UniFi Protect doorbell** (G4/G6 Doorbell, Doorbell Lite, …)
answerable from the **Loxone Intercom / Door Controller** block — two-way
audio and live video.

UniFi Protect speaks no SIP; Loxone's Door Controller speaks only SIP
(anonymous, direct-IP). This app bridges the gap: **Asterisk** as a tiny
local PBX, the Fusseldieb **unifiprotect-sip-bridge** for talkback over
Protect's official Integration API, and **go2rtc + mjpg-streamer** for the
video image — all supervised in one container.

See the **Documentation** tab for prerequisites (RTSP share link, API key,
camera id), Loxone configuration, ports, and troubleshooting.

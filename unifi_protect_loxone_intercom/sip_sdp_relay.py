#!/usr/bin/env python3
"""SDP-sanitizing SIP relay: owns UDP :5060, forwards to Asterisk on loopback.

Why this exists: Loxone's own SIP client ("Loxone Pjsua2 Wrapper"), on the
cloud-relayed remote/off-LAN call path, emits truncated SDP bandwidth lines -
e.g. ":=4" instead of "b=AS:4" - which violates RFC 4566's "<type>=<value>"
line format. pjproject rejects the whole INVITE (PJMEDIA_SDP_EINSDP, 400)
before the call reaches the dialplan, and PJSIP has no lenient-parsing knob.
An earlier NFQUEUE-based in-flight fix (1.0.3) failed on Home Assistant OS,
whose kernel ships no nfnetlink_queue module, so the sanitizing now happens in
userspace: this relay owns the public SIP port and Asterisk listens only on
127.0.0.1 behind it.

Only active when SIP_EXTERNAL_ADDRESS is set (remote access per ADVANCED.md);
otherwise this process idles and Asterisk binds :5060 directly as before, so
LAN-only installs are untouched. In relay mode ALL callers - LAN and remote -
pass through here; the entrypoint moves Asterisk's transport to
127.0.0.1:ASTERISK_SIP_PORT to match.

What it does per datagram:
  client -> Asterisk: drop any SDP body line that is not a valid
      "<type>=<value>" line (bandwidth lines are advisory; the codec/media
      lines are never malformed and never touched), fix Content-Length.
  Asterisk -> client: Asterisk, bound to loopback, advertises 127.0.0.1 in
      Contact/Via and in its SDP. Rewrite those to the address this caller
      must actually use: the host's LAN IP for callers inside SIP_LOCAL_NET,
      SIP_EXTERNAL_ADDRESS (resolved) for everyone else. This replaces
      Asterisk's external_media_address/external_signaling_address mechanism,
      which the entrypoint therefore no longer renders in relay mode.

Sessions are keyed by the caller's (ip, port); each gets its own loopback
socket toward Asterisk, so Asterisk's force_rport/rewrite_contact route
responses and in-dialog requests (e.g. its stuck-call BYE) back through the
right session. RTP never touches the relay: the rewritten SDP points media
straight at the host, same as before.

fail2ban: Asterisk now only ever sees 127.0.0.1 as a source, which blinds the
Asterisk-log jail to external scanners. The relay therefore logs every 4xx/5xx
response sent to an off-LAN peer to RELAY_SECURITY_LOG for a companion jail -
see ADVANCED.md and fail2ban/filter.d/doorbell-relay.conf.
"""

import ipaddress
import os
import re
import selectors
import socket
import sys
import time

RELAY_PORT = int(os.environ.get("RELAY_SIP_PORT", "5060"))
ASTERISK_ADDR = ("127.0.0.1", int(os.environ.get("ASTERISK_SIP_PORT", "5070")))
EXTERNAL_ADDRESS = os.environ.get("SIP_EXTERNAL_ADDRESS", "").strip()
SIP_LOCAL_NET = os.environ.get("SIP_LOCAL_NET", "")
SECURITY_LOG = os.environ.get("RELAY_SECURITY_LOG", "/var/log/asterisk/relay_security")
SECURITY_LOG_MAX_BYTES = 5 * 1024 * 1024
MAX_SESSIONS = 512
# Sessions are pruned after this much signaling silence. A call is silent
# between ACK and BYE, so this must exceed the absolute call cap or Asterisk's
# own BYE at max_call_secs would find the session already gone.
IDLE_SECS = max(900, int(os.environ.get("MAX_CALL_SECS", "600") or 0) + 300)
DNS_TTL_SECS = 300

VALID_SDP_LINE = re.compile(rb"^[a-z]=")
CONTENT_LENGTH = re.compile(rb"^Content-Length\s*:\s*\d+", re.IGNORECASE | re.MULTILINE)


def log(msg):
    print("[sdp-relay] %s" % msg, file=sys.stderr, flush=True)


# --- caller classification ---------------------------------------------------

def build_local_nets():
    nets = [ipaddress.ip_network("127.0.0.0/8")]
    configured = []
    for entry in SIP_LOCAL_NET.split(","):
        entry = entry.strip()
        if not entry:
            continue
        try:
            configured.append(ipaddress.ip_network(entry, strict=False))
        except ValueError:
            log("ignoring unparseable SIP_LOCAL_NET entry %r" % entry)
    if not configured:
        # No subnets configured: treat all RFC1918 space as local.
        configured = [ipaddress.ip_network(n) for n in
                      ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
    return nets + configured


LOCAL_NETS = build_local_nets()


def is_local(ip_text):
    try:
        ip = ipaddress.ip_address(ip_text)
    except ValueError:
        return False
    return any(ip in net for net in LOCAL_NETS)


_lan_ip_cache = {}


def lan_ip_toward(client_ip):
    """The host IP a LAN caller reaches us on: the local address the kernel
    would use to route back to that caller."""
    if client_ip in _lan_ip_cache:
        return _lan_ip_cache[client_ip]
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((client_ip, 9))
        ip = s.getsockname()[0]
    except OSError:
        ip = None
    finally:
        s.close()
    if ip is None or ip.startswith("127."):
        log("could not determine LAN address toward %s; advertising %s"
            % (client_ip, EXTERNAL_ADDRESS))
        ip = external_addr()
    _lan_ip_cache[client_ip] = ip
    return ip


_dns_cache = (None, 0.0)


_warned_split_horizon = False


def external_addr():
    """SIP_EXTERNAL_ADDRESS resolved to a PUBLIC IPv4 literal (cached).

    Falls back to the hostname text itself when resolution fails OR when the
    host's DNS returns a non-global address (split-horizon DNS resolving the
    public name to the LAN IP). A remote caller sends its 2xx ACK and BYE to
    the Contact we advertise; a private address there is a blackhole - the
    call establishes but can never be torn down, and the bridge then declines
    quick redials while the zombie session drains. With the hostname literal
    the CALLER resolves it from its own vantage point, which is always right.
    """
    global _dns_cache, _warned_split_horizon
    try:
        ipaddress.ip_address(EXTERNAL_ADDRESS)
        return EXTERNAL_ADDRESS  # explicit IP literal: user's choice, trust it
    except ValueError:
        pass
    value, ts = _dns_cache
    now = time.monotonic()
    if value is not None and now - ts < DNS_TTL_SECS:
        return value
    try:
        resolved = socket.gethostbyname(EXTERNAL_ADDRESS)
    except OSError:
        if value is not None:
            return value
        log("DNS resolution of %s failed; using the hostname literally" % EXTERNAL_ADDRESS)
        return EXTERNAL_ADDRESS
    if not ipaddress.ip_address(resolved).is_global:
        if not _warned_split_horizon:
            _warned_split_horizon = True
            log("split-horizon DNS detected: %s resolves to %s here, which "
                "remote callers cannot reach; advertising the hostname "
                "instead and letting callers resolve it themselves"
                % (EXTERNAL_ADDRESS, resolved))
        resolved = EXTERNAL_ADDRESS
    _dns_cache = (resolved, now)
    return resolved


def advertised_for(client_ip):
    return lan_ip_toward(client_ip) if is_local(client_ip) else external_addr()


# --- payload rewriting -------------------------------------------------------

def split_message(data):
    for sep in (b"\r\n\r\n", b"\n\n"):
        if sep in data:
            headers, body = data.split(sep, 1)
            return headers, sep, body
    return data, b"", b""


def set_content_length(headers, n):
    if CONTENT_LENGTH.search(headers):
        return CONTENT_LENGTH.sub(b"Content-Length: %d" % n, headers, count=1)
    return headers


def sanitize_to_asterisk(data):
    """Drop malformed SDP body lines from a client message (the Loxone bug)."""
    if b"application/sdp" not in data.lower():
        return data
    headers, sep, body = split_message(data)
    if not body:
        return data
    eol = b"\r\n" if b"\r\n" in body else b"\n"
    kept = [ln for ln in body.split(eol) if ln == b"" or VALID_SDP_LINE.match(ln)]
    fixed = eol.join(kept)
    if fixed == body:
        return data
    return set_content_length(headers, len(fixed)) + sep + fixed


def rewrite_to_client(data, client_addr, sess_port):
    """Replace Asterisk's loopback self-references with the address this
    caller must use, in both SIP headers and the SDP body. Also undo the
    received=/rport= Via params Asterisk stamped with our loopback session
    socket - the caller uses those for NAT self-discovery, and telling a
    pjsua client its public address is 127.0.0.1 invites trouble."""
    client_ip, client_port = client_addr
    adv = advertised_for(client_ip).encode()
    headers, sep, body = split_message(data)
    headers = headers.replace(
        b"127.0.0.1:%d" % ASTERISK_ADDR[1], adv + b":%d" % RELAY_PORT)
    headers = headers.replace(
        b"rport=%d;received=127.0.0.1" % sess_port,
        b"rport=%d;received=%s" % (client_port, client_ip.encode()))
    if body:
        new_body = body.replace(b"127.0.0.1", adv)
        if new_body != body:
            headers = set_content_length(headers, len(new_body))
            body = new_body
    return headers + sep + body


# --- fail2ban companion log --------------------------------------------------

_seclog = None


def log_security(data, client_addr):
    """Record 4xx/5xx responses sent to off-LAN peers, so fail2ban can ban
    scanners the Asterisk log can no longer see (it only sees 127.0.0.1)."""
    global _seclog
    if not data.startswith(b"SIP/2.0 "):
        return
    code = data[8:11]
    if not (code.startswith(b"4") or code.startswith(b"5")) or not code.isdigit():
        return
    if is_local(client_addr[0]):
        return
    line = "%s SECURITY %s to %s:%d\n" % (
        time.strftime("%Y-%m-%d %H:%M:%S"), code.decode(), client_addr[0], client_addr[1])
    try:
        if _seclog is None:
            os.makedirs(os.path.dirname(SECURITY_LOG), exist_ok=True)
            _seclog = open(SECURITY_LOG, "a", buffering=1)
        if _seclog.tell() > SECURITY_LOG_MAX_BYTES:
            _seclog.close()
            _seclog = open(SECURITY_LOG, "w", buffering=1)
        _seclog.write(line)
    except OSError:
        _seclog = None  # retry on the next event


# --- session plumbing --------------------------------------------------------

class Session:
    __slots__ = ("sock", "client_addr", "last_active")

    def __init__(self, sock, client_addr):
        self.sock = sock
        self.client_addr = client_addr
        self.last_active = time.monotonic()


def main():
    if not EXTERNAL_ADDRESS:
        log("SIP_EXTERNAL_ADDRESS not set - relay disabled, Asterisk owns :%d "
            "directly (LAN/VPN-only mode). Idling." % RELAY_PORT)
        while True:
            time.sleep(3600)

    sel = selectors.DefaultSelector()
    main_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # Deliberately NO SO_REUSEADDR: on Linux UDP it would let another
    # REUSEADDR socket (e.g. a stray Asterisk channel driver) bind :5060 too
    # and, as the later binder, steal every packet. Exclusive bind means any
    # port conflict fails loudly right here instead of silently blackholing
    # calls - exactly what chan_sip did to 1.0.4.
    main_sock.bind(("0.0.0.0", RELAY_PORT))
    main_sock.setblocking(False)
    sel.register(main_sock, selectors.EVENT_READ, None)
    log("listening on :%d, forwarding to Asterisk at %s:%d (local nets: %s)"
        % (RELAY_PORT, ASTERISK_ADDR[0], ASTERISK_ADDR[1],
           ", ".join(str(n) for n in LOCAL_NETS)))

    sessions = {}  # client (ip, port) -> Session

    def close_session(sess):
        sessions.pop(sess.client_addr, None)
        try:
            sel.unregister(sess.sock)
        except (KeyError, ValueError):
            pass
        sess.sock.close()

    def prune(now, aggressive=False):
        limit = 60 if aggressive else IDLE_SECS
        for sess in [s for s in sessions.values() if now - s.last_active > limit]:
            close_session(sess)

    def session_for(client_addr, now):
        sess = sessions.get(client_addr)
        if sess is not None:
            return sess
        if len(sessions) >= MAX_SESSIONS:
            prune(now, aggressive=True)
            if len(sessions) >= MAX_SESSIONS:
                log("session table full (%d); dropping packet from %s:%d"
                    % (MAX_SESSIONS, client_addr[0], client_addr[1]))
                return None
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("127.0.0.1", 0))
        sock.connect(ASTERISK_ADDR)
        sock.setblocking(False)
        sess = Session(sock, client_addr)
        sessions[client_addr] = sess
        sel.register(sock, selectors.EVENT_READ, sess)
        return sess

    last_prune = time.monotonic()
    while True:
        events = sel.select(timeout=60)
        now = time.monotonic()
        for key, _ in events:
            if key.data is None:
                # public socket: client -> Asterisk
                while True:
                    try:
                        data, client_addr = main_sock.recvfrom(65535)
                    except BlockingIOError:
                        break
                    except OSError:
                        break
                    new_peer = client_addr not in sessions
                    sess = session_for(client_addr, now)
                    if sess is None:
                        continue
                    if new_peer:
                        # One line per new peer so "did the call even reach
                        # us?" is answerable without a debug_sip trace.
                        first_line = data.split(b"\r\n", 1)[0][:100]
                        log("new peer %s:%d (%s): %s" % (
                            client_addr[0], client_addr[1],
                            "local" if is_local(client_addr[0]) else "external",
                            first_line.decode("utf-8", "replace")))
                    sess.last_active = now
                    try:
                        sess.sock.send(sanitize_to_asterisk(data))
                    except OSError:
                        pass  # Asterisk not up yet; client will retransmit
            else:
                # per-session socket: Asterisk -> client
                sess = key.data
                while True:
                    try:
                        data = sess.sock.recv(65535)
                    except BlockingIOError:
                        break
                    except OSError:
                        # ICMP port-unreachable from a send while Asterisk was
                        # down; socket stays usable for the retransmit.
                        break
                    sess.last_active = now
                    out = rewrite_to_client(
                        data, sess.client_addr, sess.sock.getsockname()[1])
                    log_security(out, sess.client_addr)
                    try:
                        main_sock.sendto(out, sess.client_addr)
                    except OSError:
                        pass
        if now - last_prune > 60:
            prune(now)
            last_prune = now


if __name__ == "__main__":
    main()

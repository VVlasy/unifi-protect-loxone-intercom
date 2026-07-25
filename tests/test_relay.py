#!/usr/bin/env python3
"""Tests for unifi_protect_loxone_intercom/sip_sdp_relay.py.

Run from the repo root:  python3 tests/test_relay.py

Part 1 exercises the live relay over real UDP sockets on loopback (a fake
Asterisk on :5070, a fake client, the relay as a subprocess). Part 2 unit-
tests the pure functions, including the regression cases behind each release:
malformed-SDP sanitizing (1.0.4), split-horizon Contact fallback (1.0.6),
Via received/rport transparency (1.0.6), and public-resolver DNS with the
resolution priority chain (1.0.8). No network access is required - DNS is
monkeypatched throughout.
"""
import importlib
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(REPO, "unifi_protect_loxone_intercom")
RELAY = os.path.join(ADDON, "sip_sdp_relay.py")
TMP = tempfile.mkdtemp(prefix="relay-test-")
SECLOG = os.path.join(TMP, "relay_security")

ENV = dict(os.environ,
           SIP_EXTERNAL_ADDRESS="203.0.113.7",   # IP literal: no DNS needed
           SIP_LOCAL_NET="192.168.1.0/24",
           ASTERISK_SIP_PORT="5070",
           RELAY_SIP_PORT="5060",
           RELAY_SECURITY_LOG=SECLOG,
           MAX_CALL_SECS="600")
ENV.pop("SIP_PUBLIC_IP", None)

# The malformed SDP Loxone's cloud-relayed client actually sends (LF line
# endings, truncated bandwidth lines ":=4" / ":=4000"), from a live capture.
MALFORMED_BODY = (b"v=0\n"
                  b"o=- 3993990744 3993990744 IN IP4 37.188.248.118\n"
                  b"s=pjmedia\n"
                  b":=4\n"
                  b"t=0 0\n"
                  b"a=X-nat:0\n"
                  b"m=audio 25674 RTP/AVP 98 97 8 0 104 3 99 9 96\n"
                  b"c=IN IP4 37.188.248.118\n"
                  b":=4000\n"
                  b"a=rtcp:4001 IN IP4 100.114.178.116\n"
                  b"a=sendrecv\n"
                  b"a=rtpmap:0 PCMU/8000\n")


def make_invite(body):
    headers = (b"INVITE sip:380045110@sip.vvlasy.cz SIP/2.0\r\n"
               b"Via: SIP/2.0/UDP 37.188.248.118:25630;branch=z9hG4bKtest\r\n"
               b"From: sip:smarthome@loxone.com;tag=t1\r\n"
               b"To: sip:380045110@sip.vvlasy.cz\r\n"
               b"Contact: <sip:smarthome@37.188.248.118:25630;ob>\r\n"
               b"Call-ID: test-1\r\nCSeq: 1 INVITE\r\n"
               b"Content-Type: application/sdp\r\n"
               b"Content-Length: %d\r\n" % len(body))
    return headers + b"\r\n" + body


def content_length_ok(msg):
    h, b = msg.split(b"\r\n\r\n", 1)
    return int(re.search(rb"Content-Length:\s*(\d+)", h).group(1)) == len(b)


def part1_live_sockets():
    ast = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ast.bind(("127.0.0.1", 5070))
    ast.settimeout(5)
    relay = subprocess.Popen([sys.executable, RELAY], env=ENV,
                             stderr=subprocess.PIPE)
    time.sleep(0.5)
    assert relay.poll() is None, relay.stderr.read().decode()
    client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    client.bind(("127.0.0.1", 0))
    client.settimeout(5)
    try:
        # 1: malformed SDP is sanitized on the way to Asterisk
        client.sendto(make_invite(MALFORMED_BODY), ("127.0.0.1", 5060))
        got, ast_peer = ast.recvfrom(65535)
        assert b":=4" not in got, "malformed lines not stripped"
        assert b"m=audio 25674" in got and b"a=rtcp:4001" in got, "legit lines lost"
        assert content_length_ok(got)
        print("PASS 1: malformed SDP sanitized, Content-Length fixed")

        # 2: Asterisk's loopback self-references are rewritten on the way out
        ok_body = (b"v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=Asterisk\r\n"
                   b"c=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 10002 RTP/AVP 0\r\n"
                   b"a=rtpmap:0 PCMU/8000\r\n")
        ok = (b"SIP/2.0 200 OK\r\n"
              b"Via: SIP/2.0/UDP 37.188.248.118:25630;branch=z9hG4bKtest\r\n"
              b"Contact: <sip:127.0.0.1:5070>\r\n"
              b"Call-ID: test-1\r\nCSeq: 1 INVITE\r\n"
              b"Content-Type: application/sdp\r\n"
              b"Content-Length: %d\r\n\r\n" % len(ok_body)) + ok_body
        ast.sendto(ok, ast_peer)
        resp, src = client.recvfrom(65535)
        assert src[1] == 5060, "response must come from :5060 (symmetric)"
        assert b"127.0.0.1:5070" not in resp, "Contact not rewritten"
        assert b"127.0.0.1" not in resp.split(b"\r\n\r\n", 1)[1], "loopback in SDP"
        assert content_length_ok(resp)
        print("PASS 2: 200 OK Contact + SDP rewritten, CL fixed")

        # 3: well-formed SDP passes through byte-identical
        clean_body = MALFORMED_BODY.replace(b":=4\n", b"").replace(b":=4000\n", b"")
        client.sendto(make_invite(clean_body), ("127.0.0.1", 5060))
        got2, _ = ast.recvfrom(65535)
        assert got2.split(b"\r\n\r\n", 1)[1] == clean_body, "clean body modified"
        print("PASS 3: well-formed SDP passes through unmodified")
    finally:
        relay.terminate()
        ast.close()
        client.close()


def part2_units():
    os.environ.update(ENV)
    os.environ["SIP_EXTERNAL_ADDRESS"] = "sip.example.com"
    sys.path.insert(0, ADDON)
    m = importlib.import_module("sip_sdp_relay")

    # classification (CGNAT 100.64/10 must be external)
    assert m.is_local("192.168.1.50") and m.is_local("127.0.0.1")
    assert not m.is_local("37.188.248.118") and not m.is_local("100.114.178.116")
    print("PASS 4: local/external classification (CGNAT is external)")

    # security log records external 4xx/5xx only
    m.log_security(b"SIP/2.0 404 Not Found\r\n\r\n", ("144.172.100.177", 64316))
    m.log_security(b"SIP/2.0 200 OK\r\n\r\n", ("144.172.100.177", 64316))
    m.log_security(b"SIP/2.0 404 Not Found\r\n\r\n", ("192.168.1.50", 5060))
    with open(SECLOG) as f:
        lines = f.read().strip().splitlines()
    assert len(lines) == 1 and "SECURITY 404 to 144.172.100.177:64316" in lines[0]
    print("PASS 5: security log records external 4xx only")

    # resolution priority chain (1.0.8), DNS fully monkeypatched
    m._dns_query_a = lambda name, server, timeout=2.0: "93.99.228.38"
    m.socket.gethostbyname = lambda h: "192.168.21.6"
    m._dns_cache = (None, 0.0)
    assert m.external_addr() == "93.99.228.38"
    print("PASS 6: public-resolver answer beats split-horizon host DNS")

    m._dns_query_a = lambda name, server, timeout=2.0: "192.168.21.6"
    m.socket.gethostbyname = lambda h: "192.168.21.6"
    m._dns_cache = (None, 0.0)
    assert m.external_addr() == "sip.example.com"
    print("PASS 7: intercepted port 53 -> hostname-literal fallback (cached)")
    assert m.external_addr() == "sip.example.com"  # served from cache

    m.PUBLIC_IP_OVERRIDE = "203.0.113.99"
    assert m.external_addr() == "203.0.113.99"
    m.PUBLIC_IP_OVERRIDE = ""
    print("PASS 8: SIP_PUBLIC_IP override wins")

    # DNS wire parser: compression pointers, CNAME-then-A answer
    def build_response(tid, qname, answers):
        r = struct.pack("!HHHHHH", tid, 0x8180, 1, len(answers), 0, 0)
        qn = b""
        for lbl in qname.split("."):
            qn += bytes([len(lbl)]) + lbl.encode()
        r += qn + b"\x00" + struct.pack("!HH", 1, 1)
        for rtype, rdata in answers:
            r += b"\xc0\x0c" + struct.pack("!HHIH", rtype, 1, 300, len(rdata)) + rdata
        return r

    class FakeSock:
        def __init__(self, *a): pass
        def settimeout(self, t): pass
        def sendto(self, data, addr): self.tid = struct.unpack("!H", data[:2])[0]
        def recvfrom(self, n):
            cname = b"\x03foo\x07example\x03com\x00"
            return build_response(self.tid, "sip.example.com",
                                  [(5, cname), (1, socket.inet_aton("93.99.228.38"))]), None
        def close(self): pass

    importlib.reload(m)  # restore the real _dns_query_a
    real_ctor = m.socket.socket
    m.socket.socket = lambda *a: FakeSock()
    try:
        assert m._dns_query_a("sip.example.com", "1.1.1.1") == "93.99.228.38"
    finally:
        m.socket.socket = real_ctor
    print("PASS 9: DNS parser handles CNAME + compressed names")

    # Via received/rport transparency (1.0.6)
    body = b"v=0\r\nc=IN IP4 127.0.0.1\r\nm=audio 10062 RTP/AVP 0\r\n"
    ok = (b"SIP/2.0 200 OK\r\n"
          b"Via: SIP/2.0/UDP 10.225.8.76:55726;rport=55517;received=127.0.0.1;branch=z9hG4bKx\r\n"
          b"Contact: <sip:127.0.0.1:5070>\r\n"
          b"Content-Length: %d\r\n\r\n" % len(body)) + body
    m.PUBLIC_IP_OVERRIDE = "93.99.228.38"
    out = m.rewrite_to_client(ok, ("109.81.170.217", 22170), 55517)
    assert b"rport=22170;received=109.81.170.217" in out
    assert b"received=127.0.0.1" not in out
    assert b"Contact: <sip:93.99.228.38:5060>" in out
    assert content_length_ok(out)
    print("PASS 10: Via rport/received restored to the real caller address")


if __name__ == "__main__":
    part1_live_sockets()
    part2_units()
    print("\nALL TESTS PASSED")

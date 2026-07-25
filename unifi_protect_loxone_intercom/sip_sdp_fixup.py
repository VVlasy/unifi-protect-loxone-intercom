#!/usr/bin/env python3
"""NFQUEUE handler that repairs malformed SDP bodies in inbound SIP/UDP
packets on port 5060 before Asterisk's PJSIP stack ever parses them.

Why this exists: Loxone's own SIP client ("Loxone Pjsua2 Wrapper"), on the
cloud-relayed remote/off-LAN call path, has been observed emitting truncated
SDP bandwidth lines - e.g. ":=4" instead of "b=AS:4" - which fails RFC 4566's
"<type>=<value>" line format. pjproject rejects the whole INVITE outright
(PJMEDIA_SDP_EINSDP, HTTP/SIP 400) before the call ever reaches the dialplan,
and there is no PJSIP config knob to make it lenient. Since b= lines are
purely advisory, dropping any line that doesn't match the required format is
a safe transformation - it never touches the codec/media negotiation lines
that actually matter (m=, c=, a=rtpmap, ...).

Only active when the entrypoint has installed the NFQUEUE iptables rule
(SIP_EXTERNAL_ADDRESS set - see ADVANCED.md). The rule uses --queue-bypass,
so if this process is down, traffic flows through unmodified rather than
being blocked. Runs unconditionally under supervisord either way; with no
rule installed it just sits idle waiting on the queue.
"""
import re
import socket
import struct
import sys

from netfilterqueue import NetfilterQueue

QUEUE_NUM = 5060
SIP_PORT = 5060
VALID_SDP_LINE = re.compile(rb"^[a-z]=")


def checksum16(data: bytes) -> int:
    if len(data) % 2:
        data += b"\x00"
    total = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def fix_sdp_body(body: bytes) -> bytes:
    eol = b"\r\n" if b"\r\n" in body else b"\n"
    lines = body.split(eol)
    kept = [line for line in lines if line == b"" or VALID_SDP_LINE.match(line)]
    return eol.join(kept)


def rewrite_sip_payload(payload: bytes):
    """Return a fixed copy of an inbound SIP/UDP payload, or None if it
    doesn't need fixing (no SDP body, or the body is already well-formed)."""
    if b"application/sdp" not in payload.lower():
        return None
    sep = b"\r\n\r\n" if b"\r\n\r\n" in payload else b"\n\n"
    if sep not in payload:
        return None
    headers, body = payload.split(sep, 1)
    fixed_body = fix_sdp_body(body)
    if fixed_body == body:
        return None

    header_eol = b"\r\n" if b"\r\n" in headers else b"\n"
    new_headers = []
    for line in headers.split(header_eol):
        if line.lower().startswith(b"content-length:"):
            new_headers.append(b"Content-Length: %d" % len(fixed_body))
        else:
            new_headers.append(line)
    return header_eol.join(new_headers) + sep + fixed_body


def process(pkt):
    try:
        data = pkt.get_payload()
        ihl = (data[0] & 0x0F) * 4
        proto = data[9]
        if proto != 17:  # UDP only
            pkt.accept()
            return

        src_port, dst_port, udp_len, _ = struct.unpack("!HHHH", data[ihl:ihl + 8])
        if dst_port != SIP_PORT:
            pkt.accept()
            return

        udp_payload = data[ihl + 8:ihl + udp_len]
        fixed = rewrite_sip_payload(udp_payload)
        if fixed is None:
            pkt.accept()
            return

        src_ip, dst_ip = data[12:16], data[16:20]
        new_udp_len = 8 + len(fixed)

        pseudo_header = src_ip + dst_ip + struct.pack("!BBH", 0, 17, new_udp_len)
        udp_header = struct.pack("!HHHH", src_port, dst_port, new_udp_len, 0)
        udp_csum = checksum16(pseudo_header + udp_header + fixed) or 0xFFFF
        udp_header = struct.pack("!HHHH", src_port, dst_port, new_udp_len, udp_csum)

        ip_header = bytearray(data[:ihl])
        struct.pack_into("!H", ip_header, 2, ihl + new_udp_len)
        ip_header[10:12] = b"\x00\x00"
        struct.pack_into("!H", ip_header, 10, checksum16(bytes(ip_header)))

        pkt.set_payload(bytes(ip_header) + udp_header + fixed)
        print(
            "[sdp-fixup] sanitized malformed SDP body from %s:%d (%d -> %d bytes)"
            % (socket.inet_ntoa(src_ip), src_port, len(udp_payload), len(fixed) + 8),
            file=sys.stderr,
            flush=True,
        )
        pkt.accept()
    except Exception as exc:
        # Never hold up traffic because of a bug in this script.
        print("[sdp-fixup] error, passing packet through unmodified: %r" % (exc,), file=sys.stderr, flush=True)
        pkt.accept()


def main():
    nfqueue = NetfilterQueue()
    nfqueue.bind(QUEUE_NUM, process)
    print("[sdp-fixup] listening on NFQUEUE %d (idle until the entrypoint installs the iptables rule)" % QUEUE_NUM,
          file=sys.stderr, flush=True)
    try:
        nfqueue.run()
    finally:
        nfqueue.unbind()


if __name__ == "__main__":
    main()

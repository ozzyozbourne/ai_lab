#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Chapter 10 test traffic, with no external dependencies.

    python3 -I gen_pcaps.py            # writes mixed.pcap, in.pcap, empty.pcap

mixed.pcap : 14 hand-made frames that exercise every branch of parse_pcap.c
             (IPv4/UDP, TCP, ICMP, ARP, IPv6 with an extension header, VLAN,
             QinQ, VXLAN, IP options, fragments and three broken frames).
in.pcap    : 100 IPv4/UDP frames for the l2fwd run.
empty.pcap : a pcap header with no packets (an RX source that is always empty).
All checksums are correct unless a frame is deliberately broken.
"""
import struct

def csum(b):
    """RFC 1071 Internet checksum: one's-complement sum of 16-bit words."""
    if len(b) % 2:
        b += b'\0'
    s = sum(struct.unpack('!%dH' % (len(b) // 2), b))
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff

MAC_A = bytes.fromhex('020000000001')   # sender
MAC_B = bytes.fromhex('020000000002')   # receiver
BCAST = b'\xff' * 6

def eth(t, dst=MAC_B, src=MAC_A):
    return dst + src + struct.pack('!H', t)

def vlan(vid, inner_type, pcp=0):
    return struct.pack('!HH', (pcp << 13) | vid, inner_type)

def ip4(src, dst, proto, payload, ttl=64, ident=1, frag=0, opts=b'', ihl=None):
    hl = 20 + len(opts)
    if ihl is None:
        ihl = hl // 4
    h = struct.pack('!BBHHHBBH4s4s', 0x40 | ihl, 0, hl + len(payload), ident,
                    frag, ttl, proto, 0, bytes(src), bytes(dst)) + opts
    h = h[:10] + struct.pack('!H', csum(h)) + h[12:]
    return h + payload

def l4_cksum4(src, dst, proto, seg):
    ph = bytes(src) + bytes(dst) + struct.pack('!BBH', 0, proto, len(seg))
    c = csum(ph + seg)
    return 0xffff if (c == 0 and proto == 17) else c

def udp4(src, dst, sport, dport, payload):
    u = struct.pack('!HHHH', sport, dport, 8 + len(payload), 0) + payload
    c = l4_cksum4(src, dst, 17, u)
    return u[:6] + struct.pack('!H', c) + u[8:]

def tcp4(src, dst, sport, dport, flags=0x02, payload=b''):
    t = struct.pack('!HHIIBBHHH', sport, dport, 1000, 0, 5 << 4, flags, 65535, 0, 0) + payload
    c = l4_cksum4(src, dst, 6, t)
    return t[:16] + struct.pack('!H', c) + t[18:]

def icmp_echo(ident, seq, payload):
    i = struct.pack('!BBHHH', 8, 0, 0, ident, seq) + payload
    return i[:2] + struct.pack('!H', csum(i)) + i[4:]

def ip6(src, dst, nh, payload, tc=0, flow=0, hlim=64):
    vtc = (6 << 28) | (tc << 20) | flow
    return struct.pack('!IHBB', vtc, len(payload), nh, hlim) + src + dst + payload

def udp6(src, dst, sport, dport, payload):
    u = struct.pack('!HHHH', sport, dport, 8 + len(payload), 0) + payload
    ph = src + dst + struct.pack('!IxxxB', len(u), 17)
    c = csum(ph + u) or 0xffff
    return u[:6] + struct.pack('!H', c) + u[8:]

A1, A2 = [10, 10, 0, 1], [10, 10, 0, 2]
S6 = bytes.fromhex('fd000010000000000000000000000001')
D6 = bytes.fromhex('fd000010000000000000000000000002')
P = b'ch10-payload'

def mixed():
    f = []
    # 1 plain IPv4/UDP
    f.append(eth(0x0800) + ip4(A1, A2, 17, udp4(A1, A2, 1000, 2000, P)))
    # 2 IPv4/TCP SYN
    f.append(eth(0x0800) + ip4(A1, A2, 6, tcp4(A1, A2, 40000, 80)))
    # 3 IPv4/ICMP echo request
    f.append(eth(0x0800) + ip4(A1, A2, 1, icmp_echo(0x1234, 1, P)))
    # 4 ARP request "who has 10.10.0.2? tell 10.10.0.1"
    arp = struct.pack('!HHBBH6s4s6s4s', 1, 0x0800, 6, 4, 1, MAC_A, bytes(A1), b'\0' * 6, bytes(A2))
    f.append(eth(0x0806, dst=BCAST) + arp)
    # 5 IPv6/UDP with traffic class 0xb8 (DSCP EF) and flow label 0x12345
    f.append(eth(0x86dd) + ip6(S6, D6, 17, udp6(S6, D6, 5353, 5353, P), tc=0xb8, flow=0x12345))
    # 6 IPv6 + hop-by-hop options (8 bytes, PadN) + UDP
    hbh = bytes([17, 0, 1, 4, 0, 0, 0, 0])
    f.append(eth(0x86dd) + ip6(S6, D6, 0, hbh + udp6(S6, D6, 7000, 7001, P)))
    # 7 one 802.1Q tag (VLAN 100, PCP 5) around IPv4/UDP
    f.append(eth(0x8100) + vlan(100, 0x0800, pcp=5) + ip4(A1, A2, 17, udp4(A1, A2, 1001, 2001, P)))
    # 8 QinQ: outer 802.1ad S-tag 200, inner C-tag 100
    f.append(eth(0x88a8) + vlan(200, 0x8100) + vlan(100, 0x0800) +
             ip4(A1, A2, 17, udp4(A1, A2, 1002, 2002, P)))
    # 9 VXLAN (UDP 4789, VNI 5000) carrying an inner Ethernet/IPv4/TCP frame
    I1, I2 = [192, 168, 50, 1], [192, 168, 50, 2]
    inner = eth(0x0800, dst=bytes.fromhex('0200000000bb'), src=bytes.fromhex('0200000000aa')) + \
        ip4(I1, I2, 6, tcp4(I1, I2, 33333, 443, flags=0x10))
    vx = struct.pack('!II', 0x08000000, 5000 << 8) + inner
    outer_udp = struct.pack('!HHHH', 49152, 4789, 8 + len(vx), 0) + vx   # IPv4 outer: cksum 0 is allowed
    f.append(eth(0x0800) + ip4(A1, A2, 17, outer_udp))
    # 10 IPv4 with 4 bytes of options (IHL 6: NOP NOP NOP EOL) + UDP
    f.append(eth(0x0800) + ip4(A1, A2, 17, udp4(A1, A2, 1003, 2003, P), opts=b'\x01\x01\x01\x00'))
    # 11 first IPv4 fragment (MF=1, offset 0) and 12 a later fragment (offset 185*8)
    full = udp4(A1, A2, 1004, 2004, bytes(64))
    f.append(eth(0x0800) + ip4(A1, A2, 17, full[:40], ident=77, frag=0x2000))
    f.append(eth(0x0800) + ip4(A1, A2, 17, full[40:], ident=77, frag=185))
    # 13 BROKEN: truncated, only 10 bytes of the IPv4 header were captured
    f.append((eth(0x0800) + ip4(A1, A2, 17, udp4(A1, A2, 1, 2, P)))[:24])
    # 14 BROKEN: IHL = 3 (12 bytes), smaller than the minimum of 5
    f.append(eth(0x0800) + ip4(A1, A2, 17, udp4(A1, A2, 1, 2, P), ihl=3))
    # 15 BROKEN: IPv4 header checksum corrupted
    bad = bytearray(eth(0x0800) + ip4(A1, A2, 17, udp4(A1, A2, 1005, 2005, P)))
    bad[24] ^= 0x5a
    f.append(bytes(bad))
    return f

def bulk(n):
    out = []
    for i in range(n):
        src, dst = [10, 10, 1, 1 + i % 10], [10, 10, 2, 1 + i % 4]
        out.append(eth(0x0800) + ip4(src, dst, 17, udp4(src, dst, 1000 + i, 2000 + i % 7, bytes(18))))
    return out

def write(fn, frames):
    with open(fn, 'wb') as fp:
        fp.write(struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
        for i, p in enumerate(frames):
            fp.write(struct.pack('<IIII', 1, i, len(p), len(p)) + p)

if __name__ == '__main__':
    write('mixed.pcap', mixed())
    write('in.pcap', bulk(100))
    write('empty.pcap', [])
    print('wrote mixed.pcap (%d frames), in.pcap (100 frames), empty.pcap' % len(mixed()))

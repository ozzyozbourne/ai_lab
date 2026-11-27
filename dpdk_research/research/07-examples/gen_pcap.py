#!/usr/bin/env python3
"""Generate a pcap of IPv4/UDP packets with no external deps.
usage: gen_pcap.py out.pcap N [dst_prefix: 'a.b' -> a.b.(i%4).x, 'a.b.c' -> a.b.c.x] [payload_len]"""
import struct, sys, random
def csum(b):
    if len(b) % 2: b += b'\0'
    s = sum(struct.unpack('!%dH' % (len(b)//2), b))
    while s >> 16: s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff
def pkt(src, dst, sport, dport, plen):
    payload = bytes(plen)
    udp = struct.pack('!HHHH', sport, dport, 8+plen, 0) + payload
    ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20+len(udp), 1, 0, 64, 17, 0,
                     bytes(src), bytes(dst))
    ip = ip[:10] + struct.pack('!H', csum(ip)) + ip[12:]
    eth = bytes.fromhex('020000000001' '020000000002' '0800')
    return eth + ip + udp
out, n = sys.argv[1], int(sys.argv[2])
pfx = [int(x) for x in (sys.argv[3] if len(sys.argv) > 3 else '198.18').split('.')]
plen = int(sys.argv[4]) if len(sys.argv) > 4 else 18
random.seed(7)
with open(out, 'wb') as f:
    f.write(struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
    for i in range(n):
        dst = (pfx + [i % 4, 1 + i % 200]) if len(pfx) == 2 else (pfx + [1 + i % 200])
        p = pkt([10, 0, 0, 1 + i % 10], dst, 1000 + i % 50, 2000 + i % 7, plen)
        f.write(struct.pack('<IIII', 0, i, len(p), len(p)) + p)

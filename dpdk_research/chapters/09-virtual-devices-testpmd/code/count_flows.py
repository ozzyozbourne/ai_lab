#!/usr/bin/env python3
# count_flows.py FILE - count frames and distinct IPv4/UDP 5-tuples in a pcap,
# and check the IPv4 header and UDP/TCP checksums of every frame.
import struct, sys

def csum(b):
    if len(b) % 2: b += b'\0'
    s = sum(struct.unpack('!%dH' % (len(b) // 2), b))
    while s >> 16: s = (s & 0xffff) + (s >> 16)
    return s

data = open(sys.argv[1], 'rb').read()
off, n, flows, ip_ok, l4_ok, l4_zero = 24, 0, set(), 0, 0, 0
while off + 16 <= len(data):
    caplen = struct.unpack('<I', data[off + 8:off + 12])[0]
    fr = data[off + 16:off + 16 + caplen]; off += 16 + caplen; n += 1
    if len(fr) < 34 or fr[12:14] != b'\x08\x00':
        continue
    ihl = (fr[14] & 15) * 4; ip = fr[14:14 + ihl]; proto = fr[23]
    ip_ok += csum(ip) == 0xffff
    l4 = fr[14 + ihl:14 + struct.unpack('!H', ip[2:4])[0]]
    sp, dp = struct.unpack('!HH', l4[:4])
    flows.add((ip[12:16], ip[16:20], proto, sp, dp))
    pseudo = ip[12:20] + struct.pack('!BBH', 0, proto, len(l4))
    if proto == 17 and l4[6:8] == b'\0\0':
        l4_zero += 1
    elif csum(pseudo + l4) == 0xffff:
        l4_ok += 1
print("frames=%d distinct_flows=%d ip_csum_ok=%d l4_csum_ok=%d udp_csum_zero=%d"
      % (n, len(flows), ip_ok, l4_ok, l4_zero))

#!/usr/bin/env python3
"""Summarise a pcap: count packets per (dst MAC, dst IP /24) and TTL."""
import struct, sys, collections
for fn in sys.argv[1:]:
    d = open(fn, 'rb').read(); off = 24; c = collections.Counter()
    while off + 16 <= len(d):
        _, _, incl, _ = struct.unpack('<IIII', d[off:off+16]); p = d[off+16:off+16+incl]; off += 16 + incl
        mac = p[0:6].hex(':'); ttl = p[22]; dst = '.'.join(map(str, p[30:33]))
        c[(mac, dst + '.x', 'ttl=%d' % ttl)] += 1
    print(fn, sum(c.values()), 'pkts')
    for k, v in sorted(c.items()): print('   ', k, v)

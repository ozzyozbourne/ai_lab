#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Check l2fwd output pcaps: every frame leaving port P must carry
dst MAC 02:00:00:00:00:0P and src MAC = port P's MAC.

    python3 -I l2check.py l2out0.pcap:0:02:70:63:61:70:00 l2out1.pcap:1:02:70:63:61:70:01
"""
import struct, sys, collections

bad = 0
for arg in sys.argv[1:]:
    fn, port, mac = arg.split(':', 2)
    want_dst = '02:00:00:00:00:%02x' % int(port)
    d = open(fn, 'rb').read()
    off, c = 24, collections.Counter()
    while off + 16 <= len(d):
        incl = struct.unpack('<IIII', d[off:off + 16])[2]
        p = d[off + 16:off + 16 + incl]
        off += 16 + incl
        c[(p[0:6].hex(':'), p[6:12].hex(':'), p[22])] += 1
    n = sum(c.values())
    print('%s (port %s): %d frames' % (fn, port, n))
    for (dst, src, ttl), k in sorted(c.items()):
        ok = dst == want_dst and src == mac.lower()
        bad += 0 if ok else k
        print('    dst %s  src %s  ttl %d  x%d  %s' % (dst, src, ttl, k, 'ok' if ok else 'WRONG'))
print('MAC rewrite check:', 'PASS' if bad == 0 else 'FAIL (%d frames)' % bad)
sys.exit(1 if bad else 0)

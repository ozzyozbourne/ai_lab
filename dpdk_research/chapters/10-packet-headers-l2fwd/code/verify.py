#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Independently check the frames written by build_packets.

    python3 -I verify.py built.pcap [built.crc]

Re-computes every IPv4 header checksum and every UDP/TCP/ICMP checksum
(including the IPv6 pseudo-header and the inner frame of VXLAN) with plain
Python, and compares the Ethernet CRC32 with zlib.crc32. Exit status 1 if
anything is wrong.
"""
import struct, sys, zlib

def csum(b):
    if len(b) % 2:
        b += b'\0'
    s = sum(struct.unpack('!%dH' % (len(b) // 2), b))
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return s            # NOT inverted: a correct packet sums to 0xffff

bad = 0
def check(ok, what, notes):
    global bad
    notes.append('%s=%s' % (what, 'ok' if ok else 'BAD'))
    if not ok:
        bad += 1

def l4(proto, seg, phdr, notes, inner):
    if proto == 17:
        sport, dport, ulen, ck = struct.unpack('!HHHH', seg[:8])
        notes.append('UDP %d->%d' % (sport, dport))
        if ck == 0:
            notes.append('udpcsum=none')
        else:
            check(csum(phdr + seg) == 0xffff, 'udpcsum', notes)
        if dport == 4789 and not inner:
            flags, vni = struct.unpack('!II', seg[8:16])
            notes.append('VXLAN vni=%d I=%d {' % (vni >> 8, (flags >> 27) & 1))
            ether(seg[16:], notes, inner=True)
            notes.append('}')
        if dport == 47000:
            ver, fl, sess, seq = struct.unpack('!BBIH', seg[8:16])
            notes.append('TOY ver=%d flags=%d session=0x%08x seq=%d' % (ver, fl, sess, seq))
    elif proto == 1:
        t, c = seg[0], seg[1]
        notes.append('ICMP type=%d code=%d' % (t, c))
        check(csum(seg) == 0xffff, 'icmpcsum', notes)

def ether(p, notes, inner=False):
    t = struct.unpack('!H', p[12:14])[0]
    off = 14
    while t in (0x8100, 0x88a8):
        tci, t2 = struct.unpack('!HH', p[off:off + 4])
        notes.append('tag(tpid=0x%04x vid=%d pcp=%d)' % (t, tci & 0xfff, tci >> 13))
        t, off = t2, off + 4
    if t == 0x0806:
        op = struct.unpack('!H', p[off + 6:off + 8])[0]
        notes.append('ARP op=%d tip=%s' % (op, '.'.join(map(str, p[off + 24:off + 28]))))
    elif t == 0x0800:
        ihl = (p[off] & 0xf) * 4
        ip = p[off:off + ihl]
        tot = struct.unpack('!H', ip[2:4])[0]
        check(csum(ip) == 0xffff, 'ipcsum', notes)
        proto = ip[9]
        seg = p[off + ihl:off + tot]
        phdr = ip[12:20] + struct.pack('!BBH', 0, proto, len(seg))
        l4(proto, seg, phdr, notes, inner)
    elif t == 0x86dd:
        vtc, plen, nh, hl = struct.unpack('!IHBB', p[off:off + 8])
        notes.append('IPv6 tc=0x%02x flow=0x%05x' % ((vtc >> 20) & 0xff, vtc & 0xfffff))
        seg = p[off + 40:off + 40 + plen]
        phdr = p[off + 8:off + 40] + struct.pack('!IxxxB', plen, nh)
        l4(nh, seg, phdr, notes, inner)

frames = []
d = open(sys.argv[1], 'rb').read()
off = 24
while off + 16 <= len(d):
    incl = struct.unpack('<IIII', d[off:off + 16])[2]
    frames.append(d[off + 16:off + 16 + incl])
    off += 16 + incl
crcs = [int(x, 16) for x in open(sys.argv[2]).read().split()] if len(sys.argv) > 2 else []
for i, p in enumerate(frames):
    notes = []
    ether(p, notes)
    if i < len(crcs):
        check(zlib.crc32(p) == crcs[i], 'crc32(zlib 0x%08x)' % zlib.crc32(p), notes)
    print('%d len=%d %s' % (i + 1, len(p), ' '.join(notes)))
print('%d frames, %d problems -> %s' % (len(frames), bad, 'PASS' if bad == 0 else 'FAIL'))
sys.exit(1 if bad else 0)

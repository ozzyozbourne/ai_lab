#!/usr/bin/env python3
# read_pcap.py FILE [K] - count frames in a classic pcap file and print the
# MAC addresses and IPv4 addresses of the first K (default 3) frames.
import struct, sys

def mac(b):
    return ':'.join('%02x' % x for x in b)

path = sys.argv[1]; k = int(sys.argv[2]) if len(sys.argv) > 2 else 3
data = open(path, 'rb').read()
off, n = 24, 0
while off + 16 <= len(data):
    _, _, caplen, _ = struct.unpack('<IIII', data[off:off + 16])
    fr = data[off + 16: off + 16 + caplen]
    if n < k:
        src = dst = '-'; ports = ''
        if len(fr) >= 34 and fr[12:14] == b'\x08\x00':
            src = '.'.join(str(x) for x in fr[26:30]); dst = '.'.join(str(x) for x in fr[30:34])
            ihl = (fr[14] & 15) * 4
            if fr[23] in (6, 17) and len(fr) >= 14 + ihl + 4:
                sp, dp = struct.unpack('!HH', fr[14 + ihl:18 + ihl])
                ports = ' %s %d -> %d' % ('udp' if fr[23] == 17 else 'tcp', sp, dp)
        print("  frame %d: dst=%s src=%s  ip %s -> %s%s  len=%d" % (n, mac(fr[0:6]), mac(fr[6:12]), src, dst, ports, caplen))
    n += 1
    off += 16 + caplen
print("  %s: %d frames" % (path, n))

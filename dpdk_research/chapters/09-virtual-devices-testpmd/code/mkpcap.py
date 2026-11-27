#!/usr/bin/env python3
# mkpcap.py OUT N [udp|tcp] - write N Ethernet/IPv4/UDP (or TCP) frames to a
# classic pcap file. dst MAC 02:00:00:00:00:02, src 02:00:00:00:00:01,
# IPs 10.9.0.(1..4) -> 10.9.1.1, src ports 1000..1007, dst port 53.
# Checksums: IPv4 header checksum is correct, the L4 checksum is left 0
# (UDP) or wrong (TCP) so csum mode has something to report.
import socket, struct, sys

def ip_csum(h):
    s = sum(struct.unpack('!10H', h))
    s = (s >> 16) + (s & 0xffff); s += s >> 16
    return (~s) & 0xffff

out, n = sys.argv[1], int(sys.argv[2])
proto = sys.argv[3] if len(sys.argv) > 3 else 'udp'
with open(out, 'wb') as f:
    f.write(struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
    for i in range(n):
        payload = b'ch09 pkt %05d' % i
        if proto == 'tcp':
            l4 = struct.pack('!HHIIBBHHH', 1000 + i % 8, 80, i, 0, 5 << 4, 0x02, 8192, 0xdead, 0) + payload
            p = 6
        else:
            l4 = struct.pack('!HHHH', 1000 + i % 8, 53, 8 + len(payload), 0) + payload
            p = 17
        ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(l4), i & 0xffff, 0, 64, p, 0,
                         socket.inet_aton('10.9.0.%d' % (1 + i % 4)), socket.inet_aton('10.9.1.1'))
        ip = ip[:10] + struct.pack('!H', ip_csum(ip)) + ip[12:]
        fr = b'\x02\x00\x00\x00\x00\x02' + b'\x02\x00\x00\x00\x00\x01' + b'\x08\x00' + ip + l4
        f.write(struct.pack('<IIII', 1700000000 + i, 0, len(fr), len(fr)) + fr)
print("wrote %d %s frames to %s" % (n, proto, out))

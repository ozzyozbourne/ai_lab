#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Write classic libpcap files of Ethernet/IPv4/UDP frames for chapter 12.
#   python3 -I gen_pcap.py <out.pcap> <count> [flows]
# Frame i uses UDP source port 1000 + i % flows, so a "flow" is a 5-tuple.
import socket
import struct
import sys

out, n = sys.argv[1], int(sys.argv[2])
flows = int(sys.argv[3]) if len(sys.argv) > 3 else 8


def csum(b):
    s = sum(struct.unpack('!%dH' % (len(b) // 2), b))
    s = (s >> 16) + (s & 0xffff)
    s += s >> 16
    return ~s & 0xffff


with open(out, 'wb') as f:
    f.write(struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
    for i in range(n):
        payload = b'ch12-%06d' % i
        ip = bytearray(struct.pack('!BBHHHBBH4s4s', 0x45, 0, 28 + len(payload),
                                   i & 0xffff, 0, 64, 17, 0,
                                   socket.inet_aton('10.12.0.1'),
                                   socket.inet_aton('10.12.0.2')))
        ip[10:12] = struct.pack('!H', csum(bytes(ip)))
        udp = struct.pack('!HHHH', 1000 + i % flows, 9, 8 + len(payload), 0)
        fr = (b'\x02\x12\x00\x00\x00\x02' + b'\x02\x12\x00\x00\x00\x01' +
              b'\x08\x00' + bytes(ip) + udp + payload)
        f.write(struct.pack('<IIII', 1700000000 + i, 0, len(fr), len(fr)) + fr)

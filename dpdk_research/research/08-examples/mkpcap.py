#!/usr/bin/env python3
"""Write N IPv4/UDP packets to a pcap (no scapy needed). usage: mkpcap.py out.pcap [N] [payload_len]"""
import struct, sys
out = sys.argv[1]; n = int(sys.argv[2]) if len(sys.argv) > 2 else 64; pl = int(sys.argv[3]) if len(sys.argv) > 3 else 64
def csum(b):
    s = sum(struct.unpack('!%dH' % (len(b)//2), b)); s = (s >> 16) + (s & 0xffff); s += s >> 16
    return (~s) & 0xffff
with open(out, 'wb') as f:
    f.write(struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
    for i in range(n):
        payload = (b'DPDK-crypto-%04d-' % i).ljust(pl, b'.')
        udp = struct.pack('!HHHH', 1000 + i % 8, 2000, 8 + len(payload), 0) + payload
        ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(udp), i, 0, 64, 17, 0, bytes([10,0,0,1]), bytes([10,0,0,2]))
        ip = ip[:10] + struct.pack('!H', csum(ip)) + ip[12:]
        eth = bytes.fromhex('020000000002' '020000000001' '0800')
        pkt = eth + ip + udp
        f.write(struct.pack('<IIII', i, 0, len(pkt), len(pkt)) + pkt)

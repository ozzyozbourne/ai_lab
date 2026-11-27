#!/usr/bin/env python3
# sendraw.py IFACE N - send N broadcast Ethernet/IPv4/UDP frames out of IFACE
# with an AF_PACKET raw socket (needs root). No tcpdump/scapy needed.
import socket, struct, sys
iface, n = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
s.bind((iface, 0))
dst = b'\xff' * 6; src = b'\x02\x00\x00\x00\x09\x01'
payload = b'DPDK-ch09 ' * 5
ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + 8 + len(payload), 1, 0, 64, 17, 0,
                 socket.inet_aton('10.9.0.1'), socket.inet_aton('10.9.0.2'))
udp = struct.pack('!HHHH', 1234, 5678, 8 + len(payload), 0)
frame = dst + src + b'\x08\x00' + ip + udp + payload
sent = 0
for i in range(n):
    sent += 1 if s.send(frame) == len(frame) else 0
print("sent %d frames of %d bytes on %s" % (sent, len(frame), iface))

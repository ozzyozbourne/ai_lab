#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
"""Send UDP flows from a raw AF_PACKET socket (no scapy needed).

usage: python3 -I flows.py <iface> <nflows> <pkts_per_flow> [gap_ms]

Flow i is 10.15.0.1:(10000+i) -> 10.15.0.2:5000. Packets are interleaved
(flow 0, flow 1, ..., flow n-1, flow 0, ...) so that per-flow order and
per-queue spreading can both be checked by the receiver. The UDP payload
starts with 'CH15', then the flow id (u16) and the per-flow sequence (u32).
"""
import socket, struct, sys, time

def csum(b):
    if len(b) % 2:
        b += b'\0'
    s = sum(struct.unpack('!%dH' % (len(b) // 2), b))
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff

def frame(flow, seq):
    payload = b'CH15' + struct.pack('!HI', flow, seq) + bytes(22)
    udp = struct.pack('!HHHH', 10000 + flow, 5000, 8 + len(payload), 0) + payload
    ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(udp), seq & 0xffff, 0, 64, 17, 0,
                     socket.inet_aton('10.15.0.1'), socket.inet_aton('10.15.0.2'))
    ip = ip[:10] + struct.pack('!H', csum(ip)) + ip[12:]
    eth = bytes.fromhex('02000000150b' '02000000150a' '0800')
    return eth + ip + udp

iface, nflows, per = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
gap = float(sys.argv[4]) / 1000 if len(sys.argv) > 4 else 0.0
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
s.bind((iface, 0))
sent = 0
for seq in range(per):
    for f in range(nflows):
        s.send(frame(f, seq))
        sent += 1
    if gap:
        time.sleep(gap)
print("flows.py: sent %d packets (%d flows x %d) on %s" % (sent, nflows, per, iface))

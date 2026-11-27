#!/usr/bin/env python3
"""Inject frames from a pcap into a (DPDK net_tap) kernel interface and capture
what comes out of another one.  usage: tap_inject.py IN_IF OUT_IF in.pcap out.pcap [secs]"""
import socket, struct, sys, time
in_if, out_if, inp, outp = sys.argv[1:5]; secs = float(sys.argv[5]) if len(sys.argv) > 5 else 3
rx = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3)); rx.bind((out_if, 0)); rx.settimeout(0.2)
tx = socket.socket(socket.AF_PACKET, socket.SOCK_RAW); tx.bind((in_if, 0))
d = open(inp, 'rb').read(); off = 24; n = 0
while off + 16 <= len(d):
    _, _, l, _ = struct.unpack('<IIII', d[off:off+16]); tx.send(d[off+16:off+16+l]); off += 16 + l; n += 1
print('injected', n, 'frames into', in_if)
got = []; end = time.time() + secs
while time.time() < end:
    try:
        f, addr = rx.recvfrom(65535)
        if addr[2] != socket.PACKET_OUTGOING: got.append(f)
    except socket.timeout: pass
with open(outp, 'wb') as o:
    o.write(struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
    for i, f in enumerate(got): o.write(struct.pack('<IIII', 0, i, len(f), len(f)) + f)
print('captured', len(got), 'frames from', out_if)

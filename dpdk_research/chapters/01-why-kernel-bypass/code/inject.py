#!/usr/bin/env python3
"""inject.py IFACE RATE SECONDS - write timestamped raw Ethernet frames into IFACE.

Used by run.sh to feed the net_tap port of intr_vs_poll. Writing a frame to the
kernel side of a tap interface makes it appear on the DPDK side. Bytes 14..21
hold time.monotonic_ns() (== CLOCK_MONOTONIC in C, little-endian) so the
receiver can compute one-way latency. EtherType 0x88b5 = "local experimental".
Run as root, with python3 -I.
"""
import socket, struct, sys, time

ifc, rate, secs = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
s.bind((ifc, 0))
hdr = bytes.fromhex('ffffffffffff' '020000000001' '88b5')
n = int(rate * secs)
t0 = time.monotonic()
for i in range(n):
    target = t0 + i / rate
    while True:                      # pace the sender
        d = target - time.monotonic()
        if d <= 0:
            break
        time.sleep(min(d, 0.0005))
    s.send(hdr + struct.pack('<Q', time.monotonic_ns()) + b'x' * 42)
print(f"inject.py: sent {n} frames at {rate:g}/s into {ifc}")

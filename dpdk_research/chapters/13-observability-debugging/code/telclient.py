#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13: telclient.py - the whole telemetry protocol in 25 lines.
#
# usage: python3 -I telclient.py <file-prefix> <cmd> [<cmd> ...]
#
# The socket is <runtime dir>/dpdk_telemetry.v2, an AF_UNIX SOCK_SEQPACKET
# socket. SEQPACKET keeps message boundaries: one send() is one request,
# one recv() is one complete JSON reply (at most max_output_len bytes).
import json
import socket
import sys
import time

prefix = sys.argv[1]
path = f"/var/run/dpdk/{prefix}/dpdk_telemetry.v2"
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
s.connect(path)
hello = json.loads(s.recv(1024))            # server speaks first
print("connected to", path)
print("hello:", hello)
for cmd in sys.argv[2:]:
    t0 = time.perf_counter()
    s.send(cmd.encode())                    # "<command>[,<params>]"
    raw = s.recv(hello["max_output_len"])
    dt = (time.perf_counter() - t0) * 1e6
    reply = json.loads(raw)
    print(f"{cmd} -> {len(raw)} bytes in {dt:.0f} us")
    print("   ", json.dumps(reply)[:300])
s.close()

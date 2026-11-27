#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13: tq.py - one telemetry query, optionally keeping only some keys.
# usage: python3 -I tq.py <file-prefix> <command> [key ...]
import json
import socket
import sys

s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
s.connect(f"/var/run/dpdk/{sys.argv[1]}/dpdk_telemetry.v2")
hello = json.loads(s.recv(1024))
s.send(sys.argv[2].encode())
reply = json.loads(s.recv(hello["max_output_len"]))
val = reply[sys.argv[2].split(",")[0]]
if len(sys.argv) > 3 and isinstance(val, dict):
    val = {k: val[k] for k in sys.argv[3:] if k in val}
print(json.dumps({sys.argv[2]: val}))

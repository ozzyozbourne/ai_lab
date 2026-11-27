#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13, exercise 2 (solution): poll /ethdev/stats,<port> every 0.5 s
# and print packets per second, from outside the application.
# usage: poll_pps.sh <file-prefix> [port] [samples]
# One persistent SEQPACKET connection (not one per sample): opening a
# connection makes the telemetry thread start a new pthread each time.
prefix=${1:?file-prefix}; port=${2:-0}; n=${3:-6}
exec python3 -I - "$prefix" "$port" "$n" <<'PY'
import json, socket, sys, time
prefix, port, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
s.connect(f"/var/run/dpdk/{prefix}/dpdk_telemetry.v2")
maxlen = json.loads(s.recv(1024))["max_output_len"]
def sample():
    s.send(f"/ethdev/stats,{port}".encode())
    st = json.loads(s.recv(maxlen))["/ethdev/stats"]
    return time.monotonic(), st["ipackets"], st["opackets"]
t0, rx0, tx0 = sample()
for _ in range(n):
    time.sleep(0.5)
    t1, rx1, tx1 = sample()
    dt = t1 - t0
    print(f"port {port}: rx {(rx1 - rx0) / dt / 1e6:7.3f} Mpps  tx {(tx1 - tx0) / dt / 1e6:7.3f} Mpps")
    t0, rx0, tx0 = t1, rx1, tx1
PY

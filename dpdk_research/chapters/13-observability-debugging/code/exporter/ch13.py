# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13: exporter/ch13.py - a dpdk-telemetry-exporter.py endpoint module.
#
# The exporter imports every *.py in its load path. Each module provides
# info() (metric name -> (help text, type)) and metrics(sock), which queries
# telemetry and returns (name, value, labels) tuples. This one turns the
# app's own /ch13/stats endpoint into Prometheus metrics.
#
# run: dpdk-telemetry-exporter.py -p ./exporter -e ch13 \
#        -s /var/run/dpdk/ch13-tel/dpdk_telemetry.v2 -o http://127.0.0.1:9913

PKTS = "port_packets"
POLLS = "worker_polls"


def info():
    return {
        PKTS: ("Packets counted by telemetry_app, by port and direction.", "counter"),
        POLLS: ("Worker loop iterations, busy or idle.", "counter"),
    }


def metrics(sock):
    st = sock.cmd("/ch13/stats")
    out = []
    for port in ("port0", "port1"):
        for d in ("rx", "tx", "drop"):
            out.append((PKTS, st[port][d], {"port": port, "dir": d}))
    out.append((POLLS, st["busy_polls"], {"kind": "busy"}))
    out.append((POLLS, st["idle_polls"], {"kind": "idle"}))
    return out

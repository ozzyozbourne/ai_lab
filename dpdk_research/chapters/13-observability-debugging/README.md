# Chapter 13: Observability and Debugging

Telemetry, metrics, tracing, logs, gdb and post-mortem analysis, five debug
labs, the consolidated startup-error table, the band 2 review and the band 2
project. Open `index.html` in a browser (works from `file://`, no network).

## What is here

| Path | What it is |
|---|---|
| `index.html`, `ch13.js`, `data.js` | the chapter page; widgets in `ch13.js`; `data.js` holds snippets of `code/expected_output.txt` used by the widgets |
| `code/ch13_common.h` | port init, frame builder, kernel-side injection for tap |
| `code/telemetry_app.c` | custom endpoints `/ch13/stats` and `/ch13/echo`, lcore usage callback, register errors |
| `code/telclient.py`, `code/tq.py` | raw SEQPACKET telemetry clients |
| `code/exporter/ch13.py` | an endpoint module for `dpdk-telemetry-exporter.py` |
| `code/latency_metrics.c` | latencystats + bitratestats + rte_metrics, exposed as `/ch13/latency` |
| `code/ch13_trace.h`, `ch13_trace_reg.c`, `trace_demo.c`, `trace_fp_on.h` | slow- and fast-path tracepoints; `trace_demo_fp` is the same source with fast-path tracepoints compiled in |
| `code/ctf_peek.py` | a tiny CTF reader (babeltrace is not installed) |
| `code/logdp.c` | `RTE_LOG_DP` vs `RTE_LOG`, cost measured (median of 5) |
| `code/panic_demo.c`, `code/gdb_live.gdb` | gdb on a live process, `rte_panic`, `rte_mbuf_check` |
| `code/asan_demo.c` | gcc AddressSanitizer on a DPDK app (`asan_demo_asan`) |
| `code/crash_postmortem.sh` | core files with different `coredump_filter` values, hugepages vs `--no-huge`, gdb on each |
| `code/debug_labs/` | five seeded bugs (`lab`) and fixes (`lab_fixed`), `run_all.sh` with telemetry diagnosis |
| `code/band2_project/` | band 2 project: spec (`README.md`), solution, acceptance `run.sh` |
| `code/solutions/` | exercises 1-3: `port_rates.c`, `poll_pps.sh`, `find_pool.gdb` + `find_pool.sh` |
| `code/run.sh` | builds and runs everything (about 60 s) |
| `code/expected_output.txt` | real output of `run.sh` on the course VM |

## How to run

```sh
source <path>/dpdk-env.sh        # PKG_CONFIG_PATH, DPDK_SRC, DPDK_PREFIX, PATH
cd code
make                              # gcc -Wall -Wextra, static libdpdk
sudo ./run.sh | tee my_output.txt # needs root (tap, hugepages, core dumps)
```

All runs use `--no-pci`, unique `--file-prefix=ch13-*` and `timeout`. Memory is
`--no-huge -m <=128`, except `dpdk-ethtool` (`-m 640`, its pool is sized from
the driver's descriptor limits) and the core-dump lab, which uses 32 MB of real
hugepages on purpose. Interfaces `ch13tap0..2` are created by `net_tap` and
removed on exit; the traps also remove runtime directories, hugepage files and
core files. Nothing needs real NIC hardware. `crash_postmortem.sh` expects
`/proc/sys/kernel/core_pattern` to be a plain file name (`core`); with
systemd-coredump use `coredumpctl` instead.

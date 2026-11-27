# Chapter 12: Port Control, Statistics, Events, Live Reconfiguration and Composite PMDs

Open `index.html` in a browser (works from `file://`, no network needed).

## What is here

| File | What it is |
|---|---|
| `index.html` | the chapter page; widgets in `ch12.js` |
| `code/ch12_common.h` | shared helpers: return-code names, port init, tap kernel-side injection, a tiny in-process telemetry client (reads `rxq_state`), xstat-by-name |
| `code/port_ctl.c` | optional-ops matrix on null/ring/tap; tap walk-through (MAC, promiscuous filter test with injected frames, MTU, link, ptypes, stats, all xstats, by-id lookup) |
| `code/events.c` | NEW / LSC / QUEUE_STATE / DESTROY callbacks and their threads; hotplug with `rte_dev_probe`/`rte_dev_remove`; pcap `eof=1` LSC; vhost + virtio_user; device event monitor |
| `code/rxtx_latency.c` | RX/TX burst callbacks, callback order, latency via an mbuf dynamic field, safe removal |
| `code/queue_ctl.c` | deferred start, queue start/stop, `rx_queue_is_valid`, runtime queue setup and `dev_capa` names on tap, pcap, null, ring, failsafe; stopped-queue behaviour with real traffic |
| `code/runtime_reconf.c` | "what needs a restart" table, restart outage (median of 5), ordered teardown with PASS/FAIL (`--sloppy` shows FAIL) |
| `code/bonding_modes.c` | bonding modes 0/1/2(L2,L23,L34)/3/5 over two tap members, failover, `rte_eth_dev_count_aggr_ports` |
| `code/failure_lab.c` | `--mode pool_dry|tx_full|link_flap|reset`: seeded faults, counter signatures, recovery |
| `code/solutions/lsc_poll.c` | exercise 1: link polling from an EAL alarm |
| `code/solutions/drain_restart.c` | exercise 6: drain/stop/restart one RX queue without leaks |
| `code/gen_pcap.py` | writes `tiny.pcap`, `in.pcap`, `big.pcap` |
| `code/run.sh` | builds and runs everything (about 25 s), including failsafe in testpmd |
| `code/expected_output.txt` | real output of `run.sh` on the course VM |

## How to run

```sh
source <path>/dpdk-env.sh        # PKG_CONFIG_PATH, DPDK_SRC, PATH for dpdk-testpmd
cd code
make                              # gcc -Wall -Wextra, static libdpdk
sudo ./run.sh | tee my_output.txt # needs root: tap interfaces, AF_PACKET, ip link
```

Every run uses `--no-pci --no-huge -m <=256`, a unique `--file-prefix=ch12-*`, and
`timeout -s INT`. Only virtual devices are used (`ch12tap*` tap interfaces, a
temporary `ch12a/ch12b` veth pair, a vhost socket in a temp dir). `run.sh` removes
them on exit and prints `leftover ch12 interfaces: 0`.

Nothing here needs real NIC hardware. Where real NICs behave differently (LSC
interrupts, `rte_eth_dev_reset`, hardware aggregated ports, PASSIVE/PROACTIVE
error handling) the page says so and the programs print the `-ENOTSUP` they get.

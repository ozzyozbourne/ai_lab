# Chapter 01: What Is a Packet, and Why Bypass the Kernel?

Open `index.html` in a browser (works from `file://`, no network needed).

## What is here

| Path | What |
|---|---|
| `index.html` | the chapter: frame anatomy, line-rate arithmetic, kernel receive path, DPDK's five techniques, poll vs interrupt, execution models, architecture map, history, ecosystem, alternatives |
| `code/hello_dpdk.c` | the smallest DPDK program: `rte_eal_init`, `rte_version`, `rte_lcore_count`, `rte_eth_dev_count_avail`, `rte_rdtsc`, `rte_eal_cleanup` |
| `code/bypass_bench.c` | peek ahead: UDP `sendto()+recv()` on loopback vs `rte_eth_rx_burst()+rte_eth_tx_burst()` on `net_null` (median of 5 runs); burst sizes after `--` |
| `code/intr_vs_poll.c` | peek ahead: busy polling vs Rx interrupts (`rte_epoll_wait`) on `net_tap`; CPU, wake-ups, latency |
| `code/inject.py` | writes timestamped raw frames into the tap interface |
| `code/run.sh` | builds and runs everything (about 50 s); output matches `code/expected_output.txt` in shape |
| `code/ivp_sweep.sh` | repeats intr_vs_poll 5x per (mode, rate); result in `code/ivp_sweep_output.txt` (feeds the chapter's widget) |
| `code/solutions/` | exercise answers (`ex1_budget.c` + output, `ex2_notes.md`, `ex3_answers.md`) |

## How to run

As root, with DPDK 26.11 installed and visible to `pkg-config`:

    cd code
    source ../../../common/env.sh     # or export DPDK_ENV=/path/to/your/env.sh
    make                               # gcc -Wall, static link via pkg-config libdpdk
    ./run.sh | tee my_output.txt       # creates and removes the tap ch01tap0 itself

All runs use virtual devices (`net_null`, `net_ring`, `net_tap`), `--no-pci`,
`--no-huge -m 64..128`, a unique `--file-prefix=ch01-*`, and `timeout`.
No physical NIC is touched.

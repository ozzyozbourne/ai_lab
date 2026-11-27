# Chapter 05: rte_ring: Lock-Free Queues Between Cores

Open `index.html` in a browser (works from `file://`, no network needed).

## What's here

| File | What it is |
|---|---|
| `index.html`, `ch05.js` | The chapter page and its four widgets (ring clock face, modulo-2^32 odometer, sync-mode Gantt with measured bars, bulk vs burst slider) |
| `code/ring_basics.c` | Create/lookup/free, count/free_count, bulk vs burst vs single-object calls, a producer lcore -> consumer lcore pipe |
| `code/ring_wrap.c` | Free-running 32-bit indexes, `index & mask`, crossing 2^32, capacity vs `RING_F_EXACT_SZ` |
| `code/ring_modes_bench.c` | Time-bounded SP/SC vs MP/MC vs RTS vs HTS benchmark (median of 5, min, max), producer/consumer or symmetric (`-- -s`) workload |
| `code/elem_peek.c` | HTS element ring of structs, peek (`*_start`/`*_finish`), zero-copy enqueue that wraps, two peeking consumers |
| `code/soring_demo.c` | Staged-ordered ring: out-of-order release, in-order delivery (experimental API) |
| `code/solutions/pipeline3.c` | Exercise 2: three-stage ring pipeline with order check |
| `code/Makefile` | Static pkg-config build; `ring_basics_spsc` target is exercise 1 |
| `code/run.sh` | Builds and runs everything (unique `--file-prefix=ch05-*`, `--no-huge -m 64 --no-pci`, `timeout`, cleanup trap) |
| `code/expected_output.txt` | Real output of `run.sh` on the course VM (4-core Xeon, shared, Linux 6.18, DPDK 26.11) |

## How to run

```sh
source <path>/dpdk-env.sh      # sets PKG_CONFIG_PATH for the installed DPDK 26.11
cd code
make                           # gcc -Wall -Wextra, static link
./run.sh 2>&1 | tee my_output.txt
```

No NIC, no hugepages and no root-only features are needed. The overcommit runs use
`--lcores='(0-3)@1'` (four lcores sharing CPU 1). Benchmark numbers come from a shared
VM and will differ on your machine; the shape of the results should not.

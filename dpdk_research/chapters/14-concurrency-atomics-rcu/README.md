# Chapter 14: Concurrency: Atomics, Memory Ordering, Locks and RCU

Open `index.html` in a browser (works from `file://`). Widgets live in
`chapter14.js`; the ABA widget is loaded from `../06-mempools/aba_widget.js`.

## Code (`code/`)

| File | What it shows |
|---|---|
| `litmus.c` | MP and SB litmus tests on two lcores (1M iterations each) + cost of each barrier |
| `litmus_mp.c` | compile-only: `make objdump` (x86-64 gcc) and `make objdump-arm` (clang AArch64) show compiler reordering, release = `stlr`, acquire = `ldar` |
| `locks_bench.c` | spinlock, ticketlock, MCS, rwlock, pflock, seqlock, pthread_mutex: cycles/op and fairness, 1-3 threads, median of 5 |
| `seqlock_cfg.c` | 64-byte config: torn reads without protection, none with rte_seqlock / rte_seqcount |
| `rcu_swap.c` | RCU QSBR pointer swap; modes `sync`, `broken`, `slow`, `offline` |
| `counters.c` | per-lcore counters: shared atomic, packed array, padded + RTE_CACHE_GUARD, lcore variable |
| `cas128.c` | the ABA history with a 64-bit CAS vs `rte_atomic128_cmp_exchange` |
| `thread_safety/counter_ts.c` | clang `-Wthread-safety` static lock check (`make thread_safety`, compile only) |
| `solutions/port_26_11.c` | exercise 1: removed atomics/barriers ported to 26.11 (incl. a doorbell) |
| `solutions/rcu_dq.c` | exercise 2: RCU defer queue vs synchronize |

## Run

```sh
source /tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh
cd code && ./run.sh            # ~16 s; builds and runs everything
./run.sh 2>&1 | tee expected_output.txt   # refresh the captured output
```

All runs use `--no-pci --no-huge -m 64`, `-l 0-3` (or fewer), unique
`--file-prefix=ch14-*` and `timeout`. No devices, veths or hugepages are used.
Benchmarks come from a shared 4-vCPU VM; numbers vary between runs. The AArch64
listing is compiled only (no Arm hardware here); Arm outcomes in the page are
labelled "model only".

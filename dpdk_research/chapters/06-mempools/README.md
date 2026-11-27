# Chapter 06: rte_mempool and rte_stack

Open `index.html` in a browser (works from `file://`). Widgets live in
`chapter06.js` (cache trace, two-lcore ring traffic, pool memory map, sizing
calculator) and `aba_widget.js` (the lock-free stack ABA step-through; ch14
embeds it with `Ch06ABA.mount('#id')`).

## Code (`code/`)

| Program | Shows |
|---|---|
| `mempool_basics.c` | create, obj_init, layout, get/put, bulk all-or-nothing, footprint on 4 KB vs 2 MB pages, dump |
| `cache_explorer.c` | 26.11 cache trace, cache_size limits, user cache for a non-EAL pthread, cache 0/256/1024 timing |
| `handler_bakeoff.c` | ring/stack/lf_stack/pile/bucket handlers: cost and reuse order |
| `stranded_cache.c` | objects stranded in other lcores' caches; flush and sizing fixes |
| `custom_ops.c` | a handler of your own with `RTE_MEMPOOL_REGISTER_OPS` |
| `stack_demo.c` | rte_stack std / LF / pile: order, pile bound, throughput |
| `solutions/pool_sizing.c` | exercise 1 |
| `solutions/bakeoff_mp.c` | exercise 2 (multi-lcore bakeoff) |

Run everything (needs the DPDK env script; edit `ENV_SH` in `run.sh` if it
lives elsewhere):

    cd code && ./run.sh            # builds with make, runs each program bounded
    ./run.sh > expected_output.txt # refresh the captured output

All runs use `--no-pci --no-huge` and `--file-prefix=ch06-*`, except one
`mempool_basics` run with `-m 64` of 2 MB hugepages. Cycle counts come from a
shared 4-core VM; treat them as ratios. `expected_output.txt` is real output.

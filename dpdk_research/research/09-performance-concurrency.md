# Research Note 09: Performance and Concurrency in DPDK (26.11)

Area: cache lines, burst sizes, vector PMD paths, prefetch, branch hints, batching, lock-free design,
C11 atomics (rte_atomic is gone in 26.11), locks (spinlock/rwlock/ticketlock/MCS/pflock/seqlock),
RCU (rte_rcu_qsbr), memory ordering, lcore variables, NUMA, isolcpus/nohz_full, power management,
measurement (rte_rdtsc, rte_pmu, telemetry, perf), benchmarking methodology, and performance traps.

All paths are relative to `$DPDK_SRC` (DPDK 26.11.0 tree). Everything marked **[VERIFIED]** was run on
this machine (4-vCPU Xeon (Sapphire Rapids-class, model 173) KVM guest, TSC 2.7 GHz, AVX-512, 1 NUMA node,
no cpufreq, no WAITPKG, no `perf` binary, `perf_event_paranoid=2`). Verified sources are in
`research/09-examples/` (`bench.c`, `rcu.c`).

---

## 0. TL;DR for the course planner

1. The **26.11 release removed** the legacy `rte_atomicNN_t` types and `rte_atomicNN_*()` functions as well as
   `rte_smp_mb/rmb/wmb()` (`doc/guides/rel_notes/release_26_11.rst` ~line 351). A course on 26.11 must teach
   **only** `RTE_ATOMIC(T)` + `rte_atomic_*_explicit()` + `rte_memory_order_*` + `rte_atomic_thread_fence()`.
   Older tutorials and blog posts (and much of the internet) still use `rte_atomic32_inc`. Show a migration table.
2. Measured on this VM with testpmd + `net_null` (io fwd, 1 core): **burst 1 = 7.4 Mpps, 127 cyc/pkt;
   burst 4 = 24.7 Mpps, 42 cyc/pkt; burst 32 = 49.0 Mpps, 25.9 cyc/pkt; burst 128 = 43.8 Mpps, 30.2 cyc/pkt**.
   This makes a great first "why batching" chart.
3. The vector path is visible with virtio_user (packed ring) + vhost:
   `--force-max-simd-bitwidth=128` logs "disabled packed ring vectorized path", and 512 logs "using packed ring
   vectorized Rx/Tx path". The vhost sink then received **18.0 Mpps (scalar) vs 23.4 Mpps (AVX-512)**.
4. False sharing (atomic increment on adjacent per-lcore counters, 3 lcores): **~210 cycles/op packed vs
   12.7 cycles/op padded** (about 17x). One shared atomic counter: about 450 cyc/op. Contended spinlock
   about 1600, ticketlock about 1970, MCS about 3970 cyc/op (the VM penalises fair hand-off). Uncontended costs
   are spinlock 29, ticketlock 18, MCS 36 cyc/op.
5. RCU QSBR (3 readers in a tight loop, writer calling `rte_rcu_qsbr_synchronize`): **average grace period about
   1300 cycles (0.48 µs)**, with no use-after-free.
6. A noisy neighbour (a busy loop pinned to the forwarding CPU) **halved throughput (49 to 24.5 Mpps)**, and the
   reported "cycles/packet" doubled. This shows that TSC-based busy-cycle accounting counts preempted time.
   It is the motivation for isolcpus.
7. `l3fwd-power --pmd-mgmt=pause --max-empty-polls=64` on an idle `net_ring0` dropped worker CPU from about 100%
   to about 27% (VM artefact: no WAITPKG, so a `rte_pause()` loop is used, and KVM pause-loop-exiting
   deschedules the vCPU). Treat it as a demo of the mechanism, not of real power savings.

Suggested chapter split (this area is big enough for 3 chapters):
- **Chapter A, "Thinking in cycles": the CPU model, cache lines, batching, prefetch, branch hints, vector PMDs,
  measuring with rdtsc/telemetry.**
- **Chapter B, "Concurrency without tears": atomics and memory order, locks zoo, lock-free ring/stack,
  RCU QSBR, lcore variables.**
- **Chapter C, "Production tuning": NUMA, isolcpus/nohz_full/irq affinity, power management, perf/PMU,
  benchmarking methodology, the traps catalogue.**

---

## 1. Teaching order (easy to hard)

| # | Topic | Why at this position |
|---|-------|----------------------|
| 1 | Cycle budget arithmetic (10G/40G/100G at 64B means 14.88/59.5/148.8 Mpps; at 2.7 GHz the budget is 181/45/18 cycles per packet) | Motivates everything |
| 2 | Measuring: `rte_rdtsc`, `rte_get_tsc_hz`, `rte_rdtsc_precise`, testpmd `--record-core-cycles` | Students need a ruler before optimising |
| 3 | Run-to-completion poll loop and why polling (no interrupts, no syscalls) | Context |
| 4 | Batching / burst size (`rte_eth_rx_burst` nb_pkts, ring bulk/burst, mempool cache) | Biggest, easiest win |
| 5 | Cache lines: `RTE_CACHE_LINE_SIZE`, `__rte_cache_aligned`, `alignas`, `RTE_CACHE_GUARD`, false sharing, mbuf layout (2 cache lines) | Visual and intuitive |
| 6 | Prefetch: `rte_prefetch0/1/2/_non_temporal`, `rte_prefetch0_write`, `rte_cldemote`; the prefetch-ahead pattern from l3fwd | Builds on 5 |
| 7 | Branch hints: `likely/unlikely`, `__rte_hot/__rte_cold`, `__rte_always_inline`, `__rte_noinline` | Small, concrete |
| 8 | SIMD and vector PMDs: `rte_vect.h`, `--force-max-simd-bitwidth`, `rte_vect_get_max_simd_bitwidth`, path selection (`ci_rx_path_select`) and constraints | Builds on 4 and 5 |
| 9 | Atomics and memory ordering: `rte_stdatomic.h`, acquire/release, x86 TSO vs Arm weak, `rte_atomic_thread_fence`, `rte_io_*mb` | Foundation for 10 to 13 |
| 10 | Locks: spinlock to ticketlock to MCS to rwlock to pflock to seqcount/seqlock, plus recursive variants, `rte_wait_until_equal_*`, lock annotations | Increasing sophistication |
| 11 | Lock-free structures: rte_ring (MP/MC CAS, RTS, HTS, SP/SC), rte_stack LF and the new "pile", ABA, 128-bit CAS (`rte_atomic128_cmp_exchange`) | Uses 9 |
| 12 | RCU QSBR: quiescent state, grace period, token protocol, defer queue, integration with hash/LPM/FIB | Hardest concurrency concept |
| 13 | Per-lcore data: `RTE_LCORE_VAR*` (24.11+), `RTE_PER_LCORE` TLS, why not arrays | Alternative to sharing |
| 14 | NUMA: `rte_socket_id`, `rte_eth_dev_socket_id`, `rte_lcore_to_socket_id`, the new `rte_cpu_socket_id` (26.11), `--socket-mem`, socket-aware mempools | Topology |
| 15 | OS isolation: isolcpus, nohz_full, rcu_nocbs, irqaffinity, `-l/--lcores` mapping, service cores, why never 2 lcores per CPU | Production |
| 16 | Power: rte_power cpufreq, PMD power management (monitor/pause/scale), `rte_power_monitor` (UMWAIT), `rte_power_pause` (TPAUSE), PM QoS, uncore, l3fwd-power | Trade-off: latency vs Watts |
| 17 | Profiling: telemetry (`/eal/lcore/usage`), `rte_lcore_register_usage_cb`, perf, `rte_pmu` (25.07+), VTune, trace | Diagnose |
| 18 | Benchmarking methodology and the traps catalogue | Capstone |

---

## 2. Concepts in depth

### 2.1 The cycle budget and the poll-mode model
- Line rate at 64B frames: 64 + 20 bytes (preamble/IFG) = 84 bytes = 672 bits. 10GbE gives 14.88 Mpps, 25G 37.2,
  40G 59.5, 100G 148.8 Mpps. Budget = core_Hz / pps. On this VM (2.7 GHz) one core at 49 Mpps spends
  about 26 cycles per packet *for io forwarding with no packet touch*.
- Reference costs to show in a "latency ladder" graphic (typical Intel server, order of magnitude):
  L1 hit about 4-5 cycles, L2 about 14, LLC about 40-70, DRAM about 200-300+, remote NUMA DRAM about 1.5-2x;
  branch mispredict about 15-20; atomic RMW on a line owned by another core about 100-500 (measured here: about 450);
  syscall more than 100 ns; context switch in the µs range. Measured here: `rte_rdtsc()` about 32 cycles per call
  in a loop (VM), `rte_rdtsc_precise()` about 62 cycles.
- Doc: `doc/guides/prog_guide/perf_opt_guidelines.rst` (short; points to writing_efficient_code), and
  `doc/guides/prog_guide/writing_efficient_code.rst` (memory, NUMA, PMD batching, `rte_memcpy`,
  locks, "use burst of packets", "avoid partial writes to cache lines").

### 2.2 Measuring time: rte_cycles
- `lib/eal/include/generic/rte_cycles.h`, `lib/eal/x86/include/rte_cycles.h`.
- `rte_rdtsc()` is `__rdtsc()` (with an optional VMware `rdpmc 0x10000` path under
  `RTE_LIBRTE_EAL_VMWARE_TSC_MAP_SUPPORT`). It is **not serialising**: out-of-order execution can move it.
  `rte_rdtsc_precise()` adds `rte_mb()` (mfence) first.
  `rte_get_tsc_cycles()`, `rte_get_tsc_hz()`, `rte_get_timer_cycles()/hz()`, `rte_delay_us/ms()`,
  `rte_delay_us_block()`, `rte_delay_us_sleep()`, `rte_delay_us_callback_register()`.
- The TSC is invariant on modern x86 (`constant_tsc nonstop_tsc tsc_known_freq` flags present here), so it
  counts wall-clock ticks, **not** core clock cycles. With turbo or frequency scaling, "cycles" from the TSC differ
  from core cycles (teach this explicitly; it is a common trap). On Arm, `cntvct_el0` runs at a low frequency
  unless `RTE_ARM_EAL_RDTSC_USE_PMU` is set (`doc/guides/prog_guide/profile_app.rst`).
- Measurement pattern: amortise (time N iterations and divide), subtract the empty-loop overhead, take the
  min/median of several runs, and use `rte_compiler_barrier()` / `asm volatile("" ::: "memory")` to keep the
  compiler from moving code across the timestamps.
- testpmd `--record-core-cycles` prints "CPU cycles/packet=... busy cycles / total io packets";
  `--record-burst-stats` prints the burst size histogram ("RX-bursts : N [0% of 0 pkts + 100% of 32 pkts]").
- `examples/rxtx_callbacks` stamps the RX time in an rx callback (`rte_eth_add_rx_callback`) and computes
  latency in a tx callback using `rte_rdtsc()`. **[VERIFIED]** `stdbuf -oL dpdk-rxtx_callbacks -l 0 --no-huge -m 256
  --no-pci --file-prefix=ch09cb --vdev=net_null0 --vdev=net_null1` prints "Latency = 248 cycles"
  (use `stdbuf -oL`, otherwise the printf buffer is lost on SIGINT).

### 2.3 Batching and burst size
- APIs: `rte_eth_rx_burst/tx_burst(port, q, pkts, nb)`, `rte_ring_enqueue_burst/bulk` (bulk means all or nothing,
  burst means as many as possible), `rte_mempool_get_bulk/put_bulk` with the per-lcore cache
  (`rte_mempool_create(... cache_size ...)`, `RTE_MEMPOOL_CACHE_MAX_SIZE` 512), `rte_pktmbuf_free_bulk`,
  `rte_eth_tx_buffer` (`rte_eth_tx_buffer_init/flush`, used by l2fwd), the testpmd `--burst`, `--rxfreet`,
  `--txfreet` and `--txrst` options.
- Why it works: it amortises per-call overhead (function pointer call via `rte_eth_fp_ops`, queue
  pointer loads, doorbell/tail MMIO write once per burst, descriptor ring cache-line reads of 4 descriptors per
  64B line), allows prefetch of packet N+k while processing N, and lets SIMD process 4/8 descriptors at once.
- Driver constants: `drivers/net/intel/common/rx.h`: `CI_RX_MAX_BURST 32`, `CI_VPMD_DESCS_PER_LOOP 4`,
  `CI_VPMD_DESCS_PER_LOOP_WIDE 8` (AVX2/512), `CI_VPMD_RX_REARM_THRESH`. Vector RX requires nb_pkts >= 4
  (descs per loop) and typically floors the request to a multiple of 4/8. This is a trap when an app asks for 1.
- Too big a burst: working set exceeds L1 (32 mbuf pointers plus 32 x 2 mbuf cache lines is about 4 KB), latency
  rises, and per-burst fairness drops. **[VERIFIED]** burst 128 was slower than 32 (43.8 vs 49.0 Mpps).
- **[VERIFIED experiment, ch09 burst sweep]**:
  ```
  for b in 1 4 8 16 32 64 128; do
    timeout -s INT -k 5 8 $DPDK_SRC/build/app/dpdk-testpmd -l 0-1 --no-huge -m 256 --no-pci \
      --file-prefix=ch09b$b --vdev=net_null0,copy=0 --vdev=net_null1,copy=0 -- \
      --total-num-mbufs=8192 --forward-mode=io --burst=$b --stats-period=3 \
      --record-core-cycles --record-burst-stats > tp_b$b.log 2>&1
    grep Rx-pps tp_b$b.log | tail -1; grep cycles/packet tp_b$b.log
  done
  ```
  NOTE: without `--total-num-mbufs` testpmd tries to allocate 155456 mbufs and fails with `-m 256`
  ("Creation of mbuf pool for socket 0 failed"). net_null option `copy=0` avoids memcpy; `copy=1` adds
  the data-touch cost, which is a good second curve.
  Results: b=1: 7.39 Mpps / 126.6 cyc; b=4: 24.7 / 41.8; b=32: 49.0 / 25.9; b=128: 43.8 / 30.2.

### 2.4 Cache lines, alignment, false sharing
- `lib/eal/include/rte_common.h`: `RTE_CACHE_LINE_SIZE` (64 on x86, 128 on some Arm, set via meson
  `RTE_CACHE_LINE_SIZE`), `RTE_CACHE_LINE_MIN_SIZE 64`, `RTE_CACHE_LINE_ROUNDUP()`, `__rte_cache_aligned`,
  `__rte_cache_min_aligned`, `__rte_aligned(a)`. Modern DPDK style uses C11 `alignas(RTE_CACHE_LINE_SIZE)`
  on the first member, or `struct __rte_cache_aligned name {` (the attribute goes **before** the struct name for
  MSVC portability; see `struct __rte_cache_aligned rte_rcu_qsbr_cnt` in `lib/rcu/rte_rcu_qsbr.h`).
- `RTE_CACHE_GUARD` (`rte_common.h` ~944): `alignas(RTE_CACHE_LINE_SIZE) char cache_guard_N[RTE_CACHE_LINE_SIZE *
  RTE_CACHE_GUARD_LINES]`, with `RTE_CACHE_GUARD_LINES` = 1 in `config/rte_config.h`. It guards against the
  adjacent-line ("spatial") prefetcher, which pulls the buddy line of a 128B pair, so that 64B padding alone can
  still false-share. `struct rte_ring` uses it between prod and cons headtails (`lib/ring/rte_ring_core.h`).
- mbuf: `struct rte_mbuf` is 2 cache lines (`lib/mbuf/rte_mbuf_core.h`). RX fast-path fields are in
  line 0 (`buf_addr`, `data_off`, `refcnt`, `nb_segs`, `port`, `ol_flags`, `packet_type`, `pkt_len`,
  `data_len`, `vlan_tci`, `hash`) and line 1 (marked `alignas(RTE_CACHE_LINE_MIN_SIZE)`, the `cacheline1` section)
  has `next`, `pool`, `tx_offload`, etc. There is `RTE_BUILD_BUG_ON` / `static_assert` on offsets. The 128-byte
  headroom `RTE_PKTMBUF_HEADROOM` sits between the mbuf and the packet data.
- MESI/MOESI picture: writing a line in another core's cache means an RFO and an invalidation, so the line bounces.
- **[VERIFIED]** `bench.c` modes 0/1 (3 worker lcores, 2M ops each, `__atomic_fetch_add` relaxed on a per-lcore
  slot): packed `uint64_t[]` gives 194-220 cyc/op, padded (`alignas(64)` + `RTE_CACHE_GUARD`) gives 12.7 cyc/op.
  **Pedagogical trap found**: with plain `volatile` increments the false-sharing effect was *invisible*
  (1.57 vs 1.43 cyc/op) because the store buffer and store-to-load forwarding hide it in a tight loop. Use atomic
  RMW (or a real mixed workload) to demonstrate. This is good material for "how microbenchmarks lie".
- Other alignment helpers: `RTE_ALIGN_CEIL/FLOOR`, `rte_is_aligned`, `RTE_PTR_ALIGN`, `rte_zmalloc(..., align)`,
  `rte_malloc_socket`.

### 2.5 Prefetching
- `lib/eal/x86/include/rte_prefetch.h`: `rte_prefetch0` (prefetcht0, all levels), `rte_prefetch1` (t1, L2+),
  `rte_prefetch2` (t2, LLC), `rte_prefetch_non_temporal` (prefetchnta), `rte_prefetch0_write/1_write/2_write`
  (`__builtin_prefetch(p, 1, ...)`, i.e. prefetchw), and the experimental `rte_cldemote` (CLDEMOTE pushes a line
  from L1/L2 to LLC so another core, e.g. a consumer, gets it faster; this CPU has `cldemote`).
- Pattern from `examples/l3fwd/l3fwd_lpm.h` / `l3fwd_em.c` and l2fwd: `#define PREFETCH_OFFSET 3`; prefetch
  `rte_pktmbuf_mtod(pkts[j], void*)` for the first 3 packets, then in the loop prefetch packet j+3 while
  processing j, then finish the tail. In drivers: rx descriptor rings, `rte_mbuf_prefetch_part1/part2()`
  (`rte_mbuf.h`).
- Pitfalls: a prefetch that is too late is useless and one that is too early gets evicted; prefetching NULL or
  invalid addresses is harmless architecturally but wastes slots; hardware prefetchers already handle
  sequential streams; there are a limited number of line fill buffers (about 10-16 outstanding misses per core);
  measure before keeping a prefetch.
- Demo on this machine: a pointer-chasing / random-index array benchmark over 64 MB (bigger than L2 8 MB, within the
  480 MB LLC reported by the VM) with and without `rte_prefetch0(&a[idx[i+D]])` for D in {0, 2, 4, 8, 16, 32}.
  Plot cycles per element vs prefetch distance (U-shaped curve).

### 2.6 Branch prediction and code layout
- `lib/eal/include/rte_branch_prediction.h`: `likely(x)` = `__builtin_expect(!!(x),1)`, `unlikely(x)`.
  These are layout hints: they let the compiler put the hot path fall-through and move cold blocks away. They do
  **not** program the CPU predictor (x86 has no hint prefixes honoured since P4).
- `rte_common.h`: `__rte_hot` (attribute hot, placed in .text.hot), `__rte_cold`, `__rte_always_inline`,
  `__rte_noinline`, `__rte_unused`, `__rte_restrict`, `RTE_BUILD_BUG_ON`, `__rte_assume` (where present).
- Good examples: `if (unlikely(nb_rx == 0)) continue;` in every fwd loop; error paths in `rte_eth_rx_burst`
  under `RTE_ETHDEV_DEBUG_RX`; `rte_mcslock_unlock` uses `likely(next == NULL)`.
- Branchless tricks: mask arithmetic in vector PMDs, lookup tables (ptype tables in vector PMDs),
  `rte_bit_*`.
- Demo: classify random vs sorted packets (the classic "sorted array" effect) and an `unlikely()` on/off
  comparison with `objdump -d` showing block layout. The compiled-code diff is more convincing than timing.

### 2.7 SIMD and vector PMD paths
- `lib/eal/include/generic/rte_vect.h`: `enum rte_vect_max_simd { RTE_VECT_SIMD_DISABLED=64, _128, _256, _512,
  _MAX }`, `rte_vect_get_max_simd_bitwidth()`, `rte_vect_set_max_simd_bitwidth()`; EAL option
  `--force-max-simd-bitwidth=<64|128|256|512>`. The default on x86 is 256 unless the CPU/build allow 512
  (AVX-512 frequency licences historically made 256 the default).
- Runtime CPU flags: `rte_cpu_get_flag_enabled(RTE_CPUFLAG_AVX512F)` (`rte_cpuflags.h`). The build compiles
  AVX2/AVX512 variants with per-file `-mavx512f` etc. (look at `drivers/net/intel/*/meson.build`,
  `cc_avx512_flags`) and selects them at runtime, so one binary runs everywhere.
- Intel common path selection (26.x refactor): `drivers/net/intel/common/rx.h` has `struct ci_rx_path_features
  {rx_offloads, simd_width, scattered, flex_desc, bulk_alloc, disabled, single_queue}`, `struct ci_rx_path_info
  {pkt_burst, info, features}`, and `ci_rx_path_select()`, which picks the path that supports all requested
  offloads with the widest allowed SIMD. i40e: `i40e_rxtx.c` (`req_features.simd_width =
  rte_vect_get_max_simd_bitwidth()`), `i40e_rxtx_vec_sse.c/avx2.c/avx512.c`; shared x86 helpers
  `common/rx_vec_x86.h`, `common/tx_vec_x86.h` (26.11 added Tx context-descriptor support in AVX2/AVX512 Tx).
- Constraints (doc `doc/guides/nics/ixgbe.rst` "Vector PMD for IXGBE", i40e.rst, ice.rst): rx free threshold
  and ring size conditions, no scatter (or a separate scattered vector path), limited offloads (e.g. no IEEE1588,
  certain checksum/VLAN combos), Tx fast-free (`RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE`, which requires a single
  mempool and refcnt 1).
- Discover the chosen path: `rte_eth_rx_burst_mode_get()` / `rte_eth_tx_burst_mode_get()`; testpmd
  `show rxq info 0 0` prints "Burst mode: Vector AVX512" etc.; driver logs at debug level.
- **[VERIFIED experiment, vector virtio]** (vhost-user needs hugepages and at most 8 memory regions, so use
  `--single-file-segments` on the virtio_user side, otherwise vhost silently receives nothing):
  ```
  W=<scratch>; rm -f $W/ch09.sock
  timeout -s INT -k 5 14 dpdk-testpmd -l 0-1 -m 64 --no-pci --file-prefix=ch09vh \
     --vdev "net_vhost0,iface=$W/ch09.sock,queues=1" -- --total-num-mbufs=8192 \
     --forward-mode=rxonly --auto-start --stats-period=4 > vh.log 2>&1 &
  sleep 2
  timeout -s INT -k 5 10 dpdk-testpmd -l 2-3 -m 64 --single-file-segments --no-pci --file-prefix=ch09vu \
     --force-max-simd-bitwidth=512 --log-level=pmd.net.virtio.*:debug \
     --vdev "virtio_user0,path=$W/ch09.sock,queues=1,packed_vq=1,vectorized=1,in_order=1,mrg_rxbuf=0" -- \
     --total-num-mbufs=8192 --forward-mode=txonly --auto-start --stats-period=4 --record-core-cycles > vu.log 2>&1
  ```
  With 128: log "disabled packed ring vectorized path for requirements not met", vhost Rx about 18.0 Mpps,
  virtio Tx 148 cyc/pkt. With 512: "using packed ring vectorized Rx path / Tx path", about 23.4 Mpps, 114 cyc/pkt.
  Source: `drivers/net/virtio/virtio_rxtx_packed_avx.h`, `virtio_rxtx_packed.c`, `virtio_ethdev.c`
  (`set_rxtx_funcs`, vectorized checks need AVX512F + `in_order` + no `mrg_rxbuf` for packed ring).
  The split ring vector path (`virtio_rxtx_simple_sse.c`) needs `vectorized=1, packed_vq=0, in_order=0?,
  mrg_rxbuf=0` and offloads off; check the logs.
- Visualisation: four 16B descriptors loaded into one 512-bit register, a shuffle mask converting the descriptor
  layout to the mbuf `rearm_data`/`rx_descriptor_fields1` layout, and a store of 4 mbuf headers at once
  (animate the lanes).

### 2.8 Memory ordering and atomics (C11 only in 26.11)
- `lib/eal/include/rte_stdatomic.h`: `RTE_ATOMIC(type)` (`_Atomic(type)` when built with `-Denable_stdatomic=true`,
  plain `type` otherwise so that the GCC `__atomic_*` builtins are used), `__rte_atomic` qualifier,
  `rte_memory_order_{relaxed,consume,acquire,release,acq_rel,seq_cst}`, `rte_atomic_load_explicit`,
  `_store_`, `_exchange_`, `_compare_exchange_strong/weak_`, `_fetch_add/sub/and/or/xor/nand_`,
  `rte_atomic_flag_test_and_set/clear_explicit`. The build option is `enable_stdatomic`
  (`config/meson.build`: `RTE_ENABLE_STDATOMIC`); `RTE_USE_C11_MEM_MODEL` defaults true.
- **Removed in 26.11** (`release_26_11.rst`): `rte_atomic16/32/64_t` and `rte_atomicNN_{init,read,set,add,sub,inc,
  dec,add_return,sub_return,inc_and_test,dec_and_test,test_and_set,clear,cmpset,exchange}`;
  `rte_smp_mb()` becomes `rte_atomic_thread_fence(rte_memory_order_seq_cst)`, `rte_smp_rmb()` becomes `..._acquire`,
  `rte_smp_wmb()` becomes `..._release`; device barriers use `rte_io_wmb()/rte_io_rmb()`/`rte_io_mb()`.
  Remaining: `rte_mb/rte_wmb/rte_rmb` (x86: mfence/sfence/lfence), `rte_compiler_barrier()`,
  `rte_atomic128_cmp_exchange()` (`generic/rte_atomic.h`, cmpxchg16b), and `rte_cio_*` (gone earlier).
  History: proposal to deprecate in 2020 (Phil Yang / Honnappa Nagarahalli, Arm); the 21.05 deprecation notice
  promised C11 semantics; 23.11 added `rte_stdatomic.h` and the `enable_stdatomic` option; 2026 series
  (Stephen Hemminger, "deprecate rte_atomicNN family") converted callers and 26.11 removed them.
- x86 specifics (`lib/eal/x86/include/rte_atomic.h` comment quoting Intel SDM 8.2.2): x86 is TSO, so only
  store-to-load reordering is visible. Acquire/release are compiler barriers only; seq_cst fence is needed for
  store then load patterns (Dekker/Peterson). DPDK's `rte_atomic_thread_fence(seq_cst)` uses
  `lock addl $0,-128(%rsp)` instead of `mfence` (cheaper; reference: Shipilev "On the fence with dependencies").
  `rte_io_wmb/rmb` are compiler barriers on x86 (MMIO is uncached/strongly ordered), but on Arm they are `dmb oshst`
  etc. **Teaching point: code that "works" on x86 with relaxed ordering breaks on Arm**. Show the
  message-passing litmus test (data=42; flag=1 / while(!flag); assert(data==42)).
- Which ordering where (canonical DPDK examples):
  - ring: producer writes objects, then `rte_atomic_store_explicit(&r->prod.tail, new, release)`; consumer
    loads `prod.tail` acquire (`lib/ring/rte_ring_c11_pvt.h`, `__rte_ring_update_tail`, `__rte_ring_move_prod_head`).
  - spinlock: CAS acquire to lock, store release to unlock (`generic/rte_spinlock.h`).
  - statistics counters: relaxed fetch_add or, better, a per-lcore counter with a plain store plus a relaxed load by the reader.
  - mbuf refcnt: `rte_mbuf_refcnt_update` uses acq_rel fetch_add.
- `rte_wait_until_equal_16/32/64(addr, expected, memorder)` (`generic/rte_pause.h`) and `RTE_WAIT_UNTIL_MASKED`:
  spins with `rte_pause()` on x86 and uses WFE on Arm when `RTE_ARM_USE_WFE` (`lib/eal/arm/include/rte_pause_64.h`),
  which saves power and bus traffic.
- `rte_pause()` = x86 `pause` instruction (about 140 cycles on Skylake+, versus about 10 before). It reduces power and
  pipeline flushes in spin loops and yields to the SMT sibling. Under a hypervisor, PAUSE loops trigger
  Pause-Loop Exiting (relevant to the power demo below).
- Bit ops: `rte_bitops.h` (24.11): `rte_bit_test/set/clear/assign/flip` (non-atomic, no ordering) and
  `rte_bit_atomic_*` with a memory order argument.

### 2.9 The locks zoo (all in `lib/eal/include/`)
| Lock | File | Mechanism | Fair? | Notes |
|------|------|-----------|-------|-------|
| `rte_spinlock_t` | `generic/rte_spinlock.h`, `x86/include/rte_spinlock.h` | x86 asm: `xchg` then spin on `cmpl` with `pause` (test-and-test-and-set). Generic (`RTE_FORCE_INTRINSICS`): CAS acquire + `rte_wait_until_equal_32` | No | `trylock`, `is_locked`, `_tm` variants use Intel RTM (lock elision via `rte_try_tm`; RTM is absent on this VM so it falls back), `rte_spinlock_recursive_t` (owner = `rte_gettid()`) |
| `rte_ticketlock_t` | `rte_ticketlock.h` | union {uint32 tickets; {uint16 current, next}}: fetch_add next, wait until current==me (acquire); unlock stores current+1 release | FIFO | All waiters spin on the same line; recursive variant |
| `rte_mcslock_t` | `rte_mcslock.h` | Queue of per-thread nodes: `exchange(tail, me, acq_rel)`, link `prev->next = me` (release), spin on **own** `me->locked`. Unlock: if no successor, CAS tail to NULL, else wait for the link and hand off | FIFO | Local spinning gives O(1) remote traffic per handoff; caller supplies the `rte_mcslock_t me` node (often on the stack). Added in 19.08 |
| `rte_rwlock_t` | `generic/rte_rwlock.h` | int32 cnt: bit0 WAIT, bit1 WRITE, readers add 4. Writer sets WAIT to block new readers (writer preference since 22.x) | Writer-preferring | `read_trylock`, `write_trylock`, `write_is_locked`, `_tm` variants |
| `rte_pflock_t` | `rte_pflock.h` | Phase-fair rw lock (Brandenburg & Anderson): two ticket pools rd{in,out}, wr{in,out}; reader and writer phases alternate | Phase-fair | Added in 21.05; bounded reader latency |
| `rte_seqcount_t` | `rte_seqcount.h` | Sequence number: writer makes sn odd (relaxed store, then release fence), writes, makes sn even (release); reader: begin = acquire load (spin while odd), read copy, `read_retry` compares | Readers never block writers | Single writer only (or external serialisation) |
| `rte_seqlock_t` | `rte_seqlock.h` | seqcount + spinlock to serialise multiple writers | | Added in 22.07; ideal for "config snapshot read by data plane" |
- Lock annotations (23.03+): `rte_lock_annotations.h` with `__rte_capability`, `__rte_acquire_capability`,
  `__rte_guarded_by`, `__rte_requires_capability`; enabled with clang `-Wthread-safety` via the meson
  `annotate_locks` option in a library's meson.build. Doc `doc/guides/prog_guide/thread_safety.rst` covers which
  DPDK APIs are thread-safe (ethdev queue ops are not MT-safe per queue, etc.).
- **[VERIFIED]** `bench.c` (3 contending lcores / 1 lcore, `-l 0-3 --no-huge -m 64 --no-pci`):
  contended: spinlock about 1550-1640, ticketlock about 1970, MCS about 3970 cyc/op; shared relaxed atomic add
  about 435-468; uncontended (1 worker): spinlock 29, ticketlock 18, MCS 36, atomic add 12.7.
  Explain: in a VM with 4 vCPUs, fair locks suffer "lock-waiter preemption" (the next ticket holder's vCPU may not
  be running), and the critical section is tiny, so the hand-off cost dominates. On bare metal with many cores
  MCS scales better than ticket/spin. Teach "the benchmark result depends on the platform; measure *your* case".
  Also: the best lock is no lock (per-lcore counters at 12.7 cycles with no sharing at all; plain store per lcore
  would be about 1 cycle).

### 2.10 Lock-free data structures
- `rte_ring` (`lib/ring/`, `doc/guides/prog_guide/ring_lib.rst`): fixed-size power-of-2 array; `prod` and `cons`
  headtails `{head, tail}` on separate cache lines with `RTE_CACHE_GUARD`. MP enqueue: CAS on prod.head to reserve
  n slots, copy objects, wait until prod.tail == old head (ordering between producers), store tail release.
  Sync modes `enum rte_ring_sync_type`: `RTE_RING_SYNC_MT`, `RTE_RING_SYNC_ST`, `RTE_RING_SYNC_MT_RTS` (Relaxed
  Tail Sync: head/tail counters with a ref count, avoiding the in-order tail wait; good with preemptible threads /
  overcommitted VMs), `RTE_RING_SYNC_MT_HTS` (Head/Tail Sync: serialised, which enables the peek API
  `rte_ring_enqueue_bulk_start/finish`, `rte_ring_dequeue_burst_start/finish`). Flags `RING_F_SP_ENQ`,
  `RING_F_SC_DEQ`, `RING_F_MP_RTS_ENQ`, `RING_F_MC_HTS_DEQ`, `RING_F_EXACT_SZ`. `rte_ring_elem.h` for non-pointer
  elements. Zero-copy API `rte_ring_enqueue_zc_burst_start`. It is "lock-free" but not wait-free: the MP tail
  wait means a preempted producer stalls the others (lock-waiter preemption again, which motivates RTS/HTS).
- `rte_stack` (`lib/stack/`): std (spinlock), LF (`RTE_STACK_F_LF`, linked list using 128-bit CAS
  `rte_atomic128_cmp_exchange` with a counter to defeat **ABA**), and the **new 26.11 "pile"**
  (`rte_stack_pile.c/.h`): lock-free, LIFO only at bulk granularity, optimised for bulk ops, not strictly
  bounded; there is also a pile mempool driver.
- Mempool per-lcore cache (`struct rte_mempool_cache`, `lib/mempool/rte_mempool.h`) is the main reason
  mbuf alloc/free is cheap: each lcore takes from its private cache and the shared ring is touched in batches.
  26.11 removed the obsolete `flushthresh` field and added `sizeof_cache_per_lcore`. Non-EAL threads (no lcore
  id) get no cache unless they use `rte_mempool_cache_create` and the `_generic_` APIs, which is a performance trap.
- Lock-free elsewhere: `rte_hash` with `RTE_HASH_EXTRA_FLAGS_RW_CONCURRENCY_LF` (lock-free readers, single
  writer); `rte_distributor`; eventdev atomic queues (scheduling instead of locking: "atomic flow" gives
  per-flow serialisation without locks, see the eventdev chapter).
- ABA visual: thread A reads top=X, next=Y; B pops X, pops Y, pushes X back; A's CAS(top, X, Y) succeeds and
  corrupts the stack. Fix: {pointer, counter} double-width CAS.

### 2.11 RCU: rte_rcu_qsbr (Quiescent State Based Reclamation)
- Files: `lib/rcu/rte_rcu_qsbr.h/.c`, `doc/guides/prog_guide/rcu_lib.rst` (figures in `doc/guides/prog_guide/img/
  rcu_general_info.*`). Added in 19.05 (Arm, Honnappa Nagarahalli).
- Problem: lock-free readers plus a writer that wants to free a deleted element. Split delete into 1) unlink
  (atomic) and 2) reclaim after a **grace period**, i.e. after every reader that might hold a reference has passed
  a **quiescent state** (a point holding no references, naturally the top of the `while(1)` poll loop).
- Data structure: `struct rte_rcu_qsbr { token (cache line), acked_token; num_elems, num_threads, max_threads;
  qsbr_cnt[max_threads] (each `struct __rte_cache_aligned rte_rcu_qsbr_cnt {cnt, lock_cnt}`); followed by a
  registered-thread bitmap of uint64 }`. cnt 0 means offline.
- Protocol: writer `rte_rcu_qsbr_start()` does `token = fetch_add(&v->token, 1, release) + 1` and returns t.
  Reader `rte_rcu_qsbr_quiescent(v, id)` loads token acquire and, if it differs, stores `qsbr_cnt[id].cnt = t`
  (release). Writer `rte_rcu_qsbr_check(v, t, wait)` scans the bitmap of registered threads and is done when every
  online thread's cnt >= t (offline threads are skipped), caching `acked_token` so later checks return fast.
  `rte_rcu_qsbr_synchronize(v, thread_id)` = start + blocking check (it reports a QS for the caller if it is itself
  a reader).
- Reader lifecycle: `rte_rcu_qsbr_get_memsize(max)`, `rte_rcu_qsbr_init(v, max)`,
  `rte_rcu_qsbr_thread_register(v, id)`, `_thread_online` (must be called before reading; it loads the current
  token), `_thread_offline` before blocking calls, `_thread_unregister`. `rte_rcu_qsbr_lock/unlock` are empty
  except under `RTE_LIBRTE_RCU_DEBUG` (lock_cnt is checked in quiescent). `rte_rcu_qsbr_dump(f, v)`.
- Defer queue (resource reclamation framework): `rte_rcu_qsbr_dq_create(&params)` with `struct
  rte_rcu_qsbr_dq_parameters {name, flags (RTE_RCU_QSBR_DQ_MT_LF), size, esize, trigger_reclaim_limit,
  max_reclaim_size, free_fn, p, v}`, then `rte_rcu_qsbr_dq_enqueue(dq, e)` (stores token + element in an
  internal rte_ring, auto-reclaims), `rte_rcu_qsbr_dq_reclaim(dq, n, &freed, &pending, &available)`,
  `rte_rcu_qsbr_dq_delete`.
- Library integrations: `rte_hash_rcu_qsbr_add(h, &struct rte_hash_rcu_config{v, mode
  (RTE_HASH_QSBR_MODE_DQ / _SYNC), dq_size, ...})`, `rte_lpm_rcu_qsbr_add`, `rte_fib_rcu_qsbr_add`,
  `rte_fib6_rcu_qsbr_add`. Typical usage: a control thread updates routes while workers do lookups with no locks.
- Trade-offs: zero reader cost (one relaxed load and a rarely taken store per loop iteration); writer latency is
  bounded by the slowest reader's loop iteration; memory is held during the grace period; a reader that blocks
  without going offline stalls reclamation forever (classic bug).
- **[VERIFIED]** `rcu.c`: 3 readers dereference a `RTE_ATOMIC(struct cfg *)` with acquire, verify `payload[0] ==
  version` (detects use-after-free because the writer poisons before freeing), and call `rte_rcu_qsbr_quiescent`
  every loop; the writer swaps 20 000 configs with `rte_atomic_exchange_explicit` and calls
  `rte_rcu_qsbr_synchronize(qs, RTE_QSBR_THRID_INVALID)`. Result: average grace period 1294 cycles (0.48 µs),
  about 1M reads per reader, no corruption. Variant exercises: remove the synchronize call to see the poison
  detected (non-deterministic, run several times); add `rte_delay_us(100)` in one reader to show the grace period
  growing; use the dq API.

### 2.12 Per-lcore data: lcore variables vs arrays vs TLS
- `RTE_DEFINE_PER_LCORE(type, name)` / `RTE_PER_LCORE(name)` is `__thread` TLS (`rte_per_lcore.h`). It is
  cheap, but other threads cannot access it, and it is per thread rather than per lcore id.
- The old idiom `struct foo stats[RTE_MAX_LCORE] __rte_cache_aligned` wastes memory (RTE_MAX_LCORE is 128 by
  default, often configured to 1024) and needs padding.
- **Lcore variables** (24.11, Mattias Rönnblom / Ericsson; `lib/eal/include/rte_lcore_var.h`,
  `lib/eal/common/eal_common_lcore_var.c`, `doc/guides/prog_guide/lcore_var.rst`): `RTE_LCORE_VAR_HANDLE(type,
  name)`, `RTE_LCORE_VAR_ALLOC(handle)`, `RTE_LCORE_VAR_INIT(name)` (constructor), `RTE_LCORE_VAR(handle)`
  (own value), `RTE_LCORE_VAR_LCORE(lcore_id, handle)`, `RTE_LCORE_VAR_FOREACH(lcore_id, value, handle)`,
  `rte_lcore_var_alloc(size, align)`. Storage: buffers of `RTE_MAX_LCORE_VAR (131072 in rte_config.h) *
  RTE_MAX_LCORE` bytes; the value for lcore i lives at `handle + i * RTE_MAX_LCORE_VAR`. So all of one lcore's
  variables from *different modules* are packed together (spatial locality for the owner), and different lcores
  are 128 KB apart (no false sharing without padding). The doc explicitly says **do not** cache-align or guard
  lcore variables. Not in hugepage memory; zero-initialised; never freed.
- Visual: a 2D grid (rows = lcore ids, columns = byte offset in the 128 KB slice); allocations from modules A, B, C
  appear as columns, and a core's working set is a row.

### 2.13 NUMA awareness
- APIs: `rte_socket_id()`, `rte_lcore_to_socket_id(l)`, `rte_eth_dev_socket_id(port)` (returns SOCKET_ID_ANY
  (-1) for vdevs), `rte_socket_count()`, `rte_socket_id_by_idx()`, new 26.11 experimental
  `rte_cpu_socket_id(cpu)`, `rte_pktmbuf_pool_create(..., socket_id)`, `rte_malloc_socket`,
  `rte_eth_rx_queue_setup(..., socket_id, ...)`, EAL `--numa-mem 1024,2048` / `--numa-limit` (26.11 names in
  `doc/guides/linux_gsg/linux_eal_parameters.rst`; older releases and tutorials call them `--socket-mem` /
  `--socket-limit`), `--pagesz-mem`, testpmd `--numa`, `--port-numa-config`,
  `--ring-numa-config`, `--socket-num`. Example skeleton (`examples/skeleton/basicfwd.c`) warns "port is on remote
  NUMA node". l3fwd allocates one mempool per socket.
- Costs: remote DRAM about 1.5-2x latency and lower bandwidth; PCIe DMA from a NIC to remote-socket memory crosses
  UPI/QPI; DDIO (Intel Data Direct I/O) only places DMA data in the *local* socket's LLC.
- This machine has 1 node, so NUMA cannot be shown live. Use diagrams plus `usertools/cpu_layout.py`,
  `lscpu`, and `/sys/devices/system/node`. A simulation/animation in the HTML (packet path: NIC on socket 0,
  core on socket 1, memory on socket 1, with the hops highlighted) is the way to go.

### 2.14 CPU isolation and lcore placement
- Kernel boot params: `isolcpus=2-7` (removes CPUs from the scheduler domains; `isolcpus=managed_irq,domain,2-7`),
  `nohz_full=2-7` (stops the periodic tick when 1 task runs; needs `CONFIG_NO_HZ_FULL`), `rcu_nocbs=2-7` (offload
  RCU callbacks), `irqaffinity=0-1`, `intel_pstate=disable`/`idle=poll`/`processor.max_cstate=1`
  (latency-oriented), `default_hugepagesz=1G hugepagesz=1G hugepages=N`, `iommu=pt intel_iommu=on`
  (`doc/guides/linux_gsg/nic_perf_intel_platform.rst`). Runtime checks: `/sys/devices/system/cpu/isolated`,
  `/sys/devices/system/cpu/nohz_full`, `/proc/interrupts`, `/proc/irq/*/smp_affinity`. Tools:
  `tuned-adm profile cpu-partitioning`, the cset/cgroup cpuset alternative.
- On this VM: `isolated` is empty and nohz_full is absent (Firecracker-style cmdline), so it can be *motivated*
  live with the noisy-neighbour demo.
- **[VERIFIED noisy-neighbour demo]**:
  ```
  taskset -c 1 timeout 9 sh -c 'while :; do :; done' &
  timeout -s INT -k 5 8 dpdk-testpmd -l 0-1 --no-huge -m 256 --no-pci --file-prefix=ch09noisy \
    --vdev=net_null0,copy=0 --vdev=net_null1,copy=0 -- --total-num-mbufs=8192 --forward-mode=io \
    --stats-period=3 --record-core-cycles
  ```
  Result: 24.45 Mpps (vs 49.0 alone) and "CPU cycles/packet=51.47" (vs 25.9). Lesson: the busy-cycle metric uses
  TSC and includes time the thread was preempted, so it **lies** under contention. Cross-check with `top -H`
  or `/proc/<pid>/task/<tid>/schedstat`.
- EAL lcore mapping: `-l 0-3`, `--lcores='(1-3)@20'`, `--lcores=1@(1,2)`, `--main-lcore`, `-c` mask, service
  cores `-s`, `--huge-worker-stack`. Doc `eal_args.include.rst` warns that binding multiple lcores to one CPU
  gives poor performance (spinning locks / rings plus preemption). `rte_thread_set_affinity`,
  `rte_thread_create_control` (control threads run on the "unused" CPUs from the affinity set, not on data-plane
  CPUs). Hyper-threading: put the two siblings of a physical core in the same pipeline stage or leave one idle;
  the power library notes the core frequency is set to the max requested by any sibling.

### 2.15 Power management
- Doc: `doc/guides/prog_guide/power_man.rst`, `doc/guides/sample_app_ug/l3_forward_power_man.rst`,
  `vm_power_management.rst`. Library: `lib/power/` (rte_power_cpufreq.h, rte_power_pmd_mgmt.h,
  rte_power_qos.h, rte_power_uncore.h). Drivers (26.x split into plugins): `drivers/power/{acpi, amd_pstate,
  cppc, intel_pstate, kvm_vm, intel_uncore, amd_uncore}`. **Not built in this install**
  (`build/drivers/power` is empty) and the VM has no cpufreq, so frequency scaling cannot run here.
- cpufreq API: `rte_power_set_env(PM_ENV_ACPI_CPUFREQ / PM_ENV_PSTATE_CPUFREQ / PM_ENV_CPPC_CPUFREQ /
  PM_ENV_AMD_PSTATE_CPUFREQ / PM_ENV_KVM_VM)`, `rte_power_check_env_supported`, `rte_power_init(lcore)`,
  `rte_power_freqs`, `rte_power_get_freq/set_freq`, `rte_power_freq_up/down/max/min`,
  `rte_power_freq_enable_turbo/disable_turbo`, `rte_power_turbo_status`, `rte_power_get_capabilities`
  (priority cores/SST-BF). It uses the `userspace` governor via `scaling_setspeed` (or pstate min/max).
- Uncore: `rte_power_uncore_init/set_freq/freq_min/max/get_num_freqs/pkgs/dies`; 26.11 adds
  `RTE_UNCORE_PM_ENV_AUTO_DETECT` probing multiple drivers.
- PM QoS: `rte_power_qos_set_cpu_resume_latency(lcore, latency_us)` writes
  `/sys/devices/system/cpu/cpuX/power/pm_qos_resume_latency_us` (this file **exists** on this VM, so it is
  runnable). 0 means strict (no deep C-states).
- CPU intrinsics (`lib/eal/include/generic/rte_power_intrinsics.h`, x86 impl
  `lib/eal/x86/rte_power_intrinsics.c`): `rte_power_monitor(&pmc, tsc_timestamp)` (UMONITOR/UMWAIT on an address,
  wakes on write: the NIC writing a descriptor), `rte_power_monitor_multi` (needs RTM too), `rte_power_pause(tsc)`
  (TPAUSE), `rte_power_monitor_wakeup(lcore)`; feature detection via `rte_cpu_get_intrinsics_support(&struct
  rte_cpu_intrinsics)`. Driver hook: `rte_eth_get_monitor_addr()` (eth_dev_ops `get_monitor_addr`). This VM has
  **no WAITPKG**, so monitor mode is unsupported and pause falls back to a `rte_pause()` loop.
- PMD power management (21.02+, `lib/power/rte_power_pmd_mgmt.c`): `rte_power_ethdev_pmgmt_queue_enable(lcore,
  port, queue, RTE_POWER_MGMT_TYPE_{MONITOR,PAUSE,SCALE})` installs an **Rx callback** that counts empty
  polls; after `emptypoll_max` (`rte_power_pmd_mgmt_set_emptypoll_max`, default 512) consecutive empty polls on
  *all* of the lcore's queues it sleeps (`clb_pause`: TPAUSE for `pause_duration` µs, set with
  `rte_power_pmd_mgmt_set_pause_duration`, else a `pause_per_us * duration` rte_pause loop; `clb_umwait`;
  `clb_scale_freq` with `rte_power_pmd_mgmt_set_scaling_freq_min/max`). The application stays unchanged: a pure
  callback design (ties into the ethdev rx callback chapter).
- Legacy l3fwd-power heuristics: frequency up/down on Rx queue occupancy (`rte_eth_rx_queue_count`),
  `--interrupt-only` (`rte_eth_dev_rx_intr_enable` + `rte_epoll_wait`), `--telemetry` mode (publishes busy
  percentage), `--pmd-mgmt=monitor|pause|scale`, `--max-empty-polls`, `--pause-duration`,
  `--scale-freq-min/max`, uncore `-u/-U/-i`.
- **[VERIFIED]** l3fwd-power on an idle ring vdev (needs `--parse-ptype`, otherwise "PMD can not provide needed ptypes"):
  ```
  timeout -s INT -k 3 8 $DPDK_SRC/build/examples/dpdk-l3fwd-power -l 0-1 --no-huge -m 256 --no-pci \
    --file-prefix=ch09pw --vdev=net_ring0 -- -p 0x1 --config="(0,0,1)" --parse-ptype \
    --pmd-mgmt=pause --max-empty-polls=64 --pause-duration=100
  top -b -n1 -H -p $(pgrep -f file-prefix=ch09pw | tail -1)
  ```
  Worker thread: about 27% CPU with `--max-empty-polls=64`, about 100% with `--max-empty-polls=1000000000`. Without
  mode flags it auto-selects: "Frequency scaling not supported, selecting interrupt-only mode". CAVEAT for the
  writer: the reduced CPU% is caused by KVM pause-loop exiting, not real TPAUSE; on bare metal without WAITPKG the
  rte_pause loop would still show 100% in top but use less power. Present it as "watch the mechanism, measure
  power on real HW with RAPL (`/sys/class/powercap/intel-rapl`, `turbostat`)".
- Visual: a timeline of a queue (packets arriving in bursts), empty-poll counter climbing, and the core state
  (C0 polling, C0.1/C0.2 TPAUSE, wake), with a wake-latency vs Watts trade-off slider.

### 2.16 Observability: telemetry, lcore usage, PMU, perf, trace
- Telemetry (`lib/telemetry/`, `doc/guides/prog_guide/telemetry_lib.rst`): a Unix socket at
  `/var/run/dpdk/<prefix>/dpdk_telemetry.v2`; client `usertools/dpdk-telemetry.py -f <prefix>`, plus
  `dpdk-telemetry-watcher.py` (continuous monitoring, new), `dpdk-telemetry-exporter.py` (Prometheus-style) and
  `dpdk-telemetry-client.py` (legacy). Register commands with `rte_telemetry_register_cmd(cmd, cb, help)` /
  `rte_telemetry_register_cmd_arg` (stable in 26.11) and build replies with `rte_tel_data_start_dict`,
  `rte_tel_data_add_dict_uint`, etc. 26.11 removed the old metrics-telemetry helpers.
- Lcore usage (23.03+): `rte_lcore_register_usage_cb(cb)` where `cb(lcore_id, struct rte_lcore_usage
  {total_cycles, busy_cycles})`; testpmd registers it when `--record-core-cycles`. Endpoints `/eal/lcore/usage`,
  `/eal/lcore/info,<id>`, `/eal/lcore/list`. **[VERIFIED]**:
  ```
  testpmd ... --file-prefix=ch09tel --vdev=net_null0 -- --total-num-mbufs=4096 --forward-mode=io \
     --auto-start --record-core-cycles --stats-period=5 &
  echo /eal/lcore/usage | python3 $DPDK_SRC/usertools/dpdk-telemetry.py -f ch09tel
  # {"/eal/lcore/usage":{"lcore_ids":[1],"total_cycles":[10289224302],"busy_cycles":[9477422356],"usage_ratio":["92.11%"]}}
  ```
  (testpmd without `--stats-period` or `-i` exits immediately when stdin is not a tty: always use
  `--stats-period` in scripts.) Also `/ethdev/stats,0`, `/ethdev/xstats,0`, `/mempool/info,<name>`,
  `/ring/list`, `/eal/heap_info`.
- `rte_pmu` (25.07, Marvell; `lib/pmu/rte_pmu.h`): `rte_pmu_init()`, `rte_pmu_add_event("cpu-cycles")` (names from
  `/sys/bus/event_source/devices/cpu/events`), `rte_pmu_read(index)` (inline `rdpmc` on x86 via
  `rte_pmu_pmc_x86_64.h`), `rte_pmu_fini()`. It needs `perf_event_paranoid<=2` plus CAP_PERFMON, EAL lcores not
  sharing a CPU, and the same event group on every lcore. Here paranoid=2 and we are root; whether the KVM guest
  exposes a vPMU is **unverified**: check `ls /sys/bus/event_source/devices/cpu/events` before writing an example.
  The `cpu` flags list has no `arch_perfmon`, so the vPMU is likely absent. Have a fallback.
- Linux `perf` is not installed here (`perf stat -e cycles,instructions,cache-misses,branch-misses -C 1`,
  `perf record -g`, `perf top -C`, `perf c2c` for false-sharing detection). Show the commands, not live output.
- VTune: build with `-Dc_args=-DRTE_ETHDEV_PROFILE_WITH_VTUNE` (profile_app.rst).
- Trace library (`doc/guides/prog_guide/trace_lib.rst`, `--trace=lib.ethdev.*`, CTF output, babeltrace /
  Trace Compass) for low-overhead event timelines. `lib/jobstats` (`examples/l2fwd-jobstats`) measures time per job
  versus idle. Graph lib: 26.11 adds `RTE_GRAPH_PROFILE` (cycles per burst size range per node).
- `--record-burst-stats` and `rte_eth_xstats` (`rx_missed_errors`/`imissed`: the NIC dropped because the
  core was too slow; this is THE first signal of "core can't keep up").

### 2.17 Benchmarking methodology
- RFC 2544 (throughput = max rate with zero loss, binary search; latency; back-to-back), RFC 2889, the
  "NDR/PDR" (no-drop / partial-drop rate) used by FD.io CSIT, and the DPDK per-release performance reports
  (fast.dpdk.org/doc/perf/, Intel/Mellanox/Broadcom NIC reports: these document BIOS, kernel cmdline, core
  mapping, descriptors, burst).
- Generators: TRex, pktgen-dpdk, MoonGen, testpmd txonly/flowgen, `dpdk-test-*-perf` tools
  (`dpdk-test-crypto-perf`, `dpdk-test-eventdev`, `dpdk-test-flow-perf`, all built here).
- Checklist: fix the frequency (disable turbo or report it), pin and isolate cores, warm up, run long enough, at
  least 5 repetitions with median/stddev, report packet size and the IMIX, separate throughput from latency (latency
  must be measured below saturation, with percentiles p50/p99/p99.9; HdrHistogram), control the NUMA
  placement, record versions/config, change one variable at a time, and watch for coordinated omission.
- DPDK unit/perf tests (`app/test`: `ring_perf_autotest`, `stack_perf_autotest`, `rcu_qsbr_perf_autotest`,
  `spinlock_autotest`, `ticketlock_autotest`, `mcslock_autotest`, `atomic_autotest`, `lcore_var_perf_autotest`,
  `mempool_perf_autotest`) are **not built** in this install (`build/app/` has no `dpdk-test`), so provide our own
  microbenchmarks instead (bench.c, rcu.c), or point to the source `app/test/test_*_perf.c` for reading.

---

## 3. Common pitfalls catalogue (for a "traps" section / quiz)
1. Using `rte_atomic32_*` / `rte_smp_*mb` with 26.11: **compile error** (removed). Migrate to `rte_atomic_*_explicit`.
2. Relaxed ordering that works on x86 (TSO) but fails on Arm; conversely, unneeded seq_cst everywhere (an mfence-like
   cost per op).
3. `volatile` is not atomic and not a barrier; `volatile` counters across cores have lost updates.
4. Shared statistics counters written by all lcores: use per-lcore counters (lcore variables) and aggregate in
   the reader.
5. False sharing between per-lcore structs; also the adjacent-line prefetcher, which needs `RTE_CACHE_GUARD`.
6. Burst size 1, or requesting fewer than 4 from a vector PMD (vector RX may return 0 for nb_pkts < 4).
7. Enabling an offload (e.g. scatter, a checksum offload, a VLAN combo) silently drops you from the AVX512 path to
   scalar. Always check `show rxq info` / `rte_eth_rx_burst_mode_get`.
8. Running two busy-polling lcores on one CPU (`--lcores` misuse) or a non-EAL thread spinning on a ring: lock-waiter
   preemption, MP ring tail stalls (use RTS/HTS rings).
9. Mempool without a cache, or used from non-EAL threads: every alloc hits the shared ring CAS.
10. Remote-NUMA mempool for a port (vdevs report SOCKET_ID_ANY; real NICs do not).
11. Calling blocking APIs (printf, malloc, syscalls, `rte_delay_ms`) in the fast path; logging per packet.
12. RCU reader blocking without `rte_rcu_qsbr_thread_offline()` stalls reclamation; forgetting `_thread_online`
    means the writer won't wait for that reader, which causes a use-after-free.
13. Freeing memory immediately after unlinking from a lock-free hash (without RCU or `RTE_HASH_EXTRA_FLAGS_NO_FREE_ON_DEL`).
14. Measuring with TSC under turbo/frequency scaling (TSC is not core cycles); trusting `rte_rdtsc` without
    serialisation for tiny regions; timing a single iteration.
15. TSC-based busy-cycle accounting including preemption time (noisy neighbour demo: cycles/packet doubled).
16. Microbenchmarks that the compiler optimises away, or where the store buffer hides contention (our volatile
    false-sharing non-result).
17. Comparing throughput across runs with different packet sizes, descriptor counts, or turbo state.
18. Too many descriptors (ring too large: working set exceeds LLC/DDIO ways) or too few (drops on bursts).
19. Power: enabling pause/monitor mode raises wake-up latency (a µs-level tail-latency hit); PMD power mgmt needs
    all queues of the lcore to be empty; monitor mode needs WAITPKG and driver `get_monitor_addr` support.
20. `isolcpus` alone does not stop the tick or IRQs; you also need nohz_full, rcu_nocbs and irqaffinity. Control
    threads must not be pinned on data-plane cores.
21. Unbounded spin with `rte_pause` in a VM wastes host CPU; HTS/RTS rings and `rte_wait_until_equal` with WFE help.
22. Using `rte_spinlock_lock_tm` assuming RTM: most recent Intel parts disable TSX (it falls back to the normal lock).

---

## 4. Runnable example ideas for THIS machine (all short, unique prefixes, no eth0)

Use `source <scratchpad>/dpdk-env.sh`; compile with `gcc -O2 x.c -o x $(pkg-config --cflags libdpdk)
$(pkg-config --libs --static libdpdk)`; run with `-l 0-3 --no-huge -m 64 --no-pci --file-prefix=ch09<x>
--log-level=lib.eal:warning`, wrapped in `timeout -s INT -k 5 30`.

| ID | Example | Status | Expected output shape |
|----|---------|--------|-----------------------|
| E1 | `cycles.c`: rte_get_tsc_hz, cost of rte_rdtsc vs rte_rdtsc_precise, empty-loop subtraction, rte_delay_us accuracy | rdtsc part **verified** (in bench.c) | 32 vs 62 cycles |
| E2 | testpmd burst sweep on net_null (copy=0 and copy=1) | **verified** | Mpps and cyc/pkt table |
| E3 | `false_sharing.c` packed vs padded vs RTE_CACHE_GUARD vs lcore variable, with atomic RMW | **verified** (bench.c modes 0/1) | 210 vs 12.7 cyc/op |
| E4 | `prefetch.c`: random gather over 64-256 MB with prefetch distance sweep | idea | U-curve |
| E5 | `branch.c`: sorted vs unsorted classification; `likely` vs not plus objdump | idea | 2-5x on random |
| E6 | `simd_sum.c`: checksum or a byte-swap kernel scalar vs SSE vs AVX2 vs AVX512 (`rte_vect.h` / immintrin), selected via `rte_vect_get_max_simd_bitwidth()` and `--force-max-simd-bitwidth` | idea | speedup bars |
| E7 | virtio_user packed vectorized vs scalar with vhost, `--force-max-simd-bitwidth` | **verified** | 18.0 vs 23.4 Mpps, log lines |
| E8 | `atomics_litmus.c`: message passing with relaxed vs release/acquire (on x86 the relaxed case still "works": discuss why; optionally the store-buffer/Dekker test, which **does** fail on x86 without a seq_cst fence) | idea; the SB test reliably shows r1==r2==0 on x86 | counts of forbidden outcomes |
| E9 | `locks.c`: spinlock/ticket/MCS/rwlock/pflock/seqlock under 1..3 lcores, plus a fairness histogram (acquisitions per lcore) | partially **verified** | cyc/op table, fairness bars |
| E10 | `seqlock_cfg.c`: writer updates a 64B config at 1 kHz; readers use `rte_seqlock_read_begin/retry` and count retries | idea | retry rate |
| E11 | `ring_modes.c`: rte_ring MP/MC vs SP/SC vs RTS vs HTS, bulk sizes 1/8/32, with an oversubscribed variant (`--lcores='(0-5)@(1-3)'`) to show RTS/HTS benefits under preemption | idea | |
| E12 | `rcu.c` pointer swap with synchronize; variant with `rte_rcu_qsbr_dq_*`; variant with rte_hash + `rte_hash_rcu_qsbr_add` | **verified** (base) | grace period 0.48 µs |
| E13 | `lcore_var.c`: per-lcore stats with RTE_LCORE_VAR, aggregated by the main lcore with RTE_LCORE_VAR_FOREACH and relaxed loads; plus a custom telemetry command `/ch09/stats` via `rte_telemetry_register_cmd` | idea | telemetry JSON |
| E14 | testpmd + dpdk-telemetry.py `/eal/lcore/usage` | **verified** | JSON shown above |
| E15 | noisy neighbour (busy loop on the lcore's CPU) | **verified** | 49 to 24.5 Mpps |
| E16 | l3fwd-power `--pmd-mgmt=pause` on net_ring0 with different `--max-empty-polls`; `rte_power_qos_set_cpu_resume_latency` read/write | pause **verified**; QoS sysfs file exists (not run) | top CPU% |
| E17 | `rxtx_callbacks` latency in cycles (with `stdbuf -oL`) | **verified** | "Latency = 248 cycles" |
| E18 | Custom `rte_lcore_register_usage_cb` in your own poll loop: count busy cycles only when nb_rx>0 | idea | usage ratio vs load |
| E19 | `numa_info.c`: print rte_socket_count, lcore to socket, rte_cpu_socket_id, port socket (vdev = -1) | idea | trivial on 1 node |

Notes for the writers:
- With testpmd always pass `--total-num-mbufs=4096..8192` under `-m 128/256`.
- Two concurrent testpmd processes need distinct `-l` sets and file prefixes; vhost/virtio needs `-m 64` hugepages
  and `--single-file-segments` (vhost-user has a max of 8 memory regions).
- testpmd in a script: use `--stats-period N` (it loops until SIGINT), not plain `--auto-start`.
- The machine has 4 vCPUs shared with other agents: results are noisy; print medians of 3 runs.

---

## 5. Visualisation and animation ideas
1. **Cycle-budget bar**: a horizontal bar of 181 cycles (10G at 2.7 GHz) shrinking to 18 (100G), with icons for an
   L1 hit, LLC hit, DRAM miss and a mispredict dropped into it. "One DRAM miss = your whole 100G budget".
2. **Latency ladder**: log-scale staircase from register to L1 to L2 to LLC to local DRAM to remote DRAM to PCIe
   to syscall.
3. **Burst amortisation animation**: a truck metaphor: fixed per-trip overhead (function call, doorbell MMIO, tail
   update) plus per-packet cost; slider for burst size; live chart of cyc/pkt = a/b + c fitted to our measured
   points (a about 100, c about 25).
4. **Cache-line ping-pong**: two cores, one 64B line split into 8 counter cells; animate the MESI states
   (M/E/S/I) and RFO messages as each core writes its own cell; toggle "padded" to separate the lines; show
   the measured 210 vs 12.7.
5. **Adjacent-line prefetcher**: highlight that a 128B pair is fetched together, which is why `RTE_CACHE_GUARD` exists.
6. **mbuf layout map**: two 64B rows with the field boxes colour-coded RX-hot / TX-hot / cold, plus headroom and data.
7. **Prefetch pipeline**: a timeline with memory latency bars; without prefetch the core stalls on each packet; with
   PREFETCH_OFFSET=3 the stalls overlap; slider for the offset (too early leads to eviction).
8. **Branch predictor**: a 2-bit saturating counter state machine animated on a stream of T/N outcomes; sorted vs
   random data.
9. **SIMD lanes**: 4 RX descriptors loaded into a ZMM register, a shuffle into mbuf fields, a single store; compare
   with scalar 4x loops. Path-selection decision tree (offloads requested? SIMD width allowed? CPU flag? ring
   size?) to "Vector AVX512 / AVX2 / SSE / Scalar".
10. **Memory-ordering litmus playground**: two threads, with an interactive selector of orderings (relaxed / acq-rel
    / seq_cst) and architecture (x86-TSO / Arm), showing which outcomes are allowed, including the store buffer on
    x86 animated (stores queue, loads bypass).
11. **Lock zoo animations**: spinlock (everyone hammering one line, with lots of red invalidation arrows); ticket lock
    (a deli counter "now serving"); MCS (a queue of nodes, each thread spinning on its own green flag, the hand-off
    passing a token); rwlock bit layout (`readers|WRITE|WAIT`); pflock phases; seqlock (the reader retries when it
    sees an odd or changed sequence number).
12. **Ring CAS**: prod.head/prod.tail/cons.head/cons.tail pointers on a circular buffer; two producers reserving
    slots by CAS, copying, the second waiting for the first's tail (in-order tail update); then RTS and HTS variants.
13. **ABA animation** on the LF stack, and the {ptr, counter} fix.
14. **RCU timeline** (the canonical figure): reader threads as horizontal lanes with critical sections (blue) and
    quiescent points (ticks); the writer unlinks at t0 (token++), the grace-period window extends until the last
    reader passes a tick, then free; offline readers greyed out. Interactive: drag a long critical section to
    see the grace period stretch.
15. **Lcore variable memory grid** (rows = lcores, columns = module allocations) vs the array-of-structs layout.
16. **NUMA topology map**: 2 sockets, NIC on socket 0, with correct (green) and wrong (red, crossing UPI) placements
    animated with per-hop latency.
17. **CPU isolation**: a scheduler timeline of a CPU with ticks, kworkers, IRQs and a noisy process interrupting the
    poll loop vs a clean isolated CPU (nohz_full); jitter histogram.
18. **Power state machine**: empty-poll counter, then threshold, then TPAUSE/UMWAIT (with a C0.1/C0.2 tooltip),
    then a wake on the descriptor write (monitor) or a timeout (pause); a Watts vs wake latency trade-off chart.
19. **Benchmark methodology flow**: an RFC 2544 binary search animation on offered load vs loss.

---

## 6. Source references (in tree)
- Docs: `doc/guides/prog_guide/{perf_opt_guidelines, writing_efficient_code, rcu_lib, power_man, telemetry_lib,
  lcore_var, thread_safety, ring_lib, stack_lib, mempool_lib, profile_app, trace_lib, env_abstraction_layer}.rst`;
  `doc/guides/linux_gsg/{nic_perf_intel_platform, linux_eal_parameters, eal_args.include}.rst`;
  `doc/guides/sample_app_ug/{l3_forward_power_man, vm_power_management, rxtx_callbacks, l2_forward_job_stats,
  service_cores}.rst`; `doc/guides/nics/{ixgbe,i40e,ice,virtio}.rst` (vector constraints);
  `doc/guides/rel_notes/release_26_11.rst` (atomics removal, pile, rte_cpu_socket_id, uncore auto-detect, graph
  profiling), `release_19_05` (RCU), `release_19_08` (MCS), `release_21_02` (PMD power mgmt, power monitor),
  `release_21_05` (pflock), `release_22_07` (seqlock), `release_23_03` (lock annotations, lcore usage),
  `release_23_11` (stdatomic), `release_24_11` (lcore variables, bitops), `release_25_07` (PMU library).
- Headers: `lib/eal/include/{rte_common.h, rte_branch_prediction.h, rte_stdatomic.h, rte_ticketlock.h,
  rte_mcslock.h, rte_pflock.h, rte_seqcount.h, rte_seqlock.h, rte_lcore_var.h, rte_lcore.h, rte_per_lcore.h,
  rte_bitops.h, rte_lock_annotations.h}`, `lib/eal/include/generic/{rte_atomic.h, rte_spinlock.h, rte_rwlock.h,
  rte_pause.h, rte_prefetch.h, rte_cycles.h, rte_vect.h, rte_power_intrinsics.h, rte_cpuflags.h}`,
  `lib/eal/x86/include/{rte_atomic.h, rte_spinlock.h, rte_prefetch.h, rte_cycles.h, rte_pause.h, rte_rtm.h}`,
  `lib/eal/x86/rte_power_intrinsics.c`, `lib/eal/arm/include/rte_pause_64.h`, `config/rte_config.h`.
- Libraries: `lib/rcu/rte_rcu_qsbr.{h,c}`, `lib/ring/{rte_ring_core.h, rte_ring_c11_pvt.h, rte_ring_rts*.h,
  rte_ring_hts*.h, rte_ring_peek*.h}`, `lib/stack/{rte_stack_lf*.h, rte_stack_pile.*}`,
  `lib/mempool/rte_mempool.h`, `lib/mbuf/rte_mbuf_core.h`, `lib/power/*`, `lib/pmu/*`, `lib/telemetry/*`,
  `lib/hash/rte_hash.h` (RCU config), `lib/lpm/rte_lpm.h`, `lib/fib/rte_fib.h`.
- Drivers: `drivers/net/intel/common/{rx.h, rx_vec_x86.h, tx_vec_x86.h}`, `drivers/net/intel/i40e/i40e_rxtx_vec_*.c`,
  `drivers/net/virtio/{virtio_rxtx_packed.c, virtio_rxtx_packed_avx.h, virtio_rxtx_simple_sse.c}`, `drivers/power/*`.
- Examples: `examples/l3fwd` (prefetch pattern, per-socket pools), `examples/l3fwd-power`, `examples/rxtx_callbacks`,
  `examples/l2fwd-jobstats`, `examples/service_cores`, `examples/skeleton` (NUMA warning), `app/test-pmd`
  (`--record-core-cycles`, `--record-burst-stats`, `show rxq info`), `app/test/test_{ring_perf, rcu_qsbr_perf,
  spinlock, ticketlock, mcslock, pflock, seqlock, lcore_var_perf, atomic}.c` (read-only references; not built).
- Verified example sources: `research/09-examples/bench.c` (false sharing, atomic, spin/ticket/MCS locks, rdtsc),
  `research/09-examples/rcu.c` (QSBR pointer swap).

## 7. External references (for history and design rationale)
- DPDK atomics deprecation discussion: Phil Yang (Arm), "generic rte atomic APIs deprecate proposal" (2020),
  https://lore.kernel.org/all/1981187.MM7D9Lm00Q@thomas/T/ ; "doc: add generic atomic deprecation section",
  https://lore.kernel.org/all/4777511.sDcrFEcvGN@thomas/t/ ; Stephen Hemminger, "[PATCH v3 00/27] deprecate
  rte_atomicNN family" (May 2026), https://mails.dpdk.org/archives/dev/2026-May/337911.html and v5
  https://mails.dpdk.org/archives/dev/2026-June/340288.html
- "State of C11 code in DPDK" (DPDK Userspace 2019 slides), https://www.dpdk.org/wp-content/uploads/sites/23/2019/10/StateofC11Code.pdf
- Aleksey Shipilev, "On the fence with dependencies" (lock addl vs mfence), cited in `x86/include/rte_atomic.h`.
- Mellor-Crummey & Scott, "Algorithms for Scalable Synchronization on Shared-Memory Multiprocessors" (1991, the MCS lock).
- Brandenburg & Anderson, "Spin-Based Reader-Writer Synchronization for Multiprocessor Real-Time Systems" (phase-fair locks).
- McKenney, "Is Parallel Programming Hard, And, If So, What Can You Do About It?" (RCU, QSBR, memory ordering).
- Intel SDM Vol. 3 §8.2 (x86 memory ordering); Intel optimisation manual (prefetch, PAUSE latency change in Skylake).
- RFC 2544 / RFC 2889 benchmarking; DPDK performance reports at https://core.dpdk.org/perf-reports/.
- (Not verified online in this session: DPDK Summit talks on RCU (Honnappa Nagarahalli) and lcore variables
  (Mattias Rönnblom). Search the DPDK YouTube channel if the writers want video links.)

# Research Note 01 — DPDK Big Picture: History, Goals, Kernel Bypass, Execution Models, Architecture, Ecosystem

Scope: the "why" and "map" chapter(s) of the course. Everything here is anchored to the DPDK 26.11.0 tree at
`$DPDK_SRC` (= `/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/clone/dpdk`),
plus experiments run on this VM (4-core Xeon, virtio eth0, Linux 6.18). Runnable sources used for
the experiments are copied to `research/01-examples/` (`bypass_bench.c`, `intr_vs_poll.c`).

---------------------------------------------------------------------------------------------------

## 0. Suggested teaching order (easy -> hard)

1. **The problem**: line-rate arithmetic (how many ns per packet at 10/25/100/400 GbE). Motivates everything.
2. **Where the kernel spends time**: syscall, interrupt, softirq, sk_buff alloc, copies, locks, cache misses, context switches.
3. **The five DPDK tricks** (each maps to a library you will learn later):
   user-space drivers (UIO/VFIO, `bus/pci`), polling (PMDs), hugepages (EAL memory), lock-free rings + pools
   (`ring`, `mempool`), batching/bursts + cache awareness (`mbuf`, `rte_prefetch*`, SIMD Rx/Tx paths).
4. **First contact**: `dpdk-helloworld` (EAL + lcores) -> `dpdk-skeleton` (basicfwd) on `net_null`/`net_ring`.
5. **Execution models**: run-to-completion vs pipeline (rings between lcores), and "event-driven" (eventdev).
6. **Poll vs interrupt**: why polling burns 100% CPU, power trade-off (`l3fwd-power`, Rx interrupts, `rte_power`, PMD power management).
7. **Architecture & library map**: EAL -> core libs (ring, mempool, mbuf, timer, hash, lpm...) -> device-class
   abstractions (ethdev, cryptodev, eventdev, dmadev, compressdev, bbdev, regexdev, mldev, gpudev, rawdev) -> drivers -> apps.
8. **Project/process**: licensing (BSD-3 + GPL kernel bits), YY.MM versioning, 3 releases/year, LTS (.11), ABI policy.
9. **Ecosystem**: OVS-DPDK, VPP/FD.io, SPDK, F-Stack, TRex, Seastar, Pktgen-DPDK, MoonGen, Cisco/telco NFV, cloud vSwitches.
10. **Alternatives & comparison**: AF_XDP/XDP, io_uring (zero-copy rx), netmap, PF_RING ZC, RDMA/verbs (and mlx5 bifurcated PMD), Snabb, eBPF.
    Ends with "when NOT to use DPDK".

The first chapter of the course should be narrative + visuals with 2-3 tiny runnable demos; the deep mechanics
(EAL memory, ring internals, mempool cache, mbuf layout, ethdev queue setup) belong to later dedicated chapters.

---------------------------------------------------------------------------------------------------

## 1. History and goals

### Timeline (verified against dpdk.org / LF sources + in-tree release notes)
| Year | Milestone |
|---|---|
| ~2010 | Created inside Intel (embedded & communications group). Original architect **Venky Venkatesan**; early code with **6WIND** as contractor. Goal: prove that general-purpose IA servers can do packet processing that previously required NPUs/ASICs. Early versions ~10x kernel throughput. Always BSD-licensed, but released as Intel-validated drops. |
| 2013 | **dpdk.org** open-source community site launched by 6WIND; patches on public mailing list (dev@dpdk.org). Releases 1.x (1.2.3, 1.3, 1.5, 1.6 added FreeBSD per `prog_guide/intro.rst`), 1.7, 1.8 (`rel_notes/release_1_8.rst` is the oldest in-tree note). |
| 2014-2015 | Intel moves release control to dpdk.org; maintainers **Thomas Monjalon** (6WIND, later NVIDIA) and **Bruce Richardson** (Intel). 2.0/2.1/2.2 releases. Multi-vendor drivers (Mellanox mlx4/mlx5, Chelsio, Broadcom, Cisco enic...), non-x86 ports (POWER, ARM). |
| 2016 | Versioning switches to **YY.MM** with 16.04 (`rel_notes/release_16_04.rst`). Quarterly releases (.02 .05 .08 .11). 16.11 first LTS. |
| April 2017 | DPDK moves to the **Linux Foundation** (governing board + technical board, neutral hosting). |
| 2017-2021 | Meson build replaces make (make removed in 20.11); eventdev (17.05), rte_flow (17.02), cryptodev/security, vhost improvements, Windows port (20.02+), ABI policy (major ABI yearly, aligned with LTS). |
| 2022 | Cadence changed from 4 to **3 releases/year**: .03, .07, .11 (LTS) starting 22.03 (proposal by T. Monjalon Nov 2021). |
| 2023-2026 | dmadev, mldev, gpudev, graph/node libs, dispatcher, lcore variables, `argparse`, PMU, ptr_compress, RISC-V & LoongArch EAL. 26.11 (this tree) adds VFIO cdev/IOMMUFD mode, 1.6T link speed, pile mempool driver, `rte_cpu_socket_id()` (see `doc/guides/rel_notes/release_26_11.rst`). `ABI_VERSION` file says `27.0`. |

### Stated goal (from `doc/guides/prog_guide/overview.rst`)
"The main goal of the DPDK is to provide a simple, complete framework for fast packet processing in data plane
applications." It is a **toolkit of libraries**, not a network stack: no TCP/IP stack, no sockets; the app owns the NIC.

---------------------------------------------------------------------------------------------------

## 2. Why kernel bypass — the numbers

### Packet-time budget (teach with an interactive calculator)
Min Ethernet frame = 64 B + 8 B preamble/SFD + 12 B IFG = **84 B on the wire = 672 bits**.

| Link | Max pps (64 B) | Time per packet | Cycles/pkt @ 3 GHz |
|---|---|---|---|
| 1 GbE | 1.488 Mpps | 672 ns | ~2016 |
| 10 GbE | 14.88 Mpps | 67.2 ns | ~201 |
| 25 GbE | 37.2 Mpps | 26.9 ns | ~81 |
| 40 GbE | 59.5 Mpps | 16.8 ns | ~50 |
| 100 GbE | 148.8 Mpps | 6.72 ns | ~20 |
| 400 GbE | 595 Mpps | 1.68 ns | ~5 |

Reference costs to put on the same scale: L3 hit ~40 cycles, DRAM miss ~60-100 ns (200-300 cycles), syscall
~100+ ns (more with mitigations), context switch ~1-5 us, interrupt + softirq processing hundreds of ns,
`sk_buff` alloc + init ~ hundreds of cycles. => At 10 GbE you cannot afford even ONE cache miss per packet without
batching/prefetch; a syscall per packet is impossible.

### Measured on THIS VM (`research/01-examples/bypass_bench.c`)
```
kernel sendto (UDP, loopback, 64B)        : 1093.6 ns/pkt  (0.91 Mpps)
dpdk rx_burst+tx_burst on net_null (32/burst):   9.4 ns/pkt  (106.83 Mpps)
```
testpmd io-forwarding between two `net_null` ports on one lcore: **~54.6 Mpps** (Rx-pps 54646748).
Caveat to teach honestly: `net_null` does no real I/O (it just allocs/frees mbufs: see `eth_null_rx` in
`drivers/net/null/rte_eth_null.c:88`), so this number measures the DPDK framework overhead (inline burst
dispatch + mempool cache), not a NIC. Still: framework cost ~10 ns/pkt vs ~1 us/pkt for one syscall.

Build/run:
```
source .../dpdk-env.sh
gcc -O2 bypass_bench.c -o bypass_bench $(pkg-config --cflags libdpdk) $(pkg-config --libs --static libdpdk)
timeout -s INT -k 5 25 ./bypass_bench -l 1 --no-huge -m 128 --no-pci --file-prefix=ch01bb --vdev=net_null0
```

### What the kernel does per packet (for a "path comparison" animation)
Kernel Rx: NIC DMA -> IRQ -> NAPI poll (softirq) -> `sk_buff` alloc -> GRO -> netfilter/routing -> socket queue
-> wake process -> `recvmsg()` syscall -> copy to user. Tx is the mirror (copy, qdisc, driver, doorbell, completion IRQ).
DPDK Rx: NIC DMA directly into **pre-allocated mbuf in hugepage memory mapped in user space** -> app's
`rte_eth_rx_burst()` reads descriptor ring (DD bit), hands back up to N mbuf pointers, refills descriptors with fresh
mbufs from per-lcore mempool cache -> app processes -> `rte_eth_tx_burst()` writes descriptors + one MMIO doorbell
(tail register) for the whole burst. No syscalls, no copies, no interrupts, no locks on the fast path (one queue per lcore).

### The five techniques (and where they live)
| Technique | Why | Where in DPDK |
|---|---|---|
| User-space driver (UIO/VFIO, BAR mmap, DMA via IOMMU) | no syscalls/copies; app owns device | `drivers/bus/pci/linux/pci_vfio.c`, `lib/eal/linux/eal_vfio.c`, `usertools/dpdk-devbind.py`, `doc/guides/linux_gsg/linux_drivers.rst` |
| Polling (PMD) | no IRQ/context switch latency; predictable | `drivers/net/*`, `rte_eth_rx_burst()` in `lib/ethdev/rte_ethdev.h:6183` |
| Hugepages (2M/1G) | few TLB entries cover all packet memory; physically contiguous for DMA | `lib/eal/common/eal_common_memory.c`, `lib/eal/linux/eal_memalloc.c`, `usertools/dpdk-hugepages.py` |
| Lockless rings + mempools with per-core caches | no locks/atomics in common case | `lib/ring/`, `lib/mempool/rte_mempool.h` |
| Bursts, prefetch, SIMD, cache alignment, NUMA locality | amortize per-call cost and memory latency | `__rte_cache_aligned`, `rte_prefetch0()` (`lib/eal/include/generic/rte_prefetch.h`), vector PMD paths (e.g. `drivers/net/intel/*/*_vec*.c`) |

Plus: core pinning/isolation (EAL `-l`, `isolcpus`, `nohz_full`), NUMA-aware allocation (`rte_socket_id()`).

---------------------------------------------------------------------------------------------------

## 3. User-space drivers

- Linux side: the NIC is unbound from its kernel driver and bound to **vfio-pci** (preferred; IOMMU-protected,
  works unprivileged with group permissions), **uio_pci_generic** or out-of-tree **igb_uio** (legacy, no IOMMU).
  `dpdk-devbind.py --status / --bind=vfio-pci 0000:xx:yy.z`. VFIO no-IOMMU mode for VMs without vIOMMU.
  26.11 adds **VFIO cdev (IOMMUFD)** mode alongside group mode (`linux_drivers.rst` "VFIO group and cdev modes").
- EAL then: scans buses (`rte_bus_scan()`), mmaps BARs (`/sys/bus/pci/devices/*/resource*` or VFIO region),
  sets up DMA mappings of hugepage memory in the IOMMU (`rte_vfio_*`), chooses **IOVA mode** PA or VA
  ("EAL: Selected IOVA mode 'VA'" in all our runs), and probes drivers (`rte_bus_probe()`).
- **Bifurcated drivers** (mlx4/mlx5, also AF_XDP-style designs): kernel keeps the netdev, DPDK gets queues via
  verbs; flow rules decide what goes to DPDK. No unbinding needed. Great comparison point with RDMA.
- **Virtual devices (vdev)**: software PMDs instantiated by `--vdev=net_xxx,args` with no hardware at all:
  `net_null`, `net_ring`, `net_tap`, `net_af_packet`, `net_af_xdp`, `net_pcap`, `net_memif`, `net_vhost`,
  `virtio_user`, `net_bonding`, `net_failsafe`... This is what the course uses on this machine.
  (On this VM eth0 is virtio and carries the session — never bind it; the virtio PMD is taught via `virtio_user`+`vhost`.)

### `rte_eal_init()` sequence (from `lib/eal/linux/eal.c:566`) — great for an animated "boot" diagram
1. parse args (`eal_collate_args`, `eal_parse_args`), init logging
2. CPU detection `rte_eal_cpu_init()` ("Detected CPU lcores: 4", "Detected NUMA nodes: 1")
3. plugins (`-d` shared drivers), trace init, device options (`-a/-b/--vdev`)
4. config / shared memory config (primary vs secondary process; `/var/run/dpdk/<file-prefix>/`)
5. interrupt thread (`rte_eal_intr_init`, "eal-intr-thread"), alarms, multi-process channel (`rte_mp_channel_init`, "Multi-process socket ...mp_socket")
6. VFIO init, **bus scan**, IOVA mode decision
7. hugepage info, `rte_eal_memzone_init`, `rte_eal_memory_init`, malloc heaps
8. tailqs, timers (TSC calibration), affinity of main lcore
9. create worker threads (one pthread per lcore, pinned), `rte_eal_mp_remote_launch(sync_func)`
10. `rte_service_init()`, **bus probe** (drivers' probe functions -> ethdev ports appear), services start
11. telemetry socket (`rte_telemetry_init`), `eal_mcfg_complete()`

---------------------------------------------------------------------------------------------------

## 4. Poll-mode vs interrupts

- PMD = driver with no interrupt on the data path; the app calls `rte_eth_rx_burst()` in a tight loop.
  `rte_eth_rx_burst()` is a `static inline` in `lib/ethdev/rte_ethdev.h` that indexes the flat array
  `rte_eth_fp_ops[port_id]` (`lib/ethdev/rte_ethdev_core.h:87,129`; populated by `eth_dev_fp_ops_setup()`
  `lib/ethdev/ethdev_private.c:285` at `rte_eth_dev_start()`), then calls `p->rx_pkt_burst(qd, pkts, n)` — the driver's
  function pointer. Optional Rx callbacks (`RTE_ETHDEV_RXTX_CALLBACKS`) and tracepoints follow.
  Diagram idea: "app -> inline wrapper -> fp_ops[port] -> rxq.data[queue] -> driver burst fn -> descriptor ring".
- Cost: 100% CPU on each polling lcore even at zero traffic. Measured: `dpdk-skeleton` on `net_null` -> 96.3% CPU in `ps`.
- Mitigations:
  - **Rx interrupt mode**: `conf.intr_conf.rxq = 1`, `rte_eth_dev_rx_intr_ctl_q(port, q, RTE_EPOLL_PER_THREAD, RTE_INTR_EVENT_ADD, NULL)`,
    `rte_eth_dev_rx_intr_enable()` + `rte_epoll_wait()` + `rte_eth_dev_rx_intr_disable()` (pattern used in `examples/l3fwd-power`).
    Among vdevs, only **net_tap** and virtio/vhost advertise "Rx interrupt = Y" (`doc/guides/nics/features/tap.ini`, `virtio.ini`).
  - **PMD power management** (`lib/power/rte_power_pmd_mgmt.h`): UMWAIT/monitor, pause, frequency scaling callbacks on Rx.
  - Adaptive polling heuristics (back off with `rte_pause()`/sleep after N empty polls), `l3fwd-power` "legacy/empty-poll/telemetry" modes.
  - Hybrid: NAPI in the kernel is the mirror-image idea (interrupt then poll).
- **Measured (`research/01-examples/intr_vs_poll.c`, net_tap, idle 5 s):**
  ```
  mode=poll pkts=0 polls=27,338,446 wakeups=0  user_cpu=1.96s sys_cpu=3.05s
  mode=intr pkts=0 polls=50         wakeups=50 user_cpu=0.00s sys_cpu=0.02s
  ```
  Note: poll mode on net_tap shows high *sys* time because the tap PMD does a `readv()` syscall per poll when
  its SIGIO trigger says data may be there (`pmd_rx_burst`, `drivers/net/tap/rte_eth_tap.c:479`) — a nice lesson that
  "a PMD over a kernel interface is NOT kernel bypass". Once the interface was up, polls rose to ~230 M per 5 s
  (no syscalls when the trigger counter is unchanged).
  Run: `timeout -s INT -k 5 15 ./intr_vs_poll -l 2 --no-huge -m 128 --no-pci --file-prefix=ch01ivpoll --vdev=net_tap0,iface=ch01tapX -- poll|intr`
  CAVEAT: our attempt to inject kernel UDP traffic into the tap (with `ip addr` + static neigh) delivered 0 packets
  to the single DPDK queue (kernel TX counter rose; likely the tap PMD's keep-alive queue fd or SIGIO trigger interplay).
  The chapter writer should either use 2+ Rx queues, inject with a raw AF_PACKET socket, or demo packet arrival via
  `net_af_packet` on a veth pair (verified working, below) and keep the tap demo for the idle-CPU comparison only.

---------------------------------------------------------------------------------------------------

## 5. Run-to-completion vs pipeline (and event-driven)

- **Run-to-completion (RTC)**: each lcore owns Rx queue(s) and does Rx -> process -> Tx for its packets.
  Scale with RSS (NIC hashes flows to queues: one queue per lcore). No inter-core communication; best cache locality.
  Examples: `examples/skeleton/basicfwd.c` (221 lines), `examples/l2fwd`, `examples/l3fwd`.
- **Pipeline**: stages on different lcores connected by `rte_ring` (lockless SP/SC or MP/MC FIFOs of pointers).
  E.g. Rx core -> worker cores -> Tx core. Pros: stage specialization, large code split across I-caches, handles
  heavy/variable work; cons: ring hops (cache line transfers between cores), ordering issues (needs `rte_reorder`),
  bottleneck stage. Examples: `examples/packet_ordering` (Rx -> workers -> reorder/Tx), `examples/distributor`,
  `examples/qos_sched`, `examples/pipeline` (packet framework / SWX pipeline), `lib/graph` + `examples/l3fwd-graph` (graph of nodes; mcore dispatch model).
- **Event-driven**: `lib/eventdev` + `event_sw` (or HW schedulers). Scheduler distributes events to workers with
  atomic/ordered/parallel flow semantics, giving pipeline flexibility with automatic load balancing and ordering.
  Examples: `examples/eventdev_pipeline`, `examples/l2fwd-event` (can run in poll or event mode = direct comparison).
- Hybrid: RTC + offload to service cores (`rte_service`), DMA engines (dmadev), crypto devices (cryptodev async enqueue/dequeue).
- Measured here: `dpdk-packet_ordering -l 0-3 --no-huge -m 900 --no-pci --vdev=net_null0 --vdev=net_null1 -- -p 3`
  works (8 s run: 3.29 M pkts dequeued from workers ring, 115 k "enq to tx failed" => visible back-pressure at the
  Tx stage — great talking point). Needs ~900 MB with `--no-huge` because of its pools (fails with -m 256: "Cannot allocate memory").

---------------------------------------------------------------------------------------------------

## 6. Architecture & library map (26.11 tree: 60 entries in `lib/`, 58 net drivers)

Layering (draw as stacked diagram; `doc/guides/prog_guide/img/architecture-overview.svg` exists as a reference):

```
 Applications:  app/ (dpdk-testpmd, dpdk-proc-info, dpdk-pdump, dpdk-dumpcap, test-*-perf, dpdk-test) ; examples/ (helloworld..ipsec-secgw)
 ───────────────────────────────────────────────────────────────────────────────────────────────────────────
 Protocol/algorithm libs: net (headers, cksum), ip_frag, gro, gso, ipsec, pdcp, acl, lpm/lpm6, fib, rib, hash, efd,
   member, reorder, distributor, sched, meter, pipeline/table/port, graph/node, bpf, pcapng, pdump, latencystats,
   bitratestats, metrics, jobstats, telemetry, dispatcher, power, timer, rcu, ptr_compress, argparse, cmdline, cfgfile, kvargs
 ───────────────────────────────────────────────────────────────────────────────────────────────────────────
 Device-class APIs: ethdev (+rte_flow, rte_mtr, rte_tm), cryptodev + security, compressdev, eventdev, dmadev,
   bbdev, regexdev, mldev, gpudev, rawdev, vhost (backend), (pci helper lib)
 ───────────────────────────────────────────────────────────────────────────────────────────────────────────
 Core: mbuf  ← mempool (drivers/mempool: ring, stack, bucket, pile[new]) ← ring, stack
 ───────────────────────────────────────────────────────────────────────────────────────────────────────────
 EAL (lib/eal): lcores/threads, memory (hugepages, memzones, rte_malloc, IOVA), buses/devargs/hotplug,
   interrupts/alarms, multi-process, timers (TSC), atomics/spinlocks/rwlock/seqlock/MCS/ticketlock, logs (lib/log),
   trace, services, lcore variables; per-OS (linux, freebsd, windows, unix) and per-arch (x86, arm, ppc, riscv, loongarch)
 ───────────────────────────────────────────────────────────────────────────────────────────────────────────
 Drivers (drivers/<class>/<name> -> librte_<class>_<name>): bus (pci, vdev, vmbus, fslmc, auxiliary, platform...),
   common, mempool, net, crypto, compress, event, dma, baseband, regex, ml, gpu, raw, vdpa, power
 ───────────────────────────────────────────────────────────────────────────────────────────────────────────
 OS / hardware: VFIO/UIO, hugetlbfs, IOMMU, NIC / accelerators
```

Key relationships to highlight:
- **mbuf** objects live in a **mempool**, whose default backend ("ops") is a **ring** (`ring_mp_mc` — testpmd log
  "preferred mempool ops selected: ring_mp_mc"); each lcore has a mempool **cache** in front of it.
- Every device class follows the same pattern: generic API lib + `*_driver.h` driver interface + drivers registered
  via `RTE_PMD_REGISTER_VDEV`/`RTE_PMD_REGISTER_PCI` constructors, found by the bus during probe.
- Fast-path APIs are inline (`rte_eth_rx_burst`, `rte_ring_enqueue_burst`, `rte_mempool_get`) — no PLT calls,
  driver function pointers via flat arrays.
- Source org rules: `doc/guides/prog_guide/source_org.rst` (lib = API; drivers produce `librte_X_Y.a`; apps contain main()).
- Tools: `usertools/dpdk-devbind.py`, `dpdk-hugepages.py`, `dpdk-telemetry.py`, `cpu_layout.py`, `dpdk-pmdinfo.py`.
- Build: meson/ninja; apps link via `pkg-config libdpdk` (static used here).

---------------------------------------------------------------------------------------------------

## 7. Licensing, releases, governance

- License: **BSD-3-Clause** for libs/drivers (SPDX one-line headers, `license/README`); kernel components GPL-2.0;
  some exceptions in `license/exceptions.txt` (dual BSD/GPL, MIT, ISC...). Permissive => usable in proprietary
  appliances (big reason for telco/vendor adoption).
- Versioning **YY.MM** since 16.04; releases **.03, .07, .11** since 2022 (before: .02 .05 .08 .11).
  Each cycle: proposal deadline -> rc1 (features) -> rc2..rc4 -> release.
- **LTS**: each November release (X.11), maintained 3 years with ≥3 point releases per year
  (`doc/guides/contributing/stable.rst`); stable branches at `git.dpdk.org/dpdk-stable`.
- **ABI policy** (`doc/guides/contributing/abi_policy.rst`): new major ABI at most yearly, usually aligned with LTS
  (e.g. ABI 21 for 20.11); `__rte_experimental` APIs can change; symbol versioning (`abi_versioning.rst`).
  26.11 tree: `ABI_VERSION` = 27.0.
- Governance: Linux Foundation project; Governing Board (funding members) + Technical Board (technical decisions);
  development via dev@dpdk.org mailing list + patchwork (patches.dpdk.org), maintainers per subtree (MAINTAINERS file),
  CI via DPDK Community Lab (UNH-IOL).

---------------------------------------------------------------------------------------------------

## 8. Ecosystem (who builds on DPDK)

| Project | What | How it uses DPDK |
|---|---|---|
| **OVS-DPDK** (Open vSwitch userspace datapath, `dpif-netdev`) | virtual switch for NFV/cloud | PMD threads poll physical ports (DPDK) + vhost-user ports to VMs; EMC/SMC/dpcls flow caches |
| **VPP / FD.io** (Cisco-originated, 2016) | vector packet processing router/switch | DPDK as one input plugin (also native AF_XDP, RDMA, AVF drivers); processes *vectors* of packets through a node graph — same idea as DPDK `lib/graph` |
| **SPDK** (Intel) | user-space NVMe storage | reuses DPDK EAL (hugepages, memory, PCI/VFIO, rings, mempool) — not for networking but same bypass philosophy |
| **F-Stack** (Tencent) | FreeBSD TCP/IP stack ported to user space on DPDK | provides socket-like/epoll API; DPDK itself has no TCP stack |
| **TRex** (Cisco) | stateful/stateless traffic generator | DPDK for line-rate generation; also Pktgen-DPDK, MoonGen (Lua scripting over DPDK) |
| **Seastar / ScyllaDB** | shared-nothing async C++ framework | optional DPDK network backend with own TCP stack, one shard per core |
| Others | mTCP, Snort/Suricata DAQ, Wireshark-like capture (dpdk-dumpcap), DPVS (L4 LB), 5G UPF (OAI, free5GC variants), Ericsson/Nokia/Cisco VNFs, AWS ENA / Azure netvsc / Google gVNIC PMDs in-tree, NVIDIA/Mellanox, Marvell, Intel IPU | |

---------------------------------------------------------------------------------------------------

## 9. Comparison with alternatives

| | DPDK | AF_XDP (+XDP/eBPF) | io_uring (net) | netmap | PF_RING ZC | RDMA / verbs |
|---|---|---|---|---|---|---|
| Driver | user-space PMD (or vdev) | kernel driver, XSK socket | kernel stack | patched/native kernel drivers | modified drivers | HCA, kernel ctrl + user data path |
| Kernel stack bypassed | yes, fully | yes for redirected packets | no (still TCP/IP), fewer syscalls/copies (zero-copy rx in 6.15+) | yes | yes | yes (transport in NIC) |
| NIC still usable by kernel | no (unless bifurcated) | yes (per-queue steering) | yes | partially | partially | yes |
| Memory | hugepages, mbuf pools | UMEM (user memory registered) | user buffers / provided rings | shared rings | | registered MRs |
| Polling | busy poll | poll or `poll()`/wakeup flag | async completion | `poll()`/ioctl sync | | poll CQ or event |
| Ecosystem/features | huge: rte_flow, crypto, eventdev, 50+ NIC drivers | in-kernel, safe, eBPF, upstream | general-purpose apps | simple, BSD heritage | ntop | storage/HPC/AI, RoCE |
| Perf (64B, per core) | highest (tens of Mpps) | close to DPDK in zero-copy mode | far lower (stack) | high | high | high (message-level) |

Teaching points:
- DPDK has an **AF_XDP PMD** (`drivers/net/af_xdp`) and **AF_PACKET PMD** — DPDK apps can run over kernel
  sockets; so "DPDK vs AF_XDP" is partly "PMD over hardware vs PMD over XSK".
- Trade-off axes: performance, isolation/security (kernel retains control with XDP), operational cost
  (dedicated cores, hugepages, NIC unbinding, no `tcpdump`/`ip` tools -> use dpdk-dumpcap/pdump/telemetry),
  portability, features (TCP stack not included).
- When NOT to use DPDK: low-rate apps, need of kernel TCP/sockets, shared NICs w/o bifurcation, power-sensitive
  idle systems, small teams without perf requirements.

---------------------------------------------------------------------------------------------------

## 10. Runnable examples that work on THIS machine (all verified unless marked)

Always: `source /tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh`; `cd $DPDK_SRC/build`.

1. **Hello lcores** (verified):
   `timeout -s INT -k 5 10 ./examples/dpdk-helloworld -l 0-3 --no-huge -m 64 --no-pci --file-prefix=ch01hw`
   -> "hello from core 1/2/3/0" in nondeterministic order (talk about launch order, main lcore).
2. **Skeleton forwarder** (verified): `timeout -s INT -k 5 6 stdbuf -oL ./examples/dpdk-skeleton -l 1 --no-huge -m 128 --no-pci --file-prefix=ch01sk --vdev=net_null0 --vdev=net_null1`
   (needs `stdbuf -oL` or its output is lost when killed; pair ports 0<->1; `ps` shows ~96% CPU).
3. **testpmd io forwarding** (verified ~54.6 Mpps):
   `timeout -s INT -k 5 8 ./app/dpdk-testpmd -l 0-1 --no-huge -m 256 --no-pci --file-prefix=ch01tp --vdev=net_null0 --vdev=net_null1 -- --total-num-mbufs=16384 --stats-period 2 --forward-mode=io`
   (`--total-num-mbufs` is REQUIRED with -m 256: default pool n=155456 fails "Cannot allocate memory").
4. **Kernel vs DPDK cost** (verified): `01-examples/bypass_bench.c` (see §2).
5. **Poll vs interrupt CPU** (verified idle comparison): `01-examples/intr_vs_poll.c` on net_tap (see §4).
6. **Real packets from the kernel into DPDK via veth + af_packet** (verified: 1000 raw frames injected -> RX-total 1000, 512 RX, 488 dropped):
   ```
   ip link add ch01va type veth peer name ch01vb; ip link set ch01va up; ip link set ch01vb up
   timeout -s INT -k 5 16 stdbuf -oL ./app/dpdk-testpmd -l 0-1 --no-huge -m 256 --no-pci --file-prefix=ch01x \
       --vdev=net_af_packet0,iface=ch01va -- --total-num-mbufs=8192 --forward-mode=rxonly --stats-period 1 > out.txt 2>&1 &
   sleep 4; python3 -c "import socket;s=socket.socket(socket.AF_PACKET,socket.SOCK_RAW);s.bind(('ch01vb',0));f=bytes.fromhex('ffffffffffff020000000001'+'88b5')+b'x'*50;[s.send(f) for i in range(1000)]"
   wait; ip link del ch01va
   ```
   Swap `net_af_packet0` for `net_af_xdp0,iface=ch01va` for the AF_XDP comparison (untested with --stats-period; the
   earlier attempt failed only because of the testpmd stdin pitfall below). The 488 drops are themselves a teaching moment (ring sizes, burst draining).
7. **Pipeline model** (verified): `dpdk-packet_ordering` (see §5). Also try `dpdk-distributor`, `dpdk-l2fwd-event`
   (`--mode=eventdev --vdev=event_sw0` vs `--mode=poll`) for RTC vs event comparison (not verified here).
8. **Library map exploration**: `ls $DPDK_SRC/lib`, `pkg-config --libs --static libdpdk | tr ' ' '\n' | grep rte_ | wc -l`,
   `./app/dpdk-testpmd ... -- -i` + `show port info all`; `dpdk-telemetry.py` against a running app's
   `/var/run/dpdk/<prefix>/dpdk_telemetry.v2` socket (`/ethdev/list`, `/eal/lcore/list`).
9. Minimal "my first DPDK program" for chapter 1: EAL init -> count ports (`rte_eth_dev_count_avail()`) ->
   print `rte_version()` -> `rte_eal_cleanup()`; run with `--vdev=net_null0 --vdev=net_ring0`.

---------------------------------------------------------------------------------------------------

## 11. Visualization / animation ideas

1. **Packet-time budget calculator**: slider for link speed + frame size -> ns/packet and cycles/packet bars, overlaid
   with costs of a cache miss, syscall, context switch, interrupt. Animated "conveyor belt" of packets arriving at line rate.
2. **Two-lane path race**: kernel path (IRQ -> softirq -> skb -> stack -> socket -> syscall -> copy) vs DPDK path
   (DMA -> descriptor -> rx_burst -> app); dots travel; per-hop latency labels; batch of 32 moving together in DPDK lane.
3. **Interrupt vs polling timeline**: CPU-usage strip chart; interrupt mode shows sleep/wake spikes and wake-up latency;
   polling shows flat 100% and immediate pickup; toggle traffic rate (low/high) — show NAPI-like crossover and
   adaptive polling. Use the measured numbers (27M empty polls vs 50 wakeups).
4. **Descriptor ring animation**: NIC writes DD bits, PMD harvests a burst, refills with mbufs from mempool cache,
   writes tail doorbell once per burst.
5. **RTC vs pipeline vs eventdev**: three lcore layouts side-by-side; packets as colored flow tokens; RSS hashing to
   queues in RTC; rings between stages in pipeline (show ring filling up = back-pressure, the 115k Tx-enqueue fails);
   scheduler fan-out in eventdev with atomic flows.
6. **Interactive library map**: stacked layers (OS/HW, drivers, EAL, core, device classes, protocol libs, apps); hover a
   box -> one-line description, header file, which chapter covers it; highlight dependencies (mbuf->mempool->ring->EAL).
7. **EAL boot sequence**: step-through animation of `rte_eal_init()` phases with the actual log lines.
8. **Timeline** of DPDK history (2010 -> 26.11) with release cadence change and LTS bands (3-year bars for each .11).
9. **Comparison radar chart**: DPDK / AF_XDP / io_uring / netmap / RDMA on throughput, latency, CPU efficiency,
   kernel integration, ease of use, feature breadth.
10. **Ecosystem graph**: DPDK at center; OVS-DPDK, VPP, SPDK, F-Stack, TRex, Seastar linked with "uses which part".
11. **Fast-path dispatch zoom**: `rte_eth_rx_burst()` -> `rte_eth_fp_ops[port]` -> `rxq.data[q]` -> `rx_pkt_burst` fn ptr.

---------------------------------------------------------------------------------------------------

## 12. Common pitfalls (observed + known)

- **testpmd exits immediately when backgrounded without `--stats-period` or `-i`**: it waits for "Press enter to exit"
  and stdin EOF ends it (we got RX-packets 0 until adding `--stats-period 1`).
- **Memory with `--no-huge -m 256`**: testpmd default mbuf count (155456 × 2176 B ≈ 338 MB) fails -> use
  `--total-num-mbufs=8192..16384`. `packet_ordering` needs ~900 MB.
- **stdout buffering**: examples killed by SIGINT lose buffered output -> `stdbuf -oL`.
- Forgetting `--file-prefix` -> concurrent processes collide on `/var/run/dpdk/rte/` (secondary-process confusion).
- Binding the only/management NIC to vfio-pci kills connectivity (here: NEVER touch eth0).
- net_null numbers are not NIC numbers; tap/af_packet PMDs use syscalls -> not true bypass.
- Polling cores show 100% CPU in `top` even idle — expected, not a bug.
- `rte_eth_tx_burst()` may send fewer than requested — must free/retry the rest (bypass_bench shows the pattern).
- Mixing NUMA sockets (mempool on remote socket vs port) halves performance on real servers.
- IOVA mode: PA requires root + physical addresses; VA needs IOMMU (or vdev-only) — logs "Selected IOVA mode 'VA'".
- Interrupt mode requires PMD support (`nics/features/*.ini` "Rx interrupt"); `net_null`/`net_ring` don't have it.
- Expecting a TCP/IP stack or sockets — DPDK does not provide one (use F-Stack, Seastar, mTCP, VPP host stack).
- Hugepages reserved but not mounted, or `-m` too large for shared pool (here 1024×2 MB shared with other agents).

---------------------------------------------------------------------------------------------------

## 13. Source references

In-tree (DPDK 26.11.0):
- `doc/guides/prog_guide/overview.rst`, `intro.rst`, `source_org.rst`, `env_abstraction_layer.rst`, `perf_opt_guidelines.rst`,
  `writing_efficient_code.rst`, `glossary.rst`, `img/architecture-overview.svg`
- `doc/guides/linux_gsg/linux_drivers.rst` (VFIO/UIO/bifurcated, VFIO cdev), `linux_gsg/sys_reqs.rst` (hugepages)
- `doc/guides/contributing/stable.rst` (LTS), `abi_policy.rst`, `abi_versioning.rst`; `license/README`, `license/exceptions.txt`
- `doc/guides/rel_notes/release_26_11.rst`, `release_16_04.rst`, `release_1_8.rst`; `VERSION`, `ABI_VERSION`
- `doc/guides/nics/features/*.ini` (feature matrix), `doc/guides/nics/overview.rst`
- `lib/eal/linux/eal.c:566` (`rte_eal_init`), `lib/ethdev/rte_ethdev.h:6183` (`rte_eth_rx_burst`), `:6522` (`rte_eth_tx_burst`),
  `lib/ethdev/rte_ethdev_core.h:87` (`struct rte_eth_fp_ops`), `lib/ethdev/rte_ethdev.c:45,1929`, `lib/ethdev/ethdev_private.c:285`
- `drivers/net/null/rte_eth_null.c:88` (`eth_null_rx`), `drivers/net/tap/rte_eth_tap.c:479` (`pmd_rx_burst`)
- `examples/helloworld/main.c`, `examples/skeleton/basicfwd.c`, `examples/l2fwd`, `examples/l3fwd`, `examples/l3fwd-power`,
  `examples/packet_ordering`, `examples/distributor`, `examples/eventdev_pipeline`, `examples/l2fwd-event`, `examples/l3fwd-graph`
- `usertools/dpdk-devbind.py`, `dpdk-hugepages.py`, `dpdk-telemetry.py`

Web:
- DPDK at 15 (history, Venkatesan, 6WIND, governance): https://www.dpdk.org/dpdk-at-15-from-intels-internal-experiment-to-open-source-foundation/
- DPDK history: https://www.dpdk.org/ctl-stories/dpdk-history/ ; About: https://www.dpdk.org/about/
- LF press release (move to Linux Foundation, April 2017): https://www.linuxfoundation.org/press/press-release/networking-industry-leaders-join-forces-to-expand-new-open-source-community-to-drive-development-of-the-dpdk-project
- Release cadence change to 3/yr: https://inbox.dpdk.org/dev/5786413.XMpytKYiJR@thomas/ ; 22.03 announcement https://mails.dpdk.org/archives/dev/2022-March/237619.html
- Roadmap / stable branches: https://core.dpdk.org/roadmap/
- Wikipedia overview: https://en.wikipedia.org/wiki/Data_Plane_Development_Kit
- Suggested further reading for the comparison section: "The eXpress Data Path" (Høiland-Jørgensen et al., CoNEXT 2018);
  netmap (Rizzo, USENIX ATC 2012); "MoonGen" (Emmerich et al., IMC 2015); FD.io VPP docs (fd.io); OVS-DPDK docs (docs.openvswitch.org/en/latest/intro/install/dpdk/); SPDK (spdk.io).

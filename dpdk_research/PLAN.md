# DPDK from Zero to Expert: Building Fast Packet Processing in User Space (DPDK 26.11)

**Audience:** C programmers who know basic networking (Ethernet, IP, UDP, sockets) and Linux, but have never used DPDK. The course takes them from 'why kernel bypass' to multi-core pipelines, writing a PMD, deploying in production, and a small IP router that cooperates with the Linux kernel.

**Target:** DPDK 26.11.0. All examples run on a 4-core VM with virtual devices only (net_null, net_ring, net_pcap, net_tap, af_packet/af_xdp on veth, vhost/virtio_user, memif, crypto/compress/dma/event/baseband/raw software drivers).

**Status:** Revision 2 (second gap review applied; see the Revision 2 changelog at the end). 30 chapters.

## Chapter overview

| # | Folder | Title | Level | Prerequisites |
|---|---|---|---|---|
| 1 | `chapters/01-why-kernel-bypass/` | What Is a Packet, and Why Bypass the Kernel? | beginner | - |
| 2 | `chapters/02-build-and-first-app/` | Building DPDK and Your First Application (Build, Link, main() and Options) | beginner | 1 |
| 3 | `chapters/03-eal-fundamentals/` | The EAL: Lcores, Launching Work, Threads, Logging and Time | beginner | 2 |
| 4 | `chapters/04-memory-hugepages/` | Memory: Hugepages, Memzones, rte_malloc and IOVA | beginner (core) + optional advanced deep dive | 3 |
| 5 | `chapters/05-rings/` | rte_ring: Lock-Free Queues Between Cores | intermediate | 4 |
| 6 | `chapters/06-mempools/` | rte_mempool and rte_stack: Fixed-Size Allocation at Line Rate | intermediate | 5 |
| 7 | `chapters/07-mbufs/` | rte_mbuf: The Packet Buffer | intermediate | 6 |
| 8 | `chapters/08-ethdev-first-port/` | Your First Port: ethdev Lifecycle and the Burst API | intermediate | 7 |
| 9 | `chapters/09-virtual-devices-testpmd/` | Testing Without Hardware: Buses, devargs, Virtual PMDs and testpmd | intermediate | 8 |
| 10 | `chapters/10-packet-headers-l2fwd/` | Parsing and Building Packets: lib/net, Checksums and l2fwd | intermediate | 9 |
| 11 | `chapters/11-eal-services-timers/` | EAL Services in One Evolving App: Timers, Service Cores, Alarms, Keepalive, a Control Shell and App Options | intermediate | 3, 8, 10 |
| 12 | `chapters/12-port-control-stats-events/` | Port Control, Statistics, Events, Live Reconfiguration and Composite PMDs | intermediate | 8, 9, 10, 11 |
| 13 | `chapters/13-observability-debugging/` | Observability and Debugging: Telemetry, Metrics, Tracing, Logs, gdb and Post-Mortem Analysis | intermediate | 3, 7, 8, 9, 11, 12 |
| 14 | `chapters/14-concurrency-atomics-rcu/` | Concurrency: Atomics, Memory Ordering, Locks and RCU | advanced | 5, 6, 11, 12 |
| 15 | `chapters/15-scale-out-rss-pipelines/` | Scaling Out Across Cores: Multi-Queue, RSS and Toeplitz, Run-to-Completion vs Pipeline, Distributor and Reorder | advanced | 5, 6, 7, 9, 12, 14 |
| 16 | `chapters/16-multi-process-capture/` | Multi-Process DPDK and Packet Capture: Primary/Secondary, IPC, dumpcap, pcapng and proc-info | advanced | 4, 5, 6, 7, 12, 13, 14 |
| 17 | `chapters/17-hash-exact-match/` | Exact-Match Lookup: rte_hash, Toeplitz, EFD and Member | advanced | 7, 10, 14 |
| 18 | `chapters/18-lpm-fib-acl/` | Routing and Classification: LPM, RIB, FIB, ACL and l3fwd | advanced | 14, 15, 17 |
| 19 | `chapters/19-offloads-gso-gro-frag/` | Offloads, Timestamps and Packet Transforms: Checksums, TSO, PTP, GSO, GRO and IP Fragmentation | advanced | 10, 12 |
| 20 | `chapters/20-rte-flow-steering/` | rte_flow: Classifying and Steering Traffic in Hardware (and the E-Switch Model) | advanced | 12, 15, 19 |
| 21 | `chapters/21-qos-meter-sched/` | QoS: Metering, Policing, Hierarchical Scheduling and Their Hardware Offloads | advanced | 10, 18, 20 |
| 22 | `chapters/22-performance-engineering/` | Performance Engineering: Cycles, Caches, Batching, SIMD, NUMA and Power | expert | 8, 14, 15 |
| 23 | `chapters/23-inside-a-pmd/` | Inside a Poll Mode Driver: Descriptor Rings, Vector Paths, eth_dev_ops, Buses, VFIO and Writing Your Own vdev PMD | expert | 8, 9, 12, 22 |
| 24 | `chapters/24-virtio-vhost-memif/` | Virtio, vhost-user and memif: Networking Between VMs, Containers and Processes | expert | 9, 12, 13, 16, 23 |
| 25 | `chapters/25-eventdev-pipelines/` | Event-Driven Scheduling: eventdev, Adapters, Event Vectors and the Dispatcher | expert | 11, 14, 15 |
| 26 | `chapters/26-cryptodev-ipsec/` | Lookaside Crypto: cryptodev, rte_security and IPsec | expert | 7, 11, 18, 19, 25 |
| 27 | `chapters/27-other-accelerators/` | Other Lookaside Accelerators: compressdev, dmadev and the DMA Adapter, bbdev, mldev/gpudev/regexdev and rawdev | expert | 7, 11, 25, 26 |
| 28 | `chapters/28-graph-bpf-swx/` | Programmable Data Planes: graph/node, BPF and the SWX Pipeline | expert | 14, 15, 18, 19 |
| 29 | `chapters/29-production-operations/` | Running DPDK in Production: System Setup, Containers, Hardening, Testing, Releases and Contributing | expert | 4, 10, 12, 13, 16, 22, 23 |
| 30 | `chapters/30-capstone-ip-router/` | Capstone: A Tiny IP Router That Lives Next to the Kernel | expert | 10, 11, 12, 13, 15, 16, 17, 18, 19, 21, 22, 24 |

## Design notes

Structure: 30 chapters in four bands — 1-4 beginner, 5-13 intermediate, 14-21 advanced, 22-30 expert — in strict easy -> complex order. Every prerequisite points to an earlier chapter, so authors can write in parallel. Full human-readable plan: /home/user/ai_lab/dpdk_research/PLAN.md (Revision 2); machine-readable full plan: /tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/plan_r2.json (generated by revise2.py + render2.py in the same folder). Chapter count: Revision 2 accepts the two high-severity split findings (observability vs multi-process, crypto vs other accelerators), which takes the course from 28 to 30 chapters — the upper bound the user set ("between 10 to 30"). Compensating merges were evaluated and rejected because every candidate pair would recreate an overloaded chapter. If the orchestrator must hold 28, the least harmful fallback is to fold ch27 into ch26 as a 'Part 2' and ch16's capture half into ch13, but that re-opens the overload findings.

Spiral thread and milestones: ch2 ends with a 'first look' testpmd run on net_null; ch3-ch8 open with the 'skeleton x-ray' of examples/skeleton/basicfwd.c; ch11 grows one app step by step; band reviews with a predict-then-reveal quiz close ch4, ch13 and ch21, and ch13 and ch21 also carry a band project (ch13: multi-core L2 forwarder with per-lcore stats, timer report, telemetry endpoint and shell; ch21: L3 forwarder with LPM, an ACL drop list and a per-flow meter), each with solution code and a run.sh acceptance check that prints PASS/FAIL. The ch30 capstone reuses both projects and gives every stage an acceptance test.

Boundaries (who owns what; others link):
- ch1 motivation (benchmarks are 'peek ahead'); ch2 build/link, --whole-archive, main() anatomy, getopt after --, first look (tunables and LTO are collapsed reference boxes); ch3 EAL init, lcores, launch, logging, time, 'how to measure on this machine'; ch4 memory (core + optional deep dive incl. rte_dev_dma_map for external memory) and the startup-error catalogue part 1.
- ch5 ring (atomics primer box), ch6 mempool + rte_stack (owns the LF-stack ABA widget; ch14 embeds it and adds only the 128-bit CAS fix), ch7 mbuf, ch8 ethdev lifecycle, burst API, simplified descriptor ring, 'when it doesn't work' box and port-init errors.
- ch9 buses/devargs/kvargs, software PMDs, testpmd (all forward modes, recipes, 'testpmd as a debugger' and the cheat-sheet), 'on real hardware' devbind sidebar; ch10 lib/net, checksums, __rte_packed_begin/end, l2fwd; ch11 the evolving app (rte_timer, service cores, alarms, keepalive, jobstats, cmdline, rte_argparse, rte_cfgfile) plus the EAL toolbox reference appendix.
- ch12 port control, 26.11 stats model, events/callbacks, hotplug, per-queue start/stop, deferred start, runtime queue setup, live reconfiguration, graceful shutdown, failure/recovery incl. err_handle_mode, bonding/failsafe vs aggregated ports. ch13 telemetry (+exporter), metrics/latency/bitrate, trace, RTE_LOG_DP, dpdk-ethtool, gdb, ASan, core-dump post-mortem, debug labs, the consolidated startup-error table, band 2.
- ch14 atomics, memory ordering, locks (+static lock checking), RCU, per-lcore data and lcore variables, false sharing/MESI. ch15 multi-queue, RSS, RETA, rte_thash/Toeplitz, hash algorithms and levels, RTC vs pipeline, ptr_compress, distributor, reorder, SORING revisited. ch16 multi-process, IPC, MP hotplug, pdump/pcapng/dumpcap, capture cost, proc-info, MP startup errors.
- ch17 rte_hash/fbk/EFD/member (no Toeplitz); ch18 LPM/RIB/FIB/ACL + l3fwd + test-fib/test-acl built from source; ch19 offloads, buffer split, IP reassembly offload, tunnel ports, timestamps/PTP, GSO/GRO/ip_frag; ch20 rte_flow, advanced/indirect actions, template/async, DCB/VMDq, switch representation and representors; ch21 software QoS + rte_mtr/rte_tm, band 3.
- ch22 measurement methodology, app-level performance (layout, prefetch, branch hints, SIMD, rte_memcpy), Rx interrupts from scratch, power, isolation checks, profiling without perf; ch23 descriptor rings, doorbell ordering (rte_io_wmb), vector PMD paths, PMD internals, buses/VFIO, NIC qualification incl. the physical-port knobs table; ch24 virtio/vhost/memif; ch25 eventdev (+capabilities, adapters, vectors, dispatcher); ch26 cryptodev/security/IPsec + crypto adapter; ch27 compressdev/dmadev (+DMA adapter)/bbdev/gpudev/mldev/regexdev/rawdev; ch28 graph/node, BPF, SWX (+softnic pointer); ch29 production (system setup, permissions, systemd/containers as text + unshare, hardening/fuzzing, CI testing, golden-signals runbook, VMs/cloud, restart budget, releases/ABI, contributing, atlas); ch30 capstone router.

Library assignment: eal (ch3, ch4, ch11, ch14), log (ch3, ch13), kvargs (ch9), argparse/cfgfile (ch11), telemetry (ch13), ring (ch5), mempool/stack (ch6), mbuf (ch7), net (ch10), ethdev (ch8, ch12, ch15, ch19, ch20; mtr/tm ch21), pci/vfio (ch23), hash/efd/member (ch17), thash (ch15), lpm/rib/fib/acl (ch18), ip_frag/gso/gro (ch19), meter/sched (ch21), distributor/reorder/ptr_compress (ch15), timer/jobstats/cmdline (ch11), rcu (ch14), power/pmu (ch22), metrics/latencystats/bitratestats (ch13), pdump/pcapng (ch16), vhost (ch24), eventdev/dispatcher (ch25), cryptodev/security/ipsec/pdcp (ch26), compressdev/dmadev/bbdev/gpudev/mldev/regexdev/rawdev (ch27), bpf/graph/node/pipeline/port/table (ch28). Every examples/ program, app/ tool and usertools script appears in the ch29 atlas.

Shared conventions for all chapter authors:
- Folder chapters/NN-slug/ with index.html, README.md, code/{*.c, Makefile, run.sh, expected_output.txt} plus helper .py/.pcap generators; code/solutions/ (or hints) for easy and medium exercises.
- Makefile: CFLAGS += -O2 -Wall $(shell pkg-config --cflags libdpdk) [-DALLOW_EXPERIMENTAL_API]; LDLIBS = $(shell pkg-config --libs --static libdpdk). run.sh sources the env script, runs make, runs each example under timeout -s INT -k 5 <=20 with stdbuf -oL, a unique --file-prefix=chNN-<name>, --no-pci, and cleans up in a trap (background jobs, veth/netns/tap it created, sockets, /run/dpdk/<prefix>, /dev/hugepages/<prefix>map_*).
- Memory: --no-huge -m <=256 for course programs. Hugepages only when the topic needs them: -m 64..128 max, and -m 64 for primaries that secondaries attach to (dumpcap and proc-info need a hugepage primary; a --no-huge primary makes them fail with 'is primary process running?'). With --no-huge, -m is ordinary memory, so shipped samples that size pools from fixed constants may use up to -m 1024. Verified table: dpdk-ethtool -m 640 (-m 128..512 fail with 'rte_pktmbuf_pool_create failed'), dpdk-distributor -m 640 with --lcores='(0-4)@(0-3)' (5 lcores needed), dpdk-packet_ordering -m 384 (-m 256 fails), dpdk-l3fwd-graph -m 640, dpdk-graph -m 640. A SIGINT-stopped hugepage primary can leave map_* files: the trap must remove them.
- Prebuilt samples are NOT on PATH: call them as $DPDK_SRC/build/examples/dpdk-<name> (set E=$DPDK_SRC/build/examples in run.sh). 46 example binaries are built (the earlier '90' counted .p directories); examples not built (e.g. l2fwd-cat) are marked 'not built' in the ch29 atlas. dpdk-install/bin (on PATH) holds testpmd, dumpcap, pdump, proc-info, graph, test-eventdev, test-crypto-perf, test-flow-perf and the usertools.
- Tools that must be built from app/ sources in the chapter Makefile (verified): dpdk-test-fib (gcc -O2 -DALLOW_EXPERIMENTAL_API -I$DPDK_SRC/lib/eal/linux/include app/test-fib/main.c + static pkg-config flags), dpdk-test-acl and dpdk-test-sad (same, without the extra -I), dpdk-validate-bpf (-DALLOW_EXPERIMENTAL_API -DALLOW_INTERNAL_API -I$DPDK_SRC/lib/bpf app/validate-bpf/*.c). Not built and not buildable here without effort: dpdk-test (unit tests), test-security-perf, fips_validation, wycheproof_validation; test-dma-perf and test-compress-perf get one build attempt in ch27.
- EAL options: never -c or -s (deprecated); use -l and -S <corelist>, with service lcores also in -l.
- testpmd: every invocation passes --total-num-mbufs=4096..16384 (the default 155456-mbuf pool fails in --no-huge -m 256 with 'Creation of mbuf pool for socket 0 failed: Cannot allocate memory'); a background testpmd needs --stats-period N (stopped with SIGINT) or -i fed from a FIFO, otherwise it reads EOF and exits; --no-flush-rx with pcap rx.
- Strip ANSI colour codes (sed 's/\x1b\[[0-9;]*m//g') from tool output before saving expected_output.txt (dpdk-test-eventdev prints coloured 'Result: Success').
- Interface names: chNNtap*, veth chNNa/chNNb (or chNNva/chNNvb), netns chNNns*, IPs 10.NN.x.y. Never touch eth0. af_xdp on veth prints benign libxdp warnings (no bpffs, no dispatcher): say so next to the output.
- Traffic: no tcpdump/ping/scapy here; use Python raw sockets (research/06-examples/sendraw.py, mkpcap.py, research/07-examples/gen_pcap.py) run with python3 -I. Real multi-queue steering: net_af_packet qpairs=N,fanout_mode=hash on a veth (kernel flow hash, not Toeplitz). net_null per-queue counters are poll-driven: use it only for RETA API calls and load numbers.
- Unsupported features are lessons: capture the real error (ENOTSUP, ENOSYS, rte_flow_error) and explain it. Known here: rte_flow create/isolate fail on tap; tap has no RETA and does RSS only via the flow RSS action with the enable_tap_rss BPF build option (not built); no cpufreq/WAITPKG/PMU/perf; no mldev/gpudev/regexdev drivers; OpenSSL 3.0.13 limits asymmetric algorithms; no systemd as PID 1 and no Docker daemon (lint units with systemd-analyze verify, show containers with unshare); clang sanitizer/libFuzzer runtimes are missing (use gcc -fsanitize=address,undefined); ptp4l and pahole are absent (use gdb 'ptype /o'); dpdk-graph's l2fwd_pcap.cli fails with err=-22.
- Measurements: median of N>=5 with min/max, bounded runs, no oversubscription unless that is the experiment, no predicted numbers, VM/software-PMD numbers labelled as such.
- expected_output.txt is real captured output (trim, never invent).
- Visualizations: inline SVG + vanilla JS, theme-aware via ../../assets/course.css variables, offline from file://. At least two counted interactives per chapter; a counted interactive reacts to learner input and shows internal state; core mechanisms get 'predict, then step'. A mechanism widget is owned by one chapter and embedded or linked elsewhere (ABA: ch6; checksum folding: ch10; Toeplitz: ch15; MESI/false sharing: ch14).
- Each chapter: exercises tagged [easy]/[medium]/[stretch]; a 5-question check widget; a 'Tools for this chapter' box.
- Cross-references: write 'chNN' with the Revision 2 numbers. Before finishing, grep your chapter for 'ch[0-9]' and check each target against the boundaries above.
- Accuracy (check every API against $DPDK_SRC/lib for 26.11): removed rte_atomic32 and rte_smp_*mb (CPU-to-CPU ordering uses rte_atomic_thread_fence / release-acquire; CPU-to-device ordering uses rte_io_wmb/rte_io_rmb or rte_write32); RTE_ETH_ prefixes; struct rte_ipv6_addr; bonding 'member'; crypto session API since 22.11; mempool cache no longer limited by RTE_MEMPOOL_CACHE_MAX_SIZE; rte_eth_stats has no per-queue arrays and queue-stats mapping was removed (per-queue counters are xstats); rte_vfio_* is internal (rte_dev_dma_map is the public DMA-map path) and VFIO has a cdev/IOMMUFD mode; lcore variable macros RTE_LCORE_VAR_HANDLE/ALLOC, RTE_LCORE_VAR, RTE_LCORE_VAR_LCORE, RTE_LCORE_VAR_FOREACH (no RTE_LCORE_VAR_VALUE); RTE_IP_ICMP_ECHO_* removed (RTE_ICMP_TYPE_ECHO_*); RTE_PTR_ADD/SUB no longer take integers; __rte_packed removed -> 'struct __rte_packed_begin foo {...} __rte_packed_end;'; unaligned_uint16/32/64_t now have alignment 1; rte_fast_rand removed from sched/RED (use rte_rand); rte_metrics_telemetry.h and rte_metrics_tel_* removed; the legacy pipeline/table/port API, the rte_table_action API, examples/ip_pipeline and app/test-pipeline removed (examples/pipeline is the SWX replacement); rte_graph_worker_model_set; SWX via rte_swx_pipeline_codegen + rte_swx_pipeline_build_from_lib; -c/-s deprecated.
- Internal headers: ethdev_driver.h / bus_vdev_driver.h are not installed; ch23 builds net_toy with -DALLOW_INTERNAL_API -I$DPDK_SRC/lib/ethdev -I$DPDK_SRC/drivers/bus/vdev -I$DPDK_SRC/lib/eal/include (verified). rte_eth_from_rings is in drivers/net/ring/rte_eth_ring.h and rte_eth_bond_* in drivers/net/bonding/rte_eth_bond.h (installed).

## 01. What Is a Packet, and Why Bypass the Kernel?

*Folder:* `chapters/01-why-kernel-bypass/` · *Level:* beginner · *Prerequisites:* none

Motivates the whole course: what an Ethernet frame is on the wire, the per-packet time budget at 10/25/100/400 GbE, where the Linux kernel spends its cycles, and the five techniques DPDK uses to go faster (user-space drivers, polling, hugepages, lock-free rings and pools, bursts and SIMD). Ends with the DPDK architecture map, history, ecosystem, alternatives such as AF_XDP, and when not to use DPDK. Narrative-heavy, with three tiny runnable demos. Only hello_dpdk.c and the prebuilt helloworld are code the reader is expected to understand now; the two benchmarks are 'run and observe' peeks ahead whose full source sits in a collapsible section.

**Concepts**

- Ethernet frame anatomy: preamble+SFD, header, payload, FCS, inter-frame gap; 64 B minimum frame = 84 B on the wire
- Line-rate arithmetic: 14.88 Mpps at 10 GbE/64 B; ns and CPU cycles per packet (2.7 GHz here: 181 cycles at 10G, 18 at 100G)
- Cost of the kernel receive path: IRQ, NAPI softirq, sk_buff allocation, protocol stack, socket queue, syscall, copy, context switch
- Costs of a cache miss, syscall, context switch, interrupt compared with the per-packet budget
- The five DPDK techniques and which library implements each (bus/pci+VFIO, PMDs, EAL memory, ring/mempool, mbuf bursts/SIMD)
- Poll mode vs interrupts: 100% CPU, latency, power trade-off (preview of l3fwd-power)
- Execution models: run-to-completion, pipeline (rings between lcores), event-driven (eventdev)
- DPDK architecture and library map: EAL -> core libs -> device classes (ethdev, cryptodev, eventdev, dmadev, ...) -> drivers -> apps
- DPDK provides no TCP/IP stack and no sockets (F-Stack, Seastar, VPP host stack do)
- History and governance: Intel 2010, 6WIND/dpdk.org 2013, Linux Foundation 2017; YY.MM versions, 3 releases/year, .11 LTS, BSD-3 licence
- Ecosystem: OVS-DPDK, FD.io VPP, SPDK, TRex, Pktgen, F-Stack, Suricata, cloud vSwitches
- Alternatives: XDP/AF_XDP, netmap, io_uring, PF_RING ZC, RDMA/verbs; when NOT to use DPDK
- Course thread: the 'skeleton x-ray' — one forwarding loop (examples/skeleton/basicfwd.c) that every chapter up to ch8 fills in

**APIs**

`rte_eal_init`, `rte_eal_cleanup`, `rte_version`, `rte_eth_dev_count_avail`, `rte_rdtsc`, `rte_get_tsc_hz`, `rte_eth_rx_burst (preview)`, `rte_exit`

**Runnable code examples**

- **hello_dpdk.c** — Smallest possible DPDK program: rte_eal_init, print rte_version(), rte_lcore_count() and rte_eth_dev_count_avail(), rte_eal_cleanup.  
  Run here: `./hello_dpdk -l 0 --no-pci --no-huge -m 64 --file-prefix=ch01-hello --vdev=net_null0 --vdev=net_ring0 (expect 2 ports)`
- **dpdk-helloworld (prebuilt)** — Run the shipped helloworld on 4 lcores to see nondeterministic 'hello from core N' ordering.  
  Run here: `timeout -s INT -k 5 10 $DPDK_SRC/build/examples/dpdk-helloworld -l 0-3 --no-huge -m 64 --no-pci --file-prefix=ch01-hw`
- **bypass_bench.c** — PEEK AHEAD (run and observe; you can write this by ch8): kernel vs DPDK cost, N UDP sendto()/recv() on loopback vs N packets through net_null rx/tx bursts; prints ns/packet and cycles/packet (median of 5 runs). The HTML embeds only the measured output and one annotated 10-line excerpt; the full source goes in a collapsed 'peek ahead' block. Based on research/01-examples/bypass_bench.c.  
  Run here: `./bypass_bench -l 0 --no-pci --no-huge -m 128 --file-prefix=ch01-bb --vdev=net_null0`
- **intr_vs_poll.c** — PEEK AHEAD (run and observe; Rx interrupts are built from scratch in ch22's rx_intr.c lab): interrupt (epoll on rx intr) vs busy-poll loop on an idle net_tap port: empty polls, wakeups and CPU time via getrusage. Output plus a 10-line excerpt in the flow; full source collapsed. Based on research/01-examples/intr_vs_poll.c.  
  Run here: `./intr_vs_poll -l 0 --no-pci --no-huge -m 128 --file-prefix=ch01-ivp --vdev=net_tap0,iface=ch01tap0 (tap disappears on exit)`

**Visualizations**

- **Packet-time budget calculator** (interactive) — Sliders for link speed (1-400 GbE) and frame size (64-1518 B) -> pps, ns/packet, cycles/packet at a chosen GHz; bars overlaid with the cost of an L1/LLC/DRAM access, syscall, context switch, interrupt.
- **Two-lane path race** (animation) — Kernel lane (NIC DMA -> IRQ -> softirq -> sk_buff -> IP/UDP -> socket -> syscall -> copy) vs DPDK lane (DMA -> descriptor -> rx_burst -> app); dots travel with per-hop latency labels; DPDK lane moves batches of 32.
- **Interrupt vs polling CPU timeline** (animation) — Strip chart of CPU usage and wake-up latency under low and high load; toggle traffic rate; uses measured numbers from intr_vs_poll. Learner drags the offered packet rate; CPU %, wakeups and latency counters update.
- **DPDK layer cake / library map** (interactive diagram) — Stacked SVG layers (HW/OS, drivers, EAL, core libs, device classes, protocol libs, apps); hover a box for a one-line description, header and the course chapter that covers it.
- **Frame on the wire** (diagram) — Byte-accurate SVG of an Ethernet frame including preamble/IFG overhead.
- **DPDK history timeline** (diagram) — 2010 -> 26.11 with release cadence change and 3-year LTS bars.

**Exercises**

1. [easy] Compute pps and cycles/packet for 25 GbE with 128 B frames at 3.0 GHz; how many DRAM misses fit?
2. [medium] Change bypass_bench to use bursts of 1, 8, 32 on net_null and plot cycles/packet.
3. [medium] List three workloads where AF_XDP or plain sockets are a better choice than DPDK, and why.
4. [stretch] Using `ls $DPDK_SRC/lib` and `pkg-config --libs --static libdpdk`, count libraries and map five of them onto the layer cake.

**Sources**

- doc/guides/prog_guide/intro.rst
- doc/guides/prog_guide/overview.rst
- doc/guides/prog_guide/source_org.rst
- doc/guides/linux_gsg/linux_drivers.rst
- doc/guides/contributing/stable.rst
- doc/guides/rel_notes/release_26_11.rst
- examples/helloworld/main.c
- lib/ethdev/rte_ethdev.h (rte_eth_rx_burst)
- /home/user/ai_lab/dpdk_research/research/01-overview-history-architecture.md
- https://www.dpdk.org/about/
- Hoiland-Jorgensen et al., The eXpress Data Path, CoNEXT 2018

## 02. Building DPDK and Your First Application (Build, Link, main() and Options)

*Folder:* `chapters/02-build-and-first-app/` · *Level:* beginner · *Prerequisites:* ch1

How the DPDK source tree is organised, how meson/ninja build and install it, and how an external application consumes it through pkg-config. The core of the chapter is static linking and the --whole-archive constructor pitfall, main() anatomy and the -- separator, and a 'first look' testpmd run on net_null. Build-time tunables and LTO are collapsed reference boxes. Option-parsing libraries moved out: kvargs is taught next to devargs in ch9, rte_argparse and rte_cfgfile in ch11's evolving app.

**Concepts**

- Source tree layout: lib/, drivers/, app/, examples/, usertools/, buildtools/, doc/, config/
- meson setup/configure/compile/install; key options (buildtype, platform, cpu_instruction_set, enable_drivers, disable_libs, examples, tests, enable_iova_as_pa)
- Generated rte_build_config.h and the installed layout (headers, static/shared libs, pmds-ABI dir, bin tools)
- pkg-config libdpdk: --cflags, --libs, --static; why static links need --whole-archive (RTE_INIT constructors / RTE_PMD_REGISTER_* registration)
- Static vs shared apps: LD_LIBRARY_PATH, plugin directory, -d option, EAL's world-writable-parent check (fails here under /tmp)
- Using DPDK from a Makefile and from your own meson project (dependency('libdpdk'))
- -march=native vs generic builds; portability
- ALLOW_EXPERIMENTAL_API and __rte_experimental; ALLOW_INTERNAL_API (preview)
- Anatomy of main(): rte_eal_init returns consumed-arg count; argc -= ret; argv += ret; EAL args -- app args
- rte_exit vs return; rte_eal_cleanup; minimal EAL sandbox flags (--no-pci --no-huge -m --file-prefix)
- Inspecting a binary: dpdk-pmdinfo.py, which PMDs are linked in
- ABI_VERSION, sonames and the YY.MM version macros (RTE_VERSION, rte_version())
- [Reference box, collapsed] Build-time tunables table (config/rte_config.h and meson options) with the chapter that uses each: max_lcores, max_numa_nodes, RTE_MEMPOOL_CACHE_MAX_SIZE (lost its limit meaning in 26.11, ch6), RTE_LIBRTE_MBUF_DEBUG (ch7/ch13), RTE_ENABLE_TRACE_FP (ch13), RTE_GRAPH_PROFILE (ch28)
- [Reference box, collapsed] LTO in one paragraph: -Db_lto=true, why it can inline across libraries (prog_guide/lto.rst)
- Other platforms: Windows and FreeBSD guides, cross-building for Arm (pointers only)
- Application options after the -- separator with plain getopt (rte_argparse and rte_cfgfile come in ch11, kvargs with devargs in ch9)
- First look: run dpdk-skeleton / testpmd io on two net_null ports and read Mpps; the 'skeleton x-ray' diagram marks which line each of ch3-ch8 explains

**APIs**

`rte_eal_init`, `rte_eal_cleanup`, `rte_exit`, `rte_version`, `RTE_VERSION_NUM`, `rte_eth_dev_count_avail`

**Runnable code examples**

- **hello.c + Makefile** — helloworld rewritten from scratch with comments (the launch call carries a one-line 'launch details in ch3' comment), built by a Makefile using pkg-config (static).  
  Run here: `make && ./hello -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch02-hello`
- **args.c** — Demonstrates argc/argv shifting: EAL args before --, app args (e.g. --count N --name X) parsed with getopt after; prints what each layer saw.  
  Run here: `./args -l 0 --no-pci --no-huge -m 64 --file-prefix=ch02-args -- --count 3 --name demo`
- **whole_archive_pitfall** — Same port-counting program linked twice: correctly (pkg-config --static, with --whole-archive) -> 2 ports; and deliberately without --whole-archive -> 0 ports. Shows why constructors matter.  
  Run here: `make pitfall && ./ports_ok ... --vdev=net_null0 --vdev=net_ring0 ; ./ports_broken ... (same args)`
- **shared build demo** — Same hello.c linked against the shared libraries. First capture the real failure: EAL refuses the plugin directory because /tmp (a parent of the install dir) is world-writable ('Cannot init plugins'); -d with a non-/tmp dir does not help because the compiled-in PMD path is still checked. Then show the fix in a private mount namespace (verified, ports=1), which teaches why EAL refuses insecure plugin paths.  
  Run here: `make shared; LD_LIBRARY_PATH=$(pkg-config --variable=libdir libdpdk) ./hello_shared -l 0 --no-pci --no-huge -m 64 --in-memory --vdev=net_null0 (captured failure); then: unshare -m sh -c 'mkdir -p /run/x && mount --bind /tmp /run/x && mount -t tmpfs -o mode=0755 tmpfs /tmp && mkdir -p /tmp/claude-0 && mount --bind /run/x/claude-0 /tmp/claude-0 && LD_LIBRARY_PATH=<libdir> ./hello_shared -l 0 --no-pci --no-huge -m 64 --in-memory --vdev=net_null0' (prints ports=1)`
- **mesonapp/** — A two-file meson project consuming dependency('libdpdk', static linking flags handled correctly) — reuse research/10-examples/mesonapp.  
  Run here: `meson setup build && ninja -C build && ./build/app -l 0 --no-pci --no-huge -m 64 --file-prefix=ch02-meson`
- **first_look.sh** — Spiral 'first look' lab: run the prebuilt dpdk-skeleton and testpmd io forwarding on two net_null ports for a few seconds and read the packet counters and Mpps; no code to understand yet.  
  Run here: `timeout -s INT -k 5 8 stdbuf -oL $DPDK_SRC/build/app/dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch02-first --vdev=net_null0 --vdev=net_null1 -- --total-num-mbufs=8192 --stats-period 2 --forward-mode=io`

**Visualizations**

- **From source to your binary** (diagram) — Pipeline: meson setup -> ninja -> librte_*.a -> install -> libdpdk.pc -> gcc $(pkg-config ...) -> your app; each stage lights up with the real command. (Static diagram; not one of the counted interactive widgets.)
- **Constructors before main()** (animation) — Timeline showing RTE_INIT constructors (log, bus, class, PMD registration) running before main(), and how a missing --whole-archive drops them so no PMD registers. Learner toggles --whole-archive and predicts how many ports register before stepping.
- **Command-line splitter** (interactive) — Paste a DPDK command line; the widget colours EAL options, the -- separator and app options, and explains each EAL flag.
- **Installed layout tree** (diagram) — Directory tree of the install prefix (include, lib, pmds-27.0, bin, share/dpdk/examples).
- **Skeleton x-ray** (diagram) — basicfwd.c with each line tagged by the chapter that explains it (ch3 EAL, ch4 memory, ch6 mempool, ch7 mbuf, ch8 ethdev); reused at the top of ch3-ch8 with that chapter's lines highlighted.

**Exercises**

1. [easy] Add an app option --verbose parsed after -- and make it print every EAL lcore.
2. [medium] Use dpdk-pmdinfo.py on your static binary and list the net PMDs it contains.
3. [medium] Write a meson.build for a project with two .c files and an experimental API call; make it compile without warnings.
4. [stretch] Explain in two sentences why the shared build fails on this machine and how a real deployment avoids it.

**Sources**

- doc/guides/prog_guide/build-sdk-meson.rst
- doc/guides/prog_guide/build_app.rst
- doc/guides/linux_gsg/build_dpdk.rst
- meson_options.txt
- examples/helloworld/main.c
- lib/eal/include/rte_eal.h
- lib/eal/include/rte_version.h
- lib/eal/common/eal_common_options.c (verify_perms, plugins)
- usertools/dpdk-pmdinfo.py
- ABI_VERSION
- VERSION
- /home/user/ai_lab/dpdk_research/research/10-building-debugging-ecosystem.md
- doc/guides/prog_guide/lto.rst
- config/rte_config.h
- doc/guides/windows_gsg/index.rst
- doc/guides/freebsd_gsg/index.rst
- doc/guides/linux_gsg/cross_build_dpdk_for_arm64.rst
- examples/skeleton/basicfwd.c

## 03. The EAL: Lcores, Launching Work, Threads, Logging and Time

*Folder:* `chapters/03-eal-fundamentals/` · *Level:* beginner · *Prerequisites:* ch2

The Environment Abstraction Layer from the application's view: what rte_eal_init does step by step, the EAL command line, the difference between an lcore and a CPU, the -l/--lcores mapping syntax, launching functions on worker lcores and the WAIT/RUNNING state machine, control threads vs EAL threads vs registered non-EAL threads, the logging system, TSC time, signal handling and clean shutdown.

**Concepts**

- What the EAL abstracts: memory, cores, devices/buses, time, interrupts, IPC, logging
- rte_eal_init phases (option parsing, hugepage info, memory init, bus scan, IOVA decision, threads, probe) with real debug log lines
- EAL option groups: lcore, memory, device (-a/--allow, -b/--block, --vdev; details in ch9), multi-process, logging, debug; --file-prefix and --in-memory on shared machines
- lcore id vs CPU id; -l list syntax, --lcores '@' and groups, --main-lcore, -R/--remap-lcore-ids; deprecated in 26.11: -c (coremask, use -l) and -s (service coremask, use -S)
- lcore roles: ROLE_RTE, ROLE_SERVICE, ROLE_NON_EAL, ROLE_OFF; query API
- rte_eal_remote_launch / rte_eal_mp_remote_launch (CALL_MAIN/SKIP_MAIN), rte_eal_wait_lcore / mp_wait_lcore, return values, -EBUSY
- Worker state machine WAIT -> RUNNING -> WAIT (FINISHED no longer exists)
- Threads: main and worker lcores, control threads (dpdk-intr, dpdk-mp-msg, telemetry), rte_thread_create_control, rte_thread_register for non-EAL threads
- Per-lcore TLS: RTE_DEFINE_PER_LCORE / RTE_PER_LCORE (lcore variables are taught in ch14)
- Logging: rte_log, RTE_LOG, RTE_LOG_LINE (no trailing \n), RTE_LOG_REGISTER / _SUFFIX, logtypes, --log-level patterns, --log-timestamp, --log-color, rte_openlog_stream, --syslog
- Time: rte_rdtsc, rte_rdtsc_precise, rte_get_tsc_hz, rte_get_timer_cycles/hz, rte_delay_us_block vs rte_delay_us_sleep
- Signal handling with an atomic quit flag; never call DPDK functions in signal handlers
- Shutdown: rte_eal_cleanup, leftover runtime and hugepage files, reading EAL error messages
- How to measure on this machine (box reused by every later benchmark): warm up, repeat N>=5 times, report median and min/max, never oversubscribe CPUs unless that is the experiment, expect noise from other processes on this shared 4-core VM, and never quote a number you did not measure

**APIs**

`rte_eal_init`, `rte_eal_cleanup`, `rte_lcore_id`, `rte_lcore_count`, `rte_get_main_lcore`, `rte_lcore_to_cpu_id`, `rte_lcore_to_socket_id`, `rte_eal_lcore_role`, `rte_lcore_is_enabled`, `RTE_LCORE_FOREACH`, `RTE_LCORE_FOREACH_WORKER`, `rte_eal_remote_launch`, `rte_eal_mp_remote_launch`, `rte_eal_wait_lcore`, `rte_eal_mp_wait_lcore`, `rte_eal_get_lcore_state`, `rte_thread_register`, `rte_thread_unregister`, `rte_thread_create_control`, `rte_lcore_dump`, `RTE_DEFINE_PER_LCORE`, `RTE_LOG_REGISTER_SUFFIX`, `RTE_LOG_LINE`, `rte_log_set_level_pattern`, `rte_openlog_stream`, `rte_rdtsc`, `rte_get_tsc_hz`, `rte_delay_us_block`, `rte_delay_us_sleep`

**Runnable code examples**

- **eal_tour.c** — Launch a work function on each worker that returns a distinct value; collect return codes with rte_eal_wait_lcore; print lcore->cpu/socket/role; register a pthread as non-EAL lcore (id -1 -> 3); rte_lcore_dump.  
  Run here: `./eal_tour -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch03-tour`
- **lcore mapping lab (prebuilt helloworld)** — Run dpdk-helloworld with --lcores='0,(1-3)@(1,2)', with -l 2-3 -R, and with --log-level=lib.eal:debug --log-timestamp=delta to capture the init timeline.  
  Run here: `timeout -s INT -k 5 10 dpdk-helloworld --lcores='0,(1-3)@(1,2)' --no-pci --no-huge -m 64 --file-prefix=ch03-map --log-level=lib.eal:debug`
- **log_lab.c** — Custom logtype user.ch03app via RTE_LOG_REGISTER_SUFFIX, messages at several levels, --log-level='user.*:debug', redirect to a file with rte_openlog_stream.  
  Run here: `./log_lab -l 0 --no-pci --no-huge -m 64 --file-prefix=ch03-log --log-level='user.ch03*:debug'`
- **tsc_lab.c** — Measure rte_rdtsc vs rte_rdtsc_precise vs clock_gettime cost; compare CPU time consumed by rte_delay_us_block vs rte_delay_us_sleep via getrusage. Implements the 'How to measure on this machine' recipe (warm-up, N=7 repetitions, median/min/max).  
  Run here: `./tsc_lab -l 0 --no-pci --no-huge -m 64 --file-prefix=ch03-tsc`
- **thread anatomy** — Run a background DPDK app (prebuilt dpdk-timer or eal_tour in sleep mode) and list /proc/PID/task/*/comm and Cpus_allowed_list to see main, worker, dpdk-intr, mp-msg, telemetry threads.  
  Run here: `run.sh starts it with timeout, inspects /proc, then SIGINTs it`

**Visualizations**

- **rte_eal_init step-through** (animation) — Phases light up in order with the real debug log line for each, and the files/threads/sockets they create appear (config file, mp_socket, telemetry socket, threads).
- **lcore <-> CPU mapper** (interactive) — Type a -l/--lcores string (digits, ranges, groups, @); the widget draws lcore boxes and arrows to CPU boxes, marks the main lcore and where control threads may run, flags oversubscription.
- **remote_launch swimlanes** (animation) — Main and worker lanes: pipe write, worker wake, WAIT->RUNNING, function runs, return value, RUNNING->WAIT, wait_lcore returns; -EBUSY path.
- **Log routing tree** (interactive) — Logtype tree (lib.eal, lib.ethdev, pmd.net.null, user.app) with level sliders; type a --log-level pattern and see which nodes match and which messages pass.
- **EAL layer cake** (diagram) — App -> libs -> EAL services -> Linux facilities (hugetlbfs, sysfs, VFIO, pthreads, epoll, unix sockets).

**Exercises**

1. [easy] Write a program that launches a different function on each worker and has the main lcore wait for each in reverse order.
2. [medium] Predict and then verify the lcore->CPU mapping for --lcores='0@0,(1,2)@(1-3)'.
3. [medium] Make a log message appear only with --log-level=user.ch03app:debug and verify RTE_LOG_LINE rejects a trailing newline at compile time.
4. [stretch] Install a SIGINT handler that stops a polling loop on all workers cleanly; check no files are left in /dev/hugepages for your prefix.

**Sources**

- doc/guides/prog_guide/env_abstraction_layer.rst
- doc/guides/linux_gsg/linux_eal_parameters.rst
- doc/guides/linux_gsg/eal_args.include.rst
- doc/guides/prog_guide/log_lib.rst
- lib/eal/linux/eal.c (rte_eal_init)
- lib/eal/common/eal_option_list.h
- lib/eal/include/rte_lcore.h
- lib/eal/include/rte_launch.h
- lib/eal/include/rte_thread.h
- lib/eal/include/generic/rte_cycles.h
- lib/log/rte_log.h
- examples/helloworld/main.c
- /home/user/ai_lab/dpdk_research/research/02-eal.md
- /home/user/ai_lab/dpdk_research/research/02-eal-examples/eal_tour.c
- lib/eal/common/eal_option_list.h (deprecated -c/-s)

## 04. Memory: Hugepages, Memzones, rte_malloc and IOVA

*Folder:* `chapters/04-memory-hugepages/` · *Level:* beginner (core) + optional advanced deep dive · *Prerequisites:* ch3

Why DPDK cares about memory (TLB reach, pinned DMA-able pages, shareable between processes), how Linux hugepages work, the files and EAL options you meet on day one, rte_malloc and named memzones, what IOVA is (in one picture) and NUMA placement. A clearly marked 'Deep dive (optional on first read)' section then covers memseg lists/fbarray, malloc heap internals, dynamic vs legacy memory, memory event callbacks and validators, and external memory. VFIO/IOMMU details live in ch23.

**Concepts**

- Virtual memory, page tables and TLB reach: 4 KB vs 2 MB vs 1 GB pages
- Linux hugepages: /proc/meminfo, nr_hugepages, hugetlbfs mount, usertools/dpdk-hugepages.py
- EAL memory options: --no-huge, -m (a pinned floor, not a cap), --numa-mem, --numa-limit, --in-memory, --single-file-segments, --huge-dir, --huge-unlink, --legacy-mem
- Backing files: /dev/hugepages/<prefix>map_*, memfd with --in-memory, anonymous memory with --no-huge; runtime dir /run/dpdk/<prefix>
- [Deep dive] Memory model: VA reservation -> memseg lists (one per page size x socket) -> memsegs (pages) in fbarrays
- rte_malloc family: alignment, zeroing, socket variants, stats, rte_malloc_validate; never mix with free()
- [Deep dive] Malloc heap internals: malloc_elem headers, free-list size classes, split/merge, pad elements, heap growth/shrink
- Memzones: named, aligned, bounded, RTE_MEMZONE_IOVA_CONTIG, lookup, dump, max count (rte_memzone_max_set)
- Bridge from ch1's two-lane race: a NIC DMA-writes a packet to an address it was given (an IOVA), so the CPU's virtual address for that buffer must map to the same memory; this is why DPDK pins memory and tracks IOVAs
- IOVA: what a device sees; PA vs VA vs DC modes; how EAL decides; rte_mem_virt2iova; IOVA-contiguity failure in PA mode
- VFIO/IOMMU/UIO in one picture only; group vs cdev (IOMMUFD) modes and the now-internal rte_vfio_* API are in ch23
- NUMA: socket ids, SOCKET_ID_ANY, rte_socket_id, local placement of pools/rings (one node here: theory + visual)
- [Deep dive] Dynamic vs legacy memory; memory event callbacks and allocation validators
- [Deep dive] External memory: rte_malloc_heap_create/memory_add and rte_extmem_register
- [Deep dive] DMA-mapping external memory: rte_extmem_register only tells EAL about the pages; a device can DMA into them only after rte_dev_dma_map(dev, va, iova, len) (rte_dev.h), the only public path since rte_vfio_* became internal in 26.11 (ch23). The vdev bus forwards it to the driver's dma_map (drivers/bus/vdev/vdev.c), which virtio_user implements; most vdevs return ENOTSUP. An extmem-backed mempool alone is not enough for I/O
- 'On real hardware' sidebar: reserving hugepages persistently (kernel command line or dpdk-hugepages.py --setup), 1 GB pages, turning the IOMMU on (intel_iommu=on / amd_iommu=on, iommu=pt); production detail in ch29
- Hygiene: leaked hugepage files after kill -9, unique --file-prefix, --in-memory when no secondaries
- When rte_eal_init fails (startup error catalogue, part 1): duplicate --file-prefix with a running primary, -l naming a CPU that does not exist (-l 7 on this 4-CPU VM) or is outside the affinity mask, -m larger than the free hugepages, 'No free 2048 kB hugepages reported' on an exhausted mount, memory requested on a socket with no memory; each with the exact log text, cause and fix. Port-init errors are in ch8, multi-process errors in ch16
- Band 1 review page at the end of the chapter: concepts of ch1-ch4 mapped to chapters, with a short predict-then-reveal quiz

**APIs**

`rte_malloc`, `rte_zmalloc`, `rte_calloc`, `rte_realloc`, `rte_malloc_socket`, `rte_free`, `rte_malloc_validate`, `rte_malloc_dump_stats`, `rte_malloc_get_socket_stats`, `rte_memzone_reserve`, `rte_memzone_reserve_aligned`, `rte_memzone_reserve_bounded`, `rte_memzone_lookup`, `rte_memzone_free`, `rte_memzone_dump`, `rte_memzone_max_set`, `rte_memseg_list_walk`, `rte_memseg_walk`, `rte_memseg_contig_walk`, `rte_mem_virt2iova`, `rte_mem_virt2memseg`, `rte_eal_iova_mode`, `rte_mem_event_callback_register`, `rte_mem_alloc_validator_register`, `rte_malloc_heap_create`, `rte_malloc_heap_memory_add`, `rte_malloc_heap_get_socket`, `rte_extmem_register`, `rte_socket_count`, `rte_socket_id`, `rte_dev_dma_map`, `rte_dev_dma_unmap`, `rte_errno`, `rte_strerror`

**Runnable code examples**

- **hello_memory.c** — rte_malloc/zmalloc with several alignments, validate, stats before/after, print va and iova; run twice: --no-huge (IOVA=VA) and -m 64 hugepages (IOVA=PA as root).  
  Run here: `./hello_memory -l 0 --no-pci --no-huge -m 64 --file-prefix=ch04-hm ; ./hello_memory -l 0 --no-pci -m 64 --file-prefix=ch04-hm2`
- **see_the_files.sh + sleeper.c** — Start a sleeping DPDK program in four memory modes (default hugepages -m 32, --single-file-segments, --in-memory, --no-huge) and show /dev/hugepages, /run/dpdk/<prefix>, /proc/PID/maps lines and HugetlbPages; clean up.  
  Run here: `run.sh drives it; each run timeout 8 s, prefix ch04-files-*`
- **memseg_walk.c** — Walk memseg lists and first segments; reserve a 3 MB IOVA_CONTIG memzone: fails in PA mode with hugepages, succeeds with --iova-mode=va or --no-huge. Based on research/03-memory-examples/memexp.c.  
  Run here: `./memseg_walk -l 0 --no-pci -m 32 --file-prefix=ch04-ms ; add --iova-mode=va`
- **memzones.c** — Reserve/lookup/dump memzones; error cases EEXIST (duplicate) and ENOSPC (after rte_memzone_max_set(4)); a bounded reservation checked not to cross 1 MB.  
  Run here: `./memzones -l 0 --no-pci --no-huge -m 64 --file-prefix=ch04-mz`
- **heap_events.c** — Register a mem event callback, rte_zmalloc(5 MB) then rte_free and watch ALLOC/FREE events with hugepages (-m 16, --huge-unlink); the --no-huge and --legacy-mem runs are deliberate, captured ENOTSUP cases (memory is not dynamic there). Then an external heap built on mmap memory via rte_malloc_heap_create/memory_add. Deep-dive section.  
  Run here: `./heap_events -l 0 --no-pci -m 16 --huge-unlink --file-prefix=ch04-ev ; then --no-huge -m 64 and --legacy-mem runs (expect rte_mem_event_callback_register = -1, ENOTSUP); trap cleans /dev/hugepages/ch04-*`
- **extmem_dma.c (deep dive)** — Allocates an anonymous 2 MB region, registers it with rte_extmem_register, then calls rte_dev_dma_map on a virtio_user port (vhost-user peer from a vhost vdev in the same process, socket in the chapter dir) and on a net_null port; prints the real return codes (success on virtio_user if its backend supports it, -ENOTSUP on null) and unmaps. Teaches that registration and DMA mapping are two steps.  
  Run here: `./extmem_dma -l 0 --no-pci --no-huge -m 128 --file-prefix=ch04-xdma --vdev=net_vhost0,iface=$PWD/x.sock,client=0 --vdev=net_virtio_user0,path=$PWD/x.sock --vdev=net_null0 (author verifies; capture whichever result appears; trap removes x.sock)`
- **startup_errors.sh** — Deliberately triggers each startup error reproducible here and records 'error text -> cause -> fix' rows into errors.tsv: (1) a second primary with the same --file-prefix while a -m 32 hugepage primary runs; (2) -l 7 on 4 CPUs; (3) -m 128 with --huge-dir pointing at a private hugetlbfs mount created with size=64M (mounted and unmounted by the script); (4) the same mount exhausted ('No free hugepages'); (5) rte_malloc_socket(..., 1) on a single-node VM. The table feeds the chapter's error-decoder widget.  
  Run here: `./startup_errors.sh (prefixes ch04-err-*, every run timeout 10 s; trap unmounts the private hugetlbfs and removes /dev/hugepages/ch04-err-*map_*)`

**Visualizations**

- **TLB reach slider** (interactive) — Page size slider (4K/2M/1G) shows the number of TLB entries needed to cover 512 MB and the page-walk steps.
- **DPDK VA window** (animation) — Long bar of reserved VA (PROT_NONE grey) where pages light up as alloc_seg maps them; shows fbarray and config at the start.
- **VA -> IOVA mapping** (interactive) — Two columns, VA pages and physical frames; PA mode shows scattered lines, VA mode straight lines; a 'reserve 3 MB IOVA_CONTIG' button fails in PA and succeeds in VA.
- **Malloc heap split/merge** (animation) — Strip of memory with malloc_elem headers coloured FREE/BUSY/PAD; allocations split elements, frees merge neighbours, pages are returned to the OS.
- **Memory layer cake** (diagram) — hugetlbfs/memfd -> memseg -> memseg list -> malloc_heap -> rte_malloc / memzone -> mempool, ring, mbuf.
- **NUMA topology** (diagram) — Two sockets, memory controllers, NIC on socket 0, local vs remote access paths with latency labels.
- **EAL error decoder** (interactive) — The learner pastes or picks an EAL error line; the widget matches it against the captured errors.tsv and shows the cause, the init phase where it happened (highlighted on the rte_eal_init timeline) and the fix. Extended in ch8 (port errors) and ch16 (multi-process).

**Exercises**

1. [easy] Allocate 100 objects of 1 KB with rte_malloc and compare heap stats before/after; explain the overhead.
2. [medium] Show that -m 32 does not cap the heap by allocating 64 MB; then use --numa-limit to make it fail.
3. [medium] Kill a hugepage-backed program with SIGKILL, find its leftover files, and clean them up safely.
4. [stretch] Explain why a device that DMAs a region larger than one page needs IOVA-contiguous memory (a memzone with RTE_MEMZONE_IOVA_CONTIG) in PA mode; ch23 shows the NIC descriptor ring case.
5. [medium] Reproduce one startup error that startup_errors.sh does not cover, capture its text and add a row to errors.tsv.

**Sources**

- doc/guides/prog_guide/env_abstraction_layer.rst (Memory sections, IOVA Mode Detection)
- doc/guides/linux_gsg/sys_reqs.rst
- lib/eal/include/rte_memory.h
- lib/eal/include/rte_memzone.h
- lib/eal/include/rte_malloc.h
- lib/eal/common/malloc_heap.c
- lib/eal/common/malloc_elem.c
- lib/eal/common/eal_common_memzone.c
- lib/eal/common/eal_common_dynmem.c
- lib/eal/linux/eal_memalloc.c
- usertools/dpdk-hugepages.py
- /home/user/ai_lab/dpdk_research/research/03-memory.md
- /home/user/ai_lab/dpdk_research/research/03-memory-examples/memexp.c
- lib/eal/include/rte_dev.h (rte_dev_dma_map)
- drivers/bus/vdev/vdev.c
- drivers/net/virtio/virtio_user_ethdev.c
- doc/guides/linux_gsg/linux_eal_parameters.rst

## 05. rte_ring: Lock-Free Queues Between Cores

*Folder:* `chapters/05-rings/` · *Level:* intermediate · *Prerequisites:* ch4

The rte_ring is the backbone of DPDK: a fixed-size, lock-free FIFO of pointers (or elements). Covers the API (single/bulk/burst), the head/tail algorithm with 32-bit wrapping indexes, SP/SC vs MP/MC CAS, why RTS and HTS sync modes exist for preemptible threads, element rings, peek and zero-copy APIs and the staged-ordered SORING. A two-page atomics primer box (acquire/release, CAS) gives just enough memory-ordering background; ch14 teaches it fully.

**Concepts**

- Atomics primer box: what a compare-and-swap does, why the tail update needs release ordering and the reader acquire ordering; forward link to ch14
- FIFO of pointers; size power of two; capacity = count-1 unless RING_F_EXACT_SZ
- Producer and consumer head/tail indexes; 32-bit wraparound; slot = index & mask; entries = prod_tail - cons_head
- Single-producer enqueue in three steps; multi-producer CAS on prod.head and in-order tail update (waiting for earlier producers)
- API families: single object, bulk (all or nothing), burst (as many as possible); free_space / available out-params
- Sync modes via flags: SP/SC, MP/MC, RTS (relaxed tail sync), HTS (head/tail sync); why preemption of a producer stalls MP/MC
- Default vs explicit calls (rte_ring_enqueue_burst vs rte_ring_mp_enqueue_burst)
- Status functions: count, free_count, full, empty, get_size, get_capacity, dump; lookup by name
- Element rings: rte_ring_create_elem, esize multiple of 4, *_elem APIs
- Peek API (start/finish) for ST and HTS rings; zero-copy API with two-part regions
- SORING (staged-ordered ring) overview and when to use it
- Pitfalls: ST ring used from 2 threads, bulk return-value convention, creating rings from several threads at once
- A ring can also be an Ethernet port (net_ring / rte_eth_from_rings) — shown in ch8 ring_cable

**APIs**

`rte_ring_create`, `rte_ring_create_elem`, `rte_ring_free`, `rte_ring_lookup`, `rte_ring_enqueue`, `rte_ring_dequeue`, `rte_ring_enqueue_bulk`, `rte_ring_dequeue_bulk`, `rte_ring_enqueue_burst`, `rte_ring_dequeue_burst`, `rte_ring_mp_enqueue_burst`, `rte_ring_sc_dequeue_burst`, `rte_ring_enqueue_burst_elem`, `rte_ring_count`, `rte_ring_free_count`, `rte_ring_full`, `rte_ring_empty`, `rte_ring_get_capacity`, `rte_ring_dump`, `rte_ring_dequeue_bulk_start`, `rte_ring_dequeue_finish`, `rte_ring_enqueue_zc_burst_start`, `rte_ring_enqueue_zc_finish`, `RING_F_SP_ENQ`, `RING_F_SC_DEQ`, `RING_F_MP_RTS_ENQ`, `RING_F_MC_RTS_DEQ`, `RING_F_MP_HTS_ENQ`, `RING_F_MC_HTS_DEQ`, `RING_F_EXACT_SZ`, `rte_soring_init (overview)`

**Runnable code examples**

- **ring_basics.c** — Producer lcore sends integers cast to void* to a consumer lcore; prints count/free_count; demonstrates bulk all-or-nothing vs burst partial behaviour on a nearly full ring.  
  Run here: `./ring_basics -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch05-basic`
- **ring_wrap.c** — Ring of 8 slots, 1000 enqueue/dequeue cycles; rte_ring_dump shows head/tail far beyond 8 and the mask math; capacity 7 vs RING_F_EXACT_SZ.  
  Run here: `./ring_wrap -l 0 --no-pci --no-huge -m 64 --file-prefix=ch05-wrap`
- **ring_modes_bench.c** — Ops/s and cycles per object for SP/SC, MP/MC, RTS, HTS with bulk sizes 1/8/32 on lcores 0-2; each mode runs for a fixed 1 s of TSC time (not a fixed op count) so the overcommitted run (--lcores='(0-3)@1'), where preempted MP/MC producers make others spin for whole timeslices, still finishes inside the timeout. Median of 5 runs. Reuse ideas from research/04-examples/perf.c.  
  Run here: `./ring_modes_bench -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch05-bench ; and --lcores='(0-3)@1'`
- **elem_peek.c** — HTS element ring of struct {uint32 flow; uint32 len;}; consumer peeks with dequeue_bulk_elem_start and only takes items of its flow; zero-copy enqueue example.  
  Run here: `./elem_peek -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch05-peek`

**Visualizations**

- **Ring clock face** (animation) — Circular 16-slot ring with prod_head/prod_tail/cons_head/cons_tail arrows; step buttons for SP enqueue (3 steps), SC dequeue and a 2-producer CAS race with 'CAS failed, retry' and 'wait for tail'. 'Predict, then step': before each step the widget asks where prod_tail will be.
- **Modulo-2^32 odometer** (interactive) — 32-bit counters spinning past 2^32-1 -> 0 while idx & mask picks the slot; live calculator for entries = prod_tail - cons_head.
- **Sync-mode Gantt** (animation) — Three threads, one preempted mid-enqueue: MP/MC others stall (red), RTS completes, HTS serialized; overcommit toggle and the measured cycles/object bars.
- **Bulk vs burst slider** (interactive) — Drag n against free space; bulk shows all-or-nothing failure, burst partial fill.
- **Zero-copy split** (diagram) — Reserved region wrapping the end of the ring labelled ptr1/n1 and ptr2/n-n1.

**Exercises**

1. [easy] Make ring_basics use RING_F_SP_ENQ|RING_F_SC_DEQ and measure the difference.
2. [medium] Write a 3-stage pipeline (lcore 0 -> ring -> lcore 1 -> ring -> lcore 2) passing sequence numbers and verify ordering.
3. [medium] Reproduce the overcommit collapse and explain from the head/tail algorithm why RTS helps.
4. [stretch] Implement a consumer that uses the peek API to drop items whose len field is 0 without dequeuing others.

**Sources**

- doc/guides/prog_guide/ring_lib.rst
- lib/ring/rte_ring.h
- lib/ring/rte_ring_core.h
- lib/ring/rte_ring_elem.h
- lib/ring/rte_ring_c11_pvt.h
- lib/ring/rte_ring_rts.h
- lib/ring/rte_ring_hts.h
- lib/ring/rte_ring_peek.h
- lib/ring/rte_ring_peek_zc.h
- lib/ring/rte_soring.h
- /home/user/ai_lab/dpdk_research/research/04-mbuf-mempool-ring.md
- /home/user/ai_lab/dpdk_research/research/04-examples/perf.c

## 06. rte_mempool and rte_stack: Fixed-Size Allocation at Line Rate

*Folder:* `chapters/06-mempools/` · *Level:* intermediate · *Prerequisites:* ch5

Packet processing allocates and frees millions of objects per second. The mempool gives O(1) fixed-size allocation backed by a ring (or stack, bucket, ...) with a per-lcore cache in front. Covers object layout, the 26.11 cache algorithm, sizing and stranded objects, caches for non-EAL threads, mempool handlers (ops) including writing your own, and the rte_stack library (standard, lock-free with ABA protection, and the new pile type).

**Concepts**

- Why fixed-size pools beat malloc on the fast path
- rte_mempool_create vs create_empty + set_ops_byname + populate_default; obj_init and mp_init callbacks
- Object layout: header, object, trailer; objects spread across pages; --no-huge 4 KB page effect; memory channel spreading
- get/put single and bulk; rte_mempool_avail_count and in_use_count; full/empty
- Per-lcore cache: the 26.11 algorithm (holds up to size, flushes/refills size/2) vs the old 1.5x flushthresh algorithm
- Choosing cache_size; stranded objects across lcore caches; the sizing formula for pools feeding NIC rings
- Non-EAL threads have no default cache: rte_mempool_cache_create + generic_get/put
- Mempool ops/handlers: ring_mp_mc, ring_sp_sc, stack, lf_stack, pile (26.11), bucket; RTE_MEMPOOL_REGISTER_OPS for a custom handler
- Iterators (obj_iter, mem_iter), dump, lookup, telemetry /mempool/list and /mempool/info
- rte_stack: LIFO, standard (spinlock) vs lock-free (RTE_STACK_F_LF) vs pile (RTE_STACK_F_PILE); ABA problem and 128-bit CAS
- API changes in 26.11 callout: cache size is no longer limited by RTE_MEMPOOL_CACHE_MAX_SIZE (any value up to the element count), new sizeof_cache_per_lcore field and variable-size objs[] in the cache; pile is LIFO only at the bulk level and not strictly bounded by its size (release_26_11.rst)

**APIs**

`rte_mempool_create`, `rte_mempool_create_empty`, `rte_mempool_set_ops_byname`, `rte_mempool_populate_default`, `rte_mempool_free`, `rte_mempool_lookup`, `rte_mempool_get`, `rte_mempool_put`, `rte_mempool_get_bulk`, `rte_mempool_put_bulk`, `rte_mempool_avail_count`, `rte_mempool_in_use_count`, `rte_mempool_default_cache`, `rte_mempool_cache_create`, `rte_mempool_cache_free`, `rte_mempool_cache_flush`, `rte_mempool_generic_get`, `rte_mempool_generic_put`, `rte_mempool_obj_iter`, `rte_mempool_mem_iter`, `rte_mempool_dump`, `rte_mempool_list_dump`, `RTE_MEMPOOL_REGISTER_OPS`, `struct rte_mempool_ops`, `rte_stack_create`, `rte_stack_push`, `rte_stack_pop`, `rte_stack_count`, `rte_stack_free`, `RTE_STACK_F_LF`, `RTE_STACK_F_PILE`

**Runnable code examples**

- **mempool_basics.c** — Create a pool of 1023 64-byte objects with obj_init numbering them, get/put single and bulk, print counts and rte_mempool_dump.  
  Run here: `./mempool_basics -l 0 --no-pci --no-huge -m 64 --file-prefix=ch06-basic`
- **cache_explorer.c** — Print cache->len after each get/put to reveal the 26.11 flush/refill-by-half behaviour; time get/put with cache 0 vs 256 vs 1024 (shows the old 512 limit is gone) and report the measured ratio (median of 5; no predicted numbers in the prose).  
  Run here: `./cache_explorer -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch06-cache`
- **handler_bakeoff.c** — Same workload over ring_mp_mc, ring_sp_sc, stack, lf_stack, pile, bucket: cycles/object and the first 5 addresses returned after free (LIFO vs FIFO reuse). The pile handler's addresses are LIFO per bulk but not per object; the chapter explains this documented 26.11 caveat so readers do not mistake it for a bug.  
  Run here: `./handler_bakeoff -l 0-2 --no-pci --no-huge -m 128 --file-prefix=ch06-ops`
- **stranded_cache.c** — Pool of 256 with cache 128 used by 3 lcores; main lcore then fails to get all 256; fixed with rte_mempool_cache_flush or correct sizing.  
  Run here: `./stranded_cache -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch06-strand`
- **custom_ops.c + stack_demo.c** — Register a toy 'array + spinlock' mempool handler with RTE_MEMPOOL_REGISTER_OPS and use it; separately compare std vs LF rte_stack throughput with 2 lcores.  
  Run here: `./custom_ops -l 0 ... --file-prefix=ch06-custom ; ./stack_demo -l 0-1 ... --file-prefix=ch06-stack`

**Visualizations**

- **Mempool cache animation** (animation) — Per-lcore cache stacks with a half-size marker above a shared ring 'warehouse'; get pops, refill moves size/2 up, overflow flushes the bottom half; driven by the measured trace; toggle old (flushthresh) algorithm.
- **Pool memory map** (interactive) — Pages (4K vs 2M toggle) filled with [hdr|obj|trailer] objects; shows wasted gaps with --no-huge and channel-spreading colours.
- **LF stack ABA step-through** (animation) — Three threads; ABA corruption without a counter vs prevention with the {ptr, counter} 128-bit CAS.
- **Where objects live** (diagram) — Pool -> ring backend MP_<name> -> per-lcore caches -> application, with object counts.

**Exercises**

1. [easy] Compute the minimum pool size for 2 ports x 2 queues x 1024 descriptors, 4 lcores with cache 256 and bursts of 32.
2. [medium] Change handler_bakeoff to multi-producer threads and explain which handler wins and why.
3. [medium] Use rte_mempool_obj_iter to verify that every object is back in the pool at shutdown.
4. [stretch] Make a non-EAL pthread use a user cache and measure the speedup over direct ring access.

**Sources**

- doc/guides/prog_guide/mempool_lib.rst
- doc/guides/prog_guide/stack_lib.rst
- doc/guides/mempool/*.rst
- lib/mempool/rte_mempool.h
- lib/mempool/rte_mempool.c
- lib/mempool/rte_mempool_ops.c
- drivers/mempool/ring/
- drivers/mempool/stack/
- drivers/mempool/bucket/
- lib/stack/rte_stack.h
- lib/stack/rte_stack_lf_c11.h
- doc/guides/rel_notes/release_26_11.rst
- /home/user/ai_lab/dpdk_research/research/04-mbuf-mempool-ring.md
- /home/user/ai_lab/dpdk_research/research/04-examples/exp.c
- /home/user/ai_lab/dpdk_research/research/04-examples/perf.c

## 07. rte_mbuf: The Packet Buffer

*Folder:* `chapters/07-mbufs/` · *Level:* intermediate · *Prerequisites:* ch6

Everything a PMD receives or sends is an rte_mbuf. This chapter dissects its two cache lines, the pktmbuf pool, headroom/data/tailroom and the manipulation helpers, multi-segment chains, reference counting, clones (indirect mbufs), copies and external buffers, offload flags and packet types, dynamic fields and flags, the private area, ownership rules and debugging aids.

**Concepts**

- Design: metadata and data buffer in one mempool object; m->pool so free needs no pool argument
- Layout: two 64 B cache lines; RX-hot vs TX fields; buf_addr, buf_iova, data_off, refcnt, nb_segs, port, ol_flags, packet_type, pkt_len, data_len, vlan_tci, hash, next, tx_offload bitfields, dynfield1
- rte_pktmbuf_pool_create: data room size, RTE_MBUF_DEFAULT_BUF_SIZE, RTE_PKTMBUF_HEADROOM, private size
- Headroom/data/tailroom; mtod, mtod_offset; append, prepend, adj, trim; data_len vs pkt_len
- alloc, alloc_bulk, free, free_bulk, reset, raw APIs and their invariants
- Chained mbufs: next, nb_segs, rte_pktmbuf_chain, rte_pktmbuf_read across segments, linearize, metadata only in the first segment
- Refcnt, clone (indirect mbuf attach/detach), rte_pktmbuf_copy, writing into a clone changes the original
- External buffers: rte_pktmbuf_attach_extbuf, shared info, free callback
- ol_flags: RX status bits and TX request bits; packet_type layers and rte_get_ptype_name; l2_len/l3_len/l4_len
- Dynamic fields and flags: register by name, offsets are runtime values, RTE_MBUF_DYNFIELD, rte_mbuf_dyn_dump, timestamp dynfield
- Private area (rte_mbuf_to_priv) for per-packet app metadata
- Ownership rules after rx_burst/tx_burst; double free and use-after-free; rte_mbuf_sanity_check, rte_pktmbuf_dump, mbuf history (debug builds)
- Pool variants and ops selection: rte_pktmbuf_pool_create_by_ops, the --mbuf-pool-ops-name EAL option, rte_mbuf_best_mempool_ops; pinned external-buffer pools (rte_pktmbuf_pool_create_extbuf, RTE_PKTMBUF_POOL_F_PINNED_EXT_BUF)
- Segment-level free: rte_pktmbuf_prefree_seg / rte_pktmbuf_free_seg — what a PMD TX-completion path calls (ch23)
- Timestamp dynfield/dynflag registration: rte_mbuf_dyn_rx_timestamp_register, rte_mbuf_dyn_tx_timestamp_register (used in ch19 and ch22)
- mbuf history (debug builds) and usertools/dpdk-mbuf-history-parser.py

**APIs**

`rte_pktmbuf_pool_create`, `rte_pktmbuf_alloc`, `rte_pktmbuf_alloc_bulk`, `rte_pktmbuf_free`, `rte_pktmbuf_free_bulk`, `rte_pktmbuf_reset`, `rte_pktmbuf_mtod`, `rte_pktmbuf_mtod_offset`, `rte_pktmbuf_append`, `rte_pktmbuf_prepend`, `rte_pktmbuf_adj`, `rte_pktmbuf_trim`, `rte_pktmbuf_headroom`, `rte_pktmbuf_tailroom`, `rte_pktmbuf_data_len`, `rte_pktmbuf_pkt_len`, `rte_pktmbuf_chain`, `rte_pktmbuf_read`, `rte_pktmbuf_linearize`, `rte_pktmbuf_clone`, `rte_pktmbuf_copy`, `rte_pktmbuf_attach`, `rte_pktmbuf_detach`, `rte_pktmbuf_attach_extbuf`, `rte_pktmbuf_ext_shinfo_init_helper`, `rte_mbuf_refcnt_read`, `rte_mbuf_refcnt_update`, `rte_mbuf_to_priv`, `rte_mbuf_dynfield_register`, `rte_mbuf_dynflag_register`, `RTE_MBUF_DYNFIELD`, `rte_mbuf_dyn_dump`, `rte_get_ptype_name`, `rte_mbuf_sanity_check`, `rte_pktmbuf_dump`, `rte_pktmbuf_pool_create_by_ops`, `rte_mbuf_best_mempool_ops`, `rte_pktmbuf_pool_create_extbuf`, `rte_pktmbuf_prefree_seg`, `rte_pktmbuf_free_seg`, `rte_mbuf_dyn_rx_timestamp_register`, `rte_mbuf_dyn_tx_timestamp_register`

**Runnable code examples**

- **mbuf_anatomy.c** — Print offsetof() for key fields, sizeof(struct rte_mbuf), the addresses of m, priv, buf_addr, mtod and end of buffer; then append/prepend/adj/trim with rte_pktmbuf_dump after each step; prepend overflow returns NULL.  
  Run here: `./mbuf_anatomy -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-anat`
- **payload_build.c** — Fill an mbuf with a text payload and a small app header struct of our own (no protocol headers, no port yet), then inspect it with rte_pktmbuf_dump and rte_hexdump; the Ethernet/IPv4/UDP-to-pcap version is ch10's build_packets.c.  
  Run here: `./payload_build -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-pay`
- **chain_demo.c** — Header mbuf chained to two payload mbufs; rte_pktmbuf_read across the boundary into a stack buffer; rte_pktmbuf_linearize; verify pkt_len/nb_segs and the bytes with rte_pktmbuf_dump (no ports involved).  
  Run here: `./chain_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-chain`
- **clone_extbuf.c** — Multicast pattern: one payload, 3 clones each with its own header mbuf; refcnt goes 1->4->0 and pool counts change; then an external buffer with a free_cb that prints when the last reference drops.  
  Run here: `./clone_extbuf -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-clone`
- **dynfield_demo.c** — Register a 'ch07_latency_tsc' dynfield and a 'ch07_sampled' dynflag, stamp and read them, print rte_mbuf_dyn_dump.  
  Run here: `./dynfield_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-dyn`
- **pool_ops.c** — Create pktmbuf pools by ops name (ring_mp_mc, stack) with rte_pktmbuf_pool_create_by_ops, print rte_mbuf_best_mempool_ops() with and without --mbuf-pool-ops-name=stack.  
  Run here: `./pool_ops -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-ops --mbuf-pool-ops-name=stack`

**Visualizations**

- **mbuf anatomy explorer** (interactive) — Two 64 B cache lines with every field at its byte offset (hover for meaning, colour-coded RX-hot/TX/cold/dynfield); buffer bar below with buttons append/prepend/adj/trim that move data_off and data_len live, flashing NULL on overflow.
- **Chain view** (animation) — Linked segment boxes; only the head shows pkt_len/nb_segs/ol_flags; an rte_pktmbuf_read window slides across a segment boundary and copies into a temp buffer.
- **Refcnt and clone** (animation) — A direct mbuf with a refcnt badge, clones attaching with arrows to its buffer; freeing counts down; at 0 the buffer returns to the pool; extbuf variant with free_cb.
- **ol_flags bit-board** (interactive) — 64 squares coloured RX/TX/internal/dynamic; clicking a recipe (IPv4 cksum, UDP cksum, TSO, VXLAN) lights the needed bits and fills l2/l3/l4 lengths.
- **Ownership flow** (diagram) — Who owns an mbuf at each point: pool -> PMD (rx ring) -> app -> PMD (tx ring) -> pool.

**Exercises**

1. [easy] Write a function that prepends a VLAN tag to an existing Ethernet frame in place (use headroom, move the MAC addresses); in ch10 compare it with rte_vlan_insert.
2. [medium] Show with a test that writing into a clone corrupts the original, and fix it with rte_pktmbuf_copy.
3. [medium] Register a dynfield in two different programs and show the offsets can differ.
4. [stretch] Compute the memory used per mbuf for a pool of 8192 with data room 2048 + headroom, with and without --no-huge.

**Sources**

- doc/guides/prog_guide/mbuf_lib.rst
- lib/mbuf/rte_mbuf.h
- lib/mbuf/rte_mbuf_core.h
- lib/mbuf/rte_mbuf_dyn.h
- lib/mbuf/rte_mbuf_ptype.h
- lib/mbuf/rte_mbuf_pool_ops.h
- examples/ipv4_multicast/main.c
- /home/user/ai_lab/dpdk_research/research/04-mbuf-mempool-ring.md
- /home/user/ai_lab/dpdk_research/research/04-examples/exp.c
- usertools/dpdk-mbuf-history-parser.py

## 08. Your First Port: ethdev Lifecycle and the Burst API

*Folder:* `chapters/08-ethdev-first-port/` · *Level:* intermediate · *Prerequisites:* ch7

Puts EAL, mempools and mbufs together to drive an Ethernet port. Covers port discovery and capability queries, the configure -> queue setup -> start -> stop -> close lifecycle, rte_eth_rx_burst/rte_eth_tx_burst semantics and mbuf ownership, TX buffering, how the inline burst call dispatches through rte_eth_fp_ops, and a full walkthrough of the skeleton forwarder, run on net_null and net_ring ports.

**Concepts**

- What a port is: port id, name, owner; RTE_ETH_FOREACH_DEV; rte_eth_dev_count_avail; rte_eth_dev_get_name_by_port (26.11 size param) / get_port_by_name
- rte_eth_dev_info_get: driver name, max queues, descriptor limits, offload capability masks, default configs
- struct rte_eth_conf minimal setup; rte_eth_dev_configure(nb_rxq, nb_txq)
- Queue setup: rte_eth_rx_queue_setup / tx_queue_setup, nb_desc, socket id, rxconf/txconf, rte_eth_dev_adjust_nb_rx_tx_desc
- Lifecycle state machine and reconfiguration rules (-EBUSY when started), deferred start and per-queue start/stop (preview; the lab is in ch12)
- rx_burst: returns 0..n mbufs now owned by the app; tx_burst: may accept fewer, the app must free or retry the rest
- Burst size choice; rte_eth_tx_buffer + flush and a drain timer
- Inside the call: rte_eth_fp_ops[port] flat array, queue data pointer, PMD function pointer, dummy functions before start
- The skeleton (basicfwd) walkthrough: pool, port init, promiscuous, lcore main loop
- Mempool sizing for ports: nb_rxq*nb_rxd + nb_txq*nb_txd + nb_lcores*(cache+burst)
- Link status: rte_eth_link_get_nowait, rte_eth_link_to_str; basic counters rte_eth_stats_get
- Polling shows 100% CPU in top even when idle — expected
- Descriptor rings in one picture: the NIC owns the head, software the tail, the DD bit marks a finished descriptor, the PMD refills buffers — what nb_desc means and why imissed rises when the ring fills (full treatment in ch23)
- Stats preview: in 26.11 struct rte_eth_stats has only port totals (ipackets/opackets/ibytes/obytes/imissed/ierrors/oerrors/rx_nombuf); per-queue counters are xstats such as rx_q0_packets (ch12)
- 'When it doesn't work' box: check every return value and print rte_strerror(-ret) / rte_errno; turn on --log-level=lib.ethdev:debug and pmd.net.*:debug; read rte_eth_stats_get and xstats; the testpmd equivalents ('show port stats', 'show port info'); one telemetry query (/ethdev/stats,0). Full observability and debugging tools are ch13
- Port-init errors with their exact text: 'No probed ethernet devices' (no --vdev, or --no-pci with only PCI NICs), mbuf pool creation failing with ENOMEM (e.g. testpmd's default 155456-mbuf pool does not fit in --no-huge -m 256), nb_desc outside dev_info.rx_desc_lim, configure after start (-EBUSY)

**APIs**

`RTE_ETH_FOREACH_DEV`, `rte_eth_dev_count_avail`, `rte_eth_dev_is_valid_port`, `rte_eth_dev_get_name_by_port`, `rte_eth_dev_get_port_by_name`, `rte_eth_dev_info_get`, `rte_eth_dev_configure`, `rte_eth_dev_adjust_nb_rx_tx_desc`, `rte_eth_rx_queue_setup`, `rte_eth_tx_queue_setup`, `rte_eth_dev_socket_id`, `rte_eth_dev_start`, `rte_eth_dev_stop`, `rte_eth_dev_close`, `rte_eth_rx_burst`, `rte_eth_tx_burst`, `rte_eth_tx_buffer_init`, `rte_eth_tx_buffer`, `rte_eth_tx_buffer_flush`, `RTE_ETH_TX_BUFFER_SIZE`, `rte_eth_promiscuous_enable`, `rte_eth_macaddr_get`, `rte_eth_link_get_nowait`, `rte_eth_link_to_str`, `rte_eth_stats_get`, `rte_eth_from_rings`, `rte_strerror`, `rte_errno`, `rte_eth_dev_rx_queue_start (preview)`, `rte_eth_dev_rx_queue_stop (preview)`

**Runnable code examples**

- **port_explorer.c** — Lists every port with driver name, queue/descriptor limits and offload capability masks for net_null, net_ring and net_tap; calls rx_burst before start (dummy fp op), tries configure while started (-EBUSY), prints link string. Based on research/05-examples/lifecycle.c.  
  Run here: `./port_explorer -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-ports --vdev=net_null0 --vdev=net_ring0 --vdev=net_tap0,iface=ch08tap0`
- **my_skeleton.c** — A from-scratch, heavily commented forwarder (port 0 <-> port 1) with per-second stats and a signal-driven exit, on two net_null ports.  
  Run here: `timeout -s INT -k 5 8 stdbuf -oL ./my_skeleton -l 1 --no-pci --no-huge -m 128 --file-prefix=ch08-skel --vdev=net_null0 --vdev=net_null1`
- **burst_sweep.c** — Measures cycles/packet of the rx->tx loop on net_null for burst sizes 1,2,4,8,16,32,64,128 (fixed cost per call + per-packet cost); prints a table used by the chart. Median of 5 runs per burst size; ch22 reuses this data instead of repeating the sweep.  
  Run here: `./burst_sweep -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-sweep --vdev=net_null0`
- **ring_cable.c** — Two ports cross-wired by rte_eth_from_rings: packets with sequence numbers sent on port 0 arrive on port 1 in order; shows unsent-tail freeing when the ring is full.  
  Run here: `./ring_cable -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-cable`
- **dpdk-skeleton (prebuilt)** — Run the shipped skeleton for comparison (needs stdbuf -oL to keep output when killed).  
  Run here: `timeout -s INT -k 5 6 stdbuf -oL $DPDK_SRC/build/examples/dpdk-skeleton -l 1 --no-huge -m 128 --no-pci --file-prefix=ch08-sk --vdev=net_null0 --vdev=net_null1`
- **init_errors.sh** — Triggers the port-init errors above and captures them (my_skeleton without --vdev; testpmd on --no-huge -m 256 without --total-num-mbufs, which fails with 'Creation of mbuf pool for socket 0 failed: Cannot allocate memory'; port_explorer with nb_desc=1 and with a configure call after start). Rows are appended to the ch4 error table format.  
  Run here: `./init_errors.sh (prefixes ch08-ie-*, each run timeout 10 s)`

**Visualizations**

- **Port state machine** (interactive) — Clickable states (unconfigured, configured, started, stopped, closed); clicking API calls animates transitions or shows the error; the rte_eth_fp_ops[port] pointer flips between dummy and real functions on start/stop.
- **fp_ops call path** (animation) — rte_eth_rx_burst(0,q,...) -> rte_eth_fp_ops[0] -> rxq.data[q] -> PMD rx function -> optional callbacks -> return; highlights one array lookup + indirect call.
- **Burst amortisation chart** (interactive) — cycles/packet vs burst size from burst_sweep output, with a fitted a/b + c curve and a slider.
- **mbuf ownership in a forwarding loop** (animation) — mbufs flow pool -> RX ring -> app -> TX ring; a TX ring-full case shows the unsent tail being freed (or leaking if not).
- **Skeleton structure** (diagram) — Call graph of the skeleton main: EAL init, pool, port_init per port, lcore_main loop. (Static diagram, not counted as an interactive.)
- **Descriptor ring (simplified)** (animation) — Circular ring with NIC head, software tail and DD bits; learner sets arrival rate and poll rate; refill and imissed counters update. Simplified version of the ch23 widget.

**Exercises**

1. [easy] Extend my_skeleton to support any even number of ports given via --vdev and pair them 0-1, 2-3, ...
2. [medium] Introduce a deliberate leak (do not free unsent mbufs) on ring_cable with a small ring and watch the pool drain.
3. [medium] Use rte_eth_tx_buffer with a 100 us drain timer and compare packets per tx_burst call.
4. [stretch] Find in rte_ethdev.h the inline body of rte_eth_rx_burst and explain each line.

**Sources**

- doc/guides/prog_guide/ethdev/ethdev.rst
- doc/guides/sample_app_ug/skeleton.rst
- examples/skeleton/basicfwd.c
- lib/ethdev/rte_ethdev.h (rte_eth_rx_burst, rte_eth_tx_burst)
- lib/ethdev/rte_ethdev_core.h (struct rte_eth_fp_ops)
- lib/ethdev/ethdev_private.c (dummy ops)
- lib/ethdev/rte_ethdev.c
- drivers/net/null/rte_eth_null.c
- /home/user/ai_lab/dpdk_research/research/05-ethdev.md
- /home/user/ai_lab/dpdk_research/research/05-examples/lifecycle.c
- lib/eal/include/rte_errno.h

## 09. Testing Without Hardware: Buses, devargs, Virtual PMDs and testpmd

*Folder:* `chapters/09-virtual-devices-testpmd/` · *Level:* intermediate · *Prerequisites:* ch8

How to build, test and benchmark DPDK applications with no DPDK-capable NIC. Starts with the device model (buses, classes, drivers, devargs and device iterators), then each software PMD (null, ring, pcap, tap/tun, af_packet, af_xdp) and what it costs, traffic generation from the kernel side with Python raw sockets, and testpmd as the universal lab bench: forwarding modes, topology, stats, scripting, verbose packet dumps, runtime hotplug and a set of field-tested recipes used to qualify drivers and write bug reproducers.

**Concepts**

- Buses, classes, drivers and devices: rte_bus / rte_class / rte_dev; bus types (pci, vdev, auxiliary, vmbus, platform with 26.11 device-tree matching, cdx, uacce, fslmc/dpaa; table in ch23)
- devargs: -a/--allow, -b/--block, --vdev; generic syntax 'bus=pci,addr=.../class=eth,mac=.../driver=...'; rte_devargs_parse; iterators rte_dev_iterator_init / RTE_DEV_FOREACH, rte_eth_iterator_init / RTE_ETH_FOREACH_MATCHING_DEV
- kvargs: how drivers parse 'key=value,key=value' devargs (rte_kvargs_parse with a valid-key list, rte_kvargs_process callbacks, rte_kvargs_count, rte_kvargs_free); the same library a PMD uses (ch23) and your app can use for sub-options
- vdev bus, --vdev name[,key=val...], RTE_PMD_REGISTER_VDEV and RTE_PMD_REGISTER_PARAM_STRING; runtime creation with rte_vdev_init / rte_dev_probe
- net_null (size, copy, no-rx), net_ring, net_pcap (rx_pcap, tx_pcap, rx_iface, infinite_rx), net_tap/net_tun (kernel netdev, readv/writev), net_af_packet (PACKET_MMAP, qpairs, fanout), net_af_xdp (UMEM, fill/rx/tx/completion rings, XDP program, copy mode on veth)
- KNI history (removed 23.11) and its replacements
- Same application, many backends: the ethdev abstraction
- Traffic sources on this machine: Python raw sockets (no tcpdump/ping/scapy), pcap files, testpmd txonly/flowgen
- testpmd: all 26.11 forward modes (io, mac, macswap, 5tswap, rxonly, txonly, flowgen, csum, icmpecho, noisy, ieee1588, shared_rxq, recycle_mbufs), port topology paired/chained/loop, --stats-period, --total-num-mbufs, --no-flush-rx, --tx-first, port speed 'autoneg on|off' (26.11)
- Interactive testpmd: show port info/stats/xstats, set fwd, start/stop, set verbose 1, port attach/detach, scripting via stdin or --cmdline-file
- Throughput ladder of software PMDs measured here (data-driven from ladder.sh, median of 5): expect ring > null > pcap infinite_rx > memif > vhost/virtio_user > tap/af_packet/af_xdp, but print what you measure; these are software numbers and say nothing about NIC line rate
- Veth pairs and network namespaces for realistic L2 labs; cleanup discipline
- af_packet ignore_outgoing=1 (26.11) for veth ping-pong labs
- Background testpmd rule: without -i or --stats-period it waits for Enter, gets EOF and exits at once; background instances always use --stats-period N (stop with SIGINT) or -i fed from a FIFO/sleep-delayed pipe
- testpmd recipes: multi-queue/multi-core mapping (--rxq/--txq/--nb-cores, show config fwd), jumbo frames (--max-pkt-len=9000 + scatter, mbuf size), buffer split attempt (ENOTSUP on vdevs), xstats delta workflow, txonly shaping (--txpkts, --txonly-multi-flow, --eth-peer), show port cap/info/rxq info/desc status, runtime port config, and a --cmdline-file 'minimal reproducer' template for bug reports
- 'On real hardware' sidebar: dpdk-devbind.py --status, binding a spare NIC (never the management NIC) to vfio-pci, unbinding back to the kernel driver; production detail in ch29
- af_xdp on veth prints benign libxdp warnings ('No bpffs found at /sys/fs/bpf', 'Can't use dispatcher', 'Falling back to loading single prog'): the program runs in copy mode without the libxdp dispatcher; optionally mount bpffs (mount -t bpf bpf /sys/fs/bpf) to compare, and unmount it only if the script mounted it
- Hard rule for every testpmd command line: pass --total-num-mbufs (4096..16384). The default pool (155456 x 2176 B) does not fit in --no-huge -m 256 and fails with 'Creation of mbuf pool for socket 0 failed: Cannot allocate memory' (captured as the reason)
- testpmd as a debugger: 'set verbose 1/2' packet dumps, 'show port <p> rxq|txq <q> desc <d> status', 'show rxq info', 'show port info' / 'show port cap', --record-burst-stats with 'show fwd stats all' (burst-size histogram), 'clear port xstats' + 'show port xstats' deltas, and 'port stop / port config / port start' as a reconfiguration rehearsal; a one-page testpmd cheat-sheet in the Tools box

**APIs**

`rte_vdev_init`, `rte_vdev_uninit`, `rte_dev_probe`, `rte_dev_remove`, `rte_eth_dev_get_port_by_name`, `rte_eth_dev_info_get`, `RTE_PMD_REGISTER_VDEV (reading)`, `testpmd commands: set fwd, start tx_first, show port stats all, set verbose, port attach`, `rte_devargs_parse`, `rte_dev_iterator_init`, `RTE_DEV_FOREACH`, `rte_eth_iterator_init`, `RTE_ETH_FOREACH_MATCHING_DEV`, `rte_dev_name`, `rte_dev_bus`, `rte_kvargs_parse`, `rte_kvargs_process`, `rte_kvargs_count`, `rte_kvargs_free`

**Runnable code examples**

- **testpmd null io** — testpmd io forwarding between two net_null ports with stats every 2 s; read Rx-pps.  
  Run here: `timeout -s INT -k 5 8 dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-tp --vdev=net_null0 --vdev=net_null1 -- --total-num-mbufs=16384 --stats-period 2 --forward-mode=io`
- **pcap replay** — Generate in.pcap with mkpcap.py, replay with macswap and loop topology into out.pcap with --no-flush-rx; a Python reader shows swapped MACs; then show what happens without --no-flush-rx.  
  Run here: `dpdk-testpmd ... --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=out.pcap -- --forward-mode=macswap --port-topology=loop --no-flush-rx --total-num-mbufs=8192 --stats-period 1`
- **tap kernel <-> DPDK** — testpmd rxonly on net_tap0,iface=ch09tap0; inject 1000 frames from Python (sendraw.py); then txonly in the other direction and read ip -s link counters.  
  Run here: `--vdev=net_tap0,iface=ch09tap0 ; python3 -I sendraw.py ch09tap0 1000`
- **veth + af_packet / af_xdp** — Create veth ch09va/ch09vb; attach net_af_packet0 to one end and net_af_xdp0 to the other; start tx_first and watch packets ping-pong; delete veth afterwards.  
  Run here: `ip link add ch09va type veth peer name ch09vb; ... --vdev=net_af_packet0,iface=ch09va,ignore_outgoing=1 --vdev=net_af_xdp0,iface=ch09vb,start_queue=0,queue_count=1`
- **vdev_runtime.c + ladder.sh** — C program that creates net_null and net_ring ports at runtime with rte_vdev_init and prints their info; ladder.sh runs testpmd briefly on each PMD and tabulates Mpps.  
  Run here: `./vdev_runtime -l 0 --no-pci --no-huge -m 128 --file-prefix=ch09-rt ; ./ladder.sh`
- **devargs_iter.c** — Creates several vdevs, then iterates them with RTE_ETH_FOREACH_MATCHING_DEV('class=eth,mac=...') and RTE_DEV_FOREACH('bus=vdev'), and parses devargs strings with rte_devargs_parse, printing bus/name/args.  
  Run here: `./devargs_iter -l 0 --no-pci --no-huge -m 128 --file-prefix=ch09-iter --vdev=net_null0 --vdev=net_null1 --vdev=net_ring0`
- **testpmd_recipes.sh** — 8 scripted testpmd recipes with captured output: show config fwd with --rxq=2 --nb-cores=2 on net_null; jumbo on net_ring with --max-pkt-len=9000 and scatter; buffer split (captured ENOTSUP); xstats delta; txonly multi-flow; noisy mode; port config at runtime; a minimal-reproducer --cmdline-file template. Adds a 'testpmd as a debugger' block: a --cmdline-file run on vhost + virtio_user (two testpmd processes, --no-huge -m 256 each; rxq info, desc status and burst mode are supported there) and one on net_null, capturing set verbose, show port rxq/txq desc status, show rxq info, show port info/cap, --record-burst-stats + show fwd stats all, xstats deltas after clear, and port stop/config/start, each with a one-line interpretation. Every invocation passes --total-num-mbufs=8192.  
  Run here: `each recipe: timeout -s INT -k 5 10 dpdk-testpmd ... --file-prefix=ch09-r<N> -- -i --cmdline-file=rN.txt (or --stats-period 1)`
- **kvargs_demo.c** — Parses devargs-style strings ('rate=100,burst=32,mode=fast', plus an unknown key and a repeated key) with rte_kvargs_parse/process/count and prints what a driver would see; then parses the args of a --vdev given on the command line via rte_devargs_parse.  
  Run here: `./kvargs_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch09-kv --vdev=net_null0,size=128 -- 'rate=100,burst=32,mode=fast'`

**Visualizations**

- **vdev probe pipeline** (animation) — --vdev string -> devargs -> vdev bus -> driver matched by name prefix -> probe() -> ethdev allocated -> port id assigned.
- **Same app, many backends** (interactive) — One forwarding loop with swappable backend cartridges (null, ring, pcap, tap, af_packet, af_xdp); selecting one animates the data path with cost icons (pointer pass, memcpy, syscall).
- **AF_XDP rings** (animation) — UMEM frame grid with fill, RX, TX and completion rings cycling frame addresses between kernel and user space.
- **Throughput ladder** (chart) — Bar chart drawn from ladder.sh's captured numbers (median with min/max whiskers); a banner states these are software-PMD numbers on a shared VM.
- **testpmd forwarding modes** (diagram) — Panels for every 26.11 forward mode showing what it does to each packet; modes demonstrated in this course are marked.
- **Device model explorer** (interactive) — Bus -> device -> driver -> class tree built from the vdevs the learner adds; typing a devargs filter string highlights which devices RTE_ETH_FOREACH_MATCHING_DEV would visit.

**Exercises**

1. [easy] Use testpmd flowgen on net_null and verify with xstats how many flows were generated.
2. [medium] Replay a pcap through testpmd csum mode and explain the printed checksum flags.
3. [medium] Measure af_packet with qpairs=1 vs 2 on a veth and explain the result.
4. [stretch] Write a run script that cleans up after itself even when testpmd crashes (trap EXIT).
5. [easy] Use 'show port 0 rxq 0 desc 0 status' on virtio_user before and after 'start' and explain the difference.

**Sources**

- doc/guides/nics/null.rst
- doc/guides/nics/ring.rst
- doc/guides/nics/pcap.rst
- doc/guides/nics/tap.rst
- doc/guides/nics/af_packet.rst
- doc/guides/nics/af_xdp.rst
- doc/guides/howto/af_xdp_dp.rst
- doc/guides/testpmd_app_ug/run_app.rst
- doc/guides/testpmd_app_ug/testpmd_funcs.rst
- drivers/bus/vdev/
- drivers/net/null/rte_eth_null.c
- drivers/net/tap/rte_eth_tap.c
- app/test-pmd/testpmd.c
- /home/user/ai_lab/dpdk_research/research/06-virtual-devices-and-virtio.md
- /home/user/ai_lab/dpdk_research/research/06-examples/sendraw.py
- /home/user/ai_lab/dpdk_research/research/06-examples/mkpcap.py
- doc/guides/prog_guide/devargs.rst
- lib/eal/include/rte_bus.h
- lib/eal/include/rte_class.h
- lib/eal/include/rte_dev.h
- lib/eal/include/rte_devargs.h
- app/test-pmd/noisy_vnf.c
- lib/kvargs/rte_kvargs.h
- usertools/dpdk-devbind.py

## 10. Parsing and Building Packets: lib/net, Checksums and l2fwd

*Folder:* `chapters/10-packet-headers-l2fwd/` · *Level:* intermediate · *Prerequisites:* ch9

How to read and write protocol headers safely and fast with lib/net: Ethernet, VLAN, ARP, IPv4, IPv6 (26.11 types), UDP, TCP, ICMP; byte order; Internet checksums and pseudo-headers; software packet-type parsing; then the l2fwd sample app as the classic minimal forwarder with MAC rewriting, TX buffering and periodic stats.

**Concepts**

- Header structs: rte_ether_hdr, rte_vlan_hdr, rte_arp_hdr, rte_ipv4_hdr, rte_ipv6_hdr, rte_udp_hdr, rte_tcp_hdr, rte_icmp_hdr
- Ethernet address helpers: rte_ether_addr_copy, rte_ether_format_addr, rte_is_unicast/multicast/broadcast_ether_addr, rte_eth_random_addr
- Byte order: rte_be_to_cpu_16/32, rte_cpu_to_be_16/32, RTE_BE16/RTE_BE32 constants, RTE_IPV4() host-order macro
- IPv4: version_ihl, rte_ipv4_hdr_len, fragment flags/offset, TTL, total_length
- IPv6 in 26.11: struct rte_ipv6_addr, RTE_IPV6() helpers, vtc_flow with RTE_IPV6_HDR_*_MASK/SHIFT (no bitfields)
- Checksums: one's-complement sum and folding, rte_raw_cksum, rte_ipv4_cksum, rte_ipv4_phdr_cksum, rte_ipv4_udptcp_cksum, rte_ipv6_udptcp_cksum, verify functions
- Software ptype parsing: rte_net_get_ptype with rte_net_hdr_lens; RTE_PTYPE_* masks
- Safe parsing: bounds checks against data_len, headers spanning segments (rte_pktmbuf_read)
- l2fwd sample: port pairs, MAC rewrite, rte_eth_tx_buffer with drain timer, per-port statistics, -p/-q/-T options
- Running l2fwd on pcap vdevs and verifying output
- VLAN helpers: rte_vlan_insert and the 26.11 rte_vlan_insert_tpid (QinQ), rte_vlan_strip
- CRC: rte_net_crc_set_alg / rte_net_crc_calc (CRC32-Ethernet, CRC16-CCITT; scalar/SSE/AVX-512)
- Tunnel and other headers gallery: rte_vxlan.h, rte_geneve.h, rte_gtp.h, rte_mpls.h, rte_esp.h, rte_sctp.h, rte_ecpri.h, rte_l2tpv2.h, rte_ib.h; building a VXLAN frame (sets up ch19's tunnel offloads)
- Address parsing and IPv6 extension headers: rte_ether_unformat_addr, rte_ipv6_get_next_ext, rte_net_skip_ip6_ext
- 26.11 accuracy: RTE_IP_ICMP_ECHO_* macros are gone; use RTE_ICMP_TYPE_ECHO_REQUEST / RTE_ICMP_TYPE_ECHO_REPLY
- 26.11: __rte_packed was removed. Packed structs are written 'struct __rte_packed_begin toy_tun_hdr { ... } __rte_packed_end;' (lib/eal/include/rte_common.h); code copied from older tutorials fails to compile. Also unaligned_uint16/32/64_t now really have alignment 1, so use them (or memcpy) for unaligned header fields

**APIs**

`rte_pktmbuf_mtod_offset`, `rte_ether_addr_copy`, `rte_ether_format_addr`, `rte_is_broadcast_ether_addr`, `rte_eth_random_addr`, `rte_be_to_cpu_16`, `rte_cpu_to_be_16`, `rte_cpu_to_be_32`, `RTE_IPV4`, `rte_ipv4_hdr_len`, `rte_ipv4_cksum`, `rte_ipv4_phdr_cksum`, `rte_ipv4_udptcp_cksum`, `rte_ipv4_udptcp_cksum_verify`, `rte_ipv6_udptcp_cksum`, `rte_raw_cksum`, `rte_net_get_ptype`, `struct rte_net_hdr_lens`, `rte_get_ptype_name`, `RTE_IPV6`, `rte_ipv6_addr_eq`, `rte_eth_tx_buffer`, `rte_vlan_insert`, `rte_vlan_insert_tpid`, `rte_vlan_strip`, `rte_net_crc_set_alg`, `rte_net_crc_calc`, `rte_net_crc_free`, `rte_ether_unformat_addr`, `rte_ipv6_get_next_ext`, `rte_net_skip_ip6_ext`, `RTE_ICMP_TYPE_ECHO_REQUEST`, `struct rte_vxlan_hdr`, `__rte_packed_begin`, `__rte_packed_end`, `unaligned_uint32_t`, `RTE_BUILD_BUG_ON`

**Runnable code examples**

- **parse_pcap.c** — Reads a pcap through net_pcap, parses Ethernet/VLAN/IPv4/IPv6/UDP/TCP with bounds checks, prints 5-tuples and the ptype name from rte_net_get_ptype.  
  Run here: `./parse_pcap -l 0 --no-pci --no-huge -m 128 --file-prefix=ch10-parse --vdev=net_pcap0,rx_pcap=mixed.pcap,tx_pcap=/dev/null`
- **build_packets.c** — Crafts ARP request, ICMP echo, IPv4/UDP, IPv6/UDP and a VXLAN-encapsulated frame with correct checksums and writes them via tx_pcap (this is also the Eth/IP/UDP-to-pcap build moved out of ch7); a Python verifier checks checksums; also inserts a VLAN tag with rte_vlan_insert and a QinQ tag with rte_vlan_insert_tpid, and prints rte_net_crc_calc of each frame. Includes a toy tunnel header (8 bytes after UDP port 47000) defined with __rte_packed_begin/__rte_packed_end and RTE_BUILD_BUG_ON(sizeof(...) != 8), plus a compile-only snippet showing the error a bare __rte_packed gives.  
  Run here: `./build_packets -l 0 ... --file-prefix=ch10-build --vdev=net_pcap0,rx_pcap=empty.pcap,tx_pcap=built.pcap ; python3 -I verify.py built.pcap`
- **cksum_lab.c** — Computes an IPv4 header checksum by hand step by step (16-bit sums, carries, fold, invert) and compares with rte_ipv4_cksum and rte_raw_cksum; also an incremental TTL-decrement update.  
  Run here: `./cksum_lab -l 0 --no-pci --no-huge -m 64 --file-prefix=ch10-ck`
- **l2fwd (prebuilt)** — Run dpdk-l2fwd on two pcap ports and verify with pcap_summary.py that MACs are rewritten to 02:00:00:00:00:<port>.  
  Run here: `dpdk-l2fwd -l 0,1 --no-pci --no-huge -m 128 --file-prefix=ch10-l2 --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=l2out0.pcap --vdev=net_pcap1,rx_pcap=empty.pcap,tx_pcap=l2out1.pcap -- -p 0x3 -q 2 -T 1`
- **mini_l2fwd.c** — A 150-line commented re-implementation of l2fwd's core loop with rte_eth_tx_buffer and a TSC-based drain timer, on net_ring pairs.  
  Run here: `./mini_l2fwd -l 0 ... --file-prefix=ch10-mini --vdev=net_ring0 --vdev=net_ring1`

**Visualizations**

- **Packet byte map** (interactive) — Ethernet/IPv4/UDP frame as a byte grid; hovering a struct field highlights its bytes; toggle host/network order display. Includes a tunnel-header gallery (VXLAN, GENEVE, GTP-U, MPLS) selectable by the learner.
- **Checksum folding** (animation) — Step-through of 16-bit word addition, carry wrap-around, fold and invert, with the running sum.
- **ptype decoder** (interactive) — Enter a 32-bit packet_type; nibbles map to L2/L3/L4/tunnel/inner names with a layered packet drawing.
- **l2fwd data flow** (animation) — Packets arrive on port 0, MACs rewritten, buffered in the TX buffer, flushed when full or when the drain timer fires; stats tick.
- **IPv6 header (26.11)** (diagram) — vtc_flow bit layout with version/traffic class/flow label masks.

**Exercises**

1. [easy] Add VLAN (802.1Q) and QinQ support to parse_pcap, print the VLAN ids, and generate test frames with rte_vlan_insert/rte_vlan_insert_tpid.
2. [medium] Implement an incremental checksum update for a changed destination IP (RFC 1624) and verify it.
3. [medium] Modify mini_l2fwd to drop frames whose destination MAC is not broadcast or the port's own MAC.
4. [stretch] Build an IPv6/UDP frame with a non-zero flow label using the 26.11 macros and verify it decodes.

**Sources**

- doc/guides/prog_guide/mbuf_lib.rst (packet types)
- doc/guides/sample_app_ug/l2_forward_real_virtual.rst
- lib/net/rte_ether.h
- lib/net/rte_ip4.h
- lib/net/rte_ip6.h
- lib/net/rte_udp.h
- lib/net/rte_tcp.h
- lib/net/rte_icmp.h
- lib/net/rte_arp.h
- lib/net/rte_cksum.h
- lib/net/rte_net.h
- lib/eal/include/generic/rte_byteorder.h
- examples/l2fwd/main.c
- /home/user/ai_lab/dpdk_research/research/07-packet-processing-libs.md
- /home/user/ai_lab/dpdk_research/research/07-examples/gen_pcap.py
- /home/user/ai_lab/dpdk_research/research/07-examples/pcap_summary.py
- lib/net/rte_net_crc.h
- lib/net/rte_vxlan.h
- lib/net/rte_geneve.h
- lib/net/rte_gtp.h
- lib/net/rte_mpls.h
- lib/eal/include/rte_common.h
- doc/guides/rel_notes/release_26_11.rst (Removed Items)

## 11. EAL Services in One Evolving App: Timers, Service Cores, Alarms, Keepalive, a Control Shell and App Options

*Folder:* `chapters/11-eal-services-timers/` · *Level:* intermediate · *Prerequisites:* ch3, ch8, ch10

One application grows through the chapter, and each step motivates the next library. Start from ch10's mini_l2fwd: (1) print stats every second with rte_timer; (2) move the stats work onto a service lcore (-S, the service lcore also listed in -l); (3) add a keepalive watchdog that notices a stalled forwarding lcore; (4) add a cmdline shell ('show stats', 'set burst N', 'quit'); (5) give the app proper options with rte_argparse and an rte_cfgfile .ini file. EAL alarms get a small side demo, and jobstats a short section. The EAL toolbox (rand, bitmap/bitset, errno, hexdump, strings, tailq, uuid and the rte_common macros, including the 26.11 RTE_PTR_* and __rte_packed_begin/end changes) becomes a compact reference appendix with toolbox.c as a run-and-read program.

**Concepts**

- Why an app needs background work: periodic stats, housekeeping, watchdogs and a control plane, without slowing the poll loop
- Step 1 — rte_timer: skiplist per lcore, rte_timer_subsystem_init, rte_timer_init/reset (SINGLE vs PERIODICAL, target lcore), rte_timer_manage from the poll loop, cost of managing timers
- Step 2 — service cores: components register services, apps map them to service lcores (-S <corelist>, which must also be in -l; -s coremask is deprecated), component vs app runstate, rte_service_run_iter_on_app_lcore; who uses services (event_sw, eventdev adapters, crypto_scheduler)
- Step 3 — keepalive: rte_keepalive_create, register cores, mark alive from the poll loop, dispatch pings from a timer, the failure callback; the l2fwd-keepalive sample
- Step 4 — cmdline library: token types, instruction tables, cmdline_stdin_new, cmdline_interact, driving it from a script, dpdk-cmdline-gen.py
- Step 5 — options: rte_argparse (typed values, callbacks, help) for the app part of argv and rte_cfgfile for an .ini config; getopt from ch2 for comparison
- Side demo — EAL alarms: rte_eal_alarm_set/cancel run in the dpdk-intr thread; never block there
- jobstats: accounting time spent per job in a poll loop (l2fwd-jobstats sample)
- Where each callback runs (poll lcore, service lcore, interrupt thread, control thread) and which DPDK calls are safe there
- Appendix — EAL toolbox reference: rte_rand/rte_rand_max/rte_drand, rte_bitmap, rte_bitops.h/rte_bitset.h, rte_reciprocal, rte_hexdump, rte_errno/rte_strerror, rte_strscpy/rte_strsplit, tailq, uuid
- Appendix — rte_common.h macros: RTE_MIN/RTE_MAX, RTE_DIM, RTE_ALIGN*, RTE_BUILD_BUG_ON, RTE_DIV_ROUND_UP, __rte_packed_begin/end (26.11; __rte_packed removed); 26.11 callout: RTE_PTR_ADD/SUB no longer accept integers
- Per-lcore data: lcore variables are owned by ch14 (link only)

**APIs**

`rte_service_component_register`, `rte_service_component_runstate_set`, `rte_service_runstate_set`, `rte_service_map_lcore_set`, `rte_service_lcore_add`, `rte_service_lcore_start`, `rte_service_lcore_stop`, `rte_service_attr_get`, `rte_service_dump`, `rte_service_run_iter_on_app_lcore`, `rte_service_probe_capability`, `rte_timer_subsystem_init`, `rte_timer_init`, `rte_timer_reset`, `rte_timer_reset_sync`, `rte_timer_stop`, `rte_timer_manage`, `rte_timer_dump_stats`, `rte_eal_alarm_set`, `rte_eal_alarm_cancel`, `rte_jobstats_init`, `rte_jobstats_start`, `rte_jobstats_finish`, `rte_keepalive_create`, `rte_keepalive_register_core`, `rte_keepalive_mark_alive`, `rte_keepalive_dispatch_pings`, `cmdline_parse_token_string_t`, `TOKEN_STRING_INITIALIZER`, `TOKEN_NUM_INITIALIZER`, `cmdline_parse_inst_t`, `cmdline_stdin_new`, `cmdline_interact`, `cmdline_stdin_exit`, `rte_rand`, `rte_rand_max`, `rte_bitmap_init`, `rte_bitmap_set`, `rte_bitmap_scan`, `rte_bitset_init`, `rte_hexdump`, `rte_strerror`, `rte_errno`, `rte_strscpy`, `rte_strsplit`, `RTE_DIM`, `RTE_DIV_ROUND_UP`, `rte_argparse_parse`, `struct rte_argparse`, `rte_cfgfile_load`, `rte_cfgfile_get_entry`, `rte_cfgfile_close`

**Runnable code examples**

- **evolve/step1_timer.c** — mini_l2fwd (copied from ch10) plus a 1 s PERIODICAL rte_timer printing per-port rx/tx/drop deltas; rte_timer_manage is called from the poll loop at most every 100 us of TSC.  
  Run here: `./step1_timer -l 0 --no-pci --no-huge -m 128 --file-prefix=ch11-s1 --vdev=net_ring0 --vdev=net_ring1 (timeout -s INT 6)`
- **evolve/step2_service.c** — Stats printing moved into a registered service mapped to service lcore 2 (-l 0,2 -S 2); prints service stats (calls, cycles) and the deprecation warning when run with -s.  
  Run here: `./step2_service -l 0,2 -S 2 --no-pci --no-huge -m 128 --file-prefix=ch11-s2 --vdev=net_ring0 --vdev=net_ring1 ; and once with -s 0x4 to capture the warning`
- **evolve/step3_keepalive.c** — Adds keepalive: the forwarding lcore marks itself alive; a command-line flag --stall-after 3 makes it stop marking, and the failure callback fires and is logged.  
  Run here: `./step3_keepalive -l 0-2 -S 2 --no-pci --no-huge -m 128 --file-prefix=ch11-s3 --vdev=net_ring0 --vdev=net_ring1 -- --stall-after 3`
- **evolve/step4_cli.c** — Adds a cmdline shell on the main lcore (show stats, set burst N, show keepalive, quit) while forwarding runs on a worker; run.sh feeds commands from a here-doc with sleeps.  
  Run here: `(sleep 1; echo 'show stats'; echo 'set burst 8'; sleep 1; echo 'show stats'; echo quit) | ./step4_cli -l 0-2 -S 2 --no-pci --no-huge -m 128 --file-prefix=ch11-s4 --vdev=net_ring0 --vdev=net_ring1 (main lcore 0 runs the shell, worker 1 forwards, service lcore 2 prints stats)`
- **evolve/step5_options.c** — Final app: rte_argparse parses --burst, --stats-interval, --config <file>; rte_cfgfile reads app.ini ([ports] pairs, [stats] interval); invalid options show argparse's error and help text.  
  Run here: `./step5_options -l 0-2 -S 2 --no-pci --no-huge -m 128 --file-prefix=ch11-s5 --vdev=net_ring0 --vdev=net_ring1 -- --config app.ini --burst 16`
- **alarm_demo.c** — EAL alarms fired from the interrupt thread; prints the thread name to prove where it runs; re-arming pattern and cancel.  
  Run here: `./alarm_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch11-alarm`
- **toolbox.c** — Appendix program: run-and-read tour of the EAL toolbox and rte_common macros (rte_rand, bitmap, bitset, reciprocal, hexdump, errno, strings, tailq, uuid, RTE_PTR_ADD with pointers only, a packed struct with __rte_packed_begin/end).  
  Run here: `./toolbox -l 0 --no-pci --no-huge -m 64 --file-prefix=ch11-tool`

**Visualizations**

- **Service mapping matrix** (interactive) — Services (rows) x service lcores (columns) with mapping toggles and both runstate switches; a loop animation shows each service lcore cycling through its mapped services; MT-unsafe conflict highlighted; call counters tick.
- **Timer skiplist** (animation) — Per-lcore skiplists; inserting timers, rte_timer_manage popping expired timers, a periodic timer re-inserting itself, a timer moving to another lcore.
- **Where callbacks run** (diagram) — Threads diagram: alarms and device events in dpdk-intr, timers in whichever lcore calls rte_timer_manage, services on service lcores.
- **cmdline token matching** (animation) — An input line matched token by token against instruction templates; the learner types and sees which template survives and the completion candidates.
- **Keepalive watchdog** (animation) — Per-core alive flags set by poll loops and cleared by the ping timer; the learner stalls a core and watches its state go ALIVE -> MISSING -> DEAD and the callback fire.
- **Evolving app timeline** (diagram) — The app's architecture after each step: lcores, the service lcore, the interrupt thread and the shell, with the new piece highlighted.

**Exercises**

1. [easy] Convert step1_timer to drive rte_timer_manage from a service instead of the main loop.
2. [medium] Map the stats service to the main lcore with rte_service_run_iter_on_app_lcore and explain the trade-off.
3. [medium] Measure the cost of rte_timer_manage with 0, 10 and 1000 pending timers.
4. [medium] Add a --burst option with range checking to step5_options using rte_argparse value types.
5. [stretch] Add a 'show keepalive' command that prints each core's keepalive state and last-seen time.

**Sources**

- doc/guides/prog_guide/service_cores.rst
- doc/guides/prog_guide/timer_lib.rst
- lib/eal/include/rte_service.h
- lib/eal/include/rte_service_component.h
- lib/eal/common/rte_service.c
- lib/timer/rte_timer.h
- lib/eal/include/rte_alarm.h
- lib/jobstats/rte_jobstats.h
- examples/timer/main.c
- examples/service_cores/main.c
- /home/user/ai_lab/dpdk_research/research/02-eal.md
- doc/guides/sample_app_ug/keep_alive.rst
- lib/eal/include/rte_keepalive.h
- examples/l2fwd-keepalive/main.c
- doc/guides/prog_guide/cmdline.rst
- lib/cmdline/
- lib/eal/include/rte_random.h
- lib/eal/include/rte_bitmap.h
- lib/eal/include/rte_bitset.h
- lib/eal/include/rte_common.h
- lib/eal/include/rte_errno.h
- lib/eal/include/rte_hexdump.h
- doc/guides/rel_notes/release_26_11.rst (RTE_PTR_* changes)
- /home/user/ai_lab/dpdk_research/research/10-examples/cliapp.c
- lib/argparse/rte_argparse.h
- lib/cfgfile/rte_cfgfile.h
- doc/guides/prog_guide/argparse_lib.rst
- examples/l2fwd-keepalive/
- examples/l2fwd-jobstats/

## 12. Port Control, Statistics, Events, Live Reconfiguration and Composite PMDs

*Folder:* `chapters/12-port-control-stats-events/` · *Level:* intermediate · *Prerequisites:* ch8, ch9, ch10, ch11

Everything you do to a port besides receiving and sending, and how to change a running port safely. MAC addresses, promiscuous and multicast modes, MTU, VLAN filters, link control and packet types; the 26.11 statistics model (port totals in rte_eth_stats, per-queue counters only in xstats); event and burst callbacks; runtime hotplug and the device event monitor; per-queue start/stop, deferred start and runtime queue setup; which changes need a full stop/configure/start; an ordered graceful shutdown; seeded failure labs with reset/recovery tied to dev_info.err_handle_mode; and the composite PMDs bonding and failsafe, compared with hardware aggregated ports. Physical-port knobs (FEC, flow control, EEPROM, ...) moved to ch23's NIC qualification section, and representors to ch20.

**Concepts**

- MAC address get/set/add/remove; promiscuous and allmulticast; why promisc matters on tap and real NICs
- MTU: rte_eth_dev_set_mtu vs mbuf data room; scatter for jumbo frames (preview)
- VLAN filtering and stripping configuration; link up/down; rte_eth_link_get (can block) vs _nowait
- Packet types: rte_eth_dev_get_supported_ptypes / set_ptypes
- Basic stats in 26.11: struct rte_eth_stats holds only ipackets/opackets/ibytes/obytes/imissed/ierrors/oerrors/rx_nombuf; q_ipackets[]/q_opackets[]/q_errors[], rte_eth_dev_set_rx/tx_queue_stats_mapping, RTE_ETHDEV_QUEUE_STAT_CNTRS and the rx_qN_errors xstat were removed; per-queue counters are xstats (rx_q<N>_packets ...) looked up with rte_eth_xstats_get_id_by_name; stats reset
- Optional ops and ENOTSUP as a lesson: rte_eth_rx_queue_info_get (only vhost/virtio here), rte_eth_rx_burst_mode_get (only virtio), driver xstats (vhost/virtio/failsafe), mtu_set (absent on ring and pcap); a table grepped from the built PMDs; queue info and burst mode are shown on virtio_user in ch24
- Event callbacks: LSC, QUEUE_STATE, NEW, DESTROY, INTR_RESET, RECOVERY_*; run in the interrupt thread; what is safe to do there
- RX/TX burst callbacks: rte_eth_add_rx_callback / add_tx_callback / first_rx_callback, removal and the quiescence requirement
- Runtime hotplug: rte_dev_probe / rte_dev_remove, rte_eth_dev_close, NEW/DESTROY events, deferring work with alarms; kernel uevent monitoring with rte_dev_event_monitor_start and rte_dev_event_callback_register
- Port ownership API (rte_eth_dev_owner_*) used by composite PMDs (representor ports and the switch domain are in ch20)
- Per-queue control: rx_deferred_start / tx_deferred_start in rte_eth_rxconf/txconf, rte_eth_dev_rx_queue_start/stop and tx_queue_start/stop on a started port, queue state in rte_eth_rx_queue_info_get, rte_eth_rx_queue_is_valid / rte_eth_tx_queue_is_valid; supported by net_tap and net_pcap, ENOTSUP on net_null and net_ring (drivers/net/tap/rte_eth_tap.c, drivers/net/pcap/pcap_ethdev.c)
- Runtime queue setup: dev_info.dev_capa bits RTE_ETH_DEV_CAPA_RUNTIME_RX_QUEUE_SETUP / _TX_QUEUE_SETUP printed with rte_eth_dev_capability_name (stable in 26.11); without them queue setup on a started port returns -EBUSY
- Live reconfiguration: a probed 'what needs a port restart' table (queue count, offloads, RSS conf, MTU on some PMDs, MAC/promisc and RETA do not) and the outage a stop/configure/start cycle costs, measured
- Graceful shutdown in order: stop RX polling, drain app rings and tx_buffers, rte_eth_tx_done_cleanup, rte_eth_dev_stop, rte_eth_dev_close, free pools, rte_eal_cleanup, then verify rte_mempool_in_use_count() == 0
- Bonding: modes round-robin, active-backup, balance (L2/L23/L34 hash), broadcast, 802.3ad, TLB, ALB; rte_eth_bond_create, member add/remove, primary, LSC propagation
- Failsafe: preferred/fallback sub-devices, hotplug-friendly PMD
- Software bonding vs hardware aggregated ports: rte_eth_dev_count_aggr_ports and rte_eth_dev_map_aggr_tx_affinity (stable in 26.11) for NICs that aggregate ports in hardware; the probe returns 0 on every vdev here
- Error recovery: RTE_ETH_EVENT_INTR_RESET -> stop / rte_eth_dev_reset / reconfigure / restart; RTE_ETH_EVENT_ERR_RECOVERING, RECOVERY_SUCCESS, RECOVERY_FAILED and what the app must do in each; dev_info.err_handle_mode (enum rte_eth_err_handle_mode NONE/PASSIVE/PROACTIVE) decides whether the app sees INTR_RESET (passive: the app calls rte_eth_dev_reset) or ERR_RECOVERING then RECOVERY_SUCCESS/FAILED (proactive: the PMD recovers itself)
- Failure signatures: pool too small (rx_nombuf climbs), TX ring full with a slow consumer (drop vs retry vs back-pressure, head-of-line blocking), link flap (LSC or polling), port reset order of operations
- Band 2 review comes at the end of ch13

**APIs**

`rte_eth_macaddr_get`, `rte_eth_dev_default_mac_addr_set`, `rte_eth_dev_mac_addr_add`, `rte_eth_promiscuous_enable`, `rte_eth_promiscuous_disable`, `rte_eth_allmulticast_enable`, `rte_eth_dev_set_mtu`, `rte_eth_dev_get_mtu`, `rte_eth_dev_vlan_filter`, `rte_eth_dev_set_link_up`, `rte_eth_dev_set_link_down`, `rte_eth_link_get_nowait`, `rte_eth_dev_get_supported_ptypes`, `rte_eth_dev_set_ptypes`, `rte_eth_stats_get`, `rte_eth_stats_reset`, `rte_eth_xstats_get_names`, `rte_eth_xstats_get`, `rte_eth_xstats_get_id_by_name`, `rte_eth_xstats_get_by_id`, `rte_eth_rx_queue_info_get`, `rte_eth_rx_burst_mode_get`, `rte_eth_dev_callback_register`, `rte_eth_dev_callback_unregister`, `rte_eth_add_rx_callback`, `rte_eth_add_tx_callback`, `rte_eth_remove_rx_callback`, `rte_dev_probe`, `rte_dev_remove`, `rte_eth_bond_create`, `rte_eth_bond_member_add`, `rte_eth_bond_member_remove`, `rte_eth_bond_mode_set`, `rte_eth_bond_primary_set`, `rte_eth_bond_active_members_get`, `rte_eth_dev_reset`, `rte_eth_dev_conf_get`, `rte_eth_rx_descriptor_dump`, `rte_eth_rx_avail_thresh_set`, `rte_dev_event_monitor_start`, `rte_dev_event_callback_register`, `rte_eth_dev_owner_new`, `rte_eth_dev_owner_set`, `rte_eth_dev_rx_queue_start`, `rte_eth_dev_rx_queue_stop`, `rte_eth_dev_tx_queue_start`, `rte_eth_dev_tx_queue_stop`, `struct rte_eth_rxconf (rx_deferred_start)`, `rte_eth_dev_capability_name`, `RTE_ETH_DEV_CAPA_RUNTIME_RX_QUEUE_SETUP`, `rte_eth_rx_queue_is_valid`, `rte_eth_tx_queue_is_valid`, `rte_eth_tx_done_cleanup`, `rte_mempool_in_use_count`, `enum rte_eth_err_handle_mode`, `rte_eth_dev_count_aggr_ports`, `rte_eth_dev_map_aggr_tx_affinity`

**Runnable code examples**

- **port_ctl.c** — On net_tap: read/set MAC, toggle promiscuous mode while Python injects frames addressed to another MAC (counts change), set MTU, dump all xstats with names (per-queue counters live here), and call rx_queue_info_get / rx_burst_mode_get checking return codes and printing ENOTSUP as a lesson.  
  Run here: `./port_ctl -l 0 --no-pci --no-huge -m 128 --file-prefix=ch12-ctl --vdev=net_tap0,iface=ch12tap0 (python injector runs from run.sh)`
- **events.c** — Registers callbacks for NEW, DESTROY and LSC on all ports; hotplugs net_null7 with rte_dev_probe, then stops/closes/removes it; shows callbacks run in dpdk-intr. Based on research/05-examples/evt.c.  
  Run here: `./events -l 0 --no-pci --no-huge -m 128 --file-prefix=ch12-evt --vdev=net_null0`
- **rxtx_latency.c** — RX callback stamps rte_rdtsc into a dynfield, TX callback computes cycles spent in the app; prints average latency; uses net_ring pairs.  
  Run here: `./rxtx_latency -l 0 ... --file-prefix=ch12-cb --vdev=net_ring0 --vdev=net_ring1`
- **queue_ctl.c** — On net_tap, net_pcap, net_null and net_ring: configure 2 RX queues with queue 1 deferred, start, print queue states via rte_eth_rx_queue_info_get, start/stop queue 1 while a Python sender (tap) or infinite_rx pcap feeds traffic, and show the per-queue xstats change; prints every dev_capa bit with rte_eth_dev_capability_name and the ENOTSUP contrast on null/ring.  
  Run here: `./queue_ctl -l 0 --no-pci --no-huge -m 128 --file-prefix=ch12-qc --vdev=net_tap0,iface=ch12tap2 --vdev=net_pcap0,rx_pcap=in.pcap,infinite_rx=1,tx_pcap=/dev/null --vdev=net_null0 --vdev=net_ring0`
- **runtime_reconf.c** — Live reconfiguration and graceful shutdown lab on net_null/net_ring/tap: tries runtime queue setup (captures -EBUSY/ENOTSUP where the capability is missing), probes which changes need a restart and prints the table, times the outage of a full stop/configure/start cycle under traffic (median of 5), and on SIGINT runs the ordered teardown, asserting rte_mempool_in_use_count() == 0 (prints PASS/FAIL).  
  Run here: `timeout -s INT -k 5 12 ./runtime_reconf -l 0-1 --no-pci --no-huge -m 128 --file-prefix=ch12-rr --vdev=net_null0 --vdev=net_ring0 --vdev=net_tap0,iface=ch12tap3`
- **bonding_modes.c** — Bond of two net_ring members created with rte_eth_bond_create; for modes 0/1/2/3 send 1000 packets with varying 5-tuples and print per-member counts; remove the primary in active-backup to show failover. Ends with a 'hardware aggregation' row: rte_eth_dev_count_aggr_ports on each member and on the bond (0 on vdevs).  
  Run here: `./bonding_modes -l 0 --no-pci --no-huge -m 256 --file-prefix=ch12-bond`
- **failsafe testpmd** — testpmd over net_failsafe0 with dev(net_null0,size=128),dev(net_ring0); show port info and stats of the failsafe port.  
  Run here: `dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch12-fs --vdev='net_failsafe0,dev(net_null0,size=128),dev(net_ring0)' -- --total-num-mbufs=8192 --stats-period 2 --forward-mode=txonly`
- **failure_lab.c** — Seeded faults selected by --mode: pool_dry (pool sized too small: rx_nombuf grows, then recovers when the app frees), tx_full (net_ring with a slow consumer: compare drop, retry and back-pressure policies), link_flap (run.sh does `ip link set ch12tap2 down/up` while forwarding; LSC callback or link polling reacts), reset (simulated INTR_RESET: stop, rte_eth_dev_reset, reconfigure, start; wrong order shown failing).  
  Run here: `./failure_lab -l 0-1 --no-pci --no-huge -m 128 --file-prefix=ch12-fail-<mode> --vdev=net_ring0 --vdev=net_tap0,iface=ch12tap2 -- --mode pool_dry|tx_full|link_flap|reset`

**Visualizations**

- **Where packets get counted (Sankey)** (diagram) — Flow from wire -> NIC (imissed, ierrors) -> PMD (rx_nombuf) -> app -> TX (oerrors) showing which counter increments at each drop point. Per-queue counters are drawn as xstats, not as fields of rte_eth_stats.
- **Callback chain in rx_burst** (animation) — rx_burst calls the PMD, then each registered RX callback in order mutates/inspects the burst before the app sees it; TX callbacks run before the PMD.
- **Event flow** (animation) — Interrupt thread receives LSC/NEW/DESTROY events and invokes callbacks while data-path lcores keep polling; an unsafe action (closing a port from its own callback) flashes red.
- **Bonding mode selector** (interactive) — Packets coloured by flow fan out to members according to the chosen mode; active-backup failover when a member link turns red; broadcast duplicates.
- **Promiscuous filter** (diagram) — Frames with different destination MACs hitting the port filter with promisc on/off.
- **Failure signature board** (interactive) — Learner picks a seeded fault; counters (rx_nombuf, imissed, oerrors, app drops, in_use_count) animate with the signature that fault produces, then the recovery steps run in order.
- **Queue and port state explorer** (interactive) — Per-queue states (deferred, stopped, started) inside a port state machine. The learner clicks API calls (rx_queue_start, queue_setup, configure, set_mtu, reta_update); the widget predicts OK / -EBUSY / -ENOTSUP for the selected PMD from the probed table and shows the traffic gap a restart causes.

**Exercises**

1. [easy] Add an LSC callback to a tap port and explain why it never fires; poll link status instead.
2. [medium] Use xstats by-id to read only rx_good_packets every 100 ms with minimal overhead.
3. [medium] Make rxtx_latency remove its callbacks safely while traffic flows.
4. [stretch] Compare balance mode L2 vs L34 hashing distribution with 16 flows.
5. [stretch] Make failure_lab's reset mode survive a reset requested while traffic is flowing on another lcore (quiesce the data path first).
6. [medium] Drain and stop RX queue 1 of a tap port without stopping the port, then restart it; show that no mbufs leak.

**Sources**

- doc/guides/prog_guide/ethdev/ethdev.rst
- doc/guides/prog_guide/link_bonding_poll_mode_drv_lib.rst
- doc/guides/nics/fail_safe.rst
- doc/guides/prog_guide/device_hotplug.rst
- doc/guides/sample_app_ug/rxtx_callbacks.rst
- doc/guides/sample_app_ug/link_status_intr.rst
- lib/ethdev/rte_ethdev.h
- lib/ethdev/rte_ethdev.c
- drivers/net/bonding/rte_eth_bond.h
- drivers/net/failsafe/
- examples/rxtx_callbacks/main.c
- examples/bond/main.c
- /home/user/ai_lab/dpdk_research/research/05-ethdev.md
- /home/user/ai_lab/dpdk_research/research/05-examples/evt.c
- /home/user/ai_lab/dpdk_research/research/06-virtual-devices-and-virtio.md
- doc/guides/prog_guide/ethdev/switch_representation.rst
- lib/eal/include/rte_dev.h (device events)
- doc/guides/rel_notes/release_26_11.rst (queue stats mapping removal)
- drivers/net/tap/rte_eth_tap.c (rx_queue_start)
- drivers/net/pcap/pcap_ethdev.c (rx_queue_start)

## 13. Observability and Debugging: Telemetry, Metrics, Tracing, Logs, gdb and Post-Mortem Analysis

*Folder:* `chapters/13-observability-debugging/` · *Level:* intermediate · *Prerequisites:* ch3, ch7, ch8, ch9, ch11, ch12

How to see inside a running DPDK application and fix it, taught right after the port chapters so later chapters can use these tools. Telemetry (socket, built-in endpoints, a custom endpoint, the lcore usage callback, the Prometheus exporter), the metrics, latency and bitrate libraries, rte_trace, fast-path logging, dpdk-ethtool, then debugging: gdb on a live process, ASan and mbuf sanity checks, and a post-mortem core-dump workflow that includes hugepage memory. Five seeded debug labs and the consolidated startup-error table close the chapter, followed by the band 2 review and band 2 project. Multi-process tools (proc-info, dumpcap) are in ch16.

**Concepts**

- Telemetry: unix SEQPACKET socket dpdk_telemetry.v2 in the runtime dir, JSON replies, built-in endpoints (/ethdev/list, /ethdev/stats, /ethdev/xstats, /eal/lcore/usage, /mempool/info, /eal/heap_info)
- dpdk-telemetry.py, a raw Python client, dpdk-telemetry-watcher.py; custom endpoints with rte_telemetry_register_cmd and rte_tel_data_* (limits: name length, 16 KB output, runs on another thread)
- lcore usage reporting via rte_lcore_register_usage_cb
- /eal/lcore/usage returns data only if the app registered rte_lcore_register_usage_cb (testpmd does with --record-core-cycles)
- dpdk-telemetry-exporter.py (Prometheus/OpenMetrics), dpdk-telemetry-client.py, dpdk-telemetry-watcher.py; usertools/telemetry-endpoints
- Metrics library (rte_metrics_init/reg_names/update_values/get_values), bitrate stats and latency stats with their RX/TX callbacks. 26.11: rte_metrics_telemetry.h and the rte_metrics_tel_* helpers were removed; register your own telemetry endpoint or use /ethdev/xstats
- rte_trace: RTE_TRACE_POINT definitions, registration TU rules, --trace / --trace-dir / --trace-mode, CTF output, fast-path tracepoints compiled out by default
- Fast-path logging: RTE_LOG_DP and compile-time RTE_LOG_DP_LEVEL; logging to syslog/journald in production
- ethtool-like management with the prebuilt dpdk-ethtool sample
- Debugging: gdb on a DPDK app (threads, breakpoints in PMD functions), rte_panic and rte_dump_stack, ASan builds, RTE_LIBRTE_MBUF_DEBUG, mbuf history, buildtype=debug, troubleshooting decision tree
- Post-mortem debugging: ulimit -c, /proc/sys/kernel/core_pattern (here 'core'), systemd-coredump on real hosts; /proc/<pid>/coredump_filter bits 5-6 (hugetlb private/shared) — without them mbuf, ring and mempool contents are missing from the core; EAL marks reserved-but-unused VA MADV_DONTDUMP (lib/eal/common/eal_common_memory.c); core size grows with -m
- Startup-error table (consolidated): links the ch4 EAL rows and ch8 port rows into one 'error message -> cause -> fix' page used by the error-decoder widget; multi-process rows are added in ch16; ch29 links it
- Debug labs (ch3-ch12 material only): promisc off with a foreign dst MAC, MTU 9000 with 2 KB mbufs and no scatter, mbuf leak via in_use_count, double free caught by rte_mbuf_sanity_check/ASan on --no-huge, two lcores polling one queue
- Band 2 review page (ch5-ch13) with a predict-then-reveal quiz, and the band 2 project

**APIs**

`rte_telemetry_register_cmd`, `rte_tel_data_start_dict`, `rte_tel_data_add_dict_uint`, `rte_tel_data_start_array`, `rte_lcore_register_usage_cb`, `rte_metrics_init`, `rte_metrics_reg_names`, `rte_metrics_update_values`, `rte_metrics_get_values`, `rte_stats_bitrate_create`, `rte_stats_bitrate_reg`, `rte_stats_bitrate_calc`, `rte_latencystats_init`, `rte_latencystats_get`, `rte_latencystats_uninit`, `RTE_TRACE_POINT`, `RTE_TRACE_POINT_REGISTER`, `rte_trace_point_emit_u32`, `rte_trace_save`, `rte_trace_is_enabled`, `rte_panic`, `rte_dump_stack`, `RTE_LOG_DP`, `rte_mbuf_sanity_check`, `rte_mempool_in_use_count`, `rte_pktmbuf_dump`

**Runnable code examples**

- **telemetry_app.c** — A forwarding app on net_null ports that registers /ch13/stats returning a dict of counters; run.sh queries it with dpdk-telemetry.py and with a raw Python SEQPACKET client (telclient.py), plus /eal/lcore/usage. It registers an rte_lcore_register_usage_cb reporting busy/total poll cycles so /eal/lcore/usage is populated; run.sh then starts dpdk-telemetry-exporter.py on 127.0.0.1 and fetches /metrics with python3 urllib.  
  Run here: `./telemetry_app -l 0-1 --no-pci --no-huge -m 128 --file-prefix=ch13-tel --vdev=net_null0 --vdev=net_null1 & ; echo /ch13/stats | dpdk-telemetry.py -f ch13-tel`
- **latency_metrics.c** — Forwarding loop over a net_ring pair with rte_latencystats and bitrate stats; publishes values with rte_metrics_* and exposes them through its own rte_telemetry_register_cmd endpoint (/ch13/latency). It does not use the removed rte_metrics_tel_* API.  
  Run here: `./latency_metrics -l 0 --no-pci --no-huge -m 128 --file-prefix=ch13-lat --vdev=net_ring0 --vdev=net_ring1 & ; echo /ch13/latency | dpdk-telemetry.py -f ch13-lat`
- **trace_demo.c** — Defines two custom tracepoints (slow-path and fast-path), runs with --trace=ch13.* --trace-dir=./trace, and lists/sizes the CTF files and metadata (no babeltrace here: print metadata excerpt).  
  Run here: `./trace_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-tr --trace='ch13\..*' --trace-dir=./trace`
- **dpdk-ethtool + RTE_LOG_DP** — Prebuilt dpdk-ethtool on net_tap driven by commands on stdin (drvinfo, link, portstats); plus logdp.c showing an RTE_LOG_DP debug call compiled out at the default RTE_LOG_DP_LEVEL.  
  Run here: `printf 'drvinfo\nlink\nportstats 0\nquit\n' | timeout -s INT -k 5 10 $DPDK_SRC/build/examples/dpdk-ethtool -l 0 --no-pci --no-huge -m 640 --file-prefix=ch13-eth --vdev=net_tap0,iface=ch13tap0 (verified: -m 128..512 fail with 'rte_pktmbuf_pool_create failed' because the pool is sized from desc_lim.nb_max; -m 640 works); ./logdp -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-logdp`
- **gdb_live (panic_demo.c)** — A program that calls rte_panic after corrupting an mbuf header; run under 'gdb -batch -ex run -ex bt' to capture a backtrace, threads (info threads shows dpdk-intr, telemetry) and a breakpoint in the null PMD rx function.  
  Run here: `gdb -batch -ex run -ex bt -ex 'info threads' --args ./panic_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-gdb`
- **crash_postmortem.sh** — Post-mortem lab: ulimit -c unlimited; panic_demo crashes with a corrupted mbuf, once with hugepages -m 32 and the default coredump_filter and once with coredump_filter=0x7f (set on the shell before exec); compares core sizes, then runs gdb -batch -ex bt -ex 'p *(struct rte_mbuf *)m' -ex 'p *mp' on each core to show that the mbuf and mempool contents are only readable when the hugetlb bits are set. Cores are deleted by the trap.  
  Run here: `./crash_postmortem.sh (prefix ch13-core-*, -m 32 hugepages, run in its own directory so 'core' files land there)`
- **debug_labs/** — Five small broken programs, each with README (symptom, diagnosis commands such as telemetry /ethdev/xstats and /mempool/info, gdb bt, ASan report, --log-level=pmd.net.*:debug, and the fix) and captured real error text: promisc_off (tap), mtu_noscatter (net_ring), leak (in_use_count creeps), double_free (sanity check/ASan, --no-huge), two_lcores_one_queue (net_ring). EAL init failures are in ch4's startup_errors.sh.  
  Run here: `debug_labs/run_all.sh; each lab uses prefix ch13-dbg-<name>, timeout 15 s`
- **band2_project/ (multi-core L2 forwarder)** — Band 2 project with solution: extends ch11's evolving app to two forwarding lcores, each owning one net_ring port pair, per-lcore cache-aligned stats, a periodic timer report, a /band2/stats telemetry endpoint and a cmdline 'show stats'. run.sh is the acceptance check: it sends a fixed number of packets and prints PASS when rx == tx + drops per lcore and rte_mempool_in_use_count() returns to 0.  
  Run here: `band2_project/run.sh (prefix ch13-b2, -l 0-2, --no-huge -m 128, timeout 15 s)`

**Visualizations**

- **Telemetry request/response** (animation) — Client connects to the socket, sends '/ethdev/stats,0', the telemetry thread calls the handler, JSON flows back; a live-updating mock dashboard from captured outputs.
- **Trace buffer and CTF** (animation) — Per-thread trace buffers filling with events (fast-path vs slow-path), saved into a CTF directory (metadata + channel files).
- **Troubleshooting decision tree** (interactive) — Click through symptoms (no packets, drops, low throughput, crash) to checks and fixes, following howto/debug_troubleshoot.rst.
- **Observability map** (diagram) — Which tool sees what: telemetry (in-process thread), proc-info/dumpcap (secondary), trace (buffers), logs, gdb.
- **Debug lab triage** (interactive) — The learner chooses a symptom and a diagnostic command; the widget shows the real captured output of that command for the seeded bug and asks the learner to name the cause before revealing it.
- **Core-dump contents explorer** (interactive) — The learner toggles coredump_filter bits (anon private/shared, file-backed, ELF headers, hugetlb private/shared); the widget shows which mappings of a DPDK process (from its real /proc/<pid>/maps) are written to the core, the measured core size for the two captured settings, and whether 'p *m' works in gdb.

**Exercises**

1. [easy] Add an endpoint /ch13/port_rates that computes pps since the previous call.
2. [medium] Write a shell loop that polls /ethdev/stats every 0.5 s and prints pps.
3. [medium] Take a core of panic_demo with coredump_filter=0x7f and find the mbuf's pool name and refcnt in gdb.
4. [stretch] Add a fast-path tracepoint and show it is compiled out unless RTE_ENABLE_TRACE_FP is defined.
5. [stretch] Pick one debug lab, break it a second way, and write the diagnosis steps another engineer should follow.
6. [stretch] Band 2 project extension: add 'set burst N' to the shell and show the per-lcore Mpps change.

**Sources**

- doc/guides/prog_guide/telemetry_lib.rst
- doc/guides/howto/telemetry.rst
- doc/guides/prog_guide/metrics_lib.rst
- doc/guides/prog_guide/trace_lib.rst
- doc/guides/howto/debug_troubleshoot.rst
- doc/guides/prog_guide/asan.rst
- lib/telemetry/rte_telemetry.h
- lib/telemetry/telemetry.c
- lib/metrics/rte_metrics.h
- lib/latencystats/rte_latencystats.h
- lib/bitratestats/rte_bitrate.h
- lib/eal/include/rte_trace_point.h
- usertools/dpdk-telemetry.py
- /home/user/ai_lab/dpdk_research/research/10-building-debugging-ecosystem.md
- /home/user/ai_lab/dpdk_research/research/10-examples/devapp.c
- /home/user/ai_lab/dpdk_research/research/10-examples/telclient.py
- usertools/dpdk-telemetry-exporter.py
- usertools/dpdk-telemetry-client.py
- usertools/telemetry-endpoints/
- lib/log/rte_log.h (RTE_LOG_DP)
- doc/guides/sample_app_ug/ethtool.rst
- examples/ethtool/
- lib/eal/common/eal_common_memory.c (MADV_DONTDUMP)
- man 5 core (coredump_filter)
- doc/guides/rel_notes/release_26_11.rst (metrics removals)

## 14. Concurrency: Atomics, Memory Ordering, Locks and RCU

*Folder:* `chapters/14-concurrency-atomics-rcu/` · *Level:* advanced · *Prerequisites:* ch5, ch6, ch11, ch12

Multi-core packet processing lives or dies on how cores share data, so this comes before any shared table. Covers the C11-style atomics that 26.11 requires (rte_atomic32 and rte_smp_mb are gone), memory ordering on x86 vs Arm with litmus tests, the DPDK lock zoo (spinlock, ticketlock, MCS, rwlock, pflock, seqlock), lock-free structures and the ABA problem, RCU QSBR for safe memory reclamation (used by hash, LPM and FIB in ch17-ch18), and per-lcore data — padded arrays, TLS and lcore variables — as the best way to avoid sharing.

**Concepts**

- Data races, atomicity and visibility; why volatile is neither atomic nor a barrier
- 26.11 atomics: RTE_ATOMIC(T), rte_atomic_load/store/fetch_add/exchange/compare_exchange_*_explicit, rte_memory_order_relaxed/acquire/release/acq_rel/seq_cst, rte_atomic_thread_fence; migration table from removed APIs
- Memory ordering: x86 TSO (store buffer) vs Arm weak ordering; message passing and store-buffering litmus tests. On this x86 VM the message-passing test with relaxed ordering shows zero forbidden outcomes, because x86-TSO never reorders store-store or load-load; only store-buffering is observable in hardware. So the chapter shows compiler reordering instead (objdump -d of the -O2 code for relaxed vs release, and a variant with a compiler barrier), and marks the Arm outcomes in the playground as 'allowed by the model, not measurable on this VM', citing herd7/litmus7 results and the Arm memory model docs. No Arm numbers are invented
- rte_pause, rte_wait_until_equal_16/32/64; device memory is different: rte_io_wmb/rte_io_rmb and rte_write32/rte_read32 order CPU accesses against a device (26.11 release notes), while rte_atomic_thread_fence orders CPU against CPU (the doorbell box is in ch23)
- Locks: rte_spinlock (+recursive, trylock), rte_ticketlock (fairness), rte_mcslock (queue lock, local spinning), rte_rwlock, rte_pflock (phase-fair), rte_seqcount/rte_seqlock (readers retry); lock annotations
- Lock-zoo table rows that are often confused: rte_seqcount (single writer, no lock) vs rte_seqlock (seqcount + spinlock for multiple writers); rte_pflock phase-fair reader/writer alternation vs rwlock writer starvation
- Contention costs on this VM (spinlock vs ticket vs MCS); preemption of lock holders
- Static lock checking: rte_lock_annotations.h (__rte_guarded_by, __rte_exclusive_locks_required, __rte_no_thread_safety_analysis) with clang -Wthread-safety -DRTE_ANNOTATE_LOCKS; verified here: a counter guarded by an rte_spinlock_t written without the lock gives 'writing variable 'counter' requires holding spinlock 'lk' exclusively'
- Lock-free structures revisited: ring CAS (ch5) and the LF stack ABA problem (ch6's step-through widget is embedded, not re-taught); this chapter adds only the fix, a 128-bit CAS of pointer + counter with rte_atomic128_cmp_exchange
- RCU QSBR: readers report quiescent states, writers wait for a grace period; rte_rcu_qsbr_get_memsize/init/thread_register/online/offline/quiescent/start/check/synchronize; defer queue rte_rcu_qsbr_dq_*
- Per-lcore data (this chapter owns it): arrays indexed by rte_lcore_id with __rte_cache_aligned / RTE_CACHE_GUARD, TLS (RTE_PER_LCORE), lcore variables (RTE_LCORE_VAR_HANDLE, RTE_LCORE_VAR_ALLOC, RTE_LCORE_VAR, RTE_LCORE_VAR_LCORE, RTE_LCORE_VAR_FOREACH; experimental, build with -DALLOW_EXPERIMENTAL_API; there is no RTE_LCORE_VAR_VALUE); aggregation by a reader; thread-safety table of DPDK APIs (thread_safety.rst)
- Forward pointer: RCU integrations rte_hash_rcu_qsbr_add (ch17), rte_lpm_rcu_qsbr_add / rte_fib_rcu_qsbr_add (ch18)
- Ownership: this chapter owns false sharing and the MESI cache-line ping-pong; ch22 links to it and reuses its data

**APIs**

`RTE_ATOMIC`, `rte_atomic_load_explicit`, `rte_atomic_store_explicit`, `rte_atomic_fetch_add_explicit`, `rte_atomic_compare_exchange_strong_explicit`, `rte_atomic_exchange_explicit`, `rte_atomic_thread_fence`, `rte_memory_order_acquire`, `rte_memory_order_release`, `rte_pause`, `rte_wait_until_equal_32`, `rte_spinlock_lock`, `rte_spinlock_trylock`, `rte_spinlock_recursive_lock`, `rte_ticketlock_lock`, `rte_mcslock_lock`, `rte_mcslock_unlock`, `rte_rwlock_read_lock`, `rte_rwlock_write_lock`, `rte_pflock_read_lock`, `rte_pflock_write_lock`, `rte_seqlock_read_begin`, `rte_seqlock_read_retry`, `rte_seqlock_write_lock`, `rte_atomic128_cmp_exchange`, `rte_rcu_qsbr_get_memsize`, `rte_rcu_qsbr_init`, `rte_rcu_qsbr_thread_register`, `rte_rcu_qsbr_thread_online`, `rte_rcu_qsbr_thread_offline`, `rte_rcu_qsbr_quiescent`, `rte_rcu_qsbr_start`, `rte_rcu_qsbr_check`, `rte_rcu_qsbr_synchronize`, `rte_rcu_qsbr_dq_create`, `rte_rcu_qsbr_dq_enqueue`, `rte_rcu_qsbr_dq_reclaim`, `RTE_LCORE_VAR_HANDLE`, `RTE_LCORE_VAR_ALLOC`, `RTE_LCORE_VAR`, `RTE_LCORE_VAR_LCORE`, `RTE_LCORE_VAR_FOREACH`, `RTE_CACHE_GUARD`, `RTE_DEFINE_PER_LCORE`, `rte_io_wmb`, `rte_io_rmb`, `rte_seqcount_read_begin`, `__rte_guarded_by`, `__rte_exclusive_locks_required`

**Runnable code examples**

- **litmus.c** — Message-passing test with relaxed vs release/acquire, and the store-buffering (Dekker) test which shows r1==r2==0 on x86 without a seq_cst fence; counts forbidden outcomes over 1M iterations on two lcores. Also builds litmus_mp at -O2 with relaxed and with release/acquire and prints the objdump of the writer to show where the compiler may move the stores; the MP result here is 0 forbidden outcomes, explained by TSO.  
  Run here: `./litmus -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch14-litmus`
- **locks_bench.c** — Cycles/op uncontended and contended for spinlock, ticketlock, MCS, rwlock, pflock and seqlock with 1..3 lcores, plus a fairness histogram of acquisitions per lcore. Extends research/09-examples/bench.c. Each configuration runs for a fixed TSC time; median of 5.  
  Run here: `./locks_bench -l 0-3 --no-pci --no-huge -m 64 --file-prefix=ch14-locks`
- **seqlock_cfg.c** — A writer updates a 64-byte config at ~1 kHz; readers use rte_seqlock_read_begin/retry, count retries and never see torn data.  
  Run here: `./seqlock_cfg -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch14-seq`
- **rcu_swap.c** — Readers dereference a shared config pointer; the writer swaps in a new one, calls rte_rcu_qsbr_synchronize and frees the old one; measures grace periods; a 'broken' mode frees immediately and detects use-after-free via poisoning. Based on research/09-examples/rcu.c.  
  Run here: `./rcu_swap -l 0-3 --no-pci --no-huge -m 64 --file-prefix=ch14-rcu`
- **counters.c** — Per-lcore counters four ways on 3 workers: one shared atomic, a packed array (false sharing), a cache-aligned/RTE_CACHE_GUARD array and an lcore variable (static RTE_LCORE_VAR_HANDLE(struct c, h); RTE_LCORE_VAR_ALLOC(h); RTE_LCORE_VAR(h)->v++; aggregated with RTE_LCORE_VAR_FOREACH); cycles/increment (median of 5) and correctness.  
  Run here: `./counters -l 0-3 --no-pci --no-huge -m 64 --file-prefix=ch14-cnt (built with -DALLOW_EXPERIMENTAL_API)`
- **thread_safety/ (static lock check)** — A 10-line file with a counter __rte_guarded_by(&lk), one function that forgets rte_spinlock_lock and one that does it right; compiled with clang -fsyntax-only -Wthread-safety -Wno-invalid-feature-combination -DRTE_ANNOTATE_LOCKS $(pkg-config --cflags libdpdk); the captured warning is the expected output.  
  Run here: `make thread_safety (compile-only; no EAL run)`

**Visualizations**

- **Memory-ordering playground** (interactive) — Two threads with selectable orderings (relaxed/acq-rel/seq_cst) and architecture (x86-TSO/Arm); shows which outcomes are allowed; animates the x86 store buffer letting loads bypass stores.
- **Lock zoo** (animation) — Spinlock (everyone hammering one line), ticket lock (now-serving counter), MCS (queue of nodes each spinning on its own flag), seqlock (reader retries on odd/changed sequence).
- **RCU grace period timeline** (interactive) — Reader lanes with critical sections and quiescent ticks; writer unlinks at t0 and frees after the last reader passes a tick; drag a long critical section to stretch the grace period; offline readers greyed out.
- **Cache-line ping-pong (MESI)** (animation) — Two cores writing counters in the same line; M/S/I states flip with each write; padded layout stops the ping-pong; bars show the cycles measured by counters.c on this machine (no hard-coded numbers).
- **API migration table** (diagram) — Removed rte_atomic32_*/rte_smp_*mb on the left, 26.11 replacements on the right.
- **Per-lcore data layouts** (interactive) — Grid comparing a packed counter array (false sharing), padded arrays and lcore-variable buffers; click an lcore to see which cache lines it touches and which other cores' lines get invalidated.

**Exercises**

1. [easy] Port a snippet using rte_atomic32_inc, rte_smp_wmb and a doorbell write to the 26.11 API: decide for each barrier whether it becomes rte_atomic_thread_fence / a release store (CPU to CPU) or rte_io_wmb (CPU to device).
2. [medium] Make rcu_swap use the defer queue instead of synchronize and compare writer latency.
3. [medium] Explain why MCS is slower than a spinlock on this VM but scales better on big machines.
4. [stretch] Find a DPDK API documented as not thread-safe and write a test that breaks it.

**Sources**

- doc/guides/prog_guide/rcu_lib.rst
- doc/guides/prog_guide/thread_safety.rst
- doc/guides/rel_notes/release_26_11.rst (removed atomics)
- lib/eal/include/rte_stdatomic.h
- lib/eal/include/generic/rte_atomic.h
- lib/eal/include/generic/rte_pause.h
- lib/eal/include/generic/rte_spinlock.h
- lib/eal/include/rte_ticketlock.h
- lib/eal/include/rte_mcslock.h
- lib/eal/include/generic/rte_rwlock.h
- lib/eal/include/rte_pflock.h
- lib/eal/include/rte_seqlock.h
- lib/eal/include/rte_seqcount.h
- lib/rcu/rte_rcu_qsbr.h
- lib/stack/rte_stack_lf_c11.h
- /home/user/ai_lab/dpdk_research/research/09-performance-concurrency.md
- /home/user/ai_lab/dpdk_research/research/09-examples/bench.c
- /home/user/ai_lab/dpdk_research/research/09-examples/rcu.c
- doc/guides/prog_guide/lcore_var.rst
- lib/eal/include/rte_lcore_var.h
- lib/eal/include/rte_per_lcore.h

## 15. Scaling Out Across Cores: Multi-Queue, RSS and Toeplitz, Run-to-Completion vs Pipeline, Distributor and Reorder

*Folder:* `chapters/15-scale-out-rss-pipelines/` · *Level:* advanced · *Prerequisites:* ch5, ch6, ch7, ch9, ch12, ch14

How to use several cores on real packets. Part 1 starts at the NIC: multiple RX queues, RSS configuration, the redirection table, the Toeplitz hash computed in software with rte_thash (verified against the spec vector), symmetric RSS by key or by hash function, and the encapsulation level. Real flow-to-queue steering is shown on net_af_packet with qpairs=2,fanout_mode=hash on a veth (the kernel's flow hash, not Toeplitz); net_null is used only for the RETA API, since its per-queue counters are poll-driven. Part 2 builds a run-to-completion forwarder with one queue per lcore, then a ring pipeline with per-stage cycle accounting and back-pressure (with an optional 32-bit compressed-pointer ring using lib/ptr_compress), then the distributor and reorder libraries and SORING, and ends with a measured comparison of the models. Placed before the lookup chapters so that l3fwd's --config is understood when it is first run.

**Concepts**

- Part 1 — Multi-queue and RSS
- Queue-per-lcore design; no locks inside PMDs; never poll one queue from two lcores
- mq_mode RTE_ETH_MQ_RX_RSS, rss_hf masked with flow_type_rss_offloads, rss_key, key length; 26.11 validation of RSS with >1 queue
- RETA: size, groups of 64 (struct rte_eth_rss_reta_entry64), update/query; mbuf hash.rss and RTE_ETH_RX_OFFLOAD_RSS_HASH
- Symmetric RSS (0x6d5a key / symmetric hash function) for stateful apps
- Toeplitz hash library rte_thash: rte_softrss, rte_softrss_be, symmetric keys, GFNI acceleration, rte_thash_adjust_tuple for predictable RSS (e.g. SNAT source port selection)
- Hash function vs key: the symmetric-key trick (0x6d5a repeated) vs rss_conf.algorithm = RTE_ETH_HASH_FUNCTION_SYMMETRIC_TOEPLITZ or _SYMMETRIC_TOEPLITZ_SORT; dev_info.rss_algo_capa printed with rte_eth_dev_rss_algo_name; rte_eth_find_rss_algo (stable in 26.11)
- Encapsulation level: rss_conf.rss_level with RTE_ETH_RSS_LEVEL_OUTERMOST / _INNERMOST for tunnelled traffic (VXLAN picture: hash the outer 5-tuple vs the inner one)
- What steers here: net_af_packet with qpairs=N,fanout_mode=hash on a veth spreads real flows by the kernel flow hash (verified: 40 UDP flows -> 240/160 packets over 2 queues); net_null generates packets on whichever queue is polled, so a RETA or key changes nothing in its per-queue xstats; tap has no RETA and does RSS only through the rte_flow RSS action with an eBPF program when built with enable_tap_rss (not built here)
- Part 2 — Structuring the work
- Execution models in practice: run-to-completion (RTC) with queue-per-lcore vs pipeline with rings vs event-driven (preview of ch25)
- RTC design: one RX and one TX queue per lcore, per-lcore mempool caches, no shared state on the fast path, RSS spreads flows
- Pipeline design: RX lcore, worker lcores, TX lcore connected by rings; ring sync mode choice per hop (SP/SC vs MP/MC); burst sizes between stages
- Per-stage cycle accounting with rte_rdtsc and jobstats-style busy/idle counters; finding the bottleneck stage
- Back-pressure between stages: full rings, drop vs wait, mempool exhaustion when a stage stalls
- Ordering: why parallel workers reorder packets of a flow; flow affinity vs order restoration
- Distributor library: tag-based flow affinity, rte_distributor_process on the distributor core, worker get/return API, in-flight tracking, single vs burst mode
- Reorder library: sequence-number dynfield (rte_reorder_seqn_dynfield_offset), window, insert/drain, early/late errors, rte_reorder_min_seqn_set; the packet_ordering sample
- Pointer compression (lib/ptr_compress): rte_ptr_compress_32_shift / rte_ptr_decompress_32_shift (and _16_shift) pass mbuf pointers as 32-bit offsets over a 4-byte element ring (rte_ring_create_elem, ch5), halving ring traffic between stages; precondition: the pool memory fits in a 2^(32+shift) window, checked with rte_mempool_mem_iter and RTE_PTR_COMPRESS_BITS_NEEDED_FOR_POINTER_WITHIN_RANGE
- SORING (staged-ordered ring, ch5) as a lighter staged-ordering alternative
- Measured comparison on this VM (median of 5, no oversubscription) and how to choose a model; why results on 4 shared cores differ from a real server

**APIs**

`rte_eth_dev_configure (rxmode.mq_mode, rx_adv_conf.rss_conf)`, `rte_eth_dev_rss_hash_update`, `rte_eth_dev_rss_hash_conf_get`, `rte_eth_dev_rss_reta_update`, `rte_eth_dev_rss_reta_query`, `struct rte_eth_rss_reta_entry64`, `rte_softrss`, `rte_softrss_be`, `rte_convert_rss_key`, `rte_thash_init_ctx`, `rte_thash_add_helper`, `rte_thash_adjust_tuple`, `rte_eth_dev_rss_algo_name`, `rte_eth_find_rss_algo`, `RTE_ETH_HASH_FUNCTION_SYMMETRIC_TOEPLITZ_SORT`, `RTE_ETH_RSS_LEVEL_INNERMOST`, `rte_ptr_compress_32_shift`, `rte_ptr_decompress_32_shift`, `rte_ring_create_elem`, `rte_mempool_mem_iter`, `rte_eth_dev_configure (rxmode.mq_mode = RTE_ETH_MQ_RX_RSS)`, `rte_eth_rx_queue_setup`, `rte_eal_remote_launch`, `rte_ring_create`, `rte_ring_enqueue_burst`, `rte_ring_dequeue_burst`, `rte_rdtsc`, `rte_distributor_create`, `rte_distributor_process`, `rte_distributor_returned_pkts`, `rte_distributor_flush`, `rte_distributor_get_pkt`, `rte_distributor_return_pkt`, `rte_reorder_create`, `rte_reorder_insert`, `rte_reorder_drain`, `rte_reorder_seqn_dynfield_offset`, `rte_reorder_min_seqn_set`, `rte_reorder_free`, `rte_soring_init (overview)`

**Runnable code examples**

- **rss_lab.c** — Software Toeplitz over 10k random flows -> RETA histogram per queue; then configure net_null with 4 RX queues and RSS, update and query the 128-entry RETA, read per-queue xstats rx_q0..q3 and /ethdev/rss_info via telemetry; dpdk-rss-flows.py generates flows for chosen queues. Based on research/05-examples/rss.c. Merged with the former thash_rss.c: verifies rte_softrss against the Microsoft verification vector, shows that the symmetric key gives equal hashes for swapped tuples, uses rte_thash_adjust_tuple to pick source ports landing on chosen queues, and prints dev_info.rss_algo_capa with rte_eth_dev_rss_algo_name. The RETA update/query calls run on net_null; per-queue counts there are labelled poll-driven.  
  Run here: `./rss_lab -l 0 --no-pci --no-huge -m 128 --file-prefix=ch15-rss --vdev=net_null0`
- **rss_fanout.sh** — Real multi-queue steering: creates veth ch15va/ch15vb, runs testpmd --vdev=net_af_packet0,iface=ch15va,qpairs=2,fanout_mode=hash -- --rxq=2 --txq=2 --forward-mode=rxonly --total-num-mbufs=8192 --stats-period 1, sends 40 UDP flows x 10 packets from a Python raw socket on ch15vb, and prints the per-queue split from xstats (verified 240/160); then repeats with one flow to show all packets on one queue.  
  Run here: `./rss_fanout.sh (prefix ch15-fan, timeout -s INT -k 5 15; trap deletes the veth pair)`
- **rtc_multiqueue.c** — Run-to-completion forwarder, one RX/TX queue per lcore, on net_af_packet qpairs=2,fanout_mode=hash over a veth fed by the Python flow sender, so each lcore sees whole flows; prints per-lcore rx/tx and flows seen. A --null mode runs on net_null,size=64 for a load number (labelled poll-driven).  
  Run here: `./rtc_multiqueue -l 0-2 --no-pci --no-huge -m 256 --file-prefix=ch15-rtc --vdev=net_af_packet0,iface=ch15va,qpairs=2,fanout_mode=hash,ignore_outgoing=1 (veth from rss_fanout.sh setup) ; --null mode with --vdev=net_null0,size=64`
- **pipeline_rings.c** — RX lcore -> ring -> 2 worker lcores (synthetic per-packet work, configurable cycles) -> ring -> TX lcore on net_ring/pcap ports; per-stage cycle accounting shows the bottleneck; a 'slow worker' option shows back-pressure and drops. Option --compress runs the worker hop over a 4-byte element ring carrying rte_ptr_compress_32_shift values (after checking the pool fits the window) and reports stage throughput vs 8-byte pointers (median of 5, min/max).  
  Run here: `./pipeline_rings -l 0-3 --no-pci --no-huge -m 256 --file-prefix=ch15-pipe --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=out.pcap,infinite_rx=1 -- --work 200`
- **distributor_reorder.c** — Distributor on lcore 0 handing tagged packets to 2 workers (flow affinity verified), returned packets passed through rte_reorder using the seqn dynfield; shows drained order and early/late handling.  
  Run here: `./distributor_reorder -l 0-2 --no-pci --no-huge -m 128 --file-prefix=ch15-dist`
- **compare.sh** — Runs RTC, pipeline and distributor variants with the same synthetic work per packet, 5 repetitions each, and prints a median/min/max table used by the chart.  
  Run here: `./compare.sh (prefixes ch15-cmp-*; each run <= 8 s)`
- **dpdk-distributor / dpdk-packet_ordering (prebuilt)** — The shipped samples with verified memory sizes: distributor needs 5 lcores and a 64K-mbuf pool per port; packet_ordering needs -m 384.  
  Run here: `timeout -s INT -k 5 15 $DPDK_SRC/build/examples/dpdk-distributor --lcores='(0-4)@(0-3)' --no-pci --no-huge -m 640 --file-prefix=ch15-dist --vdev=net_null0 --vdev=net_null1 -- -p 0x3 (verified: workers report packets) ; timeout -s INT -k 5 15 $DPDK_SRC/build/examples/dpdk-packet_ordering -l 0-3 --no-pci --no-huge -m 384 --file-prefix=ch15-po --vdev=net_null0 --vdev=net_null1 -- -p 0x3 (verified at -m 384; -m 256 fails with 'Cannot allocate memory')`

**Visualizations**

- **Toeplitz bit-level** (animation) — 32-bit window sliding over the key; XOR into the result whenever an input bit is 1; final hash -> low bits -> RETA -> queue. Predict-then-step: the learner predicts the next hash bit before the window XOR is shown.
- **RSS pipeline** (interactive) — 5-tuple -> Toeplitz -> 32-bit hash -> low bits -> RETA (128 coloured cells) -> queue -> lcore; edit RETA cells to rebalance; toggle symmetric key and watch forward/reverse flows land together; histogram of 10k flows.
- **Three execution models** (interactive) — RTC with RSS vs pipeline with rings vs (preview) eventdev, side by side with lcore layouts; the learner sets per-stage cost and number of lcores, and the widget shows the bottleneck stage and throughput predicted vs measured by compare.sh.
- **Pipeline bottleneck** (interactive) — Stages as boxes with ring fill bars between them; sliders set each stage's cycles/packet; the slowest stage's input ring fills and back-pressure propagates upstream; per-stage counters update.
- **Distributor flow affinity** (animation) — Distributor core hands tagged packets to workers; packets of an in-flight tag wait for the same worker; returned packets flow back; learner adds a heavy flow and sees imbalance.
- **Reorder window** (interactive) — Sequence-number line with order and ready buffers; insert packets (scripted 1,0,3,2,5,4,20,6 or by click) coloured valid/early/late; drain empties up to the first gap.
- **Measured model comparison** (chart) — Mpps per model from compare.sh with min/max whiskers.

**Exercises**

1. [easy] Rewrite the RETA on net_null so queue 1 gets 3/4 of the entries and confirm with rte_eth_dev_rss_reta_query; explain why the per-queue counters do not change.
2. [medium] Use rte_thash_adjust_tuple to pick 4 source ports that land on 4 different queues.
3. [easy] Change rtc_multiqueue to 2 vs 3 queues (qpairs) and explain the per-lcore result.
4. [medium] Add a third pipeline stage and find the new bottleneck using the per-stage counters.
5. [medium] Make pipeline_rings keep per-flow order by hashing flows to workers instead of round-robin.
6. [stretch] Compare distributor vs RTC throughput for skewed traffic (one heavy flow) and explain.

**Sources**

- doc/guides/prog_guide/ethdev/ethdev.rst (RSS, multi-queue)
- /home/user/ai_lab/dpdk_research/research/05-examples/rss.c
- usertools/dpdk-rss-flows.py
- lib/hash/rte_thash.h
- doc/guides/prog_guide/packet_distrib_lib.rst
- doc/guides/prog_guide/reorder_lib.rst
- doc/guides/prog_guide/ring_lib.rst
- doc/guides/sample_app_ug/dist_app.rst
- doc/guides/sample_app_ug/packet_ordering.rst
- lib/distributor/rte_distributor.h
- lib/reorder/rte_reorder.h
- lib/ring/rte_soring.h
- examples/distributor/main.c
- examples/packet_ordering/main.c
- examples/l3fwd/main.c (queue-per-lcore config)
- /home/user/ai_lab/dpdk_research/research/04-mbuf-mempool-ring.md (reorder)
- /home/user/ai_lab/dpdk_research/research/08-crypto-event-accel.md
- lib/ptr_compress/rte_ptr_compress.h
- doc/guides/prog_guide/ptr_compress_lib.rst
- drivers/net/af_packet/rte_eth_af_packet.c (fanout_mode)
- drivers/net/tap/meson.build (enable_tap_rss)

## 16. Multi-Process DPDK and Packet Capture: Primary/Secondary, IPC, dumpcap, pcapng and proc-info

*Folder:* `chapters/16-multi-process-capture/` · *Level:* advanced · *Prerequisites:* ch4, ch5, ch6, ch7, ch12, ch13, ch14

Several processes sharing one DPDK memory: primary and secondary processes, shared memory at identical addresses, what can and cannot be shared, rte_mp IPC, multi-process hotplug, what happens when the primary dies, and the multi-process startup errors. Then the tools built on it: pdump/pcapng/dpdk-dumpcap capture (with the full two-process command line), what capture costs in the fast path and when it is safe in production, and dpdk-proc-info as a secondary.

**Concepts**

- Primary vs secondary; --proc-type=primary|secondary|auto; shared config file with fcntl lock; runtime dir /run/dpdk/<prefix>
- Identical virtual addresses in every process; --base-virtaddr; ASLR collisions
- Shareable objects (memzones, rings, mempools, hash tables via lookup by name) vs non-shareable (function pointers, per-process fp_ops, lcore vars)
- ethdev in multi-process: rte_eth_dev_data shared, only the primary configures; secondaries use queues
- Requirements: same binary/DPDK version, same --file-prefix, hugepages (no --no-huge/--in-memory primary), non-overlapping -l
- IPC: rte_mp_action_register, rte_mp_sendmsg, rte_mp_request_sync/async, rte_mp_reply, free(reply.msgs), never malloc in IPC callbacks
- Deployment models: symmetric (simple_mp, symmetric_mp), client-server (mp_server/mp_client)
- Multi-process hotplug synchronisation (hotplug_mp)
- Packet capture: rte_pdump_init in the primary, MP enable message, RX/TX callbacks copying with rte_pcapng_copy into a ring, secondary writes pcapng; BPF filters; snaplen
- pcapng file structure: SHB, IDB, EPB, ISB
- dpdk-dumpcap and dpdk-pdump usage; dpdk-proc-info as a secondary (later in this chapter)
- dpdk-proc-info: stats, xstats, mempool and memory dumps from a secondary process
- Primary death: secondaries cannot outlive or re-attach to a new primary; detect it with rte_eal_primary_proc_alive
- Multi-process startup errors (rows added to the ch13 table): a secondary with no primary, a secondary of a --no-huge/--in-memory primary ('EAL init failed: is primary process running?' from dumpcap), mismatched binaries or DPDK versions, overlapping -l
- Hugepage hygiene for primaries: a SIGINT-stopped -m 64 primary can leave /dev/hugepages/<prefix>map_* files (32 were verified); the run.sh trap must remove them, because the shared 1024-page pool leaks fast across processes
- What capture costs: pdump installs RX/TX callbacks in the primary's fast path and copies matching packets into a ring; a broad filter or full snaplen at high rate cuts forwarding throughput, and a full capture ring drops silently. Read dumpcap's dropped-packet statistics and the pdump stats; 'safe capture in production' checklist (narrow BPF, snaplen 64-128, -c/duration limits, watch drops)

**APIs**

`rte_eal_process_type`, `rte_memzone_reserve`, `rte_memzone_lookup`, `rte_ring_lookup`, `rte_mempool_lookup`, `rte_mp_action_register`, `rte_mp_action_unregister`, `rte_mp_sendmsg`, `rte_mp_request_sync`, `rte_mp_request_async`, `rte_mp_reply`, `struct rte_mp_msg`, `rte_eal_primary_proc_alive`, `rte_pdump_init`, `rte_pdump_uninit`, `rte_pdump_enable`, `rte_pdump_enable_bpf`, `rte_pdump_disable`, `rte_pcapng_fdopen`, `rte_pcapng_add_interface`, `rte_pcapng_copy`, `rte_pcapng_write_packets`, `rte_pcapng_close`

**Runnable code examples**

- **mp_ipc.c** — Primary reserves memzone 'ch16_shared' and registers action 'ch16_ping'; secondary looks it up (same VA printed), overwrites it, sends rte_mp_request_sync and prints the reply. Based on research/02-eal-examples/mp_ipc.c.  
  Run here: `./mp_ipc -l 0 -m 64 --no-pci --file-prefix=ch16-ipc --proc-type=primary & ; ./mp_ipc -l 1 --no-pci --file-prefix=ch16-ipc --proc-type=secondary`
- **mp_pipeline.c** — Primary creates a ring and a pktmbuf pool and produces packets; secondary finds both by name and consumes them, freeing mbufs back into the shared pool; both print counts. Fault mode: run.sh SIGKILLs the primary; the secondary polls rte_eal_primary_proc_alive, reports it and exits cleanly.  
  Run here: `same binary, -m 64 hugepages, --file-prefix=ch16-pipe, primary -l 0 / secondary -l 1`
- **hotplug_mp (prebuilt)** — Attach and detach net_null5 from a secondary and see the primary and other secondaries follow.  
  Run here: `$DPDK_SRC/build/examples/dpdk-hotplug_mp -l 0 -m 32 --no-pci --file-prefix=ch16-hp ; secondary $DPDK_SRC/build/examples/dpdk-hotplug_mp -l 1 --proc-type=secondary --file-prefix=ch16-hp with commands attach net_null5 / list / detach net_null5`
- **dumpcap capture** — testpmd primary started with --stats-period 1 (a background testpmd without it exits on stdin EOF) (hugepages -m 64) replaying a pcap with infinite_rx and macswap; dpdk-dumpcap -D, then capture 20 packets with a BPF filter to a pcapng file; pcapng_dump.py prints the block structure.  
  Run here: `Primary: timeout -s INT -k 5 15 dpdk-testpmd -l 0-1 --no-pci -m 64 --file-prefix=ch16-dc --vdev=net_pcap0,rx_pcap=in.pcap,infinite_rx=1 -- --total-num-mbufs=8192 --stats-period 1 --forward-mode=macswap & ; sleep 3 ; dpdk-dumpcap --file-prefix=ch16-dc -D ; dpdk-dumpcap --file-prefix=ch16-dc -i 0 -c 20 -f 'udp src port 1003' -w cap.pcapng ; python3 -I pcapng_dump.py cap.pcapng ; trap removes /dev/hugepages/ch16-dcmap_* (verified needed). A --no-huge primary makes dumpcap fail with 'EAL init failed: is primary process running?' (captured)`
- **proc-info secondary** — testpmd primary (hugepages -m 64, --stats-period 1, prefix ch16-pi) and dpdk-proc-info --file-prefix=ch16-pi -- --stats --xstats --show-mempool as a secondary.  
  Run here: `testpmd primary -l 0-1 --no-pci -m 64 --file-prefix=ch16-pi --vdev=net_null0 --vdev=net_null1 -- --total-num-mbufs=8192 --stats-period 1 & ; sleep 3 ; dpdk-proc-info --file-prefix=ch16-pi -- --stats --xstats --show-mempool ; trap removes hugepage files`
- **capture_cost.sh** — Runs testpmd io on a pcap with infinite_rx (hugepage primary -m 64, --total-num-mbufs=8192, --stats-period 1) and measures Mpps with no capture, with dumpcap and a non-matching BPF filter, with a matching filter at snaplen 64, and with full snaplen (median of 5 each, min/max); reads dumpcap's dropped counts. Output is a table the chapter charts.  
  Run here: `./capture_cost.sh (prefixes ch16-cc-*, each run <= 8 s, trap removes hugepage files)`
- **mp_errors.sh** — Captures the multi-process startup errors: secondary without primary, dumpcap against a --no-huge primary, a secondary with an overlapping -l; rows are appended to the startup-error table.  
  Run here: `./mp_errors.sh (prefixes ch16-err-*, timeout 10 s each)`

**Visualizations**

- **Two address spaces, one memory** (animation) — Two process boxes whose hugepage segments map to the same physical pages at identical VAs; the runtime-dir files; the config lock explaining auto-detection.
- **IPC sequence diagram** (animation) — Secondary request -> unix socket -> primary action -> reply; timeout path when the primary never replies.
- **pdump architecture** (animation) — dumpcap sends 'enable' over MP; RX/TX callbacks in the primary copy matching packets into a shared ring; dumpcap writes pcapng blocks that build up on screen (SHB, IDB, EPB...).
- **What can be shared** (diagram) — Table-like diagram: green (memzone, ring, mempool, hash with *_with_hash APIs) vs red (function pointers, fp_ops, lcore vars, malloc'd heap pointers outside DPDK memory).
- **Capture cost explorer** (interactive) — The learner picks filter selectivity and snaplen; the widget shows the measured Mpps and dropped-packet counts from capture_cost.sh and animates where the copy happens in the primary's RX path.

**Exercises**

1. [easy] Make mp_pipeline's secondary restart while the primary keeps running and verify no mbufs leak.
2. [medium] Add an async IPC request with a callback and a timeout to mp_ipc.
3. [medium] Capture only TX packets of port 0 with dumpcap and count them with pcapng_dump.py.
4. [stretch] Find the snaplen/filter combination at which capture starts to drop on this VM and explain why.

**Sources**

- doc/guides/prog_guide/multi_proc_support.rst
- doc/guides/sample_app_ug/multi_process.rst
- doc/guides/prog_guide/device_hotplug.rst
- doc/guides/prog_guide/pdump_lib.rst
- doc/guides/prog_guide/pcapng_lib.rst
- doc/guides/tools/dumpcap.rst
- doc/guides/howto/packet_capture_framework.rst
- lib/eal/common/eal_common_proc.c
- lib/eal/include/rte_eal.h
- lib/pdump/rte_pdump.h
- lib/pcapng/rte_pcapng.h
- app/dumpcap/main.c
- examples/multi_process/
- /home/user/ai_lab/dpdk_research/research/02-eal.md
- /home/user/ai_lab/dpdk_research/research/03-memory-examples/mzshare.c
- /home/user/ai_lab/dpdk_research/research/06-examples/pcapng_dump.py
- doc/guides/tools/proc_info.rst
- app/proc-info/main.c

## 17. Exact-Match Lookup: rte_hash, Toeplitz, EFD and Member

*Folder:* `chapters/17-hash-exact-match/` · *Level:* advanced · *Prerequisites:* ch7, ch10, ch14

Flow tables, ARP caches, NAT tables and connection trackers all need fast exact-match lookup. This chapter covers rte_hash (cuckoo hashing with signatures, bulk lookups, extendable buckets, concurrency modes and RCU-safe deletes), the four-byte-key fbk hash, EFD and the member library. The NIC's Toeplitz/RSS hash is a different job, covered in ch15.

**Concepts**

- Exact match vs LPM vs ACL; designing a 5-tuple flow key (packing, padding, byte order)
- rte_hash_create parameters: entries, key_len, hash_func (rte_hash_crc, rte_jhash), init value, socket, extra_flag
- add/lookup/delete returning positions; *_data variants; *_with_hash variants; rte_hash_iterate
- Bulk lookups: rte_hash_lookup_bulk, rte_hash_lookup_bulk_data with hit mask; why they are faster
- Cuckoo internals: 8-entry buckets, 16-bit signatures, primary/secondary bucket, displacement (BFS), load factor, EXT_TABLE buckets
- Concurrency flags: MULTI_WRITER_ADD, RW_CONCURRENCY, RW_CONCURRENCY_LF, TRANS_MEM_SUPPORT; NO_FREE_ON_DEL
- RCU integration: rte_hash_rcu_qsbr_add with defer queue; deferred data free on update (26.03+)
- rte_fbk_hash for 4-byte keys
- EFD: perfect-hash-like 'which target' mapping without storing keys; unknown keys map to arbitrary values
- Member library: hash-table, vBF and count-min sketch set summaries; false-positive behaviour
- Multi-process caveat: hash function pointers differ per process; use *_with_hash in secondaries (ch16)
- Not this chapter: the NIC computes a Toeplitz hash to pick a queue (rte_thash, ch15); a flow table may reuse mbuf->hash.rss as its hash to save cycles

**APIs**

`rte_hash_create`, `rte_hash_free`, `rte_hash_add_key`, `rte_hash_add_key_data`, `rte_hash_lookup`, `rte_hash_lookup_data`, `rte_hash_del_key`, `rte_hash_lookup_bulk`, `rte_hash_lookup_bulk_data`, `rte_hash_hash`, `rte_hash_lookup_with_hash`, `rte_hash_iterate`, `rte_hash_count`, `rte_hash_rcu_qsbr_add`, `rte_hash_crc`, `rte_jhash`, `RTE_HASH_EXTRA_FLAGS_EXT_TABLE`, `RTE_HASH_EXTRA_FLAGS_RW_CONCURRENCY_LF`, `rte_fbk_hash_create`, `rte_fbk_hash_add_key`, `rte_fbk_hash_lookup`, `rte_efd_create`, `rte_efd_update`, `rte_efd_lookup`, `rte_member_create`, `rte_member_add`, `rte_member_lookup`

**Runnable code examples**

- **hash_fill.c** — Fill a 1M-entry table until failure to measure the achievable load factor with and without EXT_TABLE; single vs bulk lookup cycles; crc vs jhash. Based on research/07-examples/hash_fill.c. Report measured load factors and cycles (median of 5).  
  Run here: `./hash_fill -l 0 --no-pci --no-huge -m 256 --file-prefix=ch17-fill`
- **flow_table.c** — Per-flow packet/byte counters keyed by 5-tuple for packets read from a pcap (net_pcap); prints the top flows using rte_hash_iterate.  
  Run here: `./flow_table -l 0 --no-pci --no-huge -m 128 --file-prefix=ch17-flow --vdev=net_pcap0,rx_pcap=flows.pcap,tx_pcap=/dev/null`
- **hash_rcu.c** — Lock-free hash with one writer adding/deleting keys and two reader lcores looking up, with rte_hash_rcu_qsbr_add reclaiming entries safely; prints reclaim counts and zero errors.  
  Run here: `./hash_rcu -l 0-2 --no-pci --no-huge -m 128 --file-prefix=ch17-rcu`
- **efd_member.c** — Insert 100k keys into EFD and member (vBF) and measure memory use and false-positive rate for 100k unknown keys, compared with rte_hash memory.  
  Run here: `./efd_member -l 0 --no-pci --no-huge -m 256 --file-prefix=ch17-efd`

**Visualizations**

- **Cuckoo displacement** (animation) — Buckets of 8 slots with signatures; inserting into a full primary bucket triggers a BFS displacement path that moves entries to their alternative buckets.
- **Load factor slider** (interactive) — Slider fills a table; shows primary/secondary split and where inserts start failing, with/without extendable buckets.
- **Bloom filter grid** (interactive) — Bit array with k hash arrows per key; querying a non-member that happens to hit all set bits shows a false positive.
- **Lookup structure chooser** (diagram) — Decision diagram: exact key? stored keys needed? false positives OK? -> rte_hash / fbk / EFD / member / LPM / ACL.

**Exercises**

1. [easy] Add flow aging to flow_table using a timestamp in the data and rte_hash_iterate.
2. [medium] Find a key set that forces a displacement chain and print its length.
3. [stretch] Measure how bulk lookup speed changes with batch sizes 1, 4, 8, 16, 32.
4. [stretch] Explain why an rte_hash created in the primary must be used with rte_hash_lookup_with_hash in a secondary (ch16), and demonstrate it.

**Sources**

- doc/guides/prog_guide/hash_lib.rst
- doc/guides/prog_guide/toeplitz_hash_lib.rst
- doc/guides/prog_guide/efd_lib.rst
- doc/guides/prog_guide/member_lib.rst
- lib/hash/rte_hash.h
- lib/hash/rte_cuckoo_hash.c
- lib/hash/rte_fbk_hash.h
- lib/hash/rte_hash_crc.h
- lib/hash/rte_jhash.h
- lib/efd/rte_efd.h
- lib/member/rte_member.h
- examples/l3fwd/l3fwd_em.c
- /home/user/ai_lab/dpdk_research/research/07-packet-processing-libs.md
- /home/user/ai_lab/dpdk_research/research/07-examples/hash_fill.c
- /home/user/ai_lab/dpdk_research/research/05-examples/rss.c
- usertools/dpdk-rss-flows.py

## 18. Routing and Classification: LPM, RIB, FIB, ACL and l3fwd

*Folder:* `chapters/18-lpm-fib-acl/` · *Level:* advanced · *Prerequisites:* ch14, ch15, ch17

IP forwarding needs longest-prefix match and firewalls need multi-field classification. This chapter explains the DIR-24-8 algorithm behind rte_lpm, LPM6 with the 26.11 address type, the RIB (control-plane tree) and FIB (pluggable data-plane) split, RCU-safe route updates, the ACL library (field definitions, rule categories, build/classify and SIMD algorithms), and puts it all together with the l3fwd sample in its lpm, fib, em and acl modes.

**Concepts**

- Longest prefix match: why exact match is not enough for routing
- DIR-24-8: tbl24 (16M entries) + tbl8 groups, prefix expansion, deletion re-expanding the covering prefix, memory cost (64 MiB)
- rte_lpm_create config (max_rules, number_tbl8s, flags), add/delete/lookup, lookup_bulk, lookupx4; next-hop encoding
- LPM6 with struct rte_ipv6_addr (26.11), memory sizing
- RIB: binary tree of prefixes, lookup, get_nxt walks, parent, per-node user extension; control-plane uses
- FIB: rte_fib_create types DIR24_8 (nh_sz 1/2/4/8 bytes) and DUMMY, FIB6 TRIE; default next hop; RTE_FIB_F_LOOKUP_NETWORK_ORDER; rte_fib_get_rib
- RCU for lookup tables: rte_lpm_rcu_qsbr_add, rte_fib_rcu_qsbr_add
- ACL: field definitions (type, size, offset, input index), rule format with priority and category mask, contexts, build then classify, categories, immutable after build; [Deep dive, optional] the multi-bit trie and the scalar/SSE/AVX2/AVX512x16/x32 classify algorithms
- Byte order rules: LPM/FIB host order vs packets network order; ACL rules host order, input network order
- l3fwd: --lookup=lpm|fib|em|acl; every flag explained: --config '(port,queue,lcore)' tuples, -p port mask, why --parse-ptype (vdevs give no packet types) and --disable-rss / --relax-rx-offload (pcap vdevs have no RSS or RX offloads; multi-queue RSS is ch15), route and rule files; vector paths (lookupx4, hash multi-lookup); eventdev mode pointer
- Fate of packets to disabled ports in l3fwd
- Tools for this chapter: dpdk-test-fib and dpdk-test-acl are not prebuilt here (the build enabled only a few apps), so the chapter Makefile builds them from app/test-fib/main.c and app/test-acl/main.c

**APIs**

`rte_lpm_create`, `rte_lpm_add`, `rte_lpm_delete`, `rte_lpm_lookup`, `rte_lpm_lookup_bulk`, `rte_lpm_lookupx4`, `rte_lpm_rcu_qsbr_add`, `rte_lpm_free`, `rte_lpm6_create`, `rte_lpm6_add`, `rte_lpm6_lookup`, `rte_rib_create`, `rte_rib_insert`, `rte_rib_lookup`, `rte_rib_get_nxt`, `rte_rib_get_ext`, `rte_fib_create`, `rte_fib_add`, `rte_fib_delete`, `rte_fib_lookup_bulk`, `rte_fib_get_rib`, `rte_fib_rcu_qsbr_add`, `rte_fib6_create`, `rte_acl_create`, `rte_acl_add_rules`, `rte_acl_build`, `rte_acl_classify`, `rte_acl_classify_alg`, `rte_acl_set_ctx_classify`, `rte_acl_free`, `RTE_ACL_RULE_DEF`, `struct rte_acl_field_def`

**Runnable code examples**

- **lpm_fib.c** — Install the same 1000 routes in LPM, FIB (DIR24_8, 4-byte next hops) and RIB; verify identical lookups; show a /28 forcing a tbl8 group; miss vs default next hop; cycles for single vs bulk lookups. Based on research/07-examples/lpm_fib.c.  
  Run here: `./lpm_fib -l 0 --no-pci --no-huge -m 256 --file-prefix=ch18-lpm`
- **dir24_visual.c** — Tiny route set (10.0.0.0/8, 10.1.0.0/16, 10.1.1.0/24, 10.1.1.128/25) and dumps which tbl24/tbl8 entries each lookup touches; output feeds the animation.  
  Run here: `./dir24_visual -l 0 --no-pci --no-huge -m 256 --file-prefix=ch18-dir`
- **acl_5tuple.c** — Standalone ACL context with 5-tuple field defs, rules in 2 categories (allow/deny and a QoS class), classify 64k packets with every available algorithm and time them; -ERANGE with a small max_size.  
  Run here: `./acl_5tuple -l 0 --no-pci --no-huge -m 256 --file-prefix=ch18-acl`
- **l3fwd (prebuilt)** — dpdk-l3fwd on two pcap ports with --lookup=lpm, fib and acl (rule files from research/07-examples); pcap_summary.py shows TTL 64->63 and per-port destinations.  
  Run here: `$DPDK_SRC/build/examples/dpdk-l3fwd -l 1 --no-pci --no-huge -m 256 --file-prefix=ch18-l3 --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=out0.pcap --vdev=net_pcap1,rx_pcap=in.pcap,tx_pcap=out1.pcap -- -p 0x3 --config='(0,0,1),(1,0,1)' --lookup=lpm --parse-ptype --disable-rss --relax-rx-offload`
- **route_update_rcu.c** — One lcore updates routes while another looks up continuously, using rte_lpm_rcu_qsbr_add; counts lookups during churn and confirms no stale tbl8 reuse.  
  Run here: `./route_update_rcu -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch18-rcu`
- **test-fib / test-acl (built from app/ sources by the Makefile)** — Benchmark tools built standalone (verified): test-fib with gcc -O2 -DALLOW_EXPERIMENTAL_API -I$DPDK_SRC/lib/eal/linux/include $DPDK_SRC/app/test-fib/main.c (the extra -I is for rte_os_shim.h) and the pkg-config static flags; test-acl the same way without the extra -I. Prints AVG FIB lookup lines and ACL cycles/pkt.  
  Run here: `./dpdk-test-fib -l 0 --no-pci --no-huge -m 256 --file-prefix=ch18-tf -- -n 10000 -l 100000 ; ./dpdk-test-acl -l 0 --no-pci --no-huge -m 256 --file-prefix=ch18-ta -- --rulesf=$DPDK_SRC/app/test-acl/input/acl1v4_5_rule --tracef=$DPDK_SRC/app/test-acl/input/acl1v4_5_trace`

**Visualizations**

- **DIR-24-8 painter** (interactive) — 32-bit address split 24|8; adding a prefix paints tbl24 cells, longer prefixes allocate a tbl8 group; lookup walks are highlighted; delete re-expands the covering prefix.
- **RIB tree <-> FIB arrays** (animation) — Inserting prefixes into the RIB tree and seeing the FIB data plane update in sync.
- **ACL trie walk** (animation) — Byte-by-byte transitions through the multi-bit trie for several packets in parallel SIMD lanes; categories as a colour matrix of results.
- **l3fwd packet fate** (diagram) — Per-destination fate of the 1000 test packets in lpm/fib/em/acl modes from the real pcap_summary output.
- **Memory footprint bars** (chart) — Memory of LPM, FIB (by nh_sz), LPM6 and ACL contexts for the example route/rule sets.

**Exercises**

1. [easy] Add 100k random routes to LPM and FIB and compare memory and lookup speed.
2. [medium] Write an ACL rule set that implements 'drop UDP to port 53 except from 10.0.0.0/8' and test it.
3. [medium] Make l3fwd's em mode hit by generating a pcap whose 5-tuples match em_default_v4.cfg.
4. [stretch] Use RIB get_nxt to print all more-specific routes under 10.0.0.0/8.

**Sources**

- doc/guides/prog_guide/lpm_lib.rst
- doc/guides/prog_guide/lpm6_lib.rst
- doc/guides/prog_guide/rib_lib.rst
- doc/guides/prog_guide/fib_lib.rst
- doc/guides/prog_guide/packet_classif_access_ctrl.rst
- doc/guides/sample_app_ug/l3_forward.rst
- lib/lpm/rte_lpm.h
- lib/lpm/rte_lpm6.h
- lib/rib/rte_rib.h
- lib/fib/rte_fib.h
- lib/fib/rte_fib6.h
- lib/acl/rte_acl.h
- examples/l3fwd/
- /home/user/ai_lab/dpdk_research/research/07-packet-processing-libs.md
- /home/user/ai_lab/dpdk_research/research/07-examples/lpm_fib.c
- /home/user/ai_lab/dpdk_research/research/07-examples/acl_rules_v4.txt
- app/test-fib/main.c
- app/test-acl/main.c

## 19. Offloads, Timestamps and Packet Transforms: Checksums, TSO, PTP, GSO, GRO and IP Fragmentation

*Folder:* `chapters/19-offloads-gso-gro-frag/` · *Level:* advanced · *Prerequisites:* ch10, ch12

NICs can compute checksums, segment large TCP packets and strip VLAN tags; when they cannot, DPDK libraries do it in software. This chapter covers the ethdev offload capability model, RX checksum status flags, TX checksum/TSO requests with mbuf length fields and rte_eth_tx_prepare, VLAN, scatter and multi-segment, then software GSO, GRO and IPv4/IPv6 fragmentation and reassembly built on indirect mbufs. Adds hardware timestamps and IEEE 1588/PTP: where each timestamp is taken, the timesync API, and the ptpclient and ptp_tap_relay_sw samples.

**Concepts**

- Capability model: rx/tx_offload_capa, per-port vs per-queue offloads, enabling in rte_eth_conf.rxmode/txmode and queue confs; configure fails if not supported
- RX checksum flags: RTE_MBUF_F_RX_IP_CKSUM_GOOD/BAD/UNKNOWN/NONE, L4 flags, outer flags
- TX checksum offload: ol_flags RTE_MBUF_F_TX_IPV4 | IP_CKSUM | UDP_CKSUM/TCP_CKSUM, l2_len/l3_len/l4_len, pseudo-header checksum, rte_eth_tx_prepare, rte_validate_tx_offload, rte_net_intel_cksum_prepare
- TSO: RTE_MBUF_F_TX_TCP_SEG, tso_segsz; tunnel offloads (VXLAN outer_l2/l3 lengths) recipes
- VLAN strip/insert (RTE_ETH_RX_OFFLOAD_VLAN_STRIP, RTE_MBUF_F_TX_VLAN), QinQ
- SCATTER, MULTI_SEGS, MBUF_FAST_FREE, RSS_HASH, TIMESTAMP, LRO, selective Rx; buffer split at struct level: RTE_ETH_RX_OFFLOAD_BUFFER_SPLIT with struct rte_eth_rxseg_split segments (header pool vs payload pool, proto_hdr), rte_eth_buffer_split_get_supported_hdr_ptypes, and multi-mempool Rx (rxconf.rx_mempools, dev_info.max_rx_mempools); ENOTSUP on vdevs (captured in ch9's recipes)
- Software GSO: rte_gso_ctx (direct/indirect pools, segment size, gso_types), rte_gso_segment, ownership
- Software GRO: lightweight rte_gro_reassemble_burst and heavyweight context with timeouts; packet_type must be set
- IP fragmentation: rte_ipv4_fragment_packet / rte_ipv6_fragment_packet using direct header mbufs + indirect payload mbufs; IPv4 checksum left 0
- Reassembly: rte_ip_frag_table_create, rte_ipv4_frag_reassemble_packet, timeouts, death row and rte_ip_frag_free_death_row
- Hardware vs software reassembly: RTE_ETH_RX_OFFLOAD_IP_REASSEMBLY with rte_eth_ip_reassembly_capability_get/conf_get/conf_set and the dynfield/flag for incomplete reassembly (rte_eth_ip_reassembly_dynfield_register) vs software rte_ip_frag; ENOTSUP on every vdev here (captured)
- Which of these net_tap supports here vs real NICs
- Timestamps: RTE_ETH_RX_OFFLOAD_TIMESTAMP with rte_mbuf_dyn_rx_timestamp_register, rte_eth_read_clock
- IEEE 1588/PTP: Sync/Follow_Up/Delay_Req/Delay_Resp exchange and the offset/delay formulas; rte_eth_timesync_enable/read_rx_timestamp/read_tx_timestamp/adjust_time/adjust_freq/read_time; testpmd ieee1588 forward mode; examples/ptpclient (reading) and examples/ptp_tap_relay_sw (software timestamps over TAP). ptp4l is not installed here; the ptp_tap_relay_sw sample runs on af_packet + tap with hand-built PTPv2 frames
- Tunnel offload recipes build on ch10's VXLAN frame (outer_l2_len/outer_l3_len, RTE_MBUF_F_TX_TUNNEL_VXLAN); VXLAN on a non-4789 port needs rte_eth_dev_udp_tunnel_port_add (struct rte_eth_udp_tunnel) before the NIC parses it

**APIs**

`rte_eth_dev_info_get (rx_offload_capa, tx_offload_capa)`, `rte_eth_rx_offload_name`, `rte_eth_tx_offload_name`, `rte_eth_tx_prepare`, `rte_validate_tx_offload`, `rte_ipv4_phdr_cksum`, `rte_net_intel_cksum_prepare`, `RTE_ETH_TX_OFFLOAD_IPV4_CKSUM`, `RTE_ETH_TX_OFFLOAD_UDP_CKSUM`, `RTE_ETH_TX_OFFLOAD_TCP_TSO`, `RTE_ETH_RX_OFFLOAD_CHECKSUM`, `RTE_MBUF_F_TX_IP_CKSUM`, `RTE_MBUF_F_TX_UDP_CKSUM`, `RTE_MBUF_F_TX_TCP_SEG`, `RTE_MBUF_F_RX_IP_CKSUM_GOOD`, `rte_gso_segment`, `struct rte_gso_ctx`, `rte_gro_reassemble_burst`, `rte_gro_ctx_create`, `rte_gro_reassemble`, `rte_gro_timeout_flush`, `rte_ipv4_fragment_packet`, `rte_ipv6_fragment_packet`, `rte_ip_frag_table_create`, `rte_ipv4_frag_reassemble_packet`, `rte_ip_frag_free_death_row`, `rte_ip_frag_table_destroy`, `rte_eth_timesync_enable`, `rte_eth_timesync_read_rx_timestamp`, `rte_eth_timesync_read_tx_timestamp`, `rte_eth_timesync_adjust_time`, `rte_eth_timesync_adjust_freq`, `rte_eth_timesync_read_time`, `rte_eth_read_clock`, `RTE_ETH_RX_OFFLOAD_TIMESTAMP`, `rte_mbuf_dyn_rx_timestamp_register`, `rte_eth_ip_reassembly_capability_get`, `rte_eth_ip_reassembly_conf_set`, `rte_eth_dev_udp_tunnel_port_add`, `struct rte_eth_rxseg_split`, `rte_eth_buffer_split_get_supported_hdr_ptypes`

**Runnable code examples**

- **offload_caps.c** — Prints RX/TX offload capabilities by name for net_null, net_ring, net_tap, net_af_packet (veth) side by side; shows configure failing when requesting an unsupported offload. Also probes rte_eth_ip_reassembly_capability_get, rte_eth_buffer_split_get_supported_hdr_ptypes and rte_eth_dev_udp_tunnel_port_add on each port and prints the real return codes.  
  Run here: `./offload_caps -l 0 --no-pci --no-huge -m 128 --file-prefix=ch19-caps --vdev=net_null0 --vdev=net_ring0 --vdev=net_tap0,iface=ch19tap0`
- **txoff.c + cap.py** — Send UDP packets with zeroed checksums and TX checksum offload flags on net_tap; a Python AF_PACKET capture on the kernel side verifies the checksums are valid. Based on research/05-examples/txoff.c.  
  Run here: `./txoff -l 0 ... --file-prefix=ch19-tx --vdev=net_tap0,iface=ch19tap1 & python3 -I cap.py ch19tap1 5`
- **rx_cksum.c** — Receive kernel-generated UDP on net_tap with RX checksum offload enabled vs disabled; prints ol_flags decoded (GOOD vs UNKNOWN). Based on research/05-examples/taprx.c.  
  Run here: `./rx_cksum -l 0 ... --file-prefix=ch19-rx --vdev=net_tap0,iface=ch19tap2 (Python sender in run.sh)`
- **gso_gro.c** — An 8054-byte TCP packet segmented by rte_gso_segment into MSS-sized segments, then merged back by rte_gro_reassemble_burst; prints seq numbers, IP ids and lengths. Based on research/07-examples/gso_gro.c.  
  Run here: `./gso_gro -l 0 --no-pci --no-huge -m 128 --file-prefix=ch19-gso`
- **frag_reasm.c** — Fragment a 4000-byte IPv4 packet with MTU 1500 (zero-copy, refcnt shown), shuffle fragments, reassemble, then show timeout and death-row handling. Based on research/07-examples/frag_reasm.c.  
  Run here: `./frag_reasm -l 0 --no-pci --no-huge -m 128 --file-prefix=ch19-frag`
- **timesync_probe.c + ptp_tap_relay_sw** — Probes timesync and read_clock on net_null/net_tap and captures the real ENOTSUP results; then tries the prebuilt dpdk-ptp_tap_relay_sw on a tap/veth pair (author verifies args; if it cannot run, record why). The relay part runs dpdk-ptp_tap_relay_sw on net_af_packet over a veth plus a net_tap port (verified to reach 'Relay loop started on lcore 1'); a Python raw socket on the peer veth injects hand-built PTPv2 Sync and Delay_Req frames (ethertype 0x88F7) and the chapter shows the relay's stats and the correction field it rewrites. ptp4l is absent.  
  Run here: `./timesync_probe -l 0 --no-pci --no-huge -m 128 --file-prefix=ch19-ts --vdev=net_null0 --vdev=net_tap0,iface=ch19tap3 ; ip link add ch19va type veth peer name ch19vb ; timeout -s INT -k 5 12 $DPDK_SRC/build/examples/dpdk-ptp_tap_relay_sw -l 1-2 --no-pci --no-huge -m 256 --file-prefix=ch19-ptp --vdev=net_af_packet0,iface=ch19va --vdev=net_tap0,iface=ch19tap4 -- -p 0 -t 1 -T 2 & python3 -I ptp_inject.py ch19vb ; trap deletes the veth`

**Visualizations**

- **Who does what** (animation) — mbuf fields (ol_flags, l2/l3/l4_len, tso_segsz) -> tx_prepare -> PMD -> NIC; a 3000 B TCP packet splits into segments with header replication and checksum recalculation.
- **Per-port vs per-queue offloads** (diagram) — Venn of port capabilities, per-queue capabilities and pure per-port ones with the configuration rules.
- **Fragmentation with indirect mbufs** (animation) — Header copies in direct mbufs, payload slices as indirect mbufs pointing into the original buffer; refcnt badge increments; reassembly table filling out of order.
- **GRO accordion** (animation) — Segments with consecutive seq numbers merging into one packet in the GRO table; timeout flush of a stalled flow.
- **RX checksum flag decoder** (interactive) — Toggle bits to see GOOD/BAD/UNKNOWN/NONE combinations and what the app should do.
- **PTP exchange** (animation) — Master and slave timelines with Sync, Follow_Up, Delay_Req, Delay_Resp; t1..t4 timestamps marked where hardware takes them; learner drags the path asymmetry and sees the offset error.
- **Buffer split layout** (diagram) — struct-level figure: one received frame split into a header segment from a small pool and a payload segment from a large pool, linked as an mbuf chain, with the rte_eth_rxseg_split fields that define the cut.

**Exercises**

1. [easy] Add VLAN insertion via RTE_MBUF_F_TX_VLAN on net_tap and verify the tag in the kernel capture.
2. [medium] Fragment an IPv6 packet and reassemble it; compare with IPv4.
3. [medium] Make gso_gro handle UDP (UFO) and explain the difference.
4. [stretch] Write a check function that refuses to send a packet whose ol_flags request an offload the port did not enable.

**Sources**

- doc/guides/prog_guide/ethdev/ethdev.rst (Hardware Offload)
- doc/guides/prog_guide/mbuf_lib.rst (Meta Information)
- doc/guides/prog_guide/generic_segmentation_offload_lib.rst
- doc/guides/prog_guide/generic_receive_offload_lib.rst
- doc/guides/prog_guide/ip_fragment_reassembly_lib.rst
- doc/guides/nics/features.rst
- doc/guides/nics/features/tap.ini
- lib/ethdev/rte_ethdev.h (RTE_ETH_*_OFFLOAD_*)
- lib/mbuf/rte_mbuf_core.h (RTE_MBUF_F_*)
- lib/net/rte_net.h
- lib/gso/rte_gso.h
- lib/gro/rte_gro.h
- lib/ip_frag/rte_ip_frag.h
- drivers/net/tap/rte_eth_tap.c
- /home/user/ai_lab/dpdk_research/research/05-ethdev.md
- /home/user/ai_lab/dpdk_research/research/05-examples/txoff.c
- /home/user/ai_lab/dpdk_research/research/07-examples/frag_reasm.c
- doc/guides/sample_app_ug/ptp_client.rst
- doc/guides/sample_app_ug/ptp_tap_relay_sw.rst
- examples/ptpclient/ptpclient.c
- examples/ptp_tap_relay_sw/
- lib/mbuf/rte_mbuf_dyn.h (timestamp registration)
- lib/ethdev/rte_ethdev.h (ip_reassembly, rxseg_split, udp_tunnel)

## 20. rte_flow: Classifying and Steering Traffic in Hardware (and the E-Switch Model)

*Folder:* `chapters/20-rte-flow-steering/` · *Level:* advanced · *Prerequisites:* ch12, ch15, ch19

Multi-queue and RSS basics are in ch15; this chapter is about rules. The rte_flow model (attributes, pattern items, actions, validation and errors), groups, isolate mode and metadata, advanced and indirect actions, rte_flow_conv, the template/async API for high insertion rates, the legacy DCB/VMDq modes with the 26.11 validation rules, and switch representation (representor ports and transfer rules). Rules validate on tap but cannot be created there, so a software matcher applies the same rte_flow arrays to show their effect. rte_mtr/rte_tm are in ch21.

**Concepts**

- rte_flow model: attributes (ingress/egress/transfer, group, priority), pattern items (ETH, VLAN, IPV4, IPV6, UDP, TCP, VXLAN, END), spec/last/mask, actions (QUEUE, RSS, DROP, MARK, FLAG, COUNT, JUMP, PASSTHRU, END)
- RSS as an rte_flow action: struct rte_flow_action_rss with queues, types, key, func and level (inner vs outer for tunnels, the ch15 VXLAN picture), versus port-level RSS from ch15
- Validate vs create vs destroy vs flush vs query; struct rte_flow_error with type, cause and message
- Groups and JUMP; same-priority overlaps are undefined; rules may be dropped on restart
- Isolate mode; MARK/FLAG metadata and rte_eth_rx_metadata_negotiate before configure
- Template/async API: rte_flow_configure, pattern and actions templates, template tables, rte_flow_async_create, push, pull (stable in 26.11)
- Legacy multi-queue modes DCB and VMDq; 26.11 validation: DCB modes rejected without a get_dcb_info callback, VMDq modes rejected when no VMDq pools are reported
- Advanced actions table (pointer to flow_offload.rst): indirect/shared actions (rte_flow_action_handle_create/update/query, action lists), METER/METER_MARK (ties to rte_mtr in ch21), CONNTRACK, AGE + rte_flow_get_aged_flows, tunnel offload (rte_flow_tunnel_decap_set/match), flex items, VXLAN_ENCAP/RAW_ENCAP/decap, SAMPLE/mirroring, hairpin queues, rte_flow_dev_dump
- rte_flow_conv ops incl. RTE_FLOW_CONV_OP_ITEM_DEFAULT_MASK_PTR and RTE_FLOW_CONV_OP_ITEM_SIZE
- Moved from ch12: representor ports and the switch domain in one paragraph (full treatment in ch18)
- Switch representation: PF/VF/SF and representor ports, the switch domain (rte_eth_dev_info.switch_info), representor devargs (representor=[0-3]), rte_eth_representor_info_get, attr.transfer=1, rte_flow_pick_transfer_proxy, REPRESENTED_PORT vs PORT_REPRESENTOR items/actions; base of OVS-DPDK hardware offload; concept + capability probe only (no vdev supports transfer)
- What works on this VM: tap validates rules but flow create/isolate fail (kernel lacks multiq qdisc, flower, skbedit); tap has no RETA and does RSS only through the flow RSS action with the BPF build option enable_tap_rss (not built here) (RETA size 0); net_null with --rxq=4 implements RETA update/query and per-queue xstats
- Tools for this chapter: usertools/dpdk-rss-flows.py (craft flows that land on chosen queues), dpdk-test-flow-perf (rule insertion rate; run on tap or capture why it fails)

**APIs**

`rte_flow_validate`, `rte_flow_create`, `rte_flow_destroy`, `rte_flow_flush`, `rte_flow_query`, `rte_flow_isolate`, `struct rte_flow_attr`, `struct rte_flow_item`, `struct rte_flow_action`, `struct rte_flow_error`, `rte_flow_conv`, `rte_eth_rx_metadata_negotiate`, `rte_flow_configure`, `rte_flow_pattern_template_create`, `rte_flow_actions_template_create`, `rte_flow_template_table_create`, `rte_flow_async_create`, `rte_flow_push`, `rte_flow_pull`, `rte_flow_action_handle_create`, `rte_flow_action_handle_query`, `rte_flow_get_aged_flows`, `rte_flow_dev_dump`, `RTE_FLOW_CONV_OP_ITEM_DEFAULT_MASK_PTR`, `RTE_FLOW_CONV_OP_ITEM_SIZE`, `rte_eth_representor_info_get`, `rte_flow_pick_transfer_proxy`, `RTE_FLOW_ITEM_TYPE_REPRESENTED_PORT`, `RTE_FLOW_ACTION_TYPE_PORT_REPRESENTOR`, `rte_eth_dev_get_dcb_info`, `struct rte_flow_action_rss`

**Runnable code examples**

- **flow_steer_sw.c** — Calls rte_flow_create on net_tap with 'UDP dst 5001 -> queue 0, 5002 -> queue 1' and prints the real ENOTSUP rte_flow_error, then falls back to a software matcher that applies the same rte_flow_item/rte_flow_action arrays (spec/last/mask, priority, JUMP, DROP, MARK, COUNT) to packets read from net_pcap and steers them into per-'queue' rte_rings, printing per-queue counts and marks.  
  Run here: `./flow_steer_sw -l 0 --no-pci --no-huge -m 128 --file-prefix=ch20-flow --vdev=net_tap0,iface=ch20tap0 --vdev=net_pcap0,rx_pcap=flows.pcap,tx_pcap=/dev/null`
- **flow_validate.c** — Builds several good and bad rules in C and calls rte_flow_validate on tap, printing error.type, message and the index of the offending item computed from error.cause; uses rte_flow_conv with RTE_FLOW_CONV_OP_ITEM_DEFAULT_MASK_PTR and RTE_FLOW_CONV_OP_ITEM_SIZE to show default masks and item sizes.  
  Run here: `./flow_validate -l 0 --no-pci --no-huge -m 128 --file-prefix=ch20-val --vdev=net_tap0,iface=ch20tap1`
- **testpmd flow commands** — testpmd on net_tap --rxq=2: flow validate lines succeed; create/isolate lines are kept as captured failures with their real error text; then testpmd on net_null --rxq=4 for 'show port 0 rss reta 128 (...)' and 'port config 0 rss reta' commands.  
  Run here: `dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch20-tp --vdev=net_tap0,iface=ch20tap2 -- -i --rxq=2 --txq=2 --total-num-mbufs=8192 < flow_cmds.txt`
- **switch_probe.c** — Calls rte_eth_representor_info_get, rte_flow_pick_transfer_proxy and validates a transfer rule on net_null/net_tap; prints switch_info from dev_info and the real -ENOTSUP/-ENOSYS results, showing how portable code checks for e-switch support.  
  Run here: `./switch_probe -l 0 --no-pci --no-huge -m 128 --file-prefix=ch20-sw --vdev=net_null0 --vdev=net_tap0,iface=ch20tap3`

**Visualizations**

- **rte_flow rule builder** (interactive) — Stack pattern items, edit spec/mask, add actions; a stream of synthetic packets runs through groups 0 -> JUMP -> 1 with priorities; isolate mode toggle; validate errors point at the offending item.
- **Sync vs async insertion** (animation) — Timeline comparing blocking create per rule vs enqueue-many, push once, pull completions later.
- **Indirect COUNT shared by N rules** (animation) — One indirect action handle referenced by several rules; packets hitting any of them increment the single counter; updating the handle changes all rules at once.
- **E-switch model** (diagram) — PF and VFs on a NIC e-switch, representor ports in the DPDK app, transfer rules forwarding between REPRESENTED_PORT and PORT_REPRESENTOR; maps to OVS-DPDK offload.

**Exercises**

1. [easy] Use flow_validate to list which pattern items tap accepts and print the default mask of each with RTE_FLOW_CONV_OP_ITEM_DEFAULT_MASK_PTR.
2. [medium] Write a rule that MARKs packets to UDP port 4789, show the real error tap returns for flow create, and implement the MARK action in flow_steer_sw so the mark appears in the mbuf.
3. [medium] Show why two rules with the same priority overlapping is undefined, using flow validate on testpmd.
4. [stretch] Sketch (in code comments) the template API calls needed to insert 1M rules on a real NIC.

**Sources**

- doc/guides/prog_guide/ethdev/ethdev.rst (RSS, multi-queue)
- doc/guides/prog_guide/ethdev/flow_offload.rst
- doc/guides/prog_guide/toeplitz_hash_lib.rst
- doc/guides/nics/tap.rst
- doc/guides/testpmd_app_ug/testpmd_funcs.rst (flow syntax)
- lib/ethdev/rte_flow.h
- lib/hash/rte_thash.h
- drivers/net/tap/tap_flow.c
- examples/flow_filtering/
- /home/user/ai_lab/dpdk_research/research/05-ethdev.md
- /home/user/ai_lab/dpdk_research/research/05-examples/rss.c
- /home/user/ai_lab/dpdk_research/research/05-examples/flow_tap_cmds.txt
- doc/guides/prog_guide/ethdev/switch_representation.rst
- doc/guides/tools/flow-perf.rst
- usertools/dpdk-rss-flows.py
- examples/vmdq/main.c
- examples/vmdq_dcb/main.c
- doc/guides/rel_notes/release_26_11.rst (DCB/VMDq validation)

## 21. QoS: Metering, Policing, Hierarchical Scheduling and Their Hardware Offloads

*Folder:* `chapters/21-qos-meter-sched/` · *Level:* advanced · *Prerequisites:* ch10, ch18, ch20

How to enforce rates and priorities in software: token buckets, the srTCM/trTCM/RFC 4115 meters in lib/meter, building a policer, and the hierarchical scheduler lib/sched (port -> subport -> pipe -> traffic class -> queue) with its credit-based shaping, strict priority and WRR, plus RED/WRED and PIE active queue management. Closes with the same concepts offloaded to the NIC through rte_mtr (meters and policies) and rte_tm (node hierarchies and shapers), and how portable code checks for them.

**Concepts**

- Token bucket algorithm: rate, burst size, refill, conformance
- srTCM (RFC 2697): CIR, CBS, EBS, green/yellow/red; trTCM (RFC 2698): CIR/PIR, CBS/PBS; trTCM RFC 4115
- Color-blind vs color-aware metering; profiles vs per-flow runtime state; rates in bytes/s, time in TSC cycles
- Policer actions table (pass/recolor/drop) as in the qos_meter sample
- rte_sched hierarchy: port, subports, pipes, 13 traffic classes (12 strict priority + 1 best-effort with 4 WRR queues), queues
- Shaping with token buckets at subport/pipe/TC levels; credits; TC oversubscription
- Enqueue/dequeue API, rte_sched_port_pkt_write classification metadata, grinders and prefetch state machine
- Pacing dequeue to real TX capacity; stats per subport/queue
- Active queue management: RED/WRED curves (min/max thresholds, maxp, EWMA), PIE
- Hardware QoS APIs: rte_mtr (meter profiles, policies, METER/METER_MARK rte_flow actions) and rte_tm (hierarchy of nodes, shapers, WRED profiles); capability queries; on vdevs expect -ENOSYS (ops absent) or -ENOTSUP — treat both as unsupported; when to prefer hardware
- Band 3 review page (ch14-ch21) with a predict-then-reveal quiz, and the band 3 project
- 26.11: RED no longer has its private rte_fast_rand(); application code uses rte_rand()

**APIs**

`rte_meter_srtcm_profile_config`, `rte_meter_srtcm_config`, `rte_meter_srtcm_color_blind_check`, `rte_meter_srtcm_color_aware_check`, `rte_meter_trtcm_profile_config`, `rte_meter_trtcm_config`, `rte_meter_trtcm_color_blind_check`, `rte_meter_trtcm_rfc4115_profile_config`, `enum rte_color`, `rte_sched_port_config`, `rte_sched_subport_config`, `rte_sched_subport_pipe_profile_add`, `rte_sched_pipe_config`, `rte_sched_port_pkt_write`, `rte_sched_port_enqueue`, `rte_sched_port_dequeue`, `rte_sched_subport_read_stats`, `rte_sched_queue_read_stats`, `rte_red_config_init`, `rte_red_rt_data_init`, `rte_red_enqueue`, `rte_pie_config_init`, `rte_mtr_capabilities_get`, `rte_mtr_meter_profile_add`, `rte_mtr_create`, `rte_tm_capabilities_get`, `rte_tm_node_add`, `rte_tm_hierarchy_commit`

**Runnable code examples**

- **meter_demo.c** — Feeds a synthetic stream at 2x CIR through srTCM and trTCM with synthetic TSC time; prints color counts per 100 ms window. Based on research/07-examples/meter_demo.c.  
  Run here: `./meter_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch21-meter`
- **policer.c** — Per-flow trTCM meters with a policy table (green pass, yellow recolor/mark DSCP, red drop) applied to packets from a pcap; output counts per action.  
  Run here: `./policer -l 0 --no-pci --no-huge -m 128 --file-prefix=ch21-pol --vdev=net_pcap0,rx_pcap=traffic.pcap,tx_pcap=policed.pcap`
- **sched_mini.c** — 1 subport, 4 pipes, traffic in TC0 vs best-effort; emulated NIC pacing of dequeue; prints per-TC throughput showing priority and pipe rate limits. Based on research/07-examples/sched_mini.c.  
  Run here: `./sched_mini -l 0 --no-pci --no-huge -m 256 --file-prefix=ch21-sched`
- **red_curve.c** — Drives rte_red with increasing queue lengths and prints drop probability vs average queue size (data for the chart); compares with PIE. Uses rte_rand() (rte_fast_rand was removed in 26.11).  
  Run here: `./red_curve -l 0 --no-pci --no-huge -m 64 --file-prefix=ch21-red`
- **dpdk-qos_meter + dpdk-qos_sched (prebuilt)** — qos_meter hard-codes RX checksum offloads, so it fails on net_ring/pcap ('does not support Rx offloads ... (-22)', captured) and runs on two net_tap ports with traffic injected by sendraw.py; qos_sched runs on two net_null ports with profile.cfg copied from examples/qos_sched and --msz 16384 (its default 2M-mbuf pool does not fit -m 256).  
  Run here: `$DPDK_SRC/build/examples/dpdk-qos_meter -l 1 --no-pci --no-huge -m 256 --file-prefix=ch21-qm --vdev=net_tap0,iface=ch21tap0 --vdev=net_tap1,iface=ch21tap1 -- -p 0x3 ; $DPDK_SRC/build/examples/dpdk-qos_sched -l 1-3 --no-pci --no-huge -m 256 --file-prefix=ch21-qs --vdev=net_null0 --vdev=net_null1 -- --pfc "0,1,2,3" --cfg profile.cfg --msz 16384`
- **qos_caps.c** — Queries rte_mtr and rte_tm capabilities on net_null/net_tap and prints the real error text (net_null gives 'Function not implemented', i.e. ENOSYS); portable code treats ENOSYS and ENOTSUP alike.  
  Run here: `./qos_caps -l 0 --no-pci --no-huge -m 128 --file-prefix=ch21-qos --vdev=net_null0 --vdev=net_tap0,iface=ch21tap3`
- **band3_project/ (L3 forwarder)** — Band 3 project with solution: an L3 forwarder with an rte_lpm route table (RCU-protected updates), an ACL drop list, and a per-flow srTCM meter in an rte_hash flow table; traffic from net_pcap (a generated pcap with known routes, blocked flows and one over-rate flow), output to pcap. run.sh is the acceptance check: it counts forwarded, ACL-dropped and meter-dropped packets against expected values and prints PASS/FAIL; a second mode measures Mpps on net_null.  
  Run here: `band3_project/run.sh (prefix ch21-b3, --no-huge -m 256, timeout 20 s)`

**Visualizations**

- **Token bucket droplets** (animation) — Buckets fill at CIR/PIR; arriving packets of varying sizes take tokens and get coloured; srTCM C->E overflow vs trTCM two independent buckets; sliders for rates and bursts.
- **Scheduler hierarchy** (animation) — Tree with queue-fill bars; dequeue picks by strict priority across TCs and WRR within best-effort; shaping credits deplete and refill.
- **RED curve** (interactive) — Drop probability vs average queue length with sliders for min/max thresholds and maxp; EWMA trace of a bursty queue.
- **Colour timeline** (chart) — Packet colours over time from meter_demo output.
- **Software vs hardware QoS** (diagram) — lib/meter + lib/sched on CPU vs rte_mtr + rte_tm offloaded to NIC.
- **rte_tm hierarchy (hardware)** (diagram) — Port -> subport -> pipe -> TC -> queue tree with SP/WFQ and shapers, as defined by rte_tm.

**Exercises**

1. [easy] Make the policer colour-aware using the DSCP of incoming packets.
2. [medium] Give pipe 0 twice the rate of the others and verify in sched_mini.
3. [medium] Plot WRED with different thresholds per colour.
4. [stretch] Explain why dequeue must be paced by real TX capacity and what happens if it is not.

**Sources**

- doc/guides/prog_guide/ethdev/qos_framework.rst
- doc/guides/prog_guide/ethdev/traffic_metering_and_policing.rst
- doc/guides/sample_app_ug/qos_metering.rst
- doc/guides/sample_app_ug/qos_scheduler.rst
- lib/meter/rte_meter.h
- lib/sched/rte_sched.h
- lib/sched/rte_red.h
- lib/sched/rte_pie.h
- examples/qos_meter/
- examples/qos_sched/
- RFC 2697, RFC 2698, RFC 4115
- /home/user/ai_lab/dpdk_research/research/07-packet-processing-libs.md
- /home/user/ai_lab/dpdk_research/research/07-examples/meter_demo.c
- /home/user/ai_lab/dpdk_research/research/07-examples/sched_mini.c
- doc/guides/prog_guide/ethdev/traffic_management.rst
- lib/ethdev/rte_mtr.h
- lib/ethdev/rte_tm.h
- doc/guides/rel_notes/release_26_11.rst (sched: rte_fast_rand removed)

## 22. Performance Engineering: Cycles, Caches, Batching, SIMD, NUMA and Power

*Folder:* `chapters/22-performance-engineering/` · *Level:* expert · *Prerequisites:* ch8, ch14, ch15

How to make a DPDK application fast and keep it fast — and how to measure honestly. Measure first (TSC, testpmd cycle recording, telemetry lcore usage; rte_pmu and perf are not available on this VM), then apply the techniques that matter — batching, cache-line awareness, prefetching, branch hints, application-level SIMD, NUMA placement, CPU isolation — and understand power management and what of it this VM can and cannot show. A 'measuring honestly' section adds latency histograms with percentiles, a zero-loss throughput search and the rules for publishing numbers. Vector PMD paths are covered in ch23.

**Concepts**

- Cycle budget per packet and the latency ladder (L1, L2, LLC, DRAM, remote DRAM, PCIe, syscall)
- Measuring: rte_rdtsc_precise, testpmd --record-core-cycles / --record-burst-stats, /eal/lcore/usage with rte_lcore_register_usage_cb; rte_pmu is compile-only here (rte_pmu_init returns -ENODEV) and perf is not installed — fall back to rte_rdtsc_precise
- Batching: per-call fixed cost vs per-packet cost; reuse ch8's burst-sweep data and add testpmd --record-core-cycles numbers
- Cache lines: RTE_CACHE_LINE_SIZE, __rte_cache_aligned, RTE_CACHE_GUARD, false sharing (measured in ch14; reused here), hot/cold field split (mbuf)
- Struct layout: hot/cold field splitting in a 64-byte flow record, shown with gdb 'ptype /o' (pahole is not installed), and a working-set vs LLC-size sweep showing where lookups fall off the cache
- Prefetching: rte_prefetch0/1/2, rte_prefetch_non_temporal, rte_prefetch0_write, prefetch-ahead pattern from l3fwd; too-early eviction
- Branch hints and code layout: likely/unlikely, __rte_hot/__rte_cold, __rte_always_inline, __rte_noinline
- Application-level SIMD: rte_vect.h, rte_vect_get_max_simd_bitwidth (256 by default here even with AVX-512F), --force-max-simd-bitwidth=512, per-function __attribute__((target("avx512f,avx512bw"))) plus rte_cpu_get_flag_enabled before calling; DPDK has no SIMD IPv4-checksum API (vector PMD paths: ch23)
- rte_memcpy vs libc memcpy: rte_mov16/32/64/128/256 in lib/eal/x86/include/rte_memcpy.h; constant vs variable size, aligned vs unaligned, 16 B to 4 KB; the AVX-512 path needs __AVX512F__ and RTE_MEMCPY_AVX512 at build time, so the result depends on how DPDK and your app were compiled
- NUMA placement: rte_eth_dev_socket_id, rte_lcore_to_socket_id, rte_cpu_socket_id (26.11), socket-local pools
- CPU isolation: isolcpus, nohz_full, rcu_nocbs, irqaffinity, never two busy lcores per CPU; usertools/cpu_layout.py; the noisy-neighbour experiment (testpmd noisy forward mode and a pinned busy loop); l2fwd-cat (cache allocation) pointer; deployment-time setup is in ch29
- Rx interrupts from scratch: intr_conf.rxq = 1 in rte_eth_conf, rte_eth_dev_rx_intr_ctl_q(port, q, RTE_EPOLL_PER_THREAD, RTE_INTR_EVENT_ADD, data), poll until N empty polls, rte_eth_dev_rx_intr_enable, re-poll once to close the race window, rte_epoll_wait, rte_eth_dev_rx_intr_disable; the EAL interrupt thread and rte_intr_callback_register for device events (rte_interrupts.h, rte_epoll.h); net_tap (drivers/net/tap/tap_intr.c) and virtio implement it; this is the real explanation behind ch1's intr_vs_poll peek-ahead
- Power API map: per-lcore frequency (rte_power_init, rte_power_freq_up/down/max/min, rte_power_set_env; acpi/intel_pstate/cppc/amd-pstate drivers), uncore (rte_power_uncore_*, RTE_UNCORE_PM_ENV_AUTO_DETECT in 26.11), PM QoS resume latency (rte_power_qos_set_cpu_resume_latency), PMD power management pause/monitor/scale, Rx interrupts (rte_eth_dev_rx_intr_*); l3fwd-power modes (legacy, interrupt-only, telemetry, pmd-mgmt); vm_power_manager pointer
- Profiling without perf: a gdb-based 'poor man's profiler' that samples the stacks of a busy lcore N times and aggregates a flat profile and folded flame-graph text; on a real host 'perf top' / 'perf record -g' on the poll loop (walkthrough with labelled sample output, marked not runnable here)
- Verifying isolation: /sys/devices/system/cpu/isolated and nohz_full, per-CPU /proc/interrupts deltas (LOC ticks, NIC IRQs on DPDK cores), kworker/ksoftirqd threads on lcore CPUs (ps -eLo psr), VM steal time in /proc/stat; rtla osnoise/hwlat as pointers
- Measuring honestly: warm-up, median of N>=5 with min/max (error bars on every chart), fixed packet size and offered load, latency percentiles (p50/p99/p99.9/max) from a log2 histogram, coordinated omission, zero-loss throughput search (RFC 2544 style), drops defined by imissed/rx_nombuf/app counters; traffic generators (testpmd txonly/flowgen limits, TRex, pktgen-dpdk) and the PVP benchmark as methodology
- What this VM cannot show: no cpufreq sysfs (frequency scaling and scale mode fail), no WAITPKG/MONITORX (monitor mode -95), pause mode's apparent CPU saving is KVM pause-loop exiting, no PMU events
- Disclaimer table: VM/software-PMD numbers vs real NICs (PCIe bandwidth, DDIO, descriptor write-back, interrupt moderation)

**APIs**

`rte_rdtsc_precise`, `rte_get_tsc_hz`, `rte_lcore_register_usage_cb`, `rte_prefetch0`, `rte_prefetch1`, `rte_prefetch_non_temporal`, `rte_prefetch0_write`, `likely`, `unlikely`, `__rte_hot`, `__rte_cold`, `__rte_always_inline`, `__rte_cache_aligned`, `RTE_CACHE_GUARD`, `rte_vect_get_max_simd_bitwidth`, `rte_vect_set_max_simd_bitwidth`, `rte_cpu_get_flag_enabled`, `rte_eth_dev_socket_id`, `rte_cpu_socket_id`, `rte_power_ethdev_pmgmt_queue_enable`, `rte_power_pause`, `rte_eth_dev_rx_intr_enable`, `rte_eth_dev_rx_intr_ctl_q`, `rte_epoll_wait`, `rte_pmu_init (compile-only; -ENODEV here)`, `rte_power_monitor (unsupported on this CPU)`, `rte_power_init`, `rte_power_freq_up`, `rte_power_set_env`, `rte_power_uncore_init`, `rte_power_qos_set_cpu_resume_latency`, `rte_mbuf_dyn_tx_timestamp_register`, `rte_memcpy`, `rte_eth_dev_rx_intr_disable`, `rte_intr_callback_register`, `RTE_EPOLL_PER_THREAD`

**Runnable code examples**

- **burst_sweep.sh** — testpmd io forwarding on net_null with --burst 1..128 and --record-core-cycles; merges its cycles/packet with ch8's burst_sweep data instead of repeating the C sweep; median of 5 per point.  
  Run here: `for b in 1 4 8 16 32 64 128: timeout -s INT -k 5 6 dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch22-b$b --vdev=net_null0 --vdev=net_null1 -- --burst=$b --total-num-mbufs=16384 --stats-period 2 --record-core-cycles`
- **layout_lab.c** — A 64-byte flow record in two layouts (hot fields together vs interleaved with cold fields) looked up from an rte_hash of 1M entries, plus a working-set sweep 32 KB..256 MB; prints ns/lookup (median of 5, min/max); run.sh prints the struct layouts with gdb -batch -ex 'ptype /o struct flow_rec'. False-sharing numbers come from ch14's counters.c.  
  Run here: `./layout_lab -l 0 --no-pci --no-huge -m 512 --file-prefix=ch22-lay`
- **prefetch_lab.c** — Random gather over a 256 MB table with prefetch distance 0..32; prints ns/element per distance (U-curve); a --no-huge run vs a hugepage run (table sized to fit -m 128) shows the TLB effect.  
  Run here: `./prefetch_lab -l 0 --no-pci --no-huge -m 256 --file-prefix=ch22-pf ; ./prefetch_lab -l 0 --no-pci -m 128 --file-prefix=ch22-pf2`
- **branch_simd_lab.c (+ rte_memcpy sweep)** — Classifies random vs sorted packet sizes with and without likely(); then an IPv4 header checksum over many headers with scalar vs hand-written SSE/AVX2/AVX-512 intrinsics (per-function target attributes, rte_cpu_get_flag_enabled check), selected by rte_vect_get_max_simd_bitwidth; prints which path ran. Adds an rte_memcpy vs memcpy sweep: sizes 16 B..4 KB, compile-time constant vs runtime size, aligned vs unaligned destination; median, min and max of 5 runs per cell, and the build flags printed with the result.  
  Run here: `./branch_simd_lab -l 0 --no-pci --no-huge -m 64 --file-prefix=ch22-simd --force-max-simd-bitwidth=512`
- **rx_intr.c** — Rx interrupt loop on net_tap: poll; after 64 empty polls arm the queue interrupt, re-poll once (the race window), then sleep in rte_epoll_wait; a Python sender bursts packets every 200 ms; prints wakeups, empty polls, packets and CPU time (getrusage) vs a busy-poll run; a --no-repoll flag shows the race (a packet arriving between the last poll and enable is not noticed until the next one).  
  Run here: `./rx_intr -l 0 --no-pci --no-huge -m 128 --file-prefix=ch22-intr --vdev=net_tap0,iface=ch22tap1 (python sender in run.sh)`
- **power_and_noise.sh** — (1) l3fwd-power --interrupt-only on net_tap: ~0% CPU idle vs a busy-poll run at 100% (top -b, per thread with top -H); (2) --pmd-mgmt=pause with --parse-ptype --pause-duration=100 as a mechanism demo with the KVM caveat; (3) monitor and scale captured as failures (-95, no cpufreq); (4) noisy neighbour: busy loop pinned to the forwarding CPU vs testpmd noisy forward mode, Mpps before/after.  
  Run here: `$DPDK_SRC/build/examples/dpdk-l3fwd-power -l 1 --no-pci --no-huge -m 256 --file-prefix=ch22-pw --vdev=net_tap0,iface=ch22tap0 -- -p 0x1 --config='(0,0,1)' --interrupt-only --parse-ptype ; pause run adds --pmd-mgmt=pause --pause-duration=100`
- **power_probe.c** — Calls rte_power_init/freq_*, rte_power_uncore_init, rte_power_qos_set_cpu_resume_latency, rte_power_ethdev_pmgmt_queue_enable (pause/monitor/scale) and rte_pmu_init, printing each real return code and why it fails here, with graceful fallbacks.  
  Run here: `./power_probe -l 0-1 --no-pci --no-huge -m 128 --file-prefix=ch22-pp --vdev=net_ring0`
- **latency_hist.c** — Stamps a TX timestamp dynfield on a net_ring loop at fixed offered load, records RX-TX cycles in a log2 HDR-style histogram and prints p50/p99/p99.9/max; repeated with a noisy neighbour pinned to the same CPU to show tail growth.  
  Run here: `./latency_hist -l 0-1 --no-pci --no-huge -m 128 --file-prefix=ch22-lat -- --rate 200000 ; run.sh repeats with a pinned busy loop`
- **loss_search.sh** — Binary search of offered rate (testpmd txonly with --txpkts and burst pacing, or 'set port 0 rate') against a receiving testpmd over memif or net_ring, recording the highest zero-loss rate in RFC 2544 style; median of 5 per probe point. Both testpmd processes pass --total-num-mbufs=8192.  
  Run here: `two testpmd processes, --no-huge -m 256, prefixes ch22-ls-tx / ch22-ls-rx, each step <= 6 s`
- **pmp_profile.sh** — Poor man's profiler: starts testpmd io on net_null (--total-num-mbufs=8192, --stats-period 1), attaches 'gdb -p <pid> -batch -ex "thread apply all bt"' 20 times 100 ms apart, aggregates the stacks of the forwarding lcore into a flat profile and folded text; the perf top/record walkthrough is text only.  
  Run here: `./pmp_profile.sh (prefix ch22-pmp, timeout 20 s)`
- **isolation_check.sh** — Read-only report: isolated and nohz_full CPUs, per-CPU interrupt deltas over 5 s, threads running on each CPU used by a DPDK lcore (ps -eLo psr,comm), steal time; the latency_hist noisy-neighbour lab uses it in a 'find the noise source' step.  
  Run here: `./isolation_check.sh [pid] (no EAL options; read-only)`

**Visualizations**

- **Cycle-budget bar** (interactive) — Bar of 181 cycles (10G at 2.7 GHz) shrinking to 18 (100G) with draggable cost tokens: L1 hit, LLC hit, DRAM miss, mispredict, atomic.
- **Prefetch pipeline** (interactive) — Timeline of loads with memory latency bars; without prefetch the core stalls per packet; slider for prefetch distance overlaps the stalls; too-far causes eviction.
- **Burst amortisation (testpmd)** (chart) — Measured Mpps and cycles/packet vs burst size.
- **Power state machine** (animation) — Empty-poll counter -> threshold -> pause/monitor -> wake on descriptor write or timeout, with a Watts vs wake-latency trade-off plot.
- **CPU isolation timeline** (animation) — A CPU's timeline with ticks, kworkers and a noisy process interrupting the poll loop vs a clean isolated CPU; jitter histogram.
- **Latency histogram explorer** (interactive) — Log2 buckets from latency_hist output; learner toggles noisy neighbour and offered load and sees p50/p99/p99.9 markers move; shows how averages hide tails.
- **Power API map** (diagram) — Per-lcore frequency, uncore, C-state/PM QoS, PMD power management (pause/monitor/scale) and Rx interrupts, each marked runnable/not runnable on this VM with the reason.
- **Rx interrupt step-through** (animation) — Predict-then-step: poll, empty-poll counter, arm, re-poll, sleep, packet arrives, wake; the learner can remove the re-poll and see a packet wait in the ring while the core sleeps.

**Exercises**

1. [easy] Add prefetching of the next packet's header to mini_l2fwd (ch 10) and measure.
2. [medium] Find which offload drops virtio_user from the vectorised path using rte_eth_rx_burst_mode_get.
3. [medium] Run rx_intr with and without the re-poll and explain, from the captured counters, the race it closes.
4. [medium] Design an experiment that measures latency (not just throughput) of a forwarding loop.
5. [stretch] Write the kernel command line you would use to isolate CPUs 2-3 for DPDK and explain each parameter.

**Sources**

- doc/guides/prog_guide/perf_opt_guidelines.rst
- doc/guides/prog_guide/writing_efficient_code.rst
- doc/guides/prog_guide/power_man.rst
- doc/guides/prog_guide/profile_app.rst
- doc/guides/linux_gsg/nic_perf_intel_platform.rst
- doc/guides/sample_app_ug/l3_forward_power_man.rst
- lib/eal/include/generic/rte_prefetch.h
- lib/eal/include/rte_common.h
- lib/eal/include/generic/rte_vect.h
- lib/power/rte_power_pmd_mgmt.h
- lib/eal/include/generic/rte_power_intrinsics.h
- lib/pmu/rte_pmu.h
- examples/l3fwd-power/main.c
- /home/user/ai_lab/dpdk_research/research/09-performance-concurrency.md
- /home/user/ai_lab/dpdk_research/research/03-memory-examples/fshare.c
- /home/user/ai_lab/dpdk_research/research/09-examples/bench.c
- usertools/cpu_layout.py
- lib/power/rte_power_cpufreq.h
- lib/power/rte_power_uncore.h
- lib/power/rte_power_qos.h
- doc/guides/howto/pvp_reference_benchmark.rst
- doc/guides/sample_app_ug/l2_forward_cat.rst
- app/test-pmd/noisy_vnf.c
- lib/eal/x86/include/rte_memcpy.h
- lib/eal/include/rte_interrupts.h
- lib/eal/include/rte_epoll.h
- drivers/net/tap/tap_intr.c

## 23. Inside a Poll Mode Driver: Descriptor Rings, Vector Paths, eth_dev_ops, Buses, VFIO and Writing Your Own vdev PMD

*Folder:* `chapters/23-inside-a-pmd/` · *Level:* expert · *Prerequisites:* ch8, ch9, ch12, ch22

Opens the box behind rte_eth_rx_burst: how real NICs exchange packets with software through descriptor rings (DD bits, tail doorbells, RS bits and thresholds), how vector Rx/Tx paths process several descriptors at once and why they impose constraints, how a PMD is structured (probe, rte_eth_dev, eth_dev_ops, burst functions, path selection), how devices reach a PMD (bus types, PCI, VFIO group vs cdev/IOMMUFD, UIO), how to choose and qualify a NIC, and finally writes a small software PMD — with descriptor-status ops — registered on the vdev bus.

**Concepts**

- NIC RX descriptor ring: descriptors with buffer IOVA, DD (descriptor done) bit, head owned by NIC, tail register doorbell, sw_ring of mbuf pointers, refill and rx_free_thresh
- NIC TX ring: RS bit every tx_rs_thresh descriptors, lazy cleanup when free < tx_free_thresh, rte_eth_tx_done_cleanup
- Doorbell ordering: write descriptors, then rte_io_wmb(), then the tail-register write (or rte_write32(), which is a barrier plus rte_write32_relaxed()); reading completions uses rte_io_rmb() between the DD check and the descriptor fields; contrast with rte_atomic_thread_fence for CPU-to-CPU ordering (26.11 removed rte_smp_*mb; the release notes say device ordering must use rte_io_*mb)
- Descriptor status APIs: rte_eth_rx_queue_count, rte_eth_rx_descriptor_status, rte_eth_tx_descriptor_status, rte_eth_tx_done_cleanup; of the PMDs built here none implements descriptor_status, only net_vhost implements rx_queue_count and tx_done_cleanup (ch24 runs it); net_toy implements them so you see both sides; TX free path via rte_pktmbuf_free_seg (ch7)
- PMD anatomy: driver registration (RTE_PMD_REGISTER_VDEV / _PCI), probe -> rte_eth_vdev_allocate -> fill rte_eth_dev_data and dev_ops -> set rx_pkt_burst/tx_pkt_burst -> rte_eth_dev_probing_finish
- struct rte_eth_dev, rte_eth_dev_data, struct eth_dev_ops (dev_configure, dev_start, dev_infos_get, rx_queue_setup, link_update, stats_get, ...)
- Devargs parsing with kvargs and RTE_PMD_REGISTER_PARAM_STRING
- Walkthrough of drivers/net/null/rte_eth_null.c
- Vector PMD paths (moved from ch22): loading 4/8 descriptors into one SIMD register and shuffling into mbuf fields; constraints (burst >= 4/32, ring size, offloads disabled, SIMD bitwidth, CPU flags); path selection, burst mode strings, features .ini matrix
- Bus types table (pci, vdev, auxiliary, vmbus, platform with 26.11 device-tree matching, cdx, uacce, fslmc/dpaa); PCI: BARs, MMIO doorbells; VFIO group mode (/dev/vfio/N) vs 26.11 cdev/IOMMUFD mode (/dev/vfio/devices/vfioX + /dev/iommu); the whole rte_vfio_* API is internal since 26.11; UIO and no-IOMMU risks; interrupt handles (rte_intr_instance_alloc initialises fds to -1, new rte_intr_fd_close); dpdk-devbind.py (concept only; never bind eth0)
- Advanced ethdev features implemented by PMDs: mbuf recycle (rte_eth_recycle_mbufs), hairpin queues, shared Rx queues, Rx interrupts
- Internal APIs: ethdev_driver.h, __rte_internal, ALLOW_INTERNAL_API
- Choosing and qualifying a NIC: reading doc/guides/nics/features/*.ini, vendor PMD specifics (mlx5 bifurcated driver needs no vfio binding, Intel ice DDP packages, firmware/driver matching), SR-IOV VFs (trust mode, spoof check, VF MAC/VLAN limits, PF kernel driver interplay), vendor rte_pmd_* APIs and their portability cost, a testpmd qualification checklist (show port cap/info/xstats, rxq/txq info, desc status, flow validate)
- Physical-port knobs (moved from ch12) (table: API -> purpose -> supported by vdevs here?): link_speeds/RTE_ETH_LINK_SPEED_FIXED/autoneg/speed lanes (incl. 1.6T), flow control and PFC (rte_eth_dev_flow_ctrl_set, rte_eth_dev_priority_flow_ctrl_set / _queue_configure), FEC (rte_eth_fec_*), congestion management (rte_eth_cman_*), module EEPROM (rte_eth_dev_get_module_info/eeprom, experimental rte_eth_module_eeprom_parse), rte_eth_dev_conf_get, rte_eth_dev_get_reg_info_ext, rte_eth_rx_descriptor_dump, RX_AVAIL_THRESH event (rte_eth_rx_avail_thresh_set)

**APIs**

`rte_eth_rx_queue_count`, `rte_eth_rx_descriptor_status`, `rte_eth_tx_descriptor_status`, `rte_eth_tx_done_cleanup`, `rte_eth_rx_queue_info_get`, `rte_eth_rx_burst_mode_get`, `RTE_PMD_REGISTER_VDEV`, `RTE_PMD_REGISTER_PARAM_STRING`, `rte_vdev_device_name`, `rte_vdev_device_args`, `rte_eth_vdev_allocate`, `rte_eth_dev_probing_finish`, `rte_eth_dev_release_port`, `struct eth_dev_ops`, `rte_kvargs_parse`, `rte_eth_recycle_mbufs (overview)`, `rte_eth_rx_hairpin_queue_setup (overview)`, `rte_eth_tx_burst_mode_get`, `struct eth_dev_ops .rx_queue_count`, `rte_intr_instance_alloc`, `rte_io_wmb`, `rte_io_rmb`, `rte_write32`, `rte_write32_relaxed`, `rte_read32`, `rte_eth_fec_get_capability`, `rte_eth_dev_flow_ctrl_get`, `rte_eth_dev_get_module_info`

**Runnable code examples**

- **desc_ring_sim.c** — A software model of an RX and TX descriptor ring: a 'NIC' lcore writes packets into buffers and sets DD bits at a configurable rate; the 'PMD' lcore harvests bursts, refills mbufs and writes the tail every rx_free_thresh; prints imissed and doorbell counts for different thresholds and rates. Comments mark where a real PMD needs rte_io_wmb before the tail write.  
  Run here: `./desc_ring_sim -l 0-1 --no-pci --no-huge -m 128 --file-prefix=ch23-sim`
- **net_toy PMD (my_pmd.c)** — A ~350-line software PMD 'net_toy' compiled into the application: registers on the vdev bus, parses a 'pattern=' devarg, implements configure/start/stop/infos/queue setup/stats, rx (generates packets) / tx (counts and frees), plus rx_queue_count and rx_descriptor_status over an internal software descriptor ring so the app can query them. Runnable: Makefile uses -DALLOW_INTERNAL_API -I$DPDK_SRC/lib/ethdev -I$DPDK_SRC/drivers/bus/vdev -I$DPDK_SRC/lib/eal/include plus pkg-config cflags and static libs (verified to probe 1 port named net_toy). Its tx_burst shows, in a comment and a no-op call, where the doorbell barrier (rte_io_wmb) and tail write would go.  
  Run here: `./my_pmd -l 0 --no-pci --no-huge -m 128 --file-prefix=ch23-toy --vdev=net_toy0,pattern=0xab `
- **null PMD reading guide** — Not a program: an annotated walkthrough page section of drivers/net/null/rte_eth_null.c (probe, dev_ops table, eth_null_rx/tx) with line references.  
  Run here: `none (reading)`
- **nic_features.py -> features table** — Parses $DPDK_SRC/doc/guides/nics/features/*.ini into JSON embedded in the chapter's filterable NIC feature widget; also prints which built vdev PMDs claim which features.  
  Run here: `python3 -I nic_features.py $DPDK_SRC/doc/guides/nics/features > features.json`
- **devbind status** — dpdk-devbind.py --status captured and annotated: eth0 shown as the active virtio device that must never be bound, with the meaning of the '*Active*' warning.  
  Run here: `python3 $DPDK_SRC/usertools/dpdk-devbind.py --status (read-only)`
- **knobs_probe.c** — Calls every physical-port knob (speed/autoneg via conf, flow control, PFC, FEC capability, cman info, module info, reg info, descriptor dump, avail-thresh) on net_null and net_tap and prints a capability table with the real return codes (mostly -ENOTSUP / -ENOSYS).  
  Run here: `./knobs_probe -l 0 --no-pci --no-huge -m 128 --file-prefix=ch23-knob --vdev=net_null0 --vdev=net_tap0,iface=ch23tap1`

**Visualizations**

- **RX descriptor ring** (animation) — Circular ring with NIC head and software tail; DMA writes packets and sets DD (colour change); rx_burst sweeps DD descriptors, swaps in fresh mbufs from the mempool, writes the tail when held > rx_free_thresh; sliders for arrival vs poll rate show imissed; vector-mode toggle processes 4 at a time. 'Predict, then step' control before each refill.
- **TX ring with RS/DD** (animation) — App enqueues packets, RS bit every tx_rs_thresh, NIC writes back DD only on RS descriptors, lazy free when free count < tx_free_thresh; full ring shows the unsent tail.
- **PMD probe anatomy** (animation) — RTE_PMD_REGISTER_VDEV -> probe -> allocate -> dev_ops -> burst function selection -> probing_finish -> NEW event.
- **eth_dev_ops map** (interactive) — Click an rte_eth_* public API to see which eth_dev_ops callback it reaches and the checks in between.
- **VFIO vs UIO DMA path** (diagram) — Device -> IOMMU -> RAM for VFIO (group mode /dev/vfio/N vs cdev/IOMMUFD /dev/vfio/devices/vfioX + /dev/iommu) vs device -> PA directly for UIO; SR-IOV PF/VF split.
- **SIMD lanes and path selection** (animation) — Four RX descriptors loaded into one vector register and shuffled into mbuf fields; decision tree for vector vs scalar path (offloads, SIMD width, CPU flag, ring size) that the learner walks by toggling conditions.
- **NIC feature filter** (interactive) — Pick features (rte_flow, RSS, TSO, timestamp, inline crypto, ...) and see which PMDs claim them, from the parsed features/*.ini.
- **Doorbell ordering** (animation) — Predict-then-step: the CPU writes descriptors and the tail; without rte_io_wmb the learner can reorder the writes and watch the NIC fetch a half-written descriptor.

**Exercises**

1. [easy] Add an xstats callback to net_toy that reports a custom counter.
2. [medium] In desc_ring_sim, find the rx_free_thresh that minimises doorbells without increasing imissed at 80% load.
3. [medium] Read the virtio PMD path selection code and draw its decision tree.
4. [stretch] Explain why a PMD must never be called from two lcores on the same queue.

**Sources**

- doc/guides/prog_guide/ethdev/ethdev.rst (PMD architecture, descriptors)
- doc/guides/contributing/new_driver.rst
- doc/guides/nics/features.rst
- doc/guides/linux_gsg/linux_drivers.rst
- lib/ethdev/ethdev_driver.h
- lib/ethdev/ethdev_vdev.h
- lib/ethdev/rte_ethdev_core.h
- drivers/bus/vdev/bus_vdev_driver.h
- drivers/net/null/rte_eth_null.c
- drivers/net/ring/rte_eth_ring.c
- drivers/net/intel/common/rx.h
- drivers/net/virtio/virtio_ethdev.c
- usertools/dpdk-devbind.py
- /home/user/ai_lab/dpdk_research/research/05-ethdev.md
- doc/guides/rel_notes/release_26_11.rst (VFIO cdev, rte_vfio internal)
- doc/guides/nics/features/
- lib/eal/include/rte_interrupts.h
- drivers/net/vhost/rte_eth_vhost.c (rx_queue_count)
- lib/eal/include/generic/rte_io.h
- lib/eal/x86/include/rte_io.h

## 24. Virtio, vhost-user and memif: Networking Between VMs, Containers and Processes

*Folder:* `chapters/24-virtio-vhost-memif/` · *Level:* expert · *Prerequisites:* ch9, ch12, ch13, ch16, ch23

The shared-memory PMDs that connect DPDK to VMs, containers and other processes. Explains the virtio specification (split and packed virtqueues, feature negotiation, notifications), the guest-side virtio PMD and virtio_user, the host side vhost-user protocol and librte_vhost (memory tables, address translation, enqueue copies), net_vhost, and the memif protocol, all demonstrated with pairs of processes on one machine — no VM and no NIC needed.

**Concepts**

- virtio basics: device vs driver, virtqueues, feature bits (VERSION_1, MRG_RXBUF, IN_ORDER, RING_PACKED, ...), status negotiation
- Split virtqueue: descriptor table, avail ring, used ring, indexes, kicks and interrupts/suppression
- Packed virtqueue: single ring, AVAIL/USED flags and wrap counter; cache efficiency
- Guest side: virtio PMD in a VM (eth0 on this machine is a virtio device — never bind it), virtio_user as a process-level driver (devargs path, queues, packed_vq, mrg_rxbuf, in_order, server)
- Host side: vhost-user protocol over a unix socket (GET/SET_FEATURES, SET_MEM_TABLE with fds via SCM_RIGHTS, SET_VRING_*), GPA -> HVA translation, client vs server mode, reconnect
- librte_vhost API: rte_vhost_driver_register, callback_register (new_device, destroy_device, vring_state_changed), driver_start, rte_vhost_enqueue_burst (copies), rte_vhost_dequeue_burst (allocates)
- net_vhost ethdev wrapper; vhost/virtio_user and memif run with --no-huge -m 256 here; hugepages (-m 64 --single-file-segments) only for memif zero-copy; memory-region limits; async (DMA) API removed in 26.11
- vhost-kernel exception path, vDPA and VDUSE (concepts; not available here)
- Vector paths in virtio: chosen only with the virtio_user devarg vectorized=1; packed ring + in_order + mrg_rxbuf=0 + --force-max-simd-bitwidth=512 gives 'Vector packed ring'; split ring stays scalar on x86
- memif: shared memory regions, rings, descriptors; control channel handshake; roles server/client; abstract vs filesystem sockets; secret; zero-copy mode
- Container networking patterns: virtio_user + vhost, memif with VPP
- vhost-user flags for rte_vhost_driver_register: RTE_VHOST_USER_CLIENT, RTE_VHOST_USER_NO_RECONNECT, RTE_VHOST_USER_IOMMU_SUPPORT, RTE_VHOST_USER_EXTBUF_SUPPORT, RTE_VHOST_USER_NET_COMPLIANT_OL_FLAGS (legacy vs compliant offload flag semantics)
- Other vhost backends: vhost-crypto (rte_vhost_crypto.h), vhost-blk, vDPA (rte_vdpa.h), VDUSE (concepts)
- Descriptor status and queue info on real implementations: rte_eth_rx_queue_count and rte_eth_tx_done_cleanup on net_vhost; rx_queue_info_get and burst mode on virtio_user (descriptor_status: ENOTSUP everywhere here)

**APIs**

`rte_vhost_driver_register`, `rte_vhost_driver_callback_register`, `rte_vhost_driver_start`, `rte_vhost_driver_unregister`, `rte_vhost_driver_set_features`, `rte_vhost_get_negotiated_features`, `rte_vhost_enqueue_burst`, `rte_vhost_dequeue_burst`, `rte_vhost_get_ifname`, `struct rte_vhost_device_ops`, `virtio_user devargs (path, queues, queue_size, packed_vq, mrg_rxbuf, in_order, server)`, `net_vhost devargs (iface, queues, client)`, `net_memif devargs (role, id, socket, socket-abstract, secret, zero-copy)`, `rte_eth_rx_burst_mode_get`, `RTE_VHOST_USER_CLIENT`, `RTE_VHOST_USER_EXTBUF_SUPPORT`, `RTE_VHOST_USER_NET_COMPLIANT_OL_FLAGS`, `rte_eth_rx_queue_count`, `rte_eth_tx_done_cleanup`, `rte_eth_rx_queue_info_get`

**Runnable code examples**

- **vhost <-> virtio_user testpmd** — Process A: testpmd with net_vhost0 (macswap); process B: testpmd with virtio_user0 connected to the socket, start tx_first; capture VHOST_CONFIG handshake lines and negotiated feature bits; show xstats size histograms.  
  Run here: `A (background, --stats-period 2 so it does not exit on stdin EOF): dpdk-testpmd -l 2-3 --no-huge -m 256 --no-pci --file-prefix=ch24-vh --vdev=net_vhost0,iface=$PWD/vh.sock,queues=1 -- --total-num-mbufs=8192 --forward-mode=macswap --stats-period 2 ; B: dpdk-testpmd -l 0-1 --no-huge -m 256 --no-pci --file-prefix=ch24-vu --vdev=virtio_user0,path=$PWD/vh.sock -- --total-num-mbufs=8192 --tx-first --stats-period 2`
- **virtio path matrix** — Repeat B with packed_vq=0/1, mrg_rxbuf=0/1, in_order=0/1, vectorized=0/1 and --force-max-simd-bitwidth=128/512; print the chosen Rx/Tx burst mode and Mpps (median of 3) in a table; explain why split ring stays scalar.  
  Run here: `matrix.sh loops over devargs, each run ~6 s, prefixes ch24-m*`
- **vhostapp.c** — A raw librte_vhost echo backend: registers the socket, handles new_device/destroy_device, dequeues from the guest TX queue and enqueues back to its RX queue; peer is testpmd virtio_user txonly then io; demonstrates the 256-packet back-pressure stall. Based on research/06-examples/vhostapp.c. The walkthrough includes the vhost-user flags table and which flags vhostapp passes.  
  Run here: `./vhostapp -l 2 --no-huge -m 256 --no-pci --file-prefix=ch24-app -- $PWD/app.sock`
- **memif pair** — Two testpmd processes connected by net_memif with a filesystem socket (socket-abstract=no) under the code dir: server rxonly, client txonly; ls the socket; a secret mismatch shows connection refusal.  
  Run here: `server: --vdev=net_memif0,role=server,socket=$PWD/memif.sock,socket-abstract=no ; client: role=client,same socket; prefixes ch24-ms/ch24-mc ; both --no-huge -m 256 (server testpmd with --stats-period); zero-copy=yes client only with -m 64 --single-file-segments (fails with --no-huge, captured)`
- **feature_decode.py** — Decodes negotiated virtio feature masks from the captured logs into named bits (also used by the visualisation).  
  Run here: `python3 -I feature_decode.py 0x950008000`
- **desc_status_vhost.c** — Attaches to net_vhost while a virtio_user testpmd peer sends: prints rte_eth_rx_queue_count over time, calls rte_eth_tx_done_cleanup, shows rx/tx_descriptor_status returning ENOTSUP; then on the virtio_user side prints rx_queue_info_get and burst-mode strings.  
  Run here: `two processes, --no-huge -m 256 each, prefixes ch24-ds-vh / ch24-ds-vu, socket $PWD/ds.sock, trap removes it`

**Visualizations**

- **Split virtqueue step-through** (animation) — Descriptor table, avail ring, used ring: driver posts a descriptor, bumps avail.idx, kicks; device consumes, writes used ring, interrupts; step buttons and index counters.
- **Packed virtqueue wrap counter** (animation) — Single ring with AVAIL/USED flag bits and the wrap counter flipping on each wrap; side-by-side cache-line count vs split ring.
- **vhost-user handshake** (animation) — Timeline of the real captured message sequence; SET_MEM_TABLE passes fds that get mmapped; GPA -> HVA translation lookup.
- **Feature bitmap decoder** (interactive) — 64-bit bitmap where driver features AND device features light up; enter a captured mask to decode it.
- **memif region layout** (diagram) — Region with C2S rings, S2C rings and buffers; descriptor fields; handshake sequence HELLO/INIT/ADD_REGION/ADD_RING/CONNECT.
- **Throughput by path** (chart) — Measured Mpps for scalar vs vectorised virtio paths.

**Exercises**

1. [easy] Make vhostapp count packets per queue and expose it over telemetry.
2. [medium] Run virtio_user in server mode and vhost as client; restart the vhost side and observe reconnect.
3. [medium] Measure memif Mpps with zero-copy on vs off.
4. [stretch] Explain what would change if the virtio side ran in a QEMU guest instead of virtio_user.

**Sources**

- doc/guides/nics/virtio.rst
- doc/guides/nics/vhost.rst
- doc/guides/nics/memif.rst
- doc/guides/prog_guide/vhost_lib.rst
- doc/guides/howto/virtio_user_for_container_networking.rst
- doc/guides/howto/virtio_user_as_exception_path.rst
- doc/guides/howto/pvp_reference_benchmark.rst
- lib/vhost/rte_vhost.h
- lib/vhost/vhost_user.c
- lib/vhost/virtio_net.c
- drivers/net/virtio/virtqueue.h
- drivers/net/virtio/virtio_user/vhost_user.c
- drivers/net/vhost/rte_eth_vhost.c
- drivers/net/memif/memif.h
- OASIS virtio 1.2 specification
- QEMU docs/interop/vhost-user.rst
- /home/user/ai_lab/dpdk_research/research/06-virtual-devices-and-virtio.md
- /home/user/ai_lab/dpdk_research/research/06-examples/vhostapp.c
- lib/vhost/rte_vhost_crypto.h
- lib/vhost/rte_vdpa.h
- examples/vhost_crypto/
- examples/vdpa/
- examples/vhost_blk/

## 25. Event-Driven Scheduling: eventdev, Adapters, Event Vectors and the Dispatcher

*Folder:* `chapters/25-eventdev-pipelines/` · *Level:* expert · *Prerequisites:* ch11, ch14, ch15

Dynamic load balancing across cores with flow-ordering guarantees in hardware or software. Covers the eventdev model (events, queues, ports, links), the atomic/ordered/parallel scheduling types, credits and back-pressure, the software event_sw scheduler running as a service, the Rx, Tx and timer adapters in depth, event vectors and the vector adapter, link profiles, pre-scheduling, stop-flush draining, xstats/telemetry and the dispatcher library. Distributor and reorder are in ch15; the crypto adapter closes ch26 and the DMA adapter is in ch27.

**Concepts**

- From ch15's pipelines to eventdev: what the scheduler does that rings plus distributor/reorder cannot
- struct rte_event: flow_id (20 bits), sched_type, queue_id, op (NEW/FORWARD/RELEASE), priority, event_type, payload (mbuf / u64)
- Device configuration: rte_event_dev_info_get, configure (nb_queues, nb_ports, nb_events_limit, dequeue depth), queue setup, port setup, links, start
- Schedule types: ATOMIC (per-flow mutual exclusion), ORDERED (parallel with order restoration), PARALLEL (no guarantees); single-link queues
- Capabilities shape your app: RTE_EVENT_DEV_CAP_DISTRIBUTED_SCHED absent -> a centralized scheduler that you must run as a service; MAINTENANCE_FREE absent -> call rte_event_maintain on idle ports; IMPLICIT_RELEASE_DISABLE -> you may (and then must) issue explicit RELEASE; BURST_MODE, QUEUE_ALL_TYPES, CARRY_FLOW_ID, INDEPENDENT_ENQ (rte_eventdev.h), the PRESCHEDULE flags; dumped on event_sw and event_skeleton
- Credits: new_event_threshold, back-pressure, implicit release vs explicit RELEASE
- event_sw is a service: needs a service lcore (-S <corelist>, inside -l; -s coremask is deprecated) or rte_service_run_iter_on_app_lcore
- Adapters: eth Rx adapter (polling weights, internal port vs service), eth Tx adapter, timer adapter; capabilities decide internal port vs service; crypto adapter (ch26) and DMA adapter (ch27) are forward references
- Dispatcher library for event-handler registration
- Tools and samples: dpdk-test-eventdev, eventdev_pipeline, l2fwd-event
- Event vectors: RTE_EVENT_TYPE_VECTOR, struct rte_event_vector, rte_event_eth_rx_adapter_vector_limits_get, the vector adapter (rte_event_vector_adapter_create)
- Port link profiles (rte_event_port_profile_links_set / rte_event_port_profile_switch) and pre-scheduling (rte_event_port_preschedule); rte_event_port_preschedule_modify changes the type at runtime
- Clean shutdown: rte_event_dev_stop_flush_callback_register frees in-flight mbufs at stop; rte_event_port_quiesce on each worker port before rte_event_dev_stop flushes events still held by the port
- Observability: eventdev xstats (rte_event_dev_xstats_names_get/get) and the /eventdev/* telemetry endpoints
- Service mapping for adapters: with one service lcore (-S 3) the event_sw, Rx adapter and Tx adapter services must all be mapped explicitly (rte_event_dev_service_id_get, rte_event_eth_rx_adapter_service_id_get, rte_event_eth_tx_adapter_service_id_get, then rte_service_map_lcore_set(id, 3, 1) and rte_service_runstate_set); without it no packets flow and nothing reports an error

**APIs**

`rte_event_dev_count`, `rte_event_dev_info_get`, `rte_event_dev_configure`, `rte_event_queue_setup`, `rte_event_port_setup`, `rte_event_port_link`, `rte_event_dev_start`, `rte_event_dev_service_id_get`, `rte_event_enqueue_burst`, `rte_event_enqueue_new_burst`, `rte_event_enqueue_forward_burst`, `rte_event_dequeue_burst`, `rte_event_maintain`, `RTE_SCHED_TYPE_ATOMIC`, `RTE_SCHED_TYPE_ORDERED`, `RTE_SCHED_TYPE_PARALLEL`, `rte_event_eth_rx_adapter_create`, `rte_event_eth_rx_adapter_queue_add`, `rte_event_eth_tx_adapter_create`, `rte_event_eth_tx_adapter_enqueue`, `rte_event_timer_adapter_create`, `rte_event_timer_arm_burst`, `rte_dispatcher_create`, `rte_event_vector_adapter_create`, `rte_event_eth_rx_adapter_vector_limits_get`, `struct rte_event_vector`, `rte_event_port_profile_links_set`, `rte_event_port_profile_switch`, `rte_event_port_preschedule`, `rte_event_dev_stop_flush_callback_register`, `rte_event_dev_xstats_get`, `rte_event_dev_xstats_names_get`, `rte_event_port_quiesce`, `rte_event_port_preschedule_modify`, `RTE_EVENT_DEV_CAP_MAINTENANCE_FREE`, `RTE_EVENT_DEV_CAP_DISTRIBUTED_SCHED`, `RTE_EVENT_DEV_CAP_INDEPENDENT_ENQ`, `rte_event_eth_rx_adapter_service_id_get`, `rte_event_eth_tx_adapter_service_id_get`, `rte_service_map_lcore_set`

**Runnable code examples**

- **event_caps.c** — Dumps rte_event_dev_info for event_sw and event_skeleton: every RTE_EVENT_DEV_CAP_* bit with the code consequence (service needed, maintain needed, explicit release allowed), limits (queues, ports, flows, dequeue depth) and adapter caps for a net_null port.  
  Run here: `./event_caps -l 0 --no-pci --no-huge -m 128 --file-prefix=ch25-caps --vdev=event_sw0 --vdev=event_skeleton0 --vdev=net_null0`
- **event_sw_atomic.c** — Producer -> queue0 (type under test) -> 2 workers with random delays -> FORWARD to atomic queue1 -> sink checking per-flow order; prints flow->worker matrix, same-flow concurrency and out-of-order counts for ATOMIC, ORDERED, PARALLEL. Based on research/08-examples/event_sw_atomic.c.  
  Run here: `./event_sw_atomic -l 0-2 --no-pci --no-huge -m 128 --file-prefix=ch25-ev --vdev=event_sw0`
- **event_pipeline.c** — Two-stage pipeline with an eth Rx adapter on a net_ring/pcap port and eth Tx adapter; workers do stage 1 (classify) and stage 2 (MAC swap); service lcore runs event_sw and adapters; prints adapter stats. Registers a stop-flush callback so in-flight mbufs are freed at shutdown; run.sh queries /eventdev/queue_xstats via telemetry while it runs; a second mode enables Rx adapter event vectors. Maps each adapter's service explicitly to service lcore 3 (taught as a step) and calls rte_event_port_quiesce before stop.  
  Run here: `./event_pipeline -l 0-3 -S 3 --no-pci --no-huge -m 256 --file-prefix=ch25-pipe --vdev=event_sw0 --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=out.pcap`
- **event_timer_demo.c** — Timer adapter with 10 ms ticks; arm timers at 50/100/150 ms, cancel one, periodic flag; expiry events dequeued by a worker. Based on research/08-examples/event_timer_demo.c.  
  Run here: `./event_timer_demo -l 0-2 -S 2 --no-pci --no-huge -m 128 --file-prefix=ch25-tim --vdev=event_sw0`
- **dpdk-test-eventdev (prebuilt)** — order_queue and perf_queue tests on event_sw with a service core; captured Result lines and throughput.  
  Run here: `dpdk-test-eventdev -l 0-3 -S 3 --no-huge -m 256 --no-pci --file-prefix=ch25-t --vdev=event_sw0 -- --test=order_queue --plcores 1 --wlcores 2 --nb_flows 64 --nb_pkts 100000 ; strip ANSI colour codes with sed 's/\x1b\[[0-9;]*m//g' before saving expected_output.txt`

**Visualizations**

- **Eventdev scheduler** (interactive) — Producer, queues and worker ports with coloured flows; toggle ATOMIC/ORDERED/PARALLEL and replay the measured table (flow->worker matrix, collision counter, reorder counter at the sink); shows the atomic flow table and ordered reorder buffer.
- **Credits bucket** (animation) — Bucket of nb_events_limit tokens: NEW consumes, RELEASE returns; producers outrunning workers stall at new_event_threshold.
- **Adapters as bridges** (animation) — Rx adapter polling ethdev queues by weight into the eventdev, timer wheel ticking and firing, Tx adapter out; crypto and DMA adapters shown greyed as forward references to ch26/ch27.
- **Event vectors** (animation) — Many mbufs riding in one vector event: the Rx adapter fills a vector until size or timeout, one scheduling decision moves all of them; learner sets vector size and timeout and sees events/s vs latency.
- **Capability-driven code** (interactive) — The learner toggles capability bits (DISTRIBUTED_SCHED, MAINTENANCE_FREE, IMPLICIT_RELEASE_DISABLE, BURST_MODE); the worker loop skeleton on the right gains or loses the matching code (service launch, rte_event_maintain, explicit RELEASE, single-event enqueue).

**Exercises**

1. [easy] Add a third stage to event_pipeline that is ORDERED and verify output order with a pcap reader.
2. [medium] Disable implicit release and forget a RELEASE in atomic mode; observe the stall and explain it.
3. [medium] Use the timer adapter to implement per-flow idle timeouts.
4. [medium] Use link profiles to switch a worker port between two queue sets at runtime.

**Sources**

- doc/guides/prog_guide/eventdev/eventdev.rst
- doc/guides/prog_guide/eventdev/event_ethernet_rx_adapter.rst
- doc/guides/prog_guide/eventdev/event_ethernet_tx_adapter.rst
- doc/guides/prog_guide/eventdev/event_timer_adapter.rst
- doc/guides/prog_guide/eventdev/dispatcher_lib.rst
- doc/guides/eventdevs/sw.rst
- doc/guides/tools/testeventdev.rst
- lib/eventdev/rte_eventdev.h
- lib/eventdev/rte_event_eth_rx_adapter.h
- lib/eventdev/rte_event_timer_adapter.h
- lib/dispatcher/rte_dispatcher.h
- drivers/event/sw/sw_evdev_scheduler.c
- examples/eventdev_pipeline/
- examples/l2fwd-event/
- /home/user/ai_lab/dpdk_research/research/08-crypto-event-accel.md
- /home/user/ai_lab/dpdk_research/research/08-examples/event_sw_atomic.c
- lib/eventdev/rte_event_vector_adapter.h
- doc/guides/prog_guide/eventdev/event_vector_adapter.rst

## 26. Lookaside Crypto: cryptodev, rte_security and IPsec

*Folder:* `chapters/26-cryptodev-ipsec/` · *Level:* expert · *Prerequisites:* ch7, ch11, ch18, ch19, ch25

The lookaside accelerator pattern, learned in depth through cryptodev: device capabilities, queue pairs, op pools, sessions and transforms (cipher, auth, chained, AEAD), IV and digest placement, async enqueue/dequeue, asymmetric crypto read from the real capability structures (including the 26.11 rte_crypto_rsa_capa on OpenSSL 3.0.13), the crypto scheduler, raw data path and CPU crypto, rte_security, the IPsec library with SAD lookups and the ipsec-secgw structure, validation tools, and the eventdev crypto adapter at the end. ch27 reuses the same pattern for the other device classes.

**Concepts**

- The lookaside accelerator pattern shared by all device classes: discover -> configure -> qp setup -> session -> start -> enqueue/dequeue (async)
- Device discovery, feature flags, capabilities walking and checking (rte_cryptodev_sym_capability_get, check_cipher/auth/aead)
- Configuration: rte_cryptodev_configure, queue_pair_setup with session mempool, start
- Crypto op pools: rte_crypto_op_pool_create with private size for the IV; rte_crypto_op_ctod_offset IV convention
- Sessions (22.11+ API): rte_cryptodev_sym_session_pool_create, rte_cryptodev_sym_session_create(dev, xform, pool), free
- Transforms: cipher (AES-CBC/CTR), auth (SHA HMAC), chaining order (encrypt-then-MAC), AEAD (AES-GCM) with AAD and digest
- Data offsets/lengths, digest placement, in-place vs out-of-place (m_dst), op status codes (SUCCESS, AUTH_FAILED, ...)
- crypto_scheduler: round-robin, packet-size distribution, failover, multicore
- rte_security: action types NONE, INLINE_CRYPTO, INLINE_PROTOCOL, LOOKASIDE_PROTOCOL, CPU_CRYPTO; protocols IPsec/MACsec/PDCP/DOCSIS/TLS
- IPsec library: SA init, ESP tunnel/transport, sequence numbers and replay window; ipsec-secgw structure (SPD via ACL, SAD, routing via LPM)
- PDCP library overview
- Asymmetric crypto on crypto_openssl with OpenSSL 3.0.13 (crypto_caps.c prints struct rte_crypto_rsa_capa: modulus range in bytes, padding types, MGF1 hash algorithms, pss_explicit_salt / pss_salt support, so the limits are data the learner reads): runnable MODEX, MODINV, RSA (26.11 RSA capability parameters) and DH; EdDSA is listed but session creation returns ENOTSUP (needs OpenSSL >= 3.3); ML-KEM/ML-DSA need >= 3.5 and are not offered; the openssl PMD does not advertise ECDSA
- Raw data-path API (rte_cryptodev_configure_raw_dp_ctx, rte_cryptodev_raw_enqueue_burst), CPU crypto (rte_cryptodev_sym_cpu_crypto_process), enqueue/dequeue callbacks (rte_cryptodev_add_enq_callback)
- IPsec SAD: rte_ipsec_sad_create/add/lookup keyed by SPI(+DIP+SIP); rte_ipsec_pkt_crypto_group; rte_ipsec_session types inline vs lookaside; /ipsec/sa/* telemetry; MACsec (examples/l2fwd-macsec) and TLS record protocols as pointers
- Validation tools: dpdk-test-crypto-perf, dpdk-test-security-perf, dpdk-test-sad, fips_validation, wycheproof_validation (new). Built here: dpdk-test-crypto-perf (prebuilt) and dpdk-test-sad (built standalone from app/test-sad/main.c with -DALLOW_EXPERIMENTAL_API, verified); dpdk-test-security-perf, fips_validation and wycheproof_validation are not built here
- Crypto adapter (closing section of part 1): OP_NEW vs OP_FORWARD modes, internal port vs service

**APIs**

`rte_cryptodev_count`, `rte_cryptodev_get_dev_id`, `rte_cryptodev_info_get`, `rte_cryptodev_sym_capability_get`, `rte_cryptodev_sym_capability_check_cipher`, `rte_cryptodev_configure`, `rte_cryptodev_queue_pair_setup`, `rte_cryptodev_start`, `rte_crypto_op_pool_create`, `rte_crypto_op_alloc`, `rte_crypto_op_ctod_offset`, `rte_cryptodev_sym_session_pool_create`, `rte_cryptodev_sym_session_create`, `rte_cryptodev_sym_session_free`, `rte_crypto_op_attach_sym_session`, `rte_cryptodev_enqueue_burst`, `rte_cryptodev_dequeue_burst`, `struct rte_crypto_sym_xform`, `rte_cryptodev_asym_session_create`, `struct rte_crypto_asym_xform`, `rte_cryptodev_get_sec_ctx`, `rte_security_session_create`, `rte_security_capabilities_get`, `rte_ipsec_sa_size`, `rte_ipsec_sa_init`, `rte_ipsec_session_prepare`, `rte_ipsec_pkt_crypto_prepare`, `rte_ipsec_pkt_process`, `rte_cryptodev_configure_raw_dp_ctx`, `rte_cryptodev_sym_cpu_crypto_process`, `rte_cryptodev_add_enq_callback`, `rte_ipsec_sad_create`, `rte_ipsec_sad_add`, `rte_ipsec_sad_lookup`, `rte_ipsec_pkt_crypto_group`, `rte_event_crypto_adapter_create`, `rte_event_crypto_adapter_queue_pair_add`, `struct rte_crypto_rsa_capa`, `rte_cryptodev_asym_capability_get`

**Runnable code examples**

- **crypto_caps.c** — Lists crypto devices (crypto_null, crypto_openssl) with feature flags and walks all symmetric/asymmetric capabilities, printing algorithm names and key/digest sizes. Prints the asym capability list actually present (RSA, MODEX, MODINV, DH, DSA, ECFPM, SM2, EDDSA) and shows an EdDSA session failing on OpenSSL 3.0. For crypto_openssl RSA it prints rte_crypto_rsa_capa (modlen range, padding, MGF1 hashes, pss_explicit_salt).  
  Run here: `./crypto_caps -l 0 --no-pci --no-huge -m 128 --file-prefix=ch26-caps --vdev=crypto_null0 --vdev=crypto_openssl0`
- **aes_cbc_hmac.c** — AES-128-CBC + SHA1-HMAC chained session on crypto_openssl; encrypt a buffer in an mbuf and compare the ciphertext and digest against the openssl CLI output in run.sh. Based on research/08-examples/crypto_aes_cbc_sha.c.  
  Run here: `./aes_cbc_hmac -l 0 --no-pci --no-huge -m 128 --file-prefix=ch26-cbc --vdev=crypto_openssl0 ; openssl enc -aes-128-cbc ... for comparison`
- **aes_gcm.c** — AES-GCM AEAD encrypt then decrypt/verify; flip one ciphertext byte and get RTE_CRYPTO_OP_STATUS_AUTH_FAILED; shows IV/AAD/digest placement and partial enqueue handling.  
  Run here: `./aes_gcm -l 0 --no-pci --no-huge -m 128 --file-prefix=ch26-gcm --vdev=crypto_openssl0`
- **asym_modexp.c** — Modular exponentiation with the asym API on crypto_openssl, checked against Python pow(). Based on research/08-examples/crypto_asym_modexp.c.  
  Run here: `./asym_modexp -l 0 --no-pci --no-huge -m 128 --file-prefix=ch26-asym --vdev=crypto_openssl0`
- **perf + scheduler (prebuilt)** — dpdk-test-crypto-perf throughput sweep on crypto_openssl for buffer sizes 64..2048 (chart data), and crypto_scheduler round-robin over two crypto_null workers.  
  Run here: `dpdk-test-crypto-perf -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch26-perf --vdev=crypto_openssl0 -- --devtype crypto_openssl --optype cipher-then-auth --cipher-algo aes-cbc --cipher-key-sz 16 --cipher-iv-sz 16 --auth-algo sha1-hmac --auth-key-sz 64 --digest-sz 12 --buffer-sz 64,256,1024,2048 --total-ops 100000`
- **ipsec_sad.c** — Creates an IPsec SAD, adds SAs keyed by SPI, SPI+DIP and SPI+DIP+SIP, and looks up a batch of keys showing the most-specific match; prints sizes.  
  Run here: `./ipsec_sad -l 0 --no-pci --no-huge -m 128 --file-prefix=ch26-sad`
- **crypto_event_adapter.c** — Crypto adapter in OP_NEW mode on event_sw + crypto_null with a service lcore: ops enqueued to cryptodev, completions arrive as events on a worker. Based on the verified research check chk_event_crypto_adapter_new.  
  Run here: `./crypto_event_adapter -l 0-2 -S 2 --no-pci --no-huge -m 128 --file-prefix=ch26-cea --vdev=event_sw0 --vdev=crypto_null0`
- **dpdk-test-sad (built from app/test-sad)** — Built standalone like ch18's test-acl and run briefly next to ipsec_sad.c to compare SAD lookup rates.  
  Run here: `./dpdk-test-sad -l 0 --no-pci --no-huge -m 256 --file-prefix=ch26-tsad -- (author picks small -n/-t values from main.c usage; timeout 20 s)`

**Visualizations**

- **Order-ticket async model** (animation) — Ops slide from the lcore into a qp ring, the device 'kitchen' processes them, completions come back; enqueue accepts fewer when the ring is full; SW PMD finishes at enqueue vs HW later.
- **Session vs op** (interactive) — A session card (algorithm, keys, precomputed state) shared by many op cards (IV, offsets, mbuf); hover highlights which mbuf bytes cipher.data and auth.data cover and where the digest lands, using real bytes.
- **Xform chain builder** (interactive) — Drag CIPHER and AUTH blocks to build encrypt-then-MAC vs MAC-then-encrypt and see the data flow.
- **ESP packet growth** (animation) — Byte-accurate IPv4 packet becoming an ESP tunnel packet (new IP header, SPI, seq, IV, payload, padding, ICV).
- **rte_security action types** (diagram) — Lanes showing who does crypto and who does protocol processing (app/lib, NIC inline, lookaside accelerator) for each action type.
- **Throughput vs buffer size** (chart) — Measured test-crypto-perf numbers.
- **ipsec-secgw path** (diagram) — Outbound and inbound path of one packet: SPD lookup (ACL), SAD lookup, crypto prepare/process, routing (LPM), fragmentation; each box names its library and chapter.

**Exercises**

1. [easy] Add AES-CTR to crypto_caps checks and use it to encrypt a packet payload in place.
2. [medium] Make aes_gcm process a burst of 32 ops and handle partial enqueue correctly.
3. [medium] Run test-crypto-perf with the scheduler in pkt-size-distr mode and explain the result.
4. [medium] Add an SPI+DIP+SIP SA to ipsec_sad and show which SA wins for overlapping keys.
5. [stretch] Read rte_crypto_rsa_capa for crypto_openssl and write the RSA-PSS operation it allows; run it and capture the result or the error.

**Sources**

- doc/guides/prog_guide/cryptodev_lib.rst
- doc/guides/prog_guide/rte_security.rst
- doc/guides/prog_guide/ipsec_lib.rst
- doc/guides/prog_guide/pdcp_lib.rst
- doc/guides/cryptodevs/openssl.rst
- doc/guides/cryptodevs/null.rst
- doc/guides/cryptodevs/scheduler.rst
- doc/guides/tools/cryptoperf.rst
- doc/guides/sample_app_ug/ipsec_secgw.rst
- lib/cryptodev/rte_cryptodev.h
- lib/cryptodev/rte_crypto_sym.h
- lib/cryptodev/rte_crypto_asym.h
- lib/security/rte_security.h
- lib/ipsec/rte_ipsec.h
- lib/ipsec/rte_ipsec_sa.h
- drivers/crypto/openssl/
- examples/ipsec-secgw/
- examples/l2fwd-crypto/
- /home/user/ai_lab/dpdk_research/research/08-crypto-event-accel.md
- /home/user/ai_lab/dpdk_research/research/08-examples/crypto_aes_cbc_sha.c
- /home/user/ai_lab/dpdk_research/research/08-examples/crypto_asym_modexp.c
- /home/user/ai_lab/dpdk_research/research/08-examples/
- lib/ipsec/rte_ipsec_sad.h
- doc/guides/prog_guide/eventdev/event_crypto_adapter.rst
- drivers/crypto/openssl/rte_openssl_pmd_ops.c (OpenSSL version guards)
- app/test-sad/
- app/wycheproof_validation/
- app/fips_validation/
- examples/l2fwd-macsec/

## 27. Other Lookaside Accelerators: compressdev, dmadev and the DMA Adapter, bbdev, mldev/gpudev/regexdev and rawdev

*Folder:* `chapters/27-other-accelerators/` · *Level:* expert · *Prerequisites:* ch7, ch11, ch25, ch26

The lookaside pattern from ch26 applied to the other device classes, revisiting the same order-ticket animation: compressdev (stateless and stateful DEFLATE on compress_zlib), dmadev in its two programming models with burst capacity, transfer directions and drain-before-stop, the eventdev DMA adapter, bbdev on baseband_null, the device classes that have no software driver in 26.11 (gpudev, mldev, regexdev; ml quantize works without a device), and rawdev.

**Concepts**

- The pattern revisited: discover -> configure -> queue setup -> per-op object -> enqueue/dequeue, with the ch26 order-ticket animation re-labelled per class
- Comparing device classes: unit of work, session-like object, software driver available here
- compressdev: device/qp config, private_xform (stateless) vs stream (stateful), rte_comp_op fields, OUT_OF_SPACE_TERMINATED/RECOVERABLE, checksums, levels
- dmadev two programming models: ring_idx + rte_dma_copy/fill/copy_sg + submit + completed/completed_status vs ops-based rte_dma_enqueue_ops/rte_dma_dequeue_ops (RTE_DMA_CAPA_OPS_ENQ_DEQ / RTE_DMA_CFG_FLAG_ENQ_DEQ; submit/completed invalid then); fences, rte_dma_burst_capacity, vchan priorities, silent mode, stats; check skeleton support with rte_dma_info_get
- dmadev beyond mem-to-mem: transfer directions (RTE_DMA_DIR_MEM_TO_MEM / MEM_TO_DEV / DEV_TO_MEM / DEV_TO_DEV) with struct rte_dma_port_param for the device side; access pair groups for inter-process/inter-domain DMA (rte_dma_access_pair_group_create/join/leave/destroy/handler_get; concept only, the skeleton cannot do it); rte_dma_vchan_status to drain before rte_dma_stop; rte_dma_stats_get/reset
- DMA adapter for eventdev; dpdk-dma sample; IOVA addresses for DMA
- bbdev: LDPC/turbo encode/decode, FFT ops, queues per op type, rte_bbdev_queue_stats_get (26.11); baseband_null loopback
- gpudev, mldev, regexdev: no software driver exists in 26.11, so counts are 0 here; API concepts only, except mldev's rte_ml_io_float32_to_int8 quantization helpers which work without a device (saturate at 127)
- rawdev: generic container; rawdev_skeleton selftest

**APIs**

`rte_compressdev_count`, `rte_compressdev_info_get`, `rte_compressdev_configure`, `rte_compressdev_queue_pair_setup`, `rte_compressdev_start`, `rte_compressdev_private_xform_create`, `rte_compressdev_stream_create`, `rte_comp_op_pool_create`, `rte_compressdev_enqueue_burst`, `rte_compressdev_dequeue_burst`, `rte_dma_count_avail`, `rte_dma_info_get`, `rte_dma_configure`, `rte_dma_vchan_setup`, `rte_dma_start`, `rte_dma_copy`, `rte_dma_fill`, `rte_dma_submit`, `rte_dma_completed`, `rte_dma_completed_status`, `rte_dma_stats_get`, `rte_dma_dump`, `rte_bbdev_count`, `rte_bbdev_info_get`, `rte_bbdev_setup_queues`, `rte_bbdev_queue_configure`, `rte_bbdev_enqueue_enc_ops`, `rte_gpu_count_avail`, `rte_gpu_mem_alloc`, `rte_ml_dev_count`, `rte_regexdev_count`, `rte_rawdev_count`, `rte_rawdev_selftest`, `rte_ml_io_float32_to_int8`, `rte_dma_copy_sg`, `rte_dma_burst_capacity`, `rte_dma_enqueue_ops`, `rte_dma_dequeue_ops`, `rte_event_dma_adapter_create`, `rte_bbdev_queue_stats_get`, `rte_dma_vchan_status`, `rte_dma_stats_reset`, `struct rte_dma_port_param`, `rte_dma_access_pair_group_create`

**Runnable code examples**

- **comp_roundtrip.c** — Stateless DEFLATE compress then decompress of a text buffer on compress_zlib for levels 1..9; prints ratio and verifies bytes; demonstrates OUT_OF_SPACE with a too-small destination. Based on research/08-examples/comp_zlib_roundtrip.c.  
  Run here: `./comp_roundtrip -l 0 --no-pci --no-huge -m 128 --file-prefix=ch27-comp --vdev=compress_zlib0`
- **dma_copy.c** — dma_skeleton device: copy, fill and a fenced sequence; enqueue without submit shows nothing completes; then submit and poll completions with ring_idx bookkeeping and completed_status. Based on research/08-examples/dma_skeleton_copy.c. Adds rte_dma_burst_capacity and reports whether the skeleton supports the ops-based enqueue/dequeue model (rte_dma_info_get capa). Polls rte_dma_vchan_status until idle before stop, resets stats, and compares ops/s with rte_memcpy and memcpy for the same sizes (median of 5).  
  Run here: `./dma_copy -l 0-1 --no-pci --no-huge -m 128 --file-prefix=ch27-dma --vdev=dma_skeleton0,lcore=1`
- **bbdev_null.c** — baseband_null lifecycle: info, setup queues, configure, start, enqueue/dequeue NONE ops in loopback, stats. Based on research/08-examples/bbdev_null_loopback.c. Adds rte_bbdev_queue_stats_get.  
  Run here: `./bbdev_null -l 0 --no-pci --no-huge -m 128 --file-prefix=ch27-bb --vdev=baseband_null0`
- **rawdev_selftest + device census** — Runs rawdev_skeleton selftest and a 'census' program that prints the count of every device class (ethdev, cryptodev, compressdev, dmadev, eventdev, bbdev, gpudev, mldev, regexdev, rawdev) with the vdevs present. mldev, gpudev and regexdev report 0 because no software driver exists in 26.11 (there is no 'ml null' driver).  
  Run here: `./census -l 0 --no-pci --no-huge -m 128 --file-prefix=ch27-census --vdev=crypto_null0 --vdev=compress_zlib0 --vdev=dma_skeleton0 --vdev=event_sw0 --vdev=baseband_null0 --vdev=rawdev_skeleton0,selftest=1 --vdev=net_null0`
- **ml_quantize.c** — Uses mldev's rte_ml_io_float32_to_int8 without any ML device (verified: scale 0.05 maps {0.5,-1,2,100} to {10,-20,40,127}); explains saturation at 127 and the reverse helper.  
  Run here: `./ml_quantize -l 0 --no-pci --no-huge -m 64 --file-prefix=ch27-ml`
- **test-dma-perf / test-compress-perf (try once)** — Both are multi-file apps in app/; the author tries once to build each standalone (gcc app/<tool>/*.c with -DALLOW_EXPERIMENTAL_API and the pkg-config static flags) and either runs it briefly (test-dma-perf with a small config.ini on dma_skeleton; test-compress-perf on compress_zlib) or captures the build error and marks the tool 'not built here'.  
  Run here: `./build_tools.sh then the tool with prefix ch27-tool (timeout 20 s)`

**Visualizations**

- **Order-ticket async model** (animation) — Ops slide from the lcore into a qp ring, the device 'kitchen' processes them, completions come back; enqueue accepts fewer when the ring is full; SW PMD finishes at enqueue vs HW later.
- **Device-class comparison** (interactive) — Table/diagram of device classes: hover to see unit of work, session object, enqueue/dequeue names and the software driver here.
- **DMA rings with doorbell** (interactive) — Skeleton's four internal rings (empty, pending, running, completed) with ring_idx counters; buttons for enqueue, submit (doorbell), fence; completion returns last_idx and errors.
- **DEFLATE stream** (animation) — Sliding 32 KB window and Huffman blocks; consumed/produced counters; stateless vs stateful chunks carrying history.

**Exercises**

1. [easy] Add a second vchan to dma_copy and drain both with rte_dma_vchan_status before stopping.
2. [stretch] Compress a pcap file's payloads with stateful streams and compare ratio with stateless.
3. [medium] Use dmadev to copy packet payloads into a second buffer and measure ops/s vs rte_memcpy and memcpy.
4. [stretch] Explain what the DMA adapter in eventdev adds compared with polling completions.

**Sources**

- doc/guides/prog_guide/compressdev.rst
- doc/guides/prog_guide/dmadev.rst
- doc/guides/prog_guide/bbdev.rst
- doc/guides/prog_guide/gpudev.rst
- doc/guides/prog_guide/mldev.rst
- doc/guides/prog_guide/regexdev.rst
- doc/guides/prog_guide/rawdev.rst
- doc/guides/compressdevs/zlib.rst
- doc/guides/dmadevs/
- doc/guides/sample_app_ug/dma.rst
- lib/compressdev/rte_compressdev.h
- lib/compressdev/rte_comp.h
- lib/dmadev/rte_dmadev.h
- lib/bbdev/rte_bbdev.h
- lib/gpudev/rte_gpudev.h
- lib/mldev/rte_mldev.h
- lib/regexdev/rte_regexdev.h
- lib/rawdev/rte_rawdev.h
- drivers/dma/skeleton/
- doc/guides/prog_guide/eventdev/event_dma_adapter.rst

## 28. Programmable Data Planes: graph/node, BPF and the SWX Pipeline

*Folder:* `chapters/28-graph-bpf-swx/` · *Level:* expert · *Prerequisites:* ch14, ch15, ch18, ch19

Three ways to compose or program a data plane without hand-writing one big loop: the graph library (packet-processing nodes with burst-wise edges, inbuilt ethdev/IP nodes, l3fwd-graph, dispatch model, feature arcs), eBPF programs executed or JIT-compiled on ethdev queues, and the P4-like SWX pipeline (spec file, tables, actions, externs, CLI). Notes that the legacy packet framework was removed in 26.11.

**Concepts**

- Graph library: nodes (process function, next edges, init/fini), RTE_NODE_REGISTER, source nodes, rte_graph_create from node patterns, rte_graph_walk
- Enqueue APIs: rte_node_enqueue, enqueue_x1/x2/x4, rte_node_next_stream_get/put/move (home-run optimisation)
- Graph objects and stats: rte_graph_cluster_stats, rte_graph_export (dot); the 26.11 scheduler walks a topological-order pending bitmap instead of a circular buffer, so fan-out-then-converge nodes are visited once per walk; graph profiling with RTE_GRAPH_PROFILE and the RTE_GRAPH_PROFILE_BURST_* buckets (rte_config.h); graph pcap capture (rte_graph_param pcap_enable, lib/graph/graph_pcap.c)
- Models: run-to-completion vs mcore dispatch (rte_graph_worker_model_set / rte_graph_worker_model_get, rte_graph_model_mcore_dispatch_core_bind, rte_graph_clone); feature arcs (25.07) for runtime-enabled features; app/graph (dpdk-graph) as a configurable graph application
- Inbuilt nodes (lib/node): ethdev_rx/tx, pkt_cls, ip4_lookup (LPM), ip4_lookup_fib, ip4_rewrite, ip4_reassembly, kernel_rx/tx, pkt_drop; l3fwd-graph sample
- BPF: eBPF ISA basics, rte_bpf_load_ex origins (raw instructions, cBPF, ELF), verifier, JIT on x86, rte_bpf_exec / exec_burst, rte_bpf_eth_rx_install/tx_install, rte_bpf_convert from pcap filters, testpmd bpf-load; building BPF objects from examples/bpf/t1.c with clang -target bpf; dpdk-validate-bpf (new tool) to check programs offline
- SWX pipeline: spec language (structs, headers, metadata, actions, tables exact/wildcard/LPM, learner, selector, apply block), externs (meters, register arrays), ports (ethdev, ring, source/sink pcap); build flow spec -> rte_swx_pipeline_codegen (C file) -> gcc -> .so -> rte_swx_pipeline_build_from_lib, which is why dpdk-pipeline needs RTE_INSTALL_DIR and a compiler at runtime; the dpdk-pipeline CLI ('pipeline codegen' / 'pipeline build')
- Removed in 26.11, so do not follow old tutorials: the legacy rte_pipeline_* / rte_table_* / rte_port_* API, the rte_table_action API, the ip_pipeline example and the dpdk-test-pipeline app. What remains: lib/port rte_swx_port_*, lib/table rte_swx_table_em/wm/learner/selector, lib/pipeline rte_swx_*, and examples/pipeline (the SWX replacement)
- softnic (drivers/net/softnic): an ethdev whose datapath is an SWX pipeline driven by a firmware.cli — 'an SWX pipeline exposed as a port'; not built here, reading pointer only
- BPF toolchain as verified here: clang -O2 -target bpf -D__x86_64__ -I/usr/include/x86_64-linux-gnu -c examples/bpf/t1.c (without the extra flags clang fails on gnu/stubs-32.h); dpdk-validate-bpf is built from app/validate-bpf; its default --prog-arg ('struct rte_mbuf *') rejects t1.o with 'mbuf access with variable offset at pc: 17', and --prog-arg='struct udp_headers *' gives 'Validation succeeded.'
- app/graph (dpdk-graph) with examples/l2fwd_pcap.cli fails here with 'rte_node_eth_config: err=-22'; lib/node/ethdev_ctrl.c returns EINVAL for an invalid port, mbuf priv size < NODE_MBUF_PRIV2_SIZE or txq < nb_graphs; the author debugs it against that file once, otherwise presents dpdk-graph as reading only with the captured error

**APIs**

`RTE_NODE_REGISTER`, `struct rte_node_register`, `rte_node_from_name`, `rte_graph_create`, `rte_graph_lookup`, `rte_graph_walk`, `rte_graph_export`, `rte_graph_destroy`, `rte_node_enqueue_x1`, `rte_node_next_stream_move`, `rte_graph_cluster_stats_create`, `rte_graph_cluster_stats_get`, `rte_node_eth_config`, `rte_bpf_load_ex`, `struct rte_bpf_prm_ex`, `rte_bpf_exec`, `rte_bpf_exec_burst`, `rte_bpf_get_jit`, `rte_bpf_eth_rx_install`, `rte_bpf_convert`, `rte_bpf_destroy`, `rte_swx_pipeline_config`, `dpdk-pipeline CLI`, `rte_graph_worker_model_set`, `rte_graph_worker_model_get`, `rte_graph_model_mcore_dispatch_core_bind`, `rte_graph_clone`, `rte_swx_pipeline_codegen`, `rte_swx_pipeline_build_from_lib`, `rte_swx_port_*`, `rte_swx_table_*`

**Runnable code examples**

- **graph_mini.c** — Custom source node generating packets -> classifier node -> two worker nodes -> sink; per-object enqueue vs stream move; prints cluster stats and exports a .dot file rendered as SVG in the chapter. Based on research/07-examples/graph_mini.c.  
  Run here: `./graph_mini -l 0 --no-pci --no-huge -m 128 --file-prefix=ch28-graph`
- **l3fwd-graph (prebuilt)** — Run dpdk-l3fwd-graph on two pcap ports (two tx_pcap= per port for 2 TX queues), strip the screen-clear codes from its node stats table, and verify outputs with pcap_summary.py.  
  Run here: `$DPDK_SRC/build/examples/dpdk-l3fwd-graph -l 0,1 --no-pci --no-huge -m 640 --file-prefix=ch28-l3g --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=o0.pcap,tx_pcap=o0b.pcap --vdev=net_pcap1,rx_pcap=in.pcap,tx_pcap=o1.pcap,tx_pcap=o1b.pcap -- -p 0x3 --config='(0,0,1),(1,0,1)'`
- **bpf_filter.c** — Hand-assembled eBPF program (struct ebpf_insn array) that drops UDP packets to port 2001, loaded with rte_bpf_load_ex, run with rte_bpf_exec_burst on packets from a pcap, interpreter vs JIT counts and timing; and rte_bpf_convert of a pcap filter string (libpcap is linked: RTE_HAS_LIBPCAP=1), unconditionally.  
  Run here: `./bpf_filter -l 0 --no-pci --no-huge -m 128 --file-prefix=ch28-bpf --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=/dev/null`
- **t1.o via clang + dpdk-validate-bpf + testpmd bpf-load** — Builds dpdk-validate-bpf (gcc -O2 -DALLOW_EXPERIMENTAL_API -DALLOW_INTERNAL_API -I$DPDK_SRC/lib/bpf $DPDK_SRC/app/validate-bpf/*.c + pkg-config static), compiles t1.c with the verified clang flags, captures the failing default-arg validation as a teaching moment, validates with --prog-arg='struct udp_headers *', then loads it into testpmd with a --cmdline-file containing 'bpf-load rx 0 0 J ./t1.o' (verified).  
  Run here: `clang -O2 -target bpf -D__x86_64__ -I/usr/include/x86_64-linux-gnu -c $DPDK_SRC/examples/bpf/t1.c -o t1.o ; ./dpdk-validate-bpf t1.o (captured failure) ; ./dpdk-validate-bpf --prog-arg='struct udp_headers *' t1.o ; timeout -s INT -k 5 10 dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch28-bpf --vdev=net_null0 -- --total-num-mbufs=8192 --cmdline-file=bpf.cmd --stats-period 1`
- **SWX l2fwd** — SWX pipeline spec with pcap source/sink ports run by dpdk-pipeline; spec, CLI and IO files explained line by line. Based on research/07-examples/swx/. The walkthrough shows the codegen -> gcc -> build_from_lib steps that dpdk-pipeline performs (generated .c and .so are kept and listed). The research .cli hard-codes scratchpad .so paths and ./swx/ relative paths; the chapter copy rewrites them to chapter-local paths.  
  Run here: `RTE_INSTALL_DIR=$DPDK_SRC $DPDK_SRC/build/examples/dpdk-pipeline -l 0,1 --no-huge -m 256 --no-pci --file-prefix=ch28-swx -- -s l2fwd_pcap.cli (verified)`
- **dpdk-graph attempt** — Runs the built dpdk-graph with a chapter-local copy of examples/l2fwd_pcap.cli; if it still fails after checking lib/node/ethdev_ctrl.c's conditions, the captured 'rte_node_eth_config: err=-22' is the expected output.  
  Run here: `timeout -s INT -k 5 15 dpdk-graph -l 0-1 --no-pci --no-huge -m 640 --file-prefix=ch28-dg -- -s l2fwd_pcap.cli`

**Visualizations**

- **Graph walk** (animation) — Node DAG with bursts as dots; pending bitmap scanned in topological order; home-run (stream move) vs per-object copy counter; RTC vs dispatch model on lcores.
- **eBPF stepper** (interactive) — Registers, instruction pointer and a packet buffer; step through the filter program instruction by instruction; verifier range annotations.
- **SWX pipeline structure** (diagram) — Ports -> parser -> tables (em/wm/lpm/learner) -> actions -> deparser -> ports, generated from the spec.
- **Exported graph** (diagram) — The real .dot exported by graph_mini, drawn as SVG.
- **Packet thread interleaving** (animation) — SWX packet threads yielding at table lookups to hide memory latency (Gantt chart).
- **Old vs new graph walk** (animation) — A fan-out-then-converge graph: the old circular-buffer walk visits the converge node twice, the 26.11 topological bitmap walk once; the learner steps both and counts node visits.

**Exercises**

1. [easy] Add a node to graph_mini that counts packets per class and expose its stats.
2. [medium] Change bpf_filter to drop packets whose IPv4 TTL is below 5.
3. [medium] Add an exact-match table to the SWX spec that rewrites the destination MAC per input port.
4. [stretch] Compare l3fwd and l3fwd-graph outputs for packets to disabled ports and explain the difference.

**Sources**

- doc/guides/prog_guide/graph_lib.rst
- doc/guides/prog_guide/bpf_lib.rst
- doc/guides/prog_guide/packet_framework.rst
- doc/guides/sample_app_ug/l3_forward_graph.rst
- doc/guides/sample_app_ug/pipeline.rst
- doc/guides/rel_notes/release_26_11.rst (removed items)
- lib/graph/rte_graph.h
- lib/graph/rte_graph_worker.h
- lib/graph/rte_graph_model_rtc.h
- lib/graph/rte_graph_feature_arc.h
- lib/node/
- lib/bpf/rte_bpf.h
- lib/bpf/rte_bpf_ethdev.h
- lib/pipeline/rte_swx_pipeline.h
- examples/l3fwd-graph/main.c
- examples/pipeline/
- /home/user/ai_lab/dpdk_research/research/07-packet-processing-libs.md
- /home/user/ai_lab/dpdk_research/research/07-examples/graph_mini.c
- /home/user/ai_lab/dpdk_research/research/07-examples/swx/
- lib/graph/rte_graph_worker_common.h
- lib/graph/graph_pcap.c
- config/rte_config.h (RTE_GRAPH_PROFILE)
- app/graph/
- doc/guides/tools/graph.rst
- app/validate-bpf/
- examples/bpf/t1.c
- examples/pipeline/cli.c
- lib/node/ethdev_ctrl.c
- drivers/net/softnic/
- doc/guides/rel_notes/release_26_11.rst (removed legacy pipeline)

## 29. Running DPDK in Production: System Setup, Containers, Hardening, Testing, Releases and Contributing

*Folder:* `chapters/29-production-operations/` · *Level:* expert · *Prerequisites:* ch4, ch10, ch12, ch13, ch16, ch22, ch23

What a network engineer has to get right on day one and keep right afterwards. System preparation (CPU layout, hugepages including 1 GB pages and persistent configuration, the kernel command line, BIOS and platform checklists, VFIO permissions), running as a non-root user, systemd units and stale-file cleanup, containers and Kubernetes, hardening (threat model, socket and runtime-dir permissions, untrusted-packet parsing and fuzzing, the vulnerability process), testing your own application in CI with golden pcaps, living with releases and ABI, how DPDK itself is tested and how to contribute, and an atlas of every sample application and tool. Also: a golden-signals monitoring runbook, DPDK in VMs and clouds, a restart budget, and a permission-path explorer. This machine has no systemd as PID 1 and no Docker daemon, so units and container files are linted or shown as text and isolation is demonstrated with unshare.

**Concepts**

- Reading the machine: usertools/cpu_layout.py, dpdk-hugepages.py -s, NUMA and NIC locality
- Startup failures: links the consolidated startup-error table (ch4, ch8, ch13, ch16) as the first thing to check on a new host
- Kernel command line and each parameter: default_hugepagesz=1G hugepagesz=1G hugepages=N, isolcpus, nohz_full, rcu_nocbs, irqaffinity, iommu=pt, intel_iommu=on; persistent hugepage configuration; tuned/irqbalance; BIOS settings (C-states, turbo, SNC) from nic_perf_intel_platform.rst / amd_platform.rst
- dpdk-devbind.py --status walkthrough: the active device warning, why eth0 is never bound, vfio-pci vs bifurcated drivers
- Permissions: VFIO groups/devices, `ulimit -l` (locked memory), a dedicated hugetlbfs mount owned by the service user, running as non-root (linux_gsg/enable_func.rst) with --in-memory
- Service management: a systemd unit, restart policy, a pre-start script removing stale /run/dpdk/<prefix> and /dev/hugepages/<prefix>map_* files. No systemd here: the unit is linted offline with 'systemd-analyze verify' (or the error is captured); LimitCORE= and systemd-coredump box links ch13's post-mortem lab
- Containers and Kubernetes: hugepage mounts, SR-IOV device plugin, --in-memory, the AF_XDP device plugin/CNI and use_cni, CPU manager static policy (text and diagrams; no runtime here). No Docker daemon here: the same isolation is shown with 'unshare -m -n -p --fork' plus a private hugetlbfs mount or --in-memory; the Dockerfile and Kubernetes YAML are text only
- Golden signals runbook: signal -> telemetry endpoint or xstat -> rate formula -> alert threshold -> first diagnostic step: imissed rate (core too slow or ring too small), rx_nombuf (pool undersized or leaking), oerrors / tx retry rate (next hop slow), mempool in_use creeping (leak), /eal/lcore/usage busy ratio vs top's 100%, link down; turning cumulative counters into rates; each alert tied to ch12's failure-signature board
- DPDK in a VM and the cloud: vIOMMU vs vfio-pci enable_unsafe_noiommu_mode (and its security cost), virtio vs SR-IOV VF vs vendor cloud PMDs (ENA, gve, netvsc/mana with failsafe), the PF-side 'ip link set <pf> vf N trust on / spoofchk / vlan / mtu' commands (text), a VF gotcha checklist, limited RSS and rte_flow on cloud NICs; this VM's own virtio NIC read without binding
- Threat model: NIC DMA (IOMMU as the isolation boundary; UIO/no-IOMMU are unsafe), other processes (any secondary can corrupt shared memory; runtime-dir permissions), VM guests via vhost-user (validate descriptors), memif secrets, telemetry socket exposure, malicious packets; control-plane policing (CoPP) row: rate-limit punted traffic per class so a flood cannot stall the fast path (implemented in ch30 stage 3)
- Parsing untrusted packets: bounds checks, chained mbufs, lying length fields, IHL/options abuse; fuzzing a parser with libFuzzer/ASan without EAL
- Vulnerability process (contributing/vulnerability.rst), howto/security.rst, tracking the LTS stable branch for CVE fixes
- Testing your own app in CI: run it over net_pcap with --no-huge/--in-memory, compare output with a golden pcap, ASan/UBSan builds, a CI YAML (text)
- Testing DPDK itself: dpdk-test (REGISTER_*_TEST, unit_test_suite_runner), meson test suites, DTS. dpdk-test is not built here (tests=false): reading walkthrough of app/test (REGISTER_FAST_TEST, unit_test_suite_runner) only
- Restart budget: rte_eal_init and port start time vs -m (measured here at 16/32/64 MB on hugepages and --no-huge, median of 5, clearly labelled as small-scale), what changes with 1 GB pages, --huge-unlink, --legacy-mem and prefaulting; a minimal-downtime upgrade playbook (drain via RSS/rte_flow or a bonding member, start the new instance with a new --file-prefix, switch, stop the old) linked to the upgrade checklist
- Living with releases: LTS (.11) vs latest, stable branches, reading rel_notes 'API Changes'/'ABI Changes' and deprecation.rst, sonames and the pmds-ABI dir (readelf -d / objdump -p), an upgrade checklist with golden-pcap and performance baselines
- Contributing: mailing-list patch workflow, devtools/checkpatches.sh, MAINTAINERS, Fixes/Cc stable tags, CI, ABI/API policy (__rte_experimental, __rte_internal, symbol versioning), coding style
- Real deployments and what they use from this course: OVS-DPDK (representors, rte_flow offload), VPP (graph-like nodes, linux-cp), SPDK, TRex, cloud PMDs
- Sample-app and tools atlas: every examples/ and app/ program and usertools script -> chapter -> runnable here (yes/no and why); the atlas marks examples that are not built here (46 example binaries are built; e.g. l2fwd-cat is not), and prebuilt examples are called as $DPDK_SRC/build/examples/dpdk-<name>

**APIs**

`rte_eal_init (--in-memory, --huge-dir, --file-prefix)`, `rte_eal_cleanup`, `rte_version`, `RTE_VERSION_NUM`, `__rte_experimental`, `__rte_internal`, `RTE_EXPORT_SYMBOL (symbol export macros)`, `rte_net_get_ptype`, `rte_pktmbuf_read`

**Runnable code examples**

- **sysprep.sh** — Read-only system report: cpu_layout.py, dpdk-hugepages.py -s, /proc/cmdline, IOMMU groups, ulimit -l, devbind --status; then prints a recommended kernel command line for this machine with an explanation of each parameter (nothing is changed).  
  Run here: `./sysprep.sh > sysprep.txt`
- **nonroot.sh** — Creates a temporary user and a private hugetlbfs mount owned by it (or uses --in-memory/--no-huge), runs hello_dpdk as that user via setpriv/runuser, captures the real permission errors first and then the working configuration; removes the user and mount afterwards.  
  Run here: `sudo-free: run as root, setpriv --reuid=<uid> ./hello_dpdk -l 0 --no-pci --in-memory -m 64 ... (author verifies; capture errors verbatim)`
- **dpdk-app.service + prestart.sh** — A sample systemd unit (text, not installed) with CPUAffinity, LimitMEMLOCK, Restart=on-failure, and a pre-start script that safely removes stale runtime files for its prefix; the script is tested against leftovers created by a SIGKILLed program. The unit is checked with 'systemd-analyze verify dpdk-app.service' (offline lint; if it needs a running systemd the error is captured).  
  Run here: `./prestart.sh ch29-svc after `timeout -s KILL 3 ./hello_dpdk ... --file-prefix=ch29-svc -m 32``
- **fuzz_parse.c** — Fuzz harness for the ch10 parser exposed as LLVMFuzzerTestOneInput. The primary path is a small main() that replays corpus/ and then runs N random mutations (byte flips, truncations, IHL/length tampering) through the same function, built with gcc -g -O1 -fsanitize=address,undefined (gcc ASan verified to report a heap-buffer-overflow here on a seeded bug). The libFuzzer command is shown as text together with the real link error ('libclang_rt.asan-x86_64.a: No such file'), captured in expected_output.txt, because the clang sanitizer runtimes are not installed.  
  Run here: `gcc -g -O1 -fsanitize=address,undefined fuzz_parse.c replay_main.c $(pkg-config --cflags libdpdk) -o fuzz_replay $(pkg-config --libs --static libdpdk) && timeout 20 ./fuzz_replay corpus/ 20000 ; BUG=1 variant shows the ASan report ; clang -fsanitize=fuzzer,address ... (captured link error)`
- **golden_pcap_test.sh** — CI-style regression test: runs ch10's mini_l2fwd (or the capstone responder) over net_pcap with an input pcap and --no-huge, diffs the output headers against a golden file with pcap_summary.py, and shows the test failing when a deliberate bug is introduced; ci.yml given as text.  
  Run here: `./golden_pcap_test.sh ; BUG=1 ./golden_pcap_test.sh (expected to fail)`
- **abi_inspect.sh + perms.sh** — readelf -d / objdump -p on the shared DPDK libraries to show sonames and the pmds directory; ls -l of /run/dpdk/<prefix> and the telemetry socket of a running app, then the same with a restrictive umask and group.  
  Run here: `./abi_inspect.sh ; ./perms.sh (prefix ch29-perm)`
- **atlas.py** — Generates the sample-app and tools atlas: lists examples/, app/ and usertools/, maps each to its chapter from a table, and marks runnable-here status (with the reason when not).  
  Run here: `python3 -I atlas.py $DPDK_SRC > atlas.json`
- **container_unshare.sh** — Shows container-style isolation without Docker: unshare -m -n -p --fork with a private hugetlbfs mount (size=64M) and --huge-dir, and a second run with --in-memory; prints what the process can see (/dev/hugepages, /run/dpdk, network interfaces).  
  Run here: `./container_unshare.sh (prefix ch29-ctr, timeout 10 s; trap unmounts)`
- **rates.py + alerts.yaml** — Polls dpdk-telemetry twice (1 s apart) against ch13's telemetry_app running with a seeded fault (a small pool so rx_nombuf climbs) and prints per-second deltas with the alert that would fire; alerts.yaml is an example Prometheus rule file (text) using dpdk-telemetry-exporter metric names.  
  Run here: `./telemetry_app ... --file-prefix=ch29-mon & ; python3 -I rates.py ch29-mon`
- **vm_probe.sh** — Read-only: IOMMU groups (/sys/kernel/iommu_groups), the vfio noiommu module parameter, eth0's driver and features via ethtool -i/-k, and dpdk-devbind.py --status; never binds anything.  
  Run here: `./vm_probe.sh (read-only)`
- **restart_budget.sh** — Measures rte_eal_init + port start time for hello_dpdk at -m 16/32/64 with hugepages and with --no-huge (median of 5, min/max), cleaning hugepage files after each run.  
  Run here: `./restart_budget.sh (prefixes ch29-rb-*, each run timeout 10 s)`

**Visualizations**

- **Kernel command-line builder** (interactive) — Learner picks CPUs to isolate, hugepage size and count, IOMMU mode; the widget builds the command line, explains each parameter and flags conflicts (e.g. isolating CPU 0, too many hugepages for RAM).
- **Threat model** (diagram) — NIC DMA, other DPDK processes, VM guests via vhost-user, containers via memif, the network, and local users of the telemetry socket, each with its boundary and mitigation.
- **Release timeline** (interactive) — Releases from 20.11 to 26.11 with LTS support windows; selecting a release shows its support end and the upgrade checklist steps.
- **Fuzzing loop** (animation) — Corpus -> mutate -> parse -> coverage feedback -> new corpus entry; a crash input is minimised and becomes a regression test.
- **Sample-app atlas** (interactive) — Filterable table of every example, app and usertool by chapter, device class and runnable-here status (from atlas.json).
- **Container layout** (diagram) — Pod with hugepage volume, SR-IOV VF or AF_XDP socket, pinned CPUs and the /run/dpdk directory, vs the same on bare metal.
- **Permission path explorer** (interactive) — The learner toggles user, group membership, capabilities, hugetlbfs mount owner and runtime-dir mode; the widget shows which EAL init step fails first (hugetlbfs file, /dev/vfio/N, /run/dpdk/<prefix> socket, locked-memory limit) with the real error text captured by nonroot.sh.

**Exercises**

1. [easy] Write the kernel command line for a 16-core, 2-socket server dedicating cores 2-7 of socket 0 to DPDK with 8 x 1 GB pages, and justify each parameter.
2. [medium] Make golden_pcap_test.sh part of a CI job for the capstone responder and break it with a checksum bug.
3. [medium] Extend the fuzz corpus with a VLAN-in-VLAN frame and an IPv6 extension-header chain; fix any crash found.
4. [stretch] Write a patch-style commit message (with Fixes: and Cc: stable tags) for a hypothetical bug fix in a DPDK library, following patches.rst.

**Sources**

- doc/guides/linux_gsg/sys_reqs.rst
- doc/guides/linux_gsg/enable_func.rst
- doc/guides/linux_gsg/linux_drivers.rst
- doc/guides/linux_gsg/nic_perf_intel_platform.rst
- doc/guides/linux_gsg/amd_platform.rst
- doc/guides/howto/security.rst
- doc/guides/contributing/vulnerability.rst
- doc/guides/contributing/patches.rst
- doc/guides/contributing/abi_policy.rst
- doc/guides/contributing/abi_versioning.rst
- doc/guides/contributing/stable.rst
- doc/guides/contributing/coding_style.rst
- doc/guides/contributing/unit_test.rst
- doc/guides/prog_guide/meson_ut.rst
- doc/guides/tools/dts.rst
- doc/guides/rel_notes/deprecation.rst
- doc/guides/howto/af_xdp_dp.rst
- doc/guides/nics/af_xdp.rst (use_cni)
- usertools/cpu_layout.py
- usertools/dpdk-hugepages.py
- usertools/dpdk-devbind.py
- lib/eal/include/rte_compat.h
- MAINTAINERS
- devtools/checkpatches.sh
- app/test/test.h
- AGENTS.md
- /home/user/ai_lab/dpdk_research/research/10-building-debugging-ecosystem.md
- /home/user/ai_lab/dpdk_research/research/01-overview-history-architecture.md (ecosystem)
- doc/guides/nics/ena.rst
- doc/guides/nics/gve.rst
- doc/guides/nics/netvsc.rst
- usertools/dpdk-telemetry-exporter.py
- app/test/test.h (REGISTER_FAST_TEST)

## 30. Capstone: A Tiny IP Router That Lives Next to the Kernel

*Folder:* `chapters/30-capstone-ip-router/` · *Level:* expert · *Prerequisites:* ch10, ch11, ch12, ch13, ch15, ch16, ch17, ch18, ch19, ch21, ch22, ch24

Builds, in five stages, a small user-space IPv4 router on DPDK that routes between two networks and lives next to the Linux kernel. Stage 1 is a short recap of the ch10 ARP/ICMP/UDP responder. Stage 2 adds robustness: an ARP cache with aging timers, TX checksum offload with a software fallback and a fragment policy. Stage 3 is the router: two wire ports (af_packet on veth pairs into two namespaces, 10.30.1.0/24 and 10.30.2.0/24), LPM lookup, TTL decrement, incremental checksum update, next-hop MAC rewrite from the neighbour hash, ICMP time exceeded and unreachable, a policy for unresolved neighbours, and the kernel exception path via tap with netlink route/neighbour sync into LPM/hash under RCU, protected by per-class control-plane policing with rte_meter. Stage 4 scales out with af_packet fanout queues and an LF hash. Stage 5 adds telemetry, dumpcap and a memif load test. Every stage has an acceptance test in run.sh.

**Concepts**

- Design: lcore/queue layout, pool sizing, IP from app args, MAC from rte_eth_macaddr_get; 'which chapter powers this line' map
- Stage 1 (recap of ch10, kept short): EtherType dispatch, ARP reply in place, ICMP echo and UDP echo on a tap port; acceptance: 3 pings and 5 UDP echoes answered
- Stage 2: ARP cache in rte_hash with aging via rte_timer (ch11); gratuitous ARP at start; TX checksum offload when dev_info allows it, software fallback otherwise (ch19); fragment handling policy (drop or reassemble with ip_frag)
- Stage 3 topology: veth ch30a <-> ch30b in netns ch30ns1 (10.30.1.0/24) and veth ch30c <-> ch30d in netns ch30ns2 (10.30.2.0/24); DPDK owns ch30a and ch30c through net_af_packet (ignore_outgoing=1) and has a tap port ch30tap0 to the host kernel for TCP and control traffic; Python in ns1 reaches ns2 only through DPDK
- Stage 3 forwarding mechanics: validate, LPM lookup, TTL-- with ICMP time exceeded at TTL <= 1, RFC 1624 incremental checksum update (reusing the ch10 exercise), dst/src MAC rewrite from the neighbour hash, ICMP destination unreachable for no route
- Stage 3 unresolved neighbours: queue up to N packets per next hop while ARP resolves (with a timeout) or punt to the kernel; the chosen policy and its counters
- Stage 3 exception path: punt/inject design — non-data-plane traffic (TCP, DHCP, BGP/OSPF, unknown ARP) goes to a net_tap port owned by the kernel, replies from the tap go out the wire port; the wires are the two net_af_packet ports on veths whose peers live in netns ch30ns1 and ch30ns2
- Stage 3 control-plane sync: a netlink listener (non-EAL thread registered with rte_thread_register, or a Python helper) watches routes and neighbours on the tap interface and updates rte_lpm/rte_hash under RCU QSBR (ch14, ch18)
- Stage 3 control-plane policing (CoPP): an rte_meter srTCM per punt class (ARP, ICMP-to-me, other) on the path to the tap, with drop counters in telemetry; a flood test sends ARP from ns1 and shows the fast-path forwarding rate and tap queue depth with and without the policer (median of 5)
- Kernel-coexistence options: tap remote= and persist devargs, rte_flow isolate (concept here), bifurcated NICs (mlx5), AF_XDP with xdp_prog=/busy_budget/force_copy/use_cni; decision table AF_XDP vs DPDK with exception path vs bifurcated NIC; virtio_user as exception path (vhost-kernel; /dev/vhost-net is absent here)
- Stage 4 scale-out: net_af_packet qpairs=2,fanout_mode=hash on both wire ports with one lcore per queue (the kernel flow hash keeps a flow on one lcore); neighbour table in an RW_CONCURRENCY_LF rte_hash and LPM under RCU QSBR; per-lcore stats
- Stage 5 operability: /capstone/stats telemetry endpoint, dpdk-dumpcap from a secondary (hugepage primary -m 64), cmdline shell (show stats / set ip / quit), logging
- Stage 5 load test: memif or virtio_user testpmd peer sending txonly at fixed rates; measure Mpps and latency percentiles with the ch22 method
- Acceptance tests: every stage's run.sh section prints expected vs actual counters and a PASS/FAIL line (e.g. stage 3: 100 UDP packets ns1 -> ns2 arrive with TTL 63 and valid checksums; a TTL=1 packet gets ICMP time exceeded; a TCP connect to the router IP is served by the kernel through the tap)
- Where to go next: production checklist (ch29), contributing, extending to IPv6 ND/ICMPv6 and VLANs

**APIs**

`rte_eth_macaddr_get`, `rte_pktmbuf_mtod`, `rte_arp_hdr / RTE_ARP_OP_REQUEST / RTE_ARP_OP_REPLY`, `rte_ether_addr_copy`, `rte_ipv4_cksum`, `rte_ipv4_udptcp_cksum`, `rte_raw_cksum`, `rte_hash_create`, `rte_hash_add_key_data`, `rte_hash_lookup_data`, `rte_eth_rx_burst`, `rte_eth_tx_burst`, `rte_pktmbuf_free`, `rte_telemetry_register_cmd`, `cmdline_stdin_new`, `rte_eth_dev_info_get`, `rte_lpm_add`, `rte_lpm_lookup`, `rte_lpm_rcu_qsbr_add`, `rte_rcu_qsbr_quiescent`, `rte_thread_register`, `rte_timer_reset`, `rte_timer_manage`, `rte_eth_tx_prepare`, `rte_eth_dev_configure (RSS)`, `rte_ipv4_frag_reassemble_packet`, `rte_pdump_init`, `rte_meter_srtcm_color_blind_check`

**Runnable code examples**

- **responder.c (stage 1 recap)** — ch10's ARP/ICMP/UDP responder trimmed to the dispatch loop, on net_tap; kept short.  
  Run here: `timeout -s INT -k 5 20 stdbuf -oL ./responder -l 1 --no-pci --no-huge -m 128 --file-prefix=ch30-s1 --vdev=net_tap0,iface=ch30tap1 -- 10.30.0.2 ; python3 -I udp_client.py 10.30.0.2 9000 5 ; python3 -I icmp_ping.py 10.30.0.2 3`
- **responder_plus.c (stage 2)** — Adds the rte_hash ARP cache with rte_timer aging, gratuitous ARP at start, TX checksum offload with software fallback (forced with --no-offload), and a fragment policy; counters printed at exit.  
  Run here: `./responder_plus -l 0-1 --no-pci --no-huge -m 128 --file-prefix=ch30-plus --vdev=net_tap0,iface=ch30tap2 -- 10.30.3.2`
- **router.c + nl_sync (stage 3)** — Two-port router with the exception path: forwards ns1 <-> ns2 through LPM with TTL, incremental checksum and MAC rewrite; ICMP errors; neighbour resolution policy; tap punt/inject for TCP/control traffic; nl_sync mirrors kernel routes and neighbours into LPM/hash under RCU; CoPP meters on the punt path; flood mode for the CoPP test.  
  Run here: `ip netns add ch30ns1; ip netns add ch30ns2; ip link add ch30a type veth peer name ch30b; ip link add ch30c type veth peer name ch30d; (move ch30b/ch30d into the namespaces, addresses 10.30.1.2/24 and 10.30.2.2/24, routes via 10.30.x.1); ./router -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch30-rt --vdev=net_af_packet0,iface=ch30a,ignore_outgoing=1 --vdev=net_af_packet1,iface=ch30c,ignore_outgoing=1 --vdev=net_tap0,iface=ch30tap0 -- --ip0 10.30.1.1 --ip1 10.30.2.1 ; acceptance tests from run.sh ; trap deletes netns/veth/tap`
- **router_mq.c (stage 4)** — Stage 3 router with qpairs=2,fanout_mode=hash on both wire ports, one lcore per queue, LF hash + RCU; the Python sender in ns1 sends 40 flows and the run prints per-lcore counts.  
  Run here: `./router_mq -l 0-2 --no-pci --no-huge -m 256 --file-prefix=ch30-mq --vdev=net_af_packet0,iface=ch30a,qpairs=2,fanout_mode=hash,ignore_outgoing=1 --vdev=net_af_packet1,iface=ch30c,qpairs=2,fanout_mode=hash,ignore_outgoing=1`
- **ops_and_load.sh (stage 5)** — Telemetry endpoint /capstone/stats queried with dpdk-telemetry.py; dpdk-dumpcap from a secondary (the router runs as a -m 64 hugepage primary for this stage, trap removes /dev/hugepages/ch30-opsmap_*); memif load test with a testpmd txonly peer (--no-huge -m 256, --total-num-mbufs=8192) at fixed rates; median of 5.  
  Run here: `prefixes ch30-ops (router), ch30-gen (memif peer)`
- **Python clients** — udp_client.py (send/receive with timeout and RTT), icmp_ping.py (raw socket ping with checksum and RTT), arp check via `ip neigh`; all output captured.  
  Run here: `python3 -I udp_client.py 10.30.0.2 9000 5 ; python3 -I icmp_ping.py 10.30.0.2 3`

**Visualizations**

- **Packet surgery** (animation) — Incoming ARP request fields animate their swaps into a reply (sha<->tha, sip<->tip, opcode 1->2); same for ICMP (type 8->0, checksum recomputed with folding) and UDP (port swap, pseudo-header checksum).
- **Router forwarding step-through** (interactive) — Predict-then-step through one packet from ns1 to ns2: LPM lookup result, TTL 64 -> 63, the incremental checksum update with its arithmetic, neighbour lookup and MAC rewrite, TX port; the learner can set TTL=1 or remove the neighbour entry to see the ICMP and unresolved-neighbour paths.
- **Exception-path topology** (animation) — Netns client <-> veth <-> af_packet wire port <-> router fast path; punted packets go to the tap and the kernel stack, kernel replies come back through the tap and out the wire; learner sends ARP, ICMP, UDP or TCP and sees which path each takes.
- **Control-plane sync** (animation) — `ip route add` in the kernel -> netlink message -> sync thread -> new LPM entry published under RCU while data lcores keep looking up; the old entry is freed after the grace period.
- **Responder state and dispatch** (diagram) — Flowchart of the per-packet dispatch (EtherType -> ARP/IPv4 -> ICMP/UDP -> reply or drop) with counters.
- **Which chapter powers this line** (interactive) — The router source with each block tagged by the chapter that taught it; clicking a tag jumps to that chapter's concept list.
- **Kernel-coexistence decision table** (interactive) — Answer questions (need line rate? NIC supports bifurcation? need kernel tools on the same port? containers?) to land on AF_XDP, DPDK + exception path, or a bifurcated NIC.
- **CoPP under flood** (interactive) — The learner sets the ARP flood rate and the meter's CIR/CBS; measured fast-path Mpps and tap queue depth (from the flood test) are shown with and without the policer.

**Exercises**

1. [easy] Add a per-port 'no route' counter to the router and expose it in /capstone/stats.
2. [medium] Add VLAN support so the router answers on VLAN 100 only, and punt other VLANs to the kernel.
3. [medium] Make nl_sync also mirror kernel neighbour entries and age them consistently with the DPDK ARP cache.
4. [stretch] Replace the tap exception port with tap remote= mirroring or an AF_XDP socket, and compare latency of the kernel path.

**Sources**

- doc/guides/howto/flow_bifurcation.rst
- doc/guides/howto/virtio_user_as_exception_path.rst
- doc/guides/nics/tap.rst (remote, persist)
- doc/guides/nics/af_packet.rst
- doc/guides/nics/af_xdp.rst
- lib/net/rte_arp.h
- lib/net/rte_icmp.h
- lib/net/rte_ip4.h
- lib/lpm/rte_lpm.h
- lib/rcu/rte_rcu_qsbr.h
- lib/hash/rte_hash.h
- lib/timer/rte_timer.h
- lib/node/kernel_rx.c
- lib/node/kernel_tx.c
- Linux rtnetlink(7) man page
- /home/user/ai_lab/dpdk_research/research/10-examples/responder.c
- /home/user/ai_lab/dpdk_research/research/06-virtual-devices-and-virtio.md

## Revision 1 changelog

*Kept for history. Chapter numbers in this table are Revision 0/1 numbers; the Revision 2 renumbering table is in the Revision 2 changelog below.*

Renumbering (old -> new): 1-11 unchanged; 20 -> 12 (concurrency moved earlier); 12 -> 13; 13 + 14 -> 14 (multi-process merged with observability; cmdline -> 11, DPDK testing -> 27); 15-18 unchanged; new 19 (scale-out); 19 -> 20 (QoS, now with rte_mtr/rte_tm); 21-24 unchanged in position; 25 + 26 -> 25 (lookaside accelerators); 27 -> 26; new 27 (production); 28 capstone rebuilt (slug capstone-ip-router).

| # | Severity | Finding (original chapter numbers) | Decision and change |
|---|---|---|---|
| 1 | high | 18/13: switch representation missing | Accepted. ch18 gains representors, switch domain, representor devargs, transfer rules, REPRESENTED_PORT vs PORT_REPRESENTOR, rte_eth_representor_info_get, rte_flow_pick_transfer_proxy, an e-switch diagram and switch_probe.c (capability probe; no vdev supports transfer). ch13 mentions representors under port ownership; ch27 and ch28 link OVS-DPDK offload to it. |
| 2 | high | 24 (11, 21): deprecated -s coremask | Accepted (verified in eal_option_list.h). All -s 0xN replaced by -S N inside -l; ch3 lists -c and -s as deprecated; ch11 shows the warning; shared conventions forbid -c/-s. |
| 3 | high | 27: wrong graph/SWX API names, 26.11 graph changes | Accepted (verified in rte_graph_worker_common.h, rte_swx_pipeline.h, rte_config.h). Now ch26: rte_graph_worker_model_set/get, rte_swx_pipeline_codegen + build_from_lib flow, topological bitmap walk with an old-vs-new animation, RTE_GRAPH_PROFILE buckets, graph pcap, mcore-dispatch core bind and rte_graph_clone, app/graph, dpdk-validate-bpf. |
| 4 | high | 12: 26.11 stats model | Accepted (release_26_11.rst). ch13 states rte_eth_stats has only port totals, mapping APIs and rx_qN_errors removed, per-queue counters via xstats; ch8 stats preview says the same; Sankey shows per-queue counters as xstats; added to the accuracy list. |
| 5 | medium | 12/17: physical-port knobs, DCB/VMDq | Accepted. ch13 adds a physical-port knobs table and knobs_probe.c (speed/autoneg, flow control, PFC, FEC, cman, EEPROM incl. rte_eth_module_eeprom_parse, conf_get, reg/descriptor dumps, RX_AVAIL_THRESH, error recovery events + rte_eth_dev_reset). DCB/VMDq with the 26.11 validation rules go to ch18. |
| 6 | medium | 17/7: timestamps and PTP | Accepted. ch17 adds timestamps, timesync API, PTP exchange animation, timesync_probe.c and a ptp_tap_relay_sw attempt, ptpclient as reading. ch7 names rte_mbuf_dyn_rx/tx_timestamp_register. |
| 7 | medium | 18: advanced rte_flow | Accepted. Advanced actions table (indirect/action lists, METER/METER_MARK, CONNTRACK, AGE, tunnel offload, flex, encap/decap, SAMPLE, hairpin, dev_dump), indirect COUNT animation, flow_validate.c uses RTE_FLOW_CONV_OP_ITEM_DEFAULT_MASK_PTR and _ITEM_SIZE, dpdk-test-flow-perf as tool. |
| 8 | medium | 9/3: device model and devargs | Accepted. ch9 opens with buses/classes/drivers/devargs, -a/-b, rte_devargs_parse, device iterators, devargs_iter.c and a device-model widget; ch3 lists -a/-b in the device option group; ch22 has the bus-type table. |
| 9 | medium | 4/22: VFIO outdated | Accepted (release notes: VFIO cdev/IOMMUFD added, rte_vfio_* internal). ch22 diagrams group vs cdev mode, states rte_vfio_* is internal, notes interrupt-handle changes; ch4 points to ch22; added to accuracy list. |
| 10 | medium | 11: EAL utility headers | Accepted. ch11 adds an 'EAL toolbox' section and toolbox.c (rand, bitmap, bitset, reciprocal, hexdump, errno/strerror, string fns, tailq, uuid, common macros, 26.11 RTE_PTR_* callout); keepalive next to service cores; device event monitor in ch13 hotplug. |
| 11 | medium | 21: narrow power coverage | Accepted. ch21 gains a power API map (cpufreq, uncore with RTE_UNCORE_PM_ENV_AUTO_DETECT, PM QoS, PMD pmgmt, Rx interrupts), power_probe.c reporting what fails here and why, and the l3fwd-power modes table. |
| 12 | medium | 24: missing 26.11 eventdev features | Accepted. Vector adapter and event vectors (animation), link profiles, preschedule, stop-flush callback in event_pipeline.c, eventdev xstats and /eventdev/* telemetry queried in run.sh. |
| 13 | medium | 25: IPsec SAD, raw dp, CPU crypto, validation apps | Accepted. ipsec_sad.c demo, crypto_group, session types, /ipsec/sa telemetry, raw data-path, CPU crypto, callbacks, validation-tools box (crypto-perf, security-perf, test-sad, fips_validation, wycheproof_validation), MACsec/TLS pointers, ipsec-secgw SPD-vs-SAD diagram. |
| 14 | medium | 14/28: tools never mentioned | Accepted. 'Tools for this chapter' box is a convention; specific tools placed (ch16 test-fib/test-acl, ch18 rss-flows/test-flow-perf, ch14 exporter/client/watcher, ch7 mbuf-history-parser, ch21 cpu_layout, ch25 test-dma-perf/compress-perf/test-sad/wycheproof, ch26 validate-bpf/dpdk-graph); full census in the ch27 atlas. |
| 15 | medium | 28/all: sample-app atlas | Accepted. ch27 atlas.py + filterable widget maps every examples/ and app/ program to its chapter and runnable status; newly placed samples include ethtool (ch14), l2fwd-keepalive (ch11), l2fwd-cat (ch21), l2fwd-macsec (ch25), vmdq/vmdq_dcb (ch18), ptpclient/ptp_tap_relay_sw (ch17), vhost_crypto/vdpa/vhost_blk (ch23), distributor/packet_ordering (ch19). ch26 builds its BPF object from examples/bpf/t1.c with clang (installed). |
| 16 | medium | 23: vhost flags and other backends | Accepted. Flags table (CLIENT, NO_RECONNECT, IOMMU_SUPPORT, EXTBUF_SUPPORT, NET_COMPLIANT_OL_FLAGS) in the vhostapp walkthrough, 'other vhost backends' box (crypto, blk, vDPA, VDUSE); async-API removal note kept. |
| 17 | medium | 10: lib/net omissions | Accepted (verified rte_vlan_insert_tpid, rte_net_crc_calc, RTE_ICMP_TYPE_ECHO_*; RTE_IP_ICMP_ECHO_* absent). APIs, accuracy note, VXLAN build in build_packets.c and a tunnel-header gallery added. |
| 18 | low | 6: 26.11 mempool changes | Accepted (release_26_11.rst). API-changes callout, pile ordering caveat in handler_bakeoff, cache_size 1024 run in cache_explorer. |
| 19 | low | 7: pool variants and ops | Accepted. by_ops, --mbuf-pool-ops-name, best_mempool_ops, extbuf pools, free_seg/prefree_seg, mbuf-history-parser; new pool_ops.c. |
| 20 | low | 9: testpmd modes, autoneg, ignore_outgoing | Accepted. Full 26.11 forward-mode list, autoneg option, af_packet ignore_outgoing=1 in ch9 and ch28 veth recipes; noisy mode used in ch21. |
| 21 | low | 26: dmadev/bbdev gaps | Accepted (verified rte_dma_enqueue_ops, rte_dma_burst_capacity, rte_bbdev_queue_stats_get). Two programming models comparison, burst_capacity in dma_copy.c, queue stats in bbdev_null.c, test-dma-perf named (now in ch25). |
| 22 | low | 2: build tunables, LTO | Accepted. Build-time tunables table with owning chapters, LTO paragraph, Windows/FreeBSD/cross-build pointers. |
| 23 | high | 20 vs 5/6/15/16: concurrency too late | Accepted, option (a): concurrency moved to ch12 (right after EAL services, before multi-process, hash and LPM); ch5 keeps a short atomics primer box; ch15/ch16 keep their RCU examples with correct prerequisites. |
| 24 | high | 5/7: examples needing later chapters | Accepted. ring_eth.c and rte_eth_from_ring removed from ch5 (pointer to ch8 ring_cable). ch7 build_udp.c replaced by payload_build.c (no headers, no port); chain_demo verifies with rte_pktmbuf_read/linearize only; Eth/IP/UDP-to-pcap moved to ch10 build_packets.c. |
| 25 | high | 28: weak, overloaded capstone | Accepted. Capstone rebuilt as five stages (responder; robustness with timers/offload fallback/fragment policy; exception path + control-plane sync; RSS scale-out with LF hash + RCU; telemetry/dumpcap/load test) with a 'which chapter powers this line' map and prerequisites across all bands. Contributing/ABI/DTS/ecosystem moved to new ch27. |
| 26 | high | 10-24: no multi-core structuring chapter | Accepted. New ch19 'Scaling Out: Run-to-Completion vs Pipeline, Distributor and Reorder' with rtc_multiqueue.c, pipeline_rings.c, distributor_reorder.c, prebuilt samples and a measured comparison; distributor/reorder moved out of eventdev. |
| 27 | high | 24: overloaded eventdev using later device classes | Accepted. Distributor/reorder to ch19; crypto adapter closes ch25 part 1 (crypto_event_adapter.c), DMA adapter is in ch25 part 2; ch24 animation shows them greyed as forward references. |
| 28 | medium | 8/21/22: descriptor rings explained too late | Accepted. ch8 adds a simplified descriptor-ring animation and concept; vector PMD paths and the SIMD-lanes animation moved from ch21 to ch22; ch21 keeps app-level SIMD. |
| 29 | medium | 22: desc_status.c depends on ch23 | Accepted. net_toy implements rx_queue_count and rx_descriptor_status; the vhost/virtio_user descriptor-status run moved to ch23 (desc_status_vhost.c). |
| 30 | medium | 4: chapter too dense for beginners | Accepted. Core + marked 'Deep dive (optional)' section (memseg model, heap internals, legacy mem, event callbacks, external memory); IOVA-contig exercise reworded with a ch22 forward link; level label updated. |
| 31 | medium | 1: benchmarks unreadable for beginners | Accepted. bypass_bench and intr_vs_poll are 'peek ahead' demos: output + 10-line excerpt, full source collapsed. |
| 32 | medium | 2-7: no visible payoff before ch8 | Accepted. 'First look' lab at the end of ch2 (testpmd/skeleton on net_null) and a recurring 'skeleton x-ray' diagram opening ch3-ch8. |
| 33 | medium | 18/19: hardware QoS before token buckets | Accepted. rte_mtr/rte_tm, qos_caps.c and the TM hierarchy diagram moved to the end of the QoS chapter (now ch20). |
| 34 | medium | 11/14: grab-bag chapters, lcore vars taught three times | Accepted. argparse/kvargs/cfgfile moved to ch2; lcore variables owned by ch12 (ch11 and ch21 link to it); cmdline moved to ch11; DPDK's own testing moved to ch27. ch11 is now 'things that run in the background' plus the toolbox. |
| 35 | medium | 3/5/6/8/21: benchmark methodology too late, hard-coded numbers | Accepted. 'How to measure on this machine' box in ch3 tsc_lab, linked by every benchmark; ch21 reuses ch8 sweep data; predicted ratios (65x, 17x, 210 vs 12.7) removed and a convention forbids unmeasured numbers. |
| 36 | medium | 16: overloaded, unexplained l3fwd flags | Partly accepted. Every l3fwd flag (--config tuples, --parse-ptype, --disable-rss, --relax-rx-offload) explained with a forward link to ch18; ACL internals become an optional deep dive. Splitting ACL into its own chapter rejected: the 28-chapter cap is reached and ch25 references ACL from the same chapter. |
| 37 | low | 2/3: launch API overlap | Accepted. Launch APIs removed from ch2's API list; hello.c carries a 'launch details in ch3' comment. |
| 38 | low | 13/25: exercise/prerequisite mismatches | Accepted. The rte_hash secondary-process exercise moved to ch15; ch25 now requires ch16 and ch17 (and ch24 for the crypto adapter). |
| 39 | low | all: exercises without tags/solutions/checkpoints | Accepted. Exercises tagged [easy]/[medium]/[stretch]; code/solutions or hints for easy/medium; 5-question check widget per chapter; band review pages at the end of ch4, ch12, ch20 (capstone map closes ch28). |
| 40 | low | various: decorative visualizations | Accepted. Convention: a counted interactive must react to learner input and show internal state; 'predict, then step' on core mechanism widgets. ch2 build pipeline and ch8 skeleton call graph re-labelled as static diagrams; ch1/ch2/ch5/ch22 widgets gained learner input. |
| 41 | high | 18: rte_flow creation impossible here | Accepted (probe results). flow_steer_sw.c prints the real ENOTSUP then applies the same rte_flow arrays in a software matcher; testpmd flow file keeps validate lines and labels create/isolate as captured failures; RSS/RETA on net_null --rxq=4; tap exercises rewritten. |
| 42 | high | 21: power/PMU cannot run as planned | Accepted. Verified l3fwd-power --interrupt-only command on net_tap; pause mode with --parse-ptype --pause-duration=100 and KVM caveat; monitor/scale captured as failures; rte_pmu compile-only with -ENODEV fallback; perf removed. |
| 43 | high | 11 (20, 21): RTE_LCORE_VAR_VALUE does not exist | Accepted (verified rte_lcore_var.h). APIs use RTE_LCORE_VAR / RTE_LCORE_VAR_LCORE with the verified snippet in ch12 counters.c; added to accuracy list. |
| 44 | high | 25: OpenSSL 3.0.13 limits | Accepted. Runnable asym limited to MODEX/MODINV/RSA/DH; EdDSA session failure shown; ML-KEM/ML-DSA need 3.5, EdDSA 3.3; ECDSA claim removed; crypto_caps prints the real list. |
| 45 | medium | 19: qos_meter/qos_sched commands | Accepted. Verified tap-based qos_meter command and net_null qos_sched command with --msz 16384; the -22 failure on ring/pcap captured as a lesson. |
| 46 | medium | 22: desc ops support and net_toy flags | Accepted. Support table (no descriptor_status anywhere; vhost implements rx_queue_count/tx_done_cleanup; virtio burst mode); verified net_toy include flags; PMD marked runnable. |
| 47 | medium | 23: vectorized devarg, memif zero-copy, --no-huge | Accepted. vectorized=0/1 in matrix.sh with the split-ring caveat; vhost/virtio_user/memif on --no-huge -m 256; memif zero-copy client on -m 64 --single-file-segments; unique sockets and cleanup traps. |
| 48 | medium | 9 (13, 14, 22, 23): ladder order, background testpmd exits | Accepted. Ladder is data-driven with measured order and a disclaimer; shared convention requires --stats-period or -i with a FIFO for background testpmd; affected recipes updated. |
| 49 | medium | 4: heap_events --no-huge ENOTSUP | Accepted. --no-huge and --legacy-mem runs are captured ENOTSUP cases; real trace with -m 16 --huge-unlink and a cleanup trap. |
| 50 | medium | 26: no ml null / gpudev / regexdev drivers | Accepted. ml_quantize.c runnable without a device (saturation explained); census reports 0 with the reason; 'ml null' removed from conventions. |
| 51 | medium | 27: API names and rte_bpf_convert | Accepted (duplicate of the graph/SWX finding); rte_bpf_convert part of bpf_filter.c is unconditional (RTE_HAS_LIBPCAP=1). |
| 52 | medium | 12: optional ops on few PMDs | Accepted. port_ctl.c checks return codes and prints ENOTSUP as a lesson; ops-support table; queue info/burst mode shown on virtio_user in ch23; queue-stats-mapping removal noted. |
| 53 | low | 18: rte_mtr/rte_tm give ENOSYS | Accepted. qos_caps.c (now ch20) treats ENOSYS and ENOTSUP alike and captures the real text; convention added. |
| 54 | low | 24 (11): -s deprecated and service cores inside -l | Accepted (same fix as the high finding). |
| 55 | low | 14: /eal/lcore/usage needs a callback | Accepted. telemetry_app.c registers rte_lcore_register_usage_cb; noted in concepts. |
| 56 | low | 21: SIMD bitwidth default and no SIMD cksum API | Accepted. --force-max-simd-bitwidth=512, per-function target attributes, CPU-flag check, path printed. |
| 57 | low | 5: overcommitted bench may exceed timeout | Accepted. ring_modes_bench bounded by 1 s of TSC per mode, reports ops/s. |
| 58 | high | new chapter: exception path and control-plane sync | Accepted as a major part of the capstone (the finding allows 'a major section of ch28') because the 28-chapter cap is reached: stage 3 implements punt/inject via net_tap with af_packet on veth+netns as the wire, a netlink listener syncing kernel routes/neighbours into rte_lpm/rte_hash under RCU, tap remote=/persist, bifurcation and AF_XDP options and a decision table. |
| 59 | high | new chapter: deployment and operations | Accepted. New ch27 (sysprep.sh with cpu_layout/hugepages/kernel command line, nonroot.sh, systemd unit + prestart cleanup, containers/K8s diagrams, devbind status walkthrough); isolation cross-referenced from ch21. |
| 60 | high | 21/9: honest measurement | Accepted. 'Measuring honestly' in ch21: latency_hist.c with percentiles and noisy neighbour, loss_search.sh zero-loss search, median-of-5 with error bars, VM-vs-NIC disclaimer table, traffic generators and PVP as methodology; dpdk-rss-flows.py in ch18. |
| 61 | high | 12/13: failure modes and recovery | Accepted, distributed instead of a new chapter: ch13 failure_lab.c (pool dry, TX full, link flap, reset sequence, recovery events), ch14 primary-SIGKILL fault in mp_pipeline.c with rte_eal_primary_proc_alive, ch11 keepalive_demo.c + l2fwd-keepalive; keepalive API now assigned. |
| 62 | medium | 9: testpmd as a field tool | Accepted as a recipes section in ch9 (testpmd_recipes.sh: show config fwd, jumbo/scatter, buffer split ENOTSUP, xstats delta, txonly multi-flow, noisy, runtime port config, minimal reproducer cmdline-file); test-flow-perf in ch18, dpdk-graph in ch26. A separate chapter rejected because of the chapter cap. |
| 63 | medium | 13/14/23: operational security | Accepted in ch27: threat model, runtime-dir/socket permissions (perms.sh), memif secret and vhost descriptor validation notes, malformed-packet corpus and libFuzzer/ASan harness (fuzz_parse.c), vulnerability process and LTS tracking. |
| 64 | medium | 14: monitoring systems | Accepted. dpdk-telemetry-exporter.py fetched over HTTP in ch14, telemetry-client, RTE_LOG_DP example, syslog/journald note, mbuf-history-parser (ch7), dpdk-ethtool run. |
| 65 | medium | 14: hands-on debugging | Accepted. ch14 debug_labs/ with six seeded bugs, diagnosis commands and captured real errors, plus a triage widget. |
| 66 | medium | 14/28: testing your own app | Accepted. ch27 golden_pcap_test.sh with a deliberate-bug failure and a CI YAML as text. |
| 67 | medium | 22/17: NIC selection | Accepted. ch22 'Choosing and qualifying a NIC': features/*.ini parser + filter widget, vendor specifics, SR-IOV diagram, qualification checklist. |
| 68 | low | 17/21: timestamps (duplicate) and l2fwd-cat | Accepted (see the PTP finding); l2fwd-cat mentioned in ch21 isolation. |
| 69 | low | 28/27: release and upgrade strategy | Accepted. ch27 'Living with releases': LTS timeline widget, upgrade checklist, readelf/objdump soname demo (abi_inspect.sh). |

Findings handled: 69. Rejections: none outright; partial rejections are the ACL chapter split, a separate exception-path chapter, a separate testpmd chapter and a separate failure-modes chapter, all because the 28-chapter cap is reached — their content was placed in existing chapters instead.

## Revision 2 changelog

Revision 1 -> Revision 2 chapter numbers: 1-11 unchanged (ch11 reframed); 13 -> 12 (port control, now intermediate); 14 -> 13 (observability and debugging) + 16 (multi-process and capture); 12 -> 14 (concurrency, now advanced); 19 -> 15 (scale-out, now also multi-queue/RSS/Toeplitz); 15 -> 17 (hash, without Toeplitz); 16 -> 18; 17 -> 19; 18 -> 20 (rte_flow, without RSS basics); 20 -> 21; 21 -> 22; 22 -> 23; 23 -> 24; 24 -> 25; 25 -> 26 (cryptodev/IPsec) + 27 (other accelerators); 26 -> 28; 27 -> 29; 28 -> 30.

| # | Severity | Finding (Revision 1 chapter numbers) | Decision and change (Revision 2 chapter numbers) |
|---|---|---|---|
| 1 | high | R1 ch8/13: no runtime per-queue control | Accepted (verified rte_eth_dev_rx_queue_start, RTE_ETH_DEV_CAPA_RUNTIME_RX_QUEUE_SETUP, rte_eth_dev_capability_name, rte_eth_rx_queue_is_valid in rte_ethdev.h; rx_queue_start in tap and pcap, not null/ring). ch12 adds per-queue control and runtime queue setup concepts and queue_ctl.c with the ENOTSUP contrast and capability names; ch8 previews it. |
| 2 | medium | R1 ch21/ch1: Rx interrupts never taught as code | Accepted (verified tap_rx_queue_intr_enable, virtio_dev_rx_queue_intr_enable, RTE_EPOLL_PER_THREAD). ch22 adds 'Rx interrupts from scratch', rx_intr.c on net_tap with the re-poll race and a --no-repoll flag, and a predict-then-step widget; ch1's peek-ahead points to it. |
| 3 | medium | R1 ch12/22: device barriers and MMIO | Accepted (release_26_11.rst: rte_smp_*mb removed; device ordering must use rte_io_wmb/rte_io_rmb). ch23 adds the doorbell-ordering box and animation, desc_ring_sim and net_toy mark the barrier spot; ch14 adds the CPU-vs-device ordering line and the exercise row. |
| 4 | medium | R1 ch10/11: __rte_packed removed | Accepted (release_26_11.rst Removed Items; __rte_packed_begin/end in rte_common.h). Added to the accuracy list together with unaligned_uintNN_t alignment 1 and rte_fast_rand removal; ch10 build_packets has a toy tunnel header with __rte_packed_begin/end; ch11 toolbox appendix lists it; ch21 red_curve uses rte_rand. |
| 5 | medium | R1 ch4: external memory DMA mapping | Accepted (verified rte_dev_dma_map in rte_dev.h, vdev_dma_map in drivers/bus/vdev/vdev.c, virtio_user_pmd_dma_map). ch4 deep dive gains the concept and extmem_dma.c capturing the real results on virtio_user and net_null. |
| 6 | medium | R1 ch21: rte_memcpy missing | Accepted (RTE_MEMCPY_AVX512 guard verified in lib/eal/x86/include/rte_memcpy.h). ch22 branch_simd_lab adds the rte_memcpy vs memcpy sweep with median/min/max; ch27 dma_copy compares against rte_memcpy. |
| 7 | medium | R1 ch24: eventdev capability model | Accepted (RTE_EVENT_DEV_CAP_* incl. INDEPENDENT_ENQ, MAINTENANCE_FREE; rte_event_port_quiesce, rte_event_port_preschedule_modify verified). ch25 adds 'capabilities shape your app', event_caps.c on event_sw/event_skeleton, a capability-driven-code widget, quiesce in stop-flush and preschedule_modify. |
| 8 | medium | R1 ch25: missing dmadev/cryptodev APIs | Accepted (verified rte_dma_access_pair_group_*, rte_dma_vchan_status, struct rte_crypto_rsa_capa with pss_explicit_salt). ch26 crypto_caps prints rte_crypto_rsa_capa; ch27 adds the 'dmadev beyond mem-to-mem' concept (directions, rte_dma_port_param, access pair groups, vchan_status drain, stats_reset). |
| 9 | medium | R1 ch19/5: ptr_compress misplaced | Accepted (rte_ptr_compress_32_shift and RTE_PTR_COMPRESS_BITS_NEEDED_* verified). Moved into ch15's pipeline section: pipeline_rings --compress over a 4-byte element ring, with the 2^(32+shift) window precondition. |
| 10 | low | R1 ch17: stable offload APIs missing | Accepted (verified rte_eth_ip_reassembly_*, rte_eth_dev_udp_tunnel_port_add, rte_eth_buffer_split_get_supported_hdr_ptypes, max_rx_mempools). ch19 adds the hardware-vs-software reassembly concept, udp_tunnel_port_add in the tunnel recipe, a struct-level buffer-split concept and figure, and probes in offload_caps.c. |
| 11 | low | R1 ch18: RSS level and hash-algorithm APIs; tap RSS wording | Accepted (verified RTE_ETH_RSS_LEVEL_*, SYMMETRIC_TOEPLITZ_SORT, rss_algo_capa, rte_eth_dev_rss_algo_name, rte_eth_find_rss_algo; enable_tap_rss in drivers/net/tap/meson.build). Now in ch15: 'hash function vs key' and level concepts, rss_lab prints rss_algo_capa; tap note reworded in ch15, ch20 and the conventions. |
| 12 | low | R1 ch13: aggregated ports and err_handle_mode | Accepted (verified rte_eth_dev_count_aggr_ports, rte_eth_dev_map_aggr_tx_affinity, enum rte_eth_err_handle_mode). ch12 adds the software-bonding vs hardware-aggregation row (probe returns 0 on vdevs) and ties err_handle_mode to INTR_RESET vs ERR_RECOVERING events. |
| 13 | low | R1 ch12: lock annotations | Accepted and verified: clang -Wthread-safety -DRTE_ANNOTATE_LOCKS on a 6-line file prints 'writing variable 'counter' requires holding spinlock 'lk' exclusively'. ch14 adds the static-lock-checking concept and thread_safety/ example, plus seqcount vs seqlock and pflock rows. |
| 14 | low | R1 ch26: softnic and exact 26.11 removals | Accepted (drivers/net/softnic and examples/pipeline present; examples/ip_pipeline and app/test-pipeline absent; release notes checked). ch28 lists exactly what was removed and what remains, and adds a softnic reading pointer. |
| 15 | low | R1 ch14: rte_metrics_tel_* removed | Accepted (release_26_11.rst lines 399-403). Added to the accuracy list; ch13's metrics concept and latency_metrics.c use only rte_metrics_* plus rte_telemetry_register_cmd. |
| 16 | high | R1 ch14 overloaded; debugging taught too late | Accepted. Split into ch13 'Observability and Debugging' (intermediate, right after port control, so later chapters have the tools) and ch16 'Multi-Process DPDK and Packet Capture'. ch8 gains the 'when it doesn't work' box. The course grows to 30 chapters, within the user's limit of 30 (see Design notes). |
| 17 | high | R1 ch25 overloaded | Accepted. ch26 'Lookaside Crypto: cryptodev, rte_security and IPsec' (crypto adapter at the end) and ch27 'Other Lookaside Accelerators' (compressdev, dmadev + DMA adapter, bbdev, mldev/gpudev/regexdev, rawdev); both reuse the order-ticket animation. |
| 18 | high | R1 ch28: capstone never routes between networks | Accepted. Stage 3 now has two wire ports (veth ch30a/ch30b in ns1 10.30.1.0/24, ch30c/ch30d in ns2 10.30.2.0/24) plus the tap exception port; TTL--, RFC 1624 incremental checksum, MAC rewrite, ICMP time exceeded/unreachable and the unresolved-neighbour policy are explicit concepts; stage 1 shrinks to a recap; every stage has a PASS/FAIL acceptance test. |
| 19 | high | R1 ch15/18: Toeplitz before RSS | Accepted. rte_thash, the Toeplitz bit-level widget and thash_rss (merged into rss_lab.c) moved to ch15 next to RSS; ch17 hash is exact-match only with a one-line pointer to ch15. |
| 20 | medium | R1 ch16/18/19: RSS basics too late | Accepted. Multi-queue/RSS/RETA/symmetric RSS moved out of rte_flow into ch15 'Scaling Out', placed before hash/LPM (ch17/18), so l3fwd's --config is understood when first run; ch20 keeps rte_flow, DCB/VMDq and switch representation. Prerequisites of ch18, ch20, ch22, ch25 updated. |
| 21 | medium | R1 ch12/13: difficulty curve inverted | Accepted (swap). Port control becomes ch12 (intermediate), concurrency becomes ch14 (advanced, still before multi-process, hash and LPM). Band 2 review moves to the end of ch13. |
| 22 | medium | R1 ch12: MP litmus not observable on x86 | Accepted. ch14 states that x86-TSO forbids store-store and load-load reordering so MP shows 0 forbidden outcomes, demonstrates compiler reordering with objdump of relaxed vs release builds, and labels Arm outcomes 'allowed by the model, not measurable on this VM' with herd7/Arm sources; no Arm numbers. |
| 23 | medium | R1 ch21 vs 12: duplicate false-sharing lab | Accepted. false_sharing.c dropped from ch22, which reuses ch14's counters.c data; the slot goes to layout_lab.c (hot/cold flow-record layout shown with gdb ptype /o since pahole is absent, plus a working-set vs LLC sweep). Boundary rule added. |
| 24 | medium | R1 ch11: grab bag | Accepted. ch11 is one evolving app (mini_l2fwd + timer -> service -> keepalive -> cmdline shell -> argparse/cfgfile options); the toolbox and rte_common material is a reference appendix with toolbox.c. |
| 25 | medium | R1 ch2: overloaded | Accepted. kvargs moved to ch9 (kvargs_demo.c next to devargs), argparse/cfgfile to ch11 step 5; config_parse.c removed; tunables and LTO are collapsed reference boxes. |
| 26 | medium | R1 ch13: overloaded | Accepted. The physical-port knobs table and knobs_probe.c moved to ch23's NIC qualification section; the representor paragraph moved to ch20. |
| 27 | medium | R1 ch4-20: no milestone projects | Accepted. Band projects with solution code and run.sh PASS/FAIL acceptance checks at the end of ch13 (multi-core L2 forwarder) and ch21 (L3 forwarder with LPM, ACL and per-flow meter); the capstone reuses them. |
| 28 | low | R1 ch27 vs 4/9: real-hardware setup too late | Accepted. 'On real hardware' sidebars in ch4 (hugepage reservation, IOMMU) and ch9 (devbind, vfio-pci, never the management NIC); ch4's IOVA section opens with the NIC-DMA bridge from ch1. |
| 29 | low | R1 ch2/3/14: stale cross-references | Accepted. kvargs now in ch9, ch3 points lcore variables to ch14, the proc-info self-preview is gone. revise2.py remaps every reference with context rules for split chapters, and a checker listing every forward and self reference was run and its findings fixed; authors re-check (convention added). |
| 30 | low | R1 ch6/12/28: duplicated widgets; ch27 has no mechanism widget | Accepted. ch14 embeds ch6's ABA widget and adds only the 128-bit CAS fix; the capstone checksum calculator is replaced by a 'router forwarding step-through'; ch29 gains a 'permission path explorer' fed by nonroot.sh's captured errors. Widget-ownership rule added. |
| 31 | high | R1 ch16: test-fib/test-acl not built | Accepted (verified build and run commands). ch18 builds both from app/ sources in its Makefile; run lines updated; convention lists the build recipes. |
| 32 | high | R1 ch26: BPF toolchain fails as written | Accepted with the verified recipes: validate-bpf built from app/validate-bpf, t1.c compiled with -D__x86_64__ -I/usr/include/x86_64-linux-gnu, the default --prog-arg failure captured, --prog-arg='struct udp_headers *' succeeds, testpmd bpf-load on net_null with --total-num-mbufs=8192 (ch28). |
| 33 | high | R1 ch27: fuzz harness cannot link | Accepted. ch29's primary path is a replay+mutation main() built with gcc -fsanitize=address,undefined (verified); libFuzzer command and its real link error are shown as text. |
| 34 | high | all: prebuilt samples not on PATH; 46 not 90 | Accepted. Convention: call samples as $DPDK_SRC/build/examples/dpdk-<name>; every affected run line rewritten (ch13 ethtool, ch15 distributor/packet_ordering, ch16 hotplug_mp, ch18 l3fwd, ch19 ptp_tap_relay_sw, ch21 qos_meter/qos_sched, ch22 l3fwd-power, ch28 pipeline/l3fwd-graph); atlas marks non-built examples; SWX .cli paths rewritten to chapter-local. |
| 35 | high | R1 ch14/19: samples exceed -m 256 | Accepted. Convention allows up to -m 1024 with --no-huge for shipped samples, with the verified table (ethtool 640, distributor 640 with --lcores='(0-4)@(0-3)', packet_ordering 384, l3fwd-graph 640); ch13 ethtool and ch15 distributor/packet_ordering lines fixed. |
| 36 | medium | R1 ch18/19/28: net_null RSS is poll-driven | Accepted. ch15 adds rss_fanout.sh on net_af_packet qpairs=2,fanout_mode=hash over a veth (verified 240/160 split, kernel hash not Toeplitz) and runs rtc_multiqueue on it; net_null is kept for RETA API calls and labelled; ch30 stage 4 uses fanout. |
| 37 | medium | R1 ch26: dpdk-graph fails | Accepted. ch28 explains lib/node/ethdev_ctrl.c's EINVAL conditions, adds a 'dpdk-graph attempt' example whose captured err=-22 is acceptable output, and keeps l3fwd-graph and graph_mini as runnable graph examples. |
| 38 | medium | R1 ch14/28: dumpcap needs a hugepage primary; leaked map files | Accepted. ch16 has the full two-process command line, the captured --no-huge failure, and the trap rule for /dev/hugepages/<prefix>map_*; ch30 stage 5 runs the router as a -m 64 primary with the same cleanup. |
| 39 | medium | all testpmd runs: default pool too large | Accepted. Hard rule in the conventions and ch9; ch8 captures the failure; every testpmd line touched in ch9, ch15, ch16, ch22, ch28 and ch30 passes --total-num-mbufs. |
| 40 | medium | R1 ch27: no systemd, no Docker daemon, no dpdk-test | Accepted. systemd-analyze verify as offline lint, unshare-based container_unshare.sh, Dockerfile/K8s YAML as text, and a reading walkthrough of app/test stating it is not built. |
| 41 | medium | R1 ch25: validation tools not built | Accepted. dpdk-test-sad built standalone in ch26 (verified); test-dma-perf and test-compress-perf get one build attempt in ch27; the others are marked 'not built here'. |
| 42 | low | R1 ch17: PTP relay without ptp4l | Accepted (relay start verified). ch19 runs ptp_tap_relay_sw on af_packet + tap and injects hand-built PTPv2 frames from Python; ptp4l absence stated. |
| 43 | low | R1 ch2: shared build can run | Accepted (verified, ports=1). ch2 captures the failure, then shows the private-mount-namespace fix. |
| 44 | low | R1 ch9/28: af_xdp warnings | Accepted. ch9 concept and the conventions call them benign and explain copy mode; optional bpffs mount with conditional unmount. |
| 45 | low | R1 ch24/25: ANSI codes; adapter services | Accepted. ANSI stripping in conventions and the test-eventdev line; ch25 event_pipeline maps each adapter service explicitly to service lcore 3, taught as a step. |
| 46 | high | R1 ch13: live reconfiguration and graceful shutdown | Accepted. ch12 adds the 'what needs a restart' table, the ordered shutdown sequence and runtime_reconf.c (runtime queue setup attempts, outage timing, SIGINT teardown asserting in_use==0) plus a queue/port state explorer widget. |
| 47 | high | R1 ch14/27: no startup-error catalogue | Accepted, distributed by when errors are first met: ch4 startup_errors.sh (EAL/memory errors incl. a private size-limited hugetlbfs mount) with an error-decoder widget, ch8 init_errors.sh (port errors), ch16 mp_errors.sh (multi-process), consolidated in ch13 and linked from ch29. |
| 48 | medium | R1 ch14: no post-mortem debugging | Accepted. ch13 crash_postmortem.sh (ulimit -c, coredump_filter default vs 0x7f, core sizes, gdb on the core), MADV_DONTDUMP note and a core-dump contents widget; ch29 adds the LimitCORE/systemd-coredump box. |
| 49 | medium | R1 ch27: no monitoring runbook | Accepted. ch29 golden-signals concept with rate formulas and thresholds, rates.py against a seeded-fault telemetry_app, and an alerts.yaml example; tied to ch12's failure-signature board. |
| 50 | medium | R1 ch21/27: no profiling or noise diagnosis | Accepted. ch22 adds pmp_profile.sh (gdb sampling profiler), a perf walkthrough as text, and isolation_check.sh used in the latency_hist 'find the noise source' step. |
| 51 | medium | R1 ch27/22: DPDK in VMs and clouds | Accepted. ch29 'DPDK in a VM and the cloud' concept (vIOMMU vs noiommu, virtio vs VF vs cloud PMDs, PF-side ip-link commands as text, VF checklist) and vm_probe.sh (read-only). |
| 52 | medium | R1 ch28/20: no control-plane policing | Accepted. ch30 stage 3 adds per-class srTCM CoPP on the punt path with a flood test (median of 5) and a 'CoPP under flood' widget; ch29 threat model gains a CoPP row. |
| 53 | medium | R1 ch14/21: capture cost | Accepted. ch16 capture_cost.sh (no capture, non-matching filter, snaplen 64, full snaplen; median of 5; drop counters), a capture-cost widget and a safe-capture checklist. |
| 54 | low | R1 ch9: testpmd as a debugger | Accepted. ch9 recipes gain the debugger block on vhost/virtio_user and net_null with one-line interpretations and a cheat-sheet in the Tools box. |
| 55 | low | R1 ch27: restart budget | Accepted. ch29 'Restart budget' concept and restart_budget.sh (rte_eal_init + port start vs -m, hugepages vs --no-huge, median of 5) with an upgrade playbook. |

Findings handled: 55. All accepted; none rejected (each technical claim was checked against the 26.11 tree before acceptance: headers, drivers, release notes, and the tool and command results the findings report were re-run where cheap, e.g. the clang -Wthread-safety warning). One deviation from the workflow's 18-28 chapter guideline: accepting both split findings gives 30 chapters, which is the maximum the user allowed; the Design notes give the fallback if 28 is mandatory.

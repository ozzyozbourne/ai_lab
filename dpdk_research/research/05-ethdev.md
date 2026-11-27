# 05 — ethdev: Ethernet devices, Poll Mode Drivers, offloads, RSS, rte_flow, TM/MTR, PTP, telemetry

Research note for the DPDK course planner. DPDK version: **26.11.0** (source tree in `$DPDK_SRC`).
Every claim marked **[verified]** was run on this machine (4-core VM, no real DPDK-capable NIC, only vdevs).
Verified example sources are in `research/05-examples/` (`lifecycle.c`, `taprx.c`, `evt.c`, `rss.c`, `txoff.c`, `cap.py`, testpmd command files).

Build any example with:
```
source /tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh
gcc -O2 x.c -o x $(pkg-config --cflags libdpdk) $(pkg-config --libs --static libdpdk)
```

---

## 0. Map of the territory (source files)

| Topic | Files |
|---|---|
| Public API | `lib/ethdev/rte_ethdev.h` (7008 lines), `rte_eth_ctrl.h`, `rte_dev_info.h` |
| Fast-path internals exposed for inlining | `lib/ethdev/rte_ethdev_core.h` (`struct rte_eth_fp_ops`) |
| Driver-side API | `lib/ethdev/ethdev_driver.h` (`struct rte_eth_dev`, `rte_eth_dev_data`, `eth_dev_ops`), `ethdev_vdev.h`, `ethdev_pci.h` |
| Implementation | `lib/ethdev/rte_ethdev.c` (configure @1330, start @1862, stop @1937, rx_queue_setup @2359), `ethdev_private.c` (dummy fp ops @199-283, `eth_dev_fp_ops_setup` @285) |
| rte_flow | `lib/ethdev/rte_flow.h` (6797 lines, 63 public functions), `rte_flow.c`, `rte_flow_driver.h`, **new** `flow_graph.[ch]` (26.11 internal pattern-parser helper for PMDs) |
| Traffic manager / metering | `lib/ethdev/rte_tm.h`, `rte_mtr.h` (+ `_driver.h`) |
| Congestion mgmt | `lib/ethdev/rte_cman.h`, `rte_ethdev_cman.c` |
| Telemetry | `lib/ethdev/rte_ethdev_telemetry.c` (commands registered @1548-1601), `sff_telemetry.c` |
| SFF module EEPROM decode (new 26.11) | `lib/ethdev/sff_*.c`, `rte_eth_module_eeprom_parse()` |
| Docs | `doc/guides/prog_guide/ethdev/{ethdev,flow_offload,flow_graph,traffic_management,traffic_metering_and_policing,switch_representation,qos_framework}.rst`, `doc/guides/nics/*.rst`, `doc/guides/nics/features.rst` + `features/*.ini` (feature matrix), `doc/guides/testpmd_app_ug/` |
| Simple PMDs to read | `drivers/net/null/rte_eth_null.c` (779 lines, best "hello PMD"), `drivers/net/ring/rte_eth_ring.c` (793), `drivers/net/tap/` |
| Real HW PMD with vector paths | `drivers/net/intel/common/{rx.h,tx.h,desc.h,rx_vec_x86.h,tx_vec_x86.h}`, `drivers/net/intel/ice/ice_rxtx.c` (`ice_recv_pkts` @2741, path table `ice_rx_path_infos[]` @3272), `ice_rxtx_vec_avx2.c`, `ice_rxtx_vec_avx512.c` |
| Virtio (runnable vector paths here!) | `drivers/net/virtio/virtio_rxtx*.c`, `virtio_rxtx_packed_avx.h`, doc `nics/virtio.rst` §"Virtio PMD Rx/Tx Callbacks" |
| Examples | `examples/skeleton` (minimal port init), `l2fwd`, `rxtx_callbacks`, `link_status_interrupt`, `ethtool`, `flow_filtering` (+ `snippets/`, `jump_flow.c` template API), `ptpclient`, **new** `ptp_tap_relay_sw` (26.11, SW PTP transparent clock), `qos_meter` (lib/meter), `qos_sched` (lib/sched), `vmdq`, `vmdq_dcb` |
| testpmd sources (great reference for every API) | `app/test-pmd/config.c`, `cmdline_flow.c`, `cmdline_tm.c`, `cmdline_mtr.c`, `csumonly.c` |

---

## 1. Recommended teaching order (easy → hard)

1. **What a port is**: port id, name, `RTE_ETH_FOREACH_DEV`, `rte_eth_dev_count_avail`, vdev vs PCI, `rte_eth_dev_info_get` capability discovery.
2. **Port lifecycle state machine**: configure → queue setup → start → (rx/tx) → stop → close; reconfiguration rules; `-EBUSY`; deferred start; runtime queue setup.
3. **The burst API**: `rte_eth_rx_burst` / `rte_eth_tx_burst`, ownership of mbufs, partial TX, burst sizing, `rte_eth_tx_buffer`.
4. **Inside the call**: `rte_eth_fp_ops[]` flat array, dummy functions before start, inline wrappers, callbacks hook.
5. **Descriptor rings** (conceptual model + virtio/ice source): DD bit, tail register, rx_free_thresh, tx_rs_thresh/tx_free_thresh, sw_ring of mbuf pointers, `rte_eth_rx_queue_count`, `rte_eth_rx_descriptor_status`, `rte_eth_tx_done_cleanup`.
6. **Link, MAC, promiscuous/allmulti, MTU, ptypes**.
7. **Stats & xstats & telemetry** (naming scheme, by-id lookup, per-queue stats, `dpdk-telemetry.py`).
8. **Events & callbacks**: LSC, QUEUE_STATE, NEW/DESTROY (hotplug), RESET, error recovery modes; Rx/Tx burst callbacks.
9. **Offloads**: capability vs per-queue vs per-port model; RX checksum flags; TX checksum/TSO with `l2_len/l3_len/l4_len/ol_flags`, `rte_eth_tx_prepare`; VLAN strip/insert; MBUF_FAST_FREE; MULTI_SEGS; scatter; LRO; timestamp; buffer split / selective Rx (26.07).
10. **Multi-queue & RSS**: `mq_mode`, `rss_hf`, key, Toeplitz math, RETA (groups of 64), symmetric hashing, mbuf `hash.rss` + `RTE_ETH_RX_OFFLOAD_RSS_HASH`; queue-per-lcore design.
11. **rte_flow (sync)**: attributes/pattern/actions, spec/last/mask, validate/create/destroy/flush/query, error reporting, priorities/groups/JUMP, isolate mode, MARK/FLAG metadata negotiation, transfer & representors.
12. **rte_flow async/template API**: `rte_flow_configure`, pattern/actions templates, template tables, `rte_flow_async_create`, push/pull, indirect actions. (Stable since 26.11.)
13. **QoS: metering (rte_mtr) and traffic manager (rte_tm)** — HW API concepts + software substitutes (`lib/meter`, `lib/sched`).
14. **PTP/timesync** and Rx/Tx timestamps (`rte_eth_timesync_*`, `rte_eth_read_clock`, dynamic mbuf timestamp field, `ptpclient`, `ptp_tap_relay_sw`).
15. **Writing/reading a PMD**: `eth_dev_ops`, probe via `RTE_PMD_REGISTER_VDEV`, devargs (`RTE_PMD_REGISTER_PARAM_STRING`), rx/tx burst function selection, vector paths (`ci_rx_path_select`, `--force-max-simd-bitwidth`), `rx_burst_mode_get`, features `.ini` matrix.
16. Advanced extras (optional chapter): hairpin queues, shared Rx queues, mbuf recycle (`rte_eth_recycle_mbufs`), Rx interrupt mode (`rte_eth_dev_rx_intr_*`, l3fwd-power), port representors / switch model, bonding & failsafe as "PMDs made of PMDs", congestion management API, module EEPROM.

A course of ~3-4 chapters on ethdev would split: (A) lifecycle+burst+fp_ops+descriptors, (B) port control+stats+events+offloads, (C) RSS+multi-queue+rte_flow, (D) TM/MTR/PTP/PMD internals/vector paths.

---

## 2. Concepts in detail

### 2.1 Port identity and discovery
- `uint16_t port_id` indexes everything; max `RTE_MAX_ETHPORTS`. Iterate with `RTE_ETH_FOREACH_DEV(pid)` (skips ports owned by others / not attached); `rte_eth_dev_count_avail()`.
- Names: `rte_eth_dev_get_name_by_port(port, name, size)` — **26.11 API change: a `size` parameter was added** (old 2-argument code fails to compile) **[verified]**; `rte_eth_dev_get_port_by_name()`.
- Ownership (`rte_eth_dev_owner_new/set/unset`) — used by failsafe/bonding to "hide" sub-devices from `RTE_ETH_FOREACH_DEV`.
- `rte_eth_dev_info_get()` → `struct rte_eth_dev_info`: `driver_name`, `max_rx/tx_queues`, `rx/tx_desc_lim` {nb_max, nb_min, nb_align}, `rx/tx_offload_capa`, `rx/tx_queue_offload_capa`, `flow_type_rss_offloads`, `reta_size`, `hash_key_size`, `rss_algo_capa`, `min/max_mtu`, `max_rx_pktlen`, `default_rxportconf/txportconf` (preferred burst/ring sizes), `dev_capa` (`RTE_ETH_DEV_CAPA_RUNTIME_RX_QUEUE_SETUP`, `_RUNTIME_TX_QUEUE_SETUP`, `_RXQ_SHARE`, `_FLOW_RULE_KEEP`, `_FLOW_SHARED_OBJECT_KEEP`), `dev_flags` (e.g. `RTE_ETH_DEV_INTR_LSC`), `err_handle_mode`, `rx_seg_capa`.
- Observed on this machine **[verified]** (`lifecycle.c`):
  - net_null: maxrxq=1024, reta_size=128, key 40B, rx_capa=0, tx_capa=MT_LOCKFREE|MULTI_SEGS, RSS flow types advertised (null does *not* actually hash; it only stores RETA/key).
  - net_ring: maxrxq=16, no RSS, mtu_set → -ENOTSUP.
  - net_tap: maxrxq=64, rx_capa IPV4/UDP/TCP_CKSUM|SCATTER (per-queue), tx_capa IPV4/UDP/TCP_CKSUM|TCP_TSO|MULTI_SEGS, max_rx_pktlen 16128.
  - virtio_user (via vhost-user): Rx VLAN_STRIP|UDP/TCP_CKSUM|TCP_LRO|SCATTER, Tx VLAN_INSERT|UDP/TCP_CKSUM|MULTI_SEGS, desc lim 32..32768, `Device private info` shows `use_vec`, `use_inorder`, negotiated guest features.

### 2.2 The lifecycle state machine
```
 probe ──► [unconfigured] ──configure()──► [configured] ──rx/tx_queue_setup()──► [queues ready]
                                 ▲                                                    │ start()
                                 │ configure() again                                  ▼
  close() ◄── [stopped] ◄──────stop()──────────────────────────────────────── [started] ⇄ rx/tx bursts
```
- `rte_eth_dev_configure(port, nb_rxq, nb_txq, &conf)` (`rte_ethdev.c:1330`): rejects if started (`-EBUSY`, log "Port 0 must be stopped to allow configuration") **[verified]**; validates queue counts vs `max_*_queues`, `intr_conf.lsc/rmv` vs dev_flags, MTU (`rxmode.mtu==0` → default 1500), offloads ⊂ capa, LRO size. Copies conf into `dev->data->dev_conf`, calls `dev_ops->dev_configure`.
- **26.11 behaviour change**: `RTE_ETH_MQ_RX_RSS` is *rejected* with >1 Rx queue if the driver reports no `flow_type_rss_offloads`, and silently ignored with one queue; DCB rejected without `get_dcb_info`; VMDq rejected without VMDq pools; unknown modes rejected (`rel_notes/release_26_11.rst`). Course code must mask `rss_hf &= dev_info.flow_type_rss_offloads` and only set RSS if supported.
- `rte_eth_rx_queue_setup(port, q, nb_desc, socket, &rxconf|NULL, mempool)`: nb_desc==0 → driver default `default_rxportconf.ring_size` or fallback 512 (`RTE_ETH_DEV_FALLBACK_RX_RINGSIZE`); must satisfy `rx_desc_lim` (max, min, multiple of align). Use `rte_eth_dev_adjust_nb_rx_tx_desc()` to clamp. rxconf NULL → `dev_info.default_rxconf`. Mempool buffer must be ≥ `min_rx_buf_size`; otherwise need `SCATTER`. Per-queue offloads added here must be per-queue type.
- `rte_eth_tx_queue_setup(port, q, nb_desc, socket, &txconf|NULL)`.
- `rte_eth_dev_start()` (`rte_ethdev.c:1862`): calls `dev_start`, restores config (`eth_dev_config_restore` @1834: MAC addresses, promisc, allmulti — driver can opt out via `get_restore_flags`), then **`eth_dev_fp_ops_setup(rte_eth_fp_ops + port_id, dev)`** (@1929) — this is the moment the fast path becomes "live".
- `rte_eth_dev_stop()` resets fp_ops to dummies (`eth_dev_fp_ops_reset`, @1956). Then `rte_eth_dev_close()` frees queues/resources; port id is released.
- Queue-level control: `rx_deferred_start`/`tx_deferred_start` in rx/txconf, then `rte_eth_dev_rx_queue_start/stop()`; queue state in `dev->data->rx_queue_state[]` (telemetry shows `rxq_state`).
- `rte_eth_dev_reset()` for `RTE_ETH_EVENT_INTR_RESET` (passive mode). Proactive mode events: `ERR_RECOVERING`, `RECOVERY_SUCCESS`, `RECOVERY_FAILED` (PMD swaps in dummy fp, ctrl APIs return -EBUSY).
- `rte_eth_dev_conf_get()` (stable in 26.11) returns current config.

### 2.3 Rx/Tx burst API semantics
- `uint16_t rte_eth_rx_burst(port, q, struct rte_mbuf **pkts, nb)`: returns 0..nb; never blocks; the app now owns the returned mbufs. Return < nb ⇒ ring had fewer ready packets.
- `uint16_t rte_eth_tx_burst(port, q, pkts, n)`: returns number accepted into the ring; **app still owns pkts[ret..n-1]** and must retry or free them (classic leak bug). Driver frees transmitted mbufs *later* (lazy, driven by thresholds) — `rte_eth_tx_done_cleanup()` forces it (vhost supports it here).
- `rte_eth_tx_prepare()` checks/fixes packets for offloads (e.g. pseudo-header checksum for TSO, segment limits) — returns index of first bad packet with rte_errno. Without `RTE_ETHDEV_TX_PREPARE_NOOP` it calls PMD `tx_pkt_prepare` (virtio implements it).
- Thread-safety: functions are lock-free and **not** safe for two lcores on the same queue; different queues in parallel are fine. Exception: `RTE_ETH_TX_OFFLOAD_MT_LOCKFREE` (null advertises it).
- Helpers: `rte_eth_tx_buffer_init/rte_eth_tx_buffer/rte_eth_tx_buffer_flush` (used by l2fwd) to batch single packets.
- Burst size: 32 is the canonical size (`CI_RX_MAX_BURST 32`, testpmd default `packets/burst=32`); vector paths process 4 or 8 descriptors per loop (`CI_VPMD_DESCS_PER_LOOP 4`, `_WIDE 8`) and may require nb_pkts multiple of 4/8 and ≥ 32.

### 2.4 How `rte_eth_rx_burst` actually executes (fp_ops)
`rte_ethdev.h:6183`:
```c
p  = &rte_eth_fp_ops[port_id];          // flat array, 2 cache lines per port
qd = p->rxq.data[queue_id];              // driver's private queue struct
nb_rx = p->rx_pkt_burst(qd, rx_pkts, nb_pkts);   // indirect call into PMD
rte_mbuf_history_mark_bulk(...);         // mbuf history (debug)
#ifdef RTE_ETHDEV_RXTX_CALLBACKS
cb = atomic_load(&p->rxq.clbk[queue_id]); if (unlikely(cb)) nb_rx = rte_eth_call_rx_callbacks(...);
#endif
trace points (rte_ethdev_trace_rx_burst_nonempty/empty)
```
- `struct rte_eth_fp_ops` (`rte_ethdev_core.h`): Rx line {rxq.data, rxq.clbk, rx_pkt_burst, rx_queue_count, rx_descriptor_status, recycle_rx_descriptors_refill}, Tx line {txq.data, txq.clbk, tx_pkt_burst, tx_pkt_prepare, tx_descriptor_status, recycle_tx_mbufs_reuse, tx_queue_count}. Exactly two 64B lines on 64-bit. Introduced in 21.11 to hide `rte_eth_devices[]` from the public ABI.
- No port/queue validity checks unless built with `RTE_ETHDEV_DEBUG_RX/TX`.
- **Dummy functions**: before start/after stop, fp_ops point to `dummy_eth_rx_burst` which logs once per port *"lcore 0 called rx_pkt_burst for not ready port 0"* plus `rte_dump_stack()`, sets `rte_errno=ENOTSUP`, returns 0 **[verified]** — great teaching moment ("why does my app silently receive nothing?").
- The driver side: `struct rte_eth_dev` (`ethdev_driver.h:63`) holds `rx_pkt_burst`, `tx_pkt_burst`, ... (the "master copy"), `data` (`rte_eth_dev_data`, shared in hugepage memory across processes: queues, MACs, mtu, dev_conf, promiscuous/started bits), `dev_ops`, callback lists `post_rx_burst_cbs[]`, `pre_tx_burst_cbs[]`. `rte_eth_devices[]` is per-process; `rte_eth_dev_data` is shared (multi-process).

### 2.5 Descriptor rings (the hardware contract)
Teach with Intel ice + virtio, animate generically:
- Rx ring = array of DMA descriptors in hugepage memory (`rte_eth_dma_zone_reserve`), plus parallel **sw_ring** of `struct rte_mbuf *` (`struct ci_rx_entry`). Descriptor has a **read format** written by SW (`pkt_addr`, `hdr_addr` = IOVA of mbuf data) and a **write-back format** written by NIC (`status_error` with **DD = Descriptor Done** bit, length, RSS hash, ptype, VLAN tag) — `drivers/net/intel/common/desc.h` `union ci_rx_desc {read; wb;}`.
- Scalar Rx loop (`ice_recv_pkts`, `ice_rxtx.c:2741`): check DD bit at `rx_tail` → allocate replacement mbuf (`rte_mbuf_raw_alloc`; failure → `rx_mbuf_alloc_failed++` → stats `rx_nombuf`) → swap into sw_ring, write new IOVA into descriptor (re-arm) → fill old mbuf (`data_len/pkt_len`, `ol_flags` from status bits, `packet_type` via ptype table, `hash.rss`) → `nb_hold++`; when `nb_hold > rx_free_thresh` write tail register (`ICE_PCI_REG_WC_WRITE(rxq->qrx_tail, rx_id)`) — batching MMIO writes.
- Bulk-alloc & vector paths re-arm in chunks of `CI_VPMD_RX_REARM_THRESH` (64) and require power-of-2 rings and `nb_desc % rx_free_thresh == 0` (`ci_rxq_vec_capable()`).
- Tx ring: SW writes descriptors (addr, len, cmd: EOP, RS = Report Status, offload context descriptors for checksum/TSO), bumps tail; NIC DMAs and writes DD back only on descriptors with RS bit (every `tx_rs_thresh`); SW frees mbufs in batches when free descriptors < `tx_free_thresh`. Constraints (ethdev.rst): `0 < tx_rs_thresh ≤ tx_free_thresh < nb_desc-3`, `tx_rs_thresh < nb_desc-2`; one sentinel descriptor.
- Full ring ⇒ Rx: NIC drops → `imissed` (rx_missed_errors); Tx: `tx_burst` returns < n.
- Introspection APIs: `rte_eth_rx_queue_count()`, `rte_eth_rx_descriptor_status(port,q,offset)` → `RTE_ETH_RX_DESC_AVAIL/DONE/UNAVAIL`, `rte_eth_tx_descriptor_status`, `rte_eth_rx_descriptor_dump`, `rte_eth_rx_queue_info_get()` (`struct rte_eth_rxq_info`: mp, conf, scattered, nb_desc), `rte_eth_rx_burst_mode_get()` (string like "Vector AVX2"). Virtual PMDs mostly return ENOTSUP for descriptor status (null, tap, virtio_user here) **[verified]**.
- Virtio analogue: split virtqueue (desc table + avail ring + used ring) vs packed virtqueue (single ring with AVAIL/USED wrap bits); vhost is the "NIC". Good for a second animation.

### 2.6 Port control
- Link: `rte_eth_link_get()` (may wait up to 9s) vs `rte_eth_link_get_nowait()`; `struct rte_eth_link` {link_speed, duplex, autoneg, status}; `rte_eth_link_to_str()` → "Link up at 10 Gbps FDX Fixed None" **[verified on null]**; `rte_eth_dev_set_link_up/down`; speeds via `conf.link_speeds` (`RTE_ETH_LINK_SPEED_*`, 1.6T added in 26.11); speed lanes API; FEC API.
- MAC: `rte_eth_macaddr_get`, `rte_eth_dev_default_mac_addr_set`, `rte_eth_dev_mac_addr_add` (26.11: pool must be 0 unless VMDq), `rte_eth_dev_set_mc_addr_list`, `rte_eth_macaddrs_get`.
- Promiscuous/allmulticast: `rte_eth_promiscuous_enable/disable/get`, `rte_eth_allmulticast_*`. null cannot disable promisc (`-ENOTSUP`, stays 1); ring "succeeds" but stays 1 **[verified]**.
- **Pitfall [verified]**: net_tap with promiscuous *off* drops kernel-originated frames whose dst MAC ≠ the port's MAC. testpmd enables promiscuous by default, a hand-written app does not — so "testpmd receives, my app receives nothing". Always `rte_eth_promiscuous_enable()` in demos (or address frames to the port MAC).
- MTU: `rte_eth_dev_set_mtu()`; frame size = MTU + overhead (`eth_dev_get_overhead_len`: max_rx_pktlen − max_mtu, else 14+4+VLAN); MTU > mbuf data room requires `RTE_ETH_RX_OFFLOAD_SCATTER`; `rxmode.mtu` at configure (the old `max_rx_pkt_len` field was replaced in 21.11).
- VLAN: `rte_eth_dev_vlan_filter`, `rte_eth_dev_set_vlan_offload` (strip/filter/extend/qinq), `rte_eth_dev_set_vlan_pvid`, TPID.
- Packet types: `rte_eth_dev_get_supported_ptypes()` (tap: 22 **[verified]**), `rte_eth_dev_set_ptypes()` to disable unneeded parsing (perf hint); `rte_get_ptype_name()`.
- Flow control (pause frames): `rte_eth_dev_flow_ctrl_get/set`, PFC.
- Per-queue rate limit: `rte_eth_set_queue_rate_limit()`.
- Rx metadata: `rte_eth_rx_metadata_negotiate()` must be called *before configure* to enable delivery of `RTE_ETH_RX_METADATA_USER_FLAG/USER_MARK/TUNNEL_ID` set by rte_flow FLAG/MARK actions.

### 2.7 Statistics, xstats, telemetry
- Basic: `rte_eth_stats_get()` → `ipackets, opackets, ibytes, obytes, imissed (HW drop, no descriptors), ierrors, oerrors, rx_nombuf (mbuf alloc failures)`. Queue arrays `q_ipackets[]` etc. **26.11 removed queue stats mapping** (`rte_eth_dev_set_*_queue_stats_mapping`) and the `RTE_ETHDEV_QUEUE_STAT_CNTRS` limit: per-queue values are now reported via xstats for all queues; `rx_qN_errors` removed.
- xstats: names follow `direction_detail..._unit` (`rx_q3_bytes`, `tx_size_128_to_255_packets`). API: `rte_eth_xstats_get_names()`, `rte_eth_xstats_get()`, `rte_eth_xstats_get_names_by_id()`, `rte_eth_xstats_get_id_by_name()`, `rte_eth_xstats_get_by_id()` (cache ids, avoid strcmp in hot loop), `rte_eth_xstats_reset()`; counter enable/disable (`rte_eth_xstats_set_counter`/query state). Drivers with `RTE_ETH_DEV_AUTOFILL_QUEUE_XSTATS` (null) get generic per-queue xstats from ethdev. net_null shows 24 xstats (8 generic + per-queue for 4 queues) **[verified]**; virtio shows size histograms.
- **Pitfall [verified]**: testpmd "flushes" Rx queues at `start` (`flush_fwd_rx_queues`, ~1s); with net_null this generates and drops ~1.28M packets, so port stats (`rx_good_packets`=1.28M) ≫ forwarding stats (6528). Explains PMD-level vs app-level counters; use `--no-flush-rx`.
- Telemetry: `dpdk-telemetry.py -f <file-prefix>` commands: `/ethdev/list, /ethdev/info,N, /ethdev/stats,N, /ethdev/xstats,N, /ethdev/link_status,N, /ethdev/rss_info,N, /ethdev/rx_queue,N,Q, /ethdev/tx_queue, /ethdev/macs, /ethdev/flow_ctrl, /ethdev/dcb, /ethdev/fec, /ethdev/vlan, /ethdev/dump_priv, /ethdev/module_eeprom, /ethdev/tm_capability, /ethdev/tm_level_capability, /ethdev/tm_node_capability, /ethdev/regs`. Output is JSON **[verified]** — e.g. `/ethdev/rss_info,0` → `{"rss_hf":"0xa38c","rss_key_len":40,"rss_key":"6d5a56da...","algorithm":"default"}`; `/ethdev/stats,0` showed ~117M packets after ~3s of testpmd io-fwd between two net_null ports on 1 core (≈40 Mpps: useful perf intuition, no real wire). `/ethdev/rx_queue,0,1` returned null on net_null (driver lacks rxq_info_get). The old `rte_metrics_telemetry.h` helper was removed in 26.11.

### 2.8 Events and callbacks
- Event callbacks: `rte_eth_dev_callback_register(port|RTE_ETH_ALL, event, fn, arg)`; events in `enum rte_eth_event_type`: `INTR_LSC, QUEUE_STATE, INTR_RESET, VF_MBOX, MACSEC, INTR_RMV, NEW, DESTROY, IPSEC, FLOW_AGED, RX_AVAIL_THRESH, ERR_RECOVERING, RECOVERY_SUCCESS, RECOVERY_FAILED`. Callbacks run in the EAL interrupt thread (control thread) — must not do datapath work, must be thread-safe w.r.t. datapath lcores.
- LSC requires `conf.intr_conf.lsc = 1` and `dev_flags & RTE_ETH_DEV_INTR_LSC`; otherwise poll `rte_eth_link_get_nowait()` (example `link_status_interrupt`).
- **Which PMDs here actually raise LSC** (grep of `rte_eth_dev_callback_process`): vhost (LSC + QUEUE_STATE), pcap, virtio, failsafe, bonding. **TAP advertises `RTE_ETH_DEV_INTR_LSC` and tracks kernel link changes via netlink, but never calls `rte_eth_dev_callback_process`** — so app LSC callbacks never fire on tap; link state is only visible by polling **[verified: ip link set down/up produced no callback]**.
- Working event demo **[verified, `evt.c`]**: register for NEW/DESTROY/LSC/QUEUE_STATE on `RTE_ETH_ALL`; `rte_dev_probe("net_null7")` → `NEW`; `rte_dev_probe("net_vhost9,iface=<sock>,queues=1")` → `NEW`; a separate testpmd with `--vdev=virtio_user0,path=<sock>` connects → `QUEUE_STATE ×2, INTR_LSC` (up), disconnects → `QUEUE_STATE ×2, INTR_LSC` (down); `rte_eth_dev_close` + `rte_eal_hotplug_remove("vdev","net_null7")` → `DESTROY`.
- Rx/Tx burst callbacks: `rte_eth_add_rx_callback(port,q,fn,arg)` (`fn(port,q,pkts,nb,max,arg)` returns new nb), `rte_eth_add_first_rx_callback`, `rte_eth_add_tx_callback`, `rte_eth_remove_rx_callback` (removal is not RCU-safe: wait until datapath is quiescent before freeing). Requires `RTE_ETHDEV_RXTX_CALLBACKS` (default on). Used by `examples/rxtx_callbacks` (latency timestamping), pdump, latencystats, bitratestats. **[verified]** an rx callback counting packets on queue 0 saw exactly 1/4 of the null port's traffic.

### 2.9 Offloads
- Model (`ethdev.rst` §Per-Port and Per-Queue Offloads): `dev_info.[rt]x_offload_capa` = all; `[rt]x_queue_offload_capa` = subset that can differ per queue. Offloads in `dev_conf.[rt]xmode.offloads` apply to all queues; extra per-queue ones in `rxconf/txconf.offloads` must be per-queue capable. All disabled by default. Requesting unsupported → configure fails with error log.
- Rx offload results are communicated via mbuf: `ol_flags` (`RTE_MBUF_F_RX_IP_CKSUM_GOOD/BAD/UNKNOWN/NONE`, `RX_L4_CKSUM_*`, `RX_VLAN_STRIPPED`, `RX_RSS_HASH`, `RX_FDIR_ID` for MARK, timestamp dynflag), `packet_type`, `hash.rss`, `vlan_tci`.
  - **[verified]** tap with RX checksum offloads enabled: `ol_flags=0x180` = IP_CKSUM_GOOD|L4_CKSUM_GOOD; without them `ol_flags=0` (UNKNOWN). testpmd `set verbose 1` prints decoded ol_flags & ptypes — very visual.
- Tx offloads are requested per packet: set `m->l2_len, l3_len, (l4_len), ol_flags = RTE_MBUF_F_TX_IPV4 | RTE_MBUF_F_TX_IP_CKSUM | RTE_MBUF_F_TX_UDP_CKSUM` (or `TX_TCP_SEG` + `tso_segsz`), zero IP checksum, put pseudo-header checksum in L4 field (`rte_ipv4_phdr_cksum(ip, ol_flags)`) — or let `rte_eth_tx_prepare()` do the fix-ups. Port must have `RTE_ETH_TX_OFFLOAD_*` enabled at configure.
  - **[verified, `txoff.c` + `cap.py`]**: a UDP packet sent on net_tap with IP checksum 0 and only the pseudo-header in the UDP checksum arrived on the kernel side (AF_PACKET capture) with **valid IP and UDP checksums** — end-to-end proof of TX checksum offload (TAP emulates it in software, `tap_write_mbufs`).
  - **[verified, caveat]** a 3000-byte TCP payload with `TX_TCP_SEG`, `tso_segsz=1000` was *rejected* by TAP's tx_burst (returned 1 of 2, `oerrors=1`), while calling `rte_gso_segment()` directly on the same mbuf produced 3 segments. Root cause not isolated (TAP GSO path → `tap_write_mbufs` returns -1). For a TSO lesson, demonstrate segmentation with `lib/gso` (`rte_gso_segment`) as "what the NIC does", and mention TAP TSO as unreliable here; or the chapter author should re-investigate.
- Other offloads to cover conceptually: VLAN strip/insert (virtio_user supports), QINQ, LRO (virtio), SCATTER/MULTI_SEGS (jumbo with chained mbufs), `MBUF_FAST_FREE` (all mbufs from one pool, refcnt 1 → driver bulk-frees without checks), `MT_LOCKFREE`, outer/tunnel checksums and tunnel TSO, `SEND_ON_TIMESTAMP`, `KEEP_CRC`, `RSS_HASH`, `TIMESTAMP`, `SECURITY` (inline IPsec), `BUFFER_SPLIT` (header/payload into different mempools, `rte_eth_rxseg_split`), **selective Rx** (26.07: segments without mempool are discarded; capability `rte_eth_rxseg_capa.selective_rx`).

### 2.10 Multi-queue, RSS, RETA
- Configure: `conf.rxmode.mq_mode = RTE_ETH_MQ_RX_RSS; conf.rx_adv_conf.rss_conf = {.rss_key=NULL (default key), .rss_hf = RTE_ETH_RSS_IP|RTE_ETH_RSS_UDP|... & dev_info.flow_type_rss_offloads, .algorithm = RTE_ETH_HASH_FUNCTION_DEFAULT|TOEPLITZ|SIMPLE_XOR|SYMMETRIC_TOEPLITZ|SYMMETRIC_TOEPLITZ_SORT}`. Runtime: `rte_eth_dev_rss_hash_update/conf_get`, `rte_eth_dev_rss_algo_name`, `rte_eth_find_rss_algo`.
- RSS level (outer/inner for tunnels) via `RTE_ETH_RSS_LEVEL_*` bits in rss_hf; `RTE_ETH_RSS_L3_SRC_ONLY` etc. modifiers.
- Pipeline: parse packet → select input tuple by rss_hf (e.g. src/dst IP + ports) → 32-bit Toeplitz hash with 40/52-byte key → `idx = hash & (reta_size-1)` (LSBs) → `queue = RETA[idx]` → mbuf `hash.rss = hash` & `RX_RSS_HASH` flag.
- RETA API: `rte_eth_dev_rss_reta_update/query(port, struct rte_eth_rss_reta_entry64 *conf, reta_size)`; entries in groups of `RTE_ETH_RETA_GROUP_SIZE` (64) each with a 64-bit `mask` saying which entries to touch. **[verified on net_null]**: reta_size 128, update round-robin over 4 queues → query returns `0 1 2 3 0 1 2 3...`. testpmd: `port config 0 rss reta (idx,q)`, `show port 0 rss reta 128 (0xffffffffffffffff,0xffffffffffffffff)`, `show port 0 rss-hash key`.
- Software Toeplitz for teaching (`lib/hash/rte_thash.h`: `rte_softrss`, `rte_softrss_be`, `rte_convert_rss_key`, also `rte_thash_*` helpers to *find* tuples that hash to a target queue). **[verified, `rss.c`, no EAL needed]**: Microsoft test vector (66.9.149.187:2794 → 161.142.100.80:1766, default key 6d5a…) = **0x51ccc178** ✓; reverse direction = 0xfde799b2 (asymmetric); with key 0x6d5a repeated, fwd = rev = 0x9fcc9fcc (symmetric — why stateful apps use it); 10 000 flows over a 128-entry RETA / 4 queues → 2512/2504/2488/2496.
- Other mq modes: DCB, VMDq, VMDq+DCB+RSS (examples `vmdq`, `vmdq_dcb`) — mostly legacy; Tx mq modes.
- Design: one Rx queue + one Tx queue per lcore, RSS spreads flows, no locks; elephant flows break balance; RETA rebalancing at runtime; rte_flow RSS action for per-flow-class RSS.
- Machine limits: none of the vdevs here actually *hashes* incoming packets into queues (tap RSS needs eBPF+tc, unavailable: kernel lacks `sch_multiq`; virtio_user/vhost do not offer VIRTIO_NET_F_RSS). So the RSS chapter should combine: (1) real RETA/key API calls on net_null, (2) software Toeplitz with rte_softrss to show where each packet *would* go, (3) multi-queue with net_null/virtio_user (queues=N) to show per-queue stats and per-lcore polling.

### 2.11 rte_flow — generic flow API
History: introduced in **17.02** by Adrien Mazarguil (6WIND) as "ethdev: introduce generic flow API", superseding all legacy filter types (flow director, ntuple, ethertype, etc. via `filter_ctrl`, later removed) [1][2]. Template/async API added in **22.03** (`rel_notes/release_22_03.rst`); all flow template/async APIs **promoted to stable in 26.11**.

- A rule = **attributes** (`struct rte_flow_attr` {group, priority, ingress, egress, transfer}) + **pattern** (array of `struct rte_flow_item` {type, spec, last, mask} terminated by `RTE_FLOW_ITEM_TYPE_END`) + **actions** (array of `struct rte_flow_action` {type, conf}, terminated by `END`).
- Items stacked from lowest layer: `ETH / IPV4 / UDP / VXLAN / ETH / IPV6 / TCP / END`. Meta items (`VOID`, `MARK`, `META`, `TAG`, `PORT_REPRESENTOR`, `REPRESENTED_PORT`, `CONNTRACK`, `METER_COLOR`, `PTYPE`, `RANDOM`, `COMPARE`, `FLEX`...) can appear anywhere.
- spec/last/mask rules: mask w/o spec is an error; spec without mask → default mask `rte_flow_item_<name>_mask`; nothing set → match any; ranges via `last`; mask applied to both spec and last (doc example: spec 10.1.2.3, last 10.3.4.5, mask 255.255.0.0 ⇒ effective 10.1.0.0–10.3.255.255). **26.11** added `rte_flow_conv(RTE_FLOW_CONV_OP_ITEM_DEFAULT_MASK_PTR / RTE_FLOW_CONV_OP_ITEM_SIZE)` to look up default masks and spec sizes.
- Actions: fate (`QUEUE`, `RSS`, `DROP`, `PASSTHRU`, `JUMP`, `PORT_REPRESENTOR`, `REPRESENTED_PORT`, `SEND_TO_KERNEL`), metadata (`MARK` → `mbuf.hash.fdir.hi` + `RTE_MBUF_F_RX_FDIR_ID`, `FLAG`, `SET_META`, `SET_TAG`), counters (`COUNT` + `rte_flow_query`), `AGE` (event `FLOW_AGED`, `rte_flow_get_aged_flows`), modify (`SET_IPV4_SRC`, `DEC_TTL`, `MODIFY_FIELD`, `MAC_SWAP`, `NAT64`), encap/decap (`VXLAN_ENCAP/DECAP`, `RAW_ENCAP`), `METER`/`METER_MARK`, `SECURITY`, `SAMPLE`, `CONNTRACK`, `INDIRECT`/`INDIRECT_LIST` (shared action handles via `rte_flow_action_handle_create`), `QUOTA`, `SKIP_CMAN`.
- Groups & priorities: rules in group 0 are always evaluated; other groups only via `JUMP`; priority is per group (0 highest); overlapping rules at same priority → undefined order. `rte_flow_group_set_miss_actions()`.
- Lifecycle: `rte_flow_validate()` (any time, resources e.g. target queue must exist) → `rte_flow_create()` returns `struct rte_flow *` handle → `rte_flow_query()` / `rte_flow_actions_update()` → `rte_flow_destroy()`; `rte_flow_flush()`; `rte_flow_dev_dump()`. Rules may or may not survive port stop/start: check `RTE_ETH_DEV_CAPA_FLOW_RULE_KEEP`.
- Errors: `struct rte_flow_error` {type (`RTE_FLOW_ERROR_TYPE_ITEM`=13, `_ACTION`=16, `_HANDLE`=2, `_UNSPECIFIED`=1,...), cause pointer (into your item/action array), message}; `rte_flow_error_set()` on PMD side.
- Isolated mode `rte_flow_isolate(port, 1, &err)`: only traffic matched by rules reaches the app; call *before* `rte_eth_dev_configure` ideally; promisc/MAC/RSS config become no-ops.
- Transfer rules & switch model (`switch_representation.rst`): `attr.transfer=1` rules live in the embedded e-switch, matched against represented ports; `rte_flow_pick_transfer_proxy()`; representors via devargs `representor=vf[0-3]`.
- Driver side: `eth_dev_ops.flow_ops_get` → `struct rte_flow_ops` (validate/create/destroy/...); async fast path through `rte_flow_fp_ops` (per port, like rte_eth_fp_ops). New 26.11 internal helper `flow_graph` (`flow_graph.rst`): PMD declares a protocol graph (START→ETH→[VLAN]→IPv4|IPv6→[TCP|UDP|SCTP]→END) to validate & extract fields from patterns in one traversal — a great diagram for "how a PMD parses your pattern".
- Async/template API (`flow_offload.rst` §3610-4170): `rte_flow_info_get()` → `rte_flow_configure(port, &port_attr, nb_queue, queue_attr[])` (after dev configure, **before start** — testpmd shows "Device with port_id=0 already started" otherwise **[verified]**) → `rte_flow_pattern_template_create()` (masks only) + `rte_flow_actions_template_create()` → `rte_flow_template_table_create()` (bind templates, nb_flows) → datapath: `rte_flow_async_create(port, queue, op_attr, table, pattern, pattern_tmpl_idx, actions, actions_tmpl_idx, user_data, &err)` (non-blocking, lockless per flow queue) → `rte_flow_push()` → `rte_flow_pull()` results (`struct rte_flow_op_result` with user_data). Also by-index insertion, table resize, `rte_flow_calc_table_hash`. Rationale: millions of rule inserts/sec (connection tracking, NAT, vSwitch offload) — the sync API costs a syscall-like round trip per rule. `examples/flow_filtering/` shows both modes (`--template` / `jump_flow.c`).
- **What works on this machine [verified]**: net_tap is the only built PMD with `flow_ops_get` (plus failsafe/bonding pass-through). `flow validate` works and produces instructive errors: VXLAN item → "item not supported" (type 13); `queue index 7` with 2 queues → "queue index out of range" (type 16, ERANGE); MARK and RSS actions → "action not supported"; ETH/IPv4/TCP→QUEUE, ARP→DROP, egress→DROP validate OK. **`flow create` fails**: TAP needs the `multiq` qdisc and the kernel here lacks `sch_multiq` ("Specified qdisc kind is unknown … qdisc not initialized: Operation not supported"); `flow isolate` fails the same way ("Parent Qdisc doesn't exists"); `flow info`/`flow configure` → ENOTSUP. testpmd command file: `research/05-examples/flow_validate_cmds.txt`.
  - Therefore the course should: run `validate` (real PMD parsing + error reporting), teach `create/query/destroy` semantics with code that handles ENOTSUP gracefully, and build an **interactive software "flow table" visualizer** (JS) that applies spec/mask/last + priority/group/JUMP to synthetic packets. Optionally a C exercise: a tiny software matcher that walks a `struct rte_flow_item[]` array against parsed packets (reusing real rte_flow structs, `rte_flow_conv` for sizes/default masks).

### 2.12 Traffic Metering & Policing (rte_mtr) and Traffic Manager (rte_tm)
- **rte_mtr** (`rte_mtr.h`, all `rte_mtr_*` promoted to stable in 26.11): `rte_mtr_capabilities_get` → `rte_mtr_meter_profile_add` (`enum rte_mtr_algorithm`: `RTE_MTR_SRTCM_RFC2697`, `RTE_MTR_TRTCM_RFC2698`, `RTE_MTR_TRTCM_RFC4115`, plus packets-per-second variants; params CIR/CBS/EBS, CIR/PIR/CBS/PBS) → `rte_mtr_meter_policy_add` (per-color action lists = rte_flow actions, e.g. red → DROP) → `rte_mtr_create(port, mtr_id, params)` → attach to traffic via rte_flow action `METER {mtr_id}` (or `METER_MARK` in template API). Color-aware mode: input color from DSCP/VLAN PCP tables (`rte_mtr_meter_dscp_table_update`, `color_in_protocol_set`). Stats: `rte_mtr_stats_read` (green/yellow/red pkts/bytes).
- **rte_tm** (`rte_tm.h`, `traffic_management.rst`): hierarchical egress scheduler. Leaf node ids 0..N-1 = Tx queues; app-assigned ids for non-leaf nodes (port → subport → pipe → TC …). Per node: parent, priority (SP among different priorities, 0 = highest), weight (WFQ among same priority), private shaper profile (single/dual token bucket: committed+peak rate/size), shared shapers, WRED/PIE/tail-drop congestion management at leaves, packet marking (VLAN DEI, IP ECN, DSCP). Flow: `rte_tm_capabilities_get` / `level_capabilities_get` / `node_capabilities_get` → `rte_tm_shaper_profile_add` → `rte_tm_node_add` (bottom-up or top-down) → `rte_tm_hierarchy_commit(port, clear_on_fail)` (port stopped) → runtime updates (`node_suspend/resume`, `node_shaper_update`, `node_parent_update`), `rte_tm_node_stats_read`. Telemetry `/ethdev/tm_*`.
- **No built driver here implements `tm_ops_get` or `mtr_ops_get`** (implemented by e.g. ixgbe/i40e/ice/cnxk/mlx5/txgbe/hns3; softnic exists in tree but not built). testpmd `show port tm cap 0` / `show port meter cap 0` would return ENOTSUP. Runnable substitutes:
  - `lib/meter` (`rte_meter_srtcm_config`, `rte_meter_srtcm_color_blind_check`, `rte_meter_trtcm_*`) — same RFC algorithms in software; `examples/qos_meter` (binary `dpdk-qos_meter`, can run on net_null/net_ring pairs).
  - `lib/sched` (`rte_sched_port_*`, hierarchical port→subport→pipe→TC→queue scheduler with WRR, token buckets, RED/PIE) — `examples/qos_sched`; `qos_framework.rst` has the reference diagrams.
  - A JS token-bucket animation (tokens accumulating at CIR, bucket depth CBS/EBS, packets colored green/yellow/red) is the best way to make srTCM/trTCM intuitive.

### 2.13 PTP / timesync / timestamps
- API: `rte_eth_timesync_enable/disable`, `rte_eth_timesync_read_rx_timestamp(port, &ts, flags)` (flags = timesync index from mbuf), `read_tx_timestamp`, `adjust_time(delta_ns)`, `adjust_freq(ppm)` (stable 26.11), `read_time`, `write_time`; `rte_eth_read_clock()` (raw device clock, used with `RTE_ETH_RX_OFFLOAD_TIMESTAMP` dynamic field `rte_mbuf_dynfield_timestamp`). Rx PTP packets flagged `RTE_MBUF_F_RX_IEEE1588_PTP/TMST`; Tx request with `RTE_MBUF_F_TX_IEEE1588_TMST`.
- PTP message flow (Sync, Follow_Up, Delay_Req, Delay_Resp; offset = ((t2−t1) − (t4−t3))/2) — `examples/ptpclient` implements a PTP slave with HW timestamps.
- Drivers implementing timesync: axgbe, bnxt, cnxk, dpaa, dpaa2, hns3, intel (igb/ixgbe/i40e/ice/iavf/igc), ngbe, txgbe — **none built here**. `read_clock` is implemented by af_xdp and pcap here.
- **New in 26.11**: `examples/ptp_tap_relay_sw` (`doc/guides/sample_app_ug/ptp_tap_relay_sw.rst`) — PTP transparent clock between a NIC and a TAP using **software timestamps** (`clock_gettime`), updating `correctionField` with residence time; uses `lib/net/rte_ptp.h`. On this machine one could run it with a veth/af_packet "NIC" + net_tap, but ptp4l is probably not installed; at minimum walk through its code. A software PTP offset/delay animation (two clocks, four timestamps) is the right visual.

### 2.14 Anatomy of a PMD
Read `drivers/net/null/rte_eth_null.c` top to bottom (it is the canonical teaching PMD):
- Registration: `RTE_PMD_REGISTER_VDEV(net_null, pmd_null_drv)`; `RTE_PMD_REGISTER_PARAM_STRING(net_null, "size=<int> copy=<int> no-rx=0|1")`; probe parses devargs with `rte_kvargs`.
- Probe: `rte_eth_vdev_allocate(dev, sizeof(*internals))` → fills `eth_dev->data` (nb queues, `dev_link`, `mac_addrs`, promiscuous, `dev_flags |= RTE_ETH_DEV_AUTOFILL_QUEUE_XSTATS`) → `eth_dev->dev_ops = &ops` → **chooses burst functions by configuration** (`eth_null_copy_rx/tx` vs `eth_null_no_rx` vs `eth_null_rx/tx`) → `rte_eth_dev_probing_finish()` (fires `RTE_ETH_EVENT_NEW`).
- `static const struct eth_dev_ops ops = {.dev_configure, .dev_start, .dev_stop, .dev_close, .dev_infos_get, .rx_queue_setup, .tx_queue_setup, .*_queue_release, .mtu_set, .link_update, .mac_addr_set, .stats_get, .stats_reset, .reta_update, .reta_query, .rss_hash_update, .rss_hash_conf_get}` — full op list in `ethdev_driver.h:1412` (~150 ops: flow_ops_get, tm_ops_get, mtr_ops_get, timesync_*, hairpin_*, rx_burst_mode_get, get_monitor_addr, cman_*, ...). Missing op ⇒ ethdev returns `-ENOTSUP`.
- `eth_null_rx`: `rte_pktmbuf_alloc_bulk(pool, bufs, n)` then set lengths/port — shows that Rx "allocates" mbufs from *the pool you gave rx_queue_setup*. `eth_null_tx`: counts bytes, `rte_pktmbuf_free_bulk` (Tx frees).
- ring PMD: `rte_eth_from_rings(name, rxrings, n, txrings, n, socket)` — create ports in code from `rte_ring`s; crossing two ports' rings gives an in-memory "cable" (`nics/ring.rst` lines 68-102). Excellent for lifecycle/RX/TX labs with deterministic data.
- Vector paths & path selection:
  - Intel common: `struct ci_rx_path_info {pkt_burst, info, features{rx_offloads, simd_width, scattered, bulk_alloc, flex_desc, single_queue, disabled}}`, `ci_rx_path_select()` (`drivers/net/intel/common/rx.h:257`) picks the widest SIMD path whose supported offloads ⊇ requested offloads, preferring fewer offloads at equal width. ice table: "Scalar", "Scalar Scattered", "Scalar Bulk Alloc", "Vector AVX2", "Vector AVX2 Scattered", "Vector AVX512…". `info` strings surface through `rte_eth_rx_burst_mode_get()`. Lesson: *enabling one offload can silently drop you from AVX512 to scalar*.
  - Max SIMD width limited by EAL `--force-max-simd-bitwidth=64|128|256|512` (`rte_vect_get_max_simd_bitwidth()`); default on x86 is 256 → AVX-512 paths need explicit 512.
  - **Runnable here [verified]** with virtio_user ↔ net_vhost (two processes):
    - default: Rx/Tx burst mode "Scalar" / "Scalar in order", `use_vec: rx-0 tx-0`, `use_inorder: rx-1 tx-1`.
    - `in_order=0,mrg_rxbuf=0,vectorized=1` → `use_vec: rx-1` (split-ring vectorized Rx, SSE).
    - `packed_vq=1,in_order=1,mrg_rxbuf=0,vectorized=1` + EAL `--force-max-simd-bitwidth=512` → **"Vector packed ring"**, `use_vec: rx-1 tx-1` (AVX-512 `virtio_rxtx_packed_avx.h`).
    - `packed_vq=1` → "Scalar mergeable packed ring" / "Scalar packed ring".
    Use `show rxq info 0 0`, `show txq info 0 0`, `show port info 0` (private dump) in testpmd.
- Feature matrix: `doc/guides/nics/features.rst` defines each feature (and which API/mbuf fields it implies); `features/<pmd>.ini` per driver (tap: rte_flow items eth/ipv4/ipv6/tcp/udp/vlan, actions drop/passthru/queue/rss; af_packet: promisc, MTU, per-queue stats; vhost: free Tx mbuf on demand, queue status event, xstats). `doc/guides/nics/overview.rst` renders the big table — a good "how to choose a NIC/PMD" lesson.

### 2.15 Advanced extras (pointers)
- Hairpin queues (`rte_eth_rx/tx_hairpin_queue_setup`, bind/unbind; stable 26.11) — NIC loops packets Rx→Tx without CPU.
- Shared Rx queue (`RTE_ETH_DEV_CAPA_RXQ_SHARE`, `rxconf.share_group`), testpmd `shared_rxq` fwd mode.
- Mbuf recycling `rte_eth_recycle_mbufs()` (stable 26.11): moves freed Tx mbufs directly into Rx ring refill, bypassing mempool; testpmd `recycle_mbufs` fwd mode.
- Rx interrupts: `intr_conf.rxq=1`, `rte_eth_dev_rx_intr_enable/ctl_q` (tap, virtio, vhost, failsafe support) — l3fwd-power. Power-management monitor: `rte_eth_get_monitor_addr` (af_xdp, ring, vhost, virtio here) → `rte_power_monitor` (UMWAIT).
- Avail threshold event `RTE_ETH_EVENT_RX_AVAIL_THRESH`, congestion management `rte_eth_cman_*`.
- Bonding (`net_bonding` vdev: modes round-robin, active-backup, balance, 802.3ad, TLB, ALB; `examples/bond`) and failsafe — PMDs composed of PMDs; both raise LSC.
- IP reassembly offload, MACsec/inline IPsec (`rte_security`), aggregated ports (`rte_eth_dev_count_aggr_ports`, `map_aggr_tx_affinity`).
- Module EEPROM (26.11): `rte_eth_dev_get_module_info/eeprom` + `rte_eth_module_eeprom_parse()` (SFF-8079/8472/8436/8636), telemetry `/ethdev/module_eeprom`.

---

## 3. Runnable example ideas for THIS machine (all verified unless noted)

Common EAL args: `--no-pci --no-huge -m 128 --file-prefix=ch05<x> -l 0[-1]`. testpmd **needs `--total-num-mbufs=8192`** (default pool of 155456 mbufs fails with `-m 256`: "Creation of mbuf pool for socket 0 failed: Cannot allocate memory") **[verified]**. Feed testpmd commands with `-i < cmds.txt` (deterministic) rather than `--cmdline-file` (which runs concurrently with auto-start). Non-interactive testpmd exits immediately on stdin EOF ("Press enter to exit"); keep it alive with `sleep N | dpdk-testpmd ...` or `--stats-period`.

1. **Port explorer** (`lifecycle.c`): `--vdev=net_null0 --vdev=net_ring0 --vdev=net_tap0,iface=ch05tapX`; prints dev_info/capabilities, shows dummy rx before start (stack dump!), configure/-EBUSY when started, link string, RETA update/query, MTU set, promisc, stats/xstats, rx after stop. ~0.1s.
2. **Minimal forwarding loop** with `rte_eth_from_rings` (two ports cross-wired) or `--vdev=net_null0 --vdev=net_null1`; measure cycles/packet with `rte_rdtsc`, vary burst size 1..64 and plot (burst amortization visual). Compare to testpmd io fwd (~40 Mpps on null).
3. **Kernel ↔ DPDK via TAP** (`taprx.c`): start app with `--vdev=net_tap0,iface=ch05tapN`, then `ip addr add 10.57.0.1/24 dev ch05tapN; ip neigh replace 10.57.0.2 lladdr 02:11:22:33:44:55 dev ch05tapN nud permanent`, send UDP with python; app prints ptype `L2_ETHER L3_IPV4 L4_UDP` and checksum flags. Toggle `PROMISC=1` env to demonstrate the promiscuous pitfall and `CK=1` for RX checksum offload flags (0x0 → 0x180). The tap interface disappears when the app exits (no cleanup needed).
4. **TX checksum offload proof** (`txoff.c` + `cap.py`): DPDK sends a UDP packet with zeroed checksums + offload flags on tap; `python3 -I cap.py ch05tapN 5` (AF_PACKET) verifies IP/UDP checksums valid on the kernel side. Extend with `rte_gso_segment` to show software TSO (3000B → 3 segments).
5. **testpmd verbose RX** (`set fwd rxonly`, `set verbose 1`, `start`) on tap: decoded mbuf dumps (src/dst, ptype hw/sw, l2/l3/l4_len, ol_flags). Also `csum` fwd mode + `csum set ip hw 0`.
6. **Events lab** (`evt.c`): hotplug `rte_dev_probe("net_null7")` → NEW; vhost + external virtio_user testpmd → QUEUE_STATE/LSC up/down; remove → DESTROY.
7. **virtio_user ↔ vhost two-process lab** (real descriptor rings in shared memory!): process A `dpdk-testpmd --file-prefix=ch05vh -l 2-3 --vdev=net_vhost0,iface=$PWD/vh.sock,queues=2 -- --total-num-mbufs=16384 --rxq=2 --txq=2 --forward-mode=macswap --stats-period=5`; process B `dpdk-testpmd --file-prefix=ch05vu -l 0-1 --vdev=virtio_user0,path=$PWD/vh.sock,queues=2 -- -i --total-num-mbufs=16384 --rxq=2 --txq=2`, `start tx_first`, `show port xstats 0` (per-queue size histograms). Must be **two processes** — in a single process the virtio_user probe runs before the vhost socket exists ("connect error") **[verified]**. Then the vector-path matrix (§2.14).
8. **af_packet / af_xdp on a veth pair**: `ip link add ch05va type veth peer name ch05vb; ip link set ch05va up; ip link set ch05vb up`; `--vdev=net_af_packet0,iface=ch05va --vdev=net_af_xdp0,iface=ch05vb,start_queue=0,queue_count=1`; `start tx_first` → packets ping-pong between ports (32 sent, counters move) **[verified]**; af_xdp logs "No bpffs … Falling back to loading single prog" (fine). Delete the veth afterwards.
9. **RSS math lab** (`rss.c`, pure software): Toeplitz test vector, symmetric key, RETA distribution histogram; then real `rte_eth_dev_rss_reta_update` on net_null and `/ethdev/rss_info` via telemetry; testpmd `port config 0 rss reta (0,1),(1,0)` etc.
10. **Telemetry dashboard**: background testpmd (`--file-prefix=ch05tel`) + `printf '/ethdev/stats,0\n' | dpdk-telemetry.py -f ch05tel` in a loop → JSON → chart pps over time.
11. **Rx/Tx callbacks**: latency stamping like `examples/rxtx_callbacks` (`dpdk-rxtx_callbacks --vdev=net_ring0 --vdev=net_ring1` or null pair — not run, should work) — rx callback timestamps (`rte_rdtsc`) into a dynfield, tx callback computes cycles.
12. **rte_flow validate lab** (`flow_validate_cmds.txt` on net_tap, 2 queues): see good/bad rules with error types; write the same rules in C with `rte_flow_validate` and print `error.type/message` and the offending item index (`(item*)error.cause - pattern`). Also show the default mask via `rte_flow_conv(RTE_FLOW_CONV_OP_ITEM_DEFAULT_MASK_PTR, ...)` (26.11).
13. **Software meter** with `lib/meter` srTCM on a synthetic packet stream (no NIC needed), plot colors vs time; compare with rte_mtr API calls returning `-ENOTSUP` on null (teaches capability checking).
14. **Burst-mode / vector path detection**: print `rte_eth_rx_burst_mode_get()` for virtio_user under the four devarg combos; vary `--force-max-simd-bitwidth`.

Cleanup rules: unique iface names prefixed `ch05`; tap ifaces vanish with the process; delete veths; `rm` vhost sockets.

---

## 4. Visualization / animation ideas

1. **Port state machine** (SVG, clickable): states unconfigured/configured/started/stopped/closed; clicking an API call animates transition or shows the error (e.g. configure while started → `-EBUSY`); show `rte_eth_fp_ops[port]` pointer flipping between `dummy_eth_rx_burst` and `eth_null_rx` on start/stop.
2. **fp_ops call path**: app `rte_eth_rx_burst(0,2,...)` → `rte_eth_fp_ops[0]` (two cache-line boxes) → `rxq.data[2]` → PMD function → optional callback chain → return. Highlight that it's one array lookup + indirect call (why it's fast).
3. **Rx descriptor ring animation** (the centerpiece): circular ring of N descriptors with two pointers (NIC head, SW tail/rx_tail); NIC DMA writes packets & sets DD (color change); `rx_burst(32)` sweeps DD descriptors, swaps mbufs with fresh ones from a mempool (show mempool level), batches tail-register write when nb_hold > rx_free_thresh; slider for incoming rate vs poll rate → ring fills → `imissed` counter increments. Toggle "vector mode": processes 4/8 descriptors per step with a SIMD lane highlight, rearm in 64-chunks.
4. **Tx ring animation**: app enqueues, RS bit every tx_rs_thresh, NIC writes DD only on RS descriptors, lazy free when free count < tx_free_thresh; show what happens to the unsent tail of a burst when the ring is full (the leak).
5. **Burst amortization chart**: cycles/packet vs burst size (fixed cost per call + per-packet cost) — real data from example 2.
6. **RSS pipeline**: packet 5-tuple → bit-level Toeplitz (show the 32-bit sliding window over the key and XOR when input bit = 1) → 32-bit hash → low 7 bits → RETA (128 cells colored by queue) → queue/lcore. Interactive: edit RETA cells (drag to rebalance), toggle symmetric key and watch fwd/rev flows land on the same queue; histogram of 10k flows.
7. **Offload "who does what" diagram**: mbuf fields (`ol_flags`, l2/l3/l4_len, tso_segsz) → `tx_prepare` → PMD context descriptor → NIC computes checksum/segments; animate a 3000B TCP packet splitting into 3 × 1000B segments with header replication & checksum recalculation. Rx side: NIC sets flags, app reads `RTE_MBUF_F_RX_*_CKSUM_GOOD/BAD/UNKNOWN`.
8. **Per-port vs per-queue offloads** Venn diagram (port capa = per-queue capa ∪ pure per-port capa) with rules from ethdev.rst.
9. **rte_flow rule builder & matcher**: drag items (ETH/IPV4/UDP/VXLAN...) into a pattern stack, edit spec/mask/last with live "matches ??:??:01:02:03:??" view; actions; run a stream of synthetic packets through groups (0 → JUMP → 1) with priorities; show isolate mode (unmatched packets vanish instead of going to RSS). Show validate error pointing at the offending item (`cause`).
10. **Sync vs async flow insertion**: timeline comparison — sync create = blocking round trip per rule; async = enqueue many on flow queue, `push` once, `pull` completions later (with user_data tokens).
11. **Token bucket meter (srTCM/trTCM)**: two buckets filling at CIR/PIR, packets arrive with sizes, colored green/yellow/red; policy maps colors to actions.
12. **TM hierarchy tree**: port → subports → pipes → TCs → queues (leaves = Tx queues 0..N-1); SP between priorities, WFQ among equal priority by weight; shaper rates on nodes; animate packets being dequeued respecting priorities/weights.
13. **PTP exchange**: sequence diagram with t1..t4 and a slider for path delay/offset; correctionField for transparent clock (ptp_tap_relay_sw).
14. **PMD anatomy map**: `RTE_PMD_REGISTER_VDEV` → probe → `rte_eth_vdev_allocate` → fill data/dev_ops → choose rx/tx burst (decision tree like `ci_rx_path_select` or the virtio path table) → `rte_eth_dev_probing_finish` → NEW event. Show the virtio path decision tree with devargs toggles and resulting "Burst mode" string.
15. **Event flow**: interrupt thread vs datapath lcores — LSC/QUEUE_STATE from vhost connecting, callbacks on control thread.
16. **Stats layers**: NIC counters (imissed, ierrors) vs PMD counters (rx_nombuf) vs app counters (testpmd fwd stats) — Sankey of where packets are counted/dropped (explains the testpmd flush discrepancy).

---

## 5. Common pitfalls (for "gotcha" boxes)

1. Calling rx/tx before `rte_eth_dev_start` or after stop → silently 0 packets (dummy fp ops log once with a stack dump).
2. Not freeing the unsent tail of `rte_eth_tx_burst` → mbuf leak → pool exhaustion → `rx_nombuf` grows, Rx stops.
3. Mempool too small: must cover `nb_rxq*nb_rxd + nb_txq*nb_txd + nb_lcores*(cache+burst)`; Rx rings are pre-filled at setup/start.
4. Two lcores polling the same queue (data race; no locks inside PMDs) unless MT_LOCKFREE (Tx only).
5. Requesting offloads not in capa → configure fails; enabling per-port offload only in queue conf → error; not masking `rss_hf` with `flow_type_rss_offloads` → configure fails; **26.11**: RSS mq_mode with >1 queue on a PMD without RSS is now rejected.
6. TX checksum offload without enabling the port offload, without setting l2_len/l3_len, or without the pseudo-header checksum (use `rte_eth_tx_prepare`).
7. MTU larger than mbuf data room without SCATTER; jumbo needs MULTI_SEGS on Tx.
8. Forgetting promiscuous mode on TAP / real NICs in labs (frames to other MACs dropped).
9. Expecting LSC callbacks from TAP (never fired) — poll link instead, or use vhost/bonding/pcap.
10. testpmd defaults: huge default mbuf pool (use `--total-num-mbufs`), Rx flush at start inflates PMD counters (`--no-flush-rx`), promisc on, non-interactive exits on stdin EOF.
11. `rte_eth_link_get()` can block ~9 s; use `_nowait` in loops.
12. Vector paths silently disabled by an offload, non-power-of-2 ring, burst < 32 / not multiple of 4, or default `--force-max-simd-bitwidth` (256 on x86 → no AVX-512).
13. rte_flow: same-priority overlapping rules → undefined; rules outside group 0 are never hit without JUMP; validate ≠ guaranteed create (resources may run out); rules may be dropped on port restart unless `FLOW_RULE_KEEP`; isolate mode must be set early; MARK needs `rte_eth_rx_metadata_negotiate` before configure; `rte_flow_configure` must be called before start.
14. Removing Rx/Tx callbacks while datapath runs → use-after-free (wait for quiescence / RCU).
15. API drift: `RTE_ETH_` prefix rename (21.11, old `ETH_` names gone), `rxmode.max_rx_pkt_len` → `rxmode.mtu` (21.11), `rte_eth_dev_get_name_by_port(port,name,size)` (26.11), queue stats mapping removed (26.11). Old blog/StackOverflow code will not compile on 26.11.
16. Multi-process: `rte_eth_dev_data` is shared but `rte_eth_devices`/fp_ops are per process; only primary configures ports.
17. Concurrent DPDK processes on this machine need unique `--file-prefix`; vhost-user requires two processes (or server/client ordering).

---

## 6. Suggested chapter skeletons (for the planner)

- **Ch A: "Your first port"** — discovery, dev_info, lifecycle state machine, rx/tx burst, mbuf ownership, fp_ops & dummy functions. Labs 1, 2. Visuals 1, 2, 5.
- **Ch B: "Rings and descriptors: how a PMD moves packets"** — descriptor formats, DD/tail, thresholds, virtio split/packed rings, vhost two-process lab, descriptor status APIs. Lab 7. Visuals 3, 4.
- **Ch C: "Port control, stats and events"** — link/MAC/promisc/MTU/ptypes, stats/xstats/telemetry, event callbacks, rx/tx callbacks, hotplug. Labs 3, 6, 10, 11. Visuals 15, 16.
- **Ch D: "Hardware offloads"** — capability model, Rx checksum flags, Tx checksum/TSO/tx_prepare, VLAN, scatter, buffer split/selective Rx, fast free. Labs 4, 5. Visuals 7, 8.
- **Ch E: "Multi-queue and RSS"** — mq_mode, Toeplitz, RETA, symmetric RSS, queue-per-lcore design. Lab 9. Visual 6.
- **Ch F: "rte_flow"** — model, items/actions, spec/mask/last, groups/priorities/jump, validate/create/query, errors, isolate, MARK, transfer/representors, flow_graph parser; async/template API. Lab 12. Visuals 9, 10.
- **Ch G: "QoS: metering and traffic management"** — rte_mtr, rte_tm concepts + lib/meter, lib/sched runnable. Lab 13. Visuals 11, 12.
- **Ch H: "Inside a PMD + vector paths + time sync"** — null PMD walkthrough, eth_dev_ops, devargs, path selection (ci_rx_path_select, virtio table), SIMD width, features matrix, PTP/timesync & ptp_tap_relay_sw. Labs 7 (vector matrix), 14. Visuals 13, 14.

---

## 7. Source references

Local (authoritative, 26.11.0):
- `doc/guides/prog_guide/ethdev/ethdev.rst` (PMD design, queues, thresholds, offload model, xstats, reset/recovery, module EEPROM)
- `doc/guides/prog_guide/ethdev/flow_offload.rst` (4641 lines: rule model §25-288, matching §289, items §403-1550, actions §1553-3380, management §3398-3610, engine config/templates/async §3610-4200, isolate §4200, errors §4266, PMD interface §4467)
- `doc/guides/prog_guide/ethdev/flow_graph.rst` (new 26.11)
- `doc/guides/prog_guide/ethdev/traffic_management.rst`, `traffic_metering_and_policing.rst`, `qos_framework.rst`, `switch_representation.rst`
- `doc/guides/nics/{null,ring,tap,virtio,vhost,af_packet,af_xdp,memif,pcap,fail_safe,features,overview}.rst`, `doc/guides/nics/features/*.ini`
- `doc/guides/sample_app_ug/{skeleton,l2_forward_real_virtual,rxtx_callbacks,link_status_intr,flow_filtering,ptpclient,ptp_tap_relay_sw,qos_metering,qos_scheduler}.rst`
- `doc/guides/testpmd_app_ug/testpmd_funcs.rst` (flow, tm, mtr, rss commands)
- `doc/guides/rel_notes/release_17_02.rst` (rte_flow), `release_21_11.rst` (fp_ops, RTE_ETH_ rename), `release_22_03.rst` (flow templates/async), `release_26_07.rst` (selective Rx), `release_26_11.rst` (stable flow/mtr API, mq validation, queue-stats-mapping removal, get_name_by_port size, module EEPROM decode, flow_graph, conv ops)
- Code: `lib/ethdev/rte_ethdev.h:6183` (rx_burst inline), `:6522` (tx_burst), `:6639` (tx_prepare), `lib/ethdev/rte_ethdev_core.h` (fp_ops), `lib/ethdev/ethdev_private.c:199-300`, `lib/ethdev/rte_ethdev.c:1330/1834/1862/1937/2359`, `lib/ethdev/ethdev_driver.h:63` (`rte_eth_dev`), `:1412` (`eth_dev_ops`), `drivers/net/null/rte_eth_null.c`, `drivers/net/tap/rte_eth_tap.c:720-815` (tx incl. TSO/GSO), `:1221` (link_update), `:1905` (netlink LSC handler without callback_process), `drivers/net/intel/common/rx.h:139-330`, `drivers/net/intel/ice/ice_rxtx.c:2741, 3272`, `lib/hash/rte_thash.h:193` (`rte_softrss`), `lib/gso/rte_gso.c`.

Web:
- [1] Adrien Mazarguil, "[PATCH v4 01/25] ethdev: introduce generic flow API", dpdk-dev, Dec 2016 — https://mails.dpdk.org/archives/dev/2016-December/052803.html
- [2] "doc: update release notes for rte_flow" (17.02) — https://patches.dpdk.org/project/dpdk/patch/1482501605-13741-1-git-send-email-adrien.mazarguil@6wind.com/
- [3] RFC v2 "Generic flow director/filtering/classification API" (design rationale discussion, Aug/Oct 2016) — https://mails.dpdk.org/archives/dev/2016-August/045383.html
- Microsoft RSS Toeplitz verification vectors ("Verifying the RSS Hash Calculation", Windows driver docs) — the 0x51ccc178 value reproduced above.
- Woo & Park, "Scalable TCP Session Monitoring with Symmetric Receive-side Scaling" (KAIST tech report, 2012) — origin of the 0x6d5a repeated symmetric key.

## 8. Open items for chapter authors
- TAP TSO path rejected a valid TSO mbuf in our test (see §2.9); re-check or teach TSO with `rte_gso_segment`.
- No PMD here can *install* rte_flow rules, TM hierarchies, meters or PTP — teach via validate, ENOTSUP-aware code, software libraries (`lib/meter`, `lib/sched`, `rte_thash`, `rte_gso`) and JS simulations; be explicit with learners that results on real NICs (ice/mlx5) differ.
- `examples/rxtx_callbacks`, `qos_meter`, `flow_filtering` binaries exist in `$DPDK_SRC/build/examples` but were not run here; verify args with null/ring vdevs before embedding.

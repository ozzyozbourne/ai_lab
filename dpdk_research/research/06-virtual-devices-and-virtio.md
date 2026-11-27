# Research note 06 — Virtual & software PMDs, vhost/virtio, testing without hardware, testpmd, packet capture

Target: DPDK 26.11.0 (source tree `$DPDK_SRC`, build at `$DPDK_SRC/build`). Everything marked **[verified]** was
actually run on this course machine (4-core VM, single virtio NIC eth0 that must never be touched) during
research; numbers are from that VM and only meant as orders of magnitude.

Helper scripts produced during research (copies in `/home/user/ai_lab/dpdk_research/research/06-examples/`):
- `/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/ch06tools/sendraw.py` — send N raw UDP frames on a kernel interface via `AF_PACKET` (there is **no ping, tcpdump, tshark or scapy** on this machine; Python3 + raw sockets is the traffic source).
- `.../ch06tools/mkpcap.py` — write a classic libpcap file with N UDP frames (4 source IPs, 8 source ports) for `net_pcap`.
- `.../ch06tools/pcapng_dump.py` — minimal pcapng block walker (SHB/IDB/EPB/ISB) to inspect `dpdk-dumpcap` output without tshark.
- `.../ch06c/ringeth.c` — `rte_eth_from_rings()` + `rte_vdev_init()` demo (compiles & runs).
- `.../ch06c/vhostapp.c` — raw `librte_vhost` echo backend talking to a `virtio_user` testpmd (compiles & runs).

---

## 1. Big picture: why software PMDs exist

A "PMD" is just a driver that fills the `struct rte_eth_dev` ops table (`dev_ops`) and the fast-path
function pointers `rx_pkt_burst` / `tx_pkt_burst` (`lib/ethdev/ethdev_driver.h`). Nothing requires real hardware
behind them. DPDK ships many **virtual devices (vdevs)** registered on the **vdev bus**
(`drivers/bus/vdev/`, `RTE_PMD_REGISTER_VDEV(name, drv)`, created with EAL `--vdev=<name>[,k=v...]` or at runtime
with `rte_vdev_init(name, args)` / `rte_dev_probe("name,args")` / testpmd `port attach`).

Categories (good chapter structure):

| Category | PMDs | Backing object | Typical use |
|---|---|---|---|
| Pure software sinks/sources | `net_null` | nothing (alloc/free mbufs) | max-speed sanity tests, benchmarking the app itself |
| In-process plumbing | `net_ring` | `rte_ring` | wire ports together in one process, pipelines, unit tests |
| Kernel-interfacing | `net_tap`/`net_tun`, `net_af_packet`, `net_af_xdp`, `net_pcap` (iface mode), `virtio_user`+vhost-kernel | kernel netdev / socket | exception path, testing with kernel tools, no-NIC environments, containers |
| File-based | `net_pcap` (`rx_pcap`/`tx_pcap`) | libpcap files | deterministic replay, regression tests, capture |
| Inter-process shared memory | `net_memif`, `net_vhost` ↔ `virtio_user` | shared memory + unix socket | container/VM/process networking, CNFs, VPP interop |
| Composite / meta PMDs | `net_bonding`, `net_failsafe` | other ethdev ports | link aggregation, HA, hot-plug |
| Para-virtual (VM guest) | `net_virtio` (PCI) | virtio-net device in QEMU | DPDK inside a VM; **eth0 on this machine is one — never bind it** |
| Host side of virtio | `librte_vhost` (+ `net_vhost` wrapper), vDPA, VDUSE | guest memory mapped via fds | OVS-DPDK, vSwitches, VM backends |

Key teaching idea: **the application code is identical** regardless of which PMD is behind the port. Show the same
`skeleton`-like forwarding loop running on null, ring, tap, pcap, af_packet, memif, vhost/virtio_user.

---

## 2. Per-PMD deep dive (with exact args from `RTE_PMD_REGISTER_PARAM_STRING`)

### 2.1 net_null — `drivers/net/null/rte_eth_null.c`, doc `doc/guides/nics/null.rst`
- Args: `size=<int>` (default 64), `copy=<0|1>`, `no-rx=<0|1>` (`/dev/null` behaviour; incompatible with copy).
- RX (`eth_null_rx`): `rte_pktmbuf_alloc_bulk()` nb_bufs mbufs, sets `data_len=pkt_len=size`, `port`; **never
  touches data** (contents = whatever was in the mempool; zeros on first use). TX (`eth_null_tx`): frees mbufs, counts.
  `copy=1` variants memcpy to/from a dummy buffer to emulate memory traffic.
- Always "link up", infinite RX → RX returns as many packets as asked as long as the mempool has mbufs. Great
  for showing "mempool exhaustion = RX returns 0".
- **[verified]** `dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=X --vdev=net_null0 --vdev=net_null1 -- --tx-first --stats-period 2 --total-num-mbufs=8192` → ~55 Mpps per port on one core (io forwarding).

### 2.2 net_ring — `drivers/net/ring/rte_eth_ring.c`, `rte_eth_ring.h`, doc `nics/ring.rst`
- RX = `rte_ring_dequeue_burst`, TX = `rte_ring_enqueue_burst` (pointer passing, zero copy, no data touched).
- `--vdev=net_ring0` creates a port whose TX ring is its own RX ring (loopback); arg `nodeaction=name:node:ATTACH|CREATE`.
- C API: `rte_eth_from_rings(name, rx_rings[], nb_rx, tx_rings[], nb_tx, numa)`, `rte_eth_from_ring(r)`.
  Cross-wiring two ports (A tx→R0→B rx, B tx→R1→A rx) yields a "virtual cable".
- **[verified]** `ringeth.c`: port names become `net_ring_ringA`/`net_ring_ringB` (the PMD prefixes `net_ring_`);
  after `rte_eth_tx_burst(A)` `rte_ring_count(R0)==8`, `rte_eth_rx_burst(B)` returns them in order.
- **[verified]** testpmd 2×net_ring io fwd: ~163 Mpps (pure pointer moves). Note: **Rx-bps shows 0** — the ring PMD
  counts packets only, not bytes (good "stats are driver-defined" pitfall).
- Doc notes ring PMD is slower than calling `rte_ring_*` directly (function-pointer indirection vs inlining).
- API pitfall in 26.11: `rte_eth_dev_get_name_by_port(port, name, size)` now takes a **size** argument.

### 2.3 net_tap / net_tun — `drivers/net/tap/` (rte_eth_tap.c, tap_flow.c, tap_netlink.c, tap_tcmsgs.c, bpf/), doc `nics/tap.rst`
- Opens `/dev/net/tun` with `IFF_TAP|IFF_NO_PI` (or `IFF_TUN|IFF_POINTOPOINT` for `net_tun`), `IFF_MULTI_QUEUE`:
  **one fd per queue**; RX = `readv()`, TX = `writev()` → one syscall per packet (slow, ~1 Mpps class), but the
  kernel sees a normal netdev (`ip`, `ethtool`, tcpdump work).
- Args: `iface=<name>` (default `dtapN`), `mac=fixed|xx:..`, `remote=<netdev>` (TC redirect of a kernel netdev's
  traffic into the tap), `persist`. `net_tun` takes only `iface`.
- rte_flow support is implemented by translating to TC flower rules (`tap_flow.c`); RSS action via an eBPF program.
- Same number of RX and TX queues required (fd per queue pair). Secondary processes can attach (max 8 queues shared).
- **[verified]** `--vdev=net_tap0,iface=ch06tap0`, `ip link set ch06tap0 up`, `python3 sendraw.py ch06tap0 1000` →
  testpmd rxonly counts exactly 1000. The interface shows up PROMISC when testpmd starts.
- Use for: exception path to kernel, quick "talk to Linux" demos. KNI's replacement candidate #1.

### 2.4 net_af_packet — `drivers/net/af_packet/rte_eth_af_packet.c`, doc `nics/af_packet.rst`
- Uses `AF_PACKET` + `PACKET_MMAP` (TPACKET_V2 rings shared with kernel; RX via polling frame status, TX via
  `sendto()` kick). Args: `iface` (required), `qpairs`, `blocksz` (4096), `framesz` (2048, multiple of 16, must fit
  in a block), `framecnt` (512), `qdisc_bypass` (default on), `fanout_mode=hash|lb|cpu|rollover|rnd|qm`,
  `ignore_outgoing` (new in 26.11). Multi-seg RX with scatter added in 26.03. RX timestamp offload & VLAN reinsertion.
- Works on **any** kernel netdev → on this machine use a **veth pair** (never eth0).
- **[verified]** `ip link add ch06va type veth peer name ch06vb; ip link set ch06va up; ip link set ch06vb up` →
  `--vdev=net_af_packet0,iface=ch06va` rxonly; `sendraw.py ch06vb 5000` → RX-packets 5000.
- Viz idea: PACKET_MMAP ring of frames with `tp_status` flipping between TP_STATUS_KERNEL / TP_STATUS_USER.

### 2.5 net_af_xdp — `drivers/net/af_xdp/rte_eth_af_xdp.c`, doc `nics/af_xdp.rst`, howto `howto/af_xdp_dp.rst`
- AF_XDP socket (XSK) bound to one netdev queue; four rings: **fill**, **RX**, **TX**, **completion**, over a **UMEM**
  (DPDK maps the mbuf mempool memory as UMEM → zero-copy into mbufs when driver supports it). An XDP program
  (default from libxdp/libbpf; custom via `xdp_prog=`) does `bpf_redirect_map(xskmap)`.
- Args: `iface` (req), `start_queue`, `queue_count`, `shared_umem`, `xdp_prog`, `busy_budget` (busy-poll, kernel ≥5.11, `0` disables), `force_copy`, `use_cni`, `use_pinned_map`, `dp_path` (AF_XDP K8s device plugin), `mode=drv|skb|hw` (XDP attach mode), rx-timestamp metadata offsets (26.11).
- This build: libxdp 1.4.2, libbpf 1.3.0. **[verified]** works on veth `ch06va` (generic/native XDP on veth, copy
  mode); libxdp warns "No bpffs found at /sys/fs/bpf … Falling back to loading single prog without dispatcher" —
  harmless; explain what the dispatcher is (multi-prog chaining). 5000/5000 packets received.
- Only traffic landing on the bound queue reaches the socket (use `ethtool -L … combined 1` or flow steering on real NICs).
- Positioning: kernel keeps the NIC driver (no unbinding, no VFIO), packets bypass the stack → "middle ground" between AF_PACKET and a native PMD; KNI-replacement and container-friendly (K8s CNI plugin).

### 2.6 net_pcap — `drivers/net/pcap/pcap_ethdev.c` (+ `pcap_osdep_*.c`), doc `nics/pcap.rst`
- Streams: `rx_pcap=file`, `tx_pcap=file`, `rx_iface=`, `rx_iface_in=`, `tx_iface=`, `iface=`; one queue per stream arg.
  Options: `infinite_rx=1` (loop file, packets pre-loaded into mbufs → benchmark source), `eof=1` (link down + LSC event at EOF, new-ish), `phy_mac=1`, `snaplen=` (must precede stream args).
  No tx stream → tx drop queue; no rx stream → dummy rx queue.
- tx_pcap files are written with the **nanosecond pcap magic `0xa1b23c4d`** **[verified]**.
- **[verified, important pitfall]** `--vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=out.pcap` + testpmd io fwd → **0 packets**.
  Cause: testpmd `flush_fwd_rx_queues()` (app/test-pmd/testpmd.c) drains RX queues at `start`, eating the whole
  100-packet file. Fix: `--no-flush-rx`. With `--forward-mode=macswap --port-topology=loop --no-flush-rx` 100 in / 100
  out and out.pcap shows dst/src swapped.
- **[verified]** `infinite_rx=1` rxonly: ~68 Mpps (no I/O, replays pre-built mbufs).
- `dpdk-pdump` (legacy) writes via net_pcap.

### 2.7 net_memif — `drivers/net/memif/` (memif.h = wire protocol, memif_socket.c, rte_eth_memif.c), doc `nics/memif.rst`
- Origin: FD.io VPP's shared-memory interface (libmemif); DPDK PMD since 19.08 → DPDK ↔ VPP ↔ libmemif interop.
- Roles: **server** (listens on a unix socket, consumer of shm) vs **client** (connects, *creates* the shared memory
  regions — rings + buffers — and passes fds). Control messages: HELLO → INIT → ACK → ADD_REGION(+ACK)… → ADD_RING(+ACK)… → CONNECT → CONNECTED; DISCONNECT anytime.
- Rings are C2S (client→server) and S2C; descriptor = {flags(NEXT), region, length, offset, metadata}; buffers
  `bsize` (2048), ring size `2^rsize` (rsize=10). Zero-copy client mode (`zero-copy=yes`, needs `--single-file-segments`) exposes DPDK memory directly.
- Args: `id`, `role=server|client`, `bsize`, `rsize`, `socket` (default `/tmp/memif.sock`), `socket-abstract=yes|no` (default **abstract namespace** — no filesystem entry!), `owner-uid/gid`, `mac`, `secret` (not security), `zero-copy`.
- Cannot connect two memif interfaces in the same process.
- **[verified]** two testpmds, both `--no-huge` (copy mode works without hugepages):
  server `--vdev=net_memif0,role=server,socket=/run/ch06memif.sock,socket-abstract=no` rxonly (lcores 0-1),
  client same socket `role=client` txonly (lcores 2-3) → ~19 Mpps tx, ~9–19 Mpps rx.

### 2.8 net_bonding — `drivers/net/bonding/` (rte_eth_bond_pmd.c, _api.c, _8023ad.c, _alb.c, _args.c, _flow.c, bonding_testpmd.c), header `rte_eth_bond.h`, doc `prog_guide/link_bonding_poll_mode_drv_lib.rst`, example `examples/bond`
- Modes: 0 ROUND_ROBIN, 1 ACTIVE_BACKUP, 2 BALANCE (xmit_policy l2/l23/l34), 3 BROADCAST, 4 8023AD (LACP; app must call rx/tx at <100 ms intervals and tx burst ≥ 2×members; optional dedicated queues), 5 TLB, 6 ALB.
- Args: `member=` (repeatable; older name `slave` removed — terminology changed in 23.11), `primary=`, `mode=`, `xmit_policy=`, `agg_mode=count|stable|bandwidth`, `socket_id`, `mac`, `lsc_poll_period_ms`, `up_delay`, `down_delay`.
- API: `rte_eth_bond_create`, `rte_eth_bond_member_add/remove`, `rte_eth_bond_primary_set`, `rte_eth_bond_mode_set`, `rte_eth_bond_xmit_policy_set`, `rte_eth_bond_link_monitoring_set`, `rte_eth_bond_8023ad_*`.
- Bond config propagates **one way** (bond → members); don't call rx_burst on members directly; RSS RETA size = GCD of members; flows created on every member.
- testpmd plugin commands: `show bonding config <port>`, `set bonding mode`, `add/remove bonding member`, `set bonding primary`, `set bonding lacp dedicated_queues`, `show bonding lacp info`, `create bonding device`.
- **[verified]** `--vdev=net_null0 --vdev=net_null1 --vdev 'net_bonding0,mode=M,member=net_null0,member=net_null1,xmit_policy=l34' -- -i --portmask=0x4 --txonly-multi-flow`, `set fwd txonly`, 2 s (member0 / member1 / bond TX):
  - mode 0: 46.9M / 46.9M / 93.7M (even split)
  - mode 1: 107.9M / 0 / 107.9M (only primary)
  - mode 2 l34 + multi-flow: 40.0M / 40.0M / 79.9M (hash split)
  - mode 3: 39.2M / 39.2M / 78.5M (each packet on both; bond stats = sum of members)
  Without `--portmask` testpmd also forwards on the member ports (confusing stats) — pitfall. Logs show harmless "Failed to disable promiscuous mode … not supported" from null members and "Please remove port 0 from bonding device" at shutdown.
- Viz: packets coloured by flow hash fanned out to members per mode; member link-down → failover animation (mode 1).

### 2.9 net_failsafe — `drivers/net/failsafe/`, doc `nics/fail_safe.rst`
- Wraps 1–2 sub-devices: `dev(<devargs>)`, `exec(<cmd>)` (first output line = devargs), `fd(<n>)`, `mac=`, `hotplug_poll=` (ms, default 2000). Plug-in: absent sub-device is retried periodically; config is replayed when it appears. Plug-out: RMV event → switch TX to the other sub-device.
- Historical driver: Azure/Hyper-V accelerated networking (SR-IOV VF + netvsc synthetic path) — later superseded by the `netvsc` PMD's own VF handling; also generic hot-plug safety.
- Sub-devices are **owned** (`rte_eth_dev_owner_set`) so `RTE_ETH_FOREACH_DEV` hides them — apps must use that macro, not `for (i=0;i<RTE_MAX_ETHPORTS;i++)`.
- **[verified]** `--vdev 'net_failsafe0,dev(net_null0,size=128),dev(net_ring0)'` → testpmd shows only port 0 `net_failsafe0`; TX goes to the preferred (first) sub-device; warnings that sub-device 1 (ring) doesn't support mac_addr_set/promisc.

### 2.10 virtio (guest PMD) — `drivers/net/virtio/` (virtio_ethdev.c, virtio_pci*.c, virtqueue.[ch], virtio_ring.h, virtio_rxtx*.c, virtio_cvq.c), doc `nics/virtio.rst`
- Split virtqueue: descriptor table (`struct vring_desc {addr,len,flags(NEXT|WRITE|INDIRECT),next}`), avail ring (driver→device: idx + ring[]), used ring (device→driver: `{id,len}`). Packed virtqueue (virtio 1.1, `VIRTIO_F_RING_PACKED` bit 34): one descriptor ring with AVAIL/USED flag bits (`VRING_PACKED_DESC_F_AVAIL` bit 7, `_USED` bit 15) + wrap counters + event-suppression structs — fewer cache lines, HW friendly.
- Features: `VIRTIO_NET_F_MRG_RXBUF` (15), `VIRTIO_F_VERSION_1` (32), `VIRTIO_F_IN_ORDER` (35), `VIRTIO_RING_F_INDIRECT_DESC` (28), `VIRTIO_RING_F_EVENT_IDX` (29), `VHOST_USER_F_PROTOCOL_FEATURES` (30), CTRL_VQ (17), MQ, CSUM/TSO...
- Rx/Tx path selection table (split/packed × mergeable × in-order × vectorized; packed vectorized needs AVX512 — this VM has AVX-512): `virtio_recv_pkts`, `virtio_recv_mergeable_pkts`, `virtio_recv_pkts_vec`, `virtio_recv_pkts_inorder`, `virtio_recv_pkts_packed(_vec)`, `virtio_xmit_pkts(_inorder|_packed|_packed_vec)`.
- Headroom must fit `virtio_net_hdr` (10 B) / `_mrg_rxbuf` (12 B) / hash report (20 B).
- Notifications: "kick" (driver→device, eventfd/ioeventfd) and "call" (device→driver irqfd); PMD polls, so kicks suppressed via flags/EVENT_IDX.
- **Machine-specific warning:** eth0 is a virtio-net PCI device (0000:00:08.0). Always `--no-pci`; never `dpdk-devbind`.

### 2.11 virtio_user — `drivers/net/virtio/virtio_user_ethdev.c`, `virtio_user/` (virtio_user_dev.c, vhost_user.c, vhost_kernel.c, vhost_kernel_tap.c, vhost_vdpa.c)
- Reuses the virtio PMD datapath but replaces PCI with a userspace "device emulation" that talks a vhost backend.
  `struct virtio_user_backend_ops` (vhost.h): setup, set_owner, get/set_features, set_memory_table, set_vring_num/base/addr/kick/call, get/set_status, enable_qp, dma_map...
  Backends (`VIRTIO_USER_BACKEND_*`): **VHOST_USER** (unix socket path), **VHOST_KERNEL** (`path=/dev/vhost-net` + tap `iface=`, exception path), **VHOST_VDPA** (`/dev/vhost-vdpa-N`).
- Args: `path`, `mac`, `cq`, `queue_size` (256), `queues`, `iface`, `server`, `mrg_rxbuf` (1), `in_order` (1), `packed_vq` (0), `speed`, `vectorized`.
- Introduced 16.07 for container networking/IPC; howtos `howto/virtio_user_for_container_networking.rst`, `howto/virtio_user_as_exception_path.rst`.
- Memory sharing: only DPDK's own memory segments are sent in SET_MEM_TABLE (max 8 regions → `--single-file-segments`).
- **[verified, doc is outdated]** the howto says virtio-user "cannot work with --no-huge". On 26.11 it **does**: EAL
  backs `--no-huge` memory with `memfd_create("nohuge")` (`lib/eal/linux/eal_memory.c` ~l.1190), so the fd can be
  shared. `virtio_user` `--no-huge -m 128` ↔ `net_vhost` `--no-huge` moved ~17 Mpps. Teach this as "docs lag code".
- `/dev/vhost-net` is **absent** on this VM (vhost_net module not loaded) → vhost-kernel exception-path demo can't run
  here; show it as diagram + use net_tap or vhost-user instead.

### 2.12 librte_vhost — `lib/vhost/` (socket.c, fd_man.c, vhost_user.c, vhost.c, virtio_net.c, iotlb.c, vdpa.c, vduse.c, vhost_crypto.c), headers `rte_vhost.h`, `rte_vdpa.h`, `vdpa_driver.h`, `rte_vhost_crypto.h`; doc `prog_guide/vhost_lib.rst`; examples `examples/vhost`, `vhost_blk`, `vhost_crypto`, `vdpa`
- Control path API: `rte_vhost_driver_register(path, flags)`, `rte_vhost_driver_set_features / enable_features / disable_features`, `rte_vhost_driver_callback_register(path, &ops)` with `struct rte_vhost_device_ops {new_device, destroy_device, vring_state_changed, features_changed, new_connection, destroy_connection, guest_notified, guest_notify}`, `rte_vhost_driver_start(path)`, `rte_vhost_driver_unregister`.
- Flags: `RTE_VHOST_USER_CLIENT`, `_NO_RECONNECT`, `_IOMMU_SUPPORT`, `_POSTCOPY_SUPPORT`, `_EXTBUF_SUPPORT`, `_LINEARBUF_SUPPORT`, `_MAP_POPULATE` (new 26.11), `_NET_COMPLIANT_OL_FLAGS`, `_NET_STATS_ENABLE`, `_ASYNC_CONNECT`.
- Data path: `rte_vhost_enqueue_burst(vid, qid, pkts, n)` host→guest (copies into guest buffers; caller still owns/frees mbufs), `rte_vhost_dequeue_burst(vid, qid, mp, pkts, n)` guest→host (allocates mbufs). Queue numbering: even = guest RX (`VIRTIO_RXQ=0`), odd = guest TX (`VIRTIO_TXQ=1`). Internals: `virtio_dev_rx_split/packed`, `virtio_dev_tx_split/packed(_legacy|_compliant)` in virtio_net.c; guest-physical→host-virtual translation via memory table (`rte_vhost_va_from_guest_pa`, `gpa_to_vva`), IOTLB when vIOMMU.
- vhost-user protocol (QEMU `docs/interop/vhost-user.rst`): **[verified sequence]** from a virtio_user peer:
  SET_OWNER → GET_FEATURES → GET/SET_PROTOCOL_FEATURES → SET_VRING_CALL×2 → SET_FEATURES → SET_STATUS(ACK|DRIVER|FEATURES_OK) → GET_STATUS → SET_MEM_TABLE (region fd in SCM_RIGHTS, 128 MiB, GPA=GVA=0x100200000 for virtio_user since it uses process VAs as "guest physical") → per ring: SET_VRING_NUM, SET_VRING_BASE, SET_VRING_ADDR, SET_VRING_KICK → SET_VRING_ENABLE → SET_STATUS(DRIVER_OK) → "virtio is now ready for processing" → new_device(); on peer exit: SET_VRING_ENABLE 0, GET_VRING_BASE → destroy_device. Negotiated features 0x950008000 = MRG_RXBUF|INDIRECT_DESC|PROTOCOL_FEATURES|VERSION_1|IN_ORDER; with `packed_vq=1` → 0xd50008000 (+bit 34 RING_PACKED) **[verified]**.
- Server vs client mode (`client=1` / `RTE_VHOST_USER_CLIENT`): client mode gives reconnect when the vhost app restarts (QEMU stays server).
- Live migration: dirty-page logging (`VHOST_F_LOG_ALL`, `rte_vhost_log_write`, SET_LOG_BASE), postcopy, inflight tracking (`rte_vhost_get_vhost_ring_inflight`, for vhost-blk reconnect), dynamic memory slots (`VHOST_USER_PROTOCOL_F_CONFIGURE_MEM_SLOTS`, added 26.07).
- **26.11 change: the async (DMA-accelerated) data path was removed** — `rte_vhost_async_channel_register`, `rte_vhost_async_dma_configure`, `rte_vhost_submit_enqueue_burst`, `rte_vhost_poll_enqueue_completed`, `rte_vhost_async_try_dequeue_burst`, `rte_vhost_clear_queue`, `RTE_VHOST_USER_ASYNC_COPY` are gone (release_26_11.rst ~l.428). Older tutorials/blogs using them won't compile. `RTE_VHOST_USER_MAP_POPULATE` replaces ASYNC_COPY for its prefault side effect.
- **[verified]** `vhostapp.c` (raw library, ~60 lines): echoes guest TX→guest RX. With testpmd `txonly` on the virtio_user side it stops after **256** packets: guest RX ring (256 desc) fills because txonly never refills RX → beautiful backpressure lesson. With `--forward-mode=io --tx-first` it loops at ~6 Mpps (two copies per round trip).

### 2.13 net_vhost — `drivers/net/vhost/rte_eth_vhost.c`, doc `nics/vhost.rst`
- Thin ethdev wrapper: `iface=<socket path>`, `queues`, `client`, `iommu-support`, `postcopy-support`, `tso`, `linear-buffer`, `ext-buffer`, `legacy-ol-flags`. Link comes up on `new_device` (LSC event), queue state events → `rte_eth_vhost_get_queue_event()`; `rte_eth_vhost_get_vid_from_port_id()`.
- **[verified]** `net_vhost0,iface=/run/ch06vhost.sock` (`--no-huge`) ↔ `net_virtio_user0,path=/run/ch06vhost.sock` (hugepages `-m 128 --single-file-segments` or `--no-huge`): ~18 Mpps txonly→rxonly; "Port 0: link state change event" on connect and disconnect.

### 2.14 vDPA and VDUSE
- vDPA (18.05): a NIC whose HW implements virtio rings directly; vhost-user remains the control plane, data path goes guest↔HW. `rte_vhost_driver_attach_vdpa_device(path, dev)`, `rte_vdpa_find_device_by_name`, `rte_vdpa_get_queue_num/features/protocol_features/stats`. Driver ops (`vdpa_driver.h`): get_queue_num, get_features, get_protocol_features, dev_conf, dev_close, set_vring_state, set_features, migration_done, get_vfio_device_fd, get_notify_area... (26.11 removed `get_vfio_group_fd`; use VFIO container device assignment API). Drivers: `drivers/vdpa/{ifc,mlx5,sfc,nfp}` (not built here) — **no hardware here: teach conceptually** with `examples/vdpa` walkthrough. Also virtio-user's VHOST_VDPA backend (kernel vhost-vdpa).
- VDUSE (23.07): vDPA device in userspace via `/dev/vduse` kernel driver — DPDK vhost lib can expose a virtio-net device to the *host kernel* (virtio-vdpa) or to VMs (vhost-vdpa). `lib/vhost/vduse.c`; register with path `/dev/vduse/<name>`. Needs kernel VDUSE module (likely unavailable here — check `ls /dev/vduse`).

### 2.15 KNI — history only (removed)
- Kernel NIC Interface: out-of-tree kernel module `rte_kni.ko` + `librte_kni` creating `vEthX` netdevs with shared FIFOs for exception path. Problems: out-of-tree kmod breaking on every kernel, security (kernel threads touching user memory with physical addresses), maintenance burden, not upstreamable.
- Timeline: KNI vhost removed 17.05; KNI ethtool removed 19.08; deprecated (runtime warning) 22.11; **library, driver and example removed in 23.11** (release_23_11.rst ~l.286).
- Replacements to teach: `net_tap` (simplest), `virtio_user` + vhost-net (fastest, kernel threads, TSO/multiseg, upstream modules), `net_af_xdp`/flow bifurcation (`howto/flow_bifurcation.rst`), `net_af_packet`.

### 2.16 Packet capture: pdump, pcapng, dumpcap — `lib/pdump/`, `lib/pcapng/`, `app/dumpcap/`, `app/pdump/`; docs `prog_guide/pdump_lib.rst`, `pcapng_lib.rst`, `tools/dumpcap.rst`, `tools/pdump.rst`, `howto/packet_capture_framework.rst`
- Architecture: primary calls `rte_pdump_init()` (testpmd does at startup, line ~4577 of testpmd.c) → registers an MP action (`rte_mp_action_register`). Secondary (dumpcap) sends "enable" over the multi-process channel with a ring + mempool; primary installs ethdev **RX/TX callbacks** (`rte_eth_add_rx_callback`/`add_tx_callback`) that copy (`rte_pcapng_copy`) matching mbufs (optional BPF filter compiled from libpcap syntax via `rte_bpf`, snaplen) into the ring; secondary dequeues and writes with `rte_pcapng_write_packets`; stats via `rte_pdump_stats`. Zero cost until enabled; copies when enabled.
- API: `rte_pdump_init/uninit`, `rte_pdump_enable(_bpf)(_by_deviceid)`, `rte_pdump_disable(_by_deviceid)`, flags `RTE_PDUMP_FLAG_RX|TX|RXTX|PCAPNG`; pcapng: `rte_pcapng_fdopen`, `rte_pcapng_add_interface`, `rte_pcapng_mbuf_size`, `rte_pcapng_copy`, `rte_pcapng_write_packets`, `rte_pcapng_write_stats`, `rte_pcapng_close`.
- History: pdump 16.07 (pcap PMD based `dpdk-pdump`), pcapng + `dpdk-dumpcap` 21.11 (Wireshark-like CLI, BPF filters, multiple interfaces).
- **[verified]** primary `dpdk-testpmd -l 0-1 --no-pci -m 64 --file-prefix=ch06dc --vdev=net_pcap0,rx_pcap=in.pcap,infinite_rx=1 -- --forward-mode=macswap --total-num-mbufs=8192`; then
  `dpdk-dumpcap --file-prefix=ch06dc -D` → `0. net_pcap0`;
  `dpdk-dumpcap --file-prefix=ch06dc -i 0 -c 20 -f 'udp src port 1003' -w cap.pcapng` → file with SHB, IDB, 32 EPB, ISB (count overshoots `-c 20` because capture works in bursts), all sport=1003 (BPF filter works). dumpcap needs the same `--file-prefix` as the primary and a primary that uses **hugepages** (secondary must map primary memory; use small `-m 64`). Dumpcap prints "Device 0000:00:08.0 is not driven by the primary process / Failed to probe" — harmless (secondary scans PCI but won't touch devices the primary doesn't own) — explain it so students don't panic.
- Pcapng block structure for visualization: SHB (section, OS/app strings: "Linux 6.18…", "dpdk-dumpcap 1.0 (DPDK 26.11.0)"), IDB per interface (linktype, snaplen, if_name), EPB per packet (if id, 64-bit ns timestamp, caplen/origlen, optional queue/direction flags), ISB (stats).

### 2.17 testpmd as the universal test harness — `app/test-pmd/`, docs `testpmd_app_ug/{run_app,testpmd_funcs}.rst` (285 documented commands)
- Command-line essentials: `-i` interactive, `--forward-mode=`, `--tx-first`, `--stats-period N` (non-interactive mode; needs SIGINT to exit → `timeout -s INT`), `--total-num-mbufs` (default pool ~155k mbufs × 2176 B **fails with `--no-huge -m 256`** — always set e.g. 8192) **[verified]**, `--portmask`, `--port-topology=paired|chained|loop`, `--nb-cores`, `--rxq/--txq`, `--rxd/--txd`, `--burst`, `--no-flush-rx`, `--txonly-multi-flow`, `--eth-peer`, `--auto-start`, `--record-burst-stats`.
- Forward engines: io, mac, macswap, flowgen, rxonly, txonly, csum, icmpecho, noisy, 5tswap, shared-rxq, recycle_mbufs (+ `retry`).
- Interactive commands to teach: `show port info|stats|xstats all`, `clear port stats all`, `show fwd stats all`, `set fwd X`, `start [tx_first]`, `stop`, `set verbose 1` (prints each packet with ptype, l2/l3/l4 len, ol_flags) **[verified]**, `port attach <devargs>` / `port detach <id>` (runtime vdev hotplug) **[verified]**, `port stop/start/close`, `set txpkts`, `set burst`, `flow create/validate/list/destroy` (tap supports), bonding commands, `show port <id> rxq|txq info`, `set link-up/down`, `dump_mempool`, `quit`.
- Scripting pattern (works, [verified]): `(sleep 2; echo "set fwd txonly"; echo start; sleep 2; echo stop; echo "show port stats all"; echo quit) | timeout -s INT -k 5 15 dpdk-testpmd ... -- -i`. Also `--cmdline-file`.
- Observed throughput ladder on this VM (one forwarding core, 64 B): net_ring ~163 Mpps > pcap infinite_rx ~68 > net_null ~55 > virtio_user↔vhost ~18–22 > memif ~19 > raw vhost echo ~6 > tap/af_packet (~1 Mpps class, syscall-bound). Great bar chart for a chapter.

---

## 3. How the pieces relate (concept map)

```
                application (same rte_eth_rx_burst/tx_burst code)
                                   │ ethdev
   ┌──────────┬─────────┬──────────┼──────────────┬──────────────┬───────────────┐
 null      ring      pcap      tap / af_packet / af_xdp      memif         virtio_user     bonding/failsafe
 (mempool) (rte_ring) (files)   (kernel netdev: veth, tap)   (shm+uds)     (virtio PMD)    (wrap other ports)
                                                                ▲              │ vhost-user / vhost-kernel / vhost-vdpa
                                                         VPP/libmemif          ▼
                                                                        librte_vhost ◄── net_vhost (ethdev wrapper)
                                                                        (also QEMU guests via virtio-net PCI → DPDK virtio PMD in VM)
                                                                        vDPA: HW serves the rings; VDUSE: userspace vDPA to kernel
   pdump/dumpcap: secondary process + ethdev rx/tx callbacks on ANY of the above ports
```
Symmetry worth emphasizing: virtio PMD (guest/driver side) and vhost (device/backend side) are the two halves of the
same virtqueue; virtio_user lets both halves run as ordinary processes on one host — the complete VM networking stack
can be demoed with **no VM and no NIC**.

---

## 4. Suggested teaching order (easy → hard)

1. **Testing without hardware & vdev basics**: `--vdev`, `--no-pci`, `--no-huge`, `--file-prefix`, vdev bus, devargs, `RTE_PMD_REGISTER_VDEV`, `dpdk-testpmd` first run on net_null.
2. **testpmd as a lab bench**: forward modes, port topology, stats, interactive scripting, verbose, attach/detach.
3. **net_null & net_ring**: internals (20 lines of code each), `rte_eth_from_rings()` virtual cable in C.
4. **net_pcap**: replay/capture files, infinite_rx benchmarking, the flush-rx pitfall, pcap file format.
5. **Talking to the kernel**: net_tap/tun (readv/writev, TC-flow), veth + af_packet (PACKET_MMAP), af_xdp (UMEM, 4 rings, XDP prog), comparison & KNI history.
6. **Packet capture framework**: pdump MP channel, callbacks, BPF filter, pcapng blocks, dpdk-dumpcap.
7. **memif**: shared memory IPC between two processes, control handshake, descriptor format.
8. **Bonding & failsafe**: composite PMDs, modes, hashing, LACP, ownership, hot-plug.
9. **virtio fundamentals**: virtio spec, split vs packed ring, feature negotiation, notifications, virtio PMD paths.
10. **vhost-user**: protocol messages, memory table & address translation, librte_vhost API, net_vhost, virtio_user; container networking.
11. **Advanced virtualization**: vhost-kernel exception path, vDPA, VDUSE, live migration/dirty logging, reconnect, multi-queue; 26.11 async removal.

(Could be 2–3 course chapters: "Virtual PMDs & testing without hardware" (1–6), "Composite & IPC PMDs" (7–8), "Virtio & vhost" (9–11).)

---

## 5. Runnable example ideas for THIS machine (all verified unless noted)

Common env: `source .../dpdk-env.sh`; base EAL `-l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch06<x>`; testpmd args `--total-num-mbufs=8192 --stats-period 2`; wrap in `timeout -s INT -k 5 <s>`; redirect to log files.

1. **Hello vdev**: two net_null, `--tx-first`, read Rx-pps. Variant `size=1500`, `copy=1` to show memcpy cost; `no-rx=1`.
2. **Ring loopback & virtual cable** (`ringeth.c`): build with `gcc x.c $(pkg-config --cflags libdpdk) $(pkg-config --libs --static libdpdk)`; prints port names/drivers, ring counts, ordering; plus `rte_vdev_init("net_null0","size=128")`.
3. **pcap replay**: `mkpcap.py in.pcap 100` → `net_pcap0,rx_pcap=in.pcap,tx_pcap=out.pcap` `--forward-mode=macswap --port-topology=loop --no-flush-rx`; inspect out.pcap with a Python reader (show MACs swapped, ns magic). Then demonstrate failure without `--no-flush-rx`.
4. **Bench source**: `rx_pcap=in.pcap,infinite_rx=1` rxonly.
5. **Kernel ↔ DPDK via tap**: `net_tap0,iface=ch06tap0`, `ip link set ch06tap0 up`, `sendraw.py ch06tap0 1000`; reverse direction: testpmd txonly and read `ip -s link show ch06tap0` RX counter; `ip link del` afterwards (tap is removed automatically unless `persist`).
6. **veth + af_packet / af_xdp**: create `ch06va/ch06vb`, attach PMD to ch06va, inject from ch06vb; compare pps; try `fanout_mode`, `qpairs=2`; for af_xdp `mode=skb` vs default, `busy_budget=0`. Delete veth after.
7. **memif two processes**: server rxonly on lcores 0-1, client txonly on lcores 2-3, filesystem socket under `/run/ch06memif.sock` with `socket-abstract=no` (so students can `ls` it). Variant: `secret=` mismatch → connection refused.
8. **Bonding modes table**: the 4-mode loop above with `--portmask=0x4 --txonly-multi-flow`; then `examples/bond` binary in `$DPDK_SRC/build/examples/dpdk-bond` (check its args first). Failover: `set link-down port 0` may not be supported by null — use net_ring members or bonding API `rte_eth_bond_member_remove` in C.
9. **Failsafe**: `dev(net_null0,size=128),dev(net_ring0)`; show hidden sub-ports; hotplug via `exec(echo net_null1)`.
10. **vhost-user ↔ virtio-user** (testpmd both sides): log the handshake (`VHOST_CONFIG` lines) and animate it; toggle `packed_vq=1`, `mrg_rxbuf=0`, `in_order=0` and show negotiated feature bits change + which Rx/Tx function is selected (`--log-level=pmd.net.virtio.*:debug` prints chosen path).
11. **Raw vhost library** (`vhostapp.c`): callbacks + dequeue/enqueue echo; demonstrate the 256-packet stall with txonly peer (backpressure), then io loop.
12. **dpdk-dumpcap**: primary with hugepages `-m 64`, `-D`, capture with BPF filter, parse pcapng with `pcapng_dump.py`; show `-d` (print BPF bytecode); `-S` live stats.
13. **testpmd hotplug + verbose**: `port attach net_pcap1,rx_pcap=three.pcap` → `set verbose 1` → per-packet dump with ptype & ol_flags; `port detach`.
14. **Not runnable here (diagram only)**: QEMU guest with vhost-user (no QEMU), vhost-kernel/`/dev/vhost-net` exception path (module absent), vDPA (no HW), VDUSE (check `/dev/vduse`, probably absent), LACP mode 4 against a real switch (could do bond-to-bond over two net_ring pairs in one process — worth trying as an advanced exercise).

---

## 6. Visualization / animation ideas

- **vdev bus probe**: EAL parses `--vdev` → vdev bus → driver matched by name prefix (`net_null`, `net_ring`, aliases like `eth_af_packet`) → `probe()` → `rte_eth_dev_allocate` → port id assigned. Animated pipeline.
- **"Same app, many backends" switchboard**: one forwarding loop, swappable backend cartridges (null, ring, pcap file, tap→kernel, memif shm, vhost/virtio); packets flow with different costs (syscall icon, memcpy icon, pointer pass).
- **net_ring virtual cable**: two ports, two rings, mbuf pointers (not data) sliding across.
- **testpmd flush pitfall**: pcap file packets drained by `flush_fwd_rx_queues` before `start`, then empty.
- **tap**: per-queue fd, readv/writev arrows crossing the user/kernel boundary; kernel netdev box with `ip`/tcpdump attached.
- **AF_PACKET PACKET_MMAP ring**: frames with status bits toggling between kernel and user ownership.
- **AF_XDP**: UMEM grid + 4 rings (fill/RX/TX/completion) with frame addresses cycling; XDP program redirect at the driver hook.
- **memif handshake**: sequence diagram HELLO/INIT/ACK/ADD_REGION/ADD_RING/CONNECT/CONNECTED; region layout (C2S rings | S2C rings | buffers) and descriptor bitfield.
- **Bonding**: packets coloured by 5-tuple hash fanned to members; mode selector switches animation (RR alternation, active-backup with failover when a member link turns red, broadcast duplication, LACP control frames).
- **Failsafe**: preferred vs fallback sub-device; plug-out event re-routes TX; plug-in replays config.
- **Split virtqueue step-through**: desc table, avail ring, used ring; driver posts desc → avail.idx++ → kick → device consumes → used ring → call. **Packed ring**: single ring with AVAIL/USED bits and wrap counter flipping on wrap. Side-by-side cache-line count.
- **Feature negotiation**: 64-bit bitmap; driver features ∧ device features; decode `0x950008000` vs `0xd50008000` live (bit 34 lights up).
- **vhost-user handshake**: actual verified message sequence as a timeline; SET_MEM_TABLE showing fd passed via SCM_RIGHTS and mmap into vhost address space; GPA→HVA translation table lookup animation.
- **Backpressure**: guest RX ring filling to 256 and enqueue returning 0 when the guest never refills.
- **pdump/dumpcap**: primary + secondary process boxes, MP socket message "enable", RX/TX callback hooks inserting copies into a ring → secondary → pcapng file blocks building up (SHB, IDB, EPB…).
- **KNI timeline**: 1.x KNI → 16.07 virtio_user → 17.05 KNI vhost removed → 19.05 af_xdp → 22.11 deprecated → 23.11 removed; replacement decision tree (need speed? kernel features? container?).
- **Throughput ladder bar chart** using the measured numbers above (label as "this VM, 1 core, 64 B").

---

## 7. Common pitfalls (collected, most verified)

1. Binding/attaching to the management NIC (here eth0, virtio 0000:00:08.0) kills connectivity — always `--no-pci`, use veth/tap.
2. Forgetting unique `--file-prefix` → "multi-process socket in use" / hugepage file collisions between concurrent DPDK processes; secondaries (dumpcap) need the **same** prefix as the primary.
3. testpmd default mbuf pool too big for `--no-huge -m 256` → "Creation of mbuf pool … Cannot allocate memory"; set `--total-num-mbufs`.
4. testpmd flushes RX queues at start → pcap file consumed; use `--no-flush-rx`.
5. `--stats-period` mode only exits on signal → `timeout -s INT`.
6. `--tx-first` disables LSC interrupt (testpmd warns).
7. Stats semantics differ per PMD (net_ring has no byte counters; bond stats = sum of members; broadcast doubles).
8. testpmd forwards on bonding member ports too unless `--portmask` limits to the bond.
9. Calling rx/tx on bond members or failsafe sub-devices directly; iterating ports without `RTE_ETH_FOREACH_DEV` reveals owned sub-devices.
10. Bonding mode 4 requires rx/tx calls < 100 ms apart and tx burst ≥ 2×members.
11. memif default socket is **abstract** (no file to see/delete); server socket "Address already in use" if stale filesystem socket; same-process server+client not possible.
12. virtio_user memory: >8 regions fails → `--single-file-segments`; `--huge-unlink` breaks sharing. (Old "no `--no-huge`" restriction no longer applies — memfd.)
13. vhost: enqueue **copies** — caller must free mbufs; dequeue allocates from the given pool; even/odd queue index confusion (guest RX=0, TX=1).
14. vhost server vs client mode mismatch → nobody listens; stale socket file in server mode (`unlink` before register).
15. Feature set must be identical across vhost reconnect.
16. Old code using vhost async API fails to build on 26.11 (removed). Bonding "slave" API names gone since 23.11 (now "member"). `rte_eth_dev_get_name_by_port` has a size parameter in 26.11.
17. tap requires equal RX/TX queue counts; tap/af_packet are syscall-bound (don't benchmark DPDK with them).
18. af_xdp: traffic must land on the bound queue; libxdp needs bpffs for the dispatcher (falls back otherwise); zero-copy needs driver support (veth here → copy).
19. dumpcap `-c N` may write more than N (burst granularity); capture costs a copy per packet → use filter + snaplen; dumpcap needs a primary with hugepage memory (no `--no-huge` primary) and only works with apps that call `rte_pdump_init()` (testpmd does).
20. No tcpdump/ping on this machine: plan traffic generation with Python raw sockets or testpmd txonly/flowgen.

---

## 8. Source references (paths relative to `$DPDK_SRC`)

- Docs: `doc/guides/nics/{null,ring,tap,af_packet,af_xdp,pcap,memif,fail_safe,vhost,virtio}.rst`; `doc/guides/prog_guide/{vhost_lib,link_bonding_poll_mode_drv_lib,pdump_lib,pcapng_lib}.rst`; `doc/guides/howto/{virtio_user_for_container_networking,virtio_user_as_exception_path,packet_capture_framework,af_xdp_dp,flow_bifurcation,lm_virtio_vhost_user,lm_bond_virtio_sriov,pvp_reference_benchmark}.rst`; `doc/guides/tools/{dumpcap,pdump}.rst`; `doc/guides/testpmd_app_ug/{run_app,testpmd_funcs}.rst`; `doc/guides/sample_app_ug/{vhost,vdpa,vhost_blk,vhost_crypto,link_status_intr}.rst`; release notes `doc/guides/rel_notes/release_{16_07,17_08,18_05,19_05,19_08,21_11,23_07,23_11,26_07,26_11}.rst`.
- Drivers: `drivers/net/{null,ring,tap,af_packet,af_xdp,pcap,memif,bonding,failsafe,vhost,virtio}/`; `drivers/net/virtio/virtio_user/*`; `drivers/bus/vdev/`; `drivers/vdpa/` (not built here).
- Libraries: `lib/vhost/*`, `lib/pdump/rte_pdump.[ch]`, `lib/pcapng/rte_pcapng.[ch]`, `lib/bpf/` (filters), `lib/eal/linux/eal_memory.c` (memfd no-huge).
- Apps: `app/test-pmd/` (testpmd.c `flush_fwd_rx_queues`, `rte_pdump_init`), `app/dumpcap/main.c`, `app/pdump/main.c`; examples `examples/{vhost,vdpa,vhost_blk,vhost_crypto,bond,skeleton,ptp_tap_relay_sw,multi_process}` (prebuilt `build/examples/dpdk-*`).
- External: virtio spec (OASIS virtio v1.1/1.2: split & packed virtqueues, feature bits); QEMU `docs/interop/vhost-user.rst` (protocol); kernel `Documentation/networking/{af_xdp,packet_mmap}.rst`; FD.io VPP libmemif docs; DPDK Userspace talks on virtio packed ring, vDPA, VDUSE (Maxime Coquelin), dumpcap/pcapng (Stephen Hemminger); KNI deprecation discussion on dev@dpdk.org (2022).

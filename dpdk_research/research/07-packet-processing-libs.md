# 07 — Packet-processing libraries (research note for the course planner)

Area: `lib/net` helpers, hash (cuckoo), LPM/LPM6, FIB/RIB, ACL, EFD, member, ip_frag, GRO/GSO,
meter / policer, sched (hierarchical QoS + RED/PIE), BPF, SWX pipeline/port/table, graph + node,
distributor, IPsec, PDCP, and the classic sample apps l2fwd, l3fwd, l3fwd-graph, ipsec-secgw.

Everything below was checked against the DPDK **26.11.0** tree at `$DPDK_SRC` (headers, `doc/guides`,
release notes) and, where stated, **run on this VM**. All runnable material lives in
`/home/user/ai_lab/dpdk_research/research/07-examples/` (one-shot reproduction: `./run_all.sh`).

---

## 0. Read this first: what is different in 26.11 (don't teach stale material)

| Change (release) | Consequence for the course |
|---|---|
| **Legacy Packet Framework removed in 26.11**: `rte_pipeline_*`, `rte_table_*`, `rte_table_action_*`, `rte_port_*`, `rte_port_in_action_*`, the `ip_pipeline` example and `dpdk-test-pipeline` are gone (rel notes 26.11 "Removed Items"). `lib/pipeline`, `lib/port`, `lib/table` now hold only `rte_swx_*`. | Teach only the **SWX pipeline** (P4-like spec → C → .so). Old blog posts/tutorials about `rte_pipeline_create`, `rte_table_hash_*`, `ip_pipeline` are obsolete. |
| `struct rte_ipv6_addr` is the IPv6 address type everywhere (LPM6, FIB6, RIB6, net). `RTE_LPM6_IPV6_ADDR_SIZE`, `RTE_FIB6_MAXDEPTH`, `rte_rib6_copy_addr`, ... removed (26.11). `struct rte_ipv6_hdr` lost its `version/ds/ecn/flow_label` bitfields (wrong on LE) → use `vtc_flow` + `RTE_IPV6_HDR_*_MASK/SHIFT`. | IPv6 code examples must use `struct rte_ipv6_addr` + `RTE_IPV6(...)` helpers. |
| `rte_atomicNN_*` and `rte_smp_*mb()` removed (26.11) → C11 `rte_atomic_*_explicit`, `rte_atomic_thread_fence`. | Any lock-free / RCU illustration must use the C11 API. |
| BPF: extensible `rte_bpf_load_ex()` + `struct rte_bpf_prm_ex` (origins RAW / CBPF / ELF_FILE / ELF_MEMORY), up to 5 program args, `rte_bpf_exec_ex`, `rte_bpf_exec_burst_ex`, `rte_bpf_get_jit_ex`, `rte_bpf_eth_rx_install/tx_install`, and a verifier debugging API `rte_bpf_validate_debug_*` (26.07). | Teach `load_ex` as the main API; old `rte_bpf_load`/`rte_bpf_elf_load` still exist. |
| Hash: when RCU is configured with `free_key_data_func`, `rte_hash_add_key_data()` on an existing key now **defers freeing the old data pointer** through the RCU defer queue (26.03). | Nice "RCU-safe update" story. |
| FIB6 gained RCU QSBR (`rte_fib6_rcu_qsbr_add`, 25.11); FIB has `RTE_FIB_F_LOOKUP_NETWORK_ORDER` (24.11). | |
| Graph: **feature arcs** (25.07, `rte_graph_feature_arc*.h`, `ip4_output` arc in `ip4_rewrite`), shared node mbuf dynfield `rte_node_mbuf_dynfield.h` (25.07), mcore **dispatch** model (23.07). The RTC walk now uses a **pending bitmap ordered by topological depth** (`lib/graph/rte_graph_model_rtc.h`, doc "Graph object memory layout"). | Old diagrams showing a circular pending-stream queue are outdated; animate the bitmap walk. |
| ACL: custom memory hooks `rte_acl_set_mem_hook()` (26.03); RVV classify (`RTE_ACL_CLASSIFY_RVV`). | |
| sched: private RNG `rte_fast_rand()` removed (26.11). | |
| mempool cache size no longer capped by `RTE_MEMPOOL_CACHE_MAX_SIZE` (26.11). | Relevant to pools used by ip_frag/GSO. |

History (from the release notes in-tree): cuckoo hash replaced the old hash in **2.1**; ACL is from the
1.x era (doc © 2010-2015); EFD **17.02**; GRO **17.08**; GSO and member **17.11**; BPF **18.05**;
lock-free RW concurrency in rte_hash **18.11** (Arm); IPsec library **19.02**; RIB + FIB **19.11**;
graph library **20.05** (Marvell); SWX pipeline **20.11**; PDCP + graph dispatch model **23.07**;
graph feature arc **25.07**; legacy pipeline removal **26.11**.

---

## 1. Map of the area and how the pieces relate

```
                 +-------------------- data-plane building blocks ---------------------+
 parse/build     | lib/net: rte_ether.h rte_ip4.h rte_ip6.h rte_udp/tcp.h rte_cksum.h   |
 headers         |          rte_net.h (rte_net_get_ptype, cksum prepare) rte_net_crc.h  |
                 +----------------------------------------------------------------------+
 exact match     | hash (rte_hash cuckoo, rte_fbk_hash, rte_thash Toeplitz/GFNI)        |
                 |   ├─ EFD (perfect-hash "which target", no keys stored)               |
                 |   ├─ member (set summary: HT / vBF / count-min sketch)               |
                 |   └─ used by: l3fwd-em, ipsec SAD, ip_frag table (own 2-way hash)    |
 longest prefix  | LPM / LPM6 (DIR-24-8 tbl24+tbl8)  →  FIB / FIB6 (DIR-24-8 / trie,    |
                 |   with RIB / RIB6 binary tree as control-plane shadow)               |
 multi-field     | ACL (multi-bit trie, SIMD classify, categories)                      |
 transform       | ip_frag (frag + reassembly) · GSO (sw TSO) · GRO (merge)             |
 QoS             | meter (srTCM/trTCM/RFC4115) → policer (qos_meter example)            |
                 | sched (port→subport→pipe→TC→queue) + RED/WRED/PIE droppers           |
 programmable    | BPF (eBPF interp + x86/arm64 JIT, ethdev RX/TX callbacks)            |
                 | SWX pipeline (P4-like spec, tables em/wm/learner/selector, externs)  |
 composition     | graph + node (ethdev_rx → pkt_cls → ip4_lookup → ip4_rewrite → tx)    |
 load spreading  | distributor (flow-tag affinity, ordered return)                      |
 security        | IPsec (SA/SAD, ESP over cryptodev/rte_security) · PDCP (3GPP, reorder)|
                 +----------------------------------------------------------------------+
 sample apps:  l2fwd (no lookup) → l3fwd (lpm|fib|em|acl) → l3fwd-graph (graph+nodes)
               → ipsec-secgw (ACL as SPD + LPM routing + SAD hash + cryptodev + ipsec lib)
```

Key relations to emphasize:
- **LPM vs FIB vs RIB**: LPM keeps its own rules table; FIB keeps an `rte_rib` internally
  (`rte_fib_get_rib()`) as the control-plane copy and a pluggable dataplane (DIR24_8 for v4, TRIE for v6,
  DUMMY = RIB-only). RIB is *control plane* (tree walks, `get_nxt`, parent lookup, user extension per node).
- **Hash family**: rte_hash = exact match with keys stored; EFD = stores no keys, returns a small value
  (8-bit by default, `RTE_EFD_VALUE_NUM_BITS`) for keys *known to exist*; member = "is it in set N?"
  with false positives (vBF/HT cache) or approximate counts (sketch).
- **ACL** generalizes LPM to N fields with ranges/masks and priorities; used by l3fwd `--lookup=acl` and as
  the **SPD** in ipsec-secgw (`sp4.c` / `sp6.c`). The secgw log we produced shows `acl context <sp_ip4_out_0> ... alg=6`
  (AVX512X16) next to `LPM: Adding route ...`.
- **ip_frag / GSO** both use the *direct + indirect mbuf* zero-copy trick (header copy in a direct
  mbuf, payload via `rte_pktmbuf_attach` indirect mbuf) — ties back to the mbuf chapter.
- **meter → sched**: meter colors packets; sched's droppers (WRED) use per-color thresholds
  (`rte_sched_port_pkt_write(..., color)`). The hardware equivalents are `rte_mtr` / `rte_tm`
  (ethdev chapter: `doc/guides/prog_guide/ethdev/traffic_metering_and_policing.rst`, `traffic_management.rst`).
- **graph** composes the other libraries: `ip4_lookup` node = rte_lpm, `ip4_lookup_fib` = rte_fib,
  `ip4_reassembly` = ip_frag, `kernel_rx/tx`, `pkt_cls` = ptype-based classifier.
- **IPsec/PDCP** sit on cryptodev + rte_security (crypto chapter) and use hash (SAD) / reorder (PDCP).

---

## 2. Recommended teaching order (easy → hard)

1. **Headers & checksums** (`lib/net`): parse/build Ethernet/IPv4/IPv6/UDP/TCP, `rte_ipv4_cksum`,
   `rte_ipv4_udptcp_cksum`, `rte_raw_cksum`, `rte_net_get_ptype`, byte order. (Prereq for everything.)
2. **l2fwd** sample — the minimal forwarding loop, MAC rewrite, TX buffering, stats.
3. **rte_hash** — API, flags, cuckoo internals, bulk lookup, then the concurrency story (RW lock, TSX,
   lock-free + RCU QSBR, ext buckets). Then Toeplitz `rte_thash` (RSS emulation, predictable RSS / SNAT).
4. **LPM (DIR-24-8)** → **LPM6** → **RIB** → **FIB/FIB6**. Then **l3fwd** (lpm, fib, em; vector paths).
5. **ACL** — field defs, rule format, categories, build vs classify, SIMD algs; l3fwd `--lookup=acl`.
6. **EFD and member** — probabilistic / compact structures (optional/advanced side chapter).
7. **ip_frag** → **GSO** → **GRO** (packet transforms; mbuf chains, indirect mbufs, timeouts).
8. **meter / policer** → **sched** (hierarchy, token buckets, credits, grinders, WRR, RED/PIE).
9. **BPF** — eBPF programs, verifier, JIT, attaching to ethdev queues, cBPF conversion.
10. **Distributor** — flow-affinity load balancing between cores (compare with eventdev chapter).
11. **Graph + nodes** — write a node, home-run optimization, l3fwd-graph, feature arcs, dispatch model.
12. **SWX pipeline** — P4-like spec, tables (em/wm/learner/selector), externs (meter, regarray), CLI, codegen.
13. **IPsec library + ipsec-secgw** (capstone), then **PDCP** (5G user-plane, brief).

Rationale: each step reuses the previous (hash → EFD/member/SAD; LPM → FIB → graph ip4_lookup;
ACL → SPD; mbuf indirect → frag/GSO; meter → sched colors; everything → graph and secgw).

---

## 3. Library deep dives

### 3.1 `lib/net` — protocol headers and helpers
Files: `lib/net/rte_ether.h`, `rte_ip.h` (just includes `rte_ip4.h` + `rte_ip6.h`), `rte_udp.h`,
`rte_tcp.h`, `rte_icmp.h`, `rte_arp.h`, `rte_vxlan.h`, `rte_gre.h`, `rte_gtp.h`, `rte_esp.h`, `rte_mpls.h`,
`rte_ptp.h` (26.07), `rte_cksum.h`, `rte_net.h`, `rte_net_crc.h`.
- Structs are packed, 2-byte aligned (`struct __rte_aligned(2) __rte_packed_begin rte_ipv4_hdr`), fields in
  **network byte order** (`rte_be16_t` etc.) → `rte_cpu_to_be_16()` / `rte_be_to_cpu_32()`.
- Ethernet: `struct rte_ether_addr`, `rte_is_*_ether_addr`, `rte_ether_format_addr`/`unformat`,
  `rte_eth_random_addr`, VLAN `rte_vlan_strip`, `rte_vlan_insert`, `rte_vlan_insert_tpid` (26.11 TPID support).
- IPv4: `RTE_IPV4(a,b,c,d)` (host order u32), `RTE_IPV4_VHL_DEF`, `rte_ipv4_hdr_len`, `rte_ipv4_cksum`,
  `rte_ipv4_cksum_simple`, `rte_ipv4_phdr_cksum(hdr, ol_flags)` (pseudo-header for TSO/HW offload),
  `rte_ipv4_udptcp_cksum[_mbuf][_verify]`, fragment helpers `RTE_IPV4_HDR_MF_FLAG`, `RTE_IPV4_HDR_OFFSET_MASK`.
- IPv6: `struct rte_ipv6_addr` + `rte_ipv6_addr_eq/_mask/_eq_prefix`, `rte_ipv6_addr_is_*`
  (linklocal, mcast, v4mapped...), `rte_ipv6_llocal_from_ethernet`, `rte_ipv6_solnode_from_addr`,
  `rte_ether_mcast_from_ipv6`, ext-header walking `rte_ipv6_get_next_ext`, `rte_net_skip_ip6_ext`.
- Checksum core: `rte_raw_cksum(buf,len)` (one's-complement sum), `rte_raw_cksum_mbuf(m, off, len, &sum)`
  (multi-segment).
- `rte_net_get_ptype(m, &hdr_lens, layers)` — software packet-type parser → fills `m->packet_type`
  and `struct rte_net_hdr_lens` (l2/l3/l4/tunnel lens). Required by GRO and by l3fwd `--parse-ptype`
  on vdevs that report no ptypes (net_pcap/null/ring).
- `rte_net_intel_cksum_prepare()` — writes pseudo-header checksums the way Intel NICs expect for TX
  offload; used from `tx_prepare`.
- `rte_net_crc_*` (CRC16-CCITT, CRC32-Ethernet, SSE/AVX512/NEON).
**Example idea**: build a UDP packet in an mbuf, compute IP and UDP checksums, corrupt a byte, verify
with `rte_ipv4_udptcp_cksum_verify`; parse ptype of a VXLAN-encapsulated packet with `rte_net_get_ptype`.
**Viz**: byte-map of an Ethernet/IPv4/UDP frame with hover showing struct field ↔ offset ↔ endianness;
animated one's-complement checksum folding (carry wrap-around).

### 3.2 Hash library (`lib/hash`)
API (`rte_hash.h`): `rte_hash_create(&struct rte_hash_parameters{name, entries, key_len, hash_func,
hash_func_init_val, socket_id, extra_flag})`, `rte_hash_add_key[_data|_with_hash|_with_hash_data]`,
`rte_hash_lookup[_data|_with_hash|_bulk|_bulk_data|_with_hash_bulk_data]`, `rte_hash_del_key*`,
`rte_hash_free_key_with_position`, `rte_hash_get_key_with_position`, `rte_hash_iterate`, `rte_hash_count`,
`rte_hash_hash` (precompute), `rte_hash_reset`, `rte_hash_rcu_qsbr_add(h, &struct rte_hash_rcu_config)`,
`rte_hash_rcu_qsbr_dq_reclaim`. Bulk lookups ≤ `RTE_HASH_LOOKUP_BULK_MAX` = 64.
Flags: `RTE_HASH_EXTRA_FLAGS_TRANS_MEM_SUPPORT` (0x01, TSX), `MULTI_WRITER_ADD` (0x02),
`RW_CONCURRENCY` (0x04, rwlock), `EXT_TABLE` (0x08, linked overflow buckets), `NO_FREE_ON_DEL` (0x10),
`RW_CONCURRENCY_LF` (0x20, lock-free readers; implies NO_FREE_ON_DEL).
Hash functions: `rte_hash_crc` (SSE4.2/ARMv8 CRC32C, `rte_hash_crc_4byte/8byte`), `rte_jhash`,
Toeplitz `rte_thash.h` (`rte_softrss`, GFNI `rte_thash_gfni`, and the *predictable RSS* helpers
`rte_thash_init_ctx`, `rte_thash_add_helper`, `rte_thash_get_complement`, `rte_thash_adjust_tuple`;
see `doc/guides/prog_guide/toeplitz_hash_lib.rst`, images `predictable_snat_*.svg`). Also `rte_fbk_hash.h`
(4-byte key, tiny).
Internals (`rte_cuckoo_hash.c/.h`):
- Two tables: **bucket array** (cache-aligned `struct rte_hash_bucket`, `RTE_HASH_BUCKET_ENTRIES` = 8 slots,
  each slot = 16-bit signature `sig_current[]` + key index `key_idx[]`, plus `next` for ext buckets) and a
  **key store** (`struct rte_hash_key { idata/pdata; key[] }`) that never moves during cuckoo displacement.
- 32-bit hash → primary bucket `hash & bucket_bitmask`; short sig = `hash >> 16`;
  alternative bucket = `(cur_bkt_idx ^ sig) & bucket_bitmask` (**partial-key cuckoo**, MemC3) —
  so a displaced entry can compute its other bucket without re-reading the key.
- Insert: free slot in primary → else in secondary → else **BFS cuckoo search** (`rte_hash_cuckoo_make_space_mw`,
  queue `RTE_HASH_BFS_QUEUE_MAX_LEN` = 1000) moving entries to their alternative buckets, then ext bucket if
  `EXT_TABLE`, else `-ENOSPC`.
- Lookup: compare signatures of both buckets (SIMD `compare_signatures_x86.h`, AVX2/SSE), then full key
  compare (`rte_cmp_x86.h` specialized memcmp for 16/32/48/64… byte keys) only on sig match.
- Lock-free readers: writers bump `tbl_chng_cnt` around cuckoo moves; readers retry if it changed
  (seqlock-like) — a key being moved is never "temporarily missing".
- Bulk lookup: pipelined — compute hashes, prefetch both buckets for all keys, compare sigs, prefetch keys,
  compare keys.
- Key slots: per-lcore free-slot caches when MULTI_WRITER_ADD (table allocates extra slots).
**Measured on this VM** (`07-examples/hash_fill.c`, 65 536 entries, 16-byte random keys):
crc fills to **98.6 %** before the first add failure, jhash 98.5 %, with `EXT_TABLE` **100 %**;
lookup ≈ 59 cycles/key single vs ≈ 35 cycles/key `lookup_bulk(64)` (jhash ≈ 71/41).
(The doc's 90-95 % tables are older measurements; with 8-way buckets + BFS you get ~98 %.)
**RCU**: `rte_hash_rcu_qsbr_add()` with mode `RTE_HASH_QSBR_MODE_DQ` (defer queue, auto-reclaim at
`trigger_reclaim_limit`) or `RTE_HASH_QSBR_MODE_SYNC`; readers call `rte_rcu_qsbr_quiescent()`. Since 26.03 data
pointer overwrite is also deferred if `free_key_data_func` is set.
**Pitfalls**: keys must be fixed length; lookups return *position* (use as index into your own array) or
use the `_data` variants; with LF/NO_FREE_ON_DEL you must free positions after a grace period;
`rte_hash_set_cmp_func` is not multi-process safe; table "entries" ≠ guaranteed capacity without EXT_TABLE;
hash with `RW_CONCURRENCY` serializes writers but readers take a lock (slower) — prefer LF + RCU.
**Viz/animation ideas**: (1) cuckoo insertion animation: two candidate buckets highlight, an eviction chain
"kicks" entries along BFS path, key store stays still; (2) live load-factor slider showing primary/secondary
distribution (doc tables) and the cliff at ~98 %; (3) signature-compare SIMD lane picture (8 sigs vs 1);
(4) RCU timeline: writer deletes → slot in defer queue → readers report quiescent → reclaim.

### 3.3 LPM / LPM6 (`lib/lpm`)
API: `rte_lpm_create(name, socket, &struct rte_lpm_config{max_rules, number_tbl8s, flags})`,
`rte_lpm_add(lpm, ip_host_order, depth, next_hop)`, `rte_lpm_delete`, `rte_lpm_delete_all`,
`rte_lpm_is_rule_present`, `rte_lpm_lookup`, `rte_lpm_lookup_bulk`, `rte_lpm_lookupx4` (SSE/NEON/SVE/Altivec
headers `rte_lpm_sse.h`...), `rte_lpm_rcu_qsbr_add`. LPM6: `rte_lpm6_add(lpm, const struct rte_ipv6_addr*,
depth, nh)`, `rte_lpm6_lookup`, `rte_lpm6_lookup_bulk_func`, `rte_lpm6_delete_bulk_func`.
DIR-24-8 internals (`rte_lpm.h`): `struct rte_lpm_tbl_entry` = 32 bits {next_hop:24, valid:1,
valid_group:1, depth:6}. **tbl24** has 2^24 entries (= **64 MiB**), each tbl8 group 256 entries;
`RTE_LPM_MAX_TBL8_NUM_GROUPS` = 2^24. Depth ≤ 24: prefix expansion into 2^(24-depth) tbl24 entries
(only overwriting entries with smaller depth); depth > 24: allocate a tbl8 group, tbl24 entry gets
`valid_group=1` + group index, expand into 2^(32-depth) tbl8 entries. Lookup = 1 memory access, 2 if
the tbl24 entry points to a tbl8. Rules table keeps prefixes for delete (needs to re-expand the covering rule).
LPM6: tbl24 + chained tbl8s (8 bits per level) → 1..14 accesses (avg ~5), with `ext_entry` flag.
**Measured** (`lpm_fib.c`): ~6 cycles per `rte_lpm_lookup` with hot cache.
**Pitfalls**: IP in **host order** for add/lookup (unlike ACL input); `number_tbl8s` too small →
`-ENOSPC` on add of >/24 prefixes; next hop only 24 bits; LPM is 64 MiB + tbl8s even for 1 route (so
`-m 256 --no-huge` is fine for one LPM but l3fwd-graph with LPM + LPM6 needed `-m 640` here);
deletion while readers run requires RCU (`rte_lpm_rcu_qsbr_add`) for tbl8 group recycling.
**Viz**: the canonical `dir_24_8_alg.svg` animated: IP bits split 24|8, tbl24 index, follow pointer into tbl8
group; prefix expansion animation (a /20 painting 16 tbl24 cells, then a /22 overpainting 4 of them); a
"depth" heat-map of tbl24 cells.

### 3.4 RIB and FIB (`lib/rib`, `lib/fib`)
RIB: binary (path-compressed) tree with "real route" and "intermediate" nodes (`img/rib_internals.svg`).
API: `rte_rib_create(name, socket, &conf{ext_sz, max_nodes})`, `rte_rib_insert`, `rte_rib_remove`,
`rte_rib_lookup` (LPM), `rte_rib_lookup_exact`, `rte_rib_lookup_parent`, `rte_rib_get_nxt(rib, ip, depth,
last, RTE_RIB_GET_NXT_ALL|COVER)` (subtree walk), `rte_rib_get_ip/_depth/_nh/_set_nh/_get_ext`.
Extension area per node → store metrics, admin distance, backup next hop → **prefix-independent
convergence** example (`img/rib_pic.svg`).
FIB: `rte_fib_create(name, socket, &struct rte_fib_conf{type = RTE_FIB_DUMMY|RTE_FIB_DIR24_8, default_nh,
max_routes, rib_ext_sz, dir24_8{nh_sz = RTE_FIB_DIR24_8_1B/2B/4B/8B, num_tbl8}, flags})`,
`rte_fib_add/delete`, `rte_fib_lookup_bulk(fib, ips, nhs, n)` (bulk only!), `rte_fib_select_lookup()` with
`RTE_FIB_LOOKUP_DEFAULT | DIR24_8_SCALAR_MACRO | SCALAR_INLINE | SCALAR_UNI | VECTOR_AVX512`,
`rte_fib_get_rib`, `rte_fib_rcu_qsbr_add`, flag `RTE_FIB_F_LOOKUP_NETWORK_ORDER`.
FIB6: `RTE_FIB6_DUMMY | RTE_FIB6_TRIE` with `RTE_FIB6_TRIE_2B/4B/8B`.
Differences vs LPM: variable next-hop width (1..8 bytes, top bit = "extended" flag → up to 63-bit nh),
default next hop instead of "miss", memory = 2^24 × nh_sz (1B nh → 16 MiB tbl24), RIB as single source of
truth, AVX-512 lookup (selected only if EAL max SIMD bitwidth ≥ 512).
**Measured** (`lpm_fib.c`): same 5 routes in LPM, FIB and RIB give identical answers for 6 probes
(10.1.2.130 → /25 via tbl8; 11.0.0.1 → LPM *miss* vs FIB *default 0*). FIB bulk ~11-13 cycles/lookup,
~9.5 with `--force-max-simd-bitwidth=512` (AVX-512 path).
**Pitfalls**: there is no single-IP FIB lookup — always bulk; `default_nh` is returned for misses (no
error code); RIB lookups are slow (tree) — control plane only.
**Viz**: side-by-side "control plane RIB tree ↔ data plane DIR24_8 arrays" — inserting a route animates
the tree insert then the array writes; PIC failover animation (flip one nh in extension, all prefixes reroute).

### 3.5 ACL (`lib/acl`)
API: `rte_acl_create(&struct rte_acl_param{name, socket_id, rule_size = RTE_ACL_RULE_SZ(nfields),
max_rule_num})`, `RTE_ACL_RULE_DEF(name, nfields)`, `rte_acl_add_rules`, `rte_acl_build(ctx,
&struct rte_acl_config{num_categories, num_fields, defs[], max_size})`, `rte_acl_classify(ctx, data[],
results[], num, categories)`, `rte_acl_classify_alg(..., alg)`, `rte_acl_set_ctx_classify`, `rte_acl_reset_rules`,
`rte_acl_reset`, `rte_acl_dump`, `rte_acl_set_mem_hook` (26.03).
Field def `struct rte_acl_field_def{type = RTE_ACL_FIELD_TYPE_MASK|RANGE|BITMASK, size 1/2/4/8, field_index,
input_index, offset}`. **Layout rule**: first field 1 byte; all others grouped into 4-byte input groups
(two 16-bit ports share one `input_index`). Rule data: `{category_mask, priority, userdata}`; result per
category = userdata of highest-priority match (0 = no match). Max fields 64 (`RTE_ACL_MAX_FIELDS`),
categories up to `RTE_ACL_MAX_CATEGORIES` (16), must be 1 or a multiple of `RTE_ACL_RESULTS_MULTIPLIER` (4).
Internals: rules compiled (`acl_bld.c`) into up to `RTE_ACL_MAX_TRIES` = 8 multi-bit tries (stride 8 bits =
one input byte per transition); build splits rules into non-overlapping subsets to bound memory (`max_size`
→ `-ERANGE` if exceeded). Node types (`acl.h`): DFA (256-way), QRANGE (quad-range, compressed), SINGLE,
MATCH. Runtime (`acl_run_*.c`) walks several flows in parallel: scalar 2, SSE 4/8, AVX2 16, AVX512X16 16,
AVX512X32 32 (`MAX_SEARCHES_*` in `acl_run.h`); default alg = best supported within EAL max SIMD bitwidth.
**Byte order trap**: rules are added in **host order**, classify input must be **network order** (raw packet
bytes). Rules are immutable after build: updates = new context + build + pointer swap (with RCU/epoch).
**Verified**: l3fwd `--lookup=acl` with `07-examples/acl_rules_v4.txt` (one `@` drop rule for UDP to
198.18.3.0/24 dport 2000-2002 + four `R` route rules) dropped exactly the 214 matching packets
(port1 out 786 of 1000). ipsec-secgw's SPD log shows the ACL context dump (`num_tries=1, alg=6`).
Extra tools in tree (not built here): `app/test-acl` (`dpdk-test-acl`, rule/trace files in
`app/test-acl/input/`).
**Viz**: rule set → trie building animation (bytes as levels, ranges splitting into QRANGE nodes);
"N flows walking the trie in lockstep" SIMD lanes animation; category bitmask matrix (rules × categories).

### 3.6 EFD (`lib/efd`)
Elastic Flow Distributor: maps key → small value (target id) **without storing keys**, using a two-level
scheme: key → group (~22 keys per group, `EFD_TARGET_GROUP_NUM_RULES`=22), and per group a brute-force-found
hash function index such that `h_idx(key)` yields the right value bits for every key in the group (perfect
hashing for the value bits). Online table (small, per-socket, lookup) vs offline table (keys, used for updates).
API: `rte_efd_create(name, max_num_rules, key_len, online_socket_bitmask, offline_socket_id)`,
`rte_efd_update(table, socket, key, value)` (returns 0 / `RTE_EFD_UPDATE_WARN_GROUP_FULL` /
`_NO_CHANGE` / `_FAILED`), `rte_efd_delete`, `rte_efd_lookup`, `rte_efd_lookup_bulk` (≤ `RTE_EFD_BURST_MAX`=32).
Semantics: lookup of an unknown key returns an **arbitrary** value (no membership). Inspiration: ScaleBricks
(SIGCOMM'15, SetSep). Sample: `examples/server_node_efd` (built: `dpdk-efd_server`, `dpdk-efd_node`; uses
multi-process — needs 2+ ports; better to write a standalone demo).
**Example idea**: 100 k flows → 4 "backend" ids; compare memory of EFD vs rte_hash; show that a never-inserted
key still returns some id.
**Viz**: the doc's `efd_i*.svg` sequence (front-end LB → consistent hashing → flow table → EFD) as a stepper;
animation of the brute-force search trying hash indices until all keys in a group map correctly.

### 3.7 Member (`lib/member`)
Set-summary library: `rte_member_create(&struct rte_member_parameters{type = RTE_MEMBER_TYPE_HT | VBF |
SKETCH, is_cache, num_keys, key_len, num_set, false_positive_rate, prim/sec_hash_seed, socket_id, ...})`,
`rte_member_add`, `rte_member_lookup[_bulk|_multi|_multi_bulk]` (returns set id), `rte_member_delete`,
`rte_member_reset`, sketch: `rte_member_add_byte_count`, `rte_member_query_count`, `rte_member_report_heavyhitter`.
- HT: cuckoo-like table of signatures (16 entries/bucket, `RTE_MEMBER_BUCKET_ENTRIES`), "cache mode" may evict
  (false negatives possible), non-cache mode: no false negatives.
- vBF: vector of Bloom filters, one per set (≤ 32 sets); answer = which BF says yes; false positives only.
- Sketch: count-min sketch with top-k heap (`rte_member_heap.h`), AVX-512 path; heavy-hitter detection.
**Viz**: Bloom filter bit array animation with k hash arrows; FP-rate curve vs bits/key; count-min grid with
min-of-row estimate.

### 3.8 IP fragmentation & reassembly (`lib/ip_frag`)
API: `rte_ipv4_fragment_packet(pkt_in, pkts_out[], nb_out, mtu, pool_direct, pool_indirect)`,
`rte_ipv6_fragment_packet`, `rte_ipv4_fragment_copy_nonseg_packet` (copying variant),
`rte_ip_frag_table_create(bucket_num, bucket_entries, max_entries, max_cycles, socket)`,
`rte_ipv4_frag_reassemble_packet(tbl, death_row, mb, tms, ip_hdr)`, `rte_ipv6_frag_reassemble_packet`,
`rte_ipv4_frag_pkt_is_fragmented`, `rte_ip_frag_free_death_row`, `rte_ip_frag_table_del_expired_entries`,
`rte_ip_frag_table_statistics_dump`. Max fragments per packet `RTE_LIBRTE_IP_FRAG_MAX_FRAG` = 8 (config/rte_config.h).
Internals: input must start at the L3 header (strip L2 first); each fragment = direct mbuf (new L3 header) +
indirect mbuf attached to the original payload (zero copy, refcnt). Reassembly table: key <src, dst, id>,
two hash functions × bucket_entries (no cuckoo moves: failure if all 2×entries busy), entries older than
`max_cycles` recycled; freed mbufs go to a **death row** the caller must flush.
**Measured** (`frag_reasm.c`): 4028-byte datagram, MTU 1500 → 3 fragments (1500/1500/1068, offsets 0/1480/2960,
MF 1/1/0, each 2 segments), original refcnt 1 → **4**, and **IPv4 header checksum is 0** in fragments (library
does not compute it — set `RTE_MBUF_F_TX_IP_CKSUM` or call `rte_ipv4_cksum`). Out-of-order feed 2,0,1 →
reassembled 4028-byte packet as a 6-segment chain (no copy).
**Pitfalls**: the API needs `l2_len`/`l3_len` set for reassembly; fragmenting needs two pools (indirect pool
with data room 0); caller still owns `pkt_in` (free it); table not thread-safe; reassembly can hold
`2 × bucket_entries × MAX_FRAG` mbufs → size pools accordingly; forgetting `rte_ip_frag_free_death_row`
leaks mbufs. Sample apps `ip_fragmentation`/`ip_reassembly` **refuse vdevs without RX checksum offload**
(no relax switch) — so on this VM demonstrate with the standalone program, or via net_tap (has cksum offload).
**Viz**: animation of a big packet being sliced into fragments, with arrows from indirect mbufs into the
original buffer and a refcnt counter; reassembly table with fragments arriving out of order and timeout ring.

### 3.9 GSO (`lib/gso`) and GRO (`lib/gro`)
GSO: `struct rte_gso_ctx{direct_pool, indirect_pool, flag (RTE_GSO_FLAG_IPID_FIXED), gso_types
(RTE_ETH_TX_OFFLOAD_TCP_TSO | UDP_TSO | VXLAN_TNL_TSO | GRE_TNL_TSO), gso_size}`,
`rte_gso_segment(pkt, &ctx, pkts_out, nb_out)`. Requires `ol_flags` (`RTE_MBUF_F_TX_TCP_SEG |
RTE_MBUF_F_TX_IPV4`), `l2_len/l3_len/l4_len`. Each segment = header copy (direct) + indirect payload;
does not compute checksums; does **not free the input** (caller frees; segments hold references).
GRO: types `RTE_GRO_TCP_IPV4`, `RTE_GRO_TCP_IPV6`, `RTE_GRO_UDP_IPV4`, `RTE_GRO_IPV4_VXLAN_TCP_IPV4`,
`RTE_GRO_IPV4_VXLAN_UDP_IPV4`. Lightweight `rte_gro_reassemble_burst(pkts, n, &param)` (stack tables,
≤ `RTE_GRO_MAX_BURST_ITEM_NUM`=128) vs heavyweight `rte_gro_ctx_create` / `rte_gro_reassemble` /
`rte_gro_timeout_flush` / `rte_gro_get_pkt_count`. Dispatch is by **`mbuf->packet_type`**; key = flow
5-tuple + ACK etc. (`img/gro-key-algorithm.svg`); merges in-order TCP segments by chaining mbufs
(no copy), no checksum recomputation, honors RFC 6864 IP-ID rules; not thread-safe.
**Measured** (`gso_gro.c`): 8054-byte TCP/IPv4 packet, gso_size 1514 → 6 segments (5×1514 + 754),
IP IDs 100..105, seq 1000, 2460, ... (+1460 each); GRO merges them back into **1 packet of 8054 bytes /
12 mbuf segments**.
Also: testpmd has `set port <p> gro on`, `gro flush`, `set gso segsz`, `csum` fwd engine.
**Pitfalls**: GRO silently does nothing if `packet_type` is 0 (vdevs like net_pcap don't set it → use
`rte_net_get_ptype`); pure ACK / SYN / FIN packets are not merged; GSO output needs a TX path supporting
multi-segment mbufs; IP-ID handling (`IPID_FIXED`).
**Viz**: accordion animation — one big packet folding into N segments (headers duplicated, seq numbers
ticking) and back; a GRO flow table showing items merging and timeout flush.

### 3.10 Meter and policer (`lib/meter`, `examples/qos_meter`)
API (`rte_meter.h`): profiles `rte_meter_srtcm_profile_config(&p, &rte_meter_srtcm_params{cir, cbs, ebs})`
(RFC 2697), `rte_meter_trtcm_profile_config(&p, &{cir, pir, cbs, pbs})` (RFC 2698),
`rte_meter_trtcm_rfc4115_profile_config(&p, &{cir, eir, cbs, ebs})` (RFC 4115); per-flow state
`rte_meter_*_config(&m, &p)`; inline checks `rte_meter_srtcm_color_blind_check(m, p, time_tsc, pkt_len)`,
`..._color_aware_check(..., pkt_color)` returning `enum rte_color { RTE_COLOR_GREEN, YELLOW, RED }`.
Rates in **bytes/second**, time in **TSC cycles**, internally converted to "bytes per period"
(`cir_period`, `cir_bytes_per_period`) to avoid divisions per packet. srTCM: C bucket overflows into E bucket.
Policer: `examples/qos_meter/rte_policer.c` = color-in × color-out → action table (GREEN/YELLOW/RED/DROP),
`main.c` meters each packet (flow chosen by... a single flow array), compile-time `APP_MODE` selects
srTCM/trTCM, blind/aware.
**Measured** (`meter_demo.c`, synthetic time, 1500-byte packets at 2× CIR = 2 MB/s, CIR 1 MB/s,
CBS 15 KB, EBS 30 KB, PIR 1.5 MB/s):
first 100 ms srTCM G/Y/R = 76/20/37 (initial bursts), then steady **66/0/67** — yellow drops to 0 because E
only fills from C overflow, which never happens under sustained overload; trTCM steady **66/33/33**
(green = CIR share, yellow = (PIR−CIR) share, red = rest). Great "aha" moment.
**Viz**: two-bucket animation (water/token levels) with packets arriving as droplets coloured on exit;
slider for offered rate; plot of colour fractions vs offered load for srTCM vs trTCM vs RFC4115.

### 3.11 Hierarchical scheduler (`lib/sched`) + RED/PIE
Doc: `doc/guides/prog_guide/ethdev/qos_framework.rst` (1762 lines — the deepest doc in this area).
Hierarchy: **port → subport → pipe → traffic class → queue**. 16 queues per pipe
(`RTE_SCHED_QUEUES_PER_PIPE`): **13 TCs** (`RTE_SCHED_TRAFFIC_CLASSES_PER_PIPE` = 16 − 4 + 1): TC0..TC11 strict
priority, 1 queue each, and best-effort TC12 (`RTE_SCHED_TRAFFIC_CLASS_BE`) with 4 queues served by **WRR**
(`wrr_weights[4]`).
Config API: `rte_sched_port_config(&rte_sched_port_params{name, socket, rate (bytes/s), mtu, frame_overhead
(RTE_SCHED_FRAME_OVERHEAD_DEFAULT = 24: preamble+SFD+IFG+FCS), n_subports_per_port (pow2), subport_profiles,
n_subport_profiles, n_max_subport_profiles, n_pipes_per_subport (pow2)})`,
`rte_sched_subport_config(port, id, &rte_sched_subport_params{n_pipes_per_subport_enabled, qsize[13],
pipe_profiles, n_pipe_profiles, n_max_pipe_profiles, cman_params}, subport_profile_id)`,
`rte_sched_pipe_config(port, subport, pipe, profile)`, `rte_sched_subport_pipe_profile_add`,
`rte_sched_port_subport_profile_add`, `rte_sched_subport_tc_ov_config` (TC oversubscription),
pipe profile `rte_sched_pipe_params{tb_rate, tb_size, tc_rate[13], tc_period (ms), tc_ov_weight, wrr_weights[4]}`,
congestion mgmt `rte_sched_cman_params{cman_mode = RTE_SCHED_CMAN_RED | RTE_SCHED_CMAN_PIE,
red_params[13][3 colours] | pie_params[13]}`.
Data path: classify → `rte_sched_port_pkt_write(port, m, subport, pipe, tc, queue, color)` (stored in mbuf
sched field) → `rte_sched_port_enqueue(port, pkts, n)` (drops/free on full or RED) →
`rte_sched_port_dequeue(port, pkts, n)` → TX. Stats `rte_sched_subport_read_stats`, `rte_sched_queue_read_stats`.
Internals: per-port active-queue **bitmap**; dequeue uses **grinders** (`RTE_SCHED_PORT_N_GRINDERS` = 8, `rte_sched.c`) — a
prefetch state machine that switches pipe while prefetches are in flight (`img/pipe_prefetch_sm.png`);
token buckets at subport & pipe, TC credits refreshed per `tc_period`; scheduling decision requires credits
at subport, subport-TC, pipe and pipe-TC; frame overhead added to every length.
**Crucial insight (found experimentally)**: the scheduler's notion of time is the *port byte clock*:
`rte_sched_port_time_resync()` sets `port->time = max(port->time, bytes elapsed since start at port rate)`
and every dequeued byte advances `port->time`. If you dequeue in a tight loop with no real TX backpressure,
time runs ahead and **absolute rates are not enforced** — only ratios. My first `sched_mini.c` run sent
~2.6 GB/s through a "1 MB/s" port. Pacing dequeue at line rate (emulated NIC: dequeue only when link
budget allows) gives the expected result: pipe 0 (limit 100 KB/s) **98 000 B/s**, pipes 1-3 (limit 400 KB/s,
oversubscribed port) **~293 000 B/s each**, strict priority TC0 got 879 KB vs best-effort 97 KB.
Sample: `examples/qos_sched` (`profile.cfg`, `profile_red.cfg`, `profile_pie.cfg`, `profile_ov.cfg`;
`--pfc "rx,tx,wt"` core mapping; 4096 pipes by default → heavy memory; not run here). The newer hardware
abstraction is `rte_tm` (ethdev). RED/PIE: `rte_red.h` (`rte_red_config_init`, `rte_red_enqueue`, EWMA
`wq_log2`, `maxp_inv`), `rte_pie.h` (`rte_pie_config_init`, `rte_pie_enqueue`, latency target, `dp_update_interval`).
**Viz**: tree diagram (port/subport/pipe/TC/queue) with live queue fill bars; grinder animation (3 grinders
juggling pipes while prefetch arrows complete); credit buckets per level draining; WRR wheel for TC12;
RED drop-probability curve vs average queue length with EWMA smoothing animation.

### 3.12 BPF (`lib/bpf`)
API: `rte_bpf_load_ex(&struct rte_bpf_prm_ex{sz, origin = RTE_BPF_ORIGIN_RAW|CBPF|ELF_FILE|ELF_MEMORY,
elf_file{path, section}, nb_prog_arg, prog_arg[] {type = RTE_BPF_ARG_RAW | PTR | PTR_MBUF, size, buf_size},
xsym (external symbols/helpers), debug})`, legacy `rte_bpf_load`, `rte_bpf_elf_load`; execution
`rte_bpf_exec[_ex]`, `rte_bpf_exec_burst[_ex]`, JIT `rte_bpf_get_jit[_ex]` (x86-64 `bpf_jit_x86.c`, arm64
`bpf_jit_arm64.c`); `rte_bpf_destroy`, `rte_bpf_dump`, `rte_bpf_format`; cBPF → eBPF `rte_bpf_convert(const
struct bpf_program*)` (needs libpcap; `pcap_compile` output). Ethdev glue `rte_bpf_ethdev.h`:
`rte_bpf_eth_rx_elf_load(port, queue, prm, fname, sname, flags RTE_BPF_ETH_F_JIT)`, `rte_bpf_eth_rx_install`,
`rte_bpf_eth_rx_unload` (+ TX variants) — implemented as RX/TX **callbacks**; RX filter semantic: return 0 =
drop. Verifier `bpf_validate.c` (abstract interpretation, bounds tracking; hardened in 26.07) and
`rte_bpf_validate_debug_*` (breakpoints/catchpoints). Packet loads `BPF_ABS/BPF_IND` use
`rte_pktmbuf_read` (safe across segments) when arg is an mbuf.
**Verified**: `07-examples/drop_dport2001.c` (self-contained, no libc headers) built with
`clang -O2 -target bpf -c` (clang 18 here; including `<stdint.h>` fails with `gnu/stubs-32.h` — keep BPF C
header-free or use `-I/usr/include/x86_64-linux-gnu` plus a freestanding header), loaded into testpmd with
`bpf-load rx 0 0 J ./drop_dport2001.o` from a `--cmdline-file`: 1000 in → **857 forwarded** (143 = 1/7 with
dport 2001 dropped), while the no-BPF run forwards 1000. `drop_dport2001.dis` shows the 14-instruction eBPF.
testpmd flags: `J` = JIT, `M` = arg is mbuf pointer, `-` = arg is packet data pointer.
Also `app/validate-bpf` exists in tree (not built here); `examples/bpf/t1.c t2.c t3.c dummy.c`.
**Pitfalls**: testpmd **flushes RX queues at start** — with net_pcap the whole file is drained before
forwarding; pass `--no-flush-rx`. testpmd's default mbuf pool (155k mbufs) does not fit `-m 256 --no-huge`;
use `--total-num-mbufs=4096`. Port stats count the packet before the RX callback drops it.
**Viz**: eBPF register file + instruction stepper (interpreter) next to the JIT'd x86 listing; verifier
abstract-state animation (register ranges narrowing along branches); callback position in the
`rte_eth_rx_burst` pipeline.

### 3.13 SWX pipeline / port / table (`lib/pipeline`, `lib/port`, `lib/table`)
Model (P4-16 inspired; doc `packet_framework.rst`): everything defined at run time — `struct` types,
headers (`extract`/`emit`), metadata, actions (instruction lists), tables, externs, and the `apply {}` main
program. Ports: `rte_swx_port_ethdev.h`, `rte_swx_port_ring.h`, `rte_swx_port_source_sink.h` (pcap file
source with `loop N`, sink to pcap), `rte_swx_port_fd.h` (TAP fd). Tables: exact match `rte_swx_table_em.h`,
wildcard `rte_swx_table_wm.h` (uses ACL), learner (add-on-miss with timeouts) `rte_swx_table_learner.h`,
selector (ECMP groups) `rte_swx_table_selector.h`. Externs: meter, regarray, counters, hash funcs
(`rte_swx_hash_func.h`), IPsec block `rte_swx_ipsec.h`. Control: `rte_swx_ctl.h` (transactional multi-table
commit, P4Runtime-aligned). Execution: multiple packets in flight, each owned by a "thread" that yields before
memory accesses (prefetch), instructions translated & fused at build time; `pipeline codegen` translates
the spec into C, `pipeline libbuild` compiles a .so (needs `RTE_INSTALL_DIR` = DPDK source/installed tree).
Example specs in `examples/pipeline/examples/`: l2fwd, l2fwd_macswp, fib, learner, meter, selector, vxlan,
ipsec, mirroring, recirculation, registers, rss, hash_func, varbit, ipv6_addr_swap.
**Verified**: `07-examples/swx/l2fwd_pcap.cli` + `swx/pcap2.io` (two pcap **source** ports reading
`in.pcap` with `loop 1`, two pcap **sink** ports) — codegen+libbuild at startup, 1000 packets in on each
port, port i → port i^1 (`xor m.port 1`). **Pitfall**: `loop 0` means loop forever — my first run wrote
1.4 GB pcap files in 20 s. CLI is reachable by telnet on port 8086.
**Viz**: P4 parser state machine → table → action flow chart; multiple packet "threads" interleaving with
prefetch yields (Gantt chart); transactional table update (shadow copy then atomic swap).

### 3.14 Graph library + inbuilt nodes (`lib/graph`, `lib/node`)
Concepts: node = `struct rte_node_register{name, flags (RTE_NODE_SOURCE_F), process, init, fini, xstats,
nb_edges, next_nodes[]}` registered via `RTE_NODE_REGISTER()` (constructor) or `__rte_node_register`;
clones `rte_node_clone("base", "suffix")` → "base-suffix" (e.g. `ethdev_rx-0-0`, `ethdev_tx-1`).
Graph: `rte_graph_create(name, &rte_graph_param{socket_id, nb_node_patterns, node_patterns[] (shell globs)})`,
`rte_graph_lookup`, `rte_graph_clone` (per-worker copies), `rte_graph_walk(graph)` (RTC) or
`rte_graph_walk_mcore_dispatch` (dispatch model: nodes bound to lcores via `rte_graph_model_mcore_dispatch_node_lcore_affinity_set`,
objects handed across cores via rings), `rte_graph_export(name, FILE*)` (Graphviz),
`rte_graph_cluster_stats_create/get` (calls, objs, realloc_count, objs/call, cycles/call).
Fast path (`rte_graph_worker_common.h`): `rte_node_next_stream_get/put`, `rte_node_next_stream_move`
(**home run**: swap whole stream to next node, no pointer copies), `rte_node_enqueue_x1/x2/x4`,
`rte_node_enqueue_next` (array of edges), `rte_node_xstat_increment`. Burst size `RTE_GRAPH_BURST_SIZE`
= 256 (config/rte_config.h). Walk: nodes sorted by `(topo_order, node_id)` (BFS depth from sources), a
**pending bitmap**; walk scans lowest set bit (`rte_ctz64`), runs node, re-reads word — so fan-out/converge
topologies get one batched visit of the merge node. Streams grow on demand (`realloc_count`).
Inbuilt nodes (lib/node): `ethdev_rx`, `ethdev_tx`, `pkt_cls`, `ip4_lookup` (LPM; SSE/NEON/RVV x4),
`ip4_lookup_fib`, `ip4_rewrite`, `ip4_reassembly`, `ip4_local`, `udp4_input`, `ip6_lookup`, `ip6_lookup_fib`,
`ip6_rewrite`, `kernel_rx`, `kernel_tx`, `pkt_drop`, `null`, `interface_tx_feature`; control APIs in
`rte_node_ip4_api.h` (`rte_node_ip4_route_add`, `rte_node_ip4_rewrite_add`), `rte_node_eth_api.h`
(`rte_node_eth_config`). Feature arcs (`rte_graph_feature_arc*.h`): runtime-enable optional feature nodes
on an "arc" (e.g. `rte_ip4_output_arc`), RCU-synchronised control updates.
**Verified**: (a) `graph_mini.c` — custom source node `gen` (32 objs/walk) → `classify` (per-object
`rte_node_enqueue_x1` by parity) → `even`/`odd`; 1000 walks → 16000/16000, stats table and exported dot
(`graph_mini.dot`). (b) l3fwd-graph over net_pcap: stats table shows `ethdev_rx-0-0 → pkt_cls → ip4_lookup →
ip4_rewrite → ethdev_tx-{0,1}` with **1000 objs into `ip4_lookup_error`/`pkt_drop`** — l3fwd-graph installs
routes only for enabled ports, so 198.18.2/3.x are dropped, unlike l3fwd which sends unknown-port packets
back out the RX port. Note log line `Feature arc "rte_ip4_output_arc" not found` (harmless; arc not created).
Also `app/graph` (`dpdk-graph`, built) = CLI-driven graph usecases (`app/graph/examples/*.cli`, l3fwd, l2fwd).
**Viz**: node graph with packets as dots flowing in bursts; bitmap walk animation (bits lighting in topo order);
home-run vs per-packet enqueue comparison (pointer copies counter); RTC vs dispatch model core assignment.

### 3.15 Distributor (`lib/distributor`)
Roles: one distributor lcore (`rte_distributor_process(d, mbufs, n)`, `rte_distributor_returned_pkts`,
`rte_distributor_flush`, `rte_distributor_clear_returns`) and N workers (`rte_distributor_get_pkt(d, worker_id,
pkts, oldpkt, retcount)`, `rte_distributor_return_pkt`, `rte_distributor_request_pkt` / `poll_pkt`).
Create: `rte_distributor_create(name, socket, num_workers, RTE_DIST_ALG_BURST | RTE_DIST_ALG_SINGLE)`.
Burst mode: 8 packets per handoff (`RTE_DIST_BURST_SIZE`), 15-bit tag; single mode: 1 packet, 32-bit tag.
Tag = `mbuf->hash.usr` (RSS hash). Guarantees: packets with the same tag never processed concurrently and
returned in order; one cache line per worker shared with distributor (bufptr64 / retptr64 arrays in
`distributor_private.h`); `in_flight_tags` matching (SSE `rte_distributor_match_sse.c`).
Sample: `examples/distributor` (`dpdk-distributor` built; needs RX/TX/distributor/worker lcores; can run on
2 net_pcap or net_ring ports with `-l 0-3`). Related: `examples/packet_ordering` (reorder library).
Pitfall: workers that buffer packets internally break per-tag ordering (doc note); vdevs need to set
`hash.usr`/RSS or the sample sets tags itself.
**Viz**: distributor core as a dealer handing cards (bursts) to workers, same-colour (tag) cards always to the
busy worker; return path re-ordering.

### 3.16 IPsec library (`lib/ipsec`) and ipsec-secgw
SA: `rte_ipsec_sa_size(&prm)`, `rte_ipsec_sa_init(sa, &struct rte_ipsec_sa_prm{userdata, flags
(RTE_IPSEC_SAFLAG_*), ipsec_xform (struct rte_security_ipsec_xform: spi, mode tunnel/transport, direction,
options esn/replay...), crypto_xform, tun{hdr_len, hdr_l3_off, next_proto, hdr template} | trs{proto}},
size)`, `rte_ipsec_sa_type`, `rte_ipsec_sa_fini`. Session: `struct rte_ipsec_session{sa, type =
RTE_SECURITY_ACTION_TYPE_NONE | CPU_CRYPTO | INLINE_CRYPTO | INLINE_PROTOCOL | LOOKASIDE_PROTOCOL, crypto/security
session}` + `rte_ipsec_session_prepare`. Data path (async): `rte_ipsec_pkt_crypto_prepare(ss, mb, cop, n)` →
`rte_cryptodev_enqueue_burst` → `rte_cryptodev_dequeue_burst` → `rte_ipsec_pkt_crypto_group` (group crypto
ops back by session, `rte_ipsec_group.h`) → `rte_ipsec_pkt_process(ss, mb, n)`. Sync CPU crypto:
`rte_ipsec_pkt_cpu_prepare` + `process`. Stateless variants `..._prepare_stateless` (26.x). Telemetry
`rte_ipsec_telemetry_sa_add`. Internals: `esp_outb.c` (SQN+IV generation, outer header from template, padding,
ICV), `esp_inb.c` (replay window `ipsec_sqn.h`, ICV check, strip), `sa.c` per-type function pointers.
SAD (`rte_ipsec_sad.h`): keys `RTE_IPSEC_SAD_SPI_ONLY | SPI_DIP | SPI_DIP_SIP` (RFC 4301 longest match),
implemented with three rte_hash tables (`ipsec_sad.c`, CRC hash), `rte_ipsec_sad_create/add/del/lookup`.
**ipsec-secgw** (`examples/ipsec-secgw`): SPD with ACL (`sp4.c`, `sp6.c`), routing with LPM/LPM6 (`rt.c`),
SAs (`sa.c`, `sad.c`), its own ESP path (`esp.c`, legacy) or librte_ipsec (`-l` / `ipsec_process.c`), poll or
event mode (`ipsec_worker.c`, `event_helper.c`), inline offload via rte_flow (`flow.c`).
Terminology trap: **unprotected port (`-u` mask) = the ESP/WAN side**; cleartext enters on *protected* ports.
**Verified** (`07-examples/run_secgw.sh`, `secgw_min.cfg`): two **net_tap** ports (`ch07sg0`, `ch07sg1`;
net_pcap/null/ring cannot be used because the app hard-requires RX checksum offload `RTE_ETH_RX_OFFLOAD_CHECKSUM`
in `port_conf`), `--vdev=crypto_openssl0`, `-p 0x3 -P -u 0x2 --config="(0,0,1),(1,0,1)"`, SA 5 = ESP tunnel
AES-128-CBC + SHA1-HMAC 172.16.1.5 → 172.16.2.5. 100 cleartext UDP frames injected from the kernel side into
ch07sg0 with an AF_PACKET socket (`tap_inject.py`) → 100 ESP frames captured on ch07sg1: proto 50, SPI 5,
SEQ 1, 2, 3..., 106-byte frames became 166 bytes (+20 outer IP, +8 ESP hdr, +16 IV, +pad/trailer to the
16-byte block, +12 ICV). With `-u 0x1` (wrong side) all 100 were dropped — a good exercise.
App also requires an inbound SA/SP when an unprotected port is configured; needs 1 TX queue per lcore
(use `-l 1` only for single-core demos). Test harness in `examples/ipsec-secgw/test/` (needs two hosts/netns).
**Viz**: packet transformation animation (inner IP → +ESP hdr/IV → encrypted payload → trailer → ICV → outer
IP) with byte counts; SPD (ACL) → SAD (hash) → crypto → route (LPM) pipeline; replay window sliding bitmap.

### 3.17 PDCP (`lib/pdcp`)
3GPP TS 38.323 PDCP entity on top of cryptodev (+ `rte_reorder`, `pdcp_reorder.c`): `rte_pdcp_entity_establish(
&struct rte_pdcp_entity_conf)`, `rte_pdcp_entity_suspend`, `rte_pdcp_entity_release`,
`rte_pdcp_control_pdu_create` (status report), `rte_pdcp_pkt_pre_process` → cryptodev → `rte_pdcp_pkt_crypto_group`
→ `rte_pdcp_pkt_post_process`, `rte_pdcp_t_reordering_expiry_handle` (timer integration is the app's job).
Header defs `lib/net/rte_pdcp_hdr.h`. Same prepare/process split as IPsec. Testable only via
`app/test` (`pdcp_autotest`, not built here) — keep to one conceptual section with a diagram
(`img/pdcp_functional_overview.svg`).

---

## 4. Classic sample apps — what to teach & exact commands that work here

All commands verified on this VM (see `07-examples/run_all.sh`; generated traffic `in.pcap` = 1000 UDP
packets to 198.18.{0,1,2,3}.x, sport 1000-1049, dport 2000-2006, made by `gen_pcap.py`, no scapy needed).

**l2fwd** (`examples/l2fwd/main.c`): port pairs (0↔1), `l2fwd_simple_forward` rewrites dst MAC to
02:00:00:00:00:<dst port> and src MAC to port MAC, `rte_eth_tx_buffer` batching with drain timer, stats every `-T` s.
```
dpdk-l2fwd -l 0,1 --no-pci --no-huge -m 128 --file-prefix=ch07l2 \
  --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=l2out0.pcap \
  --vdev=net_pcap1,rx_pcap=empty.pcap,tx_pcap=l2out1.pcap -- -p 0x3 -q 2 -T 1
```
Result: port0 RX 1000 → port1 TX 1000, MACs rewritten, TTL unchanged. (`-l 1` alone fails: "Not enough cores".)

**l3fwd** (`examples/l3fwd`): `--lookup=lpm|fib|em|acl`, routes from `lpm_default_v4.cfg` (198.18.N.0/24 → port N),
EM 5-tuple table `em_default_v4.cfg`, ACL rule file format `@`/`R` lines; vector paths `l3fwd_sse.h`,
`l3fwd_em_hlm*.h` (hash multi-lookup), `l3fwd_lpm_sse.h` (`rte_lpm_lookupx4`), eventdev mode `--mode=eventdev`.
```
dpdk-l3fwd -l 1 --no-pci --no-huge -m 256 --file-prefix=ch07l3 \
  --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=out0.pcap --vdev=net_pcap1,rx_pcap=in.pcap,tx_pcap=out1.pcap \
  -- -p 0x3 --config="(0,0,1),(1,0,1)" --lookup=lpm --parse-ptype --disable-rss --relax-rx-offload
```
Needed flags on vdevs: `--relax-rx-offload` (else "does not support Rx offloads IPV4_CKSUM,UDP_CKSUM,TCP_CKSUM"),
`--parse-ptype` (vdev has no ptype), `--disable-rss`. EM needs `-m 1024` (4M-entry hash, `L3FWD_HASH_ENTRIES`).
Results: lpm/fib: 198.18.0.x → port0, .1.x → port1, .2/.3.x (ports 2,3 not enabled) → back out RX port; TTL 64→63,
dst MAC 02:00:00:00:00:0N. em: all 1000 hash misses (our 5-tuples are not in the EM table) → out RX port. acl: as
lpm, minus the 214 dropped by the `@` rule.

**l3fwd-graph** (`examples/l3fwd-graph/main.c`): same CLI style plus `--model rtc|dispatch`, `--pcap-enable`.
```
dpdk-l3fwd-graph -l 0,1 --no-pci --no-huge -m 640 --file-prefix=ch07g \
  --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=o0.pcap,tx_pcap=o0b.pcap \
  --vdev=net_pcap1,rx_pcap=in.pcap,tx_pcap=o1.pcap,tx_pcap=o1b.pcap -- -p 0x3 --config="(0,0,1),(1,0,1)"
```
Needs one TX queue per lcore (two `tx_pcap=` per port make 2 queues), LPM6 needs > 256 MB. Prints a live node
stats table (screen-clearing escape codes; strip `\033[2J`).

**ipsec-secgw**: see 3.16 (`run_secgw.sh`).

**Others relevant & built**: `dpdk-qos_meter`, `dpdk-qos_sched`, `dpdk-ip_fragmentation` / `dpdk-ip_reassembly`
(need RX cksum offload → net_tap), `dpdk-distributor`, `dpdk-packet_ordering`, `dpdk-efd_server/efd_node`,
`dpdk-pipeline`, `dpdk-graph` (app). Not built: `dpdk-test` (unit tests like `hash_autotest`, `lpm_autotest`,
`acl_autotest`), `dpdk-test-acl`, `dpdk-test-fib`, `dpdk-test-sad` — so course examples must be standalone programs.

---

## 5. Runnable example catalogue (files in `07-examples/`, all verified)

| File | Shows | Run (after `source dpdk-env.sh`, compile `gcc x.c -o x $(pkg-config --cflags libdpdk) $(pkg-config --libs --static libdpdk)`) |
|---|---|---|
| `gen_pcap.py`, `pcap_summary.py` | dependency-free pcap generator / per-(MAC, /24, TTL) summary | `python3 gen_pcap.py in.pcap 1000` |
| `hash_fill.c` | cuckoo load factor (98.6 %, 100 % with EXT_TABLE), single vs bulk lookup cycles, crc vs jhash | `./hash_fill --no-huge -m 128 --no-pci --file-prefix=ch07h` |
| `lpm_fib.c` | same routes in LPM, FIB (DIR24_8 4B) and RIB; tbl8 case; miss vs default_nh; cycles | `--no-huge -m 256` (+`--force-max-simd-bitwidth=512`) |
| `meter_demo.c` | srTCM vs trTCM colours at 2× CIR with synthetic TSC time | `--no-huge -m 64` |
| `frag_reasm.c` | zero-copy fragmentation (refcnt, cksum 0), out-of-order reassembly, death row | `--no-huge -m 128` |
| `gso_gro.c` | GSO 8054 B → 6 segs, GRO back to 1 pkt (packet_type requirement) | `--no-huge -m 128` |
| `graph_mini.c` | custom nodes, source node, per-object enqueue, cluster stats, `rte_graph_export` dot | `--no-huge -m 128` |
| `sched_mini.c` | 1 subport / 4 pipes / TC0 vs TC12, emulated NIC pacing, stats | `--no-huge -m 256`, ~1 s |
| `drop_dport2001.c`, `bpf_cmds.txt` | eBPF filter via testpmd `bpf-load rx 0 0 J` | `clang -O2 -target bpf -c ...` then testpmd with `--no-flush-rx --total-num-mbufs=4096 --cmdline-file=bpf_cmds.txt` |
| `acl_rules_v4.txt`, `acl_rules_v6.txt` | l3fwd ACL rule format (`@` drop + `R` route) | l3fwd `--lookup=acl --rule_ipv4=... --rule_ipv6=...` |
| `swx/l2fwd_pcap.cli`, `swx/pcap2.io`, `swx/l2fwd.spec` | SWX pipeline with pcap source/sink ports | `RTE_INSTALL_DIR=$DPDK_SRC dpdk-pipeline -l 0,1 --no-huge -m 256 --no-pci --file-prefix=ch07swx -- -s swx/l2fwd_pcap.cli` |
| `secgw_min.cfg`, `run_secgw.sh`, `tap_inject.py` | ipsec-secgw ESP tunnel over net_tap + crypto_openssl, kernel-side inject/capture | `./run_secgw.sh` (root) |
| `run_tap_test.sh` | sanity check: testpmd io fwd between two net_tap ports, kernel inject/capture | `./run_tap_test.sh` |
| `run_all.sh` | everything above end to end (~90 s), cleans its `/var/run/dpdk/ch07*` dirs | `./run_all.sh` |

Further example ideas (not yet written, all feasible here):
- `thash_rss.c`: compute Toeplitz RSS of 5-tuples with `rte_softrss`/GFNI, show symmetric-key trick,
  predictable RSS (`rte_thash_adjust_tuple`) to pick a source port landing on a given queue.
- `hash_rcu.c`: 1 writer deleting/adding, 2 readers looking up, `RW_CONCURRENCY_LF` + `rte_hash_rcu_qsbr_add`;
  print defer-queue reclaim counts.
- `acl_5tuple.c`: standalone ACL with 2 categories (doc example), classify with every alg (`SCALAR`, `SSE`,
  `AVX2`, `AVX512X16`, `AVX512X32`) and time them; show `-ERANGE` with small `max_size`.
- `efd_vs_hash.c`, `member_vbf.c`: memory and false-positive measurement.
- `distributor` sample over `net_ring` ports, or a self-contained distributor+workers program with tags.
- `rib_pic.c`: RIB extension storing backup nh; fail a next hop and repoint all covered prefixes.
- l3fwd `--lookup=em` with a pcap whose 5-tuples match `em_default_v4.cfg` (src 198.18.N.1, dst 198.18.N.0,
  ports 9/9, UDP) to show EM hits.
- `qos_meter` sample on net_pcap (check its offload requirements first).

---

## 6. Visualization / animation catalogue (for HTML chapters)

1. **Packet byte map** (lib/net): Ethernet/IPv4/UDP bytes as a grid; hovering a struct field highlights bytes;
   toggle host/network order; checksum folding animation.
2. **Cuckoo hash**: 8-slot buckets, signature + key index, BFS displacement path animation; load-factor slider
   with primary/secondary split; LF-reader retry on `tbl_chng_cnt` change.
3. **RCU QSBR timeline**: writer delete → defer queue → reader quiescent ticks → reclaim.
4. **DIR-24-8**: 32-bit address split 24|8, tbl24 cell → tbl8 group pointer; prefix expansion painting;
   delete re-expanding the covering prefix; memory bar (64 MiB tbl24 vs tbl8 groups); FIB nh_sz effect.
5. **RIB tree ↔ FIB arrays** synchronized insert; prefix-independent convergence flip.
6. **ACL trie walk**: byte-by-byte transitions, DFA vs QRANGE nodes, SIMD lanes walking 8/16/32 flows,
   categories as a colour matrix.
7. **EFD**: group → hash-index brute force search; "unknown key gets arbitrary target".
8. **Bloom filter / vBF / count-min** bit grids with hash arrows.
9. **Fragmentation**: slicing + indirect mbuf arrows + refcnt; reassembly table with out-of-order arrivals,
   timeout, death row.
10. **GSO/GRO accordion**: seq numbers and IP IDs ticking; GRO flow table + flush.
11. **Token buckets** (srTCM C→E overflow, trTCM two independent buckets) with coloured droplets; colour-vs-load plot.
12. **QoS hierarchy tree** with queue-fill bars; grinder prefetch state machine; credit buckets per level; WRR
    wheel; RED drop-probability curve with EWMA.
13. **eBPF stepper**: registers, instruction pointer, verifier ranges; JIT x86 listing side by side.
14. **SWX packet threads**: Gantt chart of interleaved packets yielding at table lookups; transactional update.
15. **Graph walk**: node DAG, bursts as dots, pending-bitmap scan in topo order, home-run (stream move) vs
    per-object copy counter; RTC vs dispatch model on lcores; feature arc enabling a node live.
16. **Distributor dealer**: tag-affinity handoff, in-flight tag table, ordered returns.
17. **ESP encapsulation**: byte-accurate growth 106 → 166 bytes; SPD→SAD→crypto→route pipeline; replay window.
18. **l3fwd vs l3fwd-graph** fate of packets to disabled ports (back out RX port vs pkt_drop) — use the real
    pcap_summary outputs as data.

---

## 7. Pitfalls master list (with evidence)

- **Byte order**: LPM/FIB/RIB/hash-of-your-struct take host-order IPs (`RTE_IPV4()`), packets are network
  order; ACL rules host order but classify input network order; FIB has `RTE_FIB_F_LOOKUP_NETWORK_ORDER`.
- **Memory**: one LPM = 64 MiB tbl24 (+tbl8s), LPM6 similar → `--no-huge -m 256` OK for one, l3fwd-graph
  needed `-m 640`; l3fwd EM 4M-entry hash needed `-m 1024`; testpmd default mbuf count does not fit `-m 256`.
- **vdev capabilities**: net_pcap/null/ring have no RX checksum offload and no ptype → l3fwd needs
  `--relax-rx-offload --parse-ptype --disable-rss`; ip_fragmentation, ip_reassembly and ipsec-secgw hard-require
  checksum offload → use net_tap (or standalone programs). 26.11 also rejects RSS config with >1 RX queue
  on drivers without RSS offloads.
- **TX queues per lcore**: l3fwd-graph and ipsec-secgw configure one TX queue per enabled lcore → with
  net_pcap give multiple `tx_pcap=` per port or use a single lcore.
- **testpmd + pcap**: RX queues are flushed at forwarding start → `--no-flush-rx`.
- **Ownership**: ip_frag and GSO never free the input packet; GRO returns merged packets in place; ip_frag
  death row must be flushed.
- **Checksums**: fragmentation leaves IPv4 cksum = 0; GSO/GRO don't touch checksums.
- **GRO needs `packet_type`** set (vdevs → `rte_net_get_ptype`).
- **Hash**: capacity not guaranteed without EXT_TABLE; LF mode needs RCU or manual `free_key_with_position`;
  `rte_hash_lookup` returns a position, not data.
- **ACL** contexts are immutable after build — rebuild & swap; categories multiple of 4; field layout rules.
- **sched** shapes against the port byte clock: dequeue must be paced by real TX capacity; port rate and
  `n_pipes_per_subport` must be power-of-2 counts where required; `tc_ov_weight` must be ≥ 1; `qsize[tc]=0` iff
  `tc_rate[tc]=0`.
- **meter**: rates in bytes/s, time in TSC cycles; srTCM yellow only from C overflow.
- **BPF**: clang `-target bpf` with glibc headers fails on this distro; keep programs header-free.
  RX filter return 0 = drop.
- **SWX pcap source `loop 0` = infinite**.
- **ipsec-secgw**: `-u` marks the *unprotected* (ESP) side; inbound SA/SP needed when `-u` is set.
- **Legacy pipeline API is gone in 26.11** — don't copy old tutorials.
- **Concurrency**: GRO ctx, ip_frag table, ACL build, LPM writes are not thread-safe; readers vs writers need RCU
  (`rte_lpm_rcu_qsbr_add`, `rte_fib_rcu_qsbr_add`, `rte_fib6_rcu_qsbr_add`, `rte_hash_rcu_qsbr_add`).

---

## 8. Suggested chapter split for this area (to feed the planner)

1. Packet headers, checksums and packet types (`lib/net`) — + l2fwd walkthrough.
2. Exact-match lookup: rte_hash (cuckoo, bulk, concurrency, RCU) + Toeplitz RSS.
3. Longest-prefix match: LPM/LPM6 → RIB → FIB, and l3fwd (lpm/fib/em).
4. Multi-field classification: ACL (+ l3fwd acl, SPD preview).
5. Compact/probabilistic structures: EFD and member (optional, can be merged into ch. 2).
6. Packet transforms: ip_frag, GSO, GRO.
7. QoS: meter/policer, hierarchical scheduler, RED/PIE.
8. Programmable data planes I: BPF.
9. Programmable data planes II: SWX pipeline (P4-like).
10. Graph architecture: graph + nodes + l3fwd-graph (+ feature arcs, dispatch model).
11. Multi-core distribution: distributor (and reorder) — can pair with eventdev chapter.
12. Capstone: IPsec library + ipsec-secgw (+ PDCP overview).

---

## 9. Source references

Docs (`$DPDK_SRC/doc/guides/`): `prog_guide/hash_lib.rst`, `toeplitz_hash_lib.rst`, `lpm_lib.rst`,
`lpm6_lib.rst`, `rib_lib.rst`, `fib_lib.rst`, `packet_classif_access_ctrl.rst`, `efd_lib.rst`, `member_lib.rst`,
`ip_fragment_reassembly_lib.rst`, `generic_receive_offload_lib.rst`, `generic_segmentation_offload_lib.rst`,
`ethdev/qos_framework.rst`, `ethdev/traffic_metering_and_policing.rst`, `ethdev/traffic_management.rst`,
`bpf_lib.rst`, `packet_framework.rst`, `graph_lib.rst` (1126 lines), `packet_distrib_lib.rst`, `ipsec_lib.rst`,
`pdcp_lib.rst`, `rcu_lib.rst`, `reorder_lib.rst`; images `prog_guide/img/` (dir_24_8_alg.svg, tbl24_tbl8*.svg,
rib_internals.svg, rib_pic.svg, efd_i1..12.svg, member_i1..7.svg, gro-key-algorithm.svg, gso-*.svg,
hier_sched_blk.png, sched_hier_per_port.*, pipe_prefetch_sm.png, anatomy_of_a_node.svg, link_the_nodes.svg,
graph_mem_layout.svg, graph_inbuilt_node_flow.svg, feature_arc-1/2.svg, packet_distributor1/2.png,
pdcp_functional_overview.svg, predictable_snat_*.svg); sample guides `sample_app_ug/l2_forward_real_virtual.rst`,
`l3_forward.rst`, `l3_forward_graph.rst`, `ipsec_secgw.rst`, `qos_metering.rst`, `qos_scheduler.rst`,
`ip_frag.rst`, `ip_reassembly.rst`, `dist_app.rst`, `pipeline.rst`, `server_node_efd.rst`;
`testpmd_app_ug` (bpf-load, gro/gso commands); release notes `rel_notes/release_26_11.rst` (removals),
`release_26_07.rst` (BPF), `release_26_03.rst` (hash, ACL hooks), `release_25_07.rst` (feature arc),
`release_25_11.rst` (FIB6 RCU).
Code: `lib/hash/rte_cuckoo_hash.{c,h}` (get_short_sig, get_alt_bucket_index, rte_hash_cuckoo_make_space_mw),
`lib/hash/compare_signatures_x86.h`, `lib/lpm/rte_lpm.{c,h}`, `lib/lpm/rte_lpm6.c`, `lib/fib/dir24_8*.{c,h}`,
`lib/fib/trie*.{c,h}`, `lib/rib/rte_rib.c`, `lib/acl/{acl_bld.c,acl_gen.c,acl_run_*.c,acl.h}`, `lib/efd/rte_efd.c`,
`lib/member/rte_member_{ht,vbf,sketch}.c`, `lib/ip_frag/*`, `lib/gro/gro_tcp4.c`, `lib/gso/gso_common.c`,
`lib/meter/rte_meter.h` (inline checks), `lib/sched/rte_sched.c` (grinder_*, rte_sched_port_time_resync),
`lib/sched/rte_red.h`, `rte_pie.h`, `lib/bpf/{bpf_validate.c,bpf_jit_x86.c,bpf_pkt.c,bpf_convert.c}`,
`lib/pipeline/rte_swx_pipeline.c`, `lib/table/rte_swx_table_*.c`, `lib/graph/{graph_populate.c,
rte_graph_model_rtc.h, rte_graph_worker_common.h, graph_feature_arc.c}`, `lib/node/{ip4_lookup.c,
ip4_rewrite.c, pkt_cls.c, ethdev_rx.c}`, `lib/distributor/rte_distributor.c`, `lib/ipsec/{sa.c,esp_outb.c,
esp_inb.c,ipsec_sad.c}`, `lib/pdcp/pdcp_process.c`; examples `examples/{l2fwd,l3fwd,l3fwd-graph,ipsec-secgw,
qos_meter,qos_sched,ip_fragmentation,ip_reassembly,distributor,packet_ordering,server_node_efd,pipeline,bpf}`;
apps `app/graph`, `app/test-acl`, `app/test-fib`, `app/test-sad`, `app/test-pmd/bpf_cmd.c`.
External/background: Gupta, Lin, McKeown, "Routing Lookups in Hardware at Memory Access Speeds" (INFOCOM 1998,
DIR-24-8); Pagh & Rodler, "Cuckoo Hashing" (2001); Fan, Andersen, Kaminsky, "MemC3" (NSDI 2013, partial-key
cuckoo — cited by hash_lib.rst); Zhou et al., "Scaling Up Clustered Network Appliances with ScaleBricks"
(SIGCOMM 2015, SetSep → EFD); RFC 2697 (srTCM), RFC 2698 (trTCM), RFC 4115; Floyd & Jacobson RED (1993),
RFC 8033 (PIE); RFC 6864 (IPv4 ID, GRO); RFC 4301/4303 (IPsec/ESP); 3GPP TS 38.323 (PDCP); P4-16 spec and
P4Runtime (SWX); VPP vector packet processing (inspiration for rte_graph's node/burst model).

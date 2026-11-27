# 08 — Accelerator frameworks: cryptodev, security, compressdev, eventdev, dmadev, bbdev, gpudev, mldev, regexdev, rawdev

Research note for the course planner. DPDK 26.11.0 (`$DPDK_SRC` = scratchpad/clone/dpdk, commit b848f8e).
Everything marked **[verified]** was compiled and run on this VM (4 vCPU, `--no-huge`, unique `--file-prefix`, no PCI).
Runnable sources + exact commands + observed output: `research/08-examples/` (see its README.md).

---------------------------------------------------------------------------------------------------

## 0. The one big idea: "the lookaside accelerator pattern"

Every accelerator class in DPDK (crypto, compress, DMA, baseband, ML, regex, raw) is the *same shape*
as ethdev, just with "operations" instead of packets:

```
 discover (vdev/PCI probe)  ->  info_get / capabilities
 configure(dev, nb_qps)     ->  queue_pair_setup(dev, qp, nb_desc, socket)
 [session / xform / model / rule-db create]   <- immutable per-flow state, created once
 start
 fast path (per lcore, per qp, lock-free, burst):
     op = op_alloc(pool) ; fill op (mbuf + offsets + session ptr)
     enqueue_burst(dev, qp, ops, n)     <- async: returns how many were *accepted*
     ... do other work ...
     dequeue_burst(dev, qp, ops, n)     <- poll for completions, check op->status
 stop / close / free sessions
```

Teaching point: once students know ethdev rx/tx bursts they already know 80 % of cryptodev, compressdev,
bbdev, mldev, regexdev. The only new concepts are **ops**, **sessions/xforms**, **capabilities**, and
**asynchrony (enqueue != done)**. Eventdev is the different one: it is a *scheduler*, not an offload, and it
glues the others together via **adapters**.

Device-class table (lib, header, op type, SW driver available on THIS machine):

| class | lib / header | unit of work | session-like object | SW PMD here |
|---|---|---|---|---|
| cryptodev | lib/cryptodev/rte_cryptodev.h, rte_crypto_sym.h, rte_crypto_asym.h | `struct rte_crypto_op` (+sym/asym) | `rte_cryptodev_sym_session_create()` / asym | crypto_null, crypto_openssl, crypto_scheduler |
| security | lib/security/rte_security.h | mbuf + metadata / crypto_op | `rte_security_session_create()` | none (needs HW: NIC inline / lookaside-protocol HW). crypto_scheduler forwards security ops to workers |
| compressdev | lib/compressdev/rte_compressdev.h, rte_comp.h | `struct rte_comp_op` | `private_xform` (stateless) / `stream` (stateful) | compress_zlib |
| eventdev | lib/eventdev/rte_eventdev.h (+adapters) | `struct rte_event` (16 B) | queues/ports/links | event_sw, event_skeleton |
| dmadev | lib/dmadev/rte_dmadev.h | descriptor in vchan ring (`ring_idx`) or `rte_dma_op` (enq/deq mode) | vchan | dma_skeleton |
| bbdev | lib/bbdev/rte_bbdev.h, rte_bbdev_op.h | `rte_bbdev_enc_op/dec_op` (turbo/LDPC/FFT/MLD-TS) | per-queue op_type | baseband_null (loopback, OP_NONE only) |
| gpudev | lib/gpudev/rte_gpudev.h | memory + comm flags/lists | – | none (CUDA driver not built) — API-only chapter |
| mldev | lib/mldev/rte_mldev.h | `struct rte_ml_op` | model (`rte_ml_model_load/start`) | none built (cnxk only in tree) — API only |
| regexdev | lib/regexdev/rte_regexdev.h | `struct rte_regex_ops` | rule DB | none (cn9k only) — API only |
| rawdev | lib/rawdev/rte_rawdev.h | opaque buffers | – | rawdev_skeleton (selftest) |

---------------------------------------------------------------------------------------------------

## 1. Recommended teaching order (easy -> hard)

1. **Why accelerators / lookaside vs inline vs CPU** — the common op model above; async enqueue/dequeue as a
   "restaurant order ticket" mental model.
2. **cryptodev basics** — device discovery, feature flags, capabilities, configure, qp setup, op pools,
   symmetric session with a *single* cipher xform (AES-CTR/CBC). Run on crypto_openssl, verify against `openssl` CLI.
3. **cryptodev chained xforms & AEAD** — cipher->auth (encrypt-then-MAC) vs auth->cipher; AES-GCM AEAD;
   IV in op private area (`rte_crypto_op_ctod_offset`), digest placement, offsets/lengths, in-place vs
   out-of-place (`m_dst`), session-less mode.
4. **cryptodev asymmetric** — modexp/RSA/ECDSA/EdDSA/ML-KEM/ML-DSA (openssl PMD supports all incl. post-quantum).
5. **Performance & composition** — `dpdk-test-crypto-perf`, crypto_scheduler (round-robin/pkt-size/failover/
   multicore), `rte_cryptodev_sym_cpu_crypto_process` (sync CPU crypto), raw data-path API, callbacks.
6. **compressdev** — stateless DEFLATE with private_xform; stateful streams; checksums; out-of-space handling.
7. **dmadev** — vchan, `ring_idx`, submit/doorbell, completion, fences, silent mode, SG, fill; dma_skeleton.
8. **eventdev fundamentals** — event struct, queues, ports, links, schedule types (ATOMIC/ORDERED/PARALLEL),
   op NEW/FORWARD/RELEASE, priorities, credits/`new_event_threshold`; event_sw is a *service* -> service cores.
9. **eventdev pipelines** — multi-stage pipelines, atomic for flow-state, ordered for reordering, single-link
   queues, `dpdk-test-eventdev`, `eventdev_pipeline` and `l2fwd-event` examples.
10. **eventdev adapters** — eth Rx/Tx adapter, timer adapter, crypto adapter (OP_NEW vs OP_FORWARD), DMA adapter,
    vector adapter, dispatcher library; capabilities decide "HW internal port" vs "SW service".
11. **rte_security & IPsec** — action types (NONE / INLINE_CRYPTO / INLINE_PROTOCOL / LOOKASIDE_PROTOCOL /
    CPU_CRYPTO), protocols (IPsec, MACsec, PDCP, DOCSIS, TLS record), lib/ipsec, ipsec-secgw.
12. **Specialised classes (survey chapter)** — bbdev (5G LDPC/FFT), gpudev (GPU memory + comm list for inline
    GPU packet processing), mldev (model load/start, quantize), regexdev, rawdev.

Suggested chapter split for the course: (A) crypto fundamentals [2+3], (B) advanced crypto/perf/asym [4+5],
(C) compress + DMA [6+7], (D) eventdev core [8+9], (E) eventdev adapters [10], (F) security/IPsec [11],
(G) specialised accelerators survey [12]. A–E are fully runnable here; F partly; G mostly API + null/skeleton.

---------------------------------------------------------------------------------------------------

## 2. cryptodev in depth

### 2.1 Device model
- Creation: PCI probe or `--vdev=crypto_openssl0` / `rte_vdev_init()`. Common vdev args:
  `max_nb_queue_pairs`, `socket_id`. ID by name: `rte_cryptodev_get_dev_id("crypto_openssl0")`.
  Count: `rte_cryptodev_count()`, by driver: `rte_cryptodev_devices_get()`.
- `rte_cryptodev_info_get()` -> `driver_name`, `feature_flags` (`RTE_CRYPTODEV_FF_*`: SYMMETRIC_CRYPTO,
  ASYMMETRIC_CRYPTO, SYM_OPERATION_CHAINING, CPU_AVX2/AVX512/AESNI, IN_PLACE_SGL, OOP_*, SECURITY,
  SYM_CPU_CRYPTO, SYM_RAW_DP, SYM_SESSIONLESS, DIGEST_ENCRYPTED...), `capabilities[]` array terminated by
  `RTE_CRYPTO_OP_TYPE_UNDEFINED`, `max_nb_queue_pairs`, `sym.max_nb_sessions`.
  **[verified]** openssl0: driver=crypto_openssl, max_qp=8, ff=0x462a47.
- Capability query: `rte_cryptodev_sym_capability_get(dev, &idx)` then
  `rte_cryptodev_sym_capability_check_cipher/auth/aead(cap, key_len, iv_len, ...)`.
  Asym: `rte_cryptodev_asym_capability_get()` (note: openssl reports modlen 0..0 = "no limit").
- `struct rte_cryptodev_config { socket_id; nb_queue_pairs; ff_disable; }` (rte_cryptodev.h:850) —
  `ff_disable` can switch off SYM/ASYM/SECURITY to save resources.
- `struct rte_cryptodev_qp_conf { nb_descriptors; mp_session; priority; }` (rte_cryptodev.h:707) —
  `mp_session` is only for session-less ops. `priority` is new-ish (QP_PRIORITY_HIGHEST..LOWEST).
- Lifecycle: `rte_cryptodev_configure` -> `queue_pair_setup` -> `start` -> ... -> `stop` -> `close`.
  **Pitfall [observed]**: `rte_eal_cleanup()` closes devices; closing a running device logs
  "Device 0 must be stopped before closing" (seen in l2fwd-crypto). Always stop first.

### 2.2 Ops, pools, private area
- `rte_crypto_op_pool_create(name, type, nb, cache, priv_size, socket)` (rte_crypto.h:264). Each element =
  `struct rte_crypto_op` + `struct rte_crypto_sym_op` (or asym) + `priv_size` bytes. The IV is conventionally
  stored right after: `#define IV_OFFSET (sizeof(struct rte_crypto_op) + sizeof(struct rte_crypto_sym_op))`,
  accessed with `rte_crypto_op_ctod_offset(op, uint8_t *, IV_OFFSET)`. The xform's `iv.offset` is this
  offset — the PMD reads the IV *from the op*, per packet (the IV is mutable, the key is not).
- `op->status`: NOT_PROCESSED on alloc, SUCCESS / AUTH_FAILED / INVALID_SESSION / INVALID_ARGS / ERROR on dequeue.
- `op->sym->m_src`, optional `m_dst` (out-of-place), `cipher.data.{offset,length}`, `auth.data.{offset,length}`,
  `auth.digest.{data,phys_addr}`, `aead.{data,digest,aad}`.

### 2.3 Sessions (API changed in 22.11 — beware old blogs!)
- Pre-22.11: `rte_cryptodev_sym_session_create(mp)` + `rte_cryptodev_sym_session_init(dev, sess, xform, priv_mp)`
  with two mempools. **Since 22.11**: one call, one pool, opaque `void *`:
  ```c
  mp = rte_cryptodev_sym_session_pool_create("sess", nb, rte_cryptodev_sym_get_private_session_size(dev),
                                             cache, user_data_size, socket);
  void *sess = rte_cryptodev_sym_session_create(dev_id, &xform_chain, mp);
  rte_crypto_op_attach_sym_session(op, sess);
  rte_cryptodev_sym_session_free(dev_id, sess);
  ```
  A session is only valid for devices with the same *driver id* as `dev_id`.
- Session = immutable, precomputed per-flow state (expanded AES key schedule, HMAC ipad/opad). Op = mutable
  per-packet data (IV, offsets, mbuf). This split is the key design rationale (docs §"Sessions").
- `user_data_size` / `rte_cryptodev_sym_session_set_user_data()` — app metadata in the session.
  **Pitfall [verified]**: the SW event crypto adapter stores its response `rte_event` in session user data
  (`rte_cryptodev_session_event_mdata_set()` falls back to `set_user_data` when the PMD has no hook,
  rte_cryptodev.c:2718). If the session pool was created with `user_data_size=0`, `mdata_set` fails.
- Session-less: `op->sess_type = RTE_CRYPTO_OP_SESSIONLESS` + `rte_crypto_op_sym_xforms_alloc()`; PMD builds a
  temp session from `qp_conf.mp_session`. Slower; good for one-shot ops.

### 2.4 Transforms
`struct rte_crypto_sym_xform { next; type (CIPHER|AUTH|AEAD); union { cipher, auth, aead } }` (rte_crypto_sym.h).
- Chain order = processing order: CIPHER(encrypt)->AUTH(generate) = encrypt-then-MAC (IPsec ESP outbound);
  AUTH(verify)->CIPHER(decrypt) for inbound. Requires `FF_SYM_OPERATION_CHAINING`.
- AEAD (AES-GCM/CCM, ChaCha20-Poly1305) is a single xform with `aad_length`, `digest_length`, `iv`.
- Zero the whole xform struct before filling (ABI forward-compat; doc says so).
- **[verified]** AES-128-CBC + HMAC-SHA256 chain on crypto_openssl gives byte-identical output to
  `openssl enc -aes-128-cbc -nopad` + `openssl dgst -sha256 -hmac` (encrypt-then-MAC over ciphertext).

openssl PMD algorithms (drivers/crypto/openssl/rte_openssl_pmd_ops.c): ciphers AES-CBC/CTR/XTS, 3DES-CBC/CTR,
DES-CBC, DES-DOCSISBPI; auth MD5, SHA1/224/256/384/512 (+HMAC), SHA3-*, SHAKE128/256, AES-CMAC, AES-GMAC;
AEAD AES-GCM/CCM; asym MODEX, MODINV, RSA, DH, DSA, ECFPM, EdDSA, SM2, **ML-KEM, ML-DSA** (post-quantum).

### 2.5 Data path
- `rte_cryptodev_enqueue_burst(dev, qp, ops, n)` / `rte_cryptodev_dequeue_burst(...)` — inline functions in
  rte_cryptodev.h that call through `rte_crypto_fp_ops[dev_id]` (fast-path ops table, like ethdev's
  `rte_eth_fp_ops`) — no locks. One qp must not be enqueued from 2 lcores (or dequeued from 2 lcores), but
  enqueue on lcore A + dequeue on lcore B is allowed -> natural pipeline hand-off point (doc §"Logical Cores").
- SW PMDs (openssl, null) process *at enqueue time* and park results in a ring; dequeue just reads the ring.
  **[verified]** with openssl, dequeue succeeded on the first poll (polls=0). HW PMDs complete asynchronously.
- Enqueue/dequeue callbacks: `rte_cryptodev_add_enq_callback/add_deq_callback` (RCU-protected).
- Sync CPU crypto: `rte_cryptodev_sym_cpu_crypto_process(dev, sess, ofs, vec)` with `rte_crypto_sym_vec`
  (needs `FF_SYM_CPU_CRYPTO`; aesni_mb/aesni_gcm — not built here). Used by lib/ipsec CPU_CRYPTO action.
- Raw data-path API (`rte_cryptodev_raw_enqueue_burst`, `rte_crypto_raw_dp_ctx`, `FF_SYM_RAW_DP`) — no mbuf/op,
  used by vhost-crypto / external libs.

### 2.6 crypto_scheduler (drivers/crypto/scheduler, doc/guides/cryptodevs/scheduler.rst)
A *virtual* cryptodev that fans ops out to worker cryptodevs. Modes (`CDEV_SCHED_MODE_*`): ROUNDROBIN,
PKT_SIZE_DISTR (threshold: small to secondary SW worker, big to primary HW), FAILOVER (primary/secondary),
MULTICORE (worker lcores + rings), USERDEFINED. `ordering=enable` uses reorder lib + mbuf fields.
vdev syntax: `--vdev crypto_null0 --vdev crypto_null1 --vdev "crypto_scheduler0,worker=crypto_null0,worker=crypto_null1,mode=round-robin"`.
Runtime API in `rte_cryptodev_scheduler.h` (`rte_cryptodev_scheduler_worker_attach`, `_mode_set`, ...) — device
must be stopped to reconfigure. Sessions created on the scheduler create sessions on every worker
(scheduler_pmd_ops.c; also forwards rte_security sessions).

### 2.7 Verified commands
```
# throughput on openssl (1.45 Mops @64B, 0.6 Mops @1024B = 4.96 Gbps, AES-CBC+SHA1-HMAC)
dpdk-test-crypto-perf -l 0-1 --no-huge -m 256 --no-pci --file-prefix=ch08p --vdev crypto_openssl0 -- \
  --ptest throughput --devtype crypto_openssl --optype cipher-then-auth --cipher-algo aes-cbc \
  --cipher-op encrypt --cipher-key-sz 16 --cipher-iv-sz 16 --auth-algo sha1-hmac --auth-op generate \
  --auth-key-sz 64 --digest-sz 12 --total-ops 100000 --burst-sz 32 --buffer-sz 64,1024 --silent
# scheduler over 2 null devs (null cipher needs --cipher-key-sz 0 --cipher-iv-sz 0 or "capabilities" error)
dpdk-test-crypto-perf -l 0-2 ... --vdev crypto_null0 --vdev crypto_null1 \
  --vdev "crypto_scheduler0,worker=crypto_null0,worker=crypto_null1,mode=round-robin" -- \
  --ptest throughput --devtype crypto_scheduler --optype cipher-only --cipher-algo null \
  --cipher-key-sz 0 --cipher-iv-sz 0 --total-ops 200000 --burst-sz 32 --buffer-sz 64 --silent
# l2fwd-crypto: needs >= 1 cryptodev PER PORT, and real IPv4 packets (net_null garbage is never enqueued)
python3 mkpcap.py in.pcap 64 64
dpdk-l2fwd-crypto -l 0 --no-huge -m 256 --no-pci --file-prefix=ch08l \
  --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=out.pcap --vdev=crypto_openssl0 -- -p 0x1 --chain CIPHER_HASH \
  --cipher_algo aes-cbc --cipher_op ENCRYPT --cipher_key 00:01:...:0f --auth_algo sha1-hmac \
  --auth_op GENERATE --auth_key_random_size 64 -T 1 --no-mac-updating     # 64 rx / 64 enq / 64 deq / 64 tx
```
Pitfalls found: test-crypto-perf `verify` with the shipped `data/aes_gcm_128.data` needs `--buffer-sz >= 512`;
l2fwd-crypto with 2 ports and 1 cryptodev exits "Number of capable crypto devices (1) has to be more or equal
to number of ports (2)"; with net_null ports it receives packets but enqueues 0 (not IPv4) and leaks the pool.

### 2.8 Asymmetric
- Pool: `rte_cryptodev_asym_session_pool_create(name, nb, cache, user_data_size, socket)`;
  `rte_cryptodev_asym_session_create(dev, &xform, mp, &sess)` (returns int, session via out-param — different
  from sym!). Op: `rte_crypto_op_attach_asym_session`, `op->asym->modex.base/result`, `rsa.*`, `ecdsa.*`...
- **Pitfall [verified]**: `rte_crypto_uint`/`rte_crypto_param` is `{ uint8_t *data; rte_iova_t iova; size_t length; }`.
  Positional init `{buf, len}` silently puts the length in `iova` -> result length 1 / garbage. Use designated
  initialisers. All big numbers are big-endian byte strings; the PMD writes `result.length`.
- **[verified]** modexp 0x123456789ABCDEF0^65537 mod 0xC351...ABCD = 0x614b49e77c2112d0736ee11cdeb818a7 (== python pow).

---------------------------------------------------------------------------------------------------

## 3. rte_security (lib/security, doc prog_guide/rte_security.rst, howto/security)

- Adds *protocol* offload on top of cryptodev or ethdev. Context: `rte_cryptodev_get_sec_ctx(dev)` or
  `rte_eth_dev_get_sec_ctx(port)` -> `void *ctx`.
- Action types (`enum rte_security_session_action_type`, rte_security.h:732):
  - `NONE` — plain cryptodev, app (or lib/ipsec) does protocol processing ("lookaside none").
  - `INLINE_CRYPTO` — NIC encrypts/decrypts on rx/tx, app still builds ESP headers; flow rule
    `RTE_FLOW_ACTION_TYPE_SECURITY` on ingress; `rte_security_set_pkt_metadata()` on egress; mbuf ol_flags
    `RTE_MBUF_F_RX_SEC_OFFLOAD(_FAILED)`, `RTE_MBUF_F_TX_SEC_OFFLOAD`.
  - `INLINE_PROTOCOL` — NIC does crypto + headers (encap/decap, seq numbers).
  - `LOOKASIDE_PROTOCOL` — crypto accelerator does full ESP/PDCP/TLS processing on a crypto_op
    (`rte_security_attach_session(op, sess)`).
  - `CPU_CRYPTO` — synchronous CPU crypto via `rte_cryptodev_sym_cpu_crypto_process`.
- Protocols: IPSEC, MACSEC (`rte_security_macsec_sc_create/sa_create`), PDCP (lib/pdcp), DOCSIS, TLS_RECORD.
- Session: `rte_security_session_create(ctx, &conf, mp)` with `conf.action_type`, `conf.protocol`,
  `conf.ipsec` (spi, salt, direction, proto ESP/AH, mode TUNNEL/TRANSPORT, tunnel addrs, options: esn, udp_encap,
  iv_gen_disable, ...), `conf.crypto_xform` (reuses cryptodev xforms!). `rte_security_capabilities_get(ctx)`.
  Newer: `rte_security_inb_pkt_rx_inject`, `rte_security_session_stats_get`, OOP dynfield.
- lib/ipsec (`rte_ipsec_sa_init`, `rte_ipsec_session_prepare`, `rte_ipsec_pkt_crypto_prepare/process`, SAD)
  sits above and supports all action types incl. NONE (lib/ipsec/sa.c:823).
- **No security-capable driver is built on this VM** (needs ixgbe/mlx5/cnxk/dpaa2 HW), so rte_security is a
  concept/diagram chapter; runnable part is lookaside-none IPsec via lib/ipsec or ipsec-secgw.
- ipsec-secgw attempt [partially verified]: config `08-examples/ipsec_secgw_ep0.cfg` (sp/sa/rt lines).
  Findings: (1) needs `--no-huge -m 768` (LPM alloc fails at 256 MB); (2) port conf hard-codes
  `RTE_ETH_RX_OFFLOAD_CHECKSUM` (ipsec-secgw.c:240) so net_pcap ports are rejected ("required RX offloads: 0xe")
  — use net_tap (`--vdev=net_tap0,iface=ch08t0`); (3) it needs an inbound SA when an unprotected port is set;
  (4) app starts, maps cdev qps ("Outbound cdev mapping: lcore 0 using cdev 0 qp 1"), receives the 20 injected
  packets but drops all 20 — root cause not found in the time box (with and without `-l`, `--single-sa 0`).
  Course implementers should either debug further (enable RTE_LOG_DP debug at build) or prefer a small custom
  lib/ipsec example. Do not promise ipsec-secgw traffic without re-testing.

---------------------------------------------------------------------------------------------------

## 4. compressdev (lib/compressdev, doc prog_guide/compressdev.rst, compressdevs/zlib.rst)

- Config: `struct rte_compressdev_config { socket_id; nb_queue_pairs; max_nb_priv_xforms; max_nb_streams; }`;
  `rte_compressdev_queue_pair_setup(dev, qp, max_inflight_ops, socket)` (note: int, not a struct).
- Capabilities: `rte_compressdev_capability_get(dev, RTE_COMP_ALGO_DEFLATE)` -> `comp_feature_flags`
  (`RTE_COMP_FF_*`: STATEFUL_*, OOP_SGL_*, HUFFMAN_FIXED/DYNAMIC, ADLER32/CRC32 checksums, SHA2 hash,
  SHAREABLE_PRIV_XFORM), `window_size.{min,max}`. **[verified]** zlib: window 8..15, ff=0x6800.
  Algorithms: NULL, DEFLATE, LZS, LZ4.
- xform: `struct rte_comp_xform { type COMPRESS|DECOMPRESS; compress{algo, deflate.huffman, level, window_size,
  chksum, hash_algo} }`. **Stateless**: `rte_compressdev_private_xform_create()` -> `op->private_xform`, each
  op is independent (whole message, `flush_flag = RTE_COMP_FLUSH_FINAL`). **Stateful**:
  `rte_compressdev_stream_create()` -> `op->stream`, chunks with FLUSH_NONE/SYNC/FULL, the device keeps
  history (sliding window) between ops; a stream must be processed by one qp, one op in flight.
- Op: `rte_comp_op_pool_create(name, nb, cache, user_size, socket)`, `op->m_src/m_dst` (dst must be pre-sized
  mbuf(s) — the PMD writes `produced`), `src.offset/length`, `dst.offset`, results `consumed`, `produced`,
  `status` (SUCCESS, OUT_OF_SPACE_TERMINATED for stateless => retry with bigger buffer,
  OUT_OF_SPACE_RECOVERABLE for stateful => continue), `input_chksum/output_chksum`.
- **[verified]** 4000 B repetitive text -> 56 B (1.4 %), decompress round-trip matches (comp_zlib_roundtrip.c).
- Related but different: lib/ptr_compress (pointer compression for mbuf rings) — not compressdev.
- Perf tool `dpdk-test-compress-perf` is not built here.

---------------------------------------------------------------------------------------------------

## 5. dmadev (lib/dmadev, doc prog_guide/dmadev.rst, dmadevs/*)

- Model: one dmadev = one HW DMA channel/queue; it has `nb_vchans` *virtual channels*, each a transfer context
  with direction MEM_TO_MEM/MEM_TO_DEV/DEV_TO_MEM/DEV_TO_DEV and `nb_desc`.
  `rte_dma_configure(dev, &(struct rte_dma_conf){.nb_vchans, .priority, .flags})`,
  `rte_dma_vchan_setup(dev, vchan, &vchan_conf)`, `rte_dma_start`.
- Capabilities `RTE_DMA_CAPA_*` (rte_dmadev.h:228+): MEM_TO_MEM..DEV_TO_DEV, SVA (can use plain VA),
  SILENT (no completion polling), HANDLES_ERRORS, M2D_AUTO_FREE, PRI_POLICY_SP, INTER_PROCESS/OS_DOMAIN,
  OPS_COPY / COPY_SG / FILL / ENQ_DEQ. **[verified]** skeleton: capa=0x700000011 (mem2mem, sva, copy, copy_sg,
  fill), max_vchans=1, desc 32..8192.
- Data path (ring-index model): `rte_dma_copy(dev, vchan, src_iova, dst_iova, len, flags)` returns a
  monotonically increasing `ring_idx` (uint16 wrap) — the app keeps its own metadata ring indexed by it.
  Nothing moves until the **doorbell**: `rte_dma_submit()` or `RTE_DMA_OP_FLAG_SUBMIT` on the last enqueue.
  `RTE_DMA_OP_FLAG_FENCE` orders an op after all previous ones; `FLAG_LLC` hints cache allocation.
  Completion: `rte_dma_completed(dev, vchan, max, &last_idx, &has_error)` (stops at first error) or
  `rte_dma_completed_status()` (per-op status codes). `rte_dma_burst_capacity()` = free slots.
  **[verified]** nb_desc 64 -> capacity 63 (one slot kept empty in the ring); 16 copies -> ring_idx 0..15.
- New enq/deq op mode (`RTE_DMA_CAPA_OPS_ENQ_DEQ`, `rte_dma_conf.enable_enq_deq`, `rte_dma_enqueue_ops/
  dequeue_ops` with `struct rte_dma_op`) — used by the event DMA adapter.
- Addresses are IOVAs: `rte_malloc_virt2iova()`, `rte_mbuf_data_iova()`. With `--no-huge` IOVA=VA.
- dma_skeleton (drivers/dma/skeleton): a control thread pinned to `lcore=N` that memcpy()s descriptors through
  empty/pending/running/completed rings (visible in `rte_dma_dump()`). Great for visualising the 4 rings.
- **[verified]** `dpdk-dma -l 0-2 --no-huge -m 512 --vdev=dma_skeleton0,lcore=2 --vdev=net_pcap0,rx_pcap=big.pcap,
  tx_pcap=out.pcap,infinite_rx=1 -- -p 0x1 -q 1 -c hw --no-mac-updating -i 1`: rx 11.3 Mpps, DMA ~2 Mops/s,
  rest "dropped on copy" -> perfect demo that a slow "accelerator" becomes the bottleneck. (-m 256 fails: mbuf pool.)
- Real HW: Intel IOAT/DSA (idxd), HiSilicon, Marvell, NXP; vhost async data path uses dmadev.

---------------------------------------------------------------------------------------------------

## 6. eventdev (lib/eventdev, doc prog_guide/eventdev/*.rst, eventdevs/sw.rst)

### 6.1 Concepts
- **Event** = 16 bytes (rte_eventdev.h `struct rte_event`): WORD0 bitfields `flow_id:20, sub_event_type:8,
  event_type:4 (ETHDEV, CRYPTODEV, TIMER, CPU, ETH_RX_ADAPTER, VECTOR...), op:2 (NEW/FORWARD/RELEASE),
  rsvd:4, sched_type:2, queue_id:8, priority:8, impl_opaque:8`; WORD1 = `u64 | event_ptr | mbuf | vec`.
- **Queue** (= pipeline stage) with schedule type: `RTE_SCHED_TYPE_ATOMIC` (one flow is processed by at most one
  port at a time -> lock-free per-flow state), `ORDERED` (parallel processing, original order restored on
  enqueue to next stage via reorder buffer), `PARALLEL` (no guarantees). `RTE_EVENT_QUEUE_CFG_ALL_TYPES`
  if `RTE_EVENT_DEV_CAP_QUEUE_ALL_TYPES`; `RTE_EVENT_QUEUE_CFG_SINGLE_LINK` for a queue linked to exactly one
  port (e.g. Tx stage).
- **Port** = per-lcore enqueue/dequeue endpoint (like an ethdev queue). `rte_event_port_link(dev, port,
  queues, prios, n)` decides which queues a port receives from. Ports have `new_event_threshold`,
  `dequeue_depth`, `enqueue_depth`, flags (`RTE_EVENT_PORT_CFG_DISABLE_IMPL_REL`, `SINGLE_LINK`, `HINT_*`).
- **op**: NEW (inject, consumes a credit, subject to `new_event_threshold`), FORWARD (move an event you
  dequeued to the next stage — keeps credit, releases atomic/ordered context), RELEASE (drop the context
  without forwarding). Implicit release: next dequeue releases previous events unless disabled.
- Device config `struct rte_event_dev_config`: `nb_event_queues`, `nb_event_ports`, `nb_events_limit`
  (inflight credits), `nb_event_queue_flows`, `nb_event_port_dequeue/enqueue_depth`, `dequeue_timeout_ns`.
- Caps `RTE_EVENT_DEV_CAP_*`: QUEUE_QOS, EVENT_QOS, DISTRIBUTED_SCHED (HW has no central scheduler -> app
  must call `rte_event_maintain`), QUEUE_ALL_TYPES, BURST_MODE, IMPLICIT_RELEASE_DISABLE, RUNTIME_PORT_LINK,
  MULTIPLE_QUEUE_PORT, CARRY_FLOW_ID, MAINTENANCE_FREE, PROFILE_LINK (link profiles switchable at runtime:
  `rte_event_port_profile_switch`), ATOMIC/ORDERED/PARALLEL, INDEPENDENT_ENQ, EVENT_PRESCHEDULE(_ADAPTIVE),
  PER_PORT_PRESCHEDULE, PRESCHEDULE_EXPLICIT. **[verified]** event_sw: max_queues=255, max_ports=64,
  max_events=4096, caps=0xe7f3.
- Fast path: `rte_event_enqueue_burst / enqueue_new_burst / enqueue_forward_burst`, `rte_event_dequeue_burst(dev,
  port, ev, n, timeout_ticks)` via `rte_event_fp_ops`.

### 6.2 event_sw internals (drivers/event/sw/sw_evdev_scheduler.c) — great visualisation material
- event_sw is a **centralised software scheduler implemented as a service** (`rte_event_dev_service_id_get`).
  Without a service core nothing moves; `rte_event_dev_start` warns "No Service core enabled".
  Options: `-s 0x8` (service coremask) + `rte_service_map_lcore_set`, or run it inline with
  `rte_service_run_iter_on_app_lcore(sid, 0)` + `rte_service_set_runstate_mapped_check(sid, 0)` [both verified].
- Each port has an rx ring (worker -> scheduler) and a cq ring (scheduler -> worker, size = dequeue_depth);
  each queue (QID) has IQs (internal queues per priority). One scheduler iteration: pull from port rx rings
  into QID IQs (`sw_schedule_pull_port_*`), then `sw_schedule_qid_to_cq` moves events from IQs into port cq
  rings by type, then `sw_schedule_reorder` for ordered queues.
- Atomic: per-QID flow table `fids[hash(flow_id)]` with `.cq` (owner port) and `.pcount` (inflight count). A flow
  with `cq < 0` is assigned to the least-loaded mapped cq and "pinned"; while `pcount > 0` all its events go
  to that port; when the port releases the last one (pcount -> 0) the flow may migrate. Events for a port
  whose cq is full or whose history list is full are "blocked" and put back.
- Ordered: a reorder buffer (ROB) entry is reserved per event at schedule time; on FORWARD the event is
  written into its ROB slot and `sw_schedule_reorder` releases slots in order.
- Credits: `nb_events_limit` inflight; NEW events fail when `new_event_threshold` reached ("Max New" in dump,
  "inflight 4096, credits: 0" when saturated). `rte_event_dev_dump()` prints per-port burst distributions,
  ring usage, per-queue per-port packet counts and flows — feed this into an animation.

### 6.3 Verified demo: the three schedule types side by side (event_sw_atomic.c)
Producer (main lcore, also drives the scheduler) -> queue0 [type under test] -> 2 workers (rte_delay_us random
0–3 µs, detect if two workers are inside the same flow at once) -> FORWARD to queue1 (atomic) -> sink port
(checks per-flow sequence order). 8 flows × 2500 events:

| mode | flow→worker matrix | same-flow concurrency | sink out-of-order | time |
|---|---|---|---|---|
| atomic | each flow 100 % on one worker (f0→w0, f1→w1, …) | 0 | 0 | 73 ms |
| ordered | flows spread ~45/55 over both workers | ~2080 | **0** | 59 ms |
| parallel | spread ~20/80 | ~970 | **~1090** | 27 ms |

This is THE eventdev teaching demo: atomic = mutual exclusion per flow, ordered = parallel but order restored,
parallel = fastest with no guarantees. (Note: in a 1-stage variant without the sink, atomic flows migrated
between workers ~30/70 because a flow becomes free whenever its pcount drops to 0.)

### 6.4 Prebuilt tools [verified]
```
dpdk-test-eventdev -l 0-3 -s 0x8 --no-huge -m 256 --no-pci --file-prefix=ch08t --vdev=event_sw0 -- \
   --test=order_queue --plcores 1 --wlcores 2 --nb_flows 64 --nb_pkts 100000        # Result: Success
dpdk-test-eventdev ... -- --test=perf_queue --plcores 1 --wlcores 2 --stlist=a,o --nb_pkts 300000
dpdk-eventdev_pipeline -l 0-3 --no-huge -m 256 --no-pci --file-prefix=ch08ep --vdev=event_sw0 \
   --vdev=net_pcap0,rx_pcap=big.pcap,tx_pcap=o.pcap,infinite_rx=1 -- -r2 -t4 -e8 -w 2 -s3 -n0 -c32 -W100 -D
   # 3 atomic stages; prints which lcore is Rx / Tx / scheduler / worker + full sw dump
dpdk-l2fwd-event -l 0-3 -s 0x8 ... --vdev=event_sw0 --vdev=net_pcap0,... --vdev=net_pcap1,... -- \
   -p 0x3 --mode=eventdev --eventq-sched=atomic --no-mac-updating     # prints Rx/Tx adapter stats
```
(l2fwd-event has no `-P` option — passing it panics.) Test names: order_queue, order_atq, perf_queue,
perf_atq, pipeline_queue, pipeline_atq; producers synthetic / `--prod_type_ethdev` / `--prod_type_timerdev`
/ `--prod_type_cryptodev` / `--prod_type_dmadev`.

### 6.5 Adapters (doc prog_guide/eventdev/*)
Every adapter follows: `caps_get(evdev, other_dev, &caps)` -> if `CAP_INTERNAL_PORT` the HW moves events itself;
otherwise the adapter is a **SW service** that needs a service core and an extra event port (the default
`create()` uses a conf callback that **stops and reconfigures the eventdev adding one port** — so don't
pre-reserve ports; **[verified]** pre-reserving gives "Port 1 not configured" at start).
- **Eth Rx adapter** (`rte_event_eth_rx_adapter_create/queue_add/start`, `queue_conf.ev` template,
  `servicing_weight`, vector mode `RTE_EVENT_ETH_RX_ADAPTER_QUEUE_EVENT_VECTOR`, `cb_register` filter,
  `instance_get`, per-queue stats). Polls ethdev rx queues (WRR over queues) and injects NEW events with
  `flow_id` = RSS hash if not overridden.
- **Eth Tx adapter** (`create`, `queue_add`, `rte_event_eth_tx_adapter_enqueue` when `CAP_INTERNAL_PORT`;
  else workers enqueue to the adapter's single-link queue; `txq_set(mbuf, q)` stores tx queue in mbuf).
- **Timer adapter** (`rte_event_timer_adapter_create(&conf{timer_tick_ns, max_tmo_ns, nb_timers, clk_src,
  flags ADJUST_RES|SP_PUT|PERIODIC})`, `rte_event_timer_arm_burst`, `arm_tmo_tick_burst`, `cancel_burst`,
  `remaining_ticks_get`; timer state NOT_ARMED/ARMED/CANCELED/ERROR_TOOEARLY/TOOLATE). The SW impl uses
  lib/timer per service lcore. **[verified]** event_timer_demo.c: tick 10 ms; 6 timers armed at 300..50 ms,
  one cancelled (state=2), 5 expiry events arrive at 51.9/101.9/151.9/201.9/251.9 ms; caps=0x2 (PERIODIC only,
  SW service). Pitfall: `printf("%d %d", cancel(), t->state)` — argument evaluation order is unspecified; read
  state after the call.
- **Crypto adapter**: modes `RTE_EVENT_CRYPTO_ADAPTER_OP_NEW` (app enqueues to cryptodev itself; adapter
  dequeues completions and injects NEW events using session `response_info`) vs `OP_FORWARD` (app *enqueues
  events* carrying crypto ops — via `rte_event_crypto_adapter_enqueue()` if `CAP_INTERNAL_PORT_OP_FWD`, else to
  the adapter's port; `request_info` gives cdev/qp). Metadata through
  `rte_cryptodev_session_event_mdata_set()` / `union rte_event_crypto_metadata`. Caps INTERNAL_PORT_OP_NEW/
  OP_FWD, INTERNAL_PORT_QP_EV_BIND, SESSION_PRIVATE_DATA, EVENT_VECTOR. **[verified]**
  event_crypto_adapter_new.c: caps=0x8 (SESSION_PRIVATE_DATA only -> SW service); 32 AES-CTR ops ->
  32 events, `event_type=CRYPTODEV`, flow 7 from metadata, stats deq_from_cdev=32 ev_enq=32.
- **DMA adapter** (`rte_event_dma_adapter_create/vchan_add/enqueue`, modes OP_NEW/OP_FORWARD; uses
  `rte_dma_op`) — needs a dmadev with ENQ_DEQ capability; skeleton does not advertise `OPS_ENQ_DEQ`
  (capa 0x7_00000011 lacks bit 35), so likely not runnable here (not tested).
- **Vector adapter** (`rte_event_vector_adapter_create/enqueue`, 25.x+) — aggregates objects into
  `rte_event_vector` by size/timeout with fallback to single events.
- **Dispatcher** (lib/dispatcher, `rte_dispatcher_create/register(match_cb, process_cb)/bind_port_to_lcore`) —
  a service that dequeues and routes events to registered handlers by predicate ("event-driven callbacks").
- **Service-ordering pitfalls [verified]**: start devices/adapters *before* `rte_service_lcore_start()`,
  otherwise the adapter service polls unconfigured devices ("maintenance requested for unconfigured event
  device" ×1000, "crypto dequeue burst requested for unconfigured device"); at shutdown stop the service
  lcore *first*, then adapters (`queue_pair_del` before `free`, else "Queue pairs not deleted"), then devices.
- **Default-conf pitfall [verified]**: `rte_event_queue_default_conf_get()` returns nb_atomic_flows=4096 and
  `port_default_conf_get()` dequeue_depth=16; if your dev config used smaller `nb_event_queue_flows` /
  depths, setup fails ("Invalid nb_atomic_flows=4096 max_flows=64"). Derive dev config from `info` maxima.

HW eventdevs for context: Intel DLB2 (dlb2), Marvell cnxk SSO, NXP dpaa/dpaa2, plus SW event_sw, event_dsw
(distributed SW), event_opdl (ordered pipeline), event_skeleton.

---------------------------------------------------------------------------------------------------

## 7. bbdev (lib/bbdev, doc prog_guide/bbdev.rst 1425 lines, bbdevs/*)

- Wireless baseband: 4G Turbo enc/dec, 5G LDPC enc/dec (`RTE_BBDEV_OP_LDPC_ENC/DEC`), FFT, MLD-TS.
  HW: Intel ACC100/ACC200 (VRB1/VRB2), FPGA 5GNR/LTE, Marvell, NXP la12xx; SW: turbo_sw (needs Intel FlexRAN
  SDK — not built), **null** (loopback ring; only OP_NONE).
- API: `rte_bbdev_setup_queues(dev, nb, socket)`, `rte_bbdev_queue_configure(dev, q, &{socket, queue_size,
  priority, deferred_start, op_type})`, `rte_bbdev_start`, op pools `rte_bbdev_op_pool_create(name, type, n,
  cache, socket)`, `rte_bbdev_enc_op_alloc_bulk`, `rte_bbdev_enqueue_ldpc_enc_ops/dequeue_ldpc_enc_ops`,
  `rte_bbdev_enqueue_fft_ops`, `rte_bbdev_queue_ops_dump`, stats, interrupts (`rte_bbdev_queue_intr_enable`).
  Op structs carry CB/TB mode, code block params, rate matching (e0, e1, k0, ncb, rv_index), HARQ buffers.
- **Pitfall [verified]**: `rte_bbdev_enc_op_alloc_bulk` rejects pools whose type is not TURBO_ENC/LDPC_ENC
  (rte_bbdev_op.h:1084) — a NONE-type pool fails with -EINVAL even for the null driver.
- **[verified]** bbdev_null_loopback.c: 16 enc ops enqueued and dequeued in order, stats 16/16.
  `dpdk-bbdev_app` with baseband_null exits "doesn't have required encoder capabilities" (needs real ops).
- Visual idea: 5G LDPC pipeline (CRC attach -> LDPC encode -> rate match -> modulation) with what is offloaded.

## 8. gpudev (lib/gpudev, doc prog_guide/gpudev.rst)
- `rte_gpu_count_avail`, `rte_gpu_info_get`, `rte_gpu_mem_alloc/free` (device memory), `rte_gpu_mem_register`
  (make CPU memory GPU-visible), `rte_gpu_mem_cpu_map` (GDRCopy-style CPU view of GPU memory), `rte_gpu_wmb`,
  child devices (`rte_gpu_add_child`), **communication flag** (`rte_gpu_comm_create_flag/set_flag`) and
  **communication list** (`rte_gpu_comm_create_list`, `rte_gpu_comm_populate_list_pkts`, status
  FREE/READY/DONE) — CPU receives packets into GPU memory (mempool with external GPU buffers via
  `rte_pktmbuf_pool_create_extbuf`) and hands bursts to a persistent CUDA kernel. Only driver: gpu/cuda (not
  built). Teach conceptually (NVIDIA Aerial / inline GPU packet processing, GPUDirect RDMA).

## 9. mldev (lib/mldev, doc prog_guide/mldev.rst; app/test-mldev)
- `rte_ml_dev_configure`, `rte_ml_dev_queue_pair_setup`, `rte_ml_model_load(dev, &params{addr,size}, &model_id)`,
  `rte_ml_model_start`, `rte_ml_model_info_get` (input/output tensor info), `rte_ml_op_pool_create`,
  `rte_ml_enqueue_burst/dequeue_burst` with `struct rte_ml_op {model_id, nb_batches, input[], output[]}`,
  quantization helpers `rte_ml_io_quantize/dequantize`, `rte_ml_io_float32_to_int8/float16/bfloat16...`.
  Drivers: ml/cnxk (Marvell Octeon ML accelerator, also TVM models). No SW driver built here -> the
  `rte_ml_io_*` conversion helpers are pure CPU and *can* be demonstrated without a device.

## 10. regexdev (lib/regexdev)
- Rule DB: `rte_regexdev_rule_db_update/compile_activate/import/export`; ops `struct rte_regex_ops` (mbuf,
  group_id, nb_matches, matches[] {rule_id, start_offset, len}); `rte_regexdev_enqueue/dequeue_burst`.
  Drivers: cn9k (mlx5 regex was removed). API-only; good for DPI/IDS context.

## 11. rawdev (lib/rawdev)
- Generic escape hatch for devices with no class: `rte_rawdev_configure(dev, &info, size)` with opaque
  `dev_private`, `queue_setup`, `enqueue_buffers/dequeue_buffers` (opaque `rte_rawdev_buf`), firmware
  load/version, attributes get/set, xstats, selftest. Drivers: skeleton, ntb, cnxk_gpio, cnxk_bphy, dpaa2_cmdif,
  ifpga (FPGA). Historical note: ioat/dpaa2_qdma started as rawdev and moved to dmadev in 21.11 — a nice story
  of how a class gets "promoted".
- **[verified]** `--vdev=rawdev_skeleton,selftest=1` (arg is `selftest`, not `self_test`) runs 12/12 tests at probe.

---------------------------------------------------------------------------------------------------

## 12. How they relate (concept map for a diagram)

```
                 +-------------------- eventdev (scheduler) ----------------------+
   ethdev --Rx adapter-->  [Q0 atomic] -> workers -> [Q1 ordered] -> workers -> --Tx adapter--> ethdev
                               ^   |                        |   ^
               timer adapter --+   +--crypto adapter (FWD)-->cryptodev --(NEW)--+
               dma adapter <---> dmadev                       |
                                                             rte_security (protocol on top of
                                                             cryptodev or ethdev inline)
   compressdev / bbdev / mldev / regexdev : same enqueue/dequeue lookaside pattern, (no adapters yet
   except via app code); rawdev = anything else; gpudev = memory+signalling, not ops.
   All SW pieces (event_sw, adapters, crypto_scheduler multicore, dma skeleton thread) run as
   EAL *services* or control threads on dedicated lcores.
```
History/timeline (for an intro slide): cryptodev 16.04 (Intel, from QAT/AESNI work); security lib 17.11
(inline IPsec w/ Mellanox+Intel+NXP); eventdev 17.05 (Cavium + Intel, OpenDataPlane-inspired scheduling);
compressdev 18.05; bbdev 18.02 (Intel FlexRAN); rawdev 18.02 (NXP); regexdev 20.08 (Mellanox/Marvell);
dmadev 21.11 (HiSilicon-led, replacing ioat rawdev); gpudev 21.11 (NVIDIA); mldev 23.03 (Marvell);
crypto session API rework 22.11; dispatcher 23.11; vector adapter ~25.07; ML-KEM/ML-DSA PQC in openssl PMD 25.x/26.x.
(Verify exact versions against doc/guides/rel_notes before printing them on slides.)

---------------------------------------------------------------------------------------------------

## 13. Visualisation / animation ideas

1. **Order-ticket animation** for async lookaside: ops (tickets) slide from lcore into a qp ring, the device
   "kitchen" processes them, tickets come back possibly reordered (HW) — contrast with SW PMD that finishes at
   enqueue. Show `enqueue_burst` returning fewer than n when ring full (back-pressure).
2. **Session vs op split**: a session card (key schedule, ipad/opad, algo) shared by many op cards
   (IV, offsets, mbuf ptr); hover highlights which bytes of the mbuf `cipher.data.offset/length` and
   `auth.data` cover, and where the digest lands. Use the real bytes from crypto_aes_cbc_sha.c.
3. **Xform chain builder**: drag CIPHER/AUTH blocks; animation shows encrypt-then-MAC vs MAC-then-encrypt data flow
   and the IPsec ESP layout (SPI|seq|IV|payload|pad|ICV).
4. **crypto_scheduler modes**: one stream of ops split round-robin / by size threshold / failover when primary
   ring is full.
5. **Compression stream**: sliding 32 KB window, Huffman blocks, `consumed`/`produced` counters; stateless vs
   stateful (history carried between chunks); OUT_OF_SPACE recoverable vs terminated.
6. **DMA rings**: the skeleton's four rings (empty → pending → running → completed) with `ring_idx` counters,
   doorbell (submit) button, fence barrier, `last_idx`/`has_error` on completion. Interactive: enqueue without
   submit -> nothing moves.
7. **Eventdev scheduler (the star)**: producer, 2-4 worker ports, queues; coloured flows. Toggle
   ATOMIC/ORDERED/PARALLEL and replay the *measured* table from §6.3 (flow→worker matrix, collision counter,
   reorder counter at sink). Show the atomic flow table (fid→cq, pcount) and the ROB for ordered.
8. **Credits**: bucket of `nb_events_limit` tokens; NEW consumes, RELEASE/Tx returns; show deadlock-ish stall
   when producers outrun workers (`new_event_threshold`).
9. **Adapters as "bridges"**: eth Rx adapter polling rx queues by weight, timer wheel ticking (10 ms ticks,
   timers firing at 50/100/...ms as in the verified run), crypto adapter OP_NEW vs OP_FORWARD swim-lane diagram.
10. **Service cores**: timeline of lcores showing which run workers vs services (event_sw scheduler, Rx adapter,
    timer adapter, crypto adapter); what happens with no service core mapped (nothing moves).
11. **rte_security action types**: 5-lane diagram (who does crypto, who does protocol headers: app/lib vs NIC vs
    lookaside accelerator) — reuse ASCII figures from rte_security.rst.
12. **bbdev 5G chain** and **gpudev comm list** state machine (FREE→READY→DONE) as small SVG animations.
13. **Bottleneck gauge**: dpdk-dma run (11 Mpps rx vs 2 Mops DMA) and test-crypto-perf numbers as bar charts.

---------------------------------------------------------------------------------------------------

## 14. Common pitfalls (collected; many verified here)

- Old session API (`sym_session_init`, two mempools) in blogs/StackOverflow — removed in 22.11.
- Forgetting the IV offset convention / not reserving `priv_size` in the op pool -> IV overwrites memory.
- Digest buffer not inside/after mbuf data, or `digest.phys_addr` wrong for HW PMDs (SW ignores it, HW crashes).
- CBC needs length multiple of 16; null cipher needs key/iv size 0 in test-crypto-perf.
- Sharing one qp between lcores for enqueue (needs external locking) — use one qp per lcore.
- Assuming enqueue == done; not handling partial enqueue (`n < nb_ops`) / not draining dequeue at shutdown.
- `rte_crypto_uint` positional initialiser (data, **iova**, length) bug — asym results silently wrong.
- Session pool without `user_data_size` when using event crypto adapter (SW) -> mdata_set fails.
- Asym session create returns int with out-param; sym returns pointer — easy to mix up.
- compressdev dst mbuf must have room (append/pre-size); stateless OUT_OF_SPACE_TERMINATED => resubmit bigger.
- dmadev: forgetting `submit`; uint16 ring_idx wrap in app metadata ring; passing VA where IOVA is needed
  (fine with --no-huge/IOVA=VA, wrong with PA mode).
- eventdev: no service core for event_sw/adapters; default queue/port confs exceeding device config;
  pre-reserving ports that the adapter's default callback adds itself; forgetting RELEASE/FORWARD with
  implicit release disabled (atomic flows stay locked forever); mixing NEW for forwarded events (credit leak);
  `flow_id` only 20 bits; app must call `rte_event_maintain()` on DISTRIBUTED_SCHED devices if idle.
- Service/teardown ordering (start devices before service lcore; stop service lcore first).
- Example-app specifics: l2fwd-crypto needs one cryptodev per port + IPv4 traffic; ipsec-secgw needs RX checksum
  offload (net_tap ok, net_pcap not), ≥768 MB with --no-huge, inbound SA when -u used; dpdk-dma needs -m ≥512;
  net_pcap rx stops at EOF unless `infinite_rx=1`.
- Shared machine: always `--file-prefix`, `--no-pci`, `timeout -s INT`, unique tap names (ch08t0...).

---------------------------------------------------------------------------------------------------

## 15. Runnable example catalogue for the course (all on THIS machine)

| # | example | devices / args | status |
|---|---|---|---|
| E1 | list cryptodevs + capabilities walker (extend crypto_aes_cbc_sha.c with capability loop) | crypto_null0, crypto_openssl0 | easy, API verified |
| E2 | AES-CBC+HMAC chain, compare to openssl CLI | crypto_openssl0 | **verified** |
| E3 | AES-GCM AEAD encrypt + decrypt/verify, tamper one byte -> AUTH_FAILED | crypto_openssl0 | straightforward variant |
| E4 | asym modexp (and RSA sign/verify, ML-KEM keygen as stretch) | crypto_openssl0 | modexp **verified** |
| E5 | test-crypto-perf sweep buffer sizes -> chart | crypto_openssl0 / crypto_null | **verified** |
| E6 | crypto_scheduler round-robin / pkt-size-distr | 2× crypto_null / openssl | rr **verified** |
| E7 | l2fwd-crypto over pcap | net_pcap + crypto_openssl | **verified** |
| E8 | DEFLATE stateless round trip + ratio vs level | compress_zlib0 | **verified** |
| E9 | dmadev copy/fill, completed vs completed_status, fence | dma_skeleton0,lcore=1 | copy **verified** |
| E10 | dpdk-dma forwarding bottleneck | dma_skeleton + net_pcap infinite_rx | **verified** |
| E11 | eventdev atomic/ordered/parallel comparison | event_sw0, -l 0-2 | **verified** |
| E12 | test-eventdev order/perf/pipeline | event_sw0, -s 0x8 | **verified** |
| E13 | eventdev_pipeline / l2fwd-event with eth Rx/Tx adapters | event_sw + net_pcap | **verified** (runs) |
| E14 | timer adapter (arm/cancel/expire, periodic flag) | event_sw0, service lcore 1 | **verified** |
| E15 | crypto adapter OP_NEW | event_sw0 + crypto_openssl0 | **verified**; OP_FORWARD variant TODO |
| E16 | bbdev null loopback lifecycle | baseband_null0 | **verified** |
| E17 | rawdev skeleton selftest | rawdev_skeleton,selftest=1 | **verified** |
| E18 | lib/ipsec or ipsec-secgw lookaside-none ESP tunnel | net_tap ×2 + crypto_openssl | app starts; traffic dropped — needs debugging |
| E19 | mldev quantize helpers (`rte_ml_io_float32_to_int8`) without a device | none | untested idea |

Build line for all: `gcc x.c -o x $(pkg-config --cflags libdpdk) $(pkg-config --libs --static libdpdk)`
(add `#include <inttypes.h>` for PRIu64).

---------------------------------------------------------------------------------------------------

## 16. Source references

Docs ($DPDK_SRC/doc/guides): prog_guide/cryptodev_lib.rst (sessions §480–590, sync mode, raw DP §591, asym §925),
prog_guide/rte_security.rst, howto/security.rst, prog_guide/compressdev.rst, prog_guide/dmadev.rst,
prog_guide/eventdev/{eventdev,event_ethernet_rx_adapter,event_ethernet_tx_adapter,event_timer_adapter,
event_crypto_adapter,event_dma_adapter,event_vector_adapter,dispatcher_lib}.rst, prog_guide/bbdev.rst,
gpudev.rst, mldev.rst, regexdev.rst, rawdev.rst, cryptodevs/{openssl,null,scheduler}.rst, eventdevs/sw.rst,
compressdevs/zlib.rst, dmadevs/*, sample_app_ug/{l2_forward_crypto,ipsec_secgw,eventdev_pipeline,
l2_forward_event,dma,bbdev_app,vhost_crypto}.rst, tools/{cryptoperf,testeventdev}.rst.
Headers: lib/cryptodev/{rte_cryptodev.h (config :850, qp_conf :707, session_create :1212, mdata_set :1459),
rte_crypto.h (op pool :264), rte_crypto_sym.h, rte_crypto_asym.h (rte_crypto_param :245)},
lib/security/rte_security.h (:732 action types), lib/compressdev/{rte_compressdev.h,rte_comp.h},
lib/dmadev/rte_dmadev.h (capa :228, flags :1131, copy :1178, completed :1367), lib/eventdev/{rte_eventdev.h,
rte_event_*_adapter.h}, lib/dispatcher/rte_dispatcher.h, lib/bbdev/{rte_bbdev.h,rte_bbdev_op.h},
lib/gpudev/rte_gpudev.h, lib/mldev/rte_mldev.h, lib/regexdev/rte_regexdev.h, lib/rawdev/rte_rawdev.h,
lib/ipsec/{sa.c,ses.c}.
Implementation: lib/cryptodev/rte_cryptodev.c:2718 (mdata fallback), drivers/crypto/openssl/rte_openssl_pmd.c
(:2264 modexp), drivers/crypto/scheduler/*, drivers/event/sw/sw_evdev_scheduler.c (:31 atomic, :117 parallel,
:268 reorder), drivers/event/sw/sw_evdev.c (:780 service check), lib/eventdev/rte_event_timer_adapter.c,
drivers/dma/skeleton/skeleton_dmadev.c (:116 cpuwork thread), drivers/baseband/null/bbdev_null.c,
drivers/raw/skeleton/skeleton_rawdev.c, examples/{l2fwd-crypto,ipsec-secgw,eventdev_pipeline,l2fwd-event,
dma,bbdev_app,vhost_crypto}, app/{test-crypto-perf,test-eventdev}.
Web (for history/rationale, check before quoting): DPDK Summit talks on eventdev (Jerin Jacob, "Eventdev:
introduction & roadmap", 2017), "DPDK cryptodev deep dive" (Intel, Declan Doherty/Pablo de Lara),
Harry van Haaren "Software Eventdev" (event_sw design), Intel DLB whitepapers, DPDK rel_notes per release.

# Research note 04: rte_ring, rte_mempool, rte_mbuf, rte_stack, rte_reorder

**Scope:** these are the five "packet plumbing" libraries that nearly every DPDK app uses:

- `rte_ring` is the queue.
- `rte_mempool` is the fixed-size object allocator, built on a ring by default.
- `rte_mbuf` is the packet buffer, whose objects live in a mempool.
- `rte_stack` is a LIFO, and it can also serve as a mempool backend.
- `rte_reorder` restores sequence order of mbufs.

**Source of truth:** DPDK **26.11.0**, at `$DPDK_SRC=/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/clone/dpdk`.

**Measurements:** every number marked *[measured]* was produced on this VM (4-core Xeon, Linux 6.18) with the programs in `research/04-examples/`. Their outputs are in `04-examples/out.txt`, `perf.txt` and `ringeth.txt`.

---

## 0. TL;DR for the course planner

- **Teaching order (easy to hard):**
  1. ring basics: create, enqueue/dequeue, bulk vs burst
  2. ring internals: head/tail, CAS, modulo-2^32 indexes
  3. ring sync modes: SP/SC, MP/MC, RTS, HTS
  4. peek and zero-copy APIs, elem rings, then SORING
  5. mempool basics
  6. mempool per-lcore cache (the most important performance idea)
  7. mempool ops/handlers: ring/stack/lf_stack/pile/bucket
  8. mbuf anatomy: two cache lines, headroom/data/tailroom
  9. mbuf manipulation: append/prepend/adj/trim/mtod
  10. pktmbuf pool creation and the object layout in memory
  11. chained (multi-seg) mbufs
  12. refcnt, clone/indirect, external buffers
  13. offload flags and packet types
  14. dynfields and dynflags
  15. rte_stack
  16. rte_reorder plus the packet_ordering sample
- **Suggested split:** this material is large enough for **3 chapters**:
  - A: Rings
  - B: Mempools
  - C: Mbufs, with stack and reorder appended to C or B
  - If the course needs it compressed, use 2 chapters: "Ring & Mempool" and "Mbuf, Stack & Reorder".
- **Everything here runs with no NIC.** All of it uses `--no-huge -m 128..256 --no-pci --file-prefix=chNN`, and several examples need no ethdev at all. The ethdev-flavoured demos use `net_ring` (`rte_eth_from_ring()`), `net_null` and testpmd.
- **Version gotcha: the mempool cache changed in 26.07/26.11.**
  - The `flushthresh` field is gone.
  - The cache now holds at most `size` objects, flushing and refilling exactly `size/2`.
  - `RTE_MEMPOOL_CACHE_MAX_SIZE` (512) no longer limits `cache_size`.
  - Most blogs and older talks describe the old "1.5 x size flush threshold" behaviour. The course must teach the new one and mention the old one as history.
- **New in 26.11:** the `RTE_STACK_F_PILE` stack type and the `"pile"` mempool driver.
- **Recently added:**
  - SORING, the Staged-Ordered Ring (25.03), with peek API in 26.07.
  - mbuf history tracking (`RTE_MBUF_HISTORY_DEBUG`, 25.11), with a testpmd `dump mbuf history` command.

---

## 1. rte_ring

### 1.1 Files

| File | Contents |
|---|---|
| `lib/ring/rte_ring_core.h` | `struct rte_ring`, `struct rte_ring_headtail`, RTS/HTS headtail unions, `RING_F_*` flags, `enum rte_ring_sync_type` |
| `lib/ring/rte_ring.h` | Pointer-ring API (`rte_ring_create`, `rte_ring_[mp|sp|]enqueue[_bulk|_burst]`, `rte_ring_count/free_count/full/empty`, `rte_ring_dump`, `rte_ring_reset`, `rte_ring_lookup`) |
| `lib/ring/rte_ring_elem.h` | Same API for arbitrary element size (`_elem` suffix, esize must be a multiple of 4) |
| `lib/ring/rte_ring_elem_pvt.h` | Copy helpers (`__rte_ring_enqueue_elems_32/64/128`) and the generic `__rte_ring_do_enqueue_elem` / `__rte_ring_do_dequeue_elem` |
| `lib/ring/rte_ring_c11_pvt.h`, `rte_ring_gcc_pvt.h` | `__rte_ring_headtail_move_head_mt/st`, `__rte_ring_update_tail` (C11 memory model is the default) |
| `lib/ring/rte_ring_rts.h`, `rte_ring_rts_elem_pvt.h` | Relaxed Tail Sync, plus `rte_ring_set/get_prod/cons_htd_max` |
| `lib/ring/rte_ring_hts.h`, `rte_ring_hts_elem_pvt.h` | Head/Tail Sync |
| `lib/ring/rte_ring_peek.h`, `rte_ring_peek_zc.h` | `*_start` / `*_finish` peek API and the zero-copy API with `struct rte_ring_zc_data` |
| `lib/ring/rte_soring.h`, `soring.c` | Staged-Ordered Ring |
| `doc/guides/prog_guide/ring_lib.rst` | Official guide, with step-by-step figures `img/ring-enqueue1..3`, `ring-mp-enqueue1..5`, `ring-modulo1/2`, `soring-pic1` |
| `app/test/test_ring*.c`, `test_ring_*_stress.c`, `test_soring*.c` | Excellent reference usage |
| `drivers/net/ring/rte_eth_ring.c` | The ring PMD, `rte_eth_from_ring(s)`. A ring disguised as an ethdev. |

### 1.2 Concept

- A ring is a **fixed-size FIFO** of pointers or N*4-byte elements, stored in a contiguous table that follows the `struct rte_ring` header (`&r[1]`).
- It is **lockless**:
  - Multi-producer enqueue needs one 32-bit CAS on `prod.head`.
  - It then spins until `prod.tail` reaches its old head before publishing.
- It comes from FreeBSD `buf_ring.h` (8.0). The guide also cites the Linux lockless ring buffer design (LWN 340400).
- A ring is named, and lives in a memzone named `RG_<name>`, so secondary processes can `rte_ring_lookup()` it.
- `RTE_RING_NAMESIZE` = memzone name size minus 3.

`struct rte_ring` is 384 bytes *[measured]*, laid out as follows:

- **Line 0:** name, flags, memzone, `size`, `mask`, `capacity`.
- **`RTE_CACHE_GUARD`.**
- **Producer `headtail` at offset 128:** `{head, tail, sync_type}`, in a union with `hts_prod` and `rts_prod`.
- **Guard.**
- **Consumer `headtail` at offset 256.**
- **Guard.**

The producer and consumer data sit on separate cache lines, with guards against adjacent-line prefetch, so producers and consumers don't false-share.

### 1.3 Sizes and capacity *[measured]*

- `rte_ring_create("r",1024,..)` gives size 1024 and **capacity 1023**. One slot is sacrificed so full and empty can be told apart.
- A non-power-of-2 count (for example 1000) without `RING_F_EXACT_SZ` gives **NULL with `rte_errno=EINVAL`**. The log says "must be power of 2".
- `RING_F_EXACT_SZ` with 1000 gives size 1024 and capacity exactly 1000.
- `rte_ring_get_memsize(1024)` is 8640 bytes: 384 for the header plus 8 x 1024 for the table, rounded up.

### 1.4 Head/tail algorithm (the core lesson)

**State.** Each side keeps two 32-bit indexes:

- `prod.head` / `prod.tail`
- `cons.head` / `cons.tail`

They run freely over 0..2^32-1. The slot used is `idx & mask`.

**Formulas.** Unsigned modulo arithmetic gives:

- `entries = prod_tail - cons_head`
- `free = capacity + cons_tail - prod_head`

These stay correct across 32-bit wrap. That is why the indexes are never reset: `rte_ring_dump` showed `prod.head=1028` on a 1024-slot ring *[measured]*.

**Enqueue** (`__rte_ring_do_enqueue_elem` in `rte_ring_elem_pvt.h`):

1. **move_head.** Load `prod.head` (acquire), load `cons.tail` (acquire), compute free space, and clip n:
   - FIXED (bulk): n becomes 0.
   - VARIABLE (burst): n becomes `free`.
   - MP mode then does a CAS of `prod.head` from old to old+n (release on success), and retries on failure.
   - ST mode does a plain relaxed store.
2. **Copy** the objects into `ring[(old_head & mask) ...]`. This handles wrap-around and uses 8- or 16-byte specialised copies.
3. **update_tail.** In MP mode, wait until `prod.tail == old_head` (`rte_wait_until_equal_32`, relaxed), then store-release `prod.tail = new_head`.

The wait in step 3 is the subtle bit: producers *finish in the same order they reserved*. A preempted producer stalls everyone behind it. This is the "lock-waiter preemption" problem.

**Dequeue** mirrors this with `cons.head`, `prod.tail` and `cons.tail`.

**Memory ordering.** The comments label the synchronisation edges A0/A1/R0/R1 (see `rte_ring_c11_pvt.h`). Release on tail pairs with acquire on the opposite side's tail. This is the right place for an advanced sidebar on acquire/release.

**Teaching device.** The official guide walks through 2 producers on 2 cores in 5 steps: both read, one wins the CAS, the other retries, both copy, then the tails update in order. That is a perfect animation script.

### 1.5 API families

| Dimension | Options |
|---|---|
| Who | `mp_`/`sp_` (enqueue), `mc_`/`sc_` (dequeue), or no prefix, which uses the default chosen by flags at create time |
| How many | `_bulk` is all or nothing and returns 0 or n. `_burst` takes as many as possible. Single-object `rte_ring_enqueue()` / `rte_ring_dequeue()` return 0 or `-ENOBUFS` / `-ENOENT`. |
| What | Pointer ring (`rte_ring_*`), or element ring (`rte_ring_*_elem`, with esize given on every call and required to equal the create-time esize) |
| Out-params | `free_space` (enqueue) and `available` (dequeue) are optional `unsigned int *` |

Measured semantics *[measured]*:

- `enqueue_bulk(1500)` into an empty capacity-1023 ring returns **0**: nothing is enqueued.
- `enqueue_burst(1500)` returns **1023** with free=0.

### 1.6 Sync modes (`enum rte_ring_sync_type`, set by flags)

| Flags | Mode | Mechanism | Use |
|---|---|---|---|
| default (0) | `RTE_RING_SYNC_MT` (MP/MC) | 32-bit CAS on head, spin on tail | Classic 1-thread-per-core |
| `RING_F_SP_ENQ` / `RING_F_SC_DEQ` | `RTE_RING_SYNC_ST` | No atomics RMW | Exactly one producer or consumer thread (fastest) |
| `RING_F_MP_RTS_ENQ` / `RING_F_MC_RTS_DEQ` | `RTE_RING_SYNC_MT_RTS` | head and tail are `{cnt,pos}` 64-bit, two 64-bit CAS. Only the *last* finishing thread moves the tail (`tail.cnt+1 == head.cnt`). `htd_max` limits head-tail distance (default capacity/8; measured 127 for a 1024 ring). | Overcommitted systems (more threads than cores, VMs, containers) |
| `RING_F_MP_HTS_ENQ` / `RING_F_MC_HTS_DEQ` | `RTE_RING_SYNC_MT_HTS` | `{head,tail}` updated as one 64-bit value. A thread may move head only when head==tail, so operations are fully serialized. | Overcommit; enables an MT-safe peek and zero-copy API |

- Producer and consumer modes are independent. For example, MP RTS enqueue can pair with SC dequeue.
- `rte_ring_get_prod_sync_type()` returns the enum. *[measured]* An HTS ring reports 3.

**History and rationale:**

- RTS and HTS were added in **20.05** by Konstantin Ananyev (Intel), in the RFC "New sync modes for ring" (Feb 2020).
- The motivation was lock-holder and lock-waiter preemption when there are more threads than cores.
- Reviewers, including Honnappa Nagarahalli (Arm), debated whether these belonged in rte_ring or in a new primitive.

**Perf** *[measured, noisy VM, 1 producer lcore + 1 consumer lcore, 2M objects, cycles per object]*:

| burst | SP/SC | MP/MC | RTS | HTS |
|---|---|---|---|---|
| 1 | 195 | 758 | 1026 | 845 |
| 32 | 21.6 | 36.9 | 41.8 | 41.7 |

Lessons:

1. Bursting amortises the atomics by roughly 10-35x.
2. SP/SC is the cheapest.
3. RTS and HTS cost slightly more when not overcommitted. They pay off only under preemption.

A good chapter lab is `perf.c`, extended to run 3 producers on 1 core, for example `-l 0-1` with oversubscribed pthreads, to show the MP/MC tail-spin collapse.

### 1.7 Peek API (`rte_ring_peek.h`)

- This API is only for **ST or HTS** rings. On other modes it hits `RTE_ASSERT(0)` and returns 0.
- `rte_ring_dequeue_bulk_start(r,&obj,1,NULL)` lets you inspect an object.
- Then `rte_ring_dequeue_finish(r,0)` keeps it, or `finish(r,n)` removes it.
- `rte_ring_enqueue_bulk_start` reserves space, then `rte_ring_enqueue_finish(r,objs,n)` publishes it.
- *[measured]* `finish(0)` leaves the object, and the next `start` returns the same object.
- Between `start` and `finish` no other thread can enqueue or dequeue on that side.

### 1.8 Zero-copy API (`rte_ring_peek_zc.h`, 20.11, Arm/Honnappa)

- `rte_ring_enqueue_zc_burst_start(r, n, &zcd, &free)` fills `struct rte_ring_zc_data {ptr1, n1, ptr2}`.
- When the reservation wraps the end of the table it is split in two:
  - n1 objects at ptr1
  - n-n1 objects at ptr2, the start of the table
- The canonical use is to have `rte_eth_rx_burst()` write mbuf pointers *directly into the ring*. This avoids the on-stack mbuf array.
- *[measured]* After moving the indexes to 1020 on a 1024 ring, a zc start of 8 gives n1=4 plus a non-NULL ptr2, which visibly demonstrates the wrap split.

### 1.9 Element rings

- `rte_ring_create_elem(name, esize, count, socket, flags)`, where esize is a multiple of 4. 8- and 16-byte elements take fast copy paths.
- The elem versions of all APIs exist: `rte_ring_enqueue_bulk_elem(r,obj,esize,n,&free)` and so on.
- Use them to pass small structs by value, such as `{uint64 a,b}` *[measured round-trip on an HTS elem ring]*, or event-like descriptors without a pointer indirection.
- They were added in 20.02.

### 1.10 SORING (Staged-Ordered Ring, 25.03; peek 26.07)

- Its pieces are:
  - a producer
  - N stages, each with `rte_soring_acquire[_burst]` / `rte_soring_release`
  - a consumer
- Objects stay in place and their order is preserved.
- There is an optional per-object metadata array, used by the "x" variants: `enqueux`, `dequeux`, `acquirx`, `releasx`.
- Internally there is a `state[]` array, and a `finalize` step advances a stage's tail across released entries.
- Typical use is IPsec-style pipelines that must preserve order.
- This is advanced material: a sidebar or appendix after reorder, contrasted with rte_reorder.
- Reference usage is in `app/test/test_soring*.c`.

### 1.11 Ring PMD

- `rte_eth_from_ring(r)` creates an ethdev whose RX and TX queues are **the same ring**.
- *[measured `ringeth.c`]* `tx_burst` of 4 mbufs, then `rx_burst`, returns *the identical mbuf pointers*.
- This is the best possible demo that "packets" in DPDK are just pointers moving through rings, with zero copy.
- `--vdev=net_ring0` creates 16 rings named `ETH_RXTX0..15_net_ring0`. The devarg is `nodeaction=name:node:CREATE|ATTACH`.
- testpmd's `dump ring` lists them, together with the mempool's ring `MP_mb_pool_0`.

---

## 2. rte_mempool

### 2.1 Files

| File | Contents |
|---|---|
| `lib/mempool/rte_mempool.h` | Structs (`rte_mempool`, `rte_mempool_cache`, `rte_mempool_objhdr`, `rte_mempool_memhdr`, `rte_mempool_ops`), the inline fast path `rte_mempool_do_generic_get/put`, and flags `RTE_MEMPOOL_F_*` |
| `lib/mempool/rte_mempool.c` | `rte_mempool_create_empty`, `rte_mempool_populate_default/virt/iova/anon`, `rte_mempool_get_page_size`, `rte_mempool_dump`, `rte_mempool_audit`, `rte_mempool_walk`, `rte_mempool_cache_create/free/flush` |
| `lib/mempool/rte_mempool_ops.c`, `rte_mempool_ops_default.c` | Ops table, `rte_mempool_set_ops_byname`, `RTE_MEMPOOL_REGISTER_OPS`, default calc_mem_size/populate (no object crosses a page when IOVA-contig is needed) |
| `drivers/mempool/ring/rte_mempool_ring.c` | Ops `ring_mp_mc` (default), `ring_sp_sc`, `ring_mp_sc`, `ring_sp_mc`, `ring_mt_rts`, `ring_mt_hts` |
| `drivers/mempool/stack/rte_mempool_stack.c` | Ops `stack` (spinlock), `lf_stack` (lock-free), `pile` (26.11) |
| `drivers/mempool/bucket/rte_mempool_bucket.c` | Ops `bucket`: contiguous buckets of objects, `dequeue_contig_blocks`, `RTE_DRIVER_MEMPOOL_BUCKET_SIZE_KB` |
| `config/rte_config.h` | `RTE_MEMPOOL_CACHE_MAX_SIZE 512` (compatibility only), `RTE_LIBRTE_MEMPOOL_STATS`/`DEBUG` (off), `RTE_MBUF_DEFAULT_MEMPOOL_OPS "ring_mp_mc"`, `RTE_STACK_PILE_BULK_SIZE 32` |
| `doc/guides/prog_guide/mempool_lib.rst` | Figures `img/mempool.*` (cache), `memory-management*.*` (channel spreading) |

### 2.2 Concept

- A mempool is a **named pool of N fixed-size objects**, allocated once at init and never returned to the OS.
- Free objects sit in a **handler** ("ops"), which by default is an `rte_ring` of pointers named `MP_<name>`.
- In front of the handler sits an optional **per-lcore cache**, a small LIFO stack of pointers, one per lcore.
- The point is to replace malloc/free on the data path with an O(1), mostly lock-free, cache-hot pointer pop.

### 2.3 Object layout in memory

Each object is laid out as `[objhdr | elt | trailer]`. The header is a `struct rte_mempool_objhdr {STAILQ next; mp *; iova; [cookie]}`, padded to 64.

- `rte_mempool_from_obj(obj)` reads `mp` from the header just before the object.
- `rte_mempool_virt2iova(obj)` reads `iova` from the header.
- **Channel spreading.** Unless `RTE_MEMPOOL_F_NO_SPREAD` is set, `trailer_size` is padded so that object start addresses rotate across DRAM channels and ranks.
  - *[measured]* A 64-byte elt got header 64 and trailer 64.
  - The pktmbuf pool got a trailer of 112 bytes, for a total of 2496.
  - With testpmd's pool the trailer was 0.
  - This feature is absent on Arm (hashing interconnects).
- **Page-boundary rule.** When objects must be IOVA-contiguous (the default, unless `RTE_MEMPOOL_F_NO_IOVA_CONTIG`), no object may straddle a page. `rte_mempool_get_page_size()` uses the hugepage size, or the 4K system page under `--no-huge`.
  - **[measured] Under `--no-huge`, one ~2.4 KB mbuf occupies a whole 4 KB page: 4096 bytes per object, versus 2370 bytes with 2 MB hugepages (-m 64).**
  - This is a great "why hugepages matter" demo.
  - It is also a practical gotcha: `dpdk-packet_ordering` (65535 mbufs) fails with "Cannot allocate memory" at `--no-huge -m 256`, and works at `-m 1024`.

### 2.4 Creation APIs

- **One-shot:** `rte_mempool_create(name, n, elt_size, cache_size, private_data_size, mp_init, mp_init_arg, obj_init, obj_init_arg, socket, flags)`.
  - It uses the default ring ops. `RTE_MEMPOOL_F_SP_PUT` / `SC_GET` select `ring_sp_*`.
- **Step-wise:**
  1. `rte_mempool_create_empty()`
  2. `rte_mempool_set_ops_byname(mp, "stack", NULL)`
  3. `rte_mempool_populate_default(mp)`, or `populate_anon`, `populate_virt` (user memory) or `populate_iova`
  4. `rte_mempool_obj_iter(mp, cb, arg)` to run constructors
- *[measured]* All of `ring_sp_sc`, `stack`, `lf_stack`, `pile`, `bucket` and `ring_mt_hts` populated 1023 objects successfully on this build.
- **N choice:** the optimum for ring-backed pools is `2^q - 1`, because the ring holds n+1 rounded up to a power of 2.

### 2.5 Per-lcore cache: the 26.11 algorithm (`rte_mempool_do_generic_put/get`)

The cache is `struct rte_mempool_cache {size, len, [stats], objs[] (flexible)}`. The per-lcore caches are laid out after the pool's private data, with stride `mp->sizeof_cache_per_lcore`, which includes `RTE_CACHE_GUARD` lines. `rte_mempool_default_cache(mp, lcore)` indexes them, and returns NULL for non-EAL threads (`LCORE_ID_ANY`) or when cache_size is 0.

**put(n):**

- If `len+n <= size`, copy onto the top of the stack.
- Otherwise, if `n <= size/2`:
  - Flush the **bottom** `size/2` objects (the coldest) to the backend.
  - memmove the hot upper half down.
  - Then push.
- Otherwise (n is larger than size/2), bypass the cache and enqueue directly to the backend.

**get(n):**

- If `n <= len`, pop from the top, in reverse order, LIFO and hot.
- Otherwise:
  - Drain whatever is cached.
  - If the remainder is at most `size/2`, refill exactly `size/2` from the backend and serve the remainder from that refill.
  - Otherwise, take the remainder straight from the backend.
- On failure, the cache contents are restored (`cache->len = n - remaining`).

**Trace** *[measured, cache_size=256, pool 4095]*:

| Step | Cache len |
|---|---|
| get 1 | 127 (refilled 128, gave 1) |
| put 1 | 128 |
| get 200 (> size/2) | 56. The ring count went to 3839, meaning 256 were taken from the ring: 128 refilled earlier, then the 200 served as 128 from cache plus 72 direct. |
| put 200 | 256 |
| `rte_mempool_cache_flush` | 0 |

**Perf** *[measured]*: 2 lcores each doing get/put of 32, in a loop:

- no cache: **86 cycles/obj**
- cache 256: **1.3 cycles/obj**

That is a 65x difference, and it is *the* headline number for the chapter.

**Other cache facts:**

- **History:** before 26.07/26.11 there was `flushthresh = 1.5 x size`. The cache could temporarily hold more than `size`, and `cache_size` was capped at `RTE_MEMPOOL_CACHE_MAX_SIZE` (512) and had to be at most n/1.5.
  - 26.11 removed `flushthresh` and the `unused` field, made `objs[]` variable-size, and added `mp->sizeof_cache_per_lcore`.
  - The cache size now only has to be at most n.
  - The work is by Morten Brørup, "mempool: improve cache behaviour and performance".
- **Idle buffers:** objects can sit "stranded" in other lcores' caches. `rte_mempool_avail_count()` includes cached objects. A pool with N=1024 and cache 256 on 4 lcores can see `get` fail while there are apparently free objects. Size N to be at least `nb_lcores*cache_size + in-flight descriptors`.
  - testpmd's dump shows `cache_count[lcore]` and `common_pool_count`.
- **User-owned caches:** `rte_mempool_cache_create(size, socket)`, then `rte_mempool_generic_get/put(mp, objs, n, cache)`. These are the way for **non-EAL threads** to get caching.

### 2.6 Ops / handlers

`struct rte_mempool_ops {name, alloc, free, enqueue, dequeue, get_count, calc_mem_size, populate, get_info, dequeue_contig_blocks}`:

- It is registered with `RTE_MEMPOOL_REGISTER_OPS(ops)` into the `rte_mempool_ops_table` (max 32).
- The pool stores an **index** (`ops_index`), not a pointer, so that secondary processes work. Multiple processes must load `-d` handler .so files in the same order.
- The handler concept was added in 16.07 as the "external mempool manager". It lets hardware buffer managers plug in: cnxk/octeontx NPA, DPAA BMan, dpaa2.

The handlers in this build:

| Ops name | Backend | Properties |
|---|---|---|
| `ring_mp_mc` | MP/MC ring | Default (`RTE_MBUF_DEFAULT_MEMPOOL_OPS`) |
| `ring_sp_sc` etc. | ST ring | When exactly one thread puts and one gets |
| `ring_mt_rts`, `ring_mt_hts` | RTS/HTS ring | Overcommitted threads |
| `stack` | Spinlock LIFO | LIFO means it returns the most recently freed object, which is more cache-warm |
| `lf_stack` | Lock-free linked-list stack, 128-bit CAS | 19.05, Gage Eads (Intel). Preemption-tolerant. |
| `pile` | Lock-free, LIFO at bulk granularity (32) | 26.11. Best when cache_size/2 is a multiple of 32. |
| `bucket` | Objects grouped in physically contiguous buckets | 18.05 (Solarflare/OKTET, Andrew Rybchenko). Supports `rte_mempool_get_contig_blocks()`. |

- **mbuf ops selection** (`lib/mbuf/rte_mbuf_pool_ops.c`): `rte_mbuf_best_mempool_ops()` checks, in order:
  1. the user setting (`rte_mbuf_set_user_mempool_ops`, or the EAL option `--mbuf-pool-ops-name`)
  2. the platform setting
  3. `RTE_MBUF_DEFAULT_MEMPOOL_OPS`
- testpmd prints "preferred mempool ops selected: ring_mp_mc".

### 2.7 Other mempool APIs worth showing

- `rte_mempool_get` / `put`, plus `_bulk` versions. A bulk get is **all or nothing** and returns `-ENOENT`.
- `rte_mempool_avail_count`, `in_use_count`, `full`, `empty`, `lookup`, `walk`, `obj_iter`, `mem_iter`, `dump`, `audit`, `list_dump`.
- Telemetry: `/mempool/list`, `/mempool/info`.
- Stats need `RTE_LIBRTE_MEMPOOL_STATS` and the debug cookies need `RTE_LIBRTE_MEMPOOL_DEBUG`. Both are off in this build, so `dump` prints "no statistics available".

---

## 3. rte_mbuf

### 3.1 Files

| File | Contents |
|---|---|
| `lib/mbuf/rte_mbuf_core.h` | `struct rte_mbuf`, `RTE_MBUF_F_RX_*`/`TX_*` flags, `RTE_MBUF_F_INDIRECT` (bit 62), `RTE_MBUF_F_EXTERNAL` (bit 61), `struct rte_mbuf_ext_shared_info`, `RTE_MBUF_DEFAULT_BUF_SIZE`, the `RTE_MBUF_DIRECT`/`CLONED`/`HAS_EXTBUF` macros |
| `lib/mbuf/rte_mbuf.h` | API: alloc/free/bulk, append/prepend/adj/trim/chain/linearize/read/copy/clone/attach/detach/attach_extbuf, `rte_pktmbuf_pool_create[_by_ops|_extbuf]`, `rte_pktmbuf_mtod[_offset]`, `rte_mbuf_refcnt_*`, `rte_pktmbuf_prefree_seg`, `rte_mbuf_raw_alloc/free[_bulk]`, `rte_mbuf_sanity_check` |
| `lib/mbuf/rte_mbuf_dyn.h`, `rte_mbuf_dyn.c` | Dynamic fields and flags; well-known names (timestamp, metadata, IP reassembly, history) |
| `lib/mbuf/rte_mbuf_ptype.h`, `.c` | `RTE_PTYPE_*`, `rte_get_ptype_name`, and the `rte_get_ptype_*_name` helpers |
| `lib/mbuf/rte_mbuf_pool_ops.[ch]` | Best-ops selection |
| `lib/mbuf/rte_mbuf_history.h`, `mbuf_history.c` | 25.11: lifecycle tracking with `RTE_MBUF_HISTORY_DEBUG`, `rte_mbuf_history_mark_bulk`, `rte_mbuf_history_dump_all`, and `usertools/dpdk-mbuf-history-parser.py` |
| `doc/guides/prog_guide/mbuf_lib.rst` | Figures `img/mbuf1` (1 seg), `img/mbuf2` (3 segs); TX offload recipes for VXLAN |
| `app/test-pmd/csumonly.c`, `txonly.c` | Real-world offload flag usage and multi-seg TX |
| `examples/ipv4_multicast/main.c` | Clone/indirect: a header pool plus a clone pool and `rte_pktmbuf_clone` |
| `examples/ip_fragmentation` | Indirect mbufs for fragments; `lib/ip_frag` |

### 3.2 Design choice

- Metadata and data share **one buffer**: the mbuf header, then the private area, then the data buffer. One alloc or free handles both.
- The alternative, separate metadata and data, was rejected for the default. It is still possible through external buffers.
- An mbuf is any message: a packet, a crypto op payload, an event.

### 3.3 Layout *[measured offsets, x86-64, `RTE_IOVA_IN_MBUF=1`]*

The struct is **128 bytes, two cache lines.**

**Cache line 0, the RX fast path:**

| Offset | Field |
|---|---|
| 0 | `buf_addr` |
| 8 | `buf_iova` |
| 16 | `rearm_data`: `data_off`, then `refcnt` (18), `nb_segs` (20), `port` (22). Drivers rearm descriptors with a single 8-byte store. |
| 24 | `ol_flags` |
| 32 | `rx_descriptor_fields1`: `packet_type` (32), `pkt_len` (36), `data_len` (40), `vlan_tci` (42), `hash` (44, union of rss/fdir/sched/txadapter/usr), `vlan_tci_outer` (52), `buf_len` (54) |
| 56 | `pool` |

**Cache line 1, the TX and slow path:**

| Offset | Field |
|---|---|
| 64 | `next` |
| 72 | `tx_offload` bitfield (`l2_len:7`, `l3_len:9`, `l4_len:8`, `tso_segsz:16`, `outer_l3_len:9`, `outer_l2_len:7`) |
| 80 | `shinfo` |
| 88 | `priv_size` |
| 90 | `timesync` |
| 92 | `dynfield1[9]`, 36 bytes, ending at 128 |

Notes on the layout:

- When `RTE_IOVA_IN_MBUF=0` (the `enable_iova_as_pa=false` build), the slot at 8 holds `next`, and the slot at 64 becomes `dynfield2`.
- History of the struct size and fields: https://doc.dpdk.org/struct/mbuf/history.html.
- **Buffer layout:** `[struct rte_mbuf 128][priv_size][headroom RTE_PKTMBUF_HEADROOM=128][data room ... buf_len]`.
  - `buf_addr = (char*)m + sizeof(mbuf) + priv_size`. *[measured]* With priv 16, `buf_addr - m = 144`.
  - `rte_pktmbuf_mtod(m,T)` is `(T)((char*)buf_addr + data_off)`.
  - `rte_mbuf_to_priv(m)` is `m+1`.

### 3.4 pktmbuf pool

- `rte_pktmbuf_pool_create(name, n, cache_size, priv_size, data_room_size, socket)`:
  - elt_size = `sizeof(rte_mbuf) + priv_size + data_room_size`.
  - The pool private area stores `struct rte_pktmbuf_pool_private {mbuf_data_room_size, mbuf_priv_size, flags}`.
  - It calls `rte_pktmbuf_init()` per object, which sets the constant fields `pool`, `buf_addr`, `buf_iova`, `buf_len`, `priv_size` and `refcnt=1` once, so allocation doesn't have to.
- **Default buffer size:** `RTE_MBUF_DEFAULT_BUF_SIZE = 2048 + 128 = 2176`.
- *[measured]* The defaults with priv 16 gave elt_size 2320 and header 64.
- A fresh mbuf has:
  - data_off 128
  - headroom 128, tailroom 2048
  - refcnt 1, nb_segs 1, pkt_len 0
- **Variants:**
  - `rte_pktmbuf_pool_create_by_ops(..., "stack")` picks a specific handler.
  - `rte_pktmbuf_pool_create_extbuf(..., ext_mem[], n)` uses data buffers in external, pinned memory. That sets the `RTE_PKTMBUF_POOL_F_PINNED_EXT_BUF` behaviour, as used by mlx5 MPRQ.
- **Indirect or clone pool:** `data_room_size=0`, giving elt_size 128 *[measured]*.

### 3.5 Manipulation *[measured]*

Starting from a fresh mbuf:

1. `append(100)` returns a pointer to the tail and sets len 100.
2. `prepend(14)` gives data_off 114 and len 114.
3. `adj(14)` strips from the front and `trim(10)` cuts from the back, giving data_off 128 and len 90.
4. `prepend(200)` when the headroom is 128 returns **NULL**, and the mbuf is unchanged.

Other functions:

- `rte_pktmbuf_headroom` / `tailroom`
- `rte_pktmbuf_data_len` / `pkt_len`
- `rte_pktmbuf_mtod_offset`
- `rte_pktmbuf_reset`, `rte_pktmbuf_dump(f, m, dump_len)`

The functions affect different fields:

- `pkt_len` is the sum over all segments and lives only in the first segment.
- `data_len` is per segment.
- append, trim and adj operate on the **last** segment (append, trim) or the **first** (adj, prepend).

### 3.6 Chained mbufs

- `rte_pktmbuf_chain(head, tail)` links the segments, updating `nb_segs` and `pkt_len`. It fails if nb_segs would exceed `RTE_MBUF_MAX_NB_SEGS`.
- *[measured]* 90 + 50 bytes gives nb_segs 2, pkt_len 140, and `is_contiguous=0`.
- `rte_pktmbuf_read(m, off, len, buf)` returns a direct pointer when the range is contiguous, or copies into `buf` when it crosses segments.
- `rte_pktmbuf_linearize(m)` copies everything into the first segment if it has room. *[measured]* It returned 0 and left nb_segs at 1.
- `rte_pktmbuf_lastseg(m)`.
- `rte_pktmbuf_free(m)` frees the entire chain. `rte_pktmbuf_free_seg` frees one segment.
- The metadata (ol_flags, ptype, port, offload lengths) is meaningful only in the first segment.
- Multi-segment packets in testpmd:
  - `set txpkts 64,64` makes txonly send 2-segment packets ("nb packet segments=2" *[measured]*).
  - `--rxpkts` / `--mbuf-size=` combined with buffer split gives multi-segment RX.

### 3.7 Refcnt, clone, indirect and external buffers

**refcnt:**

- It is a 16-bit atomic, `rte_mbuf_refcnt_read/set/update`.
- `rte_pktmbuf_free` decrements it and only returns the mbuf to the pool at 0. The fast path skips the atomic when refcnt is 1 (`rte_pktmbuf_prefree_seg`).
- *[measured]* At refcnt 3, two frees left refcnt at 1.

**The free-mbuf invariant:** an mbuf in the pool has `refcnt==1, next==NULL, nb_segs==1`.

- `prefree_seg` enforces this.
- The raw APIs `rte_mbuf_raw_alloc/free[_bulk]` require you to maintain it yourself.
- `rte_mbuf_raw_reset_bulk` is a related helper.

**Indirect (clone):**

- `rte_pktmbuf_clone(m, clone_pool)` allocates small mbufs, one per segment, and `rte_pktmbuf_attach`es them. Each attached mbuf points its `buf_addr` at the original's buffer and sets `RTE_MBUF_F_INDIRECT`. The original's refcnt is incremented.
- *[measured]*
  - Cloning gives original refcnt 2, with the clone sharing `buf_addr`.
  - After `free(orig)` the pool's available count does not change, because the data is still referenced.
  - After `free(clone)` the count goes up by one.
- **Rules:**
  - Attaching to an indirect mbuf attaches to the underlying direct one.
  - Only a refcnt==1 mbuf can become indirect.
  - Detach before reattaching.
- `rte_mbuf_from_indirect(mi)` finds the direct mbuf.
- Use cases: multicast (one payload, N headers prepended with chained header mbufs), fragmentation, capture or mirroring (`pdump` uses `rte_pktmbuf_copy`).

**External buffer (`RTE_MBUF_F_EXTERNAL`):**

- Data lives in user memory described by `struct rte_mbuf_ext_shared_info {free_cb, fcb_opaque, refcnt}`.
- `rte_pktmbuf_ext_shinfo_init_helper(buf, &len, cb, opaque)` places the shinfo at the end of the buffer, shrinking len.
- `rte_pktmbuf_attach_extbuf(m, addr, iova, len, shinfo)`.
- Clones bump `shinfo->refcnt`, not the mbuf refcnt. The `free_cb` runs when the last reference goes.
- *[measured]* A 1024-byte buffer shrinks to `buf_len` 1000. A clone brings the ext refcnt to 2, and the callback fires after both frees.
- Uses: zero-copy from vhost, mlx5 MPRQ, and pinned external pools.

**Copy vs clone:** `rte_pktmbuf_copy(m, pool, off, len)` makes a deep copy, while clone shares the data. Teach the difference with a "write to clone affects original" demo.

### 3.8 Offload flags and packet type

**`ol_flags`:**

- RX flags:
  - `RTE_MBUF_F_RX_VLAN[_STRIPPED]`, `RX_RSS_HASH`, `RX_FDIR`
  - the 2-bit fields `RX_IP_CKSUM_{UNKNOWN,BAD,GOOD,NONE}` (masked with `RTE_MBUF_F_RX_IP_CKSUM_MASK`) and the same for L4
  - `RX_OUTER_IP_CKSUM_BAD`, `RX_LRO`, `RX_QINQ`, `RX_IEEE1588_*`
- TX flags:
  - `RTE_MBUF_F_TX_IPV4/IPV6`, `TX_IP_CKSUM`, `TX_{TCP,UDP,SCTP}_CKSUM`, `TX_TCP_SEG`, `TX_UDP_SEG`
  - `TX_OUTER_*`, `TX_TUNNEL_{VXLAN,GRE,GENEVE,...}`, `TX_VLAN`, `TX_QINQ`, `TX_SEC_OFFLOAD`, `TX_MACSEC`
- The `PKT_*` names were renamed to `RTE_MBUF_F_*` in **21.11**.

**TX contract** (from `mbuf_lib.rst`):

- Set `l2_len`/`l3_len`[/`l4_len`/`tso_segsz`] and the flags.
- Zero the IP checksum.
- Seed the L4 checksum with the pseudo-header via `rte_ipv4_phdr_cksum()`, or `rte_ipv6_phdr_cksum()`.
- The port must advertise the matching `RTE_ETH_TX_OFFLOAD_*`.
- `rte_eth_tx_prepare()` and `rte_validate_tx_offload()` help.
- On this VM, `net_tap` and `virtio_user`/vhost advertise some checksum and TSO offloads, while null and ring advertise none. Course labs can show flags being *set*. The software path can be demonstrated with `rte_net_intel_cksum_prepare` and `rte_ipv4_cksum`.

**Packet type:**

- `packet_type` is a 32-bit field of 4-bit nibbles: L2, L3, L4, tunnel, inner L2/L3/L4.
- *[measured]* `rte_get_ptype_name` gives "L2_ETHER L3_IPV4 L4_UDP TUNNEL_VXLAN INNER_L3_IPV6 INNER_L4_TCP".
- In software, `rte_net_get_ptype(m, &hdr_lens, layers)` (lib/net) parses headers and fills ptype and lengths. It works on any vdev, which makes it a great lab.
- `rte_eth_dev_get_supported_ptypes()` reports what the hardware can classify.

### 3.9 Dynamic fields and flags (19.11, Olivier Matz)

- **Registration:**
  - `rte_mbuf_dynfield_register(&(struct rte_mbuf_dynfield){.name, .size, .align})` returns an **offset**.
  - `rte_mbuf_dynflag_register(&(struct rte_mbuf_dynflag){.name})` returns a **bit number** in ol_flags.
- **Access:** `RTE_MBUF_DYNFIELD(m, offset, type *)`. Look fields up by name with `rte_mbuf_dynfield_lookup` and `rte_mbuf_dynflag_lookup`.
- **Constraints:**
  - Registrations cannot be unregistered.
  - They are shared across processes (stored in a memzone).
  - Registering the same name and params twice returns the same offset.
- *[measured]*:
  - The first user field lands at offset 92, the start of `dynfield1`.
  - The first dyn flag is bit 23.
  - `rte_mbuf_dyn_rx_timestamp_register()` puts the timestamp at 96 and its flag at bit 24.
  - rte_reorder's seqn field landed at 104.
  - `rte_mbuf_dyn_dump()` prints a byte map of the free space and a bitmap of free ol_flags bits (bits 25-40 free here). This is a perfect source for a visualization.
- Well-known names:
  - `rte_dynfield_timestamp`
  - `rte_flow_dynfield_metadata`
  - `rte_dynfield_ip_reassembly`
  - `rte_mbuf_dynfield_history`
  - `rte_reorder_seqn_dynfield`, exposed as `rte_reorder_seqn(m)`
- The old static `timestamp`, `seqn` and `userdata` fields were removed in 20.11 in favour of dynfields.

### 3.10 Debug and safety

- `rte_mbuf_sanity_check(m, is_header)` (fully active only with `RTE_LIBRTE_MBUF_DEBUG`) and `rte_mbuf_check()`.
- `RTE_MBUF_HISTORY_DEBUG` with testpmd `dump mbuf history` (25.11).
- `rte_mempool_audit`.

---

## 4. rte_stack (19.05, Gage Eads)

- **Files:**
  - `lib/stack/rte_stack.h`, `rte_stack.c`
  - `rte_stack_std.[ch]` (spinlock plus array)
  - `rte_stack_lf.[ch]`, `rte_stack_lf_c11.h` (lock-free)
  - `rte_stack_pile.[ch]` (26.11)
  - `doc/guides/prog_guide/stack_lib.rst`
- **API:** `rte_stack_create(name, count, socket, flags)` with flags 0, `RTE_STACK_F_LF` or `RTE_STACK_F_PILE`. Then:
  - `rte_stack_push(s, objs, n)` and `rte_stack_pop(s, objs, n)`, which are all-or-nothing and return n or 0
  - `rte_stack_count`, `rte_stack_free_count`, `rte_stack_lookup`, `rte_stack_free`
- *[measured]* Push 1..5, then pop, gives 5,4,...
- **Lock-free design:**
  - A linked list of preallocated elements plus an atomic length.
  - Push links a list and CASes the head.
  - Pop first *reserves* by decrementing the length, so it cannot fail later, then walks the list and CASes the head.
  - Free elements live in a second lock-free LIFO.
  - **ABA** is prevented by a **128-bit CAS** of {head pointer, modification counter}, `rte_atomic128_cmp_exchange`. That requires `cmpxchg16b` on x86 or casp on Arm. On other platforms the LF stack is stubbed out (`rte_stack_lf_stubs.h`).
- **Pile:** LIFO at the bulk level (bulk size 32), not at the object level. It is not strictly bounded. Pop retries with fewer bulks.
- **Relation to mempool:** the `stack`, `lf_stack` and `pile` mempool handlers. Stack is LIFO, so the most recently freed object, which is still in the CPU cache, comes back first. A ring is FIFO and returns the coldest object.

## 5. rte_reorder

- **Files:** `lib/reorder/rte_reorder.[ch]`, `doc/guides/prog_guide/reorder_lib.rst`, `examples/packet_ordering/main.c` (prebuilt as `build/examples/dpdk-packet_ordering`).
- **API:**
  - `rte_reorder_create(name, socket, size)` or `rte_reorder_init`, where size is a power of 2
  - `rte_reorder_insert(b, m)`
  - `rte_reorder_drain(b, mbufs, max)`
  - `rte_reorder_drain_up_to_seqn`, `rte_reorder_min_seqn_set`, `rte_reorder_reset`, `rte_reorder_free`, `rte_reorder_find_existing`, `rte_reorder_memory_footprint_get`
  - The sequence number is read from the dynfield via `*rte_reorder_seqn(m)` (`rte_reorder_seqn_t` is uint32).
- **Internals:** two circular buffers.
  - The **Order** buffer, indexed by seq - min_seqn.
  - The **Ready** buffer.
- **Window rules** (`rte_reorder_insert`):
  - The first inserted mbuf initialises `min_seqn` (`is_initialized`).
  - `offset < size`: placed in the Order buffer.
  - `size <= offset < 2*size`: "early". It tries `rte_reorder_fill_overflow()` to move in-order entries to Ready and slide the window, skipping gaps that will later be "late". If Ready lacks room, it returns -1 with **ENOSPC**.
  - `offset >= 2*size` or late (negative offset, which wraps to huge): -1 with **ERANGE**. The caller must free or forward the mbuf.
- **Drain** returns Ready first, then Order until the first gap.
- *[measured, size 8]* Inserting 1,0,3,2,5,4,20,6:
  - 1 initialises the window.
  - 0 is rejected with ERANGE (late).
  - 20 is rejected with ERANGE (beyond 2x size).
  - Drain returns 1 2 3 4 5 6.
- **Not thread safe:** a single thread inserts and drains.
- **Sample** *[measured]*:
  ```
  dpdk-packet_ordering --no-huge -m 1024 --no-pci --file-prefix=chNNpo -l 0-3 --vdev=net_null0 --vdev=net_null1 -- -p 3
  ```
  - The roles are RX lcore, then workers, then a TX lcore with reorder. They are connected by `rx_to_workers` and `workers_to_tx` rings of 16384, with a 65535-mbuf pool.
  - In 8 s it reordered about 2.2 M packets. It prints stats on SIGINT.
  - The `--insight-worker` and `--disable-reorder` options are available.
  - Use `-m 1024` under no-huge because of the 4 KB-per-mbuf effect. With hugepages, `-m 256` would fit.

---

## 6. How they relate (the big picture diagram)

```
          rte_pktmbuf_pool_create()
                    |
         +----------v-----------+    per-lcore cache (LIFO of void*)
 NIC/PMD | rte_mempool "mb_pool" |<--> [lcore0 cache][lcore1 cache]...
 rx_burst|  ops: ring_mp_mc      |
  ------>|  backend: rte_ring    |    objects: [objhdr|rte_mbuf|priv|headroom|data]
         |  "MP_mb_pool"         |
         +----------------------+
 mbuf* --> rte_ring (worker queues, SP/SC/MP/MC/RTS/HTS) --> worker lcores
      --> rte_reorder (seqn dynfield) --> tx_burst --> rte_pktmbuf_free() -> refcnt-- -> cache -> ring
```

- The mempool's default backend *is* an `rte_ring`, named `MP_<pool>`. You can see it in testpmd's `dump ring` *[measured]*.
- Mbufs know their pool (`m->pool`), so free needs no pool argument.
- `net_ring` shows that an ethdev queue can literally be a ring.
- The reorder seqn and the timestamp are dynfields inside the mbuf.

## 7. Runnable example ideas that work on THIS machine

All use the build line `gcc x.c -o x $(pkg-config --cflags libdpdk) $(pkg-config --libs --static libdpdk)` and the run line `timeout -s INT -k 5 20 ./x --no-huge -m 128 --no-pci --file-prefix=chNN-x -l 0[-2] --log-level=lib.eal:warning`. The ready-made, verified sources are in `research/04-examples/`:

- `exp.c`: a tour of every mechanism with printed internals (offsets, capacity, cache len, clone and extbuf refcnts, dynfield map, ptype, stack, reorder). Its output is `out.txt`.
- `perf.c`: ring sync-mode and burst comparison, plus mempool cache on/off, on lcores 0-2. Its output is `perf.txt`.
- `dens.c`: bytes per mbuf, `--no-huge` versus `-m 64` hugepages.
- `ringeth.c`: `rte_eth_from_ring` loopback, showing the same pointers come back.

Further labs to write:

1. **Ring basics:** a producer lcore and consumer lcore passing integers cast to `void*`. Print `rte_ring_count`, `free_count`, and `rte_ring_dump`. Show bulk vs burst failure behaviour.
2. **Wrap-around:** create a ring of 8, loop enqueueing and dequeueing 1000 times, and dump head/tail to show they exceed 8 and the mask math. Also show the zc split (n1/ptr2).
3. **MPMC race visual:** 3 producer lcores (`-l 0-3`), each tagging objects with its lcore id. Have the consumer record order and count CAS retries (instrument with a copy of the move-head loop). This is optional because it needs 4 lcores, so keep it short.
4. **Overcommit lab:** run 4 pthreads registered via `rte_thread_register()` on `-l 0` with `taskset -c 0`, comparing MP/MC with RTS and HTS. It shows why RTS and HTS exist. Expect MP/MC to collapse.
5. **Peek and elem ring:** an HTS elem ring of `struct {uint32 flow; uint32 len;}` where the consumer peeks and only dequeues matching items.
6. **Mempool cache explorer:** print `cache->len` after each get/put (as in `exp.c`). An interactive cmdline version would let the HTML animation mirror real numbers.
7. **Handler bake-off:** the same workload with `ring_mp_mc`, `ring_sp_sc`, `stack`, `lf_stack`, `pile` and `bucket` (`rte_mempool_set_ops_byname`). Print cycles per object and the LIFO vs FIFO address reuse pattern (print the first 5 addresses returned after free).
8. **Stranded-cache pitfall:** a pool of 256 with cache 128 on 3 lcores, where each lcore takes and returns, then the main lcore tries to take all 256 and fails. Fix it with `rte_mempool_cache_flush` or by sizing.
9. **Mbuf anatomy:** alloc, then print the addresses of `m`, `rte_mbuf_to_priv(m)`, `buf_addr`, `mtod`, the end of `buf_len`. Then append, prepend, adj and trim with `rte_pktmbuf_dump(stdout,m,64)`.
10. **Build a real UDP packet** in an mbuf (`rte_ether_hdr`/`rte_ipv4_hdr`/`rte_udp_hdr`), send it via `net_tap0` (root; `ip link set dtap0 up`; `tcpdump -i dtap0`), or via `net_pcap` with `tx_pcap=/scratch/out.pcap` and inspect with tcpdump -r. Set `packet_type` with `rte_net_get_ptype`.
11. **Chained packet:** a header mbuf chained to a payload mbuf, then `rte_pktmbuf_read` across the boundary, then linearize. Send it over `net_pcap` (it supports multi-seg TX, since the pcap PMD gathers segments) and verify the pcap shows one packet.
12. **Multicast via clone:** one payload, 3 clones each with its own prepended header mbuf (the `examples/ipv4_multicast` pattern). Watch the refcnt go 1, 4, 1, 0 and the pool count.
13. **External buffer:** an `rte_malloc` or plain `malloc` region (for a non-IO demo) attached as extbuf with a `free_cb` printf.
14. **Dynfield:** register a "latency_tsc" field and an "is_sampled" flag. Stamp in an RX callback (`rte_eth_add_rx_callback` on net_null or net_ring) and read in the TX path. Print `rte_mbuf_dyn_dump`.
15. **Offload flags:** build a VXLAN packet and fill `l2_len`/`l3_len`/`outer_*` plus flags per the `mbuf_lib.rst` recipes. Validate with `rte_validate_tx_offload()`. Optionally TX on `net_tap` with checksum offload and see the correct checksum in tcpdump.
16. **testpmd tour** (no code):
    ```
    dpdk-testpmd --no-huge -m 256 --no-pci --file-prefix=chNN-tp -l 0-1 --vdev=net_ring0 -- -i --total-num-mbufs=2048 --mbcache=64
    ```
    with commands `dump mempool mb_pool_0`, `dump ring`, `dump struct_sizes`, `set fwd txonly`, `set txpkts 64,64` (multi-seg) and `show port stats all`. Drive it with `--cmdline-file=cmds.txt` (verified). Note that the command is `dump mempool <name>` with a space: `dump_mempool` does not exist.
    - Pool options: `--mp-alloc=native|anon|xmem|xmemhuge|xbuf` and `--mbuf-size=`.
17. **Stack:** std vs LF stack throughput with 2 lcores. Pop order demo.
18. **Reorder:** the deterministic insert sequence from `exp.c`, then `dpdk-packet_ordering` on net_null (with and without `--disable-reorder`).
19. **Multi-process:** `rte_ring_lookup` and `rte_mempool_lookup` from a secondary process. Both must use the same `--file-prefix`, and hugepages are needed (-m 64), because `--no-huge` does not support multi-process sharing. Optional, since it overlaps with the multi-process chapter.

## 8. Visualization and animation ideas

1. **Ring clock-face animation:** a circular buffer of 16 slots with 4 arrows (prod_head, prod_tail, cons_head, cons_tail). Step buttons follow the guide's 3-step SP enqueue, 3-step SC dequeue and 5-step 2-producer CAS race, highlighting "CAS failed, retry" and "waiting for tail". Show the local variables (prod_head, prod_next, free_entries) as per-core boxes above.
2. **Modulo-2^32 odometer:** the indexes shown as 32-bit counters spinning past 2^32-1 → 0, while `idx & mask` picks the slot. A live calculator for `entries = prod_tail - cons_head`.
3. **Sync-mode timeline (Gantt):** 3 threads, with one getting preempted mid-enqueue.
   - MP/MC: the others stall on the tail (red).
   - RTS: the others complete, and the last one moves the tail.
   - HTS: serialized lane.
   - Include a toggle "overcommit on/off" and a bar chart of the measured cycles per object (table in 1.6).
4. **Bulk vs burst:** a drag slider for n against free space. Bulk shows all-or-nothing (red X), burst fills partially.
5. **Zero-copy split:** a ring strip with the reserved region wrapping the end, labelled ptr1/n1 and ptr2/n-n1, and the NIC writing directly into the slots.
6. **Mempool cache animation:** per-lcore vertical stacks (size 256, half-line marker) above a shared ring "warehouse".
   - get pops from the top. When the stack is empty, a block of size/2 moves up from the ring.
   - put pushes. On overflow, the *bottom* half slides down to the ring and the hot top half moves down.
   - Drive it from the measured trace (127, 128, 56, 256, 0).
   - Include an "old algorithm (≤26.03): flushthresh 1.5x" comparison mode.
   - Add a counter of CAS operations saved, and the bar chart 86 vs 1.3 cycles per object.
7. **Memory map of a mempool:** horizontal pages (4K vs 2M) with objects `[hdr|mbuf|priv|headroom|data|trailer]`. The no-huge toggle shows one object per 4 KB page with wasted gaps (4096 vs 2370 bytes per object). Add a channel-spreading colouring of the object starts.
8. **Mbuf anatomy explorer:** two 64-byte cache lines with every field at its byte offset (table 3.3); hover for meaning. Shade "RX hot", "TX", and dynfield1 (free bytes per `rte_mbuf_dyn_dump`). Below it, the buffer bar with headroom, data and tailroom, plus buttons for append, prepend, adj and trim that move `data_off` and `data_len` live, with a NULL flash on prepend overflow.
9. **Chain view:** linked boxes (seg1 → seg2 → seg3) where only the head shows pkt_len, nb_segs and ol_flags. A `rte_pktmbuf_read` window slides across the segment boundary and copies into a temporary buffer.
10. **Refcnt and clone animation:** a direct mbuf with a refcnt badge; clones (small 128-byte boxes) attach with arrows to its buffer. Free them one by one and watch the badge count down, with the buffer returning to the pool at 0. A second variant shows extbuf with `shinfo->refcnt` and a `free_cb` firework.
11. **ol_flags bit-board:** 64 squares coloured RX, TX, internal (INDIRECT bit 62, EXTERNAL bit 61) or dynamic (allocated at 23, 24, ...). Clicking a VXLAN-TSO recipe lights the needed bits and fills the l2/l3/l4 length bitfields.
12. **Packet-type decoder:** a 32-bit value split into nibbles, mapped to names (`rte_get_ptype_name`), with a packet diagram highlighting each layer.
13. **Lock-free stack ABA:** a 3-thread step-through showing ABA corruption without a counter and its prevention with the {ptr, cnt} 128-bit CAS.
14. **Reorder window:** a sliding window over a sequence-number line, with Order and Ready buffers as two rows. Inserting packets (interactive or a scripted 1,0,3,2,5,4,20,6) colours them valid, early or late. Drain empties up to the first gap.
15. **System flow:** RX lcore, ring, workers, ring, TX with reorder (the packet_ordering sample). Packets as dots, with counters fed by the measured stats.

## 9. Common pitfalls (for "Gotchas" boxes)

**Ring pitfalls:**

- **Ring capacity is count-1** unless `RING_F_EXACT_SZ`. A non-power-of-2 count without that flag fails with EINVAL.
- **Bulk returns 0 for partial.** Check its return value, not just whether it is non-zero. The single-object enqueue returns 0 or a negative errno, so the conventions differ.
- **Using `sp_`/`sc_` or an ST ring from 2 threads** gives silent corruption. Default-mode calls follow the create flags. Explicit `mp_` calls on an SP ring are allowed and safe.
- **Peek and zc on MP/MC or RTS rings** assert or return 0. They need ST or HTS. Don't hold a `start` long: it blocks every other producer or consumer.
- **The elem ring esize must match** on every call, and must be a multiple of 4.
- **Non-EAL threads and default rings are fine**, but a preempted thread in MP/MC stalls everyone. Use RTS or HTS when overcommitted.

**Mempool pitfalls:**

- **Mempool N sizing:** the cache strands objects. Choose N ≥ (RX descriptors x queues) + (TX descriptors x queues) + nb_lcores x cache_size + burst x pipeline depth. Otherwise you get `rx_nombuf` or allocation failures.
- **`cache_size > n` is rejected** (EINVAL). In 26.11, sizes above 512 are allowed, but older DPDK rejected them. Courses using older DPDK must say so.
- **Non-EAL threads get no default cache.** `rte_mempool_default_cache()` returns NULL and every get/put hits the ring. Use `rte_mempool_cache_create()` with the generic API.
- **`--no-huge` memory blow-up:** about 4 KB per mbuf. Size `-m` accordingly, or use hugepages. Hugepage files persist in `/dev/hugepages/<prefix>map_*` after the process exits *[observed]*. Clean them up, or use `--huge-unlink` or `--in-memory`.

**Mbuf pitfalls:**

- **Double free / use after free:** after `tx_burst` accepts an mbuf, the driver owns it. Free only the *unsent* tail (`for i=nb_tx..n`). After `rte_pktmbuf_free`, never touch the mbuf. Enable `RTE_LIBRTE_MBUF_DEBUG` or mbuf history to catch this.
- **Writing into a clone** modifies the original's data, because they share the buffer. Use `rte_pktmbuf_copy` when you need private data. Indirect mbufs need `data_room_size=0` pools to save memory.
- **Metadata only in the first segment.** `data_len` and `pkt_len` must stay consistent. `pkt_len` is the sum of all segments' `data_len`.
- **`rte_pktmbuf_mtod` with no bounds checks:** prepend and append return NULL on overflow, so check them. Headers spanning segments need `rte_pktmbuf_read`.
- **Raw APIs** (`rte_mbuf_raw_free`) require the invariant refcnt=1, next=NULL, nb_segs=1, and a direct mbuf.
- **Offload flags without capability:** setting `RTE_MBUF_F_TX_*_CKSUM` on a port without `RTE_ETH_TX_OFFLOAD_*` enabled sends wrong checksums. You must also prepare the pseudo-header checksum.
- **Dynfield offsets are runtime values.** Look them up by name in each process. Don't hardcode them, and there is no unregistering. A hard limit of 36 bytes in `dynfield1` (plus `dynfield2` if IOVA is not in the mbuf) is shared by all PMDs and libraries.
- **Evaluation order in C:** `printf("%d %u", rte_pktmbuf_linearize(m), m->nb_segs)` printed a stale nb_segs in our first test. Sequence side-effecting calls explicitly. This is a teaching aside for the examples.

**Reorder pitfalls:**

- **Reorder late and early errors:** handle -1 (ERANGE/ENOSPC) by freeing or transmitting the mbuf, or it leaks. The first insert sets the window base, so call `rte_reorder_min_seqn_set()` if you need a fixed start.

**Other:**

- **ABA and 128-bit CAS:** the LF stack needs `cmpxchg16b`. The 4-core Xeon has it.

## 10. Suggested chapter breakdown (for the planner)

**Chapter A: "Rings: lock-free queues"**

- Concept and API (bulk/burst/single).
- Internals animation and modulo math.
- Sync modes and the measured perf table.
- The overcommit lab.
- Peek, zero-copy and elem rings.
- SORING overview.
- The ring PMD loopback demo.

**Chapter B: "Mempools: fixed-size allocation at line rate"**

- Create and populate.
- Object layout: hdr/trailer, page boundaries, the no-huge 4 KB effect, channel spreading.
- Per-lcore cache: the 26.11 algorithm with an animation driven by the measured trace, and the 65x perf demo.
- Stranded objects and sizing.
- User caches for non-EAL threads.
- Ops and handlers with a bake-off (ring/stack/lf_stack/pile/bucket); writing a custom handler (a simple "array + spinlock" ops with `RTE_MEMPOOL_REGISTER_OPS`).
- Telemetry and dump.

**Chapter C: "Mbufs: the packet"**

- Layout (two cache lines).
- pktmbuf pool.
- Data manipulation.
- Building a packet and sending it on tap or pcap.
- Chains.
- Refcnt, clone, copy and extbuf.
- ol_flags and ptype.
- Dynfields and dynflags.
- Debugging and history.

**Optional chapter D, or a tail section of C: "rte_stack & rte_reorder"**

- Lock-free stack, ABA and pile.
- Reorder window plus `dpdk-packet_ordering`.

**Prerequisites:** EAL and lcores (ch 02), memory, hugepages and memzones (ch 03).

**Later dependency:** every ethdev and forwarding chapter uses mbufs and pools.

## 11. Source references

**DPDK tree** (`$DPDK_SRC`):

- **Guides:**
  - `doc/guides/prog_guide/{ring_lib,mempool_lib,mbuf_lib,stack_lib,reorder_lib}.rst`
  - Images in `doc/guides/prog_guide/img/` (ring*.svg, mempool.svg, mbuf1/2.svg, memory-management*.svg, soring-pic1.svg). These are useful references for redrawing.
- **Release notes:**
  - `doc/guides/rel_notes/release_20_05.rst` (RTS/HTS, peek)
  - `release_20_11.rst` (ring zero-copy)
  - `release_20_02.rst` (custom element size)
  - `release_19_05.rst` (stack library, lf_stack handler)
  - `release_19_11.rst` (dynamic mbuf fields)
  - `release_21_11.rst` (PKT_ → RTE_MBUF_F_)
  - `release_18_05.rst` (bucket)
  - `release_25_03.rst` (SORING)
  - `release_25_11.rst` (mbuf history)
  - `release_26_07.rst` (SORING peek)
  - `release_26_11.rst` (pile; mempool cache: flushthresh removed, cache size no longer capped by `RTE_MEMPOOL_CACHE_MAX_SIZE`, `sizeof_cache_per_lcore`)
- **Code:** `lib/ring/*`, `lib/mempool/*`, `lib/mbuf/*`, `lib/stack/*`, `lib/reorder/*`, `drivers/mempool/{ring,stack,bucket}`, `drivers/net/ring/rte_eth_ring.c`, `config/rte_config.h`, `build/rte_build_config.h` (`RTE_PKTMBUF_HEADROOM 128`).
- **Tests:** `app/test/test_ring.c`, `test_ring_perf.c`, `test_ring_*_stress.c`, `test_mempool.c`, `test_mempool_perf.c`, `test_mbuf.c`, `test_stack.c`, `test_stack_perf.c`, `test_reorder.c`, `test_soring*.c`. The `dpdk-test` binary is not built here, but the sources are excellent reading.
- **Samples:** `examples/packet_ordering`, `examples/ipv4_multicast`, `examples/ip_fragmentation`, `examples/ip_reassembly`, `examples/multi_process/client_server_mp` (rings between processes), `examples/distributor`. testpmd is in `app/test-pmd/{txonly.c,csumonly.c,cmdline.c}`.

**Web:**

- Ring sync modes RFC (Ananyev, 2020): https://lore.kernel.org/all/20200224113529.4c1c94ab@hermes.lan/T/ and https://patchwork.dpdk.org/cover/67696/
- Ring sync modes design discussion: https://inbox.dpdk.org/BYAPR11MB2549DE36A58E0552168D4C819ACF0@BYAPR11MB2549.namprd11.prod.outlook.com/
- Mempool cache rework (Brørup, 2026): https://mails.dpdk.org/archives/dev/2026-May/338302.html and https://mails.dpdk.org/archives/dev/2026-July/341982.html
- Earlier cache work: https://patches.dpdk.org/comment/165562/
- Mbuf struct history: https://doc.dpdk.org/struct/mbuf/history.html
- FreeBSD buf_ring (origin of rte_ring): http://svn.freebsd.org/viewvc/base/release/8.0.0/sys/sys/buf_ring.h
- Linux lockless ring buffer design: http://lwn.net/Articles/340400/

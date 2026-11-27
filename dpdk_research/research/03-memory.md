# Research note 03: DPDK memory

Scope: hugepages, hugetlbfs and memfd, memory types and memseg lists, memsegs, fbarray, memzones, the
`rte_malloc` heap (internals), NUMA and sockets, IOVA (PA/VA/DC) and physical addressing, `--no-huge` and
`--in-memory`, legacy and dynamic memory, memory event and validator callbacks, external memory (heaps and
`rte_extmem_*`), alignment and cache lines, false sharing, `RTE_CACHE_GUARD`, lcore variables (only as the
memory-layout angle), prefetching, TLB effects, and memory channels.

Version: DPDK **26.11.0**. `$DPDK_SRC` = `.../scratchpad/clone/dpdk`. Claims were checked against the source.
**[verified]** means it was run on this machine: 4 vCPU KVM Xeon, **1 NUMA node**, **no IOMMU groups**
(`/sys/kernel/iommu_groups` is empty), root, Linux 6.18, 1024 x 2 MB hugepages mounted at `/dev/hugepages`
(other jobs share them), no 1 GB pages reserved, THP=`madvise`, `ulimit -l` = 8192 KB.

Runnable sources for the experiments are in `research/03-memory-examples/`:
- `memexp.c`: memseg-list, memseg, memzone, malloc, IOVA, external heap, and mem-event walk-through
- `fshare.c`: false-sharing benchmark, plus a random-gather prefetch and TLB benchmark
- `mzshare.c`: a primary process reserves a memzone and a secondary process looks it up

Build any of them with
`gcc -O2 x.c -o x $(pkg-config --cflags libdpdk) $(pkg-config --libs --static libdpdk)` after you source
`dpdk-env.sh`.

---

## 0. Things that changed recently (older tutorials get these wrong)

| Change | Where / when | Teaching consequence |
|---|---|---|
| **Dynamic memory (memory hotplug)** is the default. Legacy mode needs `--legacy-mem`. | 18.05 (Anatoly Burakov's rework) | Pre-18.05 tutorials say "DPDK grabs all hugepages at start". That is now only true with `--legacy-mem` (and on FreeBSD). |
| **One memseg list per memory type** (page size x NUMA node). All lists are carved out of **one** VA reservation stored in `mcfg->mem_va_addr/mem_va_len/mem_va_page_sz`. | `lib/eal/common/eal_common_dynmem.c:21` (`eal_dynmem_memseg_lists_init`). `RTE_MAX_MEMSEG_PER_LIST` and `RTE_MAX_MEM_MB_PER_LIST` no longer exist. | Older material shows "4 lists of 8192 segs / 32 GB each per type". On 26.11 **[verified]** there is one 2 MB list, 32768 segs, 64 GB of VA. |
| `--numa-mem` / `--numa-limit` replace `--socket-mem` / `--socket-limit`. The old names are still aliases. | `lib/eal/common/eal_option_list.h:88-91` | Use the new names. |
| `--pagesz-mem <pgsz>:<limit>` overrides `RTE_MAX_MEM_MB_PER_TYPE` per page size. | 26.07 release notes | It is a VA limit (the most memory of that page size), not a preallocation. |
| `--huge-unlink[=existing|always|never]`. `never` reuses "dirty" hugepages (`RTE_MEMSEG_FLAG_DIRTY`). | 22.03 | Restart is faster. Security caveat: old data is left in the pages. |
| `rte_memzero_explicit`, `rte_free_sensitive`, `rte_memeq_timingsafe` | 25.07 (experimental) | Short side note for crypto key material |
| `rte_memzone_max_set/get` (the default 2560 memzones can be changed before init) | 23.x | `lib/eal/common/eal_common_memzone.c:27` |
| Lcore variables (`rte_lcore_var.h`) replace `RTE_MAX_LCORE` arrays padded with `__rte_cache_aligned` + `RTE_CACHE_GUARD` | 24.11 (experimental) | Teach false sharing first, then the guard, then lcore vars. |
| `rte_smp_mb/rmb/wmb` were removed and replaced by `rte_atomic_thread_fence(...)` | 26.11 release notes | Matters if the chapter shows memory barriers next to cache-line examples. |
| `RTE_IOVA_IN_MBUF` (meson `enable_iova_as_pa`, default true) | 22.11 | If you build with `-Denable_iova_as_pa=false`, the mbuf loses `buf_iova` and only VA mode is possible. |

---

## 1. Concept map (what sits on top of what)

```
 Kernel: hugetlbfs files (/dev/hugepages/<prefix>map_<list>_<seg>) | memfd (--in-memory) | anon mmap (--no-huge)
   │  mmap(MAP_SHARED|MAP_POPULATE|MAP_FIXED) into pre-reserved VA
   ▼
 rte_memseg  (ONE page: va, iova, len, hugepage_sz, socket_id, flags)       lib/eal/include/rte_memory.h:49
   │  stored in an rte_fbarray (shared-memory backed, file /run/dpdk/<prefix>/fbarray_memseg-2048k-0-0)
   ▼
 rte_memseg_list (one per {page size, NUMA node}; base_va, page_sz, socket_id, len, external, heap, version)
   │  mcfg->memsegs[RTE_MAX_MEMSEG_LISTS=128]                              lib/eal/common/eal_memcfg.h
   ▼
 malloc_heap (one per NUMA node + up to RTE_MAX_HEAPS=32 total incl. external) — free lists of malloc_elem
   │  lib/eal/common/malloc_heap.{c,h}, malloc_elem.{c,h}
   ├──► rte_malloc / rte_zmalloc / rte_calloc / rte_realloc (+ _socket)      lib/eal/include/rte_malloc.h
   └──► rte_memzone_reserve*(): a named heap allocation + descriptor in fbarray "memzone"
            │                                                               lib/eal/common/eal_common_memzone.c
            ▼
        rte_ring_create, rte_mempool_create (→ rte_pktmbuf_pool_create), hash, LPM, ethdev data, PMD rings ...
```

Main idea for students: **a memseg is a page. A memseg list is a VA window for one page type. The heap
turns those pages into allocations of any size. A memzone is a named heap allocation that has a descriptor.
Mempools, rings and the rest are built on memzones and malloc.**

---

## 2. Recommended teaching order (easy to hard)

1. **Why DPDK memory is special**: TLB reach (4 KB x 1536 entries ≈ 6 MB, against 2 MB x 1536 ≈ 3 GB),
   no page faults or swapping on the fast path, pinned memory for DMA, and sharing memory between processes.
   Measured demo (§11).
2. **Hugepages on Linux**: `/proc/meminfo`, `/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages`, the
   hugetlbfs mount, `usertools/dpdk-hugepages.py -s`, 2 MB against 1 GB pages, and per-node reservation in
   `/sys/devices/system/node/nodeN/hugepages/`.
3. **EAL memory options** used in practice: `--no-huge`, `-m`, `--numa-mem`, `--in-memory`, `--file-prefix`,
   `--huge-dir`, `--single-file-segments`. Teach this at the same time as the "see the files" demo (§12.2).
4. **Allocate something**: `rte_malloc`, `rte_zmalloc`, `rte_free`, alignment, `rte_malloc_dump_stats`, and
   `rte_malloc_get_socket_stats`.
5. **Memzones**: named, shareable, aligned, bounded, IOVA-contiguous on request. Lookup by name.
6. **Memsegs and memseg lists**: walk them. Show the 64 GB VA reservation compared with the pages actually
   mapped.
7. **IOVA**: PA compared with VA, `rte_mem_virt2iova`, `rte_mem_virt2phy`, why NICs need IOVAs, how EAL
   detects the mode, and the **IOVA-contig failure demo** (§12.4). This is the best "aha" moment of the
   chapter.
8. **NUMA and sockets**: `socket_id`, `SOCKET_ID_ANY`, `rte_socket_id()`, `rte_lcore_to_socket_id`, and
   `rte_eth_dev_socket_id`. Local placement of mempools and rings. Only one node exists here, so this part
   uses visualization and theory.
9. **Dynamic memory compared with legacy**: heap growth and shrinking, `DO_NOT_FREE` pinned pages, mem-event
   callbacks, validators, `--numa-limit`, and `--match-allocations`.
10. **Malloc heap internals**: `malloc_elem` header, 13 size-class free lists, split and merge, pad elements,
    best-fit, page release, `alloc_more_mem_on_socket`, and the primary-owns-the-map rule.
11. **Multi-process view of memory**: the same VA in every process, `/run/dpdk/<prefix>/config`, fbarrays,
    `--base-virtaddr`, and the ways a secondary can fail. (The multi-process chapter covers this in depth.)
12. **External memory**: `rte_malloc_heap_create` + `rte_malloc_heap_memory_add` + `rte_malloc_heap_get_socket`
    compared with `rte_extmem_register` + `rte_dev_dma_map`. Also testpmd `--mp-alloc=xmem|xmemhuge`.
13. **CPU-cache-level memory**: cache lines, `__rte_cache_aligned`, `RTE_CACHE_LINE_ROUNDUP`, false sharing,
    `RTE_CACHE_GUARD`, lcore variables, prefetch (`rte_prefetch0/1/2/_non_temporal`, `_write`), and memory
    channels and ranks (`-n`, `-r`, and how mempool spreads objects across them).
14. **Expert topics**: `--huge-unlink=never` and dirty memory, `--huge-worker-stack`, DMA mask
    (`rte_mem_check_dma_mask`), `rte_memseg_get_fd*` (vhost-user), `--legacy-mem` contiguity sorting, 32-bit
    limits, ASan (`RTE_MALLOC_ASAN`), and `RTE_MALLOC_DEBUG` cookies.

A possible split into chapters: (a) "Hugepages & EAL memory model" (1-3, 6), (b) "rte_malloc, memzones &
the heap" (4, 5, 9, 10, 12), (c) "IOVA, DMA & NUMA" (7, 8, 11), (d) "Cache-aware data layout" (13) for the
performance part of the course.

---

## 3. Hugepages and how EAL maps them

### 3.1 Why hugepages
- **TLB reach**: every 4 KB page needs one TLB entry. Packet buffers (tens to hundreds of MB) cause constant
  page walks with 4 KB pages. 2 MB or 1 GB pages cut the number of entries by 512x or 262144x.
- **Pinned**: hugetlbfs pages are never swapped, and their physical address does not change. That is
  needed for DMA in PA mode.
- **Shareable**: hugetlbfs files can be mapped by secondary processes at the same VA.
- **Pre-zeroed by the kernel** the first time they are mapped. The allocator relies on this, so `rte_zmalloc`
  can skip memset for memory that is not dirty.

### 3.2 Linux mapping methods (`env_abstraction_layer.rst` "Hugepage Mapping"; `lib/eal/linux/eal_memalloc.c`)
- **Default**: one file per page in hugetlbfs, named `<prefix>map_<list>_<seg>` (the default prefix is
  `rte`, which gives `rtemap_0_3`). **[verified]** `--file-prefix=ch03mem` gave
  `/dev/hugepages/ch03memmap_0_0..3`. Every file is opened and kept locked (fcntl lock) while it is in use,
  so the `NOFILE` limit can be exhausted.
- `--single-file-segments`: one file per memseg list. `fallocate` grows and punches holes in it
  (`resize_hugefile_in_filesystem`). **[verified]** one file of 14 MB, `ch03memmap_0`.
- `--in-memory`: anonymous **memfd** hugepages (`memfd_create(..., MFD_HUGETLB|...)`). No files in
  hugetlbfs, no `/run/dpdk` config (it implies `--no-shconf` and `--huge-unlink`), and no multi-process.
  **[verified]** `/proc/PID/maps` shows `/memfd:seg_1-0 (deleted)`. Because memfd can create 1 GB pages
  on demand, EAL also made a **1 GB memseg list** even though no 1 GB pages were reserved
  ("No free 1048576 kB hugepages reported on node 0", a harmless notice). That is why the 2 MB list
  started at `0x1140000000`, after the 64 GB VA of the 1 GB list.
- `--no-huge`: plain 4 KB pages from `memfd_create("nohuge")` + mmap, or MAP_ANONYMOUS
  (`lib/eal/linux/eal_memory.c:1159`). One memseg list called `nohugemem`, `-m` MB in size (default 64 MB),
  with **every 4 KB page as its own memseg** (**[verified]** 16384 segs for 64 MB). IOVA = VA, there is no
  PA, and there is no secondary support. Shared config files are still created unless `--in-memory` or
  `--no-shconf` is used. **[verified]** a secondary that attaches to a `--no-huge` primary fails with
  "Failed to open shared memory!".
- `--huge-unlink` / `=always`: unlink after mapping, so nothing is left behind. `=never`: keep the files and
  remap them dirty at restart (more than 95% of mapping time is clearing pages).
- `--huge-dir`: pick a mount point or subdirectory, for example a 1 GB mount.

### 3.3 Allocating one page (`alloc_seg`, `lib/eal/linux/eal_memalloc.c:501`)
Teach these steps as an animation:
1. `get_seg_fd()` opens or creates the hugepage file (or memfd) and takes a read lock.
2. `ftruncate` (or `fallocate` for single-file).
3. `mmap(addr, pgsz, RW, MAP_SHARED|MAP_POPULATE|MAP_FIXED, fd, off)` at the **pre-reserved VA slot** of
   that memseg index.
4. Install a SIGBUS handler with sigsetjmp. hugetlb cgroup limits are enforced at fault time, and the
   handler stops the process from being killed.
5. Touch the page with `rte_atomic_fetch_or(addr, 0)`. This forces the fault without changing the contents.
6. `iova = rte_mem_virt2iova(addr)`. In PA mode this reads `/proc/self/pagemap`.
7. NUMA check: `get_mempolicy(MPOL_F_NODE|MPOL_F_ADDR)` must equal the requested socket. Before the mmap,
   EAL had set `set_mempolicy(MPOL_PREFERRED, socket)` (`prepare_numa`).
8. Fill in the `rte_memseg` fields (`addr, iova, len, hugepage_sz, socket_id, nchannel, nrank, flags`).
   On failure, munmap and **re-reserve the hole** with `eal_get_virtual_area(..., EAL_RESERVE_FORCE_ADDRESS)`
   so no other code can map into the DPDK window.

---

## 4. Memory types, VA reservation, memseg lists, memsegs, fbarray

- **Memory type** = (page size, NUMA node). `n_memtypes = num_hugepage_sizes * rte_socket_count()`, and it
  must be at most `RTE_MAX_MEMSEG_LISTS` (128). (`eal_common_dynmem.c:60`)
- Each type gets **one** `rte_memseg_list` with `n_segs = limit / pagesz`, where the limit is
  `RTE_MAX_MEM_MB_PER_TYPE` (65536 MB) or the `--pagesz-mem` value. `RTE_MAX_MEMSEG_PER_TYPE` = 32768
  (`config/rte_config.h:45-47`).
- **All lists share one VA reservation** (`eal_get_virtual_area(NULL, &mem_va_len, mem_va_page_sz, 0, 0)`).
  It is mapped PROT_NONE. **[verified]** `/proc/PID/maps` shows `140000000-1140000000 ---p` (64 GB, 1 GB
  list) in `--in-memory` mode. The fbarrays are created *before* the VA reservation, so the space after the
  VA window stays free. PCI BAR mapping uses the end of the window as its hint.
- The default base VA on 64-bit is `0x100000000` (4 GB). **[verified]** The config is at
  `0x100000000`, `fbarray_memzone` at `0x100007000`, `fbarray_memseg-2048k-0-0` at `0x100035000`, and the
  first hugepage at `0x100200000`. `--base-virtaddr` moves this.
- "Preallocated **VA** is not preallocated **memory**". Only pages that are actually allocated get mapped.
  `rte_eal_get_physmem_size()` reports mapped memory: **[verified]** 2 MB with no `-m`, 64 MB with `-m 64`.
- `struct rte_memseg` (`rte_memory.h:49`): `iova, addr, len, hugepage_sz, socket_id, nchannel, nrank, flags`.
  Flags are `RTE_MEMSEG_FLAG_DO_NOT_FREE` (bit 0, pages preallocated with `-m`/`--numa-mem` are pinned and
  never released) and `RTE_MEMSEG_FLAG_DIRTY` (bit 1). **[verified]** With `-m 64`, every seg has
  `flags=1`. With no `-m`, `flags=0`.
- `struct rte_memseg_list` (`rte_memory.h:67`): `base_va, page_sz, socket_id, version` (multi-process sync),
  `len, external, heap, memseg_arr` (an `rte_fbarray`).
- **rte_fbarray** (`lib/eal/include/rte_fbarray.h`, `eal_common_fbarray.c`): a fixed-size array of
  elements plus a used/free bitmask. It lives in a file-backed shared mapping
  (`/run/dpdk/<prefix>/fbarray_*`), so secondary processes see the same table. Its API includes
  `rte_fbarray_find_next_used` and `find_contig_used`. Memzone descriptors also live in an fbarray
  (`mcfg->memzones`).
- **Walk APIs** (`rte_memory.h`):
  - `rte_memseg_list_walk`
  - `rte_memseg_walk`
  - `rte_memseg_contig_walk`: walks **VA**-contiguous runs of used segs. It does **not** mean
    IOVA-contiguous. **[verified]** In PA mode it reported one 64 MB chunk whose pages had scattered IOVAs.
  - `*_thread_unsafe` variants: use these inside memory callbacks, because the normal walks take the
    hotplug read lock.
- Lookup: `rte_mem_virt2memseg(va, msl)`, `rte_mem_virt2memseg_list(va)`, `rte_mem_iova2virt(iova)`, and
  `rte_memseg_get_fd*` (vhost-user passes these fds to QEMU and other peers).
- Debug: `rte_dump_physmem_layout(f)`, telemetry `/eal/memseg_lists`, `/eal/memseg_list_info,<msl>`, and
  `/eal/memseg_info,<msl>,<seg>`.

---

## 5. Memzones (`lib/eal/include/rte_memzone.h`, `lib/eal/common/eal_common_memzone.c`)

- `struct rte_memzone`: `name[32], iova, addr, len, hugepage_sz, socket_id, flags`. The descriptor is
  read-only to the user, and it is in shared memory so every process can see it.
- `rte_memzone_reserve(name, len, socket, flags)`, `_aligned(..., align)` (power of 2, at least the
  cache line size), and `_bounded(..., align, bound)` (the zone must not cross a `bound` boundary, for
  example a 4 GB DMA window). `len=0` reserves the **biggest** available zone, but it never triggers new
  page allocation.
- Flags: page-size requests `RTE_MEMZONE_2MB`, `_1GB`, `_16MB`, `_256KB`, `_256MB`, `_512MB`, `_4GB`,
  `_16GB`; `RTE_MEMZONE_SIZE_HINT_ONLY` (fall back to other sizes); `RTE_MEMZONE_IOVA_CONTIG` (for hardware
  rings and descriptors).
- Implementation: `memzone_reserve_aligned_thread_unsafe` takes `mcfg->mlock` for writing, checks that the
  name is unique (`EEXIST`) and that there is a free slot (`ENOSPC`, default 2560 =
  `DEFAULT_MAX_MEMZONE_COUNT`, adjustable with `rte_memzone_max_set()` before init), then calls
  `malloc_heap_alloc(len, socket, flags, align, bound, contig)`. It fills the descriptor from the
  `malloc_elem` (`mz->hugepage_sz = elem->msl->page_sz` etc.). **A memzone is just a heap element with a
  name.**
- `rte_memzone_lookup(name)`, `rte_memzone_free(mz)`, `rte_memzone_walk(fn, arg)`, and
  `rte_memzone_dump(f)`. Telemetry: `/eal/memzone_list` and `/eal/memzone_info,<id>`.
- **[verified]** testpmd with net_null had 7 memzones. Zone 0 was `rte_eth_dev_data` (196672 B).
- **[verified]** In `mzshare.c`, the primary reserves `shared_cfg` and the secondary
  (`--proc-type=secondary`, same `--file-prefix`) looks it up by name and gets **the same VA**
  (`0x1011fcf80`) and the same content.
- Errors are reported through `rte_errno`: `ENOSPC, EEXIST, ENOMEM, EINVAL, E_RTE_NO_CONFIG`.

---

## 6. rte_malloc and the malloc heap

### 6.1 API (`lib/eal/include/rte_malloc.h`)
- `rte_malloc(type, size, align)`, `rte_zmalloc`, `rte_calloc`, `rte_realloc`, plus `_socket` variants that
  take an explicit `socket` argument. `type` is ignored (it is kept for compatibility, so pass NULL or a
  label). `align=0` means cache-line alignment, and a non-zero value must be a power of two.
- `rte_free`, `rte_free_sensitive` (zeroes the memory, experimental), and `rte_malloc_validate(ptr, &size)`
  (returns the usable size). **[verified]** `rte_malloc(100)` gives a usable size of 128, rounded up to the
  cache line.
- Stats: `rte_malloc_get_socket_stats(socket, &stats)` returns `heap_totalsz_bytes`, `heap_freesz_bytes`,
  `greatest_free_size`, `free_count`, `alloc_count`, `heap_allocsz_bytes`. Also `rte_malloc_dump_stats`,
  `rte_malloc_dump_heaps`, and telemetry `/eal/heap_list` and `/eal/heap_info,<id>`.
- `rte_malloc_virt2iova(ptr)`.
- `rte_malloc` is **not for the data plane**: it takes a heap spinlock and walks lists. Use mempools on the
  fast path (`writing_efficient_code.rst`).

### 6.2 Data structures
- `struct malloc_heap` (`malloc_heap.h`, cache-aligned): `rte_spinlock_t lock;
  LIST_HEAD free_head[RTE_HEAP_NUM_FREELISTS=13]; first; last; alloc_count; socket_id; total_size;
  name[32]`. The heaps live in `mcfg->malloc_heaps[RTE_MAX_HEAPS=32]` and are named `socket_0`, `socket_1`
  and so on. External heaps get socket ids starting at `EXTERNAL_HEAP_MIN_SOCKET_ID =
  max(256, RTE_MAX_NUMA_NODES)`. **[verified]** The first external heap had socket_id 256.
- `struct malloc_elem` (`malloc_elem.h`, cache-aligned, so the header is 64 B and sits in the cache line
  **just before** the user pointer): `heap, prev, next` (a list of neighbours in address order),
  `free_list` (LIST_ENTRY), `msl`, `state:3` (`ELEM_FREE`/`ELEM_BUSY`/`ELEM_PAD`), `dirty:1`, `pad`,
  `size` (includes the header), `orig_elem`, `orig_size` (the original element of memory that was added,
  used to decide which pages can be freed). `RTE_MALLOC_DEBUG` adds header and trailer cookies
  `0xbadbadbadadd2e55`. `RTE_MALLOC_ASAN` adds `user_size` and shadow-memory marking.
- **Free-list index** (`malloc_elem_free_list_index`): size classes go up in powers of 4, starting at 256 B.
  Bucket 0 is below 2^8. Bucket k holds sizes in roughly (2^(8+2(k-1)), 2^(8+2k)]. The last bucket (12) is
  for everything bigger. A search starts at the request's bucket and moves upward.
- `MIN_DATA_SIZE` = 64. A split happens only if the remaining piece is at least
  `MALLOC_ELEM_OVERHEAD + MIN_DATA_SIZE` (header + 64 = 128 B without debug, which matches the "128 bytes"
  in the programmer's guide).

### 6.3 Allocation path (`malloc_heap.c`)
1. `malloc_heap_alloc(size, socket_arg, flags, align, bound, contig)` checks that the size is non-zero and
   the alignment is a power of two. With `--no-huge`, a request for any native socket becomes `SOCKET_ID_ANY`.
2. `SOCKET_ID_ANY` resolves to `malloc_get_numa_socket()`: the caller's `rte_socket_id()`. A control or
   non-EAL thread gets the first socket with `numa_mem` configured, otherwise the main lcore's socket,
   otherwise the first socket.
3. `malloc_heap_alloc_on_heap_id` locks the heap, then `heap_alloc()` calls `find_suitable_element()`
   (scans the free lists from the right bucket and checks size, alignment, boundary, page-size flags and,
   if `contig`, that the element is IOVA-contiguous through `elem_check_phys_contig`). Then
   `malloc_elem_alloc()` **allocates from the end of the free element**. That way the free element stays on
   its list with a smaller size, which is cheap. Head padding is turned into an `ELEM_PAD` header if it is
   too small to split.
4. If nothing fits, `alloc_more_mem_on_socket()` runs. It collects the memseg lists on that socket, sorts
   them by page size (smallest first), and tries the requested page sizes first. With `SIZE_HINT_ONLY` it
   then tries the other sizes. The call chain is `try_expand_heap` → `try_expand_heap_primary` →
   `alloc_pages_on_heap` → `eal_memalloc_alloc_seg_bulk` (maps N pages) → `malloc_heap_add_memory` →
   retry. If `contig` is set and the new pages are not IOVA-contiguous, the pages are rolled back
   (`rollback_expand_heap`). Then it **notifies the mem-event callbacks** (`RTE_MEM_EVENT_ALLOC`) and syncs
   secondaries over IPC (`request_sync()`).
5. `SOCKET_ID_ANY` falls back to other native sockets. An explicit socket does **not** fall back, so the
   call fails with NULL.
6. Secondary processes cannot map pages themselves. `try_expand_heap_secondary` sends a request to the
   primary over IPC (`malloc_mp.c`). If the primary is gone, no memory can be added.

### 6.4 Free path
`rte_free` → `malloc_elem_from_data` (the pointer minus 64 B, then follow `pad` if the header is PAD) →
`malloc_heap_free`. It merges with free **adjacent** neighbours (`malloc_elem_join_adjacent_free`), so two
free elements are never next to each other. If the free element now covers whole pages that were not
preallocated (`DO_NOT_FREE`), those pages are removed from the heap and unmapped (`malloc_heap_free_pages`,
`eal_memalloc_free_seg_bulk`), and `RTE_MEM_EVENT_FREE` callbacks fire. The pages are only cut along
`orig_elem` boundaries when `--match-allocations` is used.

**[verified] growth and shrink trace** (`memexp`, no `-m`, PA mode): init mapped one 2 MB page. A 3 MB
IOVA_CONTIG memzone failed. `rte_zmalloc(5 MB)` gave `[mem event] ALLOC addr=0x100400000 len=6144K`, and at
the end `FREE ... 6144K`, then the initial 2 MB page was freed during cleanup. With `-m 64`, no ALLOC events
appear for allocations under 64 MB, and the pages carry `flags=1`.

**[verified]** testpmd with `-m 128` and one null port (n=155456 mbufs, 2368 B each) grew the heap to
**480 MB** (`/eal/heap_info,0` → Heap_size 503316480, Alloc_count 682). That is far more than `-m`.
`-m` is a *floor* (pinned preallocation), not a cap. Use `--numa-limit` for a cap. Warn students that
testpmd's default pool is large, and set `--total-num-mbufs` on shared machines.

---

## 7. Dynamic compared with legacy memory, callbacks and limits

| | Dynamic (default) | Legacy (`--legacy-mem`) |
|---|---|---|
| Pages at startup | only `-m` / `--numa-mem` (pinned); otherwise almost none | all requested (all available pages if no `-m`) |
| Grow and shrink at runtime | yes | no |
| IOVA contiguity | not guaranteed; ask with `RTE_MEMZONE_IOVA_CONTIG` | pages are **sorted by PA** into contiguous runs, with VA holes between runs |
| Mem event callbacks | `rte_mem_event_callback_register(name, cb, arg)` | **not supported** (`ENOTSUP`) **[verified]** |
| `--single-file-segments` | allowed | not allowed |

**[verified] legacy contiguity**: `--legacy-mem -m 32` gave six VA-contiguous chunks (4 MB × 5 + 12 MB) with
VA gaps between them. In each chunk the IOVAs are consecutive. Compare that with dynamic `-m 64`, which gave
one 64 MB VA chunk whose pages had scattered IOVAs. **This contrast makes a strong diagram.**

- Validators: `rte_mem_alloc_validator_register(name, clb, socket_id, limit)`. The callback is called when
  an allocation would push the socket above `limit`, and it can return -1 to deny it. The `--numa-limit`
  option installs a default validator.
- `--match-allocations`: pages are freed exactly as they were allocated (Linux only, not legacy or no-huge).
  Some drivers need this (historically Mellanox mlx5 with its MR cache).
- Warning (`env_abstraction_layer.rst`): do **not** allocate, free or use IPC inside memory callbacks.
  The `*_thread_unsafe` walk variants exist for use inside them.
- 32-bit: 2 GB of VA by default, all on the main lcore's node.

---

## 8. IOVA, physical addresses and DMA

- `rte_iova_t` is the address a **device** uses for DMA. Its value is either the physical address (PA) or,
  behind an IOMMU, the process VA (VA mode). The PA case is also how no-IOMMU VFIO and UIO
  (igb_uio/uio_pci_generic) work.
- APIs:
  - `rte_eal_iova_mode()` returns `RTE_IOVA_PA`, `RTE_IOVA_VA` or `RTE_IOVA_DC` (`rte_eal.h`)
  - `rte_mem_virt2iova(va)`
  - `rte_mem_virt2phy(va)`: reads `/proc/self/pagemap`, `PFN_MASK_SIZE=8`, and needs `CAP_SYS_ADMIN`.
    It returns `RTE_BAD_PHYS_ADDR` when unavailable.
  - `rte_malloc_virt2iova`
  - `rte_eal_using_phys_addrs()`
  - `mbuf->buf_iova` and `rte_pktmbuf_iova()`
- Detection (`env_abstraction_layer.rst` "IOVA Mode Detection"; `lib/eal/linux/eal.c`): each bus reports a
  preference. If every bus is DC, EAL uses VA when there are no physical addresses or
  `/sys/kernel/iommu_groups` is not empty, and PA otherwise. If the result is PA but PA cannot be read
  (non-root), init fails. `--iova-mode=pa|va` forces the mode. A driver flag
  `RTE_PCI_DRV_NEED_IOVA_AS_VA` forces VA.
- **[verified] on this machine** (root, no IOMMU groups, vdevs only): the default is **PA**. `--no-huge`
  gives **VA** (no PA). `--no-huge --iova-mode=pa` fails with "Cannot use IOVA as 'PA' since physical
  addresses are not available". `--iova-mode=va` with hugepages makes `iova == va`.
- **[verified] The IOVA-contig demo**: `rte_memzone_reserve_aligned("demo_mz", 3 MB, ANY,
  RTE_MEMZONE_IOVA_CONTIG, 4096)`:
  - Default dynamic mode in PA: **fails with ENOMEM, 3 out of 3 runs**. The 2 MB hugepages the kernel hands
    out are not physically adjacent.
  - The same call with `--iova-mode=va`: **succeeds every time**, with `iova = va = 0x100500000`.
  - With `-m 64` (PA) it succeeded by chance, because 64 MB of pinned pages contained some adjacent pairs.
  - It worked under `--legacy-mem`, because legacy mode sorts pages by PA.
  This shows why VA mode (with an IOMMU through VFIO) is the recommended default, and why mempool tries
  IOVA-contiguous memory first and then falls back to page-sized chunks (`lib/mempool/rte_mempool.c:578`).
- **[verified] mempool chunks in PA mode**: `dpdk-proc-info -- --show-mempool` on testpmd showed
  `nb_mem_chunks=176`, each 2 MB, with IOVAs that go **down** (0x1dea00000, 0x1de800000, ...) while the VAs
  go up. Use this for an animation: VA pages in order are mapped onto shuffled physical frames.
- DMA mask: `rte_mem_check_dma_mask(bits)` and `rte_mem_set_dma_mask` (some NICs can only address 39 or 44
  bits). Device mapping of external memory: `rte_dev_dma_map(dev, va, iova, len)`.
- Out of scope for this machine: real VFIO or IOMMU. There is no `/dev/vfio` and no NIC that may be bound.
  Explain it with diagrams only.

---

## 9. NUMA and sockets

- In DPDK, "socket" means NUMA node (the newer options say `numa`). APIs: `rte_socket_id()` (the calling
  lcore's node), `rte_lcore_to_socket_id(lcore)`, `rte_socket_count()`, `rte_socket_id_by_idx(i)`,
  `rte_eth_dev_socket_id(port)`, and `SOCKET_ID_ANY` (-1). Built with `RTE_MAX_NUMA_NODES=32` and
  `RTE_EAL_NUMA_AWARE_HUGEPAGES=1` (libnuma).
- Rule of thumb: allocate the RX/TX rings and mempool on `rte_eth_dev_socket_id(port)`, and poll with lcores
  on the same socket. l2fwd, l3fwd and skeleton warn when the port and the lcore are on different sockets.
- `--numa-mem 1024,2048` preallocates per node and `--numa-limit` caps per node. A heap exists per node.
- **This machine has 1 node**, so remote-NUMA effects cannot be measured. Teach them with a diagram (two
  sockets, QPI/UPI link, local and remote latency, roughly 80 ns against 140 ns) and with code that is
  correct on multi-socket systems. `rte_malloc_socket(..., 1)` fails here (no heap for socket 1). Show that
  failure as an exercise.

---

## 10. External memory

Two families (`env_abstraction_layer.rst` "Support for Externally Allocated Memory"):

1. **Heap API** (memory is managed by the DPDK allocator):
   `rte_malloc_heap_create(name)` → `rte_malloc_heap_memory_add(name, va, len, iova_addrs[] or NULL,
   n_pages, page_sz)` → `sock = rte_malloc_heap_get_socket(name)` → `rte_malloc_socket(..., sock)` or
   `rte_mempool_create(..., sock)`, `rte_ring_create(..., sock)` → `rte_malloc_heap_memory_remove` →
   `rte_malloc_heap_destroy`. Other processes call `rte_malloc_heap_memory_attach/detach`.
   `rte_malloc_heap_socket_is_external(sock)` tells you whether a socket id is an external heap.
   Internally `malloc_heap_create_external_seg` creates an `rte_memseg_list` with `external=1`.
   **[verified]** A 4 MB anonymous mmap added with page size 4096 and no IOVA table got socket id 256.
   `rte_malloc_socket` returned a pointer inside the region, and `rte_malloc_virt2iova` returned
   `RTE_BAD_IOVA` (no IOVA table means no DMA). Mem-event callbacks fired ALLOC and FREE for the region.
2. **`rte_extmem_*`** (the user manages the memory; DPDK only knows about it):
   `rte_extmem_register(va, len, iova_addrs, n_pages, page_sz)`, `rte_extmem_unregister`, `_attach`,
   `_detach`, plus `rte_dev_dma_map`/`rte_dev_dma_unmap`. After this, `rte_mem_virt2memseg` works on the
   region. Typical uses are GPU memory (gpudev) and memory from an external allocator.
- testpmd `--mp-alloc=native|anon|xmem|xmemhuge` (`app/test-pmd/testpmd.c` ~990-1130,
  `setup_extmem`/`create_extmem`) is a ready-made demo:
  `dpdk-testpmd --no-pci --vdev=net_null0 -m 64 --file-prefix=ch03x -- --mp-alloc=xmem --total-num-mbufs=8192`.
  Also `--mp-alloc=anon` + `--no-iova-contig`.
- Reference tests: `app/test/test_external_mem.c` and `app/test/test_malloc.c` (`dpdk-test` was not built
  here, so read the source instead).

---

## 11. CPU-cache-level memory: alignment, false sharing, prefetch, TLB, channels

- Cache-line constants and macros (`lib/eal/include/rte_common.h:924-959`): `RTE_CACHE_LINE_SIZE` (64 here;
  128 on some Arm builds), `RTE_CACHE_LINE_MIN_SIZE` 64, `__rte_cache_aligned`, `__rte_cache_min_aligned`,
  `RTE_CACHE_LINE_ROUNDUP(x)`, `RTE_ALIGN_CEIL/FLOOR`, `RTE_PTR_ALIGN`, `__rte_aligned(n)`, and
  **`RTE_CACHE_GUARD`**. The guard adds `RTE_CACHE_GUARD_LINES` (1) extra lines of padding, because the
  adjacent-line ("spatial") prefetcher fetches pairs of lines.
- **False sharing**: two cores writing different variables in the same 64 B line make the line bounce
  between caches (MESI invalidations). **[verified]** `fshare.c`, 2 lcores × 50 M increments:
  **packed 8 B counters took 102 ms, `__rte_cache_aligned` counters took 13 ms, 7.7× faster.** The result
  is the same with `--no-huge` and with hugepages, which shows that false sharing is a cache effect and has
  nothing to do with page size.
- Per-lcore state options (`env_abstraction_layer.rst` "Per-lcore and Shared Variables"):
  `RTE_DEFINE_PER_LCORE` (TLS), a static `[RTE_MAX_LCORE]` array with cache alignment + `RTE_CACHE_GUARD`
  (now called largely obsolete), and **lcore variables**: `RTE_LCORE_VAR_HANDLE`, `RTE_LCORE_VAR_ALLOC`,
  `RTE_LCORE_VAR`, `RTE_LCORE_VAR_FOREACH` (`rte_lcore_var.h`, experimental, needs
  `-DALLOW_EXPERIMENTAL_API`). The figures `doc/guides/prog_guide/img/static_array_mem_layout.svg` and
  `lcore_var_mem_layout.svg` are good references for visuals.
- Read-mostly data can be shared freely as long as no RW field shares its cache line. Use this to motivate
  hot/cold field splitting. The real example is `struct rte_mbuf`: two cache lines with
  `RTE_MARKER cacheline0/cacheline1`. The RX path only touches line 0 (`lib/mbuf/rte_mbuf_core.h`), and when
  `RTE_IOVA_IN_MBUF=0` the `next` pointer moves into line 0.
- **Prefetch** (`lib/eal/x86/include/rte_prefetch.h`, `generic/rte_prefetch.h`): `rte_prefetch0` (all cache
  levels), `1` (L2 and below), `2` (L3), `rte_prefetch_non_temporal`, `rte_prefetch0_write` etc., and
  `rte_cldemote`. **[verified]** A random gather over a 64 MB array went from 19.9 to 16.9 cycles per
  element (−15%) with `rte_prefetch0(&arr[idx[i+16]])`. The gain is modest because the VM's L3 is large
  (480 MB as reported), so teach prefetch distance as something you tune. The pattern in real code is
  l3fwd and l2fwd prefetching packet data `PREFETCH_OFFSET` packets ahead (`examples/l3fwd/l3fwd_sse.h`
  and others).
- **TLB, 4 KB against 2 MB**: **[verified]** The same 64 MB random gather took 24.6 cycles per element with
  `--no-huge` (4 KB pages) and 19.9 with hugepages, about **20% slower without hugepages**, even though the
  data fits in L3. That makes a clean measurable demo for the "why hugepages" chapter.
- Memory channels and ranks: `-n` and `-r`, `rte_memory_get_nchannel/nrank`. Mempool spreads object
  start addresses across channels and ranks by adding padding (`optimize_object_size` in
  `lib/mempool/rte_mempool.c`, disabled by `RTE_MEMPOOL_F_NO_SPREAD`). The mempool chapter covers this;
  here it only needs a mention.
- Do not use libc `memcpy`/`malloc` on the fast path. Use `rte_memcpy` (`rte_memcpy.h`) and mempools.
  `mlockall` is optional for non-DPDK memory.

---

## 12. Runnable examples that work on THIS machine

Every run must include `--no-pci --file-prefix=<unique> -l <cores>`, wrapped in `timeout -s INT -k 5 20`.
Keep hugepage use at 128 MB or less. Remove leftovers afterwards with `rm -f /dev/hugepages/<prefix>map_*`
and `rm -rf /run/dpdk/<prefix>`.

1. **"Hello memory"**: `rte_malloc`, alignment checks, `rte_malloc_validate`, stats, free. Run once with
   `--no-huge -m 64` and once with `-m 64`, and compare `iova` with `va`.
2. **See the backing files**: start a program that sleeps, then `ls /dev/hugepages | grep <prefix>`,
   `ls /run/dpdk/<prefix>`, and `grep -E 'map_|memfd|fbarray' /proc/PID/maps`, and read `HugetlbPages`
   in `/proc/PID/status`. Do this for the default mode, `--single-file-segments`, `--in-memory` and
   `--no-huge`. Expected results are in §3.2 **[verified]**.
3. **Memseg walk**: `memexp.c` prints the MSL table and the first segments, comparing 4 KB `--no-huge`
   (16384 segs), 2 MB, `--in-memory` (an extra 1 GB list), and `--legacy-mem` (contig chunks).
4. **IOVA-contig failure, then success**: `memexp` with no flags fails. `--iova-mode=va` succeeds.
   `--legacy-mem -m 32` succeeds.
5. **Heap grows and shrinks**: register a mem-event callback, `rte_zmalloc(5 MB)` then `rte_free`, and watch
   ALLOC/FREE. Then add `-m 64` and see that no events fire and `flags=DO_NOT_FREE`.
   `--legacy-mem` shows `ENOTSUP`.
6. **Validator and limit**: `--numa-limit 16` with an allocation of 32 MB fails. Or register a validator
   that prints and denies the allocation.
7. **Memzones**: reserve, lookup, `rte_memzone_dump(stdout)`, the error cases (duplicate name → `EEXIST`,
   `rte_memzone_max_set(4)` then a 5th reserve → `ENOSPC`), and `_bounded` with `bound=1 MB` (print the
   address and check it does not cross).
8. **Multi-process memzone sharing**: `mzshare.c`, primary and secondary, same VA **[verified]**.
9. **Telemetry tour**: run testpmd
   (`--vdev=net_null0 -m 128 --file-prefix=ch03tp -- --stats-period 5 --total-num-mbufs 16384`), then
   `echo "/eal/heap_info,0" | dpdk-telemetry.py -f ch03tp` and `/eal/memzone_info,0`,
   `/eal/memseg_info,0,0`. Also `dpdk-proc-info --file-prefix=ch03tp -- --show-mempool` (mempool chunks
   and IOVA). **[verified]**
10. **External heap**: the second half of `memexp.c` (mmap, then heap_create/add/get_socket/malloc), and
    testpmd `--mp-alloc=xmem`.
11. **False sharing**: `fshare.c` with `-l 0-1`, packed against padded. Extension: add `RTE_CACHE_GUARD` and
    an lcore-variable version (`-DALLOW_EXPERIMENTAL_API`).
12. **Prefetch and TLB**: the second half of `fshare.c`, run with `--no-huge` and with hugepages.
13. **NUMA exercise**: `rte_malloc_socket(..., 1)` → NULL here. Print `rte_socket_count()` and
    `rte_lcore_to_socket_id()` for every lcore. Explain what changes on a 2-socket server.
14. Optional: `--huge-unlink=never` twice in a row with the same prefix. The second run shows segments with
    `flags=2` (DIRTY). Clean up the files afterwards.

---

## 13. Visualization and animation ideas

1. **Address translation zoom**: virtual address → 4-level page walk → TLB. A slider switches between
   4 KB, 2 MB and 1 GB pages, and a counter shows TLB entries needed for 512 MB (131072 / 256 / 1).
2. **The DPDK VA window**: a long horizontal bar of 64 GB reserved PROT_NONE (grey) with fbarrays and config
   at the start (`0x100000000`). Pages "light up" as `alloc_seg` maps them, with each step of §3.3 shown in
   turn (open fd → ftruncate → mmap FIXED → touch → pagemap → mempolicy check).
3. **VA against IOVA mapping**: two columns, VA pages in order on the left and physical frames on the right,
   with lines between them. PA mode shows crossed, scattered lines (based on the real data: descending
   IOVAs). VA mode shows straight lines. Then legacy mode: frames sorted into runs, with VA gaps added.
   A "reserve 3 MB IOVA_CONTIG" button fails in PA and succeeds in VA.
4. **Layer cake**: hugetlbfs/memfd → memseg → memseg list → malloc_heap → rte_malloc / memzone → mempool,
   ring, mbuf. Clicking a layer shows the struct fields and the source file.
5. **Malloc heap animation**: a strip of memory with `malloc_elem` headers (64 B blocks) and colour-coded
   FREE, BUSY and PAD. Show allocation from the tail of a free element, split when more than 128 B is left
   over, a PAD header for alignment, merging when freed, and pages returned to the OS (strip shrinks, an
   event fires). Show the 13 size-class buckets on the side (a log4 ladder: <256, ≤1K, ≤4K, ...).
6. **Dynamic against legacy timeline**: hugepage usage over time (step chart). Legacy is flat and full.
   Dynamic follows the allocations, with a pinned floor from `-m`.
7. **NUMA diagram**: two sockets, each with cores, memory controller, DRAM, and NIC on a PCIe root. Packets
   travel the local or the remote path, and a latency meter shows the cost. Toggle "mempool on socket 0 or
   socket 1".
8. **Cache-line ping-pong (false sharing)**: two cores, one 64 B line split into 8 slots, MESI state badges
   (M/S/I) flipping on each write, a running "invalidations" counter, then the padded layout where each core
   owns its own line. Show the real measured bar chart (102 ms against 13 ms).
9. **Prefetch pipeline**: a timeline of loads with and without prefetch distance D. A slider for D shows
   memory latency being hidden.
10. **Multi-process mapping**: two process boxes with the same VA map pointing to the same hugepage files and
    `/run/dpdk/<prefix>/config`. Show the secondary asking the primary to allocate over IPC (mp_socket).
11. **mbuf cache-line layout**: two 64 B rows with the fields coloured hot RX, hot TX and cold.
12. Reusable DPDK SVGs (redraw them in your own style): `img/malloc_heap.svg`, `memory-management.svg`,
    `memory-management2.svg`, `multi_process_memory.svg`, `static_array_mem_layout.svg`,
    `lcore_var_mem_layout.svg`.

---

## 14. Common pitfalls (with symptoms)

- **No `--file-prefix` with several primaries**. Both use the `rte` prefix, so one deletes the other's
  hugepage files or fails with "Cannot create lock on '/var/run/dpdk/rte/config'. Is another primary process
  running?"
- **Leftover hugepage files** after a crash, `kill -9`, or a missing `rte_free`. `free_hugepages` drops and
  the next app gets ENOMEM. **[observed]** a primary from the multi-process demo left 8 `ch03mpmap_0_*`
  files behind. Fix: start again with the same prefix (EAL removes stale files) or `rm` them. Prefer
  `--in-memory` when multi-process is not needed.
- **Thinking `-m` is a cap**: it is a pinned minimum, and the heap keeps growing (testpmd grew to 480 MB
  with `-m 128`). Use `--numa-limit` to cap.
- **Expecting IOVA-contiguous `rte_malloc` memory**: it is only VA-contiguous. Use
  `rte_memzone_reserve(..., RTE_MEMZONE_IOVA_CONTIG)` for hardware rings. In PA mode, allocations larger
  than one page can fail (ENOMEM) even when the heap is mostly empty.
- **`rte_memseg_contig_walk` means VA-contiguous**, not physically contiguous.
- **IOVA PA without root** → EAL init fails. In containers, `/proc/self/pagemap` may hide PFNs, which gives
  `RTE_BAD_IOVA`.
- **Explicit socket with no memory there** → NULL with no fallback, often on 2-socket servers with
  hugepages reserved only on node 0. `SOCKET_ID_ANY` falls back. Check `rte_eth_dev_socket_id()`, which can
  return -1 (`SOCKET_ID_ANY`) for vdevs.
- **Allocating in memory callbacks or IPC callbacks** → deadlock. Use the `_thread_unsafe` walks inside
  callbacks.
- **`rte_malloc`/`rte_free` on the data path** → spinlock contention and latency spikes. Use mempools.
- **Using DPDK memory APIs before `rte_eal_init`** or after `rte_eal_cleanup`.
- **Mixing glibc `free()` with `rte_malloc` pointers** (or the other way round) → crash or heap corruption.
- **`RLIMIT_MEMLOCK`/`NOFILE`**: one fd per page in the default mode. Many small pages can exhaust NOFILE.
  Use `--single-file-segments`. `--in-memory` still needs MEMLOCK for some paths.
- **Secondary process mapping failures** (ASLR collision: "Could not map memory at the same address").
  Fixes are `--base-virtaddr` on the primary or disabling ASLR. The secondary must use the same
  `--file-prefix`. Legacy and single-file settings come from the shared config (`mcfg->legacy_mem`).
- **False sharing through "harmless" stats counters** in per-lcore arrays without `__rte_cache_aligned`.
  Also forgetting the adjacent-line prefetcher, which is the reason for `RTE_CACHE_GUARD`.
- **Wrong `align`**: it must be a power of two. `align=0` gives 64 B. A memzone `align` smaller than the
  cache line is rounded up.
- **1 GB pages** must be reserved at boot (`hugepagesz=1G hugepages=N` on the kernel command line), or later
  at runtime if memory is not fragmented. `--in-memory` creates 1 GB memseg lists even when none are
  reserved, which only prints a harmless notice.
- **`--no-huge` performance numbers are not representative** (4 KB TLB pressure; **[verified]** about 20%
  slower on a random-access microbenchmark).
- **`--huge-unlink=never`** leaks old data between applications (security).
- **Shared machine (this course)**: testpmd's default mbuf count takes about 400 MB of hugepages. Always set
  `--total-num-mbufs` or use `--no-huge`.

---

## 15. Source references (paths relative to `$DPDK_SRC`)

Docs:
- `doc/guides/prog_guide/env_abstraction_layer.rst`: Memory Mapping Discovery, Dynamic and Legacy, Hugepage
  Mapping, Segment FDs, Worker Stacks, External Memory, Per-lcore vars, IOVA detection, Memsegs/Memzones,
  Malloc internals (lines ~81-500, 601-720, 994-1251)
- `doc/guides/linux_gsg/linux_eal_parameters.rst` (lines 59-124) and `linux_gsg/eal_args.include.rst`
  (memory options at lines 165-212)
- `doc/guides/linux_gsg/sys_reqs.rst` (hugepage setup), `usertools/dpdk-hugepages.py`
- `doc/guides/prog_guide/writing_efficient_code.rst` (Memory section), `perf_opt_guidelines.rst`,
  `lcore_var.rst`, `multi_proc_support.rst`, `mempool_lib.rst`, `mbuf_lib.rst`
- `doc/guides/testpmd_app_ug/run_app.rst` (`--mp-alloc`, `--no-iova-contig`, `--total-num-mbufs`)
- Release notes: `release_18_05.rst` (memory hotplug), `release_18_11.rst` (external memory),
  `release_19_02.rst` (memfd for in-memory/no-huge), `release_22_03.rst` (`--huge-unlink=never`),
  `release_24_11.rst` (lcore vars), `release_26_07.rst` (`--pagesz-mem`), `release_26_11.rst` (barriers)

Headers:
- `lib/eal/include/rte_memory.h` (memseg, walks, virt2iova and phy, extmem, callbacks, validators, dma mask)
- `lib/eal/include/rte_memzone.h`
- `lib/eal/include/rte_malloc.h`
- `lib/eal/include/rte_fbarray.h`
- `lib/eal/include/rte_eal_memconfig.h`
- `lib/eal/include/rte_common.h` (cache macros 924-959)
- `lib/eal/include/generic/rte_prefetch.h`, `lib/eal/x86/include/rte_prefetch.h`
- `lib/eal/include/rte_lcore_var.h`, `lib/eal/include/rte_per_lcore.h`
- `config/rte_config.h` (RTE_MAX_HEAPS, MEMSEG_LISTS, MEMSEG_PER_TYPE, MEM_MB_PER_TYPE, CACHE_GUARD_LINES)

Implementation:
- `lib/eal/common/eal_memcfg.h` (`struct rte_mem_config`, the shared config with the locks
  mlock/qlock/mplock and `memory_hotplug_lock`)
- `lib/eal/common/eal_common_dynmem.c` (memtypes, VA reservation, page counting per socket)
- `lib/eal/common/eal_common_memory.c` (virtual area reservation, msl init, walks, extmem, dump, telemetry
  handlers 1177-1730)
- `lib/eal/common/eal_common_memzone.c`
- `lib/eal/common/malloc_heap.c` (alloc, expand, free, external heaps)
- `lib/eal/common/malloc_elem.c` (split, join, free-list index)
- `lib/eal/common/malloc_mp.c` (secondary → primary allocation requests)
- `lib/eal/common/rte_malloc.c`
- `lib/eal/common/eal_common_fbarray.c`
- `lib/eal/linux/eal_memory.c` (pagemap virt2phy, legacy init, no-huge init, secondary attach)
- `lib/eal/linux/eal_memalloc.c` (`alloc_seg`, `free_seg`, memfd/hugefile handling, NUMA policy, SIGBUS)
- `lib/eal/linux/eal_hugepage_info.c` (detects mounts and page sizes)
- `lib/mempool/rte_mempool.c` (IOVA-contig-first populate, around lines 499-610)

Tests and apps:
- `app/test/test_malloc.c`, `test_memzone.c`, `test_memory.c`, `test_external_mem.c`, `test_fbarray.c`
- `app/test-pmd/testpmd.c` (extmem ~990-1130)
- `app/proc-info` (`--show-mempool`)
- `examples/multi_process/simple_mp`

Web and background (for the history sidebar). These were not fetched in this session, so check titles and URLs before citing them:
- The DPDK 18.05 memory hotplug design by Anatoly Burakov (Intel). There are DPDK Summit talks with titles
  like "Memory in DPDK" and a three-part DPDK blog series, "Memory in DPDK, Part 1: General Concepts", "Part
  2: Deep Dive into IOVA" and "Part 3: 1.0-17.11", plus "Part 4: 18.05 and beyond" on dpdk.org/blog. These
  are the canonical explanation of the reasoning: why one file per page, why IOVA-as-VA is preferred, and
  why the VA is preallocated.
- Kernel docs: `Documentation/admin-guide/mm/hugetlbpage.rst`, `pagemap.rst`, and the VFIO/IOMMU docs.
- Drepper, "What Every Programmer Should Know About Memory" (cache lines, TLB, prefetch, NUMA).

---

## 16. Boundary with other chapters
- **EAL (02)** owns the init order, IOVA detection mechanics in general, and multi-process IPC. This note
  only adds the memory view of them.
- **Mempool and mbuf** own the object layout, per-lcore cache, channel spreading, and mbuf structure. They
  should reuse the IOVA-contig fallback and the `--mp-alloc` demos from here.
- **Performance** owns larger benchmarks. Hand them the `fshare.c` false-sharing and prefetch/TLB numbers.
- **vhost/virtio**: `--single-file-segments` and `rte_memseg_get_fd*` (passing guest memory fds) are the
  link between the two chapters.

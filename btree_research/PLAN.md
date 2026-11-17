# Plan: Understanding B-trees, from simple to complex

Status: DRAFT v1 (to be gap-reviewed, then implemented).

## Goal

A self-contained guide that takes a reader from "what is a sorted array" to "how Postgres
splits a page under concurrency", grounded in the source of the databases cloned in
`db_study/` (Postgres, Turso, DuckDB, TigerBeetle, Milvus, FAISS). Every chapter has:

- prose (`README.md`) that explains one important concept,
- the same example implemented twice: Zig 0.17.1 and Rust 1.97 (edition 2024, std only),
- at least one interactive HTML visualization built on the shared toolkit in `assets/`.

Research notes with file:line references live in `research/`. Only Postgres and Turso
contain real B-trees; DuckDB (ART + zone maps), TigerBeetle (LSM), Milvus and FAISS are
used for contrast and for transferable techniques. The guide says so plainly.

## Layout

```
btree_research/
  README.md            guide entry point, reading order, how to run everything
  index.html           landing page linking every chapter and visualization
  PLAN.md              this file
  ZIG_CHEATSHEET.md    verified Zig 0.17.1 API notes (allocators, I/O, containers)
  run_all_tests.sh     runs `zig build test` and `cargo test` in every chapter
  assets/              shared visualization toolkit (viz.css, viz.js, README.md)
  research/            per-database source notes
  _template/           compiling Zig + Rust skeleton projects
  chapters/NN-slug/
    README.md          the chapter text
    zig/               build.zig, build.zig.zon, src/*.zig  (zig build test, zig build run)
    rust/              Cargo.toml, src/*.rs                 (cargo test, cargo run)
    viz/index.html     visualization(s); may have extra pages viz/*.html
```

## Conventions for every chapter

Text (`README.md`), in this order: what you will learn; the idea in plain words; a worked
example by hand; the code walk-through (Zig first, then Rust, with the differences
explained); "In real databases" with file:line references taken from `research/`;
allocator notes (which Zig allocator the chapter uses and why); pitfalls; exercises;
links to previous / next chapter and to the visualization. Claims about a database must
be backed by a research note or the source; no invented numbers.

Code:
- Zig and Rust implement the same behaviour with the same public operations and the same
  test cases (same seeds, same expected outputs) so they can be read side by side.
- `zig build test`, `zig build run`, `cargo test`, `cargo run` all pass with no warnings;
  `cargo clippy` clean. No external dependencies in either language.
- Every data structure has a `validate()` / `check_invariants()` function and a
  randomized model test against a simple oracle (sorted array or std map).
- Zig: allocators are always passed explicitly; each chapter features the allocator named
  in its row below and checks leaks with `std.testing.allocator`; allocation-failure
  paths are tested with `std.testing.FailingAllocator` where insertion can fail. Across
  the guide every allocator in `std.heap` is used at least once, plus hand-written ones.
- Rust: safe code only, except where a chapter is explicitly about memory layout.
- `run` prints a small demonstration whose output is quoted in the README.

Visualization:
- Built with `assets/viz.js` / `assets/viz.css` only; no CDN, works from `file://`.
- Step-by-step with play / pause / step back / speed, captions for every step, and where
  useful a Zig/Rust code panel with the current line highlighted.
- Driven by a real model of the data structure in JS, not hand-drawn frames, and
  interactive (the reader can type keys / choose parameters).
- Verified with Playwright: no console errors, screenshots reviewed at desktop and phone
  width in light and dark themes.

## Chapters

Part I. In memory

| # | Slug | Concept | Sources | Code (Zig and Rust) | Zig allocator focus | Visualization |
|---|------|---------|---------|---------------------|---------------------|---------------|
| 01 | why-btrees | Storage is read in pages; a pointer hop costs a page read; binary search tree vs sorted array vs wide nodes; fanout and height arithmetic | Milvus sorted-array index (sorted array = one-node B-tree); page sizes of Postgres, Turso, DuckDB, TigerBeetle | Sorted array map with lower/upper bound; a BST that counts node visits; height calculator for N keys and fanout f | `FixedBufferAllocator` on a stack buffer; `page_allocator` | Race: BST vs sorted array vs B-tree lookups counting "page reads"; fanout slider showing height |
| 02 | search-inside-a-node | Lower bound / upper bound, branchless binary search, prefetching, linear SIMD scan for small nodes, where each wins | TigerBeetle `binary_search.zig`; FAISS SIMD kernels | Four search routines over a key array with identical results; micro-benchmark harness | `FixedBufferAllocator`, `BufferFirstAllocator` (stack first, heap fallback) | ArrayView stepping the four algorithms on the same array, comparison counters |
| 03 | btree-structure-and-search | B-tree definition, order / minimum degree, invariants, search and in-order traversal | CLRS-style definition; Turso index B-tree (keys in interior nodes) | Generic `BTree(K, V, order)` with search, traversal, `validate()`; tree built by hand in tests | `ArenaAllocator` (whole tree freed at once) | Search descent with key comparisons highlighted; invariant checker panel |
| 04 | insertion-and-splitting | Insert into leaf, split on overflow, median promotion, root split grows height; proactive (top-down) vs reactive (bottom-up) splitting | Turso overflow cell + balance; Postgres `_bt_split` | Insert for chapter 03 tree, both split strategies | `MemoryPool` for fixed-size nodes; `FailingAllocator` tests | Interactive insert with split animation; sequential vs random insert fill comparison |
| 05 | deletion-and-rebalancing | Delete from leaf, from interior (predecessor/successor), borrow from sibling, merge, root shrink | Turso delete + balance; TigerBeetle segmented array merge-or-borrow | Delete for chapter 04 tree; full invariant check after each op | `MemoryPool` with free-list reuse; `DebugAllocator` leak and double-free detection | Interactive delete showing borrow vs merge vs height shrink |
| 06 | testing-a-btree | Invariants as code, model-based fuzzing with a seeded PRNG, shrinking node sizes to force edge cases, allocation-failure injection | TigerBeetle fuzzers; Turso integrity checks | Fuzz harness comparing the tree with an oracle after every operation; deliberately broken variants the fuzzer catches | `std.testing.allocator`, `FailingAllocator`, a hand-written counting allocator | Fuzzer replay: operation stream on the left, tree and oracle on the right, stops at first divergence |
| 07 | bplus-trees-and-range-scans | B+tree: values only in leaves, separator keys, leaf sibling links, range scans, cursors / iterators | Turso table B-tree vs index B-tree; Postgres leaf links | `BPlusTree` with insert, delete, `range(lo, hi)` iterator, forward and backward cursor | `ArenaAllocator` with `reset(.retain_capacity)` per scan; arena per operation scratch space | B-tree vs B+tree side by side for the same keys; range scan walking the leaf chain |

Part II. On disk

| # | Slug | Concept | Sources | Code (Zig and Rust) | Zig allocator focus | Visualization |
|---|------|---------|---------|---------------------|---------------------|---------------|
| 08 | pages-and-the-buffer-pool | File as an array of fixed-size pages, page ids instead of pointers, buffer pool, pin/unpin, dirty pages, eviction (clock / SIEVE) | Turso pager + page cache; Postgres buffer manager; DuckDB block manager | `Pager` (read/write page at offset) and `BufferPool` with pin counts and eviction over a real file | Hand-written slab allocator of 4096-byte aligned frames; `SmpAllocator` for metadata | Buffer pool frames, pin counts, clock hand, hit/miss counters under a page access trace |
| 09 | slotted-pages | Variable-length cells in a fixed page: header, slot array growing forward, cell area growing backward, free blocks, fragmentation, defragmentation | Turso page format; Postgres line pointers and special space | `SlottedPage` over a `[4096]u8`: insert, delete, lookup by slot, binary search, compact | The page as a tiny allocator: a `std.mem.Allocator` implemented over a page buffer | PageView: bytes of a page as cells are inserted, deleted and defragmented |
| 10 | key-and-record-encoding | Varints, record formats, order-preserving ("memcmp-able") key encoding for ints, floats, strings; composite keys | Turso record format; DuckDB ART key encoding; TigerBeetle composite keys | Encode/decode varints and records; order-preserving encoders with property tests (encoded order equals logical order) | `FixedBufferAllocator` for encode buffers; arena for decoded rows | Byte-level view of a value being encoded; sorting demo showing byte order equals value order |
| 11 | disk-backed-bplus-tree | Putting 07 to 10 together: a B+tree whose nodes are slotted pages addressed by page id; stable root page; metapage | Turso `balance_root`; Postgres metapage and fast root | `DiskBTree` on the pager: open/create, get, put, scan, reopen from disk | Buffer pool slab + arena per operation; no per-node heap allocation | Tree of pages with page ids, plus the buffer pool state during an insert that splits |
| 12 | overflow-and-free-space | Values larger than a page: overflow chains; reusing freed pages: free list, free space map | Turso overflow thresholds and freelist trunk pages; Postgres FSM; DuckDB free list after checkpoint | Overflow chains and a free-page list added to chapter 11 | `MemoryPool` for free-list bookkeeping; arena for assembling large values | Large value spilling into an overflow chain; freed pages returning to the free list |
| 13 | rebalancing-in-real-engines | SQLite-style balance over up to three siblings, append fast path, split-point choice, fill factor, rightmost-page optimization, why Postgres never merges on underflow | Turso `balance_non_root`, `balance_quick`; Postgres `nbtsplitloc.c` | Three-sibling redistribution; split-point policies (50/50, fill factor, rightmost) with space-utilisation measurements | Scratch arena for the flattened cell array, reset per balance | Same insert workload under different split policies, page fill histogram |
| 14 | bulk-loading | Building a tree bottom-up from sorted input, fill factor, why it beats repeated inserts | Postgres `nbtsort.c` | Bottom-up bulk loader for the B+tree, compared with insert-one-by-one (page writes, fill) | One arena per tree level; `reset(.retain_capacity)` | Leaves filling left to right while parents are built above them |
| 15 | key-compression-and-deduplication | Prefix compression, suffix truncation of separators, duplicate keys and posting lists | Postgres suffix truncation and `nbtdedup.c`; DuckDB ART prefix nodes | Suffix-truncated separators; posting-list leaf entries; fanout before and after | `FixedBufferAllocator` scratch; arena for rebuilt pages | Separator shrinking during a split; duplicates collapsing into a posting list |

Part III. Concurrency and durability

| # | Slug | Concept | Sources | Code (Zig and Rust) | Zig allocator focus | Visualization |
|---|------|---------|---------|---------------------|---------------------|---------------|
| 16 | latching-and-lock-coupling | Latches vs locks, latch coupling (crabbing), safe nodes, optimistic descent | Postgres buffer locks; textbook crabbing | Thread-safe B+tree with per-node reader-writer latches; multi-threaded stress test | Thread-safe allocator (`SmpAllocator`, thread-safe wrapper); per-thread arenas | Two threads descending with shared/exclusive latches shown per node |
| 17 | blink-trees | Lehman and Yao: high keys, right links, move right, splits without holding parent latches, incomplete splits | Postgres nbtree README, `_bt_moveright`, incomplete-split flag | B-link tree with concurrent search during splits; stress test | Per-thread arenas; shared pool for nodes | A search arriving at a node that just split and moving right |
| 18 | wal-and-crash-recovery | Write-ahead logging, torn pages and full-page images, checksums, making a multi-page split atomic, redo on recovery | Postgres `nbtxlog.c`; Turso WAL frames and checksums | WAL in front of the chapter 11 tree; crash injection at every write; recovery test | `FixedBufferAllocator` for log records; arena during recovery | Timeline of page writes and log records with a crash slider; recovery replay |
| 19 | copy-on-write-btrees | Shadow paging: never overwrite, copy the root-to-leaf path, atomic root swap, snapshots for free; trade-offs vs WAL | DuckDB alternating headers and deferred block reuse; TigerBeetle copy-on-write blocks and superblock | Copy-on-write B+tree with snapshot readers and atomic root pointer flip | Arena per transaction (dropped on abort); page slab | Path copying on insert; two roots sharing subtrees; old pages freed after readers leave |
| 20 | mvcc-and-garbage | Versions and dead entries in an index, hint bits, bottom-up deletion, vacuum, page deletion and safe recycling | Postgres LP_DEAD, vacuum, half-dead pages; Turso MVCC | Tombstoned entries, a vacuum pass, two-phase page deletion on the chapter 17 tree | `DebugAllocator` to prove reclaimed memory is released; pool reuse | Dead entries accumulating, vacuum sweeping, an empty page unlinked and recycled |

Part IV. Beyond the textbook

| # | Slug | Concept | Sources | Code (Zig and Rust) | Zig allocator focus | Visualization |
|---|------|---------|---------|---------------------|---------------------|---------------|
| 21 | memory-layout-and-allocators | Handles instead of pointers, size-class slab allocators, struct-of-arrays nodes, static allocation at start-up | DuckDB `FixedSizeAllocator`; TigerBeetle `NodePool` and static allocator | B-tree on a bitmap slab allocator with 32-bit handles; SoA node layout; "freeze after init" allocator | The allocator chapter: custom slab, bitmap pool, static (freeze) allocator, `MultiArrayList`, every remaining `std.heap` allocator | Memory map of slabs and handles as nodes are allocated and freed; pointer vs handle layout |
| 22 | btree-vs-lsm | LSM-trees: memtable, sorted tables, levels, compaction; write, read and space amplification compared with a B-tree | TigerBeetle LSM forest; Milvus segments and compaction | A small LSM (memtable, runs, leveled compaction, k-way merge) and counters comparing it with the B+tree | Arena per memtable flushed and reset; fixed buffers for merge | Same workload on a B-tree and an LSM, page writes and reads counted live |
| 23 | when-not-to-use-a-btree | Adaptive radix tree, zone maps, and why ordered trees fail for vector similarity (IVF, HNSW) | DuckDB ART and zone maps; FAISS IVF and HNSW; Milvus scalar indexes | Small ART (Node4/16/48/256), zone-map pruning, and a tiny HNSW or IVF, each contrasted with the B+tree | Size-class pools for ART nodes; arena for graph build | ART node growth; zone-map pruning of row groups; greedy graph descent vs tree descent |

## Process

1. Research (done): one agent per database, notes in `research/`.
2. Plan (this file), then gap review by independent agents, then plan fixes.
3. Implementation: one agent per chapter in parallel, on top of the shared toolkit,
   template and cheat sheet.
4. Two review rounds per chapter: reviewer finds gaps, a second agent validates each gap
   and fixes the confirmed ones.
5. Integration: landing page, README, test runner, cross-links; full test run.

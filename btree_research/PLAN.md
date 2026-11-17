# Plan: Understanding B-trees, from simple to complex

Status: v2. Draft v1 was reviewed by three independent gap reviewers (topic coverage and
teaching order, fidelity to the database sources, implementation feasibility). Their
confirmed findings are folded in; the change log is at the end.

## Goal

A self-contained guide that takes a reader from "what is a sorted array" to "how Postgres
splits a page under concurrency", grounded in the source of the databases cloned in
`db_study/`. Every chapter has:

- prose (`README.md`) explaining one important concept,
- the same example implemented twice: Zig 0.17.1 and Rust 1.97 (edition 2024, std only),
- at least one interactive HTML visualization built on the shared toolkit in `assets/`.

Honest roles of the six codebases (pinned commits are recorded in `research/`):

| Codebase | Role in the guide |
|----------|-------------------|
| Postgres (`nbtree`) | The main on-disk, concurrent B-link tree: splits, split-point choice, suffix truncation, deduplication, vacuum, WAL |
| Turso | The SQLite-format B-tree: slotted pages, table B+tree vs index B-tree, balance over siblings, page-stack cursors, pager, WAL frames |
| Milvus | Two small in-memory B-trees (`google/btree`), sorted-array scalar index, LSM-like segments (not a true LSM) |
| DuckDB | No B-tree: ART index, zone maps, slab allocator with handles, alternating headers. Used for contrast and techniques |
| TigerBeetle | No B-tree: LSM forest. Static 2-level table index, segmented array with node pool, in-node search, fuzzing style, static allocation |
| FAISS | No B-tree: IVF and HNSW show why ordered trees fail for vector similarity; layout lessons |

## Layout

```
btree_research/
  README.md            entry point: reading order, prerequisites, chapter dependency diagram, how to run
  index.html           landing page linking every chapter and visualization
  GLOSSARY.md          terms used across chapters
  SOURCE_READING_MAP.md  per database: which files to read in which order, tied to chapters
  PLAN.md  ZIG_CHEATSHEET.md  run_all_tests.sh
  assets/              shared visualization toolkit (viz.css, viz.js, README.md)
  common/              tiny shared pieces that chapters COPY in: PRNG, op-stream generator, CRC32 (Zig and Rust)
  research/            per-database source notes
  _template/           compiling Zig + Rust skeleton projects
  chapters/NN-slug/
    README.md  solutions.md  expected_output.txt
    zig/    build.zig, build.zig.zon, src/*.zig   (zig build test, zig build run)
    rust/   Cargo.toml, src/*.rs                  (cargo test, cargo run)
    viz/    index.html (+ extra pages), code.js (snippets inlined for the code panel)
```

## Conventions (binding for every chapter)

Self-containment. A chapter never imports another chapter's code. If it needs a
structure from an earlier chapter, it copies that chapter's source files into its own
`src/` as `base_*.zig` / `base_*.rs`, with a header comment naming the source chapter, and
may trim them. Chapters are therefore implemented in waves (see Process). `common/` files
are copied the same way.

Fixed choices.
- Part I keys and values are `u64`. On-disk chapters use byte-string keys and values,
  little-endian integers, page size 4096.
- "Order" M means the maximum number of children (Knuth). A node holds at most M-1 keys
  and, except the root, at least ceil(M/2)-1. Default M = 4 in tests and visualizations
  (a 2-3-4 tree). Chapter 03 has the table mapping this to CLRS minimum degree t and to
  byte-based occupancy in real engines.
- Duplicate keys: Part I rejects duplicates (put overwrites). From chapter 07 the
  tie-breaker idea (key + row id) is explained; chapter 17 covers posting lists.
- Operation names: `get`, `put`, `delete`, `range`, `validate` (camelCase methods in Zig,
  snake_case in Rust). Package names `chNN_slug`.
- Canonical hand example for chapters 03 to 08: insert 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15
  in that order with M = 4.
- Randomness comes only from `common/` (SplitMix64 implemented identically in both
  languages, with golden vectors), so Zig and Rust tests use identical operation streams.

Text (`README.md`), in this order: what you will learn and prerequisites; the idea in
plain words; a worked example by hand; code walk-through (Zig, then Rust, differences
explained); "In real databases" with file:line references from `research/` (anything not
verified in source is labelled textbook or unverified); allocator notes; pitfalls; 3 to 5
graded exercises (solutions in `solutions.md`); links to previous / next chapter and the
visualization. No invented numbers; timings are never quoted, only counts.

Code.
- `zig build test`, `zig build run`, `cargo test`, `cargo run` pass without warnings;
  `cargo clippy --all-targets -- -D warnings` is clean. No external dependencies.
- `run` is deterministic. Both programs print exactly `expected_output.txt`; a test in
  each language checks it, and the README quotes it.
- Each `build.zig.zon` has its own name and fingerprint; `zig build test` must reach every
  test (explicit imports or `refAllDecls`). File tests use `std.testing.tmpDir`.
- Every structure has `validate()` and a seeded model test against a simple oracle.
- Zig: allocators are always passed explicitly; the chapter's featured allocator is the
  natural one for the job (see table) and the README says why; leaks are checked with
  `std.testing.allocator`; insert paths are tested under allocation failure.
- Rust shows the equivalent idiom: typed arena (`Vec<Node>` + `u32` indices), slab with a
  free list of indices, bump `Vec<u8>` with offsets, boxed page frames, drop-the-Vec as an
  arena; allocation failure is mirrored by a node budget returning `Err(OutOfNodes)`.
  Safe code only, except where the table declares an exception.
- Stress tests: at most 4 threads and 5 seconds; no timing assertions.

Visualization.
- `assets/viz.js` / `assets/viz.css` only; no CDN; works from `file://`; light and dark.
- Driven by a real JS model with step forward / back, speed, captions; the reader can
  type keys or choose parameters; a "predict the next step" mode where it fits.
- Code panel snippets are inlined in `viz/code.js` (no fetch under `file://`).
- The JS model must reproduce the final state of the fixed scenario printed by the
  programs (embedded as a self-test), so the picture cannot drift from the code.
- Verified with Playwright: no console errors; screenshots reviewed at 1280 and 390 px,
  both themes.

## Chapters

Wave = implementation wave (a chapter may copy code only from an earlier wave).

### Part I. In memory

| # | Slug | Wave | Concept | Sources | Code (Zig and Rust) | Allocators (Zig; Rust idiom) | Visualization |
|---|------|------|---------|---------|---------------------|------------------------------|---------------|
| 01 | why-btrees | 1 | External-memory cost model: count page reads, not comparisons. BST vs sorted array vs wide nodes; fanout and height; a one-level structure costs O(nodes) per change, which is why height exists | Milvus sorted-array index and "mutable map, sealed sorted array"; TigerBeetle one-level segmented array; numbers tables of Postgres and Turso (DuckDB/TigerBeetle block sizes are not lookup pages: say so) | Sorted-array map; BST that counts node visits; height calculator | `FixedBufferAllocator` on a stack buffer; `page_allocator` framed as one page per pointer hop. Rust: `Vec` and `Box` | Race of BST vs sorted array vs B-tree counting page reads; fanout slider |
| 02 | searching-a-sorted-node | 1 | Lower bound, upper bound, the "insertion index" result, off-by-one traps, inclusive/exclusive bounds | Postgres `_bt_binsrch`; Turso search through the cell pointer array; Milvus galloping search; TigerBeetle `binary_search.zig` (plain variant) | `lowerBound`, `upperBound`, `searchResult {found, index}`, galloping search, exhaustive tests | No heap needed: slices over caller memory; `FixedBufferAllocator` for the test arrays | ArrayView stepping lower/upper bound, with predict mode |
| 03 | btree-structure-and-search | 2 (from 05) | Definition, order terminology table (Knuth M, CLRS t, Bayer and McCreight k, bytes), 2-3-4 trees and the red-black correspondence, invariants, height bound with proof, search, traversal; first look at validate + oracle tests | Milvus `google/btree`; Turso index B-tree (keys in interior nodes); real engines measure fullness in bytes | Node type, `get`, in-order traversal, `validate`; trees built by hand | A hand-written bump allocator first, then `ArenaAllocator`. Rust: typed arena | Search descent; invariant checker; toggle showing the red-black equivalent of a 2-3-4 tree |
| 04 | insertion-and-splitting | 2 (from 05) | Insert into a leaf, split on overflow, median promotion, root split; amortised split cost; measured fill (about 69% random, about 50% ascending); top-down splitting as a textbook alternative | Postgres `_bt_split` (left half keeps its block, halves built in scratch memory, parent stack is a hint); Turso overflow cell then balance. Both are bottom-up | `put` with bottom-up split; top-down variant; fill statistics | `MemoryPool` for nodes; `checkAllAllocationFailures`. Rust: slab + node budget | Interactive insert; second page: fill under ascending vs random inserts |
| 05 | deletion-and-rebalancing | 1 | Delete from leaf and interior (predecessor), borrow, merge, root shrink; real engines use byte thresholds and often do not merge | Turso delete and balance (1 to 5 output pages unify split, merge, rotate); TigerBeetle segmented array merge-or-borrow | The complete in-memory B-tree: `get`, `put`, `delete`, `validate`, model test | A hand-written free-list pool, then `MemoryPool`; `std.testing.allocator` (SafeAllocator) catching leaks and double frees. Rust: slab free list | Interactive delete: borrow vs merge vs height shrink |
| 06 | testing-a-btree | 2 (from 05) | Invariants as code, model-based fuzzing, tiny nodes to force edge cases, swarm weights, fault injection, minimising a failing case | TigerBeetle fuzzers and coverage asserts; Turso integrity check | Fuzz harness with oracle; three deliberately broken tree variants that the fuzzer catches | Hand-written counting and fault-injecting allocator wrapper; `FailingAllocator`. Rust: counting `#[global_allocator]` (declared unsafe exception) | Fuzzer replay: op stream, tree vs oracle, stops at first divergence |
| 07 | bplus-trees | 1 | Values only in leaves; separators are copies (copy-up vs push-up); leaf chain; duplicate policy and tie-breakers; handles (indices) instead of pointers | Turso table B+tree vs index B-tree; Postgres leaf links; Turso has no sibling links on disk | In-memory `BPlusTree` on an index arena: `get`, `put`, `delete`, `validate`, leaf chain | Index arena over an `ArrayList` of nodes plus free list. Rust: `Vec<Node>` + `u32` | B-tree vs B+tree side by side for the canonical keys |
| 08 | range-scans-and-cursors | 2 (from 07) | Range scans; bounds matrix; prefix scan as a range; two cursor designs (leaf links vs root-to-leaf stack); backward scan; what happens to a cursor when the tree changes (re-seek by key) | Postgres leaf links and page-at-a-time scans; Turso page-stack cursor and save-key/re-seek; DuckDB ART iterator; Milvus bound handling; skip scan as a sidebar | `range(lo, hi)` both ways, link cursor and stack cursor with identical results, invalidation test | Arena for the cursor path stack and materialised results, `reset(.retain_capacity)` per scan; iteration itself does not allocate | Range scan with both cursor styles; cursor surviving a split |

### Part II. On disk

| # | Slug | Wave | Concept | Sources | Code | Allocators | Visualization |
|---|------|------|---------|---------|------|------------|---------------|
| 09 | pages-and-the-buffer-pool | 1 | File as an array of fixed pages; page ids as pointers (comparison table of pointer representations); buffer pool, pin, dirty, eviction | Turso pager and SIEVE cache, dirty-page spilling; TigerBeetle set-associative CLOCK cache; DuckDB eviction queues; pointer forms in Turso, Postgres, DuckDB, TigerBeetle | `Pager` over a real file and `BufferPool` with pin counts and CLOCK eviction | Hand-written slab of page-aligned 4096-byte frames. Rust: boxed frames | Frame grid with clock hand, pins, hit/miss counters |
| 10 | slotted-pages | 1 | Variable-length cells in a fixed page: slot array, cell area, free blocks, fragmentation, compaction | Turso (2-byte cell pointers, freeblock chain, fragment counter) side by side with Postgres (4-byte line pointers, special space, high key slot) | `SlottedPage` over `[4096]u8`: insert, delete, find, compact | An offset-returning cell allocator inside the page (and why it cannot be a `std.mem.Allocator`: cells move) | PageView and hex grid during insert, delete, compaction |
| 11 | key-and-record-encoding | 1 | Varints, records; comparator-based keys vs byte-comparable keys; order-preserving encoding of ints, floats, strings; composite keys; NULLs and descending order | Postgres scan keys and Turso records (comparator); DuckDB ART keys and TigerBeetle composite keys (byte-comparable) | Encoders and decoders with the property "encoded order equals logical order" | `FixedBufferAllocator` for encode buffers; arena for decoded rows; `BufferFirstAllocator` (stack first, heap on overflow). Rust: bump `Vec<u8>` | Byte view of encoding; sort by bytes equals sort by value |
| 12 | disk-backed-bplus-tree | 2 (from 09, 10, 11) | A B+tree whose nodes are slotted pages addressed by page id; fullness measured in bytes; stable root page and metapage; explicitly not crash-safe yet (demo of a torn split) | Turso `balance_root`; Postgres metapage and fast root | `DiskBTree`: create, open, `get`, `put`, `range`, reopen. 50/50 byte split; no delete | Buffer-pool slab plus an arena per operation | Tree of pages with ids; second page: buffer pool during a splitting insert |
| 13 | overflow-and-free-space | 3 (from 12) | Values larger than a page (overflow chains vs size caps); deleting and freeing pages; free list; when a freed page may be reused (four-way comparison) | Turso overflow thresholds and freelist trunk pages; Postgres 1/3-page tuple cap and recyclable pages; DuckDB and TigerBeetle "not reusable until the next durable checkpoint" | Overflow chains, `delete` with free-at-empty, on-disk free list | Fallback chain: stack buffer then heap for assembling large values; arena | Value spilling into an overflow chain; pages returning to the free list |
| 14 | split-policies-and-fill-factor | 1 | Where to cut a full page: 50/50, fill factor, rightmost-page 90/10, many duplicates; effect on space | Postgres `nbtsplitloc.c` | In-memory page model (cells with byte sizes): split policies as a strategy, fill statistics | Scratch arena reset per split | Same workload under different policies with a fill histogram |
| 15 | redistribution-and-merge-policies | 1 | Balancing across up to three siblings (B* idea), append fast path, merge at empty vs never merge and why | Turso `balance_non_root`, `balance_quick`; Postgres never merges (README) | `balance3` on the page model; merge policies compared by page count and churn | Scratch arena for the flattened cell array | Cells flowing between three siblings; policy comparison |
| 16 | bulk-loading | 1 | Build bottom-up from sorted input; fill factor; cost vs repeated insert | Postgres `nbtsort.c`; TigerBeetle table as a dense static 2-level index; DuckDB sorted ART build | Bottom-up loader vs one-by-one insert, counting page writes | One arena per tree level with `reset(.retain_capacity)` | Leaves filling left to right while parents grow above |
| 17 | key-compression-and-deduplication | 1 | Separators are not keys: suffix truncation; fence keys; heap TID tie-breaker; posting lists. Prefix compression is textbook only here | Postgres suffix truncation and `nbtdedup.c`; DuckDB ART prefix nodes as a contrast | Truncated separators and posting-list leaves on the page model; fanout before and after | `FixedBufferAllocator` scratch; arena for rebuilt pages | Separator shrinking at a split; duplicates collapsing into a posting list |
| 18 | indexes-in-a-database | 2 (from 07) | How a database uses the tree: clustered table (Turso rowid tree) vs heap plus secondary index (Postgres); unique checks; covering scans; composite keys and prefix scans | Turso table and index trees; Postgres heap TIDs and unique insertion | A tiny table with a primary tree and a secondary index; unique constraint; index-only scan | Arena per query; pool for rows | Lookup through a secondary index back to the row, for both layouts |

### Part III. Concurrency and durability

| # | Slug | Wave | Concept | Sources | Code | Allocators | Visualization |
|---|------|------|---------|---------|------|------------|---------------|
| 19 | latching-and-lock-coupling | 2 (from 07) | Latches vs locks; the ladder: one mutex, one reader-writer lock, latch coupling (textbook), optimistic version checks (prose + viz); latch ordering | DuckDB index-wide lock; Milvus RWMutex over its B-tree; Turso single writer; Postgres does not crab (one page lock at a time) | Preallocated node table indexed by `u32`; search and insert only; global lock, RW lock, and latch-coupled variants; deterministic tests plus bounded stress test | `smp_allocator`; thread-safe arena; locks via `std.Io`. Rust: `Box<[RwLock<Node>]>` | Reader-driven interleaving of two threads with shared/exclusive latch badges |
| 20 | blink-trees | 2 (from 07) | Lehman and Yao: high key, right link, move right; split as two atomic steps; incomplete-split flag finished by the next writer | Postgres nbtree README, `_bt_moveright`, `_bt_split`, incomplete split | B-link tree with a test hook that pauses a split between sibling link and parent insert; search and insert only | Shared node table; per-thread arenas | A search meeting a half-finished split; toggle "without right links the key is missed" |
| 21 | durability-primitives | 1 | What a write guarantees: fsync, OS cache, torn writes, checksums, full-page images vs double write | Turso checksums; Postgres full-page images; TigerBeetle simulated faults | `Storage` interface: real file and `SimDisk` that drops, keeps or tears unsynced writes; checksummed pages | `FixedBufferAllocator` for sector buffers; arena in the simulator | Pending vs durable writes with a crash button showing torn pages |
| 22 | wal-and-crash-recovery | 3 (from 12, 21) | Write-ahead rule, LSN, commit, checkpoint, redo; making a multi-page split atomic; crash at every write | Postgres `nbtxlog.c` (two records per split) vs Turso whole-page frames with commit marker and checksum chain; TigerBeetle simulation style | Full-page-image WAL in front of the disk tree on `SimDisk`; loop crashing after every write and checking recovery gives the before or after state | `FixedBufferAllocator` for log records; arena during recovery | Page 1: torn split without WAL; page 2: log timeline with crash scrubber and replay |
| 23 | copy-on-write-btrees | 2 (from 07) | Never overwrite: copy the path, flip the root atomically; snapshots; sibling links do not survive; page reuse after readers leave | DuckDB alternating headers and deferred block reuse; TigerBeetle copy-on-write blocks, checksummed pointers, superblock (neither is a COW B-tree: say so; LMDB is mentioned as unverified) | COW B+tree without leaf links; refcounted root snapshots; two-slot checksummed metapage | Arena per transaction, dropped on abort; page slab. Rust: drop-the-Vec | Path copying; two roots sharing subtrees (DAG); old pages freed |
| 24 | mvcc-vacuum-and-page-deletion | 2 (from 07) | MVCC primer (transaction ids, snapshots); versions inside the index (Postgres) vs outside it (Turso); dead entries, hints, vacuum; two-phase page deletion and safe recycling | Postgres LP_DEAD, bottom-up deletion, VACUUM, half-dead pages; Turso MVCC layer merged by a cursor | Single-threaded B+tree with right links, an epoch counter, tombstones, vacuum pass, unlink then recycle when the epoch has passed | `std.testing.allocator` proving reclaimed memory is released; pool reuse | Dead entries accumulating, vacuum sweep, a page unlinked then recycled |

### Part IV. Beyond the textbook

| # | Slug | Wave | Concept | Sources | Code | Allocators | Visualization |
|---|------|------|---------|---------|------|------------|---------------|
| 25 | cache-conscious-search-and-layout | 1 | Branchless search, prefetch, SIMD scan of small nodes, Eytzinger layout, struct-of-arrays nodes; when each wins | TigerBeetle `binary_search.zig`; FAISS kernels as a layout lesson (they are distance kernels, not key search) | Branchless, `@Vector` linear scan, Eytzinger; identical results and comparison counts. Rust: chunked auto-vectorisable loop | `MultiArrayList` for SoA nodes; aligned allocation | Cache-line strip showing lines touched per algorithm |
| 26 | allocators-handles-and-static-memory | 1 | The allocator chapter: bitmap slab with 32-bit handles, size classes, freeze after init, buddy allocator; plus a tour of every `std.heap` allocator | DuckDB `FixedSizeAllocator` (handles, vacuum); TigerBeetle `NodePool`, static allocator | B-tree nodes on a bitmap slab with handles; static allocator; allocator tour with three build steps (default, single-threaded for `BrkAllocator`, libc for `c_allocator`), including `DebugAllocator`, `SafeAllocator`, `SmpAllocator`, `MemoryPool` non-growable | All of them | Memory map of slabs and handles; pointer vs handle |
| 27 | btree-vs-lsm | 2 (from 07) | Memtable, sorted runs, levels, compaction, k-way merge; write, read, space amplification; B-epsilon trees as the midpoint | TigerBeetle LSM forest (growth factor, levels); Milvus segments (LSM-like, not an LSM) | Small LSM and the B+tree on the same counted block device | Arena per memtable, reset on flush; fixed merge buffers | Same workload on both with live read/write counters; second page: buffered B-epsilon node |
| 28 | radix-trees-and-hash-indexes | 1 | Adaptive radix tree (Node4/16/48/256, path compression) and hash index vs B-tree: what each can and cannot answer | DuckDB ART (node sizes, shrink thresholds, no SIMD in Node16) | ART insert and search; a simple hash index; comparison with ordered scans | Size-class pools for ART nodes | ART node growing through its four sizes |
| 29 | zone-maps-and-vector-indexes | 1 | Min/max summaries prune without ordering; why no total order preserves nearness; IVF as a one-level tree, HNSW as a skip list without order | DuckDB zone maps and index-scan cut-off; Milvus skip index; FAISS IVF and HNSW | Zone-map pruning; a small IVF (k-means + nprobe). HNSW is visualization only | Arena for clustering scratch | Three pages: zone-map pruning, IVF probing, greedy graph descent |
| 30 | tracing-a-real-insert | 3 (from 12) | Capstone: one INSERT followed through Postgres nbtree and through Turso, each step linked to its chapter; why production code is written as resumable state machines | Postgres `_bt_doinsert` path; Turso insert and balance; Turso async I/O model | A resumable (re-entrant) insert state machine over the disk tree returning `Done` or `Io` | Arena per operation that survives across resumptions | Two swim lanes (Postgres, Turso) stepping through the same insert |

## Process

1. Research: one agent per database (done), notes in `research/`.
2. Plan, three independent gap reviews, plan fixes (this version).
3. Foundations: Zig cheat sheet and template, visualization toolkit, `common/`.
4. Implementation in three waves, all chapters of a wave in parallel, one agent each.
5. Two review rounds per chapter: a reviewer lists gaps; a second agent validates each
   gap (reproduces it) and fixes the confirmed ones. Round-2 reviewers of dependent
   chapters also check their `base_*` copies against the fixed source chapter.
6. Integration: README, index.html, glossary, source reading map, test runner, full run.

## Changes from draft v1 (gap review results)

- Fixed false statements: Milvus does contain two in-memory B-trees; Turso has no leaf
  sibling links (page-stack cursor); Postgres does not use latch crabbing; Turso MVCC is
  outside the tree; top-down splitting and prefix compression are textbook, not found in
  these sources; FAISS SIMD kernels are not key search.
- Reordered: branchless/SIMD search moved from chapter 02 to Part IV (25).
- Split overloaded chapters: B+tree / cursors (07, 08); split policies / redistribution
  (14, 15); durability primitives / WAL (21, 22); ART+hash / zone maps+vectors (28, 29).
- Added: indexes in a database (18), capstone trace with state machines (30), complexity
  analysis (03, 04), order terminology, 2-3-4 trees, duplicate policy, fence keys, B*,
  B-epsilon, glossary, solutions, source reading map, pointer and free-space comparisons.
- Feasibility: self-containment rule with waves; shared PRNG and CRC32; fixed key types,
  order definition and names; `expected_output.txt`; `SimDisk` for crash tests;
  deterministic concurrency tests; scope cuts for 12, 19, 20, 24, 26, 29; allocator
  names corrected for Zig 0.17.1 and assignments made natural rather than forced.
- Left out as chapters (sidebars at most): Bw-tree, foster B-trees, partitioned B-trees,
  cache-oblivious layouts, key-range locking.

# 26. Allocators, handles and static memory

This chapter builds the three allocators an index engine ends up writing for itself,
puts a B-tree on top of them, and then walks through every allocator Zig's standard
library ships, with a tested example each.

## What you will learn

- Why a tree of fixed-size nodes wants a **slab** (one size, a bitmap, no per-item
  header) and what **32-bit handles** buy over pointers: half the size, relocation,
  compaction.
- **Size classes**: one pool per node kind.
- **Vacuum**: evacuating the emptiest slab, which only handles make possible.
- **Static memory**: reserve everything during start-up, then freeze the allocator so
  that a later allocation is a detected bug.
- The **buddy allocator**: power-of-two blocks that split and merge.
- What each allocator in Zig 0.17.1 `std.heap` and `std.testing` is for, and the stable
  Rust idiom that replaces it.

Prerequisites: the in-memory B-tree of chapters 03 to 05 and the index arena of
chapter 07. Nothing on disk is needed.

## The idea in plain words

**A slab.** All nodes of one kind have the same size. Cut a block of memory into
equal slots and keep one bit per slot that says "free". Allocating is "find a set bit,
clear it"; freeing is "set the bit". There is nothing else to store: no size (every
slot has the same one), no free-list pointer, no header. When the slab is full, take
another one.

**A handle.** Number the slabs and the slots. The pair (slab id, slot) names a node
just as well as its address does, and fits in 32 bits:

```
bit 31     bits 30..8          bits 7..0
class      slab id             slot
```

A pointer says where a node *is*. A handle says which node it is, and the pool decides
where that is. The pool may therefore move a node, as long as the one place holding
its handle is updated. The price is one extra load per dereference: slab directory
first, then the slot.

**Size classes.** A leaf has no child array and is smaller than an interior node. Two
pools, one per kind, waste nothing; the class bit in the handle says which pool to ask.

**Static memory.** A slab pool can be told how many slabs it will ever need. Create
them all during start-up, then *freeze*: from then on memory use cannot grow, an
insert can only fail with "pool exhausted", and no code path can hide an allocation.

**A buddy allocator.** The slabs themselves have to come from somewhere, and slabs of
different classes have different sizes. A buddy allocator serves power-of-two sizes
from one region: it halves a block until the piece fits and, on free, glues a block
back to its other half (its *buddy*) whenever that half is free too.

## A worked example by hand

Take a pool with 4 slots per slab. `#` is a used slot, `.` a free one.

```
create x6      slab 0 [####]  slab 1 [##..]      handles 0.0 0.1 0.2 0.3 1.0 1.1
destroy 0.1    slab 0 [#.##]  slab 1 [##..]
destroy 0.3    slab 0 [#.#.]  slab 1 [##..]
create         slab 0 [###.]  slab 1 [##..]      returns 0.1: lowest slab, lowest slot
```

The last handle of the first line is slab 1, slot 1, class 0: `(0 << 31) | (1 << 8) | 1
= 0x00000101`.

Now delete the two items of slab 1. It is empty and slab 0 still has a free slot, so
slab 1 goes back to the backing allocator. Delete the rest: slab 0 is empty too, but it
is the *only* free space left, so it stays; otherwise a workload at a slab boundary
would allocate and free a slab on every other operation.

Vacuum on three sparse slabs (the letters are node names):

```
before         slab 0 [a..b]  slab 1 [...c]  slab 2 [d.ef]     6 free slots >= 4
victim         slab 1 (fewest used slots)
relocate c     slab 0 [ac.b]  slab 1 [....]  slab 2 [d.ef]     c: handle 1.3 -> 0.1
release        slab 0 [ac.b]                 slab 2 [d.ef]
```

One node moved, one handle rewritten (in c's parent), one slab returned.

The buddy allocator on a 1024-byte heap with 64-byte minimum blocks:

```
alloc 100      [128 used][128 free][256 free][512 free]        1024 -> 512 -> 256 -> 128
alloc 60       [128 used][64 used][64 free][256 free][512 free]
free the 128   [128 free][64 used][64 free][256 free][512 free]   buddy is split: no merge
free the 64    [1024 free]                                        64+64, 128+128, 256+256, 512+512
```

The buddy of the block at minimum-block index `i` with order `k` is at `i XOR 2^k`.

## Code walk-through

Run it:

```
cd zig  && zig build test --summary all && zig build run
cd zig  && zig build test-single-threaded --summary all   # adds the BrkAllocator example
cd zig  && zig build test-libc --summary all              # adds the c_allocator example
cd rust && cargo test && cargo run
```

Both `run` programs print exactly [`expected_output.txt`](expected_output.txt). The
part that shows the tree living on slabs:

```
== 2. B-tree on two slab pools (M = 4, 4 slots per slab) ==
put 10 20 5 6 12 30 7 17 3 25 1 15
I0.1 [10]
  I0.0 [6]
    L0.0 [1 3 5]
    L0.3 [7]
  I0.2 [20]
    L0.1 [12 15 17]
    L0.2 [25 30]
leaf slabs:     0[####]
interior slabs: 0[###.]
node sizes:     leaf 56 bytes, interior 72 bytes
```

`L0.3` is "leaf pool, slab 0, slot 3". (The tree is one level taller than chapter
04's for the same keys, because this chapter splits full nodes on the way down.)

### Zig

| File | What it holds |
|------|---------------|
| `src/slab.zig` | `Handle`, `SlabPool(T, slots)`: `create`, `get`, `destroy`, `reserve`, vacuum, and an `allocator()` adapter |
| `src/btree.zig` | `BTree(M, slots)` on a leaf pool and an interior pool: `get`, `put`, `delete`, `range`, `vacuum`, `validate` |
| `src/static_allocator.zig` | `StaticAllocator`: init, static, deinit |
| `src/buddy.zig` | `BuddyAllocator(heap_log2, min_log2)` with an `allocator()` |
| `src/tour.zig` | the allocator tour (tests only) |
| `src/main.zig` | the fixed scenario |

**`slab.zig`.** `Handle` is a `packed struct(u32)`, so the bit layout above is the type
definition. A `Slab` is `{ free: [words]u64, used, items: [slots]T }`, bitmap first, as
in DuckDB. `create` scans from `hint` (no slab below it has room) for a slab with a
free slot and takes the lowest set bit with `@ctz`. `get` asserts that the handle's
class matches the pool and that the slot's bit is clear, so a stale handle or a leaf
handle used on the interior pool stops the program in a safe build. `destroy` sets the
bit and applies the "release unless it is the last free space" rule. With
`release_empty = false` the pool never returns memory: that is the static policy.

The pool also offers `allocator()`, a real `std.mem.Allocator` for requests that fit
one slot. Its `free` receives a pointer, so it must find the slab by address and could
never relocate anything: the interface gives up what handles were for.

**`btree.zig`.** `Interior` is `{ head: Leaf, children: [M]Handle }`, so `head(h)`
returns the keys and values of either kind and the class bit picks the pool. The tree
uses **top-down splitting** (the textbook alternative to chapter 04's bottom-up
insert): on the way down, every full node is split before it is entered. Each split
allocates the new sibling first and only then moves keys, so a failed allocation
leaves a valid tree without the key and returns `error.OutOfMemory`;
`checkAllAllocationFailures` proves it for every allocation of a 40-key build.
Top-down splitting needs an even `M`, asserted at comptime. `delete` is CLRS top-down
deletion and never allocates. `deinit` does not walk the tree: dropping the slabs
drops the nodes.

`vacuum` asks each pool for a victim, walks the tree in preorder and replaces every
child handle that points into a victim by the result of `relocate`. A node is
referenced from exactly one place (its parent, or `root`), so one write per moved
node is enough.

`validate` checks the B-tree invariants and the allocator: every reachable handle is
live and the number of reachable nodes equals the number of live slots, so a leaked
or double-freed node fails `validate` under any backing allocator.

**`static_allocator.zig`.** A wrapper is four functions that forward to the parent's
`rawAlloc`, `rawResize`, `rawRemap` and `rawFree`. This one adds a state. `init`
passes everything, but the first `free` ends it (state `deinit`). `static` refuses
`alloc`, `resize` and `remap`; a `free` there is counted as a bug and still performed.
`deinit` passes only `free`. Because a free ends `init`, nothing may grow by
reallocation during start-up: `SlabPool.reserve` sizes its slab directory once,
exactly, before it creates the first slab. Section 4 of the program stacks all of it
in one fixed buffer:

```
64 KiB buffer -> BuddyAllocator -> StaticAllocator -> two SlabPools -> BTree
```

After `freeze()` it runs 5000 operations, then fills the tree until the interior pool
cannot supply the nodes for a root split: one refused request, a clean `OutOfMemory`, a valid tree. After `thaw()`
and `deinit` the buddy heap is one free block again.

**`buddy.zig`.** All bookkeeping (state, order, free-list links) lives in side arrays
indexed by minimum-block number, so the allocator never writes into the memory it
manages. `allocBlock(k)` takes the smallest free block of order at least `k` and
splits it down; `freeBlock` merges upwards while the buddy is free *and* whole. The
`std.mem.Allocator` face maps `len` and `alignment` to an order, resizes in place when
the new length still fits the block, and tracks `requested` against `granted` bytes.

### Rust

| File | What it holds |
|------|---------------|
| `src/slab.rs` | `Handle(u32)`, `SlabPool<T, S>` with a slab `budget` and `freeze` |
| `src/btree.rs` | `BTree<M, K, S>` (K = M - 1) |
| `src/buddy.rs` | `Buddy`, owning a `Vec<u8>` and handing out offsets |
| `src/idioms.rs` | the Rust counterpart of the tour (tests only) |
| `src/main.rs` | the fixed scenario |

Same structure, same names, same tests, same output.

### Differences

- **No allocator interface.** `std::alloc::Allocator` is unstable. The pool is an
  ordinary owning container; "the backing allocator may fail" becomes a `budget` of
  slabs that may still be created, `freeze()` sets it to zero, and the error is
  `OutOfNodes`. There is no `StaticAllocator`: the freeze is a property of the pool.
  The buddy allocator returns byte **offsets** into a `Vec<u8>` it owns.
- **Handles are what the borrow checker wants.** Zig's `splitChild` holds pointers to
  parent, left and right at once: three `&mut` into one pool in Rust. The port copies
  a 56-byte node out, edits it and writes it back; `unsafe_code = "forbid"`.
- **Array sizes.** Zig computes `[M - 1]u64` in the type. Stable Rust takes `K` as a
  second const parameter and checks `K + 1 == M` in a `const` block.
- **Stale handles and double frees.** Zig catches them with `assert` (nothing in
  `ReleaseFast`). Rust always panics, and tests expect the panics.
- **Leak checks and failure injection.** Zig uses `std.testing.allocator` and
  `checkAllAllocationFailures`. Rust has `Drop`, `validate` (live slots against
  reachable nodes) and a loop over every budget.

## In real databases

**DuckDB `FixedSizeAllocator`** (ART nodes; DuckDB has no B-tree). Each ART owns nine
allocators, one per node type (`duckdb/src/include/duckdb/execution/index/art/art.hpp:49`).
A buffer is a bitmask followed by segments, and the constructor works out how many
segments fit when each 64-bit mask word is followed by up to 64 segments
(`duckdb/src/execution/index/fixed_size_allocator.cpp:13-54`). `New` allocates from a
cached buffer with free space (`:56-94`). `AllocateSegment` first tries slot number
`segment_count`, so a fresh buffer fills in order, then scans the mask words and finds
the lowest set bit with a six-step binary reduction
(`duckdb/src/execution/index/fixed_size_buffer.cpp:145-199`); this chapter uses `@ctz`.
A set bit means free. `Free` keeps an empty buffer when it is the only one with free
space (`fixed_size_allocator.cpp:121-128`), the rule copied here. A pointer is 64 bits:
a 32-bit buffer id, a 24-bit offset and 8 bits of metadata that carry the node type
and a gate-status bit (`duckdb/src/include/duckdb/execution/index/index_pointer.hpp:19-24`); the 32-bit
handle of this chapter is a smaller cousin (23 + 8 + 1 bits). Dereferencing looks the
buffer up in a map and computes `offset * segment_size + bitmask_offset`
(`duckdb/src/include/duckdb/execution/index/fixed_size_allocator.hpp:50-54`).

**DuckDB vacuum.** `InitializeVacuum` proceeds only if the buffers that could be saved
are at least 10% of the allocator's in-memory size (`fixed_size_allocator.hpp:31`,
`fixed_size_allocator.cpp:195-258`) and selects the emptiest buffers. `VacuumPointer`
allocates a new segment and `memcpy`s the node (`:269-283`); the tree walk rewrites the
pointer in the parent and restores its type and gate status
(`duckdb/src/execution/index/art/art.cpp:1326-1343`). This
chapter's version takes one victim per pool per pass and uses the simpler threshold
"one whole slab can be saved".

**TigerBeetle `NodePool`** (`tigerbeetle/src/lsm/node_pool.zig:10-84`; no B-tree
either, the pool serves the manifest's segmented arrays). One buffer, one bitset,
`acquire` and `release` by pointer, exhaustion is fatal, `deinit` asserts that
everything was released. It is not a `std.mem.Allocator`; one is used only in `init`.
`release_empty = false` plus `reserve` is that policy on this chapter's pool.

**TigerBeetle `StaticAllocator`** (`tigerbeetle/src/static_allocator.zig:14-23` for the
three states, `:58-62` for `alloc`). The replica flips it after start-up
(`tigerbeetle/src/vsr/replica.zig:739`) and again before shutdown (`:1472`). The
original asserts; this chapter's version refuses and counts so that a test can watch.
Both end `init` at the first `free` ("Once you start freeing, you don't stop", `:76-82`).
TigerBeetle's documentation separates this from "an arena with a limit": every object
type has an explicit upper bound, so the pools never run out
(`tigerbeetle/docs/ARCHITECTURE.md:203-206`). Section 4 of the demo fills the pool
until it fails, the arena-with-a-limit behaviour, on purpose.

**Buddy allocation** is textbook material (Knuth, TAOCP volume 1, section 2.5). None
of the six code bases studied here uses one for its index.

**Postgres and Turso** B-tree nodes are disk pages: the "allocator" is the page free
list and the buffer pool of chapter 09, and a page number is a handle in this sense.

## Allocator notes

**Choices in this chapter.** Nodes come from `SlabPool`: they are fixed-size and the
tree wants relocation and 4-byte links. The pool takes its slabs from the `Allocator`
it is given: `std.testing.allocator` in tests (a leaked slab fails the test),
`init.gpa` in sections 1 to 3 of the demo, the buddy-on-a-fixed-buffer stack in
section 4. Lifetimes are nested: the buffer outlives the buddy heap, which outlives
the pools, which outlive every handle. With other choices: a general-purpose
allocator per node pays a header and a size-class lookup and can never compact; an
`ArenaAllocator` cannot give back the nodes that deletes free; `page_allocator` per
node is a system call per insert.

**The tour** (`zig/src/tour.zig`, at least one test per row; "free one item" means the
memory becomes reusable before the allocator is torn down):

| Allocator | What it is | Cost model | Free one item? | Thread safety | Use in a B-tree engine |
|---|---|---|---|---|---|
| `std.testing.allocator` | A `SafeAllocator` owned by the test runner | Slow, checks everything | Yes | Yes | Every unit test: leaks and double frees fail the run |
| `ArenaAllocator` | Bump allocation in chunks from a child allocator | Pointer bump; `deinit` or `reset` frees all at once | No (only the latest allocation) | Yes if the child is | Bulk-loaded read-only tree; per-query scratch |
| `FixedBufferAllocator` | Bump allocation in a caller buffer | Pointer bump, no system calls, `OutOfMemory` when full | No (only the latest allocation) | No; `threadSafeAllocator()` is | Bounded scratch for one split or merge |
| `BufferFirstAllocator` | A fixed buffer first, a fallback allocator after | Bump while the buffer lasts, then the fallback's cost | Fallback items yes; buffer items as above | No | Copying search keys: short ones never touch the heap |
| `page_allocator` (`PageAllocator.map`, `unmap`) | One `mmap` per allocation, `munmap` per free | A system call each way; page granularity | Yes | Yes | Backing memory for the buffer pool or an arena, taken once |
| `smp_allocator` (`SmpAllocator`) | General purpose, per-thread free lists in power-of-two classes; large requests mapped directly | Fast paths without contention | Yes | Yes (needs a multi-threaded build) | The general allocator of a release build |
| `SafeAllocator` | The checking general-purpose allocator (`init.gpa` in debug) | Slow; footer per allocation; does not reuse memory when its backing allocator does not | Yes | Yes | Debug builds; finding leaks and use-after-free in node code |
| `DebugAllocator` | Its deprecated predecessor | Slow, bucketed | Yes | Yes by default (`thread_safe` option) | Nowhere new; shown because old code uses it |
| `MemoryPool(T)` | One item type, free list through freed items, memory from an internal arena | O(1) create and destroy, no header | Yes, to the pool | No | Nodes of a pointer-based tree (chapters 04, 05) |
| `memory_pool.Extra(T, .{ .growable = false })` | The same, all memory taken in `initCapacity` | O(1); `create` fails when empty | Yes, to the pool | No | Fixed set of buffer-pool frames |
| `memory_pool.Aligned(T, alignment)` | The same pool, items over-aligned | As `MemoryPool` | Yes, to the pool | No | Nodes on cache-line boundaries (chapter 25) |
| `brk_allocator` (`BrkAllocator`); `wasm_allocator` (`WasmAllocator`) is an alias of it in 0.17.1 | Grows the program break; size-class free lists | Fast, no locks | Yes | Single-threaded builds only | A single-threaded or WebAssembly build |
| `c_allocator` | libc `malloc` and `free` | Whatever the libc does | Yes | As the libc's `malloc` | Engine embedded in a C program, sharing its heap |
| `std.testing.FailingAllocator` | Wrapper that lets N allocations succeed, then fails every later one; counts | Child cost plus counters | Via the child | No | Aim an `OutOfMemory` at one step of an insert |
| `Allocator.failing`, `std.testing.failing_allocator` | Fails every request | Free | Nothing to free | Yes (no state) | Prove a path (lookup, delete) never allocates |
| `checkAllAllocationFailures` | Runs a function once per allocation, failing from that one on | (allocations + 1) runs | n/a | n/a | Exhaustive `OutOfMemory` test of every insert path |
| `std.mem.ValidationAllocator` (`validationWrap`) | Wrapper that asserts the interface contract: no zero-length request, returned pointers aligned | Child cost plus asserts | Via the child | As the child | Around an allocator you wrote yourself (here: the buddy heap) |

The list was checked against the 0.17.1 sources: the nine files of `lib/std/heap/`,
the instances in `heap.zig`, `std.testing`, and the two in `std.mem`. Not run:
`std.os.uefi.pool_allocator`, which exists only on UEFI firmware. `main` also receives
`init.gpa` (a `SafeAllocator` in debug and safe builds) and `init.arena`.

Two rows need a special build, which is why `build.zig` has three test steps. In the
default build the two tests report "skipped":

| Step | Extra flag | Result on this machine |
|---|---|---|
| `zig build test` | none | 51 passed, 2 skipped (`brk_allocator`, `c_allocator`) |
| `zig build test-single-threaded` | `single_threaded = true` | 51 passed, 2 skipped (`smp_allocator`, `c_allocator`) |
| `zig build test-libc` | `link_libc = true` | 52 passed, 1 skipped (`brk_allocator`) |

**The Rust side** (`rust/src/idioms.rs`):

| Idiom | Zig twin | Use |
|---|---|---|
| `TypedArena<T>`: `Vec<T>` + `u32` ids, dropped at once | `ArenaAllocator` | Bulk-built trees |
| `GenSlab<T>`: free list + generation-checked handles | `MemoryPool`, plus a check Zig's pool lacks | Long-lived handles held by cursors or caches |
| `Bump`: `Vec<u8>` with a capacity, `(offset, len)` references | `FixedBufferAllocator` | Variable-length keys of one node or operation |
| `FixedPool<T>`: fixed capacity, `acquire` fails when empty | non-growable `MemoryPool`, `NodePool` | Buffer-pool frames |

## Pitfalls

- **Reading the bitmap the wrong way round.** Here, in DuckDB and in TigerBeetle's
  `NodePool` a set bit means *free*. Many other bitmaps mean "used".
- **Keeping a handle across a vacuum, or a pointer across a `destroy`.** A handle is
  valid until its node is freed *or moved*. Cursors must re-find their node by key
  after a vacuum (chapter 08's re-seek).
- **Stale handles are not detected by a bitmap.** If slot 0.1 is freed and reused,
  the old handle opens the new occupant; the pool only catches a handle whose slot is
  free right now. Generation counters (`GenSlab` in `idioms.rs`) close the gap at 4
  more bytes per handle.
- **Slab sizes.** One live node keeps a whole slab alive; small slabs cost directory
  entries and allocator calls.
- **Growing during start-up under a `StaticAllocator`.** The first `free` ends `init`,
  and a list that grows frees its old buffer: the next allocation is refused although
  the program is still starting up. Reserve final sizes (`initCapacity`,
  `ensureTotalCapacityPrecise`), and call `SlabPool.reserve` once per pool.
- **"Static" is not "arena with a cap".** Freezing proves that memory does not grow,
  not that the reserved amount is enough; that needs an upper bound for every
  structure, computed before start-up.
- **Buddy rounding.** A request of 65 bytes takes 128. Sizes just above a power of two
  waste almost half; choose slab sizes that are powers of two.
- **Top-down splitting splits early.** Ascending inserts leave every node at its
  minimum (42 keys reach height 5 in the demo with M = 4).

## Exercises

1. (easy) A pool has 8 slots per slab and holds 3 slabs with maps `[##.#####]`,
   `[...#....]`, `[########]`. Which handle does the next `create` return? Does
   `vacuumBegin` pick a victim, and which?
2. (easy) By hand, on a 1024-byte buddy heap with 64-byte minimum blocks: allocate
   200, 200, 60, then free the first 200. Draw the heap. Can a request for 500 succeed?
3. (medium) Add a generation counter to `SlabPool` so that a handle to a freed and
   reused slot is detected. What does the handle look like if it must stay 32 bits?
4. (medium) The tree's `vacuum` moves at most one slab per pool per call. Change
   `vacuumBegin` to select several victims at once, as DuckDB does. What must
   `create` then guarantee?
5. (hard) Moving a node in this tree costs one handle update. How many updates would it
   cost in (a) a B+tree whose leaves are doubly linked, (b) a tree with parent
   handles in every node? What does that say about which structures can afford
   compaction by relocation?

Solutions: [solutions.md](solutions.md).

## Links

- Previous: [25. Cache-conscious search and layout](../25-cache-conscious-search-and-layout/README.md)
- Next: [27. B-tree vs LSM](../27-btree-vs-lsm/README.md)
- Visualization: [viz/index.html](viz/index.html) (slab memory map, pointer vs handle,
  vacuum, and "Static memory": reserve, freeze, fill until refused) and
  [viz/buddy.html](viz/buddy.html) (buddy allocator)

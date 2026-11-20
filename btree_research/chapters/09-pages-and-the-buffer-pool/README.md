# Chapter 09: Pages and the buffer pool

Part I kept every node in memory and linked nodes with pointers or array indices. From
this chapter on the tree lives in a file. Before a single key goes to disk we need two
pieces of plumbing that every later chapter stands on: something that turns a file into
numbered pages, and something that keeps a few of those pages in memory.

## What you will learn

- Why a database file is an array of fixed-size pages, and why a page number works as a
  pointer that survives a restart.
- How the forms of "pointer to a node" compare: raw pointer, array index, page id, and
  the wider forms real engines use.
- What a buffer pool is: frames, the page table, pin counts, the dirty flag.
- How CLOCK eviction picks a victim with one bit per frame, and what it refuses to evict.
- Where the pool's memory comes from and why nothing allocates after start-up.

Prerequisites: chapter 01 (count page reads, not comparisons) and chapter 07 (nodes
addressed by index instead of by pointer). No B-tree code appears in this chapter; the
pager and the pool know nothing about keys.

## The idea in plain words

**A file is an array of pages.** Pick a page size (4096 bytes in this guide). Page `n`
is the bytes from `n * 4096` up to `(n + 1) * 4096`. Reading page 5 is one positional
read of 4096 bytes at offset 20480. Nothing else is needed to find it: no directory, no
index. The file only ever grows by whole pages, so its size divided by 4096 is the page
count.

**A page id is a pointer.** A memory address is meaningless after the process exits. A
page id means the same thing tomorrow. So an on-disk node refers to its children by page
id, and "follow the pointer" becomes "get me page 17". The forms a node reference can
take:

| Form | Size | Valid after restart | To follow it | Where |
|---|---|---|---|---|
| Raw pointer | 8 bytes | no | load the address | chapters 03 to 06 |
| Index into an array of nodes | 4 bytes | only if the array is saved as is | `nodes[i]` | chapter 07 |
| Page id | 4 bytes | yes | ask the buffer pool (may read the file) | this chapter; Postgres `BlockNumber` is a `uint32` (`postgres/src/include/storage/block.h:31`); Turso stores `left_child_page: u32` (`turso/core/storage/sqlite3_ondisk.rs:814`) |
| Page id + slot in the page | 6 bytes in Postgres | yes | fetch the page, then index its slot array | Postgres `ItemPointerData`, the heap tuple id (`postgres/src/include/storage/itemptr.h:36`); slots are chapter 10 |
| Buffer id + offset + type tag | 8 bytes | yes | look up the buffer, add the offset | DuckDB `IndexPointer`: 32-bit buffer id, 24-bit offset, 8 bits of metadata (`duckdb/src/include/duckdb/execution/index/index_pointer.hpp:19-24`) |
| Block address + checksum of the target | 8 + 16 bytes, 40 with padding | yes, and verifiable | read the block, compare its checksum with the one in the pointer | TigerBeetle grid (`tigerbeetle/src/vsr/grid.zig:1421-1446`, see `research/tigerbeetle.md` section 9) |

The price of a page id is the "ask" step. Reading the file on every hop would be far too
slow, so we keep recently used pages in memory.

**A buffer pool is a fixed set of page-sized memory slots called frames.** A hash table
(the page table) says which page currently sits in which frame. To use a page you
*fetch* it: if it is in a frame (a **hit**) you get the frame at no I/O cost; if not (a
**miss**) the pool picks a frame, reads the page into it, and hands it over.

Three small facts per frame make this safe:

- **Pin count.** Fetching pins the page; you unpin it when you are done. A frame with a
  pin count above zero is never reused for another page, so the bytes you are looking at
  cannot change into a different page underneath you.
- **Dirty flag.** When you unpin, you say whether you modified the page. A dirty frame
  holds the only copy of those changes, so it must be written to the file before the
  frame is reused.
- **Referenced bit.** Set every time the page is fetched. It is all the history the
  eviction policy keeps.

**CLOCK eviction.** When a miss finds no empty frame, some cached page must go. The
ideal victim is the page that will not be needed for the longest time; we cannot know
that, so we guess "not used recently". CLOCK does it with a hand that sweeps the frames
in a circle. At each frame:

- pinned: skip it;
- referenced bit set: clear the bit and move on (the page gets a *second chance*);
- referenced bit clear: this is the victim. Write it back if dirty, then reuse the frame.

A page survives a visit of the hand only if someone fetched it since the previous visit.
That approximates "least recently used" without keeping an ordered list that every fetch
would have to update. If the hand goes round twice without finding a victim, every frame
is pinned and the fetch fails: the pool is too small for what the caller is doing, or
somebody forgot to unpin.

## A worked example by hand

Four frames, pages 0 to 7 on disk, hand at frame 0. Notation: `page flags`, with
`R` = referenced and `D` = dirty.

1. Fetch and release 0, 1, 2, 3 (page 1 is modified). Each is a miss into an empty
   frame. Frames: `0 R`, `1 RD`, `2 R`, `3 R`. The hand has gone once round and is at
   frame 0 again.
2. Fetch 1: a hit. No I/O. The bit was already set.
3. Fetch 4: a miss with no empty frame. The hand clears the bits of frames 0, 1, 2 and 3,
   arrives at frame 0 again, finds the bit clear and evicts page 0. Frames: `4 R`,
   `1 D`, `2`, `3`; hand at 1. Note that the hit in step 2 did not help page 1: when
   every bit is set, the first sweep is plain first-in first-out.
4. Fetch 1 again: a hit, bit set. Frames: `4 R`, `1 RD`, `2`, `3`.
5. Fetch 5: the hand is at frame 1. Page 1 is referenced, so it only loses its bit: the
   second chance. Frame 2 (page 2, bit clear) is the victim. Page 2 is clean, so nothing
   is written. Hand at 3.
6. Fetch 3 and keep it pinned.
7. Fetch 6: the hand is at frame 3, which is pinned: skipped. Frame 0 (page 4) loses its
   bit. Frame 1 (page 1) has no bit and no pin: victim. It is dirty, so the pool writes
   page 1 to the file first, then loads page 6 into frame 1. Page 6 is then modified and
   released.
8. Pin 4, 5 and 6 as well, then fetch 7: two full turns find nothing to evict and the
   fetch fails with `AllFramesPinned`. The pool is unchanged. After unpinning, the same
   fetch succeeds.

This is exactly the trace of part 2 of the program below, and of the
[visualization](viz/index.html).

## Code walk-through

Both languages have the same four layers, one file each, and the same tests.

| Layer | Zig | Rust | Job |
|---|---|---|---|
| Storage | `zig/src/storage.zig` | `rust/src/storage.rs` | bytes at offsets: `read`, `write`, `size`, `sync` |
| Pager | `zig/src/pager.zig` | `rust/src/pager.rs` | pages by id: `allocatePage`, `readPage`, `writePage`, `sync`, counters |
| Buffer pool | `zig/src/buffer_pool.zig` | `rust/src/buffer_pool.rs` | `fetchPage`, `newPage`, `unpin`, `flushPage`, `flushAll`, `validate` |
| Demo, workload | `demo.zig`, `workload.zig` | `demo.rs`, `workload.rs` | the printed scenario; seeded model test |

### Zig

**Storage** is an interface built the way `std.mem.Allocator` is built: a type-erased
pointer and a table of four function pointers. `FileStorage` implements it with
`readPositionalAll` / `writePositionalAll` / `sync` on a `std.Io.File`; `MemStorage`
implements it with an `ArrayList(u8)` and two countdowns that make reads or writes fail
on request.
Function pointers need one concrete error set, so every backend maps its failures to
`error{ ShortRead, StorageFailure }`. Chapter 21 adds a third backend that tears and
drops writes; nothing above this interface will change.

**Pager** is thin on purpose:

```zig
pub fn readPage(self: *Pager, id: PageId, out: *Page) Error!void {
    if (id >= self.page_count) return error.PageOutOfRange;
    try self.storage.read(offsetOf(id), out);
    self.stats.reads += 1;
}
```

`allocatePage` appends a zero page and increments `page_count` only after the write
succeeded; when the 32-bit id space is used up it returns `error.FileFull`. There is no
file header and no free list here: chapter 12 puts a metapage in
page 0 and chapter 13 adds the free list.

**BufferPool.** `init` allocates three things: one slab of `frame_count * 4096` bytes
aligned to 4096, an array of `Frame { page_id, pin_count, referenced, dirty }`, and the
page table. Frame `f` is `slab[f * 4096 ..][0..4096]`; `fetchPage` returns it as
`*align(4096) [4096]u8`.

```zig
pub fn fetchPage(self: *BufferPool, id: PageId) Error!PagePtr {
    if (id >= self.pager.pageCount()) return error.PageOutOfRange;
    if (self.page_table.get(id)) |f| {            // hit
        const frame = &self.frames[f];
        frame.pin_count += 1;
        frame.referenced = true;
        self.stats.hits += 1;
        return self.frameBytes(f);
    }
    self.stats.misses += 1;                        // miss
    const f = try self.takeFrame();                // CLOCK; returns an empty frame
    errdefer self.hand = f;                        // failed read: reuse f next time
    try self.pager.readPage(id, self.frameBytes(f));
    self.install(f, id);                           // pin = 1, referenced, clean
    return self.frameBytes(f);
}
```

`takeFrame` is the clock sweep described above, bounded by `2 * frame_count` steps. The
error paths are where the order of steps matters:

- A dirty victim is written **before** it is removed from the page table. If the write
  fails, the function returns with the page still cached and still dirty; nothing is
  lost. The test "a failed write-back keeps the page cached and dirty" injects that
  failure. The hand stays on that frame, so later misses retry the same write and fail
  until the storage recovers: the pool stops evicting rather than skip a page it could
  not save.
- `newPage` takes its frame **before** it grows the file, so `AllFramesPinned` cannot
  leave an allocated page that nobody knows about.
- If the read fails after `takeFrame` has emptied a frame, the `errdefer` puts the hand
  back on that frame. Otherwise the next miss would start one frame further on and evict
  a second page while an empty frame sat unused.

A pool call that fails takes no pin and leaves the pool valid.

The page table is a small hand-written hash table (`PageTable`, about 90 lines): open
addressing, linear probing, `2 * frame_count` slots rounded up to a power of two. It is
not `std.AutoHashMapUnmanaged` because of how the pool uses it: one removal and one
insertion per eviction, forever, at a fixed capacity. The std map marks a removed entry
with a tombstone and clears tombstones only when it grows. Ours never grows, so after
enough evictions it has no free slot left and every miss probes the whole table.
`PageTable` deletes by shifting the following entries of the probe run back into the gap,
so there are no tombstones and a lookup stays one short probe.

`validate` checks four invariants: frames and page table agree in both directions, empty
frames carry no pin or flag, the hand is in range, and no cached page id is beyond the
end of the file. `deinit` asserts that no pin is left, which turns a forgotten `unpin`
into a test failure, and it does not flush: dropping a pool without `flushAll` loses the
dirty pages, exactly like a crash.

That assert has a consequence for every caller. If a function returns an error while it
still holds a pin, the caller's `defer pool.deinit()` trips the assert and the program
aborts instead of reporting the error. So a pin is released on the error path too:

```zig
const page = try pool.fetchPage(id);
errdefer pool.unpin(id, false);     // runs only if a later `try` fails
try somethingThatCanFail(page);
pool.unpin(id, true);
```

`workload.run` does this for its long-lived pins; a test injects a failure at each of
its first 150 reads and writes and checks that no pin is left.

### Rust, and the differences

- **Interface.** The hand-built vtable becomes `trait Storage` used as `Box<dyn Storage>`.
- **Errors.** Zig merges error sets (`Pager.Error = Storage.Error || error{...}`). Rust
  has no set union, so one flat `enum Error` carries the same six names.
- **Ownership.** Zig's pool borrows a `*Pager` that the caller owns. Rust's pool owns its
  `Pager` (`pool.pager()`, `pool.into_pager()`), and the pager owns its storage.
- **Looking at the disk from a test.** In Zig a test keeps the `MemStorage` and passes a
  `Storage` that points at it. In Rust the pager owns the box, so `MemStorage` is a
  cloneable handle to shared bytes (`Rc<RefCell<..>>`): the test keeps one clone.
- **Pin versus borrow.** This is the difference that matters. Zig's `fetchPage` returns a
  pointer that stays usable until `unpin`, across any number of other pool calls. A
  `&mut Page` borrowed from `&mut self` ends at the next pool call. So in Rust a pin is
  not a borrow: `fetch_page(id)` pins and lends the page for the moment, and while the
  pin lasts `page(id)`, `page_mut(id)` and `page_pair_mut(a, b)` lend it again (a split
  needs two pages at once; `page_pair_mut` uses `get_disjoint_mut`). Touching a page
  without a pin is a silent bug in Zig and a panic in Rust (test
  `using_a_page_after_unpin_panics`).
- **Frames.** One aligned slab in Zig; `Vec<Box<[u8; 4096]>>` in Rust, each frame its own
  allocation made once in `new`.
- **Page table.** Rust keeps `std::collections::HashMap`. It has tombstones too, but
  clears them by rehashing: in place while the map is at most half full, into a larger
  allocation otherwise. `new` therefore reserves `2 * frame_count`; with `frame_count` a
  100-frame pool reallocated its table (test
  `the_page_table_does_not_grow_while_the_pool_cycles_through_many_pages`).
- **Leaked pins and error paths.** Dropping the Rust pool checks nothing. Rust has no
  `errdefer`, so a `Drop` that panicked on a leftover pin would turn any `?` between a
  fetch and its unpin into a panic. Instead `workload::run` releases its pins by hand
  before it returns an error, and the tests assert `pinned_frames() == 0` themselves.

### The program's output

`zig build run` and `cargo run` print exactly `expected_output.txt` (a test in each
language checks it):

```text
Chapter 09: pages and the buffer pool

== Part 1: a file is an array of pages ==
created ch09_demo.db: 0 pages
allocated 8 pages: file size = 32768 bytes (8 * 4096)
  pager: reads=0 writes=8 allocations=8 syncs=1
reopened: 8 pages
page 5 is at byte offset 20480; its id field says 5, version 0
page 8 does not exist: error.PageOutOfRange

== Part 2: a 4-frame buffer pool with CLOCK eviction ==
frame cell = page, pin count, R = referenced, D = dirty; hand = next frame the clock looks at

 #  op       outcome                               f0       f1       f2       f3       hand
 1  fetch 0  miss: load into empty f0              0 p1 R-  -        -        -        1
 2  unpin 0  released, page unchanged              0 p0 R-  -        -        -        1
 3  fetch 1  miss: load into empty f1              0 p0 R-  1 p1 R-  -        -        2
 4  edit 1   version -> 1, released dirty          0 p0 R-  1 p0 RD  -        -        2
 5  fetch 2  miss: load into empty f2              0 p0 R-  1 p0 RD  2 p1 R-  -        3
 6  unpin 2  released, page unchanged              0 p0 R-  1 p0 RD  2 p0 R-  -        3
 7  fetch 3  miss: load into empty f3              0 p0 R-  1 p0 RD  2 p0 R-  3 p1 R-  0
 8  unpin 3  released, page unchanged              0 p0 R-  1 p0 RD  2 p0 R-  3 p0 R-  0
 9  fetch 1  hit in f1                             0 p0 R-  1 p1 RD  2 p0 R-  3 p0 R-  0
10  unpin 1  released, page unchanged              0 p0 R-  1 p0 RD  2 p0 R-  3 p0 R-  0
11  fetch 4  miss: evict page 0 (f0)               4 p1 R-  1 p0 -D  2 p0 --  3 p0 --  1
12  unpin 4  released, page unchanged              4 p0 R-  1 p0 -D  2 p0 --  3 p0 --  1
13  fetch 1  hit in f1                             4 p0 R-  1 p1 RD  2 p0 --  3 p0 --  1
14  unpin 1  released, page unchanged              4 p0 R-  1 p0 RD  2 p0 --  3 p0 --  1
15  fetch 5  miss: evict page 2 (f2)               4 p0 R-  1 p0 -D  5 p1 R-  3 p0 --  3
16  unpin 5  released, page unchanged              4 p0 R-  1 p0 -D  5 p0 R-  3 p0 --  3
17  fetch 3  hit in f3                             4 p0 R-  1 p0 -D  5 p0 R-  3 p1 R-  3
18  fetch 6  miss: write back + evict page 1 (f1)  4 p0 --  6 p1 R-  5 p0 R-  3 p1 R-  2
19  edit 6   version -> 1, released dirty          4 p0 --  6 p0 RD  5 p0 R-  3 p1 R-  2
20  fetch 4  hit in f0                             4 p1 R-  6 p0 RD  5 p0 R-  3 p1 R-  2
21  fetch 5  hit in f2                             4 p1 R-  6 p0 RD  5 p1 R-  3 p1 R-  2
22  fetch 6  hit in f1                             4 p1 R-  6 p1 RD  5 p1 R-  3 p1 R-  2
23  fetch 7  error.AllFramesPinned                 4 p1 R-  6 p1 RD  5 p1 R-  3 p1 R-  2
24  unpin 3  released, page unchanged              4 p1 R-  6 p1 RD  5 p1 R-  3 p0 R-  2
25  unpin 4  released, page unchanged              4 p0 R-  6 p1 RD  5 p1 R-  3 p0 R-  2
26  unpin 5  released, page unchanged              4 p0 R-  6 p1 RD  5 p0 R-  3 p0 R-  2
27  unpin 6  released, page unchanged              4 p0 R-  6 p0 RD  5 p0 R-  3 p0 R-  2
28  fetch 7  miss: evict page 5 (f2)               4 p0 --  6 p0 -D  7 p1 R-  3 p0 --  3
29  unpin 7  released, page unchanged              4 p0 --  6 p0 -D  7 p0 R-  3 p0 --  3

final state (the visualization's self-test checks these lines):
  frame 0: page=4 pin=0 referenced=0 dirty=0
  frame 1: page=6 pin=0 referenced=0 dirty=1
  frame 2: page=7 pin=0 referenced=1 dirty=0
  frame 3: page=3 pin=0 referenced=0 dirty=0
  hand=3
  pool:  hits=6 misses=9 evictions=4 writebacks=1
  pager: reads=8 writes=1 allocations=0 syncs=0
after flushAll:
  pager: reads=8 writes=2 allocations=0 syncs=1
reopened; versions on disk: 0 1 0 0 0 0 1 0

== Part 3: 5000 page accesses over 64 pages (80% to 8 hot pages), in-memory storage ==
frames   hits  misses  evictions  writebacks  file reads  file writes
     4   1567    3433       3429        1145        3433         1145
     8   2886    2114       2106         919        2114          921
    16   4074     926        910         394         926          403
    32   4443     557        525         219         557          233
every run ended with the same page contents as the oracle
```

Things to read off: step 23 counts as a miss but reads nothing (9 misses, 8 reads); page
6 was edited at step 19 but reaches the file only at `flushAll`; in part 3 the same 5000
accesses cost 3433 file reads with 4 frames and 557 with 32; `file writes` can exceed
`writebacks` because each row is printed after a final `flushAll`. The part 3 workload keeps
up to two pages pinned across operations, so the 4-frame pool often has only two frames
it can reuse. Part 3 runs on `MemStorage` and parts 1 and 2 on a real file, through the
same pager and pool code.

## In real databases

**Turso** (`research/turso.md` section 12). The B-tree never touches the file; it asks
the pager for a page and marks it dirty before changing it. A page carries a pin counter
(`turso/core/storage/pager.rs:1105-1142`), and the cursor pins every page on its
root-to-leaf path. Turso calls its eviction SIEVE (`page_cache.rs:91`, `:673`); as implemented it is a
clock with a small counter instead of one bit: the
reference counter saturates at 3 (`turso/core/storage/page_cache.rs:35`) and is bumped on
every `get` (`page_cache.rs:438`). `evict_one` (`page_cache.rs:674-740`) advances the
hand, decrements the counter of evictable entries and evicts the first one at zero. Its
`evictable` test (`page_cache.rs:665-671`) is stricter than ours: clean or already
spilled, not locked, not pinned, not page 1, and no other reference to the page. Turso
does not write a dirty page back at eviction time the way this chapter does. When the
cache passes 90% of capacity (`page_cache.rs:28`), dirty unpinned pages are appended to
the write-ahead log early ("spilled"), which makes them evictable; and the capacity is a
soft limit (research notes, `pager.rs:3795-3823`, `:4242-4396`). The default cache is
2000 pages and the minimum 200 (`page_cache.rs:14-25`).

**Postgres.** Shared buffers use a clock sweep with a usage count per buffer, capped at
`BM_MAX_USAGE_COUNT` = 5 (`postgres/src/include/storage/buf_internals.h:144`). Pinning a
buffer increments the count up to that cap (`postgres/src/backend/storage/buffer/bufmgr.c:3340`);
the sweep in `StrategyGetBuffer` skips pinned buffers and otherwise decrements the count
(`postgres/src/backend/storage/buffer/freelist.c:246-277`). If the sweep finds every
buffer pinned it raises an error, the same outcome as our `AllFramesPinned`. A child
pointer in an nbtree page is a block number stored in the pivot tuple
(`BTreeTupleGetDownLink`, `postgres/src/include/access/nbtree.h:557-560`).

**TigerBeetle** has no B-tree, but its block cache shows the same policy in a statically
allocated shape. `set_associative_cache.zig` is 16-way set-associative with an 8-bit tag
and a 2-bit counter per way (`tigerbeetle/src/lsm/set_associative_cache.zig:15-19`): a
key can only live in one set of 16 slots, each set has its own clock hand, and the
source calls the algorithm "CLOCK Nth-Chance" (`:123-137`). No hash table that can
grow, no list.

**DuckDB** pins blocks through its buffer manager and puts unpinned blocks on eviction
queues rather than sweeping a clock (`duckdb/src/storage/buffer/buffer_pool.cpp:63`,
`research/duckdb.md` section 20). A block's file offset is computed from its id as in
our pager, plus a header offset (`research/duckdb.md`, `GetBlockLocation`).

Textbook, not verified in these sources: LRU and LRU-K lists, and the name "second
chance" for one-bit CLOCK.

## Allocator notes

The featured allocator is a **hand-written slab of page-aligned frames**: one
`alignedAlloc(u8, .fromByteUnits(4096), frame_count * 4096)` in `init`, never resized.

- Why a slab: all frames have the same size and the same lifetime (the pool's). There is
  nothing to free individually, so there is no free list; "allocating a frame" is the
  CLOCK sweep. Frames never move, which is what makes it legal to hand out pointers into
  them.
- Why page-aligned: a later chapter can lay a header struct over the start of a frame
  without `@alignCast` failing, and direct I/O (not used here) requires aligned buffers.
- Lifetime: `init` to `deinit`. The frame table and the page table are allocated at
  their final size in `init` too (three allocations in all), so after `init` the pool
  performs no allocation. The
  test "nothing allocates after init" runs 2000 operations on an allocator that fails
  every request made after `init`; `checkAllAllocationFailures` checks that `init` frees
  what it had when its second or third allocation fails.
- What would go wrong otherwise: allocating a buffer per fetched page from a general
  allocator would make memory use depend on the workload instead of on a number chosen
  at start-up, and would add an `OutOfMemory` path to every page access. An arena could
  not release one frame. A growable list of frames would move them on growth and
  invalidate every pinned pointer.

Tests use `std.testing.allocator`, so a leaked slab fails the run. In Rust the analogue
of "allocation failed" is the fixed frame budget: running out is `Err(AllFramesPinned)`.

## Pitfalls

- **Forgetting to unpin.** The frame can never be evicted again. Leak enough pins and
  every fetch fails. `deinit` asserts on it; use `defer pool.unpin(id, false)` for reads.
- **Forgetting to unpin on the error path.** A `try` between a fetch and its unpin leaks
  the pin when it fails, and in Zig the assert in `deinit` then hides the real error. Use
  `errdefer pool.unpin(id, false)`; in Rust unpin before returning the `Err`.
- **Using a page after unpinning it.** The frame may now hold a different page. Zig will
  not notice; you will read another node's bytes.
- **Unpinning a modified page as clean.** The change exists only in memory and vanishes
  when the frame is evicted. This bug passes every test that never fills the pool, which
  is why the model test also runs with 1, 2 and 4 frames.
- **A pool smaller than one operation's pin set.** A cursor pins a path; a split pins
  siblings. Turso's minimum of 200 pages exists for this reason (`page_cache.rs:19-25`).
- **Thinking `flushAll` makes writes safe.** It makes them durable if nothing fails
  half way. A crash between two page writes leaves the file inconsistent; chapters 21
  and 22 deal with that.
- **Reading `createFile` defaults as "open for update".** In Zig it opens write-only and
  truncates; a database file needs `.read = true`.

## Exercises

1. (easy) Three frames, all empty, hand at 0. Pages are fetched and released in the
   order 1, 2, 3, 1, 4, 1, 5, 2, 1. Predict hits, misses, evictions and the final frames
   by hand, then check with the visualization (3 frames, "release at once" ticked).
2. (easy) In `takeFrame`, swap the two steps "write the dirty victim" and "remove it
   from the page table". Which existing test fails, and what would a user lose?
3. (medium) Replace the referenced bit by a counter that saturates at 3, as Turso does.
   What is the new bound on sweep steps before `AllFramesPinned` can be reported?
4. (medium) Write a pin guard so that a pin cannot be forgotten: `defer` in Zig, a type
   with `Drop` in Rust. Why can the Rust guard not simply hold `&mut BufferPool`?
5. (hard) A full scan fetches every page once. Show with counters that it flushes the
   hot pages out of a CLOCK pool, and design a fix.

Solutions: [solutions.md](solutions.md).

## Where next

- Previous: [chapter 08, range scans and cursors](../08-range-scans-and-cursors/README.md)
- Next: [chapter 10, slotted pages](../10-slotted-pages/README.md), what goes inside one
  of these 4096-byte pages.
- Visualization: [viz/index.html](viz/index.html)
- Chapter 12 copies `storage`, `pager` and `buffer_pool` as the base of the
  disk-backed B+tree. Its tree code holds pins across calls that can fail, so it needs
  the `errdefer` pattern above.

# Chapter 01: Why B-trees

Part I, in memory. Previous: [guide index](../../README.md). Next:
[02 Searching a sorted node](../02-searching-a-sorted-node/README.md).
Visualization: [viz/index.html](viz/index.html).

## What you will learn

- The cost model that database indexes are designed for: count **page reads**, not
  comparisons.
- Why the two structures you already know, the sorted array and the binary search tree
  (BST), each fail at one half of the job.
- What a "wide node" is, what **fan-out** and **height** mean, and how to compute the
  height of a tree for a given number of keys.
- Why a flat, one-level structure costs work proportional to the number of pages on every
  change, and why adding levels fixes that.

Prerequisites: you can read simple code with arrays and pointers, and you know what
binary search does. No knowledge of B-trees is assumed. This chapter builds no B-tree.
It explains the problem the B-tree solves, so that the rules in chapters 03 to 05 look
like answers instead of arbitrary definitions.

## The idea in plain words

An index answers the question "where is the entry with key k?" for a set of keys that is
too large to scan. Keys and values are `u64` throughout Part I.

### Pages

A database does not read storage one byte at a time. It reads fixed-size blocks called
**pages**: 4096 bytes by default in SQLite and Turso, 8192 in Postgres. Reading a page
that is not in memory yet means going to the storage device, far more expensive than
anything the CPU does with the page afterwards (textbook; this guide quotes no
timings). Comparing two keys that are already in memory is close to free.

So we use this cost model for the whole guide:

> The cost of an operation is the number of **different pages** it touches.

The same model works for RAM with "cache line" in place of "page" (chapter 25).

In this chapter the pages are a model. The programs lay each structure out on imaginary
4096-byte pages and count the pages a lookup touches. An entry is 16 bytes (key and
value), so one page holds 256 entries if it holds nothing else. Real I/O starts in
chapter 09.

### Candidate 1: one sorted array

Keep all entries in one array, sorted by key. A lookup is a binary search: look at the
middle entry, discard the half that cannot contain the key, repeat.

Reads are good, though less good than the comparison count suggests. For 100,000 entries
a search needs about 17 probes. The array spans 391 pages, and the first probes are far
apart, so each lands on a different page. Only when the remaining interval fits in one
page (after about log2(391), roughly 9 probes) do the page reads stop.

Writes are the real problem. To insert a key, every entry with a larger key moves one
slot to the right. A new smallest key among 100,000 entries moves all of them and
rewrites all 391 pages. Deleting costs the same.

### Candidate 2: a binary search tree

Give every entry its own node with two pointers: "smaller keys are down there, larger
keys are down there". Inserting allocates one node and changes one pointer. Nothing is
shifted.

Two things go wrong:

1. Every step of a lookup follows a pointer to a node that can be anywhere. In our cost
   model each node visit is a page read, and a BST only discards half of the keys per
   node, so even a perfectly balanced one needs about log2(n) page reads: 17 for 100,000
   keys, where the sorted array needed 9.
2. Nothing keeps the tree balanced. Insert keys in ascending order and each new node
   hangs to the right of the previous one. The "tree" is a linked list, and a lookup
   visits every node.

Balanced binary trees (AVL, red-black) repair the second point but not the first: two
children per node means about log2(n) levels.

### Candidate 3: wide nodes

The fix for the first point: put many keys in each node. A page is read as a whole
anyway, so fill it. If a node holds M-1 keys in sorted order, they cut the key space
into M ranges, and the node stores one child pointer for each range. In that role the
keys are called **separators**. Reading one node now divides the remaining keys by M
instead of by 2.

- **Order** M is the maximum number of children of a node (Knuth's definition, used
  throughout this guide). A node holds at most M-1 keys.
- **Fan-out** is the number of children a node actually has.
- **Height** is the number of nodes on the path from the root to a leaf, which is the
  number of page reads for one lookup.

With 16-byte entries and 8-byte child pointers, a 4096-byte page fits 170 entries and
171 pointers, so M = 171. Every level multiplies the capacity by 171, so the height is
about log171(n): 3 levels for 100,000 keys, 5 for a billion.

Inside a node, the keys are a small sorted array. Shifting them on insert is cheap
because it happens inside one page. A B-tree is therefore both earlier candidates
at once: sorted arrays inside the nodes, pointers between the nodes. What remains is
keeping such a tree balanced while keys come and go: chapters 03 to 05.

### Why height at all: the one-level trap

Before accepting a tree, try the cheap fix for the sorted array: cut it into
page-sized chunks and keep a small **directory** with one slot per chunk (the first key
of the chunk and where the chunk is, 16 bytes). A lookup searches the directory, then
one chunk.
An insert shifts entries inside one chunk only.

It works until you look at the directory: a sorted array with one slot per chunk. When
a chunk fills up and splits, a slot is inserted into it, shifting everything behind. The cost of a change is again proportional to the size of a flat array, now
divided by 256. For a billion keys the directory has 3.9 million slots and fills 15,259
pages.

The repair is the same trick again: cut the directory into chunks and put a directory
on top of it. Repeat until the top directory fits in one page. Now you have built a
tree, each level a couple of hundred times smaller than the one below (256 with these
16-byte slots, 171 for candidate 3's nodes, which also hold values), and a change
touches a few pages per level in the worst case (chapter 04 shows exactly which) instead of a number
of pages that grows with n. That is why height exists: a one-level structure costs
O(number of pages) per change, a tree costs O(height).

## A worked example by hand

The guide's canonical keys, inserted in this order: 10, 20, 5, 6, 12, 30, 7, 17, 3, 25,
1, 15.

**Sorted array.** After all twelve puts: `1 3 5 6 7 10 12 15 17 20 25 30`. Count the
entries that had to move. 10 and 20 arrive in order (0 moves). 5 goes in front of two
entries (2). 6 goes in front of 10 and 20 (2). 12 moves one entry, 30 none, 7 four, 17
two, 3 eight, 25 one, 1 ten, 15 four. Total: 34 moves for 12 puts, and the average
grows with the size of the array.

`get(17)` by binary search over indexes 0..12: probe index 6 (key 12, too small), index
9 (20, not smaller), index 8 (17, not smaller), index 7 (15, too small). The search
stops at index 8; one more comparison confirms the key. 5 comparisons, and all twelve
entries sit on one page.

**BST**, same insert order:

```
              10
          /        \
         5          20
       /   \       /   \
      3     6    12     30
     /       \     \    /
    1         7    17  25
                   /
                 15
```

Height 5. `get(17)` visits 10, 20, 12, 17: four nodes, four page reads. Feed the same
keys in ascending order and every node has only a right child: height 12, and
`get(30)` visits all twelve.

**Wide nodes, M = 4** (at most 3 keys per node), laid over the sorted keys:

```
                 [ 6 | 12 | 20 ]
               /     |     |     \
      [1 3 5]   [7 10]   [15 17]   [25 30]
```

`get(17)`: read the root, compare with 6, 12 and 20, follow the third pointer, read
that leaf, compare with 15 and 17. Two page reads. Note that this lookup made 5
comparisons, more than the BST's 4, and still wins: the comparisons happen inside pages
that are already in memory.

## Code walk-through

Both programs print exactly [expected_output.txt](expected_output.txt). The interesting
part:

```
== 3. Race: 100000 keys, 1000 lookups ==
lookups that found their key: 541
                               comparisons      page reads
structure                      avg      max     avg      max
sorted array, 256 per page      17.68       18     8.52        9
BST, random insert order        21.69       36    21.69       36
wide nodes, M = 171            160.45      308     2.99        3
heights: BST 39, wide nodes 3; the sorted array spans 391 pages
BST, 2000 keys in ascending order: height 2000, get(largest) reads 2000 pages
```

Half of the 1,000 lookups ask for an existing key, the other half for a random number
that is rarely a key: 541 hits are what to expect, not 459 failures.

The wide-node row makes about nine times as many comparisons as the sorted array (this
code scans the separators one by one; chapter 02 replaces the scan with a binary
search) and a third of the page reads. That row is the cost model in one line.

### Zig (`zig/src/`)

- `cost.zig`: the model. `Entry`, `page_size`, `entries_per_page`, and `Trace`, which
  counts comparisons and distinct pages for one lookup. `Trace.touch(page_id)` counts a
  page only the first time it is seen.
- `sorted_array.zig`: `SortedArrayMap` with `get`, `getTraced`, `put`, `delete`, `range`,
  `validate`. The map owns a slice and a length and shifts with `@memmove`. `put` grows
  the slice (8 slots, then doubling) before it changes anything, so a failed allocation
  leaves the map untouched. It counts `moves` and `page_writes`.
  `initFromEntries` copies and sorts once.
- `bst.zig`: `Bst` with the same operations plus `height` and `pagesOnPath`. `put` walks
  a `*?*Node` ("pointer to the link I would have to change"), which removes the special
  case for the root, and allocates only when it has found the empty link.
- `wide.zig`: `getTraced(sorted, m, key, trace)` searches a sorted slice the way a
  balanced, evenly filled tree of order `m` laid over it would, and counts one page read per
  node. It builds no nodes: a stand-in for the real tree of chapter 03, good enough to
  measure lookups.
- `height.zig`: `minHeight(n, m)` (every node full), `maxHeight(n, m)` (every node as
  empty as B-tree rules allow, proved in chapter 03) and `orderForPage`.
- `main.zig`: the scenario, written to a `*std.Io.Writer` so a test can capture it and
  compare it with `expected_output.txt`.

Both maps are checked against the oracle from `common/` (`ops.zig`) with a seeded
stream of 5,000 operations, running `validate` after each.

### Rust (`rust/src/`)

Same files, names and tests in snake_case; the same output.

### Differences worth noticing

- **Who owns the memory.** In Zig every function that may allocate takes an
  `Allocator`, and `deinit` takes it again. In Rust `Vec` and `Box` allocate from the
  global allocator and free themselves when dropped.
- **Failure.** Zig's `put` returns `error.OutOfMemory` when the allocator says no; the
  tests inject that at every allocation with `std.testing.checkAllAllocationFailures`.
  Rust's `Vec` and `Box` abort the process instead, so the Rust versions carry a limit:
  `SortedArrayMap::with_limit` returns `Err(OutOfSpace)` and `Bst::with_budget` returns
  `Err(OutOfNodes)`. The tests try every possible limit.
- **The shift.** Zig spells it out with `@memmove`; Rust's `Vec::insert` and
  `Vec::remove` do the same shift internally.
- **Deleting a BST node with two children.** Zig copies the successor's entry into the
  node and unlinks the successor. Rust re-links the successor node itself
  (`detach_min`), because moving a `Box` is easier than holding two mutable references
  into one tree. Both give the same shape.
- **Freeing a deep tree.** A degenerate BST is as deep as it is large. Zig's `deinit`
  threads the nodes still to be freed through their own `right` pointers, so it needs
  no stack and no extra memory. Rust's generated drop for `Option<Box<Node>>` is
  recursive and would overflow the stack, so `Bst` implements `Drop` with a `Vec` of
  pending nodes. `range`, `height` and `validate` keep such a list too; in Zig the
  caller passes its allocator, so `tree.height(allocator)` can fail.
- **`range` on the array** returns a slice into the map. In Zig a comment says the
  next `put` invalidates it; in Rust a `put` while the slice is alive does not compile.
- **One page per node.** Zig passes `std.heap.page_allocator`. Rust's `std` has no such
  allocator, so `Bst<PageAligned>` adds a zero-sized field with `#[repr(align(4096))]`,
  which makes every node a page-aligned, page-sized allocation.

## In real databases

All line references are to the pinned clones described in `research/`.

**A sorted array is a real index, when the data never changes.** Milvus builds its
sorted scalar index by appending every `(value, row offset)` pair and calling
`std::sort` once (`milvus/internal/core/src/index/scalar/sort/SortedIndexBuilder.cpp:302-322`);
equality lookups are `std::equal_range`
(`milvus/internal/core/src/index/scalar/sort/SortedIndexReader.cpp:542`). There is no
insert path. This is `initFromEntries` in our code.

**Mutable map while data changes, sorted array once it is sealed.** For its primary-key
lookup Milvus uses a `std::map` (a pointer-based balanced tree) in growing segments
(`milvus/internal/core/src/segcore/InsertRecord.h:305-312`) and a sorted vector in
sealed ones. The sealed variant makes the trade explicit: `insert` after `seal()`
throws "could not insert after seal", and `seal()` is one `sort` call
(`milvus/internal/core/src/segcore/InsertRecord.h:717-730`). These are candidates 2 and
1 of this chapter, each used where it is strong. A B-tree is the structure that does not
need to choose.

**A one-level structure in production code, with the cost written down.** TigerBeetle's
`SegmentedArray` is an array of pointers to fixed-capacity nodes plus an array of prefix
counts: exactly the "chunks plus a directory" of this chapter
(`tigerbeetle/src/lsm/segmented_array.zig:14-19`). Its own fuzzer describes the sorted
variant as "a stunted B-tree one-level deep" (`tigerbeetle/src/lsm/tree_fuzz.zig:681-683`).
The O(nodes) cost is visible in the source: every insert adds to all later prefix counts
in a loop over the rest of the directory (`segmented_array.zig:671-673`), and a split
shifts the pointer array (`segmented_array.zig:422-430`). TigerBeetle uses it for
in-memory metadata of bounded size
(`tigerbeetle/src/lsm/manifest_level.zig:27-52`), where that is fine.

**Page sizes and fan-out.**

| Engine | Unit | Size | Is it a lookup page? | Source |
|---|---|---|---|---|
| Postgres | block | 8 kB default (1 to 32 kB at build time) | yes, one B-tree node | `postgres/meson_options.txt:5-8` |
| Turso (SQLite format) | page | 4096 default, 512 to 65536 | yes, one B-tree node | `turso/core/storage/sqlite3_ondisk.rs:104-107` |
| DuckDB | block | 262,144 bytes default | no: unit of column storage, DuckDB has no B-tree | `duckdb/src/include/duckdb/storage/storage_info.hpp:30` |
| TigerBeetle | block | 512 KiB | no: block of an LSM table (a sorted run of keys, chapter 27), TigerBeetle has no B-tree | `tigerbeetle/src/config.zig:161` |

The last two rows are a warning: a big "block size" does not mean wide B-tree nodes;
those engines scan or merge whole blocks.

Derived, not measured (arithmetic from the page formats in `research/postgres.md`
section 11 and `research/turso.md` section 6): a Postgres leaf page holds about 366 to
407 single-integer index entries and an internal page 284 to 407 downlinks (child
pointers, each stored with a separator), so three
levels cover tens of millions of rows and four levels cover billions. A Turso table
interior page with 4096 bytes has a fan-out between about 272 and 584 depending on
rowid size (a rowid is a table's integer row number, stored in 1 to 9 bytes; chapter
11). Turso refuses trees deeper than 20 levels as corrupt, and its comment
derives that bound from 2^31 pages and a minimum fan-out of 2 at the root and 3
elsewhere (`turso/core/storage/btree.rs:150-157`). Its overflow thresholds (the entry
size above which part of an entry moves off the page, chapter 13) are chosen to
"give a minimum fanout of 4 for index b-trees" (`turso/core/storage/btree.rs:10804`).

Real nodes are not full. Postgres cites the classic estimate that "the steady-state
load factor for btrees is usually estimated at 70%"
(`postgres/src/backend/access/nbtree/nbtsort.c:19-20`). That is why the height
calculator prints a best and a worst case; chapter 04 measures the fill.

## Allocator notes

The chapter uses two allocators, and each makes a point about its structure.

**`FixedBufferAllocator` on a stack buffer, for the sorted array.** A sorted array is
one contiguous block, exactly what a bump allocator over a fixed buffer hands out: no
system call, no free list, and the memory disappears when the function returns. `handExample` in `main.zig` puts the twelve entries in a 256-byte buffer on
the stack and never calls `deinit`. The lifetime is the stack frame; returning the map
from that function would be a use-after-return bug.

Section 2 of the output shows the limit: 16 entries fit, put number 17 fails with
`error.OutOfMemory`, and the map still has 16 valid entries. Growing from 8 to 16 slots
worked because `FixedBufferAllocator` can extend its most recent allocation in place.
With any other allocation in between, the grow would have needed a second block of 16
while the first block of 8 was still occupied, and it would have failed earlier. That is
the general weakness of one big array: growing it needs the old and the new block at
the same time.

**`page_allocator`, for the BST: one page per pointer hop.** `std.heap.page_allocator`
asks the operating system for fresh pages on every allocation. For 32-byte nodes that
is wasteful and slow (`ZIG_CHEATSHEET.md` says never to do it per node). Here it is
used on purpose, for twelve nodes: it makes the cost model literally true.
`Bst.pagesOnPath` looks at the real addresses of the nodes on a search path, and the
program prints that `get(17)` visits 4 nodes on 4 distinct pages of memory. The test
`page_allocator puts every node on its own page` builds the same tree in a
page-aligned `FixedBufferAllocator` buffer, and there the whole path is on 1 page.

So the allocator decides how many pages a pointer-based tree touches. A B-tree stops
depending on it by making the node itself page-sized.

Everything else uses `init.gpa` or `std.testing.allocator`, so leaks fail the tests.

## Pitfalls

- **Counting comparisons.** Big-O classes hide the difference between a comparison and
  a page read. Sorted array, balanced BST and B-tree are all O(log n) per lookup. In
  page reads they are about log2(n / 256), log2(n) and log171(n).
- **"Binary search is one page read per probe."** Only until the search interval fits
  in a page; later probes are free. Hence 9 page reads for 100,000 entries, not 17.
- **Forgetting the worst case of the BST.** Sorted input is common (timestamps,
  auto-increment ids) and is the worst input for an unbalanced tree.
- **Recursion on unbalanced trees.** A recursive `deinit`, `range`, `height` or
  `validate` on a 20,000-node chain needs 20,000 stack frames, and nearly sorted input
  (2, 1, 4, 3, ...) gives a tree just as deep that forks at every level. This code
  does not recurse; the tests walk both shapes.
- **`for (1..len)` in Zig when `len` is 0.** The range `1..0` is an integer overflow,
  not an empty loop, so `validate` uses a `while` loop.
- **Reading "height" differently.** Some texts count edges, so a single node has height
  0. This guide counts nodes, because that is the number of page reads.

## Exercises

1. (easy) By hand: insert the canonical keys into a BST in ascending order and draw the
   result. Then find an insert order of the same twelve keys that gives the smallest
   possible height. What is that height?
2. (easy) A Postgres-like leaf entry for an integer key takes 20 bytes on an 8192-byte
   page with 8152 usable bytes. What order does that give, and how many levels are
   needed for 10^6, 10^9 and 10^12 keys in the best and worst case? Check with the
   visualization's height calculator or call `minHeight` and `maxHeight` from a test.
3. (medium) Add `rangeTraced` to `SortedArrayMap` and `Bst`: return the number of page
   reads for a range query. How many pages does each touch for 1,000 consecutive keys
   out of 100,000?
4. (medium) The one-level structure: with chunks of B entries and a directory with one
   slot per chunk, an insert shifts at most B entries in the chunk and, when the chunk
   splits, up to n / B slots in the directory. Which B minimises the worst case for
   n = 10^9? Compare with a tree of order 171.
5. (hard) Replace the linear scan over separators in `wide.getTraced` by a binary
   search. Predict what happens to the two columns of the race table, then check.

Solutions: [solutions.md](solutions.md).

## Where next

- Visualization: [viz/index.html](viz/index.html) races the three structures.
- Previous: [guide index](../../README.md) ([landing page](../../index.html)).
- Next: [02 Searching a sorted node](../02-searching-a-sorted-node/README.md): the
  search inside one node.

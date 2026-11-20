# Chapter 12: A disk-backed B+tree

## What you will learn

- How the B+tree of chapter 07 changes when a node is a page in a file and a pointer is a page number.
- Why "full" and "half full" are numbers of bytes here, and what that does to splitting.
- Why the root keeps its page id for the whole life of the file, and what a metapage is for.
- Why this tree is **not crash-safe yet**, shown by stopping one split after every page write.

Prerequisites: chapter 07 (B+tree, separators are copies, leaf links), chapter 09 (pager and buffer
pool: fetch, pin, unpin, dirty), chapter 10 (slotted page), chapter 11 (keys as byte strings).

This chapter adds no new data structure. It puts chapters 07 to 11 together, and chapters 13, 22
and 30 start from its code.

## The idea in plain words

Take the B+tree of chapter 07 and replace three things.

1. **A node is a slotted page.** A leaf page holds cells `key -> value`. An interior page holds
   cells `key -> child page id`. The page's kind (leaf or interior) and one extra page id live in
   the header bytes that chapter 10 left to the caller. In a leaf the extra id is the right
   sibling; in an interior page it is the rightmost child.
2. **A pointer is a page id.** To follow one, the tree asks the buffer pool for that page, gets a
   pinned frame, looks at it and unpins it. The tree never reads or writes the file itself.
3. **Capacity is bytes.** Chapter 03 said a node of order M holds at most M-1 keys. A page
   holds as many cells as fit in 4076 bytes (4096 minus a 16-byte header and 4 reserved bytes).
   Four cells of 1010 bytes fill a page; so do 226 cells of 18 bytes.

Two more decisions follow from "the tree lives in a file".

**The file needs a fixed starting point.** Page 0 is the *metapage*: a magic number, a format
version, the root's page id and two counters. Whoever opens the file reads page 0 first.

**The root stays where it is.** When the root is full, this tree does not create a new root
above it. It copies the root's content into a new page, and rewrites the root page in place as
an interior page with that new page as its only child. Then the new page splits like any other
page. The height grows by one and the root is still page 1. Everything that knows where the
root is (the metapage, and in a real database the catalog and every open cursor) stays correct.

### Why a split is "50/50 by bytes"

When a cell does not fit, the leaf's cells plus the new one are laid out in key order and cut in
two. With fixed-size keys you cut after half of the *keys*. Here cells differ in size, so the
cut goes after the shortest prefix that holds at least half of the *bytes*.

Does each half fit in a page? Only if no single cell is too large. Let `C` be the capacity
(4076) and `m` the largest cost a cell may have. The page overflowed, so the costs add up to `T`
with `C < T <= C + m`. The prefix before the cut point is below `T/2`, so the left half is below
`T/2 + m <= C/2 + 3m/2`. That is at most `C` exactly when `m <= C/3`. The right half is at most
`T/2`. So the rule is: **every cell must cost at most a third of a page.** This chapter allows
keys up to 256 bytes and values up to 1024 bytes (a quarter of a page), which makes the largest
leaf cell 1286 bytes, below 4076 / 3 = 1358. A `comptime` assertion checks it.

"Half full" becomes a byte notion too. After a split each half holds roughly half of the bytes,
give or take one cell. It may hold two cells or two hundred.

### Why chapter 04's top-down splitting does not carry over

Chapter 04 showed an insert that splits every full node on the way *down*, so that a parent
always has room for one more key when a child splits. That relies on two facts: "full" can be
seen without knowing the key to insert, and a node that is not full can take any one key.
Neither is true here. Whether an interior page can take a separator depends on that separator's
length, and the separator is only known after the leaf below has chosen its split point. A page
with 300 free bytes is full for a 256-byte key and far from full for a 3-byte one.

So splits run bottom-up. The descent remembers its path (page ids and child indexes, not
pinned pages). If the leaf is full it splits and hands a separator to its parent; if the parent
has no room for that particular separator, the parent splits too, and so on.

## A worked example by hand

The programs insert 24 two-digit keys. Key `n` carries a value of `300 + 24*n` bytes, so its
cell costs `4 + 2 + (300 + 24n) + 2` bytes: key 05 costs 428, key 30 costs 1028.

The first six keys (10, 20, 05, 06, 12, 30) cost 548 + 788 + 428 + 452 + 596 + 1028 = 3840 bytes.
They fit in the root, page 1, which is still a leaf. Key 07 costs 476 and only 236 bytes are free.

- The full page is the root, so its content moves to a new page 2, and page 1 becomes an
  interior page with no key and the single child 2.
- Page 2 now splits. The seven cells in key order cost 428, 452, 476, 548, 596, 788, 1028,
  together 4316. Half is 2158. The prefixes are 428, 880, 1356, 1904, **2500**: the first five
  cells stay on page 2 and the last two (20 and 30, 1816 bytes) go to a new page 3.
- The separator is a copy of the right half's first key, 20. It goes into page 1.

```
page 1  interior  1 keys  12/4076 bytes  | (2) 20 (3)
  page 2  leaf      5 keys  2500/4076 bytes  next 3  | 05:420 06:444 07:468 10:540 12:588
  page 3  leaf      2 keys  1816/4076 bytes  next -  | 20:780 30:1020
```

Five keys on the left, two on the right: an uneven split by keys, a fair one by bytes. After
all 24 puts (the full output is in `expected_output.txt`):

```
page 1  interior  5 keys  60/4076 bytes  | (2) 08 (7) 12 (4) 20 (3) 25 (6) 28 (5)
  page 2  leaf      7 keys  2828/4076 bytes  next 7  | 01:324 02:348 03:372 04:396 05:420 06:444 07:468
  page 7  leaf      4 keys  2144/4076 bytes  next 4  | 08:492 09:516 10:540 11:564
  page 4  leaf      5 keys  3364/4076 bytes  next 3  | 12:588 14:636 15:660 17:708 18:732
  page 3  leaf      3 keys  2484/4076 bytes  next 6  | 20:780 22:828 23:852
  page 6  leaf      2 keys  1864/4076 bytes  next 5  | 25:900 27:948
  page 5  leaf      3 keys  3012/4076 bytes  next -  | 28:972 29:996 30:1020
```

Read the interior line as `(child) key (child) key ... (rightmost child)`. Page ids are in order
of allocation, not in key order: the leaf chain runs 2, 7, 4, 3, 6, 5. A range scan follows the
`next` links and never needs the parent.

## Code walk-through

### Layout of the code

```
base_storage, base_pager, base_buffer_pool   copied from chapter 09, behaviour unchanged
base_slotted_page                            copied from chapter 10, unchanged
disk_btree                                   this chapter
workload, tests, demo                        seeded keys and oracle, tests, the printed scenario
```

Chapter 11's `varint` and `keycodec` are not copied: the tree treats keys as opaque bytes
compared with memcmp, which is exactly what chapter 11's encoders produce. Part 3 of the demo
uses the simplest of them, a `u64` as 8 big-endian bytes, and gets numeric order from byte order.

### Zig (`zig/src/disk_btree.zig`)

**File format.** `Meta` is page 0: magic `"BTREE12\0"`, version, page size, root page id, page
count, key count, all little-endian. The two counters are "as of the last flush". Every other
page is created with `SlottedPage.initReserved(buf, 4)`: the last 4 bytes of each page are never
used by the tree, so that chapters 21 and 22 can store a page checksum there without changing
the layout. `kind` is 1 for a leaf and 2 for an interior page, and the first 4 bytes of the user
area are the link.

**Interior cells.** Cell `i` is `(K_i, C_i)` and child `C_i` holds the keys `k` with
`K_(i-1) <= k < K_i`; the rightmost child holds the keys `>= K_(n-1)`. `childIndex` is one
binary search: the first cell whose key is greater than the search key, or the rightmost child.
A key equal to a separator goes right, as in chapter 07.

**`put`.** `findLeaf` walks down with one pin at a time and records the path in a list. The
leaf's own `put` (chapter 10) either succeeds, and then one page is dirty and nothing else
happened, or returns `PageFull`. Then `splitAndInsert` runs these steps:

- `pushRootDown` if the page to split is the root (copy the root to a new page, rewrite the
  root as an interior page pointing at it).
- `splitLeaf`: copy the page into scratch memory, build the list of cells including the new
  one, call `splitPoint`, allocate the right page, rebuild both halves. The left half stays on
  the old page id, so the leaf to its left still points at the right place.
- `insertSeparator` on the parent taken from the path: if the separator fits, insert
  `(sep -> left)` and make the pointer after it lead to `right`. If not, `splitInterior`, where
  the middle key *moves* up instead of being copied, and loop.

Each step does everything that can fail (fetch, allocation) before it changes a byte, so a
step either happens or does not. The steps together are not atomic; see "Not crash-safe yet".

**Pins.** No function returns with a pin it took, and at most two pages are pinned at once.
`BufferPool.deinit` asserts that no pin is left, so every error path has an `errdefer` unpin;
the tests inject failures at every point to check that.

**`get`, `range`.** `get` copies the value with an allocator the caller passes, because the
page may be evicted the moment it is unpinned. `range(lo, hi)` returns an iterator that
remembers `(leaf page id, slot)` and holds no pin between calls: each `next` pins the leaf,
copies one entry into the iterator's own buffer and unpins. Nothing has to be released.

**`validate`** walks the whole file and checks eight invariants (T1 to T8 at the top of the
file): well-formed pages, key order, separator bounds, equal leaf depth, the leaf chain, every
page reachable exactly once, no empty pages, and the key count.

### Rust (`rust/src/disk_btree.rs`) and the differences

Same structure, names, tests and output. The differences that matter:

- **Ownership.** Zig's tree borrows a `*BufferPool`; the Rust tree owns its `BufferPool`
  (which owns the pager and the storage) and lends it out with `pool()` / `pool_mut()`.
- **A pin is not a borrow.** `pin_node` is a free function over the pool that returns a
  `SlottedPage<'_>` borrowing only `tree.pool`. A split needs two pages at once and uses
  `page_pair_mut`.
- **No `errdefer`.** Every early return unpins by hand. The "poison if a later step fails"
  logic is one `errdefer` in Zig and an inner function plus a check of its result in Rust.
- **Scratch memory.** See the allocator notes.
- **The range iterator borrows the tree mutably**, so "do not modify the tree during a scan"
  is enforced by the compiler; in Zig it is a comment. Its `next` returns slices into the
  iterator, so it cannot implement `std::iter::Iterator`.
- **Errors.** Zig merges error sets; Rust has one `TreeError` enum with `Io(...)` and
  `Invalid(Violation)` variants.
- **Tests.** Zig reports 69 tests, Rust 66. Both hash the file that a fixed run of puts
  leaves (the empty key, 0x00 and 0xFF bytes, chains of prefixes, 400 seeded puts) and compare
  it with the same constant, so the two programs write the same bytes. Only in Zig: the allocation-failure test, one
  storage test (out of memory reported as `StorageFailure`) and the `test` block that pulls in
  the other files. Safe Rust cannot make a `Vec` allocation fail; the nearest case, "the
  page allocation in the middle of a split fails", is covered by the I/O tests in both.

## Not crash-safe yet

A split changes two pages (the two halves), then a third (the parent), and a root split a
fourth. The file receives pages one write at a time. There is no moment at which all of them
change together, so a crash between two writes leaves a file that is neither the old tree nor
the new one. Two things make this worse than it sounds:

- The writes do not even wait for `flush`. Whenever the buffer pool needs a frame it evicts a
  dirty page and writes it, in the middle of whatever the tree is doing.
- Nothing on a page says whether it is current. A reader cannot tell a stale page from a
  fresh one.

Part 4 of the programs demonstrates it. Eleven keys are safely on disk. Then `put 15` splits
leaf 2 and the tree is flushed, which needs five storage writes: the allocation of page 4
(zeroes), the metapage, the parent (page 1), the left half (page 2), the right half (page 4).
`MemStorage` is told to fail after N writes; then everything in memory is dropped, as in a
crash, and the file is reopened:

```
N = 0: validate ok; 11 of 11 old keys readable; new key missing
N = 1: validate fails with error.UnreachablePage; 11 of 11 old keys readable; new key missing
N = 2: validate fails with error.UnreachablePage; 11 of 11 old keys readable; new key missing
N = 3: validate fails with error.KeyOutOfBounds; 9 of 11 old keys readable; new key missing
N = 4: validate fails with error.BadPage; 9 of 11 old keys readable; new key missing
N = 5: no crash, all writes done; validate ok; 11 of 11 old keys readable; new key readable
```

At N = 1 and 2 the file has leaked a page. At N = 3 the parent already points at page 4, which
is still zeroes: keys 12 and 17 are in the file (on the old page 2) but lookups go to the empty
page. At N = 4 the left half has been rewritten without them and the right half was never
written: **two keys that had been flushed long ago no longer exist anywhere.** A crash during
an insert of one key destroyed two others.

The same holds in memory. If `put` fails with an I/O or allocation error after its first step
has changed a page, the tree in the buffer pool is half-split. The handle then sets `poisoned`.
From then on `put`, `get`, `range` and `flush` (and `close`, which flushes) return
`TreePoisoned`: nothing is answered from the broken tree and no more of it is written. That is
honest but not a repair. `validate`, `height` and `dump` deliberately do not check the flag:
they still read the half-split pages, because they are how you look at the damage. Neither
does a range iterator obtained earlier (Rust's borrow checker forbids keeping one across a
`put`; in Zig, do not).

Chapter 21 adds the tools (checksums in the reserved 4 bytes, what `fsync` promises) and
chapter 22 puts a write-ahead log in front of this tree so that a split is all or nothing.

## In real databases

- **Turso / SQLite: the root does not move.** `balance_root` allocates a child, copies the
  root's cells and header into it, changes the root's page type from leaf to interior, sets its
  cell count to 0 and its rightmost pointer to the child, and continues balancing the child
  (`turso/core/storage/btree.rs:5406-5489`). This chapter's `pushRootDown` is that function.
  The research notes list it among the engine's main ideas: "the root page number never
  changes" (`research/turso.md`, section on balancing).
- **Postgres: the root moves and the metapage follows it.** Block 0 of every nbtree index is a
  metapage holding `btm_root`, `btm_level`, `btm_fastroot` and `btm_fastlevel`
  (`postgres/src/include/access/nbtree.h:104-111`). A root split builds a *new* root page above
  the two halves and updates those fields (`_bt_newlevel`,
  `postgres/src/backend/access/nbtree/nbtinsert.c:2489-2655`). The *fast root* exists because
  Postgres never shrinks the tree: after mass deletion the top levels can be single pages, so
  the metapage also records the lowest single-page level and searches start there
  (`postgres/src/backend/access/nbtree/README:362-381`; `_bt_getroot` reads `btm_fastroot` at
  `nbtpage.c:376`). The price of a moving root is one more page to consult (cached in
  practice); the price of a fixed root is copying a page on every root split.
- **The one-third rule is Postgres's.** "We actually need to be able to fit three items on
  every page, so restrict any one item to 1/3 the per-page available space"
  (`nbtree.h:155-173`, `BTMaxItemSize`). Postgres needs three because a page holds a high key
  plus at least two items; this chapter needs it for the split argument above.
- **Bytes, not counts.** Turso decides whether a page needs balancing from its free bytes
  (`free_space * 3 <= usable_space * 2`, `btree.rs:3427-3430`). Postgres chooses a split point
  by comparing the free space left on both sides (`_bt_findsplitloc`,
  `nbtsplitloc.c:129-429`); chapter 14 is about that choice.
- **Bottom-up with a remembered path.** Postgres keeps a stack of parent locations from the
  descent and inserts the separator through it (`_bt_insert_parent`,
  `nbtinsert.c:2127-2254`). Turso keeps a page stack in its cursor and balances upward from
  the leaf (`btree.rs:3401-3514`).

Not like real databases, on purpose: no delete (chapter 13), values limited to a quarter page
(overflow chains: chapter 13), plain 50/50 splits even for ascending inserts (chapter 14), no
latches (chapter 19), no log (chapter 22).

## Allocator notes

The tree uses two kinds of memory with two very different lifetimes.

- **Nodes live in the buffer pool's frame slab**, one aligned allocation made when the pool is
  created. The tree never allocates or frees a node. A node's memory is "freed" by eviction
  and comes back with the next fetch, possibly in another frame, which is why the tree holds
  page ids and never pointers across calls.
- **Scratch memory comes from one `std.heap.ArenaAllocator` per tree, reset at the end of each
  operation** (`reset(.retain_capacity)`). A put needs a path stack of unknown depth, a 4096-byte
  copy of each page it splits, and cell lists; `validate` needs a bitmap and copies of interior
  pages. None of it outlives the operation, so one reset frees it all, and no error path can
  leak it. After the first few operations the arena has kept enough capacity that later ones
  ask the backing allocator for nothing. The price: the arena keeps its high-water mark, so
  one `validate` of a large tree leaves 4096 bytes per interior page with the handle until
  `deinit`; `reset(.{ .retain_with_limit = n })` would cap that.

What would go wrong with something else: a general-purpose allocator would need a matching
`free` on every error path of the split code, next to the `unpin`s. A `FixedBufferAllocator`
would have to be sized for the deepest tree and the largest `validate`. An arena that is never
reset would grow with every put.

`get` is the one place that uses a caller-supplied allocator: the returned value must outlive
the operation, so it cannot come from the arena.

Rust has the same split with other tools: nodes are the pool's boxed frames; the path stack is
a `Vec` owned by the tree and cleared per operation (its capacity is the retained arena); the
page copy is a `[u8; 4096]` on the stack; cell lists are short-lived `Vec`s dropped at the end
of the split.

## Pitfalls

- **`defer pool.unpin(id)` with an `id` that changes.** `defer` evaluates its expression when
  the scope ends. In a loop that walks down the tree, unpin through a `const` copy of the id.
- **Slices into a page die when the page is unpinned or modified.** `SlottedPage.key(i)` points
  into the frame. Copy what you need before unpinning, and before any insert into that page.
- **A pool that is too small fails, it does not block.** With every frame pinned,
  `fetchPage` returns `AllFramesPinned`. This tree needs 2 frames.
- **A crash inside `create` leaves a file neither call accepts.** With only page 0 written,
  `create` returns `NotEmpty` and `open` returns `BadMagic`; delete the file.
- **The counters in the metapage lag.** Between flushes the file can have more pages than
  page 0 says. `open` accepts that; `validate` reports the orphans.
- **Pages from disk are trusted.** `pinNode` checks only the page kind and the reserved size.
  A damaged page of the right kind can make the slotted page code read out of bounds, and an
  interior page that points at one of its ancestors makes `get` and `put` descend forever
  (only `validate` remembers which pages it has seen); real protection needs the checksum of
  chapter 21.
- **An overwrite can split.** Replacing a value with a larger one may not fit; `put` handles
  it through the same split path.

## Exercises

1. (easy) By hand: how many cells with a 4-byte key and a 1000-byte value fit in a leaf? How
   many with an 8-byte value? Check against the test "full is a number of bytes".
2. (easy) Change `max_value_len` to 2000 and build. What happens, and which step of the split
   argument would break without that check?
3. (medium) Part 4 uses an 8-frame pool, so nothing is written before `flush`. Predict what
   changes with a 3-frame pool, then try it.
4. (medium) Insert 1000 keys in ascending order and in random order (8-byte keys, 100-byte
   values) and compare the number of leaves. Explain the difference.
5. (hard) Make `put` leave the in-memory tree intact when a step fails, instead of poisoning
   the handle. What must be acquired before the first change, and how many pins does it need?

Solutions: [solutions.md](solutions.md).

## Where next

- Previous: [chapter 11, key and record encoding](../11-key-and-record-encoding/README.md)
- Next: [chapter 13, overflow and free space](../13-overflow-and-free-space/README.md)
- Visualization: [the tree of pages](viz/index.html) (its 128-byte toy pages show an interior
  split and a third level) and
  [the buffer pool during an insert that splits](viz/pool.html)
- Output of both programs: [expected_output.txt](expected_output.txt)

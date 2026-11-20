# Chapter 13: Overflow and free space

## What you will learn

- How a tree of 4096-byte pages stores a value of 60000 bytes: a prefix stays in the leaf, the
  rest goes to a chain of *overflow pages*. And how to choose the size of the prefix.
- How `delete` gives pages back: a leaf is freed when it becomes empty ("free at empty"), and
  why nothing is merged.
- How a file remembers its free pages: a *free list* of trunk pages, read before the file grows.
- **When** a freed page may be reused, in four systems, and why this chapter's answer
  ("immediately") is the one that is not crash-safe.

Prerequisites: chapter 12 (this chapter extends its code), chapter 09 (buffer pool) and
chapter 10 (slotted page). Chapter 05's borrowing and merging are not used here.

## The idea in plain words

Chapter 12's tree had three gaps: a value could be at most 1024 bytes, nothing could be
deleted, and the file only grew. All three are about pages that belong to the file but not to
the tree. **From now on every page of the file has exactly one role.**

| Role | What it is | How it is reached |
|---|---|---|
| metapage | page 0 | fixed |
| tree page | leaf or interior | from the root, page 1 |
| overflow page | part of one large value | from one leaf cell, then page to page |
| trunk page | a list of free page ids | from the metapage, then trunk to trunk |
| free page | nothing; its bytes are leftovers | listed in a trunk |

`validate` checks exactly this: it walks the tree, every chain and the free list, gives each
page it meets a role, and fails if a page gets two roles or none.

### Large values: keep a prefix, chain the rest

A leaf cell is still `key -> value field`, but the field is now

```
total length P (4 bytes) | the first L bytes of the value | first overflow page id (4 bytes, only if spilled)
```

and an overflow page is `next page id (4 bytes) | 3 spare bytes | kind | 4084 bytes of the value`.
The chain is singly linked and ends with "no page". Its length is not stored: it follows from P.

How large may L be? Chapter 12's split argument needs every cell to cost at most a third of a
page (then a page that overflowed can always be cut into two halves that fit). So the largest
local part X is what is left of a third of a page after everything else in the cell:

```
X = 4076/3 - slot 2 - cell header 4 - longest key 256 - length 4 - page id 4 = 1358 - 270 = 1088
```

A value of at most 1088 bytes is stored whole. For a larger one the code uses SQLite's rule,
with M = X/2 = 544 as the minimum local part:

```
K = M + (P - M) mod 4084        if K <= X keep K bytes in the leaf, else keep M
```

Read it as: fill whole overflow pages counting from M, and look at the remainder. If the
remainder fits in the leaf (K <= X), put it there: every overflow page is then full and no
page is spent on a small tail. Otherwise keep only the minimum, so that more cells fit in the
leaf, and let the last overflow page be partly full. With L bytes kept in the leaf, the chain
has `(P - L) / 4084` pages, rounded up.

| P | K | in the leaf | overflow pages |
|---|---|---|---|
| 1088 | | 1088 | 0 |
| 1089 | 1089 > X | 544 | 1 (545 bytes) |
| 5000 | 544 + 4456 mod 4084 = 916 | 916 | 1, full |
| 9000 | 544 + 8456 mod 4084 = 832 | 832 | 2, full |
| 14000 | 544 + 13456 mod 4084 = 1748 > X | 544 | 13456 / 4084 = 3.29, so 4 (the last holds 1204) |

The alternative to chaining is a size cap: refuse what does not fit. Postgres does that for
index entries (see "In real databases").

### Delete: free at empty

`delete(key)` removes the cell from its leaf. Usually that is all. Only when the leaf's *last*
cell goes does the page leave the tree:

1. the left sibling's link is changed to skip it,
2. the parent, with children C0..Cn and separators K0..Kn-1, loses the pointer Ci and one
   separator: cell i (Ki with Ci) goes, and the right neighbour inherits Ci's key range. If Ci
   was the rightmost child, the last cell goes and its child becomes the rightmost. No key moves,
3. a parent that had no other child goes the same way, and so on up,
4. the removed pages are put on the free list,
5. if the root is left with one child and no key, the child's content is copied into the root
   page and the child is freed: chapter 12's `pushRootDown` backwards. The tree loses a level
   and the root is still page 1.

Pages that are merely nearly empty stay: no borrowing, no merging. That wastes space under
some workloads (chapter 15 measures merge policies), and it is what Postgres does: moving
cells between pages is what concurrent scans cannot tolerate (chapter 19 on), and removing a
page that is already empty moves nothing.

### The free list

The metapage gets two fields: the id of the first *trunk page* and the number of free pages.
A trunk page is `next trunk id | count | up to 1021 page ids`. This is SQLite's design.

- **free(p)**: if the first trunk has room, append `p` to its array. Otherwise `p` itself
  becomes the new first trunk, pointing at the old one.
- **allocate()**: no trunk: grow the file. A trunk that lists ids: take the last one. A trunk
  that lists nothing: hand out the trunk page itself and move the head to the next trunk.

The simpler design threads a linked list through the free pages themselves, so freeing a page
writes it. With trunks, freeing 1000 overflow pages dirties one page, the trunk. The price is
one more page format and one more case in allocation.

The file never shrinks: a free page stays in the file until something reuses it.

### Two ordering rules

`put` writes the overflow chain *before* the leaf cell that points to it, and frees the old
chain *after* that cell is gone. `delete` removes the parent's pointer *before* it frees the
child. So an operation that fails half-way (an I/O error) leaves at worst a page that nobody
points to, never a pointer to a free page. The handle still poisons itself, as in chapter 12:
`validate` would report the leak. These rules order changes *in memory*; they say nothing
about the order in which pages reach the disk (see "Not crash-safe, and worse than before").

## A worked example by hand

Part 1 of the programs, on a new file (page 0 metapage, page 1 root leaf). Keys are two digits.
A 700-byte value costs its leaf 712 bytes (2 slot + 4 cell header + 2 key + 4 length + 700).

1. **put 10, 20, 30, 40, 50** with 700 bytes each: 3560 of 4076 bytes in page 1.
2. **put 25 = 9000 bytes.** L = 832, so two overflow pages. They are written first: the file
   grows by pages 2 and 3. The cell costs 848 bytes; 3560 + 848 > 4076, so the root's content
   moves to page 4 and that page splits into 4 and 5.
   ```
   page 1  interior  | (4) 30 (5)
     page 4  leaf    | 10:700 20:700 25:9000=832+[2 3]
     page 5  leaf    | 30:700 40:700 50:700
   page map: M I O O L L
   ```
3. **put 60 = 3000 bytes**: 544 local, one overflow page: the file grows by page 6.
4. **put 25 = 100 bytes** (overwrite). The new cell is written, then the old chain is freed.
   Page 2: there is no trunk, so it becomes one. Page 3: appended to trunk 2.
   `free list: 2 pages | trunk 2: 3`, page map `M I T F L L O`.
5. **put 35 = 5000 bytes** needs one overflow page and gets page 3, the id trunk 2 lists.
   The file does not grow. Page map `M I T O L L O`.
6. **delete 60, 35, 40, 50.** The first two free their chains (pages 6 and 3). Leaf 5 keeps
   shrinking but stays: it still holds key 30.
7. **delete 30.** Leaf 5 is empty: leaf 4's link becomes "none", the root loses separator 30
   and the pointer, page 5 is freed. The root now has one child and no key, so page 4's cells
   are copied into page 1 and page 4 is freed.
   ```
   page 1  leaf  | 10:700 20:700 25:100
   free list: 5 pages | trunk 2: 6 3 5 4
   page map: M L T F F F F
   ```
8. **put 70 = 14000 bytes** needs four pages and takes 4, 5, 3, 6 (last listed first).
9. **put 80 = 3000 bytes** needs one page. Trunk 2 lists nothing, so page 2 itself is used.
   `page map: M L O O O O O`: seven pages, none free. Six of the eleven allocations reused a page.

The [visualization](viz/index.html) plays these sixteen operations step by step, and part 5's crash.

## Code walk-through

`disk_btree` is chapter 12's file, extended; the `base_*` files are copied unchanged. The split
code (`pushRootDown`, `splitLeaf`, `insertSeparator`, `splitInterior`, `splitPoint`) has two
changes: it calls `allocPage()` where it called `pool.newPage()`, and `insertSeparator` returns
`Corrupt` if the separator does not sort between its new neighbours. To the splitting code a
value field is just a value of at most 1096 bytes.

### Zig (`zig/src/disk_btree.zig`)

- **Constants.** `max_local`, `min_local`, `overflow_payload`, `trunk_capacity` are computed
  from the page layout and asserted at `comptime`. `localLen` and `overflowPages` are the
  formulas above. `parseField` decodes a value field and is safe on any bytes.
- **Free list.** `allocPage` and `freePage` (shown in the visualization). `allocPage` unpins
  the trunk *before* it fetches the page it handed out, so chapter 12's limit of two pins
  holds and a 2-frame pool still works.
- **Chains.** `writeChain` allocates front to back. `readChain` reports `Corrupt` if the chain
  is shorter or longer than the stored length says. `freeChain` takes its page count from the
  stored length, so a damaged chain cannot make it loop.
- **`delete`, `removeLeaf`, `leftSibling`, `collapseRoot`**: the five steps of "free at
  empty". Leaves are singly linked, so the left sibling is found from the remembered path: up
  to the nearest ancestor where the path did not take child 0, one child to the left, then
  down along the rightmost children.
- **The poisoned handle.** A field `changed` is set by whatever changes a page first; one
  `errdefer` in `put` and in `delete` poisons the handle if the operation fails after that.
- **`get` and `range`.** `get(allocator, key)` makes one allocation of exactly the value's
  length, copies the local part while the leaf is pinned, unpins, then reads the chain.
  `RangeIterator` now has a `deinit`; see "Allocator notes".
- **`validate`** checks T1 to T10 (top of the file) and fills a `[]Role`, one per page;
  `pageMap` returns it, and the demo prints it as letters (`M I L O T F`).
- **A file is untrusted input.** Every count, length and page id read from a page is checked
  before it is used, and every walk is bounded (`max_height` = 32 levels, the file's page
  count). A tree page is checked as a whole (`nodeIsSound`) the first time a handle pins it.
  On a damaged file every call returns a value or `Corrupt` and leaves no pin; the damage
  tests in both languages check that.

### Rust (`rust/src/disk_btree.rs`) and the differences

Same structure, names, tests and output; the files the two programs write are byte-identical
(a test in each language compares a hash of the file with the same constant). Differences
beyond those listed in chapter 12:

- **No allocator parameter.** Zig's `get` takes an `Allocator`. In Rust the "stack first, heap
  if larger" idea is a type: `ValueBuf` holds an inline array of 1088 bytes and a `Vec`, and
  `get_into(key, &mut buf)` fills whichever is large enough. The `Vec` keeps its capacity, so
  a scan over many large values allocates once; the Zig iterator frees each large value
  before reading the next.
- **Pin, copy, unpin.** In `validate` and `dump` Rust copies a pinned leaf to the stack before
  it walks the leaf's chains: a `SlottedPage` borrowing the pool cannot coexist with further
  pool calls. The pin is held for the same span.
- **Poisoning** is an inner function (`put_steps`, `delete_steps`) plus a check of its result.
- **Tests.** Zig has 83 tests, Rust 79. Zig has four more: two allocation-failure tests (safe
  Rust cannot make a `Vec` allocation fail), one storage test and the import block.

## Not crash-safe, and worse than before

Chapter 12 showed a split torn by a crash. Reuse adds a new kind of damage. Part 5 of the
programs: `"old"` = 5000 × `'o'` is on disk (leaf cell plus overflow page 2). Then `"old"` is
deleted, `"new"` = 5000 × `'n'` is put (its overflow page is page 2 again, fresh from the free
list), and the tree is flushed; the storage fails after N writes.

```
N = 0: validate ok; old: intact; new: missing
N = 1: validate ok; old: intact; new: missing
N = 2: validate ok; old: missing; new: WRONG VALUE (starts with 'n', ends with 'o')
N = 3: no crash, all writes done; validate ok; old: missing; new: intact
```

At N = 2 the metapage and the leaf are new and page 2 is old. The file passes every check:
the cell says "5000 bytes, chain starts at page 2", and page 2 is a well-formed overflow page.
It is the overflow page of the value that was deleted. `get("new")` returns 916 bytes of `'n'`
followed by 4084 bytes of `'o'`, and nothing can tell. Without reuse the new cell would
point at a newly appended page that is still all zeroes, which `get` reports as `Corrupt`.

So: **this chapter reuses a freed page immediately, and that is not crash-safe.** Chapter 22
adds the log that makes it safe; "In real databases" shows what others do instead.

## In real databases

**Turso (SQLite format): overflow thresholds.** On index pages max local payload X is
`((usable - 12) * 64 / 255) - 23` and min local M is `((usable - 12) * 32 / 255) - 23`
(`turso/core/storage/btree.rs:10808-10832`; the comment at `:10804` gives the reason: "a
minimum fanout of 4 for index b-trees"). `payload_overflows` is the rule this chapter copied
(`turso/core/storage/sqlite3_ondisk.rs:2263-2278`). For 4096-byte pages X = 1002 and M = 489
(arithmetic in `research/turso.md`, section 5).

**Postgres: a cap instead of a chain.** "We actually need to be able to fit three items on
every page, so restrict any one item to 1/3 the per-page available space"
(`postgres/src/include/access/nbtree.h:155-173`, `BTMaxItemSize`; 2704 bytes for 8 KiB pages,
computed in `research/postgres.md`). A larger index tuple is an error (`_bt_check_third_page`,
`postgres/src/backend/access/nbtree/nbtutils.c:1107-1160`). The comment there says why it
does not chain: out-of-line storage "would break assumptions made by suffix truncation and by
contrib/amcheck".

**Postgres: free at empty, never merge.** "We consider deleting an entire page from the btree
only when it's become completely empty of items. (Merging partly-full pages would allow better
space reuse, but it seems impractical to move existing data items left or right to make this
happen --- a scan moving in the opposite direction might miss the items if so.)"
(`postgres/src/backend/access/nbtree/README:232-239`). Unlike this chapter, Postgres never
deletes the rightmost page of a level, so its tree never loses a level. Like this chapter, it
removes an interior page only together with its last child (exercise 4).

### When may a freed page be reused?

| System | Where a freed page waits | It may be reused when |
|---|---|---|
| This chapter | free list (trunk pages) in the file | immediately, by the next allocation |
| Turso | freelist trunk pages in the file, same structure (`sqlite3_ondisk.rs:89-97`, `turso/core/storage/pager.rs:5588-5725`, `:5853-6087`). It hands out the first listed page and shifts the rest (`pager.rs:5960-6017`); this chapter takes the last | by the next allocation; trunk and reused page reach the file through the WAL with the rest of the transaction (`add_dirty`, `pager.rs:5681`, `:5990`) |
| Postgres | the page stays in place as a deleted tombstone carrying `safexid`; later it is recorded in the free space map | once `safexid` is old enough (`BTPageIsRecyclable`, `nbtree.h:291-319`; `_bt_allocbuf` re-checks at `nbtpage.c:910`): "A deleted page cannot be recycled immediately, since there may be other processes waiting to reference it" (`README:319-325`) |
| DuckDB | an in-memory set of block ids, `modified_blocks` | after the next checkpoint: "this block was used in storage, we cannot directly re-use it" (`duckdb/src/storage/single_file_block_manager.cpp:1024-1028`); the blocks join the free list when the new header is written (`:1454-1458`). Only a block first used since the last checkpoint goes straight back (`:1018-1022`) |
| TigerBeetle | a "released" bit in the free set | after the next checkpoint is durable: "Leave the address acquired for now, but free it when the next checkpoint becomes durable" (`tigerbeetle/src/vsr/free_set.zig:509-511`) |

Postgres waits for *readers*: a concurrent scan may still follow a link to the page. DuckDB
and TigerBeetle (block allocators without a B-tree) wait for *recovery*: the last durable
state still refers to the block, and a crash would return to that state (part 5 is this
failure in miniature). Turso does not wait, because its log makes the whole transaction
atomic. This chapter has neither readers nor a log, so it does not wait and is not safe.

## Allocator notes

**The featured allocator: `std.heap.BufferFirstAllocator`** (Zig 0.17's replacement for
`stackFallback`). It tries a fixed buffer first and falls back to another allocator when the
request does not fit, and it tells by address which of the two a slice came from.

Reading a value needs a buffer of 0 to 65536 bytes, and most values are small. Two places
use it:

- **The caller of `get`.** `get` takes an `Allocator` and makes exactly one allocation. Part 4
  of the demo passes a `BufferFirstAllocator` over a 1088-byte array in its own stack frame,
  with the general-purpose allocator behind it: of 383 values, 240 are assembled on the stack
  and 143 on the heap. The tree does not know.
- **`RangeIterator`.** It contains `inline_buf: [1088]u8`, and each `next` puts a
  `BufferFirstAllocator` over it with the tree's allocator as fallback. 1088 is X: only a
  value that had an overflow chain costs a heap allocation.

Lifetime: the value returned by `next` is valid until the next call. That call, or `deinit`,
frees it; a fresh `BufferFirstAllocator` over the same buffer can do so because ownership is
decided by address.

With other allocators: chapter 12's fixed inline buffer would make the iterator 64 KiB. The
general-purpose allocator alone costs an allocation and a free per entry scanned. The
per-operation arena cannot be reset between calls of `next`, so it would grow by every value
scanned.

**The arena per operation** is chapter 12's, with one more thing in it: the list of pages
`removeLeaf` is about to free. The value field `put` builds (at most 1096 bytes) is a stack array.

Tests: allocation failure is injected into `get`'s allocator, into the iterator's fallback,
and into every scratch request of four puts that split and three deletes that free pages.
Each run ends with `OutOfMemory`, no pin, and an intact tree or a poisoned handle. Rust does
not simulate allocation failure.

## Pitfalls

- **A freed page's `kind` byte tells you nothing.** A page that was appended to a trunk is not
  written: it still looks like the leaf or overflow page it was. Only reachability decides a
  page's role. That is why part 5's damaged file validates.
- **A trunk is a free page too.** `free_count` counts trunks, and an allocation may hand one out.
- **Empty is not nearly empty.** One 10-byte cell keeps a 4096-byte leaf alive. Random deletes
  rarely empty a leaf; the model test needs range deletes ("sweeps") to reach the page-freeing
  code at all.

## Exercises

1. (easy) By hand: local bytes and overflow pages for P = 4628, 4629, 5172, 5173 and 65536.
   Then: how many cells with a 2-byte key fit in one leaf if every value has 1088, 5173 or
   9000 bytes? What does that say about choosing M?
2. (medium) `allocPage` fetches a reused page, which reads it from the storage, and then
   erases it. Add a pool function that pins a page without reading it and use it. How many
   reads does part 3 save?
3. (medium) Set `min_local = max_local` (always keep as much as allowed in the leaf). Predict
   how the page counts of part 2 change, then run it.
4. (hard) Build a tree in which an interior page that is not the root has one child and no
   key. Why does `validate` accept it? What would it take to remove such pages?
5. (hard) Delay reuse: pages freed since the last `flush` go to a list in memory and join the
   free list only after the flush has succeeded. Run part 5 again. What changes, and what
   still goes wrong?

Solutions: [solutions.md](solutions.md).

## Where next

- Previous: [chapter 12, a disk-backed B+tree](../12-disk-backed-bplus-tree/README.md)
- Next: [chapter 14, split policies and fill factor](../14-split-policies-and-fill-factor/README.md)
- Later: [chapter 15](../15-redistribution-and-merge-policies/README.md) (merge policies),
  [chapter 22](../22-wal-and-crash-recovery/README.md) (atomic multi-page changes),
  [chapter 24](../24-mvcc-vacuum-and-page-deletion/README.md) (Postgres's page deletion).
- Visualization: [a value spilling into a chain, pages going to the free list and coming back](viz/index.html)
- Output of both programs: [expected_output.txt](expected_output.txt)

# Chapter 23: Copy-on-write B-trees

## What you will learn

- How a B+tree can be updated without ever overwriting a page that a reader
  might be looking at: **path copying**.
- How a commit becomes one small write, the **root flip**, through a metapage
  with two checksummed slots, and why two slots are enough to survive a torn
  write.
- How old versions of the tree stay readable as **snapshots**, and what that
  costs.
- When a replaced page may be reused: the **pending-free list** and the rule
  that releases it.
- Why a copy-on-write tree **cannot have leaf sibling links**, and how range
  scans work without them.

Prerequisites: chapter 07 (the in-memory B+tree this chapter starts from),
chapter 09 (pages named by page ids), chapter 21 (torn writes and checksums).
Chapter 22 solves the same problem, atomic multi-page updates, in the other
classic way: update in place and keep a write-ahead log. Reading both shows
the trade.

## The idea in plain words

Chapter 22 made a split atomic by writing every change twice: first to a log,
then to the page. Copy-on-write (COW) takes the opposite route. It has one
rule:

> A page that a committed root can reach is never modified.

A transaction that wants to change a leaf writes the new version of that leaf
into a **free** page instead. The parent still points at the old leaf, so the
parent needs a new version too, in another free page, pointing at the new
leaf. So does its parent, up to the root. The result is a new root from which
the changed tree is visible, and it shares every page that is not on the path
with the old tree:

```
old root #9 [15]                         new root #2 [15]
   |        \                               /        |
#4 [6 10]    \_______ #8 [20] ____________/      #5 [6 10]
 |   |   \            /     \                    /  |   \
#3  #6   #0        #7       #1    (shared) -> #3   #6   #10
           (10 12)                                     (10 12 13)
```

Only three pages were written (`#2`, `#5`, `#10`), one per level. Five pages
belong to both trees. At this point nothing is committed: the database still
says "the root is #9".

**Commit** is the act of changing that one fact. It is a single small write
into the **metapage**. Before the write, every reader finds the old tree;
after it, the new one. There is no moment at which a reader can see half of a
split, so no log is needed to repair one.

The metapage is the only place that is overwritten, so it needs protection of
its own. It has **two slots**. Each holds a transaction id, the root page id
and a checksum. Commits alternate: transaction 7 writes slot 1, transaction 8
writes slot 0. A reader takes the slot with a valid checksum and the higher
transaction id. If the write of transaction 8 is torn, slot 0 fails its
checksum and the reader falls back to slot 1: transaction 7, complete.

### Snapshots

The old root does not stop working when a new one is committed. As long as
nobody overwrites its pages, a reader holding "root #9" keeps seeing the tree
exactly as it was. That handle is a **snapshot**. Taking one copies nothing;
it only registers the root so that its pages are left alone. In this chapter
snapshots are refcounted: two readers of the same root share one entry, and
the root is unpinned when the last of them lets go.

The code is single-threaded, so "reader" means a handle that stays valid
across later commits, not a thread. The property that would make real
concurrent readers easy is already visible: a reader needs no latch on any
page, because no page it can reach ever changes.

### When may a page be reused?

Transaction T copied pages `#9 #4 #0`. The old versions are unreachable from
T's root. They are reachable from the roots of earlier transactions and from
no later one. So:

> A page freed by transaction T may be reused once no snapshot older than T
> remains.

Until then it sits on the **pending-free list**, tagged with T. The store
therefore has three kinds of page: reachable from the current root, pending,
and free. `validate` checks that these three sets never overlap and together
cover the store.

Two details follow from the rule. With no snapshot at all, the pages freed by
T become free as soon as T's meta slot is written, and transaction T+1 reuses
them: the store stops growing. And T+1 may overwrite them safely even though
the *previous* meta slot (T-1) still points at them, because T-1 is only a
fallback for a torn write of T, and T is already complete when T+1 starts.

### Why the leaf chain has to go

Chapter 07 linked every leaf to its neighbours so that a range scan could walk
sideways. Try to keep that under path copying. Leaf `#0` is copied to `#10`.
Its left neighbour `#6` has a `next` link that says `#0`. For the new tree
that link must say `#10`, so `#6` has to change, so `#6` must be copied, say
to `#11`. Now the `next` link of *its* left neighbour is wrong. The copying
runs along the whole chain, and every copied leaf needs its parent copied.
One insert would rewrite the entire tree.

The underlying reason: path copying works because each page is pointed at by
exactly one other page, its parent. A sibling link is a second pointer to the
same page. So the leaves here have no links (`base_node.zig` removes them),
and `validate` rejects a page that is reached twice from one root.

Range scans use a **stack** instead. The cursor remembers the path from the
root to the current leaf as (page, position) pairs. When a leaf is exhausted
it pops, advances the parent's position and descends again. Turso's on-disk
tree has no sibling links either and scans the same way (chapter 08).

## A worked example by hand

M = 4, the canonical keys 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15, one
transaction per key. `#n` is a page id.

Transaction 1 (`put 10`) writes a leaf into page `#0`. Transaction 2
(`put 20`) may not change `#0`: it copies it to `#1`, adds 20 there and
commits root `#1`. Nobody holds a snapshot, so `#0` is free at once, and
transaction 3 (`put 5`) copies `#1` right back into `#0`. The tree hops
between page ids while the store stays small. After 12 transactions:

```
txn 12: root #9, height 3, 12 keys
  level 0: #9[15]
  level 1: #4[6 10] #8[20]
  leaves : #3(1 3 5) #6(6 7) #0(10 12) | #7(15 17) #1(20 25 30)
store: 10 pages | free: #5 #2 | pending: -
```

Now a reader takes a snapshot of transaction 12, and transaction 13 does
`put 13`. The key belongs in leaf `#0`. Top down:

1. Copy root `#9` to a free page. The free list is used as a stack: `#2`.
2. Copy `#4` to `#5`, and make `#2` point at `#5`.
3. Copy `#0` to a new page `#10` (the free list is empty, the store grows),
   make `#5` point at `#10`, insert 13 there.
4. Commit: write pages `#2 #5 #10`, then write meta slot 1 with
   "txn 13, root #2".

Pages `#9 #4 #0` go to the pending list tagged 13. The snapshot of 12 is
older than 13, so they stay. The store now holds two complete trees in 11
pages:

```
shared by both roots: #1 #3 #6 #7 #8
only the old root   : #0 #4 #9
only the new root   : #2 #5 #10
```

`delete 6` (transaction 14) copies another path of three. `delete 7`
(transaction 15) leaves leaf `(6 7)` empty, which is below the minimum of
one key; it borrows 5 from its left sibling `(1 3 5)`. The sibling changes, so
**the sibling is copied too**: four copies, not three. Ten pages are now
pending and the store has grown to 18.

Releasing the snapshot removes the last root older than 13, 14 and 15. All
ten pending pages move to the free list, and `put 8` (transaction 16) takes
its three pages from there. The store stays at 18 pages.

## Code walk-through

The files, in reading order (same names in `zig/src/*.zig` and
`rust/src/*.rs`):

| File | Content |
| --- | --- |
| `base_node`, `base_search` | Copied from chapter 07 and trimmed: node layout without leaf links, in-node binary search |
| `crc32`, `ops` | Copied from `common/` |
| `meta` | The 32-byte meta slot: `encode`, `decode`, `pick` |
| `store` | `PageStore`: the page slab, the free list, the two meta slots |
| `read` | `View` (a root plus where to find pages): `get`, the stack `Cursor`, `range` |
| `db` | `Db`: committed root, refcounted snapshots, pending list, `reclaim`, `reopen` |
| `txn` | `WriteTxn`: `touch` (the copy), `put`, `delete`, `commit`, `abort` |
| `validate` | Every invariant as code |
| `dump`, `tests`, `main` | Text rendering, tests, the demo program |

### Zig

**The store** (`store.zig`) is an `ArrayList` of slots. A slot has a state
(`free` or `live`), the id of the transaction that last wrote it, and a node.
`write` asserts that the target slot is free. That assertion is the chapter's
rule in one line.

**The meta slot** (`meta.zig`) is real bytes: 28 bytes of little-endian
fields followed by their CRC-32. A slot of zeroes does not decode, because
the CRC of 28 zero bytes is not zero, so a never-written slot needs no flag.

```zig
pub fn pick(slots: *const Slots) ?Meta {
    const a = decode(&slots[0]);
    const b = decode(&slots[1]);
    if (a == null) return b;
    if (b == null) return a;
    return if (a.?.txn_id > b.?.txn_id) a else b;
}
```

**The transaction** (`txn.zig`) owns an arena. Every page it creates is
allocated there and recorded in `dirty`, a map from the page's future page id
to the node. The copy-on-write step:

```zig
fn touch(self: *WriteTxn, id: PageId) Allocator.Error!Page {
    if (self.dirty.get(id)) |node| return .{ .id = id, .node = node };
    try self.freed.ensureUnusedCapacity(self.arena.allocator(), 1);
    const copy = try self.allocPage(self.db.store.read(id).*);
    self.freed.appendAssumeCapacity(id);
    self.info.copied += 1;
    return copy;
}
```

A page already in `dirty` belongs to this transaction and is modified in
place, so a transaction copies each page at most once however many keys it
writes. `allocPage` takes a page id from the free list, or the next id past
the end of the store.

`put` and `delete` are chapter 07's recursive algorithms with two changes.
Each node is `touch`ed on the way down, and after the recursion the parent
stores the id the child reports back (`in.children[i] = r.id`), because the
child may have moved. The splicing of leaf links is gone. `delete` first
looks the key up read-only, so that deleting a missing key copies nothing.

Rebalancing has different costs than in chapter 07. A **borrow** changes the
sibling, so the sibling is copied. A **merge** only reads the sibling, so
`merge` builds the merged node in the page that is already a private copy and
drops the other one without copying it. Chapter 07 always merged right into
left; here the direction depends on which side is already private.

`commit` has four phases, and their order is the point:

1. Reserve memory (the only part that can fail). Nothing has changed yet.
2. Write the dirty pages into their slots. All are free slots, so the old
   tree is intact.
3. Set `db.current` and write `meta_slots[id % 2]`. This is the commit.
4. Append the replaced pages to `pending` and call `reclaim`.

A transaction that changed nothing skips all of it: no new root, no new id.

`abort` returns the page ids taken from the free list and frees the arena.
Nothing was written to the store, so there is nothing to undo. `abort` on a
closed transaction does nothing, which allows
`var txn = db.begin(gpa); defer txn.abort();`.

If `put` or `delete` fails with `OutOfMemory`, the private tree may be half
modified. The transaction is marked `failed`, `commit` returns
`error.TxnFailed`, and the caller aborts. The committed tree was never
involved.

**Snapshots** (`db.zig`). A `Snapshot` is four numbers (transaction id, root,
height, count). `Db.snapshots` holds one entry per pinned root with a
reference count. `reclaim` is the rule from above:

```zig
const oldest = if (self.snapshots.items.len > 0) self.snapshots.items[0].snap.id else std.math.maxInt(u64);
while (n < items.len and items[n].freed_by <= oldest) : (n += 1) {
    self.store.release(items[n].page);
}
```

`reopen` simulates a restart: pick a meta slot, forget snapshots and pending
pages, and rebuild the free list as every page the chosen root cannot reach.
A real engine keeps the free list in the file instead of scanning; this
program has everything in memory, so the scan is the honest equivalent.

**Validate** (`validate.zig`) walks the current root and every snapshot root.
Besides the B+tree invariants it checks: a page is reached once per root; a
page reachable from the root of transaction R was last written by a
transaction no later than R (so no page shared by two live roots was ever
modified); free, pending and reachable sets are disjoint and complete; a page
only a snapshot reaches is pending and freed by a later transaction.

### Rust

The Rust version has the same files, names, tests and output. The
differences:

- **Single writer by borrow.** `Db::begin(&mut self)` returns a
  `WriteTxn<'_>` that holds the `&mut Db`. A second writer, or a commit while
  a `db.view()` is alive, does not compile. Zig has a `writer_active` flag and
  an assertion. The price in Rust: to read the committed tree while a
  transaction is open you go through `txn.committed()`.
- **Abort is `Drop`.** `commit(self)` and `abort(self)` consume the
  transaction, and `impl Drop` returns the page ids. Letting a transaction go
  out of scope aborts it. Zig needs the explicit `defer txn.abort()`.
- **Drop-the-Vec instead of an arena.** The transaction's pages live in a
  `Vec<Node>`, and `dirty` maps a page id to an index in it. Dropping the
  transaction drops the `Vec`.
- **Indices instead of pointers.** Zig keeps a `*Node` into the arena across
  the recursive call. Rust cannot hold `&mut Node` while calling
  `self.insert_into`, so it looks the node up again by page id afterwards,
  and `borrow_from_left` carries the moved item by value from node to node.
- **Snapshots are `Copy` values in both.** A guard with `Drop` would have to
  borrow the `Db` and would then forbid every write while a snapshot exists.
- **Failure model.** A `Vec` aborts the process when memory runs out, so the
  Rust tests use `Db::page_budget`, a limit on the pages one transaction may
  hold, returning `Err(TxnError::OutOfPages)`. Zig's commit can fail and leave
  the transaction open; Rust's commit cannot run out of pages.
- The Rust cursor keeps its stack in a `Vec`; the Zig cursor uses a fixed
  array of 32 frames and allocates nothing.

### Output

Both programs print exactly this (`expected_output.txt`):

```
== 1. Build: canonical keys, M = 4, one transaction per put ==
put 10 -> txn 1  copied 0 reused 0 fresh 1 | freed 0 released 0 | root #0
put 20 -> txn 2  copied 1 reused 0 fresh 1 | freed 1 released 1 | root #1
put 5  -> txn 3  copied 1 reused 1 fresh 0 | freed 1 released 1 | root #0
put 6  -> txn 4  copied 1 reused 1 fresh 2 | freed 1 released 1 | root #3
put 12 -> txn 5  copied 2 reused 1 fresh 1 | freed 2 released 2 | root #0
put 30 -> txn 6  copied 2 reused 2 fresh 1 | freed 2 released 2 | root #2
put 7  -> txn 7  copied 2 reused 2 fresh 0 | freed 2 released 2 | root #4
put 17 -> txn 8  copied 2 reused 2 fresh 0 | freed 2 released 2 | root #1
put 3  -> txn 9  copied 2 reused 2 fresh 1 | freed 2 released 2 | root #3
put 25 -> txn 10 copied 2 reused 2 fresh 0 | freed 2 released 2 | root #0
put 1  -> txn 11 copied 2 reused 2 fresh 0 | freed 2 released 2 | root #5
put 15 -> txn 12 copied 2 reused 2 fresh 3 | freed 2 released 2 | root #9
txn 12: root #9, height 3, 12 keys
  level 0: #9[15]
  level 1: #4[6 10] #8[20]
  leaves : #3(1 3 5) #6(6 7) #0(10 12) | #7(15 17) #1(20 25 30)
store: 10 pages | free: #5 #2 | pending: -

== 2. Path copying: a snapshot keeps the old root alive ==
snapshot taken at txn 12 (root #9)
put 13 -> txn 13 copied 3 reused 2 fresh 1 | freed 3 released 0 | root #2
old tree, still readable through the snapshot:
txn 12: root #9, height 3, 12 keys
  level 0: #9[15]
  level 1: #4[6 10] #8[20]
  leaves : #3(1 3 5) #6(6 7) #0(10 12) | #7(15 17) #1(20 25 30)
new tree:
txn 13: root #2, height 3, 13 keys
  level 0: #2[15]
  level 1: #5[6 10] #8[20]
  leaves : #3(1 3 5) #6(6 7) #10(10 12 13) | #7(15 17) #1(20 25 30)
shared by both roots: #1 #3 #6 #7 #8
only the old root   : #0 #4 #9
only the new root   : #2 #5 #10
store: 11 pages | free: - | pending: #9(txn 13) #4(txn 13) #0(txn 13)

== 3. Two readers, two answers; range without sibling links ==
snapshot: get 13 = null, 12 keys
current : get 13 = 1300, 13 keys
snapshot range [6, 20): 6 7 10 12 15 17
current  range [6, 20): 6 7 10 12 13 15 17

== 4. Freed pages wait for the snapshot ==
delete 6 -> txn 14 copied 3 reused 0 fresh 3 | freed 3 released 0 | root #11
delete 7 -> txn 15 copied 4 reused 0 fresh 4 | freed 4 released 0 | root #14
store: 18 pages | free: - | pending: #9(txn 13) #4(txn 13) #0(txn 13) #2(txn 14) #5(txn 14) #6(txn 14) #11(txn 15) #12(txn 15) #13(txn 15) #3(txn 15)
snapshot still sees 12 keys, get 6 = 600
two handles on txn 12; release the first : 0 pages released
                       release the second: 10 pages move from pending to the free list
store: 18 pages | free: #9 #4 #0 #2 #5 #6 #11 #12 #13 #3 | pending: -
put 8  -> txn 16 copied 3 reused 3 fresh 0 | freed 3 released 3 | root #3
txn 16: root #3, height 3, 12 keys
  level 0: #3[15]
  level 1: #13[5 10] #8[20]
  leaves : #17(1 3) #12(5 8) #10(10 12 13) | #7(15 17) #1(20 25 30)
store: 18 pages | free: #9 #4 #0 #2 #5 #6 #11 #14 #15 #16 | pending: -

== 5. A transaction with several writes; abort ==
  put 26: 4 dirty pages, 3 copied so far
  put 27: 4 dirty pages, 3 copied so far
  put 28: 5 dirty pages, 3 copied so far
  inside the txn: get 27 = 2700; outside: get 27 = null
abort : current is still txn 16, root #3, get 27 = null
store: 18 pages | free: #9 #4 #0 #2 #5 #6 #11 #14 #15 #16 | pending: -
  put 26: 4 dirty pages, 3 copied so far
  put 27: 4 dirty pages, 3 copied so far
  put 28: 5 dirty pages, 3 copied so far
  inside the txn: get 27 = 2700; outside: get 27 = null
commit -> txn 17 copied 3 reused 5 fresh 0 | freed 3 released 3 | root #16
txn 17: root #16, height 3, 15 keys
  level 0: #16[15]
  level 1: #13[5 10] #15[20 26 28]
  leaves : #17(1 3) #12(5 8) #10(10 12 13) | #7(15 17) #14(20 25) #11(26 27) #6(28 30)

== 6. The two-slot metapage; a torn commit ==
  slot 0: txn 16, root #3, height 3, 12 keys, 18 pages, crc e2548d94  valid
  slot 1: txn 17, root #16, height 3, 15 keys, 18 pages, crc db104496  valid
  reader picks txn 17
flip one byte in slot 1, then restart:
  slot 0: txn 16, root #3, height 3, 12 keys, 18 pages, crc e2548d94  valid
  slot 1: stored crc db104496 does not match  INVALID
  reader picks txn 16
txn 16: root #3, height 3, 12 keys
  level 0: #3[15]
  level 1: #13[5 10] #8[20]
  leaves : #17(1 3) #12(5 8) #10(10 12 13) | #7(15 17) #1(20 25 30)
get 27 = null (the torn commit is gone, the one before it is intact)
store: 18 pages | free: #0 #2 #4 #5 #6 #9 #11 #14 #15 #16 | pending: -

== 7. Model run: 3000 operations, snapshots against saved oracle copies ==
M=4  keys=124 height=5 commits=1542 | pages: store=973 copied=7579 reused=6739 fresh=973 released=7597 peak pending=858 | snapshot checks=174 mismatches=0
M=5  keys=124 height=4 commits=1542 | pages: store=772 copied=6161 reused=5498 fresh=772 released=6205 peak pending=703 | snapshot checks=174 mismatches=0
M=8  keys=124 height=3 commits=1542 | pages: store=562 copied=4619 reused=4106 fresh=562 released=4631 peak pending=522 | snapshot checks=174 mismatches=0
```

Things to notice. In section 1 almost every commit reuses pages
(`reused 2 fresh 0`). In section 2 `released 0`: the snapshot holds the three
old pages. In section 4 `delete 7` shows `copied 4`, the borrow. In section 5
three puts into one transaction copy three pages in total, and the abort
leaves the `store:` line unchanged. In section 6 the restart falls back to
transaction 16; its page `#1` was replaced by transaction 17 and already
counted as free, but nobody had overwritten it yet. Section 7 shows what
snapshots cost: with three snapshots held 100 operations apart, a tree of 124
keys sits in a store of 973 pages (M = 4).

## In real databases

None of the databases in `db_study` is a copy-on-write B-tree. Two of them
use the same three mechanisms for other structures, and that is what the
references below show.

**DuckDB: alternating headers and deferred block reuse.** DuckDB's storage is
columnar with an ART index; it has no B-tree. Its file has two
`DatabaseHeader`s, each with an `iteration` counter, a pointer to the root
metadata block, a pointer to the free list and the block count
(`duckdb/src/include/duckdb/storage/storage_info.hpp:374-399`). On open, the
header with the higher iteration is used
(`duckdb/src/storage/single_file_block_manager.cpp:721-729`). A checkpoint
syncs the data blocks first, then writes the *other* header and syncs again
(`single_file_block_manager.cpp:1423-1424`, `:1443-1450`). A block that the
last checkpoint used is not reused directly; it goes to `modified_blocks`
"indicating it will be re-usable after the next checkpoint"
(`single_file_block_manager.cpp:1023-1028`,
`duckdb/src/include/duckdb/storage/single_file_block_manager.hpp:216-226`).
That is this chapter's metapage and pending list, per checkpoint instead of
per transaction. Both headers are read through `ReadAndChecksum`
(`:714-719`); what DuckDB does when one of them fails its checksum was not
traced (unverified).

**TigerBeetle: copy-on-write blocks, checksummed pointers, superblock.**
TigerBeetle stores LSM trees, not a B-tree, in a grid of blocks. Its
documentation describes the grid as "a purely functional, persistent (in both
senses), garbage collected data structure which is updated atomically by
swapping the pointer to the root node"
(`tigerbeetle/docs/internals/data_file.md:36-46`). A pointer to a block is an
address plus the block's checksum, and a read is validated against the
checksum the parent expected (`tigerbeetle/src/vsr/grid.zig:1421-1446`). A
released block stays allocated "but free it when the next checkpoint becomes
durable" (`tigerbeetle/src/vsr/free_set.zig:509-533`). The root is the
superblock, with a checksum, a `sequence` counter and the checksum of its
predecessor (`tigerbeetle/src/vsr/superblock.zig:53-79`). It is written as
four copies and the latest one with at least two copies wins, because a
superblock that stores its own checksum can be hidden by a misdirected read
(`tigerbeetle/docs/internals/data_file.md:74-80`). A pointer that carries the
child's checksum makes in-place update impossible: changing a child changes
its checksum, hence the parent. Path copying is then not a choice.

**LMDB** is the best-known copy-on-write B+tree: one writer, readers that pin
a transaction id, two meta pages, and freed pages recorded per transaction.
It is not in `db_study`; everything in this sentence is from memory and
**unverified**. The design in this chapter follows that general shape and
makes no claim to match LMDB in detail.

**Postgres and Turso** take the other route. Both update pages in place and
rely on a write-ahead log for atomicity (chapter 22). Postgres keeps leaf
sibling links, which in-place update makes cheap; old row versions are
handled by MVCC inside the pages rather than by keeping old pages
(chapter 24).

Textbook background: the technique is called shadow paging in the database
literature, and path copying is the standard way to make a tree persistent
in the functional-data-structure sense.

## Allocator notes

Two allocators with two lifetimes.

**The page slab** (`PageStore.slots`, an `ArrayList` on the general-purpose
allocator) lives as long as the database. Slots are fixed size and addressed
by index, never by pointer, so growing the list is harmless. Freed slots are
recycled through the free list; the list of free ids is pre-sized so that
releasing a page can never fail.

**One arena per write transaction.** Everything a transaction builds has the
same lifetime: until commit or abort. Page copies, the dirty map and the
lists all come from `std.heap.ArenaAllocator`, and `close` frees them with
one `deinit`. Abort is cheap and cannot leak, however the transaction failed.
Arena memory does not move, which is what allows `insertInto` to hold a
`*Node` across the recursive call.

What would go wrong otherwise: with the general-purpose allocator, every
error path in `put`, `delete` and `commit` would need `errdefer` cleanup for
each page copy, and the allocation-failure tests would report leaks at the
first mistake. With the arena for the *store*, committed pages would never be
freed individually. The tests run on `std.testing.allocator`;
`checkAllAllocationFailures` runs a whole scenario once per allocation and
requires an `OutOfMemory` and no leak each time.

In Rust the transaction owns a `Vec<Node>`; dropping it is the arena reset.

## Pitfalls

- **Reusing a freed page too early.** If transaction T reuses a page that T
  itself freed, a torn meta write of T falls back to T-1, whose tree now has
  a hole. Pages freed by T may be reused from T+1 on.
- **Changing the store before the last fallible step.** The first version of
  `commit` grew the store and *then* reserved the pending list. When that
  reservation failed, the store had more pages than the meta slot said. The
  allocation-failure test caught it through `validate` (`BadMeta`).
  Reservations first, mutation after.
- **One old reader holds back everything.** The rule looks only at the oldest
  snapshot. A snapshot of transaction 12 keeps every page freed by 13, 14,
  15, ... pending, including pages that were created *after* 12 and that it
  could never reach. Exercise 2 measures the difference.
- **Write amplification.** Changing one value writes `height` pages. A borrow
  writes one more. Chapter 22's log would have written one page image.
- **Copying on a miss.** Deleting a missing key must not `touch` anything, or
  it publishes a new root that differs from the old one only in page ids.
- **Half-modified private trees.** After a failed `put`, do not continue and
  commit.
- **Assuming sibling links.** Code ported from chapter 07 that walks
  `leaf.next` has no equivalent here; use the cursor.

## Exercises

1. (Easy) Start from the state after section 2 of the program (transaction
   13 committed, snapshot of 12 held). By hand, perform `delete 30`. Which
   pages are copied, what is the new tree, and what is on the pending list?
2. (Medium) Make reclamation precise: a page written by transaction B and
   freed by transaction T is needed only by snapshots S with B <= S < T.
   Change `reclaim` accordingly. Which tests change, and what happens to the
   store size in the model run?
3. (Medium) The fallback argument in "When may a page be reused?" claims that
   T+1 may overwrite pages that the meta slot of T-1 still points at. Which
   test would fail if that were wrong, and why does it pass?
4. (Medium) Give each child pointer a checksum of the child page, as
   TigerBeetle does. What has to change in `touch`, `commit` and `validate`,
   and what would it detect that a per-page checksum does not?
5. (Hard) `reopen` rebuilds the free list by walking the tree. Design a way
   to store the free list and the pending list in pages of the same store, so
   that a restart does not scan. What must be true of the pages that hold the
   list itself?

Solutions: [solutions.md](solutions.md).

## Links

- Previous: [chapter 22, WAL and crash recovery](../22-wal-and-crash-recovery/README.md)
- Next: [chapter 24, MVCC, vacuum and page deletion](../24-mvcc-vacuum-and-page-deletion/README.md)
- Visualization: [viz/index.html](viz/index.html) (two roots sharing
  subtrees, path copying step by step, the meta slots, pending and free
  pages)
- Code: [zig/src](zig/src), [rust/src](rust/src)

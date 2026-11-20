# Chapter 23: Copy-on-write B-trees

## What you will learn

- How a B+tree can be updated without ever overwriting a page that a reader
  might be looking at: **path copying**.
- How a commit becomes one small write, the **root flip**, through a metapage
  with two checksummed slots, what has to be true for the second slot to be
  a real fallback, and which faults that covers.
- How old versions of the tree stay readable as **snapshots**, and what that
  costs.
- When a replaced page may be reused: the **pending-free list** and the rule
  that releases it, including the part that waits for the *next* commit.
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
old root #11 [15]                        new root #2 [15]
   |        \                               /        |
#7 [6 10]    \_______ #10 [20] ___________/      #6 [6 10]
 |   |   \            /     \                    /  |   \
#5  #8   #0        #9       #3    (shared) -> #5   #8   #12
           (10 12)                                     (10 12 13)
```

Only three pages were written (`#2`, `#6`, `#12`), one per level. Five pages
belong to both trees. At this point nothing is committed: the database still
says "the root is #11".

**Commit** is the act of changing that one fact. It is a single small write
into the **metapage**. Before the write, every reader finds the old tree;
after it, the new one. There is no moment at which a reader can see half of a
split, so no log is needed to repair one.

On a real disk the order is part of the commit: sync the new pages, write the
slot, sync again, or the slot could name pages that never arrived. This
program has no disk; the order of its writes stands for the syncs.

The metapage is the only place that is overwritten, so it needs protection of
its own. It has **two slots**. Each holds a transaction id, the root page id
and a checksum. Commits alternate: transaction 7 writes slot 1, transaction 8
writes slot 0. A reader takes the slot with a valid checksum and the higher
transaction id. If the write of transaction 8 is torn, slot 0 fails its
checksum and the reader falls back to slot 1: transaction 7, complete.

The same fallback serves when slot 0 was written correctly and cannot be read
later. That only works if the tree of transaction 7 is still all there,
which the reuse rule below has to guarantee.

### Snapshots

The old root does not stop working when a new one is committed. As long as
nobody overwrites its pages, a reader holding "root #11" keeps seeing the tree
exactly as it was. That handle is a **snapshot**. Taking one copies nothing;
it only registers the root so that its pages are left alone. In this chapter
snapshots are refcounted: two readers of the same root share one entry, and
the root is unpinned when the last of them lets go.

The code is single-threaded, so "reader" means a handle that stays valid
across later commits, not a thread. The property that would make real
concurrent readers easy is already visible: a reader needs no latch on any
page, because no page it can reach ever changes.

### When may a page be reused?

Transaction T copied pages `#11 #7 #0`. The old versions are unreachable from
T's root. They are reachable from the roots of earlier transactions and from
no later one. So a page freed by T is needed by exactly the roots older than
T that somebody may still read, and there are two kinds of those:

> A page freed by transaction T may be reused once
> 1. no snapshot older than T remains, **and**
> 2. the meta slot of T-1 can no longer be chosen by a restart, which is the
>    case when transaction T+1 has committed and overwritten it.

Until then it sits on the **pending-free list**, tagged with T. The store has
three kinds of page: reachable from the current root, pending, and free.
`validate` checks that these three sets never overlap and together cover the
store.

Part 1 is about readers. Part 2 is about restarts, and it is easy to get
wrong. The tempting argument goes: "T-1 is only a fallback for a torn write
of T; once T's slot is written completely, T-1 is not needed, so T+1 may
reuse the pages T freed." That holds for a crash and nothing else. Suppose
T+1 is in flight and has overwritten two of those pages, the power fails,
and on restart the slot of T turns out to be unreadable. The checksum of
T-1's slot is still valid, the reader picks it, and walks a tree in which two
pages now belong to T+1. A checksum on the slot says the 32 bytes are intact.
It says nothing about the pages.

With part 2 the code keeps a stronger invariant:

> At every moment, also in the middle of a commit, each meta slot names a
> complete tree or names nothing.

T+1 writes only free pages; the pages T replaced are pending until T+1's own
slot is durable, and that slot is the one that used to name T-1. Whichever
slot a restart can read, it finds a whole tree. The price is one commit's
worth of pages: with no snapshot at all, the store holds the tree plus two
paths instead of one, and then stops growing.

### The fault model

What a restart finds, fault by fault:

| Fault | Result |
| --- | --- |
| Power fails at any write of a commit (some pages written, or the meta slot torn after any byte) | the last complete commit |
| One meta slot cannot be read, for good or only at this restart, with or without a commit in flight | the commit in the other slot, complete |
| Neither slot can be read (or one at this restart and the other at the next, with no commit between) | the error `NoValidMeta` |
| A tree page is lost, changed after it was written, or written to the wrong place | **not defended**: see below |

Row 2 hides a trap: a read error can be transient. The slot of T cannot be
read today, so the restart falls back to T-1 and frees the pages only T
reached. If the slot answers correctly at the next restart, it wins by
transaction id and names a tree whose pages are gone, or rewritten by the
next transaction, which was given the id T again. So a restart **scrubs** a
slot it decided against: it overwrites the slot with zeroes before it frees
a single page. The invariant above then holds across restarts. The cost is
that a read error on the newest slot loses a durable commit; a real engine
retries the read first.

Row 4: **tree pages carry no checksum here**. A restart checks the shape of
the tree it walks (page ids, height, counts, the transaction that wrote each
page), not its content: a page whose keys rotted in place is served without
an error. A real store adds a checksum per page (chapter 21). TigerBeetle
stores a block's checksum in the pointer to it and checks every read against
what the parent expected (`tigerbeetle/src/vsr/grid.zig:1421-1446`): "The
block checksum is stored outside of the block itself, to protect from
misdirected writes" (`tigerbeetle/docs/internals/data_file.md:39`). That
also catches a page that is intact but the wrong one, such as a stale
version (exercise 4).

### Why the leaf chain has to go

Chapter 07 linked every leaf to its neighbours so that a range scan could walk
sideways. Try to keep that under path copying. Leaf `#0` is copied to `#12`.
Its left neighbour `#8` has a `next` link that says `#0`. For the new tree
that link must say `#12`, so `#8` has to change, so `#8` must be copied, say
to `#13`. Now the `next` link of *its* left neighbour is wrong. The same
happens to the right through the `prev` links. The copying runs along the
whole chain, and every copied leaf needs its parent copied. One insert would
rewrite the entire tree.

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
commits root `#1`. Nobody holds a snapshot, but `#0` is not free yet: meta
slot 1 still names transaction 1, whose root is `#0`. Transaction 3 (`put 5`)
therefore takes a new page `#2`; its commit overwrites slot 1, and now `#0`
is free. From here on each commit frees what the commit before it replaced.
The tree hops between page ids while the store stays small. After 12
transactions:

```
txn 12: root #11, height 3, 12 keys
  level 0: #11[15]
  level 1: #7[6 10] #10[20]
  leaves : #5(1 3 5) #8(6 7) #0(10 12) | #9(15 17) #3(20 25 30)
store: 12 pages | free: #6 #2 | pending: #4(txn 12) #1(txn 12)
```

`#4` and `#1` are the path transaction 12 replaced. They are the part of
transaction 11's tree that slot 1 still needs.

Now a reader takes a snapshot of transaction 12, and transaction 13 does
`put 13`. The key belongs in leaf `#0`. Top down:

1. Copy root `#11` to a free page. The free list is used as a stack: `#2`.
2. Copy `#7` to `#6`, and make `#2` point at `#6`.
3. Copy `#0` to a new page `#12` (the free list is empty, the store grows),
   make `#6` point at `#12`, insert 13 there.
4. Commit: write pages `#2 #6 #12`, then write meta slot 1 with
   "txn 13, root #2".

Slot 1 named transaction 11 until this write, so `#4` and `#1` are free now.
Pages `#11 #7 #0` go to the pending list tagged 13. Both parts of the rule
hold them: the snapshot of 12 is older than 13, and slot 0 names 12. The
store holds two complete trees in 13 pages:

```
shared by both roots: #3 #5 #8 #9 #10
only the old root   : #0 #7 #11
only the new root   : #2 #6 #12
```

`delete 6` (transaction 14) copies another path of three. `delete 7`
(transaction 15) leaves leaf `(7)` empty, which is below the minimum of one
key; it borrows 5 from its left sibling `(1 3 5)`. The sibling changes, so
**the sibling is copied too**: four copies, not three. Ten pages are now
pending and the store has grown to 18.

Releasing the snapshot removes the only reader. The six pages freed by 13 and
14 move to the free list. The four freed by 15 stay: slot 0 names transaction
14, and its root reaches them. `put 8` (transaction 16) takes its three pages
from the free list, and its commit releases those four. The store stays at 18
pages.

## Code walk-through

The files, in reading order (same names in `zig/src/*.zig` and
`rust/src/*.rs`):

| File | Content |
| --- | --- |
| `base_node`, `base_search` | Copied from chapter 07 and trimmed: node layout without leaf links, in-node binary search |
| `crc32`, `ops` | Copied from `common/` |
| `meta` | The 32-byte meta slot: `encode`, `decode`, `pick`, `fallback` |
| `store` | `PageStore`: the page slab, the free list, the two meta slots |
| `read` | `View` (a root plus where to find pages): `get`, the stack `Cursor`, `range` |
| `db` | `Db`: committed root, previous root, refcounted snapshots, pending list, `reclaim`, `reopen` |
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
2. Write the dirty pages into their slots. All are free slots, so the trees
   of both meta slots are intact.
3. Write `meta_slots[id % 2]`. This is the commit. Then `db.previous` becomes
   the root just replaced and `db.current` the new one.
4. Append the replaced pages to `pending` and call `reclaim`. It releases
   what the commit *before* this one replaced, never what this one did.

`Db.crash_after` is fault injection: the commit stops after that many device
writes (one per page, then one per byte of the meta slot, so that a slot can
be torn) and returns `error.Crashed`. The store is then what a disk would
hold after a power failure; the next call is `reopen`.
`PageStore.meta_read_fault` is the other injected fault: a meta slot that a
restart cannot read although its bytes are intact.

A transaction that changed nothing skips all of it: no new root, no new id.

`abort` returns the page ids taken from the free list and frees the arena;
nothing was written to the store, so there is nothing to undo. If `put` or
`delete` fails with `OutOfMemory`, the private tree may be half modified: the
transaction is marked `failed`, `commit` returns `error.TxnFailed`, and the
caller aborts.

**Snapshots** (`db.zig`). A `Snapshot` is four numbers (transaction id, root,
height, count). `Db.snapshots` holds one entry per pinned root with a
reference count. `reclaim` is the rule from above:

```zig
var oldest: u64 = std.math.maxInt(u64);
if (self.snapshots.items.len > 0) oldest = self.snapshots.items[0].snap.id;
if (self.previous) |p| oldest = @min(oldest, p.txn_id);
while (n < items.len and items[n].freed_by <= oldest) : (n += 1) {
    self.store.release(items[n].page);
}
```

`previous` is the root in the other meta slot: a snapshot that nobody can
release early.

`reopen` simulates a restart from what a file would hold: the two meta slots
and the pages. It picks a slot and checks its tree **while walking it**
(`treeIsComplete`), so the result is an error, never a panic: `NoValidMeta`,
or `CorruptTree` when a slot is intact and its tree is not (possible only in
row 4 of the fault table). The other slot stays the fallback if it holds an
older commit whose tree passes the same check; otherwise it is zeroed. Only
then is every page that no kept root reaches put on the free list. A real
engine keeps the free list in the file instead of scanning.

**Validate** (`validate.zig`) walks the current root, the previous root and
every snapshot root. Besides the B+tree invariants it checks three things
that belong to copy-on-write: a page reachable from the root of transaction
R was last written by a transaction no later than R; free, pending and
reachable pages are disjoint and together cover the store; and an older
commit in the other meta slot is `previous` (`FallbackUnprotected`
otherwise).

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
  `self.insert_into`, so it looks the node up again by page id afterwards.
- **Failure model.** A `Vec` aborts the process when memory runs out, so the
  Rust tests use `Db::page_budget`, a limit on the pages one transaction may
  hold, returning `Err(TxnError::OutOfPages)`. The injected crash is
  `Err(TxnError::Crashed)`, and `reopen` returns a `ReopenError`.

### Output

Both programs print exactly this (`expected_output.txt`):

```
== 1. Build: canonical keys, M = 4, one transaction per put ==
put 10 -> txn 1  copied 0 reused 0 fresh 1 | freed 0 released 0 | root #0
put 20 -> txn 2  copied 1 reused 0 fresh 1 | freed 1 released 0 | root #1
put 5  -> txn 3  copied 1 reused 0 fresh 1 | freed 1 released 1 | root #2
put 6  -> txn 4  copied 1 reused 1 fresh 2 | freed 1 released 1 | root #4
put 12 -> txn 5  copied 2 reused 1 fresh 1 | freed 2 released 1 | root #1
put 30 -> txn 6  copied 2 reused 1 fresh 2 | freed 2 released 2 | root #2
put 7  -> txn 7  copied 2 reused 2 fresh 0 | freed 2 released 2 | root #3
put 17 -> txn 8  copied 2 reused 2 fresh 0 | freed 2 released 2 | root #5
put 3  -> txn 9  copied 2 reused 2 fresh 1 | freed 2 released 2 | root #0
put 25 -> txn 10 copied 2 reused 2 fresh 0 | freed 2 released 2 | root #6
put 1  -> txn 11 copied 2 reused 2 fresh 0 | freed 2 released 2 | root #4
put 15 -> txn 12 copied 2 reused 2 fresh 3 | freed 2 released 2 | root #11
txn 12: root #11, height 3, 12 keys
  level 0: #11[15]
  level 1: #7[6 10] #10[20]
  leaves : #5(1 3 5) #8(6 7) #0(10 12) | #9(15 17) #3(20 25 30)
store: 12 pages | free: #6 #2 | pending: #4(txn 12) #1(txn 12)

== 2. Path copying: a snapshot keeps the old root alive ==
snapshot taken at txn 12 (root #11)
put 13 -> txn 13 copied 3 reused 2 fresh 1 | freed 3 released 2 | root #2
old tree, still readable through the snapshot:
txn 12: root #11, height 3, 12 keys
  level 0: #11[15]
  level 1: #7[6 10] #10[20]
  leaves : #5(1 3 5) #8(6 7) #0(10 12) | #9(15 17) #3(20 25 30)
new tree:
txn 13: root #2, height 3, 13 keys
  level 0: #2[15]
  level 1: #6[6 10] #10[20]
  leaves : #5(1 3 5) #8(6 7) #12(10 12 13) | #9(15 17) #3(20 25 30)
shared by both roots: #3 #5 #8 #9 #10
only the old root   : #0 #7 #11
only the new root   : #2 #6 #12
store: 13 pages | free: #4 #1 | pending: #11(txn 13) #7(txn 13) #0(txn 13)

== 3. Two readers, two answers; range without sibling links ==
snapshot: get 13 = null, 12 keys
current : get 13 = 1300, 13 keys
snapshot range [6, 20): 6 7 10 12 15 17
current  range [6, 20): 6 7 10 12 13 15 17

== 4. Freed pages wait for the snapshot ==
delete 6 -> txn 14 copied 3 reused 2 fresh 1 | freed 3 released 0 | root #1
delete 7 -> txn 15 copied 4 reused 0 fresh 4 | freed 4 released 0 | root #14
store: 18 pages | free: - | pending: #11(txn 13) #7(txn 13) #0(txn 13) #2(txn 14) #6(txn 14) #8(txn 14) #1(txn 15) #4(txn 15) #13(txn 15) #5(txn 15)
snapshot still sees 12 keys, get 6 = 600
two handles on txn 12; release the first : 0 pages released
                       release the second: 6 pages move from pending to the free list
store: 18 pages | free: #11 #7 #0 #2 #6 #8 | pending: #1(txn 15) #4(txn 15) #13(txn 15) #5(txn 15)
put 8  -> txn 16 copied 3 reused 3 fresh 0 | freed 3 released 4 | root #8
txn 16: root #8, height 3, 12 keys
  level 0: #8[15]
  level 1: #6[5 10] #10[20]
  leaves : #17(1 3) #2(5 8) #12(10 12 13) | #9(15 17) #3(20 25 30)
store: 18 pages | free: #11 #7 #0 #1 #4 #13 #5 | pending: #14(txn 16) #15(txn 16) #16(txn 16)

== 5. A transaction with several writes; abort ==
  put 26: 4 dirty pages, 3 copied so far
  put 27: 4 dirty pages, 3 copied so far
  put 28: 5 dirty pages, 3 copied so far
  inside the txn: get 27 = 2700; outside: get 27 = null
abort : current is still txn 16, root #8, get 27 = null
store: 18 pages | free: #11 #7 #0 #1 #4 #13 #5 | pending: #14(txn 16) #15(txn 16) #16(txn 16)
  put 26: 4 dirty pages, 3 copied so far
  put 27: 4 dirty pages, 3 copied so far
  put 28: 5 dirty pages, 3 copied so far
  inside the txn: get 27 = 2700; outside: get 27 = null
commit -> txn 17 copied 3 reused 5 fresh 0 | freed 3 released 3 | root #5
txn 17: root #5, height 3, 15 keys
  level 0: #5[15]
  level 1: #6[5 10] #13[20 26 28]
  leaves : #17(1 3) #2(5 8) #12(10 12 13) | #9(15 17) #4(20 25) #1(26 27) #0(28 30)

== 6. The two-slot metapage: restarts after damage ==
  slot 0: txn 16, root #8, height 3, 12 keys, 18 pages, crc d02616ec  valid
  slot 1: txn 17, root #5, height 3, 15 keys, 18 pages, crc 105c3fac  valid
  reader picks txn 17
put 9: power fails in the middle of the meta write of txn 18 (slot 0). Restart:
  slot 0: stored crc d02616ec does not match  INVALID
  slot 1: txn 17, root #5, height 3, 15 keys, 18 pages, crc 105c3fac  valid
  reader picks txn 17
get 9 = null, 15 keys (txn 18 never happened; txn 17 is complete)
store: 18 pages | free: #3 #7 #8 #10 #11 #14 #15 #16 | pending: -
put 9  -> txn 18 copied 3 reused 3 fresh 0 | freed 3 released 0 | root #16
store: 18 pages | free: #3 #7 #8 #10 #11 | pending: #5(txn 18) #6(txn 18) #2(txn 18)
put 4: power fails after the 3 page writes of txn 19, before its meta write.
On top of that, slot 0 (txn 18, the newest commit) has become unreadable. Restart:
  slot 0: stored crc a742313c does not match  INVALID
  slot 1: txn 17, root #5, height 3, 15 keys, 18 pages, crc 105c3fac  valid
  reader picks txn 17
txn 17: root #5, height 3, 15 keys
  level 0: #5[15]
  level 1: #6[5 10] #13[20 26 28]
  leaves : #17(1 3) #2(5 8) #12(10 12 13) | #9(15 17) #4(20 25) #1(26 27) #0(28 30)
get 9 = null, get 4 = null (txn 18 is lost with its slot; txn 17 is complete, although txn 19 had written pages)
store: 18 pages | free: #3 #7 #8 #10 #11 #14 #15 #16 | pending: -

== 7. Model run: 3000 operations, snapshots against saved oracle copies ==
M=4  keys=124 height=5 commits=1542 | pages: store=973 copied=7579 reused=6739 fresh=973 released=7592 peak pending=858 | snapshot checks=174 mismatches=0
M=5  keys=124 height=4 commits=1542 | pages: store=772 copied=6161 reused=5498 fresh=772 released=6201 peak pending=703 | snapshot checks=174 mismatches=0
M=8  keys=124 height=3 commits=1542 | pages: store=562 copied=4619 reused=4106 fresh=562 released=4628 peak pending=522 | snapshot checks=174 mismatches=0
```

Things to notice. In section 1 `released` lags one commit behind `freed`:
from `put 5` on each commit releases exactly what the previous one freed, and
when no page splits the store stops growing (`reused 2 fresh 0`). In section
4 `delete 7` shows `copied 4`, the borrow, and releasing the snapshot frees
6 of 10 pages: the other 4 wait for transaction 16. Section 6 restarts
twice: after a torn meta write, and after the double fault of "When may a
page be reused?", where the restart lands on transaction 17 with its tree
whole because the pages 18 replaced (`#5 #6 #2`) were still pending. Section
7 shows what snapshots cost: with three snapshots held 100 operations apart,
a tree of 124 keys sits in a store of 973 pages (M = 4).

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
last checkpoint used is not reused directly: "we cannot directly re-use it",
it goes to `modified_blocks` "indicating it will be re-usable after the next
checkpoint" (`single_file_block_manager.cpp:1023-1028`). That is this
chapter's metapage and pending list, per checkpoint instead of per
transaction, and the same shape as part 2 of the reuse rule: freed in one
checkpoint, reusable after the next. Both headers are read through
`ReadAndChecksum` (`:714-719`); what DuckDB does when one of them fails its
checksum was not traced (unverified).

**TigerBeetle: copy-on-write blocks, checksummed pointers, superblock.**
TigerBeetle stores LSM trees, not a B-tree, in a grid of blocks. Its
documentation describes the grid as "a purely functional, persistent (in both
senses), garbage collected data structure which is updated atomically by
swapping the pointer to the root node"
(`tigerbeetle/docs/internals/data_file.md:36-46`). A pointer to a block
carries the block's checksum (see "The fault model"). A released block stays
allocated: "free it when the next checkpoint becomes durable. This ensures
that it will not be overwritten during the current checkpoint — the block
may still be needed if we crash and recover from the current checkpoint"
(`tigerbeetle/src/vsr/free_set.zig:509-533`). That is the argument of this
chapter's rule in one sentence: a freed block belongs to a state a restart
can still land on. The root is the superblock, with a checksum, a `sequence`
counter and the checksum of its predecessor
(`tigerbeetle/src/vsr/superblock.zig:53-79`). It is written as four copies
and the latest one with at least two copies wins, because a superblock that
stores its own checksum can be hidden by a misdirected read
(`tigerbeetle/docs/internals/data_file.md:74-80`). A pointer that carries the
child's checksum makes in-place update impossible: changing a child changes
its checksum, hence the parent. Path copying is then not a choice.

**LMDB** is the best-known copy-on-write B+tree: one writer, readers that pin
a transaction id, two meta pages, freed pages recorded per transaction. It
is not in `db_study`, so that description is from memory and **unverified**.

**Postgres and Turso** take the other route: update in place, with a
write-ahead log for atomicity (chapter 22) and, in Postgres, MVCC inside the
pages instead of old pages (chapter 24).

Textbook background: the database literature calls the technique shadow
paging.

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

- **Reusing a freed page too early.** Pages freed by T may be reused from
  T+2 on, not from T+1 ("When may a page be reused?"). No single-fault test
  shows the difference.
- **Letting a checksum vouch for a tree.** A valid CRC on a meta slot proves
  that 32 bytes are intact. A restart walks nothing it has not checked.
- **Leaving a skipped slot in place.** A slot that a restart could not read
  may be readable next time, after its pages were freed. Scrub it first
  ("The fault model").
- **One old reader holds back everything.** The rule looks only at the oldest
  snapshot. A snapshot of transaction 12 keeps every page freed by 13, 14,
  15, ... pending, including pages that were created *after* 12 and that it
  could never reach. Exercise 2 measures the difference.
- **Write amplification.** Changing one value writes `height` pages. A borrow
  writes one more. Chapter 22's log would have written one page image.
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
3. (Medium) Delete the `previous` line from `reclaim`, so that only snapshots
   hold pages back (part 1 of the rule alone). Which tests fail and with
   which error? Then find the smallest history, in crashes and damaged
   slots, that makes `reopen` return `CorruptTree`.
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
  subtrees, path copying step by step, the meta slots and the fallback root,
  pending and free pages, a crash with an unreadable slot)
- Code: [zig/src](zig/src), [rust/src](rust/src)

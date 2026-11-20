# Chapter 24: MVCC, vacuum and page deletion

## What you will learn

- What multi-version concurrency control (MVCC) is, in three rules: transaction ids,
  row versions with a birth and a death, and snapshots that are just a number.
- Why, in a design like PostgreSQL's, a `DELETE` removes nothing from an index, and
  how the dead entries are cleaned up later in layers: a hint bit, deletion when a
  leaf would otherwise split, and VACUUM.
- Why a production B-tree does not merge half-empty pages, and how it deletes a
  completely empty one in two phases.
- Why a deleted page cannot be reused at once, and the rule that says when it can.
- The other design: keep the versions out of the tree and merge them in with a
  cursor (Turso).

Prerequisites: chapter 07 (B+tree, leaf chain, handles into an arena, duplicates
through a tie-breaker). No threads are used: everything "concurrent" here is an
interleaving of single steps, which is enough to show every problem.

## The idea in plain words

### MVCC primer

A reader that takes a long time should not block writers, and should still see one
consistent state of the data. MVCC gets this by never changing a row in place.

1. **Transaction ids.** Every write gets the next number from one counter. In this
   chapter the counter is called `now`.
2. **Row versions.** An update does not overwrite the row. It writes a new *version*
   and marks the old one as ended. Each version carries two numbers: `xmin`, the
   transaction that created it, and `xmax`, the transaction that ended it (0 while
   nobody has). A delete only sets `xmax`.
3. **Snapshots.** A reader notes the value of the counter when it starts. That number
   is its snapshot. It sees a version if and only if

   ```
   xmin <= snapshot   and   (xmax == 0 or xmax > snapshot)
   ```

That is the whole model of this chapter. It leaves out something real systems cannot:
here every transaction commits immediately and none aborts, so comparing numbers is
enough. A real system also has to ask whether `xmin` and `xmax` committed.

Old versions are garbage once nobody can see them. The **horizon** is the oldest
snapshot any reader still holds, or `now` if there are none. A version with
`xmax <= horizon` fails the visibility test for every open snapshot and for every
snapshot that will ever be taken: it is **dead to everyone**. Every clean-up step in
this chapter is justified by a comparison against the horizon.

The counter has a second job, as a clock. Page deletion (below) advances it by one, a
*tick*, without writing a row, and keeps the new value as a timestamp. A value used
that way is called an **epoch**. Because snapshots are values of the same counter, a
snapshot and an epoch can be compared: "snapshot < epoch" means "taken before that
moment".

### Where do the versions live? Two designs

**Versions referenced from inside the index (PostgreSQL).** The table holds every row
version; each version has an address (a TID). An index entry is `(key, TID)`. The
index does not know `xmin` or `xmax`: a reader follows the TID and the table decides
visibility. An update adds an index entry for the new version. A delete cannot remove
the entry of the old one: a snapshot taken before the delete still sees that version
and has to find it through the index. The entry is needed until the version is dead
to everyone, and no transaction is there to remove it at that moment. So the index
fills up with entries that point at dead versions. Somebody has to remove them later,
and the B-tree has to cope with pages that slowly become empty. This is the design
the chapter's code models.

**Versions outside the tree (Turso's MVCC mode).** The B-tree is not versioned at
all. Recent versions live in an in-memory ordered map next to it, and a cursor merges
the two: it looks at the next visible key from the map and the next key from the
B-tree and returns the smaller; on a tie the in-memory version wins, which is how an
update or a delete marker hides the row stored in the tree. Only a checkpoint writes
to the B-tree, so the tree never contains a dead entry and needs none of the
machinery below.

The first keeps the read path a plain index scan and pays with garbage inside the
tree; the second keeps the tree clean and pays with a second structure in front of
it.

### The garbage pipeline

In the first design, dead entries are removed by whoever is cheapest:

1. **Hint bit.** A scan that finds an entry's version dead to everyone sets one bit
   on the entry. Later scans skip it without visiting the table.
2. **Deletion instead of a split.** An insert that finds its leaf full first removes
   hinted entries (*simple deletion*); if none are hinted it may ask the table about
   the entries on this one page (*bottom-up deletion*). Only then does it split.
3. **VACUUM.** A background pass removes every entry whose version is dead to the
   horizon.

### Page deletion

VACUUM can leave a leaf completely empty, and many half-empty. Chapter 05 would
merge them. PostgreSQL never merges non-empty pages, for a reason that only appears
with concurrent readers: a scan sits *between* pages and remembers only "the next
page is P". Suppose a forward scan has read page A and is paused before B, and a
merge now moves B's items left into A. The scan goes on with B and never returns
them. So items move right (splits) or disappear; nothing else.

An empty page has no items to move, so it can be removed. The deletion has two
phases, and the page is reused in a third step:

1. **Half-dead** (phase 1). Remove the parent's downlink. The page's key range is
   given to its right sibling. No search from the root can reach the page any more.
2. **Unlink** (phase 2). Make the left sibling's right link skip the page, and stamp
   the page with a new epoch: a tick of the counter taken after the unlink. The page
   keeps its own right link.
3. **Recycle.** Much later, when the horizon has reached the stamp (no snapshot
   older than the stamp is open), put the page on the free list.

Why two phases and not one? They change different pages: the parent, then the left
sibling. This chapter's single-threaded model could do both at once, but a real
system locks each group of pages separately and logs each phase as its own record
(`N/README:247-259`, `:279-282`, `:688-692`; `N/` is explained under "In real
databases"). So the state in between must be a tree that searches and scans survive,
and one that a crash may leave behind for a later VACUUM to finish. PostgreSQL calls
it "a similar state as during a page split: the page has no downlink pointing to it,
but it's still linked to its siblings" (`N/README:257-259`).

Why the downlink first? Once it is gone, no new descent arrives at the page, while
the chain still carries every scan across it. The other order would leave a page
that the parent still routes to but that no scan passes: an insert sent there would
add an entry that scans never return.

Step 3 is delayed because of the scan that read "next page is P" just before step 2.
It will still arrive at P. If P is a tombstone with an intact right link, the scan
moves right and loses nothing. If P has been handed to a split somewhere else in the
tree, the scan reads unrelated keys and has no way to notice.

## A worked example by hand

Order M = 4, so a leaf holds at most 3 entries. An entry is written `key:xmin-xmax`;
`!` marks a hint. The two numbers are shown for the reader's benefit; the index does
not store them.

Transactions 1, 2, 3 insert rows 10, 20, 30. Snapshot A = 3 is taken. Transaction 4
updates row 20; transaction 5 deletes row 30. Snapshot B = 5 is taken.

```
#0(10:1- 20:2-4) -> #1(20:4- 30:3-5)
```

Four entries for two live rows. A sees `20:2-4` (2 <= 3, and 4 > 3) and `30:3-5`;
B sees `20:4-` and no row 30.

A scan under B visits all four entries. Two are invisible to it, but A is open, the
horizon is 3, and neither version has `xmax <= 3`: no hints. Close A. The horizon
jumps to 5, both versions are dead to everyone, and the next scan marks them:

```
#0(10:1- 20:2-4!) -> #1(20:4- 30:3-5!)
```

Insert 25 into `#1` (now 3 entries, full), then 27. The leaf is full, one entry is
hinted, it is dropped, and 27 fits: no split.

Now the page deletion. Twelve rows 10..120, rows 30..80 deleted, VACUUM has removed
the six dead entries but was told to leave pages alone:

```
level 1: #2[30 50]  #6[90 110]
leaves : #0(10 20) -> #1() -> #3() -> #4() -> #5(90 100) -> #8(110 120)
```

A scan under snapshot S = 18 reads `#0`, returns 10 and 20, remembers "next = #1" and
pauses.

*Phase 1 on #1.* Its parent `#2` has children `#0 #1 #3` and separators `30 50`. Make
the slot of `#1` point at `#3` and remove separator 50: children `#0 #3`, separator
`30`. `#3` now covers everything from 30 up to the parent's upper bound, which
includes the old range of `#1`. No key in any leaf was touched. `#1` is half-dead and
still in the chain.

*Phase 2.* `#0.next` becomes `#3`. `#1` is stamped with a new tick of the counter,
19, and keeps `next = #3`.

*Recycle?* The horizon is 18 (snapshot S). 19 > 18: no.

*The scan resumes*, follows its saved link to `#1`, finds a deleted page, follows
`#1.next` to `#3`, and goes on to return 90, 100, 110, 120. Close S: the horizon is
19, and `#1` goes to the free list. The next split takes it.

## Code walk-through

Both languages have the same files, names, tests and output: chapter 07's arena, node
and search (`base_*`), plus `store`, `index`, `db`, `validate`, `dump`, `tests` and
`fuzz` (random interleavings of paused scans, writers, VACUUM and the three steps of
page deletion, checked against an oracle).

### Zig

`store.zig` is the primer as code: `Version.visible`, `Store.horizon` (a minimum
over a small array) and `Store.deadToAll` (`xmax != 0 and xmax <= horizon()`).

An index key is `(user key, tid)` packed into one `u64` (`base_node.pack`), the
tie-breaker idea of chapter 07, so that the many versions of one row are distinct
keys and the searches of chapter 07 work unchanged. User keys are therefore limited
to 32 bits in this chapter.

`Db.put` reserves a version slot and the worst-case number of pages first, and only
then ticks the counter, ends the current version, allocates the new one and calls
`Index.insertReserved`. After the two `reserve` calls nothing can fail, so there is
no rollback code. `Db.delete` is four lines and does not mention the index.

`Index.insertInto` differs from chapter 07 in one line: a full leaf calls `makeRoom`
before the insert. `makeRoom` calls `removeWhere(.hinted)` and, if the page is still
full and `bottom_up` is set, `removeWhere(.dead_to_all)`. `removeWhere` removes the
entry and then frees the version, in that order (see Pitfalls).

`Cursor` is the reader: a snapshot, bounds, a buffer of rows and `next_leaf`, the
handle of the page to read when the buffer is empty. `readPage` walks right over
pages that are not `live`, reads one leaf completely, copies out the visible rows,
sets hints on entries that are dead to all, and saves the page's right link.

`Index.markHalfDead` is phase 1. It finds the parent slot by walking the internal
pages (an empty leaf has no key to search for), refuses the rightmost child, then:

```zig
parent.kind.internal.children[link.slot] = parent.kind.internal.children[link.slot + 1];
parent.internalRemoveAt(link.slot);
leaf.kind.leaf.state = .half_dead;
```

`Index.unlinkHalfDead` is phase 2. The stamp is `store.tick()`, a *new* epoch taken
after the unlink, so that "snapshot < stamp" means exactly "taken before the unlink".
Deleted pages are threaded onto an intrusive FIFO (`next_deleted`), so nothing is
allocated. `Index.recycle(horizon)` frees from the head while `stamp <= horizon`.

`Db.vacuum` walks the leaf chain once and does all of it: remove entries, finish
half-dead pages, delete emptied leaves, recycle. It never allocates, so it cannot
fail.

### Rust

The port is line for line where the borrow checker allows it. The differences:

- **Handles instead of pointers.** Zig keeps `*Node` across calls (`makeRoom(store, n)`).
  Rust passes the `NodeId` and looks the node up again (`make_room(store, id)`),
  because a `&mut Node` would keep the whole arena borrowed. `split_leaf` uses the
  arena's `pair_mut` to hold two pages at once.
- **The cursor does not borrow the `Db`.** `Cursor::next(&mut self, db: &mut Db)`
  takes the database on every call. A cursor holding `&Db` would make the compiler
  reject every interleaving this chapter is about: "no writers while a reader
  exists" is the guarantee a database cannot afford. The page handle in the cursor
  is the unchecked reference that replaces the borrow, and the recycling rule is the
  lifetime rule the database must enforce itself.
- **`get` takes `&mut self`** in Rust and `*Db` in Zig, for the same reason: a read
  may set hint bits.
- **Allocation failure.** Zig tests `put` with a `FailingAllocator` at every
  allocation index. Rust's `Vec` aborts instead of failing, so the arenas carry a
  budget and `put` returns `Err(OutOfNodes)`.
- **Panics and errors.** Rust has two tests more (`#[should_panic]`, which Zig cannot
  express): an oversized key and a cursor whose snapshot was closed.
  `error.DanglingLink` is a unit struct.

### What the programs print

`zig build run` and `cargo run` print the same 111 lines
([expected_output.txt](expected_output.txt)). The first three sections are the first
half of the worked example. The core of the chapter is section 5:

```
== 5. Deleting an empty leaf: half-dead, unlinked, recycled ==
open snapshot S = 18; a scan under S returns: 10 20 and pauses; the next page it will read is #1
phase 1, mark #1 half-dead: done
  now=18 horizon=18 | height 3, 6 entries, 9 pages
  level 0: #7[70.6]
  level 1: #2[30.2] #6[90.8 110.10]
  leaves : #0(10:1- 20:2-) -> #1(half-dead) -> #3() -> #4() -> #5(90:9- 100:10-) -> #8(110:11- 120:12-)
phase 2, unlink #1: stamped with epoch 19
  now=19 horizon=18 | height 3, 6 entries, 9 pages
  level 0: #7[70.6]
  level 1: #2[30.2] #6[90.8 110.10]
  leaves : #0(10:1- 20:2-) -> #3() -> #4() -> #5(90:9- 100:10-) -> #8(110:11- 120:12-)
  deleted: #1@19->#3
recycle (horizon 18): pages freed 0
the scan resumes: 90 100 110 120 | moved right past 1 deleted page
close snapshot S; recycle (horizon 19): pages freed 1
```

(`30.2` is a separator: user key 30, tid 2.) Section 6 repeats this with the rule
switched off:

```
#1 is deleted with stamp 19; snapshot S = 18 is older, but we recycle anyway (pages freed 1)
the scan resumes at once: error.DanglingLink (the page is on the free list)
put 111=1110: xid 20
put 112=1120: xid 21; page full: leaf split into a recycled page
  ...
the scan resumes after the split: 120 <- 90, 100 and 110 are missing, and nothing reports an error
```

The first failure is the lucky one. The second is the real danger: the tree passes
`validate`, and the reader silently gets a wrong answer.

Section 7 runs 20000 random operations against the oracle (key space 400), holding a
long snapshot for 300 operations at a time and checking that it still reads its
frozen copy. Counts from its output, all with 278 live rows at the end and 0
mismatches:

| M = 4, collectors | entries | pages | splits | splits avoided | pages recycled | reused |
| --- | --- | --- | --- | --- | --- | --- |
| hints + bottom-up + vacuum | 278 | 423 | 1109 | 688 | 693 | 677 |
| hints + vacuum | 278 | 433 | 1207 | 317 | 781 | 762 |
| hints only | 1126 | 755 | 748 | 3411 | 0 | 0 |

Without VACUUM the index keeps 1126 entries for 278 rows. With it, most splits are
served from recycled pages; but 423 pages for 278 rows is the cost of never merging,
exaggerated here by a leaf capacity of 3.

## In real databases

All statements below were checked in the source trees under `db_study/`; see
[research/postgres.md](../../research/postgres.md) section 7 and
[research/turso.md](../../research/turso.md) section 15. Paths:
`N/` = `postgres/src/backend/access/nbtree/`.

**PostgreSQL, hint bits (LP_DEAD).** "If a process visits a heap tuple and finds
that it's dead and removable (ie, dead to all open transactions, not only that
process), then we can return to the index and mark the corresponding index entry
'known dead'" (`N/README:513-516`). The bit is set by `_bt_killitems`
(`N/nbtutils.c:190-390`, `ItemIdMarkDead` at `:361`) under a share lock, and scans
skip marked items (`N/nbtreadpage.c:249`). Our model sets the bit while reading the
page; PostgreSQL does it when the scan leaves the page. A scan that dropped its pin
on the page skips it entirely if the page changed in the meantime, because a TID may
have been recycled and reused (`N/README:474-489`).

**Simple and bottom-up deletion.** When an insert finds its leaf full,
`_bt_delete_or_dedup_one_page` first collects the LP_DEAD items and deletes them
(`N/nbtinsert.c:2756-2770`), then tries bottom-up deletion if the executor hinted
that the new tuple is a version-churn duplicate (`N/nbtinsert.c:2819-2821`,
`_bt_bottomupdel_pass` in `N/nbtdedup.c:308-423`), then deduplication (chapter 17),
and only then splits. Our `makeRoom` has the same order, but its bottom-up pass asks
about every entry on the page, while PostgreSQL asks only about promising duplicates
and only when hinted (`N/README:556-566`).

**VACUUM.** `btvacuumscan` (`N/nbtree.c:1270-1431`) reads the index in physical block
order, not in key order as our chain walk does, and needs a per-split "vacuum cycle
id" to cope with concurrent splits (`N/nbtree.c:1581-1586`). It also deletes emptied
leaves and finishes half-dead pages left by an interrupted deletion.

**No merging.** "We consider deleting an entire page from the btree only when it's
become completely empty of items. (Merging partly-full pages would allow better space
reuse, but it seems impractical to move existing data items left or right to make
this happen --- a scan moving in the opposite direction might miss the items if so.)
Also, we *never* delete the rightmost page on a tree level" (`N/README:235-240`).

**Two phases.** The eligibility test is at `N/nbtpage.c:1906-1908`. Phase 1,
`_bt_mark_page_halfdead`, does exactly the parent surgery of our `markHalfDead`: set
the target's pivot to point at the right sibling, delete the next pivot, set
`BTP_HALF_DEAD` (`N/nbtpage.c:2232-2246`). Phase 2, `_bt_unlink_halfdead_page`,
stores `safexid = ReadNextFullTransactionId()` in the page (`N/nbtpage.c:2671-2672`).
PostgreSQL's leaves also have left links, which phase 2 updates; ours do not.
Differences: PostgreSQL can delete the rightmost child of a parent when it is the
only child, removing the parent with it (a "skinny subtree", `N/README:240-245`); our
model never does. PostgreSQL re-finds the parent through the page's high key; our
pages have none, so `findDownlink` walks the internal pages.

**Recycling.** "A deleted page cannot be recycled immediately, since there may be
other processes waiting to reference it (ie, search processes that just left the
parent, or scans moving right or left from one of the siblings). ... they recover by
moving right" (`N/README:319-324`). `BTPageIsRecyclable` asks whether `safexid` could
still be visible to anyone (`nbtree.h:296-319`); forward scans skip ignorable pages
and continue with the saved right link (`N/nbtsearch.c:1921-1929`). Our epoch stamp
and horizon are the same idea with one counter for both jobs; PostgreSQL uses its
transaction-id horizon. Since version 14 the VACUUM that deleted a page may also
recycle it at the end of the same scan (`N/README:417-424`), as our `vacuum` does.

**Turso.** `MvStore` keeps row versions in a skip map; a `RowVersion` has `begin`
and `end` timestamps (`turso/core/mvcc/database/mod.rs:456-476`). `MvccLazyCursor`
(`turso/core/mvcc/cursor.rs:541`) wraps a B-tree cursor; the merge of the two streams
is `DualCursorPeek::get_next` (`:222-275`), and on equal keys the MVCC side wins
(`:257`). A checkpoint writes committed versions into the B-tree
with ordinary cursor operations (`turso/core/mvcc/database/checkpoint.rs`). The
version store has its own garbage collector (`gc_version_chain`,
`turso/core/mvcc/database/mod.rs:8625`), which this guide did not study.

## Allocator notes

Both the pages and the row versions live in chapter 07's `Arena(T)`: one growable
slot array with a free list, backed by whatever `std.mem.Allocator` the caller passes
to `put`. This is the natural choice here because the chapter's subject is the free
list itself. A recycled page is `arena.free(id)`, and "the next split reuses it" is
`allocAssumeCapacity` popping the list. A page handle that outlives its page is
exactly a dangling `NodeId`, which the arena's slot tag lets `Cursor.readPage` detect
as `error.DanglingLink` instead of reading freed memory.

Lifetimes: a page lives from the split that created it to the `recycle` that frees
it, long after it left the tree; a version lives from its `put` until its index
entry is removed. Reclaimed slots return to the pool, not to the operating system;
`deinit` releases the whole array.

What `std.testing.allocator` proves: every test ends with `db.deinit(gpa)`, and the
test fails if a single byte is still allocated, including pages that are half-dead,
deleted or on the free list at that moment. The model test additionally deletes every
row, vacuums, and reloads the rows, asserting that neither arena grows: the reclaimed
slots were reused. `put` is tested with a `FailingAllocator` at every allocation
index and must leave the database, including the transaction counter, unchanged.

What would go wrong with other choices: with `gpa.create` per page and raw pointers,
a premature recycle is a real use-after-free instead of a detectable stale handle. A
bump `ArenaAllocator` cannot return a single page, which is the one thing this
chapter needs. A deleted queue in an `ArrayList` would let VACUUM fail with
`OutOfMemory` halfway through a page deletion; the intrusive link avoids that.

## Pitfalls

- **Freeing the version before removing the entry.** TIDs are reused. If a version
  slot is freed while an index entry still points at it, the next insert may put an
  unrelated row there and the old entry now "finds" it. Entry first, version second;
  PostgreSQL's VACUUM cleans indexes before it frees table item pointers for the same
  reason.
- **Setting a hint for "invisible to me".** A hint means dead to *everyone*. A
  version your snapshot cannot see may be visible to an older one. `validate` has a
  check for this (`LyingHint`).
- **Stamping at the wrong moment.** The stamp must be taken after the page left the
  chain. Stamp at half-dead time and a scan that reads the still-chained page
  afterwards has a snapshot >= stamp and no protection.
- **Clearing the deleted page's right link.** It looks tidy and strands every reader
  that is on its way to the page.
- **Using a cursor after closing its snapshot.** The open snapshot is the only thing
  that keeps the cursor's saved page from being recycled. `seek` and every page read
  assert that it is still open.
- **One long-running snapshot.** It holds the horizon back: no hints, no bottom-up
  deletion, VACUUM removes nothing, deleted pages wait.
- **Expecting VACUUM to shrink the tree.** It never merges non-empty pages and never
  lowers the height. Empty pages that are rightmost children stay.

## Exercises

1. (easy) With the four versions `10:1-`, `20:2-4`, `20:4-`, `30:3-5` and no hints,
   what does a snapshot of 4 see? What is the horizon if snapshots 3 and 5 are open,
   and which versions are dead to everyone then?
2. (medium) Change `unlinkHalfDead` to stamp the page with `store.now` instead of
   `store.tick()`. Which tests fail, and why? Then change the comparison in
   `recycle` so that the scheme is safe again. What did you lose?
3. (medium) In `unlinkHalfDead`, also set the deleted page's `next` to nil. Predict
   what the paused scan of section 5 returns, then run it.
4. (medium) Count the leaves that are empty at the end of the first model run of
   section 7. Why can VACUUM not delete them?
5. (hard) Sketch the other design: a plain chapter 07 B+tree plus a sorted in-memory
   map from key to a list of versions, and a cursor that merges the two. What does
   `delete` write? What does a checkpoint do, and when may it drop a version?

Solutions: [solutions.md](solutions.md).

## Links

- Previous: [23. Copy-on-write B-trees](../23-copy-on-write-btrees/README.md)
- Next: [25. Cache-conscious search and layout](../25-cache-conscious-search-and-layout/README.md)
- Visualization: [viz/index.html](viz/index.html) (dead entries accumulating, hints,
  the vacuum sweep, and a page drawn as it goes from live to half-dead to deleted to
  free while a paused scan holds its handle)

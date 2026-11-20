# Chapter 23: solutions

Notation as in the chapter: `#n` page id, `[..]` internal node, `(..)` leaf.
Code is shown in Zig; the Rust version differs only in syntax. Every number
below was produced by running the chapter's code (for exercises 1 to 3) or is
marked as an expectation that was not measured (exercises 4 and 5).

## 1. `delete 30` under the snapshot

Start (transaction 13, snapshot of 12 held):

```
txn 13: root #2, height 3, 13 keys
  level 0: #2[15]
  level 1: #6[6 10] #10[20]
  leaves : #5(1 3 5) #8(6 7) #12(10 12 13) | #9(15 17) #3(20 25 30)
store: 13 pages | free: #4 #1 | pending: #11(txn 13) #7(txn 13) #0(txn 13)
```

30 is in leaf `#3`, reached through `#2` and `#10`. The copies are made top
down and the free list is a stack, so `#2 -> #1`, `#10 -> #4`, and the leaf
gets a new page: `#3 -> #13`. The leaf keeps two keys, which is above the
minimum of one, so nothing is borrowed or merged. Result, printed by a test
that runs exactly these steps (`copied 3 reused 2 fresh 1 | freed 3 released
0`, 14 pages):

```
txn 14: root #1, height 3, 12 keys
  level 0: #1[15]
  level 1: #6[6 10] #4[20]
  leaves : #5(1 3 5) #8(6 7) #12(10 12 13) | #9(15 17) #13(20 25)
free: - | pending: #11(txn 13) #7(txn 13) #0(txn 13) #2(txn 14) #10(txn 14) #3(txn 14)
```

Three things to notice. `#6` and `#12`, which transaction 13 created, are now
shared by roots 13 and 14. `released 0`: the pages freed by 13 would have
been released by this commit (slot 0, which named 12, was overwritten), but
the snapshot of 12 still holds them. And `#2`, created by 13 and freed by 14,
is pending for a good reason at this moment: slot 1 names transaction 13.
After the next commit no kept root reaches it, and it stays pending only
because the snapshot of 12 is older than 14: that is the imprecision
exercise 2 removes.

## 2. Precise reclamation

Each slot already records the transaction that wrote it (`written_by`), which
is the page's birth. A root R reaches a page exactly when `born <= R <
freed_by`. The rule becomes "release unless some kept root (a snapshot or
`previous`) is in that range", and the releasable entries are no longer a
prefix of the pending list:

```zig
pub fn reclaim(self: *Db) usize {
    const items = self.pending.items;
    var kept: usize = 0;
    var n: usize = 0;
    for (items) |p| {
        const born = self.store.slots.items[p.page.index()].written_by;
        var needed = false;
        for (self.snapshots.items) |s| {
            if (born <= s.snap.id and s.snap.id < p.freed_by) needed = true;
        }
        if (self.previous) |prev| {
            if (born <= prev.txn_id and prev.txn_id < p.freed_by) needed = true;
        }
        if (needed) {
            items[kept] = p;
            kept += 1;
        } else {
            self.store.release(p.page);
            n += 1;
        }
    }
    self.pending.shrinkRetainingCapacity(kept);
    self.stats.pages_released += n;
    return n;
}
```

Measured with this change applied to a scratch copy of the Zig project
(`zig build test --summary all`: 33 of 35 tests pass):

- Both model tests, the metapage test, all four restart tests (crash at every
  write, damaged slots, the long random run, forged slots), the
  allocation-failure tests and all fourteen corruption cases of `validate`
  still pass, without changing `validate`. The precise rule is as safe
  across restarts as the coarse one, because it still never releases a page
  that `previous` reaches.
- Two tests fail. "freed pages are reused only after the snapshots that need
  them are gone" asserts the coarse rule: 6 pages are pending after 20
  commits under a snapshot instead of 60 (the 3 the snapshot reaches and the
  3 of the newest commit). And "run prints exactly expected_output.txt"
  fails because the demo's output changes: in section 4 `delete 7` shows
  `released 2`, releasing the snapshot frees 4 pages instead of 6, the page
  ids differ from there on, and section 7 prints the smaller stores below.
- The demo's model run (section 7; three snapshots held, 100 operations
  apart) with the coarse and the precise rule:

  | M | store pages, coarse | store pages, precise | peak pending, coarse | peak pending, precise |
  | --- | --- | --- | --- | --- |
  | 4 | 973 | 354 | 858 | 234 |
  | 5 | 772 | 240 | 703 | 167 |
  | 8 | 562 | 147 | 522 | 106 |

  Mismatches stay at 0 in all three runs.

The cost is that `reclaim` is now a loop over pending pages times kept roots
instead of a prefix scan, and it needs the birth transaction of every pending
page. Whether that is worth it in a real engine depends on how long readers
live; that was not measured here.

## 3. The rule without its second half

Measured on a scratch copy of the Zig project with the line
`if (self.previous) |p| oldest = @min(oldest, p.txn_id);` deleted:
18 of 35 tests fail.

- Most of them fail in `validate` with `error.ReachablePageIsFree`: the walk
  of the previous root (invariant 10) reaches a page that is on the free
  list. That happens after the very first commit that replaces a page, so
  every test that validates a database with two or more commits reports it.
  This is the purpose of putting the invariant into `validate`: the bug shows
  without any crash.
- The tests that count pages fail on their numbers (for example "a put
  copies exactly the root-to-leaf path": `expected 2, found 0` released).
- "newest slot unreadable while the next commit is in flight" fails with
  `error.CorruptTree` from `reopen`. That is the smallest history:

  ```zig
  var db = try buildCanonical(gpa);          // 12 commits; slots: 0 = txn 12, 1 = txn 11
  db.crash_after = 3;                        // txn 13 writes its 3 pages ...
  _ = db.put(gpa, 13, 1300) catch {};        // ... and loses power before its meta write
  db.store.meta_slots[0][3] ^= 1;            // the slot of txn 12 is unreadable
  try db.reopen(gpa);                        // only txn 11 is left
  ```

  Without the line, transaction 13 took its page ids from pages that
  transaction 12 had freed, and the tree of transaction 11 still used them.
  The walk from 11's root meets a page whose `written_by` is 13 and stops.
  One crash is not enough to show this, and neither is one unreadable slot
  at rest: it takes both, with a commit in flight. That is why the first
  version of this chapter passed millions of single-fault cases with the
  bug in place.

Before `reopen` checked the tree it walked, the same history did not return
an error at all. It indexed past the end of the store (the stale root named a
store of 7 pages and reached page 10) and panicked.

## 4. Checksummed child pointers

Not implemented; the following is the expected design.

- Node layout: `Internal.children[i]` becomes a pair (page id, checksum of
  the child's bytes), and the meta slot stores the root's checksum next to
  the root's page id.
- `touch` stays as it is. The checksum of a dirty page is not known until the
  page is final, so the checksums are filled in at commit, bottom-up: a child
  must be final before its parent's entry for it can be computed. `commit`
  would walk the transaction's tree in post-order over dirty pages only
  (clean children keep the checksum already stored in their parent).
- `validate` (and every read, in a real engine) recomputes the checksum of a
  page it reaches and compares it with the one stored in the parent.

What it would detect beyond a checksum stored inside each page: a page that
is internally consistent but is the wrong page, for example a stale version
left behind by a lost write, or a write that landed at the wrong page id.
TigerBeetle states this purpose for its own blocks
(`tigerbeetle/docs/internals/data_file.md:36-46`). Note that with such
pointers copy-on-write is forced: any change to a child changes the parent.

## 5. Persisting the free and pending lists

Not implemented; an outline of the constraints.

- The lists must be reachable from the meta slot, so that the root flip
  publishes the tree and the lists together. Add "free-list root" to the meta
  slot.
- The pages holding the lists must themselves obey the rule: never
  overwritten while a committed meta slot points at them. So the list is
  written copy-on-write too, into free pages, and the pages of the old list
  version are freed by the same transaction, which means they belong on the
  new list's pending part. The list describes its own previous storage.
- That is circular: writing the list consumes free pages, which changes the
  list. A workable order is to reserve the pages for the new list first, then
  serialise the list with those pages already removed.
- Pending entries need their `freed_by` tag in the file. Snapshots are
  in-memory, so after a restart the pending entries of older transactions
  are releasable. The entries of the recovered transaction itself are not, as
  long as the other meta slot is readable: its root still reaches those
  pages. Entries written by a lost commit are never seen, because the
  recovered meta slot points at the older list.
- The list pages of the previous version must stay unwritten for one more
  commit as well, for the same reason as tree pages: the fallback slot
  points at them.

LMDB is usually described as keeping exactly such a list in a second B-tree
keyed by transaction id; that is from memory and unverified.

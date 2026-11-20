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
  level 1: #5[6 10] #8[20]
  leaves : #3(1 3 5) #6(6 7) #10(10 12 13) | #7(15 17) #1(20 25 30)
store: 11 pages | free: - | pending: #9(txn 13) #4(txn 13) #0(txn 13)
```

30 is in leaf `#1`, reached through `#2` and `#8`. The free list is empty, so
the three copies get new page ids in top-down order: `#2 -> #11`,
`#8 -> #12`, `#1 -> #13`. The leaf keeps two keys, which is above the minimum
of one, so nothing is borrowed or merged. Result, printed by a test that runs
exactly these steps (`copied=3 fresh=3 freed=3`, 14 pages):

```
txn 14: root #11, height 3, 12 keys
  level 0: #11[15]
  level 1: #5[6 10] #12[20]
  leaves : #3(1 3 5) #6(6 7) #10(10 12 13) | #7(15 17) #13(20 25)
pending: #9(txn 13) #4(txn 13) #0(txn 13) #2(txn 14) #8(txn 14) #1(txn 14)
```

Two things to notice. `#5` and `#10`, which transaction 13 created, are now
shared by roots 13 (no longer held by anyone) and 14. And `#2`, created by 13
and freed by 14, is pending although the only snapshot (of 12) cannot reach
it: that is the imprecision exercise 2 removes.

## 2. Precise reclamation

Each slot already records the transaction that wrote it (`written_by`), which
is the page's birth. The rule becomes "release unless some snapshot S has
`born <= S < freed_by`", and the releasable entries are no longer a prefix of
the pending list:

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

Measured with this change applied to a scratch copy of the Zig project:

- Both model tests, the metapage test, the allocation-failure tests and all
  twelve corruption cases of `validate` still pass, without changing
  `validate`.
- Two tests fail, both because they assert the coarse rule. In "the oldest
  snapshot holds back every later free" releasing the younger snapshot now
  frees 3 pages instead of 0 (and the older one the remaining 3). In "freed
  pages are reused only after the snapshots that need them are gone" 3 pages
  are pending after 20 commits instead of 60: only the first commit after the
  snapshot replaces pages the snapshot can reach.
- The demo's model run (section 7; three snapshots held, 100 operations
  apart) with the coarse and the precise rule:

  | M | store pages, coarse | store pages, precise | peak pending, coarse | peak pending, precise |
  | --- | --- | --- | --- | --- |
  | 4 | 973 | 350 | 858 | 229 |
  | 5 | 772 | 237 | 703 | 164 |
  | 8 | 562 | 145 | 522 | 103 |

  Mismatches stay at 0 in all three runs.

The cost is that `reclaim` is now a loop over pending pages times snapshots
instead of a prefix scan, and it needs the birth transaction of every pending
page. Whether that is worth it in a real engine depends on how long readers
live; that was not measured here.

## 3. Why the fallback is safe

The test is "commits alternate between the meta slots; a torn slot falls back
one commit". After every fourth commit it flips a bit in the slot that commit
wrote, calls `reopen`, and requires that the database is at the previous
transaction id, that `validate` passes, and that a full range scan equals the
oracle's content from before the commit. No snapshot is held in that test, so
every commit immediately frees the pages it replaced and the next commit
reuses them. The test passes in both languages.

Why: let the torn commit be T. T wrote only into slots that were free when T
started. A slot is free at that point only if the root of T-1 cannot reach it
(pages freed by T-1 were reachable from T-2, not from T-1). So the tree of
T-1 is untouched by T. The pages that T itself freed are reachable from T-1,
and they are still intact because nothing ran after T. If the rule were
wrong, say if T could reuse pages it freed itself, the range scan after the
fallback would differ from the saved oracle copy or `validate` would report a
bound or count violation.

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
  in-memory, so after a restart every pending entry of a transaction up to
  the recovered one is releasable; entries written by a lost commit are never
  seen, because the recovered meta slot points at the older list.

LMDB is usually described as keeping exactly such a list in a second B-tree
keyed by transaction id; that is from memory and unverified.

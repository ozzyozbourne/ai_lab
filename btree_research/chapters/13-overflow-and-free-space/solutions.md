# Chapter 13: solutions

Numbers below come from this chapter's own code. Where a change was tried, it was tried on a
scratch copy of the Zig project (the Rust twin was not changed for these answers), and the
text says what was run. Where something was not run, it says so.

## 1. Local bytes by hand, and cells per leaf

X = 1088, M = 544, an overflow page holds 4084 bytes, K = M + (P - M) mod 4084.

| P | (P - M) mod 4084 | K | in the leaf | overflow pages |
|---|---|---|---|---|
| 4628 | 4084 mod 4084 = 0 | 544 | 544 | 1, full |
| 4629 | 1 | 545 | 545 | 1, full |
| 5172 | 544 | 1088 = X | 1088 | 1, full |
| 5173 | 545 | 1089 > X | 544 | 2 (4084 + 545) |
| 65536 | 64992 mod 4084 = 3732 | 4276 > X | 544 | 16 (15 full + 3732) |

These rows are in the test "localLen: SQLite's rule, with this chapter's numbers" in both
languages. The same test checks, for every P up to 65536, that more than M bytes stay local
only when that makes every overflow page full.

Cells per leaf with a 2-byte key. A cell costs `2 (slot) + 4 (cell header) + 2 (key) +
4 (length) + local bytes + 4 (page id, if spilled)`, and a leaf offers 4076 bytes.

| value bytes | in the leaf | cell cost | cells per leaf |
|---|---|---|---|
| 1088 | 1088 | 1100 | 3 |
| 5173 | 544 | 560 | 7 |
| 9000 | 832 | 848 | 4 |

(Computed with the `cellCost` of `viz/model.js`, which the page's self-test ties to the
programs' output.) A leaf of 1088-byte values holds three cells; a leaf of values five times
as large holds seven. That is what M buys: the less of a spilled value stays in the leaf, the
more cells per leaf and the fewer leaves to read during a scan or a lookup of *other* keys.
The cost is that reading the value itself always needs the chain. SQLite states the purpose
as a minimum fanout (see the README's citation).

## 2. Pinning a reused page without reading it

Tried. A pool function next to `newPage`:

```zig
/// Pin page `id` WITHOUT reading it, zero-filled: for a caller that is
/// about to overwrite every byte (a page taken from the free list).
pub fn fetchZeroed(self: *BufferPool, id: PageId) Error!PagePtr {
    if (id >= self.pager.pageCount()) return error.PageOutOfRange;
    if (self.page_table.get(id)) |f| {
        const frame = &self.frames[f];
        frame.pin_count += 1;
        frame.referenced = true;
        self.stats.hits += 1;
        @memset(self.frameBytes(f), 0);
        return self.frameBytes(f);
    }
    self.stats.misses += 1;
    const f = try self.takeFrame();
    @memset(self.frameBytes(f), 0);
    self.install(f, id);
    return self.frameBytes(f);
}
```

and in `allocPage` the last three lines become `const page = try self.pool.fetchZeroed(id);`.
(The other reuse case, handing out the trunk itself, has to read the trunk anyway.)

Measured with the workload of part 3 (12 rounds, 1855 reuses): pager reads go from 9723 to
8675, so 1048 reads are saved. Writes, hits and misses are unchanged (6355, 20167, 9723): a
miss still takes a frame, it just does not fill it from the storage. The other 807 reuses
were cache hits or trunk pages. With the change, 80 of the 81 Zig tests pass, including the
file-hash test: the bytes written are the same. The one failure is the expected-output test,
because the demo prints the read counters (for example part 1: 74 reads instead of 78).

One thing to keep in mind when adding this to a real pool: a page pinned this way is dirty
from the start. If it were evicted without being written, the stale bytes on disk would come
back. Here every caller unpins it with `dirty = true`.

## 3. `min_local = max_local`

Tried (the `comptime` assertion that pins `min_local == 544` has to go too). Part 2 after
4000 operations, from the changed program and from `expected_output.txt`:

| | M = 544 | M = 1088 |
|---|---|---|
| leaf pages | 97 | 150 |
| overflow pages | 274 | 274 |
| pages in the file | 392 | 443 |
| leaf splits (both halves of the run) | 81 + 18 | 145 + 36 |

The number of overflow pages does not change at all, and that is not luck. Write
P - 544 = q * 4084 + r. If r <= 544, the old rule already keeps K = 544 + r bytes and uses q
pages; the new rule keeps 1088 and has q * 4084 - (544 - r) bytes left, still q pages. If
r > 544, the old rule keeps 544 and needs q + 1 pages; the new one keeps 1088 and has
q * 4084 + (r - 544) left, also q + 1 pages. So a larger M never shortens a chain. It only
moves up to 544 more bytes per large value into the leaves, which is why there are 55% more
leaf pages.

## 4. An interior page with one child and no key

They appear without any trick. In the test "delete everything" (2000 keys of 200 bytes, three
levels, deleted in a scrambled order), `validate` was instrumented to count interior pages
that are not the root and have no key: the first one shows up after the 1737th delete, and one
is still there after the 1975th, with 25 keys left and the height still 3.

How it happens: an interior page with two children loses one of them. `removeLeaf` deletes
one separator and one pointer; what is left is a page with zero cells and its link, the
rightmost child. `validate` accepts it because invariant T7 only forbids pages with *nothing*
in them: an interior page always has one child, and the search code handles zero keys
(`childIndex` returns 0, `childAt(0)` is the link). Only the root is collapsed, by
`collapseRoot`.

What it costs: one page read per lookup through that page, and one page of the file, for no
fan-out. Postgres leaves the same shape behind (the README quotes the rule: the rightmost
child goes only if it is the only child, and then the parent goes with it).

What removing them would take (not implemented, so this is a design, not a result). The
obvious splice does not work: replace the grandparent's pointer to the keyless page by a
pointer to its only child and free the page. The separators in the grandparent would stay
correct, but the child's subtree would be one level higher than its cousins, which breaks T4
(all leaves at the same depth). The splice is only legal at the root, where it lowers every
leaf together, and that is `collapseRoot`. Below the root, the single child has to be handed
to a neighbouring interior page, with the grandparent's separator pulled down between the two
groups of children. That is a merge: it moves entries between existing pages, which is exactly
what "free at empty" avoids. Chapter 15 is about that trade.

## 5. Delaying reuse until after the flush

Tried, in the simplest form: `freePage` appends the page id to a list in memory; `flush`
writes everything, then moves the pending ids to the free list, and, because that changed
trunk pages and the metapage, writes and syncs a second time. `validate` counts pending pages
as free.

Part 5 with this change:

```
N = 0: validate ok; old: intact; new: missing
N = 1: validate fails with error.UnreachablePage; old: intact; new: missing
N = 2: validate fails with error.UnreachablePage; old: intact; new: missing
N = 3: validate fails with error.OverflowChainBroken; old: missing; new: unreadable
N = 4: validate fails with error.UnreachablePage; old: missing; new: intact
N = 5: validate fails with error.FreeListBroken; old: missing; new: intact
N = 6: no crash, all writes done; validate ok; old: missing; new: intact
```

What changed: there is no line with a wrong value any more. `"new"` got a page of its own
(the file grew to 4 pages), so a crash can no longer leave the new cell pointing at the old
value's bytes. At N = 3 the new cell points at a page that is still zeroes; `get` reports
`Corrupt` ("unreadable") instead of returning 4084 bytes of `'o'`. Every damaged state now
fails `validate`.

What it costs: six writes instead of three for the same work, a file one page larger, and no
reuse at all between flushes. Part 3 never flushes, so with this change its file grows in
every round, to 1993 pages after round 12 instead of 138 (1993 is the number the unchanged
program prints as "without a free list"). Eighteen of the 81 tests fail, as they should: they
pin immediate reuse, or build their test files with it.

What still goes wrong: everything else. Five of the seven crash points still leave a file
that fails `validate` and needs repair (leaked pages at N = 1, 2 and 4, a torn chain at
N = 3, a free list that disagrees with the metapage at N = 5). The two flushes are not
atomic, each flush is still a sequence of page writes, and a split is still torn as in
chapter 12. Delaying reuse removes one failure, the silent one; it does not make the file
crash-safe. DuckDB and TigerBeetle pair the same delay with an atomic switch from one durable
state to the next (the header flip, the superblock), and that pairing is what makes it work
(chapter 23); chapter 22 gets there with a log instead.

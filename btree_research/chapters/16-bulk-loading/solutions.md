# Chapter 16: solutions

## 1. Keys 1 to 10, M = 4, fill 100%

Leaf capacity is 3, interior capacity is 4 children.

| Event | Level 0 | Level 1 | Written |
|---|---|---|---|
| key 4 arrives | `[1 2 3]` becomes A (pending) | | |
| key 7 arrives | `[4 5 6]` becomes B; A written | open `(1,A)` | A |
| key 10 arrives | `[7 8 9]` becomes C; B written | open `(1,A) (4,B)` | B |
| end, level 0 | open `[10]` has 1 key (the minimum), becomes D; C and D written | open `(1,A) (4,B) (7,C) (10,D)` | C, D |
| end, level 1 | only page on its level: root | | root |

Five pages, five writes. The root's separators are 4, 7 and 10 (the key 1 sits in the
ignored slot 0). Note that the fourth pair did not close the level-1 page: a page is
closed only when it is full *and another pair arrives*.

As a test (Zig, in `bulk.zig`):

```zig
test "exercise 1" {
    const gpa = testing.allocator;
    const entries = try ascending(gpa, 10, 1);
    defer gpa.free(entries);
    var tree = try bulkLoad(gpa, 4, entries, .{});
    defer tree.deinit();
    try testing.expectEqual(5, tree.stats.page_writes);
    const root = &tree.nodes.items[tree.root];
    try testing.expectEqualSlices(u64, &.{ 4, 7, 10 }, root.keys[1..root.len]);
}
```

## 2. Why 90% shows up as 86%

A leaf of order 16 holds 15 keys. `fillTarget` computes `floor(15 * 90 / 100) = 13`
keys, and 13 / 15 = 86.67%, printed rounded down. (The last leaf may hold fewer, which
can only lower the average.)

The target is an integer between the leaf minimum (7) and the capacity (15), so there
are only nine distinct leaf layouts. The smallest percentage that reaches each target
t is `ceil(100 * t / 15)`:

| Target (keys) | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|---|
| Smallest fill factor | 50 (and anything lower) | 54 | 60 | 67 | 74 | 80 | 87 | 94 | 100 |

So 87% to 93% all build the same leaves. Real engines measure fullness in bytes on
pages of several kilobytes, where the steps are far finer.

## 3. `minPagesFor`

Pack every level as full as possible: `ceil(n / (M - 1))` leaves, then divide by M
(children per interior page), rounding up, until one page is left.

```zig
pub fn minPagesFor(order: usize, n: usize) usize {
    if (n == 0) return 0;
    var level = (n + order - 2) / (order - 1); // ceil(n / (M - 1)) leaves
    var pages = level;
    while (level > 1) {
        level = (level + order - 1) / order; // ceil(level / M) parents
        pages += level;
    }
    return pages;
}
```

For n = 10,000 and M = 16: 667 leaves, then 42, 3 and 1 interior pages, 713 in total.
That is the "bulk load 100%" row of the report (667 leaves, 46 interior, 713 pages).

Why the loader always reaches this bound at 100%: every page except the last on its
level is full, and the tail repair never adds a page (it either moves pairs between the
last two pages or removes one).

## 4. A Postgres-style loader

Changes to the loader:

- Drop `pending`. When the open page is full and another pair arrives, write it
  immediately and send its low key up.
- A leaf must know its right neighbour's id before it is written. Postgres solves this
  by giving every open page its block number when it is *started*
  (`btps_blkno` in `nbtsort.c:660`), so the id of the next page can be allocated just
  before the old page is written. Do the same: allocate the node when the page is
  opened, not when it is closed.
- `finish` writes each level's open page as it is and sends it up; the first level
  that has never sent anything up holds the root.

The resulting trees can have a last page on each level that is below the minimum: a
leaf with one key where the minimum is seven, or an interior page with a single child
and no separator at all. `validate` must exempt the rightmost node of every level from
the minimum (keep "at least one pair"). One way: pass an `is_rightmost` flag down the
recursion, true for the root and for the last child of a rightmost node.

Everything that reads still works. `childIndex` returns 0 for a one-child node; `get`,
`range` and `put` never look at the minimum. What would break is code that *relies* on
the minimum, such as a delete that assumes a sibling can always lend a key, or a
height bound derived from the minimum fanout. That is the trade Postgres makes
throughout (chapter 15): simpler writers, weaker occupancy guarantee.

## 5. Rightmost split

In `put`, before the 50/50 split of a leaf, test: the leaf has no right neighbour
(`next == nil`) and the new key landed in the last position. If so, keep all the old
keys in the left page and move only the new key to the right page (`keep = len - 1`).

The new right page starts with one key. For every M >= 5 that is below the leaf minimum
of ceil(M/2) - 1 (7 for M = 16), so with this change alone the tree breaks the promise
the README makes, and `validate` returns `error.Underfull` until the page has filled up.
The existing model test that bulk-loads and then keeps inserting catches it. Something
has to give, and there are two choices:

- Exempt the last leaf (`next == nil`) from the minimum in `validate`, keeping "at least
  one key". This is the relaxation of solution 4 again, limited to one page. Without
  `delete` nothing else in this chapter's tree depends on the minimum.
- Keep the promise and leave `leafMin` keys in the new page instead of one. Then the
  left page is not full and most of the space gain is lost, so this is not what the
  policy is for.

With the first choice, the two tests that pin the 50/50 behaviour ("ascending inserts
leave leaves half full" and the report test) fail, as they should, and all others pass.
Measured in a scratch copy for experiment 2 (n = 10,000, M = 16, ascending): 667 leaves,
83 interior pages, 750 pages in total, 11,492 page writes, 37,476 page reads, 746
splits. The bulk load at 100% has 667 leaves, 46 interior pages and 713 writes.

Why, for ascending inserts of n keys with order M:

- Leaves: every leaf is filled to M - 1 keys before the next one is started, so there
  are `ceil(n / (M - 1))` leaves, the same as the 100% bulk load (667 for the report's
  parameters) instead of 1250.
- Interior pages still split 50/50 unless you apply the same rule there, so there are
  more of them than the bulk loader's 46 (83 measured). Applying the rule to the
  rightmost interior page as well would close that gap, and needs the same exemption
  for the last page of every level.
- Page reads do not improve: every insert still descends from the root, one read per
  level.
- Page writes stay above n: every insert dirties at least its leaf, where the loader
  writes each leaf once. A buffer pool hides much of that, because the rightmost leaf
  is dirtied about M - 1 times in a row.

So the policy recovers the *space* of a bulk load for ascending input, and none of the
per-key work. It is still worth having: it helps inserts that arrive in order long
after the index was built, which a bulk loader cannot. Chapter 14 covers how Postgres
picks the split point on the rightmost page.

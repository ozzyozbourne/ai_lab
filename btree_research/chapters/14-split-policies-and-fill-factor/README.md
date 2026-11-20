# Chapter 14: Split policies and fill factor

Every chapter so far split a full node "in the middle" without asking whether the
middle is a good place. This chapter asks. The answer decides how many pages an index
occupies and how large the keys in its upper levels are, and it costs nothing at run
time except a little thought at the moment of the split.

## What you will learn

- Why "cut in the middle" wastes half of every page under the most common insert
  pattern of all, and how one extra rule fixes it.
- What a fill factor is, and why applying it on every split is worse than not having
  one.
- How runs of equal keys change the question from "how many bytes on each side" to
  "between which two cells".
- How PostgreSQL combines these rules in `nbtsplitloc.c`, and how to write the same
  decision procedure in about 150 lines.

Prerequisites: node splits (chapter 04), cells with byte sizes in a slotted
page (chapters 10 and 12), and the tie-breaker that makes equal keys distinct
(chapter 07). No pager is needed here: the chapter uses a small in-memory page model
so that nothing distracts from the one decision it is about.

## The idea in plain words

A page is full and one more cell must go in. Picture the page with the new cell already
in its sorted place: an **imaginary page** that is slightly too long. Every gap between
two neighbouring cells is a place where it could be cut; the cells before the gap stay,
the cells after it move to a new right page, and the first cell after the gap gives the
parent its new separator. Choosing the gap is the whole split policy.

**50:50.** The textbook picks the gap that puts the same number of bytes on both sides.
That is the right answer when the next insert is equally likely to land on either half,
which is what random keys do. Both halves have room, and both will use it.

**Appends break it.** With ascending keys (ids from a sequence, timestamps) the next
insert always lands on the right half. The left half is exactly 50% full and will stay
that way for ever, because no key that small will arrive again. Every page of the index
except the last ends up half empty.

**Fill factor, applied to the rightmost page.** If the page being split is the rightmost
one of its level, cut it so that the left page stays, say, 90% full and the right page
starts nearly empty. Appends then leave a trail of 90% full pages. The remaining 10% is
deliberate slack: it absorbs later inserts into old pages without an immediate split.

**Why only the rightmost page.** A lopsided cut is a bet that inserts will keep arriving
on the small side. On the rightmost page under appends that bet is safe. On an ordinary
page under random inserts it usually loses, since most cells sit on the full side: the
90% page overflows again almost at once, and the 10% page rarely fills. The experiment
below shows that this "fill factor everywhere" policy needs twice as many pages as
plain 50:50.

**Equal keys.** If the gap falls between two cells with different keys, the separator
only needs the key of the right-hand cell. If it falls inside a run of equal keys, the
separator must also carry the tie-breaker (the row id, "tid") to say where the run was
cut, so it is larger, and that larger separator lives in the upper levels where space
buys fan-out. Worse, the run now spans two pages. So it pays to move the cut a little
away from the byte-perfect middle if that lands it between two different keys, and, when
a long run sits right on the middle, to move it a lot: all the way to the edge of the
run.

**One key filling the whole page.** Then there is no edge to move to. New cells with
this key carry higher row ids, so they arrive at the right end of the run: this is an
append in disguise, and the page should be cut like a rightmost page, even more
lopsided.

## A worked example by hand

Page capacity 100 bytes. The page holds six cells, 94 bytes, written `(key,tid):bytes`.
A seventh cell `(20,5)` of 12 bytes arrives; 106 bytes do not fit.

```
imaginary page:  (10,1):18 (20,1):14 (20,2):14 (20,3):14 (20,4):14 *(20,5):12 (30,1):20
cut before index s:        1         2         3         4          5         6
```

For every `s`, add up the bytes on each side. A candidate is legal if both sides fit in
100 bytes; here all six are. Its **delta** measures the distance from the space target.
For 50:50 the target is equal free space, `delta = |left_free - right_free|`. For a fill
factor of 90 the left page should keep 10% of the free space and the right page 90%,
`delta = |90 * left_free - 10 * right_free|`. This is the first part of the program's
output:

```
candidate split points (cut before index s)
  s  left  right  delta 50:50  delta 90:10  separator
  1    18     88           70         7260  (20)      8 bytes
  2    32     74           42         5860  (20,2)   16 bytes
  3    46     60           14         4460  (20,3)   16 bytes
  4    60     46           14         3060  (20,4)   16 bytes
  5    74     32           42         1660  (20,5)   16 bytes
  6    86     20           66          460  (30)      8 bytes
```

The program gives the four ideas of the previous section names: **half** is 50:50 on
every split, **fill-90** a fill factor of 90 on every split, **rightmost-90** a fill
factor of 90 on the rightmost page only, and **adaptive-90** is rightmost-90 plus the
two rules for equal keys.

- **half** takes the smallest 50:50 delta: `s=3` (the tie with `s=4` goes to the left
  one). It cuts inside the run of 20s, so the separator is `(20,3)`, 16 bytes.
- **fill-90** takes the smallest 90:10 delta: `s=6`, left page 86 bytes.
- **rightmost-90** does what fill-90 does if this is the rightmost page, and what half
  does otherwise.
- **adaptive-90** on a page that is not rightmost starts from `s=3` like half. It then
  accepts any candidate whose two sides differ from that one by at most 5% of the old
  page content (94 / 20 = 4 bytes). No other candidate is that close, and `s=3` needs a
  tid. So it widens the search to the whole page and takes the best-balanced candidate
  with a bare-key separator: `s=6` (delta 66 beats `s=1` with 70). The split is
  lopsided, 86 to 20, but the five 20s stay together and the separator is `(30)`.

The program prints the choice twice. In the first block the page is not the rightmost
one: the page to its right starts with key 40, which is this page's **upper bound**.
In the second block it is the rightmost page and has no upper bound.

```
choice when the page is NOT the rightmost page (upper bound 40)
  half          s=3  left 46  right 60  separator 16 bytes  default
  fill-90       s=6  left 86  right 20  separator  8 bytes  default
  rightmost-90  s=3  left 46  right 60  separator 16 bytes  default
  adaptive-90   s=6  left 86  right 20  separator  8 bytes  many_duplicates

choice when the page IS the rightmost page
  half          s=3  left 46  right 60  separator 16 bytes  default
  fill-90       s=6  left 86  right 20  separator  8 bytes  default
  rightmost-90  s=6  left 86  right 20  separator  8 bytes  default
  adaptive-90   s=6  left 86  right 20  separator  8 bytes  default
```

## Code walk-through

### The page model (`pages.zig`, `pages.rs`)

A `Cell` is `(key, tid, size)`; it has no payload, only the number of bytes it would
occupy. A `Leaf` is a sorted list of cells plus `used`, and `used <= capacity` (4096 in
the experiment). The levels above the leaves are flattened into one sorted **directory**:
entry `i` holds the lower bound of page `i` (a `Sep`) and the page number. A `Sep` with
`tid == null` is a truncated separator of 8 bytes; with a tid it is 16 bytes. That is
all the model needs to count pages, fill and separator bytes. (Shortening separators
is a topic of its own, suffix truncation, in chapter 17; fill factor returns in
chapter 16 on bulk loading.)

`put(key, tid, size)` finds the page by binary search in the directory, then the
position in the page. If the cell fits it is inserted. Otherwise `splitAndInsert`:

1. builds the imaginary page in scratch memory,
2. calls `chooseSplit`,
3. reserves all long-lived memory it will need,
4. and only then moves cells: the left page is truncated in place, the right part
   becomes a new page, and the directory gets one new entry.

Step 3 before step 4 is what makes a failed `put` leave the tree untouched. `delete`
removes a cell and never merges pages; that is chapter 15. `validate` checks five
invariants listed at the top of the file.

### The decision (`split.zig`, `split.rs`)

The policy is data: a tagged union with a fill factor as payload.

```zig
pub const Policy = union(enum) { half, fill: u8, rightmost: u8, adaptive: u8 };
```

The payload is a percentage, 0 to 100; `Tree.init` asserts that, so a wrong value
fails where the tree is created and not at its first split.

`chooseSplit` does by program what the hand example did, in five numbered steps (the
same list, with the name of the PostgreSQL function behind each step, is at the top
of `split.zig`):

```zig
const cands = try candidates(scratch, items, page.capacity);   // 1. legal gaps
const fill: ?u8 = switch (policy) {                             //    which target?
    .half => null,
    .fill => |ff| ff,
    .rightmost, .adaptive => |ff| if (page.isRightmost()) ff else null,
};
deltaSort(cands, page.capacity, fill);                          // 2. best balance first
```

For `half`, `fill` and `rightmost` the answer is `cands[0]`: these three policies differ
only in the four lines that choose the target. `adaptive` goes on:

```zig
interval = defaultInterval(cands, old_bytes / 20);              // 3. close enough
if (firstDistinct(items, cands[0..interval])) |i| {
    pick = i;                                                   // 4. cheapest separator
} else if (items[leftmost.first_right - 1].key != items[rightmost.first_right].key) {
    strategy = .many_duplicates;                                // 5a. edge of the run
    interval = @intCast(cands.len);
    pick = firstDistinct(items, cands).?;
} else if (page.isRightmost() or page.upper_key.? != items[new_index].key) {
    strategy = .single_value;                                   // 5b. append in disguise
    deltaSort(cands, page.capacity, single_value_fill);         //     96% left
}
```

The last condition deserves a second look. The page holds one key only. If its upper
bound in the directory is a *different* key, no page to the right holds this key, so
this page is the end of the run and new cells will keep arriving here: pack it. If the
upper bound *is* this key, the insert landed in the middle of a run that continues to
the right, and 50:50 stays the right answer.

Deltas are integers scaled by 100 (`ff * left_free - (100 - ff) * right_free`), and the
sort breaks ties by position, so the order is total and both languages agree exactly.

### Rust, and the differences

The Rust port has the same files, names, tests and output.

- `Policy` is an `enum` with payloads and `choose_split` a `match`; same shape.
- `Sep` derives `Ord`. Field order `key`, then `tid: Option<u64>`, and `None < Some(_)`,
  give exactly "truncated separators sort before every cell with that key" for free.
  Zig spells out `atOrBelow` and `lessThan` by hand.
- Binary searches use `partition_point`; Zig writes the loop.
- Scratch memory is two `Vec`s kept in the tree and `clear()`ed per split (see the next
  section but one).
- `Vec` cannot report allocation failure, so the failure path is a `page_budget`:
  `put` returns `Err(PutError::OutOfPages)` at the point where Zig would reserve
  memory, and the same "failed put changes nothing" test runs against it.
- The crate is a small library plus a `main.rs`, so that methods the report does not
  call (`get`, `delete`, `range`) are not dead code.

### The experiment (`report.zig`, `report.rs`)

Four workloads insert 20 000 cells of 40 to 120 bytes. The row id of the i-th insert is
`i` in all of them. `ascending`: key = i. `random`: the keys 0..n shuffled.
`dup-groups`: n/8 distinct keys chosen at random (about 8 cells per key). `dup-heavy`:
22 distinct keys (about 900 cells, some 18 pages, per key). This is the second part of
`expected_output.txt`, with the repeated header lines and the histograms left out:

```
workload ascending
  policy         pages  avg fill  min fill  splits  default/manydup/single  tid seps  sep bytes
  half             774     50.5%     48.6%     773      773/      0/     0         0       6184
  fill-90          435     89.9%     33.8%     434      434/      0/     0         0       3472
  rightmost-90     435     89.9%     33.8%     434      434/      0/     0         0       3472
  adaptive-90      435     89.9%     33.8%     434      434/      0/     0         0       3472

workload random
  half             554     70.3%     48.9%     553      553/      0/     0         0       4424
  fill-90         1161     33.5%      8.9%    1160     1160/      0/     0         0       9280
  rightmost-90     565     69.0%     22.5%     564      564/      0/     0         0       4512
  adaptive-90      565     69.0%     22.5%     564      564/      0/     0         0       4512

workload dup-groups
  half             572     68.2%     48.7%     571      571/      0/     0       398       7752
  fill-90         1114     35.0%      8.8%    1113     1113/      0/     0       730      14744
  rightmost-90     570     68.5%     49.0%     569      569/      0/     0       378       7576
  adaptive-90      572     68.2%     37.9%     571      487/     84/     0         0       4568

workload dup-heavy
  half             761     51.3%     48.8%     760      760/      0/     0       759      12152
  fill-90          459     85.0%      9.4%     458      458/      0/     0       453       7288
  rightmost-90     748     52.2%     48.8%     747      747/      0/     0       747      11952
  adaptive-90      417     93.6%      8.8%     416       10/     11/   395       395       6488
```

Read it row by row:

- **ascending**: 50:50 leaves 774 pages at 50.5%; any policy that packs the rightmost
  page needs 435 at 89.9%.
- **random**: 50:50 settles at 70.3%. (Textbook: the average fill of a B-tree under
  random inserts tends to ln 2, about 69%.) Packing every split drops to 33.5% and 1161
  pages. The rightmost rule costs almost nothing here.
- **dup-groups**: the page count is the same for half and adaptive, but adaptive has
  **no** separator that carries a tid, against 398, and 41% fewer separator bytes. Of
  its 571 splits, 84 had to go to the edge of a run.
- **dup-heavy**: each key is a private append stream. 50:50 leaves 51.3%; adaptive
  recognises 395 single-value splits and reaches 93.6% with 417 pages. Its 395
  tid-carrying separators are unavoidable: a run of 18 pages must be cut somewhere.
  Naive fill-90 also does well here, for the same reason, which is exactly why it looks
  attractive until you try it on random keys.

The output also contains a fill histogram per workload (ten buckets) and a third part,
a 300-insert scenario whose per-page byte counts the visualization reproduces.

## In real databases

All of this is PostgreSQL's `_bt_findsplitloc`; file references are to
`postgres/src/backend/access/nbtree/nbtsplitloc.c` unless stated, and the notes are in
`research/postgres.md`, section 5.

- **Candidates.** One per gap of the imaginary page; a candidate is recorded only if
  `leftfree >= 0 && rightfree >= 0` (`:546`). Postgres charges the first right tuple to
  *both* sides, because a copy of it becomes the left page's high key, plus one aligned
  tid on leaf pages as the worst case (`:525-527`). The model has no high key inside
  the page (separators live only in the directory), so it does not make that charge.
- **Space target.** Rightmost leaf: the leaf fill factor. Internal rightmost page: a
  fixed 70. Other pages: 50:50 (`:281-336`). The delta formula is at `:575-582`, in
  floating point. The defaults are in `postgres/src/include/access/nbtree.h:200-203`:
  leaf 90 (minimum 10), internal 70, single value 96. The header comment of
  `_bt_findsplitloc` gives the reason in one sentence: with ever-increasing keys the
  tree ends up fillfactor% full "instead of the 50% full result".
- **Interval.** `_bt_defaultinterval` (`:877`) accepts candidates whose free space is
  within `LEAF_SPLIT_DISTANCE` = 5% of the old items' total size of the space-optimal
  one (`:850`, `:894`); 7.5% on internal pages.
- **Penalty.** On leaves, the number of key columns the new high key must keep; one
  more than the number of columns means a heap TID must be appended
  (`_bt_split_penalty`, `:1132`). With a single column that is the model's 1 or 2. On
  internal pages the penalty is the byte size of the tuple that moves up.
- **Strategies.** `_bt_strategy` (`:935`) picks `SPLIT_MANY_DUPLICATES` (interval
  widened to all candidates, `:398-405`) or `SPLIT_SINGLE_VALUE` (fill 96, interval 1,
  `:407-416`). The test "is this the last page of the run?" compares the page's high
  key with the new item (`:1013-1042`). The prose version is in
  `postgres/src/backend/access/nbtree/README:890-899`: the logic "almost always manages
  to pick a split point between two user-key-distinct tuples, accepting a completely
  lopsided split if it must".

Two things in the source are **not** in the model, and the exercises return to both:

- A guard in `_bt_bestsplitloc` (`:833-843`) falls back to the 50:50 candidate when a
  many-duplicates split would put the cut just left of the new item on a page that is
  not rightmost. It protects against descending inserts next to a large run.
- `_bt_afternewitemoff` (`:631`) recognises ascending inserts into the middle of a
  multi-column index and cuts right after the new item. It returns false at once for
  single-column indexes.

This chapter looks only at PostgreSQL. How the other engines in this guide
choose split points is the subject of chapter 15 (Turso's `balance_non_root`
redistributes over siblings instead of cutting one page in two).

## Allocator notes

A split needs two temporary arrays: the imaginary page (one cell more than fits in a
page) and the candidate list. Neither outlives the split.

Zig: the tree owns a `std.heap.ArenaAllocator` named `scratch`, backed by the same
general purpose allocator as the pages. `splitAndInsert` begins with

```zig
defer _ = self.scratch.reset(.retain_capacity);
```

so both arrays are released together on every path out, including errors, with no
individual `free` to forget. `retain_capacity` keeps the arena's buffer, so after the
first few splits a split allocates nothing from the general purpose allocator except
the new right page. Lifetime: one call. Owner: the tree, which deinitialises the arena
in `deinit`.

What would go wrong with other choices:

- The general purpose allocator directly: two `alloc`/`free` pairs per split and two
  `errdefer`s to get right; correct but noisy, and slower.
- The arena for the *pages*: every time a page's cell list (or the directory) grows,
  the outgrown buffer would stay allocated until the tree dies. Pages are long-lived
  and individually resized; they belong in the general purpose allocator.
- A `FixedBufferAllocator` over a stack buffer: possible, but the bound is a number of
  structs, not the bytes of a page. The scratch memory holds one `Cell` and one
  `Candidate` (24 bytes each) per cell of the imaginary page, and a page can hold as
  many cells as it has bytes, because a cell may be 1 byte long: about 197 kB for a
  4096-byte page. The arena does not need the bound.
- Forgetting the reset: everything still works and nothing leaks at exit, because
  `deinit` frees the arena, but memory grows with every split. No test fails; only a
  memory counter shows it.

`chooseSplit` receives the scratch allocator as a parameter and never stores it. Tests
use `std.testing.allocator`; `checkAllAllocationFailures` builds a tree under every
possible allocation failure, and a second test fails each allocation of one splitting
`put` in turn and checks that the tree is valid, unchanged and still accepts the cell.

Rust: `scratch_items: Vec<Cell>` and `scratch_cands: Vec<Candidate>` live in the tree
and are `clear()`ed, not dropped, which is the same idea: length to zero, buffer kept.
`std::mem::take` moves the vector out of `self` for the duration of the split so that
the borrow checker allows reading it while the pages are modified.

## Pitfalls

- **Balancing cell counts instead of bytes.** With variable-size cells the middle cell
  is not the middle byte, and one side may not even fit.
- **Forgetting the new cell.** The split must be chosen on the imaginary page. Cut the
  old page 50:50 and then add the new cell, and the side that receives it can overflow.
- **A fill factor on every split.** See the `random` rows above.
- **Truncating a separator inside a run.** A separator without a tid claims that no
  cell with that key lies to its left. If one does, lookups for it go to the wrong page.
  `validate` catches this (invariant I2).
- **Mutating before reserving.** If the right page is appended and then the directory
  insert fails, the tree has a page nobody points to.
- **Reading the 96% rule as "always pack duplicates".** It applies only when the page
  is the last one holding that key.
- **Expecting fill factor to bound fill.** It is a target for some splits only.

## Exercises

1. (easy) Capacity 100, rightmost page, cells of 30, 10, 10, 10, 10 and 20 bytes with
   six different keys, and a new 15-byte cell with the largest key. List the
   candidates with both deltas and say where `half` and `rightmost-90` cut.
2. (easy) Predict the average fill of `rightmost-90` when keys arrive in *descending*
   order, then measure it. What would a policy need to do better?
3. (medium) Bulk-load 20 000 ascending keys with `rightmost` at fill factors 100, 90,
   70 and 50, then insert 2 000 cells with random existing keys. Count the splits of
   the second phase. What does the slack buy, and what does it cost?
4. (medium) Add the guard from `nbtsplitloc.c:833-843` to `adaptive`. Construct a
   workload on which the unguarded policy repeatedly produces nearly empty pages.
5. (hard) `dup-groups` under `adaptive` still averages 68%: each key is an ascending
   stream, but its cells land in the middle of a page. Implement a "split after the
   new item" rule in the spirit of `_bt_afternewitemoff` and measure whether it helps.

Solutions are in [solutions.md](solutions.md).

## Links

- Previous: [chapter 13, overflow and free space](../13-overflow-and-free-space/README.md)
- Next: [chapter 15, redistribution and merge policies](../15-redistribution-and-merge-policies/README.md)
- Visualization: [viz/index.html](viz/index.html): the same workload under two
  policies side by side, with a fill histogram, and the hand example step by step.
- Full program output: [expected_output.txt](expected_output.txt)

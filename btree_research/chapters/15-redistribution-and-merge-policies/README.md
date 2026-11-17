# 15. Redistribution and merge policies

## What you will learn

- How to repair an overfull or underfull page by looking at its neighbours first:
  flatten up to three siblings into one array and cut it into pages again.
- Why split, "borrow from a sibling" and merge are one routine with a different number
  of output pages, and how the two cutting steps (pack left, even out) work on bytes.
- The append fast path, and why it beats any amount of clever balancing for ascending
  keys.
- Four answers to "what do we do when a page gets emptier": never merge, free at
  empty, rebalance below one third, rebalance below one half. What each costs in pages
  and in churn, and why Postgres chooses not to move items at all.

Prerequisites: chapter 05 (borrow and merge with key counts), chapter 10 (cells have
byte sizes), chapter 14 (where to cut one full page). The code uses an in-memory page
model, not a pager: leaves hold cells that are just `{key, size}`, a page is full at
`capacity` bytes (4096, or 100 in the small examples), and one parent page holds
divider cells.

## The idea in plain words

Chapter 14 asked where to cut **one** full page. The cut always produced a new page, so
after a split both halves are about half empty. That is the price of looking at one
page only.

The alternative is to look sideways before allocating. If the page on the left or the
right has free space, some cells can move there, the parent's divider is adjusted, and
no new page is needed. Only when the whole neighbourhood is full does a new page appear,
and then it is shared between more pages: two full pages become three that are two
thirds full, or three become four that are three quarters full. This is the textbook
**B\*-tree** idea (Knuth describes it with two siblings: redistribute first, split two
into three, so every page stays at least 2/3 full).

Once you look at siblings for overflow, you notice that underflow is the same problem.
A page that became too empty is also fixed by pooling its cells with the neighbours and
cutting the pool again. If the pool now fits in fewer pages, one page is freed, and that
is a merge.

So the chapter is one routine:

1. **Pick** up to three adjacent siblings around the page that needs attention.
2. **Flatten** their cells into one array, in key order.
3. **Pack left**: fill pages from the left, each as full as possible. This gives the
   smallest possible number of pages.
4. **Even out**: packing left leaves the last page with the leftovers, maybe one cell.
   Walk the boundaries from right to left and move cells rightwards for as long as the
   right page does not become bigger than the left one.
5. **Write back**: reuse the old pages, allocate or free the difference, and replace the
   dividers in the parent.

| pages in | pages out | textbook name |
|---|---|---|
| 1 | 2 | split |
| 2 or 3 | one more | split, shared between siblings (B\*) |
| 2 or 3 | the same | redistribution, rotation, "borrow" |
| 2 or 3 | fewer | merge |

Two things are separate from this routine and matter just as much.

**The append fast path.** If the cell that does not fit is the last cell of the
right-most leaf, the workload is probably appending. Balancing would spread the full
pages out again and leave room where nobody will ever insert. So do the cheapest thing:
give the new cell a fresh page and leave the old one 100% full.

**When to bother on delete.** Repairing overflow is mandatory, because a page cannot
hold more than its capacity. Repairing underflow is optional. A half-empty page is a
perfectly valid page. Minimum fill is therefore a *policy*, not an invariant, and
engines disagree about it. The four policies in this chapter:

| policy | on delete | who does this |
|---|---|---|
| never | nothing, empty pages stay | nobody as a final answer; it is the baseline |
| at empty | unlink a page when its last cell is gone | Postgres (during VACUUM, see below) |
| below 1/3 | run the balance routine when more than 2/3 of the page is free | SQLite, Turso |
| below 1/2 | run it as soon as the page is less than half used | textbooks |

## A worked example by hand

Capacity is 100 bytes. A cell is written `key:size`. The parent is written as divider
cells `(child, largest key that may be in that child)` plus a right-most pointer. This
is section 2 of the program output; follow it with pencil and paper.

Start: after `put 10 20 30 40 50 60 70 80` there are two full leaves.

```
parent: (p0, 40) right=p1
  p0 100/100: 10:25 20:25 30:25 40:25
  p1 100/100: 50:25 60:20 70:30 80:25
```

(Key 50 got there by the append fast path: p0 was full, 50 was larger than everything,
so it simply started p1. Nothing in p0 moved.)

**put 35:20.** It belongs in p0, which is now 120/100. It is not an append. The parent
has only two children, so both are taken.

```
flatten    25 25 25 20 25 | 25 20 30 25        (p0 with 35 in it | p1)
pack left  25 25 25 20 =95 | 25 25 20 30 =100 | 25 =25
even out   25 25 25 20 =95 | 25 25 20 =70 | 30 25 =55
```

Packing left needs three pages, and the third holds one lonely cell. Evening out starts
at the last boundary: moving `30` right gives 70 | 55, fine; moving `20` as well would
give 50 | 75, the right page would be bigger, stop. Then the first boundary: moving `20`
would give 75 | 90, stop at once. Two pages in, three out: a split, but the new page is
filled from both old pages.

```
parent: (p0, 35) (p1, 60) right=p2
  p0  95/100: 10:25 20:25 30:25 35:20
  p1  70/100: 40:25 50:25 60:20
  p2  55/100: 70:30 80:25
```

The new dividers are the largest key of each page except the last. Key 40 moved from p0
to p1, across a boundary that existed before. Remember that; it is the crux of the
Postgres section.

**put 15:20.** p0 is 115/100 again. Now there are three siblings.

```
flatten    25 20 25 25 20 | 25 25 20 | 30 25
pack left  25 20 25 25 =95 | 20 25 25 20 =90 | 30 25 =55
even out   (nothing moves: 90 | 55 -> 70 | 75 would overshoot)
```

Three in, three out. No page was allocated: cell 35 moved to p1 and the first divider
changed from 35 to 30. A plain split would have created a fourth page here.

**delete 70.** p2 drops to 25/100. More than two thirds free, so the same routine runs:

```
flatten    25 20 25 25 | 20 25 25 20 | 25
pack left  95 | 90 | 25
even out   95 | 20 25 25 =70 | 20 25 =45
```

Cell 60 moved right into p2. This is what chapter 05 called "borrow from the left
sibling".

**delete 80.** p2 is 20/100.

```
flatten    25 20 25 25 | 20 25 25 | 20
pack left  95 | 20 25 25 20 =90
```

Everything fits in two pages: three in, two out, a merge. p2 goes to the free list and
its divider disappears.

```
parent: (p0, 30) right=p1
  p0  95/100: 10:25 15:20 20:25 30:25
  p1  90/100: 35:20 40:25 50:25 60:20
```

The result of "even out" is not perfectly even (90 | 85 | 45 in the first case of
section 1 of the output). Cells are indivisible and the rule stops at the first move
that would overshoot.

## Code walk-through

### Zig (`zig/src/pages.zig`)

`packLeft(scratch, sizes, capacity)` and `evenOut(sizes, ends)` are pure functions on
an array of cell sizes. They return and adjust `ends`, the prefix counts: `ends[p]` is
the index one past the last cell of output page `p`.

`Tree` holds a page table (`pages`, indexed by page id), a free list of ids, and the
parent: `dividers` plus `rightmost`. `put` inserts the cell into its leaf even if that
makes the page overfull; `used > capacity` is the signal to repair. `fixOverflow` then
chooses between `quickAppend` and `balance`.

`balance(ci, window)` is the routine from the list above. Its structure follows one
rule: **everything that can fail happens before the first mutation.** Flatten into
scratch memory, compute `ends`, allocate the extra pages, reserve room in each output
page and in the parent; only then overwrite pages and splice the dividers with
`...AssumeCapacity` calls. If a reservation fails, `put` removes the cell it had
inserted and the tree is exactly as before.

`delete` shows the asymmetry. It returns `bool`, not an error union. If the optional
rebalance runs out of memory, the tree is left underfull, which is still valid. A page
that became completely empty is unlinked by `removeEmpty`, which needs no memory.

`removeEmpty` removes divider `i` from the parent. That hands the key range of child
`i` to its **right** neighbour without changing any other page.

`validate` checks that dividers increase, that every cell lies between its page's
bounds, that sizes add up and fit, and that the free list matches the dead pages. It
does not check any minimum fill.

### Rust (`rust/src/pages.rs`)

Same names in snake case, same tests, same output. The differences:

- **Scratch memory.** Zig resets an arena; Rust keeps a `Scratch` struct of four `Vec`s
  inside the tree and calls `clear()`, which keeps the capacity. `balance` moves the
  struct out with `std::mem::take` and puts it back afterwards, because the borrow
  checker will not let a method hold `&mut self.scratch` and `&mut self` together.
- **Running out of memory.** A `Vec` aborts the process when allocation fails, so the
  Zig failure tests are mirrored by a page budget: `Config::max_pages`, and
  `PutError::OutOfPages`. The Rust test runs the same puts under every budget from 1 to
  39 and checks that a refused put changes nothing.
- **Underflow repair cannot fail in Rust.** A rebalance after a delete never needs more
  pages than it started with, so the budget never bites. In Zig it can still fail,
  because scratch memory is an allocation too. The two "failed" tests therefore differ
  in their second half.
- `validate` returns `Result<(), &'static str>` with a reason instead of Zig's single
  `error.Invalid`; `partition_point` replaces `std.sort.lowerBound`; `Vec::splice`
  replaces `replaceRangeAssumeCapacity`.
- The Zig package is named `ch15_redistribution_and_merge` because `build.zig.zon`
  names are limited to 32 characters. The executable and the Cargo package carry the
  full name.

### What the programs print

Both programs print exactly this (`expected_output.txt`; a test in each language
compares):

```
== 1. Redistribution by hand (capacity 100) ==
redistribute: the middle page is overfull, its neighbours have room
  before     20 20 20 =60 | 30 20 20 20 25 =115 | 25 10 10 =45
  pack left  20 20 20 30 =90 | 20 20 20 25 =85 | 25 10 10 =45
  even out   20 20 20 30 =90 | 20 20 20 25 =85 | 25 10 10 =45
  pages: 3 in, 3 out
split: three full pages and one cell too many
  before     25 25 25 25 =100 | 20 20 20 20 20 15 =115 | 25 25 25 25 =100
  pack left  25 25 25 25 =100 | 20 20 20 20 20 =100 | 15 25 25 25 =90 | 25 =25
  even out   25 25 25 25 =100 | 20 20 20 20 20 =100 | 15 25 25 =65 | 25 25 =50
  pages: 3 in, 4 out
merge: three pages that are mostly free
  before     20 15 =35 | 10 25 =35 | 20 30 10 =60
  pack left  20 15 10 25 20 =90 | 30 10 =40
  even out   20 15 10 25 =70 | 20 30 10 =60
  pages: 3 in, 2 out

== 2. Fixed scenario (capacity 100, 3 siblings, quick append, merge below 1/3) ==
put 10 20 30 40 (25 bytes each): one full leaf
parent: right=p0
  p0 100/100: 10:25 20:25 30:25 40:25
put 50: append fast path, nothing moves
parent: (p0, 40) right=p1
  p0 100/100: 10:25 20:25 30:25 40:25
  p1  25/100: 50:25
put 60 70 80: the right-most leaf fills up
parent: (p0, 40) right=p1
  p0 100/100: 10:25 20:25 30:25 40:25
  p1 100/100: 50:25 60:20 70:30 80:25
put 35: p0 overflows, 2 siblings in, 3 out (split)
parent: (p0, 35) (p1, 60) right=p2
  p0  95/100: 10:25 20:25 30:25 35:20
  p1  70/100: 40:25 50:25 60:20
  p2  55/100: 70:30 80:25
put 15: p0 overflows again, 3 in, 3 out (redistribution)
parent: (p0, 30) (p1, 60) right=p2
  p0  95/100: 10:25 15:20 20:25 30:25
  p1  90/100: 35:20 40:25 50:25 60:20
  p2  55/100: 70:30 80:25
delete 70: p2 is more than 2/3 free, 3 in, 3 out (redistribution)
parent: (p0, 30) (p1, 50) right=p2
  p0  95/100: 10:25 15:20 20:25 30:25
  p1  70/100: 35:20 40:25 50:25
  p2  45/100: 60:20 80:25
delete 80: 3 in, 2 out (merge), p2 goes to the free list
parent: (p0, 30) right=p1
  p0  95/100: 10:25 15:20 20:25 30:25
  p1  90/100: 35:20 40:25 50:25 60:20
get 35 -> 20, get 70 -> null, range [20, 50) -> 20 30 35 40
stats: balances=4 quick_appends=1 allocated=2 freed=1 leaf_writes=9 parent_writes=5 moved=6 moved_to_old=4

== 3. Overflow policies: 20000 inserts, cells of 40..200 bytes, capacity 4096 ==
-- ascending keys --
policy                 pages   fill balances  writes   freed    moved   to old
split alone             1114   52.5%     1113    2226       0    18653        0
split alone + quick      596   98.2%        0     595       0        0        0
balance 2                760   77.0%     2545    5848       0    24700    11938
balance 3                655   89.4%     2559    7912       0    28880    17921
balance 3 + quick        596   98.2%        0     595       0        0        0
-- random order --
policy                 pages   fill balances  writes   freed    moved   to old
split alone              855   68.5%      854    1708       0    14283        0
split alone + quick      856   68.4%      854    1709       0    14283        0
balance 2                707   82.8%     2777    6259       0    25731    13885
balance 3                676   86.6%     4111   11594       0    40940    29507
balance 3 + quick        676   86.6%     4111   11594       0    40940    29507

== 4. Underflow policies (tree built by 20000 random inserts, balance 3 + quick) ==
-- delete 90% of the keys in random order (counters: the deletes only) --
policy                 pages   fill balances  writes   freed    moved   to old
never                    676    8.6%        0       0       0        0        0
at empty                 643    9.0%        0       0      33        0        0
below 1/3 (balance 3)    122   47.7%      553    1104     554    12523    12523
below 1/2 (balance 3)     82   71.0%      774    1706     594    20857    20857
-- delete the 90% smallest keys, a queue being drained --
policy                 pages   fill balances  writes   freed    moved   to old
never                    676    8.7%        0       0       0        0        0
at empty                  70   84.0%        0       0     606        0        0
below 1/3 (balance 3)     70   84.0%     1020    2454     606    35971    35971
below 1/2 (balance 3)     70   84.0%     1318    3348     606    35986    35986
-- steady churn: 40000 times, toggle a random key (delete it if present, else insert it) --
policy                 pages   fill balances  writes   freed    moved   to old
never                    676   43.8%        0       0       0        0        0
at empty                 676   43.8%        0       0       0        0        0
below 1/3 (balance 3)    488   60.8%      211     443     188     5181     5181
below 1/2 (balance 3)    377   78.7%      821    2058     304    14382    14299
```

Columns: `pages` and `fill` describe the leaves at the end. `balances` counts runs of
the routine that changed something, `writes` the leaf pages it rewrote, `moved` the
cells that changed page, and `to old` those that landed on a page that existed before
the operation. The one leaf write that any put or delete needs is not counted.

Reading section 3:

- Ascending keys: a plain split leaves a half-full page behind every time (52.5%). The
  fast path gives 98.2% with zero cells moved. Balance 3 without it reaches 89.4% and
  pays 7912 page writes. No balancing rule is as good as recognising the append.
- Random order: balancing with 2 siblings raises fill from 68.5% to 82.8%, with 3 to
  86.6%. The price: 3.3 and 4.8 times as many balances, 3.7 and 6.8 times as many page
  writes. Fuller pages overflow sooner, and each repair touches more pages.
- The `to old` column is zero for a plain split. A split only moves cells onto the new
  page. Sibling balancing moves tens of thousands of cells onto pages that were
  already there.

Reading section 4:

- Random deletes of 90% of the keys: almost no page becomes completely empty, so "at
  empty" frees 33 of 676 pages and leaves the rest 9% full. The balancing policies
  shrink the tree to 122 or 82 pages and move 12,523 or 20,857 cells to do it.
- Draining a queue: pages empty out completely one after the other, so every policy
  that frees anything ends at 70 pages. "At empty" moves zero cells. The balancing
  policies move about 36,000: cells are pulled towards the page that is running low,
  only to be deleted next.
- Steady churn around half the keys: without merging the tree keeps its 676 pages at
  43.8%. Below 1/3 costs 211 balances; below 1/2 costs 821 and holds 78.7%. The tighter
  the minimum, the more work a delete can trigger.

These are counts from this model on these three workloads, not benchmarks of any
engine.

## In real databases

**Turso (the SQLite design): one routine for everything.** `balance_non_root`
(`turso/core/storage/btree.rs:3604`) is the routine this chapter copies in miniature.
The research notes (`research/turso.md`, "Balance") walk through it; the parts mirrored
here are:

- Sibling choice: at most three, `MAX_SIBLING_PAGES_TO_BALANCE = 3`
  (`btree.rs:160`), the page plus its left and right neighbours, or the first or last
  three at the edges (`btree.rs:3693-3713`). The output may be up to five pages
  (`btree.rs:163`).
- Pack left (`btree.rs:4200-4284`), producing `cell_count_per_page_cumulative`, which is
  `ends` here.
- Even out, right to left (`btree.rs:4312` onward; stop condition at
  `btree.rs:4384-4390`). The comment borrowed from SQLite says "This adjustment is not
  optional" (`btree.rs:4311`): for index pages the packing could otherwise leave the
  last sibling empty.
- Table-leaf dividers are not part of the redistributed cells; a new divider is built
  from the left page id and the rowid of the last cell on the left page
  (`btree.rs:4622-4630`). The model's parent works the same way.
- The trigger: a page is fine if it has no overflow cells and, unless it is the root,
  its free space is at most 2/3 of the usable space (`btree.rs:3427-3430`). That is the
  `below_third` policy.
- `balance_quick` (`btree.rs:3526-3600`) is the append fast path. Its conditions
  (`btree.rs:3460-3492`): a table leaf, exactly one overflow cell, that cell is the
  last, the leaf is the parent's right-most child, and the parent is not page 1.

What the model leaves out: index and interior pages, where a divider is a real cell
that joins the flattened array and one cell per boundary moves up into the parent; the
parent itself overflowing (the routine then repeats one level up); the root
(`balance_root`, chapter 12); and the order in which pages are rewritten so that no
cell is overwritten before it is read (`btree.rs:4720-4810`).

**Postgres nbtree: never merge.** The README is explicit
(`postgres/src/backend/access/nbtree/README:235-239`):

> We consider deleting an entire page from the btree only when it's become completely
> empty of items. (Merging partly-full pages would allow better space reuse, but it
> seems impractical to move existing data items left or right to make this happen ---
> a scan moving in the opposite direction might miss the items if so.)

The reason is concurrency, not space. A Postgres scan reads one leaf, releases its lock,
and later continues from the sibling link. It is "effectively stopped between pages",
and this is safe "because items are never moved across pre-existing page boundaries"
(`README:93-98`). A split is compatible with that promise: it only moves items onto a
brand-new right sibling. Redistribution and merging are not. That is exactly what the
`to old` column measures. A design that needs it to be zero cannot use the balance
routine at all, neither for inserts nor for deletes.

So nbtree removes a page only when it is completely empty, only during VACUUM, and never
the right-most page of a level (`README:239-241`). The first phase of that deletion
redirects the parent's downlink so that the page's key range falls to its right
sibling (`research/postgres.md`, section 7.4, `_bt_mark_page_halfdead`). `removeEmpty`
uses the same range-moves-right trick; the two-phase protocol and safe recycling are
chapter 24. The model's `at_empty` policy is a simplification in two ways: it runs
inside `delete` instead of in a later VACUUM pass, and it does unlink the right-most
leaf.

Why can Turso move cells freely? Per the research notes it has a single writer, no
sibling links on disk, and cursors are root-to-leaf page stacks that save their key and
re-seek after any structural change (chapter 08). Nothing is ever parked between two
pages.

**B\*-trees** as such (two-into-three splits with a 2/3 minimum) are textbook material.
None of the six codebases studied for this guide calls its tree a B\*-tree; the SQLite
design is the closest relative.

## Allocator notes

The tree takes one `std.mem.Allocator` (`gpa`) for everything that lives as long as the
tree: the page table, each page's cell array, the free list, the parent's dividers.

For the flattened cell array it creates a second allocator, a
`std.heap.ArenaAllocator` on top of `gpa`. This is the featured allocator of the chapter
and it fits the data exactly:

- **Lifetime.** `flat`, `from`, `sizes` and `ends` are born at the top of `balance` and
  are garbage when it returns. One `defer _ = self.scratch.reset(.retain_capacity)`
  frees all four on every exit path, including the error paths.
- **No per-allocation bookkeeping.** `ends` is an `ArrayList` that grows inside the
  arena; its outgrown buffers are abandoned until the reset.
- **Steady state allocates nothing.** `.retain_capacity` keeps the memory, so after the
  first few balances the scratch buffer is simply reused.

What would go wrong with other choices. Using `gpa` directly works but turns four
lifetimes into four `defer`s and makes every balance pay for allocation. A
`FixedBufferAllocator` on a stack buffer needs a bound on the number of cells in three
pages, which depends on the minimum cell size; getting it wrong is a failure instead
of a slow path. An arena that is never reset would grow with every balance. The
reverse mistake, allocating page contents from the scratch arena, would leave every
page pointing at freed memory after the first reset.

The failure tests use `std.testing.allocator` behind `checkAllAllocationFailures` (a
run of puts must return `OutOfMemory` and leak nothing at every allocation index) and a
`FailingAllocator` to show that a failed `put` leaves no trace.

## Pitfalls

- **Treating minimum fill as an invariant.** If `validate` demanded half-full pages, the
  "never" and "at empty" policies would be invalid trees, and a failed rebalance would
  have to be an error. It is a policy.
- **Forgetting the divider of the last sibling.** The last output page keeps the upper
  bound the last old sibling had; only the others get a fresh divider. And if the last
  sibling is the parent's right-most child it has no divider cell at all. Both cases
  are in `balance` and both are easy to get wrong by one.
- **Stale dividers after delete.** After deleting the largest key of a page the divider
  above it is larger than any key on the page. That is correct: a divider is an upper
  bound, not a copy of a live key. "Fixing" it costs a parent write per delete.
- **Mutating before reserving.** If `balance` rewrote the first page and then failed to
  allocate the second, cells would exist in `flat` only. Reserve, then commit.
- **Rebalancing too eagerly.** With a threshold of one half, a page sitting at the
  boundary triggers the routine again and again. A lower threshold is hysteresis.

## Exercises

1. (Easy) By hand, with capacity 100: siblings `[40 40] [30 30 30 20] [50]`, where the
   middle page has just overflowed. Compute pack-left and even-out. How many pages come
   out, and which cells changed page?
2. (Easy) `evenOut` stops when the right page would become bigger than the left. Change
   the rule to "stop when the move no longer reduces the difference between the two
   pages". Does any test change? Find sizes for which the two rules differ.
3. (Medium) Add `even_out: bool` to `Config` and skip `evenOut` when it is false. Run
   the ascending workload with `insert_siblings = 3` and no fast path. Explain the fill
   you get and why this is not a substitute for the fast path under random inserts.
4. (Medium) Postgres never deletes the right-most page of a level. Add that restriction
   to `at_empty` and to `validate`. Which of the three delete workloads changes, and by
   how many pages?
5. (Hard) Extend the model to index-style leaves, where the divider is a real cell:
   dividers join the flattened array between the siblings, and after cutting, the cell
   at each boundary moves up into the parent instead of staying in a leaf. What must
   `packLeft` account for, and why does the SQLite comment call even-out "not optional"
   in this setting?

Solutions: [solutions.md](solutions.md).

## Links

- Previous: [14. Split policies and fill factor](../14-split-policies-and-fill-factor/README.md)
- Next: [16. Bulk loading](../16-bulk-loading/README.md)
- Visualization: [viz/index.html](viz/index.html) (cells flowing between three
  siblings, and the policy comparison)

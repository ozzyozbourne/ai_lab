# Chapter 14: solutions

## 1. One split by hand

Imaginary page: 30, 10, 10, 10, 10, 20, *15 bytes, 105 in total, capacity 100. All keys
differ, so every separator is a bare key and the penalty plays no part.

```
  s  left  right  delta 50:50              delta 90:10
  1    30     75  |70 - 25|  = 45          |90*70 - 10*25| = 6050
  2    40     65  |60 - 35|  = 25          |90*60 - 10*35| = 5050
  3    50     55  |50 - 45|  =  5          |90*50 - 10*45| = 4050
  4    60     45  |40 - 55|  = 15          |90*40 - 10*55| = 3050
  5    70     35  |30 - 65|  = 35          |90*30 - 10*65| = 2050
  6    90     15  |10 - 85|  = 75          |90*10 - 10*85| =   50
```

All six candidates are legal (both sides at most 100 bytes). `half` cuts at `s=3`,
leaving 50 and 55 bytes. `rightmost-90` cuts at `s=6`: the left page is exactly 90%
full and the new cell is alone on the right page.

Check it with `split.chooseSplit` on these seven cells and `upper_key = null`.

## 2. Descending inserts

Prediction: about 50%. After the first split every insert lands on the leftmost page.
That page is not the rightmost one, so `rightmost-90` cuts it 50:50. The right half
never receives another cell; the left half fills and splits again. This is the
ascending case mirrored, and the rightmost rule looks in the wrong direction.

Measured, by replacing the key in `runWorkload` with `n - i` (20 000 inserts, seed
2014): `half` 774 pages at 50.5%, `rightmost-90` and `adaptive-90` 775 pages at 50.4%.

To do better a policy would need the mirror rule: when splitting the *leftmost* page,
leave the *right* page fill factor% full. `nbtsplitloc.c` has no such rule; its only
positional test is `is_rightmost` (`nbtsplitloc.c:287`). Descending keys are rare
enough in practice (and an index can be declared `DESC`) that the asymmetry is
accepted.

## 3. What the slack buys

Load with `Tree.init(gpa, 4096, .{ .rightmost = ff })` and keys `0..20000`, note
`tree.stats.splits`, then insert 2 000 cells `put(rng.below(20000), 20000 + i, size)`
and subtract. With seed 2014 for sizes and keys:

```
fill factor   after load          after 2000 random inserts
              pages  avg fill     new splits  pages  avg fill
   100          396    98.8%          392       788    54.6%
    90          435    89.9%          167       602    71.4%
    70          557    70.2%            0       557    77.2%
    50          774    50.5%            0       774    55.5%
```

At 100 the load is as compact as possible, and then almost every one of the 396 pages
splits on its first new cell: the page count doubles and the index is *less* compact
than if it had been loaded at 90. At 90 each page has room for about five more cells
and 167 pages run out. At 70 nothing splits. The cost of slack is paid up front and for
ever in pages that are read by every scan; the cost of no slack is paid later in splits
and in half-empty pages. An index that is only ever appended to wants 100; one that
receives updates all over wants less. That is why the fill factor is a user-visible
setting in Postgres (default 90, `nbtree.h:201`) and not a constant.

## 4. The many-duplicates guard

The problem: a page that is not rightmost holds a large run of one key `d` followed by
a few larger keys, and new keys arrive in *descending* order just above `d`. The many
duplicates strategy cuts at the right edge of the run. The new right page starts with
the smallest key above `d`. The next insert is smaller than that key, so it goes to
the left page again, which is still nearly full; it splits again at the same edge, and
leaves behind another right page holding one or two cells that will never receive
anything.

A workload that shows it (capacity 4096, `adaptive-90`, every cell 100 bytes):
`put(5, tid, 100)` for tids 0..40, so that the run fills 98% of the page, then 2 000
keys `10_000 - i` with ascending `i`. Count the pages under 10% full in `fill()`.
Measured: 2 001 pages, 2 000 of them under 10% full (one 100-byte cell each), 2.4%
average fill. The stranded right page holds whatever did not belong to the run, so
the run has to fill nearly the whole page for the effect to be this stark: with
81-byte cells (the run is 79% of the page) the same workload gives 183 pages, 181
of them 20 to 29% full. With the guard below the two runs need 98 pages (50.8%
average fill) and 79 pages (51.0%).

The guard, at the end of `chooseSplit` (Zig; `nbtsplitloc.c:833-843`):

```zig
if (strategy == .many_duplicates and !page.isRightmost() and
    cands[pick].first_right == new_index)
{
    // The cut would fall immediately to the left of the new cell, with the
    // new cell first on the right page. Fall back to the space-optimal cut.
    pick = 0;
}
```

`cands[pick].first_right == new_index` is this model's way of saying "the new item is
the first right tuple": in Postgres terms `!newitemonleft && firstrightoff ==
newitemoff`. (Postgres writes the test as a range of nine offsets and calls it
"conservative". As far as I can tell from how candidates are recorded at
`nbtsplitloc.c:225-254`, a candidate with the new item on the right never has
`firstrightoff > newitemoff`, so equality is the case that matters.) Add a test that builds the page above and checks that
the choice is the 50:50 candidate, and re-run the model test: the guard changes where
cells go, never whether the tree is valid.

## 5. Split after the new item

Idea: on a page that is not rightmost, if the new cell is the *last cell of its key* on
the imaginary page (the next cell has a larger key, or the upper bound is a different
key) and the previous cell has the same key, assume the key is an ascending stream and
cut directly after the new cell: `first_right = new_index + 1`, if that candidate is
legal. The cells of this key stay on the left page and the right page starts with the
next key, so the separator is a bare key.

Where to put it: in `chooseSplit`, before the delta sort, for `.adaptive` only, the way
`_bt_findsplitloc` calls `_bt_afternewitemoff` before anything else on a leaf that is
not rightmost (`nbtsplitloc.c:293`).

What to measure: pages, average fill and tid separators for `dup-groups` and for
`random` (which must not get worse: there the previous cell never has the same key, so
the rule must not fire at all). Do not expect the gain of the rightmost rule. With
about 8 cells per key the stream for one key is short, and after the cut the left page
is full of *other* keys that are still growing, so it splits again soon. Postgres is
careful for the same reason: the real heuristic applies only to multi-column indexes
with equally sized tuples, requires the new tuple's heap TID to be adjacent to the
previous tuple's, and falls back to the fill factor as its target when cutting after
the new item would leave the left page fuller than that (`nbtsplitloc.c:631-740`). The comment above it
admits that it "may leave extra free space" behind a group that never grows again.
The honest answer to this exercise is a table of your own counts, and it may well show
no improvement for short groups and a clear one when groups span several pages but
pages hold more than one group.

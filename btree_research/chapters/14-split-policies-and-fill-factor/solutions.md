# Chapter 14: solutions

Every count below was measured with the chapter's Zig code (20 000 inserts and seed
2014 where a workload is involved, as in the README's experiment). The code changes that
a solution describes were made in a scratch copy and are not part of the chapter's
sources; the text says what was changed so that the numbers can be reproduced.

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

`split.candidates`, `split.deltaOf` and `split.chooseSplit` on these seven cells with
`upper_key = null` give the same table and the same two cuts.

## 2. Descending inserts

Prediction: about 50%. After the first split every insert lands on the leftmost page.
That page is not the rightmost one, so `rightmost-90` cuts it 50:50. The right half
never receives another cell; the left half fills and splits again. This is the
ascending case mirrored, and the rightmost rule looks in the wrong direction.

Measured, by replacing the key of the `ascending` workload in `runWorkload` with
`n - i`: `half` 774 pages at 50.5%, `rightmost-90` and `adaptive-90` 775 pages at
50.4%. Naive `fill-90` is far worse here than anywhere in the README: 3 556 pages at
11.0%, because it packs the left page, which is exactly the one that keeps growing.

To do better a policy would need the mirror rule: when splitting the *leftmost* page,
leave the *right* page fill factor% full. `nbtsplitloc.c` has no such rule; the only
position it tests when it chooses the space target is `is_rightmost`
(`nbtsplitloc.c:287`).

## 3. What the slack buys

Load with `Tree.init(gpa, 4096, .{ .rightmost = ff })`: keys and tids `0..20000`, sizes
`rng.range(40, 121)` from one `SplitMix64.init(2014)`. Note `tree.stats.splits`. Then,
with the same generator carrying on, insert 2 000 cells
`put(rng.below(20000), 20000 + i, size)` (the key is drawn before the size) and
subtract.

```
fill factor   after load          after 2000 random inserts
              pages  avg fill     new splits  pages  avg fill
   100          396    98.8%          392       788    54.6%
    90          435    89.9%          167       602    71.4%
    70          557    70.2%            0       557    77.2%
    50          774    50.5%            0       774    55.5%
```

At 100 the load is as compact as possible, and then the second phase causes 392
splits in 396 pages: a page that is 98.8% full has about 50 bytes free, less than most
cells need. The page count doubles and the index ends up *less* compact than the one
loaded at 90. At 90 a page has about 410 free bytes, room for about five cells of
average size, and there are 167 splits. At 70 nothing splits. The cost of slack is
paid up front and for ever in pages that are read by every scan; the cost of no slack
is paid later in splits and in half-empty pages. An index that is only ever appended
to wants 100; one that receives inserts all over wants less. Postgres makes the fill
factor a setting with a default of 90 (`nbtree.h:201`) and not a constant.

## 4. The many-duplicates guard

The problem: a page that is not rightmost holds a large run of one key `d` followed by
a few larger keys, and new keys arrive in *descending* order just above `d`. The many
duplicates strategy cuts at the right edge of the run. The new right page starts with
the smallest key above `d`. The next insert is smaller than that key, so it goes to
the left page again, which is still nearly full; it splits again at the same edge, and
leaves behind another right page holding only the cells above the run, which will
never receive anything.

A workload that shows it (capacity 4096, `adaptive-90`, every cell 100 bytes):
`put(5, tid, 100)` for tids 0..40 (40 cells, so that the run fills 98% of the page),
then `put(10_000 - i, 40 + i, 100)` for `i` in 0..2000. Count the pages under 10% full
in `fill()`.
Measured: 2 001 pages, 2 000 of them under 10% full (one 100-byte cell each), 2.4%
average fill. The stranded right page holds whatever did not belong to the run, so
the run has to fill nearly the whole page for the effect to be this stark: with
81-byte cells (the run is 79% of the page) the same workload gives 183 pages, 181
of them 20 to 29% full. With the guard below the two runs need 98 pages (50.8%
average fill) and 79 pages (51.0%).

The guard, at the end of `chooseSplit` just before `const c = cands[pick]` (Zig;
`nbtsplitloc.c:833-843`):

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
`firstrightoff > newitemoff`, so equality is the case that matters.)

A test for it: 40 cells `(5, tid)` of 100 bytes, then `(8999, 50)` as the new cell at
index 40 and `(9000, 49)` after it, capacity 4096, upper key 9001. Without the guard
`adaptive-90` cuts before index 40 (many duplicates); with it, before index 21, the
same cut as `half`. With the guard in place all of the chapter's tests still pass,
the model test and the comparison with `expected_output.txt` included: the guard
changes none of the numbers in the README's experiment.

## 5. Split after the new item

The rule, as simple as it can be made in this model: on a page that is not rightmost,
if the cell before the new one has the same key and the cell after it has a larger
key, assume the key is an ascending stream and cut directly after the new cell, so
that the cells of this key stay on the left page and the right page starts with the
next key (a bare-key separator). When the new cell is the last one on the imaginary
page there is no gap after it and the rule cannot apply.

In `chooseSplit`, before the first `deltaSort`, the way `_bt_findsplitloc` calls
`_bt_afternewitemoff` before anything else on a leaf that is not rightmost
(`nbtsplitloc.c:293`):

```zig
if (policy == .adaptive and !page.isRightmost() and
    new_index > 0 and new_index + 1 < items.len and
    items[new_index - 1].key == items[new_index].key and
    items[new_index + 1].key != items[new_index].key)
{
    for (cands) |c| if (c.first_right == new_index + 1) { // only if that gap is legal
        return .{
            .first_right = c.first_right,
            .left_bytes = c.left_bytes,
            .right_bytes = c.right_bytes,
            .penalty = 1,
            .strategy = .default,
            .interval = 1,
        };
    };
}
```

Measured under `adaptive-90`, pages and average fill, with the number of splits the
rule decided in brackets. The last column adds one condition, the model's version of
Postgres's "heap TID adjacency": `items[new_index - 1].tid + 1 == items[new_index].tid`.
The rows "with N keys" are `dup-groups` with `rng.below(N)` as the key.

```
workload                     no rule       with the rule       ... and adjacent tids
random                       565  69.0%    565  69.0%   (0)    565  69.0%   (0)
dup-groups (2500 keys)       572  68.2%    697  56.0% (539)    572  68.2%   (1)
dup-groups with 1000 keys    582  67.0%    643  60.7% (494)    583  66.9%   (1)
dup-groups with 400 keys     567  68.8%    567  68.8% (272)    567  68.8%   (1)
dup-groups with 100 keys     447  87.3%    447  87.3%  (64)    447  87.3%   (0)
dup-heavy (22 keys)          417  93.6%    417  93.6%  (16)    417  93.6%   (0)
```

So the answer is no. The rule never helped, and on the workload the exercise names it
costs 125 pages, 22% more. The number of separators with a tid is the same in all
three columns of every row. `random` is untouched, as it must be: there the cell
before the new one never has the same key.

Why it loses (my reading of the numbers, not a further measurement): tids ascend with
arrival, so a new cell is always the last one of its key. The rule's condition
therefore says little more than "this key already has a cell on this page", and it
decided 539 of the 696 splits of `dup-groups`. Each of those cuts falls wherever the
newest cell happens to sit, which is a random place on the page, and nothing makes the
next inserts follow it: they go to other keys. The rule replaces a balanced cut by a
random one. Requiring adjacent tids removes the damage by removing the rule: with keys
drawn at random, two consecutive rows almost never share a key, and it fired at most
once per run.

I also tried a workload in which the adjacency test does hold: `dup-groups`, but each
randomly chosen key receives a burst of 4 cells with consecutive tids. Without the
rule 584 pages at 66.9%; with it 658 at 59.4%; with the adjacency condition 645 at
60.6%. With bursts of 16 the three results are 565, 592 and 592 pages. Still a loss.

The case the heuristic exists for, a long ascending stream per group, shows up in this
single-column model as one key filling whole pages, and the single value strategy
already handles it: `dup-heavy` reaches 93.6% without the rule. Postgres is careful in
the same direction. `_bt_afternewitemoff` (`nbtsplitloc.c:631-740`) returns false at
once for single-column indexes, applies only to pages of equally sized, narrow tuples,
requires the new tuple's heap TID to be adjacent to the previous tuple's unless the
new tuple is the last on the page, and uses the leaf fill factor as its target when
cutting after the new item would leave the left page fuller than that. The comment
above it admits that it "may leave extra free space" behind a group that never grows
again.

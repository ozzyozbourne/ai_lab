# Chapter 29: solutions

## 1. Verdicts by hand

Chunks: `[3, 9]` holding 3 8 5 9; `[11, 14]` holding 12 14 11 14; `[2, 20]` holding 7 20 2 16.

`v < 14`:

| Chunk | Reasoning | Verdict | Comparisons | Matches |
|---|---|---|---|---|
| 0 | max 9 < 14 | always true | 0 | 4 |
| 1 | max 14 is not < 14, min 11 < 14 | maybe | 4 | 2 (12, 11) |
| 2 | max 20 is not < 14, min 2 < 14 | maybe | 4 | 2 (7, 2) |

Total: 8 matches, 8 row comparisons instead of 12.

`v != 9`:

| Chunk | Reasoning | Verdict | Comparisons | Matches |
|---|---|---|---|---|
| 0 | 9 is inside [3, 9], and min != max | maybe | 4 | 3 |
| 1 | 9 is outside [11, 14] | always true | 0 | 4 |
| 2 | 9 is inside [2, 20] | maybe | 4 | 4 |

Total: 11 matches, 8 comparisons. Note chunk 2: all four rows match, but the summary
could not prove it.

## 2. A distinct-value count

"Always true" for `v = c` means every row equals `c`. If every row equals `c` then the
smallest and the largest row equal `c`, which is exactly `min == max == c`. A distinct
count of 1 says the same thing as `min == max`, and a distinct count of 2 or more means
some row differs from `c`. So the count adds no power to this check.

Uses for it: estimating how many rows a filter will return when the verdict is "maybe"
(a planner question), or deciding whether the chunk is worth dictionary encoding.

## 3. An `In` filter

The list is sorted, so "is any listed value inside `[min, max]`" is one lower-bound search
(chapter 02):

```zig
// values: sorted, no duplicates, not empty
fn checkIn(zone: Zone, values: []const u64) Prune {
    // first listed value >= zone.min
    var lo: usize = 0;
    var hi: usize = values.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (values[mid] < zone.min) lo = mid + 1 else hi = mid;
    }
    if (lo == values.len or values[lo] > zone.max) return .always_false;
    // Every row matches only if the chunk holds a single value and it is listed.
    if (zone.min == zone.max) return .always_true; // values[lo] == zone.min here
    return .maybe;
}
```

When `min == max` and the search found a value in `[min, max]`, that value must be `min`,
so the chunk's only value is in the list. `matches` is a binary search of the row value
in the list. In the model test, generate a random sorted list of 1 to 5 constants and add
it as an eighth filter kind; the existing oracle loop and the per-chunk soundness check
need no change, which is the point of writing them against `Filter` and not against one
operator.

## 4. Sorting the chunks, then the rows

Sorting the chunks by `min` changes nothing about pruning. The same summaries exist and
all of them are still tested; a summary's verdict does not depend on its position. It
does not even permit an early exit, because the `max` values are not in order: a chunk
that starts low can still reach high.

Sorting the rows makes the zones disjoint and ordered: `max` of chunk i is at most `min`
of chunk i + 1. Now a binary search over the summaries finds the first chunk that can
match, and a range filter touches one contiguous run of chunks. That is the static
two-level index of chapter 01 (a sorted array with one level of fence keys), or equally
the leaf level of a B+tree with one inner level and no slack.

An insert in the middle now has to shift every later row, O(n), and rewrite every later
summary. Fixing that cost by leaving free space in chunks and splitting a full chunk in
two is exactly how the B+tree of chapters 04 and 07 comes about.

## 5. A three-level IVF

Sketch: build a second `Ivf` whose data is the centroid array of the first (say 16 coarse
cells over 256 fine centroids). Routing becomes: rank the 16 coarse centroids, take the
nearest `nprobe_coarse` cells, rank only the fine centroids in those cells, take the
nearest `nprobe` of them, scan their lists.

This is the B-tree idea of adding height: when one node (the root) is too large to scan,
put an index on top of it. FAISS offers it as an HNSW graph over the centroids (the
research notes cite `faiss/faiss/index_factory.cpp:318-322` for the `IVF..._HNSW..`
factory string).

What it costs: in a B-tree every level routes exactly, so height is free in accuracy. Here
every level can route wrongly. The right fine centroid may sit in a coarse cell that was
not probed, for the same boundary reason that a vector can sit in a list that was not
probed. The errors of the two levels compound, so expect lower recall than the two-level index
at the same number of vectors scanned; what the extra level saves is centroid
comparisons, which only matters when `nlist` is large compared with the lists scanned.
The measurement to report is three numbers per setting: centroid
distances computed, vectors scanned, recall.

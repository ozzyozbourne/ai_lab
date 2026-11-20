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

Sorting the chunks by `min` does not change a single verdict: the same summaries exist,
and a summary's verdict does not depend on its position. Tried on the program's layouts
with its five filters, every count (skipped, counted whole, scanned, rows compared) is
the same before and after; on `shuffled` every filter still compares all 2000 rows.

What the order of `min` does give is half a search. For a filter with an upper bound
(`v < c`, `v <= c`, `v = c`, `between`) a chunk whose `min` is past the bound is "always
false", and so is every chunk after it, so the scan can stop there. A filter with only a
lower bound (`v >= c`) gets nothing, because the `max` values are in no order: a chunk
that starts low can still reach high. Measured, as summaries tested out of 20:

| Layout, chunks sorted by `min` | `v = 777` | `v < 250` | `400 <= v <= 449` | `v >= 1500` |
|---|---|---|---|---|
| `shuffled` (every `min` is between 0 and 117) | 20 | 20 | 20 | 20 |
| `arrival` | 8 | 3 | 5 | 20 |

On `shuffled` the cut-off never fires: each chunk is a random sample of the whole domain,
so every `min` is small. The cut-off saves tests of summaries, never row comparisons.

Sorting the rows makes the zones disjoint and ordered: `max` of chunk i is at most `min`
of chunk i + 1. Now both ends are ordered, a binary search over the summaries finds the
first chunk that can match, and a range filter touches one contiguous run of chunks. On
the sorted `shuffled` rows `v = 777` takes 7 summary tests instead of 20 (5 for the
search, the one matching chunk, and the chunk that ends the run) and compares 100 rows
instead of 2000. That is the chunked sorted array with a directory from chapter 01 ("the
one-level trap": one slot per chunk holding its first key), or equally the leaf level of
a B+tree with one inner level and no slack.

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
probed, and the errors of the two levels compound.

Measured with a scratch version built from this chapter's `Ivf` (not part of the chapter's
code): 20,000 uniform points in 16 dimensions, 256 lists, 16 coarse cells holding 11 to
21 centroids each, k = 10, 200 queries. Each cell shows centroid distances computed per
query, vectors scanned per query, and recall:

| `nprobe` | two levels | three levels, 1 coarse cell | 2 coarse cells | 4 coarse cells |
|---|---|---|---|---|
| 1 | 256, 78, 25.0% | 31, 77, 17.5% | 48, 77, 21.0% | 80, 77, 24.0% |
| 4 | 256, 314, 53.2% | 31, 312, 28.1% | 48, 312, 38.5% | 80, 313, 48.4% |
| 16 | 256, 1259, 86.3% | 31, 1126, 30.8% | 48, 1248, 48.2% | 80, 1252, 67.7% |
| 32 | 256, 2512, 95.6% | 31, 1243, 30.8% | 48, 2359, 48.4% | 80, 2504, 70.3% |

At the same number of vectors scanned the three-level index finds fewer true neighbours
in every row, and with one coarse cell recall stops near 31% however large `nprobe` is:
lists outside the probed cells cannot be reached. The saving is in centroid distances (31
to 80 instead of 256), which is small next to the vectors scanned here and only matters
when `nlist` is large compared with the lists scanned. The same run on 20,000 clustered
2-D points (the chapter's blob generator) shows a much smaller loss: at `nprobe` = 2,
98.3% with two levels against 91.1%, 97.8% and 98.3% with 1, 2 and 4 coarse cells. These
are counts from one data set each, not a law.

# Chapter 29: Zone maps and vector indexes

## What you will learn

- How a list of per-chunk `(min, max)` summaries (a zone map) prunes a scan without
  keeping anything sorted, and why its test has three outcomes, not two.
- Why a zone map is as good as a B-tree on clustered data and useless on shuffled data.
- Why no sort order of two or more dimensions keeps near points near, and therefore why a
  B-tree cannot answer "which vectors are closest to this one".
- IVF, a vector index that keeps the "root routes to a leaf" half of a B-tree; `nprobe`
  and recall.
- HNSW in outline: a skip list with the order removed (visualization and prose only).

Prerequisites: chapters 01 (cost model), 02 (lower bound) and 07 (B+tree separators).

## The idea in plain words

### A zone map is a B+tree's inner level with the order thrown away

An inner node of a B+tree is a list of statements "every key in child *i* lies between
this separator and the next one". Because the statements are sorted and do not overlap,
one binary search finds the single child that can hold a key.

A zone map keeps the statements and drops the sorting. The column is cut into chunks in
whatever order the rows arrived, and each chunk remembers its smallest and largest value.
A scan with a filter asks each chunk's summary one question before touching the rows.
There are three possible answers:

| Answer | Meaning | Work for this chunk |
|---|---|---|
| always false | no row can match | none: skip it |
| always true | every row matches | none: add the row count |
| maybe | the summary cannot tell | compare every row |

Two things follow. There is no navigation: every summary is tested, so the cost is
proportional to the number of chunks, not its logarithm (acceptable, because a summary is
tiny and a chunk is large). And the benefit depends entirely on the data. If rows arrive
in key order the zones are narrow and disjoint, and the zone map behaves like the bottom
inner level of a B+tree. If they arrive in random order every zone spans nearly the
whole domain and every answer is "maybe".

A B-tree pays to keep keys sorted on every insert; a zone map pays one `min` and one
`max`. That is why analytical engines, which append in bulk and filter on many columns,
keep zone maps on every column and a real index on few or none.

### No total order preserves nearness

A B-tree works for "find 42" and "find everything between 40 and 50" because the answer
is one contiguous run of the sorted order. "Find the points nearest to (5, 5)" is also a
contiguous region, but of the plane, and the plane has to be flattened into one order
before a B-tree can store it.

Any flattening breaks some neighbourhoods. Sort by `(y, x)` (row-major): cells side by
side stay adjacent, but cells above each other are a whole row apart. Interleave the bits
of x and y instead (Z-order): most touching cells are close, but at the seams of the
curve they are far apart. The program measures both on a 16 x 16 grid: row-major has 240
touching pairs that are 16 positions apart; Z-order has only 64 pairs that far apart, but
the worst is 86. It is a textbook result (not from the sources studied here) that every
order of an n x n grid separates some touching pair by at least n positions.

So for nearness in many dimensions there is nothing to binary-search. The two families
below each keep one half of the B-tree idea and replace the comparison.

### IVF: a root without order

Pick `nlist` representative points (centroids) with k-means. Store each vector in the
list of its nearest centroid. This is a two-level tree: the root holds the centroids, the
leaves are flat lists.

To search, compute the distance from the query to every centroid, take the nearest
`nprobe` lists, scan them completely and keep the best k. Compare this with a B-tree
root:

- Routing is a scan over all centroids, not a binary search, because centroids have no
  order.
- The cells are not intervals. The query's true neighbour can be just across a cell
  boundary, in a list whose centroid is only second nearest. With `nprobe = 1` it is
  missed. This cannot happen in a B-tree, where the key falls in exactly one child.
- So the result is approximate. **Recall** is the fraction of the true k nearest
  neighbours (found by brute force) that the index returned. Raising `nprobe` trades
  work for recall; `nprobe = nlist` is brute force with extra steps.

### HNSW: a skip list without order

A skip list gives every key a random height; tall keys form sparse express levels, and
search moves right while the next key is not past the target, then drops a level. HNSW
gives every vector a random top level in the same way and links it to a few near
neighbours on each of its levels. Search starts at one entry point on the top level and
moves to whichever neighbour is closer to the query; when none is closer it drops a
level. "Move right while smaller" has become "move to a closer neighbour", and the
stopping rule has changed from a proof (the next key is too big) to a local minimum
(nobody I am linked to is closer). A local minimum is not always the nearest point, so
HNSW is approximate too, and the bottom level keeps several candidates instead of one.
The third visualization page lets you find queries where the descent stops short.

## A worked example by hand

**Zone map.** Twelve values in arrival order, chunks of four:

```
chunk 0:  3  8  5  9     min 3,  max 9
chunk 1: 12 14 11 14     min 11, max 14
chunk 2:  7 20  2 16     min 2,  max 20
```

Filter `v >= 10`:

- chunk 0: max 9 < 10, so no row matches: skip.
- chunk 1: min 11 >= 10, so all four match: add 4 without reading a row.
- chunk 2: min 2 < 10 <= max 20: maybe. Compare 4 rows; 20 and 16 match.

Answer 6, with 4 row comparisons instead of 12. Filter `v = 9`: chunk 0 is "maybe" and
contains it; chunk 1 is skipped; chunk 2 is "maybe" and contains no 9. The summary of
chunk 2 was a false positive: a zone map can only prove absence.

**IVF.** Seven points and two centroids:

```
list 0, centroid (3, 2):  A(1,1)  B(2,3)  C(3,1)  G(5,3)
list 1, centroid (8, 2):  D(7,2)  E(8,4)  F(9,1)
```

Check G: its squared distance to (3,2) is 4 + 1 = 5 and to (8,2) is 9 + 1 = 10, so it
belongs to list 0. Query q = (6, 3):

- Route: q to centroid 0 is 9 + 1 = 10, to centroid 1 is 4 + 1 = 5. List 1 is nearest.
- `nprobe = 1`: scan D (1 + 1 = 2), E (4 + 1 = 5), F (9 + 4 = 13). Answer: D at 2.
- The truth: G is at 1 + 0 = 1. G sits in list 0, on the other side of the boundary.
- `nprobe = 2`: scan both lists (7 vectors, all of them) and find G.

## Code walk-through

Both versions have the same four files. Zig first.

**`zonemap.zig`**. `checkZone(zone, op, c)` is the three-way test for one comparison. Each
arm asks "true for all rows?" then "true for some row?":

```zig
.ge => if (zone.min >= c) .always_true else if (zone.max >= c) .maybe else .always_false,
```

`Filter.between` is two one-sided checks joined by `andPrune`. `append` widens the last
zone or opens a new one, reserving space in both lists first so that a failed allocation
cannot leave a row without a zone. `scan` touches rows only in "maybe" chunks. `validate`
recomputes every min and max. The model test compares `scan` with a loop over all rows
and checks every verdict against the rows of its chunk.

**`zorder.zig`**. `interleave` builds a Morton code; `gapStats` measures, for all touching
cell pairs, how far apart their positions are in row-major or Z-order.

**`ivf.zig`**. Vectors are `i32` coordinates stored back to back; distances are squared
`u64`; every comparison is on `(dist, id)` so ties have one answer. `Ivf.build` chooses
`nlist` starting centroids with a seeded shuffle, runs Lloyd's iterations (assign each
vector to the nearest centroid, move each centroid to the rounded mean of its vectors)
until no assignment changes, and lays the lists out with a counting sort. The loop always
exits just after an assignment step, which makes the invariant in `validate` true: every
vector is stored in the list of its nearest centroid. `search` ranks the centroids, scans
`nprobe` lists and keeps a sorted top-k buffer. `flatSearch` is brute force and defines
the right answer.

The lists are not an array of arrays. List `c` owns positions
`list_offsets[c] .. list_offsets[c+1]` of two flat arrays, with the vectors copied next
to their ids, so scanning a list is one sequential pass, like scanning a leaf page.

**`root.zig`** holds the data generators and the fixed scenario.

**Rust.** Same names in snake_case, same tests, same output. The differences:

- `Hit` derives `Ord`; field order (`dist`, then `id`) gives the tie-break that Zig
  writes out in `lessThan`.
- `check_zone` uses a small `verdict(all, some)` helper instead of chained `if`
  expressions.
- Zig passes an allocator to `append`, `build` and `search`. Rust owns its `Vec`s: the
  k-means scratch is locals dropped at the end of `build`, the search scratch a
  `&mut Vec<Hit>` that the caller reuses.
- Zig tests `append` and `build` with `checkAllAllocationFailures`. Rust cannot make
  `Vec` fail, so `ZoneMap::with_budget` models the failure as `Err(OutOfRows)`.
- Rounded mean: `@divFloor(2 * sum + n, 2 * n)` in Zig, `div_euclid` in Rust. Both are
  floor division, so centroids agree even for negative coordinates.

Why integers? Float k-means would need the same additions in the same order, with no
fused multiply-add, to print identical centroids in two languages. The cost of integers
is that a centroid is rounded to the grid, moving it by less than one unit.

### Output

`zig build run` and `cargo run` both print `expected_output.txt`:

```
== 1. zone maps: 2000 rows in 20 chunks of 100 ==
layout    predicate        skip  all  scan  rows compared  matches
sorted    v = 777            19    0     1            100        1
sorted    v >= 1500          15    5     0              0      500
sorted    v < 250            17    2     1            100      250
sorted    400 <= v <= 449    19    0     1            100       50
sorted    v != 777            0   19     1            100     1999
arrival   v = 777            16    0     4            400        0
arrival   v >= 1500          12    5     3            300      636
arrival   v < 250            17    0     3            300      101
arrival   400 <= v <= 449    16    0     4            400       44
arrival   v != 777            0   16     4            400     2000
shuffled  v = 777             0    0    20           2000        1
shuffled  v >= 1500           0    0    20           2000      500
shuffled  v < 250             0    0    20           2000      250
shuffled  400 <= v <= 449     0    0    20           2000       50
shuffled  v != 777            0    0    20           2000     1999
append 150 rows (5000 down to 4851) to 'sorted': 22 chunks, last chunk has 50 rows, min 4851, max 4900

== 2. one sort order for two dimensions: touching cells on a 16 x 16 grid ==
order      pairs  gap >= 16  largest gap  sum of gaps
row_major    480        240           16         4080
z_order      480         64           86         4080

== 3. IVF in 2 dimensions: 240 points, 8 lists, k = 5, 24 queries ==
k-means: assignments stopped changing after 7 centroid updates
list  size  centroid
   0    17  (651, 282)
   1    38  (549, 620)
   2    23  (720, 255)
   3    34  (683, 614)
   4    30  (612, 540)
   5    41  (280, 410)
   6    39  (236, 228)
   7    18  (524, 510)
nprobe  vectors scanned  of brute force  true neighbours found  recall
     1              792            5760             109 / 120      90%
     2             1519            5760             120 / 120     100%
     3             2210            5760             120 / 120     100%
     4             2781            5760             120 / 120     100%
     8             5760            5760             120 / 120     100%
first miss: query 12 at (572, 572)
  true nearest: id 93 at (563, 573), dist2 82, stored in list 1
  nearest centroid: list 4 (dist2 2624); list 1 ranks 2 (dist2 2833)
  so nprobe must be at least 2 to find it

== 4. IVF in 16 dimensions: 2000 uniform points, 16 lists, k = 10, 50 queries ==
k-means: 25 centroid updates (limit 25)
list sizes: smallest 106, largest 148
nprobe  vectors scanned  of brute force  true neighbours found  recall
     1             6215          100000             144 / 500      28%
     2            12428          100000             236 / 500      47%
     4            24943          100000             362 / 500      72%
     8            49951          100000             477 / 500      95%
    16           100000          100000             500 / 500     100%
```

How to read it:

- Section 1. On `sorted` data almost every chunk is decided by its summary. On `arrival`
  data (row number plus a delay of up to 299) zones overlap their neighbours, so three or
  four chunks are scanned; `v = 777` reads 400 rows to find nothing. On `shuffled` data
  the zone map never helps. The last line shows that appends only touch the last zone.
- Section 2. Same total gap, distributed differently: row-major makes half the pairs
  moderately bad, Z-order makes a few pairs very bad.
- Section 3. One probe scans 792 of 5760 vectors and finds 109 of the 120 true
  neighbours. Query 12 is the hand example again.
- Section 4. In 16 dimensions with uniform data one probe finds 28% of the true
  neighbours, and it takes half the lists to reach 95%. These are counts from this
  program on this data, not a general law.

## In real databases

**DuckDB zone maps.** A table is stored in row groups of 122,880 rows
(`duckdb/src/include/duckdb/storage/storage_info.hpp:23`), and column segments carry
statistics including min and max. `CheckZonemapTemplated`
(`duckdb/src/storage/statistics/numeric_stats.cpp:209-278`) is the three-way test; the
`>=` arm at lines 231-241 has the same structure as `checkZone` in this chapter. The
result enum has five values, not three: `NO_PRUNING_POSSIBLE`, `FILTER_ALWAYS_TRUE`,
`FILTER_ALWAYS_FALSE`, and two more for NULLs, `FILTER_TRUE_OR_NULL` and
`FILTER_FALSE_OR_NULL` (`duckdb/src/include/duckdb/common/enums/filter_propagate_result.hpp:16-20`).
This chapter's column has no NULLs. A scan checks the zone map when it enters a row group
(`duckdb/src/storage/table/row_group.cpp:385`) and skips the group on "always false"
(`row_group.cpp:791-794`).

**DuckDB's index-scan cut-off.** DuckDB also has a pointer index (the ART of chapter 28),
but uses it only for very selective filters. The scan probes the index with room for
`max(index_scan_max_count, index_scan_percentage * total_rows)` row ids
(`duckdb/src/function/table/table_scan.cpp:1015-1020`); the defaults are 2,048 and 0.001
(`duckdb/src/include/duckdb/main/settings.hpp:2027-2052`). If the probe would return more,
`ART::Scan` resets the output and returns false (`duckdb/src/execution/index/art/art.cpp:896-902`)
and the scan falls back to a sequential scan with zone maps.

**Milvus skip index.** Milvus keeps per-chunk metrics with the same purpose. Its range
test, `RangeShouldSkip`
(`milvus/internal/core/src/index/skipindex_stats/SkipIndexStats.h:168-187`), spells out
the four inclusive/exclusive combinations and returns a boolean: a two-way answer,
without "always true". Integer chunk metrics also hold an optional bloom filter
(`SkipIndexStats.h:491-496`), which the research notes describe as serving equality:
min/max for ranges, bloom for points, where a B-tree does both by keeping order.

**FAISS IVF.** The class comment describes exactly the structure above: "a few (nprobe)
quantization indices are selected and several inverted lists are visited"
(`faiss/faiss/IndexIVF.h:212-217`). The default is `nprobe = 1` (`IndexIVF.h:96`). Search
asks the coarse quantizer for the nearest centroids, then prefetches those lists
(`faiss/faiss/IndexIVF.cpp:916-921`), like read-ahead for leaves. FAISS's k-means
defaults to 25 iterations and seed 1234 (`faiss/faiss/Clustering.h:24`, `:50`) and
splits large clusters to refill empty ones (`faiss/faiss/Clustering.cpp:413`); this
chapter's version leaves an empty cell empty.

**FAISS HNSW.** Levels are drawn with `levelMult = 1 / log(M)`
(`faiss/faiss/impl/HNSW.cpp:62-63`), so each level is about M times sparser than the one
below; M plays the part of fanout. Search does a greedy descent from `entry_point` through
the upper levels (`HNSW.cpp:1775-1783`, `greedy_update_nearest_impl` at `:702`) and then a
candidate search on level 0 with `efSearch` candidates, default 16
(`faiss/faiss/impl/HNSW.h:144`). The graph is not made of pointers: all neighbour lists
live in one array indexed through `offsets` (`HNSW.h:123-129`).

**What FAISS does not have.** Per the research notes, a search of the FAISS source for
kd-trees and ball trees finds nothing.

Not verified in these sources (textbook): the claim that no linear order of two or more
dimensions keeps all near pairs near, the grid lower bound quoted above, and "distances
concentrate in high dimensions".

## Allocator notes

The plan assigns this chapter an arena for clustering scratch.

- **Where.** `Ivf.build` creates a `std.heap.ArenaAllocator` on top of the caller's
  allocator and takes four temporary arrays from it: the shuffled ids, the per-centroid
  coordinate sums, the per-centroid counts and the counting-sort cursors. One
  `defer arena_state.deinit()` frees them all.
- **Lifetime.** The scratch dies when `build` returns, on success and on every error
  path. The five slices of the index come from the caller's `gpa` and are freed by
  `Ivf.deinit`. Two lifetimes, two allocators.
- **Why an arena.** The scratch arrays are born and die together. An arena turns four
  `free`s and four `errdefer`s into one line; compare the five `errdefer gpa.free(...)`
  lines the long-lived slices need in the same function.
- **What would go wrong otherwise.** Index slices taken from the arena would be freed
  when `build` returns, leaving the index pointing at freed memory. Scratch taken from
  `gpa` needs an `errdefer` each; `checkAllAllocationFailures` fails every allocation in
  turn and reports any that is forgotten as a leak.
- **Second use.** `search` takes a `scratch` allocator for the buffer that ranks the
  centroids. The scenario passes an arena and calls `reset(.retain_capacity)` before each
  query, so later queries allocate nothing. Passing `gpa` would leak a buffer per query.
- **Zone map.** `ZoneMap` holds two `ArrayList`s on the general-purpose allocator: they
  grow as long as the table does, and an arena never gives memory back early.
- **Rust.** Locals dropped at the end of `build` are the arena; a reused `&mut Vec<Hit>`
  is `reset(.retain_capacity)`.

## Pitfalls

- **Treating "maybe" as "true".** A zone that contains the constant proves nothing about
  the rows. Only "always true" may skip the comparison.
- **Wrong inclusivity.** `v > c` is "always false" when `max <= c`; `v >= c` is not. Test
  every operator with the constant below, at, inside and above the zone.
- **Stale summaries.** An in-place update that does not widen the zone makes the scan
  return wrong answers silently (the test "validate catches a stale summary" shows it).
  Too-wide bounds after a delete are harmless; too-narrow bounds are a bug.
- **Comparing distances with a square root or with floats** when exact agreement matters.
  Squared integer distances order vectors identically and reproduce everywhere.
- **Unbroken ties.** Two vectors at the same distance must be ordered by something (here
  the id), or top-k results and k-means assignments depend on iteration order.
- **Leaving the loop after a centroid update.** Then lists are filled from assignments
  made against the old centroids, and "each vector is in its nearest centroid's list"
  is false. Exit after an assignment step.
- **Reading recall as a guarantee.** B-tree bounds are exact; IVF and HNSW numbers depend
  on the data, the queries and the knobs.
- **Calling HNSW a tree or a skip list.** It is a graph with cycles and no key order.

## Exercises

1. (easy) By hand, give the verdict of `v < 14` and of `v != 9` for each of the three
   chunks in the worked example, and the number of row comparisons.
2. (easy) The `=` check returns "always true" only when `min == max == c`. Suppose each
   zone also stored the number of distinct values in its chunk. Explain why that would
   not let `=` return "always true" more often, and name one thing the count could be
   used for.
3. (medium) Add a filter `In { values }` (the value is one of a small sorted list).
   Write its three-way check and extend the model test.
4. (medium) Sort the `shuffled` layout's chunks by their `min` without moving rows inside
   a chunk. Does pruning improve? Then sort the rows. What have you built, and what
   would an insert cost now?
5. (hard) Replace the scan over all centroids in `rankLists` with a second, smaller IVF
   over the centroids (a three-level index). Measure recall against the two-level version
   at the same number of vectors scanned. Which B-tree idea is this, and what does it
   cost here that it does not cost in a B-tree?

Solutions are in [solutions.md](solutions.md).

## Links

- Previous: [chapter 28, radix trees and hash indexes](../28-radix-trees-and-hash-indexes/README.md)
- Next: [chapter 30, tracing a real insert](../30-tracing-a-real-insert/README.md)
- Visualizations: [zone-map pruning](viz/index.html), [IVF probing](viz/ivf.html),
  [greedy graph descent](viz/hnsw.html)

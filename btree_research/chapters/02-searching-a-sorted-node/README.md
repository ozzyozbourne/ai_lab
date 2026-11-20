# Chapter 02: Searching a sorted node

## What you will learn

Chapter 01 showed why a database index is made of wide nodes: each node is one page
read, and a wide node cuts the number of page reads. This chapter is about what happens
after the page is in memory. A node is a small sorted array of keys, and every operation
on a B-tree (lookup, insert, delete, range scan, choosing a child to descend into) begins
by searching that array.

After this chapter you can:

- write `lowerBound` and `upperBound` from memory and say why each line is the way it is,
  using a loop invariant instead of trial and error;
- explain why a node search returns an **insertion index** and not "found or nothing";
- translate a range with inclusive or exclusive ends into two bound calls;
- name the classic off-by-one traps and the tests that catch them;
- use a galloping (exponential) search when the answer is near a known position.

Prerequisites: chapter 01, arrays and slices, a `while` loop. No trees yet.

Out of scope here: making the search fast on real hardware (branchless loops, prefetch,
SIMD, Eytzinger layout). That is chapter 25. This chapter is about being correct.

## The idea in plain words

Take a sorted array and a key. Do not ask "is the key in the array?". Ask instead:

> How many elements are smaller than the key?

Call the answer `i`. It is a number between 0 and `len`, so there are `len + 1` possible
answers, and it always exists, even for an empty array. It is called the **lower bound**
and it means three things at once:

1. `keys[i]` is the first element that is `>= key` (if `i < len`);
2. the key is present exactly when `i < len` and `keys[i] == key`;
3. if the key is absent, `i` is the position where it must be inserted to keep the array
   sorted.

One search therefore serves `get` (point 2), `put` (points 2 and 3), `delete` (point 2)
and the start of a range scan (point 1). This is why the code returns
`SearchResult { found, index }`.

The **upper bound** asks a slightly different question: how many elements are smaller
than *or equal to* the key? It is the index of the first element `> key`. The two bounds
differ only when the key is present: the copies of the key sit exactly in
`[lowerBound, upperBound)`. With unique keys, as in Part I of this guide, the upper bound
is the lower bound plus one when the key is found. With duplicates (chapter 07 onwards,
and inside real indexes) the difference matters a lot.

### The loop, derived from an invariant

Binary search is famous for being easy to get wrong. The reliable way to write it is to
decide first what the two variables *mean* and never break that meaning.

One piece of notation first. `keys[a..b]` means the elements at indices `a`, `a + 1`,
..., `b - 1`: the start is included and the end is **excluded**. So `keys[0..7]` stops at
index 6, `keys[0..0]` is empty, and `keys[hi..]` runs from `hi` to the last element. A
range written this way is called **half-open** (in maths notation `[a, b)`), and the loop
below is the half-open style of binary search. For the lower bound:

```
keys[0..lo]   are all <  key      "known small": the answer is not left of lo
keys[hi..]    are all >= key      "known large": the answer is not right of hi
keys[lo..hi]  unknown
```

Start with `lo = 0`, `hi = len`: both known regions are empty, so the statement is true.
Each step picks one unknown element `keys[mid]` and compares it once:

- `keys[mid] < key`: this element and everything left of it is small. `lo = mid + 1`.
- otherwise: this element and everything right of it is large. `hi = mid`.

Either way the unknown region shrinks and the statement stays true. When `lo == hi` it
is empty, and the statement says that `lo` is the answer. The whole function:

```zig
var lo: usize = 0;
var hi: usize = keys.len;
while (lo < hi) {
    const mid = lo + (hi - lo) / 2;
    if (keys[mid] < key) lo = mid + 1 else hi = mid;
}
return lo;
```

Every detail follows from the invariant:

- `hi = keys.len`, not `len - 1`: `hi` is an index into the *answers*, and `len` is a
  valid answer (the key is larger than everything).
- `while (lo < hi)`: stop when nothing is unknown.
- `lo <= mid < hi` always holds inside the loop, so `keys[mid]` is a real element and
  the region shrinks in both branches. The loop cannot spin forever.
- `hi = mid`, not `mid - 1`: `keys[mid]` is `>= key`, so `mid` may be the answer.
- For the upper bound, change `<` to `<=`. Nothing else.

The cost is one comparison per step. The unknown region has `n` elements and is at least
halved each time, so the loop runs at most as many times as `n` has binary digits: 4
steps for the 12 keys below, 13 for 4096 keys. The tests assert this bound.

## A worked example by hand

The node holds the canonical keys of chapters 03 to 08 in sorted order:

```
index:   0   1   2   3   4   5   6   7   8   9  10  11
key:     1   3   5   6   7  10  12  15  17  20  25  30
```

`lowerBound(13)`:

| step | lo | hi | mid | keys[mid] | `keys[mid] < 13`? | action |
|------|----|----|-----|-----------|-------------------|--------|
| 1 | 0 | 12 | 6 | 12 | yes | `lo = 7` |
| 2 | 7 | 12 | 9 | 20 | no | `hi = 9` |
| 3 | 7 | 9 | 8 | 17 | no | `hi = 8` |
| 4 | 7 | 8 | 7 | 15 | no | `hi = 7` |

`lo == hi == 7`. `keys[7]` is 15, not 13, so the result is `{found = false, index = 7}`:
13 is absent, and inserting it at index 7 (between 12 and 15) keeps the node sorted.
The invariant holds at the end: `keys[0..7]` (1 to 12) are all less than 13, and
`keys[7..]` (15 to 30) are all at least 13.

Now a node with duplicates, `3 7 7 7 12 15 15 20`, and the key 7:

- `lowerBound(7)`: mid 4 (12, not `< 7`, `hi = 4`), mid 2 (7, not `< 7`, `hi = 2`),
  mid 1 (7, not `< 7`, `hi = 1`), mid 0 (3 `< 7`, `lo = 1`). Result 1.
- `upperBound(7)`: mid 4 (12, not `<= 7`, `hi = 4`), mid 2 (7 `<= 7`, `lo = 3`),
  mid 3 (7 `<= 7`, `lo = 4`). Result 4.

The three sevens are at indices `[1, 4)`, and `4 - 1 = 3` is their count. Notice that
the lower bound walked *left* through the equal keys and the upper bound walked *right*:
neither may stop when it first sees a 7.

### Ranges with inclusive and exclusive ends

A range query has two ends and each end is inclusive or exclusive. All four cases reduce
to the two bounds, and the result is always a half-open index range `[start, end)`:

| key range end | index |
|---------------|-------|
| start `>= k` | `lowerBound(k)` |
| start `> k` | `upperBound(k)` (skip the keys equal to `k`) |
| end `<= k` | `upperBound(k)` (step past the keys equal to `k`) |
| end `< k` | `lowerBound(k)` |

On the canonical node: `[5, 17]` gives indices `[2, 9)`, seven keys; `(5, 17)` gives
`[3, 8)`, five keys. If the ends are not keys, as in `[4, 16]` and `(4, 16)`, all four
combinations give the same answer. The same idea gives neighbours: the last key `<= k`
is at `upperBound(k) - 1` and the last key `< k` at `lowerBound(k) - 1`, when those
bounds are not 0.

### Galloping

Binary search always starts with the whole array. If you already know the answer is at
or after some position `from`, and probably close to it, you can do better. First look
at `keys[from]` itself: if it is already `>= key`, the answer is `from`, after one
comparison. Otherwise probe `from + 1`, `from + 3`, `from + 7`, ... (the step doubles
each time) until a probe is `>= key`, then binary search between the last two probes. If
the answer is `d` positions away this costs about `2 * log2(d)` comparisons, however
long the array is. The typical use is a sorted batch of lookups: each search starts
where the previous one ended, and the first comparison is what makes a lookup that lands
on the same position cost one comparison instead of a whole search.

## Code walk-through

### Zig (`zig/src/`)

- `search.zig` is the chapter. `lowerBound` and `upperBound` are the loops above with the
  invariant in the comments. `search` adds the `found` flag with one more comparison
  (`index < keys.len and keys[index] == key`: the length test must come first).
  `equalRange` returns a `Span { start, end }`. `rangeSpan` takes two
  `Bound = union(enum) { unbounded, included: u64, excluded: u64 }` values and applies the
  table above, clamping an inverted range such as `(7, 7)` to an empty span.
  `lastLessOrEqual` and `lastLess` return `?usize`, so "there is none" is `null` and not
  an underflowed index. `gallopLowerBound(keys, from, key)` keeps `keys[below] < key`
  while doubling `step`, then calls `lowerBound` on the bracket.
  `linearLowerBound` and `linearUpperBound` are the oracles: a linear scan that cannot be
  wrong.
- `trace.zig` repeats the loops with a recorder (`traceBound` writes one `Step` per
  iteration into a caller buffer) and with comparison counters. Tests prove the twins
  return what the plain functions return.
- `node.zig` is `Node(capacity)`: inline key and value arrays plus a length. `get`,
  `put`, `delete` and `range` each call `search` once and then act at the returned index;
  `put` opens a gap with `std.mem.copyBackwards` and returns `error.NodeFull` when there
  is no room, which is the error a B-tree answers by splitting (chapter 04). `validate`
  checks that the keys are strictly increasing.
- `main.zig` prints the demo. `prng.zig` and `ops.zig` are copies from `common/`.

The tests are the second half of the lesson. `firstCounterexample` enumerates **all**
330 sorted arrays of length 0 to 7 over the alphabet `{1, 3, 5, 7}` and searches each
for every key from 0 to 8, so every position below, between, on and above the elements
is tried. It returns the smallest input where a candidate disagrees with the linear
scan. Two deliberately wrong versions show it working: the "closed interval" bug fails
on `[1]` with key 2, the "return as soon as equal" bug on `[1, 1]` with key 1. (A third
wrong version, the mixed convention of pitfall 2, has its own test because it does not
terminate.) A seeded
test compares against `std.sort` on random arrays, and the node is model-tested against
the oracle from `common/` with 20 000 operations.

### Rust (`rust/src/`)

Same files, names (in snake_case), tests and output. The differences are worth reading:

| Topic | Zig | Rust |
|-------|-----|------|
| Index range | own `Span { start, end }` | `std::ops::Range<usize>`, which can index a slice: `&keys[span]` |
| Range end | own `Bound` tagged union | `std::ops::Bound<u64>` from the standard library |
| "None" index | `?usize`, `if (i == 0) null else i - 1` | `Option<usize>`, `i.checked_sub(1)` |
| Overflow | `+` traps in debug and safe builds; `+%` wraps | `+` panics in debug builds; `wrapping_add`, `checked_add` |
| Node capacity | `Node(4)`: a function returning a type | `Node<4>`: a const generic parameter |
| Unused slots | `undefined` | must be initialised (`[0; CAP]`) |
| Shifting | `std.mem.copyBackwards` / `copyForwards` | `slice.copy_within` |
| Errors | `error{NodeFull}!?u64` | `Result<Option<u64>, NodeFull>` |
| Scratch memory | `FixedBufferAllocator` over a stack buffer | a stack array split with `split_at_mut_checked` |
| Crate layout | one module rooted at `main.zig` | `lib.rs` + `main.rs`, so unused `pub fn`s are not dead code |

Both standard libraries already have these functions: Rust as
`keys.partition_point(|&k| k < key)` (`<=` for the upper bound), Zig as
`std.sort.lowerBound`, `upperBound`, `equalRange` and `partitionPoint`. Rust's
`keys.binary_search(&key)` returns `Ok(index)` or `Err(insertion_index)`, the same
information as `SearchResult`, with one caveat that the seeded test checks: with
duplicates it may return *any* of the equal elements, so it is not a lower bound.

### Output

Both programs print exactly `expected_output.txt`; a test in each language checks it.
Sections 3 and 7:

```
[3] trace of lowerBound(13); invariant: keys[0..lo] < 13 <= keys[hi..]
step  lo  hi  mid  keys[mid]  decision
   1   0  12    6         12  12 <  13 is true:  lo = mid + 1 = 7
   2   7  12    9         20  20 <  13 is false: hi = mid = 9
   3   7   9    8         17  17 <  13 is false: hi = mid = 8
   4   7   8    7         15  15 <  13 is false: hi = mid = 7
result: 7 after 4 comparisons

[7] sorted batch of probes against 4096 sorted keys (seed 2): comparisons
probes  binary from 0  gallop from cursor
     4             48                  75
    64            768                 732
  1024          12291                4495
  4096          49154                8822
```

Binary search costs about 12 comparisons per probe whatever the batch looks like.
Galloping from the previous answer is *worse* for 4 probes (the answers are about a
thousand positions apart, and `2 * log2(1000)` is more than 12), about equal for 64, and
several times cheaper once the probes are dense. It is a tool for one situation, not a
replacement. These are comparison counts from this program, not timings.

## In real databases

All four engines search a sorted sequence inside a page or block with the ideas above.
File and line references are to the checkouts under `db_study/`.

**Postgres.** `_bt_binsrch` (`postgres/src/backend/access/nbtree/nbtsearch.c:345-451`) is
one half-open loop for both bounds. It sets `high` one past the last item (`:390`,
"establish the loop invariant for high"), computes `mid = low + ((high - low) / 2)`
(`:396`), and compares with a threshold `cmpval` that is 1 for a lower bound and 0 when
the caller sets `nextkey`, which turns it into an upper bound (`:392`, `:400-403`). The
comment at `:382-386` states the invariant in the same words as this chapter: "all slots
before 'low' are < scan key, all slots at or after 'high' are >= scan key". The
post-processing is where leaf and internal pages differ: a leaf returns `low`, the first
item `>=` the key (`:429`), or the slot before it for a backward scan (`:427`); an
internal page returns `OffsetNumberPrev(low)` (`:451`), the last pivot before the bound,
whose downlink is the child to follow. That is this chapter's `lastLess` /
`lastLessOrEqual`. `_bt_binsrch_insert` (`:477`) is the variant used for inserts.

**Turso.** Keys are not stored in an array: the page has an array of 2-byte cell
pointers and each key is read through it (`turso/core/storage/pager.rs:506-518`: pointer
`idx` in the cell pointer array, then a varint rowid inside the cell). The search over
that array uses the other classic formulation, a *closed* interval with a remembered
candidate (`turso/core/storage/btree.rs:2143-2165`): `while min <= max`, midpoint
`(min + max) >> 1`, and when the cell qualifies it is saved in
`state.nearest_matching_cell` and the search continues to its left with
`max = cur_cell_idx - 1`. If no cell qualifies, the descent follows the page's
right-most pointer (`btree.rs:2198-2203`). `min` and `max` are stored back into the
cursor state (`:2165-2166`) because Turso's operations can be suspended and resumed.
The leaf search for an exact rowid returns as soon as it sees an equal key
(`btree.rs:2725-2733`); that early exit is correct there because rowids are unique, and
it is exactly bug 2 of the tests when keys can repeat. (That `min + max` cannot overflow
for the number of cells in one page is my reading, not a statement in the source.)

**Milvus.** Its sorted-array scalar index maps the four inclusive / exclusive
combinations to `std::lower_bound` and `std::upper_bound` exactly as in the table above
(`milvus/internal/core/src/index/scalar/sort/SortedIndexReader.cpp:637-642`). For
`IN (...)` lists it sorts the query values and walks the index with one cursor, using a
galloping search to advance it
(`milvus/internal/core/src/index/scalar/sort/SortedMembership.h:45-62`): double `hi`
while `value_at(cursor + hi) < value`, then a lower bound inside the bracket. The comment
at `:53-54` warns never to compare by subtracting values. `gallopLowerBound` in this
chapter is the same algorithm, written independently.

**TigerBeetle.** `binary_search_values_upsert_index`
(`tigerbeetle/src/lsm/binary_search.zig:33-147`) returns "either the index of the value
equal to `key`, or if there is no such value then the index where `key` would be
inserted" (`:17-18`), and explicitly "doesn't perform the extra key comparison to
determine if the match is exact" (`:32`). The exact-match wrapper adds that one
comparison (`:190`), the same split as `lowerBound` and `search` here. Note a naming
difference: its `.upper_bound` mode returns the *last* equal element (`:24-26`), not one
past it as C++ and this chapter define it. The file tests itself exhaustively
(`:561-569`, every length below 300 in both modes). Its loop is a different, branch-free
formulation with prefetching; chapter 25 studies it.

## Allocator notes

Searching needs no memory. Every function takes a slice (`[]const u64`, `&[u64]`) over
memory the caller owns: the node's inline array today, a page from the buffer pool from
chapter 12 on. `traceBound` writes into a caller-provided array for the same reason. A
search that allocated would add a failure path and a cost to the hottest loop of the
tree for nothing.

The only memory this chapter needs is for test and demo arrays, and for those the natural
allocator is `std.heap.FixedBufferAllocator`: a bump pointer over a buffer that already
exists.

- **Choice.** The arrays are short-lived, their total size is known in advance, and
  nothing is freed individually. `main` puts a 64 KiB buffer on the stack and hands
  `fba.allocator()` to `run`; the program makes no heap allocation and no system call for
  memory.
- **Lifetime.** The memory lives as long as the buffer's stack frame. `fba.reset()`
  drops everything at once; the seeded tests call it once per round. `free` only reclaims
  the most recent allocation, which is why `run` frees its two arrays in reverse order
  (with `defer`) and a test checks that `end_index` is back at 0.
- **Failure.** A full buffer returns `error.OutOfMemory`; two tests exercise that path.
- **What would go wrong with another one.** Nothing dramatic, only waste.
  `std.testing.allocator` per array pays for bookkeeping the test does not need; it is
  used only where a test needs a real heap: as the *backing* buffer of one
  `FixedBufferAllocator` (so a leak still fails the test), for the oracle of the node
  model test, and for the output buffer of `main`'s test. An `ArenaAllocator` allocates
  from the heap and grows without limit. `page_allocator` rounds every small array up to
  a page.
- **A trap that was hit while writing this chapter.** A `[N]u8` buffer has alignment 1.
  Allocating `u64`s from it may first skip up to 7 bytes, so a buffer sized for exactly
  `n` keys can fail. The buffers are declared `align(@alignOf(u64))`.

Rust mirrors this with a stack array `[0u64; N]` passed as `&mut [u64]`:
`make_sorted` carves keys off the front with `split_at_mut_checked` and returns the
rest, and a buffer that is too small gives `None` (mapped to
`io::ErrorKind::OutOfMemory` in `run`).

## Pitfalls

1. **`(lo + hi) / 2` overflows.** With 8-bit indices, `200 + 250` wraps to 194 and the
   "midpoint" is 97, outside the interval; a test shows it. Use `lo + (hi - lo) / 2`.
2. **Mixing interval conventions.** `hi = len - 1` with a `lo < hi` loop can never
   return `len`; `lo <= hi` with `hi = mid` either never terminates (keys `1`, key 0:
   `lo = hi = mid = 0` forever) or reads one past the end (keys `1`, key 2 reads
   `keys[1]`); a test shows both. Choose half-open (this chapter, Postgres) or closed
   with a remembered candidate (Turso) and derive every line from it.
3. **`hi - 1` on unsigned indices.** The closed form computes `mid - 1`, which underflows
   at 0 for unsigned types. Turso's `min_cell_idx` and `max_cell_idx` are signed
   (`isize`, `btree.rs:614-615`), so `max` can become -1. The half-open form never
   subtracts one inside the loop.
4. **Stopping at the first equal key.** Correct only if keys are unique. With duplicates
   you get an arbitrary one, and a range scan that starts there silently loses rows.
5. **Reading `keys[index]` without checking `index < len`.** The lower bound can be
   `len`.
6. **Comparing by subtraction.** `a - b < 0` is wrong for unsigned keys and overflows
   for signed extremes. Compare with `<`.
7. **An unsorted array.** Binary search does not fail on it, it answers wrongly. That is
   why `validate` exists and why the tests call it after every operation.
8. **Inverted ranges.** `(7, 7)` gives `start = 5 > end = 4` on the canonical node
   before clamping; `end - start` would underflow.

## Exercises

Solutions are in [solutions.md](solutions.md).

1. (warm-up) By hand, on the canonical node: trace `lowerBound(6)`, `upperBound(6)` and
   `lowerBound(31)`. For each, give the final index, the number of comparisons, and what
   `search` reports.
2. (easy) Write `countInRange(keys, lo, hi)` returning how many keys `k` satisfy
   `lo <= k <= hi`, using only `lowerBound` and `upperBound`. What must it return when
   `lo > hi`, and does your version do that without a special case?
3. (medium) Rewrite `lowerBound` in the closed-interval style Turso uses: signed `min`
   and `max`, `while (min <= max)`, and a "nearest matching" variable. State its loop
   invariant, and check it with the exhaustive test.
4. (medium) An interior node with separators `s[0..n]` has `n + 1` children, and child
   `i` holds the keys `k` with `s[i-1] <= k < s[i]` (treat the missing ends as minus and
   plus infinity). Which bound gives the child index for a key? Which one if the
   convention is `s[i-1] < k <= s[i]` instead? Check with separators `10, 20` and the
   keys 5, 10, 15, 20, 25.
5. (harder) Both bounds are instances of one function,
   `partitionPoint(keys, pred)`: the index of the first element for which `pred` is
   false. Implement it, express `lowerBound`, `upperBound` and the galloping search with
   it, and say precisely what property `pred` must have. Then give an array on which
   the predicate "the key is odd" makes `partitionPoint` return a wrong answer, and say
   why.

## Links

- Visualization: [viz/index.html](viz/index.html) (step through lower and upper bound,
  predict the next step, try your own keys).
- Previous: [Chapter 01: Why B-trees](../01-why-btrees/README.md)
- Next: [Chapter 03: B-tree structure and search](../03-btree-structure-and-search/README.md)

# Chapter 25: Cache-conscious search and layout

Part IV, "Beyond the textbook".

## What you will learn

Chapter 01 said: count page reads, not comparisons. Once the page is in memory the
same argument repeats one level down. The CPU reads memory in 64-byte **cache lines**,
and it guesses the outcome of every `if` before it knows the answer. This chapter is
about searching a sorted node so that it touches few lines and has no guess to get wrong.

You will learn:

- why chapter 02's binary search is slow on modern CPUs although it makes the fewest
  comparisons;
- the "halving" binary search, and why "branchless" is a property of machine code, not
  of source code;
- software prefetch, and a SIMD linear scan of a small node;
- the Eytzinger layout and a pointer-free B-tree with one cache line per level;
- struct-of-arrays nodes, and when each technique is worth using.

Prerequisites: chapter 01 (cost model, fanout), chapter 02 (lower bound, insertion
index). Nothing from Parts II or III is needed.

Everything here is measured in **counts**: comparisons, compare instructions, distinct
cache lines. They come from a small model in `trace.zig` / `trace.rs` and are identical
in Zig and Rust. There are no timings in the text; an optional `--bench` flag prints
timings to stderr for your own machine.

## The idea in plain words

Two things make a memory access expensive.

**A cache miss.** Memory arrives in lines of 64 bytes. Eight `u64` keys fit in one line.
Reading a key whose line is not in the cache means waiting for main memory, which takes
far longer than the comparison itself (textbook; how much longer depends on which cache
level, if any, still has the line). Reading a second key from the same line is nearly free. So the unit to count is the
number of *distinct lines*, exactly as chapter 01 counted distinct pages.

**A mispredicted branch.** The CPU runs many instructions ahead of the one it is
finishing. At an `if` it guesses. In a binary search for a random key the comparison
`keys[mid] < key` is a coin flip, so the guess is wrong about half the time and the
speculative work is thrown away.

The techniques of this chapter attack one or both:

| Technique | Attacks | In one sentence |
|---|---|---|
| Halving search with a conditional move | branches | The loop runs a fixed number of times and the comparison only selects a value |
| Prefetch | misses | Ask for the next line before you know you need it |
| SIMD linear scan | branches | Compare 8 keys with one instruction, count the hits |
| Eytzinger layout | misses (via prefetch) | Store the search tree in breadth-first order so the next lines are predictable |
| Block tree (8 keys per node) | misses | A B-tree whose node is one cache line: one line per level |
| Struct of arrays | misses | Keep keys together so that a line of keys contains only keys |

Notice that the last two rows are the B-tree idea again. A B-tree exists because one
node should be one unit of I/O. With disk the unit is a 4096-byte page. With memory it is
a 64-byte line.

## A worked example by hand

Fifteen keys, 10 to 150, eight per cache line. In sorted order line 0 holds indexes 0..7
(keys 10..80) and line 1 holds indexes 8..14.

```
index   0  1  2  3  4  5  6  7 |  8   9  10  11  12  13  14
key    10 20 30 40 50 60 70 80 | 90 100 110 120 130 140 150
```

**Classic search for 70** (chapter 02: `lo`, `hi`, `mid`). Probe index 7 (80, go left),
3 (40, go right), 5 (60, go right), 6 (70, go left). Four comparisons, answer 6. Each of
the four `if`s is a guess.

**Halving search for 70.** Keep a window `[offset, offset + length)`. Every step compares
the key at `offset + length/2` and then shrinks `length` by `length/2` *whichever way the
comparison went*. Only `offset` depends on the comparison.

```
offset length  half  probe      keys[probe] < 70 ?   new offset
   0     15      7    7  (80)   no                    0
   0      8      4    4  (50)   yes                   4
   4      4      2    6  (70)   no                    4
   4      2      1    5  (60)   yes                   5
   5      1                     final check: keys[5] = 60 < 70, so the answer is 5 + 1 = 6
```

Five comparisons instead of four. The sequence of lengths 15, 8, 4, 2, 1 is the same for
every needle: `ceil(log2(n))` steps plus the final check. The halving search pays up to
one extra comparison and in exchange the loop has nothing unpredictable left in it.

**Eytzinger layout.** Take the balanced binary search tree over the keys and write it
down level by level, starting at slot 1. The children of slot `k` are slots `2k` and
`2k+1`, as in a binary heap.

```
slot    1   2    3   4   5    6    7 |  8  9 10 11 12  13  14  15
key    80  40  120  20  60  100  140 | 10 30 50 70 90 110 130 150
```

Search for 70: slot 1 (80, not smaller: go to 2), slot 2 (40, smaller: go to 5), slot 5
(60, smaller: go to 11), slot 11 (70, not smaller: go to 22, which is past the end). The
slot number wrote down the path in binary: 22 is `10110`. Drop the trailing zero that
recorded the last left turn and you get `1011` = 11, the slot of the answer. In general:
drop the trailing 1 bits (right turns after the last left turn) and one more bit.

Slot 0 is unused on purpose. With it, slots 8k to 8k+7 are one cache line, and they are
exactly the eight great-grandchildren of slot k. One prefetch covers every place the
search can be three steps from now.

**Block tree.** Put eight keys in a node, so a node is one line and has nine children.
With 15 keys there are two nodes: a leaf with the eight smallest keys and a root with
the other seven and one padding slot (`-`).

```
node 0 (root):  90 100 110 120 130 140 150  -
node 1 (child 0 of the root):  10 20 30 40 50 60 70 80
```

Search for 70: in the root, count the keys smaller than 70: zero, so go to child 0. In
node 1 count again: six. Answer 6. Two vector compares, two lines, no data-dependent
branch.

The programs print exactly this (from section 1 of `expected_output.txt`):

```
needle 70 -> index 6
  classic   cmps  4 steps 4 lines 1 probes 7 3 5 6
  halving   cmps  5 steps 5 lines 1 probes 7 4 6 5 5
  vector    cmps 16 steps 2 lines 2 probes 0 8
  eytzinger cmps  4 steps 4 lines 2 probes 1 2 5 11
  blocktree cmps 16 steps 2 lines 2 probes 0 8
```

`cmps` counts key comparisons, `steps` counts compare instructions (a vector compare of
eight keys is one step), `lines` counts distinct cache lines.

### What the counts say at larger sizes

```
== 2. 1000 lookups per size: comparisons and cache lines per lookup ==
     n  algorithm     cmps   steps   lines  max lines
    15  classic       4.00    4.00    1.50          2
    15  halving       5.00    5.00    1.50          2
    15  vector       16.00    2.00    2.00          2
    15  eytzinger     4.00    4.00    2.00          2
    15  blocktree    12.77    1.59    1.59          2
  4095  classic      12.00   12.00    9.00         10
  4095  halving      13.00   13.00    9.00         10
  4095  vector     4096.00  512.00  512.00        512
  4095  eytzinger    12.00   12.00   10.00         10
  4095  blocktree    31.33    3.91    3.91          4
```

(Two of the six sizes; the rest is in `expected_output.txt`.) Read it this way:

- **Classic and halving touch the same number of lines.** The halving search is not a
  cache optimisation. It removes the unpredictable branch, nothing else.
- **The vector scan reads everything.** Two steps for 15 keys is unbeatable. 512 steps
  for 4095 keys is absurd. It is a technique for nodes of a few lines.
- **Eytzinger does not touch fewer lines than binary search.** This surprises people. A
  binary search over 4095 sorted keys reads about 9 lines, Eytzinger 10. Its advantage is
  that the lines are *predictable*, which section 4 of the output shows.
- **The block tree touches the fewest lines by far**: about 4 instead of 9 or 10, because
  each line read narrows the search by a factor of 9 instead of 2. This is chapter 01's
  fanout argument at cache-line scale.

```
== 4. Prefetch coverage, n = 4095, per lookup ==
algorithm            lines   hints  lines not hinted
halving               8.99    0.00              8.99
halving+prefetch      8.99   24.00              1.00
eytzinger            10.00    0.00             10.00
eytzinger+prefetch   10.00   12.00              1.00
```

Without prefetch every line is a miss that must finish before the next address is even
known: the misses form a chain. With prefetch only the first line is a surprise. The
halving search needs two hints per step (it does not know which half it will take, so
one hint is always wasted) and each hint is only one comparison ahead. Eytzinger needs
one hint per step and each is three comparisons ahead. The model counts hints; it cannot
tell you whether a hint arrives in time. That depends on the machine.

```
== 3. One 255-entry node: array of structs vs struct of arrays ==
layout  bytes/key  key bytes  key lines    cmps   lines  max lines
aos            16       4080         64    9.00    6.01          7
soa             8       2040         32    9.00    5.00          6
```

Same node, same nine comparisons, same probe positions. With 16-byte `{key, child,
flags}` entries the keys spread over 64 lines; as a separate column, over 32. A binary
search saves one line per lookup, because only its last few probes are close together.
Anything that reads many keys (a vector scan, a range scan, a merge) saves the full
factor of two.

## Code walk-through

Four files per language, same names and structure.

### `trace`: the counting model

Every search takes a `tracer` and calls `tracer.cmp(index)` for each key it compares,
`tracer.cmpBlock(index, 8)` for a vector compare and `tracer.prefetch(index)` for a hint.
`Trace` turns an index into a line number (`index * stride / 64`), keeps the distinct
lines in a fixed bitmap and counts. `NoTrace` has empty methods. The search is written
once and instantiated with both, so the counted code and the fast code cannot diverge.

Zig passes `tracer: anytype` and the compiler checks the calls when the function is
instantiated. Rust names the contract as `trait Tracer` and uses a generic parameter
`T: Tracer`. Both produce one specialised copy per tracer type.

### `search`: four lower bounds over a sorted slice

`lowerBoundClassic` is chapter 02's loop. `lowerBoundHalving` is the window search from
the hand example. Its `Select` parameter chooses between three spellings of the same step:

```zig
switch (select) {
    .branch => if (take_upper) {
        offset = mid;
    },
    .arithmetic => offset += half * @intFromBool(take_upper),
    .hinted => offset = if (take_upper) blk: {
        @branchHint(.unpredictable); // must be the first statement of the arm
        break :blk mid;
    } else offset,
}
```

Tests assert that all three probe the same keys in the same order, with and without
prefetch, and make exactly `halvingComparisons(n)` comparisons for every needle.

**"Branchless" is not something source code can promise.** We compiled these loops as
standalone functions and read the assembly (Zig 0.17.1 `-O ReleaseFast` and rustc 1.97
`-O`, both LLVM, x86-64). The `.arithmetic` spelling, which looks the most branch-free,
was compiled to a conditional *jump* in both languages: the optimiser recognised
"multiply by 0 or 1" as a select and then decided a jump was better. The plain `if` was
also a jump in both. The `.hinted` spelling produced a conditional move (`cmov`) in both.
Other compiler versions, targets and inlining contexts will differ. The lesson is to say what you know (this branch is
unpredictable) rather than to disguise the branch, and then to look at the output
(exercise 2).

`rank8` counts the keys of one 8-key block that are smaller than the needle:

```zig
pub fn rank8(block: *const [trace.lanes]u64, key: u64) usize {
    const V = @Vector(trace.lanes, u64);
    const smaller: @Vector(trace.lanes, bool) = @as(V, block.*) < @as(V, @splat(key));
    return @popCount(@as(u8, @bitCast(smaller)));
}
```

`lowerBoundVector` adds up `rank8` over every block of a padded array. The padding value
is the largest `u64`, which is never smaller than a needle, so the last block needs no
special case. The price is a precondition: real keys must be below the sentinel.

### `layout`: Eytzinger and the block tree

Both are built by an in-order walk of an implicit tree that hands out the sorted keys
one by one (`fill`). Both keep a parallel `rank` array (slot to sorted index) so that
their answers can be compared with the other searches. A real index would keep its
payload there instead. `validate()` repeats the in-order walk and checks that keys are
strictly increasing, ranks count 0, 1, 2, ... and the padding is intact.

The Eytzinger search is three lines:

```zig
while (k <= self.n) {
    tracer.cmp(k);
    k = 2 * k + @intFromBool(self.keys[k] < key);
}
k >>= @intCast(@ctz(~k) + 1);
return self.rank[k];
```

There is no `if` on the key at all: the comparison result is added to the index. When
we read the assembly of this loop (Zig, same setup as above) the comparison was a
compare-and-set with no jump.

`BlockTree.lowerBound` calls `rank8` once per level and moves to child `9 * block + r + 1`.

### `node`: struct of arrays

`SoaNode` and `AosNode` are fixed-capacity sorted nodes with `put`, `get` and `validate`.
The model test drives both against an oracle and asserts identical results, identical
probe sequences and `lines(SoA) <= lines(AoS)`.

### Zig and Rust differences

| Topic | Zig | Rust |
|---|---|---|
| Vector compare | `@Vector(8, u64)`, `<`, `@bitCast`, `@popCount`: explicit SIMD in the language | `std::simd` is nightly only. A fixed loop of 8 that adds 0 or 1 ("chunked auto-vectorisable loop") |
| Alignment | `gpa.alignedAlloc(u64, .@"64", n)` returns `[]align(64) u64` | `#[repr(align(64))] struct Line([u64; 8])` in a `Vec<Line>`; element i is `lines[i / 8].0[i % 8]` |
| Prefetch | `@prefetch(&keys[i], .{...})` builtin | No safe stable prefetch (`_mm_prefetch` is `unsafe` and x86-only). The Rust twin *records* the hint for the model but issues none |
| Unpredictable select | `@branchHint(.unpredictable)` inside the arm | `std::hint::select_unpredictable(cond, a, b)` |
| SoA node | `std.MultiArrayList(Entry)` derives the columns from the struct | Three `Vec`s written by hand |
| Allocation failure | `checkAllAllocationFailures` on every builder | Mirrored by the fixed node capacity: `Err(NodeFull)` |

Two honest notes about the Rust column. "Auto-vectorisable" is a hope: for the default
target (baseline x86-64) the `rank8` loop compiled to eight scalar compare-and-set
instructions, with no jumps but no SIMD either. With `-C target-cpu=native` on an AVX-512
machine the compare became one vector instruction. Zig's `@Vector` asks for the vector
operation directly and `zig build` targets the host CPU by default. And because the Rust
twin issues no real prefetch, its `--bench` rows with and without prefetch run the same
machine code.

## In real databases

**TigerBeetle** is the model for the halving search. Its
`binary_search_values_upsert_index` is the offset/length loop
(`tigerbeetle/src/lsm/binary_search.zig:33-147`), with `@branchHint(.unpredictable)` on
the step (`:110`), a comptime `Config` with `mode` and `prefetch` (`:9-12`), and a
prefetch of both possible next probes (`:59-98`). It computes the prefetch addresses
with raw pointer arithmetic and runtime safety disabled, because bounds checks would
cost more than the prefetch gains (`:70-74`); our version stays in bounds instead. Its
benchmark has two scenarios, 64 values per page ("in-cache") and
4096 values per page with a 1 GiB buffer ("out-of-cache")
(`tigerbeetle/src/lsm/binary_search_benchmark.zig:26-37`), because prefetch can only help
when the data is not already cached. TigerBeetle is not a B-tree; this routine searches
the blocks of its LSM tables.

TigerBeetle also uses the other two layout ideas. Its k-way merge keeps a loser tree "in
a flat Eytzinger layout", struct-of-arrays, with both arrays `align(64)`
(`tigerbeetle/src/lsm/k_way_merge.zig:1-34`). Its table index block stores checksums,
minimum keys, maximum keys and addresses as four separate arrays
(`tigerbeetle/src/lsm/schema.zig:120-158`), so a search over the maximum keys reads only
keys.

**FAISS** contains no key search at all. Its kernels compute vector distances. It is
here as a layout lesson: its reference distance loop is written to be auto-vectorised
(`faiss/faiss/utils/simd_impl/distances_autovec-inl.h:44-53`), and its "transposed"
kernel reads one dimension of eight vectors with one load, which is struct-of-arrays
applied to vectors (`faiss/faiss/utils/simd_impl/distances_avx2.cpp:122-170`). FAISS
shows that "scan a contiguous block very fast" is a first-class strategy, which is what
`lowerBoundVector` does for a small node.

**Postgres** and **Turso** use neither technique. `_bt_binsrch` is the classic
`low`/`high` loop and every probe calls the comparator `_bt_compare` through the line
pointer array (`postgres/src/backend/access/nbtree/nbtsearch.c:394-406`). Turso's
interior-page search is also a `min`/`max` loop that decodes a cell per probe
(`turso/core/storage/btree.rs:2141-2159`). Both pages are slotted (chapter 10): a probe
reads a slot and then follows it to a variable-length cell elsewhere in the page, so each
comparison can touch two lines. With variable-length keys and a comparator function, the
comparison itself dominates and none of this chapter's tricks apply directly. They apply
to fixed-width keys.

**DuckDB**'s ART Node16 would be the obvious place for a SIMD compare (16 key bytes), but
this code base searches it with a plain loop
(`duckdb/src/include/duckdb/execution/index/art/base_node.hpp:72-82`). Chapter 28 returns
to it.

The Eytzinger layout with the `8k` prefetch and the 8-key block tree are textbook
material in this guide (the standard reference is Khuong and Morin, "Array Layouts for
Comparison-Based Searching", the paper TigerBeetle's prefetch comment cites at
`binary_search.zig:61-62`). None of the six code bases uses them for key lookup.

## Allocator notes

**Aligned allocation.** `padToLanes`, `Eytzinger.init` and `BlockTree.init` allocate
their key arrays with `gpa.alignedAlloc(u64, .fromByteUnits(64), n)`. The result type is
`[]align(64) u64`: the alignment is part of the type, `lowerBoundVector` demands it in
its signature, and `gpa.free` reads it from the slice. The arrays live as long as the
index.

What goes wrong with an ordinary `gpa.alloc(u64, n)`: nothing visible. Results are the
same. But the array may start in the middle of a line. Then every 8-key block straddles
two lines, and slots 8k..8k+7 of the Eytzinger array no longer share a line, so one
prefetch covers only part of the next level. It is a silent performance bug, which is
why `validate()` checks the address.

**`MultiArrayList`.** `SoaNode` holds a `std.MultiArrayList(Entry)`. It makes one
allocation and lays the columns out one after another, so the `key` column is a dense
`[]u64`. The node reserves its full capacity in `init` and uses
`insertAssumeCapacity`, so `put` never allocates and can only fail with `NodeFull`, like
a page. `checkAllAllocationFailures` covers the builders. One limitation:
`MultiArrayList` aligns its buffer for the widest field (8 bytes), not for the cache
line. A production node would carve its columns out of a line-aligned page, as
TigerBeetle's index block does.

**Rust.** `Vec<Line>` with `#[repr(align(64))]` gives the same guarantee without unsafe
code, at the price of two-level indexing. `SoaNode` is three `Vec`s with capacity
reserved up front.

## Pitfalls

- **Prefetching everything.** A hint for a line that is already cached costs an
  instruction and gains nothing. Prefetch pays only when the structure is larger than the
  cache, which is why TigerBeetle benchmarks both cases.
- **The vector scan on big arrays.** It reads every line. Use it for a node, not for an
  index.
- **Sentinel padding.** Padding with the largest key means the largest key cannot be
  stored. Our builders assert this.
- **Forgetting the extra comparison.** The halving search makes `ceil(log2 n) + 1`
  comparisons, up to one more than the classic search. If a comparison is expensive (long
  strings, a comparator call), that can cost more than a misprediction saves.
- **Eytzinger and range scans.** In-order iteration over an Eytzinger array jumps around
  in memory. For range scans keep a sorted array.
- **These layouts are static.** Inserting means rebuilding. They suit read-mostly data
  and the inside of a node, not a whole updatable index.
- **Benchmarks on a warm cache.** Looking up the same few keys in a loop measures a
  trained branch predictor. Use many random needles.

### When each wins

| Situation | Reasonable choice |
|---|---|
| Node of up to a few lines, fixed-width keys | Vector scan |
| Sorted array that must stay sorted (range scans, merges), any size | Halving search with an unpredictable hint |
| Large read-only array, point lookups only | Block tree; Eytzinger with prefetch is simpler and close |
| Variable-length keys or a comparator function | Classic search; spend the effort on the comparison (chapter 17's truncated separators) |
| Any node layout | Keys in their own array |

## Exercises

1. (easy) By hand, run the halving search for 95 on the fifteen keys. List the probes
   and compare with the program's output. Why is the last comparison redundant here?
2. (medium) Compile the three `Select` variants as standalone exported functions and
   find the loop in the assembly. Which contain a conditional jump on the key
   comparison? Does the answer change with the optimisation mode?
3. (medium) Add `upperBound` to the halving search and to `rank8` (first key greater
   than the needle). Which single operator changes, and what happens to the sentinel?
4. (medium) The vector scan reads every block. Add an early exit: stop after the first
   block whose rank is below 8. How many lines does it read on average for a uniformly
   random needle, and what did you give up?
5. (hard) `BlockTree.lowerBound` has an `if (r < 8)`. Remove it by padding `rank` to
   nine entries per node. What goes in the ninth entry?

Solutions: [solutions.md](solutions.md).

Run with `zig build test --summary all && zig build run` in `zig/` and `cargo test &&
cargo run` in `rust/`. Add `-Doptimize=fast -- --bench` or `--release -- --bench` for
timings on stderr.

Previous: [24 MVCC, vacuum and page deletion](../24-mvcc-vacuum-and-page-deletion/README.md) ·
Next: [26 Allocators, handles and static memory](../26-allocators-handles-and-static-memory/README.md) ·
Visualization: [viz/index.html](viz/index.html)

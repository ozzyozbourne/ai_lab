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
- the Eytzinger layout and the block tree, a pointer-free search tree with one cache line
  of keys per level;
- struct-of-arrays nodes, and when each technique is worth using.

Prerequisites: chapter 01 (cost model, fanout), chapter 02 (lower bound, insertion
index). Nothing from Parts II or III is needed.

Everything here is measured in **counts**: comparisons, compare instructions, distinct
cache lines. They come from a small model in `trace.zig` / `trace.rs` and are identical
in Zig and Rust. The model counts the lines of *every* array a lookup reads, and it
assumes each array starts on a line boundary. There are no timings in the text; an
optional `--bench` flag prints timings to stderr for your own machine.

## The idea in plain words

Two things make a memory access expensive.

**A cache miss.** Memory arrives in lines of 64 bytes. Eight `u64` keys fit in one line.
Reading a key whose line is not in the cache means waiting for main memory, which takes
far longer than the comparison itself (textbook; how much longer depends on which cache
level, if any, still has the line). Reading a second key from the same line is nearly free. So the unit to count is the
number of *distinct lines*, exactly as chapter 01 counted distinct pages.

**A mispredicted branch.** The CPU runs ahead of the instruction it is finishing, and
at an `if` it guesses. In a binary search for a random key `keys[mid] < key` is a coin
flip, so the guess is wrong about half the time and the speculative work is thrown away.

The techniques of this chapter attack one or both:

| Technique | Attacks | In one sentence |
|---|---|---|
| Halving search with a conditional move | branches | The loop runs a fixed number of times and the comparison only selects a value |
| Prefetch | misses | Ask for the next line before you know you need it |
| SIMD linear scan | branches | Compare 8 keys with one instruction, count the hits |
| Eytzinger layout | misses (via prefetch) | Store the search tree in breadth-first order so the next lines are predictable |
| Block tree (8 keys per node) | misses | A search tree whose node is one cache line: one line of keys per level |
| Struct of arrays | misses | Keep keys together so that a line of keys contains only keys |

The block tree is the B-tree idea again: one node should be one unit of transfer. With
disk the unit is a 4096-byte page; with memory it is a 64-byte line. It borrows the
B-tree's node shape (8 keys, 9 children) but it is not a B-tree: it is a complete 9-ary
search tree, so leaves may sit on two adjacent levels and a node may have fewer children
than keys + 1.

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
every needle: `ceil(log2(n))` steps plus the final check. That is at most one more than
the classic search's worst case (and up to two more than its best case). In exchange the
loop has nothing unpredictable left in it.

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

Slot 11 is not sorted position 11. A second array, `rank`, maps a slot to its sorted
position: `rank[11]` is 6. That read is one more cache line, in another array.

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
node 1 count again: six, so the candidate is key 6 of node 1, which is slot 14. Node 1
has no children, the descent ends, and `rank[14]` is 6. Two vector compares, two lines of
keys, one line of `rank`, no data-dependent branch.

The programs print exactly this (from section 1 of `expected_output.txt`):

```
needle 70 -> index 6
  classic   cmps  4 steps 4 lines 1 (keys 1 + rank 0) probes 7 3 5 6
  halving   cmps  5 steps 5 lines 1 (keys 1 + rank 0) probes 7 4 6 5 5
  vector    cmps 16 steps 2 lines 2 (keys 2 + rank 0) probes 0 8
  eytzinger cmps  4 steps 4 lines 3 (keys 2 + rank 1) probes 1 2 5 11
  blocktree cmps 16 steps 2 lines 3 (keys 2 + rank 1) probes 0 8
```

`cmps` counts key comparisons, `steps` counts compare instructions (a vector compare of
eight keys is one step), `lines` counts distinct cache lines in both arrays.

The first three searches return the sorted position itself and read no second array. A
real index wants a payload (a child id, a row id), which a sorted array also keeps in a
second array, and which the two layouts would store where `rank` is. So for a payload
lookup add one line to the first three rows.

### What the counts say at larger sizes

```
== 2. 1000 lookups per size: comparisons and cache lines per lookup ==
     n  algorithm     cmps   steps  key lines  rank lines   lines  max lines
    15  classic       4.00    4.00       1.50        0.00    1.50          2
    15  halving       5.00    5.00       1.50        0.00    1.50          2
    15  vector       16.00    2.00       2.00        0.00    2.00          2
    15  eytzinger     4.00    4.00       2.00        1.00    3.00          3
    15  blocktree    12.77    1.59       1.59        1.00    2.59          3
  4095  classic      12.00   12.00       9.00        0.00    9.00         10
  4095  halving      13.00   13.00       9.00        0.00    9.00         10
  4095  vector     4096.00  512.00     512.00        0.00  512.00        512
  4095  eytzinger    12.00   12.00      10.00        1.00   11.00         11
  4095  blocktree    31.33    3.91       3.91        1.00    4.91          5
```

(Two of the six sizes; the rest is in `expected_output.txt`.) Read it this way:

- **Classic and halving touch the same number of lines.** The halving search is not a
  cache optimisation. It removes the unpredictable branch, nothing else.
- **The vector scan reads everything.** Two steps for 15 keys is unbeatable. 512 steps
  for 4095 keys is absurd. It is a technique for nodes of a few lines.
- **Eytzinger does not touch fewer lines than binary search.** This surprises people. A
  binary search over 4095 sorted keys reads about 9 lines, Eytzinger 10 of keys and one
  of `rank`. Its advantage is that the key lines are *predictable*, which section 4 of
  the output shows.
- **The block tree touches the fewest lines**: about 4 of keys and one of `rank`, 4.91 in
  total against 9 to 11, because each key line narrows the search by a factor of 9
  instead of 2. This is chapter 01's fanout argument at cache-line scale.
- **A side array is not free.** At 15 keys both layouts read more lines than the sorted
  array, because of the `rank` line. And it matters where the read happens: a block tree
  that looked `rank` up on every level instead of once at the end read 7.31 lines per
  lookup in this same run (measured by changing the code; not part of the output).

```
== 4. Prefetch coverage, n = 4095, per lookup ==
algorithm            lines   hints  lines not hinted
halving               8.99    0.00              8.99
halving+prefetch      8.99   24.00              1.00
eytzinger            11.00    0.00             11.00
eytzinger+prefetch   11.00   12.00              2.00
```

Without prefetch every line is a miss that must finish before the next address is even
known: the misses form a chain. With prefetch only the first key line is a surprise,
plus, for Eytzinger, the `rank` line, which nothing prefetches. The halving search needs
two hints per step (one is always wasted) and each is only one comparison ahead.
Eytzinger needs one hint per step, three comparisons ahead. The model counts a line as
hinted only if at least one comparison lies between the hint and the read: a hint issued
right before the read buys nothing. Whether a hint with lead time arrives in time
depends on the machine.

```
== 3. One 255-entry node: array of structs vs struct of arrays ==
layout  bytes/key  key bytes  key lines | search: cmps   lines | get: cmps  key lines  child lines   lines  max lines
aos            16       4080         64 |         9.00    6.01 |      9.99       6.01         0.00    6.01          7
soa             8       2040         32 |         9.00    5.00 |      9.99       5.00         0.51    5.52          7
```

Same node, same nine comparisons, same probe positions. With 16-byte `{key, child,
flags}` entries the keys spread over 64 lines; as a separate column, over 32. The
*search* saves one line per lookup, because only its last few probes are close together.

`get` is the search, one equality check, and for a hit the read of the child. In the
array of structs the child sits next to the key just compared. In the struct of arrays
it is in another column, which is another line: 0.51 per lookup here, because 518 of the
1000 needles were found. So a point lookup that fetches the child gains half a line, not
a whole one. Anything that reads many keys (a vector scan, a range scan, a merge) saves
the full factor of two.

## Code walk-through

Four files per language, same names and structure.

### `trace`: the counting model

Every search takes a `tracer` and calls `tracer.cmp(index)` for each key it compares,
`tracer.cmpBlock(index, 8)` for a vector compare, `tracer.prefetch(index)` for a hint and
`tracer.side(index)` for a read of a second array (`rank`, or a node's child column).
`Trace` turns an index into a line number (`index * stride / 64`), keeps the distinct
lines of each array in a fixed bitmap and counts. `NoTrace` has empty methods. The search
is written once and instantiated with both, so the counted code and the fast code cannot
diverge.

The model assumes that each array starts on a line boundary. The scenario makes that
true for every key array it searches (see Allocator notes). For the two node types it is
only an assumption: their containers align to 8 bytes, and a node that starts in the
middle of a line can touch one line more than the table says.

Zig passes `tracer: anytype` (duck typing at compile time); Rust names the contract as
`trait Tracer`. Both produce one specialised copy per tracer type.

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

**"Branchless" is not something source code can promise.** We compiled each of these
loops as a standalone exported function, *one function per source file*, and read the
assembly (Zig 0.17.1 `zig build-obj -O ReleaseFast` and rustc 1.97.0 `rustc -O`, both
LLVM, on an x86-64 Linux machine; the exact commands are in the solution to exercise 2).
What we saw: the `.arithmetic` spelling, which looks the most branch-free, was a
conditional *jump* in both languages. The plain `if` was also a jump in both. The
`.hinted` spelling was a conditional move (`cmov`) in both. This describes those two
compilers and that one context, not a rule: other versions, targets and inlining
contexts can differ, and we did not read the loops as inlined into the `--bench` binary.

One file per function matters. With all three in one file, both compilers merged the
`.hinted` function into the `.branch` function (their bodies differ only in the hint),
and what was left was the jump. The lesson is to say what you know (this branch is
unpredictable) rather than to disguise the branch, and then to look at the code that
actually ships (exercise 2).

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

The Eytzinger search is a few lines:

```zig
while (k <= self.n) {
    tracer.cmp(k);
    k = 2 * k + @intFromBool(self.keys[k] < key);
}
k >>= @intCast(@ctz(~k) + 1);
tracer.side(k);
return self.rank[k];
```

There is no `if` on the key at all: the comparison result is added to the index. When
we read the assembly of this loop (Zig, same setup as above) the comparison was a
compare, a set-on-below and an add, with no jump on the key.

`BlockTree.lowerBound` calls `rank8` once per level and moves to child `9 * block + r + 1`.
If `r < 8`, key `r` of the node is the best candidate so far. The loop only remembers
that slot number; it reads `rank` once, after the descent:

```zig
slot = if (r < lanes) block * lanes + r else slot;
block = block * fanout + r + 1;
```

`rank` has one entry more than there are slots. It holds `n`, and `slot` starts there,
so "every key is smaller" needs no special case.

### `node`: struct of arrays

`SoaNode` and `AosNode` are fixed-capacity sorted nodes with `put`, `get` and `validate`.
The model test drives both against an oracle and asserts identical results, identical
probe sequences and `lines(SoA) <= lines(AoS)`.

### Zig and Rust differences

| Topic | Zig | Rust |
|---|---|---|
| Vector compare | `@Vector(8, u64)`, `<`, `@bitCast`, `@popCount`: explicit SIMD in the language | `std::simd` is nightly only. A fixed loop of 8 that adds 0 or 1 ("chunked auto-vectorisable loop") |
| Alignment | `gpa.alignedAlloc(u64, .@"64", n)` returns `[]align(64) u64`; the scalar searches take any slice of it | `#[repr(align(64))] struct Line([u64; 8])` in a `Vec<Line>`; element i is `lines[i / 8].0[i % 8]`. Safe Rust cannot view that as `&[u64]`, so the scalar searches are generic over a small `Keys` trait |
| Prefetch | `@prefetch(&keys[i], .{...})` builtin | No safe stable prefetch (`_mm_prefetch` is `unsafe` and x86-only). The Rust twin *records* the hint for the model but issues none |
| Unpredictable select | `@branchHint(.unpredictable)` inside the arm | `std::hint::select_unpredictable(cond, a, b)` |
| SoA node | `std.MultiArrayList(Entry)` derives the columns from the struct | Three `Vec`s written by hand |
| Allocation failure | `checkAllAllocationFailures` on every builder | Mirrored by the fixed node capacity: `Err(NodeFull)` |

Two honest notes about the Rust column. "Auto-vectorisable" is a hope: for the default
target (baseline x86-64) the `rank8` loop compiled to eight scalar compare-and-set
instructions, with no jumps but no vector compare either. With `-C target-cpu=native` on
an AVX-512 machine the compare became one vector instruction. Zig's `@Vector` asks for the vector
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
reads a slot and then follows it to a variable-length cell elsewhere in the page. With
variable-length keys and a comparator function the comparison itself dominates, and this
chapter's tricks, which need fixed-width keys, do not apply directly.

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
index. The scenario's classic and halving searches run on `padded[0..n]`, a view of the
same aligned memory, so the model's assumption holds for them too.

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
line, and puts the child column directly behind the key column. The node counts above
are therefore for an idealised node whose columns each start on a line boundary. A
production node would carve its columns out of a line-aligned page, as TigerBeetle's
index block does.

**Rust.** `Vec<Line>` with `#[repr(align(64))]` gives the same guarantee without unsafe
code, at the price of two-level indexing. `SoaNode` is three `Vec`s with capacity
reserved up front; like the Zig node they are aligned to 8 bytes only.

## Pitfalls

- **Prefetching everything.** A hint for a line that is already cached costs an
  instruction and gains nothing. Prefetch pays only when the structure is larger than the
  cache, which is why TigerBeetle benchmarks both cases.
- **The vector scan on big arrays.** It reads every line. Use it for a node, not for an
  index.
- **Sentinel padding.** Padding with the largest key means the largest key cannot be
  stored. Our builders assert this.
- **Forgetting the extra comparison.** The halving search makes `ceil(log2 n) + 1`
  comparisons: at most one more than the classic search's worst case, and up to two more
  than the classic search needs for the same needle (5 keys, needle above all of them: 2
  against 4). If a comparison is expensive (long strings, a comparator call), that can
  cost more than a misprediction saves.
- **Counting only the key array.** A lookup in a second array (a rank, a child id, a
  payload) is another cache line. Do it once, after the search, not once per level.
- **Trusting a hint you did not check.** The compiler may merge a hinted function with
  an unhinted twin, or inline it into a context where it chooses differently. Read the
  assembly of the final binary.
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
| Any node layout | Keys in their own array; fetching the child then costs one more line |

## Exercises

1. (easy) By hand, run the halving search for 95 on the fifteen keys. List the probes
   and compare with the program's output. Why is the last comparison redundant here?
2. (medium) Compile the three `Select` variants as standalone exported functions, one
   per file, and find the loop in the assembly. Which contain a conditional jump on the
   key comparison? Does the answer change with the optimisation mode? What happens if
   you put all three in one file?
3. (medium) Add `upperBound` to the halving search and to `rank8` (first key greater
   than the needle). Which single operator changes, and what happens to the sentinel?
4. (medium) The vector scan reads every block. Add an early exit: stop after the first
   block whose rank is below 8. How many lines does it read on average for a uniformly
   random needle, and what did you give up?
5. (hard) `BlockTree.lowerBound` carries a `slot` through the loop and updates it with a
   select on `r < 8`. Remove both by padding `rank` to nine entries per node. What goes
   in the ninth entry?

Solutions: [solutions.md](solutions.md).

Run with `zig build test --summary all && zig build run` in `zig/` and `cargo test &&
cargo run` in `rust/`. Add `-Doptimize=fast -- --bench` or `--release -- --bench` for
timings on stderr.

Previous: [24 MVCC, vacuum and page deletion](../24-mvcc-vacuum-and-page-deletion/README.md) ·
Next: [26 Allocators, handles and static memory](../26-allocators-handles-and-static-memory/README.md) ·
Visualization: [viz/index.html](viz/index.html)

# Chapter 25: solutions

## 1. Halving search for 95 by hand

Keys 10..150 at indexes 0..14.

```
offset length  half  probe       keys[probe] < 95 ?   new offset
   0     15      7    7  (80)    yes                   7
   7      8      4   11  (120)   no                    7
   7      4      2    9  (100)   no                    7
   7      2      1    8  (90)    yes                   8
   8      1                      final check: keys[8] = 90 < 95, answer 8 + 1 = 9
```

Probes 7, 11, 9, 8, 8: the line `halving ... probes 7 11 9 8 8` of the program output.

The final check compares index 8, which the previous step had just compared. Whenever the
last step moves `offset` to `mid`, the final check repeats that comparison. The loop does
not remember which element it compared last, only the window, and remembering would need
a data-dependent branch. Recomputing a comparison on a line that is already in the cache
is cheaper than a branch that is taken half the time. The same shape is in TigerBeetle
(`tigerbeetle/src/lsm/binary_search.zig:131`:
`offset += @intFromBool(key_from_value(&values[offset]) < key);`).

## 2. Reading the assembly

Put three thin exported wrappers in a file next to a copy of `search.zig` and `trace.zig`:

```zig
const search = @import("search.zig");
const trace = @import("trace.zig");
export fn h_branch(p: [*]const u64, n: usize, key: u64) usize {
    return search.lowerBoundHalving(.branch, false, p[0..n], key, trace.NoTrace{});
}
// ... h_arith with .arithmetic, h_hinted with .hinted
```

```
zig build-obj -O ReleaseFast wrappers.zig -femit-asm=wrappers.s
```

In the loop body look at the instruction after `cmp qword ptr [...], rdx` (the key
comparison). A `jb` / `jae` there is a data-dependent jump; a `cmovb` / `cmovae` is a
conditional move. What we saw with Zig 0.17.1 on x86-64 is described in the README
(jump for `.branch` and `.arithmetic`, `cmov` for the hinted form). Two traps:

- LLVM may merge functions whose code is identical after ignoring hints, so a wrapper
  can end up as an alias of another (`h_hinted = h_branch` in the symbol table). Write
  the loop out by hand in each exported function, or give them different surroundings,
  to see each variant's own code.
- In `Debug` mode nothing is optimised: every variant has jumps (and bounds checks).
  The question only makes sense for optimised builds, and the answer can change between
  `ReleaseSafe` (bounds checks stay) and `ReleaseFast`.

For Rust: `rustc -O --crate-type lib --emit asm` on a file with `#[unsafe(no_mangle)]`
functions, or `cargo rustc --release -- --emit asm`.

## 3. Upper bound

Upper bound is the number of keys less than *or equal to* the needle. One operator
changes: `<` becomes `<=`, in the loop comparison and in the final check of the halving
search, and in the vector compare of `rank8`:

```zig
const not_greater: @Vector(8, bool) = @as(V, block.*) <= @as(V, @splat(key));
```

The invariant flips accordingly: `keys[offset - 1] <= key` and `key < keys[offset + length]`.
TigerBeetle's loop has a comptime `mode` that switches the same operator
(`tigerbeetle/src/lsm/binary_search.zig:9-12`, `:104-107`).

The sentinel breaks for exactly one needle. A padding slot holds `maxInt(u64)`, and
`maxInt <= maxInt` is true, so for the needle `maxInt` the padding would be counted and
the result would exceed `n`. Either forbid that needle (it cannot be a real key anyway,
real keys must be below the sentinel) or clamp: `@min(count, n)`.

## 4. Early exit in the vector scan

```zig
while (i < padded.len) : (i += lanes) {
    const r = rank8(padded[i..][0..lanes], key);
    count += r;
    if (r < lanes) break; // a key >= needle was seen: every later key is larger still
}
```

For a needle whose answer is uniformly distributed over the array, the scan stops in a
uniformly random block, so it reads about half of the blocks on average: (B + 1) / 2 of
B blocks. Needles above every key still read all of them.

What you gave up: the trip count now depends on the data. The loop-exit branch is
mispredicted about once per search, and the compiler can no longer unroll the whole scan
of a fixed-size node into straight-line code. For a node of two to four lines the
unconditional version is usually the better trade; for sixteen lines the early exit is.
Count lines with the tracer to see where the totals cross; time it with `--bench` on
your machine to see where the cost crosses.

## 5. Removing the `if (r < 8)` from the block tree

When the rank inside a node is 8, every key of the node is smaller than the needle and
the best candidate is whatever the ancestors had found. The observation that makes this
branch-free: for a given node that inherited candidate is *always the same key*. It is
the key that follows the node's whole subtree in sorted order. It depends only on the
node's position in the tree, not on the needle.

So give every node nine rank entries. Entries 0..7 are the ranks of its keys as before.
Entry 8 is the sorted index of the first key greater than everything in this node's
subtree (`n` if there is none). `fill` can write it: after the in-order walk of the whole
node, including child 8, `next` is exactly that index.

```zig
fn fill(self: *BlockTree, sorted: []const u64, block: usize, next: *usize) void {
    if (block >= self.blockCount()) return;
    for (0..lanes) |j| {
        self.fill(sorted, block * fanout + j + 1, next);
        if (next.* < sorted.len) { ...as before...  self.rank9[block * 9 + j] = next.*; ... }
        else self.rank9[block * 9 + j] = sorted.len;
    }
    self.fill(sorted, block * fanout + lanes + 1, next);
    self.rank9[block * 9 + lanes] = next.*; // successor of the whole subtree
}
```

The search then needs no running `result` at all. It remembers only the last node it
visited and the rank there:

```zig
var block: usize = 0;
var last: usize = 0;
var r: usize = lanes;
while (block < blocks) {
    r = rank8(self.keys[block * lanes ..][0..lanes], key);
    last = block;
    block = block * fanout + r + 1;
}
return if (blocks == 0) 0 else self.rank9[last * 9 + r];
```

Why the last node is enough: if `r < 8` there, key `r` of that node is the smallest key
that is `>=` the needle (its left child does not exist or the loop would have continued).
If `r == 8`, entry 8 is the successor of the subtree, which is the inherited candidate.

This is how the tree would look with child ids instead of ranks: nine child ids per node
is the natural shape of a node with eight keys, which is the "M - 1 keys, M children"
rule of chapter 03 with M = 9.

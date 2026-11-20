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

The recipe below was run with Zig 0.17.1 and rustc 1.97.0 on x86-64 Linux (an Intel Xeon
with AVX-512). It reproduces the README's statement; other versions may not.

**Zig.** Copy `search.zig` and `trace.zig` into an empty directory and add three files,
one exported function each. `one_branch.zig`:

```zig
const search = @import("search.zig");
const trace = @import("trace.zig");
export fn h_branch(p: [*]const u64, n: usize, key: u64) usize {
    return search.lowerBoundHalving(.branch, false, p[0..n], key, trace.NoTrace{});
}
```

`one_arithmetic.zig` and `one_hinted.zig` are the same with `h_arithmetic` /
`.arithmetic` and `h_hinted` / `.hinted`. Compile each on its own:

```
zig build-obj -O ReleaseFast one_branch.zig     -fno-emit-bin -femit-asm=one_branch.s
zig build-obj -O ReleaseFast one_arithmetic.zig -fno-emit-bin -femit-asm=one_arithmetic.s
zig build-obj -O ReleaseFast one_hinted.zig     -fno-emit-bin -femit-asm=one_hinted.s
```

The function body is under the label `one_branch.h_branch:` (the exported name is an
alias at the end of the file). Debug directives make it hard to read; this strips them:

```
grep -vE '^\s*\.(loc|file|cfi|p2align)|^\.Ltmp' one_branch.s
```

The function compares a key twice: `cmp qword ptr [rdi + 8*r8], rdx` inside the loop
(registers vary) and once more for the final check, where it is followed by `adc`. Look
at the instruction after the one in the loop. A `jb` there is a data-dependent jump; a
`cmovb` is a conditional move. What we saw:

| Mode | `.branch` | `.arithmetic` | `.hinted` |
|---|---|---|---|
| `ReleaseFast` | `jb` | `jb` | `cmovb` |
| `ReleaseSmall` | `jb` | `jb` | `cmovb` |
| `ReleaseSafe` | `jb` | `jb` | `cmovb` |

So the answer did not change with the optimisation mode. (`ReleaseSmall` names the
label `.Lone_branch.h_branch:`. `ReleaseSafe` emits about 700 000 lines, because the
panic handler comes along, and adds bounds and overflow checks around the comparison;
search for the label.) In `Debug` nothing is optimised and the question is meaningless.

**Rust.** In the chapter's `rust/` directory create three files next to `src/`.
`h_branch.rs`:

```rust
#![allow(dead_code)]
#[path = "src/layout.rs"] mod layout;
#[path = "src/prng.rs"] mod prng;
#[path = "src/search.rs"] mod search;
#[path = "src/trace.rs"] mod trace;

#[unsafe(no_mangle)]
pub fn h_branch(keys: &[u64], key: u64) -> usize {
    search::lower_bound_halving(search::Select::Branch, false, keys, key, &mut trace::NoTrace)
}
```

and the same with `Select::Arithmetic` and `Select::Hinted`. Then, for each:

```
rustc -O --crate-type lib --emit asm -o h_branch.s h_branch.rs
```

(AT&T syntax: the comparison in the loop is `cmpq %rdx, (%rdi,%rax,8)` or similar, after
a bounds check.) We saw `jb` after it for `Branch` and `Arithmetic` and `cmovbq` for
`Hinted`. Delete the three files and the `.s` files afterwards.

The README's other statements about machine code come from the same method: a one-line
wrapper around `rank8` (Zig at the host CPU: one `vpcmpnleuq` on a `zmm` register and a
`popcnt`; Rust with `-O`: eight `cmpq` / `setb`; Rust with `-O -C target-cpu=native`:
one `vpcmpnleuq`) and around `Eytzinger.lowerBound` (Zig: `cmp`, `setb`, `lea` in the
loop).

**The trap: all three in one file.** Put the three Zig wrappers in one file and compile
it the same way. The end of the assembly then reads:

```
h_hinted = all.h_branch
h_arithmetic = all.h_arithmetic
h_branch = all.h_branch
```

`h_hinted` is an alias of `h_branch`, and the one shared body has `jb` in its loop. LLVM's
function merging treats two functions as identical when they differ only in the
unpredictable hint, and keeps one. The Rust file with all three functions ends with
`h_hinted = h_branch` in the same way. Writing the loop out by hand in each exported
function does not help, because the bodies are still identical apart from the hint.
Separate files (separate compilation units) do.

This is more than a trap for the exercise: in a real program a hinted function can be
replaced by an unhinted twin, or be inlined into a caller where the compiler decides
differently. The assembly of the final binary is the only evidence.

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

## 5. Removing the select on `r < 8` from the block tree

When the rank inside a node is 8, every key of the node is smaller than the needle and
the best candidate is whatever the ancestors had found. The chapter's code carries that
candidate down as `slot`. The observation that makes it unnecessary: for a given node
the inherited candidate is *always the same key*. It is the key that follows the node's
whole subtree in sorted order. It depends only on the node's position in the tree, not
on the needle.

So give every node nine rank entries. Entries 0..7 are the ranks of its keys as before.
Entry 8 is the sorted index of the first key greater than everything in this node's
subtree (`n` if there is none). `fill` can write it: after the in-order walk of the whole
node, including child 8, `next` is exactly that index.

```zig
fn fill(self: *BlockTree, sorted: []const u64, block: usize, next: *usize) void {
    if (block >= self.blockCount()) return;
    for (0..lanes) |j| {
        self.fill(sorted, block * fanout + j + 1, next);
        if (next.* < sorted.len) {
            self.keys[block * lanes + j] = sorted[next.*];
            self.rank9[block * 9 + j] = @intCast(next.*);
            next.* += 1;
        } else self.rank9[block * 9 + j] = @intCast(sorted.len);
    }
    self.fill(sorted, block * fanout + lanes + 1, next);
    self.rank9[block * 9 + lanes] = @intCast(next.*); // successor of the whole subtree
}
```

The search then needs no running candidate at all. It remembers only the last node it
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

We ran this version against the linear scan for every array length from 0 to 699 and
every needle: it agrees. It still reads `rank9` exactly once per lookup, so the line
counts of the chapter do not change; what goes away is the select in the loop. We did
not measure whether that is faster.

This is how the tree would look with child ids instead of ranks: nine child ids per node
is the natural shape of a node with eight keys, which is the "M - 1 keys, M children"
rule of chapter 03 with M = 9.

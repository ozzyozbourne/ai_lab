# Chapter 06: Testing a B-tree

## What you will learn

Chapter 05 finished a complete in-memory B-tree. This chapter adds no feature to it. It
builds the tools that let you believe the tree is correct, and that will be pointed at
every structure in the rest of the guide:

- the invariants as code, with one error value per broken promise and the place it broke;
- a model-based fuzzer: one seed produces a stream of operations that goes to the tree and
  to a trivially correct oracle, and every answer is compared;
- why tests use tiny nodes, and swarm testing (each seed draws its own configuration);
- coverage counters, asserted, so a green run proves it reached the hard branches;
- three deliberately broken trees, and which check catches each one;
- minimisation: shrinking a failing run of hundreds of steps to a handful;
- fault injection: a hand-written allocator wrapper that counts and fails on demand.

Prerequisites: chapters 03 to 05 (the tree itself). In Zig, the allocator interface of
chapter 04; in Rust, the slab and its node budget.

## The idea in plain words

A unit test says "after these five inserts the tree looks like this". It checks the cases
you thought of. A B-tree fails in the cases you did not think of: a borrow between two
interior nodes at the right edge, a split while the parent is full, a failed allocation
half-way through a reservation.

So do not write the cases. Write three small things instead.

1. A checker (`validate`) that walks the whole tree and says whether every structural
   promise holds. It knows nothing about how the tree got there.
2. A model: the dumbest structure with the same behaviour. Here a sorted array (the
   `Oracle` from `common/`). It is slow and obviously right.
3. A generator: from one 64-bit seed, a sequence of `put`, `delete`, `get`, `range`.

Then run the same operations on both, compare every answer, and call the checker after
every step. Do that for many seeds. When something disagrees, you have a seed and a step
number, and the run can be repeated exactly. (If the tree crashes instead of failing a
check, see "When the tree crashes instead".)

Four refinements turn this from a toy into something that finds real bugs:

- **Tiny nodes.** With 4 children per node every few inserts split and every few deletes
  merge. With 32 children per node the same test never touches an interior node.
- **Swarm testing.** One "reasonable" mix of operations visits the same few shapes again
  and again. Let each seed pick its own mix, key range and length.
- **Coverage asserts.** Count how often each interesting branch ran and fail the test if a
  count is zero. Otherwise "no failures" may mean "never got there".
- **Minimisation.** A failure at step 52 of 256 is a fact; eleven steps you can do on paper
  are an explanation.

## A worked example by hand

Take the broken variant `merge_leaks_node` (a merge forgets to return the emptied node
to the pool) and the reproducer the minimiser prints, with M = 4:

```
put 4, put 2, put 3      one leaf [2 3 4]                        pool 1, reachable 1
put 1                    overflow, split: [3] over [1 2] [4]     pool 3, reachable 3
delete 2                 [3] over [1] [4]                        pool 3, reachable 3
delete 4                 right leaf is empty; left has 1 key and
                         cannot lend: merge [1] + 3 + [] = [1 3];
                         the root has no key left: root shrink   pool 2, reachable 1
```

After the last step the tree is the single leaf `[1 3]`, which is right. Every `get`
returns the right value. But the pool believes two nodes are alive. `validate` compares
the pool's counter with the nodes it can reach and returns `NodeCountMismatch`. Comparing
answers with the oracle would never have noticed.

## Code walk-through

The tree is copied from chapter 05 as `base_*` files. Three things were added to the copy:
coverage points (replacing chapter 05's counters), a diagnostic in `validate`, and three
fault seams marked `SEAM`. `deinit`, `shape` and `render` tolerate a malformed tree (a
missing child, a key count larger than the node), so a rejected tree can still be printed
and torn down. Two more seams break the rollback of a failed `put`; only the tests use
them, to show the harness catching them. Left out of the copy: the `StdPool` node pool
and chapter 05's unit tests of insert and delete. Here the fuzzer is their test.

### Zig

**Invariants as code** (`base_validate.zig`). Each promise has its own error:
`KeysOutOfOrder`, `KeyOutsideParentBounds`, `NodeOverfull`, `NodeUnderfull`, `EmptyRoot`,
`LeavesAtDifferentDepths`, `MissingChild`, `UnexpectedChild`, `WrongKeyCount`,
`NodeCountMismatch`. A Zig error is a bare tag and cannot carry data, so the place of the
violation travels through an out-parameter:

```zig
pub const Diagnostic = struct { depth: usize = 0, first_key: ?u64 = null };
pub fn validate(comptime M: usize, root: ?*const Node(M), expected_len: usize, diag: ?*Diagnostic) Error!void
```

A node's own checks (key count, order, bounds, child slots) all run before the walk
descends, so the error names the wrong node closest to the root.

**Coverage** (`coverage.zig`). An enum of 21 points and an array of counters. The tree
calls `tree.coverage.hit(.split_interior)` at each branch. Points are split by level
because "a split happened" does not tell you whether an interior split, which also moves
children, was ever run.

**The fuzzer** (`fuzz.zig`).

- `swarm(seed) Case` draws the configuration: 4, 16, 64 or 256 possible keys; 64 to 512
  operations; weights for put, delete, get, range (any of the last three may be zero);
  how often a put gets an injected allocation failure; whether the run ends by deleting
  every remaining key in random order; and where the keys lie (`KeyLayout`): from 0,
  around 2^32, spread evenly over all of `u64` (equal low 32 bits, half with the top bit
  set), or just below 2^64. Every layout keeps the keys' order, so the tree's shape does
  not depend on it; only the numbers compared do. The largest key used is
  `maxInt(u64) - 1`, because a half-open `range` cannot contain `maxInt`.
- `generate(gpa, case) []Step` produces the whole sequence up front. A `Step` is an `Op`
  plus an optional fault ("the n-th node allocation of this put fails").
- `replay(Tree, gpa, steps, checks, totals) ?Failure` builds a fresh tree and a fresh
  oracle and applies each step to both. After every step: compare the answer, call
  `validate`, compare the key count; every 16 steps and at the end, compare a full
  in-order scan with the oracle. The first failed check ends the run with a
  `Failure{ step, kind, diag }`. After a put that was made to fail, the tree must validate
  and have the same contents and the same `pool.usage` as before.
- `hunt` runs one swarm case per seed and stops at the first failure; `huntShortest` runs
  all seeds and keeps the failure that needed the fewest steps.

`replay` takes the tree type as a `comptime` parameter. The broken variants are chosen the
same way:

```zig
pub fn BTreeWith(comptime M: usize, comptime PoolFn: fn (type) type, comptime bug_: Bug) type
...
if (Tree.bug != .merge_leaks_node) tree.pool.destroy(gpa, emptied);   // base_delete.zig
```

`Tree.bug` is known at compile time, so the correct tree `BTreeWith(M, P, .none)` contains
no test for it at all.

**Minimisation** (`minimize.zig`). Cut the sequence after the failing step. Then try to
delete chunks: half the sequence, then quarters, down to single steps. That is fast but
leaves pairs of steps that can only go together (a put and the delete that undoes it).
So a second phase tries every contiguous block of steps, longest first, and starts over
after each success. A deletion is kept only if the shorter sequence still fails with the
same kind of failure. The guarantee: no contiguous block of steps, of any length, can be
removed from the result. Three cosmetic passes follow: drop injected faults, rename keys to 1, 2, 3, ...
in order, make the n-th put write the value n.

**Fault injection** (`fault_alloc.zig`). See "Allocator notes".

**When the tree crashes instead.** Many real bugs trip an assert, an index check or a
null unwrap inside `put` or `delete`. The process stops before `validate` runs, `hunt`
never returns, and the panic message does not know the seed. For this the harness has a
trace mode that prints one line to stderr before every step:

```
zig build test -Dtrace=true -Dtest-filter="correct tree passes" 2> trace.txt
cargo test --features trace correct_tree_passes 2> trace.txt

trace: seed 1, M=3, bug none, step 209 of 294: put 11240984669916758016 = 10737218468902139262
thread 17799 panic: index out of bounds: index 4, len 4
```

(A real run, with `max_height` lowered to 4 in a scratch copy.) The last `trace:` line
before the panic names seed, order and step. To work on it, replay that one seed in a
test of its own: `hunt(Tree(3, .none), gpa, 1, 1, .{}, null)`. Use a test filter: the
whole suite prints over a million trace lines. A crash cannot be minimised this way: in
Zig a panic ends the process and the minimiser with it (for Rust, see exercise 5).

### Rust

Structure, names, tests and output match. The differences:

- **The bug is a field, not a type parameter.** The Rust tree already keeps its order as a
  run-time field (stable Rust cannot size an array from a const generic expression), so
  `BTree::with_bug(order, Bug::MergeLeaksNode)` stores an enum and the seams test it at
  run time. `replay` takes a `Subject { order, bug }` instead of a type. A zero-cost
  version would be `BTree<F: Fault>` with an associated constant.
- **Errors carry data.** `validate` returns `Result<(), Violation>` where `Violation`
  holds the `ValidateError`, the depth and the node's first key. No out-parameter.
- **The slab counts its own slots.** `BTree::validate` compares the reachable nodes with
  `usage.live()` and with `Slab::live_slots()` (all slots minus the free list); see
  "Allocator notes" for why.
- **No arena, no `deinit`.** Dropping the slab drops every node, reachable or not, so a
  corrupt tree is torn down safely by construction.
- **Allocation failure** is the slab's `fail_after` switch from chapter 04, not an
  allocator. Counting is done by a `#[global_allocator]` (`alloc_count.rs`).

### What `run` prints

Both programs print the same 86 lines (`expected_output.txt`). The parts that matter:

```
== 2. Swarm sweep of the correct tree: seeds 1..150 at each order ==
M=3: 150 cases, 40965 steps, 337 injected allocation failures, max height 6, coverage 21/21: ok
M=4: 150 cases, 40965 steps, 203 injected allocation failures, max height 5, coverage 21/21: ok
M=5: 150 cases, 40965 steps, 176 injected allocation failures, max height 4, coverage 21/21: ok
M=6: 150 cases, 40965 steps, 114 injected allocation failures, max height 4, coverage 21/21: ok
...
the same seeds at M=32: 40965 steps, max height 2, coverage 16/21, never reached: split_interior, root_split_interior, borrow_left_interior, borrow_right_interior, merge_interior

== 3. A fixed mix against the swarm (M = 4, seeds 1..150) ==
fixed mix: 38400 steps, max height 4, coverage 18/21, never reached: put_oom, put_oom_rollback, root_shrink
swarm    : 40965 steps, max height 5, coverage 21/21
```

The fixed mix has no faults, so the two out-of-memory points are unreachable by
construction; `root_shrink` is the one it could have reached and did not in 38400 steps.

```
== 4. Three broken trees (M = 4, swarm seeds 1..200) ==
bug split_wrong_value
  caught by 191 of 200 seeds; shortest failing run: seed 72, step 5 of 512
  wrong result (answer differs from the oracle)
  with validate alone: not caught
  minimised to 5 steps in 25 replays:
    put 6 = 1
    put 1 = 2
    put 2 = 3
    put 4 = 4
    range [3, 5)
    -> wrong result (answer differs from the oracle)
bug merge_leaks_node
  caught by 154 of 200 seeds; shortest failing run: seed 68, step 9 of 512
  invariant NodeCountMismatch
  with the oracle comparison alone: not caught
  minimised to 6 steps in 38 replays:
    ...
bug borrow_forgets_child
  caught by 74 of 200 seeds; shortest failing run: seed 28, step 52 of 256
  invariant MissingChild at depth 1 (node starts with key 7782220156096217088)
  with the oracle comparison alone: not tried (the tree is malformed)
  minimised to 11 steps in 117 replays:
    ...
```

| Variant | One-line change | Caught by |
|---|---|---|
| `split_wrong_value` | a split sends the median key up with its left neighbour's value | oracle comparison only; the shape is legal |
| `merge_leaks_node` | a merge does not return the emptied node | `validate` only (pool accounting); all answers are right |
| `borrow_forgets_child` | an interior borrow moves the key, not the child | `validate`: `MissingChild`; needs height 3, so 74 seeds instead of 154 |

The two families of checks are not redundant: each sees a bug the other cannot.

Seed 28 uses the "spread" layout: 7782220156096217088 is 27 * 2^58. The minimised
reproducer says key 7, because renaming keys in order is part of making it readable.

## In real databases

**TigerBeetle** tests its data structures with exactly this pattern. For its segmented
array (`research/tigerbeetle.md`, section 10.1): a seeded PRNG is the only source of
randomness and the seed is logged (`tigerbeetle/src/fuzz_tests.zig:145`); the reference
model is a flat `std.ArrayList`; after every operation a `verify` function compares length,
forward and reverse iteration and structural invariants
(`tigerbeetle/src/lsm/segmented_array.zig:1295-1370`). The configurations are deliberately
tiny: for `u32` elements, node sizes of 8 to 64 bytes, which is 2 to 16 elements per node
(`tigerbeetle/src/lsm/segmented_array.zig:1466-1480`). And the driver ends with coverage
asserts, `assert(tested_padding); assert(tested_node_capacity_min);`
(`tigerbeetle/src/lsm/segmented_array.zig:1508-1509`), which is where this chapter's
"every point was hit" test comes from.

Its LSM tree fuzzer generates all operations first and replays them, and uses swarm
weights: each of compact, remove, get and scan gets weight zero with probability one half
(`tigerbeetle/src/lsm/tree_fuzz.zig:826-837`). The comment on its model is worth quoting:
"The ideal model would have been an in-memory B-tree, but there isn't one in Zig's
standard library" (`tigerbeetle/src/lsm/tree_fuzz.zig:681-683`). There is also a `canary`
fuzzer that fails on purpose to test the fuzzing infrastructure
(`tigerbeetle/src/fuzz_tests.zig:52-53`); the three broken trees here play that role.

One level up, TigerBeetle runs the whole cluster on one thread with clock, network and
disk replaced by seeded simulations (the VOPR, `tigerbeetle/docs/internals/vopr.md`):
"Assertions are a force multiplier when used with simulation testing and fuzzing"
(`vopr.md:56`). Its style guide adds the necessary caution: "a fuzzer can prove only the
presence of bugs, not their absence" (`tigerbeetle/docs/TIGER_STYLE.md:143-144`).
Deterministic simulation of disks and crashes returns in the on-disk chapters.

**Turso** has the checker as a user-visible feature. `PRAGMA integrity_check`
(`turso/core/storage/btree.rs:8405`, notes in `research/turso.md` section 16) walks every
tree and reports, among others, `CellRowidOutOfRange` (a key outside the parent's divider,
this chapter's `KeyOutsideParentBounds`; `btree.rs:8671`), `LeafDepthMismatch`
(`btree.rs:8689`) and `PageReferencedMultipleTimes` / `PageNeverUsed`, the on-disk
relative of `NodeCountMismatch` (`btree.rs:8226`). Its unit tests fuzz inserts and deletes
against a model and run a `validate_btree` helper (`btree.rs:11560`), there is a module of
allocation-failure tests inside the B-tree code (`btree.rs:11026`), and its simulator has
a property "PRAGMA integrity_check should return ok"
(`turso/testing/simulator/generation/property.rs:1903-1908`).

Textbook, not from these sources: delta debugging (Zeller and Hildebrandt's `ddmin`) and
the term "swarm testing" (Groce et al.). The minimiser here is a simplified chunk-removal
variant of `ddmin`, followed by an exhaustive pass over contiguous blocks.

## Allocator notes

**The wrapper** (`fault_alloc.zig`). `std.mem.Allocator` is a context pointer plus a table
of four functions: `alloc`, `resize`, `remap`, `free`. `FaultAllocator` stores a child
allocator, does its bookkeeping in each of the four and forwards. It counts attempts,
allocations, frees and live / peak / total bytes, and `failNth(n)` makes the n-th attempt
from now return null once. Only `alloc` counts as an attempt: `resize` and `remap` are
never failed. That suits this tree, which only creates and destroys whole nodes, but an
`ArrayList` grows mostly through those two, out of `failNth`'s reach
(`std.testing.FailingAllocator` has `resize_fail_index` for that). The wrapper is a plain struct on the caller's stack;
`allocator()` returns an interface pointing at it, so it must outlive every use and must
not be moved.

**Compared with the standard library.** `std.testing.FailingAllocator` is armed once, at
`init`, with an absolute index, and from that index on every allocation fails (the test
"FailingAllocator stays failed" shows it). `std.testing.checkAllAllocationFailures` builds
on that: it runs a function once to count allocations, then once per index, and checks
that the function returns `OutOfMemory` and leaks nothing. That is the right first test
(`tests.zig` runs it on twelve puts). It cannot check that the tree is unchanged and
usable afterwards, because the allocator stays dead. The hand-written wrapper fails one
attempt and recovers, so `faultSweep` can fail every allocation of every put in turn on
one tree: 40 puts, 22 nodes created, 22 injected failures, 12 already reserved nodes
handed back, tree identical after each. (`put` reserves one node for each node in the
unbroken run of full nodes from the leaf upward, plus one if that run reaches the root.)

**Which allocator where.** Inside `replay` the nodes come from an `ArenaAllocator`,
wrapped in the `FaultAllocator`. A tree that has just failed validation may have lost
track of nodes, and no walk can find those; the arena frees everything at once. The cost
is that `std.testing.allocator` can no longer see a leaked node, because the arena returns
its memory whatever the tree did. That is what the wrapper's counter is for: it sits
between the tree and the arena, and `liveAllocations() != 0` after `deinit` is reported as
a leak. The harness itself (steps, oracle) uses `std.testing.allocator` directly, so its
own leaks fail the tests. The unit tests of fault injection use `std.testing.allocator`
under the wrapper with `DirectNodes`: one allocation per node, so every node is visible.
With `FreeListPool` an injected fault only bites when a new chunk of 32 nodes is needed.

**Rust.** Collections ask one process-wide allocator, so the only place to count is a
`#[global_allocator]`. `GlobalAlloc` is an `unsafe trait`, which makes `alloc_count.rs`
the guide's one declared exception to safe code in Part I: three one-line forwards to
`System`, each with a `SAFETY` comment; `Cargo.toml` lowers `unsafe_code` from `forbid` to
`deny` and only that file opts out. The counters are thread-local, because `cargo test`
runs tests on several threads. `replay` uses them as its leak check, which sees heap
memory that outlives the tree (`mem::forget`, a reference cycle). It cannot see a lost
NODE: every node is a slot in the slab's `Vec`, and dropping the tree frees that `Vec`
whole. A failed `put` that keeps one reserved slot is caught by `validate` instead,
through `Slab::live_slots()`, the slab's own count, which a rollback cannot hide by
restoring `usage`. (In Zig the `FaultAllocator` under the tree reports the same bug as a
leak.) The wrapper does not inject failures: `Vec::push` aborts the process
when the allocator returns null.

## Pitfalls

- **A fuzzer without coverage asserts.** At M = 32 the sweep is green and has tested
  nothing about interior nodes (16 of 21 points).
- **Only one family of checks.** `validate` alone misses wrong values; the oracle alone
  misses leaks, and on a malformed tree it would crash before it could compare anything.
- **Acting on a tree that failed validation.** Stop at the first failure. In Zig, do not
  rely on a walk to free it.
- **Acting on random numbers immediately.** If operations are not data, they cannot be
  minimised, logged or replayed in the other language.
- **A minimiser that accepts any failure.** Deleting steps can turn failure A into an
  unrelated failure B. Compare the kind.
- **Expecting the shortest reproducer.** "No contiguous block can be removed" is not
  "shortest": steps that are not neighbours are never removed together, and a shorter
  reproducer need not be a subsequence at all (exercise 3).
- **Only small keys.** With keys 0 to 255, a tree that compares the low 32 bits of a key
  passes everything. Random values do not help; the keys must cover the type's range.
- **A crash is a failure too.** An assert inside the tree ends the run before any check,
  without seed or step. Trace it, or log the seed before each case as TigerBeetle does.
- **A seed without a version.** Seed 28 means nothing after the generator changes.
  TigerBeetle reproduces from seed plus git commit.
- **Zig error traces under fault injection.** Every injected `OutOfMemory` is recorded in
  the error return trace; a failing test later prints thousands of unrelated frames.
- **Believing it.** A fuzzer shows the presence of bugs. 150 seeds per order is a smoke
  test; real projects run such fuzzers continuously.

## Exercises

1. (easy) Replay the `merge_leaks_node` reproducer on paper with M = 4 and say which node
   is leaked and why no `get` can reveal it.
2. (easy) At M = 32, how many distinct keys must a test use before a third level is
   certain, and how few could produce one?
3. (medium) `hunt` returns the first failing seed, `huntShortest` the one with the fewest
   steps. Starting from the first failing seed for `merge_leaks_node`, how long is the
   minimised reproducer, and why is it longer than six steps?
4. (medium) The fixed mix never reaches `root_shrink`. Explain why from its configuration,
   and name the swarm dimension that fixes it.
5. (hard, open) Add a fourth broken variant of your own (for example: root shrink does not
   free the old root) and predict which check catches it before you run it. Rust only:
   make `replay` report a panic inside the tree as a failure with its step.

Solutions: [solutions.md](solutions.md).

## Links

- Previous: [Chapter 05: Deletion and rebalancing](../05-deletion-and-rebalancing/README.md)
- Next: [Chapter 07: B+trees](../07-bplus-trees/README.md)
- Visualization: [fuzzer replay](viz/index.html) (pick a broken tree, step to the first
  divergence, minimise)
- Run it: `cd zig && zig build test --summary all && zig build run`;
  `cd rust && cargo test && cargo run`

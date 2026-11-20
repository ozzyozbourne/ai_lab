# Chapter 06: Testing a B-tree

## What you will learn

Chapter 05 finished a complete in-memory B-tree. This chapter adds no feature to it. It
builds the tools that let you believe the tree is correct, for every structure to come:

- the invariants as code, with one error value per broken promise and the place it broke;
- a model-based fuzzer: one seed produces operations that go to the tree and to a
  trivially correct oracle, and every answer is compared;
- why tests use tiny nodes, and swarm testing (each seed draws its own configuration);
- coverage counters, asserted, so a green run proves it reached the hard branches;
- three deliberately broken trees, and which check catches each one;
- minimisation: shrinking a failing run of hundreds of steps to a handful;
- fault injection: a hand-written allocator wrapper that counts and fails on demand;
- what all of this still cannot catch.

Prerequisites: chapters 03 to 05 (the tree itself). In Zig, the allocator interface of
chapter 04; in Rust, the slab and its node budget.

## The idea in plain words

A unit test checks the cases you thought of. A B-tree fails in the cases you did not
think of: a borrow between two interior nodes at the right edge, a split while the parent
is full, a failed allocation half-way through a reservation.

So do not write the cases. Write three small things instead.

1. A checker (`validate`) that walks the whole tree and says whether every structural
   promise holds. It knows nothing about how the tree got there.
2. A model: the dumbest structure with the same behaviour. Here a sorted array (the
   `Oracle` from `common/`). It is slow and obviously right.
3. A generator: from one 64-bit seed, a sequence of `put`, `delete`, `get`, `range`.

Then run the same operations on both, compare every answer, and call the checker after
every step. Do that for many seeds. When something disagrees, you have a seed and a step
number, and the run can be repeated exactly.

Four refinements turn this from a toy into something that finds real bugs:

- **Tiny nodes.** With 4 children per node every few inserts split and every few deletes
  merge. With 32 the same test never touches an interior node.
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

The tree is copied from chapter 05 as `base_*` files, with coverage points instead of
counters, a diagnostic in `validate`, and three fault seams marked `SEAM`. Four more
seams exist only for the tests: two break the rollback of a failed `put`, two (Zig only)
read a node after freeing it. Chapter 05's unit tests of insert and delete are left out:
here the fuzzer is their test.

### Zig

**Invariants as code** (`base_validate.zig`). Each promise has its own error:
`KeysOutOfOrder`, `KeyOutsideParentBounds`, `NodeOverfull`, `NodeUnderfull`, `EmptyRoot`,
`LeavesAtDifferentDepths`, `MissingChild`, `UnexpectedChild`, `WrongKeyCount`,
`NodeCountMismatch`. A Zig error is a bare tag and cannot carry data, so the place of the
violation (depth, first key of the node) travels through an out-parameter, `*Diagnostic`.
A node's own checks all run before the walk descends, so the error names the wrong node
closest to the root.

`validate` also asserts chapter 03's height bound, `height <= maxHeight(M, keys)`, which
follows from the other invariants. `put` keeps its path in an array of `max_height = 64`
entries, and no test can build a tree that tall (the fuzzer reaches 6 levels), so the
constant is tied to the same function: with a smaller one `put` does not compile.

**Coverage** (`coverage.zig`). An enum of 21 points and an array of counters:

```zig
tree.coverage.hit(if (left.leaf) .split_leaf else .split_interior); // base_insert.zig
try testing.expectEqual(null, totals.coverage.firstMissing());      // tests.zig, after the sweep
```

For your own structure: one point per branch you would be embarrassed never to have
run, split wherever two levels do different work (an interior split also moves children).

**The fuzzer** (`fuzz.zig`).

- `swarm(seed) Case` draws the configuration: 4, 16, 64 or 256 possible keys; 64 to 512
  operations; weights for put, delete, get, range (any of the last three may be zero);
  which puts get injected allocation failures (none, one in 8, one in 2, all); whether
  the run ends by deleting every remaining key; and where the keys lie (`KeyLayout`):
  from 0, around 2^32, spread over all of `u64`, or just below 2^64. The layout changes
  the numbers compared, not the tree's shape. The largest key used is `maxInt(u64) - 1`,
  because a half-open `range` cannot contain `maxInt`.
- `generate(gpa, case) []Step` produces the whole sequence up front. A `Step` is an `Op`
  plus a `fault` flag. The stream only asks for ranges `[lo, hi)` with `lo < hi` between
  two keys of the case, so 5 ranges in 16 are reshaped: inverted, empty, from 0, up to
  `maxInt`, or both.
- `replay(Tree, gpa, steps, checks, totals) ?Failure` applies each step to a fresh tree
  and a fresh oracle and stops at the first failed check. Condensed:

  ```zig
  for (steps, 0..) |step, i| {
      const answer_ok = switch (step.op) { // 1. the same operation goes to both
          .put => |p| try tree.put(gpa, p.key, p.value) == try oracle.put(gpa, p.key, p.value),
          .delete => |d| tree.delete(gpa, d.key) == oracle.delete(d.key),
          .get => |g| tree.get(g.key) == oracle.get(g.key),
          .range => |r| sameEntries(&tree, oracle.range(r.lo, r.hi)),
      };
      if (!answer_ok) return fail(i, .wrong_result);
      tree.validate(&diag) catch |err| return fail(i, .{ .invariant = err }); // 2.
      if (tree.len != oracle.len()) return fail(i, .wrong_contents); // 3.
      if (sweep and !sameEntries(&tree, oracle.range(0, max))) return fail(i, .wrong_contents);
  }
  ```

  `sweep` is true every 16 steps and at the end. A put with `fault` set is first tried
  with its node allocation 0 failing, then with allocation 1 failing, and so on until it
  gets through. After each failure the tree must validate and have the same contents and
  the same `pool.usage` as before. So every node of a reservation fails once, down to
  the last one of the deepest.
- `hunt` runs one swarm case per seed and stops at the first failure. A case that passes
  is replayed once more to look for a use after free ("Which allocator where").
  `huntShortest` runs all seeds and keeps the failure with the fewest steps.

`replay` takes the tree type as a `comptime` parameter, and the bug is part of the type:
`if (Tree.bug != .merge_leaks_node) tree.pool.destroy(gpa, emptied);`. The correct tree
`BTreeWith(M, P, .none)` contains no test for it at all.

**Minimisation** (`minimize.zig`). Cut the sequence after the failing step. Then try to
delete chunks: half the sequence, then quarters, down to single steps. That is fast but
leaves pairs of steps that can only go together (a put and the delete that undoes it).
So a second phase tries every contiguous block, longest first, and starts over after
each success. A deletion is kept only if the shorter sequence still fails in the same
way. The guarantee: no contiguous block can be removed from the result. Then faults are
dropped, keys renamed 1, 2, 3, ... and the n-th put writes n.

**When the tree crashes instead.** Many real bugs trip an assert or an index check inside
the tree. The process stops before `validate` runs, and the panic message does not know
the seed. Trace mode prints one line to stderr before every step:

```
zig build test -Dtrace=true -Dtest-filter="correct tree passes" 2> trace.txt
cargo test --features trace correct_tree_passes 2> trace.txt

trace: seed 1, M=3, bug none, step 11 of 294: put 13835058055282163712 = 15660989352789793366 (each node allocation fails once first)
General protection exception (no address available)
```

(A real run of a scratch copy without the line of `put` that reserves a node for a new
root; Rust panics with `reserved` at the same step.) The last `trace:` line names the
case. In Rust the panic message is in the test report on stdout, not in `trace.txt`. To
work on the crash, replay that seed in a test of its own:

```
_ = try fuzz.hunt(Tree(3, .none), testing.allocator, 1, 1, .{}, null);   // tests.zig
fuzz::hunt(Subject::correct(3), 1, 1, checks(), None);                   // tests.rs
```

Use a test filter: the suite prints over a million lines. A crash cannot be minimised:
in Zig a panic ends the process (for Rust, see exercise 5).

### Rust

Structure, names, tests and output match. The differences:

- **The bug is a field, not a type parameter.** The Rust tree already keeps its order as a
  run-time field, so `BTree::with_bug(order, Bug::MergeLeaksNode)` stores an enum and the
  seams test it at run time. `replay` takes a `Subject { order, bug }`.
- **Errors carry data.** `validate` returns `Result<(), Violation>`: the error, the depth
  and the node's first key. `MAX_HEIGHT` is checked by a `const` assertion.
- **The slab counts its own slots.** `BTree::validate` compares the reachable nodes with
  `usage.live()` and with `Slab::live_slots()`; see "Allocator notes".
- **No arena, no `deinit`, no poison.** Dropping the slab drops every node. A freed slot
  is marked and any later access panics (`use of freed NodeId`): a use after free is a
  crash, never a quiet wrong read.
- **Allocation failure** is the slab's `fail_after` switch from chapter 04. Counting is
  done by a `#[global_allocator]` (`alloc_count.rs`).

### What `run` prints

Both programs print the same 86 lines (`expected_output.txt`). The parts that matter:

```
M=3: 150 cases, 40965 steps, 2321 injected allocation failures (deepest rollback 5 nodes), max height 6, coverage 21/21: ok
...
the same seeds at M=32: 40965 steps, max height 2, coverage 16/21, never reached: split_interior, root_split_interior, borrow_left_interior, borrow_right_interior, merge_interior
...
fixed mix: 38400 steps, max height 4, coverage 18/21, never reached: put_oom, put_oom_rollback, root_shrink
swarm    : 40965 steps, max height 5, coverage 21/21
```

The fixed mix has no faults, so `root_shrink` is the point it could have reached and
did not.

```
bug split_wrong_value
  caught by 191 of 200 seeds; shortest failing run: seed 20, step 6 of 67
  wrong result (answer differs from the oracle)
  with validate alone: not caught
  minimised to 5 steps in 25 replays:
  ...
```

| Variant | One-line change | Caught by |
|---|---|---|
| `split_wrong_value` | a split sends the median key up with its left neighbour's value | oracle only; the shape is legal |
| `merge_leaks_node` | a merge does not return the emptied node | `validate` only (`NodeCountMismatch`), 154 seeds; all answers are right |
| `borrow_forgets_child` | an interior borrow moves the key, not the child | `validate`: `MissingChild`; needs height 3, so only 71 seeds |

The two families of checks are not redundant: each sees a bug the other cannot.

## In real databases

**TigerBeetle** tests its data structures with exactly this pattern. For its segmented
array (`research/tigerbeetle.md`, section 10.1): a seeded PRNG is the only source of
randomness and the seed is logged (`tigerbeetle/src/fuzz_tests.zig:145`); the reference
model is a flat `std.ArrayList`; after every operation a `verify` function compares
length, iteration and structural invariants
(`tigerbeetle/src/lsm/segmented_array.zig:1295-1370`). The configurations are tiny: 2 to
16 elements per node (`segmented_array.zig:1466-1480`). And the driver ends with coverage
asserts, `assert(tested_padding); assert(tested_node_capacity_min);`
(`segmented_array.zig:1508-1509`), which is where this chapter's "every point was hit"
test comes from.

Its LSM tree fuzzer generates all operations first and replays them, and uses swarm
weights: each of compact, remove, get and scan gets weight zero with probability one half
(`tigerbeetle/src/lsm/tree_fuzz.zig:826-837`). There is also a `canary` fuzzer that fails
on purpose to test the fuzzing infrastructure (`tigerbeetle/src/fuzz_tests.zig:52-53`);
the three broken trees here play that role.

Its style guide adds a caution: "a fuzzer can prove only the presence of bugs, not
their absence" (`tigerbeetle/docs/TIGER_STYLE.md:143-144`).

**Turso** has the checker as a user-visible feature. `PRAGMA integrity_check`
(`turso/core/storage/btree.rs:8405`, notes in `research/turso.md` section 16) walks every
tree and reports, among others, `CellRowidOutOfRange` (this chapter's
`KeyOutsideParentBounds`; `btree.rs:8671`), `LeafDepthMismatch` (`btree.rs:8689`) and
`PageReferencedMultipleTimes` / `PageNeverUsed`, the on-disk relative of
`NodeCountMismatch` (`btree.rs:8226`). Its unit tests fuzz inserts and deletes against a
model and run a `validate_btree` helper (`btree.rs:11560`), next to allocation-failure
tests (`btree.rs:11026`).

Textbook, not from these sources: delta debugging (Zeller and Hildebrandt's `ddmin`, of
which the minimiser here is a simplified variant) and the term "swarm testing" (Groce et
al.).

## Allocator notes

**The wrapper** (`fault_alloc.zig`). `std.mem.Allocator` is a context pointer plus a table
of four functions: `alloc`, `resize`, `remap`, `free`. `FaultAllocator` stores a child
allocator, does its bookkeeping in each of the four and forwards. It counts attempts,
allocations, frees and bytes, and `failNth(n)` makes the n-th attempt from now return
null once. Only `alloc` counts as an attempt. That suits this tree, which only creates
and destroys whole nodes; an `ArrayList` grows mostly through `resize` and `remap`
(`std.testing.FailingAllocator` has `resize_fail_index` for that). With
`quarantine = byte`, `free` fills the block with that byte and keeps it instead of
passing it on.

**Compared with the standard library.** `std.testing.FailingAllocator` is armed once, at
`init`, and from its index on every allocation fails.
`std.testing.checkAllAllocationFailures` runs a function once per allocation index and
checks that it returns `OutOfMemory` and leaks nothing: the right first test (`tests.zig`
runs it on twelve puts). It cannot check that the tree is unchanged and usable
afterwards, because the allocator stays dead. The hand-written wrapper fails one attempt
and recovers, so `faultSweep` fails every allocation of every put in turn on one tree: 40
puts, 22 nodes created, 22 injected failures, 12 reserved nodes handed back, tree
identical after each.

**Which allocator where.** Inside `replay` the nodes come from an `ArenaAllocator` under
the `FaultAllocator`. A tree that has just failed validation may have lost nodes that no
walk can find; the arena frees everything at once. But an arena hides two kinds of bug,
and the wrapper has to bring both back.

A leak: the arena returns its memory whatever the tree did. So the wrapper counts:
`liveAllocations() != 0` after `deinit` is a leak.

A use after free: `destroy` does not touch the bytes and the arena keeps them mapped, so
a freed node reads exactly as it did while alive. A tree that frees the old root and then
reads its child from it passes every check. `std.testing.allocator` is no cure: in a
Debug build it overwrites a freed small allocation with `0x55` and does not reuse the
slot, which finds writes after free; a read gets garbage that nothing reports. So
`replay` sets the quarantine to `0x00`. A freed node then looks like an interior node
without keys or children: reached again, it fails `validate` (`EmptyRoot`,
`NodeUnderfull`, `MissingChild`) or the tree loses its keys (`WrongKeyCount`).

One read survives that: a single flag of a freed node that changes nothing in the
tree. So `hunt` replays every passing case once more with `0x01` in freed nodes, where
`leaf` reads true instead of false. A tree that never looks at a freed node cannot tell
the two runs apart: both must pass and hit every coverage point equally often. If not,
the failure is `read_after_free`, and bisection over prefixes of the steps finds the
step: for the test seam, seed 1, step 142 at M = 3, where the Rust slab panics for the
same bug.

The harness itself uses `std.testing.allocator`, so its own leaks fail the tests. With
`FreeListPool` a fault only bites when a new chunk of 32 nodes is needed, and a freed
node stays inside its chunk, out of the quarantine's reach.

**Rust.** Collections ask one process-wide allocator, so the only place to count is a
`#[global_allocator]`. `GlobalAlloc` is an `unsafe trait`, which makes `alloc_count.rs`
the guide's one declared exception to safe code in Part I: three one-line forwards to
`System`; `Cargo.toml` lowers `unsafe_code` from `forbid` to `deny` and only that file
opts out. The counters are thread-local, because tests run on several threads. `replay`
uses them as its leak check. It cannot see a lost NODE: every node is a slot in the
slab's `Vec`, and dropping the tree frees that `Vec`. A failed `put` that keeps a
reserved slot is caught by `validate`, through `Slab::live_slots()`, which a rollback
cannot hide by restoring `usage`.

## Pitfalls

- **A fuzzer without coverage asserts.** At M = 32 the sweep is green and has tested
  nothing about interior nodes (16 of 21 points).
- **Only one family of checks.** `validate` alone misses wrong values; the oracle alone
  misses leaks, and on a malformed tree it crashes before it can compare anything.
- **Polite inputs.** Keys 0 to 255 hide a comparison of the low 32 bits. Ranges with
  `lo < hi` hide a scan that stops on `key > hi - 1`. Faults in the first three
  allocations hide a rollback that forgets its third node.
- **Acting on random numbers immediately.** If operations are not data, they cannot be
  minimised, logged or replayed in the other language.
- **A minimiser that accepts any failure.** Deleting steps can turn failure A into an
  unrelated failure B. Compare the kind. Do not expect the shortest reproducer either
  (exercise 3).
- **A seed without a version.** Seed 28 means nothing after the generator changes.
- **Zig error traces under fault injection.** Every injected `OutOfMemory` lands in the
  error return trace; a failing test later prints thousands of unrelated frames.

### What this toolkit cannot catch

Change one line of the tree or the pool and see whether anything complains (mutation
testing; do it to your own tests). These kinds of bug still got past the fuzzer:

- **A crash.** An assert, a bounds or overflow check, a null child: the process stops
  before a check can report. Only the trace names seed and step, and in Zig nothing is
  minimised. In Rust every use of a freed node ends this way.
- **State that no check compares.** `usage.peak` not updated, a freed slot that is never
  handed out again: the tree answers and validates as before. Only the pool's unit tests
  see these.
- **A write to a freed node.** The quarantine exposes reads; nobody checks afterwards
  that the poison is intact.
- **Nodes inside `FreeListPool`.** The sweep runs on `DirectNodes`. In the pool (one
  test, 40 seeds) a freed node is not poisoned, and a slot lost by a failed `put` is
  invisible to the allocator's counter.
- **Inputs never generated.** The key `maxInt(u64)` (the harness's own full scan is
  `range(0, maxInt)`); a tree taller than 6 levels (`max_height` is checked by formula,
  never run).
- **Other builds.** Everything runs in Debug. ReleaseFast removes the asserts and
  overflow checks that turn several of these bugs into crashes.
- **Everything else.** 150 seeds per order is a smoke test; real projects run such
  fuzzers continuously.

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
5. (hard, open) Add a fourth broken variant (for example: root shrink does not free the
   old root) and predict which check catches it. Rust only: make `replay` report a panic
   inside the tree as a failure with its step.

Solutions: [solutions.md](solutions.md).

## Links

- Previous: [Chapter 05: Deletion and rebalancing](../05-deletion-and-rebalancing/README.md)
- Next: [Chapter 07: B+trees](../07-bplus-trees/README.md)
- Visualization: [fuzzer replay](viz/index.html)
- Run it: `cd zig && zig build test --summary all && zig build run`;
  `cd rust && cargo test && cargo run`

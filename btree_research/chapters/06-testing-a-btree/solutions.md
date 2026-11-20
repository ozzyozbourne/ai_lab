# Chapter 06: solutions

Numbers below come from the chapter's programs and tests unless a line says otherwise.

## 1. The leak, by hand

Reproducer (part 4 of `expected_output.txt`), M = 4:

```
put 4 = 1, put 2 = 2, put 3 = 3     one leaf [2 3 4]                       pool 1, reachable 1
put 1 = 4                           4 keys: split at the median 3
                                    [3] over [1 2] and [4]                 pool 3, reachable 3
delete 2                            [3] over [1] and [4]                   pool 3, reachable 3
delete 4                            the right leaf is empty; the left one
                                    has 1 key (the minimum) and cannot
                                    lend, so merge: [1] + 3 + [] = [1 3].
                                    The root has no key left and is
                                    replaced by its only child.            pool 2, reachable 1
```

The leaked node is the emptied RIGHT leaf (the one that held 4). The merge copies nothing
out of it that matters (it is empty) and unlinks it from the parent, so no path from the
root leads to it. `get`, `range` and an in-order scan only follow paths from the root, so
they cannot see it. The root shrink frees the old root correctly, which is why the pool
says 2 and not 3. The pool/reachable counts were checked with the visualization's model,
which is verified against the program output.

## 2. How many keys for three levels at M = 32

Derived by arithmetic, not run. A node holds at most 31 keys and, except the root, at
least 15.

- Certain: a tree of height 2 holds at most 31 + 32 * 31 = 1023 keys. With 1024 keys
  present the tree must have a third level.
- Possible: the sparsest tree of height 3 has a root with 1 key, 2 interior nodes with 15
  keys each, and 32 leaves with 15 keys each: 1 + 30 + 480 = 511 keys. Fewer than 511
  keys can never form three levels.

The swarm's largest key space is 256, below 511, which is why the sweep at M = 32 reports
`max height 2` and never reaches the five interior points. Raising the key space is the
expensive fix; lowering M is the cheap one.

## 3. First failing seed against shortest failing run

The first failing seed for `merge_leaks_node` at M = 4 is seed 1, failing at step 76 of
294. Minimising from there gives 12 steps in 60 replays (measured with the JavaScript port
in `viz/local.js`, which reproduces the programs' part 4 exactly):

```
put 11, put 5, put 4, put 3, put 9, put 10, put 7, put 6, put 1, put 8, put 2, delete 9
```

Starting from seed 68 (step 9 of 512) the same minimiser reaches 6 steps.

Why 12 and not 6: chunk removal only ever deletes steps. The 12-step survivor contains a
single delete, and with one delete a merge only happens in a tree where the victim leaf
and its neighbours are all at the minimum; that needs those eleven puts, and removing any
one of them changes the shape so that the delete borrows instead of merging. The 6-step
reproducer uses TWO deletes and four puts. It is not a subsequence of the 12 steps, so no
amount of deleting gets there. "1-minimal" promises that no single step can be removed;
it does not promise the shortest sequence. Starting from a short failing run is the cheap
remedy, which is what `huntShortest` is for.

## 4. Why the fixed mix never shrinks the root

The fixed mix is put:delete:get:range = 4:2:3:1 on 64 keys, 256 operations, no drain. Puts
are twice as frequent as deletes, and a delete of an absent key does nothing, so the tree
fills up towards 64 keys and stays there. A root shrink needs merges to propagate all the
way to the root, which needs a tree that is being emptied. Measured: `root_shrink` has 0
hits in 38400 steps of the fixed mix (part 3 of the output).

The explanation of the mechanism is reasoning, not a measurement. What is measured is the
effect of the swarm: 21 of 21 points, with `root_shrink` hit 1394 times across the four
orders. Two swarm dimensions make the tree shrink: the `drain` flag (delete every
remaining key at the end) and seeds whose delete weight exceeds their put weight.

## 5. A fourth broken variant

Open exercise; nothing below was run. An expectation for "root shrink does not free the
old root": the tree stays well-formed and every answer stays right, exactly like
`merge_leaks_node`, so the oracle comparison should be silent and `validate` should report
`NodeCountMismatch` at the first root shrink. If your run agrees, you have a second bug
that only the pool accounting sees. To add it: a fourth `Bug` tag, one `if (Tree.bug != ...)`
around `tree.pool.destroy(gpa, root)` in `base_delete.zig` (Rust: clone the root instead
of calling `pool.free`), and one more entry in `scenario.bugs`.

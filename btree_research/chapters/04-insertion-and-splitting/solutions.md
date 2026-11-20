# Chapter 04: solutions

Every tree and number below was produced by the chapter's code (the test suites, the
output of `run`, or the JavaScript model of the visualization, which is checked against
that output). Where something was not run, the text says so.

## 1. Keys 1 to 10 in ascending order, M = 4, bottom-up

```
put 1, 2, 3      [1 2 3]
put 4            [1 2 3 4] is overfull; mid = 2, median 3; the root split
                 [3]
                 [1 2] [4]
put 5, 6         [3]
                 [1 2] [4 5 6]
put 7            [4 5 6 7] is overfull; median 6 goes up
                 [3 6]
                 [1 2] [4 5] [7]
put 8, 9         [3 6]
                 [1 2] [4 5] [7 8 9]
put 10           [7 8 9 10] is overfull; median 9 goes up
                 [3 6 9]
                 [1 2] [4 5] [7 8] [10]
```

The puts of 4, 7 and 10 split a node: one split for every three keys once the first
leaf is full. The state after 9 keys is asserted in `base_tests_insert` ("put under
allocation failure leaves the tree unchanged"); the whole sequence was replayed with
the visualization's model. Every
left half stays at `[a b]` forever, because no later key is smaller than the median
that was pushed up.

## 2. Fill for ascending keys at M = 3, 4 and 5

An overfull node has M keys and `mid = M / 2` (integer division). The left half keeps
`mid` keys in a node with M - 1 slots, and with ascending keys it never gets another
one. So nearly every node ends at `mid / (M - 1)`:

| M | overfull | left keeps | slots | fill of a left half | measured (100000 keys) |
|---|----------|-----------|-------|---------------------|------------------------|
| 3 | 3 keys   | 1         | 2     | 1/2 = 50%           | 50.0% |
| 4 | 4 keys   | 2         | 3     | 2/3 = 66.7%         | 66.6% |
| 5 | 5 keys   | 2         | 4     | 2/4 = 50%           | 50.0% |

The same holds one level up: the separators arrive in ascending order too, so interior
nodes are also left behind at `mid` keys. Only the nodes on the right edge of the tree
differ, which is why the measured value for M = 4 is 66.6% and not 66.7%.

Even orders do better than their odd neighbours here because `M / 2` rounds in their
favour: the left half gets the larger share.

## 3. Fewer than N / (ceil(M/2) - 1) splits

Let m = ceil(M/2) - 1 be the minimum number of keys of a non-root node.

- A split turns one node into two; a root split also adds the new root. So
  `nodes = 1 + splits + root_splits` (asserted in `measure`, "split accounting"), and
  in particular `splits <= nodes - 1`.
- The tree has N keys. The root holds at least 1, every other node at least m. So
  `N >= 1 + m * (nodes - 1)`, which gives `nodes - 1 <= (N - 1) / m`.
- Together: `splits <= (N - 1) / m < N / m`.

Compared with the output (N = 100000):

| M | m | bound N / m | splits, ascending | splits, random |
|---|---|-------------|-------------------|----------------|
| 4 | 1 | 100000 | 49991 | 51854 |
| 64 | 31 | 3225 | 3120 | 2277 |

The bound is the case "every node at the minimum". Ascending keys at M = 64 come close
to it (3120 of 3225), because they leave nearly every node at 32 keys, one above the
minimum of 31. Random keys stay well below it because their nodes are about 69% full.

The worst single put is a different matter: the column "most in one put" shows 10 for
M = 4 and at most 3 for M = 64, which is bounded by the height, not by this argument.

## 4. Top-down, ascending keys, M = 4: one third full

Top-down splits a node when it is full, before the new key is in it: 3 keys become
1 + median + 1. Both halves hold exactly one key, the minimum. With ascending keys the
left half never receives another key, so it stays at 1 of 3 slots. The right half
receives keys until it is full again, is split when the next insert passes through it,
and leaves another one-key node behind. Measured: 33.3% fill, 99974 splits for 100000
keys, that is one split per insert, and a tree of height 16 where bottom-up needs 11.

Bottom-up splits one key later, when the node holds 4 keys, and the left half keeps 2.
That single key is the whole difference between 33.3% and 66.6%.

At M = 256 the same effect is one key out of 255: top-down leaves 127 keys on the left
(49.8%), bottom-up 128 (50.2%). Measured: 49.7% against 50.1%, 785 against 779 splits.
The early split costs a fixed number of keys per node, so it matters for tiny nodes and
disappears for the node sizes real engines use. What remains at any size are the other
two objections from the chapter: it needs an even M, and it needs to know what "full"
means before the key arrives.

## 5. Reserving with `MemoryPool.addCapacity`

Not implemented in this chapter; what follows is a design, and its behaviour under
failure is an expectation, not a measurement. The building block itself is tested
(`tests_alloc.zig`, "MemoryPool.addCapacity: reserve first, then create does not
allocate").

The pool interface would get a fifth function, for example

```zig
pub fn reserve(self: *Self, gpa: Allocator, n: usize) Allocator.Error!void
```

`StdPool.reserve` forwards to `self.inner.addCapacity(gpa, n)`. `put` calls
`try tree.pool.reserve(gpa, need)` after the descent and then, in the commit phase,
calls `create` exactly `need` times. Those calls are served from the pool's free list
and should not reach the backing allocator, so they can be treated as infallible
(`catch unreachable`).

What changes:

- The `spare` array and the `errdefer` loop that hands nodes back disappear. If
  `addCapacity` fails after pre-allocating some of the n slots, those slots are already
  on the pool's free list. Nothing has to be undone, and the `usage` counters were never
  touched, so there is nothing to restore either.
- The slots stay in the pool. That is the same trace the current code leaves (a
  returned reservation also ends up on the free list); they are used by the next split
  and freed in `deinit`.
- `DirectNodes` cannot implement `reserve` without becoming a pool: it has nowhere to
  keep a node that is allocated but not yet handed out. It would need a small list of
  spare nodes, which is the `spare` array again, moved from `put` into the pool. That
  is the reason this chapter keeps the reservation in `put`: it works with any pool
  that has `create` and `destroy`.
- The Rust slab would get the same function (push n free slots, or check the budget for
  n nodes at once), and `fail_after` would have to count reserved slots instead of
  calls to `alloc`.

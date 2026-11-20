# Chapter 04: Insertion and splitting

## What you will learn

- How `put` adds a key: always into a leaf, and what happens when the leaf is full.
- The **split**: one overfull node becomes two nodes and one key for the parent.
- Why a B-tree only grows at the root, and why that keeps every leaf at the same depth.
- What an insert costs: at most one split per level, and far fewer on average.
- How full the nodes are after many inserts, measured for ascending and for random keys.
- A second way to insert, **top-down** splitting from the textbook, and why real engines
  do not use it.
- How to make `put` safe against running out of memory: reserve first, then change.

Prerequisites: [chapter 02](../02-searching-a-sorted-node/README.md) (lower bound) and
[chapter 03](../03-btree-structure-and-search/README.md) (node layout, invariants, search,
`validate`). The node type, `get` and `validate` used here are the ones from chapter 03.

Terms: the **order** M is the maximum number of children. A node holds at most M - 1
keys and, unless it is the root, at least ceil(M/2) - 1. All examples use M = 4, so a
node has 1 to 3 keys. A node with M - 1 keys is **full**. A node with M keys is
**overfull**: that state is not allowed to last.

## The idea in plain words

Inserting a key starts like searching for it. Walk from the root to the leaf where the
key would be. If the key is found on the way, overwrite its value and stop (keys are
unique in Part I). Otherwise put the key into the leaf, in sorted position.

A new key never goes into an interior node directly. An interior node with k keys must
have exactly k + 1 children; adding a key there would require a new child out of nowhere.
A leaf has no children, so it can simply take the key.

If the leaf had room, the insert is over. If it was full, it now holds M keys. The repair
is the split:

1. Take the middle key, the **median**.
2. The keys below the median stay in the node.
3. The keys above the median move to a new node, the right sibling.
4. The median moves up into the parent, between the pointers to the two halves.

The parent gained one key and one child, so its key and child counts still match. But
the parent may have been full. Then it is overfull now and splits in the same way, and
its median goes one level higher. This can continue up to the root.

When the root splits there is no parent to take the median. A new root is created that
holds only the median and points to the two halves. This is the only way a B-tree gets
taller. Because the new level appears at the top, every leaf gets one level deeper at
the same moment, and all leaves stay at the same depth. A binary search tree grows
downwards, at the leaves, which is exactly how it becomes unbalanced.

This is **bottom-up** splitting: change the leaf first, repair upwards afterwards.

### What a split leaves behind

An overfull node has M keys. With `mid = M / 2` (integer division), the left half keeps
`mid` keys, the right half gets `M - 1 - mid`, and one key goes up. For M = 4 that is
2 + 1 + 1. Both halves hold at least ceil(M/2) - 1 keys for every M, so a split never
creates an underfull node. It does create two nodes that are about half empty. Whether
they fill up again depends on where later keys arrive, which the measurements below show.

### What an insert costs

One `put` splits at most one node per level, so at most `height` nodes. That worst case
is rare. Every split creates exactly one node (a root split creates two: the right half
and the new root), and every non-root node keeps at least ceil(M/2) - 1 keys. A tree
with N keys therefore has fewer than N / (ceil(M/2) - 1) nodes, and it took fewer than
that many splits to build. Spread over the N inserts, that is less than one split per
ceil(M/2) - 1 inserts. This is the **amortised** split cost: for M = 64 it is at most one
split per 31 inserts, however unlucky a single insert may be.

## A worked example by hand

Insert 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 into an empty tree with M = 4.

`10`, `20`, `5` go into the first leaf, which is also the root:

```
[5 10 20]
```

`6` belongs between 5 and 10. The leaf becomes `[5 6 10 20]`: four keys, overfull.
`mid = 4 / 2 = 2`, so the median is the key at index 2, which is 10. `[5 6]` stays,
`[20]` moves to a new node, and 10 needs a parent. The node was the root, so a new root
is made:

```
[10]
[5 6] [20]
```

`12`, `30` go right of 10, `7` goes left. No leaf overflows:

```
[10]
[5 6 7] [12 20 30]
```

`17` makes the right leaf `[12 17 20 30]`. Median 20 goes up; the root has room:

```
[10 20]
[5 6 7] [12 17] [30]
```

`3` makes the left leaf `[3 5 6 7]`. Median 6 goes up; the root is now full:

```
[6 10 20]
[3 5] [7] [12 17] [30]
```

`25`, `1`, `15` each find a leaf with room:

```
[6 10 20]
[1 3 5] [7] [12 15 17] [25 30]
```

Twelve inserts, three splits, one of them a root split. The next key that overflows a
leaf will also overflow the root, and the tree will get its third level.

## Code walk-through

Layout of both projects:

| File | Content |
|------|---------|
| `base_node`, `base_search`, `base_validate`, `base_stats` | node type, `get`, invariants, shape and text rendering (chapter 03 material) |
| `base_pool` | where nodes come from |
| `base_insert` | `put`, bottom-up |
| `base_btree` | the tree type that ties them together |
| `topdown` | `put`, top-down (textbook) |
| `measure` | fill and split counts after N inserts |
| `scenario` | the output of `run` |

The `base_*` files are copies from chapter 05, which holds the complete tree of Part I;
`delete` was trimmed away. This chapter has no delete.

### Zig: bottom-up `put` (`zig/src/base_insert.zig`)

`put` has three phases. The listing is condensed.

```zig
pub fn put(comptime Tree: type, tree: *Tree, gpa: Allocator, key: u64, value: u64) Allocator.Error!?u64 {
    // Phase 1: descend, remembering the path.
    var path: [max_height]struct { node: *N, index: usize } = undefined;
    while (true) {
        const i = search.lowerBound(node.keySlice(), key);
        if (i < node.len and node.keys[i] == key) { ... overwrite, return old value ... }
        path[depth] = .{ .node = node, .index = i };
        depth += 1;
        if (node.leaf) break;
        node = node.children[i].?;
    }

    // Phase 2: reserve. The split travels up exactly as far as the nodes are full.
    var need: usize = 0;
    while (need < depth and path[depth - 1 - need].node.len == N.max_keys) need += 1;
    if (need == depth) need += 1; // the root splits too: one more node for the new root
    errdefer { for (spare[0..reserved]) |n| tree.pool.destroy(gpa, n); tree.pool.usage = usage_before; }
    while (reserved < need) : (reserved += 1) spare[reserved] = try tree.pool.create(gpa);

    // Phase 3: commit. Nothing below can fail.
    path[level].node.insertEntry(path[level].index, key, value);
    while (path[level].node.len > N.max_keys) {
        const median = splitNode(N, left, right);
        if (level == 0) { ... new root above left and right ...; break; }
        level -= 1;
        parent.insertChild(path[level].index + 1, right);
        parent.insertEntry(path[level].index, median.key, median.value);
    }
}
```

Three decisions are worth noticing.

**The path is an array, not parent pointers.** Nodes do not know their parent. A parent
pointer in every node would have to be updated in every child that moves during a split.
The path costs 64 entries on the stack, enough for any tree of order 3 or more with 2^64
keys (height bound from chapter 03).

**Overflow, then split.** The key arrays have M slots, one more than a node may keep.
The new key is written into the full node first, and `splitNode` then cuts a node of M
keys. The alternative, deciding which half the new key belongs to while splitting,
needs three cases. The extra slot removes them.

**Reserve, then commit.** How many nodes a `put` needs is known after the descent: one
per full node at the bottom of the path, plus one if the chain of full nodes reaches the
root. All of them are taken from the pool before the tree is touched. If the pool cannot
deliver, the `errdefer` hands back what was taken and `put` returns `error.OutOfMemory`
with the tree exactly as it was.

### Zig: top-down `put` (`zig/src/topdown.zig`)

This is the insert of Cormen, Leiserson, Rivest and Stein ("B-TREE-INSERT"), textbook
material. Its rule: never walk into a full node. A full child is split *before* it is
entered, so the node we stand in always has room for a median coming up.

```zig
// Loop invariant: `node` is NOT full, so it can take one more key.
while (true) {
    const i = search.lowerBound(node.keySlice(), key);
    if (node.leaf) { node.insertEntry(i, key, value); return null; }
    var child = node.children[i].?;
    if (child.len == N.max_keys) {
        const right = try tree.pool.create(gpa);
        const median = splitFull(N, child, right);
        node.insertChild(i + 1, right);
        node.insertEntry(i, median.key, median.value);
        if (key > median.key) child = right;
    }
    node = child;
}
```

One pass, no path, no walk back up. The costs:

- **M must be even.** A full node has M - 1 keys. Without the median, M - 2 remain for
  two halves that each need ceil(M/2) - 1. For even M that is exactly (M - 2) / 2 each.
  For odd M each half needs (M - 1) / 2, and M - 2 keys are one too few. The bottom-up
  split has the new key as well, so it works for every M. In Zig an odd order is a
  `@compileError`.
- **It splits nodes that did not need it.** In the canonical example, 25 belongs in the
  leaf `[30]`, which has room. Top-down meets the full root `[6 10 20]` first and splits
  it. The result is a tree of height 3 with 7 nodes where bottom-up has height 2 with 5.
- **It does not carry over to variable-length keys.** "Full" has to be decided before the
  key arrives. With fixed-size keys it is a count. In a page of byte strings, whether a
  node can take the separator from below depends on that separator's size, which is not
  known on the way down. All on-disk trees in this guide have variable-length keys.
- **A failed allocation leaves a different tree.** Each split is complete before the next
  begins, so after `error.OutOfMemory` the tree is valid and holds the same keys, but
  splits that already happened stay. Bottom-up leaves the tree unchanged.

### Zig: measurements (`zig/src/measure.zig`)

`build(M, variant, gpa, keys)` inserts distinct keys into an empty tree and returns the
shape, the number of splits and the largest number of splits in one `put`. The order is
a `comptime` parameter, so the scenario loops over orders with `inline for`.

### Rust: the same code, three differences

1. **Order at run time, nodes as vectors.** Stable Rust cannot size an array from a
   const generic expression (`[u64; M]` next to `[NodeId; M + 1]`), so `BTree::new(order)`
   takes the order as a value and a node holds three `Vec`s. A split is `split_off`
   and `pop` instead of copy loops. An odd order for `topdown::put` is a panic, not a
   compile error.
2. **Indices instead of pointers.** Nodes live in a slab (`base_pool.rs`) and are named
   by `NodeId(u32)`. The path is an array of `(NodeId, usize)`. Holding a parent and a
   child at the same time is then two indices, which the borrow checker accepts.
3. **`Err(OutOfNodes)` instead of `error.OutOfMemory`.** Rust aborts when the global
   allocator fails, so the slab models the failure itself (see "Allocator notes").

Names, tests and output match the Zig version.

### Output of `zig build run` and `cargo run`

Part 1 prints the worked example above, one tree per put. The rest:

```
== 2. Top-down insert (textbook, CLRS): the same keys ==
...
put 25: 1 split, the root split: height 3
put 1: no split
put 15: no split
  [10]
  [6] [20]
  [1 3 5] [7] | [12 15 17] [25 30]
shape: height=3 nodes=7 leaves=4 keys=12 fill=57% splits=4 root_splits=2
same keys and values as the bottom-up tree: yes

== 3. A put that runs out of memory (the third node allocation fails) ==
both trees before:
  [3 6 9]
  [1 2] [4 5] [7 8] [10 11 12]
bottom-up put 13: OutOfMemory; splits done: 0; keys: 12; tree unchanged:
  [3 6 9]
  [1 2] [4 5] [7 8] [10 11 12]
top-down put 13: OutOfMemory; splits done: 1; keys: 12; valid tree, same keys, new shape:
  [6]
  [3] [9]
  [1 2] [4 5] | [7 8] [10 11 12]
```

Part 4 measures fill (keys stored divided by key slots in all nodes) and splits for
100000 distinct keys, bottom-up. A selection of its rows:

```
   M  keys       variant    height   nodes    fill  splits  per 1000 puts  most in one put
   3  ascending  bottom-up      16   99994   50.0%   99978          999.7               15
   4  ascending  bottom-up      11   50002   66.6%   49991          499.9               10
   5  ascending  bottom-up      10   49995   50.0%   49985          499.8                9
   8  ascending  bottom-up       7   24999   57.1%   24992          249.9                6
  64  ascending  bottom-up       4    3124   50.8%    3120           31.2                3
 256  ascending  bottom-up       3     782   50.1%     779            7.7                2
   4  random     bottom-up      11   51865   64.2%   51854          518.5               10
   8  random     bottom-up       7   21203   67.3%   21196          211.9                6
  16  random     bottom-up       5    9731   68.5%    9726           97.2                4
  64  random     bottom-up       3    2280   69.6%    2277           22.7                2
 128  random     bottom-up       3    1124   70.0%    1121           11.2                2
 256  random     bottom-up       3     529   74.1%     526            5.2                2
```

How to read it:

- **Ascending keys.** Every key lands in the rightmost leaf. When that leaf splits, its
  left half keeps M / 2 keys of M - 1 slots and is never touched again. For M = 4 that is
  2 of 3: the tree is two thirds full, not half. For M = 5 it is 2 of 4, exactly 50%.
  As M grows, (M / 2) / (M - 1) approaches one half, and the measured fill follows:
  57.1%, 50.8%, 50.1%. "Ascending inserts give 50%" is the large-M statement.
- **Random keys.** Half-empty nodes keep receiving keys. The measured fill rises from
  64.2% (M = 4) to about 69 to 70% (M = 32 to 128). The textbook result (Yao, 1978; not
  derived here) is that the expected fill approaches ln 2 = 69.3% as the order grows.
  The row for M = 256 shows 74.1%: with only 529 nodes for 100000 keys this tree is too
  small for the limit to apply, and this single seed sits above it.
- **Random is not always fuller.** At M = 4 the ascending tree (66.6%) is fuller than
  the random one (64.2%).
- **Amortised cost.** "per 1000 puts" falls roughly in proportion to 1 / M, while "most
  in one put" stays near the height. At M = 64 a random insert splits a node 22.7 times
  in 1000 puts, and no put split more than 2 nodes.

Part 5 runs top-down against bottom-up. Top-down is worst for small M and ascending
keys: at M = 4 every node ends at one key of three (33.3%, 99974 splits, against 66.6%
and 49991). For large M the two are close (M = 256, random: 525 against 526 splits).

## In real databases

Both B-tree engines studied in this guide split bottom-up. Neither splits on the way
down (research notes: [`research/postgres.md`](../../research/postgres.md) section 4.3
and 4.4, [`research/turso.md`](../../research/turso.md) sections 8 and 9).

**Postgres, `_bt_split`** (`postgres/src/backend/access/nbtree/nbtinsert.c:1486-2109`).

- *Both halves are built in scratch memory.* The comment at `nbtinsert.c:1519-1533`
  says the left page "is a temporary buffer that receives the left-sibling data, which
  will be copied back into origpage on success", and that failing before the new right
  buffer is acquired "won't have lasting consequences, since origpage won't have been
  modified". The right page is likewise assembled in a temporary copy
  (`nbtinsert.c:1733-1740`). This is the same idea as reserve-then-commit above: do
  everything that can fail before the first visible change.
- *The left half keeps its block number.* "The algorithm requires that the left page
  never move during a split, so we copy the new left page back on top of the original"
  (`nbtinsert.c:1953-1959`). Existing pointers to the page stay valid; only the right
  half is new. Our `splitNode` does the same: `left` stays where it is.
- *The parent stack is only a hint.* Postgres remembers the path too
  (`BTStackData`, `postgres/src/include/access/nbtree.h:743-748`), but other backends
  may split pages while this one works, so the stack "can become stale due to concurrent
  page splits and page deletions" (`nbtree.h:739-741`). `_bt_getstackbuf`
  (`nbtinsert.c:2348-2453`) finds the parent again starting from the remembered
  position, and the median's counterpart, the downlink, is then inserted with a recursive
  `_bt_insertonpg` at `stack->bts_offset + 1` (`nbtinsert.c:2247-2249`). In our
  single-threaded tree the path is always exact. Chapter 20 covers the concurrent case.

**Turso, overflow cell then balance** (`turso/core/storage/btree.rs`).

- When a cell does not fit, `_insert_into_cell` does not write it to the page. It pushes
  it onto the in-memory list `page.overflow_cells` (`btree.rs:10339-10368`). A page with
  overflow cells is the byte-sized version of our node with M keys: "insert first, repair
  afterwards".
- `balance` (`btree.rs:3401`) then works from the leaf upwards. A level is in order when
  `page.overflow_cells.is_empty()` and the page is not too empty (`btree.rs:3429-3430`).
  Otherwise `balance_non_root` (`btree.rs:3604`) redistributes the cells of up to three
  siblings, which may put a new divider into the parent and overflow it in turn.
- A root that overflows is handled by `balance_root` (`btree.rs:5410`): per the research
  notes its content is copied into a new child and the root page itself stays in place,
  so the root's page number never changes. Chapter 12 uses that trick.

The differences from this chapter's tree: fullness is measured in bytes, not keys; the
split point is chosen (chapter 14); and Turso balances across siblings instead of always
cutting one node in two (chapter 15).

Top-down splitting was not found in any of these sources; it is textbook material here.

## Allocator notes

**`std.heap.MemoryPool` is the node pool.** Every node of a `BTree(M, ...)` has the same
type and size, and nodes are created one at a time by splits. `MemoryPool(T)` is built
for that: it hands out fixed-size slots from an internal arena, keeps destroyed slots on
a free list and reuses them first. `base_pool.zig` wraps it as `StdPool` and adds the
counters the tree checks (`created`, `destroyed`, `peak`). The demonstrations and
measurements use it.

- *Lifetime:* the pool is a field of the tree. `tree.deinit(gpa)` returns every node to
  the pool and then calls `pool.deinit(gpa)`, which frees the arena in one go. The
  backing allocator is passed to every call; the pool stores none.
- *What a general-purpose allocator would cost:* one request per node. The test "what a
  build asks of the backing allocator" counts them: `DirectNodes` asks once per node,
  `MemoryPool` less than a quarter as often for the same tree.
- *What an arena alone would cost:* nothing in this chapter, because an insert-only tree
  never frees a node (a test asserts `destroyed == 0`). It stops working in chapter 05,
  where merges give nodes back.
- *Reservation in one call:* `MemoryPool.addCapacity(gpa, n)` pre-allocates n slots, after
  which n calls of `create` cannot fail (tested in `tests_alloc.zig`). `put` reserves
  through `create` instead, to keep one pool interface for all pools.

**`DirectNodes` exists for the tests.** It makes every node its own allocation. With
`std.testing.allocator` a node the tree forgets is then a reported leak, and
`FailingAllocator` can fail one particular node. Part 3 of the scenario uses it for that
reason: with `MemoryPool`, several nodes share one request to the backing allocator, so
"fail the third node" cannot be expressed.

**`std.testing.checkAllAllocationFailures`** runs a function once to count its
allocations, then once per allocation with that allocation and all later ones failing.
Each run must return `error.OutOfMemory` and free everything. `tests_alloc.zig` gives it
a build of 120 keys in which every failed `put` is followed by a check that the rendered
tree, the counters and the pool usage are identical to the state before the call. It
runs for M = 3, 4 and 7 with both pools. `tests_topdown.zig` does the same for the
top-down insert with the weaker promise: valid tree, same keys.

**Rust: slab plus node budget.** `Slab` is a `Vec` of slots with a free list of indices.
Two switches model memory running out: `budget = Some(n)` refuses to have more than n
live nodes, and `fail_after = Some(n)` lets n more allocations succeed and fails the
rest (the twin of `FailingAllocator.fail_index`). Both return `Err(OutOfNodes)`.
`tests_alloc.rs` tries every failing allocation index and every budget below what the
build needs. The slab recycles slots only; each node's `Vec` buffers are still separate
heap allocations, which the Zig pool does not have.

## Pitfalls

- **Splitting at the wrong index.** With M keys, `mid = M / 2` gives halves of M / 2 and
  M - 1 - M / 2. Using `(M - 1) / 2` is also legal for bottom-up, but cutting a node of
  M - 1 keys (a full node, before the insert) is only legal for even M.
- **Forgetting the children.** In an interior split the children right of the median
  move with their keys: `mid + 1` keys stay with `mid + 1` children... no: `mid` keys
  stay with `mid + 1` children. Losing or duplicating one pointer breaks the tree in a
  way only `validate` notices.
- **Inserting the separator and the child in the wrong positions.** The median goes to
  index `i` of the parent and the right half to child index `i + 1`, where `i` is the
  child index followed on the way down.
- **Allocating in the middle of a split chain.** If the second of three splits fails,
  the tree has an overfull node and no way back. Count first, allocate everything, then
  change the tree.
- **Treating an overwrite as an insert.** `put` of an existing key must not change `len`
  and must not split anything in the bottom-up version. The top-down version in this
  chapter does split full nodes on its way to an existing key; a test documents it.
- **Reading "50% for ascending keys" as exact.** It depends on M and on the split point;
  measure before quoting a number.

## Exercises

1. (easy) Insert 1, 2, ..., 10 in this order into an empty tree with M = 4, bottom-up,
   by hand. Which puts split a node?
2. (easy) The table shows 50.0% fill for ascending keys at M = 3 and M = 5 but 66.6% at
   M = 4. Derive all three numbers from the split point.
3. (medium) Prove that building a tree of N keys takes fewer than N / (ceil(M/2) - 1)
   splits, and compare the bound with the measured rows for M = 4 and M = 64.
4. (medium) Top-down with ascending keys at M = 4 ends 33.3% full. Explain why, and why
   the same experiment at M = 256 is harmless.
5. (harder) Replace the reservation loop of `put` by one call of
   `MemoryPool.addCapacity`. What has to change in the pool interface, and what happens
   to the reserved slots when a later step fails?

Solutions: [solutions.md](solutions.md).

## Links

- Previous: [chapter 03, B-tree structure and search](../03-btree-structure-and-search/README.md)
- Next: [chapter 05, Deletion and rebalancing](../05-deletion-and-rebalancing/README.md)
- Visualization: [insert a key, step by step](viz/index.html) and
  [how full do the nodes get?](viz/fill.html)
- Later chapters that build on this one: [14, split policies](../14-split-policies-and-fill-factor/README.md),
  [15, redistribution](../15-redistribution-and-merge-policies/README.md),
  [20, B-link trees](../20-blink-trees/README.md)

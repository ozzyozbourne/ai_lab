# Chapter 05: Deletion and rebalancing

## What you will learn

- How to delete a key from a B-tree without breaking its invariants.
- The four repairs: replace an interior key by its **predecessor**, **borrow** from a
  sibling, **merge** with a sibling, and **shrink** the tree at the root.
- Why a key can never move sideways, only through the parent.
- Why an underflow can travel up the tree, and what stops it.
- What real engines do instead: byte thresholds, lazy merging, or no merging at all.
- Where B-tree nodes should come from and go back to: a free-list pool, written by hand
  and then taken from the standard library.

Prerequisites: [chapter 02](../02-searching-a-sorted-node/README.md) (lower bound),
[chapter 03](../03-btree-structure-and-search/README.md) (structure, invariants, search)
and [chapter 04](../04-insertion-and-splitting/README.md) (insert and split).

This chapter's code is the complete in-memory B-tree of Part I. Search and insertion are
in it, but they are explained in chapters 03 and 04. In short: `get` walks from the root
to a leaf and runs a lower-bound search in every node; `put` inserts into a leaf and,
if the leaf now holds M keys, splits it around the median and pushes the median into the
parent, which may split in turn, up to the root.

## The idea in plain words

A B-tree of order M (M = 4 in all examples) promises three things:

1. Keys are sorted inside a node, and a separator key in a parent lies between the keys
   of the two children next to it.
2. Every node has at most M - 1 keys, and every node except the root has at least
   ceil(M/2) - 1 keys. For M = 4 that is 1 to 3 keys.
3. All leaves are at the same depth.

Insertion threatens the upper limit of promise 2 and repairs it by splitting. Deletion
threatens the lower limit: a node with too few keys is said to **underflow**. Deletion
also threatens promise 1 when the key sits in an interior node, because that key is a
separator and the children on both sides still need one.

The algorithm has two parts.

**Part one: always delete from a leaf.** If the key is in a leaf, remove it. If it is in
an interior node, do not remove it; overwrite it with its in-order predecessor, the
largest key of the subtree to its left. That predecessor is always the last key of a
leaf (walk down the right-most children). It is larger than everything else on the left
and smaller than everything on the right, so it is a valid separator. Then remove the
predecessor from its leaf. Every delete has now become a leaf delete.

**Part two: repair an underflow from the parent.** A node that lost a key may have
ceil(M/2) - 2 keys, one too few. Its parent looks at the node's direct siblings:

- **Borrow.** If a sibling has more than the minimum, one key rotates through the
  parent: the separator between the two nodes moves down into the underfull node, and
  the sibling's nearest key moves up to become the new separator. The key cannot go
  directly from sibling to sibling, because the separator lies between them in sorted
  order. In interior nodes one child pointer moves with the key.
- **Merge.** If no direct sibling can spare a key, the node, one sibling, and the
  separator between them become one node. It always fits: (min - 1) + min + 1 = 2 * min
  keys, and 2 * (ceil(M/2) - 1) is at most M - 1. One node is freed.

A borrow leaves the parent's key count unchanged, so the repair ends there. A merge
takes one key out of the parent, so the parent may now underflow, and its own parent
repairs it the same way. This is the mirror image of a split pushing a key up.

**Root shrink.** The root has no minimum. When a merge takes the root's last key, the
root is left with zero keys and one child. That child becomes the new root and the tree
is one level shorter. Because the tree loses the level at the top, all leaves get one
step closer to the root together, and promise 3 holds. A B-tree grows and shrinks only
at the root.

Cost: one walk down and at most one repair per level on the way back: O(height) nodes.

## A worked example by hand

The canonical keys 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 inserted with M = 4 give
(chapter 04):

```
            [6 10 20]
  [1 3 5]  [7]  [12 15 17]  [25 30]
```

**Delete 3: leaf, no underflow.** `[1 3 5]` becomes `[1 5]`. Still at least one key.

**Delete 7: borrow from the left.** `[7]` becomes empty. Its left sibling `[1 5]` has
two keys and can spare one. Separator 6 moves down, 5 moves up:

```
            [5 10 20]
  [1]  [6]  [12 15 17]  [25 30]
```

**Delete 6: borrow from the right.** `[6]` becomes empty. The left sibling `[1]` is at
the minimum, the right sibling `[12 15 17]` is not. Separator 10 moves down, 12 moves up:

```
            [5 12 20]
  [1]  [10]  [15 17]  [25 30]
```

**Delete 20: interior key.** 20 separates `[15 17]` from `[25 30]`. Its predecessor is
17. Write 17 over 20 and remove 17 from the leaf, which keeps one key:

```
            [5 12 17]
  [1]  [10]  [15]  [25 30]
```

**Delete 10: merge.** `[10]` becomes empty; `[1]` and `[15]` are both at the minimum.
Merge with the left sibling: `[1]` + separator 5 + `[]`:

```
            [12 17]
  [1 5]  [15]  [25 30]
```

The root lost a key. It is the root, so nothing more happens. Continuing with 12, 15,
17, 30 and 25 (see the program output below) ends with a merge that empties the root:
`[5]` over `[1] [25]`, delete 25, merge to `[1 5]`, the root has zero keys, its only
child becomes the root.

**An underflow that travels up.** Keys 1 to 13 inserted in ascending order give a tree
with three levels. After deleting 9 and 13:

```
                 [8]
        [3 6]           [11]
  [1 2] [4 5] [7]     [10] [12]
```

Delete 10. The leaf `[10]` is empty and its only sibling `[12]` is at the minimum, so
they merge with separator 11 into `[11 12]`. The interior node that held 11 now has
zero keys. Its parent (the root) repairs it: the left sibling `[3 6]` can spare a key,
so 8 moves down, 6 moves up, and the child `[7]`, whose keys lie between 6 and 8,
changes parent:

```
                 [6]
        [3]             [8]
  [1 2] [4 5]       [7] [11 12]
```

Delete 1, then 2 (a borrow from the right leaves `[4]` over `[3] [5]`), then 3: the
leaves merge into `[4 5]`, the interior node above them is empty, its sibling `[8]` is
at the minimum, so the two interior nodes merge with separator 6 into `[6 8]`, the root
is empty, and the tree shrinks from three levels to two:

```
        [6 8]
  [4 5] [7] [11 12]
```

## Code walk-through

Both programs print exactly [`expected_output.txt`](expected_output.txt). Parts 2 and 3
are the example above:

```
== 2. Delete, one case at a time ==
delete 3: leaf key; no underflow
  [6 10 20]
  [1 5] [7] [12 15 17] [25 30]
delete 7: leaf key; borrow from left
  [5 10 20]
  [1] [6] [12 15 17] [25 30]
...
delete 25: leaf key; merge, root shrink
  [1 5]

== 3. An underflow that travels up (keys 1..13 inserted in order) ==
...
delete 10: leaf key; merge, borrow from left
  [6]
  [3] [8]
  [1 2] [4 5] | [7] [11 12]
...
delete 3: leaf key; 2 x merge, root shrink
  [6 8]
  [4 5] [7] [11 12]

== 4. Random workload: 20000 operations on 500 possible keys (seed 5) ==
answers checksum: c3304f93543922a7
shape: height=6 nodes=208 leaves=129 keys=347 fill=55%
counters: splits=644 root_splits=5 predecessor_swaps=955 borrows_left=412 borrows_right=234 merges=442 root_shrinks=0

== 5. Delete every remaining key in ascending order ==
  (empty)
shape: height=0 nodes=0 leaves=0 keys=0 fill=0%
counters: splits=644 root_splits=5 predecessor_swaps=955 borrows_left=412 borrows_right=368 merges=644 root_shrinks=5
node pool: created=650 destroyed=650 live=0 peak=217 reused=433
```

In the tree printout one line is one level; ` | ` separates nodes with different
parents. Two things to read off the last lines: after everything is deleted, merges
equal splits and root shrinks equal root splits (every node that a split created was
removed by a merge), and 650 nodes were created over the run although at most 217 were
alive at once.

### Zig

The source is split by topic so later chapters can copy what they need. The last
column says which other files a file imports:

| File | Content | Needs |
|------|---------|-------|
| `node.zig` | `Node(M)`: fixed arrays, one spare slot, entry and child helpers | - |
| `search.zig` | `lowerBound`, `get`, `inOrder`, `range` | node |
| `validate.zig` | every invariant as a named error | node |
| `stats.zig` | `Shape` (height, nodes, fill) and the text rendering | node |
| `pool.zig` | node allocation: `DirectNodes`, `FreeListPool`, `StdPool` | - |
| `insert.zig` | `put`: descend, reserve, commit; `splitNode` | node, search |
| `delete.zig` | `delete`, `removeFrom`, `removeMax`, `fixUnderflow`, borrow, merge | node, search |
| `btree.zig` | `BTree(M, PoolFn)`: fields, counters, thin methods | all of the above |
| `tests_insert.zig` | whole-tree tests that never call `delete` | btree, pool |
| `tests_delete.zig`, `scenario.zig` | the delete tests; the printed scenario | everything |

Search alone is the first four files. Search and insert add `pool`, `insert`,
`tests_insert` and `btree.zig` without its `delete` method.

Deletion is recursive, because the repair happens in the parent after the child has
been changed, which is exactly what "code after the recursive call" does. Condensed
from `delete.zig` (comments and the counter update removed):

```zig
fn removeFrom(comptime Tree: type, tree: *Tree, gpa: Allocator, node: *Tree.NodeT, key: u64) ?u64 {
    const i = search.lowerBound(node.keySlice(), key);
    const found = i < node.len and node.keys[i] == key;
    if (node.leaf) return if (found) node.removeEntry(i).value else null;
    if (found) {
        const removed = node.values[i];
        const predecessor = removeMax(Tree, tree, gpa, node.children[i].?);
        node.keys[i] = predecessor.key;
        node.values[i] = predecessor.value;
        fixUnderflow(Tree, tree, gpa, node, i);
        return removed;
    }
    const removed = removeFrom(Tree, tree, gpa, node.children[i].?, key) orelse return null;
    fixUnderflow(Tree, tree, gpa, node, i);
    return removed;
}
```

`fixUnderflow(parent, i)` returns at once if child `i` still has `min_keys` keys.
Otherwise it tries the left sibling, then the right sibling, then merges (with the left
sibling if there is one). `borrowFromLeft` is five moves:

```zig
if (!child.leaf) child.insertChild(0, left.children[left.len].?);
child.insertEntry(0, parent.keys[sep], parent.values[sep]);   // separator down
const up = left.removeEntry(left.len - 1);                    // sibling's last key ...
if (!left.leaf) _ = left.removeChild(left.len + 1);
parent.keys[sep] = up.key;                                    // ... up
parent.values[sep] = up.value;
```

`mergeChildren` removes the separator and the right child pointer from the parent,
appends separator and right node to the left node, and returns the right node so the
caller can give it back to the pool. `delete` itself handles the root: if the root has
no keys after the recursion, its first child (or nothing, for a leaf) becomes the root
and the old root is freed.

Deletion never allocates and cannot fail. Insertion can, so `put` first reserves every
node the split chain will need (one per full node on the path, plus one if the root
splits) and only then changes the tree. A failed allocation therefore leaves the tree
untouched. `put` also restores the pool's `usage` counters, so they never count
reservations that were handed back. The only trace of a failed `put` is inside the pool:
a slot carved for a returned reservation stays on its free list. `tests_insert.zig`
checks all of this with `std.testing.FailingAllocator` and
`std.testing.checkAllAllocationFailures`.

### Rust

Same files, same function names in snake_case, same tests, same output. The
differences:

- **Order at run time.** Zig's `Node(M)` holds `[M]u64` arrays sized at compile time.
  Stable Rust rejects `[u64; M - 1]` for a const generic `M` ("generic parameters may
  not be used in const operations"), so `BTree::new(order)` stores the order and a node
  holds three `Vec`s. Shifting entries is `Vec::insert` / `Vec::remove` instead of
  hand-written loops, and a split is `split_off`.
- **Indices instead of pointers.** Nodes live in a `Slab` and refer to each other by
  `NodeId(u32)`. A borrow needs the parent, the child and the sibling mutable at the
  same time; with indices the code takes a value out of one node, then touches the
  next, and the borrow checker is satisfied without `unsafe` or `Rc<RefCell<_>>`.
- **`free` returns the node by value.** A merge frees the right node first and appends
  its keys, values and children to the left node (`Vec::append` copies the elements).
  The right node's own buffers are then dropped.
- **Read-only code does not know the slab.** `search.rs`, `validate.rs` and `stats.rs`
  take any `Nodes` (a type with `nodes[id]`). That is the slab, or a plain `Vec<Node>`,
  the typed arena of chapter 03.
- **No `deinit`.** Dropping the tree drops the slab and every node in it. In Zig the
  tree walks all nodes and returns each one, and the test allocator checks that none
  was missed.
- **Failure model.** A failed allocation aborts a Rust process, so the slab itself
  refuses and `put` returns `Err(OutOfNodes)`. It has two switches. `budget` limits
  the number of live nodes. `fail_after = Some(n)` lets n more allocations succeed and
  then fails, like `fail_index` of Zig's `FailingAllocator`; only this one can fail the
  second allocation of one `put` in a tree of any size. The reserve-then-commit
  structure is identical; the `errdefer` that returns reserved nodes is an explicit
  loop.
- **Use-after-free and double free** are panics in the slab (`slab[id]` on a freed
  slot, `free` twice), tested with `#[should_panic]`. In Zig the same bugs are caught
  by `std.testing.allocator` when nodes are allocated one by one (see below).

## In real databases

The algorithm above is the textbook one (Bayer and McCreight's, in the bottom-up form;
CLRS describes a top-down variant that refills nodes on the way down so that no repair
is needed on the way up). None of the engines studied for this guide implements it as
written. What they do instead:

**Turso (SQLite format): one balance routine, byte thresholds.**
- An index-tree delete of an interior cell replaces it with the predecessor from a
  leaf, as here: the flow is documented at `turso/core/storage/btree.rs:7029-7040`
  ("we copy the left subtree leaf node into the deleted interior node's place") and the
  three steps (move to the largest key of the left subtree, replace the interior cell,
  delete the predecessor from the leaf) are marked in the code at `:7203`, `:7282` and
  `:7301`. Table trees keep all rows in leaves (chapter 07), so
  their deletes always start in a leaf.
- Underflow is measured in bytes, lazily. `delete_may_need_balancing`
  (`btree.rs:10836-10848`) asks whether more than two thirds of the page would be free;
  `balance` treats a page as fine when `free_space * 3 <= usable_space * 2`
  (`btree.rs:3427-3430`). A page is repaired when it is less than one third full, not
  when it is less than half full.
- There is no separate borrow or merge function. `balance_non_root` collects the cells
  of up to 3 siblings (`MAX_SIBLING_PAGES_TO_BALANCE`, `btree.rs:160`) plus the dividers
  between them, and redistributes them over as many pages as needed, up to 5
  (`btree.rs:162-163`). Fewer pages out than in is a merge, the same number is a
  borrow, more is a split. Chapter 15 builds this.
- Root shrink exists under the name "balance-shallower": when the root has no cells
  left and its only child fits, the child is copied into the root page
  (`btree.rs:4833-4838`). The root page number never changes.

**TigerBeetle: merge or borrow, one level.** TigerBeetle has no B-tree, but its
`SegmentedArray` is an array of fixed-capacity nodes with the same half-full rule
("Every node is at least half-full, except the last",
`tigerbeetle/src/lsm/segmented_array.zig:192`). After a removal, `maybe_merge_nodes`
(`segmented_array.zig:579-637`) looks at the node and its right neighbour: if both fit
into one node they are merged and the empty node goes back to the node pool; otherwise,
if the left one is below half, elements move from the right until both hold half of the
total. There are no separator keys to fix, because the structure has a single level.

**PostgreSQL: no merging.** nbtree never merges or rebalances partly full pages. Its
README states: "We consider deleting an entire page from the btree only when it's
become completely empty of items. (Merging partly-full pages would allow better space
reuse, but it seems impractical to move existing data items left or right to make this
happen --- a scan moving in the opposite direction might miss the items if so.)"
(`postgres/src/backend/access/nbtree/README:235-239`). Empty pages are removed later by
VACUUM, and the tree never gets shorter. Chapter 24 covers that.

**Milvus** uses the Go library `google/btree` with degree 2 in two in-memory places
(`milvus/internal/kv/mem/mem_kv.go:53`,
`milvus/internal/streamingcoord/server/broadcaster/schema.go:90`). The library's
delete code is not part of the Milvus checkout and was not inspected (unverified).

The pattern: strict "at least half full" is a textbook guarantee. Engines that store
variable-size records count bytes, repair late or never, and accept emptier pages in
exchange for less work and simpler concurrency.

## Allocator notes

Nodes of one tree all have the same size and are created and destroyed constantly:
part 5 of the output shows 650 nodes created while at most 217 were alive. That is the
textbook case for a **pool**: fixed-size slots and a free list.

The tree is generic over a pool type, `BTree(M, PoolFn)`, and every pool has the same
members: `empty`, `create(gpa)`, `destroy(gpa, node)`, `deinit(gpa)`, `usage`. The
backing allocator is passed to each call; nothing stores one. The contract is checked
by the compiler where the tree uses it, so a pool written in another file works too
(`tests_insert.zig` has a bump allocator as an example). Every pool must keep `usage`
current with `usage.onCreate()` and `usage.onDestroy()`; a pool that cannot free a
single node only counts in `destroy`.

| Pool | How it works | Use it for |
|------|--------------|-----------|
| `DirectNodes` | `gpa.create` / `gpa.destroy` per node | tests |
| `FreeListPool` | hand-written: chunks of 32 slots; a freed slot stores the pointer to the next free slot in its own first bytes | understanding |
| `StdPool` | wraps `std.heap.MemoryPool(Node)`, which does the same | real code |

`FreeListPool.create` pops the free list if it is not empty (last freed, first reused)
and otherwise takes the next unused slot of the newest chunk, allocating a new chunk
when needed. `destroy` pushes the slot on the list. Memory returns to `gpa` only in
`deinit`. The model tests run all three pools and require identical trees.

**Lifetime.** The pool lives exactly as long as the tree; `tree.deinit` returns every
node and then calls `pool.deinit`. A node's lifetime ends at the merge or root shrink
that unlinks it.

**What goes wrong with other choices.**
- An `ArenaAllocator` cannot free a single node. Under the workload of part 4 it would
  hold all 650 nodes instead of 217. Arenas fit a build-once tree (chapter 03), not one
  that deletes.
- One general-purpose allocation per node works but pays the general allocator's cost
  on every split and merge and scatters nodes across the heap.
- A pool hides bugs from the leak checker. `std.testing.allocator` is a
  `SafeAllocator`: it fails a test on a leaked allocation and aborts on a double free.
  With a pool it only sees chunks, so a node that a merge forgot to return is invisible
  to it: the test "SafeAllocator sees a node that DirectNodes forgot, but not one a
  pool forgot" shows exactly one reported leak for two forgotten nodes. That is why the
  tests use `DirectNodes` (every node is its own allocation), why each pool counts
  `created` and `destroyed`, and why `validate` compares the pool's live count with the
  number of nodes reachable from the root.
- A double `destroy` on `FreeListPool` links a slot to itself. The free list then never
  runs out and every later `create` returns that same node. No counter looks wrong (the
  test "FreeListPool does not notice a double destroy" shows it). The same bug under
  `DirectNodes` with the test allocator stops the program at the second `destroy` with
  `panic: double free of [addr: ..., len: 16 ...]` and the stack traces of the
  allocation and of both frees. A test that aborts cannot be part of the suite, so this
  half is not in `zig build test`.
- A pool never shrinks. After part 5 the tree is empty, but the chunks for 217 nodes
  stay allocated until `deinit`.

Rust has one structure in this role: `Slab`, a `Vec` of slots with a free list of
indices. It detects double free and use-after-free itself, and counts live nodes for
`validate`. It recycles node slots (ids) only. The key, value and child vectors of a
node are still separate heap allocations, made by a split and released by a merge, so
the slab is not the full pool of the Zig version.

## Pitfalls

- **Moving a key sideways.** Borrowing must rotate through the parent. Copying the
  sibling's key straight into the underfull node leaves the old separator on the wrong
  side of it. `validate` reports `KeyOutsideParentBounds`.
- **Forgetting the child pointer** when borrowing or merging interior nodes. The key
  count looks right, the child count does not (`MissingChild`), or a subtree becomes
  unreachable.
- **Leaving the separator in the parent on a merge.** The parent then has as many keys
  as children.
- **Repairing in the wrong place.** The underfull node cannot fix itself: it has no
  access to its siblings. Check the child after the recursive call returns, in the
  parent.
- **Taking the predecessor without repairing its path.** `removeMax` must call
  `fixUnderflow` at every level it passes, not only at the leaf.
- **Treating the root like other nodes.** The root may have a single key. It is
  replaced only when it has none.
- **Not freeing the merged-away node**, or freeing it twice. The first is invisible
  without a leak check or a live counter.
- **Testing only with large nodes.** With M = 4, part 4 of the output needs 646 borrows
  and 442 merges in 20000 operations; with M = 64 the workload of exercise 4 merges 56
  times in 200000 operations. Small orders find bugs (chapter 06).

## Exercises

1. (Easy) Start from the canonical tree `[6 10 20]` over `[1 3 5] [7] [12 15 17]
   [25 30]`. By hand, delete 25, then 30, then 17. Draw the tree after each step and
   name the repair. Check with the visualization.
2. (Medium) Replace the predecessor by the **successor** (smallest key of the right
   subtree) when an interior key is deleted. What does `removeMin` look like, and how
   does the result of "delete 20" on the canonical tree change? Is one choice better?
3. (Medium) Prove for every order M >= 3 that (a) a merge never produces a node with
   more than M - 1 keys, and (b) after a borrow both nodes are legal. Where does the
   argument use that only one key is deleted at a time?
4. (Harder) Make the tree lazy like a real engine: keep the split rule, but treat a
   node as underfull only when it has no keys left. Which lines change? Which invariant
   in `validate` must be relaxed? Run 200000 operations (only puts and deletes, equal
   weights, 5000 possible keys, seed 5) with M = 16 for both rules and compare node
   count, fill and the number of repairs.

Solutions: [solutions.md](solutions.md).

## Links

- Previous: [Chapter 04: Insertion and splitting](../04-insertion-and-splitting/README.md)
- Next: [Chapter 06: Testing a B-tree](../06-testing-a-btree/README.md)
- Visualization: [viz/index.html](viz/index.html) (interactive delete: borrow, merge,
  height shrink)

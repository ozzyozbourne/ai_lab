# Chapter 05: solutions

## 1. Three deletes by hand

Start:

```
            [6 10 20]
  [1 3 5]  [7]  [12 15 17]  [25 30]
```

**Delete 25.** Leaf key, the leaf keeps one key. No repair.

```
            [6 10 20]
  [1 3 5]  [7]  [12 15 17]  [30]
```

**Delete 30.** The leaf is empty. It is the right-most child, so it has only a left
sibling, `[12 15 17]`, which can spare a key: borrow from the left. Separator 20 moves
down, 17 moves up.

```
            [6 10 17]
  [1 3 5]  [7]  [12 15]  [20]
```

**Delete 17.** Interior key. Its predecessor is 15, the largest key of the child to its
left. 15 replaces 17 and is removed from the leaf, which keeps one key. No repair.

```
            [6 10 15]
  [1 3 5]  [7]  [12]  [20]
```

(Checked by running the chapter's tree with these three deletes.)

## 2. Successor instead of predecessor

`removeMin` is the mirror image of `removeMax`: follow child 0 instead of the last
child, remove the first entry of the leaf, and repair child 0 on the way back.

```zig
fn removeMin(comptime Tree: type, tree: *Tree, gpa: Allocator, node: *Tree.NodeT) node_mod.Entry {
    if (node.leaf) return node.removeEntry(0);
    const entry = removeMin(Tree, tree, gpa, node.children[0].?);
    fixUnderflow(Tree, tree, gpa, node, 0);
    return entry;
}
```

In `removeFrom`, the interior case becomes:

```zig
const successor = removeMin(Tree, tree, gpa, node.children[i + 1].?);
node.keys[i] = successor.key;
node.values[i] = successor.value;
fixUnderflow(Tree, tree, gpa, node, i + 1);   // the RIGHT child lost a key
```

On the canonical tree, "delete 20" then takes 25 from `[25 30]`:

```
            [6 10 25]
  [1 3 5]  [7]  [12 15 17]  [30]
```

instead of `[6 10 17]` over `... [12 15] [25 30]`.

Neither choice is better in general; both are valid separators and both cost one walk
to a leaf. A refinement is to look at the two children first and take the key from the
one with more keys, so the replacement itself does not cause an underflow. On this tree
that picks the predecessor (`[12 15 17]` has three keys, `[25 30]` has two). The price
is one more node read. Turso always uses the predecessor
(`turso/core/storage/btree.rs:7203`).

## 3. Why a merge fits and a borrow is legal

Let min = ceil(M/2) - 1 and max = M - 1.

Before a delete every non-root node has between min and max keys. A delete removes one
key from one leaf. So when `fixUnderflow` finds a child below min, the child has exactly
min - 1 keys. The same holds one level up: a merge removes exactly one key from the
parent, so an underfull interior node also has exactly min - 1 keys. This is where "one
key at a time" is used; a bulk delete would need a different argument (and a different
algorithm, see chapter 15).

**(a) Merge.** We merge only if no direct sibling has more than min keys. The sibling
we merge with is a legal node, so it has exactly min keys. The merged node has

    (min - 1) + 1 + min = 2 * min = 2 * ceil(M/2) - 2 keys.

For even M this is M - 2; for odd M it is M - 1. Both are at most max. For odd M the
merged node is completely full, which is worth knowing: the next insert into it splits
it again (see chapter 15 on why some engines avoid merging).

Children: an interior node with k keys has k + 1 children. The two nodes bring
(min - 1 + 1) + (min + 1) = 2 * min + 1 children, exactly what a node with 2 * min keys
needs.

**(b) Borrow.** We borrow only from a sibling with at least min + 1 keys. Afterwards
the sibling has at least min keys (legal) and at most max - 1. The underfull node goes
from min - 1 to min keys (legal). The parent's key count does not change; one of its
separators is replaced by a key that lies between the two nodes, because it was the
sibling's extreme key on the side facing the underfull node. One child moves, so the
sibling has one key and one child fewer and the underfull node one key and one child
more: both keep "children = keys + 1".

M = 3 is the edge: min = 1, so an underfull node has zero keys (and, if interior, one
child). The code handles it without a special case, and the model test runs M = 3.

## 4. A lazy tree

**What changes.** Only the threshold. In the chapter's code the underflow limit and
the legal minimum are the same constant, `min_keys`. Give the lazy tree `min_keys = 1`
for every M:

- `fixUnderflow` then acts only when a child has zero keys;
- "borrow if the sibling has more than `min_keys`" becomes "more than one key";
- a merge joins an empty node, the separator and a one-key sibling: two keys, always
  fits;
- `splitNode` is unchanged (it still cuts in the middle);
- `validate` uses the same constant, so `NodeUnderfull` now means "a non-root node
  with zero keys". The invariant "at least half full" is gone; "at least one key"
  replaces it. The height bound of chapter 03 no longer holds: in the worst case every
  node has one key and two children, and the tree is as tall as a binary tree.

In Zig the experiment is one line in `node.zig` (`pub const min_keys = 1;`).

**Measured** with this chapter's code, 200000 operations, weights put 4 / delete 4,
5000 possible keys, seed 5. Both runs end with the same 2545 keys.

| M = 16 | strict (min 7) | lazy (min 1) |
|--------|----------------|--------------|
| height | 4 | 4 |
| nodes | 276 | 484 |
| fill | 61% | 35% |
| splits | 1287 | 506 |
| borrows (left + right) | 5886 + 1882 = 7768 | 976 + 149 = 1125 |
| merges | 1015 | 26 |

The lazy tree does about one seventh of the repair work and less than half the splits
(nodes that are allowed to stay half empty absorb later inserts), and pays with 75%
more nodes. With M = 64 the difference in structure grows: strict gives 65 nodes at
height 2 with 1900 borrows and 56 merges; lazy gives 78 nodes at height 3 with no
borrow and no merge at all in this run.

This is the trade the real engines make (README, "In real databases"): Turso repairs a
page only when it is less than one third full, PostgreSQL only removes pages that are
completely empty. Steady workloads refill half-empty pages by themselves; the repair
work is only worth it when space matters more than write cost.

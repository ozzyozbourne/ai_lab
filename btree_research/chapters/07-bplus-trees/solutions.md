# Chapter 07: solutions

Notation as in the chapter: `#n` handle, `[..]` internal node, `(..)` leaf.
Code is shown in Zig; the Rust version differs only in syntax.

## 1. Ascending inserts 1 to 10, M = 4

A leaf overflows at 4 keys and splits 2 + 2. New keys are always the largest,
so they always go to the rightmost leaf; the left half of every split is never
touched again and stays at 2 keys.

```
1 2 3            (1 2 3)
4                [3]            (1 2) (3 4)
5 6              [3 5]          (1 2) (3 4) (5 6)
7 8              [3 5 7]        (1 2) (3 4) (5 6) (7 8)
9                                               ... (7 8 9)
10               leaf split copies 9 up: root would be [3 5 7 9], one too many;
                 push-up of 7:

                 [7]
        [3 5]           [9]
(1 2) (3 4) (5 6)   (7 8) (9 10)
```

Every leaf holds 2 of 3 possible keys. A 50/50 split is the wrong choice for
ascending keys, because the space left in the left half is never used.
Chapter 14 (split policies) fixes this by splitting the rightmost leaf
unevenly. You can check the shape with:

```zig
var tree: BPlusTree = .init(4);
for (1..11) |k| _ = try tree.put(gpa, k, k);
try dump.dump(&tree, w);
```

## 2. Delete 6, then 7

Start: `#7[15]`, `#2[6 10] #6[20]`,
`#0(1 3 5) #4(6 7) #1(10 12) #5(15 17) #3(20 25 30)`.

- **delete 6**: leaf `#4` becomes `(7)`. It still has the minimum of 1 key, so
  nothing else happens. Separator 6 in `#2` is now stale: no leaf contains 6.
- **delete 7**: leaf `#4` is empty. It is child 1 of `#2`. Its left sibling
  `#0(1 3 5)` has more than the minimum, so `#4` borrows 5 from it and the
  separator between them (the stale 6) is overwritten with a copy of `#4`'s
  new first key, 5.

Result: `#2[5 10]`, leaves `#0(1 3) #4(5) #1(10 12) ...`. The stale separator
existed only between the two deletes; a borrow or merge next to a stale
separator replaces or removes it. Separators 10, 15 and 20 do not change.

## 3. `min`, `max`, `countLeaves`

The tree keeps both ends of the chain, so neither function descends:

```zig
pub fn min(tree: *const BPlusTree) ?Entry {
    if (tree.first_leaf == .nil) return null;
    const n = tree.nodes.get(tree.first_leaf);
    return .{ .key = n.keys[0], .value = n.kind.leaf.values[0] };
}

pub fn max(tree: *const BPlusTree) ?Entry {
    if (tree.last_leaf == .nil) return null;
    const n = tree.nodes.get(tree.last_leaf);
    return .{ .key = n.keys[n.len - 1], .value = n.kind.leaf.values[n.len - 1] };
}

pub fn countLeaves(tree: *const BPlusTree) usize {
    var count: usize = 0;
    var id = tree.first_leaf;
    while (id != .nil) : (id = tree.nodes.get(id).kind.leaf.next) count += 1;
    return count;
}
```

`keys[0]` and `keys[len - 1]` are safe because a leaf that is part of the tree
is never empty (invariant 4; an empty tree has no leaf at all). In a classic
B-tree `min` needs a descent along the leftmost path; here it is O(1).
`countLeaves` is O(number of leaves) and reads no internal node.

## 4. A stricter check, and why it is too strict

```zig
pub fn separatorsAreLeafKeys(tree: *const BPlusTree) bool {
    if (tree.root == .nil) return true;
    return check(tree, tree.root);
}

fn check(tree: *const BPlusTree, id: NodeId) bool {
    const n = tree.nodes.get(id);
    if (n.isLeaf()) return true;
    for (n.keySlice()) |separator| {
        if (tree.get(separator) == null) return false;
    }
    for (n.childSlice()) |child| {
        if (!check(tree, child)) return false;
    }
    return true;
}
```

The shortest failing sequence in the demo program is the twelve canonical
inserts followed by `delete 15`. After inserts alone the check always holds:
a separator is created as a copy of a leaf key, and inserts never remove keys.

The tree is still correct because of what a separator promises. Separator `s`
between children `left` and `right` promises: every key in `left` is `< s`
and every key in `right` is `>= s`. Deleting a key from a leaf cannot break
either half of that promise. Search only ever uses the promise, never the
assumption that `s` exists. That is why `validate` checks key *bounds*
(`KeyOutOfBounds`) and not membership.

## 5. Separators that are not keys

Only `splitLeaf` has to change. Instead of returning `right.keys[0]` it may
return any `s` with `left.keys[left.len - 1] < s <= right.keys[0]`, for
example the value closest to the middle:

```zig
const last_left = left.keys[left.len - 1];
const first_right = right.keys[0];
// last_left < first_right, so the subtraction cannot underflow and the
// result is in (last_left, first_right].
const separator = first_right - (first_right - last_left - 1) / 2;
return .{ .separator = separator, .right = right_id };
```

Nothing else needs to change:

- `childIndex` only compares; it does not care whether `s` is a key.
- `splitInternal` moves separators around without looking at leaves.
- The leaf cases of `borrowFromLeft` / `borrowFromRight` overwrite the
  separator with a copy of the right node's first key. That is still a valid
  separator (it is the upper end of the allowed range), so they may stay.
- `merge` drops or pulls down separators without interpreting them.
- `validate` checks bounds, and the new separator is inside them.

Tests: everything that checks behaviour still passes (the model tests, the
chain tests, the failure-injection test, the corruption tests). The tests
that fail are the ones that compare an exact picture: the canonical shape
(the root would hold 14 instead of 15), the delete walk-through, the
copy-up test (it asks for 15 in the root), and the comparison with
`expected_output.txt`.

This is the idea behind suffix truncation in chapter 17: with string keys the
"value in between" can be much shorter than either key, and shorter separators
mean more children per internal page.

# Chapter 03: solutions

Every result below that is not pure arithmetic was produced by the chapter's code. The
place where it is checked is named with each answer.

## 1. Three lookups by hand

```
                 [6 10 20]
    [1 3 5]  [7]  [12 15 17]  [25 30]
```

**get(15).** Root `[6 10 20]`: the first key that is not smaller than 15 is 20, index 2.
It is not 15, the root is not a leaf, so follow child 2. Leaf `[12 15 17]`: the lower
bound is index 1, and the key there is 15. Found, value 150, 2 nodes read.

**get(26).** Root: no key is 26 or larger, so the lower bound is index 3, one past the
end. Follow child 3. Leaf `[25 30]`: the lower bound is index 1 (key 30), which is not
26. A leaf has no children: absent, 2 nodes read.

**get(6).** Root: the lower bound is index 0, and the key there is 6. Found, value 60,
1 node read. The search ends in an interior node.

`explainGet` (or the Search box of the visualization) prints the same:

```
get 15: [6 10 20] child 2 -> [12 15 17] has it at index 1 -> value 150 (2 nodes read)
get 26: [6 10 20] child 3 -> [25 30] is a leaf without it -> absent (2 nodes read)
get 6: [6 10 20] has it at index 0 -> value 60 (1 node read)
```

## 2. Heights for M = 5 and 100 keys

t = ceil(5/2) = 3.

- Fewest keys with h levels: 2 * 3^(h-1) - 1, that is 1, 5, 17, 53, 161 for h = 1 to 5.
  100 keys reach 53 but not 161, so the largest possible height is **4**.
- Most keys with h levels: 5^h - 1, that is 4, 24, 124 for h = 1 to 3. 100 keys do not
  fit into 24 but fit into 124, so the smallest possible height is **3**.

A tree of order 5 needs **161** keys before it can have 5 levels.

Checked by the test "height bounds: the README's worked example" in `height.zig` and
`height.rs` (`minHeight(5, 100) == 3`, `maxHeight(5, 100) == 4`, `minKeys(5, 5) == 161`).

## 3. Two defects at once

**Leaf `[7]` becomes `[11]` and leaf `[12 15 17]` becomes `[12 17 15]`.** `validate`
returns `KeyOutsideParentBounds`. The walk is depth-first, left to right. It checks the
root, then leaf `[1 3 5]`, then leaf `[11]` with the bounds (6, 10). 11 is not below 10,
so the walk stops there. It never reaches the third leaf. Both languages agree.

**Leaf `[1 3 5]` becomes `[3 1 5]` and the root's last child pointer is erased.**
`validate` returns `MissingChild`, not `KeysOutOfOrder`, although the disordered leaf is
the leftmost node below the root. `check` works on one node in this order: its size, its
keys (order and bounds), then all of its child slots, and only after that the subtrees.

- Zig: a first loop over `node.children` returns `MissingChild` for an empty slot among
  the first `len + 1` (and `UnexpectedChild` for a filled slot behind them). The second
  loop, which descends, is never reached.
- Rust: a missing child is a `children` vector that is too short, and `check` compares
  `children.len()` with `len() + 1` before it descends into any child.

So the root's defect is found while the walk is still in the root, and both languages
name the same error. `validate` promises only to name a violation that exists; which
one comes first follows from the order of the walk.

Both cases are the test "two defects: validate reports the one its walk meets first" in
`broken.zig` and `two_defects_validate_reports_the_one_its_walk_meets_first` in
`broken.rs`.

## 4. How many red-black trees for one 2-3-4 tree

A one-key node has one form: a black node. A two-key node `[a b]` has two forms: black
b with red left child a, or black a with red right child b. A three-key node `[a b c]`
has one form: black b with red children a and c.

Why no choice for three keys: the node needs one black node and two red ones, and a red
node may not have a red child. So both red nodes must be direct children of the black
one, which forces the black node to be the middle key b (a binary node has one child on
each side, and a < b < c).

The choices of different nodes are independent, so a 2-3-4 tree with j two-key nodes has
2^j red-black forms. The canonical tree has exactly one two-key node, `[25 30]`, so it
has **2**. (This is counting, not a program result. The code's choice, red on the left,
is the left-leaning form.)

## 5. `successor`

The smallest key greater than `key` is either in the subtree the search for `key`
descends into, or it is one of the separators the search passed on the way down: the
nearest one to the right. So walk down as `get` does, and remember the last key seen
that is greater than `key`.

```zig
/// Smallest key strictly greater than `key`, or null. One descent, no allocation.
pub fn successor(comptime M: usize, root: ?*const Node(M), key: u64) ?u64 {
    var best: ?u64 = null;
    var node = root orelse return null;
    while (true) {
        // i = index of the first key that is > key (the upper bound of chapter 02).
        var i: usize = 0;
        while (i < node.len and node.keys[i] <= key) i += 1;
        if (i < node.len) best = node.keys[i];
        if (node.leaf) return best;
        node = node.children[i].?;
    }
}
```

`best` is the variable that has to survive. A candidate found lower in the tree always
replaces one found higher up, because child i holds only keys below `keys[i]`: anything
greater than `key` down there is closer to `key` than `keys[i]` is. If the lower levels
have nothing greater than `key`, the last separator remembered is the answer. Example:
`successor(17)` on the canonical tree remembers 20 in the root, finds nothing greater
than 17 in leaf `[12 15 17]`, and returns 20.

The inner loop is a linear scan to keep the solution short; a binary search for the
upper bound does the same in fewer comparisons.

This function was run against a brute-force scan of the sorted key list for every key
from 0 to 39 on the canonical tree (a scratch test, not part of the chapter's test
suite). It is not in the chapter's source: ordered iteration is the subject of
[chapter 08](../08-range-scans-and-cursors/README.md).

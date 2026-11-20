/* Chapter 03 visualization data. A classic script (no fetch under file://).
 *
 * CHAPTER_CODE: the functions the figures animate, taken from zig/src and
 * rust/src (base_search, base_validate, redblack). `get` and `inOrder` are
 * line-aligned in both languages; `validate` is condensed (the optional
 * bounds are written as plain numbers) and also line-aligned; the red-black
 * snippets are the real code and are highlighted per language.
 *
 * CHAPTER_EXPECTED: ../expected_output.txt, copied verbatim. index.html
 * recomputes every part with the JavaScript model (model.js) and compares
 * the text, so the pictures cannot drift from the programs.
 */
window.CHAPTER_CODE = {
  get: {
    zig: `
pub fn get(comptime M: usize, root: ?*const Node(M), key: u64) ?u64 {
    var node = root orelse return null;
    while (true) {
        const i = lowerBound(node.keySlice(), key);
        if (i < node.len and node.keys[i] == key) return node.values[i];
        if (node.leaf) return null;
        node = node.children[i].?;
    }
}`,
    rust: `
pub fn get<P: Nodes + ?Sized>(nodes: &P, root: Option<NodeId>, key: u64) -> Option<u64> {
    let mut node = &nodes[root?];
    loop {
        let i = lower_bound(&node.keys, key);
        if i < node.len() && node.keys[i] == key { return Some(node.values[i]); }
        if node.leaf { return None; }
        node = &nodes[node.children[i]];
    }
}`
  },
  inorder: {
    zig: `
pub fn inOrder(comptime M: usize, root: ?*const Node(M), visitor: anytype) void {
    const node = root orelse return;
    for (0..node.len + 1) |i| {
        if (!node.leaf) inOrder(M, node.children[i], visitor);
        if (i < node.len) visitor.visit(node.keys[i], node.values[i]);
    }
}`,
    rust: `
pub fn in_order<P: Nodes + ?Sized>(nodes: &P, root: Option<NodeId>, visit: &mut dyn FnMut(u64, u64)) {
    let Some(id) = root else { return };
    for i in 0..=nodes[id].len() {
        if !nodes[id].leaf { in_order(nodes, Some(nodes[id].children[i]), visit); }
        if i < nodes[id].len() { visit(nodes[id].keys[i], nodes[id].values[i]); }
    }
}`
  },
  validate: {
    zig: `
if (root.len == 0) return error.EmptyRoot; // else: check(root, none, none, true, 0)
if (node.len > max_keys) return error.NodeOverfull;
if (!is_root and node.len < min_keys) return error.NodeUnderfull;
for (node.keySlice(), 0..) |key, i| {
    if (i > 0 and node.keys[i - 1] >= key) return error.KeysOutOfOrder;
    if (key <= lo or key >= hi) return error.KeyOutsideParentBounds;
}
if (node.leaf) {
    if (hasChildPointer(node)) return error.UnexpectedChild;
    if (depth != first_leaf_depth) return error.LeavesAtDifferentDepths;
    return;
}
for (node.children, 0..) |child, i| { // every child slot of this node first ...
    if (i <= node.len and child == null) return error.MissingChild;
    if (i > node.len and child != null) return error.UnexpectedChild;
}
for (0..node.len + 1) |i| { // ... and only then the subtrees
    try check(node.children[i].?, if (i == 0) lo else node.keys[i - 1],
        if (i == node.len) hi else node.keys[i], false, depth + 1);
}
// after the walk:
if (count != tree.len) return error.WrongKeyCount;
if (reachable_nodes != pool.usage.live()) return error.NodeCountMismatch;`,
    rust: `
if nodes[root].is_empty() { return Err(EmptyRoot); } // else: check(root, none, none, true, 0)
if node.len() > max_keys(order) { return Err(NodeOverfull); }
if !is_root && node.len() < min_keys(order) { return Err(NodeUnderfull); }
for (i, &key) in node.keys.iter().enumerate() {
    if i > 0 && node.keys[i - 1] >= key { return Err(KeysOutOfOrder); }
    if key <= lo || key >= hi { return Err(KeyOutsideParentBounds); }
}
if node.leaf {
    if !node.children.is_empty() { return Err(UnexpectedChild); }
    if depth != first_leaf_depth { return Err(LeavesAtDifferentDepths); }
    return Ok(());
}
// the number of children of this node first ...
if node.children.len() < node.len() + 1 { return Err(MissingChild); }
if node.children.len() > node.len() + 1 { return Err(UnexpectedChild); }
// (a Vec has no empty slots: too short or too long is all that can happen)
for (i, &child) in node.children.iter().enumerate() { // ... and only then the subtrees
    check(child, if i == 0 { lo } else { node.keys[i - 1] },
        if i == node.len() { hi } else { node.keys[i] }, false, depth + 1)?;
}
// after the walk:
if count != tree.len { return Err(WrongKeyCount); }
if reachable_nodes != arena.len() { return Err(NodeCountMismatch); }`
  },
  redblack: {
    zig: `
const k = n.keys;
return switch (n.len) {
    1 => try make(arena, k[0], .black, sub[0], sub[1]),
    2 => try make(arena, k[1], .black,
        try make(arena, k[0], .red, sub[0], sub[1]), sub[2]),
    3 => try make(arena, k[1], .black,
        try make(arena, k[0], .red, sub[0], sub[1]),
        try make(arena, k[2], .red, sub[2], sub[3])),
    else => unreachable,
};`,
    rust: `
let k = &n.keys;
match n.len() {
    1 => self.make(k[0], Color::Black, sub[0], sub[1]),
    2 => {
        let red = self.make(k[0], Color::Red, sub[0], sub[1]);
        self.make(k[1], Color::Black, Some(red), sub[2])
    }
    _ => {
        let left = self.make(k[0], Color::Red, sub[0], sub[1]);
        let right = self.make(k[2], Color::Red, sub[2], sub[3]);
        self.make(k[1], Color::Black, Some(left), Some(right))
    }
}`
  }
};

/* Lines of the red-black snippet for a 2-3-4 node with 1, 2 or 3 keys. */
window.CHAPTER_RB_LINES = {
  1: { zig: [3], rust: [3] },
  2: { zig: [[4, 5]], rust: [[4, 7]] },
  3: { zig: [[6, 8]], rust: [[8, 12]] }
};

window.CHAPTER_EXPECTED = `== 1. The canonical tree, built by hand (M = 4: 1 to 3 keys per node) ==
  [6 10 20]
  [1 3 5] [7] [12 15 17] [25 30]
shape: height=2 nodes=5 leaves=4 keys=12 fill=80%
validate: ok
node storage: 5 nodes created, 0 freed one by one, all released together

== 2. Search reads one node per level ==
get 10: [6 10 20] has it at index 1 -> value 100 (1 node read)
get 17: [6 10 20] child 2 -> [12 15 17] has it at index 2 -> value 170 (2 nodes read)
get 1: [6 10 20] child 0 -> [1 3 5] has it at index 0 -> value 10 (2 nodes read)
get 8: [6 10 20] child 1 -> [7] is a leaf without it -> absent (2 nodes read)
get 31: [6 10 20] child 3 -> [25 30] is a leaf without it -> absent (2 nodes read)

== 3. In-order traversal visits the keys in ascending order ==
1 3 5 6 7 10 12 15 17 20 25 30

== 4. Break the canonical tree on purpose: one change, one broken invariant ==
 1. leaf [12 15 17] reordered to [12 17 15]
    validate: KeysOutOfOrder; get finds 11 of the 12 original keys
 2. leaf [7] holds 11 instead: sorted, but on the wrong side of separator 10
    validate: KeyOutsideParentBounds; get finds 11 of the 12 original keys
 3. leaf [12 15 17] gets a fourth key, 18
    validate: NodeOverfull; get finds 12 of the 12 original keys
 4. leaf [7] loses its only key
    validate: NodeUnderfull; get finds 11 of the 12 original keys
 5. the root's key count is set to 0
    validate: EmptyRoot; get finds 3 of the 12 original keys
 6. leaf [12 15 17] becomes interior [15] above new leaves [12] and [17]
    validate: LeavesAtDifferentDepths; get finds 12 of the 12 original keys
 7. the root's last child pointer is erased
    validate: MissingChild; get not tried (it could follow the erased pointer)
 8. leaf [7] gets a child pointer
    validate: UnexpectedChild; get finds 12 of the 12 original keys
 9. key 5 vanishes from leaf [1 3 5], the tree still claims 12 keys
    validate: WrongKeyCount; get finds 11 of the 12 original keys
10. a sixth node is allocated but nothing points to it
    validate: NodeCountMismatch; get finds 12 of the 12 original keys

== 5. Height: how few and how many keys fit ==
sparsest tree with 3 levels at M = 4 (7 keys):
  [4]
  [2] [6]
  [1] [3] | [5] [7]
fullest tree with 2 levels at M = 4 (15 keys):
  [4 8 12]
  [1 2 3] [5 6 7] [9 10 11] [13 14 15]
keys in a tree of h levels: 2*d^(h-1) - 1 up to M^h - 1, with d = ceil(M/2)
  M=4: h=1: 1..3 h=2: 3..15 h=3: 7..63 h=4: 15..255
  M=256: h=1: 1..255 h=2: 255..65535 h=3: 32767..16777215 h=4: 4194303..4294967295
possible heights for n keys (shortest..tallest):
  n=12: M=4: 2..3 M=16: 1..1 M=256: 1..1 M=1024: 1..1
  n=1000: M=4: 5..9 M=16: 3..3 M=256: 2..2 M=1024: 1..1
  n=1000000: M=4: 10..19 M=16: 5..7 M=256: 3..3 M=1024: 2..3
  n=1000000000: M=4: 15..29 M=16: 8..10 M=256: 4..5 M=1024: 3..4

== 6. The 2-3-4 tree as a red-black tree ==
  [6 10 20] -> 10 black, red children 6 and 20
  [1 3 5] -> 3 black, red children 1 and 5
  [7] -> 7 black
  [12 15 17] -> 15 black, red children 12 and 17
  [25 30] -> 30 black, red left child 25
red-black tree: 12 nodes, 2 black nodes on every path (B-tree height 2), paths of 3 to 4 nodes

== 7. Oracle check: 608 of the keys 0..1999 (seed 3), several orders ==
  M=3: height=6 (bounds 6..9) nodes=364 fill=83% validate ok, 2000 of 2000 lookups agree
  M=4: height=5 (bounds 5..9) nodes=241 fill=84% validate ok, 2000 of 2000 lookups agree
  M=5: height=4 (bounds 4..6) nodes=156 fill=97% validate ok, 2000 of 2000 lookups agree
  M=8: height=4 (bounds 4..5) nodes=93 fill=93% validate ok, 2000 of 2000 lookups agree
`;

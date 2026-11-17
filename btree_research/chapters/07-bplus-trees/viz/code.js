/*
 * Chapter 07 — source snippets for the code panel (classic script: no fetch under file://).
 * Trimmed from zig/src/{search,insert,delete}.zig and rust/src/{search,insert,delete}.rs.
 *
 * CHAPTER_PARTS names line ranges inside a snippet by the text of their first and last line,
 * so the highlights cannot drift when a snippet is edited.
 */
window.CHAPTER_CODE = {
  search: {
    zig: `
/// Which child of an internal node to descend into.
/// A key EQUAL to a separator goes RIGHT.
pub fn childIndex(separators: []const u64, key: u64) usize {
    return upperBound(separators, key);
}

pub fn get(tree: *const BPlusTree, key: u64) ?u64 {
    const id = findLeaf(tree, key); // always down to a leaf
    if (id == .nil) return null;
    const leaf = tree.nodes.get(id);
    const i = lowerBound(leaf.keySlice(), key);
    if (i < leaf.len and leaf.keys[i] == key) return leaf.kind.leaf.values[i];
    return null;
}`,
    rust: `
/// Which child of an internal node to descend into.
/// A key EQUAL to a separator goes RIGHT.
pub fn child_index(separators: &[u64], key: u64) -> usize {
    upper_bound(separators, key)
}

pub fn get(&self, key: u64) -> Option<u64> {
    let id = self.find_leaf(key); // always down to a leaf
    if id.is_nil() {
        return None;
    }
    let leaf = self.nodes.get(id);
    let i = lower_bound(leaf.key_slice(), key);
    (i < leaf.len && leaf.keys[i] == key).then(|| leaf.leaf().values[i])
}`
  },

  splitLeaf: {
    zig: `
fn splitLeaf(tree: *BPlusTree, left_id: NodeId) Split {
    const right_id = tree.nodes.allocAssumeCapacity(Node.initLeaf());
    const left = tree.nodes.ptr(left_id);
    const right = tree.nodes.ptr(right_id);

    // floor(M/2) entries stay, ceil(M/2) move.
    const mid = left.len / 2;
    const moved = left.len - mid;
    @memcpy(right.keys[0..moved], left.keys[mid..left.len]);
    @memcpy(right.kind.leaf.values[0..moved], left.kind.leaf.values[mid..left.len]);
    right.len = moved;
    left.len = mid;

    // left <-> old_next   becomes   left <-> right <-> old_next
    const old_next = left.kind.leaf.next;
    right.kind.leaf.prev = left_id;
    right.kind.leaf.next = old_next;
    left.kind.leaf.next = right_id;
    if (old_next != .nil) {
        tree.nodes.ptr(old_next).kind.leaf.prev = right_id;
    } else {
        tree.last_leaf = right_id; // we split the rightmost leaf
    }

    // COPY-UP: right.keys[0] goes to the parent AND stays in the leaf.
    return .{ .separator = right.keys[0], .right = right_id };
}`,
    rust: `
fn split_leaf(&mut self, left_id: NodeId) -> Split {
    let right_id = self.nodes.alloc_reserved(Node::new_leaf());
    let (left, right) = self.nodes.pair_mut(left_id, right_id);

    // floor(M/2) entries stay, ceil(M/2) move.
    let mid = left.len / 2;
    let moved = left.len - mid;
    right.keys[..moved].copy_from_slice(&left.keys[mid..left.len]);
    right.leaf_mut().values[..moved].copy_from_slice(&left.leaf().values[mid..left.len]);
    right.len = moved;
    left.len = mid;

    // left <-> old_next   becomes   left <-> right <-> old_next
    let old_next = left.leaf().next;
    right.leaf_mut().prev = left_id;
    right.leaf_mut().next = old_next;
    left.leaf_mut().next = right_id;
    // COPY-UP: right.keys[0] goes to the parent AND stays in the leaf.
    let separator = right.keys[0];
    if old_next.is_nil() {
        self.last_leaf = right_id; // we split the rightmost leaf
    } else {
        self.nodes.get_mut(old_next).leaf_mut().prev = right_id;
    }
    Split { separator, right: right_id }
}`
  },

  splitInternal: {
    zig: `
fn splitInternal(tree: *BPlusTree, left_id: NodeId) Split {
    const right_id = tree.nodes.allocAssumeCapacity(Node.initInternal());
    const left = tree.nodes.ptr(left_id);
    const right = tree.nodes.ptr(right_id);

    //   keys:      k0 .. k(mid-1) | k(mid) | k(mid+1) .. k(len-1)
    //              stay in left     goes up    move to right
    const mid = left.len / 2;
    const separator = left.keys[mid];
    const moved = left.len - mid - 1;
    @memcpy(right.keys[0..moved], left.keys[mid + 1 .. left.len]);
    @memcpy(
        right.kind.internal.children[0 .. moved + 1],
        left.kind.internal.children[mid + 1 .. left.len + 1],
    );
    right.len = moved;
    left.len = mid;

    // PUSH-UP: the separator goes to the parent and is kept in neither half.
    return .{ .separator = separator, .right = right_id };
}`,
    rust: `
fn split_internal(&mut self, left_id: NodeId) -> Split {
    let right_id = self.nodes.alloc_reserved(Node::new_internal());
    let (left, right) = self.nodes.pair_mut(left_id, right_id);

    //   keys:      k0 .. k(mid-1) | k(mid) | k(mid+1) .. k(len-1)
    //              stay in left     goes up    move to right
    let mid = left.len / 2;
    let separator = left.keys[mid];
    let moved = left.len - mid - 1;
    right.keys[..moved].copy_from_slice(&left.keys[mid + 1..left.len]);
    right.internal_mut().children[..moved + 1]
        .copy_from_slice(&left.internal().children[mid + 1..left.len + 1]);
    right.len = moved;
    left.len = mid;

    // PUSH-UP: the separator goes to the parent and is kept in neither half.
    Split { separator, right: right_id }
}`
  },

  borrow: {
    zig: `
// Leaf cases of borrowFromLeft / borrowFromRight (child i of parent).
// From the LEFT sibling: its last entry becomes our first.
const e = left.leafRemoveAt(left.len - 1);
child.leafInsertAt(0, e.key, e.value);
parent.keys[i - 1] = child.keys[0]; // fresh copy of the new first key

// From the RIGHT sibling: its first entry becomes our last.
const e = right.leafRemoveAt(0);
child.leafInsertAt(child.len, e.key, e.value);
parent.keys[i] = right.keys[0]; // fresh copy of ITS new first key`,
    rust: `
// Leaf cases of borrow_from_left / borrow_from_right (child i of parent).
// From the LEFT sibling: its last entry becomes our first.
let e = left.leaf_remove_at(left.len - 1);
child.leaf_insert_at(0, e.key, e.value);
let new_separator = child.keys[0]; // written to parent.keys[i - 1]

// From the RIGHT sibling: its first entry becomes our last.
let e = right.leaf_remove_at(0);
child.leaf_insert_at(child.len, e.key, e.value);
let new_separator = right.keys[0]; // written to parent.keys[i]`
  },

  merge: {
    zig: `
/// Merges child li + 1 into child li and frees it (always right INTO left).
fn merge(tree: *BPlusTree, parent: *Node, li: usize) void {
    // ... left, right = the two children ...
    switch (left.kind) {
        .leaf => |*leaf| {
            // The separator between two leaves was only a copy: drop it.
            @memcpy(left.keys[left.len .. left.len + right.len], right.keys[0..right.len]);
            @memcpy(leaf.values[left.len .. left.len + right.len], rl.values[0..right.len]);
            left.len += right.len;
            leaf.next = rl.next; // unlink right from the chain
            if (rl.next != .nil) {
                tree.nodes.ptr(rl.next).kind.leaf.prev = left_id;
            } else {
                tree.last_leaf = left_id;
            }
        },
        .internal => |*in| {
            // The separator between two internal nodes routes: pull it DOWN.
            left.keys[left.len] = parent.keys[li];
            @memcpy(left.keys[left.len + 1 .. left.len + 1 + right.len], right.keys[0..right.len]);
            @memcpy(in.children[left.len + 1 .. left.len + 2 + right.len], rc[0 .. right.len + 1]);
            left.len += 1 + right.len;
        },
    }
    parent.internalRemoveAt(li);
    tree.nodes.free(right_id); // slot goes to the free list
}`,
    rust: `
/// Merges child li + 1 into child li and frees it (always right INTO left).
fn merge(&mut self, parent_id: NodeId, li: usize) {
    // ... (left, right) = pair_mut of the two children ...
    if left.is_leaf() {
        // The separator between two leaves was only a copy: drop it.
        left.keys[llen..llen + rlen].copy_from_slice(&right.keys[..rlen]);
        left.leaf_mut().values[llen..llen + rlen].copy_from_slice(&right.leaf().values[..rlen]);
        left.len += rlen;
        let next = right.leaf().next; // unlink right from the chain
        left.leaf_mut().next = next;
        if next.is_nil() {
            self.last_leaf = left_id;
        } else {
            self.nodes.get_mut(next).leaf_mut().prev = left_id;
        }
    } else {
        // The separator between two internal nodes routes: pull it DOWN.
        left.keys[llen] = separator;
        left.keys[llen + 1..llen + 1 + rlen].copy_from_slice(&right.keys[..rlen]);
        left.internal_mut().children[llen + 1..llen + 2 + rlen]
            .copy_from_slice(&right.internal().children[..rlen + 1]);
        left.len += 1 + rlen;
    }
    self.nodes.get_mut(parent_id).internal_remove_at(li);
    self.nodes.free(right_id); // slot goes to the free list
}`
  }
};

/* part name → [text on the first line, text on the last line] per language */
window.CHAPTER_PARTS = {
  search: {
    route: { zig: ['pub fn childIndex', 'return upperBound'], rust: ['pub fn child_index', 'upper_bound(separators'] },
    leaf: { zig: ['const leaf =', 'if (i < leaf.len'], rust: ['let leaf =', '.then('] }
  },
  splitLeaf: {
    divide: { zig: ['const mid', 'left.len = mid;'], rust: ['let mid', 'left.len = mid;'] },
    link: { zig: ['const old_next', 'return .{'], rust: ['let old_next', 'Split {'] }
  },
  splitInternal: {
    divide: { zig: ['const mid', 'left.len = mid;'], rust: ['let mid', 'left.len = mid;'] },
    pushup: { zig: ['// PUSH-UP', 'return .{'], rust: ['// PUSH-UP', 'Split {'] }
  },
  borrow: {
    left: { zig: ['// From the LEFT', 'parent.keys[i - 1]'], rust: ['// From the LEFT', 'parent.keys[i - 1]'] },
    right: { zig: ['// From the RIGHT', 'parent.keys[i] ='], rust: ['// From the RIGHT', 'parent.keys[i]'] }
  },
  merge: {
    leaf: { zig: ['.leaf => |*leaf|', 'tree.last_leaf = left_id;'], rust: ['if left.is_leaf()', 'leaf_mut().prev = left_id;'] },
    internal: { zig: ['.internal => |*in|', 'left.len += 1 + right.len;'], rust: ['// The separator between two internal', 'left.len += 1 + rlen;'] },
    free: { zig: ['parent.internalRemoveAt', 'tree.nodes.free'], rust: ['internal_remove_at(li)', 'self.nodes.free'] }
  }
};

/* Text printed by the Zig and Rust programs (../expected_output.txt), embedded so the page can
 * check its JavaScript model against it. Sections 1 to 5 and the three lines of section 7. */
window.CHAPTER_EXPECTED = {
  sections1to5: "== 1. Build: canonical keys, order M = 4 (at most 3 keys per node) ==\nput 10: first leaf\n  height 1, 1 keys, 1 nodes\n  leaves : #0(10)\nput 20: no structural change\nput 5: no structural change\nput 6: leaf split (copy-up), new root\n  height 2, 4 keys, 3 nodes\n  level 0: #2[10]\n  leaves : #0(5 6) <-> #1(10 20)\nput 12: no structural change\nput 30: leaf split (copy-up)\n  height 2, 6 keys, 4 nodes\n  level 0: #2[10 20]\n  leaves : #0(5 6) <-> #1(10 12) <-> #3(20 30)\nput 7: no structural change\nput 17: no structural change\nput 3: leaf split (copy-up)\n  height 2, 9 keys, 5 nodes\n  level 0: #2[6 10 20]\n  leaves : #0(3 5) <-> #4(6 7) <-> #1(10 12 17) <-> #3(20 30)\nput 25: no structural change\nput 1: no structural change\nput 15: leaf split (copy-up), internal split (push-up), new root\n  height 3, 12 keys, 8 nodes\n  level 0: #7[15]\n  level 1: #2[6 10] #6[20]\n  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(15 17) <-> #3(20 25 30)\n\n== 2. The leaf chain ==\nforward  (next links): 1 3 5 6 7 10 12 15 17 20 25 30\nbackward (prev links), leaf handles: #3 #5 #1 #4 #0\nseparators: 6 10 15 20\n\n== 3. Lookups always end in a leaf ==\nget 15 = 1500\nget 12 = 1200\nget 13 = null\n\n== 4. Delete: stale separator, borrow, merge, shrink ==\ndelete 15: no structural change\n  get 15 = null, but separators: 6 10 15(stale) 20\ndelete 17: borrow\n  height 3, 10 keys, 8 nodes\n  level 0: #7[15]\n  level 1: #2[6 10] #6[25]\n  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(20) <-> #3(25 30)\ndelete 20: borrow\n  height 3, 9 keys, 8 nodes\n  level 0: #7[15]\n  level 1: #2[6 10] #6[30]\n  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(25) <-> #3(30)\ndelete 25: merge, borrow\n  height 3, 8 keys, 7 nodes\n  level 0: #7[10]\n  level 1: #2[6] #6[15]\n  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(30)\ndelete 30: borrow\n  height 3, 7 keys, 7 nodes\n  level 0: #7[10]\n  level 1: #2[6] #6[12]\n  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10) <-> #5(12)\ndelete 12: merge x2, root removed\n  height 2, 6 keys, 4 nodes\n  level 0: #2[6 10]\n  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10)\n\n== 5. Handles: freed slots are reused ==\narena: 8 slots, 4 live, 4 free; free list: #7 #6 #5 #3\nput 11: no structural change\nput 13: no structural change\nput 14: leaf split (copy-up)\n  height 2, 9 keys, 5 nodes\n  level 0: #2[6 10 13]\n  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 11) <-> #7(13 14)\narena: 8 slots, 5 live, 3 free; free list: #6 #5 #3\n\n",
  section7: "M=3  keys=322 height=7 nodes=412 slots=455 | leaf splits=908 internal splits=605 borrows=738 merges=1108 | mismatches=0\nM=4  keys=322 height=6 nodes=298 slots=310 | leaf splits=384 internal splits=111 borrows=410 merges=203 | mismatches=0\nM=16 keys=322 height=3 nodes=40 slots=43 | leaf splits=72 internal splits=6 borrows=287 merges=41 | mismatches=0\n",
  /* chapter 05's classic B-tree for the same keys (its expected_output.txt, section 1) */
  btreeCanonical: "[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]"
};

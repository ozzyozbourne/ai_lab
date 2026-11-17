/* Chapter 05 visualization data. A classic script (no fetch under file://).
 *
 * CHAPTER_CODE: the delete algorithm, condensed from zig/src/delete.zig and
 * rust/src/delete.rs. Both listings are line-aligned, so one set of line
 * numbers highlights the same statement in either language.
 *
 * CHAPTER_EXPECTED: parts 2 and 3 of ../expected_output.txt, copied verbatim.
 * index.html replays the same deletes with the JavaScript model and compares
 * the text, so the picture cannot drift from the programs.
 */
window.CHAPTER_CODE = {
  delete: {
    zig: `
fn removeFrom(node: *Node, key: u64) ?u64 {
    const i = lowerBound(node.keySlice(), key);
    if (node.leaf)                        // case 1: the key is in a leaf
        return if (found) node.removeEntry(i).value else null;
    if (found) {                          // case 2: the key is a separator
        const pred = removeMax(node.children[i].?);
        node.keys[i] = pred.key;          // predecessor takes its place
        fixUnderflow(node, i);
        return removed;
    }
    const removed = removeFrom(node.children[i].?, key) orelse return null;
    fixUnderflow(node, i);                // case 3: repair on the way back up
    return removed;
}

fn fixUnderflow(parent: *Node, i: usize) void {
    const child = parent.children[i].?;
    if (child.len >= min_keys) return;    // nothing to repair
    if (i > 0 and left.len > min_keys) {
        borrowFromLeft(parent, i);        // separator down, left's last key up
    } else if (i < parent.len and right.len > min_keys) {
        borrowFromRight(parent, i);       // separator down, right's first key up
    } else {                              // nobody can lend: merge
        const emptied = mergeChildren(parent, if (i > 0) i - 1 else i);
        pool.destroy(gpa, emptied);       // parent lost a key: may underflow
    }
}

// in delete(), after removeFrom(root, key):
if (root.len == 0) {                      // root shrink
    tree.root = if (root.leaf) null else root.children[0];
    pool.destroy(gpa, root);              // the tree is one level shorter
}`,
    rust: `
fn remove_from(tree: &mut BTree, id: NodeId, key: u64) -> Option<u64> {
    let i = lower_bound(&tree.pool[id].keys, key);
    if tree.pool[id].leaf {               // case 1: the key is in a leaf
        return found.then(|| tree.pool[id].remove_entry(i).value);
    } else if found {                     // case 2: the key is a separator
        let pred = remove_max(tree, child);
        tree.pool[id].keys[i] = pred.key; // predecessor takes its place
        fix_underflow(tree, id, i);
        return Some(removed);
    }
    let removed = remove_from(tree, child, key)?;
    fix_underflow(tree, id, i);           // case 3: repair on the way back up
    Some(removed)
}

fn fix_underflow(tree: &mut BTree, parent: NodeId, i: usize) {
    let child = tree.pool[parent].children[i];
    if tree.pool[child].len() >= min { return; }   // nothing to repair
    if i > 0 && left_len > min {
        borrow_from_left(tree, parent, i);    // separator down, left's last key up
    } else if i + 1 < child_count && right_len > min {
        borrow_from_right(tree, parent, i);   // separator down, right's first key up
    } else {                              // nobody can lend: merge
        merge_children(tree, parent, if i > 0 { i - 1 } else { i });
        // (merge_children frees the emptied node; parent lost a key)
    }
}

// in delete(), after remove_from(root, key):
if tree.pool[root].is_empty() {           // root shrink
    let old_root = tree.pool.free(root);
    tree.root = old_root.children.first().copied();   // one level shorter
}`
  }
};

/* Step type (from BTViz.models.BTree) -> lines of the listing above. */
window.CHAPTER_LINES = {
  'start': [1, 2],
  'compare': [2, 11],
  'not-found': [3, 4],
  'remove': [3, 4],
  'found-internal': [5],
  'predecessor': [6],
  'replace': [7, 8],
  'underflow': [17, 18],
  'borrow-left': [19, 20],
  'borrow-right': [21, 22],
  'merge': [[23, 25]],
  'root-shrink': [[30, 33]],
  'done': []
};

window.CHAPTER_EXPECTED = {
  canonical: '[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]\n',
  part2: `delete 3: leaf key; no underflow
  [6 10 20]
  [1 5] [7] [12 15 17] [25 30]
delete 7: leaf key; borrow from left
  [5 10 20]
  [1] [6] [12 15 17] [25 30]
delete 6: leaf key; borrow from right
  [5 12 20]
  [1] [10] [15 17] [25 30]
delete 20: interior key, replaced by its predecessor; no underflow
  [5 12 17]
  [1] [10] [15] [25 30]
delete 10: leaf key; merge
  [12 17]
  [1 5] [15] [25 30]
delete 12: interior key, replaced by its predecessor; no underflow
  [5 17]
  [1] [15] [25 30]
delete 15: leaf key; borrow from right
  [5 25]
  [1] [17] [30]
delete 17: leaf key; merge
  [25]
  [1 5] [30]
delete 30: leaf key; borrow from left
  [5]
  [1] [25]
delete 25: leaf key; merge, root shrink
  [1 5]

`,
  part3: `  [9]
  [3 6] [12]
  [1 2] [4 5] [7 8] | [10 11] [13]
delete 9: interior key, replaced by its predecessor; no underflow
  [8]
  [3 6] [12]
  [1 2] [4 5] [7] | [10 11] [13]
delete 13: leaf key; borrow from left
  [8]
  [3 6] [11]
  [1 2] [4 5] [7] | [10] [12]
delete 10: leaf key; merge, borrow from left
  [6]
  [3] [8]
  [1 2] [4 5] | [7] [11 12]
delete 1: leaf key; no underflow
  [6]
  [3] [8]
  [2] [4 5] | [7] [11 12]
delete 2: leaf key; borrow from right
  [6]
  [4] [8]
  [3] [5] | [7] [11 12]
delete 3: leaf key; 2 x merge, root shrink
  [6 8]
  [4 5] [7] [11 12]

`
};

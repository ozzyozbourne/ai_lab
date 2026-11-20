/* Chapter 04 visualization data. A classic script (no fetch under file://).
 *
 * CHAPTER_CODE: the two insert algorithms, condensed from
 * zig/src/base_insert.zig + rust/src/base_insert.rs (bottom-up) and
 * zig/src/topdown.zig + rust/src/topdown.rs (top-down). The Zig and Rust
 * listings are line-aligned, so one set of line numbers highlights the same
 * statement in either language. CHAPTER_LINES maps a step type to lines.
 *
 * CHAPTER_EXPECTED: sections of ../expected_output.txt, copied verbatim.
 * The pages replay the same inserts with the JavaScript model and compare
 * the text, so the pictures cannot drift from the programs.
 */
window.CHAPTER_CODE = {
  'bottom-up': {
    zig: `
pub fn put(tree: *Tree, gpa: Allocator, key: u64, value: u64) !?u64 {
    while (true) {                           // 1. descend, remembering the path
        const i = lowerBound(node.keySlice(), key);
        if (found) return overwrite(node, i, value);
        path[depth] = .{ .node = node, .index = i };
        depth += 1;
        if (node.leaf) break;
        node = node.children[i].?;
    }
    // 2. reserve: one node per full node in the unbroken run above the leaf
    while (reserved < need) : (reserved += 1)
        spare[reserved] = try tree.pool.create(gpa); // only this can fail
    // 3. commit: nothing below can fail
    leaf.insertEntry(path[level].index, key, value);
    while (path[level].node.len > max_keys) {   // overfull: M keys
        const median = splitNode(left, right);  // left keeps M / 2 keys
        if (level == 0) {                       // the root was split
            new_root.children[0] = left;
            new_root.insertChild(1, right);
            new_root.insertEntry(0, median.key, median.value);
            tree.root = new_root;               // the tree grows at the top
            break;
        }
        level -= 1;                             // median goes to the parent
        parent.insertChild(path[level].index + 1, right);
        parent.insertEntry(path[level].index, median.key, median.value);
    }
    return null;
}
`,
    rust: `
pub fn put(tree: &mut BTree, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
    loop {                                   // 1. descend, remembering the path
        let i = lower_bound(&node.keys, key);
        if found { return Ok(Some(overwrite(node, i, value))); }
        path[depth] = (id, i);
        depth += 1;
        if node.leaf { break; }
        id = node.children[i];
    }
    // 2. reserve: one node per full node in the unbroken run above the leaf
    for _ in 0..need {
        spare.push(tree.pool.alloc(Node::new(true))?); // only this can fail
    }   // 3. commit: nothing below can fail
    tree.pool[leaf].insert_entry(path[level].1, key, value);
    while tree.pool[path[level].0].len() > full {  // overfull: M keys
        let median = split_node(tree, left, right); // left keeps M / 2 keys
        if level == 0 {                         // the root was split
            let node = &mut tree.pool[new_root];
            node.children = vec![left, right];
            node.insert_entry(0, median.key, median.value);
            tree.root = Some(new_root);         // the tree grows at the top
            break;
        }
        level -= 1;                             // median goes to the parent
        tree.pool[parent].children.insert(at + 1, right);
        tree.pool[parent].insert_entry(at, median.key, median.value);
    }
    Ok(None)
}
`
  },
  'top-down': {
    zig: `
pub fn put(tree: *Tree, gpa: Allocator, key: u64, value: u64) !?u64 {
    if (root.len == max_keys) {              // full root: split it first
        const median = splitFull(root, right);
        new_root.children[0] = root;         // the tree grows at the top
        new_root.insertChild(1, right);
        new_root.insertEntry(0, median.key, median.value);
        node = new_root;
    }
    while (true) {                           // invariant: node is NOT full
        const i = lowerBound(node.keySlice(), key);
        if (found) return overwrite(node, i, value);
        if (node.leaf) {
            node.insertEntry(i, key, value); // room is guaranteed
            return null;
        }
        var child = node.children[i].?;
        if (child.len == max_keys) {         // full child: split before entering
            const right = try tree.pool.create(gpa);
            const median = splitFull(child, right); // halves: M/2 - 1 keys each
            node.insertChild(i + 1, right);
            node.insertEntry(i, median.key, median.value);
            if (key > median.key) child = right;
        }
        node = child;
    }
}
`,
    rust: `
pub fn put(tree: &mut BTree, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
    if tree.pool[root].len() == full {       // full root: split it first
        let median = split_full(tree, root, right);
        let node = &mut tree.pool[new_root]; // the tree grows at the top
        node.children = vec![root, right];
        node.insert_entry(0, median.key, median.value);
        id = new_root;
    }
    loop {                                   // invariant: node is NOT full
        let i = lower_bound(&node.keys, key);
        if found { return Ok(Some(overwrite(node, i, value))); }
        if node.leaf {
            node.insert_entry(i, key, value); // room is guaranteed
            return Ok(None);
        }
        let mut child = node.children[i];
        if tree.pool[child].len() == full {  // full child: split before entering
            let right = tree.pool.alloc(Node::new(true))?;
            let median = split_full(tree, child, right); // halves: M/2 - 1 keys each
            node.children.insert(i + 1, right);
            node.insert_entry(i, median.key, median.value);
            if key > median.key { child = right; }
        }
        id = child;
    }
}
`
  }
};

/* Lines to highlight per step type (same numbers in both languages). */
window.CHAPTER_LINES = {
  'bottom-up': {
    'start': [2], 'descend': [3, [5, 8]], 'exists': [4], 'new-root': [1],
    'insert-leaf': [[10, 14]], 'overflow': [15], 'split': [16, [24, 26]], 'root-grow': [16, [17, 22]], 'done': [28]
  },
  'top-down': {
    'start': [9], 'preempt-root': [2], 'root-grow-root': [[3, 7]], 'descend': [10, 16], 'preempt': [17],
    'split': [[18, 22]], 'insert-leaf': [12, 13], 'exists': [11], 'new-root': [1], 'done': [14]
  }
};

window.CHAPTER_EXPECTED = {
  part1: "put 10: no split\n  [10]\nput 20: no split\n  [10 20]\nput 5: no split\n  [5 10 20]\nput 6: 1 split, the root split: height 2\n  [10]\n  [5 6] [20]\nput 12: no split\n  [10]\n  [5 6] [12 20]\nput 30: no split\n  [10]\n  [5 6] [12 20 30]\nput 7: no split\n  [10]\n  [5 6 7] [12 20 30]\nput 17: 1 split\n  [10 20]\n  [5 6 7] [12 17] [30]\nput 3: 1 split\n  [6 10 20]\n  [3 5] [7] [12 17] [30]\nput 25: no split\n  [6 10 20]\n  [3 5] [7] [12 17] [25 30]\nput 1: no split\n  [6 10 20]\n  [1 3 5] [7] [12 17] [25 30]\nput 15: no split\n  [6 10 20]\n  [1 3 5] [7] [12 15 17] [25 30]\nshape: height=2 nodes=5 leaves=4 keys=12 fill=80% splits=3 root_splits=1\none more key, 2: a leaf splits, then the full root above it (the first split of an interior node)\nput 2: 2 splits, the root split: height 3\n  [10]\n  [3 6] [20]\n  [1 2] [5] [7] | [12 15 17] [25 30]\n",
  part2: "put 10: no split\nput 20: no split\nput 5: no split\nput 6: 1 split, the root split: height 2\nput 12: no split\nput 30: no split\nput 7: no split\nput 17: 1 split\nput 3: 1 split\nput 25: 1 split, the root split: height 3\nput 1: no split\nput 15: no split\n  [10]\n  [6] [20]\n  [1 3 5] [7] | [12 15 17] [25 30]\nshape: height=3 nodes=7 leaves=4 keys=12 fill=57% splits=4 root_splits=2\nsame keys and values as the bottom-up tree: yes\n",
  part3: "both trees before:\n  [3 6 9]\n  [1 2] [4 5] [7 8] [10 11 12]\nbottom-up put 13: OutOfMemory; splits done: 0; keys: 12; tree unchanged:\n  [3 6 9]\n  [1 2] [4 5] [7 8] [10 11 12]\ntop-down put 13: OutOfMemory; splits done: 1; keys: 12; valid tree, same keys, new shape:\n  [6]\n  [3] [9]\n  [1 2] [4 5] | [7 8] [10 11 12]\nwith memory again, bottom-up put 13:\n  [9]\n  [3 6] [12]\n  [1 2] [4 5] [7 8] | [10 11] [13]\nwith memory again, top-down put 13:\n  [6]\n  [3] [9 11]\n  [1 2] [4 5] | [7 8] [10] [12 13]\n",
  part4: "   M  keys       variant    height   nodes    fill  splits  per 1000 puts  most in one put\n   3  ascending  bottom-up      16   99994   50.0%   99978          999.7               15\n   4  ascending  bottom-up      11   50002   66.6%   49991          499.9               10\n   5  ascending  bottom-up      10   49995   50.0%   49985          499.8                9\n   8  ascending  bottom-up       7   24999   57.1%   24992          249.9                6\n  16  ascending  bottom-up       5   12498   53.3%   12493          124.9                4\n  32  ascending  bottom-up       4    6249   51.6%    6245           62.4                3\n  64  ascending  bottom-up       4    3124   50.8%    3120           31.2                3\n 128  ascending  bottom-up       3    1562   50.4%    1559           15.5                2\n 256  ascending  bottom-up       3     782   50.1%     779            7.7                2\n   3  random     bottom-up      14   74697   66.9%   74683          746.8               13\n   4  random     bottom-up      11   51865   64.2%   51854          518.5               10\n   5  random     bottom-up       9   37038   67.4%   37029          370.2                8\n   8  random     bottom-up       7   21203   67.3%   21196          211.9                6\n  16  random     bottom-up       5    9731   68.5%    9726           97.2                4\n  32  random     bottom-up       4    4677   68.9%    4673           46.7                3\n  64  random     bottom-up       3    2280   69.6%    2277           22.7                2\n 128  random     bottom-up       3    1124   70.0%    1121           11.2                2\n 256  random     bottom-up       3     529   74.1%     526            5.2                2\nreferences: all nodes at the minimum = about 50%; textbook (Yao 1978), random inserts, large M: ln 2 = 69.3%\n",
  part5: "   M  keys       variant    height   nodes    fill  splits  per 1000 puts  most in one put\n   4  ascending  bottom-up      11   50002   66.6%   49991          499.9               10\n   4  ascending  top-down       16   99990   33.3%   99974          999.7                3\n   8  ascending  bottom-up       7   24999   57.1%   24992          249.9                6\n   8  ascending  top-down        8   33329   42.8%   33321          333.2                2\n  16  ascending  bottom-up       5   12498   53.3%   12493          124.9                4\n  16  ascending  top-down        6   14285   46.6%   14279          142.7                1\n  64  ascending  bottom-up       4    3124   50.8%    3120           31.2                3\n  64  ascending  top-down        4    3226   49.2%    3222           32.2                1\n 256  ascending  bottom-up       3     782   50.1%     779            7.7                2\n 256  ascending  top-down        3     788   49.7%     785            7.8                1\n   4  random     bottom-up      11   51865   64.2%   51854          518.5               10\n   4  random     top-down       13   56970   58.5%   56957          569.5                4\n   8  random     bottom-up       7   21203   67.3%   21196          211.9                6\n   8  random     top-down        7   21626   66.0%   21619          216.1                3\n  16  random     bottom-up       5    9731   68.5%    9726           97.2                4\n  16  random     top-down        5    9806   67.9%    9801           98.0                2\n  64  random     bottom-up       3    2280   69.6%    2277           22.7                2\n  64  random     top-down        4    2304   68.8%    2300           23.0                2\n 256  random     bottom-up       3     529   74.1%     526            5.2                2\n 256  random     top-down        3     528   74.2%     525            5.2                1\n"
};

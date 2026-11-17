//! A compact in-memory B+tree whose nodes play the role of disk pages.
//!
//! Everything in this chapter is about *how the tree gets built*, so the tree
//! itself is kept as small as possible:
//!
//!   * keys and values are u64, duplicates are rejected (put overwrites);
//!   * nodes have a fixed capacity and live in one `Vec` (`nodes`); a node is
//!     named by its index, which stands in for a page id;
//!   * there is no delete (chapters 05, 07 and 15 cover it);
//!   * every time a node would have to be written back to disk we bump
//!     `stats.page_writes`. That counter is the measuring stick of the chapter.
//!
//! Node layout. Leaf and interior nodes use the same two arrays:
//!
//! ```text
//!     leaf:      keys[i] -> slots[i] is a value          (len entries)
//!     interior:  slots[i] is a child id                  (len children)
//!                keys[i], i >= 1, is the separator: every key in child i
//!                is >= keys[i] and every key in child i-1 is < keys[i]
//!                keys[0] is IGNORED by search ("minus infinity")
//! ```
//!
//! Storing an ignored key in slot 0 keeps both node kinds a plain list of
//! (key, pointer) pairs, which is exactly the shape the bulk loader produces.
//! PostgreSQL does the same: the first item on an internal page is a "minus
//! infinity" item whose key is never compared.

/// Largest supported order. Fixed so that a node is a fixed-size struct, like
/// a page. One extra array slot lets a node overflow by one before it splits.
pub const MAX_ORDER: usize = 32;
/// "No node": used for an empty tree's root and the last leaf's `next`.
pub const NIL: u32 = u32::MAX;
/// A tree of order >= 3 with 2^32 node ids cannot be taller than this.
pub const MAX_HEIGHT: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    pub key: u64,
    pub value: u64,
}

#[derive(Debug, Clone)]
pub struct Node {
    pub is_leaf: bool,
    pub len: usize,
    /// Leaves only: id of the next leaf to the right, or `NIL`.
    pub next: u32,
    pub keys: [u64; MAX_ORDER + 1],
    pub slots: [u64; MAX_ORDER + 1],
}

impl Node {
    fn new(is_leaf: bool) -> Self {
        Self { is_leaf, len: 0, next: NIL, keys: [0; MAX_ORDER + 1], slots: [0; MAX_ORDER + 1] }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    /// Nodes written back. One insert that splits nothing writes 1 page; each
    /// split writes the two halves; a new root is one more write.
    pub page_writes: u64,
    /// Nodes read by `put` on its way down (one per level).
    pub page_reads: u64,
    /// Node splits performed by `put`.
    pub splits: u64,
}

/// What the tree looks like, for the report and the tests.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Shape {
    pub height: usize,
    pub leaves: usize,
    pub inner: usize,
    pub entries: usize,
}

impl Shape {
    pub fn pages(&self) -> usize {
        self.leaves + self.inner
    }
}

/// Zig's `error.OutOfMemory` becomes a node budget here: the tree refuses to
/// grow past `max_nodes`, which lets tests exercise the same failure paths.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    OutOfNodes,
    /// Bulk loader: the key is not greater than the previous one.
    NotSorted,
    /// Bulk loader: an earlier call ran out of nodes and the load was abandoned.
    LoaderClosed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Invalid {
    KeysOutOfOrder,
    KeyOutOfBounds,
    Underfull,
    Overfull,
    UnevenDepth,
    BrokenLeafChain,
    CountMismatch,
}

#[derive(Debug)]
pub struct Tree {
    /// Order M = maximum number of children (Knuth). 3 <= M <= MAX_ORDER.
    pub order: usize,
    /// The typed arena: nodes are addressed by `u32` index, never by pointer.
    pub nodes: Vec<Node>,
    pub root: u32,
    /// Number of levels; 0 for an empty tree, 1 when the root is a leaf.
    pub height: usize,
    /// Number of key/value pairs.
    pub count: usize,
    pub stats: Stats,
    max_nodes: usize,
}

/// Iterator over the entries with lo <= key < hi, ascending. It walks the
/// leaf chain, so it also proves that the loader linked the leaves.
pub struct RangeIter<'a> {
    tree: &'a Tree,
    node: u32,
    pos: usize,
    hi: u64,
}

impl Iterator for RangeIter<'_> {
    type Item = Entry;

    fn next(&mut self) -> Option<Entry> {
        while self.node != NIL {
            let leaf = &self.tree.nodes[self.node as usize];
            if self.pos < leaf.len {
                let key = leaf.keys[self.pos];
                if key >= self.hi {
                    return None;
                }
                self.pos += 1;
                return Some(Entry { key, value: leaf.slots[self.pos - 1] });
            }
            self.node = leaf.next;
            self.pos = 0;
        }
        None
    }
}

/// State threaded through `check`: the leaf seen last and the entries so far.
struct Walk {
    prev_leaf: u32,
    entries: usize,
}

impl Tree {
    pub fn new(order: usize) -> Self {
        Self::with_budget(order, usize::MAX)
    }

    /// A tree that may hold at most `max_nodes` nodes.
    pub fn with_budget(order: usize, max_nodes: usize) -> Self {
        assert!((3..=MAX_ORDER).contains(&order));
        Self { order, nodes: Vec::new(), root: NIL, height: 0, count: 0, stats: Stats::default(), max_nodes }
    }

    // ---- capacities (all in "pairs", see the node layout above) ----

    pub fn leaf_cap(&self) -> usize {
        self.order - 1
    }
    pub fn inner_cap(&self) -> usize {
        self.order
    }
    /// ceil(M/2) - 1 keys, but never less than one.
    pub fn leaf_min(&self) -> usize {
        (self.order.div_ceil(2) - 1).max(1)
    }
    /// ceil(M/2) children.
    pub fn inner_min(&self) -> usize {
        self.order.div_ceil(2)
    }
    pub fn cap(&self, is_leaf: bool) -> usize {
        if is_leaf { self.leaf_cap() } else { self.inner_cap() }
    }
    pub fn min(&self, is_leaf: bool) -> usize {
        if is_leaf { self.leaf_min() } else { self.inner_min() }
    }

    /// Append a blank node and return its id. This only reserves the page id;
    /// it does not count as a page write.
    pub fn alloc_node(&mut self, is_leaf: bool) -> Result<u32, Error> {
        if self.nodes.len() >= self.max_nodes {
            return Err(Error::OutOfNodes);
        }
        self.nodes.push(Node::new(is_leaf));
        Ok((self.nodes.len() - 1) as u32)
    }

    // ---- search ----

    /// Which child of an interior node covers `key`: the last i with
    /// keys[i] <= key, where keys[0] counts as minus infinity.
    fn child_index(node: &Node, key: u64) -> usize {
        let mut i = 1;
        while i < node.len && node.keys[i] <= key {
            i += 1;
        }
        i - 1
    }

    /// First position in a leaf whose key is >= `key` (may be node.len).
    fn lower_bound(node: &Node, key: u64) -> usize {
        let mut i = 0;
        while i < node.len && node.keys[i] < key {
            i += 1;
        }
        i
    }

    fn find_leaf(&self, key: u64) -> u32 {
        let mut id = self.root;
        while !self.nodes[id as usize].is_leaf {
            let node = &self.nodes[id as usize];
            id = node.slots[Self::child_index(node, key)] as u32;
        }
        id
    }

    pub fn get(&self, key: u64) -> Option<u64> {
        if self.root == NIL {
            return None;
        }
        let leaf = &self.nodes[self.find_leaf(key) as usize];
        let pos = Self::lower_bound(leaf, key);
        (pos < leaf.len && leaf.keys[pos] == key).then(|| leaf.slots[pos])
    }

    pub fn range(&self, lo: u64, hi: u64) -> RangeIter<'_> {
        if self.root == NIL || lo >= hi {
            return RangeIter { tree: self, node: NIL, pos: 0, hi };
        }
        let id = self.find_leaf(lo);
        RangeIter { tree: self, node: id, pos: Self::lower_bound(&self.nodes[id as usize], lo), hi }
    }

    // ---- one-by-one insert (the path the bulk loader is compared against) ----

    /// Insert or overwrite. On `Err(OutOfNodes)` the tree is unchanged.
    pub fn put(&mut self, key: u64, value: u64) -> Result<(), Error> {
        if self.root == NIL {
            let id = self.alloc_node(true)?;
            let leaf = &mut self.nodes[id as usize];
            leaf.keys[0] = key;
            leaf.slots[0] = value;
            leaf.len = 1;
            self.root = id;
            self.height = 1;
            self.count = 1;
            self.stats.page_writes += 1;
            return Ok(());
        }

        // 1. Descend, remembering the path: path[d] is the node at depth d and
        //    idx[d] the child slot we took out of it.
        let mut path = [NIL; MAX_HEIGHT];
        let mut idx = [0usize; MAX_HEIGHT];
        let mut depth = 0;
        let mut id = self.root;
        loop {
            path[depth] = id;
            self.stats.page_reads += 1;
            let node = &self.nodes[id as usize];
            if node.is_leaf {
                break;
            }
            idx[depth] = Self::child_index(node, key);
            id = node.slots[idx[depth]] as u32;
            depth += 1;
        }

        let leaf = &mut self.nodes[id as usize];
        let pos = Self::lower_bound(leaf, key);
        if pos < leaf.len && leaf.keys[pos] == key {
            leaf.slots[pos] = value; // overwrite: one page written, no growth
            self.stats.page_writes += 1;
            return Ok(());
        }

        // 2. Check the budget for every node this insert can create BEFORE
        //    changing anything: one new node per full node at the bottom of
        //    the path, plus a new root if the whole path is full. After this
        //    check nothing can fail, so a failure never leaves a half-done
        //    split.
        let mut needed = 0;
        for d in (0..=depth).rev() {
            let n = &self.nodes[path[d] as usize];
            if n.len < self.cap(n.is_leaf) {
                break;
            }
            needed += 1;
        }
        if needed == depth + 1 {
            needed += 1; // root splits too
        }
        if self.max_nodes - self.nodes.len() < needed {
            return Err(Error::OutOfNodes);
        }

        // 3. Insert into the leaf, then walk back up while nodes overflow.
        Self::insert_at(&mut self.nodes[id as usize], pos, key, value);
        self.count += 1;
        let mut d = depth;
        loop {
            let node_id = path[d];
            let is_leaf = self.nodes[node_id as usize].is_leaf;
            if self.nodes[node_id as usize].len <= self.cap(is_leaf) {
                self.stats.page_writes += 1;
                return Ok(());
            }
            // Overflow by one: split 50/50. The right half's first key is the
            // separator. In a leaf it is *copied* up (the entry stays in the
            // leaf); in an interior node it moves into the ignored slot 0 of
            // the right half, which amounts to pushing it up.
            let right_id = self.nodes.len() as u32;
            let mut right = Node::new(is_leaf);
            let left = &mut self.nodes[node_id as usize];
            let keep = left.len - left.len / 2;
            right.len = left.len - keep;
            right.keys[..right.len].copy_from_slice(&left.keys[keep..left.len]);
            right.slots[..right.len].copy_from_slice(&left.slots[keep..left.len]);
            left.len = keep;
            if is_leaf {
                right.next = left.next;
                left.next = right_id;
            }
            let sep = right.keys[0];
            self.nodes.push(right);
            self.stats.page_writes += 2;
            self.stats.splits += 1;

            if d == 0 {
                // The root split: grow the tree by one level.
                let mut root = Node::new(false);
                root.keys[0] = 0; // ignored
                root.slots[0] = u64::from(node_id);
                root.keys[1] = sep;
                root.slots[1] = u64::from(right_id);
                root.len = 2;
                self.root = self.nodes.len() as u32;
                self.nodes.push(root);
                self.height += 1;
                self.stats.page_writes += 1;
                return Ok(());
            }
            d -= 1;
            Self::insert_at(&mut self.nodes[path[d] as usize], idx[d] + 1, sep, u64::from(right_id));
        }
    }

    /// Shift pairs [pos, len) one to the right and put (key, slot) at pos.
    fn insert_at(node: &mut Node, pos: usize, key: u64, slot: u64) {
        node.keys.copy_within(pos..node.len, pos + 1);
        node.slots.copy_within(pos..node.len, pos + 1);
        node.keys[pos] = key;
        node.slots[pos] = slot;
        node.len += 1;
    }

    // ---- inspection ----

    pub fn shape(&self) -> Shape {
        let mut s = Shape { height: self.height, ..Shape::default() };
        if self.root != NIL {
            self.shape_of(self.root, &mut s);
        }
        s
    }

    fn shape_of(&self, id: u32, s: &mut Shape) {
        let node = &self.nodes[id as usize];
        if node.is_leaf {
            s.leaves += 1;
            s.entries += node.len;
        } else {
            s.inner += 1;
            for &child in &node.slots[..node.len] {
                self.shape_of(child as u32, s);
            }
        }
    }

    /// Check every invariant of the structure:
    ///   1. keys inside a node are strictly ascending;
    ///   2. every key lies inside the bounds its ancestors' separators promise;
    ///   3. every node except the root holds at least the minimum, none more
    ///      than the capacity; an interior root has at least two children;
    ///   4. all leaves are at the same depth;
    ///   5. the leaf chain visits the leaves left to right and ends with NIL;
    ///   6. `count` equals the number of entries in the leaves.
    pub fn validate(&self) -> Result<(), Invalid> {
        if self.root == NIL {
            if self.count != 0 || self.height != 0 {
                return Err(Invalid::CountMismatch);
            }
            return Ok(());
        }
        let mut walk = Walk { prev_leaf: NIL, entries: 0 };
        self.check(self.root, None, None, 1, &mut walk)?;
        if walk.prev_leaf != NIL && self.nodes[walk.prev_leaf as usize].next != NIL {
            return Err(Invalid::BrokenLeafChain);
        }
        if walk.entries != self.count {
            return Err(Invalid::CountMismatch);
        }
        Ok(())
    }

    fn check(&self, id: u32, lo: Option<u64>, hi: Option<u64>, depth: usize, walk: &mut Walk) -> Result<(), Invalid> {
        let node = &self.nodes[id as usize];
        let is_root = id == self.root;
        if node.len > self.cap(node.is_leaf) {
            return Err(Invalid::Overfull);
        }
        let least = if !is_root {
            self.min(node.is_leaf)
        } else if node.is_leaf {
            1
        } else {
            2
        };
        if node.len < least {
            return Err(Invalid::Underfull);
        }

        if node.is_leaf {
            if depth != self.height {
                return Err(Invalid::UnevenDepth);
            }
            for i in 0..node.len {
                let key = node.keys[i];
                if i > 0 && node.keys[i - 1] >= key {
                    return Err(Invalid::KeysOutOfOrder);
                }
                if lo.is_some_and(|lo| key < lo) || hi.is_some_and(|hi| key >= hi) {
                    return Err(Invalid::KeyOutOfBounds);
                }
            }
            // In-order traversal meets the leaves left to right, so the leaf
            // seen just before this one must point here.
            if walk.prev_leaf != NIL && self.nodes[walk.prev_leaf as usize].next != id {
                return Err(Invalid::BrokenLeafChain);
            }
            walk.prev_leaf = id;
            walk.entries += node.len;
            return Ok(());
        }

        for i in 0..node.len {
            // keys[0] is ignored: child 0 inherits the lower bound from above.
            let child_lo = if i == 0 { lo } else { Some(node.keys[i]) };
            let child_hi = if i + 1 < node.len { Some(node.keys[i + 1]) } else { hi };
            if i >= 1 {
                let key = node.keys[i];
                if i >= 2 && node.keys[i - 1] >= key {
                    return Err(Invalid::KeysOutOfOrder);
                }
                if lo.is_some_and(|lo| key <= lo) || hi.is_some_and(|hi| key >= hi) {
                    return Err(Invalid::KeyOutOfBounds);
                }
            }
            self.check(node.slots[i] as u32, child_lo, child_hi, depth + 1, walk)?;
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
pub fn assert_same_entries(expected: &[crate::ops::Entry], tree: &Tree, lo: u64, hi: u64) {
    let got: Vec<(u64, u64)> = tree.range(lo, hi).map(|e| (e.key, e.value)).collect();
    let want: Vec<(u64, u64)> = expected.iter().map(|e| (e.key, e.value)).collect();
    assert_eq!(got, want);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ops::{Config, Op, OpStream, Oracle, Weights};

    #[test]
    fn empty_tree() {
        let tree = Tree::new(4);
        assert_eq!(tree.validate(), Ok(()));
        assert_eq!(tree.get(1), None);
        assert_eq!(tree.range(0, 100).next(), None);
    }

    #[test]
    fn ascending_inserts_leave_leaves_half_full() {
        let mut tree = Tree::new(4);
        for k in 1..14 {
            tree.put(k, k * 10).unwrap();
        }
        assert_eq!(tree.validate(), Ok(()));
        let s = tree.shape();
        // 13 keys, leaf capacity 3: a 50/50 split of a full leaf leaves 2 behind,
        // and nothing is ever added to a left half again.
        assert_eq!(s.leaves, 6);
        assert_eq!(s.height, 3);
        assert_eq!(s.entries, 13);
        for k in 1..14 {
            assert_eq!(tree.get(k), Some(k * 10));
        }
        assert_eq!(tree.get(14), None);
    }

    #[test]
    fn put_overwrites() {
        let mut tree = Tree::new(4);
        tree.put(5, 1).unwrap();
        tree.put(5, 2).unwrap();
        assert_eq!(tree.count, 1);
        assert_eq!(tree.get(5), Some(2));
    }

    #[test]
    fn model_test_put_get_range_against_the_oracle() {
        for order in [3usize, 4, 5, 8] {
            let mut tree = Tree::new(order);
            let mut oracle = Oracle::new();
            let stream = OpStream::new(Config {
                seed: 16 + order as u64,
                count: 4000,
                key_space: 300,
                weights: Weights { put: 5, delete: 0, get: 3, range: 2 },
            });
            for op in stream {
                match op {
                    Op::Put { key, value } => {
                        tree.put(key, value).unwrap();
                        oracle.put(key, value);
                    }
                    Op::Delete { .. } => unreachable!("weight 0: this chapter's tree has no delete"),
                    Op::Get { key } => assert_eq!(tree.get(key), oracle.get(key)),
                    Op::Range { lo, hi } => assert_same_entries(oracle.range(lo, hi), &tree, lo, hi),
                }
            }
            assert_eq!(tree.validate(), Ok(()));
            assert_eq!(tree.count, oracle.len());
        }
    }

    #[test]
    fn put_under_a_node_budget_leaves_the_tree_unchanged() {
        // Allow 0, 1, 2, ... nodes until a run succeeds. Whenever put fails,
        // everything inserted before must still be there.
        let mut budget = 0;
        loop {
            let mut tree = Tree::with_budget(4, budget);
            let mut inserted = 0u64;
            let mut failed = false;
            while inserted < 200 {
                if tree.put(inserted * 3, inserted) == Err(Error::OutOfNodes) {
                    failed = true;
                    break;
                }
                inserted += 1;
            }
            assert_eq!(tree.validate(), Ok(()));
            assert_eq!(tree.count as u64, inserted);
            for k in 0..inserted {
                assert_eq!(tree.get(k * 3), Some(k));
            }
            if !failed {
                break;
            }
            budget += 1;
        }
        assert!(budget > 0);
    }

    #[test]
    fn validate_catches_a_broken_separator_and_a_broken_leaf_chain() {
        let mut tree = Tree::new(4);
        for k in 1..14 {
            tree.put(k, k).unwrap();
        }
        let first_leaf = tree.find_leaf(0) as usize;
        let saved = tree.nodes[first_leaf].clone();
        tree.nodes[first_leaf].keys[1] = 0;
        assert_eq!(tree.validate(), Err(Invalid::KeysOutOfOrder));
        tree.nodes[first_leaf] = saved.clone();
        tree.nodes[first_leaf].next = NIL;
        assert_eq!(tree.validate(), Err(Invalid::BrokenLeafChain));
        tree.nodes[first_leaf] = saved;
        assert_eq!(tree.validate(), Ok(()));
    }
}

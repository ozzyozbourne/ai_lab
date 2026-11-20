//! An unbalanced binary search tree (BST) that counts node visits.
//!
//! The BST fixes the sorted array's write problem: inserting a key allocates
//! one node and changes one pointer; nothing is shifted. It pays for this
//! twice:
//!
//!   1. Every step of a lookup follows a pointer to a node that can be
//!      anywhere in memory (or on disk). In the cost model of this chapter
//!      each node visit is one page read.
//!   2. Nothing keeps the tree shallow. Insert keys in ascending order and
//!      the "tree" is a linked list: height = number of keys.
//!
//! A B-tree keeps the pointer idea but puts hundreds of keys in each node
//! (few page reads) and keeps all leaves at the same depth (no bad order).
//!
//! Invariant (checked by `validate`): for every node, all keys in its left
//! subtree are smaller and all keys in its right subtree are larger.

use crate::cost::{Entry, PAGE_SIZE, Trace};
use std::cmp::Ordering;

/// `put` needed a new node and the node budget is used up.
/// (The Zig version gets `error.OutOfMemory` from its allocator instead.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutOfNodes;

/// A zero-sized marker with page alignment. A `Node<PageAligned>` is forced
/// to start on a page boundary and is padded to a whole page, so every node
/// gets a page of its own: the Rust stand-in for Zig's `page_allocator`.
#[derive(Debug, Default)]
#[repr(align(4096))]
pub struct PageAligned;

/// `P` only influences the layout: `()` for an ordinary 32-byte node,
/// `PageAligned` for one page per node.
#[derive(Debug)]
pub struct Node<P> {
    key: u64,
    value: u64,
    left: Link<P>,
    right: Link<P>,
    _layout: P,
}

/// An owning pointer to a child, or nothing. `Box` is one heap allocation.
type Link<P> = Option<Box<Node<P>>>;

#[derive(Debug)]
pub struct Bst<P = ()> {
    root: Link<P>,
    len: usize,
    /// Maximum number of nodes, or None for "as many as memory allows".
    budget: Option<usize>,
}

impl<P: Default> Default for Bst<P> {
    fn default() -> Self {
        Self::new()
    }
}

impl<P: Default> Bst<P> {
    pub fn new() -> Self {
        Self {
            root: None,
            len: 0,
            budget: None,
        }
    }

    /// A tree that refuses to hold more than `budget` nodes.
    pub fn with_budget(budget: usize) -> Self {
        Self {
            root: None,
            len: 0,
            budget: Some(budget),
        }
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn get(&self, key: u64) -> Option<u64> {
        self.get_traced(key, &mut Trace::new())
    }

    /// `get` that also reports what the lookup cost: one comparison and one
    /// page read per node on the path.
    pub fn get_traced(&self, key: u64, trace: &mut Trace) -> Option<u64> {
        let mut current = &self.root;
        while let Some(node) = current {
            trace.comparisons += 1;
            trace.page_reads += 1; // model: every node lives on its own page
            match key.cmp(&node.key) {
                Ordering::Equal => return Some(node.value),
                Ordering::Less => current = &node.left,
                Ordering::Greater => current = &node.right,
            }
        }
        None
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    /// On `Err(OutOfNodes)` the tree is unchanged.
    pub fn put(&mut self, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
        // `link` is the place we would have to change: first the root field,
        // then the left or right field of some node. When it holds None we
        // have found the place where the key belongs.
        let mut link = &mut self.root;
        while let Some(node) = link {
            match key.cmp(&node.key) {
                Ordering::Equal => return Ok(Some(std::mem::replace(&mut node.value, value))),
                Ordering::Less => link = &mut node.left,
                Ordering::Greater => link = &mut node.right,
            }
        }
        // Check the budget last: if this fails, nothing has been modified yet.
        if self.budget == Some(self.len) {
            return Err(OutOfNodes);
        }
        // The only write to existing memory: one pointer.
        *link = Some(Box::new(Node {
            key,
            value,
            left: None,
            right: None,
            _layout: P::default(),
        }));
        self.len += 1;
        Ok(None)
    }

    /// Remove a key. Returns the removed value, or None if it was absent.
    pub fn delete(&mut self, key: u64) -> Option<u64> {
        let mut link = &mut self.root;
        loop {
            // Compare first, then move `link`: borrowing the node inside the
            // `match` arms would keep `link` borrowed after the loop.
            match key.cmp(&link.as_ref()?.key) {
                Ordering::Equal => break,
                Ordering::Less => link = &mut link.as_mut()?.left,
                Ordering::Greater => link = &mut link.as_mut()?.right,
            }
        }
        // Take the node out of the tree; `link` now holds None.
        let mut node = link.take()?;
        *link = match (node.left.take(), node.right.take()) {
            // At most one child: that child (or nothing) takes the node's place.
            (None, child) | (child, None) => child,
            // Two children: the successor (the smallest key of the right
            // subtree) takes the node's place. Zig copies the successor's
            // entry into the node; here the successor NODE is re-linked,
            // which gives the same tree shape without copying.
            (Some(left), Some(right)) => {
                let (mut successor, rest) = detach_min(right);
                successor.left = Some(left);
                successor.right = rest;
                Some(successor)
            }
        };
        self.len -= 1;
        Some(node.value)
    }

    // `range`, `height` and `validate` have to visit a whole subtree, so they
    // must remember where to continue after finishing one side. Recursion
    // remembers that on the call stack, one frame per level, and an
    // unbalanced tree can have as many levels as it has nodes: 20000 nodes
    // inserted in ascending order would need 20000 frames, more than a Rust
    // test thread's 2 MiB stack holds. All three therefore keep the pending
    // work in a `Vec` on the heap, which can grow as long as there is memory.

    /// All entries with lo <= key < hi, ascending.
    pub fn range(&self, lo: u64, hi: u64) -> Vec<Entry> {
        let mut out = Vec::new();
        // In-order walk. `pending` holds the nodes whose left subtree is
        // being visited: their own entry and their right subtree come later.
        let mut pending: Vec<&Node<P>> = Vec::new();
        let mut current = self.root.as_deref();
        loop {
            while let Some(node) = current {
                if node.key < lo {
                    // The node and its whole left subtree are below the range.
                    current = node.right.as_deref();
                } else {
                    pending.push(node);
                    // Keys equal to `lo` cannot have anything useful on the left.
                    current = if lo < node.key {
                        node.left.as_deref()
                    } else {
                        None
                    };
                }
            }
            let Some(node) = pending.pop() else { break };
            // Everything still pending is larger than this node: stop early.
            if node.key >= hi {
                break;
            }
            out.push(Entry {
                key: node.key,
                value: node.value,
            });
            current = node.right.as_deref();
        }
        out
    }

    /// Number of nodes on the longest path from the root down (0 if empty).
    /// This is the worst-case number of page reads for one lookup.
    pub fn height(&self) -> usize {
        let mut pending: Vec<(&Node<P>, usize)> = Vec::new();
        pending.extend(self.root.as_deref().map(|root| (root, 1)));
        let mut deepest = 0;
        while let Some((node, depth)) = pending.pop() {
            deepest = deepest.max(depth);
            pending.extend(node.left.as_deref().map(|left| (left, depth + 1)));
            pending.extend(node.right.as_deref().map(|right| (right, depth + 1)));
        }
        deepest
    }

    /// Check the search-tree invariant and that `len` matches the node count.
    pub fn validate(&self) -> Result<(), &'static str> {
        // Every key in the subtree below `node` must lie strictly between
        // `low` and `high` (None = unbounded).
        type Bounds = (Option<u64>, Option<u64>);
        let mut pending: Vec<(&Node<P>, Bounds)> = Vec::new();
        pending.extend(self.root.as_deref().map(|root| (root, (None, None))));
        let mut count = 0;
        while let Some((node, (low, high))) = pending.pop() {
            if low.is_some_and(|l| node.key <= l) || high.is_some_and(|h| node.key >= h) {
                return Err("key out of order");
            }
            count += 1;
            // Going left tightens the upper bound, going right the lower one.
            let key = Some(node.key);
            pending.extend(node.left.as_deref().map(|left| (left, (low, key))));
            pending.extend(node.right.as_deref().map(|right| (right, (key, high))));
        }
        if count != self.len {
            return Err("len does not match the number of nodes");
        }
        Ok(())
    }

    /// How many distinct 4096-byte pages of REAL memory hold the nodes on the
    /// search path for `key`? This looks at actual addresses, so the answer
    /// depends on where the allocator put the nodes: that is the point.
    pub fn pages_on_path(&self, key: u64) -> u64 {
        let mut trace = Trace::new();
        let mut current = &self.root;
        while let Some(node) = current {
            // A path longer than 64 nodes would overflow the trace; stop there.
            if trace.page_reads == Trace::SEEN_CAPACITY {
                break;
            }
            let address = std::ptr::from_ref::<Node<P>>(node).addr();
            trace.touch((address / PAGE_SIZE) as u64);
            match key.cmp(&node.key) {
                Ordering::Equal => break,
                Ordering::Less => current = &node.left,
                Ordering::Greater => current = &node.right,
            }
        }
        trace.page_reads
    }
}

/// Free every node without recursion. The drop code that Rust generates for
/// `Option<Box<Node>>` is recursive: a degenerate tree is as deep as it is
/// large, and dropping it that way would overflow the stack.
impl<P> Drop for Bst<P> {
    fn drop(&mut self) {
        let mut pending: Vec<Box<Node<P>>> = Vec::new();
        pending.extend(self.root.take());
        while let Some(mut node) = pending.pop() {
            pending.extend(node.left.take());
            pending.extend(node.right.take());
            // `node` is dropped here with both links empty: no recursion.
        }
    }
}

/// Split a non-empty subtree into its smallest node and everything else.
fn detach_min<P>(mut root: Box<Node<P>>) -> (Box<Node<P>>, Link<P>) {
    if root.left.is_none() {
        let rest = root.right.take();
        return (root, rest);
    }
    // Walk left until `parent.left` is the node with no left child.
    let mut parent = &mut root;
    while parent
        .left
        .as_ref()
        .is_some_and(|child| child.left.is_some())
    {
        parent = parent.left.as_mut().expect("checked by the loop condition");
    }
    let mut min = parent
        .left
        .take()
        .expect("root.left was Some and we only walked left");
    parent.left = min.right.take();
    (min, Some(root))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ops::{Config, Op, OpStream, Oracle, Weights};

    /// The guide's canonical keys (chapters 03 to 08 insert the same sequence).
    const CANONICAL: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

    fn leaf(key: u64) -> Box<Node<()>> {
        Box::new(Node {
            key,
            value: key,
            left: None,
            right: None,
            _layout: (),
        })
    }

    #[test]
    fn put_get_and_node_visits_on_the_canonical_keys() {
        let mut tree: Bst = Bst::new();
        for k in CANONICAL {
            assert_eq!(tree.put(k, k * 10), Ok(None));
        }
        tree.validate().unwrap();
        assert_eq!(tree.len(), 12);
        assert_eq!(tree.height(), 5);

        // 10 -> 20 -> 12 -> 17: four nodes, four page reads.
        let mut trace = Trace::new();
        assert_eq!(tree.get_traced(17, &mut trace), Some(170));
        assert_eq!(trace.page_reads, 4);

        assert_eq!(tree.get(18), None);
        assert_eq!(tree.put(17, 1), Ok(Some(170)));
        assert_eq!(tree.len(), 12);
    }

    #[test]
    fn ascending_inserts_degenerate_into_a_linked_list() {
        let mut tree: Bst = Bst::new();
        for i in 0..500 {
            tree.put(i, i).unwrap();
        }
        tree.validate().unwrap();
        assert_eq!(tree.height(), 500);
        let mut trace = Trace::new();
        tree.get_traced(499, &mut trace);
        assert_eq!(trace.page_reads, 500);
    }

    /// Build a deep tree directly, without `put` (which would walk the whole
    /// chain for every key). `spine` nodes hang below each other; with
    /// `RightChain` and `LeftChain` that is all. With `Caterpillar` every
    /// spine node also gets a leaf as its left child, which is what inserting
    /// 2, 1, 4, 3, 6, 5, ... (nearly sorted input) produces: no long chain of
    /// single children anywhere, but still `spine` levels.
    #[derive(Clone, Copy, PartialEq)]
    enum Shape {
        RightChain,
        LeftChain,
        Caterpillar,
    }

    fn build_deep(spine: u64, shape: Shape) -> Bst {
        let mut tree: Bst = Bst::new();
        let mut link = &mut tree.root;
        for i in 0..spine {
            // Keys 1, 3, 5, ... going down (descending for the left chain).
            let rank = if shape == Shape::LeftChain {
                spine - 1 - i
            } else {
                i
            };
            let mut node = leaf(rank * 2 + 1);
            tree.len += 1;
            if shape == Shape::Caterpillar {
                node.left = Some(leaf(rank * 2));
                tree.len += 1;
            }
            let node = link.insert(node);
            link = if shape == Shape::LeftChain {
                &mut node.left
            } else {
                &mut node.right
            };
        }
        tree
    }

    /// Regression test. Recursive versions of these functions overflowed the
    /// stack: Rust at 20000 levels, Zig at 100000 (validate on the
    /// caterpillar) and 1000000 (range on a chain).
    #[test]
    fn drop_height_validate_and_range_survive_very_deep_trees() {
        let cases = [
            (Shape::RightChain, 1_000_000, 1_000_000),
            (Shape::LeftChain, 1_000_000, 1_000_000),
            (Shape::Caterpillar, 200_000, 400_000),
        ];
        for (shape, spine, nodes) in cases {
            let tree = build_deep(spine, shape);
            assert_eq!(tree.len(), nodes);
            tree.validate().unwrap();
            let expected_height = spine as usize + usize::from(shape == Shape::Caterpillar);
            assert_eq!(tree.height(), expected_height);

            let all = tree.range(0, u64::MAX);
            assert_eq!(all.len(), nodes);
            assert!(all.windows(2).all(|pair| pair[0].key < pair[1].key));

            // A narrow range deep inside the tree: keys 1000, 1001, 1002.
            let want = if shape == Shape::Caterpillar { 3 } else { 1 }; // chains hold odd keys only
            assert_eq!(tree.range(1000, 1003).len(), want);
        } // every tree is dropped here, without recursion
    }

    #[test]
    fn range_prunes_bounds_empty_and_inverted_ranges() {
        let mut tree: Bst = Bst::new();
        for k in CANONICAL {
            tree.put(k, k * 10).unwrap();
        }
        let cases: [(u64, u64, &[u64]); 6] = [
            (6, 17, &[6, 7, 10, 12, 15]), // lo included, hi excluded
            (8, 9, &[]),
            (20, 5, &[]), // inverted
            (10, 10, &[]),
            (30, u64::MAX, &[30]),
            (0, 2, &[1]),
        ];
        for (lo, hi, want) in cases {
            let keys: Vec<u64> = tree.range(lo, hi).iter().map(|e| e.key).collect();
            assert_eq!(keys, want);
        }
    }

    /// Insert order 2, 1, 4, 3, ... (here 1, 0, 3, 2, ...): a small
    /// caterpillar built through `put`. Zig runs the three walks under every
    /// possible allocation failure here; a `Vec` cannot fail that way.
    #[test]
    fn range_height_and_validate_on_nearly_sorted_input() {
        let mut tree: Bst = Bst::new();
        for i in 0..12u64 {
            tree.put(i ^ 1, i).unwrap();
        }
        tree.validate().unwrap();
        assert_eq!(tree.height(), 7);
        assert_eq!(tree.range(0, 100).len(), 12);
    }

    #[test]
    fn delete_leaf_one_child_two_children_root() {
        let mut tree: Bst = Bst::new();
        for k in CANONICAL {
            tree.put(k, k * 10).unwrap();
        }
        assert_eq!(tree.delete(1), Some(10)); // leaf
        assert_eq!(tree.delete(6), Some(60)); // one child (7)
        assert_eq!(tree.delete(20), Some(200)); // two children
        assert_eq!(tree.delete(10), Some(100)); // the root
        assert_eq!(tree.delete(10), None);
        tree.validate().unwrap();
        assert_eq!(tree.len(), 8);
        assert_eq!(tree.root.as_ref().unwrap().key, 12); // successor of 10 moved up

        let keys: Vec<u64> = tree.range(0, 100).iter().map(|e| e.key).collect();
        assert_eq!(keys, [3, 5, 7, 12, 15, 17, 25, 30]);
    }

    #[test]
    fn validate_rejects_a_tree_that_breaks_the_ordering() {
        let mut tree: Bst = Bst::new();
        let mut root = leaf(10);
        root.right = Some(leaf(5)); // 5 on the right of 10
        tree.root = Some(root);
        tree.len = 2;
        assert_eq!(tree.validate(), Err("key out of order"));
        tree.root.as_mut().unwrap().right.as_mut().unwrap().key = 11;
        tree.validate().unwrap();
        tree.len = 3;
        assert!(tree.validate().is_err());
    }

    #[test]
    fn put_beyond_the_budget_leaves_the_tree_unchanged() {
        let mut tree: Bst = Bst::with_budget(3);
        for k in [2, 1, 3] {
            tree.put(k, k).unwrap();
        }
        assert_eq!(tree.put(4, 4), Err(OutOfNodes));
        tree.validate().unwrap();
        assert_eq!(tree.len(), 3);
        assert_eq!(tree.get(4), None);
        // Overwriting needs no new node, so it works even at the budget.
        assert_eq!(tree.put(3, 33), Ok(Some(3)));
    }

    /// Mirror of Zig's checkAllAllocationFailures: fail at every possible
    /// point (here: every possible budget) and check the tree stays valid.
    #[test]
    fn put_under_every_possible_budget() {
        let count = 25u64;
        for budget in 0..count as usize {
            let mut tree: Bst = Bst::with_budget(budget);
            for i in 0..count {
                let result = tree.put((i * 7) % count, i);
                assert_eq!(result.is_err(), i as usize >= budget);
                tree.validate().unwrap();
            }
            assert_eq!(tree.len(), budget);
        }
    }

    #[test]
    fn page_aligned_nodes_each_get_their_own_page() {
        assert_eq!(size_of::<Node<()>>(), 32);
        assert_eq!(size_of::<Node<PageAligned>>(), PAGE_SIZE);
        let mut tree: Bst<PageAligned> = Bst::new();
        for k in CANONICAL {
            tree.put(k, k).unwrap();
        }
        assert_eq!(tree.pages_on_path(17), 4); // 4 nodes, 4 pages
    }

    #[test]
    fn model_test_against_the_oracle() {
        let mut tree: Bst = Bst::new();
        let mut oracle = Oracle::new();
        let config = Config {
            seed: 2,
            count: 5000,
            key_space: 200,
            weights: Weights::default(),
        };
        for op in OpStream::new(config) {
            match op {
                Op::Put { key, value } => {
                    assert_eq!(tree.put(key, value), Ok(oracle.put(key, value)))
                }
                Op::Delete { key } => assert_eq!(tree.delete(key), oracle.delete(key)),
                Op::Get { key } => assert_eq!(tree.get(key), oracle.get(key)),
                Op::Range { lo, hi } => {
                    let want = oracle.range(lo, hi);
                    let got = tree.range(lo, hi);
                    assert_eq!(got.len(), want.len());
                    for (w, g) in want.iter().zip(&got) {
                        assert_eq!((w.key, w.value), (g.key, g.value));
                    }
                }
            }
            tree.validate().unwrap();
            assert_eq!(tree.len(), oracle.len());
        }
    }
}

//! The cursor: a position in the tree that can step forward and backward,
//! and that survives changes to the tree.
//!
//! A cursor has two halves:
//!
//!   * a PHYSICAL position: where the entry is right now. This is the part
//!     that differs between the two designs of this chapter
//!     (`link_cursor.rs`: leaf handle + index, moves along sibling links;
//!     `stack_cursor.rs`: root-to-leaf path, moves by climbing and
//!     descending). It is only valid for the tree version it was computed in.
//!   * a LOGICAL position: the KEY of the entry the cursor is on. A key is
//!     the only thing that still means something after a split, a merge, or
//!     the reuse of a freed node handle.
//!
//! `Cursor<P>` owns the logical half and the rule that connects the two:
//! before using the physical position, compare `version` with the tree's. If
//! they differ, throw the physical position away and seek again from the
//! root with the saved key ("save key and re-seek"). That rule is the same
//! for both designs, so it is written once, here.
//!
//! A cursor does NOT borrow the tree: every method takes `&Tree`. A cursor
//! that held `&Tree` could not exist across a `put` at all (the borrow
//! checker would refuse the `&mut`), and living across changes is the point.

use crate::base_node::Entry;
use crate::base_search::{lower_bound, upper_bound};
use crate::base_tree::BPlusTree;
use crate::tree::Tree;

/// Where to position a cursor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Seek {
    First,   // smallest entry
    Last,    // largest entry
    Ge(u64), // first entry with key >= k
    Gt(u64), // first entry with key >  k
    Le(u64), // last entry with key <= k
    Lt(u64), // last entry with key <  k
}

/// Counts only (no timings). `node_visits` counts every move of the cursor
/// to another node: down to a child, sideways along a link, or back up.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub seeks: usize,
    /// How many of `seeks` were forced by a changed tree.
    pub reseeks: usize,
    pub node_visits: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    /// In front of the smallest entry (also the state of a new cursor).
    BeforeFirst,
    /// Behind the largest entry.
    AfterLast,
    /// On the entry with this key. The key is kept even if that entry is
    /// deleted later: it still tells `next` and `prev` where to continue.
    On(u64),
}

/// Where a seek lands inside the leaf that the descent reached.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Landing {
    /// Index of the answer. May equal the leaf's length: then the answer is
    /// the first entry of the NEXT leaf.
    Forward(usize),
    /// Number of entries of this leaf that qualify; the answer is the last
    /// of them (index n-1). 0 means: the last entry of the PREVIOUS leaf.
    Backward(usize),
}

/// The bounds table of the chapter in code. `lower_bound` counts keys < k,
/// `upper_bound` counts keys <= k; the four seeks are those two numbers read
/// from the left or from the right.
pub fn landing(keys: &[u64], target: Seek) -> Landing {
    match target {
        Seek::First => Landing::Forward(0),
        Seek::Ge(k) => Landing::Forward(lower_bound(keys, k)),
        Seek::Gt(k) => Landing::Forward(upper_bound(keys, k)),
        Seek::Last => Landing::Backward(keys.len()),
        Seek::Le(k) => Landing::Backward(upper_bound(keys, k)),
        Seek::Lt(k) => Landing::Backward(lower_bound(keys, k)),
    }
}

/// The physical half of a cursor. Zig checks this interface by duck typing
/// at compile time (`Cursor(comptime Position: type)`); Rust names it.
pub trait Position {
    /// Position from scratch.
    fn seek(&mut self, tree: &BPlusTree, target: Seek, stats: &mut Stats) -> Option<Entry>;
    /// Step forward; only called on a valid position.
    fn next(&mut self, tree: &BPlusTree, stats: &mut Stats) -> Option<Entry>;
    /// Step backward; only called on a valid position.
    fn prev(&mut self, tree: &BPlusTree, stats: &mut Stats) -> Option<Entry>;
    /// The entry under a valid position.
    fn entry(&self, tree: &BPlusTree) -> Entry;
}

#[derive(Debug, Clone)]
pub struct Cursor<P> {
    pub pos: P,
    pub state: State,
    /// Tree version for which `pos` was computed. INVARIANT: if
    /// `state == On(k)` and `version == tree.version`, then `pos` is on the
    /// entry with key k. In every other case `pos` is garbage.
    version: u64,
    pub stats: Stats,
}

impl<P: Position> Cursor<P> {
    pub fn new(pos: P) -> Self {
        Cursor {
            pos,
            state: State::BeforeFirst,
            version: 0,
            stats: Stats::default(),
        }
    }

    /// Positions the cursor and returns the entry it is now on, or `None`
    /// if no entry qualifies (the cursor is then before the first or after
    /// the last entry, whichever side the seek was looking at).
    pub fn seek(&mut self, tree: &Tree, target: Seek) -> Option<Entry> {
        self.stats.seeks += 1;
        if let Some(found) = self.pos.seek(&tree.base, target, &mut self.stats) {
            self.state = State::On(found.key);
            self.version = tree.version;
            return Some(found);
        }
        self.state = match target {
            Seek::First | Seek::Ge(_) | Seek::Gt(_) => State::AfterLast,
            Seek::Last | Seek::Le(_) | Seek::Lt(_) => State::BeforeFirst,
        };
        None
    }

    /// The entry under the cursor, or `None` if the cursor is off either
    /// end, or if the entry it was on has been deleted since.
    pub fn entry(&mut self, tree: &Tree) -> Option<Entry> {
        let State::On(key) = self.state else {
            return None;
        };
        if self.version == tree.version {
            return Some(self.pos.entry(&tree.base));
        }
        // The tree changed: find the saved key again.
        self.stats.seeks += 1;
        self.stats.reseeks += 1;
        let found = self.pos.seek(&tree.base, Seek::Ge(key), &mut self.stats)?;
        // Not there any more. Stay "on" the key (and stale), so that the
        // next step continues from the gap it left.
        if found.key != key {
            return None;
        }
        self.version = tree.version;
        Some(found)
    }

    /// Moves to the following entry and returns it.
    #[allow(clippy::should_implement_trait)] // not an Iterator: it needs the tree
    pub fn next(&mut self, tree: &Tree) -> Option<Entry> {
        match self.state {
            State::AfterLast => None,
            State::BeforeFirst => self.seek(tree, Seek::First),
            State::On(key) => {
                if self.version != tree.version {
                    // Save key and re-seek: "the first entry after the one I
                    // returned last" is well defined whatever happened to
                    // the nodes in between.
                    self.stats.reseeks += 1;
                    return self.seek(tree, Seek::Gt(key));
                }
                if let Some(found) = self.pos.next(&tree.base, &mut self.stats) {
                    self.state = State::On(found.key);
                    return Some(found);
                }
                self.state = State::AfterLast;
                None
            }
        }
    }

    /// Moves to the preceding entry and returns it.
    pub fn prev(&mut self, tree: &Tree) -> Option<Entry> {
        match self.state {
            State::BeforeFirst => None,
            State::AfterLast => self.seek(tree, Seek::Last),
            State::On(key) => {
                if self.version != tree.version {
                    self.stats.reseeks += 1;
                    return self.seek(tree, Seek::Lt(key));
                }
                if let Some(found) = self.pos.prev(&tree.base, &mut self.stats) {
                    self.state = State::On(found.key);
                    return Some(found);
                }
                self.state = State::BeforeFirst;
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Landing::{Backward, Forward};
    use super::*;

    #[test]
    fn landing_the_four_seeks_are_lower_bound_and_upper_bound_read_from_both_sides() {
        let keys = [10, 20, 30];
        // key present
        assert_eq!(landing(&keys, Seek::Ge(20)), Forward(1));
        assert_eq!(landing(&keys, Seek::Gt(20)), Forward(2));
        assert_eq!(landing(&keys, Seek::Le(20)), Backward(2)); // index 1
        assert_eq!(landing(&keys, Seek::Lt(20)), Backward(1)); // index 0
        // key in a gap: inclusive and exclusive agree
        assert_eq!(landing(&keys, Seek::Ge(25)), Forward(2));
        assert_eq!(landing(&keys, Seek::Gt(25)), Forward(2));
        assert_eq!(landing(&keys, Seek::Le(25)), Backward(2));
        assert_eq!(landing(&keys, Seek::Lt(25)), Backward(2));
        // off the ends of this leaf: the answer is in a neighbour
        assert_eq!(landing(&keys, Seek::Gt(30)), Forward(3));
        assert_eq!(landing(&keys, Seek::Lt(10)), Backward(0));
        assert_eq!(landing(&keys, Seek::First), Forward(0));
        assert_eq!(landing(&keys, Seek::Last), Backward(3));
    }
}

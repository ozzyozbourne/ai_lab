//! Reading: a `View` is "a root plus where to find pages"; `get` and the
//! range cursor work on any view, so the same code serves
//!   * the current committed tree          (Db::view),
//!   * an old snapshot                     (Snapshot::view),
//!   * the uncommitted tree of a write transaction (WriteTxn::view), whose
//!     new pages are not in the store yet.
//!
//! Range scans cannot follow leaf sibling links, because this tree has none.
//! The cursor keeps the root-to-leaf path on a small stack instead and climbs
//! back up through it when a leaf is exhausted.

use std::collections::HashMap;

use crate::base_node::{Entry, Kind, Node, PageId};
use crate::base_search::{child_index, lower_bound};
use crate::store::PageStore;

/// Pages a write transaction has created or copied: page id -> index into
/// the transaction's `Vec<Node>`.
pub type DirtyMap = HashMap<PageId, usize>;

/// With a minimum fan-out of 2 this is enough for 2^31 leaves.
pub const MAX_HEIGHT: usize = 32;

#[derive(Clone, Copy)]
pub struct View<'a> {
    pub store: &'a PageStore,
    /// Only set for the view of a write transaction.
    pub dirty: Option<(&'a DirtyMap, &'a [Node])>,
    pub root: PageId,
    pub height: usize,
    pub count: u64,
}

impl<'a> View<'a> {
    pub fn node(&self, id: PageId) -> &'a Node {
        if let Some((map, pages)) = self.dirty
            && let Some(&i) = map.get(&id)
        {
            return &pages[i];
        }
        self.store.read(id)
    }

    pub fn get(&self, key: u64) -> Option<u64> {
        let mut id = self.root;
        if id.is_nil() {
            return None;
        }
        loop {
            let n = self.node(id);
            match &n.kind {
                Kind::Internal(internal) => id = internal.children[child_index(n.key_slice(), key)],
                Kind::Leaf(leaf) => {
                    let i = lower_bound(n.key_slice(), key);
                    return (i < n.len && n.keys[i] == key).then(|| leaf.values[i]);
                }
            }
        }
    }

    /// Cursor positioned at the first entry with key >= `lo`.
    pub fn seek(&self, lo: u64) -> Cursor<'a> {
        let mut c = Cursor {
            view: *self,
            stack: Vec::with_capacity(self.height),
        };
        let mut id = self.root;
        if id.is_nil() {
            return c;
        }
        loop {
            let n = self.node(id);
            match &n.kind {
                Kind::Internal(internal) => {
                    let i = child_index(n.key_slice(), lo);
                    c.push(id, i);
                    id = internal.children[i];
                }
                Kind::Leaf(_) => {
                    c.push(id, lower_bound(n.key_slice(), lo));
                    return c;
                }
            }
        }
    }

    /// Entries with lo <= key < hi, ascending. `hi` is exclusive, so no
    /// range reaches the key `u64::MAX`: scan everything with `seek(0)`.
    pub fn range(&self, lo: u64, hi: u64) -> Range<'a> {
        Range {
            cursor: self.seek(lo),
            hi,
        }
    }
}

struct Frame {
    id: PageId,
    i: usize,
}

pub struct Cursor<'a> {
    view: View<'a>,
    /// stack[d] = (page at depth d, position in it). For an internal page the
    /// position is the child we descended into; for the leaf on top it is the
    /// next entry to return.
    stack: Vec<Frame>,
}

impl Cursor<'_> {
    fn push(&mut self, id: PageId, i: usize) {
        assert!(self.stack.len() < MAX_HEIGHT);
        self.stack.push(Frame { id, i });
    }

    /// Pops the exhausted top frame; the parent moves on to its next child.
    fn pop(&mut self) {
        self.stack.pop();
        if let Some(parent) = self.stack.last_mut() {
            parent.i += 1;
        }
    }
}

impl Iterator for Cursor<'_> {
    type Item = Entry;

    fn next(&mut self) -> Option<Entry> {
        while let Some(top) = self.stack.last_mut() {
            let n = self.view.node(top.id);
            match &n.kind {
                Kind::Leaf(leaf) => {
                    if top.i < n.len {
                        top.i += 1;
                        return Some(Entry {
                            key: n.keys[top.i - 1],
                            value: leaf.values[top.i - 1],
                        });
                    }
                    // Leaf exhausted. With sibling links this would be one
                    // hop; here we pop, and the parent frame takes over.
                    self.pop();
                }
                Kind::Internal(internal) => {
                    if top.i <= n.len {
                        // Descend into the next child, to its first position.
                        let child = internal.children[top.i];
                        self.push(child, 0);
                    } else {
                        self.pop();
                    }
                }
            }
        }
        None
    }
}

pub struct Range<'a> {
    cursor: Cursor<'a>,
    hi: u64,
}

impl Iterator for Range<'_> {
    type Item = Entry;

    fn next(&mut self) -> Option<Entry> {
        let e = self.cursor.next()?;
        if e.key >= self.hi {
            self.cursor.stack.clear(); // stay finished
            return None;
        }
        Some(e)
    }
}

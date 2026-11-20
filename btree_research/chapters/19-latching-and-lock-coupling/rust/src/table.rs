//! The node table: every node the tree will ever have, allocated ONCE.
//!
//! Chapter 07 kept its nodes in a growable `Vec` with a free list. Neither
//! survives the move to several threads:
//!
//!   * a growing `Vec` MOVES, and another thread may be reading a node at
//!     that moment (the borrow checker would not even let us push while a
//!     reference is out). Here the table is a `Box<[RwLock<Node>]>`: fixed
//!     length, never moved;
//!   * a freed slot can be REUSED while a slow thread still holds its handle.
//!     Here nodes are never freed (the chapter has no delete), so a handle
//!     always names the node it named when it was read. A thread may latch a
//!     node it found through a stale pointer; it then sees an old but real
//!     node, never an unrelated one. `latch_root` in coupled.rs depends on
//!     this.
//!
//! Each slot IS the latch: in Rust the data lives inside the lock, and the
//! only way to a `&Node` or `&mut Node` is through a guard. Handing out slots
//! is a bump of one atomic counter, so two threads splitting different
//! leaves never wait for each other to get a node.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};

use crate::base_node::{Node, NodeId, OutOfNodes};

pub struct NodeTable {
    slots: Box<[RwLock<Node>]>,
    /// Slots handed out so far; ids 0 .. used-1 are live. Only ever grows.
    used: AtomicU32,
}

impl NodeTable {
    /// The only allocation the tree ever makes.
    pub fn new(node_count: u32) -> NodeTable {
        NodeTable {
            slots: (0..node_count)
                .map(|_| RwLock::new(Node::new_leaf()))
                .collect(),
            used: AtomicU32::new(0),
        }
    }

    /// Hands out `n` consecutive slots and returns the id of the first, or
    /// fails WITHOUT taking any. All or nothing matters: an insert asks for
    /// every node its splits will need before it changes the tree, so running
    /// out of nodes never leaves a half-finished split behind.
    ///
    /// `fetch_update` is a compare-and-swap loop. A plain `fetch_add` would
    /// have to be undone on failure, and between the add and the undo another
    /// thread could see a counter beyond the capacity.
    pub fn reserve(&self, n: u32) -> Result<NodeId, OutOfNodes> {
        self.reserve_observed(n, &|_| {})
    }

    /// Test seam for `reserve`: `observer` is called with the counter value
    /// this call has just read, BEFORE it tries to claim the slots. Whatever
    /// the observer does there is exactly what another thread could do in
    /// that gap, so a test can replay the race on one thread, every time.
    pub fn reserve_observed(&self, n: u32, observer: &dyn Fn(u32)) -> Result<NodeId, OutOfNodes> {
        let capacity = self.capacity();
        self.used
            // Claims the slots only if the counter is still what the closure
            // was given. If somebody moved it, the closure runs again with
            // the new value.
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |seen| {
                if n > capacity - seen {
                    return None;
                }
                observer(seen);
                Some(seen + n)
            })
            .map(|first| NodeId::from_index(first as usize))
            .map_err(|_| OutOfNodes)
    }

    /// Shared latch on a node. Blocks while a writer holds it.
    pub fn read(&self, id: NodeId) -> RwLockReadGuard<'_, Node> {
        self.slots[id.index()].read().expect("latch poisoned")
    }

    /// Exclusive latch on a node. Blocks while anybody holds it.
    pub fn write(&self, id: NodeId) -> RwLockWriteGuard<'_, Node> {
        self.slots[id.index()].write().expect("latch poisoned")
    }

    /// The latch itself, for `try_read` / `try_write`.
    pub fn latch(&self, id: NodeId) -> &RwLock<Node> {
        &self.slots[id.index()]
    }

    pub fn count(&self) -> u32 {
        self.used.load(Ordering::Relaxed)
    }

    pub fn capacity(&self) -> u32 {
        self.slots.len() as u32
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn reserve_is_all_or_nothing() {
        let table = NodeTable::new(5);
        assert_eq!(table.reserve(2).unwrap().index(), 0);
        assert_eq!(table.reserve(2).unwrap().index(), 2);
        // Two are needed, one is left: nothing is taken.
        assert_eq!(table.reserve(2), Err(OutOfNodes));
        assert_eq!(table.count(), 4);
        assert_eq!(table.reserve(1).unwrap().index(), 4);
        assert_eq!(table.reserve(1), Err(OutOfNodes));
    }

    /// Plays "the other thread": the first time `reserve` reports what it
    /// read, it takes `take` slots itself, in the gap before `reserve`
    /// claims its own. Returns what the caller got, what the intruder got,
    /// and how often `reserve` read the counter.
    fn reserve_with_intruder(
        table: &NodeTable,
        n: u32,
        take: u32,
    ) -> (Result<NodeId, OutOfNodes>, Option<NodeId>, u32) {
        let calls = Cell::new(0);
        let got = Cell::new(None);
        let mine = table.reserve_observed(n, &|_seen| {
            calls.set(calls.get() + 1);
            // Only once: a weak compare-and-swap may fail for no reason and
            // ask again.
            if calls.get() == 1 {
                got.set(table.reserve(take).ok());
            }
        });
        (mine, got.get(), calls.get())
    }

    #[test]
    fn reserve_a_slot_taken_between_the_read_and_the_claim_is_never_handed_out_twice() {
        let table = NodeTable::new(8);
        // We read "0 used"; the intruder takes slot 0; our claim must notice.
        let (mine, theirs, calls) = reserve_with_intruder(&table, 2, 1);
        assert_eq!(theirs.unwrap().index(), 0);
        assert_eq!(mine.unwrap().index(), 1); // not 0 again
        assert_eq!(table.count(), 3); // 1 + 2, none lost
        assert!(calls >= 2); // the claim was retried
    }

    #[test]
    fn reserve_all_or_nothing_also_when_the_last_slots_go_in_the_gap() {
        let table = NodeTable::new(2);
        // We read "0 used" and need both slots; the intruder takes one.
        let (mine, theirs, _) = reserve_with_intruder(&table, 2, 1);
        assert_eq!(mine, Err(OutOfNodes));
        assert_eq!(theirs.unwrap().index(), 0);
        assert_eq!(table.count(), 1); // we took nothing
    }
}

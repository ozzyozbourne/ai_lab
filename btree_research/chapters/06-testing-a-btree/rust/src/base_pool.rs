// Copied from chapters/05-deletion-and-rebalancing/rust/src/pool.rs
// Change for chapter 06: the slab counts its occupied slots (`live_slots`),
// independently of `usage`, so that `BTree::validate` can find a node that
// was reserved by a failed `put` and never handed back.
//! SECTION 2: node allocation.
//!
//! The tree never creates nodes on its own. It asks the *slab* for a slot and
//! gives slots back to it:
//!
//! ```text
//! alloc(node) -> Result<NodeId, OutOfNodes>
//! free(id)    -> Node            (panics on a double free)
//! slab[id]                       (panics on a freed id)
//! usage                          (counters)
//! ```
//!
//! The Zig twin has three allocators behind this interface (one allocation
//! per node, a hand-written free-list pool, `std.heap.MemoryPool`). The Rust
//! idiom for all three is one structure: a `Vec` of slots plus a free list of
//! *indices*. A freed slot stores the index of the next free slot, exactly
//! like the intrusive free list in Zig stores a pointer in the freed node.
//!
//! What the slab recycles is the SLOT (and with it the `NodeId`). It is not
//! the full pool of the Zig version: a Rust node owns up to three `Vec`
//! buffers on the heap (node.rs), which are allocated by a split and
//! released by a merge through the global allocator as before.
//!
//! Without `free`, `free_head`, the failure switches and `usage`, a slab is a
//! `Vec<Node>` that is only pushed to: the *typed arena* of chapter 03.
//! search.rs, validate.rs and stats.rs accept either (node.rs, `Nodes`).
//!
//! Rust aborts the process when the global allocator fails, so "out of
//! memory" is modelled by the slab itself, with two switches:
//!
//! * `budget = Some(n)`: `alloc` fails while n nodes are live (a memory limit);
//! * `fail_after = Some(n)`: n more calls of `alloc` succeed, then every call
//!   fails until the switch is reset. This is `fail_index` of Zig's
//!   `std.testing.FailingAllocator`: it can fail the second allocation of
//!   one particular `put` in a tree of any size, which a limit on live nodes
//!   cannot express.

use crate::base_node::{Node, NodeId};

/// The slab's node budget is exhausted (the Rust stand-in for `error.OutOfMemory`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutOfNodes;

impl std::fmt::Display for OutOfNodes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("node budget exhausted")
    }
}

impl std::error::Error for OutOfNodes {}

/// Counters, so the tree can check "no node was lost"
/// (`live() == number of nodes reachable from the root`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Usage {
    pub created: u64,
    pub destroyed: u64,
    pub peak: u64,
}

impl Usage {
    pub fn live(&self) -> u64 {
        self.created - self.destroyed
    }
}

#[derive(Debug)]
enum Slot {
    Live(Node),
    /// A free slot remembers the next free slot: the free list threads
    /// through the unused slots and costs no memory of its own.
    Free {
        next_free: Option<NodeId>,
    },
}

/// Fixed-size-object pool: O(1) alloc and free, slots reused LIFO.
#[derive(Debug, Default)]
pub struct Slab {
    slots: Vec<Slot>,
    free_head: Option<NodeId>,
    /// Length of the free list.
    free_slots: usize,
    /// `None`: unlimited. `Some(n)`: at most n live nodes.
    pub budget: Option<u64>,
    /// `None`: never. `Some(n)`: n more allocations succeed, then all fail.
    pub fail_after: Option<u64>,
    /// `put` restores these when it fails (insert.rs), so they always
    /// describe nodes that were part of the tree, never returned reservations.
    pub usage: Usage,
}

impl Slab {
    pub fn new() -> Self {
        Self::default()
    }

    /// Slots ever created (the Zig pool calls this `carved`). Because a free
    /// slot is always reused before a new one is pushed, it equals
    /// `usage.peak`, unless a `put` failed half-way through its reservation:
    /// the slot pushed for a returned reservation stays on the free list.
    pub fn slot_count(&self) -> usize {
        self.slots.len()
    }

    /// Slots that hold a node right now: all slots minus the free list.
    ///
    /// This is the slab's own count, and deliberately not derived from
    /// `usage`. `put` overwrites `usage` when it fails (it restores the
    /// value from before its reservation), so `usage.live()` cannot tell
    /// whether the reserved slots were really given back. This number can:
    /// it only changes when a slot changes state. `BTree::validate` compares
    /// both with the number of nodes reachable from the root. (In Zig the
    /// same job is done from outside, by the counting allocator under the
    /// tree: Rust's global allocator cannot see a slot of this `Vec`.)
    pub fn live_slots(&self) -> usize {
        self.slots.len() - self.free_slots
    }

    pub fn alloc(&mut self, node: Node) -> Result<NodeId, OutOfNodes> {
        if self
            .budget
            .is_some_and(|budget| self.usage.live() >= budget)
        {
            return Err(OutOfNodes);
        }
        match &mut self.fail_after {
            Some(0) => return Err(OutOfNodes),
            Some(left) => *left -= 1,
            None => {}
        }
        self.usage.created += 1;
        self.usage.peak = self.usage.peak.max(self.usage.live());
        if let Some(id) = self.free_head {
            // Pop the free list: the most recently freed slot is reused first.
            let Slot::Free { next_free } = self.slots[id.0 as usize] else {
                unreachable!("free list points at a live slot");
            };
            self.free_head = next_free;
            self.free_slots -= 1;
            self.slots[id.0 as usize] = Slot::Live(node);
            return Ok(id);
        }
        let id = NodeId(u32::try_from(self.slots.len()).expect("more than 2^32 nodes"));
        self.slots.push(Slot::Live(node));
        Ok(id)
    }

    /// Returns the slot to the free list and hands the node back by value,
    /// so the caller decides what happens to its keys and children (a merge
    /// appends them to the left sibling). The node's own buffers are dropped
    /// with it: only the slot is recycled.
    pub fn free(&mut self, id: NodeId) -> Node {
        let next_free = self.free_head;
        match std::mem::replace(&mut self.slots[id.0 as usize], Slot::Free { next_free }) {
            Slot::Live(node) => {
                self.free_head = Some(id);
                self.free_slots += 1;
                self.usage.destroyed += 1;
                node
            }
            Slot::Free { .. } => panic!("double free of {id:?}"),
        }
    }
}

/// `slab[id]` panics on a freed id (the safe-Rust version of use-after-free).
impl std::ops::Index<NodeId> for Slab {
    type Output = Node;
    fn index(&self, id: NodeId) -> &Node {
        match &self.slots[id.0 as usize] {
            Slot::Live(node) => node,
            Slot::Free { .. } => panic!("use of freed {id:?}"),
        }
    }
}

impl std::ops::IndexMut<NodeId> for Slab {
    fn index_mut(&mut self, id: NodeId) -> &mut Node {
        match &mut self.slots[id.0 as usize] {
            Slot::Live(node) => node,
            Slot::Free { .. } => panic!("use of freed {id:?}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn leaf(key: u64) -> Node {
        let mut node = Node::new(true);
        node.insert_entry(0, key, key);
        node
    }

    #[test]
    fn create_destroy_counters() {
        let mut slab = Slab::new();
        let x = slab.alloc(leaf(1)).unwrap();
        let y = slab.alloc(leaf(3)).unwrap();
        assert_eq!(slab[x].keys, [1]); // y did not overwrite x
        assert_eq!(slab.free(x).keys, [1]);
        assert_eq!(slab.usage.live(), 1);
        slab.free(y);
        assert_eq!(slab.usage.created, 2);
        assert_eq!(slab.usage.peak, 2);
        assert_eq!(slab.usage.live(), 0);
    }

    #[test]
    fn a_destroyed_slot_is_handed_out_again_lifo() {
        let mut slab = Slab::new();
        let a = slab.alloc(leaf(1)).unwrap();
        let b = slab.alloc(leaf(2)).unwrap();
        slab.free(a);
        slab.free(b);
        assert_eq!(slab.alloc(leaf(3)).unwrap(), b); // last freed, first reused
        assert_eq!(slab.alloc(leaf(4)).unwrap(), a);
        assert_eq!(slab.slot_count(), 2); // nothing new was pushed
        assert_eq!(slab.usage.created, 4);
    }

    #[test]
    fn live_slots_is_counted_by_the_slab_not_derived_from_usage() {
        let mut slab = Slab::new();
        let a = slab.alloc(leaf(1)).unwrap();
        let before = slab.usage;
        let b = slab.alloc(leaf(2)).unwrap();
        let _c = slab.alloc(leaf(3)).unwrap();
        assert_eq!(slab.live_slots(), 3);
        slab.free(b);
        assert_eq!(slab.live_slots(), 2);
        // What a failed `put` does: put the counters back. If it forgot to
        // free a slot first (`_c`), `usage` looks innocent ...
        slab.usage = before;
        assert_eq!(slab.usage.live(), 1);
        // ... and the slab's own count does not.
        assert_eq!(slab.live_slots(), 2);
        slab.free(a);
        assert_eq!(slab.live_slots(), 1);
    }

    #[test]
    fn budget_reports_failure_and_the_slab_stays_usable() {
        let mut slab = Slab::new();
        slab.budget = Some(1);
        let a = slab.alloc(leaf(1)).unwrap();
        assert_eq!(slab.alloc(leaf(2)), Err(OutOfNodes));
        assert_eq!(slab.usage.created, 1);
        slab.free(a);
        assert!(slab.alloc(leaf(2)).is_ok()); // a freed node makes room again
    }

    #[test]
    fn fail_after_fails_a_chosen_allocation_whatever_is_live() {
        let mut slab = Slab::new();
        slab.fail_after = Some(2);
        let a = slab.alloc(leaf(1)).unwrap();
        slab.free(a); // nothing is live: a budget would let the next ones pass
        slab.alloc(leaf(2)).unwrap();
        assert_eq!(slab.alloc(leaf(3)), Err(OutOfNodes));
        assert_eq!(slab.alloc(leaf(3)), Err(OutOfNodes)); // and stays failing
        assert_eq!(slab.usage.created, 2);
        slab.fail_after = None;
        assert!(slab.alloc(leaf(3)).is_ok());
    }

    #[test]
    #[should_panic(expected = "double free")]
    fn double_free_panics() {
        let mut slab = Slab::new();
        let a = slab.alloc(leaf(1)).unwrap();
        slab.free(a);
        slab.free(a);
    }

    #[test]
    #[should_panic(expected = "use of freed")]
    fn use_after_free_panics() {
        let mut slab = Slab::new();
        let a = slab.alloc(leaf(1)).unwrap();
        slab.free(a);
        let _ = &slab[a];
    }
}

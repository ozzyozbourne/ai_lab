//! The page store: fixed-size slots addressed by page id (the "file"), the
//! list of slots that may be written, and the two metapage slots.
//!
//! This is the page slab of the chapter. It is a stand-in for a database file
//! behind a pager (chapter 09): slot i is "the page at offset i * page_size".
//! The store enforces the one rule everything else depends on:
//!
//! ```text
//! `write` only ever targets a FREE slot.
//! ```
//!
//! A slot is free when no committed root and no snapshot can reach it. So a
//! page that some reader may be looking at is never modified, by construction.

use crate::base_node::{Node, PageId};
use crate::meta::{SLOT_SIZE, Slots};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlotState {
    /// Not part of any tree; listed in `free` (or reserved by the open write
    /// transaction). Its content is garbage.
    Free,
    /// Written by a committed transaction and not yet released.
    Live,
}

#[derive(Debug, Clone)]
pub struct Slot {
    pub state: SlotState,
    /// Id of the transaction that last wrote this slot. `validate` uses it to
    /// prove that no page was written after a root that still reaches it.
    pub written_by: u64,
    pub node: Node,
}

#[derive(Debug)]
pub struct PageStore {
    pub slots: Vec<Slot>,
    /// Page ids that may be written right now, used as a stack.
    pub free: Vec<PageId>,
    pub meta_slots: Slots,
}

impl Default for PageStore {
    fn default() -> Self {
        PageStore {
            slots: Vec::new(),
            free: Vec::new(),
            meta_slots: [[0; SLOT_SIZE]; 2],
        }
    }
}

impl PageStore {
    pub fn page_count(&self) -> usize {
        self.slots.len()
    }

    pub fn is_live(&self, id: PageId) -> bool {
        !id.is_nil()
            && id.index() < self.slots.len()
            && self.slots[id.index()].state == SlotState::Live
    }

    /// A committed page. Readers get a shared reference: nothing may change it.
    pub fn read(&self, id: PageId) -> &Node {
        let slot = &self.slots[id.index()];
        assert!(slot.state == SlotState::Live);
        &slot.node
    }

    /// Makes room for `page_count` slots (new ones are free but NOT listed in
    /// `free`; the caller decides what happens to them).
    pub fn grow(&mut self, page_count: usize) {
        while self.slots.len() < page_count {
            self.slots.push(Slot {
                state: SlotState::Free,
                written_by: 0,
                node: Node::new_leaf(),
            });
        }
    }

    /// The only function that writes page content.
    pub fn write(&mut self, id: PageId, node: &Node, txn_id: u64) {
        let slot = &mut self.slots[id.index()];
        assert!(slot.state == SlotState::Free); // never overwrite a page a root can reach
        *slot = Slot {
            state: SlotState::Live,
            written_by: txn_id,
            node: node.clone(),
        };
    }

    /// A live page that no root can reach any more becomes writable again.
    pub fn release(&mut self, id: PageId) {
        let slot = &mut self.slots[id.index()];
        assert!(slot.state == SlotState::Live);
        slot.state = SlotState::Free;
        self.free.push(id);
    }
}

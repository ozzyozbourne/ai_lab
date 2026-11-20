//! The heap: where rows live in the "heap + index" layout.
//!
//! A heap is an unordered pile of fixed-size pages. A new row goes into the
//! next free slot of the last page; nothing is ever moved. A row's address is
//! its TID (tuple identifier): page number and slot number. Fetching by TID
//! is one array access, no search, which is why every index of this layout
//! stores TIDs.
//!
//! The price of "never moved, found by position": a deleted row leaves a hole
//! (a dead slot). This chapter never reuses holes; reclaiming them is VACUUM
//! (chapter 24).

use crate::row::Row;

pub const SLOTS_PER_PAGE: usize = 4;

/// Page number and slot packed as `page * SLOTS_PER_PAGE + slot`. Printed as
/// `(page,slot)` with the slot counted from 1, the way Postgres prints ctid.
pub type Tid = u32;

pub fn tid_page(tid: Tid) -> usize {
    tid as usize / SLOTS_PER_PAGE
}

pub fn tid_slot(tid: Tid) -> usize {
    tid as usize % SLOTS_PER_PAGE + 1
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Slot {
    Live(Row),
    Dead,
}

#[derive(Debug)]
struct Page {
    slots: [Slot; SLOTS_PER_PAGE],
    used: usize,
}

#[derive(Debug, Default)]
pub struct Heap {
    /// Page number -> page: the analogue of the file's block map. Each page
    /// is its own `Box`: fixed size, allocated one at a time, never moved,
    /// all released together when the `Vec` is dropped. That is what Zig's
    /// `MemoryPool` gives. (A `Vec<Row>` would copy every row each time it
    /// grows; a heap file only ever appends a page.)
    #[allow(clippy::vec_box)] // deliberate: pages must not move, see above
    pages: Vec<Box<Page>>,
    pub live_rows: usize,
}

impl Heap {
    pub fn new() -> Heap {
        Heap::default()
    }

    /// Stores the row in the next free slot. Cannot fail: a `Vec` aborts the
    /// process when memory runs out (Zig's version returns OutOfMemory).
    pub fn append(&mut self, row: Row) -> Tid {
        if self.pages.last().is_none_or(|p| p.used == SLOTS_PER_PAGE) {
            self.pages.push(Box::new(Page {
                slots: [Slot::Dead; SLOTS_PER_PAGE],
                used: 0,
            }));
        }
        let page_no = self.pages.len() - 1;
        let page = &mut self.pages[page_no];
        let slot = page.used;
        page.slots[slot] = Slot::Live(row);
        page.used += 1;
        self.live_rows += 1;
        u32::try_from(page_no * SLOTS_PER_PAGE + slot).expect("heap full")
    }

    /// The row at `tid`, or `None` if that slot is dead or was never used.
    pub fn fetch(&self, tid: Tid) -> Option<Row> {
        let page = self.pages.get(tid_page(tid))?;
        let slot = tid as usize % SLOTS_PER_PAGE;
        match page.slots[slot] {
            Slot::Live(row) if slot < page.used => Some(row),
            _ => None,
        }
    }

    /// Marks the slot dead. The slot is not reused and later TIDs do not
    /// change, so index entries of OTHER rows stay correct.
    pub fn kill(&mut self, tid: Tid) {
        let page = &mut self.pages[tid_page(tid)];
        let slot = tid as usize % SLOTS_PER_PAGE;
        assert!(matches!(page.slots[slot], Slot::Live(_)));
        page.slots[slot] = Slot::Dead;
        self.live_rows -= 1;
    }

    pub fn page_count(&self) -> usize {
        self.pages.len()
    }

    /// The used slots of one page, for printing and validation.
    pub fn page_slots(&self, page_no: usize) -> &[Slot] {
        let page = &self.pages[page_no];
        &page.slots[..page.used]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: u32) -> Row {
        Row {
            id,
            customer: 1,
            day: 2,
            amount: 3,
            code: id as u16,
        }
    }

    #[test]
    fn tids_are_stable_appending_and_killing_never_moves_a_row() {
        let mut heap = Heap::new();
        let tids: Vec<Tid> = (0..10).map(|i| heap.append(row(i))).collect();
        assert_eq!(heap.page_count(), 3);
        assert_eq!(tids[9], 9);
        assert_eq!(tid_page(tids[9]), 2);
        assert_eq!(tid_slot(tids[9]), 2);

        heap.kill(tids[4]);
        assert_eq!(heap.fetch(tids[4]), None);
        assert_eq!(heap.fetch(tids[5]).unwrap().id, 5);
        assert_eq!(heap.live_rows, 9);
        assert_eq!(heap.fetch(10), None); // never used
        assert_eq!(heap.fetch(400), None); // no such page
        // The hole is not reused: the next row gets a fresh TID.
        assert_eq!(heap.append(row(99)), 10);
    }
}

//! A tiny table engine in two layouts. Same table, same indexes, same
//! queries; the only thing that differs is WHERE THE ROWS LIVE and therefore
//! what an index entry points at.
//!
//!   Clustered  (index-organized; Turso / SQLite table B-tree)
//!       primary tree:  id -> row              the row is IN the leaf
//!       secondary:     (columns, id)          locator = row id
//!       back to the row = one more DESCENT of the primary tree
//!
//!   Heap       (heap + index; Postgres)
//!       heap:          rows in arrival order  the row is at a TID
//!       primary key:   (id, TID)              just another index
//!       secondary:     (columns, TID)         locator = TID
//!       back to the row = one HEAP READ, no search
//!
//! Three functions contain every difference: `get_by_id`, `fetch` and the
//! "store the row" step of `insert`. Everything about secondary indexes
//! (unique check, covering scan, prefix scan) is the same code for both.
//!
//! Invariants (checked by `validate`):
//!   1. Each of the three trees is a valid B+tree.
//!   2. Every tree has exactly one entry per row.
//!   3. Every index entry's locator leads to a live row whose columns equal
//!      the columns in the entry's key.
//!   4. No two rows share an id; no two rows share a code.

use std::cell::Cell;

use crate::base_arena::OutOfNodes;
use crate::base_tree::BPlusTree;
use crate::base_validate::Violation;
use crate::base_walk::LeafWalker;
use crate::cursor::{Counters, Cursor, charge_descent, count};
use crate::heap::Heap;
use crate::row::{self, KeyRange, Locator, Row};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Layout {
    Clustered,
    Heap,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InsertError {
    DuplicatePrimaryKey,
    DuplicateCode,
    /// A tree hit its node budget (the stand-in for Zig's OutOfMemory).
    OutOfNodes,
}

impl From<OutOfNodes> for InsertError {
    fn from(_: OutOfNodes) -> InsertError {
        InsertError::OutOfNodes
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValidateError {
    Tree(Violation),
    Inconsistent,
}

impl From<Violation> for ValidateError {
    fn from(v: Violation) -> ValidateError {
        ValidateError::Tree(v)
    }
}

#[derive(Debug)]
pub struct Table {
    pub layout: Layout,
    /// Clustered: id -> packed row.   Heap: (id, TID) -> unused.
    pub primary: BPlusTree,
    /// Only the heap layout puts rows here; stays empty when clustered.
    pub heap: Heap,
    /// (customer, day, locator) -> unused.
    pub by_customer_day: BPlusTree,
    /// (code, locator) -> unused. UNIQUE on code alone.
    pub by_code: BPlusTree,
    pub counters: Cell<Counters>,
    pub rows: usize,
}

impl Table {
    /// `order` is the M of all three trees. Does not allocate.
    pub fn new(layout: Layout, order: usize) -> Table {
        Self::with_node_budgets(layout, order, [usize::MAX; 3])
    }

    /// Node budgets for the primary tree, `by_customer_day` and `by_code`,
    /// in that order. `insert` returns `Err(OutOfNodes)` instead of exceeding
    /// one. This mirrors the Zig tests that make the allocator fail.
    pub fn with_node_budgets(layout: Layout, order: usize, max_nodes: [usize; 3]) -> Table {
        Table {
            layout,
            primary: BPlusTree::with_node_budget(order, max_nodes[0]),
            heap: Heap::new(),
            by_customer_day: BPlusTree::with_node_budget(order, max_nodes[1]),
            by_code: BPlusTree::with_node_budget(order, max_nodes[2]),
            counters: Cell::new(Counters::default()),
            rows: 0,
        }
    }

    // ------------------------------------------------ the layout-specific part

    /// SELECT * FROM orders WHERE id = ?
    pub fn get_by_id(&self, id: u32) -> Option<Row> {
        match self.layout {
            // The descent ENDS at the row: nothing left to fetch.
            Layout::Clustered => {
                charge_descent(&self.counters, &self.primary);
                let value = self.primary.get(u64::from(id))?;
                Some(row::unpack_row(id, value))
            }
            // The descent ends at a TID; the row is one more page away.
            Layout::Heap => {
                let tid = self.probe(&self.primary, id)?;
                self.fetch(tid)
            }
        }
    }

    /// The step "back to the table": from a locator found in an index entry
    /// to the row. This is the function the whole chapter is about.
    fn fetch(&self, locator: Locator) -> Option<Row> {
        count(&self.counters, |c| c.row_fetches += 1);
        match self.layout {
            // The locator is a KEY of another tree: search that tree.
            Layout::Clustered => {
                charge_descent(&self.counters, &self.primary);
                let value = self.primary.get(u64::from(locator))?;
                Some(row::unpack_row(locator, value))
            }
            // The locator is an ADDRESS: go there.
            Layout::Heap => {
                count(&self.counters, |c| c.heap_reads += 1);
                self.heap.fetch(locator)
            }
        }
    }

    /// `fetch` without the counters, for `validate`.
    fn row_at(&self, locator: Locator) -> Option<Row> {
        match self.layout {
            Layout::Clustered => {
                let value = self.primary.get(u64::from(locator))?;
                Some(row::unpack_row(locator, value))
            }
            Layout::Heap => self.heap.fetch(locator),
        }
    }

    // ------------------------------------------------------- index primitives

    /// First locator filed under `value` in a one-column index, or `None`.
    /// One descent to the place where (value, smallest locator) would be.
    /// This is both the equality lookup and the UNIQUE check: the search key
    /// deliberately leaves the locator out, because "is there ANY entry with
    /// this value" is the question.
    fn probe(&self, tree: &BPlusTree, value: u32) -> Option<Locator> {
        let mut cursor = Cursor::seek(tree, row::column_range(value), &self.counters);
        cursor.next().map(row::key_locator)
    }

    // `put_new` and `remove` take the tree and the counters as separate
    // arguments (not `&mut self`) so that the borrow checker can see that the
    // tree being changed and the counters are different fields.
    fn put_new(
        counters: &Cell<Counters>,
        tree: &mut BPlusTree,
        key: u64,
        value: u64,
    ) -> Result<(), OutOfNodes> {
        charge_descent(counters, tree);
        let old = tree.put(key, value)?;
        assert!(old.is_none()); // the locator makes every index key distinct
        Ok(())
    }

    fn remove(counters: &Cell<Counters>, tree: &mut BPlusTree, key: u64) {
        charge_descent(counters, tree);
        let old = tree.delete(key);
        assert!(old.is_some()); // invariant 2: the entry was there
    }

    // ---------------------------------------------------------------- writes

    /// INSERT. On any error the table is logically unchanged: the row is in
    /// none of the trees. (In the heap layout a failed insert may leave one
    /// dead heap slot behind, exactly the hole an aborted insert leaves.)
    pub fn insert(&mut self, row: Row) -> Result<(), InsertError> {
        // 1. Constraints first, before anything is written.
        let id_taken = match self.layout {
            Layout::Clustered => {
                charge_descent(&self.counters, &self.primary);
                self.primary.get(u64::from(row.id)).is_some()
            }
            Layout::Heap => self.probe(&self.primary, row.id).is_some(),
        };
        if id_taken {
            return Err(InsertError::DuplicatePrimaryKey);
        }
        if self.probe(&self.by_code, u32::from(row.code)).is_some() {
            return Err(InsertError::DuplicateCode);
        }

        // 2. Store the row; this decides its locator.
        let (locator, primary_key, primary_value) = match self.layout {
            Layout::Clustered => (row.id, u64::from(row.id), row::pack_row(row)),
            Layout::Heap => {
                let tid = self.heap.append(row);
                (tid, row::column_key(row.id, tid), 0)
            }
        };
        // Every later step can run out of nodes. `delete` never allocates, so
        // undoing the earlier steps cannot fail in turn. Zig writes the undo
        // steps as `errdefer`; here they are spelled out in `undo`.
        let customer_day_key = row::customer_day_key(row.customer, row.day, locator);
        let code_key = row::column_key(u32::from(row.code), locator);
        let mut done = 0;
        let result = (|| {
            Self::put_new(
                &self.counters,
                &mut self.primary,
                primary_key,
                primary_value,
            )?;
            done = 1;
            // 3. One entry per secondary index, each ending in the locator.
            Self::put_new(
                &self.counters,
                &mut self.by_customer_day,
                customer_day_key,
                0,
            )?;
            done = 2;
            Self::put_new(&self.counters, &mut self.by_code, code_key, 0)
        })();
        if let Err(out_of_nodes) = result {
            if done >= 2 {
                self.by_customer_day.delete(customer_day_key);
            }
            if done >= 1 {
                self.primary.delete(primary_key);
            }
            if self.layout == Layout::Heap {
                self.heap.kill(locator);
            }
            return Err(out_of_nodes.into());
        }
        self.rows += 1;
        Ok(())
    }

    /// DELETE FROM orders WHERE id = ?   Returns false if there was no such
    /// row. The row must be READ before it can be deleted: its column values
    /// and its locator are the only way to name its index entries.
    pub fn delete(&mut self, id: u32) -> bool {
        let found = match self.layout {
            Layout::Clustered => {
                charge_descent(&self.counters, &self.primary);
                self.primary
                    .get(u64::from(id))
                    .map(|value| (id, u64::from(id), row::unpack_row(id, value)))
            }
            Layout::Heap => self.probe(&self.primary, id).map(|tid| {
                let row = self.fetch(tid).expect("index entry without a row");
                (tid, row::column_key(id, tid), row)
            }),
        };
        let Some((locator, primary_key, row)) = found else {
            return false;
        };
        // Because the locator is part of the key, each entry is found by an
        // exact descent even among many equal (customer, day) pairs.
        Self::remove(
            &self.counters,
            &mut self.by_customer_day,
            row::customer_day_key(row.customer, row.day, locator),
        );
        Self::remove(
            &self.counters,
            &mut self.by_code,
            row::column_key(u32::from(row.code), locator),
        );
        Self::remove(&self.counters, &mut self.primary, primary_key);
        if self.layout == Layout::Heap {
            self.heap.kill(locator);
        }
        self.rows -= 1;
        true
    }

    // --------------------------------------------------------------- queries
    // Results go into `out`, the caller's per-query buffer. It is cleared
    // first and keeps its capacity: the `Vec` equivalent of resetting an
    // arena with `retain_capacity`.

    /// SELECT * ... WHERE <a range of by_customer_day>: one descent of the
    /// index, then one row fetch PER ENTRY. Rows come back in index order.
    pub fn fetch_scan(&self, out: &mut Vec<Row>, range: KeyRange) {
        out.clear();
        for key in Cursor::seek(&self.by_customer_day, range, &self.counters) {
            let row = self.fetch(row::key_locator(key));
            out.push(row.expect("index entry without a row"));
        }
    }

    /// SELECT customer, day ... WHERE <a range of by_customer_day>: the
    /// index key already contains every requested column, so the scan never
    /// leaves the index. Zero row fetches in both layouts. Returns the keys;
    /// decode them with `row::key_customer` / `key_day` / `key_locator`.
    pub fn index_only_scan(&self, out: &mut Vec<u64>, range: KeyRange) {
        out.clear();
        out.extend(Cursor::seek(&self.by_customer_day, range, &self.counters));
    }

    /// SELECT count(*) ... WHERE day = ?   `day` is the SECOND column of the
    /// index and the first is not fixed, so the matching entries are scattered
    /// over the whole index: every entry has to be read.
    pub fn count_on_day(&self, day: u16) -> usize {
        Cursor::seek(&self.by_customer_day, KeyRange::ALL, &self.counters)
            .filter(|&key| row::key_day(key) == day)
            .count()
    }

    /// SELECT * ... WHERE code = ?   At most one row, by the UNIQUE constraint.
    pub fn get_by_code(&self, code: u16) -> Option<Row> {
        let locator = self.probe(&self.by_code, u32::from(code))?;
        self.fetch(locator)
    }

    // -------------------------------------------------------------- validate

    pub fn validate(&self) -> Result<(), ValidateError> {
        use ValidateError::Inconsistent;
        self.primary.validate()?;
        self.by_customer_day.validate()?;
        self.by_code.validate()?;

        let n = self.rows;
        if self.primary.len() != n || self.by_customer_day.len() != n || self.by_code.len() != n {
            return Err(Inconsistent);
        }
        let heap_rows = if self.layout == Layout::Heap { n } else { 0 };
        if self.heap.live_rows != heap_rows {
            return Err(Inconsistent);
        }

        for e in LeafWalker::first(&self.by_customer_day) {
            let row = self.row_at(row::key_locator(e.key)).ok_or(Inconsistent)?;
            if row.customer != row::key_customer(e.key) || row.day != row::key_day(e.key) {
                return Err(Inconsistent);
            }
        }
        // In a one-column index equal values are adjacent, so uniqueness is
        // "no two neighbours agree".
        let mut previous = None;
        for e in LeafWalker::first(&self.by_code) {
            let row = self.row_at(row::key_locator(e.key)).ok_or(Inconsistent)?;
            let code = row::key_column(e.key);
            if u32::from(row.code) != code || previous == Some(code) {
                return Err(Inconsistent);
            }
            previous = Some(code);
        }
        if self.layout == Layout::Heap {
            previous = None;
            for e in LeafWalker::first(&self.primary) {
                let row = self.row_at(row::key_locator(e.key)).ok_or(Inconsistent)?;
                if row.id != row::key_column(e.key) || previous == Some(row.id) {
                    return Err(Inconsistent);
                }
                previous = Some(row.id);
            }
        }
        Ok(())
    }
}

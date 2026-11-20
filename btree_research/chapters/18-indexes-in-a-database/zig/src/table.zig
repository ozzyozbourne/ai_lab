//! A tiny table engine in two layouts. Same table, same indexes, same
//! queries; the only thing that differs is WHERE THE ROWS LIVE and therefore
//! what an index entry points at.
//!
//!   .clustered  (index-organized; Turso / SQLite table B-tree)
//!       primary tree:  id -> row              the row is IN the leaf
//!       secondary:     (columns, id)          locator = row id
//!       back to the row = one more DESCENT of the primary tree
//!
//!   .heap       (heap + index; Postgres)
//!       heap:          rows in arrival order  the row is at a TID
//!       primary key:   (id, TID)              just another index
//!       secondary:     (columns, TID)         locator = TID
//!       back to the row = one HEAP READ, no search
//!
//! Three functions contain every difference: `getById`, `fetch` and the
//! "store the row" step of `insert`. Everything about secondary indexes
//! (unique check, covering scan, prefix scan) is the same code for both.
//!
//! Invariants (checked by `validate`):
//!   1. Each of the three trees is a valid B+tree.
//!   2. Every tree has exactly one entry per row.
//!   3. Every index entry's locator leads to a live row whose columns equal
//!      the columns in the entry's key.
//!   4. No two rows share an id; no two rows share a code.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const BPlusTree = @import("base_tree.zig").BPlusTree;
const LeafWalker = @import("base_walk.zig").LeafWalker;
const Violation = @import("base_validate.zig").Violation;
const cursor_ = @import("cursor.zig");
const Counters = cursor_.Counters;
const Cursor = cursor_.Cursor;
const chargeDescent = cursor_.chargeDescent;
const Heap = @import("heap.zig").Heap;
const row_ = @import("row.zig");
const Row = row_.Row;
const Locator = row_.Locator;
const KeyRange = row_.KeyRange;

pub const Layout = enum { clustered, heap };

pub const InsertError = Allocator.Error || error{ DuplicatePrimaryKey, DuplicateCode };
pub const ValidateError = Violation || error{Inconsistent};

pub const Table = struct {
    layout: Layout,
    /// clustered: id -> packed row.   heap: (id, TID) -> unused.
    primary: BPlusTree,
    /// Only the heap layout puts rows here; stays empty when clustered.
    heap: Heap = .empty,
    /// (customer, day, locator) -> unused.
    by_customer_day: BPlusTree,
    /// (code, locator) -> unused. UNIQUE on code alone.
    by_code: BPlusTree,
    counters: Counters = .{},
    rows: usize = 0,

    /// `order` is the M of all three trees. Does not allocate.
    pub fn init(layout: Layout, order: usize) Table {
        return .{
            .layout = layout,
            .primary = .init(order),
            .by_customer_day = .init(order),
            .by_code = .init(order),
        };
    }

    pub fn deinit(self: *Table, gpa: Allocator) void {
        self.primary.deinit(gpa);
        self.heap.deinit(gpa);
        self.by_customer_day.deinit(gpa);
        self.by_code.deinit(gpa);
    }

    // ------------------------------------------------ the layout-specific part

    /// SELECT * FROM orders WHERE id = ?
    pub fn getById(self: *Table, id: u32) ?Row {
        switch (self.layout) {
            // The descent ENDS at the row: nothing left to fetch.
            .clustered => {
                chargeDescent(&self.counters, &self.primary);
                const value = self.primary.get(id) orelse return null;
                return row_.unpackRow(id, value);
            },
            // The descent ends at a TID; the row is one more page away.
            .heap => {
                const tid = self.probe(&self.primary, id) orelse return null;
                return self.fetch(tid);
            },
        }
    }

    /// The step "back to the table": from a locator found in an index entry
    /// to the row. This is the function the whole chapter is about.
    fn fetch(self: *Table, locator: Locator) ?Row {
        self.counters.row_fetches += 1;
        switch (self.layout) {
            // The locator is a KEY of another tree: search that tree.
            .clustered => {
                chargeDescent(&self.counters, &self.primary);
                const value = self.primary.get(locator) orelse return null;
                return row_.unpackRow(locator, value);
            },
            // The locator is an ADDRESS: go there.
            .heap => {
                self.counters.heap_reads += 1;
                return self.heap.fetch(locator);
            },
        }
    }

    /// `fetch` without the counters, for `validate`.
    fn rowAt(self: *const Table, locator: Locator) ?Row {
        return switch (self.layout) {
            .clustered => row_.unpackRow(locator, self.primary.get(locator) orelse return null),
            .heap => self.heap.fetch(locator),
        };
    }

    // ------------------------------------------------------- index primitives

    /// First locator filed under `value` in a one-column index, or null.
    /// One descent to the place where (value, smallest locator) would be.
    /// This is both the equality lookup and the UNIQUE check: the search key
    /// deliberately leaves the locator out, because "is there ANY entry with
    /// this value" is the question.
    fn probe(self: *Table, tree: *const BPlusTree, value: u32) ?Locator {
        var cursor = Cursor.seek(tree, row_.columnRange(value), &self.counters);
        return row_.keyLocator(cursor.next() orelse return null);
    }

    fn putNew(self: *Table, gpa: Allocator, tree: *BPlusTree, key: u64, value: u64) Allocator.Error!void {
        chargeDescent(&self.counters, tree);
        const old = try tree.put(gpa, key, value);
        assert(old == null); // the locator makes every index key distinct
    }

    fn remove(self: *Table, tree: *BPlusTree, key: u64) void {
        chargeDescent(&self.counters, tree);
        const old = tree.delete(key);
        assert(old != null); // invariant 2: the entry was there
    }

    // ---------------------------------------------------------------- writes

    /// INSERT. On any error the table is logically unchanged: the row is in
    /// none of the trees. (In the heap layout a failed insert may leave one
    /// dead heap slot behind, exactly the hole an aborted insert leaves.)
    pub fn insert(self: *Table, gpa: Allocator, row: Row) InsertError!void {
        // 1. Constraints first, before anything is written.
        const id_taken = switch (self.layout) {
            .clustered => blk: {
                chargeDescent(&self.counters, &self.primary);
                break :blk self.primary.get(row.id) != null;
            },
            .heap => self.probe(&self.primary, row.id) != null,
        };
        if (id_taken) return error.DuplicatePrimaryKey;
        if (self.probe(&self.by_code, row.code) != null) return error.DuplicateCode;

        // 2. Store the row; this decides its locator.
        var locator: Locator = row.id;
        var primary_key: u64 = row.id;
        var primary_value: u64 = row_.packRow(row);
        if (self.layout == .heap) {
            locator = try self.heap.append(gpa, row);
            primary_key = row_.columnKey(row.id, locator);
            primary_value = 0;
        }
        // Every later step can fail for lack of memory. `delete` never
        // allocates, so undoing the earlier steps cannot fail in turn.
        errdefer if (self.layout == .heap) self.heap.kill(locator);
        try self.putNew(gpa, &self.primary, primary_key, primary_value);
        errdefer _ = self.primary.delete(primary_key);

        // 3. One entry per secondary index, each ending in the locator.
        const customer_day_key = row_.customerDayKey(row.customer, row.day, locator);
        try self.putNew(gpa, &self.by_customer_day, customer_day_key, 0);
        errdefer _ = self.by_customer_day.delete(customer_day_key);
        try self.putNew(gpa, &self.by_code, row_.columnKey(row.code, locator), 0);
        self.rows += 1;
    }

    /// DELETE FROM orders WHERE id = ?   Returns false if there was no such
    /// row. The row must be READ before it can be deleted: its column values
    /// and its locator are the only way to name its index entries.
    pub fn delete(self: *Table, id: u32) bool {
        var locator: Locator = id;
        var primary_key: u64 = id;
        const row: Row = switch (self.layout) {
            .clustered => blk: {
                chargeDescent(&self.counters, &self.primary);
                break :blk row_.unpackRow(id, self.primary.get(id) orelse return false);
            },
            .heap => blk: {
                locator = self.probe(&self.primary, id) orelse return false;
                primary_key = row_.columnKey(id, locator);
                break :blk self.fetch(locator).?;
            },
        };
        // Because the locator is part of the key, each entry is found by an
        // exact descent even among many equal (customer, day) pairs.
        self.remove(&self.by_customer_day, row_.customerDayKey(row.customer, row.day, locator));
        self.remove(&self.by_code, row_.columnKey(row.code, locator));
        self.remove(&self.primary, primary_key);
        if (self.layout == .heap) self.heap.kill(locator);
        self.rows -= 1;
        return true;
    }

    // --------------------------------------------------------------- queries
    // Results are allocated from `arena`, the caller's per-query arena: one
    // reset frees them all, and no query has a free path of its own.

    /// SELECT * ... WHERE <a range of by_customer_day>: one descent of the
    /// index, then one row fetch PER ENTRY. Rows come back in index order.
    pub fn fetchScan(self: *Table, arena: Allocator, range: KeyRange) Allocator.Error![]Row {
        var out: std.ArrayList(Row) = .empty;
        var cursor = Cursor.seek(&self.by_customer_day, range, &self.counters);
        while (cursor.next()) |key| try out.append(arena, self.fetch(row_.keyLocator(key)).?);
        return out.items;
    }

    /// SELECT customer, day ... WHERE <a range of by_customer_day>: the
    /// index key already contains every requested column, so the scan never
    /// leaves the index. Zero row fetches in both layouts. Returns the keys;
    /// decode them with `row.keyCustomer` / `keyDay` / `keyLocator`.
    pub fn indexOnlyScan(self: *Table, arena: Allocator, range: KeyRange) Allocator.Error![]u64 {
        var out: std.ArrayList(u64) = .empty;
        var cursor = Cursor.seek(&self.by_customer_day, range, &self.counters);
        while (cursor.next()) |key| try out.append(arena, key);
        return out.items;
    }

    /// SELECT count(*) ... WHERE day = ?   `day` is the SECOND column of the
    /// index and the first is not fixed, so the matching entries are scattered
    /// over the whole index: every entry has to be read.
    pub fn countOnDay(self: *Table, day: u16) usize {
        var count: usize = 0;
        var cursor = Cursor.seek(&self.by_customer_day, .all, &self.counters);
        while (cursor.next()) |key| {
            if (row_.keyDay(key) == day) count += 1;
        }
        return count;
    }

    /// SELECT * ... WHERE code = ?   At most one row, by the UNIQUE constraint.
    pub fn getByCode(self: *Table, code: u16) ?Row {
        const locator = self.probe(&self.by_code, code) orelse return null;
        return self.fetch(locator);
    }

    // -------------------------------------------------------------- validate

    pub fn validate(self: *const Table) ValidateError!void {
        try self.primary.validate();
        try self.by_customer_day.validate();
        try self.by_code.validate();

        const n = self.rows;
        if (self.primary.len() != n or self.by_customer_day.len() != n or self.by_code.len() != n) return error.Inconsistent;
        const heap_rows = if (self.layout == .heap) n else 0;
        if (self.heap.live_rows != heap_rows) return error.Inconsistent;

        var walker = LeafWalker.first(&self.by_customer_day);
        while (walker.next()) |e| {
            const row = self.rowAt(row_.keyLocator(e.key)) orelse return error.Inconsistent;
            if (row.customer != row_.keyCustomer(e.key) or row.day != row_.keyDay(e.key)) return error.Inconsistent;
        }
        // In a one-column index equal values are adjacent, so uniqueness is
        // "no two neighbours agree".
        var previous: ?u32 = null;
        walker = LeafWalker.first(&self.by_code);
        while (walker.next()) |e| {
            const row = self.rowAt(row_.keyLocator(e.key)) orelse return error.Inconsistent;
            if (row.code != row_.keyColumn(e.key) or previous == row_.keyColumn(e.key)) return error.Inconsistent;
            previous = row_.keyColumn(e.key);
        }
        if (self.layout == .heap) {
            previous = null;
            walker = LeafWalker.first(&self.primary);
            while (walker.next()) |e| {
                const row = self.rowAt(row_.keyLocator(e.key)) orelse return error.Inconsistent;
                if (row.id != row_.keyColumn(e.key) or previous == row.id) return error.Inconsistent;
                previous = row.id;
            }
        }
    }
};

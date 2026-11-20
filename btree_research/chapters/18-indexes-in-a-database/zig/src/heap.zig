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
const std = @import("std");
const Allocator = std.mem.Allocator;
const Row = @import("row.zig").Row;

pub const slots_per_page = 4;

/// Page number and slot packed as `page * slots_per_page + slot`. Printed as
/// `(page,slot)` with the slot counted from 1, the way Postgres prints ctid.
pub const Tid = u32;

pub fn tidPage(tid: Tid) u32 {
    return tid / slots_per_page;
}

pub fn tidSlot(tid: Tid) u32 {
    return tid % slots_per_page + 1;
}

pub const Slot = union(enum) { live: Row, dead };

const Page = struct {
    slots: [slots_per_page]Slot = undefined,
    used: usize = 0,
};

pub const Heap = struct {
    /// Pages come from a pool: fixed size, allocated one at a time, never
    /// moved, all released together. (An `ArrayList(Row)` would copy every
    /// row each time it grows; a heap file only ever appends a page.)
    pool: std.heap.MemoryPool(Page) = .empty,
    /// Page number -> page. The analogue of the file's block map.
    pages: std.ArrayList(*Page) = .empty,
    live_rows: usize = 0,

    pub const empty: Heap = .{};

    pub fn deinit(self: *Heap, gpa: Allocator) void {
        self.pages.deinit(gpa);
        self.pool.deinit(gpa);
        self.* = .empty;
    }

    /// Stores the row in the next free slot. On error nothing has changed.
    pub fn append(self: *Heap, gpa: Allocator, row: Row) Allocator.Error!Tid {
        const need_page = self.pages.items.len == 0 or self.pages.getLast().used == slots_per_page;
        if (need_page) {
            try self.pages.ensureUnusedCapacity(gpa, 1);
            const page = try self.pool.create(gpa);
            page.* = .{};
            self.pages.appendAssumeCapacity(page);
        }
        const page_no = self.pages.items.len - 1;
        const page = self.pages.items[page_no];
        page.slots[page.used] = .{ .live = row };
        defer page.used += 1;
        self.live_rows += 1;
        return @intCast(page_no * slots_per_page + page.used);
    }

    /// The row at `tid`, or null if that slot is dead or was never used.
    pub fn fetch(self: *const Heap, tid: Tid) ?Row {
        if (tidPage(tid) >= self.pages.items.len) return null;
        const page = self.pages.items[tidPage(tid)];
        const slot = tid % slots_per_page;
        if (slot >= page.used) return null;
        return switch (page.slots[slot]) {
            .live => |row| row,
            .dead => null,
        };
    }

    /// Marks the slot dead. The slot is not reused and later TIDs do not
    /// change, so index entries of OTHER rows stay correct.
    pub fn kill(self: *Heap, tid: Tid) void {
        const page = self.pages.items[tidPage(tid)];
        std.debug.assert(page.slots[tid % slots_per_page] == .live);
        page.slots[tid % slots_per_page] = .dead;
        self.live_rows -= 1;
    }

    pub fn pageCount(self: *const Heap) usize {
        return self.pages.items.len;
    }

    /// The used slots of one page, for printing and validation.
    pub fn pageSlots(self: *const Heap, page_no: usize) []const Slot {
        const page = self.pages.items[page_no];
        return page.slots[0..page.used];
    }
};

test "TIDs are stable: appending and killing never moves a row" {
    const gpa = std.testing.allocator;
    var heap: Heap = .empty;
    defer heap.deinit(gpa);
    var tids: [10]Tid = undefined;
    for (&tids, 0..) |*tid, i| {
        tid.* = try heap.append(gpa, .{ .id = @intCast(i), .customer = 1, .day = 2, .amount = 3, .code = @intCast(i) });
    }
    try std.testing.expectEqual(3, heap.pageCount());
    try std.testing.expectEqual(9, tids[9]);
    try std.testing.expectEqual(2, tidPage(tids[9]));
    try std.testing.expectEqual(2, tidSlot(tids[9]));

    heap.kill(tids[4]);
    try std.testing.expectEqual(null, heap.fetch(tids[4]));
    try std.testing.expectEqual(5, heap.fetch(tids[5]).?.id);
    try std.testing.expectEqual(9, heap.live_rows);
    try std.testing.expectEqual(null, heap.fetch(10)); // never used
    try std.testing.expectEqual(null, heap.fetch(400)); // no such page
    // The hole is not reused: the next row gets a fresh TID.
    try std.testing.expectEqual(10, try heap.append(gpa, .{ .id = 99, .customer = 0, .day = 0, .amount = 0, .code = 0 }));
}

test "append under allocation failure changes nothing" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var heap: Heap = .empty;
        defer heap.deinit(gpa);
        const result = heap.append(gpa, .{ .id = 1, .customer = 0, .day = 0, .amount = 0, .code = 0 });
        if (result) |tid| {
            try std.testing.expectEqual(0, tid);
            break;
        } else |_| {
            try std.testing.expectEqual(0, heap.live_rows);
            try std.testing.expectEqual(0, heap.pageCount());
        }
    }
    try std.testing.expect(fail_index > 0);
}

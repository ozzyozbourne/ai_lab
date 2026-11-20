//! Tests of the table engine: fixed scenarios, the cost claims of the chapter
//! as assertions, a seeded model test of both layouts against a plain list of
//! rows, allocation failure with rollback, and proof that `validate` catches
//! an index that disagrees with the table.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Table = @import("table.zig").Table;
const Layout = @import("table.zig").Layout;
const Counters = @import("cursor.zig").Counters;
const row_ = @import("row.zig");
const Row = row_.Row;
const SplitMix64 = @import("prng.zig").SplitMix64;

const layouts = [_]Layout{ .clustered, .heap };

/// The 12 rows of the demo program: ids are the canonical keys of chapters
/// 03 to 08, in the canonical order.
pub const demo_rows = [_]Row{
    .{ .id = 10, .customer = 7, .day = 12, .amount = 250, .code = 141 },
    .{ .id = 20, .customer = 3, .day = 4, .amount = 40, .code = 107 },
    .{ .id = 5, .customer = 7, .day = 12, .amount = 75, .code = 163 },
    .{ .id = 6, .customer = 9, .day = 2, .amount = 300, .code = 118 },
    .{ .id = 12, .customer = 7, .day = 3, .amount = 120, .code = 155 },
    .{ .id = 30, .customer = 3, .day = 9, .amount = 90, .code = 102 },
    .{ .id = 7, .customer = 7, .day = 21, .amount = 35, .code = 129 },
    .{ .id = 17, .customer = 9, .day = 15, .amount = 510, .code = 170 },
    .{ .id = 3, .customer = 3, .day = 4, .amount = 60, .code = 111 },
    .{ .id = 25, .customer = 7, .day = 17, .amount = 125, .code = 134 },
    .{ .id = 1, .customer = 3, .day = 28, .amount = 999, .code = 148 },
    .{ .id = 15, .customer = 9, .day = 2, .amount = 45, .code = 126 },
};

fn buildDemo(gpa: Allocator, layout: Layout) !Table {
    var table: Table = .init(layout, 4);
    errdefer table.deinit(gpa);
    for (demo_rows) |row| try table.insert(gpa, row);
    return table;
}

fn expectIds(expected: []const u32, rows: []const Row) !void {
    try testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |id, row| try testing.expectEqual(id, row.id);
}

test "point lookup: the clustered descent ends at the row, the heap needs one more read" {
    const gpa = testing.allocator;
    for (layouts) |layout| {
        var table = try buildDemo(gpa, layout);
        defer table.deinit(gpa);
        try table.validate();
        const before = table.counters;
        try testing.expectEqual(demo_rows[7], table.getById(17).?);
        try testing.expectEqual(null, table.getById(18));
        const cost = table.counters.minus(before);
        try testing.expectEqual(2, cost.descents);
        // Only the hit on the heap layout leaves the index.
        try testing.expectEqual(@as(usize, if (layout == .heap) 1 else 0), cost.row_fetches);
        try testing.expectEqual(cost.row_fetches, cost.heap_reads);
    }
}

test "secondary index: k rows cost k extra descents (clustered) or k heap reads (heap)" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (layouts) |layout| {
        var table = try buildDemo(gpa, layout);
        defer table.deinit(gpa);
        const before = table.counters;
        const rows = try table.fetchScan(arena.allocator(), row_.customerRange(7));
        // Index order is (day, locator). The two rows of day 12 are ordered by
        // row id in the clustered layout and by arrival (TID) in the heap.
        const expected: []const u32 = if (layout == .clustered) &.{ 12, 5, 10, 25, 7 } else &.{ 12, 10, 5, 25, 7 };
        try expectIds(expected, rows);
        const cost = table.counters.minus(before);
        try testing.expectEqual(5, cost.row_fetches);
        try testing.expectEqual(5, cost.index_entries);
        switch (layout) {
            .clustered => {
                try testing.expectEqual(1 + 5, cost.descents);
                try testing.expectEqual(0, cost.heap_reads);
            },
            .heap => {
                try testing.expectEqual(1, cost.descents);
                try testing.expectEqual(5, cost.heap_reads);
            },
        }
    }
}

test "covering scan never leaves the index, in either layout" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (layouts) |layout| {
        var table = try buildDemo(gpa, layout);
        defer table.deinit(gpa);
        const before = table.counters;
        const keys = try table.indexOnlyScan(arena.allocator(), row_.customerRange(7));
        try testing.expectEqual(5, keys.len);
        for (keys, [_]u16{ 3, 12, 12, 17, 21 }) |key, day| {
            try testing.expectEqual(7, row_.keyCustomer(key));
            try testing.expectEqual(day, row_.keyDay(key));
        }
        const cost = table.counters.minus(before);
        try testing.expectEqual(1, cost.descents);
        try testing.expectEqual(0, cost.row_fetches);
        try testing.expectEqual(0, cost.heap_reads);
        // The clustered index covers the primary key as well: its locator IS the id.
        if (layout == .clustered) try testing.expectEqual(12, row_.keyLocator(keys[0]));
    }
}

test "prefix scans: leading column, leading column plus range, and a non-prefix" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var table = try buildDemo(gpa, .clustered);
    defer table.deinit(gpa);
    const a = arena.allocator();

    try expectIds(&.{ 12, 5, 10, 25, 7 }, try table.fetchScan(a, row_.customerRange(7)));
    try expectIds(&.{ 5, 10, 25 }, try table.fetchScan(a, row_.customerDaysRange(7, 10, 20)));
    try expectIds(&.{ 5, 10 }, try table.fetchScan(a, row_.customerDaysRange(7, 12, 12)));
    try expectIds(&.{}, try table.fetchScan(a, row_.customerDaysRange(7, 13, 16)));
    try expectIds(&.{}, try table.fetchScan(a, row_.customerRange(8)));
    try expectIds(&.{ 6, 15, 17 }, try table.fetchScan(a, row_.customerRange(9)));

    // day alone is not a prefix: the whole index is read to find 2 entries.
    const before = table.counters;
    try testing.expectEqual(2, table.countOnDay(12));
    try testing.expectEqual(12, table.counters.minus(before).index_entries);
    // ... while the two-column prefix reads exactly the 2 it returns.
    const before_prefix = table.counters;
    _ = try table.indexOnlyScan(a, row_.customerDaysRange(7, 12, 12));
    try testing.expectEqual(2, table.counters.minus(before_prefix).index_entries);
}

test "unique constraint and primary key reject duplicates and change nothing" {
    const gpa = testing.allocator;
    for (layouts) |layout| {
        var table = try buildDemo(gpa, layout);
        defer table.deinit(gpa);
        const dead_before = table.heap.pageCount();

        const before = table.counters;
        try testing.expectError(error.DuplicateCode, table.insert(gpa, .{ .id = 40, .customer = 3, .day = 1, .amount = 10, .code = 129 }));
        // Rejected after two descents (id check, code check), before any write.
        const cost = table.counters.minus(before);
        try testing.expectEqual(2, cost.descents);
        // The README's hand trace. The code probe seeks (129, smallest
        // locator), which is below the separator (129, locator of id 7): the
        // descent ends one leaf early, and the conflicting entry is the first
        // one after a leaf hop. 3 + 3 nodes for the descents, 1 for the hop.
        try testing.expectEqual(7, cost.tree_nodes);
        try testing.expectEqual(1, cost.index_entries);
        try testing.expectEqual(0, cost.row_fetches);
        try testing.expectError(error.DuplicatePrimaryKey, table.insert(gpa, .{ .id = 12, .customer = 3, .day = 1, .amount = 10, .code = 500 }));
        // The id is checked first, so a row that violates both reports the id.
        try testing.expectError(error.DuplicatePrimaryKey, table.insert(gpa, .{ .id = 12, .customer = 3, .day = 1, .amount = 10, .code = 129 }));

        try testing.expectEqual(12, table.rows);
        try testing.expectEqual(dead_before, table.heap.pageCount());
        try testing.expectEqual(null, table.getById(40));
        try testing.expectEqual(null, table.getByCode(500));
        try testing.expectEqual(7, table.getByCode(129).?.id);
        try table.validate();

        // Deleting the holder frees the code for somebody else.
        try testing.expect(table.delete(7));
        try testing.expect(!table.delete(7));
        try table.insert(gpa, .{ .id = 40, .customer = 3, .day = 1, .amount = 10, .code = 129 });
        try testing.expectEqual(40, table.getByCode(129).?.id);
        try table.validate();
    }
}

test "heap: a deleted row leaves a dead slot and every other TID still works" {
    const gpa = testing.allocator;
    var table = try buildDemo(gpa, .heap);
    defer table.deinit(gpa);
    try testing.expectEqual(3, table.heap.pageCount());
    try testing.expect(table.delete(5)); // TID 2 = (0,3)
    try testing.expect(table.heap.pageSlots(0)[2] == .dead);
    try testing.expectEqual(11, table.heap.live_rows);
    for (demo_rows) |row| {
        if (row.id == 5) continue;
        try testing.expectEqual(row, table.getById(row.id).?);
        try testing.expectEqual(row, table.getByCode(row.code).?);
    }
    try table.validate();
}

// ------------------------------------------------------------- model test

/// The oracle: every row in arrival order, searched linearly. `seq` is the
/// arrival number, which is the order of TIDs in the heap layout.
const Oracle = struct {
    const Item = struct { row: Row, seq: usize };
    items: std.ArrayList(Item) = .empty,
    next_seq: usize = 0,

    fn find(self: *const Oracle, id: u32) ?usize {
        for (self.items.items, 0..) |item, i| if (item.row.id == id) return i;
        return null;
    }

    fn hasCode(self: *const Oracle, code: u16) bool {
        for (self.items.items) |item| if (item.row.code == code) return true;
        return false;
    }

    /// Rows of `customer` with day in [lo, hi], in the order the index of
    /// the given layout returns them: (day, id) or (day, arrival).
    fn select(self: *const Oracle, gpa: Allocator, layout: Layout, customer: u16, lo: u16, hi: u16) ![]Item {
        var out: std.ArrayList(Item) = .empty;
        errdefer out.deinit(gpa);
        for (self.items.items) |item| {
            if (item.row.customer == customer and item.row.day >= lo and item.row.day <= hi) try out.append(gpa, item);
        }
        std.mem.sort(Item, out.items, layout, struct {
            fn lessThan(l: Layout, a: Item, b: Item) bool {
                if (a.row.day != b.row.day) return a.row.day < b.row.day;
                return if (l == .clustered) a.row.id < b.row.id else a.seq < b.seq;
            }
        }.lessThan);
        return out.toOwnedSlice(gpa);
    }
};

fn modelTest(gpa: Allocator, layout: Layout, order: usize, seed: u64, ops: usize) !void {
    var table: Table = .init(layout, order);
    defer table.deinit(gpa);
    var oracle: Oracle = .{};
    defer oracle.items.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var rng = SplitMix64.init(seed);

    for (0..ops) |op_index| {
        // The per-query arena: everything the last query returned dies here.
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const id: u32 = @intCast(rng.below(300));
        switch (rng.below(10)) {
            0...4 => { // insert; small ranges so both kinds of duplicate happen
                const row: Row = .{
                    .id = id,
                    .customer = @intCast(rng.below(8)),
                    .day = @intCast(rng.below(20)),
                    .amount = @intCast(rng.below(1000)),
                    .code = @intCast(rng.below(400)),
                };
                const expected: anyerror!void = if (oracle.find(id) != null)
                    error.DuplicatePrimaryKey
                else if (oracle.hasCode(row.code))
                    error.DuplicateCode
                else {};
                try testing.expectEqual(expected, table.insert(gpa, row));
                if (expected) |_| {
                    try oracle.items.append(gpa, .{ .row = row, .seq = oracle.next_seq });
                    oracle.next_seq += 1;
                } else |_| {}
            },
            5...6 => { // delete
                const at = oracle.find(id);
                try testing.expectEqual(at != null, table.delete(id));
                if (at) |i| _ = oracle.items.orderedRemove(i);
            },
            7 => { // point lookups by both unique keys
                const at = oracle.find(id);
                const expected: ?Row = if (at) |i| oracle.items.items[i].row else null;
                try testing.expectEqual(expected, table.getById(id));
                if (expected) |row| try testing.expectEqual(row, table.getByCode(row.code).?);
            },
            else => { // prefix scan, fetched and index-only
                const customer: u16 = @intCast(rng.below(9));
                const d1: u16 = @intCast(rng.below(20));
                const d2: u16 = @intCast(rng.below(20));
                const lo = @min(d1, d2);
                const hi = if (rng.chance(1, 3)) std.math.maxInt(u16) else @max(d1, d2);
                const expected = try oracle.select(a, layout, customer, lo, hi);
                const range = row_.customerDaysRange(customer, lo, hi);
                const rows = try table.fetchScan(a, range);
                const keys = try table.indexOnlyScan(a, range);
                try testing.expectEqual(expected.len, rows.len);
                try testing.expectEqual(expected.len, keys.len);
                for (expected, rows, keys) |item, row, key| {
                    try testing.expectEqual(item.row, row);
                    try testing.expectEqual(item.row.day, row_.keyDay(key));
                }
                var on_day: usize = 0;
                for (oracle.items.items) |item| on_day += @intFromBool(item.row.day == lo);
                try testing.expectEqual(on_day, table.countOnDay(lo));
            },
        }
        try testing.expectEqual(oracle.items.items.len, table.rows);
        if (op_index % 64 == 0) try table.validate();
    }
    try table.validate();
}

test "model: both layouts agree with a plain list of rows" {
    for (layouts) |layout| {
        for ([_]usize{ 3, 4, 16 }) |order| {
            try modelTest(testing.allocator, layout, order, 18, 6000);
            try modelTest(testing.allocator, layout, order, 1800 + order, 3000);
        }
    }
}

// ------------------------------------------------------ allocation failure

test "insert under allocation failure: the row is in all three trees or in none" {
    for (layouts) |layout| {
        var saw_dead_slot = false;
        var completed = false;
        var fail_index: usize = 0;
        while (!completed) : (fail_index += 1) {
            var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
            const gpa = failing.allocator();
            var table: Table = .init(layout, 3);
            defer table.deinit(gpa);
            var inserted: usize = 0;
            for (0..40) |i| {
                const row: Row = .{ .id = @intCast(i * 7 % 40), .customer = @intCast(i % 3), .day = @intCast(i % 5), .amount = 1, .code = @intCast(i) };
                table.insert(gpa, row) catch |err| {
                    try testing.expectEqual(error.OutOfMemory, err);
                    // Logically unchanged: valid, and the failed row is nowhere.
                    try table.validate();
                    try testing.expectEqual(inserted, table.rows);
                    try testing.expectEqual(null, table.getById(row.id));
                    try testing.expectEqual(null, table.getByCode(row.code));
                    // A heap slot was taken and then killed: the rollback ran
                    // AFTER the heap append had succeeded.
                    if (table.heap.live_rows < table.heap.pageCount() * 4 and table.heap.live_rows == inserted) {
                        for (0..table.heap.pageCount()) |p| {
                            for (table.heap.pageSlots(p)) |slot| saw_dead_slot = saw_dead_slot or slot == .dead;
                        }
                    }
                    // The same insert succeeds once memory is available again.
                    failing.fail_index = std.math.maxInt(usize);
                    try table.insert(gpa, row);
                    try table.validate();
                    break;
                };
                inserted += 1;
            } else completed = true;
        }
        try testing.expect(fail_index > 10); // many different failure points were hit
        try testing.expectEqual(layout == .heap, saw_dead_slot);
    }
}

// ------------------------------------------------------ validate has teeth

test "validate catches an index entry without a row, and a row without an entry" {
    const gpa = testing.allocator;
    for (layouts) |layout| {
        var table = try buildDemo(gpa, layout);
        defer table.deinit(gpa);
        try table.validate();

        // An extra entry in the secondary index (counts no longer agree).
        _ = try table.by_customer_day.put(gpa, row_.customerDayKey(7, 13, 999), 0);
        try testing.expectError(error.Inconsistent, table.validate());
        _ = table.by_customer_day.delete(row_.customerDayKey(7, 13, 999));
        try table.validate();

        // Same count, but one entry files row 7 under the wrong day.
        const locator = row_.keyLocator(findEntry(&table, 7, 21));
        _ = table.by_customer_day.delete(row_.customerDayKey(7, 21, locator));
        _ = try table.by_customer_day.put(gpa, row_.customerDayKey(7, 22, locator), 0);
        try testing.expectError(error.Inconsistent, table.validate());
    }
}

fn findEntry(table: *Table, customer: u16, day: u16) u64 {
    var cursor = @import("cursor.zig").Cursor.seek(&table.by_customer_day, row_.customerDaysRange(customer, day, day), &table.counters);
    return cursor.next().?;
}

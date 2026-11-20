//! Demo program of chapter 18. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Rust program's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const lib = @import("ch18_indexes_in_a_database");
const Table = lib.Table;
const Layout = lib.Layout;
const Row = lib.Row;
const Counters = lib.Counters;
const BPlusTree = lib.BPlusTree;
const row_ = lib.row;

/// Ids are the canonical keys of chapters 03 to 08 in the canonical order, so
/// the clustered primary tree is the tree chapter 07 drew.
const demo_rows = [_]Row{
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

const layouts = [_]Layout{ .clustered, .heap };

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &file_writer.interface;
    try run(init.gpa, w);
    try w.flush();
}

pub fn run(gpa: Allocator, w: *Writer) !void {
    // Tables own their trees and live as long as the program: general-purpose
    // allocator. Query results live until the next query: one arena, reset.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tables: [2]Table = .{ .init(.clustered, 4), .init(.heap, 4) };
    defer for (&tables) |*t| t.deinit(gpa);

    try w.writeAll("== 1. One table, two layouts ==\n");
    try w.writeAll("orders(id PRIMARY KEY, customer, day, amount, code UNIQUE); INDEX by_customer_day(customer, day)\n");
    try w.writeAll("index key = columns, then locator, packed into one u64: customer:16 | day:16 | locator:32\n");
    try w.writeAll("12 rows inserted with ids 10 20 5 6 12 30 7 17 3 25 1 15; every tree has order M = 4\n");
    for (&tables) |*t| {
        for (demo_rows) |row| try t.insert(gpa, row);
        try t.validate();
        try describe(w, t);
    }

    try w.writeAll("\n== 2. Point lookup: SELECT * FROM orders WHERE id = 17 ==\n");
    for (&tables) |*t| {
        const before = t.counters;
        const row = t.getById(17).?;
        try w.print("{s}: ", .{name(t.layout)});
        try printRow(w, row);
        try w.writeByte('\n');
        try printCost(w, t.counters.minus(before));
    }

    try w.writeAll("\n== 3. Secondary index, then back to the row: SELECT * WHERE customer = 7 ==\n");
    for (&tables) |*t| {
        _ = arena_state.reset(.retain_capacity);
        const before = t.counters;
        const rows = try t.fetchScan(arena, row_.customerRange(7));
        try w.print("{s}: ids", .{name(t.layout)});
        for (rows) |row| try w.print(" {d}", .{row.id});
        try w.writeAll(", amounts");
        for (rows) |row| try w.print(" {d}", .{row.amount});
        try w.writeByte('\n');
        try printCost(w, t.counters.minus(before));
    }

    try w.writeAll("\n== 4. Covering (index-only) scan: SELECT day WHERE customer = 7 ==\n");
    for (&tables) |*t| {
        _ = arena_state.reset(.retain_capacity);
        const before = t.counters;
        const keys = try t.indexOnlyScan(arena, row_.customerRange(7));
        try w.print("{s}: days", .{name(t.layout)});
        for (keys) |key| try w.print(" {d}", .{row_.keyDay(key)});
        try w.writeAll(", locators in the entries");
        for (keys) |key| {
            try w.writeByte(' ');
            try printLocator(w, t.layout, row_.keyLocator(key));
        }
        try w.writeByte('\n');
        try printCost(w, t.counters.minus(before));
    }
    try w.writeAll("clustered only: the locator is the id, so SELECT id, day is covered as well\n");

    try w.writeAll("\n== 5. Composite key: which predicates are one contiguous run of the index? ==\n");
    const prefix_queries = [_]struct { text: []const u8, range: row_.KeyRange }{
        .{ .text = "customer = 7 AND day BETWEEN 10 AND 20", .range = row_.customerDaysRange(7, 10, 20) },
        .{ .text = "customer = 7 AND day = 12", .range = row_.customerDaysRange(7, 12, 12) },
        .{ .text = "customer = 8", .range = row_.customerRange(8) },
    };
    for (prefix_queries) |q| {
        try w.print("WHERE {s}\n", .{q.text});
        for (&tables) |*t| {
            _ = arena_state.reset(.retain_capacity);
            const before = t.counters;
            const rows = try t.fetchScan(arena, q.range);
            try w.print("{s}: ids", .{name(t.layout)});
            for (rows) |row| try w.print(" {d}", .{row.id});
            if (rows.len == 0) try w.writeAll(" (none)");
            try w.writeByte('\n');
            try printCost(w, t.counters.minus(before));
        }
    }
    try w.writeAll("WHERE day = 12   (not a prefix: the first column is free, so the whole index is read)\n");
    for (&tables) |*t| {
        const before = t.counters;
        const count = t.countOnDay(12);
        try w.print("{s}: count {d}\n", .{ name(t.layout), count });
        try printCost(w, t.counters.minus(before));
    }

    try w.writeAll("\n== 6. Unique constraint: probe the index before writing ==\n");
    const attempts = [_]Row{
        .{ .id = 40, .customer = 3, .day = 1, .amount = 10, .code = 129 }, // code of row 7
        .{ .id = 12, .customer = 3, .day = 1, .amount = 10, .code = 500 }, // id taken
        .{ .id = 40, .customer = 3, .day = 1, .amount = 10, .code = 500 }, // fine
    };
    for (attempts) |row| {
        try w.print("INSERT id={d} code={d}\n", .{ row.id, row.code });
        for (&tables) |*t| {
            const before = t.counters;
            const outcome: []const u8 = if (t.insert(gpa, row)) |_| "ok" else |err| switch (err) {
                error.DuplicatePrimaryKey => "rejected, duplicate primary key",
                error.DuplicateCode => "rejected, duplicate code",
                error.OutOfMemory => return err,
            };
            try w.print("{s}: {s}; {d} rows\n", .{ name(t.layout), outcome, t.rows });
            try printCost(w, t.counters.minus(before));
            try t.validate();
        }
    }

    try w.writeAll("\n== 7. Delete: read the row first, its columns name the index entries ==\n");
    try w.writeAll("DELETE FROM orders WHERE id = 5\n");
    for (&tables) |*t| {
        const before = t.counters;
        const deleted = t.delete(5);
        try w.print("{s}: deleted {}; {d} rows\n", .{ name(t.layout), deleted, t.rows });
        try printCost(w, t.counters.minus(before));
        try w.writeAll("  by_customer_day:");
        try printIndex(w, t.layout, &t.by_customer_day, .customer_day);
        if (t.layout == .heap) try printHeap(w, t);
        try t.validate();
    }

    try scaleRun(gpa, &arena_state, w);
}

fn name(layout: Layout) []const u8 {
    return switch (layout) {
        .clustered => "clustered",
        .heap => "heap     ",
    };
}

fn printRow(w: *Writer, row: Row) !void {
    try w.print("id={d} customer={d} day={d} amount={d} code={d}", .{ row.id, row.customer, row.day, row.amount, row.code });
}

/// A row id prints as `#17`, a TID as `(page,slot)`.
fn printLocator(w: *Writer, layout: Layout, locator: lib.Locator) !void {
    switch (layout) {
        .clustered => try w.print("#{d}", .{locator}),
        .heap => try w.print("({d},{d})", .{ lib.heap.tidPage(locator), lib.heap.tidSlot(locator) }),
    }
}

fn printCost(w: *Writer, c: Counters) !void {
    try w.print("  cost: descents={d} tree nodes={d} index entries={d} row fetches={d} heap reads={d} -> {d} page reads\n", .{
        c.descents, c.tree_nodes, c.index_entries, c.row_fetches, c.heap_reads, c.pageReads(),
    });
}

const KeyKind = enum { customer_day, column };

/// The entries of an index in leaf-chain order; ` | ` separates leaves.
fn printIndex(w: *Writer, layout: Layout, tree: *const BPlusTree, kind: KeyKind) !void {
    try w.print(" height {d}, {d} nodes\n   ", .{ tree.height, tree.nodes.liveCount() });
    var id = tree.first_leaf;
    while (id != .nil) {
        const n = tree.nodes.get(id);
        for (n.keySlice()) |key| {
            switch (kind) {
                .customer_day => try w.print(" ({d},{d},", .{ row_.keyCustomer(key), row_.keyDay(key) }),
                .column => try w.print(" ({d},", .{row_.keyColumn(key)}),
            }
            try printLocator(w, layout, row_.keyLocator(key));
            try w.writeByte(')');
        }
        id = n.kind.leaf.next;
        if (id != .nil) try w.writeAll(" |");
    }
    try w.writeByte('\n');
}

fn printHeap(w: *Writer, t: *const Table) !void {
    for (0..t.heap.pageCount()) |page| {
        try w.print("  heap page {d}:", .{page});
        for (t.heap.pageSlots(page), 1..) |slot, slot_no| {
            try w.print(" ({d},{d})=", .{ page, slot_no });
            switch (slot) {
                .live => |row| try w.print("id {d}", .{row.id}),
                .dead => try w.writeAll("dead"),
            }
        }
        try w.writeByte('\n');
    }
}

fn describe(w: *Writer, t: *const Table) !void {
    switch (t.layout) {
        .clustered => {
            try w.writeAll("\n-- clustered: the row is in the primary tree; locator = row id, printed #id --\n");
            try w.writeAll("  primary tree (id -> row): ");
            try lib.dump.dump(&t.primary, w);
        },
        .heap => {
            try w.writeAll("\n-- heap + index: the row is in the heap; locator = TID, printed (page,slot) --\n");
            try printHeap(w, t);
            try w.writeAll("  primary key index (id,TID):");
            try printIndex(w, t.layout, &t.primary, .column);
        },
    }
    try w.writeAll("  by_customer_day (customer,day,locator):");
    try printIndex(w, t.layout, &t.by_customer_day, .customer_day);
    try w.writeAll("  by_code (code,locator):");
    try printIndex(w, t.layout, &t.by_code, .column);
}

/// The same queries on 2000 seeded random rows and wider nodes; prints only
/// counts. Both layouts must return the same rows.
fn scaleRun(gpa: Allocator, arena_state: *std.heap.ArenaAllocator, w: *Writer) !void {
    const arena = arena_state.allocator();
    const row_target = 2000;
    try w.writeAll("\n== 8. The same queries on 2000 random rows, order M = 16 ==\n");
    var tables: [2]Table = .{ .init(.clustered, 16), .init(.heap, 16) };
    defer for (&tables) |*t| t.deinit(gpa);
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);

    var rng = lib.prng.SplitMix64.init(18);
    var attempts: u64 = 0;
    var load: [2]Counters = undefined;
    while (ids.items.len < row_target) : (attempts += 1) {
        const row: Row = .{
            .id = @intCast(rng.below(100_000)),
            .customer = @intCast(rng.below(50)),
            .day = @intCast(rng.below(365)),
            .amount = @intCast(rng.below(1000)),
            // 7919 is odd, so i -> i * 7919 mod 65536 never repeats: codes are unique.
            .code = @intCast(attempts * 7919 % 65536),
        };
        var accepted: [2]bool = undefined;
        for (&tables, &accepted) |*t, *ok| {
            ok.* = if (t.insert(gpa, row)) |_| true else |err| switch (err) {
                error.DuplicatePrimaryKey => false,
                else => return err,
            };
        }
        std.debug.assert(accepted[0] == accepted[1]);
        if (accepted[0]) try ids.append(gpa, row.id);
    }
    try w.print("{d} rows loaded, {d} inserts rejected for a duplicate id\n", .{ ids.items.len, attempts - row_target });
    for (&tables, &load) |*t, *l| {
        try t.validate();
        l.* = t.counters;
        try w.print("{s}: primary height {d} ({d} nodes), by_customer_day height {d} ({d} nodes), by_code height {d} ({d} nodes), heap pages {d}\n", .{
            name(t.layout),              t.primary.height,                    t.primary.nodes.liveCount(),
            t.by_customer_day.height,    t.by_customer_day.nodes.liveCount(), t.by_code.height,
            t.by_code.nodes.liveCount(), t.heap.pageCount(),
        });
    }

    try w.writeAll("\nlayout     query                                rows  descents  tree nodes  row fetches  heap reads  page reads\n");
    for (&tables, load) |*t, l| try printLine(w, t.layout, "2000 inserts", row_target, l);

    // Each workload runs on both layouts; `checksum` proves they agree.
    var checksum: [2]u64 = .{ 0, 0 };
    var returned: [2]usize = .{ 0, 0 };

    for (&tables, 0..) |*t, i| {
        const before = t.counters;
        for (ids.items) |id| checksum[i] +%= t.getById(id).?.amount;
        try printLine(w, t.layout, "2000 x WHERE id = ?", ids.items.len, t.counters.minus(before));
    }
    for (&tables, 0..) |*t, i| {
        const before = t.counters;
        returned[i] = 0;
        for (0..50) |customer| {
            _ = arena_state.reset(.retain_capacity);
            const rows = try t.fetchScan(arena, row_.customerRange(@intCast(customer)));
            for (rows) |row| checksum[i] +%= @as(u64, row.id) * row.amount;
            returned[i] += rows.len;
        }
        try printLine(w, t.layout, "50 x SELECT * WHERE customer = ?", returned[i], t.counters.minus(before));
    }
    for (&tables, 0..) |*t, i| {
        const before = t.counters;
        returned[i] = 0;
        for (0..50) |customer| {
            _ = arena_state.reset(.retain_capacity);
            const keys = try t.indexOnlyScan(arena, row_.customerRange(@intCast(customer)));
            for (keys) |key| checksum[i] +%= row_.keyDay(key);
            returned[i] += keys.len;
        }
        try printLine(w, t.layout, "50 x SELECT day WHERE customer = ?", returned[i], t.counters.minus(before));
    }
    for (&tables, 0..) |*t, i| {
        const before = t.counters;
        returned[i] = 0;
        for (0..50) |customer| {
            _ = arena_state.reset(.retain_capacity);
            const rows = try t.fetchScan(arena, row_.customerDaysRange(@intCast(customer), 100, 129));
            for (rows) |row| checksum[i] +%= @as(u64, row.id) * row.day;
            returned[i] += rows.len;
        }
        try printLine(w, t.layout, "50 x ... AND day BETWEEN 100 AND 129", returned[i], t.counters.minus(before));
    }
    for (&tables, 0..) |*t, i| {
        const before = t.counters;
        returned[i] = t.countOnDay(180);
        checksum[i] +%= returned[i];
        try printLine(w, t.layout, "1 x SELECT count(*) WHERE day = 180", returned[i], t.counters.minus(before));
    }
    for (&tables, 0..) |*t, i| {
        const before = t.counters;
        returned[i] = 0;
        for (ids.items, 0..) |id, n| {
            if (n % 4 == 0) returned[i] += @intFromBool(t.delete(id));
        }
        try printLine(w, t.layout, "500 x DELETE WHERE id = ?", returned[i], t.counters.minus(before));
        try t.validate();
    }
    try w.print("\nboth layouts returned the same rows: {}; rows left: {d} and {d}; dead heap slots: {d}\n", .{
        checksum[0] == checksum[1] and returned[0] == returned[1],
        tables[0].rows,
        tables[1].rows,
        tables[1].heap.pageCount() * lib.heap.slots_per_page - tables[1].heap.live_rows,
    });
}

fn printLine(w: *Writer, layout: Layout, query: []const u8, rows: usize, c: Counters) !void {
    try w.print("{s}  {s:<36} {d:>4}  {d:>8}  {d:>10}  {d:>11}  {d:>10}  {d:>10}\n", .{
        name(layout), query, rows, c.descents, c.tree_nodes, c.row_fetches, c.heap_reads, c.pageReads(),
    });
}

test "run prints exactly expected_output.txt" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}

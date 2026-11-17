//! The fixed scenario printed by `zig build run`. It writes to any
//! `*std.Io.Writer`, so a test can capture it and compare it with
//! ../expected_output.txt (the Rust program prints the same bytes).
const std = @import("std");
const Io = std.Io;
const sp = @import("slotted_page.zig");
const ops = @import("ops.zig");
const workload = @import("workload.zig");
const SlottedPage = sp.SlottedPage;

pub fn run(w: *Io.Writer) Io.Writer.Error!void {
    try partOne(w);
    try partTwo(w);
    try partThree(w);
}

/// One page, one operation at a time: the worked example of the README and
/// the default animation of the visualization.
fn partOne(w: *Io.Writer) Io.Writer.Error!void {
    var buf: [sp.page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    try w.writeAll("== Part 1: one page, step by step ==\n");
    try w.writeAll("init\n");
    try describe(w, page);

    const Step = struct { op: enum { put, delete, compact }, key: []const u8 = "", value: []const u8 = "" };
    const steps = [_]Step{
        .{ .op = .put, .key = "mango", .value = "yellow" },
        .{ .op = .put, .key = "apple", .value = "red" },
        .{ .op = .put, .key = "kiwi", .value = "green" },
        .{ .op = .put, .key = "cherry", .value = "dark red" },
        .{ .op = .put, .key = "fig", .value = "purple" },
        .{ .op = .delete, .key = "kiwi" },
        .{ .op = .delete, .key = "apple" },
        .{ .op = .put, .key = "banana", .value = "yellow" },
        .{ .op = .put, .key = "pea", .value = "g" },
        .{ .op = .delete, .key = "fig" },
        .{ .op = .delete, .key = "mango" },
        .{ .op = .compact },
    };
    for (steps) |step| {
        switch (step.op) {
            .put => {
                try w.print("put {s}={s} ({d}-byte cell)\n", .{ step.key, step.value, sp.cellSize(step.key.len, step.value.len) });
                page.put(step.key, step.value) catch unreachable; // the scenario never fills the page
            },
            .delete => {
                try w.print("delete {s}\n", .{step.key});
                std.debug.assert(page.delete(step.key));
            },
            .compact => {
                try w.writeAll("compact\n");
                page.compact();
            },
        }
        page.validate() catch unreachable;
        try describe(w, page);
    }

    try w.writeAll("header and slot array:\n");
    try dumpRows(w, &buf, 0, 32);
    try w.writeAll("content area:\n");
    try dumpRows(w, &buf, page.stats().content_start & ~@as(usize, 15), sp.page_size);
}

/// Fragmentation under pressure: enough free bytes, but not in one piece.
fn partTwo(w: *Io.Writer) Io.Writer.Error!void {
    var buf: [sp.page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    const filler: [96]u8 = @splat('.');
    var name: [4]u8 = undefined;
    try w.writeAll("\n== Part 2: fragmentation and automatic compaction ==\n");

    var n: usize = 0;
    while (page.fits(4, filler.len)) : (n += 1) {
        page.put(std.fmt.bufPrint(&name, "k{d:0>3}", .{n}) catch unreachable, &filler) catch unreachable;
    }
    try w.print("fill with {d}-byte cells until the next one does not fit\n", .{sp.cellSize(4, filler.len)});
    try describeShort(w, page);

    var i: usize = 0;
    while (i < n) : (i += 2) {
        std.debug.assert(page.delete(std.fmt.bufPrint(&name, "k{d:0>3}", .{i}) catch unreachable));
    }
    try w.writeAll("delete every other cell\n");
    try describeShort(w, page);

    const big: [500]u8 = @splat('B');
    try w.print("put big ({d}-byte cell): no free block and no gap is large enough, so the page compacts first\n", .{sp.cellSize(3, big.len)});
    page.put("big", &big) catch unreachable;
    try describeShort(w, page);

    const huge: [2000]u8 = @splat('H');
    try w.print("put huge ({d}-byte cell): ", .{sp.cellSize(4, huge.len)});
    if (page.put("huge", &huge)) |_| unreachable else |err| try w.print("{t}, page unchanged\n", .{err});
    try describeShort(w, page);
    page.validate() catch unreachable;
}

/// The shared pseudo-random operation stream applied to one page. Zig and
/// Rust must agree on every counter and on a hash of the final page bytes.
fn partThree(w: *Io.Writer) Io.Writer.Error!void {
    var buf: [sp.page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    const config: ops.Config = .{ .seed = 10, .count = 3000, .key_space = 300 };
    try w.writeAll("\n== Part 3: 3000 random operations on one page ==\n");
    try w.print("seed={d} count={d} key_space={d}\n", .{ config.seed, config.count, config.key_space });

    var kb: [workload.max_key_len]u8 = undefined;
    var vb: [workload.max_value_len]u8 = undefined;
    var puts: usize = 0;
    var page_full: usize = 0;
    var deletes: usize = 0;
    var delete_hits: usize = 0;
    var gets: usize = 0;
    var get_hits: usize = 0;
    var ranges: usize = 0;
    var range_cells: usize = 0;
    var max_blocks: usize = 0;
    var max_frag: usize = 0;

    var stream = ops.OpStream.init(config);
    while (stream.next()) |op| {
        switch (op) {
            .put => |p| {
                puts += 1;
                page.put(workload.keyBytes(&kb, p.key), workload.valueBytes(&vb, p.value)) catch {
                    page_full += 1;
                };
            },
            .delete => |d| {
                deletes += 1;
                delete_hits += @intFromBool(page.delete(workload.keyBytes(&kb, d.key)));
            },
            .get => |g| {
                gets += 1;
                get_hits += @intFromBool(page.get(workload.keyBytes(&kb, g.key)) != null);
            },
            .range => |r| {
                ranges += 1;
                const lo = page.search(workload.keyBytes(&kb, r.lo)).index;
                const hi = page.search(workload.keyBytes(&kb, r.hi)).index;
                range_cells += hi - lo;
            },
        }
        const s = page.stats();
        max_blocks = @max(max_blocks, s.free_block_count);
        max_frag = @max(max_frag, s.frag_bytes);
    }
    page.validate() catch unreachable;
    try w.print("put: {d} ({d} refused with PageFull)\n", .{ puts, page_full });
    try w.print("delete: {d} ({d} found)\n", .{ deletes, delete_hits });
    try w.print("get: {d} ({d} found)\n", .{ gets, get_hits });
    try w.print("range: {d} ({d} cells visited)\n", .{ ranges, range_cells });
    try w.print("most free blocks at once: {d}, most fragment bytes at once: {d}\n", .{ max_blocks, max_frag });
    try describeShort(w, page);
    try w.print("fnv1a64 of the page: {x:0>16}\n", .{fnv1a64(&buf)});
}

fn describeShort(w: *Io.Writer, page: SlottedPage) Io.Writer.Error!void {
    const s = page.stats();
    try w.print("  cells={d} content_start={d} gap={d} free_blocks={d} ({d} bytes, largest {d}) frag={d} free={d}\n", .{
        s.cell_count,       s.content_start,      s.gap,        s.free_block_count,
        s.free_block_bytes, s.largest_free_block, s.frag_bytes, s.free_bytes,
    });
}

fn describe(w: *Io.Writer, page: SlottedPage) Io.Writer.Error!void {
    const s = page.stats();
    try w.print("  cells={d} content_start={d} gap={d} free_blocks=[", .{ s.cell_count, s.content_start, s.gap });
    var blocks: [8]sp.FreeBlock = undefined;
    for (page.freeBlocks(&blocks), 0..) |b, i| {
        try w.print("{s}{d}+{d}", .{ if (i == 0) "" else " ", b.offset, b.size });
    }
    try w.print("] frag={d} free={d}\n  slots:", .{ s.frag_bytes, s.free_bytes });
    if (s.cell_count == 0) try w.writeAll(" (none)");
    for (0..s.cell_count) |i| try w.print(" {s}@{d}", .{ page.key(i), page.cellOffset(i) });
    try w.writeAll("\n");
}

/// Hexdump rows with real page offsets (same row format as common/hexdump).
/// `start` must be a multiple of 16.
fn dumpRows(w: *Io.Writer, buf: *const [sp.page_size]u8, start: usize, end: usize) Io.Writer.Error!void {
    var off = start;
    while (off < end) : (off += 16) {
        const row = buf[off..@min(off + 16, end)];
        try w.print("{x:0>8}  ", .{off});
        for (0..16) |i| {
            if (i < row.len) try w.print("{x:0>2} ", .{row[i]}) else try w.writeAll("   ");
            if (i == 7) try w.writeAll(" ");
        }
        try w.writeAll(" |");
        for (row) |b| try w.writeByte(if (b >= 0x20 and b <= 0x7e) b else '.');
        try w.writeAll("|\n");
    }
}

/// FNV-1a, 64 bit: a five-line hash, enough to compare two page images.
fn fnv1a64(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

test "fnv1a64 known values" {
    try std.testing.expectEqual(0xcbf29ce484222325, fnv1a64(""));
    try std.testing.expectEqual(0xaf63dc4c8601ec8c, fnv1a64("a"));
}

test "demo output equals expected_output.txt" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try run(&aw.writer);
    // build.zig exposes ../expected_output.txt under this import name.
    try std.testing.expectEqualStrings(@embedFile("expected_output"), aw.written());
}

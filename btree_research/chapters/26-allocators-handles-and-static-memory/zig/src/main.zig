//! Chapter 26: allocators, handles and static memory.
//!
//! `zig build run` prints the fixed scenario of the chapter (identical to the Rust
//! program and to ../expected_output.txt):
//!   1. a bitmap slab pool with 32-bit handles
//!   2. a B-tree whose nodes live in two such pools (two size classes)
//!   3. holes after deletes, and vacuum
//!   4. static memory: reserve, freeze, run, exhaust
//!   5. a buddy allocator
//! The allocator tour (src/tour.zig) is tests only.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const slab = @import("slab.zig");
const btree = @import("btree.zig");
const buddy = @import("buddy.zig");
const ops = @import("ops.zig");
const StaticAllocator = @import("static_allocator.zig").StaticAllocator;

const Tree = btree.BTree(4, 4);

fn printPools(w: *Io.Writer, tree: anytype) !void {
    try w.writeAll("leaf slabs:     ");
    try tree.leaves.writeMap(w);
    try w.writeAll("\ninterior slabs: ");
    try tree.interiors.writeMap(w);
    try w.writeAll("\n");
}

pub fn demo(w: *Io.Writer, gpa: Allocator) !void {
    // ---- 1 ---------------------------------------------------------------------------
    try w.writeAll("== 1. bitmap slab, 32-bit handles ==\n");
    {
        var pool: slab.SlabPool(u64, 4) = .init(gpa, .{});
        defer pool.deinit();
        var hs: [6]slab.Handle = undefined;
        for (&hs) |*h| h.* = try pool.create();
        try w.writeAll("create x6:      ");
        try pool.writeMap(w);
        try w.print("\nlast handle:    {f} = 0x{x:0>8} ({d} bytes)\n", .{ hs[5], hs[5].toInt(), @sizeOf(slab.Handle) });
        pool.destroy(hs[1]);
        pool.destroy(hs[3]);
        try w.writeAll("destroy 2:      ");
        try pool.writeMap(w);
        const again = try pool.create();
        try w.print("\ncreate:         {f} (lowest hole first)\n", .{again});
        for ([_]slab.Handle{ hs[4], hs[5] }) |h| pool.destroy(h);
        try w.writeAll("empty slab 1:   ");
        try pool.writeMap(w);
        try w.writeAll(" (given back: slab 0 has room)\n");
        for ([_]slab.Handle{ hs[0], again, hs[2] }) |h| pool.destroy(h);
        try w.writeAll("empty slab 0:   ");
        try pool.writeMap(w);
        try w.writeAll(" (kept: the only free space)\n");
    }

    // ---- 2 ---------------------------------------------------------------------------
    try w.writeAll("\n== 2. B-tree on two slab pools (M = 4, 4 slots per slab) ==\n");
    var tree: Tree = .init(gpa, true);
    defer tree.deinit();
    try w.writeAll("put 10 20 5 6 12 30 7 17 3 25 1 15\n");
    for (btree.canonical_keys) |k| try tree.put(k, k * 10);
    try tree.dump(w);
    try printPools(w, &tree);
    try w.print("node sizes:     leaf {d} bytes, interior {d} bytes\n", .{ @sizeOf(Tree.Leaf), @sizeOf(Tree.Interior) });
    try w.print("get 17 = {?d}, get 18 = {?d}\n", .{ tree.get(17), tree.get(18) });
    var found: std.ArrayList(btree.Entry) = .empty;
    defer found.deinit(gpa);
    try tree.range(gpa, 6, 20, &found);
    try w.writeAll("range [6, 20) =");
    for (found.items) |e| try w.print(" {d}", .{e.key});
    try w.writeAll("\n");

    // ---- 3 ---------------------------------------------------------------------------
    try w.writeAll("\n== 3. holes and vacuum ==\n");
    for (31..61) |k| try tree.put(k, k * 10);
    try w.print("put 31..60:     {d} keys, height {d}\n", .{ tree.count, tree.height });
    try printPools(w, &tree);
    for (1..61) |k| {
        if (k % 5 != 0) _ = tree.delete(k);
    }
    try w.print("delete all but multiples of 5: {d} keys, height {d}\n", .{ tree.count, tree.height });
    try printPools(w, &tree);
    var pass: u32 = 1;
    while (true) : (pass += 1) {
        const moved = tree.vacuum();
        if (moved == 0) break;
        try w.print("vacuum pass {d}:  moved {d} node(s)\n", .{ pass, moved });
        try printPools(w, &tree);
    }
    try tree.dump(w);
    try tree.validate();
    try w.writeAll("validate: ok\n");

    // ---- 4 ---------------------------------------------------------------------------
    try w.writeAll("\n== 4. static memory: reserve, freeze, run ==\n");
    {
        // The whole stack in one fixed buffer: buddy allocator -> freeze wrapper ->
        // slab pools -> tree. After `freeze` the process footprint cannot change.
        const Heap = buddy.BuddyAllocator(16, 6);
        const memory = try gpa.alignedAlloc(u8, Heap.heap_align, Heap.heap_size);
        defer gpa.free(memory);
        var heap: Heap = .init(memory);
        var static: StaticAllocator = .init(heap.allocator());
        var fixed: btree.BTree(4, 32) = .init(static.allocator(), false);
        try fixed.leaves.reserve(3);
        try fixed.interiors.reserve(2);
        static.freeze();
        try w.print("reserved:       {d} leaf slabs, {d} interior slabs of 32 slots; frozen\n", .{ fixed.leaves.slab_count, fixed.interiors.slab_count });

        var stream = ops.OpStream.init(.{ .seed = 26, .count = 5000, .key_space = 100 });
        var failed_puts: u32 = 0;
        while (stream.next()) |op| switch (op) {
            .put => |p| fixed.put(p.key, p.value) catch {
                failed_puts += 1;
            },
            .delete => |d| _ = fixed.delete(d.key),
            else => {},
        };
        try fixed.validate();
        try w.print("5000 ops:       {d} keys, {d} leaves + {d} interior nodes live, failed puts {d}\n", .{ fixed.count, fixed.leaves.live, fixed.interiors.live, failed_puts });
        try w.print("slabs now:      {d} leaf, {d} interior (unchanged)\n", .{ fixed.leaves.slab_count, fixed.interiors.slab_count });

        // Ascending inserts until the pool runs dry.
        var key: u64 = 1000;
        while (fixed.put(key, key)) |_| key += 1 else |_| {}
        try fixed.validate();
        try w.print("fill:           put {d} failed with OutOfMemory at {d} keys\n", .{ key, fixed.count });
        try w.print("pool refusals:  {d}; tree still valid, get {d} = {?d}\n", .{ fixed.leaves.grow_failures + fixed.interiors.grow_failures, key, fixed.get(key) });
        try w.print("free slots:     {d} leaf, {d} interior\n", .{ fixed.leaves.freeSlots(), fixed.interiors.freeSlots() });

        std.debug.assert(static.refused >= 1);
        static.thaw();
        fixed.deinit();
        std.debug.assert(heap.largestFree() == Heap.heap_size); // everything came back
    }

    // ---- 5 ---------------------------------------------------------------------------
    try w.writeAll("\n== 5. buddy allocator (1024-byte heap, 64-byte minimum block) ==\n");
    {
        const Heap = buddy.BuddyAllocator(10, 6);
        var memory: [Heap.heap_size]u8 align(Heap.heap_size) = undefined;
        var heap: Heap = .init(&memory);
        const a = heap.allocator();
        const Step = struct { name: []const u8, len: usize };
        var blocks: [3][]u8 = undefined;
        for ([_]Step{ .{ .name = "a", .len = 100 }, .{ .name = "b", .len = 60 }, .{ .name = "c", .len = 200 } }, 0..) |s, i| {
            blocks[i] = try a.alloc(u8, s.len);
            try w.print("alloc {s} = {d:>3}:  ", .{ s.name, s.len });
            try heap.writeMap(w);
            try w.writeAll("\n");
        }
        try w.print("requested {d} bytes, granted {d}: {d} lost to rounding\n", .{ heap.requested, heap.granted, heap.granted - heap.requested });
        try w.print("free {d} bytes, largest block {d}; alloc 600 -> {s}\n", .{
            heap.freeBytes(),
            heap.largestFree(),
            if (a.alloc(u8, 600)) |_| "ok" else |_| "OutOfMemory",
        });
        for ([_][]const u8{ "a", "b", "c" }, blocks) |name, block| {
            a.free(block);
            try w.print("free {s}:         ", .{name});
            try heap.writeMap(w);
            try w.writeAll("\n");
        }
        try heap.validate();
    }
}

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const stdout = &file_writer.interface;
    try demo(stdout, init.gpa);
    try stdout.flush();
}

test "run output matches expected_output.txt" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try demo(&out.writer, std.testing.allocator);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}

test {
    // Reach the tests of every file from the test root.
    _ = slab;
    _ = btree;
    _ = buddy;
    _ = ops;
    _ = @import("static_allocator.zig");
    _ = @import("prng.zig");
    _ = @import("tour.zig");
}

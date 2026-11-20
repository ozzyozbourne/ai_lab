//! Demo program of chapter 19. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Rust program's.
//!
//! Sections 3, 4 and 6 start threads, and still print the same text on every
//! run: sections 3 and 4 because the second thread only runs while the first
//! is frozen by the test hook, section 6 because it prints only facts that
//! do not depend on the interleaving.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const lib = @import("ch19_latching_and_lock_coupling");
const Tree = lib.Tree;
const Protocol = lib.Protocol;
const NodeId = lib.NodeId;
const probe = lib.probe;

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &file_writer.interface;
    // The node tables and the stress workers' logs come from smp_allocator:
    // several threads allocate at once, and it is built for exactly that.
    try run(std.heap.smp_allocator, init.io, w);
    try w.flush();
}

pub fn run(gpa: Allocator, io: Io, w: *Writer) !void {
    try buildDemo(gpa, io, w);
    try modelRun(gpa, io, w);
    try probeDemo(gpa, io, w);
    try rootDemo(gpa, io, w);
    try outOfNodesDemo(gpa, io, w);
    try stressDemo(gpa, io, w);
}

fn canonicalTree(gpa: Allocator, io: Io, protocol: Protocol) !Tree {
    var tree: Tree = try .init(gpa, 4, protocol, 64);
    errdefer tree.deinit(gpa);
    for (lib.canonical) |key| _ = try tree.put(io, key, probe.valueOf(key));
    return tree;
}

fn dumpToString(gpa: Allocator, tree: *const Tree) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try lib.dump.dump(tree, &out.writer);
    return out.toOwnedSlice();
}

fn buildDemo(gpa: Allocator, io: Io, w: *Writer) !void {
    try w.writeAll("== 1. One tree, three protocols: canonical keys, order M = 4 ==\n");
    var reference: ?[]u8 = null;
    defer if (reference) |r| gpa.free(r);
    for (lib.protocols) |protocol| {
        var tree = try canonicalTree(gpa, io, protocol);
        defer tree.deinit(gpa);
        try tree.validate();
        const text = try dumpToString(gpa, &tree);
        if (reference) |r| {
            defer gpa.free(text);
            try w.print("{s}: same tree: {s}\n", .{ lib.protocolName(protocol), if (std.mem.eql(u8, r, text)) "yes" else "NO" });
        } else {
            reference = text;
            try w.print("{s}:\n  {s}", .{ lib.protocolName(protocol), text });
        }
    }
}

/// A seeded single-threaded workload against the reference oracle.
fn modelRun(gpa: Allocator, io: Io, w: *Writer) !void {
    try w.writeAll("\n== 2. Model run: 20000 single-threaded operations (put, get) against the oracle ==\n");
    for (lib.protocols) |protocol| {
        var tree: Tree = try .init(gpa, 4, protocol, 2048);
        defer tree.deinit(gpa);
        var oracle: lib.ops.Oracle = .{};
        defer oracle.deinit(gpa);
        var stream = lib.ops.OpStream.init(.{
            .seed = 19,
            .count = 20_000,
            .key_space = 500,
            .weights = .{ .put = 1, .delete = 0, .get = 1, .range = 0 },
        });
        var mismatches: usize = 0;
        while (stream.next()) |op| switch (op) {
            .put => |p| {
                if (try tree.put(io, p.key, p.value) != try oracle.put(gpa, p.key, p.value)) mismatches += 1;
            },
            .get => |g| {
                if (tree.get(io, g.key) != oracle.get(g.key)) mismatches += 1;
            },
            .delete, .range => unreachable, // weight 0
        };
        try tree.validate();
        try w.print("{s:<14} keys={d} height={d} nodes={d} leaf splits={d} internal splits={d} mismatches={d}\n", .{
            lib.protocolName(protocol),             tree.len(),                                  tree.height(), tree.table.count(),
            tree.stats.leaf_splits.load(.monotonic), tree.stats.internal_splits.load(.monotonic), mismatches,
        });
    }
}

const Scenario = struct {
    /// Extra keys put before the experiment.
    setup: []const u64 = &.{},
    title: []const u8,
    frozen: probe.OpSpec,
    others: []const Other,

    const Other = struct { op: probe.OpSpec, note: []const u8 };
};

const scenarios = [_]Scenario{
    .{
        .title = "A = get 12, frozen at leaf #1 (shared)",
        .frozen = .{ .get = 12 },
        .others = &.{
            .{ .op = .{ .get = 25 }, .note = "other leaf" },
            .{ .op = .{ .get = 10 }, .note = "same leaf" },
            .{ .op = .{ .put = 16 }, .note = "other leaf" },
            .{ .op = .{ .put = 11 }, .note = "same leaf" },
        },
    },
    .{
        .title = "A = put 11, frozen at leaf #1 (exclusive; the leaf has room, ancestors released)",
        .frozen = .{ .put = 11 },
        .others = &.{
            .{ .op = .{ .get = 25 }, .note = "other leaf" },
            .{ .op = .{ .get = 12 }, .note = "same leaf" },
            .{ .op = .{ .put = 16 }, .note = "other leaf" },
        },
    },
    .{
        .setup = &.{ 8, 9 },
        .title = "after put 8, put 9: A = put 2, frozen at leaf #0 (full, under the full node #2: both stay latched)",
        .frozen = .{ .put = 2 },
        .others = &.{
            .{ .op = .{ .get = 25 }, .note = "under #6" },
            .{ .op = .{ .get = 12 }, .note = "under #2" },
            .{ .op = .{ .put = 16 }, .note = "under #6" },
        },
    },
};

fn probeDemo(gpa: Allocator, io: Io, w: *Writer) !void {
    try w.writeAll("\n== 3. While A is frozen holding its locks, does B finish? (canonical tree) ==\n");
    for (scenarios) |s| {
        try w.print("{s}\n", .{s.title});
        try w.print("  {s:<22}", .{"B"});
        for (lib.protocols) |p| try w.print(" {s:<15}", .{lib.protocolName(p)});
        try w.writeByte('\n');
        for (s.others) |other| {
            var label_buf: [32]u8 = undefined;
            const label = try std.fmt.bufPrint(&label_buf, "{t} {d} ({s})", .{ other.op, opKey(other.op), other.note });
            try w.print("  {s:<22}", .{label});
            for (lib.protocols) |protocol| {
                var tree = try canonicalTree(gpa, io, protocol);
                defer tree.deinit(gpa);
                for (s.setup) |key| _ = try tree.put(io, key, probe.valueOf(key));
                const outcome = try probe.probe(&tree, io, s.frozen, .{ .point = .at_leaf }, other.op);
                try tree.validate();
                var cell_buf: [32]u8 = undefined;
                const cell = switch (outcome) {
                    .completed => "finishes",
                    .blocked => |node| if (node == .nil) "waits" else try std.fmt.bufPrint(&cell_buf, "waits at #{d}", .{node.index()}),
                };
                try w.print(" {s:<15}", .{cell});
            }
            try w.writeByte('\n');
        }
    }
}

fn opKey(op: probe.OpSpec) u64 {
    return switch (op) {
        .get => |k| k,
        .put => |k| k,
    };
}

/// The root is replaced between "read the root id" and "latch that node".
fn rootDemo(gpa: Allocator, io: Io, w: *Writer) !void {
    try w.writeAll("\n== 4. Latch coupling: the root is replaced under a reader ==\n");
    var tree: Tree = try .init(gpa, 4, .latch_coupling, 16);
    defer tree.deinit(gpa);
    for ([_]u64{ 10, 20, 5 }) |key| _ = try tree.put(io, key, probe.valueOf(key));
    try w.writeAll("before: ");
    try lib.dump.dump(&tree, w);

    var reader: probe.Actor = .{ .tree = &tree, .io = io, .op = .{ .get = 20 }, .pause = .{ .point = .root_loaded } };
    try reader.spawn();
    reader.waitSettled();
    try w.writeAll("reader of 20 has read root = #0 and holds no latch yet; now put 6 splits the root\n");
    _ = tree.put(io, 6, probe.valueOf(6)) catch |err| {
        reader.release();
        reader.join();
        return err;
    };
    try w.writeAll("after:  ");
    try lib.dump.dump(&tree, w);
    reader.release();
    reader.join();
    try w.print("reader latched #0, saw root = #{d}, restarted {d} time(s): get 20 = {?d}\n", .{
        tree.root.load(.acquire).index(), tree.stats.root_restarts.load(.monotonic), try reader.result,
    });
}

fn outOfNodesDemo(gpa: Allocator, io: Io, w: *Writer) !void {
    try w.writeAll("\n== 5. A full node table: the failing put changes nothing ==\n");
    for (lib.protocols) |protocol| {
        var tree: Tree = try .init(gpa, 4, protocol, 5);
        defer tree.deinit(gpa);
        for (lib.canonical) |key| {
            const before = try dumpToString(gpa, &tree);
            defer gpa.free(before);
            _ = tree.put(io, key, probe.valueOf(key)) catch {
                const after = try dumpToString(gpa, &tree);
                defer gpa.free(after);
                try tree.validate();
                try w.print("{s:<14} capacity 5: put {d} needs 3 nodes, {d} left: OutOfNodes; tree unchanged: {s}; locks left held: {s}\n", .{
                    lib.protocolName(protocol),                  key,
                    tree.table.capacity() - tree.table.count(), if (std.mem.eql(u8, before, after)) "yes" else "NO",
                    if (tree.nothingLocked(io)) "none" else "SOME",
                });
                break;
            };
        }
    }
}

fn stressDemo(gpa: Allocator, io: Io, w: *Writer) !void {
    try w.writeAll("\n== 6. Stress: 4 threads x 5000 operations, then validate and compare with the oracle ==\n");
    for ([_]bool{ false, true }) |overlapping| {
        for (lib.protocols) |protocol| {
            const config: lib.stress.Config = .{
                .threads = 4,
                .ops_per_thread = 5000,
                .seed = if (overlapping) 1902 else 1901,
                .key_space = if (overlapping) 3000 else 750,
                .overlapping = overlapping,
            };
            var tree: Tree = try .init(gpa, 4, protocol, config.nodeCapacity());
            defer tree.deinit(gpa);
            // Thread-safe arena: the four workers grow their logs from it at
            // the same time, and everything is freed at once after the check.
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const r = try lib.stress.run(&tree, io, gpa, arena.allocator(), config);
            try w.print("{s} {s:<14} keys={d} expected={d} first-time puts={d} lost={d} failed={d} mismatches={d} valid={s}\n", .{
                if (overlapping) "overlapping keys" else "disjoint keys   ", lib.protocolName(protocol),
                r.keys,                                                      r.expected_keys,
                r.fresh,                                                     r.lost,
                r.failed,                                                    r.mismatches,
                if (r.valid) "yes" else "NO",
            });
        }
    }
}

test "run prints exactly expected_output.txt" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(std.testing.allocator, std.testing.io, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}

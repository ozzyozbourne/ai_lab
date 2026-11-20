//! Chapter 02 demo program. `zig build run` prints exactly
//! ../expected_output.txt (a test below checks that), and the Rust program
//! in ../rust prints the same bytes.
const std = @import("std");
const Io = std.Io;

const search = @import("search.zig");
const trace = @import("trace.zig");
const node = @import("node.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;

/// The canonical keys of chapters 03 to 08, in sorted order: one node.
const node_keys = [_]u64{ 1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30 };
/// A node with duplicates, to tell lower bound and upper bound apart.
const dup_keys = [_]u64{ 3, 7, 7, 7, 12, 15, 15, 20 };

/// Bytes of scratch memory `run` needs: 4096 keys plus up to 4096 probes.
pub const scratch_bytes = 2 * 4096 * @sizeOf(u64);

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout: *Io.Writer = &stdout_file_writer.interface;

    // All memory the program needs, reserved on the stack. No heap, no
    // syscalls, and nothing to free: the buffer disappears with the frame.
    // The buffer is aligned for u64: a plain [N]u8 may start at an odd
    // address, and the allocator would then spend up to 7 bytes on padding,
    // which this exactly-sized buffer does not have.
    var scratch_buffer: [scratch_bytes]u8 align(@alignOf(u64)) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&scratch_buffer);

    try run(stdout, fba.allocator());
    try stdout.flush();
}

/// Writes the whole demo to `w`. `scratch` is used for the two large arrays
/// of section 7 only; everything else works on constant arrays.
pub fn run(w: *Io.Writer, scratch: std.mem.Allocator) !void {
    try w.writeAll("chapter 02: searching a sorted node\n");

    try w.writeAll("\n[1] one node: the canonical keys of chapters 03-08, sorted\n");
    try w.writeAll("index:");
    for (0..node_keys.len) |i| try w.print(" {d:>3}", .{i});
    try w.writeAll("\nkey:  ");
    for (node_keys) |k| try w.print(" {d:>3}", .{k});
    try w.writeAll("\n");

    try w.writeAll("\n[2] search(key) -> {found, index}: where the key is, or where it would be inserted\n");
    try w.writeAll("key  found  index\n");
    for ([_]u64{ 0, 1, 12, 13, 30, 31 }) |key| {
        const r = search.search(&node_keys, key);
        try w.print("{d:>3}  {s:<5}  {d:>5}\n", .{ key, yesNo(r.found), r.index });
    }

    try w.writeAll("\n[3] trace of lowerBound(13); invariant: keys[0..lo] < 13 <= keys[hi..]\n");
    try writeTrace(w, &node_keys, 13, .lower);
    try w.writeAll("trace of upperBound(12); invariant: keys[0..lo] <= 12 < keys[hi..]\n");
    try writeTrace(w, &node_keys, 12, .upper);

    try w.writeAll("\n[4] duplicates: lower bound, upper bound, count = upper - lower\n");
    try w.writeAll("keys:");
    for (dup_keys) |k| try w.print(" {d}", .{k});
    try w.writeAll("\nkey  lower  upper  count\n");
    for ([_]u64{ 2, 3, 7, 8, 15, 20, 21 }) |key| {
        const span = search.equalRange(&dup_keys, key);
        try w.print("{d:>3}  {d:>5}  {d:>5}  {d:>5}\n", .{ key, span.start, span.end, span.len() });
    }

    try w.writeAll("\n[5] range bounds on the node of [1]: key range -> index range [start, end)\n");
    const B = search.Bound;
    const ranges = [_]struct { text: []const u8, lo: B, hi: B }{
        .{ .text = "[5, 17]", .lo = .{ .included = 5 }, .hi = .{ .included = 17 } },
        .{ .text = "(5, 17]", .lo = .{ .excluded = 5 }, .hi = .{ .included = 17 } },
        .{ .text = "[5, 17)", .lo = .{ .included = 5 }, .hi = .{ .excluded = 17 } },
        .{ .text = "(5, 17)", .lo = .{ .excluded = 5 }, .hi = .{ .excluded = 17 } },
        .{ .text = "[4, 16]", .lo = .{ .included = 4 }, .hi = .{ .included = 16 } },
        .{ .text = "(4, 16)", .lo = .{ .excluded = 4 }, .hi = .{ .excluded = 16 } },
        .{ .text = "[8, 9]", .lo = .{ .included = 8 }, .hi = .{ .included = 9 } },
        .{ .text = "(7, 7)", .lo = .{ .excluded = 7 }, .hi = .{ .excluded = 7 } },
        .{ .text = "(20, +inf)", .lo = .{ .excluded = 20 }, .hi = .unbounded },
        .{ .text = "(-inf, 5)", .lo = .unbounded, .hi = .{ .excluded = 5 } },
    };
    for (ranges) |r| {
        const span = search.rangeSpan(&node_keys, r.lo, r.hi);
        try w.print("{s:<10} -> [{d:>2}, {d:>2})  {d} keys:", .{ r.text, span.start, span.end, span.len() });
        for (node_keys[span.start..span.end]) |k| try w.print(" {d}", .{k});
        try w.writeAll("\n");
    }

    try w.writeAll("\n[6] neighbours (bound minus one; 'none' instead of index -1)\n");
    try w.writeAll("key  last <  last <=\n");
    for ([_]u64{ 0, 1, 12, 13, 31 }) |key| {
        try w.print("{d:>3}", .{key});
        try writeOptionalIndex(w, search.lastLess(&node_keys, key));
        try writeOptionalIndex(w, search.lastLessOrEqual(&node_keys, key));
        try w.writeAll("\n");
    }

    try w.writeAll("\n[7] sorted batch of probes against 4096 sorted keys (seed 2): comparisons\n");
    var rng = SplitMix64.init(2);
    const keys = try search.makeSorted(scratch, &rng, 4096, 16);
    defer scratch.free(keys);
    const top = keys[keys.len - 1] + 1;
    try w.writeAll("probes  binary from 0  gallop from cursor\n");
    for ([_]usize{ 4, 64, 1024, 4096 }) |m| {
        const probes = try scratch.alloc(u64, m);
        defer scratch.free(probes);
        for (probes) |*p| p.* = rng.below(top);
        std.mem.sort(u64, probes, {}, std.sort.asc(u64));

        var binary_total: u64 = 0;
        var gallop_total: u64 = 0;
        // The cursor is where the previous (smaller or equal) probe landed,
        // so the next answer cannot be left of it.
        var cursor: usize = 0;
        for (probes) |p| {
            const b = trace.lowerBoundCounted(keys, p);
            const g = trace.gallopLowerBoundCounted(keys, cursor, p);
            std.debug.assert(b.index == g.index);
            binary_total += b.comparisons;
            gallop_total += g.comparisons;
            cursor = g.index;
        }
        try w.print("{d:>6}  {d:>13}  {d:>18}\n", .{ m, binary_total, gallop_total });
    }

    try w.writeAll("\n[8] a node of capacity 4 driven by search results\n");
    var n: node.Node(4) = .empty;
    for ([_]u64{ 10, 20, 5, 6, 12, 20 }) |key| {
        const r = search.search(n.keySlice(), key);
        try w.print("put {d:>2}: search -> found={s:<3} index={d}; ", .{ key, yesNo(r.found), r.index });
        if (n.put(key, key * 100 + 1)) |old| {
            try w.writeAll(if (old == null) "inserted;    " else "overwritten; ");
        } else |err| switch (err) {
            error.NodeFull => try w.writeAll("NodeFull;    "),
        }
        try writeKeys(w, n.keySlice());
    }
    try w.print("get 6 -> {?d}, get 7 -> {?d}\n", .{ n.get(6), n.get(7) });
    try w.print("delete 6 -> {?d}; ", .{n.delete(6)});
    try writeKeys(w, n.keySlice());
    try w.print("put 12 -> {?d}; ", .{try n.put(12, 1201)});
    try writeKeys(w, n.keySlice());
    try n.validate();
    try w.writeAll("validate: ok\n");
}

fn yesNo(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

fn writeKeys(w: *Io.Writer, keys: []const u64) !void {
    try w.writeAll("keys:");
    for (keys) |k| try w.print(" {d}", .{k});
    try w.writeAll("\n");
}

fn writeOptionalIndex(w: *Io.Writer, index: ?usize) !void {
    if (index) |i| {
        try w.print("  {d:>6}", .{i});
    } else {
        try w.writeAll("    none");
    }
}

fn writeTrace(w: *Io.Writer, keys: []const u64, key: u64, mode: trace.Mode) !void {
    var buffer: [trace.max_steps]trace.Step = undefined;
    const t = trace.traceBound(keys, key, mode, &buffer);
    const op = if (mode == .lower) "< " else "<=";
    try w.writeAll("step  lo  hi  mid  keys[mid]  decision\n");
    for (t.steps, 1..) |s, i| {
        try w.print("{d:>4}  {d:>2}  {d:>2}  {d:>3}  {d:>9}  ", .{ i, s.lo, s.hi, s.mid, s.probe });
        if (s.go_right) {
            try w.print("{d} {s} {d} is true:  lo = mid + 1 = {d}\n", .{ s.probe, op, key, s.mid + 1 });
        } else {
            try w.print("{d} {s} {d} is false: hi = mid = {d}\n", .{ s.probe, op, key, s.mid });
        }
    }
    try w.print("result: {d} after {d} comparisons\n", .{ t.index, t.steps.len });
}

test "run prints exactly expected_output.txt" {
    // build.zig exposes ../expected_output.txt as the import "expected_output"
    // (a module cannot @embedFile a path outside its own directory).
    const expected = @embedFile("expected_output");

    var scratch_buffer: [scratch_bytes]u8 align(@alignOf(u64)) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&scratch_buffer);
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(&out.writer, fba.allocator());
    try std.testing.expectEqualStrings(expected, out.written());
    // run() freed both arrays (in reverse order), so the bump pointer is back
    // at the start: the scratch buffer is reusable.
    try std.testing.expectEqual(0, fba.end_index);
}

test "run fails cleanly when the scratch buffer is too small" {
    var small: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&small);
    var discard_buffer: [4096]u8 = undefined;
    var out: Io.Writer.Discarding = .init(&discard_buffer);
    try std.testing.expectError(error.OutOfMemory, run(&out.writer, fba.allocator()));
}

test {
    // Make `zig build test` reach the tests of every file.
    _ = search;
    _ = trace;
    _ = node;
    _ = @import("prng.zig");
    _ = @import("ops.zig");
}

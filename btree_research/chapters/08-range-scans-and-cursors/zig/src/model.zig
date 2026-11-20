//! Seeded model run: random puts, deletes, gets and range scans against the
//! sorted-array oracle from `common/`, with two long-lived cursors (one of
//! each design) that take a step between the operations. The tree therefore
//! changes under those cursors all the time, and every answer they give is
//! checked against what the oracle says the answer must be.
//!
//! Used by the tests (which demand zero mismatches) and by the demo program
//! (which prints the counts).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ops = @import("ops.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;
const Tree = @import("tree.zig").Tree;
const Entry = @import("base_node.zig").Entry;
const bounds = @import("bounds.zig");
const Bound = bounds.Bound;
const cursor = @import("cursor.zig");
const Seek = cursor.Seek;
const State = cursor.State;
const Stats = cursor.Stats;
const scan = @import("scan.zig");
const LinkCursor = @import("link_cursor.zig").LinkCursor;
const stack_cursor = @import("stack_cursor.zig");
const StackCursor = stack_cursor.StackCursor;

pub const Config = struct { order: usize, seed: u64, count: u64, key_space: u64 };

pub const Report = struct {
    keys: usize = 0,
    height: usize = 0,
    /// Range scans compared with the oracle (each one by both cursors).
    scans: usize = 0,
    /// Steps taken by the two long-lived cursors.
    cursor_steps: usize = 0,
    link: Stats = .{},
    stack: Stats = .{},
    mismatches: usize = 0,
};

const max_key = std.math.maxInt(u64);

pub fn run(gpa: Allocator, config: Config) !Report {
    var tree: Tree = .init(config.order);
    defer tree.deinit(gpa);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var stream = ops.OpStream.init(.{ .seed = config.seed, .count = config.count, .key_space = config.key_space });
    // A second generator for the choices the op stream does not make.
    var rng = SplitMix64.init(config.seed ^ 0xC0FFEE);

    // Memory of the long-lived stack cursor: lives for the whole run.
    var live_arena: std.heap.ArenaAllocator = .init(gpa);
    defer live_arena.deinit();
    // Memory of one range scan: reset after each, so that after the first
    // few scans nothing is requested from `gpa` any more.
    var scan_arena: std.heap.ArenaAllocator = .init(gpa);
    defer scan_arena.deinit();

    var link: LinkCursor = .init(.{});
    var stack: StackCursor = .init(try stack_cursor.StackPosition.init(live_arena.allocator()));
    var expected_state: State = .before_first;
    var report: Report = .{};

    while (stream.next()) |op| {
        switch (op) {
            .put => |p| {
                if (try tree.put(gpa, p.key, p.value) != try oracle.put(gpa, p.key, p.value)) report.mismatches += 1;
            },
            .delete => |d| {
                if (tree.delete(d.key) != oracle.delete(d.key)) report.mismatches += 1;
            },
            .get => |g| {
                if (tree.get(g.key) != oracle.get(g.key)) report.mismatches += 1;
            },
            .range => |r| {
                defer _ = scan_arena.reset(.retain_capacity);
                var lo = randomBound(&rng, r.lo);
                var hi = randomBound(&rng, r.hi);
                if (rng.chance(1, 8)) std.mem.swap(Bound, &lo, &hi); // inverted: must be empty
                const direction: bounds.Direction = if (rng.chance(1, 2)) .forward else .backward;
                report.mismatches += try checkScan(scan_arena.allocator(), &tree, &oracle, lo, hi, direction);
                report.scans += 1;
            },
        }
        // One step of the long-lived cursors, whatever just happened.
        const all = oracle.range(0, max_key);
        const action = rng.below(8);
        var expected: ?ops.Entry = null;
        var got_link: ?Entry = null;
        var got_stack: ?Entry = null;
        switch (action) {
            0 => {
                const target = randomSeek(&rng, config.key_space);
                expected = expectedSeek(all, target);
                expected_state = if (expected) |e| .{ .on = e.key } else switch (target) {
                    .first, .ge, .gt => .after_last,
                    .last, .le, .lt => .before_first,
                };
                got_link = link.seek(&tree, target);
                got_stack = stack.seek(&tree, target);
            },
            1, 2, 3 => {
                expected = switch (expected_state) {
                    .after_last => null,
                    .before_first => expectedSeek(all, .first),
                    .on => |k| expectedSeek(all, .{ .gt = k }),
                };
                if (expected) |e| expected_state = .{ .on = e.key } else expected_state = .after_last;
                got_link = link.next(&tree);
                got_stack = stack.next(&tree);
            },
            4, 5 => {
                expected = switch (expected_state) {
                    .before_first => null,
                    .after_last => expectedSeek(all, .last),
                    .on => |k| expectedSeek(all, .{ .lt = k }),
                };
                if (expected) |e| expected_state = .{ .on = e.key } else expected_state = .before_first;
                got_link = link.prev(&tree);
                got_stack = stack.prev(&tree);
            },
            6 => {
                expected = switch (expected_state) {
                    .before_first, .after_last => null,
                    .on => |k| if (oracle.get(k)) |v| .{ .key = k, .value = v } else null,
                };
                got_link = link.entry(&tree);
                got_stack = stack.entry(&tree);
            },
            else => continue, // 7: no cursor step this time
        }
        report.cursor_steps += 1;
        if (!same(expected, got_link)) report.mismatches += 1;
        if (!same(expected, got_stack)) report.mismatches += 1;
        if (!std.meta.eql(link.state, expected_state) or !std.meta.eql(stack.state, expected_state)) report.mismatches += 1;
    }
    try tree.validate();
    report.keys = tree.len();
    report.height = tree.base.height;
    report.link = link.stats;
    report.stack = stack.stats;
    return report;
}

/// Runs the scan with both cursors and counts differences from the oracle
/// filtered by the definition of a range (`bounds.contains`).
fn checkScan(arena: Allocator, tree: *const Tree, oracle: *const ops.Oracle, lo: Bound, hi: Bound, direction: bounds.Direction) !usize {
    var by_link = scan.Scan(LinkCursor).init(tree, .init(.{}), lo, hi, direction);
    var by_stack = scan.Scan(StackCursor).init(tree, .init(try stack_cursor.StackPosition.init(arena)), lo, hi, direction);
    const from_link = try by_link.collect(arena);
    const from_stack = try by_stack.collect(arena);

    var mismatches: usize = 0;
    var n: usize = 0;
    const all = oracle.range(0, max_key);
    for (0..all.len) |i| {
        const e = if (direction == .forward) all[i] else all[all.len - 1 - i];
        if (!bounds.contains(lo, hi, e.key)) continue;
        if (n >= from_link.len or !same(e, from_link[n])) mismatches += 1;
        if (n >= from_stack.len or !same(e, from_stack[n])) mismatches += 1;
        n += 1;
    }
    if (from_link.len != n) mismatches += 1;
    if (from_stack.len != n) mismatches += 1;
    return mismatches;
}

fn same(expected: ?ops.Entry, got: ?Entry) bool {
    const e = expected orelse return got == null;
    const g = got orelse return false;
    return e.key == g.key and e.value == g.value;
}

fn randomBound(rng: *SplitMix64, key: u64) Bound {
    return switch (rng.below(3)) {
        0 => .unbounded,
        1 => .{ .included = key },
        else => .{ .excluded = key },
    };
}

fn randomSeek(rng: *SplitMix64, key_space: u64) Seek {
    const kind = rng.below(6);
    const key = rng.below(key_space);
    return switch (kind) {
        0 => .first,
        1 => .last,
        2 => .{ .ge = key },
        3 => .{ .gt = key },
        4 => .{ .le = key },
        else => .{ .lt = key },
    };
}

/// What a seek must return, by counting in the sorted array.
fn expectedSeek(all: []const ops.Entry, target: Seek) ?ops.Entry {
    // Number of entries in front of the landing point.
    var before: usize = 0;
    for (all) |e| {
        const in_front = switch (target) {
            .first => false,
            .last => true,
            .ge, .lt => |k| e.key < k,
            .gt, .le => |k| e.key <= k,
        };
        if (in_front) before += 1;
    }
    return switch (target) {
        // Forward seeks: the first entry that is not in front.
        .first, .ge, .gt => if (before < all.len) all[before] else null,
        // Backward seeks: the last entry that is.
        .last, .le, .lt => if (before > 0) all[before - 1] else null,
    };
}

//! Wide nodes: the idea behind the B-tree, without building one yet.
//!
//! Binary search halves the remaining keys with every page it reads. If one
//! page holds M-1 separator keys, reading that page can cut the remaining
//! keys into M parts instead of 2. That is all a B-tree node is: a sorted
//! array of separators, plus one child pointer for each gap between them.
//!
//! This file does NOT build nodes. It searches an ordinary sorted slice the
//! way a balanced, evenly filled tree of order M laid over that slice would,
//! and counts one page read per node it would visit. Chapters 03 to 05 build
//! the real, updatable structure; here we only need the cost of a lookup.
//!
//! "Order M" follows Knuth: a node has at most M children and M-1 keys.
const std = @import("std");
const cost = @import("cost.zig");
const height = @import("height.zig");

pub const Entry = cost.Entry;

/// Look `key` up in `sorted` as a tree of order `m` would. Requires m >= 2.
pub fn getTraced(sorted: []const Entry, m: usize, key: u64, trace: *cost.Trace) ?u64 {
    std.debug.assert(m >= 2);
    // The subtree we are in covers sorted[lo..hi].
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        trace.page_reads += 1; // read the node that is the root of this subtree
        const size = hi - lo;
        const levels = height.minHeight(size, m); // of this subtree; >= 1

        if (levels == 1) {
            // Leaf: all remaining keys (at most m-1) are in this one node.
            // Scan them. (Chapter 02 replaces this scan by a binary search.
            // Either way it is work inside a page that is already in memory.)
            for (sorted[lo..hi]) |entry| {
                trace.comparisons += 1;
                if (entry.key == key) return entry.value;
                if (entry.key > key) return null;
            }
            return null;
        }

        // Interior node. A child is a subtree of levels-1 levels and holds at
        // most m^(levels-1) - 1 keys, so `children` of them (plus the
        // children-1 separators between them) are needed for `size` keys.
        const child_capacity_plus_one = std.math.pow(usize, m, levels - 1);
        const children = (size + child_capacity_plus_one) / child_capacity_plus_one; // ceil((size+1) / cap+1), 2..m
        // The separators cut the other keys into children whose sizes differ
        // by at most one, so every child is at least about half full.
        const below = size - (children - 1);
        const base = below / children;
        const extra = below % children; // the first `extra` children get one more key
        var child_start = lo;
        var child: usize = 0;
        while (true) : (child += 1) {
            const child_len = base + @intFromBool(child < extra);
            const separator = child_start + child_len; // index of the key after this child
            if (child == children - 1) {
                // Larger than every separator: the last child.
                lo = child_start;
                hi = child_start + child_len;
                break;
            }
            trace.comparisons += 1;
            switch (std.math.order(key, sorted[separator].key)) {
                .eq => return sorted[separator].value, // interior nodes hold entries too
                .lt => {
                    lo = child_start;
                    hi = separator;
                    break;
                },
                .gt => child_start = separator + 1,
            }
        }
    }
    return null; // only reached when `sorted` is empty
}

pub fn get(sorted: []const Entry, m: usize, key: u64) ?u64 {
    var trace: cost.Trace = .{};
    return getTraced(sorted, m, key, &trace);
}

// ----------------------------------------------------------------- tests ---

const testing = std.testing;

fn makeSorted(buffer: []Entry) []const Entry {
    for (buffer, 0..) |*e, i| e.* = .{ .key = (i + 1) * 10, .value = i };
    return buffer;
}

test "finds every key and nothing else, for many sizes and orders" {
    var buffer: [300]Entry = undefined;
    for ([_]usize{ 0, 1, 2, 3, 4, 5, 15, 16, 63, 64, 255, 300 }) |n| {
        const sorted = makeSorted(buffer[0..n]);
        for ([_]usize{ 2, 3, 4, 5, 16, 171 }) |m| {
            const levels = height.minHeight(n, m);
            var deepest: u64 = 0;
            for (sorted) |entry| {
                var trace: cost.Trace = .{};
                try testing.expectEqual(entry.value, getTraced(sorted, m, entry.key, &trace));
                deepest = @max(deepest, trace.page_reads);
                // Absent keys just below and just above each present key.
                for ([_]u64{ entry.key - 1, entry.key + 1 }) |absent| {
                    trace = .{};
                    try testing.expectEqual(null, getTraced(sorted, m, absent, &trace));
                    // A miss always ends in a leaf, and for m >= 3 all leaves
                    // are at the same depth: the mark of a B-tree.
                    if (m >= 3) try testing.expectEqual(levels, trace.page_reads);
                }
            }
            // The stand-in is as shallow as a tree of order m can be.
            try testing.expectEqual(levels, deepest);
        }
    }
}

test "the canonical 12 keys with M = 4 need 2 page reads" {
    var buffer: [12]Entry = undefined;
    const keys = [_]u64{ 1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30 };
    for (&buffer, keys) |*e, k| e.* = .{ .key = k, .value = k * 10 };
    // Root holds 6, 12, 20; children are [1 3 5] [7 10] [15 17] [25 30].
    var trace: cost.Trace = .{};
    try testing.expectEqual(170, getTraced(&buffer, 4, 17, &trace));
    try testing.expectEqual(2, trace.page_reads);
    trace = .{};
    try testing.expectEqual(120, getTraced(&buffer, 4, 12, &trace));
    try testing.expectEqual(1, trace.page_reads); // found in the root
}

test "a node gets only as many children as it needs" {
    // 5 keys, M = 4: two leaves are enough, so the root holds ONE separator
    // (30) with children [10 20] and [40 50], not three separators.
    var buffer: [5]Entry = undefined;
    const sorted = makeSorted(&buffer);
    var trace: cost.Trace = .{};
    try testing.expectEqual(2, getTraced(sorted, 4, 30, &trace));
    try testing.expectEqual(1, trace.page_reads);
    try testing.expectEqual(1, trace.comparisons);
    trace = .{};
    try testing.expectEqual(4, getTraced(sorted, 4, 50, &trace));
    try testing.expectEqual(2, trace.page_reads);
    try testing.expectEqual(3, trace.comparisons); // 30, then 40 and 50 in the leaf
}

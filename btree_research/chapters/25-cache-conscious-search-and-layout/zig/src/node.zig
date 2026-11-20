//! One B-tree node, two memory layouts.
//!
//! A node is a sorted list of entries `{key, child, flags}`. The obvious
//! representation is an array of structs (AoS). The cache-conscious one is a
//! struct of arrays (SoA): all keys together, all children together. A search
//! only reads keys, so in SoA every line it loads is 100% keys, while in AoS
//! half of every line is child ids the search never looks at.
//!
//! The other side of the trade: once the search has found its entry, AoS has
//! the child on the line it just read, while SoA must read the child column,
//! which is one more line. `get` reports both reads to the tracer, so the
//! counts show the saving and its price.
//!
//! Zig's `std.MultiArrayList(Entry)` IS the SoA transformation: you declare
//! the struct once and the container stores one column per field.
//!
//! Alignment caveat: `MultiArrayList` and `ArrayList` align their buffers to
//! 8 bytes, not to a cache line, and `MultiArrayList` places the child column
//! directly behind the key column in one buffer. The tracer's counts describe
//! a node whose key array and child column each start on a line boundary.
//! A node that starts in the middle of a line can touch one line more.
const std = @import("std");
const Allocator = std.mem.Allocator;
const trace = @import("trace.zig");
const search = @import("search.zig");

/// 16 bytes: four entries per cache line in AoS form.
pub const Entry = struct {
    key: u64,
    child: u32,
    flags: u32 = 0,
};

pub const aos_layout: trace.Layout = .{ .stride = @sizeOf(Entry), .offset = @offsetOf(Entry, "key") };
pub const soa_layout: trace.Layout = .keys;

pub const PutError = error{NodeFull};
pub const ValidateError = error{Corrupt};

/// Struct-of-arrays node with a fixed capacity, like a page: all memory is
/// allocated in `init`, so `put` cannot fail for lack of memory, only for
/// lack of room.
pub const SoaNode = struct {
    list: std.MultiArrayList(Entry) = .empty,
    capacity: usize,

    pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!SoaNode {
        var self: SoaNode = .{ .capacity = capacity };
        try self.list.ensureTotalCapacity(gpa, capacity);
        return self;
    }

    pub fn deinit(self: *SoaNode, gpa: Allocator) void {
        self.list.deinit(gpa);
        self.* = undefined;
    }

    /// The key column: a dense `[]u64`, exactly what search.zig wants.
    pub fn keys(self: *const SoaNode) []const u64 {
        return self.list.items(.key);
    }

    /// Insert in sorted position, or overwrite the child of an existing key.
    pub fn put(self: *SoaNode, key: u64, child: u32) PutError!void {
        const i = search.lowerBoundHalving(.hinted, false, self.keys(), key, trace.NoTrace{});
        if (i < self.list.len and self.keys()[i] == key) {
            self.list.items(.child)[i] = child;
            return;
        }
        if (self.list.len == self.capacity) return error.NodeFull;
        // Shifts each column separately: three small memmoves instead of one.
        self.list.insertAssumeCapacity(i, .{ .key = key, .child = child });
    }

    /// The search part of `get`: reads the key column and nothing else.
    pub fn lowerBound(self: *const SoaNode, key: u64, tracer: anytype) usize {
        return search.lowerBoundHalving(.hinted, false, self.keys(), key, tracer);
    }

    /// The search touches only the key column. Then come two more reads, and
    /// the tracer hears about both: the equality check on key `i` (usually on
    /// a line the search already read) and, for a hit, the child column,
    /// which is a different array and so always a line of its own.
    pub fn get(self: *const SoaNode, key: u64, tracer: anytype) ?u32 {
        const i = self.lowerBound(key, tracer);
        if (i == self.list.len) return null;
        tracer.cmp(i);
        if (self.keys()[i] != key) return null;
        tracer.side(i);
        return self.list.items(.child)[i];
    }

    pub fn validate(self: *const SoaNode) ValidateError!void {
        if (self.list.len > self.capacity) return error.Corrupt;
        const ks = self.keys();
        for (1..@max(ks.len, 1)) |i| if (ks[i - 1] >= ks[i]) return error.Corrupt;
    }
};

/// Array-of-structs node with the same interface, for comparison.
pub const AosNode = struct {
    entries: std.ArrayList(Entry) = .empty,
    capacity: usize,

    pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!AosNode {
        var self: AosNode = .{ .capacity = capacity };
        try self.entries.ensureTotalCapacity(gpa, capacity);
        return self;
    }

    pub fn deinit(self: *AosNode, gpa: Allocator) void {
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    /// The same halving loop as `search.lowerBoundHalving`, but each probe
    /// strides over 16-byte entries: half as many keys per cache line.
    pub fn lowerBound(self: *const AosNode, key: u64, tracer: anytype) usize {
        const entries = self.entries.items;
        if (entries.len == 0) return 0;
        var offset: usize = 0;
        var length: usize = entries.len;
        while (length > 1) {
            const half = length / 2;
            const mid = offset + half;
            tracer.cmp(mid);
            offset = if (entries[mid].key < key) blk: {
                @branchHint(.unpredictable);
                break :blk mid;
            } else offset;
            length -= half;
        }
        tracer.cmp(offset);
        return offset + @intFromBool(entries[offset].key < key);
    }

    pub fn put(self: *AosNode, key: u64, child: u32) PutError!void {
        const i = self.lowerBound(key, trace.NoTrace{});
        if (i < self.entries.items.len and self.entries.items[i].key == key) {
            self.entries.items[i].child = child;
            return;
        }
        if (self.entries.items.len == self.capacity) return error.NodeFull;
        self.entries.insertAssumeCapacity(i, .{ .key = key, .child = child });
    }

    /// Same two extra reads as `SoaNode.get`, but here the second one is
    /// free: the child is in the 16-byte entry whose key the equality check
    /// just read, and (in a line-aligned array) a 16-byte entry never
    /// straddles two lines. So there is no `tracer.side` call.
    pub fn get(self: *const AosNode, key: u64, tracer: anytype) ?u32 {
        const i = self.lowerBound(key, tracer);
        if (i == self.entries.items.len) return null;
        tracer.cmp(i);
        if (self.entries.items[i].key != key) return null;
        return self.entries.items[i].child;
    }

    pub fn validate(self: *const AosNode) ValidateError!void {
        const es = self.entries.items;
        if (es.len > self.capacity) return error.Corrupt;
        for (1..@max(es.len, 1)) |i| if (es[i - 1].key >= es[i].key) return error.Corrupt;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Trace = trace.Trace;
const SplitMix64 = @import("prng.zig").SplitMix64;

test "Entry is 16 bytes and MultiArrayList stores the key column densely" {
    try testing.expectEqual(16, @sizeOf(Entry));
    var node = try SoaNode.init(testing.allocator, 4);
    defer node.deinit(testing.allocator);
    try node.put(30, 3);
    try node.put(10, 1);
    try node.put(20, 2);
    try testing.expectEqualSlices(u64, &.{ 10, 20, 30 }, node.keys());
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, node.list.items(.child));
    // Consecutive keys are 8 bytes apart, not 16.
    try testing.expectEqual(8, @intFromPtr(&node.keys()[1]) - @intFromPtr(&node.keys()[0]));
}

test "model test: SoA and AoS nodes behave like a sorted oracle and compare the same keys" {
    const gpa = testing.allocator;
    const capacity = 255;
    var soa = try SoaNode.init(gpa, capacity);
    defer soa.deinit(gpa);
    var aos = try AosNode.init(gpa, capacity);
    defer aos.deinit(gpa);
    // Oracle: child value per key, 0 = absent (children are stored as >= 1).
    var oracle: [600]u32 = @splat(0);
    var count: usize = 0;
    var rng = SplitMix64.init(2525);
    for (0..4000) |step| {
        const key = rng.below(oracle.len);
        if (rng.chance(1, 3)) {
            const child: u32 = @intCast(step + 1);
            const is_new = oracle[key] == 0;
            if (is_new and count == capacity) {
                try testing.expectError(error.NodeFull, soa.put(key, child));
                try testing.expectError(error.NodeFull, aos.put(key, child));
            } else {
                try soa.put(key, child);
                try aos.put(key, child);
                oracle[key] = child;
                count += @intFromBool(is_new);
            }
        } else {
            var ts: Trace = .init(soa_layout);
            var ta: Trace = .init(aos_layout);
            const want: ?u32 = if (oracle[key] == 0) null else oracle[key];
            try testing.expectEqual(want, soa.get(key, &ts));
            try testing.expectEqual(want, aos.get(key, &ta));
            // Same probes, same comparison count; only the lines differ.
            try testing.expectEqualSlices(u32, ts.probeSlice(), ta.probeSlice());
            try testing.expectEqual(ts.comparisons, ta.comparisons);
            // The search, plus the equality check unless the needle is above
            // every key.
            const searched = search.halvingComparisons(count);
            try testing.expect(ts.comparisons == searched or ts.comparisons == searched + 1);
            try testing.expect(ts.keyLines() <= ta.keyLines());
            // Regression (review round 1, G1): the child column is a read
            // too. SoA pays one side line for every hit, AoS never does.
            try testing.expectEqual(@as(u32, @intFromBool(want != null)), ts.sideLines());
            try testing.expectEqual(0, ta.sideLines());
            try testing.expectEqual(ts.keyLines() + ts.sideLines(), ts.linesRead());
            // The search alone reads only keys, in both layouts.
            var ss: Trace = .init(soa_layout);
            var sa: Trace = .init(aos_layout);
            try testing.expectEqual(soa.lowerBound(key, &ss), aos.lowerBound(key, &sa));
            try testing.expectEqual(searched, ss.comparisons);
            try testing.expectEqual(0, ss.sideLines() + sa.sideLines());
            try testing.expect(ss.linesRead() <= sa.linesRead());
        }
    }
    try testing.expectEqual(capacity, soa.list.len); // the node did fill up
    try soa.validate();
    try aos.validate();
}

fn buildNodes(gpa: Allocator) !void {
    var soa = try SoaNode.init(gpa, 64);
    defer soa.deinit(gpa);
    var aos = try AosNode.init(gpa, 64);
    defer aos.deinit(gpa);
    for (0..64) |i| {
        try soa.put(i, 1);
        try aos.put(i, 1);
    }
}

test "allocation failure in init leaks nothing; put never allocates" {
    try testing.checkAllAllocationFailures(testing.allocator, buildNodes, .{});
}

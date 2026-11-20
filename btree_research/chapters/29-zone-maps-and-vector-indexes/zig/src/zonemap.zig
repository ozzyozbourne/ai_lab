//! Zone map: one (min, max) summary per fixed-size chunk of a column.
//!
//! A B+tree's inner node says "every key in child i lies between separator
//! i-1 and separator i", and the separators are sorted, so one binary search
//! picks one child. A zone map keeps only the first half of that sentence.
//! The chunks are in arrival order, their ranges may overlap, and so every
//! summary has to be tested: the cost is O(chunks), not O(log chunks). What
//! it buys is that nothing has to be kept sorted.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// What a summary can prove about a predicate over a whole chunk.
/// DuckDB calls these FILTER_ALWAYS_TRUE, FILTER_ALWAYS_FALSE and
/// NO_PRUNING_POSSIBLE (duckdb/src/storage/statistics/numeric_stats.cpp:209).
pub const Prune = enum {
    /// Every row matches: count the chunk, do not look at its rows.
    always_true,
    /// No row can match: skip the chunk.
    always_false,
    /// The summary cannot decide: compare every row.
    maybe,
};

pub const Op = enum { eq, ne, lt, le, gt, ge };

pub const Zone = struct {
    min: u64,
    max: u64,
    /// Rows summarised. Never 0: a zone is created by its first row.
    count: u32,
};

/// The three-way test for `value <op> c`. Each arm reads as: "can the
/// predicate be true for some row?" and "is it true for all rows?".
pub fn checkZone(zone: Zone, op: Op, c: u64) Prune {
    const inside = zone.min <= c and c <= zone.max;
    const single = zone.min == c and zone.max == c; // every row equals c
    return switch (op) {
        .eq => if (single) .always_true else if (inside) .maybe else .always_false,
        .ne => if (!inside) .always_true else if (single) .always_false else .maybe,
        // v >= c: all rows match if the smallest does, none if the largest does not.
        .ge => if (zone.min >= c) .always_true else if (zone.max >= c) .maybe else .always_false,
        .gt => if (zone.min > c) .always_true else if (zone.max > c) .maybe else .always_false,
        .le => if (zone.max <= c) .always_true else if (zone.min <= c) .maybe else .always_false,
        .lt => if (zone.max < c) .always_true else if (zone.min < c) .maybe else .always_false,
    };
}

/// Combine the verdicts of two predicates joined by AND.
pub fn andPrune(a: Prune, b: Prune) Prune {
    if (a == .always_false or b == .always_false) return .always_false;
    if (a == .always_true and b == .always_true) return .always_true;
    return .maybe;
}

pub fn compare(v: u64, op: Op, c: u64) bool {
    return switch (op) {
        .eq => v == c,
        .ne => v != c,
        .lt => v < c,
        .le => v <= c,
        .gt => v > c,
        .ge => v >= c,
    };
}

pub const Filter = union(enum) {
    cmp: struct { op: Op, c: u64 },
    /// lo <= v <= hi, both ends inclusive.
    between: struct { lo: u64, hi: u64 },

    pub fn matches(self: Filter, v: u64) bool {
        return switch (self) {
            .cmp => |f| compare(v, f.op, f.c),
            .between => |f| f.lo <= v and v <= f.hi,
        };
    }

    pub fn check(self: Filter, zone: Zone) Prune {
        return switch (self) {
            .cmp => |f| checkZone(zone, f.op, f.c),
            .between => |f| andPrune(checkZone(zone, .ge, f.lo), checkZone(zone, .le, f.hi)),
        };
    }
};

pub const ScanStats = struct {
    chunks_skipped: u32 = 0, // always_false
    chunks_all: u32 = 0, // always_true
    chunks_scanned: u32 = 0, // maybe
    rows_compared: u64 = 0,
    matches: u64 = 0,
};

pub const ZoneMap = struct {
    chunk_size: u32,
    values: std.ArrayList(u64) = .empty,
    /// zones.items[i] summarises values[i * chunk_size ..][0..count].
    zones: std.ArrayList(Zone) = .empty,

    pub fn init(chunk_size: u32) ZoneMap {
        std.debug.assert(chunk_size > 0);
        return .{ .chunk_size = chunk_size };
    }

    pub fn deinit(self: *ZoneMap, gpa: Allocator) void {
        self.values.deinit(gpa);
        self.zones.deinit(gpa);
        self.* = undefined;
    }

    /// Append one row. The only maintenance a zone map ever needs: widen the
    /// last zone, or open a new one. Both lists reserve space before either
    /// changes, so an allocation failure leaves the map exactly as it was.
    pub fn append(self: *ZoneMap, gpa: Allocator, v: u64) Allocator.Error!void {
        try self.values.ensureUnusedCapacity(gpa, 1);
        try self.zones.ensureUnusedCapacity(gpa, 1);
        self.values.appendAssumeCapacity(v);
        if (self.zones.items.len > 0) {
            const last = &self.zones.items[self.zones.items.len - 1];
            if (last.count < self.chunk_size) {
                last.min = @min(last.min, v);
                last.max = @max(last.max, v);
                last.count += 1;
                return;
            }
        }
        self.zones.appendAssumeCapacity(.{ .min = v, .max = v, .count = 1 });
    }

    pub fn appendSlice(self: *ZoneMap, gpa: Allocator, vs: []const u64) Allocator.Error!void {
        for (vs) |v| try self.append(gpa, v);
    }

    fn chunk(self: *const ZoneMap, i: usize) []const u64 {
        const start = i * self.chunk_size;
        return self.values.items[start..][0..self.zones.items[i].count];
    }

    /// Count the rows that match `filter`. Every zone is tested (no order to
    /// exploit), but rows are only touched in the `maybe` chunks.
    pub fn scan(self: *const ZoneMap, filter: Filter) ScanStats {
        var stats: ScanStats = .{};
        for (self.zones.items, 0..) |zone, i| {
            switch (filter.check(zone)) {
                .always_false => stats.chunks_skipped += 1,
                .always_true => {
                    stats.chunks_all += 1;
                    stats.matches += zone.count;
                },
                .maybe => {
                    stats.chunks_scanned += 1;
                    for (self.chunk(i)) |v| {
                        stats.rows_compared += 1;
                        if (filter.matches(v)) stats.matches += 1;
                    }
                },
            }
        }
        return stats;
    }

    /// Invariants: every zone but the last is full, the counts add up to the
    /// row count, and each (min, max) is exactly the chunk's min and max.
    /// (A real engine only needs min <= every row <= max; deletes leave the
    /// bounds wider than necessary, which is still correct.)
    pub fn validate(self: *const ZoneMap) error{Invalid}!void {
        var rows: usize = 0;
        for (self.zones.items, 0..) |zone, i| {
            const is_last = i + 1 == self.zones.items.len;
            if (zone.count == 0 or zone.count > self.chunk_size) return error.Invalid;
            if (!is_last and zone.count != self.chunk_size) return error.Invalid;
            rows += zone.count;
            if (rows > self.values.items.len) return error.Invalid;
            var lo: u64 = std.math.maxInt(u64);
            var hi: u64 = 0;
            for (self.chunk(i)) |v| {
                lo = @min(lo, v);
                hi = @max(hi, v);
            }
            if (zone.min != lo or zone.max != hi) return error.Invalid;
        }
        if (rows != self.values.items.len) return error.Invalid;
    }
};

// ---------------------------------------------------------------------------
const testing = std.testing;
const SplitMix64 = @import("prng.zig").SplitMix64;

test "checkZone: every operator, every position of the constant" {
    const z: Zone = .{ .min = 10, .max = 20, .count = 5 };
    // constant below, at min, inside, at max, above
    const cs = [_]u64{ 5, 10, 15, 20, 25 };
    const want = [_][5]Prune{
        .{ .always_false, .maybe, .maybe, .maybe, .always_false }, // eq
        .{ .always_true, .maybe, .maybe, .maybe, .always_true }, // ne
        .{ .always_false, .always_false, .maybe, .maybe, .always_true }, // lt
        .{ .always_false, .maybe, .maybe, .always_true, .always_true }, // le
        .{ .always_true, .maybe, .maybe, .always_false, .always_false }, // gt
        .{ .always_true, .always_true, .maybe, .maybe, .always_false }, // ge
    };
    for ([_]Op{ .eq, .ne, .lt, .le, .gt, .ge }, want) |op, row| {
        for (cs, row) |c, expected| try testing.expectEqual(expected, checkZone(z, op, c));
    }
    // A chunk holding one distinct value can decide = and != completely.
    const one: Zone = .{ .min = 7, .max = 7, .count = 3 };
    try testing.expectEqual(Prune.always_true, checkZone(one, .eq, 7));
    try testing.expectEqual(Prune.always_false, checkZone(one, .ne, 7));
}

test "between combines two one-sided checks" {
    const z: Zone = .{ .min = 10, .max = 20, .count = 5 };
    const f = struct {
        fn f(lo: u64, hi: u64) Filter {
            return .{ .between = .{ .lo = lo, .hi = hi } };
        }
    }.f;
    try testing.expectEqual(Prune.always_true, f(10, 20).check(z));
    try testing.expectEqual(Prune.always_true, f(0, 99).check(z));
    try testing.expectEqual(Prune.maybe, f(15, 99).check(z));
    try testing.expectEqual(Prune.always_false, f(21, 99).check(z));
    try testing.expectEqual(Prune.always_false, f(0, 9).check(z));
}

test "model test: pruned scan equals brute force, verdicts are sound" {
    const gpa = testing.allocator;
    var rng = SplitMix64.init(29);
    for (0..40) |round| {
        var zm = ZoneMap.init(@intCast(1 + rng.below(40)));
        defer zm.deinit(gpa);
        const n = rng.below(600);
        // Even rounds: nearly sorted (zones are narrow). Odd rounds: random.
        for (0..n) |i| try zm.append(gpa, if (round % 2 == 0) i / 3 + rng.below(8) else rng.below(200));
        try zm.validate();
        for (0..60) |_| {
            const a = rng.below(220);
            const filter: Filter = switch (rng.below(7)) {
                0 => .{ .between = .{ .lo = a, .hi = a + rng.below(50) } },
                else => |k| .{ .cmp = .{ .op = @fromBackingInt(@intCast(k - 1)), .c = a } },
            };
            // Oracle: look at every row.
            var want: u64 = 0;
            for (zm.values.items) |v| want += @intFromBool(filter.matches(v));
            const got = zm.scan(filter);
            try testing.expectEqual(want, got.matches);
            try testing.expectEqual(zm.zones.items.len, got.chunks_skipped + got.chunks_all + got.chunks_scanned);
            // Soundness of each verdict, chunk by chunk.
            for (zm.zones.items, 0..) |zone, i| {
                var hits: u32 = 0;
                for (zm.chunk(i)) |v| hits += @intFromBool(filter.matches(v));
                switch (filter.check(zone)) {
                    .always_true => try testing.expectEqual(zone.count, hits),
                    .always_false => try testing.expectEqual(0, hits),
                    .maybe => {},
                }
            }
        }
    }
}

test "validate catches a stale summary" {
    const gpa = testing.allocator;
    var zm = ZoneMap.init(4);
    defer zm.deinit(gpa);
    try zm.appendSlice(gpa, &.{ 5, 9, 7, 6, 30 });
    try zm.validate();
    zm.values.items[1] = 99; // update in place without widening the zone
    try testing.expectError(error.Invalid, zm.validate());
    // ... and the stale zone now gives a wrong answer: this is why validate exists.
    try testing.expectEqual(0, zm.scan(.{ .cmp = .{ .op = .eq, .c = 99 } }).matches);
}

fn appendMany(gpa: Allocator, n: u64) !void {
    var zm = ZoneMap.init(3);
    defer zm.deinit(gpa);
    for (0..n) |i| {
        zm.append(gpa, i * 7 % 11) catch |err| {
            // The failed append must not have half-happened.
            try testing.expectEqual(i, zm.values.items.len);
            try zm.validate();
            return err;
        };
    }
    try zm.validate();
}

test "append under allocation failure leaves a valid map and leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, appendMany, .{@as(u64, 40)});
}

//! Seeded model test: random rows, three ways to order them, one answer.
//!
//! For every random pair of rows (a, b) the following must agree:
//!   1. row.compareRows(a, b)                      the oracle: values only
//!   2. std.mem.order(u8, key(a), key(b))          byte-comparable keys
//!   3. record.compareRecords(rec(a), rec(b))      comparator over records
//! and both encodings must validate and round trip.
//!
//! The Rust twin (model.rs) draws from SplitMix64 in exactly the same order,
//! so both programs see the same rows and print the same counts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitMix64 = @import("prng.zig").SplitMix64;
const row_mod = @import("row.zig");
const record = @import("record.zig");

const Value = row_mod.Value;
const Column = row_mod.Column;

/// Every option combination appears on some column.
pub const schema = [_]Column{
    .{ .type = .text, .opts = .{ .desc = true, .nulls_first = true } },
    .{ .type = .int },
    .{ .type = .float, .opts = .{ .desc = true } },
    .{ .type = .text, .opts = .{ .nulls_first = true } },
};

/// A tiny alphabet that hits the escape byte, the terminator and 0xff often.
const alphabet = [_]u8{ 0x00, 0x01, 0x02, 'a', 'b', 0xff };
const int_extremes = [_]i64{ std.math.minInt(i64), std.math.maxInt(i64), -1, 0 };
const float_specials = [_]f64{ -std.math.inf(f64), -1.5, -0.0, 0.0, 1.5, std.math.inf(f64), std.math.nan(f64), 1.0e300 };

/// A random row for `schema`. Text values point into `text_bytes`, so a
/// RandomRow must not be copied or moved after `fill`.
pub const RandomRow = struct {
    text_bytes: [2][3]u8 = undefined,
    values: [4]Value = undefined,

    pub fn fill(self: *RandomRow, rng: *SplitMix64) void {
        self.values[0] = genText(rng, &self.text_bytes[0]);
        self.values[1] = genInt(rng);
        self.values[2] = genFloat(rng);
        self.values[3] = genText(rng, &self.text_bytes[1]);
    }
};

fn genText(rng: *SplitMix64, buf: *[3]u8) Value {
    if (rng.chance(1, 6)) return .null;
    const n: usize = @intCast(rng.below(4));
    for (buf[0..n]) |*c| c.* = alphabet[@intCast(rng.below(alphabet.len))];
    return .{ .text = buf[0..n] };
}

fn genInt(rng: *SplitMix64) Value {
    if (rng.chance(1, 6)) return .null;
    return .{ .int = switch (rng.below(4)) {
        0 => @as(i64, @intCast(rng.below(7))) - 3,
        1 => @bitCast(rng.nextU64()),
        2 => int_extremes[@intCast(rng.below(int_extremes.len))],
        else => @as(i64, @intCast(rng.below(1024))) - 512,
    } };
}

fn genFloat(rng: *SplitMix64) Value {
    if (rng.chance(1, 6)) return .null;
    if (rng.chance(1, 2)) return .{ .float = float_specials[@intCast(rng.below(float_specials.len))] };
    // Quarters between -8 and 7.75: exactly representable, many ties.
    const quarters: i64 = @as(i64, @intCast(rng.below(64))) - 32;
    return .{ .float = @as(f64, @floatFromInt(quarters)) / 4.0 };
}

pub const Counts = struct { lt: u64 = 0, eq: u64 = 0, gt: u64 = 0 };

pub const CheckError = error{Mismatch} || Allocator.Error;

/// Checks `pairs` random pairs. `gpa` backs one arena that holds the decoded
/// rows of a pair and is reset (capacity kept) before the next pair.
pub fn checkPairs(gpa: Allocator, seed: u64, pairs: u64) CheckError!Counts {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rng = SplitMix64.init(seed);
    var counts: Counts = .{};
    for (0..pairs) |_| {
        _ = arena_state.reset(.retain_capacity);
        var a: RandomRow = .{};
        var b: RandomRow = .{};
        a.fill(&rng);
        b.fill(&rng);
        // Independent rows almost always differ in column 0. Copying a random
        // prefix of `a` into `b` makes later columns (and equality) matter.
        const shared: usize = @intCast(rng.below(schema.len + 1));
        for (0..shared) |i| b.values[i] = a.values[i];

        const expected = row_mod.compareRows(&a.values, &b.values, &schema);
        switch (expected) {
            .lt => counts.lt += 1,
            .eq => counts.eq += 1,
            .gt => counts.gt += 1,
        }

        var key_bufs: [2][40]u8 = undefined; // worst case here is 34 bytes
        var rec_bufs: [2][40]u8 = undefined;
        var keys: [2][]const u8 = undefined;
        var recs: [2][]const u8 = undefined;
        for ([_]*const RandomRow{ &a, &b }, 0..) |r, i| {
            keys[i] = row_mod.encodeKey(&key_bufs[i], &r.values, &schema) catch return error.Mismatch;
            recs[i] = record.encodeRecord(&rec_bufs[i], &r.values) catch return error.Mismatch;

            row_mod.validateKey(keys[i], &schema) catch return error.Mismatch;
            record.validateRecord(recs[i]) catch return error.Mismatch;
            const from_key = row_mod.decodeKey(arena, keys[i], &schema) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return error.Mismatch,
            };
            const from_rec = record.decodeRecord(arena, recs[i]) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => return error.Mismatch,
            };
            if (row_mod.compareRows(&r.values, from_key, &schema) != .eq) return error.Mismatch;
            if (from_rec.len != schema.len) return error.Mismatch;
            if (row_mod.compareRows(&r.values, from_rec, &schema) != .eq) return error.Mismatch;
        }

        if (std.mem.order(u8, keys[0], keys[1]) != expected) return error.Mismatch;
        const by_comparator = record.compareRecords(recs[0], recs[1], &schema, null) catch return error.Mismatch;
        if (by_comparator != expected) return error.Mismatch;
    }
    return counts;
}

test "model: key bytes, record comparator and oracle agree (several seeds)" {
    var total: Counts = .{};
    for ([_]u64{ 1, 2, 3, 42, 0xdead_beef }) |seed| {
        const c = try checkPairs(std.testing.allocator, seed, 3000);
        total.lt += c.lt;
        total.eq += c.eq;
        total.gt += c.gt;
    }
    // The generator must exercise all three outcomes, or the test proves little.
    try std.testing.expect(total.lt > 1000 and total.gt > 1000 and total.eq > 1000);
}

test "model: generator matches the Rust twin" {
    // Same seed, same draws, same counts as `cargo run` prints.
    const c = try checkPairs(std.testing.allocator, 11, 2000);
    try std.testing.expectEqual(Counts{ .lt = 771, .eq = 434, .gt = 795 }, c);
}

test "model: allocation failure in the decode arena is reported, not leaked" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            _ = try checkPairs(gpa, 7, 20);
        }
    }.run, .{});
}

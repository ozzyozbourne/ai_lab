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
//!
//! Two generators:
//!   checkPairs           one fixed four-column schema and a tiny alphabet; small
//!                        enough to print, used by `zig build run` (section 8)
//!   checkRandomSchemas   tests only: a new random schema for every pair (any
//!                        type with any options), the bytes that collide with
//!                        the key framing under ASC and under DESC, longer
//!                        strings, floats at every edge of the format, and
//!                        every truncation of every key and record
const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitMix64 = @import("prng.zig").SplitMix64;
const row_mod = @import("row.zig");
const record = @import("record.zig");

const Value = row_mod.Value;
const Column = row_mod.Column;

/// Every option combination appears on some column (but not on every type:
/// `checkRandomSchemas` below covers that).
pub const schema = [_]Column{
    .{ .type = .text, .opts = .{ .desc = true, .nulls_first = true } },
    .{ .type = .int },
    .{ .type = .float, .opts = .{ .desc = true } },
    .{ .type = .text, .opts = .{ .nulls_first = true } },
};

/// A tiny alphabet that hits the escape byte, the terminator and 0xff often.
/// (0xfe, which becomes the escape byte once a DESC column is inverted, is in
/// `wide_alphabet`; adding it here would change the printed counts.)
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

// ---- the wide generator (tests only) -----------------------------------------

const wide_max_cols = 5;
const wide_max_text = 24;

/// 00 terminator, 01 escape and value tag, 02 NULLS LAST tag; fd fe ff are the
/// bytes that turn into 02 01 00 when a DESC column is inverted.
const wide_alphabet = [_]u8{ 0x00, 0x01, 0x02, 0xfd, 0xfe, 0xff, 'a' };

const wide_ints = [_]i64{
    std.math.minInt(i64), std.math.minInt(i64) + 1, -0x1_0000_0001, -0x8000_0000, -257, -256, -255,        -129,          -128,                     -1,
    0,                    1,                        127,            128,          255,  256,  0x7fff_ffff, 0x1_0000_0000, std.math.maxInt(i64) - 1, std.math.maxInt(i64),
};

/// Both zeros, smallest and largest subnormals, smallest normal, largest
/// finite, infinities, NaNs of both signs with and without payload,
/// neighbours of 1.0, 2^53.
const wide_float_bits = [_]u64{
    0x0000000000000000, 0x8000000000000000, 0x0000000000000001, 0x8000000000000001,
    0x000fffffffffffff, 0x800fffffffffffff, 0x0010000000000000, 0x8010000000000000,
    0x7fefffffffffffff, 0xffefffffffffffff, 0x7ff0000000000000, 0xfff0000000000000,
    0x7ff0000000000001, 0xfff0000000000001, 0x7ff8000000000000, 0xfff8000000000000,
    0x7fffffffffffffff, 0xffffffffffffffff, 0x3ff0000000000000, 0xbff0000000000000,
    0x3ff0000000000001, 0xbff0000000000001, 0x3fefffffffffffff, 0xbfefffffffffffff,
    0x4340000000000000, 0xc340000000000000, 0x7ff4000000000000, 0xfff000000000beef,
};

fn wideInt(rng: *SplitMix64) i64 {
    switch (rng.below(4)) {
        0 => return wide_ints[@intCast(rng.below(wide_ints.len))],
        1 => return @bitCast(rng.nextU64()),
        2 => return @as(i64, 1) << @intCast(rng.below(63)),
        else => return @as(i64, @intCast(rng.below(7))) - 3,
    }
}

fn wideFloat(rng: *SplitMix64) f64 {
    switch (rng.below(4)) {
        0 => return @bitCast(wide_float_bits[@intCast(rng.below(wide_float_bits.len))]),
        1 => return @bitCast(rng.nextU64()), // any bit pattern
        2 => {
            // Within 2 ulp of a special pattern.
            const special = wide_float_bits[@intCast(rng.below(wide_float_bits.len))];
            return @bitCast(special +% rng.below(5) -% 2);
        },
        else => return @as(f64, @floatFromInt(@as(i64, @intCast(rng.below(9))) - 4)) / 2.0,
    }
}

/// Mostly up to 4 bytes (ties and prefixes are common), one in four up to 24.
fn wideText(rng: *SplitMix64, buf: *[wide_max_text]u8) []const u8 {
    const n: usize = @intCast(if (rng.chance(1, 4)) rng.below(wide_max_text + 1) else rng.below(5));
    for (buf[0..n]) |*c| {
        c.* = if (rng.chance(1, 4)) @truncate(rng.nextU64()) else wide_alphabet[@intCast(rng.below(wide_alphabet.len))];
    }
    return buf[0..n];
}

/// FNV-1a over every key and record produced: equal in Zig and in Rust only
/// if the two implementations write the same bytes for the same rows.
fn fnv1a(hash: *u64, bytes: []const u8) void {
    for (bytes) |b| {
        hash.* ^= b;
        hash.* *%= 0x100000001b3;
    }
}

const WideResult = struct { counts: Counts, hash: u64 };

/// Like `checkPairs`, but with a new random schema for every pair, and with
/// stricter checks: exact lengths, key decode-then-encode is the identity on
/// bytes, records round trip to the bit, and every truncation is an error.
fn checkRandomSchemas(gpa: Allocator, seed: u64, pairs: u64) !WideResult {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rng = SplitMix64.init(seed);
    var counts: Counts = .{};
    var hash: u64 = 0xcbf29ce484222325;
    for (0..pairs) |_| {
        _ = arena_state.reset(.retain_capacity);

        const ncol: usize = @intCast(1 + rng.below(wide_max_cols));
        var schema_buf: [wide_max_cols]Column = undefined;
        for (schema_buf[0..ncol]) |*col| {
            const col_type: row_mod.ColumnType = @fromBackingInt(@intCast(rng.below(3)));
            const desc = rng.chance(1, 2);
            const nulls_first = rng.chance(1, 2);
            col.* = .{ .type = col_type, .opts = .{ .desc = desc, .nulls_first = nulls_first } };
        }
        const sc = schema_buf[0..ncol];

        var text: [2][wide_max_cols][wide_max_text]u8 = undefined;
        var row_bufs: [2][wide_max_cols]Value = undefined;
        for (0..2) |r| for (0..ncol) |c| {
            row_bufs[r][c] = if (rng.chance(1, 7)) .null else switch (sc[c].type) {
                .int => .{ .int = wideInt(&rng) },
                .float => .{ .float = wideFloat(&rng) },
                .text => .{ .text = wideText(&rng, &text[r][c]) },
            };
        };
        const shared: usize = @intCast(rng.below(ncol + 1));
        for (0..shared) |c| row_bufs[1][c] = row_bufs[0][c];
        // Often make one text of `b` a prefix of `a`'s, or that plus one byte.
        const pc: usize = @intCast(rng.below(ncol));
        if (row_bufs[0][pc] == .text and rng.chance(1, 2)) {
            const s = row_bufs[0][pc].text;
            var n: usize = @intCast(rng.below(s.len + 1));
            @memcpy(text[1][pc][0..n], s[0..n]);
            if (n < wide_max_text and rng.chance(1, 2)) {
                text[1][pc][n] = wide_alphabet[@intCast(rng.below(wide_alphabet.len))];
                n += 1;
            }
            row_bufs[1][pc] = .{ .text = text[1][pc][0..n] };
        }
        const rows = [2][]const Value{ row_bufs[0][0..ncol], row_bufs[1][0..ncol] };

        const expected = row_mod.compareRows(rows[0], rows[1], sc);
        switch (expected) {
            .lt => counts.lt += 1,
            .eq => counts.eq += 1,
            .gt => counts.gt += 1,
        }

        var key_bufs: [2][wide_max_cols * (2 * wide_max_text + 2)]u8 = undefined;
        var rec_bufs: [2][wide_max_cols * (wide_max_text + 2) + 1]u8 = undefined;
        var keys: [2][]const u8 = undefined;
        var recs: [2][]const u8 = undefined;
        for (rows, 0..) |row, i| {
            const key = try row_mod.encodeKey(&key_bufs[i], row, sc);
            const rec = try record.encodeRecord(&rec_bufs[i], row);
            keys[i] = key;
            recs[i] = rec;
            fnv1a(&hash, key);
            fnv1a(&hash, rec);
            try std.testing.expectEqual(row_mod.keyLen(row), key.len);
            try std.testing.expectEqual(record.recordLen(row), rec.len);

            // Key: validates, decodes to an equal row, and that row encodes to
            // the very same bytes (one row, one key).
            try row_mod.validateKey(key, sc);
            const from_key = try row_mod.decodeKey(arena, key, sc);
            try std.testing.expectEqual(.eq, row_mod.compareRows(row, from_key, sc));
            var again: [wide_max_cols * (2 * wide_max_text + 2)]u8 = undefined;
            try std.testing.expectEqualSlices(u8, key, try row_mod.encodeKey(&again, from_key, sc));

            // Record: validates and round trips to the bit, -0.0 and NaN
            // payloads included (the key normalises them, the record must not).
            try record.validateRecord(rec);
            const from_rec = try record.decodeRecord(arena, rec);
            try std.testing.expectEqual(ncol, from_rec.len);
            for (row, from_rec) |want, got| switch (want) {
                .null => try std.testing.expect(got == .null),
                .int => |x| try std.testing.expectEqual(x, got.int),
                .float => |x| try std.testing.expectEqual(@as(u64, @bitCast(x)), @as(u64, @bitCast(got.float))),
                .text => |x| try std.testing.expectEqualSlices(u8, x, got.text),
            };

            // These bytes come from disk: cut anywhere, both must be rejected.
            for (0..key.len) |cut| {
                try std.testing.expectError(error.Truncated, row_mod.validateKey(key[0..cut], sc));
                try std.testing.expect(std.meta.isError(row_mod.decodeKey(arena, key[0..cut], sc)));
            }
            for (0..rec.len) |cut| {
                try std.testing.expect(std.meta.isError(record.validateRecord(rec[0..cut])));
                try std.testing.expect(std.meta.isError(record.decodeRecord(arena, rec[0..cut])));
            }
        }

        try std.testing.expectEqual(expected, std.mem.order(u8, keys[0], keys[1]));
        try std.testing.expectEqual(expected, try record.compareRecords(recs[0], recs[1], sc, null));
    }
    return .{ .counts = counts, .hash = hash };
}

test "model: random schemas, framing bytes, long strings, float edges, every truncation" {
    var total: Counts = .{};
    for ([_]u64{ 1, 2, 3 }) |seed| {
        const r = try checkRandomSchemas(std.testing.allocator, seed, 2000);
        total.lt += r.counts.lt;
        total.eq += r.counts.eq;
        total.gt += r.counts.gt;
    }
    try std.testing.expect(total.lt > 1000 and total.gt > 1000 and total.eq > 500);
}

test "model: random schemas produce the same bytes as the Rust twin" {
    // Same seed, same draws; the hash covers every key and record byte.
    const r = try checkRandomSchemas(std.testing.allocator, 11, 2000);
    std.debug.print("WIDE {d} {d} {d} {x:0>16}\n", .{ r.counts.lt, r.counts.eq, r.counts.gt, r.hash });
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

//! Variable-length integers ("varints"): small numbers take few bytes.
//!
//! STANDALONE: depends on `std` only. Chapter 12 may copy this file as
//! `base_varint.zig`. Nothing here allocates.
//!
//! Two formats are implemented:
//!
//!   LEB128 (the guide's own format, little-endian like the rest of our pages)
//!     7 payload bits per byte, least significant group first, high bit set
//!     on every byte except the last. 1 to 10 bytes for a u64.
//!       encodedLen(v) usize
//!       encode(buf, v) error{NoSpaceLeft}!usize      returns bytes written
//!       decode(buf) DecodeError!Decoded              .value and .len (bytes read)
//!       zigzag(i64) u64 / unzigzag(u64) i64          so small negatives stay small
//!
//!   SQLite varint (what Turso reads and writes; shown for comparison)
//!     7 bits per byte, MOST significant group first; a 9th byte, if present,
//!     carries 8 bits. 1 to 9 bytes for a u64.
//!       sqliteLen(v), sqliteEncode(buf, v), sqliteDecode(buf)
//!
//! Neither format is order-preserving: comparing two varints as byte strings
//! does not compare the numbers (see the test at the bottom). Varints belong
//! in record bodies and cell headers; keys that must be compared with memcmp
//! use `keycodec.zig`.
const std = @import("std");

pub const max_len = 10; // ceil(64 / 7)
pub const sqlite_max_len = 9; // 8 * 7 + 8 = 64 bits

pub const DecodeError = error{
    /// The buffer ended in the middle of a varint.
    Truncated,
    /// More than 64 bits of payload.
    Overflow,
    /// A longer encoding than necessary (for example `80 00` for 0).
    NonCanonical,
};

pub const Decoded = struct { value: u64, len: usize };

/// Number of bytes `encode` writes for `value`.
pub fn encodedLen(value: u64) usize {
    var n: usize = 1;
    var v = value >> 7;
    while (v != 0) : (v >>= 7) n += 1;
    return n;
}

/// Writes `value` at the start of `buf`. Writes nothing if it does not fit.
pub fn encode(buf: []u8, value: u64) error{NoSpaceLeft}!usize {
    const n = encodedLen(value);
    if (buf.len < n) return error.NoSpaceLeft;
    var v = value;
    for (buf[0 .. n - 1]) |*b| {
        b.* = @as(u8, @truncate(v)) | 0x80; // low 7 bits + "more follows"
        v >>= 7;
    }
    buf[n - 1] = @intCast(v); // last group: high bit clear
    return n;
}

/// Reads one varint from the start of `buf`.
///
/// Invariant kept by rejecting `NonCanonical`: every number has exactly one
/// encoding, so two LEB128 fields hold the same number if and only if they
/// hold the same bytes, and `decode` followed by `encode` gives the input
/// back. Without it `80 00` and `00` would both mean 0. (This is a property
/// of one varint, not of whatever is built from several of them.)
pub fn decode(buf: []const u8) DecodeError!Decoded {
    var value: u64 = 0;
    for (0..max_len) |i| {
        if (i == buf.len) return error.Truncated;
        const b = buf[i];
        const group: u64 = b & 0x7f;
        // The 10th byte holds bit 63 only: anything larger does not fit a u64.
        if (i == max_len - 1 and group > 1) return error.Overflow;
        value |= group << @intCast(7 * i);
        if (b & 0x80 == 0) {
            if (i > 0 and b == 0) return error.NonCanonical;
            return .{ .value = value, .len = i + 1 };
        }
    }
    return error.Overflow; // ten bytes, all with the continuation bit
}

/// Zigzag maps signed to unsigned so that numbers near zero stay short:
/// 0, -1, 1, -2, 2, ... become 0, 1, 2, 3, 4, ...
/// Without it -1 would be `ff ff ff ff ff ff ff ff ff 01` (ten bytes).
pub fn zigzag(v: i64) u64 {
    return @bitCast((v << 1) ^ (v >> 63)); // `>>` on i64 is arithmetic: 0 or all ones
}

pub fn unzigzag(u: u64) i64 {
    const half: i64 = @bitCast(u >> 1);
    return half ^ -@as(i64, @intCast(u & 1));
}

// ---- SQLite / Turso format -------------------------------------------------

pub fn sqliteLen(value: u64) usize {
    if (value >> 56 != 0) return 9; // needs the 8-bit ninth byte
    var n: usize = 1;
    var v = value >> 7;
    while (v != 0) : (v >>= 7) n += 1;
    return n;
}

pub fn sqliteEncode(buf: []u8, value: u64) error{NoSpaceLeft}!usize {
    const n = sqliteLen(value);
    if (buf.len < n) return error.NoSpaceLeft;
    var v = value;
    if (n == 9) {
        buf[8] = @truncate(v); // the last byte is a full byte
        v >>= 8;
    } else {
        buf[n - 1] = @as(u8, @truncate(v)) & 0x7f; // last group: high bit clear
        v >>= 7;
    }
    // Fill the remaining bytes from the back: big-endian groups.
    var i: usize = @min(n - 1, 8);
    while (i > 0) {
        i -= 1;
        buf[i] = @as(u8, @truncate(v)) | 0x80;
        v >>= 7;
    }
    return n;
}

/// Reads one SQLite varint from the start of `buf`.
///
/// Unlike `decode` this is NOT canonical below nine bytes: like SQLite and
/// Turso it accepts padded forms such as `80 05` for 5. Only the nine-byte
/// form is checked.
pub fn sqliteDecode(buf: []const u8) DecodeError!Decoded {
    var value: u64 = 0;
    for (0..8) |i| {
        if (i == buf.len) return error.Truncated;
        value = (value << 7) | (buf[i] & 0x7f);
        if (buf[i] & 0x80 == 0) return .{ .value = value, .len = i + 1 };
    }
    if (buf.len < 9) return error.Truncated;
    // Same rule as Turso: a 9-byte varint whose value would have fitted in 8
    // bytes (top 8 of the 56 bits read so far are zero) is treated as corrupt.
    if (value >> 48 == 0) return error.NonCanonical;
    return .{ .value = (value << 8) | buf[8], .len = 9 };
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// Boundary values: every power of two, its neighbours, and the extremes.
fn edgeValues(out: *[194]u64) void {
    var n: usize = 0;
    for (0..64) |bit| {
        const p = @as(u64, 1) << @intCast(bit);
        for ([_]u64{ p -% 1, p, p +% 1 }) |v| {
            out[n] = v;
            n += 1;
        }
    }
    out[n] = 0;
    out[n + 1] = std.math.maxInt(u64);
}

test "leb128 known encodings" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{0x00}, buf[0..try encode(&buf, 0)]);
    try testing.expectEqualSlices(u8, &.{0x7f}, buf[0..try encode(&buf, 127)]);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, buf[0..try encode(&buf, 128)]);
    try testing.expectEqualSlices(u8, &.{ 0xac, 0x02 }, buf[0..try encode(&buf, 300)]);
    try testing.expectEqual(10, try encode(&buf, std.math.maxInt(u64)));
    try testing.expectEqual(0x01, buf[9]);
}

test "leb128 round trip and length on boundary values" {
    var values: [194]u64 = undefined;
    edgeValues(&values);
    var buf: [max_len]u8 = undefined;
    for (values) |v| {
        const n = try encode(&buf, v);
        try testing.expectEqual(encodedLen(v), n);
        const d = try decode(buf[0..n]);
        try testing.expectEqual(v, d.value);
        try testing.expectEqual(n, d.len);
        // One byte short is always Truncated, on both sides.
        try testing.expectError(error.Truncated, decode(buf[0 .. n - 1]));
        try testing.expectError(error.NoSpaceLeft, encode(buf[0 .. n - 1], v));
    }
}

test "leb128 rejects overflow and non-canonical input" {
    try testing.expectError(error.NonCanonical, decode(&.{ 0x80, 0x00 }));
    try testing.expectError(error.NonCanonical, decode(&.{ 0xff, 0x80, 0x00 }));
    const nine_ff: [9]u8 = @splat(0xff);
    try testing.expectError(error.Overflow, decode(&(nine_ff ++ [_]u8{0x02})));
    try testing.expectError(error.Overflow, decode(&(nine_ff ++ [_]u8{0x81})));
    try testing.expectError(error.Truncated, decode(&.{}));
}

test "zigzag keeps small magnitudes small and round trips" {
    try testing.expectEqual(0, zigzag(0));
    try testing.expectEqual(1, zigzag(-1));
    try testing.expectEqual(2, zigzag(1));
    try testing.expectEqual(3, zigzag(-2));
    try testing.expectEqual(std.math.maxInt(u64), zigzag(std.math.minInt(i64)));
    for ([_]i64{ 0, 1, -1, 63, -64, 64, std.math.maxInt(i64), std.math.minInt(i64) }) |v| {
        try testing.expectEqual(v, unzigzag(zigzag(v)));
    }
    try testing.expectEqual(1, encodedLen(zigzag(-64)));
    try testing.expectEqual(2, encodedLen(zigzag(64)));
}

test "sqlite varint known encodings, round trip, corrupt 9-byte form" {
    var buf: [sqlite_max_len]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{0x7f}, buf[0..try sqliteEncode(&buf, 127)]);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x00 }, buf[0..try sqliteEncode(&buf, 128)]);
    try testing.expectEqualSlices(u8, &.{ 0x82, 0x2c }, buf[0..try sqliteEncode(&buf, 300)]);
    const all_ff: [9]u8 = @splat(0xff);
    try testing.expectEqualSlices(u8, &all_ff, buf[0..try sqliteEncode(&buf, std.math.maxInt(u64))]);

    var values: [194]u64 = undefined;
    edgeValues(&values);
    for (values) |v| {
        const n = try sqliteEncode(&buf, v);
        try testing.expectEqual(sqliteLen(v), n);
        const d = try sqliteDecode(buf[0..n]);
        try testing.expectEqual(v, d.value);
        try testing.expectEqual(n, d.len);
        try testing.expectError(error.Truncated, sqliteDecode(buf[0 .. n - 1]));
    }
    const eight_80: [8]u8 = @splat(0x80);
    const small_in_nine = eight_80 ++ [_]u8{0x05};
    try testing.expectError(error.NonCanonical, sqliteDecode(&small_in_nine));
}

test "varints are NOT order-preserving" {
    var a: [max_len]u8 = undefined;
    var b: [max_len]u8 = undefined;
    // 129 < 256, but 81 01 > 80 02 as byte strings.
    const ea = a[0..try encode(&a, 129)];
    const eb = b[0..try encode(&b, 256)];
    try testing.expectEqual(.gt, std.mem.order(u8, ea, eb));
    // SQLite's big-endian groups do not rescue it: 16383 = ff 7f, 16384 = 81 80 00.
    const sa = a[0..try sqliteEncode(&a, 16383)];
    const sb = b[0..try sqliteEncode(&b, 16384)];
    try testing.expectEqual(.gt, std.mem.order(u8, sa, sb));
}

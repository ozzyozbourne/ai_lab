//! Byte-comparable keys and the two small types every index in this chapter
//! shares.
//!
//! A radix tree never compares whole keys. It walks the key one byte at a time,
//! so "smaller key" has to mean "smaller byte string" (memcmp order). Chapter 11
//! is the full story of order-preserving encodings; this file has only the two
//! encoders the chapter needs, both modelled on DuckDB's ART keys.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// One key/value pair handed back by a scan. `key` is borrowed from the index.
pub const Entry = struct { key: []const u8, value: u64 };

/// Result of a point lookup plus what it cost. `steps` means something
/// different per index (comparisons, nodes visited, slots probed); the unit is
/// documented at each `lookup`.
pub const Lookup = struct { value: ?u64, steps: u32 };

/// Big-endian fixed width: the most significant byte comes first, so byte
/// order equals numeric order. All keys have the same length, so no key can be
/// a prefix of another.
pub fn encodeU64(v: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, v, .big);
    return out;
}

pub fn decodeU64(bytes: []const u8) u64 {
    std.debug.assert(bytes.len == 8);
    return std.mem.readInt(u64, bytes[0..8], .big);
}

/// Strings: escape 0x00 and 0x01 with a leading 0x01, then append a 0x00
/// terminator (the scheme of duckdb/src/execution/index/art/art_key.cpp:20-49).
///
/// Invariant this buys: no encoded key is a strict prefix of another encoded
/// key. "ab" and "abc" become "ab\x00" and "abc\x00", which differ at byte 2.
/// The ART below stores values only at the end of a path, so it needs this.
/// Order is preserved: the terminator 0x00 sorts before every escaped byte.
/// Caller frees the result.
pub fn encodeStr(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var extra: usize = 1; // terminator
    for (s) |c| {
        if (c <= 1) extra += 1;
    }
    const out = try gpa.alloc(u8, s.len + extra);
    var i: usize = 0;
    for (s) |c| {
        if (c <= 1) {
            out[i] = 1;
            i += 1;
        }
        out[i] = c;
        i += 1;
    }
    out[i] = 0;
    return out;
}

/// Print bytes the way the chapter's dumps show them: printable ASCII as is,
/// everything else (and the quote characters) as \xNN.
pub fn writeBytes(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    for (bytes) |c| {
        if (c >= 0x20 and c <= 0x7e and c != '"' and c != '\'' and c != '\\') {
            try w.writeByte(c);
        } else {
            try w.print("\\x{x:0>2}", .{c});
        }
    }
}

/// FNV-1a, 64 bit. Chosen because it is five lines and gives the same numbers
/// in Zig and Rust; a real hash index would use something stronger.
pub fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return h;
}

const testing = std.testing;

test "encodeU64: byte order equals numeric order" {
    const values = [_]u64{ 0, 1, 255, 256, 65535, 65536, 1 << 40, std.math.maxInt(u64) };
    for (values[0 .. values.len - 1], values[1..]) |a, b| {
        const ea = encodeU64(a);
        const eb = encodeU64(b);
        try testing.expect(std.mem.lessThan(u8, &ea, &eb));
        try testing.expectEqual(a, decodeU64(&ea));
    }
}

test "encodeStr: order preserved and no key is a prefix of another" {
    const gpa = testing.allocator;
    // Already in the order we expect the encodings to have.
    const inputs = [_][]const u8{ "", "\x00", "\x00a", "\x01", "a", "a\x00", "a\x01", "ab", "abc", "b" };
    var encoded: [inputs.len][]u8 = undefined;
    for (inputs, 0..) |s, i| encoded[i] = try encodeStr(gpa, s);
    defer for (encoded) |e| gpa.free(e);

    for (0..inputs.len) |i| {
        for (0..inputs.len) |j| {
            if (i == j) continue;
            try testing.expectEqual(i < j, std.mem.lessThan(u8, encoded[i], encoded[j]));
            try testing.expect(!std.mem.startsWith(u8, encoded[i], encoded[j]));
        }
    }
    try testing.expectEqualSlices(u8, &.{ 'a', 1, 0, 0 }, encoded[5]);
}

test "encodeStr reports allocation failure" {
    try testing.expectError(error.OutOfMemory, encodeStr(testing.failing_allocator, "abc"));
}

test "writeBytes escapes non-printable bytes" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeBytes(&w, "ab\x00\xff'");
    try testing.expectEqualStrings("ab\\x00\\xff\\x27", w.buffered());
}

test "fnv1a reference values" {
    try testing.expectEqual(@as(u64, 0xcbf29ce484222325), fnv1a(""));
    try testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), fnv1a("a"));
}

//! Order-preserving ("byte-comparable", "memcmp-able") key encoding.
//!
//! STANDALONE: depends on `std` only. Chapter 12 may copy this file as
//! `base_keycodec.zig`. Nothing here allocates: the caller owns every buffer.
//!
//! THE property (tested at the bottom of this file against an oracle that
//! never looks at bytes: random schemas, every byte value, every truncation):
//! for two keys built with the same sequence of `put*` calls and the same
//! `ColumnOpts` per column,
//!
//!     std.mem.order(u8, key_a, key_b) == logical order of the column values
//!
//! so a B-tree that only knows how to compare byte strings sorts them right.
//!
//! Layout of one column inside a key:
//!
//!     tag (1 byte)   0x00 NULL when NULLS FIRST
//!                    0x01 a value follows
//!                    0x02 NULL when NULLS LAST (the default here, for ASC and
//!                         for DESC; Postgres defaults to NULLS LAST for ASC
//!                         but to NULLS FIRST for DESC, so a caller that
//!                         mirrors Postgres must set `nulls_first` on a
//!                         bare DESC column itself)
//!     payload        u64   8 bytes big-endian
//!                    i64   8 bytes big-endian with the sign bit flipped
//!                    f64   8 bytes, see `encodeF64`
//!                    bytes escaped and terminated, see `encodeBytes`
//!     DESC columns   every payload byte is inverted (b ^ 0xff); the tag is not,
//!                    so NULL placement is independent of ASC / DESC
//!
//! A composite key is the concatenation of its columns. Keys are NOT
//! self-describing: the reader must know the column types and options.
//!
//! API
//!   primitives     encodeU64/decodeU64, encodeI64/decodeI64, encodeF64/decodeF64
//!                  encodedBytesLen, encodeBytes, decodeBytes, invert
//!   KeyWriter      init(buf), putNull, putU64, putI64, putF64, putBytes, written()
//!                  every put is all-or-nothing: on error.NoSpaceLeft nothing was written
//!   KeyReader      init(bytes), takeU64, takeI64, takeF64 (null = SQL NULL),
//!                  bytesLen (peek), takeBytes(out), skipBytes, done()
const std = @import("std");

pub const ColumnOpts = struct {
    /// Descending order for this column.
    desc: bool = false,
    /// NULLs sort before all values (default: after all values, whatever
    /// `desc` is; see the note on Postgres in the file header).
    nulls_first: bool = false,
};

pub const tag_null_first: u8 = 0x00;
pub const tag_value: u8 = 0x01;
pub const tag_null_last: u8 = 0x02;

pub const EncodeError = error{NoSpaceLeft};
pub const DecodeError = error{
    /// The key ended in the middle of a column.
    Truncated,
    /// A tag byte that this column (with these options) can never have.
    BadTag,
    /// An escape byte followed by something that is never escaped.
    BadEscape,
};

// ---- fixed-width primitives (ascending, no tag) ---------------------------

/// Big-endian: the most significant byte comes first, so the first byte that
/// differs between two keys is the most significant difference between the
/// numbers. Little-endian would compare the LEAST significant byte first.
pub fn encodeU64(v: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, v, .big);
    return out;
}

pub fn decodeU64(b: [8]u8) u64 {
    return std.mem.readInt(u64, &b, .big);
}

const sign_bit: u64 = 1 << 63;

/// Two's complement puts negative numbers (sign bit 1) after positive ones in
/// unsigned order. Flipping the sign bit moves the negative half below the
/// positive half and keeps the order inside each half:
///   i64 min -> 00 00.., -1 -> 7f ff.., 0 -> 80 00.., i64 max -> ff ff..
pub fn encodeI64(v: i64) [8]u8 {
    return encodeU64(@as(u64, @bitCast(v)) ^ sign_bit);
}

pub fn decodeI64(b: [8]u8) i64 {
    return @bitCast(decodeU64(b) ^ sign_bit);
}

/// The one NaN bit pattern this encoder produces (a positive quiet NaN).
pub const canonical_nan: u64 = 0x7ff8_0000_0000_0000;

/// IEEE 754 doubles are sign-magnitude: for non-negative numbers the bit
/// pattern already sorts like the value, for negative numbers a larger
/// pattern means a smaller value. So:
///   non-negative: set the sign bit (moves them above all negatives)
///   negative:     invert every bit (reverses their order, clears the top bit)
/// Two normalisations keep "equal values have equal keys":
///   -0.0 is stored as +0.0 (they compare equal), and
///   every NaN is stored as `canonical_nan`, which sorts after +infinity.
/// Resulting order: -inf < negatives < 0 < positives < +inf < NaN.
pub fn encodeF64(v: f64) [8]u8 {
    var bits: u64 = @bitCast(v);
    if (v == 0) bits = 0;
    if (v != v) bits = canonical_nan;
    return encodeU64(if (bits & sign_bit == 0) bits | sign_bit else ~bits);
}

pub fn decodeF64(b: [8]u8) f64 {
    const e = decodeU64(b);
    return @bitCast(if (e & sign_bit != 0) e ^ sign_bit else ~e);
}

/// Inverts every byte in place: turns an ascending encoding into a
/// descending one (a < b as bytes  <=>  ~a > ~b as bytes, for equal lengths
/// or when neither is a prefix of the other, which the terminator ensures).
pub fn invert(bytes: []u8) void {
    for (bytes) |*b| b.* = ~b.*;
}

// ---- variable-length byte strings -----------------------------------------

/// Escape scheme (the one DuckDB's ART keys use):
///   0x00 and 0x01 in the data are written as 0x01 followed by the byte,
///   and the string ends with a single 0x00 terminator.
/// Why a terminator: in a composite key the next column follows immediately,
/// so ("a", "b") and ("ab", "") would otherwise both be `61 62`. Why it must
/// be the smallest byte: a string must sort before every string it is a
/// prefix of, whatever column follows. Why escaping: the data may contain
/// 0x00 itself, and `00` -> `01 00`, `01` -> `01 01`, `02` -> `02` keeps order.
pub const terminator: u8 = 0x00;
pub const escape: u8 = 0x01;

pub fn encodedBytesLen(s: []const u8) usize {
    var n = s.len + 1;
    for (s) |c| n += @intFromBool(c <= escape);
    return n;
}

/// Writes the escaped, terminated form of `s`. Writes nothing if it does not fit.
pub fn encodeBytes(out: []u8, s: []const u8) EncodeError!usize {
    const n = encodedBytesLen(s);
    if (out.len < n) return error.NoSpaceLeft;
    var pos: usize = 0;
    for (s) |c| {
        if (c <= escape) {
            out[pos] = escape;
            pos += 1;
        }
        out[pos] = c;
        pos += 1;
    }
    out[pos] = terminator;
    return n;
}

pub const DecodedBytes = struct {
    /// Encoded bytes read, including the terminator.
    consumed: usize,
    /// Length of the original string.
    len: usize,
};

/// Undoes `encodeBytes` from the start of `enc`. `mask` is 0x00 for an
/// ascending column and 0xff for a descending one (bytes are un-inverted on
/// the fly). With `out == null` nothing is stored: use that to measure.
pub fn decodeBytes(out: ?[]u8, enc: []const u8, mask: u8) (DecodeError || EncodeError)!DecodedBytes {
    var pos: usize = 0;
    var len: usize = 0;
    while (true) {
        if (pos == enc.len) return error.Truncated;
        var c = enc[pos] ^ mask;
        pos += 1;
        if (c == terminator) return .{ .consumed = pos, .len = len };
        if (c == escape) {
            if (pos == enc.len) return error.Truncated;
            c = enc[pos] ^ mask;
            pos += 1;
            if (c > escape) return error.BadEscape;
        }
        if (out) |o| {
            if (len == o.len) return error.NoSpaceLeft;
            o[len] = c;
        }
        len += 1;
    }
}

// ---- KeyWriter: build a (composite) key in a caller buffer ----------------

pub const KeyWriter = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) KeyWriter {
        return .{ .buf = buf };
    }

    /// The key built so far. Borrowed from the caller's buffer.
    pub fn written(self: *const KeyWriter) []const u8 {
        return self.buf[0..self.len];
    }

    /// Claims `n` bytes or fails without changing anything.
    fn reserve(self: *KeyWriter, n: usize) EncodeError![]u8 {
        if (self.buf.len - self.len < n) return error.NoSpaceLeft;
        const out = self.buf[self.len..][0..n];
        self.len += n;
        return out;
    }

    pub fn putNull(self: *KeyWriter, opts: ColumnOpts) EncodeError!void {
        const out = try self.reserve(1);
        out[0] = if (opts.nulls_first) tag_null_first else tag_null_last;
    }

    fn putFixed(self: *KeyWriter, payload: [8]u8, opts: ColumnOpts) EncodeError!void {
        const out = try self.reserve(9);
        out[0] = tag_value;
        out[1..9].* = payload;
        if (opts.desc) invert(out[1..9]);
    }

    pub fn putU64(self: *KeyWriter, v: u64, opts: ColumnOpts) EncodeError!void {
        return self.putFixed(encodeU64(v), opts);
    }

    pub fn putI64(self: *KeyWriter, v: i64, opts: ColumnOpts) EncodeError!void {
        return self.putFixed(encodeI64(v), opts);
    }

    pub fn putF64(self: *KeyWriter, v: f64, opts: ColumnOpts) EncodeError!void {
        return self.putFixed(encodeF64(v), opts);
    }

    pub fn putBytes(self: *KeyWriter, s: []const u8, opts: ColumnOpts) EncodeError!void {
        const out = try self.reserve(1 + encodedBytesLen(s));
        out[0] = tag_value;
        _ = encodeBytes(out[1..], s) catch unreachable; // reserved exactly enough
        // Inverted, the terminator is 0xff: a DESC string sorts AFTER the
        // strings it is a prefix of, which is what descending means.
        if (opts.desc) invert(out[1..]);
    }
};

// ---- KeyReader: take the columns back out, in the same order --------------

pub const KeyReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) KeyReader {
        return .{ .bytes = bytes };
    }

    /// True when every byte has been consumed. A well-formed key ends exactly
    /// after its last column.
    pub fn done(self: *const KeyReader) bool {
        return self.pos == self.bytes.len;
    }

    /// Looks at the tag at `pos`: true = a value follows, false = NULL.
    fn peekTag(self: *const KeyReader, opts: ColumnOpts) DecodeError!bool {
        if (self.pos == self.bytes.len) return error.Truncated;
        const tag = self.bytes[self.pos];
        if (tag == tag_value) return true;
        const null_tag = if (opts.nulls_first) tag_null_first else tag_null_last;
        return if (tag == null_tag) false else error.BadTag;
    }

    fn takeFixed(self: *KeyReader, opts: ColumnOpts) DecodeError!?[8]u8 {
        if (!try self.peekTag(opts)) {
            self.pos += 1;
            return null;
        }
        if (self.bytes.len - self.pos < 9) return error.Truncated;
        var payload: [8]u8 = self.bytes[self.pos + 1 ..][0..8].*;
        if (opts.desc) invert(&payload);
        self.pos += 9;
        return payload;
    }

    pub fn takeU64(self: *KeyReader, opts: ColumnOpts) DecodeError!?u64 {
        return if (try self.takeFixed(opts)) |p| decodeU64(p) else null;
    }

    pub fn takeI64(self: *KeyReader, opts: ColumnOpts) DecodeError!?i64 {
        return if (try self.takeFixed(opts)) |p| decodeI64(p) else null;
    }

    pub fn takeF64(self: *KeyReader, opts: ColumnOpts) DecodeError!?f64 {
        return if (try self.takeFixed(opts)) |p| decodeF64(p) else null;
    }

    /// Decoded length of the byte-string column at the cursor (null = NULL),
    /// without consuming it. Lets the caller allocate exactly enough.
    pub fn bytesLen(self: *const KeyReader, opts: ColumnOpts) DecodeError!?usize {
        if (!try self.peekTag(opts)) return null;
        const mask: u8 = if (opts.desc) 0xff else 0x00;
        const d = decodeBytes(null, self.bytes[self.pos + 1 ..], mask) catch |err| switch (err) {
            error.NoSpaceLeft => unreachable, // only possible with an output buffer
            else => |e| return e,
        };
        return d.len;
    }

    /// Consumes the byte-string column without storing it; returns its
    /// decoded length (null = NULL).
    pub fn skipBytes(self: *KeyReader, opts: ColumnOpts) DecodeError!?usize {
        const n = try self.bytesLen(opts);
        self.pos += 1; // the tag
        if (n == null) return null;
        const mask: u8 = if (opts.desc) 0xff else 0x00;
        const d = decodeBytes(null, self.bytes[self.pos..], mask) catch unreachable; // bytesLen succeeded
        self.pos += d.consumed;
        return n;
    }

    /// Copies the byte-string column into `out` and returns the used part.
    /// On any error the cursor has not moved.
    pub fn takeBytes(self: *KeyReader, out: []u8, opts: ColumnOpts) (DecodeError || EncodeError)!?[]u8 {
        if (!try self.peekTag(opts)) {
            self.pos += 1;
            return null;
        }
        const mask: u8 = if (opts.desc) 0xff else 0x00;
        const d = try decodeBytes(out, self.bytes[self.pos + 1 ..], mask);
        self.pos += 1 + d.consumed;
        return out[0..d.len];
    }
};

// ---- tests -----------------------------------------------------------------

const testing = std.testing;
const Order = std.math.Order;

fn orderBytes(a: []const u8, b: []const u8) Order {
    return std.mem.order(u8, a, b);
}

test "u64: big-endian bytes order like the numbers" {
    const values = [_]u64{ 0, 1, 255, 256, 65535, 65536, 1 << 32, std.math.maxInt(u64) - 1, std.math.maxInt(u64) };
    for (values, 0..) |a, i| {
        try testing.expectEqual(a, decodeU64(encodeU64(a)));
        for (values[i + 1 ..]) |b| {
            try testing.expectEqual(.lt, orderBytes(&encodeU64(a), &encodeU64(b)));
        }
    }
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 1, 0 }, &encodeU64(256));
}

test "i64: sign flip puts negatives first" {
    const values = [_]i64{ std.math.minInt(i64), -256, -2, -1, 0, 1, 2, 256, std.math.maxInt(i64) };
    for (values, 0..) |a, i| {
        try testing.expectEqual(a, decodeI64(encodeI64(a)));
        for (values[i + 1 ..]) |b| {
            try testing.expectEqual(.lt, orderBytes(&encodeI64(a), &encodeI64(b)));
        }
    }
    try testing.expectEqualSlices(u8, &.{ 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, &encodeI64(-1));
    try testing.expectEqualSlices(u8, &.{ 0x80, 0, 0, 0, 0, 0, 0, 0 }, &encodeI64(0));
}

test "f64: total order, -0 and NaN normalised" {
    const inf = std.math.inf(f64);
    const values = [_]f64{ -inf, -1.0e300, -1.5, -std.math.floatMin(f64), -std.math.floatTrueMin(f64), 0.0, std.math.floatTrueMin(f64), 1.5, 1.0e300, inf, std.math.nan(f64) };
    for (values, 0..) |a, i| {
        for (values[i + 1 ..]) |b| {
            try testing.expectEqual(.lt, orderBytes(&encodeF64(a), &encodeF64(b)));
        }
    }
    for (values[0 .. values.len - 1]) |a| try testing.expectEqual(a, decodeF64(encodeF64(a)));
    // -0.0 and +0.0 are equal, so they must have the same key ...
    try testing.expectEqualSlices(u8, &encodeF64(0.0), &encodeF64(-0.0));
    // ... which means the sign of zero does not survive a round trip.
    try testing.expect(!std.math.signbit(decodeF64(encodeF64(-0.0))));
    // Any NaN (here: negative, with payload) becomes the canonical one.
    const odd_nan: f64 = @bitCast(@as(u64, 0xfff0_0000_0000_beef));
    try testing.expectEqualSlices(u8, &encodeF64(std.math.nan(f64)), &encodeF64(odd_nan));
    try testing.expectEqual(canonical_nan, @as(u64, @bitCast(decodeF64(encodeF64(odd_nan)))));
}

test "bytes: escaping keeps order and round trips" {
    // Already in logical (lexicographic) order.
    const values = [_][]const u8{ "", "\x00", "\x00\x00", "\x00\x01", "\x01", "\x01\x00", "\x02", "a", "a\x00", "a\x00b", "a\x01", "a\x02", "ab", "b", "\xff" };
    var ea: [16]u8 = undefined;
    var eb: [16]u8 = undefined;
    var back: [8]u8 = undefined;
    for (values, 0..) |a, i| {
        const na = try encodeBytes(&ea, a);
        try testing.expectEqual(encodedBytesLen(a), na);
        const d = try decodeBytes(&back, ea[0..na], 0);
        try testing.expectEqual(na, d.consumed);
        try testing.expectEqualSlices(u8, a, back[0..d.len]);
        for (values[i + 1 ..]) |b| {
            const nb = try encodeBytes(&eb, b);
            try testing.expectEqual(.lt, orderBytes(ea[0..na], eb[0..nb]));
        }
    }
    try testing.expectEqualSlices(u8, &.{ 'a', 0x01, 0x00, 'b', 0x00 }, ea[0..try encodeBytes(&ea, "a\x00b")]);
}

test "bytes: decode errors" {
    var out: [4]u8 = undefined;
    try testing.expectError(error.Truncated, decodeBytes(&out, "ab", 0)); // no terminator
    try testing.expectError(error.Truncated, decodeBytes(&out, "a\x01", 0)); // escape, then nothing
    try testing.expectError(error.BadEscape, decodeBytes(&out, "a\x01b\x00", 0));
    try testing.expectError(error.NoSpaceLeft, decodeBytes(&out, "abcde\x00", 0));
    try testing.expectEqual(5, (try decodeBytes(null, "abcde\x00", 0)).len); // measuring needs no buffer
    try testing.expectError(error.NoSpaceLeft, encodeBytes(out[0..2], "ab"));
}

test "composite: the terminator keeps column boundaries apart" {
    var ba: [32]u8 = undefined;
    var bb: [32]u8 = undefined;
    var a: KeyWriter = .init(&ba);
    var b: KeyWriter = .init(&bb);
    // ("a", "b") < ("ab", "") because "a" < "ab" in the first column.
    try a.putBytes("a", .{});
    try a.putBytes("b", .{});
    try b.putBytes("ab", .{});
    try b.putBytes("", .{});
    try testing.expectEqual(.lt, orderBytes(a.written(), b.written()));
    try testing.expectEqualSlices(u8, &.{ 1, 'a', 0, 1, 'b', 0 }, a.written());
}

test "descending and NULL placement" {
    const desc: ColumnOpts = .{ .desc = true };
    var ba: [32]u8 = undefined;
    var bb: [32]u8 = undefined;

    // DESC ints: 5 sorts before 3.
    var a: KeyWriter = .init(&ba);
    var b: KeyWriter = .init(&bb);
    try a.putI64(5, desc);
    try b.putI64(3, desc);
    try testing.expectEqual(.lt, orderBytes(a.written(), b.written()));

    // DESC strings: "ab" sorts before its prefix "a".
    a = .init(&ba);
    b = .init(&bb);
    try a.putBytes("ab", desc);
    try b.putBytes("a", desc);
    try testing.expectEqual(.lt, orderBytes(a.written(), b.written()));

    // NULLS LAST (default) and NULLS FIRST, each for ASC and DESC: the tag is
    // never inverted, so the NULL position does not depend on `desc`.
    for ([_]bool{ false, true }) |d| {
        a = .init(&ba);
        b = .init(&bb);
        try a.putI64(std.math.maxInt(i64), .{ .desc = d });
        try b.putNull(.{ .desc = d });
        try testing.expectEqual(.lt, orderBytes(a.written(), b.written()));

        a = .init(&ba);
        b = .init(&bb);
        try a.putNull(.{ .desc = d, .nulls_first = true });
        try b.putI64(std.math.minInt(i64), .{ .desc = d, .nulls_first = true });
        try testing.expectEqual(.lt, orderBytes(a.written(), b.written()));
    }
}

test "KeyWriter is all-or-nothing, KeyReader round trips every column kind" {
    const desc: ColumnOpts = .{ .desc = true };
    var buf: [64]u8 = undefined;
    var w: KeyWriter = .init(&buf);
    try w.putU64(7, .{});
    try w.putI64(-7, desc);
    try w.putF64(-2.5, desc);
    try w.putBytes("k\x00y", desc);
    try w.putNull(.{});
    try w.putBytes("", .{});
    const full = w.len;

    // No room: nothing is written, the key so far is intact.
    var small: KeyWriter = .init(buf[0..full]);
    small.len = full - 3;
    try testing.expectError(error.NoSpaceLeft, small.putU64(1, .{}));
    try testing.expectError(error.NoSpaceLeft, small.putBytes("abc", .{}));
    try testing.expectEqual(full - 3, small.len);

    var r: KeyReader = .init(w.written());
    var out: [8]u8 = undefined;
    try testing.expectEqual(7, (try r.takeU64(.{})).?);
    try testing.expectEqual(-7, (try r.takeI64(desc)).?);
    try testing.expectEqual(-2.5, (try r.takeF64(desc)).?);
    try testing.expectEqual(3, (try r.bytesLen(desc)).?);
    try testing.expectError(error.NoSpaceLeft, r.takeBytes(out[0..2], desc)); // cursor stays put
    try testing.expectEqualSlices(u8, "k\x00y", (try r.takeBytes(&out, desc)).?);
    try testing.expectEqual(null, try r.takeI64(.{}));
    try testing.expectEqual(0, (try r.skipBytes(.{})).?);
    try testing.expect(r.done());
    try testing.expectError(error.Truncated, r.takeU64(.{}));

    // A NULLS LAST tag is not valid for a NULLS FIRST column, and vice versa.
    var bad: KeyReader = .init(&.{tag_null_last});
    try testing.expectError(error.BadTag, bad.takeI64(.{ .nulls_first = true }));
    var cut: KeyReader = .init(&.{ tag_value, 1, 2, 3 });
    try testing.expectError(error.Truncated, cut.takeU64(.{}));
}

// ---- property tests ----------------------------------------------------------
//
// Everything below uses only this file, so the tests travel with it when it is
// copied. Each test compares the encoder with `testOrder`, an oracle that
// looks at values and never at bytes.

/// SplitMix64, for tests only: deterministic, the same in the Rust twin.
const TestRng = struct {
    state: u64,

    fn next(self: *TestRng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// Integer in [0, n).
    fn below(self: *TestRng, n: u64) u64 {
        return @intCast((@as(u128, self.next()) * n) >> 64);
    }
};

const TestKind = enum { u64, i64, f64, bytes };
const TestValue = union(enum) { null, u64: u64, i64: i64, f64: f64, bytes: []const u8 };

const test_max_cols = 5;
/// Longest random byte string. Its encoding is at most 2 * 40 + 1 bytes.
const test_max_bytes = 40;

/// Float order the encoding promises: -0 equals +0, every NaN equals every
/// other NaN and is greater than all numbers.
fn testOrderF64(a: f64, b: f64) Order {
    const a_nan = a != a;
    const b_nan = b != b;
    if (a_nan or b_nan) return std.math.order(@intFromBool(a_nan), @intFromBool(b_nan));
    return std.math.order(a, b);
}

/// The logical order of two values of one column.
fn testOrder(a: TestValue, b: TestValue, opts: ColumnOpts) Order {
    if (a == .null and b == .null) return .eq;
    if (a == .null) return if (opts.nulls_first) .lt else .gt;
    if (b == .null) return if (opts.nulls_first) .gt else .lt;
    const asc: Order = switch (a) {
        .null => unreachable,
        .u64 => |x| std.math.order(x, b.u64),
        .i64 => |x| std.math.order(x, b.i64),
        .f64 => |x| testOrderF64(x, b.f64),
        .bytes => |x| std.mem.order(u8, x, b.bytes), // plain lexicographic order
    };
    return if (opts.desc) asc.invert() else asc;
}

fn testPut(w: *KeyWriter, v: TestValue, opts: ColumnOpts) EncodeError!void {
    switch (v) {
        .null => try w.putNull(opts),
        .u64 => |x| try w.putU64(x, opts),
        .i64 => |x| try w.putI64(x, opts),
        .f64 => |x| try w.putF64(x, opts),
        .bytes => |x| try w.putBytes(x, opts),
    }
}

/// Reads one column of `kind`. A byte string is copied into `out`.
fn testTake(r: *KeyReader, kind: TestKind, opts: ColumnOpts, out: []u8) (DecodeError || EncodeError)!TestValue {
    switch (kind) {
        .u64 => return if (try r.takeU64(opts)) |x| .{ .u64 = x } else .null,
        .i64 => return if (try r.takeI64(opts)) |x| .{ .i64 = x } else .null,
        .f64 => return if (try r.takeF64(opts)) |x| .{ .f64 = x } else .null,
        .bytes => return if (try r.takeBytes(out, opts)) |s| .{ .bytes = s } else .null,
    }
}

/// Reads a whole key without storing anything (byte strings are skipped).
fn testReadAll(key: []const u8, kinds: []const TestKind, opts: []const ColumnOpts) (DecodeError || error{TrailingBytes})!void {
    var r: KeyReader = .init(key);
    for (kinds, opts) |kind, o| switch (kind) {
        .u64 => _ = try r.takeU64(o),
        .i64 => _ = try r.takeI64(o),
        .f64 => _ = try r.takeF64(o),
        .bytes => _ = try r.skipBytes(o),
    };
    if (!r.done()) return error.TrailingBytes;
}

/// Bit patterns at every edge of the f64 format: both zeros, the smallest and
/// largest subnormals, the smallest normal, the largest finite, infinities,
/// signalling and quiet NaNs with and without payload, neighbours of 1.0, 2^53.
const test_f64_bits = [_]u64{
    0x0000000000000000, 0x8000000000000000, 0x0000000000000001, 0x8000000000000001,
    0x000fffffffffffff, 0x800fffffffffffff, 0x0010000000000000, 0x8010000000000000,
    0x7fefffffffffffff, 0xffefffffffffffff, 0x7ff0000000000000, 0xfff0000000000000,
    0x7ff0000000000001, 0xfff0000000000001, 0x7ff8000000000000, 0xfff8000000000000,
    0x7fffffffffffffff, 0xffffffffffffffff, 0x3ff0000000000000, 0xbff0000000000000,
    0x3ff0000000000001, 0xbff0000000000001, 0x3fefffffffffffff, 0xbfefffffffffffff,
    0x4340000000000000, 0xc340000000000000, 0x7ff4000000000000, 0xfff000000000beef,
};

/// Integers around every place where a byte of the encoding rolls over.
const test_i64 = [_]i64{
    std.math.minInt(i64), std.math.minInt(i64) + 1, -0x1_0000_0001, -0x8000_0000, -257, -256, -255,        -129,          -128,                     -1,
    0,                    1,                        127,            128,          255,  256,  0x7fff_ffff, 0x1_0000_0000, std.math.maxInt(i64) - 1, std.math.maxInt(i64),
};

/// The data bytes that collide with the framing: 00 terminator, 01 escape and
/// value tag, 02 NULLS LAST tag, and fd fe ff, which become 02 01 00 when a
/// DESC column is inverted.
const test_alphabet = [_]u8{ 0x00, 0x01, 0x02, 0xfd, 0xfe, 0xff, 'a' };

fn testRandomF64(rng: *TestRng) f64 {
    const special = test_f64_bits[@intCast(rng.below(test_f64_bits.len))];
    return switch (rng.below(4)) {
        0 => @bitCast(special),
        1 => @bitCast(rng.next()), // any bit pattern, NaNs included
        2 => @bitCast(special +% rng.below(5) -% 2), // within 2 ulp of a special
        else => @as(f64, @floatFromInt(@as(i64, @intCast(rng.below(9))) - 4)) / 2.0, // many ties
    };
}

fn testRandomI64(rng: *TestRng) i64 {
    return switch (rng.below(4)) {
        0 => test_i64[@intCast(rng.below(test_i64.len))],
        1 => @bitCast(rng.next()),
        2 => @as(i64, 1) << @intCast(rng.below(63)),
        else => @as(i64, @intCast(rng.below(7))) - 3, // many ties
    };
}

/// Mostly short strings (so that ties and prefixes are common), sometimes up
/// to `test_max_bytes`; bytes from the nasty alphabet or from all 256 values.
fn testRandomBytes(rng: *TestRng, buf: *[test_max_bytes]u8) []const u8 {
    const n: usize = @intCast(if (rng.below(4) == 0) rng.below(test_max_bytes + 1) else rng.below(5));
    for (buf[0..n]) |*c| {
        c.* = if (rng.below(4) == 0) @truncate(rng.next()) else test_alphabet[@intCast(rng.below(test_alphabet.len))];
    }
    return buf[0..n];
}

fn testRandomValue(rng: *TestRng, kind: TestKind, buf: *[test_max_bytes]u8) TestValue {
    if (rng.below(7) == 0) return .null;
    return switch (kind) {
        .u64 => .{ .u64 = @bitCast(testRandomI64(rng)) },
        .i64 => .{ .i64 = testRandomI64(rng) },
        .f64 => .{ .f64 = testRandomF64(rng) },
        .bytes => .{ .bytes = testRandomBytes(rng, buf) },
    };
}

test "f64: byte order is the total order on every special pattern and on random bits" {
    for (test_f64_bits) |x| for (test_f64_bits) |y| {
        const a: f64 = @bitCast(x);
        const b: f64 = @bitCast(y);
        try testing.expectEqual(testOrderF64(a, b), orderBytes(&encodeF64(a), &encodeF64(b)));
    };
    var rng: TestRng = .{ .state = 1 };
    for (0..20_000) |_| {
        const a = testRandomF64(&rng);
        const b = testRandomF64(&rng);
        const ea = encodeF64(a);
        try testing.expectEqual(testOrderF64(a, b), orderBytes(&ea, &encodeF64(b)));
        // Decoding gives an equal value, and encoding that gives the same key.
        const back = decodeF64(ea);
        try testing.expectEqual(.eq, testOrderF64(a, back));
        try testing.expectEqualSlices(u8, &ea, &encodeF64(back));
        // Apart from -0.0 and NaN the round trip is exact to the bit.
        const bits: u64 = @bitCast(a);
        if (a == a and bits != sign_bit) try testing.expectEqual(bits, @as(u64, @bitCast(back)));
    }
}

test "i64 and u64: byte order is numeric order on extremes and on random values" {
    for (test_i64) |a| for (test_i64) |b| {
        try testing.expectEqual(std.math.order(a, b), orderBytes(&encodeI64(a), &encodeI64(b)));
    };
    var rng: TestRng = .{ .state = 2 };
    for (0..20_000) |_| {
        const a = testRandomI64(&rng);
        const b = testRandomI64(&rng);
        try testing.expectEqual(std.math.order(a, b), orderBytes(&encodeI64(a), &encodeI64(b)));
        try testing.expectEqual(a, decodeI64(encodeI64(a)));
        // The same bits read as unsigned: no sign flip, a different order.
        const ua: u64 = @bitCast(a);
        const ub: u64 = @bitCast(b);
        try testing.expectEqual(std.math.order(ua, ub), orderBytes(&encodeU64(ua), &encodeU64(ub)));
        try testing.expectEqual(ua, decodeU64(encodeU64(ua)));
    }
}

test "bytes: every string of up to 3 framing bytes, ASC and DESC" {
    // 00 01 02 are terminator, escape and a tag; fe ff are what turns into
    // escape and terminator once a DESC column is inverted.
    const letters = [_]u8{ 0x00, 0x01, 0x02, 0xfe, 0xff };
    const count = 1 + 5 + 25 + 125;
    var strings: [count][3]u8 = undefined;
    var lens: [count]usize = undefined;
    for (0..count) |i| {
        // i -> a string: lengths 0, 1, 2, 3 take 1, 5, 25, 125 numbers each.
        var rest = i;
        var len: usize = 0;
        var block: usize = 1;
        while (rest >= block) : (len += 1) {
            rest -= block;
            block *= letters.len;
        }
        lens[i] = len;
        for (strings[i][0..len]) |*c| {
            c.* = letters[rest % letters.len];
            rest /= letters.len;
        }
    }
    for ([_]bool{ false, true }) |desc| {
        const opts: ColumnOpts = .{ .desc = desc };
        var keys: [count][8]u8 = undefined; // tag + at most 6 escaped bytes + terminator
        var key_lens: [count]usize = undefined;
        for (0..count) |i| {
            const s = strings[i][0..lens[i]];
            var w: KeyWriter = .init(&keys[i]);
            try w.putBytes(s, opts);
            key_lens[i] = w.len;
            try testing.expectEqual(2 + encodedBytesLen(s) - 1, w.len);
            var r: KeyReader = .init(w.written());
            var back: [3]u8 = undefined;
            try testing.expectEqualSlices(u8, s, (try r.takeBytes(&back, opts)).?);
            try testing.expect(r.done());
        }
        for (0..count) |i| for (0..count) |j| {
            const logical = testOrder(.{ .bytes = strings[i][0..lens[i]] }, .{ .bytes = strings[j][0..lens[j]] }, opts);
            try testing.expectEqual(logical, orderBytes(keys[i][0..key_lens[i]], keys[j][0..key_lens[j]]));
        };
    }
}

test "composite (bytes, bytes): all short framing strings and NULL, all 16 option combinations" {
    // Column 1 of one row is often a prefix of column 1 of the other while
    // column 2 pulls the other way: only correct framing gets these right.
    const letters = [_]u8{ 0x00, 0x01, 0xfe, 0xff };
    const count = 1 + 1 + 4 + 16; // NULL, "", 4 of length 1, 16 of length 2
    var store: [count][2]u8 = undefined;
    var values: [count]TestValue = undefined;
    values[0] = .null;
    values[1] = .{ .bytes = "" };
    for (letters, 0..) |x, i| {
        store[2 + i] = .{ x, 0 };
        values[2 + i] = .{ .bytes = store[2 + i][0..1] };
        for (letters, 0..) |y, j| {
            const k = 6 + i * letters.len + j;
            store[k] = .{ x, y };
            values[k] = .{ .bytes = &store[k] };
        }
    }
    var keys: [count * count][12]u8 = undefined; // 2 * (tag + 4 escaped bytes + terminator)
    var key_lens: [count * count]usize = undefined;
    for (0..16) |combo| {
        const o1: ColumnOpts = .{ .desc = combo & 1 != 0, .nulls_first = combo & 2 != 0 };
        const o2: ColumnOpts = .{ .desc = combo & 4 != 0, .nulls_first = combo & 8 != 0 };
        for (0..count * count) |row| {
            var w: KeyWriter = .init(&keys[row]);
            try testPut(&w, values[row / count], o1);
            try testPut(&w, values[row % count], o2);
            key_lens[row] = w.len;
        }
        for (0..count * count) |a| for (0..count * count) |b| {
            var logical = testOrder(values[a / count], values[b / count], o1);
            if (logical == .eq) logical = testOrder(values[a % count], values[b % count], o2);
            if (logical != orderBytes(keys[a][0..key_lens[a]], keys[b][0..key_lens[b]])) {
                std.debug.print("options {d}, rows {d} and {d}\n", .{ combo, a, b });
                return error.TestUnexpectedResult;
            }
        };
    }
}

test "random schemas: key order is logical order, round trip, every truncation rejected" {
    var rng: TestRng = .{ .state = 0x5eed };
    var seen = [3]u32{ 0, 0, 0 };
    for (0..4000) |_| {
        // A random schema: 1 to 5 columns of any kind with any options.
        const ncol: usize = @intCast(1 + rng.below(test_max_cols));
        var kinds: [test_max_cols]TestKind = undefined;
        var opts: [test_max_cols]ColumnOpts = undefined;
        for (0..ncol) |c| {
            kinds[c] = @fromBackingInt(@intCast(rng.below(4)));
            opts[c] = .{ .desc = rng.below(2) == 1, .nulls_first = rng.below(2) == 1 };
        }
        // Two random rows ...
        var text: [2][test_max_cols][test_max_bytes]u8 = undefined;
        var rows: [2][test_max_cols]TestValue = undefined;
        for (0..2) |r| for (0..ncol) |c| {
            rows[r][c] = testRandomValue(&rng, kinds[c], &text[r][c]);
        };
        // ... that share a prefix of columns, so later columns and ties matter ...
        const shared: usize = @intCast(rng.below(ncol + 1));
        for (0..shared) |c| rows[1][c] = rows[0][c];
        // ... and where one string is often a prefix of the other, or one byte longer.
        const pc: usize = @intCast(rng.below(ncol));
        if (rows[0][pc] == .bytes and rng.below(2) == 0) {
            const s = rows[0][pc].bytes;
            var n: usize = @intCast(rng.below(s.len + 1));
            @memcpy(text[1][pc][0..n], s[0..n]);
            if (n < test_max_bytes and rng.below(2) == 0) {
                text[1][pc][n] = test_alphabet[@intCast(rng.below(test_alphabet.len))];
                n += 1;
            }
            rows[1][pc] = .{ .bytes = text[1][pc][0..n] };
        }

        var logical: Order = .eq;
        for (0..ncol) |c| {
            logical = testOrder(rows[0][c], rows[1][c], opts[c]);
            if (logical != .eq) break;
        }
        seen[@backingInt(logical)] += 1;

        var key_bufs: [2][test_max_cols * (2 * test_max_bytes + 2)]u8 = undefined;
        var keys: [2][]const u8 = undefined;
        for (0..2) |r| {
            var w: KeyWriter = .init(&key_bufs[r]);
            var ends: [test_max_cols]usize = undefined; // key length after each column
            for (0..ncol) |c| {
                try testPut(&w, rows[r][c], opts[c]);
                ends[c] = w.len;
            }
            const key = w.written();
            keys[r] = key;

            // Round trip: equal values come back, and they encode to the same bytes.
            var reader: KeyReader = .init(key);
            var back_text: [test_max_cols][test_max_bytes]u8 = undefined;
            var again_buf: [test_max_cols * (2 * test_max_bytes + 2)]u8 = undefined;
            var again: KeyWriter = .init(&again_buf);
            for (0..ncol) |c| {
                const peeked = if (kinds[c] == .bytes) try reader.bytesLen(opts[c]) else null;
                const back = try testTake(&reader, kinds[c], opts[c], &back_text[c]);
                try testing.expectEqual(.eq, testOrder(rows[r][c], back, opts[c]));
                if (back == .bytes) try testing.expectEqual(back.bytes.len, peeked.?);
                try testing.expectEqual(ends[c], reader.pos);
                try testPut(&again, back, opts[c]);
            }
            try testing.expect(reader.done());
            try testing.expectEqualSlices(u8, key, again.written());

            for (0..key.len) |cut| {
                // A key cut anywhere is Truncated, never garbage and never a crash.
                try testing.expectError(error.Truncated, testReadAll(key[0..cut], kinds[0..ncol], opts[0..ncol]));
                // A buffer of `cut` bytes holds the columns that fit completely
                // and not one byte of the column that does not.
                var small_buf: [test_max_cols * (2 * test_max_bytes + 2)]u8 = undefined;
                var small: KeyWriter = .init(small_buf[0..cut]);
                var fitted: usize = 0;
                for (0..ncol) |c| {
                    testPut(&small, rows[r][c], opts[c]) catch break;
                    fitted = ends[c];
                }
                try testing.expect(fitted < key.len);
                try testing.expectEqual(fitted, small.len);
                try testing.expectEqualSlices(u8, key[0..fitted], small.written());
            }
            // One byte too many is noticed as well.
            key_bufs[r][key.len] = tag_value;
            try testing.expectError(error.TrailingBytes, testReadAll(key_bufs[r][0 .. key.len + 1], kinds[0..ncol], opts[0..ncol]));
        }

        if (logical != orderBytes(keys[0], keys[1])) {
            std.debug.print("{any} {any}\n  {any} -> {x}\n  {any} -> {x}\n", .{ kinds[0..ncol], opts[0..ncol], rows[0][0..ncol], keys[0], rows[1][0..ncol], keys[1] });
            return error.TestUnexpectedResult;
        }
    }
    // All three outcomes must be common, or the test proves little.
    for (seen) |n| try testing.expect(n > 500);
}

test "decoder fuzz: damaged keys and random bytes never crash the reader, and what it accepts is canonical" {
    const bias = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x7f, 0x80, 0xfd, 0xfe, 0xff };
    var rng: TestRng = .{ .state = 99 };
    var accepted: u32 = 0;
    var rejected: u32 = 0;
    for (0..50_000) |_| {
        const ncol: usize = @intCast(1 + rng.below(3));
        var kinds: [3]TestKind = undefined;
        var opts: [3]ColumnOpts = undefined;
        for (0..ncol) |c| {
            kinds[c] = @fromBackingInt(@intCast(rng.below(4)));
            opts[c] = .{ .desc = rng.below(2) == 1, .nulls_first = rng.below(2) == 1 };
        }

        // The input: random bytes, or a valid key with one byte overwritten
        // (which is how most corruption looks, and gets much deeper into the
        // reader than noise does).
        var buf: [3 * (2 * test_max_bytes + 2)]u8 = undefined;
        var n: usize = undefined;
        if (rng.below(3) == 0) {
            n = @intCast(rng.below(21));
            for (buf[0..n]) |*c| c.* = @truncate(rng.next());
        } else {
            var w: KeyWriter = .init(&buf);
            var scratch: [test_max_bytes]u8 = undefined;
            for (0..ncol) |c| try testPut(&w, testRandomValue(&rng, kinds[c], &scratch), opts[c]);
            n = w.len;
            const at: usize = @intCast(rng.below(n));
            buf[at] = if (rng.below(4) == 0) @truncate(rng.next()) else bias[@intCast(rng.below(bias.len))];
        }

        var reader: KeyReader = .init(buf[0..n]);
        var text: [3][buf.len]u8 = undefined;
        var again_buf: [buf.len]u8 = undefined;
        var again: KeyWriter = .init(&again_buf);
        var canonical = true;
        const ok = for (0..ncol) |c| {
            const before = reader.pos;
            const v = testTake(&reader, kinds[c], opts[c], &text[c]) catch {
                try testing.expectEqual(before, reader.pos); // an error never moves the cursor
                break false;
            };
            // The reader takes any 8 bytes as an f64. The two families that
            // encodeF64 never writes (-0.0, NaNs other than the canonical one)
            // are for the layer above to reject.
            if (v == .f64) {
                const bits: u64 = @bitCast(v.f64);
                if (bits == sign_bit or (v.f64 != v.f64 and bits != canonical_nan)) canonical = false;
            }
            try testPut(&again, v, opts[c]);
        } else reader.done();
        if (!ok) {
            rejected += 1;
            continue;
        }
        accepted += 1;
        // Accepted and canonical means: these are exactly the bytes the
        // writer produces for the decoded values. No second spelling exists.
        if (canonical) try testing.expectEqualSlices(u8, buf[0..n], again.written());
    }
    std.debug.print("ACC {d} REJ {d}\n", .{ accepted, rejected });
    try testing.expect(accepted > 5000 and rejected > 5000);
}

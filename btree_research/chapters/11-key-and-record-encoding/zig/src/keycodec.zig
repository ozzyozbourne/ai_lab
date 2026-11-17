//! Order-preserving ("byte-comparable", "memcmp-able") key encoding.
//!
//! STANDALONE: depends on `std` only. Chapter 12 may copy this file as
//! `base_keycodec.zig`. Nothing here allocates: the caller owns every buffer.
//!
//! THE property (tested here and, against an independent oracle, in
//! model.zig): for two keys built with the same sequence of `put*` calls and
//! the same `ColumnOpts` per column,
//!
//!     std.mem.order(u8, key_a, key_b) == logical order of the column values
//!
//! so a B-tree that only knows how to compare byte strings sorts them right.
//!
//! Layout of one column inside a key:
//!
//!     tag (1 byte)   0x00 NULL when NULLS FIRST
//!                    0x01 a value follows
//!                    0x02 NULL when NULLS LAST (the default, as in Postgres)
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
    /// NULLs sort before all values (default: after all values).
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

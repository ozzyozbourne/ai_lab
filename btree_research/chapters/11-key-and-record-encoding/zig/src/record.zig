//! Records: the compact, self-describing row format that needs a comparator.
//!
//! This is the SQLite / Turso record idea, simplified:
//!
//!     header_len   varint   number of bytes in the serial-type area
//!     serial types varint per column:
//!                    0      NULL            (no body bytes)
//!                    1      int             body: zigzag LEB128 varint
//!                    2      float           body: 8 bytes, little-endian IEEE bits
//!                    n >= 3 text of n - 3 bytes, stored raw
//!     bodies       in column order
//!
//! (Real SQLite: header_len includes itself, integers are fixed 1/2/3/4/6/8
//! bytes chosen by magnitude, and text is `13 + 2 * len`.)
//!
//! Compared with a key from keycodec.zig a record is smaller and can be read
//! back without a schema, but two records can only be ordered by decoding
//! their columns and calling a comparator (`compareRecords`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const varint = @import("varint.zig");
const row_mod = @import("row.zig");

const Value = row_mod.Value;
const Column = row_mod.Column;

const serial_null = 0;
const serial_int = 1;
const serial_float = 2;
const serial_text_base = 3;

pub const DecodeError = varint.DecodeError || error{Corrupt};

fn serialType(v: Value) u64 {
    return switch (v) {
        .null => serial_null,
        .int => serial_int,
        .float => serial_float,
        .text => |s| serial_text_base + s.len,
    };
}

fn headerLen(row: []const Value) usize {
    var n: usize = 0;
    for (row) |v| n += varint.encodedLen(serialType(v));
    return n;
}

/// Exact number of bytes `encodeRecord` produces for `row`.
pub fn recordLen(row: []const Value) usize {
    const h = headerLen(row);
    var n = varint.encodedLen(h) + h;
    for (row) |v| n += switch (v) {
        .null => 0,
        .int => |x| varint.encodedLen(varint.zigzag(x)),
        .float => 8,
        .text => |s| s.len,
    };
    return n;
}

/// Encodes `row` into `buf` and returns the used part.
pub fn encodeRecord(buf: []u8, row: []const Value) error{NoSpaceLeft}![]u8 {
    if (buf.len < recordLen(row)) return error.NoSpaceLeft;
    var pos = try varint.encode(buf, headerLen(row));
    for (row) |v| pos += try varint.encode(buf[pos..], serialType(v));
    for (row) |v| switch (v) {
        .null => {},
        .int => |x| pos += try varint.encode(buf[pos..], varint.zigzag(x)),
        .float => |x| {
            std.mem.writeInt(u64, buf[pos..][0..8], @bitCast(x), .little);
            pos += 8;
        },
        .text => |s| {
            @memcpy(buf[pos..][0..s.len], s);
            pos += s.len;
        },
    };
    return buf[0..pos];
}

/// Walks the columns of a record one at a time, without allocating.
/// Text values borrow from the record bytes.
pub const RecordCursor = struct {
    bytes: []const u8,
    type_pos: usize,
    types_end: usize,
    body_pos: usize,

    pub fn init(bytes: []const u8) DecodeError!RecordCursor {
        const h = try varint.decode(bytes);
        if (h.value > bytes.len - h.len) return error.Truncated;
        const types_end = h.len + @as(usize, @intCast(h.value));
        return .{ .bytes = bytes, .type_pos = h.len, .types_end = types_end, .body_pos = types_end };
    }

    /// The next column, or null after the last one.
    pub fn next(self: *RecordCursor) DecodeError!?Value {
        if (self.type_pos == self.types_end) return null;
        const t = try varint.decode(self.bytes[self.type_pos..self.types_end]);
        const body = self.bytes[self.body_pos..];
        var used: usize = 0;
        const value: Value = switch (t.value) {
            serial_null => .null,
            serial_int => blk: {
                const d = try varint.decode(body);
                used = d.len;
                break :blk .{ .int = varint.unzigzag(d.value) };
            },
            serial_float => blk: {
                if (body.len < 8) return error.Truncated;
                used = 8;
                break :blk .{ .float = @bitCast(std.mem.readInt(u64, body[0..8], .little)) };
            },
            else => blk: {
                const n = t.value - serial_text_base;
                if (n > body.len) return error.Truncated;
                used = @intCast(n);
                break :blk .{ .text = body[0..used] };
            },
        };
        // Advance only after the whole column decoded.
        self.type_pos += t.len;
        self.body_pos += used;
        return value;
    }
};

/// Decodes a whole record. The value array and copies of the text bytes come
/// from `arena`, so the row stays valid after the page buffer that held
/// `bytes` is reused. Free everything at once with the arena.
pub fn decodeRecord(arena: Allocator, bytes: []const u8) (DecodeError || Allocator.Error)![]Value {
    var count: usize = 0;
    var counter: RecordCursor = try .init(bytes);
    while (try counter.next()) |_| count += 1;
    if (counter.body_pos != bytes.len) return error.Corrupt; // trailing bytes

    const row = try arena.alloc(Value, count);
    var cursor: RecordCursor = try .init(bytes);
    for (row) |*out| {
        const v = (try cursor.next()).?;
        out.* = switch (v) {
            .text => |s| .{ .text = try arena.dupe(u8, s) },
            else => v,
        };
    }
    return row;
}

/// Structural check: header and bodies are consistent and nothing is left over.
pub fn validateRecord(bytes: []const u8) DecodeError!void {
    var cursor: RecordCursor = try .init(bytes);
    while (try cursor.next()) |_| {}
    if (cursor.body_pos != bytes.len) return error.Corrupt;
}

/// Counters for the "what does a comparison cost" demonstration.
pub const CompareStats = struct {
    calls: u64 = 0,
    columns_decoded: u64 = 0,
};

/// The comparator: orders two records by their first `schema.len` columns.
/// It decodes column by column and stops at the first difference, so later
/// columns of long rows are never touched.
pub fn compareRecords(a: []const u8, b: []const u8, schema: []const Column, stats: ?*CompareStats) DecodeError!Order {
    if (stats) |s| s.calls += 1;
    var ca: RecordCursor = try .init(a);
    var cb: RecordCursor = try .init(b);
    for (schema) |col| {
        const va = (try ca.next()) orelse return error.Corrupt;
        const vb = (try cb.next()) orelse return error.Corrupt;
        if (stats) |s| s.columns_decoded += 2;
        if (!row_mod.matches(va, col.type) or !row_mod.matches(vb, col.type)) return error.Corrupt;
        const o = row_mod.compareValues(va, vb, col.opts);
        if (o != .eq) return o;
    }
    return .eq;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "record bytes for a small row" {
    var buf: [32]u8 = undefined;
    const row = [_]Value{ .{ .text = "Anna" }, .{ .int = 7 }, .null, .{ .float = 1.0 } };
    const rec = try encodeRecord(&buf, &row);
    try testing.expectEqual(recordLen(&row), rec.len);
    try testing.expectEqualSlices(u8, &.{
        4, // header_len: four serial types follow
        7, 1, 0, 2, // text of 4 bytes, int, NULL, float
        'A', 'n', 'n', 'a', // text body
        14, // zigzag(7)
        0, 0, 0, 0, 0, 0, 0xf0, 0x3f, // 1.0, little-endian
    }, rec);
    try validateRecord(rec);
    try testing.expectError(error.NoSpaceLeft, encodeRecord(buf[0 .. rec.len - 1], &row));
}

test "decodeRecord copies text into the arena" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var page: [32]u8 = undefined;
    const row = [_]Value{ .{ .text = "Anna" }, .{ .int = -7 }, .null, .{ .float = -2.5 } };
    const rec = try encodeRecord(&page, &row);
    const back = try decodeRecord(arena_state.allocator(), rec);

    @memset(&page, 0xaa); // the "page" is reused; the decoded row must not care
    try testing.expectEqual(4, back.len);
    try testing.expectEqualStrings("Anna", back[0].text);
    try testing.expectEqual(-7, back[1].int);
    try testing.expect(back[2] == .null);
    try testing.expectEqual(-2.5, back[3].float);
}

test "decodeRecord under allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var buf: [64]u8 = undefined;
            const row = [_]Value{ .{ .text = "first" }, .{ .int = 1 }, .{ .text = "second" } };
            const rec = try encodeRecord(&buf, &row);
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit(); // releases a half-built row too
            const back = try decodeRecord(arena_state.allocator(), rec);
            try testing.expectEqualStrings("second", back[2].text);
        }
    }.run, .{});
}

test "corrupt records are rejected, never trusted" {
    var buf: [32]u8 = undefined;
    const row = [_]Value{ .{ .text = "Anna" }, .{ .int = 7 } };
    const rec = try encodeRecord(&buf, &row);
    for (0..rec.len) |cut| {
        try testing.expect(std.meta.isError(validateRecord(rec[0..cut])));
    }
    buf[rec.len] = 0;
    try testing.expectError(error.Corrupt, validateRecord(buf[0 .. rec.len + 1])); // trailing byte
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.Corrupt, decodeRecord(arena_state.allocator(), buf[0 .. rec.len + 1]));
    try testing.expectError(error.Truncated, validateRecord(&.{ 1, 200 })); // serial type varint cut off
    try testing.expectError(error.Truncated, validateRecord(&.{ 1, 9, 'a' })); // text of 6 bytes, 1 present
    try testing.expectError(error.Truncated, validateRecord(&.{9})); // header longer than the record
}

test "a serial type may not run out of the header into the bodies" {
    // header_len = 1, but the type varint `81 01` needs two bytes. Its second
    // byte is the first body byte. Read across the boundary it would say
    // "text of 126 bytes", and 126 body bytes do follow, so only the bound
    // `types_end` stops the cursor from inventing a column.
    var b: [129]u8 = @splat(0);
    b[0] = 1;
    b[1] = 0x81;
    b[2] = 0x01;
    var cursor: RecordCursor = try .init(&b);
    try testing.expectError(error.Truncated, cursor.next());
    try testing.expectError(error.Truncated, validateRecord(&b));
}

test "records keep float bits: equal under the comparator, different as bytes" {
    // A key normalises -0.0 and NaN so that equal values are equal bytes. A
    // record must read back exactly, so it does not: never memcmp records.
    const schema = [_]Column{.{ .type = .float }};
    const odd_nan: f64 = @bitCast(@as(u64, 0xfff0_0000_0000_beef));
    const pairs = [_][2]f64{ .{ 0.0, -0.0 }, .{ std.math.nan(f64), odd_nan } };
    for (pairs) |pair| {
        var ba: [16]u8 = undefined;
        var bb: [16]u8 = undefined;
        const a = try encodeRecord(&ba, &.{.{ .float = pair[0] }});
        const b = try encodeRecord(&bb, &.{.{ .float = pair[1] }});
        try testing.expectEqual(.eq, try compareRecords(a, b, &schema, null));
        try testing.expect(!std.mem.eql(u8, a, b));
        // The bits survive the round trip.
        var cursor: RecordCursor = try .init(b);
        const back = (try cursor.next()).?.float;
        try testing.expectEqual(@as(u64, @bitCast(pair[1])), @as(u64, @bitCast(back)));
        // The keys of the same two rows are identical.
        var ka: [9]u8 = undefined;
        var kb: [9]u8 = undefined;
        try testing.expectEqualSlices(
            u8,
            try row_mod.encodeKey(&ka, &.{.{ .float = pair[0] }}, &schema),
            try row_mod.encodeKey(&kb, &.{.{ .float = pair[1] }}, &schema),
        );
    }
}

test "compareRecords: stops at the first differing column" {
    const schema = [_]Column{ .{ .type = .text }, .{ .type = .int, .opts = .{ .desc = true } } };
    var ba: [32]u8 = undefined;
    var bb: [32]u8 = undefined;
    const a = try encodeRecord(&ba, &.{ .{ .text = "Ann" }, .{ .int = 7 } });
    const b = try encodeRecord(&bb, &.{ .{ .text = "Anna" }, .{ .int = 9 } });
    var stats: CompareStats = .{};
    try testing.expectEqual(.lt, try compareRecords(a, b, &schema, &stats));
    try testing.expectEqual(2, stats.columns_decoded); // only the first column of each

    const c = try encodeRecord(&bb, &.{ .{ .text = "Ann" }, .{ .int = 9 } });
    try testing.expectEqual(.gt, try compareRecords(a, c, &schema, &stats)); // DESC: 7 after 9
    try testing.expectEqual(6, stats.columns_decoded);
    try testing.expectEqual(2, stats.calls);

    // A record with the wrong column type for this schema is an error, not a crash.
    const d = try encodeRecord(&bb, &.{ .{ .int = 1 }, .{ .int = 9 } });
    try testing.expectError(error.Corrupt, compareRecords(a, d, &schema, null));
    const short = try encodeRecord(&bb, &.{.{ .text = "Ann" }});
    try testing.expectError(error.Corrupt, compareRecords(a, short, &schema, null));
}

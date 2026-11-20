//! Typed rows: the logical layer above the two encodings.
//!
//! `compareRows` is the definition of "logical order" for this chapter and
//! the ORACLE of the model test: it looks only at values, never at bytes.
//! `encodeKey` maps a row to a byte-comparable key (keycodec.zig); record.zig
//! maps a row to a compact record that needs a comparator.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const keycodec = @import("keycodec.zig");

pub const ColumnOpts = keycodec.ColumnOpts;

pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    /// Borrowed bytes; compared bytewise (no collation).
    text: []const u8,
};

pub const ColumnType = enum { int, float, text };

/// One key column: its type and how it sorts. A slice of these is the schema
/// that both the comparator and the key decoder need; the bytes do not carry it.
pub const Column = struct {
    type: ColumnType,
    opts: ColumnOpts = .{},
};

/// Float order used everywhere in this chapter: -0 equals +0, all NaNs are
/// equal to each other and greater than every number.
pub fn orderF64(a: f64, b: f64) Order {
    const a_nan = a != a;
    const b_nan = b != b;
    if (a_nan or b_nan) return std.math.order(@intFromBool(a_nan), @intFromBool(b_nan));
    return std.math.order(a, b);
}

/// Logical order of two values of the same column.
/// The NULL rules are those of Postgres' `_bt_compare`: NULL equals NULL,
/// NULLS FIRST / LAST decides NULL against a value, and DESC reverses only
/// value-against-value comparisons.
pub fn compareValues(a: Value, b: Value, opts: ColumnOpts) Order {
    const a_null = a == .null;
    const b_null = b == .null;
    if (a_null and b_null) return .eq;
    if (a_null) return if (opts.nulls_first) .lt else .gt;
    if (b_null) return if (opts.nulls_first) .gt else .lt;
    const asc: Order = switch (a) {
        .null => unreachable,
        .int => |x| std.math.order(x, b.int),
        .float => |x| orderF64(x, b.float),
        .text => |x| std.mem.order(u8, x, b.text),
    };
    return if (opts.desc) asc.invert() else asc;
}

/// Lexicographic over the columns: the first column that differs decides.
pub fn compareRows(a: []const Value, b: []const Value, schema: []const Column) Order {
    for (schema, a, b) |col, x, y| {
        const o = compareValues(x, y, col.opts);
        if (o != .eq) return o;
    }
    return .eq;
}

pub fn matches(v: Value, t: ColumnType) bool {
    return switch (v) {
        .null => true,
        .int => t == .int,
        .float => t == .float,
        .text => t == .text,
    };
}

pub const KeyError = error{ NoSpaceLeft, TypeMismatch };

/// Exact number of bytes `encodeKey` produces for `row`.
pub fn keyLen(row: []const Value) usize {
    var n: usize = 0;
    for (row) |v| n += switch (v) {
        .null => 1,
        .int, .float => 9,
        .text => |s| 1 + keycodec.encodedBytesLen(s),
    };
    return n;
}

/// Encodes `row` as one composite key into `buf` and returns the used part.
pub fn encodeKey(buf: []u8, row: []const Value, schema: []const Column) KeyError![]u8 {
    std.debug.assert(row.len == schema.len);
    var w: keycodec.KeyWriter = .init(buf);
    for (schema, row) |col, v| {
        if (!matches(v, col.type)) return error.TypeMismatch;
        switch (v) {
            .null => try w.putNull(col.opts),
            .int => |x| try w.putI64(x, col.opts),
            .float => |x| try w.putF64(x, col.opts),
            .text => |x| try w.putBytes(x, col.opts),
        }
    }
    return buf[0..w.len];
}

/// Same, into exactly `keyLen(row)` bytes from `allocator` (caller frees).
/// With a `BufferFirstAllocator` short keys never touch the heap.
pub fn encodeKeyAlloc(allocator: Allocator, row: []const Value, schema: []const Column) (KeyError || Allocator.Error)![]u8 {
    const buf = try allocator.alloc(u8, keyLen(row));
    errdefer allocator.free(buf);
    const key = try encodeKey(buf, row, schema);
    std.debug.assert(key.len == buf.len);
    return buf;
}

pub const DecodeKeyError = keycodec.DecodeError || Allocator.Error || error{TrailingBytes};

/// Decodes a key back into values. Everything (the value array and the text
/// bytes) is allocated from `arena` and is meant to be freed all at once.
/// Text cannot be borrowed from `key` the way record text can: it is stored
/// escaped (and inverted for DESC), so it has to be rebuilt somewhere.
pub fn decodeKey(arena: Allocator, key: []const u8, schema: []const Column) DecodeKeyError![]Value {
    const row = try arena.alloc(Value, schema.len);
    var r: keycodec.KeyReader = .init(key);
    for (schema, row) |col, *out| {
        out.* = switch (col.type) {
            .int => if (try r.takeI64(col.opts)) |x| .{ .int = x } else .null,
            .float => if (try r.takeF64(col.opts)) |x| .{ .float = x } else .null,
            .text => blk: {
                const n = (try r.bytesLen(col.opts)) orelse {
                    _ = try r.skipBytes(col.opts); // consume the NULL tag
                    break :blk .null;
                };
                const text = try arena.alloc(u8, n);
                _ = r.takeBytes(text, col.opts) catch |err| switch (err) {
                    error.NoSpaceLeft => unreachable, // sized by bytesLen
                    else => |e| return e,
                };
                break :blk .{ .text = text };
            },
        };
    }
    if (!r.done()) return error.TrailingBytes;
    return row;
}

/// Checks that `key` is a well-formed key for `schema`, without allocating:
/// every column decodes, nothing is left over, and re-encoding each float
/// column gives the same bytes (so -0.0 or a stray NaN payload is caught).
pub fn validateKey(key: []const u8, schema: []const Column) (keycodec.DecodeError || error{ TrailingBytes, NotCanonical })!void {
    var r: keycodec.KeyReader = .init(key);
    for (schema) |col| {
        const start = r.pos;
        switch (col.type) {
            .int => _ = try r.takeI64(col.opts),
            .float => if (try r.takeF64(col.opts)) |x| {
                var expect = keycodec.encodeF64(x);
                if (col.opts.desc) keycodec.invert(&expect);
                if (!std.mem.eql(u8, &expect, key[start + 1 .. r.pos])) return error.NotCanonical;
            },
            .text => _ = try r.skipBytes(col.opts),
        }
    }
    if (!r.done()) return error.TrailingBytes;
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

const people = [_]Column{
    .{ .type = .text },
    .{ .type = .int, .opts = .{ .desc = true } },
    .{ .type = .int },
};

test "compareValues: NULL rules and DESC" {
    const one: Value = .{ .int = 1 };
    const two: Value = .{ .int = 2 };
    try testing.expectEqual(.lt, compareValues(one, two, .{}));
    try testing.expectEqual(.gt, compareValues(one, two, .{ .desc = true }));
    try testing.expectEqual(.eq, compareValues(.null, .null, .{ .desc = true }));
    // NULL placement ignores DESC.
    try testing.expectEqual(.gt, compareValues(.null, one, .{}));
    try testing.expectEqual(.gt, compareValues(.null, one, .{ .desc = true }));
    try testing.expectEqual(.lt, compareValues(.null, one, .{ .nulls_first = true }));
    try testing.expectEqual(.lt, compareValues(.null, one, .{ .desc = true, .nulls_first = true }));
    // Floats: NaN is the greatest, zeros are equal.
    try testing.expectEqual(.eq, orderF64(-0.0, 0.0));
    try testing.expectEqual(.gt, orderF64(std.math.nan(f64), std.math.inf(f64)));
    try testing.expectEqual(.eq, orderF64(std.math.nan(f64), std.math.nan(f64)));
}

test "encodeKey: key order equals row order, and decodeKey round trips" {
    const a = [_]Value{ .{ .text = "Ann" }, .{ .int = 7 }, .{ .int = 2 } };
    const b = [_]Value{ .{ .text = "Ann" }, .{ .int = -2 }, .{ .int = 3 } };
    const c = [_]Value{ .{ .text = "Ann" }, .null, .{ .int = 4 } };
    const d = [_]Value{ .{ .text = "Anna" }, .{ .int = 256 }, .{ .int = 8 } };
    const rows = [_][]const Value{ &a, &b, &c, &d }; // in logical order

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bufs: [4][64]u8 = undefined;
    var keys: [4][]u8 = undefined;
    for (rows, 0..) |row, i| {
        keys[i] = try encodeKey(&bufs[i], row, &people);
        try testing.expectEqual(keyLen(row), keys[i].len);
        try validateKey(keys[i], &people);
        const back = try decodeKey(arena, keys[i], &people);
        try testing.expectEqual(.eq, compareRows(row, back, &people));
    }
    for (0..rows.len) |i| for (0..rows.len) |j| {
        try testing.expectEqual(compareRows(rows[i], rows[j], &people), std.mem.order(u8, keys[i], keys[j]));
    };
}

test "encodeKey errors: wrong type, no space" {
    var buf: [64]u8 = undefined;
    const wrong = [_]Value{ .{ .int = 1 }, .{ .int = 1 }, .{ .int = 1 } };
    try testing.expectError(error.TypeMismatch, encodeKey(&buf, &wrong, &people));
    const row = [_]Value{ .{ .text = "Ann" }, .{ .int = 7 }, .{ .int = 2 } };
    try testing.expectError(error.NoSpaceLeft, encodeKey(buf[0 .. keyLen(&row) - 1], &row, &people));
}

test "validateKey and decodeKey reject malformed keys" {
    var buf: [64]u8 = undefined;
    const row = [_]Value{ .{ .text = "Ann" }, .{ .int = 7 }, .{ .int = 2 } };
    const key = try encodeKey(&buf, &row, &people);
    // Cut anywhere (inside the text, after its terminator, on a tag, inside
    // an integer), the key is Truncated; decodeKey agrees.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for (0..key.len) |cut| {
        try testing.expectError(error.Truncated, validateKey(key[0..cut], &people));
        try testing.expectError(error.Truncated, decodeKey(arena_state.allocator(), key[0..cut], &people));
    }
    buf[key.len] = 0;
    try testing.expectError(error.TrailingBytes, validateKey(buf[0 .. key.len + 1], &people));

    // A float column holding the bit pattern of -0.0 (never produced by encodeF64).
    const floats = [_]Column{.{ .type = .float }};
    const minus_zero = [_]u8{ keycodec.tag_value, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    try testing.expectError(error.NotCanonical, validateKey(&minus_zero, &floats));
}

test "allocation failure: encodeKeyAlloc and decodeKey leak nothing" {
    const row = [_]Value{ .{ .text = "a name long enough to matter" }, .null, .{ .int = 2 } };
    try testing.expectError(error.OutOfMemory, encodeKeyAlloc(testing.failing_allocator, &row, &people));

    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator, r: []const Value) !void {
            const key = try encodeKeyAlloc(gpa, r, &people);
            defer gpa.free(key);
            // decodeKey is written for an arena: on failure it returns without
            // freeing, and the arena's deinit releases the partial row.
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const back = try decodeKey(arena_state.allocator(), key, &people);
            try testing.expectEqual(.eq, compareRows(r, back, &people));
        }
    }.run, .{&row});
}

test "FixedBufferAllocator: keys share one buffer until it is full" {
    var space: [48]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&space);
    const row = [_]Value{ .{ .text = "Bo" }, .{ .int = 300 }, .{ .int = 5 } }; // 22-byte key
    const k1 = try encodeKeyAlloc(fba.allocator(), &row, &people);
    const k2 = try encodeKeyAlloc(fba.allocator(), &row, &people);
    try testing.expectEqualSlices(u8, k1, k2);
    try testing.expectEqual(44, fba.end_index); // u8 needs no alignment padding
    // The third key does not fit: OutOfMemory, and nothing was claimed.
    try testing.expectError(error.OutOfMemory, encodeKeyAlloc(fba.allocator(), &row, &people));
    try testing.expectEqual(44, fba.end_index);
    fba.reset(); // frees both keys at once
    _ = try encodeKeyAlloc(fba.allocator(), &row, &people);
}

test "BufferFirstAllocator: short keys on the stack, long keys on the heap" {
    var stack_buf: [32]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&stack_buf, testing.allocator);
    const a = bfa.allocator();

    const short = [_]Value{ .{ .text = "Bo" }, .{ .int = 300 }, .{ .int = 5 } };
    const k1 = try encodeKeyAlloc(a, &short, &people);
    try testing.expect(bfa.fixed_buffer_allocator.ownsPtr(k1.ptr));
    a.free(k1);

    const long = [_]Value{ .{ .text = "a name that does not fit in thirty-two bytes" }, .{ .int = 300 }, .{ .int = 5 } };
    const k2 = try encodeKeyAlloc(a, &long, &people);
    try testing.expect(!bfa.fixed_buffer_allocator.ownsPtr(k2.ptr));
    a.free(k2); // forgetting this fails the test: testing.allocator reports the leak
}

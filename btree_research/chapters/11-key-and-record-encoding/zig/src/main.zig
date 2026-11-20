//! Chapter 11: key and record encoding. `zig build run` prints the fixed
//! scenario that the README quotes and the visualization embeds.
//!
//! Allocators on show (see README "Allocator notes"):
//!   FixedBufferAllocator   all eight sort keys of section 5 live in one
//!                          256-byte stack buffer
//!   ArenaAllocator         decoded rows (section 6) and the model test
//!   BufferFirstAllocator   one key at a time: stack first, heap on overflow
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

const varint = @import("varint.zig");
const keycodec = @import("keycodec.zig");
const row_mod = @import("row.zig");
const record = @import("record.zig");
const model = @import("model.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;

const Value = row_mod.Value;
const Column = row_mod.Column;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const w = &stdout_writer.interface;
    try run(w, init.gpa);
    try w.flush();
}

// ---- small printing helpers -------------------------------------------------

/// Formats bytes as "61 00 ff" into `buf` and returns the text.
fn hex(buf: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    var n: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i != 0) {
            buf[n] = ' ';
            n += 1;
        }
        buf[n] = digits[b >> 4];
        buf[n + 1] = digits[b & 0xf];
        n += 2;
    }
    return buf[0..n];
}

/// Formats a byte string as a quoted literal, non-printable bytes as \xNN.
fn quoted(buf: []u8, s: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    var n: usize = 0;
    buf[n] = '"';
    n += 1;
    for (s) |c| {
        if (c >= 0x20 and c <= 0x7e) {
            buf[n] = c;
            n += 1;
        } else {
            buf[n..][0..4].* = .{ '\\', 'x', digits[c >> 4], digits[c & 0xf] };
            n += 4;
        }
    }
    buf[n] = '"';
    return buf[0 .. n + 1];
}

/// Decimal text of a signed integer. (A width on `{d}` would add a '+' sign.)
fn dec(buf: []u8, v: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable;
}

fn printValue(w: *Io.Writer, v: Value) Io.Writer.Error!void {
    var buf: [128]u8 = undefined;
    switch (v) {
        .null => try w.writeAll("NULL"),
        .int => |x| try w.print("{d}", .{x}),
        .float => |x| try w.print("f64:0x{x:0>16}", .{@as(u64, @bitCast(x))}),
        .text => |s| try w.writeAll(quoted(&buf, s)),
    }
}

fn printRow(w: *Io.Writer, row: []const Value) Io.Writer.Error!void {
    try w.writeAll("(");
    for (row, 0..) |v, i| {
        if (i != 0) try w.writeAll(", ");
        try printValue(w, v);
    }
    try w.writeAll(")");
}

/// Insertion sort of an index array; `ctx.compare(i, j)` orders two items.
/// Hand-written so that Zig and Rust perform exactly the same comparisons
/// and the printed counts match (library sorts differ between languages).
fn insertionSort(order: []usize, ctx: anytype) !void {
    for (1..order.len) |i| {
        var j = i;
        while (j > 0 and (try ctx.compare(order[j - 1], order[j])) == .gt) : (j -= 1) {
            std.mem.swap(usize, &order[j - 1], &order[j]);
        }
    }
}

/// memcmp that counts how many byte positions it looked at.
fn compareBytesCounted(a: []const u8, b: []const u8, examined: *u64) Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        examined.* += 1;
        if (x != y) return std.math.order(x, y);
    }
    return std.math.order(a.len, b.len);
}

// ---- the fixed scenario -------------------------------------------------------

/// (name ASC, score DESC NULLS LAST, id ASC)
const people_schema = [_]Column{
    .{ .type = .text },
    .{ .type = .int, .opts = .{ .desc = true } },
    .{ .type = .int },
};

const people = [8][3]Value{
    .{ .{ .text = "Anna" }, .{ .int = 7 }, .{ .int = 1 } },
    .{ .{ .text = "Ann" }, .{ .int = 7 }, .{ .int = 2 } },
    .{ .{ .text = "Ann" }, .{ .int = -2 }, .{ .int = 3 } },
    .{ .{ .text = "Ann" }, .null, .{ .int = 4 } },
    .{ .{ .text = "Bo" }, .{ .int = 300 }, .{ .int = 5 } },
    .{ .{ .text = "Bo" }, .{ .int = 300 }, .{ .int = 6 } },
    .{ .{ .text = "" }, .{ .int = 0 }, .{ .int = 7 } },
    .{ .{ .text = "Anna" }, .{ .int = 256 }, .{ .int = 8 } },
};

pub fn run(w: *Io.Writer, gpa: Allocator) !void {
    try sectionVarints(w);
    try sectionIntegers(w);
    try sectionFloats(w);
    try sectionStrings(w);
    try sectionComposite(w, gpa);
    try sectionRecord(w, gpa);
    try sectionAllocators(w, gpa);
    try sectionProperty(w, gpa);
}

fn sectionVarints(w: *Io.Writer) !void {
    try w.writeAll("== 1. varints: small numbers, few bytes ==\n");
    try w.print("{s:<21}{s:<31}{s}\n", .{ "value", "leb128", "sqlite" });
    const values = [_]u64{ 0, 1, 127, 128, 300, 16383, 16384, 1 << 32, std.math.maxInt(u64) };
    var a: [varint.max_len]u8 = undefined;
    var b: [varint.sqlite_max_len]u8 = undefined;
    var ha: [32]u8 = undefined;
    var hb: [32]u8 = undefined;
    for (values) |v| {
        const na = try varint.encode(&a, v);
        const nb = try varint.sqliteEncode(&b, v);
        try w.print("{d:<21}{s:<31}{s}\n", .{ v, hex(&ha, a[0..na]), hex(&hb, b[0..nb]) });
    }
    try w.writeAll("zigzag:");
    for ([_]i64{ 0, -1, 1, -2, 2, -64, 64 }) |v| {
        try w.print(" {d}->{d}", .{ v, varint.zigzag(v) });
    }
    try w.writeAll("\n");
    const na = try varint.encode(&a, 129);
    var c: [varint.max_len]u8 = undefined;
    const nc = try varint.encode(&c, 256);
    try w.print("as bytes: leb128(129) = {s} {s} leb128(256) = {s}, but 129 < 256: varints are not sort keys\n\n", .{
        hex(&ha, a[0..na]),
        if (std.mem.order(u8, a[0..na], c[0..nc]) == .gt) ">" else "<=",
        hex(&hb, c[0..nc]),
    });
}

fn sectionIntegers(w: *Io.Writer) !void {
    try w.writeAll("== 2. integers as keys ==\n");
    const values = [_]i64{ -2, -1, 0, 1, 256 };
    try w.writeAll("i64 values -2 -1 0 1 256, sorted by comparing the bytes of each encoding:\n");
    const Encoding = enum { little_endian, big_endian, big_endian_sign_flip };
    const labels = [_][]const u8{ "little-endian", "big-endian", "big-endian + sign flip" };
    for ([_]Encoding{ .little_endian, .big_endian, .big_endian_sign_flip }, labels) |encoding, label| {
        var enc: [values.len][8]u8 = undefined;
        for (values, &enc) |v, *e| switch (encoding) {
            .little_endian => std.mem.writeInt(i64, e, v, .little),
            .big_endian => std.mem.writeInt(i64, e, v, .big),
            .big_endian_sign_flip => e.* = keycodec.encodeI64(v),
        };
        var order = [_]usize{ 0, 1, 2, 3, 4 };
        const Ctx = struct {
            enc: *const [values.len][8]u8,
            fn compare(self: @This(), i: usize, j: usize) !Order {
                return std.mem.order(u8, &self.enc[i], &self.enc[j]);
            }
        };
        try insertionSort(&order, Ctx{ .enc = &enc });
        try w.print("  {s:<23}:", .{label});
        var sorted = true;
        for (order, 0..) |idx, pos| {
            try w.print(" {d}", .{values[idx]});
            if (idx != pos) sorted = false;
        }
        try w.print("  {s}\n", .{if (sorted) "(correct)" else "(WRONG)"});
    }
    var h: [32]u8 = undefined;
    for (values) |v| {
        var d: [24]u8 = undefined;
        try w.print("  {s:>4} -> {s}\n", .{ dec(&d, v), hex(&h, &keycodec.encodeI64(v)) });
    }
    try w.writeAll("\n");
}

fn sectionFloats(w: *Io.Writer) !void {
    try w.writeAll("== 3. floats as keys ==\n");
    const inf = std.math.inf(f64);
    const values = [_]f64{ -inf, -1.5, -0.0, 0.0, 1.5, inf, std.math.nan(f64) };
    const labels = [_][]const u8{ "-inf", "-1.5", "-0.0", "0.0", "1.5", "+inf", "NaN" };
    var h: [32]u8 = undefined;
    var prev: ?[8]u8 = null;
    for (values, labels) |v, label| {
        const e = keycodec.encodeF64(v);
        // Relation to the previous line: the list is in logical order, so
        // every key must be >= the one before it.
        const rel: []const u8 = if (prev) |p| switch (std.mem.order(u8, &p, &e)) {
            .lt => "  (> previous)",
            .eq => "  (= previous)",
            .gt => "  (< previous: BUG)",
        } else "";
        try w.print("  {s:>4} -> {s}{s}\n", .{ label, hex(&h, &e), rel });
        prev = e;
    }
    try w.writeAll("\n");
}

fn sectionStrings(w: *Io.Writer) !void {
    try w.writeAll("== 4. strings as keys ==\n");
    const values = [_][]const u8{ "", "a", "a\x00", "a\x01", "a\x02", "ab", "b" };
    var q: [64]u8 = undefined;
    var h: [64]u8 = undefined;
    var e: [16]u8 = undefined;
    for (values) |s| {
        const n = try keycodec.encodeBytes(&e, s);
        try w.print("  {s:<8} -> {s}\n", .{ quoted(&q, s), hex(&h, e[0..n]) });
    }
    // Why the terminator exists: two different composite values.
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var k1: keycodec.KeyWriter = .init(&b1);
    var k2: keycodec.KeyWriter = .init(&b2);
    try k1.putBytes("a", .{});
    try k1.putBytes("b", .{});
    try k2.putBytes("ab", .{});
    try k2.putBytes("", .{});
    var h2: [64]u8 = undefined;
    try w.writeAll("  raw concatenation: (\"a\",\"b\") and (\"ab\",\"\") are both 61 62\n");
    try w.print("  as key columns   : (\"a\",\"b\") = {s}   (\"ab\",\"\") = {s}\n\n", .{ hex(&h, k1.written()), hex(&h2, k2.written()) });
}

fn sectionComposite(w: *Io.Writer, gpa: Allocator) !void {
    _ = gpa; // this section deliberately does not touch the heap
    try w.writeAll("== 5. composite keys: (name ASC, score DESC NULLS LAST, id ASC) ==\n");

    // Arrival order of the rows: a seeded shuffle of 0..7.
    var shuffled = [_]u64{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var rng = SplitMix64.init(11);
    rng.shuffle(&shuffled);
    try w.writeAll("arrival order (ids):");
    for (shuffled) |i| try w.print(" {d}", .{people[@intCast(i)][2].int});
    try w.writeAll("\n");

    // All keys and all records are bump-allocated from two stack buffers.
    var key_space: [256]u8 = undefined;
    var key_fba: std.heap.FixedBufferAllocator = .init(&key_space);
    var rec_space: [128]u8 = undefined;
    var rec_fba: std.heap.FixedBufferAllocator = .init(&rec_space);
    var keys: [8][]const u8 = undefined;
    var recs: [8][]const u8 = undefined;
    for (shuffled, 0..) |src, i| {
        const row = &people[@intCast(src)];
        keys[i] = try row_mod.encodeKeyAlloc(key_fba.allocator(), row, &people_schema);
        const rec_buf = try rec_fba.allocator().alloc(u8, record.recordLen(row));
        recs[i] = try record.encodeRecord(rec_buf, row);
    }

    // (a) sort by comparing key bytes; the sort knows nothing about columns.
    var by_bytes = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const BytesCtx = struct {
        keys: []const []const u8,
        comparisons: u64 = 0,
        bytes_examined: u64 = 0,
        fn compare(self: *@This(), i: usize, j: usize) !Order {
            self.comparisons += 1;
            return compareBytesCounted(self.keys[i], self.keys[j], &self.bytes_examined);
        }
    };
    var bytes_ctx: BytesCtx = .{ .keys = &keys };
    try insertionSort(&by_bytes, &bytes_ctx);

    // (b) sort the records with the schema-aware comparator.
    var by_comparator = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const RecCtx = struct {
        recs: []const []const u8,
        stats: record.CompareStats = .{},
        fn compare(self: *@This(), i: usize, j: usize) !Order {
            return record.compareRecords(self.recs[i], self.recs[j], &people_schema, &self.stats);
        }
    };
    var rec_ctx: RecCtx = .{ .recs = &recs };
    try insertionSort(&by_comparator, &rec_ctx);

    try w.print("sorted by key bytes ({d} comparisons, {d} byte positions examined):\n", .{ bytes_ctx.comparisons, bytes_ctx.bytes_examined });
    var q: [32]u8 = undefined;
    var h: [128]u8 = undefined;
    for (by_bytes) |i| {
        const row = &people[@intCast(shuffled[i])];
        try w.print("  id {d}  {s:<6} ", .{ row[2].int, quoted(&q, row[0].text) });
        var d: [24]u8 = undefined;
        try w.print("{s:>4}", .{if (row[1] == .int) dec(&d, row[1].int) else "NULL"});
        try w.print("  {s}\n", .{hex(&h, keys[i])});
    }
    try w.print("sorted by record comparator ({d} comparisons, {d} columns decoded):\n ", .{ rec_ctx.stats.calls, rec_ctx.stats.columns_decoded });
    for (by_comparator) |i| try w.print(" {d}", .{people[@intCast(shuffled[i])][2].int});
    try w.print("\nsame order: {s}\n", .{if (std.mem.eql(usize, &by_bytes, &by_comparator)) "yes" else "NO"});
    try w.print("space: 8 keys = {d} bytes of a {d}-byte fixed buffer, 8 records = {d} bytes\n\n", .{ key_fba.end_index, key_space.len, rec_fba.end_index });
}

fn sectionRecord(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("== 6. one row, two encodings ==\n");
    const row = &people[0];
    var rec_buf: [32]u8 = undefined;
    var key_buf: [32]u8 = undefined;
    const rec = try record.encodeRecord(&rec_buf, row);
    const key = try row_mod.encodeKey(&key_buf, row, &people_schema);
    var h: [128]u8 = undefined;
    try w.writeAll("row    ");
    try printRow(w, row);
    try w.print("\nrecord {s}  ({d} bytes)\n", .{ hex(&h, rec), rec.len });
    try w.print("key    {s}  ({d} bytes)\n", .{ hex(&h, key), key.len });

    // Decoded rows live in an arena: one deinit frees the value arrays and
    // every text copy, however many rows were decoded.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try w.writeAll("record -> ");
    try printRow(w, try record.decodeRecord(arena, rec));
    try w.writeAll("   (self-describing)\nkey    -> ");
    try printRow(w, try row_mod.decodeKey(arena, key, &people_schema));
    try w.writeAll("   (needs the schema)\n\n");
}

fn sectionAllocators(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("== 7. where the key bytes live ==\n");
    const rows = [_][3]Value{
        people[4],
        .{ .{ .text = "Bartholomew-Maximilian" }, .null, .{ .int = 9 } },
    };
    var q: [64]u8 = undefined;
    for (rows) |row| {
        // A fresh 32-byte stack buffer per key; the heap is only the fallback.
        var stack_buf: [32]u8 = undefined;
        var bfa: std.heap.BufferFirstAllocator = .init(&stack_buf, gpa);
        const a = bfa.allocator();
        const key = try row_mod.encodeKeyAlloc(a, &row, &people_schema);
        defer a.free(key);
        const on_stack = bfa.fixed_buffer_allocator.ownsPtr(key.ptr);
        try w.print("  key for {s:<24} {d:>2} bytes -> {s}\n", .{
            quoted(&q, row[0].text),
            key.len,
            if (on_stack) "32-byte stack buffer" else "heap fallback",
        });
    }
    try w.writeAll("\n");
}

fn sectionProperty(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("== 8. the property, checked on random rows ==\n");
    const seed = 11;
    const pairs = 2000;
    const result = model.checkPairs(gpa, seed, pairs);
    if (result) |c| {
        try w.print("seed {d}, {d} pairs: {d} less, {d} equal, {d} greater\n", .{ seed, pairs, c.lt, c.eq, c.gt });
        try w.writeAll("byte order of keys == comparator order of records == logical order: yes\n");
    } else |err| switch (err) {
        error.Mismatch => try w.writeAll("MISMATCH\n"),
        error.OutOfMemory => |e| return e,
    }
}

// ---- tests -----------------------------------------------------------------

test {
    // Reach the tests of every file from the test root.
    _ = varint;
    _ = keycodec;
    _ = row_mod;
    _ = record;
    _ = model;
    _ = @import("prng.zig");
}

test "run prints exactly expected_output.txt" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(&out.writer, std.testing.allocator);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}

test "the people table sorts as the README says" {
    // Logical order by id: 7, 2, 3, 4, 8, 1, 5, 6.
    const expected = [_]i64{ 7, 2, 3, 4, 8, 1, 5, 6 };
    var order = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const Ctx = struct {
        fn compare(_: @This(), i: usize, j: usize) !Order {
            return row_mod.compareRows(&people[i], &people[j], &people_schema);
        }
    };
    try insertionSort(&order, Ctx{});
    for (order, expected) |i, id| try std.testing.expectEqual(id, people[i][2].int);
}

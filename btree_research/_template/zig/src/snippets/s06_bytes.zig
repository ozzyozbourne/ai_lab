//! Section 6: slices and bytes for page-oriented code.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;

pub const page_size = 4096;

test "readInt / writeInt take a pointer to a fixed-size array + endianness" {
    var page: [page_size]u8 = @splat(0);

    // `page[off..][0..4]` gives *[4]u8 (comptime-known length), which is what the API wants.
    std.mem.writeInt(u32, page[0..4], 0xDEADBEEF, .little);
    std.mem.writeInt(u16, page[4..][0..2], 513, .big);
    std.mem.writeInt(u64, page[8..16], 1 << 40, .little);

    try testing.expectEqual(0xDEADBEEF, std.mem.readInt(u32, page[0..4], .little));
    try testing.expectEqual(513, std.mem.readInt(u16, page[4..6], .big));
    try testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE, 0xAD, 0xDE }, page[0..4]);

    // Runtime offset: slice by offset, then by comptime length.
    var off: usize = 8;
    off += 0;
    try testing.expectEqual(1 << 40, std.mem.readInt(u64, page[off..][0..8], .little));

    // Endianness enum: std.lang.Endian (.little / .big). `std.builtin` is a deprecated alias of `std.lang`.
    const native: std.lang.Endian = builtin.cpu.arch.endian();
    try testing.expectEqual(0xDEADBEEF, std.mem.readInt(u32, page[0..4], .little));
    try testing.expectEqual(std.mem.nativeToLittle(u32, 7), if (native == .little) 7 else @byteSwap(@as(u32, 7)));
    // Variable-width helpers:
    try testing.expectEqual(0xADBEEF, std.mem.readVarInt(u32, page[0..3], .little));
}

// extern struct: C layout, fields in declaration order, natural alignment + padding.
// This is the type to use for on-disk headers. Make padding explicit and assert the size.
const PageHeader = extern struct {
    magic: u32,
    kind: u8,
    flags: u8,
    key_count: u16,
    right_sibling: u64,
    lsn: u64,

    comptime {
        assert(@sizeOf(PageHeader) == 24);
        assert(@alignOf(PageHeader) == 8);
        assert(@offsetOf(PageHeader, "kind") == 4);
        assert(@offsetOf(PageHeader, "key_count") == 6);
        assert(@offsetOf(PageHeader, "right_sibling") == 8);
    }
};

// `extern struct` with align(1) fields: no padding at all (unaligned on-disk records).
const Slot = extern struct {
    offset: u16 align(1),
    len: u16 align(1),
    child: u64 align(1),

    comptime {
        assert(@sizeOf(Slot) == 12);
        assert(@alignOf(Slot) == 1);
    }
};

// packed struct: a bag of bits backed by ONE integer. Field order = LSB first.
// Good for flag words; NOT a byte-layout tool (endianness of the backing int applies).
const Flags = packed struct(u8) {
    is_leaf: bool,
    is_root: bool,
    dirty: bool,
    _reserved: u5 = 0,
};

test "packed struct <-> integer: @backingInt / @fromBackingInt (0.17) or @bitCast" {
    const f: Flags = .{ .is_leaf = true, .is_root = false, .dirty = true };
    try testing.expectEqual(0b101, @backingInt(f));
    try testing.expectEqual(0b101, @as(u8, @bitCast(f)));
    const g: Flags = @fromBackingInt(@as(u8, 0b010));
    try testing.expect(g.is_root and !g.is_leaf);
    try testing.expectEqual(1, @sizeOf(Flags));
    try testing.expectEqual(8, @bitSizeOf(Flags));
    try testing.expectEqual(2, @bitOffsetOf(Flags, "dirty"));
}

test "view a page as a header: @ptrCast + @alignCast" {
    // The buffer must really be aligned for the target type; declare it so.
    var page: [page_size]u8 align(page_size) = @splat(0);

    // *align(4096) [4096]u8 -> *PageHeader: alignment is sufficient, only @ptrCast needed.
    const hdr: *PageHeader = @ptrCast(&page);
    hdr.* = .{ .magic = 0xB7EE, .kind = 1, .flags = 0, .key_count = 3, .right_sibling = 9, .lsn = 0 };
    try testing.expectEqual(3, std.mem.readInt(u16, page[6..8], builtin.cpu.arch.endian()));

    // From a plain []u8 (alignment 1) you must add @alignCast (safety-checked at runtime in Debug).
    const bytes: []u8 = &page;
    const hdr2: *PageHeader = @ptrCast(@alignCast(bytes.ptr));
    try testing.expectEqual(9, hdr2.right_sibling);
    // Both casts take the result type from the destination; with no destination use @as:
    try testing.expectEqual(0xB7EE, @as(*const PageHeader, @ptrCast(@alignCast(bytes.ptr))).magic);

    // Unaligned access without @alignCast: point at an align(1) type instead.
    const slot: *align(1) Slot = @ptrCast(bytes[100..][0..@sizeOf(Slot)]);
    slot.* = .{ .offset = 4000, .len = 96, .child = 77 };
    const unaligned_u64: *align(1) u64 = @ptrCast(bytes[101..][0..8]);
    unaligned_u64.* = 5;

    // Slot array region after the header (slice of structs over bytes):
    const slots: []align(1) Slot = std.mem.bytesAsSlice(Slot, bytes[@sizeOf(PageHeader)..][0 .. 3 * @sizeOf(Slot)]);
    try testing.expectEqual(3, slots.len);
    slots[2] = .{ .offset = 1, .len = 2, .child = 3 };
}

test "std.mem byte reinterpretation helpers" {
    var hdr: PageHeader = .{ .magic = 1, .kind = 2, .flags = 3, .key_count = 4, .right_sibling = 5, .lsn = 6 };

    const as_bytes: *[@sizeOf(PageHeader)]u8 = std.mem.asBytes(&hdr); // view, no copy
    try testing.expectEqual(2, as_bytes[4]);
    const copy: [@sizeOf(PageHeader)]u8 = std.mem.toBytes(hdr); // by value
    const back: PageHeader = std.mem.bytesToValue(PageHeader, &copy); // copy out, any alignment
    try testing.expectEqual(5, back.right_sibling);
    const view: *align(1) const PageHeader = std.mem.bytesAsValue(PageHeader, &copy); // view
    try testing.expectEqual(6, view.lsn);

    var keys = [_]u32{ 1, 2, 3 };
    const key_bytes: []u8 = std.mem.sliceAsBytes(keys[0..]); // []T -> []u8
    try testing.expectEqual(12, key_bytes.len);
    const keys_again: []u32 = @alignCast(std.mem.bytesAsSlice(u32, key_bytes)); // []u8 -> []align(1) T
    try testing.expectEqual(3, keys_again[2]);

    // Zero-initialise (extern structs / arrays):
    const zeroed: PageHeader = std.mem.zeroes(PageHeader);
    try testing.expectEqual(0, zeroed.magic);
    var buf: [16]u8 = undefined;
    @memset(&buf, 0);
    const z: [16]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &z, &buf);
}

test "copying: @memcpy (no overlap), @memmove (overlap ok), copyForwards/copyBackwards" {
    var a = [_]u8{ 1, 2, 3, 4, 5, 0, 0 };

    // @memcpy: dest and source must have equal lengths and must NOT overlap (checked in Debug).
    var b: [3]u8 = undefined;
    @memcpy(&b, a[0..3]);
    @memcpy(b[0..2], a[3..5]);

    // @memmove: overlapping regions allowed. Shift right by one to open a gap at index 1:
    @memmove(a[2..6], a[1..5]);
    a[1] = 99;
    try testing.expectEqualSlices(u8, &.{ 1, 99, 2, 3, 4, 5, 0 }, &a);

    // Shift left to delete index 1:
    @memmove(a[1..5], a[2..6]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, a[0..5]);

    // Library equivalents (dest.len >= source.len; direction named after iteration order):
    std.mem.copyBackwards(u8, a[1..6], a[0..5]); // shift right: copy from the end
    std.mem.copyForwards(u8, a[0..5], a[1..6]); // shift left: copy from the start
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, a[0..5]);
}

test "comparing byte strings and integers" {
    try testing.expectEqual(std.math.Order.lt, std.mem.order(u8, "abc", "abd")); // lexicographic
    try testing.expectEqual(.lt, std.mem.order(u8, "ab", "abc")); // prefix sorts first
    try testing.expect(std.mem.lessThan(u8, "a", "b"));
    try testing.expect(std.mem.eql(u8, "key", "key"));
    try testing.expect(std.mem.startsWith(u8, "prefix-key", "prefix"));
    try testing.expectEqual(.gt, std.math.order(@as(u64, 9), 3));
    try testing.expectEqual(.eq, std.math.order(2, 2));
    try testing.expectEqual(2, std.mem.findDiff(u8, "abc", "abd").?); // was indexOfDiff (alias remains)
    try testing.expectEqual(1, std.mem.findScalar(u8, "abc", 'b').?); // was indexOfScalar (alias remains)
}

// --- Binary search family -------------------------------------------------
// All four have the same shape in 0.17.1:
//   fn(comptime T: type, items: []const T, context: anytype,
//      comptime compareFn: fn (@TypeOf(context), T) std.math.Order) -> ?usize / usize
// compareFn(context, item) returns the order of the *context (the key searched for)
// relative to the item*: .lt = key is before item, .gt = key is after item.
fn orderU32(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}

test "binarySearch / lowerBound / upperBound / equalRange / partitionPoint" {
    const keys = [_]u32{ 10, 20, 20, 30, 40 };

    try testing.expectEqual(3, std.sort.binarySearch(u32, &keys, @as(u32, 30), orderU32).?);
    try testing.expectEqual(null, std.sort.binarySearch(u32, &keys, @as(u32, 25), orderU32));

    // lowerBound: first index whose item is >= key (insertion point / child index in a leaf)
    try testing.expectEqual(1, std.sort.lowerBound(u32, &keys, @as(u32, 20), orderU32));
    try testing.expectEqual(3, std.sort.lowerBound(u32, &keys, @as(u32, 25), orderU32));
    try testing.expectEqual(5, std.sort.lowerBound(u32, &keys, @as(u32, 99), orderU32));
    // upperBound: first index whose item is > key (child index in an internal node)
    try testing.expectEqual(3, std.sort.upperBound(u32, &keys, @as(u32, 20), orderU32));
    try testing.expectEqual(0, std.sort.upperBound(u32, &keys, @as(u32, 5), orderU32));
    // equalRange: .{ lowerBound, upperBound }
    try testing.expectEqual(.{ 1, 3 }, std.sort.equalRange(u32, &keys, @as(u32, 20), orderU32));

    // partitionPoint: first index where predicate(context, item) is false.
    const S = struct {
        fn lessThan(limit: u32, item: u32) bool {
            return item < limit;
        }
    };
    try testing.expectEqual(3, std.sort.partitionPoint(u32, &keys, @as(u32, 30), S.lessThan));
}

test "binary search over structs / byte-string keys with a context" {
    const Entry = struct { key: []const u8, value: u32 };
    const entries = [_]Entry{
        .{ .key = "apple", .value = 1 },
        .{ .key = "mango", .value = 2 },
        .{ .key = "pear", .value = 3 },
    };
    const S = struct {
        fn cmp(key: []const u8, item: Entry) std.math.Order {
            return std.mem.order(u8, key, item.key);
        }
    };
    const needle: []const u8 = "mango";
    const i = std.sort.binarySearch(Entry, &entries, needle, S.cmp).?;
    try testing.expectEqual(2, entries[i].value);
    try testing.expectEqual(1, std.sort.lowerBound(Entry, &entries, @as([]const u8, "banana"), S.cmp));
}

// Hand-rolled branch-light lower bound: what most B-tree chapters actually want.
pub fn lowerBoundU64(keys: []const u64, key: u64) usize {
    var lo: usize = 0;
    var len = keys.len;
    while (len > 0) {
        const half = len / 2;
        if (keys[lo + half] < key) {
            lo += half + 1;
            len -= half + 1;
        } else {
            len = half;
        }
    }
    return lo;
}

test lowerBoundU64 {
    try testing.expectEqual(2, lowerBoundU64(&.{ 1, 3, 5, 7 }, 5));
    try testing.expectEqual(2, lowerBoundU64(&.{ 1, 3, 5, 7 }, 4));
    try testing.expectEqual(4, lowerBoundU64(&.{ 1, 3, 5, 7 }, 8));
    try testing.expectEqual(0, lowerBoundU64(&.{}, 8));
}

test "sorting" {
    var xs = [_]u32{ 5, 1, 4, 2 };
    std.mem.sort(u32, &xs, {}, std.sort.asc(u32)); // stable; lessThan(context, a, b) bool
    try testing.expectEqualSlices(u32, &.{ 1, 2, 4, 5 }, &xs);
    std.mem.sortUnstable(u32, &xs, {}, std.sort.desc(u32)); // pdqsort
    try testing.expectEqualSlices(u32, &.{ 5, 4, 2, 1 }, &xs);
    try testing.expect(std.sort.isSorted(u32, &xs, {}, std.sort.desc(u32)));

    const Pair = struct { k: u32, v: u8 };
    var ps = [_]Pair{ .{ .k = 2, .v = 'b' }, .{ .k = 1, .v = 'a' } };
    const byKey = struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return a.k < b.k;
        }
    }.lessThan;
    std.mem.sort(Pair, &ps, {}, byKey);
    try testing.expectEqual('a', ps[0].v);
}

test "alignment arithmetic and checksums" {
    try testing.expectEqual(8192, std.mem.alignForward(usize, 4097, 4096));
    try testing.expectEqual(4096, std.mem.alignBackward(usize, 8191, 4096));
    try testing.expect(std.mem.isAligned(8192, 4096));
    try testing.expectEqual(3, std.math.divCeil(usize, 9000, 4096) catch unreachable);
    try testing.expectEqual(12, std.math.log2_int(usize, 4096));

    const crc = std.hash.Crc32.hash("page bytes");
    const wy = std.hash.Wyhash.hash(0, "page bytes");
    try testing.expect(crc != 0 and wy != 0);
}

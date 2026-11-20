//! Regenerates the text of common/golden.txt from the four modules and checks
//! it byte for byte. common/rust/golden_test.rs does the same, so if both
//! pass, Zig and Rust agree. Chapters do NOT copy this file.
const std = @import("std");
const SplitMix64 = @import("prng.zig").SplitMix64;
const ops = @import("ops.zig");
const crc32 = @import("crc32.zig").crc32;
const hexdump = @import("hexdump.zig").hexdump;

/// build.zig makes ../golden.txt importable under the name "golden".
const golden = @embedFile("golden");

pub fn render(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "# Golden vectors for common/. Reproduced exactly by the tests in\n" ++
        "# common/zig/golden_test.zig and common/rust/golden_test.rs. Do not edit by hand.\n");

    for ([_]u64{ 0, 1, 42 }) |seed| {
        try out.print(allocator, "\n[splitmix64 seed={d} first=16]\n", .{seed});
        var rng = SplitMix64.init(seed);
        for (0..16) |_| try out.print(allocator, "0x{x:0>16}\n", .{rng.nextU64()});
    }

    try out.appendSlice(allocator, "\n[below seed=42 n=10 first=16]\n");
    var rng = SplitMix64.init(42);
    for (0..16) |i| try out.print(allocator, "{s}{d}", .{ if (i == 0) "" else " ", rng.below(10) });

    try out.appendSlice(allocator, "\n\n[range seed=42 lo=100 hi=200 first=16]\n");
    rng = SplitMix64.init(42);
    for (0..16) |i| try out.print(allocator, "{s}{d}", .{ if (i == 0) "" else " ", rng.range(100, 200) });

    try out.appendSlice(allocator, "\n\n[chance seed=42 numerator=1 denominator=3 first=16]\n");
    rng = SplitMix64.init(42);
    for (0..16) |i| try out.print(allocator, "{s}{d}", .{ if (i == 0) "" else " ", @intFromBool(rng.chance(1, 3)) });

    try out.appendSlice(allocator, "\n\n[shuffle seed=7 input=0..16]\n");
    var items: [16]u64 = undefined;
    for (&items, 0..) |*item, i| item.* = i;
    rng = SplitMix64.init(7);
    rng.shuffle(&items);
    for (items, 0..) |item, i| try out.print(allocator, "{s}{d}", .{ if (i == 0) "" else " ", item });

    try out.appendSlice(allocator, "\n\n[ops seed=42 count=20 key_space=100 weights=put:3,delete:2,get:2,range:2]\n");
    var stream = ops.OpStream.init(.{ .seed = 42, .count = 20, .key_space = 100, .weights = .{ .put = 3, .delete = 2, .get = 2, .range = 2 } });
    while (stream.next()) |op| switch (op) {
        .put => |p| try out.print(allocator, "put {d} {d}\n", .{ p.key, p.value }),
        .delete => |d| try out.print(allocator, "delete {d}\n", .{d.key}),
        .get => |g| try out.print(allocator, "get {d}\n", .{g.key}),
        .range => |r| try out.print(allocator, "range {d} {d}\n", .{ r.lo, r.hi }),
    };

    try out.appendSlice(allocator, "\n[crc32]\n");
    for ([_][]const u8{ "", "a", "123456789", "The quick brown fox jumps over the lazy dog" }) |text| {
        try out.print(allocator, "0x{x:0>8} \"{s}\"\n", .{ crc32(text), text });
    }
    var page: [4096]u8 = undefined;
    @memset(&page, 0);
    try out.print(allocator, "0x{x:0>8} 4096 zero bytes\n", .{crc32(&page)});
    for (&page, 0..) |*b, i| b.* = @truncate(i);
    try out.print(allocator, "0x{x:0>8} 4096 bytes, byte[i] = i mod 256\n", .{crc32(&page)});

    try out.appendSlice(allocator, "\n[hexdump of \"B-tree page\" followed by bytes 0x00..0x1b]\n");
    var bytes: [39]u8 = undefined;
    @memcpy(bytes[0..11], "B-tree page");
    for (bytes[11..], 0..) |*b, i| b.* = @intCast(i);
    const dump = try hexdump(allocator, &bytes);
    defer allocator.free(dump);
    try out.appendSlice(allocator, dump);

    return out.toOwnedSlice(allocator);
}

test "golden.txt is reproduced exactly" {
    const text = try render(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(golden, text);
}

test "the private generator in ops.zig is SplitMix64" {
    // With only `put` enabled each op draws: kind, key, value. Mirror that.
    var stream = ops.OpStream.init(.{ .seed = 5, .count = 50, .key_space = 1000, .weights = .{ .put = 1, .delete = 0, .get = 0, .range = 0 } });
    var rng = SplitMix64.init(5);
    while (stream.next()) |op| {
        _ = rng.below(1);
        try std.testing.expectEqual(rng.below(1000), op.put.key);
        try std.testing.expectEqual(rng.nextU64(), op.put.value);
    }
}

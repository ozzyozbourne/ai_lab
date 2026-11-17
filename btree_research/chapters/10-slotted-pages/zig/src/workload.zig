//! Turns the u64 keys and values of the shared operation stream (ops.zig)
//! into the variable-length byte strings a slotted page stores. Used by the
//! model test and by part 3 of the demo; the Rust twin produces the same bytes.
const std = @import("std");

pub const max_key_len = 12;
pub const max_value_len = 40;

/// 8 bytes big-endian (so byte order equals numeric order) followed by
/// `key % 5` bytes of 'x' (so cells have different sizes).
pub fn keyBytes(buf: *[max_key_len]u8, key: u64) []const u8 {
    std.mem.writeInt(u64, buf[0..8], key, .big);
    const extra: usize = @intCast(key % 5);
    @memset(buf[8..][0..extra], 'x');
    return buf[0 .. 8 + extra];
}

/// `value % 40` bytes derived from the bits of `value`.
pub fn valueBytes(buf: *[max_value_len]u8, value: u64) []const u8 {
    const len: usize = @intCast(value % max_value_len);
    for (buf[0..len], 0..) |*b, i| {
        const shift: u6 = @intCast(8 * (i % 8));
        b.* = @as(u8, @truncate(value >> shift)) ^ @as(u8, @intCast(i));
    }
    return buf[0..len];
}

test "keyBytes keeps numeric order and varies the length" {
    var a: [max_key_len]u8 = undefined;
    var b: [max_key_len]u8 = undefined;
    var k: u64 = 0;
    while (k < 600) : (k += 1) {
        try std.testing.expectEqual(.lt, std.mem.order(u8, keyBytes(&a, k), keyBytes(&b, k + 1)));
    }
    try std.testing.expectEqual(8, keyBytes(&a, 5).len);
    try std.testing.expectEqual(12, keyBytes(&a, 9).len);
}

test "valueBytes golden" {
    var buf: [max_value_len]u8 = undefined;
    try std.testing.expectEqual(0, valueBytes(&buf, 40).len);
    try std.testing.expectEqualSlices(u8, &.{ 0x2b, 0x01, 0x02 }, valueBytes(&buf, 43));
    try std.testing.expectEqual(39, valueBytes(&buf, 79).len);
}

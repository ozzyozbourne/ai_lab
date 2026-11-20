// Copied from common/zig/crc32.zig; do not edit here
//! CRC-32 (IEEE 802.3: the checksum of zlib, gzip, PNG, Ethernet), by hand.
//!
//! Source of truth: common/zig/crc32.zig (twin: common/rust/crc32.rs).
//! A chapter copies this file and adds as its first line:
//!     // Copied from common/zig/crc32.zig; do not edit here
//!
//! Parameters: reflected (bits processed least-significant first),
//! polynomial 0xEDB88320 (0x04C11DB7 bit-reversed), initial value 0xFFFFFFFF,
//! final XOR 0xFFFFFFFF. Check value: crc32("123456789") == 0xCBF43926.
//! On-disk chapters use it to detect torn or corrupted pages.
const std = @import("std");

/// table[b] = the CRC register after feeding the single byte b into a zero
/// register. Built once by the compiler (`comptime`): 256 entries, 8 shift
/// steps each; nothing is computed at run time.
const table: [256]u32 = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*entry, i| {
        var c: u32 = i;
        for (0..8) |_| {
            // If the low bit is set, shift and "subtract" (XOR) the polynomial.
            c = if (c & 1 != 0) (c >> 1) ^ 0xEDB88320 else c >> 1;
        }
        entry.* = c;
    }
    break :blk t;
};

/// CRC-32 of `bytes` in one call.
pub fn crc32(bytes: []const u8) u32 {
    return crc32Update(0, bytes);
}

/// Continue a checksum: crc32Update(crc32(a), b) == crc32(a ++ b).
/// Start with `crc = 0`. (Same convention as zlib's crc32().)
pub fn crc32Update(crc: u32, bytes: []const u8) u32 {
    var c = ~crc; // undo the final XOR of the previous call (or apply init)
    for (bytes) |byte| {
        // Low 8 bits of the register XOR the next byte select a table entry.
        c = table[@as(u8, @truncate(c)) ^ byte] ^ (c >> 8);
    }
    return ~c; // final XOR
}

test "known vectors" {
    try std.testing.expectEqual(0x00000000, crc32(""));
    try std.testing.expectEqual(0xE8B7BE43, crc32("a"));
    try std.testing.expectEqual(0xCBF43926, crc32("123456789"));
    try std.testing.expectEqual(0x414FA339, crc32("The quick brown fox jumps over the lazy dog"));
}

test "matches std.hash.Crc32 and supports chunked updates" {
    var data: [1000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    for ([_]usize{ 0, 1, 2, 15, 16, 17, 255, 256, 1000 }) |n| {
        try std.testing.expectEqual(std.hash.Crc32.hash(data[0..n]), crc32(data[0..n]));
        const half = n / 2;
        try std.testing.expectEqual(crc32(data[0..n]), crc32Update(crc32(data[0..half]), data[half..n]));
    }
}

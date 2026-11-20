//! Canonical hexdump of a byte slice, for expected-output files.
//!
//! Source of truth: common/zig/hexdump.zig (twin: common/rust/hexdump.rs).
//! A chapter copies this file and adds as its first line:
//!     // Copied from common/zig/hexdump.zig; do not edit here
//!
//! Format (the row layout of `hexdump -C`), 16 bytes per line:
//!
//!   00000000  42 54 72 65 65 00 01 02  03 04 05 06 07 08 09 0a  |BTree...........|
//!   00000010  ff 7e                                             |.~|
//!
//!   - 8 lowercase hex digits of offset, then two spaces
//!   - each byte as two lowercase hex digits + one space; one extra space
//!     after the 8th byte; missing bytes of a short last line are 3 spaces
//!   - one space, then '|' + ASCII + '|' where bytes outside 0x20..0x7e are '.'
//!   - every line ends with '\n'; empty input gives the empty string
//!   - unlike `hexdump -C`: repeated lines are never squeezed into '*', and
//!     there is no trailing total-length line
const std = @import("std");

const digits = "0123456789abcdef";

/// Returns a newly allocated string; the caller frees it with `allocator.free`.
pub fn hexdump(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 16) {
        const line = bytes[offset..@min(offset + 16, bytes.len)];

        // Offset column: 8 hex digits, most significant first.
        var shift: u6 = 32;
        while (shift > 0) {
            shift -= 4;
            try out.append(allocator, digits[(offset >> shift) & 0xF]);
        }
        try out.appendSlice(allocator, "  ");

        // Hex column: always 16 cells wide so the ASCII column lines up.
        for (0..16) |i| {
            if (i < line.len) {
                try out.append(allocator, digits[line[i] >> 4]);
                try out.append(allocator, digits[line[i] & 0xF]);
                try out.append(allocator, ' ');
            } else {
                try out.appendSlice(allocator, "   ");
            }
            if (i == 7) try out.append(allocator, ' ');
        }

        // ASCII column.
        try out.appendSlice(allocator, " |");
        for (line) |b| try out.append(allocator, if (b >= 0x20 and b <= 0x7e) b else '.');
        try out.appendSlice(allocator, "|\n");
    }
    return out.toOwnedSlice(allocator);
}

test "hexdump layout" {
    const allocator = std.testing.allocator;

    const empty = try hexdump(allocator, "");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const bytes = "BTree" ++ [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0xff, 0x7e };
    const text = try hexdump(allocator, bytes);
    defer allocator.free(text);
    try std.testing.expectEqualStrings(
        \\00000000  42 54 72 65 65 00 01 02  03 04 05 06 07 08 09 0a  |BTree...........|
        \\00000010  ff 7e                                             |.~|
        \\
    , text);
}

test "hexdump frees everything when allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const text = try hexdump(allocator, "0123456789abcdefXYZ");
            allocator.free(text);
        }
    }.run, .{});
}

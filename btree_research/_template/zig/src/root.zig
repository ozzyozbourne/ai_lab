//! Library root. `zig build test` compiles this file and every file it
//! references from a `test` block.
const std = @import("std");

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test add {
    try std.testing.expectEqual(10, add(3, 7));
}

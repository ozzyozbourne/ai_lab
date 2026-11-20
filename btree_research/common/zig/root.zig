//! Test root for common/zig. `zig build test` compiles this file; the `test`
//! block below pulls in the tests of every file. Chapters do NOT copy this.
pub const prng = @import("prng.zig");
pub const ops = @import("ops.zig");
pub const crc32 = @import("crc32.zig");
pub const hexdump = @import("hexdump.zig");
pub const golden_test = @import("golden_test.zig");

test {
    _ = prng;
    _ = ops;
    _ = crc32;
    _ = hexdump;
    _ = golden_test;
}

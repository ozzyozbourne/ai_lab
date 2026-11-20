//! Chapter 17 entry point: `zig build run` prints expected_output.txt.
const std = @import("std");
const demo = @import("demo.zig");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const stdout = &file_writer.interface;
    try demo.run(init.gpa, stdout);
    try stdout.flush();
}

test "run prints exactly expected_output.txt" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try demo.run(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}

test {
    // Pull in the tests of every file.
    _ = @import("tree.zig");
    _ = @import("tests.zig");
    _ = @import("prng.zig");
}

//! Chapter 15: redistribution and merge policies. `zig build run` prints the
//! report that is stored in ../expected_output.txt.
const std = @import("std");
const experiments = @import("experiments.zig");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout: *std.Io.Writer = &stdout_file_writer.interface;
    try experiments.writeReport(init.gpa, stdout);
    try stdout.flush();
}

test "the report is exactly expected_output.txt" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try experiments.writeReport(std.testing.allocator, &aw.writer);
    // build.zig exposes ../expected_output.txt under this name.
    try std.testing.expectEqualStrings(@embedFile("expected_output"), aw.written());
}

test {
    // Reach the tests of every file from the test root.
    _ = @import("pages.zig");
    _ = @import("experiments.zig");
    _ = @import("prng.zig");
    _ = @import("ops.zig");
}

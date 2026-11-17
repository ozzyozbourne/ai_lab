//! `zig build run`: prints the fixed scenario of chapter 10 (see demo.zig).
const std = @import("std");
const lib = @import("ch10_slotted_pages");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout: *std.Io.Writer = &stdout_file_writer.interface;
    try lib.demo.run(stdout);
    try stdout.flush();
}

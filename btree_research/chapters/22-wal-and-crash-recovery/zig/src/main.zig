const std = @import("std");
const Io = std.Io;

pub const demo = @import("demo.zig");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try demo.run(stdout, init.gpa);
    try stdout.flush();
}

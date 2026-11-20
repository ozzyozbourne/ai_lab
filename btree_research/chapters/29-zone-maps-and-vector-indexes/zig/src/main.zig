//! `zig build run`: print the chapter's fixed scenario (see root.zig).
const std = @import("std");
const lib = @import("ch29_zone_maps_and_vector_indexes");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout: *std.Io.Writer = &stdout_file_writer.interface;
    // init.gpa is a leak-checking allocator in debug builds: a leak in the
    // scenario is reported when the program exits.
    try lib.runScenario(init.gpa, stdout);
    try stdout.flush();
}

//! Chapter 28 program: prints the fixed scenario (see scenario.zig). The
//! output must equal ../expected_output.txt byte for byte.
const std = @import("std");
const lib = @import("ch28_radix_trees_and_hash_indexes");

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const stdout = &file_writer.interface;
    try lib.scenario.run(init.gpa, stdout);
    try stdout.flush();
}

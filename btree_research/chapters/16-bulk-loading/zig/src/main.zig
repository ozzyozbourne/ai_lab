//! Chapter 16: bulk loading. Prints the fixed scenario of the chapter.
//!
//!   bptree.zig  the compact in-memory B+tree with a page-write counter
//!   bulk.zig    the bottom-up loader (start reading here)
//!   report.zig  the scenario printed below
const std = @import("std");
const Io = std.Io;

pub const bptree = @import("bptree.zig");
pub const bulk = @import("bulk.zig");
pub const report = @import("report.zig");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout: *Io.Writer = &stdout_file_writer.interface;
    try report.write(stdout, init.gpa);
    try stdout.flush();
}

test {
    // Tests in other files only run if the files are referenced from here.
    _ = bptree;
    _ = bulk;
    _ = report;
    _ = @import("prng.zig");
    _ = @import("ops.zig");
}

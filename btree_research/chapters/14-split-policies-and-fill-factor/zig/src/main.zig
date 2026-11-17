//! Chapter 14: split policies and fill factor.
//!
//! `zig build run` prints the report that the README quotes: one split
//! decided by hand under each policy, then four workloads under four
//! policies. The interesting code is in split.zig (the decision) and
//! pages.zig (the page model); report.zig runs the experiment.
const std = @import("std");
const Io = std.Io;
const report = @import("report.zig");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout: *Io.Writer = &stdout_file_writer.interface;

    // init.gpa is the leak-checking allocator in debug builds: pages and the
    // directory live there, and every tree is freed before the next one runs.
    try report.writeReport(init.gpa, stdout);
    try stdout.flush();
}

test {
    // Tests in other files only run when the file is referenced from here.
    _ = @import("prng.zig");
    _ = @import("split.zig");
    _ = @import("pages.zig");
    _ = @import("report.zig");
}

//! Chapter 04: insertion and splitting. `zig build run` prints the fixed
//! scenario (see scenario.zig); `zig build test` runs every test.
const std = @import("std");
const scenario = @import("scenario.zig");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout: *std.Io.Writer = &stdout_file_writer.interface;
    // init.gpa is a leak-checking SafeAllocator in debug builds.
    try scenario.run(init.gpa, stdout);
    try stdout.flush();
}

test {
    // Tests in other files only run if the file is referenced from here.
    _ = @import("base_node.zig");
    _ = @import("base_pool.zig");
    _ = @import("base_search.zig");
    _ = @import("base_insert.zig");
    _ = @import("base_validate.zig");
    _ = @import("base_stats.zig");
    _ = @import("base_btree.zig");
    _ = @import("base_tests_insert.zig");
    _ = @import("topdown.zig");
    _ = @import("tests_topdown.zig");
    _ = @import("tests_alloc.zig");
    _ = @import("measure.zig");
    _ = @import("scenario.zig");
    _ = @import("prng.zig");
    _ = @import("ops.zig");
}

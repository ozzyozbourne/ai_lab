//! Chapter 05: deletion and rebalancing. `zig build run` prints the fixed
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
    _ = @import("node.zig");
    _ = @import("pool.zig");
    _ = @import("search.zig");
    _ = @import("insert.zig");
    _ = @import("delete.zig");
    _ = @import("validate.zig");
    _ = @import("stats.zig");
    _ = @import("btree.zig");
    _ = @import("scenario.zig");
    _ = @import("tests.zig");
    _ = @import("prng.zig");
    _ = @import("ops.zig");
}

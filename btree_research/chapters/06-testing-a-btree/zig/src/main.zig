//! Chapter 06: testing a B-tree. `zig build run` prints the fixed scenario
//! (see scenario.zig); `zig build test` runs every test.
//!
//!   base_*.zig       the B-tree of chapter 05 (the system under test), with
//!                    coverage points and one-line fault seams
//!   coverage.zig     counters that prove the tests reached the hard branches
//!   fault_alloc.zig  counting + fault-injecting std.mem.Allocator wrapper
//!   fuzz.zig         swarm cases, operation generation, replay against the oracle
//!   minimize.zig     shrink a failing sequence to a short reproducer
//!   scenario.zig     what `zig build run` prints
//!   tests.zig        the tests built from the pieces above
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
    _ = @import("base_delete.zig");
    _ = @import("base_validate.zig");
    _ = @import("base_stats.zig");
    _ = @import("base_btree.zig");
    _ = @import("coverage.zig");
    _ = @import("fault_alloc.zig");
    _ = @import("fuzz.zig");
    _ = @import("minimize.zig");
    _ = @import("scenario.zig");
    _ = @import("tests.zig");
    _ = @import("prng.zig");
    _ = @import("ops.zig");
}

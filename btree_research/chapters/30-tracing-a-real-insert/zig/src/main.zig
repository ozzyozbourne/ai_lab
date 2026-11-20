//! Chapter 30: tracing a real insert.
//!
//! Copied from chapters/12-disk-backed-bplus-tree (see each file's header):
//!   base_storage.zig, base_pager.zig, base_buffer_pool.zig,
//!   base_slotted_page.zig, disk_btree.zig, prng.zig, workload.zig
//! New in this chapter:
//!   resumable.zig   InsertOp and GetOp: operations that yield instead of waiting
//!   scheduler.zig   SimDisk (reads complete later) and the cooperative Scheduler
//!   tests.zig       byte-identity, every suspension point, re-entry, failures
//!   demo.zig        the fixed scenario printed by `zig build run`
const std = @import("std");
const Io = std.Io;

pub const disk_btree = @import("disk_btree.zig");
pub const resumable = @import("resumable.zig");
pub const scheduler = @import("scheduler.zig");
pub const demo = @import("demo.zig");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try demo.run(stdout, init.gpa);
    try stdout.flush();
}

test {
    // Make `zig build test` reach the tests of every file.
    _ = @import("base_storage.zig");
    _ = @import("base_pager.zig");
    _ = @import("base_buffer_pool.zig");
    _ = @import("base_slotted_page.zig");
    _ = @import("prng.zig");
    _ = @import("workload.zig");
    _ = @import("tests.zig");
    _ = disk_btree;
    _ = resumable;
    _ = scheduler;
    _ = demo;
}

test "run output matches expected_output.txt" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try demo.run(&out.writer, std.testing.allocator);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}

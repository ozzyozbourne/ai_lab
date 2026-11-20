//! Chapter 13: overflow chains and free space.
//!
//!   base_storage.zig       Storage interface, FileStorage, MemStorage   (chapter 09)
//!   base_pager.zig         Pager: a storage as an array of 4096-byte pages (chapter 09)
//!   base_buffer_pool.zig   BufferPool: pinned frames, dirty flags, CLOCK   (chapter 09)
//!   base_slotted_page.zig  SlottedPage: variable-length cells in one page  (chapter 10)
//!   disk_btree.zig         DiskBTree (chapter 12) + overflow chains, delete, free list
//!   workload.zig           seeded keys and values of every size class, the oracle
//!   tests.zig              model tests, fault injection, damaged files
//!   demo.zig               the fixed scenario printed by `zig build run`
const std = @import("std");
const Io = std.Io;

pub const disk_btree = @import("disk_btree.zig");
pub const demo = @import("demo.zig");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    // The demo database is created in the current directory and deleted again.
    try demo.run(stdout, init.gpa, init.io, Io.Dir.cwd());
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
    _ = demo;
}

test "run output matches expected_output.txt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try demo.run(&out.writer, std.testing.allocator, std.testing.io, tmp.dir);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}

//! Chapter 22: write-ahead log and crash recovery.
//!
//!   wal.zig        Wal: log format, commit, checkpoint, recovery      (this chapter)
//!   db.zig         Db: the disk tree behind the log                   (this chapter)
//!   machine.zig    Machine: two SimDisks with one power switch        (this chapter)
//!   adapter.zig    PageFile: chapter 12's storage on chapter 21's     (this chapter)
//!   crash.zig      the crash loop, with and without the log           (this chapter)
//!   demo.zig       the fixed scenario printed by `zig build run`
//!   tests.zig      tests of the log, of recovery and of the crash loop
//!
//!   base_storage / base_pager / base_buffer_pool / base_slotted_page /
//!   base_disk_btree / base_workload      copied from chapter 12
//!   base_page_storage / base_sim_disk / base_checksum   copied from chapter 21
//!   prng / crc32                         copied from common/
const std = @import("std");
const Io = std.Io;

pub const wal = @import("wal.zig");
pub const db = @import("db.zig");
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
    _ = @import("base_disk_btree.zig");
    _ = @import("base_workload.zig");
    _ = @import("base_page_storage.zig");
    _ = @import("base_sim_disk.zig");
    _ = @import("base_checksum.zig");
    _ = @import("prng.zig");
    _ = @import("crc32.zig");
    _ = @import("machine.zig");
    _ = @import("adapter.zig");
    _ = @import("crash.zig");
    _ = @import("tests.zig");
    _ = wal;
    _ = db;
    _ = demo;
}

test "run output matches expected_output.txt" {
    // This is also the test of the "second power cut during recovery" loop
    // and of the cost table: their numbers are part of the expected output.
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try demo.run(&out.writer, std.testing.allocator);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}

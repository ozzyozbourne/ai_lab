//! Chapter 09: pages and the buffer pool.
//!
//!   storage.zig      Storage interface, FileStorage, MemStorage
//!   pager.zig        Pager: a storage seen as an array of 4096-byte pages
//!   buffer_pool.zig  BufferPool: pinned frames, dirty flags, CLOCK eviction
//!   workload.zig     seeded random workload + oracle (model test, demo part 3)
//!   demo.zig         the fixed scenario printed by `zig build run`
const std = @import("std");
const Io = std.Io;

pub const storage = @import("storage.zig");
pub const pager = @import("pager.zig");
pub const buffer_pool = @import("buffer_pool.zig");
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
    _ = storage;
    _ = pager;
    _ = buffer_pool;
    _ = demo;
    _ = @import("workload.zig");
    _ = @import("prng.zig");
}

test "run output matches expected_output.txt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try demo.run(&out.writer, std.testing.allocator, std.testing.io, tmp.dir);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}

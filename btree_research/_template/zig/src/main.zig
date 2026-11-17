//! Executable entry point. In 0.17.1 `main` may take:
//!   pub fn main() !void                                  - nothing provided
//!   pub fn main(init: std.process.Init.Minimal) !void    - only args + environ
//!   pub fn main(init: std.process.Init) !void            - args, environ, gpa, arena, io
//! Return type: void, !void, u8, !u8 or noreturn.
const std = @import("std");
const Io = std.Io;
const lib = @import("btree_template");

pub fn main(init: std.process.Init) !void {
    // General purpose allocator: leak-checking SafeAllocator in Debug/ReleaseSafe,
    // smp_allocator (or c_allocator when linking libc) in ReleaseFast/ReleaseSmall.
    const gpa: std.mem.Allocator = init.gpa;
    // Process-lifetime arena; never freed individually.
    const arena: std.mem.Allocator = init.arena.allocator();
    // The Io implementation (std.Io.Threaded): needed for files, stdout, clocks, mutexes.
    const io: Io = init.io;

    // Command line arguments. args[0] is the program name.
    const args: []const [:0]const u8 = try init.minimal.args.toSlice(arena);
    // Environment variables.
    const home: ?[]const u8 = init.environ_map.get("HOME");

    // Buffered stdout. Nothing is written until flush().
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout: *Io.Writer = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print("btree_template: {d} arg(s), HOME set: {}\n", .{ args.len - 1, home != null });
    for (args[1..], 1..) |arg, i| {
        try stdout.print("  arg[{d}] = {s}\n", .{ i, arg });
    }

    var keys: std.ArrayList(u32) = .empty;
    defer keys.deinit(gpa);
    try keys.appendSlice(gpa, &.{ 30, 10, 20 });
    std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));
    try stdout.print("sorted keys: {any}\n", .{keys.items});
    try stdout.print("lib.add(2, 3) = {d}\n", .{lib.add(2, 3)});

    // stderr, unbuffered, for diagnostics:
    std.debug.print("(stderr) done\n", .{});
    // std.process.exit(1) terminates immediately WITHOUT running defers (flush first).
}

test "main module tests run under `zig build test` too" {
    try std.testing.expectEqual(5, lib.add(2, 3));
}

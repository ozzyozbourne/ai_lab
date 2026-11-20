//! Section 2: printing, formatting, Io.Writer.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

// std.debug.print(fmt, args): stderr, unbuffered, cannot fail, no `try`. See src/main.zig.
// Avoid it inside tests that pass: any stderr output makes `zig build test` echo the
// test command as "failed command: ..." (the step still succeeds).
fn debugDump(keys: []const u32) void {
    std.debug.print("keys={any} n={d}\n", .{ keys, keys.len });
}

test "std.debug.print compiles (not called: keeps test output clean)" {
    _ = &debugDump;
}

test "format specifiers via bufPrint" {
    var buf: [128]u8 = undefined;
    // {d} decimal, {x}/{X} hex, {b} binary, {o} octal, {c} char, {s} string,
    // {e} float scientific, {any} anything, {f} calls the value's format() method,
    // {t} tag name of enum/union / error name, {*} address.
    try testing.expectEqualStrings("42 2a 2A 101010", try std.fmt.bufPrint(&buf, "{d} {x} {X} {b}", .{ 42, 42, 42, 42 }));
    try testing.expectEqualStrings("abc|a", try std.fmt.bufPrint(&buf, "{s}|{c}", .{ "abc", 'a' }));
    // width / fill / alignment: {[fill][align][width]} with < ^ >
    try testing.expectEqualStrings("  42|42  |0042|_42_", try std.fmt.bufPrint(&buf, "{d:4}|{d:<4}|{d:0>4}|{d:_^4}", .{ 42, 42, 42, 42 }));
    try testing.expectEqualStrings("3.14", try std.fmt.bufPrint(&buf, "{d:.2}", .{3.14159}));
    // slices of integers: {any} works; {d} on a slice also prints each element.
    const xs = [_]u8{ 1, 2, 3 };
    try testing.expectEqualStrings("{ 1, 2, 3 }", try std.fmt.bufPrint(&buf, "{any}", .{xs[0..]}));
    try testing.expectEqualStrings("{ 1, 2, 3 }", try std.fmt.bufPrint(&buf, "{any}", .{xs}));
    // bytes as hex string
    try testing.expectEqualStrings("010203", try std.fmt.bufPrint(&buf, "{x}", .{xs[0..]}));
    // optional and error union need {?} / {!} wrappers (or {any})
    const maybe: ?u32 = null;
    try testing.expectEqualStrings("null 7", try std.fmt.bufPrint(&buf, "{?d} {?d}", .{ maybe, @as(?u32, 7) }));
    // enum tag name
    const Color = enum { red, green };
    try testing.expectEqualStrings("green", try std.fmt.bufPrint(&buf, "{t}", .{Color.green}));
    try testing.expectEqualStrings(".green", try std.fmt.bufPrint(&buf, "{any}", .{Color.green}));
    // error name
    try testing.expectEqualStrings("OutOfMemory", try std.fmt.bufPrint(&buf, "{t}", .{error.OutOfMemory}));
}

const Key = struct {
    id: u32,
    // Custom formatting: exact signature in 0.17.1. Invoked by "{f}", NOT by "{}".
    pub fn format(self: Key, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("Key#{d}", .{self.id});
    }
};

test "custom format method uses {f}" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Key#9", try std.fmt.bufPrint(&buf, "{f}", .{Key{ .id = 9 }}));
}

test "allocPrint and Allocator.print" {
    const gpa = testing.allocator;
    const s = try std.fmt.allocPrint(gpa, "page {d}", .{7});
    defer gpa.free(s);
    try testing.expectEqualStrings("page 7", s);
}

test "Io.Writer.fixed: write into a caller buffer" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("{s}={d}", .{ "n", 3 });
    try w.writeAll("!");
    try w.writeByte('\n');
    try testing.expectEqualStrings("n=3!\n", w.buffered());
}

test "Io.Writer.Allocating: growable in-memory writer" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.print("{d}-{d}", .{ 1, 2 });
    try testing.expectEqualStrings("1-2", aw.written());
}

test "buffered stdout writer" {
    const io = testing.io; // in main(): init.io
    var stdout_buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout: *Io.Writer = &file_writer.interface;
    try stdout.print("", .{}); // tests must not write to stdout (it is the test-runner protocol pipe)
    try stdout.flush(); // nothing is written until flush
}

/// Reusable code takes `*Io.Writer` (a concrete type, not anytype).
pub fn dumpKeys(w: *Io.Writer, keys: []const u32) Io.Writer.Error!void {
    for (keys, 0..) |k, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{d}", .{k});
    }
}

test dumpKeys {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try dumpKeys(&w, &.{ 1, 2, 3 });
    try testing.expectEqualStrings("1, 2, 3", w.buffered());
}

test "std.log" {
    std.log.debug("not shown in tests unless testing.log_level is lowered: {d}", .{1});
}

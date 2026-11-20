const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const crash = @import("crash.zig");

pub fn run(w: *Io.Writer, gpa: Allocator) !void {
    const clean = try crash.runWithLog(gpa, crash.small, null, null, .drop, .{});
    try w.print("writes {d} stats {any} rec {any}\n", .{ clean.writes, clean.stats, clean.recovery });
    for ([_]bool{ true, false }) |with_log| {
        const loop = try crash.crashLoop(gpa, crash.small, with_log, .{ .frames = 3 });
        try w.print("with_log={} total {d}\n", .{ with_log, loop.total_writes });
        for (crash.modes, loop.tallies) |m, t| try w.print("  {t}: {any}\n", .{ m, t });
    }
}

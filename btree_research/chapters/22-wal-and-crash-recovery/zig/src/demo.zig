const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const crash = @import("crash.zig");

pub fn run(w: *Io.Writer, gpa: Allocator) !void {
    for ([_]u32{ 30, 34, 36, 38, 40, 44 }) |puts| {
        for ([_]u64{ 22, 1, 2, 3, 4, 5 }) |seed| {
            const wl: crash.Workload = .{ .seed = seed, .puts = puts, .key_space = 60 };
            const clean = try crash.runWithLog(gpa, wl, null, null, .drop, .{});
            try w.print("puts {d} seed {d} writes {d} stats {any}\n", .{ puts, seed, clean.writes, clean.stats });
        }
    }
}

const std = @import("std");
test "placeholder" {}
const fuzz = @import("fuzz.zig");
const scenario = @import("scenario.zig");
test "probe" {
    inline for (.{ 16, 32 }) |M| {
        var t: fuzz.Totals = .{};
        _ = try fuzz.hunt(scenario.Tree(M, .none), std.testing.allocator, 1, 150, .{}, &t);
        std.debug.print("M={d} reached {d} height {d}\n", .{ M, t.coverage.reached(), t.max_height });
        for (t.coverage.hits, 0..) |h, i| if (h == 0) std.debug.print("  {t}\n", .{@as(@import("coverage.zig").Point, @enumFromInt(i))});
    }
    const c = fuzz.swarm(1);
    std.debug.print("{any}\n", .{c});
}

const std = @import("std");
const lib = @import("btree_template");

pub fn main(init: std.process.Init) !void {
    std.debug.print("hello {d}\n", .{lib.add(1, 2)});
    _ = init;
}

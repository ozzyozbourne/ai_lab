//! SECTION C: search, narrated.
//!
//! `explainGet` is `get` from base_search.zig with a print statement at
//! every decision. It returns what `get` returns (a test checks that), and
//! writes one line such as
//!
//!     get 17: [6 10 20] child 2 -> [12 15 17] has it at index 2 -> value 170 (2 nodes read)
//!
//! The number at the end is the cost that matters once nodes are disk pages
//! (chapter 01): one node per level, never more.
const std = @import("std");
const Node = @import("base_node.zig").Node;
const lowerBound = @import("base_search.zig").lowerBound;

pub fn explainGet(comptime M: usize, root: ?*const Node(M), key: u64, w: *std.Io.Writer) std.Io.Writer.Error!?u64 {
    try w.print("get {d}: ", .{key});
    var node = root orelse {
        try w.writeAll("the tree is empty -> absent (0 nodes read)\n");
        return null;
    };
    var nodes_read: usize = 1;
    while (true) : (nodes_read += 1) {
        try writeKeys(node.keySlice(), w);
        // i = number of keys in this node that are smaller than `key`.
        const i = lowerBound(node.keySlice(), key);
        if (i < node.len and node.keys[i] == key) {
            try w.print(" has it at index {d} -> value {d}", .{ i, node.values[i] });
            try writeCost(nodes_read, w);
            return node.values[i];
        }
        if (node.leaf) {
            try w.writeAll(" is a leaf without it -> absent");
            try writeCost(nodes_read, w);
            return null;
        }
        // i keys are smaller, so the key can only be in child i: every key
        // there lies between keys[i - 1] and keys[i].
        try w.print(" child {d} -> ", .{i});
        node = node.children[i].?;
    }
}

fn writeKeys(keys: []const u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (keys, 0..) |key, i| {
        if (i > 0) try w.writeByte(' ');
        try w.print("{d}", .{key});
    }
    try w.writeByte(']');
}

fn writeCost(nodes_read: usize, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print(" ({d} node{s} read)\n", .{ nodes_read, if (nodes_read == 1) "" else "s" });
}

test "explainGet answers like get and reads at most `height` nodes" {
    const tree_mod = @import("tree.zig");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var t: tree_mod.Tree4 = .empty;
    try tree_mod.canonical(&t, arena_state.allocator());

    var buf: [256]u8 = undefined;
    for (0..40) |key| {
        var w: std.Io.Writer = .fixed(&buf);
        try std.testing.expectEqual(t.get(key), try explainGet(4, t.root, key, &w));
    }
    var w: std.Io.Writer = .fixed(&buf);
    _ = try explainGet(4, t.root, 17, &w);
    try std.testing.expectEqualStrings(
        "get 17: [6 10 20] child 2 -> [12 15 17] has it at index 2 -> value 170 (2 nodes read)\n",
        w.buffered(),
    );
    w = .fixed(&buf);
    try std.testing.expectEqual(null, try explainGet(4, null, 17, &w));
    try std.testing.expectEqualStrings("get 17: the tree is empty -> absent (0 nodes read)\n", w.buffered());
}

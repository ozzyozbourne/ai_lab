//! Text rendering of a tree for the demo program and for debugging.
//!
//!     height 2, 7 keys, 5 nodes
//!       level 1: #2[10 20]
//!       level 0: #0(5 6)<10 -> #1(10 12)<20 {incomplete} -> #4(20 25)<30 {no downlink} -> #3(30 40)
//!
//! `#n` is a node handle, `[..]` an internal node (separators), `(..)` a leaf
//! (keys). `<k` is the node's high key (keys in the node are below k); the
//! rightmost node of a level has none. `->` is a right link. `{incomplete}`
//! marks INCOMPLETE_SPLIT; the node after it is tagged `{no downlink}`.
//!
//! Every level is printed by following right links from its leftmost node,
//! because that is the only way to see a node whose downlink is missing.
//! Quiescent only: takes no latches.
const std = @import("std");
const Writer = std.Io.Writer;
const blink = @import("blink.zig");
const BLinkTree = blink.BLinkTree;
const NodeId = blink.NodeId;

pub fn dump(tree: *const BLinkTree, w: *Writer) Writer.Error!void {
    try w.print("height {d}, {d} keys, {d} nodes\n", .{ tree.height, tree.len(), tree.nodeCount() });
    var level = tree.height;
    while (level > 0) {
        level -= 1;
        try w.print("  level {d}:", .{level});
        var id = tree.level_head[level];
        var left_is_incomplete = false;
        while (id != .nil) {
            const p = tree.page(id);
            try w.writeByte(' ');
            try printNode(tree, id, w);
            if (p.high_key) |hk| try w.print("<{d}", .{hk});
            if (p.incomplete_split) try w.writeAll(" {incomplete}");
            if (left_is_incomplete) try w.writeAll(" {no downlink}");
            if (p.right != .nil) try w.writeAll(" ->");
            left_is_incomplete = p.incomplete_split;
            id = p.right;
        }
        try w.writeByte('\n');
    }
}

pub fn printNode(tree: *const BLinkTree, id: NodeId, w: *Writer) Writer.Error!void {
    const p = tree.page(id);
    const open: u8, const close: u8 = if (p.level == 0) .{ '(', ')' } else .{ '[', ']' };
    try w.print("#{d}{c}", .{ id.index(), open });
    for (p.node.keySlice(), 0..) |k, i| {
        if (i != 0) try w.writeByte(' ');
        try w.print("{d}", .{k});
    }
    try w.writeByte(close);
}

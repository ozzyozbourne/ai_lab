//! Text rendering of a tree for the demo program and for debugging.
//!
//!     height 2, 5 keys, 3 nodes
//!       level 0: #2[10]
//!       leaves : #0(5 6) <-> #1(10 12 20)
//!
//! `#n` is a node handle, `[..]` an internal node (separators), `(..)` a leaf
//! (keys; values are omitted). Internal levels are printed by descending from
//! the root; the leaf line is printed by following the `next` links only, so
//! it shows the chain rather than the tree. `|` separates groups of siblings.
const std = @import("std");
const Writer = std.Io.Writer;
const BPlusTree = @import("tree.zig").BPlusTree;
const NodeId = @import("arena.zig").NodeId;

pub fn dump(tree: *const BPlusTree, w: *Writer) Writer.Error!void {
    try w.print("height {d}, {d} keys, {d} nodes\n", .{ tree.height, tree.count, tree.nodes.liveCount() });
    if (tree.root == .nil) return;
    for (1..tree.height) |depth| {
        try w.print("  level {d}:", .{depth - 1});
        var first_group = true;
        try printLevel(tree, tree.root, depth - 1, &first_group, w);
        try w.writeByte('\n');
    }
    try w.writeAll("  leaves :");
    var id = tree.first_leaf;
    while (id != .nil) {
        try w.writeByte(' ');
        try printNode(tree, id, w);
        id = tree.nodes.get(id).kind.leaf.next;
        if (id != .nil) try w.writeAll(" <->");
    }
    try w.writeByte('\n');
}

/// Prints the internal nodes that are `levels_down` levels below `id`.
fn printLevel(tree: *const BPlusTree, id: NodeId, levels_down: usize, first_group: *bool, w: *Writer) Writer.Error!void {
    if (levels_down == 0) {
        try w.writeByte(' ');
        return printNode(tree, id, w);
    }
    if (levels_down == 1) {
        // `id` is a parent of printed nodes: a bar between sibling groups.
        if (!first_group.*) try w.writeAll(" |");
        first_group.* = false;
    }
    for (tree.nodes.get(id).childSlice()) |child| {
        try printLevel(tree, child, levels_down - 1, first_group, w);
    }
}

fn printNode(tree: *const BPlusTree, id: NodeId, w: *Writer) Writer.Error!void {
    const n = tree.nodes.get(id);
    const open: u8, const close: u8 = if (n.isLeaf()) .{ '(', ')' } else .{ '[', ']' };
    try w.print("#{d}{c}", .{ id.index(), open });
    for (n.keySlice(), 0..) |k, i| {
        if (i != 0) try w.writeByte(' ');
        try w.print("{d}", .{k});
    }
    try w.writeByte(close);
}

/// The leaf handles from last to first, following `prev` links only.
pub fn dumpChainBackward(tree: *const BPlusTree, w: *Writer) Writer.Error!void {
    var id = tree.last_leaf;
    while (id != .nil) {
        try w.print(" #{d}", .{id.index()});
        id = tree.nodes.get(id).kind.leaf.prev;
    }
}

//! Text rendering and a leaf-chain walker. QUIESCENT ONLY, like `validate`.
//!
//!     height 2, 5 keys, 3 nodes
//!       level 0: #2[10]
//!       leaves : #0(5 6) -> #1(10 12 20)
//!
//! `#n` is a node handle, `[..]` an internal node (separators), `(..)` a leaf
//! (keys; values are omitted). The leaf line follows the `next` links.
const std = @import("std");
const Writer = std.Io.Writer;
const tree_ = @import("tree.zig");
const Tree = tree_.Tree;
const NodeId = tree_.NodeId;
const Entry = @import("base_node.zig").Entry;

pub fn dump(tree: *const Tree, w: *Writer) Writer.Error!void {
    const height = tree.height();
    try w.print("height {d}, {d} keys, {d} nodes\n", .{ height, tree.len(), tree.table.count() });
    const root = tree.root.load(.acquire);
    for (1..height) |depth| {
        try w.print("  level {d}:", .{depth - 1});
        var first_group = true;
        try printLevel(tree, root, depth - 1, &first_group, w);
        try w.writeByte('\n');
    }
    try w.writeAll("  leaves :");
    var id = firstLeaf(tree);
    while (id != .nil) {
        try w.writeByte(' ');
        try printNode(tree, id, w);
        id = tree.table.node(id).kind.leaf.next;
        if (id != .nil) try w.writeAll(" ->");
    }
    try w.writeByte('\n');
}

/// Prints the internal nodes that are `levels_down` levels below `id`.
fn printLevel(tree: *const Tree, id: NodeId, levels_down: usize, first_group: *bool, w: *Writer) Writer.Error!void {
    if (levels_down == 0) {
        try w.writeByte(' ');
        return printNode(tree, id, w);
    }
    if (levels_down == 1) {
        // `id` is a parent of printed nodes: a bar between sibling groups.
        if (!first_group.*) try w.writeAll(" |");
        first_group.* = false;
    }
    for (tree.table.node(id).childSlice()) |child| {
        try printLevel(tree, child, levels_down - 1, first_group, w);
    }
}

fn printNode(tree: *const Tree, id: NodeId, w: *Writer) Writer.Error!void {
    const n = tree.table.node(id);
    const open: u8, const close: u8 = if (n.isLeaf()) .{ '(', ')' } else .{ '[', ']' };
    try w.print("#{d}{c}", .{ id.index(), open });
    for (n.keySlice(), 0..) |k, i| {
        if (i != 0) try w.writeByte(' ');
        try w.print("{d}", .{k});
    }
    try w.writeByte(close);
}

fn firstLeaf(tree: *const Tree) NodeId {
    var id = tree.root.load(.acquire);
    while (true) switch (tree.table.node(id).kind) {
        .leaf => return id,
        .internal => |*in| id = in.children[0],
    };
}

/// Every entry in key order, by walking the leaf chain. Used to compare the
/// final contents of a tree with the oracle.
pub const Walker = struct {
    tree: *const Tree,
    leaf: NodeId,
    i: usize = 0,

    pub fn init(tree: *const Tree) Walker {
        return .{ .tree = tree, .leaf = firstLeaf(tree) };
    }

    pub fn next(self: *Walker) ?Entry {
        while (self.leaf != .nil) {
            const n = self.tree.table.node(self.leaf);
            if (self.i < n.len) {
                defer self.i += 1;
                return .{ .key = n.keys[self.i], .value = n.kind.leaf.values[self.i] };
            }
            self.leaf = n.kind.leaf.next;
            self.i = 0;
        }
        return null;
    }
};

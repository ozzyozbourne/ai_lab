//! Text rendering of one tree (any `View`) for the demo program and tests.
//!
//!     txn 13: root #11, height 3, 13 keys
//!       level 0: #11[15]
//!       level 1: #8[6 10] #10[20]
//!       leaves : #0(1 3 5) #4(6 7) #9(10 12 13) | #5(15 17) #3(20 25 30)
//!
//! `#n` is a page id, `[..]` an internal node (separators), `(..)` a leaf
//! (keys; values are omitted). `|` separates groups of siblings. Every level
//! is printed by descending from the root: there is no leaf chain to follow.
const std = @import("std");
const Writer = std.Io.Writer;
const base_node = @import("base_node.zig");
const PageId = base_node.PageId;
const View = @import("read.zig").View;

pub fn dump(view: View, txn_id: u64, w: *Writer) Writer.Error!void {
    if (view.root == .nil) return w.print("txn {d}: empty tree\n", .{txn_id});
    try w.print("txn {d}: root #{d}, height {d}, {d} keys\n", .{ txn_id, view.root.index(), view.height, view.count });
    for (0..view.height) |level| {
        if (level + 1 == view.height) try w.writeAll("  leaves :") else try w.print("  level {d}:", .{level});
        var first_group = true;
        try printLevel(view, view.root, level, &first_group, w);
        try w.writeByte('\n');
    }
}

/// Prints the nodes that are `levels_down` levels below `id`.
fn printLevel(view: View, id: PageId, levels_down: usize, first_group: *bool, w: *Writer) Writer.Error!void {
    if (levels_down == 0) {
        try w.writeByte(' ');
        return printNode(view, id, w);
    }
    if (levels_down == 1) {
        // `id` is a parent of printed nodes: a bar between sibling groups.
        if (!first_group.*) try w.writeAll(" |");
        first_group.* = false;
    }
    for (view.node(id).childSlice()) |child| {
        try printLevel(view, child, levels_down - 1, first_group, w);
    }
}

fn printNode(view: View, id: PageId, w: *Writer) Writer.Error!void {
    const n = view.node(id);
    const open: u8, const close: u8 = if (n.isLeaf()) .{ '(', ')' } else .{ '[', ']' };
    try w.print("#{d}{c}", .{ id.index(), open });
    for (n.keySlice(), 0..) |k, i| {
        if (i != 0) try w.writeByte(' ');
        try w.print("{d}", .{k});
    }
    try w.writeByte(close);
}

/// Sets `marks[p]` for every page the view's root reaches. `marks` must have
/// one entry per page of the store (and the view must be a committed one).
pub fn markReachable(view: View, marks: []bool) void {
    if (view.root != .nil) markFrom(view, view.root, marks);
}

fn markFrom(view: View, id: PageId, marks: []bool) void {
    marks[id.index()] = true;
    const n = view.node(id);
    if (n.isLeaf()) return;
    for (n.childSlice()) |child| markFrom(view, child, marks);
}

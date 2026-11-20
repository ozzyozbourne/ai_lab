// Copied from chapters/05-deletion-and-rebalancing/zig/src/stats.zig
// Change for chapter 06: `shape` and `render` tolerate a malformed tree (a
// missing child is skipped / printed as `[?]`, a key count larger than the
// node is clamped and marked `!`) instead of aborting, so a failure report
// can show the tree that failed.
//! SECTION 6b: shape statistics and a text rendering of the tree.
//! This file needs only node.zig.
const std = @import("std");
const Node = @import("base_node.zig").Node;

/// What the tree looks like right now.
pub const Shape = struct {
    /// Number of levels; 0 for an empty tree, 1 for a single leaf.
    height: usize = 0,
    nodes: usize = 0,
    leaves: usize = 0,
    keys: usize = 0,
    /// Key slots available in the existing nodes: nodes * (M - 1).
    capacity: usize = 0,

    /// Average node fill in whole percent (rounded down). A tree whose every
    /// non-root node is at the legal minimum is roughly 50% full; the ratio
    /// says how much of the allocated node space holds data.
    pub fn fillPercent(self: Shape) usize {
        return if (self.capacity == 0) 0 else self.keys * 100 / self.capacity;
    }
};

pub fn shape(comptime M: usize, root: ?*const Node(M)) Shape {
    var s: Shape = .{};
    var node = root;
    while (node) |n| : (node = if (n.leaf) null else n.children[0]) s.height += 1;
    if (root) |r| addNode(M, r, &s);
    return s;
}

fn addNode(comptime M: usize, node: *const Node(M), s: *Shape) void {
    s.nodes += 1;
    s.keys += node.len;
    s.capacity += Node(M).max_keys;
    if (node.leaf) {
        s.leaves += 1;
        return;
    }
    const slots = @min(node.len + 1, node.children.len);
    for (node.children[0..slots]) |child| if (child) |c| addNode(M, c, s);
}

/// One line per level, root first. Nodes are `[k k k]`; ` | ` separates
/// nodes that have different parents:
///
///     [9]
///     [3 6] [12]
///     [1 2] [4 5] [7 8] | [10 11] [13]
///
/// Every line starts with `indent`. An empty tree prints `(empty)`.
pub fn render(comptime M: usize, root: ?*const Node(M), w: *std.Io.Writer, indent: []const u8) std.Io.Writer.Error!void {
    const r = root orelse {
        try w.print("{s}(empty)\n", .{indent});
        return;
    };
    const height = shape(M, root).height;
    for (0..height) |level| {
        try w.writeAll(indent);
        var first = true;
        try renderLevel(M, r, level, w, &first);
        try w.writeByte('\n');
    }
}

/// Print the nodes `remaining` levels below `node`, left to right.
fn renderLevel(comptime M: usize, maybe_node: ?*const Node(M), remaining: usize, w: *std.Io.Writer, first: *bool) std.Io.Writer.Error!void {
    const node = maybe_node orelse return w.writeAll("[?]"); // a missing child
    if (remaining == 0) {
        // Not `keySlice()`: a garbage `len` (NodeOverfull) must not index
        // past the array. Such a node is printed with a `!` after its keys.
        const shown = @min(node.len, node.keys.len);
        try w.writeByte('[');
        for (node.keys[0..shown], 0..) |key, i| {
            if (i > 0) try w.writeByte(' ');
            try w.print("{d}", .{key});
        }
        try w.writeAll(if (shown == node.len) "]" else " !]");
        return;
    }
    if (node.leaf) return; // a leaf above the lowest level: nothing below it
    for (node.children[0..@min(node.len + 1, node.children.len)], 0..) |child, i| {
        if (remaining == 1) {
            // Siblings are separated by a space, families by " | ".
            if (i > 0) try w.writeByte(' ') else if (!first.*) try w.writeAll(" | ");
            first.* = false;
        }
        try renderLevel(M, child, remaining - 1, w, first);
    }
}

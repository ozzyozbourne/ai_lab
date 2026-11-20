//! SECTION F: a 2-3-4 tree is a red-black tree in disguise.
//!
//! A B-tree of order 4 has nodes with 1, 2 or 3 keys. Draw each node as a
//! tiny binary tree: one BLACK node on top, the other keys as RED children.
//!
//!     [b]        [a b]          [a b c]
//!
//!      b           b               b            black
//!                 /               / \
//!                a               a   c          red
//!
//! A red node therefore means "I belong to the same B-tree node as my
//! parent". The subtrees of the B-tree node hang below, in the same
//! left-to-right order. (For two keys the red one could also go to the
//! right; we always put it on the left, the "left-leaning" choice.)
//!
//! A red-black tree is a binary search tree (one key and at most two
//! children per node) with one colour per node, kept balanced by three
//! rules. Each of them follows from a B-tree rule:
//!   * the root is black             (the top of the root's B-tree node)
//!   * a red node has no red child   (a B-tree node has at most 3 keys)
//!   * every path from the root down to a missing child passes the same
//!     number of black nodes         (all B-tree leaves are on one level)
//! `check` verifies all three and the order of the keys, so a broken
//! conversion would be caught.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("base_node.zig").Node(4);

pub const Color = enum { red, black };

pub const RbNode = struct {
    key: u64,
    color: Color,
    left: ?*RbNode = null,
    right: ?*RbNode = null,
};

/// Convert the 2-3-4 tree below `node` into a red-black tree with the same
/// keys. Allocates one RbNode per key from `arena` and never frees: meant
/// for an arena or bump allocator.
pub fn fromTree(arena: Allocator, node: ?*const Node) Allocator.Error!?*RbNode {
    const n = node orelse return null;
    std.debug.assert(n.len >= 1 and n.len <= 3);
    // Converted subtrees, left to right (all null below a leaf).
    var sub: [4]?*RbNode = @splat(null);
    if (!n.leaf) {
        for (0..n.len + 1) |i| sub[i] = try fromTree(arena, n.children[i]);
    }
    const k = n.keys;
    return switch (n.len) {
        1 => try make(arena, k[0], .black, sub[0], sub[1]),
        2 => try make(arena, k[1], .black, try make(arena, k[0], .red, sub[0], sub[1]), sub[2]),
        3 => try make(arena, k[1], .black, try make(arena, k[0], .red, sub[0], sub[1]), try make(arena, k[2], .red, sub[2], sub[3])),
        else => unreachable,
    };
}

fn make(arena: Allocator, key: u64, color: Color, left: ?*RbNode, right: ?*RbNode) Allocator.Error!*RbNode {
    const node = try arena.create(RbNode);
    node.* = .{ .key = key, .color = color, .left = left, .right = right };
    return node;
}

pub const Error = error{ RootIsRed, RedHasRedChild, BlackHeightDiffers, KeysOutOfOrder };

pub const Summary = struct {
    nodes: usize = 0,
    /// Black nodes on every path from the root to a missing child.
    black_height: usize = 0,
    /// Nodes on the shortest / longest such path.
    shortest_path: usize = std.math.maxInt(usize),
    longest_path: usize = 0,
};

/// Check the red-black rules and the search-tree order.
pub fn check(root: ?*const RbNode) Error!Summary {
    var s: Summary = .{};
    const r = root orelse return .{ .shortest_path = 0 };
    if (r.color == .red) return error.RootIsRed;
    s.black_height = try walk(r, null, null, 1, &s);
    return s;
}

/// Returns the number of black nodes from `node` down to a missing child.
fn walk(node: *const RbNode, lo: ?u64, hi: ?u64, level: usize, s: *Summary) Error!usize {
    s.nodes += 1;
    if (lo) |l| if (node.key <= l) return error.KeysOutOfOrder;
    if (hi) |h| if (node.key >= h) return error.KeysOutOfOrder;
    var black: [2]usize = undefined;
    for ([_]?*const RbNode{ node.left, node.right }, 0..) |child, side| {
        if (child) |c| {
            if (node.color == .red and c.color == .red) return error.RedHasRedChild;
            black[side] = try walk(c, if (side == 0) lo else node.key, if (side == 0) node.key else hi, level + 1, s);
        } else {
            black[side] = 0; // a path ends here
            s.shortest_path = @min(s.shortest_path, level);
            s.longest_path = @max(s.longest_path, level);
        }
    }
    if (black[0] != black[1]) return error.BlackHeightDiffers;
    return black[0] + @intFromBool(node.color == .black);
}

/// One line for one 2-3-4 node, e.g. "10 black, red children 6 and 20".
pub fn describe(keys: []const u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (keys.len) {
        1 => try w.print("{d} black", .{keys[0]}),
        2 => try w.print("{d} black, red left child {d}", .{ keys[1], keys[0] }),
        3 => try w.print("{d} black, red children {d} and {d}", .{ keys[1], keys[0], keys[2] }),
        else => unreachable,
    }
}

const testing = std.testing;
const tree_mod = @import("tree.zig");

test "the canonical tree as a red-black tree" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var t: tree_mod.Tree4 = .empty;
    try tree_mod.canonical(&t, arena);
    const rb = (try fromTree(arena, t.root)).?;
    //             10
    //        6r        20r
    //      3    7    15    30
    //    1r 5r     12r 17r 25r
    try testing.expectEqual(10, rb.key);
    try testing.expectEqual(Color.red, rb.left.?.color);
    try testing.expectEqual(6, rb.left.?.key);
    try testing.expectEqual(7, rb.left.?.right.?.key);
    try testing.expectEqual(30, rb.right.?.right.?.key);
    try testing.expectEqual(25, rb.right.?.right.?.left.?.key);
    try testing.expectEqual(null, rb.right.?.right.?.right);
    const s = try check(rb);
    try testing.expectEqual(Summary{ .nodes = 12, .black_height = 2, .shortest_path = 3, .longest_path = 4 }, s);
    try testing.expectEqual(Summary{ .shortest_path = 0 }, try check(null));
}

test "black height equals B-tree height; no path is more than twice as long as another" {
    var keys: [300]u64 = undefined;
    for (&keys, 0..) |*key, i| key.* = i;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (0..keys.len + 1) |n| {
        _ = arena_state.reset(.retain_capacity);
        var t: tree_mod.Tree4 = .empty;
        try t.fromSorted(arena, keys[0..n]);
        const s = try check(try fromTree(arena, t.root));
        try testing.expectEqual(n, s.nodes);
        try testing.expectEqual(t.shape().height, s.black_height);
        try testing.expect(s.longest_path <= 2 * s.shortest_path);
    }
}

test "check rejects trees that break a red-black rule" {
    var a: RbNode = .{ .key = 1, .color = .red };
    var b: RbNode = .{ .key = 2, .color = .red, .left = &a };
    var c: RbNode = .{ .key = 3, .color = .black, .left = &b };
    try testing.expectError(error.RootIsRed, check(&b));
    try testing.expectError(error.RedHasRedChild, check(&c));
    a.color = .black; // 3 -> 2r -> 1: the left path has one more black node
    try testing.expectError(error.BlackHeightDiffers, check(&c));
    a = .{ .key = 9, .color = .red };
    b.color = .black;
    try testing.expectError(error.KeysOutOfOrder, check(&b));
}

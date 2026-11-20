//! SECTION E: trees that are broken on purpose.
//!
//! Each case takes the canonical tree
//!
//!                  [6 10 20]
//!     [1 3 5]  [7]  [12 15 17]  [25 30]
//!
//! and changes ONE thing, so that exactly one invariant is violated.
//! `validate` must name that invariant. There is one case for every member
//! of `validate.Error`.
//!
//! Several of these trees still answer every `get` correctly. That is the
//! reason `validate` exists: a test that only looks at query results cannot
//! see such damage until a later insert or delete trips over it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tree_mod = @import("tree.zig");
const validation = @import("base_validate.zig");

pub const Tree = tree_mod.Tree4;
const NodeT = Tree.NodeT;

pub const Case = struct {
    /// The change, in words.
    what: []const u8,
    /// What `validate` must answer.
    expect: validation.Error,
    apply: *const fn (t: *Tree, gpa: Allocator) Allocator.Error!void,
    /// false: a search could follow a pointer that is not there.
    searchable: bool = true,
};

pub const cases = [_]Case{
    .{ .what = "leaf [12 15 17] reordered to [12 17 15]", .expect = error.KeysOutOfOrder, .apply = swapTwoKeys },
    .{ .what = "leaf [7] holds 11 instead: sorted, but on the wrong side of separator 10", .expect = error.KeyOutsideParentBounds, .apply = keyOnWrongSide },
    .{ .what = "leaf [12 15 17] gets a fourth key, 18", .expect = error.NodeOverfull, .apply = fourthKey },
    .{ .what = "leaf [7] loses its only key", .expect = error.NodeUnderfull, .apply = emptyLeaf },
    .{ .what = "the root's key count is set to 0", .expect = error.EmptyRoot, .apply = emptyRoot },
    .{ .what = "leaf [12 15 17] becomes interior [15] above new leaves [12] and [17]", .expect = error.LeavesAtDifferentDepths, .apply = deeperLeaves },
    .{ .what = "the root's last child pointer is erased", .expect = error.MissingChild, .apply = eraseChild, .searchable = false },
    .{ .what = "leaf [7] gets a child pointer", .expect = error.UnexpectedChild, .apply = childInLeaf },
    .{ .what = "key 5 vanishes from leaf [1 3 5], the tree still claims 12 keys", .expect = error.WrongKeyCount, .apply = loseKey },
    .{ .what = "a sixth node is allocated but nothing points to it", .expect = error.NodeCountMismatch, .apply = orphanNode },
};

fn leafAt(t: *Tree, i: usize) *NodeT {
    return t.root.?.children[i].?;
}

fn swapTwoKeys(t: *Tree, _: Allocator) Allocator.Error!void {
    const n = leafAt(t, 2);
    std.mem.swap(u64, &n.keys[1], &n.keys[2]);
    std.mem.swap(u64, &n.values[1], &n.values[2]);
}

fn keyOnWrongSide(t: *Tree, _: Allocator) Allocator.Error!void {
    const n = leafAt(t, 1);
    n.keys[0] = 11; // must be between the separators 6 and 10
    n.values[0] = tree_mod.valueOf(11);
}

fn fourthKey(t: *Tree, _: Allocator) Allocator.Error!void {
    leafAt(t, 2).insertEntry(3, 18, tree_mod.valueOf(18)); // the array has a spare slot
    t.len += 1; // keep the count honest: only the node size is wrong
}

fn emptyLeaf(t: *Tree, _: Allocator) Allocator.Error!void {
    _ = leafAt(t, 1).removeEntry(0);
    t.len -= 1;
}

fn emptyRoot(t: *Tree, _: Allocator) Allocator.Error!void {
    t.root.?.len = 0;
}

fn deeperLeaves(t: *Tree, gpa: Allocator) Allocator.Error!void {
    // Same 12 keys, still sorted, every node within its size limits: only
    // the depth of two leaves changes.
    const low = try t.leaf(gpa, &.{12});
    const high = try t.leaf(gpa, &.{17});
    t.len -= 2; // 12 and 17 were counted before
    const n = leafAt(t, 2);
    n.leaf = false;
    n.len = 1;
    n.keys[0] = 15;
    n.values[0] = tree_mod.valueOf(15);
    n.children[0] = low;
    n.children[1] = high;
}

fn eraseChild(t: *Tree, _: Allocator) Allocator.Error!void {
    t.root.?.children[3] = null;
}

fn childInLeaf(t: *Tree, _: Allocator) Allocator.Error!void {
    leafAt(t, 1).children[0] = leafAt(t, 0);
}

fn loseKey(t: *Tree, _: Allocator) Allocator.Error!void {
    _ = leafAt(t, 0).removeEntry(2); // t.len is NOT adjusted
}

fn orphanNode(t: *Tree, gpa: Allocator) Allocator.Error!void {
    _ = try t.leaf(gpa, &.{99});
    t.len -= 1; // the key count is right; one node too many exists
}

/// How many of the 12 canonical keys `get` still finds, with the right value.
pub fn keysFound(t: *const Tree) usize {
    var found: usize = 0;
    for (tree_mod.canonical_keys) |key| {
        if (t.get(key) == tree_mod.valueOf(key)) found += 1;
    }
    return found;
}

test "every case breaks exactly the invariant it names" {
    // An arena, because a broken tree cannot be freed by walking it: the
    // walk would follow the very pointers that are wrong.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const found_expected = [cases.len]?usize{ 11, 11, 12, 11, 3, 12, null, 12, 11, 12 };
    for (cases, found_expected) |case, found| {
        _ = arena_state.reset(.retain_capacity);
        var t: Tree = .empty;
        try tree_mod.canonical(&t, arena_state.allocator());
        try t.validate(); // intact before ...
        try case.apply(&t, arena_state.allocator());
        try std.testing.expectError(case.expect, t.validate()); // ... named after
        if (case.searchable) try std.testing.expectEqual(found.?, keysFound(&t));
        try std.testing.expectEqual(case.searchable, found != null);
    }
}

test "the cases cover every error validate can return" {
    const names = @typeInfo(validation.Error).error_set.error_names.?;
    try std.testing.expectEqual(names.len, cases.len);
    for (cases, 0..) |a, i| {
        for (cases[i + 1 ..]) |b| try std.testing.expect(a.expect != b.expect);
    }
}

test "a key on the wrong side of a separator is stored but cannot be found" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var t: Tree = .empty;
    try tree_mod.canonical(&t, arena_state.allocator());
    try keyOnWrongSide(&t, arena_state.allocator());
    try std.testing.expectEqual(11, leafAt(&t, 1).keys[0]); // it is there ...
    try std.testing.expectEqual(null, t.get(11)); // ... but search goes to [12 15 17]
}

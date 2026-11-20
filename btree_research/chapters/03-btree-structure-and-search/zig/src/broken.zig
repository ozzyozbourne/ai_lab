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
//!
//! A broken tree can still be inspected and torn down: `render`, `shape` and
//! `deinit` skip a missing child instead of aborting (a test below runs them
//! on all ten). Only `get` is not safe on case 7.
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
    // the level of two leaves changes.
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
    // An arena: one reset frees a tree whatever state it is in, including
    // the nodes a walk from the root would no longer reach (next test).
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

test "two defects: validate reports the one its walk meets first" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Leaf [7] is visited before leaf [12 15 17], so its defect wins.
    var a: Tree = .empty;
    try tree_mod.canonical(&a, arena);
    try swapTwoKeys(&a, arena);
    try keyOnWrongSide(&a, arena);
    try std.testing.expectError(error.KeyOutsideParentBounds, a.validate());

    // A disordered first leaf and an erased last child pointer. The walk
    // looks at ALL child slots of a node before it descends into the first
    // child, so the root's defect wins although the leaf is further left.
    // (Regression: an older walk descended first and said KeysOutOfOrder
    // here, while the Rust twin said MissingChild.)
    var b: Tree = .empty;
    try tree_mod.canonical(&b, arena);
    std.mem.swap(u64, &leafAt(&b, 0).keys[0], &leafAt(&b, 0).keys[1]);
    try eraseChild(&b, arena);
    try std.testing.expectError(error.MissingChild, b.validate());
}

/// What `render` prints for each broken tree, and how many nodes a walk
/// from the root can no longer reach (so `deinit` cannot free them).
const Inspection = struct { rendered: []const u8, stranded: usize = 0 };
const inspections = [cases.len]Inspection{
    .{ .rendered = "[6 10 20]\n[1 3 5] [7] [12 17 15] [25 30]\n" },
    .{ .rendered = "[6 10 20]\n[1 3 5] [11] [12 15 17] [25 30]\n" },
    .{ .rendered = "[6 10 20]\n[1 3 5] [7] [12 15 17 18] [25 30]\n" },
    .{ .rendered = "[6 10 20]\n[1 3 5] [] [12 15 17] [25 30]\n" },
    // 0 keys means 1 child for a walk: the other three leaves are out of reach.
    .{ .rendered = "[]\n[1 3 5]\n", .stranded = 3 },
    // The height is measured along the leftmost path, so level 3 is not printed.
    .{ .rendered = "[6 10 20]\n[1 3 5] [7] [15] [25 30]\n" },
    .{ .rendered = "[6 10 20]\n[1 3 5] [7] [12 15 17]\n", .stranded = 1 },
    .{ .rendered = "[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]\n" },
    .{ .rendered = "[6 10 20]\n[1 3] [7] [12 15 17] [25 30]\n" },
    .{ .rendered = "[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]\n", .stranded = 1 },
};

/// Build case `i` on `gpa`, then print, measure, validate and walk-free it.
fn inspectAndTearDown(gpa: Allocator, i: usize) !void {
    var t: Tree = .empty;
    try tree_mod.canonical(&t, gpa);
    try cases[i].apply(&t, gpa);
    defer t.deinit(gpa); // must not abort, whatever the damage
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try t.render(&w, "");
    try std.testing.expectEqualStrings(inspections[i].rendered, w.buffered());
    const reachable = t.pool.usage.live() - inspections[i].stranded;
    try std.testing.expectEqual(reachable, t.shape().nodes);
    try std.testing.expectError(cases[i].expect, t.validate());
}

test "every broken tree can be printed, measured, validated and torn down" {
    // Regression: `render` and `shape` unwrapped the erased pointer of case
    // 7, and `deinit` asserted that no node was left, which aborted on
    // cases 5, 7 and 10.
    for (cases, inspections, 0..) |_, inspection, i| {
        // 1. Nodes in an arena, with a counter in between: the walk in
        //    `deinit` frees exactly the nodes it can reach, the arena frees
        //    the stranded ones. testing.allocator sees no leak.
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();
        var counting: std.testing.FailingAllocator = .init(arena_state.allocator(), .{});
        try inspectAndTearDown(counting.allocator(), i);
        try std.testing.expectEqual(inspection.stranded, counting.allocations - counting.deallocations);

        // 2. Seven of the ten are freed completely by the walk alone:
        //    testing.allocator would report a leak or a double free.
        if (inspection.stranded == 0) try inspectAndTearDown(std.testing.allocator, i);
    }
}

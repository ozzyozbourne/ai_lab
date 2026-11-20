//! SECTION B: a tree built by hand.
//!
//! This chapter has no insert and no delete. A tree is assembled bottom-up:
//! make the leaves, then the node above them, and so on up to the root.
//!
//!     var t: Tree4 = .empty;
//!     const a = try t.leaf(gpa, &.{ 5, 10 });
//!     const b = try t.leaf(gpa, &.{ 30, 40 });
//!     t.root = try t.interior(gpa, &.{20}, &.{ a, b });
//!
//! `leaf` and `interior` check NOTHING about the B-tree rules. That is on
//! purpose: the same builder makes valid trees and the broken ones of
//! broken.zig, and `validate` is the only judge.
//!
//! Where do nodes come from? From a node pool (base_pool.zig). With
//! `DirectNodes` every node is one `gpa.create`, so the allocator you pass
//! decides everything:
//!
//!   std.testing.allocator   every node tracked; you must call `deinit`,
//!                           which walks the tree and destroys every node it
//!                           can reach from the root
//!   BumpAllocator (bump.zig) / std.heap.ArenaAllocator
//!                           nodes packed into chunks; do NOT walk the tree,
//!                           just deinit the allocator: one free per chunk
const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("base_node.zig");
const search = @import("base_search.zig");
const validation = @import("base_validate.zig");
const stats = @import("base_stats.zig");
const pool_mod = @import("base_pool.zig");
const height_mod = @import("height.zig");

/// The guide's convention for example data: the value of key k is 10 * k.
/// `*%` wraps around instead of trapping: every u64 is a legal key, also the
/// ones above maxInt(u64) / 10, and the value is only example data.
pub fn valueOf(key: u64) u64 {
    return key *% 10;
}

/// A read-only B-tree of order `M` (at most M children, at most M - 1 keys
/// per node) with nodes from `PoolFn(Node(M))`.
pub fn HandTree(comptime M: usize, comptime PoolFn: fn (type) type) type {
    return struct {
        const Self = @This();
        pub const order = M;
        pub const NodeT = node_mod.Node(M);

        /// null means the tree is empty: an empty tree owns no nodes.
        root: ?*NodeT = null,
        /// Number of keys the tree claims to hold. `leaf` and `interior` add
        /// the keys they are given; `validate` compares with what it finds.
        len: usize = 0,
        pool: PoolFn(NodeT) = .empty,

        pub const empty: Self = .{};

        // ------------------------------------------------------- building

        /// A new leaf holding `keys` (the caller promises nothing about them).
        pub fn leaf(self: *Self, gpa: Allocator, keys: []const u64) Allocator.Error!*NodeT {
            return self.newNode(gpa, true, keys, &.{});
        }

        /// A new interior node: `children[i]` is meant to hold the keys below
        /// `keys[i]`, the last child the keys above the last key.
        pub fn interior(self: *Self, gpa: Allocator, keys: []const u64, children: []const *NodeT) Allocator.Error!*NodeT {
            return self.newNode(gpa, false, keys, children);
        }

        fn newNode(self: *Self, gpa: Allocator, is_leaf: bool, keys: []const u64, children: []const *NodeT) Allocator.Error!*NodeT {
            // Only what the arrays can physically hold is asserted (they have
            // one spare slot each, see base_node.zig). Order, fill and child
            // count are deliberately left to `validate`.
            std.debug.assert(keys.len <= M and children.len <= M + 1);
            const node = try self.pool.create(gpa);
            node.* = .{ .leaf = is_leaf }; // create() returns undefined memory
            for (keys, 0..) |key, i| {
                node.keys[i] = key;
                node.values[i] = valueOf(key);
            }
            node.len = keys.len;
            for (children, 0..) |child, i| node.children[i] = child;
            self.len += keys.len;
            return node;
        }

        /// Build a valid tree of the smallest possible height from keys in
        /// strictly ascending order. The tree must be empty.
        ///
        /// Not an insertion algorithm: it deals the keys out top-down, like
        /// laying out a book index (chapter 16 does this properly, bottom-up
        /// and streaming). It exists so tests can check big trees.
        pub fn fromSorted(self: *Self, gpa: Allocator, sorted: []const u64) Allocator.Error!void {
            std.debug.assert(self.root == null);
            if (sorted.len == 0) return;
            const h = height_mod.minHeight(M, sorted.len);
            self.root = try self.buildSubtree(gpa, sorted, h, true);
        }

        fn buildSubtree(self: *Self, gpa: Allocator, keys: []const u64, h: usize, is_root: bool) Allocator.Error!*NodeT {
            if (h == 1) return self.leaf(gpa, keys);
            // Fewest children such that each child subtree fits into h - 1
            // levels. The root may have 2 children, other nodes at least t.
            const child_capacity = height_mod.maxKeys(M, h - 1);
            var n_children: usize = if (is_root) 2 else (M + 1) / 2;
            while ((keys.len - (n_children - 1) + n_children - 1) / n_children > child_capacity) n_children += 1; // ceil

            // n_children - 1 keys stay here as separators; the others are
            // dealt out evenly, the left children taking the remainder.
            const below = keys.len - (n_children - 1);
            var separators: [M]u64 = undefined;
            var children: [M + 1]*NodeT = undefined;
            var pos: usize = 0;
            for (0..n_children) |i| {
                const take = below / n_children + @intFromBool(i < below % n_children);
                children[i] = try self.buildSubtree(gpa, keys[pos .. pos + take], h - 1, false);
                pos += take;
                if (i + 1 < n_children) {
                    separators[i] = keys[pos]; // this key lives in the interior node, nowhere else
                    pos += 1;
                }
            }
            return self.interior(gpa, separators[0 .. n_children - 1], children[0..n_children]);
        }

        // -------------------------------------------------------- reading

        pub fn get(self: *const Self, key: u64) ?u64 {
            return search.get(M, self.root, key);
        }

        /// `visitor.visit(key, value)` for every entry, ascending.
        pub fn inOrder(self: *const Self, visitor: anytype) void {
            search.inOrder(M, self.root, visitor);
        }

        /// Checks every structural invariant, the key count, and that the
        /// number of nodes reachable from the root equals the number of
        /// nodes created (a node nothing points to is a leak).
        pub fn validate(self: *const Self) validation.Error!void {
            try validation.validate(M, self.root, self.len);
            if (self.shape().nodes != self.pool.usage.live()) return error.NodeCountMismatch;
        }

        pub fn shape(self: *const Self) stats.Shape {
            return stats.shape(M, self.root);
        }

        pub fn render(self: *const Self, w: *std.Io.Writer, indent: []const u8) std.Io.Writer.Error!void {
            return stats.render(M, self.root, w, indent);
        }

        // ------------------------------------------------------- teardown

        /// Destroys every node that can be reached from the root, one by
        /// one. Needed when nodes come from an allocator that tracks each
        /// allocation. With a bump allocator or an arena, skip this call and
        /// deinit the allocator instead.
        ///
        /// Teardown is total: it also works on a tree that `validate` has
        /// rejected (a missing child is skipped), so a test can write
        /// `defer t.deinit(gpa)` and still assert on the error. But a walk
        /// frees only what it can reach. A node that nothing points to any
        /// more stays allocated: `validate` names it (NodeCountMismatch),
        /// `std.testing.allocator` reports it as a leak, and an arena frees
        /// it with everything else. (Same as `BTree.deinit` in chapter 05.)
        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (self.root) |root| self.destroySubtree(gpa, root);
            self.pool.deinit(gpa);
            self.* = undefined;
        }

        fn destroySubtree(self: *Self, gpa: Allocator, node: *NodeT) void {
            if (!node.leaf) {
                for (node.children[0 .. node.len + 1]) |child| {
                    if (child) |c| self.destroySubtree(gpa, c);
                }
            }
            self.pool.destroy(gpa, node);
        }
    };
}

/// The tree used in all examples: order 4, a "2-3-4 tree".
pub const Tree4 = HandTree(4, pool_mod.DirectNodes);

/// The tree that inserting 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 in that
/// order produces at M = 4 (chapter 04 shows how; chapter 05 prints it):
///
///                  [6 10 20]
///     [1 3 5]  [7]  [12 15 17]  [25 30]
pub fn canonical(t: *Tree4, gpa: Allocator) Allocator.Error!void {
    std.debug.assert(t.root == null);
    const a = try t.leaf(gpa, &.{ 1, 3, 5 });
    const b = try t.leaf(gpa, &.{7});
    const c = try t.leaf(gpa, &.{ 12, 15, 17 });
    const d = try t.leaf(gpa, &.{ 25, 30 });
    t.root = try t.interior(gpa, &.{ 6, 10, 20 }, &.{ a, b, c, d });
}

/// The canonical keys in insertion order.
pub const canonical_keys = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };

// ------------------------------------------------------------------ tests

const testing = std.testing;
const BumpAllocator = @import("bump.zig").BumpAllocator;
const SplitMix64 = @import("prng.zig").SplitMix64;

fn expectRendered(t: anytype, expected: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try t.render(&w, "");
    try testing.expectEqualStrings(expected, w.buffered());
}

const canonical_text = "[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]\n";

test "the canonical tree: shape, search, validate" {
    const gpa = testing.allocator;
    var t: Tree4 = .empty;
    defer t.deinit(gpa); // node by node: testing.allocator would report any node left behind
    try canonical(&t, gpa);
    try t.validate();
    try expectRendered(&t, canonical_text);
    try testing.expectEqual(stats.Shape{ .height = 2, .nodes = 5, .leaves = 4, .keys = 12, .capacity = 15 }, t.shape());
    for (canonical_keys) |key| try testing.expectEqual(valueOf(key), t.get(key));
    for ([_]u64{ 0, 2, 4, 8, 9, 11, 16, 21, 31, std.math.maxInt(u64) }) |key| try testing.expectEqual(null, t.get(key));
}

test "order 5: the minimum fill is two keys, except in the root" {
    // The README's order 5 example and the three trees of exercise 1. At
    // M = 4 the minimum is one key, so rule 4 only says "not empty"; at
    // M = 5 it is ceil(5/2) - 1 = 2 and a one-key node below the root is
    // an error.
    const Tree5 = HandTree(5, pool_mod.DirectNodes);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // README: valid, every size from the minimum (2) to the maximum (4).
    var valid: Tree5 = .empty;
    valid.root = try valid.interior(gpa, &.{ 10, 20 }, &.{
        try valid.leaf(gpa, &.{ 2, 5 }), try valid.leaf(gpa, &.{ 12, 15, 17 }), try valid.leaf(gpa, &.{ 25, 30, 35, 40 }),
    });
    try valid.validate();

    // README: the middle leaf has one key. Broken at M = 5, legal at M = 4.
    var thin5: Tree5 = .empty;
    thin5.root = try thin5.interior(gpa, &.{ 10, 20 }, &.{
        try thin5.leaf(gpa, &.{ 2, 5 }), try thin5.leaf(gpa, &.{15}), try thin5.leaf(gpa, &.{ 25, 30, 35 }),
    });
    try testing.expectError(error.NodeUnderfull, thin5.validate());
    var thin4: Tree4 = .empty;
    thin4.root = try thin4.interior(gpa, &.{ 10, 20 }, &.{
        try thin4.leaf(gpa, &.{ 2, 5 }), try thin4.leaf(gpa, &.{15}), try thin4.leaf(gpa, &.{ 25, 30, 35 }),
    });
    try thin4.validate();

    // Exercise 1 (a): a root with one key is legal at every order.
    var a: Tree5 = .empty;
    a.root = try a.interior(gpa, &.{20}, &.{ try a.leaf(gpa, &.{ 5, 10, 15 }), try a.leaf(gpa, &.{ 25, 30 }) });
    try a.validate();

    // Exercise 1 (b): interior node [40] is not the root and has one key.
    var b: Tree5 = .empty;
    const b_left = try b.interior(gpa, &.{ 10, 20 }, &.{
        try b.leaf(gpa, &.{ 2, 5 }), try b.leaf(gpa, &.{ 12, 15 }), try b.leaf(gpa, &.{ 22, 25 }),
    });
    const b_right = try b.interior(gpa, &.{40}, &.{ try b.leaf(gpa, &.{ 32, 35 }), try b.leaf(gpa, &.{ 42, 45 }) });
    b.root = try b.interior(gpa, &.{30}, &.{ b_left, b_right });
    try testing.expectError(error.NodeUnderfull, b.validate());
    var b4: Tree4 = .empty; // the same tree is a legal 2-3-4 tree
    const b4_left = try b4.interior(gpa, &.{ 10, 20 }, &.{
        try b4.leaf(gpa, &.{ 2, 5 }), try b4.leaf(gpa, &.{ 12, 15 }), try b4.leaf(gpa, &.{ 22, 25 }),
    });
    const b4_right = try b4.interior(gpa, &.{40}, &.{ try b4.leaf(gpa, &.{ 32, 35 }), try b4.leaf(gpa, &.{ 42, 45 }) });
    b4.root = try b4.interior(gpa, &.{30}, &.{ b4_left, b4_right });
    try b4.validate();

    // Exercise 1 (c): every node is full enough, but 21 is right of separator 20.
    var c: Tree5 = .empty;
    c.root = try c.interior(gpa, &.{ 10, 20 }, &.{
        try c.leaf(gpa, &.{ 2, 5 }), try c.leaf(gpa, &.{ 12, 21 }), try c.leaf(gpa, &.{ 25, 30 }),
    });
    try testing.expectError(error.KeyOutsideParentBounds, c.validate());
    try testing.expectEqual(null, c.get(21)); // stored, but a search goes to [25 30]
}

test "every u64 is a legal key: the largest ones can be stored and found" {
    // Regression: valueOf multiplied with `*`, which traps above maxInt / 10.
    const max = std.math.maxInt(u64);
    const gpa = testing.allocator;
    var t: Tree4 = .empty;
    defer t.deinit(gpa);
    const low = try t.leaf(gpa, &.{ 0, max / 10 });
    const high = try t.leaf(gpa, &.{ max - 1, max });
    t.root = try t.interior(gpa, &.{max / 10 + 1}, &.{ low, high });
    try t.validate();
    try testing.expectEqual(max / 10 * 10, t.get(max / 10)); // the last key whose value does not wrap
    try testing.expectEqual(valueOf(max / 10 + 1), t.get(max / 10 + 1));
    try testing.expectEqual(valueOf(max - 1), t.get(max - 1));
    try testing.expectEqual(valueOf(max), t.get(max));
    try testing.expectEqual(max - 9, valueOf(max)); // (2^64 - 1) * 10 mod 2^64
    try testing.expectEqual(null, t.get(max - 2));
}

test "the same builder on three allocators: tracked, bump, arena" {
    // 1. Every node tracked: the tree must be walked to free it.
    var tracked: Tree4 = .empty;
    try canonical(&tracked, testing.allocator);
    try expectRendered(&tracked, canonical_text);
    tracked.deinit(testing.allocator);

    // 2. Hand-written bump allocator: no walk, one deinit.
    var bump_state: BumpAllocator = .init(testing.allocator);
    defer bump_state.deinit();
    var bumped: Tree4 = .empty;
    try canonical(&bumped, bump_state.allocator());
    try bumped.validate();
    try expectRendered(&bumped, canonical_text);
    try testing.expectEqual(5, bump_state.stats.allocations);
    try testing.expectEqual(1, bump_state.stats.chunks); // five nodes, one request to the child

    // 3. std.heap.ArenaAllocator: the same job from the standard library.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var in_arena: Tree4 = .empty;
    try canonical(&in_arena, arena_state.allocator());
    try in_arena.validate();
    try expectRendered(&in_arena, canonical_text);
}

test "bump-allocated nodes are neighbours in memory" {
    var bump_state: BumpAllocator = .init(testing.allocator);
    defer bump_state.deinit();
    var t: Tree4 = .empty;
    try canonical(&t, bump_state.allocator());
    const root = t.root.?;
    // Leaves were created first, left to right, the root last.
    for (0..3) |i| {
        const here = @intFromPtr(root.children[i].?);
        const next = @intFromPtr(root.children[i + 1].?);
        try testing.expectEqual(here + @sizeOf(Tree4.NodeT), next);
    }
    try testing.expectEqual(@intFromPtr(root.children[3].?) + @sizeOf(Tree4.NodeT), @intFromPtr(root));
}

/// Build on `gpa` and free everything again. With an arena in between, a
/// build that fails half-way leaves nothing behind although there is no
/// finished tree that could be walked.
fn buildInArena(gpa: Allocator, n: u64) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var keys: [200]u64 = undefined;
    for (keys[0..n], 0..) |*key, i| key.* = i * 3;
    var t: Tree4 = .empty;
    try t.fromSorted(arena_state.allocator(), keys[0..n]);
    try t.validate();
}

fn buildInBump(gpa: Allocator, n: u64) !void {
    var bump_state: BumpAllocator = .init(gpa);
    defer bump_state.deinit();
    var keys: [200]u64 = undefined;
    for (keys[0..n], 0..) |*key, i| key.* = i * 3;
    var t: Tree4 = .empty;
    try t.fromSorted(bump_state.allocator(), keys[0..n]);
    try t.validate();
}

test "allocation failure at every point of a build leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, buildInArena, .{@as(u64, 200)});
    try testing.checkAllAllocationFailures(testing.allocator, buildInBump, .{@as(u64, 200)});
}

test "allocation failure with tracked nodes: the builder reports it, the caller cleans up" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 2 });
    const gpa = failing.allocator();
    var t: Tree4 = .empty;
    const a = try t.leaf(gpa, &.{ 1, 2 });
    const b = try t.leaf(gpa, &.{ 4, 5 });
    try testing.expectError(error.OutOfMemory, t.interior(gpa, &.{3}, &.{ a, b }));
    try testing.expectEqual(2, t.pool.usage.live()); // the failed node was not counted
    // No root exists, so deinit could not find the two leaves: free them by hand.
    t.pool.destroy(gpa, a);
    t.pool.destroy(gpa, b);
    t.deinit(gpa);
}

test "fromSorted: valid and of minimal height for every size and several orders" {
    var keys: [400]u64 = undefined;
    for (&keys, 0..) |*key, i| key.* = i * 2 + 1;
    inline for (.{ 3, 4, 5, 6, 7, 16 }) |M| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        for (0..keys.len + 1) |n| {
            _ = arena_state.reset(.retain_capacity); // forget the previous tree, keep the memory
            var t: HandTree(M, pool_mod.DirectNodes) = .empty;
            try t.fromSorted(arena_state.allocator(), keys[0..n]);
            try t.validate();
            try testing.expectEqual(n, t.len);
            try testing.expectEqual(height_mod.minHeight(M, n), t.shape().height);
        }
    }
}

test "seeded model test: get and inOrder agree with an oracle" {
    // The oracle is the simplest thing that can answer "is k present?":
    // one bool per possible key.
    const key_space = 1500;
    inline for (.{ 3, 4, 5, 8 }) |M| {
        for ([_]u64{ 1, 2, 3 }) |seed| {
            var prng = SplitMix64.init(seed * 100 + M);
            var present: [key_space]bool = undefined;
            var sorted: [key_space]u64 = undefined;
            var n: usize = 0;
            for (&present, 0..) |*p, key| {
                p.* = prng.chance(seed, 4); // 25%, 50% or 75% of the key space
                if (p.*) {
                    sorted[n] = key;
                    n += 1;
                }
            }
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var t: HandTree(M, pool_mod.DirectNodes) = .empty;
            try t.fromSorted(arena_state.allocator(), sorted[0..n]);
            try t.validate();

            for (present, 0..) |p, key| {
                const want: ?u64 = if (p) valueOf(key) else null;
                try testing.expectEqual(want, t.get(key));
            }
            const Check = struct {
                expected: []const u64,
                i: usize = 0,
                ok: bool = true,
                pub fn visit(self: *@This(), key: u64, value: u64) void {
                    self.ok = self.ok and self.i < self.expected.len and
                        self.expected[self.i] == key and value == valueOf(key);
                    self.i += 1;
                }
            };
            var check: Check = .{ .expected = sorted[0..n] };
            t.inOrder(&check);
            try testing.expect(check.ok and check.i == n);
        }
    }
}

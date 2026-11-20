//! Tests of the whole tree: fixed scenarios, a seeded model test against the
//! oracle, allocation failure, and proof that `validate` catches corruption.
//! (arena.zig, node.zig and search.zig carry their own unit tests.)
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const BPlusTree = @import("tree.zig").BPlusTree;
const NodeId = @import("arena.zig").NodeId;
const node = @import("node.zig");
const LeafWalker = @import("walk.zig").LeafWalker;
const dump = @import("dump.zig");
const ops = @import("ops.zig");

const canonical = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };

fn buildCanonical(gpa: Allocator) !BPlusTree {
    var tree: BPlusTree = .init(4);
    errdefer tree.deinit(gpa);
    for (canonical) |k| _ = try tree.put(gpa, k, k * 100);
    return tree;
}

fn expectDump(expected: []const u8, tree: *const BPlusTree) !void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try dump.dump(tree, &w);
    try testing.expectEqualStrings(expected, w.buffered());
}

/// Checks the chain in both directions against `expected` (ascending keys).
fn expectChain(expected: []const u64, tree: *const BPlusTree) !void {
    var walker = LeafWalker.first(tree);
    for (expected) |k| try testing.expectEqual(k, walker.next().?.key);
    try testing.expectEqual(null, walker.next());

    // Backward by hand through the prev links: the last key first.
    var i = expected.len;
    var id = tree.last_leaf;
    while (id != .nil) : (id = tree.nodes.get(id).kind.leaf.prev) {
        const n = tree.nodes.get(id);
        var j = n.len;
        while (j > 0) {
            j -= 1;
            i -= 1;
            try testing.expectEqual(expected[i], n.keys[j]);
        }
    }
    try testing.expectEqual(0, i);
}

test "canonical example has the shape shown in the README" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    try tree.validate();
    try expectDump(
        \\height 3, 12 keys, 8 nodes
        \\  level 0: #7[15]
        \\  level 1: #2[6 10] #6[20]
        \\  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(15 17) <-> #3(20 25 30)
        \\
    , &tree);
    try expectChain(&.{ 1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30 }, &tree);
    for (canonical) |k| try testing.expectEqual(k * 100, tree.get(k));
    try testing.expectEqual(null, tree.get(13));
    try testing.expectEqual(4, tree.stats.leaf_splits);
    try testing.expectEqual(1, tree.stats.internal_splits);
}

test "copy-up keeps the key in the leaf, push-up moves the separator" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    // 15 was copied up from leaf #5 and then pushed up out of node #2:
    // it is in the root and in a leaf, but in no other internal node.
    const root = tree.nodes.get(tree.root);
    try testing.expectEqualSlices(u64, &.{15}, root.keySlice());
    for (root.childSlice()) |child| {
        try testing.expect(std.mem.findScalar(u64, tree.nodes.get(child).keySlice(), 15) == null);
    }
    try testing.expectEqual(1500, tree.get(15));
}

test "put overwrites and reports the old value" {
    const gpa = testing.allocator;
    var tree: BPlusTree = .init(4);
    defer tree.deinit(gpa);
    try testing.expectEqual(null, try tree.put(gpa, 1, 10));
    try testing.expectEqual(10, try tree.put(gpa, 1, 11));
    try testing.expectEqual(11, tree.get(1));
    try testing.expectEqual(1, tree.len());
}

test "a separator may outlive its key" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    try testing.expectEqual(1500, tree.delete(15));
    try testing.expectEqual(null, tree.delete(15));
    try testing.expectEqual(null, tree.get(15));
    // The root still says 15, and that is a valid tree.
    try testing.expectEqualSlices(u64, &.{15}, tree.nodes.get(tree.root).keySlice());
    try tree.validate();
    // Keys on both sides of the stale separator are still routed correctly.
    try testing.expectEqual(null, try tree.put(gpa, 14, 1));
    try testing.expectEqual(null, try tree.put(gpa, 16, 2));
    try testing.expectEqual(null, try tree.put(gpa, 15, 3));
    try tree.validate();
    try expectChain(&.{ 1, 3, 5, 6, 7, 10, 12, 14, 15, 16, 17, 20, 25, 30 }, &tree);
}

test "delete walks through borrow, merge and root shrink" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    for ([_]u64{ 15, 17, 20, 25, 30, 12 }) |k| {
        try testing.expectEqual(k * 100, tree.delete(k));
        try tree.validate();
    }
    try testing.expectEqual(4, tree.stats.borrows);
    try testing.expectEqual(3, tree.stats.merges);
    try expectDump(
        \\height 2, 6 keys, 4 nodes
        \\  level 0: #2[6 10]
        \\  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10)
        \\
    , &tree);
}

test "an underfull middle leaf merges with its left sibling" {
    // The README's delete rule: borrow left, borrow right, merge left, merge
    // right. Bring #0, #4 and #1 (the three children of #2) down to one key
    // each; deleting 6 then leaves #4, the middle one, with nothing to borrow.
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    for ([_]u64{ 3, 5, 12, 7 }) |k| try testing.expectEqual(k * 100, tree.delete(k));
    try testing.expectEqual(0, tree.stats.borrows + tree.stats.merges);
    try testing.expectEqual(600, tree.delete(6));
    try tree.validate();
    try testing.expectEqual(0, tree.stats.borrows);
    try testing.expectEqual(1, tree.stats.merges);
    // #4 was emptied into its LEFT sibling #0 and freed; separator 6 is gone.
    try expectDump(
        \\height 3, 7 keys, 7 nodes
        \\  level 0: #7[15]
        \\  level 1: #2[10] #6[20]
        \\  leaves : #0(1) <-> #1(10) <-> #5(15 17) <-> #3(20 25 30)
        \\
    , &tree);
    try testing.expect(!tree.nodes.isLive(NodeId.fromIndex(4)));
}

test "deleting everything frees every node, and the tree can be refilled" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    for (canonical) |k| {
        try testing.expectEqual(k * 100, tree.delete(k));
        try tree.validate();
    }
    try testing.expectEqual(0, tree.nodes.liveCount());
    try testing.expectEqual(0, tree.height);
    try testing.expectEqual(NodeId.nil, tree.root);
    const slots = tree.nodes.slotCount();
    for (canonical) |k| _ = try tree.put(gpa, k, k);
    try tree.validate();
    // The second build fits entirely into recycled slots.
    try testing.expectEqual(slots, tree.nodes.slotCount());
}

test "ascending and descending inserts keep both ends of the chain right" {
    const gpa = testing.allocator;
    for ([_]usize{ 3, 4, 5, 8 }) |order| {
        var up: BPlusTree = .init(order);
        defer up.deinit(gpa);
        var down: BPlusTree = .init(order);
        defer down.deinit(gpa);
        var expected: [200]u64 = undefined;
        for (0..200) |i| {
            expected[i] = i;
            _ = try up.put(gpa, i, i);
            _ = try down.put(gpa, 199 - i, i);
        }
        try up.validate();
        try down.validate();
        try expectChain(&expected, &up);
        try expectChain(&expected, &down);
        // Empty one from the front and the other from the back.
        for (0..200) |i| {
            try testing.expectEqual(i, up.delete(i));
            try testing.expect(down.delete(199 - i) != null);
            try up.validate();
            try down.validate();
        }
        try testing.expectEqual(0, up.nodes.liveCount());
        try testing.expectEqual(0, down.nodes.liveCount());
    }
}

test "seek positions the walker at the first key >= the argument" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    var w = LeafWalker.seek(&tree, 12);
    try testing.expectEqual(12, w.next().?.key);
    // 13 is absent and falls after the last key of leaf #1: the walker must
    // step over the leaf boundary to 15.
    w = LeafWalker.seek(&tree, 13);
    try testing.expectEqual(15, w.next().?.key);
    w = LeafWalker.seek(&tree, 0);
    try testing.expectEqual(1, w.next().?.key);
    w = LeafWalker.seek(&tree, 31);
    try testing.expectEqual(null, w.next());
    var empty: BPlusTree = .init(4);
    w = LeafWalker.seek(&empty, 1);
    try testing.expectEqual(null, w.next());
}

/// The seeded model test: the same operation stream goes to the tree and to
/// the oracle and every answer must agree. The Rust twin replays the
/// identical stream.
fn modelTest(gpa: Allocator, order: usize, seed: u64, count: u64, key_space: u64) !void {
    var tree: BPlusTree = .init(order);
    defer tree.deinit(gpa);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var stream = ops.OpStream.init(.{ .seed = seed, .count = count, .key_space = key_space });
    while (stream.next()) |op| {
        switch (op) {
            .put => |p| try testing.expectEqual(try oracle.put(gpa, p.key, p.value), try tree.put(gpa, p.key, p.value)),
            .delete => |d| try testing.expectEqual(oracle.delete(d.key), tree.delete(d.key)),
            .get => |g| try testing.expectEqual(oracle.get(g.key), tree.get(g.key)),
            .range => |r| {
                var walker = LeafWalker.seek(&tree, r.lo);
                for (oracle.range(r.lo, r.hi)) |expected| {
                    const got = walker.next().?;
                    try testing.expectEqual(expected.key, got.key);
                    try testing.expectEqual(expected.value, got.value);
                }
                if (walker.next()) |after| try testing.expect(after.key >= r.hi);
            },
        }
        try testing.expectEqual(oracle.len(), tree.len());
        try tree.validate();
    }
}

test "model test against the oracle, several orders and key spaces" {
    const gpa = testing.allocator;
    for ([_]usize{ 3, 4, 5, 6, 7, 16 }) |order| {
        // A small key space keeps the tree tiny and churning (many merges and
        // root shrinks); a large one makes it tall.
        try modelTest(gpa, order, 1, 3000, 40);
        try modelTest(gpa, order, 2, 3000, 2000);
        try modelTest(gpa, order, 3 + order, 1500, 300);
    }
}

test "model test with delete-heavy weights empties the tree repeatedly" {
    const gpa = testing.allocator;
    var tree: BPlusTree = .init(4);
    defer tree.deinit(gpa);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var stream = ops.OpStream.init(.{ .seed = 11, .count = 5000, .key_space = 6, .weights = .{ .put = 2, .delete = 5, .get = 1, .range = 0 } });
    var times_empty: usize = 0;
    while (stream.next()) |op| {
        switch (op) {
            .put => |p| try testing.expectEqual(try oracle.put(gpa, p.key, p.value), try tree.put(gpa, p.key, p.value)),
            .delete => |d| {
                try testing.expectEqual(oracle.delete(d.key), tree.delete(d.key));
                if (tree.len() == 0) times_empty += 1;
            },
            .get => |g| try testing.expectEqual(oracle.get(g.key), tree.get(g.key)),
            .range => unreachable,
        }
        try tree.validate();
    }
    try testing.expect(times_empty > 50);
}

// ------------------------------------------------------ allocation failure

fn buildUnderFailure(gpa: Allocator) !void {
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    try tree.validate();
}

test "every allocation failure during a build is reported and leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, buildUnderFailure, .{});
}

test "a put that runs out of memory leaves the tree exactly as it was" {
    // Give the tree a fixed memory budget and insert until it runs out; then
    // repeat with a larger budget, so the failure hits trees of every size.
    const slot_size = @sizeOf(@import("node.zig").Node) + 16;
    const storage = try testing.allocator.alloc(u8, 80 * slot_size);
    defer testing.allocator.free(storage);

    var failures: usize = 0;
    var budget: usize = 0;
    while (budget <= storage.len) : (budget += slot_size) {
        var fixed: std.heap.FixedBufferAllocator = .init(storage[0..budget]);
        const gpa = fixed.allocator();
        var tree: BPlusTree = .init(3);
        defer tree.deinit(gpa);

        for (0..64) |i| {
            const key: u64 = (i * 37) % 64;
            var before: [4096]u8 = undefined;
            var wb: std.Io.Writer = .fixed(&before);
            try dump.dump(&tree, &wb);

            if (tree.put(gpa, key, key)) |old| {
                try testing.expectEqual(null, old);
                try tree.validate();
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                failures += 1;
                // Nothing changed: same picture, still valid, key absent,
                // and the tree is still usable for reads and deletes.
                try expectDump(wb.buffered(), &tree);
                try tree.validate();
                try testing.expectEqual(null, tree.get(key));
                try testing.expectEqual(i, tree.len());
                if (i > 0) try testing.expectEqual(0, tree.delete(0));
                try tree.validate();
                break;
            }
        }
    }
    try testing.expect(failures > 10);
}

// ------------------------------------------- validate catches corruption

test "validate names the broken invariant" {
    const gpa = testing.allocator;
    const V = error{ OutOfMemory, TestExpectedError, TestUnexpectedError };
    const Case = struct {
        expected: anyerror,
        corrupt: *const fn (tree: *BPlusTree, a: Allocator) V!void,
    };
    const cases = [_]Case{
        .{ .expected = error.KeysNotSorted, .corrupt = struct {
            fn f(t: *BPlusTree, _: Allocator) V!void {
                const leaf = t.nodes.ptr(t.first_leaf);
                std.mem.swap(u64, &leaf.keys[0], &leaf.keys[1]);
            }
        }.f },
        .{
            .expected = error.KeyOutOfBounds,
            .corrupt = struct {
                fn f(t: *BPlusTree, _: Allocator) V!void {
                    // Leaf #4 is (6 7) and sits left of separator 10. Changing 7 to
                    // 11 keeps the leaf sorted but breaks the separator's promise.
                    t.nodes.ptr(NodeId.fromIndex(4)).keys[1] = 11;
                }
            }.f,
        },
        .{ .expected = error.NodeUnderfull, .corrupt = struct {
            fn f(t: *BPlusTree, _: Allocator) V!void {
                t.nodes.ptr(t.last_leaf).len = 0;
            }
        }.f },
        .{
            .expected = error.NodeOverfull,
            .corrupt = struct {
                fn f(t: *BPlusTree, _: Allocator) V!void {
                    // Append keys larger than any other until the leaf holds
                    // one too many. Appending at `len` works however full the
                    // leaf is, so the case does not depend on the exact shape.
                    const leaf = t.nodes.ptr(t.last_leaf);
                    while (leaf.len <= t.maxKeys()) leaf.leafInsertAt(leaf.len, 40 + leaf.len, 0);
                }
            }.f,
        },
        .{
            .expected = error.NodeOverfull,
            .corrupt = struct {
                fn f(t: *BPlusTree, _: Allocator) V!void {
                    // A length beyond the node's arrays: the checker must
                    // report it before it slices the keys, not crash on it.
                    t.nodes.ptr(t.last_leaf).len = node.key_capacity + 1;
                }
            }.f,
        },
        .{ .expected = error.BrokenLeafChain, .corrupt = struct {
            fn f(t: *BPlusTree, _: Allocator) V!void {
                t.nodes.ptr(t.last_leaf).kind.leaf.prev = t.first_leaf;
            }
        }.f },
        .{
            .expected = error.BrokenLeafChain,
            .corrupt = struct {
                fn f(t: *BPlusTree, _: Allocator) V!void {
                    // Skip a leaf in the forward direction.
                    const first = t.nodes.ptr(t.first_leaf);
                    first.kind.leaf.next = t.nodes.get(first.kind.leaf.next).kind.leaf.next;
                }
            }.f,
        },
        .{ .expected = error.WrongCount, .corrupt = struct {
            fn f(t: *BPlusTree, _: Allocator) V!void {
                t.count += 1;
            }
        }.f },
        .{ .expected = error.UnevenLeafDepth, .corrupt = struct {
            fn f(t: *BPlusTree, _: Allocator) V!void {
                t.height += 1;
            }
        }.f },
        .{
            .expected = error.DanglingChild,
            .corrupt = struct {
                fn f(t: *BPlusTree, _: Allocator) V!void {
                    // Free a leaf behind the tree's back: its parent still points at it.
                    t.nodes.free(t.last_leaf);
                }
            }.f,
        },
        .{
            .expected = error.ArenaLeak,
            .corrupt = struct {
                fn f(t: *BPlusTree, a: Allocator) V!void {
                    // A node nobody points at: a leak inside the arena.
                    _ = try t.nodes.alloc(a, .initLeaf());
                }
            }.f,
        },
    };
    for (cases) |case| {
        var tree = try buildCanonical(gpa);
        defer tree.deinit(gpa);
        try tree.validate();
        try case.corrupt(&tree, gpa);
        try testing.expectError(case.expected, tree.validate());
    }
}

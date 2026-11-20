//! A small in-memory B-tree whose nodes live in two bitmap slab pools (one size class
//! for leaves, one for interior nodes) and refer to each other by 32-bit handles.
//!
//! The tree is the classic B-tree of chapters 03 to 05 (keys and values in every node),
//! with top-down splitting and CLRS top-down deletion, because that variant needs no
//! parent stack and has a property this chapter cares about: every allocation happens
//! BEFORE the step that needs it mutates anything, so an allocation failure in the
//! middle of `put` leaves a valid tree and leaks nothing.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const slab = @import("slab.zig");
pub const Handle = slab.Handle;

pub const Entry = struct { key: u64, value: u64 };

/// `M` = order = maximum number of children (Knuth). `slots` = slots per slab.
pub fn BTree(comptime M: u8, comptime slots: u16) type {
    // Top-down splitting splits a full node (M-1 keys) around its median into two
    // minimal nodes, which only works out when M is even.
    comptime assert(M >= 4 and M % 2 == 0);
    const t = M / 2; // CLRS minimum degree: non-root nodes hold t-1 ..= 2t-1 keys
    const max_keys = M - 1;

    return struct {
        const Tree = @This();

        /// Size class 0. A leaf has no child array, so it is smaller than an interior
        /// node; giving each kind its own pool means neither wastes the difference.
        pub const Leaf = struct {
            len: u8,
            keys: [max_keys]u64,
            vals: [max_keys]u64,
        };
        /// Size class 1: the same header plus M child handles (4 bytes each, where a
        /// pointer-based node would spend 8).
        pub const Interior = struct {
            head: Leaf,
            children: [M]Handle,
        };
        pub const LeafPool = slab.SlabPool(Leaf, slots);
        pub const InteriorPool = slab.SlabPool(Interior, slots);

        leaves: LeafPool,
        interiors: InteriorPool,
        root: Handle = .none,
        /// Number of levels; 0 for the empty tree.
        height: u32 = 0,
        count: usize = 0,

        pub fn init(backing: Allocator, release_empty: bool) Tree {
            return .{
                .leaves = .init(backing, .{ .class = 0, .release_empty = release_empty }),
                .interiors = .init(backing, .{ .class = 1, .release_empty = release_empty }),
            };
        }

        /// No tree walk: dropping the slabs drops every node.
        pub fn deinit(tree: *Tree) void {
            tree.leaves.deinit();
            tree.interiors.deinit();
            tree.* = undefined;
        }

        // ---- handle plumbing ---------------------------------------------------------

        fn isLeaf(h: Handle) bool {
            return h.class == 0;
        }

        /// Keys and values of any node. The class bit in the handle picks the pool.
        fn head(tree: *const Tree, h: Handle) *Leaf {
            return if (isLeaf(h)) tree.leaves.get(h) else &tree.interiors.get(h).head;
        }

        fn kids(tree: *const Tree, h: Handle) *[M]Handle {
            return &tree.interiors.get(h).children;
        }

        fn newNode(tree: *Tree, leaf: bool) Allocator.Error!Handle {
            const h = if (leaf) try tree.leaves.create() else try tree.interiors.create();
            tree.head(h).len = 0;
            return h;
        }

        fn freeNode(tree: *Tree, h: Handle) void {
            if (isLeaf(h)) tree.leaves.destroy(h) else tree.interiors.destroy(h);
        }

        fn lowerBound(keys: []const u64, key: u64) u8 {
            var i: u8 = 0;
            while (i < keys.len and keys[i] < key) i += 1;
            return i;
        }

        // ---- get / range ---------------------------------------------------------------

        pub fn get(tree: *const Tree, key: u64) ?u64 {
            var h = tree.root;
            while (!h.isNone()) {
                const n = tree.head(h);
                const i = lowerBound(n.keys[0..n.len], key);
                if (i < n.len and n.keys[i] == key) return n.vals[i];
                if (isLeaf(h)) return null;
                h = tree.kids(h)[i];
            }
            return null;
        }

        /// Appends the entries with lo <= key < hi to `out`, ascending.
        pub fn range(tree: *const Tree, gpa: Allocator, lo: u64, hi: u64, out: *std.ArrayList(Entry)) Allocator.Error!void {
            if (!tree.root.isNone() and lo < hi) try tree.rangeNode(gpa, tree.root, lo, hi, out);
        }

        fn rangeNode(tree: *const Tree, gpa: Allocator, h: Handle, lo: u64, hi: u64, out: *std.ArrayList(Entry)) Allocator.Error!void {
            const n = tree.head(h);
            var i = lowerBound(n.keys[0..n.len], lo);
            while (true) : (i += 1) {
                // Child i holds the keys between key i-1 and key i.
                if (!isLeaf(h)) try tree.rangeNode(gpa, tree.kids(h)[i], lo, hi, out);
                if (i == n.len or n.keys[i] >= hi) return;
                try out.append(gpa, .{ .key = n.keys[i], .value = n.vals[i] });
            }
        }

        // ---- put -----------------------------------------------------------------------

        /// Insert or overwrite. On `error.OutOfMemory` the key is not inserted and the
        /// tree is still valid (some full nodes on the path may already have been split,
        /// which changes the shape but not the contents).
        pub fn put(tree: *Tree, key: u64, value: u64) Allocator.Error!void {
            if (tree.root.isNone()) {
                tree.root = try tree.newNode(true);
                tree.height = 1;
            }
            if (tree.head(tree.root).len == max_keys) {
                // Grow upwards: a new empty root above the old one, then split the old.
                const new_root = try tree.newNode(false);
                errdefer tree.freeNode(new_root);
                tree.kids(new_root)[0] = tree.root;
                try tree.splitChild(new_root, 0);
                tree.root = new_root;
                tree.height += 1;
            }
            var h = tree.root;
            while (true) {
                // Invariant: node h is not full, so a key coming up from a split fits.
                const n = tree.head(h);
                const i = lowerBound(n.keys[0..n.len], key);
                if (i < n.len and n.keys[i] == key) {
                    n.vals[i] = value;
                    return;
                }
                if (isLeaf(h)) {
                    insertAt(n, i, key, value);
                    tree.count += 1;
                    return;
                }
                var child = tree.kids(h)[i];
                if (tree.head(child).len == max_keys) {
                    try tree.splitChild(h, i);
                    // The child's median is now n.keys[i]; pick the correct side of it.
                    if (key == n.keys[i]) {
                        n.vals[i] = value;
                        return;
                    }
                    if (key > n.keys[i]) child = tree.kids(h)[i + 1];
                }
                h = child;
            }
        }

        fn insertAt(n: *Leaf, i: u8, key: u64, value: u64) void {
            @memmove(n.keys[i + 1 .. n.len + 1], n.keys[i..n.len]);
            @memmove(n.vals[i + 1 .. n.len + 1], n.vals[i..n.len]);
            n.keys[i] = key;
            n.vals[i] = value;
            n.len += 1;
        }

        fn removeAt(n: *Leaf, i: u8) void {
            @memmove(n.keys[i .. n.len - 1], n.keys[i + 1 .. n.len]);
            @memmove(n.vals[i .. n.len - 1], n.vals[i + 1 .. n.len]);
            n.len -= 1;
        }

        /// Split the full child i of `parent` (which is not full). The only allocation
        /// comes first; after it nothing can fail.
        fn splitChild(tree: *Tree, parent: Handle, i: u8) Allocator.Error!void {
            const left_h = tree.kids(parent)[i];
            const right_h = try tree.newNode(isLeaf(left_h));
            // These pointers stay valid across `create`: slabs never move.
            const left = tree.head(left_h);
            const right = tree.head(right_h);
            // left keeps keys 0..t-1, the median (index t-1) goes up, right gets the rest.
            right.len = t - 1;
            @memcpy(right.keys[0 .. t - 1], left.keys[t..max_keys]);
            @memcpy(right.vals[0 .. t - 1], left.vals[t..max_keys]);
            if (!isLeaf(left_h)) @memcpy(tree.kids(right_h)[0..t], tree.kids(left_h)[t..M]);
            left.len = t - 1;

            const p = tree.head(parent);
            const pk = tree.kids(parent);
            @memmove(pk[i + 2 .. p.len + 2], pk[i + 1 .. p.len + 1]);
            pk[i + 1] = right_h;
            insertAt(p, i, left.keys[t - 1], left.vals[t - 1]);
        }

        // ---- delete --------------------------------------------------------------------

        /// Returns whether the key was present. Never allocates.
        pub fn delete(tree: *Tree, key: u64) bool {
            if (tree.root.isNone()) return false;
            const removed = tree.deleteFrom(tree.root, key);
            if (removed) tree.count -= 1;
            // A root without keys is replaced by its only child (or by nothing).
            if (tree.head(tree.root).len == 0) {
                const old = tree.root;
                tree.root = if (isLeaf(old)) .none else tree.kids(old)[0];
                tree.freeNode(old);
                tree.height -= 1;
            }
            return removed;
        }

        /// Precondition: `h` is the root or holds at least t keys, so one key can leave
        /// it without underflow. Each step re-establishes this for the child it enters.
        fn deleteFrom(tree: *Tree, h: Handle, key: u64) bool {
            const n = tree.head(h);
            const i = lowerBound(n.keys[0..n.len], key);
            const found = i < n.len and n.keys[i] == key;
            if (isLeaf(h)) {
                if (found) removeAt(n, i);
                return found;
            }
            const pk = tree.kids(h);
            if (found) {
                if (tree.head(pk[i]).len >= t) {
                    // Replace by the predecessor, then delete the predecessor below.
                    const pred = tree.edgeEntry(pk[i], .max);
                    n.keys[i] = pred.key;
                    n.vals[i] = pred.value;
                    return tree.deleteFrom(pk[i], pred.key);
                }
                if (tree.head(pk[i + 1]).len >= t) {
                    const succ = tree.edgeEntry(pk[i + 1], .min);
                    n.keys[i] = succ.key;
                    n.vals[i] = succ.value;
                    return tree.deleteFrom(pk[i + 1], succ.key);
                }
                tree.merge(h, i); // both minimal: key sinks into the merged child
                return tree.deleteFrom(pk[i], key);
            }
            var c = i;
            if (tree.head(pk[c]).len == t - 1) {
                if (c > 0 and tree.head(pk[c - 1]).len >= t) {
                    tree.borrowFromLeft(h, c);
                } else if (c < n.len and tree.head(pk[c + 1]).len >= t) {
                    tree.borrowFromRight(h, c);
                } else if (c < n.len) {
                    tree.merge(h, c);
                } else {
                    tree.merge(h, c - 1);
                    c -= 1;
                }
            }
            return tree.deleteFrom(pk[c], key);
        }

        fn edgeEntry(tree: *const Tree, start: Handle, side: enum { min, max }) Entry {
            var h = start;
            while (!isLeaf(h)) h = tree.kids(h)[if (side == .min) 0 else tree.head(h).len];
            const n = tree.head(h);
            const i = if (side == .min) 0 else n.len - 1;
            return .{ .key = n.keys[i], .value = n.vals[i] };
        }

        /// Merge child i, separator i and child i+1 into child i; free child i+1.
        /// This is where slots become free and holes appear in the slab bitmaps.
        fn merge(tree: *Tree, parent: Handle, i: u8) void {
            const p = tree.head(parent);
            const pk = tree.kids(parent);
            const left_h = pk[i];
            const right_h = pk[i + 1];
            const left = tree.head(left_h);
            const right = tree.head(right_h);
            assert(left.len == t - 1 and right.len == t - 1);
            left.keys[t - 1] = p.keys[i];
            left.vals[t - 1] = p.vals[i];
            @memcpy(left.keys[t..max_keys], right.keys[0 .. t - 1]);
            @memcpy(left.vals[t..max_keys], right.vals[0 .. t - 1]);
            if (!isLeaf(left_h)) @memcpy(tree.kids(left_h)[t..M], tree.kids(right_h)[0..t]);
            left.len = max_keys;
            @memmove(pk[i + 1 .. p.len], pk[i + 2 .. p.len + 1]);
            removeAt(p, i);
            tree.freeNode(right_h);
        }

        /// Rotate right: separator c-1 moves down to the front of child c, the last
        /// entry of child c-1 moves up.
        fn borrowFromLeft(tree: *Tree, parent: Handle, c: u8) void {
            const p = tree.head(parent);
            const left_h = tree.kids(parent)[c - 1];
            const child_h = tree.kids(parent)[c];
            const left = tree.head(left_h);
            const child = tree.head(child_h);
            if (!isLeaf(child_h)) {
                const ck = tree.kids(child_h);
                @memmove(ck[1 .. child.len + 2], ck[0 .. child.len + 1]);
                ck[0] = tree.kids(left_h)[left.len];
            }
            insertAt(child, 0, p.keys[c - 1], p.vals[c - 1]);
            p.keys[c - 1] = left.keys[left.len - 1];
            p.vals[c - 1] = left.vals[left.len - 1];
            left.len -= 1;
        }

        /// Rotate left: separator c moves down to the end of child c, the first entry
        /// of child c+1 moves up.
        fn borrowFromRight(tree: *Tree, parent: Handle, c: u8) void {
            const p = tree.head(parent);
            const child_h = tree.kids(parent)[c];
            const right_h = tree.kids(parent)[c + 1];
            const child = tree.head(child_h);
            const right = tree.head(right_h);
            if (!isLeaf(child_h)) {
                const rk = tree.kids(right_h);
                tree.kids(child_h)[child.len + 1] = rk[0];
                @memmove(rk[0..right.len], rk[1 .. right.len + 1]);
            }
            insertAt(child, child.len, p.keys[c], p.vals[c]);
            p.keys[c] = right.keys[0];
            p.vals[c] = right.vals[0];
            removeAt(right, 0);
        }

        // ---- vacuum --------------------------------------------------------------------

        /// Compaction after many deletes (after DuckDB's `ART::Vacuum`): each pool picks
        /// its emptiest slab as victim, the tree moves every node out of it and rewrites
        /// the ONE handle that refers to the node (its parent's child slot, or `root`).
        /// Returns the number of nodes moved.
        pub fn vacuum(tree: *Tree) u32 {
            const leaf_victim = tree.leaves.vacuumBegin();
            const interior_victim = tree.interiors.vacuumBegin();
            var moved: u32 = 0;
            if (!tree.root.isNone()) {
                tree.root = tree.moveIfVictim(tree.root, &moved);
                tree.vacuumNode(tree.root, &moved);
            }
            if (leaf_victim) tree.leaves.vacuumEnd();
            if (interior_victim) tree.interiors.vacuumEnd();
            return moved;
        }

        fn moveIfVictim(tree: *Tree, h: Handle, moved: *u32) Handle {
            const victim = if (isLeaf(h)) tree.leaves.isVictim(h) else tree.interiors.isVictim(h);
            if (!victim) return h;
            moved.* += 1;
            return if (isLeaf(h)) tree.leaves.relocate(h) else tree.interiors.relocate(h);
        }

        fn vacuumNode(tree: *Tree, h: Handle, moved: *u32) void {
            if (isLeaf(h)) return;
            for (0..tree.head(h).len + 1) |i| {
                // Re-fetch per child: this node itself is not moved any more, but going
                // through the handle keeps the code independent of that argument.
                const slot = &tree.kids(h)[i];
                slot.* = tree.moveIfVictim(slot.*, moved);
                tree.vacuumNode(slot.*, moved);
            }
        }

        // ---- validate / dump -------------------------------------------------------------

        /// Checks the B-tree invariants and the allocator bookkeeping: every reachable
        /// handle is live in the pool of its class, and the pools hold no other node
        /// (so a leaked or double-freed node fails here, with any backing allocator).
        pub fn validate(tree: *const Tree) error{Invalid}!void {
            var seen: Counts = .{};
            if (tree.root.isNone()) {
                if (tree.height != 0 or tree.count != 0) return error.Invalid;
            } else {
                try tree.validateNode(tree.root, 1, null, null, &seen);
            }
            if (seen.keys != tree.count) return error.Invalid;
            if (seen.leaves != tree.leaves.live or seen.interiors != tree.interiors.live) return error.Invalid;
        }

        const Counts = struct { keys: usize = 0, leaves: u32 = 0, interiors: u32 = 0 };

        fn validateNode(tree: *const Tree, h: Handle, depth: u32, lo: ?u64, hi: ?u64, seen: *Counts) error{Invalid}!void {
            const live = if (isLeaf(h)) tree.leaves.isLive(h) else tree.interiors.isLive(h);
            if (!live) return error.Invalid;
            const n = tree.head(h);
            if (n.len > max_keys or n.len == 0) return error.Invalid;
            if (h != tree.root and n.len < t - 1) return error.Invalid;
            for (n.keys[0..n.len], 0..) |k, i| {
                if (i > 0 and n.keys[i - 1] >= k) return error.Invalid;
                if (lo != null and k <= lo.?) return error.Invalid;
                if (hi != null and k >= hi.?) return error.Invalid;
            }
            seen.keys += n.len;
            if (isLeaf(h)) {
                seen.leaves += 1;
                if (depth != tree.height) return error.Invalid; // all leaves on one level
                return;
            }
            seen.interiors += 1;
            for (0..n.len + 1) |i| {
                const child_lo = if (i == 0) lo else n.keys[i - 1];
                const child_hi = if (i == n.len) hi else n.keys[i];
                try tree.validateNode(tree.kids(h)[i], depth + 1, child_lo, child_hi, seen);
            }
        }

        /// One node per line, children indented, each with its handle:
        /// `I0.0 [10]` / `  L0.1 [12 20 30]`.
        pub fn dump(tree: *const Tree, w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (tree.root.isNone()) return w.writeAll("(empty)\n");
            try tree.dumpNode(w, tree.root, 0);
        }

        fn dumpNode(tree: *const Tree, w: *std.Io.Writer, h: Handle, depth: usize) std.Io.Writer.Error!void {
            const n = tree.head(h);
            try w.splatByteAll(' ', depth * 2);
            try w.print("{f} [", .{h});
            for (n.keys[0..n.len], 0..) |k, i| try w.print("{s}{d}", .{ if (i == 0) "" else " ", k });
            try w.writeAll("]\n");
            if (!isLeaf(h)) for (0..n.len + 1) |i| try tree.dumpNode(w, tree.kids(h)[i], depth + 1);
        }
    };
}

// ---------------------------------------------------------------------------------------
const testing = std.testing;
const ops = @import("ops.zig");
const StaticAllocator = @import("static_allocator.zig").StaticAllocator;

pub const canonical_keys = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };

fn expectDump(tree: anytype, expected: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try tree.dump(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "node sizes: handles are half the size of pointers" {
    const T = BTree(4, 4);
    try testing.expectEqual(56, @sizeOf(T.Leaf)); // 3 keys + 3 values + len, padded
    try testing.expectEqual(56 + 4 * 4, @sizeOf(T.Interior)); // + four 4-byte handles
}

test "canonical example on slabs" {
    var tree: BTree(4, 4) = .init(testing.allocator, true);
    defer tree.deinit();
    for (canonical_keys) |k| {
        try tree.put(k, k * 10);
        try tree.validate();
    }
    try expectDump(&tree,
        \\I0.1 [10]
        \\  I0.0 [6]
        \\    L0.0 [1 3 5]
        \\    L0.3 [7]
        \\  I0.2 [20]
        \\    L0.1 [12 15 17]
        \\    L0.2 [25 30]
        \\
    );
    try testing.expectEqual(12, tree.count);
    try testing.expectEqual(3, tree.height);
    for (canonical_keys) |k| try testing.expectEqual(k * 10, tree.get(k).?);
    try testing.expectEqual(null, tree.get(11));
    try tree.put(12, 99); // overwrite
    try testing.expectEqual(99, tree.get(12).?);
    try testing.expectEqual(12, tree.count);
}

test "delete down to empty returns every slot" {
    var tree: BTree(4, 4) = .init(testing.allocator, true);
    defer tree.deinit();
    for (0..200) |k| try tree.put(k, k);
    try testing.expect(!tree.delete(1000));
    for (0..200) |i| {
        const k = (i * 37) % 200; // a fixed permutation
        try testing.expect(tree.delete(k));
        try tree.validate();
    }
    try testing.expect(tree.root.isNone());
    try testing.expectEqual(0, tree.leaves.live + tree.interiors.live);
    try testing.expectEqual(1, tree.leaves.slab_count); // the kept "last slab with space"
}

fn modelTest(comptime M: u8, comptime slots: u16, seed: u64) !void {
    const gpa = testing.allocator;
    var tree: BTree(M, slots) = .init(gpa, true);
    defer tree.deinit();
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var got: std.ArrayList(Entry) = .empty;
    defer got.deinit(gpa);

    var stream = ops.OpStream.init(.{ .seed = seed, .count = 4000, .key_space = 120 });
    var step: usize = 0;
    while (stream.next()) |op| : (step += 1) {
        switch (op) {
            .put => |p| {
                try tree.put(p.key, p.value);
                _ = try oracle.put(gpa, p.key, p.value);
            },
            .delete => |d| try testing.expectEqual(oracle.delete(d.key) != null, tree.delete(d.key)),
            .get => |g| try testing.expectEqual(oracle.get(g.key), tree.get(g.key)),
            .range => |r| {
                got.clearRetainingCapacity();
                try tree.range(gpa, r.lo, r.hi, &got);
                const want = oracle.range(r.lo, r.hi);
                try testing.expectEqual(want.len, got.items.len);
                for (want, got.items) |a, b| try testing.expect(a.key == b.key and a.value == b.value);
            },
        }
        try testing.expectEqual(oracle.len(), tree.count);
        // Vacuum now and then: contents must not change when nodes move.
        if (step % 500 == 499) _ = tree.vacuum();
        if (step % 16 == 0) try tree.validate();
    }
    try tree.validate();
}

test "model test against the oracle (tiny slabs force slab edges)" {
    try modelTest(4, 2, 1);
    try modelTest(4, 4, 2);
    try modelTest(6, 3, 3);
    try modelTest(8, 64, 4);
}

fn putMany(gpa: Allocator, n: u64) !void {
    var tree: BTree(4, 2) = .init(gpa, true);
    defer tree.deinit();
    for (0..n) |i| {
        const k = (i * 7) % n;
        tree.put(k, k) catch |err| {
            // The failed put changed nothing visible: tree valid, key absent.
            try tree.validate();
            try testing.expectEqual(null, tree.get(k));
            try testing.expectEqual(i, tree.count);
            return err;
        };
    }
}

test "put under every possible allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, putMany, .{@as(u64, 40)});
}

test "vacuum releases slabs and keeps the contents" {
    var tree: BTree(4, 4) = .init(testing.allocator, true);
    defer tree.deinit();
    for (1..41) |k| try tree.put(k, k);
    for (1..41) |k| {
        if (k % 4 != 0) try testing.expect(tree.delete(k));
    }
    try tree.validate();
    var before = tree.leaves.slab_count + tree.interiors.slab_count;
    // One vacuum pass frees at most one slab per pool: repeat until nothing moves.
    var moved_total: u32 = 0;
    while (true) {
        const moved = tree.vacuum();
        try tree.validate();
        if (moved == 0) break;
        moved_total += moved;
        const after = tree.leaves.slab_count + tree.interiors.slab_count;
        try testing.expect(after < before);
        before = after;
    }
    try testing.expect(moved_total > 0);
    for (1..41) |k| try testing.expectEqual(if (k % 4 == 0) @as(?u64, k) else null, tree.get(k));
    // Dense again: fewer free slots than one slab in each pool.
    try testing.expect(tree.leaves.freeSlots() < 4 and tree.interiors.freeSlots() < 4);
}

test "frozen: after reserve the tree runs without touching the allocator" {
    var static: StaticAllocator = .init(testing.allocator);
    var tree: BTree(4, 16) = .init(static.allocator(), false);
    try tree.leaves.reserve(4);
    try tree.interiors.reserve(2);
    static.freeze();

    var stream = ops.OpStream.init(.{ .seed = 9, .count = 3000, .key_space = 60 });
    while (stream.next()) |op| switch (op) {
        .put => |p| try tree.put(p.key, p.value),
        .delete => |d| _ = tree.delete(d.key),
        else => {},
    };
    try tree.validate();
    try testing.expectEqual(0, static.refused); // no allocation was even attempted

    // Exhaust the pool: the put fails cleanly, the tree stays usable.
    var k: u64 = 1000;
    while (tree.put(k, k)) |_| k += 1 else |err| try testing.expectEqual(error.OutOfMemory, err);
    try tree.validate();
    try testing.expect(static.refused >= 1);
    try testing.expectEqual(null, tree.get(k));
    try testing.expectEqual(4, tree.leaves.slab_count);

    static.thaw();
    tree.deinit();
}

// The scenario of the "Static memory" mode in viz/index.html, pinned here and in the
// Rust twin so that the page's JS model can be checked against real programs.
test "static picture: 3 + 2 slabs of 4 slots, ascending keys until the pool is dry" {
    var static: StaticAllocator = .init(testing.allocator);
    var tree: BTree(4, 4) = .init(static.allocator(), false);
    try tree.leaves.reserve(3);
    try tree.interiors.reserve(2);
    static.freeze();

    var k: u64 = 1;
    while (tree.put(k, k)) |_| k += 1 else |err| try testing.expectEqual(error.OutOfMemory, err);
    // Key 25 would fit into leaf L2.3, but top-down insertion must first split the
    // full interior node I1.3 on the way, and the interior pool has no slot left.
    try testing.expectEqual(25, k);
    try testing.expectEqual(24, tree.count);
    try testing.expectEqual(4, tree.height);
    try testing.expectEqual(0, tree.leaves.grow_failures);
    try testing.expectEqual(1, tree.interiors.grow_failures);
    try testing.expectEqual(0, tree.leaves.freeSlots() + tree.interiors.freeSlots());
    try tree.validate();
    try expectDump(&tree,
        \\I1.1 [8]
        \\  I0.1 [4]
        \\    I0.0 [2]
        \\      L0.0 [1]
        \\      L0.1 [3]
        \\    I0.2 [6]
        \\      L0.2 [5]
        \\      L0.3 [7]
        \\  I1.2 [12 16]
        \\    I0.3 [10]
        \\      L1.0 [9]
        \\      L1.1 [11]
        \\    I1.0 [14]
        \\      L1.2 [13]
        \\      L1.3 [15]
        \\    I1.3 [18 20 22]
        \\      L2.0 [17]
        \\      L2.1 [19]
        \\      L2.2 [21]
        \\      L2.3 [23 24]
        \\
    );
    // Deleting gives slots back to the pool (never to the allocator): 5 and 7 merge
    // into one leaf, their parent into its sibling, and the insert fits again.
    try testing.expect(tree.delete(7));
    try testing.expectEqual(3, tree.leaves.slab_count);
    try testing.expect(tree.leaves.freeSlots() + tree.interiors.freeSlots() > 0);
    try tree.put(25, 25);
    try tree.validate();

    static.thaw();
    tree.deinit();
}

// Copied from chapters/05-deletion-and-rebalancing/zig/src/btree.zig
//! The complete in-memory B-tree: this file only ties the sections together.
//!
//!   file          content                              needs
//!   node.zig      the node type (chapter 03)           -
//!   search.zig    get, inOrder, range (chapter 03)     node
//!   validate.zig  the invariants as code               node
//!   stats.zig     shape, fill, text rendering          node
//!   pool.zig      where nodes come from and go back to -
//!   insert.zig    put, split (chapter 04)              node, search
//!   delete.zig    delete, borrow, merge, root shrink   node, search
//!
//! Copying a part of the tree into another chapter:
//!   search only       node, search, validate, stats (trees built by hand,
//!                     or this file without `put`, `delete` and `Counters`)
//!   search + insert   the above + pool, insert, this file without `delete`
//!                     and the delete counters; tests_insert.zig
//!   everything        all of the above + delete.zig, tests_delete.zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const search = @import("search.zig");
const insert = @import("insert.zig");
const deletion = @import("delete.zig");
const validation = @import("validate.zig");
const stats = @import("stats.zig");

/// How often each structural change happened since the tree was created.
pub const Counters = struct {
    // Written by insert.zig.
    /// Node splits, including root splits.
    splits: u64 = 0,
    /// Splits of the root: each one made the tree one level taller.
    root_splits: u64 = 0,
    // Written by delete.zig.
    /// Deletes that hit a key in an interior node and replaced it with its
    /// in-order predecessor from a leaf.
    predecessor_swaps: u64 = 0,
    /// Underflows repaired by taking a key from the left sibling.
    borrows_left: u64 = 0,
    /// Underflows repaired by taking a key from the right sibling.
    borrows_right: u64 = 0,
    /// Underflows repaired by merging two siblings (one node freed).
    merges: u64 = 0,
    /// Times an empty interior root was replaced by its only child.
    root_shrinks: u64 = 0,
};

/// A B-tree of order `M` (at most M children, at most M - 1 keys per node)
/// mapping u64 keys to u64 values, with nodes from `PoolFn(Node(M))`
/// (see pool.zig: `DirectNodes`, `FreeListPool` or `StdPool`).
///
///     var tree: BTree(4, FreeListPool) = .empty;
///     defer tree.deinit(gpa);
///     _ = try tree.put(gpa, 10, 100);
pub fn BTree(comptime M: usize, comptime PoolFn: fn (type) type) type {
    return struct {
        const Self = @This();
        pub const order = M;
        pub const NodeT = node_mod.Node(M);

        /// null means the tree is empty: an empty tree owns no nodes.
        root: ?*NodeT = null,
        /// Number of keys.
        len: usize = 0,
        pool: PoolFn(NodeT) = .empty,
        counters: Counters = .{},

        pub const empty: Self = .{};

        /// Returns every node to the pool, then releases the pool itself.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (self.root) |root| self.destroySubtree(gpa, root);
            std.debug.assert(self.pool.usage.live() == 0); // a merge forgot to free a node?
            self.pool.deinit(gpa);
            self.* = undefined;
        }

        fn destroySubtree(self: *Self, gpa: Allocator, node: *NodeT) void {
            if (!node.leaf) {
                for (node.children[0 .. node.len + 1]) |child| self.destroySubtree(gpa, child.?);
            }
            self.pool.destroy(gpa, node);
        }

        pub fn get(self: *const Self, key: u64) ?u64 {
            return search.get(M, self.root, key);
        }

        /// Insert or overwrite. Returns the previous value of the key, if any.
        /// On error.OutOfMemory the tree, `counters` and `pool.usage` are
        /// exactly as before the call.
        pub fn put(self: *Self, gpa: Allocator, key: u64, value: u64) Allocator.Error!?u64 {
            return insert.put(Self, self, gpa, key, value);
        }

        /// Remove a key. Returns its value, or null if it was not present.
        /// Never allocates, so it cannot fail; `gpa` is only used to give
        /// nodes back.
        pub fn delete(self: *Self, gpa: Allocator, key: u64) ?u64 {
            return deletion.delete(Self, self, gpa, key);
        }

        /// `visitor.visit(key, value)` for every entry, ascending.
        pub fn inOrder(self: *const Self, visitor: anytype) void {
            search.inOrder(M, self.root, visitor);
        }

        /// `visitor.visit(key, value)` for every entry with lo <= key < hi, ascending.
        /// (Half-open, so the key maxInt(u64) is out of reach: see search.zig.)
        pub fn range(self: *const Self, lo: u64, hi: u64, visitor: anytype) void {
            search.range(M, self.root, lo, hi, visitor);
        }

        /// Checks every structural invariant, the key count, and that the
        /// pool's live-node counter matches the nodes reachable from the root.
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
    };
}

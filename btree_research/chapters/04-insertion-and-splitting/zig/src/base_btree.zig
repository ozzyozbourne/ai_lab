// Copied from chapters/05-deletion-and-rebalancing/zig/src/btree.zig; fixes go there first
//! Trimmed for chapter 04: no `delete`, no delete counters.
//!
//! The in-memory B-tree with search and insert: this file only ties the
//! parts together.
//!
//!   file               content                              needs
//!   base_node.zig      the node type (chapter 03)           -
//!   base_search.zig    get, inOrder, range (chapter 03)     node
//!   base_validate.zig  the invariants as code               node
//!   base_stats.zig     shape, fill, text rendering          node
//!   base_pool.zig      where nodes come from and go back to -
//!   base_insert.zig    put with bottom-up splitting         node, search
//!
//! This chapter's own files sit on top: topdown.zig (the other way to
//! insert), measure.zig (fill and split counts), scenario.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("base_node.zig");
const search = @import("base_search.zig");
const insert = @import("base_insert.zig");
const validation = @import("base_validate.zig");
const stats = @import("base_stats.zig");

/// How often each structural change happened since the tree was created.
pub const Counters = struct {
    // Written by base_insert.zig and topdown.zig.
    /// Node splits, including root splits.
    splits: u64 = 0,
    /// Splits of the root: each one made the tree one level taller.
    root_splits: u64 = 0,
};

/// A B-tree of order `M` (at most M children, at most M - 1 keys per node)
/// mapping u64 keys to u64 values, with nodes from `PoolFn(Node(M))`
/// (see base_pool.zig: `DirectNodes` or `StdPool`).
///
///     var tree: BTree(4, StdPool) = .empty;
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
        /// Teardown is total: it also works on a tree that `validate` has
        /// just rejected (a missing child is skipped; nodes that are no
        /// longer reachable are not an error here), so a test can write
        /// `defer tree.deinit(gpa)` and still assert on the error. Finding
        /// a leaked node is the job of `validate` (NodeCountMismatch) and,
        /// with `DirectNodes`, of the leak-checking test allocator; with a
        /// pooling pool `pool.deinit` frees the leaked node's memory as well.
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

        pub fn get(self: *const Self, key: u64) ?u64 {
            return search.get(M, self.root, key);
        }

        /// Insert or overwrite. Returns the previous value of the key, if any.
        /// On error.OutOfMemory the tree, `counters` and `pool.usage` are
        /// exactly as before the call.
        pub fn put(self: *Self, gpa: Allocator, key: u64, value: u64) Allocator.Error!?u64 {
            return insert.put(Self, self, gpa, key, value);
        }

        /// `visitor.visit(key, value)` for every entry, ascending.
        pub fn inOrder(self: *const Self, visitor: anytype) void {
            search.inOrder(M, self.root, visitor);
        }

        /// `visitor.visit(key, value)` for every entry with lo <= key < hi, ascending.
        /// (Half-open, so the key maxInt(u64) is out of reach: see base_search.zig.)
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

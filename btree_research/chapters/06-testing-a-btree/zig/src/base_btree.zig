// Copied from chapters/05-deletion-and-rebalancing/zig/src/btree.zig
// Changes for chapter 06: the comptime `bug` parameter (`BTreeWith`),
// `Counters` replaced by `Coverage`, `validate` takes a diagnostic, and
// `deinit` no longer aborts on a tree that `validate` has rejected.
//! The complete in-memory B-tree of chapter 05, as the system under test.
//!
//!   file               content                              needs
//!   base_node.zig      the node type (chapter 03)           -
//!   base_search.zig    get, inOrder, range (chapter 03)     node
//!   base_validate.zig  the invariants as code               node
//!   base_stats.zig     shape, fill, text rendering          node
//!   base_pool.zig      where nodes come from and go back to -
//!   base_insert.zig    put, split (chapter 04)              node, search
//!   base_delete.zig    delete, borrow, merge, root shrink   node, search
//!   coverage.zig       which branches ran (new in chapter 06)
const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("base_node.zig");
const search = @import("base_search.zig");
const insert = @import("base_insert.zig");
const deletion = @import("base_delete.zig");
const validation = @import("base_validate.zig");
const stats = @import("base_stats.zig");
const Coverage = @import("coverage.zig").Coverage;

/// The deliberately broken variants. Each one changes ONE line of
/// base_insert.zig or base_delete.zig (search for "SEAM"). Because `bug` is a
/// comptime parameter, `BTreeWith(M, P, .none)` contains no trace of the
/// faults: the `if (Tree.bug == ...)` tests are decided by the compiler and
/// the dead branch is never generated.
pub const Bug = enum {
    none,
    /// insert: a split sends the median KEY up with its left neighbour's VALUE.
    split_wrong_value,
    /// delete: a merge unlinks the emptied node but never returns it to the pool.
    merge_leaks_node,
    /// delete: a borrow between interior nodes moves the key but not the child.
    borrow_forgets_child,
    // The next two are not part of the chapter's story. They break the
    // rollback of a failed `put`, and exist so that tests.zig can show that
    // the HARNESS notices (a check nobody has seen fail is not a check).
    /// insert: a failed put hands back one reserved node too few.
    rollback_leaks_node,
    /// insert: a failed put does not restore `pool.usage`.
    rollback_keeps_usage,
    // Two uses of a node after it went back to the pool (Zig only: the Rust
    // slab panics on any access to a freed slot, so there the bug cannot
    // even be written to fail quietly).
    /// delete: root shrink frees the old root, THEN reads its only child from it.
    root_read_after_free,
    /// delete: after a merge, the `leaf` flag is read from the node the
    /// merge has just freed. It only decides which coverage point is hit.
    merge_reads_freed_flag,
};

/// The correct tree.
pub fn BTree(comptime M: usize, comptime PoolFn: fn (type) type) type {
    return BTreeWith(M, PoolFn, .none);
}

/// A B-tree of order `M` (at most M children, at most M - 1 keys per node)
/// mapping u64 keys to u64 values, with nodes from `PoolFn(Node(M))`
/// (base_pool.zig), built with the fault `bug_`.
pub fn BTreeWith(comptime M: usize, comptime PoolFn: fn (type) type, comptime bug_: Bug) type {
    return struct {
        const Self = @This();
        pub const order = M;
        pub const bug = bug_;
        pub const NodeT = node_mod.Node(M);

        /// null means the tree is empty: an empty tree owns no nodes.
        root: ?*NodeT = null,
        /// Number of keys.
        len: usize = 0,
        pool: PoolFn(NodeT) = .empty,
        /// Instrumentation, not state: it also counts failed puts.
        coverage: Coverage = .{},

        pub const empty: Self = .{};

        /// Returns every REACHABLE node to the pool, then releases the pool.
        ///
        /// Tolerant on purpose: it must be callable on a tree that `validate`
        /// has just rejected (a test wants to report the error, not abort),
        /// so it skips missing children and asserts nothing. The price: a
        /// node the tree lost track of is not freed here. With `DirectNodes`
        /// that is a leak the backing allocator reports; `validate` reports
        /// it earlier as NodeCountMismatch. fuzz.zig sidesteps the question
        /// with an arena, and does not call this at all after a failure.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            if (self.root) |root| self.destroySubtree(gpa, root);
            self.pool.deinit(gpa);
            self.* = undefined;
        }

        fn destroySubtree(self: *Self, gpa: Allocator, node: *NodeT) void {
            if (!node.leaf) {
                const slots = @min(node.len + 1, node.children.len);
                for (node.children[0..slots]) |child| if (child) |c| self.destroySubtree(gpa, c);
            }
            self.pool.destroy(gpa, node);
        }

        pub fn get(self: *const Self, key: u64) ?u64 {
            return search.get(M, self.root, key);
        }

        /// Insert or overwrite. Returns the previous value of the key, if any.
        /// On error.OutOfMemory the tree and `pool.usage` are exactly as
        /// before the call.
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
        /// (Half-open, so the key maxInt(u64) is out of reach: see base_search.zig.)
        pub fn range(self: *const Self, lo: u64, hi: u64, visitor: anytype) void {
            search.range(M, self.root, lo, hi, visitor);
        }

        /// Checks every structural invariant, the key count, and that the
        /// pool's live-node counter matches the nodes reachable from the root.
        /// `diag`, if given, receives the place of the first violation.
        pub fn validate(self: *const Self, diag: ?*validation.Diagnostic) validation.Error!void {
            try validation.validate(M, self.root, self.len, diag);
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

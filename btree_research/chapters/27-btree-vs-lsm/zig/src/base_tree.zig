// Copied from chapters/07-bplus-trees/zig/src/tree.zig; changes for chapter 27 are marked "ch27:"
//! The B+tree object: its fields and the public method names. The algorithms
//! live in one file each (search, insert, delete, walk, validate); the methods
//! here only forward, so `tree.put(...)` reads the same as in other chapters.
//!
//! Invariants (checked by `validate`):
//!   1. Entries (key + value) are stored only in leaves.
//!   2. Keys inside a node are strictly ascending.
//!   3. An internal node with k keys has k+1 children; child i holds only
//!      keys in [keys[i-1], keys[i]). Separators route; they need not exist
//!      as keys in any leaf.
//!   4. A node has at most M-1 keys; every node except the root has at least
//!      ceil(M/2)-1; an internal root has at least 1 key.
//!   5. All leaves are at the same depth (`height`).
//!   6. The leaves form a doubly linked list in key order from `first_leaf`
//!      to `last_leaf`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const arena = @import("base_arena.zig");
const node = @import("base_node.zig");
const search = @import("base_search.zig");
const insert = @import("base_insert.zig");
const delete_ = @import("base_delete.zig");
const validate_ = @import("base_validate.zig");
const device = @import("device.zig"); // ch27

pub const NodeId = arena.NodeId;
pub const Node = node.Node;

/// Counters of structural changes. Counts only; used by the demo program to
/// say what an operation did, and by tests to prove a path was exercised.
pub const Stats = struct {
    leaf_splits: usize = 0,
    internal_splits: usize = 0,
    borrows: usize = 0,
    merges: usize = 0,
};

pub const BPlusTree = struct {
    /// M: maximum number of children of an internal node (Knuth's order).
    order: usize,
    nodes: arena.Arena(Node) = .empty,
    /// `.nil` when the tree is empty.
    root: NodeId = .nil,
    /// Ends of the leaf chain; `.nil` when the tree is empty.
    first_leaf: NodeId = .nil,
    last_leaf: NodeId = .nil,
    /// Number of levels: 0 for an empty tree, 1 when the root is a leaf.
    height: usize = 0,
    /// Number of entries.
    count: usize = 0,
    stats: Stats = .{},
    /// ch27: the counted block device this tree "lives on". Every node is one
    /// block: internal nodes are index blocks, leaves are data blocks.
    dev: device.Device = .{},

    /// Does not allocate; the first `put` creates the root leaf.
    pub fn init(order: usize) BPlusTree {
        assert(order >= 3 and order <= node.max_order);
        return .{ .order = order };
    }

    pub fn deinit(self: *BPlusTree, gpa: Allocator) void {
        self.nodes.deinit(gpa);
    }

    /// Most keys a node may hold: M-1.
    pub fn maxKeys(self: *const BPlusTree) usize {
        return self.order - 1;
    }

    /// Fewest keys a non-root node may hold: ceil(M/2)-1.
    pub fn minKeys(self: *const BPlusTree) usize {
        return (self.order + 1) / 2 - 1;
    }

    pub fn len(self: *const BPlusTree) usize {
        return self.count;
    }

    /// ch27: takes `*BPlusTree` (not `*const`) because a read changes the
    /// device counters. Real buffer pools also write on a read: pin counts,
    /// usage bits.
    pub fn get(self: *BPlusTree, key: u64) ?u64 {
        defer self.dev.endOp();
        return search.get(self, key);
    }

    /// Inserts or overwrites. Returns the previous value if the key existed.
    /// On `error.OutOfMemory` the tree is unchanged.
    pub fn put(self: *BPlusTree, gpa: Allocator, key: u64, value: u64) Allocator.Error!?u64 {
        defer self.dev.endOp(); // ch27: write back every dirty node
        return insert.put(self, gpa, key, value);
    }

    /// Removes a key. Returns its value, or null if it was absent.
    /// Never allocates, so it cannot fail.
    pub fn delete(self: *BPlusTree, key: u64) ?u64 {
        defer self.dev.endOp(); // ch27
        return delete_.delete(self, key);
    }

    /// ch27: appends every entry with lo <= key < hi to `out`, ascending.
    /// One descent, then the leaf chain: height + (leaves crossed) reads.
    pub fn range(self: *BPlusTree, gpa: Allocator, lo: u64, hi: u64, out: *std.ArrayList(node.Entry)) Allocator.Error!void {
        if (lo >= hi) return;
        var walker = @import("base_walk.zig").LeafWalker.seek(self, lo);
        while (walker.next()) |e| {
            if (e.key >= hi) break;
            try out.append(gpa, e);
        }
    }

    // ------------------------------------------------ ch27: device hooks

    /// The operation in progress looks at node `id`: one block read, unless
    /// this operation already holds the block.
    pub fn touch(self: *BPlusTree, id: NodeId) void {
        const kind: device.Kind = if (self.nodes.get(id).isLeaf()) .data else .index;
        self.dev.pin(id.index(), kind);
    }

    /// The operation in progress changed node `id`: one block write at the
    /// end of the operation.
    pub fn dirty(self: *BPlusTree, id: NodeId) void {
        self.dev.markDirty(id.index());
    }

    /// Allocates a node (capacity was reserved by `put`) and its block.
    pub fn allocNode(self: *BPlusTree, n: Node) NodeId {
        const id = self.nodes.allocAssumeCapacity(n);
        self.dev.pinNew(id.index(), if (n.isLeaf()) .data else .index);
        return id;
    }

    pub fn freeNode(self: *BPlusTree, id: NodeId) void {
        self.dev.release(id.index());
        self.nodes.free(id);
    }

    /// Checks every invariant listed at the top of this file.
    pub fn validate(self: *const BPlusTree) validate_.Violation!void {
        return validate_.validate(self);
    }
};

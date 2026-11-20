//! The B-link tree object (Lehman and Yao): the node table, the latches, and
//! the public method names. The algorithms live in one file each:
//!
//!   search.zig    descent that holds ONE latch at a time and moves right
//!   insert.zig    put; a split as two separate atomic steps
//!   validate.zig  every invariant as code, including half-finished splits
//!   dump.zig      text rendering
//!
//! What a B-link tree adds to the B+tree of chapter 07:
//!
//!   high key    an upper bound on the keys a node may hold. Here it is
//!               EXCLUSIVE: a node holds keys < high_key. `null` = +infinity.
//!   right link  the handle of the next node on the SAME level (leaf or
//!               internal). `.nil` on the rightmost node of a level.
//!
//! Invariants (checked by `validate`):
//!   1. Every level is a singly linked list in key order: the high key of a
//!      node is the lower bound of its right sibling.
//!   2. A node has a high key if and only if it has a right link.
//!   3. A node is reachable from its parent level by a DOWNLINK, except the
//!      right half of a split whose second step has not happened yet. That
//!      case is marked by `incomplete_split` on its LEFT sibling.
//!   4. Keys only ever move to the right, into a NEW node. A node's id, its
//!      level and its lower bound never change; its high key only decreases.
//!
//! Invariant 4 is the whole trick. A reader that holds a stale handle (it
//! read the parent before a split) lands on a node that is still the leftmost
//! place the key could be, compares the key with the high key, and follows
//! right links until the range fits. No lock coupling is needed.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const base_node = @import("base_node.zig");
const search = @import("search.zig");
const insert = @import("insert.zig");
const validate_ = @import("validate.zig");

pub const NodeId = @import("base_handle.zig").NodeId;
pub const Node = base_node.Node;

/// More levels than any tree that fits in a u32-indexed table can have.
pub const max_levels = 32;

/// Everything in a node that the latch protects.
pub const Page = struct {
    /// Keys plus values (leaf) or children (internal): chapter 07's node.
    node: Node,
    /// 0 for a leaf, 1 for the parents of leaves, ... Never changes.
    level: u32,
    /// Exclusive upper bound of this node's key range; null = +infinity.
    high_key: ?u64 = null,
    /// Next node on the same level, or `.nil`.
    right: NodeId = .nil,
    /// Step 1 of a split happened here and step 2 has not: the node behind
    /// `right` has no downlink in the parent level yet (Postgres:
    /// BTP_INCOMPLETE_SPLIT, set on the left half).
    incomplete_split: bool = false,

    pub fn init(level: u32) Page {
        return .{ .node = if (level == 0) Node.initLeaf() else Node.initInternal(), .level = level };
    }

    /// True when `key` belongs to a node further right. This single
    /// comparison is how a concurrent split is detected.
    pub fn isBeyond(self: *const Page, key: u64) bool {
        return if (self.high_key) |hk| key >= hk else false;
    }
};

/// One entry of the node table: a latch and the page it protects.
pub const Slot = struct {
    latch: Io.RwLock = .init,
    page: Page,
};

/// Plain copy of the counters (see `BLinkTree.stats`).
pub const Stats = struct {
    /// Step 1 performed: sibling created and linked, flag set.
    half_splits: u64 = 0,
    /// Step 2 performed: downlink inserted (or new root built), flag cleared.
    completed_splits: u64 = 0,
    /// ... of which by a LATER writer that met the flag, not by the splitter.
    finished_later: u64 = 0,
    /// Right links followed by searches and by descending writers.
    moves_right: u64 = 0,
};

const Counter = std.atomic.Value(u64);

/// Test hook of `putFrom`: see insert.zig.
pub const Pause = insert.Pause;

pub const PutError = error{
    /// The preallocated node table is full. The tree content is unchanged.
    OutOfNodes,
};

pub const BLinkTree = struct {
    /// M: maximum number of children of an internal node (Knuth's order).
    order: usize,
    /// The node table. Allocated once, never grown, never moved: a `*Slot`
    /// stays valid for the life of the tree, which is what lets threads use
    /// nodes while other threads allocate new ones.
    slots: []Slot,
    /// Number of slots handed out so far. Nodes are never freed (no delete).
    allocated: std.atomic.Value(u32) = .init(0),
    /// The "metapage": where a descent starts. Readers load it without any
    /// lock. It may be stale by the time they use it, which is fine, because
    /// an old root is still a node of the tree and has a right link.
    root: std.atomic.Value(u32),
    /// Protects root changes, `height` and `level_head`. Always taken LAST
    /// (after any node latch), so it cannot be part of a deadlock cycle.
    /// (The new root is written under `meta` without a latch, see
    /// `allocPage`; Rust has to latch it there, which cannot block.)
    meta: Io.Mutex = .init,
    /// Number of levels; 1 when the root is a leaf. Guarded by `meta`.
    height: usize = 1,
    /// level_head[l] = leftmost node of level l. Set once, when the level is
    /// created by a root split, and never changed afterwards: the left half
    /// of a split keeps its id, so the leftmost node of a level is forever
    /// the node that was the root when the level was born. Guarded by `meta`.
    level_head: [max_levels]NodeId = @splat(.nil),
    /// Number of entries.
    count: Counter = .init(0),
    /// TEST HOOK. While true, every split stops after step 1, as if the
    /// writer had died between the two atomic steps.
    abandon_splits: std.atomic.Value(bool) = .init(false),

    half_splits: Counter = .init(0),
    completed_splits: Counter = .init(0),
    finished_later: Counter = .init(0),
    moves_right: Counter = .init(0),

    /// Allocates the whole node table (`capacity` nodes) and creates the
    /// root as an empty leaf. This is the only allocation the tree ever
    /// makes; `put` can therefore not fail with OutOfMemory, only with
    /// `error.OutOfNodes` when the table is used up.
    pub fn init(gpa: Allocator, order: usize, capacity: usize) Allocator.Error!BLinkTree {
        assert(order >= 3 and order <= base_node.max_order);
        assert(capacity >= 1 and capacity < std.math.maxInt(u32));
        const slots = try gpa.alloc(Slot, capacity);
        for (slots) |*slot| slot.* = .{ .page = .init(0) };
        var tree: BLinkTree = .{ .order = order, .slots = slots, .root = .init(0) };
        tree.allocated.store(1, .monotonic); // slot 0: the root leaf
        tree.level_head[0] = NodeId.fromIndex(0);
        return tree;
    }

    pub fn deinit(self: *BLinkTree, gpa: Allocator) void {
        gpa.free(self.slots);
        self.* = undefined;
    }

    /// A node holds at most M-1 keys.
    pub fn maxKeys(self: *const BLinkTree) usize {
        return self.order - 1;
    }

    /// Smallest node a split can produce: ceil(M/2)-1 keys.
    pub fn minKeys(self: *const BLinkTree) usize {
        return (self.order + 1) / 2 - 1;
    }

    pub fn len(self: *const BLinkTree) u64 {
        return self.count.load(.monotonic);
    }

    pub fn rootId(self: *const BLinkTree) NodeId {
        return @fromBackingInt(self.root.load(.acquire));
    }

    pub fn nodeCount(self: *const BLinkTree) usize {
        return self.allocated.load(.monotonic);
    }

    pub fn stats(self: *const BLinkTree) Stats {
        return .{
            .half_splits = self.half_splits.load(.monotonic),
            .completed_splits = self.completed_splits.load(.monotonic),
            .finished_later = self.finished_later.load(.monotonic),
            .moves_right = self.moves_right.load(.monotonic),
        };
    }

    /// Test hook: see `abandon_splits`.
    pub fn setAbandonSplits(self: *BLinkTree, on: bool) void {
        self.abandon_splits.store(on, .release);
    }

    // ------------------------------------------------------------ nodes

    /// Hands out the next unused slot as an empty node of `level`.
    ///
    /// The new node is NOT latched: no other thread can know its id until
    /// the caller stores it in a right link or a child slot, and it does
    /// that while holding the exclusive latch of the node it stores it in.
    pub fn allocPage(self: *BLinkTree, level: u32) PutError!NodeId {
        var used = self.allocated.load(.monotonic);
        while (true) {
            if (used >= self.slots.len) return error.OutOfNodes;
            // Compare-and-swap instead of fetchAdd, so that a failed
            // allocation never pushes the counter past the table size.
            used = self.allocated.cmpxchgWeak(used, used + 1, .acq_rel, .monotonic) orelse break;
        }
        self.slots[used].page = .init(level);
        return NodeId.fromIndex(used);
    }

    /// The page behind a handle. The caller must hold the node's latch (or
    /// be the only thread using the tree, as `validate` and `dump` require).
    pub fn page(self: *const BLinkTree, id: NodeId) *Page {
        return &self.slots[id.index()].page;
    }

    pub fn lockShared(self: *const BLinkTree, io: Io, id: NodeId) *const Page {
        const slot = &self.slots[id.index()];
        slot.latch.lockSharedUncancelable(io);
        return &slot.page;
    }

    pub fn unlockShared(self: *const BLinkTree, io: Io, id: NodeId) void {
        self.slots[id.index()].latch.unlockShared(io);
    }

    pub fn lockExclusive(self: *const BLinkTree, io: Io, id: NodeId) *Page {
        const slot = &self.slots[id.index()];
        slot.latch.lockUncancelable(io);
        return &slot.page;
    }

    pub fn unlockExclusive(self: *const BLinkTree, io: Io, id: NodeId) void {
        self.slots[id.index()].latch.unlock(io);
    }

    // ------------------------------------------------------- operations

    /// Value stored under `key`, or null. Holds one shared latch at a time.
    pub fn get(self: *BLinkTree, io: Io, key: u64) ?u64 {
        return search.lookup(self, io, key, .follow_right_links).value;
    }

    /// Like `get`, with a report of the path, and optionally with move-right
    /// switched off to show what goes wrong without it.
    pub fn lookup(self: *BLinkTree, io: Io, key: u64, mode: search.Mode) search.Lookup {
        return search.lookup(self, io, key, mode);
    }

    /// Inserts or overwrites. Returns the previous value if the key existed.
    /// Safe to call from several threads at once.
    pub fn put(self: *BLinkTree, io: Io, key: u64, value: u64) PutError!?u64 {
        return insert.put(self, io, key, value);
    }

    /// TEST HOOK: `put` that starts its descent at `start` (the leftmost node
    /// of a level, i.e. a former root) and can be paused on its leaf. See
    /// `insert.putFrom`.
    pub fn putFrom(self: *BLinkTree, io: Io, start: NodeId, key: u64, value: u64, pause: ?insert.Pause) PutError!?u64 {
        return insert.putFrom(self, io, start, key, value, pause);
    }

    /// Checks every invariant. Call only while no other thread uses the tree.
    pub fn validate(self: *const BLinkTree) validate_.Violation!void {
        return validate_.validate(self);
    }

    /// Number of nodes whose `incomplete_split` flag is set. Quiescent only.
    pub fn incompleteSplits(self: *const BLinkTree) usize {
        return validate_.incompleteSplits(self);
    }
};

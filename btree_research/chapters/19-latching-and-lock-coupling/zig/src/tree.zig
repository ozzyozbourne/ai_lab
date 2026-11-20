//! One B+tree, three ways of letting several threads use it.
//!
//!   global_mutex    one mutex around every operation. One thread at a time.
//!   global_rwlock   one reader-writer lock around every operation. Any
//!                   number of `get`s together, or one `put` alone.
//!   latch_coupling  one reader-writer LATCH per node; an operation holds
//!                   only the latches of the nodes it is working on
//!                   (coupled.zig).
//!
//! The first two wrap the plain single-threaded algorithm of plain.zig. All
//! three produce exactly the same tree for the same sequence of operations;
//! they differ only in what a second thread may do meanwhile.
//!
//! Invariants (checked by `validate`, see validate.zig):
//!   1. Entries live only in leaves; keys inside a node are strictly ascending.
//!   2. An internal node with k keys has k+1 children; child i holds only
//!      keys in [keys[i-1], keys[i]).
//!   3. A node has at most M-1 keys; every node except the root has at least
//!      ceil(M/2)-1; an internal root has at least 1 key.
//!   4. All leaves are at the same depth and are chained in key order.
//!   5. Every slot handed out by the node table is reachable from the root.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const base_node = @import("base_node.zig");
const table_ = @import("table.zig");
const plain = @import("plain.zig");
const coupled = @import("coupled.zig");
const validate_ = @import("validate.zig");

pub const NodeId = base_node.NodeId;
pub const Node = base_node.Node;

pub const Protocol = enum { global_mutex, global_rwlock, latch_coupling };

pub const Error = error{OutOfNodes};

/// Shared: many holders, all of them only read. Exclusive: one holder.
pub const Mode = enum { shared, exclusive };

/// A tree of order M >= 3 over n nodes is at most log2(n) levels deep, and a
/// table holds fewer than 2^32 nodes.
pub const max_height = 32;

/// Counters. Atomics, because under latch coupling two threads may split
/// different leaves at the same moment.
pub const Stats = struct {
    leaf_splits: std.atomic.Value(usize) = .init(0),
    internal_splits: std.atomic.Value(usize) = .init(0),
    /// Times an operation latched a node that was no longer the root and
    /// started again (latch coupling only).
    root_restarts: std.atomic.Value(usize) = .init(0),
};

/// Test hook: a callback that an operation calls at the points listed in
/// `Point`, ON ITS OWN THREAD and while holding whatever it holds at that
/// point. A test blocks inside the callback to freeze the operation there,
/// which turns "what if the other thread runs exactly now" into a
/// deterministic test. Production calls pass `null` and pay one branch.
pub const Hook = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, event: Event) void,

    pub const Point = enum {
        /// Latch coupling: the root id was read; no latch is held yet.
        root_loaded,
        /// Latch coupling: a latch on `node` was acquired.
        latched,
        /// The descent is over. Latch coupling: a `get` holds exactly the
        /// leaf (shared); a `put` holds the leaf and every unsafe ancestor
        /// (exclusive). Global protocols: the tree-wide lock is held.
        at_leaf,
        /// The lock or latch on `node` is held by someone else; the operation
        /// is about to wait for it. (`node` is `.nil` for the tree-wide lock.)
        blocked,
    };

    pub const Event = struct { point: Point, node: NodeId };
};

pub fn emit(hook: ?*const Hook, point: Hook.Point, node: NodeId) void {
    if (hook) |h| h.func(h.ctx, .{ .point = point, .node = node });
}

pub const Tree = struct {
    /// M: maximum number of children of an internal node (Knuth's order).
    order: usize,
    protocol: Protocol,
    table: table_.NodeTable,
    /// Handle of the root. Atomic, because under latch coupling a thread reads
    /// it before it holds any latch. It changes only when the root splits.
    root: std.atomic.Value(NodeId),
    /// Number of entries.
    count: std.atomic.Value(usize) = .init(0),
    stats: Stats = .{},
    /// The tree-wide lock of `global_mutex`.
    mutex: Io.Mutex = .init,
    /// The tree-wide lock of `global_rwlock`.
    rwlock: Io.RwLock = .init,

    /// Allocates the whole node table (`node_count` nodes) and creates the root
    /// as an empty leaf, so that no operation has to handle "no root yet".
    pub fn init(gpa: Allocator, order: usize, protocol: Protocol, node_count: u32) Allocator.Error!Tree {
        assert(order >= 3 and order <= base_node.max_order);
        assert(node_count >= 1);
        var table: table_.NodeTable = try .init(gpa, node_count);
        const root = table.reserve(1) catch unreachable; // node_count >= 1
        table.node(root).* = Node.initLeaf();
        return .{ .order = order, .protocol = protocol, .table = table, .root = .init(root) };
    }

    pub fn deinit(self: *Tree, gpa: Allocator) void {
        self.table.deinit(gpa);
    }

    /// Most keys a node may hold: M-1.
    pub fn maxKeys(self: *const Tree) usize {
        return self.order - 1;
    }

    /// Fewest keys a non-root node may hold: ceil(M/2)-1.
    pub fn minKeys(self: *const Tree) usize {
        return (self.order + 1) / 2 - 1;
    }

    pub fn len(self: *const Tree) usize {
        return self.count.load(.monotonic);
    }

    pub fn get(self: *Tree, io: Io, key: u64) ?u64 {
        return self.getHooked(io, key, null);
    }

    /// Inserts or overwrites. Returns the previous value if the key existed.
    /// On `error.OutOfNodes` the tree is unchanged and no lock is held.
    pub fn put(self: *Tree, io: Io, key: u64, value: u64) Error!?u64 {
        return self.putHooked(io, key, value, null);
    }

    pub fn getHooked(self: *Tree, io: Io, key: u64, hook: ?*const Hook) ?u64 {
        if (self.protocol == .latch_coupling) return coupled.get(self, io, key, hook);
        self.lockGlobal(io, .shared, hook);
        defer self.unlockGlobal(io, .shared);
        emit(hook, .at_leaf, .nil);
        return plain.get(self, key);
    }

    pub fn putHooked(self: *Tree, io: Io, key: u64, value: u64, hook: ?*const Hook) Error!?u64 {
        if (self.protocol == .latch_coupling) return coupled.put(self, io, key, value, hook);
        self.lockGlobal(io, .exclusive, hook);
        defer self.unlockGlobal(io, .exclusive);
        emit(hook, .at_leaf, .nil);
        return plain.put(self, key, value);
    }

    /// Takes the tree-wide lock. A mutex cannot tell readers from writers, so
    /// under `global_mutex` two `get`s exclude each other although neither
    /// changes anything; under `global_rwlock` they share the lock.
    fn lockGlobal(self: *Tree, io: Io, mode: Mode, hook: ?*const Hook) void {
        switch (self.protocol) {
            .global_mutex => {
                // With a hook: try first, so that the hook hears about the
                // wait before it starts. Without: just lock.
                if (hook != null and self.mutex.tryLock()) return;
                emit(hook, .blocked, .nil);
                self.mutex.lockUncancelable(io);
            },
            .global_rwlock => switch (mode) {
                .shared => {
                    if (hook != null and self.rwlock.tryLockShared(io)) return;
                    emit(hook, .blocked, .nil);
                    self.rwlock.lockSharedUncancelable(io);
                },
                .exclusive => {
                    if (hook != null and self.rwlock.tryLock(io)) return;
                    emit(hook, .blocked, .nil);
                    self.rwlock.lockUncancelable(io);
                },
            },
            .latch_coupling => unreachable,
        }
    }

    fn unlockGlobal(self: *Tree, io: Io, mode: Mode) void {
        switch (self.protocol) {
            .global_mutex => self.mutex.unlock(io),
            .global_rwlock => switch (mode) {
                .shared => self.rwlock.unlockShared(io),
                .exclusive => self.rwlock.unlock(io),
            },
            .latch_coupling => unreachable,
        }
    }

    /// Checks every invariant listed at the top of this file.
    /// QUIESCENT ONLY: call it when no operation is running (it takes no lock).
    pub fn validate(self: *const Tree) validate_.Violation!void {
        return validate_.validate(self);
    }

    /// Number of levels (1 when the root is a leaf). Quiescent only.
    pub fn height(self: *const Tree) usize {
        var levels: usize = 1;
        var id = self.root.load(.acquire);
        while (true) : (levels += 1) switch (self.table.node(id).kind) {
            .leaf => return levels,
            .internal => |*in| id = in.children[0],
        };
    }

    /// True if no lock and no latch is held. Tests call it after every
    /// scenario: a latch leaked on an error path would otherwise show up
    /// only as a hang in some later test.
    pub fn nothingLocked(self: *Tree, io: Io) bool {
        if (!self.mutex.tryLock()) return false;
        self.mutex.unlock(io);
        if (!self.rwlock.tryLock(io)) return false;
        self.rwlock.unlock(io);
        for (self.table.slots) |*slot| {
            if (!slot.latch.tryLock(io)) return false;
            slot.latch.unlock(io);
        }
        return true;
    }
};

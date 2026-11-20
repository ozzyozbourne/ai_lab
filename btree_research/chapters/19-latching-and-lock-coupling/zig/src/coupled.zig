//! Latch coupling ("crabbing"): one reader-writer latch per node.
//!
//! The rule for moving from a node to its child, for readers and writers:
//!
//!     latch the CHILD first, release the PARENT afterwards.
//!
//! For a moment the thread holds both, like a crab that puts one claw down
//! before lifting the other. The moment matters: with the parent latched,
//! nobody can split the child and move our key range out of it between
//! "read the child pointer" and "arrive at the child".
//!
//! Readers hold shared latches and so hold at most two at a time. A writer
//! holds exclusive latches and may release the ancestors only when the child
//! is SAFE: it has room for one more key, so it cannot split, so nothing
//! above it can change. A full child keeps its ancestors latched.
//!
//! Latch order: every thread acquires latches top-down along one path and
//! never waits for a latch above or beside one it holds. No cycle of waiting
//! threads can form, so there is no deadlock.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const tree_ = @import("tree.zig");
const Tree = tree_.Tree;
const NodeId = tree_.NodeId;
const Hook = tree_.Hook;
const Mode = tree_.Mode;
const emit = tree_.emit;
const search = @import("base_search.zig");
const insert = @import("insert.zig");

fn latch(tree: *Tree, io: Io, id: NodeId, mode: Mode, hook: ?*const Hook) void {
    const l = tree.table.latch(id);
    switch (mode) {
        .shared => {
            // With a hook: try first, so that the hook hears about the wait
            // before it starts. Without: just wait.
            if (hook == null or !l.tryLockShared(io)) {
                emit(hook, .blocked, id);
                l.lockSharedUncancelable(io);
            }
        },
        .exclusive => {
            if (hook == null or !l.tryLock(io)) {
                emit(hook, .blocked, id);
                l.lockUncancelable(io);
            }
        },
    }
    emit(hook, .latched, id);
}

fn unlatch(tree: *Tree, io: Io, id: NodeId, mode: Mode) void {
    switch (mode) {
        .shared => tree.table.latch(id).unlockShared(io),
        .exclusive => tree.table.latch(id).unlock(io),
    }
}

/// Latches the root and returns its id.
///
/// The root has no parent whose latch could protect the step "read the root
/// id, then latch that node". Between the two another thread may split the
/// root and publish a new one; the node we latched is then only the left
/// half of the tree. So: latch, then look at the root id AGAIN. If it still
/// names our node we own the real root, because the root id is only ever
/// changed by a thread holding the exclusive latch of the current root, and
/// we now hold a latch on that node. If not, let go and start over.
///
/// Latching a node that is no longer the root is harmless only because nodes
/// are never freed or reused (see table.zig).
fn latchRoot(tree: *Tree, io: Io, mode: Mode, hook: ?*const Hook) NodeId {
    while (true) {
        const id = tree.root.load(.acquire);
        emit(hook, .root_loaded, id);
        latch(tree, io, id, mode, hook);
        if (tree.root.load(.acquire) == id) return id;
        unlatch(tree, io, id, mode);
        _ = tree.stats.root_restarts.fetchAdd(1, .monotonic);
    }
}

pub fn get(tree: *Tree, io: Io, key: u64, hook: ?*const Hook) ?u64 {
    var id = latchRoot(tree, io, .shared, hook);
    while (true) {
        const n = tree.table.node(id);
        switch (n.kind) {
            .internal => |*in| {
                const child = in.children[search.childIndex(n.keySlice(), key)];
                latch(tree, io, child, .shared, hook); // claw down on the child ...
                unlatch(tree, io, id, .shared); //        ... then lift it off the parent
                id = child;
            },
            .leaf => |*leaf| {
                emit(hook, .at_leaf, id);
                const i = search.lowerBound(n.keySlice(), key);
                const result: ?u64 = if (i < n.len and n.keys[i] == key) leaf.values[i] else null;
                unlatch(tree, io, id, .shared);
                return result;
            },
        }
    }
}

pub fn put(tree: *Tree, io: Io, key: u64, value: u64, hook: ?*const Hook) tree_.Error!?u64 {
    // `held[0..n]`: the nodes we hold exclusive latches on, top-down. It is
    // always a contiguous piece of the path that ends at the current node.
    var held: [tree_.max_height]NodeId = undefined;
    var n: usize = 0;
    // Whether held[0] is the root (then a split may still grow the tree).
    var top_is_root = true;

    var id = latchRoot(tree, io, .exclusive, hook);
    held[n] = id;
    n += 1;
    while (true) {
        const node = tree.table.node(id);
        if (node.isLeaf()) break;
        const child = node.kind.internal.children[search.childIndex(node.keySlice(), key)];
        latch(tree, io, child, .exclusive, hook);
        // SAFE NODE RULE. A child with room for one more key will absorb
        // whatever comes up from below without splitting, so no ancestor can
        // change: release them all, top-down. (A leaf that already contains
        // the key would not split either, but we cannot know that before we
        // hold its latch, and afterwards the rule has already decided.)
        if (tree.table.node(child).len < tree.maxKeys()) {
            for (held[0..n]) |ancestor| unlatch(tree, io, ancestor, .exclusive);
            n = 0;
            top_is_root = false;
        }
        held[n] = child;
        n += 1;
        id = child;
    }
    emit(hook, .at_leaf, id);

    // Every node that can change is latched: held[0] has room (or is the
    // root), everything below it is full. On OutOfNodes nothing was changed.
    defer for (held[0..n]) |h| unlatch(tree, io, h, .exclusive);
    return insert.insertAtLeaf(tree, held[0..n], top_is_root, key, value, hook);
}

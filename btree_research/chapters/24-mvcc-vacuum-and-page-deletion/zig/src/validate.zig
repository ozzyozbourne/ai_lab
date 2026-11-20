//! `validate`: every invariant of index.zig and store.zig as code, naming the
//! first one that is broken. It trusts no handle it reads: each one is
//! checked with `isLive` before it is followed.
const std = @import("std");
const node = @import("base_node.zig");
const Db = @import("db.zig").Db;
const NodeId = @import("base_arena.zig").NodeId;

pub const Violation = error{
    /// root / first_leaf / height disagree about emptiness.
    BadRoot,
    /// A child handle is nil, out of range, or names a freed slot.
    DanglingChild,
    NodeOverfull,
    KeysNotSorted,
    /// A key lies outside the range its ancestors' separators allow.
    KeyOutOfBounds,
    UnevenLeafDepth,
    /// A page reachable from the root is half-dead or deleted.
    DeadPageInTree,
    /// The right links do not visit the tree's leaves in order.
    BrokenLeafChain,
    /// The deleted queue is not exactly the deleted pages in stamp order.
    BadDeletedQueue,
    /// An entry's tid is not a live version of the same key.
    DanglingTid,
    /// Entries and versions are not one-to-one.
    WrongCount,
    /// Two versions of one key are both undeleted.
    TwoCurrentVersions,
    /// A hint bit on an entry whose version somebody could still see.
    LyingHint,
    /// xmin/xmax/snapshot from the future, or xmax < xmin.
    BadTimestamp,
    /// Live pages that nothing accounts for, or a corrupt free list.
    ArenaLeak,
};

const Walk = struct {
    /// Next live leaf the chain should deliver (half-dead pages skipped).
    chain: NodeId,
    pages: usize = 0,
    entries: usize = 0,
    /// User key of the last undeleted version seen, to catch two of them.
    last_current: ?u64 = null,
};

pub fn validate(db: *const Db) Violation!void {
    const index = &db.index;
    const store = &db.store;
    var pages: usize = 0;
    if (index.root == .nil) {
        if (index.first_leaf != .nil or index.height != 0 or index.count != 0) return error.BadRoot;
    } else {
        if (!index.nodes.isLive(index.root)) return error.BadRoot;
        var walk: Walk = .{ .chain = index.first_leaf };
        // Half-dead pages are in the chain but not in the tree: count them
        // while skipping to the first live leaf, and again after each leaf.
        try skipHalfDead(db, &walk);
        try checkNode(db, index.root, 1, null, null, &walk);
        if (walk.chain != .nil) return error.BrokenLeafChain;
        if (walk.entries != index.count) return error.WrongCount;
        pages = walk.pages;
    }
    // Entries are unique (strictly sorted) and each names a live version, so
    // equal counts make entries and versions one-to-one.
    if (index.count != store.versions.liveCount()) return error.WrongCount;

    // The deleted queue: deleted pages only, stamps ascending, proper tail.
    var last_stamp: u64 = 0;
    var tail: NodeId = .nil;
    var id = index.deleted_head;
    while (id != .nil) : (pages += 1) {
        if (!index.nodes.isLive(id) or !index.nodes.get(id).isLeaf()) return error.BadDeletedQueue;
        const leaf = &index.nodes.get(id).kind.leaf;
        if (leaf.state != .deleted or leaf.state.deleted <= last_stamp) return error.BadDeletedQueue;
        if (leaf.state.deleted > store.now) return error.BadTimestamp;
        if (pages > index.nodes.slotCount()) return error.BadDeletedQueue; // cycle
        last_stamp = leaf.state.deleted;
        tail = id;
        id = leaf.next_deleted;
    }
    if (tail != index.deleted_tail) return error.BadDeletedQueue;

    // Tree pages + half-dead pages + deleted pages are all the live slots.
    if (pages != index.nodes.liveCount()) return error.ArenaLeak;
    const free = index.nodes.freeCount() orelse return error.ArenaLeak;
    if (free + index.nodes.liveCount() != index.nodes.slotCount()) return error.ArenaLeak;
    if (store.versions.freeCount() == null) return error.ArenaLeak;
    for (store.open[0..store.open_len]) |s| if (s > store.now) return error.BadTimestamp;
}

fn skipHalfDead(db: *const Db, walk: *Walk) Violation!void {
    while (walk.chain != .nil) {
        if (!db.index.nodes.isLive(walk.chain)) return error.BrokenLeafChain;
        const n = db.index.nodes.get(walk.chain);
        if (!n.isLeaf() or n.kind.leaf.state == .deleted) return error.BrokenLeafChain;
        if (n.kind.leaf.state == .live) return;
        if (n.len != 0) return error.BrokenLeafChain; // only empty pages die
        walk.pages += 1;
        walk.chain = n.kind.leaf.next;
    }
}

/// `lo` (inclusive) and `hi` (exclusive) are the bounds inherited from the
/// separators above; null means unbounded. Leaves are visited left to right,
/// so the visit order can be compared with the right links as we go.
fn checkNode(db: *const Db, id: NodeId, depth: usize, lo: ?u64, hi: ?u64, walk: *Walk) Violation!void {
    const index = &db.index;
    const n = index.nodes.get(id);
    const keys = n.keySlice();
    walk.pages += 1;
    if (n.len > index.maxKeys()) return error.NodeOverfull;
    for (keys, 0..) |k, i| {
        if (i > 0 and keys[i - 1] >= k) return error.KeysNotSorted;
        if (lo != null and k < lo.?) return error.KeyOutOfBounds;
        if (hi != null and k >= hi.?) return error.KeyOutOfBounds;
    }
    switch (n.kind) {
        .leaf => |*leaf| {
            if (depth != index.height) return error.UnevenLeafDepth;
            if (leaf.state != .live) return error.DeadPageInTree;
            if (walk.chain != id) return error.BrokenLeafChain;
            walk.chain = leaf.next;
            try skipHalfDead(db, walk);
            walk.entries += n.len;
            for (keys, 0..) |k, i| {
                const tid = node.tidOf(k);
                if (!db.store.versions.isLive(tid)) return error.DanglingTid;
                const v = db.store.versions.get(tid);
                if (v.key != node.userKey(k)) return error.DanglingTid;
                if (v.xmin > db.store.now or v.xmax > db.store.now) return error.BadTimestamp;
                if (v.xmax != 0 and v.xmax < v.xmin) return error.BadTimestamp;
                if (v.xmax == 0) {
                    if (walk.last_current == v.key) return error.TwoCurrentVersions;
                    walk.last_current = v.key;
                }
                if (leaf.dead[i] and !db.store.deadToAll(tid)) return error.LyingHint;
            }
        },
        .internal => {
            if (depth >= index.height) return error.UnevenLeafDepth;
            for (n.childSlice(), 0..) |child, i| {
                if (!index.nodes.isLive(child)) return error.DanglingChild;
                const child_lo = if (i == 0) lo else keys[i - 1];
                const child_hi = if (i == n.len) hi else keys[i];
                try checkNode(db, child, depth + 1, child_lo, child_hi, walk);
            }
        },
    }
}

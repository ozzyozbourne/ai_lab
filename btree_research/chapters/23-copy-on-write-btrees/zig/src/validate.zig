//! `validate`: every invariant of the copy-on-write tree as code.
//!
//! Per root (the committed root and every snapshot root), the B+tree
//! invariants of chapter 07 minus the leaf chain:
//!   1. keys in a node strictly ascending, within the bounds of the separators
//!      above; 2. at most M-1 keys, at least ceil(M/2)-1 except in the root;
//!   3. all leaves at depth `height`; 4. `count` entries in total.
//!
//! Across roots, the copy-on-write invariants:
//!   5. Within one root a page is reached exactly once: each tree is a tree.
//!      (Two DIFFERENT roots sharing a page is the whole point and is fine.)
//!   6. A page reachable from the root of transaction R was written by a
//!      transaction <= R. So no page was modified after a root that still
//!      reaches it was published; in particular no page shared by two live
//!      roots was ever modified.
//!   7. The free list, the pending list and the set reachable from the
//!      current root are pairwise disjoint and together cover every page:
//!      nothing reachable is writable, nothing is leaked.
//!   8. A page that only a snapshot reaches is pending, freed by a LATER
//!      transaction than the snapshot (so the reclamation rule protects it).
//!   9. `current` is what the two meta slots decode to.
const std = @import("std");
const Allocator = std.mem.Allocator;
const base_node = @import("base_node.zig");
const PageId = base_node.PageId;
const Meta = @import("meta.zig").Meta;
const db_ = @import("db.zig");
const Db = db_.Db;

pub const Violation = error{
    /// No meta slot has a valid checksum, or `current` is not the winner.
    BadMeta,
    /// root / height / count disagree about emptiness.
    BadRoot,
    /// A child page id is nil or out of range.
    DanglingChild,
    NodeOverfull,
    NodeUnderfull,
    KeysNotSorted,
    KeyOutOfBounds,
    UnevenLeafDepth,
    WrongCount,
    /// Invariant 5.
    PageReachedTwice,
    /// Invariant 6.
    LivePageModified,
    /// Invariant 7: a root reaches a page that is on the free list.
    ReachablePageIsFree,
    /// Invariant 7: duplicates, bad ids or wrong slot state in the free list.
    FreeListCorrupt,
    /// Invariant 7: bad pending entry, or a pending page the current root reaches.
    PendingCorrupt,
    /// Invariant 7: a page that is neither reachable, pending nor free.
    PageLeak,
    /// Invariant 8.
    SnapshotPageUnprotected,
};

const Class = enum(u8) { unknown, reachable, pending, free };

const Checker = struct {
    db: *const Db,
    /// What each page is from the point of view of the CURRENT root.
    class: []Class,
    /// For pending pages: the transaction that freed them.
    freed_by: []u64,
    /// Pages reached during the walk of one root.
    seen: []bool,
    // The root being walked:
    root_txn: u64,
    is_current: bool,
    height: usize,
    entries: u64 = 0,
};

pub fn validate(db: *const Db, gpa: Allocator) (Violation || Allocator.Error)!void {
    const n = db.store.pageCount();
    const m = Meta.pick(&db.store.meta_slots) orelse return error.BadMeta;
    if (!std.meta.eql(m, db.current) or m.page_count != n) return error.BadMeta;

    const class = try gpa.alloc(Class, n);
    defer gpa.free(class);
    const freed_by = try gpa.alloc(u64, n);
    defer gpa.free(freed_by);
    const seen = try gpa.alloc(bool, n);
    defer gpa.free(seen);
    @memset(class, .unknown);

    // Free list: valid ids, no duplicates, slots really free.
    for (db.store.free.items) |id| {
        if (id == .nil or id.index() >= n) return error.FreeListCorrupt;
        if (class[id.index()] != .unknown) return error.FreeListCorrupt;
        if (db.store.slots.items[id.index()].state != .free) return error.FreeListCorrupt;
        class[id.index()] = .free;
    }
    // Pending list: live pages, ascending by the freeing transaction, none
    // freed by a transaction that has not committed.
    var last: u64 = 0;
    for (db.pending.items) |p| {
        if (p.page == .nil or p.page.index() >= n) return error.PendingCorrupt;
        if (class[p.page.index()] != .unknown) return error.PendingCorrupt;
        if (!db.store.isLive(p.page)) return error.PendingCorrupt;
        if (p.freed_by < last or p.freed_by > m.txn_id) return error.PendingCorrupt;
        last = p.freed_by;
        class[p.page.index()] = .pending;
        freed_by[p.page.index()] = p.freed_by;
    }

    var c: Checker = .{ .db = db, .class = class, .freed_by = freed_by, .seen = seen, .root_txn = m.txn_id, .is_current = true, .height = m.height };
    try checkRoot(&c, m.root, m.count);
    // Everything else must be accounted for. (While a write transaction is
    // open, the page ids it has reserved are in none of the three sets.)
    if (!db.writer_active) {
        for (class) |cl| if (cl == .unknown) return error.PageLeak;
    }

    var prev_id: ?u64 = null;
    for (db.snapshots.items) |s| {
        if (s.refs == 0 or s.snap.id > m.txn_id) return error.BadRoot;
        if (prev_id != null and s.snap.id <= prev_id.?) return error.BadRoot;
        prev_id = s.snap.id;
        c.root_txn = s.snap.id;
        c.is_current = false;
        c.height = s.snap.height;
        try checkRoot(&c, s.snap.root, s.snap.count);
    }
}

fn checkRoot(c: *Checker, root: PageId, count: u64) Violation!void {
    @memset(c.seen, false);
    c.entries = 0;
    if (root == .nil) {
        if (c.height != 0 or count != 0) return error.BadRoot;
        return;
    }
    if (c.height == 0) return error.BadRoot;
    try checkNode(c, root, 1, null, null);
    if (c.entries != count) return error.WrongCount;
}

/// Checks the subtree rooted at `id`. `lo` (inclusive) and `hi` (exclusive)
/// are the bounds inherited from the separators above; null means unbounded.
fn checkNode(c: *Checker, id: PageId, depth: usize, lo: ?u64, hi: ?u64) Violation!void {
    const db = c.db;
    if (id == .nil or id.index() >= c.class.len) return error.DanglingChild;
    const i = id.index();
    const slot = &db.store.slots.items[i];

    if (c.seen[i]) return error.PageReachedTwice; // invariant 5
    c.seen[i] = true;
    if (slot.state != .live or c.class[i] == .free) return error.ReachablePageIsFree; // invariant 7
    if (slot.written_by > c.root_txn) return error.LivePageModified; // invariant 6
    if (c.is_current) {
        if (c.class[i] == .pending) return error.PendingCorrupt; // invariant 7
        c.class[i] = .reachable;
    } else switch (c.class[i]) {
        .reachable => {}, // shared with the current tree
        .pending => if (c.freed_by[i] <= c.root_txn) return error.SnapshotPageUnprotected, // invariant 8
        .unknown, .free => return error.SnapshotPageUnprotected,
    }

    const n = &slot.node;
    const keys = n.keySlice();
    if (n.len > db.maxKeys()) return error.NodeOverfull;
    if (n.len < (if (depth == 1) 1 else db.minKeys())) return error.NodeUnderfull;
    for (keys, 0..) |k, j| {
        if (j > 0 and keys[j - 1] >= k) return error.KeysNotSorted;
        if (lo != null and k < lo.?) return error.KeyOutOfBounds;
        if (hi != null and k >= hi.?) return error.KeyOutOfBounds;
    }
    switch (n.kind) {
        .leaf => {
            if (depth != c.height) return error.UnevenLeafDepth;
            c.entries += n.len;
        },
        .internal => {
            if (depth >= c.height) return error.UnevenLeafDepth;
            for (n.childSlice(), 0..) |child, j| {
                const child_lo = if (j == 0) lo else keys[j - 1];
                const child_hi = if (j == n.len) hi else keys[j];
                try checkNode(c, child, depth + 1, child_lo, child_hi);
            }
        },
    }
}

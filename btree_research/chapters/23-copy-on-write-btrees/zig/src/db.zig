//! `Db`: the committed state of a copy-on-write B+tree and its readers.
//!
//!   store      page slab + free list + two metapage slots   (store.zig)
//!   current    the decoded winner of the two meta slots: the committed root
//!   snapshots  one entry per root that some reader still holds, refcounted
//!   pending    pages that a commit made unreachable from ITS root, but that
//!              older roots can still reach
//!
//! The life of a page:
//!
//!     free --(written by a commit)--> live --(replaced or dropped by txn T)-->
//!     pending(T) --(no snapshot older than T remains)--> free
//!
//! THE reclamation rule: a page freed by transaction T is reachable from the
//! roots of transactions before T and from no root at or after T. A snapshot
//! with id S therefore needs it exactly when S < T, and the page may be
//! reused once every live snapshot has S >= T.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const base_node = @import("base_node.zig");
const PageId = base_node.PageId;
const Meta = @import("meta.zig").Meta;
const PageStore = @import("store.zig").PageStore;
const read = @import("read.zig");
const View = read.View;
const WriteTxn = @import("txn.zig").WriteTxn;

/// A reader's handle on one committed root. It is a plain value (four
/// numbers): what keeps the pages alive is the refcount in `Db.snapshots`,
/// which `Db.snapshot` / `Db.retain` raise and `Db.release` lowers.
pub const Snapshot = struct {
    id: u64,
    root: PageId,
    height: usize,
    count: u64,

    pub fn view(self: Snapshot, db: *const Db) View {
        return .{ .store = &db.store, .root = self.root, .height = self.height, .count = self.count };
    }
};

pub const SnapshotRef = struct { snap: Snapshot, refs: usize };

pub const PendingFree = struct { freed_by: u64, page: PageId };

pub const Stats = struct {
    commits: u64 = 0,
    aborts: u64 = 0,
    /// Committed pages copied because a transaction wanted to change them.
    pages_copied: u64 = 0,
    /// Page ids taken from the free list / by growing the store.
    pages_reused: u64 = 0,
    pages_fresh: u64 = 0,
    /// Pages moved from pending to the free list.
    pages_released: u64 = 0,
};

pub const Db = struct {
    /// M: maximum number of children of a node.
    order: usize,
    store: PageStore = .{},
    current: Meta,
    /// Ascending by snapshot id (a new snapshot always has the newest id).
    snapshots: std.ArrayList(SnapshotRef) = .empty,
    /// Ascending by `freed_by` (commits append).
    pending: std.ArrayList(PendingFree) = .empty,
    /// Single writer: at most one write transaction is open.
    writer_active: bool = false,
    stats: Stats = .{},

    /// An empty database: transaction 0 committed an empty tree into meta
    /// slot 0; slot 1 has never been written and fails its checksum.
    pub fn init(order: usize) Db {
        assert(order >= 3 and order <= base_node.max_order);
        var db: Db = .{
            .order = order,
            .current = .{ .txn_id = 0, .root = .nil, .height = 0, .count = 0, .page_count = 0 },
        };
        db.store.meta_slots[0] = db.current.encode();
        return db;
    }

    pub fn deinit(self: *Db, gpa: Allocator) void {
        assert(!self.writer_active);
        self.store.deinit(gpa);
        self.snapshots.deinit(gpa);
        self.pending.deinit(gpa);
    }

    pub fn maxKeys(self: *const Db) usize {
        return self.order - 1;
    }

    /// ceil(M/2) - 1, for every node except the root.
    pub fn minKeys(self: *const Db) usize {
        return (self.order + 1) / 2 - 1;
    }

    pub fn len(self: *const Db) u64 {
        return self.current.count;
    }

    // ------------------------------------------------------------ reads

    /// The current committed tree. Valid until the next commit; a reader that
    /// must survive commits takes a `snapshot` instead.
    pub fn view(self: *const Db) View {
        const m = self.current;
        return .{ .store = &self.store, .root = m.root, .height = m.height, .count = m.count };
    }

    pub fn get(self: *const Db, key: u64) ?u64 {
        return self.view().get(key);
    }

    pub fn range(self: *const Db, lo: u64, hi: u64) read.Range {
        return self.view().range(lo, hi);
    }

    // -------------------------------------------------------- snapshots

    /// Pins the current root. Every page it reaches stays untouched until the
    /// matching `release`, no matter how many transactions commit meanwhile.
    pub fn snapshot(self: *Db, gpa: Allocator) Allocator.Error!Snapshot {
        const m = self.current;
        const items = self.snapshots.items;
        if (items.len > 0 and items[items.len - 1].snap.id == m.txn_id) {
            items[items.len - 1].refs += 1; // second reader of the same root
            return items[items.len - 1].snap;
        }
        const snap: Snapshot = .{ .id = m.txn_id, .root = m.root, .height = m.height, .count = m.count };
        try self.snapshots.append(gpa, .{ .snap = snap, .refs = 1 });
        return snap;
    }

    /// One more reference to a root that is already pinned.
    pub fn retain(self: *Db, snap: Snapshot) Snapshot {
        self.snapshots.items[self.findSnapshot(snap.id)].refs += 1;
        return snap;
    }

    /// Drops one reference. When the last reference to the OLDEST root goes,
    /// pages that were only waiting for it move to the free list. Returns the
    /// number of pages released.
    pub fn release(self: *Db, snap: Snapshot) usize {
        const i = self.findSnapshot(snap.id);
        const entry = &self.snapshots.items[i];
        entry.refs -= 1;
        if (entry.refs > 0) return 0;
        _ = self.snapshots.orderedRemove(i);
        return self.reclaim();
    }

    fn findSnapshot(self: *const Db, id: u64) usize {
        for (self.snapshots.items, 0..) |s, i| {
            if (s.snap.id == id) return i;
        }
        unreachable; // releasing a snapshot that is not held
    }

    /// Applies the reclamation rule. Cannot fail: `store.free` always has
    /// room for every page id.
    pub fn reclaim(self: *Db) usize {
        const oldest = if (self.snapshots.items.len > 0) self.snapshots.items[0].snap.id else std.math.maxInt(u64);
        const items = self.pending.items;
        var n: usize = 0;
        // `pending` is ascending by freed_by, so the releasable entries are a prefix.
        while (n < items.len and items[n].freed_by <= oldest) : (n += 1) {
            self.store.release(items[n].page);
        }
        @memmove(items[0 .. items.len - n], items[n..]);
        self.pending.shrinkRetainingCapacity(items.len - n);
        self.stats.pages_released += n;
        return n;
    }

    // ----------------------------------------------------------- writes

    /// Opens the write transaction. Nothing it does is visible, or touches
    /// the store's pages, until `commit`.
    pub fn begin(self: *Db, gpa: Allocator) WriteTxn {
        assert(!self.writer_active);
        self.writer_active = true;
        return WriteTxn.init(self, gpa);
    }

    /// One-operation transactions. Returns the previous value, if any.
    pub fn put(self: *Db, gpa: Allocator, key: u64, value: u64) !?u64 {
        var txn = self.begin(gpa);
        errdefer txn.abort();
        const old = try txn.put(key, value);
        _ = try txn.commit(gpa);
        return old;
    }

    pub fn delete(self: *Db, gpa: Allocator, key: u64) !?u64 {
        var txn = self.begin(gpa);
        errdefer txn.abort();
        const old = try txn.delete(key);
        _ = try txn.commit(gpa);
        return old;
    }

    // ---------------------------------------------------------- restart

    pub const ReopenError = error{NoValidMeta} || Allocator.Error;

    /// What a restart does: forget all in-memory state (readers, pending
    /// list, free list), choose the meta slot by checksum and transaction id,
    /// and rebuild the free list as "every page the chosen root cannot
    /// reach". (A real engine stores the free list in the file instead of
    /// scanning; see the README.)
    pub fn reopen(self: *Db, gpa: Allocator) ReopenError!void {
        assert(!self.writer_active);
        const m = Meta.pick(&self.store.meta_slots) orelse return error.NoValidMeta;
        const reachable = try gpa.alloc(bool, m.page_count);
        defer gpa.free(reachable);
        @memset(reachable, false);

        self.current = m;
        self.snapshots.clearRetainingCapacity();
        self.pending.clearRetainingCapacity();
        // Pages past the chosen meta's page_count belong to a lost commit.
        self.store.slots.shrinkRetainingCapacity(m.page_count);
        self.store.free.clearRetainingCapacity();
        if (m.root != .nil) self.mark(m.root, reachable);
        for (self.store.slots.items, reachable, 0..) |*slot, r, i| {
            slot.state = if (r) .live else .free;
            if (!r) self.store.free.appendAssumeCapacity(.fromIndex(i));
        }
    }

    fn mark(self: *const Db, id: PageId, reachable: []bool) void {
        reachable[id.index()] = true;
        const n = &self.store.slots.items[id.index()].node;
        if (n.isLeaf()) return;
        for (n.childSlice()) |child| self.mark(child, reachable);
    }
};

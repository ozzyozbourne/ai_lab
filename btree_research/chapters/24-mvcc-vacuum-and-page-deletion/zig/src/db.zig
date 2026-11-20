//! `Db` = version store + index, and the operations that need both:
//! `put` / `delete` (writers), `Cursor` and `get` (snapshot readers that
//! leave hints behind), and `vacuum`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const node = @import("base_node.zig");
const index_ = @import("index.zig");
const store_ = @import("store.zig");
const validate_ = @import("validate.zig");
const Index = index_.Index;
const NodeId = index_.NodeId;
const Store = store_.Store;

pub const Row = struct { key: u64, value: u64 };

/// What readers did. Kept apart from `Index.Stats` because these are costs
/// of reading, not changes to the tree.
pub const ReadStats = struct {
    /// Version-store lookups made to decide visibility ("heap visits").
    heap_fetches: usize = 0,
    /// Entries skipped because of their hint bit: a heap visit saved.
    hint_skips: usize = 0,
    hints_set: usize = 0,
    /// Times a scan landed on a half-dead or deleted page and moved right.
    moved_right: usize = 0,
};

pub const VacuumOptions = struct {
    /// false = only remove entries; leave empty pages in place.
    delete_pages: bool = true,
};

pub const VacuumReport = struct {
    horizon: u64,
    entries_removed: usize = 0,
    pages_unlinked: usize = 0,
    pages_recycled: usize = 0,
    /// Deleted pages that some snapshot still forces us to keep.
    pages_waiting: usize = 0,
};

pub const Db = struct {
    store: Store = .{},
    index: Index,
    reads: ReadStats = .{},

    pub fn init(order: usize) Db {
        return .{ .index = .init(order) };
    }

    pub fn deinit(self: *Db, gpa: Allocator) void {
        self.index.deinit(gpa);
        self.store.deinit(gpa);
    }

    // ------------------------------------------------------------ writers

    /// The tid of the version of `key` that no transaction has deleted yet.
    /// A writer's lookup: it wants the latest state, not a snapshot.
    fn current(self: *const Db, key: u64) ?store_.Tid {
        var id = self.index.findLeaf(node.packLow(key));
        while (id != .nil) : (id = self.index.nodes.get(id).kind.leaf.next) {
            const n = self.index.nodes.get(id);
            if (n.kind.leaf.state != .live) continue;
            for (n.keySlice()) |index_key| {
                if (node.userKey(index_key) < key) continue;
                if (node.userKey(index_key) > key) return null;
                const tid = node.tidOf(index_key);
                if (self.store.versions.get(tid).xmax == 0) return tid;
            }
        }
        return null;
    }

    /// Insert or update. An update does NOT overwrite: it ends the current
    /// version (sets its xmax) and adds a new version with a new index entry.
    /// Returns the previous value. On error.OutOfMemory nothing has changed.
    pub fn put(self: *Db, gpa: Allocator, key: u64, value: u64) Allocator.Error!?u64 {
        // Reserve everything that can fail before changing anything.
        try self.store.versions.reserve(gpa, 1);
        try self.index.reserveForInsert(gpa);
        const xid = self.store.tick();
        var old: ?u64 = null;
        if (self.current(key)) |tid| {
            const v = self.store.versions.ptr(tid);
            v.xmax = xid;
            old = v.value;
        }
        const tid = self.store.versions.allocAssumeCapacity(.{ .key = key, .value = value, .xmin = xid });
        self.index.insertReserved(&self.store, node.pack(key, tid));
        return old;
    }

    /// Delete = write one number. The index is not touched at all: its entry
    /// stays, because snapshots older than this transaction still need it.
    pub fn delete(self: *Db, key: u64) ?u64 {
        const tid = self.current(key) orelse return null;
        const v = self.store.versions.ptr(tid);
        v.xmax = self.store.tick();
        return v.value;
    }

    // ------------------------------------------------------------ readers

    /// Takes `*Db`, not `*const Db`: a read may set hint bits.
    pub fn get(self: *Db, snapshot: u64, key: u64) Cursor.Error!?u64 {
        var cursor = Cursor.seek(self, snapshot, key, key + 1);
        const row = try cursor.next(self) orelse return null;
        return row.value;
    }

    // ------------------------------------------------------------- vacuum

    /// Walks the leaf chain once and
    ///   1. removes every entry whose version is dead to the horizon,
    ///   2. finishes page deletions that stopped after phase 1,
    ///   3. deletes (both phases) the leaves it emptied, where allowed,
    ///   4. recycles the deleted pages that no snapshot can reach any more.
    /// Never allocates, so it cannot fail.
    pub fn vacuum(self: *Db, options: VacuumOptions) VacuumReport {
        var report: VacuumReport = .{ .horizon = self.store.horizon() };
        const index = &self.index;
        var left: NodeId = .nil; // chain predecessor of `id`
        var id = index.first_leaf;
        while (id != .nil) {
            const n = index.nodes.ptr(id);
            const next = n.kind.leaf.next;
            if (n.kind.leaf.state == .live) {
                const removed = index.removeWhere(&self.store, n, .dead_to_all);
                index.stats.vacuum_deleted += removed;
                report.entries_removed += removed;
                if (n.len == 0 and options.delete_pages) _ = index.markHalfDead(id);
            }
            if (n.kind.leaf.state == .half_dead and options.delete_pages) {
                index.unlinkHalfDead(&self.store, left, id);
                report.pages_unlinked += 1;
            } else {
                left = id; // still in the chain: it is the next page's predecessor
            }
            id = next;
        }
        // The unlinks above advanced the epoch; ask for the horizon again.
        report.pages_recycled = index.recycle(self.store.horizon());
        var waiting = index.deleted_head;
        while (waiting != .nil) : (waiting = index.nodes.get(waiting).kind.leaf.next_deleted) {
            report.pages_waiting += 1;
        }
        return report;
    }

    pub fn validate(self: *const Db) validate_.Violation!void {
        return validate_.validate(self);
    }
};

/// A forward scan under one snapshot.
///
/// It works the way a Postgres index scan does: read ONE leaf completely,
/// copy out what the snapshot can see, remember the page's right link, and
/// only then hand rows to the caller. Between two calls the cursor therefore
/// holds no pointer INTO a page, only the handle of the page it will read
/// next. That handle is the whole problem of page deletion: the page may be
/// emptied, half-dead or deleted by the time the cursor follows it.
///
/// The cursor is plain data and does not borrow the Db; every call is given
/// the Db again, so writers and VACUUM can run between calls.
/// The caller must keep `snapshot` open for as long as the cursor is used.
pub const Cursor = struct {
    snapshot: u64,
    /// First page: skip index keys below this. Later pages hold only larger ones.
    lo: u64,
    /// Stop before the first user key >= hi.
    hi: u64,
    /// The page to read when the buffer runs out (`.nil` = end of chain).
    next_leaf: NodeId,
    rows: [node.key_capacity]Row = undefined,
    len: usize = 0,
    pos: usize = 0,

    pub const Error = error{
        /// The saved link names a page that has been recycled. Cannot happen
        /// unless a page was recycled while this cursor's snapshot was open.
        DanglingLink,
    };

    /// Positions before the first row with lo <= key < hi. Reads nothing yet.
    pub fn seek(db: *const Db, snapshot: u64, lo: u64, hi: u64) Cursor {
        assert(db.store.isOpen(snapshot));
        return .{ .snapshot = snapshot, .lo = node.packLow(lo), .hi = hi, .next_leaf = db.index.findLeaf(node.packLow(lo)) };
    }

    pub fn next(self: *Cursor, db: *Db) Error!?Row {
        while (self.pos == self.len) {
            if (!try self.readPage(db)) return null;
        }
        self.pos += 1;
        return self.rows[self.pos - 1];
    }

    /// Fills the buffer from the next live page. Returns false at the end.
    fn readPage(self: *Cursor, db: *Db) Error!bool {
        var id = self.next_leaf;
        self.len = 0;
        self.pos = 0;
        const n = while (true) {
            if (id == .nil) {
                self.next_leaf = .nil;
                return false;
            }
            if (!db.index.nodes.isLive(id)) return error.DanglingLink;
            const page = db.index.nodes.ptr(id);
            if (!page.isLeaf()) return error.DanglingLink;
            // Half-dead or deleted: nothing to read, and the page's own right
            // link still leads to everything that used to be to its right.
            if (page.kind.leaf.state == .live) break page;
            db.reads.moved_right += 1;
            id = page.kind.leaf.next;
        };
        for (n.keySlice(), 0..) |index_key, i| {
            if (index_key < self.lo) continue;
            if (node.userKey(index_key) >= self.hi) {
                self.next_leaf = .nil; // nothing further right can qualify
                return self.len > 0;
            }
            if (n.kind.leaf.dead[i]) {
                db.reads.hint_skips += 1;
                continue;
            }
            const tid = node.tidOf(index_key);
            const v = db.store.versions.get(tid);
            db.reads.heap_fetches += 1;
            if (Store.visible(v, self.snapshot)) {
                self.rows[self.len] = .{ .key = v.key, .value = v.value };
                self.len += 1;
            } else if (db.store.deadToAll(tid)) {
                // Not just invisible to me: invisible to everyone, for ever.
                // Leave a note so that the next reader skips the heap visit
                // and the next insert on a full page can drop the entry.
                n.kind.leaf.dead[i] = true;
                db.reads.hints_set += 1;
            }
        }
        self.next_leaf = n.kind.leaf.next;
        return true;
    }
};

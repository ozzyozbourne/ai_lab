//! `Db`: the committed state of a copy-on-write B+tree and its readers.
//!
//!   store      page slab + free list + two metapage slots   (store.zig)
//!   current    the decoded winner of the two meta slots: the committed root
//!   previous   the root in the OTHER meta slot: where a restart lands if the
//!              newest slot cannot be read
//!   snapshots  one entry per root that some reader still holds, refcounted
//!   pending    pages that a commit made unreachable from ITS root, but that
//!              older roots can still reach
//!
//! The life of a page:
//!
//!     free --(written by a commit)--> live --(replaced or dropped by txn T)-->
//!     pending(T) --(no protected root older than T remains)--> free
//!
//! THE reclamation rule: a page freed by transaction T is reachable from the
//! roots of transactions before T and from no root at or after T. A root with
//! id R therefore needs it exactly when R < T, and the page may be reused
//! once every PROTECTED root has R >= T. Two kinds of root are protected:
//!
//!   * every snapshot, for as long as a reader holds it;
//!   * `previous`, the root of the commit before the current one, for as
//!     long as its meta slot can still be chosen by a restart. Its slot is
//!     overwritten by the NEXT commit, so pages freed by transaction T become
//!     reusable when T+1 has committed, and not before.
//!
//! The second line is what makes two meta slots worth having. At every
//! moment, also in the middle of a commit, the trees of BOTH slots are
//! complete: whichever slot a restart is able to read names a whole tree.
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
    /// The committed root one commit back, as recorded in the other meta
    /// slot. null when that slot holds nothing (a new database, or after a
    /// restart that could not use it and scrubbed it). `reclaim` treats it like a
    /// snapshot that nobody can release early.
    previous: ?Meta = null,
    /// Fault injection for the tests and the demo: when set, the next commit
    /// "loses power" after this many device writes (one per page, then one
    /// per byte of the meta slot) and returns `error.Crashed`.
    crash_after: ?usize = null,
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
        // The oldest root that must stay complete: the oldest snapshot, or
        // the previous committed root, whichever is older.
        var oldest: u64 = std.math.maxInt(u64);
        if (self.snapshots.items.len > 0) oldest = self.snapshots.items[0].snap.id;
        if (self.previous) |p| oldest = @min(oldest, p.txn_id);
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
        defer txn.abort(); // no-op after a successful commit
        const old = try txn.put(key, value);
        _ = try txn.commit(gpa);
        return old;
    }

    pub fn delete(self: *Db, gpa: Allocator, key: u64) !?u64 {
        var txn = self.begin(gpa);
        defer txn.abort(); // no-op after a successful commit
        const old = try txn.delete(key);
        _ = try txn.commit(gpa);
        return old;
    }

    // ---------------------------------------------------------- restart

    pub const ReopenError = error{ NoValidMeta, CorruptTree } || Allocator.Error;

    /// What a restart does. Only the "file" is trusted: the two meta slots
    /// and the pages (content and `written_by`). Everything else (readers,
    /// pending list, free list, slot states) is rebuilt:
    ///
    ///   1. choose the meta slot by checksum and transaction id;
    ///   2. walk its tree and CHECK it while walking (`treeIsComplete`);
    ///   3. if the other slot holds an older commit with a complete tree, it
    ///      stays the fallback: the pages only it reaches go back on the
    ///      pending list;
    ///   4. otherwise the other slot is SCRUBBED (overwritten with zeroes)
    ///      before anything else changes: see below;
    ///   5. every page neither root reaches is free.
    ///
    /// (A real engine stores the free list in the file instead of scanning;
    /// see the README.) On error nothing has been changed.
    ///
    /// Why step 4. Step 5 gives away the pages of every tree this restart
    /// did not keep. If the slot of such a tree were left as it is and read
    /// correctly at a LATER restart (the read error was transient), it would
    /// win again by transaction id and name a tree whose pages are gone or,
    /// worse, rewritten by a transaction that reused its id. A slot that a
    /// restart has decided against must never be chosen again, so it is
    /// overwritten first. After `reopen` each slot holds `current`, holds
    /// `previous`, or is all zeroes.
    ///
    /// `error.NoValidMeta`: neither slot has a valid checksum.
    /// `error.CorruptTree`: the chosen slot has a valid checksum but its tree
    /// is not all there. The reclamation rule guarantees this cannot happen
    /// after a crash, a torn meta write or one unreadable slot, so it means
    /// damage this design does not defend against (a lost page write, a
    /// forged slot), and it is reported instead of guessed around.
    pub fn reopen(self: *Db, gpa: Allocator) ReopenError!void {
        assert(!self.writer_active);
        const seen = self.store.readMeta(); // what this restart is able to read
        const slots = &seen;
        const m = Meta.pick(slots) orelse return error.NoValidMeta;
        if (m.page_count > self.store.pageCount()) return error.CorruptTree;
        const n: usize = m.page_count;

        const in_current = try gpa.alloc(bool, n);
        defer gpa.free(in_current);
        const in_previous = try gpa.alloc(bool, n);
        defer gpa.free(in_previous);
        if (!self.treeIsComplete(m, in_current)) return error.CorruptTree;

        // The other slot is a fallback only if its tree is whole as well.
        var previous = Meta.fallback(slots);
        if (previous) |p| {
            if (p.page_count > n or !self.treeIsComplete(p, in_previous)) previous = null;
        }
        if (previous == null) @memset(in_previous, false);
        var only_previous: usize = 0;
        for (in_current, in_previous) |c, p| {
            if (p and !c) only_previous += 1;
        }
        try self.pending.ensureTotalCapacity(gpa, only_previous);

        // Nothing can fail from here on. The scrub is the first write: until
        // it is done no page has been given away, so a crash in the middle
        // of it leaves every tree as it was.
        if (previous == null) {
            for (&self.store.meta_slots, slots) |*slot, *read_back| {
                const kept = if (Meta.decode(read_back)) |d| std.meta.eql(d, m) else false;
                if (!kept) slot.* = @splat(0);
            }
        }
        self.current = m;
        self.previous = previous;
        self.crash_after = null;
        self.snapshots.clearRetainingCapacity();
        self.pending.clearRetainingCapacity();
        // Pages past the chosen meta's page_count belong to a lost commit.
        self.store.slots.shrinkRetainingCapacity(n);
        self.store.free.clearRetainingCapacity();
        for (self.store.slots.items, in_current, in_previous, 0..) |*slot, c, p, i| {
            slot.state = if (c or p) .live else .free;
            if (c) continue;
            if (p) {
                // Replaced by the current commit; released when the next
                // commit overwrites the fallback slot.
                self.pending.appendAssumeCapacity(.{ .freed_by = m.txn_id, .page = .fromIndex(i) });
            } else {
                self.store.free.appendAssumeCapacity(.fromIndex(i));
            }
        }
    }

    /// Walks the tree a meta slot names, marking its pages, and reports
    /// whether it is all there. A valid checksum only says the 32 bytes of
    /// the slot are intact; it says nothing about the pages. So the walk
    /// trusts nothing: every page id is range-checked, a page may be reached
    /// only once (no cycles), it must have been written by a transaction no
    /// later than the slot's, and `height` and `count` must come out right.
    /// The recursion is at most `max_height` deep whatever the input.
    fn treeIsComplete(self: *const Db, m: Meta, marks: []bool) bool {
        @memset(marks, false);
        if (m.root == .nil) return m.height == 0 and m.count == 0;
        if (m.height == 0 or m.height > read.max_height) return false;
        var entries: u64 = 0;
        return self.markChecked(m, m.root, 1, marks, &entries) and entries == m.count;
    }

    fn markChecked(self: *const Db, m: Meta, id: PageId, depth: usize, marks: []bool, entries: *u64) bool {
        if (id == .nil or id.index() >= marks.len) return false;
        if (marks[id.index()]) return false;
        marks[id.index()] = true;
        const slot = &self.store.slots.items[id.index()];
        // 0 = never written (its content is undefined: do not even look).
        if (slot.written_by == 0 or slot.written_by > m.txn_id) return false;
        const n = &slot.node;
        if (n.len > self.maxKeys()) return false;
        if (n.isLeaf()) {
            entries.* += n.len;
            return depth == m.height;
        }
        if (depth >= m.height) return false;
        for (n.childSlice()) |child| {
            if (!self.markChecked(m, child, depth + 1, marks, entries)) return false;
        }
        return true;
    }
};

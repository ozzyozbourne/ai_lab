//! `WriteTxn`: the write transaction. Path copying happens here.
//!
//! A transaction never changes a committed page. Before it modifies a page it
//! calls `touch`, which copies the page into the transaction's ARENA under a
//! brand-new page id and remembers the old id as "freed by this transaction".
//! The parent must then point at the new id, so the parent is copied too, and
//! so on up to the root: every modification copies one root-to-leaf path and
//! shares everything else with the previous tree.
//!
//! Memory: everything the transaction builds (page copies, the dirty map,
//! its lists) is allocated from one arena.
//!   abort   = hand back the page ids, free the arena. The store was never
//!             written, so there is nothing to undo.
//!   commit  = copy the dirty pages into their (free) slots, write the meta
//!             slot, free the arena.
//!
//! Errors: if `put` or `delete` fails (OutOfMemory) the transaction's private
//! tree may be half modified. That is harmless, because nobody else can see
//! it: the transaction is marked `failed`, `commit` refuses it, and `abort`
//! throws it away.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const base_node = @import("base_node.zig");
const Node = base_node.Node;
const PageId = base_node.PageId;
const search = @import("base_search.zig");
const read = @import("read.zig");
const Db = @import("db.zig").Db;

/// What one commit did; the demo program prints it.
pub const CommitInfo = struct {
    /// 0 for a transaction that changed nothing (no commit happened).
    txn_id: u64 = 0,
    /// Committed pages replaced by a copy.
    copied: usize = 0,
    /// Page ids taken from the free list / by growing the store.
    reused: usize = 0,
    fresh: usize = 0,
    /// Committed pages this transaction made unreachable (now pending).
    freed: usize = 0,
    /// Pending pages that became free right after the commit.
    released: usize = 0,
};

pub const WriteTxn = struct {
    db: *Db,
    arena: std.heap.ArenaAllocator,
    /// The id this transaction gets if it commits.
    id: u64,
    // The transaction's private idea of the tree.
    root: PageId,
    height: usize,
    count: u64,
    /// New and copied pages by page id. A page in here belongs to this
    /// transaction alone and may be modified in place as often as needed.
    dirty: read.DirtyMap = .empty,
    /// Committed pages replaced or dropped by this transaction.
    freed: std.ArrayList(PageId) = .empty,
    /// Dirty pages dropped again (merged away); they were never committed,
    /// so no root can reach them and they go straight to the free list.
    scrapped: std.ArrayList(PageId) = .empty,
    /// Page ids popped from the store's free list (returned on abort).
    taken: std.ArrayList(PageId) = .empty,
    /// Next page id past the end of the store (the "file" grows at commit).
    next_new: usize,
    info: CommitInfo = .{},
    failed: bool = false,

    pub fn init(db: *Db, gpa: Allocator) WriteTxn {
        const m = db.current;
        return .{
            .db = db,
            .arena = .init(gpa),
            .id = m.txn_id + 1,
            .root = m.root,
            .height = m.height,
            .count = m.count,
            .next_new = db.store.pageCount(),
        };
    }

    pub fn view(self: *const WriteTxn) read.View {
        return .{ .store = &self.db.store, .dirty = &self.dirty, .root = self.root, .height = self.height, .count = self.count };
    }

    /// Reads see the transaction's own uncommitted changes.
    pub fn get(self: *const WriteTxn, key: u64) ?u64 {
        return self.view().get(key);
    }

    // ------------------------------------------------------ page plumbing

    const Page = struct { id: PageId, node: *Node };

    /// A new private page holding `content`, under a page id nobody uses.
    fn allocPage(self: *WriteTxn, content: Node) Allocator.Error!Page {
        const a = self.arena.allocator();
        // Everything that can fail comes first, so that a failure leaves the
        // free list and the dirty map consistent.
        const node = try a.create(Node);
        try self.dirty.ensureUnusedCapacity(a, 1);
        try self.taken.ensureUnusedCapacity(a, 1);
        node.* = content;
        var id: PageId = undefined;
        if (self.db.store.free.pop()) |reusable| {
            id = reusable;
            self.taken.appendAssumeCapacity(id);
            self.info.reused += 1;
        } else {
            id = .fromIndex(self.next_new);
            self.next_new += 1;
            self.info.fresh += 1;
        }
        self.dirty.putAssumeCapacityNoClobber(id, node);
        return .{ .id = id, .node = node };
    }

    /// Returns a page this transaction may modify, with the same content as
    /// page `id`. THE copy-on-write step:
    ///   * already dirty: it is ours, use it (a page is copied at most once
    ///     per transaction);
    ///   * committed: copy it to a new page id; the old page stays as it is
    ///     for older roots and is recorded in `freed`.
    /// The caller must store the returned id where the old id was.
    fn touch(self: *WriteTxn, id: PageId) Allocator.Error!Page {
        if (self.dirty.get(id)) |node| return .{ .id = id, .node = node };
        try self.freed.ensureUnusedCapacity(self.arena.allocator(), 1);
        const copy = try self.allocPage(self.db.store.read(id).*);
        self.freed.appendAssumeCapacity(id);
        self.info.copied += 1;
        return copy;
    }

    /// Page `id` is no longer part of this transaction's tree.
    fn discard(self: *WriteTxn, id: PageId) Allocator.Error!void {
        const a = self.arena.allocator();
        if (self.dirty.contains(id)) {
            try self.scrapped.append(a, id);
            _ = self.dirty.remove(id);
        } else {
            try self.freed.append(a, id);
        }
    }

    /// Read-only access to a page of this transaction's tree.
    fn peek(self: *const WriteTxn, id: PageId) *const Node {
        return self.dirty.get(id) orelse self.db.store.read(id);
    }

    // -------------------------------------------------------------- put

    const Split = struct { separator: u64, right: PageId };
    const Outcome = union(enum) { replaced: u64, inserted, split: Split };
    /// `id` is where the visited page lives NOW (its copy).
    const PutResult = struct { id: PageId, outcome: Outcome };

    /// Insert or overwrite. Returns the previous value, if any.
    pub fn put(self: *WriteTxn, key: u64, value: u64) Allocator.Error!?u64 {
        assert(!self.failed);
        errdefer self.failed = true;
        if (self.root == .nil) {
            const leaf = try self.allocPage(Node.initLeaf());
            leaf.node.leafInsertAt(0, key, value);
            self.root = leaf.id;
            self.height = 1;
            self.count = 1;
            return null;
        }
        const r = try self.insertInto(self.root, key, value);
        self.root = r.id; // the root moved: this is what the meta flip publishes
        switch (r.outcome) {
            .replaced => |old| return old,
            .inserted => {},
            .split => |s| {
                // The root split: a new root above the two halves.
                const new_root = try self.allocPage(Node.initInternal());
                new_root.node.kind.internal.children[0] = r.id;
                new_root.node.internalInsertAt(0, s.separator, s.right);
                self.root = new_root.id;
                self.height += 1;
            },
        }
        self.count += 1;
        return null;
    }

    fn insertInto(self: *WriteTxn, id: PageId, key: u64, value: u64) Allocator.Error!PutResult {
        // Copy on the way DOWN: by the time we change anything, this page is
        // private. The pointer stays valid: arena memory never moves.
        const page = try self.touch(id);
        const n = page.node;
        const max = self.db.maxKeys();
        switch (n.kind) {
            .leaf => |*leaf| {
                const i = search.lowerBound(n.keySlice(), key);
                if (i < n.len and n.keys[i] == key) {
                    const old = leaf.values[i];
                    leaf.values[i] = value;
                    return .{ .id = page.id, .outcome = .{ .replaced = old } };
                }
                n.leafInsertAt(i, key, value);
                if (n.len <= max) return .{ .id = page.id, .outcome = .inserted };
                return .{ .id = page.id, .outcome = .{ .split = try self.splitLeaf(n) } };
            },
            .internal => |*in| {
                const i = search.childIndex(n.keySlice(), key);
                const r = try self.insertInto(in.children[i], key, value);
                // The child was copied to a new page id: repoint. This write
                // is the reason the parent had to be copied as well.
                in.children[i] = r.id;
                switch (r.outcome) {
                    .replaced, .inserted => return .{ .id = page.id, .outcome = r.outcome },
                    .split => |s| {
                        n.internalInsertAt(i, s.separator, s.right);
                        if (n.len <= max) return .{ .id = page.id, .outcome = .inserted };
                        return .{ .id = page.id, .outcome = .{ .split = try self.splitInternal(n) } };
                    },
                }
            },
        }
    }

    /// Splits a (private) leaf holding M entries. COPY-UP as in chapter 07,
    /// minus the sibling-link splicing: there is no chain to maintain.
    fn splitLeaf(self: *WriteTxn, left: *Node) Allocator.Error!Split {
        const right = (try self.allocPage(Node.initLeaf()));
        const mid = left.len / 2;
        const moved = left.len - mid;
        @memcpy(right.node.keys[0..moved], left.keys[mid..left.len]);
        @memcpy(right.node.kind.leaf.values[0..moved], left.kind.leaf.values[mid..left.len]);
        right.node.len = moved;
        left.len = mid;
        return .{ .separator = right.node.keys[0], .right = right.id };
    }

    /// Splits a (private) internal node holding M separators. PUSH-UP.
    fn splitInternal(self: *WriteTxn, left: *Node) Allocator.Error!Split {
        const right = try self.allocPage(Node.initInternal());
        const mid = left.len / 2;
        const separator = left.keys[mid];
        const moved = left.len - mid - 1;
        @memcpy(right.node.keys[0..moved], left.keys[mid + 1 .. left.len]);
        @memcpy(
            right.node.kind.internal.children[0 .. moved + 1],
            left.kind.internal.children[mid + 1 .. left.len + 1],
        );
        right.node.len = moved;
        left.len = mid;
        return .{ .separator = separator, .right = right.id };
    }

    // ----------------------------------------------------------- delete

    const DeleteResult = struct { id: PageId, removed: u64 };

    /// Removes `key`. Returns its value, or null if it was not there.
    pub fn delete(self: *WriteTxn, key: u64) Allocator.Error!?u64 {
        assert(!self.failed);
        errdefer self.failed = true;
        // Look before you copy: a miss must not copy a path for nothing.
        if (self.get(key) == null) return null;
        const r = try self.deleteFrom(self.root, key);
        self.root = r.id;
        self.count -= 1;

        const root = self.peek(self.root);
        if (root.len == 0) {
            const old_root = self.root;
            switch (root.kind) {
                .leaf => self.root = .nil, // last entry gone
                .internal => |*in| self.root = in.children[0], // one child left
            }
            self.height -= 1;
            try self.discard(old_root);
        }
        return r.removed;
    }

    fn deleteFrom(self: *WriteTxn, id: PageId, key: u64) Allocator.Error!DeleteResult {
        const page = try self.touch(id);
        const n = page.node;
        switch (n.kind) {
            .leaf => {
                const i = search.lowerBound(n.keySlice(), key);
                assert(i < n.len and n.keys[i] == key);
                return .{ .id = page.id, .removed = n.leafRemoveAt(i).value };
            },
            .internal => |*in| {
                const i = search.childIndex(n.keySlice(), key);
                const r = try self.deleteFrom(in.children[i], key);
                in.children[i] = r.id;
                if (self.peek(r.id).len < self.db.minKeys()) try self.rebalance(n, i);
                return .{ .id = page.id, .removed = r.removed };
            },
        }
    }

    /// Child `i` of the private node `parent` is one key short. Same order of
    /// preference as chapter 07 (borrow left, borrow right, merge left, merge
    /// right), but the COSTS are different here:
    ///   borrow  the sibling changes, so the sibling is COPIED (one extra page);
    ///   merge   the sibling is only read and then freed (no extra copy).
    fn rebalance(self: *WriteTxn, parent: *Node, i: usize) Allocator.Error!void {
        const children = &parent.kind.internal.children;
        const min = self.db.minKeys();
        if (i > 0 and self.peek(children[i - 1]).len > min) {
            try self.borrowFromLeft(parent, i);
        } else if (i < parent.len and self.peek(children[i + 1]).len > min) {
            try self.borrowFromRight(parent, i);
        } else if (i > 0) {
            try self.merge(parent, i - 1, .right);
        } else {
            try self.merge(parent, i, .left);
        }
    }

    /// Moves the last item of the left sibling to the front of child `i`.
    fn borrowFromLeft(self: *WriteTxn, parent: *Node, i: usize) Allocator.Error!void {
        const children = &parent.kind.internal.children;
        const left_page = try self.touch(children[i - 1]);
        children[i - 1] = left_page.id;
        const left = left_page.node;
        const child = self.dirty.get(children[i]).?; // copied on the way down
        switch (child.kind) {
            .leaf => {
                const e = left.leafRemoveAt(left.len - 1);
                child.leafInsertAt(0, e.key, e.value);
                parent.keys[i - 1] = child.keys[0];
            },
            .internal => |*in| {
                // Rotation through the parent, as in chapter 05.
                const moved_child = left.kind.internal.children[left.len];
                @memmove(child.keys[1 .. child.len + 1], child.keys[0..child.len]);
                @memmove(in.children[1 .. child.len + 2], in.children[0 .. child.len + 1]);
                child.keys[0] = parent.keys[i - 1];
                in.children[0] = moved_child;
                child.len += 1;
                parent.keys[i - 1] = left.keys[left.len - 1];
                left.len -= 1;
            },
        }
    }

    /// Moves the first item of the right sibling to the end of child `i`.
    fn borrowFromRight(self: *WriteTxn, parent: *Node, i: usize) Allocator.Error!void {
        const children = &parent.kind.internal.children;
        const right_page = try self.touch(children[i + 1]);
        children[i + 1] = right_page.id;
        const right = right_page.node;
        const child = self.dirty.get(children[i]).?;
        switch (child.kind) {
            .leaf => {
                const e = right.leafRemoveAt(0);
                child.leafInsertAt(child.len, e.key, e.value);
                parent.keys[i] = right.keys[0];
            },
            .internal => |*in| {
                child.keys[child.len] = parent.keys[i];
                in.children[child.len + 1] = right.kind.internal.children[0];
                child.len += 1;
                parent.keys[i] = right.keys[0];
                const rc = &right.kind.internal.children;
                @memmove(right.keys[0 .. right.len - 1], right.keys[1..right.len]);
                @memmove(rc[0..right.len], rc[1 .. right.len + 1]);
                right.len -= 1;
            },
        }
    }

    /// Merges children `li` and `li + 1` of `parent` into ONE page.
    ///
    /// Chapter 07 always merged right into left. Here exactly one of the two
    /// is already a private copy (the child we came up from, named by
    /// `survivor`), so we merge INTO THAT ONE: the other sibling is only read
    /// and then freed, and never has to be copied.
    fn merge(self: *WriteTxn, parent: *Node, li: usize, survivor: enum { left, right }) Allocator.Error!void {
        const children = &parent.kind.internal.children;
        const left_id = children[li];
        const right_id = children[li + 1];
        const keep_id = if (survivor == .left) left_id else right_id;
        const drop_id = if (survivor == .left) right_id else left_id;
        try self.discard(drop_id); // may fail; nothing has been changed yet
        // (A discarded committed page stays readable: it is only on our list.)
        const left: *const Node = if (survivor == .left) self.dirty.get(left_id).? else self.db.store.read(left_id);
        const right: *const Node = if (survivor == .right) self.dirty.get(right_id).? else self.db.store.read(right_id);

        // Build the merged node in a scratch copy, then store it in the survivor.
        var merged = left.*;
        switch (merged.kind) {
            .leaf => |*leaf| {
                // The separator between two leaves was only a copy: drop it.
                @memcpy(merged.keys[left.len .. left.len + right.len], right.keys[0..right.len]);
                @memcpy(leaf.values[left.len .. left.len + right.len], right.kind.leaf.values[0..right.len]);
                merged.len = left.len + right.len;
            },
            .internal => |*in| {
                // The separator between two internal nodes comes DOWN.
                merged.keys[left.len] = parent.keys[li];
                @memcpy(merged.keys[left.len + 1 .. left.len + 1 + right.len], right.keys[0..right.len]);
                @memcpy(in.children[left.len + 1 .. left.len + 2 + right.len], right.childSlice());
                merged.len = left.len + 1 + right.len;
            },
        }
        assert(merged.len <= self.db.maxKeys());
        self.dirty.get(keep_id).?.* = merged;
        children[li] = keep_id; // internalRemoveAt drops child li + 1
        parent.internalRemoveAt(li);
    }

    // --------------------------------------------------- commit / abort

    pub const CommitError = error{TxnFailed} || Allocator.Error;

    /// Publishes the transaction: write the new pages, then flip the root.
    /// On error nothing has been published and the transaction is still
    /// open; the caller aborts it (or, for OutOfMemory, may try again).
    pub fn commit(self: *WriteTxn, gpa: Allocator) CommitError!CommitInfo {
        if (self.failed) return error.TxnFailed;
        const db = self.db;
        if (self.dirty.count() == 0 and self.freed.items.len == 0) {
            // Nothing changed (e.g. delete of a missing key): no new root.
            self.close();
            return .{};
        }

        // Phase 1: everything that can fail. No state has changed yet.
        try db.store.grow(gpa, self.next_new);
        try db.pending.ensureUnusedCapacity(gpa, self.freed.items.len);

        // Phase 2: write the new pages. Each goes to a FREE slot, so a crash
        // (or a reader) in the middle of this loop still sees the old tree
        // complete: the old meta slot does not point at any of these pages.
        var it = self.dirty.iterator();
        while (it.next()) |e| db.store.write(e.key_ptr.*, e.value_ptr.*, self.id);
        for (self.scrapped.items) |id| db.store.free.appendAssumeCapacity(id);

        // Phase 3: THE atomic step. One small write into the slot that does
        // NOT hold the current root. Before it, readers find the old tree;
        // after it, the new one. A real engine syncs the pages before this
        // write and the meta slot after it (chapter 21).
        db.current = .{
            .txn_id = self.id,
            .root = self.root,
            .height = @intCast(self.height),
            .count = self.count,
            .page_count = @intCast(db.store.pageCount()),
        };
        db.store.meta_slots[self.id % 2] = db.current.encode();

        // Phase 4: the replaced pages are unreachable from the new root, but
        // older snapshots may still reach them: pending, not free.
        for (self.freed.items) |id| db.pending.appendAssumeCapacity(.{ .freed_by = self.id, .page = id });
        var info = self.info;
        info.txn_id = self.id;
        info.freed = self.freed.items.len;
        info.released = db.reclaim();

        db.stats.commits += 1;
        db.stats.pages_copied += info.copied;
        db.stats.pages_reused += info.reused;
        db.stats.pages_fresh += info.fresh;
        self.close();
        return info;
    }

    /// Throws the transaction away. No page of the store was written, so the
    /// committed tree and every snapshot are exactly as before.
    pub fn abort(self: *WriteTxn) void {
        // Hand the reserved page ids back, last taken first, which restores
        // the free list's order.
        var i = self.taken.items.len;
        while (i > 0) {
            i -= 1;
            self.db.store.free.appendAssumeCapacity(self.taken.items[i]);
        }
        self.db.stats.aborts += 1;
        self.close();
    }

    fn close(self: *WriteTxn) void {
        self.db.writer_active = false;
        self.arena.deinit(); // every page copy, the map and the lists: gone
        self.* = undefined;
    }
};

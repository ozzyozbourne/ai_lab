//! The index: a B+tree of (user key, tid) entries whose leaves are chained
//! by right links. Three things make it different from chapter 07:
//!
//!   * `delete` does not exist. Entries leave the index only as GARBAGE,
//!     after the row version they point at is dead to every snapshot
//!     (`makeRoom` here, VACUUM in db.zig).
//!   * Non-empty pages are never merged and nothing is ever borrowed: an
//!     entry stays on the page it was put on until it is removed or the page
//!     splits (then it may move RIGHT, never left).
//!   * An EMPTY leaf is deleted in two phases plus a delayed third step:
//!     live -> (markHalfDead) half-dead -> (unlink) deleted -> (recycle) free
//!
//! Invariants (checked by validate.zig):
//!   1. Keys inside a page are strictly ascending; a child holds only keys
//!      inside the range its parent's separators give it.
//!   2. An internal page with k separators has k+1 children; k may be 0.
//!   3. All leaves reachable from the root are `live` and at the same depth.
//!   4. Following `next` from `first_leaf` visits exactly those leaves in key
//!      order, plus any half-dead pages still waiting for phase 2.
//!   5. A deleted page is on the deleted queue, in stamp order, and nothing
//!      in the tree or the chain points at it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const arena = @import("base_arena.zig");
const node = @import("base_node.zig");
const search = @import("base_search.zig");
const Store = @import("store.zig").Store;

pub const NodeId = arena.NodeId;
pub const Node = node.Node;

/// Counts only. The demo uses them to say what an operation did; tests use
/// them to prove that a path was exercised.
pub const Stats = struct {
    leaf_splits: usize = 0,
    internal_splits: usize = 0,
    /// Splits that did not happen because garbage was removed instead.
    splits_avoided: usize = 0,
    /// Entries removed by each of the three collectors.
    simple_deleted: usize = 0,
    bottom_up_deleted: usize = 0,
    vacuum_deleted: usize = 0,
    pages_half_dead: usize = 0,
    pages_unlinked: usize = 0,
    pages_recycled: usize = 0,
    /// Splits that got a recycled page instead of growing the page array.
    pages_reused: usize = 0,
};

const Split = struct { separator: u64, right: NodeId };

pub const Index = struct {
    /// M: maximum number of children of an internal page.
    order: usize,
    /// When a leaf is full and has no hinted entries, ask the version store
    /// about every entry on it before splitting (the "bottom-up" pass).
    bottom_up: bool = true,
    nodes: arena.Arena(Node) = .empty,
    root: NodeId = .nil,
    /// Head of the leaf chain (may be a half-dead page between the phases).
    first_leaf: NodeId = .nil,
    height: usize = 0,
    /// Number of entries, garbage included.
    count: usize = 0,
    /// Deleted pages waiting for the horizon to pass their stamp (FIFO).
    deleted_head: NodeId = .nil,
    deleted_tail: NodeId = .nil,
    stats: Stats = .{},

    pub fn init(order: usize) Index {
        assert(order >= 3 and order <= node.max_order);
        return .{ .order = order };
    }

    pub fn deinit(self: *Index, gpa: Allocator) void {
        self.nodes.deinit(gpa);
    }

    pub fn maxKeys(self: *const Index) usize {
        return self.order - 1;
    }

    /// The live leaf whose key range contains `index_key`; `.nil` if empty.
    pub fn findLeaf(self: *const Index, index_key: u64) NodeId {
        var id = self.root;
        if (id == .nil) return .nil;
        while (true) {
            const n = self.nodes.get(id);
            switch (n.kind) {
                .leaf => return id,
                .internal => |*in| id = in.children[search.childIndex(n.keySlice(), index_key)],
            }
        }
    }

    // ------------------------------------------------------------ insert

    /// Worst case for one insert: every page on the path splits, plus a new
    /// root. Reserving first makes `insertReserved` infallible, so the caller
    /// can allocate the row version in between without a rollback path.
    pub fn reserveForInsert(self: *Index, gpa: Allocator) Allocator.Error!void {
        try self.nodes.reserve(gpa, self.height + 1);
    }

    pub fn insertReserved(self: *Index, store: *Store, index_key: u64) void {
        if (self.root == .nil) {
            self.root = self.nodes.allocAssumeCapacity(Node.initLeaf());
            self.first_leaf = self.root;
            self.height = 1;
        }
        if (self.insertInto(store, self.root, index_key)) |s| {
            var new_root = Node.initInternal();
            new_root.kind.internal.children[0] = self.root;
            new_root.internalInsertAt(0, s.separator, s.right);
            self.root = self.allocPage(new_root);
            self.height += 1;
        }
    }

    fn insertInto(self: *Index, store: *Store, id: NodeId, index_key: u64) ?Split {
        const n = self.nodes.ptr(id);
        switch (n.kind) {
            .leaf => {
                // A full page: collect garbage first, split only as a last resort.
                if (n.len == self.maxKeys()) self.makeRoom(store, n);
                const i = search.lowerBound(n.keySlice(), index_key);
                assert(i == n.len or n.keys[i] != index_key); // the tid makes it unique
                n.leafInsertAt(i, index_key);
                self.count += 1;
                if (n.len <= self.maxKeys()) return null;
                return self.splitLeaf(id);
            },
            .internal => |*in| {
                const i = search.childIndex(n.keySlice(), index_key);
                const s = self.insertInto(store, in.children[i], index_key) orelse return null;
                n.internalInsertAt(i, s.separator, s.right);
                if (n.len <= self.maxKeys()) return null;
                return self.splitInternal(id);
            },
        }
    }

    /// Garbage collection on ONE leaf, run by the insert that found it full.
    ///
    ///   simple deletion : drop the entries a scan has already hinted. Costs
    ///                     nothing extra: the hint bit is on the page.
    ///   bottom-up       : nothing hinted, so ask the version store about
    ///                     every entry on the page (one "heap visit" each).
    ///
    /// Either one is safe at any time, because an entry whose version is dead
    /// to all is by definition invisible to every reader, now and later.
    fn makeRoom(self: *Index, store: *Store, n: *Node) void {
        self.stats.simple_deleted += self.removeWhere(store, n, .hinted);
        if (n.len == self.maxKeys() and self.bottom_up) {
            self.stats.bottom_up_deleted += self.removeWhere(store, n, .dead_to_all);
        }
        if (n.len < self.maxKeys()) self.stats.splits_avoided += 1;
    }

    /// Removes the matching entries of a leaf and frees their row versions.
    /// Entry first, version second: the tid may be handed out again as soon
    /// as the version is freed, and no entry may still point at it then.
    pub fn removeWhere(self: *Index, store: *Store, n: *Node, what: enum { hinted, dead_to_all }) usize {
        var removed: usize = 0;
        var i = n.len;
        while (i > 0) {
            i -= 1;
            const tid = node.tidOf(n.keys[i]);
            const garbage = switch (what) {
                .hinted => n.kind.leaf.dead[i],
                .dead_to_all => store.deadToAll(tid),
            };
            if (!garbage) continue;
            n.leafRemoveAt(i);
            store.versions.free(tid);
            removed += 1;
        }
        self.count -= removed;
        return removed;
    }

    /// Takes a page from the arena's free list (a recycled page) if there is
    /// one. Capacity was reserved by `reserveForInsert`.
    fn allocPage(self: *Index, page: Node) NodeId {
        const slots_before = self.nodes.slotCount();
        const id = self.nodes.allocAssumeCapacity(page);
        if (self.nodes.slotCount() == slots_before) self.stats.pages_reused += 1;
        return id;
    }

    /// Splits a leaf holding M entries. The upper half moves RIGHT into a
    /// new page; nothing ever moves left, which is what lets a scan that
    /// remembers a right link find everything it has not seen yet.
    fn splitLeaf(self: *Index, left_id: NodeId) Split {
        const right_id = self.allocPage(Node.initLeaf());
        const left = self.nodes.ptr(left_id);
        const right = self.nodes.ptr(right_id);
        const mid = left.len / 2;
        const moved = left.len - mid;
        @memcpy(right.keys[0..moved], left.keys[mid..left.len]);
        @memcpy(right.kind.leaf.dead[0..moved], left.kind.leaf.dead[mid..left.len]);
        right.len = moved;
        left.len = mid;
        right.kind.leaf.next = left.kind.leaf.next;
        left.kind.leaf.next = right_id;
        self.stats.leaf_splits += 1;
        return .{ .separator = right.keys[0], .right = right_id };
    }

    fn splitInternal(self: *Index, left_id: NodeId) Split {
        const right_id = self.allocPage(Node.initInternal());
        const left = self.nodes.ptr(left_id);
        const right = self.nodes.ptr(right_id);
        const mid = left.len / 2;
        const separator = left.keys[mid];
        const moved = left.len - mid - 1;
        @memcpy(right.keys[0..moved], left.keys[mid + 1 .. left.len]);
        @memcpy(right.kind.internal.children[0 .. moved + 1], left.kind.internal.children[mid + 1 .. left.len + 1]);
        right.len = moved;
        left.len = mid;
        self.stats.internal_splits += 1;
        return .{ .separator = separator, .right = right_id };
    }

    // ----------------------------------------------------- page deletion

    const Downlink = struct { parent: NodeId, slot: usize };

    /// Finds the parent slot that points at `target` by walking the internal
    /// pages. (An empty leaf has no key to search for. Postgres keeps a high
    /// key on every page and re-finds the parent by searching for that.)
    fn findDownlink(self: *const Index, id: NodeId, depth: usize, target: NodeId) ?Downlink {
        const n = self.nodes.get(id);
        if (n.isLeaf()) return null;
        for (n.childSlice(), 0..) |child, slot| {
            if (depth + 1 == self.height) {
                if (child == target) return .{ .parent = id, .slot = slot };
            } else if (self.findDownlink(child, depth + 1, target)) |found| return found;
        }
        return null;
    }

    /// PHASE 1. Removes the parent's downlink to an empty leaf and marks the
    /// leaf half-dead. Returns false (and changes nothing) if the page may
    /// not be deleted:
    ///   * it is not an empty live leaf, or it is the root;
    ///   * it is the rightmost child of its parent. Its key range would have
    ///     to be given to a page under a DIFFERENT parent, which means
    ///     changing separators higher up. (Postgres allows one more case, a
    ///     parent with a single child, and deletes the parent too.)
    ///
    /// The surgery: slot i now points at the old child i+1, and separator i
    /// goes away. The target's key range is thereby handed to its right
    /// sibling without touching a single key in either leaf:
    ///
    ///     .. k(i-1) [T] k(i) [R] k(i+1) ..   ->   .. k(i-1) [R] k(i+1) ..
    pub fn markHalfDead(self: *Index, id: NodeId) bool {
        if (!self.nodes.isLive(id) or id == self.root) return false;
        const leaf = self.nodes.ptr(id);
        if (!leaf.isLeaf() or leaf.kind.leaf.state != .live or leaf.len != 0) return false;
        const link = self.findDownlink(self.root, 1, id) orelse return false;
        const parent = self.nodes.ptr(link.parent);
        if (link.slot == parent.len) return false; // rightmost child
        parent.kind.internal.children[link.slot] = parent.kind.internal.children[link.slot + 1];
        parent.internalRemoveAt(link.slot);
        leaf.kind.leaf.state = .half_dead;
        self.stats.pages_half_dead += 1;
        return true;
    }

    /// The page whose right link points at `id`, or `.nil` if `id` is the
    /// head of the chain. Walks the chain (there are no left links).
    pub fn leftSibling(self: *const Index, id: NodeId) NodeId {
        var left: NodeId = .nil;
        var cur = self.first_leaf;
        while (cur != id) : (cur = self.nodes.get(cur).kind.leaf.next) left = cur;
        return left;
    }

    /// PHASE 2. Takes a half-dead page out of the sibling chain and stamps it
    /// with a fresh epoch. `left` is its chain predecessor (`.nil` = head).
    ///
    /// The page keeps its OWN right link: a scan that read "next = this page"
    /// before the unlink may still arrive here, and escapes to the right.
    ///
    /// The stamp is a NEW tick of the counter, taken after the unlink. So:
    ///   snapshot <  stamp : taken before the unlink, may hold a link here;
    ///   snapshot >= stamp : taken after it, cannot have found a link here.
    pub fn unlinkHalfDead(self: *Index, store: *Store, left: NodeId, id: NodeId) void {
        const leaf = &self.nodes.ptr(id).kind.leaf;
        assert(leaf.state == .half_dead);
        if (left == .nil) {
            assert(self.first_leaf == id);
            self.first_leaf = leaf.next;
        } else {
            const left_leaf = &self.nodes.ptr(left).kind.leaf;
            assert(left_leaf.next == id);
            left_leaf.next = leaf.next;
        }
        leaf.state = .{ .deleted = store.tick() };
        leaf.next_deleted = .nil;
        if (self.deleted_tail == .nil) {
            self.deleted_head = id;
        } else {
            self.nodes.ptr(self.deleted_tail).kind.leaf.next_deleted = id;
        }
        self.deleted_tail = id;
        self.stats.pages_unlinked += 1;
    }

    /// STEP 3. Frees every deleted page whose stamp the horizon has reached:
    /// no open snapshot is older than the unlink, so no scan can still be on
    /// its way to the page. Freed pages go to the arena's free list and are
    /// handed to the next split. Stamps only grow, so the queue is in stamp
    /// order and we can stop at the first page that must wait.
    pub fn recycle(self: *Index, horizon: u64) usize {
        var freed: usize = 0;
        while (self.deleted_head != .nil) {
            const id = self.deleted_head;
            const leaf = &self.nodes.get(id).kind.leaf;
            if (leaf.state.deleted > horizon) break;
            self.deleted_head = leaf.next_deleted;
            if (self.deleted_head == .nil) self.deleted_tail = .nil;
            self.nodes.free(id);
            freed += 1;
        }
        self.stats.pages_recycled += freed;
        return freed;
    }

    /// The bug this chapter is about, on purpose: recycle without asking who
    /// might still be looking. Only tests and the demo call it.
    pub fn recycleIgnoringSnapshots(self: *Index) usize {
        return self.recycle(std.math.maxInt(u64));
    }
};

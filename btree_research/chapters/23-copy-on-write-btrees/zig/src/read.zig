//! Reading: a `View` is "a root plus where to find pages"; `get` and the
//! range cursor work on any view, so the same code serves
//!   * the current committed tree          (Db.view),
//!   * an old snapshot                     (Snapshot.view),
//!   * the uncommitted tree of a write transaction (WriteTxn.view), whose
//!     new pages are not in the store yet.
//!
//! Range scans cannot follow leaf sibling links, because this tree has none.
//! The cursor keeps the root-to-leaf path on a small stack instead and climbs
//! back up through it when a leaf is exhausted.
const std = @import("std");
const assert = std.debug.assert;
const base_node = @import("base_node.zig");
const Node = base_node.Node;
const PageId = base_node.PageId;
const Entry = base_node.Entry;
const search = @import("base_search.zig");
const PageStore = @import("store.zig").PageStore;

/// Pages a write transaction has created or copied, by their future page id.
pub const DirtyMap = std.AutoHashMapUnmanaged(PageId, *Node);

/// With a minimum fan-out of 2 this is enough for 2^31 leaves.
pub const max_height = 32;

pub const View = struct {
    store: *const PageStore,
    /// Only set for the view of a write transaction.
    dirty: ?*const DirtyMap = null,
    root: PageId,
    height: usize,
    count: u64,

    pub fn node(self: View, id: PageId) *const Node {
        if (self.dirty) |d| {
            if (d.get(id)) |n| return n;
        }
        return self.store.read(id);
    }

    pub fn get(self: View, key: u64) ?u64 {
        var id = self.root;
        if (id == .nil) return null;
        while (true) {
            const n = self.node(id);
            switch (n.kind) {
                .internal => |*in| id = in.children[search.childIndex(n.keySlice(), key)],
                .leaf => |*leaf| {
                    const i = search.lowerBound(n.keySlice(), key);
                    return if (i < n.len and n.keys[i] == key) leaf.values[i] else null;
                },
            }
        }
    }

    /// Cursor positioned at the first entry with key >= `lo`.
    pub fn seek(self: View, lo: u64) Cursor {
        var c: Cursor = .{ .view = self };
        var id = self.root;
        if (id == .nil) return c;
        while (true) {
            const n = self.node(id);
            const i = switch (n.kind) {
                .internal => search.childIndex(n.keySlice(), lo),
                .leaf => search.lowerBound(n.keySlice(), lo),
            };
            c.push(id, i);
            if (n.isLeaf()) return c;
            id = n.kind.internal.children[i];
        }
    }

    /// Entries with lo <= key < hi, ascending.
    pub fn range(self: View, lo: u64, hi: u64) Range {
        return .{ .cursor = self.seek(lo), .hi = hi };
    }
};

pub const Cursor = struct {
    view: View,
    /// stack[d] = (page at depth d, position in it). For an internal page the
    /// position is the child we descended into; for the leaf on top it is the
    /// next entry to return.
    stack: [max_height]Frame = undefined,
    depth: usize = 0,

    const Frame = struct { id: PageId, i: usize };

    fn push(self: *Cursor, id: PageId, i: usize) void {
        assert(self.depth < max_height);
        self.stack[self.depth] = .{ .id = id, .i = i };
        self.depth += 1;
    }

    pub fn next(self: *Cursor) ?Entry {
        while (self.depth > 0) {
            const top = &self.stack[self.depth - 1];
            const n = self.view.node(top.id);
            switch (n.kind) {
                .leaf => |*leaf| {
                    if (top.i < n.len) {
                        top.i += 1;
                        return .{ .key = n.keys[top.i - 1], .value = leaf.values[top.i - 1] };
                    }
                    // Leaf exhausted. With sibling links this would be one
                    // hop; here we pop, and the parent frame takes over.
                    self.depth -= 1;
                    if (self.depth > 0) self.stack[self.depth - 1].i += 1;
                },
                .internal => |*in| {
                    if (top.i <= n.len) {
                        // Descend into the next child, to its first position.
                        self.push(in.children[top.i], 0);
                    } else {
                        self.depth -= 1;
                        if (self.depth > 0) self.stack[self.depth - 1].i += 1;
                    }
                },
            }
        }
        return null;
    }
};

pub const Range = struct {
    cursor: Cursor,
    hi: u64,

    pub fn next(self: *Range) ?Entry {
        const e = self.cursor.next() orelse return null;
        if (e.key >= self.hi) {
            self.cursor.depth = 0; // stay finished
            return null;
        }
        return e;
    }
};

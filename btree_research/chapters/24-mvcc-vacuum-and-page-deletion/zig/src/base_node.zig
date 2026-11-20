// Copied from chapters/07-bplus-trees/zig/src/node.zig and changed for
// chapter 24: a leaf entry is an index key (user key, tid) with a "dead" hint
// bit instead of a key with a value; a leaf has only a right link, and a page
// state (live / half-dead / deleted).
//! Page layout of the index, and the array surgery done inside one page.
//!
//!   * a LEAF holds index entries. An entry is NOT a row: it is the pair
//!     (user key, tid), where the tid names a row version in the version
//!     store (store.zig). Whether that version is visible to anyone is not
//!     recorded here, except for one bit: the `dead` hint.
//!   * an INTERNAL page holds separators and child handles, as in chapter 07.
const std = @import("std");
const assert = std.debug.assert;
const NodeId = @import("base_arena.zig").NodeId;

pub const max_order = 16;
/// A page of order M holds at most M-1 keys, but an insert lets it overflow
/// by exactly one key before it is split, so the arrays have room for M.
pub const key_capacity = max_order;
pub const child_capacity = max_order + 1;

/// User keys are limited to 32 bits in this chapter so that an index key
/// fits in one u64 and base_search.zig can compare it as a plain integer.
pub const max_user_key = std.math.maxInt(u32);

/// Index key = (user key, tid): the tid is the tie-breaker that makes every
/// entry unique even when one user key has many row versions (chapter 07,
/// "duplicates through a tie-breaker").
pub fn pack(user_key: u64, tid: NodeId) u64 {
    assert(user_key <= max_user_key);
    return (user_key << 32) | tid.index();
}

/// Smallest index key with this user key: where a search for the key starts.
pub fn packLow(user_key: u64) u64 {
    assert(user_key <= max_user_key);
    return user_key << 32;
}

pub fn userKey(index_key: u64) u64 {
    return index_key >> 32;
}

pub fn tidOf(index_key: u64) NodeId {
    return .fromIndex(@intCast(index_key & 0xFFFF_FFFF));
}

/// Life cycle of a leaf page. Only an EMPTY page ever leaves `live`.
pub const PageState = union(enum) {
    /// Reachable from its parent and from its left sibling.
    live,
    /// Phase 1 done: no parent downlink any more, still in the sibling chain.
    half_dead,
    /// Phase 2 done: out of the sibling chain too. The payload is the epoch
    /// at which it was unlinked. The page keeps its own right link, and must
    /// not be reused while any snapshot older than that epoch is open.
    deleted: u64,
};

pub const Leaf = struct {
    /// dead[i] belongs to keys[i]: "a scan saw that this entry's row version
    /// is dead to every snapshot". A HINT: false says nothing.
    dead: [key_capacity]bool = @splat(false),
    /// Right sibling. There is no left link in this chapter.
    next: NodeId = .nil,
    state: PageState = .live,
    /// Queue of deleted pages waiting to be recycled (oldest first).
    next_deleted: NodeId = .nil,
};

pub const Internal = struct {
    /// children[i] holds keys <  keys[i]   (and >= keys[i-1]);
    /// children[len] holds keys >= keys[len-1].
    children: [child_capacity]NodeId = undefined,
};

pub const Node = struct {
    /// Number of keys in use.
    len: usize = 0,
    /// Sorted ascending, unique. Leaf: index keys. Internal: separators.
    keys: [key_capacity]u64 = undefined,
    kind: union(enum) { leaf: Leaf, internal: Internal },

    pub fn initLeaf() Node {
        return .{ .kind = .{ .leaf = .{} } };
    }

    pub fn initInternal() Node {
        return .{ .kind = .{ .internal = .{} } };
    }

    pub fn isLeaf(self: *const Node) bool {
        return self.kind == .leaf;
    }

    pub fn keySlice(self: *const Node) []const u64 {
        return self.keys[0..self.len];
    }

    /// The len+1 child handles of an internal page.
    pub fn childSlice(self: *const Node) []const NodeId {
        return self.kind.internal.children[0 .. self.len + 1];
    }

    /// Inserts an entry (hint clear) at position i, shifting the tail right.
    pub fn leafInsertAt(self: *Node, i: usize, index_key: u64) void {
        assert(self.len < key_capacity and i <= self.len);
        const leaf = &self.kind.leaf;
        @memmove(self.keys[i + 1 .. self.len + 1], self.keys[i..self.len]);
        @memmove(leaf.dead[i + 1 .. self.len + 1], leaf.dead[i..self.len]);
        self.keys[i] = index_key;
        leaf.dead[i] = false;
        self.len += 1;
    }

    /// Removes the entry at position i, shifting the tail left.
    pub fn leafRemoveAt(self: *Node, i: usize) void {
        assert(i < self.len);
        const leaf = &self.kind.leaf;
        @memmove(self.keys[i .. self.len - 1], self.keys[i + 1 .. self.len]);
        @memmove(leaf.dead[i .. self.len - 1], leaf.dead[i + 1 .. self.len]);
        self.len -= 1;
    }

    /// Inserts separator `key` at key position i and `right` as the child to
    /// its right (child position i+1): what a parent does after child i split.
    pub fn internalInsertAt(self: *Node, i: usize, key: u64, right: NodeId) void {
        assert(self.len < key_capacity and i <= self.len);
        const children = &self.kind.internal.children;
        @memmove(self.keys[i + 1 .. self.len + 1], self.keys[i..self.len]);
        @memmove(children[i + 2 .. self.len + 2], children[i + 1 .. self.len + 1]);
        self.keys[i] = key;
        children[i + 1] = right;
        self.len += 1;
    }

    /// Removes separator i and the child to its right (child i+1).
    pub fn internalRemoveAt(self: *Node, i: usize) void {
        assert(i < self.len);
        const children = &self.kind.internal.children;
        @memmove(self.keys[i .. self.len - 1], self.keys[i + 1 .. self.len]);
        @memmove(children[i + 1 .. self.len], children[i + 2 .. self.len + 1]);
        self.len -= 1;
    }
};

test "pack keeps (user key, tid) order and round-trips" {
    const a = pack(7, .fromIndex(9));
    try std.testing.expectEqual(7, userKey(a));
    try std.testing.expectEqual(9, tidOf(a).index());
    try std.testing.expect(pack(7, .fromIndex(9)) < pack(8, .fromIndex(0)));
    try std.testing.expect(packLow(7) <= pack(7, .fromIndex(0)));
}

test "leaf insert and remove keep keys and hint bits aligned" {
    var n = Node.initLeaf();
    n.leafInsertAt(0, 20);
    n.leafInsertAt(0, 10);
    n.kind.leaf.dead[1] = true; // hint on 20
    n.leafInsertAt(1, 15);
    try std.testing.expectEqualSlices(u64, &.{ 10, 15, 20 }, n.keySlice());
    try std.testing.expectEqualSlices(bool, &.{ false, false, true }, n.kind.leaf.dead[0..3]);
    n.leafRemoveAt(0);
    try std.testing.expectEqualSlices(u64, &.{ 15, 20 }, n.keySlice());
    try std.testing.expectEqualSlices(bool, &.{ false, true }, n.kind.leaf.dead[0..2]);
}

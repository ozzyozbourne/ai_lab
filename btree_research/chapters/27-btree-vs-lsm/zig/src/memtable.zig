//! The memtable: the only mutable part of an LSM-tree, and it lives in RAM.
//!
//! It is a skip list (textbook; the classic choice since LevelDB) whose nodes
//! are bump-allocated from an ARENA. That pairing is the allocator lesson of
//! the chapter:
//!   * a memtable only ever grows, one small node per new key, until it is
//!     flushed; then EVERY node dies at the same instant;
//!   * so no node is ever freed on its own, and `reset` gives all of them
//!     back in one call without walking the list.
//!
//! A put of a key that is already in the memtable overwrites in place and
//! allocates nothing: the memtable absorbs repeated updates for free.
//! A delete is a put of a TOMBSTONE (`value == null`): the key may still
//! exist in an older run on the device, and only a newer entry can hide it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const SplitMix64 = @import("prng.zig").SplitMix64;

/// Tallest tower. 2^8 = 256 keys per top-level step is plenty for a memtable
/// of a few hundred entries.
pub const max_height = 8;

/// Result of looking a key up in ONE place (the memtable or one run).
pub const Lookup = union(enum) {
    /// This place knows nothing about the key: keep looking in older data.
    absent,
    /// The key was deleted: stop looking, the answer is "not found".
    tombstone,
    value: u64,
};

pub const Node = struct {
    key: u64,
    /// null = tombstone.
    value: ?u64,
    /// next[h] is the following node on level h. The tower's length is this
    /// node's height; it is a second allocation from the same arena.
    next: []?*Node,
};

pub const Memtable = struct {
    arena: std.heap.ArenaAllocator,
    /// head[h] is the first node on level h.
    head: [max_height]?*Node = @splat(null),
    /// Number of distinct keys (tombstones included).
    count: usize = 0,
    /// Tower heights come from a seeded generator so that runs are
    /// reproducible. The shape of the list never reaches the output.
    rng: SplitMix64 = .init(27),

    /// `child` is where the arena gets its big chunks from.
    pub fn init(child: Allocator) Memtable {
        return .{ .arena = .init(child) };
    }

    pub fn deinit(self: *Memtable) void {
        self.arena.deinit();
    }

    /// Drops every node at once and keeps the memory for the next memtable.
    /// This is called right after a flush.
    pub fn reset(self: *Memtable) void {
        _ = self.arena.reset(.retain_capacity);
        self.head = @splat(null);
        self.count = 0;
    }

    /// Finds, per level, the last node with key < `key` (null = the head).
    /// Returns the node at or after `key` on level 0.
    fn findPredecessors(self: *const Memtable, key: u64, preds: *[max_height]?*Node) ?*Node {
        var pred: ?*Node = null;
        var h: usize = max_height;
        while (h > 0) {
            h -= 1;
            // Walk right on level h while the next key is still too small,
            // then drop one level: the skip list's version of a descent.
            while (true) {
                const next = if (pred) |p| (if (h < p.next.len) p.next[h] else null) else self.head[h];
                if (next == null or next.?.key >= key) break;
                pred = next;
            }
            preds[h] = pred;
        }
        return if (pred) |p| p.next[0] else self.head[0];
    }

    /// Inserts or overwrites; `value == null` writes a tombstone.
    /// On `error.OutOfMemory` the memtable is unchanged. (A node allocated
    /// just before the failure stays in the arena as dead bytes until the
    /// next `reset`. With an arena that needs no cleanup code at all.)
    pub fn put(self: *Memtable, key: u64, value: ?u64) Allocator.Error!void {
        var preds: [max_height]?*Node = undefined;
        if (self.findPredecessors(key, &preds)) |found| {
            if (found.key == key) {
                found.value = value;
                return;
            }
        }
        // Height h with probability 2^-h: count the trailing one bits.
        const height = @min(max_height, 1 + @ctz(~self.rng.nextU64()));
        const a = self.arena.allocator();
        const node = try a.create(Node);
        node.* = .{ .key = key, .value = value, .next = try a.alloc(?*Node, height) };
        // Nothing can fail from here on. Splice the node in on each level.
        for (node.next, 0..) |*slot, h| {
            if (preds[h]) |p| {
                slot.* = p.next[h];
                p.next[h] = node;
            } else {
                slot.* = self.head[h];
                self.head[h] = node;
            }
        }
        self.count += 1;
    }

    pub fn get(self: *const Memtable, key: u64) Lookup {
        var preds: [max_height]?*Node = undefined;
        const found = self.findPredecessors(key, &preds) orelse return .absent;
        if (found.key != key) return .absent;
        return if (found.value) |v| .{ .value = v } else .tombstone;
    }

    /// First node with key >= `key`; follow `next[0]` to iterate in order.
    pub fn seek(self: *const Memtable, key: u64) ?*const Node {
        var preds: [max_height]?*Node = undefined;
        return self.findPredecessors(key, &preds);
    }

    pub fn first(self: *const Memtable) ?*const Node {
        return self.head[0];
    }
};

test "put, overwrite, tombstone, ordered iteration" {
    var m: Memtable = .init(std.testing.allocator);
    defer m.deinit();
    for ([_]u64{ 50, 10, 40, 20, 30 }) |k| try m.put(k, k * 10);
    try m.put(40, 444); // overwrite: no new node
    try m.put(20, null); // tombstone
    try m.put(25, null); // tombstone for a key that was never here
    try std.testing.expectEqual(6, m.count);
    try std.testing.expectEqual(Lookup{ .value = 444 }, m.get(40));
    try std.testing.expectEqual(Lookup.tombstone, m.get(20));
    try std.testing.expectEqual(Lookup.absent, m.get(21));

    var keys: [6]u64 = undefined;
    var n: usize = 0;
    var it = m.first();
    while (it) |node| : (it = node.next[0]) {
        keys[n] = node.key;
        n += 1;
    }
    try std.testing.expectEqualSlices(u64, &.{ 10, 20, 25, 30, 40, 50 }, keys[0..n]);
    try std.testing.expectEqual(30, m.seek(26).?.key);
    try std.testing.expectEqual(null, m.seek(51));
}

test "reset frees every node at once and the arena is reused" {
    var m: Memtable = .init(std.testing.allocator);
    defer m.deinit();
    for (0..200) |k| try m.put(k, k);
    const capacity = m.arena.queryCapacity();
    m.reset();
    try std.testing.expectEqual(0, m.count);
    try std.testing.expectEqual(Lookup.absent, m.get(7));
    // The second generation fits into the memory of the first.
    for (0..200) |k| try m.put(k + 1000, k);
    try std.testing.expectEqual(capacity, m.arena.queryCapacity());
    try std.testing.expectEqual(200, m.count);
}

test "a failed put leaves the memtable unchanged" {
    // Fail each allocation in turn while inserting; whatever happens, the
    // memtable must hold exactly the keys whose put returned success.
    var fail_index: usize = 0;
    while (fail_index < 12) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = fail_index });
        var m: Memtable = .init(failing.allocator());
        defer m.deinit();
        var stored: usize = 0;
        for (0..40) |k| {
            if (m.put(k * 3, k)) |_| {
                stored += 1;
            } else |_| {
                try std.testing.expectEqual(Lookup.absent, m.get(k * 3));
            }
        }
        try std.testing.expectEqual(stored, m.count);
        var n: usize = 0;
        var it = m.first();
        while (it) |node| : (it = node.next[0]) n += 1;
        try std.testing.expectEqual(stored, n);
    }
}

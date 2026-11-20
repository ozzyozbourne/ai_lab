//! Cost counters and the counting index cursor.
//!
//! Every query of this chapter is built from two primitives and the counters
//! count exactly those:
//!
//!   * a DESCENT: walk one tree from its root to a leaf (`height` nodes);
//!   * a ROW FETCH: leave an index entry and go and get the row it points to.
//!
//! What a row fetch costs is the whole difference between the two layouts,
//! so `table.zig` is where it is charged. Counts only, never timings.
const std = @import("std");
const BPlusTree = @import("base_tree.zig").BPlusTree;
const NodeId = @import("base_arena.zig").NodeId;
const search = @import("base_search.zig");
const KeyRange = @import("row.zig").KeyRange;

pub const Counters = struct {
    /// Root-to-leaf walks, in any tree.
    descents: usize = 0,
    /// Tree nodes read: `height` per descent, plus one per leaf-link hop.
    tree_nodes: usize = 0,
    /// Index entries a scan returned.
    index_entries: usize = 0,
    /// Times a query followed a locator from an index entry to the row.
    row_fetches: usize = 0,
    /// Heap pages read by TID (always 0 in the clustered layout, where a row
    /// fetch is a descent of the primary tree and shows up in `tree_nodes`).
    heap_reads: usize = 0,

    /// Nodes and heap pages are both "one page" on disk. This is the number
    /// of page reads with no cache at all (chapter 09 adds the cache).
    pub fn pageReads(self: Counters) usize {
        return self.tree_nodes + self.heap_reads;
    }

    pub fn minus(self: Counters, earlier: Counters) Counters {
        return .{
            .descents = self.descents - earlier.descents,
            .tree_nodes = self.tree_nodes - earlier.tree_nodes,
            .index_entries = self.index_entries - earlier.index_entries,
            .row_fetches = self.row_fetches - earlier.row_fetches,
            .heap_reads = self.heap_reads - earlier.heap_reads,
        };
    }
};

/// Charges one root-to-leaf walk of `tree`.
pub fn chargeDescent(counters: *Counters, tree: *const BPlusTree) void {
    counters.descents += 1;
    counters.tree_nodes += tree.height;
}

/// Forward scan of the keys in a closed range: one descent to the first key
/// that is not below range.lo, then the leaf chain until a key is above range.hi. It never goes
/// back up the tree, and it never looks at a row: it returns index KEYS, and
/// the caller decides whether those are enough (a covering scan) or whether
/// each one must be followed to its row.
///
/// Holds a handle and an index, no pointer; must not be used across a `put`
/// or `delete` (chapter 08 lifts that restriction).
pub const Cursor = struct {
    tree: *const BPlusTree,
    counters: *Counters,
    leaf: NodeId,
    index: usize,
    hi: u64,

    pub fn seek(tree: *const BPlusTree, range: KeyRange, counters: *Counters) Cursor {
        chargeDescent(counters, tree);
        const leaf = search.findLeaf(tree, range.lo);
        const index = if (leaf == .nil) 0 else search.lowerBound(tree.nodes.get(leaf).keySlice(), range.lo);
        return .{ .tree = tree, .counters = counters, .leaf = leaf, .index = index, .hi = range.hi };
    }

    pub fn next(self: *Cursor) ?u64 {
        while (self.leaf != .nil) {
            const n = self.tree.nodes.get(self.leaf);
            if (self.index < n.len) {
                const key = n.keys[self.index];
                if (key > self.hi) break; // keys only grow from here: done
                self.index += 1;
                self.counters.index_entries += 1;
                return key;
            }
            // End of this leaf: follow the sibling link, one more node read.
            self.leaf = n.kind.leaf.next;
            self.index = 0;
            if (self.leaf != .nil) self.counters.tree_nodes += 1;
        }
        self.leaf = .nil;
        return null;
    }
};

test "cursor returns the closed range and counts its work" {
    const gpa = std.testing.allocator;
    var tree: BPlusTree = .init(4);
    defer tree.deinit(gpa);
    for (1..21) |k| _ = try tree.put(gpa, k * 10, 0);
    try std.testing.expectEqual(3, tree.height);

    var counters: Counters = .{};
    var cursor = Cursor.seek(&tree, .{ .lo = 45, .hi = 90 }, &counters);
    for ([_]u64{ 50, 60, 70, 80, 90 }) |expected| try std.testing.expectEqual(expected, cursor.next());
    try std.testing.expectEqual(null, cursor.next());
    try std.testing.expectEqual(null, cursor.next());
    try std.testing.expectEqual(1, counters.descents);
    try std.testing.expectEqual(5, counters.index_entries);
    // 3 nodes for the descent, the rest are leaf-link hops; never a second descent.
    try std.testing.expect(counters.tree_nodes > 3 and counters.tree_nodes <= 3 + 3);

    // An empty range and an empty tree cost a descent and return nothing.
    var none = Cursor.seek(&tree, .{ .lo = 91, .hi = 99 }, &counters);
    try std.testing.expectEqual(null, none.next());
    var empty: BPlusTree = .init(4);
    var on_empty = Cursor.seek(&empty, .all, &counters);
    try std.testing.expectEqual(null, on_empty.next());
    try std.testing.expectEqual(3, counters.descents);
}

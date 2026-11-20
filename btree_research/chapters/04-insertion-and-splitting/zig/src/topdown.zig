//! Top-down insert ("proactive" or "preventive" splitting): the textbook
//! alternative to base_insert.zig. This is B-TREE-INSERT from Cormen,
//! Leiserson, Rivest and Stein (CLRS), written for the order M of this guide
//! (CLRS minimum degree t = M / 2).
//!
//! The idea: never walk into a full node. On the way DOWN, a full child is
//! split before it is entered. The node we are standing in is therefore never
//! full, so it always has room for the median that a split below pushes up,
//! and nothing ever has to travel back up: one pass, no remembered path.
//!
//! What it costs:
//!   * M must be even. A full node has M - 1 keys. Taking the median out
//!     leaves M - 2, and both halves need ceil(M/2) - 1 keys. For even M that
//!     is exactly (M - 2) / 2 each. For odd M the halves would have to share
//!     M - 2 (an odd number) and each need (M - 1) / 2: one key short. The
//!     bottom-up split has one more key to share (the new one), so it works
//!     for every M.
//!   * It splits nodes that did not need it: a full node on the path is split
//!     even when the leaf below has room (and even when the key turns out to
//!     be present already and is only overwritten).
//!   * "Full" must be known before the key arrives. With fixed-size keys that
//!     is a count. With variable-length keys a page is full or not depending
//!     on the size of the separator that will come up, which is not known on
//!     the way down, so this method does not carry over to byte-sized pages
//!     as it stands.
//!
//! Allocation failure: each split is complete before the next one starts, so
//! an error.OutOfMemory half-way down leaves a VALID tree holding exactly the
//! same keys as before, but possibly with a different shape (the splits that
//! already happened stay). Compare base_insert.zig, which reserves all nodes
//! first and leaves the tree bit-for-bit unchanged.
const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("base_node.zig");
const search = @import("base_search.zig");

/// `Tree` is a `BTree(M, PoolFn)` from base_btree.zig with even M.
/// Returns the previous value if the key was already present (overwrite).
pub fn put(comptime Tree: type, tree: *Tree, gpa: Allocator, key: u64, value: u64) Allocator.Error!?u64 {
    const N = Tree.NodeT;
    if (Tree.order % 2 != 0) @compileError("top-down splitting needs an even order M (see the file header)");

    var node = tree.root orelse {
        const leaf = try tree.pool.create(gpa);
        leaf.* = .{ .leaf = true };
        leaf.insertEntry(0, key, value);
        tree.root = leaf;
        tree.len = 1;
        return null;
    };

    if (node.len == N.max_keys) {
        // A full root is split before anything else: the tree grows at the
        // top. Two nodes are needed; take both before touching the tree so
        // that this split either happens completely or not at all.
        const usage_before = tree.pool.usage;
        const right = try tree.pool.create(gpa);
        const new_root = tree.pool.create(gpa) catch |err| {
            tree.pool.destroy(gpa, right);
            tree.pool.usage = usage_before;
            return err;
        };
        const median = splitFull(N, node, right);
        new_root.* = .{ .leaf = false };
        new_root.children[0] = node;
        new_root.insertChild(1, right);
        new_root.insertEntry(0, median.key, median.value);
        tree.root = new_root;
        tree.counters.splits += 1;
        tree.counters.root_splits += 1;
        node = new_root;
    }

    // Loop invariant: `node` is NOT full, so it can take one more key.
    while (true) {
        std.debug.assert(node.len < N.max_keys);
        const i = search.lowerBound(node.keySlice(), key);
        if (i < node.len and node.keys[i] == key) {
            const old = node.values[i];
            node.values[i] = value;
            return old;
        }
        if (node.leaf) {
            node.insertEntry(i, key, value); // room is guaranteed: no overflow slot needed
            tree.len += 1;
            return null;
        }
        var child = node.children[i].?;
        if (child.len == N.max_keys) {
            // Split the full child BEFORE entering it. Its median moves into
            // `node`, which has room by the invariant.
            const right = try tree.pool.create(gpa);
            const median = splitFull(N, child, right);
            node.insertChild(i + 1, right);
            node.insertEntry(i, median.key, median.value);
            tree.counters.splits += 1;
            // The key now belongs left of the median, right of it, or IS it.
            if (key == median.key) {
                node.values[i] = value;
                return median.value;
            }
            if (key > median.key) child = right;
        }
        node = child;
    }
}

/// Split a FULL node (len == M - 1, M even) around its median. `left` keeps
/// the lower M/2 - 1 keys, `right` (uninitialised) receives the upper
/// M/2 - 1, and the median entry is returned for the parent. Both halves end
/// up at exactly `min_keys`: a split never produces a node with fewer keys.
fn splitFull(comptime N: type, left: *N, right: *N) node_mod.Entry {
    std.debug.assert(left.len == N.max_keys);
    const mid = N.max_keys / 2;
    right.* = .{ .leaf = left.leaf };
    for (mid + 1..left.len) |i| right.insertEntry(right.len, left.keys[i], left.values[i]);
    if (!left.leaf) {
        // Children right of the median move with their keys.
        for (mid + 1..left.len + 1) |i| {
            right.children[i - (mid + 1)] = left.children[i];
            left.children[i] = null;
        }
    }
    const median: node_mod.Entry = .{ .key = left.keys[mid], .value = left.values[mid] };
    left.len = mid;
    std.debug.assert(left.len == N.min_keys and right.len == N.min_keys);
    return median;
}

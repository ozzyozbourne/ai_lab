// Copied from chapters/05-deletion-and-rebalancing/zig/src/insert.zig
// Changes for chapter 06: coverage points instead of counters, and one fault
// seam (search for "SEAM") that is only compiled into a broken variant.
//! SECTION 4: insert with bottom-up splitting (explained in chapter 04).
//!
//! `put` works in three phases:
//!   1. descend to the leaf, remembering the path (node + child index per level);
//!   2. RESERVE every node the splits will need. This is the only step that
//!      can fail, and the tree has not been touched yet;
//!   3. COMMIT: insert into the leaf, then split upwards along the path while
//!      a node is overfull. Nothing in this phase can fail.
//! Reserving first means an allocation failure leaves the tree exactly as it
//! was (tests.zig and fault_alloc.zig check exactly that). The pool's
//! `usage` counters are put back as well, so a failed `put` cannot be seen
//! from the tree at all. The one trace it can leave is inside the pool: a
//! slot that was carved for a reservation and returned stays on the pool's
//! free list.
//!
//! This file needs base_node.zig and base_search.zig (`lowerBound`), nothing
//! from base_delete.zig.
const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("base_node.zig");
const search = @import("base_search.zig");

/// A tree of order 3 with 2^64 keys is at most 64 levels high (chapter 03).
pub const max_height = 64;

/// `Tree` is a `BTreeWith(M, PoolFn, bug)` from base_btree.zig; this function
/// uses its `root`, `len`, `pool` and `coverage` fields.
/// Returns the previous value if the key was already present (overwrite).
/// On error.OutOfMemory the tree and `pool.usage` are unchanged.
pub fn put(comptime Tree: type, tree: *Tree, gpa: Allocator, key: u64, value: u64) Allocator.Error!?u64 {
    const N = Tree.NodeT;

    const root = tree.root orelse {
        const leaf = tree.pool.create(gpa) catch |err| {
            tree.coverage.hit(.put_oom);
            return err;
        };
        tree.coverage.hit(.put_first_key);
        leaf.* = .{ .leaf = true };
        leaf.insertEntry(0, key, value);
        tree.root = leaf;
        tree.len = 1;
        return null;
    };

    // Phase 1: descend. path[d].index is the child we followed at depth d
    // (in the leaf: the position where the key belongs).
    var path: [max_height]struct { node: *N, index: usize } = undefined;
    var depth: usize = 0;
    var node = root;
    while (true) {
        const i = search.lowerBound(node.keySlice(), key);
        if (i < node.len and node.keys[i] == key) {
            const old = node.values[i];
            node.values[i] = value; // duplicate key: overwrite, no structural change
            tree.coverage.hit(.put_overwrite);
            return old;
        }
        path[depth] = .{ .node = node, .index = i };
        depth += 1;
        if (node.leaf) break;
        node = node.children[i].?;
    }

    // Phase 2: reserve. A split propagates upwards exactly as long as the
    // nodes on the path are full, so count the full nodes from the leaf up.
    var need: usize = 0;
    while (need < depth and path[depth - 1 - need].node.len == N.max_keys) need += 1;
    if (need == depth) need += 1; // the root splits too: one more node for the new root
    var spare: [max_height + 1]*N = undefined;
    var reserved: usize = 0;
    const usage_before = tree.pool.usage;
    errdefer {
        // Hand back what we already took, and forget that we took it:
        // `usage` (created, destroyed, peak) counts nodes of the tree, and
        // these never became part of it.
        for (spare[0..reserved]) |n| tree.pool.destroy(gpa, n);
        tree.pool.usage = usage_before;
        tree.coverage.hit(if (reserved > 0) .put_oom_rollback else .put_oom);
    }
    while (reserved < need) : (reserved += 1) spare[reserved] = try tree.pool.create(gpa);

    // Phase 3: commit.
    var level = depth - 1;
    path[level].node.insertEntry(path[level].index, key, value);
    tree.len += 1;
    if (need == 0) tree.coverage.hit(.put_no_split);
    var used: usize = 0;
    while (path[level].node.len > N.max_keys) {
        const left = path[level].node;
        const right = spare[used];
        used += 1;
        const median = splitNode(N, left, right, Tree.bug);
        tree.coverage.hit(if (left.leaf) .split_leaf else .split_interior);
        if (level == 0) {
            // The root was split: the tree grows by one level, at the top.
            // This is the only way a B-tree gets taller, which is why all
            // leaves stay at the same depth.
            const new_root = spare[used];
            used += 1;
            new_root.* = .{ .leaf = false };
            new_root.children[0] = left;
            new_root.insertChild(1, right);
            new_root.insertEntry(0, median.key, median.value);
            tree.root = new_root;
            tree.coverage.hit(if (left.leaf) .root_split_leaf else .root_split_interior);
            break;
        }
        // Push the median into the parent, right half next to the left half.
        // The parent may now be overfull: the loop handles it.
        level -= 1;
        const parent = path[level].node;
        parent.insertChild(path[level].index + 1, right);
        parent.insertEntry(path[level].index, median.key, median.value);
    }
    std.debug.assert(used == need);
    return null;
}

/// Split an overfull node (len == M) around its median. `left` keeps the
/// lower half, `right` (uninitialised) receives the upper half, and the
/// median entry is returned for the parent. With `mid = M / 2`:
/// left keeps mid keys, right gets M - 1 - mid keys; both are >= min_keys.
fn splitNode(comptime N: type, left: *N, right: *N, comptime bug: anytype) node_mod.Entry {
    const total = left.len; // == M
    const mid = total / 2;
    right.* = .{ .leaf = left.leaf };
    for (mid + 1..total) |i| right.insertEntry(right.len, left.keys[i], left.values[i]);
    if (!left.leaf) {
        // Children right of the median move with their keys.
        for (mid + 1..total + 1) |i| {
            right.children[i - (mid + 1)] = left.children[i];
            left.children[i] = null;
        }
    }
    // SEAM split_wrong_value: the key goes up with the value of its left
    // neighbour. Every node keeps a legal shape, so `validate` stays silent;
    // only a comparison of answers with the oracle can notice.
    const value_at = if (bug == .split_wrong_value) mid - 1 else mid;
    const median: node_mod.Entry = .{ .key = left.keys[mid], .value = left.values[value_at] };
    left.len = mid;
    std.debug.assert(left.len >= N.min_keys and right.len >= N.min_keys);
    return median;
}

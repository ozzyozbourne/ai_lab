//! Insert, with a split done as TWO separate atomic steps (as in Postgres):
//!
//!   step 1  `halfSplit`     under the exclusive latch of the full node only:
//!                           create the right sibling, move the upper half
//!                           into it, set high keys and right links, and set
//!                           INCOMPLETE_SPLIT on the left node.
//!                           (Postgres: _bt_split, nbtinsert.c:1486-2109.)
//!   step 2  `insertParent`  insert the downlink to the new sibling into the
//!                           parent and clear the flag, both under the
//!                           parent's exclusive latch.
//!                           (Postgres: _bt_insert_parent, nbtinsert.c:2127-2254.)
//!
//! After step 1 the tree is already correct for every reader: the moved keys
//! are one right link away. Step 2 only makes the path shorter. If step 2
//! never happens (the test hook `abandon_splits`, or the node table ran out
//! while the parent needed to split), the flag stays, and the next writer
//! that latches the node finishes the job before doing its own
//! (`finishSplit`; Postgres: _bt_finish_split, nbtinsert.c:2269-2315).
//!
//! Latches held by a writer:
//!   going down   one at a time, like a reader (shared, exclusive on the leaf);
//!   going up     the child stays latched until its downlink is in the parent,
//!                so child + parent, plus one more level while it finishes
//!                somebody else's split of that parent.
//! The order is always child before parent and never left-and-right at once;
//! the `meta` mutex comes last. With one global order there is no deadlock.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

const blink = @import("blink.zig");
const BLinkTree = blink.BLinkTree;
const NodeId = blink.NodeId;
const Page = blink.Page;
const PutError = blink.PutError;
const base_search = @import("base_search.zig");

/// The nodes a writer came through on its way down: at[l] is the node of
/// level l (l >= 1) from which it followed a downlink. Like Postgres'
/// BTStack it is only a HINT for finding the parent later: by then that node
/// may have split, and the real parent may be further right.
const Stack = struct {
    at: [blink.max_levels]NodeId = @splat(.nil),
};

/// Result of step 2 for one split.
const Finish = enum {
    /// Downlink inserted (or new root built) and flag cleared.
    done,
    /// A node was needed and the table is full. The split stays incomplete,
    /// which is a legal state of the tree.
    out_of_nodes,
};

pub fn put(tree: *BLinkTree, io: Io, key: u64, value: u64) PutError!?u64 {
    var stack: Stack = .{};

    // ---- Descend to the leaf whose key range contains `key`. -------------
    var id = tree.rootId();
    var exclusive = false; // mode of the latch we hold on `id`
    _ = tree.lockShared(io, id);
    while (true) {
        if (tree.page(id).level == 0 and !exclusive) {
            // We reached a leaf with a shared latch (only happens when the
            // root is a leaf). There is no upgrade: release, then take the
            // exclusive latch. Whatever happened in between is handled by
            // moveRight below. Postgres: nbtsearch.c:191-201.
            tree.unlockShared(io, id);
            _ = tree.lockExclusive(io, id);
            exclusive = true;
        }
        id = try moveRight(tree, io, id, key, exclusive, &stack);
        const page = tree.page(id);
        if (page.level == 0) break;

        stack.at[page.level] = id;
        const child = page.node.kind.internal.children[base_search.childIndex(page.node.keySlice(), key)];
        // The children of a level-1 node are leaves: latch them exclusively
        // straight away. The level is known from the parent, so no peeking
        // at an unlatched node is needed.
        const child_is_leaf = page.level == 1;
        // Release the parent BEFORE latching the child: no lock coupling.
        // If the child splits in this gap, moveRight repairs the path.
        unlatch(tree, io, id, exclusive);
        id = child;
        exclusive = child_is_leaf;
        latch(tree, io, id, exclusive);
    }

    // ---- Insert into the leaf (exclusively latched, flag clear). ----------
    const leaf = tree.page(id);
    const keys = leaf.node.keySlice();
    const i = base_search.lowerBound(keys, key);
    if (i < keys.len and keys[i] == key) {
        const values = &leaf.node.kind.leaf.values;
        const old = values[i];
        values[i] = value;
        tree.unlockExclusive(io, id);
        return old;
    }
    if (leaf.node.len < tree.maxKeys()) {
        leaf.node.leafInsertAt(i, key, value);
        _ = tree.count.fetchAdd(1, .monotonic);
        tree.unlockExclusive(io, id);
        return null;
    }

    // The leaf is full. Get the new node BEFORE changing anything, so that
    // a full table leaves the tree exactly as it was.
    const right_id = tree.allocPage(0) catch |err| {
        tree.unlockExclusive(io, id);
        return err;
    };
    // The arrays have one spare slot (base_node.key_capacity), so the leaf
    // may hold M keys for a moment; halfSplit cuts it in two right away.
    leaf.node.leafInsertAt(i, key, value);
    _ = tree.count.fetchAdd(1, .monotonic);
    halfSplit(tree, leaf, right_id);

    if (tree.abandon_splits.load(.acquire)) {
        // TEST HOOK: stop between the two steps. The key is in the tree and
        // every reader can find it; only the downlink is missing.
        tree.unlockExclusive(io, id);
        return null;
    }
    // Step 2. Whether it succeeds or not, the put itself has succeeded.
    _ = insertParent(tree, io, id, &stack);
    return null;
}

fn latch(tree: *BLinkTree, io: Io, id: NodeId, exclusive: bool) void {
    if (exclusive) _ = tree.lockExclusive(io, id) else _ = tree.lockShared(io, id);
}

fn unlatch(tree: *BLinkTree, io: Io, id: NodeId, exclusive: bool) void {
    if (exclusive) tree.unlockExclusive(io, id) else tree.unlockShared(io, id);
}

/// The writer's version of "move right" (Postgres: _bt_moveright with
/// forupdate, nbtsearch.c:243-331).
///
/// `start` is latched in the given mode. Returns the node on the same level
/// whose key range contains `key`, latched in the same mode, with its
/// INCOMPLETE_SPLIT flag clear. On error no latch is held.
fn moveRight(tree: *BLinkTree, io: Io, start: NodeId, key: u64, exclusive: bool, stack: *const Stack) PutError!NodeId {
    var id = start;
    while (true) {
        const page = tree.page(id);
        if (page.incomplete_split) {
            // A writer never walks past a half-finished split: it finishes
            // it first. That needs the exclusive latch.
            if (!exclusive) {
                tree.unlockShared(io, id);
                _ = tree.lockExclusive(io, id);
            }
            // Re-check: between the two latches another writer may have
            // finished the split already.
            if (page.incomplete_split) {
                if (finishSplit(tree, io, id, stack) == .out_of_nodes) return error.OutOfNodes;
            } else {
                tree.unlockExclusive(io, id);
            }
            // finishSplit released the latch. Take it again in our mode and
            // look at the node afresh.
            latch(tree, io, id, exclusive);
            continue;
        }
        if (!page.isBeyond(key)) return id;
        const next = page.right;
        unlatch(tree, io, id, exclusive);
        latch(tree, io, next, exclusive);
        _ = tree.moves_right.fetchAdd(1, .monotonic);
        id = next;
    }
}

/// STEP 1 of a split. `left` is exclusively latched and holds M keys (one
/// too many); `right_id` is a fresh node nobody else can see yet.
///
/// When this returns, `left` and the new node together hold exactly what
/// `left` held before, the level's linked list has one more element, and
/// `left` is flagged. Readers are served correctly from this moment on.
fn halfSplit(tree: *BLinkTree, left: *Page, right_id: NodeId) void {
    const right = tree.page(right_id);
    assert(left.node.len == tree.order and !left.incomplete_split);
    assert(right.level == left.level);

    const mid = left.node.len / 2;
    var separator: u64 = undefined;
    switch (left.node.kind) {
        .leaf => |*from| {
            // floor(M/2) entries stay, ceil(M/2) move. The separator is a
            // COPY of the first moved key (copy-up, chapter 07).
            const moved = left.node.len - mid;
            @memcpy(right.node.keys[0..moved], left.node.keys[mid..left.node.len]);
            @memcpy(right.node.kind.leaf.values[0..moved], from.values[mid..left.node.len]);
            right.node.len = moved;
            separator = right.node.keys[0];
        },
        .internal => |*from| {
            // The middle separator leaves the node (push-up, chapter 07).
            // It does not go into the parent yet: it becomes `left`'s high
            // key, and step 2 copies it from there.
            const moved = left.node.len - mid - 1;
            @memcpy(right.node.keys[0..moved], left.node.keys[mid + 1 .. left.node.len]);
            @memcpy(right.node.kind.internal.children[0 .. moved + 1], from.children[mid + 1 .. left.node.len + 1]);
            right.node.len = moved;
            separator = left.node.keys[mid];
        },
    }
    left.node.len = mid;

    // The new node takes over the old upper bound and the old right link ...
    right.high_key = left.high_key;
    right.right = left.right;
    // ... and only then does `left` point at it. (Under the exclusive latch
    // nobody can observe the order of these writes; it is written this way
    // because it is the order a lock-free publication would need.)
    left.high_key = separator;
    left.right = right_id;
    left.incomplete_split = true;
    _ = tree.half_splits.fetchAdd(1, .monotonic);
}

/// Finishes a split that some earlier operation left half-done.
/// `left_id` is exclusively latched and flagged; the latch is released.
fn finishSplit(tree: *BLinkTree, io: Io, left_id: NodeId, stack: *const Stack) Finish {
    assert(tree.page(left_id).incomplete_split);
    const result = insertParent(tree, io, left_id, stack);
    if (result == .done) _ = tree.finished_later.fetchAdd(1, .monotonic);
    return result;
}

/// STEP 2 of a split: give the right half of `left_id` its downlink.
///
/// `left_id` is exclusively latched and flagged. Its latch is released
/// before returning, but not before the downlink is in place and the flag is
/// clear: both change under the parent's latch, so no thread can ever see a
/// downlink together with the flag, or neither.
fn insertParent(tree: *BLinkTree, io: Io, left_id: NodeId, stack: *const Stack) Finish {
    const left = tree.page(left_id);
    assert(left.incomplete_split);
    const level = left.level;
    // The downlink is (left's high key, left's right link). Postgres builds
    // it the same way: nbtinsert.c:2206-2212.
    const separator = left.high_key.?;
    const right_id = left.right;

    // ---- Where is the parent level? -----------------------------------
    var parent_id = stack.at[level + 1];
    if (parent_id == .nil) {
        // We did not come through a node of level+1: `left` was the root
        // when we started. Is it still?
        tree.meta.lockUncancelable(io);
        if (tree.rootId() == left_id) {
            // Root split: build a new root above the two halves. This is
            // the only way the tree grows, and it is step 2 of the root's
            // split (Postgres: _bt_newlevel, nbtinsert.c:2489-2655).
            const new_root = tree.allocPage(level + 1) catch {
                tree.meta.unlock(io);
                tree.unlockExclusive(io, left_id);
                return .out_of_nodes;
            };
            const root = tree.page(new_root);
            root.node.kind.internal.children[0] = left_id;
            root.node.internalInsertAt(0, separator, right_id);
            tree.level_head[level + 1] = new_root;
            tree.height = level + 2;
            left.incomplete_split = false;
            // Publishing the root last: a reader that still starts at the
            // old root finds everything by moving right.
            tree.root.store(@backingInt(new_root), .release);
            _ = tree.completed_splits.fetchAdd(1, .monotonic);
            tree.meta.unlock(io);
            tree.unlockExclusive(io, left_id);
            return .done;
        }
        // Somebody else grew the tree meanwhile. Start at the leftmost node
        // of the parent level and walk right.
        parent_id = tree.level_head[level + 1];
        tree.meta.unlock(io);
        assert(parent_id != .nil);
    }

    // ---- Find the node that holds the downlink to `left`. ---------------
    // Search by CHILD ID, not by key, moving right as needed (Postgres:
    // _bt_getstackbuf, nbtinsert.c:2348-2453). We hold `left`, then latch a
    // parent-level node: child before parent, the one allowed order.
    var parent: *Page = undefined;
    var slot: usize = undefined;
    while (true) {
        parent = tree.lockExclusive(io, parent_id);
        if (parent.incomplete_split) {
            // The flag can describe only ONE missing downlink. Inserting
            // into this node might split it again, so finish the pending
            // split first (Postgres: nbtinsert.c:2368-2372).
            if (finishSplit(tree, io, parent_id, stack) == .out_of_nodes) {
                tree.unlockExclusive(io, left_id);
                return .out_of_nodes;
            }
            continue; // latch the same node again and look afresh
        }
        if (std.mem.indexOfScalar(NodeId, parent.node.childSlice(), left_id)) |found| {
            slot = found;
            break;
        }
        const next = parent.right;
        tree.unlockExclusive(io, parent_id);
        // The downlink exists (writers finish incomplete splits before they
        // go on), and downlinks only move right. Not finding it is a bug.
        if (next == .nil) @panic("B-link tree: downlink of a split node not found");
        parent_id = next;
    }

    // ---- Insert the downlink; split the parent if it is full. ------------
    var parent_right: NodeId = .nil;
    if (parent.node.len == tree.maxKeys()) {
        // Allocate before modifying, as in `put`.
        parent_right = tree.allocPage(level + 1) catch {
            tree.unlockExclusive(io, parent_id);
            tree.unlockExclusive(io, left_id);
            return .out_of_nodes;
        };
    }
    // Child `slot` is `left`; the new sibling goes right after it.
    parent.node.internalInsertAt(slot, separator, right_id);
    left.incomplete_split = false;
    _ = tree.completed_splits.fetchAdd(1, .monotonic);
    // The split of `left` is complete: let go of it before going further up.
    tree.unlockExclusive(io, left_id);

    if (parent_right == .nil) {
        tree.unlockExclusive(io, parent_id);
        return .done;
    }
    // The parent overflowed: the same two steps, one level up.
    halfSplit(tree, parent, parent_right);
    if (tree.abandon_splits.load(.acquire)) {
        tree.unlockExclusive(io, parent_id);
        return .done;
    }
    // The result of the parent's step 2 is not ours to report: the split of
    // `left`, which is what the caller asked about, is done.
    _ = insertParent(tree, io, parent_id, stack);
    return .done;
}

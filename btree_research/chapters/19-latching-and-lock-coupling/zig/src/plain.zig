//! The single-threaded algorithm: no latch anywhere. Correct only while the
//! caller holds a lock that keeps every other thread out (tree.zig takes the
//! tree-wide mutex or reader-writer lock around these two functions).
//!
//! Compare with coupled.zig line by line: the searches and the splits are the
//! same; that file adds only the latch calls.
const std = @import("std");

const tree_ = @import("tree.zig");
const Tree = tree_.Tree;
const NodeId = tree_.NodeId;
const search = @import("base_search.zig");
const insert = @import("insert.zig");

pub fn get(tree: *const Tree, key: u64) ?u64 {
    var id = tree.root.load(.acquire);
    while (true) {
        const n = tree.table.node(id);
        switch (n.kind) {
            .internal => |*in| id = in.children[search.childIndex(n.keySlice(), key)],
            .leaf => |*leaf| {
                const i = search.lowerBound(n.keySlice(), key);
                return if (i < n.len and n.keys[i] == key) leaf.values[i] else null;
            },
        }
    }
}

pub fn put(tree: *Tree, key: u64, value: u64) tree_.Error!?u64 {
    // Remember the whole path: any node on it may have to split.
    var path: [tree_.max_height]NodeId = undefined;
    var depth: usize = 0;
    var id = tree.root.load(.acquire);
    while (true) {
        path[depth] = id;
        depth += 1;
        const n = tree.table.node(id);
        switch (n.kind) {
            .internal => |*in| id = in.children[search.childIndex(n.keySlice(), key)],
            .leaf => break,
        }
    }
    return insert.insertAtLeaf(tree, path[0..depth], true, key, value);
}

//! `Tree`: the chapter 07 B+tree plus ONE new field, a change counter.
//!
//! The B+tree itself is copied unchanged (`base_*.zig`). This wrapper adds
//! what cursors need to notice that the tree changed between two of their
//! steps: `version` goes up whenever an entry is added or removed. Those are
//! exactly the operations that can shift entries inside a leaf, split or
//! merge nodes, and free a node whose handle is then reused for another one.
//!
//! An overwrite (`put` on an existing key) moves nothing, so it does not
//! count: a cursor standing on that entry simply sees the new value.
const std = @import("std");
const Allocator = std.mem.Allocator;

const BPlusTree = @import("base_tree.zig").BPlusTree;
const Violation = @import("base_validate.zig").Violation;
const bounds = @import("bounds.zig");
const Bound = bounds.Bound;
const scan = @import("scan.zig");
const LinkCursor = @import("link_cursor.zig").LinkCursor;

pub const Tree = struct {
    base: BPlusTree,
    /// Number of inserts and deletes so far. A cursor remembers the value it
    /// saw when it computed its position; a different value means "your
    /// (node, index) may point anywhere now: seek again by key".
    version: u64 = 0,

    pub fn init(order: usize) Tree {
        return .{ .base = .init(order) };
    }

    pub fn deinit(self: *Tree, gpa: Allocator) void {
        self.base.deinit(gpa);
    }

    pub fn len(self: *const Tree) usize {
        return self.base.len();
    }

    pub fn get(self: *const Tree, key: u64) ?u64 {
        return self.base.get(key);
    }

    /// Inserts or overwrites; returns the previous value if the key existed.
    /// On `error.OutOfMemory` neither the tree nor `version` has changed.
    pub fn put(self: *Tree, gpa: Allocator, key: u64, value: u64) Allocator.Error!?u64 {
        const old = try self.base.put(gpa, key, value);
        if (old == null) self.version += 1; // a new entry: positions may have moved
        return old;
    }

    pub fn delete(self: *Tree, key: u64) ?u64 {
        const removed = self.base.delete(key);
        if (removed != null) self.version += 1;
        return removed;
    }

    pub fn validate(self: *const Tree) Violation!void {
        return self.base.validate();
    }

    /// Entries with `lo <= / < key <= / < hi` in ascending order, through a
    /// leaf-link cursor (no allocation). For the other cursor or a custom
    /// one, build a `scan.Scan(...)` directly.
    pub fn range(self: *const Tree, lo: Bound, hi: Bound) scan.Scan(LinkCursor) {
        return .init(self, .init(.{}), lo, hi, .forward);
    }

    /// The same entries in descending order.
    pub fn rangeBackward(self: *const Tree, lo: Bound, hi: Bound) scan.Scan(LinkCursor) {
        return .init(self, .init(.{}), lo, hi, .backward);
    }
};

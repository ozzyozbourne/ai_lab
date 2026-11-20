//! The page store: fixed-size slots addressed by page id (the "file"), the
//! list of slots that may be written, and the two metapage slots.
//!
//! This is the page slab of the chapter. It is a stand-in for a database file
//! behind a pager (chapter 09): slot i is "the page at offset i * page_size".
//! The store enforces the one rule everything else depends on:
//!
//!     `write` only ever targets a FREE slot.
//!
//! A slot is free when no committed root and no snapshot can reach it. So a
//! page that some reader may be looking at is never modified, by construction.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const base_node = @import("base_node.zig");
const Node = base_node.Node;
const PageId = base_node.PageId;
const meta = @import("meta.zig");

pub const SlotState = enum {
    /// Not part of any tree; listed in `free` (or reserved by the open write
    /// transaction). Its content is garbage.
    free,
    /// Written by a committed transaction and not yet released.
    live,
};

pub const Slot = struct {
    state: SlotState = .free,
    /// Id of the transaction that last wrote this slot. `validate` uses it to
    /// prove that no page was written after a root that still reaches it.
    written_by: u64 = 0,
    node: Node = undefined,
};

pub const PageStore = struct {
    slots: std.ArrayList(Slot) = .empty,
    /// Page ids that may be written right now, used as a stack.
    /// Invariant: capacity >= slots.len, so pushing a page id never allocates
    /// (releasing pages must not be able to fail).
    free: std.ArrayList(PageId) = .empty,
    meta_slots: meta.Slots = @splat(@splat(0)),

    pub fn deinit(self: *PageStore, gpa: Allocator) void {
        self.slots.deinit(gpa);
        self.free.deinit(gpa);
        self.* = .{};
    }

    pub fn pageCount(self: *const PageStore) usize {
        return self.slots.items.len;
    }

    pub fn isLive(self: *const PageStore, id: PageId) bool {
        return id != .nil and id.index() < self.slots.items.len and self.slots.items[id.index()].state == .live;
    }

    /// A committed page. Readers get a const pointer: nothing may change it.
    pub fn read(self: *const PageStore, id: PageId) *const Node {
        const slot = &self.slots.items[id.index()];
        assert(slot.state == .live);
        return &slot.node;
    }

    /// Makes room for `page_count` slots (new ones are free but NOT listed in
    /// `free`; the caller decides what happens to them).
    pub fn grow(self: *PageStore, gpa: Allocator, page_count: usize) Allocator.Error!void {
        if (page_count <= self.slots.items.len) return;
        try self.slots.ensureTotalCapacity(gpa, page_count);
        try self.free.ensureTotalCapacity(gpa, page_count);
        while (self.slots.items.len < page_count) self.slots.appendAssumeCapacity(.{});
    }

    /// The only function that writes page content.
    pub fn write(self: *PageStore, id: PageId, node: *const Node, txn_id: u64) void {
        const slot = &self.slots.items[id.index()];
        assert(slot.state == .free); // never overwrite a page a root can reach
        slot.* = .{ .state = .live, .written_by = txn_id, .node = node.* };
    }

    /// A live page that no root can reach any more becomes writable again.
    pub fn release(self: *PageStore, id: PageId) void {
        const slot = &self.slots.items[id.index()];
        assert(slot.state == .live);
        slot.state = .free;
        self.free.appendAssumeCapacity(id);
    }
};

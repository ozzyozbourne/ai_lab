//! Text rendering of a Db for the demo program and for debugging.
//!
//!     now=7 horizon=3 | height 2, 4 entries, 3 pages
//!       level 0: #2[20.1]
//!       leaves : #0(10:1-) -> #1(20:2-4! 20:4- 30:3-5)
//!       deleted: #5@9->#1
//!       free   : #4
//!
//! `#n` is a page handle. `[..]` is an internal page; a separator is printed
//! as `key.tid`. `(..)` is a leaf; an entry is printed as `key:xmin-xmax`
//! (the two numbers come from the version store, not from the index), `-`
//! with nothing after it means "not deleted", and `!` is the dead hint bit.
//! `#n(half-dead)` is a page between the two phases. A deleted page is shown
//! with its stamp and the right link it keeps. `free` is the arena's free
//! list: the next split takes the first page on it.
const std = @import("std");
const Writer = std.Io.Writer;
const node = @import("base_node.zig");
const Db = @import("db.zig").Db;
const NodeId = @import("base_arena.zig").NodeId;

pub fn dump(db: *const Db, w: *Writer) Writer.Error!void {
    const index = &db.index;
    try w.print("now={d} horizon={d} | height {d}, {d} entries, {d} pages\n", .{
        db.store.now, db.store.horizon(), index.height, index.count, index.nodes.liveCount(),
    });
    if (index.root == .nil) return;
    for (1..index.height) |depth| {
        try w.print("  level {d}:", .{depth - 1});
        try printLevel(db, index.root, depth - 1, w);
        try w.writeByte('\n');
    }
    try w.writeAll("  leaves :");
    var id = index.first_leaf;
    while (id != .nil) {
        try w.writeByte(' ');
        try printNode(db, id, w);
        id = index.nodes.get(id).kind.leaf.next;
        if (id != .nil) try w.writeAll(" ->");
    }
    try w.writeByte('\n');
    if (index.deleted_head != .nil) {
        try w.writeAll("  deleted:");
        id = index.deleted_head;
        while (id != .nil) {
            const leaf = &index.nodes.get(id).kind.leaf;
            try w.print(" #{d}@{d}->", .{ id.index(), leaf.state.deleted });
            if (leaf.next == .nil) try w.writeAll("end") else try w.print("#{d}", .{leaf.next.index()});
            id = leaf.next_deleted;
        }
        try w.writeByte('\n');
    }
    if (index.nodes.free_head != .nil) {
        try w.writeAll("  free   :");
        id = index.nodes.free_head;
        while (id != .nil) : (id = index.nodes.slots.items[id.index()].free) try w.print(" #{d}", .{id.index()});
        try w.writeByte('\n');
    }
}

/// Prints the internal pages that are `levels_down` levels below `id`.
fn printLevel(db: *const Db, id: NodeId, levels_down: usize, w: *Writer) Writer.Error!void {
    if (levels_down == 0) {
        try w.writeByte(' ');
        return printNode(db, id, w);
    }
    for (db.index.nodes.get(id).childSlice()) |child| try printLevel(db, child, levels_down - 1, w);
}

fn printNode(db: *const Db, id: NodeId, w: *Writer) Writer.Error!void {
    const n = db.index.nodes.get(id);
    try w.print("#{d}", .{id.index()});
    switch (n.kind) {
        .internal => {
            try w.writeByte('[');
            for (n.keySlice(), 0..) |k, i| {
                if (i != 0) try w.writeByte(' ');
                try w.print("{d}.{d}", .{ node.userKey(k), node.tidOf(k).index() });
            }
            try w.writeByte(']');
        },
        .leaf => |*leaf| {
            if (leaf.state == .half_dead) return w.writeAll("(half-dead)");
            try w.writeByte('(');
            for (n.keySlice(), 0..) |k, i| {
                if (i != 0) try w.writeByte(' ');
                const v = db.store.versions.get(node.tidOf(k));
                try w.print("{d}:{d}-", .{ v.key, v.xmin });
                if (v.xmax != 0) try w.print("{d}", .{v.xmax});
                if (leaf.dead[i]) try w.writeByte('!');
            }
            try w.writeByte(')');
        },
    }
}

//! Library root of chapter 18: a tiny table engine on top of the chapter 07
//! B+tree, in two layouts (clustered, heap + index).
//!
//!   base_*.zig   the in-memory B+tree, copied from chapter 07
//!   row.zig      the table's row, and composite index keys packed into u64
//!   cursor.zig   cost counters and the counting range cursor
//!   heap.zig     the heap: rows addressed by TID
//!   table.zig    Table: insert, delete, unique check, the four kinds of query
//!   prng.zig     SplitMix64 (copied from common/)
const std = @import("std");

pub const row = @import("row.zig");
pub const cursor = @import("cursor.zig");
pub const heap = @import("heap.zig");
pub const table = @import("table.zig");
pub const prng = @import("prng.zig");
pub const dump = @import("base_dump.zig");

pub const Row = row.Row;
pub const Locator = row.Locator;
pub const KeyRange = row.KeyRange;
pub const Counters = cursor.Counters;
pub const Cursor = cursor.Cursor;
pub const Heap = heap.Heap;
pub const Table = table.Table;
pub const Layout = table.Layout;
pub const BPlusTree = @import("base_tree.zig").BPlusTree;
pub const LeafWalker = @import("base_walk.zig").LeafWalker;

test {
    // A test block only runs if its file is referenced from here.
    _ = @import("base_arena.zig");
    _ = @import("base_node.zig");
    _ = @import("base_search.zig");
    _ = @import("base_ops.zig");
    _ = @import("base_tests.zig");
    _ = row;
    _ = cursor;
    _ = heap;
    _ = prng;
    _ = @import("tests.zig");
}

//! Library root of chapter 08: range scans and cursors on the chapter 07
//! B+tree.
//!
//!   base_*.zig        the B+tree, copied unchanged from chapter 07
//!   tree.zig          Tree = B+tree + a change counter (`version`)
//!   bounds.zig        Bound (unbounded / included / excluded), prefixRange
//!   cursor.zig        Seek, Cursor(Position): save key and re-seek
//!   link_cursor.zig   LinkPosition: leaf + index, follows sibling links
//!   stack_cursor.zig  StackPosition: root-to-leaf path, no sibling links
//!   scan.zig          Scan(Cursor): range scan in either direction
//!   model.zig         seeded model run against the oracle
const std = @import("std");

pub const bounds = @import("bounds.zig");
pub const cursor = @import("cursor.zig");
pub const link_cursor = @import("link_cursor.zig");
pub const stack_cursor = @import("stack_cursor.zig");
pub const scan = @import("scan.zig");
pub const model = @import("model.zig");
pub const dump = @import("base_dump.zig");
pub const ops = @import("ops.zig");
pub const prng = @import("prng.zig");

pub const Tree = @import("tree.zig").Tree;
pub const BPlusTree = @import("base_tree.zig").BPlusTree;
pub const NodeId = @import("base_arena.zig").NodeId;
pub const Entry = @import("base_node.zig").Entry;
pub const LeafWalker = @import("base_walk.zig").LeafWalker;
pub const Bound = bounds.Bound;
pub const Direction = bounds.Direction;
pub const Seek = cursor.Seek;
pub const Scan = scan.Scan;
pub const LinkCursor = link_cursor.LinkCursor;
pub const LinkPosition = link_cursor.LinkPosition;
pub const StackCursor = stack_cursor.StackCursor;
pub const StackPosition = stack_cursor.StackPosition;

test {
    // A test block only runs if its file is referenced from here.
    _ = @import("base_arena.zig");
    _ = @import("base_node.zig");
    _ = @import("base_search.zig");
    _ = bounds;
    _ = cursor;
    _ = ops;
    _ = prng;
    _ = @import("tests.zig");
}

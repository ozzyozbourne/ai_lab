//! Library root of chapter 07: an in-memory B+tree on an index arena.
//!
//! One concern per file, so that later chapters can copy exactly what they
//! need (as `base_*.zig`):
//!
//!   arena.zig     NodeId handles, Arena(T): growable slot array + free list
//!   node.zig      Node layout (leaf / internal) and in-node array surgery
//!   tree.zig      BPlusTree: fields, invariants, public method names
//!   search.zig    lowerBound / upperBound / childIndex, findLeaf, get
//!   insert.zig    put: leaf split (copy-up), internal split (push-up)
//!   delete.zig    delete: borrow, merge, root shrink
//!   walk.zig      LeafWalker: minimal forward walk over the leaf chain
//!   validate.zig  every invariant as code
//!   dump.zig      text rendering
const std = @import("std");

pub const arena = @import("arena.zig");
pub const node = @import("node.zig");
pub const search = @import("search.zig");
pub const dump = @import("dump.zig");
pub const ops = @import("ops.zig");

pub const NodeId = arena.NodeId;
pub const Arena = arena.Arena;
pub const Node = node.Node;
pub const Entry = node.Entry;
pub const BPlusTree = @import("tree.zig").BPlusTree;
pub const Stats = @import("tree.zig").Stats;
pub const LeafWalker = @import("walk.zig").LeafWalker;
pub const Violation = @import("validate.zig").Violation;

test {
    // A test block only runs if its file is referenced from here.
    _ = arena;
    _ = node;
    _ = search;
    _ = ops;
    _ = @import("tests.zig");
}

//! Library root of chapter 19: one B+tree on a preallocated node table,
//! shared by several threads under three lock protocols.
//!
//!   base_node.zig    Node layout (copied from chapter 07, trimmed)
//!   base_search.zig  binary search inside a node (copied from chapter 07)
//!   table.zig        NodeTable: fixed array of {latch, node}, atomic bump
//!   tree.zig         Tree: fields, the three protocols, the test hook
//!   plain.zig        get / put with no latches (under a tree-wide lock)
//!   coupled.zig      get / put with latch coupling and the safe-node rule
//!   insert.zig       leaf insert and splits, shared by plain and coupled
//!   validate.zig     every invariant as code (quiescent)
//!   dump.zig         text rendering and leaf-chain walker (quiescent)
//!   probe.zig        freeze one operation, run another: deterministic
//!   stress.zig       bounded multi-threaded workload and its check
const std = @import("std");

pub const base_node = @import("base_node.zig");
pub const base_search = @import("base_search.zig");
pub const table = @import("table.zig");
pub const dump = @import("dump.zig");
pub const probe = @import("probe.zig");
pub const stress = @import("stress.zig");
pub const ops = @import("ops.zig");
pub const prng = @import("prng.zig");

pub const NodeId = base_node.NodeId;
pub const Node = base_node.Node;
pub const Entry = base_node.Entry;
pub const NodeTable = table.NodeTable;
pub const Tree = @import("tree.zig").Tree;
pub const Protocol = @import("tree.zig").Protocol;
pub const Hook = @import("tree.zig").Hook;
pub const Error = @import("tree.zig").Error;
pub const Violation = @import("validate.zig").Violation;

/// Canonical hand example of chapters 03 to 08.
pub const canonical = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };

pub const protocols = [_]Protocol{ .global_mutex, .global_rwlock, .latch_coupling };

pub fn protocolName(p: Protocol) []const u8 {
    return switch (p) {
        .global_mutex => "global mutex",
        .global_rwlock => "global rwlock",
        .latch_coupling => "latch coupling",
    };
}

test {
    // A test block only runs if its file is referenced from here.
    _ = base_node;
    _ = base_search;
    _ = table;
    _ = ops;
    _ = prng;
    _ = @import("tests.zig");
}

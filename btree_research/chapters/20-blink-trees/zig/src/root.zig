//! Library root of chapter 20: a Lehman-Yao B-link tree.
//!
//!   base_handle.zig  NodeId                                  (from chapter 07)
//!   base_node.zig    keys + values / children of one node    (from chapter 07)
//!   base_search.zig  lowerBound / upperBound / childIndex    (from chapter 07)
//!   blink.zig        BLinkTree: node table, latches, high key, right link
//!   search.zig       Descent: one latch at a time, move right
//!   insert.zig       put: split step 1, split step 2, finishing a split
//!   validate.zig     every invariant as code
//!   dump.zig         text rendering
//!   stress.zig       bounded multi-threaded workload with per-thread arenas
//!   prng.zig, ops.zig  copied from common/
const std = @import("std");

pub const base_handle = @import("base_handle.zig");
pub const base_node = @import("base_node.zig");
pub const base_search = @import("base_search.zig");
pub const blink = @import("blink.zig");
pub const search = @import("search.zig");
pub const dump = @import("dump.zig");
pub const stress = @import("stress.zig");
pub const prng = @import("prng.zig");
pub const ops = @import("ops.zig");

pub const NodeId = blink.NodeId;
pub const BLinkTree = blink.BLinkTree;
pub const Page = blink.Page;
pub const Stats = blink.Stats;
pub const PutError = blink.PutError;
pub const Descent = search.Descent;
pub const Violation = @import("validate.zig").Violation;

test {
    // A test block only runs if its file is referenced from here.
    _ = base_node;
    _ = base_search;
    _ = prng;
    _ = ops;
    _ = stress;
    _ = @import("tests.zig");
}

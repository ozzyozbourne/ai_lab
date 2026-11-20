//! Library root of chapter 27: a B+tree and an LSM-tree on the same counted
//! block device.
//!
//!   device.zig    the counted block device: reads, writes, blocks allocated
//!   base_*.zig    the B+tree of chapter 07, instrumented (changes: "ch27:")
//!   memtable.zig  skip list in an arena: the LSM-tree's mutable part
//!   run.zig       immutable sorted run: data blocks + index blocks, builder
//!   filter.zig    Bloom filter: a run's optional membership filter, in RAM
//!   merge.zig     k-way merge with fixed buffers
//!   lsm.zig       Lsm: put, delete, get, range, flush, compaction, validate
//!   bench.zig     the same operation stream on both, counted per operation
const std = @import("std");

pub const device = @import("device.zig");
pub const memtable = @import("memtable.zig");
pub const run = @import("run.zig");
pub const filter = @import("filter.zig");
pub const merge = @import("merge.zig");
pub const lsm = @import("lsm.zig");
pub const bench = @import("bench.zig");
pub const ops = @import("ops.zig");
pub const prng = @import("prng.zig");
pub const node = @import("base_node.zig");
pub const arena = @import("base_arena.zig");
pub const search = @import("base_search.zig");

pub const Device = device.Device;
pub const Counters = device.Counters;
pub const BPlusTree = @import("base_tree.zig").BPlusTree;
pub const LeafWalker = @import("base_walk.zig").LeafWalker;
pub const Entry = node.Entry;
pub const Lsm = lsm.Lsm;
pub const Memtable = memtable.Memtable;

test {
    // A test block only runs if its file is referenced from here.
    _ = device;
    _ = memtable;
    _ = run;
    _ = filter;
    _ = merge;
    _ = lsm;
    _ = bench;
    _ = ops;
    _ = prng;
    _ = node;
    _ = arena;
    _ = search;
    _ = @import("tests.zig");
}

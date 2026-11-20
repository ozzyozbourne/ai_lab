//! Library root of chapter 23: a copy-on-write B+tree.
//!
//!   base_node.zig    Node layout and in-node surgery   (from chapter 07, no leaf links)
//!   base_search.zig  lowerBound / upperBound / childIndex   (from chapter 07)
//!   crc32.zig, ops.zig                                      (from common/)
//!   meta.zig         two-slot checksummed metapage: encode, decode, pick
//!   store.zig        PageStore: page slab, free list, meta slots
//!   read.zig         View: get, stack cursor, range
//!   db.zig           Db: committed root, snapshots (refcounted), pending frees
//!   txn.zig          WriteTxn: path copying, put, delete, commit, abort
//!   validate.zig     every invariant as code
//!   dump.zig         text rendering
const std = @import("std");

pub const base_node = @import("base_node.zig");
pub const base_search = @import("base_search.zig");
pub const crc32 = @import("crc32.zig");
pub const ops = @import("ops.zig");
pub const meta = @import("meta.zig");
pub const store = @import("store.zig");
pub const read = @import("read.zig");
pub const dump = @import("dump.zig");

pub const PageId = base_node.PageId;
pub const Node = base_node.Node;
pub const Entry = base_node.Entry;
pub const Meta = meta.Meta;
pub const PageStore = store.PageStore;
pub const View = read.View;
pub const Cursor = read.Cursor;
pub const Db = @import("db.zig").Db;
pub const Snapshot = @import("db.zig").Snapshot;
pub const Stats = @import("db.zig").Stats;
pub const WriteTxn = @import("txn.zig").WriteTxn;
pub const CommitInfo = @import("txn.zig").CommitInfo;
pub const Violation = @import("validate.zig").Violation;
pub const validate = @import("validate.zig").validate;

test {
    // A test block only runs if its file is referenced from here.
    _ = base_node;
    _ = base_search;
    _ = crc32;
    _ = ops;
    _ = meta;
    _ = @import("tests.zig");
}

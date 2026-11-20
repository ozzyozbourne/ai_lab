//! Library root of chapter 24: MVCC garbage in a B+tree index, VACUUM, and
//! the deletion and recycling of empty pages. Single-threaded model.
//!
//!   base_arena.zig   (ch. 07) NodeId handles, Arena(T): slot array + free list
//!   base_node.zig    (ch. 07, changed) page layout, (key, tid) entries, hint bits, page states
//!   base_search.zig  (ch. 07, trimmed) binary searches inside a page
//!   store.zig        row versions (xmin, xmax), transaction counter, snapshots, visibility
//!   index.zig        the B+tree: insert, garbage-before-split, two-phase page deletion, recycle
//!   db.zig           Db (put / delete / get / vacuum) and the snapshot Cursor
//!   validate.zig     every invariant as code
//!   dump.zig         text rendering
const std = @import("std");

pub const arena = @import("base_arena.zig");
pub const node = @import("base_node.zig");
pub const search = @import("base_search.zig");
pub const store = @import("store.zig");
pub const index = @import("index.zig");
pub const dump = @import("dump.zig");
pub const ops = @import("ops.zig");

pub const NodeId = arena.NodeId;
pub const Store = store.Store;
pub const Version = store.Version;
pub const Index = index.Index;
pub const Stats = index.Stats;
pub const Db = @import("db.zig").Db;
pub const Cursor = @import("db.zig").Cursor;
pub const Row = @import("db.zig").Row;
pub const VacuumReport = @import("db.zig").VacuumReport;
pub const Violation = @import("validate.zig").Violation;

test {
    // A test block only runs if its file is referenced from here.
    _ = arena;
    _ = node;
    _ = search;
    _ = store;
    _ = ops;
    _ = @import("tests.zig");
}

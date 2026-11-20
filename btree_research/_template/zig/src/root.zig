//! Library root of the template (`@import("btree_template")` from main.zig).
//!
//! `zig build test` compiles this file as a test root. Tests in *other* files
//! only run if those files are referenced from a `test` block reachable from
//! here, hence the `test { _ = @import(...); }` block at the bottom.
const std = @import("std");

pub const snippets = struct {
    pub const printing = @import("snippets/s02_printing.zig");
    pub const allocators = @import("snippets/s03_allocators.zig");
    pub const allocator_interface = @import("snippets/s04_allocator_interface.zig");
    pub const containers = @import("snippets/s05_containers.zig");
    pub const bytes = @import("snippets/s06_bytes.zig");
    pub const file_io = @import("snippets/s07_file_io.zig");
    pub const misc = @import("snippets/s08_misc.zig");
    pub const changes = @import("snippets/s09_changes.zig");
};

pub const CountingAllocator = snippets.allocator_interface.CountingAllocator;
pub const PagePool = snippets.allocator_interface.PagePool;
pub const Pager = snippets.file_io.Pager;

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test add {
    try std.testing.expectEqual(10, add(3, 7));
}

test {
    // Pull in the tests of every snippet file. `std.testing.refAllDecls(@This())`
    // only references top-level decls of this file; listing imports is explicit.
    _ = snippets.printing;
    _ = snippets.allocators;
    _ = snippets.allocator_interface;
    _ = snippets.containers;
    _ = snippets.bytes;
    _ = snippets.file_io;
    _ = snippets.misc;
    _ = snippets.changes;
}

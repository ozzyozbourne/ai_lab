//! Chapter 03: B-tree structure and search. `zig build run` prints the fixed
//! scenario (see scenario.zig); `zig build test` runs every test.
//!
//!   file               content                                   needs
//!   base_node.zig      the node type                             -
//!   base_search.zig    lowerBound, get, inOrder                  base_node
//!   base_validate.zig  the invariants as code                    base_node
//!   base_stats.zig     shape, fill, text rendering               base_node
//!   base_pool.zig      the node pool contract, DirectNodes       -
//!   bump.zig           a hand-written bump allocator             -
//!   tree.zig           HandTree: build by hand, read, tear down  all of the above
//!   trace.zig          explainGet: search with a narration       base_node, base_search
//!   height.zig         key counts and height bounds              -
//!   broken.zig         ten corrupted trees for validate          tree
//!   redblack.zig       2-3-4 tree to red-black tree              base_node
//!   scenario.zig       what `zig build run` prints               everything
//!
//! The base_* files are copies from chapter 05, which holds the complete
//! tree (with insert and delete).
const std = @import("std");
const scenario = @import("scenario.zig");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout: *std.Io.Writer = &stdout_file_writer.interface;
    // init.gpa is a leak-checking SafeAllocator in debug builds.
    try scenario.run(init.gpa, stdout);
    try stdout.flush();
}

test {
    // Tests in other files only run if the file is referenced from here.
    _ = @import("base_node.zig");
    _ = @import("base_search.zig");
    _ = @import("base_validate.zig");
    _ = @import("base_stats.zig");
    _ = @import("base_pool.zig");
    _ = @import("bump.zig");
    _ = @import("tree.zig");
    _ = @import("trace.zig");
    _ = @import("height.zig");
    _ = @import("broken.zig");
    _ = @import("redblack.zig");
    _ = @import("scenario.zig");
    _ = @import("prng.zig");
}

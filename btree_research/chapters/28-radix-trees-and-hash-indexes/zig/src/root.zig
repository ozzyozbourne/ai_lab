//! Chapter 28: radix trees and hash indexes.
//!
//! Library root. `zig build test` uses this file as the test root, so every
//! file with tests is referenced from the `test` block at the bottom.
pub const keys = @import("keys.zig");
pub const art = @import("art.zig");
pub const hash_index = @import("hash_index.zig");
pub const sorted_index = @import("sorted_index.zig");
pub const scenario = @import("scenario.zig");

pub const Art = art.Art;
pub const HashIndex = hash_index.HashIndex;
pub const SortedIndex = sorted_index.SortedIndex;

test {
    _ = keys;
    _ = art;
    _ = hash_index;
    _ = sorted_index;
    _ = scenario;
    _ = @import("prng.zig");
    _ = @import("ops.zig");
}

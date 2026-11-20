// Copied from chapters/07-bplus-trees/zig/src/arena.zig; trimmed to the handle
// type. The growable Arena(T) with its free list is NOT copied: this chapter
// preallocates a fixed node table and never frees a node (see blink.zig).
const std = @import("std");
const assert = std.debug.assert;

/// Handle of a node: an index into the node table. `.nil` plays the role of a
/// null pointer (or of "page 0 = no page" in an on-disk format).
///
/// A non-exhaustive enum instead of a bare `u32` so that the compiler refuses
/// to mix handles up with key counts and array indices.
pub const NodeId = enum(u32) {
    nil = std.math.maxInt(u32),
    _,

    /// Position in the node table. Never call on `.nil`.
    pub fn index(self: NodeId) usize {
        assert(self != .nil);
        return @backingInt(self);
    }

    pub fn fromIndex(i: usize) NodeId {
        assert(i < std.math.maxInt(u32)); // maxInt itself is reserved for nil
        return @fromBackingInt(@intCast(@as(u32, @intCast(i))));
    }
};

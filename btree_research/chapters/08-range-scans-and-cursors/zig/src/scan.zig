//! `Scan`: a range scan = one seek + steps + a stop test.
//!
//!   forward:  seek to the LOWER bound, step `next`, stop at the first key
//!             outside the UPPER bound;
//!   backward: seek to the UPPER bound, step `prev`, stop at the first key
//!             outside the LOWER bound.
//!
//! Only the far bound is tested per entry. The near bound is satisfied by
//! the seek and stays satisfied, because keys only move away from it.
//!
//! `Scan` is generic over the cursor, so the same code runs on the link
//! cursor and on the stack cursor. Because cursors re-seek by key, a scan
//! keeps working when entries are inserted or deleted between two `next`
//! calls. What it returns then: every entry that was in the range for the
//! whole scan exactly once, in order; an entry inserted during the scan is
//! returned if and only if the scan had not passed its key yet; an entry
//! deleted during the scan is not returned unless the scan had passed it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Tree = @import("tree.zig").Tree;
const Entry = @import("base_node.zig").Entry;
const bounds = @import("bounds.zig");
const Bound = bounds.Bound;
const Direction = bounds.Direction;
const Seek = @import("cursor.zig").Seek;

/// Which seek puts a cursor on the first entry of the scan.
pub fn startSeek(lo: Bound, hi: Bound, direction: Direction) Seek {
    return switch (direction) {
        .forward => switch (lo) {
            .unbounded => .first,
            .included => |k| .{ .ge = k },
            .excluded => |k| .{ .gt = k },
        },
        .backward => switch (hi) {
            .unbounded => .last,
            .included => |k| .{ .le = k },
            .excluded => |k| .{ .lt = k },
        },
    };
}

pub fn Scan(comptime C: type) type {
    return struct {
        const Self = @This();

        tree: *const Tree,
        cursor: C,
        lo: Bound,
        hi: Bound,
        direction: Direction,
        phase: enum { start, running, done } = .start,

        pub fn init(tree: *const Tree, cursor: C, lo: Bound, hi: Bound, direction: Direction) Self {
            return .{ .tree = tree, .cursor = cursor, .lo = lo, .hi = hi, .direction = direction };
        }

        pub fn next(self: *Self) ?Entry {
            const candidate = switch (self.phase) {
                .done => return null,
                .start => self.cursor.seek(self.tree, startSeek(self.lo, self.hi, self.direction)),
                .running => switch (self.direction) {
                    .forward => self.cursor.next(self.tree),
                    .backward => self.cursor.prev(self.tree),
                },
            };
            self.phase = .running;
            if (candidate) |found| {
                const inside = switch (self.direction) {
                    .forward => bounds.belowUpper(self.hi, found.key),
                    .backward => bounds.aboveLower(self.lo, found.key),
                };
                if (inside) return found;
            }
            // Past the far bound or off the end of the tree. An empty or
            // inverted range needs no special case: its first candidate
            // already fails the test.
            self.phase = .done;
            return null;
        }

        /// Runs the scan to its end and returns the entries as one slice
        /// allocated from `gpa` (usually a per-scan arena). The only
        /// function of the scan machinery that can run out of memory.
        pub fn collect(self: *Self, gpa: Allocator) Allocator.Error![]Entry {
            var list: std.ArrayList(Entry) = .empty;
            errdefer list.deinit(gpa);
            while (self.next()) |found| try list.append(gpa, found);
            return list.toOwnedSlice(gpa);
        }
    };
}

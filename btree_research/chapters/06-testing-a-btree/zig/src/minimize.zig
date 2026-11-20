//! Minimisation: turn "seed 7 fails at step 131" into a handful of steps a
//! person can follow by hand.
//!
//! The method is delta debugging by chunk removal:
//!
//!   1. cut everything after the failing step (it never ran);
//!   2. try to delete a chunk of steps; if the shorter sequence STILL FAILS
//!      IN THE SAME WAY, keep it, otherwise put the chunk back;
//!   3. start with chunks of half the sequence, halve the chunk size after
//!      each pass, and at chunk size 1 repeat until a whole pass removes
//!      nothing. The result is 1-minimal: no single step can be removed.
//!
//! Then three cosmetic passes make the survivor readable: forget injected
//! faults, rename the keys 1, 2, 3, ... (keeping their order), and replace
//! the random 64-bit values with 1, 2, 3, ... Each pass is kept only if the
//! sequence still fails in the same way.
//!
//! "The same way" matters. Deleting steps from a sequence that breaks
//! invariant A can produce a sequence that breaks B for an unrelated reason;
//! accepting it would silently swap the bug being chased (`Failure.sameKind`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const fuzz = @import("fuzz.zig");
const Step = fuzz.Step;
const Failure = fuzz.Failure;

pub const Minimized = struct {
    /// The reproducer; its last step is the failing one. Caller frees.
    steps: []Step,
    failure: Failure,
    /// How many times the tree was rebuilt and replayed to get here.
    replays: usize,
};

pub fn minimize(comptime Tree: type, gpa: Allocator, original: []const Step, target: Failure, checks: fuzz.Checks) Allocator.Error!Minimized {
    var m: Minimizer(Tree) = .{ .gpa = gpa, .target = target, .checks = checks, .failure = target };
    defer m.candidate.deinit(gpa);
    errdefer m.current.deinit(gpa);
    try m.current.appendSlice(gpa, original[0 .. target.step + 1]);

    var chunk = @max(m.current.items.len / 2, 1);
    while (true) {
        var removed_any = false;
        var i: usize = 0;
        while (i < m.current.items.len) {
            const end = @min(i + chunk, m.current.items.len);
            m.candidate.clearRetainingCapacity();
            try m.candidate.appendSlice(gpa, m.current.items[0..i]);
            try m.candidate.appendSlice(gpa, m.current.items[end..]);
            if (try m.acceptIfStillFailing()) {
                removed_any = true; // do not advance: the next chunk slid to position i
            } else {
                i = end;
            }
        }
        if (chunk > 1) {
            chunk /= 2;
        } else if (!removed_any) {
            break;
        }
    }

    try m.withoutFaults();
    try m.renumberKeys();
    try m.smallValues();
    return .{ .steps = try m.current.toOwnedSlice(gpa), .failure = m.failure, .replays = m.replays };
}

fn Minimizer(comptime Tree: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        target: Failure,
        checks: fuzz.Checks,
        /// The shortest failing sequence so far, and how it fails.
        current: std.ArrayList(Step) = .empty,
        failure: Failure,
        /// Scratch: the sequence being tried.
        candidate: std.ArrayList(Step) = .empty,
        replays: usize = 0,

        /// Replay `candidate`. If it fails like the target, it becomes
        /// `current` (cut after its failing step) and the result is true.
        fn acceptIfStillFailing(self: *Self) Allocator.Error!bool {
            self.replays += 1;
            const failure = try fuzz.replay(Tree, self.gpa, self.candidate.items, self.checks, null) orelse return false;
            if (!failure.sameKind(self.target)) return false;
            self.candidate.shrinkRetainingCapacity(failure.step + 1);
            std.mem.swap(std.ArrayList(Step), &self.current, &self.candidate);
            self.failure = failure;
            return true;
        }

        fn copyToCandidate(self: *Self) Allocator.Error!void {
            self.candidate.clearRetainingCapacity();
            try self.candidate.appendSlice(self.gpa, self.current.items);
        }

        fn withoutFaults(self: *Self) Allocator.Error!void {
            try self.copyToCandidate();
            for (self.candidate.items) |*step| step.fault = null;
            _ = try self.acceptIfStillFailing();
        }

        /// A B-tree only ever compares keys, so any order-preserving renaming
        /// is the same test. Rank 1 goes to the smallest number mentioned.
        fn renumberKeys(self: *Self) Allocator.Error!void {
            var seen: std.ArrayList(u64) = .empty;
            defer seen.deinit(self.gpa);
            for (self.current.items) |step| switch (step.op) {
                .put => |p| try seen.append(self.gpa, p.key),
                .delete => |d| try seen.append(self.gpa, d.key),
                .get => |g| try seen.append(self.gpa, g.key),
                .range => |r| try seen.appendSlice(self.gpa, &.{ r.lo, r.hi }),
            };
            std.mem.sort(u64, seen.items, {}, std.sort.asc(u64));
            try self.copyToCandidate();
            for (self.candidate.items) |*step| switch (step.op) {
                .put => |*p| p.key = rank(seen.items, p.key),
                .delete => |*d| d.key = rank(seen.items, d.key),
                .get => |*g| g.key = rank(seen.items, g.key),
                .range => |*r| {
                    r.lo = rank(seen.items, r.lo);
                    r.hi = rank(seen.items, r.hi);
                },
            };
            _ = try self.acceptIfStillFailing();
        }

        /// The n-th put writes the value n.
        fn smallValues(self: *Self) Allocator.Error!void {
            try self.copyToCandidate();
            var n: u64 = 0;
            for (self.candidate.items) |*step| switch (step.op) {
                .put => |*p| {
                    n += 1;
                    p.value = n;
                },
                else => {},
            };
            _ = try self.acceptIfStillFailing();
        }
    };
}

/// 1 + the number of DISTINCT values in `sorted` that are smaller than `x`.
fn rank(sorted: []const u64, x: u64) u64 {
    var distinct: u64 = 0;
    for (sorted, 0..) |value, i| {
        if (value >= x) break;
        if (i == 0 or sorted[i - 1] != value) distinct += 1;
    }
    return distinct + 1;
}

test "rank renumbers in order and ignores repeats" {
    const sorted = [_]u64{ 5, 5, 9, 40, 40, 41 };
    try std.testing.expectEqual(1, rank(&sorted, 5));
    try std.testing.expectEqual(2, rank(&sorted, 9));
    try std.testing.expectEqual(3, rank(&sorted, 40));
    try std.testing.expectEqual(4, rank(&sorted, 41));
}

//! Minimisation: turn "seed 7 fails at step 131" into a handful of steps a
//! person can follow by hand.
//!
//! The method is delta debugging by chunk removal:
//!
//!   1. cut everything after the failing step (it never ran);
//!   2. try to delete a chunk of steps; if the shorter sequence STILL FAILS
//!      IN THE SAME WAY, keep it, otherwise put the chunk back;
//!   3. start with chunks of half the sequence and halve the chunk size
//!      after each pass, down to single steps. This is the fast part: it
//!      throws away most of a long run in few replays;
//!   4. finish exhaustively: try to remove EVERY contiguous block of steps
//!      (every start, every length, longest first), and start over whenever
//!      one goes. Chunk sizes that only shrink would miss a pair of steps
//!      that can only go together (a put and the delete that undoes it),
//!      because by the time single steps are stable no larger chunk is tried
//!      again.
//!
//! The guarantee, exactly: in the result no contiguous block of steps, of
//! any length, can be removed without losing the failure. In particular no
//! single step can (1-minimal). It is NOT the shortest failing sequence:
//! removing two steps that are not next to each other is never tried (that
//! search is exponential), and a shorter reproducer may not be a
//! subsequence of this run at all.
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

    // Fast reduction: aligned chunks, halving.
    var chunk = @max(m.current.items.len / 2, 1);
    while (true) : (chunk /= 2) {
        var i: usize = 0;
        while (i < m.current.items.len) {
            // On success do not advance: the next chunk slid to position i.
            if (!try m.tryWithout(i, i + chunk)) i += chunk;
        }
        if (chunk == 1) break;
    }
    // Exhaustive finish: every contiguous block, longest first, until a
    // whole round removes nothing. Each success shortens the sequence, so
    // this ends; a round costs about n^2 / 2 replays for n steps, which is
    // why the fast reduction comes first.
    restart: while (true) {
        const n = m.current.items.len;
        var len = n -| 1; // removing all n steps leaves nothing to fail
        while (len >= 1) : (len -= 1) {
            for (0..n - len + 1) |start| {
                if (try m.tryWithout(start, start + len)) continue :restart;
            }
        }
        break;
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

        /// Try the current sequence without steps [start, end).
        fn tryWithout(self: *Self, start: usize, end_: usize) Allocator.Error!bool {
            const end = @min(end_, self.current.items.len);
            self.candidate.clearRetainingCapacity();
            try self.candidate.appendSlice(self.gpa, self.current.items[0..start]);
            try self.candidate.appendSlice(self.gpa, self.current.items[end..]);
            return self.acceptIfStillFailing();
        }

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

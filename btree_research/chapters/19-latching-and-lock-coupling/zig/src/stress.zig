//! Bounded stress test: a few threads hammer one tree, then the result is
//! checked while nothing is running.
//!
//! Everything a worker does is decided by its seed alone, never by what the
//! other threads did. So although the interleaving (and with it the shape of
//! the tree) differs from run to run, the SET of keys that ends up in the
//! tree is the same every time, and so is everything `check` reports.
//!
//! Bounded by operation count, not by a clock: no sleeps, no timing asserts.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const tree_ = @import("tree.zig");
const Tree = tree_.Tree;
const SplitMix64 = @import("prng.zig").SplitMix64;
const Oracle = @import("ops.zig").Oracle;
const Walker = @import("dump.zig").Walker;
const valueOf = @import("probe.zig").valueOf;

pub const max_threads = 4;

pub const Config = struct {
    threads: u32,
    ops_per_thread: u32,
    seed: u64,
    /// Each worker draws from this many keys.
    key_space: u64,
    /// false: worker t only uses keys with key % threads == t, so no two
    /// workers ever touch the same key (they still share leaves and split
    /// each other's nodes). true: all workers draw from the same keys.
    overlapping: bool,

    /// A node table that cannot run out for this workload: at most one leaf
    /// per key (M = 4 allows leaves with a single key) and fewer internal
    /// nodes than leaves.
    pub fn nodeCapacity(self: Config) u32 {
        const keys = if (self.overlapping) self.key_space else self.key_space * self.threads;
        return @intCast(2 * keys + 16);
    }
};

pub const Worker = struct {
    tree: *Tree,
    io: Io,
    /// Shared by all workers, so it must be thread-safe.
    arena: Allocator,
    config: Config,
    index: u32,
    /// Every key this worker has put, in order. Grows from the shared arena.
    log: std.ArrayList(u64) = .empty,
    /// Puts that returned null: "the key was not there before".
    fresh: usize = 0,
    /// Gets of a key this worker had already put that did NOT return its
    /// value. Must stay 0: an insert that has returned is visible.
    lost: usize = 0,
    /// Operations that failed (table or arena exhausted). Must stay 0.
    failed: usize = 0,

    pub fn run(self: *Worker) void {
        const c = self.config;
        var rng = SplitMix64.init(c.seed +% self.index);
        for (0..c.ops_per_thread) |_| {
            if (self.log.items.len > 0 and rng.below(4) == 0) {
                const key = self.log.items[@intCast(rng.below(self.log.items.len))];
                if (self.tree.get(self.io, key) != valueOf(key)) self.lost += 1;
            } else {
                const k = rng.below(c.key_space);
                const key = if (c.overlapping) k else k * c.threads + self.index;
                const old = self.tree.put(self.io, key, valueOf(key)) catch {
                    self.failed += 1;
                    continue;
                };
                if (old == null) self.fresh += 1;
                self.log.append(self.arena, key) catch {
                    self.failed += 1;
                };
            }
        }
    }
};

pub const Report = struct {
    /// Entries in the tree at the end.
    keys: usize,
    /// Distinct keys in the workers' logs (the oracle's size).
    expected_keys: usize,
    /// Sum of the workers' `fresh` counters. Equal to `expected_keys` exactly
    /// when every key was inserted once: no insert lost, none done twice.
    fresh: usize,
    lost: usize,
    failed: usize,
    /// Positions where the leaf chain and the oracle disagree.
    mismatches: usize,
    valid: bool,

    pub fn ok(self: Report) bool {
        return self.valid and self.mismatches == 0 and self.lost == 0 and self.failed == 0 and
            self.keys == self.expected_keys and self.fresh == self.expected_keys;
    }
};

/// Runs the workers to completion and checks the quiescent tree.
/// `arena` must be thread-safe; `gpa` is used by this thread only.
pub fn run(tree: *Tree, io: Io, gpa: Allocator, arena: Allocator, config: Config) !Report {
    std.debug.assert(config.threads >= 1 and config.threads <= max_threads);
    var workers: [max_threads]Worker = undefined;
    var threads: [max_threads]std.Thread = undefined;
    var spawned: usize = 0;
    // Join whatever was started, also when a later spawn fails.
    errdefer for (threads[0..spawned]) |t| t.join();
    for (workers[0..config.threads], 0..) |*w, i| {
        w.* = .{ .tree = tree, .io = io, .arena = arena, .config = config, .index = @intCast(i) };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
        spawned += 1;
    }
    for (threads[0..spawned]) |t| t.join();
    spawned = 0;
    return check(tree, gpa, workers[0..config.threads]);
}

/// Replays the workers' logs into the oracle, one after the other, and
/// compares. The order of the replay does not matter because a key always
/// gets the same value.
pub fn check(tree: *const Tree, gpa: Allocator, workers: []const Worker) Allocator.Error!Report {
    var oracle: Oracle = .{};
    defer oracle.deinit(gpa);
    var report: Report = .{ .keys = tree.len(), .expected_keys = 0, .fresh = 0, .lost = 0, .failed = 0, .mismatches = 0, .valid = true };
    for (workers) |*w| {
        for (w.log.items) |key| _ = try oracle.put(gpa, key, valueOf(key));
        report.fresh += w.fresh;
        report.lost += w.lost;
        report.failed += w.failed;
    }
    report.expected_keys = oracle.len();
    tree.validate() catch {
        report.valid = false;
    };
    var walker = Walker.init(tree);
    for (oracle.range(0, std.math.maxInt(u64))) |expected| {
        const got = walker.next();
        if (got == null or got.?.key != expected.key or got.?.value != expected.value) report.mismatches += 1;
    }
    if (walker.next() != null) report.mismatches += 1;
    return report;
}

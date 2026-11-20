//! A bounded multi-threaded workload, used by the tests and by the demo
//! program. Nothing here is timed and nothing printed depends on how the
//! threads interleave: the report contains only facts that must hold for
//! EVERY interleaving (no key lost, final content equals the oracle).
//!
//! Each worker thread
//!   * inserts `puts_per_thread` keys drawn from its own seeded SplitMix64;
//!   * after every put reads back that key, a key it inserted earlier, and a
//!     key that was in the tree before the threads started. All three must be
//!     found, whatever the other threads are splitting at that moment. This
//!     is the B-link promise: a key, once inserted, is never unreachable.
//!
//! Values are a function of the key, so when two threads put the same key
//! the outcome does not depend on who wins.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const BLinkTree = @import("blink.zig").BLinkTree;
const SplitMix64 = @import("prng.zig").SplitMix64;
const Oracle = @import("ops.zig").Oracle;

pub const max_threads = 4;

pub const Config = struct {
    order: usize = 4,
    threads: usize = max_threads,
    puts_per_thread: usize,
    /// Keys are drawn from [0, key_space).
    key_space: u64,
    /// Keys inserted before the threads start.
    preload: usize,
    seed: u64,
    /// Size of the node table.
    capacity: usize,
    /// Run with the test hook on: every split stops after step 1 and is
    /// finished by whichever writer meets the flag next.
    abandon_splits: bool = false,
};

pub const Report = struct {
    /// Entries in the tree at the end / in the oracle.
    keys: u64 = 0,
    expected_keys: u64 = 0,
    /// Reads during the run that missed a key known to be present.
    lost: u64 = 0,
    /// Puts that failed (node table full).
    failed_puts: u64 = 0,
    /// Differences between the final tree and the oracle.
    mismatches: u64 = 0,
    valid: bool = false,
    /// Flags still set at the end (always 0 unless `abandon_splits`).
    incomplete_splits: usize = 0,
};

pub fn valueOf(key: u64) u64 {
    return key * 10 + 7;
}

const Worker = struct {
    tree: *BLinkTree,
    io: Io,
    seed: u64,
    puts: usize,
    key_space: u64,
    preloaded: []const u64,
    /// Scratch memory of THIS thread: its key log and its list of misses.
    /// One arena per thread, so that the hot loop of one thread never
    /// touches allocator state another thread is using, and so that all of
    /// a thread's memory is released with one call after the join.
    arena: std.heap.ArenaAllocator,
    /// Every key this thread tried to insert, in order (lives in `arena`).
    keys: []u64 = &.{},
    /// Keys a read failed to find (lives in `arena`). Must stay empty.
    missed: std.ArrayList(u64) = .empty,
    failed_puts: u64 = 0,
    out_of_memory: bool = false,

    fn run(self: *Worker) void {
        self.work() catch {
            self.out_of_memory = true;
        };
    }

    fn work(self: *Worker) Allocator.Error!void {
        const scratch = self.arena.allocator();
        var rng = SplitMix64.init(self.seed);
        const keys = try scratch.alloc(u64, self.puts);
        for (keys, 0..) |*slot, i| {
            const key = rng.below(self.key_space);
            slot.* = key;
            self.keys = keys[0 .. i + 1];
            _ = self.tree.put(self.io, key, valueOf(key)) catch {
                self.failed_puts += 1;
                continue;
            };
            try self.expectPresent(scratch, key);
            try self.expectPresent(scratch, keys[rng.below(i + 1)]);
            if (self.preloaded.len > 0) {
                try self.expectPresent(scratch, self.preloaded[rng.below(self.preloaded.len)]);
            }
        }
    }

    fn expectPresent(self: *Worker, scratch: Allocator, key: u64) Allocator.Error!void {
        if (self.tree.get(self.io, key) != valueOf(key)) try self.missed.append(scratch, key);
    }
};

/// Runs the workload and compares the result with a single-threaded oracle.
/// `gpa` must be thread-safe (std.testing.allocator and init.gpa are).
pub fn run(gpa: Allocator, io: Io, config: Config) !Report {
    std.debug.assert(config.threads >= 1 and config.threads <= max_threads);
    var tree = try BLinkTree.init(gpa, config.order, config.capacity);
    defer tree.deinit(gpa);
    var oracle: Oracle = .{};
    defer oracle.deinit(gpa);
    var report: Report = .{};

    // Preload, single-threaded.
    const preloaded = try gpa.alloc(u64, config.preload);
    defer gpa.free(preloaded);
    var rng = SplitMix64.init(config.seed);
    for (preloaded) |*slot| {
        const key = rng.below(config.key_space);
        slot.* = key;
        _ = tree.put(io, key, valueOf(key)) catch {
            report.failed_puts += 1;
            continue;
        };
        _ = try oracle.put(gpa, key, valueOf(key));
    }

    tree.setAbandonSplits(config.abandon_splits);

    var workers: [max_threads]Worker = undefined;
    var threads: [max_threads]std.Thread = undefined;
    for (workers[0..config.threads], 0..) |*w, t| w.* = .{
        .tree = &tree,
        .io = io,
        .seed = config.seed +% (t + 1) *% 0x9E3779B97F4A7C15,
        .puts = config.puts_per_thread,
        .key_space = config.key_space,
        .preloaded = preloaded,
        .arena = .init(gpa),
    };
    defer for (workers[0..config.threads]) |*w| w.arena.deinit();

    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (workers[0..config.threads], 0..) |*w, t| {
        threads[t] = try std.Thread.spawn(.{}, Worker.run, .{w});
        started += 1;
    }
    for (threads[0..started]) |thread| thread.join();
    started = 0; // joined: the deferred join has nothing left to do

    // From here on this thread is alone again. The arenas are still alive:
    // the key logs in them are the input of the oracle.
    tree.setAbandonSplits(false);
    for (workers[0..config.threads]) |*w| {
        if (w.out_of_memory) return error.OutOfMemory;
        report.lost += w.missed.items.len;
        report.failed_puts += w.failed_puts;
        for (w.keys) |key| _ = try oracle.put(gpa, key, valueOf(key));
    }

    report.keys = tree.len();
    report.expected_keys = oracle.len();
    if (report.keys != report.expected_keys) report.mismatches += 1;
    for (oracle.entries.items) |e| {
        if (tree.get(io, e.key) != e.value) report.mismatches += 1;
    }
    // The other direction: walking the leaf level by right links must give
    // exactly the oracle's entries, in order.
    report.mismatches += leafChainMismatches(&tree, &oracle);
    report.valid = if (tree.validate()) |_| true else |_| false;
    report.incomplete_splits = tree.incompleteSplits();
    return report;
}

fn leafChainMismatches(tree: *const BLinkTree, oracle: *const Oracle) u64 {
    const expected = oracle.entries.items;
    var mismatches: u64 = 0;
    var n: usize = 0;
    var id = tree.level_head[0];
    while (id != .nil) : (id = tree.page(id).right) {
        const p = tree.page(id);
        for (p.node.keySlice(), p.node.kind.leaf.values[0..p.node.len]) |key, value| {
            if (n >= expected.len or expected[n].key != key or expected[n].value != value) mismatches += 1;
            n += 1;
        }
    }
    if (n != expected.len) mismatches += 1;
    return mismatches;
}

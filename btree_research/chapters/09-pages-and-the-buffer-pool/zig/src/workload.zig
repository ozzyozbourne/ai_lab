//! workload.zig: a seeded random page-access workload with an oracle.
//!
//! Used twice: by the model test below (several pool sizes, storage compared
//! with the oracle afterwards) and by part 3 of the demo (counters printed).
//! The Rust twin draws the same random numbers, so both languages perform the
//! same operations and print the same counters.
const std = @import("std");
const testing = std.testing;
const storage_mod = @import("storage.zig");
const MemStorage = storage_mod.MemStorage;
const pager_mod = @import("pager.zig");
const Pager = pager_mod.Pager;
const PageId = pager_mod.PageId;
const page_size = pager_mod.page_size;
const BufferPool = @import("buffer_pool.zig").BufferPool;
const SplitMix64 = @import("prng.zig").SplitMix64;

pub const page_count = 64;
pub const ops = 5000;

/// Run `ops` random page accesses against `pool` and check every page
/// read against `expected`. 80% of accesses go to 8 hot pages; one access
/// in four modifies the page. Up to two pages are kept pinned across
/// operations to exercise the "skip pinned frames" path.
///
/// On an error (a failed fetch, wrong content, a broken invariant) every pin
/// taken here is released before returning, so the caller's
/// `defer pool.deinit()` sees no pin and the error reaches the caller.
pub fn run(pool: *BufferPool, seed: u64, expected: *[page_count]u64) !void {
    const Held = struct { id: PageId, dirty: bool };
    var rng = SplitMix64.init(seed);
    var held: [2]Held = undefined;
    var held_len: usize = 0;
    // Always leave at least one frame unpinned, or fetches would fail.
    const max_held = @min(held.len, pool.frameCount() - 1);
    // Error path only: give back the long-lived pins. (`held_len` is read
    // when the errdefer runs, not here.)
    errdefer for (held[0..held_len]) |h| pool.unpin(h.id, h.dirty);

    for (0..ops) |_| {
        const id: PageId = @intCast(if (rng.chance(4, 5)) rng.below(8) else rng.below(page_count));
        const write = rng.chance(1, 4);
        const hold = rng.chance(1, 16);

        if (held_len > 0 and held_len == max_held) {
            // Release the oldest long-lived pin to make room for a new one.
            pool.unpin(held[0].id, held[0].dirty);
            std.mem.copyForwards(Held, held[0 .. held_len - 1], held[1..held_len]);
            held_len -= 1;
        }

        const page = try pool.fetchPage(id);
        const counter = page[8..16];
        {
            // Between the fetch and the unpin (or the hand-over to `held`)
            // this pin is ours to release if something fails.
            errdefer pool.unpin(id, false);
            if (std.mem.readInt(u64, counter, .little) != expected[id]) return error.WrongPageContent;
        }
        if (write) {
            expected[id] += 1;
            std.mem.writeInt(u64, counter, expected[id], .little);
        }
        if (hold and held_len < max_held) {
            held[held_len] = .{ .id = id, .dirty = write };
            held_len += 1;
        } else {
            pool.unpin(id, write);
        }
        try pool.validate();
    }
    for (held[0..held_len]) |h| pool.unpin(h.id, h.dirty);
}

test "workload: seeded model test against an oracle, several pool sizes" {
    for ([_]u32{ 1, 2, 4, 8, 16, 64, 100 }) |frame_count| {
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        var pager: Pager = try .init(mem.storage());
        for (0..page_count) |_| _ = try pager.allocatePage();
        pager.stats = .{};
        var pool: BufferPool = try .init(testing.allocator, &pager, frame_count);
        defer pool.deinit();

        var expected: [page_count]u64 = @splat(0);
        try run(&pool, 0xB7EE + frame_count, &expected);
        try testing.expectEqual(ops, pool.stats.hits + pool.stats.misses);
        try testing.expectEqual(pool.stats.misses, pager.stats.reads);
        // A page is only ever evicted to load another one.
        try testing.expect(pool.stats.evictions <= pool.stats.misses);
        if (frame_count >= page_count) try testing.expectEqual(0, pool.stats.evictions);

        // After a flush the storage itself must agree with the oracle.
        try pool.flushAll();
        for (expected, 0..) |want, id| {
            const got = std.mem.readInt(u64, mem.bytes.items[id * page_size + 8 ..][0..8], .little);
            try testing.expectEqual(want, got);
        }
    }
}

/// Run the workload on a 4-frame pool with one injected fault and check that
/// the error comes back with no pin left and the pool still valid.
fn runWithFault(comptime fault: enum { write, read, content }, after: u64, want: anyerror) !void {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager: Pager = try .init(mem.storage());
    for (0..page_count) |_| _ = try pager.allocatePage();
    var pool: BufferPool = try .init(testing.allocator, &pager, 4);
    // Before the fix this deinit aborted the test: `run` returned its error
    // with pins held and the assert in deinit fired instead.
    defer pool.deinit();

    var expected: [page_count]u64 = @splat(0);
    switch (fault) {
        .write => mem.writes_before_failure = after,
        .read => mem.reads_before_failure = after,
        // Page 0 is hot, so it is read early: make the oracle disagree.
        .content => expected[0] = 99,
    }
    try testing.expectError(want, run(&pool, 2024, &expected));
    try testing.expectEqual(0, pool.pinnedFrames());
    try pool.validate();
}

test "workload: an error while pins are held is returned, and the pins are released" {
    // 200 write-backs / 300 reads into the run, long-lived pins are held.
    try runWithFault(.write, 200, error.StorageFailure);
    try runWithFault(.read, 300, error.StorageFailure);
    try runWithFault(.content, 0, error.WrongPageContent);
    // Every failure point in the first part of the run, both kinds.
    for (0..150) |n| {
        try runWithFault(.write, n, error.StorageFailure);
        try runWithFault(.read, n, error.StorageFailure);
    }
}

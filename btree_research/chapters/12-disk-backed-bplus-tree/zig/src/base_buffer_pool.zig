// Copied from chapters/09-pages-and-the-buffer-pool/zig/src/buffer_pool.zig; behaviour unchanged (only the
// @import paths were renamed to the base_* files of this chapter).
//! buffer_pool.zig: a fixed number of in-memory page frames in front of a Pager.
//!
//! The tree code never reads the file itself. It asks the pool for a page id
//! and receives a pointer to a 4096-byte frame that holds that page:
//!
//!     const page = try pool.fetchPage(id);   // pins the page
//!     ... read or modify page ...
//!     pool.unpin(id, modified);              // dirty = true if you wrote to it
//!
//! Three per-frame facts drive everything:
//!   pin_count   how many callers are using the frame right now. A pinned
//!               frame is never evicted, so the pointer stays valid.
//!   dirty       the frame differs from the file. It must be written back
//!               before the frame is reused for another page.
//!   referenced  "used since the clock hand last passed". This is the whole
//!               memory of the CLOCK eviction policy: one bit per frame.
//!
//! Invariants (checked by `validate`):
//!   I1  every non-empty frame's page id is in the page table and maps back
//!       to that frame; the table has no other entries (no page is cached twice)
//!   I2  an empty frame has pin_count 0 and is neither dirty nor referenced
//!   I3  hand < frame count
//!   I4  every cached page id is < pager.pageCount()
//!
//! Errors and pins. A call that returns an error leaves the pool valid and
//! takes no pin: after a failed `fetchPage` or `newPage` there is nothing to
//! unpin. Pins that the CALLER already holds are the caller's to release, on
//! the error path too, because `deinit` asserts that none is left:
//!
//!     const page = try pool.fetchPage(id);
//!     errdefer pool.unpin(id, false);        // runs only if a later `try` fails
//!     try somethingThatCanFail(page);
//!     pool.unpin(id, true);
//!
//! (`defer pool.unpin(id, false)` covers both paths when the page is only
//! read.) Without this, an I/O error deep in a tree operation would surface as
//! an assertion failure in `deinit` instead of as the error.
//!
//! A storage error is not retried. In particular a dirty victim whose
//! write-back fails stays where it is with the hand on it, so every later
//! miss that needs to evict tries the same write again and fails the same
//! way until the storage recovers: the pool stops rather than skip a page it
//! could not save.
//!
//! Memory: `init` makes exactly three allocations (the frame slab, the frame
//! table, the page table at full capacity). Nothing allocates after that, so
//! fetch / unpin / flush cannot fail with OutOfMemory.
//!
//! Not thread-safe: one thread, no latches (latching starts in chapter 19).
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const storage_mod = @import("base_storage.zig");
const pager_mod = @import("base_pager.zig");
const Pager = pager_mod.Pager;
const Page = pager_mod.Page;
const PageId = pager_mod.PageId;
const page_size = pager_mod.page_size;
const invalid_page_id = pager_mod.invalid_page_id;

/// page id -> frame index for the cached pages: a small hand-written hash
/// table with open addressing and linear probing.
///
/// Why not `std.AutoHashMapUnmanaged`: the pool removes and inserts one entry
/// per eviction, forever, at a fixed capacity. std's map deletes by leaving a
/// tombstone and only clears tombstones when it grows. This table never
/// grows, so after enough evictions no slot would be free any more and every
/// lookup of an uncached page (every miss) would probe the whole table.
///
/// Deletion here is "backward shift": the entries that follow the removed one
/// in its probe run move up to close the gap. There are no tombstones, so a
/// probe run always ends at a truly empty slot, and with at most half the
/// slots in use the runs stay short however long the pool lives.
const PageTable = struct {
    /// Length is a power of two and at least 2 * frame_count.
    slots: []Slot,
    len: u32 = 0,
    /// 32 - log2(slots.len): the hash keeps the top bits of a product.
    shift: u5,

    const Slot = struct {
        page_id: PageId = invalid_page_id, // invalid_page_id = slot is empty
        frame: u32 = 0,
    };

    fn init(allocator: Allocator, frame_count: u32) Allocator.Error!PageTable {
        const capacity = std.math.ceilPowerOfTwo(u32, @max(2, frame_count *| 2)) catch return error.OutOfMemory;
        const slots = try allocator.alloc(Slot, capacity);
        @memset(slots, .{});
        return .{ .slots = slots, .shift = @intCast(@as(u32, 32) - std.math.log2_int(u32, capacity)) };
    }

    fn deinit(self: *PageTable, allocator: Allocator) void {
        allocator.free(self.slots);
        self.* = undefined;
    }

    /// The slot where the probe run of `id` starts. Fibonacci hashing:
    /// multiply by 2^32 / golden ratio and keep the top bits, which spreads
    /// consecutive page ids (the common case) evenly over the table.
    fn home(self: *const PageTable, id: PageId) u32 {
        return (id *% 0x9E3779B9) >> self.shift;
    }

    fn mask(self: *const PageTable) u32 {
        return @intCast(self.slots.len - 1);
    }

    fn get(self: *const PageTable, id: PageId) ?u32 {
        var i = self.home(id);
        while (true) : (i = (i + 1) & self.mask()) {
            const slot = self.slots[i];
            if (slot.page_id == id) return slot.frame;
            if (slot.page_id == invalid_page_id) return null; // end of the run
        }
    }

    /// Insert a page that is not in the table. Cannot fail: the pool holds at
    /// most frame_count pages, and the table has twice as many slots.
    fn put(self: *PageTable, id: PageId, frame: u32) void {
        assert(id != invalid_page_id);
        assert(self.len < self.slots.len / 2);
        var i = self.home(id);
        while (self.slots[i].page_id != invalid_page_id) : (i = (i + 1) & self.mask()) {
            assert(self.slots[i].page_id != id); // no page is cached twice
        }
        self.slots[i] = .{ .page_id = id, .frame = frame };
        self.len += 1;
    }

    /// Remove `id`; false if it was not there.
    fn remove(self: *PageTable, id: PageId) bool {
        const m = self.mask();
        var hole = self.home(id);
        while (self.slots[hole].page_id != id) : (hole = (hole + 1) & m) {
            if (self.slots[hole].page_id == invalid_page_id) return false;
        }
        // Close the gap. An entry at j whose home lies in (hole, j] is still
        // reachable with the hole empty and stays; any other entry of the run
        // was pushed past the hole by a collision and moves into it, which
        // leaves a new hole at j.
        var j = hole;
        while (true) {
            j = (j + 1) & m;
            const slot = self.slots[j];
            if (slot.page_id == invalid_page_id) break;
            const from_home = (j -% self.home(slot.page_id)) & m;
            const from_hole = (j -% hole) & m;
            if (from_home >= from_hole) {
                self.slots[hole] = slot;
                hole = j;
            }
        }
        self.slots[hole] = .{};
        self.len -= 1;
        return true;
    }

    fn count(self: *const PageTable) u32 {
        return self.len;
    }
};

/// A pointer into the frame slab. The alignment is part of the type: frames
/// are page-aligned, so a header struct can be laid over the start of one.
pub const PagePtr = *align(page_size) Page;

pub const BufferPool = struct {
    allocator: Allocator,
    /// Borrowed: the caller owns the pager and keeps it alive.
    pager: *Pager,
    /// One allocation of frame_count * 4096 bytes, 4096-aligned. Frame f is
    /// slab[f * 4096 ..][0..4096]. Frames never move.
    slab: []align(page_size) u8,
    /// Bookkeeping for frame f, parallel to the slab.
    frames: []Frame,
    /// page id -> frame index, for the pages currently in memory.
    page_table: PageTable,
    /// The clock hand: the next frame the eviction sweep will look at.
    hand: u32 = 0,
    stats: Stats = .{},

    pub const Frame = struct {
        page_id: PageId = invalid_page_id, // invalid_page_id = frame is empty
        pin_count: u32 = 0,
        referenced: bool = false,
        dirty: bool = false,
    };

    pub const Stats = struct {
        /// fetchPage found the page in memory.
        hits: u64 = 0,
        /// fetchPage had to go to the pager.
        misses: u64 = 0,
        /// A cached page was removed to make room.
        evictions: u64 = 0,
        /// Evictions that first had to write a dirty page back.
        writebacks: u64 = 0,
    };

    pub const Error = Pager.Error || error{
        /// Every frame is pinned: nothing can be evicted. Either the pool is
        /// too small for the operation, or somebody forgot to unpin.
        AllFramesPinned,
    };

    pub const NewPage = struct { id: PageId, page: PagePtr };

    pub fn init(allocator: Allocator, pager: *Pager, frame_count: u32) Allocator.Error!BufferPool {
        assert(frame_count > 0);
        const slab = try allocator.alignedAlloc(u8, .fromByteUnits(page_size), @as(usize, frame_count) * page_size);
        errdefer allocator.free(slab);
        const frames = try allocator.alloc(Frame, frame_count);
        errdefer allocator.free(frames);
        @memset(frames, .{});
        // Sized now for one entry per frame; the table never holds more.
        const page_table: PageTable = try .init(allocator, frame_count);
        return .{ .allocator = allocator, .pager = pager, .slab = slab, .frames = frames, .page_table = page_table };
    }

    /// Frees the memory. Does NOT flush: unwritten dirty pages are lost, as
    /// they would be in a crash. Call `flushAll` first to keep them.
    /// A page still pinned here is a pin leak in the caller, and the assert
    /// says so. That includes error paths: see "Errors and pins" at the top.
    pub fn deinit(self: *BufferPool) void {
        assert(self.pinnedFrames() == 0);
        self.page_table.deinit(self.allocator);
        self.allocator.free(self.frames);
        self.allocator.free(self.slab);
        self.* = undefined;
    }

    /// Return page `id` in memory and pin it. The pointer is valid until the
    /// matching `unpin`. Every successful fetchPage needs exactly one unpin;
    /// a failed one took no pin.
    pub fn fetchPage(self: *BufferPool, id: PageId) Error!PagePtr {
        if (id >= self.pager.pageCount()) return error.PageOutOfRange;

        if (self.page_table.get(id)) |f| {
            // Hit: no I/O. Setting `referenced` is what protects a popular
            // page from the next sweep of the clock hand.
            const frame = &self.frames[f];
            frame.pin_count += 1;
            frame.referenced = true;
            self.stats.hits += 1;
            return self.frameBytes(f);
        }

        // Miss: find a frame, then read the page into it.
        self.stats.misses += 1;
        const f = try self.takeFrame();
        // If the read fails, frame f stays empty (I2 holds) and whatever page
        // takeFrame evicted from it stays evicted. Put the hand back on f so
        // that the next miss takes this empty frame instead of evicting a
        // second page while one frame sits unused.
        errdefer self.hand = f;
        try self.pager.readPage(id, self.frameBytes(f));
        self.install(f, id);
        return self.frameBytes(f);
    }

    /// Allocate a new page at the end of the file and return it pinned and
    /// zero-filled. Nothing is read: a fresh page has no content to load.
    /// On an error the file has not grown and nothing is pinned.
    pub fn newPage(self: *BufferPool) Error!NewPage {
        // Take the frame first: if every frame is pinned we must not have
        // grown the file yet.
        const f = try self.takeFrame();
        errdefer self.hand = f; // as in fetchPage: reuse the empty frame next
        const id = try self.pager.allocatePage();
        @memset(self.frameBytes(f), 0);
        self.install(f, id);
        return .{ .id = id, .page = self.frameBytes(f) };
    }

    /// Release one pin on page `id`. Pass `dirty = true` if the page was
    /// modified while pinned. The flag is sticky: a later clean unpin does not
    /// clear it; only writing the page out does.
    pub fn unpin(self: *BufferPool, id: PageId, dirty: bool) void {
        const f = self.page_table.get(id) orelse unreachable; // unpin of a page that is not cached
        const frame = &self.frames[f];
        assert(frame.pin_count > 0); // unpin without a matching fetch
        frame.pin_count -= 1;
        if (dirty) frame.dirty = true;
    }

    /// Write page `id` to the pager if it is cached and dirty. No sync.
    pub fn flushPage(self: *BufferPool, id: PageId) Error!void {
        const f = self.page_table.get(id) orelse return;
        try self.flushFrame(f);
    }

    /// Write every dirty page, then sync the pager once. Pages stay cached.
    pub fn flushAll(self: *BufferPool) Error!void {
        for (0..self.frames.len) |f| try self.flushFrame(@intCast(f));
        try self.pager.sync();
    }

    /// Which frame holds page `id` right now, if any (for tests and displays).
    pub fn frameOf(self: *const BufferPool, id: PageId) ?u32 {
        return self.page_table.get(id);
    }

    pub fn frameCount(self: *const BufferPool) u32 {
        return @intCast(self.frames.len);
    }

    /// Number of frames with pin_count > 0.
    pub fn pinnedFrames(self: *const BufferPool) u32 {
        var n: u32 = 0;
        for (self.frames) |frame| {
            if (frame.pin_count > 0) n += 1;
        }
        return n;
    }

    /// Check invariants I1 to I4 (see the top of the file).
    pub fn validate(self: *const BufferPool) error{InvariantViolated}!void {
        var used: u32 = 0;
        for (self.frames, 0..) |frame, f| {
            if (frame.page_id == invalid_page_id) {
                if (frame.pin_count != 0 or frame.dirty or frame.referenced) return error.InvariantViolated; // I2
                continue;
            }
            used += 1;
            const mapped = self.page_table.get(frame.page_id) orelse return error.InvariantViolated; // I1
            if (mapped != f) return error.InvariantViolated; // I1
            if (frame.page_id >= self.pager.pageCount()) return error.InvariantViolated; // I4
        }
        if (self.page_table.count() != used) return error.InvariantViolated; // I1
        if (self.hand >= self.frames.len) return error.InvariantViolated; // I3
    }

    // ---- internals -------------------------------------------------------

    fn frameBytes(self: *BufferPool, f: u32) PagePtr {
        // The slab is 4096-aligned and f * 4096 keeps that alignment.
        return @alignCast(self.slab[@as(usize, f) * page_size ..][0..page_size]);
    }

    /// Record that frame `f` (empty) now holds page `id`, pinned once.
    fn install(self: *BufferPool, f: u32, id: PageId) void {
        self.frames[f] = .{ .page_id = id, .pin_count = 1, .referenced = true, .dirty = false };
        // Cannot fail: the table was sized for frame_count entries in init
        // and takeFrame removed the previous occupant's entry.
        self.page_table.put(id, f);
    }

    fn flushFrame(self: *BufferPool, f: u32) Error!void {
        const frame = &self.frames[f];
        if (frame.page_id == invalid_page_id or !frame.dirty) return;
        try self.pager.writePage(frame.page_id, self.frameBytes(f));
        // Clear the flag only after the write succeeded.
        frame.dirty = false;
    }

    /// CLOCK ("second chance"). Returns an EMPTY frame, evicting if needed.
    ///
    /// The hand sweeps the frames in a circle. At each frame:
    ///   empty               -> take it
    ///   pinned              -> skip it (and leave its referenced bit alone)
    ///   referenced          -> clear the bit and move on: its second chance
    ///   not referenced      -> victim: write it back if dirty, then evict
    ///
    /// Two full turns are enough: the first clears every unpinned frame's
    /// bit, so the second must stop at the first unpinned frame. If we get
    /// through both, every frame is pinned.
    fn takeFrame(self: *BufferPool) Error!u32 {
        const n: u32 = @intCast(self.frames.len);
        var steps: u32 = 0;
        while (steps < 2 * n) : (steps += 1) {
            const f = self.hand;
            const frame = &self.frames[f];
            if (frame.page_id != invalid_page_id) {
                if (frame.pin_count > 0) {
                    self.advanceHand();
                    continue;
                }
                if (frame.referenced) {
                    frame.referenced = false;
                    self.advanceHand();
                    continue;
                }
                // Victim. A dirty page is the only copy of its changes: write
                // it BEFORE dropping it. If the write fails we return with the
                // frame untouched (still cached, still dirty), nothing lost.
                // The hand stays on this frame, so the next sweep retries the
                // same write: no eviction happens until it succeeds.
                if (frame.dirty) {
                    try self.pager.writePage(frame.page_id, self.frameBytes(f));
                    self.stats.writebacks += 1;
                }
                const removed = self.page_table.remove(frame.page_id);
                assert(removed);
                frame.* = .{};
                self.stats.evictions += 1;
            }
            self.advanceHand();
            return f;
        }
        return error.AllFramesPinned;
    }

    fn advanceHand(self: *BufferPool) void {
        self.hand = (self.hand + 1) % @as(u32, @intCast(self.frames.len));
    }
};

// ---- tests -----------------------------------------------------------------

const MemStorage = storage_mod.MemStorage;
const FileStorage = storage_mod.FileStorage;
const SplitMix64 = @import("prng.zig").SplitMix64;

/// Test helper: a pager over `mem` with `pages` zero pages allocated.
fn pagerWithPages(mem: *MemStorage, pages: u32) !Pager {
    var pager: Pager = try .init(mem.storage());
    for (0..pages) |_| _ = try pager.allocatePage();
    pager.stats = .{};
    return pager;
}

/// Test helper: fetch + unpin, i.e. "touch" a page.
fn touch(pool: *BufferPool, id: PageId, dirty: bool) !void {
    const page = try pool.fetchPage(id);
    if (dirty) page[0] +%= 1;
    pool.unpin(id, dirty);
}

fn cachedPages(pool: *const BufferPool, out: []PageId) []PageId {
    for (pool.frames, 0..) |frame, f| out[f] = frame.page_id;
    return out[0..pool.frames.len];
}

test "BufferPool: hits cost no I/O, misses cost one read" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 4);
    var pool: BufferPool = try .init(testing.allocator, &pager, 2);
    defer pool.deinit();

    try touch(&pool, 0, false); // miss
    try touch(&pool, 0, false); // hit
    try touch(&pool, 1, false); // miss
    try touch(&pool, 0, false); // hit
    try testing.expectEqual(BufferPool.Stats{ .hits = 2, .misses = 2 }, pool.stats);
    try testing.expectEqual(2, pager.stats.reads);
    try pool.validate();
    try testing.expectError(error.PageOutOfRange, pool.fetchPage(4));
}

test "BufferPool: fetch returns the same frame while the page is cached" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 2);
    var pool: BufferPool = try .init(testing.allocator, &pager, 2);
    defer pool.deinit();

    const a = try pool.fetchPage(1);
    const b = try pool.fetchPage(1); // second pin on the same frame
    try testing.expectEqual(a, b);
    try testing.expect(std.mem.isAligned(@intFromPtr(a), page_size));
    try testing.expectEqual(2, pool.frames[0].pin_count);
    pool.unpin(1, false);
    try testing.expectEqual(1, pool.pinnedFrames());
    pool.unpin(1, false);
    try testing.expectEqual(0, pool.pinnedFrames());
}

test "BufferPool: CLOCK gives a referenced page a second chance" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 8);
    var pool: BufferPool = try .init(testing.allocator, &pager, 3);
    defer pool.deinit();
    var buf: [3]PageId = undefined;

    // Fill: frames [0 1 2], all referenced, hand back at 0.
    for (0..3) |i| try touch(&pool, @intCast(i), false);
    try testing.expectEqual(0, pool.hand);

    // Page 3: the sweep clears all three bits, comes round, evicts frame 0.
    try touch(&pool, 3, false);
    try testing.expectEqualSlices(PageId, &.{ 3, 1, 2 }, cachedPages(&pool, &buf));
    try testing.expectEqual(1, pool.hand);

    // Touch page 1: its bit is set again. Page 2's bit is still clear.
    try touch(&pool, 1, false);
    // Page 4: the hand is at frame 1 (page 1, referenced): second chance.
    // Frame 2 (page 2, not referenced) is the victim.
    try touch(&pool, 4, false);
    try testing.expectEqualSlices(PageId, &.{ 3, 1, 4 }, cachedPages(&pool, &buf));
    try testing.expect(!pool.frames[1].referenced); // the chance was used up
    try testing.expectEqual(0, pool.hand);
    try testing.expectEqual(2, pool.stats.evictions);
    try pool.validate();
}

test "BufferPool: pinned pages are never evicted; all pinned is an error" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 4);
    var pool: BufferPool = try .init(testing.allocator, &pager, 2);
    defer pool.deinit();
    var buf: [2]PageId = undefined;

    const p0 = try pool.fetchPage(0); // stays pinned
    p0[100] = 7;
    try touch(&pool, 1, false);
    try touch(&pool, 2, false); // must evict page 1, not the pinned page 0
    try testing.expectEqualSlices(PageId, &.{ 0, 2 }, cachedPages(&pool, &buf));
    try testing.expectEqual(7, p0[100]); // the pointer is still good

    _ = try pool.fetchPage(2); // now both frames are pinned
    const before = pool.stats;
    try testing.expectError(error.AllFramesPinned, pool.fetchPage(3));
    try testing.expectError(error.AllFramesPinned, pool.newPage());
    // The failed fetch changed nothing except the miss counter.
    try testing.expectEqualSlices(PageId, &.{ 0, 2 }, cachedPages(&pool, &buf));
    try testing.expectEqual(before.evictions, pool.stats.evictions);
    try testing.expectEqual(4, pager.pageCount()); // newPage did not grow the file
    try pool.validate();

    pool.unpin(2, false);
    try touch(&pool, 3, false); // works again
    pool.unpin(0, true);
}

test "BufferPool: a dirty page is written back when evicted, a clean one is not" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 4);
    var pool: BufferPool = try .init(testing.allocator, &pager, 1);
    defer pool.deinit();

    const p0 = try pool.fetchPage(0);
    @memcpy(p0[0..5], "dirty");
    pool.unpin(0, true);
    // Still only in memory: the storage has zeroes.
    try testing.expect(std.mem.allEqual(u8, mem.bytes.items[0..5], 0));

    try touch(&pool, 1, false); // evicts page 0 -> write back
    try testing.expectEqual(1, pager.stats.writes);
    try testing.expectEqual(1, pool.stats.writebacks);
    try testing.expectEqualSlices(u8, "dirty", mem.bytes.items[0..5]);

    try touch(&pool, 2, false); // evicts clean page 1 -> no write
    try testing.expectEqual(1, pager.stats.writes);
    try testing.expectEqual(2, pool.stats.evictions);

    // Reading page 0 again brings the modified bytes back from storage.
    const again = try pool.fetchPage(0);
    try testing.expectEqualSlices(u8, "dirty", again[0..5]);
    pool.unpin(0, false);
}

test "BufferPool: the dirty flag is sticky across a clean unpin" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 2);
    var pool: BufferPool = try .init(testing.allocator, &pager, 2);
    defer pool.deinit();

    try touch(&pool, 0, true);
    try touch(&pool, 0, false); // a reader comes later; the page is still dirty
    try testing.expect(pool.frames[0].dirty);
    try pool.flushPage(0);
    try testing.expect(!pool.frames[0].dirty);
    try testing.expectEqual(1, pager.stats.writes);
    try pool.flushPage(0); // clean: nothing to write
    try pool.flushPage(1); // not cached: nothing to write
    try testing.expectEqual(1, pager.stats.writes);
}

test "BufferPool: flushAll writes dirty pages once and syncs; data survives reopen" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var file: FileStorage = try .create(io, tmp.dir, "pool.db");
        defer file.close();
        var pager: Pager = try .init(file.storage());
        var pool: BufferPool = try .init(testing.allocator, &pager, 4);
        defer pool.deinit();

        for (0..3) |i| {
            const np = try pool.newPage();
            try testing.expectEqual(i, np.id);
            try testing.expect(std.mem.allEqual(u8, np.page, 0));
            std.mem.writeInt(u64, np.page[0..8], 1000 + i, .little);
            pool.unpin(np.id, true);
        }
        try pool.flushAll();
        try testing.expectEqual(3, pager.stats.writes);
        try testing.expectEqual(1, pager.stats.syncs);
        try pool.flushAll(); // nothing dirty any more
        try testing.expectEqual(3, pager.stats.writes);
        try pool.validate();
    }

    var file: FileStorage = try .open(io, tmp.dir, "pool.db");
    defer file.close();
    var pager: Pager = try .init(file.storage());
    try testing.expectEqual(3, pager.pageCount());
    var pool: BufferPool = try .init(testing.allocator, &pager, 2);
    defer pool.deinit();
    for (0..3) |i| {
        const page = try pool.fetchPage(@intCast(i));
        try testing.expectEqual(1000 + i, std.mem.readInt(u64, page[0..8], .little));
        pool.unpin(@intCast(i), false);
    }
}

test "BufferPool: without a flush, dirty pages are lost (deinit is not a checkpoint)" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 1);
    {
        var pool: BufferPool = try .init(testing.allocator, &pager, 2);
        defer pool.deinit();
        try touch(&pool, 0, true);
    }
    try testing.expect(std.mem.allEqual(u8, mem.bytes.items, 0));
}

test "BufferPool: a failed write-back keeps the page cached and dirty" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 3);
    var pool: BufferPool = try .init(testing.allocator, &pager, 1);
    defer pool.deinit();

    try touch(&pool, 0, true);
    mem.writes_before_failure = 0;
    try testing.expectError(error.StorageFailure, pool.fetchPage(1));
    try testing.expectError(error.StorageFailure, pool.flushAll());
    // Page 0 is still here with its change; nothing was dropped.
    try testing.expectEqual(0, pool.frames[0].page_id);
    try testing.expect(pool.frames[0].dirty);
    try testing.expectEqual(0, pool.stats.evictions);
    try pool.validate();

    mem.writes_before_failure = null; // the disk recovers
    try touch(&pool, 1, false);
    try testing.expectEqual(1, mem.bytes.items[0]);
}

test "BufferPool: a victim that cannot be written blocks eviction until the storage recovers" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 4);
    var pool: BufferPool = try .init(testing.allocator, &pager, 2);
    defer pool.deinit();
    var buf: [2]PageId = undefined;

    try touch(&pool, 0, true); // dirty
    try touch(&pool, 1, false); // clean
    mem.writes_before_failure = 0;
    // The sweep reaches dirty page 0 first. Clean page 1 could be evicted
    // without any write, but the pool does not skip a page it failed to save.
    try testing.expectError(error.StorageFailure, pool.fetchPage(2));
    try testing.expectError(error.StorageFailure, pool.fetchPage(3));
    try testing.expectEqualSlices(PageId, &.{ 0, 1 }, cachedPages(&pool, &buf));
    try testing.expectEqual(0, pool.hand);
    try testing.expect(pool.frames[0].dirty);
    try pool.validate();
    // Pages that are cached are still served.
    try touch(&pool, 1, false);

    mem.writes_before_failure = null;
    try touch(&pool, 2, false);
    try testing.expectEqualSlices(PageId, &.{ 2, 1 }, cachedPages(&pool, &buf));
    try testing.expectEqual(1, mem.bytes.items[0]); // page 0 reached the storage
}

test "BufferPool: a failed read leaves an empty frame that the next miss reuses" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 6);
    var pool: BufferPool = try .init(testing.allocator, &pager, 2);
    defer pool.deinit();
    var buf: [2]PageId = undefined;

    try touch(&pool, 0, true);
    try touch(&pool, 1, true);
    mem.reads_before_failure = 0;
    // The miss evicts page 0 (written back first), then the read fails.
    try testing.expectError(error.StorageFailure, pool.fetchPage(2));
    try testing.expectEqualSlices(PageId, &.{ invalid_page_id, 1 }, cachedPages(&pool, &buf));
    try testing.expectEqual(0, pool.hand); // back on the empty frame
    try testing.expectEqual(0, pool.pinnedFrames()); // the failed fetch took no pin
    try testing.expectEqual(null, pool.frameOf(2));
    try pool.validate();
    try testing.expectEqual(1, mem.bytes.items[0]); // the evicted page was saved

    mem.reads_before_failure = null;
    try touch(&pool, 3, false);
    // Page 3 went into the empty frame; page 1 was not evicted for it.
    try testing.expectEqualSlices(PageId, &.{ 3, 1 }, cachedPages(&pool, &buf));
    try testing.expectEqual(1, pool.stats.evictions);
    try testing.expectEqual(1, pool.stats.writebacks);
    try pool.validate();
}

test "BufferPool: a failed newPage neither grows the file nor wastes a frame" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 3);
    var pool: BufferPool = try .init(testing.allocator, &pager, 2);
    defer pool.deinit();
    var buf: [2]PageId = undefined;

    try touch(&pool, 0, false);
    try touch(&pool, 1, false);
    mem.writes_before_failure = 0; // growing the file fails
    try testing.expectError(error.StorageFailure, pool.newPage());
    try testing.expectEqual(3, pager.pageCount());
    try testing.expectEqual(0, pool.pinnedFrames());
    try testing.expectEqualSlices(PageId, &.{ invalid_page_id, 1 }, cachedPages(&pool, &buf));
    try pool.validate();

    mem.writes_before_failure = null;
    const np = try pool.newPage(); // the retry works and uses the empty frame
    try testing.expectEqual(3, np.id);
    try testing.expectEqualSlices(PageId, &.{ 3, 1 }, cachedPages(&pool, &buf));
    try testing.expectEqual(1, pool.stats.evictions);
    pool.unpin(np.id, true);
}

/// The shape every multi-page operation in later chapters has: hold one pin,
/// then do something that can fail.
fn copyFirstByte(pool: *BufferPool, from: PageId, to: PageId) !void {
    const src = try pool.fetchPage(from);
    defer pool.unpin(from, false); // read only: the same unpin on both paths
    const dst = try pool.fetchPage(to); // may fail while `from` is pinned
    errdefer pool.unpin(to, false); // error path: nothing was changed
    if (src[0] == 0xFF) return error.BadSource; // a failure with both pinned
    dst[0] = src[0];
    pool.unpin(to, true); // success path: released dirty
}

test "BufferPool: defer and errdefer release the caller's pins when a later step fails" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 4);
    var pool: BufferPool = try .init(testing.allocator, &pager, 2);
    defer pool.deinit(); // would assert if copyFirstByte leaked a pin

    mem.reads_before_failure = 1; // the first fetch works, the second does not
    try testing.expectError(error.StorageFailure, copyFirstByte(&pool, 0, 1));
    try testing.expectEqual(0, pool.pinnedFrames());
    mem.reads_before_failure = null;

    const p0 = try pool.fetchPage(0);
    p0[0] = 0xFF;
    pool.unpin(0, true);
    try testing.expectError(error.BadSource, copyFirstByte(&pool, 0, 1));
    try testing.expectEqual(0, pool.pinnedFrames());
    try testing.expect(!pool.frames[pool.frameOf(1).?].dirty); // released clean

    try copyFirstByte(&pool, 2, 1);
    try testing.expectEqual(0, pool.pinnedFrames());
}

test "PageTable: matches a model through many insertions and removals" {
    const frame_count = 37;
    var table: PageTable = try .init(testing.allocator, frame_count);
    defer table.deinit(testing.allocator);
    try testing.expectEqual(128, table.slots.len); // next power of two >= 2 * 37

    // Model: model[f] = the page "cached" in frame f.
    var model: [frame_count]PageId = @splat(invalid_page_id);
    var rng = SplitMix64.init(41);
    for (0..20000) |_| {
        const f: u32 = @intCast(rng.below(frame_count));
        if (model[f] != invalid_page_id) {
            try testing.expect(table.remove(model[f]));
            try testing.expect(!table.remove(model[f])); // gone
            model[f] = invalid_page_id;
        }
        // Mostly small ids, as in a real file; sometimes any 32-bit id.
        const id: PageId = @intCast(if (rng.chance(3, 4)) rng.below(300) else rng.below(invalid_page_id));
        if (table.get(id) == null) {
            table.put(id, f);
            model[f] = id;
        }
    }
    var used: u32 = 0;
    for (model, 0..) |id, f| {
        if (id == invalid_page_id) continue;
        used += 1;
        try testing.expectEqual(@as(?u32, @intCast(f)), table.get(id));
    }
    try testing.expectEqual(used, table.count());
    // No tombstones: every slot that holds no entry is really empty.
    var empty: u32 = 0;
    for (table.slots) |slot| {
        if (slot.page_id == invalid_page_id) empty += 1;
    }
    try testing.expectEqual(table.slots.len - used, empty);
}

test "BufferPool: lookups stay short after the pool has cycled through many pages" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 2000);
    var pool: BufferPool = try .init(testing.allocator, &pager, 100);
    defer pool.deinit();

    for (0..3) |_| {
        for (0..2000) |id| try touch(&pool, @intCast(id), false);
    }
    try pool.validate();
    // 5900 evictions later the table still has exactly one used slot per
    // cached page and every other slot free.
    var empty: usize = 0;
    var longest_run: usize = 0;
    var run: usize = 0;
    for (pool.page_table.slots) |slot| {
        if (slot.page_id == invalid_page_id) {
            empty += 1;
            run = 0;
        } else {
            run += 1;
            longest_run = @max(longest_run, run);
        }
    }
    try testing.expectEqual(pool.page_table.slots.len - 100, empty);
    // A miss probes at most one run of used slots. (std's hash map, used at
    // a fixed capacity, had no free slot left at this point: every miss
    // probed its whole table.)
    try testing.expect(longest_run <= 16);
}

fn initAndUse(allocator: Allocator, pager: *Pager) !void {
    var pool: BufferPool = try .init(allocator, pager, 4);
    defer pool.deinit();
    try touch(&pool, 0, false);
}

test "BufferPool: init frees everything when any of its allocations fails" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 1);
    try testing.checkAllAllocationFailures(testing.allocator, initAndUse, .{&pager});
}

test "BufferPool: nothing allocates after init" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager = try pagerWithPages(&mem, 64);

    // Let init's allocations through, then make every later one fail.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var pool: BufferPool = try .init(failing.allocator(), &pager, 4);
    defer pool.deinit();
    const allocations_after_init = failing.allocations;
    failing.fail_index = failing.alloc_index; // the very next allocation fails

    var rng = SplitMix64.init(9);
    for (0..2000) |_| try touch(&pool, @intCast(rng.below(64)), rng.chance(1, 3));
    try pool.flushAll();
    try testing.expectEqual(allocations_after_init, failing.allocations);
    try testing.expect(!failing.has_induced_failure);
    try pool.validate();
}

//! `SimDisk`: an in-memory disk that can lose power.
//!
//! It keeps two things apart that a real machine also keeps apart:
//!
//!   durable   the bytes on the platter: what is left after a power cut
//!   pending   writes the process issued that were not synced yet (on a real
//!             machine they sit in the OS page cache and the drive's cache)
//!
//!   writePage(p, bytes)  append to `pending`           (durable untouched)
//!   readPage(p)          newest pending write for p, else durable
//!   sync()               apply all pending writes in order, then forget them
//!   crash(mode)          decide the fate of every pending write, then forget
//!
//! Crash modes (`CrashMode`):
//!   .drop    every pending write is lost
//!   .keep    every pending write reached the disk (the OS had flushed them)
//!   .tear    every pending write is torn: some of its eight 512-byte sectors
//!            are new, the others keep their old contents
//!   .random  each pending write independently gets one of the three fates
//!
//! All randomness comes from the SplitMix64 seeded in `init`, so a failing
//! crash test is reproduced by its seed. Draws per crash, in pending order:
//!   .tear    one `below(254)` per write: sector mask = 1 + draw (1..254, so
//!            never "no sector" and never "all sectors"); bit s = sector s new
//!   .random  one `below(3)` per write (0 drop, 1 keep, 2 tear), followed by
//!            the mask draw if the write is torn
//!   .drop / .keep draw nothing
//!
//! Crash-after-N-writes: `powerOffAfterWrites(n)` lets `n` more writes
//! succeed; after that every operation returns `error.PowerLoss` until
//! `crash` is called, which also "reboots" the disk. A test loops n = 0, 1, 2,
//! ... to stop a multi-write operation at every possible point.
//!
//! Memory: the durable image belongs to the general-purpose allocator (it
//! lives as long as the disk). Pending writes live in an arena that is reset
//! at every sync and every crash, the two moments at which all pending writes
//! die together. `writePage` reserves the durable space its write may need,
//! so `sync` and `crash` never allocate and cannot fail for lack of memory.
const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitMix64 = @import("prng.zig").SplitMix64;
const storage_mod = @import("storage.zig");
const Storage = storage_mod.Storage;
const Page = storage_mod.Page;
const page_size = storage_mod.page_size;
const sector_size = storage_mod.sector_size;
const sectors_per_page = storage_mod.sectors_per_page;

pub const CrashMode = enum { drop, keep, tear, random };

/// What `crash` did to the pending writes.
pub const CrashReport = struct { dropped: u32 = 0, kept: u32 = 0, torn: u32 = 0 };

pub const Stats = struct { reads: u64 = 0, writes: u64 = 0, syncs: u64 = 0, crashes: u64 = 0 };

pub const SimDisk = struct {
    gpa: Allocator,
    /// The platter: a whole number of pages.
    durable: std.ArrayList(u8) = .empty,
    /// Owns the page copies and the list of `pending`.
    arena: std.heap.ArenaAllocator,
    /// Unsynced writes, oldest first.
    pending: std.ArrayList(Pending) = .empty,
    prng: SplitMix64,
    /// null = power stays on. Some(n) = n more writes succeed, then PowerLoss.
    writes_left: ?u64 = null,
    stats: Stats = .{},

    const Pending = struct { page_no: u64, data: *const Page };

    /// Largest page number + 1 this simulator accepts (256 MiB of pages).
    pub const max_pages = 1 << 16;

    pub fn init(gpa: Allocator, seed: u64) SimDisk {
        return .{ .gpa = gpa, .arena = .init(gpa), .prng = .init(seed) };
    }

    pub fn deinit(self: *SimDisk) void {
        self.arena.deinit();
        self.durable.deinit(self.gpa);
        self.* = undefined;
    }

    /// The interface value. `self` must outlive it and must not move.
    pub fn storage(self: *SimDisk) Storage {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // ---- the four Storage operations ----

    pub fn readPage(self: *SimDisk, page_no: u64, out: *Page) Storage.Error!void {
        if (self.isPoweredOff()) return error.PowerLoss;
        self.stats.reads += 1;
        // Newest pending write wins: this is the OS page cache answering.
        var i = self.pending.items.len;
        while (i > 0) {
            i -= 1;
            if (self.pending.items[i].page_no == page_no) {
                out.* = self.pending.items[i].data.*;
                return;
            }
        }
        if (page_no >= self.durablePages()) return error.OutOfBounds;
        const start: usize = @intCast(page_no * page_size);
        @memcpy(out, self.durable.items[start..][0..page_size]);
    }

    pub fn writePage(self: *SimDisk, page_no: u64, page: *const Page) Storage.Error!void {
        if (self.isPoweredOff()) return error.PowerLoss;
        if (page_no >= max_pages) return error.OutOfBounds;
        // Reserve everything first, so that a failed allocation changes
        // nothing and so that sync/crash never need memory later.
        try self.durable.ensureTotalCapacity(self.gpa, @intCast((page_no + 1) * page_size));
        const arena = self.arena.allocator();
        try self.pending.ensureUnusedCapacity(arena, 1);
        const copy = try arena.create(Page);
        copy.* = page.*;
        self.pending.appendAssumeCapacity(.{ .page_no = page_no, .data = copy });
        self.stats.writes += 1;
        if (self.writes_left) |*left| left.* -= 1;
    }

    pub fn sync(self: *SimDisk) Storage.Error!void {
        if (self.isPoweredOff()) return error.PowerLoss;
        for (self.pending.items) |w| self.apply(w, all_sectors);
        self.forgetPending();
        self.stats.syncs += 1;
    }

    /// Pages visible to the running process (durable or pending).
    pub fn size(self: *const SimDisk) u64 {
        var n = self.durablePages();
        for (self.pending.items) |w| n = @max(n, w.page_no + 1);
        return n;
    }

    // ---- fault injection ----

    /// Let `n` more writes succeed, then fail every operation with
    /// `error.PowerLoss` until `crash` is called. `n = 0` fails immediately.
    pub fn powerOffAfterWrites(self: *SimDisk, n: u64) void {
        self.writes_left = n;
    }

    pub fn isPoweredOff(self: *const SimDisk) bool {
        return if (self.writes_left) |left| left == 0 else false;
    }

    /// Power cut and reboot. Decides what happens to each pending write (see
    /// the file comment), empties the pending list, and turns the power back
    /// on. Afterwards reads see exactly the durable image.
    pub fn crash(self: *SimDisk, mode: CrashMode) CrashReport {
        var report: CrashReport = .{};
        for (self.pending.items) |w| {
            const fate: CrashMode = switch (mode) {
                .random => @enumFromInt(@as(u2, @intCast(self.prng.below(3)))), // 0 drop, 1 keep, 2 tear
                else => mode,
            };
            switch (fate) {
                .drop => report.dropped += 1,
                .keep => {
                    self.apply(w, all_sectors);
                    report.kept += 1;
                },
                .tear => {
                    const mask: u8 = @intCast(1 + self.prng.below(254));
                    self.apply(w, mask);
                    report.torn += 1;
                },
                .random => unreachable,
            }
        }
        self.forgetPending();
        self.writes_left = null;
        self.stats.crashes += 1;
        return report;
    }

    // ---- inspection ----

    pub fn pendingCount(self: *const SimDisk) usize {
        return self.pending.items.len;
    }

    pub fn durablePages(self: *const SimDisk) u64 {
        return self.durable.items.len / page_size;
    }

    /// The durable bytes of a page, ignoring pending writes: what a crash with
    /// `.drop` would leave. null if the durable image is shorter.
    pub fn durablePage(self: *const SimDisk, page_no: u64) ?*const Page {
        if (page_no >= self.durablePages()) return null;
        const start: usize = @intCast(page_no * page_size);
        return self.durable.items[start..][0..page_size];
    }

    /// Internal invariants; tests call this after every operation.
    pub fn validate(self: *const SimDisk) error{Invalid}!void {
        // The platter holds whole pages only.
        if (self.durable.items.len % page_size != 0) return error.Invalid;
        // Every pending write can be applied without allocating.
        for (self.pending.items) |w| {
            if (w.page_no >= max_pages) return error.Invalid;
            if (self.durable.capacity < (w.page_no + 1) * page_size) return error.Invalid;
        }
        // Each accepted write is either still pending or was resolved by a
        // sync or a crash, so there can never be more pending than accepted.
        if (self.pending.items.len > self.stats.writes) return error.Invalid;
    }

    // ---- internals ----

    const all_sectors: u8 = 0xFF;

    /// Copy the sectors selected by `mask` (bit s = sector s) from a pending
    /// write onto the platter. Sectors not selected keep their old bytes;
    /// if the page did not exist yet, "old" means zeroes.
    fn apply(self: *SimDisk, w: Pending, mask: u8) void {
        const start: usize = @intCast(w.page_no * page_size);
        if (self.durable.items.len < start + page_size) {
            const grow = start + page_size - self.durable.items.len;
            self.durable.appendNTimesAssumeCapacity(0, grow); // reserved by writePage
        }
        const dst = self.durable.items[start..][0..page_size];
        for (0..sectors_per_page) |s| {
            if (mask & (@as(u8, 1) << @intCast(s)) == 0) continue;
            const at = s * sector_size;
            @memcpy(dst[at..][0..sector_size], w.data[at..][0..sector_size]);
        }
    }

    fn forgetPending(self: *SimDisk) void {
        // The list's buffer lives in the arena too, so drop it before the
        // reset, which keeps the arena's memory for the next batch of writes.
        self.pending = .empty;
        _ = self.arena.reset(.retain_capacity);
    }

    const vtable: Storage.VTable = .{
        .readPage = vtReadPage,
        .writePage = vtWritePage,
        .sync = vtSync,
        .size = vtSize,
    };
    fn vtReadPage(ptr: *anyopaque, page_no: u64, out: *Page) Storage.Error!void {
        return cast(ptr).readPage(page_no, out);
    }
    fn vtWritePage(ptr: *anyopaque, page_no: u64, page: *const Page) Storage.Error!void {
        return cast(ptr).writePage(page_no, page);
    }
    fn vtSync(ptr: *anyopaque) Storage.Error!void {
        return cast(ptr).sync();
    }
    fn vtSize(ptr: *anyopaque) u64 {
        return cast(ptr).size();
    }
    fn cast(ptr: *anyopaque) *SimDisk {
        return @ptrCast(@alignCast(ptr));
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

fn filled(byte: u8) Page {
    return @splat(byte);
}

test "SimDisk: a write is visible at once but durable only after sync" {
    var disk: SimDisk = .init(testing.allocator, 1);
    defer disk.deinit();
    var page: Page = undefined;

    try disk.writePage(0, &filled('A'));
    try disk.readPage(0, &page);
    try testing.expect(std.mem.allEqual(u8, &page, 'A')); // the cache answers
    try testing.expectEqual(null, disk.durablePage(0)); // the platter is empty
    try testing.expectEqual(1, disk.size());

    try testing.expectEqual(CrashReport{ .dropped = 1 }, disk.crash(.drop));
    try testing.expectEqual(0, disk.size());
    try testing.expectError(error.OutOfBounds, disk.readPage(0, &page));

    try disk.writePage(0, &filled('A'));
    try disk.sync();
    try testing.expectEqual(CrashReport{}, disk.crash(.drop)); // nothing pending
    try disk.readPage(0, &page);
    try testing.expect(std.mem.allEqual(u8, &page, 'A'));
    try disk.validate();
}

test "SimDisk: keep applies writes in order, holes read as zeroes" {
    var disk: SimDisk = .init(testing.allocator, 1);
    defer disk.deinit();
    try disk.writePage(2, &filled('A'));
    try disk.writePage(2, &filled('B'));
    try testing.expectEqual(CrashReport{ .kept = 2 }, disk.crash(.keep));
    var page: Page = undefined;
    try disk.readPage(2, &page);
    try testing.expect(std.mem.allEqual(u8, &page, 'B'));
    try disk.readPage(0, &page);
    try testing.expect(std.mem.allEqual(u8, &page, 0));
    try testing.expectEqual(3, disk.size());
}

test "SimDisk: a torn write mixes old and new sectors, never bytes within one" {
    for (0..200) |seed| {
        var disk: SimDisk = .init(testing.allocator, seed);
        defer disk.deinit();
        try disk.writePage(0, &filled('A'));
        try disk.sync();
        try disk.writePage(0, &filled('B'));
        try testing.expectEqual(CrashReport{ .torn = 1 }, disk.crash(.tear));

        const page = disk.durablePage(0).?;
        var new_sectors: usize = 0;
        for (0..sectors_per_page) |s| {
            const sector = page[s * sector_size ..][0..sector_size];
            const first = sector[0];
            try testing.expect(first == 'A' or first == 'B');
            try testing.expect(std.mem.allEqual(u8, sector, first)); // sector is atomic
            if (first == 'B') new_sectors += 1;
        }
        // The mask is 1..254: at least one sector new, at least one old.
        try testing.expect(new_sectors >= 1 and new_sectors <= sectors_per_page - 1);
    }
}

test "SimDisk: the same seed tears the same way" {
    var images: [2]Page = undefined;
    for (&images) |*image| {
        var disk: SimDisk = .init(testing.allocator, 21);
        defer disk.deinit();
        try disk.writePage(0, &filled('A'));
        try disk.sync();
        try disk.writePage(0, &filled('B'));
        try disk.writePage(1, &filled('C'));
        _ = disk.crash(.random);
        try disk.writePage(0, &filled('D'));
        _ = disk.crash(.tear);
        image.* = disk.durablePage(0).?.*;
    }
    try testing.expectEqualSlices(u8, &images[0], &images[1]);
}

test "SimDisk: power goes off after the Nth write" {
    var disk: SimDisk = .init(testing.allocator, 1);
    defer disk.deinit();
    var page: Page = undefined;

    disk.powerOffAfterWrites(2);
    try disk.writePage(0, &filled('A'));
    try disk.writePage(1, &filled('B')); // the 2nd write is accepted...
    try testing.expect(disk.isPoweredOff());
    try testing.expectError(error.PowerLoss, disk.sync()); // ...but never synced
    try testing.expectError(error.PowerLoss, disk.writePage(2, &filled('C')));
    try testing.expectError(error.PowerLoss, disk.readPage(0, &page));
    try testing.expectEqual(2, disk.stats.writes);

    _ = disk.crash(.keep); // reboot: power is back, budget is gone
    try testing.expect(!disk.isPoweredOff());
    try disk.readPage(1, &page);
    try testing.expect(std.mem.allEqual(u8, &page, 'B'));

    disk.powerOffAfterWrites(0); // crash before anything happens
    try testing.expectError(error.PowerLoss, disk.writePage(0, &filled('Z')));
    try disk.validate();
}

fn writeUnderAllocationFailure(gpa: Allocator) !void {
    var disk: SimDisk = .init(gpa, 1);
    defer disk.deinit();
    try disk.writePage(0, &filled('A'));
    try disk.writePage(3, &filled('B'));
    try disk.sync();
    try disk.writePage(1, &filled('C'));
    _ = disk.crash(.tear);
    try disk.validate();
}

test "SimDisk: every allocation failure in writePage is clean" {
    // Runs the function once per allocation, failing that allocation: it must
    // return OutOfMemory and leak nothing.
    try testing.checkAllAllocationFailures(testing.allocator, writeUnderAllocationFailure, .{});
}

test "SimDisk: a failed write leaves the disk unchanged" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var disk: SimDisk = .init(failing.allocator(), 1);
    defer disk.deinit();
    try disk.writePage(0, &filled('A'));
    try disk.sync();

    // The very next allocation fails, whether it is a fresh one or an
    // attempt to grow the durable buffer in place.
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try testing.expectError(error.OutOfMemory, disk.writePage(7, &filled('B')));
    try testing.expectEqual(0, disk.pendingCount());
    try testing.expectEqual(1, disk.size());
    try testing.expectEqual(1, disk.stats.writes);
    try disk.validate();
}

/// Reference model for the seeded test below. `cache` is what the process
/// should read, `durable` what must survive a crash; one byte per page is
/// enough because every test page is filled with a single byte.
const model_pages = 6;
const Model = struct {
    cache: [model_pages]?u8 = @splat(null),
    durable: [model_pages]?u8 = @splat(null),
    cache_size: u64 = 0,
    durable_size: u64 = 0,
};

test "SimDisk: seeded model test (write, read, sync, crash drop/keep)" {
    var disk: SimDisk = .init(testing.allocator, 7);
    defer disk.deinit();
    var model: Model = .{};
    var rng: SplitMix64 = .init(2121);
    var page: Page = undefined;

    for (0..5000) |_| {
        switch (rng.below(10)) {
            0...4 => { // write
                const p = rng.below(model_pages);
                const byte: u8 = @intCast(1 + rng.below(255));
                try disk.writePage(p, &filled(byte));
                model.cache[@intCast(p)] = byte;
                model.cache_size = @max(model.cache_size, p + 1);
            },
            5...6 => { // read
                const p = rng.below(model_pages);
                if (p >= model.cache_size) {
                    try testing.expectError(error.OutOfBounds, disk.readPage(p, &page));
                } else {
                    try disk.readPage(p, &page);
                    // A hole (never written, below the size) reads as zeroes.
                    try testing.expect(std.mem.allEqual(u8, &page, model.cache[@intCast(p)] orelse 0));
                }
            },
            7 => { // sync: the cache becomes the durable state
                try disk.sync();
                model.durable = model.cache;
                model.durable_size = model.cache_size;
            },
            8 => { // crash, nothing survives but the durable state
                _ = disk.crash(.drop);
                model.cache = model.durable;
                model.cache_size = model.durable_size;
            },
            else => { // crash, everything pending happened to reach the disk
                _ = disk.crash(.keep);
                model.durable = model.cache;
                model.durable_size = model.cache_size;
            },
        }
        try disk.validate();
        try testing.expectEqual(model.cache_size, disk.size());
        try testing.expectEqual(model.durable_size, disk.durablePages());
    }
    try testing.expect(disk.stats.crashes > 100 and disk.stats.syncs > 100);
}

test "SimDisk: after a random crash every sector is old or one of the pending versions" {
    var page: Page = undefined;
    for (0..300) |seed| {
        var disk: SimDisk = .init(testing.allocator, seed);
        defer disk.deinit();
        var rng: SplitMix64 = .init(seed +% 1000);
        // Durable state: pages 0..3 hold byte 1.
        for (0..4) |p| try disk.writePage(p, &filled(1));
        try disk.sync();
        // Pending: up to 6 writes with bytes 2, 3, ... on random pages.
        var allowed: [4]u64 = @splat(1 << 1); // bit set of bytes each page may show
        const n = 1 + rng.below(6);
        for (0..@intCast(n)) |i| {
            const p = rng.below(4);
            try disk.writePage(p, &filled(@intCast(2 + i)));
            allowed[@intCast(p)] |= @as(u64, 1) << @intCast(2 + i);
        }
        const report = disk.crash(.random);
        try testing.expectEqual(n, report.dropped + report.kept + report.torn);
        try testing.expectEqual(0, disk.pendingCount());
        for (0..4) |p| {
            try disk.readPage(p, &page);
            for (0..sectors_per_page) |s| {
                const sector = page[s * sector_size ..][0..sector_size];
                try testing.expect(std.mem.allEqual(u8, sector, sector[0]));
                try testing.expect(allowed[p] & (@as(u64, 1) << @intCast(sector[0])) != 0);
            }
        }
    }
}

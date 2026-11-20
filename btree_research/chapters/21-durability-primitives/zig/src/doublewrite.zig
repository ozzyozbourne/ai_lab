//! Double write: repairing a torn page with a second copy.
//!
//! A checksum tells us a page is torn; it cannot give the bytes back. The
//! double-write idea (textbook; the best-known user is InnoDB's doublewrite
//! buffer, not one of the code bases studied in this guide) is: keep two
//! copies, and never have both of them in flight (written but not yet synced)
//! at the same time.
//!
//!     update(i, page):
//!       1. write the new image to slot i      then sync
//!       2. write the new image to home i      then sync
//!
//! A crash can tear at most the copy being written, and the other copy is
//! intact: during step 1 the home page still holds the old version; during
//! step 2 the slot already holds the new version, durably.
//!
//!     recover():  for every i
//!       slot ok                  -> home := slot (repairs a torn home page and
//!                                   finishes an update that stopped between
//!                                   the two steps)
//!       slot torn or blank       -> keep home (the update never got past
//!                                   step 1, so home was not touched)
//!
//! After recovery every home page is the old or the new version, never a mix:
//! a single-page write has become atomic. The price is two writes and two
//! syncs per update.
//!
//! `recover` cannot see which copy is newer; "slot ok -> home := slot" is
//! right only because `update` always writes the slot first. It is correct
//! for pages written through `update` and for nothing else: write a home
//! page directly and the next `recover` puts the slot's older image back.
//!
//! Layout, kept deliberately trivial: logical page i has its slot at page i
//! and its home at page `slots + i`. Each copy is sealed for its own address.
const std = @import("std");
const Allocator = std.mem.Allocator;
const page_mod = @import("page.zig");
const storage_mod = @import("storage.zig");
const Storage = storage_mod.Storage;
const Page = storage_mod.Page;
const page_size = storage_mod.page_size;
const sector_size = storage_mod.sector_size;

pub const RecoverReport = struct {
    /// Home was fine and no newer slot existed.
    intact: u32 = 0,
    /// Home was fine but older than the slot: the update is finished.
    rolled_forward: u32 = 0,
    /// Home was torn (or missing) and was rebuilt from the slot.
    restored: u32 = 0,
    /// Neither copy was ever written.
    blank: u32 = 0,
};

pub const DoubleWrite = struct {
    storage: Storage,
    /// Number of logical pages (and of slots).
    slots: u64,

    pub const RecoverError = Storage.Error || error{Unrecoverable};

    pub fn slotPage(self: DoubleWrite, i: u64) u64 {
        std.debug.assert(i < self.slots);
        return i;
    }

    pub fn homePage(self: DoubleWrite, i: u64) u64 {
        std.debug.assert(i < self.slots);
        return self.slots + i;
    }

    /// Atomically replace logical page `i` with `page`'s payload. Seals the
    /// caller's buffer in place (first for the slot, then for home), so no
    /// memory is allocated. Durable when it returns.
    pub fn update(self: DoubleWrite, i: u64, page: *Page) Storage.Error!void {
        page_mod.seal(page, self.slotPage(i));
        try self.storage.writePage(self.slotPage(i), page);
        // This sync is the whole trick: the home page must not be touched
        // until a complete second copy is known to be durable.
        try self.storage.sync();
        page_mod.seal(page, self.homePage(i));
        try self.storage.writePage(self.homePage(i), page);
        try self.storage.sync();
    }

    /// Read logical page `i` from its home and classify it.
    pub fn read(self: DoubleWrite, i: u64, out: *Page) Storage.Error!page_mod.Check {
        return page_mod.readChecked(self.storage, self.homePage(i), out);
    }

    /// Run once after a crash, before anything else touches the pages.
    /// Idempotent: if recovery itself is interrupted, run it again.
    ///
    /// `scratch` provides two page-sized, sector-aligned buffers; a
    /// `FixedBufferAllocator` over `scratch_bytes` bytes of stack is enough.
    pub fn recover(self: DoubleWrite, scratch: Allocator) RecoverError!RecoverReport {
        const sector: std.mem.Alignment = comptime .fromByteUnits(sector_size);
        const slot_buf = try scratch.alignedAlloc(u8, sector, page_size);
        defer scratch.free(slot_buf);
        const home_buf = try scratch.alignedAlloc(u8, sector, page_size);
        defer scratch.free(home_buf);
        const slot: *Page = slot_buf[0..page_size];
        const home: *Page = home_buf[0..page_size];

        var report: RecoverReport = .{};
        for (0..self.slots) |i| {
            const slot_check = try page_mod.readChecked(self.storage, self.slotPage(i), slot);
            const home_check = try page_mod.readChecked(self.storage, self.homePage(i), home);
            if (slot_check == .ok) {
                const same = home_check == .ok and
                    std.mem.eql(u8, slot[0..page_mod.payload_size], home[0..page_mod.payload_size]);
                if (same) {
                    report.intact += 1;
                    continue;
                }
                // The slot is a complete, durable image at least as new as
                // home. Copy it; if this write tears too, the slot is still
                // there for the next recovery.
                page_mod.seal(slot, self.homePage(i));
                try self.storage.writePage(self.homePage(i), slot);
                if (home_check == .ok) report.rolled_forward += 1 else report.restored += 1;
            } else switch (home_check) {
                // The slot write itself was torn or lost: step 2 never
                // started, so home is the complete old version.
                .ok => report.intact += 1,
                .blank => report.blank += 1,
                // Both copies damaged cannot happen under the protocol, which
                // never has both in flight. If it does (bit rot, a bug), say
                // so instead of handing out garbage.
                .corrupt => return error.Unrecoverable,
            }
        }
        try self.storage.sync();
        return report;
    }

    /// Stack bytes that `recover` needs from a FixedBufferAllocator: two
    /// pages plus room to align each to a sector.
    pub const scratch_bytes = 2 * (page_size + sector_size);
};

// ---------------------------------------------------------------------------
const testing = std.testing;
const SimDisk = @import("sim_disk.zig").SimDisk;
const CrashMode = @import("sim_disk.zig").CrashMode;

fn payloadOf(byte: u8) Page {
    return @splat(byte);
}

/// The byte a recovered logical page is filled with, or an error if the page
/// is not a single clean version.
fn versionOf(dw: DoubleWrite, i: u64) !u8 {
    var page: Page = undefined;
    try testing.expectEqual(page_mod.Check.ok, try dw.read(i, &page));
    const payload = page[0..page_mod.payload_size];
    try testing.expect(std.mem.allEqual(u8, payload, payload[0]));
    return payload[0];
}

test "DoubleWrite: update then read, no crash" {
    var disk: SimDisk = .init(testing.allocator, 1);
    defer disk.deinit();
    const dw: DoubleWrite = .{ .storage = disk.storage(), .slots = 2 };
    var page = payloadOf('A');
    try dw.update(1, &page);
    try testing.expectEqual('A', try versionOf(dw, 1));
    try testing.expectEqual(2, disk.stats.writes);
    try testing.expectEqual(2, disk.stats.syncs);

    var buf: [DoubleWrite.scratch_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const report = try dw.recover(fba.allocator());
    try testing.expectEqual(RecoverReport{ .intact = 1, .blank = 1 }, report);
}

test "DoubleWrite: crash at every write, every mode: old or new, never torn" {
    var buf: [DoubleWrite.scratch_bytes]u8 = undefined;
    var saw_old = false;
    var saw_new = false;
    var saw_restore = false;
    for ([_]CrashMode{ .drop, .keep, .tear, .random }) |mode| {
        for (0..3) |crash_after| { // the update issues 2 writes: stop after 0, 1, 2
            for (0..40) |seed| {
                var disk: SimDisk = .init(testing.allocator, seed);
                defer disk.deinit();
                const dw: DoubleWrite = .{ .storage = disk.storage(), .slots = 2 };
                var page = payloadOf('A');
                try dw.update(0, &page); // version A is durable

                disk.powerOffAfterWrites(crash_after);
                page = payloadOf('B');
                const result = dw.update(0, &page);
                try testing.expectError(error.PowerLoss, result); // the final sync never ran
                _ = disk.crash(mode);

                var fba: std.heap.FixedBufferAllocator = .init(&buf);
                const report = try dw.recover(fba.allocator());
                if (report.restored > 0) saw_restore = true;
                const v = try versionOf(dw, 0);
                try testing.expect(v == 'A' or v == 'B');
                if (v == 'A') saw_old = true else saw_new = true;
                // Once the slot is durable (first sync passed) the update must win.
                if (crash_after == 2) try testing.expectEqual('B', v);
                try disk.validate();
            }
        }
    }
    try testing.expect(saw_old and saw_new and saw_restore); // the test exercised all paths
}

test "DoubleWrite: recover on a fresh store whose first update was cut short" {
    // Regression: recovery's own repair write extends size(), and the next
    // slot it reads is then a hole below that pending write.
    var buf: [DoubleWrite.scratch_bytes]u8 = undefined;
    for ([_]CrashMode{ .drop, .keep, .tear, .random }) |mode| {
        for (0..3) |crash_after| {
            var disk: SimDisk = .init(testing.allocator, 1);
            defer disk.deinit();
            const dw: DoubleWrite = .{ .storage = disk.storage(), .slots = 3 };
            var page = payloadOf('A');
            disk.powerOffAfterWrites(crash_after);
            try testing.expectError(error.PowerLoss, dw.update(0, &page));
            _ = disk.crash(mode);

            var fba: std.heap.FixedBufferAllocator = .init(&buf);
            const report = try dw.recover(fba.allocator());
            try testing.expectEqual(3, report.intact + report.rolled_forward + report.restored + report.blank);
            // Logical page 0 is the new version or was never written; the
            // other two were never written.
            var out: Page = undefined;
            const check = try dw.read(0, &out);
            try testing.expect(check == .ok or check == .blank);
            if (crash_after == 2) try testing.expectEqual('A', try versionOf(dw, 0));
            try testing.expectEqual(page_mod.Check.blank, try dw.read(1, &out));
            try testing.expectEqual(page_mod.Check.blank, try dw.read(2, &out));
        }
    }
}

test "DoubleWrite: recovery interrupted by a second crash still converges" {
    var buf: [DoubleWrite.scratch_bytes]u8 = undefined;
    for (0..200) |seed| {
        var disk: SimDisk = .init(testing.allocator, seed);
        defer disk.deinit();
        const dw: DoubleWrite = .{ .storage = disk.storage(), .slots = 1 };
        var page = payloadOf('A');
        try dw.update(0, &page);
        disk.powerOffAfterWrites(2);
        page = payloadOf('B');
        try testing.expectError(error.PowerLoss, dw.update(0, &page));
        _ = disk.crash(.tear); // home page torn, slot holds B

        disk.powerOffAfterWrites(1); // recovery's repair write is accepted, its sync is not
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        try testing.expectError(error.PowerLoss, dw.recover(fba.allocator()));
        _ = disk.crash(.random);

        fba.reset();
        _ = try dw.recover(fba.allocator());
        try testing.expectEqual('B', try versionOf(dw, 0));
    }
}

test "DoubleWrite: seeded oracle over three pages, with crashes and interrupted recoveries" {
    // Model test: 60 seeds x 40 updates of a random logical page. Every
    // update may lose power after 0, 1 or 2 writes, in a random crash mode,
    // and recovery itself may be cut up to three times. After every step all
    // three logical pages must equal the oracle: a crash while page i is being
    // updated never disturbs page j.
    const SplitMix64 = @import("prng.zig").SplitMix64;
    const modes = [_]CrashMode{ .drop, .keep, .tear, .random };
    var buf: [DoubleWrite.scratch_bytes]u8 = undefined;
    var crashes: u32 = 0;
    var interrupted: u32 = 0;
    for (0..60) |seed| {
        var disk: SimDisk = .init(testing.allocator, seed);
        defer disk.deinit();
        const dw: DoubleWrite = .{ .storage = disk.storage(), .slots = 3 };
        var rng: SplitMix64 = .init(seed + 1000);
        var oracle: [3]?u8 = @splat(null); // null = never written
        for (0..40) |step| {
            const i: usize = @intCast(rng.below(3));
            const version: u8 = @intCast(1 + step);
            var page = payloadOf(version);
            const cut = rng.below(4); // 3 = the power stays on
            if (cut < 3) disk.powerOffAfterWrites(cut);
            if (dw.update(i, &page)) |_| {
                try testing.expectEqual(3, cut);
                oracle[i] = version;
            } else |err| {
                try testing.expectEqual(error.PowerLoss, err);
                _ = disk.crash(modes[@intCast(rng.below(4))]);
                crashes += 1;
                var tries: u32 = 0;
                while (true) : (tries += 1) {
                    if (tries < 3 and rng.below(2) == 0) disk.powerOffAfterWrites(rng.below(3));
                    var fba: std.heap.FixedBufferAllocator = .init(&buf);
                    if (dw.recover(fba.allocator())) |_| break else |e| {
                        try testing.expectEqual(error.PowerLoss, e);
                        _ = disk.crash(modes[@intCast(rng.below(4))]);
                        interrupted += 1;
                    }
                }
                // A recovery that needed fewer writes than its budget leaves
                // the power cut armed; disarm it.
                disk.powerOffAfterWrites(std.math.maxInt(u64));
                // Page i is the new version or still the old one, and it is
                // the new one whenever the first sync had passed.
                var out: Page = undefined;
                if (try dw.read(i, &out) == .ok and out[0] == version) {
                    oracle[i] = version;
                } else {
                    try testing.expect(cut < 2);
                }
            }
            for (oracle, 0..) |want, j| {
                if (want) |v| {
                    try testing.expectEqual(v, try versionOf(dw, j));
                } else {
                    var out: Page = undefined;
                    try testing.expectEqual(page_mod.Check.blank, try dw.read(j, &out));
                }
            }
            try disk.validate();
        }
    }
    try testing.expect(crashes > 1000 and interrupted > 100); // the faults really happened
}

test "DoubleWrite: recover trusts the protocol, a home page written directly is rolled back" {
    // Not a feature: this pins down the limit stated at the top of the file.
    // `recover` cannot tell which copy is newer, it assumes the slot is.
    var disk: SimDisk = .init(testing.allocator, 1);
    defer disk.deinit();
    const dw: DoubleWrite = .{ .storage = disk.storage(), .slots = 1 };
    var page = payloadOf('A');
    try dw.update(0, &page);
    page = payloadOf('B');
    page_mod.seal(&page, dw.homePage(0));
    try disk.writePage(dw.homePage(0), &page); // bypasses the slot
    try disk.sync();
    try testing.expectEqual('B', try versionOf(dw, 0));

    var buf: [DoubleWrite.scratch_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const report = try dw.recover(fba.allocator());
    try testing.expectEqual(RecoverReport{ .rolled_forward = 1 }, report);
    try testing.expectEqual('A', try versionOf(dw, 0)); // the durable B is gone
}

test "DoubleWrite: recover reports OutOfMemory when the scratch buffer is too small" {
    var disk: SimDisk = .init(testing.allocator, 1);
    defer disk.deinit();
    const dw: DoubleWrite = .{ .storage = disk.storage(), .slots = 1 };
    var small: [page_size]u8 = undefined; // room for one page, not two
    var fba: std.heap.FixedBufferAllocator = .init(&small);
    try testing.expectError(error.OutOfMemory, dw.recover(fba.allocator()));
    try testing.expectEqual(0, fba.end_index); // the first buffer was given back
}

test "DoubleWrite: both copies damaged is reported, not hidden" {
    var disk: SimDisk = .init(testing.allocator, 1);
    defer disk.deinit();
    const dw: DoubleWrite = .{ .storage = disk.storage(), .slots = 1 };
    const garbage = payloadOf('X'); // never sealed
    try disk.writePage(0, &garbage);
    try disk.writePage(1, &garbage);
    try disk.sync();
    var buf: [DoubleWrite.scratch_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    try testing.expectError(error.Unrecoverable, dw.recover(fba.allocator()));
}

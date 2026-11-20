//! Chapter 21: durability primitives. The demo program.
//!
//! Five small experiments on a simulated disk (seed 2121 for the walk-through):
//!   1. a write is visible immediately but durable only after sync
//!   2. a torn write, and the checksum that catches it
//!   3. the checksum also binds a page to its address
//!   4. double write: a second copy turns "detected" into "repaired"
//!   5. crash at every write, in every mode, for 100 seeds: count the outcomes
//!
//! Demo pages are filled with one letter ('A' = old version, 'B' = new) so a
//! page can be shown as eight characters, one per 512-byte sector.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const storage_mod = @import("storage.zig");
pub const page_mod = @import("page.zig");
pub const sim_disk = @import("sim_disk.zig");
pub const file_storage = @import("file_storage.zig");
pub const doublewrite = @import("doublewrite.zig");

const Storage = storage_mod.Storage;
const Page = storage_mod.Page;
const sector_size = storage_mod.sector_size;
const sectors_per_page = storage_mod.sectors_per_page;
const SimDisk = sim_disk.SimDisk;
const CrashMode = sim_disk.CrashMode;
const DoubleWrite = doublewrite.DoubleWrite;

const demo_seed = 2121;

/// A page whose payload is all `letter`, sealed for `page_no`.
fn sealedPage(letter: u8, page_no: u64) Page {
    var page: Page = @splat(letter);
    page_mod.seal(&page, page_no);
    return page;
}

/// One character per sector: 'A' or 'B' if the sector equals that sector of
/// the sealed A or B image for this address, '.' if it is all zeroes, '?'
/// otherwise.
fn sectorMap(page: *const Page, page_no: u64) [sectors_per_page]u8 {
    var map: [sectors_per_page]u8 = undefined;
    for (&map, 0..) |*c, s| {
        const sector = page[s * sector_size ..][0..sector_size];
        c.* = '?';
        if (std.mem.allEqual(u8, sector, 0)) c.* = '.';
        for ("AB") |letter| {
            const reference = sealedPage(letter, page_no);
            if (std.mem.eql(u8, sector, reference[s * sector_size ..][0..sector_size])) c.* = letter;
        }
    }
    return map;
}

fn printRead(w: *Io.Writer, storage: Storage, page_no: u64) !void {
    var page: Page = undefined;
    storage.readPage(page_no, &page) catch |err| switch (err) {
        error.OutOfBounds => {
            try w.print("read  page {d} -> out of bounds (size={d})\n", .{ page_no, storage.size() });
            return;
        },
        else => return err,
    };
    try w.print("read  page {d} -> {s} {t}\n", .{ page_no, sectorMap(&page, page_no), page_mod.verify(&page, page_no) });
}

fn printCrash(w: *Io.Writer, disk: *SimDisk, mode: CrashMode) !void {
    const r = disk.crash(mode);
    try w.print("crash({t}): dropped={d} kept={d} torn={d}\n", .{ mode, r.dropped, r.kept, r.torn });
}

/// The naive update: overwrite the page where it lives.
fn updateInPlace(storage: Storage, page_no: u64, page: *Page) Storage.Error!void {
    page_mod.seal(page, page_no);
    try storage.writePage(page_no, page);
    try storage.sync();
}

const Outcome = struct { old: u32 = 0, new: u32 = 0, corrupt: u32 = 0 };

fn count(outcome: *Outcome, check: page_mod.Check, page: *const Page) void {
    if (check != .ok) {
        outcome.corrupt += 1;
    } else if (page[0] == 'A') {
        outcome.old += 1;
    } else {
        outcome.new += 1;
    }
}

const modes = [_]CrashMode{ .drop, .keep, .tear, .random };
const seeds_per_cell = 100;

/// Experiment 5a: page 0 holds A durably; overwrite it with B in place, lose
/// power after `crash_after` writes, crash in every mode, look at the page.
fn inPlaceOutcomes(gpa: Allocator, crash_after: u64) !Outcome {
    var outcome: Outcome = .{};
    for (modes) |mode| {
        for (0..seeds_per_cell) |seed| {
            var disk: SimDisk = .init(gpa, seed);
            defer disk.deinit();
            const storage = disk.storage();
            var page: Page = @splat('A');
            try updateInPlace(storage, 0, &page);

            disk.powerOffAfterWrites(crash_after);
            page = @splat('B');
            updateInPlace(storage, 0, &page) catch |err| switch (err) {
                error.PowerLoss => {},
                else => return err,
            };
            _ = disk.crash(mode);
            const check = try page_mod.readChecked(storage, 0, &page);
            count(&outcome, check, &page);
        }
    }
    return outcome;
}

/// Experiment 5b: the same, through DoubleWrite, looking after `recover`.
fn doubleWriteOutcomes(gpa: Allocator, crash_after: u64) !Outcome {
    var outcome: Outcome = .{};
    // Recovery's two page buffers come from this stack buffer: recovery needs
    // a fixed, known amount of memory and must not fail half way for lack of it.
    var scratch_buf: [DoubleWrite.scratch_bytes]u8 = undefined;
    for (modes) |mode| {
        for (0..seeds_per_cell) |seed| {
            var disk: SimDisk = .init(gpa, seed);
            defer disk.deinit();
            const dw: DoubleWrite = .{ .storage = disk.storage(), .slots = 1 };
            var page: Page = @splat('A');
            try dw.update(0, &page);

            disk.powerOffAfterWrites(crash_after);
            page = @splat('B');
            dw.update(0, &page) catch |err| switch (err) {
                error.PowerLoss => {},
                else => return err,
            };
            _ = disk.crash(mode);
            var fba: std.heap.FixedBufferAllocator = .init(&scratch_buf);
            _ = try dw.recover(fba.allocator());
            const check = try dw.read(0, &page);
            count(&outcome, check, &page);
        }
    }
    return outcome;
}

pub fn run(gpa: Allocator, w: *Io.Writer) !void {
    try w.writeAll("Chapter 21: durability primitives\n");
    try w.writeAll("page = 4096 bytes = 8 sectors of 512; one letter per sector; SimDisk seed 2121\n");

    // ---- 1 and 2 share one disk ----
    var disk: SimDisk = .init(gpa, demo_seed);
    defer disk.deinit();
    const storage = disk.storage();

    try w.writeAll("\n== 1. A write is not durable until sync ==\n");
    var page = sealedPage('A', 0);
    try storage.writePage(0, &page);
    try w.print("write page 0 = A: pending={d} durable_pages={d}\n", .{ disk.pendingCount(), disk.durablePages() });
    try printRead(w, storage, 0);
    try printCrash(w, &disk, .drop);
    try printRead(w, storage, 0);
    try storage.writePage(0, &page);
    try storage.sync();
    try w.print("write page 0 = A, sync: pending={d} durable_pages={d}\n", .{ disk.pendingCount(), disk.durablePages() });
    try printCrash(w, &disk, .drop);
    try printRead(w, storage, 0);

    try w.writeAll("\n== 2. A torn write, caught by the checksum ==\n");
    page = sealedPage('B', 0);
    try storage.writePage(0, &page);
    try w.print("write page 0 = B: pending={d} durable_pages={d}\n", .{ disk.pendingCount(), disk.durablePages() });
    try printRead(w, storage, 0);
    try printCrash(w, &disk, .tear);
    try printRead(w, storage, 0);
    try storage.readPage(0, &page);
    try w.print("checksum: stored={x:0>8} computed={x:0>8}\n", .{ page_mod.storedChecksum(&page), page_mod.checksum(&page, 0) });

    try w.writeAll("\n== 3. The checksum binds a page to its address ==\n");
    page = sealedPage('A', 0);
    try w.print("page sealed for address 0: checksum={x:0>8}\n", .{page_mod.storedChecksum(&page)});
    try w.print("verified at address 0: {t}\n", .{page_mod.verify(&page, 0)});
    try w.print("verified at address 1: {t} (expected checksum {x:0>8})\n", .{ page_mod.verify(&page, 1), page_mod.checksum(&page, 1) });

    try w.writeAll("\n== 4. Double write: a second copy makes repair possible ==\n");
    {
        var disk2: SimDisk = .init(gpa, demo_seed);
        defer disk2.deinit();
        const dw: DoubleWrite = .{ .storage = disk2.storage(), .slots = 1 };
        try w.print("layout: slot = page {d}, home = page {d}\n", .{ dw.slotPage(0), dw.homePage(0) });
        page = @splat('A');
        try dw.update(0, &page);
        try w.print("update to A: writes={d} syncs={d}\n", .{ disk2.stats.writes, disk2.stats.syncs });
        disk2.powerOffAfterWrites(2);
        page = @splat('B');
        if (dw.update(0, &page)) |_| {
            try w.writeAll("update to B: ok\n");
        } else |err| {
            try w.print("update to B, power off after 2 writes: {t}\n", .{err});
        }
        try printCrash(w, &disk2, .tear);
        try printRead(w, dw.storage, 0);
        try printRead(w, dw.storage, 1);
        var scratch_buf: [DoubleWrite.scratch_bytes]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&scratch_buf);
        const r = try dw.recover(fba.allocator());
        try w.print("recover: intact={d} rolled_forward={d} restored={d} blank={d}\n", .{ r.intact, r.rolled_forward, r.restored, r.blank });
        try printRead(w, dw.storage, 1);
    }

    try w.writeAll("\n== 5. Crash at every write: 4 crash modes x 100 seeds per line ==\n");
    try w.writeAll("in-place update (1 write, 1 sync):\n");
    for (0..2) |crash_after| {
        const o = try inPlaceOutcomes(gpa, crash_after);
        try w.print("  power off after {d} writes: old={d} new={d} corrupt={d}\n", .{ crash_after, o.old, o.new, o.corrupt });
    }
    try w.writeAll("double write (2 writes, 2 syncs), after recover:\n");
    for (0..3) |crash_after| {
        const o = try doubleWriteOutcomes(gpa, crash_after);
        try w.print("  power off after {d} writes: old={d} new={d} corrupt={d}\n", .{ crash_after, o.old, o.new, o.corrupt });
    }
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout: *Io.Writer = &stdout_file_writer.interface;
    try run(init.gpa, stdout);
    try stdout.flush();
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "run prints exactly expected_output.txt" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try run(testing.allocator, &aw.writer);
    try testing.expectEqualStrings(@embedFile("expected_output"), aw.written());
}

test "in place: a torn overwrite is detected but the page is gone" {
    var disk: SimDisk = .init(testing.allocator, demo_seed);
    defer disk.deinit();
    const storage = disk.storage();
    var page: Page = @splat('A');
    try updateInPlace(storage, 0, &page);
    disk.powerOffAfterWrites(1);
    page = @splat('B');
    try testing.expectError(error.PowerLoss, updateInPlace(storage, 0, &page));
    _ = disk.crash(.tear);
    try testing.expectEqual(page_mod.Check.corrupt, try page_mod.readChecked(storage, 0, &page));
    // Neither version can be reconstructed: every sector is A or B, but
    // nothing on the disk says which sectors to trust.
    const map = sectorMap(&page, 0);
    try testing.expect(std.mem.indexOfScalar(u8, &map, 'A') != null);
    try testing.expect(std.mem.indexOfScalar(u8, &map, 'B') != null);
}

test "the same code runs on SimDisk and on a real file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var file: file_storage.FileStorage = try .open(testing.io, tmp.dir, "dw.db");
    defer file.close();
    var disk: SimDisk = .init(testing.allocator, 1);
    defer disk.deinit();

    var scratch_buf: [DoubleWrite.scratch_bytes]u8 = undefined;
    for ([_]Storage{ file.storage(), disk.storage() }) |storage| {
        const dw: DoubleWrite = .{ .storage = storage, .slots = 3 };
        var page: Page = @splat('A');
        try dw.update(2, &page);
        page = @splat('B');
        try dw.update(0, &page);
        var fba: std.heap.FixedBufferAllocator = .init(&scratch_buf);
        const report = try dw.recover(fba.allocator());
        try testing.expectEqual(doublewrite.RecoverReport{ .intact = 2, .blank = 1 }, report);
        try testing.expectEqual(6, storage.size());
    }
    // Byte for byte the same image on both.
    var a: Page = undefined;
    var b: Page = undefined;
    for (0..6) |p| {
        try file.storage().readPage(p, &a);
        try disk.storage().readPage(p, &b);
        try testing.expectEqualSlices(u8, &a, &b);
    }
}

test "SimDisk and FileStorage answer every call alike" {
    // One random stream of writes, reads and syncs against both
    // implementations of `Storage`: every result, error and size must agree.
    // (No crashes: a real file cannot be crashed from a test.)
    const SplitMix64 = @import("prng.zig").SplitMix64;
    const pages = 12;
    for (0..20) |seed| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var file: file_storage.FileStorage = try .open(testing.io, tmp.dir, "diff.db");
        defer file.close();
        var disk: SimDisk = .init(testing.allocator, seed);
        defer disk.deinit();
        const f = file.storage();
        const d = disk.storage();

        var rng: SplitMix64 = .init(seed);
        var a: Page = undefined;
        var b: Page = undefined;
        for (0..150) |_| {
            const p = rng.below(pages);
            switch (rng.below(8)) {
                0...2 => {
                    const page: Page = @splat(@intCast(1 + rng.below(255)));
                    try f.writePage(p, &page);
                    try d.writePage(p, &page);
                },
                3...6 => {
                    const from_file = f.readPage(p, &a);
                    const from_disk = d.readPage(p, &b);
                    try testing.expectEqual(from_file, from_disk);
                    if (from_file) |_| {
                        try testing.expectEqualSlices(u8, &a, &b);
                    } else |err| {
                        try testing.expectEqual(error.OutOfBounds, err);
                        try testing.expect(p >= f.size());
                    }
                },
                else => {
                    try f.sync();
                    try d.sync();
                },
            }
            try testing.expectEqual(f.size(), d.size());
        }
    }
    // Both refuse a page number beyond their own limit and change nothing.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var file: file_storage.FileStorage = try .open(testing.io, tmp.dir, "limit.db");
    defer file.close();
    var disk: SimDisk = .init(testing.allocator, 1);
    defer disk.deinit();
    const page: Page = @splat('A');
    try testing.expectError(error.OutOfBounds, file.storage().writePage(file_storage.FileStorage.max_pages, &page));
    try testing.expectError(error.OutOfBounds, disk.storage().writePage(SimDisk.max_pages, &page));
    try testing.expectEqual(0, file.storage().size());
    try testing.expectEqual(0, disk.storage().size());
}

test {
    // Reach the tests of every file (see common/README.md).
    _ = storage_mod;
    _ = page_mod;
    _ = sim_disk;
    _ = file_storage;
    _ = doublewrite;
    _ = @import("prng.zig");
    _ = @import("crc32.zig");
}

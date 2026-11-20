//! machine.zig: two files on one simulated computer, with one power switch.
//!
//! A database with a write-ahead log has two files: the main file (the tree's
//! pages) and the log. Chapter 21's `SimDisk` simulates ONE file that can lose
//! power. A `Machine` owns two of them and gives them a common power supply:
//!
//!   powerOffAfterWrites(n)   n more page writes succeed, counted over BOTH
//!                            files; after that every call on either file
//!                            fails with error.PowerLoss
//!   crash(mode)              each file decides the fate of its unsynced
//!                            writes (drop, keep, tear, random), then the
//!                            power is back on
//!
//! `mainStorage()` and `logStorage()` hand out chapter 21's `Storage`
//! interface, so everything written against it (the checksummed pages, the
//! log, the adapter of adapter.zig) runs on the machine unchanged.
//!
//! The machine can also record a trace of every write and sync. The demo
//! prints it, and the visualization replays it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const page_storage = @import("base_page_storage.zig");
const Storage = page_storage.Storage;
const Page = page_storage.Page;
const sim = @import("base_sim_disk.zig");
const SimDisk = sim.SimDisk;
pub const CrashMode = sim.CrashMode;

pub const FileId = enum { main, log };

pub const Event = struct {
    file: FileId,
    kind: enum { write, sync },
    /// The page written; 0 for a sync.
    page_no: u64 = 0,
};

pub const Machine = struct {
    gpa: Allocator,
    main: SimDisk,
    log: SimDisk,
    /// null = power stays on. n = that many more writes succeed.
    writes_left: ?u64 = null,
    /// Page writes accepted so far, on both files together. This is the
    /// clock of the crash loop: "crash after write number N".
    writes: u64 = 0,
    tracing: bool = false,
    trace: std.ArrayList(Event) = .empty,

    /// The two disks draw their crash randomness from different streams
    /// derived from one seed, so a run is reproduced by that seed.
    pub fn init(gpa: Allocator, seed: u64) Machine {
        return .{ .gpa = gpa, .main = .init(gpa, seed), .log = .init(gpa, seed ^ 0x9E3779B97F4A7C15) };
    }

    pub fn deinit(self: *Machine) void {
        self.trace.deinit(self.gpa);
        self.main.deinit();
        self.log.deinit();
        self.* = undefined;
    }

    /// The interface values. The machine must outlive them and must not move.
    pub fn mainStorage(self: *Machine) Storage {
        return .{ .ptr = self, .vtable = &Port(.main).vtable };
    }

    pub fn logStorage(self: *Machine) Storage {
        return .{ .ptr = self, .vtable = &Port(.log).vtable };
    }

    pub fn disk(self: *Machine, file: FileId) *SimDisk {
        return switch (file) {
            .main => &self.main,
            .log => &self.log,
        };
    }

    pub fn powerOffAfterWrites(self: *Machine, n: u64) void {
        self.writes_left = n;
        if (n == 0) self.cutPower();
    }

    pub fn isPoweredOff(self: *const Machine) bool {
        return self.main.isPoweredOff();
    }

    /// Power cut and reboot of both files.
    pub fn crash(self: *Machine, mode: CrashMode) void {
        _ = self.main.crash(mode);
        _ = self.log.crash(mode);
        self.writes_left = null;
    }

    fn cutPower(self: *Machine) void {
        self.main.powerOffAfterWrites(0);
        self.log.powerOffAfterWrites(0);
    }

    fn record(self: *Machine, event: Event) Storage.Error!void {
        if (self.tracing) try self.trace.append(self.gpa, event);
    }

    /// The four `Storage` functions for one of the two files. `comptime file`
    /// makes two copies of this struct, each with its own vtable.
    fn Port(comptime file: FileId) type {
        return struct {
            const vtable: Storage.VTable = .{ .readPage = readPage, .writePage = writePage, .sync = sync, .size = size };

            fn readPage(ptr: *anyopaque, page_no: u64, out: *Page) Storage.Error!void {
                const m: *Machine = @ptrCast(@alignCast(ptr));
                return m.disk(file).readPage(page_no, out);
            }

            fn writePage(ptr: *anyopaque, page_no: u64, page: *const Page) Storage.Error!void {
                const m: *Machine = @ptrCast(@alignCast(ptr));
                try m.record(.{ .file = file, .kind = .write, .page_no = page_no });
                errdefer if (m.tracing) {
                    _ = m.trace.pop();
                };
                try m.disk(file).writePage(page_no, page);
                m.writes += 1;
                if (m.writes_left) |*left| {
                    left.* -= 1;
                    // The write that used up the budget still succeeded; the
                    // power fails right after it, for both files.
                    if (left.* == 0) m.cutPower();
                }
            }

            fn sync(ptr: *anyopaque) Storage.Error!void {
                const m: *Machine = @ptrCast(@alignCast(ptr));
                try m.disk(file).sync();
                try m.record(.{ .file = file, .kind = .sync });
            }

            fn size(ptr: *anyopaque) u64 {
                const m: *Machine = @ptrCast(@alignCast(ptr));
                return m.disk(file).size();
            }
        };
    }
};

// ---------------------------------------------------------------------------
const testing = std.testing;

test "one power switch for two files" {
    var m: Machine = .init(testing.allocator, 1);
    defer m.deinit();
    const main = m.mainStorage();
    const log = m.logStorage();
    const page: Page = @splat('x');

    m.powerOffAfterWrites(2);
    try log.writePage(0, &page);
    try log.sync();
    try main.writePage(0, &page); // the second write still succeeds
    try testing.expect(m.isPoweredOff());
    try testing.expectError(error.PowerLoss, main.sync());
    try testing.expectError(error.PowerLoss, log.writePage(1, &page));
    var out: Page = undefined;
    try testing.expectError(error.PowerLoss, log.readPage(0, &out));
    try testing.expectEqual(2, m.writes);

    m.crash(.drop);
    try log.readPage(0, &out); // synced before the power cut: still there
    try testing.expectEqualSlices(u8, &page, &out);
    try testing.expectEqual(0, main.size()); // never synced: gone
}

test "the trace lists writes and syncs in order" {
    var m: Machine = .init(testing.allocator, 1);
    defer m.deinit();
    m.tracing = true;
    const page: Page = @splat(0);
    try m.logStorage().writePage(3, &page);
    try m.logStorage().sync();
    try m.mainStorage().writePage(1, &page);
    try testing.expectEqual(3, m.trace.items.len);
    try testing.expectEqual(Event{ .file = .log, .kind = .write, .page_no = 3 }, m.trace.items[0]);
    try testing.expectEqual(Event{ .file = .log, .kind = .sync }, m.trace.items[1]);
    try testing.expectEqual(Event{ .file = .main, .kind = .write, .page_no = 1 }, m.trace.items[2]);
}

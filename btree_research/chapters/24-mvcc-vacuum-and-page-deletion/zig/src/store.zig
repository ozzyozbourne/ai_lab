//! The version store ("the heap"): row versions, the transaction counter and
//! the list of open snapshots. Visibility is decided HERE, outside the index;
//! the index only stores (user key, tid) pairs that point into this store.
//!
//! The whole MVCC model of the chapter is three rules:
//!
//!   1. Every write is a transaction and gets the next number from one
//!      counter (`now`). The same counter serves as the EPOCH that page
//!      deletion stamps on a page.
//!   2. A row version records the transaction that created it (`xmin`) and
//!      the one that deleted or replaced it (`xmax`, 0 = nobody yet).
//!   3. A snapshot is the value of the counter when the reader started.
//!      It sees a version iff  xmin <= snapshot  and  (xmax == 0 or xmax > snapshot).
//!
//! Simplification, stated once: every transaction here commits at once and
//! none aborts, so "xid <= snapshot" is the whole visibility test. A real
//! system also has to ask whether xmin / xmax committed, aborted or are still
//! running.
const std = @import("std");
const assert = std.debug.assert;
const arena = @import("base_arena.zig");

/// Tuple id: handle of a row version. Slots are reused after VACUUM frees
/// them, which is why an index entry must be gone BEFORE its version is freed.
pub const Tid = arena.NodeId;

pub const Version = struct {
    key: u64,
    value: u64,
    xmin: u64,
    xmax: u64 = 0,

    pub fn visible(self: *const Version, snapshot: u64) bool {
        return self.xmin <= snapshot and (self.xmax == 0 or self.xmax > snapshot);
    }
};

pub const max_snapshots = 16;

pub const Store = struct {
    versions: arena.Arena(Version) = .empty,
    /// Last transaction id handed out. Also the current epoch.
    now: u64 = 0,
    /// Open snapshots, in no particular order (a small multiset).
    open: [max_snapshots]u64 = undefined,
    open_len: usize = 0,

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        self.versions.deinit(gpa);
    }

    /// Starts (and, in this model, immediately commits) a transaction.
    pub fn tick(self: *Store) u64 {
        self.now += 1;
        return self.now;
    }

    /// A reader registers its snapshot so that garbage collection knows which
    /// old versions and which deleted pages somebody may still need.
    pub fn openSnapshot(self: *Store) error{TooManySnapshots}!u64 {
        if (self.open_len == max_snapshots) return error.TooManySnapshots;
        self.open[self.open_len] = self.now;
        self.open_len += 1;
        return self.now;
    }

    pub fn closeSnapshot(self: *Store, snapshot: u64) void {
        const i = std.mem.findScalar(u64, self.open[0..self.open_len], snapshot).?;
        self.open_len -= 1;
        self.open[i] = self.open[self.open_len];
    }

    pub fn isOpen(self: *const Store, snapshot: u64) bool {
        return std.mem.findScalar(u64, self.open[0..self.open_len], snapshot) != null;
    }

    /// The oldest snapshot anybody holds; `now` if nobody holds one, because
    /// every future snapshot will be >= now. Everything garbage collection
    /// does is justified by comparing against this number.
    pub fn horizon(self: *const Store) u64 {
        var h = self.now;
        for (self.open[0..self.open_len]) |s| h = @min(h, s);
        return h;
    }

    /// Dead to everyone: deleted at or before the horizon, so no open and no
    /// future snapshot can see it. (Compare with `visible`: xmax <= horizon
    /// <= snapshot fails the second half of the test for every snapshot.)
    pub fn deadToAll(self: *const Store, tid: Tid) bool {
        const v = self.versions.get(tid);
        return v.xmax != 0 and v.xmax <= self.horizon();
    }
};

test "visibility is two comparisons" {
    const v: Version = .{ .key = 1, .value = 1, .xmin = 5, .xmax = 9 };
    try std.testing.expect(!v.visible(4)); // created later
    try std.testing.expect(v.visible(5));
    try std.testing.expect(v.visible(8));
    try std.testing.expect(!v.visible(9)); // deleted by then
    const live: Version = .{ .key = 1, .value = 1, .xmin = 5 };
    try std.testing.expect(live.visible(1000));
}

test "the horizon is the oldest open snapshot, or now" {
    var s: Store = .{};
    _ = s.tick();
    _ = s.tick();
    try std.testing.expectEqual(2, s.horizon());
    const a = try s.openSnapshot(); // 2
    _ = s.tick();
    const b = try s.openSnapshot(); // 3
    _ = s.tick();
    try std.testing.expectEqual(2, s.horizon());
    s.closeSnapshot(a);
    try std.testing.expectEqual(3, s.horizon());
    s.closeSnapshot(b);
    try std.testing.expectEqual(4, s.horizon());
    for (0..max_snapshots) |_| _ = try s.openSnapshot();
    try std.testing.expectError(error.TooManySnapshots, s.openSnapshot());
}

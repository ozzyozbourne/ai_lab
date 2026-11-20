//! A counted block device: no bytes, only arithmetic.
//!
//! Both structures of this chapter "store" their data on one of these. The
//! device never holds a byte; it only counts how many blocks would have been
//! read, written and allocated if the structure lived on a disk. That is all
//! the three amplification factors need.
//!
//! The rules are the same for both structures, and deliberately harsh:
//!   * NOTHING is cached between operations. Every operation reads each block
//!     it looks at from the device and writes each block it changed back
//!     before it returns. (Real engines put a buffer pool in between; chapter
//!     09. The counters split index blocks from data blocks so that you can
//!     see what a cache holding all the index blocks would save.)
//!   * Within ONE operation a block is read at most once and written at most
//!     once, however often the code touches it: that is the `pin` table.
//!   * Sequential work that streams over many blocks (a scan walking the leaf
//!     chain, a compaction) uses `read` / `write` directly.
//!   * There is no write-ahead log in the model, for either structure.
const std = @import("std");
const assert = std.debug.assert;

/// What a block holds. The B+tree's internal nodes and the LSM's index blocks
/// are `index`; B+tree leaves and LSM data blocks are `data`.
pub const Kind = enum(u1) { index, data };

pub const Counters = struct {
    /// Indexed by `@intFromEnum(Kind)`.
    reads: [2]u64 = .{ 0, 0 },
    writes: [2]u64 = .{ 0, 0 },

    pub fn totalReads(self: Counters) u64 {
        return self.reads[0] + self.reads[1];
    }

    pub fn totalWrites(self: Counters) u64 {
        return self.writes[0] + self.writes[1];
    }

    /// `self - earlier`: what happened between two snapshots.
    pub fn since(self: Counters, earlier: Counters) Counters {
        return .{
            .reads = .{ self.reads[0] - earlier.reads[0], self.reads[1] - earlier.reads[1] },
            .writes = .{ self.writes[0] - earlier.writes[0], self.writes[1] - earlier.writes[1] },
        };
    }

    pub fn add(self: *Counters, other: Counters) void {
        for (0..2) |i| {
            self.reads[i] += other.reads[i];
            self.writes[i] += other.writes[i];
        }
    }
};

/// Most blocks one B+tree operation can hold at once: per level the node, a
/// new or examined sibling or two, plus a leaf-chain neighbour and a new root.
/// A tree of order >= 3 with 2^32 nodes has fewer than 32 levels.
pub const max_pins = 128;

const Pin = struct { id: u32, kind: Kind, dirty: bool };

pub const Device = struct {
    counters: Counters = .{},
    /// Blocks allocated right now, and the most there have ever been.
    live: u64 = 0,
    peak: u64 = 0,
    /// Blocks held by the operation in progress (fixed buffer, no allocator).
    pins: [max_pins]Pin = undefined,
    pin_count: usize = 0,

    // ------------------------------------------------------ space

    pub fn allocBlocks(self: *Device, n: u64) void {
        self.live += n;
        self.peak = @max(self.peak, self.live);
    }

    pub fn freeBlocks(self: *Device, n: u64) void {
        assert(n <= self.live);
        self.live -= n;
    }

    // ------------------------------------------------- streaming I/O

    pub fn read(self: *Device, kind: Kind, n: u64) void {
        self.counters.reads[@intFromEnum(kind)] += n;
    }

    pub fn write(self: *Device, kind: Kind, n: u64) void {
        self.counters.writes[@intFromEnum(kind)] += n;
    }

    // ------------------------------------- per-operation pinned blocks

    fn findPin(self: *Device, id: usize) ?*Pin {
        for (self.pins[0..self.pin_count]) |*p| {
            if (p.id == id) return p;
        }
        return null;
    }

    /// The operation looks at block `id`. Costs one read the first time.
    pub fn pin(self: *Device, id: usize, kind: Kind) void {
        if (self.findPin(id) != null) return;
        self.read(kind, 1);
        self.pins[self.pin_count] = .{ .id = @intCast(id), .kind = kind, .dirty = false };
        self.pin_count += 1;
    }

    /// The operation created block `id`: nothing to read, but it must be
    /// written. Also accounts for the space.
    pub fn pinNew(self: *Device, id: usize, kind: Kind) void {
        assert(self.findPin(id) == null);
        self.allocBlocks(1);
        self.pins[self.pin_count] = .{ .id = @intCast(id), .kind = kind, .dirty = true };
        self.pin_count += 1;
    }

    /// The operation changed block `id` (which it must have pinned).
    pub fn markDirty(self: *Device, id: usize) void {
        self.findPin(id).?.dirty = true;
    }

    /// The operation freed block `id`. A freed block is never written, even
    /// if it was changed first.
    pub fn release(self: *Device, id: usize) void {
        self.freeBlocks(1);
        const p = self.findPin(id) orelse return;
        self.pin_count -= 1;
        p.* = self.pins[self.pin_count];
    }

    /// End of the operation: every dirty block is written exactly once.
    pub fn endOp(self: *Device) void {
        for (self.pins[0..self.pin_count]) |p| {
            if (p.dirty) self.write(p.kind, 1);
        }
        self.pin_count = 0;
    }
};

test "a block is read once and written once per operation" {
    var dev: Device = .{};
    dev.pin(7, .index);
    dev.pin(9, .data);
    dev.pin(7, .index); // already held: free
    dev.markDirty(9);
    dev.markDirty(9);
    dev.pinNew(12, .data); // fresh block: no read, one write
    try std.testing.expectEqual(2, dev.counters.totalReads());
    try std.testing.expectEqual(0, dev.counters.totalWrites()); // not yet
    dev.endOp();
    try std.testing.expectEqual([2]u64{ 1, 1 }, dev.counters.reads);
    try std.testing.expectEqual([2]u64{ 0, 2 }, dev.counters.writes);
    try std.testing.expectEqual(1, dev.live);

    // The next operation pays again: nothing is cached.
    dev.pin(7, .index);
    dev.endOp();
    try std.testing.expectEqual(3, dev.counters.totalReads());
}

test "a freed block is not written, and peak remembers the high-water mark" {
    var dev: Device = .{};
    dev.pinNew(1, .data);
    dev.pinNew(2, .data);
    dev.endOp();
    dev.pin(2, .data);
    dev.markDirty(2);
    dev.release(2);
    dev.endOp();
    try std.testing.expectEqual(2, dev.counters.totalWrites());
    try std.testing.expectEqual(1, dev.live);
    try std.testing.expectEqual(2, dev.peak);

    const before = dev.counters;
    dev.read(.data, 5);
    dev.write(.index, 2);
    const delta = dev.counters.since(before);
    try std.testing.expectEqual(5, delta.totalReads());
    try std.testing.expectEqual(2, delta.writes[@intFromEnum(Kind.index)]);
}

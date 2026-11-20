//! A sorted run: the immutable, on-device half of an LSM-tree.
//!
//! A run is a sorted sequence of slots cut into DATA BLOCKS of
//! `block_entries` slots, plus INDEX BLOCKS that hold the first key of each
//! data block (`index_fanout` of them per index block). That is a static,
//! bulk-loaded, 100% full B+tree that is never updated in place.
//!
//! What is on the device and what is in RAM:
//!   device  data blocks and index blocks (counted when read or written)
//!   RAM     the "manifest": per run its smallest and largest key, and which
//!           index block covers which key range. Tiny, so not counted.
//! A point lookup into a run therefore costs 1 index block + 1 data block.
//!
//! The model keeps a run's slots in one array; block j is simply
//! slots[j * block_entries ..][0..block_entries].
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Device = @import("device.zig").Device;
pub const Lookup = @import("memtable.zig").Lookup;

/// One entry of a run or of the memtable. `value == null` is a tombstone.
pub const Slot = struct { key: u64, value: ?u64 };

/// How slots map to blocks. Shared by every run of one LSM-tree.
pub const Geometry = struct {
    /// Slots per data block. The chapter sets this to M - 1, the capacity of
    /// a B+tree leaf of order M, so both structures have the same block size.
    block_entries: usize,
    /// First-keys per index block. Set to M, the fan-out of an internal node.
    index_fanout: usize,

    pub fn dataBlocks(self: Geometry, slots: usize) usize {
        return std.math.divCeil(usize, slots, self.block_entries) catch unreachable;
    }

    pub fn indexBlocks(self: Geometry, slots: usize) usize {
        return std.math.divCeil(usize, self.dataBlocks(slots), self.index_fanout) catch unreachable;
    }

    pub fn blocks(self: Geometry, slots: usize) usize {
        return self.dataBlocks(slots) + self.indexBlocks(slots);
    }
};

/// Largest `block_entries` a builder's block buffer can hold.
pub const max_block_entries = 64;

pub const Run = struct {
    /// Strictly ascending keys; never empty; never modified after `finish`.
    slots: std.ArrayList(Slot),
    /// Manifest metadata, kept in RAM: lets a lookup skip the whole run
    /// without touching the device.
    min_key: u64,
    max_key: u64,

    pub fn deinit(self: *Run, gpa: Allocator) void {
        self.slots.deinit(gpa);
    }

    pub fn len(self: *const Run) usize {
        return self.slots.items.len;
    }

    pub fn mayContain(self: *const Run, key: u64) bool {
        return self.min_key <= key and key <= self.max_key;
    }

    /// Does the run have any key in [lo, hi)?  (As far as min/max can tell.)
    pub fn overlaps(self: *const Run, lo: u64, hi: u64) bool {
        return lo < hi and self.min_key < hi and lo <= self.max_key;
    }

    /// Index of the first slot with key >= `key`.
    pub fn lowerBound(self: *const Run, key: u64) usize {
        var lo: usize = 0;
        var hi: usize = self.slots.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.slots.items[mid].key < key) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Looks the key up, assuming the caller already paid for the blocks.
    pub fn find(self: *const Run, key: u64) Lookup {
        const i = self.lowerBound(key);
        if (i == self.len() or self.slots.items[i].key != key) return .absent;
        return if (self.slots.items[i].value) |v| .{ .value = v } else .tombstone;
    }
};

/// Writes a run from slots that arrive in ascending key order.
///
/// The builder owns ONE block-sized buffer. Slots collect there and leave for
/// the device a whole block at a time; that buffer is all the memory a flush
/// or a compaction needs on its output side, however large the run gets.
pub const Builder = struct {
    geo: Geometry,
    slots: std.ArrayList(Slot),
    block: [max_block_entries]Slot = undefined,
    block_len: usize = 0,

    /// `max_slots` is an upper bound on what will be appended (the sum of the
    /// inputs). Reserving it here is the builder's ONLY allocation, so a merge
    /// that got this far cannot fail half-way through.
    pub fn init(gpa: Allocator, geo: Geometry, max_slots: usize) Allocator.Error!Builder {
        assert(geo.block_entries >= 1 and geo.block_entries <= max_block_entries);
        assert(geo.index_fanout >= 2);
        return .{ .geo = geo, .slots = try .initCapacity(gpa, max_slots) };
    }

    pub fn append(self: *Builder, dev: *Device, slot: Slot) void {
        self.block[self.block_len] = slot;
        self.block_len += 1;
        if (self.block_len == self.geo.block_entries) self.writeBlock(dev);
    }

    fn writeBlock(self: *Builder, dev: *Device) void {
        if (self.slots.items.len > 0) {
            // Invariant: a run is strictly ascending across block borders too.
            assert(self.slots.items[self.slots.items.len - 1].key < self.block[0].key);
        }
        self.slots.appendSliceAssumeCapacity(self.block[0..self.block_len]);
        self.block_len = 0;
        dev.allocBlocks(1);
        dev.write(.data, 1);
    }

    /// Writes the last partial block and the index blocks. Returns null (and
    /// frees everything) if nothing was appended: there is no empty run.
    pub fn finish(self: *Builder, gpa: Allocator, dev: *Device) ?Run {
        if (self.block_len > 0) self.writeBlock(dev);
        const items = self.slots.items;
        if (items.len == 0) {
            self.slots.deinit(gpa);
            return null;
        }
        const index_blocks = self.geo.indexBlocks(items.len);
        dev.allocBlocks(index_blocks);
        dev.write(.index, index_blocks);
        return .{ .slots = self.slots, .min_key = items[0].key, .max_key = items[items.len - 1].key };
    }
};

test "geometry: slots to blocks" {
    const g: Geometry = .{ .block_entries = 3, .index_fanout = 4 };
    try std.testing.expectEqual(1, g.dataBlocks(1));
    try std.testing.expectEqual(1, g.dataBlocks(3));
    try std.testing.expectEqual(2, g.dataBlocks(4));
    try std.testing.expectEqual(1, g.indexBlocks(12)); // 4 data blocks: one index block
    try std.testing.expectEqual(2, g.indexBlocks(13)); // 5 data blocks: two
    try std.testing.expectEqual(7, g.blocks(13));
}

test "builder writes whole blocks, then the index; run answers lookups" {
    const gpa = std.testing.allocator;
    const g: Geometry = .{ .block_entries = 3, .index_fanout = 4 };
    var dev: Device = .{};
    var b: Builder = try .init(gpa, g, 10);
    for ([_]u64{ 2, 4, 6, 8, 10, 12, 14 }) |k| {
        b.append(&dev, .{ .key = k, .value = if (k == 8) null else k * 10 });
    }
    // Two full blocks are on the device already, the seventh slot is buffered.
    try std.testing.expectEqual(2, dev.counters.totalWrites());
    var run = b.finish(gpa, &dev).?;
    defer run.deinit(gpa);
    try std.testing.expectEqual([2]u64{ 1, 3 }, dev.counters.writes); // 1 index, 3 data
    try std.testing.expectEqual(4, dev.live);
    try std.testing.expectEqual(2, run.min_key);
    try std.testing.expectEqual(14, run.max_key);

    try std.testing.expectEqual(Lookup{ .value = 60 }, run.find(6));
    try std.testing.expectEqual(Lookup.tombstone, run.find(8));
    try std.testing.expectEqual(Lookup.absent, run.find(7));
    try std.testing.expect(!run.mayContain(1) and !run.mayContain(15) and run.mayContain(7));
    try std.testing.expect(run.overlaps(14, 20) and !run.overlaps(15, 20) and !run.overlaps(0, 2));
    try std.testing.expectEqual(3, run.lowerBound(7));
}

test "a builder with nothing appended produces no run" {
    var dev: Device = .{};
    var b: Builder = try .init(std.testing.allocator, .{ .block_entries = 3, .index_fanout = 4 }, 5);
    try std.testing.expectEqual(null, b.finish(std.testing.allocator, &dev));
    try std.testing.expectEqual(0, dev.live);
}

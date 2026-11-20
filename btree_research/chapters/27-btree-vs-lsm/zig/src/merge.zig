//! K-way merge: several sorted inputs in, one sorted stream out, and for each
//! key only its NEWEST version survives.
//!
//! This one routine is both halves of an LSM-tree's cost:
//!   * compaction is "merge these runs and write the result as a new run";
//!   * a range scan is "merge the memtable and every run, and stop early".
//!
//! Inputs are added newest first, so an input's position is its age rank.
//! A binary min-heap of input numbers, ordered by (current key, rank), always
//! has the smallest key on top, and among equal keys the newest version.
//!
//! All state is in fixed arrays inside the `Merger` (a cursor per input and
//! the heap): a merge never allocates. Reading is charged to the device one
//! block at a time, as a cursor enters each block.
const std = @import("std");
const assert = std.debug.assert;
const Device = @import("device.zig").Device;
const run_ = @import("run.zig");
const Run = run_.Run;
const Slot = run_.Slot;
const Geometry = run_.Geometry;
const MemNode = @import("memtable.zig").Node;

/// Most inputs one merge can have: the memtable, every level-0 run and one
/// run per deeper level. `Lsm.init` asserts that its configuration fits.
pub const max_sources = 32;

const Source = union(enum) {
    /// A run on the device.
    run: struct {
        slots: []const Slot,
        pos: usize,
        /// Data block the cursor has paid for, if any.
        loaded: ?usize = null,
    },
    /// The memtable: in RAM, so it costs nothing to read.
    mem: ?*const MemNode,

    fn peek(self: *const Source) ?Slot {
        switch (self.*) {
            .run => |r| return if (r.pos < r.slots.len) r.slots[r.pos] else null,
            .mem => |m| return if (m) |node| .{ .key = node.key, .value = node.value } else null,
        }
    }
};

pub const Merger = struct {
    geo: Geometry,
    sources: [max_sources]Source = undefined,
    count: usize = 0,
    /// heap[0..heap_len]: numbers of the inputs that still have a slot.
    heap: [max_sources]u8 = undefined,
    heap_len: usize = 0,
    /// Older versions of a key that were skipped because a newer input had
    /// the same key.
    shadowed: u64 = 0,

    pub fn init(geo: Geometry) Merger {
        return .{ .geo = geo };
    }

    /// Adds a run, positioned at slot `from`. Add inputs NEWEST FIRST.
    pub fn addRun(self: *Merger, dev: *Device, run: *const Run, from: usize) void {
        self.sources[self.count] = .{ .run = .{ .slots = run.slots.items, .pos = from } };
        self.pushSource(dev);
    }

    /// Adds the memtable, positioned at `node` (from `Memtable.seek`).
    pub fn addMemtable(self: *Merger, dev: *Device, node: ?*const MemNode) void {
        self.sources[self.count] = .{ .mem = node };
        self.pushSource(dev);
    }

    fn pushSource(self: *Merger, dev: *Device) void {
        assert(self.count < max_sources);
        const s: u8 = @intCast(self.count);
        self.count += 1;
        self.load(dev, s);
        if (self.sources[s].peek() == null) return; // empty input
        self.heap[self.heap_len] = s;
        self.heap_len += 1;
        self.siftUp(self.heap_len - 1);
    }

    /// Charges the device for the block under the cursor of input `s`, if the
    /// cursor has just entered it: one data block, plus one index block
    /// whenever the data block is the first one that index block describes.
    fn load(self: *Merger, dev: *Device, s: u8) void {
        switch (self.sources[s]) {
            .mem => {},
            .run => |*r| {
                if (r.pos >= r.slots.len) return;
                const block = r.pos / self.geo.block_entries;
                if (r.loaded == block) return;
                const fan = self.geo.index_fanout;
                if (r.loaded == null or r.loaded.? / fan != block / fan) dev.read(.index, 1);
                dev.read(.data, 1);
                r.loaded = block;
            },
        }
    }

    fn advance(self: *Merger, dev: *Device, s: u8) void {
        switch (self.sources[s]) {
            .mem => |*m| m.* = m.*.?.next[0],
            .run => |*r| r.pos += 1,
        }
        self.load(dev, s);
    }

    /// (key, rank) order: smaller key first; for equal keys the newer input.
    fn less(self: *const Merger, a: u8, b: u8) bool {
        const ka = self.sources[a].peek().?.key;
        const kb = self.sources[b].peek().?.key;
        return ka < kb or (ka == kb and a < b);
    }

    fn siftUp(self: *Merger, start: usize) void {
        var i = start;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (!self.less(self.heap[i], self.heap[parent])) break;
            std.mem.swap(u8, &self.heap[i], &self.heap[parent]);
            i = parent;
        }
    }

    fn siftDown(self: *Merger) void {
        var i: usize = 0;
        while (true) {
            var smallest = i;
            for ([_]usize{ 2 * i + 1, 2 * i + 2 }) |child| {
                if (child < self.heap_len and self.less(self.heap[child], self.heap[smallest])) smallest = child;
            }
            if (smallest == i) return;
            std.mem.swap(u8, &self.heap[i], &self.heap[smallest]);
            i = smallest;
        }
    }

    /// Advances the input on top of the heap and restores the heap order.
    fn advanceTop(self: *Merger, dev: *Device) void {
        const s = self.heap[0];
        self.advance(dev, s);
        if (self.sources[s].peek() == null) {
            // Input exhausted: the last heap entry takes its place.
            self.heap_len -= 1;
            self.heap[0] = self.heap[self.heap_len];
        }
        self.siftDown();
    }

    /// Key of the slot `next` would return, without consuming anything.
    pub fn peekKey(self: *const Merger) ?u64 {
        if (self.heap_len == 0) return null;
        return self.sources[self.heap[0]].peek().?.key;
    }

    /// The newest version of the next key in ascending order (tombstones
    /// included: the caller decides whether they may be dropped).
    pub fn next(self: *Merger, dev: *Device) ?Slot {
        if (self.heap_len == 0) return null;
        const winner = self.sources[self.heap[0]].peek().?;
        self.advanceTop(dev);
        // Every other input positioned at the same key holds an older
        // version. Skip them all: that is how an overwrite finally
        // reclaims space.
        while (self.peekKey() == winner.key) {
            self.shadowed += 1;
            self.advanceTop(dev);
        }
        return winner;
    }
};

const testing = std.testing;
const Builder = run_.Builder;

fn buildRun(gpa: std.mem.Allocator, dev: *Device, geo: Geometry, slots: []const Slot) !Run {
    var b: Builder = try .init(gpa, geo, slots.len);
    for (slots) |s| b.append(dev, s);
    return b.finish(gpa, dev).?;
}

test "three runs: ascending output, the newest version wins, tombstones pass through" {
    const gpa = testing.allocator;
    const geo: Geometry = .{ .block_entries = 2, .index_fanout = 2 };
    var dev: Device = .{};
    var newest = try buildRun(gpa, &dev, geo, &.{ .{ .key = 3, .value = 31 }, .{ .key = 7, .value = null } });
    defer newest.deinit(gpa);
    var middle = try buildRun(gpa, &dev, geo, &.{ .{ .key = 1, .value = 12 }, .{ .key = 3, .value = 32 }, .{ .key = 9, .value = 92 } });
    defer middle.deinit(gpa);
    var oldest = try buildRun(gpa, &dev, geo, &.{ .{ .key = 3, .value = 33 }, .{ .key = 5, .value = 53 }, .{ .key = 7, .value = 73 } });
    defer oldest.deinit(gpa);

    const before = dev.counters;
    var m: Merger = .init(geo);
    m.addRun(&dev, &newest, 0);
    m.addRun(&dev, &middle, 0);
    m.addRun(&dev, &oldest, 0);
    const expected = [_]Slot{
        .{ .key = 1, .value = 12 }, .{ .key = 3, .value = 31 }, .{ .key = 5, .value = 53 },
        .{ .key = 7, .value = null }, .{ .key = 9, .value = 92 },
    };
    for (expected) |e| try testing.expectEqual(e, m.next(&dev).?);
    try testing.expectEqual(null, m.next(&dev));
    try testing.expectEqual(3, m.shadowed); // 3 twice, 7 once
    // Every block of every input was read exactly once: 1 + 2 + 2 data
    // blocks and one index block per run.
    const io = dev.counters.since(before);
    try testing.expectEqual([2]u64{ 3, 5 }, io.reads);
}

test "a merge that stops early reads only the blocks it entered" {
    const gpa = testing.allocator;
    const geo: Geometry = .{ .block_entries = 2, .index_fanout = 2 };
    var dev: Device = .{};
    var slots: [20]Slot = undefined;
    for (&slots, 0..) |*s, i| s.* = .{ .key = i * 10, .value = i };
    var run = try buildRun(gpa, &dev, geo, &slots);
    defer run.deinit(gpa);

    const before = dev.counters;
    var m: Merger = .init(geo);
    m.addRun(&dev, &run, run.lowerBound(65)); // slot 7 = key 70, in data block 3
    try testing.expectEqual(70, m.next(&dev).?.key); // cursor moves into block 4
    try testing.expectEqual(80, m.peekKey());
    const io = dev.counters.since(before);
    // Blocks 3 and 4 are described by different index blocks (fan-out 2).
    try testing.expectEqual([2]u64{ 2, 2 }, io.reads);
}

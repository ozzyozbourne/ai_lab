//! A small LSM-tree (log-structured merge tree) on the counted block device.
//!
//!   put / delete ──> MEMTABLE (RAM, sorted, mutable)
//!                       │ full: FLUSH, written once as a sorted run
//!                       ▼
//!   level 0     up to `l0_runs` runs; their key ranges may overlap
//!                       │ full: COMPACT, k-way merge of all of them + level 1
//!                       ▼
//!   level 1     one run, at most  memtable * l0_runs * growth    slots
//!   level 2     one run, at most  memtable * l0_runs * growth^2  slots
//!   ...                 │ over its limit: merge the whole level into the next
//!
//! Nothing on the device is ever changed in place. A write costs no device
//! I/O at all until the memtable fills; the price is paid later, in bulk, by
//! compaction, and by readers, who may have to look in several places.
//!
//! Invariants (checked by `validate`):
//!   1. The memtable holds at most `memtable_entries` keys.
//!   2. Every run is non-empty, strictly ascending, and its min/max keys in
//!      the manifest are those of its first and last slot.
//!   3. Level 0 holds at most `l0_runs` runs; l0[i + 1] is newer than l0[i].
//!   4. NEWER DATA IS ALWAYS SHALLOWER: memtable, then level 0 newest to
//!      oldest, then level 1, 2, ... A reader that searches in this order may
//!      stop at the first hit. Compaction only ever merges ADJACENT ages, so
//!      it cannot break this.
//!   5. The device's block count is exactly the blocks of all runs.
//!   6. (When no maintenance is pending) no level is over its limit.
//!
//! Not an invariant but a space rule: a compaction whose output becomes the
//! deepest level drops tombstones, because nothing older is left to hide.
//!
//! Simplification, stated loudly: a compaction here merges a WHOLE level in
//! one go. Real engines cut each level into many tables and merge one table
//! at a time so that the work can be spread evenly; see the README.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const device = @import("device.zig");
const Device = device.Device;
const memtable = @import("memtable.zig");
const Memtable = memtable.Memtable;
const run_ = @import("run.zig");
const Run = run_.Run;
const Slot = run_.Slot;
const Geometry = run_.Geometry;
const Builder = run_.Builder;
const merge = @import("merge.zig");
const Merger = merge.Merger;

pub const Lookup = memtable.Lookup;
pub const Entry = @import("base_node.zig").Entry;

/// Levels 1 .. max_levels. The last one has no size limit.
pub const max_levels = 12;
pub const max_l0_runs = 16;

comptime {
    // A scan merges the memtable, every level-0 run and every level.
    assert(1 + max_l0_runs + max_levels <= merge.max_sources);
}

pub const Config = struct {
    /// Slots per data block; first-keys per index block (see run.zig).
    block_entries: usize = 15,
    index_fanout: usize = 16,
    /// Distinct keys the memtable holds before it is flushed.
    memtable_entries: usize = 60,
    /// Runs that level 0 collects before they are merged into level 1.
    l0_runs: usize = 4,
    /// Each level may hold `growth` times as many slots as the one above.
    growth: usize = 4,

    pub fn geometry(self: Config) Geometry {
        return .{ .block_entries = self.block_entries, .index_fanout = self.index_fanout };
    }
};

pub const Stats = struct {
    flushes: u64 = 0,
    /// Merges of level 0 into level 1, and of level n into level n + 1.
    l0_compactions: u64 = 0,
    level_merges: u64 = 0,
    /// Slots that compaction did NOT carry over: older versions of a key,
    /// and tombstones that reached the deepest level.
    versions_dropped: u64 = 0,
    tombstones_dropped: u64 = 0,
    /// Point lookups, per run: skipped thanks to the min/max check, probed
    /// (index path + 1 data block), and probed without finding the key.
    runs_skipped: u64 = 0,
    runs_probed: u64 = 0,
    probes_wasted: u64 = 0,
};

pub const Violation = error{
    MemtableOverfull,
    RunEmpty,
    RunNotSorted,
    RunBoundsWrong,
    TooManyL0Runs,
    LevelOverLimit,
    DeviceAccounting,
};

pub const Lsm = struct {
    cfg: Config,
    dev: Device = .{},
    mem: Memtable,
    /// Level 0, oldest first: l0[l0_len - 1] is the most recent flush.
    l0: [max_l0_runs]Run = undefined,
    l0_len: usize = 0,
    /// levels[n - 1] is level n: one run, or nothing yet.
    levels: [max_levels]?Run = @splat(null),
    stats: Stats = .{},

    /// `gpa` backs the memtable's arena. The runs are allocated with the
    /// allocator passed to `put` / `delete` (the same one, normally).
    pub fn init(gpa: Allocator, cfg: Config) Lsm {
        assert(cfg.memtable_entries >= 1 and cfg.growth >= 2);
        assert(cfg.l0_runs >= 1 and cfg.l0_runs <= max_l0_runs);
        return .{ .cfg = cfg, .mem = .init(gpa) };
    }

    pub fn deinit(self: *Lsm, gpa: Allocator) void {
        self.mem.deinit();
        for (self.l0[0..self.l0_len]) |*run| run.deinit(gpa);
        for (&self.levels) |*level| {
            if (level.*) |*run| run.deinit(gpa);
        }
    }

    /// Most slots level `n` (1-based) may hold before it is merged down.
    pub fn levelLimit(self: *const Lsm, n: usize) usize {
        var limit = self.cfg.memtable_entries * self.cfg.l0_runs;
        for (0..n) |_| limit *= self.cfg.growth;
        return limit;
    }

    /// Number of the deepest level that holds a run (0 if there is none).
    pub fn deepestLevel(self: *const Lsm) usize {
        var n: usize = max_levels;
        while (n > 0 and self.levels[n - 1] == null) n -= 1;
        return n;
    }

    // ------------------------------------------------------------ writes

    /// Inserts or overwrites. Unlike the B+tree's `put` it cannot say whether
    /// the key existed: finding out would cost a read, and not reading is the
    /// whole point. On `error.OutOfMemory` the visible contents are unchanged.
    pub fn put(self: *Lsm, gpa: Allocator, key: u64, value: u64) Allocator.Error!void {
        try self.maintain(gpa);
        try self.mem.put(key, value);
    }

    /// Writes a tombstone, whether or not the key exists.
    pub fn delete(self: *Lsm, gpa: Allocator, key: u64) Allocator.Error!void {
        try self.maintain(gpa);
        try self.mem.put(key, null);
    }

    /// True if `maintain` has work to do before the next write.
    pub fn needsMaintenance(self: *const Lsm) bool {
        return self.mem.count >= self.cfg.memtable_entries or self.pendingCompaction() != null;
    }

    /// What `compactOnce` would do: 0 = merge level 0 into level 1,
    /// n = merge level n into level n + 1, null = nothing.
    fn pendingCompaction(self: *const Lsm) ?usize {
        if (self.l0_len >= self.cfg.l0_runs) return 0;
        for (1..max_levels) |n| {
            if (self.levels[n - 1]) |*run| {
                if (run.len() > self.levelLimit(n)) return n;
            }
        }
        return null;
    }

    /// Makes room for one more write: finishes compactions left over from a
    /// failed attempt, flushes a full memtable, and compacts until every
    /// level is within its limit again. This is where ALL the device writes
    /// of an LSM-tree happen. Any step may fail with OutOfMemory; each step
    /// either completes or changes nothing, so it is simply retried by the
    /// next write.
    fn maintain(self: *Lsm, gpa: Allocator) Allocator.Error!void {
        while (self.pendingCompaction()) |n| try self.compact(gpa, n);
        if (self.mem.count < self.cfg.memtable_entries) return;
        try self.flush(gpa);
        while (self.pendingCompaction()) |n| try self.compact(gpa, n);
    }

    /// Writes the memtable as a new level-0 run and empties it. No merging:
    /// the memtable is already sorted, so this is one sequential write.
    pub fn flush(self: *Lsm, gpa: Allocator) Allocator.Error!void {
        if (self.mem.count == 0) return;
        assert(self.l0_len < self.cfg.l0_runs);
        var builder: Builder = try .init(gpa, self.cfg.geometry(), self.mem.count);
        var it = self.mem.first();
        while (it) |node| : (it = node.next[0]) {
            // Tombstones are written too: they must hide older runs.
            builder.append(&self.dev, .{ .key = node.key, .value = node.value });
        }
        self.l0[self.l0_len] = builder.finish(gpa, &self.dev).?;
        self.l0_len += 1;
        self.mem.reset(); // every skip-list node is gone in one call
        self.stats.flushes += 1;
    }

    /// Merges level `from` (0 = all level-0 runs) with the run of the next
    /// level and installs the result as the next level's run.
    fn compact(self: *Lsm, gpa: Allocator, from: usize) Allocator.Error!void {
        const geo = self.cfg.geometry();
        const target = &self.levels[from]; // level from + 1
        // Tombstones can be dropped only if no older data lies below the
        // output: otherwise a dropped tombstone would let a deleted key
        // "come back" from a deeper level.
        const drop_tombstones = self.deepestLevel() <= from + 1;

        // Inputs, newest first (invariant 4).
        var merger: Merger = .init(geo);
        var input_slots: usize = 0;
        if (from == 0) {
            var i = self.l0_len;
            while (i > 0) {
                i -= 1;
                input_slots += self.l0[i].len();
            }
        } else {
            input_slots += self.levels[from - 1].?.len();
        }
        if (target.*) |*old| input_slots += old.len();

        // The only allocation of a compaction. If it fails, nothing has been
        // read, written or changed.
        var builder: Builder = try .init(gpa, geo, input_slots);

        if (from == 0) {
            var i = self.l0_len;
            while (i > 0) {
                i -= 1;
                merger.addRun(&self.dev, &self.l0[i], 0);
            }
        } else {
            merger.addRun(&self.dev, &self.levels[from - 1].?, 0);
        }
        if (target.*) |*old| merger.addRun(&self.dev, old, 0);

        while (merger.next(&self.dev)) |slot| {
            if (slot.value == null and drop_tombstones) {
                self.stats.tombstones_dropped += 1;
                continue;
            }
            builder.append(&self.dev, slot);
        }
        self.stats.versions_dropped += merger.shadowed;
        const output = builder.finish(gpa, &self.dev);

        // The new run is complete: only now do the inputs disappear. Until
        // this point input and output existed side by side on the device,
        // which is what `Device.peak` records.
        if (from == 0) {
            for (self.l0[0..self.l0_len]) |*run| self.dropRun(gpa, run);
            self.l0_len = 0;
            self.stats.l0_compactions += 1;
        } else {
            self.dropRun(gpa, &self.levels[from - 1].?);
            self.levels[from - 1] = null;
            self.stats.level_merges += 1;
        }
        if (target.*) |*old| self.dropRun(gpa, old);
        target.* = output;
    }

    fn dropRun(self: *Lsm, gpa: Allocator, run: *Run) void {
        self.dev.freeBlocks(self.cfg.geometry().blocks(run.len()));
        run.deinit(gpa);
    }

    // ------------------------------------------------------------- reads

    /// Point lookup: newest place first, stop at the first place that knows
    /// the key (invariant 4). Each run that the min/max check cannot rule out
    /// costs its index path, root first, and one data block.
    pub fn get(self: *Lsm, key: u64) ?u64 {
        var result = self.mem.get(key);
        var i = self.l0_len;
        while (result == .absent and i > 0) {
            i -= 1;
            result = self.probe(&self.l0[i], key);
        }
        for (&self.levels) |*level| {
            if (result != .absent) break;
            if (level.*) |*run| result = self.probe(run, key);
        }
        return switch (result) {
            .value => |v| v,
            .tombstone, .absent => null,
        };
    }

    fn probe(self: *Lsm, run: *const Run, key: u64) Lookup {
        if (!run.mayContain(key)) {
            self.stats.runs_skipped += 1; // decided in RAM, no I/O
            return .absent;
        }
        // Root to data block, one block per level: the rule the B+tree's
        // `findLeaf` is charged by.
        self.dev.read(.index, self.cfg.geometry().indexHeight(run.len()));
        self.dev.read(.data, 1);
        self.stats.runs_probed += 1;
        const result = run.find(key);
        // A bloom filter per run exists to make this case rare.
        if (result == .absent) self.stats.probes_wasted += 1;
        return result;
    }

    /// Appends every live entry with lo <= key < hi to `out`, ascending.
    /// A scan cannot stop at the first place that has a key: the next key in
    /// order may come from any run, so all of them are merged.
    pub fn range(self: *Lsm, gpa: Allocator, lo: u64, hi: u64, out: *std.ArrayList(Entry)) Allocator.Error!void {
        if (lo >= hi) return;
        var merger: Merger = .init(self.cfg.geometry());
        merger.addMemtable(&self.dev, self.mem.seek(lo));
        var i = self.l0_len;
        while (i > 0) {
            i -= 1;
            const run = &self.l0[i];
            if (run.overlaps(lo, hi)) merger.addRun(&self.dev, run, run.lowerBound(lo));
        }
        for (&self.levels) |*level| {
            if (level.*) |*run| {
                if (run.overlaps(lo, hi)) merger.addRun(&self.dev, run, run.lowerBound(lo));
            }
        }
        while (merger.peekKey()) |key| {
            if (key >= hi) break;
            const slot = merger.next(&self.dev).?;
            // A tombstone has done its job by winning the merge: skip it.
            if (slot.value) |v| try out.append(gpa, .{ .key = slot.key, .value = v });
        }
    }

    // -------------------------------------------------------- inspection

    /// Slots stored on the device, stale versions and tombstones included.
    pub fn slotsOnDevice(self: *const Lsm) usize {
        var n: usize = 0;
        for (self.l0[0..self.l0_len]) |*run| n += run.len();
        for (&self.levels) |*level| {
            if (level.*) |*run| n += run.len();
        }
        return n;
    }

    pub fn validate(self: *const Lsm) Violation!void {
        try self.validateStructure();
        // 6. Limits hold whenever maintenance is not pending.
        if (self.pendingCompaction() != null) return error.LevelOverLimit;
    }

    /// Invariants 1 to 5: these hold even after a write failed half-way.
    pub fn validateStructure(self: *const Lsm) Violation!void {
        if (self.mem.count > self.cfg.memtable_entries) return error.MemtableOverfull;
        if (self.l0_len > self.cfg.l0_runs) return error.TooManyL0Runs;
        const geo = self.cfg.geometry();
        var blocks: usize = 0;
        for (self.l0[0..self.l0_len]) |*run| {
            try checkRun(run);
            blocks += geo.blocks(run.len());
        }
        for (&self.levels) |*level| {
            const run = if (level.*) |*r| r else continue;
            try checkRun(run);
            blocks += geo.blocks(run.len());
        }
        if (blocks != self.dev.live) return error.DeviceAccounting;
    }

    fn checkRun(run: *const Run) Violation!void {
        const slots = run.slots.items;
        if (slots.len == 0) return error.RunEmpty;
        for (slots[1..], slots[0 .. slots.len - 1]) |b, a| {
            if (a.key >= b.key) return error.RunNotSorted;
        }
        if (run.min_key != slots[0].key or run.max_key != slots[slots.len - 1].key) return error.RunBoundsWrong;
    }
};

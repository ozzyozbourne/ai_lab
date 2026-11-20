//! Interleaving fuzzer: the property the chapter is about, under random test.
//!
//! The fixed scenarios in tests.zig pause ONE scan at ONE chosen moment. Here
//! many scans are paused at once, under up to eight open snapshots, and are
//! advanced a few rows at a time while writers, VACUUM and the three steps of
//! page deletion (`markHalfDead`, `unlinkHalfDead`, `recycle`), called one by
//! one in any order, change the tree under them.
//!
//! After every step:
//!   - `validate()` holds;
//!   - the page handle every paused scan saved is still a live slot (this is
//!     the recycling rule, stated as a check);
//! and regularly a fresh scan and a `get` under every open snapshot equal an
//! independent oracle: a flat list of versions that is never garbage
//! collected. A paused scan must return exactly its snapshot's rows, in order,
//! none lost and none twice, however often it was interrupted.
//!
//! The last test swaps `recycle(horizon)` for `recycleIgnoringSnapshots()` and
//! demands that the same fuzzer then FAILS: a test that cannot fail proves
//! nothing. rust/src/fuzz.rs is the same file line for line (same generator,
//! same seeds, same counts).
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const db_ = @import("db.zig");
const Db = db_.Db;
const Cursor = db_.Cursor;
const NodeId = @import("base_arena.zig").NodeId;

const everything = std.math.maxInt(u64);

/// xorshift64: tiny, seedable, and the same numbers in both languages.
const Rng = struct {
    s: u64,

    fn init(seed: u64) Rng {
        return .{ .s = (seed *% 0x9E3779B97F4A7C15) | 1 };
    }
    fn next(self: *Rng) u64 {
        self.s ^= self.s << 13;
        self.s ^= self.s >> 7;
        self.s ^= self.s << 17;
        return self.s;
    }
    fn below(self: *Rng, n: u64) u64 {
        return (self.next() >> 11) % n;
    }
};

/// The oracle: every version ever written, with its two transaction ids.
const OracleVersion = struct { key: u64, value: u64, xmin: u64, xmax: u64 };
const Pair = struct { key: u64, value: u64 };

fn pairLess(_: void, a: Pair, b: Pair) bool {
    return a.key < b.key;
}

/// What `snapshot` sees in [lo, hi), by the definition of visibility alone.
fn visible(gpa: Allocator, oracle: []const OracleVersion, snapshot: u64, lo: u64, hi: u64) !std.ArrayList(Pair) {
    var out: std.ArrayList(Pair) = .empty;
    errdefer out.deinit(gpa);
    for (oracle) |v| {
        if (v.key >= lo and v.key < hi and v.xmin <= snapshot and (v.xmax == 0 or v.xmax > snapshot))
            try out.append(gpa, .{ .key = v.key, .value = v.value });
    }
    std.mem.sort(Pair, out.items, {}, pairLess); // one visible version per key: keys are unique
    return out;
}

/// A scan stopped between two rows, and the rows it still owes.
const Paused = struct { cursor: Cursor, expected: std.ArrayList(Pair), pos: usize = 0, done: bool = false };
const Snap = struct {
    snapshot: u64,
    cursors: std.ArrayList(Paused) = .empty,

    fn deinit(self: *Snap, gpa: Allocator) void {
        for (self.cursors.items) |*p| p.expected.deinit(gpa);
        self.cursors.deinit(gpa);
    }
};

const Options = struct {
    seed: u64,
    order: usize,
    steps: usize,
    key_space: u64,
    /// Compare every snapshot with the oracle after every step (else every 17th).
    check_every_step: bool,
    bottom_up: bool,
    /// Recycle without asking the horizon: the bug of section 6.
    cheat: bool = false,
};

const max_snapshots = 8;

/// Proof that the runs went where the danger is, summed over all of them.
const Coverage = struct { pages_recycled: usize = 0, pages_reused: usize = 0, moved_right: usize = 0 };

fn run(o: Options, coverage: *Coverage) !void {
    const gpa = testing.allocator;
    var rng: Rng = .init(o.seed);
    var db: Db = .init(o.order);
    defer db.deinit(gpa);
    db.index.bottom_up = o.bottom_up;
    var oracle: std.ArrayList(OracleVersion) = .empty;
    defer oracle.deinit(gpa);
    var snaps: std.ArrayList(Snap) = .empty;
    defer {
        for (snaps.items) |*s| s.deinit(gpa);
        snaps.deinit(gpa);
    }
    var leaves: std.ArrayList(NodeId) = .empty;
    defer leaves.deinit(gpa);

    for (0..o.steps) |step| {
        errdefer if (!o.cheat) std.debug.print("fuzz: seed {d} order {d} step {d}\n", .{ o.seed, o.order, step });
        const r = rng.below(100);
        if (r < 30) { // put
            const key = rng.below(o.key_space);
            const value = rng.next() % 1000;
            const old = try db.put(gpa, key, value);
            try testing.expectEqual(endCurrent(oracle.items, key, db.store.now), old);
            try oracle.append(gpa, .{ .key = key, .value = value, .xmin = db.store.now, .xmax = 0 });
        } else if (r < 50) { // delete one row, or a whole range (that is what empties pages)
            const first = rng.below(o.key_space);
            const n = if (rng.below(4) == 0) rng.below(o.key_space / 2 + 1) else 1;
            var key = first;
            while (key < @min(first + n, o.key_space)) : (key += 1) {
                const old = db.delete(key);
                try testing.expectEqual(endCurrent(oracle.items, key, db.store.now), old);
            }
        } else if (r < 58) { // open a snapshot
            if (snaps.items.len < max_snapshots)
                try snaps.append(gpa, .{ .snapshot = try db.store.openSnapshot() });
        } else if (r < 64) { // close one, with the scans that ran under it
            if (snaps.items.len > 0) {
                var s = snaps.swapRemove(rng.below(snaps.items.len));
                db.store.closeSnapshot(s.snapshot);
                s.deinit(gpa);
            }
        } else if (r < 72) { // start a scan and leave it paused before its first row
            if (snaps.items.len > 0) {
                const s = &snaps.items[rng.below(snaps.items.len)];
                var lo: u64 = 0;
                var hi: u64 = everything;
                if (rng.below(2) != 0) {
                    lo = rng.below(o.key_space);
                    hi = lo + rng.below(o.key_space);
                }
                var expected = try visible(gpa, oracle.items, s.snapshot, lo, hi);
                errdefer expected.deinit(gpa);
                try s.cursors.append(gpa, .{ .cursor = Cursor.seek(&db, s.snapshot, lo, hi), .expected = expected });
            }
        } else if (r < 85) { // advance a paused scan by 1 to 5 rows
            if (snaps.items.len > 0) {
                const s = &snaps.items[rng.below(snaps.items.len)];
                if (s.cursors.items.len > 0) {
                    const p = &s.cursors.items[rng.below(s.cursors.items.len)];
                    const n = 1 + rng.below(5);
                    for (0..n) |_| {
                        if (p.done) break;
                        const got = try p.cursor.next(&db);
                        if (p.pos < p.expected.items.len) {
                            const want = p.expected.items[p.pos];
                            if (got == null) return error.RowLost;
                            try testing.expectEqual(want.key, got.?.key);
                            try testing.expectEqual(want.value, got.?.value);
                            p.pos += 1;
                        } else {
                            try testing.expectEqual(null, got);
                            p.done = true;
                        }
                    }
                }
            }
        } else if (r < 90) { // VACUUM, one time in three without page deletion
            _ = db.vacuum(.{ .delete_pages = rng.below(3) != 0 });
        } else if (r < 94) { // phase 1 alone, on any leaf (most are refused: not empty, rightmost ...)
            try chainLeaves(gpa, &db, &leaves, false);
            if (leaves.items.len > 0)
                _ = db.index.markHalfDead(leaves.items[rng.below(leaves.items.len)]);
        } else if (r < 97) { // phase 2 alone, on a page some earlier step left half-dead
            try chainLeaves(gpa, &db, &leaves, true);
            if (leaves.items.len > 0) {
                const target = leaves.items[rng.below(leaves.items.len)];
                db.index.unlinkHalfDead(&db.store, db.index.leftSibling(target), target);
            }
        } else if (o.cheat) {
            _ = db.index.recycleIgnoringSnapshots();
        } else {
            _ = db.index.recycle(db.store.horizon());
        }

        try db.validate();
        // The recycling rule as a check: no paused scan holds a freed handle.
        for (snaps.items) |*s| for (s.cursors.items) |*p| {
            if (!p.done and p.cursor.next_leaf != .nil and !db.index.nodes.isLive(p.cursor.next_leaf))
                return error.PausedScanPageRecycled;
        };
        if (o.check_every_step or step % 17 == 0) {
            for (snaps.items) |*s| {
                var want = try visible(gpa, oracle.items, s.snapshot, 0, everything);
                defer want.deinit(gpa);
                var cursor = Cursor.seek(&db, s.snapshot, 0, everything);
                for (want.items) |w| {
                    const row = (try cursor.next(&db)) orelse return error.RowLost;
                    try testing.expectEqual(w.key, row.key);
                    try testing.expectEqual(w.value, row.value);
                }
                try testing.expectEqual(null, try cursor.next(&db));
                if (rng.below(4) == 0) {
                    const key = rng.below(o.key_space);
                    var one = try visible(gpa, oracle.items, s.snapshot, key, key + 1);
                    defer one.deinit(gpa);
                    const value: ?u64 = if (one.items.len > 0) one.items[0].value else null;
                    try testing.expectEqual(value, try db.get(s.snapshot, key));
                }
            }
            try db.validate(); // scans set hint bits: those must not lie either
        }
    }

    // Close everything, delete every row, vacuum: nothing may be left behind.
    for (snaps.items) |*s| {
        db.store.closeSnapshot(s.snapshot);
        s.deinit(gpa);
    }
    snaps.clearRetainingCapacity();
    for (0..o.key_space) |key| _ = db.delete(key);
    const report = db.vacuum(.{});
    try testing.expectEqual(0, db.index.count);
    try testing.expectEqual(0, db.store.versions.liveCount());
    try testing.expectEqual(0, report.pages_waiting);
    try db.validate();
    coverage.pages_recycled += db.index.stats.pages_recycled;
    coverage.pages_reused += db.index.stats.pages_reused;
    coverage.moved_right += db.reads.moved_right;
}

/// Ends the current version of `key` in the oracle; returns its value.
fn endCurrent(oracle: []OracleVersion, key: u64, xid: u64) ?u64 {
    for (oracle) |*v| {
        if (v.key == key and v.xmax == 0) {
            v.xmax = xid;
            return v.value;
        }
    }
    return null;
}

/// The leaf chain as the right links give it (all of it, or only half-dead pages).
fn chainLeaves(gpa: Allocator, db: *const Db, out: *std.ArrayList(NodeId), only_half_dead: bool) !void {
    out.clearRetainingCapacity();
    var leaf_id = db.index.first_leaf;
    while (leaf_id != .nil) {
        const leaf = &db.index.nodes.get(leaf_id).kind.leaf;
        if (!only_half_dead or leaf.state == .half_dead) try out.append(gpa, leaf_id);
        leaf_id = leaf.next;
    }
}

const orders = [_]usize{ 3, 4, 5, 8, 16 };
const key_spaces = [_]u64{ 6, 20, 60, 200 };

test "fuzz: paused scans survive writers, vacuum and page deletion in any interleaving" {
    var coverage: Coverage = .{};
    for (1..9) |seed| {
        for (orders) |order| {
            try run(.{
                .seed = seed,
                .order = order,
                .steps = 800,
                .key_space = key_spaces[seed % 4],
                .check_every_step = seed % 2 == 0,
                .bottom_up = seed % 3 != 0,
            }, &coverage);
        }
    }
    // Pages were freed and handed to later splits, and scans did land on dead pages.
    try testing.expect(coverage.pages_recycled > 100);
    try testing.expect(coverage.pages_reused > 100);
    try testing.expect(coverage.moved_right > 100);
}

test "fuzz: the same fuzzer catches recycling that ignores the horizon" {
    var caught: usize = 0;
    var coverage: Coverage = .{};
    for (1..13) |seed| {
        run(.{ .seed = seed, .order = 4, .steps = 800, .key_space = 60, .check_every_step = false, .bottom_up = true, .cheat = true }, &coverage) catch |err| {
            // Always the first symptom: the handle is freed before any scan can trip over it.
            try testing.expectEqual(error.PausedScanPageRecycled, err);
            caught += 1;
        };
    }
    try testing.expectEqual(5, caught); // of 12 seeds; the Rust test finds the same five
}

//! Chapter 14: WHERE to cut a full page.
//!
//! This file is a pure decision procedure. It is handed the cells of a page
//! that is too full, with the incoming cell already placed at its sorted
//! position ("the imaginary page"), and answers one question: which gap
//! between two neighbouring cells becomes the boundary between the left and
//! the right page? It moves no cells and owns no memory; `pages.zig` acts on
//! the answer.
//!
//! The shape follows PostgreSQL's postgres/src/backend/access/nbtree/nbtsplitloc.c:
//!   1. list every legal split point with the free space it leaves  (_bt_recsplitloc)
//!   2. give each a "delta" = distance from the space target, sort   (_bt_deltasortsplits)
//!   3. keep the candidates close enough to the best one             (_bt_defaultinterval)
//!   4. among those, take the one with the cheapest separator        (_bt_bestsplitloc)
//!   5. fall back to other strategies when duplicates get in the way (_bt_strategy)
const std = @import("std");
const Allocator = std.mem.Allocator;

/// One entry of a leaf page. Only its ordering and its size matter here.
/// `tid` is the row id that makes equal keys distinct (chapter 07): cells are
/// ordered by (key, tid), so there are no true duplicates inside the tree.
pub const Cell = struct {
    key: u64,
    tid: u64,
    /// Bytes this cell occupies in the page, slot entry included.
    size: u16,
};

pub fn cellLess(a: Cell, b: Cell) bool {
    return if (a.key != b.key) a.key < b.key else a.tid < b.tid;
}

/// The split policy is a value, not a subclass: a tagged union that
/// `chooseSplit` switches on. The payload is a fill factor in percent, so it
/// must be 0..100 (`isValid`); `Tree.init` and `deltaOf` assert that.
pub const Policy = union(enum) {
    /// Textbook: equalize the bytes on both sides, always.
    half,
    /// Naive fill factor: leave the LEFT page `ff`% full on every split.
    fill: u8,
    /// `half`, except that the rightmost page of the level is cut so that the
    /// left page stays `ff`% full (the append optimisation).
    rightmost: u8,
    /// `rightmost` plus the duplicate-aware part of nbtsplitloc.c: split
    /// interval, separator penalty, "many duplicates" and "single value".
    adaptive: u8,

    /// Is the fill factor a percentage? Anything above 100 has no meaning
    /// ("the left page stays 150% full") and would make `100 - ff` in
    /// `deltaOf` overflow.
    pub fn isValid(self: Policy) bool {
        return switch (self) {
            .half => true,
            .fill, .rightmost, .adaptive => |ff| ff <= 100,
        };
    }
};

/// Which of the three nbtsplitloc.c strategies decided a split
/// (FindSplitStrat, nbtsplitloc.c:21-27). Only `adaptive` leaves `default`.
pub const Strategy = enum { default, many_duplicates, single_value };

/// Left-page fill used by the single value strategy
/// (BTREE_SINGLEVAL_FILLFACTOR, postgres/src/include/access/nbtree.h:203).
pub const single_value_fill: u8 = 96;

/// A legal split point. `first_right` indexes the imaginary page: cells
/// [0, first_right) go left, cells [first_right, n) go right.
pub const Candidate = struct {
    first_right: u32,
    left_bytes: u32,
    right_bytes: u32,
    /// Distance from the space target; smaller is better. Set by `deltaSort`.
    delta: u64 = 0,
};

/// What the policy needs to know about the page besides its cells.
pub const PageInfo = struct {
    capacity: u32,
    /// Key of the separator that bounds this page from above, or null when
    /// the page is the rightmost one of its level (upper bound = +infinity).
    upper_key: ?u64,

    pub fn isRightmost(self: PageInfo) bool {
        return self.upper_key == null;
    }
};

pub const Choice = struct {
    first_right: u32,
    left_bytes: u32,
    right_bytes: u32,
    /// 1: the two cells around the cut have different keys, so the separator
    ///    can be the bare key. 2: equal keys, the separator must carry a tid.
    penalty: u8,
    strategy: Strategy,
    /// How many candidates were close enough to the space target to be
    /// compared by penalty (always 1 for the non-adaptive policies).
    interval: u32,
};

/// Step 1: every gap of the imaginary page whose two sides both fit in a
/// page. The result is in position order and the legal gaps are contiguous,
/// because left_bytes only grows and right_bytes only shrinks along the page.
pub fn candidates(scratch: Allocator, items: []const Cell, capacity: u32) Allocator.Error![]Candidate {
    var total: u32 = 0;
    for (items) |c| total += c.size;

    var list: std.ArrayList(Candidate) = .empty;
    try list.ensureTotalCapacityPrecise(scratch, items.len);
    var left: u32 = 0;
    for (items[0 .. items.len - 1], 1..) |c, first_right| {
        left += c.size;
        const right = total - left;
        // Invariant of every page: used <= capacity. A gap that would break
        // it on either side is not a candidate at all.
        if (left <= capacity and right <= capacity) {
            list.appendAssumeCapacity(.{
                .first_right = @intCast(first_right),
                .left_bytes = left,
                .right_bytes = right,
            });
        }
    }
    return list.items;
}

/// The space target as a number. `fill == null` asks for equal free space on
/// both sides. Otherwise the left page should end up `fill`% full, which is
/// the same as saying left_free : right_free = (100 - fill) : fill.
/// nbtsplitloc.c:575-582 computes this with doubles; we scale by 100 and stay
/// in integers so that Zig and Rust agree bit for bit.
/// `fill` is a percentage; more than 100 is a programming error (asserted).
pub fn deltaOf(c: Candidate, capacity: u32, fill: ?u8) u64 {
    if (fill) |ff| std.debug.assert(ff <= 100);
    const left_free: i64 = @as(i64, capacity) - c.left_bytes;
    const right_free: i64 = @as(i64, capacity) - c.right_bytes;
    const d: i64 = if (fill) |ff|
        @as(i64, ff) * left_free - @as(i64, 100 - ff) * right_free
    else
        left_free - right_free;
    return @abs(d);
}

/// Step 2: best space balance first. Ties go to the leftmost gap, which makes
/// the order total and therefore identical in every implementation.
pub fn deltaSort(cands: []Candidate, capacity: u32, fill: ?u8) void {
    for (cands) |*c| c.delta = deltaOf(c.*, capacity, fill);
    std.mem.sort(Candidate, cands, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return if (a.delta != b.delta) a.delta < b.delta else a.first_right < b.first_right;
        }
    }.lessThan);
}

/// The price of cutting at `c`, measured by what the separator must contain.
/// With one key column this is nbtree's "number of attributes to keep"
/// (_bt_split_penalty, nbtsplitloc.c:1131-1154): 1 or 2.
pub fn penaltyOf(items: []const Cell, c: Candidate) u8 {
    const last_left = items[c.first_right - 1];
    const first_right = items[c.first_right];
    return if (last_left.key != first_right.key) 1 else 2;
}

/// Step 3: how many candidates at the front of the sorted array leave free
/// space within `tolerance` bytes of the best one (_bt_defaultinterval,
/// nbtsplitloc.c:876-921).
fn defaultInterval(cands: []const Candidate, tolerance: u32) u32 {
    const best = cands[0];
    for (cands[1..], 1..) |c, i| {
        // free = capacity - bytes on both sides, so comparing bytes is the
        // same as comparing free space.
        const dl = @max(c.left_bytes, best.left_bytes) - @min(c.left_bytes, best.left_bytes);
        const dr = @max(c.right_bytes, best.right_bytes) - @min(c.right_bytes, best.right_bytes);
        if (dl > tolerance or dr > tolerance) return @intCast(i);
    }
    return @intCast(cands.len);
}

/// Index of the first (lowest delta) candidate with penalty 1, if any.
fn firstDistinct(items: []const Cell, cands: []const Candidate) ?usize {
    for (cands, 0..) |c, i| {
        if (penaltyOf(items, c) == 1) return i;
    }
    return null;
}

/// Decide where to cut. `items` is the imaginary page: the old cells with the
/// new one already inserted at `new_index`, sorted by (key, tid).
///
/// `scratch` only has to live until this function returns; the caller resets
/// it after every split.
pub fn chooseSplit(
    scratch: Allocator,
    items: []const Cell,
    new_index: usize,
    page: PageInfo,
    policy: Policy,
) Allocator.Error!Choice {
    const cands = try candidates(scratch, items, page.capacity);
    // pages.zig caps a cell at capacity / 4, which guarantees a legal gap.
    std.debug.assert(cands.len > 0);

    // Remember the outermost legal gaps before sorting destroys page order
    // (nbtsplitloc.c:342-343). They tell us what the whole page looks like.
    const leftmost = cands[0];
    const rightmost = cands[cands.len - 1];

    // Which space target? This is the entire difference between the first
    // three policies (compare nbtsplitloc.c:281-336).
    const fill: ?u8 = switch (policy) {
        .half => null,
        .fill => |ff| ff,
        .rightmost, .adaptive => |ff| if (page.isRightmost()) ff else null,
    };
    deltaSort(cands, page.capacity, fill);

    var pick: usize = 0; // the space-optimal candidate
    var strategy: Strategy = .default;
    var interval: u32 = 1;

    if (policy == .adaptive) {
        // 5% of the bytes that were on the page before the new cell arrived
        // (LEAF_SPLIT_DISTANCE, nbtsplitloc.c:850).
        const old_bytes = leftmost.left_bytes + leftmost.right_bytes - items[new_index].size;
        interval = defaultInterval(cands, old_bytes / 20);

        if (firstDistinct(items, cands[0..interval])) |i| {
            // Default strategy: a slightly less balanced cut that falls
            // between two different keys beats a perfectly balanced one that
            // falls inside a run of equal keys.
            pick = i;
        } else if (items[leftmost.first_right - 1].key != items[rightmost.first_right].key) {
            // Many duplicates: nothing near the middle works, but the page
            // does hold more than one key. Look at ALL legal gaps and take
            // the best-balanced one at the edge of a duplicate group, however
            // lopsided (nbtsplitloc.c:376-388, 398-406).
            strategy = .many_duplicates;
            interval = @intCast(cands.len);
            pick = firstDistinct(items, cands).?;
        } else if (page.isRightmost() or page.upper_key.? != items[new_index].key) {
            // Single value: the page is one long run of a single key, and the
            // upper bound shows that no page to the right holds this key. New
            // cells of this key carry higher tids and will keep arriving at
            // the right end, so treat it like an append: pack the left page
            // (nbtsplitloc.c:407-417, 1017-1042).
            strategy = .single_value;
            deltaSort(cands, page.capacity, single_value_fill);
            interval = 1;
        }
        // else: one single key, but more of it lives to the right, so this is
        // a random insert into the middle of the group. Keep the 50:50 cut.
    }

    const c = cands[pick];
    return .{
        .first_right = c.first_right,
        .left_bytes = c.left_bytes,
        .right_bytes = c.right_bytes,
        .penalty = penaltyOf(items, c),
        .strategy = strategy,
        .interval = interval,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The page of the README's hand example: capacity 100, 94 bytes used, and a
/// 12-byte cell (20, 5) arriving at index 5.
pub const hand_capacity: u32 = 100;
pub const hand_new_index: usize = 5;
pub const hand_items = [_]Cell{
    .{ .key = 10, .tid = 1, .size = 18 },
    .{ .key = 20, .tid = 1, .size = 14 },
    .{ .key = 20, .tid = 2, .size = 14 },
    .{ .key = 20, .tid = 3, .size = 14 },
    .{ .key = 20, .tid = 4, .size = 14 },
    .{ .key = 20, .tid = 5, .size = 12 },
    .{ .key = 30, .tid = 1, .size = 20 },
};

fn handChoice(policy: Policy, upper_key: ?u64) !Choice {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page: PageInfo = .{ .capacity = hand_capacity, .upper_key = upper_key };
    return chooseSplit(arena.allocator(), &hand_items, hand_new_index, page, policy);
}

test "candidates: every gap of the hand example is legal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cands = try candidates(arena.allocator(), &hand_items, hand_capacity);
    try testing.expectEqual(6, cands.len);
    try testing.expectEqual(18, cands[0].left_bytes);
    try testing.expectEqual(88, cands[0].right_bytes);
    try testing.expectEqual(86, cands[5].left_bytes);
    try testing.expectEqual(20, cands[5].right_bytes);
}

test "candidates: gaps that overflow one side are dropped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // 106 bytes in total and capacity 80: the left side must hold at least 26.
    const cands = try candidates(arena.allocator(), &hand_items, 80);
    try testing.expectEqual(4, cands.len);
    try testing.expectEqual(2, cands[0].first_right);
    try testing.expectEqual(5, cands[3].first_right);
}

test "half cuts in the middle, inside the duplicates" {
    const c = try handChoice(.half, 40);
    try testing.expectEqual(3, c.first_right);
    try testing.expectEqual(46, c.left_bytes);
    try testing.expectEqual(60, c.right_bytes);
    try testing.expectEqual(2, c.penalty);
}

test "fill and rightmost differ only on a page that is not rightmost" {
    const fill_inner = try handChoice(.{ .fill = 90 }, 40);
    const fill_last = try handChoice(.{ .fill = 90 }, null);
    const right_inner = try handChoice(.{ .rightmost = 90 }, 40);
    const right_last = try handChoice(.{ .rightmost = 90 }, null);
    try testing.expectEqual(6, fill_inner.first_right);
    try testing.expectEqual(6, fill_last.first_right);
    try testing.expectEqual(3, right_inner.first_right); // behaves like half
    try testing.expectEqual(6, right_last.first_right);
}

test "adaptive: many duplicates moves the cut to the edge of the group" {
    const c = try handChoice(.{ .adaptive = 90 }, 40);
    try testing.expectEqual(Strategy.many_duplicates, c.strategy);
    try testing.expectEqual(6, c.first_right);
    try testing.expectEqual(1, c.penalty);
    try testing.expectEqual(6, c.interval);
}

test "adaptive: default strategy trades a little balance for a short separator" {
    // 26 cells of 4 bytes; the key changes between index 13 and 14. The
    // perfectly balanced cut (before 13) falls inside key 1. The tolerance is
    // 5% of 100 bytes, so the cuts before 12 and 14 are also acceptable, and
    // the one before 14 has two different keys around it.
    var items: [26]Cell = undefined;
    for (&items, 0..) |*c, i| c.* = .{ .key = if (i < 14) 1 else 2, .tid = i, .size = 4 };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const page: PageInfo = .{ .capacity = 100, .upper_key = 9 };
    const half = try chooseSplit(arena.allocator(), &items, 25, page, .half);
    const adaptive = try chooseSplit(arena.allocator(), &items, 25, page, .{ .adaptive = 90 });
    try testing.expectEqual(13, half.first_right);
    try testing.expectEqual(2, half.penalty);
    try testing.expectEqual(14, adaptive.first_right);
    try testing.expectEqual(1, adaptive.penalty);
    try testing.expectEqual(Strategy.default, adaptive.strategy);
    try testing.expectEqual(3, adaptive.interval); // gaps 13, 12 and 14
}

test "adaptive: single value packs the left page only at the end of the group" {
    var items: [26]Cell = undefined;
    for (&items, 0..) |*c, i| c.* = .{ .key = 7, .tid = i, .size = 4 };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const policy: Policy = .{ .adaptive = 90 };

    // Upper bound is another key: this is the last page holding key 7.
    const last = try chooseSplit(a, &items, 25, .{ .capacity = 100, .upper_key = 8 }, policy);
    try testing.expectEqual(Strategy.single_value, last.strategy);
    try testing.expectEqual(96, last.left_bytes);

    // Rightmost page of the level: same.
    const rightmost = try chooseSplit(a, &items, 25, .{ .capacity = 100, .upper_key = null }, policy);
    try testing.expectEqual(Strategy.single_value, rightmost.strategy);

    // Upper bound is key 7 itself: more 7s live to the right, split 50:50.
    const middle = try chooseSplit(a, &items, 3, .{ .capacity = 100, .upper_key = 7 }, policy);
    try testing.expectEqual(Strategy.default, middle.strategy);
    try testing.expectEqual(52, middle.left_bytes);
    try testing.expectEqual(2, middle.penalty);
}

test "a fill factor is a percentage: only 0..100 is valid" {
    try testing.expect((Policy{ .half = {} }).isValid());
    for ([_]u8{ 0, 50, 100 }) |ff| {
        try testing.expect((Policy{ .fill = ff }).isValid());
        try testing.expect((Policy{ .rightmost = ff }).isValid());
        try testing.expect((Policy{ .adaptive = ff }).isValid());
    }
    for ([_]u8{ 101, 150, 255 }) |ff| {
        try testing.expect(!(Policy{ .fill = ff }).isValid());
        try testing.expect(!(Policy{ .rightmost = ff }).isValid());
        try testing.expect(!(Policy{ .adaptive = ff }).isValid());
    }
    // The two ends of the range are ordinary targets. 100: the left page
    // should keep no free space, so the fullest legal left page wins.
    // 0: the left page should be empty, so the emptiest one wins.
    try testing.expectEqual(6, (try handChoice(.{ .fill = 100 }, 40)).first_right);
    try testing.expectEqual(1, (try handChoice(.{ .fill = 0 }, 40)).first_right);
}

test "chooseSplit reports OutOfMemory from the scratch allocator" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    const page: PageInfo = .{ .capacity = hand_capacity, .upper_key = null };
    try testing.expectError(
        error.OutOfMemory,
        chooseSplit(failing.allocator(), &hand_items, hand_new_index, page, .half),
    );
}

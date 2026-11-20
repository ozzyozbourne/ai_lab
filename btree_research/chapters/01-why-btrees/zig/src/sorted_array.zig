//! A map from u64 to u64 kept as ONE sorted array.
//!
//! This is the simplest ordered index there is, and it is the right mental
//! starting point: a B-tree node is a small sorted array, and a B-tree is
//! what you get when one sorted array is no longer good enough.
//!
//! Reads are excellent: binary search, and the result of a range query is one
//! contiguous slice. Writes are the problem: to keep the array sorted, `put`
//! and `delete` must shift every entry behind the affected position.
//!
//! Invariant (checked by `validate`): keys are strictly ascending in
//! `entries[0..len]`. "Strictly" also means there are no duplicates.
const std = @import("std");
const Allocator = std.mem.Allocator;
const cost = @import("cost.zig");

pub const Entry = cost.Entry;

pub const SortedArrayMap = struct {
    /// The whole allocation. `entries.len` is the capacity.
    entries: []Entry = &.{},
    /// How many slots at the front are in use.
    len: usize = 0,
    /// Total entries shifted by `put` and `delete` so far (the write cost).
    moves: u64 = 0,
    /// Total model pages rewritten by `put` and `delete` so far.
    page_writes: u64 = 0,

    pub const empty: SortedArrayMap = .{};

    /// Build from entries in any order: copy, then sort once. This is how a
    /// read-only index is made (Milvus builds its sorted index the same way)
    /// and it costs O(n log n) in total instead of O(n^2) for n single puts.
    /// The keys must be distinct.
    pub fn initFromEntries(allocator: Allocator, unsorted: []const Entry) Allocator.Error!SortedArrayMap {
        const copy = try allocator.dupe(Entry, unsorted);
        std.mem.sort(Entry, copy, {}, keyLessThan);
        const map: SortedArrayMap = .{ .entries = copy, .len = copy.len };
        std.debug.assert(map.isValid());
        return map;
    }

    pub fn deinit(self: *SortedArrayMap, allocator: Allocator) void {
        allocator.free(self.entries);
        self.* = .empty;
    }

    /// The live entries, in ascending key order.
    pub fn items(self: *const SortedArrayMap) []const Entry {
        return self.entries[0..self.len];
    }

    pub fn get(self: *const SortedArrayMap, key: u64) ?u64 {
        var trace: cost.Trace = .{};
        return self.getTraced(key, &trace);
    }

    /// `get` that also reports what the lookup cost.
    pub fn getTraced(self: *const SortedArrayMap, key: u64, trace: *cost.Trace) ?u64 {
        const i = self.lowerBound(key, trace);
        // The entry at `i` was probed by the search or sits next to a probed
        // entry on the same page... unless the search never ran (i == len).
        if (i == self.len) return null;
        trace.touch(i / cost.entries_per_page);
        trace.comparisons += 1;
        return if (self.entries[i].key == key) self.entries[i].value else null;
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    /// On error.OutOfMemory the map is unchanged.
    pub fn put(self: *SortedArrayMap, allocator: Allocator, key: u64, value: u64) Allocator.Error!?u64 {
        const i = self.lowerBound(key, null);
        if (i < self.len and self.entries[i].key == key) {
            const old = self.entries[i].value;
            self.entries[i].value = value;
            self.page_writes += 1;
            return old;
        }
        // Grow BEFORE touching anything, so a failed allocation changes nothing.
        if (self.len == self.entries.len) try self.grow(allocator);

        // Open a gap at i: everything in [i, len) moves one slot to the right.
        // This loop is the reason a sorted array is a poor index for data
        // that changes: its length is "how many keys are larger than mine".
        const tail = self.len - i;
        @memmove(self.entries[i + 1 .. self.len + 1], self.entries[i..self.len]);
        self.entries[i] = .{ .key = key, .value = value };
        self.len += 1;
        self.moves += tail;
        self.page_writes += pagesSpanned(i, self.len);
        return null;
    }

    /// Remove a key. Returns the removed value, or null if it was absent.
    pub fn delete(self: *SortedArrayMap, key: u64) ?u64 {
        const i = self.lowerBound(key, null);
        if (i == self.len or self.entries[i].key != key) return null;
        const old = self.entries[i].value;
        // Close the gap: everything in (i, len) moves one slot to the left.
        const tail = self.len - i - 1;
        @memmove(self.entries[i .. self.len - 1], self.entries[i + 1 .. self.len]);
        self.moves += tail;
        self.page_writes += pagesSpanned(i, self.len);
        self.len -= 1;
        return old;
    }

    /// All entries with lo <= key < hi, ascending. The slice points into the
    /// map and is invalidated by the next `put` or `delete`.
    pub fn range(self: *const SortedArrayMap, lo: u64, hi: u64) []const Entry {
        const start = self.lowerBound(lo, null);
        const end = self.lowerBound(hi, null);
        return if (start < end) self.entries[start..end] else &.{};
    }

    pub const ValidateError = error{ LenExceedsCapacity, KeysNotStrictlyAscending };

    /// Check the invariant: len fits and keys are strictly ascending.
    pub fn validate(self: *const SortedArrayMap) ValidateError!void {
        if (self.len > self.entries.len) return error.LenExceedsCapacity;
        var i: usize = 1; // `for (1..self.len)` would overflow when len is 0
        while (i < self.len) : (i += 1) {
            if (self.entries[i - 1].key >= self.entries[i].key) return error.KeysNotStrictlyAscending;
        }
    }

    fn isValid(self: *const SortedArrayMap) bool {
        self.validate() catch return false;
        return true;
    }

    /// Binary search: index of the first entry whose key is >= `key`
    /// (`len` if there is none). Chapter 02 is entirely about this function.
    fn lowerBound(self: *const SortedArrayMap, key: u64, trace: ?*cost.Trace) usize {
        var lo: usize = 0;
        var hi: usize = self.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (trace) |t| {
                t.comparisons += 1;
                // Looking at entry `mid` means having its page in memory.
                t.touch(mid / cost.entries_per_page);
            }
            if (self.entries[mid].key < key) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Double the capacity (8 slots to start with). The array must stay ONE
    /// contiguous block, so growing means asking for a bigger block; unless
    /// the allocator can extend the block in place, every entry is copied.
    fn grow(self: *SortedArrayMap, allocator: Allocator) Allocator.Error!void {
        const new_capacity = @max(8, self.entries.len * 2);
        self.entries = try allocator.realloc(self.entries, new_capacity);
    }

    /// Pages that contain any of the slots [first, end): the pages a shift
    /// starting at `first` has to rewrite.
    fn pagesSpanned(first: usize, end: usize) u64 {
        std.debug.assert(first < end);
        return (end - 1) / cost.entries_per_page - first / cost.entries_per_page + 1;
    }

    fn keyLessThan(_: void, a: Entry, b: Entry) bool {
        return a.key < b.key;
    }
};

// ----------------------------------------------------------------- tests ---

const testing = std.testing;
const ops = @import("ops.zig");

test "put keeps keys sorted and counts the shifted entries" {
    const allocator = testing.allocator;
    var map: SortedArrayMap = .empty;
    defer map.deinit(allocator);

    try testing.expectEqual(null, try map.put(allocator, 20, 200));
    try testing.expectEqual(0, map.moves); // appended at the end: nothing moves
    try testing.expectEqual(null, try map.put(allocator, 30, 300));
    try testing.expectEqual(0, map.moves);
    try testing.expectEqual(null, try map.put(allocator, 10, 100));
    try testing.expectEqual(2, map.moves); // new smallest key: both others move
    try testing.expectEqual(200, try map.put(allocator, 20, 222)); // overwrite
    try testing.expectEqual(2, map.moves);

    try map.validate();
    try testing.expectEqual(3, map.len);
    try testing.expectEqual(222, map.get(20));
    try testing.expectEqual(null, map.get(25));
    try testing.expectEqual(null, map.get(99));
}

test "delete closes the gap" {
    const allocator = testing.allocator;
    var map: SortedArrayMap = .empty;
    defer map.deinit(allocator);
    for ([_]u64{ 1, 2, 3, 4, 5 }) |k| _ = try map.put(allocator, k, k * 10);
    map.moves = 0;

    try testing.expectEqual(20, map.delete(2));
    try testing.expectEqual(3, map.moves); // 3, 4, 5 moved left
    try testing.expectEqual(null, map.delete(2));
    try testing.expectEqual(50, map.delete(5));
    try testing.expectEqual(3, map.moves); // last entry: nothing to move
    try map.validate();
    try testing.expectEqual(3, map.len);
}

test "range is a contiguous slice with lo inclusive and hi exclusive" {
    const allocator = testing.allocator;
    var map: SortedArrayMap = .empty;
    defer map.deinit(allocator);
    for ([_]u64{ 10, 20, 30, 40 }) |k| _ = try map.put(allocator, k, k + 1);

    const r = map.range(20, 40);
    try testing.expectEqual(2, r.len);
    try testing.expectEqual(20, r[0].key);
    try testing.expectEqual(30, r[1].key);
    try testing.expectEqual(0, map.range(21, 30).len);
    try testing.expectEqual(0, map.range(40, 20).len);
    try testing.expectEqual(4, map.range(0, std.math.maxInt(u64)).len);
}

test "initFromEntries sorts once" {
    const allocator = testing.allocator;
    var map = try SortedArrayMap.initFromEntries(allocator, &.{
        .{ .key = 3, .value = 30 }, .{ .key = 1, .value = 10 }, .{ .key = 2, .value = 20 },
    });
    defer map.deinit(allocator);
    try map.validate();
    try testing.expectEqual(0, map.moves);
    try testing.expectEqual(20, map.get(2));
}

test "validate rejects an unsorted array" {
    var storage = [_]Entry{ .{ .key = 2, .value = 0 }, .{ .key = 1, .value = 0 } };
    const map: SortedArrayMap = .{ .entries = &storage, .len = 2 };
    try testing.expectError(error.KeysNotStrictlyAscending, map.validate());
    storage[1].key = 2; // a duplicate is not strictly ascending either
    try testing.expectError(error.KeysNotStrictlyAscending, map.validate());
}

test "a lookup in 100000 entries: at most 18 comparisons and 9 page reads" {
    const allocator = testing.allocator;
    const n = 100_000;
    const unsorted = try allocator.alloc(Entry, n);
    defer allocator.free(unsorted);
    for (unsorted, 0..) |*e, i| e.* = .{ .key = (n - i) * 10, .value = i };
    var map = try SortedArrayMap.initFromEntries(allocator, unsorted);
    defer map.deinit(allocator);

    var max_comparisons: u64 = 0;
    var max_pages: u64 = 0;
    for (0..n) |i| {
        var trace: cost.Trace = .{};
        try testing.expect(map.getTraced((i + 1) * 10, &trace) != null);
        max_comparisons = @max(max_comparisons, trace.comparisons);
        max_pages = @max(max_pages, trace.page_reads);
    }
    // ceil(log2(100000)) = 17 halvings, plus the final equality check.
    try testing.expectEqual(18, max_comparisons);
    // The array spans 391 pages. Each early probe lands on a different page;
    // the reads stop only when the search interval fits inside one page,
    // after about log2(391) = 8.6 halvings.
    try testing.expectEqual(9, max_pages);
}

test "put on a fixed buffer: OutOfMemory leaves the map unchanged" {
    // Room for exactly 16 entries. FixedBufferAllocator can extend its most
    // recent allocation in place, so 8 -> 16 works; 16 -> 32 cannot.
    var buffer: [16 * @sizeOf(Entry)]u8 align(@alignOf(Entry)) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const allocator = fba.allocator();

    var map: SortedArrayMap = .empty;
    for (0..16) |i| _ = try map.put(allocator, 100 - i, i);
    try testing.expectError(error.OutOfMemory, map.put(allocator, 1, 1));
    try map.validate();
    try testing.expectEqual(16, map.len);
    try testing.expectEqual(null, map.get(1));
    try testing.expectEqual(15, map.get(85));
    // Overwriting needs no memory, so it still works on a full buffer.
    try testing.expectEqual(15, try map.put(allocator, 85, 7));
}

fn putMany(allocator: Allocator, count: u64) !void {
    var map: SortedArrayMap = .empty;
    defer map.deinit(allocator);
    for (0..count) |i| {
        _ = try map.put(allocator, (i * 7) % count, i);
        try map.validate();
    }
}

test "put under every possible allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, putMany, .{@as(u64, 40)});
}

test "model test against the oracle" {
    const allocator = testing.allocator;
    var map: SortedArrayMap = .empty;
    defer map.deinit(allocator);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(allocator);

    var stream = ops.OpStream.init(.{ .seed = 1, .count = 5000, .key_space = 200 });
    while (stream.next()) |op| {
        switch (op) {
            .put => |p| try testing.expectEqual(try oracle.put(allocator, p.key, p.value), try map.put(allocator, p.key, p.value)),
            .delete => |d| try testing.expectEqual(oracle.delete(d.key), map.delete(d.key)),
            .get => |g| try testing.expectEqual(oracle.get(g.key), map.get(g.key)),
            .range => |r| {
                const want = oracle.range(r.lo, r.hi);
                const got = map.range(r.lo, r.hi);
                try testing.expectEqual(want.len, got.len);
                for (want, got) |w, g| {
                    try testing.expectEqual(w.key, g.key);
                    try testing.expectEqual(w.value, g.value);
                }
            },
        }
        try map.validate();
        try testing.expectEqual(oracle.len(), map.len);
    }
}

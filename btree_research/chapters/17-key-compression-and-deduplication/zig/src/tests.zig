//! Tests for tree.zig. Every test uses std.testing.allocator, so a leaked
//! page arena or scratch buffer fails the run.
const std = @import("std");
const testing = std.testing;
const t = @import("tree.zig");
const Tree = t.Tree;
const SplitMix64 = @import("prng.zig").SplitMix64;

fn cell(key: []const u8, tids: []t.Tid) t.LeafCell {
    return .{ .key = key, .tids = tids };
}

test "compareTuple: key bytes, then TID, and a missing TID is minus infinity" {
    try testing.expectEqual(.lt, t.compareTuple("app", 9, "apple", 1)); // a prefix sorts first
    try testing.expectEqual(.lt, t.compareTuple("apple", 1, "apple", 2));
    try testing.expectEqual(.lt, t.compareTuple("apple", null, "apple", 0)); // truncated TID
    try testing.expectEqual(.gt, t.compareTuple("apple", 0, "apple", null));
    try testing.expectEqual(.eq, t.compareTuple("apple", null, "apple", null));
    try testing.expectEqual(.gt, t.compareTuple("b", null, "apple", 99));
}

test "separator: shortest prefix that separates, TID only when keys are equal" {
    var one = [_]t.Tid{4};
    var two = [_]t.Tid{ 7, 9 };
    const Case = struct { left: []const u8, right: []const u8, key: []const u8, tid: ?t.Tid };
    const cases = [_]Case{
        .{ .left = "banana", .right = "cherry", .key = "c", .tid = null },
        .{ .left = "blackberry", .right = "blueberry", .key = "blu", .tid = null },
        .{ .left = "app", .right = "apple", .key = "appl", .tid = null }, // left is a prefix of right
        .{ .left = "apple", .right = "apply", .key = "apply", .tid = null }, // differ in the last byte: no gain
        .{ .left = "apple", .right = "apple", .key = "apple", .tid = 4 }, // equal keys: last-left key AND TID
    };
    for (cases) |c| {
        const l = cell(c.left, &one);
        const r = cell(c.right, &two);
        const s = t.separator(true, l, r);
        try testing.expectEqualStrings(c.key, s.key);
        try testing.expectEqual(c.tid, s.tid);
        // The contract: last_left <= sep < first_right.
        try testing.expect(t.compareTuple(l.key, l.tids[0], s.key, s.tid) != .gt);
        try testing.expectEqual(.lt, t.compareTuple(s.key, s.tid, r.key, r.tids[0]));
        // Without truncation the separator is always the full last-left tuple.
        const full = t.separator(false, l, r);
        try testing.expectEqualStrings(c.left, full.key);
        try testing.expectEqual(@as(?t.Tid, 4), full.tid);
    }
}

test "byte accounting" {
    try testing.expectEqual(15, t.leafCellSize(5, 1)); // slot 2 + len 2 + "apple" 5 + TID 6
    try testing.expectEqual(29, t.leafCellSize(5, 3)); // slot 2 + len 2 + 5 + count 2 + 3 * 6
    try testing.expectEqual(0, t.sepSize(null));
    try testing.expectEqual(5, t.sepSize(.{ .key = "c", .tid = null }));
    try testing.expectEqual(16, t.sepSize(.{ .key = "banana", .tid = 3 }));
    try testing.expectEqual(9, t.pivotSize(.{ .key = "c", .tid = null }));
}

test "empty tree, duplicates rejected, key size limit" {
    var tree = try Tree.init(testing.allocator, .{ .page_size = 256 });
    defer tree.deinit();
    try tree.validate();
    try testing.expectEqual(27, tree.maxKeyLen());
    try testing.expect(try tree.put("apple", 1));
    try testing.expect(!try tree.put("apple", 1)); // same (key, TID): already there
    try testing.expect(try tree.put("apple", 2)); // same key, other row: a new entry
    const long: [28]u8 = @splat('x');
    try testing.expectError(error.KeyTooLarge, tree.put(&long, 1));
    try testing.expect(try tree.put(long[0..27], 1));
    try testing.expect(tree.contains("apple", 2));
    try testing.expect(!tree.contains("apple", 3));
    try testing.expect(tree.delete("apple", 1));
    try testing.expect(!tree.delete("apple", 1));
    try testing.expectEqual(2, tree.count);
    try tree.validate();
}

test "a search routes correctly through truncated separators" {
    var tree = try Tree.init(testing.allocator, .{ .page_size = 128 });
    defer tree.deinit();
    const words = [_][]const u8{ "a", "ab", "abc", "abcd", "b", "ba", "bab", "c", "ca", "cab", "d", "da" };
    for (0..6) |round| {
        for (words, 0..) |w, i| try testing.expect(try tree.put(w, round * 100 + i));
    }
    try tree.validate();
    const s = tree.stats();
    try testing.expect(s.height >= 2);
    try testing.expectEqual(72, s.entries);
    for (words, 0..) |w, i| {
        const tids = try tree.get(testing.allocator, w);
        defer testing.allocator.free(tids);
        try testing.expectEqual(6, tids.len);
        for (tids, 0..) |tid, round| try testing.expectEqual(round * 100 + i, tid);
    }
    // Keys that are absent but equal to, shorter or longer than separators.
    for ([_][]const u8{ "", "aa", "abcde", "bb", "cz", "e" }) |w| {
        const tids = try tree.get(testing.allocator, w);
        defer testing.allocator.free(tids);
        try testing.expectEqual(0, tids.len);
    }
}

test "deduplication turns a page of duplicates into posting lists instead of splitting" {
    var with = try Tree.init(testing.allocator, .{ .page_size = 256, .dedup = true });
    defer with.deinit();
    var without = try Tree.init(testing.allocator, .{ .page_size = 256, .dedup = false });
    defer without.deinit();
    for (0..60) |i| {
        const key: []const u8 = if (i % 2 == 0) "open" else "closed";
        _ = try with.put(key, i);
        _ = try without.put(key, i);
    }
    try with.validate();
    try without.validate();
    const a = with.stats();
    const b = without.stats();
    try testing.expectEqual(60, a.entries);
    try testing.expect(a.posting_cells > 0);
    try testing.expectEqual(0, b.posting_cells);
    try testing.expect(a.leaf_pages < b.leaf_pages);
    try testing.expect(with.counters.dedup_passes > 0);
}

test "posting list split: a TID inside a posting list's range pushes the largest one out" {
    var tree = try Tree.init(testing.allocator, .{ .page_size = 256 });
    defer tree.deinit();
    // 15 even TIDs fill the page; the 16th put triggers the dedup pass.
    var i: t.Tid = 0;
    while (tree.counters.dedup_passes == 0) : (i += 2) _ = try tree.put("k", i);
    const before = tree.stats();
    try testing.expect(before.posting_cells > 0);
    try testing.expect(try tree.put("k", 3)); // inside the first posting list
    try testing.expectEqual(1, tree.counters.posting_swaps);
    const after = tree.stats();
    try testing.expectEqual(before.posting_cells, after.posting_cells);
    try testing.expectEqual(before.leaf_cells + 1, after.leaf_cells); // the evicted TID became a plain cell
    try tree.validate();
    const tids = try tree.get(testing.allocator, "k");
    defer testing.allocator.free(tids);
    try testing.expectEqual(i / 2 + 1, tids.len);
    try testing.expectEqualSlices(t.Tid, &.{ 0, 2, 3, 4, 6 }, tids[0..5]);
}

test "range is ordered by (key, TID) and respects the upper bound" {
    var tree = try Tree.init(testing.allocator, .{ .page_size = 128 });
    defer tree.deinit();
    for ([_][]const u8{ "d", "b", "a", "c", "b", "d", "b" }, 0..) |w, i| _ = try tree.put(w, 10 - i);
    var it = tree.range("b", "d");
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    while (it.next()) |e| try w.print("{s}@{d} ", .{ e.key, e.tid });
    try testing.expectEqualStrings("b@4 b@6 b@9 c@7 ", w.buffered());
}

/// The key for model-test index `i`: fixed-width digits first, so byte order
/// equals index order, then a tail of varying length so that prefixes vary.
fn modelKey(buf: *[16]u8, i: u64) []const u8 {
    const tail = "xxx";
    return std.fmt.bufPrint(buf, "k{d:0>2}{s}", .{ i, tail[0..@intCast(i % 4)] }) catch unreachable;
}

fn modelRun(cfg: t.Config, seed: u64, ops: usize) !void {
    const gpa = testing.allocator;
    var tree = try Tree.init(gpa, cfg);
    defer tree.deinit();
    // Oracle: a sorted array of (key index << 32 | tid).
    var oracle: std.ArrayList(u64) = .empty;
    defer oracle.deinit(gpa);
    var rng = SplitMix64.init(seed);
    var buf: [16]u8 = undefined;
    const lessThan = struct {
        fn f(ctx: u64, x: u64) bool {
            return x < ctx;
        }
    }.f;

    for (0..ops) |n| {
        const ki = rng.below(40);
        const tid = rng.below(64);
        const key = modelKey(&buf, ki);
        const packed_entry = ki << 32 | tid;
        const at = std.sort.partitionPoint(u64, oracle.items, packed_entry, lessThan);
        const present = at < oracle.items.len and oracle.items[at] == packed_entry;
        switch (rng.below(10)) {
            0...5 => {
                try testing.expectEqual(!present, try tree.put(key, tid));
                if (!present) try oracle.insert(gpa, at, packed_entry);
            },
            6...7 => {
                try testing.expectEqual(present, tree.delete(key, tid));
                if (present) _ = oracle.orderedRemove(at);
            },
            8 => try testing.expectEqual(present, tree.contains(key, tid)),
            else => {
                // get: every TID of the key, in order.
                const tids = try tree.get(gpa, key);
                defer gpa.free(tids);
                var i = std.sort.partitionPoint(u64, oracle.items, ki << 32, lessThan);
                for (tids) |got| {
                    try testing.expectEqual(oracle.items[i], ki << 32 | got);
                    i += 1;
                }
                try testing.expect(i == oracle.items.len or oracle.items[i] >> 32 != ki);
            },
        }
        try testing.expectEqual(oracle.items.len, tree.count);
        if (n % 64 == 0) try tree.validate();
    }
    try tree.validate();
    // Full scan equals the oracle.
    var it = tree.range("", null);
    var kbuf: [16]u8 = undefined;
    for (oracle.items) |want| {
        const e = it.next().?;
        try testing.expectEqualStrings(modelKey(&kbuf, want >> 32), e.key);
        try testing.expectEqual(want & 0xffff_ffff, e.tid);
    }
    try testing.expectEqual(null, it.next());
}

test "model test against a sorted-array oracle, all four configurations" {
    for ([_]bool{ false, true }) |truncate| {
        for ([_]bool{ false, true }) |dedup| {
            try modelRun(.{ .page_size = 128, .truncate = truncate, .dedup = dedup }, 17, 6000);
            try modelRun(.{ .page_size = 256, .truncate = truncate, .dedup = dedup }, 1717, 6000);
        }
    }
}

fn buildSmall(gpa: std.mem.Allocator) !void {
    var tree = try Tree.init(gpa, .{ .page_size = 128 });
    defer tree.deinit();
    var buf: [16]u8 = undefined;
    for (0..70) |i| _ = try tree.put(modelKey(&buf, (i * 7) % 20), i);
    try tree.validate();
}

test "allocation failure anywhere during a build: error returned, nothing leaked" {
    try testing.checkAllAllocationFailures(testing.allocator, buildSmall, .{});
}

test "a put that fails for lack of memory leaves the tree exactly as it was" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var tree = try Tree.init(failing.allocator(), .{ .page_size = 128, .dedup = false });
    defer tree.deinit();
    var buf: [16]u8 = undefined;
    var saw_root_split_failure = false;
    for (0..400) |i| {
        const key = modelKey(&buf, (i * 13) % 40);
        const before = tree.stats();
        // Fail the 1st, 2nd, 3rd ... allocation of this put until it gets through.
        var k: usize = 0;
        while (true) : (k += 1) {
            failing.fail_index = failing.alloc_index + k;
            if (tree.put(key, i)) |inserted| {
                try testing.expect(inserted);
                break;
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try tree.validate();
                try testing.expectEqual(before, tree.stats());
                try testing.expect(!tree.contains(key, i));
                if (k > 6) saw_root_split_failure = true; // deep into a multi-page split
            }
        }
        failing.fail_index = std.math.maxInt(usize);
    }
    try tree.validate();
    try testing.expect(tree.stats().height >= 3);
    try testing.expect(saw_root_split_failure);
}

test "deletes do not grow a leaf's arena without bound" {
    var tree = try Tree.init(testing.allocator, .{ .page_size = 128 });
    defer tree.deinit();
    for (0..5000) |i| {
        try testing.expect(try tree.put("churn", i));
        try testing.expect(tree.delete("churn", i));
    }
    try testing.expectEqual(1, tree.pages.items.len);
    try testing.expect(tree.pages.items[0].dead_bytes <= 128);
    try tree.validate();
}

//! IVF ("inverted file") index: a two-level tree whose root is not ordered.
//!
//!   root:   nlist centroids                     (B-tree: sorted separators)
//!   leaves: one flat list of vectors per centroid   (B-tree: leaf pages)
//!
//! Routing in a B-tree is a binary search that picks exactly one child. Here
//! the root has no order to search, so routing is itself a nearest-neighbour
//! scan over all centroids, and because the query's true neighbours may sit
//! just across a cell boundary, the search visits the `nprobe` nearest
//! leaves instead of one. The answer is approximate; "recall" measures it
//! against brute force.
//!
//! Everything is integer arithmetic (i32 coordinates, u64 squared distances,
//! ties broken by id), so the Zig and Rust programs agree bit for bit.
const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitMix64 = @import("prng.zig").SplitMix64;

/// A candidate answer. Ordered by (dist, id): the id breaks distance ties so
/// that every "nearest" in this file has exactly one answer.
pub const Hit = struct {
    dist: u64,
    id: u32,

    pub fn lessThan(a: Hit, b: Hit) bool {
        return if (a.dist != b.dist) a.dist < b.dist else a.id < b.id;
    }
};

fn hitLessThan(_: void, a: Hit, b: Hit) bool {
    return a.lessThan(b);
}

/// Squared Euclidean distance. Squared, because sqrt is monotonic: it would
/// change no comparison and would bring floating point in.
pub fn dist2(a: []const i32, b: []const i32) u64 {
    std.debug.assert(a.len == b.len);
    var sum: u64 = 0;
    for (a, b) |x, y| {
        const d: i64 = @as(i64, x) - y;
        sum += @intCast(d * d);
    }
    return sum;
}

/// Offer `hit` to the sorted top-k buffer `out[0..len]`; returns the new len.
/// k is small, so insertion into a sorted array beats a heap here.
pub fn topkOffer(out: []Hit, len: usize, hit: Hit) usize {
    if (len == out.len and !hit.lessThan(out[len - 1])) return len;
    var i = if (len < out.len) len else len - 1; // slot that opens up
    while (i > 0 and hit.lessThan(out[i - 1])) : (i -= 1) out[i] = out[i - 1];
    out[i] = hit;
    return @min(len + 1, out.len);
}

/// Brute force ("flat index"): the exact answer and the yardstick for recall.
/// `data` holds n vectors of `dim` coordinates back to back.
pub fn flatSearch(data: []const i32, dim: usize, query: []const i32, out: []Hit) usize {
    var len: usize = 0;
    var id: u32 = 0;
    while (id * dim < data.len) : (id += 1) {
        len = topkOffer(out, len, .{ .dist = dist2(data[id * dim ..][0..dim], query), .id = id });
    }
    return len;
}

/// How many of `got` also appear in the exact answer `want`.
pub fn overlap(got: []const Hit, want: []const Hit) u32 {
    var n: u32 = 0;
    for (got) |g| for (want) |w| {
        if (g.id == w.id) n += 1;
    };
    return n;
}

pub const SearchStats = struct {
    lists_probed: u32 = 0,
    /// Distance computations against stored vectors (not centroids).
    vectors_scanned: u32 = 0,
    hits: usize = 0,
};

pub const Ivf = struct {
    dim: usize,
    nlist: usize,
    /// nlist * dim coordinates: the "root node".
    centroids: []i32,
    /// List c owns positions list_offsets[c] .. list_offsets[c + 1] of `ids`
    /// and `vecs` (CSR layout: no pointer per list, no pointer per vector).
    list_offsets: []u32,
    ids: []u32,
    /// Vectors copied next to their list, so scanning a list is one
    /// sequential pass over memory, like scanning a leaf page.
    vecs: []i32,
    /// id -> list, kept for validate() and for explaining misses.
    assign: []u32,
    /// Centroid updates performed before assignments stopped changing.
    iterations: u32,

    /// Train with k-means (Lloyd's algorithm) and fill the lists.
    ///
    /// Memory: the five slices of the result come from `gpa` and live as long
    /// as the index. Everything k-means needs only while it runs (the shuffle
    /// used to pick starting centroids, per-centroid sums and counts) comes
    /// from an arena that is dropped on return, on success and on error.
    pub fn build(gpa: Allocator, data: []const i32, dim: usize, nlist: usize, seed: u64, max_iter: u32) Allocator.Error!Ivf {
        std.debug.assert(dim > 0 and data.len % dim == 0);
        const n = data.len / dim;
        std.debug.assert(nlist > 0 and nlist <= n);

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const scratch = arena_state.allocator();

        const centroids = try gpa.alloc(i32, nlist * dim);
        errdefer gpa.free(centroids);
        const assign = try gpa.alloc(u32, n);
        errdefer gpa.free(assign);
        const list_offsets = try gpa.alloc(u32, nlist + 1);
        errdefer gpa.free(list_offsets);
        const ids = try gpa.alloc(u32, n);
        errdefer gpa.free(ids);
        const vecs = try gpa.alloc(i32, n * dim);
        errdefer gpa.free(vecs);

        // 1. Starting centroids: nlist distinct data points, chosen by a
        //    seeded shuffle of the ids.
        const perm = try scratch.alloc(u64, n);
        for (perm, 0..) |*p, i| p.* = i;
        var rng = SplitMix64.init(seed);
        rng.shuffle(perm);
        for (0..nlist) |c| {
            const src: usize = @intCast(perm[c]);
            @memcpy(centroids[c * dim ..][0..dim], data[src * dim ..][0..dim]);
        }

        // 2. Lloyd iterations: assign every vector to its nearest centroid,
        //    then move each centroid to the mean of its vectors. The loop
        //    always exits right after an assignment step, so on exit every
        //    vector is in the list of its nearest centroid (see validate).
        const sums = try scratch.alloc(i64, nlist * dim);
        const counts = try scratch.alloc(u32, nlist);
        @memset(assign, std.math.maxInt(u32));
        var iterations: u32 = 0;
        while (true) {
            var changed: usize = 0;
            for (0..n) |i| {
                const c = nearestCentroid(centroids, dim, data[i * dim ..][0..dim]);
                if (assign[i] != c) changed += 1;
                assign[i] = c;
            }
            if (changed == 0 or iterations == max_iter) break;
            @memset(sums, 0);
            @memset(counts, 0);
            for (0..n) |i| {
                const c = assign[i];
                counts[c] += 1;
                for (0..dim) |j| sums[c * dim + j] += data[i * dim + j];
            }
            for (0..nlist) |c| {
                if (counts[c] == 0) continue; // empty cell: leave its centroid where it is
                const cnt: i64 = counts[c];
                // Mean rounded to the nearest integer, in integers only.
                for (0..dim) |j| centroids[c * dim + j] = @intCast(@divFloor(2 * sums[c * dim + j] + cnt, 2 * cnt));
            }
            iterations += 1;
        }

        // 3. Counting sort of the ids by list: offsets first, then fill.
        //    Ids stay ascending inside each list.
        @memset(list_offsets, 0);
        for (assign) |c| list_offsets[c + 1] += 1;
        for (0..nlist) |c| list_offsets[c + 1] += list_offsets[c];
        const cursor = try scratch.dupe(u32, list_offsets[0..nlist]);
        for (assign, 0..) |c, i| {
            const pos = cursor[c];
            cursor[c] += 1;
            ids[pos] = @intCast(i);
            @memcpy(vecs[pos * dim ..][0..dim], data[i * dim ..][0..dim]);
        }

        return .{
            .dim = dim,
            .nlist = nlist,
            .centroids = centroids,
            .list_offsets = list_offsets,
            .ids = ids,
            .vecs = vecs,
            .assign = assign,
            .iterations = iterations,
        };
    }

    pub fn deinit(self: *Ivf, gpa: Allocator) void {
        gpa.free(self.centroids);
        gpa.free(self.list_offsets);
        gpa.free(self.ids);
        gpa.free(self.vecs);
        gpa.free(self.assign);
        self.* = undefined;
    }

    pub fn centroid(self: *const Ivf, c: usize) []const i32 {
        return self.centroids[c * self.dim ..][0..self.dim];
    }

    pub fn listLen(self: *const Ivf, c: usize) u32 {
        return self.list_offsets[c + 1] - self.list_offsets[c];
    }

    /// Rank all centroids by distance to `query` into `order` (len nlist).
    /// This is the routing step. Compare with a B-tree: there it is a binary
    /// search over sorted separators; here it is a scan, because centroids
    /// have no order that a query could be compared against.
    pub fn rankLists(self: *const Ivf, query: []const i32, order: []Hit) void {
        for (order, 0..) |*o, c| o.* = .{ .dist = dist2(self.centroid(c), query), .id = @intCast(c) };
        std.mem.sort(Hit, order, {}, hitLessThan);
    }

    /// Approximate k nearest neighbours (k = out.len): scan the `nprobe`
    /// lists whose centroids are nearest to the query. `scratch` provides
    /// the ranking buffer; pass an arena and reset it between queries.
    pub fn search(self: *const Ivf, scratch: Allocator, query: []const i32, nprobe: usize, out: []Hit) Allocator.Error!SearchStats {
        const order = try scratch.alloc(Hit, self.nlist);
        self.rankLists(query, order);
        var stats: SearchStats = .{};
        for (order[0..@min(nprobe, self.nlist)]) |list| {
            stats.lists_probed += 1;
            for (self.list_offsets[list.id]..self.list_offsets[list.id + 1]) |pos| {
                const d = dist2(self.vecs[pos * self.dim ..][0..self.dim], query);
                stats.vectors_scanned += 1;
                stats.hits = topkOffer(out, stats.hits, .{ .dist = d, .id = self.ids[pos] });
            }
        }
        return stats;
    }

    /// Invariants: the lists partition the ids (each id once, ascending
    /// inside a list); each stored vector is a copy of the original; and each
    /// vector is in the list of its nearest centroid.
    pub fn validate(self: *const Ivf, data: []const i32) error{Invalid}!void {
        const n = self.ids.len;
        if (data.len != n * self.dim or self.list_offsets[0] != 0 or self.list_offsets[self.nlist] != n) return error.Invalid;
        for (0..self.nlist) |c| {
            if (self.list_offsets[c] > self.list_offsets[c + 1]) return error.Invalid;
            for (self.list_offsets[c]..self.list_offsets[c + 1]) |pos| {
                const id = self.ids[pos];
                if (id >= n or self.assign[id] != c) return error.Invalid;
                if (pos > self.list_offsets[c] and self.ids[pos - 1] >= id) return error.Invalid;
                const v = self.vecs[pos * self.dim ..][0..self.dim];
                if (!std.mem.eql(i32, v, data[id * self.dim ..][0..self.dim])) return error.Invalid;
                if (nearestCentroid(self.centroids, self.dim, v) != c) return error.Invalid;
            }
        }
        // Why this proves "each id exactly once": an id can only sit in list
        // assign[id], at most once there (strictly ascending), and there are
        // exactly n positions for n possible ids.
    }
};

/// Index of the centroid nearest to `v`; the lowest index wins a tie.
fn nearestCentroid(centroids: []const i32, dim: usize, v: []const i32) u32 {
    var best: Hit = .{ .dist = std.math.maxInt(u64), .id = 0 };
    var c: u32 = 0;
    while (c * dim < centroids.len) : (c += 1) {
        const h: Hit = .{ .dist = dist2(centroids[c * dim ..][0..dim], v), .id = c };
        if (h.lessThan(best)) best = h;
    }
    return best.id;
}

// ---------------------------------------------------------------------------
const testing = std.testing;

fn randomData(gpa: Allocator, rng: *SplitMix64, n: usize, dim: usize, limit: u64) ![]i32 {
    const data = try gpa.alloc(i32, n * dim);
    for (data) |*x| x.* = @intCast(rng.below(limit));
    return data;
}

test "dist2 and topkOffer" {
    try testing.expectEqual(25, dist2(&.{ 0, 0 }, &.{ 3, 4 }));
    try testing.expectEqual(4, dist2(&.{ -1, 5 }, &.{ 1, 5 }));
    var out: [3]Hit = undefined;
    var len: usize = 0;
    for ([_]u64{ 50, 10, 40, 10, 60, 5 }, 0..) |d, id| len = topkOffer(&out, len, .{ .dist = d, .id = @intCast(id) });
    try testing.expectEqual(3, len);
    // Sorted by distance; the tie at 10 is broken by the smaller id.
    try testing.expectEqualSlices(Hit, &.{ .{ .dist = 5, .id = 5 }, .{ .dist = 10, .id = 1 }, .{ .dist = 10, .id = 3 } }, &out);
}

test "1-D: the nearest neighbour is the predecessor or the successor" {
    // With one dimension a sorted array answers nearest-neighbour exactly by
    // looking at two slots. This is the last dimension where that works.
    const gpa = testing.allocator;
    var rng = SplitMix64.init(1);
    const data = try randomData(gpa, &rng, 300, 1, 10_000);
    defer gpa.free(data);
    const sorted = try gpa.dupe(i32, data);
    defer gpa.free(sorted);
    std.mem.sort(i32, sorted, {}, std.sort.asc(i32));
    for (0..200) |_| {
        const q: i32 = @intCast(rng.below(10_000));
        var best: [1]Hit = undefined;
        _ = flatSearch(data, 1, &.{q}, &best);
        const i = std.sort.lowerBound(i32, sorted, q, struct {
            fn order(ctx: i32, item: i32) std.math.Order {
                return std.math.order(ctx, item);
            }
        }.order);
        var d: u64 = std.math.maxInt(u64);
        if (i < sorted.len) d = @min(d, dist2(&.{sorted[i]}, &.{q}));
        if (i > 0) d = @min(d, dist2(&.{sorted[i - 1]}, &.{q}));
        try testing.expectEqual(best[0].dist, d);
    }
}

test "model test: probing every list equals brute force; recall grows with nprobe" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var rng = SplitMix64.init(2929);
    for (0..12) |round| {
        const dim: usize = @intCast(1 + rng.below(6));
        const n: usize = @intCast(20 + rng.below(300));
        const nlist: usize = @intCast(1 + rng.below(12));
        // Small coordinate range on some rounds forces duplicate points,
        // equal distances and empty cells.
        const data = try randomData(gpa, &rng, n, dim, if (round % 3 == 0) 4 else 500);
        defer gpa.free(data);
        var index = try Ivf.build(gpa, data, dim, nlist, rng.nextU64(), 20);
        defer index.deinit(gpa);
        try index.validate(data);

        const query = try gpa.alloc(i32, dim);
        defer gpa.free(query);
        var want: [7]Hit = undefined;
        var got: [7]Hit = undefined;
        for (0..20) |_| {
            for (query) |*x| x.* = @intCast(rng.below(500));
            const want_len = flatSearch(data, dim, query, &want);
            var prev_overlap: u32 = 0;
            var prev_scanned: u32 = 0;
            for (1..nlist + 1) |nprobe| {
                _ = arena_state.reset(.retain_capacity);
                const stats = try index.search(arena_state.allocator(), query, nprobe, &got);
                const o = overlap(got[0..stats.hits], want[0..want_len]);
                try testing.expect(o >= prev_overlap); // more lists never hurt
                try testing.expect(stats.vectors_scanned >= prev_scanned);
                prev_overlap = o;
                prev_scanned = stats.vectors_scanned;
                if (nprobe == nlist) {
                    // All lists probed: the index degenerates to brute force.
                    try testing.expectEqual(n, stats.vectors_scanned);
                    try testing.expectEqualSlices(Hit, want[0..want_len], got[0..stats.hits]);
                }
            }
        }
    }
}

test "validate catches a vector filed under the wrong centroid" {
    const gpa = testing.allocator;
    var rng = SplitMix64.init(5);
    const data = try randomData(gpa, &rng, 100, 2, 1000);
    defer gpa.free(data);
    var index = try Ivf.build(gpa, data, 2, 4, 7, 20);
    defer index.deinit(gpa);
    try index.validate(data);
    // Move centroid 0 far away: its vectors are now nearer to other centroids.
    index.centroids[0] += 100_000;
    try testing.expectError(error.Invalid, index.validate(data));
}

fn buildAndSearch(gpa: Allocator, data: []const i32) !void {
    var index = try Ivf.build(gpa, data, 2, 5, 3, 10);
    defer index.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var out: [3]Hit = undefined;
    _ = try index.search(arena_state.allocator(), &.{ 10, 10 }, 2, &out);
}

test "build and search under allocation failure leak nothing" {
    var rng = SplitMix64.init(9);
    const data = try randomData(testing.allocator, &rng, 60, 2, 100);
    defer testing.allocator.free(data);
    try testing.checkAllAllocationFailures(testing.allocator, buildAndSearch, .{@as([]const i32, data)});
}

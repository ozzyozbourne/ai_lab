//! Chapter 01: why B-trees.
//!
//! `zig build run` prints a fixed, deterministic scenario that compares three
//! ways of keeping keys findable (one sorted array, a binary search tree, and
//! wide nodes) by the measure that matters for a database: page reads.
//! The output is exactly ../expected_output.txt; the Rust program prints the
//! same bytes.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cost = @import("cost.zig");
const height = @import("height.zig");
const wide = @import("wide.zig");
const SortedArrayMap = @import("sorted_array.zig").SortedArrayMap;
const Bst = @import("bst.zig").Bst;
const SplitMix64 = @import("prng.zig").SplitMix64;

const Entry = cost.Entry;

/// The guide's canonical keys (chapters 03 to 08 insert the same sequence).
const canonical = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout: *Io.Writer = &stdout_file_writer.interface;
    try report(init.gpa, stdout);
    try stdout.flush();
}

/// Everything the program prints. Takes the writer so that a test can
/// capture the text and compare it with expected_output.txt.
pub fn report(gpa: Allocator, w: *Io.Writer) !void {
    try w.writeAll("Chapter 01: why B-trees\n");
    try w.print("Cost model: count page reads ({d}-byte pages, {d} entries each), not comparisons.\n", .{ cost.page_size, cost.entries_per_page });
    try handExample(gpa, w);
    try whereTheBytesLive(w);
    try race(gpa, w);
    try priceOfInserts(gpa, w);
    try heightTable(w);
}

// ---- 1 --------------------------------------------------------------------

fn handExample(gpa: Allocator, w: *Io.Writer) !void {
    try w.writeAll("\n== 1. Hand example: 12 keys ==\n");
    try w.writeAll("insert order:");
    for (canonical) |k| try w.print(" {d}", .{k});
    try w.writeAll("\n");

    // Sorted array. 12 entries need 192 bytes: a stack buffer is plenty, and
    // FixedBufferAllocator hands out pieces of it without any system call.
    var buffer: [16 * @sizeOf(Entry)]u8 align(@alignOf(Entry)) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    var array: SortedArrayMap = .empty; // no deinit: the memory is `buffer`
    for (canonical) |k| _ = try array.put(fba.allocator(), k, k * 10);
    try array.validate();
    try w.writeAll("sorted array:");
    for (array.items()) |e| try w.print(" {d}", .{e.key});
    try w.print("\n  entries shifted by the 12 puts: {d}\n", .{array.moves});
    var trace: cost.Trace = .{};
    _ = array.getTraced(17, &trace);
    try w.print("  get(17): {d} comparisons, {d} page read\n", .{ trace.comparisons, trace.page_reads });

    // BST, same insert order.
    var tree: Bst = .empty;
    defer tree.deinit(gpa);
    for (canonical) |k| _ = try tree.put(gpa, k, k * 10);
    try tree.validate();
    trace = .{};
    _ = tree.getTraced(17, &trace);
    try w.print("BST, same insert order: height {d}\n", .{tree.height()});
    try w.print("  get(17): {d} comparisons, {d} page reads\n", .{ trace.comparisons, trace.page_reads });

    // BST fed the keys in ascending order: a linked list.
    var chain: Bst = .empty;
    defer chain.deinit(gpa);
    for (array.items()) |e| _ = try chain.put(gpa, e.key, e.value);
    trace = .{};
    _ = chain.getTraced(30, &trace);
    try w.print("BST, ascending insert order: height {d}\n", .{chain.height()});
    try w.print("  get(30): {d} comparisons, {d} page reads\n", .{ trace.comparisons, trace.page_reads });

    // Wide nodes of order 4 laid over the sorted array.
    trace = .{};
    _ = wide.getTraced(array.items(), 4, 17, &trace);
    try w.print("wide nodes, M = 4 (at most 3 keys per node): height {d}\n", .{height.minHeight(array.len, 4)});
    try w.print("  get(17): {d} comparisons, {d} page reads\n", .{ trace.comparisons, trace.page_reads });
}

// ---- 2 --------------------------------------------------------------------

fn whereTheBytesLive(w: *Io.Writer) !void {
    try w.writeAll("\n== 2. Where the bytes live ==\n");

    // A sorted array is one contiguous block. On a fixed buffer it can grow
    // only until the buffer is used up.
    var buffer: [16 * @sizeOf(Entry)]u8 align(@alignOf(Entry)) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    var array: SortedArrayMap = .empty;
    var fitted: u64 = 0;
    var failed_at: u64 = 0;
    for (1..40) |i| {
        _ = array.put(fba.allocator(), i, i) catch {
            failed_at = i;
            break;
        };
        fitted += 1;
    }
    try w.print("sorted array in a {d}-byte stack buffer: {d} entries fit, put #{d} fails, len stays {d}\n", .{ buffer.len, fitted, failed_at, array.len });
    try w.print("  12 entries are {d} contiguous bytes: less than one page\n", .{12 * @sizeOf(Entry)});

    // A tree node can be anywhere. page_allocator makes the worst case
    // real: every allocation is a fresh mapping of at least one page, so
    // each pointer hop of a lookup lands on a different page of memory.
    const page_allocator = std.heap.page_allocator;
    var tree: Bst = .empty;
    defer tree.deinit(page_allocator);
    for (canonical) |k| _ = try tree.put(page_allocator, k, k * 10);
    var trace: cost.Trace = .{};
    _ = tree.getTraced(17, &trace);
    try w.print("BST with one page per node: {d} nodes; get(17) visits {d} nodes on {d} distinct pages of memory\n", .{ tree.len, trace.page_reads, tree.pagesOnPath(17) });
}

// ---- 3 --------------------------------------------------------------------

const race_keys = 100_000;
const race_lookups = 1000;

/// Sum and maximum of one counter over many lookups.
const Tally = struct {
    total: u64 = 0,
    max: u64 = 0,
    fn add(self: *Tally, x: u64) void {
        self.total += x;
        self.max = @max(self.max, x);
    }
};

const Lane = struct {
    comparisons: Tally = .{},
    page_reads: Tally = .{},
    fn add(self: *Lane, trace: cost.Trace) void {
        self.comparisons.add(trace.comparisons);
        self.page_reads.add(trace.page_reads);
    }
};

fn race(gpa: Allocator, w: *Io.Writer) !void {
    try w.print("\n== 3. Race: {d} keys, {d} lookups ==\n", .{ race_keys, race_lookups });

    // Keys 10, 20, ..., 1000000 in a random order.
    const keys = try gpa.alloc(u64, race_keys);
    defer gpa.free(keys);
    for (keys, 0..) |*k, i| k.* = (i + 1) * 10;
    var rng = SplitMix64.init(2024);
    rng.shuffle(keys);

    const unsorted = try gpa.alloc(Entry, race_keys);
    defer gpa.free(unsorted);
    for (unsorted, keys) |*e, k| e.* = .{ .key = k, .value = k + 1 };

    var array = try SortedArrayMap.initFromEntries(gpa, unsorted);
    defer array.deinit(gpa);
    var tree: Bst = .empty;
    defer tree.deinit(gpa);
    for (unsorted) |e| _ = try tree.put(gpa, e.key, e.value);
    try tree.validate();

    // The order of a node that fills one page: 170 entries + 171 pointers.
    const m = height.orderForPage(cost.page_size, @sizeOf(Entry), @sizeOf(u64));

    var array_lane: Lane = .{};
    var tree_lane: Lane = .{};
    var wide_lane: Lane = .{};
    var found: u64 = 0;
    for (0..race_lookups) |_| {
        // Half of the lookups ask for a key that exists.
        const key = if (rng.chance(1, 2)) (rng.below(race_keys) + 1) * 10 else rng.below(race_keys * 10 + 10);
        var a: cost.Trace = .{};
        var t: cost.Trace = .{};
        var b: cost.Trace = .{};
        const from_array = array.getTraced(key, &a);
        const from_tree = tree.getTraced(key, &t);
        const from_wide = wide.getTraced(array.items(), m, key, &b);
        // Three structures, one answer.
        if (from_array != from_tree or from_array != from_wide) return error.StructuresDisagree;
        if (from_array != null) found += 1;
        array_lane.add(a);
        tree_lane.add(t);
        wide_lane.add(b);
    }
    try w.print("lookups that found their key: {d}\n", .{found});
    try w.writeAll("                               comparisons      page reads\n");
    try w.writeAll("structure                      avg      max     avg      max\n");
    try printLane(w, "sorted array, 256 per page", array_lane);
    try printLane(w, "BST, random insert order", tree_lane);
    try printLane(w, "wide nodes, M = 171", wide_lane);
    try w.print("heights: BST {d}, wide nodes {d}; the sorted array spans {d} pages\n", .{
        tree.height(),
        height.minHeight(race_keys, m),
        (race_keys + cost.entries_per_page - 1) / cost.entries_per_page,
    });

    // The same BST fed sorted keys is hopeless; 2000 keys are enough to see it.
    var chain: Bst = .empty;
    defer chain.deinit(gpa);
    for (0..2000) |i| _ = try chain.put(gpa, (i + 1) * 10, i);
    var worst: cost.Trace = .{};
    _ = chain.getTraced(2000 * 10, &worst);
    try w.print("BST, 2000 keys in ascending order: height {d}, get(largest) reads {d} pages\n", .{ chain.height(), worst.page_reads });
}

fn printLane(w: *Io.Writer, name: []const u8, lane: Lane) !void {
    try w.print("{s:<28}", .{name});
    try printAverage(w, lane.comparisons.total);
    try w.print(" {d:>8}", .{lane.comparisons.max});
    try printAverage(w, lane.page_reads.total);
    try w.print(" {d:>8}\n", .{lane.page_reads.max});
}

/// Print total / race_lookups with two decimals, using integers only so that
/// Zig and Rust cannot round differently.
fn printAverage(w: *Io.Writer, total: u64) !void {
    const hundredths = total * 100 / race_lookups;
    try w.print(" {d:>5}.{d:0>2}", .{ hundredths / 100, hundredths % 100 });
}

// ---- 4 --------------------------------------------------------------------

fn priceOfInserts(gpa: Allocator, w: *Io.Writer) !void {
    try w.print("\n== 4. The price of one flat array: a single put into {d} keys ==\n", .{race_keys});
    const unsorted = try gpa.alloc(Entry, race_keys);
    defer gpa.free(unsorted);
    for (unsorted, 0..) |*e, i| e.* = .{ .key = (i + 1) * 10, .value = i };
    var array = try SortedArrayMap.initFromEntries(gpa, unsorted);
    defer array.deinit(gpa);

    const Case = struct { name: []const u8, key: u64 };
    const cases = [_]Case{
        .{ .name = "larger than every key", .key = race_keys * 10 + 5 },
        .{ .name = "in the middle", .key = race_keys * 5 + 5 },
        .{ .name = "smaller than every key", .key = 5 },
    };
    for (cases) |case| {
        const moves_before = array.moves;
        const writes_before = array.page_writes;
        _ = try array.put(gpa, case.key, 0);
        try w.print("sorted array, new key {s:<23}: {d:>6} entries shifted, {d:>3} pages rewritten\n", .{
            case.name, array.moves - moves_before, array.page_writes - writes_before,
        });
        _ = array.delete(case.key); // back to exactly race_keys entries
    }
    try w.writeAll("BST, any new key: 1 node written, 1 pointer changed (after the page reads to find the place)\n");

    // A one-level fix: cut the array into page-sized chunks and keep a
    // directory with one slot per chunk. Inserting now shifts one chunk only,
    // but the directory is itself a sorted array with one slot per page.
    try w.writeAll("one level of chunks plus a directory (8 bytes per chunk):\n");
    try w.writeAll("          keys       chunks  directory pages\n");
    var n: u64 = 1000;
    while (n <= 1_000_000_000_000) : (n *= 1000) {
        const chunks = (n + cost.entries_per_page - 1) / cost.entries_per_page;
        const directory_pages = (chunks * 8 + cost.page_size - 1) / cost.page_size;
        try w.print("{d:>14} {d:>12} {d:>16}\n", .{ n, chunks, directory_pages });
    }
}

// ---- 5 --------------------------------------------------------------------

fn heightTable(w: *Io.Writer) !void {
    try w.writeAll("\n== 5. Height calculator: page reads per lookup ==\n");
    try w.writeAll("          keys   binary best   M = 4 best   worst   M = 171 best   worst\n");
    var n: u64 = 1000;
    while (n <= 1_000_000_000_000) : (n *= 1000) {
        try w.print("{d:>14} {d:>13} {d:>12} {d:>7} {d:>14} {d:>7}\n", .{
            n,
            height.minHeight(n, 2),
            height.minHeight(n, 4),
            height.maxHeight(n, 4),
            height.minHeight(n, 171),
            height.maxHeight(n, 171),
        });
    }
}

// ----------------------------------------------------------------- tests ---

test {
    // Reach the tests of every file (see ZIG_CHEATSHEET section 1).
    _ = @import("cost.zig");
    _ = @import("height.zig");
    _ = @import("wide.zig");
    _ = @import("sorted_array.zig");
    _ = @import("bst.zig");
    _ = @import("prng.zig");
    _ = @import("ops.zig");
}

test "run prints exactly expected_output.txt" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try report(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}

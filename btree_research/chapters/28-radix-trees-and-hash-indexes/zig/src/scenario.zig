//! The fixed scenario printed by `zig build run` (and by the Rust twin).
//! Everything is deterministic: keys come from SplitMix64 with fixed seeds.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const keys = @import("keys.zig");
const art = @import("art.zig");
const Art = art.Art;
const HashIndex = @import("hash_index.zig").HashIndex;
const entryLessThan = @import("hash_index.zig").entryLessThan;
const SortedIndex = @import("sorted_index.zig").SortedIndex;
const SplitMix64 = @import("prng.zig").SplitMix64;

pub fn run(gpa: Allocator, w: *Writer) !void {
    // Scratch space for encoded keys; everything in it dies together at the end.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();

    try pathCompression(gpa, scratch, w);
    try fourLayouts(gpa, w);
    try denseAndSparse(gpa, w);
    try threeIndexes(gpa, scratch, w);
}

fn printCensus(w: *Writer, tree: *const Art) !void {
    const c = tree.census();
    try w.print("nodes: prefix={d} node4={d} node16={d} node48={d} node256={d}; leaves={d}; longest path={d} nodes\n", .{
        c.nodes[0], c.nodes[1], c.nodes[2], c.nodes[3], c.nodes[4], c.leaves, c.max_path,
    });
}

/// Section 1: the classic radix-tree words. Each string is encoded with a
/// 0x00 terminator, which shows up in the dumps as \x00.
fn pathCompression(gpa: Allocator, scratch: Allocator, w: *Writer) !void {
    try w.writeAll("== 1. Path compression and prefix splits ==\n");
    var tree: Art = .init(gpa);
    defer tree.deinit();
    const words = [_][]const u8{ "romane", "romanus", "romulus", "rubens", "ruber", "rubicon", "rubicundus" };
    for (words, 1..) |word, value| {
        _ = try tree.put(try keys.encodeStr(scratch, word), value);
        try tree.validate();
        // Show the tree after each of the first three keys, then at the end.
        if (value <= 3 or value == words.len) {
            if (value <= 3) {
                try w.print("put \"{s}\" = {d}\n", .{ word, value });
            } else {
                try w.writeAll("put \"rubens\" = 4, \"ruber\" = 5, \"rubicon\" = 6, \"rubicundus\" = 7\n");
            }
            try tree.dump(w);
        }
    }
    try printCensus(w, &tree);
    try w.print("prefix splits: {d}\n", .{tree.prefix_splits});

    try w.writeAll("keys in order:");
    var it = tree.iterator(gpa);
    defer it.deinit();
    while (try it.next()) |e| {
        try w.writeAll(" ");
        try keys.writeBytes(w, e.key[0 .. e.key.len - 1]); // drop the terminator
    }
    try w.writeAll("\n");

    const lo = "rube"; // a raw byte bound: no terminator, not a stored key
    try it.seek(lo);
    const first = (try it.next()).?;
    try w.print("first key >= \"{s}\": ", .{lo});
    try keys.writeBytes(w, first.key[0 .. first.key.len - 1]);
    try w.print(" = {d}\n\n", .{first.value});
}

/// Section 2: 256 two-byte keys 'k', b. All of them branch at the same node
/// (below the prefix "k"), which therefore has to take every layout in turn.
fn fourLayouts(gpa: Allocator, w: *Writer) !void {
    try w.writeAll("== 2. One node through four layouts ==\n");
    var tree: Art = .init(gpa);
    defer tree.deinit();
    var bytes: [256]u64 = undefined;
    for (&bytes, 0..) |*b, i| b.* = i;
    var rng = SplitMix64.init(28);
    rng.shuffle(&bytes);

    try w.writeAll("  keys  layout   slots used/reserved  event\n");
    var last_kind: ?usize = null;
    for (bytes, 1..) |b, n| {
        const key = [2]u8{ 'k', @intCast(b) };
        _ = try tree.put(&key, n);
        const c = tree.census();
        // Exactly one inner node exists; find which layout it has now.
        var kind: ?usize = null;
        for (1..art.kind_count) |k| {
            if (c.nodes[k] == 1) kind = k;
        }
        if (n == 1 or kind != last_kind or n == bytes.len) {
            try w.print("  {d:>4}  {s:<7}  {d:>3}/{d:<3}", .{ n, if (kind) |k| art.kind_names[k] else "(none)", c.slots_used, c.slots_allocated });
            if (kind == null) {
                try w.writeAll("              one key: a prefix chain, no inner node yet\n");
            } else if (last_kind == null) {
                try w.writeAll("              second key splits the prefix\n");
            } else if (kind != last_kind) {
                try w.print("              {s} was full: copied into a {s} for byte 0x{x:0>2}\n", .{ art.kind_names[last_kind.?], art.kind_names[kind.?], b });
            } else {
                try w.writeAll("              every byte has its own slot\n");
            }
            last_kind = kind;
        }
    }
    try tree.validate();
    try w.print("grow steps: node4->node16 {d}, node16->node48 {d}, node48->node256 {d}\n", .{ tree.grows[0], tree.grows[1], tree.grows[2] });
    try w.writeAll("pool     created  live\n");
    for (art.kind_names, tree.pools.created, tree.pools.live) |name, created, live| {
        try w.print("{s:<8} {d:>7}  {d:>4}\n", .{ name, created, live });
    }
    try w.writeAll("\n");
}

/// Section 3: the same number of 8-byte integer keys, once dense (0..999) and
/// once spread over the whole u64 range.
fn denseAndSparse(gpa: Allocator, w: *Writer) !void {
    try w.writeAll("== 3. Dense and sparse integer keys (1000 each, 8 bytes big-endian) ==\n");
    try w.writeAll("         prefix  node4  node16  node48  node256  slots used/reserved  longest path  nodes visited by 1000 gets\n");
    var rng = SplitMix64.init(2828);
    for ([_][]const u8{ "dense", "sparse" }, 0..) |name, which| {
        var tree: Art = .init(gpa);
        defer tree.deinit();
        var stored: [1000]u64 = undefined;
        for (&stored, 0..) |*k, i| {
            k.* = if (which == 0) i else rng.nextU64();
            _ = try tree.put(&keys.encodeU64(k.*), i);
        }
        try tree.validate();
        var steps: u64 = 0;
        for (stored, 0..) |k, i| {
            const found = tree.lookup(&keys.encodeU64(k));
            std.debug.assert(found.value.? == i);
            steps += found.steps;
        }
        const c = tree.census();
        try w.print("{s:<7}  {d:>6}  {d:>5}  {d:>6}  {d:>6}  {d:>7}  {d:>9}/{d:<9}  {d:>12}  {d:>26}\n", .{
            name,         c.nodes[0],        c.nodes[1], c.nodes[2], c.nodes[3], c.nodes[4],
            c.slots_used, c.slots_allocated, c.max_path, steps,
        });
    }
    try w.writeAll("\n");
}

/// Collect values from the ART: keys >= lo that are < hi (if given) and start
/// with `prefix` (if given). The iterator yields them in key order.
fn artCollect(gpa: Allocator, tree: *const Art, lo: []const u8, hi: ?[]const u8, prefix: ?[]const u8, out: *std.ArrayList(u64)) !void {
    var it = tree.iterator(gpa);
    defer it.deinit();
    try it.seek(lo);
    while (try it.next()) |e| {
        if (hi) |h| {
            if (!std.mem.lessThan(u8, e.key, h)) break;
        }
        if (prefix) |p| {
            if (!std.mem.startsWith(u8, e.key, p)) break;
        }
        try out.append(gpa, e.value);
    }
}

fn sameValues(entries: []const keys.Entry, values: []const u64) bool {
    if (entries.len != values.len) return false;
    for (entries, values) |e, v| {
        if (e.value != v) return false;
    }
    return true;
}

fn isSorted(entries: []const keys.Entry) bool {
    for (1..entries.len) |i| {
        if (!std.mem.lessThan(u8, entries[i - 1].key, entries[i].key)) return false;
    }
    return true;
}

/// One ordered query (a byte range [lo, hi)) answered by all three indexes.
fn compareQuery(
    gpa: Allocator,
    w: *Writer,
    tree: *const Art,
    hash: *const HashIndex,
    want: []const keys.Entry,
    lo: []const u8,
    hi: []const u8,
    prefix: ?[]const u8,
) !void {
    try w.print("  sorted array  {d:>3} entries in key order (a slice between two binary searches)\n", .{want.len});

    var values: std.ArrayList(u64) = .empty;
    defer values.deinit(gpa);
    try artCollect(gpa, tree, lo, if (prefix == null) hi else null, prefix, &values);
    try w.print("  art           {d:>3} entries in key order (seek, then iterate); same as sorted: {}\n", .{ values.items.len, sameValues(want, values.items) });

    var found: std.ArrayList(keys.Entry) = .empty;
    defer found.deinit(gpa);
    const inspected = try hash.scanRange(gpa, lo, hi, &found);
    const ordered_before = isSorted(found.items);
    std.mem.sort(keys.Entry, found.items, {}, entryLessThan);
    values.clearRetainingCapacity();
    for (found.items) |e| try values.append(gpa, e.value);
    try w.print("  hash index    {d:>3} entries after inspecting all {d} slots; in key order: {}; same as sorted after sorting: {}\n", .{
        found.items.len, inspected, ordered_before, sameValues(want, values.items),
    });
}

/// Section 4: one data set, three indexes, four kinds of question.
fn threeIndexes(gpa: Allocator, scratch: Allocator, w: *Writer) !void {
    try w.writeAll("== 4. Same data in a sorted array, an ART and a hash index ==\n");
    var sorted: SortedIndex = .init(gpa);
    defer sorted.deinit();
    var tree: Art = .init(gpa);
    defer tree.deinit();
    var hash: HashIndex = .init(gpa);
    defer hash.deinit();

    // Keys look like "cat/0042": a tenant name, a slash, a 4-digit id.
    const tenants = [_][]const u8{ "ant", "bee", "cat", "dog", "eel", "fox" };
    var rng = SplitMix64.init(4);
    for (0..600) |i| {
        const tenant = tenants[@intCast(rng.below(tenants.len))];
        const id = rng.below(10_000);
        const text = try std.fmt.allocPrint(scratch, "{s}/{d:0>4}", .{ tenant, id });
        const key = try keys.encodeStr(scratch, text);
        const a = try sorted.put(key, i);
        const b = try tree.put(key, i);
        const c = try hash.put(key, i);
        std.debug.assert(a == b and b == c);
    }
    try sorted.validate();
    try tree.validate();
    try hash.validate();
    try w.print("600 puts, {d} distinct keys such as \"cat/0042\"; hash table capacity {d}\n", .{ sorted.len(), hash.capacity() });
    try printCensus(w, &tree);

    // Point lookups: every stored key, then 300 keys that cannot exist
    // (5-digit ids).
    var steps = [3]u64{ 0, 0, 0 };
    var found = [3]usize{ 0, 0, 0 };
    for (sorted.entries.items) |e| {
        const results = [3]keys.Lookup{ sorted.lookup(e.key), tree.lookup(e.key), hash.lookup(e.key) };
        for (results, 0..) |r, k| {
            steps[k] += r.steps;
            if (r.value == e.value) found[k] += 1;
        }
    }
    const hits = sorted.len();
    for (0..300) |_| {
        const tenant = tenants[@intCast(rng.below(tenants.len))];
        const text = try std.fmt.allocPrint(scratch, "{s}/{d}", .{ tenant, rng.range(10_000, 100_000) });
        const key = try keys.encodeStr(scratch, text);
        const results = [3]keys.Lookup{ sorted.lookup(key), tree.lookup(key), hash.lookup(key) };
        for (results, 0..) |r, k| {
            steps[k] += r.steps;
            if (r.value != null) found[k] += 1;
        }
    }
    try w.print("\npoint lookups ({d} hits, 300 misses)\n", .{hits});
    try w.writeAll("                found  steps  unit of a step\n");
    const names = [3][]const u8{ "sorted array", "art", "hash index" };
    const units = [3][]const u8{ "whole-key comparison", "node visited", "slot probed" };
    for (names, units, found, steps) |name, unit, f, s| {
        try w.print("  {s:<12}  {d:>5}  {d:>5}  {s}\n", .{ name, f, s, unit });
    }

    // Range and prefix bounds are raw bytes without the terminator, so they
    // are bounds, not keys.
    try w.writeAll("\nrange \"bee/2000\" <= key < \"bee/4000\"\n");
    try compareQuery(gpa, w, &tree, &hash, sorted.range("bee/2000", "bee/4000"), "bee/2000", "bee/4000", null);

    // A prefix is the range [prefix, prefix with its last byte + 1).
    try w.writeAll("\nprefix \"cat/\"\n");
    try compareQuery(gpa, w, &tree, &hash, sorted.prefixRange("cat/"), "cat/", "cat0", "cat/");

    try w.writeAll("\nfirst 4 keys\n");
    try w.writeAll("  sorted array ");
    for (sorted.entries.items[0..4]) |e| {
        try w.writeAll(" ");
        try keys.writeBytes(w, e.key[0 .. e.key.len - 1]);
    }
    try w.writeAll("\n  art          ");
    var it = tree.iterator(gpa);
    defer it.deinit();
    for (0..4) |_| {
        const e = (try it.next()).?;
        try w.writeAll(" ");
        try keys.writeBytes(w, e.key[0 .. e.key.len - 1]);
    }
    try w.writeAll("\n  hash index   ");
    var shown: usize = 0;
    for (hash.slots) |slot| {
        const k = slot.key orelse continue;
        try w.writeAll(" ");
        try keys.writeBytes(w, k[0 .. k.len - 1]);
        shown += 1;
        if (shown == 4) break;
    }
    try w.writeAll("  (slot order)\n");

    try w.writeAll(
        \\
        \\what each index can answer
        \\                point  range        prefix       ordered scan
        \\  sorted array  yes    yes          yes          yes
        \\  art           yes    yes          yes          yes
        \\  hash index    yes    scan + sort  scan + sort  scan + sort
        \\
    );
}

test "run prints exactly expected_output.txt" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try run(std.testing.allocator, &aw.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), aw.written());
}

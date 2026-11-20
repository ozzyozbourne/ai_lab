//! demo.zig: the fixed, deterministic scenario printed by `zig build run`.
//!
//! Part 1  sixteen operations on a real file: a value spills into an
//!         overflow chain, pages are freed and reused, a leaf empties and
//!         the root collapses. The visualization replays exactly this part.
//! Part 2  a seeded workload of puts and deletes with values of every size
//!         class, with a reopen in the middle, compared with the oracle.
//! Part 3  the file stops growing under a steady insert/delete load.
//! Part 4  where a value is assembled: stack buffer first, heap if larger.
//! Part 5  not crash-safe: a freed page is reused at once.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const storage_mod = @import("base_storage.zig");
const MemStorage = storage_mod.MemStorage;
const FileStorage = storage_mod.FileStorage;
const Pager = @import("base_pager.zig").Pager;
const BufferPool = @import("base_buffer_pool.zig").BufferPool;
const btree = @import("disk_btree.zig");
const DiskBTree = btree.DiskBTree;
const workload = @import("workload.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;

pub const db_name = "ch13_demo.db";

/// One step of part 1: `len` null deletes the key, otherwise the key gets a
/// value of `len` bytes.
pub const Step = struct { key: u8, len: ?usize, show: bool = false };

pub const scenario = [_]Step{
    .{ .key = 10, .len = 700 },
    .{ .key = 20, .len = 700 },
    .{ .key = 30, .len = 700 },
    .{ .key = 40, .len = 700 },
    .{ .key = 50, .len = 700 },
    .{ .key = 25, .len = 9000, .show = true }, // spills, and splits the root leaf
    .{ .key = 60, .len = 3000 },
    .{ .key = 25, .len = 100, .show = true }, // large -> small: the chain is freed
    .{ .key = 35, .len = 5000, .show = true }, // reuses a freed page
    .{ .key = 60, .len = null }, // frees its chain
    .{ .key = 35, .len = null },
    .{ .key = 40, .len = null },
    .{ .key = 50, .len = null },
    .{ .key = 30, .len = null, .show = true }, // the right leaf empties; the root collapses
    .{ .key = 70, .len = 14000, .show = true }, // four overflow pages, all from the free list
    .{ .key = 80, .len = 3000, .show = true }, // takes the trunk page itself
};

/// Key `n` as two decimal digits, so that byte order is numeric order.
pub fn scenarioKey(n: u8, buf: *[2]u8) []const u8 {
    buf.* = .{ '0' + n / 10, '0' + n % 10 };
    return buf;
}

/// Apply one step. The value is `len` copies of one letter.
pub fn applyStep(tree: *DiskBTree, gpa: Allocator, step: Step) !void {
    var key_buf: [2]u8 = undefined;
    const key = scenarioKey(step.key, &key_buf);
    const len = step.len orelse {
        _ = try tree.delete(key);
        return;
    };
    const value = try gpa.alloc(u8, len);
    defer gpa.free(value);
    @memset(value, 'a' + step.key % 26);
    try tree.put(key, value);
}

pub fn run(w: *Io.Writer, gpa: Allocator, io: Io, dir: Io.Dir) !void {
    try w.writeAll("Chapter 13: overflow chains and free space\n");
    // Remove the demo file on every path out of here, errors included.
    defer dir.deleteFile(io, db_name) catch {};
    try part1(w, gpa, io, dir);
    try part2(w, gpa);
    try part3(w, gpa);
    try part4(w, gpa);
    try part5(w, gpa);
}

/// One letter per page: M metapage, I interior, L leaf, O overflow, T free-
/// list trunk, F free.
fn printPageMap(w: *Io.Writer, tree: *DiskBTree, gpa: Allocator) !void {
    const roles = try tree.pageMap(gpa);
    defer gpa.free(roles);
    try w.writeAll("page map:");
    for (roles) |role| try w.print(" {c}", .{role.letter()});
    try w.writeAll("\n");
}

fn printCounters(w: *Io.Writer, tree: *DiskBTree) !void {
    const pool = tree.pool;
    const s = tree.stats;
    try w.print("tree:  {d} keys, {d} pages, height {d}; splits: {d} leaf, {d} interior, {d} root; root collapses: {d}\n", .{
        tree.key_count, pool.pager.pageCount(), try tree.height(), s.leaf_splits, s.interior_splits, s.root_splits, s.root_collapses,
    });
    try w.print("space: {d} overflow pages written, {d} tree pages freed, {d} pages freed in all, {d} allocations reused a page, {d} pages free now\n", .{
        s.overflow_pages_written, s.tree_pages_freed, s.pages_freed, s.pages_reused, tree.free_count,
    });
    try w.print("pool:  {d} hits, {d} misses, {d} evictions, {d} write-backs\n", .{ pool.stats.hits, pool.stats.misses, pool.stats.evictions, pool.stats.writebacks });
    try w.print("pager: {d} reads, {d} writes, {d} allocations, {d} syncs\n", .{ pool.pager.stats.reads, pool.pager.stats.writes, pool.pager.stats.allocations, pool.pager.stats.syncs });
}

fn part1(w: *Io.Writer, gpa: Allocator, io: Io, dir: Io.Dir) !void {
    try w.writeAll("\n== Part 1: large values, freed pages and their reuse, in a real file (3-frame pool) ==\n");
    try w.print("a page offers {d} bytes to cells; a leaf cell keeps at most X = {d} value bytes, a spilled value at least M = {d}\n", .{ btree.page_capacity, btree.max_local, btree.min_local });
    try w.print("an overflow page holds {d} value bytes; a trunk page lists up to {d} free pages; a value may have {d} bytes\n", .{ btree.overflow_payload, btree.trunk_capacity, btree.max_value_len });
    try w.writeAll("value bytes -> in the leaf + overflow pages:");
    for ([_]usize{ 100, 1088, 1089, 3000, 5000, 9000, 14000 }) |total| try w.print("  {d} -> {d}+{d}p", .{ total, btree.localLen(total), btree.overflowPages(total) });
    try w.writeAll("\n");
    {
        var file: FileStorage = try .create(io, dir, db_name);
        defer file.close();
        var pager: Pager = try .init(file.storage());
        var pool: BufferPool = try .init(gpa, &pager, 3);
        defer pool.deinit();
        var tree: DiskBTree = try .create(gpa, &pool);
        defer tree.deinit();
        try w.print("created {s}: {d} pages (page 0 = metapage, page {d} = root)\n", .{ db_name, pager.pageCount(), tree.root });

        var key_buf: [2]u8 = undefined;
        for (scenario, 1..) |step, i| {
            const pages_before = pager.pageCount();
            const reused_before = tree.stats.pages_reused;
            const freed_before = tree.stats.pages_freed;
            try applyStep(&tree, gpa, step);
            const key = scenarioKey(step.key, &key_buf);
            if (step.len) |len| {
                try w.print("#{d} put {s} = {d} bytes ({d} in the leaf + {d} overflow pages)", .{ i, key, len, btree.localLen(len), btree.overflowPages(len) });
            } else try w.print("#{d} delete {s}", .{ i, key });
            try w.print(": {d} pages freed, {d} reused, file grew by {d}\n", .{
                tree.stats.pages_freed - freed_before, tree.stats.pages_reused - reused_before, pager.pageCount() - pages_before,
            });
            if (!step.show) continue;
            try tree.dump(w);
            try printPageMap(w, &tree, gpa);
        }
        try tree.validate();
        try printCounters(w, &tree);
        try tree.flush();
        try w.print("flushed: file size = {d} bytes\n", .{try file.storage().size()});
    }
    var file: FileStorage = try .open(io, dir, db_name);
    defer file.close();
    var pager: Pager = try .init(file.storage());
    var pool: BufferPool = try .init(gpa, &pager, 3);
    defer pool.deinit();
    var tree: DiskBTree = try .open(gpa, &pool);
    defer tree.deinit();
    try tree.validate();
    try w.print("reopened: root = page {d}, {d} keys, height {d}, {d} free pages, validate ok\n", .{ tree.root, tree.key_count, try tree.height(), tree.free_count });

    const value = (try tree.get(gpa, "70")).?;
    defer gpa.free(value);
    try w.print("get 70 -> {d} bytes, all '{c}': {}\n", .{ value.len, value[0], std.mem.allEqual(u8, value, 'a' + 70 % 26) });
    try w.print("get 35 -> {s}\n", .{if (try tree.get(gpa, "35")) |_| "found?!" else "not found"});
    try w.writeAll("range [20, 99) ->");
    var it = try tree.range("20", "99");
    defer it.deinit();
    while (try it.next()) |item| try w.print(" {s}:{d}{s}", .{ item.key, item.value.len, if (it.valueOnHeap()) "(heap)" else "" });
    try w.writeAll("\n");
}

/// One random operation of parts 2 to 4, applied to tree and oracle: a put
/// of a mixed-size value, or (`deletes` times in 10) a delete.
fn mixedOp(tree: *DiskBTree, model: *workload.Model, rng: *SplitMix64, key_space: u64, deletes: u64) !void {
    var key_buf: [workload.max_key_len]u8 = undefined;
    var value_buf: [workload.max_value_len]u8 = undefined;
    const key = workload.keyFor(rng.below(key_space), 32, &key_buf);
    if (rng.below(10) < deletes) {
        const deleted = try tree.delete(key);
        std.debug.assert(deleted == model.delete(key));
    } else {
        const value = workload.mixedValue(rng, 20000, &value_buf);
        try tree.put(key, value);
        try model.put(key, value);
    }
}

fn sameAsOracle(tree: *DiskBTree, model: *const workload.Model) !bool {
    var it = try tree.range("", null);
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |item| : (count += 1) {
        if (count == model.len()) return false;
        const expected = model.entries.items[count];
        if (!std.mem.eql(u8, item.key, expected.key) or !std.mem.eql(u8, item.value, expected.value)) return false;
    }
    return count == model.len();
}

fn part2(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 2: 4000 random operations, 3 puts to 1 delete, values of 0 to 20000 bytes (8-frame pool) ==\n");
    var mem: MemStorage = .init(gpa);
    defer mem.deinit();
    var model: workload.Model = .init(gpa);
    defer model.deinit();
    var rng = SplitMix64.init(13);

    for (0..2) |half| {
        var pager: Pager = try .init(mem.storage());
        var pool: BufferPool = try .init(gpa, &pager, 8);
        defer pool.deinit();
        var tree: DiskBTree = if (half == 0) try .create(gpa, &pool) else try .open(gpa, &pool);
        defer tree.deinit();
        for (0..2000) |_| try mixedOp(&tree, &model, &rng, 600, 3);
        try tree.validate();
        try w.print("{s}\n", .{if (half == 0) "first 2000 operations:" else "reopened, 2000 more operations:"});
        try printCounters(w, &tree);
        try tree.flush();
        if (half == 0) continue;

        const roles = try tree.pageMap(gpa);
        defer gpa.free(roles);
        var counts: [7]usize = @splat(0);
        for (roles) |role| counts[@backingInt(role)] += 1;
        try w.print("page roles: {d} metapage, {d} interior, {d} leaf, {d} overflow, {d} trunk, {d} free\n", .{ counts[1], counts[2], counts[3], counts[4], counts[5], counts[6] });
        try w.print("full scan: oracle has {d} entries, identical: {}\n", .{ model.len(), try sameAsOracle(&tree, &model) });
    }
}

/// Part 3 and its test: `rounds` rounds of 500 operations, half puts and
/// half deletes over 200 keys. Returns the page count after each round.
pub fn steadyState(gpa: Allocator, rounds: usize, pages: []u32, stats: *DiskBTree.Stats) !void {
    var mem: MemStorage = .init(gpa);
    defer mem.deinit();
    var model: workload.Model = .init(gpa);
    defer model.deinit();
    var pager: Pager = try .init(mem.storage());
    var pool: BufferPool = try .init(gpa, &pager, 8);
    defer pool.deinit();
    var tree: DiskBTree = try .create(gpa, &pool);
    defer tree.deinit();
    var rng = SplitMix64.init(3);
    for (0..rounds) |round| {
        for (0..500) |_| try mixedOp(&tree, &model, &rng, 200, 5);
        try tree.validate();
        pages[round] = pager.pageCount();
    }
    std.debug.assert(try sameAsOracle(&tree, &model));
    stats.* = tree.stats;
}

fn part3(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 3: the file stops growing: 12 rounds of 500 operations, half puts and half deletes, over 200 keys ==\n");
    var pages: [12]u32 = undefined;
    var stats: DiskBTree.Stats = undefined;
    try steadyState(gpa, pages.len, &pages, &stats);
    try w.writeAll("pages in the file after each round:");
    for (pages) |n| try w.print(" {d}", .{n});
    try w.print("\n{d} pages were freed and {d} allocations reused one; without a free list the file would have {d} pages\n", .{ stats.pages_freed, stats.pages_reused, pages[pages.len - 1] + stats.pages_reused });
}

fn part4(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 4: assembling values: a 1088-byte stack buffer first, the heap only if the value is larger ==\n");
    var mem: MemStorage = .init(gpa);
    defer mem.deinit();
    var model: workload.Model = .init(gpa);
    defer model.deinit();
    var pager: Pager = try .init(mem.storage());
    var pool: BufferPool = try .init(gpa, &pager, 8);
    defer pool.deinit();
    var tree: DiskBTree = try .create(gpa, &pool);
    defer tree.deinit();
    var rng = SplitMix64.init(4);
    for (0..1500) |_| try mixedOp(&tree, &model, &rng, 500, 2);

    // `get` allocates the value with whatever allocator it is given. This
    // one tries a buffer in this stack frame and falls back to `gpa`.
    var on_stack: usize = 0;
    var on_heap: usize = 0;
    var wrong: usize = 0;
    for (model.entries.items) |entry| {
        var stack_buf: [btree.max_local]u8 = undefined;
        var chain: std.heap.BufferFirstAllocator = .init(&stack_buf, gpa);
        const allocator = chain.allocator();
        const value = (try tree.get(allocator, entry.key)).?;
        defer allocator.free(value);
        if (!std.mem.eql(u8, value, entry.value)) wrong += 1;
        if (value.len == 0 or chain.fixed_buffer_allocator.ownsPtr(value.ptr)) on_stack += 1 else on_heap += 1;
    }
    try w.print("{d} gets: {d} values assembled in the stack buffer, {d} on the heap, {d} wrong\n", .{ model.len(), on_stack, on_heap, wrong });

    // The range iterator carries the same kind of chain inside itself.
    var it = try tree.range("", null);
    defer it.deinit();
    var inline_values: usize = 0;
    var heap_values: usize = 0;
    while (try it.next()) |_| {
        if (it.valueOnHeap()) heap_values += 1 else inline_values += 1;
    }
    try w.print("full scan: {d} values in the iterator's inline buffer, {d} on the heap\n", .{ inline_values, heap_values });
}

// ---- Part 5 -------------------------------------------------------------------

/// What is in the storage after a crash in the middle of "delete one large
/// value, put another".
pub const CrashOutcome = struct {
    /// Both operations and the flush finished: there was no crash.
    completed: bool = false,
    validate_error: ?anyerror = null,
    old: Found = .{},
    new: Found = .{},

    pub const State = enum { missing, intact, wrong_bytes, unreadable };
    /// What `get` returned, with the value's first and last byte.
    pub const Found = struct { state: State = .missing, first: u8 = 0, last: u8 = 0 };
};

pub const crash_value_len = 5000;

fn look(tree: *DiskBTree, gpa: Allocator, key: []const u8, letter: u8) CrashOutcome.Found {
    const value = (tree.get(gpa, key) catch return .{ .state = .unreadable }) orelse return .{};
    defer gpa.free(value);
    const intact = value.len == crash_value_len and std.mem.allEqual(u8, value, letter);
    return .{ .state = if (intact) .intact else .wrong_bytes, .first = value[0], .last = value[value.len - 1] };
}

fn printFound(w: *Io.Writer, name: []const u8, found: CrashOutcome.Found) !void {
    try w.print("; {s}: ", .{name});
    switch (found.state) {
        .wrong_bytes => try w.print("WRONG VALUE (starts with '{c}', ends with '{c}')", .{ found.first, found.last }),
        else => try w.print("{t}", .{found.state}),
    }
}

/// Store "old" = 5000 x 'o' (916 bytes in the leaf, one overflow page) and
/// flush. Then let only `writes_allowed` more page writes reach the storage
/// while "old" is deleted, "new" = 5000 x 'n' is put (its overflow page is
/// the one "old" just gave back) and the tree is flushed. Finally forget
/// everything in memory, as a crash does, reopen and look.
pub fn crashDuringReuse(gpa: Allocator, writes_allowed: u64) !CrashOutcome {
    var mem: MemStorage = .init(gpa);
    defer mem.deinit();
    var outcome: CrashOutcome = .{};
    const old_value: [crash_value_len]u8 = @splat('o');
    const new_value: [crash_value_len]u8 = @splat('n');
    {
        var pager: Pager = try .init(mem.storage());
        var pool: BufferPool = try .init(gpa, &pager, 8);
        defer pool.deinit(); // no flush: dirty pages in memory are lost
        var tree: DiskBTree = try .create(gpa, &pool);
        defer tree.deinit();
        try tree.put("old", &old_value);
        try tree.flush();

        mem.writes_before_failure = writes_allowed;
        const done = blk: {
            _ = tree.delete("old") catch break :blk false;
            tree.put("new", &new_value) catch break :blk false;
            std.debug.assert(tree.stats.pages_reused == 1 and pager.pageCount() == 3);
            tree.flush() catch break :blk false;
            break :blk true;
        };
        outcome.completed = done;
        mem.writes_before_failure = null;
    }

    var pager: Pager = try .init(mem.storage());
    var pool: BufferPool = try .init(gpa, &pager, 8);
    defer pool.deinit();
    var tree: DiskBTree = try .open(gpa, &pool);
    defer tree.deinit();
    tree.validate() catch |err| {
        outcome.validate_error = err;
    };
    outcome.old = look(&tree, gpa, "old", 'o');
    outcome.new = look(&tree, gpa, "new", 'n');
    return outcome;
}

fn part5(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 5: not crash-safe: a freed page is reused at once ==\n");
    try w.writeAll("\"old\" (5000 x 'o', one overflow page) is on disk; delete it, put \"new\" (5000 x 'n') into the same page, flush; the storage fails after N writes\n");
    var writes: u64 = 0;
    while (true) : (writes += 1) {
        const o = try crashDuringReuse(gpa, writes);
        try w.print("N = {d}: ", .{writes});
        if (o.completed) try w.writeAll("no crash, all writes done; ");
        if (o.validate_error) |err| try w.print("validate fails with error.{t}", .{err}) else try w.writeAll("validate ok");
        try printFound(w, "old", o.old);
        try printFound(w, "new", o.new);
        try w.writeAll("\n");
        if (o.completed) break;
    }
}

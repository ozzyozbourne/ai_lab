//! demo.zig: the fixed, deterministic scenario printed by `zig build run`.
//!
//! Part 1  a pager over a real file: allocate, write, sync, reopen, read.
//! Part 2  a 4-frame buffer pool over that file, driven by a fixed trace that
//!         shows a hit, a second chance, a skipped pinned frame, a dirty
//!         write-back and the all-frames-pinned error. The visualization
//!         replays exactly this trace and checks its final state.
//! Part 3  the same seeded workload against pools of 4, 8, 16 and 32 frames
//!         on an in-memory storage: only the counters change.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const storage_mod = @import("storage.zig");
const pager_mod = @import("pager.zig");
const pool_mod = @import("buffer_pool.zig");
const Pager = pager_mod.Pager;
const Page = pager_mod.Page;
const PageId = pager_mod.PageId;
const BufferPool = pool_mod.BufferPool;

pub const db_name = "ch09_demo.db";

/// Demo page layout: bytes 0..4 = the page's own id, bytes 8..16 = a version
/// counter that every "edit" increments. Little-endian, like every on-disk
/// integer in this guide.
fn stamp(page: *Page, id: PageId, version: u64) void {
    std.mem.writeInt(u32, page[0..4], id, .little);
    std.mem.writeInt(u64, page[8..16], version, .little);
}
fn idOf(page: *const Page) u32 {
    return std.mem.readInt(u32, page[0..4], .little);
}
fn versionOf(page: *const Page) u64 {
    return std.mem.readInt(u64, page[8..16], .little);
}

pub fn run(w: *Io.Writer, gpa: Allocator, io: Io, dir: Io.Dir) !void {
    try w.writeAll("Chapter 09: pages and the buffer pool\n");
    // Remove the demo file on every path out of here, errors included.
    defer dir.deleteFile(io, db_name) catch {};
    try part1(w, io, dir);
    try part2(w, gpa, io, dir);
    try part3(w, gpa);
}

fn part1(w: *Io.Writer, io: Io, dir: Io.Dir) !void {
    try w.writeAll("\n== Part 1: a file is an array of pages ==\n");
    {
        var file: storage_mod.FileStorage = try .create(io, dir, db_name);
        defer file.close();
        var pager: Pager = try .init(file.storage());
        try w.print("created {s}: {d} pages\n", .{ db_name, pager.pageCount() });

        var page: Page = @splat(0);
        for (0..8) |_| {
            const id = try pager.allocatePage();
            stamp(&page, id, 0);
            try pager.writePage(id, &page);
        }
        try pager.sync();
        try w.print("allocated 8 pages: file size = {d} bytes (8 * {d})\n", .{ try file.storage().size(), pager_mod.page_size });
        try printPagerStats(w, &pager);
    }
    var file: storage_mod.FileStorage = try .open(io, dir, db_name);
    defer file.close();
    var pager: Pager = try .init(file.storage());
    try w.print("reopened: {d} pages\n", .{pager.pageCount()});
    var page: Page = undefined;
    try pager.readPage(5, &page);
    try w.print("page 5 is at byte offset {d}; its id field says {d}, version {d}\n", .{ Pager.offsetOf(5), idOf(&page), versionOf(&page) });
    if (pager.readPage(8, &page)) |_| unreachable else |err| {
        try w.print("page 8 does not exist: error.{t}\n", .{err});
    }
}

const Op = union(enum) {
    /// fetchPage and keep the pin
    fetch: PageId,
    /// unpin, page not modified
    unpin: PageId,
    /// increment the page's version, then unpin with dirty = true
    edit: PageId,
};

/// The fixed trace. Kept in step with viz/index.html (TRACE).
pub const trace = [_]Op{
    .{ .fetch = 0 }, .{ .unpin = 0 }, // fill the four frames
    .{ .fetch = 1 }, .{ .edit = 1 }, // page 1 becomes dirty
    .{ .fetch = 2 }, .{ .unpin = 2 },
    .{ .fetch = 3 }, .{ .unpin = 3 },
    .{ .fetch = 1 }, .{ .unpin = 1 }, // hit
    .{ .fetch = 4 }, .{ .unpin = 4 }, // first eviction: full sweep
    .{ .fetch = 1 }, .{ .unpin = 1 }, // hit: sets the referenced bit again
    .{ .fetch = 5 }, .{ .unpin = 5 }, // page 1 gets its second chance
    .{ .fetch = 3 }, // stays pinned
    .{ .fetch = 6 }, .{ .edit = 6 }, // skips pinned page 3, writes back page 1
    .{ .fetch = 4 }, .{ .fetch = 5 }, .{ .fetch = 6 }, // now all four are pinned
    .{ .fetch = 7 }, // error
    .{ .unpin = 3 },
    .{ .unpin = 4 },
    .{ .unpin = 5 },
    .{ .unpin = 6 },
    .{ .fetch = 7 },
    .{ .unpin = 7 },
};

const frame_count = 4;

fn part2(w: *Io.Writer, gpa: Allocator, io: Io, dir: Io.Dir) !void {
    try w.print("\n== Part 2: a {d}-frame buffer pool with CLOCK eviction ==\n", .{frame_count});
    try w.writeAll("frame cell = page, pin count, R = referenced, D = dirty; hand = next frame the clock looks at\n\n");
    {
        var file: storage_mod.FileStorage = try .open(io, dir, db_name);
        defer file.close();
        var pager: Pager = try .init(file.storage());
        var pool: BufferPool = try .init(gpa, &pager, frame_count);
        defer pool.deinit();
        // The trace keeps pages pinned from one step to the next. If a step
        // fails (a write to `w`, say), release them before `deinit` runs, or
        // its pin-leak assert would hide the real error.
        errdefer for (pool.frames) |frame| {
            for (0..frame.pin_count) |_| pool.unpin(frame.page_id, false);
        };

        // The pointer each fetch returned, by page id (valid while pinned).
        var pinned: [8]?pool_mod.PagePtr = @splat(null);

        try w.writeAll(" #  op       outcome                               f0       f1       f2       f3       hand\n");
        for (trace, 1..) |op, step| {
            var outcome_buf: [64]u8 = undefined;
            var op_buf: [16]u8 = undefined;
            const before = pool.stats;
            var old_frames: [frame_count]BufferPool.Frame = undefined;
            @memcpy(&old_frames, pool.frames);

            var op_text: []const u8 = undefined;
            var outcome: []const u8 = undefined;
            switch (op) {
                .fetch => |id| {
                    op_text = try std.fmt.bufPrint(&op_buf, "fetch {d}", .{id});
                    if (pool.fetchPage(id)) |page| {
                        pinned[id] = page;
                        const f = pool.frameOf(id).?;
                        if (pool.stats.hits > before.hits) {
                            outcome = try std.fmt.bufPrint(&outcome_buf, "hit in f{d}", .{f});
                        } else if (pool.stats.writebacks > before.writebacks) {
                            outcome = try std.fmt.bufPrint(&outcome_buf, "miss: write back + evict page {d} (f{d})", .{ old_frames[f].page_id, f });
                        } else if (pool.stats.evictions > before.evictions) {
                            outcome = try std.fmt.bufPrint(&outcome_buf, "miss: evict page {d} (f{d})", .{ old_frames[f].page_id, f });
                        } else {
                            outcome = try std.fmt.bufPrint(&outcome_buf, "miss: load into empty f{d}", .{f});
                        }
                    } else |err| {
                        outcome = try std.fmt.bufPrint(&outcome_buf, "error.{t}", .{err});
                    }
                },
                .unpin => |id| {
                    op_text = try std.fmt.bufPrint(&op_buf, "unpin {d}", .{id});
                    pool.unpin(id, false);
                    outcome = "released, page unchanged";
                },
                .edit => |id| {
                    op_text = try std.fmt.bufPrint(&op_buf, "edit {d}", .{id});
                    // The trace pinned this page with an earlier fetch; use
                    // the pointer that fetch returned.
                    const page = pinned[id].?;
                    stamp(page, id, versionOf(page) + 1);
                    pool.unpin(id, true);
                    outcome = try std.fmt.bufPrint(&outcome_buf, "version -> {d}, released dirty", .{versionOf(page)});
                },
            }
            try pool.validate();
            try w.print("{d:>2}  {s:<8} {s:<37}", .{ step, op_text, outcome });
            try printFrames(w, &pool);
        }

        try w.writeAll("\nfinal state (the visualization's self-test checks these lines):\n");
        for (pool.frames, 0..) |frame, f| {
            try w.print("  frame {d}: page={d} pin={d} referenced={d} dirty={d}\n", .{ f, frame.page_id, frame.pin_count, @intFromBool(frame.referenced), @intFromBool(frame.dirty) });
        }
        try w.print("  hand={d}\n", .{pool.hand});
        try printPoolStats(w, &pool);
        try printPagerStats(w, &pager);

        try pool.flushAll();
        try w.writeAll("after flushAll:\n");
        try printPagerStats(w, &pager);
    }

    // Reopen without a pool: the edits must be in the file.
    var file: storage_mod.FileStorage = try .open(io, dir, db_name);
    defer file.close();
    var pager: Pager = try .init(file.storage());
    var page: Page = undefined;
    try w.writeAll("reopened; versions on disk:");
    for (0..pager.pageCount()) |id| {
        try pager.readPage(@intCast(id), &page);
        try w.print(" {d}", .{versionOf(&page)});
    }
    try w.writeAll("\n");
}

fn part3(w: *Io.Writer, gpa: Allocator) !void {
    const Workload = @import("workload.zig");
    try w.print("\n== Part 3: {d} page accesses over {d} pages (80% to 8 hot pages), in-memory storage ==\n", .{ Workload.ops, Workload.page_count });
    try w.writeAll("frames   hits  misses  evictions  writebacks  file reads  file writes\n");
    for ([_]u32{ 4, 8, 16, 32 }) |frames| {
        var mem: storage_mod.MemStorage = .init(gpa);
        defer mem.deinit();
        var pager: Pager = try .init(mem.storage());
        for (0..Workload.page_count) |_| _ = try pager.allocatePage();
        pager.stats = .{};
        var pool: BufferPool = try .init(gpa, &pager, frames);
        defer pool.deinit();

        var expected: [Workload.page_count]u64 = @splat(0);
        try Workload.run(&pool, 2024, &expected);
        try pool.flushAll();
        // Verify the storage against the oracle, page by page.
        for (expected, 0..) |want, id| {
            const got = std.mem.readInt(u64, mem.bytes.items[id * pager_mod.page_size + 8 ..][0..8], .little);
            if (got != want) return error.WrongPageContent;
        }
        try w.print("{d:>6}  {d:>5}  {d:>6}  {d:>9}  {d:>10}  {d:>10}  {d:>11}\n", .{
            frames,                pool.stats.hits,   pool.stats.misses,  pool.stats.evictions,
            pool.stats.writebacks, pager.stats.reads, pager.stats.writes,
        });
    }
    try w.writeAll("every run ended with the same page contents as the oracle\n");
}

fn printFrames(w: *Io.Writer, pool: *const BufferPool) !void {
    for (pool.frames) |frame| {
        var buf: [16]u8 = undefined;
        const cell = if (frame.page_id == pager_mod.invalid_page_id)
            "-"
        else
            try std.fmt.bufPrint(&buf, "{d} p{d} {c}{c}", .{
                frame.page_id,
                frame.pin_count,
                @as(u8, if (frame.referenced) 'R' else '-'),
                @as(u8, if (frame.dirty) 'D' else '-'),
            });
        try w.print(" {s:<8}", .{cell});
    }
    try w.print(" {d}\n", .{pool.hand});
}

fn printPoolStats(w: *Io.Writer, pool: *const BufferPool) !void {
    const s = pool.stats;
    try w.print("  pool:  hits={d} misses={d} evictions={d} writebacks={d}\n", .{ s.hits, s.misses, s.evictions, s.writebacks });
}

fn printPagerStats(w: *Io.Writer, pager: *const Pager) !void {
    const s = pager.stats;
    try w.print("  pager: reads={d} writes={d} allocations={d} syncs={d}\n", .{ s.reads, s.writes, s.allocations, s.syncs });
}

//! Model test: the shared operation stream is applied to one SlottedPage and
//! to the oracle from ops.zig (a sorted array of u64 pairs). After every
//! operation the page must validate and answer exactly like the oracle.
//!
//! A page is finite, so `put` may fail with PageFull. The test then checks
//! that the refusal was justified and that the page did not change, and does
//! not apply the put to the oracle.
const std = @import("std");
const testing = std.testing;
const sp = @import("slotted_page.zig");
const ops = @import("ops.zig");
const workload = @import("workload.zig");
const SlottedPage = sp.SlottedPage;

const Coverage = struct {
    page_full: usize = 0,
    replaced: usize = 0,
    saw_free_blocks: usize = 0,
    saw_fragments: usize = 0,
    compactions: usize = 0,
};

fn runModel(allocator: std.mem.Allocator, config: ops.Config) !Coverage {
    var buf: [sp.page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(allocator);
    var cov: Coverage = .{};

    var kb: [workload.max_key_len]u8 = undefined;
    var vb: [workload.max_value_len]u8 = undefined;
    var stream = ops.OpStream.init(config);
    while (stream.next()) |op| {
        switch (op) {
            .put => |p| {
                const k = workload.keyBytes(&kb, p.key);
                const v = workload.valueBytes(&vb, p.value);
                const before = page.stats();
                const snapshot: [sp.page_size]u8 = buf;
                // What the put needs versus what the page can give back.
                const need = sp.cellSize(k.len, v.len);
                const old: ?usize = if (page.get(k)) |old_v| sp.cellSize(k.len, old_v.len) else null;
                const available = if (old) |o| before.free_bytes + o else before.free_bytes -| sp.slot_size;
                if (page.put(k, v)) |_| {
                    try testing.expect(need <= available);
                    _ = try oracle.put(allocator, p.key, p.value);
                    cov.replaced += @intFromBool(old != null);
                    // A put that had to compact leaves no free block behind,
                    // although there were some before.
                    const after = page.stats();
                    if (before.free_block_count > 0 and after.free_block_count == 0 and after.frag_bytes == 0 and
                        before.gap < need + sp.slot_size) cov.compactions += 1;
                } else |err| {
                    try testing.expectEqual(error.PageFull, err);
                    try testing.expect(need > available);
                    try testing.expectEqualSlices(u8, &snapshot, &buf);
                    cov.page_full += 1;
                }
            },
            .delete => |d| {
                const expected = oracle.delete(d.key) != null;
                try testing.expectEqual(expected, page.delete(workload.keyBytes(&kb, d.key)));
            },
            .get => |g| {
                const got = page.get(workload.keyBytes(&kb, g.key));
                if (oracle.get(g.key)) |value| {
                    try testing.expectEqualSlices(u8, workload.valueBytes(&vb, value), got.?);
                } else {
                    try testing.expectEqual(null, got);
                }
            },
            .range => |r| {
                // A range scan on a sorted page: lower bound, then walk slots.
                var i = page.search(workload.keyBytes(&kb, r.lo)).index;
                for (oracle.range(r.lo, r.hi)) |entry| {
                    try testing.expectEqualSlices(u8, workload.keyBytes(&kb, entry.key), page.key(i));
                    try testing.expectEqualSlices(u8, workload.valueBytes(&vb, entry.value), page.value(i));
                    i += 1;
                }
                try testing.expectEqual(page.search(workload.keyBytes(&kb, r.hi)).index, i);
            },
        }
        try page.validate();
        try testing.expectEqual(oracle.len(), page.count());
        const s = page.stats();
        cov.saw_free_blocks += @intFromBool(s.free_block_count > 0);
        cov.saw_fragments += @intFromBool(s.frag_bytes > 0);
    }
    return cov;
}

test "model: 20000 operations, page mostly full" {
    // 300 possible keys of about 36 bytes each do not fit in 4 KiB, so the
    // page fills up and every free-space path is taken many times.
    const cov = try runModel(testing.allocator, .{ .seed = 10, .count = 20_000, .key_space = 300 });
    // Coverage asserts: a model test that never reaches the hard paths
    // proves nothing about them.
    try testing.expect(cov.page_full > 0);
    try testing.expect(cov.replaced > 0);
    try testing.expect(cov.saw_free_blocks > 0);
    try testing.expect(cov.saw_fragments > 0);
    try testing.expect(cov.compactions > 0);
}

test "model: small key space, page never fills, heavy overwrite and delete" {
    const cov = try runModel(testing.allocator, .{ .seed = 11, .count = 20_000, .key_space = 40 });
    try testing.expectEqual(0, cov.page_full);
    try testing.expect(cov.replaced > 0);
    try testing.expect(cov.saw_fragments > 0);
}

test "model: delete-heavy, the page empties again and again" {
    _ = try runModel(testing.allocator, .{
        .seed = 12,
        .count = 20_000,
        .key_space = 16,
        .weights = .{ .put = 2, .delete = 4, .get = 1, .range = 1 },
    });
}

test "model: the oracle's allocation failure leaves nothing leaked" {
    // The page itself never allocates; only the oracle does. This checks the
    // test harness (errdefer/defer paths) under allocation failure.
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            _ = try runModel(allocator, .{ .seed = 13, .count = 200, .key_space = 50 });
        }
    }.run, .{});
}

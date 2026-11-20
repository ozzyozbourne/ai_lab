//! Tests of chapter 19, deterministic ones first.
//!
//!   1. single-threaded: every protocol against the oracle and against the
//!      other protocols; a full node table;
//!   2. the test hook on ONE thread: which latches an operation holds;
//!   3. the test hook with TWO OR MORE threads (probe.zig): one operation
//!      frozen, the others run one at a time, no sleeps;
//!   4. bounded stress with up to 4 threads, then validate and oracle.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;

const lib = @import("root.zig");
const Tree = lib.Tree;
const Protocol = lib.Protocol;
const NodeId = lib.NodeId;
const Hook = lib.Hook;
const probe = lib.probe;
const stress = lib.stress;
const valueOf = probe.valueOf;

fn expectDump(tree: *const Tree, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try lib.dump.dump(tree, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

fn dumpAlloc(tree: *const Tree) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try lib.dump.dump(tree, &out.writer);
    return out.toOwnedSlice();
}

/// Hook for operations that run while NO other thread touches the tree.
/// Nobody else can hold a lock or latch then, so an operation that has to
/// wait would wait for something an earlier operation leaked, forever. The
/// hook hears about the wait before it starts and stops the test binary
/// with a message instead of letting it hang.
var never_waits_ctx: u8 = 0; // a hook needs a context; this one has no state
const never_waits: Hook = .{ .ctx = &never_waits_ctx, .func = panicOnWait };

fn panicOnWait(_: *anyopaque, event: Hook.Event) void {
    if (event.point != .blocked) return;
    if (event.node == NodeId.nil) @panic("an operation running alone must wait for the tree-wide lock: an earlier one leaked it");
    std.debug.panic("an operation running alone must wait for the latch of #{d}: an earlier one leaked it", .{event.node.index()});
}

fn canonicalTree(protocol: Protocol) !Tree {
    var tree: Tree = try .init(testing.allocator, 4, protocol, 64);
    errdefer tree.deinit(testing.allocator);
    for (lib.canonical) |key| _ = try tree.putHooked(testing.io, key, valueOf(key), &never_waits);
    return tree;
}

/// Compares the leaf chain with the oracle, entry by entry.
fn expectSameContents(tree: *const Tree, oracle: *const lib.ops.Oracle) !void {
    var walker = lib.dump.Walker.init(tree);
    for (oracle.range(0, std.math.maxInt(u64))) |expected| {
        const got = walker.next() orelse return error.TestExpectedEqual;
        try testing.expectEqual(expected.key, got.key);
        try testing.expectEqual(expected.value, got.value);
    }
    try testing.expectEqual(null, walker.next());
}

// ------------------------------------------------------- 1. single-threaded

test "canonical keys: all protocols build the tree of chapter 07" {
    for (lib.protocols) |protocol| {
        var tree = try canonicalTree(protocol);
        defer tree.deinit(testing.allocator);
        try tree.validate();
        // Same handles and same shape as chapter 07's expected output (the
        // chain is singly linked here, hence `->`).
        try expectDump(&tree,
            \\height 3, 12 keys, 8 nodes
            \\  level 0: #7[15]
            \\  level 1: #2[6 10] #6[20]
            \\  leaves : #0(1 3 5) -> #4(6 7) -> #1(10 12) -> #5(15 17) -> #3(20 25 30)
            \\
        );
        try testing.expectEqual(1200, tree.get(testing.io, 12));
        try testing.expectEqual(null, tree.get(testing.io, 13));
        try testing.expectEqual(1200, try tree.put(testing.io, 12, 7)); // overwrite
        try testing.expectEqual(7, tree.get(testing.io, 12));
        try testing.expectEqual(12, tree.len());
        try testing.expect(tree.nothingLocked(testing.io));
    }
}

test "an empty tree is a valid tree" {
    for (lib.protocols) |protocol| {
        var tree: Tree = try .init(testing.allocator, 4, protocol, 1);
        defer tree.deinit(testing.allocator);
        try tree.validate();
        try testing.expectEqual(null, tree.get(testing.io, 1));
        try testing.expectEqual(1, tree.height());
        try expectDump(&tree, "height 1, 0 keys, 1 nodes\n  leaves : #0()\n");
    }
}

test "model test: every protocol against the oracle, orders 3, 4, 5 and 16" {
    const gpa = testing.allocator;
    for (lib.protocols) |protocol| {
        for ([_]usize{ 3, 4, 5, 16 }) |order| {
            var tree: Tree = try .init(gpa, order, protocol, 1024);
            defer tree.deinit(gpa);
            var oracle: lib.ops.Oracle = .{};
            defer oracle.deinit(gpa);
            var stream = lib.ops.OpStream.init(.{
                .seed = 100 + order,
                .count = 4000,
                .key_space = 300,
                .weights = .{ .put = 3, .delete = 0, .get = 2, .range = 0 },
            });
            var step: usize = 0;
            while (stream.next()) |op| : (step += 1) {
                switch (op) {
                    .put => |p| try testing.expectEqual(try oracle.put(gpa, p.key, p.value), try tree.putHooked(testing.io, p.key, p.value, &never_waits)),
                    .get => |g| try testing.expectEqual(oracle.get(g.key), tree.getHooked(testing.io, g.key, &never_waits)),
                    .delete, .range => unreachable,
                }
                if (step % 97 == 0) try tree.validate();
            }
            try tree.validate();
            try testing.expectEqual(oracle.len(), tree.len());
            try expectSameContents(&tree, &oracle);
            try testing.expect(tree.nothingLocked(testing.io));
        }
    }
}

test "the three protocols produce byte-identical trees for the same operations" {
    const gpa = testing.allocator;
    for ([_]usize{ 3, 4, 7 }) |order| {
        var reference: ?[]u8 = null;
        defer if (reference) |r| gpa.free(r);
        for (lib.protocols) |protocol| {
            var tree: Tree = try .init(gpa, order, protocol, 1024);
            defer tree.deinit(gpa);
            var rng = lib.prng.SplitMix64.init(order);
            for (0..1500) |_| {
                const key = rng.below(400);
                _ = try tree.put(testing.io, key, valueOf(key));
            }
            const text = try dumpAlloc(&tree);
            if (reference) |r| {
                defer gpa.free(text);
                try testing.expectEqualStrings(r, text);
            } else reference = text;
        }
    }
}

test "OutOfNodes: for every table size the failing put changes nothing and releases everything" {
    const gpa = testing.allocator;
    for (lib.protocols) |protocol| {
        // The canonical tree needs 8 nodes; try every smaller table.
        for (1..8) |capacity| {
            var tree: Tree = try .init(gpa, 4, protocol, @intCast(capacity));
            defer tree.deinit(gpa);
            var inserted: usize = 0;
            var failures: usize = 0;
            for (lib.canonical) |key| {
                const before = try dumpAlloc(&tree);
                defer gpa.free(before);
                if (tree.put(testing.io, key, valueOf(key))) |old| {
                    try testing.expectEqual(null, old);
                    inserted += 1;
                } else |err| {
                    try testing.expectEqual(error.OutOfNodes, err);
                    failures += 1;
                    try expectDump(&tree, before);
                    // No lock or latch may survive the error path.
                    try testing.expect(tree.nothingLocked(testing.io));
                }
                try tree.validate();
            }
            try testing.expect(failures > 0);
            try testing.expectEqual(inserted, tree.len());
            // Overwriting needs no node and still works on a full table.
            const some_key = lib.canonical[0];
            try testing.expectEqual(valueOf(some_key), try tree.put(testing.io, some_key, 1));
            try testing.expectEqual(1, tree.get(testing.io, some_key));
        }
    }
}

test "Tree.init reports an allocation failure and leaks nothing" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, Tree.init(failing.allocator(), 4, .latch_coupling, 16));
}

// --------------------------------------------- 2. the hook on a single thread

const Latched = struct {
    ids: [8]u32 = undefined,
    len: usize = 0,

    fn slice(self: *const Latched) []const u32 {
        return self.ids[0..self.len];
    }
};

/// Handles of the nodes somebody holds a latch on right now, found by trying
/// to latch every node exclusively. Only meaningful while every other thread
/// is frozen or done.
fn latched(tree: *Tree) Latched {
    var result: Latched = .{};
    for (tree.table.slots, 0..) |*slot, i| {
        if (slot.latch.tryLock(testing.io)) {
            slot.latch.unlock(testing.io);
        } else {
            result.ids[result.len] = @intCast(i);
            result.len += 1;
        }
    }
    return result;
}

/// Records, at chosen points of ONE operation, which nodes are latched:
/// those the operation itself holds.
const LatchSpy = struct {
    tree: *Tree,
    /// Nodes latched when the descent ended (`at_leaf`).
    at_leaf: [8]u32 = undefined,
    at_leaf_len: usize = 0,
    /// Largest number of latches held right after acquiring one.
    max_held: usize = 0,

    fn onEvent(ctx: *anyopaque, event: Hook.Event) void {
        const self: *LatchSpy = @ptrCast(@alignCast(ctx));
        if (event.point != .latched and event.point != .at_leaf) return;
        const held = latched(self.tree);
        self.max_held = @max(self.max_held, held.len);
        if (event.point == .at_leaf) {
            self.at_leaf = held.ids;
            self.at_leaf_len = held.len;
        }
    }

    fn hook(self: *LatchSpy) Hook {
        return .{ .ctx = self, .func = onEvent };
    }
};

test "latch coupling: a get holds at most two latches, and only the leaf at the end" {
    var tree = try canonicalTree(.latch_coupling);
    defer tree.deinit(testing.allocator);
    for (lib.canonical) |key| {
        var spy: LatchSpy = .{ .tree = &tree };
        try testing.expectEqual(valueOf(key), tree.getHooked(testing.io, key, &spy.hook()));
        try testing.expectEqual(2, spy.max_held); // parent + child, never three
        try testing.expectEqual(1, spy.at_leaf_len);
    }
    try testing.expect(tree.nothingLocked(testing.io));
}

test "latch coupling: the safe-node rule decides which latches a put keeps" {
    const io = testing.io;
    var tree = try canonicalTree(.latch_coupling);
    defer tree.deinit(testing.allocator);
    //   #7[15]
    //   #2[6 10]                         #6[20]
    //   #0(1 3 5) #4(6 7) #1(10 12)      #5(15 17) #3(20 25 30)

    // Leaf #1 has room: everything above it is released.
    var spy: LatchSpy = .{ .tree = &tree };
    _ = try tree.putHooked(io, 11, valueOf(11), &spy.hook());
    try testing.expectEqualSlices(u32, &.{1}, spy.at_leaf[0..spy.at_leaf_len]);
    // A writer couples too: it held #7 while it latched #2, and #2 while it
    // latched #1. Looking at a child and releasing the parent BEFORE the
    // child is latched would show up here as 1.
    try testing.expectEqual(2, spy.max_held);

    // Leaf #3 is full, its parent #6 has room: the split stops at #6, so #6
    // stays latched and the root does not.
    spy = .{ .tree = &tree };
    _ = try tree.putHooked(io, 26, valueOf(26), &spy.hook());
    try testing.expectEqualSlices(u32, &.{ 3, 6 }, spy.at_leaf[0..spy.at_leaf_len]);
    try testing.expectEqual(2, spy.max_held); // #7+#6, then #6+#3: never three

    // Overwriting a key in a full leaf: the rule cannot know that no split
    // will happen, so it is as pessimistic as for a new key.
    spy = .{ .tree = &tree };
    try testing.expectEqual(valueOf(3), try tree.putHooked(io, 3, 33, &spy.hook()));
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, spy.at_leaf[0..spy.at_leaf_len]);

    // Fill #2, then insert into the full leaf #0 below it: the run of full
    // nodes reaches up to the root's child, so the root stays latched too.
    _ = try tree.put(io, 8, valueOf(8));
    _ = try tree.put(io, 9, valueOf(9));
    try testing.expectEqual(3, tree.table.node(.fromIndex(2)).len);
    spy = .{ .tree = &tree };
    _ = try tree.putHooked(io, 2, valueOf(2), &spy.hook());
    try testing.expectEqualSlices(u32, &.{ 0, 2, 7 }, spy.at_leaf[0..spy.at_leaf_len]);
    try testing.expectEqual(3, spy.max_held);

    try tree.validate();
    try testing.expect(tree.nothingLocked(io));
}

test "global protocols: an operation never touches a node latch" {
    for ([_]Protocol{ .global_mutex, .global_rwlock }) |protocol| {
        var tree = try canonicalTree(protocol);
        defer tree.deinit(testing.allocator);
        var spy: LatchSpy = .{ .tree = &tree };
        _ = try tree.putHooked(testing.io, 26, valueOf(26), &spy.hook());
        try testing.expectEqual(0, spy.max_held);
        // ... but it does hold the tree-wide lock at that point.
        const Check = struct {
            tree: *Tree,
            locked: bool = false,
            fn onEvent(ctx: *anyopaque, event: Hook.Event) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                if (event.point == .at_leaf) self.locked = !self.tree.nothingLocked(testing.io);
            }
        };
        var check: Check = .{ .tree = &tree };
        _ = tree.getHooked(testing.io, 26, &.{ .ctx = &check, .func = Check.onEvent });
        try testing.expect(check.locked);
        try testing.expect(tree.nothingLocked(testing.io));
    }
}

// ------------------------------------------------ 3. the hook with two threads

const Expect = struct { b: probe.OpSpec, mutex: probe.Outcome, rwlock: probe.Outcome, coupling: probe.Outcome };

fn expectProbes(setup: []const u64, a: probe.OpSpec, rows: []const Expect) !void {
    if (builtin.single_threaded) return error.SkipZigTest;
    for (rows) |row| {
        for (lib.protocols, [_]probe.Outcome{ row.mutex, row.rwlock, row.coupling }) |protocol, expected| {
            var tree = try canonicalTree(protocol);
            defer tree.deinit(testing.allocator);
            for (setup) |key| _ = try tree.put(testing.io, key, valueOf(key));
            const outcome = try probe.probe(&tree, testing.io, a, .{ .point = .at_leaf }, row.b);
            try testing.expectEqual(expected, outcome);
            // Both operations ran to completion afterwards.
            try tree.validate();
            try testing.expect(tree.nothingLocked(testing.io));
            for ([_]probe.OpSpec{ a, row.b }) |op| switch (op) {
                .put => |key| try testing.expectEqual(valueOf(key), tree.get(testing.io, key)),
                .get => {},
            };
        }
    }
}

const done: probe.Outcome = .completed;
const waits: probe.Outcome = .{ .blocked = .nil };
fn waitsAt(node: usize) probe.Outcome {
    return .{ .blocked = .fromIndex(node) };
}

test "probe: what a frozen reader allows" {
    try expectProbes(&.{}, .{ .get = 12 }, &.{
        // A mutex stops everybody; a reader-writer lock lets readers through;
        // latch coupling also lets a writer through, unless it needs the
        // very leaf the reader is on.
        .{ .b = .{ .get = 25 }, .mutex = waits, .rwlock = done, .coupling = done },
        .{ .b = .{ .get = 10 }, .mutex = waits, .rwlock = done, .coupling = done },
        .{ .b = .{ .put = 16 }, .mutex = waits, .rwlock = waits, .coupling = done },
        .{ .b = .{ .put = 11 }, .mutex = waits, .rwlock = waits, .coupling = waitsAt(1) },
    });
}

test "probe: what a frozen writer allows" {
    // Leaf #1 has room: the writer holds only that leaf.
    try expectProbes(&.{}, .{ .put = 11 }, &.{
        .{ .b = .{ .get = 25 }, .mutex = waits, .rwlock = waits, .coupling = done },
        .{ .b = .{ .get = 12 }, .mutex = waits, .rwlock = waits, .coupling = waitsAt(1) },
        .{ .b = .{ .put = 16 }, .mutex = waits, .rwlock = waits, .coupling = done },
    });
    // Leaf #3 is full: its parent #6 stays latched, the subtree under #6 is
    // closed, the subtree under #2 is not.
    try expectProbes(&.{}, .{ .put = 26 }, &.{
        .{ .b = .{ .get = 12 }, .mutex = waits, .rwlock = waits, .coupling = done },
        .{ .b = .{ .put = 11 }, .mutex = waits, .rwlock = waits, .coupling = done },
        .{ .b = .{ .get = 17 }, .mutex = waits, .rwlock = waits, .coupling = waitsAt(6) },
    });
    // Full leaf under a full parent: the latches reach the root and latch
    // coupling is no better than a tree-wide lock.
    try expectProbes(&.{ 8, 9 }, .{ .put = 2 }, &.{
        .{ .b = .{ .get = 25 }, .mutex = waits, .rwlock = waits, .coupling = waitsAt(7) },
    });
}

test "probe: mid-descent, the parent is still latched when the child has just been latched" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var tree = try canonicalTree(.latch_coupling);
    defer tree.deinit(testing.allocator);
    // Writer: put 26 has just latched #6. It has not looked at #6 yet, so it
    // still holds the root, and even a reader bound for #2 waits there.
    const after_6: probe.Pause = .{ .point = .latched, .node = .fromIndex(6) };
    try testing.expectEqual(waitsAt(7), try probe.probe(&tree, io, .{ .put = 26 }, after_6, .{ .get = 12 }));
    // Reader: get 12 has just latched leaf #1 and still holds #2 shared. A
    // put under #2 waits at #2; a reader passes; the root is free again.
    const after_1: probe.Pause = .{ .point = .latched, .node = .fromIndex(1) };
    try testing.expectEqual(waitsAt(2), try probe.probe(&tree, io, .{ .get = 12 }, after_1, .{ .put = 7 }));
    try testing.expectEqual(done, try probe.probe(&tree, io, .{ .get = 12 }, after_1, .{ .get = 7 }));
    try testing.expectEqual(done, try probe.probe(&tree, io, .{ .get = 12 }, after_1, .{ .put = 16 }));
    try tree.validate();
    try testing.expect(tree.nothingLocked(io));
}

test "convoy: a reader that waits keeps the root, and a writer bound elsewhere waits behind it" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var tree = try canonicalTree(.latch_coupling);
    defer tree.deinit(testing.allocator);
    // A = put 26 is frozen holding #6 and #3 (exclusive). With two threads,
    // `put 11` finishes next to it (see "what a frozen writer allows").
    var outcomes: [3]probe.Outcome = undefined;
    try probe.convoy(&tree, io, .{ .put = 26 }, .{ .point = .at_leaf }, &.{
        .{ .get = 17 }, // B: waits at #6, HOLDING #7 shared
        .{ .get = 12 }, // C: shares #7 with B and gets through
        .{ .put = 11 }, // D: needs #7 exclusive; B is in its way, not A
    }, &outcomes);
    try testing.expectEqualSlices(probe.Outcome, &.{ waitsAt(6), done, waitsAt(7) }, &outcomes);
    try tree.validate();
    try testing.expect(tree.nothingLocked(io));
    for ([_]u64{ 26, 11 }) |key| try testing.expectEqual(valueOf(key), tree.get(io, key));
}

test "convoy: one reader stalled on a leaf closes the tree for writers, three waits deep" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var tree = try canonicalTree(.latch_coupling);
    defer tree.deinit(testing.allocator);
    // A = get 25 is frozen on leaf #3 with one SHARED latch.
    var outcomes: [4]probe.Outcome = undefined;
    try probe.convoy(&tree, io, .{ .get = 25 }, .{ .point = .at_leaf }, &.{
        .{ .put = 26 }, // waits at #3 for A, holding #6 exclusive
        .{ .get = 17 }, // waits at #6 for the put, holding #7 shared
        .{ .get = 12 }, // shares #7 and gets through
        .{ .put = 11 }, // waits at #7 for the get 17
    }, &outcomes);
    try testing.expectEqualSlices(probe.Outcome, &.{ waitsAt(3), waitsAt(6), done, waitsAt(7) }, &outcomes);
    try tree.validate();
    try testing.expect(tree.nothingLocked(io));
    for ([_]u64{ 26, 11 }) |key| try testing.expectEqual(valueOf(key), tree.get(io, key));
}

test "probe reports a pause point that is never reached" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var tree = try canonicalTree(.global_mutex);
    defer tree.deinit(testing.allocator);
    // A global protocol never emits `root_loaded`.
    try testing.expectError(error.PauseNotReached, probe.probe(&tree, testing.io, .{ .get = 1 }, .{ .point = .root_loaded }, .{ .get = 2 }));
    try testing.expect(tree.nothingLocked(testing.io));
}

test "latch coupling: a reader that latched a replaced root starts again" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var tree: Tree = try .init(testing.allocator, 4, .latch_coupling, 16);
    defer tree.deinit(testing.allocator);
    for ([_]u64{ 10, 20, 5 }) |key| _ = try tree.put(io, key, valueOf(key));

    // The reader has read "root = #0" and holds nothing.
    var reader: probe.Actor = .{ .tree = &tree, .io = io, .op = .{ .get = 20 }, .pause = .{ .point = .root_loaded } };
    try reader.spawn();
    reader.waitSettled();
    // Whatever happens next, the reader thread must be released and joined.
    {
        errdefer {
            reader.release();
            reader.join();
        }
        try testing.expect(reader.frozen);
        // The root splits: #0 keeps (5 6); key 20 moves to the new leaf #1.
        _ = try tree.put(io, 6, valueOf(6));
        try testing.expectEqual(2, tree.root.load(.acquire).index());
        try testing.expectEqual(0, tree.stats.root_restarts.load(.monotonic));
    }
    reader.release();
    reader.join();
    // Without the second look at the root id the reader would search #0,
    // which no longer holds 20, and answer "not found".
    try testing.expectEqual(2000, try reader.result);
    try testing.expectEqual(1, tree.stats.root_restarts.load(.monotonic));
    try testing.expect(tree.nothingLocked(io));
}

test "latch coupling: a writer that latched a replaced root starts again" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var tree: Tree = try .init(testing.allocator, 4, .latch_coupling, 16);
    defer tree.deinit(testing.allocator);
    for ([_]u64{ 10, 20, 5 }) |key| _ = try tree.put(io, key, valueOf(key));

    // The writer has read "root = #0" and holds nothing.
    var writer: probe.Actor = .{ .tree = &tree, .io = io, .op = .{ .put = 30 }, .pause = .{ .point = .root_loaded } };
    try writer.spawn();
    writer.waitSettled();
    {
        errdefer {
            writer.release();
            writer.join();
        }
        try testing.expect(writer.frozen);
        // The root splits: #0 keeps (5 6); (10 20) move to the new leaf #1.
        _ = try tree.put(io, 6, valueOf(6));
        try testing.expectEqual(2, tree.root.load(.acquire).index());
    }
    writer.release();
    writer.join();
    try testing.expectEqual(null, try writer.result);
    try testing.expectEqual(1, tree.stats.root_restarts.load(.monotonic));
    // The restart must not leave its latch on the old root.
    try testing.expect(tree.nothingLocked(io));
    try tree.validate();
    // Without the second look the writer would put 30 into #0, the LEFT
    // leaf, to the left of separator 10: no search would ever find it.
    try testing.expectEqual(3000, tree.get(io, 30));
    try expectDump(&tree,
        \\height 2, 5 keys, 3 nodes
        \\  level 0: #2[10]
        \\  leaves : #0(5 6) -> #1(10 20 30)
        \\
    );
}

test "a new root is complete before it is published" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    for (lib.protocols) |protocol| {
        var tree: Tree = try .init(testing.allocator, 4, protocol, 16);
        defer tree.deinit(testing.allocator);
        for ([_]u64{ 10, 20, 5 }) |key| _ = try tree.put(io, key, valueOf(key));

        // put 6 splits the root leaf #0 and is frozen with the new root #2
        // built but not yet published.
        var writer: probe.Actor = .{ .tree = &tree, .io = io, .op = .{ .put = 6 }, .pause = .{ .point = .root_built } };
        try writer.spawn();
        writer.waitSettled();
        const frozen = writer.frozen;
        // Read while the writer is frozen. (The writer's thread wrote these
        // fields before it set `settled`, so reading them here is no race.)
        const published = tree.root.load(.acquire);
        const new_root = tree.table.node(.fromIndex(2)).*;
        writer.release();
        writer.join();

        try testing.expect(frozen);
        try testing.expectEqual(0, published.index()); // still the old root
        try testing.expect(!new_root.isLeaf()); //        and #2 is finished:
        try testing.expectEqualSlices(u64, &.{10}, new_root.keySlice());
        try testing.expectEqual(0, new_root.kind.internal.children[0].index());
        try testing.expectEqual(1, new_root.kind.internal.children[1].index());
        try testing.expectEqual(null, try writer.result);
        try testing.expectEqual(2, tree.root.load(.acquire).index());
        try tree.validate();
        try testing.expect(tree.nothingLocked(io));
    }
}

test "a thread waiting for the old root's latch starts again when the root is replaced" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    for ([_]probe.OpSpec{ .{ .get = 20 }, .{ .put = 30 } }) |b_op| {
        var tree: Tree = try .init(testing.allocator, 4, .latch_coupling, 16);
        defer tree.deinit(testing.allocator);
        for ([_]u64{ 10, 20, 5 }) |key| _ = try tree.put(io, key, valueOf(key));
        // A = put 6 is frozen with the new root #2 built but not published.
        // It must still hold the old root #0 exclusively: a writer keeps its
        // latches until the last node is written. B reads "root = #0" and so
        // has to WAIT at #0. (The two tests above freeze the thread before
        // it asks for the latch; here it is already in the queue.)
        const outcome = try probe.probe(&tree, io, .{ .put = 6 }, .{ .point = .root_built }, b_op);
        try testing.expectEqual(waitsAt(0), outcome);
        // When B gets #0 at last it is no longer the root: one restart. A
        // B that looked at the root id only BEFORE it queued would go on
        // into #0, the left half, and miss 20 (or misplace 30).
        try testing.expectEqual(1, tree.stats.root_restarts.load(.monotonic));
        try testing.expect(tree.nothingLocked(io));
        try tree.validate();
        try testing.expectEqual(2000, tree.get(io, 20));
        switch (b_op) {
            .put => |key| try testing.expectEqual(valueOf(key), tree.get(io, key)),
            .get => {},
        }
    }
}

/// A `get` that its test stops three times: when it has read the root id,
/// when it has latched that node, and at the first event after that.
const SteppedGet = struct {
    tree: *Tree,
    io: Io,
    key: u64,
    /// `at[i]` is set by the reader when it reaches stop i; it then waits
    /// for `go[i]`.
    at: [3]Io.Event = @splat(.unset),
    go: [3]Io.Event = @splat(.unset),
    stops: usize = 0,
    /// The event of the third stop. Written before `at[2]` is set.
    third: ?Hook.Event = null,
    result: ?u64 = null,

    fn onEvent(ctx: *anyopaque, event: Hook.Event) void {
        const self: *SteppedGet = @ptrCast(@alignCast(ctx));
        const wanted: ?Hook.Point = switch (self.stops) {
            0 => .root_loaded,
            1 => .latched,
            2 => null, // whatever comes first
            else => return,
        };
        if (wanted != null and wanted.? != event.point) return;
        const i = self.stops;
        self.stops += 1;
        if (i == 2) self.third = event;
        self.at[i].set(self.io);
        self.go[i].waitUncancelable(self.io);
    }

    fn run(self: *SteppedGet) void {
        const hook: Hook = .{ .ctx = self, .func = onEvent };
        self.result = self.tree.getHooked(self.io, self.key, &hook);
    }

    /// Lets the reader run from stop `i` to the next one.
    fn step(self: *SteppedGet, i: usize) void {
        self.go[i].set(self.io);
        if (i + 1 < self.at.len) self.at[i + 1].waitUncancelable(self.io);
    }
};

test "latch order at the root: a restart lets go of the old root before it asks for the new one" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var tree: Tree = try .init(testing.allocator, 4, .latch_coupling, 16);
    defer tree.deinit(testing.allocator);
    for ([_]u64{ 10, 20, 5 }) |key| _ = try tree.put(io, key, valueOf(key));

    var reader: SteppedGet = .{ .tree = &tree, .io = io, .key = 20 };
    const thread = try std.Thread.spawn(.{}, SteppedGet.run, .{&reader});
    reader.at[0].waitUncancelable(io); // the reader has read "root = #0"
    const split = tree.put(io, 6, valueOf(6)); // the root is #2 now, #0 its left child
    reader.step(0); // the reader holds #0 (shared) and has not looked again
    const stale = latched(&tree);
    reader.step(1); // its next event, whatever it is
    // The reader is frozen again. It must hold NOTHING: #0 is below the
    // root now, and asking for #2 while holding #0 would be a latch request
    // going UP the tree. A writer that holds #2 and wants #0 goes down. The
    // two would wait for each other forever.
    const third = reader.third.?;
    const held = latched(&tree);
    // Such a writer, while the reader is frozen: it must get through. If
    // the reader kept a latch, the writer reports that it is stuck, which
    // ends this wait; nothing here can hang.
    var writer: probe.Actor = .{ .tree = &tree, .io = io, .op = .{ .put = 7 } };
    const spawned = writer.spawn();
    if (spawned) |_| writer.waitSettled() else |_| {}
    const writer_blocked_at = writer.blocked_at;
    // Let everybody finish before the first assertion.
    reader.step(2);
    thread.join();
    if (spawned) |_| writer.join() else |_| {}

    try spawned;
    try testing.expectEqual(null, try split);
    try testing.expectEqualSlices(u32, &.{0}, stale.slice());
    try testing.expectEqual(Hook.Event{ .point = .root_loaded, .node = .fromIndex(2) }, third);
    try testing.expectEqualSlices(u32, &.{}, held.slice());
    try testing.expectEqual(null, writer_blocked_at);
    try testing.expectEqual(1, tree.stats.root_restarts.load(.monotonic));
    try testing.expectEqual(2000, reader.result);
    try testing.expect(tree.nothingLocked(io));
    try tree.validate();
    try testing.expectEqual(700, tree.get(io, 7));
}

// ------------------------------------------------------------------ 4. stress

fn stressOnce(protocol: Protocol, config: stress.Config, node_capacity: u32) !stress.Report {
    const gpa = testing.allocator;
    var tree: Tree = try .init(gpa, 4, protocol, node_capacity);
    defer tree.deinit(gpa);
    // Thread-safe arena on top of the (thread-safe) testing allocator: the
    // workers' logs are freed in one go, and a leak still fails the test.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const report = try stress.run(&tree, testing.io, gpa, arena.allocator(), config);
    try testing.expect(tree.nothingLocked(testing.io));
    return report;
}

test "stress: 4 threads, disjoint and overlapping keys, every protocol" {
    if (builtin.single_threaded) return error.SkipZigTest;
    for (lib.protocols) |protocol| {
        for ([_]bool{ false, true }) |overlapping| {
            for ([_]u64{ 1, 2 }) |seed| {
                const config: stress.Config = .{
                    .threads = 4,
                    .ops_per_thread = 4000,
                    .seed = seed,
                    .key_space = if (overlapping) 1500 else 400,
                    .overlapping = overlapping,
                };
                const r = try stressOnce(protocol, config, config.nodeCapacity());
                try testing.expect(r.valid);
                try testing.expectEqual(0, r.mismatches);
                try testing.expectEqual(0, r.lost);
                try testing.expectEqual(0, r.failed);
                try testing.expectEqual(r.expected_keys, r.keys);
                // Every key was inserted exactly once, whoever got there first.
                try testing.expectEqual(r.expected_keys, r.fresh);
                try testing.expect(r.ok());
            }
        }
    }
}

test "stress: a hot spot (few keys, constant overwrites and root splits early on)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    for (lib.protocols) |protocol| {
        const config: stress.Config = .{ .threads = 4, .ops_per_thread = 3000, .seed = 7, .key_space = 24, .overlapping = true };
        const r = try stressOnce(protocol, config, config.nodeCapacity());
        try testing.expect(r.ok());
    }
}

test "stress: the node table runs out under concurrency and the tree stays valid" {
    if (builtin.single_threaded) return error.SkipZigTest;
    for (lib.protocols) |protocol| {
        const config: stress.Config = .{ .threads = 4, .ops_per_thread = 2000, .seed = 3, .key_space = 5000, .overlapping = true };
        // 40 nodes of order 4 hold at most 120 keys: most puts must fail.
        const r = try stressOnce(protocol, config, 40);
        try testing.expect(r.failed > 0);
        try testing.expect(r.valid);
        // Only successful puts are logged, so the oracle still applies.
        try testing.expectEqual(0, r.mismatches);
        try testing.expectEqual(0, r.lost);
        try testing.expectEqual(r.expected_keys, r.keys);
        try testing.expectEqual(r.expected_keys, r.fresh);
    }
}

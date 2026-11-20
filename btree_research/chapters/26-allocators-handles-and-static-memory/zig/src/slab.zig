//! A bitmap slab allocator addressed by 32-bit handles.
//!
//! Modelled on DuckDB's `FixedSizeAllocator` (db_study/duckdb/src/execution/index/
//! fixed_size_allocator.cpp): memory is cut into slabs, a slab is a bitmap followed by
//! equally sized slots, and the tree stores `(slab id, slot)` handles in place of
//! pointers. As in DuckDB, a SET bit means the slot is FREE.
//!
//! Two policies share this one type:
//!   * `release_empty = true`  : DuckDB style. Slabs are created on demand and an empty
//!     slab goes back to the backing allocator (except the last one with free space).
//!   * `release_empty = false` : TigerBeetle `NodePool` style. `reserve` everything in
//!     init, never give memory back, and `create` fails when the pool is exhausted.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;

/// What the tree stores where a pointer-based tree stores `*Node`. 4 bytes, not 8, and
/// it stays meaningful if the slab is moved, written to disk, or reloaded elsewhere.
pub const Handle = packed struct(u32) {
    /// Slot inside the slab (so a slab has at most 256 slots).
    slot: u8,
    /// Which slab. The all-ones value is reserved for `none`.
    slab: u23,
    /// Size class: which pool this handle belongs to. Checked on every dereference,
    /// so a leaf handle can never be used to read an interior node.
    class: u1,

    pub const none: Handle = @bitCast(@as(u32, 0xFFFF_FFFF));

    pub fn isNone(h: Handle) bool {
        return @as(u32, @bitCast(h)) == 0xFFFF_FFFF;
    }

    pub fn toInt(h: Handle) u32 {
        return @bitCast(h);
    }

    /// Printed as `L2.5` / `I0.1`: class letter, slab id, slot. Use with `{f}`.
    pub fn format(h: Handle, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (h.isNone()) return w.writeAll("none");
        try w.print("{c}{d}.{d}", .{ @as(u8, if (h.class == 0) 'L' else 'I'), h.slab, h.slot });
    }
};

pub const Options = struct {
    /// Stamped into every handle this pool hands out.
    class: u1 = 0,
    /// See the file comment.
    release_empty: bool = true,
};

pub fn SlabPool(comptime T: type, comptime slots_per_slab: u16) type {
    comptime assert(slots_per_slab >= 1 and slots_per_slab <= 256);
    const words = (slots_per_slab + 63) / 64;

    return struct {
        const Pool = @This();
        pub const slots = slots_per_slab;

        /// One slab: bitmap first, then the slots, exactly DuckDB's buffer layout.
        /// There is no per-item header: that is the point of a single-size allocator.
        pub const Slab = struct {
            /// Bit i set <=> slot i is free.
            free: [words]u64,
            used: u16,
            items: [slots_per_slab]T,
        };

        backing: Allocator,
        options: Options,
        /// Slab id -> slab. Slabs are allocated one by one, so they never move and a
        /// `*T` stays valid until that item is destroyed. A released slab leaves a
        /// `null` whose id is reused by the next new slab.
        slabs: std.ArrayList(?*Slab) = .empty,
        slab_count: u32 = 0,
        /// Number of live items over all slabs.
        live: u32 = 0,
        /// Invariant: no slab with id < hint has a free slot. Lets `create` skip the
        /// full prefix (DuckDB caches one `buffer_with_free_space` for the same reason).
        hint: u32 = 0,
        /// During `vacuumBegin .. vacuumEnd`: the slab being evacuated. `create` never
        /// allocates from it.
        victim: ?u32 = null,
        /// How often `create` failed because the backing allocator said no.
        grow_failures: u32 = 0,

        pub fn init(backing: Allocator, options: Options) Pool {
            return .{ .backing = backing, .options = options };
        }

        /// Frees every slab, live items included: a slab pool can be torn down like an
        /// arena, in O(slabs), without visiting the items.
        pub fn deinit(pool: *Pool) void {
            for (pool.slabs.items) |maybe| if (maybe) |slab| pool.backing.destroy(slab);
            pool.slabs.deinit(pool.backing);
            pool.* = undefined;
        }

        /// Create slabs until at least `count` exist (the "allocate everything in init"
        /// half of static allocation).
        ///
        /// The directory is sized ONCE, exactly, before the first slab is created.
        /// Growing it append by append would reallocate, and a reallocation frees the
        /// old buffer: under a `StaticAllocator` the first `free` ends the init phase,
        /// so the next slab would be refused while the program is still starting up.
        /// For the same reason call `reserve` once per pool, with the final count.
        pub fn reserve(pool: *Pool, count: u32) Allocator.Error!void {
            if (count > pool.slabs.capacity) try pool.slabs.ensureTotalCapacityPrecise(pool.backing, count);
            while (pool.slab_count < count) _ = try pool.addSlab();
        }

        pub fn freeSlots(pool: *const Pool) u32 {
            return pool.slab_count * slots - pool.live;
        }

        fn addSlab(pool: *Pool) Allocator.Error!u32 {
            // Reuse the lowest released id, so ids (and therefore handles) stay small.
            const id: u32 = for (pool.slabs.items, 0..) |maybe, i| {
                if (maybe == null) break @intCast(i);
            } else @intCast(pool.slabs.items.len);
            // Make room in the directory BEFORE creating the slab: if the second
            // allocation fails there is nothing to undo.
            if (id == pool.slabs.items.len) try pool.slabs.ensureUnusedCapacity(pool.backing, 1);
            const slab = try pool.backing.create(Slab);
            slab.free = @splat(0);
            for (0..slots) |i| slab.free[i / 64] |= @as(u64, 1) << @intCast(i % 64);
            slab.used = 0;
            if (id == pool.slabs.items.len) pool.slabs.appendAssumeCapacity(slab) else pool.slabs.items[id] = slab;
            pool.slab_count += 1;
            pool.hint = @min(pool.hint, id);
            return id;
        }

        fn hasSpace(pool: *const Pool, id: u32) bool {
            if (pool.victim == id) return false;
            const slab = pool.slabs.items[id] orelse return false;
            return slab.used < slots;
        }

        /// Allocate one slot: the lowest free slot of the lowest slab that has one.
        /// The contents are undefined, as with `Allocator.create`.
        pub fn create(pool: *Pool) Allocator.Error!Handle {
            var id = pool.hint;
            while (id < pool.slabs.items.len and !pool.hasSpace(id)) id += 1;
            if (id == pool.slabs.items.len) {
                id = pool.addSlab() catch |err| {
                    pool.grow_failures += 1;
                    return err;
                };
            }
            if (pool.victim == null) pool.hint = id;

            const slab = pool.slabs.items[id].?;
            for (&slab.free, 0..) |*word, w| {
                if (word.* == 0) continue;
                // Lowest set bit = lowest free slot. DuckDB hand-rolls this as a six-step
                // binary search (`AllocateSegment`, fixed_size_buffer.cpp:145-199); `@ctz` is one instruction.
                const bit: u6 = @intCast(@ctz(word.*));
                word.* &= ~(@as(u64, 1) << bit);
                slab.used += 1;
                pool.live += 1;
                return .{ .slot = @intCast(w * 64 + bit), .slab = @intCast(id), .class = pool.options.class };
            }
            unreachable; // hasSpace() said there is a free slot
        }

        pub fn isLive(pool: *const Pool, h: Handle) bool {
            if (h.isNone() or h.class != pool.options.class) return false;
            if (h.slab >= pool.slabs.items.len or h.slot >= slots) return false;
            const slab = pool.slabs.items[h.slab] orelse return false;
            return slab.free[h.slot / 64] & (@as(u64, 1) << @intCast(h.slot % 64)) == 0;
        }

        /// Handle -> pointer: one directory load plus an index. This is the price of
        /// handles (DuckDB pays a hash-map lookup here, fixed_size_allocator.hpp:50-54).
        pub fn get(pool: *const Pool, h: Handle) *T {
            assert(pool.isLive(h)); // stale handle, wrong class or double free
            return &pool.slabs.items[h.slab].?.items[h.slot];
        }

        pub fn destroy(pool: *Pool, h: Handle) void {
            assert(pool.isLive(h));
            const slab = pool.slabs.items[h.slab].?;
            slab.free[h.slot / 64] |= @as(u64, 1) << @intCast(h.slot % 64);
            slab.used -= 1;
            pool.live -= 1;
            if (pool.victim != h.slab) pool.hint = @min(pool.hint, h.slab);
            if (slab.used != 0 or !pool.options.release_empty) return;

            // The slab is empty. Keep it if it is the only place the next `create`
            // could go; otherwise a create/destroy pair at a slab boundary would
            // allocate and free a whole slab each time (DuckDB keeps it for the same
            // reason, fixed_size_allocator.cpp:121-128).
            const other_space = pool.victim == h.slab or for (0..pool.slabs.items.len) |id| {
                if (id != h.slab and pool.hasSpace(@intCast(id))) break true;
            } else false;
            if (!other_space) return;
            pool.backing.destroy(slab);
            pool.slabs.items[h.slab] = null;
            pool.slab_count -= 1;
        }

        // ---- vacuum: evacuate the emptiest slab so it can be released -------------

        /// Picks a victim if a whole slab's worth of slots is free elsewhere. The owner
        /// of the handles (the tree) must then `relocate` every item of the victim and
        /// call `vacuumEnd`. Only handles make this possible: a `*T` cannot be moved
        /// behind the tree's back.
        pub fn vacuumBegin(pool: *Pool) bool {
            assert(pool.victim == null and pool.options.release_empty);
            if (pool.slab_count < 2 or pool.freeSlots() < slots) return false;
            var best: ?u32 = null;
            for (pool.slabs.items, 0..) |maybe, id| {
                const slab = maybe orelse continue;
                // `<=`: among equally empty slabs take the highest id, so data
                // collects in the low slabs.
                if (best == null or slab.used <= pool.slabs.items[best.?].?.used) best = @intCast(id);
            }
            pool.victim = best;
            pool.hint = 0; // conservative: the victim no longer counts as free space
            return true;
        }

        pub fn isVictim(pool: *const Pool, h: Handle) bool {
            return pool.victim != null and pool.victim.? == h.slab;
        }

        /// Move one item out of the victim slab and return its new handle. Cannot fail:
        /// `vacuumBegin` checked that the other slabs have room, so no memory is needed.
        pub fn relocate(pool: *Pool, old: Handle) Handle {
            assert(pool.isVictim(old));
            const new = pool.create() catch unreachable;
            pool.get(new).* = pool.get(old).*;
            pool.destroy(old); // releases the victim slab when its last item leaves
            return new;
        }

        pub fn vacuumEnd(pool: *Pool) void {
            const id = pool.victim.?;
            if (pool.slabs.items[id]) |slab| {
                // Only possible if the victim was the kept empty slab: nothing had to
                // move, release it here.
                assert(slab.used == 0); // otherwise the owner forgot to relocate an item
                pool.backing.destroy(slab);
                pool.slabs.items[id] = null;
                pool.slab_count -= 1;
            }
            pool.victim = null;
            pool.hint = 0;
        }

        /// One line per pool, for the demo and the visualization: `0[##.#] 1[#...]`.
        pub fn writeMap(pool: *const Pool, w: *std.Io.Writer) std.Io.Writer.Error!void {
            for (pool.slabs.items, 0..) |maybe, id| {
                if (id != 0) try w.writeByte(' ');
                const slab = maybe orelse {
                    try w.print("{d}[released]", .{id});
                    continue;
                };
                try w.print("{d}[", .{id});
                for (0..slots) |i| {
                    const free = slab.free[i / 64] & (@as(u64, 1) << @intCast(i % 64)) != 0;
                    try w.writeByte(if (free) '.' else '#');
                }
                try w.writeByte(']');
            }
            if (pool.slabs.items.len == 0) try w.writeAll("(no slabs)");
        }

        // ---- the same pool as a std.mem.Allocator ----------------------------------
        //
        // Useful to plug the pool under code that wants an `Allocator` (for example
        // `gpa.create(T)`), but note what is lost: `free` receives a pointer, so the
        // slab must be found by address (a linear scan here), and nothing can ever be
        // relocated. The handle API above is the real interface.

        pub fn allocator(pool: *Pool) Allocator {
            return .{ .ptr = pool, .vtable = &vtable };
        }

        const vtable: Allocator.VTable = .{ .alloc = vtAlloc, .resize = vtResize, .remap = vtRemap, .free = vtFree };

        fn vtAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            _ = ret_addr;
            const pool: *Pool = @ptrCast(@alignCast(ctx));
            // One size class: anything that fits a slot is served, anything else refused.
            if (len > @sizeOf(T) or alignment.toByteUnits() > @alignOf(T)) return null;
            const h = pool.create() catch return null;
            return @ptrCast(pool.get(h));
        }

        fn vtResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            _ = .{ ctx, memory, alignment, ret_addr };
            return new_len <= @sizeOf(T); // every allocation owns a whole slot
        }

        fn vtRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            return if (vtResize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
        }

        fn vtFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            _ = .{ alignment, ret_addr };
            const pool: *Pool = @ptrCast(@alignCast(ctx));
            const addr = @intFromPtr(memory.ptr);
            for (pool.slabs.items, 0..) |maybe, id| {
                const slab = maybe orelse continue;
                const first = @intFromPtr(&slab.items);
                if (addr < first or addr >= first + @sizeOf(@TypeOf(slab.items))) continue;
                // @divExact: a pointer into the middle of a slot is a bug, not a slot.
                const slot = @divExact(addr - first, @sizeOf(T));
                return pool.destroy(.{ .slot = @intCast(slot), .slab = @intCast(id), .class = pool.options.class });
            }
            unreachable; // not our memory
        }
    };
}

// ---------------------------------------------------------------------------------------
const testing = std.testing;

fn expectMap(pool: anytype, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try pool.writeMap(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "handle is 32 bits: slot, slab, class" {
    try testing.expectEqual(4, @sizeOf(Handle));
    const h: Handle = .{ .slot = 5, .slab = 2, .class = 1 };
    try testing.expectEqual(0x8000_0205, h.toInt());
    try testing.expect(Handle.none.isNone() and !h.isNone());
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("I2.5", try std.fmt.bufPrint(&buf, "{f}", .{h}));
}

test "slots fill in order and the lowest hole is reused first" {
    var pool: SlabPool(u64, 4) = .init(testing.allocator, .{});
    defer pool.deinit();
    var hs: [6]Handle = undefined;
    for (&hs, 0..) |*h, i| {
        h.* = try pool.create();
        pool.get(h.*).* = i * 100;
    }
    try expectMap(&pool, "0[####] 1[##..]");
    try testing.expectEqual(Handle{ .slot = 1, .slab = 1, .class = 0 }, hs[5]);

    pool.destroy(hs[3]);
    pool.destroy(hs[1]);
    try expectMap(&pool, "0[#.#.] 1[##..]");
    try testing.expect(!pool.isLive(hs[1]));
    const again = try pool.create();
    try testing.expectEqual(hs[1], again); // lowest slab, lowest slot
    try testing.expectEqual(200, pool.get(hs[2]).*); // neighbours untouched
    try testing.expectEqual(5, pool.live);
    try testing.expectEqual(3, pool.freeSlots());
}

test "an empty slab is released, but not the last one with free space" {
    var pool: SlabPool(u64, 2) = .init(testing.allocator, .{});
    defer pool.deinit();
    const a = try pool.create();
    const b = try pool.create();
    const c = try pool.create();
    const d = try pool.create();
    const e = try pool.create();
    try expectMap(&pool, "0[##] 1[##] 2[#.]");
    pool.destroy(c);
    pool.destroy(d); // slab 1 empty, slab 2 still has space: release slab 1
    try expectMap(&pool, "0[##] 1[released] 2[#.]");
    pool.destroy(e); // slab 2 empty and the only one with space: keep it
    try expectMap(&pool, "0[##] 1[released] 2[..]");
    pool.destroy(a);
    pool.destroy(b); // slab 0 empty, slab 2 has space: release slab 0
    try expectMap(&pool, "0[released] 1[released] 2[..]");
    try testing.expectEqual(1, pool.slab_count);
    // A released id is reused before the directory grows.
    _ = try pool.create();
    _ = try pool.create();
    const f = try pool.create();
    try testing.expectEqual(0, f.slab);
    try expectMap(&pool, "0[#.] 1[released] 2[##]");
}

test "a bitmap longer than one word" {
    var pool: SlabPool(u8, 100) = .init(testing.allocator, .{});
    defer pool.deinit();
    for (0..130) |i| {
        const h = try pool.create();
        try testing.expectEqual(i / 100, h.slab);
        try testing.expectEqual(i % 100, h.slot);
    }
    try testing.expectEqual(70, pool.freeSlots());
}

test "static policy: reserve, then no growth and no release" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var pool: SlabPool(u64, 2) = .init(failing.allocator(), .{ .release_empty = false });
    defer pool.deinit();
    try pool.reserve(2);
    const allocations = failing.allocations;
    failing.fail_index = failing.alloc_index; // every later allocation fails

    var hs: [4]Handle = undefined;
    for (&hs) |*h| h.* = try pool.create();
    try testing.expectError(error.OutOfMemory, pool.create());
    try testing.expectEqual(1, pool.grow_failures);
    for (hs) |h| pool.destroy(h);
    try expectMap(&pool, "0[..] 1[..]"); // nothing was given back
    try testing.expectEqual(allocations, failing.allocations);
    try testing.expectEqual(0, failing.deallocations);
}

// Regression: `reserve` used to grow the slab directory one append at a time. Every
// growth frees the old directory, and a wrapper that treats a free as "start-up is
// over" (StaticAllocator, TigerBeetle's original) then refused slab number 17.
test "reserve never frees, so it works under a StaticAllocator" {
    const StaticAllocator = @import("static_allocator.zig").StaticAllocator;
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var static: StaticAllocator = .init(failing.allocator());
    var pool: SlabPool(u64, 4) = .init(static.allocator(), .{ .release_empty = false });
    try pool.reserve(400);
    try testing.expectEqual(StaticAllocator.State.init, static.state);
    try testing.expectEqual(0, static.refused);
    try testing.expectEqual(0, failing.deallocations);
    try testing.expectEqual(401, failing.allocations); // 400 slabs + one directory
    try testing.expectEqual(400, pool.slab_count);

    static.freeze();
    for (0..1600) |_| _ = try pool.create(); // every reserved slot is usable
    try testing.expectError(error.OutOfMemory, pool.create());
    static.thaw();
    pool.deinit();
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "reserve under allocation failure leaks nothing" {
    const Scenario = struct {
        fn run(gpa: Allocator) !void {
            var pool: SlabPool(u64, 2) = .init(gpa, .{ .release_empty = false });
            defer pool.deinit();
            try pool.reserve(5);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Scenario.run, .{});
}

test "create under allocation failure leaks nothing" {
    const Scenario = struct {
        fn run(gpa: Allocator) !void {
            var pool: SlabPool(u64, 2) = .init(gpa, .{});
            defer pool.deinit();
            for (0..7) |_| _ = try pool.create();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Scenario.run, .{});
}

test "vacuum evacuates the emptiest slab" {
    var pool: SlabPool(u64, 4) = .init(testing.allocator, .{});
    defer pool.deinit();
    var hs: [12]Handle = undefined;
    for (&hs, 0..) |*h, i| {
        h.* = try pool.create();
        pool.get(h.*).* = i;
    }
    try testing.expect(!pool.vacuumBegin()); // full: nothing to gain
    for ([_]usize{ 1, 2, 4, 5, 6, 9 }) |i| pool.destroy(hs[i]);
    try expectMap(&pool, "0[#..#] 1[...#] 2[#.##]");

    try testing.expect(pool.vacuumBegin());
    try testing.expect(pool.isVictim(hs[7]) and !pool.isVictim(hs[0]));
    hs[7] = pool.relocate(hs[7]);
    pool.vacuumEnd();
    try expectMap(&pool, "0[##.#] 1[released] 2[#.##]");
    try testing.expectEqual(7, pool.get(hs[7]).*); // same value, new handle
    try testing.expectEqual(Handle{ .slot = 1, .slab = 0, .class = 0 }, hs[7]);
}

test "the pool behind the std.mem.Allocator interface" {
    const Node = struct { keys: [3]u64, len: u8 };
    var pool: SlabPool(Node, 4) = .init(testing.allocator, .{});
    defer pool.deinit();
    const a = pool.allocator();

    const n1 = try a.create(Node);
    const n2 = try a.create(Node);
    const small = try a.alloc(u8, 8); // fits a slot: served (and wastes the rest)
    try testing.expectEqual(3, pool.live);
    try testing.expectError(error.OutOfMemory, a.alloc(u64, 100)); // not this size class
    a.destroy(n1);
    try testing.expectEqual(@intFromPtr(n1), @intFromPtr(try a.create(Node))); // slot reused
    a.destroy(n2);
    a.free(small);
    try testing.expectEqual(1, pool.live);
}

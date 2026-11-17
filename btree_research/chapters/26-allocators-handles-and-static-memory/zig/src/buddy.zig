//! A binary buddy allocator over one caller-provided buffer (textbook algorithm, Knuth
//! TAOCP 2.5; none of the six studied databases ships one for its index).
//!
//! The heap is 2^heap_log2 bytes and is only ever cut in halves: a block of order k is
//! 2^(min_log2 + k) bytes and starts at a multiple of its own size. A request is rounded
//! up to a power of two; if no block of that order is free, a larger one is split and
//! the unused halves ("buddies") go on free lists. On free, a block whose buddy is also
//! free merges with it, again and again, so the heap coalesces back into large blocks.
//!
//! Where a slab serves ONE size, a buddy allocator serves a geometric ladder of sizes
//! from one region. That makes it the natural allocator UNDER the slab pools: slabs of
//! different size classes, and other large buffers, share one fixed arena.
//!
//! All bookkeeping lives in side arrays indexed by "minimum block number", not inside
//! the free blocks, so the managed bytes are never touched by the allocator itself.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;

pub fn BuddyAllocator(comptime heap_log2: u6, comptime min_log2: u6) type {
    comptime assert(heap_log2 >= min_log2 and heap_log2 - min_log2 <= 20);
    const max_order = heap_log2 - min_log2;
    const leaf_count = 1 << max_order; // number of minimum-size blocks
    const none = std.math.maxInt(u32);

    return struct {
        const Buddy = @This();
        pub const heap_size = 1 << heap_log2;
        pub const min_block = 1 << min_log2;
        /// Every block start is a multiple of its size from `base`, so this is the
        /// strictest alignment the allocator can promise.
        pub const heap_align: Alignment = .fromByteUnits(@min(heap_size, 4096));

        const State = enum(u8) {
            /// Not the first minimum block of any block.
            inside,
            /// First minimum block of a free block (which is on a free list).
            free,
            /// First minimum block of an allocated block.
            used,
        };

        base: [*]u8,
        /// Per minimum block; `order` and the links are meaningful only where a block
        /// starts.
        state: [leaf_count]State,
        order: [leaf_count]u8,
        next: [leaf_count]u32,
        prev: [leaf_count]u32,
        /// One doubly linked free list per order (doubly linked so that a buddy can be
        /// unlinked from the middle when it merges).
        heads: [max_order + 1]u32,
        /// Bytes the callers asked for, and bytes actually set aside for them. The
        /// difference is internal fragmentation, the cost of power-of-two rounding.
        requested: usize,
        granted: usize,

        pub fn init(buffer: []align(heap_align.toByteUnits()) u8) Buddy {
            assert(buffer.len == heap_size);
            var b: Buddy = .{
                .base = buffer.ptr,
                .state = @splat(.inside),
                .order = @splat(0),
                .next = @splat(none),
                .prev = @splat(none),
                .heads = @splat(none),
                .requested = 0,
                .granted = 0,
            };
            b.pushFree(0, max_order); // the whole heap is one free block
            return b;
        }

        fn pushFree(b: *Buddy, block: u32, k: u8) void {
            b.state[block] = .free;
            b.order[block] = k;
            b.prev[block] = none;
            b.next[block] = b.heads[k];
            if (b.heads[k] != none) b.prev[b.heads[k]] = block;
            b.heads[k] = block;
        }

        fn unlinkFree(b: *Buddy, block: u32) void {
            const k = b.order[block];
            if (b.prev[block] != none) b.next[b.prev[block]] = b.next[block] else b.heads[k] = b.next[block];
            if (b.next[block] != none) b.prev[b.next[block]] = b.prev[block];
        }

        /// Smallest order whose block holds `len` bytes at `alignment`, or null if no
        /// block can.
        pub fn orderFor(len: usize, alignment: Alignment) ?u8 {
            if (alignment.toByteUnits() > heap_align.toByteUnits()) return null;
            // A block is aligned to its own size (capped at heap_align), so asking for
            // a block at least as large as the alignment satisfies it.
            const want = @max(len, alignment.toByteUnits(), min_block);
            if (want > heap_size) return null;
            return @intCast(std.math.log2_int_ceil(usize, want) - min_log2);
        }

        /// Returns the minimum-block number of a block of order k, or null if the heap
        /// has no free block that large (even if the total free space would suffice:
        /// that is external fragmentation).
        pub fn allocBlock(b: *Buddy, k: u8) ?u32 {
            var j = k;
            while (j <= max_order and b.heads[j] == none) j += 1;
            if (j > max_order) return null;
            const block = b.heads[j];
            b.unlinkFree(block);
            // Split down to the wanted order. The left half is kept, the right half
            // (the buddy) becomes a free block one order lower.
            while (j > k) {
                j -= 1;
                b.pushFree(block + (@as(u32, 1) << @intCast(j)), j);
            }
            b.state[block] = .used;
            b.order[block] = k;
            return block;
        }

        pub fn freeBlock(b: *Buddy, start: u32) void {
            assert(b.state[start] == .used); // double free or a pointer into a block
            var block = start;
            var k = b.order[block];
            b.state[block] = .inside;
            while (k < max_order) : (k += 1) {
                // The buddy is the other half of the parent block: flip bit k.
                const buddy = block ^ (@as(u32, 1) << @intCast(k));
                // Merge only with a buddy that is free AND whole (same order); a buddy
                // that has been split further is partly in use.
                if (b.state[buddy] != .free or b.order[buddy] != k) break;
                b.unlinkFree(buddy);
                b.state[buddy] = .inside;
                block = @min(block, buddy);
            }
            b.pushFree(block, k);
        }

        pub fn freeBytes(b: *const Buddy) usize {
            var total: usize = 0;
            for (b.heads, 0..) |head, k| {
                var block = head;
                while (block != none) : (block = b.next[block]) total += @as(usize, min_block) << @intCast(k);
            }
            return total;
        }

        /// Size of the largest request that can succeed right now.
        pub fn largestFree(b: *const Buddy) usize {
            var k: usize = max_order + 1;
            while (k > 0) : (k -= 1) {
                if (b.heads[k - 1] != none) return @as(usize, min_block) << @intCast(k - 1);
            }
            return 0;
        }

        /// The heap as a row of blocks in address order: `[128 used][128 free][256 free]`.
        pub fn writeMap(b: *const Buddy, w: *std.Io.Writer) std.Io.Writer.Error!void {
            var block: u32 = 0;
            while (block < leaf_count) {
                const k = b.order[block];
                try w.print("[{d} {s}]", .{ @as(usize, min_block) << @intCast(k), if (b.state[block] == .free) "free" else "used" });
                block += @as(u32, 1) << @intCast(k);
            }
        }

        /// Blocks tile the heap exactly, free lists and states agree, and no two free
        /// buddies of the same order exist (they would have been merged).
        pub fn validate(b: *const Buddy) error{Invalid}!void {
            var block: u32 = 0;
            var free_blocks: usize = 0;
            while (block < leaf_count) {
                const k = b.order[block];
                if (b.state[block] == .inside or k > max_order) return error.Invalid;
                const size = @as(u32, 1) << @intCast(k);
                if (block % size != 0) return error.Invalid;
                for (block + 1..block + size) |i| if (b.state[i] != .inside) return error.Invalid;
                if (b.state[block] == .free) {
                    free_blocks += 1;
                    const buddy = block ^ size;
                    if (k < max_order and b.state[buddy] == .free and b.order[buddy] == k) return error.Invalid;
                }
                block += size;
            }
            if (block != leaf_count) return error.Invalid;
            var listed: usize = 0;
            for (b.heads, 0..) |head, k| {
                var it = head;
                while (it != none) : (it = b.next[it]) {
                    if (b.state[it] != .free or b.order[it] != k) return error.Invalid;
                    listed += 1;
                }
            }
            if (listed != free_blocks) return error.Invalid;
        }

        // ---- std.mem.Allocator ---------------------------------------------------------

        pub fn allocator(b: *Buddy) Allocator {
            return .{ .ptr = b, .vtable = &vtable };
        }

        const vtable: Allocator.VTable = .{ .alloc = vtAlloc, .resize = vtResize, .remap = vtRemap, .free = vtFree };

        fn blockOf(b: *const Buddy, memory: []u8) u32 {
            return @intCast(@divExact(@intFromPtr(memory.ptr) - @intFromPtr(b.base), min_block));
        }

        fn vtAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            _ = ret_addr;
            const b: *Buddy = @ptrCast(@alignCast(ctx));
            const k = orderFor(len, alignment) orelse return null;
            const block = b.allocBlock(k) orelse return null;
            b.requested += len;
            b.granted += @as(usize, min_block) << @intCast(k);
            return b.base + @as(usize, block) * min_block;
        }

        /// In place only: the request must still fit the block it already has. A grow
        /// beyond that could merge with a free right-hand buddy; left as an exercise.
        fn vtResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            _ = .{ alignment, ret_addr };
            const b: *Buddy = @ptrCast(@alignCast(ctx));
            const size = @as(usize, min_block) << @intCast(b.order[b.blockOf(memory)]);
            if (new_len > size) return false;
            b.requested = b.requested - memory.len + new_len;
            return true;
        }

        fn vtRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            return if (vtResize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
        }

        fn vtFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            _ = .{ alignment, ret_addr };
            const b: *Buddy = @ptrCast(@alignCast(ctx));
            const block = b.blockOf(memory);
            b.requested -= memory.len;
            b.granted -= @as(usize, min_block) << @intCast(b.order[block]);
            b.freeBlock(block);
        }
    };
}

// ---------------------------------------------------------------------------------------
const testing = std.testing;
const SplitMix64 = @import("prng.zig").SplitMix64;

const Small = BuddyAllocator(10, 6); // 1024-byte heap, 64-byte minimum block

fn expectHeap(b: *const Small, expected: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try b.writeMap(&w);
    try testing.expectEqualStrings(expected, w.buffered());
    try b.validate();
}

test "split on alloc, merge on free" {
    var heap: [1024]u8 align(1024) = undefined;
    var b: Small = .init(&heap);
    try expectHeap(&b, "[1024 free]");

    const x = b.allocBlock(Small.orderFor(100, .@"1").?).?; // 100 -> 128 bytes
    try testing.expectEqual(0, x);
    try expectHeap(&b, "[128 used][128 free][256 free][512 free]");
    const y = b.allocBlock(Small.orderFor(60, .@"1").?).?; // 64: splits the free 128
    try expectHeap(&b, "[128 used][64 used][64 free][256 free][512 free]");
    const z = b.allocBlock(Small.orderFor(200, .@"1").?).?; // 256: exact fit
    try expectHeap(&b, "[128 used][64 used][64 free][256 used][512 free]");

    b.freeBlock(x); // buddy [64 used][64 free] is split: no merge
    try expectHeap(&b, "[128 free][64 used][64 free][256 used][512 free]");
    b.freeBlock(y); // 64+64 -> 128, 128+128 -> 256, then the 256 buddy is used: stop
    try expectHeap(&b, "[256 free][256 used][512 free]");
    b.freeBlock(z); // cascades to the whole heap
    try expectHeap(&b, "[1024 free]");
}

test "external fragmentation: enough bytes, no block" {
    var heap: [1024]u8 align(1024) = undefined;
    var b: Small = .init(&heap);
    var blocks: [16]u32 = undefined;
    for (&blocks) |*blk| blk.* = b.allocBlock(0).?;
    try testing.expectEqual(null, b.allocBlock(0));
    for (0..8) |i| b.freeBlock(blocks[i * 2]); // free every other 64-byte block
    try testing.expectEqual(512, b.freeBytes());
    try testing.expectEqual(64, b.largestFree()); // no two free blocks are buddies
    try testing.expectEqual(null, b.allocBlock(1));
    try b.validate();
    for (0..8) |i| b.freeBlock(blocks[i * 2 + 1]);
    try testing.expectEqual(1024, b.largestFree());
}

test "as a std.mem.Allocator: containers, alignment, resize" {
    var heap: [4096]u8 align(4096) = undefined;
    const B = BuddyAllocator(12, 4);
    var b: B = .init(&heap);
    const a = b.allocator();

    var list: std.ArrayList(u64) = .empty;
    for (0..100) |i| try list.append(a, i);
    for (list.items, 0..) |v, i| try testing.expectEqual(i, v);

    const page = try a.alignedAlloc(u8, .fromByteUnits(1024), 100);
    try testing.expect(std.mem.isAligned(@intFromPtr(page.ptr), 1024));
    try testing.expect(b.granted - b.requested >= 924); // 100 bytes in a 1024 block
    try testing.expect(a.resize(page, 1000)); // still inside its block
    try testing.expect(!a.resize(page.ptr[0..1000], 1025));
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 8192));
    try testing.expectError(error.OutOfMemory, a.alignedAlloc(u8, .fromByteUnits(8192), 8));

    a.free(page.ptr[0..1000]);
    list.deinit(a);
    try b.validate();
    try testing.expectEqual(4096, b.largestFree()); // fully coalesced
    try testing.expectEqual(0, b.requested + b.granted);
}

test "random alloc/free against a shadow list" {
    var heap: [4096]u8 align(4096) = undefined;
    const B = BuddyAllocator(12, 4);
    var b: B = .init(&heap);
    const a = b.allocator();
    var rng = SplitMix64.init(7);
    var live: [64][]u8 = undefined;
    var n: usize = 0;
    for (0..5000) |step| {
        if (n < live.len and rng.chance(3, 5)) {
            const len: usize = @intCast(rng.range(1, 300));
            const mem = a.alloc(u8, len) catch continue;
            // Stamp the block; an overlap with another live block would corrupt a stamp.
            @memset(mem, @truncate(step));
            live[n] = mem;
            n += 1;
        } else if (n > 0) {
            const i: usize = @intCast(rng.below(n));
            for (live[i]) |byte| try testing.expectEqual(live[i][0], byte);
            a.free(live[i]);
            n -= 1;
            live[i] = live[n];
        }
        if (step % 64 == 0) try b.validate();
    }
    while (n > 0) : (n -= 1) a.free(live[n - 1]);
    try b.validate();
    try testing.expectEqual(4096, b.largestFree());
}

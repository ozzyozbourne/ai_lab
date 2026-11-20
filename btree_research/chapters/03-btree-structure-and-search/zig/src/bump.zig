//! SECTION A: a bump allocator, written by hand.
//!
//! The simplest allocator there is. It owns a chunk of memory and a cursor.
//! To allocate, round the cursor up to the requested alignment, remember that
//! address, move the cursor past the new object. That is all: no size
//! classes, no free list, no per-object header.
//!
//!     chunk:  [header|node|node|node|......unused......]
//!                                   ^ cursor (`used`)
//!
//! The price: a single object cannot be given back. `free` does nothing, and
//! all memory returns to the child allocator at once, in `deinit`.
//!
//! That is the right trade for the trees of this chapter. They are built
//! once and never change, so no node dies before the whole tree does.
//! Chapter 05 deletes nodes one by one and needs a free list instead.
//!
//! `BumpAllocator` implements `std.mem.Allocator` (four function pointers),
//! so every piece of code that takes an `Allocator` can run on it unchanged.
//! `std.heap.ArenaAllocator` is the production version of the same idea.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const BumpAllocator = struct {
    /// Where chunks come from, and where they go back to in `deinit`.
    child: Allocator,
    /// All chunks. Only the first one, the head, is bumped; what is left
    /// over in a chunk behind it stays unused. A new ordinary chunk becomes
    /// the head; a chunk made for one oversized object goes behind the head
    /// (see `alloc`).
    chunks: ?*Chunk = null,
    stats: Stats = .{},

    /// Smallest chunk requested from the child allocator.
    pub const min_chunk_size = 4096;

    pub const Stats = struct {
        /// Successful `alloc` calls.
        allocations: usize = 0,
        /// `free` calls, all of them ignored.
        frees_ignored: usize = 0,
        /// Chunks requested from the child allocator.
        chunks: usize = 0,
    };

    /// Header at the start of every chunk; the objects follow it.
    const Chunk = struct {
        next: ?*Chunk,
        /// Size of the whole chunk in bytes, this header included.
        size: usize,
        /// Offset of the first unused byte, counted from the chunk start.
        used: usize,
    };

    pub fn init(child: Allocator) BumpAllocator {
        return .{ .child = child };
    }

    /// Releases every chunk. Every pointer ever handed out dangles afterwards.
    pub fn deinit(self: *BumpAllocator) void {
        var chunk = self.chunks;
        while (chunk) |c| {
            chunk = c.next; // read first: the header is inside the memory being freed
            const bytes: [*]u8 = @ptrCast(c);
            self.child.rawFree(bytes[0..c.size], .of(Chunk), @returnAddress());
        }
        self.* = undefined;
    }

    pub fn allocator(self: *BumpAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    /// The whole algorithm: align the cursor, check that the object fits,
    /// advance the cursor.
    fn bump(chunk: *Chunk, len: usize, alignment: Alignment) ?[*]u8 {
        const base = @intFromPtr(chunk);
        const start = alignment.forward(base + chunk.used) - base;
        if (start > chunk.size or len > chunk.size - start) return null;
        chunk.used = start + len;
        const bytes: [*]u8 = @ptrCast(chunk);
        return bytes + start;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *BumpAllocator = @ptrCast(@alignCast(ctx));
        if (self.chunks) |chunk| {
            if (bump(chunk, len, alignment)) |ptr| {
                self.stats.allocations += 1;
                return ptr;
            }
        }
        // The head chunk cannot hold the object (or there is no chunk yet):
        // request another one, large enough for the header, alignment
        // padding and the object.
        const overhead = @sizeOf(Chunk) + alignment.toByteUnits();
        const needed = std.math.add(usize, len, overhead) catch return null;
        const size = @max(min_chunk_size, needed);
        const raw = self.child.rawAlloc(size, .of(Chunk), ret_addr) orelse return null;
        const chunk: *Chunk = @ptrCast(@alignCast(raw));
        chunk.* = .{ .next = self.chunks, .size = size, .used = @sizeOf(Chunk) };
        if (needed > min_chunk_size and self.chunks != null) {
            // A chunk sized for this one object is full from birth. As the
            // head it would make the very next small allocation open yet
            // another chunk and abandon the room left in the current head.
            // So it goes BEHIND the head, which keeps being bumped.
            const head = self.chunks.?;
            chunk.next = head.next;
            head.next = chunk;
        } else {
            self.chunks = chunk;
        }
        self.stats.chunks += 1;
        self.stats.allocations += 1;
        return bump(chunk, len, alignment).?;
    }

    /// Shrinking always "works": the tail is simply wasted. Growing in place
    /// works only for the most recent allocation, the one that ends at the
    /// cursor. (This is what lets an `ArrayList` grow cheaply on a bump
    /// allocator while nothing else is allocated in between.)
    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = .{ alignment, ret_addr };
        const self: *BumpAllocator = @ptrCast(@alignCast(ctx));
        if (new_len <= memory.len) return true;
        const chunk = self.chunks orelse return false;
        const cursor = @intFromPtr(chunk) + chunk.used;
        if (@intFromPtr(memory.ptr) + memory.len != cursor) return false;
        const extra = new_len - memory.len;
        if (extra > chunk.size - chunk.used) return false;
        chunk.used += extra;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    /// Nothing is reclaimed. The memory comes back in `deinit`.
    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = .{ memory, alignment, ret_addr };
        const self: *BumpAllocator = @ptrCast(@alignCast(ctx));
        self.stats.frees_ignored += 1;
    }
};

const testing = std.testing;

test "objects are laid out one after the other, each correctly aligned" {
    var bump_state: BumpAllocator = .init(testing.allocator);
    defer bump_state.deinit(); // without this line the test fails: the chunk leaks
    const a = bump_state.allocator();

    const x = try a.create(u64);
    const y = try a.create(u64);
    try testing.expectEqual(@intFromPtr(x) + 8, @intFromPtr(y)); // no header between objects
    const byte = try a.create(u8);
    const z = try a.create(u64); // 7 bytes of padding are skipped
    try testing.expect(@intFromPtr(z) > @intFromPtr(byte));
    try testing.expect(std.mem.isAligned(@intFromPtr(z), @alignOf(u64)));
    const page = try a.alignedAlloc(u8, .fromByteUnits(256), 16);
    try testing.expect(std.mem.isAligned(@intFromPtr(page.ptr), 256));
    try testing.expectEqual(1, bump_state.stats.chunks);
    try testing.expectEqual(5, bump_state.stats.allocations);
}

test "free gives nothing back; deinit gives everything back" {
    var bump_state: BumpAllocator = .init(testing.allocator);
    defer bump_state.deinit();
    const a = bump_state.allocator();
    const x = try a.create(u64);
    x.* = 7;
    a.destroy(x);
    const y = try a.create(u64);
    try testing.expect(x != y); // the freed slot was not reused
    try testing.expectEqual(1, bump_state.stats.frees_ignored);
}

test "a full chunk is followed by a new one; a huge request gets its own chunk" {
    var bump_state: BumpAllocator = .init(testing.allocator);
    defer bump_state.deinit();
    const a = bump_state.allocator();
    for (0..3) |_| _ = try a.alloc(u8, 2000); // 4096 bytes hold two of these
    try testing.expectEqual(2, bump_state.stats.chunks);
    const huge = try a.alloc(u64, 10_000);
    @memset(huge, 0xAB); // all 80000 bytes are really ours
    try testing.expectEqual(3, bump_state.stats.chunks);
}

test "an oversized object does not abandon the room left in the current chunk" {
    // Regression: the oversized chunk became the head, so each small
    // allocation after a big one opened a fresh 4096-byte chunk: 100 chunks
    // for this loop instead of 51.
    var bump_state: BumpAllocator = .init(testing.allocator);
    defer bump_state.deinit();
    const a = bump_state.allocator();
    var previous: ?*u64 = null;
    for (0..50) |i| {
        const big = try a.alloc(u8, 5000);
        @memset(big, 0xCD);
        const small = try a.create(u64);
        small.* = i;
        // The small objects stay neighbours in the one ordinary chunk.
        if (previous) |p| try testing.expectEqual(@intFromPtr(p) + 8, @intFromPtr(small));
        previous = small;
    }
    try testing.expectEqual(51, bump_state.stats.chunks); // 50 oversized + 1 ordinary
    try testing.expectEqual(100, bump_state.stats.allocations);
    try testing.expectEqual(49, previous.?.*); // nothing was overwritten
}

test "the most recent allocation can grow in place, so ArrayList works" {
    var bump_state: BumpAllocator = .init(testing.allocator);
    defer bump_state.deinit();
    const a = bump_state.allocator();
    var buf = try a.alloc(u8, 8);
    try testing.expect(a.resize(buf, 64)); // it ends at the cursor
    buf = buf.ptr[0..64];
    _ = try a.create(u8); // now something else ends at the cursor
    try testing.expect(!a.resize(buf, 128));
    try testing.expect(a.resize(buf, 4)); // shrinking is always fine

    var list: std.ArrayList(u64) = .empty; // no deinit needed: the bump allocator owns the memory
    for (0..1000) |i| try list.append(a, i);
    try testing.expectEqual(999, list.items[999]);
}

test "allocation failure of the child is reported, and the allocator stays usable" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    var bump_state: BumpAllocator = .init(failing.allocator());
    defer bump_state.deinit();
    const a = bump_state.allocator();
    _ = try a.alloc(u8, 3000); // chunk 1
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 3000)); // would need chunk 2
    _ = try a.alloc(u8, 500); // still fits in chunk 1
    try testing.expectEqual(2, bump_state.stats.allocations);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, std.math.maxInt(usize) - 8)); // size overflow
}

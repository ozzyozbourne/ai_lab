//! Section 4: the std.mem.Allocator interface and custom allocators.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;

test "Allocator interface: create/destroy/alloc/free/dupe" {
    const gpa = testing.allocator;

    const one: *u64 = try gpa.create(u64); // single item, contents undefined
    defer gpa.destroy(one);

    const many: []u32 = try gpa.alloc(u32, 8); // slice, contents undefined
    defer gpa.free(many);
    @memset(many, 0);

    const copy: []u8 = try gpa.dupe(u8, "hello"); // (dupeZ is now dupeSentinel)
    defer gpa.free(copy);
    const copy_z: [:0]u8 = try gpa.dupeSentinel(u8, "hello", 0);
    defer gpa.free(copy_z);
    const zs: [:0]u8 = try gpa.allocSentinel(u8, 4, 0);
    defer gpa.free(zs);
    const msg = try gpa.print("{d} keys", .{3}); // Allocator.print == std.fmt.allocPrint
    defer gpa.free(msg);
}

test "Allocator interface: aligned allocation uses std.mem.Alignment (an enum)" {
    const gpa = testing.allocator;
    // Alignment is a log2 enum: .@"1" .. .@"64", or .fromByteUnits(n), or .of(T).
    const page: []align(4096) u8 = try gpa.alignedAlloc(u8, .fromByteUnits(4096), 4096);
    defer gpa.free(page);
    try testing.expect(std.mem.isAligned(@intFromPtr(page.ptr), 4096));

    const cache_aligned: []align(64) u64 = try gpa.alignedAlloc(u64, .@"64", 4);
    defer gpa.free(cache_aligned);

    const natural: []u64 = try gpa.alignedAlloc(u64, null, 4); // null = natural alignment
    defer gpa.free(natural);

    const one: *align(64) u64 = try gpa.alignedCreate(u64, .@"64");
    defer gpa.destroy(one);

    try testing.expectEqual(4096, Alignment.fromByteUnits(4096).toByteUnits());
    try testing.expectEqual(Alignment.@"8", Alignment.of(u64));
}

test "Allocator interface: resize / remap / realloc" {
    const gpa = testing.allocator;
    var buf = try gpa.alloc(u8, 16);
    defer gpa.free(buf);

    // resize: in place only; returns bool. On true you must update the slice length yourself.
    if (gpa.resize(buf, 8)) buf = buf[0..8];

    // remap: may move without a copy (e.g. mremap); returns ?[]T. null = "do alloc+copy+free yourself".
    if (gpa.remap(buf, 64)) |moved| buf = moved;

    // realloc: always works or returns OutOfMemory; may move; preserves contents.
    buf = try gpa.realloc(buf, 1024);
    try testing.expectEqual(1024, buf.len);
}

// ---------------------------------------------------------------------------
// (a) Counting / tracking allocator wrapper.
//
// VTable in 0.17.1 (std.mem.Allocator.VTable) - exactly four function pointers:
//   alloc:  *const fn (*anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8
//   resize: *const fn (*anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool
//   remap:  *const fn (*anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8
//   free:   *const fn (*anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void
// Forward to the child with rawAlloc / rawResize / rawRemap / rawFree.
// ---------------------------------------------------------------------------
pub const CountingAllocator = struct {
    child: Allocator,
    alloc_count: usize = 0,
    free_count: usize = 0,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    total_bytes: usize = 0,

    pub fn init(child: Allocator) CountingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn grew(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        self.live_bytes = self.live_bytes - old_len + new_len;
        if (new_len > old_len) self.total_bytes += new_len - old_len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.alloc_count += 1;
        self.grew(0, len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.grew(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.grew(memory.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.free_count += 1;
        self.live_bytes -= memory.len;
    }
};

test CountingAllocator {
    var counting: CountingAllocator = .init(testing.allocator);
    const a = counting.allocator();

    const xs = try a.alloc(u64, 10);
    const node = try a.create([32]u8);
    try testing.expectEqual(2, counting.alloc_count);
    try testing.expectEqual(80 + 32, counting.live_bytes);

    var list: std.ArrayList(u32) = .empty;
    try list.appendSlice(a, &.{ 1, 2, 3 });
    list.deinit(a);

    a.free(xs);
    a.destroy(node);
    try testing.expectEqual(counting.alloc_count, counting.free_count);
    try testing.expectEqual(0, counting.live_bytes);
    try testing.expect(counting.peak_bytes >= 112);
}

// ---------------------------------------------------------------------------
// (b) Fixed-size slab "page allocator": hands out 4096-byte, 4096-aligned pages
// from one big slab, with an intrusive free list threaded through free pages.
// Offers both a typed API (allocPage/freePage) and a std.mem.Allocator interface.
// ---------------------------------------------------------------------------
pub const PagePool = struct {
    pub const page_size = 4096;
    pub const Page = [page_size]u8;
    pub const PagePtr = *align(page_size) Page;

    backing: Allocator,
    slab: []align(page_size) u8,
    /// Pages never handed out yet start at this index.
    next_fresh: usize = 0,
    /// Intrusive singly linked list of freed pages.
    free_list: ?*FreeNode = null,
    in_use: usize = 0,

    const FreeNode = struct { next: ?*FreeNode };

    pub fn init(backing: Allocator, page_count: usize) Allocator.Error!PagePool {
        const slab = try backing.alignedAlloc(u8, .fromByteUnits(page_size), page_count * page_size);
        return .{ .backing = backing, .slab = slab };
    }

    pub fn deinit(self: *PagePool) void {
        assert(self.in_use == 0); // leak check
        self.backing.free(self.slab);
        self.* = undefined;
    }

    pub fn capacity(self: *const PagePool) usize {
        return self.slab.len / page_size;
    }

    pub fn allocPage(self: *PagePool) Allocator.Error!PagePtr {
        if (self.free_list) |node| {
            self.free_list = node.next;
            self.in_use += 1;
            return @ptrCast(@alignCast(node));
        }
        if (self.next_fresh == self.capacity()) return error.OutOfMemory;
        const off = self.next_fresh * page_size;
        self.next_fresh += 1;
        self.in_use += 1;
        return @alignCast(self.slab[off..][0..page_size]);
    }

    pub fn freePage(self: *PagePool, page: PagePtr) void {
        assert(self.owns(page));
        const node: *FreeNode = @ptrCast(page); // page alignment (4096) >= @alignOf(FreeNode)
        node.* = .{ .next = self.free_list };
        self.free_list = node;
        self.in_use -= 1;
    }

    pub fn owns(self: *const PagePool, ptr: [*]const u8) bool {
        const base = @intFromPtr(self.slab.ptr);
        const addr = @intFromPtr(ptr);
        return addr >= base and addr < base + self.slab.len and (addr - base) % page_size == 0;
    }

    // ---- std.mem.Allocator adapter: only serves requests that fit in one page ----
    pub fn allocator(self: *PagePool) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *PagePool = @ptrCast(@alignCast(ctx));
        if (len > page_size or alignment.toByteUnits() > page_size) return null;
        const page = self.allocPage() catch return null;
        return page;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = .{ ctx, memory, alignment, ret_addr };
        return new_len <= page_size; // every allocation owns a whole page
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = .{ alignment, ret_addr };
        const self: *PagePool = @ptrCast(@alignCast(ctx));
        self.freePage(@ptrCast(@alignCast(memory.ptr)));
    }
};

test "PagePool: typed page API with free list reuse" {
    var pool: PagePool = try .init(testing.allocator, 4);
    defer pool.deinit();

    const p0 = try pool.allocPage();
    const p1 = try pool.allocPage();
    try testing.expect(std.mem.isAligned(@intFromPtr(p0), 4096));
    try testing.expectEqual(@intFromPtr(p0) + 4096, @intFromPtr(p1));
    @memset(p0, 0xAA);

    pool.freePage(p0);
    const p2 = try pool.allocPage(); // LIFO reuse
    try testing.expectEqual(p0, p2);

    const p3 = try pool.allocPage();
    const p4 = try pool.allocPage();
    try testing.expectError(error.OutOfMemory, pool.allocPage());
    try testing.expectEqual(4, pool.in_use);

    for ([_]PagePool.PagePtr{ p1, p2, p3, p4 }) |p| pool.freePage(p);
}

test "PagePool: through the std.mem.Allocator interface" {
    var pool: PagePool = try .init(testing.allocator, 2);
    defer pool.deinit();
    const a = pool.allocator();

    const page = try a.alignedAlloc(u8, .fromByteUnits(4096), 4096);
    const Header = extern struct { kind: u32, count: u32 };
    const hdr = try a.create(Header); // small object still consumes a whole page
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    try testing.expectError(error.OutOfMemory, pool.allocator().alloc(u8, 8192));
    a.free(page);
    a.destroy(hdr);
}

// ---------------------------------------------------------------------------
// Testing OOM paths: checkAllAllocationFailures runs the function once to count
// allocations, then once per allocation index with that allocation failing, and
// checks: the function returns error.OutOfMemory and nothing leaks.
// ---------------------------------------------------------------------------
fn buildSomething(gpa: Allocator, n: usize) !void {
    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    for (0..n) |i| {
        const s = try gpa.alloc(u8, i + 1);
        errdefer gpa.free(s); // without this line the check reports a leak
        try list.append(gpa, s);
    }
}

test "checkAllAllocationFailures" {
    try testing.checkAllAllocationFailures(testing.allocator, buildSomething, .{@as(usize, 4)});
}

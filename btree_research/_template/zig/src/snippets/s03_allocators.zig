//! Section 3: every allocator in std.heap (0.17.1) + std.testing allocators.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Node = struct { keys: [8]u64 = @splat(0), len: u8 = 0 };

// ---- std.testing.allocator: a SafeAllocator; leaks fail the test. ----
test "testing.allocator" {
    const gpa = testing.allocator;
    const node = try gpa.create(Node);
    defer gpa.destroy(node);
    node.* = .{};
    const keys = try gpa.alloc(u64, 16);
    defer gpa.free(keys);
}

// ---- ArenaAllocator: bulk free; individual free is a no-op (except last alloc). ----
test "ArenaAllocator" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator); // or .init(std.heap.page_allocator)
    defer arena.deinit(); // frees everything at once
    const a = arena.allocator();

    for (0..100) |_| _ = try a.create(Node); // no individual destroy needed
    try testing.expect(arena.queryCapacity() >= 100 * @sizeOf(Node));

    // Reuse the arena for the next batch/transaction:
    try testing.expect(arena.reset(.retain_capacity)); // also: .free_all, .{ .retain_with_limit = 1 << 20 }
    _ = try a.alloc(u8, 10);
}

// ---- FixedBufferAllocator: bump allocator over a caller buffer, no syscalls. ----
test "FixedBufferAllocator" {
    var buf: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const a = fba.allocator(); // fba.threadSafeAllocator() for a lock-free variant

    const xs = try a.alloc(u32, 100);
    try testing.expect(fba.ownsSlice(std.mem.sliceAsBytes(xs)));
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 8192));
    a.free(xs); // only actually reclaims if it was the most recent allocation
    fba.reset(); // drop everything
    try testing.expectEqual(0, fba.end_index);
}

// ---- BufferFirstAllocator: replaces std.heap.stackFallback(). ----
// Tries the buffer first, then falls back to another allocator.
test "BufferFirstAllocator (was stackFallback)" {
    var stack_buf: [256]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&stack_buf, testing.allocator);
    const a = bfa.allocator();

    const small = try a.alloc(u8, 100); // from stack_buf
    defer a.free(small);
    const big = try a.alloc(u8, 10_000); // from the fallback
    defer a.free(big);
    try testing.expect(bfa.fixed_buffer_allocator.ownsPtr(small.ptr));
    try testing.expect(!bfa.fixed_buffer_allocator.ownsPtr(big.ptr));
}

// ---- page_allocator: one mmap/munmap per alloc/free. A global `Allocator` value. ----
test "page_allocator" {
    const a = std.heap.page_allocator;
    const page = try a.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), 4096);
    defer a.free(page);
    try testing.expect(std.mem.isAligned(@intFromPtr(page.ptr), std.heap.page_size_min));
    try testing.expect(std.heap.pageSize() >= std.heap.page_size_min); // runtime page size
    // Lower level (no Allocator interface): std.heap.PageAllocator.map / unmap / realloc
    const raw = std.heap.PageAllocator.map(8192, .fromByteUnits(std.heap.page_size_min)) orelse return error.OutOfMemory;
    std.heap.PageAllocator.unmap(@alignCast(raw[0..8192]));
}

// ---- smp_allocator: the fast general-purpose multi-threaded allocator (release builds). ----
// A global `Allocator` value, no init/deinit, no leak checking. Requires !single_threaded.
test "smp_allocator" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const a = std.heap.smp_allocator;
    const node = try a.create(Node);
    defer a.destroy(node);
}

// ---- SafeAllocator: the debug/leak-checking GPA of 0.17 (std.testing.allocator is one). ----
test "SafeAllocator" {
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    // Options (all defaulted): .stack_trace_frames, .check_write_after_free, .canary,
    //                          .bucket_size_log2, .block_size_log2
    const a = safe.allocator();
    const node = try a.create(Node);
    a.destroy(node);
    const leak_count: usize = safe.deinit(); // returns NUMBER OF LEAKS (logs each); deinitLog(false) to stay quiet
    try testing.expectEqual(0, leak_count);
}

test "SafeAllocator detects a leak" {
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    _ = try safe.allocator().create(Node); // leaked on purpose
    try testing.expectEqual(1, safe.deinitLog(false));
}

// ---- DebugAllocator: deprecated in 0.17 (use SafeAllocator) but still present. ----
test "DebugAllocator (deprecated)" {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    const a = dbg.allocator();
    const node = try a.create(Node);
    a.destroy(node);
    try testing.expectEqual(std.heap.Check.ok, dbg.deinit()); // .ok or .leak
}

// ---- MemoryPool: fixed-size object pool with a free list; perfect for nodes. ----
test "MemoryPool" {
    const gpa = testing.allocator;
    var pool: std.heap.MemoryPool(Node) = .empty; // or: try .initCapacity(gpa, 64)
    defer pool.deinit(gpa);

    const n1 = try pool.create(gpa); // contents undefined
    n1.* = .{};
    const n2 = try pool.create(gpa);
    pool.destroy(n1); // pushed on the free list
    const n3 = try pool.create(gpa); // reuses n1's memory
    try testing.expectEqual(@intFromPtr(n1), @intFromPtr(n3));
    _ = n2;

    try pool.addCapacity(gpa, 32); // preheat
    _ = pool.reset(gpa, .retain_capacity); // destroy all items, keep memory
}

test "MemoryPool variants: Aligned and Extra (non-growable)" {
    const gpa = testing.allocator;
    // Items aligned to 4096 bytes (e.g. O_DIRECT page buffers):
    const Page = [4096]u8;
    var pages: std.heap.memory_pool.Aligned(Page, .fromByteUnits(4096)) = .empty;
    defer pages.deinit(gpa);
    const p = try pages.create(gpa);
    try testing.expect(std.mem.isAligned(@intFromPtr(p), 4096));

    // Fixed capacity: create() never calls the allocator after initCapacity.
    const Fixed = std.heap.memory_pool.Extra(Node, .{ .growable = false });
    var fixed: Fixed = try .initCapacity(gpa, 2);
    defer fixed.deinit(gpa);
    _ = try fixed.create(undefined);
    _ = try fixed.create(undefined);
    try testing.expectError(error.OutOfMemory, fixed.create(undefined));
}

// ---- c_allocator: only when linking libc (exe.root_module.link_libc = true / `-lc`). ----
test "c_allocator" {
    if (!builtin.link_libc) return error.SkipZigTest;
    const a = std.heap.c_allocator;
    const xs = try a.alloc(u8, 10);
    defer a.free(xs);
}

// ---- BrkAllocator / brk_allocator: sbrk-style; single-threaded Linux and wasm only. ----
test "brk_allocator" {
    if (!builtin.single_threaded) return error.SkipZigTest; // @compileError otherwise
    const a = std.heap.brk_allocator;
    const xs = try a.alloc(u8, 10);
    defer a.free(xs);
}

// ---- Allocator.failing: always returns OutOfMemory. ----
test "Allocator.failing and testing.failing_allocator" {
    try testing.expectError(error.OutOfMemory, Allocator.failing.alloc(u8, 1));
    try testing.expectError(error.OutOfMemory, testing.failing_allocator.alloc(u8, 1));
}

// ---- std.testing.FailingAllocator: fail the Nth allocation. ----
test "FailingAllocator" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 2 });
    const a = failing.allocator();
    const x = try a.create(u64); // #0 ok
    defer a.destroy(x);
    const y = try a.create(u64); // #1 ok
    defer a.destroy(y);
    try testing.expectError(error.OutOfMemory, a.create(u64)); // #2 fails
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(2, failing.allocations);
    try testing.expectEqual(0, failing.deallocations);
    try testing.expectEqual(16, failing.allocated_bytes);
}

// ---- How a non-test program picks its allocator in 0.17.1 ----
// `pub fn main(init: std.process.Init) !void` gets:
//   init.gpa   - SafeAllocator in Debug/ReleaseSafe; c_allocator or smp_allocator in release
//   init.arena - *ArenaAllocator living for the whole process (page_allocator backed)
// Doing it by hand:
pub fn chooseGpa(safe: *std.heap.SafeAllocator) Allocator {
    return switch (builtin.mode) {
        .debug, .safe => safe.allocator(),
        .fast, .small => std.heap.smp_allocator,
    };
}

test chooseGpa {
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = safe.deinit();
    const gpa = chooseGpa(&safe);
    const p = try gpa.create(u8);
    gpa.destroy(p);
}

//! The allocator tour: one short, tested example for every allocator in Zig 0.17.1
//! `std.heap` and `std.testing`, each with the place a B-tree engine would use it.
//!
//! "Every" was checked against the 0.17.1 sources: the nine files of `lib/std/heap/`
//! (ArenaAllocator, BrkAllocator, BufferFirstAllocator, FixedBufferAllocator,
//! PageAllocator, SafeAllocator, SmpAllocator, debug_allocator, memory_pool), the
//! instances declared in `lib/std/heap.zig` (page_allocator, smp_allocator,
//! brk_allocator, wasm_allocator, c_allocator), `std.testing` (allocator,
//! FailingAllocator, failing_allocator, checkAllAllocationFailures) and the two that
//! live in `std.mem` (Allocator.failing, ValidationAllocator). Not run here:
//! `std.os.uefi.pool_allocator` and `raw_pool_allocator`, which need UEFI firmware.
//!
//! Three examples need a special build, because the allocator does not exist otherwise:
//!   zig build test                   everything except BrkAllocator and c_allocator
//!   zig build test-single-threaded   adds BrkAllocator / wasm_allocator (smp_allocator is skipped)
//!   zig build test-libc              adds c_allocator
//! In the default build those tests report "skipped", they do not fail.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const BTree = @import("btree.zig").BTree;

/// Stand-in for a B-tree node in the examples.
const Node = struct { len: u8 = 0, keys: [7]u64 = @splat(0), next: ?*Node = null };

// 1. std.testing.allocator: a SafeAllocator owned by the test runner. A test that
// leaks FAILS; a double free or a free with the wrong size panics, which ends the run.
// Use it in every unit test: it is what proves that split, merge and deinit return
// every node.
test "testing.allocator: leaks fail the test" {
    const gpa = testing.allocator;
    const node = try gpa.create(Node);
    defer gpa.destroy(node); // delete this line and the test run reports a leak
    node.* = .{};
}

// 2. ArenaAllocator: bump allocation inside chunks taken from a child allocator; `free`
// of one item does nothing (unless it was the latest allocation); everything dies at
// once. Engine use: a bulk-loaded read-only tree, or scratch memory per query.
test "ArenaAllocator: build many, free once, reuse per query" {
    // A FailingAllocator that never fails is a counter for the calls that reach the child.
    var child: testing.FailingAllocator = .init(testing.allocator, .{});
    var arena: std.heap.ArenaAllocator = .init(child.allocator());
    defer arena.deinit(); // one call frees all 100 nodes
    const a = arena.allocator();

    try buildList(a, 100);
    const capacity = arena.queryCapacity();
    try testing.expect(capacity >= 100 * @sizeOf(Node));
    try testing.expect(child.allocations > 1); // the nodes did not fit one chunk
    // Next query: forget the contents, keep the capacity. The first reset merges the
    // chunks into one of the same total capacity, and that is one last trip to the
    // child allocator (ArenaAllocator.zig:149-200) ...
    try testing.expect(arena.reset(.retain_capacity));
    try testing.expect(child.deallocations > 0);
    try testing.expectEqual(capacity, arena.queryCapacity());
    // ... from then on a query of the same size and its reset never call the child.
    const allocations = child.allocations;
    const deallocations = child.deallocations;
    try buildList(a, 100);
    try testing.expect(arena.reset(.retain_capacity));
    try testing.expectEqual(allocations, child.allocations);
    try testing.expectEqual(deallocations, child.deallocations);
}

fn buildList(a: Allocator, count: usize) !void {
    var head: ?*Node = null;
    for (0..count) |_| {
        const node = try a.create(Node);
        node.* = .{ .next = head };
        head = node;
    }
}

// 3. FixedBufferAllocator: bump allocation in a buffer you provide; no syscalls, no
// growth, OutOfMemory when the buffer is full. Engine use: scratch space with a known
// bound, for example the temporary key array while one node splits.
test "FixedBufferAllocator: bounded scratch on the stack" {
    var buffer: [512]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const a = fba.allocator();

    const merged = try a.alloc(u64, 15); // keys of two siblings + separator
    try testing.expect(fba.ownsSlice(std.mem.sliceAsBytes(merged)));
    try testing.expectError(error.OutOfMemory, a.alloc(u64, 100)); // bound enforced
    const first = try a.alloc(u8, 8);
    const second = try a.alloc(u8, 8);
    const used = fba.end_index;
    a.free(first); // not the latest allocation: nothing is reclaimed
    try testing.expectEqual(used, fba.end_index);
    a.free(second); // the latest one is: the bump pointer moves back
    try testing.expectEqual(used - 8, fba.end_index);
    fba.reset(); // forget everything
    try testing.expectEqual(0, fba.end_index);
}

// 3b. FixedBufferAllocator.threadSafeAllocator(): the same buffer behind a lock-free
// interface (the bump pointer is moved with a compare-and-swap). Use one interface or
// the other, never both at once. Engine use: one scratch buffer shared by the worker
// threads of a parallel bulk load.
test "FixedBufferAllocator.threadSafeAllocator: the lock-free face" {
    var buffer: [256]u8 align(8) = undefined; // aligned, so the first u64 needs no padding
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    const a = fba.threadSafeAllocator();

    const keys = try a.alloc(u64, 8);
    try testing.expect(fba.ownsSlice(std.mem.sliceAsBytes(keys)));
    try testing.expectEqual(64, fba.end_index);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 1000)); // same bound
    a.free(keys); // the latest allocation: the bump pointer moves back
    try testing.expectEqual(0, fba.end_index);
}

// 4. BufferFirstAllocator: try a fixed buffer first, fall back to another allocator
// when the request does not fit what is left of it. Engine use: copying a search key;
// almost all keys are short and never touch the heap, a huge one still works.
test "BufferFirstAllocator: short keys on the stack, long keys on the heap" {
    var stack: [64]u8 = undefined;
    var bfa: std.heap.BufferFirstAllocator = .init(&stack, testing.allocator);
    const a = bfa.allocator();

    const short_key = try a.dupe(u8, "user:42");
    defer a.free(short_key);
    const long_key = try a.alloc(u8, 4000);
    defer a.free(long_key); // must be freed: it came from the fallback
    try testing.expect(bfa.fixed_buffer_allocator.ownsPtr(short_key.ptr));
    try testing.expect(!bfa.fixed_buffer_allocator.ownsPtr(long_key.ptr));
}

// 5. page_allocator: every allocation is its own mmap, every free a munmap, and the
// result is page aligned. Engine use: the memory of the buffer pool or of an arena,
// taken once. Never one call per node: that is a syscall per insert.
test "page_allocator: whole pages straight from the OS" {
    const a = std.heap.page_allocator;
    const frames = try a.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), 8 * 4096);
    defer a.free(frames);
    try testing.expect(std.mem.isAligned(@intFromPtr(frames.ptr), std.heap.page_size_min));
    try testing.expect(std.heap.pageSize() >= std.heap.page_size_min);
}

// 5b. PageAllocator: the namespace behind `page_allocator`. `map` and `unmap` are the
// calls without the `Allocator` interface in between. Engine use: map the frames of a
// buffer pool once, at an alignment larger than a page if direct I/O wants it.
test "PageAllocator.map / unmap: the raw calls under page_allocator" {
    const len = 4 * std.heap.page_size_min;
    const big: std.mem.Alignment = .fromByteUnits(16 * std.heap.page_size_min);
    const ptr = std.heap.PageAllocator.map(len, big) orelse return error.OutOfMemory;
    const frames: []align(std.heap.page_size_min) u8 = @alignCast(ptr[0..len]);
    defer std.heap.PageAllocator.unmap(frames);
    try testing.expect(big.check(@intFromPtr(ptr))); // over-aligned on request
    frames[len - 1] = 1; // mapped and writable
    try testing.expectEqual(0, frames[0]); // fresh pages from the OS are zero
}

// 6. smp_allocator (SmpAllocator): the general-purpose allocator for release builds:
// per-thread free lists in power-of-two size classes, large requests mapped directly.
// No leak checking. Engine use: the "gpa" of a release build with pointer-based nodes.
test "smp_allocator: fast general purpose, multi-threaded builds only" {
    if (builtin.single_threaded) return error.SkipZigTest; // does not compile there
    const a = std.heap.smp_allocator;
    const node = try a.create(Node);
    defer a.destroy(node);
    const keys = try a.alloc(u64, 1000);
    defer a.free(keys);
}

// 7. SafeAllocator: the checking general-purpose allocator of 0.17 (`init.gpa` in debug
// and safe builds and `std.testing.allocator` are instances). It adds no reuse of its
// own: a freed small allocation is not handed out again (its bucket goes back to the
// backing allocator as a whole, once it is no longer filled and empty), so, as long as the backing allocator does not reuse
// memory either, most writes after free fault or are detected later
// (SafeAllocator.zig:7-8). Thread-safe if the backing allocator is. `deinit` returns
// the number of leaked allocations.
test "SafeAllocator: counts leaks, does not reuse a freed slot" {
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const a = safe.allocator();
    const kept = try a.create(Node);
    const forgotten = try a.create(Node);
    _ = forgotten; // the bug
    const kept_address = @intFromPtr(kept);
    a.destroy(kept);
    const next = try a.create(Node);
    try testing.expect(@intFromPtr(next) != kept_address); // a pool would return it at once
    a.destroy(next);
    try testing.expectEqual(1, safe.deinitLog(false)); // `deinit()` also logs a stack trace
}

// 8. DebugAllocator: the other checking allocator, marked "Deprecated; use
// `SafeAllocator`" (heap.zig:23) but still present; `deinit` returns .ok or .leak.
test "DebugAllocator: deprecated, SafeAllocator replaces it" {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    const a = debug.allocator();
    const node = try a.create(Node);
    a.destroy(node);
    try testing.expectEqual(std.heap.Check.ok, debug.deinit());
}

// 9. MemoryPool: objects of ONE type, a free list threaded through the freed objects,
// memory from an internal arena. Not a `std.mem.Allocator`: you call create/destroy
// with the type built in. Engine use: THE node allocator of a pointer-based tree.
test "MemoryPool (growable): O(1) create and destroy, LIFO reuse" {
    const gpa = testing.allocator;
    var pool: std.heap.MemoryPool(Node) = .empty;
    defer pool.deinit(gpa); // frees all nodes, destroyed or not

    const a = try pool.create(gpa);
    const b = try pool.create(gpa);
    pool.destroy(a);
    const c = try pool.create(gpa);
    try testing.expectEqual(@intFromPtr(a), @intFromPtr(c)); // the freed slot comes back
    try testing.expect(b != c);
    try pool.addCapacity(gpa, 32); // preheat: the next 32 creates cannot fail
}

// 10. MemoryPool, non-growable: memory is taken up front (`initCapacity`, or a later
// `addCapacity`); `create` never asks for more and fails when the pool is empty.
// Engine use: a fixed set of buffer-pool frames, or the std twin of this chapter's
// static slab.
test "MemoryPool (non-growable): fixed capacity" {
    const gpa = testing.allocator;
    const Frames = std.heap.memory_pool.Extra(Node, .{ .growable = false });
    var frames: Frames = try .initCapacity(gpa, 2);
    defer frames.deinit(gpa);

    // A non-growable pool never uses the allocator argument of `create`.
    const a = try frames.create(Allocator.failing);
    _ = try frames.create(Allocator.failing);
    try testing.expectError(error.OutOfMemory, frames.create(Allocator.failing));
    frames.destroy(a); // "evict" one frame ...
    _ = try frames.create(Allocator.failing); // ... and its memory is available again
}

// 10b. memory_pool.Aligned: the same pool with items aligned more strictly than the
// type asks for. Engine use: nodes on cache-line boundaries (chapter 25), so that two
// neighbouring nodes never share a line.
test "memory_pool.Aligned: over-aligned items" {
    const gpa = testing.allocator;
    const Lines = std.heap.memory_pool.Aligned(Node, .fromByteUnits(64));
    var pool: Lines = .empty;
    defer pool.deinit(gpa);
    try testing.expectEqual(64, Lines.item_alignment.toByteUnits());
    for (0..10) |_| {
        const node = try pool.create(gpa);
        try testing.expect(std.mem.isAligned(@intFromPtr(node), 64));
    }
}

// 11. brk_allocator (BrkAllocator): grows the program break on Linux and the linear
// memory on WebAssembly; size-class free lists, no locking. It only exists in
// single-threaded builds. Engine use: a single-threaded embedded or WebAssembly build
// of the engine. `wasm_allocator` / `WasmAllocator` are the same code under a second
// name: in 0.17.1 `WasmAllocator` is an alias of `BrkAllocator` (heap.zig:18).
test "brk_allocator and wasm_allocator: single-threaded builds only" {
    if (!builtin.single_threaded) return error.SkipZigTest; // @compileError otherwise
    try testing.expect(std.heap.WasmAllocator == std.heap.BrkAllocator);
    try testing.expectEqual(std.heap.brk_allocator.vtable, std.heap.wasm_allocator.vtable);
    const a = std.heap.brk_allocator;
    const node = try a.create(Node);
    defer a.destroy(node);
    const keys = try a.alloc(u64, 1000);
    defer a.free(keys);
    keys[999] = 1;
}

// 12. c_allocator: libc malloc/free behind the Allocator interface. Only when libc is
// linked. Engine use: when the engine is a library inside a C program and must share
// its heap (and its heap tools) with the host.
test "c_allocator: malloc, only when linking libc" {
    if (!builtin.link_libc) return error.SkipZigTest; // @compileError otherwise
    const a = std.heap.c_allocator;
    const node = try a.create(Node);
    defer a.destroy(node);
    const page = try a.alignedAlloc(u8, .fromByteUnits(4096), 4096); // aligned works too
    defer a.free(page);
    try testing.expect(std.mem.isAligned(@intFromPtr(page.ptr), 4096));
}

// 13. std.testing.FailingAllocator: wraps an allocator, lets `fail_index` allocations
// succeed and then fails EVERY later one (the index does not advance on a failure); it
// also counts. Use: aim an OutOfMemory at one exact step of an insert.
test "FailingAllocator: N allocations succeed, then all fail" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 2 });
    const a = failing.allocator();
    const left = try a.create(Node); // allocation 0
    defer a.destroy(left);
    const right = try a.create(Node); // allocation 1
    defer a.destroy(right);
    try testing.expectError(error.OutOfMemory, a.create(Node)); // allocation 2
    try testing.expectError(error.OutOfMemory, a.create(Node)); // and every one after it
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(2, failing.allocations);
    try testing.expectEqual(2 * @sizeOf(Node), failing.allocated_bytes);
}

// 14. Allocator.failing: fails every request and has no state; its resize, remap and
// free are `unreachable`, because nothing it handed out can come back.
// `std.testing.failing_allocator` also fails every request, but it is a FailingAllocator
// with `fail_index = 0` (testing.zig:14-17): it has state and is not thread-safe.
// Use: hand it to code that must not allocate. If the code is wrong the test fails.
test "Allocator.failing: prove a path never allocates" {
    try testing.expectError(error.OutOfMemory, Allocator.failing.create(Node));
    try testing.expectError(error.OutOfMemory, testing.failing_allocator.create(Node));
    var tree: BTree(4, 4) = .init(Allocator.failing, true);
    defer tree.deinit();
    try testing.expectEqual(null, tree.get(7)); // lookups need no memory
    try testing.expect(!tree.delete(7)); // neither does delete
    try testing.expectError(error.OutOfMemory, tree.put(7, 70)); // insert does
    try tree.validate();
}

// 15. std.testing.checkAllAllocationFailures: runs a function once to count its
// allocations, then once per allocation with that one (and any later one) failing, and
// checks each time that it returns OutOfMemory and leaks nothing. In-place resizes are
// refused in every run. Use: every insert path.
fn buildTree(gpa: Allocator, key_count: u64) !void {
    var tree: BTree(4, 4) = .init(gpa, true);
    defer tree.deinit();
    for (0..key_count) |k| try tree.put(k, k);
}

test "checkAllAllocationFailures: every OutOfMemory path, automatically" {
    try testing.checkAllAllocationFailures(testing.allocator, buildTree, .{@as(u64, 30)});
}

// 16. std.mem.ValidationAllocator (`std.mem.validationWrap`): a wrapper that asserts
// the interface contract in both directions: no zero-length request reaches the
// allocator, and every returned pointer has the alignment that was asked for.
// Use: put it around an allocator you wrote yourself, such as this chapter's buddy heap.
test "ValidationAllocator: check a hand-written allocator against the contract" {
    const Heap = @import("buddy.zig").BuddyAllocator(12, 6);
    var memory: [Heap.heap_size]u8 align(Heap.heap_size) = undefined;
    var heap: Heap = .init(&memory);
    var checked = std.mem.validationWrap(heap.allocator());
    const a = checked.allocator();

    const page = try a.alignedAlloc(u8, .fromByteUnits(1024), 1000); // alignment asserted
    const node = try a.create(Node);
    a.destroy(node);
    a.free(page);
    try testing.expectEqual(Heap.heap_size, heap.largestFree());
}

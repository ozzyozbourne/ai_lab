//! Section 5: containers in 0.17.1. Everything is "unmanaged": the container
//! does not store an allocator; you pass `gpa` to every method that may allocate
//! and to deinit.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

test "ArrayList: unmanaged by default" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u32) = .empty; // NOT .init(gpa)
    defer list.deinit(gpa);

    try list.append(gpa, 1);
    try list.appendSlice(gpa, &.{ 2, 3, 4 });
    try list.insert(gpa, 0, 0); // shift right (B-tree leaf insert)
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4 }, list.items);

    try testing.expectEqual(2, list.orderedRemove(2)); // shift left, returns removed
    try testing.expectEqual(0, list.swapRemove(0)); // O(1), moves last into hole
    try testing.expectEqual(3, list.pop().?); // pop() returns ?T
    try testing.expectEqualSlices(u32, &.{ 4, 1 }, list.items);
    try testing.expectEqual(1, list.getLast());

    // Reserve, then use the non-allocating (cannot fail) variants.
    try list.ensureTotalCapacity(gpa, 16);
    try list.ensureUnusedCapacity(gpa, 4);
    list.appendAssumeCapacity(9);
    list.insertAssumeCapacity(0, 7);
    const slot: *u32 = try list.addOne(gpa);
    slot.* = 5;
    const three: []u32 = try list.addManyAsSlice(gpa, 3);
    @memset(three, 0);

    try list.resize(gpa, 2);
    list.shrinkRetainingCapacity(1);
    list.clearRetainingCapacity();
    try testing.expectEqual(0, list.items.len);
    try testing.expect(list.capacity >= 16);
}

test "ArrayList: initCapacity, toOwnedSlice, fromOwnedSlice, clone" {
    const gpa = testing.allocator;
    var list: std.ArrayList(u8) = try .initCapacity(gpa, 8);
    defer list.deinit(gpa);
    try list.print(gpa, "{d}+{d}", .{ 1, 2 }); // ArrayList(u8) only
    try testing.expectEqualStrings("1+2", list.items);

    var copy = try list.clone(gpa);
    const owned: []u8 = try copy.toOwnedSlice(gpa); // list is emptied; caller owns slice
    defer gpa.free(owned);

    var again: std.ArrayList(u8) = .fromOwnedSlice(try gpa.dupe(u8, "xyz"));
    defer again.deinit(gpa);
}

// BoundedArray was removed. Replacement: an ArrayList over a fixed buffer +
// the *Bounded methods (return error.OutOfMemory when the buffer is full).
test "fixed-capacity list (BoundedArray replacement): ArrayList.initBuffer" {
    var storage: [4]u32 = undefined;
    var keys: std.ArrayList(u32) = .initBuffer(&storage);
    // no deinit: the memory is not owned

    try keys.appendBounded(10);
    try keys.appendBounded(30);
    try keys.insertBounded(1, 20);
    keys.appendAssumeCapacity(40);
    try testing.expectError(error.OutOfMemory, keys.appendBounded(50));
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30, 40 }, keys.items);
    try testing.expectEqual(4, keys.capacity);
}

// For B-tree nodes the most common "bounded array" is simply array + len:
fn BoundedKeys(comptime K: type, comptime cap: usize) type {
    return struct {
        buf: [cap]K = undefined,
        len: usize = 0,

        const Self = @This();
        pub fn slice(self: *Self) []K {
            return self.buf[0..self.len];
        }
        pub fn constSlice(self: *const Self) []const K {
            return self.buf[0..self.len];
        }
        pub fn insert(self: *Self, i: usize, k: K) error{Overflow}!void {
            if (self.len == cap) return error.Overflow;
            // overlapping shift right: @memmove (or std.mem.copyBackwards)
            @memmove(self.buf[i + 1 .. self.len + 1], self.buf[i..self.len]);
            self.buf[i] = k;
            self.len += 1;
        }
        pub fn orderedRemove(self: *Self, i: usize) K {
            const k = self.buf[i];
            @memmove(self.buf[i .. self.len - 1], self.buf[i + 1 .. self.len]);
            self.len -= 1;
            return k;
        }
    };
}

test BoundedKeys {
    var ks: BoundedKeys(u32, 4) = .{};
    try ks.insert(0, 30);
    try ks.insert(0, 10);
    try ks.insert(1, 20);
    try testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, ks.constSlice());
    try testing.expectEqual(20, ks.orderedRemove(1));
    try ks.insert(2, 40);
    try ks.insert(3, 50);
    try testing.expectError(error.Overflow, ks.insert(0, 1));
}

test "aligned ArrayList: std.array_list.Aligned" {
    const gpa = testing.allocator;
    var bytes: std.array_list.Aligned(u8, .fromByteUnits(4096)) = .empty;
    defer bytes.deinit(gpa);
    try bytes.appendNTimes(gpa, 0, 4096);
    const page: []align(4096) u8 = bytes.items;
    try testing.expect(std.mem.isAligned(@intFromPtr(page.ptr), 4096));
}

test "managed ArrayList still exists as std.array_list.Managed (avoid in new code)" {
    var list: std.array_list.Managed(u32) = .init(testing.allocator);
    defer list.deinit();
    try list.append(1);
    try testing.expectEqual(1, list.items.len);
}

test "AutoHashMapUnmanaged (preferred)" {
    const gpa = testing.allocator;
    var map: std.AutoHashMapUnmanaged(u64, []const u8) = .empty;
    defer map.deinit(gpa);

    try map.put(gpa, 1, "one");
    try map.putNoClobber(gpa, 2, "two");
    try testing.expectEqualStrings("one", map.get(1).?);
    try testing.expect(map.contains(2));
    try testing.expect(map.get(3) == null);
    if (map.getPtr(1)) |v| v.* = "uno";

    const gop = try map.getOrPut(gpa, 3);
    if (!gop.found_existing) gop.value_ptr.* = "three";
    try testing.expectEqual(3, map.count());

    try testing.expect(map.remove(2));
    const kv = map.fetchRemove(3).?;
    try testing.expectEqualStrings("three", kv.value);

    var it = map.iterator();
    while (it.next()) |entry| {
        try testing.expectEqual(1, entry.key_ptr.*);
        try testing.expectEqualStrings("uno", entry.value_ptr.*);
    }
}

test "AutoHashMap (managed wrapper, stores the allocator)" {
    var map: std.AutoHashMap(u32, u32) = .init(testing.allocator);
    defer map.deinit();
    try map.put(1, 10);
    try testing.expectEqual(10, map.get(1).?);
}

test "StringHashMapUnmanaged and custom context" {
    const gpa = testing.allocator;
    var by_name: std.StringHashMapUnmanaged(u32) = .empty;
    defer by_name.deinit(gpa);
    try by_name.put(gpa, "root", 0); // keys are NOT copied

    // Custom hash/eql: struct with hash(ctx, K) u64 and eql(ctx, K, K) bool.
    const Ctx = struct {
        pub fn hash(_: @This(), k: u32) u64 {
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&k));
        }
        pub fn eql(_: @This(), a: u32, b: u32) bool {
            return a == b;
        }
    };
    var custom: std.HashMapUnmanaged(u32, u32, Ctx, std.hash_map.default_max_load_percentage) = .empty;
    defer custom.deinit(gpa);
    try custom.put(gpa, 5, 50);
    try testing.expectEqual(50, custom.get(5).?);
}

test "array hash map: insertion-ordered, keys()/values() slices" {
    const gpa = testing.allocator;
    var map: std.array_hash_map.Auto(u32, u8) = .empty; // was AutoArrayHashMapUnmanaged
    defer map.deinit(gpa);
    try map.put(gpa, 30, 'c');
    try map.put(gpa, 10, 'a');
    try testing.expectEqualSlices(u32, &.{ 30, 10 }, map.keys());
    try testing.expectEqualSlices(u8, "ca", map.values());
    try testing.expectEqual(1, map.getIndex(10).?);
}

fn lessU32(_: void, a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

test "PriorityQueue: unmanaged, compare fn returns std.math.Order" {
    const gpa = testing.allocator;
    var pq: std.PriorityQueue(u32, void, lessU32) = .empty; // min-heap; .initContext(ctx) for non-void
    defer pq.deinit(gpa);
    try pq.push(gpa, 5);
    try pq.pushSlice(gpa, &.{ 1, 9, 3 });
    try testing.expectEqual(1, pq.peek().?);
    try testing.expectEqual(1, pq.pop().?); // pop() returns ?T
    try testing.expectEqual(3, pq.pop().?);
    try testing.expectEqual(2, pq.count());
}

test "Deque: ring buffer (BFS over tree levels)" {
    const gpa = testing.allocator;
    var q: std.Deque(u32) = .empty;
    defer q.deinit(gpa);
    try q.pushBack(gpa, 1);
    try q.pushBack(gpa, 2);
    try q.pushFront(gpa, 0);
    try testing.expectEqual(0, q.popFront().?);
    try testing.expectEqual(2, q.popBack().?);
    try testing.expectEqual(1, q.len);
}

// DoublyLinkedList / SinglyLinkedList are intrusive and NOT generic:
// embed a `Node` field and recover the parent with @fieldParentPtr.
const Frame = struct {
    page_no: u32,
    lru: std.DoublyLinkedList.Node = .{},
};

test "DoublyLinkedList: intrusive (LRU list for a buffer pool)" {
    var lru: std.DoublyLinkedList = .{};
    var a: Frame = .{ .page_no = 1 };
    var b: Frame = .{ .page_no = 2 };
    var c: Frame = .{ .page_no = 3 };
    lru.append(&a.lru);
    lru.append(&b.lru);
    lru.prepend(&c.lru); // c, a, b

    lru.remove(&a.lru); // touch a: move to the back
    lru.append(&a.lru); // c, b, a

    var seen: [3]u32 = undefined;
    var i: usize = 0;
    var it = lru.first;
    while (it) |node| : (it = node.next) {
        const frame: *Frame = @fieldParentPtr("lru", node);
        seen[i] = frame.page_no;
        i += 1;
    }
    try testing.expectEqualSlices(u32, &.{ 3, 2, 1 }, &seen);

    const victim: *Frame = @fieldParentPtr("lru", lru.popFirst().?);
    try testing.expectEqual(3, victim.page_no);
    try testing.expectEqual(2, lru.len()); // O(n)
}

test "SinglyLinkedList: intrusive free list" {
    const Item = struct { id: u32, node: std.SinglyLinkedList.Node = .{} };
    var free_list: std.SinglyLinkedList = .{};
    var x: Item = .{ .id = 1 };
    var y: Item = .{ .id = 2 };
    free_list.prepend(&x.node);
    free_list.prepend(&y.node);
    const top: *Item = @fieldParentPtr("node", free_list.popFirst().?);
    try testing.expectEqual(2, top.id);
}

test "MultiArrayList: struct-of-arrays" {
    const gpa = testing.allocator;
    const Entry = struct { key: u64, child: u32, dirty: bool };
    var soa: std.MultiArrayList(Entry) = .empty;
    defer soa.deinit(gpa);
    try soa.append(gpa, .{ .key = 10, .child = 1, .dirty = false });
    try soa.append(gpa, .{ .key = 20, .child = 2, .dirty = true });

    const keys: []u64 = soa.items(.key); // contiguous column: cache-friendly key search
    try testing.expectEqualSlices(u64, &.{ 10, 20 }, keys);
    try testing.expectEqual(2, soa.get(1).child);
    soa.set(0, .{ .key = 11, .child = 1, .dirty = true });

    const s = soa.slice(); // cache the column pointers when touching several fields
    try testing.expectEqual(11, s.items(.key)[0]);
    try testing.expectEqual(2, soa.len);
}

// SegmentedList was removed from std. Stable-address growth is easy to write:
// a list of fixed-size chunks; pointers to elements never move.
fn ChunkedList(comptime T: type, comptime chunk_len: usize) type {
    return struct {
        chunks: std.ArrayList(*[chunk_len]T) = .empty,
        len: usize = 0,

        const Self = @This();
        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (self.chunks.items) |c| gpa.destroy(c);
            self.chunks.deinit(gpa);
        }
        pub fn addOne(self: *Self, gpa: Allocator) Allocator.Error!*T {
            if (self.len == self.chunks.items.len * chunk_len) {
                const chunk = try gpa.create([chunk_len]T);
                errdefer gpa.destroy(chunk);
                try self.chunks.append(gpa, chunk);
            }
            defer self.len += 1;
            return self.at(self.len);
        }
        pub fn at(self: *Self, i: usize) *T {
            return &self.chunks.items[i / chunk_len][i % chunk_len];
        }
    };
}

test "ChunkedList (SegmentedList replacement): stable element addresses" {
    const gpa = testing.allocator;
    var list: ChunkedList(u64, 4) = .{};
    defer list.deinit(gpa);
    const first = try list.addOne(gpa);
    first.* = 42;
    for (0..20) |i| (try list.addOne(gpa)).* = i;
    try testing.expectEqual(first, list.at(0)); // did not move
    try testing.expectEqual(42, list.at(0).*);
    try testing.expectEqual(19, list.at(20).*);
}

test "bit sets: free-page bitmap" {
    var bits: std.StaticBitSet(128) = .empty; // also .full (initEmpty()/initFull() are gone)
    bits.set(3);
    bits.set(64);
    try testing.expect(bits.isSet(3));
    try testing.expectEqual(2, bits.count());
    try testing.expectEqual(3, bits.findFirstSet().?);
    bits.unset(3);

    var dyn: std.DynamicBitSetUnmanaged = try .initEmpty(testing.allocator, 1000);
    defer dyn.deinit(testing.allocator);
    dyn.set(999);
    try testing.expectEqual(1, dyn.count());
}

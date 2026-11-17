//! Section 8: randomness, testing, generics, errors, optionals, @branchHint,
//! @Vector, threads, locks, atomics.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

// ---------------------------------------------------------------- Random
test "seeded PRNG for reproducible fuzz tests" {
    var prng: std.Random.DefaultPrng = .init(0xB7EE); // Xoshiro256; fixed seed = reproducible
    const rand: std.Random = prng.random();

    const a = rand.int(u64);
    const b = rand.uintLessThan(u32, 100); // [0, 100)
    const c = rand.intRangeAtMost(i32, -5, 5); // [-5, 5]
    const d = rand.intRangeLessThan(usize, 10, 20); // [10, 20)
    const e = rand.float(f64); // [0, 1)
    const f = rand.boolean();
    _ = .{ a, e, f };
    try testing.expect(b < 100 and c >= -5 and c <= 5 and d >= 10 and d < 20);

    var keys: [16]u32 = undefined;
    for (&keys, 0..) |*k, i| k.* = @intCast(i);
    rand.shuffle(u32, &keys);
    var bytes: [8]u8 = undefined;
    rand.bytes(&bytes);

    // Same seed => same sequence.
    var p1: std.Random.DefaultPrng = .init(42);
    var p2: std.Random.DefaultPrng = .init(42);
    try testing.expectEqual(p1.random().int(u64), p2.random().int(u64));

    // Per-run seed in tests (printed by the test runner on failure; set with `--seed N`):
    var p3: std.Random.DefaultPrng = .init(testing.random_seed);
    _ = p3.random().int(u8);
    // OS entropy (not reproducible): io.random(&buf) fills bytes.
    var seed_bytes: [8]u8 = undefined;
    testing.io.random(&seed_bytes);
}

test "differential fuzz test pattern: structure under test vs a simple model" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(1);
    const rand = prng.random();

    var sorted: std.ArrayList(u32) = .empty; // "tree": sorted array with binary search insert
    defer sorted.deinit(gpa);
    var model: std.AutoHashMapUnmanaged(u32, void) = .empty; // reference model
    defer model.deinit(gpa);

    for (0..2000) |_| {
        const key = rand.uintLessThan(u32, 500);
        const S = struct {
            fn cmp(k: u32, item: u32) std.math.Order {
                return std.math.order(k, item);
            }
        };
        const i = std.sort.lowerBound(u32, sorted.items, key, S.cmp);
        const present = i < sorted.items.len and sorted.items[i] == key;
        try testing.expectEqual(model.contains(key), present);
        if (rand.boolean()) {
            if (!present) try sorted.insert(gpa, i, key);
            try model.put(gpa, key, {});
        } else {
            if (present) _ = sorted.orderedRemove(i);
            _ = model.remove(key);
        }
    }
    try testing.expectEqual(model.count(), sorted.items.len);
    try testing.expect(std.sort.isSorted(u32, sorted.items, {}, std.sort.asc(u32)));
}

// --------------------------------------------------------------- testing
const TreeError = error{ KeyNotFound, DuplicateKey };

fn find(keys: []const u32, key: u32) TreeError!usize {
    return std.mem.findScalar(u32, keys, key) orelse error.KeyNotFound;
}

test "std.testing assertions" {
    // expectEqual(expected, actual): expected FIRST; the comptime literal coerces to actual's type.
    try testing.expectEqual(4, 2 + 2);
    try testing.expectEqual(@as(?u32, null), @as(?u32, null));
    try testing.expect(1 < 2);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, &[_]u32{ 1, 2, 3 });
    try testing.expectEqualStrings("abc", "abc");
    try testing.expectError(error.KeyNotFound, find(&.{ 1, 2 }, 3));
    try testing.expectEqual(1, try find(&.{ 1, 2 }, 2));
    try testing.expectEqualDeep(@as([]const u8, "x"), @as([]const u8, "x")); // follows pointers
    try testing.expectApproxEqAbs(@as(f64, 0.3), 0.1 + 0.2, 1e-9);
    try testing.expectFmt("7:ab", "{d}:{s}", .{ 7, "ab" });
    // structs compare field by field:
    const P = struct { x: u32, y: u32 };
    try testing.expectEqual(P{ .x = 1, .y = 2 }, P{ .x = 1, .y = 2 });
}

test "skipping a test" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
}

// A test named after a declaration is a "doctest": `test find { ... }`.
test find {
    try testing.expectEqual(0, try find(&.{9}, 9));
}

// ------------------------------------------------- comptime generic B-tree shape
pub fn BTree(comptime K: type, comptime V: type, comptime order: usize) type {
    comptime assert(order >= 3);
    return struct {
        const Self = @This();
        pub const max_keys = order - 1;
        pub const min_keys = (order - 1) / 2;

        pub const Node = struct {
            len: usize = 0,
            keys: [max_keys]K = undefined,
            values: [max_keys]V = undefined,
            children: [order]?*Node = @splat(null),

            fn isLeaf(n: *const Node) bool {
                return n.children[0] == null;
            }
        };

        gpa: Allocator,
        root: ?*Node = null,
        count: usize = 0,

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            if (self.root) |r| self.freeNode(r);
            self.* = undefined;
        }

        fn freeNode(self: *Self, node: *Node) void {
            for (node.children[0 .. node.len + 1]) |maybe_child| {
                if (maybe_child) |child| self.freeNode(child);
            }
            self.gpa.destroy(node);
        }

        /// Toy insert: only fills the root leaf; real chapters add splitting.
        pub fn put(self: *Self, key: K, value: V) (Allocator.Error || error{NodeFull})!void {
            const node = self.root orelse blk: {
                const n = try self.gpa.create(Node);
                n.* = .{};
                self.root = n;
                break :blk n;
            };
            var i: usize = 0;
            while (i < node.len and node.keys[i] < key) i += 1;
            if (i < node.len and node.keys[i] == key) {
                node.values[i] = value;
                return;
            }
            if (node.len == max_keys) return error.NodeFull;
            @memmove(node.keys[i + 1 .. node.len + 1], node.keys[i..node.len]);
            @memmove(node.values[i + 1 .. node.len + 1], node.values[i..node.len]);
            node.keys[i] = key;
            node.values[i] = value;
            node.len += 1;
            self.count += 1;
        }

        pub fn get(self: *const Self, key: K) ?V {
            var node = self.root orelse return null;
            while (true) {
                var i: usize = 0;
                while (i < node.len and node.keys[i] < key) i += 1;
                if (i < node.len and node.keys[i] == key) return node.values[i];
                node = node.children[i] orelse return null;
            }
        }
    };
}

test BTree {
    const Tree = BTree(u32, []const u8, 4);
    try testing.expectEqual(3, Tree.max_keys);
    var tree: Tree = .init(testing.allocator);
    defer tree.deinit();
    try tree.put(20, "twenty");
    try tree.put(10, "ten");
    try tree.put(30, "thirty");
    try testing.expectEqualStrings("ten", tree.get(10).?);
    try testing.expect(tree.get(15) == null);
    try testing.expectError(error.NodeFull, tree.put(40, "forty"));
    try testing.expect(tree.root.?.isLeaf());
}

// Generic over a comparison: pass a comptime function or a context type.
pub fn SortedSet(comptime K: type, comptime compare: fn (K, K) std.math.Order) type {
    return struct {
        items: std.ArrayList(K) = .empty,
        const Self = @This();
        pub fn insert(self: *Self, gpa: Allocator, key: K) !bool {
            var lo: usize = 0;
            var hi: usize = self.items.items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                switch (compare(key, self.items.items[mid])) {
                    .eq => return false,
                    .lt => hi = mid,
                    .gt => lo = mid + 1,
                }
            }
            try self.items.insert(gpa, lo, key);
            return true;
        }
    };
}

fn orderBytes(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

test SortedSet {
    const gpa = testing.allocator;
    var set: SortedSet([]const u8, orderBytes) = .{};
    defer set.items.deinit(gpa);
    try testing.expect(try set.insert(gpa, "b"));
    try testing.expect(try set.insert(gpa, "a"));
    try testing.expect(!try set.insert(gpa, "b"));
    try testing.expectEqualStrings("a", set.items.items[0]);
}

test "comptime reflection: @typeInfo field names are lowercase, @FieldType, @hasDecl" {
    const Hdr = extern struct { magic: u32, count: u16, pad: u16 = 0 };
    const info = @typeInfo(Hdr).@"struct";
    try testing.expectEqual(3, info.field_names.len);
    try testing.expectEqualStrings("magic", info.field_names[0]);
    try testing.expectEqual(u16, @FieldType(Hdr, "count"));
    try testing.expectEqual(32, @typeInfo(u32).int.bits);
    try testing.expect(@typeInfo([]const u8).pointer.size == .slice);
    try testing.expect(@hasField(Hdr, "pad") and !@hasDecl(Hdr, "init"));
    inline for (comptime std.meta.fieldNames(Hdr)) |name| {
        try testing.expect(name.len > 0);
    }
    // Type construction: @Type is gone; use @Int / @Struct / @Enum / @Union / @Pointer / @Tuple / @Fn.
    const U24 = @Int(.unsigned, 24);
    try testing.expectEqual(u24, U24);
}

// ------------------------------------------------------------ error sets
const PagerError = error{ ShortRead, Corrupt };
const AllErrors = PagerError || TreeError || Allocator.Error; // merge with ||

fn mayFail(n: u32) AllErrors!u32 {
    return switch (n) {
        0 => error.Corrupt,
        1 => error.KeyNotFound,
        2 => error.OutOfMemory,
        else => n,
    };
}

test "error sets, try/catch, errdefer, switch on error" {
    try testing.expectEqual(7, try mayFail(7));
    try testing.expectEqual(99, mayFail(0) catch 99);
    const r = mayFail(1) catch |err| switch (err) {
        error.KeyNotFound => @as(u32, 1000),
        error.Corrupt, error.ShortRead => 2000,
        else => |e| return e, // e has the narrowed error set
    };
    try testing.expectEqual(1000, r);

    if (mayFail(2)) |v| {
        _ = v;
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expectEqualStrings("OutOfMemory", @errorName(err));
    }

    // errdefer: undo partial work when the function returns an error.
    const gpa = testing.allocator;
    const S = struct {
        fn two(a: Allocator, fail: bool) !struct { *u32, *u32 } {
            const x = try a.create(u32);
            errdefer a.destroy(x);
            const y = try a.create(u32);
            errdefer a.destroy(y);
            if (fail) return error.Corrupt;
            return .{ x, y };
        }
    };
    try testing.expectError(error.Corrupt, S.two(gpa, true)); // no leak
    const x, const y = try S.two(gpa, false); // destructuring
    gpa.destroy(x);
    gpa.destroy(y);
}

// ------------------------------------------------- optionals and pointers
test "optionals, optional pointers, sentinel pointers, many-item pointers" {
    const Node = struct { next: ?*@This() = null, key: u32 };
    var b: Node = .{ .key = 2 };
    var a: Node = .{ .key = 1, .next = &b };

    // ?*T is pointer-sized (null = address 0).
    try testing.expectEqual(@sizeOf(*Node), @sizeOf(?*Node));
    try testing.expectEqual(2, a.next.?.key); // .? asserts non-null
    const key = if (b.next) |n| n.key else 0; // unwrap with capture
    try testing.expectEqual(0, key);
    var it: ?*Node = &a;
    var sum: u32 = 0;
    while (it) |n| : (it = n.next) sum += n.key; // walk a linked chain (leaf siblings)
    try testing.expectEqual(3, sum);
    const tail = b.next orelse &b; // default
    try testing.expectEqual(2, tail.key);

    // Index-based "pointers" with a sentinel value instead of optionals (on-disk page numbers):
    const PageNo = enum(u32) {
        none = std.math.maxInt(u32),
        _, // non-exhaustive: any other u32 is a valid page number
        fn unwrap(p: @This()) ?u32 {
            return if (p == .none) null else @intFromEnum(p);
        }
    };
    const p: PageNo = @enumFromInt(7);
    try testing.expectEqual(7, p.unwrap().?);
    try testing.expectEqual(null, PageNo.none.unwrap());

    // Sentinel-terminated: [:0]const u8 (slice), [*:0]const u8 (C string), [N:0]u8 (array).
    const lit: [:0]const u8 = "abc"; // string literals are *const [N:0]u8
    try testing.expectEqual(0, lit[lit.len]); // reading the sentinel is allowed
    const c_str: [*:0]const u8 = lit.ptr;
    try testing.expectEqual(3, std.mem.len(c_str));
    try testing.expectEqualStrings("abc", std.mem.span(c_str));

    // Pointer kinds: *T (one), [*]T (many, no length), []T (slice = ptr + len), *[N]T (array ptr).
    var arr = [_]u32{ 1, 2, 3, 4 };
    const many: [*]u32 = &arr;
    const slice: []u32 = many[1..3];
    const arr_ptr: *[2]u32 = slice[0..2];
    try testing.expectEqual(3, arr_ptr[1]);
    try testing.expectEqual(@intFromPtr(&arr[1]), @intFromPtr(slice.ptr));
}

// ------------------------------------------------------------ @branchHint
fn searchHinted(keys: []const u64, key: u64) ?usize {
    for (keys, 0..) |k, i| {
        if (k == key) {
            @branchHint(.unlikely); // must be the FIRST statement of the branch/function body
            return i;
        }
    }
    return null;
}

fn corrupt() noreturn {
    @branchHint(.cold); // .none, .likely, .unlikely, .cold, .unpredictable
    @panic("corrupt page");
}

test "@branchHint" {
    try testing.expectEqual(2, searchHinted(&.{ 1, 2, 3 }, 3).?);
    if (searchHinted(&.{1}, 1) == null) corrupt();
}

// ---------------------------------------------------------------- @Vector
/// Count of keys strictly less than `key` in an 8-key node = child index.
fn simdRank8(keys: *const [8]u32, key: u32) u8 {
    const V = @Vector(8, u32);
    const kv: V = keys.*; // arrays coerce to vectors and back
    const needle: V = @splat(key);
    const lt: @Vector(8, bool) = kv < needle; // element-wise compare
    const mask: u8 = @bitCast(lt); // one bit per lane
    return @popCount(mask);
}

test "@Vector basics" {
    const keys = [8]u32{ 10, 20, 30, 40, 50, 60, 70, 80 };
    try testing.expectEqual(3, simdRank8(&keys, 35));
    try testing.expectEqual(0, simdRank8(&keys, 5));
    try testing.expectEqual(8, simdRank8(&keys, 99));

    const a: @Vector(4, i32) = .{ 1, 2, 3, 4 };
    const b: @Vector(4, i32) = @splat(10);
    const sum = a + b; // + - * / % & | ^ << >> are element-wise
    try testing.expectEqual([4]i32{ 11, 12, 13, 14 }, @as([4]i32, sum));
    try testing.expectEqual(10, @reduce(.Add, a)); // .Add .Mul .Min .Max .And .Or .Xor
    try testing.expectEqual(4, @reduce(.Max, a));
    try testing.expect(@reduce(.Or, a == @as(@Vector(4, i32), @splat(3))));
    const picked = @select(i32, a > @as(@Vector(4, i32), @splat(2)), a, b); // per-lane choose
    try testing.expectEqual([4]i32{ 10, 10, 3, 4 }, @as([4]i32, picked));
    try testing.expectEqual(3, a[2]); // index like an array
    // First matching lane:
    const eq: @Vector(4, bool) = a == @as(@Vector(4, i32), @splat(3));
    try testing.expectEqual(2, std.simd.firstTrue(eq).?);
    try testing.expectEqual(2, @ctz(@as(u4, @bitCast(eq))));
    // Load from a slice at a runtime offset: slice to a comptime-known length first.
    const lane_count = comptime std.simd.suggestVectorLength(u32) orelse 4;
    try testing.expect(lane_count >= 4);
    const chunk: @Vector(4, u32) = keys[2..][0..4].*;
    try testing.expectEqual(30, chunk[0]);
}

// ------------------------------------------------- threads, locks, atomics
// 0.17.1: std.Thread only spawns/joins OS threads. Mutex / Condition / RwLock /
// Semaphore / Event live in std.Io and every blocking call takes `io`.
const Counter = struct {
    mutex: Io.Mutex = .init,
    value: u64 = 0,
    hits: std.atomic.Value(u64) = .init(0),

    fn work(self: *Counter, io: Io, n: usize) void {
        for (0..n) |_| {
            self.mutex.lockUncancelable(io); // `try mutex.lock(io)` can return error.Canceled
            defer self.mutex.unlock(io);
            self.value += 1;
            _ = self.hits.fetchAdd(1, .monotonic);
        }
    }
};

test "std.Thread.spawn + Io.Mutex + atomics" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var counter: Counter = .{};

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Counter.work, .{ &counter, io, 1000 });
    for (threads) |t| t.join();

    try testing.expectEqual(4000, counter.value);
    try testing.expectEqual(4000, counter.hits.load(.monotonic));
    try testing.expect((try std.Thread.getCpuCount()) >= 1);
}

test "Io.RwLock: many readers or one writer (latch per node / per tree)" {
    const io = testing.io;
    var latch: Io.RwLock = .init;
    var shared: u32 = 0;

    {
        latch.lockSharedUncancelable(io); // or: try latch.lockShared(io)
        defer latch.unlockShared(io);
        try testing.expect(latch.tryLockShared(io)); // a second reader is fine
        latch.unlockShared(io);
        try testing.expect(!latch.tryLock(io)); // writer excluded while readers hold it
        try testing.expectEqual(0, shared);
    }
    {
        latch.lockUncancelable(io); // or: try latch.lock(io)
        defer latch.unlock(io);
        shared = 1;
    }
    try testing.expectEqual(1, shared);
}

test "Io.Mutex.tryLock, Io.Condition, Io.Event" {
    const io = testing.io;
    var m: Io.Mutex = .init;
    try testing.expect(m.tryLock()); // tryLock takes no io
    try testing.expect(!m.tryLock());
    m.unlock(io);

    var cond: Io.Condition = .init;
    cond.signal(io); // wake one waiter; cond.broadcast(io) wakes all
    // waiting side:  mutex.lockUncancelable(io); while (!ready) cond.waitUncancelable(io, &mutex);

    var ev: Io.Event = .unset;
    ev.set(io);
    try testing.expect(ev.isSet());
    ev.waitUncancelable(io); // returns immediately once set
}

fn sumRange(lo: u64, hi: u64) u64 {
    var s: u64 = 0;
    for (lo..hi) |i| s += i;
    return s;
}

test "Io.async / Io.Group: task parallelism without managing threads" {
    const io = testing.io;
    var fut = io.async(sumRange, .{ 0, 1000 }); // may run inline or on a pool thread
    const direct = sumRange(1000, 2000);
    try testing.expectEqual(1999000, fut.await(io) + direct);

    const S = struct {
        fn bump(counter: *std.atomic.Value(u32)) void {
            _ = counter.fetchAdd(1, .monotonic);
        }
    };
    var counter: std.atomic.Value(u32) = .init(0);
    var group: Io.Group = .init;
    for (0..8) |_| group.async(io, S.bump, .{&counter});
    try group.await(io);
    try testing.expectEqual(8, counter.load(.monotonic));
}

test "atomics: std.atomic.Value and builtins" {
    var v: std.atomic.Value(u32) = .init(5);
    try testing.expectEqual(5, v.fetchAdd(1, .seq_cst)); // returns the OLD value
    try testing.expectEqual(6, v.load(.acquire));
    v.store(10, .release);
    try testing.expectEqual(10, v.swap(11, .acq_rel));
    // cmpxchg returns null on success, the current value on failure.
    try testing.expectEqual(null, v.cmpxchgStrong(11, 12, .acq_rel, .acquire));
    try testing.expectEqual(12, v.cmpxchgStrong(99, 0, .acq_rel, .acquire).?);
    try testing.expectEqual(12, v.raw); // non-atomic access to the field

    // Optimistic version latch: readers retry if the version changed or is odd (locked).
    var version: std.atomic.Value(u64) = .init(0);
    const before = version.load(.acquire);
    _ = version.fetchAdd(2, .release);
    try testing.expect(version.load(.acquire) != before);

    // Builtin forms on plain variables. Orders: .unordered .monotonic .acquire .release .acq_rel .seq_cst
    var raw: usize = 0;
    _ = @atomicRmw(usize, &raw, .Add, 1, .monotonic);
    @atomicStore(usize, &raw, 2, .release);
    try testing.expectEqual(2, @atomicLoad(usize, &raw, .acquire));
    try testing.expectEqual(null, @cmpxchgStrong(usize, &raw, 2, 3, .seq_cst, .seq_cst));

    // Avoid false sharing between per-thread counters:
    const Padded = struct { n: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0) };
    try testing.expect(@alignOf(Padded) >= 64);
    std.atomic.spinLoopHint();
}

test "timing a section (std.Io clock)" {
    const io = testing.io;
    const start = Io.Clock.awake.now(io);
    std.mem.doNotOptimizeAway(sumRange(0, 1000));
    const elapsed: Io.Duration = start.untilNow(io, .awake);
    try testing.expect(elapsed.toNanoseconds() >= 0);
}

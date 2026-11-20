//! Adaptive radix tree (ART): insert, search, ordered iteration. No delete.
//!
//! Shape of the tree (the same choices DuckDB makes, see the chapter README):
//!
//!   * An INNER node consumes exactly one key byte and maps it to a child. It
//!     comes in four layouts, Node4 / Node16 / Node48 / Node256, picked by the
//!     number of children. A full node is copied into the next larger layout.
//!   * A PREFIX node holds 1..7 key bytes that every key below it shares, and
//!     one child. This is path compression: a run of one-child levels costs
//!     one node instead of one node per byte.
//!   * A LEAF is not a node at all: the value is stored inside the reference
//!     that would otherwise point to a node. The key is not stored anywhere in
//!     one piece; it is spelled out by the path from the root.
//!
//! Requirement on keys: non-empty, and no key is a strict prefix of another
//! (see keys.zig). Otherwise a value would have to live in the middle of a
//! path, and this tree has no place for it. `put` reports `error.PrefixKey`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const keys = @import("keys.zig");

pub const Entry = keys.Entry;
pub const Lookup = keys.Lookup;

/// Bytes per prefix node. DuckDB derives this from the key type and gets 7
/// for a single 8-byte integer key (art.cpp:1258-1287).
pub const prefix_cap = 7;

/// Longest key `put` accepts, in bytes. The limit exists because of how this
/// teaching version walks the tree: `insertAt`, `census`, `validate` and
/// `dump` recurse once per node, and a path has at most one node per key
/// byte. So the key length bounds the recursion depth, and with it the stack
/// those walks need (512 levels fit comfortably in the default stacks of
/// both languages, see the test "the longest keys"). Without a limit a key
/// of some tens of thousands of bytes overflows the stack. `lookup` and the
/// iterator are loops and would not need the limit.
pub const max_key_len = 512;

/// A reference to a subtree. Leaves are inlined: `.leaf` carries the value.
pub const Ref = union(enum) {
    none,
    leaf: u64,
    prefix: *Prefix,
    n4: *Node4,
    n16: *Node16,
    n48: *Node48,
    n256: *Node256,
};

pub const Prefix = struct {
    len: u8,
    bytes: [prefix_cap]u8,
    child: Ref,

    fn slice(self: *const Prefix) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Node4 and Node16 are the same layout with a different capacity: the key
/// bytes are kept SORTED in `keys[0..count]` and `children[i]` belongs to
/// `keys[i]`. Sorted order is what makes in-order iteration a left-to-right
/// walk. Finding a byte is a plain linear scan (DuckDB does the same, with no
/// SIMD: base_node.hpp:72-82).
fn SmallNode(comptime cap: u8) type {
    return struct {
        const Self = @This();
        count: u8 = 0,
        keys: [cap]u8 = undefined,
        children: [cap]Ref = undefined,

        fn find(self: *const Self, byte: u8) ?usize {
            for (self.keys[0..self.count], 0..) |k, i| {
                if (k == byte) return i;
            }
            return null;
        }

        /// Insert keeping `keys` sorted. Caller guarantees room and absence.
        fn add(self: *Self, byte: u8, child: Ref) void {
            std.debug.assert(self.count < cap);
            var i: usize = self.count;
            while (i > 0 and self.keys[i - 1] > byte) : (i -= 1) {
                self.keys[i] = self.keys[i - 1];
                self.children[i] = self.children[i - 1];
            }
            self.keys[i] = byte;
            self.children[i] = child;
            self.count += 1;
        }
    };
}

pub const Node4 = SmallNode(4);
pub const Node16 = SmallNode(16);

/// Node48: a 256-entry byte table that maps a key byte to a position in a
/// 48-entry child array. Two array reads, no scan. `empty48` marks "no child".
pub const Node48 = struct {
    pub const empty48: u8 = 48;
    count: u8 = 0,
    index: [256]u8 = @splat(empty48),
    children: [48]Ref = undefined,
};

/// Node256: the child array is indexed by the key byte directly.
pub const Node256 = struct {
    count: u16 = 0,
    children: [256]Ref = @splat(.none),
};

/// The five allocation size classes. Leaves are inlined and need none.
pub const Kind = enum(u8) { prefix, node4, node16, node48, node256 };
pub const kind_count = 5;
pub const kind_names = [kind_count][]const u8{ "prefix", "node4", "node16", "node48", "node256" };
/// Child slots of each inner layout (a prefix node has one fixed child).
pub const kind_slots = [kind_count]usize{ 1, 4, 16, 48, 256 };

/// One `std.heap.MemoryPool` per node type: every pool hands out blocks of
/// exactly one size and keeps a free list of returned blocks. A grown node
/// goes back to its pool and is reused by the next node of that size.
const Pools = struct {
    prefix: std.heap.MemoryPool(Prefix) = .empty,
    n4: std.heap.MemoryPool(Node4) = .empty,
    n16: std.heap.MemoryPool(Node16) = .empty,
    n48: std.heap.MemoryPool(Node48) = .empty,
    n256: std.heap.MemoryPool(Node256) = .empty,
    /// Nodes currently in use, per size class.
    live: [kind_count]usize = @splat(0),
    /// Nodes ever handed out, per size class (reuse included).
    created: [kind_count]usize = @splat(0),

    fn kindOf(comptime T: type) Kind {
        return switch (T) {
            Prefix => .prefix,
            Node4 => .node4,
            Node16 => .node16,
            Node48 => .node48,
            Node256 => .node256,
            else => @compileError("not an ART node type"),
        };
    }

    fn poolFor(self: *Pools, comptime T: type) *std.heap.MemoryPool(T) {
        return switch (T) {
            Prefix => &self.prefix,
            Node4 => &self.n4,
            Node16 => &self.n16,
            Node48 => &self.n48,
            Node256 => &self.n256,
            else => @compileError("not an ART node type"),
        };
    }

    fn create(self: *Pools, gpa: Allocator, comptime T: type) Allocator.Error!*T {
        const node = try self.poolFor(T).create(gpa);
        const k = @backingInt(kindOf(T));
        self.live[k] += 1;
        self.created[k] += 1;
        return node;
    }

    fn destroy(self: *Pools, comptime T: type, node: *T) void {
        self.poolFor(T).destroy(node);
        self.live[@backingInt(kindOf(T))] -= 1;
    }

    fn deinit(self: *Pools, gpa: Allocator) void {
        self.prefix.deinit(gpa);
        self.n4.deinit(gpa);
        self.n16.deinit(gpa);
        self.n48.deinit(gpa);
        self.n256.deinit(gpa);
    }
};

// ---- Operations that work on any of the four inner layouts ----------------

fn childOf(ref: Ref, byte: u8) ?Ref {
    switch (ref) {
        .n4 => |n| return if (n.find(byte)) |i| n.children[i] else null,
        .n16 => |n| return if (n.find(byte)) |i| n.children[i] else null,
        .n48 => |n| {
            const slot = n.index[byte];
            return if (slot == Node48.empty48) null else n.children[slot];
        },
        .n256 => |n| return if (n.children[byte] == .none) null else n.children[byte],
        else => unreachable,
    }
}

/// Overwrite the child that already exists at `byte`.
fn setChild(ref: Ref, byte: u8, child: Ref) void {
    switch (ref) {
        .n4 => |n| n.children[n.find(byte).?] = child,
        .n16 => |n| n.children[n.find(byte).?] = child,
        .n48 => |n| n.children[n.index[byte]] = child,
        .n256 => |n| n.children[byte] = child,
        else => unreachable,
    }
}

fn isFull(ref: Ref) bool {
    return switch (ref) {
        .n4 => |n| n.count == 4,
        .n16 => |n| n.count == 16,
        .n48 => |n| n.count == 48,
        .n256 => false, // one slot per possible byte: can never overflow
        else => unreachable,
    };
}

/// Add a child at a byte that has none. Caller guarantees room.
fn addChild(ref: Ref, byte: u8, child: Ref) void {
    switch (ref) {
        .n4 => |n| n.add(byte, child),
        .n16 => |n| n.add(byte, child),
        .n48 => |n| {
            // Without delete there are no holes: the next free slot is `count`.
            n.children[n.count] = child;
            n.index[byte] = n.count;
            n.count += 1;
        },
        .n256 => |n| {
            n.children[byte] = child;
            n.count += 1;
        },
        else => unreachable,
    }
}

const ByteChild = struct { byte: u8, child: Ref };

/// First child whose byte is >= `from` (0..256). This one function is all the
/// iterator needs to walk any layout in key order.
fn nextChild(ref: Ref, from: u16) ?ByteChild {
    switch (ref) {
        inline .n4, .n16 => |n| {
            for (n.keys[0..n.count], 0..) |k, i| {
                if (k >= from) return .{ .byte = k, .child = n.children[i] };
            }
            return null;
        },
        .n48 => |n| {
            var b: u16 = from;
            while (b < 256) : (b += 1) {
                const slot = n.index[b];
                if (slot != Node48.empty48) return .{ .byte = @intCast(b), .child = n.children[slot] };
            }
            return null;
        },
        .n256 => |n| {
            var b: u16 = from;
            while (b < 256) : (b += 1) {
                if (n.children[b] != .none) return .{ .byte = @intCast(b), .child = n.children[b] };
            }
            return null;
        },
        else => unreachable,
    }
}

fn childCount(ref: Ref) usize {
    return switch (ref) {
        .n4 => |n| n.count,
        .n16 => |n| n.count,
        .n48 => |n| n.count,
        .n256 => |n| n.count,
        else => unreachable,
    };
}

fn kindOfRef(ref: Ref) Kind {
    return switch (ref) {
        .prefix => .prefix,
        .n4 => .node4,
        .n16 => .node16,
        .n48 => .node48,
        .n256 => .node256,
        else => unreachable,
    };
}

/// What the tree is made of, found by walking it.
pub const Census = struct {
    /// Reachable nodes per size class.
    nodes: [kind_count]usize = @splat(0),
    leaves: usize = 0,
    /// Child slots in use / reserved, over the four inner layouts.
    slots_used: usize = 0,
    slots_allocated: usize = 0,
    /// Most nodes (prefix + inner) on any root-to-leaf path.
    max_path: usize = 0,
};

pub const ValidateError = error{
    BadPrefix,
    UnsortedBytes,
    BadCount,
    BadIndex,
    LeafCountMismatch,
    PoolMismatch,
};

pub const PutError = error{ OutOfMemory, EmptyKey, KeyTooLong, PrefixKey };

pub const Art = struct {
    gpa: Allocator,
    root: Ref = .none,
    len: usize = 0,
    pools: Pools = .{},
    /// grows[0] = Node4 to Node16, [1] = Node16 to Node48, [2] = Node48 to Node256.
    grows: [3]usize = @splat(0),
    /// Number of prefix nodes that had to be split by an insert.
    prefix_splits: usize = 0,

    /// `gpa` backs the five pools and must stay valid until `deinit`.
    pub fn init(gpa: Allocator) Art {
        return .{ .gpa = gpa };
    }

    /// Frees every node at once. There is no tree walk: each pool releases its
    /// blocks wholesale.
    pub fn deinit(self: *Art) void {
        self.pools.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn get(self: *const Art, key: []const u8) ?u64 {
        return self.lookup(key).value;
    }

    /// Point lookup. `steps` counts nodes visited (prefix and inner nodes).
    /// Note what is absent: no comparison against a stored key, no binary
    /// search. The cost is bounded by the key length, not by `len`.
    pub fn lookup(self: *const Art, key: []const u8) Lookup {
        var ref = self.root;
        var depth: usize = 0;
        var steps: u32 = 0;
        while (true) {
            switch (ref) {
                .none => return .{ .value = null, .steps = steps },
                // The whole path matched; it is our key only if it used all bytes.
                .leaf => |v| return .{ .value = if (depth == key.len) v else null, .steps = steps },
                .prefix => |p| {
                    steps += 1;
                    if (!std.mem.startsWith(u8, key[depth..], p.slice())) return .{ .value = null, .steps = steps };
                    depth += p.len;
                    ref = p.child;
                },
                .n4, .n16, .n48, .n256 => {
                    steps += 1;
                    if (depth == key.len) return .{ .value = null, .steps = steps };
                    ref = childOf(ref, key[depth]) orelse return .{ .value = null, .steps = steps };
                    depth += 1;
                },
            }
        }
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    /// On any error the tree is exactly as it was before the call.
    pub fn put(self: *Art, key: []const u8, value: u64) PutError!?u64 {
        if (key.len == 0) return error.EmptyKey;
        // Bounds the recursion depth of insertAt and of the inspection walks.
        if (key.len > max_key_len) return error.KeyTooLong;
        var old: ?u64 = null;
        self.root = try self.insertAt(self.root, key, 0, value, &old);
        if (old == null) self.len += 1;
        return old;
    }

    /// Insert below `ref`, whose path has consumed `key[0..depth]`. Returns the
    /// reference the parent must now store: usually `ref` itself, but a node
    /// that grew or a prefix that was split has a new identity. This is how a
    /// structural change stays local: the parent only swaps one reference
    /// (compare DuckDB passing `NodePtr &node_ptr`, base_node.cpp:61-76).
    /// One recursion level per node on the path, at most `max_key_len` levels.
    fn insertAt(self: *Art, ref: Ref, key: []const u8, depth: usize, value: u64, old: *?u64) PutError!Ref {
        switch (ref) {
            // Only the empty root: the whole key becomes one prefix chain.
            .none => return self.newChain(key[depth..], value),
            .leaf => |v| {
                // A leaf ends a stored key. If our key continues, the stored
                // key is a strict prefix of ours.
                if (depth != key.len) return error.PrefixKey;
                old.* = v;
                return .{ .leaf = value };
            },
            .prefix => |p| {
                for (p.slice(), 0..) |stored, i| {
                    // Our key ends inside the path: it is a prefix of stored keys.
                    if (depth + i == key.len) return error.PrefixKey;
                    if (stored != key[depth + i]) return self.splitPrefix(p, i, key, depth + i, value);
                }
                p.child = try self.insertAt(p.child, key, depth + p.len, value, old);
                return ref;
            },
            .n4, .n16, .n48, .n256 => {
                if (depth == key.len) return error.PrefixKey;
                const byte = key[depth];
                if (childOf(ref, byte)) |child| {
                    setChild(ref, byte, try self.insertAt(child, key, depth + 1, value, old));
                    return ref;
                }
                // New branch. Allocate everything first, mutate last, so that
                // an allocation failure leaves the tree untouched.
                const chain = try self.newChain(key[depth + 1 ..], value);
                errdefer self.freeChain(chain);
                const node = if (isFull(ref)) try self.grow(ref) else ref;
                addChild(node, byte, chain);
                return node;
            },
        }
    }

    /// Build `prefix -> prefix -> ... -> leaf` for the rest of a key. Built
    /// back to front so that every node is complete when it is linked.
    fn newChain(self: *Art, rest: []const u8, value: u64) Allocator.Error!Ref {
        var child: Ref = .{ .leaf = value };
        errdefer self.freeChain(child);
        var end = rest.len;
        while (end > 0) {
            const start = ((end - 1) / prefix_cap) * prefix_cap;
            const p = try self.pools.create(self.gpa, Prefix);
            p.* = .{ .len = @intCast(end - start), .bytes = undefined, .child = child };
            @memcpy(p.bytes[0..p.len], rest[start..end]);
            child = .{ .prefix = p };
            end = start;
        }
        return child;
    }

    fn freeChain(self: *Art, chain: Ref) void {
        var ref = chain;
        while (ref == .prefix) {
            const p = ref.prefix;
            ref = p.child;
            self.pools.destroy(Prefix, p);
        }
    }

    /// The new key leaves prefix `p` at position `i` (key byte `key[at]`).
    ///
    ///   before:  p[b0 .. bi .. bn] -> C
    ///   after:   p[b0 .. b(i-1)] -> Node4 { bi   -> rest[b(i+1) .. bn] -> C
    ///                                       key[at] -> new chain -> leaf }
    ///
    /// Either prefix piece may be empty and is then left out.
    fn splitPrefix(self: *Art, p: *Prefix, i: usize, key: []const u8, at: usize, value: u64) Allocator.Error!Ref {
        const chain = try self.newChain(key[at + 1 ..], value);
        errdefer self.freeChain(chain);
        const branch = try self.pools.create(self.gpa, Node4);
        errdefer self.pools.destroy(Node4, branch);
        branch.* = .{};

        const old_byte = p.bytes[i];
        const rest_len = p.len - i - 1;
        var old_side = p.child;
        if (rest_len > 0 and i > 0) {
            // Both pieces are non-empty: the tail needs a node of its own.
            // This is the last allocation; nothing has been modified yet.
            const tail = try self.pools.create(self.gpa, Prefix);
            tail.* = .{ .len = @intCast(rest_len), .bytes = undefined, .child = p.child };
            @memcpy(tail.bytes[0..rest_len], p.bytes[i + 1 .. p.len]);
            old_side = .{ .prefix = tail };
        }

        // From here on nothing can fail.
        self.prefix_splits += 1;
        var result: Ref = .{ .n4 = branch };
        if (i > 0) {
            p.len = @intCast(i); // p keeps the shared head
            p.child = result;
            result = .{ .prefix = p };
        } else if (rest_len > 0) {
            // No shared head: reuse p itself as the tail.
            std.mem.copyForwards(u8, p.bytes[0..rest_len], p.bytes[1 .. 1 + rest_len]);
            p.len = @intCast(rest_len);
            old_side = .{ .prefix = p };
        } else {
            self.pools.destroy(Prefix, p); // a 1-byte prefix dissolved into the branch
        }
        branch.add(old_byte, old_side);
        branch.add(key[at], chain);
        return result;
    }

    /// Copy a full node into the next larger layout and free the old one.
    fn grow(self: *Art, ref: Ref) Allocator.Error!Ref {
        switch (ref) {
            .n4 => |old| {
                const new = try self.pools.create(self.gpa, Node16);
                new.* = .{ .count = old.count };
                @memcpy(new.keys[0..old.count], old.keys[0..old.count]);
                @memcpy(new.children[0..old.count], old.children[0..old.count]);
                self.pools.destroy(Node4, old);
                self.grows[0] += 1;
                return .{ .n16 = new };
            },
            .n16 => |old| {
                const new = try self.pools.create(self.gpa, Node48);
                new.* = .{ .count = old.count };
                for (old.keys[0..old.count], 0..) |k, i| {
                    new.index[k] = @intCast(i);
                    new.children[i] = old.children[i];
                }
                self.pools.destroy(Node16, old);
                self.grows[1] += 1;
                return .{ .n48 = new };
            },
            .n48 => |old| {
                const new = try self.pools.create(self.gpa, Node256);
                new.* = .{ .count = old.count };
                for (old.index, 0..) |slot, byte| {
                    if (slot != Node48.empty48) new.children[byte] = old.children[slot];
                }
                self.pools.destroy(Node48, old);
                self.grows[2] += 1;
                return .{ .n256 = new };
            },
            else => unreachable,
        }
    }

    // ---- Inspection ---------------------------------------------------

    pub fn census(self: *const Art) Census {
        var c: Census = .{};
        censusAt(self.root, 0, &c);
        return c;
    }

    fn censusAt(ref: Ref, path: usize, c: *Census) void {
        switch (ref) {
            .none => {},
            .leaf => {
                c.leaves += 1;
                c.max_path = @max(c.max_path, path);
            },
            .prefix => |p| {
                c.nodes[@backingInt(Kind.prefix)] += 1;
                censusAt(p.child, path + 1, c);
            },
            .n4, .n16, .n48, .n256 => {
                const k = @backingInt(kindOfRef(ref));
                c.nodes[k] += 1;
                c.slots_used += childCount(ref);
                c.slots_allocated += kind_slots[k];
                var from: u16 = 0;
                while (nextChild(ref, from)) |bc| : (from = @as(u16, bc.byte) + 1) {
                    censusAt(bc.child, path + 1, c);
                }
            },
        }
    }

    /// Check every structural invariant. Tests call this after each change.
    pub fn validate(self: *const Art) ValidateError!void {
        try validateAt(self.root);
        const c = self.census();
        // Every stored key ends in exactly one leaf.
        if (c.leaves != self.len) return error.LeafCountMismatch;
        // Every node handed out by a pool is reachable: nothing leaked inside
        // the tree, nothing freed twice.
        for (c.nodes, self.pools.live) |reachable, live| {
            if (reachable != live) return error.PoolMismatch;
        }
    }

    fn validateAt(ref: Ref) ValidateError!void {
        switch (ref) {
            .none, .leaf => {},
            .prefix => |p| {
                if (p.len == 0 or p.len > prefix_cap or p.child == .none) return error.BadPrefix;
                try validateAt(p.child);
            },
            inline .n4, .n16 => |n, tag| {
                // Sorted, distinct bytes: iteration order and `find` rely on it.
                for (1..n.count) |i| {
                    if (n.keys[i - 1] >= n.keys[i]) return error.UnsortedBytes;
                }
                // An inner node branches (>= 2 children), and without delete a
                // Node16 only exists because a Node4 overflowed.
                const min: usize = if (tag == .n4) 2 else 5;
                if (n.count < min or n.count > n.keys.len) return error.BadCount;
                for (n.children[0..n.count]) |child| {
                    if (child == .none) return error.BadCount;
                    try validateAt(child);
                }
            },
            .n48 => |n| {
                if (n.count < 17 or n.count > 48) return error.BadCount;
                // `index` must be a one-to-one map onto children[0..count].
                var seen: [48]bool = @splat(false);
                var used: usize = 0;
                for (n.index) |slot| {
                    if (slot == Node48.empty48) continue;
                    if (slot >= n.count or seen[slot]) return error.BadIndex;
                    seen[slot] = true;
                    used += 1;
                    try validateAt(n.children[slot]);
                }
                if (used != n.count) return error.BadIndex;
            },
            .n256 => |n| {
                var used: usize = 0;
                for (n.children) |child| {
                    if (child == .none) continue;
                    used += 1;
                    try validateAt(child);
                }
                if (used != n.count or used < 49) return error.BadCount;
            },
        }
    }

    /// Print the tree, one line per branch:
    ///   prefix "rom" -> node4 [2]
    ///     'a' -> prefix "n" -> ...
    pub fn dump(self: *const Art, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.root == .none) return w.writeAll("(empty)\n");
        try dumpAt(self.root, w, 0);
    }

    fn dumpAt(ref: Ref, w: *std.Io.Writer, indent: usize) std.Io.Writer.Error!void {
        switch (ref) {
            .none => unreachable,
            .leaf => |v| try w.print("leaf {d}\n", .{v}),
            .prefix => |p| {
                try w.writeAll("prefix \"");
                try keys.writeBytes(w, p.slice());
                try w.writeAll("\" -> ");
                try dumpAt(p.child, w, indent);
            },
            .n4, .n16, .n48, .n256 => {
                try w.print("{s} [{d}]\n", .{ kind_names[@backingInt(kindOfRef(ref))], childCount(ref) });
                var from: u16 = 0;
                while (nextChild(ref, from)) |bc| : (from = @as(u16, bc.byte) + 1) {
                    try w.splatByteAll(' ', indent + 2);
                    try w.writeAll("'");
                    try keys.writeBytes(w, &.{bc.byte});
                    try w.writeAll("' -> ");
                    try dumpAt(bc.child, w, indent + 2);
                }
            },
        }
    }

    pub fn iterator(self: *const Art, gpa: Allocator) Iterator {
        return .{ .gpa = gpa, .tree = self, .pending = self.root };
    }
};

/// Ordered iteration. An ART has no leaf chain to follow, so the iterator
/// keeps the path from the root as an explicit stack, and rebuilds the current
/// key from the bytes along that path (DuckDB: iterator.cpp:312-348).
///
/// The tree must not change while an iterator is in use.
///
/// `next` and `seek` grow the stack and the key buffer and can therefore
/// return `error.OutOfMemory`. After that error the position is unspecified
/// (the path was only partly recorded): call `seek` again before the next
/// `next`. `seek` starts from scratch, so the iterator itself stays usable.
pub const Iterator = struct {
    gpa: Allocator,
    tree: *const Art,
    /// One frame per inner node on the current path.
    stack: std.ArrayList(Frame) = .empty,
    /// The key bytes consumed along the current path.
    key: std.ArrayList(u8) = .empty,
    /// A subtree that still has to be entered (set by init and by `seek`).
    pending: Ref,

    const Frame = struct {
        node: Ref,
        /// Next byte value to try in `node`, 0..256.
        next: u16,
        /// Length of `key` when standing at `node`.
        key_len: usize,
    };

    pub fn deinit(self: *Iterator) void {
        self.stack.deinit(self.gpa);
        self.key.deinit(self.gpa);
        self.* = undefined;
    }

    /// Next entry in ascending key order. `entry.key` is valid until the next
    /// call on this iterator.
    pub fn next(self: *Iterator) Allocator.Error!?Entry {
        if (self.pending != .none) {
            const ref = self.pending;
            self.pending = .none;
            if (try self.descend(ref)) |e| return e;
        }
        while (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            self.key.shrinkRetainingCapacity(top.key_len);
            if (nextChild(top.node, top.next)) |bc| {
                top.next = @as(u16, bc.byte) + 1;
                try self.key.append(self.gpa, bc.byte);
                if (try self.descend(bc.child)) |e| return e;
            } else {
                _ = self.stack.pop(); // node exhausted: back to its parent
            }
        }
        return null;
    }

    /// Walk down from `start` through prefix nodes. A leaf is the next entry.
    /// An inner node is pushed so that `next` continues with its first child.
    fn descend(self: *Iterator, start: Ref) Allocator.Error!?Entry {
        var ref = start;
        while (true) {
            switch (ref) {
                .none => return null,
                .leaf => |v| return .{ .key = self.key.items, .value = v },
                .prefix => |p| {
                    try self.key.appendSlice(self.gpa, p.slice());
                    ref = p.child;
                },
                .n4, .n16, .n48, .n256 => {
                    try self.stack.append(self.gpa, .{ .node = ref, .next = 0, .key_len = self.key.items.len });
                    return null;
                },
            }
        }
    }

    /// Position the iterator so that `next` returns the first key >= `lo`
    /// (lower bound). `lo` is any byte string; it need not be a stored key.
    pub fn seek(self: *Iterator, lo: []const u8) Allocator.Error!void {
        self.stack.clearRetainingCapacity();
        self.key.clearRetainingCapacity();
        self.pending = .none;
        var ref = self.tree.root;
        var depth: usize = 0;
        while (true) {
            switch (ref) {
                .none => return,
                .leaf => {
                    // Path == lo[0..depth]. Equal if lo ends here; otherwise the
                    // stored key is a strict prefix of lo, hence smaller: skip.
                    if (depth == lo.len) self.pending = ref;
                    return;
                },
                .prefix => |p| {
                    const rest = lo[depth..];
                    const stored = p.slice();
                    const n = @min(rest.len, stored.len);
                    switch (std.mem.order(u8, stored[0..n], rest[0..n])) {
                        // Every key below is smaller than lo: nothing here.
                        .lt => return,
                        // Every key below is greater than lo: take it all.
                        .gt => {
                            self.pending = ref;
                            return;
                        },
                        .eq => {},
                    }
                    if (rest.len < stored.len) {
                        // lo ended inside the prefix: all keys below extend lo.
                        self.pending = ref;
                        return;
                    }
                    try self.key.appendSlice(self.gpa, stored);
                    depth += stored.len;
                    ref = p.child;
                },
                .n4, .n16, .n48, .n256 => {
                    if (depth == lo.len) {
                        self.pending = ref;
                        return;
                    }
                    const byte = lo[depth];
                    // Children with a greater byte are all > lo: `next` will
                    // visit them after whatever we find below `byte`.
                    try self.stack.append(self.gpa, .{ .node = ref, .next = @as(u16, byte) + 1, .key_len = self.key.items.len });
                    const child = childOf(ref, byte) orelse return;
                    try self.key.append(self.gpa, byte);
                    depth += 1;
                    ref = child;
                },
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ops = @import("ops.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;

fn expectDump(tree: *const Art, expected: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try tree.dump(&aw.writer);
    try testing.expectEqualStrings(expected, aw.written());
}

test "empty tree" {
    var tree: Art = .init(testing.allocator);
    defer tree.deinit();
    try testing.expectEqual(null, tree.get("a"));
    try tree.validate();
    try expectDump(&tree, "(empty)\n");
    var it = tree.iterator(testing.allocator);
    defer it.deinit();
    try testing.expectEqual(null, try it.next());
}

test "first key is one prefix chain; long keys chain prefix nodes" {
    var tree: Art = .init(testing.allocator);
    defer tree.deinit();
    try testing.expectEqual(null, try tree.put("abcdefghij", 1));
    try expectDump(&tree, "prefix \"abcdefg\" -> prefix \"hij\" -> leaf 1\n");
    try testing.expectEqual(1, tree.get("abcdefghij"));
    try testing.expectEqual(null, tree.get("abcdefghi"));
    try testing.expectEqual(null, tree.get("abcdefghijk"));
    try testing.expectEqual(1, try tree.put("abcdefghij", 2)); // overwrite
    try testing.expectEqual(1, tree.len);
    try tree.validate();
}

test "prefix split: head kept, tail kept, both, neither" {
    var tree: Art = .init(testing.allocator);
    defer tree.deinit();
    _ = try tree.put("abcd", 1);
    _ = try tree.put("abxy", 2); // split in the middle: head "ab", tails "d" and "y"
    try expectDump(&tree,
        \\prefix "ab" -> node4 [2]
        \\  'c' -> prefix "d" -> leaf 1
        \\  'x' -> prefix "y" -> leaf 2
        \\
    );
    _ = try tree.put("zz", 3); // split at byte 0, tail "b" reuses the node
    try expectDump(&tree,
        \\node4 [2]
        \\  'a' -> prefix "b" -> node4 [2]
        \\    'c' -> prefix "d" -> leaf 1
        \\    'x' -> prefix "y" -> leaf 2
        \\  'z' -> prefix "z" -> leaf 3
        \\
    );
    _ = try tree.put("ac", 4); // 1-byte prefix "b" dissolves into a branch
    try expectDump(&tree,
        \\node4 [2]
        \\  'a' -> node4 [2]
        \\    'b' -> node4 [2]
        \\      'c' -> prefix "d" -> leaf 1
        \\      'x' -> prefix "y" -> leaf 2
        \\    'c' -> leaf 4
        \\  'z' -> prefix "z" -> leaf 3
        \\
    );
    try testing.expectEqual(3, tree.prefix_splits);
    try tree.validate();
    for ([_][]const u8{ "abcd", "abxy", "zz", "ac" }, 1..) |k, v| try testing.expectEqual(v, tree.get(k));
}

test "keys that are prefixes of each other are rejected without side effects" {
    var tree: Art = .init(testing.allocator);
    defer tree.deinit();
    try testing.expectError(error.EmptyKey, tree.put("", 1));
    _ = try tree.put("abc", 1);
    _ = try tree.put("abd", 2);
    try testing.expectError(error.PrefixKey, tree.put("ab", 3)); // ends at an inner node
    try testing.expectError(error.PrefixKey, tree.put("a", 3)); // ends inside a prefix
    try testing.expectError(error.PrefixKey, tree.put("abcd", 3)); // continues past a leaf
    try testing.expectEqual(2, tree.len);
    try tree.validate();
}

test "one node grows through all four layouts" {
    var tree: Art = .init(testing.allocator);
    defer tree.deinit();
    const expected = [_]struct { at: usize, kind: Kind }{
        .{ .at = 2, .kind = .node4 },    .{ .at = 4, .kind = .node4 },
        .{ .at = 5, .kind = .node16 },   .{ .at = 16, .kind = .node16 },
        .{ .at = 17, .kind = .node48 },  .{ .at = 48, .kind = .node48 },
        .{ .at = 49, .kind = .node256 }, .{ .at = 256, .kind = .node256 },
    };
    var next_check: usize = 0;
    // Descending byte order exercises the sorted insert of Node4 / Node16.
    for (0..256) |i| {
        const key = [2]u8{ 'k', @intCast(255 - i) };
        _ = try tree.put(&key, i);
        try tree.validate();
        if (next_check < expected.len and expected[next_check].at == i + 1) {
            try testing.expectEqual(expected[next_check].kind, kindOfRef(tree.root.prefix.child));
            next_check += 1;
        }
    }
    try testing.expectEqual(expected.len, next_check);
    try testing.expectEqualSlices(usize, &.{ 1, 1, 1 }, &tree.grows);
    // The three outgrown nodes went back to their pools.
    try testing.expectEqualSlices(usize, &.{ 1, 0, 0, 0, 1 }, &tree.pools.live);
    try testing.expectEqualSlices(usize, &.{ 1, 1, 1, 1, 1 }, &tree.pools.created);
    for (0..256) |i| {
        const key = [2]u8{ 'k', @intCast(255 - i) };
        try testing.expectEqual(i, tree.get(&key));
    }
}

test "a freed node is reused by its pool" {
    var tree: Art = .init(testing.allocator);
    defer tree.deinit();
    for (0..4) |i| _ = try tree.put(&.{ 'a', @intCast(i) }, i);
    // The address of the Node4 that the fifth key is about to outgrow.
    const freed_address = @intFromPtr(tree.root.prefix.child.n4);
    _ = try tree.put(&.{ 'a', 4 }, 4); // Node4 -> Node16, Node4 freed
    try testing.expectEqual(0, tree.pools.live[@backingInt(Kind.node4)]);
    const freed_created = tree.pools.created[@backingInt(Kind.node4)];
    _ = try tree.put(&.{ 'b', 0 }, 9); // needs a Node4 for the new branch at byte 0
    try testing.expectEqual(freed_created + 1, tree.pools.created[@backingInt(Kind.node4)]);
    try testing.expectEqual(1, tree.pools.live[@backingInt(Kind.node4)]);
    // The counters above would also move if the pool never reused anything.
    // The address shows it: the new Node4 is the very block that was freed.
    try testing.expectEqual(freed_address, @intFromPtr(tree.root.n4));
    try tree.validate();
}

test "the longest keys: recursion depth is bounded by max_key_len" {
    const gpa = testing.allocator;
    var tree: Art = .init(gpa);
    defer tree.deinit();
    var buf: [max_key_len + 1]u8 = @splat('a');

    // One byte too long: refused before anything is touched.
    try testing.expectError(error.KeyTooLong, tree.put(&buf, 1));
    try testing.expectEqual(0, tree.len);
    try tree.validate();
    try expectDump(&tree, "(empty)\n");

    // The deepest tree the limit allows: keys "b", "ab", "aab", ... up to
    // max_key_len bytes. Every byte position branches, so the path to the
    // longest key has one Node4 per byte and every recursive walk goes
    // max_key_len levels deep.
    for (0..max_key_len) |i| {
        buf[i] = 'b';
        try testing.expectEqual(null, try tree.put(buf[0 .. i + 1], i));
        buf[i] = 'a';
    }
    // And the longest unbranched key: a chain of 73 prefix nodes.
    @memset(buf[0..max_key_len], 'c');
    try testing.expectEqual(null, try tree.put(buf[0..max_key_len], 7));
    try testing.expectEqual(7, try tree.put(buf[0..max_key_len], 8)); // overwrite walks the chain

    try tree.validate();
    const c = tree.census();
    try testing.expectEqual(max_key_len - 1, c.nodes[@backingInt(Kind.node4)]);
    try testing.expectEqual(max_key_len, c.max_path);
    try testing.expectEqual(max_key_len + 1, c.leaves);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try tree.dump(&aw.writer);
    try testing.expect(std.mem.endsWith(u8, aw.written(), "\" -> leaf 8\n"));

    @memset(buf[0..max_key_len], 'a');
    buf[max_key_len - 1] = 'b';
    try testing.expectEqual(max_key_len - 1, tree.get(buf[0..max_key_len]));
    var it = tree.iterator(gpa);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    try testing.expectEqual(max_key_len + 1, n);
}

test "iterator returns keys in byte order and seek is a lower bound" {
    const gpa = testing.allocator;
    var tree: Art = .init(gpa);
    defer tree.deinit();
    const words = [_][]const u8{ "romulus!", "romane!", "rubens!", "romanus!", "ruber!", "rubicon!", "rubicundus!" };
    for (words, 0..) |word, i| _ = try tree.put(word, i);
    var it = tree.iterator(gpa);
    defer it.deinit();

    const sorted = [_][]const u8{ "romane!", "romanus!", "romulus!", "rubens!", "ruber!", "rubicon!", "rubicundus!" };
    for (sorted) |want| try testing.expectEqualStrings(want, (try it.next()).?.key);
    try testing.expectEqual(null, try it.next());

    const cases = [_]struct { lo: []const u8, first: ?[]const u8 }{
        .{ .lo = "", .first = "romane!" },
        .{ .lo = "romane!", .first = "romane!" }, // exact hit
        .{ .lo = "romane", .first = "romane!" }, // lo is a prefix of a key
        .{ .lo = "romane!!", .first = "romanus!" }, // a key is a prefix of lo
        .{ .lo = "romb", .first = "romulus!" }, // no child at that byte
        .{ .lo = "roz", .first = "rubens!" }, // greater than a whole prefix
        .{ .lo = "ra", .first = "romane!" }, // smaller than a whole prefix
        .{ .lo = "rubf", .first = "rubicon!" },
        .{ .lo = "rubicundus!", .first = "rubicundus!" },
        .{ .lo = "rubz", .first = null },
        .{ .lo = "s", .first = null },
    };
    for (cases) |c| {
        try it.seek(c.lo);
        const got = try it.next();
        if (c.first) |want| {
            try testing.expectEqualStrings(want, got.?.key);
        } else {
            try testing.expectEqual(null, got);
        }
    }
}

test "iterator: after OutOfMemory a new seek gives the right answer" {
    const gpa = testing.allocator;
    var tree: Art = .init(gpa);
    defer tree.deinit();
    const words = [_][]const u8{ "romulus!", "romane!", "rubens!", "romanus!", "ruber!", "rubicon!", "rubicundus!" };
    for (words, 0..) |word, i| _ = try tree.put(word, i);

    var fail_index: usize = 0;
    var failures: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        var it = tree.iterator(failing.allocator());
        defer it.deinit();
        // Seek, then read to the end; every allocation from `fail_index` on fails.
        var failed = false;
        if (it.seek("rubf")) |_| {
            while (it.next() catch blk: {
                failed = true;
                break :blk null;
            }) |_| {}
        } else |_| failed = true;
        if (!failed) break; // ran past the last allocation
        failures += 1;
        // With memory available again the same iterator works from a new seek.
        it.gpa = gpa;
        try it.seek("rubf");
        try testing.expectEqualStrings("rubicon!", (try it.next()).?.key);
        try testing.expectEqualStrings("rubicundus!", (try it.next()).?.key);
        try testing.expectEqual(null, try it.next());
    }
    try testing.expect(failures >= 2); // failures hit both the stack and the key buffer
}

/// Collect the values of all keys in [lo, hi) through the iterator.
fn collectRange(gpa: Allocator, tree: *const Art, lo: []const u8, hi: []const u8, out: *std.ArrayList(Entry64)) !void {
    var it = tree.iterator(gpa);
    defer it.deinit();
    try it.seek(lo);
    while (try it.next()) |e| {
        if (!std.mem.lessThan(u8, e.key, hi)) break;
        try out.append(gpa, .{ .key = keys.decodeU64(e.key), .value = e.value });
    }
}
const Entry64 = struct { key: u64, value: u64 };

test "model test against the oracle: put, get, range on u64 keys" {
    const gpa = testing.allocator;
    // (seed, key space): a tiny space forces overwrites and dense nodes, a
    // huge one gives sparse keys with long prefixes.
    const configs = [_][2]u64{ .{ 1, 300 }, .{ 2, 70_000 }, .{ 3, 1 << 40 } };
    for (configs) |cfg| {
        var tree: Art = .init(gpa);
        defer tree.deinit();
        var oracle: ops.Oracle = .{};
        defer oracle.deinit(gpa);
        var got: std.ArrayList(Entry64) = .empty;
        defer got.deinit(gpa);

        var stream = ops.OpStream.init(.{
            .seed = cfg[0],
            .count = 4000,
            .key_space = cfg[1],
            .weights = .{ .put = 5, .delete = 0, .get = 3, .range = 2 }, // no delete in this chapter
        });
        var n: usize = 0;
        while (stream.next()) |op| : (n += 1) {
            switch (op) {
                .put => |p| {
                    const old = try tree.put(&keys.encodeU64(p.key), p.value);
                    try testing.expectEqual(try oracle.put(gpa, p.key, p.value), old);
                },
                .get => |g| try testing.expectEqual(oracle.get(g.key), tree.get(&keys.encodeU64(g.key))),
                .range => |r| {
                    got.clearRetainingCapacity();
                    try collectRange(gpa, &tree, &keys.encodeU64(r.lo), &keys.encodeU64(r.hi), &got);
                    const want = oracle.range(r.lo, r.hi);
                    try testing.expectEqual(want.len, got.items.len);
                    for (want, got.items) |w, g| {
                        try testing.expectEqual(w.key, g.key);
                        try testing.expectEqual(w.value, g.value);
                    }
                },
                .delete => unreachable,
            }
            if (n % 64 == 0) try tree.validate();
        }
        try tree.validate();
        try testing.expectEqual(oracle.len(), tree.len);
    }
}

test "allocation failure at every point leaves the tree unchanged" {
    const gpa = testing.allocator;
    // Mixed key shapes so that failures land in chain building, prefix splits
    // and all three grow steps.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        var tree: Art = .init(failing.allocator());
        defer tree.deinit();
        var rng = SplitMix64.init(99);
        var inserted: std.ArrayList(u64) = .empty;
        defer inserted.deinit(gpa);

        var failures: usize = 0;
        for (0..700) |i| {
            // Low byte dense (drives one node to Node256), high bytes sparse.
            const k: u64 = if (i % 3 == 0) rng.below(256) else rng.nextU64();
            const before = tree.census();
            const had = tree.get(&keys.encodeU64(k));
            if (tree.put(&keys.encodeU64(k), i)) |_| {
                try inserted.append(gpa, k);
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                failures += 1;
                // Nothing changed: same shape, same answer for the failed key.
                try tree.validate();
                try testing.expectEqual(before, tree.census());
                try testing.expectEqual(had, tree.get(&keys.encodeU64(k)));
            }
        }
        try tree.validate();
        for (inserted.items) |k| try testing.expect(tree.get(&keys.encodeU64(k)) != null);
        if (!failing.has_induced_failure) break; // ran past the last allocation
        // FailingAllocator keeps failing from `fail_index` on, so every later
        // put that needed fresh memory failed too (and was checked above).
        try testing.expect(failures >= 1);
    }
    try testing.expect(fail_index > 10); // the loop really exercised several failure points
}

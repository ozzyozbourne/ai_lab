//! Storage 1: one sparse set per component type (the EnTT layout).
//! Each component lives in a packed `data` array whose order is the set's own, and
//! `sparse[entity.index]` says where (or `none`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Entity = @import("entity.zig").Entity;
const Entities = @import("entity.zig").Entities;
const main = @import("main.zig");

const none = std.math.maxInt(u32);

/// Sparse array indexed by entity index -> position in the packed arrays.
/// `dense[i]` is the entity whose component is `data[i]`.
pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();
        sparse: std.ArrayList(u32) = .empty,
        dense: std.ArrayList(Entity) = .empty,
        data: std.ArrayList(T) = .empty,

        pub const empty: Self = .{};

        pub fn deinit(s: *Self, gpa: Allocator) void {
            s.sparse.deinit(gpa);
            s.dense.deinit(gpa);
            s.data.deinit(gpa);
        }

        pub fn len(s: *const Self) usize {
            return s.dense.items.len;
        }

        /// Two dependent loads: sparse, then dense. Comparing the whole Entity (with its
        /// generation) means a stale id fails here even if its index was reused.
        fn position(s: *const Self, e: Entity) ?u32 {
            if (e.index >= s.sparse.items.len) return null;
            const d = s.sparse.items[e.index];
            if (d >= s.dense.items.len or s.dense.items[d] != e) return null;
            return d;
        }

        pub fn get(s: *const Self, e: Entity) ?*T {
            const d = s.position(e) orelse return null;
            return &s.data.items[d];
        }

        /// O(1): append to the packed arrays and point the sparse slot at the new position.
        pub fn insert(s: *Self, gpa: Allocator, e: Entity, value: T) Allocator.Error!void {
            if (s.position(e)) |d| {
                s.data.items[d] = value;
                return;
            }
            if (e.index >= s.sparse.items.len) {
                const old = s.sparse.items.len;
                try s.sparse.resize(gpa, e.index + 1);
                @memset(s.sparse.items[old..], none);
            }
            s.sparse.items[e.index] = @intCast(s.dense.items.len);
            try s.dense.append(gpa, e);
            try s.data.append(gpa, value);
        }

        /// O(1) swap-and-pop: the last element moves into the hole and its sparse slot is fixed.
        pub fn remove(s: *Self, e: Entity) ?T {
            const d = s.position(e) orelse return null;
            const last = s.dense.last().?;
            s.sparse.items[last.index] = d;
            s.sparse.items[e.index] = none;
            _ = s.dense.swapRemove(d);
            return s.data.swapRemove(d);
        }
    };
}

/// Join of two sets: walk the smaller packed array, probe the other one by entity id.
/// `f(ctx, *A, *B)` is comptime-known, so each call site gets its own inlined loop.
pub fn query2(a: anytype, b: anytype, ctx: anytype, comptime f: anytype) void {
    if (a.len() <= b.len()) {
        for (a.dense.items, a.data.items) |e, *va| if (b.get(e)) |vb| f(ctx, va, vb);
    } else {
        for (b.dense.items, b.data.items) |e, *vb| if (a.get(e)) |va| f(ctx, va, vb);
    }
}

/// Join of three sets, driven by the smallest; the other two are probed per entity.
pub fn query3(a: anytype, b: anytype, c: anytype, ctx: anytype, comptime f: anytype) void {
    const smallest = @min(a.len(), b.len(), c.len());
    if (c.len() == smallest) {
        for (c.dense.items, c.data.items) |e, *vc| {
            const va = a.get(e) orelse continue;
            const vb = b.get(e) orelse continue;
            f(ctx, va, vb, vc);
        }
    } else if (a.len() == smallest) {
        for (a.dense.items, a.data.items) |e, *va| {
            const vb = b.get(e) orelse continue;
            const vc = c.get(e) orelse continue;
            f(ctx, va, vb, vc);
        }
    } else {
        for (b.dense.items, b.data.items) |e, *vb| {
            const va = a.get(e) orelse continue;
            const vc = c.get(e) orelse continue;
            f(ctx, va, vb, vc);
        }
    }
}

/// The sparse-set world: an entity allocator plus one set per component type.
pub const SparseWorld = struct {
    entities: Entities = .empty,
    pos: SparseSet(main.Pos) = .empty,
    vel: SparseSet(main.Vel) = .empty,
    hp: SparseSet(main.Hp) = .empty,

    pub fn deinit(w: *SparseWorld, gpa: Allocator) void {
        w.entities.deinit(gpa);
        w.pos.deinit(gpa);
        w.vel.deinit(gpa);
        w.hp.deinit(gpa);
    }

    pub fn spawn(w: *SparseWorld, gpa: Allocator, pos: main.Pos, vel: ?main.Vel, hp: ?main.Hp) !Entity {
        const e = try w.entities.spawn(gpa);
        try w.pos.insert(gpa, e, pos);
        if (vel) |v| try w.vel.insert(gpa, e, v);
        if (hp) |h| try w.hp.insert(gpa, e, h);
        return e;
    }

    pub fn despawn(w: *SparseWorld, gpa: Allocator, e: Entity) !bool {
        if (!w.entities.alive(e)) return false;
        _ = w.pos.remove(e);
        _ = w.vel.remove(e);
        _ = w.hp.remove(e);
        try w.entities.despawn(gpa, e);
        return true;
    }
};

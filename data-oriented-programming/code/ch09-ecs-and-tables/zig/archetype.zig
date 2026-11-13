//! Storage 2: one table per component combination (archetype storage, minimal).
//! With three component types a combination is a 3-bit mask, so the "archetype graph edge"
//! for adding VEL is just `mask | VEL` and the tables live in an array indexed by mask.
//! A real ECS has open-ended component ids and needs a hash map plus cached edges for this.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Entity = @import("entity.zig").Entity;
const Entities = @import("entity.zig").Entities;
const main = @import("main.zig");
const Pos = main.Pos;
const Vel = main.Vel;
const Hp = main.Hp;

pub const POS: u8 = 1;
pub const VEL: u8 = 2;
pub const HP: u8 = 4;

/// One archetype: SoA columns with aligned rows. Columns for components outside `mask` stay empty.
pub const Table = struct {
    mask: u8,
    entities: std.ArrayList(Entity) = .empty,
    pos: std.ArrayList(Pos) = .empty,
    vel: std.ArrayList(Vel) = .empty,
    hp: std.ArrayList(Hp) = .empty,
};

/// Where an entity's row lives: the entity index (Mertens calls this the "record").
const Location = struct { table: u8 = 0, row: u32 = 0 };

/// The components of one entity while it moves between tables.
const Row = struct { pos: ?Pos, vel: ?Vel, hp: ?Hp };

pub const ArchWorld = struct {
    entities: Entities = .empty,
    loc: std.ArrayList(Location) = .empty, // indexed by entity index
    tables: [8]Table = blk: { // indexed by component mask
        var t: [8]Table = undefined;
        for (&t, 0..) |*x, m| x.* = .{ .mask = @intCast(m) };
        break :blk t;
    },

    pub fn deinit(w: *ArchWorld, gpa: Allocator) void {
        w.entities.deinit(gpa);
        w.loc.deinit(gpa);
        for (&w.tables) |*t| {
            t.entities.deinit(gpa);
            t.pos.deinit(gpa);
            t.vel.deinit(gpa);
            t.hp.deinit(gpa);
        }
    }

    pub fn spawn(w: *ArchWorld, gpa: Allocator, pos: Pos, vel: ?Vel, hp: ?Hp) !Entity {
        const e = try w.entities.spawn(gpa);
        if (e.index >= w.loc.items.len) try w.loc.resize(gpa, e.index + 1);
        try w.put(gpa, e, .{ .pos = pos, .vel = vel, .hp = hp });
        return e;
    }

    pub fn despawn(w: *ArchWorld, gpa: Allocator, e: Entity) !bool {
        if (!w.entities.alive(e)) return false;
        _ = w.take(e);
        try w.entities.despawn(gpa, e);
        return true;
    }

    /// Appends a row to the table that matches exactly the components present.
    fn put(w: *ArchWorld, gpa: Allocator, e: Entity, r: Row) !void {
        const mask = (if (r.pos != null) POS else 0) | (if (r.vel != null) VEL else 0) | (if (r.hp != null) HP else 0);
        const t = &w.tables[mask];
        w.loc.items[e.index] = .{ .table = mask, .row = @intCast(t.entities.items.len) };
        try t.entities.append(gpa, e);
        if (r.pos) |p| try t.pos.append(gpa, p);
        if (r.vel) |v| try t.vel.append(gpa, v);
        if (r.hp) |h| try t.hp.append(gpa, h);
    }

    /// Swap-and-pops the entity's row out of its table, column by column, and fixes the
    /// location of the entity that moved into the hole.
    fn take(w: *ArchWorld, e: Entity) Row {
        const l = w.loc.items[e.index];
        const t = &w.tables[l.table];
        _ = t.entities.swapRemove(l.row);
        if (l.row < t.entities.items.len) w.loc.items[t.entities.items[l.row].index].row = l.row;
        return .{
            .pos = if (l.table & POS != 0) t.pos.swapRemove(l.row) else null,
            .vel = if (l.table & VEL != 0) t.vel.swapRemove(l.row) else null,
            .hp = if (l.table & HP != 0) t.hp.swapRemove(l.row) else null,
        };
    }

    /// Adding a component is a move: the whole row is copied to the table for `mask | VEL`.
    pub fn addVel(w: *ArchWorld, gpa: Allocator, e: Entity, v: Vel) !void {
        var r = w.take(e);
        r.vel = v;
        try w.put(gpa, e, r);
    }

    pub fn removeVel(w: *ArchWorld, gpa: Allocator, e: Entity) !?Vel {
        var r = w.take(e);
        const v = r.vel;
        r.vel = null;
        try w.put(gpa, e, r);
        return v;
    }

    pub fn has(w: *const ArchWorld, e: Entity, component: u8) bool {
        return w.entities.alive(e) and w.loc.items[e.index].table & component != 0;
    }

    pub fn get(w: *ArchWorld, e: Entity) Row {
        if (!w.entities.alive(e)) return .{ .pos = null, .vel = null, .hp = null };
        const l = w.loc.items[e.index];
        const t = &w.tables[l.table];
        return .{
            .pos = if (l.table & POS != 0) t.pos.items[l.row] else null,
            .vel = if (l.table & VEL != 0) t.vel.items[l.row] else null,
            .hp = if (l.table & HP != 0) t.hp.items[l.row] else null,
        };
    }

    /// The number of entities in every table whose mask contains all of `with`.
    pub fn countWith(w: *const ArchWorld, with: u8) usize {
        var n: usize = 0;
        for (&w.tables) |*t| {
            if (t.mask & with == with) n += t.entities.items.len;
        }
        return n;
    }
};

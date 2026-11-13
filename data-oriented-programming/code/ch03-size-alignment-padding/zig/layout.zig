//! Part (a): sizes, alignments and offsets of the chapter's structs, as Zig 0.17.1 lays them out on x86-64.
const std = @import("std");
const Io = std.Io;

// ---- Kelley's alignment quiz (extern = C layout, so the order is the one written) ----
const U32Bool = extern struct { a: u32, b: bool };
const Quiz = extern struct { a: u32, b: u64, c: u32 };
const QuizSorted = extern struct { a: u32, c: u32, b: u64 };
const QuizSortedBool = extern struct { a: u32, c: u32, b: u64, d: bool };

// default-layout
// ---- the same fields, three layouts ----
const Mixed = struct { a: u8, b: u64, c: u8, d: u32 }; // compiler picks the order
const MixedExtern = extern struct { a: u8, b: u64, c: u8, d: u32 }; // C order
const MixedPacked = packed struct { a: u8, b: u64, c: u8, d: u32 }; // a u112 bit field
// default-layout

// monster
const Animation = struct { frames: []const u32 };

/// A pointer, two u32s and a bool: 8 + 4 + 4 + 1 = 17 bytes of data, 24 bytes of struct.
const Monster = struct { anim: *const Animation, hp: u32, y: u32, alive: bool };
/// `alive` moved out of band (one list of live monsters, one of dead ones): 16 bytes.
const MonsterOob = struct { anim: *const Animation, hp: u32, y: u32 };
/// The pointer replaced by a u32 index into an animation table: 12 bytes, alignment 4.
const MonsterIdx = struct { anim: u32, hp: u32, y: u32 };

comptime {
    std.debug.assert(@sizeOf(Monster) == 24);
    std.debug.assert(@sizeOf(MonsterOob) == 16);
    std.debug.assert(@sizeOf(MonsterIdx) == 12);
}
// monster

// niche
const Kind = enum { bee, human, snake, wolf, ghost }; // tag type u3, stored in 1 byte
/// Zig has no NonZero types. The idiom is a non-exhaustive enum with a named sentinel.
const AnimId = enum(u32) { none = std.math.maxInt(u32), _ };

comptime {
    std.debug.assert(@sizeOf(Kind) == 1);
    std.debug.assert(@sizeOf(?Kind) == 2); // no niche: a separate "has value" byte
    std.debug.assert(@sizeOf(?u32) == 8); // tag + padding
    std.debug.assert(@sizeOf(AnimId) == 4); // the sentinel costs nothing
    std.debug.assert(@sizeOf(?AnimId) == 8); // but `?` does not know about it
    std.debug.assert(@sizeOf(?*const u64) == 8); // optional pointers use address 0
}
// niche

// quantize
const PosF32 = struct { x: f32, y: f32, z: f32 }; // 12 bytes
const PosU16 = struct { x: u16, y: u16, z: u16 }; // 6 bytes: 1 km cell / 65535 ≈ 1.5 cm steps
const PosF16 = struct { x: f16, y: f16, z: f16 }; // 6 bytes, but only ~3 significant digits

/// Fields are laid out from the least significant bit: kind = bits 0..3, layer = 4..7, index = 8..31.
const PackedRef = packed struct(u32) { kind: u4, layer: u4, index: u24 };

comptime {
    std.debug.assert(@sizeOf(PackedRef) == 4);
}
// quantize

const CELL_M: f32 = 1000.0;

fn quantize(v: f32) u16 {
    return @intFromFloat(@round(std.math.clamp(v / CELL_M, 0, 1) * std.math.maxInt(u16)));
}

fn dequantize(q: u16) f32 {
    return @as(f32, @floatFromInt(q)) / std.math.maxInt(u16) * CELL_M;
}

const CacheLine = struct { counter: u64 align(64) };

fn row(out: *Io.Writer, name: []const u8, comptime T: type, extra: []const u8) !void {
    try out.print("{s:<28} size {d:>3}  align {d:>2}  {s}\n", .{ name, @sizeOf(T), @alignOf(T), extra });
}

fn offsets(buf: []u8, comptime T: type) ![]const u8 {
    return std.mem.print(buf, "offsets a={d} b={d} c={d} d={d}", .{
        @offsetOf(T, "a"), @offsetOf(T, "b"), @offsetOf(T, "c"), @offsetOf(T, "d"),
    });
}

pub fn print(out: *Io.Writer) !void {
    var buf: [96]u8 = undefined;
    try out.writeAll("== layout (zig, x86-64) ==\n");
    try row(out, "U32Bool extern", U32Bool, "");
    try row(out, "Quiz {u32,u64,u32} extern", Quiz, "");
    try row(out, "QuizSorted {u32,u32,u64}", QuizSorted, "");
    try row(out, "QuizSorted + bool", QuizSortedBool, "");
    try row(out, "Mixed (struct)", Mixed, try offsets(&buf, Mixed));
    try row(out, "Mixed extern struct", MixedExtern, try offsets(&buf, MixedExtern));
    try row(out, "Mixed packed struct", MixedPacked, try std.mem.print(&buf, "{d} bits; bit offsets b={d} d={d}", .{
        @bitSizeOf(MixedPacked), @bitOffsetOf(MixedPacked, "b"), @bitOffsetOf(MixedPacked, "d"),
    }));
    try row(out, "Monster {*Anim,u32,u32,bool}", Monster, try std.mem.print(&buf, "offsets anim={d} hp={d} y={d} alive={d}", .{
        @offsetOf(Monster, "anim"), @offsetOf(Monster, "hp"), @offsetOf(Monster, "y"), @offsetOf(Monster, "alive"),
    }));
    try row(out, "MonsterOob (bool out of band)", MonsterOob, "");
    try row(out, "MonsterIdx (u32 index)", MonsterIdx, "");
    try row(out, "Kind (5 tags)", Kind, "");
    try row(out, "?Kind", ?Kind, "");
    try row(out, "?u32", ?u32, "");
    try row(out, "?u31", ?u31, "");
    try row(out, "AnimId enum(u32) sentinel", AnimId, "");
    try row(out, "?AnimId", ?AnimId, "");
    try row(out, "?*const u64", ?*const u64, "");
    try row(out, "PosF32", PosF32, "");
    try row(out, "PosU16", PosU16, "");
    try row(out, "PosF16", PosF16, "");
    try row(out, "PackedRef packed struct(u32)", PackedRef, "");
    try row(out, "u24", u24, "");
    try row(out, "CacheLine align(64)", CacheLine, "");
    const p: PackedRef = .{ .kind = 3, .layer = 7, .index = 123_456 };
    try out.print("PackedRef(3, 7, 123456) -> kind={d} layer={d} index={d} raw=0x{x:0>8}\n", .{ p.kind, p.layer, p.index, @backingInt(p) });
    const q = quantize(123.456);
    try out.print("quantize(123.456 m) = {d} -> {d:.4} m (error {d:.4} m)\n", .{ q, dequantize(q), @abs(dequantize(q) - 123.456) });
    const h: f16 = 123.456;
    try out.print("f16 123.456 -> {d:.4} (error {d:.4})\n", .{ @as(f32, h), @abs(@as(f32, h) - 123.456) });
}

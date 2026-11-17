//! Section 9: the 0.17.1 replacement for each old idiom that no longer compiles.
//! Each test is the *working* form; the failing old form is quoted in the comment.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;

test "builtin.mode tags are lowercase and renamed" {
    // old: if (builtin.mode == .Debug)   -> error: no field named 'Debug' in enum 'lang.Optimize'
    const safe_build = switch (builtin.mode) {
        .debug, .safe => true, // were .Debug, .ReleaseSafe
        .fast, .small => false, // were .ReleaseFast, .ReleaseSmall
    };
    try testing.expectEqual(std.debug.runtime_safety, safe_build);
}

test "std.lang replaces std.builtin (alias still works in 0.17)" {
    const e: std.lang.Endian = .little; // old: std.builtin.Endian.Little
    const o: std.lang.AtomicOrder = .seq_cst; // old: .SeqCst
    try testing.expect(e == .little and o == .seq_cst);
    comptime std.debug.assert(std.builtin.Endian == std.lang.Endian);
}

test "@typeInfo: lowercase tags; struct info is field_names/field_types/field_attrs" {
    // old: @typeInfo(T).Struct.fields            -> no field named 'Struct'
    // old: @typeInfo(T).@"struct".fields         -> no field named 'fields'
    // old: std.meta.fields(T)                    -> @compileError("deprecated in favor of @typeInfo")
    const Hdr = extern struct { magic: u32 = 7, count: u16 align(2) = 0, pad: u16 = 0 };
    const info = @typeInfo(Hdr).@"struct";
    try testing.expect(info.layout == .@"extern");
    comptime var total: usize = 0;
    inline for (info.field_names, info.field_types, info.field_attrs) |name, T, attrs| {
        total += @sizeOf(T);
        _ = name;
        _ = attrs.@"align";
    }
    try testing.expectEqual(8, total);
    try testing.expectEqual(7, info.field_attrs[0].defaultValue(u32).?);
    try testing.expectEqualStrings("count", std.meta.fieldNames(Hdr)[1]);
    comptime std.debug.assert(std.meta.fieldTypes(Hdr)[2] == u16);

    // pointers: .size is .one/.many/.slice/.c ; qualifiers moved under .attrs
    const p = @typeInfo([]align(4) const u8).pointer;
    try testing.expect(p.size == .slice and p.child == u8);
    try testing.expect(p.attrs.@"const");
    try testing.expectEqual(4, p.attrs.@"align".?);
    // enums / unions / fns: field_names etc. as well
    const E = enum(u8) { a, b };
    try testing.expectEqual(2, @typeInfo(E).@"enum".field_names.len);
    try testing.expectEqual(u8, @typeInfo(E).@"enum".tag_type);
}

test "@Type is gone: @Int, @Struct, @Enum, @Union, @Pointer, @Tuple, @Fn" {
    // old: @Type(.{ .int = .{ .signedness = .unsigned, .bits = 7 } }) -> invalid builtin function: '@Type'
    // old: std.meta.Int(.unsigned, 7)
    const U7 = @Int(.unsigned, 7);
    try testing.expectEqual(7, @bitSizeOf(U7));
    const Pair = @Tuple(&.{ u32, bool });
    const pair: Pair = .{ 1, true };
    try testing.expectEqual(1, pair[0]);
}

test "casts: single-argument builtins, result type from context" {
    const big: u64 = 300;
    // old: @intCast(u32, big)       -> expected 1 argument, found 2
    const a: u32 = @intCast(big);
    const b = @as(u16, @intCast(big));
    const c: u8 = @truncate(big);
    try testing.expectEqual(300 + 300 + 44, a + b + c);
    // old: @enumToInt / @intToEnum / @intToPtr / @ptrToInt / @boolToInt / @intToFloat / @floatToInt
    const E = enum(u8) { x = 3 };
    try testing.expectEqual(3, @backingInt(E.x));
    try testing.expectEqual(E.x, @as(E, @fromBackingInt(@intCast(3))));
    try testing.expectEqual(1, @intFromBool(true));
    try testing.expectEqual(2.0, @as(f64, @floatFromInt(@as(u8, 2))));
    try testing.expectEqual(2, @as(u8, @intFromFloat(@as(f64, 2.9))));
    var x: u32 = 0;
    const addr: usize = @intFromPtr(&x);
    const p: *u32 = @ptrFromInt(addr);
    p.* = 1;
    try testing.expectEqual(1, x);
    // old: @fieldParentPtr(T, "field", ptr) -> expected 2 arguments, found 3
    const S = struct { a: u8, b: u32 };
    var s: S = .{ .a = 1, .b = 2 };
    const parent: *S = @fieldParentPtr("b", &s.b);
    try testing.expectEqual(1, parent.a);
}

test "for loops: index is a second operand, ranges, multi-sequence" {
    const keys = [_]u8{ 10, 20, 30 };
    const vals = [_]u8{ 1, 2, 3 };
    var sum: usize = 0;
    // old: for (keys) |k, i|   -> error: extra capture in for loop
    for (keys, 0..) |k, i| sum += k * i;
    for (0..3) |i| sum += i; // range loop
    for (keys, vals) |k, v| sum += k + v; // lengths must match (checked)
    var copy = keys;
    for (&copy) |*k| k.* += 1; // mutate through pointer capture
    try testing.expectEqual(80 + 3 + 66, sum);
}

test "@splat for arrays, decl literals, destructuring" {
    const zero_page: [4096]u8 = @splat(0); // old: [_]u8{0} ** 4096 (still valid)
    try testing.expectEqual(0, zero_page[4095]);
    var list: std.ArrayList(u8) = .empty; // decl literal: `.empty` / `.init(x)` resolve on the result type
    defer list.deinit(testing.allocator);
    const q, const r = .{ 17 / 5, 17 % 5 };
    try testing.expectEqual(3 + 2, q + r);
}

fn exportedStyle() callconv(.c) void {} // old: callconv(.C) -> no member named 'C'

fn rarelyCalled() void {
    @branchHint(.cold); // old: @setCold(true) -> invalid builtin function: '@setCold'
}

test "calling conventions and cold functions" {
    exportedStyle();
    rarelyCalled();
}

/// Writers are concrete: take `*std.Io.Writer`, never copy it by value.
fn emit(w: *Io.Writer) Io.Writer.Error!void {
    try w.writeAll("x");
}

test "Io.Writer must be passed by pointer" {
    // old: fn emit(w: anytype) / std.io.AnyWriter / std.io.fixedBufferStream(&buf).writer()
    var buf: [4]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try emit(&w);
    try testing.expectEqualStrings("x", w.buffered());
    // WRONG (compiles, silently loses data): `var copy = file_writer.interface;` or `fn f(w: Io.Writer)`.
    // The interface must stay inside its File.Writer: always `&file_writer.interface`.
}

test "in-memory reader replaces fixedBufferStream().reader()" {
    var r: Io.Reader = .fixed(&.{ 1, 0, 0, 0, 9, 'a', 'b', '\n' });
    try testing.expectEqual(1, try r.takeInt(u32, .little)); // old: reader.readInt(u32, .little)
    try testing.expectEqual(9, try r.takeByte()); // old: readByte()
    try testing.expectEqualStrings("ab", (try r.takeDelimiter('\n')).?); // old: readUntilDelimiter
    try testing.expectError(error.EndOfStream, r.takeByte());
}

test "growable byte buffer writer replaces ArrayList(u8).writer()" {
    const gpa = testing.allocator;
    // old: list.writer().print(...)  -> no field or member function named 'writer'
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.print(gpa, "{d}", .{1}); // direct
    var aw: Io.Writer.Allocating = .fromArrayList(gpa, &list); // or adopt the list as a Writer
    try aw.writer.print("{d}", .{2});
    list = aw.toArrayList();
    try testing.expectEqualStrings("12", list.items);
}

test "time: std.time.Timer/milliTimestamp/sleep moved to std.Io" {
    const io = testing.io;
    // old: std.time.Timer.start() / timer.read()
    const t0 = Io.Clock.awake.now(io); // monotonic
    try io.sleep(.fromMilliseconds(1), .awake); // old: std.time.sleep(ns) / std.Thread.sleep(ns)
    const dt = t0.untilNow(io, .awake);
    try testing.expect(dt.toNanoseconds() >= std.time.ns_per_ms);
    // old: std.time.milliTimestamp()
    const wall_ms: i64 = Io.Clock.real.now(io).toMilliseconds();
    try testing.expect(wall_ms > 1_600_000_000_000);
}

test "entropy: std.crypto.random / std.posix.getrandom moved to io.random" {
    var seed: u64 = undefined;
    testing.io.random(std.mem.asBytes(&seed)); // old: std.crypto.random.int(u64) / std.posix.getrandom(&buf)
    var prng: std.Random.DefaultPrng = .init(seed); // old: std.rand.DefaultPrng
    _ = prng.random().int(u32);
}

test "std.mem renames: copy/set gone, indexOf* -> find*" {
    var a: [3]u8 = undefined;
    @memcpy(&a, "abc"); // old: std.mem.copy(u8, &a, "abc")
    @memset(a[0..1], 'z'); // old: std.mem.set(u8, ..., 'z')
    try testing.expectEqual(1, std.mem.findScalar(u8, &a, 'b').?); // old name indexOfScalar still aliased
    try testing.expectEqual(1, std.mem.find(u8, &a, "bc").?); // indexOf
    try testing.expectEqual(2, std.mem.findScalarLast(u8, &a, 'c').?); // lastIndexOfScalar
    try testing.expectEqual(3, @max(1, 3)); // old: std.math.max
    var xs = [_]u8{ 2, 1 };
    std.mem.sort(u8, &xs, {}, std.sort.asc(u8)); // old: std.sort.sort
    try testing.expectEqual(1, xs[0]);
}

test "single-threaded Io without process.Init" {
    // For helper binaries / tests that need an Io but have no `init`:
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var buf: [8]u8 = undefined;
    io.random(&buf);
    // Full version: var threaded: Io.Threaded = .init(gpa, .{}); defer threaded.deinit();
}

# 02 — Zig slice: Zig 0.17.1 idioms + DOD facts

Researched 2026-11-13. Toolchain: `zig version` → `0.17.1` (`~/tools/zig`), std source at `~/langsrc/zig` (tag 0.17.1, commit `be248cc1`, 2026-11-02).
Every snippet marked ✅ was compiled and run with this 0.17.1 toolchain in `/tmp/zigprobe` (x86_64 Linux, 4-core Intel Xeon @ 2.60 GHz, in an orb). Every error message quoted below came from this compiler.

> **The main thing to know:** Zig changed a lot between 0.14 and 0.17. Most Zig code online, and most LLM training data, is 0.13–0.15 style and **will not compile**. The biggest breaks:
> (1) 0.15: "Writergate" (`std.io` → `std.Io.Writer`/`Reader` with the buffer inside the interface) and `ArrayList` becoming unmanaged;
> (2) 0.16: "I/O as an Interface": everything that blocks or is nondeterministic (files, stdout, clocks, sleep, randomness, mutexes, threads) takes an `io: std.Io`; `main` can take `std.process.Init` ("Juicy Main");
> (3) 0.17: renames (`-O fast`, `.debug/.safe/.fast/.small`, `std.lang`, `SafeAllocator`, `bit_set.Static/Dynamic`, `@backingInt`), with `@typeInfo` now returning struct-of-arrays.

---

## 1. Zig 0.17 idiom cheat-sheet (all ✅ verified)

### 1.1 `main`, allocator, Io: the standard skeleton

```zig
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;                    // general-purpose allocator (leak-checked in debug/safe)
    const io = init.io;                      // the Io implementation (Io.Threaded)
    const arena = init.arena.allocator();    // process-lifetime arena, freed at exit, threadsafe
    const args = try init.minimal.args.toSlice(arena);
    _ = args;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface; // *std.Io.Writer — pass THIS to functions

    try stdout.print("hello {s}\n", .{"world"});
    try stdout.flush();                      // "Don't forget to flush!" — nothing appears otherwise
    _ = gpa;
}
```

Facts from `lib/std/process.zig:31` and `lib/std/start.zig:780-835`:
- `std.process.Init` fields are `minimal: Minimal{environ, args}`, `arena: *std.heap.ArenaAllocator`, `gpa: Allocator`, `io: Io`, `environ_map: *Environ.Map`, `preopens`.
- `main` may take no parameter, `std.process.Init.Minimal` (just argv/environ), or `std.process.Init`.
- What `init.gpa` is: in `-O debug`/`-O safe` it is `std.heap.SafeAllocator` (leaks are logged at exit but **do not change the exit code**); with libc it is `c_allocator`; otherwise in fast/small it is `std.heap.smp_allocator`. `init.io` is `std.Io.Threaded`.
- `zig init` (0.17.1) writes the same pattern, but with `var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);`. Both forms are fine.
- `std.debug.print` still exists. It writes to stderr, unbuffered, ignores errors, and needs no `io`, so use it for quick demos and debugging. Note the ordering: with a deferred `flush`, debug output shows up *before* buffered stdout output.
- If you have no `Io` (library code, quick hacks): `var threaded: std.Io.Threaded = .init_single_threaded; const io = threaded.io();` ✅. The release notes call this a "non-ideal workaround"; the better fix is to take an `io: Io` parameter.
- One-shot unbuffered write: `try std.Io.File.stdout().writeStreamingAll(io, "Hello\n");` (from `doc/langref/hello.zig`). `File.writeAll` **does not exist**: `error: no field or member function named 'writeAll' in 'Io.File'`.

### 1.2 Benchmark timer (std.time.Timer/Instant are gone; the clock is on Io)

```zig
const start = Io.Clock.awake.now(io);            // Io.Timestamp {nanoseconds: i96}
// ... work ...
std.mem.doNotOptimizeAway(result);
const elapsed = start.untilNow(io, .awake);      // Io.Duration
try stdout.print("{d} ns ({f})\n", .{ elapsed.toNanoseconds(), elapsed }); // "{f}" pretty-prints e.g. "6.344ms"
```
- Pattern from std's own benchmarks (`lib/std/hash/benchmark.zig:113`): `fn benchTime(io: Io) i96 { return Io.Clock.awake.now(io).nanoseconds; }`, then subtract.
- Clocks (`Io.zig:836`): `.real` (wall), `.awake` (monotonic, CLOCK_MONOTONIC: **use this for benchmarks**), `.boot`, `.cpu_process`, `.cpu_thread`. `clock.resolution(io)` reports the granularity.
- `Io.Duration`: `.fromNanoseconds/.fromMilliseconds/.fromSeconds`, `.toNanoseconds()` (i96), `.toMilliseconds()` etc. `t0.durationTo(t1)`.
- Sleep: `try io.sleep(.fromMilliseconds(1), .awake);` ✅
- `std.time` now holds only constants (`ns_per_s`, `ms_per_s`, …) plus `epoch`.

### 1.3 ArrayList (unmanaged by default since 0.15)

```zig
var list: std.ArrayList(u32) = .empty;           // NOT .init(gpa), NOT .{}
defer list.deinit(gpa);
try list.append(gpa, 1);                         // allocator on every allocating call
try list.appendSlice(gpa, &.{ 2, 3, 4 });
try list.ensureTotalCapacity(gpa, 1000);
list.appendAssumeCapacity(5);
const last = list.last().?;                      // 0.17: getLast/getLastOrNull deprecated → last()

var storage: [8]u8 = undefined;                  // fixed-capacity list, no allocator (BoundedArray replacement)
var fixed: std.ArrayList(u8) = .initBuffer(&storage);
try fixed.appendBounded('h');                    // returns error.OutOfMemory when full
fixed.appendAssumeCapacity('i');
```
- `ArrayListUnmanaged` is a deprecated alias of `ArrayList`. `std.array_list.Managed(T)` is the old managed type, slated for removal.
- `list.print(gpa, fmt, args)` exists. `list.writer()` **does not**. For a growable in-memory writer use `std.Io.Writer.Allocating`:
  `var aw: std.Io.Writer.Allocating = .init(gpa); defer aw.deinit(); try aw.writer.print("{d}", .{42}); aw.written()` ✅

### 1.4 MultiArrayList (SoA): the core DOD container

```zig
const Monster = struct { hp: u32, x: f32, y: f32, alive: bool };

var monsters: std.MultiArrayList(Monster) = .empty;
defer monsters.deinit(gpa);
try monsters.ensureTotalCapacity(gpa, n);
monsters.appendAssumeCapacity(.{ .hp = 10, .x = 0, .y = 0, .alive = true });
try monsters.append(gpa, .{ .hp = 5, .x = 1, .y = 1, .alive = false });

const s = monsters.slice();                      // take the Slice ONCE outside hot loops (it caches field pointers)
const xs = s.items(.x);                          // []f32
const ys = s.items(.y);
for (xs, ys) |*x, y| x.* += y * 0.016;           // multi-object for loop over parallel columns
const m0: Monster = monsters.get(0);             // gather an AoS view of one element
monsters.set(0, m0);
// also: resize(gpa,n), swapRemove, orderedRemove, pop, insert, clone, sort(ctx), capacityInBytes(n)
```
- Measured: `@sizeOf(Monster) == 16` (AoS), `MultiArrayList(Monster).capacityInBytes(1) == 13` (SoA: 4+4+4+1, no padding).
- Tagged unions work too: `MultiArrayList(Shape)` stores `.tags` and `.data` columns (`shapes.items(.tags)`). ✅
- Sorting by a column ✅:
  ```zig
  l.sort(struct {
      keys: []const u32,
      pub fn lessThan(ctx: @This(), a: usize, b: usize) bool { return ctx.keys[a] < ctx.keys[b]; }
  }{ .keys = l.items(.key) });
  ```
- Internals (`lib/std/multi_array_list.zig`): a single allocation `bytes: [*]u8` holds all columns back to back, with column sub-arrays **ordered by field alignment, descending**, so the columns themselves need no padding.

### 1.5 Allocators

| Need | 0.17 spelling |
|---|---|
| default GPA in an app | `init.gpa` from Juicy Main |
| leak-checking GPA you construct yourself | `var sa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{}); defer if (sa.deinit() != 0) @panic("leak"); const gpa = sa.allocator();` ✅ (`deinit` returns the **number of leaks**, a `usize`) |
| fast multithreaded GPA for release | `std.heap.smp_allocator` |
| arena | `var arena: std.heap.ArenaAllocator = .init(gpa); defer arena.deinit(); const a = arena.allocator();` ✅; reuse it with `_ = arena.reset(.retain_capacity);`. Since 0.16 it is **thread-safe and lock-free** |
| pages from the OS | `std.heap.page_allocator` |
| fixed buffer | `var fba: std.heap.FixedBufferAllocator = .init(&buf);` ✅ |
| stack buffer first, then heap ("small-vec") | `std.heap.BufferFirstAllocator.init(buf, gpa)` (0.17 rename of StackFallbackAllocator) |
| object pool | `var pool: std.heap.MemoryPool(Node) = .empty; defer pool.deinit(gpa); const p = try pool.create(gpa); pool.destroy(p);` ✅ |
| tests | `std.testing.allocator` (a leak fails the test) |
| format into an allocation | `try gpa.print("{s}={d}", .{x, y})` (0.17; `std.fmt.allocPrint` is deprecated) ✅ |
| format into a buffer | `try std.mem.print(&buf, "x={d}", .{7})` (0.17; `std.fmt.bufPrint` is deprecated) ✅ |
| `dupeZ` | gone: `gpa.dupeSentinel(u8, s, 0)` ✅ |

A leak report from SafeAllocator looks like this: `error(SafeAllocator): leaked [addr: 7f18132f6010, len: 8 (0x8) align: 8] allocated at: … p15_leak.zig:2:158`.

### 1.6 Hash maps, bit sets, enums

```zig
var map: std.AutoHashMapUnmanaged(u32, f32) = .empty;      // still the name in 0.17
defer map.deinit(gpa);
try map.put(gpa, 7, 0.5);
const gop = try map.getOrPut(gpa, 7);
if (gop.found_existing) gop.value_ptr.* += 1;

var amap: std.array_hash_map.Auto(u32, u8) = .empty;      // 0.17 name (AutoArrayHashMapUnmanaged = deprecated alias)
defer amap.deinit(gpa);
try amap.put(gpa, 1, 'a');
_ = amap.keys();                                           // array hash map = dense keys/values arrays: DOD-friendly iteration

var bits: std.bit_set.Static(128) = .empty;               // 0.17: .empty/.full decl literals (initEmpty() removed)
bits.set(3);
var dbits: std.bit_set.Dynamic = try .initEmpty(gpa, 10_000); // Dynamic (unmanaged) keeps initEmpty(gpa, n)
defer dbits.deinit(gpa);
var it = dbits.iterator(.{});
_ = it.next();
```

Typed indices (the Kelley/matklad "newtype index" pattern) with the 0.17 builtins ✅:
```zig
const MonsterId = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    fn from(i: usize) MonsterId { return @fromBackingInt(@intCast(i)); }
    fn index(id: MonsterId) usize { return @backingInt(id); }
};
comptime { std.debug.assert(@sizeOf(MonsterId) == 4); }
```
`@intFromEnum`/`@enumFromInt` still compile in 0.17.1 but are **deprecated** in favour of `@backingInt`/`@fromBackingInt` (0.17 release notes; `zig fmt` upgrades them). The std code itself now uses `@fromBackingInt(@intCast(@backingInt(i)))` (Ast.zig:2925).

Packed flags ✅: `const Flags = packed struct(u8) { alive: bool = true, flying: bool = false, _pad: u6 = 0 };` gives `@sizeOf == 1`.

### 1.7 SIMD (`@Vector`)

```zig
const N = std.simd.suggestVectorLength(f32) orelse 4;   // 8 on this AVX2 box
const V = @Vector(N, f32);
var acc: V = @splat(0);
var i: usize = 0;
while (i + N <= data.len) : (i += N) {
    const v: V = data[i..][0..N].*;                     // slice → array → vector
    acc += v;
}
const total = @reduce(.Add, acc);
```
Also available: `@shuffle`, `@select`, comparisons that yield `@Vector(N, bool)`, vector↔array coercion, and `std.simd.{iota, repeat, join, interlace, deinterlace, firstTrue, …}`.

### 1.8 Random

```zig
var prng: std.Random.DefaultPrng = .init(42);    // Xoshiro256
const rand = prng.random();
_ = rand.intRangeLessThan(u32, 1, 100); _ = rand.float(f32); _ = rand.boolean();
var seed: u64 = undefined;
io.random(std.mem.asBytes(&seed));               // entropy now comes from Io (std.crypto.random removed)
// CSPRNG: try io.randomSecure(&bytes);
```

### 1.9 Concurrency (Io.async / Group / Mutex) ✅

```zig
fn sumChunk(xs: []const u64) u64 { var s: u64 = 0; for (xs) |x| s += x; return s; }
fn sumInto(xs: []const u64, out: *u64) void { out.* = sumChunk(xs); }

var fa = io.async(sumChunk, .{data[0..half]});   // Future(u64)
var fb = io.async(sumChunk, .{data[half..]});
const total = fa.await(io) + fb.await(io);

var partial: [4]u64 = undefined;
var group: Io.Group = .init;
for (&partial, 0..) |*p, i| group.async(io, sumInto, .{ data[i * chunk ..][0..chunk], p });
try group.await(io);                              // Cancelable!void

var mutex: Io.Mutex = .init;
try mutex.lock(io); mutex.unlock(io);
```
- `io.async` expresses *asynchrony* and may run the function inline. Use `io.concurrent(...)` (which can fail with `error.ConcurrencyUnavailable`) when you truly need parallel progress.
- `Future.cancel(io)` returns the function's result type. Kristoff's 2025 blog uses `defer f.cancel(io) catch {}`, which only works if the result is an error union.
- `std.Thread.Pool`, `std.Thread.Mutex/Condition/ResetEvent/WaitGroup/Semaphore/RwLock`, and `std.Thread.sleep` are gone, replaced by `std.Io.*` / `io.sleep`. `std.Thread.spawn` remains for raw threads.
- To write per-thread output without false sharing, give each task its own slot and pad slots to `std.atomic.cache_line` (SafeAllocator itself uses `_: void align(std.atomic.cache_line) = {}`).

### 1.10 Testing

```zig
test "MultiArrayList basics" {
    const gpa = std.testing.allocator;
    var l: std.MultiArrayList(struct { a: u8, b: u64 }) = .empty;
    defer l.deinit(gpa);
    try l.append(gpa, .{ .a = 1, .b = 2 });
    try std.testing.expectEqual(@as(u64, 2), l.items(.b)[0]);
    try std.testing.expectEqual(1, l.len);
}
test "io in tests" { const io = std.testing.io; _ = Io.Clock.awake.now(io); }
```
`zig test file.zig` prints `All N tests passed.`. Also available: `expectEqualSlices`, `expectApproxEqAbs/Rel`, `std.testing.fuzz(ctx, fn, .{})` with `*std.testing.Smith` (0.17 template), and `std.testing.io`.

### 1.11 Reflection is SoA now (a nice DOD anecdote for the book)

```zig
const info = @typeInfo(Monster).@"struct";
inline for (info.field_names, info.field_types) |name, T|
    std.debug.print("{s}: {s} ({d}B)\n", .{ name, @typeName(T), @sizeOf(T) });
```
In 0.17, `std.lang.Type.Struct` has `field_names`, `field_types`, `field_attrs` (parallel arrays) instead of `fields: []StructField`. The release notes title this "Struct-Of-Arrays Style for `std.lang.Type`". `std.meta.fields` is now a `@compileError("deprecated in favor of @typeInfo")`.

### 1.12 Optimize modes / build

- CLI: `zig run -O fast file.zig` (also `debug` default, `safe`, `small`). `zig run --help` lists only the lowercase names, but `-O ReleaseFast` was still accepted by 0.17.1 in my test.
- In code: `@import("builtin").mode` and `.optimize` both yield `std.lang.Optimize` = `.debug/.safe/.fast/.small`; `builtin.optimize.runtimeSafety()` gives a bool. **`builtin.mode == .ReleaseFast` fails**: `error: no field named 'ReleaseFast' in enum 'lang.Optimize'`.
- `std.builtin` is deprecated in favour of `std.lang` (the alias still works).
- build.zig (0.17 `zig init`): `b.standardOptimizeOption(.{})`, `b.addExecutable(.{ .name=…, .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }) })`. The template still suggests `-Doptimize=ReleaseFast` for `zig build`; `--release=fast` also works. 0.17 changes: `run_cmd.addPassthruArgs()` replaces `if (b.args) |args| run_cmd.addArgs(args)`, and `b.build_root` → `b.root`. (I did not run `zig build`. The first `zig build` builds the separate "maker" once and can take minutes. `zig init` sat for more than 90 s after writing its files.)
- Incremental: `zig build -fincremental --watch` (x86_64-linux usable in 0.17).

### 1.13 Format methods (0.15+)

```zig
const Point = struct {
    x: u8,
    pub fn format(p: Point, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("P({d})", .{p.x});
    }
};
std.debug.print("{f}\n", .{Point{ .x = 3 }});   // {f} calls format; {any} / {} print fields
```
Format specifiers to know: `{d}` numbers, `{s}` strings, `{any}` debug dump of anything (arrays print as `{ 1, 2, 3 }`), `{t}` enum/error tag name, `{f}` calls a format method, `{x}` hex, `{d:.2}` precision.

---

## 2. Pitfalls: old → new (errors captured from 0.17.1)

| Old idiom (≤0.15) | 0.17.1 error | Use instead |
|---|---|---|
| `std.io.getStdOut().writer()` | `root source file struct 'std' has no member named 'io'` | `Io.File.stdout().writer(io, &buf)` + `.interface` + `flush()` |
| `std.io.bufferedWriter(...)` | same (`no member named 'io'`) | the buffer *is* the writer: `.writer(io, &buf)` |
| `std.fs.File.stdout().writer(&buf)` (0.15 form) | `struct 'fs' has no member named 'File'` | `std.Io.File.stdout().writer(io, &buf)` |
| `std.fs.cwd()` | `struct 'fs' has no member named 'cwd'` | `std.Io.Dir.cwd()`; methods take `io` (`readFileAlloc(io, path, gpa, .unlimited)`) |
| `std.time.Timer.start()` | `struct 'time' has no member named 'Timer'` | `Io.Clock.awake.now(io)` … `.untilNow(io, .awake)` |
| `std.time.Instant.now()` | `no member named 'Instant'` | `Io.Timestamp` / `Io.Clock.now` |
| `std.time.nanoTimestamp()` / `milliTimestamp()` | `no member named 'nanoTimestamp'` | `Io.Clock.real.now(io)` (wall) / `.awake` (monotonic) |
| `std.heap.GeneralPurposeAllocator(.{}){}` | `struct 'heap' has no member named 'GeneralPurposeAllocator'` | `init.gpa` or `std.heap.SafeAllocator` |
| `std.heap.DebugAllocator(.{}) = .init` (0.14–0.16) | compiles, **deprecated** | `std.heap.SafeAllocator = .init(page_allocator, .{})` |
| `std.ArrayList(u32).init(gpa)` | `struct 'array_list.Aligned(u32,null)' has no member named 'init'` | `var l: std.ArrayList(u32) = .empty;` |
| `list.append(x)` | `member function expected 2 argument(s), found 1` | `list.append(gpa, x)`; `list.deinit(gpa)` |
| `list.writer()` | `no field or member function named 'writer'` | `std.Io.Writer.Allocating` or `list.print(gpa, …)` |
| `std.ArrayListUnmanaged(T)`, `.{}` init | compiles (deprecated alias / default init deprecated) | `std.ArrayList(T)` + `.empty` |
| `std.MultiArrayList(T){}` | compiles | prefer `= .empty` |
| `std.StaticBitSet(64).initEmpty()` | `struct 'bit_set.Integer(64)' has no member named 'initEmpty'` | `std.bit_set.Static(64) = .empty` |
| `std.crypto.random.int(u32)` | `struct 'crypto' has no member named 'random'` | `io.random(&bytes)` → seed a `DefaultPrng` |
| `std.Thread.Mutex` | `struct 'Thread' has no member named 'Mutex'` | `std.Io.Mutex = .init`, `lock(io)` |
| `std.Thread.sleep(ns)` | `no member named 'sleep'` | `io.sleep(.fromMilliseconds(1), .awake)` |
| `std.Thread.Pool` | removed (0.16) | `io.async` / `Io.Group.async` |
| `std.process.argsAlloc(a)` | `struct 'process' has no member named 'argsAlloc'` | `init.minimal.args.toSlice(arena)` / `.iterate()` |
| `@Type(.{ .int = … })` | `invalid builtin function: '@Type'` | `@Int(.unsigned, 7)`, `@Struct`, `@Union`, `@Enum`, `@Pointer`, `@Fn`, `@Tuple`, `@EnumLiteral` |
| `@typeInfo(S).Struct` | `no field named 'Struct' in union 'lang.Type'` | `@typeInfo(S).@"struct"` |
| `@typeInfo(S).@"struct".fields` (0.14–0.16) | `no field named 'fields' in struct 'lang.Type.Struct'` | `.field_names`, `.field_types`, `.field_attrs` |
| `@typeInfo(F).@"fn".params` | `no field named 'params' in struct 'lang.Type.Fn'` | `.param_types` |
| `std.meta.fields(S)` | `error: deprecated in favor of @typeInfo` | `@typeInfo(S).@"struct".field_names` |
| `builtin.mode == .ReleaseFast` | `no field named 'ReleaseFast' in enum 'lang.Optimize'` | `== .fast` |
| `@intFromEnum` / `@enumFromInt` | compiles, deprecated (0.17) | `@backingInt` / `@fromBackingInt` |
| `@intCast(u8, x)` (≤0.10) | `expected 1 argument, found 2` | `const y: u8 = @intCast(x);` |
| `usingnamespace` | parse error `expected ',' after field` | explicit namespacing / zero-bit field mixins |
| `async f()` / `await` | parse error `expected ';' after statement` | `io.async(f, .{})` / `future.await(io)` |
| `[_]u8{0} ** 4` | `binary operator '*' has whitespace on one side…` (`**` removed, 0.17) | `@splat(0)` with a result type: `const a: [4]u8 = @splat(0);` |
| `errdefer \|err\| …` | `expected block or expression, found '\|'` | removed in 0.17 |
| `void{}` | `type 'void' does not support array initialization syntax` | `{}` |
| `std.fmt.FormatOptions` / old `format(self, comptime f, opts, writer: anytype)` | `struct 'fmt' has no member named 'FormatOptions'` | `pub fn format(self, w: *std.Io.Writer) std.Io.Writer.Error!void` + `{f}` |
| `std.fmt.allocPrint` / `bufPrint` | compile, deprecated (0.17) | `gpa.print(...)` / `std.mem.print(buf, ...)` |
| `gpa.dupeZ(u8, s)` | `no field or member function named 'dupeZ' in 'mem.Allocator'` | `gpa.dupeSentinel(u8, s, 0)` |
| `std.zig.Ast.parse(gpa, src, .zig)` | `struct 'zig.Ast.ParseOptions' has no member named 'zig'` | `Ast.parse(gpa, src, .{})` |
| `std.Io.File.stdout().writeAll(io, s)` | `no … member function named 'writeAll' in 'Io.File'` | `writeStreamingAll(io, s)` or use a Writer |

**Silent pitfall:** printing a struct with `{}` now dumps its fields (`.{ .x = 1 }`) and does **not** call a custom `format` method; you need `{f}`. An old-signature `format` method is silently ignored under `{}`.
**Debug-mode pitfall for benchmarks:** always benchmark with `-O fast`. The SoA loop below runs 6.3 ms in debug and 1.2 ms in fast.

---

## 3. Verified complete programs

### 3.1 `soa.zig`: MultiArrayList + timer + buffered stdout ✅
```zig
const std = @import("std");
const Io = std.Io;

const Monster = struct { hp: u32, x: f32, y: f32, alive: bool };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var prng: std.Random.DefaultPrng = .init(42);
    const rand = prng.random();

    var monsters: std.MultiArrayList(Monster) = .empty;
    defer monsters.deinit(gpa);

    const n = 1_000_000;
    try monsters.ensureTotalCapacity(gpa, n);
    for (0..n) |_| {
        monsters.appendAssumeCapacity(.{
            .hp = rand.intRangeLessThan(u32, 1, 100),
            .x = rand.float(f32),
            .y = rand.float(f32),
            .alive = rand.boolean(),
        });
    }

    const start = Io.Clock.awake.now(io);
    const s = monsters.slice();
    for (s.items(.x), s.items(.y)) |*x, y| x.* += y * 0.016;
    var total_hp: u64 = 0;
    for (s.items(.hp)) |hp| total_hp += hp;
    std.mem.doNotOptimizeAway(total_hp);
    const elapsed = start.untilNow(io, .awake);

    try stdout.print("n={d} total_hp={d} elapsed={d}ns ({f})\n", .{ n, total_hp, elapsed.toNanoseconds(), elapsed });
    try stdout.print("sizeOf(Monster)={d} SoA bytes/elem={d}\n", .{
        @sizeOf(Monster), std.MultiArrayList(Monster).capacityInBytes(1),
    });
    try stdout.print("first: {any}\n", .{monsters.get(0)});
    try stdout.flush();
}
```
Output (`zig run -O fast soa.zig`):
```
n=1000000 total_hp=49977099 elapsed=1217609ns (1.217ms)
sizeOf(Monster)=16 SoA bytes/elem=13
first: .{ .hp = 27, .x = 0.4775288, .y = 0.6442497, .alive = false }
```

### 3.2 `bench.zig`: AoS vs SoA hot/cold split, measured ✅
```zig
const std = @import("std");
const Io = std.Io;

const Entity = struct {
    pos: [3]f32,
    vel: [3]f32,
    name: [32]u8, // cold
    health: u32,  // cold
    flags: u32,   // cold
};

fn nowNs(io: Io) i96 { return Io.Clock.awake.now(io).nanoseconds; }

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const n = 4_000_000;
    const iters = 20;

    var buf: [512]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;

    const aos = try gpa.alloc(Entity, n);
    defer gpa.free(aos);
    var soa: std.MultiArrayList(Entity) = .empty;
    defer soa.deinit(gpa);
    try soa.resize(gpa, n);
    for (aos, 0..) |*e, i| {
        const f: f32 = @floatFromInt(i);
        e.* = .{ .pos = .{ f, f, f }, .vel = .{ 1, 2, 3 }, .name = @splat(0), .health = 100, .flags = 0 };
        soa.set(i, e.*);
    }

    var t = nowNs(io);
    for (0..iters) |_| {
        for (aos) |*e| for (&e.pos, e.vel) |*p, v| {
            p.* += v * 0.016;
        };
        std.mem.doNotOptimizeAway(aos.ptr);
    }
    const aos_ns = nowNs(io) - t;

    const s = soa.slice();
    t = nowNs(io);
    for (0..iters) |_| {
        for (s.items(.pos), s.items(.vel)) |*p, v| for (p, v) |*pc, vc| {
            pc.* += vc * 0.016;
        };
        std.mem.doNotOptimizeAway(s.items(.pos).ptr);
    }
    const soa_ns = nowNs(io) - t;

    try out.print("sizeOf(Entity)={d}B  AoS {d:.2} ms/iter  SoA {d:.2} ms/iter  speedup {d:.2}x\n", .{
        @sizeOf(Entity),
        @as(f64, @floatFromInt(aos_ns)) / iters / 1e6,
        @as(f64, @floatFromInt(soa_ns)) / iters / 1e6,
        @as(f64, @floatFromInt(aos_ns)) / @as(f64, @floatFromInt(soa_ns)),
    });
    try out.flush();
}
```
Result (`-O fast`, one run, 4-core Xeon 2.6 GHz in an orb, so treat it as illustrative only):
`sizeOf(Entity)=64B  AoS 25.83 ms/iter  SoA 8.61 ms/iter  speedup 3.00x`
Rough math: the loop needs 24 B/entity of hot data, AoS drags a 64 B cache line per entity, and 64/24 ≈ 2.7, which matches the 3× measured.

### 3.3 `misc.zig`: ArrayList, fixed list, arena, hash maps, bit sets, SIMD, random, enum index ✅
Its sections all appear in §1.3–1.8. Output:
```
debug.print still works: 42
list={ 1, 2, 3, 4 } len=4 cap>=33
fixed=hi
arena sum=24
map[7]=1.5
amap keys={ 1 }
bits count=2
dbits count=1
vec reduce=72 suggest f32 len=8
id=5 backing=5
dt ns=482
mode=debug
```
(The `debug.print` line comes first because stdout was flushed by `defer` at the end of main.)

### 3.4 `dod_idioms.zig` (zig test, 6/6 passed) ✅
It covers comptime size asserts, typed index, packed flags, `MultiArrayList` of a tagged union, out-of-band bools via `bit_set.Dynamic`, SoA sort by key column, and SIMD sum. Key output:
`Fat(auto)=16 FatExtern=24 WithBool=24 Flags=1 Shape=12`

**Book-worthy nuance:** Kelley's padding quiz (`u32, u64, u32` → 24 B) holds for C/`extern` layout. A **plain Zig `struct` has unspecified layout, and the compiler reorders fields**, so `struct { a: u32, b: u64, c: u32 }` is 16 B. Use `extern struct` to demonstrate padding, and `comptime { assert(@sizeOf(T) == N); }` to pin sizes (the Zig compiler does exactly this, e.g. `Air.zig:1371` `assert(@sizeOf(Data) == 8)`, `Ast.zig:2980-2983`).

### 3.5 `par.zig`: io.async, Group, Mutex, sleep, `{f}` ✅
See §1.9. Output: `total=549755289600 total2=549755289600 P(3)`.

### 3.6 `astsz.zig`: measure the real Zig AST (ground truth for the talk's numbers) ✅
```zig
const std = @import("std");
const Ast = std.zig.Ast;
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const src = try std.Io.Dir.cwd().readFileAlloc(init.io, "~/langsrc/zig/lib/std/multi_array_list.zig", gpa, .unlimited);
    defer gpa.free(src);
    const srcz = try gpa.dupeSentinel(u8, src, 0);
    defer gpa.free(srcz);
    var tree = try Ast.parse(gpa, srcz, .{});
    defer tree.deinit(gpa);
    std.debug.print("Token={d}+{d}B Node.Tag={d} Node.Data={d} Node(AoS)={d}\n", .{
        @sizeOf(std.zig.Token.Tag), @sizeOf(Ast.ByteOffset), @sizeOf(Ast.Node.Tag), @sizeOf(Ast.Node.Data), @sizeOf(Ast.Node) });
    std.debug.print("source={d}B tokens={d} nodes={d} extra_data={d} u32s\n", .{ src.len, tree.tokens.len, tree.nodes.len, tree.extra_data.len });
}
```
Output: `Token=1+4B Node.Tag=1 Node.Data=8 Node(AoS)=16` / `source=47143B tokens=9387 nodes=4515 extra_data=2053 u32s`
- So a Zig token is **5 bytes** in SoA (tag u8 + start u32), confirming Kelley's "64 → 5 bytes". An AST node is 1+4+8 = **13 B in SoA vs 16 B as an AoS struct**.
- A 47 KB source file → 46.9 KB of tokens + 58.7 KB of nodes + 8.2 KB of extra, so the whole AST is ≈ 2.4× the source size.
- For contrast, `std.zig.Token` from the tokenizer (`tag` + `Loc{start: usize, end: usize}`) is 24 B. It is the transient tokenizer output, and the `end` is recomputed by re-tokenizing instead of being stored ("calculate instead of store").

---

## 4. DOD content facts, with numbers

### 4.1 Andrew Kelley: "A Practical Guide to Applying Data-Oriented Design" (Handmade Seattle, 23 Nov 2021)
- Framing: he "picks up where Mike Acton left off". He prepared by attending Handmade Seattle three times and reading Richard Fabian's *Data-Oriented Design* book.
- Thesis: "CPU is fast, memory is slow." Each cache level is roughly an order of magnitude slower. Cache line ≈ 64 B ("could be 32, could be 128"). His recipe: *"Think about a struct that you have the most of in memory and think about how you can make it smaller. That's the whole trick."*
- Alignment quiz: u32 → align 4/size 4; bool → 1/1; `union{u32,bool}` → 4/4 (bare); `struct{u32,bool}` → align 4, size 8; `struct{u32,u64,u32}` → align 8, size 24. Adding a bool to a 16 B struct makes it 24 B: "We paid the cost of 64 bits just to add one [bit]".
- Strategies, in order: (1) **indexes instead of pointers**: a struct with pointers is 32 B → 16 B, and alignment drops 8 → 4; (2) **store booleans out-of-band** (which list an item is in *is* the bool): 24 B → 16 B, → 12 B combined with indexes (100 monsters: 2.4 KB → 1.2 KB); (3) **struct-of-arrays to eliminate padding** ("a five-character fix, same API", i.e. `ArrayList` → `MultiArrayList`): 10,000 monsters 160 KB → 91 KB; (4) **sparse data in hash maps** (only 10% of monsters hold items): 366 KB → 198 KB for 10k monsters including capacity overhead; (5) **encodings instead of polymorphism**: tagged-union monster 32 B → OOP-ish 24 B → encoding ≈ 17 B/monster average.
- Zig compiler results: **tokens 64 B → 5 B**; **AST nodes 120 B → 15.6 B average**, which gave **22% wall-clock improvement** for parsing; **ZIR instructions 54.0 B → 20.3 B average**, which gave a further **39% wall-clock reduction**. A RAM-site summary also cites a ~15% reduction in cache misses (I could not confirm that number from the transcript).
- Q&A: 32-bit ops are as fast as 64-bit on 64-bit CPUs.
- Closing summary quote: "Add CPU cache to your mental model of computers… Identify where you have a lot of the same thing in memory and make the size of each thing smaller."

### 4.2 The Zig compiler as a DOD case study (local source, 0.17.1)
- **Ast** (`lib/std/zig/Ast.zig`): `tokens: TokenList.Slice` (MultiArrayList{tag: Token.Tag u8, start: u32}), `nodes: NodeList.Slice` (MultiArrayList{tag u8, main_token u32, data 8-byte union}), `extra_data: []u32`, `source: [:0]const u8`. `Node.Index` is `enum(u32) { root = 0, _ }` (typed index). Node data is either inline (two u32s, or `lhs/rhs`) or an index into `extra_data` where a tag-specific struct is laid out as consecutive u32s. Mitchell Hashimoto: "lhs/rhs may point to either nodes or extra data."
- **Zir** (`lib/std/zig/Zir.zig`): `instructions: std.MultiArrayList(Inst).Slice`, `string_bytes: []u8`, `extra: []u32`. "The minimum amount of information needed to represent a list of ZIR instructions… without any memory access into the AST tree token list, node list, or source bytes." `Inst = struct { tag: Tag, data: Data }` with `assert(@sizeOf(Data) == 8)` (Zir.zig:2526). One ZIR per file, and it can be serialized straight to the cache.
- **Air** (`src/Air.zig`): "Unlike ZIR where there is one instance for an entire source file, each function gets its own `Air` instance." `instructions: std.MultiArrayList(Inst).Slice`, `extra: std.ArrayList(u32)`; `Inst = { tag: Tag(enum u8), data: Data }` with `assert(@sizeOf(Data) == 8)` in non-safety builds (Air.zig:1371; safety builds add a hidden tag).
- **InternPool** (`src/InternPool.zig`): "All interned objects have both a value and a type. This data structure is self-contained." `Item = struct { tag: Tag, data: u32 }`, where data is an inline value or an index into `extra`. `Index = enum(u32)`, and "Two values which have the same type can be equality compared simply by checking if their indexes are equal." Types and values share one pool. Since 2024 it is sharded per thread (Local/Shard). Kelley's commit message: "an extremely efficient encoding of types and values, represented only by three arrays, which has no pointers, and can therefore be serialized and deserialized by a single writev/readv call." mlugg on Ziggit: "most things are stored as a handful of u32 in a monolithic array – this is a common technique in modern DOD-style Zig code."
- Recurring pattern for the book (Zig "tag + data + extra"): `MultiArrayList(struct { tag: enum(u8), data: union(8 B) })` + `extra: []u32` + `string_bytes: []u8`, with all cross-references as `enum(u32)` indices and comptime size assertions.

### 4.3 TigerBeetle / TigerStyle
- "All memory must be statically allocated at startup. **No memory may be dynamically allocated (or freed and reallocated) after initialization.**" This avoids unpredictable performance and use-after-free, and "makes for more efficient, simpler designs".
- "Put a limit on everything." "Use explicitly-sized types like `u32` for everything, avoid architecture-specific `usize`." Assertion density of at least 2 per function. "Assert the relationships of compile-time constants… or type sizes." 70-line function limit.
- Performance section: "The lack of back-of-the-envelope performance sketches is the root of all evil." "The best time to solve performance, to get the huge 1000x wins, is in the design phase." Sketch the four resources (network, disk, memory, CPU) × (bandwidth, latency). "A memory cache miss may be as expensive as a disk fsync, if it happens many times more." "Let the CPU be a sprinter doing the 100m… Give the CPU large enough chunks of work. This comes back to batching." Extract hot loops into standalone functions with primitive arguments and no `self`. Push `if`s up and `for`s down (matklad).
- ARCHITECTURE.md: at startup, for every object type, compute the worst-case count from CLI args, allocate exactly that, then never allocate. That is "different from truly static allocation of some embedded systems" and "different from arena allocation". "Static allocation is a forcing function to ensure that everything has a limit." `src/static_allocator.zig` is an allocator wrapper with states `init → static → deinit` that asserts if you allocate after startup (a nice Zig code exhibit).
- Phil Eaton (2022): Zig's std data structures are "static allocation friendly" (ArrayList/HashMap with fixed capacity, i.e. `initCapacity` + `*AssumeCapacity`/`*Bounded`).

### 4.4 matklad (Alex Kladov)
- "Newtype Index Pattern In Zig" (2025-12-23): indexes over pointers. "Typically a 32-bit index is enough, a saving of four bytes per pointer on 64-bit." Use `const ItemIndex = enum(u32) { _ };` for type safety, a "happy accident of language design" popularized by @andrewrk. Comptime-assert sizes.
- "Static Allocation For Compilers" (2025-12-23), "Static Allocation, Constant Work" (2026-09-02): pool + `DynamicBitSet` free-list example (`OrderPool { orders: []Order, free: DynamicBitSet }`); "constant work" means P100 latency stays flat regardless of load.
- "Reserve First" (2025-08-16): reserve all capacity, then mutate in an error-free path, marked with `errdefer comptime unreachable;`.
- "Zig And Rust" (2023): "Zig is a DSL for emitting machine code" (attributed to Kelley); collections take an allocator per call rather than being parameterized by one.
- "Data Oriented Parallel Value Interner" (2023): interning trees like the Zig compiler's Value with lazily-allocated segments.

### 4.5 Ghostty (Mitchell Hashimoto)
- Devlog 006 (2024-02-12): SIMD for control-sequence scanning plus UTF-8 decoding. ASCII **7.3×** faster than scalar (≈ memcpy speed), and UTF-8→UTF-32 decode **16.6×** faster (M3 Max). Codepoint width was 30% of per-char time, and a precomputed 3-stage lookup table made it 2.8× faster for ASCII and ~5× for random UTF-8. The grapheme-break table is under 1 KB, nearly 8× faster, only 27% slower than reading the bytes. `cat` of a 5.4 MB Japanese file: 189 ms → 73 ms.
- "Finding and Fixing Ghostty's Largest Memory Leak" (2026-01-10): `PageList` is a doubly linked list of page-aligned, page-multiple-sized contiguous blocks, with a pool of standard-size pages and oversize pages mmapped directly.
- X post (2026): scrollback compression gives 70–90% less resident memory, possible *because* pages are page-aligned blocks (`madvise` discards them). This is data layout chosen up front paying off two years later.
- His Zig compiler internals series (2022: tokenizer, parser, AstGen, Sema) has clear diagrams of MultiArrayList and extra_data. Note it shows pre-2024 `Node.Data{lhs, rhs}` and `Index = u32`; current code uses enums and unions.

### 4.6 Zig release-notes facts useful for prose
- 0.15.1 (2025-08-19): self-hosted x86_64 backend is the default in Debug, with ~5× faster compilation than LLVM. Writergate: `std.Io.Writer/Reader` are "non-generic and have the buffer above the vtable — the buffer is in the interface, not the implementation", "still transparent to optimization; all of the interface functions have a concrete hot path operating on the buffer, and only make vtable calls when the buffer is full." Kelley: "These changes are extremely breaking. I am sorry for that." On ArrayList: "Having an extra field is more complicated than not having an extra field, so not having it is the null hypothesis." Downsides of managed lists include "extra memory storage cost, particularly for nested containers" (a DOD argument!). BoundedArray was removed with the advice "Don't guess… Accept a buffer as a slice."
- 0.16.0 (2026-04-13): I/O as an Interface: "anything that potentially blocks control flow or introduces nondeterminism is grounds for being owned by the I/O interface." `Io.Threaded` is feature-complete and `Io.Evented` is experimental (M:N green threads). ArenaAllocator became thread-safe and lock-free. Juicy Main arrived. `@Type` was split into `@Int/@Struct/...`. `Thread.Pool` was removed. `std.time.Timer/Instant` became `std.Io.Timestamp`. "Lazy Field Analysis".
- 0.17.0 (2026-10-01/02, 925 commits, 206 contributors per a secondary source): `@backingInt/@fromBackingInt`; `**` and `errdefer |err|` removed; SoA-style `@typeInfo`; `Optimize` renamed; `SafeAllocator` (a Chinese-language report says std tests built with -Osafe went 29.4 s → 22.1 s wall with the new allocator; I did not verify this against the primary source); `BufferFirstAllocator`; `bit_set` renames; usable incremental compilation; build system split into configurer + maker.

---

## 5. Quotes (verbatim from sources I read)
- Kelley: "Think about a struct that you have the most of in memory and think about how you can make it smaller. That's the whole trick."
- Kelley: "Even though 64-bit computers can have more RAM, by default, they actually also use more RAM."
- Kelley: "We paid the cost of 64 bits just to add one to the struct." (the bool-padding moment)
- Kelley (on MultiArrayList): "that's a five-character fix, same API."
- Kelley: "Add CPU cache to your mental model of computers."
- TigerStyle: "The lack of back-of-the-envelope performance sketches is the root of all evil."
- TigerStyle: "Let the CPU be a sprinter doing the 100m. Be predictable. Don't force the CPU to zig zag and change lanes."
- TigerBeetle ARCHITECTURE: "static allocation is a forcing function to ensure that everything has a limit."
- 0.15 notes: "the buffer is in the interface, not the implementation."
- Zir.zig doc comment: "The minimum amount of information needed to represent a list of ZIR instructions."
- InternPool.zig: "All interned objects have both a value and a type. This data structure is self-contained."
- matklad: "In efficiency-minded code, it is idiomatic to use indexes rather than pointers."
- Ghostty devlog: "compilers are notoriously bad at autovectorization."

## 6. Visualization ideas
1. **Padding explorer**: field boxes for `extern struct {u32,u64,u32}` (24 B with grey padding) vs Zig auto-layout (16 B, reordered) vs SoA columns. Toggle "add bool" to see 16 → 24.
2. **Kelley's shrink ladder**: a step chart of bytes per monster, 32 → 16 (indices) → 12 (out-of-band bool), and a KB-for-10k-monsters bar chart (160 → 91 KB SoA; 366 → 198 KB sparse hash map).
3. **Zig compiler before/after**: bar pairs for token 64 → 5 B, AST node 120 → 15.6 B, ZIR 54 → 20.3 B, annotated with −22% and −39% wall clock.
4. **MultiArrayList memory map**: one allocation, columns sorted by alignment (u64 col | u32 cols | u8 cols), with `items(.x)` pointers into it. Contrast with the AoS strided access pattern that pulls 64 B lines for 24 B of hot data (§3.2: 3.0× measured).
5. **Tag + data + extra diagram**: a `fn_proto` node whose `data.lhs` points into `extra_data[lhs..lhs+6]`, whose entries point back to nodes and tokens (`main_token + 1` = identifier). Three arrays, arrows as u32 indices.
6. **InternPool**: `Index(u32)` → `items[tag,data]` → `extra[]`; equality = integer compare. Show the same `u8` type interned once.
7. **Static allocation lifecycle** (TigerBeetle StaticAllocator): state machine init → static → deinit with the "alloc ⇒ assert" edge.
8. **Io-as-parameter diagram**: `main(init)` handing `gpa` and `io` down the call tree, the same way an Allocator is passed (a "capabilities passed explicitly" theme shared by allocator and io).
9. **Interactive cache-line calculator**: N entities × hot bytes vs struct size → lines touched → predicted ratio (64/24 ≈ 2.7 vs measured 3.0×).

---

## 7. SOURCES (only ones actually read or seen in this session)

| URL | Title | Author | Year | Note |
|---|---|---|---|---|
| https://josherich.me/podcast/andrew-kelley-practical-data-oriented-design-dod | Andrew Kelley Practical Data Oriented Design (DoD) [transcript] | Andrew Kelley (talk), transcribed by Josherich | 2021 talk / transcript n.d. | Primary source for all talk numbers (64→5, 120→15.6, 54→20.3, 22%, 39%, monster examples) |
| https://community.tmpdir.org/t/a-practical-guide-to-applying-data-oriented-design/560 | A Practical Guide to Applying Data-Oriented Design (notes) | cbrake | 2022 | Bullet summary of strategies; links media.handmade-seattle.com page dated 23 Nov 21 |
| https://randomaccessmemory.cc/t/andrew-kelley-a-practical-guide-to-applying-data-o | Andrew Kelley: A Practical Guide to Applying DoD | RAM (summary of YouTube upload) | 2024 | Secondary summary; cites ~15% cache-miss reduction (unverified) |
| https://tildes.net/~comp/zch/a_practical_guide_to_applying_data_oriented_design | A practical guide to applying data-oriented design | Apos | 2021 | Confirms publish date 23 Nov 2021, media.handmade-seattle.com URL |
| https://raymondtana.github.io/math/programming/2026/01/23/zig-alignment-and-sizing.html | Memory Layout in Zig with Formulas | Raymond Tana | 2026 | Notes Zig auto-reorders struct fields (seen in search excerpt) |
| https://tweedegolf.nl/en/blog/88/data-oriented-design/ | Optimizing a parser/compiler with data-oriented design: a case study | Folkert de Vries (Tweede golf / Roc) | 2022 | Roc compiler applying Kelley's ideas; vimeo link to talk (vimeo.com/649009599) |
| https://ziglang.org/download/0.15.1/release-notes.html | 0.15.1 Release Notes | Zig Software Foundation | 2025 | Writergate, ArrayList unmanaged, usingnamespace/async removal, x86 backend 5× |
| https://ziglang.org/download/0.16.0/release-notes.html | 0.16.0 Release Notes | ZSF | 2026 | I/O as an Interface, Juicy Main, @Type split, Thread.Pool removed, time → Io.Timestamp, arena lock-free |
| https://ziglang.org/download/0.17.0/release-notes.html | 0.17.0 Release Notes | ZSF | 2026 | @backingInt, Optimize rename, SoA @typeInfo, bit_set renames, SafeAllocator, BufferFirstAllocator, `**` removed |
| https://ziglang.org/ja-JP/download/ | Download page (ja) | ZSF | 2026 | Release dates: 0.15.1 2025-08-19, 0.16.0 2026-04-13, 0.17.0 2026-10-01 |
| https://course.ziglang.cc/update/upgrade-0.17.0 | Zig 语言圣经: upgrade to 0.17.0 | Zig 语言圣经 community | 2026 | DebugAllocator→SafeAllocator migration snippet, allocPrint→gpa.print |
| https://linlog.top/article/1541 | Zig 0.17.0 发布 | Lin Blog | 2026 | 925 commits / 206 contributors; SafeAllocator 29.4 s→22.1 s claim (secondary) |
| https://www.ziglang.in/learn/getting-started/zig-0-17/ | Zig 0.17: What Changed Since 0.16 | Zig Guide Live | 2026 | Old/new table (seen in search excerpt only) |
| https://native-sdk.dev/zig | Zig 0.16 Notes | Native SDK | 2026 | Error→fix index for 0.16 migration (excerpt) |
| https://standard-reader.app/a/did:plc:xbtmt2zjwlrfegqvch7fboei/languages-ziglang-versions-migration-0.16 | 0.16 migration notes | nate (@zzstoatzz.io) | 2026 | io.random vs io.randomSecure; ArrayList `.empty` |
| https://kristoff.it/blog/zig-new-async-io/ | Zig's New Async I/O | Loris Cro | 2025 | Io passed like Allocator; io.async/await; "defeated function coloring"; devirtualization note |
| https://mitchellh.com/zig/parser | Zig Parser | Mitchell Hashimoto | 2022 | MultiArrayList diagrams, extra_data, main_token, lhs/rhs; Tree example 37.5% saving |
| https://mitchellh.com/zig/astgen | Zig AstGen: AST => ZIR | Mitchell Hashimoto | 2022 | ZIR Inst tag+data, extra (search excerpt) |
| https://mitchellh.com/zig/sema | Zig Sema: ZIR => AIR | Mitchell Hashimoto | 2022 | AIR = MultiArrayList(Inst).Slice + extra (search excerpt) |
| https://mitchellh.com/writing/ghostty-devlog-006 | Ghostty Devlog 006 | Mitchell Hashimoto | 2024 | SIMD 7.3× / 16.6×, lookup tables, cat benchmarks |
| https://mitchellh.com/writing/ghostty-memory-leak-fix | Finding and Fixing Ghostty's Largest Memory Leak | Mitchell Hashimoto | 2026 | PageList: page-aligned blocks, pool, mmap for oversize (excerpt) |
| https://x.com/mitchellh/status/2075284760583418284 | Ghostty scrollback compression post | Mitchell Hashimoto | 2026 | 70–90% less RSS thanks to page-aligned PageList (excerpt) |
| https://mitchellh.com/writing/ghostty-and-useful-zig-patterns | Talk: Introducing Ghostty and Some Useful Zig Patterns | Mitchell Hashimoto | 2023 | comptime data tables (excerpt) |
| https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md | TigerStyle | TigerBeetle | living doc | Static allocation, limits, u32 over usize, napkin math, batching quotes |
| https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md | TigerBeetle Architecture | TigerBeetle | living doc | Precise meaning of "static allocation" (excerpt) |
| https://github.com/tigerbeetle/tigerbeetle/blob/main/src/static_allocator.zig | static_allocator.zig | TigerBeetle | living | init→static→deinit allocator (excerpt) |
| https://tigerbeetle.com/blog/a-database-without-dynamic-memory | A Database Without Dynamic Memory Allocation | Phil Eaton | 2022 | Std containers "static allocation friendly" |
| https://matklad.github.io/2025/12/23/zig-newtype-index-pattern.html | Newtype Index Pattern In Zig | Alex Kladov | 2025 | `enum(u32) { _ }` index pattern (excerpt) |
| https://matklad.github.io/2025/12/23/static-allocation-compilers.html | Static Allocation For Compilers | Alex Kladov | 2025 | Static allocation beyond databases (excerpt) |
| https://matklad.github.io/2026/09/02/static-allocation-constant-work.html | Static Allocation, Constant Work | Alex Kladov | 2026 | Pool + DynamicBitSet; constant work → flat P100 (excerpt) |
| https://matklad.github.io/2025/08/16/reserve-first.html | Reserve First | Alex Kladov | 2025 | `errdefer comptime unreachable` reservation idiom (excerpt) |
| https://matklad.github.io/2023/03/26/zig-and-rust.html | Zig And Rust | Alex Kladov | 2023 | "DSL for emitting machine code" (excerpt) |
| https://matklad.github.io/2023/04/23/data-oriented-parallel-value-interner.html | Data Oriented Parallel Value Interner | Alex Kladov | 2023 | Interning Zig-compiler-like values (excerpt) |
| https://ziggit.dev/t/comptime-garbage-collection/2736/3 | Comptime Garbage Collection (#3) | mlugg (Matthew Lugg) | 2024 | InternPool "handful of u32 in a monolithic array" |
| https://upd.dev/oven-sh/zig/commits/branch/bun/src/InternPool.zig | InternPool.zig history (mirror) | Andrew Kelley et al. | 2022–23 | Commit msgs: "three arrays, no pointers, single writev/readv"; Zir.Inst.Index made enum |
| https://readoss.com/en/ziglang/zig/semantic-analysis-and-the-internpool-heart-of-the-compiler | Semantic Analysis and the InternPool | Read OSS | n.d. | Types and values both u32 indices (excerpt) |
| https://andreashohmann.com/zig-struct-of-arrays | Zig structs of arrays | Andreas Hohmann | 2024 | MultiArrayList via comptime; 2400 B → 1700 B token example (excerpt) |
| local: ~/langsrc/zig/lib/std/{process.zig,start.zig,Io.zig,Io/File.zig,multi_array_list.zig,array_list.zig,heap.zig,heap/SafeAllocator.zig,bit_set.zig,hash_map.zig,array_hash_map.zig,Random.zig,testing.zig,simd.zig,lang.zig,zig/Ast.zig,zig/Zir.zig}, src/{Air.zig,InternPool.zig}, doc/langref.html.in, doc/langref/*.zig | Zig 0.17.1 source | ZSF | 2026 | Ground truth for every API in §1–3 |

Could not load: https://media.handmade-seattle.com/practical-data-oriented-design/ (connection error). The talk date and title come from the tmpdir, tildes and Tweede golf citations of that page.

## 8. Assumptions and caveats
- The benchmark numbers (§3.2, §3.1) come from single runs on a shared 4-vCPU cloud VM. Use them as illustrations; re-measure on the book's reference machine.
- `zig build`/build.zig was not executed. The build.zig notes come from the `zig init` output files and the 0.17 release notes.
- `-O ReleaseFast` was still accepted on the CLI in 0.17.1, but the book should use `-O fast` (the only spelling in `--help`).
- I could not confirm the ~15% cache-miss figure for Kelley's talk from the transcript; it appears only in a secondary summary.

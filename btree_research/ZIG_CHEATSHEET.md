# Zig 0.17.1 cheat sheet (verified) + Rust conventions

Everything here was compiled and run with `zig version` = **0.17.1**
(`/opt/zigdl/zig-x86_64-linux-0.17.1`, std source in `lib/std`, language reference in `doc/langref.html`)
and rustc/cargo **1.97.0**. Every Zig code block below is an exact copy of a file in
`_template/zig/` and is exercised by `cd _template/zig && zig build test` (97 pass, 2 skipped:
`c_allocator` needs libc, `brk_allocator` needs `-fsingle-threaded`; both were also run with those flags).

**Your training data is older Zig (0.11-0.14). Do not trust memory for std APIs.** When unsure:
`grep -n "pub fn" /opt/zigdl/zig-x86_64-linux-0.17.1/lib/std/<file>.zig`, then compile.

Start a new chapter by copying `_template/zig` (and `_template/rust`), then rename `btree_template`
in `build.zig`, `build.zig.zon` (the fingerprint must be regenerated: delete the line, run
`zig build`, paste the suggested value) and `src/main.zig`.

## 0. The 25 things that will bite you (old idiom -> 0.17.1)

| Old (0.11-0.14) | 0.17.1 |
|---|---|
| `pub fn main() !void` + `std.process.argsAlloc`, `std.heap.GeneralPurposeAllocator` | `pub fn main(init: std.process.Init) !void` gives `init.gpa`, `init.arena`, `init.io`, `init.minimal.args`, `init.environ_map` |
| `std.io.getStdOut().writer()`, `std.io.bufferedWriter` (`std.io` does not exist) | `var fw: std.Io.File.Writer = .init(.stdout(), io, &buf); const w = &fw.interface; ... try w.flush();` |
| `std.fs.cwd()`, `std.fs.File`, `file.pread/pwriteAll/seekTo/getEndPos`, `file.close()` | `std.Io.Dir.cwd()`, `std.Io.File`; every call takes `io`: `file.readPositionalAll(io, buf, off)`, `file.writePositionalAll(io, bytes, off)`, `file.length(io)`, `file.sync(io)`, `file.close(io)` |
| `writer: anytype`, `std.io.AnyWriter`, `fixedBufferStream` | concrete `*std.Io.Writer` / `*std.Io.Reader`; `.fixed(&buf)`; `std.Io.Writer.Allocating` |
| `pub fn format(self, comptime fmt, options, writer: anytype)` | `pub fn format(self: T, w: *std.Io.Writer) std.Io.Writer.Error!void`, printed with `{f}` |
| `{}` on a slice/string, `{s}` on an enum | slices need `{s}`/`{any}`/`{x}`; enum/error name is `{t}`; `{}` still fine for ints/bools |
| `std.ArrayList(T).init(gpa)`, `list.append(x)`, `list.deinit()` | `var list: std.ArrayList(T) = .empty;` `try list.append(gpa, x);` `list.deinit(gpa);` (`pop()` returns `?T`) |
| `std.BoundedArray`, `std.SegmentedList` | removed: `ArrayList.initBuffer(&buf)` + `appendBounded`, or array + len; chunk list by hand |
| `std.DoublyLinkedList(T)` | non-generic intrusive `std.DoublyLinkedList` + `Node` field + `@fieldParentPtr("field", node)` |
| `std.PriorityQueue(T, C, f).init(gpa, ctx)`, `add`, `remove` | `.empty` / `.initContext(ctx)`, `push(gpa, x)`, `pop()` (`?T`), `deinit(gpa)` |
| `std.heap.GeneralPurposeAllocator(.{}){}` | `std.heap.SafeAllocator` (`.init(backing, .{})`, `deinit()` returns leak count); `DebugAllocator` deprecated |
| `std.heap.stackFallback(N, a)` | `std.heap.BufferFirstAllocator.init(&buf, fallback)` |
| `std.heap.MemoryPool(T).init(gpa)`, `pool.create()` | `.empty`, `pool.create(gpa)`, `pool.destroy(p)`, `pool.deinit(gpa)` |
| `alignedAlloc(u8, 4096, n)`, vtable `ptr_align: u8` | `alignedAlloc(u8, .fromByteUnits(4096), n)`; vtable takes `std.mem.Alignment`, has 4 fns: `alloc`, `resize`, `remap`, `free` |
| `allocator.dupeZ` | `allocator.dupeSentinel(u8, s, 0)` |
| `std.Thread.Mutex`, `RwLock`, `Condition`, `ResetEvent`, `Pool`, `WaitGroup` | `std.Io.Mutex` / `RwLock` / `Condition` / `Event` / `Group`; init with `.init`, lock with `lockUncancelable(io)` or `try lock(io)`, `unlock(io)` |
| `std.time.Timer`, `milliTimestamp`, `std.time.sleep` | `std.Io.Clock.awake.now(io)`, `t0.untilNow(io, .awake).toNanoseconds()`, `try io.sleep(.fromMilliseconds(1), .awake)` |
| `std.rand`, `std.crypto.random`, `std.posix.getrandom` | `std.Random.DefaultPrng.init(seed)`; entropy: `io.random(&bytes)` |
| `builtin.mode == .Debug`, `.ReleaseFast` | `.debug`, `.safe`, `.fast`, `.small` (CLI accepts both `-Doptimize=fast` and `ReleaseFast`) |
| `std.builtin.Endian.Little`, `.SeqCst`, `callconv(.C)` | `.little`/`.big`, `.seq_cst`, `callconv(.c)`; `std.builtin` is now `std.lang` (alias kept) |
| `@typeInfo(T).Struct.fields`, `std.meta.fields(T)` | `@typeInfo(T).@"struct".field_names` / `.field_types` / `.field_attrs` |
| `@Type(.{...})`, `std.meta.Int` | `@Int(.unsigned, 24)`, `@Struct`, `@Enum`, `@Union`, `@Tuple`, `@Pointer`, `@Fn` |
| `@intCast(u32, x)`, `@ptrCast(*T, p)`, `@enumToInt`, `@fieldParentPtr(T, "f", p)`, `@setCold` | one-argument casts with result type (`const y: u32 = @intCast(x);`), `@intFromEnum`, `@fieldParentPtr("f", p)`, `@branchHint(.cold)` |
| `for (xs) \|x, i\|`, `std.mem.copy`, `std.mem.set`, `std.sort.sort` | `for (xs, 0..) \|x, i\|`, `@memcpy`/`@memmove`, `@memset`, `std.mem.sort` |
| `b.addExecutable(.{ .root_source_file = ... })`, `exe.linkLibC()`, `b.args` | `.root_module = b.createModule(.{ .root_source_file = b.path(...), .target, .optimize })`, `.link_libc = true` on the module, `run_cmd.addPassthruArgs()` |

Also: unused locals, unused `var` mutability ("local variable is never mutated"), shadowing of any outer
declaration, and "pointless discard" are **compile errors**, not warnings.

---

## 1. Project layout, build, run, test

```
chapter/
  build.zig          # build graph
  build.zig.zon      # package manifest (optional, but if present 4 fields are mandatory)
  src/main.zig       # executable root: pub fn main(init: std.process.Init) !void
  src/root.zig       # library root; must reference every file whose tests should run
  src/snippets/*.zig
```

`build.zig` (executable + library module + `test` and `run` steps + `-Dtest-filter`):

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module: src/root.zig (+ everything it @imports).
    const mod = b.addModule("btree_template", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Executable: src/main.zig, importing the library as @import("btree_template").
    const exe = b.addExecutable(.{
        .name = "btree_template",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "btree_template", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    // `zig build run -- arg1 arg2`
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs the test blocks of both modules.
    // `zig build test -Dtest-filter=PagePool -Dtest-filter=Pager` runs only matching tests.
    const filters = b.option([]const []const u8, "test-filter", "Only run tests whose name contains this") orelse &.{};
    const mod_tests = b.addTest(.{ .root_module = mod, .filters = filters });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .filters = filters });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
```

`build.zig.zon`. A `build.zig` works without it. If the file exists, `.name` (an **enum literal**, not a
string), `.version`, `.fingerprint` and `.paths` are all required (each missing one is a hard error:
`missing top-level 'fingerprint' field; suggested value: 0x...`). The fingerprint is derived from the
name: after renaming, delete the field, run `zig build`, paste the suggested value.
`.minimum_zig_version` and `.dependencies` are optional.

```zig
.{
    .name = .btree_template,
    .version = "0.0.0",
    .fingerprint = 0x47d080399abf9e29, // required; `zig build` suggests a value if missing
    .minimum_zig_version = "0.17.1",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

Commands (all verified):

```sh
zig build                       # compile + install to zig-out/bin/
zig build run -- arg1 arg2      # run the executable with arguments
zig build test                  # run all tests (silent on success)
zig build test --summary all    # ... and print per-step pass/skip counts
zig build test -Dtest-filter=PagePool -Dtest-filter=Pager   # substring filters (case-sensitive), this build.zig only
zig build -Doptimize=fast       # debug (default) | safe | fast | small ; old names ReleaseFast etc. still accepted
zig build --release=fast        # same idea, standard flag

zig test src/root.zig                           # one file (+ everything it references), no build.zig needed
zig test src/snippets/s06_bytes.zig             # a leaf file on its own
zig test src/root.zig --test-filter "PagePool"  # filter by test name substring
zig test -O fast src/root.zig                   # optimized; also -Ofast / -OReleaseFast
zig test -lc file.zig                           # link libc (needed for std.heap.c_allocator)
zig test -fsingle-threaded file.zig
zig run file.zig -- arg1 arg2                   # compile + run a file that has pub fn main
zig fmt src build.zig                           # format in place (zig fmt --check to verify)
zig init                                        # scaffold a project named after the current directory
```

Gotchas:
* A test block only runs if its file is reachable from the test root **through a `test` block or a
  referenced declaration**. Pattern used in `src/root.zig`: `test { _ = @import("snippets/x.zig"); }`.
* `@import("../x.zig")` from a file under the module root's directory tree is fine; importing a file
  *above* the root file's directory fails with `import of file outside module path`. So
  `zig test src/snippets/a.zig` cannot import `../root.zig`.
* Anything a passing test prints to stderr (`std.debug.print`, `std.log.err`) makes `zig build test`
  echo `failed command: ...` even though the step succeeds. Keep passing tests silent. A leaked
  allocation from `std.testing.allocator` fails the test run (`1 tests leaked memory`).
* Never write to stdout inside `zig build test`: stdout is the pipe to the build runner.
* Test names: `test "string name" {}`, `test identifierOfADecl {}` (doctest), or anonymous `test {}`.
  Skip with `return error.SkipZigTest;`.

`src/root.zig`:

```zig
//! Library root of the template (`@import("btree_template")` from main.zig).
//!
//! `zig build test` compiles this file as a test root. Tests in *other* files
//! only run if those files are referenced from a `test` block reachable from
//! here, hence the `test { _ = @import(...); }` block at the bottom.
const std = @import("std");

pub const snippets = struct {
    pub const printing = @import("snippets/s02_printing.zig");
    pub const allocators = @import("snippets/s03_allocators.zig");
    pub const allocator_interface = @import("snippets/s04_allocator_interface.zig");
    pub const containers = @import("snippets/s05_containers.zig");
    pub const bytes = @import("snippets/s06_bytes.zig");
    pub const file_io = @import("snippets/s07_file_io.zig");
    pub const misc = @import("snippets/s08_misc.zig");
    pub const changes = @import("snippets/s09_changes.zig");
};

pub const CountingAllocator = snippets.allocator_interface.CountingAllocator;
pub const PagePool = snippets.allocator_interface.PagePool;
pub const Pager = snippets.file_io.Pager;

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test add {
    try std.testing.expectEqual(10, add(3, 7));
}

test {
    // Pull in the tests of every snippet file. `std.testing.refAllDecls(@This())`
    // only references top-level decls of this file; listing imports is explicit.
    _ = snippets.printing;
    _ = snippets.allocators;
    _ = snippets.allocator_interface;
    _ = snippets.containers;
    _ = snippets.bytes;
    _ = snippets.file_io;
    _ = snippets.misc;
    _ = snippets.changes;
}
```

---

## 2. Printing, stdout, formatting, `main`

`main` signatures accepted by `std/start.zig`: `pub fn main() ...`, `pub fn main(init: std.process.Init.Minimal) ...`
(args + environ only), `pub fn main(init: std.process.Init) ...`. Return `void`, `!void`, `u8`, `!u8` or `noreturn`.
`std.process.Init` fields: `minimal: Minimal { args, environ }`, `arena: *std.heap.ArenaAllocator`,
`gpa: Allocator`, `io: std.Io`, `environ_map: *Environ.Map`, `preopens`.
In debug/safe builds `init.gpa` is a `SafeAllocator`; leaks are logged at exit (exit code unaffected).
Do not name the parameter `init` if the file also has a top-level `const init = ...` (shadowing error).

`src/main.zig` (run with `zig build run -- a b`):

```zig
//! Executable entry point. In 0.17.1 `main` may take:
//!   pub fn main() !void                                  - nothing provided
//!   pub fn main(init: std.process.Init.Minimal) !void    - only args + environ
//!   pub fn main(init: std.process.Init) !void            - args, environ, gpa, arena, io
//! Return type: void, !void, u8, !u8 or noreturn.
const std = @import("std");
const Io = std.Io;
const lib = @import("btree_template");

pub fn main(init: std.process.Init) !void {
    // General purpose allocator: leak-checking SafeAllocator in Debug/ReleaseSafe,
    // smp_allocator (or c_allocator when linking libc) in ReleaseFast/ReleaseSmall.
    const gpa: std.mem.Allocator = init.gpa;
    // Process-lifetime arena; never freed individually.
    const arena: std.mem.Allocator = init.arena.allocator();
    // The Io implementation (std.Io.Threaded): needed for files, stdout, clocks, mutexes.
    const io: Io = init.io;

    // Command line arguments. args[0] is the program name.
    const args: []const [:0]const u8 = try init.minimal.args.toSlice(arena);
    // Environment variables.
    const home: ?[]const u8 = init.environ_map.get("HOME");

    // Buffered stdout. Nothing is written until flush().
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout: *Io.Writer = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print("btree_template: {d} arg(s), HOME set: {}\n", .{ args.len - 1, home != null });
    for (args[1..], 1..) |arg, i| {
        try stdout.print("  arg[{d}] = {s}\n", .{ i, arg });
    }

    var keys: std.ArrayList(u32) = .empty;
    defer keys.deinit(gpa);
    try keys.appendSlice(gpa, &.{ 30, 10, 20 });
    std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));
    try stdout.print("sorted keys: {any}\n", .{keys.items});
    try stdout.print("lib.add(2, 3) = {d}\n", .{lib.add(2, 3)});

    // stderr, unbuffered, for diagnostics:
    std.debug.print("(stderr) done\n", .{});
    // std.process.exit(1) terminates immediately WITHOUT running defers (flush first).
}

test "main module tests run under `zig build test` too" {
    try std.testing.expectEqual(5, lib.add(2, 3));
}
```

Format specifier summary (all exercised below): `{d}` decimal (ints and floats, `{d:.2}` precision),
`{x}`/`{X}` hex (ints, and byte slices as a hex string), `{b}` binary, `{o}` octal, `{c}` char, `{s}` string,
`{e}` scientific, `{any}` anything (structs print as `.{ .id = 1 }`, `[]const u8` fields as `{ 97, 98 }`),
`{f}` call the value's `format` method, `{t}` enum tag / error name, `{*}` pointer address,
`{?d}` optional, `{B}`/`{Bi}` byte sizes (`1.5MB`, `4KiB`). Width/fill/align: `{d:>5}`, `{d:0>4}`, `{s:<6}`, `{d:_^4}`.
`{}` works for ints/bools/structs but is a compile error for slices
(`cannot format slice without a specifier`); `{s}` on an enum and `{d}` on a pointer are compile errors.
Wrong argument count is a compile error (`too few arguments`).

```zig
//! Section 2: printing, formatting, Io.Writer.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

// std.debug.print(fmt, args): stderr, unbuffered, cannot fail, no `try`. See src/main.zig.
// Avoid it inside tests that pass: any stderr output makes `zig build test` echo the
// test command as "failed command: ..." (the step still succeeds).
fn debugDump(keys: []const u32) void {
    std.debug.print("keys={any} n={d}\n", .{ keys, keys.len });
}

test "std.debug.print compiles (not called: keeps test output clean)" {
    _ = &debugDump;
}

test "format specifiers via bufPrint" {
    var buf: [128]u8 = undefined;
    // {d} decimal, {x}/{X} hex, {b} binary, {o} octal, {c} char, {s} string,
    // {e} float scientific, {any} anything, {f} calls the value's format() method,
    // {t} tag name of enum/union / error name, {*} address.
    try testing.expectEqualStrings("42 2a 2A 101010", try std.fmt.bufPrint(&buf, "{d} {x} {X} {b}", .{ 42, 42, 42, 42 }));
    try testing.expectEqualStrings("abc|a", try std.fmt.bufPrint(&buf, "{s}|{c}", .{ "abc", 'a' }));
    // width / fill / alignment: {[fill][align][width]} with < ^ >
    try testing.expectEqualStrings("  42|42  |0042|_42_", try std.fmt.bufPrint(&buf, "{d:4}|{d:<4}|{d:0>4}|{d:_^4}", .{ 42, 42, 42, 42 }));
    try testing.expectEqualStrings("3.14", try std.fmt.bufPrint(&buf, "{d:.2}", .{3.14159}));
    // slices of integers: {any} works; {d} on a slice also prints each element.
    const xs = [_]u8{ 1, 2, 3 };
    try testing.expectEqualStrings("{ 1, 2, 3 }", try std.fmt.bufPrint(&buf, "{any}", .{xs[0..]}));
    try testing.expectEqualStrings("{ 1, 2, 3 }", try std.fmt.bufPrint(&buf, "{any}", .{xs}));
    // bytes as hex string
    try testing.expectEqualStrings("010203", try std.fmt.bufPrint(&buf, "{x}", .{xs[0..]}));
    // optional and error union need {?} / {!} wrappers (or {any})
    const maybe: ?u32 = null;
    try testing.expectEqualStrings("null 7", try std.fmt.bufPrint(&buf, "{?d} {?d}", .{ maybe, @as(?u32, 7) }));
    // enum tag name
    const Color = enum { red, green };
    try testing.expectEqualStrings("green", try std.fmt.bufPrint(&buf, "{t}", .{Color.green}));
    try testing.expectEqualStrings(".green", try std.fmt.bufPrint(&buf, "{any}", .{Color.green}));
    // error name
    try testing.expectEqualStrings("OutOfMemory", try std.fmt.bufPrint(&buf, "{t}", .{error.OutOfMemory}));
}

const Key = struct {
    id: u32,
    // Custom formatting: exact signature in 0.17.1. Invoked by "{f}", NOT by "{}".
    pub fn format(self: Key, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("Key#{d}", .{self.id});
    }
};

test "custom format method uses {f}" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Key#9", try std.fmt.bufPrint(&buf, "{f}", .{Key{ .id = 9 }}));
}

test "allocPrint and Allocator.print" {
    const gpa = testing.allocator;
    const s = try std.fmt.allocPrint(gpa, "page {d}", .{7});
    defer gpa.free(s);
    try testing.expectEqualStrings("page 7", s);
}

test "Io.Writer.fixed: write into a caller buffer" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("{s}={d}", .{ "n", 3 });
    try w.writeAll("!");
    try w.writeByte('\n');
    try testing.expectEqualStrings("n=3!\n", w.buffered());
}

test "Io.Writer.Allocating: growable in-memory writer" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.print("{d}-{d}", .{ 1, 2 });
    try testing.expectEqualStrings("1-2", aw.written());
}

test "buffered stdout writer" {
    const io = testing.io; // in main(): init.io
    var stdout_buffer: [1024]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout: *Io.Writer = &file_writer.interface;
    try stdout.print("", .{}); // tests must not write to stdout (it is the test-runner protocol pipe)
    try stdout.flush(); // nothing is written until flush
}

/// Reusable code takes `*Io.Writer` (a concrete type, not anytype).
pub fn dumpKeys(w: *Io.Writer, keys: []const u32) Io.Writer.Error!void {
    for (keys, 0..) |k, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{d}", .{k});
    }
}

test dumpKeys {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try dumpKeys(&w, &.{ 1, 2, 3 });
    try testing.expectEqualStrings("1, 2, 3", w.buffered());
}

test "std.log" {
    std.log.debug("not shown in tests unless testing.log_level is lowered: {d}", .{1});
}
```

---

## 3. Allocators in `std.heap` (complete list for 0.17.1)

`ls lib/std/heap/`: `ArenaAllocator.zig BrkAllocator.zig BufferFirstAllocator.zig FixedBufferAllocator.zig
PageAllocator.zig SafeAllocator.zig SmpAllocator.zig debug_allocator.zig memory_pool.zig`.
Not present any more: `GeneralPurposeAllocator`, `stackFallback`/`StackFallbackAllocator`, `LoggingAllocator`,
`ThreadSafeAllocator`, `raw_c_allocator`, `MemoryPoolExtra`/`MemoryPoolAligned` (now `memory_pool.Extra` / `.Aligned`),
`std.mem.page_size`/`std.heap.page_size` (now `std.heap.page_size_min`, `page_size_max`, `pageSize()`).

| Allocator | Construct | `Allocator` | Teardown / reset | Leak check | Use in a B-tree |
|---|---|---|---|---|---|
| `std.testing.allocator` | global (a `SafeAllocator`) | itself | per test, automatic | yes: test run fails | every unit test; proves split/merge/deinit free everything |
| `std.heap.SafeAllocator` | `var s: SafeAllocator = .init(std.heap.page_allocator, .{});` | `s.allocator()` | `s.deinit()` returns leak **count** (`deinitLog(false)` quiet) | yes + double free, use-after-free | debug-build GPA for the node heap (what `init.gpa` is in debug/safe) |
| `std.heap.DebugAllocator(.{})` (deprecated) | `var d: DebugAllocator(.{}) = .init;` | `d.allocator()` | `d.deinit()` returns `std.heap.Check` `.ok`/`.leak` | yes | avoid; use `SafeAllocator` |
| `std.heap.smp_allocator` | global | itself | none | no | release-build GPA for pointer-based nodes; multi-thread benchmarks |
| `std.heap.page_allocator` | global | itself | none (`munmap` per free) | no | backing for arenas/pools; whole-page buffers. One syscall per alloc: never per node |
| `std.heap.PageAllocator` | namespace: `.map(n, alignment)`, `.unmap(slice)`, `.realloc(...)` | (use `page_allocator`) | `unmap` | no | raw mmap'd buffer pool memory |
| `std.heap.ArenaAllocator` | `var a: ArenaAllocator = .init(child);` | `a.allocator()` | `a.deinit()`; `a.reset(.retain_capacity \| .free_all \| .{ .retain_with_limit = n })` | via child | bulk-loaded / immutable trees, per-query scratch, "free the whole tree at once" |
| `std.heap.FixedBufferAllocator` | `var f: FixedBufferAllocator = .init(&buf);` | `f.allocator()` / `f.threadSafeAllocator()` | `f.reset()` | n/a (OOM when full) | no-syscall scratch for one operation (split buffers, key copies), bounded-memory tests |
| `std.heap.BufferFirstAllocator` | `var b: BufferFirstAllocator = .init(&stack_buf, fallback);` | `b.allocator()` | free what you allocate | via fallback | small temporary key/path buffers on the stack with heap fallback for big ones |
| `std.heap.MemoryPool(T)` | `var p: MemoryPool(T) = .empty;` or `try .initCapacity(gpa, n)` | none: `p.create(gpa)`, `p.destroy(ptr)` | `p.deinit(gpa)`; `p.reset(gpa, mode)`; `p.addCapacity(gpa, n)` | no (items live in an internal arena) | **the node allocator**: fixed-size nodes, O(1) alloc/free via free list |
| `std.heap.memory_pool.Aligned(T, alignment)` | same as above | same | same | no | 4096-aligned page frames for a buffer pool |
| `std.heap.memory_pool.Extra(T, .{ .alignment = ?, .growable = false })` | `try .initCapacity(gpa, n)` | `create(undefined)` | same | no | fixed-capacity buffer pool: `create` returns `error.OutOfMemory` when all frames are in use |
| `std.heap.c_allocator` | global, needs libc (`-lc` / `.link_libc = true`) | itself | none | no | comparison against malloc; what `init.gpa` is in fast/small builds with libc |
| `std.heap.brk_allocator` (`BrkAllocator`) | global; single-threaded Linux / wasm only (`@compileError` otherwise) | itself | none | no | not useful here |
| `std.heap.wasm_allocator` | wasm only | itself | none | no | not useful here |
| `std.mem.Allocator.failing` / `std.testing.failing_allocator` | global | itself | none | n/a | prove a code path performs no allocation |
| `std.testing.FailingAllocator` | `var f: FailingAllocator = .init(child, .{ .fail_index = n });` | `f.allocator()` | none; inspect `allocations`, `deallocations`, `allocated_bytes`, `has_induced_failure` | via child | OOM-injection: fail the Nth allocation inside insert/split |
| `std.testing.checkAllAllocationFailures(gpa, fn, args)` | function | passes one in as first arg | n/a | yes | exhaustive OOM test of insert/split/merge (section 4) |

```zig
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
```

---

## 4. The `std.mem.Allocator` interface and custom allocators

`std.mem.Allocator` is `{ ptr: *anyopaque, vtable: *const VTable }`, passed **by value**. Methods:
`create(T)`, `destroy(ptr)`, `alloc(T, n)`, `free(slice)`, `dupe(T, slice)`, `dupeSentinel(T, slice, s)`,
`allocSentinel(T, n, s)`, `alignedAlloc(T, ?Alignment, n)`, `alignedCreate(T, ?Alignment)`,
`resize(slice, n) bool` (in place only), `remap(slice, n) ?[]T` (may move, null = do it yourself),
`realloc(slice, n) ![]T`, `print(fmt, args) ![]u8`, and the raw forms `rawAlloc`, `rawResize`, `rawRemap`, `rawFree`.
`Allocator.Error` is `error{OutOfMemory}`. Freshly allocated memory is `undefined` (0xAA in debug).

`std.mem.Alignment` is a log2 `enum`: `.@"1"`, `.@"2"`, ... `.@"64"`, `.fromByteUnits(4096)`, `.of(T)`,
`a.toByteUnits()`. Passing an integer is a compile error (`expected type '?mem.Alignment', found 'comptime_int'`).

VTable (exact, from `lib/std/mem/Allocator.zig`):

```
alloc:  *const fn (*anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8
resize: *const fn (*anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool
remap:  *const fn (*anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8
free:   *const fn (*anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void
```

Defaults you can plug in: `Allocator.noAlloc`, `noResize`, `noRemap`, `noFree`.

```zig
//! Section 4: the std.mem.Allocator interface and custom allocators.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;

test "Allocator interface: create/destroy/alloc/free/dupe" {
    const gpa = testing.allocator;

    const one: *u64 = try gpa.create(u64); // single item, contents undefined
    defer gpa.destroy(one);

    const many: []u32 = try gpa.alloc(u32, 8); // slice, contents undefined
    defer gpa.free(many);
    @memset(many, 0);

    const copy: []u8 = try gpa.dupe(u8, "hello"); // (dupeZ is now dupeSentinel)
    defer gpa.free(copy);
    const copy_z: [:0]u8 = try gpa.dupeSentinel(u8, "hello", 0);
    defer gpa.free(copy_z);
    const zs: [:0]u8 = try gpa.allocSentinel(u8, 4, 0);
    defer gpa.free(zs);
    const msg = try gpa.print("{d} keys", .{3}); // Allocator.print == std.fmt.allocPrint
    defer gpa.free(msg);
}

test "Allocator interface: aligned allocation uses std.mem.Alignment (an enum)" {
    const gpa = testing.allocator;
    // Alignment is a log2 enum: .@"1" .. .@"64", or .fromByteUnits(n), or .of(T).
    const page: []align(4096) u8 = try gpa.alignedAlloc(u8, .fromByteUnits(4096), 4096);
    defer gpa.free(page);
    try testing.expect(std.mem.isAligned(@intFromPtr(page.ptr), 4096));

    const cache_aligned: []align(64) u64 = try gpa.alignedAlloc(u64, .@"64", 4);
    defer gpa.free(cache_aligned);

    const natural: []u64 = try gpa.alignedAlloc(u64, null, 4); // null = natural alignment
    defer gpa.free(natural);

    const one: *align(64) u64 = try gpa.alignedCreate(u64, .@"64");
    defer gpa.destroy(one);

    try testing.expectEqual(4096, Alignment.fromByteUnits(4096).toByteUnits());
    try testing.expectEqual(Alignment.@"8", Alignment.of(u64));
}

test "Allocator interface: resize / remap / realloc" {
    const gpa = testing.allocator;
    var buf = try gpa.alloc(u8, 16);
    defer gpa.free(buf);

    // resize: in place only; returns bool. On true you must update the slice length yourself.
    if (gpa.resize(buf, 8)) buf = buf[0..8];

    // remap: may move without a copy (e.g. mremap); returns ?[]T. null = "do alloc+copy+free yourself".
    if (gpa.remap(buf, 64)) |moved| buf = moved;

    // realloc: always works or returns OutOfMemory; may move; preserves contents.
    buf = try gpa.realloc(buf, 1024);
    try testing.expectEqual(1024, buf.len);
}

// ---------------------------------------------------------------------------
// (a) Counting / tracking allocator wrapper.
//
// VTable in 0.17.1 (std.mem.Allocator.VTable) - exactly four function pointers:
//   alloc:  *const fn (*anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8
//   resize: *const fn (*anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool
//   remap:  *const fn (*anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8
//   free:   *const fn (*anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void
// Forward to the child with rawAlloc / rawResize / rawRemap / rawFree.
// ---------------------------------------------------------------------------
pub const CountingAllocator = struct {
    child: Allocator,
    alloc_count: usize = 0,
    free_count: usize = 0,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    total_bytes: usize = 0,

    pub fn init(child: Allocator) CountingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn grew(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        self.live_bytes = self.live_bytes - old_len + new_len;
        if (new_len > old_len) self.total_bytes += new_len - old_len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.alloc_count += 1;
        self.grew(0, len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.grew(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.grew(memory.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.free_count += 1;
        self.live_bytes -= memory.len;
    }
};

test CountingAllocator {
    var counting: CountingAllocator = .init(testing.allocator);
    const a = counting.allocator();

    const xs = try a.alloc(u64, 10);
    const node = try a.create([32]u8);
    try testing.expectEqual(2, counting.alloc_count);
    try testing.expectEqual(80 + 32, counting.live_bytes);

    var list: std.ArrayList(u32) = .empty;
    try list.appendSlice(a, &.{ 1, 2, 3 });
    list.deinit(a);

    a.free(xs);
    a.destroy(node);
    try testing.expectEqual(counting.alloc_count, counting.free_count);
    try testing.expectEqual(0, counting.live_bytes);
    try testing.expect(counting.peak_bytes >= 112);
}

// ---------------------------------------------------------------------------
// (b) Fixed-size slab "page allocator": hands out 4096-byte, 4096-aligned pages
// from one big slab, with an intrusive free list threaded through free pages.
// Offers both a typed API (allocPage/freePage) and a std.mem.Allocator interface.
// ---------------------------------------------------------------------------
pub const PagePool = struct {
    pub const page_size = 4096;
    pub const Page = [page_size]u8;
    pub const PagePtr = *align(page_size) Page;

    backing: Allocator,
    slab: []align(page_size) u8,
    /// Pages never handed out yet start at this index.
    next_fresh: usize = 0,
    /// Intrusive singly linked list of freed pages.
    free_list: ?*FreeNode = null,
    in_use: usize = 0,

    const FreeNode = struct { next: ?*FreeNode };

    pub fn init(backing: Allocator, page_count: usize) Allocator.Error!PagePool {
        const slab = try backing.alignedAlloc(u8, .fromByteUnits(page_size), page_count * page_size);
        return .{ .backing = backing, .slab = slab };
    }

    pub fn deinit(self: *PagePool) void {
        assert(self.in_use == 0); // leak check
        self.backing.free(self.slab);
        self.* = undefined;
    }

    pub fn capacity(self: *const PagePool) usize {
        return self.slab.len / page_size;
    }

    pub fn allocPage(self: *PagePool) Allocator.Error!PagePtr {
        if (self.free_list) |node| {
            self.free_list = node.next;
            self.in_use += 1;
            return @ptrCast(@alignCast(node));
        }
        if (self.next_fresh == self.capacity()) return error.OutOfMemory;
        const off = self.next_fresh * page_size;
        self.next_fresh += 1;
        self.in_use += 1;
        return @alignCast(self.slab[off..][0..page_size]);
    }

    pub fn freePage(self: *PagePool, page: PagePtr) void {
        assert(self.owns(page));
        const node: *FreeNode = @ptrCast(page); // page alignment (4096) >= @alignOf(FreeNode)
        node.* = .{ .next = self.free_list };
        self.free_list = node;
        self.in_use -= 1;
    }

    pub fn owns(self: *const PagePool, ptr: [*]const u8) bool {
        const base = @intFromPtr(self.slab.ptr);
        const addr = @intFromPtr(ptr);
        return addr >= base and addr < base + self.slab.len and (addr - base) % page_size == 0;
    }

    // ---- std.mem.Allocator adapter: only serves requests that fit in one page ----
    pub fn allocator(self: *PagePool) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *PagePool = @ptrCast(@alignCast(ctx));
        if (len > page_size or alignment.toByteUnits() > page_size) return null;
        const page = self.allocPage() catch return null;
        return page;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = .{ ctx, memory, alignment, ret_addr };
        return new_len <= page_size; // every allocation owns a whole page
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = .{ alignment, ret_addr };
        const self: *PagePool = @ptrCast(@alignCast(ctx));
        self.freePage(@ptrCast(@alignCast(memory.ptr)));
    }
};

test "PagePool: typed page API with free list reuse" {
    var pool: PagePool = try .init(testing.allocator, 4);
    defer pool.deinit();

    const p0 = try pool.allocPage();
    const p1 = try pool.allocPage();
    try testing.expect(std.mem.isAligned(@intFromPtr(p0), 4096));
    try testing.expectEqual(@intFromPtr(p0) + 4096, @intFromPtr(p1));
    @memset(p0, 0xAA);

    pool.freePage(p0);
    const p2 = try pool.allocPage(); // LIFO reuse
    try testing.expectEqual(p0, p2);

    const p3 = try pool.allocPage();
    const p4 = try pool.allocPage();
    try testing.expectError(error.OutOfMemory, pool.allocPage());
    try testing.expectEqual(4, pool.in_use);

    for ([_]PagePool.PagePtr{ p1, p2, p3, p4 }) |p| pool.freePage(p);
}

test "PagePool: through the std.mem.Allocator interface" {
    var pool: PagePool = try .init(testing.allocator, 2);
    defer pool.deinit();
    const a = pool.allocator();

    const page = try a.alignedAlloc(u8, .fromByteUnits(4096), 4096);
    const Header = extern struct { kind: u32, count: u32 };
    const hdr = try a.create(Header); // small object still consumes a whole page
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    try testing.expectError(error.OutOfMemory, pool.allocator().alloc(u8, 8192));
    a.free(page);
    a.destroy(hdr);
}

// ---------------------------------------------------------------------------
// Testing OOM paths: checkAllAllocationFailures runs the function once to count
// allocations, then once per allocation index with that allocation failing, and
// checks: the function returns error.OutOfMemory and nothing leaks.
// ---------------------------------------------------------------------------
fn buildSomething(gpa: Allocator, n: usize) !void {
    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    for (0..n) |i| {
        const s = try gpa.alloc(u8, i + 1);
        errdefer gpa.free(s); // without this line the check reports a leak
        try list.append(gpa, s);
    }
}

test "checkAllAllocationFailures" {
    try testing.checkAllAllocationFailures(testing.allocator, buildSomething, .{@as(usize, 4)});
}
```

---

## 5. Containers

Rule: containers are unmanaged. Initialise with `.empty`, pass `gpa` to anything that may allocate and to
`deinit(gpa)`. Managed variants that remain: `std.AutoHashMap` / `std.StringHashMap` / `std.HashMap`
(`.init(gpa)`, `deinit()`), and `std.array_list.Managed(T)`.

| Type | Status in 0.17.1 | Key API |
|---|---|---|
| `std.ArrayList(T)` | unmanaged (`std.ArrayListUnmanaged` is a deprecated alias) | `.empty`, `try .initCapacity(gpa, n)`, `.initBuffer(&buf)`, `append(gpa, x)`, `appendSlice(gpa, s)`, `insert(gpa, i, x)`, `orderedRemove(i)`, `swapRemove(i)`, `pop() ?T`, `ensureTotalCapacity(gpa, n)`, `appendAssumeCapacity(x)`, `appendBounded(x)`, `addOne(gpa)`, `resize(gpa, n)`, `clearRetainingCapacity()`, `toOwnedSlice(gpa)`, `deinit(gpa)`; fields `.items`, `.capacity` |
| `std.array_list.Aligned(T, alignment)` | present | same API, `items` is `[]align(a) T` |
| `std.AutoHashMapUnmanaged(K, V)`, `StringHashMapUnmanaged(V)`, `HashMapUnmanaged(K, V, Ctx, 80)` | present | `.empty`, `put(gpa, k, v)`, `get(k) ?V`, `getPtr(k)`, `getOrPut(gpa, k)`, `contains(k)`, `remove(k) bool`, `fetchRemove(k)`, `count()`, `iterator()`, `deinit(gpa)` |
| `std.array_hash_map.Auto(K, V)` / `.String(V)` / `.Custom` | present (`std.AutoArrayHashMapUnmanaged` deprecated alias; managed `std.AutoArrayHashMap` gone) | insertion ordered; `keys()`, `values()`, `getIndex(k)` |
| `std.PriorityQueue(T, Context, compareFn)` | unmanaged; `compareFn(ctx, a, b) std.math.Order` | `.empty`, `.initContext(ctx)`, `push(gpa, x)`, `pushSlice`, `peek()`, `pop() ?T`, `count()`, `deinit(gpa)` |
| `std.Deque(T)` | new | `.empty`, `pushBack(gpa, x)`, `pushFront(gpa, x)`, `popFront() ?T`, `popBack() ?T`, `.len` |
| `std.DoublyLinkedList`, `std.SinglyLinkedList` | intrusive, not generic | embed `Node`; `append/prepend/remove/popFirst/popLast`; `@fieldParentPtr("node", n)` |
| `std.MultiArrayList(T)` | unmanaged | `.empty`, `append(gpa, x)`, `items(.field)`, `get(i)`, `set(i, x)`, `slice()`, `.len`, `deinit(gpa)` |
| `std.StaticBitSet(n)`, `std.DynamicBitSetUnmanaged` | present | `.empty` / `.full` (static); `try .initEmpty(gpa, n)` (dynamic); `set`, `unset`, `isSet`, `count`, `findFirstSet` |
| `std.BoundedArray` | **removed** | `ArrayList.initBuffer` + `*Bounded` methods, or array + len (below) |
| `std.SegmentedList` | **removed** | hand-rolled chunk list (below) |
| `std.Treap` | present | not covered |

```zig
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
```

---

## 6. Slices and bytes for page-oriented code

Signatures (from `lib/std/mem.zig`, `lib/std/sort.zig`):

```
std.mem.readInt(comptime T: type, buffer: *const [@divExact(@typeInfo(T).int.bits, 8)]u8, endian: Endian) T
std.mem.writeInt(comptime T: type, buffer: *[@divExact(@typeInfo(T).int.bits, 8)]u8, value: T, endian: Endian) void
std.mem.order(comptime T: type, lhs: []const T, rhs: []const T) std.math.Order
std.mem.bytesAsSlice(comptime T: type, bytes: anytype) []align(1) T        (alignment follows the input)
std.mem.sliceAsBytes(slice: anytype) []u8
std.mem.asBytes(ptr: anytype) *[N]u8      std.mem.toBytes(value) [N]u8      std.mem.bytesToValue(T, bytes) T
std.mem.copyForwards(comptime T: type, dest: []T, source: []const T) void   (and copyBackwards)
std.mem.sort(comptime T: type, items: []T, context: anytype, comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool) void

std.sort.binarySearch(comptime T: type, items: []const T, context: anytype,
                      comptime compareFn: fn (@TypeOf(context), T) std.math.Order) ?usize
std.sort.lowerBound(...same parameters...) usize       // first index with item >= key
std.sort.upperBound(...same parameters...) usize       // first index with item >  key
std.sort.equalRange(...same parameters...) struct { usize, usize }
std.sort.partitionPoint(comptime T: type, items: []const T, context: anytype,
                        comptime predicate: fn (@TypeOf(context), T) bool) usize
```

`compareFn(context, item)` returns the order of **the searched key (context) relative to the item**.
There is no separate `key` parameter (the old 5-argument form fails with `expected 4 argument(s), found 5`).
When the context is an integer literal, write `@as(u32, 30)` so `@TypeOf(context)` matches the compare fn.

Rules:
* `readInt`/`writeInt` need a pointer to an array of exactly N bytes: `page[off..][0..4]`. A runtime-length
  slice fails with `coercion from slice to array pointer type '*const [4]u8' requires length to be known at compile-time`.
* `@ptrCast` cannot increase alignment (`@ptrCast increases pointer alignment` ... `use @alignCast`).
  `@ptrCast(@alignCast(p))` asserts alignment; a wrong one panics `incorrect alignment` in debug/safe.
  For unaligned on-disk data use `*align(1) T` or `readInt`.
* `extern struct`: C layout, declaration order, padding as in C. Use it for on-disk structs and pin it
  with `comptime { assert(@sizeOf(T) == N); assert(@offsetOf(T, "f") == K); }`.
  `extern struct { a: u8, b: u32, c: bool }` is 12 bytes. Fields with `align(1)` remove padding.
* `packed struct(uN)`: one integer, fields LSB first; no arrays inside
  (`packed structs cannot contain fields of type '[2]u8'`). `@sizeOf` is the backing integer's ABI size
  (`packed struct { a: u24, b: u8, c: u1 }` is 8 bytes). Convert with `@backingInt(x)` /
  `@fromBackingInt(i)` (new in 0.17) or `@bitCast`. Use for flag bytes, not for byte layouts.
* `@memcpy(dest, src)`: equal lengths, **no overlap** (debug panics: `@memcpy arguments alias`,
  `source and destination arguments have non-equal lengths`). `@memmove(dest, src)`: overlap allowed;
  this is the builtin for shifting keys inside a node. `@memset(slice, value)`. `@splat(0)` for arrays.
* Integer overflow panics in debug/safe (`integer overflow`); use `+%`, `-%`, `*%` (wrapping), `+|`, `-|` (saturating).

```zig
//! Section 6: slices and bytes for page-oriented code.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;

pub const page_size = 4096;

test "readInt / writeInt take a pointer to a fixed-size array + endianness" {
    var page: [page_size]u8 = @splat(0);

    // `page[off..][0..4]` gives *[4]u8 (comptime-known length), which is what the API wants.
    std.mem.writeInt(u32, page[0..4], 0xDEADBEEF, .little);
    std.mem.writeInt(u16, page[4..][0..2], 513, .big);
    std.mem.writeInt(u64, page[8..16], 1 << 40, .little);

    try testing.expectEqual(0xDEADBEEF, std.mem.readInt(u32, page[0..4], .little));
    try testing.expectEqual(513, std.mem.readInt(u16, page[4..6], .big));
    try testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE, 0xAD, 0xDE }, page[0..4]);

    // Runtime offset: slice by offset, then by comptime length.
    var off: usize = 8;
    off += 0;
    try testing.expectEqual(1 << 40, std.mem.readInt(u64, page[off..][0..8], .little));

    // Endianness enum: std.lang.Endian (.little / .big). `std.builtin` is a deprecated alias of `std.lang`.
    const native: std.lang.Endian = builtin.cpu.arch.endian();
    try testing.expectEqual(0xDEADBEEF, std.mem.readInt(u32, page[0..4], .little));
    try testing.expectEqual(std.mem.nativeToLittle(u32, 7), if (native == .little) 7 else @byteSwap(@as(u32, 7)));
    // Variable-width helpers:
    try testing.expectEqual(0xADBEEF, std.mem.readVarInt(u32, page[0..3], .little));
}

// extern struct: C layout, fields in declaration order, natural alignment + padding.
// This is the type to use for on-disk headers. Make padding explicit and assert the size.
const PageHeader = extern struct {
    magic: u32,
    kind: u8,
    flags: u8,
    key_count: u16,
    right_sibling: u64,
    lsn: u64,

    comptime {
        assert(@sizeOf(PageHeader) == 24);
        assert(@alignOf(PageHeader) == 8);
        assert(@offsetOf(PageHeader, "kind") == 4);
        assert(@offsetOf(PageHeader, "key_count") == 6);
        assert(@offsetOf(PageHeader, "right_sibling") == 8);
    }
};

// `extern struct` with align(1) fields: no padding at all (unaligned on-disk records).
const Slot = extern struct {
    offset: u16 align(1),
    len: u16 align(1),
    child: u64 align(1),

    comptime {
        assert(@sizeOf(Slot) == 12);
        assert(@alignOf(Slot) == 1);
    }
};

// packed struct: a bag of bits backed by ONE integer. Field order = LSB first.
// Good for flag words; NOT a byte-layout tool (endianness of the backing int applies).
const Flags = packed struct(u8) {
    is_leaf: bool,
    is_root: bool,
    dirty: bool,
    _reserved: u5 = 0,
};

test "packed struct <-> integer: @backingInt / @fromBackingInt (0.17) or @bitCast" {
    const f: Flags = .{ .is_leaf = true, .is_root = false, .dirty = true };
    try testing.expectEqual(0b101, @backingInt(f));
    try testing.expectEqual(0b101, @as(u8, @bitCast(f)));
    const g: Flags = @fromBackingInt(@as(u8, 0b010));
    try testing.expect(g.is_root and !g.is_leaf);
    try testing.expectEqual(1, @sizeOf(Flags));
    try testing.expectEqual(8, @bitSizeOf(Flags));
    try testing.expectEqual(2, @bitOffsetOf(Flags, "dirty"));
}

test "view a page as a header: @ptrCast + @alignCast" {
    // The buffer must really be aligned for the target type; declare it so.
    var page: [page_size]u8 align(page_size) = @splat(0);

    // *align(4096) [4096]u8 -> *PageHeader: alignment is sufficient, only @ptrCast needed.
    const hdr: *PageHeader = @ptrCast(&page);
    hdr.* = .{ .magic = 0xB7EE, .kind = 1, .flags = 0, .key_count = 3, .right_sibling = 9, .lsn = 0 };
    try testing.expectEqual(3, std.mem.readInt(u16, page[6..8], builtin.cpu.arch.endian()));

    // From a plain []u8 (alignment 1) you must add @alignCast (safety-checked at runtime in Debug).
    const bytes: []u8 = &page;
    const hdr2: *PageHeader = @ptrCast(@alignCast(bytes.ptr));
    try testing.expectEqual(9, hdr2.right_sibling);
    // Both casts take the result type from the destination; with no destination use @as:
    try testing.expectEqual(0xB7EE, @as(*const PageHeader, @ptrCast(@alignCast(bytes.ptr))).magic);

    // Unaligned access without @alignCast: point at an align(1) type instead.
    const slot: *align(1) Slot = @ptrCast(bytes[100..][0..@sizeOf(Slot)]);
    slot.* = .{ .offset = 4000, .len = 96, .child = 77 };
    const unaligned_u64: *align(1) u64 = @ptrCast(bytes[101..][0..8]);
    unaligned_u64.* = 5;

    // Slot array region after the header (slice of structs over bytes):
    const slots: []align(1) Slot = std.mem.bytesAsSlice(Slot, bytes[@sizeOf(PageHeader)..][0 .. 3 * @sizeOf(Slot)]);
    try testing.expectEqual(3, slots.len);
    slots[2] = .{ .offset = 1, .len = 2, .child = 3 };
}

test "std.mem byte reinterpretation helpers" {
    var hdr: PageHeader = .{ .magic = 1, .kind = 2, .flags = 3, .key_count = 4, .right_sibling = 5, .lsn = 6 };

    const as_bytes: *[@sizeOf(PageHeader)]u8 = std.mem.asBytes(&hdr); // view, no copy
    try testing.expectEqual(2, as_bytes[4]);
    const copy: [@sizeOf(PageHeader)]u8 = std.mem.toBytes(hdr); // by value
    const back: PageHeader = std.mem.bytesToValue(PageHeader, &copy); // copy out, any alignment
    try testing.expectEqual(5, back.right_sibling);
    const view: *align(1) const PageHeader = std.mem.bytesAsValue(PageHeader, &copy); // view
    try testing.expectEqual(6, view.lsn);

    var keys = [_]u32{ 1, 2, 3 };
    const key_bytes: []u8 = std.mem.sliceAsBytes(keys[0..]); // []T -> []u8
    try testing.expectEqual(12, key_bytes.len);
    const keys_again: []u32 = @alignCast(std.mem.bytesAsSlice(u32, key_bytes)); // []u8 -> []align(1) T
    try testing.expectEqual(3, keys_again[2]);

    // Zero-initialise (extern structs / arrays):
    const zeroed: PageHeader = std.mem.zeroes(PageHeader);
    try testing.expectEqual(0, zeroed.magic);
    var buf: [16]u8 = undefined;
    @memset(&buf, 0);
    const z: [16]u8 = @splat(0);
    try testing.expectEqualSlices(u8, &z, &buf);
}

test "copying: @memcpy (no overlap), @memmove (overlap ok), copyForwards/copyBackwards" {
    var a = [_]u8{ 1, 2, 3, 4, 5, 0, 0 };

    // @memcpy: dest and source must have equal lengths and must NOT overlap (checked in Debug).
    var b: [3]u8 = undefined;
    @memcpy(&b, a[0..3]);
    @memcpy(b[0..2], a[3..5]);

    // @memmove: overlapping regions allowed. Shift right by one to open a gap at index 1:
    @memmove(a[2..6], a[1..5]);
    a[1] = 99;
    try testing.expectEqualSlices(u8, &.{ 1, 99, 2, 3, 4, 5, 0 }, &a);

    // Shift left to delete index 1:
    @memmove(a[1..5], a[2..6]);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, a[0..5]);

    // Library equivalents (dest.len >= source.len; direction named after iteration order):
    std.mem.copyBackwards(u8, a[1..6], a[0..5]); // shift right: copy from the end
    std.mem.copyForwards(u8, a[0..5], a[1..6]); // shift left: copy from the start
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, a[0..5]);
}

test "comparing byte strings and integers" {
    try testing.expectEqual(std.math.Order.lt, std.mem.order(u8, "abc", "abd")); // lexicographic
    try testing.expectEqual(.lt, std.mem.order(u8, "ab", "abc")); // prefix sorts first
    try testing.expect(std.mem.lessThan(u8, "a", "b"));
    try testing.expect(std.mem.eql(u8, "key", "key"));
    try testing.expect(std.mem.startsWith(u8, "prefix-key", "prefix"));
    try testing.expectEqual(.gt, std.math.order(@as(u64, 9), 3));
    try testing.expectEqual(.eq, std.math.order(2, 2));
    try testing.expectEqual(2, std.mem.findDiff(u8, "abc", "abd").?); // was indexOfDiff (alias remains)
    try testing.expectEqual(1, std.mem.findScalar(u8, "abc", 'b').?); // was indexOfScalar (alias remains)
}

// --- Binary search family -------------------------------------------------
// All four have the same shape in 0.17.1:
//   fn(comptime T: type, items: []const T, context: anytype,
//      comptime compareFn: fn (@TypeOf(context), T) std.math.Order) -> ?usize / usize
// compareFn(context, item) returns the order of the *context (the key searched for)
// relative to the item*: .lt = key is before item, .gt = key is after item.
fn orderU32(key: u32, item: u32) std.math.Order {
    return std.math.order(key, item);
}

test "binarySearch / lowerBound / upperBound / equalRange / partitionPoint" {
    const keys = [_]u32{ 10, 20, 20, 30, 40 };

    try testing.expectEqual(3, std.sort.binarySearch(u32, &keys, @as(u32, 30), orderU32).?);
    try testing.expectEqual(null, std.sort.binarySearch(u32, &keys, @as(u32, 25), orderU32));

    // lowerBound: first index whose item is >= key (insertion point / child index in a leaf)
    try testing.expectEqual(1, std.sort.lowerBound(u32, &keys, @as(u32, 20), orderU32));
    try testing.expectEqual(3, std.sort.lowerBound(u32, &keys, @as(u32, 25), orderU32));
    try testing.expectEqual(5, std.sort.lowerBound(u32, &keys, @as(u32, 99), orderU32));
    // upperBound: first index whose item is > key (child index in an internal node)
    try testing.expectEqual(3, std.sort.upperBound(u32, &keys, @as(u32, 20), orderU32));
    try testing.expectEqual(0, std.sort.upperBound(u32, &keys, @as(u32, 5), orderU32));
    // equalRange: .{ lowerBound, upperBound }
    try testing.expectEqual(.{ 1, 3 }, std.sort.equalRange(u32, &keys, @as(u32, 20), orderU32));

    // partitionPoint: first index where predicate(context, item) is false.
    const S = struct {
        fn lessThan(limit: u32, item: u32) bool {
            return item < limit;
        }
    };
    try testing.expectEqual(3, std.sort.partitionPoint(u32, &keys, @as(u32, 30), S.lessThan));
}

test "binary search over structs / byte-string keys with a context" {
    const Entry = struct { key: []const u8, value: u32 };
    const entries = [_]Entry{
        .{ .key = "apple", .value = 1 },
        .{ .key = "mango", .value = 2 },
        .{ .key = "pear", .value = 3 },
    };
    const S = struct {
        fn cmp(key: []const u8, item: Entry) std.math.Order {
            return std.mem.order(u8, key, item.key);
        }
    };
    const needle: []const u8 = "mango";
    const i = std.sort.binarySearch(Entry, &entries, needle, S.cmp).?;
    try testing.expectEqual(2, entries[i].value);
    try testing.expectEqual(1, std.sort.lowerBound(Entry, &entries, @as([]const u8, "banana"), S.cmp));
}

// Hand-rolled branch-light lower bound: what most B-tree chapters actually want.
pub fn lowerBoundU64(keys: []const u64, key: u64) usize {
    var lo: usize = 0;
    var len = keys.len;
    while (len > 0) {
        const half = len / 2;
        if (keys[lo + half] < key) {
            lo += half + 1;
            len -= half + 1;
        } else {
            len = half;
        }
    }
    return lo;
}

test lowerBoundU64 {
    try testing.expectEqual(2, lowerBoundU64(&.{ 1, 3, 5, 7 }, 5));
    try testing.expectEqual(2, lowerBoundU64(&.{ 1, 3, 5, 7 }, 4));
    try testing.expectEqual(4, lowerBoundU64(&.{ 1, 3, 5, 7 }, 8));
    try testing.expectEqual(0, lowerBoundU64(&.{}, 8));
}

test "sorting" {
    var xs = [_]u32{ 5, 1, 4, 2 };
    std.mem.sort(u32, &xs, {}, std.sort.asc(u32)); // stable; lessThan(context, a, b) bool
    try testing.expectEqualSlices(u32, &.{ 1, 2, 4, 5 }, &xs);
    std.mem.sortUnstable(u32, &xs, {}, std.sort.desc(u32)); // pdqsort
    try testing.expectEqualSlices(u32, &.{ 5, 4, 2, 1 }, &xs);
    try testing.expect(std.sort.isSorted(u32, &xs, {}, std.sort.desc(u32)));

    const Pair = struct { k: u32, v: u8 };
    var ps = [_]Pair{ .{ .k = 2, .v = 'b' }, .{ .k = 1, .v = 'a' } };
    const byKey = struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return a.k < b.k;
        }
    }.lessThan;
    std.mem.sort(Pair, &ps, {}, byKey);
    try testing.expectEqual('a', ps[0].v);
}

test "alignment arithmetic and checksums" {
    try testing.expectEqual(8192, std.mem.alignForward(usize, 4097, 4096));
    try testing.expectEqual(4096, std.mem.alignBackward(usize, 8191, 4096));
    try testing.expect(std.mem.isAligned(8192, 4096));
    try testing.expectEqual(3, std.math.divCeil(usize, 9000, 4096) catch unreachable);
    try testing.expectEqual(12, std.math.log2_int(usize, 4096));

    const crc = std.hash.Crc32.hash("page bytes");
    const wy = std.hash.Wyhash.hash(0, "page bytes");
    try testing.expect(crc != 0 and wy != 0);
}
```

---

## 7. File I/O for a pager

Files and directories are `std.Io.File` and `std.Io.Dir` (`std.fs` only keeps `std.fs.path`).
Every operation takes an `io: std.Io` (`init.io` in `main`, `std.testing.io` in tests).

```
Io.Dir.cwd() Dir
dir.createFile(io, sub_path, .{ .read = false, .truncate = true, .exclusive = false, .lock = .none }) File.OpenError!File
dir.openFile(io, sub_path, .{ .mode = .read_only | .write_only | .read_write }) File.OpenError!File
dir.deleteFile(io, sub_path)   dir.access(io, sub_path, .{})   dir.createDirPath(io, sub_path)   dir.deleteTree(io, sub_path)
dir.rename(old_sub_path, new_dir, new_sub_path, io)             // note: io is LAST here
dir.writeFile(io, .{ .sub_path = "f", .data = bytes })   dir.readFileAlloc(io, sub_path, gpa, .limited(n)) ![]u8

file.readPositionalAll(io, buffer: []u8, offset: u64) ReadPositionalError!usize     // pread loop; < buffer.len means EOF
file.readPositional(io, buffer: []const []u8, offset: u64) !usize                   // vectored, may be short
file.writePositionalAll(io, bytes: []const u8, offset: u64) WritePositionalError!void   // pwrite loop
file.writePositional(io, buffer: []const []const u8, offset: u64) !usize                // vectored, may be short
file.length(io) !u64     file.setLength(io, n) !void     file.stat(io) !Stat (.size, .kind, ...)
file.sync(io) SyncError!void        // fsync
file.close(io) void
file.reader(io, &buf) File.Reader   file.writer(io, &buf) File.Writer    // buffered streaming; use .interface
file.lock(io, .exclusive) / file.unlock(io) / file.tryLock(io, .shared)
std.testing.tmpDir(.{}) TmpDir      // .dir is an Io.Dir under .zig-cache/tmp/<random>; defer tmp.cleanup();
```

Defaults that surprise: `createFile` opens **write-only** and **truncates**. A database file needs
`.{ .read = true, .truncate = false }`.

```zig
//! Section 7: file I/O for a pager. In 0.17.1 files live in std.Io
//! (std.Io.File / std.Io.Dir); every operation takes an `io: std.Io`.
//! In tests use `std.testing.io`; in main use `init.io`.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

pub const page_size = 4096;
pub const Page = [page_size]u8;

/// Minimal pager: fixed-size pages addressed by page number.
pub const Pager = struct {
    io: Io,
    file: Io.File,
    page_count: u64,

    pub const Error = error{ ShortRead, CorruptFile } ||
        Io.File.OpenError || Io.File.StatError ||
        Io.File.ReadPositionalError || Io.File.WritePositionalError ||
        Io.File.SyncError;

    /// Create or open `sub_path` inside `dir` for read+write without truncating.
    pub fn open(io: Io, dir: Io.Dir, sub_path: []const u8) Error!Pager {
        const file = try dir.createFile(io, sub_path, .{
            .read = true, // default is write-only!
            .truncate = false, // default is true!
        });
        errdefer file.close(io);
        const size = try file.length(io); // or (try file.stat(io)).size
        if (size % page_size != 0) return error.CorruptFile;
        return .{ .io = io, .file = file, .page_count = size / page_size };
    }

    pub fn close(self: *Pager) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    /// pread: fills the whole buffer or reports a short read.
    pub fn readPage(self: *Pager, page_no: u64, out: *Page) Error!void {
        const n = try self.file.readPositionalAll(self.io, out, page_no * page_size);
        if (n != page_size) return error.ShortRead;
    }

    /// pwrite: writes all bytes at the offset; extends the file if needed.
    pub fn writePage(self: *Pager, page_no: u64, page: *const Page) Error!void {
        try self.file.writePositionalAll(self.io, page, page_no * page_size);
        self.page_count = @max(self.page_count, page_no + 1);
    }

    pub fn allocPage(self: *Pager) Error!u64 {
        const page_no = self.page_count;
        const zero: Page = @splat(0);
        try self.writePage(page_no, &zero);
        return page_no;
    }

    /// fsync
    pub fn sync(self: *Pager) Error!void {
        try self.file.sync(self.io);
    }
};

test "pager round trip in a temp dir" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{}); // .zig-cache/tmp/<random>/ ; tmp.dir is an Io.Dir
    defer tmp.cleanup();

    {
        var pager: Pager = try .open(io, tmp.dir, "test.db");
        defer pager.close();
        try testing.expectEqual(0, pager.page_count);

        var page: Page = @splat(0);
        std.mem.writeInt(u32, page[0..4], 0xB7EE, .little);
        @memcpy(page[8..13], "hello");
        try pager.writePage(3, &page); // sparse write: pages 0..2 read back as zeroes
        try pager.sync();
        try testing.expectEqual(4, pager.page_count);
        try testing.expectEqual(4, try pager.allocPage());
    }

    // Reopen and read back.
    var pager: Pager = try .open(io, tmp.dir, "test.db");
    defer pager.close();
    try testing.expectEqual(5, pager.page_count);

    var page: Page = undefined;
    try pager.readPage(3, &page);
    try testing.expectEqual(0xB7EE, std.mem.readInt(u32, page[0..4], .little));
    try testing.expectEqualStrings("hello", page[8..13]);
    try pager.readPage(0, &page);
    try testing.expect(std.mem.allEqual(u8, &page, 0));
    try testing.expectError(error.ShortRead, pager.readPage(99, &page));
}

test "raw file API tour" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir: Io.Dir = tmp.dir; // Io.Dir.cwd() for the working directory

    // --- create (truncates, write-only by default) ---
    const f = try dir.createFile(io, "a.bin", .{ .read = true });
    // .exclusive = true -> error.PathAlreadyExists if it exists
    // .lock = .exclusive -> advisory file lock (single-writer database)

    // --- positional write (pwrite) ---
    try f.writePositionalAll(io, "0123456789", 0);
    try f.writePositionalAll(io, "AB", 4);
    // vectored: returns bytes written, may be short
    _ = try f.writePositional(io, &.{ "x", "y" }, 8);

    // --- positional read (pread) ---
    var buf: [10]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0); // n < buf.len means EOF
    try testing.expectEqualStrings("0123AB67xy", buf[0..n]);
    var small: [4]u8 = undefined;
    const m = try f.readPositional(io, &.{&small}, 8); // vectored, may be short
    try testing.expectEqual(2, m);

    // --- size / truncate / extend ---
    try testing.expectEqual(10, try f.length(io));
    try f.setLength(io, 4096); // ftruncate: grow (zero-filled) or shrink
    const st = try f.stat(io);
    try testing.expectEqual(4096, st.size);
    try testing.expectEqual(Io.File.Kind.file, st.kind);

    // --- durability ---
    try f.sync(io);
    f.close(io); // close cannot fail and takes io

    // --- reopen existing file ---
    const g = try dir.openFile(io, "a.bin", .{ .mode = .read_write }); // .read_only (default), .write_only
    defer g.close(io);
    try testing.expectError(error.FileNotFound, dir.openFile(io, "missing.bin", .{}));

    // --- rename (atomic replace), exists check, delete ---
    try dir.rename("a.bin", dir, "b.bin", io);
    try dir.access(io, "b.bin", .{});
    try testing.expectError(error.FileNotFound, dir.access(io, "a.bin", .{}));
    try dir.deleteFile(io, "b.bin");

    // --- directories ---
    try dir.createDirPath(io, "x/y/z");
    try dir.deleteTree(io, "x");
}

test "whole-file helpers and buffered sequential I/O (WAL-style append)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "small.txt", .data = "hello\nworld\n" });
    const contents = try tmp.dir.readFileAlloc(io, "small.txt", gpa, .limited(1 << 20));
    defer gpa.free(contents);
    try testing.expectEqualStrings("hello\nworld\n", contents);

    // Buffered sequential writer: File.Writer owns position + buffer; `.interface` is the *Io.Writer.
    const f = try tmp.dir.createFile(io, "wal.log", .{ .read = true });
    defer f.close(io);
    var wbuf: [256]u8 = undefined;
    var fw: Io.File.Writer = f.writer(io, &wbuf);
    const w: *Io.Writer = &fw.interface;
    try w.writeInt(u32, 0xCAFE, .little);
    try w.print("record {d}\n", .{1});
    try w.flush(); // required before sync / reading back
    try f.sync(io);

    // Buffered sequential reader: `.interface` is the *Io.Reader.
    var rbuf: [256]u8 = undefined;
    var fr: Io.File.Reader = f.reader(io, &rbuf);
    const r: *Io.Reader = &fr.interface;
    try testing.expectEqual(0xCAFE, try r.takeInt(u32, .little));
    const line = (try r.takeDelimiter('\n')).?; // null at EOF
    try testing.expectEqualStrings("record 1", line);
    try testing.expectError(error.EndOfStream, r.takeByte());
}
```

---

## 8. Randomness, testing, generics, errors, pointers, `@branchHint`, SIMD, threads, atomics

Locations (verified): `std.Random` (`DefaultPrng` = Xoshiro256, `.init(seed: u64)`, `.random()`),
`std.testing.random_seed`, `std.Thread.spawn(.{}, fn, args)` / `.join()` / `std.Thread.getCpuCount()`,
`std.Io.Mutex`, `std.Io.RwLock`, `std.Io.Condition`, `std.Io.Event`, `std.Io.Semaphore`, `std.Io.Group`,
`std.Io.Queue(T)`, `io.async(fn, args)` returning a future with `.await(io)`, `std.atomic.Value(T)`,
`std.atomic.cache_line`, `std.atomic.Mutex` (a bare try-lock spin flag: `tryLock()`/`unlock()`).
`std.Thread` no longer contains any synchronisation primitives.

Lock API: `var m: Io.Mutex = .init;` `m.lockUncancelable(io)` or `try m.lock(io)` (can return
`error.Canceled`), `m.unlock(io)`, `m.tryLock()` (no `io`).
`var rw: Io.RwLock = .init;` `lockShared(io)` / `lockSharedUncancelable(io)` / `unlockShared(io)` /
`tryLockShared(io)`, `lock(io)` / `lockUncancelable(io)` / `unlock(io)` / `tryLock(io)`.

Testing: `expect(bool)`, `expectEqual(expected, actual)`, `expectEqualSlices(T, expected, actual)`,
`expectEqualStrings`, `expectError(expected_error, actual_error_union)`, `expectEqualDeep`,
`expectApproxEqAbs`, `expectFmt`, `std.testing.allocator`, `std.testing.io`, `std.testing.tmpDir`,
`std.testing.checkAllAllocationFailures`, `std.testing.fuzz(context, testOne, .{})` with
`fn testOne(context, smith: *std.testing.Smith) !void` (run with `zig build test --fuzz`).

```zig
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
            return if (p == .none) null else @backingInt(p);
        }
    };
    const p: PageNo = @fromBackingInt(@intCast(7));
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
```

---

## 9. What changed: old idioms that fail under 0.17.1, with the exact error

Each row was compiled; the middle column is the compiler's message.

### std: I/O, files, process

| Old code | Error from 0.17.1 | Replacement |
|---|---|---|
| `std.io.getStdOut().writer()`, `std.io.bufferedWriter(..)`, `std.io.fixedBufferStream(&buf)` | `root source file struct 'std' has no member named 'io'` | `std.Io.File.Writer` + `.interface`; `std.Io.Writer.fixed(&buf)`; `std.Io.Reader.fixed(bytes)` |
| `std.fs.File.stdout()` | `struct 'fs' has no member named 'File'` | `std.Io.File.stdout()` |
| `std.fs.cwd()` | `struct 'fs' has no member named 'cwd'` | `std.Io.Dir.cwd()` |
| `dir.createFile("x", .{})`, `f.close()` | `member function expected 3 argument(s), found 2` | add `io`: `dir.createFile(io, "x", .{})`, `f.close(io)` |
| `f.pwriteAll(bytes, off)`, `f.pread(..)` | `no field or member function named 'pwriteAll' in 'Io.File'` | `f.writePositionalAll(io, bytes, off)`, `f.readPositionalAll(io, buf, off)` |
| `f.seekTo(0)`, `f.getEndPos()` | `no field or member function named 'seekTo' in 'Io.File'` | positional calls; `f.length(io)`; seeking lives on `File.Reader`/`File.Writer` |
| `list.writer()` on `ArrayList(u8)` | `no field or member function named 'writer'` | `list.print(gpa, fmt, args)` or `std.Io.Writer.Allocating` |
| `fn f(w: std.Io.Writer)` / `var c = fw.interface;` | compiles; output silently lost (`expected "x", found ""`) | always pass `*std.Io.Writer`, take `&fw.interface` |
| `std.process.argsAlloc(gpa)`, `std.process.args()` | `struct 'process' has no member named 'argsAlloc'` | `init.minimal.args.toSlice(arena)` or `init.minimal.args.iterate()` |
| `std.process.getEnvVarOwned(gpa, "HOME")` | `no member named 'getEnvVarOwned'` | `init.environ_map.get("HOME")` |
| `std.os.getpid()`, `std.posix.pread` | `struct 'os' has no member named 'getpid'`, `struct 'posix' has no member named 'pread'` | use `std.Io`; raw syscalls only via `std.os.linux.*` |
| `std.time.Timer.start()` | `struct 'time' has no member named 'Timer'` | `std.Io.Clock.awake.now(io)` + `untilNow(io, .awake)` |
| `std.time.milliTimestamp()` | `no member named 'milliTimestamp'` | `std.Io.Clock.real.now(io).toMilliseconds()` |
| `std.Thread.sleep(ns)` / `std.time.sleep` | `struct 'Thread' has no member named 'sleep'` | `try io.sleep(.fromMilliseconds(n), .awake)` |
| `std.crypto.random.int(u32)`, `std.posix.getrandom(&b)` | `struct 'crypto' has no member named 'random'` | `io.random(&bytes)` |
| `std.rand.DefaultPrng` | `struct 'std' has no member named 'rand'` | `std.Random.DefaultPrng` |

### std: formatting

| Old code | Error | Replacement |
|---|---|---|
| `"{}"` with a `[]const u8` | `cannot format slice without a specifier (i.e. {s}, {x}, {b64}, or {any})` | `{s}` |
| `"{s}"` with an enum | `invalid format string 's' for type 'math.Order'` | `{t}` (or `{s}` with `@tagName(e)`) |
| `"{d}"` with a pointer | `invalid format string 'd' for type '*const u32'` | `{*}` or `{x}` with `@intFromPtr(p)` |
| `pub fn format(self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype)` | `struct 'fmt' has no member named 'FormatOptions'` | `pub fn format(self: T, w: *std.Io.Writer) std.Io.Writer.Error!void` + `{f}` |
| `std.fmt.fmtSliceHexLower(bytes)` | `no member named 'fmtSliceHexLower'` | `{x}` on the byte slice |

### std: allocators

| Old code | Error | Replacement |
|---|---|---|
| `std.heap.GeneralPurposeAllocator(.{}){}` | `struct 'heap' has no member named 'GeneralPurposeAllocator'` | `std.heap.SafeAllocator` (or `init.gpa`) |
| `std.heap.stackFallback(256, gpa)` | `no member named 'stackFallback'` | `std.heap.BufferFirstAllocator.init(&buf, gpa)` |
| `gpa.alignedAlloc(u8, 4096, n)` | `expected type '?mem.Alignment', found 'comptime_int'` | `.fromByteUnits(4096)` |
| `gpa.dupeZ(u8, s)` | `no field or member function named 'dupeZ' in 'mem.Allocator'` | `gpa.dupeSentinel(u8, s, 0)` |
| vtable fn `(ctx, len, ptr_align: u8, ret_addr)`; vtable without `.remap` | `parameter 2 'u8' cannot cast into 'mem.Alignment'` | signatures in section 4; all four fields required |
| `std.heap.loggingAllocator`, `ThreadSafeAllocator`, `raw_c_allocator` | `no member named ...` | write a wrapper (section 4a); `smp_allocator`/`SafeAllocator` are thread-safe; `c_allocator` |
| `std.heap.MemoryPool(T).init(gpa)`, `pool.create()` | `has no member named 'init'` | `.empty`, `pool.create(gpa)`, `pool.deinit(gpa)` |
| `std.heap.MemoryPoolExtra(T, .{})` | `no member named 'MemoryPoolExtra'` | `std.heap.memory_pool.Extra(T, .{})` |
| `std.mem.page_size`, `std.heap.page_size` | `no member named 'page_size'` | `std.heap.page_size_min` (comptime), `std.heap.pageSize()` (runtime) |

### std: containers, sync, mem

| Old code | Error | Replacement |
|---|---|---|
| `std.ArrayList(u32).init(gpa)` | `struct 'array_list.Aligned(u32,null)' has no member named 'init'` | `.empty` + allocator per call |
| `var l: std.ArrayListUnmanaged(u32) = .{};` | `missing struct field: items` | `.empty` |
| `list.popOrNull()` | `no field or member function named 'popOrNull'` | `list.pop()` returns `?T` |
| `std.BoundedArray(u8, 4)` | `struct 'std' has no member named 'BoundedArray'` | `ArrayList.initBuffer(&buf)` + `appendBounded` |
| `std.SegmentedList(u8, 4)` | `no member named 'SegmentedList'` | chunk list (section 5) |
| `std.DoublyLinkedList(u32){}` | `type 'type' not a function` | intrusive `std.DoublyLinkedList` |
| `std.PriorityQueue(..).init(gpa, {})`, `q.add(x)`, `q.remove()` | `has no member named 'init'`, `no field or member function named 'remove'` | `.empty`, `push(gpa, x)`, `pop()` |
| `std.AutoArrayHashMap(K, V).init(gpa)` | `struct 'std' has no member named 'AutoArrayHashMap'` | `std.array_hash_map.Auto(K, V)` = `.empty` |
| `std.StaticBitSet(128).initEmpty()` | `has no member named 'initEmpty'` | `.empty` / `.full` |
| `std.Thread.Mutex`, `std.Thread.RwLock`, `std.Thread.Pool` | `struct 'Thread' has no member named 'Mutex'` | `std.Io.Mutex`, `std.Io.RwLock`, `io.async` / `std.Io.Group` |
| `m.lock()` on `Io.Mutex` | `member function expected 1 argument(s), found 0` | `m.lockUncancelable(io)` / `try m.lock(io)`; `m.unlock(io)` |
| `v.fetchAdd(1, .SeqCst)` | `enum 'lang.AtomicOrder' has no member named 'SeqCst'` | `.seq_cst`, `.monotonic`, `.acquire`, `.release`, `.acq_rel` |
| `std.mem.writeInt(u32, &b, 1, .Little)` | `enum 'lang.Endian' has no member named 'Little'` | `.little` / `.big` |
| `std.mem.writeIntLittle(u32, &b, 1)` | `struct 'mem' has no member named 'writeIntLittle'` | `std.mem.writeInt(u32, &b, 1, .little)` |
| `std.mem.readInt(u32, slice[0..], .little)` | `coercion from slice to array pointer type '*const [4]u8' requires length to be known at compile-time` | `slice[off..][0..4]` |
| `std.mem.copy(u8, d, s)`, `std.mem.set(u8, d, 0)` | `struct 'mem' has no member named 'copy'` | `@memcpy(d[0..s.len], s)`, `@memmove`, `@memset` |
| `std.sort.sort(T, items, {}, lt)` | `struct 'sort' has no member named 'sort'` | `std.mem.sort` (stable), `std.mem.sortUnstable` |
| `std.sort.binarySearch(T, key, items, ctx, cmp)` | `expected 4 argument(s), found 5` | `binarySearch(T, items, key_as_context, cmp)` with `cmp(key, item)` |
| `std.math.max(a, b)` | `struct 'math' has no member named 'max'` | `@max(a, b)`, `@min(a, b)` |
| `std.hash.crc.Crc32` | `struct 'hash.crc' has no member named 'Crc32'` | `std.hash.Crc32.hash(bytes)` |
| `std.meta.fields(T)` | `deprecated in favor of @typeInfo` | `@typeInfo(T).@"struct".field_names` / `std.meta.fieldNames(T)` |

Still valid (checked): `std.mem.indexOfScalar` / `indexOf` (aliases of `findScalar` / `find`),
`std.AutoHashMapUnmanaged(K, V) = .{}` and `std.heap.DebugAllocator(.{}) = .{}` (default field values),
`std.builtin.Endian` (alias of `std.lang.Endian`), `std.json.Stringify.valueAlloc`.

### Language

| Old code | Error | Replacement |
|---|---|---|
| `@intCast(u32, x)`, `@ptrCast(*u32, &x)` | `expected 1 argument, found 2` | result type from context / `@as(u32, @intCast(x))` |
| `@enumToInt(e)`, `@intToEnum`, `@intToPtr`, `@ptrToInt`, `@boolToInt` | `invalid builtin function: '@enumToInt'` | `@intFromEnum`, `@enumFromInt`, `@ptrFromInt`, `@intFromPtr`, `@intFromBool` |
| `@Type(.{ .int = ... })` | `invalid builtin function: '@Type'` | `@Int(.unsigned, 7)`, `@Struct(...)`, `@Enum(...)`, `@Union(...)`, `@Tuple(&.{ ... })` |
| `@typeInfo(T).Struct.fields` | `no field named 'Struct' in union 'lang.Type'` | `.@"struct"`, `.int`, `.pointer`, `.@"enum"`, `.@"union"`, `.@"fn"`, `.optional`, `.array` |
| `@typeInfo(T).@"struct".fields` | `no field named 'fields' in struct 'lang.Type.Struct'` | `.field_names`, `.field_types`, `.field_attrs` (parallel slices) |
| `@setCold(true)` | `invalid builtin function: '@setCold'` | `@branchHint(.cold)` as first statement |
| `@fieldParentPtr(T, "n", ptr)` | `expected 2 arguments, found 3` | `const p: *T = @fieldParentPtr("n", ptr);` |
| `callconv(.C)` | `union 'lang.CallingConvention' has no member named 'C'` | `callconv(.c)` |
| `builtin.mode == .Debug` | `no field named 'Debug' in enum 'lang.Optimize'` | `.debug` / `.safe` / `.fast` / `.small` |
| `for (a) \|x, i\|` | `extra capture in for loop` | `for (a, 0..) \|x, i\|` |
| `usingnamespace A;` | parse error (`expected ',' after field`) | removed from the language; re-export declarations explicitly |
| `async f()` / `await` keywords | parse error (`expected ';' after statement`) | `io.async(f, .{args})`, `future.await(io)` |
| `var x: u32 = 1;` never modified | `local variable is never mutated` / `consider using 'const'` | `const` |
| `const x = 1;` unused | `unused local constant` | use it or `_ = x;` |
| `_ = x;` and then using `x` | `pointless discard of local constant` | remove the discard |
| local named like an outer decl | `local constant shadows declaration of 'x'` | rename |
| `switch (err)` missing a case | `switch must handle all possibilities` / `unhandled error value: 'error.B'` | add the case or `else => \|e\| return e` |
| `const p: *u32 = @ptrCast(&bytes);` | `@ptrCast increases pointer alignment` / `use @alignCast to assert pointer alignment` | `@ptrCast(@alignCast(..))` or `*align(1) u32` |
| `packed struct { a: [2]u8 }` | `packed structs cannot contain fields of type '[2]u8'` | `extern struct` |

### Build system

| Old code | Error | Replacement |
|---|---|---|
| `b.addExecutable(.{ .name, .root_source_file, .target, .optimize })` | `no field named 'root_source_file' in struct 'Build.ExecutableOptions'` | `.root_module = b.createModule(.{ ... })` |
| `exe.linkLibC()` | `no field or member function named 'linkLibC' in 'Build.Step.Compile'` | `.link_libc = true` in the module options, or `exe.root_module.link_libc = true` |
| `if (b.args) \|args\| run.addArgs(args);` | `no field named 'args' in struct 'Build'` | `run_cmd.addPassthruArgs();` |
| `build.zig.zon` with `.name = "x"` | `expected enum literal` | `.name = .x` |
| `build.zig.zon` without `.fingerprint` | `missing top-level 'fingerprint' field; suggested value: 0x...` | paste the suggested value |

Compiled forms of the replacements that are not shown in earlier sections:

```zig
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
```

---

## 10. Rust conventions (rustc/cargo 1.97.0)

Template crate: `_template/rust/` (`cargo test`: 9 tests pass; `cargo run`; `cargo clippy --all-targets -- -D warnings`
and `cargo fmt --check` clean).

* **Edition 2024, std only.** `Cargo.toml` has an empty `[dependencies]`. No `rand`, `tempfile`, `bytemuck`:
  the template has a SplitMix64 PRNG (`src/rng.rs`) and a `TempDir` helper (`tests/pager_roundtrip.rs`).
* **Layout:** `src/lib.rs` (library, modules), `src/bin/<name>.rs` (binary using the library),
  `tests/*.rs` (integration tests, public API only), unit tests in each module under
  `#[cfg(test)] mod tests { use super::*; #[test] fn ...() {} }`. Tests may return `io::Result<()>`;
  expected panics use `#[should_panic(expected = "...")]`.
* **No `unsafe`** (`[lints.rust] unsafe_code = "forbid"` in `Cargo.toml`). Only a chapter that is explicitly
  about memory layout may relax this, locally and with a `// SAFETY:` comment.
* **Nodes: arena + indices** (`src/arena.rs`). `Arena<T>` is a `Vec<Slot<T>>` with a slab-style free list
  (`Slot::Free { next_free }`); nodes refer to each other with `NodeId(u32)`. `arena.alloc(node) -> NodeId`,
  `arena.free(id) -> T`, `arena[id]`, `arena.get(id) -> Option<&T>`, and
  `arena.get_pair_mut(a, b)` (built on `slice::get_disjoint_mut`, Rust 1.86+) for node + sibling during
  split/merge. This is the direct analogue of Zig's `MemoryPool` / `PagePool` and of on-disk page numbers.
  Do not use `Rc<RefCell<Node>>`.
* **`Box`** (`src/boxed.rs`) only for strictly top-down ownership (`enum Node { Leaf {..}, Internal { children: Vec<Box<Node>> } }`),
  i.e. no parent or sibling links.
* **Searching:** `slice.partition_point(|k| k < key)` is lower bound, `|k| k <= key` is upper bound,
  `slice.binary_search(&key)` returns `Ok(index)` or `Err(insertion_point)`.
* **Pages:** `type Page = [u8; 4096]`; fields via `u32::from_le_bytes(page[o..o + 4].try_into().unwrap())` and
  `page[o..o + 4].copy_from_slice(&v.to_le_bytes())`; shifting inside a page with `page.copy_within(src_range, dest)`
  (the `@memmove` analogue); `copy_from_slice` is the `@memcpy` analogue (lengths must match).
* **File I/O:** `std::os::unix::fs::FileExt`: `file.read_exact_at(&mut buf, offset)` /
  `file.write_all_at(&buf, offset)` (`read_at`/`write_at` are the single-call, possibly short forms),
  `file.sync_all()` (fsync) / `sync_data()`, opened with
  `OpenOptions::new().read(true).write(true).create(true).truncate(false)`.
* **Output:** `io::BufWriter::new(io::stdout().lock())` + `writeln!` + explicit `flush()`; diagnostics with `eprintln!`.
* **Errors:** `io::Result<T>` for I/O paths; a small `enum` implementing `std::error::Error` for tree errors; no `anyhow`.
* **Zig <-> Rust naming used across chapters:** `Allocator` param <-> arena owned by the tree; `?*Node` <-> `Option<NodeId>`;
  `[]const u8` <-> `&[u8]`; `error{...}!T` <-> `Result<T, E>`; `std.testing.allocator` leak check <-> `Arena::len() == 0` assertion;
  `defer x.deinit(gpa)` <-> `Drop`.

`Cargo.toml`:

```toml
[package]
name = "btree_template"
version = "0.1.0"
edition = "2024"
rust-version = "1.86" # slice::get_disjoint_mut
publish = false

# std only: no external dependencies.
[dependencies]

[lints.rust]
unsafe_code = "forbid" # relax per chapter only when the chapter is about memory layout

[lints.clippy]
all = { level = "warn", priority = -1 }

[profile.release]
debug = true # keep symbols for perf/flamegraphs
```

`src/arena.rs` (the node arena every chapter should start from):

```rust
//! Node arena: `Vec` storage + typed indices + a slab-style free list.
//!
//! This is the default way to model tree nodes in these examples. Indices are
//! `Copy`, 4 bytes, survive `Vec` reallocation, map 1:1 onto on-disk page
//! numbers, and avoid fighting the borrow checker over parent/sibling links.

/// Typed index of a node inside an [`Arena`]. `u32` keeps nodes compact.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct NodeId(u32);

impl NodeId {
    pub fn index(self) -> usize {
        self.0 as usize
    }
}

#[derive(Debug)]
enum Slot<T> {
    Occupied(T),
    /// Free slot; holds the next free slot, forming an intrusive free list.
    Free {
        next_free: Option<NodeId>,
    },
}

/// Slab allocator: O(1) alloc/free, slots are reused LIFO.
#[derive(Debug)]
pub struct Arena<T> {
    slots: Vec<Slot<T>>,
    free_head: Option<NodeId>,
    len: usize,
}

impl<T> Default for Arena<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> Arena<T> {
    pub fn new() -> Self {
        Self {
            slots: Vec::new(),
            free_head: None,
            len: 0,
        }
    }

    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            slots: Vec::with_capacity(capacity),
            free_head: None,
            len: 0,
        }
    }

    /// Number of live nodes.
    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn alloc(&mut self, value: T) -> NodeId {
        self.len += 1;
        match self.free_head {
            Some(id) => {
                let Slot::Free { next_free } = self.slots[id.index()] else {
                    unreachable!("free list points at an occupied slot");
                };
                self.free_head = next_free;
                self.slots[id.index()] = Slot::Occupied(value);
                id
            }
            None => {
                let id = NodeId(u32::try_from(self.slots.len()).expect("arena full"));
                self.slots.push(Slot::Occupied(value));
                id
            }
        }
    }

    /// Frees a slot and returns its value. Panics on double free.
    pub fn free(&mut self, id: NodeId) -> T {
        let slot = std::mem::replace(
            &mut self.slots[id.index()],
            Slot::Free {
                next_free: self.free_head,
            },
        );
        match slot {
            Slot::Occupied(value) => {
                self.free_head = Some(id);
                self.len -= 1;
                value
            }
            Slot::Free { next_free } => {
                // Undo the replace so the free list stays intact, then report the bug.
                self.slots[id.index()] = Slot::Free { next_free };
                panic!("double free of {id:?}");
            }
        }
    }

    pub fn get(&self, id: NodeId) -> Option<&T> {
        match self.slots.get(id.index())? {
            Slot::Occupied(value) => Some(value),
            Slot::Free { .. } => None,
        }
    }

    pub fn get_mut(&mut self, id: NodeId) -> Option<&mut T> {
        match self.slots.get_mut(id.index())? {
            Slot::Occupied(value) => Some(value),
            Slot::Free { .. } => None,
        }
    }

    /// Two distinct nodes mutably at once (e.g. node + sibling during a split).
    pub fn get_pair_mut(&mut self, a: NodeId, b: NodeId) -> Option<(&mut T, &mut T)> {
        let [x, y] = self.slots.get_disjoint_mut([a.index(), b.index()]).ok()?;
        match (x, y) {
            (Slot::Occupied(x), Slot::Occupied(y)) => Some((x, y)),
            _ => None,
        }
    }
}

/// `arena[id]` panics on a stale id, like slice indexing.
impl<T> std::ops::Index<NodeId> for Arena<T> {
    type Output = T;
    fn index(&self, id: NodeId) -> &T {
        self.get(id).expect("stale NodeId")
    }
}

impl<T> std::ops::IndexMut<NodeId> for Arena<T> {
    fn index_mut(&mut self, id: NodeId) -> &mut T {
        self.get_mut(id).expect("stale NodeId")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Default)]
    struct Node {
        keys: Vec<u64>,
        children: Vec<NodeId>,
        next_leaf: Option<NodeId>,
    }

    #[test]
    fn alloc_free_reuse() {
        let mut arena: Arena<Node> = Arena::new();
        let a = arena.alloc(Node::default());
        let b = arena.alloc(Node {
            keys: vec![1, 2],
            ..Node::default()
        });
        assert_eq!(arena.len(), 2);

        let freed = arena.free(a);
        assert!(freed.keys.is_empty());
        assert!(arena.get(a).is_none());

        let c = arena.alloc(Node::default());
        assert_eq!(c, a, "freed slot is reused");
        assert_eq!(arena[b].keys, [1, 2]);
    }

    #[test]
    fn link_nodes_by_index() {
        let mut arena: Arena<Node> = Arena::with_capacity(3);
        let left = arena.alloc(Node {
            keys: vec![1, 2],
            ..Node::default()
        });
        let right = arena.alloc(Node {
            keys: vec![5, 6],
            ..Node::default()
        });
        let root = arena.alloc(Node {
            keys: vec![5],
            children: vec![left, right],
            next_leaf: None,
        });
        arena[left].next_leaf = Some(right);

        // Move a key between siblings: needs both nodes mutably.
        let (l, r) = arena.get_pair_mut(left, right).unwrap();
        l.keys.push(r.keys.remove(0));
        arena[root].keys[0] = 6;

        assert_eq!(arena[left].keys, [1, 2, 5]);
        assert_eq!(arena[arena[root].children[1]].keys, [6]);
        assert!(arena.get_pair_mut(left, left).is_none());
    }

    #[test]
    #[should_panic(expected = "double free")]
    fn double_free_panics() {
        let mut arena: Arena<u8> = Arena::new();
        let id = arena.alloc(1);
        arena.free(id);
        arena.free(id);
    }
}
```

`src/pager.rs`:

```rust
//! Fixed-size page file using positional I/O (`pread`/`pwrite`) from
//! `std::os::unix::fs::FileExt`: no shared seek cursor, `&self` methods.

use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::fs::FileExt;
use std::path::Path;

pub const PAGE_SIZE: usize = 4096;
pub type Page = [u8; PAGE_SIZE];

#[derive(Debug)]
pub struct Pager {
    file: File,
    page_count: u64,
}

impl Pager {
    /// Opens (creating if missing) a page file for reading and writing.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)?;
        let len = file.metadata()?.len();
        if len % PAGE_SIZE as u64 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "file is not a whole number of pages",
            ));
        }
        Ok(Self {
            file,
            page_count: len / PAGE_SIZE as u64,
        })
    }

    pub fn page_count(&self) -> u64 {
        self.page_count
    }

    /// `read_exact_at` = loop over `pread` until the buffer is full
    /// (`UnexpectedEof` if the page does not exist).
    pub fn read_page(&self, page_no: u64, out: &mut Page) -> io::Result<()> {
        self.file.read_exact_at(out, page_no * PAGE_SIZE as u64)
    }

    /// `write_all_at` = loop over `pwrite`; extends the file if needed.
    pub fn write_page(&mut self, page_no: u64, page: &Page) -> io::Result<()> {
        self.file.write_all_at(page, page_no * PAGE_SIZE as u64)?;
        self.page_count = self.page_count.max(page_no + 1);
        Ok(())
    }

    pub fn alloc_page(&mut self) -> io::Result<u64> {
        let page_no = self.page_count;
        self.write_page(page_no, &[0; PAGE_SIZE])?;
        Ok(page_no)
    }

    /// fsync (data + metadata). `sync_data` is fdatasync.
    pub fn sync(&self) -> io::Result<()> {
        self.file.sync_all()
    }
}

/// Little-endian field access inside a page, without `unsafe`.
pub fn read_u32(page: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(page[offset..offset + 4].try_into().expect("4 bytes"))
}

pub fn write_u32(page: &mut [u8], offset: usize, value: u32) {
    page[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn le_fields_and_shifts() {
        let mut page = [0u8; PAGE_SIZE];
        write_u32(&mut page, 8, 0xDEAD_BEEF);
        assert_eq!(page[8..12], [0xEF, 0xBE, 0xAD, 0xDE]);
        assert_eq!(read_u32(&page, 8), 0xDEAD_BEEF);

        // Overlapping move inside one buffer (Zig: @memmove): open a gap at 100..104.
        page.copy_within(100..200, 104);
        // Non-overlapping copy between buffers (Zig: @memcpy).
        let mut other = [0u8; PAGE_SIZE];
        other[..12].copy_from_slice(&page[..12]);
        assert_eq!(read_u32(&other, 8), 0xDEAD_BEEF);
    }
}
```

Commands: `cargo test`, `cargo test fuzz_against_model` (name filter), `cargo test -- --nocapture`,
`cargo run -- arg1 arg2`, `cargo run --release`, `cargo clippy --all-targets -- -D warnings`, `cargo fmt`.

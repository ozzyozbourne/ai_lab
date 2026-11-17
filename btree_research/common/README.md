# common/ — tiny shared pieces that chapters copy

Four small modules, each written twice (Zig and Rust) so that both languages
produce **bit-identical** results. `golden.txt` pins those results; a test in
each language regenerates it byte for byte.

| Purpose | Zig | Rust |
|---|---|---|
| SplitMix64 PRNG | `zig/prng.zig` | `rust/prng.rs` |
| Operation stream + reference oracle | `zig/ops.zig` | `rust/ops.rs` |
| CRC-32 (IEEE) | `zig/crc32.zig` | `rust/crc32.rs` |
| Hexdump | `zig/hexdump.zig` | `rust/hexdump.rs` |

Every one of these files depends on `std` only and on no other file (`ops`
carries a private copy of the SplitMix64 step). The other files (`root.zig`,
`golden_test.zig`, `build.zig*`, `lib.rs`, `golden_test.rs`, `Cargo.toml`)
exist only to test `common/` itself and are **not** copied.

```
cd common/zig  && zig build test        # 14 tests
cd common/rust && cargo test            # 11 tests
cd common/rust && cargo clippy --all-targets -- -D warnings
```

## How a chapter uses it

Chapters never import across projects. Copy the file into the chapter's
`src/`, keep its name, and put this line first:

```
// Copied from common/zig/prng.zig; do not edit here
```

(`common/rust/prng.rs` for Rust, and so on.) Fixes go into `common/` first and
are then re-copied. Trimming unused functions from a copy is allowed; changing
behaviour is not.

Zig: `const SplitMix64 = @import("prng.zig").SplitMix64;`. The copied file's
own tests only run if the file is reachable from a `test` block of your root
file: `test { _ = @import("prng.zig"); }`.

Rust: `mod prng;` in `main.rs` / `lib.rs`, then `use crate::prng::SplitMix64;`.
The copies contain no `crate::` paths, so they work in any module position.
Items you do not call trigger `dead_code` warnings in a binary crate (and fail
`clippy -D warnings`): either trim them or declare `#[allow(dead_code)] mod prng;`.

## API

### prng — SplitMix64

| | Zig | Rust |
|---|---|---|
| create | `SplitMix64.init(seed: u64) SplitMix64` | `SplitMix64::new(seed: u64) -> SplitMix64` |
| 64 random bits | `nextU64(self: *SplitMix64) u64` | `next_u64(&mut self) -> u64` |
| integer in `[0, n)` | `below(self, n: u64) u64` | `below(&mut self, n: u64) -> u64` |
| integer in `[lo, hi)` | `range(self, lo: u64, hi: u64) u64` | `range(&mut self, lo: u64, hi: u64) -> u64` |
| true with probability num/den | `chance(self, numerator: u64, denominator: u64) bool` | `chance(&mut self, numerator: u64, denominator: u64) -> bool` |
| shuffle in place | `shuffle(self, items: []u64) void` | `shuffle(&mut self, items: &mut [u64])` |

- `below(n)` is multiply-high: the top 64 bits of the 128-bit product
  `nextU64() * n`. One draw per call, no rejection loop; bias at most n / 2^64.
- `range(lo, hi) = lo + below(hi - lo)`; `chance(a, b) = below(b) < a`.
- `shuffle` is Fisher-Yates from the last index down: for `i = len-1 .. 1`,
  swap `items[i]` with `items[below(i + 1)]`.
- Preconditions `n > 0`, `lo < hi`, `denominator > 0`: `std.debug.assert` in
  Zig, `assert!` (panic) in Rust.

### ops — operation stream and oracle

| | Zig | Rust |
|---|---|---|
| operation | `Op = union(enum) { put: {key, value}, delete: {key}, get: {key}, range: {lo, hi} }` | `enum Op { Put { key, value }, Delete { key }, Get { key }, Range { lo, hi } }` |
| weights | `Weights { put: u32 = 4, delete: u32 = 2, get: u32 = 3, range: u32 = 1 }` | `Weights { put, delete, get, range: u32 }`, `Weights::default()` = 4, 2, 3, 1 |
| config | `Config { seed: u64, count: u64, key_space: u64, weights: Weights = .{} }` | `Config { seed: u64, count: u64, key_space: u64, weights: Weights }` |
| create | `OpStream.init(config: Config) OpStream` | `OpStream::new(config: Config) -> OpStream` |
| next op | `next(self: *OpStream) ?Op` | `impl Iterator<Item = Op>` (`next(&mut self) -> Option<Op>`) |
| entry | `Entry { key: u64, value: u64 }` | `Entry { key: u64, value: u64 }` |
| oracle | `var o: Oracle = .{};` + `o.deinit(allocator)` | `Oracle::new()` |
| lookup | `get(self: *const Oracle, key: u64) ?u64` | `get(&self, key: u64) -> Option<u64>` |
| insert / overwrite, returns old value | `put(self: *Oracle, allocator: std.mem.Allocator, key: u64, value: u64) !?u64` | `put(&mut self, key: u64, value: u64) -> Option<u64>` |
| remove, returns removed value | `delete(self: *Oracle, key: u64) ?u64` | `delete(&mut self, key: u64) -> Option<u64>` |
| entries with `lo <= key < hi`, ascending | `range(self: *const Oracle, lo: u64, hi: u64) []const Entry` | `range(&self, lo: u64, hi: u64) -> &[Entry]` |
| size | `len(self: *const Oracle) usize` | `len(&self) -> usize`, `is_empty(&self) -> bool` |

- Keys are in `[0, key_space)`; put values are full random `u64`.
- A generated `range` is the half-open interval `[lo, hi)` with
  `lo < hi <= key_space` (`lo = min(a, b)`, `hi = max(a, b) + 1`), so it is
  never empty as an interval and can include the largest key.
- `Oracle.range` returns a slice borrowed from the oracle: use it before the
  next `put` / `delete`. `lo >= hi` gives an empty slice.
- Only `Oracle.put` allocates in Zig.

Typical model test (Zig; Rust is the same with `for op in OpStream::new(cfg)` and `match`):

```zig
var oracle: ops.Oracle = .{};
defer oracle.deinit(allocator);
var stream = ops.OpStream.init(.{ .seed = 1, .count = 10_000, .key_space = 200 });
while (stream.next()) |op| switch (op) {
    .put => |p| { try tree.put(p.key, p.value); _ = try oracle.put(allocator, p.key, p.value); },
    .delete => |d| try std.testing.expectEqual(oracle.delete(d.key) != null, tree.delete(d.key)),
    .get => |g| try std.testing.expectEqual(oracle.get(g.key), tree.get(g.key)),
    .range => |r| try expectSameEntries(oracle.range(r.lo, r.hi), &tree, r.lo, r.hi),
};
```

### crc32

| | Zig | Rust |
|---|---|---|
| one shot | `crc32(bytes: []const u8) u32` | `crc32(bytes: &[u8]) -> u32` |
| continue | `crc32Update(crc: u32, bytes: []const u8) u32` | `crc32_update(crc: u32, bytes: &[u8]) -> u32` |

IEEE CRC-32: reflected, polynomial `0xEDB88320`, init and final XOR
`0xFFFFFFFF`; `crc32("123456789") == 0xCBF43926`. The 256-entry table is built
at compile time (`comptime` block / `const fn`). `crc32Update(crc32(a), b)`
equals `crc32(a ++ b)`; start a chain with `crc = 0`. The Zig test also checks
it against `std.hash.Crc32`.

### hexdump

| | Zig | Rust |
|---|---|---|
| format | `hexdump(allocator: std.mem.Allocator, bytes: []const u8) ![]u8` (caller frees) | `hexdump(bytes: &[u8]) -> String` |

```
00000000  42 2d 74 72 65 65 20 70  61 67 65 00 01 02 03 04  |B-tree page.....|
00000020  15 16 17 18 19 1a 1b                              |.......|
```

16 bytes per line: 8-digit lowercase hex offset, two spaces, bytes as `xx `
with an extra space after the 8th (short lines padded), one space, then the
ASCII column between `|` (bytes outside `0x20..0x7e` shown as `.`). Every line
ends with `\n`; empty input gives an empty string. Unlike `hexdump -C` there is
no `*` squeezing of repeated lines and no final length line.

## golden.txt

Sections: the first 16 outputs of SplitMix64 for seeds 0, 1 and 42; 16 draws
each of `below`, `range` and `chance`; a 16-element shuffle; the first 20
operations for `seed=42 count=20 key_space=100 weights=3,2,2,2`; six CRCs; one
hexdump. `zig/golden_test.zig` reads it through an anonymous import set up in
`build.zig`; `rust/golden_test.rs` uses `include_str!`. If you ever change an
algorithm on purpose, both tests fail until `golden.txt` and both languages
agree again.

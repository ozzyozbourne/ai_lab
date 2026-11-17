# Chapter 11: solutions

## 1. Six integer keys by hand

Payloads only (every key also starts with the tag `01`, which does not
change the order).

| value | ASC: big-endian, sign bit flipped | DESC: the ASC bytes inverted |
|---|---|---|
| -1 | `7f ff ff ff ff ff ff ff` | `80 00 00 00 00 00 00 00` |
| 0 | `80 00 00 00 00 00 00 00` | `7f ff ff ff ff ff ff ff` |
| 1 | `80 00 00 00 00 00 00 01` | `7f ff ff ff ff ff ff fe` |

`memcmp` order of the six strings:

```
DESC(1)  <  ASC(-1) = DESC(0)  <  ASC(0) = DESC(-1)  <  ASC(1)
```

Two of them coincide pairwise. That is no accident: inverting all bits of a
two's complement number `v` gives `-v - 1`, so `DESC(v)` is the same bytes
as `ASC(-v - 1)`. It also shows why ASC and DESC encodings must never be
mixed in the same column: the bytes alone do not say which one was used.

## 2. Varints of 16384

16384 = 2^14 = `1 0000000 0000000` in 7-bit groups.

- LEB128, low group first: `80 80 01`.
- SQLite, high group first: `81 80 00`.

Both formats carry 14 payload bits in two bytes, so the largest two-byte
value is 2^14 - 1 = 16383 in both (`ff 7f` in both, by coincidence of the
all-ones pattern).

A `u64` has 64 bits. LEB128 always spends one bit per byte on the
continuation flag: nine bytes carry 63 bits, so the 64th bit needs a tenth
byte (which can only be `00` or `01`; `decode` reports `Overflow` for
anything else). SQLite's format says "if you get to a ninth byte, it has no
flag": 8 × 7 + 8 = 64 bits in nine bytes. The price is a special case in the
encoder and decoder, visible in `sqliteEncode` and `sqliteDecode`.

## 3. Length prefix against terminator

With a big-endian `u32` length prefix:

```
"b"   ->  00 00 00 01 62
"aa"  ->  00 00 00 02 61 61
```

The fourth byte decides: `01 < 02`, so `"b"` sorts before `"aa"`, but
lexicographically `"aa" < "b"`. A length prefix orders strings by length
first, which is not the order anyone asks for. (It is fine in a *record*,
where order does not matter: that is exactly what the serial type `n - 3`
is.)

Cost of the terminator scheme: one byte for the terminator, plus one byte
for each data byte that is `00` or `01`. Valid UTF-8 text contains those
bytes only as the control characters NUL and SOH, which ordinary text does
not use, so a typical string costs `len + 1` bytes, less than `len + 4`
with the prefix. The worst case is a string made only of `00` / `01` bytes:
`2 * len + 1`. `encodedBytesLen` computes the exact figure so callers can
reserve it.

## 4. `bool` and `u32` columns

Both are fixed-width, so they follow the pattern of `putFixed` with a
different width. Sketch in Zig:

```zig
pub fn putBool(self: *KeyWriter, v: bool, opts: ColumnOpts) EncodeError!void {
    const out = try self.reserve(2);
    out[0] = tag_value;
    out[1] = @intFromBool(v);          // false = 00 < true = 01
    if (opts.desc) invert(out[1..2]);
}

pub fn putU32(self: *KeyWriter, v: u32, opts: ColumnOpts) EncodeError!void {
    const out = try self.reserve(5);
    out[0] = tag_value;
    std.mem.writeInt(u32, out[1..5], v, .big);
    if (opts.desc) invert(out[1..5]);
}
```

The readers mirror `takeFixed`: check the tag, check that enough bytes
remain (otherwise `Truncated`, without moving the cursor), un-invert for
DESC, decode. `takeBool` should also reject payload bytes other than `00`
and `01` (after un-inverting), for the same reason `validateKey` rejects
`-0.0`: one value, one encoding.

Tests, in the style of the existing ones:

1. A list of edge values already in logical order; assert that every earlier
   element encodes to strictly smaller bytes than every later one, and that
   each round trips. For `u32`: 0, 1, 255, 256, 65535, 65536, 2^31 - 1, 2^31,
   2^32 - 1 (the byte boundaries, and 2^31 to catch an accidental signed
   conversion). For `bool`: false, true.
2. The NULL placement loop from "descending and NULL placement" for all four
   option combinations.
3. Add a column of each type to `model.schema` and a generator for it; the
   existing `checkPairs` then compares key order against `compareRows` for
   thousands of random pairs. This is the test that would catch a mistake in
   how the new column composes with its neighbours.

DuckDB's ART supports both: booleans are stored as one byte `1` / `0`
(`duckdb/src/include/duckdb/common/radix.hpp:161-164`) and all unsigned
widths as big-endian bytes.

## 5. Shortest separator

Let `i` be the first index at which `a` and `b` differ, or `a.len` if `a` is
a proper prefix of `b`. (One of the two must hold, because `a < b`.)
The answer is `b[0 .. i + 1]`.

```zig
/// Shortest s with a < s <= b. Requires a < b (as byte strings).
pub fn shortestSeparator(a: []const u8, b: []const u8) []const u8 {
    std.debug.assert(std.mem.order(u8, a, b) == .lt);
    var i: usize = 0;
    while (i < a.len and a[i] == b[i]) i += 1;   // i < b.len because a < b
    return b[0 .. i + 1];
}
```

Why it is correct:

- `s <= b`: `s` is a prefix of `b`, and a prefix never sorts after the
  string it is a prefix of.
- `a < s`: the first `i` bytes are equal. Either `a` has ended (then `a` is
  a proper prefix of `s`), or `a[i] < b[i] = s[i]` (it cannot be greater,
  since `a < b`).
- No shorter string works. Call the common first `i` bytes `p`. Any `s'`
  with `a < s' <= b` must itself start with `p`: if it left `p` earlier with
  a smaller byte (or ended inside `p`) it would sort before `a`, and with a
  larger byte it would sort after `b`. And `s'` cannot be exactly `p`,
  because `p <= a`. So `s'` has at least `i + 1` bytes.

For the people table: `a` = key of `("Ann", NULL, 4)`, `b` = key of
`("Anna", 256, 8)`. They share `01 41 6e 6e` and differ at index 4
(`00` against `61`), so the separator is the five bytes `01 41 6e 6e 61`:
"everything from `Anna` on goes right". The 24-byte key shrank to 5.

Note that the result is not a decodable key (the string column has no
terminator). That is fine: a separator only ever takes part in comparisons.

Why this is easy here and hard with a comparator: for byte-comparable keys
"order" *is* byte order, so cutting bytes off the end has a precise,
type-independent meaning. With a comparator the unit of truncation is a
whole column, because the comparator cannot compare half an integer or a
string cut in the middle of a collation element. That is what Postgres
does: suffix truncation removes whole trailing attributes and treats the
missing ones as minus infinity (`_bt_compare`,
`postgres/src/backend/access/nbtree/nbtsearch.c:784-795`). Chapter 17 builds
on this.

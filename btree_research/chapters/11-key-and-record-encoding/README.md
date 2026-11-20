# Chapter 11. Key and record encoding

Previous: [10 slotted pages](../10-slotted-pages/README.md) ·
Next: [12 disk-backed B+tree](../12-disk-backed-bplus-tree/README.md) ·
Visualization: [viz/index.html](viz/index.html)

## What you will learn

- How a row of typed values becomes the bytes that a slotted-page cell holds.
- Varints: why they exist, how LEB128 and the SQLite varint differ, and why
  neither can be used as a sort key.
- The two ways a B-tree can order its keys: call a **comparator** that
  understands the columns, or store **byte-comparable** keys and compare with
  `memcmp`.
- How to build byte-comparable keys for integers, floats, strings, composite
  keys, NULLs and descending columns, and the one property that tells you the
  encoding is right: *encoded order equals logical order*.

Prerequisites: chapter 02 (a node is searched by comparing keys) and chapter
10 (a cell is a run of bytes inside a page). Two's complement and IEEE 754
doubles are recalled where they are used.

## The idea in plain words

Up to chapter 8 a key was a `u64` compared with `<`. On disk a key is a
byte string inside a cell, and the row behind it has typed columns.

**How do I store a row compactly?** Most integers are small and most strings
are short, so fixed-width fields waste space. A *record* stores, for each
column, a small type code and then only as many bytes as the value needs.
The lengths and small integers inside it are *varints*: integers written in
1 byte when they are small and more bytes only when they are large.

**How does the tree compare two keys?** There are two answers, and real
systems are split between them.

1. *Comparator-based.* Keys are stored in whatever compact format is
   convenient (a record). To compare two keys the tree decodes column 1 of
   each and compares; on a tie it goes on to column 2, and so on. The
   comparator needs the schema: types, ASC or DESC, where NULLs go, which
   collation. Postgres and Turso work this way.
2. *Byte-comparable.* The encoder is designed so that comparing two encoded
   keys byte by byte, as unsigned bytes, gives the same answer the comparator
   would have given. The tree then needs no schema at all: one `memcmp` per
   comparison, and the same code handles every key type. DuckDB's ART index
   works this way (a radix tree has no choice: it *is* the bytes).
   TigerBeetle gets the same effect without bytes: it packs the columns into
   one wide integer and compares integers.

The second approach moves all the cleverness into the encoder. What goes
wrong when you encode naively, and the fix for each:

| Value | Naive encoding | What breaks | Fix |
|---|---|---|---|
| unsigned int | little-endian | the first byte compared is the least significant | big-endian |
| signed int | big-endian two's complement | negatives have the top bit set, so they sort after positives | flip the sign bit |
| float | IEEE bits, big-endian | same sign problem, and among negatives a larger bit pattern is a *smaller* number | positives: set the sign bit; negatives: invert all bits |
| string | raw bytes | in a composite key, column boundaries disappear | terminator byte, with escaping for data bytes that look like it |
| NULL | nothing | indistinguishable from an empty value | one tag byte per column |
| DESC column | (same as ASC) | wrong direction | invert every payload byte |
| varint | as is | LEB128 is little-endian (low group first); the SQLite varint is big-endian, but a longer encoding can start with a smaller byte | do not use varints in keys |

The price: byte-comparable keys are bigger (every integer takes 8 bytes plus
a tag), they need the schema to be decoded, and some orders cannot be
expressed as bytes without extra work (language-aware collations).

## A worked example by hand

Schema: `(name ASC, score DESC NULLS LAST, id ASC)`. Row: `("Ann", -2, 3)`.

**As a byte-comparable key.** Each column is a tag byte followed by a
payload. Tags: `00` NULL when NULLS FIRST, `01` "a value follows", `02` NULL
when NULLS LAST. That is why the value tag is `01` and not `00`.

- `name = "Ann"`: tag `01`, then the bytes `41 6e 6e`, then the terminator
  `00`. No byte of "Ann" is `00` or `01`, so nothing is escaped.
  → `01 41 6e 6e 00`
- `score = -2`, descending:
  - two's complement, big-endian: `ff ff ff ff ff ff ff fe`
  - flip the sign bit (`ff` → `7f`): `7f ff ff ff ff ff ff fe`
  - DESC: invert every byte: `80 00 00 00 00 00 00 01`
  - with the tag (not inverted): `01 80 00 00 00 00 00 00 01`
- `id = 3`: `00 .. 03` → sign flip → `80 00 00 00 00 00 00 03`, tag `01`.

Key, 23 bytes:
`01 41 6e 6e 00 | 01 80 00 00 00 00 00 00 01 | 01 80 00 00 00 00 00 00 03`

Compare it with the key of `("Ann", 7, 2)`. The name columns are identical.
For `score = 7`: `00..07` → `80 00 .. 07` → inverted `7f ff ff ff ff ff ff f8`.
The first differing byte is `7f` against `80`, so `("Ann", 7, 2)` sorts
first: 7 before -2, which is what DESC asks for. A row with `score = NULL`
has the single tag byte `02` in that position; `02 > 01`, so it sorts after
every non-NULL score.

A float column (section 3 of the output). A double is 1 sign bit, 11
exponent bits, 52 fraction bits: sign-magnitude, exponent above fraction. So
among non-negative doubles a larger bit pattern is a larger number, and
among negative ones it is the reverse.

- `1.5` is `3f f8 00 ..`; set the sign bit: `bf f8 00 ..`
- `-1.5` is `bf f8 00 ..`; invert every bit: `40 07 ff ..`

So -1.5 sorts before 1.5, and `-inf` (`ff f0 00 ..`, the largest negative
pattern) becomes `00 0f ff ..`, the smallest key.

Why the terminator? Take two columns of text. Concatenating raw bytes turns
both `("a", "b")` and `("ab", "")` into `61 62`. With tag and terminator
they are `01 61 00 01 62 00` and `01 61 62 00 01 00`: the third byte is `00`
against `62`, so `("a", ..)` sorts first, as it should, because "a" < "ab".
The terminator must be the smallest byte so that a string sorts before every
string it is a prefix of, no matter what the next column contains. Data
bytes `00` and `01` are written as `01 00` and `01 01` so the decoder can
tell them from the terminator; `"a\x00"` becomes `61 01 00 00`.

**As a record.** The same row in the comparator format:

```
03          header_len: three bytes of serial types follow
06 01 01    serial types: text of 3 bytes (3 + 3), int, int
41 6e 6e    "Ann"
03          zigzag(-2) = 3, as a one-byte varint
06          zigzag(3) = 6
```

9 bytes instead of 23, and it can be decoded without knowing the schema.
But there is no way to order two such records without decoding them. The
whole format (a *serial type* is the type code of one column):

```
header_len    varint: how many bytes of serial types follow
serial types  one varint per column:
                0       NULL   no body
                1       int    body: zigzag, then LEB128 varint
                2       float  body: 8 bytes, the IEEE bits little-endian
                n >= 3  text   body: n - 3 raw bytes
bodies        in column order
```

*Zigzag* maps 0, -1, 1, -2, 2 to 0, 1, 2, 3, 4, so small negative numbers
are short too. With `score = NULL` the row is `03 06 00 01 41 6e 6e 06`.
This is the SQLite record simplified: there `header_len` counts itself,
integers are fixed-width (1 to 8 bytes by magnitude) and text is
`13 + 2 * len`.

Varints by hand: LEB128 writes 300 = `10 0101100` in binary as the low seven
bits `0101100` with the "more" bit set (`ac`), then the rest `10` (`02`):
`ac 02`. The SQLite varint writes the high group first: `82 2c`.

## The programs

`zig build run` and `cargo run` print exactly
[`expected_output.txt`](expected_output.txt) (a test in each language checks
it). Sections 1 to 4 show the primitives one by one, 6 to 8 one row in both
encodings, the allocators and the random check. The central part:

```
== 5. composite keys: (name ASC, score DESC NULLS LAST, id ASC) ==
arrival order (ids): 5 6 7 1 8 4 2 3
sorted by key bytes (27 comparisons, 117 byte positions examined):
  id 7  ""        0  01 00 01 7f ff ff ff ff ff ff ff 01 80 00 00 00 00 00 00 07
  id 2  "Ann"     7  01 41 6e 6e 00 01 7f ff ff ff ff ff ff f8 01 80 00 00 00 00 00 00 02
  id 3  "Ann"    -2  01 41 6e 6e 00 01 80 00 00 00 00 00 00 01 01 80 00 00 00 00 00 00 03
  id 4  "Ann"  NULL  01 41 6e 6e 00 02 01 80 00 00 00 00 00 00 04
  id 8  "Anna"  256  01 41 6e 6e 61 00 01 7f ff ff ff ff ff fe ff 01 80 00 00 00 00 00 00 08
  id 1  "Anna"    7  01 41 6e 6e 61 00 01 7f ff ff ff ff ff ff f8 01 80 00 00 00 00 00 00 01
  id 5  "Bo"    300  01 42 6f 00 01 7f ff ff ff ff ff fe d3 01 80 00 00 00 00 00 00 05
  id 6  "Bo"    300  01 42 6f 00 01 7f ff ff ff ff ff fe d3 01 80 00 00 00 00 00 00 06
sorted by record comparator (27 comparisons, 66 columns decoded):
  7 2 3 4 8 1 5 6
same order: yes
space: 8 keys = 173 bytes of a 256-byte fixed buffer, 8 records = 71 bytes
```

The counts describe the work; they are not a benchmark. The same 27
comparisons either look at 117 bytes without the schema, or decode 66 column
values and dispatch on type and options for each. The price is space: 173
bytes against 71.

## Code walk-through

### Zig

| File | Role |
|---|---|
| [`zig/src/varint.zig`](zig/src/varint.zig) | LEB128 `encode` / `decode` / `encodedLen`, `zigzag`, and the SQLite varint. Standalone. |
| [`zig/src/keycodec.zig`](zig/src/keycodec.zig) | Order-preserving primitives, `KeyWriter`, `KeyReader`. Standalone. |
| [`zig/src/row.zig`](zig/src/row.zig) | `Value`, `Column`, the logical comparator `compareRows` (the oracle), `encodeKey`, `decodeKey`, `validateKey`. |
| [`zig/src/record.zig`](zig/src/record.zig) | Record format, `RecordCursor`, `compareRecords`, `validateRecord`. |
| [`zig/src/model.zig`](zig/src/model.zig) | Seeded model test: random row pairs, three orderings that must agree. |
| [`zig/src/main.zig`](zig/src/main.zig) | The fixed scenario. |

`varint.zig` and `keycodec.zig` import nothing but `std` and never allocate;
their header comments list the API. Chapter 12 copies them.

**Varints.** `encode` writes seven bits per byte, low group first, and sets
the high bit on every byte but the last. `decode` rejects three kinds of bad
input: `Truncated`, `Overflow` (more than 64 bits) and `NonCanonical` (a
trailing zero group such as `80 00`), so one integer has one encoding (whole
records are still not canonical; see the pitfalls). Without `zigzag`, -1
would cost ten bytes.

**Fixed-width keys.** `encodeU64` is `writeInt(.., .big)`. `encodeI64` XORs
the sign bit first. `encodeF64` first normalises `-0.0` to `+0.0` and every
NaN to one canonical NaN: values that compare equal must produce the same
key, otherwise a lookup for `0.0` misses a stored `-0.0`.

**Strings.** `encodeBytes` escapes and terminates; `decodeBytes` takes a
`mask` (`0x00` or `0xff`) so a descending column can be un-inverted on the
fly, and an optional output buffer so the same loop can also just measure.

**`KeyWriter`.** A cursor over a caller-supplied `[]u8`. Each `put*` call
reserves the bytes it needs before it writes, so `NoSpaceLeft` leaves the
key as it was. DESC inverts the payload but not the tag: that makes NULLS
FIRST / LAST independent of ASC / DESC.

**Records.** `RecordCursor` keeps two positions, `type_pos` in the serial
types and `body_pos` in the bodies, and moves both only after a column has
decoded completely. Text values borrow from the record. A type varint is
read from the type area only, so a damaged header cannot take a type from
the bodies (tested).

**The oracle.** `row.compareRows` never looks at bytes: NULL equals NULL,
NULL against a value is decided by `nulls_first` alone, value against value
is reversed by `desc`. `model.checkPairs` draws random rows for one schema
from a small alphabet (`00 01 02 a b ff`, integer extremes, infinities, NaN,
both zeros) and requires that `std.mem.order` on the keys, `compareRecords`
on the records and `compareRows` on the values agree, and that both
encodings validate and round trip (section 8 of the output). In the tests,
`checkRandomSchemas` also draws a schema per pair, adds `fd fe ff` (tag,
escape and terminator once a DESC column is inverted) and float edge cases,
and cuts every key and record at every position. `keycodec` and `varint`
carry tests of the same kind inside the file, so they move with it.

**`validate`.** `validateKey` walks a key with the schema and checks that it
ends exactly after the last column and that float columns hold canonical
bits. `validateRecord` checks that header and bodies add up to the record's
length. Both reject every truncation of a valid input (tested): bytes from
disk cannot be trusted.

### Rust

Same files (`varint.rs`, `keycodec.rs`, `row.rs`, `record.rs`, `model.rs`,
`main.rs`), same function names in snake_case, matching tests,
byte-identical output. `bump.rs` is extra: it holds the Rust counterparts of the Zig
allocators.

Differences worth noticing:

- **Errors.** Zig uses error sets and merges them with `||`; Rust has one
  small enum per module (`VarintError`, `KeyError`, `RowError`,
  `RecordError`) and `From` impls so `?` converts between them.
- **Decoded records borrow.** `decode_record(bytes) -> Vec<Value<'_>>`
  returns text values that point into the record. The lifetime ties the row
  to the page buffer, so using the row after the page changes does not
  compile (the test `decode_record_borrows_text_from_the_record` shows the
  line that is rejected). Zig has no such check, so `decodeRecord` copies
  the text into an arena.
- **Decoded keys cannot borrow** in either language: key text is escaped and
  possibly inverted, so it must be rebuilt. Zig allocates it from the arena;
  Rust appends it to `RowArena.text`, a bump `Vec<u8>`, and the columns hold
  offset ranges into it.
- **Self-referential data.** Zig's `RandomRow` stores slices into its own
  buffer ("do not move"). Rust forbids that struct; `RandomRow` owns the
  bytes and `values()` lends them out.
- **`RecordCursor.next`** is `next_column` in Rust: it returns a `Result`,
  so it should not look like `Iterator::next`.

## In real databases

All line numbers are for the commits pinned in `research/`.

**Comparator: Postgres.** nbtree does not have byte-comparable keys. An
*insertion scankey* holds one 3-way comparison function per index column
(`postgres/src/backend/access/nbtree/README:798-821`), and `_bt_compare`
loops over the columns calling it
(`postgres/src/backend/access/nbtree/nbtsearch.c:735-782`). The NULL and
DESC rules in `row.zig` are a transcription of that loop: NULL equals NULL
and is otherwise placed by `SK_BT_NULLS_FIRST` alone (`nbtsearch.c:742-757`);
the comparator result is inverted for `SK_BT_DESC` columns only in the
value-against-value branch (`nbtsearch.c:768-775`; flags at
`postgres/src/include/access/nbtree.h:1116-1117`). The heap TID is compared
last, as one more column (`nbtsearch.c:801-860`); chapter 17 returns to
that.

**Comparator: Turso.** A record is `header_size, serial types, data`
(`turso/docs/agent-guides/storage-format.md:82-98`; serial type constants at
`turso/core/types.rs:3264-3295`). Index keys are records, compared by
`compare_immutable`, which walks the columns and calls `cmp_in_column`
(`turso/core/types.rs:2730-2764`), and `cmp_with_sort` applies sort order
and NULL order afterwards (`turso/core/types.rs:2799-2820`). The varint is the SQLite one:
`read_varint` at `turso/core/storage/sqlite3_ondisk.rs:1353-1399`,
`varint_len` at `:1458-1467`, `write_varint` at `:1470-1507`; a 9-byte
encoding of a value that fits in 8 is rejected as corrupt (`:1385-1391`),
which is the rule `sqliteDecode` copies. Turso's page format is big-endian
throughout (`storage-format.md:36`); this guide uses little-endian for page
fields and big-endian only inside keys, where it is required.

**Byte-comparable: DuckDB.** ART keys are built by `Radix::EncodeData`:
unsigned integers are byte-swapped to big-endian (`BSwapIfLE`,
`duckdb/src/include/duckdb/common/radix.hpp:200-213`), signed ones
additionally get `FlipSign` on the first byte (`radix.hpp:45-47`,
`:165-172`), floats
are mapped by `EncodeFloat` (`radix.hpp:49-78`). Strings escape bytes `00`
and `01` with `01` and end with `00`
(`duckdb/src/execution/index/art/art_key.cpp:20-49`): the scheme
`encodeBytes` uses. Compound keys are plain concatenation
(`art_key.cpp:146-152`). Two differences from this chapter: DuckDB's float
encoding special-cases infinities and NaN to fixed patterns instead of
relying on their bit patterns, and NULLs are not encoded at all: a NULL
produces an empty key (`duckdb/src/execution/index/art/art.cpp:362-370`)
that the insert loop skips (`art.cpp:635-637`). The tag byte and DESC by
inversion in this chapter are textbook techniques, not taken from these
sources.

**Order-preserving integers: TigerBeetle.** A secondary index key is
`(field, timestamp)` packed into one wide unsigned integer with the field in
the high bits (`tigerbeetle/src/lsm/composite_key.zig:64-77`), and the
search compares with integer `<`
(`tigerbeetle/src/lsm/binary_search.zig:105`). It is the same idea, one
schema-free comparison, but not `memcmp`: the stored struct is
little-endian (`composite_key.zig:39-47`). Fixed-width columns need no
terminator, no tags and no escaping.

## Allocator notes

Encoding is a hot path: one key per insert and per lookup. The encoders
never allocate; the caller picks where the bytes live.

- **`FixedBufferAllocator` for encode buffers.** In section 5 all eight keys
  are bump-allocated from one 256-byte stack array (`encodeKeyAlloc` with
  `fba.allocator()`): no system call, no per-key free, and the whole batch
  disappears when the function returns. It fits because the total size is
  bounded and the lifetime is one scope; a general-purpose allocator would
  pay for bookkeeping that is never used. What goes wrong: the buffer is
  finite, so a key that does not fit is
  `error.OutOfMemory` (tested in `row.zig`), and a key returned from the
  function that owns the stack buffer is a dangling slice.
- **`ArenaAllocator` for decoded rows.** `decodeRecord` and `decodeKey`
  allocate one value array plus one copy per text column. Their lifetimes
  are identical ("until the caller is done with this row"), so they are
  freed together, and the arena's `deinit` releases a half-built row after
  a failure. `model.checkPairs` resets the
  arena with `.retain_capacity` once per pair, so it soon stops asking the
  backing allocator for memory. With a general-purpose
  allocator every decoded row would need a matching free of each text, and
  the error paths would need `errdefer` chains.
- **`BufferFirstAllocator` for one key of unknown size.** Most keys are
  short, a few are not. `BufferFirstAllocator.init(&stack_buf, gpa)` serves
  allocations from the stack buffer and falls back to `gpa` when they do not
  fit (section 7: 22 bytes on the stack, 34 on the heap). The caller still
  frees every key; `std.testing.allocator` fails the test if it forgets.
- **Rust.** `Bump` is a fixed-capacity `Vec<u8>` that hands out index
  ranges (a borrowed slice would freeze the `Vec`) and returns
  `Err(OutOfSpace)` when full. `RowArena` is a bump `Vec<u8>` plus offsets,
  cleared with capacity kept. `SmallBuf<N>` is inline storage with a `Vec`
  fallback.

## Pitfalls

- **Endianness in the wrong place.** Page headers in this guide are
  little-endian; key payloads must be big-endian. Mixing them up produces a
  tree that works for keys below 256 and silently mis-sorts above.
- **Using a varint inside a key.** `leb128(129) = 81 01` sorts after
  `leb128(256) = 80 02`: the low group comes first. The SQLite varint fails
  across lengths: 16383 is `ff 7f`, 16384 is `81 80 00`. A length prefix
  has the same problem: `"b"` would sort before `"aa"`.
- **Equal values, different bytes.** `-0.0` and `0.0`, NaNs with different
  payloads, non-canonical varints. In a key, normalise on encode and reject
  on decode; the price is that the sign of zero and NaN payloads do not
  survive. Records here keep the raw float bits on purpose (a row reads
  back exactly), so two records can be equal under `compareRecords` and
  differ as bytes: do not `memcmp` records, not even for equality.
- **Keys are not self-describing.** Decoding `01 80 ..` needs to know
  whether the column is an int or a float, ASC or DESC. If the schema
  changes, old keys do not.
- **Inverting the tag for DESC.** Then NULLS LAST silently becomes NULLS
  FIRST on descending columns. Decide which behaviour you want and test all
  four combinations. Here NULLS LAST is the default for ASC and DESC; in
  Postgres a bare `DESC` means NULLS FIRST
  (`postgres/doc/src/sgml/ref/create_index.sgml:319-333`).
- **Prefix scans on DESC strings.** Inverted, the terminator is `ff`, so a
  string sorts after its extensions. That is correct, but the bounds of a
  prefix scan must then be built from the inverted bytes too.
- **Collations.** Bytewise order is not alphabetical order ("Z" < "a" in
  ASCII). A key for a collated column has to store a collation sort key
  instead of the text, which usually cannot be decoded back (textbook; not
  verified in these sources).

## Exercises

Solutions are in [`solutions.md`](solutions.md).

1. (easy) Encode `-1`, `0` and `1` as `i64` keys by hand, then as DESC keys.
   Without running anything, give the `memcmp` order of the six byte strings.
2. (easy) What are the LEB128 and SQLite varints of 16384, and what is the
   largest value each format can store in two bytes? Why does LEB128 need a
   tenth byte for `u64` while SQLite needs only nine?
3. (medium) The key encoder uses a one-byte terminator with escaping. An
   alternative is a length prefix. Show a pair of strings that a big-endian
   `u32` length prefix sorts wrongly, then explain why escaping costs nothing
   for typical text.
4. (medium) Add a `bool` column type and an unsigned 32-bit column type to
   `KeyWriter` / `KeyReader`. Which existing property test style proves them
   correct, and what are the edge values?
5. (hard) In an interior node only enough of a separator key is needed to
   send a search left or right (chapter 17 calls this suffix truncation).
   Given keys `a < b` as encoded byte strings, write
   `shortestSeparator(a, b)` that returns the shortest byte string `s` with
   `a < s <= b`. Why is this easy for byte-comparable keys and hard for
   comparator-based ones?

## Where next

- Previous: [chapter 10, slotted pages](../10-slotted-pages/README.md)
  defined the cell; this chapter defined what goes inside it.
- Next: [chapter 12, a disk-backed B+tree](../12-disk-backed-bplus-tree/README.md)
  stores byte-string keys in slotted pages and compares them with `memcmp`.
- Visualization: [viz/index.html](viz/index.html): type values, watch the
  bytes, and switch single fixes off to see the sort order break.

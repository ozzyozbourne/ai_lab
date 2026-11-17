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
10 (a cell is just a run of bytes inside a page). You need two's complement
and a rough idea of IEEE 754 doubles; both are recalled where they are used.

## The idea in plain words

Up to chapter 8 a key was a `u64` compared with `<`. On disk a key is a
byte string inside a cell, and the row behind it has typed columns. Two
questions follow.

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
   and TigerBeetle's composite keys work this way (a radix tree has no
   choice: it *is* the bytes).

The second approach moves all the cleverness into the encoder. The rest of
this chapter is mostly the list of things that go wrong when you encode
naively, and the fix for each:

| Value | Naive encoding | What breaks | Fix |
|---|---|---|---|
| unsigned int | little-endian | the first byte compared is the least significant | big-endian |
| signed int | big-endian two's complement | negatives have the top bit set, so they sort after positives | flip the sign bit |
| float | IEEE bits, big-endian | same sign problem, and among negatives a larger bit pattern is a *smaller* number | positives: set the sign bit; negatives: invert all bits |
| string | raw bytes | in a composite key, column boundaries disappear | terminator byte, with escaping for data bytes that look like it |
| NULL | nothing | indistinguishable from an empty value | one tag byte per column |
| DESC column | (same as ASC) | wrong direction | invert every payload byte |
| varint | as is | a longer encoding can start with a smaller byte | do not use varints in keys |

The price: byte-comparable keys are bigger (every integer takes 8 bytes plus
a tag), they are not self-describing (you need the schema to decode them),
and some orders cannot be expressed as bytes at all without extra work
(language-aware collations).

## A worked example by hand

Schema: `(name ASC, score DESC NULLS LAST, id ASC)`. Row: `("Ann", -2, 3)`.

**As a byte-comparable key.** Each column is a tag byte followed by a
payload; tag `01` means "a value follows".

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
03          header: three bytes of serial types follow
06 01 01    text of 3 bytes (3 + 3), int, int
41 6e 6e    "Ann"
03          zigzag(-2) = 3, as a one-byte varint
06          zigzag(3) = 6
```

9 bytes instead of 23, and it can be decoded without knowing the schema.
But there is no way to order two such records without decoding them.

Varints by hand: LEB128 writes 300 = `10 0101100` in binary as the low seven
bits `0101100` with the "more" bit set (`ac`), then the rest `10` (`02`):
`ac 02`. The SQLite varint writes the high group first: `82 2c`.

## The programs

`zig build run` and `cargo run` print exactly
[`expected_output.txt`](expected_output.txt) (a test in each language checks
it). The central part:

```
== 2. integers as keys ==
i64 values -2 -1 0 1 256, sorted by comparing the bytes of each encoding:
  little-endian          : 0 256 1 -2 -1  (WRONG)
  big-endian             : 0 1 256 -2 -1  (WRONG)
  big-endian + sign flip : -2 -1 0 1 256  (correct)

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

== 8. the property, checked on random rows ==
seed 11, 2000 pairs: 771 less, 434 equal, 795 greater
byte order of keys == comparator order of records == logical order: yes
```

The counts describe the work; they are not a benchmark. The same 27
comparisons either look at 117 bytes with no knowledge of the schema, or
decode 66 column values and dispatch on type and options for each. The
space line is the other side of the trade: 173 bytes against 71.

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
trailing zero group such as `80 00`). The last one is an invariant worth
having: one value, one encoding, so equal rows are equal bytes. `zigzag`
interleaves negative and positive numbers so that -1 costs one byte rather
than ten.

**Fixed-width keys.** `encodeU64` is `writeInt(.., .big)`. `encodeI64` XORs
the sign bit first. `encodeF64` normalises `-0.0` to `+0.0` and every NaN to
one canonical NaN, then sets the sign bit of non-negative numbers and
inverts negative ones. The normalisations matter: if two values compare
equal they must produce the same key, otherwise a lookup for `0.0` misses a
stored `-0.0`.

**Strings.** `encodeBytes` escapes and terminates; `decodeBytes` takes a
`mask` (`0x00` or `0xff`) so a descending column can be un-inverted on the
fly, and an optional output buffer so the same loop can also just measure.

**`KeyWriter`.** A cursor over a caller-supplied `[]u8`. Each `put*` call
first reserves the exact number of bytes it needs and only then writes, so a
`NoSpaceLeft` leaves the key as it was. DESC inverts the payload but not the
tag: that is what makes NULLS FIRST / LAST independent of ASC / DESC.

**The oracle.** `row.compareRows` never looks at bytes. It encodes the rules
directly: NULL equals NULL, NULL against a value is decided by `nulls_first`
alone, value against value is reversed by `desc`. `model.checkPairs` then
draws random rows from a nasty little alphabet (`00 01 02 a b ff`, integer
extremes, infinities, NaN, both zeros) and requires, for each pair, that
`std.mem.order` on the keys, `compareRecords` on the records and
`compareRows` on the values give the same answer, and that both encodings
validate and round trip.

**`validate`.** `validateKey` walks a key with the schema and checks that it
ends exactly after the last column and that float columns hold canonical
bits. `validateRecord` checks that the header and the bodies add up to the
record's length. Both return errors on every truncation of a valid input
(tested), because these bytes come from disk and cannot be trusted.

### Rust

Same files (`varint.rs`, `keycodec.rs`, `row.rs`, `record.rs`, `model.rs`,
`main.rs`), same function names in snake_case, same tests, byte-identical
output. `bump.rs` is extra: it holds the Rust counterparts of the Zig
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
  the text into an arena and the test overwrites the "page" afterwards to
  prove the row survived.
- **Decoded keys cannot borrow** in either language: key text is escaped and
  possibly inverted, so it must be rebuilt. Zig allocates it from the arena;
  Rust appends it to `RowArena.text`, a bump `Vec<u8>`, and the columns hold
  offset ranges into it.
- **Self-referential data.** Zig's `RandomRow` stores slices into its own
  buffer and carries a comment "do not move". Rust will not let that struct
  exist; `RandomRow` owns the bytes and `values()` lends them out.
- **`RecordCursor.next`** is called `next_column` in Rust, to avoid looking
  like `Iterator::next` while returning a `Result`.

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
and NULL order afterwards (`turso/core/types.rs:2799-2820`). There are
specialised comparators chosen by the type of the first column
(`turso/core/types.rs:2882-2895`). The varint is the SQLite one:
`read_varint` at `turso/core/storage/sqlite3_ondisk.rs:1353-1399`,
`varint_len` at `:1458-1467`, `write_varint` at `:1470-1507`; a 9-byte
encoding of a value that fits in 8 is rejected as corrupt (`:1385-1391`),
which is the rule `sqliteDecode` copies. Turso's page format is big-endian
throughout (`storage-format.md:36`); this guide uses little-endian for page
fields and big-endian only inside keys, where it is required.

**Byte-comparable: DuckDB.** ART keys are built by `Radix::EncodeData`:
unsigned integers are byte-swapped to big-endian, signed ones additionally
get `FlipSign` on the first byte
(`duckdb/src/include/duckdb/common/radix.hpp:45-47`, `:165-172`), floats
are mapped by `EncodeFloat` (`radix.hpp:49-78`). Strings escape bytes `00`
and `01` with `01` and end with `00`
(`duckdb/src/execution/index/art/art_key.cpp:20-49`): the scheme
`encodeBytes` uses. Compound keys are plain concatenation
(`art_key.cpp:146-152`). Two differences from this chapter: DuckDB's float
encoding special-cases infinities and NaN to fixed patterns instead of
relying on their bit patterns, and NULLs are not encoded at all: a NULL
produces an empty key that is not inserted
(`duckdb/src/execution/index/art/art.cpp:362-370`). The tag byte and DESC by
inversion in this chapter are textbook techniques, not taken from these
sources.

**Byte-comparable by construction: TigerBeetle.** A secondary index key is
`(field, timestamp)` packed into one wide unsigned integer with the field in
the high bits, so integer comparison is lexicographic comparison
(`tigerbeetle/src/lsm/composite_key.zig:64-77`). Fixed-width columns need no
terminator, no tags and no escaping.

## Allocator notes

Encoding is a hot path: one key per insert and per lookup. The design goal
is that the encoders themselves never allocate, and the caller picks where
the bytes live.

- **`FixedBufferAllocator` for encode buffers.** In section 5 all eight keys
  are bump-allocated from one 256-byte stack array (`encodeKeyAlloc` with
  `fba.allocator()`): no system call, no per-key free, and the whole batch
  disappears when the function returns. It is the natural choice because the
  total size is bounded and the lifetime is one scope. A general-purpose
  allocator would pay for bookkeeping that is never used. What goes wrong
  with it: the buffer is finite, so a key that does not fit is
  `error.OutOfMemory` (tested in `row.zig`), and returning a key that points
  into a stack buffer from the function that owns the buffer is a dangling
  slice.
- **`ArenaAllocator` for decoded rows.** `decodeRecord` and `decodeKey`
  allocate one value array plus one copy per text column. Their lifetimes
  are identical ("until the caller is done with this row"), so they are
  freed together; the functions do not even clean up on failure, because the
  arena's `deinit` releases a half-built row. `model.checkPairs` resets the
  arena with `.retain_capacity` once per pair, so after the first few pairs
  it stops asking the backing allocator for memory. With a general-purpose
  allocator every decoded row would need a matching free of each text, and
  the error paths would need `errdefer` chains.
- **`BufferFirstAllocator` for one key of unknown size.** Most keys are
  short, a few are not. `BufferFirstAllocator.init(&stack_buf, gpa)` serves
  allocations from the stack buffer and falls back to `gpa` when they do not
  fit (section 7: 22 bytes on the stack, 34 bytes on the heap). The caller
  still calls `free` on every key; for the stack case that is nearly free,
  for the heap case it is required, and `std.testing.allocator` fails the
  test if it is forgotten.
- **Rust.** `Bump` is a fixed-capacity `Vec<u8>` that hands out index
  ranges; `alloc` returns `Err(OutOfSpace)` when full, which is the
  mirror of the allocation-failure tests. `RowArena` is a bump `Vec<u8>`
  plus offsets, cleared with capacity kept. `SmallBuf<N>` is inline storage
  with a `Vec` fallback. Ranges rather than slices because a slice borrowed
  from the `Vec` would freeze it while the key is in use.

## Pitfalls

- **Endianness in the wrong place.** Page headers in this guide are
  little-endian; key payloads must be big-endian. Mixing them up produces a
  tree that works for keys below 256 and silently mis-sorts above.
- **Using a varint inside a key.** `leb128(129) = 81 01` sorts after
  `leb128(256) = 80 02`. A length prefix has the same problem: `"b"` would
  sort before `"aa"`.
- **Equal values, different bytes.** `-0.0` and `0.0`, NaNs with different
  payloads, non-canonical varints. Normalise on encode, reject on decode.
  The flip side: the sign of zero and NaN payloads do not survive.
- **Forgetting that keys are not self-describing.** Decoding `01 80 ..` needs
  to know whether the column is an int or a float, ASC or DESC. If the
  schema changes, old keys do not.
- **Inverting the tag for DESC.** Then NULLS LAST silently becomes NULLS
  FIRST on descending columns. Decide which behaviour you want and test all
  four combinations.
- **Prefix scans on DESC strings.** Inverted, the terminator is `ff`, so a
  string sorts after its extensions. That is correct, but the bounds of a
  prefix scan must then be built from the inverted bytes too.
- **Collations.** Bytewise order is not alphabetical order in most
  languages ("Z" < "a" in ASCII). A byte-comparable key for a collated
  column has to store a collation sort key instead of the text, which
  usually cannot be decoded back (textbook; not verified in these sources).
- **Trusting bytes from disk.** Every decoder here returns an error on
  truncated or malformed input instead of indexing past the end.

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
  stores byte-string keys in slotted pages and compares them with `memcmp`,
  using `varint` and `keycodec` from here.
- Visualization: [viz/index.html](viz/index.html): type values, watch the
  bytes, and switch individual fixes off to see the sort order break.

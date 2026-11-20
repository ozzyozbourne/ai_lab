# Chapter 10: Slotted pages

Previous: [09 Pages and the buffer pool](../09-pages-and-the-buffer-pool/README.md) |
Next: [11 Key and record encoding](../11-key-and-record-encoding/README.md) |
Visualization: [viz/index.html](viz/index.html)

## What you will learn

- How one fixed 4096-byte page keeps a changing number of variable-size records sorted.
- The three places free space hides (the gap, free blocks, fragments) and why "enough
  free bytes" is not the same as "it fits".
- How a page reuses the holes left by deleted records, and when it has to compact.
- How Turso (the SQLite format) and Postgres lay out the same idea.

Prerequisites: chapter 02 (lower-bound binary search) and chapter 09 (a file is an array of
fixed-size pages). In chapter 12 every node of a disk-backed B+tree is one of these pages.

## The idea in plain words

In Part I a node was a struct with an array of `u64` keys, and inserting into the middle
shifted a few small keys. On disk, keys and values are byte strings of any length. Two
problems appear:

1. If records are stored back to back in key order, inserting one in the middle means
   moving every record after it.
2. Records have no fixed position, so "the i-th record" cannot be found by arithmetic,
   and binary search needs exactly that.

A slotted page solves both with one level of indirection: two regions that grow toward
each other.

```
 0        16                                           usable        4096
 +--------+---------------+------------------+-----------------+----------+
 | header | slot array -> |   gap (unused)   | <- cell content | reserved |
 +--------+---------------+------------------+-----------------+----------+
```

- A **cell** is one record: lengths, key bytes, value bytes. Cells are written wherever
  there is room, starting at the end of the page and growing toward the front.
- A **slot** is a 2-byte offset that says where one cell starts. Slots sit right after the
  header and are kept **in key order**.

- The **reserved tail** is optional: the page never touches the last `reserved` bytes of
  the buffer, and its content area ends at `usable = 4096 - reserved`. It is 0 in this
  chapter's examples; chapter 22 reserves 4 bytes for the page checksum of chapter 21.

The 16-byte header (little-endian integers):

| Offset | Size | Field | Meaning |
|--------|------|-------|---------|
| 0 | 2 | `cell_count` | number of slots, which is the number of cells |
| 2 | 2 | `content_start` | offset of the lowest cell; `usable` when the page is empty |
| 4 | 2 | `first_free` | offset of the first free block (see below), 0 if none |
| 6 | 1 | `frag_bytes` | number of fragment bytes (see below) |
| 7 | 1 | `kind` | the caller's: chapter 12 stores leaf or interior here |
| 8 | 1 | `reserved` | size of the reserved tail |
| 9 | 7 | user area | the caller's: chapter 12 stores a page number here |

Slot `i` is at a computable position (`16 + 2*i`), so binary search works: probe a slot,
follow it to the cell, compare keys. Inserting in the middle moves only the 2-byte slots
after it; no cell moves.

Deleting is harder. Removing a slot is easy, but the cell leaves a hole in the content
area, and the page has to remember it so that a later insert can reuse it. The page
becomes a very small heap allocator, with the usual problem of heaps: fragmentation. Free
space ends up in three forms:

| Form | What it is | Can hold |
|------|------------|----------|
| gap | the unused bytes between the slot array and the lowest cell | a new slot, a new cell |
| free block | a hole of 4 bytes or more left by a deleted cell | a new cell that fits in it |
| fragment | a sliver of 1 to 3 bytes, too small to describe itself | nothing |

A free block describes itself: its first 4 bytes hold the offset of the next free block and
its own size, so the list that starts at `first_free` costs no space outside the holes. A
sliver under 4 bytes cannot do that, so it is only counted, in `frag_bytes`.

The total of the three is what the page has free, but a cell needs its bytes **in one
piece**. When the total is enough and no single piece is, the page **compacts**: it slides
every cell to the end of the page, and all free bytes become gap. Slot numbers do not
change during compaction; only the offsets stored in the slots do. A reference by slot
number or by key survives; a raw pointer to the bytes does not.

## A worked example by hand

A slot is 2 bytes and a cell is `4 + key length + value length` bytes (two 2-byte lengths,
then key, then value). The page is 4096 bytes. This is Part 1 of the programs' output. The
visualization animates it on a 256-byte page, so every offset there is 3840 lower.

**Five inserts.** `mango=yellow` is a 15-byte cell. The content area is empty, so the cell
goes at the very end: offset 4096 - 15 = 4081. `apple=red` (12 bytes) goes just below it at
4069, then `kiwi=green` (13) at 4056, `cherry=dark red` (18) at 4038, `fig=purple` (13) at
4025. Physical order is insertion order. The slot array is in key order:

```
slots:  apple@4069  cherry@4038  fig@4025  kiwi@4056  mango@4081
```

Inserting `apple` moved one slot (mango's) up by 2 bytes; no cell moved. `content_start`
is 4025 and the gap is 4025 - (16 + 5*2) = 3999 bytes.

**Delete kiwi.** Its slot is removed (mango's slot moves down). Its 13 bytes at 4056 are
in the middle of the content area, so they become a free block: the bytes at 4056 are
overwritten with `next = 0, size = 13`, and the header's `first_free` points at 4056.

**Delete apple.** Apple's cell is at 4069, and kiwi's hole ends at 4056 + 13 = 4069. The two
are neighbours, so they merge into one free block: offset 4056, size 25.

**Put banana=yellow** (16 bytes). The allocator looks at the free list first. The block of
25 is big enough. The cell takes the *tail* of the block (offset 4056 + 9 = 4065), so the
block keeps its offset and only its size field changes, to 9.

**Put pea=g** (8 bytes). The 9-byte block fits it, but the 1 byte left over cannot hold a
4-byte free block header. The block is unlinked, the cell goes at 4056, and the leftover
byte at 4064 is recorded only by incrementing `frag_bytes` to 1.

**Delete fig.** Fig's cell is the lowest one (4025 = `content_start`). Nothing has to be
remembered: `content_start` simply moves up to 4038 and the bytes are gap again.

**Delete mango.** The cell at 4081 is surrounded by live data, so it becomes a new free
block of 15 bytes. Now the page has gap 4016, one free block of 15, and 1 fragment byte:
4032 free bytes in three pieces.

**Compact.** The three remaining cells are rewritten from the end of the page in slot
order: banana (16) at 4080, cherry (18) at 4062, pea (8) at 4054. The free list is empty,
`frag_bytes` is 0, and the gap is 4032: the same total as before, in one piece.

<details>
<summary>Part 1 of expected_output.txt</summary>

```
== Part 1: one page, step by step ==
init
  cells=0 content_start=4096 gap=4080 free_blocks=[] frag=0 free=4080
  slots: (none)
put mango=yellow (15-byte cell)
  cells=1 content_start=4081 gap=4063 free_blocks=[] frag=0 free=4063
  slots: mango@4081
put apple=red (12-byte cell)
  cells=2 content_start=4069 gap=4049 free_blocks=[] frag=0 free=4049
  slots: apple@4069 mango@4081
put kiwi=green (13-byte cell)
  cells=3 content_start=4056 gap=4034 free_blocks=[] frag=0 free=4034
  slots: apple@4069 kiwi@4056 mango@4081
put cherry=dark red (18-byte cell)
  cells=4 content_start=4038 gap=4014 free_blocks=[] frag=0 free=4014
  slots: apple@4069 cherry@4038 kiwi@4056 mango@4081
put fig=purple (13-byte cell)
  cells=5 content_start=4025 gap=3999 free_blocks=[] frag=0 free=3999
  slots: apple@4069 cherry@4038 fig@4025 kiwi@4056 mango@4081
delete kiwi
  cells=4 content_start=4025 gap=4001 free_blocks=[4056+13] frag=0 free=4014
  slots: apple@4069 cherry@4038 fig@4025 mango@4081
delete apple
  cells=3 content_start=4025 gap=4003 free_blocks=[4056+25] frag=0 free=4028
  slots: cherry@4038 fig@4025 mango@4081
put banana=yellow (16-byte cell)
  cells=4 content_start=4025 gap=4001 free_blocks=[4056+9] frag=0 free=4010
  slots: banana@4065 cherry@4038 fig@4025 mango@4081
put pea=g (8-byte cell)
  cells=5 content_start=4025 gap=3999 free_blocks=[] frag=1 free=4000
  slots: banana@4065 cherry@4038 fig@4025 mango@4081 pea@4056
delete fig
  cells=4 content_start=4038 gap=4014 free_blocks=[] frag=1 free=4015
  slots: banana@4065 cherry@4038 mango@4081 pea@4056
delete mango
  cells=3 content_start=4038 gap=4016 free_blocks=[4081+15] frag=1 free=4032
  slots: banana@4065 cherry@4038 pea@4056
compact
  cells=3 content_start=4054 gap=4032 free_blocks=[] frag=0 free=4032
  slots: banana@4080 cherry@4062 pea@4054
header and slot array:
00000000  03 00 d6 0f 00 00 00 00  00 00 00 00 00 00 00 00  |................|
00000010  f0 0f de 0f d6 0f 00 00  00 00 00 00 00 00 00 00  |................|
content area:
00000fd0  00 00 00 00 00 00 03 00  01 00 70 65 61 67 06 00  |..........peag..|
00000fe0  08 00 63 68 65 72 72 79  64 61 72 6b 20 72 65 64  |..cherrydark red|
00000ff0  06 00 06 00 62 61 6e 61  6e 61 79 65 6c 6c 6f 77  |....bananayellow|
```

</details>

In the final hexdump, `03 00` is the cell count, `d6 0f` is `content_start` 0x0fd6 = 4054,
and the slots `f0 0f`, `de 0f`, `d6 0f` are 4080, 4062, 4054. At 0xfd6 the cell
`03 00 01 00 "pea" "g"` begins: key length 3, value length 1.

Part 2 shows why "free" and "fits" differ, and Part 3 runs the shared random operation
stream against one page:

```
== Part 2: fragmentation and automatic compaction ==
fill with 104-byte cells until the next one does not fit
  cells=38 content_start=144 gap=52 free_blocks=0 (0 bytes, largest 0) frag=0 free=52
delete every other cell
  cells=19 content_start=144 gap=90 free_blocks=19 (1976 bytes, largest 104) frag=0 free=2066
put big (507-byte cell): no free block and no gap is large enough, so the page compacts first
  cells=20 content_start=1613 gap=1557 free_blocks=0 (0 bytes, largest 0) frag=0 free=1557
put huge (2008-byte cell): PageFull, page unchanged
  cells=20 content_start=1613 gap=1557 free_blocks=0 (0 bytes, largest 0) frag=0 free=1557

== Part 3: 3000 random operations on one page ==
seed=10 count=3000 key_space=300
put: 1202 (475 refused with PageFull)
delete: 600 (235 found)
get: 885 (327 found)
range: 313 (12768 cells visited)
most free blocks at once: 16, most fragment bytes at once: 27
  cells=128 content_start=279 gap=7 free_blocks=1 (4 bytes, largest 4) frag=0 free=11
fnv1a64 of the page: 3b3ad4029bd5294a
```

After deleting every other cell the page has 2066 free bytes, but the largest piece is
104. The 507-byte cell still goes in, because the insert compacts first. The last line of
Part 3 hashes all 4096 bytes: Zig and Rust end with the identical page image.

## Code walk-through

Both implementations have the same four files:

| Zig | Rust | Content |
|-----|------|---------|
| `zig/src/slotted_page.zig` | `rust/src/slotted_page.rs` | `SlottedPage` and its unit tests (std only; chapter 12 copies this file) |
| `zig/src/model_test.zig` | `rust/src/model_test.rs` | seeded model test against the oracle from `common/` |
| `zig/src/workload.zig` | `rust/src/workload.rs` | turns the `u64` keys and values of the shared op stream into byte strings |
| `zig/src/demo.zig` | `rust/src/demo.rs` | the scenario above; a test compares it with `expected_output.txt` |

### Zig

`SlottedPage` is a struct with one field, `buf: *[page_size]u8`. It owns nothing. `init`
formats a buffer, `initReserved(buf, n)` formats it with a reserved tail, and `open` wraps
a buffer that is already formatted. Every access
goes through two helpers, `rd16` and `wr16`. The file never casts the buffer to a struct,
so alignment and the host's byte order cannot leak into the file format.

The public API:

```zig
pub fn init(buf: *[page_size]u8) SlottedPage              // reserved tail of 0 bytes
pub fn initReserved(buf: *[page_size]u8, reserved_bytes: u8) SlottedPage
pub fn open(buf: *[page_size]u8) SlottedPage              // reads the tail size from the header
pub fn reservedSize(self) usize, usableSize(self) usize   // usable = 4096 - reserved
pub fn reservedArea(self) []u8                            // the caller's bytes: buf[usable..]
pub fn maxCellSize(self) usize                            // usable - 16 - 2
pub fn count(self) usize
pub fn key(self, index: usize) []const u8
pub fn value(self, index: usize) []const u8
pub fn search(self, wanted: []const u8) SearchResult      // { found, index }, lower bound
pub fn get(self, wanted: []const u8) ?[]const u8
pub fn put(self, k: []const u8, v: []const u8) Error!void // PageFull, CellTooLarge
pub fn delete(self, wanted: []const u8) bool
pub fn insertAt(self, index: usize, k: []const u8, v: []const u8) Error!void
pub fn deleteAt(self, index: usize) void
pub fn compact(self) void
pub fn freeBytes(self) usize
pub fn fits(self, key_len: usize, value_len: usize) bool
pub fn stats(self) Stats
pub fn validate(self) ValidateError!void
pub fn kind(self) u8, setKind(self, u8) void, userArea(self) *[7]u8
```

`search` is the lower bound of chapter 02 with `keys[mid]` replaced by `self.key(mid)`,
which reads a slot and follows it. `put` is `search` followed by `insertAt` (or by a
replacement if the key exists).

`insertAt` has two steps. First `allocSpace(size)` returns an *offset* for the cell, and
the cell is written there. Then the slots from `index` on move up with one `@memmove`, and
the new slot is written. The check `size + slot_size > freeBytes()` comes before anything
is modified, so a `PageFull` leaves the page byte for byte as it was.

`allocSpace` is the allocation policy:

1. If the gap still has 2 bytes for the new slot, try the free list (`takeFromFreeBlock`,
   first fit). A block with 4 or more bytes to spare gives up its tail; otherwise it is
   unlinked and its 0 to 3 leftover bytes are added to `frag_bytes`.
2. Otherwise use the gap: lower `content_start` by `size`.
3. If the gap is too small for cell plus slot, `compact()` first; the gap then equals
   `freeBytes()`, which the caller already checked.

`freeSpace(offset, size)` is the reverse. It merges the freed range with the free block
on either side if they touch **or are at most 3 bytes apart**: bytes in between cannot be
a live cell (a cell is at least 4 bytes), so they are a sliver, and merging takes them
back out of `frag_bytes`. If the merged range starts at `content_start`, no block is
written: `content_start` moves up and the bytes are gap.

`compact` copies the content area to a 4 KiB scratch array on the stack and rewrites the cells
from the end of the content area in slot order, reading cell lengths from the copy.

`validate` paints every byte of the content area into a 4 KiB map on the stack as "cell"
or "free block", fails if a byte is painted twice, and requires the unpainted bytes to
number `frag_bytes`. It also checks that the free list is ascending and merged, that
nothing reaches into the reserved tail, and that keys are strictly ascending. It is the
only method that is safe on arbitrary bytes.

### Rust

`SlottedPage<'a>` holds `buf: &'a mut [u8; PAGE_SIZE]`. Names, constants, algorithms, tests
and output match the Zig version (`insert_at` for `insertAt`, and so on). Reads take
`&self`, writes take `&mut self`. Slot shifting is `copy_within`. `PageError` and
`ValidateError` are plain enums implementing `std::error::Error`.

### Differences that matter

- **Stale slices.** In Zig, `page.value(1)` returns a `[]const u8` into the buffer, and
  nothing stops you from using it after `compact()` moved the cell (test "a slice into the
  page does not survive compaction"). In Rust the same program does not compile:
  `value(&self)` borrows the page, and `compact(&mut self)` needs it exclusively. The Rust
  test remembers an offset instead.
- **Aliasing arguments.** `put(k, v)` may compact, so `k` and `v` must not point into the
  page. Zig asserts this on the pointer ranges (`assertOutside`). Rust needs no check: a
  `&[u8]` into the page cannot exist while `&mut self` does.
- **Free list for dumps.** Zig's `freeBlocks(out)` fills a caller's buffer; Rust's
  `free_blocks()` returns a `Vec`, the only allocation in the Rust file.
- **Test counts.** Zig runs 32 tests, Rust 29: two Zig tests put the oracle under
  allocation failure, which Rust's `Vec` cannot report; one is the block in `root.zig`.

Run it:

```
cd zig  && zig build test --summary all && zig build run
cd rust && cargo test && cargo run
```

## In real databases

Everything below was read in the sources under `db_study/` (see `research/turso.md`
sections 2 and 3 and `research/postgres.md` section 1).

**Turso (SQLite file format)** is the source of this chapter's free-space design.

- A B-tree page is a header (8 bytes for a leaf, 12 for an interior page), 2-byte cell
  pointers sorted by key, the unallocated gap, and cell content growing from the end of
  the page. The header has our fields: first freeblock, cell count, content area start,
  fragmented free bytes
  (`turso/core/storage/btree.rs:100-148`, `turso/core/storage/sqlite3_ondisk.rs:82-87`).
- Freeblocks are a chain in ascending offset order; each stores `next` and `size` in its
  first 4 bytes. `find_free_slot` is first fit, shrinks a block from its tail, and turns a
  remainder under 4 bytes into fragment bytes (`btree.rs:9288-9383`). The bound of 60
  fragment bytes is our `max_frag_bytes`, but the test differs: Turso will not use up a
  block once the page has more than 57 (`:9335-9340`), even for an exact fit; we compare
  the sum with 60.
- `free_cell_range` merges a freed range with the next and previous freeblock, absorbing
  a gap of 1 to 3 bytes out of the fragment count, and extends the unallocated region
  when the range starts at the content area (`btree.rs:9797-9970`).
- `allocate_cell_space` tries a freeblock only if the gap has room for the new 2-byte
  pointer, then the gap, then defragments (`btree.rs:10516-10562`).
- `compute_free_space` sums gap, freeblocks and fragments (`btree.rs:10433-10513`); the
  integrity check's coverage checker (`btree.rs:8913`) is our `validate`.
- Our reserved tail is Turso's reserved space with the count stored per page instead of
  once in the database header (`sqlite3_ondisk.rs:321-322`, `:369-371`); Turso's optional
  8-byte page checksum lives there (`turso/core/storage/checksum.rs:4-6`, `:36-48`).

Differences from our page: integers are big-endian; a cell describes itself through
varints (chapter 11) instead of two fixed length fields; a 2- or 3-byte cell is padded to
4 bytes (`btree.rs:10522-10524`); and defragmentation has a fast path for one or two
freeblocks (`btree.rs:9976-10098`).

**Postgres** uses the same two regions for every page, heap and index
(`postgres/src/include/storage/bufpage.h:24-78`):

| | This chapter | Turso | Postgres |
|---|---|---|---|
| slot | 2 bytes: offset | 2 bytes: offset (`sqlite3_ondisk.rs:84`) | 4 bytes: 15-bit offset, 2-bit state, 15-bit length (`itemid.h:25-30`) |
| who knows the cell length | the cell (two u16) | the cell (varints) | the slot (`lp_len`) |
| holes after delete | free blocks + fragment count | freeblocks + fragment count | none on index pages: closed at once |
| caller-owned area | 7 header bytes, optional reserved tail | reserved bytes at the page end, same size for the whole file | "special space" at the page end, size chosen per page (`bufpage.c:42-57`) |
| slot numbering | from 0 | from 0 | from 1 (`bufpage.h:60-61`) |

- The header keeps `pd_lower` (end of the line pointer array) and `pd_upper` (start of
  tuple data) (`bufpage.h:46-47`, struct at `bufpage.h:184-197`). Free space is their
  difference (`PageGetFreeSpace`, `postgres/src/backend/storage/page/bufpage.c:918`).
- Inserting shifts line pointers with one `memmove` and copies the tuple to `pd_upper`
  (`PageAddItemExtended`, `bufpage.c:205`, `:338-340`). Tuple sizes are rounded up to the
  maximum alignment (`MAXALIGN`, `bufpage.c:326`); our cells are byte-packed.
- Deleting an index tuple closes the hole at once: `PageIndexTupleDelete` moves all tuple
  data below the deleted tuple up by its size and adjusts every line pointer that pointed
  below it (`bufpage.c:1063-1160`). No free list and no fragments, at the price of a
  `memmove` and a pass over all line pointers per delete.
- nbtree keeps sibling links, level and flags in the special space (`BTPageOpaqueData`,
  `postgres/src/include/access/nbtree.h:63-70`), as chapter 12 uses `kind` and the user area.

DuckDB, TigerBeetle, Milvus and FAISS are not sources for this chapter.

## Allocator notes

`SlottedPage` never allocates from a heap: it works on the caller's buffer and two 4 KiB
stack arrays. The only `std.mem.Allocator` in the Zig code is
`std.testing.allocator`, passed explicitly to the oracle of the model test; one test runs
the model under `checkAllAllocationFailures`. This structure's "allocation failure on
insert" is `error.PageFull`, tested the same way: the operation fails and the page is
unchanged.

The featured allocator is the one **inside the page**: `allocSpace(size) -> offset` and
`freeSpace(offset, size)`, first fit with coalescing over the content area. It cannot be
exposed as a `std.mem.Allocator`, for four reasons:

1. **Cells move.** `Allocator.alloc` returns a pointer that must stay valid until `free`;
   compaction relocates every cell. The slot array is the indirection a compacting
   allocator needs: the stable name of a record is its slot index or its key, never its
   address.
2. **The heap itself moves.** The page is written to disk and read back into a different
   buffer-pool frame. An address inside it means nothing after that; an offset still
   does, which is why `first_free`, the `next` links and the slots are 16-bit offsets.
3. **Free needs context the interface does not give.** `Allocator.free(memory)` receives
   only the slice; deleting also removes a slot, and the last delete resets the page.
4. **Failure is routine.** `error.OutOfMemory` is exceptional; `error.PageFull` happens on
   every page of every tree and means "split me" (chapter 12).

What would go wrong with a different choice: a `FixedBufferAllocator` over the 4096 bytes
is a bump allocator with no reuse, so a page that sees deletes would fill up with dead
bytes. In Rust the borrow checker turns reason 1 into a compile error.

## Pitfalls

- **Total free space is not allocatable space.** Use `freeBytes()` (or `fits`) to decide
  whether an insert can succeed, never only the gap or only the largest hole.
- **The slot needs room too.** A hole that fits the cell is useless if the gap has no 2
  bytes for the new slot.
- **Slices into the page die on the next mutation.** Copy a key out first.
- **Compaction must not read what it has overwritten.** Take cell sizes from the scratch
  copy: a moved cell may have landed on the header of one not yet moved.
- **Slot indexes are stable across compaction, not across insert and delete.** Long-lived
  references use the key and search again (chapter 08's cursors did the same).
- **Key order is byte order.** `"10"` sorts before `"9"` (chapter 11 fixes this with
  order-preserving encodings).
- **Delete does not erase.** The key and value bytes stay on the page (a free block
  overwrites only their first 4) until a new cell or a compaction covers them, so pages
  with the same records are not always the same bytes.
- **A checksum in the last bytes needs a reserved tail.** After plain `init` the first
  cell ends at byte 4095. Use `initReserved(buf, 4)`; a tail cannot be added later.
- **Nothing here is crash-safe, and `open` checks nothing.** On a corrupt page `stats`
  can follow a free list forever. Verify a checksum or call `validate` on pages read from
  disk (chapters 21 and 22).

## Exercises

1. (easy) Start from the final page of Part 1 (banana@4080, cherry@4062, pea@4054). By
   hand, apply `put fig=purple`, `delete cherry`, `put date=brown`. Give the slot array
   with offsets, `content_start`, the free blocks, `frag_bytes` and the free total. Check
   with the visualization: press End, then type the three operations. Its page is 256
   bytes, so add 3840 to every offset it shows.
2. (easy) `delete` can make the gap grow or create a free block. State the exact condition
   for each, and explain why `deleteAt` resets `content_start` to the end of the content
   area (4096 here) when the last cell goes, instead of calling `freeSpace`.
3. (medium) Write `deleteAtCompacting(index)`, which removes a cell the way Postgres does
   on index pages: close the hole at once by moving the cell bytes below it, then fix the
   slots. With it a page never has free blocks or fragments. For a page of `n` cells of
   `s` bytes each, compare the bytes moved by one delete in both designs.
4. (medium) Change `takeFromFreeBlock` from first fit to best fit (the smallest block that
   is large enough). Rerun Part 3 of the demo. Which printed counters can change, and
   which one cannot change no matter what the policy is? Why?
5. (hard) Redesign the page with Postgres-style 4-byte slots that hold offset and length,
   and cells that are raw bytes without a length header. What happens to the minimum cell
   size, to the free-block trick, to the per-record overhead, and to the bytes touched by
   one probe of the binary search?

Solutions: [solutions.md](solutions.md).

## Where next

- Previous: [09 Pages and the buffer pool](../09-pages-and-the-buffer-pool/README.md).
- Next: [11 Key and record encoding](../11-key-and-record-encoding/README.md) decides what
  the key and value bytes inside a cell look like.
- Chapter 12 copies `slotted_page.zig` / `slotted_page.rs` as its node format; chapter 13
  handles values too large for one page (`CellTooLarge` here); chapter 22 uses the
  reserved tail for chapter 21's CRC-32.
- Visualization: [viz/index.html](viz/index.html).

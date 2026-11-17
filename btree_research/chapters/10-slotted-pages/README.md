# Chapter 10: Slotted pages

Previous: [09 Pages and the buffer pool](../09-pages-and-the-buffer-pool/README.md) |
Next: [11 Key and record encoding](../11-key-and-record-encoding/README.md) |
Visualization: [viz/index.html](viz/index.html)

## What you will learn

- How one fixed 4096-byte page stores a changing number of records of different sizes
  and still keeps them sorted.
- The three places free space hides in such a page (the gap, free blocks, fragments) and
  why "enough free bytes" is not the same as "it fits".
- How a page reuses the holes left by deleted records, and when it has to compact.
- How Turso (the SQLite format) and Postgres lay out the same idea, and where they differ.

Prerequisites: chapter 02 (lower-bound binary search) and chapter 09 (a file is an array of
fixed-size pages). This chapter is about a single node; in chapter 12 every node of a
disk-backed B+tree is one of these pages.

## The idea in plain words

In Part I a node was a struct with an array of `u64` keys. Inserting into the middle
shifted the keys after it, and that was cheap because every key had the same small size.
On disk, keys and values are byte strings of any length. Two problems appear:

1. If records are stored back to back in key order, inserting one in the middle means
   moving every record after it.
2. Records have no fixed position, so "the i-th record" cannot be found by arithmetic,
   and binary search needs exactly that.

A slotted page solves both with one level of indirection. The page has two regions that
grow toward each other:

```
 0        16                                                         4096
 +--------+---------------+----------------------+--------------------+
 | header | slot array -> |      gap (unused)    | <- cell content    |
 +--------+---------------+----------------------+--------------------+
```

- A **cell** is one record: lengths, key bytes, value bytes. Cells are written wherever
  there is room, starting at the end of the page and growing toward the front.
- A **slot** is a 2-byte offset that says where one cell starts. Slots sit right after the
  header and are kept **in key order**.

Slot `i` is at a computable position (`16 + 2*i`), so binary search works: probe a slot,
follow it to the cell, compare keys. Inserting in the middle moves only the 2-byte slots
that come after it. The cells themselves never move because of an insert.

Deleting is harder. Removing a slot is easy, but the cell leaves a hole in the middle of
the content area, and the page has to remember that hole so that a later insert can reuse
it. The page becomes a very small heap allocator, with the usual problem of heaps:
fragmentation. Free space ends up in three forms:

| Form | What it is | Can hold |
|------|------------|----------|
| gap | the unused bytes between the slot array and the lowest cell | a new slot, a new cell |
| free block | a hole of 4 bytes or more left by a deleted cell | a new cell that fits in it |
| fragment | a sliver of 1 to 3 bytes, too small to describe itself | nothing |

A free block describes itself: its first 4 bytes hold the offset of the next free block and
its own size, so the list of holes costs no space outside the holes. That only works if a
hole has at least 4 bytes, which is why a sliver smaller than that can only be counted.

The total of the three is what the page has free, but a cell needs its bytes **in one
piece**. When the total is enough and no single piece is, the page **compacts**: it slides
every cell to the end of the page, and all free bytes become gap. Slot numbers do not
change during compaction; only the offsets stored in the slots do. Whoever refers to a
record by slot number or by key is not disturbed. Whoever kept a raw pointer to the bytes
is.

## A worked example by hand

The header is 16 bytes, a slot is 2 bytes, and a cell is `4 + key length + value length`
bytes (two 2-byte lengths, then key, then value). The page is 4096 bytes. This is Part 1 of
the programs' output, and the default animation in the visualization.

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

Part 2 shows why the distinction between "free" and "fits" matters, and Part 3 runs the
shared random operation stream against one page:

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

After deleting every other cell the page has 2066 free bytes, but the largest piece is 104
bytes. The 507-byte cell still goes in, because the insert compacts first. The last line
of Part 3 is a hash of all 4096 bytes: Zig and Rust end with the identical page image.

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
formats a buffer, `open` wraps one that is already formatted (for example a frame of the
buffer pool from chapter 09). The layout is a block of named constants under a diagram
comment at the top of the file, and every access goes through two helpers, `rd16` and
`wr16`. The file never casts the buffer to a struct, so alignment and the host's byte
order cannot leak into the file format.

The public API is small:

```zig
pub fn init(buf: *[page_size]u8) SlottedPage
pub fn open(buf: *[page_size]u8) SlottedPage
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
pub fn kind(self) u8, setKind(self, u8) void, userArea(self) *[8]u8
```

`search` is the lower bound of chapter 02 with one change: `keys[mid]` becomes
`self.key(mid)`, which reads a slot and follows it. `put` is `search` followed by
`insertAt` (or by a replacement if the key exists).

`insertAt` has two steps. First `allocSpace(size)` reserves bytes for the cell and returns
an *offset*; the cell is written there. Then the slots from `index` on are moved up with
one `@memmove`, and the new slot is written. The check `size + slot_size > freeBytes()`
comes before anything is modified, so a `PageFull` leaves the page byte for byte as it
was (a test compares against a snapshot).

`allocSpace` is the allocation policy:

1. If the gap still has 2 bytes for the new slot, try the free list (`takeFromFreeBlock`,
   first fit). A block with 4 or more bytes to spare gives up its tail and stays in the
   list; otherwise it is unlinked and the 0 to 3 leftover bytes are added to `frag_bytes`.
2. Otherwise use the gap: lower `content_start` by `size`.
3. If the gap is too small for cell plus slot, `compact()` first. After compaction the gap
   equals `freeBytes()`, and the caller already checked that this is enough.

`freeSpace(offset, size)` is the reverse. It walks the free list to find the blocks on both
sides of the freed range and merges with either one if they touch **or are at most 3 bytes
apart**. A range of 1 to 3 bytes between two free ranges cannot be a live cell (a cell is
at least 4 bytes), so it must be a sliver, and merging takes it back out of `frag_bytes`.
If the merged range starts at `content_start`, no block is written at all:
`content_start` moves up and the bytes are gap.

`compact` copies the content area to a 4 KiB scratch array on the stack and rewrites the
cells from the page end in slot order, reading cell lengths from the copy.

`validate` paints every byte of the content area into a 4 KiB map on the stack as "cell"
or "free block", fails if anything is painted twice, and requires that the number of
unpainted bytes equals `frag_bytes`. It also checks that the free list is ascending and
merged, and that slot order is strict key order. A unit test damages a good page in seven
ways and expects the matching error each time.

### Rust

`SlottedPage<'a>` holds `buf: &'a mut [u8; PAGE_SIZE]`. Names, constants, algorithms, tests
and output match the Zig version (`insert_at` for `insertAt`, and so on). Reads take
`&self`, writes take `&mut self`. Slot shifting is `copy_within` (the `@memmove`
equivalent). `PageError` and `ValidateError` are plain enums implementing
`std::error::Error`.

### Differences that matter

- **Stale slices.** In Zig, `page.value(1)` returns a `[]const u8` into the buffer, and
  nothing stops you from using it after `compact()` moved the cell. The Zig test "a slice
  into the page does not survive compaction" shows the address changing. In Rust the same
  program does not compile: `value(&self)` borrows the page, and `compact(&mut self)` needs
  it exclusively. The Rust test has to remember an offset instead of a slice.
- **Aliasing arguments.** `put(k, v)` may compact, so `k` and `v` must not point into the
  page being changed. Zig checks this with an assert on the pointer ranges
  (`assertOutside`). Rust needs no check: a `&[u8]` into the page cannot exist while
  `&mut self` does.
- **Free list for dumps.** Zig's `freeBlocks(out: []FreeBlock)` fills a caller-provided
  buffer; Rust's `free_blocks()` returns a `Vec`. It is the only place in the Rust file
  that allocates, and it is used only by tests and the demo.

Run it:

```
cd zig  && zig build test --summary all && zig build run
cd rust && cargo test && cargo run
```

## In real databases

Everything below was read in the sources under `db_study/` (see `research/turso.md`
sections 2 and 3 and `research/postgres.md` section 1), except where marked.

**Turso (SQLite file format)** is the closest relative of this chapter's page, and the
source of its free-space design.

- A B-tree page is a header (8 bytes for a leaf, 12 for an interior page), an array of
  2-byte cell pointers sorted by key, the unallocated gap, and the cell content area
  growing from the end of the page. The header holds the same bookkeeping fields we use:
  first freeblock, cell count, content area start, fragmented free bytes
  (`turso/core/storage/btree.rs:100-148`, `turso/core/storage/sqlite3_ondisk.rs:82-87`).
- Freeblocks are a chain in ascending offset order; each hole stores `next` and `size` in
  its own first 4 bytes. `find_free_slot` is first fit, shrinks a block from its tail, and
  turns a remainder under 4 bytes into fragment bytes unless the page already has more
  than 57 of them (`btree.rs:9288-9383`, the cap at `:9336`). Our `max_frag_bytes = 60`
  copies that limit.
- `free_cell_range` merges a freed range with the next and previous freeblock, absorbing a
  gap of 1 to 3 bytes and subtracting it from the fragment count, and extends the
  unallocated region instead of creating a freeblock when the range starts at the content
  area (`btree.rs:9797-9970`).
- `allocate_cell_space` tries a freeblock only if the gap has room for the new 2-byte
  pointer, then the gap, then defragments (`btree.rs:10516-10562`). Every allocation is at
  least 4 bytes (`MINIMUM_CELL_SIZE`, `sqlite3_ondisk.rs:82`).
- `compute_free_space` sums gap, freeblocks and fragments (`btree.rs:10433-10513`); the
  page fuzzer `test_fuzz_drop_defragment_insert` (`btree.rs:13883`) and the integrity
  check's coverage checker over cell and freeblock ranges (`btree.rs:8913`) play the role
  of our `validate`.

Differences from our page: integers are big-endian; a cell is self-describing through
varints (chapter 11) instead of two fixed length fields; a 2- or 3-byte cell is padded to
4 bytes (`btree.rs:10522-10524`), where ours is never smaller than its 4-byte header; and
defragmentation has a fast path for one or two freeblocks (`btree.rs:9976-10098`).

**Postgres** uses the same two-regions picture for every page, heap and index
(`postgres/src/include/storage/bufpage.h:24-78`), with different details:

| | This chapter | Turso | Postgres |
|---|---|---|---|
| slot | 2 bytes: offset | 2 bytes: offset (`sqlite3_ondisk.rs:84`) | 4 bytes: 15-bit offset, 2-bit state, 15-bit length (`itemid.h:25-30`) |
| who knows the cell length | the cell (two u16) | the cell (varints) | the slot (`lp_len`) |
| holes after delete | free blocks + fragment count | freeblocks + fragment count | none on index pages: closed at once |
| caller-owned area | 8 header bytes | none (right-most child in the header) | "special space" at the page end |
| slot numbering | from 0 | from 0 | from 1 (`bufpage.h:60-61`) |

- The header keeps `pd_lower` (end of the line pointer array) and `pd_upper` (start of
  tuple data); "a page is full when nothing can be added between pd_lower and pd_upper"
  (`bufpage.h:46-47`, struct at `bufpage.h:184-197`). Free space is just their difference
  (`PageGetFreeSpace`, `postgres/src/backend/storage/page/bufpage.c:918`).
- Inserting shifts line pointers with one `memmove` and copies the tuple to `pd_upper`
  (`PageAddItemExtended`, `bufpage.c:205`, the shuffle at `:338-340`). Tuple sizes are
  rounded up to the platform's maximum alignment (`MAXALIGN`, `bufpage.c:326`); our cells
  are byte-packed.
- Deleting an index tuple closes the hole immediately: `PageIndexTupleDelete` moves all
  tuple data below the deleted tuple up by its size and then adds that size to every line
  pointer that pointed below it (`bufpage.c:1063-1160`). So a Postgres B-tree page has no
  free list and no fragments; the price is a `memmove` of tuple data and a pass over all
  line pointers on each delete.
- nbtree stores sibling links, level and flags in the special space
  (`BTPageOpaqueData`, `postgres/src/include/access/nbtree.h:63-70`) and reserves the first
  slot of a non-rightmost page for the high key (`nbtree.h:368-370`). Both belong to
  chapter 20; our `kind` byte and 8-byte user area are the hook chapter 12 uses for the
  same purpose.

DuckDB, TigerBeetle, Milvus and FAISS are not sources for this chapter.

## Allocator notes

`SlottedPage` never allocates from a heap. It works on the caller's buffer and uses two
4 KiB stack arrays (the scratch copy in `compact`, the byte map in `validate`). The only
`std.mem.Allocator` in the Zig code is `std.testing.allocator`, passed explicitly to the
oracle of the model test; one test runs the model under `checkAllAllocationFailures`. The
counterpart of "allocation failure on insert" for this structure is `error.PageFull`, and
it is tested the same way: the operation fails and the page is unchanged.

The featured allocator is the one **inside the page**: `allocSpace(size) -> offset` and
`freeSpace(offset, size)`, a first-fit free-list allocator with coalescing whose heap is
the content area. It cannot be exposed as a `std.mem.Allocator`, for four reasons:

1. **Cells move.** `std.mem.Allocator.alloc` returns a pointer that must stay valid until
   `free`. Compaction relocates every cell. A compacting allocator needs a level of
   indirection that the caller goes through on every access, and that indirection is the
   slot array. The stable name of a record is its slot index (or its key), never its
   address.
2. **The heap itself moves.** The page is copied to disk, read back into a different
   buffer-pool frame, and evicted. An address inside it means nothing after that; an
   offset from the start of the page still does. This is why `first_free`, the free block
   `next` links and the slots are all 16-bit offsets.
3. **Free needs context the interface does not give.** `Allocator.free(memory)` receives
   only the slice. Our `freeSpace` also has to remove the slot, and deleting the last cell
   resets the whole page.
4. **Failure is routine and has a different meaning.** `error.OutOfMemory` is exceptional.
   `error.PageFull` happens on every page of every tree and means "split me" (chapter 12).

What would go wrong with a different choice: a `FixedBufferAllocator` over the 4096 bytes
is a bump allocator with no reuse, so a page that sees deletes would fill up with dead
bytes until it is rewritten.

In Rust the equivalent idiom is the same code: offsets into a borrowed `[u8; 4096]`. The
borrow checker turns reason 1 from a comment into a compile error.

## Pitfalls

- **Total free space is not allocatable space.** Check `freeBytes()` (or `fits`) to decide
  whether an insert can succeed; never check only the gap or only the largest hole.
- **The slot needs room too.** A hole that fits the cell is useless if the gap has no 2
  bytes for the new slot. `allocSpace` checks this before using a free block; the test
  "a hole that fits the cell is not enough" builds such a page.
- **Slices into the page die on the next mutation.** Copy a key out before you insert or
  delete on the same page. Moving cells between two different pages is fine.
- **Compaction must not read what it has already overwritten.** Take cell sizes from the
  scratch copy: a cell moved earlier may have landed on the header of one not yet moved.
- **Slot indexes are stable across compaction, not across insert and delete.** Slot 3
  after an insert at slot 1 is a different record. Long-lived references use the key and
  search again (chapter 08's cursors did the same).
- **Key order is byte order.** `"10"` sorts before `"9"`, and `"a"` before `"ab"`
  (chapter 11 fixes this with order-preserving encodings).
- **Nothing here is crash-safe.** An insert touches the cell, the slot array and the
  header; a page written halfway is corrupt (chapters 21 and 22).

## Exercises

1. (easy) Start from the final page of Part 1 (banana@4080, cherry@4062, pea@4054). By
   hand, apply `put fig=purple`, `delete cherry`, `put date=brown`. Give the slot array
   with offsets, `content_start`, the free blocks, `frag_bytes` and the free total. Check
   with the visualization.
2. (easy) `delete` can make the gap grow or create a free block. State the exact condition
   for each, and explain why `deleteAt` resets `content_start` to 4096 when the last cell
   goes, instead of calling `freeSpace`.
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
  handles values too large for one page (`CellTooLarge` here).
- Visualization: [viz/index.html](viz/index.html).

# Turso B-tree research notes

Source: `/home/user/ai_lab/db_study/turso`, commit `469c4f4` (shallow clone).
All `file:line` references are relative to that checkout and were read directly from the source.
Anything not read in the source is marked **(unverified)**; arithmetic I did myself from verified formulas is marked **(derived)**.

Files studied (line counts): `core/storage/btree.rs` (16279), `core/storage/sqlite3_ondisk.rs` (2749),
`core/storage/pager.rs` (7430), `core/storage/page_cache.rs` (2013), `core/storage/buffer_pool.rs` (1769),
`core/storage/wal.rs` (10583), `core/storage/state_machines.rs` (58), `core/storage/checksum.rs` (191),
`core/mvcc/cursor.rs` (2408), `core/mvcc/database/mod.rs` (11520), `docs/agent-guides/{storage-format,async-io-model,mvcc,testing}.md`.

Map of `btree.rs` (useful when navigating):

| Lines | Content |
|---|---|
| 100-163 | page header offsets, depth and sibling constants |
| 178-400 | state enums: `DestroyState`, `DeleteState`, `OverwriteCellState`, `BalanceSubState`, `WriteState` |
| 410-445 | `PinGuard` (RAII pin) |
| 596-680 | cursor validity and seek state enums |
| 873-997 | `struct BTreeCursor` |
| 1453-1910 | `get_prev_record`, `process_overflow_read`, `get_next_record` |
| 1931-2052 | `pop_upwards`, `descend`, `move_to_root*`, `move_to_rightmost` |
| 2054-3097 | `tablebtree_move_to`, `indexbtree_move_to`, `tablebtree_seek`, `indexbtree_seek` |
| 3099-3390 | `move_to`, `insert_into_page` |
| 3401-3600 | `balance`, `balance_quick` |
| 3604-4938 | `balance_non_root` |
| 4942-5406 | debug-only post-balance validation |
| 5410-5490 | `balance_root` |
| 5499-5870 | `clear_overflow_pages`, `destroy_btree_contents` |
| 7012-7426 | `insert`, `delete` (trait impl) |
| 8162-8985 | `integrity_check`, `CoverageChecker` |
| 8989-9254 | `PageStack` |
| 9257-10560 | page-level primitives: `CellArray`, `find_free_slot`, `btree_init_page`, `edit_page`, `page_free_array`, `page_insert_array`, `free_cell_range`, `defragment_page*`, `insert_into_cell`, `compute_free_space`, `allocate_cell_space` |
| 10566-10888 | `fill_cell_payload`, `PayloadLimits`, overflow thresholds, `delete_may_need_balancing`, `drop_cell` |
| 10891-end | tests, including fuzzers |

---

## 1. Database file and header

### What it does
The file is an array of fixed-size pages numbered from 1. Page 1 begins with a 100-byte database header; its
B-tree page header starts at byte 100. All multi-byte integers are big-endian. Turso models the header as a
`#[repr(C, packed)]` `Pod` struct of big-endian wrapper types and statically asserts it is exactly 100 bytes.

Page size is a power of two from 512 to 65536; 65536 is stored as the value `1` because the field is 2 bytes.
Default is 4096. "Usable space" = page size - reserved bytes; it must be at least 480.

### Where
- Module doc diagrams: `core/storage/sqlite3_ondisk.rs:1-42`
- `PageSize` (MIN 512, MAX 65536, DEFAULT 4096, MIN_USABLE_SPACE 480): `sqlite3_ondisk.rs:102-150`
- `DatabaseHeader` fields: `sqlite3_ondisk.rs:307-359`; size assert and `usable_space`: `:361-372`; defaults: `:374-402`
- Page-1 offset handling: `core/storage/pager.rs:230-254` (`offset()`, `header_offset_of`)
- `Pager::usable_space` doc: `pager.rs:3075-3079`

### Snippet
```rust
// sqlite3_ondisk.rs:111-118
pub const fn new(size: u32) -> Option<Self> {
    match size {
        512 | 1024 | 2048 | 4096 | 8192 | 16384 | 32768 => Some(Self(U16BE::new(size as u16))),
        // Internally, the value 1 represents 65536, since the on-disk value of the page size in the DB header is 2 bytes.
        PageSize::MAX => Some(Self(U16BE::new(1))),
        _ => None,
    }
}
```
```rust
// sqlite3_ondisk.rs:361-372
impl DatabaseHeader {
    pub const PAGE_ID: usize = 1;
    pub const SIZE: usize = size_of::<Self>();
    const _CHECK: () = { assert!(Self::SIZE == 100); };
    pub fn usable_space(self) -> usize {
        (self.page_size.get() as usize) - (self.reserved_space as usize)
    }
}
```
Header fields that matter to the B-tree: `database_size` (pages), `freelist_trunk_page`, `freelist_pages`,
`reserved_space`, and the three fixed fractions `max_embed_frac = 64`, `min_embed_frac = 32`, `leaf_frac = 32`
(`sqlite3_ondisk.rs:381-384`), which are the constants behind the overflow formulas in section 5.

### Teaching idea
First chapter after "what is a page": a hex-dump viewer of page 1 that colours the 100-byte header and then
the B-tree header at offset 100. Zig/Rust exercise: declare a packed 100-byte struct with big-endian fields
and a compile-time size assertion (Zig `comptime { std.debug.assert(@sizeOf(Header) == 100); }`).

---

## 2. B-tree page layout: header, cell pointer array, content area

### What it does
Every B-tree page is: header (8 bytes leaf, 12 bytes interior) | cell pointer array (2 bytes per cell,
sorted by key) | unallocated gap | cell content area (grows from the end of the page toward the front).
The pointer array is what is kept sorted; the cell bodies sit anywhere in the content area. Insertion in
key order is a `memmove` of 2-byte pointers, not of cell bodies.

Header fields (offsets relative to the header start):

| Off | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | page type | 2 index interior, 5 table interior, 10 index leaf, 13 table leaf |
| 1 | 2 | first freeblock | 0 = none |
| 3 | 2 | cell count | |
| 5 | 2 | cell content area start | 0 means 65536 |
| 7 | 1 | fragmented free bytes | |
| 8 | 4 | right-most child pointer | interior pages only |

Interior vs leaf is decided by `type <= 5` (interior) vs `type > 5` (leaf), a branch-free trick used on hot paths.

### Where
- Offsets and long comments: `core/storage/btree.rs:100-148`
- `PageType` enum: `sqlite3_ondisk.rs:504-538`
- Constants (`MINIMUM_CELL_SIZE = 4`, `CELL_PTR_SIZE_BYTES = 2`, header sizes 12/8): `sqlite3_ondisk.rs:82-87`
- Accessors: `pager.rs:395-431` (`cell_count`, `unallocated_region_*`, `cell_content_area`, `header_size`),
  `pager.rs:466-474` (`rightmost_pointer`), `pager.rs:736-754` (pointer array), `pager.rs:879-900` (`is_leaf`, `is_table`)
- Page initialisation: `btree.rs:9385-9430` (`btree_init_page`)

### Snippet
```rust
// pager.rs:416-431
pub fn cell_content_area(&self) -> u32 {
    let offset = self.read_u16(BTREE_CELL_CONTENT_AREA);
    if offset == 0 { PageSize::MAX } else { offset as u32 }
}
pub fn header_size(&self) -> usize {
    let is_interior = self.read_u8(BTREE_PAGE_TYPE) <= PageType::TableInterior as u8;
    (!is_interior as usize) * LEAF_PAGE_HEADER_SIZE_BYTES
        + (is_interior as usize) * INTERIOR_PAGE_HEADER_SIZE_BYTES
}
```
```rust
// pager.rs:749-754  — cell i lives wherever pointer i says
pub fn cell_get_raw_start_offset(&self, idx: usize) -> usize {
    let cell_pointer_array_start = self.cell_pointer_array_offset();
    let cell_pointer = cell_pointer_array_start + (idx * CELL_PTR_SIZE_BYTES);
    self.read_u16_no_offset(cell_pointer) as usize
}
```

### Teaching idea
"Slotted page" chapter. Animation: two cursors moving toward each other (pointer array growing right,
content area growing left) with the gap shrinking. Small example: a 256-byte slotted page in Zig/Rust with
`insert(idx, bytes)` and `get(idx)`; show that sorting costs 2 bytes per shifted entry.

---

## 3. Free space inside a page: freeblocks, fragments, defragmentation

### What it does
Free space on a page has three forms, and `compute_free_space` sums them:
1. the unallocated gap between the pointer array and the content area;
2. freeblocks: a linked list (ascending offset) of holes of at least 4 bytes inside the content area; each
   hole stores `next:u16, size:u16` in its own first 4 bytes;
3. fragments: holes of 1-3 bytes, too small to hold a freeblock header, counted in the 1-byte header field.

Deleting a cell (`free_cell_range`) either extends the gap (if the cell is at the very start of the content
area) or links a new freeblock, coalescing with the previous/next freeblock; a 1-3 byte gap between adjacent
freeblocks is absorbed and subtracted from the fragment count.

Allocating (`allocate_cell_space`): try a freeblock (`find_free_slot`, first fit; if the remainder is under
4 bytes the block is unlinked and the remainder becomes fragment bytes, refused once fragments exceed 57),
else use the gap, else defragment and then use the gap. Every allocation is at least 4 bytes.

Defragmentation packs cells to the end of the page. There is a fast path (at most 2 freeblocks and few
fragment bytes: `memmove` the blocks between them and patch pointers) and a full path (collect
`(offset,size,pointer_index)` for every cell and rewrite from the page end). `DefragmentedPage<'a>` is a
type-state wrapper: `page_insert_array` only accepts a page proven defragmented at compile time.

### Where
- `compute_free_space`: `btree.rs:10433-10513`
- `allocate_cell_space`: `btree.rs:10516-10562`
- `find_free_slot`: `btree.rs:9288-9383` (fragment cap at `:9334-9338`)
- `free_cell_range`: `btree.rs:9797-9970`
- `defragment_page_fast`: `btree.rs:9976-10098`; `defragment_page`: `btree.rs:10125-10280`; `DefragmentedPage`: `btree.rs:9636-9656`
- `drop_cell` / `shift_pointers_left`: `btree.rs:10852-10888`
- Freeblock read/write helpers: `pager.rs:353-372`

### Snippet
```rust
// btree.rs:10543-10560 (allocate_cell_space, tail)
if unallocated_region_start + CELL_PTR_SIZE_BYTES + amount > cell_content_area_start {
    // There's no room in the unallocated region, so we need to defragment.
    let max_frag_bytes = 4.min(free_space as isize - (CELL_PTR_SIZE_BYTES + amount) as isize);
    defragment_page(page_ref, usable_space, max_frag_bytes)?;
    cell_content_area_start = page_ref.cell_content_area() as usize;
}
// insert the cell -> content area start moves left by that amount.
cell_content_area_start -= amount;
page_ref.write_cell_content_area(cell_content_area_start);
```
```rust
// btree.rs:9824-9829 (free_cell_range, empty freelist case)
if offset == cur_content_area {
    // if the freeblock list is empty and the freed range is exactly at the beginning of the content area,
    // we are not creating a freeblock; instead we are just extending the unallocated region.
    page.write_cell_content_area(end);
} else {
```

### Teaching idea
A chapter "a page is a tiny heap allocator". Interactive: click a cell to delete it and watch a freeblock
appear, two adjacent ones coalesce, a 2-byte sliver become "fragmented bytes", then press "defragment".
Exercise: implement `free(offset,len)` with coalescing and the invariant
`gap + sum(freeblocks) + fragments == usable - header - 2*ncells - sum(cell sizes)`
(this is exactly what `test_fuzz_drop_defragment_insert` asserts, `btree.rs:13883-13961`).

---

## 4. Table B-trees vs index B-trees

### What it does
There are four cell shapes (`BTreeCell`), and the difference between the two tree kinds is visible in them:

| Page type | Cell contents | Carries a record? |
|---|---|---|
| Table interior (5) | `left_child:u32`, `rowid:varint` | No. Pure routing key. |
| Table leaf (13) | `payload_size:varint`, `rowid:varint`, payload, `[overflow:u32]` | Yes |
| Index interior (2) | `left_child:u32`, `payload_size:varint`, payload, `[overflow:u32]` | Yes |
| Index leaf (10) | `payload_size:varint`, payload, `[overflow:u32]` | Yes |

Table B-tree = B+tree: 64-bit rowid keys, every row lives in a leaf, interior cells hold only a copy of a
rowid as a separator ("all rowids <= K are in my left child"). Index B-tree = classic B-tree: the key is the
whole record (index columns + rowid) and an entry stored in an interior cell exists nowhere else, so
interior cells are real entries that a scan must visit.

Consequences verified in the code:
1. Scan: the cursor has a `going_upwards` flag. When forward iteration pops from a child back to an index
   interior page, it stops on the divider cell and returns it as a row before descending into the next
   child. Table trees never stop on interior cells.
2. Seek: table descent picks the first interior cell with `cell_rowid >= rowid`; index descent compares the
   full interior payload and records `eq_seen` so a leaf-level miss can still be answered from an ancestor
   (`SeekResult::TryAdvance`).
3. Split: a table-leaf divider is manufactured (`left page id + rowid of last cell on the left`); the leaf
   cell stays in the leaf. For index pages and table interiors the divider is one of the redistributed
   cells and moves up into the parent.
4. Delete: deleting from an index interior page replaces the cell with its in-order predecessor from a leaf.
   Table deletes always act on leaf cells.
5. Overflow limits differ: table leaf max local payload is `U-35`; index is about a quarter page.
6. `balance_quick` (append fast path) exists only for table leaves.

### Where
- Cell structs: `sqlite3_ondisk.rs:792-843`; decoding `read_btree_cell`: `sqlite3_ondisk.rs:847-972`
- Per-type raw cell length: `pager.rs:785-876`
- Explanation of interior routing: `btree.rs:3101-3120` (comment in `move_to`)
- `going_upwards` field: `btree.rs:887-890`; use in `get_next_record`: `btree.rs:1801-1816`, `:1867-1872`; `pop_upwards`: `btree.rs:1931-1934`
- Index descent decision table: `btree.rs:2410-2449`
- `eq_seen` / `TryAdvance`: `btree.rs:636-643`, `btree.rs:3000-3006`
- Divider construction: `btree.rs:4594-4651`

### Snippet
```rust
// btree.rs:1864-1872 (get_next_record)
if is_leaf {
    return Ok(IOResult::Done(true));
}
if is_index && self.going_upwards {
    // This means we just came up from a child, so now we need to visit the divider cell before going back to another child page.
    // This is because index interior cells have payloads, so unless we do this we will be skipping an entry when traversing the tree.
    self.going_upwards = false;
    return Ok(IOResult::Done(true));
}
```
```rust
// btree.rs:2446-2451 (index interior: is the target in the left subtree?)
match cmp {
    SeekOp::GT => interior_cell_vs_index_key.is_gt(),
    SeekOp::GE { .. } => interior_cell_vs_index_key.is_ge(),
    SeekOp::LE { .. } => interior_cell_vs_index_key.is_gt(),
    SeekOp::LT => interior_cell_vs_index_key.is_ge(),
},
```

### Teaching idea
The pivotal "B-tree vs B+tree" chapter, and SQLite/Turso contains both in one file. Side-by-side
animation of an in-order scan: the table tree's cursor only lights up leaves; the index tree's cursor lights
up the divider between two children. Small example: one generic `Node` type with a `const KEYS_IN_INTERIOR`
flag, and an in-order iterator that differs by exactly one `if`.

---

## 5. Varints, records, cells, and payload overflow

### What it does
**Varint**: 1-9 bytes, big-endian base-128. Bytes 1-8 carry 7 bits with a continuation bit; a 9th byte
carries 8 full bits (total 64). Turso has a 1/2/3-byte fast path, and rejects a 9-byte encoding whose value
would have fit in 8 bytes as corrupt.

**Record** (the payload): `header_size:varint, serial_type:varint..., data...`. Serial types 0-9 are NULL,
1/2/3/4/6/8-byte ints, f64, constant 0, constant 1; 10 and 11 are invalid; even >= 12 is a blob of length
`(N-12)/2`, odd >= 13 text of length `(N-13)/2`.

**Overflow**: if payload size `P` exceeds `X` (max local), only part stays on the B-tree page and the rest
goes to a linked list of overflow pages (`next:u32` then `U-4` data bytes). With `U` = usable size:
- `X` = `U - 35` for table pages, `((U-12)*64/255) - 23` for index pages
- `M` = `((U-12)*32/255) - 23` (min local, all types)
- if `P <= X`: all local. Else `K = M + (P - M) % (U - 4)`; local bytes = `K` if `K <= X`, else `M`.
- The cell then ends with a 4-byte first-overflow-page number.

The `% (U-4)` makes the overflow chain consist of completely full pages wherever possible: the remainder
stays local. `payload_overflows` returns the local size including the 4-byte pointer.

`fill_cell_payload` builds the cell bytes in a `Vec` (header, then local payload), allocating overflow pages
one at a time through the pager; it is a resumable state machine because page allocation can need I/O, and
it holds a `PinGuard` on the current overflow page so the cache cannot evict it mid-chain.

### Where
- `read_varint`: `sqlite3_ondisk.rs:1353-1399`; `varint_len`: `:1458-1467`; `write_varint`: `:1470-1507`
- Serial types: `core/types.rs:3264-3295`; summary table: `docs/agent-guides/storage-format.md:85-98`
- Thresholds: `btree.rs:10798-10832`; `PayloadLimits`: `btree.rs:10771-10796`
- `payload_overflows`: `sqlite3_ondisk.rs:2259-2278`
- `fill_cell_payload`: `btree.rs:10609-10768`
- Reading a chain: `process_overflow_read` `btree.rs:1617-1745`
- Freeing a chain: `clear_overflow_pages` `btree.rs:5499-5570`
- Expected chain length (integrity check): `btree.rs:8381-8393`

### Snippet
```rust
// sqlite3_ondisk.rs:2263-2278
pub fn payload_overflows(payload_size: usize, max_local_bytes: usize,
                         min_local_bytes: usize, usable_size: usize) -> Option<usize> {
    if payload_size <= max_local_bytes {
        return None;
    }
    let mut space_left = min_local_bytes + (payload_size - min_local_bytes) % (usable_size - 4);
    if space_left > max_local_bytes {
        space_left = min_local_bytes;
    }
    Some(space_left + 4)
}
```
```rust
// btree.rs:10808-10817
pub fn payload_overflow_threshold_max(page_type: PageType, usable_space: usize) -> usize {
    match page_type {
        PageType::IndexInterior | PageType::IndexLeaf => {
            ((usable_space - 12) * 64 / 255) - 23 // Index page formula
        }
        PageType::TableInterior | PageType::TableLeaf => {
            usable_space - 35 // Table leaf page formula
        }
    }
}
```

### Teaching idea
Three small standalone exercises: (a) varint encode/decode with property test `decode(encode(x)) == x` and
`varint_len(x) == encode(x).len()` (Turso has exactly these quickcheck tests, `sqlite3_ondisk.rs:2706-2720`);
(b) a record encoder for `(int, text, null)`; (c) an "overflow calculator" widget: slider for payload size,
shows local bytes and number of overflow pages for table vs index. Worked example **(derived)** for U=4096,
table leaf, P=5000: K = 489 + (5000-489) % 4092 = 908 <= 4061, so 908 bytes local + 4-byte pointer, and
exactly one full overflow page of 4092 bytes.

---

## 6. Concrete numbers

Verified constants:

| Quantity | Value | Where |
|---|---|---|
| Page size range / default | 512..65536, 4096 | `sqlite3_ondisk.rs:105-107` |
| Minimum usable space | 480 | `sqlite3_ondisk.rs:108` |
| Leaf / interior page header | 8 / 12 bytes | `sqlite3_ondisk.rs:85-86` |
| Cell pointer | 2 bytes | `sqlite3_ondisk.rs:84` |
| Minimum cell allocation | 4 bytes | `sqlite3_ondisk.rs:82`, `btree.rs:10522-10524` |
| Max fragmented bytes before refusing a freeblock split | >57 refuses (limit 60) | `btree.rs:9334-9338` |
| Max cursor depth | 20 | `btree.rs:157` |
| Siblings balanced at once | 3 in, up to 5 out | `btree.rs:160-163` |
| Underflow threshold | free space > 2/3 of usable | `btree.rs:3428-3429`, `:10848` |
| Freelist trunk capacity | `usable/4 - 2` leaf pointers | `pager.rs:5673-5674` |
| Default page cache | 2000 pages (100000 on wasm), min 200 | `page_cache.rs:14-25` |
| Spill threshold | 90% of capacity | `page_cache.rs:28` |
| SIEVE ref counter max | 3 | `page_cache.rs:35` |
| WAL header / frame header | 32 / 24 bytes | `sqlite3_ondisk.rs:404-405` |
| Page checksum (optional feature) | 8-byte XXH3-64 in reserved tail, 4096-byte pages only | `checksum.rs:4-6`, `:36-48`, `:82-84` |
| Pending-byte page | page containing byte offset 0x40000000 is skipped | `pager.rs:70`, `pager.rs:6038-6043` |
| Max page count | 0xfffffffe | `pager.rs:61` |

Derived for U = 4096 (my arithmetic from the verified formulas):

| Quantity | Value |
|---|---|
| Table max local payload X | 4096 - 35 = **4061** |
| Index max local payload X | (4084*64/255) - 23 = 1025 - 23 = **1002** |
| Min local payload M | (4084*32/255) - 23 = 512 - 23 = **489** |
| Overflow page data | **4092** bytes |
| Freelist trunk capacity | 4096/4 - 2 = **1022** page numbers |
| Table interior cell | 4 + 1..9 bytes, plus 2-byte pointer = 7..15 bytes |
| Table interior fanout | 4084/7 = 583 cells (584 children) for 1-byte rowids; 4084/9 = 453 cells for 3-byte rowids; 4084/15 = 272 cells for 9-byte rowids |
| Index worst-case fanout | largest local index cell = 4 + 2 + 1002 + 4 + 2 (pointer) = 1014 bytes, so 4084/1014 = **4** cells per interior page |
| WAL frame | 24 + 4096 = 4120 bytes |

The index figure matches the source comment "Give a minimum fanout of 4 for index b-trees" (`btree.rs:10805`).
The depth bound comment (`btree.rs:150-157`) reasons from 2^31 pages and minimum fanout 2 at the root and 3
elsewhere.

### Teaching idea
A "back of the envelope" chapter: with fanout ~450 and ~50 rows per leaf, how many rows fit in a tree of
height 3? Let the reader plug in page size and key size and see height vs row count on a log chart.

---

## 7. Cursor: page stack, seek, next/prev

### What it does
A cursor is a root-to-leaf path: `PageStack` holds up to 21 `PageRef`s plus, per level, a `cell_idx` and a
cached `cell_count`. There are no parent pointers and no sibling links on disk, so the stack is the only
way back up. Pages on the stack are pinned (not evictable). `cell_idx` uses sentinels: `-1` = before first
cell, `cell_count` = on the right-most pointer, `cell_count + 1` = past it; `push_backwards` starts at
`i32::MAX`. Pushing a page that is already on the path is reported as corruption (cycle detection).

- `move_to_root_nonblock`: keeps the already pinned root if the stack still holds it.
- `move_to` (descent): per interior page, binary search for the left-most cell whose key satisfies the
  operator; follow its left child, or the right-most pointer if none matches. Table and index have separate
  specialised versions; the binary-search bounds live in `seek_state` so a yield can resume.
- Leaf: second binary search. Results are `Found`, `NotFound`, or `TryAdvance` (range seek whose answer may
  be the first cell of the next leaf, or for indexes an ancestor's divider).
- `get_next_record`: fast path "same leaf, bump index"; otherwise advance on the parent, descend into the
  next child, or pop when exhausted; `ancestor_pages_have_more_children` detects end of tree without I/O
  using the cached counts.
- `move_to_rightmost` caches the right-most leaf page id so repeated appends skip the descent; any balance
  clears that cache.
- Fast path for exact rowid seeks on the leaf the cursor is already on (`try_start_seek_on_current_table_leaf`).
- After a structural change the cursor is marked `RequireSeek` with a saved key (`save_context`) and lazily
  re-seeks (`restore_context`).

### Where
- `PageStack`: `btree.rs:8989-9254` (cycle check `:9012-9021`, pin on push `:9033`, unpin on pop `:9091-9093`)
- `BTreeCursor` struct: `btree.rs:873-997`; validity states: `btree.rs:600-610`; seek states: `btree.rs:660-677`
- `move_to`: `btree.rs:3099-3156`; `tablebtree_move_to`/`_inner`: `btree.rs:2054-2225`; `indexbtree_move_to_inner`: `btree.rs:2364-2542`
- `tablebtree_seek`: `btree.rs:2547-2601`; leaf search: `btree.rs:2678-2802`; `indexbtree_seek_impl`: `btree.rs:2962-3097`
- `get_next_record`: `btree.rs:1759-1906`; `get_prev_record`: `btree.rs:1453-1615`
- `move_to_root_nonblock`: `btree.rs:1971-1988`; `move_to_rightmost`: `btree.rs:1991-2050`; `rewind`: `btree.rs:7649-7672`
- `save_context` / `restore_context`: `btree.rs:6521-6531`, `:6562-6620`

### Snippet
```rust
// btree.rs:2141-2159 (table interior binary search; INCLUSIVE covers GE/LE)
let mut min = state.min_cell_idx;
let mut max = state.max_cell_idx;
while min <= max {
    let cur_cell_idx = (min + max) >> 1;
    let cell_rowid = contents.cell_table_interior_read_rowid(cur_cell_idx as usize)?;
    let is_on_left = if INCLUSIVE { cell_rowid >= rowid } else { /* GT / LT variants */ };
    if is_on_left {
        state.nearest_matching_cell = Some(cur_cell_idx as usize);
        max = cur_cell_idx - 1;
    } else {
        min = cur_cell_idx + 1;
    }
}
```
(The `else` arm above is abbreviated; the full match is at `btree.rs:2148-2156`.)
```rust
// btree.rs:9032-9039 (PageStack::_push)
// Pin the page to prevent it from being evicted while on the stack
page.pin();
self.stack[current] = Some(page);
self.node_states[current] = BTreeNodeState {
    cell_idx: starting_cell_idx,
    cell_count: None, // ... any code pushing a child page onto the stack MUST set the parent page's cell_count.
};
```

### Teaching idea
"Cursors are paths" chapter. Animation: the stack drawn as a column beside the tree, each slot showing
`(page, cell_idx)`; step through `next()` across a leaf boundary to show pop / advance / push. Example:
array-based stack cursor over an in-memory tree with `seek_ge`, `next`, `prev`. A good exercise is the
lower-bound binary search with the "nearest matching cell" variable, then discussing why the right-most
pointer is the fallback.

---

## 8. Insert into a leaf, and the "overflow cell" trick

### What it does
`insert` assumes the caller already positioned the cursor with a seek (`GE { eq_only: true }` lands on the
key or on the slot where it would go). `insert_into_page` is a state machine:
`Start -> (Overwrite | Insert) -> [Balancing] -> Finish`.

- `Start`: mark the leaf dirty; if the cell under the cursor has the same rowid (table) or compares equal
  (index), switch to `Overwrite`.
- `Insert`: `fill_cell_payload` builds the cell bytes (may allocate overflow pages), then
  `insert_into_cell` places them.
- `insert_into_cell`: if `max(len,4) + 2 <= free space`, allocate, copy, shift pointers right, write the
  pointer, bump the count. Otherwise the cell is not written to the page at all: it is pushed to
  `page.overflow_cells` (an in-memory `Vec<OverflowCell { index, payload }>` on the cached page). A
  non-empty `overflow_cells` is the definition of "this page is overfull" and triggers balancing.
- Before balancing, the cursor saves its key; afterwards it re-seeks.

Note the two unrelated meanings of "overflow" in this code base: *overflow pages* (on-disk chains for large
payloads) and *overflow cells* (in-memory cells that did not fit and await balancing). A page with pending
overflow cells is never spilled to disk (`page_cache.rs:530-538`) and never initialised with them present
(`btree.rs:9388-9392`); `free_page` clears them (`pager.rs:5634`), and handing out a freelist page that still
has them is reported as corruption (`pager.rs:5938-5943`, `:5972-5977`).

### Where
- Trait `insert`: `btree.rs:7012-7026`
- `insert_into_page`: `btree.rs:3162-3390` (overwrite detection `:3195-3243`, insert `:3267-3311`, overwrite underflow check `:3341-3345`)
- `_insert_into_cell`: `btree.rs:10325-10411`
- `OverflowCell`: `sqlite3_ondisk.rs:540-544`; field on the page: `pager.rs:153-154`
- `overwrite_cell`: `btree.rs:6276-6372`

### Snippet
```rust
// btree.rs:10339-10348 and 10357-10367 (_insert_into_cell)
let enough_space = if already_has_overflow && !allow_regular_insert_despite_overflow {
    false
} else {
    payload.len().max(MINIMUM_CELL_SIZE) + CELL_PTR_SIZE_BYTES <= free
};
if !enough_space {
    // ...
    let overflow_cell = OverflowCell { index: cell_idx, payload: Pin::new(payload) };
    page.overflow_cells.try_push(overflow_cell)?;
    return Ok(());
}
```

### Teaching idea
Present the design choice: "split first, then insert" (textbook) vs "insert virtually, then rebalance"
(SQLite/Turso). The second makes the balance routine uniform: it just sees a list of cells that must be
laid out. Small example: a leaf struct with `cells: [..]` plus `pending: Option<(usize, Cell)>`.

---

## 9. The balance algorithm

### What it does
`balance()` is a loop over a sub-state machine (`BalanceSubState`), working from the leaf upward:

1. **Start**: page is fine if it has no overflow cells and (it is the root or free space <= 2/3 of usable).
   If fine, stop (or pop to an ancestor that the caller demanded be balanced). Otherwise go to
   `BalanceRoot` if the page has no parent, else `Decide`.
2. **BalanceRoot (balance-deeper)**: allocate a child, copy the whole root (pointer array, content, header,
   overflow cells) into it, turn the root into an empty interior page whose right-most pointer is the child,
   push the child on the stack. The root page number never changes, so the schema entry stays valid. Then
   the child is balanced as a non-root.
3. **Decide**: `balance_quick` applies if: table leaf, exactly one overflow cell, it is the last cell, the
   leaf is the parent's right-most child, and the parent is not page 1. Otherwise pop to the parent and run
   `balance_non_root`.
4. **Quick (append fast path)**: allocate a new right leaf, put only the overflow cell in it, append a divider
   `(old leaf id, largest rowid of old leaf)` to the parent, set the parent's right-most pointer to the new
   leaf, pop, and restart at the parent. The old leaf stays 100% full, good for sequential inserts.
5. **NonRootPickSiblings**: choose up to 3 adjacent siblings around the unbalanced child (first 3 if it is
   the left-most, last 3 if it is the right-most), read them (one `CompletionGroup` for all reads), pin them.
6. **NonRootDoBalancing** (pure computation, no I/O):
   a. Walk siblings right to left; for each divider between them, copy the divider out of the parent and
      `drop_cell` it from the parent (the right-most divider/pointer is kept and patched later).
   b. Build a flat `CellArray`: all cells of sibling 0 (with its overflow cells spliced in at their index),
      then divider 0, then sibling 1, divider 1, sibling 2. For **table leaves the dividers are not added**
      (they carry no data). For interior pages the divider's left-child pointer is rewritten to the left
      sibling's old right-most pointer; for index leaves the 4-byte child pointer is stripped.
   c. Compute current byte usage per page, then **pack left**: push cells right while a page is over
      capacity (adding pages up to 5), pull cells from the right while they fit. Result: prefix sums
      `cell_count_per_page_cumulative` (e.g. `[1,3,6]`).
   d. **Even out, right to left**: move cells from the left page to the right page while that does not make
      the right page larger than the left. The source quotes SQLite: this step "is not optional" because
      left-packing can leave the last sibling empty.
7. **NonRootDoBalancingAllocate**: reuse the old sibling pages, allocate extra ones if the new count is larger.
8. **NonRootDoBalancingFinish**:
   - reassign page numbers so siblings are in ascending page order (helps sequential scans);
   - patch the parent's pointer that referenced the last old sibling to the last new sibling;
   - for each new sibling except the last, build a divider and `insert_into_cell` it into the parent (this may
     overflow the parent, which is how the split propagates up):
     - interior: the cell at the boundary moves up; its old left child becomes the left sibling's right-most
       pointer; the divider's child pointer is set to the left sibling;
     - table leaf: new 4+varint cell with the rowid of the last cell on the left sibling;
     - index leaf: child pointer + the boundary cell, which is removed from the leaf level;
   - rewrite the sibling pages with `edit_page` in an order that never overwrites cells still to be read
     (down pass then up pass);
   - **balance-shallower**: if the parent is the root, now has zero cells, and the single remaining child
     fits (page 1 has 100 fewer bytes), copy the child into the root and free the child: height shrinks.
9. **FreePages**: siblings no longer needed go to the freelist; then back to `Start` with the parent on top
   of the stack, so the loop continues upward while parents are overfull or underfull.

The same routine handles split (3 pages become 4), merge (3 become 2), and redistribution (3 stay 3). There
is no separate "borrow from sibling" or "merge" function.

`edit_page` avoids rebuilding a page from scratch: it frees cells leaving at the front/back
(`page_free_array`), defragments, then inserts cells arriving at the front/back (`page_insert_array`), using
pointer identity into the page buffer to tell which array cells already live on this page.

### Where
- `balance`: `btree.rs:3401-3514` (already-balanced test `:3427-3430`, quick conditions `:3460-3492`)
- `balance_quick`: `btree.rs:3526-3600`
- `balance_root`: `btree.rs:5410-5489`
- `balance_non_root`: `btree.rs:3604-4938`
  - sibling choice `:3693-3713`; OVERFLOW CELL ADJUSTMENT comment `:3730-3751`; sibling reads `:3762-3794`
  - divider removal `:3908-3990`; cell array build `:3992-4107`
  - page sizes `:4160-4189`; pack-left `:4200-4284`; even-out `:4293-4420` (diagrams `:4311-4359`)
  - page number reassignment `:4505-4524`; divider insertion `:4583-4704`; two-pass `edit_page` order `:4720-4810`
  - balance-shallower `:4813-4868`; free pages `:4899-4922`
- `CellArray`: `btree.rs:9257-9284`; `edit_page`: `btree.rs:9436-9530`; `page_free_array`: `:9552-9630`; `page_insert_array`: `:9666-9790`
- State enums: `btree.rs:294-324` (`BalanceSubState`), `:271-278` (`BalanceContext`), `:492-510` (`BalanceInfo`)

### Snippet
```rust
// btree.rs:3427-3430 — when is a page "balanced"?
let free_space = compute_free_space(page, usable_space)?;
let this_level_is_already_balanced = page.overflow_cells.is_empty()
    && (!self.stack.has_parent() || free_space * 3 <= usable_space * 2);
```
```rust
// btree.rs:3578-3594 — balance_quick: the whole "split" for an append
let mut new_divider: [u8; 13] = [0; 13]; // 4 bytes for page number, max 9 bytes for rowid (varint)
new_divider[0..4].copy_from_slice(&(old_rightmost_leaf.get().id() as u32).to_be_bytes());
let largest_rowid = old_rightmost_leaf_contents
    .cell_table_leaf_read_rowid(old_rightmost_leaf_contents.cell_count() - 1)?;
let n = write_varint(&mut new_divider[4..], largest_rowid as u64);
let divider_length = 4 + n;
insert_into_cell(parent_contents, &new_divider[..divider_length],
                 parent_contents.cell_count(), usable_space)?;
parent_contents.write_rightmost_ptr(new_rightmost_leaf.get().id() as u32);
```
```rust
// btree.rs:4384-4390 — even-out stop condition (right would become bigger than left)
let would_not_improve_balance =
    size_right_page + cell_right_size + (CELL_PTR_SIZE_BYTES as i64)
        > size_left_page - (cell_left_size + pointer_size);
if size_right_page != 0 && would_not_improve_balance {
    break;
}
```
```rust
// btree.rs:4622-4630 — table-leaf divider: (left page id, last rowid on the left page)
divider_cell = &mut cell_array.cell_payloads[divider_cell_idx - 1];
let (_, n_bytes_payload) = read_varint(divider_cell)?;
let (rowid, _) = read_varint(&divider_cell[n_bytes_payload..])?;
balance_info.reusable_divider_cell
    .extend_from_slice(&(page.get().id() as u32).to_be_bytes());
write_varint_to_vec(rowid, &mut balance_info.reusable_divider_cell)?;
```

### Teaching idea
This deserves two chapters.
(1) "Splitting the simple way": implement textbook split-in-half for fixed-size keys; then `balance_root`
(tree grows at the top, root page id is stable) and `balance_quick` (append) as the first optimisation,
with a chart comparing fill factor for sequential inserts with and without it.
(2) "One routine to balance them all": the flatten-and-redistribute model. Animation in four frames:
collect (siblings + dividers fall into one strip), pack-left, even-out, write back with new dividers rising
into the parent. Show variable-size cells so the reader sees why balancing is by bytes, not by count. A
compact Rust/Zig example: `fn redistribute(sizes: &[usize], cap: usize) -> Vec<usize>` returning prefix sums,
run on both a table-leaf strip (dividers excluded) and an index strip (one cell per boundary promoted).

---

## 10. Delete

### What it does
`delete()` removes the cell under the cursor; state machine `DeleteState`:

1. `Start`: mark dirty; return if the cursor is not on a row.
2. `DeterminePostBalancingSeekKey`: `delete_may_need_balancing` predicts whether dropping the cell will leave
   the leaf more than 2/3 empty (always true for interior pages, single-cell pages, or pages with overflow
   cells). Only then is the current key copied so the cursor can re-seek after balancing.
3. `FindCell` -> `ClearOverflowPages`: walk and free the overflow chain first.
4. Leaf: `drop_cell` (free the byte range, shift the pointer array left, decrement the count).
5. Interior (index trees): `InteriorNodeReplacement`:
   - `get_prev_record()` moves to the largest entry of the left subtree (always the last cell of a leaf);
   - build a new interior cell = original left-child pointer + that leaf cell's payload (and its overflow
     pointer, so the overflow chain is re-parented without copying);
   - `drop_cell` + `insert_into_cell` at the same index in the interior page (the new cell may be larger and
     become an overflow cell on the interior page);
   - `drop_cell` the predecessor from the leaf.
6. `CheckNeedsBalancing`: leaf underflow and/or interior overflow/underflow. If both, `balance(Some(depth))`
   balances the leaf and forces balancing at the interior page's depth even if levels in between are fine.
7. After balancing: `restore_context` re-seeks with `GE { eq_only: true }` on the deleted key, landing on the
   successor; `skip_advance = true` makes the next `next()` a no-op so `DELETE` loops do not skip a row.
   Without balancing: `stack.retreat()` achieves the same.

Underflow handling is the same `balance_non_root` as for inserts; merging happens when the redistributed
cells fit in fewer pages, and the root collapses via balance-shallower.

### Where
- `delete`: `btree.rs:7041-7426` (flow doc `:7029-7040`)
- `delete_may_need_balancing`: `btree.rs:10836-10848`; `drop_cell`: `btree.rs:10852-10875`
- Interior replacement: `btree.rs:7187-7300`; balance decision: `btree.rs:7302-7370`
- Parent overflow from replacement handled in balance: `btree.rs:3667-3685`, `:3730-3751`
- `clear_overflow_pages`: `btree.rs:5499-5570`
- `skip_advance`: `btree.rs:942-946`, `btree.rs:7411-7417`
- Whole-tree destruction (DROP TABLE / clear): `destroy_btree_contents` `btree.rs:5606-5860`

### Snippet
```rust
// btree.rs:10836-10848
fn delete_may_need_balancing(page: &PageContent, cell_idx: usize, usable_space: usize) -> Result<bool> {
    if !page.is_leaf() || page.cell_count() == 1 || !page.overflow_cells.is_empty() {
        return Ok(true);
    }
    let (_, cell_len) = page.cell_get_raw_region(cell_idx, usable_space)?;
    let free_space_after_delete = compute_free_space(page, usable_space)? + cell_len + 2;
    Ok(free_space_after_delete * 3 > usable_space * 2)
}
```
```rust
// btree.rs:7282-7292 — interior replacement
// First, drop the old cell that is being replaced.
drop_cell(parent_contents, cell_idx, usable_space)?;
// Then, insert the new cell (the predecessor) in its place.
insert_into_cell(parent_contents, &cell_payload, cell_idx, usable_space)?;
// ...
// Step 3: Delete the predecessor cell from the leaf page.
drop_cell(leaf_contents, leaf_cell_idx, usable_space)?;
```

### Teaching idea
Chapter "Deleting is harder than inserting". Animation of predecessor replacement in an index tree: the
deleted interior key fades, the right-most key of the left subtree rises into its slot, then the leaf may
underflow and merge. Contrast with the table tree where a delete can leave a stale separator rowid in the
interior page (the separator only needs to be an upper bound). Discussion point: the 2/3-empty threshold is
lazy on purpose; pages are not kept half full.

---

## 11. Freelist: where freed pages go

### What it does
Freed pages are not returned to the OS. The header holds the first trunk page and a total count. A trunk
page is `next_trunk:u32, leaf_count:u32, leaf_page_numbers:u32...`; leaf pages are just free pages whose
content is irrelevant.

`free_page(page_id)`: bump `freelist_pages`; if there is a trunk with room (`leaf_count < usable/4 - 2`),
append the page number to it; otherwise the freed page itself becomes the new first trunk, pointing at the
old one.

`allocate_page()`: if there is a trunk: when it has leaves, take the **first** leaf pointer (shifting the
rest left) and zero the page; when it has none, hand out the trunk page itself and advance the header to the
next trunk. If there is no freelist, extend the file: `database_size + 1`, skipping the pending-byte page
and (with the `autovacuum` feature) pointer-map pages; fail with `DatabaseFull` beyond the max page count.

Both are state machines with pinned pages carried in the state, since reading the trunk can need I/O.

### Where
- Layout constants: `sqlite3_ondisk.rs:89-97`
- `free_page`: `pager.rs:5588-5725`
- `allocate_page`: `pager.rs:5853-6087` (trunk reuse `:5932-5957`, leaf reuse `:5960-6017`, file growth `:6018-6085`)
- `do_allocate_page` (allocate + `btree_init_page`): `pager.rs:3053-3073`; `allocate_overflow_page`: `pager.rs:3038-3048`
- Integrity check of freelist: `btree.rs:8465-8590`

### Snippet
```rust
// pager.rs:5673-5690 (free_page, AddToTrunk)
let max_free_list_entries =
    (header.usable_space() / FREELIST_LEAF_PTR_SIZE) - RESERVED_SLOTS;
if number_of_leaf_pages < max_free_list_entries as u32 {
    self.add_dirty(&trunk_page)?;
    trunk_page_contents.write_u32_no_offset(
        FREELIST_TRUNK_OFFSET_LEAF_COUNT, number_of_leaf_pages + 1);
    trunk_page_contents.write_u32_no_offset(
        FREELIST_TRUNK_OFFSET_FIRST_LEAF_PTR
            + (number_of_leaf_pages as usize * FREELIST_LEAF_PTR_SIZE),
        page_id as u32);
```

### Teaching idea
Short chapter: "the file never shrinks (without vacuum)". Visual: file as a strip of pages, coloured by role
(B-tree / overflow / trunk / free leaf), and a DELETE storm followed by INSERTs reusing the holes. Example:
a free-list as "linked list of arrays" in ~60 lines.

---

## 12. Pager and page cache

### What it does
The B-tree never touches files. It asks `Pager::read_page(id)` and receives an `Arc<Page>` (`PageRef`).
A `Page` is an `UnsafeCell<PageInner>` holding atomic flags (`LOCKED` = I/O in flight, `DIRTY`, `LOADED`,
`SPILLED`), a `pin_count`, a WAL tag (frame number + checkpoint epoch the content came from), the buffer,
and the in-memory `overflow_cells`. There is no per-page lock; correctness relies on flags, pins and the
single-writer rule.

- **Reading**: `read_page` returns `Done((page, None))` on a cache hit, `Done((page, Some(completion)))` when
  a disk/WAL read was started (caller must yield before touching contents), or `IO(spill)` when the cache had
  to spill first. `pending_reads` memoises the in-flight page so re-entry does not issue duplicate I/O.
  The source of bytes is the newest WAL frame for that page if any (`wal.find_frame`), else the database file.
- **Writing**: before modifying, the B-tree calls `pager.add_dirty(&page)`: records the page id in
  `dirty_pages` (a bitmap), saves the before-image in the sub-journal if a savepoint needs it, sets `DIRTY`.
  Pages are modified in place in the cache.
- **Pinning**: `page.pin()`/`unpin()` is a counter; `PinGuard` is the RAII form. The cursor stack pins every
  page on its path; balance pins siblings; freelist state machines pin pages stored in their state.
- **Eviction**: a SIEVE/GClock variant: intrusive circular list, a clock hand, a 0..3 reference counter
  bumped on `get`. A page is evictable only if (clean or spilled) and not locked, not pinned, not page 1,
  and the cache holds the only `Arc`. The sweep decrements counters and evicts the first evictable page at 0.
- **Spilling**: when the cache passes 90% and not enough clean pages exist, dirty unpinned pages are appended
  to the WAL early (uncommitted frames) and marked `SPILLED`, which makes them evictable. Capacity is a soft
  limit: if nothing can be evicted the page is admitted anyway.
- **Buffers** come from `BufferPool` arenas: one arena of page-sized buffers and one of page+24-byte WAL
  frame buffers (optionally registered with io_uring).

### Where
- `PageInner`: `pager.rs:127-155`; `Page`, flags: `pager.rs:965-987`; pin/unpin: `pager.rs:1105-1146`
- `read_page` contract and body: `pager.rs:3656-3754`; `read_page_no_cache` (WAL vs file): `pager.rs:3610-3654`
- `cache_insert` (spill and soft capacity): `pager.rs:3795-3823`; `add_dirty`: `pager.rs:3919-3941`
- `try_spill_dirty_pages`: `pager.rs:4242-4396`
- `PageCache`: `page_cache.rs:89-117`; `get`: `:421-440`; `spillable`/`evictable`: `:530-538`, `:665-671`; `evict_one`: `:674-740`; `needs_spill`: `:473-495`
- Minimum cache size reasoning: `page_cache.rs:19-25`
- `PinGuard`: `btree.rs:409-445`; `BufferPool`: `buffer_pool.rs:89-114`
- `upsert_page_in_cache` (used when balance renumbers pages): `pager.rs:6089`

### Snippet
```rust
// page_cache.rs:665-671
fn evictable(page: &PageRef) -> bool {
    (!page.is_dirty() || page.is_spilled())
        && !page.is_locked()
        && !page.is_pinned()
        && page.get().id().ne(&DatabaseHeader::PAGE_ID)
        && Arc::strong_count(page) == 1
}
```
```rust
// btree.rs:409-416, 433-437
pub struct PinGuard(PageRef);
impl PinGuard {
    pub fn new(p: PageRef) -> Self { p.pin(); Self(p) }
}
impl Drop for PinGuard {
    fn drop(&mut self) { self.0.try_unpin(); }
}
```

### Teaching idea
Chapter "The B-tree does not own its nodes": introduce the buffer pool as the indirection between page ids
and memory. Animation: a fixed ring of cache slots with the clock hand sweeping, pinned pages shown with a
lock, dirty pages in red, spilled dirty pages hatched. Example: a 4-slot cache with `get(id) -> Handle`,
`Handle::drop` unpins, and an eviction that refuses pinned/dirty pages; then show the bug you get if the
cursor forgets to pin its parent.

---

## 13. Async I/O and re-entrant state machines

### What it does
Turso does not use Rust `async`. Any function that can touch storage returns
`IOResultOr<T> = Result<IOResult<T>, Box<LimboError>>` where `IOResult` is `Done(T)` or `IO(completions)`.
On `IO` the caller returns all the way up to the VDBE/statement loop, the I/O backend is stepped, and the
**same function is called again from the top**. `return_if_io!` is the `?` of this scheme; `io_yield_one!`
returns an `IO`.

Therefore every multi-step B-tree operation stores its progress in the cursor: `CursorState`
(`Write`/`Delete`/`Destroy`), `BalanceState`, `OverflowState`, `seek_state`, `move_to_state`, and the small
enums in `state_machines.rs`. The rule stated in the docs: never mutate state before a point that may yield
unless the mutation is recorded in the state machine, because re-entry will run it again.

Visible effects on the B-tree code:
- Binary-search bounds are persisted (`InteriorPageBinarySearchState`) so a seek can resume mid-page (an
  index key comparison may have to read overflow pages).
- `iteration_pending_descent` exists only because `stack.advance()` has already happened when the child read
  yields; on re-entry the advance must not be repeated.
- `CountState::Descend { target }` has the same purpose for `COUNT(*)`.
- `sibling_load_group` lives in `BalanceState` rather than on the stack, so reads issued before a yield are
  still awaited afterwards.
- `balance_non_root` is split into states exactly at the points that can do I/O (sibling reads, page
  allocation, page freeing); the redistribution maths is one uninterrupted block.
- Borrow-checker workarounds: states are `take()`n out of `self` and put back on `IO` (`btree.rs:3320-3336`).
- Tests inject yields at chosen points to prove re-entrancy (`BTreeWriteYieldPoint`, `btree.rs:383-400`;
  `arm_spill_yield_on_read`, `pager.rs:3828-3830`).

Blocking shims exist for tests and a few FIXMEs: `pager.io.block(|| ...)` loops until `Done`
(e.g. `btree.rs:14776-14778`, and inside balance at `btree.rs:4678-4682`).

### Where
- Types and macros: `core/types.rs:3797-3843`, `core/util.rs:27-31`, VDBE variant `core/vdbe/execute.rs:209-220`
- Guide: `docs/agent-guides/async-io-model.md` (re-entrancy pitfall section, lines 113-160)
- State enums: `core/storage/state_machines.rs:1-58`; `btree.rs:178-400`, `:513-565`
- Pending-descent resume hook: `btree.rs:1768-1785`; field doc `btree.rs:967-973`
- Idempotence notes: `btree.rs:1959-1970` (`move_to_root_nonblock`), `pager.rs:5607-5621` (`free_page`)

### Snippet
```rust
// core/types.rs:3831-3843
macro_rules! return_if_io {
    ($expr:expr) => {
        match $expr {
            Ok(IOResult::Done(v)) => v,
            Ok(IOResult::IO(io)) => return Ok(IOResult::IO(io)),
            Err(err) => { branches::mark_unlikely(); return Err(err.into()); }
        }
    };
}
```
```rust
// btree.rs:5539-5548 (clear_overflow_pages) — commit progress to state before the next yield
return_if_io!(self.pager.free_page(Some(page), next_page_id));
// free_page returned `Done` — commit `next` to state
// BEFORE any fallible IO so re-entry cannot invoke
// `free_page` again on the now-freed page.
if next != 0 {
    self.overflow_state = OverflowState::ReadNext { next };
} else {
    self.overflow_state = OverflowState::Done;
}
```

### Teaching idea
An advanced chapter: "What happens to a recursive algorithm when every page read may suspend?". Start from
a recursive `insert`, convert to an explicit stack, then to a resumable state machine with a fake pager
that returns `Pending` on every first read. Demonstrate the classic bug (`idx += 1` before the yield).
In Zig this maps to a hand-written state enum + `switch` loop; in Rust compare with what `async fn` would
generate. Visualization: a timeline of calls where each re-entry is a row and the state variant is the
colour.

---

## 14. WAL and atomic commit, as far as B-tree pages are concerned

### What it does
The B-tree only dirties cached pages. At commit the pager runs `commit_wal_inner` (`CommitState`):
gather every dirty page id (re-reading any that were spilled and evicted), build WAL frames, write them,
fsync (depending on sync mode), and only then publish them (`commit_prepared_frames` advances `max_frame`
and updates the page-to-frame index), mark pages clean and tag them with their frame. The last frame of a
transaction carries the database size in pages; a frame with non-zero `db_size` is a commit frame. A
checkpoint later copies frames back into the main file.

Atomicity for a multi-page B-tree change (for example a split touching a leaf, a sibling, the parent and
page 1) comes from this: readers and recovery only accept frames up to the last valid commit frame, so
either all pages of the transaction are visible or none.

Frame checksum: SQLite's cumulative two-word checksum over 8 header bytes plus the page, seeded with the
previous frame's checksum (so frames form a chain), with salts copied from the WAL header.

Separately, Turso has an optional per-page checksum (`checksum` feature): XXH3-64 of the first 4088 bytes
stored little-endian in the last 8 bytes, which requires 8 reserved bytes and therefore reduces the usable
size that all B-tree formulas use. It only applies to 4096-byte pages.

Rollback: uncommitted cached pages are discarded and cursors invalidated; statement-level savepoints use a
sub-journal of before-images captured in `add_dirty`.

### Where
- WAL header / frame header structs: `sqlite3_ondisk.rs:404-502`
- `checksum_wal`: `sqlite3_ondisk.rs:2280-2325`; frame preparation: `sqlite3_ondisk.rs:2157-2215`
- Commit states: `pager.rs:1228-1259`; `commit_wal_inner`: `pager.rs:4562-4838`
- `Wal` trait: `wal.rs:641-770`; `commit_prepared_frames` / `finalize_committed_pages`: `wal.rs:4686-4708`; `find_frame`: `wal.rs:3684`
- Spill path uses `append_frames_vectored` (not the commit path): `wal.rs:4715-4721`
- Sub-journal hook: `pager.rs:2221`, called at `pager.rs:3925`
- Page checksum: `checksum.rs:35-84`
- Recovery test that ignores uncommitted checksummed frames: `sqlite3_ondisk.rs:2590`

### Snippet
```rust
// sqlite3_ondisk.rs:2197-2214
pub(crate) fn recompute_wal_frame_checksum(frame: &mut [u8], wal_header: &WalHeader,
                                           prev_checksums: (u32, u32)) -> (u32, u32) {
    let expects_be = wal_header.magic & 1;
    let use_native_endian = cfg!(target_endian = "big") as u32 == expects_be;
    let header_checksum = checksum_wal(&frame[0..8], wal_header, prev_checksums, use_native_endian);
    let final_checksum = checksum_wal(&frame[WAL_FRAME_HEADER_SIZE..], wal_header,
                                      header_checksum, use_native_endian);
    frame[16..20].copy_from_slice(&final_checksum.0.to_be_bytes());
    frame[20..24].copy_from_slice(&final_checksum.1.to_be_bytes());
    final_checksum
}
```

### Teaching idea
One chapter near the end: "A split is five page writes; what if we crash after three?". Diagram of the WAL
as a tape of frames with a commit marker; a slider that "crashes" at any frame and shows which tree the
reader sees. Example: the 10-line Fibonacci-weighted checksum in Zig and Rust, plus a test that flipping
one byte breaks the chain from that frame onward.

---

## 15. MVCC and the B-tree

### What it does
`PRAGMA journal_mode = 'mvcc'` adds an in-memory multi-version row store on top of the B-tree; the B-tree
itself is not versioned.

- `MvStore.rows: SkipMap<RowID, RowVersions>` where `RowID = (table_id, RowKey)`; each index has its own
  skip map keyed by the index record. A `RowVersion` has packed `begin`/`end` timestamps, optional data, and
  `btree_resident` (the row already exists in the B-tree file).
- Commits are written to a logical log (`.db-log`), not as pages.
- Reads use `MvccLazyCursor`, which implements the same `CursorTrait` as `BTreeCursor` and wraps one
  (`btree_cursor: Box<dyn CursorTrait>`). It does a two-way merge: peek the next visible key from the skip
  map and the next key from the B-tree, return the smaller (larger when iterating backwards); on a tie the
  MVCC version wins (`mvcc_key <= btree_key`), which is how in-memory updates and tombstones shadow the
  on-disk row.
- A checkpoint is the only writer to the B-tree in this mode: it replays committed versions through ordinary
  `BTreeCursor` seek/insert/delete inside a pager transaction, then truncates the log.
- Table ids are separate from root pages because a table created in MVCC has no root page until checkpoint
  (`table_id_to_rootpage`; negative root ids are rejected by the pager: `pager.rs:3681`).

So the B-tree chapter content is unchanged by MVCC; the lesson is architectural: the B-tree becomes the
base level of a small LSM-like arrangement (memory versions + log on top, B-tree as the checkpoint target).

### Where
- Guide: `docs/agent-guides/mvcc.md`; design docs: `docs/internals/mvcc/{DESIGN,GC,RECOVERY_SEMANTICS}.md` (not read in detail)
- `MvStore`: `core/mvcc/database/mod.rs:4393-4412`; `RowID`: `:347-351`; `RowVersion`: `:456-476`
- `MvccLazyCursor`: `core/mvcc/cursor.rs:541-581`; merge logic `DualCursorPeek::get_next`: `core/mvcc/cursor.rs:222-275`
- Checkpoint using `BTreeCursor`: `core/mvcc/database/checkpoint.rs:21`, `:320`, `:647`, `:735`
- `CursorTrait` (the shared interface): `btree.rs:716-870`; `is_mvcc` hook: `btree.rs:840`
- Integrity check skips not-yet-allocated MVCC trees: `btree.rs:8409-8425`

### Snippet
```rust
// core/mvcc/cursor.rs:253-266
match (self.mvcc_peek.get_row_key(), self.btree_peek.get_row_key()) {
    (Some(mvcc_key), Some(btree_key)) => {
        if dir == IterationDirection::Forwards {
            // In forwards iteration we want the smaller of the two keys
            if mvcc_key <= btree_key {
                Some((mvcc_key.clone(), false, self.mvcc_peek.get_versions()))
            } else {
                Some((btree_key.clone(), true, None))
            }
        } else if mvcc_key >= btree_key {
            Some((mvcc_key.clone(), false, self.mvcc_peek.get_versions()))
        } else {
            Some((btree_key.clone(), true, None))
```

### Teaching idea
Optional closing chapter: "Layering versions over a B-tree". Example: a merging iterator over a sorted
in-memory map with tombstones and a B-tree cursor; test that results equal applying the map to the tree.

---

## 16. Integrity checks, invariants, and tests

### What the code asserts
`PRAGMA integrity_check` (`integrity_check`, iterative with an explicit page stack to stay re-entrant):
- every cell lies inside `[content_area, usable_space)` (`CellOutOfRange`, `CellOverflowsPage`);
- cells and freeblocks do not overlap, and the gaps between them add up to exactly the header's fragment
  count (`CoverageChecker`: min-heap of ranges, `CellOverlap`, `UnexpectedFragmentation`);
- freeblocks are in ascending order with at least 4 bytes between them (`FreeBlockOutOfOrder`);
- rowids are ordered within a page and bounded by the parent's divider (`CellRowidOutOfRange`; iterates cells
  in reverse with a running upper bound);
- all leaves are at the same depth (`LeafDepthMismatch`);
- overflow chain length equals `ceil((payload - local) / (U-4))` (`OverflowListLengthMismatch`);
- every page is referenced exactly once across trees, overflow chains and the freelist
  (`PageReferencedMultipleTimes`, `PageNeverUsed`), the pending-byte page is unused, and the freelist count
  matches the header (`FreelistCountMismatch`, `FreelistTrunkCorrupt`, `FreelistPointerOutOfRange`).

Runtime invariants (`turso_assert!`, many only with `debug_assertions`):
- `debug_validate_cells!` after page edits: content area does not overlap the pointer array; every cell is
  at least 2 bytes, inside usable space, and a leaf cell does not start with a 0 byte (`btree.rs:10285-10318`);
- pages on the cursor stack are pinned and loaded (`btree.rs:9056-9065`); a child may not be its own ancestor;
- balance: at most 5 output pages (`btree.rs:4210-4213`); collected cell count matches the prediction
  (`btree.rs:4128-4137`); each output page is non-empty (`btree.rs:4409-4416`); every new sibling is pointed
  to by a divider or the right pointer (`btree.rs:4706-4717`); divider left pointer equals the sibling id and
  is within the database size (`btree.rs:4670-4687`);
- `post_balance_non_root_validation` (debug only, `btree.rs:4991-5405`) keeps a byte copy of every cell
  before balancing and verifies each one is found afterwards in the right page or as the right divider, and
  that table dividers carry the correct rowid;
- interior pages only ever get overwrites, never new inserts (`btree.rs:3233-3236`); only an index interior
  page can have an overflow cell in the parent during balancing (`btree.rs:3667-3676`);
- pages with overflow cells cannot be re-initialised or handed out from the freelist
  (`btree.rs:9388-9392`, `pager.rs:5972-5977`).
- Corrupt input is reported as `LimboError::Corrupt` rather than a panic on read paths
  (`return_corrupt!`, `assert_or_bail_corrupt!`, e.g. `sqlite3_ondisk.rs:858-863`, `btree.rs:10447-10510`).

### Tests and what they check
In `btree.rs` (`mod tests`, from line 10891):
- `btree_insert_fuzz_run` (`:12181-12305`): random unique rowids with random payload sizes, commit after each
  insert; periodically walks the tree with `next()` comparing against a sorted model, and runs
  `validate_btree` (`:11560-11675`): strictly increasing keys within a page, uniform child depth, no
  self-referencing child, all children of one page have the same type, no empty non-root page. Variants:
  equal sizes 1..8, random up to 4096, big (3-4 KB), overflow (up to 31 KB) (`:12827-12873`), plus long
  `#[ignore]`d versions.
- `btree_index_insert_fuzz_run` (`:12307`), `btree_index_insert_delete_fuzz_run` (`:12478`, 65% inserts):
  index trees against a model; every expected key must be found by seek (`validate_expected_keys`, `:12643`).
- `leaf_delete_balancing_prediction_matches_underflow_after_drop` (`:12777`): the predictor in section 10
  agrees with the real free space after `drop_cell`.
- Page-level fuzz: `test_fuzz_drop_defragment_insert` (`:13883`): 100000 random insert/drop/defragment steps
  on one page against a model `Vec`, asserting after each step that
  `compute_free_space == 4096 - total_cell_bytes - header`. `test_free_array` (`:14780`), `test_defragment*`,
  `test_tiny_cell_insert_must_not_overlap_cell_pointer_array` (`:14060`), `test_fuzz_victim_*` (saved seeds).
- Overflow: `btree_test_overflow_pages_are_cleared_on_overwrite` (`:11953`), `test_clear_overflow_pages_*`.
- Re-entrancy: `wal_overflowing_insert_resumes_after_yield_before_balance` (`:11347`),
  `process_overflow_read_survives_spill_yield_from_next_chain_read` (`:13256`),
  `count_survives_spill_yield_at_finalization` (`:13300`).
- Allocation failure injection inside B-tree paths: `mod allocation_fault_repro` (`:11026`).
- Cursor stability under peer writes: `mod save_all_cursors` (`:14897`).
- Corruption handling: `table_leaf_oversized_cell_count_reads_corrupt_not_panic` (`:13326`).

Outside the unit tests:
- `tests/fuzz/sqlite_file_format.rs`: real SQLite generates databases at all 8 page sizes in `delete` and
  `wal` journal modes; Turso must read them and agree with SQLite, and `PRAGMA integrity_check` is run
  (`:13-50`, `:310-317`). This is the file-format compatibility oracle.
- `testing/simulator/`: deterministic simulation with randomly generated interaction plans and properties;
  includes a `PRAGMA integrity_check should return ok` property (`generation/property.rs:1903-1930`).
- `testing/concurrent-simulator/chaotic_btree.rs:1-6`: workload designed to stress `balance_non_root` page
  renumbering by deleting key bands (seeding the freelist) and refilling with large payloads under savepoints.
- Also present, not examined: `testing/differential-oracle`, `testing/antithesis`, `testing/sqlancer`,
  `testing/unreliable-libc`, `tlaplus/` (specs named `multiprocess`, `sqlite-tx`), `fuzz/fuzz_targets`
  (expression/schema targets, not B-tree).

### Snippet
```rust
// btree.rs:8943-8965 (CoverageChecker::analyze, core loop)
let mut fragmentation = 0;
let mut prev_end = content_area;
while let Some(cell) = self.heap.pop() {
    let start = cell.0.start;
    if prev_end > start {
        push_integrity_error(errors, IntegrityCheckError::CellOverlap { /* ... */ })?;
        break;
    } else {
        fragmentation += start - prev_end;
        prev_end = cell.0.end;
    }
}
fragmentation += usable_space - prev_end;
if fragmentation != expected_fragmentation { /* UnexpectedFragmentation */ }
```

### Teaching idea
Make "write the checker first" a recurring practice in the guide: every chapter's example ships with a
`check()` function, and a model-based fuzz loop (`BTreeMap`/sorted array as the oracle, fixed seed printed
on failure). A chapter can list the invariants as a table (ordering, separator bounds, uniform depth, byte
accounting on a page, every page referenced once) and map each to a line of checker code.

---

## Most important insights for a learner

1. **A node is a page, and a page is a tiny allocator.** Sorted order lives in a 2-byte pointer array; cell
   bodies are unordered in a heap that grows from the end. Most page-level work is byte accounting
   (gap + freeblocks + fragments), not key logic.
2. **SQLite/Turso contains both B-tree variants.** Table trees are B+trees (routing rowids in interior
   pages, rows only in leaves); index trees are classic B-trees (entries in interior pages). The whole
   difference shows up in a handful of places: cell format, the `going_upwards` visit during scans, divider
   construction in balance, and predecessor replacement in delete.
3. **Balancing is "flatten up to 3 siblings plus their dividers, then redistribute by bytes".** Split, merge
   and rotate are the same routine with a different output page count (1..5). Cells are variable-sized, so
   "half full" is measured in bytes, and the trigger for underflow is lazy (more than 2/3 free).
4. **Overfull is represented, not prevented.** A cell that does not fit is parked in an in-memory overflow
   list on the page; that list being non-empty is the signal to balance, and propagation to the parent uses
   the same mechanism when a divider does not fit.
5. **The tree grows and shrinks at the root, and the root page number never changes.** `balance_root` pushes
   the root's content down into a new child; balance-shallower pulls a lone child back up.
6. **The append fast path matters.** `balance_quick` leaves the old right-most leaf full and starts a new
   one, so sequential rowid inserts give nearly 100% fill instead of 50%.
7. **Cursors are root-to-leaf paths.** No sibling or parent pointers exist on disk; the stack of
   `(page, cell_idx)` is how `next`/`prev` work, and any structural change invalidates it, so cursors save a
   key and re-seek.
8. **Large values leave the tree.** Overflow chains keep fanout predictable; the local/overflow split formula
   is chosen so overflow pages are completely full and index pages keep at least 4 entries.
9. **The B-tree does not own memory or files.** It borrows pinned pages from a cache, marks them dirty, and a
   pager turns the dirty set into WAL frames with a commit marker; that is what makes a multi-page split
   atomic.
10. **I/O shape dictates code shape.** Because any page read may suspend, every algorithm is a resumable
    state machine; much of the 16k lines is about being safe to re-enter.

## Things that are easy to get wrong

- **Page 1 offset.** The B-tree header of page 1 starts at byte 100, but cell pointers are absolute page
  offsets. Root split and balance-shallower must copy between pages with different header offsets
  (`btree.rs:5451-5459`, `:4829-4866`), and page 1 has 100 fewer usable bytes, so a child may not fit back
  (`btree.rs:4816-4819`).
- **Cell content area value 0 means 65536** (`pager.rs:416-423`), and page size 65536 is stored as 1.
- **Minimum cell size is 4 bytes.** A 2- or 3-byte cell still occupies 4 bytes so that it can later become a
  freeblock; forgetting this makes the content area collide with the pointer array (regression test
  `test_tiny_cell_insert_must_not_overlap_cell_pointer_array`, check at `btree.rs:10342-10346`). The same
  padding must be removed when an index leaf cell is promoted to a divider and re-added when it comes back
  (`btree.rs:4632-4646`, `:4066-4073`, `ensure_min_cell_size` `:8896`).
- **Fragment bookkeeping.** Coalescing freeblocks across a 1-3 byte gap must subtract those bytes from the
  fragment counter (`btree.rs:9870-9905`); splitting a freeblock with under 4 bytes left must add them and is
  refused past the limit (`btree.rs:9331-9338`).
- **The right-most child has no cell.** N cells mean N+1 children; the last lives in the header. Cursor code
  uses `cell_count` and `cell_count + 1` as positions for it, and balance must special-case "last sibling is
  the right pointer" (`btree.rs:3715-3719`).
- **Separator semantics.** Left child holds keys `<=` the divider (`btree.rs:3104-3109`). In table trees the
  divider is only a bound and can be stale after deletes; in index trees it is a real entry and must be
  returned by scans exactly once (forward: on the way up; backward seek: `retreat` before descending,
  `btree.rs:2503-2512`).
- **Dividers and child pointers during balance.** When an interior divider is pulled down into the cell
  array, its child pointer must be replaced by the left sibling's old right-most pointer
  (`btree.rs:4077-4082`); when a cell is pushed up, its old child pointer becomes the left sibling's new
  right-most pointer (`btree.rs:4596-4602`). Table-leaf dividers are never part of the redistributed cells
  (`btree.rs:4115-4125`).
- **Raw pointers into a page become invalid when the page is defragmented.** Balance updates the parent's
  right pointer before inserting dividers for this reason (`btree.rs:4540-4551`), and the cell array holds
  `&'static mut [u8]` slices into sibling pages (`to_static_buf`, `btree.rs:9432-9434`) that are only valid
  because those pages are pinned and edited in a strict order (`btree.rs:4720-4744`).
- **Overflow cells shift indexes.** After `drop_cell` + failed `insert_into_cell` in a parent, physical cell
  indexes to the right are off by one (the "OVERFLOW CELL ADJUSTMENT" comment, `btree.rs:3730-3751`).
- **Two different "overflows".** Overflow pages (on disk, large payload) vs overflow cells (in memory,
  pending balance).
- **`payload_overflows` returns local size including the 4-byte pointer**; the payload bytes on the page are
  that minus 4 (`sqlite3_ondisk.rs:2259-2262`, `btree.rs:10676`).
- **Varint edge cases.** The 9th byte carries 8 bits; negative rowids are 9-byte varints (cast through
  `u64`); a 9-byte encoding of a small value is treated as corrupt (`sqlite3_ondisk.rs:1385-1391`).
- **Re-entrancy.** Mutating cursor state before a call that can yield repeats the mutation on resume
  (`docs/agent-guides/async-io-model.md:113-160`; concrete fixes at `btree.rs:1768-1785`, `:5539-5548`).
- **Pin before you depend on a page.** Parents on the cursor stack, siblings during balance, the current
  overflow page while chaining, and freelist pages held in state machines are all pinned explicitly;
  eviction otherwise drops the buffer underneath (`btree.rs:9033`, `:10590-10592`, `pager.rs:5637`).
- **Mark dirty before modifying**, so the savepoint sub-journal captures the before-image
  (`pager.rs:3919-3925`, comment at `pager.rs:5989`).
- **Insert trusts the cursor position.** `insert` only checks the cell under the cursor for an exact match;
  a caller that ignores `TryAdvance` after a seek can insert a duplicate key
  (`btree.rs:12890-12897`, test `btree_index_reinsert_after_tryadvance_never_duplicates`).
- **Delete inside a scan.** After a delete the cursor must not skip the successor: `retreat()` without
  balancing, `skip_advance` after balancing, and an extra `next` after an interior replacement
  (`btree.rs:7386-7417`, `:218-225`).
- **Freelist allocation may return the trunk page itself** when it has no leaves (`pager.rs:5932-5957`), and
  reused pages must be zeroed.
- **Stale comment warning for readers of the source:** the doc comment on `balance()` calls it "a naive
  algorithm" that splits by key count (`btree.rs:3392-3394`), but the implementation below it balances by
  bytes as described in section 9.

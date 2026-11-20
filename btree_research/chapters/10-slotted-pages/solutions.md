# Chapter 10: solutions

Back to the [chapter](README.md).

## 1. Three more operations by hand

Start: `banana@4080 cherry@4062 pea@4054`, `content_start = 4054`, no free blocks,
`frag_bytes = 0`, gap = 4054 - (16 + 3*2) = 4032.

`put fig=purple` is a 13-byte cell. The free list is empty, so it comes from the gap:
`content_start = 4054 - 13 = 4041`, `fig@4041`. In key order `fig` goes between `cherry`
and `pea`, so pea's slot moves up by one.

```
slots: banana@4080 cherry@4062 fig@4041 pea@4054     gap = 4041 - 24 = 4017
```

`delete cherry` frees 18 bytes at 4062..4080. The free list is empty and 4062 is more than
3 bytes above `content_start` (pea and fig are below it), so the range becomes a free
block: `[4062+18]`. The slot array shrinks, so the gap grows by 2 to 4019. Free total:
4019 + 18 = 4037.

`put date=brown` is a 13-byte cell. First fit finds the 18-byte block; 18 - 13 = 5 bytes
remain, which is enough for a free block header, so the cell takes the tail: offset
4062 + 5 = 4067. The block stays at 4062 with size 5.

```
slots: banana@4080 date@4067 fig@4041 pea@4054
content_start = 4041   gap = 4041 - (16 + 4*2) = 4017
free blocks = [4062+5]   frag_bytes = 0   free = 4017 + 5 = 4022
```

In the visualization: load the default scenario, step to the end, then type the three
operations.

## 2. When does a delete grow the gap, and why the reset?

Let the freed range (after merging with neighbouring free blocks) be `[start, end)`.

- If `start <= content_start + 3`, the gap grows: `content_start = end`. The typical case
  is `start == content_start`, the lowest cell. The cases `content_start + 1 .. + 3` occur
  when the lowest bytes of the content area are a sliver left by an earlier allocation: no
  cell can be 1 to 3 bytes long, so those bytes are known to be dead and are taken out of
  `frag_bytes`.
- Otherwise a free block is written at `start` and linked into the list in offset order.

Why reset on the last delete instead of calling `freeSpace`: slivers are only recovered
when a free range next to them is created. A sliver between two cells that are deleted in
the "wrong" order, or two slivers that sit side by side (4 to 6 dead bytes, more than the
3-byte merge window), can outlive every merge. If the last cell went through `freeSpace`,
an empty page could keep `frag_bytes > 0` and a free block forever, and "empty page" would
not have a single canonical header. With zero cells there is nothing that could be live,
so the whole content area is gap by definition, and `content_start` goes back to the end
of the content area (`usableSize()`: 4096 without a reserved tail). Turso does the same
in `drop_cell` (`turso/core/storage/btree.rs:10852-10862`, which writes `usable_space`).

Only the header is canonical. The bytes of the deleted cells are still in the gap, so an
emptied page is not byte for byte the page `init` produced (the test "delete does not
erase" shows it).

## 3. Deleting the Postgres way

Close the hole at once. Everything between `content_start` and the deleted cell slides up
by the cell's size; every slot that pointed below the deleted cell is increased by that
size. This is the algorithm of `PageIndexTupleDelete`
(`postgres/src/backend/storage/page/bufpage.c:1063-1160`), without alignment.

```zig
/// Precondition: the page has no free blocks and no fragments (true if all
/// deletes on this page go through this function).
pub fn deleteAtCompacting(self: SlottedPage, index: usize) void {
    const n = self.count();
    assert(index < n);
    assert(self.rd16(off_first_free) == 0 and self.buf[off_frag_bytes] == 0);
    const off = self.slot(index);
    const size = self.cellSizeAt(off);
    const content_start = self.rd16(off_content_start);

    // 1. Remove the slot.
    const at = header_size + index * slot_size;
    const end = header_size + n * slot_size;
    @memmove(self.buf[at .. end - slot_size], self.buf[at + slot_size .. end]);
    @memset(self.buf[end - slot_size .. end], 0);
    self.wr16(off_cell_count, n - 1);

    // 2. Slide everything below the deleted cell up by `size` bytes.
    @memmove(self.buf[content_start + size .. off + size], self.buf[content_start..off]);
    @memset(self.buf[content_start .. content_start + size], 0);
    self.wr16(off_content_start, content_start + size);

    // 3. Every cell that was below the deleted one has moved.
    for (0..n - 1) |i| {
        const slot_at = header_size + i * slot_size;
        const cell = self.rd16(slot_at);
        if (cell < off) self.wr16(slot_at, cell + size);
    }
}
```

(This function was compiled and tested against `validate` while writing the solution; it
is not part of the chapter's source.)

Cost for a page of `n` cells of `s` bytes, deleting the cell at physical position `p`
counted from the page end (`p = 0` is the cell written first):

| | free-list delete (this chapter) | compacting delete |
|---|---|---|
| slot bytes moved | up to `2(n-1)` | up to `2(n-1)` |
| cell bytes moved | 0 | `s * (n - 1 - p)`: all cells written after it |
| slots rewritten | 0 | `n - 1 - p` |
| bytes written for bookkeeping | 4 (free block header) + header fields | header fields |

The compacting delete pays up to a whole page of `memmove` per delete, but buys a page
whose free space is always one piece: insert never searches a list, never compacts, and
`pd_upper - pd_lower` is the whole free-space computation. The free-list delete is O(1) in
cell bytes, and pays later, once, when an insert needs a compaction. Which is better
depends on whether deletes come one at a time (free list) or in batches, where one pass
can close many holes (`PageIndexMultiDelete`, `bufpage.c:1172`).

## 4. Best fit instead of first fit

```zig
fn takeFromFreeBlock(self: SlottedPage, size: usize) ?usize {
    var best: usize = 0;
    var best_prev: usize = 0;
    var best_size: usize = page_size + 1;
    var prev: usize = 0;
    var block = self.rd16(off_first_free);
    while (block != 0) : ({
        prev = block;
        block = self.rd16(block);
    }) {
        const block_size = self.rd16(block + 2);
        if (block_size < size or block_size >= best_size) continue;
        const rest = block_size - size;
        if (rest < free_block_header_size and self.buf[off_frag_bytes] + rest > max_frag_bytes) continue;
        best = block;
        best_prev = prev;
        best_size = block_size;
    }
    if (best == 0) return null;
    const rest = best_size - size;
    if (rest >= free_block_header_size) {
        self.wr16(best + 2, rest);
        return best + rest;
    }
    self.buf[off_frag_bytes] = @intCast(self.buf[off_frag_bytes] + rest);
    self.wr16(if (best_prev == 0) off_first_free else best_prev, self.rd16(best));
    return best;
}
```

**What cannot change:** every count of `put`, `delete`, `get` and `range`, including the
number of puts refused with `PageFull`, and the final `cells=` and `free=`. Whether an
insert succeeds depends only on `size + slot_size <= freeBytes()`, and `freeBytes()` is
determined by which cells are on the page, not by where they are. The placement policy
decides where a cell goes; it never decides whether it goes. So both policies hold the same
set of records after every operation.

**What can change:** everything about the layout: the number of free blocks, the fragment
bytes, how often an insert has to compact, `content_start`, the gap, and therefore the
hash of the page image. With the code above, the line of Part 3 that reads
`most free blocks at once: 16, most fragment bytes at once: 27` became
`most free blocks at once: 15, most fragment bytes at once: 31` when I ran it. Best fit
leaves smaller leftovers, so it produces slivers more often. In that run the final line
and the hash happened to be the same as with first fit. That is not guaranteed: a
compaction rewrites the page into a layout that depends only on its logical content, so
two policies can meet again after one, but nothing forces them to.

## 5. Postgres-style slots: offset and length in 4 bytes

- **Minimum cell size.** The cell no longer has a header, so a cell can be 1 byte (or 0).
  The free-block trick needs 4 bytes inside every hole, so either cells are padded to 4
  bytes when allocated (what Turso does for 2- and 3-byte cells,
  `turso/core/storage/btree.rs:10522-10524`) or the free list is given up. Postgres gives
  it up: index pages close holes immediately (exercise 3), and heap pages are compacted
  in a separate pass (`PageRepairFragmentation`, `bufpage.c:710`).
- **Free-block trick.** If kept, `freeSpace` gets the length from the slot instead of the
  cell; nothing else changes. Note that the length in the slot must be the *allocated*
  length (after padding) or a second field is needed.
- **Per-record overhead.** Ours: 2 (slot) + 4 (two lengths) = 6 bytes. With a 4-byte slot
  holding offset and total length, the cell still has to say where the key ends, so a
  key/value cell needs one more length: 4 + 2 = 6 bytes, the same. Postgres spends its 4
  bytes differently: 15 bits of offset, 15 bits of length and 2 state bits
  (`postgres/src/include/storage/itemid.h:25-30`), which caps a page at 32 KiB
  (`bufpage.h:180-181`) and gives a per-slot state that our page has no room for.
- **Binary search.** One probe reads a slot and then the key bytes in the cell. With the
  length in the slot, the probe has the cell's size before touching the cell, which can
  save a cache line when keys are compared from a known offset. With the length in the
  cell (ours) the probe reads the cell header first; the key follows it directly, so it
  is usually the same cache line as the first key bytes. Neither design avoids the jump
  from the slot array to the content area, which is the expensive part. Engines that want
  to avoid it store a few key bytes in the slot itself (textbook; not in the sources of
  this guide).
- **Slot shifting on insert** moves 4 bytes per following record instead of 2.

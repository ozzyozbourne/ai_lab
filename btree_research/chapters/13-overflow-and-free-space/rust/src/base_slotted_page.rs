// Copied from chapters/12-disk-backed-bplus-tree/rust/src/base_slotted_page.rs (chapter 13 uses it unchanged), which has it from:
// Copied from chapters/10-slotted-pages/rust/src/slotted_page.rs; unchanged.
//! Chapter 10: a slotted page.
//!
//! A `SlottedPage` stores variable-length key/value cells, sorted by key,
//! inside one caller-provided 4096-byte buffer. It owns no memory and never
//! allocates: every byte of state lives in the buffer, so the buffer can be
//! written to disk and read back as it is (all integers are little-endian).
//!
//! This file depends on `std` only. Chapter 12 copies it as its node format.
//!
//! On-page layout
//! ==============
//!
//! ```text
//!   offset 0                                               usable     4096
//!   +--------+---------------+--------------+----------------+----------+
//!   | header | slot array -> | gap (unused) | <- cell content| reserved |
//!   +--------+---------------+--------------+----------------+----------+
//!   0        16              16 + 2*cell_count   content_start
//!
//!   usable = 4096 - reserved. `reserved` is 0 unless the page was formatted
//!   with `init_reserved`; then the last `reserved` bytes of the buffer belong
//!   to the caller (chapter 22 keeps a 4-byte page checksum there) and this
//!   file never reads or writes them after `init`.
//!
//!   header (16 bytes)
//!     0  u16  cell_count      number of cells = number of slots
//!     2  u16  content_start   offset of the lowest byte of the content area
//!                             (`usable` when the page is empty)
//!     4  u16  first_free      offset of the first free block, 0 = none
//!     6  u8   frag_bytes      free bytes lost in slivers of 1 to 3 bytes
//!     7  u8   kind            caller-defined tag (never read by this file)
//!     8  u8   reserved        size of the reserved tail; written by `init`,
//!                             never changed, so a page read back from disk
//!                             knows where its content area ends
//!     9  [7]  user area       caller-defined (never read by this file);
//!                             chapter 12 keeps a sibling / child page id here
//!
//!   slot i (2 bytes, at 16 + 2*i)
//!     u16 offset of cell i. Slots are ordered by key; cells are not.
//!
//!   cell (4 + key_len + value_len bytes, anywhere in the content area)
//!     0  u16  key_len
//!     2  u16  value_len
//!     4  key bytes, then value bytes
//!
//!   free block (a hole of 4 bytes or more inside the content area)
//!     0  u16  next   offset of the next free block (ascending), 0 = last
//!     2  u16  size   size of this hole in bytes, including these 4 bytes
//! ```
//!
//! Free space therefore has three forms, and `free_bytes` is their sum:
//!   1. the gap between the slot array and `content_start`,
//!   2. the free blocks (holes left by deleted cells),
//!   3. `frag_bytes` (slivers too small to hold a free block header).
//!
//! Only the gap can hold a new slot, and only the gap or one single free
//! block can hold a new cell. When the bytes exist but not in one piece,
//! `compact` slides all cells to the end of the page and turns everything
//! free into gap.
//!
//! The page never hands out references that stay valid across a change:
//! `key(i)` / `value(i)` borrow the page, so the borrow checker rejects any
//! mutation while such a slice is alive.

use std::fmt;

pub const PAGE_SIZE: usize = 4096;

// --- header field offsets -------------------------------------------------
const OFF_CELL_COUNT: usize = 0;
const OFF_CONTENT_START: usize = 2;
const OFF_FIRST_FREE: usize = 4;
const OFF_FRAG_BYTES: usize = 6;
const OFF_KIND: usize = 7;
const OFF_RESERVED: usize = 8;
pub const OFF_USER_AREA: usize = 9;
pub const USER_AREA_SIZE: usize = 7;
pub const HEADER_SIZE: usize = 16;

/// One slot: the u16 offset of a cell.
pub const SLOT_SIZE: usize = 2;
/// Cell header: key_len u16 + value_len u16.
pub const CELL_HEADER_SIZE: usize = 4;
/// Free block header: next u16 + size u16. Because a cell is never smaller
/// than its 4-byte header, every freed cell can hold a free block header.
pub const FREE_BLOCK_HEADER_SIZE: usize = 4;
/// Upper bound for `frag_bytes`. Above it the allocator refuses to create
/// more slivers and uses the gap (or compacts) instead. Same bound as SQLite's
/// limit of 60 fragmented bytes; the test is slightly different (SQLite will
/// not use up a block once the page has more than 57, we compare the sum).
pub const MAX_FRAG_BYTES: usize = 60;
/// The largest cell that fits in an empty page without a reserved tail
/// (header + one slot + cell). An upper bound for every page; the exact
/// limit of one page is `max_cell_size()`.
pub const MAX_CELL_SIZE: usize = PAGE_SIZE - HEADER_SIZE - SLOT_SIZE;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PageError {
    /// Not enough free bytes on this page. The page is unchanged.
    /// The caller (a B-tree) reacts by splitting the page.
    PageFull,
    /// The cell could not fit even in an empty page. The page is unchanged.
    CellTooLarge,
}

impl fmt::Display for PageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

impl std::error::Error for PageError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValidateError {
    BadHeader,
    SlotOutOfRange,
    CellOverlap,
    FreeListCorrupt,
    FragmentMismatch,
    KeysOutOfOrder,
}

impl fmt::Display for ValidateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(self, f)
    }
}

impl std::error::Error for ValidateError {}

/// Result of `search`: `index` is the slot of the key if `found`, otherwise
/// the slot where the key would have to be inserted (lower bound).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchResult {
    pub found: bool,
    pub index: usize,
}

/// A summary of where the bytes of the page are. `free_bytes` is always
/// `gap + free_block_bytes + frag_bytes`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stats {
    pub cell_count: usize,
    pub content_start: usize,
    pub gap: usize,
    pub free_block_count: usize,
    pub free_block_bytes: usize,
    pub largest_free_block: usize,
    pub frag_bytes: usize,
    pub free_bytes: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FreeBlock {
    pub offset: usize,
    pub size: usize,
}

/// Total bytes a cell with this key and value occupies in the content area.
pub const fn cell_size(key_len: usize, value_len: usize) -> usize {
    CELL_HEADER_SIZE + key_len + value_len
}

pub struct SlottedPage<'a> {
    buf: &'a mut [u8; PAGE_SIZE],
}

impl<'a> SlottedPage<'a> {
    // ---- construction -----------------------------------------------------

    /// Format `buf` as an empty page (zeroes all 4096 bytes) and wrap it.
    pub fn init(buf: &'a mut [u8; PAGE_SIZE]) -> Self {
        Self::init_reserved(buf, 0)
    }

    /// Like `init`, but the last `reserved_bytes` bytes of the buffer are
    /// left to the caller: the content area ends at `4096 - reserved_bytes`.
    /// The buffer is zeroed once, here; afterwards no method reads or writes
    /// the reserved tail. The number is stored in the header, so `open`
    /// needs no argument.
    pub fn init_reserved(buf: &'a mut [u8; PAGE_SIZE], reserved_bytes: u8) -> Self {
        buf.fill(0);
        let mut page = SlottedPage { buf };
        page.buf[OFF_RESERVED] = reserved_bytes;
        page.wr16(OFF_CONTENT_START, page.usable_size());
        page
    }

    /// Wrap a buffer that already holds a formatted page (for example one
    /// read from disk). Nothing is checked, and the other methods trust the
    /// page: on a damaged one they can panic or follow a free list that
    /// never ends. A page that comes from disk must pass a checksum or
    /// `validate` (which is safe on any bytes) before it is used.
    pub fn open(buf: &'a mut [u8; PAGE_SIZE]) -> Self {
        SlottedPage { buf }
    }

    // ---- the reserved tail ------------------------------------------------

    /// Size of the reserved tail in bytes (0 for a page made by `init`).
    pub fn reserved_size(&self) -> usize {
        self.buf[OFF_RESERVED] as usize
    }

    /// Where the content area ends: `PAGE_SIZE - reserved_size()`.
    pub fn usable_size(&self) -> usize {
        PAGE_SIZE - self.reserved_size()
    }

    /// The reserved tail itself, `buf[usable_size()..]`: the caller's bytes.
    pub fn reserved_area(&self) -> &[u8] {
        &self.buf[self.usable_size()..]
    }

    pub fn reserved_area_mut(&mut self) -> &mut [u8] {
        let usable = self.usable_size();
        &mut self.buf[usable..]
    }

    /// The largest cell that fits in this page when it is empty.
    pub fn max_cell_size(&self) -> usize {
        self.usable_size() - HEADER_SIZE - SLOT_SIZE
    }

    /// The raw page image (what would be written to disk).
    pub fn bytes(&self) -> &[u8; PAGE_SIZE] {
        self.buf
    }

    // ---- reading ------------------------------------------------------------

    pub fn count(&self) -> usize {
        self.rd16(OFF_CELL_COUNT)
    }

    /// Key of the cell in slot `index`. The slice borrows the page, so no
    /// `put`, `insert_at`, `delete`, `delete_at` or `compact` can run while
    /// it is alive.
    pub fn key(&self, index: usize) -> &[u8] {
        let off = self.slot(index);
        let start = off + CELL_HEADER_SIZE;
        &self.buf[start..start + self.rd16(off)]
    }

    /// Value of the cell in slot `index`. Same lifetime rule as `key`.
    pub fn value(&self, index: usize) -> &[u8] {
        let off = self.slot(index);
        let start = off + CELL_HEADER_SIZE + self.rd16(off);
        &self.buf[start..start + self.rd16(off + 2)]
    }

    /// Binary search over the slot array (lower bound). Each probe follows
    /// one slot to its cell; keys compare as byte strings (memcmp order, a
    /// prefix sorts before a longer key).
    pub fn search(&self, wanted: &[u8]) -> SearchResult {
        let mut lo = 0;
        let mut hi = self.count();
        // Invariant: every key before `lo` is < wanted, every key at or
        // after `hi` is >= wanted.
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if self.key(mid) < wanted {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        let found = lo < self.count() && self.key(lo) == wanted;
        SearchResult { found, index: lo }
    }

    /// Value stored under `wanted`, or `None`. Same lifetime rule as `key`.
    pub fn get(&self, wanted: &[u8]) -> Option<&[u8]> {
        let r = self.search(wanted);
        r.found.then(|| self.value(r.index))
    }

    // ---- writing ------------------------------------------------------------

    /// Insert or overwrite. On error the page is unchanged.
    /// (`k` and `v` cannot point into this page: `&mut self` forbids it.)
    pub fn put(&mut self, k: &[u8], v: &[u8]) -> Result<(), PageError> {
        let r = self.search(k);
        if !r.found {
            return self.insert_at(r.index, k, v);
        }

        let off = self.slot(r.index);
        let old_size = self.cell_size_at(off);
        let new_size = cell_size(k.len(), v.len());
        if new_size == old_size {
            // Same size: overwrite the value bytes where they are.
            let start = off + CELL_HEADER_SIZE + k.len();
            self.buf[start..start + v.len()].copy_from_slice(v);
            return Ok(());
        }
        // Different size: the old cell and its slot are given back first, so
        // the new cell needs `new_size` bytes out of `free + old_size`.
        if new_size > self.max_cell_size() {
            return Err(PageError::CellTooLarge);
        }
        if new_size > self.free_bytes() + old_size {
            return Err(PageError::PageFull);
        }
        self.delete_at(r.index);
        self.insert_at(r.index, k, v)
            .expect("checked just above: the cell fits");
        Ok(())
    }

    /// Remove `wanted`. Returns false if it was not on the page.
    pub fn delete(&mut self, wanted: &[u8]) -> bool {
        let r = self.search(wanted);
        if r.found {
            self.delete_at(r.index);
        }
        r.found
    }

    /// Insert a cell so that it becomes slot `index` (0 <= index <= count).
    /// The caller is responsible for key order: the key must sort after slot
    /// `index - 1` and before the cell currently in slot `index`. `put` does
    /// the search for you; a B-tree split uses `insert_at` to append cells it
    /// already has in order. On error the page is unchanged.
    pub fn insert_at(&mut self, index: usize, k: &[u8], v: &[u8]) -> Result<(), PageError> {
        let n = self.count();
        assert!(index <= n);
        debug_assert!(index == 0 || self.key(index - 1) < k);
        debug_assert!(index == n || k < self.key(index));

        let size = cell_size(k.len(), v.len());
        if size > self.max_cell_size() {
            return Err(PageError::CellTooLarge);
        }
        if size + SLOT_SIZE > self.free_bytes() {
            return Err(PageError::PageFull);
        }

        // 1. Find room for the cell body. May compact, which moves cells but
        //    never changes which slot refers to which cell.
        let off = self.alloc_space(size);
        self.wr16(off, k.len());
        self.wr16(off + 2, v.len());
        let key_start = off + CELL_HEADER_SIZE;
        self.buf[key_start..key_start + k.len()].copy_from_slice(k);
        self.buf[key_start + k.len()..key_start + k.len() + v.len()].copy_from_slice(v);

        // 2. Open a hole in the slot array: slots index..n move up by one
        //    slot. This is the whole cost of keeping the page sorted: 2 bytes
        //    per following cell, no cell body moves.
        let at = HEADER_SIZE + index * SLOT_SIZE;
        let end = HEADER_SIZE + n * SLOT_SIZE;
        self.buf.copy_within(at..end, at + SLOT_SIZE);
        self.wr16(at, off);
        self.wr16(OFF_CELL_COUNT, n + 1);
        Ok(())
    }

    /// Remove the cell in slot `index`; later slots move down by one.
    pub fn delete_at(&mut self, index: usize) {
        let n = self.count();
        assert!(index < n);
        let off = self.slot(index);
        let size = self.cell_size_at(off);

        // Close the hole in the slot array.
        let at = HEADER_SIZE + index * SLOT_SIZE;
        let end = HEADER_SIZE + n * SLOT_SIZE;
        self.buf.copy_within(at + SLOT_SIZE..end, at);
        self.buf[end - SLOT_SIZE..end].fill(0);
        self.wr16(OFF_CELL_COUNT, n - 1);

        if n == 1 {
            // Last cell gone: everything is gap again. This also recovers
            // slivers that no neighbouring free block could absorb.
            // The cell's bytes are not erased (see `compact`).
            self.wr16(OFF_CONTENT_START, self.usable_size());
            self.wr16(OFF_FIRST_FREE, 0);
            self.buf[OFF_FRAG_BYTES] = 0;
        } else {
            self.free_space(off, size);
        }
    }

    /// Slide every cell to the end of the page (slot 0 ends up last) so that
    /// all free bytes form one gap. Slot indexes do not change; cell offsets
    /// do. Called automatically by `insert_at` when the bytes exist but not
    /// in one piece.
    pub fn compact(&mut self) {
        // Cells would overwrite each other if moved in place in slot order,
        // so read them from a copy of the content area. 4 KiB of stack.
        let mut scratch = [0u8; PAGE_SIZE];
        let old_start = self.rd16(OFF_CONTENT_START);
        let usable = self.usable_size();
        scratch[old_start..usable].copy_from_slice(&self.buf[old_start..usable]);

        let mut top = usable;
        for i in 0..self.count() {
            let off = self.slot(i);
            // Lengths come from the copy: the live cell header at `off` may
            // already have been overwritten by a cell moved earlier.
            let key_len = u16::from_le_bytes([scratch[off], scratch[off + 1]]) as usize;
            let value_len = u16::from_le_bytes([scratch[off + 2], scratch[off + 3]]) as usize;
            let size = cell_size(key_len, value_len);
            top -= size;
            self.buf[top..top + size].copy_from_slice(&scratch[off..off + size]);
            self.wr16(HEADER_SIZE + i * SLOT_SIZE, top);
        }
        // Zero the new gap. This keeps dumps readable; it is not an erase
        // guarantee. `delete_at` leaves the bytes of a deleted cell where
        // they are (a free block overwrites only its first 4), and they stay
        // on the page until a compaction or a new cell happens to cover them.
        let slots_end = HEADER_SIZE + self.count() * SLOT_SIZE;
        self.buf[slots_end..top].fill(0);
        self.wr16(OFF_CONTENT_START, top);
        self.wr16(OFF_FIRST_FREE, 0);
        self.buf[OFF_FRAG_BYTES] = 0;
    }

    // ---- free-space accounting ----------------------------------------------

    /// Total free bytes: gap + free blocks + fragments. A cell of `size`
    /// bytes can be inserted if and only if `size + SLOT_SIZE <= free_bytes()`.
    pub fn free_bytes(&self) -> usize {
        self.stats().free_bytes
    }

    /// True if `put`/`insert_at` of a new key with these lengths would succeed.
    pub fn fits(&self, key_len: usize, value_len: usize) -> bool {
        cell_size(key_len, value_len) + SLOT_SIZE <= self.free_bytes()
    }

    pub fn stats(&self) -> Stats {
        let n = self.count();
        let content_start = self.rd16(OFF_CONTENT_START);
        let mut s = Stats {
            cell_count: n,
            content_start,
            gap: content_start - (HEADER_SIZE + n * SLOT_SIZE),
            free_block_count: 0,
            free_block_bytes: 0,
            largest_free_block: 0,
            frag_bytes: self.buf[OFF_FRAG_BYTES] as usize,
            free_bytes: 0,
        };
        let mut block = self.rd16(OFF_FIRST_FREE);
        while block != 0 {
            let size = self.rd16(block + 2);
            s.free_block_count += 1;
            s.free_block_bytes += size;
            s.largest_free_block = s.largest_free_block.max(size);
            block = self.rd16(block);
        }
        s.free_bytes = s.gap + s.free_block_bytes + s.frag_bytes;
        s
    }

    /// The offset of the cell in slot `index` (for dumps and visualizations).
    pub fn cell_offset(&self, index: usize) -> usize {
        self.slot(index)
    }

    /// The free list in ascending offset order. For dumps and tests (this is
    /// the only method that allocates; the Zig twin fills a caller buffer).
    pub fn free_blocks(&self) -> Vec<FreeBlock> {
        let mut out = Vec::new();
        let mut block = self.rd16(OFF_FIRST_FREE);
        while block != 0 {
            out.push(FreeBlock {
                offset: block,
                size: self.rd16(block + 2),
            });
            block = self.rd16(block);
        }
        out
    }

    // ---- caller-owned header bytes ------------------------------------------

    pub fn kind(&self) -> u8 {
        self.buf[OFF_KIND]
    }

    pub fn set_kind(&mut self, k: u8) {
        self.buf[OFF_KIND] = k;
    }

    /// Seven header bytes this file never interprets. A caller that needs
    /// more per-page state asks for a reserved tail (`init_reserved`).
    pub fn user_area(&self) -> &[u8; USER_AREA_SIZE] {
        self.buf[OFF_USER_AREA..OFF_USER_AREA + USER_AREA_SIZE]
            .try_into()
            .expect("slice has USER_AREA_SIZE bytes")
    }

    pub fn user_area_mut(&mut self) -> &mut [u8; USER_AREA_SIZE] {
        (&mut self.buf[OFF_USER_AREA..OFF_USER_AREA + USER_AREA_SIZE])
            .try_into()
            .expect("slice has USER_AREA_SIZE bytes")
    }

    // ---- the allocator inside the page --------------------------------------
    //
    // `alloc_space` and `free_space` are a tiny heap allocator whose heap is
    // the content area. They deal in *offsets*, never references, and an
    // offset is only meaningful until the next compaction (see the README).

    /// Reserve `size` bytes in the content area and return their offset.
    /// Precondition (checked by `insert_at`): size + SLOT_SIZE <= free_bytes().
    /// Postcondition: the gap can still take one more slot.
    fn alloc_space(&mut self, size: usize) -> usize {
        debug_assert!(size >= FREE_BLOCK_HEADER_SIZE);
        let slots_end = HEADER_SIZE + self.count() * SLOT_SIZE;
        let mut content_start = self.rd16(OFF_CONTENT_START);

        // 1. Reuse a hole, but only if the gap can still take the new slot.
        if content_start - slots_end >= SLOT_SIZE
            && let Some(off) = self.take_from_free_block(size)
        {
            return off;
        }
        // 2. Otherwise carve from the gap, compacting first if the gap alone
        //    is too small. After compaction gap == free_bytes(), so it fits.
        if content_start - slots_end < size + SLOT_SIZE {
            self.compact();
            content_start = self.rd16(OFF_CONTENT_START);
        }
        content_start -= size;
        self.wr16(OFF_CONTENT_START, content_start);
        content_start
    }

    /// First fit over the free list. Returns `None` if no block is big enough.
    fn take_from_free_block(&mut self, size: usize) -> Option<usize> {
        let mut prev = 0; // 0 = the list head in the page header
        let mut block = self.rd16(OFF_FIRST_FREE);
        while block != 0 {
            let block_size = self.rd16(block + 2);
            if block_size >= size {
                let rest = block_size - size;
                if rest >= FREE_BLOCK_HEADER_SIZE {
                    // Take the tail. The block keeps its offset and its `next`
                    // link; only its size shrinks, so no link has to be patched.
                    self.wr16(block + 2, rest);
                    return Some(block + rest);
                }
                // The whole block is used. The 0 to 3 bytes left over cannot
                // hold a free block header: they become fragment bytes,
                // tracked only as a count. Refuse if that would pass the cap.
                let frag = self.buf[OFF_FRAG_BYTES] as usize;
                if frag + rest <= MAX_FRAG_BYTES {
                    self.buf[OFF_FRAG_BYTES] = (frag + rest) as u8;
                    let next = self.rd16(block);
                    self.wr16(if prev == 0 { OFF_FIRST_FREE } else { prev }, next);
                    return Some(block);
                }
            }
            prev = block;
            block = self.rd16(block);
        }
        None
    }

    /// Give `size` bytes at `offset` back. Keeps the free list sorted by
    /// offset and merges the range with its neighbours.
    fn free_space(&mut self, offset: usize, size: usize) {
        debug_assert!(size >= FREE_BLOCK_HEADER_SIZE);
        let mut start = offset;
        let mut end = offset + size;
        let mut frag = self.buf[OFF_FRAG_BYTES] as usize;
        let content_start = self.rd16(OFF_CONTENT_START);

        // Find the free blocks on both sides of the range.
        let mut prev = 0;
        let mut next = self.rd16(OFF_FIRST_FREE);
        while next != 0 && next < start {
            prev = next;
            next = self.rd16(next);
        }

        // Up to 3 bytes between two free ranges cannot be a cell (a cell is at
        // least 4 bytes), so they must be a sliver counted in frag_bytes.
        // Merging swallows the sliver and takes it out of that count.
        const SLIVER_MAX: usize = FREE_BLOCK_HEADER_SIZE - 1;
        if next != 0 && end + SLIVER_MAX >= next {
            frag -= next - end;
            end = next + self.rd16(next + 2);
            next = self.rd16(next);
        }
        if prev != 0 {
            let prev_end = prev + self.rd16(prev + 2);
            if prev_end + SLIVER_MAX >= start {
                frag -= start - prev_end;
                start = prev;
                // `prev` is now the block being rewritten; find its own
                // predecessor so the link to it can be kept.
                prev = self.predecessor_of(start);
            }
        }
        if start <= content_start + SLIVER_MAX {
            // The range touches the low end of the content area: grow the gap
            // instead of creating a block. (prev is 0 here: a block below
            // `start` would lie inside the 3 bytes we just ruled out.)
            frag -= start - content_start;
            self.wr16(OFF_CONTENT_START, end);
            self.wr16(OFF_FIRST_FREE, next);
        } else {
            self.wr16(start, next);
            self.wr16(start + 2, end - start);
            self.wr16(if prev == 0 { OFF_FIRST_FREE } else { prev }, start);
        }
        self.buf[OFF_FRAG_BYTES] = frag as u8;
    }

    /// The free block whose `next` is `block`, or 0 if `block` is the head.
    fn predecessor_of(&self, block: usize) -> usize {
        let mut prev = 0;
        let mut cur = self.rd16(OFF_FIRST_FREE);
        while cur != block {
            prev = cur;
            cur = self.rd16(cur);
        }
        prev
    }

    // ---- validation -----------------------------------------------------------

    /// Check every invariant of the layout. Paints each byte of the content
    /// area as "cell" or "free block" in a 4 KiB map on the stack; whatever
    /// stays unpainted must be exactly `frag_bytes`.
    pub fn validate(&self) -> Result<(), ValidateError> {
        let n = self.count();
        let slots_end = HEADER_SIZE + n * SLOT_SIZE;
        let content_start = self.rd16(OFF_CONTENT_START);
        // Nothing below may reach into the reserved tail: every upper bound
        // is `usable`, not `PAGE_SIZE`.
        let usable = self.usable_size();
        if slots_end > content_start || content_start > usable {
            return Err(ValidateError::BadHeader);
        }

        let mut owner = [0u8; PAGE_SIZE]; // 0 = unclaimed, 1 = cell, 2 = free block

        // Cells: inside the content area, not overlapping.
        for i in 0..n {
            let off = self.slot(i);
            if off < content_start || off + CELL_HEADER_SIZE > usable {
                return Err(ValidateError::SlotOutOfRange);
            }
            let end = off + self.cell_size_at(off);
            if end > usable {
                return Err(ValidateError::SlotOutOfRange);
            }
            for o in &mut owner[off..end] {
                if *o != 0 {
                    return Err(ValidateError::CellOverlap);
                }
                *o = 1;
            }
        }

        // Free list: ascending, each block >= 4 bytes, at least 4 bytes after
        // the end of the previous one (closer blocks must have been merged),
        // and at least 4 bytes above content_start (else it would be gap).
        let mut min_start = content_start + FREE_BLOCK_HEADER_SIZE;
        let mut block = self.rd16(OFF_FIRST_FREE);
        while block != 0 {
            if block < min_start || block + FREE_BLOCK_HEADER_SIZE > usable {
                return Err(ValidateError::FreeListCorrupt);
            }
            let size = self.rd16(block + 2);
            if size < FREE_BLOCK_HEADER_SIZE || block + size > usable {
                return Err(ValidateError::FreeListCorrupt);
            }
            for o in &mut owner[block..block + size] {
                if *o != 0 {
                    return Err(ValidateError::CellOverlap);
                }
                *o = 2;
            }
            min_start = block + size + FREE_BLOCK_HEADER_SIZE;
            block = self.rd16(block);
        }

        // Every content byte is a cell, a free block, or a counted fragment.
        let unclaimed = owner[content_start..usable]
            .iter()
            .filter(|&&o| o == 0)
            .count();
        if unclaimed != self.buf[OFF_FRAG_BYTES] as usize || unclaimed > MAX_FRAG_BYTES {
            return Err(ValidateError::FragmentMismatch);
        }

        // Slot order is key order, without duplicates.
        for i in 1..n {
            if self.key(i - 1) >= self.key(i) {
                return Err(ValidateError::KeysOutOfOrder);
            }
        }
        Ok(())
    }

    // ---- small helpers --------------------------------------------------------

    fn rd16(&self, off: usize) -> usize {
        u16::from_le_bytes([self.buf[off], self.buf[off + 1]]) as usize
    }

    fn wr16(&mut self, off: usize, v: usize) {
        let v = u16::try_from(v).expect("page offsets and lengths fit in 16 bits");
        self.buf[off..off + 2].copy_from_slice(&v.to_le_bytes());
    }

    fn slot(&self, index: usize) -> usize {
        assert!(index < self.count());
        self.rd16(HEADER_SIZE + index * SLOT_SIZE)
    }

    fn cell_size_at(&self, off: usize) -> usize {
        cell_size(self.rd16(off), self.rd16(off + 2))
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn fb(offset: usize, size: usize) -> FreeBlock {
        FreeBlock { offset, size }
    }

    fn expect_cell(page: &SlottedPage, index: usize, k: &str, v: &str) {
        assert_eq!(page.key(index), k.as_bytes());
        assert_eq!(page.value(index), v.as_bytes());
    }

    fn name(i: usize) -> String {
        format!("k{i:03}")
    }

    #[test]
    fn layout_constants() {
        assert_eq!(HEADER_SIZE, 16);
        assert_eq!(MAX_CELL_SIZE, 4078);
        assert_eq!(OFF_USER_AREA + USER_AREA_SIZE, HEADER_SIZE);
        assert_eq!(cell_size("mango".len(), "yellow".len()), 15);
    }

    #[test]
    fn empty_page() {
        let mut buf = [0xAAu8; PAGE_SIZE];
        let mut page = SlottedPage::init(&mut buf);
        page.validate().unwrap();
        assert_eq!(page.count(), 0);
        assert_eq!(page.free_bytes(), PAGE_SIZE - HEADER_SIZE);
        assert_eq!(page.get(b"x"), None);
        assert!(!page.delete(b"x"));
        assert_eq!(
            page.search(b"x"),
            SearchResult {
                found: false,
                index: 0
            }
        );
    }

    #[test]
    fn put_keeps_slots_sorted_while_cells_stay_where_they_were_written() {
        let mut buf = [0u8; PAGE_SIZE];
        let mut page = SlottedPage::init(&mut buf);
        page.put(b"mango", b"yellow").unwrap();
        page.put(b"apple", b"red").unwrap();
        page.put(b"kiwi", b"green").unwrap();
        page.validate().unwrap();

        expect_cell(&page, 0, "apple", "red");
        expect_cell(&page, 1, "kiwi", "green");
        expect_cell(&page, 2, "mango", "yellow");
        // Physical order is insertion order, growing down from the page end.
        assert_eq!(page.cell_offset(2), 4081); // mango, first written
        assert_eq!(page.cell_offset(0), 4069); // apple
        assert_eq!(page.cell_offset(1), 4056); // kiwi
        assert_eq!(page.stats().content_start, 4056);

        assert_eq!(page.get(b"kiwi"), Some(&b"green"[..]));
        assert_eq!(page.get(b"kiwj"), None);
        assert_eq!(
            page.search(b"kiwi"),
            SearchResult {
                found: true,
                index: 1
            }
        );
        assert_eq!(
            page.search(b"banana"),
            SearchResult {
                found: false,
                index: 1
            }
        );
        assert_eq!(
            page.search(b"zebra"),
            SearchResult {
                found: false,
                index: 3
            }
        );
    }

    #[test]
    fn keys_compare_as_byte_strings_empty_key_and_empty_value_are_legal() {
        let mut buf = [0u8; PAGE_SIZE];
        let mut page = SlottedPage::init(&mut buf);
        page.put(b"ab", b"2").unwrap();
        page.put(b"a", b"1").unwrap();
        page.put(b"", b"").unwrap();
        page.put(b"abc", b"").unwrap();
        page.put(&[0xff, 0x00], b"high").unwrap();
        page.validate().unwrap();
        expect_cell(&page, 0, "", "");
        expect_cell(&page, 1, "a", "1");
        expect_cell(&page, 2, "ab", "2");
        expect_cell(&page, 3, "abc", "");
        assert_eq!(page.value(4), b"high");
        assert_eq!(page.get(b""), Some(&b""[..]));
    }

    #[test]
    fn put_overwrites_same_size_in_place_different_size_relocates() {
        let mut buf = [0u8; PAGE_SIZE];
        let mut page = SlottedPage::init(&mut buf);
        page.put(b"a", b"111").unwrap();
        page.put(b"b", b"222").unwrap();
        let before = page.cell_offset(0);

        page.put(b"a", b"999").unwrap(); // same size
        assert_eq!(page.cell_offset(0), before);
        assert_eq!(page.get(b"a"), Some(&b"999"[..]));

        page.put(b"a", b"a longer value").unwrap(); // grows
        page.put(b"b", b"").unwrap(); // shrinks
        page.validate().unwrap();
        assert_eq!(page.count(), 2);
        assert_eq!(page.get(b"a"), Some(&b"a longer value"[..]));
        assert_eq!(page.get(b"b"), Some(&b""[..]));
    }

    #[test]
    fn delete_free_block_coalescing_tail_reuse_fragment_gap_growth() {
        let mut buf = [0u8; PAGE_SIZE];
        let mut page = SlottedPage::init(&mut buf);
        page.put(b"mango", b"yellow").unwrap(); // 15 bytes at 4081
        page.put(b"apple", b"red").unwrap(); // 12 bytes at 4069
        page.put(b"kiwi", b"green").unwrap(); // 13 bytes at 4056
        page.put(b"cherry", b"dark red").unwrap(); // 18 bytes at 4038
        page.put(b"fig", b"purple").unwrap(); // 13 bytes at 4025

        // A cell in the middle of the content area becomes a free block.
        assert!(page.delete(b"kiwi"));
        assert_eq!(page.free_blocks(), [fb(4056, 13)]);
        // Its physical neighbour is freed: the two holes merge into one.
        assert!(page.delete(b"apple"));
        assert_eq!(page.free_blocks(), [fb(4056, 25)]);
        page.validate().unwrap();

        // A 16-byte cell takes the tail of the 25-byte block; 9 bytes remain.
        page.put(b"banana", b"yellow").unwrap();
        assert_eq!(page.cell_offset(0), 4065);
        assert_eq!(page.free_blocks(), [fb(4056, 9)]);

        // An 8-byte cell uses the block up; the 1 byte left over is a fragment.
        page.put(b"pea", b"g").unwrap();
        assert_eq!(page.cell_offset(4), 4056);
        assert_eq!(page.stats().free_block_count, 0);
        assert_eq!(page.stats().frag_bytes, 1);
        page.validate().unwrap();

        // The lowest cell is freed: the gap grows, no free block is created.
        assert!(page.delete(b"fig"));
        assert_eq!(page.stats().content_start, 4038);
        assert_eq!(page.stats().free_block_count, 0);

        // The cell at the very end of the page becomes a block again.
        assert!(page.delete(b"mango"));
        assert_eq!(page.free_blocks(), [fb(4081, 15)]);
        page.validate().unwrap();

        let free_before = page.free_bytes();
        page.compact();
        page.validate().unwrap();
        let s = page.stats();
        assert_eq!(s.free_bytes, free_before);
        assert_eq!(s.gap, s.free_bytes); // everything free is gap now
        assert_eq!(s.frag_bytes, 0);
        assert_eq!(s.content_start, 4054);
        expect_cell(&page, 0, "banana", "yellow");
        expect_cell(&page, 1, "cherry", "dark red");
        expect_cell(&page, 2, "pea", "g");
        assert_eq!(page.cell_offset(0), 4080); // slot 0 is now last on the page
    }

    #[test]
    fn freeing_between_two_free_blocks_merges_all_three_and_absorbs_a_sliver() {
        let mut buf = [0u8; PAGE_SIZE];
        let mut page = SlottedPage::init(&mut buf);
        // Five 10-byte cells: a@4086 b@4076 c@4066 d@4056 e@4046.
        for k in ["a", "b", "c", "d", "e"] {
            page.put(k.as_bytes(), b"12345").unwrap();
        }
        assert!(page.delete(b"b"));
        // A 9-byte cell fills b's 10-byte hole at 4076 and leaves a sliver at 4085.
        page.put(b"f", b"1234").unwrap();
        assert_eq!(page.cell_offset(4), 4076);
        assert_eq!(page.stats().frag_bytes, 1);
        // Free a (above the sliver) and c (below f): two separate blocks.
        assert!(page.delete(b"a"));
        assert!(page.delete(b"c"));
        assert_eq!(page.free_blocks(), [fb(4066, 10), fb(4086, 10)]);
        // Free f: it touches c's block below and is 1 byte short of a's block
        // above. All of it, sliver included, becomes one block.
        assert!(page.delete(b"f"));
        assert_eq!(page.free_blocks(), [fb(4066, 30)]);
        assert_eq!(page.stats().frag_bytes, 0);
        page.validate().unwrap();
        // Deleting the last cells returns the page to its pristine accounting.
        assert!(page.delete(b"d"));
        assert!(page.delete(b"e"));
        assert_eq!(page.stats().gap, PAGE_SIZE - HEADER_SIZE);
        page.validate().unwrap();
    }

    #[test]
    fn page_full_and_cell_too_large_leave_the_page_byte_for_byte_unchanged() {
        let mut buf = [0u8; PAGE_SIZE];
        let mut page = SlottedPage::init(&mut buf);
        let big = [b'v'; MAX_CELL_SIZE];

        // Exactly the largest cell fits an empty page; one byte more never does.
        let r = page.put(b"k", &big[..MAX_CELL_SIZE - CELL_HEADER_SIZE]);
        assert_eq!(r, Err(PageError::CellTooLarge));
        page.put(b"k", &big[..MAX_CELL_SIZE - CELL_HEADER_SIZE - 1])
            .unwrap();
        assert_eq!(page.free_bytes(), 0);
        page.validate().unwrap();

        let snapshot = *page.bytes();
        assert_eq!(page.put(b"l", b""), Err(PageError::PageFull));
        assert_eq!(page.insert_at(1, b"l", b""), Err(PageError::PageFull));
        assert_eq!(page.put(b"k", &big), Err(PageError::CellTooLarge)); // replace path
        assert_eq!(page.bytes(), &snapshot);
        assert!(!page.fits(1, 0));

        // Replacing with something smaller works on a full page...
        page.put(b"k", b"small").unwrap();
        page.validate().unwrap();
        // ...and replacing with something that cannot fit fails without losing the old value.
        page.put(b"j", &big[..4000]).unwrap();
        let snapshot = *page.bytes();
        assert_eq!(page.put(b"k", &big[..200]), Err(PageError::PageFull));
        assert_eq!(page.bytes(), &snapshot);
        assert_eq!(page.get(b"k"), Some(&b"small"[..]));
    }

    #[test]
    fn insert_compacts_by_itself_when_free_bytes_exist_but_not_in_one_piece() {
        let mut buf = [0u8; PAGE_SIZE];
        let mut page = SlottedPage::init(&mut buf);
        let filler = [b'.'; 96];

        // Fill the page with 104-byte cells, then delete every other one.
        let mut n = 0;
        while page.fits(4, filler.len()) {
            page.put(name(n).as_bytes(), &filler).unwrap();
            n += 1;
        }
        assert_eq!(n, 38);
        for i in (0..n).step_by(2) {
            assert!(page.delete(name(i).as_bytes()));
        }
        page.validate().unwrap();
        let before = page.stats();
        assert_eq!(before.free_block_count, 19);
        assert_eq!(before.largest_free_block, 104);
        let need = cell_size("big".len(), 500) + SLOT_SIZE; // 509
        assert!(before.gap < need && before.free_bytes >= need);

        // No hole and no gap is big enough, but the page as a whole is.
        let big = [b'B'; 500];
        page.put(b"big", &big).unwrap();
        page.validate().unwrap();
        let after = page.stats();
        assert_eq!(after.free_block_count, 0);
        assert_eq!(after.free_bytes, before.free_bytes - need);
        assert_eq!(page.count(), 20);
        assert_eq!(page.get(b"big"), Some(&big[..]));
        assert_eq!(page.get(b"k001"), Some(&filler[..]));
    }

    #[test]
    fn a_hole_that_fits_the_cell_is_not_enough_the_new_slot_needs_gap_too() {
        let mut buf = [0u8; PAGE_SIZE];
        let mut page = SlottedPage::init(&mut buf);
        let a = [b'a'; 15];
        let c = [b'c'; MAX_CELL_SIZE];
        page.put(b"a", &a).unwrap(); // 20-byte cell
        page.put(b"b", &a).unwrap(); // 20-byte cell
        let rest = page.free_bytes() - SLOT_SIZE - CELL_HEADER_SIZE - 1;
        page.put(b"c", &c[..rest]).unwrap(); // exactly full
        assert_eq!(page.stats().gap, 0);

        assert!(page.delete(b"b")); // 20-byte hole; the freed slot is the only gap
        page.put(b"d", b"12345").unwrap(); // 10-byte cell from the tail of the hole; its slot uses the gap
        assert_eq!(page.stats().gap, 0);
        assert_eq!(page.stats().largest_free_block, 10);

        // An 8-byte cell fits the 10-byte hole, but there is no gap for slot 3.
        // The insert must compact (the hole becomes gap) instead of failing.
        page.put(b"e", b"123").unwrap();
        page.validate().unwrap();
        assert_eq!(page.free_bytes(), 0);
        assert_eq!(page.get(b"e"), Some(&b"123"[..]));
        assert_eq!(page.get(b"a"), Some(&a[..]));
    }

    #[test]
    fn an_offset_into_the_page_does_not_survive_compaction() {
        // The Zig twin keeps a stale slice across `compact`. Here the borrow
        // checker refuses that program (`page.value(1)` borrows `page`), so
        // the test remembers the offset instead.
        let mut buf = [0u8; PAGE_SIZE];
        let mut page = SlottedPage::init(&mut buf);
        page.put(b"a", b"first").unwrap();
        page.put(b"b", b"second").unwrap();
        let stale_offset = page.cell_offset(1);
        assert!(page.delete(b"a"));
        page.compact();
        // The cell moved; the slot (the stable name) still finds it.
        assert_ne!(page.cell_offset(0), stale_offset);
        assert_eq!(page.get(b"b"), Some(&b"second"[..]));
    }

    #[test]
    fn kind_and_user_area_belong_to_the_caller_and_survive_every_operation() {
        let mut buf = [0u8; PAGE_SIZE];
        let mut page = SlottedPage::init(&mut buf);
        page.set_kind(7);
        *page.user_area_mut() = [0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11];
        page.put(b"a", b"1").unwrap();
        page.put(b"b", b"2").unwrap();
        assert!(page.delete(b"a"));
        page.compact();
        page.validate().unwrap();
        assert_eq!(page.kind(), 7);
        assert_eq!(
            page.user_area(),
            &[0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11]
        );
        assert_eq!(page.reserved_size(), 0); // the user area is next to it
    }

    #[test]
    fn open_sees_what_init_and_put_wrote() {
        let mut buf = [0u8; PAGE_SIZE];
        {
            let mut page = SlottedPage::init(&mut buf);
            page.put(b"k1", b"v1").unwrap();
            page.put(b"k0", b"v0").unwrap();
        }
        let mut copy = buf; // "write to disk, read back"
        let page = SlottedPage::open(&mut copy);
        page.validate().unwrap();
        expect_cell(&page, 0, "k0", "v0");
        expect_cell(&page, 1, "k1", "v1");
    }

    #[test]
    fn validate_detects_each_kind_of_corruption() {
        let mut good = [0u8; PAGE_SIZE];
        {
            let mut page = SlottedPage::init(&mut good);
            for k in ["a", "b", "c", "d"] {
                page.put(k.as_bytes(), b"12345").unwrap();
            }
            assert!(page.delete(b"b")); // free block at 4076, size 10
            page.validate().unwrap();
        }
        // Apply one corruption to a fresh copy and return what validate says.
        let corrupt = |damage: &dyn Fn(&mut SlottedPage)| {
            let mut buf = good;
            let mut page = SlottedPage::open(&mut buf);
            damage(&mut page);
            page.validate()
        };

        // content_start below the slot array
        let r = corrupt(&|p| p.wr16(OFF_CONTENT_START, 10));
        assert_eq!(r, Err(ValidateError::BadHeader));
        // a slot pointing into the gap
        let r = corrupt(&|p| p.wr16(HEADER_SIZE, 100));
        assert_eq!(r, Err(ValidateError::SlotOutOfRange));
        // two slots pointing at the same cell
        let r = corrupt(&|p| p.wr16(HEADER_SIZE, p.rd16(HEADER_SIZE + SLOT_SIZE)));
        assert_eq!(r, Err(ValidateError::CellOverlap));
        // a free block that claims bytes of a live cell
        let r = corrupt(&|p| p.wr16(4076 + 2, 14));
        assert_eq!(r, Err(ValidateError::CellOverlap));
        // a free block smaller than its own header
        let r = corrupt(&|p| p.wr16(4076 + 2, 3));
        assert_eq!(r, Err(ValidateError::FreeListCorrupt));
        // a hole that nobody accounts for
        let r = corrupt(&|p| p.wr16(OFF_FIRST_FREE, 0));
        assert_eq!(r, Err(ValidateError::FragmentMismatch));
        // slots out of key order
        let r = corrupt(&|p| {
            let s0 = p.rd16(HEADER_SIZE);
            p.wr16(HEADER_SIZE, p.rd16(HEADER_SIZE + SLOT_SIZE));
            p.wr16(HEADER_SIZE + SLOT_SIZE, s0);
        });
        assert_eq!(r, Err(ValidateError::KeysOutOfOrder));
        assert_eq!(corrupt(&|_| {}), Ok(()));
    }

    #[test]
    fn delete_does_not_erase_an_emptied_page_has_inits_header_not_inits_bytes() {
        let mut fresh = [0xAAu8; PAGE_SIZE];
        SlottedPage::init(&mut fresh);
        let mut buf = [0u8; PAGE_SIZE];
        let mut page = SlottedPage::init(&mut buf);
        page.put(b"secret-key", b"secret-value").unwrap();
        assert!(page.delete(b"secret-key"));
        page.validate().unwrap();
        // Every header field is back to what `init` wrote...
        assert_eq!(buf[..HEADER_SIZE], fresh[..HEADER_SIZE]);
        // ...but the cell's bytes are still on the page, in what is now gap.
        assert_ne!(buf, fresh);
        assert_eq!(&buf[PAGE_SIZE - 22..], b"secret-keysecret-value");
        // Two pages with the same records are therefore not always the same bytes.
    }

    fn tail_intact(page: &SlottedPage) {
        page.validate().unwrap();
        assert!(page.reserved_area().iter().all(|&b| b == 0xA5));
    }

    #[test]
    fn reserved_tail_the_content_area_ends_before_it_and_no_operation_touches_it() {
        for r in [4u8, 32, 255] {
            let mut buf = [0u8; PAGE_SIZE];
            let mut page = SlottedPage::init_reserved(&mut buf, r);
            let usable = PAGE_SIZE - r as usize;
            // The caller owns the tail from now on; fill it with a pattern.
            assert_eq!(page.reserved_area().len(), r as usize);
            page.reserved_area_mut().fill(0xA5);

            assert_eq!(page.usable_size(), usable);
            assert_eq!(page.stats().content_start, usable);
            assert_eq!(page.free_bytes(), usable - HEADER_SIZE);
            assert_eq!(page.max_cell_size(), usable - HEADER_SIZE - SLOT_SIZE);

            // The first cell ends exactly where the tail begins.
            page.put(b"mango", b"yellow").unwrap();
            assert_eq!(page.cell_offset(0), usable - 15);
            tail_intact(&page);
            // Deleting the last cell resets content_start to `usable`, not 4096.
            assert!(page.delete(b"mango"));
            assert_eq!(page.stats().content_start, usable);
            tail_intact(&page);

            // The largest cell is smaller by `r`; it fills the page to the byte.
            let big = [b'v'; MAX_CELL_SIZE];
            let max_value = page.max_cell_size() - CELL_HEADER_SIZE - 1;
            let too_large = Err(PageError::CellTooLarge);
            assert_eq!(page.put(b"k", &big[..max_value + 1]), too_large);
            page.put(b"k", &big[..max_value]).unwrap();
            assert_eq!(page.free_bytes(), 0);
            assert_eq!(page.put(b"l", b""), Err(PageError::PageFull));
            assert_eq!(page.put(b"k", &big[..max_value + 1]), too_large); // replace path
            tail_intact(&page);
            assert!(page.delete(b"k"));

            // Free blocks, a fragment, merging and compaction next to the tail.
            for k in ["a", "b", "c", "d"] {
                page.put(k.as_bytes(), b"12345").unwrap();
            }
            assert_eq!(page.cell_offset(0), usable - 10);
            assert!(page.delete(b"a")); // free block that ends at `usable`
            assert_eq!(page.free_blocks(), [fb(usable - 10, 10)]);
            tail_intact(&page);
            page.put(b"e", b"1234").unwrap(); // 9 of the 10 bytes: 1 fragment byte
            assert_eq!(page.stats().frag_bytes, 1);
            tail_intact(&page);
            assert!(page.delete(b"c"));
            page.compact();
            assert_eq!(page.cell_offset(0), usable - 10); // b is last now
            tail_intact(&page);

            // "Write to disk, read back": the reopened page knows its own size.
            let mut copy = buf;
            let reopened = SlottedPage::open(&mut copy);
            assert_eq!(reopened.usable_size(), usable);
            tail_intact(&reopened);
            assert_eq!(reopened.get(b"e"), Some(&b"1234"[..]));
        }
    }

    #[test]
    fn reserved_tail_without_it_the_first_cell_occupies_the_last_bytes_of_the_buffer() {
        // Why a page that will carry a checksum in its last 4 bytes must be
        // formatted with init_reserved(buf, 4): after plain init, storing
        // those 4 bytes destroys the end of the first cell.
        let mut buf = [0u8; PAGE_SIZE];
        SlottedPage::init(&mut buf)
            .put(b"mango", b"yellow")
            .unwrap();
        buf[PAGE_SIZE - 4..].fill(0xCC); // what sealing the page would do
        assert_ne!(
            SlottedPage::open(&mut buf).get(b"mango"),
            Some(&b"yellow"[..])
        );

        SlottedPage::init_reserved(&mut buf, 4)
            .put(b"mango", b"yellow")
            .unwrap();
        buf[PAGE_SIZE - 4..].fill(0xCC);
        let page = SlottedPage::open(&mut buf);
        assert_eq!(page.get(b"mango"), Some(&b"yellow"[..]));
        page.validate().unwrap();
    }

    #[test]
    fn validate_nothing_may_reach_into_the_reserved_tail_and_a_looping_free_list_is_caught() {
        let mut good = [0u8; PAGE_SIZE];
        let a_off = {
            let mut page = SlottedPage::init_reserved(&mut good, 4);
            for k in ["a", "b", "c", "d"] {
                page.put(k.as_bytes(), b"12345").unwrap();
            }
            assert!(page.delete(b"b")); // free block at 4072, size 10
            page.validate().unwrap();
            page.cell_offset(0) // 4082: a's cell ends at 4092
        };
        let corrupt = |damage: &dyn Fn(&mut SlottedPage)| {
            let mut buf = good;
            let mut page = SlottedPage::open(&mut buf);
            damage(&mut page);
            page.validate()
        };

        // the last cell claims one byte of the tail
        let r = corrupt(&|p| p.wr16(a_off + 2, 6));
        assert_eq!(r, Err(ValidateError::SlotOutOfRange));
        // a free block that runs into the tail (it also covers a's cell,
        // which the bound check must report first)
        let r = corrupt(&|p| p.wr16(4072 + 2, 21));
        assert_eq!(r, Err(ValidateError::FreeListCorrupt));
        // content_start inside the tail
        let r = corrupt(&|p| p.wr16(OFF_CONTENT_START, PAGE_SIZE - 2));
        assert_eq!(r, Err(ValidateError::BadHeader));
        // a reserved byte that changed on disk moves the end of the content area
        let r = corrupt(&|p| p.buf[OFF_RESERVED] = 8);
        assert_eq!(r, Err(ValidateError::SlotOutOfRange));
        // A free block whose `next` points back at itself: `stats` would
        // never return on this page; validate must (the list has to ascend).
        let r = corrupt(&|p| p.wr16(4072, 4072));
        assert_eq!(r, Err(ValidateError::FreeListCorrupt));
        assert_eq!(corrupt(&|_| {}), Ok(()));
    }
}

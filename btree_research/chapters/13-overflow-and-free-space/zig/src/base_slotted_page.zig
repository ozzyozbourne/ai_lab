// Copied from chapters/12-disk-backed-bplus-tree/zig/src/base_slotted_page.zig (chapter 13 uses it unchanged), which has it from:
// Copied from chapters/10-slotted-pages/zig/src/slotted_page.zig; unchanged.
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
//!   offset 0                                               usable     4096
//!   +--------+---------------+--------------+----------------+----------+
//!   | header | slot array -> | gap (unused) | <- cell content| reserved |
//!   +--------+---------------+--------------+----------------+----------+
//!   0        16              16 + 2*cell_count   content_start
//!
//!   usable = 4096 - reserved. `reserved` is 0 unless the page was formatted
//!   with `initReserved`; then the last `reserved` bytes of the buffer belong
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
//!
//! Free space therefore has three forms, and `freeBytes` is their sum:
//!   1. the gap between the slot array and `content_start`,
//!   2. the free blocks (holes left by deleted cells),
//!   3. `frag_bytes` (slivers too small to hold a free block header).
//! Only the gap can hold a new slot, and only the gap or one single free
//! block can hold a new cell. When the bytes exist but not in one piece,
//! `compact` slides all cells to the end of the page and turns everything
//! free into gap.
//!
//! The page never hands out pointers that stay valid: `key(i)` / `value(i)`
//! return slices into the buffer that any later mutation may move.
const std = @import("std");
const assert = std.debug.assert;

pub const page_size = 4096;

// --- header field offsets -------------------------------------------------
const off_cell_count = 0;
const off_content_start = 2;
const off_first_free = 4;
const off_frag_bytes = 6;
const off_kind = 7;
const off_reserved = 8;
pub const off_user_area = 9;
pub const user_area_size = 7;
pub const header_size = 16;

/// One slot: the u16 offset of a cell.
pub const slot_size = 2;
/// Cell header: key_len u16 + value_len u16.
pub const cell_header_size = 4;
/// Free block header: next u16 + size u16. Because a cell is never smaller
/// than its 4-byte header, every freed cell can hold a free block header.
pub const free_block_header_size = 4;
/// Upper bound for `frag_bytes`. Above it the allocator refuses to create
/// more slivers and uses the gap (or compacts) instead. Same bound as SQLite's
/// limit of 60 fragmented bytes; the test is slightly different (SQLite will
/// not use up a block once the page has more than 57, we compare the sum).
pub const max_frag_bytes = 60;
/// The largest cell that fits in an empty page without a reserved tail
/// (header + one slot + cell). An upper bound for every page; the exact
/// limit of one page is `maxCellSize()`.
pub const max_cell_size = page_size - header_size - slot_size;

pub const Error = error{
    /// Not enough free bytes on this page. The page is unchanged.
    /// The caller (a B-tree) reacts by splitting the page.
    PageFull,
    /// The cell could not fit even in an empty page. The page is unchanged.
    CellTooLarge,
};

pub const ValidateError = error{
    BadHeader,
    SlotOutOfRange,
    CellOverlap,
    FreeListCorrupt,
    FragmentMismatch,
    KeysOutOfOrder,
};

/// Result of `search`: `index` is the slot of the key if `found`, otherwise
/// the slot where the key would have to be inserted (lower bound).
pub const SearchResult = struct { found: bool, index: usize };

/// A summary of where the bytes of the page are. `free_bytes` is always
/// `gap + free_block_bytes + frag_bytes`.
pub const Stats = struct {
    cell_count: usize,
    content_start: usize,
    gap: usize,
    free_block_count: usize,
    free_block_bytes: usize,
    largest_free_block: usize,
    frag_bytes: usize,
    free_bytes: usize,
};

pub const FreeBlock = struct { offset: usize, size: usize };

/// Total bytes a cell with this key and value occupies in the content area.
pub fn cellSize(key_len: usize, value_len: usize) usize {
    return cell_header_size + key_len + value_len;
}

pub const SlottedPage = struct {
    buf: *[page_size]u8,

    // ---- construction -----------------------------------------------------

    /// Format `buf` as an empty page (zeroes all 4096 bytes) and wrap it.
    pub fn init(buf: *[page_size]u8) SlottedPage {
        return initReserved(buf, 0);
    }

    /// Like `init`, but the last `reserved_bytes` bytes of the buffer are
    /// left to the caller: the content area ends at `4096 - reserved_bytes`.
    /// The buffer is zeroed once, here; afterwards no method reads or writes
    /// the reserved tail. The number is stored in the header, so `open`
    /// needs no argument.
    pub fn initReserved(buf: *[page_size]u8, reserved_bytes: u8) SlottedPage {
        @memset(buf, 0);
        const page: SlottedPage = .{ .buf = buf };
        buf[off_reserved] = reserved_bytes;
        page.wr16(off_content_start, page.usableSize());
        return page;
    }

    /// Wrap a buffer that already holds a formatted page (for example one
    /// read from disk). Nothing is checked, and the other methods trust the
    /// page: on a damaged one they can index out of bounds or follow a free
    /// list that never ends. A page that comes from disk must pass a
    /// checksum or `validate` (which is safe on any bytes) before it is used.
    pub fn open(buf: *[page_size]u8) SlottedPage {
        return .{ .buf = buf };
    }

    // ---- the reserved tail ------------------------------------------------

    /// Size of the reserved tail in bytes (0 for a page made by `init`).
    pub fn reservedSize(self: SlottedPage) usize {
        return self.buf[off_reserved];
    }

    /// Where the content area ends: `page_size - reservedSize()`.
    pub fn usableSize(self: SlottedPage) usize {
        return page_size - self.reservedSize();
    }

    /// The reserved tail itself, `buf[usableSize()..]`: the caller's bytes.
    pub fn reservedArea(self: SlottedPage) []u8 {
        return self.buf[self.usableSize()..];
    }

    /// The largest cell that fits in this page when it is empty.
    pub fn maxCellSize(self: SlottedPage) usize {
        return self.usableSize() - header_size - slot_size;
    }

    // ---- reading ------------------------------------------------------------

    pub fn count(self: SlottedPage) usize {
        return self.rd16(off_cell_count);
    }

    /// Key of the cell in slot `index`. The slice points into the page and is
    /// invalidated by the next `put`, `insertAt`, `delete`, `deleteAt` or
    /// `compact`.
    pub fn key(self: SlottedPage, index: usize) []const u8 {
        const off = self.slot(index);
        return self.buf[off + cell_header_size ..][0..self.rd16(off)];
    }

    /// Value of the cell in slot `index`. Same lifetime rule as `key`.
    pub fn value(self: SlottedPage, index: usize) []const u8 {
        const off = self.slot(index);
        const key_len = self.rd16(off);
        return self.buf[off + cell_header_size + key_len ..][0..self.rd16(off + 2)];
    }

    /// Binary search over the slot array (lower bound). Each probe follows
    /// one slot to its cell; keys compare as byte strings (memcmp order, a
    /// prefix sorts before a longer key).
    pub fn search(self: SlottedPage, wanted: []const u8) SearchResult {
        var lo: usize = 0;
        var hi: usize = self.count();
        // Invariant: every key before `lo` is < wanted, every key at or
        // after `hi` is >= wanted.
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.key(mid), wanted) == .lt) lo = mid + 1 else hi = mid;
        }
        const found = lo < self.count() and std.mem.eql(u8, self.key(lo), wanted);
        return .{ .found = found, .index = lo };
    }

    /// Value stored under `wanted`, or null. Same lifetime rule as `key`.
    pub fn get(self: SlottedPage, wanted: []const u8) ?[]const u8 {
        const r = self.search(wanted);
        return if (r.found) self.value(r.index) else null;
    }

    // ---- writing ------------------------------------------------------------

    /// Insert or overwrite. On error the page is unchanged.
    /// `k` and `v` must not point into this page (cells may move).
    pub fn put(self: SlottedPage, k: []const u8, v: []const u8) Error!void {
        const r = self.search(k);
        if (!r.found) return self.insertAt(r.index, k, v);

        const old_size = self.cellSizeAt(self.slot(r.index));
        const new_size = cellSize(k.len, v.len);
        if (new_size == old_size) {
            // Same size: overwrite the value bytes where they are.
            self.assertOutside(v);
            const off = self.slot(r.index);
            @memcpy(self.buf[off + cell_header_size + k.len ..][0..v.len], v);
            return;
        }
        // Different size: the old cell and its slot are given back first, so
        // the new cell needs `new_size` bytes out of `free + old_size`.
        if (new_size > self.maxCellSize()) return error.CellTooLarge;
        if (new_size > self.freeBytes() + old_size) return error.PageFull;
        self.deleteAt(r.index);
        self.insertAt(r.index, k, v) catch unreachable; // checked just above
    }

    /// Remove `wanted`. Returns false if it was not on the page.
    pub fn delete(self: SlottedPage, wanted: []const u8) bool {
        const r = self.search(wanted);
        if (r.found) self.deleteAt(r.index);
        return r.found;
    }

    /// Insert a cell so that it becomes slot `index` (0 <= index <= count).
    /// The caller is responsible for key order: the key must sort after slot
    /// `index - 1` and before the cell currently in slot `index`. `put` does
    /// the search for you; a B-tree split uses `insertAt` to append cells it
    /// already has in order. On error the page is unchanged.
    pub fn insertAt(self: SlottedPage, index: usize, k: []const u8, v: []const u8) Error!void {
        const n = self.count();
        assert(index <= n);
        assert(index == 0 or std.mem.order(u8, self.key(index - 1), k) == .lt);
        assert(index == n or std.mem.order(u8, k, self.key(index)) == .lt);
        self.assertOutside(k);
        self.assertOutside(v);

        const size = cellSize(k.len, v.len);
        if (size > self.maxCellSize()) return error.CellTooLarge;
        if (size + slot_size > self.freeBytes()) return error.PageFull;

        // 1. Find room for the cell body. May compact, which moves cells but
        //    never changes which slot refers to which cell.
        const off = self.allocSpace(size);
        self.wr16(off, k.len);
        self.wr16(off + 2, v.len);
        @memcpy(self.buf[off + cell_header_size ..][0..k.len], k);
        @memcpy(self.buf[off + cell_header_size + k.len ..][0..v.len], v);

        // 2. Open a hole in the slot array: slots index..n move up by one
        //    slot. This is the whole cost of keeping the page sorted: 2 bytes
        //    per following cell, no cell body moves.
        const at = header_size + index * slot_size;
        const end = header_size + n * slot_size;
        @memmove(self.buf[at + slot_size .. end + slot_size], self.buf[at..end]);
        self.wr16(at, off);
        self.wr16(off_cell_count, n + 1);
    }

    /// Remove the cell in slot `index`; later slots move down by one.
    pub fn deleteAt(self: SlottedPage, index: usize) void {
        const n = self.count();
        assert(index < n);
        const off = self.slot(index);
        const size = self.cellSizeAt(off);

        // Close the hole in the slot array.
        const at = header_size + index * slot_size;
        const end = header_size + n * slot_size;
        @memmove(self.buf[at .. end - slot_size], self.buf[at + slot_size .. end]);
        @memset(self.buf[end - slot_size .. end], 0);
        self.wr16(off_cell_count, n - 1);

        if (n == 1) {
            // Last cell gone: everything is gap again. This also recovers
            // slivers that no neighbouring free block could absorb.
            // The cell's bytes are not erased (see `compact`).
            self.wr16(off_content_start, self.usableSize());
            self.wr16(off_first_free, 0);
            self.buf[off_frag_bytes] = 0;
        } else {
            self.freeSpace(off, size);
        }
    }

    /// Slide every cell to the end of the page (slot 0 ends up last) so that
    /// all free bytes form one gap. Slot indexes do not change; cell offsets
    /// do. Called automatically by `insertAt` when the bytes exist but not
    /// in one piece.
    pub fn compact(self: SlottedPage) void {
        // Cells would overwrite each other if moved in place in slot order,
        // so read them from a copy of the content area. 4 KiB of stack.
        var scratch: [page_size]u8 = undefined;
        const old_start = self.rd16(off_content_start);
        const usable = self.usableSize();
        @memcpy(scratch[old_start..usable], self.buf[old_start..usable]);

        var top: usize = usable;
        for (0..self.count()) |i| {
            const off = self.slot(i);
            // Lengths come from the copy: the live cell header at `off` may
            // already have been overwritten by a cell moved earlier.
            const key_len = std.mem.readInt(u16, scratch[off..][0..2], .little);
            const value_len = std.mem.readInt(u16, scratch[off + 2 ..][0..2], .little);
            const size = cellSize(key_len, value_len);
            top -= size;
            @memcpy(self.buf[top..][0..size], scratch[off..][0..size]);
            self.wr16(header_size + i * slot_size, top);
        }
        // Zero the new gap. This keeps dumps readable; it is not an erase
        // guarantee. `deleteAt` leaves the bytes of a deleted cell where they
        // are (a free block overwrites only its first 4), and they stay on
        // the page until a compaction or a new cell happens to cover them.
        @memset(self.buf[header_size + self.count() * slot_size .. top], 0);
        self.wr16(off_content_start, top);
        self.wr16(off_first_free, 0);
        self.buf[off_frag_bytes] = 0;
    }

    // ---- free-space accounting ----------------------------------------------

    /// Total free bytes: gap + free blocks + fragments. A cell of `size`
    /// bytes can be inserted if and only if `size + slot_size <= freeBytes()`.
    pub fn freeBytes(self: SlottedPage) usize {
        return self.stats().free_bytes;
    }

    /// True if `put`/`insertAt` of a new key with these lengths would succeed.
    pub fn fits(self: SlottedPage, key_len: usize, value_len: usize) bool {
        return cellSize(key_len, value_len) + slot_size <= self.freeBytes();
    }

    pub fn stats(self: SlottedPage) Stats {
        const n = self.count();
        const content_start = self.rd16(off_content_start);
        var s: Stats = .{
            .cell_count = n,
            .content_start = content_start,
            .gap = content_start - (header_size + n * slot_size),
            .free_block_count = 0,
            .free_block_bytes = 0,
            .largest_free_block = 0,
            .frag_bytes = self.buf[off_frag_bytes],
            .free_bytes = 0,
        };
        var block = self.rd16(off_first_free);
        while (block != 0) : (block = self.rd16(block)) {
            const size = self.rd16(block + 2);
            s.free_block_count += 1;
            s.free_block_bytes += size;
            s.largest_free_block = @max(s.largest_free_block, size);
        }
        s.free_bytes = s.gap + s.free_block_bytes + s.frag_bytes;
        return s;
    }

    /// The offset of the cell in slot `index` (for dumps and visualizations).
    pub fn cellOffset(self: SlottedPage, index: usize) usize {
        return self.slot(index);
    }

    /// Copy the free list into `out` (ascending offsets); returns the filled
    /// prefix. For dumps and tests; pass a buffer of at least
    /// `stats().free_block_count` entries.
    pub fn freeBlocks(self: SlottedPage, out: []FreeBlock) []FreeBlock {
        var n: usize = 0;
        var block = self.rd16(off_first_free);
        while (block != 0 and n < out.len) : (block = self.rd16(block)) {
            out[n] = .{ .offset = block, .size = self.rd16(block + 2) };
            n += 1;
        }
        return out[0..n];
    }

    // ---- caller-owned header bytes ------------------------------------------

    pub fn kind(self: SlottedPage) u8 {
        return self.buf[off_kind];
    }

    pub fn setKind(self: SlottedPage, k: u8) void {
        self.buf[off_kind] = k;
    }

    /// Seven header bytes this file never interprets. A caller that needs
    /// more per-page state asks for a reserved tail (`initReserved`).
    pub fn userArea(self: SlottedPage) *[user_area_size]u8 {
        return self.buf[off_user_area..][0..user_area_size];
    }

    // ---- the allocator inside the page --------------------------------------
    //
    // `allocSpace` and `freeSpace` are a tiny heap allocator whose heap is the
    // content area. They deal in *offsets*, never pointers, and an offset is
    // only meaningful until the next compaction. That is why this allocator
    // cannot be exposed as a `std.mem.Allocator` (see the README).

    /// Reserve `size` bytes in the content area and return their offset.
    /// Precondition (checked by `insertAt`): size + slot_size <= freeBytes().
    /// Postcondition: the gap can still take one more slot.
    fn allocSpace(self: SlottedPage, size: usize) usize {
        assert(size >= free_block_header_size);
        const slots_end = header_size + self.count() * slot_size;
        var content_start = self.rd16(off_content_start);

        // 1. Reuse a hole, but only if the gap can still take the new slot.
        if (content_start - slots_end >= slot_size) {
            if (self.takeFromFreeBlock(size)) |off| return off;
        }
        // 2. Otherwise carve from the gap, compacting first if the gap alone
        //    is too small. After compaction gap == freeBytes(), so it fits.
        if (content_start - slots_end < size + slot_size) {
            self.compact();
            content_start = self.rd16(off_content_start);
        }
        content_start -= size;
        self.wr16(off_content_start, content_start);
        return content_start;
    }

    /// First fit over the free list. Returns null if no block is big enough.
    fn takeFromFreeBlock(self: SlottedPage, size: usize) ?usize {
        var prev: usize = 0; // 0 = the list head in the page header
        var block = self.rd16(off_first_free);
        while (block != 0) : ({
            prev = block;
            block = self.rd16(block);
        }) {
            const block_size = self.rd16(block + 2);
            if (block_size < size) continue;
            const rest = block_size - size;
            if (rest >= free_block_header_size) {
                // Take the tail. The block keeps its offset and its `next`
                // link; only its size shrinks, so no link has to be patched.
                self.wr16(block + 2, rest);
                return block + rest;
            }
            // The whole block is used. The 0 to 3 bytes left over cannot hold
            // a free block header: they become fragment bytes, tracked only
            // as a count. Refuse if that would pass the cap.
            const frag = self.buf[off_frag_bytes];
            if (frag + rest > max_frag_bytes) continue;
            self.buf[off_frag_bytes] = @intCast(frag + rest);
            self.wr16(if (prev == 0) off_first_free else prev, self.rd16(block));
            return block;
        }
        return null;
    }

    /// Give `size` bytes at `offset` back. Keeps the free list sorted by
    /// offset and merges the range with its neighbours.
    fn freeSpace(self: SlottedPage, offset: usize, size: usize) void {
        assert(size >= free_block_header_size);
        var start = offset;
        var end = offset + size;
        var frag: usize = self.buf[off_frag_bytes];
        const content_start = self.rd16(off_content_start);

        // Find the free blocks on both sides of the range.
        var prev: usize = 0;
        var next = self.rd16(off_first_free);
        while (next != 0 and next < start) {
            prev = next;
            next = self.rd16(next);
        }

        // Up to 3 bytes between two free ranges cannot be a cell (a cell is at
        // least 4 bytes), so they must be a sliver counted in frag_bytes.
        // Merging swallows the sliver and takes it out of that count.
        const sliver_max = free_block_header_size - 1;
        if (next != 0 and end + sliver_max >= next) {
            frag -= next - end;
            end = next + self.rd16(next + 2);
            next = self.rd16(next);
        }
        if (prev != 0) {
            const prev_end = prev + self.rd16(prev + 2);
            if (prev_end + sliver_max >= start) {
                frag -= start - prev_end;
                start = prev;
                // `prev` is now the block being rewritten; find its own
                // predecessor so the link to it can be kept.
                prev = self.predecessorOf(start);
            }
        }
        if (start <= content_start + sliver_max) {
            // The range touches the low end of the content area: grow the gap
            // instead of creating a block. (prev is 0 here: a block below
            // `start` would lie inside the 3 bytes we just ruled out.)
            frag -= start - content_start;
            self.wr16(off_content_start, end);
            self.wr16(off_first_free, next);
        } else {
            self.wr16(start, next);
            self.wr16(start + 2, end - start);
            self.wr16(if (prev == 0) off_first_free else prev, start);
        }
        self.buf[off_frag_bytes] = @intCast(frag);
    }

    /// The free block whose `next` is `block`, or 0 if `block` is the head.
    fn predecessorOf(self: SlottedPage, block: usize) usize {
        var prev: usize = 0;
        var cur = self.rd16(off_first_free);
        while (cur != block) {
            prev = cur;
            cur = self.rd16(cur);
        }
        return prev;
    }

    // ---- validation -----------------------------------------------------------

    /// Check every invariant of the layout. Paints each byte of the content
    /// area as "cell" or "free block" in a 4 KiB map on the stack; whatever
    /// stays unpainted must be exactly `frag_bytes`.
    pub fn validate(self: SlottedPage) ValidateError!void {
        const n = self.count();
        const slots_end = header_size + n * slot_size;
        const content_start = self.rd16(off_content_start);
        // Nothing below may reach into the reserved tail: every upper bound
        // is `usable`, not `page_size`.
        const usable = self.usableSize();
        if (slots_end > content_start or content_start > usable) return error.BadHeader;

        var owner: [page_size]u8 = @splat(0); // 0 = unclaimed, 1 = cell, 2 = free block

        // Cells: inside the content area, not overlapping.
        for (0..n) |i| {
            const off = self.slot(i);
            if (off < content_start or off + cell_header_size > usable) return error.SlotOutOfRange;
            const end = off + self.cellSizeAt(off);
            if (end > usable) return error.SlotOutOfRange;
            for (owner[off..end]) |*o| {
                if (o.* != 0) return error.CellOverlap;
                o.* = 1;
            }
        }

        // Free list: ascending, each block >= 4 bytes, at least 4 bytes after
        // the end of the previous one (closer blocks must have been merged),
        // and at least 4 bytes above content_start (else it would be gap).
        var min_start: usize = content_start + free_block_header_size;
        var block = self.rd16(off_first_free);
        while (block != 0) {
            if (block < min_start or block + free_block_header_size > usable) return error.FreeListCorrupt;
            const size = self.rd16(block + 2);
            if (size < free_block_header_size or block + size > usable) return error.FreeListCorrupt;
            for (owner[block .. block + size]) |*o| {
                if (o.* != 0) return error.CellOverlap;
                o.* = 2;
            }
            min_start = block + size + free_block_header_size;
            block = self.rd16(block);
        }

        // Every content byte is a cell, a free block, or a counted fragment.
        var unclaimed: usize = 0;
        for (owner[content_start..usable]) |o| unclaimed += @intFromBool(o == 0);
        if (unclaimed != self.buf[off_frag_bytes]) return error.FragmentMismatch;
        if (unclaimed > max_frag_bytes) return error.FragmentMismatch;

        // Slot order is key order, without duplicates.
        for (1..@max(n, 1)) |i| {
            if (std.mem.order(u8, self.key(i - 1), self.key(i)) != .lt) return error.KeysOutOfOrder;
        }
    }

    // ---- small helpers --------------------------------------------------------

    fn rd16(self: SlottedPage, off: usize) usize {
        return std.mem.readInt(u16, self.buf[off..][0..2], .little);
    }

    fn wr16(self: SlottedPage, off: usize, v: usize) void {
        std.mem.writeInt(u16, self.buf[off..][0..2], @intCast(v), .little);
    }

    fn slot(self: SlottedPage, index: usize) usize {
        assert(index < self.count());
        return self.rd16(header_size + index * slot_size);
    }

    fn cellSizeAt(self: SlottedPage, off: usize) usize {
        return cellSize(self.rd16(off), self.rd16(off + 2));
    }

    /// Arguments of put/insertAt must not be slices of this very page: the
    /// insert may compact the page and move the bytes they point at.
    fn assertOutside(self: SlottedPage, bytes: []const u8) void {
        const lo = @intFromPtr(self.buf);
        const p = @intFromPtr(bytes.ptr);
        assert(bytes.len == 0 or p + bytes.len <= lo or p >= lo + page_size);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn expectCell(page: SlottedPage, index: usize, k: []const u8, v: []const u8) !void {
    try testing.expectEqualStrings(k, page.key(index));
    try testing.expectEqualStrings(v, page.value(index));
}

test "layout constants" {
    try testing.expectEqual(16, header_size);
    try testing.expectEqual(4078, max_cell_size);
    try testing.expectEqual(header_size, off_user_area + user_area_size);
    try testing.expectEqual(15, cellSize("mango".len, "yellow".len));
}

test "empty page" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    try page.validate();
    try testing.expectEqual(0, page.count());
    try testing.expectEqual(page_size - header_size, page.freeBytes());
    try testing.expectEqual(null, page.get("x"));
    try testing.expect(!page.delete("x"));
    try testing.expectEqual(SearchResult{ .found = false, .index = 0 }, page.search("x"));
}

test "put keeps slots sorted while cells stay where they were written" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    try page.put("mango", "yellow");
    try page.put("apple", "red");
    try page.put("kiwi", "green");
    try page.validate();

    try expectCell(page, 0, "apple", "red");
    try expectCell(page, 1, "kiwi", "green");
    try expectCell(page, 2, "mango", "yellow");
    // Physical order is insertion order, growing down from the page end.
    try testing.expectEqual(4081, page.cellOffset(2)); // mango, first written
    try testing.expectEqual(4069, page.cellOffset(0)); // apple
    try testing.expectEqual(4056, page.cellOffset(1)); // kiwi
    try testing.expectEqual(4056, page.stats().content_start);

    try testing.expectEqualStrings("green", page.get("kiwi").?);
    try testing.expectEqual(null, page.get("kiwj"));
    try testing.expectEqual(SearchResult{ .found = true, .index = 1 }, page.search("kiwi"));
    try testing.expectEqual(SearchResult{ .found = false, .index = 1 }, page.search("banana"));
    try testing.expectEqual(SearchResult{ .found = false, .index = 3 }, page.search("zebra"));
}

test "keys compare as byte strings; empty key and empty value are legal" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    try page.put("ab", "2");
    try page.put("a", "1");
    try page.put("", "");
    try page.put("abc", "");
    try page.put(&.{ 0xff, 0x00 }, "high");
    try page.validate();
    try expectCell(page, 0, "", "");
    try expectCell(page, 1, "a", "1");
    try expectCell(page, 2, "ab", "2");
    try expectCell(page, 3, "abc", "");
    try testing.expectEqualStrings("high", page.value(4));
    try testing.expectEqualStrings("", page.get("").?);
}

test "put overwrites: same size in place, different size relocates" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    try page.put("a", "111");
    try page.put("b", "222");
    const before = page.cellOffset(0);

    try page.put("a", "999"); // same size
    try testing.expectEqual(before, page.cellOffset(0));
    try testing.expectEqualStrings("999", page.get("a").?);

    try page.put("a", "a longer value"); // grows
    try page.put("b", ""); // shrinks
    try page.validate();
    try testing.expectEqual(2, page.count());
    try testing.expectEqualStrings("a longer value", page.get("a").?);
    try testing.expectEqualStrings("", page.get("b").?);
}

test "delete: free block, coalescing, tail reuse, fragment, gap growth" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    var blocks: [4]FreeBlock = undefined;
    try page.put("mango", "yellow"); // 15 bytes at 4081
    try page.put("apple", "red"); // 12 bytes at 4069
    try page.put("kiwi", "green"); // 13 bytes at 4056
    try page.put("cherry", "dark red"); // 18 bytes at 4038
    try page.put("fig", "purple"); // 13 bytes at 4025

    // A cell in the middle of the content area becomes a free block.
    try testing.expect(page.delete("kiwi"));
    try testing.expectEqualSlices(FreeBlock, &.{.{ .offset = 4056, .size = 13 }}, page.freeBlocks(&blocks));
    // Its physical neighbour is freed: the two holes merge into one.
    try testing.expect(page.delete("apple"));
    try testing.expectEqualSlices(FreeBlock, &.{.{ .offset = 4056, .size = 25 }}, page.freeBlocks(&blocks));
    try page.validate();

    // A 16-byte cell takes the tail of the 25-byte block; 9 bytes remain.
    try page.put("banana", "yellow");
    try testing.expectEqual(4065, page.cellOffset(0));
    try testing.expectEqualSlices(FreeBlock, &.{.{ .offset = 4056, .size = 9 }}, page.freeBlocks(&blocks));

    // An 8-byte cell uses the block up; the 1 byte left over is a fragment.
    try page.put("pea", "g");
    try testing.expectEqual(4056, page.cellOffset(4));
    try testing.expectEqual(0, page.stats().free_block_count);
    try testing.expectEqual(1, page.stats().frag_bytes);
    try page.validate();

    // The lowest cell is freed: the gap grows, no free block is created.
    try testing.expect(page.delete("fig"));
    try testing.expectEqual(4038, page.stats().content_start);
    try testing.expectEqual(0, page.stats().free_block_count);

    // The cell at the very end of the page becomes a block again.
    try testing.expect(page.delete("mango"));
    try testing.expectEqualSlices(FreeBlock, &.{.{ .offset = 4081, .size = 15 }}, page.freeBlocks(&blocks));
    try page.validate();

    const free_before = page.freeBytes();
    page.compact();
    try page.validate();
    const s = page.stats();
    try testing.expectEqual(free_before, s.free_bytes);
    try testing.expectEqual(s.free_bytes, s.gap); // everything free is gap now
    try testing.expectEqual(0, s.frag_bytes);
    try testing.expectEqual(4054, s.content_start);
    try expectCell(page, 0, "banana", "yellow");
    try expectCell(page, 1, "cherry", "dark red");
    try expectCell(page, 2, "pea", "g");
    try testing.expectEqual(4080, page.cellOffset(0)); // slot 0 is now last on the page
}

test "freeing between two free blocks merges all three and absorbs a sliver" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    var blocks: [4]FreeBlock = undefined;
    // Five 10-byte cells: a@4086 b@4076 c@4066 d@4056 e@4046.
    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |k| try page.put(k, "12345");
    try testing.expect(page.delete("b"));
    // A 9-byte cell fills b's 10-byte hole at 4076 and leaves a sliver at 4085.
    try page.put("f", "1234");
    try testing.expectEqual(4076, page.cellOffset(4));
    try testing.expectEqual(1, page.stats().frag_bytes);
    // Free a (above the sliver) and c (below f): two separate blocks.
    try testing.expect(page.delete("a"));
    try testing.expect(page.delete("c"));
    try testing.expectEqualSlices(FreeBlock, &.{
        .{ .offset = 4066, .size = 10 },
        .{ .offset = 4086, .size = 10 },
    }, page.freeBlocks(&blocks));
    // Free f: it touches c's block below and is 1 byte short of a's block
    // above. All of it, sliver included, becomes one block.
    try testing.expect(page.delete("f"));
    try testing.expectEqualSlices(FreeBlock, &.{.{ .offset = 4066, .size = 30 }}, page.freeBlocks(&blocks));
    try testing.expectEqual(0, page.stats().frag_bytes);
    try page.validate();
    // Deleting the last cells returns the page to its pristine accounting.
    try testing.expect(page.delete("d"));
    try testing.expect(page.delete("e"));
    try testing.expectEqual(page_size - header_size, page.stats().gap);
    try page.validate();
}

test "PageFull and CellTooLarge leave the page byte-for-byte unchanged" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    const big: [max_cell_size]u8 = @splat('v');

    // Exactly the largest cell fits an empty page; one byte more never does.
    try testing.expectError(error.CellTooLarge, page.put("k", big[0 .. max_cell_size - cell_header_size]));
    try page.put("k", big[0 .. max_cell_size - cell_header_size - 1]);
    try testing.expectEqual(0, page.freeBytes());
    try page.validate();

    var snapshot: [page_size]u8 = buf;
    try testing.expectError(error.PageFull, page.put("l", ""));
    try testing.expectError(error.PageFull, page.insertAt(1, "l", ""));
    try testing.expectError(error.CellTooLarge, page.put("k", &big)); // replace path
    try testing.expectEqualSlices(u8, &snapshot, &buf);
    try testing.expect(!page.fits(1, 0));

    // Replacing with something smaller works on a full page...
    try page.put("k", "small");
    try page.validate();
    // ...and replacing with something that cannot fit fails without losing the old value.
    try page.put("j", big[0..4000]);
    snapshot = buf;
    try testing.expectError(error.PageFull, page.put("k", big[0..200]));
    try testing.expectEqualSlices(u8, &snapshot, &buf);
    try testing.expectEqualStrings("small", page.get("k").?);
}

test "insert compacts by itself when free bytes exist but not in one piece" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    const filler: [96]u8 = @splat('.');
    var name: [4]u8 = undefined;

    // Fill the page with 104-byte cells, then delete every other one.
    var n: usize = 0;
    while (page.fits(4, filler.len)) : (n += 1) {
        try page.put(std.fmt.bufPrint(&name, "k{d:0>3}", .{n}) catch unreachable, &filler);
    }
    try testing.expectEqual(38, n);
    var i: usize = 0;
    while (i < n) : (i += 2) {
        try testing.expect(page.delete(std.fmt.bufPrint(&name, "k{d:0>3}", .{i}) catch unreachable));
    }
    try page.validate();
    const before = page.stats();
    try testing.expectEqual(19, before.free_block_count);
    try testing.expectEqual(104, before.largest_free_block);
    const need = cellSize("big".len, 500) + slot_size; // 509
    try testing.expect(before.gap < need and before.free_bytes >= need);

    // No hole and no gap is big enough, but the page as a whole is.
    const big: [500]u8 = @splat('B');
    try page.put("big", &big);
    try page.validate();
    const after = page.stats();
    try testing.expectEqual(0, after.free_block_count);
    try testing.expectEqual(before.free_bytes - need, after.free_bytes);
    try testing.expectEqual(20, page.count());
    try testing.expectEqualStrings(&big, page.get("big").?);
    try testing.expectEqualStrings(&filler, page.get("k001").?);
}

test "a hole that fits the cell is not enough: the new slot needs gap too" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    const a: [15]u8 = @splat('a');
    const c: [max_cell_size]u8 = @splat('c');
    try page.put("a", &a); // 20-byte cell
    try page.put("b", &a); // 20-byte cell
    try page.put("c", c[0 .. page.freeBytes() - slot_size - cell_header_size - 1]); // exactly full
    try testing.expectEqual(0, page.stats().gap);

    try testing.expect(page.delete("b")); // 20-byte hole; the freed slot is the only gap
    try page.put("d", "12345"); // 10-byte cell from the tail of the hole; its slot uses the gap
    try testing.expectEqual(0, page.stats().gap);
    try testing.expectEqual(10, page.stats().largest_free_block);

    // An 8-byte cell fits the 10-byte hole, but there is no gap for slot 3.
    // The insert must compact (the hole becomes gap) instead of failing.
    try page.put("e", "123");
    try page.validate();
    try testing.expectEqual(0, page.freeBytes());
    try testing.expectEqualStrings("123", page.get("e").?);
    try testing.expectEqualStrings(&a, page.get("a").?);
}

test "a slice into the page does not survive compaction (why offsets, not pointers)" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    try page.put("a", "first");
    try page.put("b", "second");
    const stale = page.value(1); // points at "second"
    const stale_addr = @intFromPtr(stale.ptr);
    try testing.expect(page.delete("a"));
    page.compact();
    // The cell moved; the slot (the stable name) still finds it.
    try testing.expect(@intFromPtr(page.value(0).ptr) != stale_addr);
    try testing.expectEqualStrings("second", page.get("b").?);
}

test "kind and user area belong to the caller and survive every operation" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    page.setKind(7);
    std.mem.writeInt(u56, page.userArea(), 0x11223344556677, .little);
    try page.put("a", "1");
    try page.put("b", "2");
    try testing.expect(page.delete("a"));
    page.compact();
    try page.validate();
    try testing.expectEqual(7, page.kind());
    try testing.expectEqual(0x11223344556677, std.mem.readInt(u56, page.userArea(), .little));
    try testing.expectEqual(0, page.reservedSize()); // the user area is next to it
}

test "open sees what init + put wrote (the page is its own serialization)" {
    var buf: [page_size]u8 = undefined;
    {
        const page = SlottedPage.init(&buf);
        try page.put("k1", "v1");
        try page.put("k0", "v0");
    }
    var copy: [page_size]u8 = buf; // "write to disk, read back"
    const page = SlottedPage.open(&copy);
    try page.validate();
    try expectCell(page, 0, "k0", "v0");
    try expectCell(page, 1, "k1", "v1");
}

test "validate detects each kind of corruption" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.init(&buf);
    for ([_][]const u8{ "a", "b", "c", "d" }) |k| try page.put(k, "12345");
    try testing.expect(page.delete("b")); // free block at 4076, size 10
    try page.validate();
    const good: [page_size]u8 = buf;

    // content_start below the slot array
    page.wr16(off_content_start, 10);
    try testing.expectError(error.BadHeader, page.validate());
    buf = good;
    // a slot pointing into the gap
    page.wr16(header_size, 100);
    try testing.expectError(error.SlotOutOfRange, page.validate());
    buf = good;
    // two slots pointing at the same cell
    page.wr16(header_size, page.rd16(header_size + slot_size));
    try testing.expectError(error.CellOverlap, page.validate());
    buf = good;
    // a free block that claims bytes of a live cell
    page.wr16(4076 + 2, 14);
    try testing.expectError(error.CellOverlap, page.validate());
    buf = good;
    // a free block smaller than its own header
    page.wr16(4076 + 2, 3);
    try testing.expectError(error.FreeListCorrupt, page.validate());
    buf = good;
    // a hole that nobody accounts for
    page.wr16(off_first_free, 0);
    try testing.expectError(error.FragmentMismatch, page.validate());
    buf = good;
    // slots out of key order
    const s0 = page.rd16(header_size);
    page.wr16(header_size, page.rd16(header_size + slot_size));
    page.wr16(header_size + slot_size, s0);
    try testing.expectError(error.KeysOutOfOrder, page.validate());
    buf = good;
    try page.validate();
}

test "delete does not erase: an emptied page has init's header, not init's bytes" {
    var fresh: [page_size]u8 = undefined;
    var buf: [page_size]u8 = undefined;
    _ = SlottedPage.init(&fresh);
    const page = SlottedPage.init(&buf);
    try page.put("secret-key", "secret-value");
    try testing.expect(page.delete("secret-key"));
    try page.validate();
    // Every header field is back to what `init` wrote...
    try testing.expectEqualSlices(u8, fresh[0..header_size], buf[0..header_size]);
    // ...but the cell's bytes are still on the page, in what is now gap.
    try testing.expect(!std.mem.eql(u8, &fresh, &buf));
    try testing.expectEqualStrings("secret-keysecret-value", buf[page_size - 22 ..]);
    // Two pages with the same records are therefore not always the same bytes.
}

test "reserved tail: the content area ends before it and no operation touches it" {
    for ([_]u8{ 4, 32, 255 }) |r| {
        var buf: [page_size]u8 = undefined;
        const page = SlottedPage.initReserved(&buf, r);
        const usable = page_size - @as(usize, r);
        // The caller owns the tail from now on; fill it with a pattern.
        try testing.expectEqual(@as(usize, r), page.reservedArea().len);
        @memset(page.reservedArea(), 0xA5);
        const Tail = struct {
            fn intact(p: SlottedPage) !void {
                try p.validate();
                for (p.reservedArea()) |b| try testing.expectEqual(0xA5, b);
            }
        };

        try testing.expectEqual(usable, page.usableSize());
        try testing.expectEqual(usable, page.stats().content_start);
        try testing.expectEqual(usable - header_size, page.freeBytes());
        try testing.expectEqual(usable - header_size - slot_size, page.maxCellSize());

        // The first cell ends exactly where the tail begins.
        try page.put("mango", "yellow");
        try testing.expectEqual(usable - 15, page.cellOffset(0));
        try Tail.intact(page);
        // Deleting the last cell resets content_start to `usable`, not 4096.
        try testing.expect(page.delete("mango"));
        try testing.expectEqual(usable, page.stats().content_start);
        try Tail.intact(page);

        // The largest cell is smaller by `r`; it fills the page to the byte.
        const big: [max_cell_size]u8 = @splat('v');
        const max_value = page.maxCellSize() - cell_header_size - 1;
        try testing.expectError(error.CellTooLarge, page.put("k", big[0 .. max_value + 1]));
        try page.put("k", big[0..max_value]);
        try testing.expectEqual(0, page.freeBytes());
        try testing.expectError(error.PageFull, page.put("l", ""));
        try testing.expectError(error.CellTooLarge, page.put("k", big[0 .. max_value + 1])); // replace path
        try Tail.intact(page);
        try testing.expect(page.delete("k"));

        // Free blocks, a fragment, merging and compaction next to the tail.
        for ([_][]const u8{ "a", "b", "c", "d" }) |k| try page.put(k, "12345");
        try testing.expectEqual(usable - 10, page.cellOffset(0));
        try testing.expect(page.delete("a")); // free block that ends at `usable`
        var blocks: [2]FreeBlock = undefined;
        try testing.expectEqualSlices(FreeBlock, &.{.{ .offset = usable - 10, .size = 10 }}, page.freeBlocks(&blocks));
        try Tail.intact(page);
        try page.put("e", "1234"); // 9 of the 10 bytes: 1 fragment byte
        try testing.expectEqual(1, page.stats().frag_bytes);
        try Tail.intact(page);
        try testing.expect(page.delete("c"));
        page.compact();
        try testing.expectEqual(usable - 10, page.cellOffset(0)); // b is last now
        try Tail.intact(page);

        // "Write to disk, read back": the reopened page knows its own size.
        var copy: [page_size]u8 = buf;
        const reopened = SlottedPage.open(&copy);
        try testing.expectEqual(usable, reopened.usableSize());
        try Tail.intact(reopened);
        try testing.expectEqualStrings("1234", reopened.get("e").?);
    }
}

test "reserved tail: without it the first cell occupies the last bytes of the buffer" {
    // Why a page that will carry a checksum in its last 4 bytes must be
    // formatted with initReserved(buf, 4): after plain init, storing those
    // 4 bytes destroys the end of the first cell.
    var buf: [page_size]u8 = undefined;
    const plain = SlottedPage.init(&buf);
    try plain.put("mango", "yellow");
    @memset(buf[page_size - 4 ..], 0xCC); // what sealing the page would do
    try testing.expect(!std.mem.eql(u8, "yellow", plain.get("mango").?));

    const page = SlottedPage.initReserved(&buf, 4);
    try page.put("mango", "yellow");
    @memset(buf[page_size - 4 ..], 0xCC);
    try testing.expectEqualStrings("yellow", page.get("mango").?);
    try page.validate();
}

test "validate: nothing may reach into the reserved tail, and a looping free list is caught" {
    var buf: [page_size]u8 = undefined;
    const page = SlottedPage.initReserved(&buf, 4);
    for ([_][]const u8{ "a", "b", "c", "d" }) |k| try page.put(k, "12345");
    try testing.expect(page.delete("b")); // free block at 4072, size 10
    try page.validate();
    const good: [page_size]u8 = buf;
    const a_off = page.cellOffset(0); // 4082: a's cell ends at 4092

    // the last cell claims one byte of the tail
    page.wr16(a_off + 2, 6);
    try testing.expectError(error.SlotOutOfRange, page.validate());
    buf = good;
    // a free block that runs into the tail (it also covers a's cell, which
    // the bound check must report first)
    page.wr16(4072 + 2, 21);
    try testing.expectError(error.FreeListCorrupt, page.validate());
    buf = good;
    // content_start inside the tail
    page.wr16(off_content_start, page_size - 2);
    try testing.expectError(error.BadHeader, page.validate());
    buf = good;
    // a reserved byte that changed on disk moves the end of the content area
    buf[off_reserved] = 8;
    try testing.expectError(error.SlotOutOfRange, page.validate());
    buf = good;
    // A free block whose `next` points back at itself: `stats` would never
    // return on this page; validate must (the list has to ascend).
    page.wr16(4072, 4072);
    try testing.expectError(error.FreeListCorrupt, page.validate());
    buf = good;
    try page.validate();
}

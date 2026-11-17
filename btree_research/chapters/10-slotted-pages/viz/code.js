/*
 * Chapter 10 — data for the visualization (classic script, no fetch under file://).
 * CHAPTER_CODE: functions copied verbatim from zig/src/slotted_page.zig and
 * rust/src/slotted_page.rs. CHAPTER_EXPECTED_OUTPUT: a copy of ../expected_output.txt,
 * which the JS model in model.js must reproduce (BTViz.selfTest in index.html).
 */
window.CHAPTER_CODE = {
  "search": {
    zig: `
    pub fn search(self: SlottedPage, wanted: []const u8) SearchResult {
        var lo: usize = 0;
        var hi: usize = self.count();
        // Invariant: every key before \`lo\` is < wanted, every key at or
        // after \`hi\` is >= wanted.
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.key(mid), wanted) == .lt) lo = mid + 1 else hi = mid;
        }
        const found = lo < self.count() and std.mem.eql(u8, self.key(lo), wanted);
        return .{ .found = found, .index = lo };
    }
`,
    rust: `
    pub fn search(&self, wanted: &[u8]) -> SearchResult {
        let mut lo = 0;
        let mut hi = self.count();
        // Invariant: every key before \`lo\` is < wanted, every key at or
        // after \`hi\` is >= wanted.
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
`,
  },
  "insert": {
    zig: `
    pub fn insertAt(self: SlottedPage, index: usize, k: []const u8, v: []const u8) Error!void {
        const n = self.count();
        assert(index <= n);
        assert(index == 0 or std.mem.order(u8, self.key(index - 1), k) == .lt);
        assert(index == n or std.mem.order(u8, k, self.key(index)) == .lt);
        self.assertOutside(k);
        self.assertOutside(v);

        const size = cellSize(k.len, v.len);
        if (size > max_cell_size) return error.CellTooLarge;
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
                // Take the tail. The block keeps its offset and its \`next\`
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
`,
    rust: `
    pub fn insert_at(&mut self, index: usize, k: &[u8], v: &[u8]) -> Result<(), PageError> {
        let n = self.count();
        assert!(index <= n);
        debug_assert!(index == 0 || self.key(index - 1) < k);
        debug_assert!(index == n || k < self.key(index));

        let size = cell_size(k.len(), v.len());
        if size > MAX_CELL_SIZE {
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

    fn take_from_free_block(&mut self, size: usize) -> Option<usize> {
        let mut prev = 0; // 0 = the list head in the page header
        let mut block = self.rd16(OFF_FIRST_FREE);
        while block != 0 {
            let block_size = self.rd16(block + 2);
            if block_size >= size {
                let rest = block_size - size;
                if rest >= FREE_BLOCK_HEADER_SIZE {
                    // Take the tail. The block keeps its offset and its \`next\`
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
`,
  },
  "delete": {
    zig: `
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
            self.wr16(off_content_start, page_size);
            self.wr16(off_first_free, 0);
            self.buf[off_frag_bytes] = 0;
        } else {
            self.freeSpace(off, size);
        }
    }

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
                // \`prev\` is now the block being rewritten; find its own
                // predecessor so the link to it can be kept.
                prev = self.predecessorOf(start);
            }
        }
        if (start <= content_start + sliver_max) {
            // The range touches the low end of the content area: grow the gap
            // instead of creating a block. (prev is 0 here: a block below
            // \`start\` would lie inside the 3 bytes we just ruled out.)
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
`,
    rust: `
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
            self.wr16(OFF_CONTENT_START, PAGE_SIZE);
            self.wr16(OFF_FIRST_FREE, 0);
            self.buf[OFF_FRAG_BYTES] = 0;
        } else {
            self.free_space(off, size);
        }
    }

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
                // \`prev\` is now the block being rewritten; find its own
                // predecessor so the link to it can be kept.
                prev = self.predecessor_of(start);
            }
        }
        if start <= content_start + SLIVER_MAX {
            // The range touches the low end of the content area: grow the gap
            // instead of creating a block. (prev is 0 here: a block below
            // \`start\` would lie inside the 3 bytes we just ruled out.)
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
`,
  },
  "compact": {
    zig: `
    pub fn compact(self: SlottedPage) void {
        // Cells would overwrite each other if moved in place in slot order,
        // so read them from a copy of the content area. 4 KiB of stack.
        var scratch: [page_size]u8 = undefined;
        const old_start = self.rd16(off_content_start);
        @memcpy(scratch[old_start..], self.buf[old_start..]);

        var top: usize = page_size;
        for (0..self.count()) |i| {
            const off = self.slot(i);
            // Lengths come from the copy: the live cell header at \`off\` may
            // already have been overwritten by a cell moved earlier.
            const key_len = std.mem.readInt(u16, scratch[off..][0..2], .little);
            const value_len = std.mem.readInt(u16, scratch[off + 2 ..][0..2], .little);
            const size = cellSize(key_len, value_len);
            top -= size;
            @memcpy(self.buf[top..][0..size], scratch[off..][0..size]);
            self.wr16(header_size + i * slot_size, top);
        }
        // Zero the new gap so that deleted data does not linger on disk.
        @memset(self.buf[header_size + self.count() * slot_size .. top], 0);
        self.wr16(off_content_start, top);
        self.wr16(off_first_free, 0);
        self.buf[off_frag_bytes] = 0;
    }
`,
    rust: `
    pub fn compact(&mut self) {
        // Cells would overwrite each other if moved in place in slot order,
        // so read them from a copy of the page. 4 KiB of stack.
        let scratch: [u8; PAGE_SIZE] = *self.buf;

        let mut top = PAGE_SIZE;
        for i in 0..self.count() {
            let off = self.slot(i);
            // Lengths come from the copy: the live cell header at \`off\` may
            // already have been overwritten by a cell moved earlier.
            let key_len = u16::from_le_bytes([scratch[off], scratch[off + 1]]) as usize;
            let value_len = u16::from_le_bytes([scratch[off + 2], scratch[off + 3]]) as usize;
            let size = cell_size(key_len, value_len);
            top -= size;
            self.buf[top..top + size].copy_from_slice(&scratch[off..off + size]);
            self.wr16(HEADER_SIZE + i * SLOT_SIZE, top);
        }
        // Zero the new gap so that deleted data does not linger on disk.
        let slots_end = HEADER_SIZE + self.count() * SLOT_SIZE;
        self.buf[slots_end..top].fill(0);
        self.wr16(OFF_CONTENT_START, top);
        self.wr16(OFF_FIRST_FREE, 0);
        self.buf[OFF_FRAG_BYTES] = 0;
    }
`,
  },
};

window.CHAPTER_EXPECTED_OUTPUT = `== Part 1: one page, step by step ==
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
`;

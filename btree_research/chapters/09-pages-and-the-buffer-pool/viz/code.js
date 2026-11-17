/* Chapter 09 code panel snippets (trimmed from zig/src/buffer_pool.zig and
 * rust/src/buffer_pool.rs). Inlined because fetch() does not work under file://. */
window.CHAPTER_CODE = {
  'buffer pool': {
    zig: `
pub fn fetchPage(self: *BufferPool, id: PageId) Error!PagePtr {
    if (id >= self.pager.pageCount()) return error.PageOutOfRange;
    if (self.page_table.get(id)) |f| {
        const frame = &self.frames[f];
        frame.pin_count += 1;
        frame.referenced = true;
        self.stats.hits += 1;
        return self.frameBytes(f);
    }
    self.stats.misses += 1;
    const f = try self.takeFrame();
    try self.pager.readPage(id, self.frameBytes(f));
    self.install(f, id); // pin = 1, referenced, clean
    return self.frameBytes(f);
}

fn takeFrame(self: *BufferPool) Error!u32 {
    const n: u32 = @intCast(self.frames.len);
    var steps: u32 = 0;
    while (steps < 2 * n) : (steps += 1) {
        const f = self.hand;
        const frame = &self.frames[f];
        if (frame.page_id != invalid_page_id) {
            if (frame.pin_count > 0) {
                self.advanceHand();
                continue;
            }
            if (frame.referenced) {
                frame.referenced = false;
                self.advanceHand();
                continue;
            }
            if (frame.dirty) {
                try self.pager.writePage(frame.page_id, self.frameBytes(f));
                self.stats.writebacks += 1;
            }
            _ = self.page_table.remove(frame.page_id);
            frame.* = .{};
            self.stats.evictions += 1;
        }
        self.advanceHand();
        return f;
    }
    return error.AllFramesPinned;
}

pub fn unpin(self: *BufferPool, id: PageId, dirty: bool) void {
    const f = self.page_table.get(id) orelse unreachable;
    const frame = &self.frames[f];
    assert(frame.pin_count > 0);
    frame.pin_count -= 1;
    if (dirty) frame.dirty = true;
}

pub fn flushAll(self: *BufferPool) Error!void {
    for (0..self.frames.len) |f| try self.flushFrame(@intCast(f));
    try self.pager.sync();
}`,
    rust: `
pub fn fetch_page(&mut self, id: PageId) -> Result<&mut Page, Error> {
    if id >= self.pager.page_count() {
        return Err(Error::PageOutOfRange);
    }
    if let Some(&f) = self.page_table.get(&id) {
        let frame = &mut self.frames[f];
        frame.pin_count += 1;
        frame.referenced = true;
        self.stats.hits += 1;
        return Ok(&mut self.pages[f]);
    }
    self.stats.misses += 1;
    let f = self.take_frame()?;
    self.pager.read_page(id, &mut self.pages[f])?;
    self.install(f, id); // pin = 1, referenced, clean
    Ok(&mut self.pages[f])
}

fn take_frame(&mut self) -> Result<usize, Error> {
    let n = self.frames.len();
    for _ in 0..2 * n {
        let f = self.hand;
        let frame = self.frames[f];
        if frame.page_id != INVALID_PAGE_ID {
            if frame.pin_count > 0 {
                self.advance_hand();
                continue;
            }
            if frame.referenced {
                self.frames[f].referenced = false;
                self.advance_hand();
                continue;
            }
            if frame.dirty {
                self.pager.write_page(frame.page_id, &self.pages[f])?;
                self.stats.writebacks += 1;
            }
            self.page_table.remove(&frame.page_id);
            self.frames[f] = Frame::EMPTY;
            self.stats.evictions += 1;
        }
        self.advance_hand();
        return Ok(f);
    }
    Err(Error::AllFramesPinned)
}

pub fn unpin(&mut self, id: PageId, dirty: bool) {
    let f = *self.page_table.get(&id).expect("page is cached");
    let frame = &mut self.frames[f];
    assert!(frame.pin_count > 0, "unpin without a matching fetch");
    frame.pin_count -= 1;
    if dirty {
        frame.dirty = true;
    }
}

pub fn flush_all(&mut self) -> Result<(), Error> {
    for f in 0..self.frames.len() {
        self.flush_frame(f)?;
    }
    self.pager.sync()
}`
  }
};

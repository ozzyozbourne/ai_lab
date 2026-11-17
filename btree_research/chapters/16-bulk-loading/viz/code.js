/*
 * Chapter 16 code-panel snippets and the programs' expected output.
 * Inlined here because fetch() does not work under file://.
 * The snippets are four functions of zig/src/bulk.zig and rust/src/bulk.rs
 * with the comments removed. closeRightEdge is the body of finish().
 */
window.CHAPTER_CODE = {
  loader: {
    zig: `
fn addPair(self: *BulkLoader, level: usize, pair: Pair) Allocator.Error!void {
    if (level == self.n_levels) {
        self.levels[level] = .{ .arena = .init(self.gpa) };
        self.n_levels += 1;
        const lv = &self.levels[level];
        lv.buf = try lv.arena.allocator().alloc(Pair, self.target(level));
    }
    if (self.levels[level].len == self.target(level)) {
        try self.closeOpenPage(level);
    }
    const lv = &self.levels[level];
    lv.buf[lv.len] = pair;
    lv.len += 1;
}

fn closeOpenPage(self: *BulkLoader, level: usize) Allocator.Error!void {
    const id = try self.copyOut(level);
    const old = self.levels[level].pending;
    self.levels[level].pending = id;
    if (old != nil) {
        if (level == 0) self.tree.nodes.items[old].next = id;
        try self.seal(level, old);
    }
    const lv = &self.levels[level];
    _ = lv.arena.reset(.retain_capacity);
    lv.buf = try lv.arena.allocator().alloc(Pair, self.target(level));
    lv.len = 0;
}

fn seal(self: *BulkLoader, level: usize, id: u32) Allocator.Error!void {
    self.tree.stats.page_writes += 1;
    self.levels[level].sealed += 1;
    const low_key = self.tree.nodes.items[id].keys[0];
    try self.addPair(level + 1, .{ .key = low_key, .slot = id });
}

fn closeRightEdge(self: *BulkLoader) Allocator.Error!void {
    const tree = self.tree;
    var level: usize = 0;
    while (level < self.n_levels) : (level += 1) {
        const lv = &self.levels[level];
        const is_leaf = level == 0;
        const min = tree.min(is_leaf);

        if (lv.pending != nil and lv.len < min) {
            const left = &tree.nodes.items[lv.pending];
            const total = left.len + lv.len;
            if (total <= tree.cap(is_leaf)) {
                for (lv.buf[0..lv.len], left.len..) |pair, i| {
                    left.keys[i] = pair.key;
                    left.slots[i] = pair.slot;
                }
                left.len = @intCast(total);
                lv.len = 0;
            } else {
                const keep = total - total / 2;
                const move = left.len - keep;
                std.mem.copyBackwards(Pair, lv.buf[move .. move + lv.len], lv.buf[0..lv.len]);
                for (0..move) |i| lv.buf[i] = .{ .key = left.keys[keep + i], .slot = left.slots[keep + i] };
                lv.len += move;
                left.len = @intCast(keep);
            }
        }

        const pages_left = @intFromBool(lv.pending != nil) + @as(usize, @intFromBool(lv.len > 0));
        if (lv.sealed == 0 and pages_left == 1) {
            const id = if (lv.pending != nil) lv.pending else try self.copyOut(level);
            tree.stats.page_writes += 1;
            tree.root = id;
            tree.height = level + 1;
            return;
        }

        const pending = lv.pending;
        if (lv.len > 0) {
            const id = try self.copyOut(level);
            self.levels[level].len = 0;
            if (pending != nil) {
                if (is_leaf) tree.nodes.items[pending].next = id;
                try self.seal(level, pending);
            }
            try self.seal(level, id);
        } else {
            try self.seal(level, pending);
        }
        self.levels[level].pending = nil;
    }
}`,
    rust: `
fn add_pair(&mut self, level: usize, pair: Pair) -> Result<(), Error> {
    if level == self.levels.len() {
        let buf = Vec::with_capacity(self.target(level));
        self.levels.push(Level { buf, pending: NIL, sealed: 0 });
    }
    if self.levels[level].buf.len() == self.target(level) {
        self.close_open_page(level)?;
    }
    self.levels[level].buf.push(pair);
    Ok(())
}

fn close_open_page(&mut self, level: usize) -> Result<(), Error> {
    let id = self.copy_out(level)?;
    let old = self.levels[level].pending;
    self.levels[level].pending = id;
    if old != NIL {
        if level == 0 {
            self.tree.nodes[old as usize].next = id;
        }
        self.seal(level, old)?;
    }
    self.levels[level].buf.clear();
    Ok(())
}

fn seal(&mut self, level: usize, id: u32) -> Result<(), Error> {
    self.tree.stats.page_writes += 1;
    self.levels[level].sealed += 1;
    let low_key = self.tree.nodes[id as usize].keys[0];
    self.add_pair(level + 1, Pair { key: low_key, slot: u64::from(id) })
}

fn close_right_edge(&mut self) -> Result<(), Error> {
    let mut level = 0;
    while level < self.levels.len() {
        let is_leaf = level == 0;
        let min = self.tree.min(is_leaf);
        let cap = self.tree.cap(is_leaf);
        let lv = &mut self.levels[level];

        if lv.pending != NIL && lv.buf.len() < min {
            let left = &mut self.tree.nodes[lv.pending as usize];
            let total = left.len + lv.buf.len();
            if total <= cap {
                for (i, pair) in lv.buf.iter().enumerate() {
                    left.keys[left.len + i] = pair.key;
                    left.slots[left.len + i] = pair.slot;
                }
                left.len = total;
                lv.buf.clear();
            } else {
                let keep = total - total / 2;
                let moved = (keep..left.len).map(|i| Pair { key: left.keys[i], slot: left.slots[i] });
                lv.buf.splice(0..0, moved);
                left.len = keep;
            }
        }

        let pending = lv.pending;
        let open = !lv.buf.is_empty();
        let pages_left = usize::from(pending != NIL) + usize::from(open);
        if lv.sealed == 0 && pages_left == 1 {
            let id = if pending != NIL { pending } else { self.copy_out(level)? };
            self.tree.stats.page_writes += 1;
            self.tree.root = id;
            self.tree.height = level + 1;
            return Ok(());
        }

        if open {
            let id = self.copy_out(level)?;
            self.levels[level].buf.clear();
            if pending != NIL {
                if is_leaf {
                    self.tree.nodes[pending as usize].next = id;
                }
                self.seal(level, pending)?;
            }
            self.seal(level, id)?;
        } else {
            self.seal(level, pending)?;
        }
        self.levels[level].pending = NIL;
        level += 1;
    }
    Ok(())
}`
  }
};

/*
 * Which lines light up for each kind of step (1-based, [a, b] is a range).
 * start, push, close and seal happen while keys arrive; end, merge, share,
 * last and root are the steps of closeRightEdge, which finish() runs.
 */
window.CHAPTER_LINES = {
  start: { zig: [[2, 7], [11, 13]], rust: [[2, 4], 9] },
  push: { zig: [[11, 13]], rust: [9] },
  close: { zig: [[8, 10], [17, 19], [24, 27]], rust: [[6, 8], [14, 16], 23] },
  seal: { zig: [[20, 23], [31, 34]], rust: [[17, 22], [28, 31]] },
  end: { zig: [37, 40], rust: [34, 36] },
  merge: { zig: [45, [48, 54]], rust: [42, [45, 51]] },
  share: { zig: [45, [55, 61]], rust: [42, [52, 56]] },
  root: { zig: [[66, 71]], rust: [[63, 68]] },
  last: { zig: [[75, 77]], rust: [[71, 73]] }
};

/* Exact copy of ../expected_output.txt (what zig build run and cargo run print). */
window.CHAPTER_EXPECTED = `Chapter 16: bulk loading

== 1. Hand example: keys 1..13, order M = 4 ==
bulk load, fill 100%:
  level 2: (10)
  level 1: (4 7) (13)
  level 0: [1 2 3] [4 5 6] [7 8 9] [10 11 12] [13]
  pages 8, page writes 8, splits 0
one-by-one insert, ascending:
  level 2: (7)
  level 1: (3 5) (9 11)
  level 0: [1 2] [3 4] [5 6] [7 8] [9 10] [11 12 13]
  pages 9, page writes 25, splits 6

== 2. Building n = 10000 keys, order M = 16 ==
method                 height  leaves  inner  pages  leaf fill  page writes  page reads  splits
bulk load 100%              4     667     46    713        99%          713           0       0
bulk load 90% / 70%         4     770     77    847        86%          847           0       0
insert, ascending           4    1250    155   1405        53%        12802       38631    1401
insert, shuffled            4     941     92   1033        70%        12058       37884    1029

== 3. 1000 random inserts after the bulk load ==
leaf / inner fill  pages before  splits  page writes  pages after
 100% / 100%              713     566         2132         1279
  90% /  70%              847     112         1224          959
  70% /  70%             1100       2         1004         1102
`;

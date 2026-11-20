/*
 * Chapter 23: code shown next to the visualization. Excerpts of zig/src/txn.zig, zig/src/db.zig and
 * rust/src/txn.rs, rust/src/db.rs, lightly abridged (comments shortened, nothing reordered).
 * CHAPTER_PARTS names line ranges by the text of their first and last line.
 */
window.CHAPTER_CODE = {
  touch: {
    zig: [
      "/// Returns a page this transaction may modify, with the",
      "/// same content as page `id`.",
      "fn touch(self: *WriteTxn, id: PageId) Allocator.Error!Page {",
      "    // Already ours: a page is copied at most once per txn.",
      "    if (self.dirty.get(id)) |node| return .{ .id = id, .node = node };",
      "    try self.freed.ensureUnusedCapacity(self.arena.allocator(), 1);",
      "    // Committed: copy it under a new page id (arena memory).",
      "    const copy = try self.allocPage(self.db.store.read(id).*);",
      "    // The old page stays as it is, for older roots.",
      "    self.freed.appendAssumeCapacity(id);",
      "    self.info.copied += 1;",
      "    return copy;",
      "}",
      "",
      "// The caller stores the new id where the old one was:",
      "const r = try self.insertInto(in.children[i], key, value);",
      "in.children[i] = r.id; // why the parent was copied too"
    ].join('\n'),
    rust: [
      "/// Returns the id of a page this transaction may modify,",
      "/// with the same content as page `id`.",
      "fn touch(&mut self, id: PageId) -> Result<PageId, TxnError> {",
      "    // Already ours: a page is copied at most once per txn.",
      "    if self.dirty.contains_key(&id) {",
      "        return Ok(id);",
      "    }",
      "    // Committed: copy it under a new page id (the txn's Vec).",
      "    let copy = self.alloc_page(self.db.store.read(id).clone())?;",
      "    // The old page stays as it is, for older roots.",
      "    self.freed.push(id);",
      "    self.info.copied += 1;",
      "    Ok(copy)",
      "}",
      "",
      "// The caller stores the new id where the old one was:",
      "let (child, outcome) = self.insert_into(child, key, value)?;",
      "n.internal_mut().children[i] = child; // why the parent was copied too"
    ].join('\n')
  },
  commit: {
    zig: [
      "pub fn commit(self: *WriteTxn, gpa: Allocator) CommitError!CommitInfo {",
      "    if (self.failed) return error.TxnFailed;",
      "    const db = self.db;",
      "    // Phase 1: everything that can fail.",
      "    try db.pending.ensureUnusedCapacity(gpa, self.freed.items.len);",
      "    try db.store.grow(gpa, self.next_new);",
      "    // Phase 2: write the new pages, each into a FREE slot.",
      "    var it = self.dirty.iterator();",
      "    while (it.next()) |e| db.store.write(e.key_ptr.*, e.value_ptr.*, self.id);",
      "    // Phase 3: the atomic step, one small write.",
      "    db.current = .{ .txn_id = self.id, .root = self.root, ... };",
      "    db.store.meta_slots[self.id % 2] = db.current.encode();",
      "    // Phase 4: replaced pages are pending, not free.",
      "    for (self.freed.items) |id|",
      "        db.pending.appendAssumeCapacity(.{ .freed_by = self.id, .page = id });",
      "    info.released = db.reclaim();",
      "    self.close(); // frees the arena",
      "    return info;",
      "}"
    ].join('\n'),
    rust: [
      "pub fn commit(mut self) -> Result<CommitInfo, TxnError> {",
      "    if self.failed {",
      "        return Err(TxnError::TxnFailed);",
      "    }",
      "    let id = self.id;",
      "    self.db.store.grow(self.next_new);",
      "    // Phase 2: write the new pages, each into a FREE slot.",
      "    for (&page, &i) in &self.dirty {",
      "        self.db.store.write(page, &self.pages[i], id);",
      "    }",
      "    // Phase 3: the atomic step, one small write.",
      "    self.db.current = Meta { txn_id: id, root: self.root, ... };",
      "    self.db.store.meta_slots[(id % 2) as usize] = self.db.current.encode();",
      "    // Phase 4: replaced pages are pending, not free.",
      "    let freed = self.freed.iter().map(|&page| PendingFree { freed_by: id, page });",
      "    self.db.pending.extend(freed);",
      "    info.released = self.db.reclaim();",
      "    self.committed = true;",
      "    Ok(info) // `self` is dropped here: the Vec of pages is gone",
      "}"
    ].join('\n')
  },
  reclaim: {
    zig: [
      "/// A page freed by txn T is reachable from roots before T",
      "/// only. A snapshot S needs it exactly when S < T.",
      "pub fn reclaim(self: *Db) usize {",
      "    const oldest = if (self.snapshots.items.len > 0)",
      "        self.snapshots.items[0].snap.id",
      "    else",
      "        std.math.maxInt(u64);",
      "    const items = self.pending.items;",
      "    var n: usize = 0;",
      "    // pending is ascending by freed_by: release a prefix.",
      "    while (n < items.len and items[n].freed_by <= oldest) : (n += 1) {",
      "        self.store.release(items[n].page);",
      "    }",
      "    @memmove(items[0 .. items.len - n], items[n..]);",
      "    self.pending.shrinkRetainingCapacity(items.len - n);",
      "    return n;",
      "}"
    ].join('\n'),
    rust: [
      "/// A page freed by txn T is reachable from roots before T",
      "/// only. A snapshot S needs it exactly when S < T.",
      "pub fn reclaim(&mut self) -> usize {",
      "    let oldest = self.snapshots.first().map_or(u64::MAX, |s| s.snap.id);",
      "    // pending is ascending by freed_by: release a prefix.",
      "    let n = self",
      "        .pending",
      "        .iter()",
      "        .take_while(|p| p.freed_by <= oldest)",
      "        .count();",
      "    for p in self.pending.drain(..n) {",
      "        self.store.release(p.page);",
      "    }",
      "    n",
      "}"
    ].join('\n')
  }
};

window.CHAPTER_PARTS = {
  touch: { copy: { zig: ['// Committed: copy it', 'return copy;'], rust: ['// Committed: copy it', 'Ok(copy)'] } },
  commit: {
    write: { zig: ['// Phase 2', 'db.store.write('], rust: ['// Phase 2', 'self.db.store.write('] },
    flip: { zig: ['// Phase 3', 'db.current.encode()'], rust: ['// Phase 3', 'self.db.current.encode()'] }
  },
  reclaim: { rule: { zig: ['const oldest', 'self.store.release('], rust: ['let oldest', 'self.store.release('] } }
};

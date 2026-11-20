/*
 * Chapter 27 — snippets for the code panels. Classic script (no fetch under file://).
 * Abridged from zig/src/{lsm,base_tree,base_insert}.zig and rust/src/{lsm,base_tree,base_insert}.rs;
 * the last one is the JavaScript model of page 2 (viz/local.js).
 */
window.CHAPTER_CODE = {
  write: {
    zig: `
pub fn put(self: *Lsm, gpa: Allocator, key: u64, value: u64) !void {
    try self.maintain(gpa);          // all device I/O of a write is in here
    try self.mem.put(key, value);    // RAM only
}

fn maintain(self: *Lsm, gpa: Allocator) !void {
    while (self.pendingCompaction()) |n| try self.compact(gpa, n);
    if (self.mem.count < self.cfg.memtable_entries) return;
    try self.flush(gpa);             // memtable -> new run in level 0
    while (self.pendingCompaction()) |n| try self.compact(gpa, n);
}

// The B+tree, for comparison: every node it looks at is a block read,
// every node it changes is a block write at the end of the operation.
pub fn touch(self: *BPlusTree, id: NodeId) void {
    const kind: device.Kind = if (self.nodes.get(id).isLeaf()) .data else .index;
    self.dev.pin(id.index(), kind);
}
pub fn dirty(self: *BPlusTree, id: NodeId) void {
    self.dev.markDirty(id.index());
}`,
    rust: `
pub fn put(&mut self, key: u64, value: u64) -> Result<(), OutOfMemory> {
    self.maintain()?;                // all device I/O of a write is in here
    self.mem.put(key, Some(value))   // RAM only
}

fn maintain(&mut self) -> Result<(), OutOfMemory> {
    while let Some(n) = self.pending_compaction() {
        self.compact(n)?;
    }
    if self.mem.count() < self.cfg.memtable_entries {
        return Ok(());
    }
    self.flush()?;                   // memtable -> new run in level 0
    while let Some(n) = self.pending_compaction() {
        self.compact(n)?;
    }
    Ok(())
}

// The B+tree, for comparison: every node it looks at is a block read,
// every node it changes is a block write at the end of the operation.
pub(crate) fn touch(&mut self, id: NodeId) {
    let kind = if self.nodes.get(id).is_leaf() { BlockKind::Data } else { BlockKind::Index };
    self.dev.pin(id.index(), kind);
}
pub(crate) fn dirty(&mut self, id: NodeId) {
    self.dev.mark_dirty(id.index());
}`
  },
  compact: {
    zig: `
fn compact(self: *Lsm, gpa: Allocator, from: usize) !void {
    const target = &self.levels[from]; // level from + 1
    // A tombstone may go only if no older data lies below the output.
    const drop_tombstones = self.deepestLevel() <= from + 1;
    var builder: Builder = try .init(gpa, geo, input_slots); // only allocation

    var merger: Merger = .init(geo);   // inputs, NEWEST FIRST
    if (from == 0) {
        var i = self.l0_len;
        while (i > 0) { i -= 1; merger.addRun(&self.dev, &self.l0[i], 0); }
    } else merger.addRun(&self.dev, &self.levels[from - 1].?, 0);
    if (target.*) |*old| merger.addRun(&self.dev, old, 0);

    while (merger.next(&self.dev)) |slot| {   // newest version of each key
        if (slot.value == null and drop_tombstones) continue;
        builder.append(&self.dev, slot);      // one block write per full block
    }
    const output = builder.finish(gpa, &self.dev);
    // ... free the inputs, install \`output\` as level from + 1
}`,
    rust: `
fn compact(&mut self, from: usize) -> Result<(), OutOfMemory> {
    // A tombstone may go only if no older data lies below the output.
    let drop_tombstones = self.deepest_level() <= from + 1;
    let l0: &[Run] = if from == 0 { &self.l0 } else { &[] };
    let upper = if from == 0 { None } else { self.levels[from - 1].as_ref() };
    let target = self.levels[from].as_ref();
    let mut builder = Builder::new(geo, input_slots, budget_left)?; // only allocation

    let mut merger = Merger::new(geo);  // inputs, NEWEST FIRST
    for run in l0.iter().rev().chain(upper).chain(target) {
        merger.add_run(&mut self.dev, run, 0);
    }
    while let Some(slot) = merger.next(&mut self.dev) {  // newest version of each key
        if slot.value.is_none() && drop_tombstones {
            continue;
        }
        builder.append(&mut self.dev, slot);             // one block write per full block
    }
    let output = builder.finish(&mut self.dev);
    // ... free the inputs, install \`output\` as level from + 1
    Ok(())
}`
  },
  read: {
    zig: `
pub fn get(self: *Lsm, key: u64) ?u64 {
    var result = self.mem.get(key);            // newest place first
    var i = self.l0_len;
    while (result == .absent and i > 0) {      // level 0, newest run first
        i -= 1;
        result = self.probe(&self.l0[i], key);
    }
    for (&self.levels) |*level| {              // then level 1, 2, ...
        if (result != .absent) break;
        if (level.*) |*run| result = self.probe(run, key);
    }
    return switch (result) { .value => |v| v, .tombstone, .absent => null };
}

fn probe(self: *Lsm, run: *const Run, key: u64) Lookup {
    if (!run.mayContain(key)) return .absent;  // min/max in RAM: no I/O
    self.dev.read(.index, 1);
    self.dev.read(.data, 1);
    return run.find(key);                      // may still be .absent: wasted
}`,
    rust: `
pub fn get(&mut self, key: u64) -> Option<u64> {
    let mut result = self.mem.get(key);        // newest place first
    // level 0 newest run first, then level 1, 2, ...
    for run in self.l0.iter().rev().chain(self.levels.iter().flatten()) {
        if result != Lookup::Absent {
            break;
        }
        result = probe(&mut self.dev, &mut self.stats, run, key);
    }
    match result {
        Lookup::Value(v) => Some(v),
        Lookup::Tombstone | Lookup::Absent => None,
    }
}

fn probe(dev: &mut Device, stats: &mut Stats, run: &Run, key: u64) -> Lookup {
    if !run.may_contain(key) {
        return Lookup::Absent;                 // min/max in RAM: no I/O
    }
    dev.read(Kind::Index, 1);
    dev.read(Kind::Data, 1);
    run.find(key)                              // may still be Absent: wasted
}`
  },
  buffered: {
    js: `
// One buffered node (textbook B-epsilon tree; model in viz/local.js).
N.send = function (kind, key) {
  var flushed = null;
  if (this.buffer.length >= this.capacity) {   // no room: make some
    var c = this.victim();                     // child with the most pending messages
    flushed = { child: c, moved: this.flush(c) };
  }
  this.buffer.push({ seq: this.seq++, kind: kind, key: key });   // RAM only
  return { flushed: flushed };
};

N.flush = function (c) {
  var self = this, moved = [], keep = [];
  this.buffer.forEach(function (m) { (self.childOf(m.key) === c ? moved : keep).push(m); });
  moved.forEach(function (m) { self._applyToLeaf(c, m); });   // oldest first: newest wins
  this.buffer = keep;
  this.counters.leafReads++;     // ONE read and ONE write of the leaf ...
  this.counters.leafWrites++;    // ... for moved.length messages
  this.counters.nodeWrites++;    // and the node itself, whose buffer changed
  return moved;
};

N.get = function (key) {
  for (var i = this.buffer.length - 1; i >= 0; i--)           // newest message first
    if (this.buffer[i].key === key) return { present: this.buffer[i].kind === 'put', from: 'buffer' };
  this.counters.queryReads++;                                  // otherwise: read the leaf
  return { present: this.leaves[this.childOf(key)].indexOf(key) >= 0, from: 'leaf' };
};`
  }
};

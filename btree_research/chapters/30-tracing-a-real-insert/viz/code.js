/* Chapter 30: code shown in figure 3 (shortened from zig/src/resumable.zig
 * and rust/src/resumable.rs; the comments are the same), and the output of
 * the chapter programs that the page's self-tests compare the JS models with.
 * Classic script, no fetch. */
(function () {
  'use strict';
  var zig = [
    'pub fn step(self: *InsertOp) Error!Step {',
    '    errdefer self.fail(); // an error ends the operation; nothing stays pinned',
    '    while (true) switch (try self.advance()) {',
    '        .again => {},',
    '        .done => return .done,',
    '        .io => |id| return .{ .io = id }, // "call me again when this page is in the pool"',
    '    };',
    '}',
    '',
    'fn advance(self: *InsertOp) Error!Advance {',
    '    const tree = self.tree;',
    '    switch (self.state) {',
    '        .descend => {',
    '            if (self.need(self.cur)) |id| return .{ .io = id }; // 1. ask first, change nothing',
    '            const page = try tree.pinNode(self.cur); // 2. cannot block: the page is there',
    '            if (page.kind() == kind_leaf) { unpin; self.state = .leaf_put; return .again; }',
    '            const index = childIndex(page, self.key);',
    '            const child = childAt(page, index); unpin;',
    '            try self.path.append(self.arena.allocator(), .{ .id = self.cur, .index = index });',
    '            self.cur = child; // 3. recorded AFTER the yield point',
    '            return .again;',
    '        },',
    '        .leaf_put => {',
    '            if (self.need(self.cur)) |id| return .{ .io = id };',
    '            const leaf = try tree.pinNode(self.cur);',
    '            if (leaf.put(self.key, self.value)) |_| { unpin dirty; return self.finish(); }',
    '            unpin; // page full, nothing changed',
    '            self.state = if (self.path.items.len == 0) .push_root_leaf else .split_leaf;',
    '            return .again;',
    '        },',
    '        .push_root_leaf => {',
    '            if (self.need(tree.root)) |id| return .{ .io = id };',
    '            try self.path.ensureUnusedCapacity(self.arena.allocator(), 1);',
    '            self.cur = try tree.pushRootDown();',
    '            self.path.appendAssumeCapacity(.{ .id = tree.root, .index = 0 });',
    '            self.state = .split_leaf;',
    '            return .again;',
    '        },',
    '        .split_leaf => {',
    '            if (self.need(self.cur)) |id| return .{ .io = id };',
    '            // carry.sep points into the arena: it is read by a LATER call',
    '            self.carry = try tree.splitLeaf(self.arena.allocator(), self.cur, self.key, self.value);',
    '            self.state = .insert_separator;',
    '            return .again;',
    '        },',
    '        .insert_separator => {',
    '            const parent = self.path.getLast(); // look, do not pop: we may yield',
    '            if (self.need(parent.id)) |id| return .{ .io = id };',
    '            const fitted = try tree.insertSeparator(self.arena.allocator(), parent, self.carry);',
    '            _ = self.path.pop();',
    '            if (fitted) return self.finish(); // frees the arena',
    '            self.parent = parent;',
    '            self.state = if (self.path.items.len == 0) .push_root_interior else .split_interior;',
    '            return .again;',
    '        },',
    '        .push_root_interior => {',
    '            if (self.need(tree.root)) |id| return .{ .io = id };',
    '            try self.path.ensureUnusedCapacity(self.arena.allocator(), 1);',
    '            self.parent.id = try tree.pushRootDown();',
    '            self.path.appendAssumeCapacity(.{ .id = tree.root, .index = 0 });',
    '            self.state = .split_interior;',
    '            return .again;',
    '        },',
    '        .split_interior => {',
    '            if (self.need(self.parent.id)) |id| return .{ .io = id };',
    '            self.carry = try tree.splitInterior(self.arena.allocator(), self.parent, self.carry);',
    '            self.state = .insert_separator;',
    '            return .again;',
    '        },',
    '        .done, .failed => unreachable,',
    '    }',
    '}'
  ];
  var rust = [
    'pub fn step(&mut self, tree: &mut DiskBTree) -> Result<Step> {',
    '    loop {',
    '        match self.advance(tree)? { // an error leaves State::Failed behind',
    '            Advance::Again => {}',
    '            Advance::Done => return Ok(Step::Done),',
    '            Advance::Io(id) => return Ok(Step::Io(id)), // "call me again when it is in the pool"',
    '        }',
    '    }',
    '}',
    '',
    'fn advance(&mut self, tree: &mut DiskBTree) -> Result<Advance> {',
    '    // The state is taken out; each arm puts a state back. The enum owns its data.',
    '    match std::mem::replace(&mut self.state, State::Failed) {',
    '        State::Descend { page: id } => {',
    '            if self.missing(tree, id) { // 1. ask first, change nothing',
    '                self.state = State::Descend { page: id }; // the SAME state goes back',
    '                return Ok(Advance::Io(id));',
    '            }',
    '            let page = pin_node(&mut tree.pool, id)?; // 2. cannot block',
    '            if page.kind() == KIND_LEAF { unpin; self.state = State::LeafPut { leaf: id }; return Ok(Again); }',
    '            let index = child_index(&page, &self.key);',
    '            let child = child_at(&page, index); unpin;',
    '            self.path.push(PathEntry { id, index }); // 3. recorded AFTER the yield point',
    '            self.state = State::Descend { page: child };',
    '            Ok(Advance::Again)',
    '        }',
    '        State::LeafPut { leaf } => {',
    '            if self.missing(tree, leaf) { self.state = State::LeafPut { leaf }; return Ok(Io(leaf)); }',
    '            let mut page = pin_node(&mut tree.pool, leaf)?;',
    '            match page.put(&self.key, &self.value) {',
    '                Ok(()) => { unpin dirty; Ok(self.finish(tree)) }',
    '                Err(PageFull) => { unpin; self.state = /* PushRootLeaf or SplitLeaf */; Ok(Again) }',
    '            }',
    '        }',
    '        State::PushRootLeaf => {',
    '            let root = tree.root();',
    '            if self.missing(tree, root) { self.state = State::PushRootLeaf; return Ok(Io(root)); }',
    '            let leaf = tree.push_root_down()?;',
    '            self.path.push(PathEntry { id: root, index: 0 });',
    '            self.state = State::SplitLeaf { leaf };',
    '            Ok(Advance::Again)',
    '        }',
    '        State::SplitLeaf { leaf } => {',
    '            if self.missing(tree, leaf) { self.state = State::SplitLeaf { leaf }; return Ok(Io(leaf)); }',
    '            let carry = tree.split_leaf(leaf, &self.key, &self.value)?; // carry.sep: an owned Vec<u8>',
    '            self.state = State::InsertSeparator { carry }; // ... which MOVES into the next state',
    '            Ok(Advance::Again)',
    '        }',
    '        State::InsertSeparator { carry } => {',
    '            let parent = *self.path.last().unwrap(); // look, do not pop: we may yield',
    '            if self.missing(tree, parent.id) { self.state = State::InsertSeparator { carry }; return Ok(Io(parent.id)); }',
    '            let fitted = tree.insert_separator(parent, &carry)?;',
    '            self.path.pop();',
    '            if fitted { return Ok(self.finish(tree)); }',
    '            self.state = /* PushRootInterior or SplitInterior */ { parent, carry };',
    '            Ok(Advance::Again)',
    '        }',
    '        State::PushRootInterior { mut parent, carry } => {',
    '            let root = tree.root();',
    '            if self.missing(tree, root) { self.state = State::PushRootInterior { parent, carry }; return Ok(Io(root)); }',
    '            parent.id = tree.push_root_down()?;',
    '            self.path.push(PathEntry { id: root, index: 0 });',
    '            self.state = State::SplitInterior { parent, carry };',
    '            Ok(Advance::Again)',
    '        }',
    '        State::SplitInterior { parent, carry } => {',
    '            if self.missing(tree, parent.id) { self.state = State::SplitInterior { parent, carry }; return Ok(Io(parent.id)); }',
    '            let up = tree.split_interior(parent, &carry)?;',
    '            self.state = State::InsertSeparator { carry: up };',
    '            Ok(Advance::Again)',
    '        }',
    '        State::Done | State::Failed => unreachable!(),',
    '    }',
    '}'
  ];
  window.CHAPTER_CODE = { advance: { zig: zig.join('\n'), rust: rust.join('\n') } };

  /* state name -> lines of its arm in each language (1-based, inclusive). */
  function arm(lines, start, isArmStart) {
    var from = -1, to = -1;
    for (var i = 0; i < lines.length; i++) {
      if (from < 0) { if (lines[i].trim().indexOf(start) === 0) from = i + 1; continue; }
      if (isArmStart(lines[i])) { to = i; break; }
    }
    return [[from, to]];
  }
  var zigArm = function (l) { return /^ {8}\.[a-z_, .]+ =>/.test(l); };
  var rustArm = function (l) { return /^ {8}State::/.test(l); };
  var names = { descend: 'Descend', leaf_put: 'LeafPut', push_root_leaf: 'PushRootLeaf', split_leaf: 'SplitLeaf',
    insert_separator: 'InsertSeparator', push_root_interior: 'PushRootInterior', split_interior: 'SplitInterior' };
  window.CHAPTER_CODE_LINES = {};
  Object.keys(names).forEach(function (s) {
    window.CHAPTER_CODE_LINES[s] = { zig: arm(zig, '.' + s + ' =>', zigArm), rust: arm(rust, 'State::' + names[s] + ' ', rustArm) };
  });
  window.CHAPTER_CODE_LINES.done = { zig: [[3, 5]], rust: [[3, 5]] };

  /* From expected_output.txt, Part 1 (the "call" lines and the two dumps). */
  window.EXPECTED_PART1 = [
    'call 1: descend -> Io(page 1)',
    'call 2: descend, leaf_put, push_root_leaf, split_leaf, insert_separator -> Io(page 1)',
    'call 3: insert_separator -> Done',
    'page 1  interior  1 keys  12/4076 bytes  | (2) 20 (3)',
    '  page 2  leaf      5 keys  2500/4076 bytes  next 3  | 05:420 06:444 07:468 10:540 12:588',
    '  page 3  leaf      2 keys  1816/4076 bytes  next -  | 20:780 30:1020',
    'call 1: descend -> Io(page 1)',
    'call 2: descend, descend -> Io(page 2)',
    'call 3: descend, leaf_put, split_leaf, insert_separator -> Io(page 1)',
    'call 4: insert_separator -> Done',
    'page 1  interior  2 keys  24/4076 bytes  | (2) 12 (4) 20 (3)',
    '  page 2  leaf      6 keys  2616/4076 bytes  next 4  | 01:324 03:372 05:420 06:444 07:468 10:540',
    '  page 4  leaf      3 keys  1980/4076 bytes  next 3  | 12:588 15:660 17:708',
    '  page 3  leaf      3 keys  2724/4076 bytes  next -  | 20:780 25:900 30:1020'
  ].join('\n');
  /* From expected_output.txt, Part 4. */
  window.EXPECTED_PART4 = 'insert 16 has split a leaf into pages 4 and 8 and waits for page 1 in state insert_separator';
  /* Not program output (the programs have no toy pages): the calls of the
   * JS model for the climbing split of figure 2, 2-frame pool. The same
   * state sequence, without the waits, is what resumable.zig runs through
   * when a root that is an interior page splits. */
  window.EXPECTED_CASCADE = [
    'call 1: descend -> Io(page 1)',
    'call 2: descend, descend -> Io(page 3)',
    'call 3: descend, leaf_put, split_leaf, insert_separator -> Io(page 1)',
    'call 4: insert_separator, push_root_interior, split_interior, insert_separator -> Io(page 1)',
    'call 5: insert_separator -> Done',
    'under pressure suspended in: descend, leaf_put, split_leaf, insert_separator, push_root_interior, split_interior'
  ].join('\n');
  /* Not program output: pins the behaviour of the two schematic models of figure 1. */
  window.EXPECTED_LANES_27 =
    '1 · S-lock 3 → 1 / 1 · X-lock leaf 1 / 2 · unique: ok / 3 · leaf 1 is full / 4 · split point: 3 | 2 / 4 · SPLIT_L → new blk 5 / 5 · INSERT_UPPER blk 3 / 6 · commit: flush 2 WAL records\n' +
    '1 · push 2 → 4 / 1 · leaf 4 on the stack / 2 · unique: ok / 3 · overflow cell on 4 / 4 · siblings 3, 4, 5 / 4 · 3 pages → 3 / 5 · dividers 27, 45 → page 2 / 6 · commit: 4 page frames';
})();

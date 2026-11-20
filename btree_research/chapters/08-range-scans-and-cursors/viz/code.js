/*
 * Chapter 08 — source snippets for the code panels and the program output for the
 * self-tests (classic script: no fetch under file://).
 * Snippets are trimmed from zig/src/{scan,cursor,link_cursor,stack_cursor}.zig and the
 * matching rust/src files. CHAPTER_PARTS names line ranges inside a snippet by the text
 * of their first and last line, so highlights cannot drift when a snippet is edited.
 * CHAPTER_EXPECTED is copied verbatim from ../expected_output.txt (sections 1 to 4 and 6;
 * section 2 without its last line, whose key u64::MAX a JavaScript number cannot hold).
 */
window.CHAPTER_CODE = {
  scan: {
    zig: `
pub fn next(self: *Self) ?Entry {
    const candidate = switch (self.phase) {
        .done => return null,
        .start => self.cursor.seek(self.tree, startSeek(self.lo, self.hi, self.direction)),
        .running => switch (self.direction) {
            .forward => self.cursor.next(self.tree),
            .backward => self.cursor.prev(self.tree),
        },
    };
    self.phase = .running;
    if (candidate) |found| {
        const inside = switch (self.direction) {
            .forward => bounds.belowUpper(self.hi, found.key),
            .backward => bounds.aboveLower(self.lo, found.key),
        };
        if (inside) return found;
    }
    // Past the far bound or off the end of the tree.
    self.phase = .done;
    return null;
}`,
    rust: `
pub fn next(&mut self, tree: &Tree) -> Option<Entry> {
    let candidate = match self.phase {
        Phase::Done => return None,
        Phase::Start => self.cursor.seek(tree, start_seek(self.lo, self.hi, self.direction)),
        Phase::Running => match self.direction {
            Direction::Forward => self.cursor.next(tree),
            Direction::Backward => self.cursor.prev(tree),
        },
    };
    self.phase = Phase::Running;
    if let Some(found) = candidate {
        let inside = match self.direction {
            Direction::Forward => below_upper(self.hi, found.key),
            Direction::Backward => above_lower(self.lo, found.key),
        };
        if inside {
            return Some(found);
        }
    }
    // Past the far bound or off the end of the tree.
    self.phase = Phase::Done;
    None
}`
  },
  seek: {
    zig: `
/// Which seek puts a cursor on the first entry of the scan.
pub fn startSeek(lo: Bound, hi: Bound, direction: Direction) Seek {
    return switch (direction) {
        .forward => switch (lo) {
            .unbounded => .first,
            .included => |k| .{ .ge = k },
            .excluded => |k| .{ .gt = k },
        },
        .backward => switch (hi) {
            .unbounded => .last,
            .included => |k| .{ .le = k },
            .excluded => |k| .{ .lt = k },
        },
    };
}

/// Where a seek lands inside the leaf that the descent reached.
pub fn landing(keys: []const u64, target: Seek) Landing {
    return switch (target) {
        .first => .{ .forward = 0 },
        .ge => |k| .{ .forward = search.lowerBound(keys, k) },
        .gt => |k| .{ .forward = search.upperBound(keys, k) },
        .last => .{ .backward = keys.len },
        .le => |k| .{ .backward = search.upperBound(keys, k) },
        .lt => |k| .{ .backward = search.lowerBound(keys, k) },
    };
}`,
    rust: `
/// Which seek puts a cursor on the first entry of the scan.
pub fn start_seek(lo: Bound<u64>, hi: Bound<u64>, direction: Direction) -> Seek {
    match direction {
        Direction::Forward => match lo {
            Bound::Unbounded => Seek::First,
            Bound::Included(k) => Seek::Ge(k),
            Bound::Excluded(k) => Seek::Gt(k),
        },
        Direction::Backward => match hi {
            Bound::Unbounded => Seek::Last,
            Bound::Included(k) => Seek::Le(k),
            Bound::Excluded(k) => Seek::Lt(k),
        },
    }
}

/// Where a seek lands inside the leaf that the descent reached.
pub fn landing(keys: &[u64], target: Seek) -> Landing {
    match target {
        Seek::First => Landing::Forward(0),
        Seek::Ge(k) => Landing::Forward(lower_bound(keys, k)),
        Seek::Gt(k) => Landing::Forward(upper_bound(keys, k)),
        Seek::Last => Landing::Backward(keys.len()),
        Seek::Le(k) => Landing::Backward(upper_bound(keys, k)),
        Seek::Lt(k) => Landing::Backward(lower_bound(keys, k)),
    }
}`
  },
  linkStep: {
    zig: `
/// Link cursor: entry \`start\` of the current leaf, or the first entry
/// of the next leaf. ONE link, no parent.
fn settleForward(self: *LinkPosition, tree: *const BPlusTree, start: usize, stats: *Stats) ?Entry {
    var i = start;
    while (self.leaf != .nil) {
        const n = tree.nodes.get(self.leaf);
        if (i < n.len) {
            self.index = i;
            return entryAt(n, i);
        }
        self.leaf = n.kind.leaf.next;
        if (self.leaf != .nil) stats.node_visits += 1;
        i = 0;
    }
    return null; // ran off the right end of the chain
}`,
    rust: `
/// Link cursor: entry \`start\` of the current leaf, or the first entry
/// of the next leaf. ONE link, no parent.
fn settle_forward(&mut self, tree: &BPlusTree, start: usize, stats: &mut Stats) -> Option<Entry> {
    let mut i = start;
    while !self.leaf.is_nil() {
        let n = tree.nodes.get(self.leaf);
        if i < n.len {
            self.index = i;
            return Some(entry_at(n, i));
        }
        self.leaf = n.leaf().next;
        if !self.leaf.is_nil() {
            stats.node_visits += 1;
        }
        i = 0;
    }
    None // ran off the right end of the chain
}`
  },
  stackStep: {
    zig: `
/// Stack cursor: to the neighbouring leaf using only the path.
fn stepLeaf(self: *StackPosition, tree: *const BPlusTree, direction: enum { forward, backward }, stats: *Stats) bool {
    while (self.depth > 0) {
        const frame = &self.frames[self.depth - 1];
        const parent = tree.nodes.get(frame.node);
        stats.node_visits += 1; // back up in the parent
        const has_sibling = if (direction == .forward) frame.child < parent.len else frame.child > 0;
        if (has_sibling) {
            if (direction == .forward) frame.child += 1 else frame.child -= 1;
            const subtree = parent.kind.internal.children[frame.child];
            self.leaf = self.descend(tree, subtree, if (direction == .forward) .first else .last, stats);
            return true;
        }
        self.depth -= 1; // this ancestor has nothing further: pop it
    }
    self.leaf = .nil;
    return false;
}`,
    rust: `
/// Stack cursor: to the neighbouring leaf using only the path.
fn step_leaf(&mut self, tree: &BPlusTree, direction: Step, stats: &mut Stats) -> bool {
    while let Some(frame) = self.frames.last_mut() {
        let parent = tree.nodes.get(frame.node);
        stats.node_visits += 1; // back up in the parent
        let has_sibling = match direction {
            Step::Forward => frame.child < parent.len,
            Step::Backward => frame.child > 0,
        };
        if has_sibling {
            let edge = match direction {
                Step::Forward => { frame.child += 1; Seek::First }
                Step::Backward => { frame.child -= 1; Seek::Last }
            };
            let subtree = parent.internal().children[frame.child];
            self.leaf = self.descend(tree, subtree, edge, stats);
            return true;
        }
        self.frames.pop(); // this ancestor has nothing further: pop it
    }
    self.leaf = NodeId::NIL;
    false
}`
  },
  reseek: {
    zig: `
/// Moves to the following entry and returns it.
pub fn next(self: *Self, tree: *const Tree) ?Entry {
    switch (self.state) {
        .after_last => return null,
        .before_first => return self.seek(tree, .first),
        .on => |key| {
            if (self.version != tree.version) {
                // Save key and re-seek: the position is stale,
                // the key is not.
                self.stats.reseeks += 1;
                return self.seek(tree, .{ .gt = key });
            }
            if (self.pos.next(&tree.base, &self.stats)) |found| {
                self.state = .{ .on = found.key };
                return found;
            }
            self.state = .after_last;
            return null;
        },
    }
}`,
    rust: `
/// Moves to the following entry and returns it.
pub fn next(&mut self, tree: &Tree) -> Option<Entry> {
    match self.state {
        State::AfterLast => None,
        State::BeforeFirst => self.seek(tree, Seek::First),
        State::On(key) => {
            if self.version != tree.version {
                // Save key and re-seek: the position is stale,
                // the key is not.
                self.stats.reseeks += 1;
                return self.seek(tree, Seek::Gt(key));
            }
            if let Some(found) = self.pos.next(&tree.base, &mut self.stats) {
                self.state = State::On(found.key);
                return Some(found);
            }
            self.state = State::AfterLast;
            None
        }
    }
}`
  }
};

window.CHAPTER_PARTS = {
  scan: {
    start: { zig: ['.start =>', '.start =>'], rust: ['Phase::Start =>', 'Phase::Start =>'] },
    return: { zig: ['const inside', 'if (inside) return found;'], rust: ['let inside', 'return Some(found);'] },
    stop: { zig: ['// Past the far bound', 'return null;'], rust: ['// Past the far bound', 'None'] }
  },
  seek: {
    descend: { zig: ['pub fn startSeek', '.excluded => |k| .{ .lt = k },'], rust: ['pub fn start_seek', 'Bound::Excluded(k) => Seek::Lt(k),'] },
    land: { zig: ['pub fn landing', '.lt =>'], rust: ['pub fn landing', 'Seek::Lt'] }
  },
  linkStep: {
    link: { zig: ['self.leaf = n.kind.leaf.next;', 'i = 0;'], rust: ['self.leaf = n.leaf().next;', 'i = 0;'] },
    end: { zig: ['return null; // ran off', 'return null; // ran off'], rust: ['None // ran off', 'None // ran off'] }
  },
  stackStep: {
    up: { zig: ['if (has_sibling) {', 'return true;'], rust: ['if has_sibling {', 'return true;'] },
    down: { zig: ['self.leaf = self.descend', 'return true;'], rust: ['self.leaf = self.descend', 'return true;'] },
    pop: { zig: ['self.depth -= 1;', 'self.depth -= 1;'], rust: ['self.frames.pop();', 'self.frames.pop();'] },
    end: { zig: ['self.leaf = .nil;', 'return false;'], rust: ['self.leaf = NodeId::NIL;', 'false'] }
  },
  reseek: {
    reseek: { zig: ['if (self.version != tree.version) {', 'return self.seek(tree, .{ .gt = key });'], rust: ['if self.version != tree.version {', 'return self.seek(tree, Seek::Gt(key));'] },
    fresh: { zig: ['if (self.pos.next', 'return found;'], rust: ['if let Some(found) = self.pos.next', 'return Some(found);'] }
  }
};

window.CHAPTER_EXPECTED = {
  s1: `== 1. The tree: canonical keys, order M = 4 ==
height 3, 12 keys, 8 nodes
  level 0: #7[15]
  level 1: #2[6 10] #6[20]
  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(15 17) <-> #3(20 25 30)
`,
  s2: `== 2. Bounds matrix: every combination for the bounds 6 and 17 ==
(-inf, +inf) : 1 3 5 6 7 10 12 15 17 20 25 30
(-inf, 17]   : 1 3 5 6 7 10 12 15 17
(-inf, 17)   : 1 3 5 6 7 10 12 15
[6, +inf)    : 6 7 10 12 15 17 20 25 30
[6, 17]      : 6 7 10 12 15 17
[6, 17)      : 6 7 10 12 15
(6, +inf)    : 7 10 12 15 17 20 25 30
(6, 17]      : 7 10 12 15 17
(6, 17)      : 7 10 12 15
edge cases:
[12, 12]     : 12   <- one key
(12, 15)     : (nothing)   <- neighbours, both excluded
[13, 14]     : (nothing)   <- both bounds in one gap
[17, 6]      : (nothing)   <- inverted
[12, 12)     : (nothing)   <- half open, same key
(-inf, 0)    : (nothing)   <- below the smallest u64
`,
  s3: `== 3. Backward: seek to the upper bound, step with prev ==
(-inf, +inf) : 30 25 20 17 15 12 10 7 6 5 3 1
[6, 17)      : 15 12 10 7 6
(6, 17]      : 17 15 12 10 7
[13, +inf)   : 30 25 20 17 15
`,
  s4: `== 4. Two cursor designs, one result ==
scan [5, 20] forward; "#0[2]" = leaf #0, entry 2; "#7.0" = in node #7, down child 0
key  link cursor  stack cursor
5    #0[2]        #7.0 #2.0 -> #0[2]
6    #4[0]        #7.0 #2.1 -> #4[0]
7    #4[1]        #7.0 #2.1 -> #4[1]
10   #1[0]        #7.0 #2.2 -> #1[0]
12   #1[1]        #7.0 #2.2 -> #1[1]
15   #5[0]        #7.1 #6.0 -> #5[0]
17   #5[1]        #7.1 #6.0 -> #5[1]
20   #3[0]        #7.1 #6.1 -> #3[0]
node visits (every move of a cursor to another node):
[5, 20]      forward  :  8 entries, link  7, stack 13
[5, 20]      backward :  8 entries, link  7, stack 13
(-inf, +inf) forward  : 12 entries, link  5, stack 15
[12, 12]     forward  :  1 entries, link  4, stack  7
`,
  s6: `== 6. The tree changes under the cursor ==
both cursors: seek >= 10, next. link on 12 at #1[1], stack on 12 at #7.0 #2.2 -> #1[1]
put 11, 13, 14: leaf #1 fills up and splits
  height 3, 15 keys, 9 nodes
  level 0: #7[15]
  level 1: #2[6 10 12] #6[20]
  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 11) <-> #8(12 13 14) <-> #5(15 17) <-> #3(20 25 30)
  the old position #1[1] now holds 11; stepping from it would return 12 a second time
  link  next -> 13 (re-seek: first key > 12), now at #8[1]
  stack next -> 13 (re-seek: first key > 12), now at #7.0 #2.3 -> #8[1]
delete 13 (the entry under both cursors), 14, 15, 17: 1 borrow, 0 merges
  height 3, 11 keys, 9 nodes
  level 0: #7[15]
  level 1: #2[6 10 12] #6[25]
  leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 11) <-> #8(12) <-> #5(20) <-> #3(25 30)
  link  entry -> none (deleted), next -> 20, prev -> 12
  stack entry -> none (deleted), prev -> 12, next -> 20
  link on 12=1200; put 12=1212 (overwrite); entry -> 12=1212, re-seeks caused: 0
  re-seeks so far: link 3, stack 3
delete every even key while scanning the whole tree forward:
  link  returned: 1 3 5 6 7 10 12 15 17 20 25 30 | re-seeks 5 | left: 1 3 5 7 15 17 25
  stack returned: 1 3 5 6 7 10 12 15 17 20 25 30 | re-seeks 5 | left: 1 3 5 7 15 17 25
`
};

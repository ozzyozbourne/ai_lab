/* Chapter 19: source snippets for the code panels, and the programs' expected output.
 * Classic script (no fetch under file://). The snippets are the chapter's Zig and Rust
 * code with the test-hook calls removed. CH19_MARKS maps a step kind to text fragments;
 * app.js highlights the lines that contain one of them. */
window.CHAPTER_CODE = {
 "coupled": {
  "zig": "// coupled.zig (test-hook calls removed)\nfn latchRoot(tree: *Tree, io: Io, mode: Mode) NodeId {\n    while (true) {\n        const id = tree.root.load(.acquire);\n        latch(tree, io, id, mode);\n        if (tree.root.load(.acquire) == id) return id;\n        unlatch(tree, io, id, mode);\n        _ = tree.stats.root_restarts.fetchAdd(1, .monotonic);\n    }\n}\n\npub fn get(tree: *Tree, io: Io, key: u64) ?u64 {\n    var id = latchRoot(tree, io, .shared);\n    while (true) {\n        const n = tree.table.node(id);\n        switch (n.kind) {\n            .internal => |*in| {\n                const child = in.children[search.childIndex(n.keySlice(), key)];\n                latch(tree, io, child, .shared); // claw down on the child ...\n                unlatch(tree, io, id, .shared); //  ... then lift it off the parent\n                id = child;\n            },\n            .leaf => |*leaf| {\n                const i = search.lowerBound(n.keySlice(), key);\n                const result: ?u64 = if (i < n.len and n.keys[i] == key) leaf.values[i] else null;\n                unlatch(tree, io, id, .shared);\n                return result;\n            },\n        }\n    }\n}\n\npub fn put(tree: *Tree, io: Io, key: u64, value: u64) Error!?u64 {\n    var held: [max_height]NodeId = undefined; // exclusive latches, top-down\n    var n: usize = 0;\n    var top_is_root = true;\n\n    var id = latchRoot(tree, io, .exclusive);\n    held[n] = id;\n    n += 1;\n    while (true) {\n        const node = tree.table.node(id);\n        if (node.isLeaf()) break;\n        const child = node.kind.internal.children[search.childIndex(node.keySlice(), key)];\n        latch(tree, io, child, .exclusive);\n        // SAFE NODE RULE: a child with room cannot split.\n        if (tree.table.node(child).len < tree.maxKeys()) {\n            for (held[0..n]) |ancestor| unlatch(tree, io, ancestor, .exclusive);\n            n = 0;\n            top_is_root = false;\n        }\n        held[n] = child;\n        n += 1;\n        id = child;\n    }\n    defer for (held[0..n]) |h| unlatch(tree, io, h, .exclusive);\n    return insert.insertAtLeaf(tree, held[0..n], top_is_root, key, value);\n}",
  "rust": "// coupled.rs (test-hook calls removed)\nfn latch_root<G>(tree: &Tree, latch: impl Fn(NodeId) -> G) -> (NodeId, G) {\n    loop {\n        let id = tree.root();\n        let guard = latch(id);\n        if tree.root() == id {\n            return (id, guard);\n        }\n        drop(guard);\n        tree.stats.root_restarts.fetch_add(1, Ordering::Relaxed);\n    }\n}\n\npub fn get(tree: &Tree, key: u64) -> Option<u64> {\n    let (_, mut node) = latch_root(tree, |id| tree.table.read(id));\n    loop {\n        match &node.kind {\n            Kind::Internal(internal) => {\n                let child = internal.children[child_index(node.key_slice(), key)];\n                let child_guard = tree.table.read(child); // claw down on the child ...\n                node = child_guard; //                       ... then lift it off the parent\n            }\n            Kind::Leaf(leaf) => {\n                let i = lower_bound(node.key_slice(), key);\n                return (i < node.len && node.keys[i] == key).then(|| leaf.values[i]);\n                // the leaf guard is dropped here\n            }\n        }\n    }\n}\n\npub fn put(tree: &Tree, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {\n    let mut held: Vec<Held<'_>> = Vec::new(); // exclusive guards, top-down\n    let mut top_is_root = true;\n\n    held.push(latch_root(tree, |id| tree.table.write(id)));\n    loop {\n        let (_, node) = held.last().expect(\"never empty\");\n        let Kind::Internal(internal) = &node.kind else {\n            break;\n        };\n        let child = internal.children[child_index(node.key_slice(), key)];\n        let child_guard = tree.table.write(child);\n        // SAFE NODE RULE: a child with room cannot split.\n        if child_guard.len < tree.max_keys() {\n            held.clear(); // drops the guards front to back = top-down\n            top_is_root = false;\n        }\n        held.push((child, child_guard));\n    }\n    // the guards in `held` are dropped, top-down, on return\n    insert_at_leaf(tree, &mut held, top_is_root, key, value)\n}"
 },
 "global": {
  "zig": "// tree.zig (test-hook calls removed)\npub fn get(self: *Tree, io: Io, key: u64) ?u64 {\n    if (self.protocol == .latch_coupling) return coupled.get(self, io, key);\n    self.lockGlobal(io, .shared);\n    defer self.unlockGlobal(io, .shared);\n    return plain.get(self, key); // no latches inside\n}\n\npub fn put(self: *Tree, io: Io, key: u64, value: u64) Error!?u64 {\n    if (self.protocol == .latch_coupling) return coupled.put(self, io, key, value);\n    self.lockGlobal(io, .exclusive);\n    defer self.unlockGlobal(io, .exclusive);\n    return plain.put(self, key, value); // no latches inside\n}\n\nfn lockGlobal(self: *Tree, io: Io, mode: Mode) void {\n    switch (self.protocol) {\n        // A mutex has one mode: two gets exclude each other.\n        .global_mutex => self.mutex.lockUncancelable(io),\n        .global_rwlock => switch (mode) {\n            .shared => self.rwlock.lockSharedUncancelable(io),\n            .exclusive => self.rwlock.lockUncancelable(io),\n        },\n        .latch_coupling => unreachable,\n    }\n}",
  "rust": "// tree.rs (test-hook calls removed)\npub fn get(&self, key: u64) -> Option<u64> {\n    if self.protocol == Protocol::LatchCoupling {\n        return coupled::get(self, key);\n    }\n    let _guard = self.lock_global(Mode::Shared);\n    plain::get(self, key)\n    // _guard is dropped here: unlock\n}\n\npub fn put(&self, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {\n    if self.protocol == Protocol::LatchCoupling {\n        return coupled::put(self, key, value);\n    }\n    let _guard = self.lock_global(Mode::Exclusive);\n    plain::put(self, key, value)\n}\n\nfn lock_global(&self, mode: Mode) -> GlobalGuard<'_> {\n    match (self.protocol, mode) {\n        // A mutex has one mode: two gets exclude each other.\n        (Protocol::GlobalMutex, _) => GlobalGuard::mutex(self.mutex.lock().unwrap()),\n        (Protocol::GlobalRwLock, Mode::Shared) => GlobalGuard::shared(self.rwlock.read().unwrap()),\n        (Protocol::GlobalRwLock, Mode::Exclusive) => GlobalGuard::exclusive(self.rwlock.write().unwrap()),\n        (Protocol::LatchCoupling, _) => unreachable!(),\n    }\n}"
 },
 "optimistic": {
  "pseudo": "// Sketch only: NOT in the chapter's Zig / Rust code.\n// Every node has a version; releasing an exclusive latch bumps it.\nget(key):\n  restart:\n    id = root;  v = version(id)        // wait while a writer holds id\n    if root != id: goto restart\n    while id is internal:\n      child = pick_child(id, key)      // read without a latch\n      cv = version(child)\n      if version(id) != v: goto restart   // id changed: pointer may be stale\n      id = child;  v = cv\n    answer = search_leaf(id, key)      // read without a latch\n    if version(id) != v: goto restart\n    return answer                      // nothing was written to shared memory\n\nput(key):\n  restart:\n    descend as in get, down to leaf id at version v\n    latch_exclusive(id)\n    if version(id) != v: unlatch; goto restart\n    if leaf is full:                   // a split must change the parent\n      unlatch\n      return put_with_latch_coupling(key)\n    insert;  unlatch                   // bumps version(id)"
 }
};
window.CH19_MARKS = {
 "coupled": {
  "rootLoad": [
   "tree.root.load(.acquire);",
   "let id = tree.root();"
  ],
  "rootLatch": [
   "latch(tree, io, id, mode);",
   "let guard = latch(id);"
  ],
  "rootCheck": [
   "== id) return id;",
   "if tree.root() == id {",
   "unlatch(tree, io, id, mode);",
   "drop(guard);"
  ],
  "getChild": [
   "claw down on the child"
  ],
  "getRelease": [
   "then lift it off the parent"
  ],
  "getLeaf": [
   "search.lowerBound",
   "const result",
   "unlatch(tree, io, id, .shared);\n                return",
   "lower_bound(node.key_slice()",
   ".then(|| leaf.values[i])",
   "the leaf guard is dropped"
  ],
  "putChild": [
   "latch(tree, io, child, .exclusive);",
   "let child_guard = tree.table.write(child);"
  ],
  "putSafe": [
   "SAFE NODE RULE",
   ".len < tree.maxKeys()",
   "for (held[0..n]) |ancestor|",
   "child_guard.len < tree.max_keys()",
   "held.clear();"
  ],
  "putInsert": [
   "insertAtLeaf(",
   "insert_at_leaf("
  ],
  "putRelease": [
   "defer for (held[0..n])",
   "the guards in `held` are dropped"
  ]
 },
 "global": {
  "lock": [
   "self.lockGlobal(io",
   "self.lock_global(Mode"
  ],
  "work": [
   "plain.get(self, key)",
   "plain.put(self, key, value)",
   "plain::get(self, key)",
   "plain::put(self, key, value)"
  ],
  "unlock": [
   "defer self.unlockGlobal",
   "_guard is dropped"
  ]
 },
 "optimistic": {
  "optRoot": [
   "id = root;",
   "if root != id"
  ],
  "optChild": [
   "child = pick_child",
   "cv = version(child)"
  ],
  "optValidate": [
   "if version(id) != v: goto restart   //",
   "id = child;  v = cv"
  ],
  "optLeaf": [
   "answer = search_leaf",
   "if version(id) != v: goto restart\n",
   "return answer"
  ],
  "optWrite": [
   "latch_exclusive(id)",
   "unlatch; goto restart",
   "if leaf is full",
   "return put_with_latch_coupling",
   "insert;  unlatch"
  ]
 }
};
window.CH19_EXPECTED = "== 1. One tree, three protocols: canonical keys, order M = 4 ==\nglobal mutex:\n  height 3, 12 keys, 8 nodes\n  level 0: #7[15]\n  level 1: #2[6 10] #6[20]\n  leaves : #0(1 3 5) -> #4(6 7) -> #1(10 12) -> #5(15 17) -> #3(20 25 30)\nglobal rwlock: same tree: yes\nlatch coupling: same tree: yes\n\n== 2. Model run: 20000 single-threaded operations (put, get) against the oracle ==\nglobal mutex   keys=500 height=6 nodes=323 leaf splits=212 internal splits=105 mismatches=0\nglobal rwlock  keys=500 height=6 nodes=323 leaf splits=212 internal splits=105 mismatches=0\nlatch coupling keys=500 height=6 nodes=323 leaf splits=212 internal splits=105 mismatches=0\n\n== 3. A is frozen at the end of its descent, holding its locks. Does B finish? (canonical tree) ==\nA = get 12 (latch coupling holds: #1 shared)\n  B                      global mutex    global rwlock   latch coupling\n  get 25 (other leaf)    waits           finishes        finishes\n  get 10 (same leaf)     waits           finishes        finishes\n  put 16 (other leaf)    waits           waits           finishes\n  put 11 (same leaf)     waits           waits           waits at #1\nA = put 11 (latch coupling holds: #1 exclusive; leaf #1 has room)\n  B                      global mutex    global rwlock   latch coupling\n  get 25 (other leaf)    waits           waits           finishes\n  get 12 (same leaf)     waits           waits           waits at #1\n  put 16 (other leaf)    waits           waits           finishes\nA = put 26 (latch coupling holds: #6, #3 exclusive; leaf #3 is full, its parent #6 has room)\n  B                      global mutex    global rwlock   latch coupling\n  get 12 (under #2)      waits           waits           finishes\n  put 11 (under #2)      waits           waits           finishes\n  get 17 (under #6)      waits           waits           waits at #6\nafter put 8, put 9: A = put 2 (latch coupling holds: #7, #2, #0 exclusive; leaf #0 and its parent #2 are full)\n  B                      global mutex    global rwlock   latch coupling\n  get 25 (under #6)      waits           waits           waits at #7\n\n== 4. Latch coupling: the root is replaced under a reader ==\nbefore: height 1, 3 keys, 1 nodes\n  leaves : #0(5 10 20)\nreader of 20 has read root = #0 and holds no latch yet; now put 6 splits the root\nafter:  height 2, 4 keys, 3 nodes\n  level 0: #2[10]\n  leaves : #0(5 6) -> #1(10 20)\nreader latched #0, saw root = #2, restarted 1 time(s): get 20 = 2000\n\n== 5. A node table of 7: put 15 needs 3 new nodes (leaf, internal, root) ==\nglobal mutex   put 15: OutOfNodes; nodes used 5 -> 5 of 7; tree unchanged: yes; locks still held: none\nglobal rwlock  put 15: OutOfNodes; nodes used 5 -> 5 of 7; tree unchanged: yes; locks still held: none\nlatch coupling put 15: OutOfNodes; nodes used 5 -> 5 of 7; tree unchanged: yes; locks still held: none\n\n== 6. Stress: 4 threads x 5000 operations, then validate and compare with the oracle ==\ndisjoint keys    global mutex   keys=2972 expected=2972 first-time puts=2972 lost=0 failed=0 mismatches=0 valid=yes\ndisjoint keys    global rwlock  keys=2972 expected=2972 first-time puts=2972 lost=0 failed=0 mismatches=0 valid=yes\ndisjoint keys    latch coupling keys=2972 expected=2972 first-time puts=2972 lost=0 failed=0 mismatches=0 valid=yes\noverlapping keys global mutex   keys=2983 expected=2983 first-time puts=2983 lost=0 failed=0 mismatches=0 valid=yes\noverlapping keys global rwlock  keys=2983 expected=2983 first-time puts=2983 lost=0 failed=0 mismatches=0 valid=yes\noverlapping keys latch coupling keys=2983 expected=2983 first-time puts=2983 lost=0 failed=0 mismatches=0 valid=yes\n";

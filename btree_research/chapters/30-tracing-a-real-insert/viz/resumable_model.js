/* Chapter 30, figure 2: the resumable insert of zig/src/resumable.zig (and
 * rust/src/resumable.rs) in JavaScript, on top of chapter 12's JS model of
 * the disk B+tree (base_model.js). Same states, same order of pool calls, so
 * the calls it makes can be checked against what the programs print.
 *
 * Classic script: adds to window.CH30. Needs window.CH12 (base_model.js).
 */
(function (root) {
  'use strict';
  var CH12 = root.CH12 || (typeof require !== 'undefined' ? require('./base_model.js') : null);
  var Tree = CH12.Tree, kb = CH12.kb;

  var STATES = ['descend', 'leaf_put', 'push_root_leaf', 'split_leaf', 'insert_separator', 'push_root_interior', 'split_interior'];
  var WHAT = {
    descend: 'look at one page on the way down',
    leaf_put: 'put the cell into the leaf if it fits',
    push_root_leaf: 'the full leaf is the root: move its content down',
    split_leaf: 'split the leaf around the new cell',
    insert_separator: 'give the separator to the parent',
    push_root_interior: 'the full parent is the root: move its content down',
    split_interior: 'split the parent around the separator'
  };

  function search(page, key) {
    var lo = 0, hi = page.cells.length;
    while (lo < hi) { var mid = (lo + hi) >> 1; if (page.cells[mid].k < key) lo = mid + 1; else hi = mid; }
    return { found: lo < page.cells.length && page.cells[lo].k === key, index: lo };
  }
  function childAt(page, i) { return i === page.cells.length ? page.link : page.cells[i].c; }

  /* BufferPool.evictUnpinned: write back and drop every unpinned page. */
  function evictUnpinned(pool) {
    pool.frames.forEach(function (fr, f) {
      if (fr.page === null || fr.pin > 0) return;
      if (fr.dirty) pool.pager.writes++;
      pool.frames[f] = { page: null, pin: 0, ref: false, dirty: false };
      pool.stats.evictions++;
    });
  }
  /* What the simulated disk does when it completes a read. */
  function supply(pool, id) { pool.fetch(id); pool.unpin(id, false); }

  function InsertOp(tree, key, vlen) {
    this.tree = tree;
    this.key = key;
    this.cell = { k: key, v: vlen };
    this.state = 'descend';
    this.cur = tree.root;
    this.path = [];
    this.parent = null;
    this.carry = null;
    this.existed = false;
    this.waiting = null;
    this.suspended = {};
    this.note = '';
  }
  InsertOp.prototype.need = function (id) {
    if (this.tree.pool.frameOf(id) >= 0) { this.waiting = null; return false; }
    if (this.waiting === null) this.suspended[this.state] = (this.suspended[this.state] || 0) + 1;
    this.waiting = id;
    return true;
  };
  /* One transition. Returns 'again', 'done' or {io: page}. `this.note` says
   * in words what the transition did. */
  InsertOp.prototype.advance = function () {
    var t = this.tree, pool = t.pool, id, page;
    switch (this.state) {
      case 'descend':
        id = this.cur;
        if (this.need(id)) return { io: id };
        pool.fetch(id);
        page = t.pages[id];
        if (page.leaf) {
          pool.unpin(id, false);
          this.state = 'leaf_put';
          this.note = 'Page ' + id + ' is in the pool: pin it, see that it is a <b>leaf</b>, unpin it. Next state: <code>leaf_put</code>.';
          return 'again';
        }
        var r = search(page, this.key), index = r.found ? r.index + 1 : r.index, child = childAt(page, index);
        pool.unpin(id, false);
        this.path.push({ id: id, index: index });
        this.cur = child;
        this.note = 'Page ' + id + ' is in the pool: pin it, binary-search it, unpin it. The key belongs to child page ' + child +
          '. Only <em>now</em>, after the last point where this state could yield, is (page ' + id + ', index ' + index + ') appended to <code>path</code> and <code>cur</code> set to ' + child + '.';
        return 'again';
      case 'leaf_put':
        id = this.cur;
        if (this.need(id)) return { io: id };
        pool.fetch(id);
        page = t.pages[id];
        var s = search(page, this.key);
        var cost = 4 + this.key.length + this.cell.v + 2;
        var free = t.capacity - t.used(id) + (s.found ? t.cost(page, page.cells[s.index]) : 0);
        this.existed = s.found;
        if (cost <= free) {
          if (s.found) page.cells[s.index] = this.cell; else page.cells.splice(s.index, 0, this.cell);
          pool.unpin(id, true);
          if (!this.existed) t.keyCount++;
          this.state = 'done';
          this.note = 'The cell (' + cost + ' bytes) fits into leaf ' + id + ' (' + free + ' free). The page is unpinned dirty, the operation is <b>done</b>, and its arena is freed in one call.';
          return 'done';
        }
        pool.unpin(id, false);
        this.state = this.path.length === 0 ? 'push_root_leaf' : 'split_leaf';
        this.note = 'Leaf ' + id + ' has ' + free + ' free bytes and the cell needs ' + cost + ': full. Nothing was changed. Next state: <code>' + this.state + '</code>.';
        return 'again';
      case 'push_root_leaf':
        if (this.need(t.root)) return { io: t.root };
        this.cur = t.pushRootDown();
        this.path.push({ id: t.root, index: 0 });
        this.state = 'split_leaf';
        this.note = 'The root is in the pool: its content moves to the new page ' + this.cur + ' and page ' + t.root + ' becomes an interior page with one child. (A new page needs no read.) The root is appended to <code>path</code>.';
        return 'again';
      case 'split_leaf':
        if (this.need(this.cur)) return { io: this.cur };
        this.carry = t.splitLeaf(this.cur, this.cell);
        this.state = 'insert_separator';
        this.note = 'Leaf ' + this.carry.left + ' is split; the right half is the new page ' + this.carry.right + '. The result is stored in the operation: <code>carry = {sep: "' + this.carry.sep +
          '", left: ' + this.carry.left + ', right: ' + this.carry.right + '}</code>. The separator bytes live in the arena, because the state that reads them may run many calls from now.';
        return 'again';
      case 'insert_separator':
        var top = this.path[this.path.length - 1];
        if (this.need(top.id)) return { io: top.id };
        var fitted = t.insertSeparator(top, this.carry);
        this.path.pop();
        if (fitted) {
          if (!this.existed) t.keyCount++;
          this.state = 'done';
          this.note = 'Parent page ' + top.id + ' is in the pool: the separator ' + kb(this.carry.sep, 'split') + ' and the pointer to page ' + this.carry.right +
            ' go in. Only now is the top of <code>path</code> popped. The operation is <b>done</b>; its arena (key, value, path, the copy of the split page) is freed in one call.';
          return 'done';
        }
        this.parent = top;
        this.state = this.path.length === 0 ? 'push_root_interior' : 'split_interior';
        this.note = 'Parent page ' + top.id + ' has no room for the separator. Nothing was changed. Next state: <code>' + this.state + '</code>.';
        return 'again';
      case 'push_root_interior':
        if (this.need(t.root)) return { io: t.root };
        this.parent = { id: t.pushRootDown(), index: this.parent.index };
        this.path.push({ id: t.root, index: 0 });
        this.state = 'split_interior';
        this.note = 'The full parent is the root: its content moves to the new page ' + this.parent.id + '.';
        return 'again';
      case 'split_interior':
        if (this.need(this.parent.id)) return { io: this.parent.id };
        this.carry = t.splitInterior(this.parent, this.carry);
        this.state = 'insert_separator';
        this.note = 'Interior page ' + this.carry.left + ' is split; ' + kb(this.carry.sep, 'split') + ' moves up. <code>carry</code> is replaced.';
        return 'again';
    }
    throw new Error('stepped after the end');
  };

  /* Run one insert to the end and record it.
   * opts: {pressure, impatient, cold}. Returns {steps, calls, lines}. */
  function traceInsert(tree, key, vlen, opts) {
    opts = opts || {};
    if (opts.cold !== false) evictUnpinned(tree.pool);
    var op = new InsertOp(tree, key, vlen);
    var steps = [], calls = [], lines = [];
    function snap(kind, caption, hl, extra) {
      var st = {
        kind: kind, caption: caption, highlight: hl || {},
        state: { tree: tree.snapshot(), frames: tree.frameModel(),
          op: { state: op.state, cur: op.cur, path: op.path.map(function (p) { return 'page ' + p.id + ' · child ' + p.index; }),
            carry: op.carry ? 'sep "' + op.carry.sep + '", left ' + op.carry.left + ', right ' + op.carry.right : null,
            waiting: op.waiting, key: key, vlen: vlen, live: op.state !== 'done' },
          calls: JSON.parse(JSON.stringify(calls)), running: kind === 'transition' || kind === 'call' || kind === 'yield' || kind === 'again',
          reads: tree.pool.pager.reads }
      };
      if (extra) for (var x in extra) st[x] = extra[x];
      steps.push(st);
    }
    function hlPage(id, state) { var h = { nodes: {} }; h.nodes['p' + id] = state; return h; }
    snap('start', 'An insert of ' + kb(key, 'inserted') + ' (' + vlen + '-byte value) is created. <code>init</code> copies the key and the value into the operation\'s own <b>arena</b>: the caller\'s buffers will be long gone when the operation finishes. ' +
      'State: <code>descend</code>, <code>cur</code> = the root. ' + (opts.cold !== false ? 'The buffer pool is empty: every page must come from the disk.' : ''), {});
    for (var n = 1; ; n++) {
      var call = { n: n, states: [], end: null };
      calls.push(call);
      var entered = op.state;
      snap('call', '<b>Call ' + n + ' of <code>step()</code>.</b> ' + (n === 1 ? 'It looks at <code>op.state</code> and jumps to that arm of the <code>switch</code>.'
        : 'This is an ordinary function call that starts at the top again. The function\'s local variables from call ' + (n - 1) + ' are gone; it looks at <code>op.state</code> = <code>' + entered +
          '</code> and jumps straight to that arm. Everything it needs is in the operation object on the right.'), {});
      var res;
      for (;;) {
        var before = op.state;
        call.states.push(before);
        res = op.advance();
        if (res === 'again') {
          snap('transition', '<code>' + before + '</code> (' + WHAT[before] + '). ' + op.note, {});
          if (opts.pressure) evictUnpinned(tree.pool);
          continue;
        }
        break;
      }
      if (res === 'done') {
        call.end = 'Done';
        lines.push('call ' + n + ': ' + call.states.join(', ') + ' -> Done');
        snap('done', '<code>' + call.states[call.states.length - 1] + '</code> (' + WHAT[call.states[call.states.length - 1]] + '). ' + op.note + ' <code>step()</code> returns <b>Done</b> after ' + n + ' calls.', {});
        break;
      }
      call.end = 'Io(page ' + res.io + ')';
      lines.push('call ' + n + ': ' + call.states.join(', ') + ' -> Io(page ' + res.io + ')');
      snap('yield', '<code>' + op.state + '</code> needs page ' + res.io + ', and it is <b>not in the buffer pool</b>. A blocking <code>put</code> would sit in <code>read()</code> now. This one changes nothing and <b>returns <code>Io(page ' + res.io +
        ')</code></b> to its caller, which is free to run other operations. The state stays <code>' + op.state + '</code>.', {}, { yielded: res.io });
      if (opts.impatient) {
        var again = op.advance();
        snap('again', 'An impatient caller calls <code>step()</code> again before the disk has answered. The arm for <code>' + op.state + '</code> asks for page ' + again.io +
          ' first, finds it still missing, and returns <code>Io(page ' + again.io + ')</code> again. No page, no counter and no field of the operation changed: asking first and changing afterwards is what makes re-entry safe.', {}, { yielded: again.io });
      }
      supply(tree.pool, res.io);
      snap('disk', 'Some time later the disk completes the read: page ' + res.io + ' is now in a frame of the buffer pool, unpinned. The scheduler wakes the operation that asked for it.', hlPage(res.io, 'found'), { supplied: res.io });
    }
    return { steps: steps, calls: calls, lines: lines, op: op };
  }

  /* The scenario tree of the programs' Part 1 / Part 4. */
  function scenarioTree(frames, count) {
    var tree = new Tree({ pageSize: 4096, frames: frames });
    CH12.SCENARIO.slice(0, count).forEach(function (n) { tree.put(CH12.scenarioKey(n), CH12.scenarioValueLen(n, 4096), false); });
    return tree;
  }

  /* What demo.zig / demo.rs print in Part 1 (the call lines and the dumps). */
  function replayPart1() {
    var tree = scenarioTree(2, 6), out = [];
    function one(n) {
      var t = traceInsert(tree, CH12.scenarioKey(n), CH12.scenarioValueLen(n, 4096), {});
      out = out.concat(t.lines);
      out.push(tree.dump());
    }
    one(7);
    CH12.SCENARIO.slice(7, 11).forEach(function (n) { tree.put(CH12.scenarioKey(n), CH12.scenarioValueLen(n, 4096), false); });
    one(15);
    return { text: out.join('\n'), valid: tree.validate() };
  }
  /* Part 4: the half-split moment. */
  function replayPart4() {
    var tree = scenarioTree(2, 24);
    var op = new InsertOp(tree, '16', 1000), res;
    for (;;) {
      res = op.advance();
      if (res === 'again') continue;
      if (op.state === 'insert_separator') break;
      supply(tree.pool, res.io);
    }
    return 'insert 16 has split a leaf into pages ' + op.carry.left + ' and ' + op.carry.right + ' and waits for page ' + res.io + ' in state ' + op.state;
  }

  var api = { InsertOp: InsertOp, traceInsert: traceInsert, scenarioTree: scenarioTree, replayPart1: replayPart1, replayPart4: replayPart4,
    evictUnpinned: evictUnpinned, STATES: STATES, WHAT: WHAT };
  root.CH30 = root.CH30 || {};
  for (var name in api) root.CH30[name] = api[name];
  if (typeof module !== 'undefined' && module.exports) module.exports = root.CH30;
})(typeof window !== 'undefined' ? window : globalThis);

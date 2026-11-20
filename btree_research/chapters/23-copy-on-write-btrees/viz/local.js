/*
 * Chapter 23, chapter-local model: a copy-on-write B+tree.
 *
 * A JavaScript port of the chapter's Zig / Rust code (zig/src/txn.zig, db.zig, meta.zig), kept
 * statement for statement where page ids are handed out, so that the page ids on screen are the
 * ones the programs print. The page self-tests it against expected_output.txt.
 *
 * It is a classic script (no modules) and defines one global, `Ch23`.
 *
 *   var db = new Ch23.Cow(4);
 *   var steps = db.opPut(13);          // one transaction, recorded as Stepper steps
 *   db.opSnapshot(); db.opRelease(12); db.opTear();
 *   db.save() / Ch23.Cow.load(json)    // plain-data checkpoint of the whole database
 */
(function () {
  'use strict';
  var k = function (v, state) { return window.BTViz ? window.BTViz.k(v, state) : String(v); };
  var pg = function (id) { return '<b>#' + id + '</b>'; };
  var pgs = function (ids) { return ids.map(pg).join(' '); };
  var plural = function (n, word) { return n + ' ' + word + (n === 1 ? '' : 's'); };

  /* ------------------------------------------------------------ CRC-32 and the meta slot */
  var TABLE = (function () {
    var t = [], i, j, c;
    for (i = 0; i < 256; i++) {
      c = i;
      for (j = 0; j < 8; j++) c = c & 1 ? (c >>> 1) ^ 0xEDB88320 : c >>> 1;
      t.push(c >>> 0);
    }
    return t;
  })();
  function crc32(bytes) {
    var c = 0xFFFFFFFF, i;
    for (i = 0; i < bytes.length; i++) c = TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
  }
  function le32(out, v) { out.push(v & 0xFF, (v >>> 8) & 0xFF, (v >>> 16) & 0xFF, (v >>> 24) & 0xFF); }
  /** The 28 checksummed bytes of a meta slot (same layout as meta.zig; values here fit in 32 bits). */
  function metaBytes(m) {
    var b = [];
    le32(b, m.txn); le32(b, 0);
    le32(b, m.root === null ? 0xFFFFFFFF : m.root);
    le32(b, m.height);
    le32(b, m.count); le32(b, 0);
    le32(b, m.pages);
    return b;
  }
  function hex8(n) { return ('00000000' + n.toString(16)).slice(-8); }
  function metaSlot(m) {
    return { txn: m.txn, root: m.root, height: m.height, count: m.count, pages: m.pages, crc: crc32(metaBytes(m)), valid: true };
  }

  /* ------------------------------------------------------------ nodes */
  function leaf(keys, vals) { return { leaf: true, keys: keys || [], vals: vals || [] }; }
  function internal(keys, kids) { return { leaf: false, keys: keys || [], kids: kids || [] }; }
  function copyNode(n) {
    return n.leaf ? leaf(n.keys.slice(), n.vals.slice()) : internal(n.keys.slice(), n.kids.slice());
  }
  function lowerBound(keys, key) { var i = 0; while (i < keys.length && keys[i] < key) i++; return i; }
  function childIndex(keys, key) { var i = 0; while (i < keys.length && keys[i] <= key) i++; return i; }
  function nodeText(n) { return (n.leaf ? '(' : '[') + n.keys.join(' ') + (n.leaf ? ')' : ']'); }

  /* ------------------------------------------------------------ the database */
  function Cow(order) {
    this.order = order || 4;
    this.slots = [];                 // {state: 'free' | 'live', by: txn id, gen: n, node}
    this.free = [];                  // page ids, used as a stack
    this.pending = [];               // {by: txn id, page}
    this.snaps = [];                 // {id, root, height, count, refs}, ascending by id
    this.cur = { txn: 0, root: null, height: 0, count: 0, pages: 0 };
    this.meta = [metaSlot(this.cur), { valid: false, never: true }];
    this.steps = null;               // recording target
  }
  Cow.prototype.maxKeys = function () { return this.order - 1; };
  Cow.prototype.minKeys = function () { return Math.ceil(this.order / 2) - 1; };
  Cow.prototype.save = function () {
    return JSON.stringify({ order: this.order, slots: this.slots, free: this.free, pending: this.pending, snaps: this.snaps, cur: this.cur, meta: this.meta });
  };
  Cow.load = function (json) {
    var d = JSON.parse(json), db = new Cow(d.order);
    db.slots = d.slots; db.free = d.free; db.pending = d.pending; db.snaps = d.snaps; db.cur = d.cur; db.meta = d.meta;
    return db;
  };

  /* ---------------------------------------------------------- reads */
  Cow.prototype.nodeOf = function (id, txn) {
    return txn && txn.dirty[id] ? txn.dirty[id] : this.slots[id].node;
  };
  Cow.prototype.get = function (key, root, txn) {
    var id = root === undefined ? this.cur.root : root, n;
    if (id === null) return undefined;
    for (;;) {
      n = this.nodeOf(id, txn);
      if (n.leaf) { var i = lowerBound(n.keys, key); return i < n.keys.length && n.keys[i] === key ? n.vals[i] : undefined; }
      id = n.kids[childIndex(n.keys, key)];
    }
  };
  /** Keys in [lo, hi) from `root`, using a stack of (page, position) and no sibling links. */
  Cow.prototype.range = function (lo, hi, root) {
    var out = [], stack = [], id = root === undefined ? this.cur.root : root, n, top;
    if (id === null) return out;
    for (;;) {
      n = this.slots[id].node;
      if (n.leaf) { stack.push({ id: id, i: lowerBound(n.keys, lo) }); break; }
      stack.push({ id: id, i: childIndex(n.keys, lo) });
      id = n.kids[stack[stack.length - 1].i];
    }
    while (stack.length) {
      top = stack[stack.length - 1];
      n = this.slots[top.id].node;
      if (n.leaf) {
        if (top.i < n.keys.length) { if (n.keys[top.i] >= hi) return out; out.push(n.keys[top.i++]); continue; }
      } else if (top.i <= n.keys.length) { stack.push({ id: n.kids[top.i], i: 0 }); continue; }
      stack.pop();
      if (stack.length) stack[stack.length - 1].i++;
    }
    return out;
  };
  Cow.prototype.reachable = function (root) {
    var self = this, set = {};
    (function walk(id) {
      if (id === null) return;
      set[id] = true;
      var n = self.slots[id].node;
      if (!n.leaf) n.kids.forEach(walk);
    })(root);
    return set;
  };

  /* ---------------------------------------------------------- the write transaction */
  Cow.prototype.begin = function () {
    return { id: this.cur.txn + 1, root: this.cur.root, height: this.cur.height, count: this.cur.count,
             dirty: {}, moved: {}, freed: [], scrapped: [], taken: [], nextNew: this.slots.length,
             copied: 0, reused: 0, fresh: 0 };
  };
  Cow.prototype.allocPage = function (t, node) {
    var id;
    if (this.free.length) { id = this.free.pop(); t.taken.push(id); t.reused++; t.lastFrom = 'free'; }
    else { id = t.nextNew++; t.fresh++; t.lastFrom = 'fresh'; }
    t.dirty[id] = node;
    return id;
  };
  /** THE copy-on-write step: a private copy of a committed page, under a new page id. */
  Cow.prototype.touch = function (t, id) {
    if (t.dirty[id]) return id;
    var copy = this.allocPage(t, copyNode(this.slots[id].node));
    t.freed.push(id);
    t.moved[id] = copy;
    t.copied++;
    this.rec('copy', t, { old: id, id: copy });
    return copy;
  };
  Cow.prototype.discard = function (t, id) {
    if (t.dirty[id]) { t.scrapped.push(id); delete t.dirty[id]; } else t.freed.push(id);
  };

  Cow.prototype.txnPut = function (t, key, value) {
    if (t.root === null) {
      t.root = this.allocPage(t, leaf([key], [value]));
      t.height = 1; t.count = 1;
      this.rec('first-leaf', t, { id: t.root, key: key });
      return;
    }
    var r = this.insertInto(t, t.root, key, value);
    t.root = r.id;
    if (r.replaced) return;
    if (r.split) {
      var old = r.id;
      t.root = this.allocPage(t, internal([r.split.sep], [r.id, r.split.right]));
      t.height++;
      this.rec('root-grow', t, { id: t.root, left: old, right: r.split.right, sep: r.split.sep });
    }
    t.count++;
  };
  Cow.prototype.insertInto = function (t, id, key, value) {
    id = this.touch(t, id);
    var n = t.dirty[id], i, r;
    if (n.leaf) {
      i = lowerBound(n.keys, key);
      if (i < n.keys.length && n.keys[i] === key) {
        n.vals[i] = value;
        this.rec('overwrite', t, { id: id, key: key });
        return { id: id, replaced: true };
      }
      n.keys.splice(i, 0, key); n.vals.splice(i, 0, value);
      this.rec('insert-leaf', t, { id: id, key: key });
      if (n.keys.length <= this.maxKeys()) return { id: id };
      return { id: id, split: this.splitLeaf(t, id) };
    }
    i = childIndex(n.keys, key);
    r = this.insertInto(t, n.kids[i], key, value);
    n.kids[i] = r.id;
    if (!r.split) return { id: id, replaced: r.replaced };
    n.keys.splice(i, 0, r.split.sep); n.kids.splice(i + 1, 0, r.split.right);
    if (n.keys.length <= this.maxKeys()) return { id: id };
    return { id: id, split: this.splitInternal(t, id) };
  };
  Cow.prototype.splitLeaf = function (t, leftId) {
    var left = t.dirty[leftId], mid = Math.floor(left.keys.length / 2);
    var right = this.allocPage(t, leaf(left.keys.slice(mid), left.vals.slice(mid)));
    left.keys.length = mid; left.vals.length = mid;
    var s = { sep: t.dirty[right].keys[0], right: right };
    this.rec('split-leaf', t, { id: leftId, right: right, sep: s.sep });
    return s;
  };
  Cow.prototype.splitInternal = function (t, leftId) {
    var left = t.dirty[leftId], mid = Math.floor(left.keys.length / 2), sep = left.keys[mid];
    var right = this.allocPage(t, internal(left.keys.slice(mid + 1), left.kids.slice(mid + 1)));
    left.keys.length = mid; left.kids.length = mid + 1;
    this.rec('split-internal', t, { id: leftId, right: right, sep: sep });
    return { sep: sep, right: right };
  };

  Cow.prototype.txnDelete = function (t, key) {
    if (this.get(key, t.root, t) === undefined) return false;      // look before you copy
    t.root = this.deleteFrom(t, t.root, key);
    t.count--;
    var root = this.nodeOf(t.root, t);
    if (root.keys.length === 0) {
      var old = t.root;
      t.root = root.leaf ? null : root.kids[0];
      t.height--;
      this.discard(t, old);
      this.rec('root-shrink', t, { id: t.root, old: old });
    }
    return true;
  };
  Cow.prototype.deleteFrom = function (t, id, key) {
    id = this.touch(t, id);
    var n = t.dirty[id], i;
    if (n.leaf) {
      i = lowerBound(n.keys, key);
      this.rec('remove-key', t, { id: id, key: key });
      n.keys.splice(i, 1); n.vals.splice(i, 1);
      return id;
    }
    i = childIndex(n.keys, key);
    n.kids[i] = this.deleteFrom(t, n.kids[i], key);
    if (this.nodeOf(n.kids[i], t).keys.length < this.minKeys()) this.rebalance(t, id, i);
    return id;
  };
  Cow.prototype.rebalance = function (t, parentId, i) {
    var p = t.dirty[parentId], min = this.minKeys(), self = this;
    var len = function (j) { return self.nodeOf(p.kids[j], t).keys.length; };
    this.rec('underflow', t, { id: p.kids[i] });
    if (i > 0 && len(i - 1) > min) this.borrow(t, parentId, i, i - 1);
    else if (i < p.keys.length && len(i + 1) > min) this.borrow(t, parentId, i, i + 1);
    else if (i > 0) this.merge(t, parentId, i - 1, 'right');
    else this.merge(t, parentId, i, 'left');
  };
  /** Moves one item from sibling `j` (i - 1 or i + 1) into child `i`. The sibling changes: it is copied. */
  Cow.prototype.borrow = function (t, parentId, i, j) {
    var p = t.dirty[parentId], fromLeft = j < i;
    p.kids[j] = this.touch(t, p.kids[j]);
    var sib = t.dirty[p.kids[j]], child = t.dirty[p.kids[i]], si = fromLeft ? i - 1 : i;
    if (child.leaf) {
      if (fromLeft) { child.keys.unshift(sib.keys.pop()); child.vals.unshift(sib.vals.pop()); p.keys[si] = child.keys[0]; }
      else { child.keys.push(sib.keys.shift()); child.vals.push(sib.vals.shift()); p.keys[si] = sib.keys[0]; }
    } else if (fromLeft) {
      child.keys.unshift(p.keys[si]); child.kids.unshift(sib.kids.pop()); p.keys[si] = sib.keys.pop();
    } else {
      child.keys.push(p.keys[si]); child.kids.push(sib.kids.shift()); p.keys[si] = sib.keys.shift();
    }
    this.rec('borrow', t, { id: p.kids[i], sib: p.kids[j], fromLeft: fromLeft });
  };
  /** Merges children li and li + 1 into the one that is already a private copy (`survivor`). */
  Cow.prototype.merge = function (t, parentId, li, survivor) {
    var p = t.dirty[parentId], leftId = p.kids[li], rightId = p.kids[li + 1];
    var keepId = survivor === 'left' ? leftId : rightId, dropId = survivor === 'left' ? rightId : leftId;
    var left = this.nodeOf(leftId, t), right = this.nodeOf(rightId, t), merged;
    this.discard(t, dropId);
    if (left.leaf) merged = leaf(left.keys.concat(right.keys), left.vals.concat(right.vals));
    else merged = internal(left.keys.concat([p.keys[li]], right.keys), left.kids.concat(right.kids));
    t.dirty[keepId] = merged;
    p.kids[li] = keepId;
    p.keys.splice(li, 1); p.kids.splice(li + 1, 1);
    this.rec('merge', t, { id: keepId, dropped: dropId });
  };

  /** Applies the reclamation rule; returns the page ids released. */
  Cow.prototype.reclaim = function () {
    var oldest = this.snaps.length ? this.snaps[0].id : Infinity, out = [];
    while (this.pending.length && this.pending[0].by <= oldest) {
      var p = this.pending.shift();
      this.slots[p.page].state = 'free';
      this.free.push(p.page);
      out.push(p.page);
    }
    return out;
  };
  Cow.prototype.returnIds = function (t) { while (t.taken.length) this.free.push(t.taken.pop()); };

  /** Commit, recorded in its phases. Returns {txn, copied, reused, fresh, freed, released}. */
  Cow.prototype.commit = function (t) {
    var self = this, ids = Object.keys(t.dirty).map(Number);
    if (!ids.length && !t.freed.length) { this.returnIds(t); return { txn: 0, copied: 0, reused: 0, fresh: 0, freed: 0, released: 0 }; }
    while (this.slots.length < t.nextNew) this.slots.push({ state: 'free', by: 0, gen: 0, node: null });
    ids.forEach(function (id) {
      var s = self.slots[id];
      if (s.state !== 'free') throw new Error('overwriting live page #' + id);
      self.slots[id] = { state: 'live', by: t.id, gen: s.gen + 1, node: t.dirty[id] };
    });
    t.scrapped.forEach(function (id) { self.free.push(id); });
    var written = { ids: ids, dirty: t.dirty };
    t.dirty = {};                                     // the pages are in the store now
    this.rec('commit-write', t, { ids: ids, written: true });

    var oldRoot = this.cur.root, pinned = this.snaps.some(function (s) { return s.id === self.cur.txn; });
    this.cur = { txn: t.id, root: t.root, height: t.height, count: t.count, pages: this.slots.length };
    this.meta[t.id % 2] = metaSlot(this.cur);
    this.rec('commit-flip', null, { ids: ids, slot: t.id % 2, oldRoot: pinned ? undefined : oldRoot });

    t.freed.forEach(function (id) { self.pending.push({ by: t.id, page: id }); });
    var released = this.reclaim();
    this.rec('retire', null, { freed: t.freed.slice(), released: released, oldRoot: pinned ? undefined : oldRoot, txn: t.id });
    if (released.length) this.rec('done', null, { txn: t.id });
    void written;
    return { txn: t.id, copied: t.copied, reused: t.reused, fresh: t.fresh, freed: t.freed.length, released: released.length };
  };
  Cow.prototype.abort = function (t) {
    this.rec('abort', t, { ids: Object.keys(t.dirty).map(Number) });
    this.returnIds(t);
    this.rec('aborted', null, {});
  };

  /* ---------------------------------------------------------- snapshots, restart */
  Cow.prototype.snapshot = function () {
    var last = this.snaps[this.snaps.length - 1], c = this.cur;
    if (last && last.id === c.txn) { last.refs++; return last; }
    last = { id: c.txn, root: c.root, height: c.height, count: c.count, refs: 1 };
    this.snaps.push(last);
    return last;
  };
  Cow.prototype.release = function (id) {
    var i = this.snaps.findIndex(function (s) { return s.id === id; });
    if (--this.snaps[i].refs > 0) return [];
    this.snaps.splice(i, 1);
    return this.reclaim();
  };
  Cow.prototype.pick = function () {
    var a = this.meta[0].valid ? this.meta[0] : null, b = this.meta[1].valid ? this.meta[1] : null;
    if (!a) return b;
    if (!b) return a;
    return a.txn > b.txn ? a : b;
  };
  /** What a restart does: pick a meta slot, forget readers, rebuild the free list by reachability. */
  Cow.prototype.reopen = function () {
    var m = this.pick(), i;
    this.cur = { txn: m.txn, root: m.root, height: m.height, count: m.count, pages: m.pages };
    this.snaps = []; this.pending = []; this.free = [];
    this.slots.length = m.pages;
    var live = this.reachable(m.root);
    for (i = 0; i < this.slots.length; i++) {
      this.slots[i].state = live[i] ? 'live' : 'free';
      if (!live[i]) this.free.push(i);
    }
  };

  /* ---------------------------------------------------------- text, as the programs print it */
  Cow.prototype.dump = function (root, txn, height, count) {
    var self = this;
    if (root === undefined) { root = this.cur.root; txn = this.cur.txn; height = this.cur.height; count = this.cur.count; }
    if (root === null) return 'txn ' + txn + ': empty tree\n';
    var out = 'txn ' + txn + ': root #' + root + ', height ' + height + ', ' + count + ' keys\n';
    for (var level = 0; level < height; level++) {
      out += level + 1 === height ? '  leaves :' : '  level ' + level + ':';
      var first = true;
      (function walk(id, down) {
        var n = self.slots[id].node;
        if (down === 0) { out += ' #' + id + nodeText(n); return; }
        if (down === 1) { if (!first) out += ' |'; first = false; }
        n.kids.forEach(function (c) { walk(c, down - 1); });
      })(root, level);
      out += '\n';
    }
    return out;
  };
  Cow.prototype.storeLine = function () {
    return 'store: ' + this.slots.length + ' pages | free:' +
      (this.free.length ? this.free.map(function (id) { return ' #' + id; }).join('') : ' -') + ' | pending:' +
      (this.pending.length ? this.pending.map(function (p) { return ' #' + p.page + '(txn ' + p.by + ')'; }).join('') : ' -');
  };
  /** Every invariant of validate.zig that matters for the picture; [] when all hold. */
  Cow.prototype.validate = function () {
    var self = this, errs = [], cls = {}, i;
    this.free.forEach(function (id) { if (cls[id] || self.slots[id].state !== 'free') errs.push('free list corrupt at #' + id); cls[id] = 'free'; });
    this.pending.forEach(function (p) { if (cls[p.page] || self.slots[p.page].state !== 'live') errs.push('pending corrupt at #' + p.page); cls[p.page] = 'pending'; });
    function walk(root, rootTxn, isCur, height, count) {
      var seen = {}, entries = 0;
      (function node(id, depth, lo, hi) {
        var s = self.slots[id], n = s && s.node;
        if (!s || seen[id]) { errs.push('page #' + id + ' reached twice or missing'); return; }
        seen[id] = true;
        if (s.state !== 'live' || cls[id] === 'free') errs.push('reachable page #' + id + ' is free');
        if (s.by > rootTxn) errs.push('page #' + id + ' was written after root ' + rootTxn);
        if (isCur) { if (cls[id] === 'pending') errs.push('pending page #' + id + ' is reachable'); cls[id] = 'reachable'; }
        else if (cls[id] !== 'reachable' && !(cls[id] === 'pending' && self.pending.some(function (p) { return p.page === id && p.by > rootTxn; }))) errs.push('snapshot page #' + id + ' is unprotected');
        if (n.keys.length > self.maxKeys() || n.keys.length < (depth === 1 ? 1 : self.minKeys())) errs.push('bad occupancy in #' + id);
        n.keys.forEach(function (key, j) {
          if ((j && n.keys[j - 1] >= key) || (lo !== null && key < lo) || (hi !== null && key >= hi)) errs.push('key order in #' + id);
        });
        if (n.leaf) { if (depth !== height) errs.push('uneven depth at #' + id); entries += n.keys.length; }
        else n.kids.forEach(function (c, j) { node(c, depth + 1, j ? n.keys[j - 1] : lo, j < n.keys.length ? n.keys[j] : hi); });
      })(root, 1, null, null);
      if (entries !== count) errs.push('count of root ' + rootTxn);
    }
    if (this.cur.root !== null) walk(this.cur.root, this.cur.txn, true, this.cur.height, this.cur.count);
    for (i = 0; i < this.slots.length; i++) if (!cls[i]) errs.push('page #' + i + ' leaked');
    this.snaps.forEach(function (s) { if (s.root !== null) walk(s.root, s.id, false, s.height, s.count); });
    return errs;
  };

  /* ---------------------------------------------------------- what the page draws */
  /**
   * Plain-data picture of the database: a TreeView forest (one root per held snapshot, the committed
   * root, and the open transaction's private root; shared pages are drawn once and referenced),
   * plus the store, the lists and the meta slots.
   * opts.extra = {root, label}: one more root to draw (an old root on its way out).
   */
  Cow.prototype.picture = function (t, opts) {
    opts = opts || {};
    var self = this, placed = {}, forest = [], states = {}, ofPage = {}, cur = this.cur;
    var pendingBy = {};
    this.pending.forEach(function (p) { pendingBy[p.page] = p.by; });
    function did(id, dirty) { var s = self.slots[id]; return 'p' + id + 'g' + ((s ? s.gen : 0) + (dirty ? 1 : 0)); }
    function build(id, inTxn, label) {
      if (inTxn && t.moved[id] !== undefined) id = t.moved[id];
      var dirty = !!(inTxn && t.dirty[id]), n = dirty ? t.dirty[id] : self.slots[id].node, d = did(id, dirty);
      if (placed[d]) return { ref: d };
      placed[d] = true; ofPage[id] = d;
      if (dirty) states[d] = 'dirty';
      else if (pendingBy[id] !== undefined) states[d] = 'compare';
      else if (self.slots[id].state === 'free') states[d] = 'deleted';
      var model = { id: d, keys: n.keys.slice(), leaf: n.leaf, meta: { label: '#' + id + (label ? ' · ' + label : '') } };
      if (!n.leaf) model.children = n.kids.map(function (c) { return build(c, inTxn); });
      return model;
    }
    if (opts.extra && opts.extra.root !== null && opts.extra.root !== undefined) forest.push(build(opts.extra.root, false, opts.extra.label));
    var curPinned = false;
    this.snaps.forEach(function (s) {
      var isCur = s.id === cur.txn;
      curPinned = curPinned || isCur;
      if (s.root === null) return;
      forest.push(build(s.root, false, (isCur ? 'current, ' : '') + 'snapshot of txn ' + s.id + (s.refs > 1 ? ' ×' + s.refs : '')));
    });
    if (!curPinned && cur.root !== null) forest.push(build(cur.root, false, 'current (txn ' + cur.txn + ')'));
    var txnRoot = t ? (t.moved[t.root] !== undefined ? t.moved[t.root] : t.root) : null;
    if (t && txnRoot !== null && (t.dirty[txnRoot] || txnRoot !== cur.root)) forest.push(build(txnRoot, true, 'txn ' + t.id + ', not committed'));

    var reserved = {};
    if (t) Object.keys(t.dirty).forEach(function (id) { reserved[id] = true; });
    var slots = [], n = Math.max(this.slots.length, t ? t.nextNew : 0), i;
    for (i = 0; i < n; i++) {
      var s = this.slots[i];
      slots.push(reserved[i] ? 'dirty' : !s || s.state === 'free' ? 'free' : pendingBy[i] !== undefined ? 'compare' : 'used');
    }
    return {
      forest: forest.length ? forest : null, states: states, ofPage: ofPage, slots: slots, stored: this.slots.length,
      free: this.free.slice(), pending: this.pending.map(function (p) { return { page: p.page, by: p.by }; }),
      snaps: this.snaps.map(function (s) { return { id: s.id, root: s.root, refs: s.refs, count: s.count }; }),
      meta: this.meta.map(function (m) { return m.valid || !m.never ? { txn: m.txn, root: m.root, count: m.count, crc: hex8(m.crc), valid: m.valid } : { never: true, valid: false }; }),
      cur: { txn: cur.txn, root: cur.root, height: cur.height, count: cur.count },
      txn: t ? { id: t.id, copied: t.copied, reused: t.reused, fresh: t.fresh } : null
    };
  };

  /* ---------------------------------------------------------- recording steps */
  Cow.prototype.rec = function (type, t, d) {
    if (!this.steps) return;
    var self = this, pic = this.picture(t, d.oldRoot !== undefined ? { extra: { root: d.oldRoot, label: 'old root' } } : d.extra ? { extra: d.extra } : null);
    var hl = { nodes: {}, keys: {} }, cap = '', log = null, lines = null, question = null;
    var at = function (id) { return pic.ofPage[id]; };
    var mark = function (id, state) { if (at(id)) hl.nodes[at(id)] = state; };
    var who = this.snaps.length ? 'the snapshot of txn ' + this.snaps[0].id : 'a reader that started earlier';
    switch (type) {
      case 'copy':
        mark(d.old, 'active'); mark(d.id, 'dirty');
        cap = 'Page ' + pg(d.old) + ' ' + nodeText(this.slots[d.old].node) + ' has to change, but it belongs to a committed tree and ' + who +
          ' may be reading it. So it is <b>copied</b> to page ' + pg(d.id) + (t.lastFrom === 'free' ? ', a page id taken from the free list' : ', a new page at the end of the store') +
          '. The copy is private to transaction ' + t.id + '; whoever pointed at ' + pg(d.old) + ' in this transaction now points at ' + pg(d.id) +
          ', which is why the parent had to be copied first.';
        lines = { snippet: 'touch', part: 'copy' };
        if (t.copied === 1) {
          question = { prompt: 'The tree has ' + plural(t.height, 'level') + '. How many committed pages will this transaction copy before it can make its change (not counting a borrow from a sibling)?',
            choices: ['1: only the leaf', t.height + ': one per level', 'all ' + Object.keys(this.reachable(this.cur.root)).length + ' pages of the tree'],
            answer: t.height === 1 ? 0 : 1,
            explain: 'One per level, from the root down to the leaf. A child that moves to a new page id forces its parent to change, and a parent that must change is copied too. Everything off the path is shared.' };
          if (t.height === 1) question.choices.splice(1, 1);
        }
        break;
      case 'first-leaf':
        mark(d.id, 'dirty'); hl.keys[at(d.id) + ':' + d.key] = 'inserted';
        cap = 'The tree is empty, so there is nothing to copy: transaction ' + t.id + ' builds its first leaf as page ' + pg(d.id) + ' with ' + k(d.key, 'inserted') + '.';
        break;
      case 'insert-leaf':
        mark(d.id, 'dirty'); hl.keys[at(d.id) + ':' + d.key] = 'inserted';
        cap = k(d.key, 'inserted') + ' goes into the private leaf ' + pg(d.id) + '. The committed leaf it was copied from is untouched, so every reader still sees the tree without ' + k(d.key) + '.';
        break;
      case 'overwrite':
        mark(d.id, 'dirty'); hl.keys[at(d.id) + ':' + d.key] = 'inserted';
        cap = k(d.key, 'inserted') + ' already exists: its value is replaced in the private leaf ' + pg(d.id) + '. Even an overwrite copies the whole path.';
        break;
      case 'split-leaf':
        mark(d.id, 'split'); mark(d.right, 'split');
        cap = 'The private leaf overflowed and splits. The right half becomes page ' + pg(d.right) + ' and ' + k(d.sep, 'split') + ' is copied up. There are <b>no sibling links</b> to splice: the only pointer to ' + pg(d.right) + ' is the one in its parent.';
        break;
      case 'split-internal':
        mark(d.id, 'split'); mark(d.right, 'split');
        cap = 'The private internal node overflowed too: its right half becomes page ' + pg(d.right) + ' and ' + k(d.sep, 'split') + ' moves up.';
        break;
      case 'root-grow':
        mark(d.id, 'dirty');
        cap = 'The root split, so the transaction builds a new root ' + pg(d.id) + ' above the two halves. The tree of this transaction is one level taller than the committed tree.';
        break;
      case 'remove-key':
        mark(d.id, 'dirty'); hl.keys[at(d.id) + ':' + d.key] = 'deleted';
        cap = k(d.key, 'deleted') + ' is removed from the private leaf ' + pg(d.id) + '. In the committed tree it is still there.';
        break;
      case 'underflow':
        mark(d.id, 'merge');
        cap = 'Page ' + pg(d.id) + ' is left with too few keys. As in chapter 05 it borrows from a sibling or merges with one, but here the two have different costs.';
        break;
      case 'borrow':
        mark(d.id, 'merge'); mark(d.sib, 'dirty');
        cap = 'It borrows from its ' + (d.fromLeft ? 'left' : 'right') + ' sibling. The sibling loses an item, so <b>the sibling had to be copied as well</b> (page ' + pg(d.sib) + '): a borrow costs one page more than the path.';
        break;
      case 'merge':
        mark(d.id, 'merge');
        cap = 'It merges with its sibling ' + pg(d.dropped) + '. The merge goes <b>into the page that is already a private copy</b> (' + pg(d.id) + '); the sibling is only read and then dropped from this tree, so it is not copied.';
        break;
      case 'root-shrink':
        if (d.id !== null) mark(d.id, 'dirty');
        cap = d.id === null ? 'The last key is gone: the transaction\'s tree is empty and has no root page.' : 'The root has one child left, so that child ' + pg(d.id) + ' becomes the root. The tree of this transaction is one level shorter.';
        break;
      case 'commit-write':
        d.ids.forEach(function (id) { mark(id, 'inserted'); });
        cap = '<b>Commit, part 1.</b> The ' + plural(d.ids.length, 'new page') + ' (' + pgs(d.ids) + ') are written into free slots of the store. The meta page still names the old root' +
          (this.cur.root === null ? ' (an empty tree)' : ' ' + pg(this.cur.root)) + ': a crash at this point loses the transaction and nothing else.';
        lines = { snippet: 'commit', part: 'write' };
        break;
      case 'commit-flip':
        d.ids.forEach(function (id) { mark(id, 'found'); });
        cap = '<b>Commit, part 2: the root flip.</b> One small write puts transaction ' + this.cur.txn + ', its root' + (this.cur.root === null ? ' (none)' : ' ' + pg(this.cur.root)) +
          ' and a checksum into meta slot ' + d.slot + ', the slot that did <em>not</em> hold the current root. From now on a reader that picks "valid slot with the higher id" finds the new tree. ' +
          'Nothing was overwritten.';
        lines = { snippet: 'commit', part: 'flip' };
        log = 'commit txn ' + this.cur.txn + ' → root ' + (this.cur.root === null ? 'none' : '#' + this.cur.root);
        break;
      case 'retire':
        if (!d.freed.length) { cap = 'This transaction replaced no committed page, so nothing has to be retired.'; break; }
        if (d.released.length) {
          d.freed.forEach(function (id) { mark(id, 'deleted'); });
          cap = 'The ' + plural(d.freed.length, 'page') + ' this transaction replaced (' + pgs(d.freed) + ') cannot be reached from the new root, and no snapshot holds an older root. ' +
            'They go to the <b>free list</b> at once and the next transaction may overwrite them.';
          question = null;
        } else {
          d.freed.forEach(function (id) { mark(id, 'compare'); });
          cap = 'The ' + plural(d.freed.length, 'page') + ' this transaction replaced (' + pgs(d.freed) + ') cannot be reached from the new root, but ' + who + ' still reads ' +
            (d.freed.length === 1 ? 'it' : 'them') + '. They go to the <b>pending</b> list, tagged "freed by txn ' + d.txn + '", and must not be overwritten. ' +
            'The two roots now share every page that is not on the copied path.';
          question = { prompt: 'Transaction ' + d.txn + ' replaced ' + plural(d.freed.length, 'page') + ' while ' + who + ' is still held. What happens to the old pages?',
            choices: ['They go to the free list now', 'They wait on a pending list', 'They are overwritten with the new content'], answer: 1,
            explain: 'A snapshot older than transaction ' + d.txn + ' can still reach them. They become reusable only when no such snapshot remains.' };
        }
        lines = { snippet: 'reclaim', part: 'rule' };
        break;
      case 'done':
        cap = 'Transaction ' + d.txn + ' is committed. ' + this.summary();
        break;
      case 'abort':
        d.ids.forEach(function (id) { mark(id, 'deleted'); });
        cap = '<b>Abort.</b> The ' + plural(d.ids.length, 'private page') + ' (' + pgs(d.ids) + ') exist only in the transaction\'s memory. Nothing was written to the store, so there is nothing to undo.';
        break;
      case 'aborted':
        cap = 'The transaction\'s memory is dropped in one go and the page ids it had reserved are back on the free list. The store, the meta page and every reader are exactly as before.';
        log = 'abort';
        break;
      default:
        cap = d.caption || '';
        if (d.mark) Object.keys(d.mark).forEach(function (id) { mark(+id, d.mark[id]); });
        log = d.log || null;
        lines = d.lines || null;
        question = d.question || null;
    }
    void self;
    this.steps.push({ type: type, caption: cap, state: pic, highlight: hl, log: log, lines: lines, question: question });
  };
  Cow.prototype.summary = function () {
    var c = this.cur, live = Object.keys(this.reachable(c.root)).length;
    return 'Current tree: ' + plural(c.count, 'key') + ' in ' + plural(live, 'page') + '. Store: ' + plural(this.slots.length, 'page') + ', ' +
      this.free.length + ' free, ' + this.pending.length + ' pending' + (this.snaps.length ? ', ' + plural(this.snaps.length, 'pinned root') : '') + '.';
  };

  /* ---------------------------------------------------------- recorded operations */
  Cow.prototype.record = function (fn) {
    this.steps = [];
    try { fn.call(this); } finally { var out = this.steps; this.steps = null; }
    return out;
  };
  Cow.prototype.note = function (caption, extra) {
    extra = extra || {};
    extra.caption = caption;
    this.rec('note', extra.txn || null, extra);
  };
  /** One write transaction: put (or delete) `key`, then commit, or abort when `abort` is set. */
  Cow.prototype.opWrite = function (kind, key, abort) {
    return this.record(function () {
      var t = this.begin(), c = this.cur, changed;
      this.note('Transaction ' + t.id + ' begins: ' + (kind === 'put' ? 'put ' : 'delete ') + k(key) + '. It starts from the committed root' +
        (c.root === null ? ' (the tree is empty)' : ' ' + pg(c.root)) + ' and may not change any page that root can reach.',
        { log: (kind === 'put' ? 'put ' : 'delete ') + key + (abort ? ' (to be aborted)' : '') });
      if (kind === 'put') { this.txnPut(t, key, key * 100); changed = true; } else changed = this.txnDelete(t, key);
      if (!changed) {
        this.commit(t);
        this.note(k(key) + ' is not in the tree. The transaction looked before copying anything, so it has no private pages and commits nothing: no new root, no new transaction id.', { log: '  not found' });
        return;
      }
      if (abort) this.abort(t);
      else if (!this.commit(t).released) this.note('Transaction ' + t.id + ' is committed. ' + this.summary());
    });
  };
  Cow.prototype.opSnapshot = function () {
    return this.record(function () {
      var s = this.snapshot(), mark = {};
      Object.keys(this.reachable(s.root)).forEach(function (id) { mark[id] = 'found'; });
      this.note(s.refs > 1
        ? 'A second reader takes the same root: the snapshot of transaction ' + s.id + ' now has ' + s.refs + ' references. The root stays pinned until every one of them is released.'
        : 'A reader takes a <b>snapshot</b>: a handle on the committed root' + (s.root === null ? ' (an empty tree)' : ' ' + pg(s.root)) + ' of transaction ' + s.id +
          ', with a reference count of 1. Taking it copies nothing. It only promises that no page this root can reach will be overwritten while the handle is held.',
        { mark: mark, log: 'snapshot of txn ' + s.id + (s.refs > 1 ? ' (×' + s.refs + ')' : '') });
    });
  };
  Cow.prototype.opRelease = function (id) {
    return this.record(function () {
      var s = this.snaps.find(function (x) { return x.id === id; }), self = this;
      if (s.refs > 1) {
        this.release(id);
        this.note('One handle on the snapshot of transaction ' + id + ' is released. ' + plural(s.refs, 'reference') + ' remain' + (s.refs === 1 ? 's' : '') + ', so the root stays pinned and nothing is freed.',
          { log: 'release txn ' + id + ' (' + s.refs + ' left)' });
        return;
      }
      var isCur = id === this.cur.txn, older = this.snaps[0].id < id ? this.snaps[0].id : null;
      var extra = isCur ? null : { root: s.root, label: 'released snapshot of txn ' + id };
      var own = this.reachable(s.root);
      var released = this.release(id), mark = {}, stay = [];
      released.forEach(function (p) { mark[p] = 'deleted'; });
      Object.keys(own).forEach(function (p) { if (self.pending.some(function (x) { return x.page === +p; })) stay.push(+p); });
      var text = 'The last handle on the snapshot of transaction ' + id + ' is released. ';
      if (released.length) {
        text += 'The rule: a page freed by transaction T may be reused once no snapshot older than T remains. ' +
          (this.snaps.length ? 'The oldest snapshot left is that of transaction ' + this.snaps[0].id : 'No snapshot is left') + ', so ' + plural(released.length, 'pending page') +
          ' (' + pgs(released) + ') ' + (released.length === 1 ? 'moves' : 'move') + ' to the <b>free list</b>.' +
          (this.pending.length ? ' ' + plural(this.pending.length, 'page') + ' stay pending for the snapshots that remain.' : '');
      } else if (older !== null && this.pending.length) {
        text += '<b>Nothing is freed.</b> The snapshot of transaction ' + older + ' is older than every transaction on the pending list, and the rule only looks at the oldest snapshot. ' +
          (stay.length ? 'The pages only this root could reach (' + pgs(stay) + ') stay pending although nobody can read them any more: one long-lived reader holds back all later garbage.' : '');
      } else {
        text += 'No page was waiting for it, so nothing moves.';
      }
      this.note(text, { extra: released.length || stay.length ? extra : null, mark: mark, log: 'release txn ' + id + ': ' + released.length + ' freed', lines: { snippet: 'reclaim', part: 'rule' } });
      if (released.length || (extra && stay.length)) this.note('Done. ' + this.summary());
    });
  };
  /** The newest meta slot is torn (its checksum no longer matches), then the database restarts. */
  Cow.prototype.opTear = function () {
    return this.record(function () {
      var slot = this.cur.txn % 2, lost = this.cur.txn;
      this.meta[slot].valid = false;
      this.meta[slot].crc = (this.meta[slot].crc ^ 0xFF00) >>> 0;
      this.note('<b>Crash during the root flip.</b> Suppose the write of meta slot ' + slot + ' for transaction ' + lost + ' was torn: the stored checksum no longer matches the bytes. ' +
        'The other slot was not touched by this commit.', { log: 'meta slot ' + slot + ' torn' });
      var before = this.cur.root;
      this.reopen();
      this.note('<b>Restart.</b> The reader takes the valid slot with the higher id: transaction ' + this.cur.txn + '. Its tree is complete, because transaction ' + lost +
        ' wrote only into pages that this root could not reach. All of transaction ' + lost + ' is gone, and none of it is half there. (Snapshots are in-memory handles; a restart forgets them.)',
        { extra: before !== this.cur.root ? { root: before, label: 'lost commit (txn ' + lost + ')' } : null, log: 'restart → txn ' + this.cur.txn });
      this.note('The free list was rebuilt as "every page the chosen root cannot reach". ' + this.summary());
    });
  };

  window.Ch23 = { Cow: Cow, crc32: crc32, hex8: hex8 };
})();

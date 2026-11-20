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
 *   db.opSnapshot(); db.opRelease(12); db.opTear(); db.opDoubleFault(9);
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
    this.prev = null;                // the committed root one commit back (the other meta slot), or null
    this.meta = [metaSlot(this.cur), { valid: false, never: true }];
    this.steps = null;               // recording target
  }
  Cow.prototype.maxKeys = function () { return this.order - 1; };
  Cow.prototype.minKeys = function () { return Math.ceil(this.order / 2) - 1; };
  Cow.prototype.save = function () {
    return JSON.stringify({ order: this.order, slots: this.slots, free: this.free, pending: this.pending, snaps: this.snaps, cur: this.cur, prev: this.prev, meta: this.meta });
  };
  Cow.load = function (json) {
    var d = JSON.parse(json), db = new Cow(d.order);
    db.slots = d.slots; db.free = d.free; db.pending = d.pending; db.snaps = d.snaps; db.cur = d.cur; db.prev = d.prev; db.meta = d.meta;
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

  /** The transaction id of the oldest root that must stay complete (Infinity when there is none). */
  Cow.prototype.oldestKept = function () {
    var oldest = this.snaps.length ? this.snaps[0].id : Infinity;
    if (this.prev) oldest = Math.min(oldest, this.prev.txn);
    return oldest;
  };
  /** Applies the reclamation rule; returns the entries released, [{page, by}]. */
  Cow.prototype.reclaim = function () {
    var oldest = this.oldestKept(), out = [];
    while (this.pending.length && this.pending[0].by <= oldest) {
      var p = this.pending.shift();
      this.slots[p.page].state = 'free';
      this.free.push(p.page);
      out.push(p);
    }
    return out;
  };
  Cow.prototype.returnIds = function (t) { while (t.taken.length) this.free.push(t.taken.pop()); };

  /** Commit, phase 2: the transaction's pages go into free slots of the store. Returns their ids. */
  Cow.prototype.writePages = function (t) {
    var self = this, ids = Object.keys(t.dirty).map(Number);
    while (this.slots.length < t.nextNew) this.slots.push({ state: 'free', by: 0, gen: 0, node: null });
    ids.forEach(function (id) {
      var s = self.slots[id];
      if (s.state !== 'free') throw new Error('overwriting live page #' + id);
      self.slots[id] = { state: 'live', by: t.id, gen: s.gen + 1, node: t.dirty[id] };
    });
    t.scrapped.forEach(function (id) { self.free.push(id); });
    t.dirty = {};                                     // the pages are in the store now
    return ids;
  };
  /** Commit, recorded in its phases. Returns {txn, copied, reused, fresh, freed, released}. */
  Cow.prototype.commit = function (t) {
    var self = this;
    if (!Object.keys(t.dirty).length && !t.freed.length) { this.returnIds(t); return { txn: 0, copied: 0, reused: 0, fresh: 0, freed: 0, released: 0 }; }
    var ids = this.writePages(t);
    this.rec('commit-write', t, { ids: ids, written: true });

    // The slot about to be overwritten names the root from two commits back. Unless a snapshot
    // pins it, that root is on its way out: draw it once more.
    var gone = this.prev, pinned = gone && this.snaps.some(function (s) { return s.id === gone.txn; });
    var oldRoot = gone && !pinned ? gone.root : undefined;
    this.prev = this.cur;
    this.cur = { txn: t.id, root: t.root, height: t.height, count: t.count, pages: this.slots.length };
    this.meta[t.id % 2] = metaSlot(this.cur);
    this.rec('commit-flip', null, { ids: ids, slot: t.id % 2, oldRoot: oldRoot, gone: gone });

    t.freed.forEach(function (id) { self.pending.push({ by: t.id, page: id }); });
    var released = this.reclaim();
    this.rec('retire', null, { freed: t.freed.slice(), released: released, oldRoot: oldRoot, txn: t.id });
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
  /** A lost slot can only be shown while the other slot holds a valid older commit. */
  Cow.prototype.canTear = function () { return this.meta[0].valid && this.meta[1].valid; };
  Cow.prototype.pick = function () {
    var a = this.meta[0].valid ? this.meta[0] : null, b = this.meta[1].valid ? this.meta[1] : null;
    if (!a) return b;
    if (!b) return a;
    return a.txn > b.txn ? a : b;
  };
  /** The valid slot that pick() did not choose, when it holds an older commit. */
  Cow.prototype.fallback = function () {
    var a = this.meta[0], b = this.meta[1];
    if (!a.valid || !b.valid || a.txn === b.txn) return null;
    return a.txn < b.txn ? a : b;
  };
  /** The set of pages of the tree a meta slot names, or null when that tree is not all there. */
  Cow.prototype.treeComplete = function (m) {
    var self = this, marks = {}, entries = 0, ok = true;
    if (m.root === null) return m.height === 0 && m.count === 0 ? marks : null;
    (function walk(id, depth) {
      var s = self.slots[id];
      if (!ok) return;
      if (id >= m.pages || !s || !s.node || marks[id] || s.by === 0 || s.by > m.txn) { ok = false; return; }
      marks[id] = true;
      if (s.node.leaf) { entries += s.node.keys.length; if (depth !== m.height) ok = false; return; }
      if (depth >= m.height) { ok = false; return; }
      s.node.kids.forEach(function (c) { walk(c, depth + 1); });
    })(m.root, 1);
    return ok && entries === m.count ? marks : null;
  };
  /**
   * What a restart does: pick a meta slot, check its tree, forget readers, keep the other slot's
   * tree as the fallback if it is complete too, and rebuild the lists by reachability.
   */
  Cow.prototype.reopen = function () {
    var m = this.pick(), f = this.fallback(), i;
    var live = this.treeComplete(m);
    if (!live) throw new Error('the tree of transaction ' + m.txn + ' is not complete');
    var kept = f && f.pages <= m.pages ? this.treeComplete(f) : null;
    this.cur = { txn: m.txn, root: m.root, height: m.height, count: m.count, pages: m.pages };
    this.prev = kept ? { txn: f.txn, root: f.root, height: f.height, count: f.count, pages: f.pages } : null;
    this.snaps = []; this.pending = []; this.free = [];
    this.slots.length = m.pages;
    for (i = 0; i < this.slots.length; i++) {
      this.slots[i].state = live[i] || (kept && kept[i]) ? 'live' : 'free';
      if (live[i]) continue;
      if (kept && kept[i]) this.pending.push({ by: m.txn, page: i }); else this.free.push(i);
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
    if (this.prev && this.prev.root !== null) walk(this.prev.root, this.prev.txn, false, this.prev.height, this.prev.count);
    var f = this.fallback();
    if (f && !(this.prev && this.prev.txn === f.txn && this.prev.root === f.root)) errs.push('the fallback slot names a root nobody protects');
    this.snaps.forEach(function (s) { if (s.root !== null) walk(s.root, s.id, false, s.height, s.count); });
    return errs;
  };

  /* ---------------------------------------------------------- who keeps a page alive */
  /**
   * The roots the database keeps complete, oldest first: [{txn, root, roles: [...], slot}].
   * One root can have several roles (a snapshot of the previous commit is also the fallback).
   */
  Cow.prototype.keptRoots = function () {
    var by = {}, cur = this.cur, self = this;
    var add = function (txn, root, role) { (by[txn] = by[txn] || { txn: txn, root: root, roles: [] }).roles.push(role); };
    this.snaps.forEach(function (s) { add(s.id, s.root, 'snap ' + s.id + (s.refs > 1 ? ' ×' + s.refs : '')); });
    if (this.prev) add(this.prev.txn, this.prev.root, 'fallback');
    add(cur.txn, cur.root, 'current');
    return Object.keys(by).map(Number).sort(function (a, b) { return a - b; }).map(function (txn) {
      var r = by[txn];
      r.slot = self.meta.findIndex(function (m) { return m.valid && m.txn === txn && m.root === r.root; });
      return r;
    });
  };
  /** "the root of txn 12 (held by a snapshot; the fallback in meta slot 0)": computed from the model. */
  Cow.prototype.describeRoot = function (r) {
    var what = r.roles.map(function (role) {
      return role === 'fallback' ? 'the fallback in meta slot ' + r.slot : role === 'current' ? 'the current root' : 'held by a snapshot';
    });
    return 'the root of txn ' + r.txn + ' (' + what.join('; ') + ')';
  };
  /** Kept roots other than the current one that reach `page`. */
  Cow.prototype.holders = function (page) {
    var self = this;
    return this.keptRoots().filter(function (r) { return r.txn !== self.cur.txn && r.root !== null && self.reachable(r.root)[page]; });
  };
  /**
   * One sentence per group of pending pages saying which kept root still reaches them, or that
   * none does and they wait only because the rule compares transaction ids. Computed, never assumed.
   */
  Cow.prototype.pendingReasons = function () {
    var self = this, groups = {}, order = [], oldest = this.oldestKept();
    this.pending.forEach(function (p) {
      var h = self.holders(p.page), key = h.map(function (r) { return r.txn; }).join(',');
      if (!groups[key]) { groups[key] = { roots: h, pages: [], by: {} }; order.push(key); }
      groups[key].pages.push(p.page); groups[key].by[p.by] = true;
    });
    return order.map(function (key) {
      var g = groups[key], many = g.pages.length > 1;
      if (g.roots.length) return pgs(g.pages) + ': still reached by ' + g.roots.map(function (r) { return self.describeRoot(r); }).join(' and by ') + '.';
      return pgs(g.pages) + ': no kept root reaches ' + (many ? 'them' : 'it') + ' any more. ' + (many ? 'They wait' : 'It waits') + ' only because the rule compares transaction ids, and the oldest kept root (txn ' + oldest +
        ') is older than transaction ' + Object.keys(g.by).join(', ') + ', which freed ' + (many ? 'them' : 'it') + '.';
    }).join(' ');
  };

  /* ---------------------------------------------------------- what the page draws */
  /**
   * Plain-data picture of the database: a TreeView forest (one root per held snapshot, the fallback
   * root, the committed root, and the open transaction's private root; shared pages are drawn once
   * and referenced),
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
    // Every root that is kept complete, oldest first: snapshots, the fallback, the current root.
    this.keptRoots().forEach(function (r) {
      if (r.root !== null) forest.push(build(r.root, false, r.roles.join(', ')));
    });
    var txnRoot = t ? (t.moved[t.root] !== undefined ? t.moved[t.root] : t.root) : null;
    if (t && txnRoot !== null && (t.dirty[txnRoot] || txnRoot !== cur.root)) forest.push(build(txnRoot, true, 'txn ' + t.id + ' open'));

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
      prev: this.prev ? { txn: this.prev.txn, root: this.prev.root } : null,
      meta: this.meta.map(function (m) { return m.valid || !m.never ? { txn: m.txn, root: m.root, count: m.count, crc: hex8(m.crc), valid: m.valid } : { never: true, valid: false }; }),
      cur: { txn: cur.txn, root: cur.root, height: cur.height, count: cur.count },
      txn: t ? { id: t.id, copied: t.copied, reused: t.reused, fresh: t.fresh } : null
    };
  };

  /* ---------------------------------------------------------- recording steps */
  Cow.prototype.rec = function (type, t, d) {
    if (!this.steps) return;
    var self = this, pic = this.picture(t, d.oldRoot !== undefined ? { extra: { root: d.oldRoot, label: 'old' } } : d.extra ? { extra: d.extra } : null);
    var hl = { nodes: {}, keys: {} }, cap = '', log = null, lines = null, question = null;
    var at = function (id) { return pic.ofPage[id]; };
    var mark = function (id, state) { if (at(id)) hl.nodes[at(id)] = state; };
    var others, gone;
    switch (type) {
      case 'copy':
        mark(d.old, 'active'); mark(d.id, 'dirty');
        others = this.holders(d.old);
        cap = 'Page ' + pg(d.old) + ' ' + nodeText(this.slots[d.old].node) + ' has to change, but it is part of the committed tree of transaction ' + this.cur.txn +
          (others.length ? ', and ' + others.map(function (r) { return self.describeRoot(r); }).join(' and ') + ' can reach it too' : '') +
          '. A page that a committed root can reach is never modified, so it is <b>copied</b> to page ' + pg(d.id) + (t.lastFrom === 'free' ? ', a page id taken from the free list' : ', a new page at the end of the store') +
          '. The copy is private to transaction ' + t.id + '; whoever pointed at ' + pg(d.old) + ' in this transaction now points at ' + pg(d.id) +
          ', which is why the parent had to be copied first.';
        lines = { snippet: 'touch', part: 'copy' };
        if (t.copied === 1 && t.height > 1) {
          question = { prompt: 'The tree has ' + plural(t.height, 'level') + '. How many committed pages will this transaction copy before it can make its change (not counting a borrow from a sibling)?',
            choices: ['1: only the leaf', t.height + ': one per level', 'all ' + Object.keys(this.reachable(this.cur.root)).length + ' pages of the tree'],
            answer: 1,
            explain: 'One per level, from the root down to the leaf. A child that moves to a new page id forces its parent to change, and a parent that must change is copied too. Everything off the path is shared.' };
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
          'No page was overwritten. ' + (this.prev ? 'Meta slot ' + (1 - d.slot) + ' keeps transaction ' + this.prev.txn + ': it is the <b>fallback</b> if slot ' + d.slot + ' can ever not be read. ' : '') +
          (d.gone ? 'Transaction ' + d.gone.txn + ', which slot ' + d.slot + ' named until now, can no longer be chosen by a restart.' : '');
        lines = { snippet: 'commit', part: 'flip' };
        log = 'commit txn ' + this.cur.txn + ' → root ' + (this.cur.root === null ? 'none' : '#' + this.cur.root);
        break;
      case 'retire':
        d.freed.forEach(function (id) { mark(id, 'compare'); });
        d.released.forEach(function (p) { mark(p.page, 'deleted'); });
        if (!d.freed.length && !d.released.length && !this.pending.length) { cap = 'This transaction replaced no committed page, and no page was waiting: nothing to retire.'; break; }
        if (d.freed.length) {
          cap = 'The ' + plural(d.freed.length, 'page') + ' this transaction replaced (' + pgs(d.freed) + ') cannot be reached from the new root. ' +
            (d.freed.length === 1 ? 'It goes' : 'They go') + ' to the <b>pending</b> list, tagged "freed by txn ' + d.txn + '", and must not be overwritten yet. ';
        }
        if (d.released.length) {
          gone = {};
          d.released.forEach(function (p) { gone[p.by] = true; });
          cap += 'No kept root is older than transaction ' + Object.keys(gone).join(', ') + ' any more, so the ' + plural(d.released.length, 'page') + ' ' +
            (Object.keys(gone).length === 1 ? 'it' : 'they') + ' freed (' + pgs(d.released.map(function (p) { return p.page; })) + ') ' + (d.released.length === 1 ? 'moves' : 'move') + ' to the <b>free list</b>. ';
        }
        if (this.pending.length) cap += 'Pending, and why. ' + this.pendingReasons();
        if (d.freed.length) {
          others = this.holders(d.freed[0]);
          question = { prompt: 'Transaction ' + d.txn + ' replaced ' + plural(d.freed.length, 'page') + '. What happens to the old ' + (d.freed.length === 1 ? 'page' : 'pages') + '?',
            choices: ['They go to the free list now', 'They wait on a pending list', 'They are overwritten with the new content'], answer: 1,
            explain: (others.length ? others.map(function (r) { return self.describeRoot(r); }).join(' and ') + ' can still reach them. ' : '') +
              'A page freed by transaction ' + d.txn + ' becomes reusable when no kept root older than ' + d.txn + ' remains: at the earliest when the next commit has overwritten the fallback slot.' };
        }
        lines = { snippet: 'reclaim', part: 'rule' };
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
    this.steps.push({ type: type, caption: cap, state: pic, highlight: hl, log: log, lines: lines, question: question });
  };
  Cow.prototype.summary = function () {
    var c = this.cur, live = Object.keys(this.reachable(c.root)).length;
    return 'Current tree: ' + plural(c.count, 'key') + ' in ' + plural(live, 'page') + '. Store: ' + plural(this.slots.length, 'page') + ', ' +
      this.free.length + ' free, ' + this.pending.length + ' pending' + (this.snaps.length ? ', ' + plural(this.snaps.length, 'pinned root') : '') +
      (this.prev ? ', fallback: txn ' + this.prev.txn : ', no fallback') + '.';
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
      else { this.commit(t); this.note('Transaction ' + t.id + ' is committed. ' + this.summary()); }
    });
  };
  Cow.prototype.opSnapshot = function () {
    return this.record(function () {
      var s = this.snapshot(), mark = {};
      if (s.root !== null) Object.keys(this.reachable(s.root)).forEach(function (id) { mark[id] = 'found'; });
      this.note(s.refs > 1
        ? 'A second reader takes the same root: the snapshot of transaction ' + s.id + ' now has ' + s.refs + ' references. The root stays pinned until every one of them is released.'
        : 'A reader takes a <b>snapshot</b>: a handle on the committed root' + (s.root === null ? ' (an empty tree)' : ' ' + pg(s.root)) + ' of transaction ' + s.id +
          ', with a reference count of 1. Taking it copies nothing. It only promises that no page this root can reach will be overwritten while the handle is held.',
        { mark: mark, log: 'snapshot of txn ' + s.id + (s.refs > 1 ? ' (×' + s.refs + ')' : '') });
    });
  };
  Cow.prototype.opRelease = function (id) {
    return this.record(function () {
      var s = this.snaps.find(function (x) { return x.id === id; });
      if (s.refs > 1) {
        this.release(id);
        this.note('One handle on the snapshot of transaction ' + id + ' is released. ' + plural(s.refs, 'reference') + ' remain' + (s.refs === 1 ? 's' : '') + ', so the root stays pinned and nothing is freed.',
          { log: 'release txn ' + id + ' (' + s.refs + ' left)' });
        return;
      }
      var kept = this.keptRoots().some(function (r) { return r.txn === id && r.roles.length > 1; });
      var extra = kept ? null : { root: s.root, label: 'released' };
      var released = this.release(id), mark = {}, oldest = this.oldestKept();
      released.forEach(function (p) { mark[p.page] = 'deleted'; });
      var text = 'The last handle on the snapshot of transaction ' + id + ' is released. ';
      if (released.length) {
        text += 'The rule: a page freed by transaction T may be reused once no kept root older than T remains. The oldest kept root is now transaction ' + oldest +
          ', so ' + plural(released.length, 'pending page') + ' (' + pgs(released.map(function (p) { return p.page; })) + ') ' + (released.length === 1 ? 'moves' : 'move') + ' to the <b>free list</b>. ';
      } else if (this.pending.length) {
        text += '<b>Nothing is freed</b>: the oldest kept root is transaction ' + oldest + ', and every pending page was freed by a later transaction. ';
      } else {
        text += 'No page was waiting, so nothing moves.';
      }
      if (this.pending.length) text += 'Pending, and why. ' + this.pendingReasons();
      this.note(text, { extra: extra, mark: mark, log: 'release txn ' + id + ': ' + released.length + ' freed', lines: { snippet: 'reclaim', part: 'rule' } });
      if (extra) this.note('Done. ' + this.summary());
    });
  };
  /** Draw `root` as an extra root only if a store of `pages` pages still holds all of it. */
  Cow.prototype.drawable = function (root, pages) {
    return root !== null && Object.keys(this.reachable(root)).every(function (id) { return +id < pages; });
  };
  /** The newest meta slot is torn (its checksum no longer matches), then the database restarts. */
  Cow.prototype.opTear = function () {
    return this.record(function () {
      var slot = this.cur.txn % 2, lost = this.cur.txn, before = this.cur.root;
      var waiting = this.pending.filter(function (p) { return p.by === lost; }).map(function (p) { return p.page; });
      this.meta[slot].valid = false;
      this.meta[slot].crc = (this.meta[slot].crc ^ 0xFF00) >>> 0;
      this.note('<b>Crash during the root flip.</b> Suppose the write of meta slot ' + slot + ' for transaction ' + lost + ' was torn: the stored checksum no longer matches the bytes. ' +
        'The other slot was not touched by this commit.', { log: 'meta slot ' + slot + ' torn' });
      var extra = this.drawable(before, this.pick().pages) ? { root: before, label: 'lost' } : null;
      this.reopen();
      this.note('<b>Restart.</b> The reader takes the valid slot with the higher id: transaction ' + this.cur.txn + '. Its tree is complete: transaction ' + lost +
        ' wrote only into free pages' + (waiting.length ? ', and the ' + plural(waiting.length, 'page') + ' it replaced (' + pgs(waiting) + ') ' + (waiting.length === 1 ? 'was' : 'were') + ' still pending' : '') +
        '. All of transaction ' + lost + ' is gone, and none of it is half there. (Snapshots are in-memory handles; a restart forgets them.)',
        { extra: extra && extra.root !== this.cur.root ? extra : null, log: 'restart → txn ' + this.cur.txn });
      this.note('The lists were rebuilt by walking the tree: every page the chosen root cannot reach is free. ' +
        (this.prev ? 'The other slot still names transaction ' + this.prev.txn + ', so its pages are kept as the fallback. ' : 'No second readable slot is left, so there is no fallback until the next commit rewrites slot ' + slot + '. ') + this.summary());
    });
  };
  /**
   * Two faults at once: the next transaction (put `key`) loses power after writing its pages and
   * before its meta write, and the slot of the newest commit turns out to be unreadable.
   */
  Cow.prototype.opDoubleFault = function (key) {
    return this.record(function () {
      var t = this.begin(), newest = this.cur.txn, slot = newest % 2, before = this.cur.root;
      var waiting = this.pending.filter(function (p) { return p.by === newest; }).map(function (p) { return p.page; });
      this.note('Transaction ' + t.id + ' begins: put ' + k(key) + '. This time the power will fail in the middle of its commit.', { log: 'put ' + key + ' (will crash)' });
      this.txnPut(t, key, key * 100);
      var ids = this.writePages(t);
      this.rec('commit-write', t, { ids: ids, written: true });
      this.meta[slot].valid = false;
      this.meta[slot].crc = (this.meta[slot].crc ^ 0xFF00) >>> 0;
      this.note('<b>Power fails</b> before the meta write of transaction ' + t.id + '. And when the machine comes back, meta slot ' + slot + ' (transaction ' + newest +
        ', the newest commit) cannot be read: a bad sector. Two faults at once. The only readable slot is the one transaction ' + t.id + ' was about to overwrite.',
        { txn: t, log: 'crash; meta slot ' + slot + ' unreadable' });
      var extra = this.drawable(before, this.pick().pages) ? { root: before, label: 'lost' } : null;
      this.reopen();
      this.note('<b>Restart.</b> Slot ' + (1 - slot) + ' names transaction ' + this.cur.txn + ', and its tree is complete, although transaction ' + t.id + ' had already written ' + plural(ids.length, 'page') +
        ' (' + pgs(ids) + '). Those went into free pages' + (waiting.length ? ', and the ' + plural(waiting.length, 'page') + ' transaction ' + newest + ' had replaced (' + pgs(waiting) +
        ') ' + (waiting.length === 1 ? 'was' : 'were') + ' still pending, so ' + (waiting.length === 1 ? 'it was' : 'they were') + ' not among them' : '') +
        '. <b>This is why a freed page waits one more commit.</b> Transactions ' + newest + ' and ' + t.id + ' are gone; nothing is half there.',
        { extra: extra && extra.root !== this.cur.root ? extra : null, log: 'restart → txn ' + this.cur.txn });
      this.note('The lists were rebuilt by walking the tree. ' + this.summary());
    });
  };

  window.Ch23 = { Cow: Cow, crc32: crc32, hex8: hex8 };
})();

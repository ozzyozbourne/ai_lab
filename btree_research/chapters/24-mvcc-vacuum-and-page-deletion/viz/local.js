/*
 * Chapter 24, chapter-local model: a JavaScript port of the chapter's Zig / Rust programs
 * (store, index, db, dump). The whole database is ONE plain object, so a step of the timeline can
 * hold a deep copy of it and the page can continue from whatever step is on screen.
 *
 * Every mutating function takes an optional `emit(type, info)` callback and calls it right after
 * each change worth showing; the page turns those calls into steps.
 *
 * The second half is the drawing (Ch24.Picture): the tree, the leaf chain with half-dead pages in
 * it, the deleted pages and the free list, which the toolkit's TreeView cannot show (see there).
 *
 * Classic script: defines window.Ch24.
 */
(function () {
  'use strict';

  var NIL = -1, SHIFT = 65536;            // index key = user key * 65536 + tid

  function pack(key, tid) { return key * SHIFT + tid; }
  function userKey(ik) { return Math.floor(ik / SHIFT); }
  function tidOf(ik) { return ik % SHIFT; }

  /* --------------------------------------------------------------- arena (slot array + free list) */
  function arena() { return { slots: [], freeHead: NIL, live: 0 }; }
  function alloc(a, value) {
    a.live++;
    if (a.freeHead !== NIL) {
      var id = a.freeHead;
      a.freeHead = a.slots[id].free;
      a.slots[id] = value;
      return id;
    }
    a.slots.push(value);
    return a.slots.length - 1;
  }
  function release(a, id) {
    a.slots[id] = { free: a.freeHead };
    a.freeHead = id;
    a.live--;
  }
  function isLive(a, id) { return id >= 0 && id < a.slots.length && a.slots[id].free === undefined; }
  function freeList(a) {
    var out = [];
    for (var id = a.freeHead; id !== NIL; id = a.slots[id].free) out.push(id);
    return out;
  }

  /* ------------------------------------------------------------------------------------- store */
  function create(order) {
    return {
      order: order, bottomUp: true,
      now: 0, open: [],                    // transaction counter (= epoch), open snapshots
      versions: arena(), pages: arena(),
      root: NIL, first: NIL, height: 0, count: 0,
      delHead: NIL, delTail: NIL,          // deleted pages waiting to be recycled (FIFO)
      stats: { leafSplits: 0, internalSplits: 0, splitsAvoided: 0, simple: 0, bottomUp: 0, vacuum: 0,
               halfDead: 0, unlinked: 0, recycled: 0, reused: 0 },
      reads: { heapFetches: 0, hintSkips: 0, hintsSet: 0, movedRight: 0 },
      scan: null                           // the one paused scan the page lets the reader run
    };
  }
  function tick(db) { return ++db.now; }
  function openSnapshot(db) { db.open.push(db.now); return db.now; }
  function closeSnapshot(db, s) { db.open.splice(db.open.indexOf(s), 1); }
  function horizon(db) { return db.open.reduce(function (h, s) { return Math.min(h, s); }, db.now); }
  function visible(v, snapshot) { return v.xmin <= snapshot && (v.xmax === 0 || v.xmax > snapshot); }
  function deadToAll(db, tid) {
    var v = db.versions.slots[tid];
    return v.xmax !== 0 && v.xmax <= horizon(db);
  }

  /* ------------------------------------------------------------------------------------- index */
  function newLeaf() { return { leaf: true, keys: [], dead: [], next: NIL, state: 'live', stamp: 0, nextDeleted: NIL }; }
  function newInternal() { return { leaf: false, keys: [], children: [] }; }
  function maxKeys(db) { return db.order - 1; }
  function page(db, id) { return db.pages.slots[id]; }

  function lowerBound(keys, key) {
    var lo = 0, hi = keys.length;
    while (lo < hi) { var mid = (lo + hi) >> 1; if (keys[mid] < key) lo = mid + 1; else hi = mid; }
    return lo;
  }
  function childIndex(keys, key) {       // number of separators <= key: equal goes right
    var lo = 0, hi = keys.length;
    while (lo < hi) { var mid = (lo + hi) >> 1; if (keys[mid] <= key) lo = mid + 1; else hi = mid; }
    return lo;
  }
  function findLeaf(db, ik) {
    var id = db.root;
    if (id === NIL) return NIL;
    while (!page(db, id).leaf) id = page(db, id).children[childIndex(page(db, id).keys, ik)];
    return id;
  }

  function allocPage(db, p) {
    var before = db.pages.slots.length;
    var id = alloc(db.pages, p);
    if (db.pages.slots.length === before) db.stats.reused++;
    return id;
  }

  /** Removes the hinted ('hinted') or dead-to-all ('dead') entries of a leaf and frees their versions. */
  function removeWhere(db, id, what) {
    var n = page(db, id), removed = 0;
    for (var i = n.keys.length - 1; i >= 0; i--) {
      var tid = tidOf(n.keys[i]);
      var garbage = what === 'hinted' ? n.dead[i] : deadToAll(db, tid);
      if (!garbage) continue;
      n.keys.splice(i, 1);
      n.dead.splice(i, 1);
      release(db.versions, tid);          // entry first, version second
      removed++;
    }
    db.count -= removed;
    return removed;
  }

  function makeRoom(db, id, emit) {
    var n = page(db, id);
    emit('full', { page: id });
    var removed = removeWhere(db, id, 'hinted');
    db.stats.simple += removed;
    if (removed) emit('simple', { page: id, removed: removed });
    if (n.keys.length === maxKeys(db) && db.bottomUp) {
      removed = removeWhere(db, id, 'dead');
      db.stats.bottomUp += removed;
      if (removed) emit('bottom-up', { page: id, removed: removed });
    }
    if (n.keys.length < maxKeys(db)) db.stats.splitsAvoided++;
  }

  function splitLeaf(db, leftId, emit) {
    var reusedBefore = db.stats.reused;
    var rightId = allocPage(db, newLeaf());
    var left = page(db, leftId), right = page(db, rightId);
    var mid = left.keys.length >> 1;
    right.keys = left.keys.splice(mid);
    right.dead = left.dead.splice(mid);
    right.next = left.next;
    left.next = rightId;
    db.stats.leafSplits++;
    emit('split', { page: leftId, right: rightId, reused: db.stats.reused > reusedBefore });
    return { separator: right.keys[0], right: rightId };
  }

  function splitInternal(db, leftId) {
    var rightId = allocPage(db, newInternal());
    var left = page(db, leftId), right = page(db, rightId);
    var mid = left.keys.length >> 1;
    var separator = left.keys[mid];
    right.keys = left.keys.splice(mid + 1);
    left.keys.pop();
    right.children = left.children.splice(mid + 1);
    db.stats.internalSplits++;
    return { separator: separator, right: rightId };
  }

  function insertInto(db, id, ik, emit) {
    var n = page(db, id);
    if (n.leaf) {
      if (n.keys.length === maxKeys(db)) makeRoom(db, id, emit);
      var i = lowerBound(n.keys, ik);
      n.keys.splice(i, 0, ik);
      n.dead.splice(i, 0, false);
      db.count++;
      emit('insert', { page: id, ik: ik });
      return n.keys.length <= maxKeys(db) ? null : splitLeaf(db, id, emit);
    }
    var c = childIndex(n.keys, ik);
    var s = insertInto(db, n.children[c], ik, emit);
    if (!s) return null;
    n.keys.splice(c, 0, s.separator);
    n.children.splice(c + 1, 0, s.right);
    return n.keys.length <= maxKeys(db) ? null : splitInternal(db, id);
  }

  function insertEntry(db, ik, emit) {
    if (db.root === NIL) {
      db.root = alloc(db.pages, newLeaf());
      db.first = db.root;
      db.height = 1;
    }
    var s = insertInto(db, db.root, ik, emit);
    if (s) {
      var root = newInternal();
      root.keys = [s.separator];
      root.children = [db.root, s.right];
      db.root = allocPage(db, root);
      db.height++;
    }
  }

  /* ----------------------------------------------------------------------------- page deletion */
  function findDownlink(db, id, depth, target) {
    var n = page(db, id);
    if (n.leaf) return null;
    for (var slot = 0; slot < n.children.length; slot++) {
      if (depth + 1 === db.height) {
        if (n.children[slot] === target) return { parent: id, slot: slot };
      } else {
        var found = findDownlink(db, n.children[slot], depth + 1, target);
        if (found) return found;
      }
    }
    return null;
  }

  /** Phase 1. Returns null when done, else the reason for refusing (a string for the caption). */
  function markHalfDead(db, id) {
    if (!isLive(db.pages, id)) return 'it is not a page';
    if (id === db.root) return 'it is the root';
    var leaf = page(db, id);
    if (!leaf.leaf || leaf.state !== 'live') return 'it is not a live leaf';
    if (leaf.keys.length !== 0) return 'it is not empty';
    var link = findDownlink(db, db.root, 1, id);
    if (!link) return 'it has no downlink';
    var parent = page(db, link.parent);
    if (link.slot === parent.keys.length) return 'it is the rightmost child of its parent';
    parent.children[link.slot] = parent.children[link.slot + 1];
    parent.keys.splice(link.slot, 1);
    parent.children.splice(link.slot + 1, 1);
    leaf.state = 'half-dead';
    db.stats.halfDead++;
    return null;
  }

  function leftSibling(db, id) {
    var left = NIL;
    for (var cur = db.first; cur !== id; cur = page(db, cur).next) left = cur;
    return left;
  }

  /** Phase 2: out of the chain, stamped with a fresh epoch, own right link kept. */
  function unlinkHalfDead(db, left, id) {
    var leaf = page(db, id);
    if (left === NIL) db.first = leaf.next; else page(db, left).next = leaf.next;
    leaf.state = 'deleted';
    leaf.stamp = tick(db);
    leaf.nextDeleted = NIL;
    if (db.delTail === NIL) db.delHead = id; else page(db, db.delTail).nextDeleted = id;
    db.delTail = id;
    db.stats.unlinked++;
  }

  /** Step 3: free the deleted pages whose stamp the horizon has reached. Returns their ids. */
  function recycle(db, limit) {
    var freed = [];
    while (db.delHead !== NIL && page(db, db.delHead).stamp <= limit) {
      var id = db.delHead;
      db.delHead = page(db, id).nextDeleted;
      if (db.delHead === NIL) db.delTail = NIL;
      release(db.pages, id);
      freed.push(id);
    }
    db.stats.recycled += freed.length;
    return freed;
  }
  function deletedQueue(db) {
    var out = [];
    for (var id = db.delHead; id !== NIL; id = page(db, id).nextDeleted) out.push(id);
    return out;
  }
  /** The chain as the right links give it, half-dead pages included. */
  function chain(db) {
    var out = [];
    for (var id = db.first; id !== NIL; id = page(db, id).next) out.push(id);
    return out;
  }

  /* ---------------------------------------------------------------------------------------- db */
  function current(db, key) {
    for (var id = findLeaf(db, pack(key, 0)); id !== NIL; id = page(db, id).next) {
      var n = page(db, id);
      if (n.state !== 'live') continue;
      for (var i = 0; i < n.keys.length; i++) {
        var k = userKey(n.keys[i]);
        if (k < key) continue;
        if (k > key) return NIL;
        if (db.versions.slots[tidOf(n.keys[i])].xmax === 0) return tidOf(n.keys[i]);
      }
    }
    return NIL;
  }

  function noop() {}

  /** Insert or update. Returns {xid, old} where old is the replaced value or null. */
  function put(db, key, value, emit) {
    var xid = tick(db), old = null;
    var cur = current(db, key);
    if (cur !== NIL) { db.versions.slots[cur].xmax = xid; old = db.versions.slots[cur].value; }
    var tid = alloc(db.versions, { key: key, value: value, xmin: xid, xmax: 0 });
    insertEntry(db, pack(key, tid), emit || noop);
    return { xid: xid, old: old, tid: tid };
  }

  /** Returns {xid, old} or null when the key has no current version. */
  function del(db, key) {
    var cur = current(db, key);
    if (cur === NIL) return null;
    var v = db.versions.slots[cur];
    v.xmax = tick(db);
    return { xid: v.xmax, old: v.value, tid: cur };
  }

  /** A paused forward scan: plain data, like the Cursor of the programs. */
  function seek(db, snapshot, lo, hi) {
    return { snapshot: snapshot, lo: pack(lo, 0), hi: hi, next: findLeaf(db, pack(lo, 0)), out: [], done: false, error: null };
  }

  /**
   * Reads the next live page into cursor.out. Returns
   *   {status: 'page', page, rows, hinted, skipped}   a page was read
   *   {status: 'end', skipped}                        the chain ended
   *   {status: 'dangling', page}                      the saved link names a recycled page
   */
  function readPage(db, c) {
    var id = c.next, skipped = [];
    for (;;) {
      if (id === NIL) { c.next = NIL; c.done = true; return { status: 'end', skipped: skipped }; }
      if (!isLive(db.pages, id) || !page(db, id).leaf) { c.error = 'DanglingLink'; c.done = true; return { status: 'dangling', page: id, skipped: skipped }; }
      if (page(db, id).state === 'live') break;
      db.reads.movedRight++;
      skipped.push(id);
      id = page(db, id).next;
    }
    var n = page(db, id), rows = [], hinted = [];
    for (var i = 0; i < n.keys.length; i++) {
      var ik = n.keys[i];
      if (ik < c.lo) continue;
      if (userKey(ik) >= c.hi) { c.next = NIL; c.out = c.out.concat(rows); return { status: 'page', page: id, rows: rows, hinted: hinted, skipped: skipped }; }
      if (n.dead[i]) { db.reads.hintSkips++; continue; }
      var v = db.versions.slots[tidOf(ik)];
      db.reads.heapFetches++;
      if (visible(v, c.snapshot)) rows.push({ key: v.key, value: v.value });
      else if (deadToAll(db, tidOf(ik))) { n.dead[i] = true; db.reads.hintsSet++; hinted.push(ik); }
    }
    c.next = n.next;
    c.out = c.out.concat(rows);
    return { status: 'page', page: id, rows: rows, hinted: hinted, skipped: skipped };
  }

  /** Runs a scan to the end. Returns the keys it produced (stops at a dangling link). */
  function scanAll(db, c) {
    while (!c.done) readPage(db, c);
    return c.out.map(function (r) { return r.key; });
  }

  function vacuum(db, options, emit) {
    emit = emit || noop;
    var deletePages = !options || options.deletePages !== false;
    var report = { horizon: horizon(db), removed: 0, unlinked: 0, recycled: 0, waiting: 0 };
    var left = NIL, id = db.first;
    while (id !== NIL) {
      var n = page(db, id), next = n.next;
      if (n.state === 'live') {
        var removed = removeWhere(db, id, 'dead');
        db.stats.vacuum += removed;
        report.removed += removed;
        emit('sweep', { page: id, removed: removed });
        if (n.keys.length === 0 && deletePages) {
          var refused = markHalfDead(db, id);
          emit(refused ? 'keep' : 'half-dead', { page: id, reason: refused });
        }
      }
      if (n.state === 'half-dead' && deletePages) {
        unlinkHalfDead(db, left, id);
        report.unlinked++;
        emit('unlink', { page: id, stamp: n.stamp, next: n.next });
      } else {
        left = id;
      }
      id = next;
    }
    var freed = recycle(db, horizon(db));
    report.recycled = freed.length;
    report.waiting = deletedQueue(db).length;
    emit('recycle', { freed: freed, waiting: deletedQueue(db), horizon: horizon(db) });
    return report;
  }

  /* -------------------------------------------------------------------------------------- dump */
  /** The same text as dump.zig / dump.rs, so the page can be checked against the programs. */
  function entryText(db, n, i) {
    var v = db.versions.slots[tidOf(n.keys[i])];
    return v.key + ':' + v.xmin + '-' + (v.xmax !== 0 ? v.xmax : '') + (n.dead[i] ? '!' : '');
  }
  function nodeText(db, id) {
    var n = page(db, id);
    if (!n.leaf) return '#' + id + '[' + n.keys.map(function (k) { return userKey(k) + '.' + tidOf(k); }).join(' ') + ']';
    if (n.state === 'half-dead') return '#' + id + '(half-dead)';
    return '#' + id + '(' + n.keys.map(function (_, i) { return entryText(db, n, i); }).join(' ') + ')';
  }
  function dump(db) {
    var out = 'now=' + db.now + ' horizon=' + horizon(db) + ' | height ' + db.height + ', ' + db.count + ' entries, ' + db.pages.live + ' pages\n';
    if (db.root === NIL) return out;
    function level(id, down) {
      if (down === 0) return ' ' + nodeText(db, id);
      return page(db, id).children.map(function (c) { return level(c, down - 1); }).join('');
    }
    for (var depth = 1; depth < db.height; depth++) out += '  level ' + (depth - 1) + ':' + level(db.root, depth - 1) + '\n';
    out += '  leaves : ' + chain(db).map(function (id) { return nodeText(db, id); }).join(' -> ') + '\n';
    var dq = deletedQueue(db);
    if (dq.length) {
      out += '  deleted:' + dq.map(function (id) {
        var p = page(db, id);
        return ' #' + id + '@' + p.stamp + '->' + (p.next === NIL ? 'end' : '#' + p.next);
      }).join('') + '\n';
    }
    var fl = freeList(db.pages);
    if (fl.length) out += '  free   :' + fl.map(function (id) { return ' #' + id; }).join('') + '\n';
    return out;
  }

  /** Light invariant check: [] when fine, else messages. (The programs' validate is the full one.) */
  function validate(db) {
    var errors = [], entries = 0, live = [];
    function walk(id, depth, lo, hi) {
      var n = page(db, id);
      n.keys.forEach(function (k, i) {
        if (i && n.keys[i - 1] >= k) errors.push('keys not sorted in #' + id);
        if ((lo !== null && k < lo) || (hi !== null && k >= hi)) errors.push('key out of bounds in #' + id);
      });
      if (n.leaf) {
        if (depth !== db.height) errors.push('uneven depth at #' + id);
        if (n.state !== 'live') errors.push('dead page #' + id + ' in the tree');
        live.push(id);
        entries += n.keys.length;
        n.keys.forEach(function (k, i) {
          if (!isLive(db.versions, tidOf(k)) || db.versions.slots[tidOf(k)].key !== userKey(k)) errors.push('dangling tid in #' + id);
          else if (n.dead[i] && !deadToAll(db, tidOf(k))) errors.push('lying hint in #' + id);
        });
        return;
      }
      n.children.forEach(function (c, i) {
        walk(c, depth + 1, i === 0 ? lo : n.keys[i - 1], i === n.keys.length ? hi : n.keys[i]);
      });
    }
    if (db.root !== NIL) walk(db.root, 1, null, null);
    var chained = chain(db).filter(function (id) { return page(db, id).state === 'live'; });
    if (chained.join() !== live.join()) errors.push('leaf chain differs from tree order');
    if (entries !== db.count || db.count !== db.versions.live) errors.push('entries and versions are not one-to-one');
    return errors;
  }

  /* ------------------------------------------------------------------------------- the picture */
  /*
   * The toolkit's TreeView draws a tree: every box hangs under a parent. This chapter needs boxes
   * that do NOT: a half-dead leaf (still in the leaf chain, no downlink), a deleted leaf (in
   * neither, but with its own right link) and a free slot. So the chapter draws its own picture,
   * with the toolkit's CSS classes and colour tokens:
   *
   *   internal levels     the tree, edges = downlinks
   *   leaf row            the leaf chain exactly as the right links give it; a half-dead page
   *                       keeps its place between its neighbours and has no edge from above
   *   deleted row         unlinked pages with their stamp; a dashed arrow is the right link each kept
   *   free row            the free list, head first
   *
   * A box is keyed by its page id, so a page visibly travels: leaf row, deleted row, free row, and
   * back into the tree when a split reuses it. layout() is pure; Picture animates between layouts.
   */
  var GEO = { cellH: 28, vGap: 40, hGap: 16, padX: 14, padTop: 28, charW: 7.3, cellPad: 12, minCell: 30, rowGap: 34, minScale: 0.5 };
  var INNER = { 'empty': 46, 'half-dead': 66, 'free': 44 };   // box widths when there are no cells

  function layout(db) {
    var g = GEO, boxes = {}, order = [], edges = [], links = [];
    function box(id, kind, texts, inner) {
      var cw = texts.map(function (t) { return Math.max(g.minCell, Math.round(t.length * g.charW) + g.cellPad); });
      var w = cw.reduce(function (a, b) { return a + b; }, 0) || INNER[inner] || Math.round(inner.length * 6.2) + 14;
      var b = { id: id, kind: kind, texts: texts, cw: cw, w: w, inner: texts.length ? '' : inner, x: 0, y: 0, sw: w, kids: [], real: [] };
      boxes[id] = b;
      order.push(b);
      return b;
    }
    var ch = chain(db);
    var leafY = g.padTop + (Math.max(db.height, 1) - 1) * (g.cellH + g.vGap);
    // A half-dead leaf has no parent, but it has a place: just left of the next live leaf.
    var before = {}, pending = [];
    ch.forEach(function (id) {
      if (page(db, id).state === 'half-dead') pending.push(id);
      else { before[id] = pending; pending = []; }
    });
    function leafBox(id) {
      var n = page(db, id), b;
      if (n.state === 'half-dead') b = box(id, 'half-dead', [], 'half-dead');
      else b = box(id, 'leaf', n.keys.map(function (_, i) { return entryText(db, n, i); }), 'empty');
      b.y = leafY;
      return b;
    }
    function measure(id, depth) {
      var n = page(db, id);
      if (n.leaf) return leafBox(id);
      var b = box(id, 'internal', n.keys.map(function (k) { return userKey(k) + '.' + tidOf(k); }), '');
      b.y = g.padTop + (depth - 1) * (g.cellH + g.vGap);
      n.children.forEach(function (c, slot) {
        (page(db, c).leaf && before[c] || []).forEach(function (h) { b.kids.push(leafBox(h)); });
        var cb = measure(c, depth + 1);
        b.kids.push(cb);
        b.real.push(cb);
        edges.push({ from: id, to: c, slot: slot, slots: n.children.length });
      });
      b.cw2 = b.kids.reduce(function (a, k) { return a + k.sw; }, 0) + g.hGap * (b.kids.length - 1);
      b.sw = Math.max(b.w, b.cw2);
      return b;
    }
    function place(b, left) {
      if (!b.kids.length) { b.x = left + (b.sw - b.w) / 2; return; }
      var cl = left + (b.sw - b.cw2) / 2;
      b.kids.forEach(function (k) { place(k, cl); cl += k.sw + g.hGap; });
      var a = b.real[0], z = b.real[b.real.length - 1];
      b.x = Math.min(Math.max((a.x + a.w / 2 + z.x + z.w / 2) / 2 - b.w / 2, left), left + b.sw - b.w);
    }
    var right = g.padX;
    if (db.root !== NIL) {
      var rootBox = measure(db.root, 1);
      place(rootBox, g.padX);
      right = g.padX + rootBox.sw;
    }
    ch.forEach(function (id) { if (page(db, id).next !== NIL) links.push({ from: id, to: page(db, id).next, kind: 'chain' }); });

    // Deleted pages: below the chain, just left of the page their kept right link leads to.
    var ghostY = leafY + g.cellH + g.rowGap, freeY = ghostY + g.cellH + g.rowGap;
    var ghosts = deletedQueue(db).map(function (id) {
      var p = page(db, id), hops = 0, t = p.next;
      while (t !== NIL && isLive(db.pages, t) && page(db, t).leaf && page(db, t).state === 'deleted') { t = page(db, t).next; hops++; }
      var b = box(id, 'deleted', [], 'stamp ' + p.stamp);
      b.y = ghostY;
      b.anchor = t !== NIL && boxes[t] && boxes[t].y === leafY ? boxes[t].x : right + g.hGap + b.w;
      b.hops = hops;
      links.push({ from: id, to: p.next, kind: 'kept' });
      return b;
    });
    ghosts.sort(function (a, b) { return a.anchor - b.anchor || b.hops - a.hops; });
    var limit = Infinity, minX = g.padX;
    for (var i = ghosts.length - 1; i >= 0; i--) {
      ghosts[i].x = Math.min(ghosts[i].anchor - 6, limit) - ghosts[i].w;
      limit = ghosts[i].x - g.hGap;
      minX = Math.min(minX, ghosts[i].x);
    }
    if (minX < g.padX) order.forEach(function (b) { b.x += g.padX - minX; });
    var x = g.padX;
    freeList(db.pages).forEach(function (id) {
      var b = box(id, 'free', [], 'free');
      b.x = x; b.y = freeY;
      x += b.w + 10;
    });
    // Each lower row is named by a line of text to the right of its last box.
    var titles = [
      { y: ghostY, x: g.padX, text: ghosts.length ? '← deleted: unlinked and stamped, right link kept; waiting for the horizon' : 'deleted pages: none' },
      { y: freeY, x: x > g.padX ? x + 4 : g.padX, text: x > g.padX ? '← free list: the next split takes the leftmost' : 'free list: empty' }
    ];
    var W = 0;
    order.forEach(function (b) {
      W = Math.max(W, b.x + b.w + g.padX);
      if (b.kind === 'deleted') titles[0].x = Math.max(titles[0].x, b.x + b.w + 46);    // past the hook of its arrow
    });
    titles.forEach(function (t) { W = Math.max(W, t.x + t.text.length * 5.5 + g.padX); });
    return { boxes: boxes, order: order, edges: edges, links: links, titles: titles, leafY: leafY, ghostY: ghostY, freeY: freeY,
             W: Math.ceil(W), H: freeY + g.cellH + 10 };
  }

  var SVG_NS = 'http://www.w3.org/2000/svg';
  function sv(tag, attrs) {
    var e = document.createElementNS(SVG_NS, tag);
    for (var a in (attrs || {})) e.setAttribute(a, attrs[a]);
    for (var i = 2; i < arguments.length; i++) e.appendChild(typeof arguments[i] === 'string' ? document.createTextNode(arguments[i]) : arguments[i]);
    return e;
  }
  var picUid = 0;

  /** new Ch24.Picture(target).render(db, {pages: {id: state}, keys: {'p3:20:2-4': state}, scan: {page, stale}}, duration) */
  function Picture(target) {
    var self = this;
    this.uid = 'c24p' + (++picUid);
    this.cur = {};                         // page id -> {x, y, o}: where each box is drawn right now
    this.els = {};
    this.gEdges = sv('g'); this.gLinks = sv('g'); this.gTitles = sv('g'); this.gNodes = sv('g'); this.gOver = sv('g');
    function marker(id, cls) {
      return sv('marker', { id: self.uid + id, viewBox: '0 0 8 8', refX: 7, refY: 4, markerWidth: 7, markerHeight: 7, orient: 'auto' },
        sv('path', { d: 'M0 .8L7.2 4L0 7.2z', 'class': cls }));
    }
    this.svg = sv('svg', { 'class': 'c24-svg', role: 'img' }, sv('defs', {}, marker('a', 'bt-arrowhead'), marker('k', 'c24-arrow-kept')),
      this.gEdges, this.gLinks, this.gTitles, this.gNodes, this.gOver);
    this.root = document.createElement('div');
    this.root.className = 'c24-pic';
    this.root.tabIndex = 0;
    this.root.setAttribute('role', 'group');
    this.root.setAttribute('aria-label', 'The index, the deleted pages and the free list (scrollable)');
    this.root.appendChild(this.svg);
    target.appendChild(this.root);
    this.W = 430; this.H = 200;
    if (typeof ResizeObserver !== 'undefined') new ResizeObserver(function () { self._fit(); }).observe(this.root);
  }
  /** The whole picture is scaled to fit the width; below GEO.minScale it scrolls instead. */
  Picture.prototype._fit = function () {
    var avail = this.root.clientWidth || this.W;
    this.scale = Math.min(1, Math.max(GEO.minScale, avail / this.W));
    this.svg.setAttribute('viewBox', '0 0 ' + this.W + ' ' + this.H);
    this.svg.setAttribute('width', Math.floor(this.W * this.scale));
    this.svg.setAttribute('height', Math.floor(this.H * this.scale));
  };

  Picture.prototype.render = function (db, hl, duration) {
    hl = hl || {};
    var self = this, g = GEO, L = layout(db), pages = hl.pages || {}, keys = hl.keys || {};
    this.L = L;
    this.W = L.W; this.H = L.H;
    this._fit();

    // --- boxes: one <g> per page id, content rebuilt, position animated
    var seen = {};
    L.order.forEach(function (b) {
      seen[b.id] = true;
      var it = self.els[b.id];
      if (!it) {
        it = self.els[b.id] = { g: sv('g') };
        self.gNodes.appendChild(it.g);
      }
      var state = pages[b.id] || (b.kind === 'half-dead' ? 'merge' : b.kind === 'deleted' ? 'deleted' : b.kind === 'free' ? 'free' : '');
      it.g.setAttribute('class', 'bt-node c24-page is-' + b.kind + (state ? ' s-' + state : ''));
      it.g.setAttribute('data-page', b.id);
      it.g.setAttribute('data-kind', b.kind);
      it.g.textContent = '';
      it.g.appendChild(sv('rect', { 'class': 'bt-node-box', rx: 7, ry: 7, width: b.w, height: g.cellH }));
      it.g.appendChild(sv('text', { 'class': 'bt-node-label', x: 1, y: -5 }, '#' + b.id));
      if (b.inner) it.g.appendChild(sv('text', { 'class': 'c24-inner', x: b.w / 2, y: g.cellH / 2 }, b.inner));
      var cx = 0;
      b.texts.forEach(function (t, i) {
        var st = keys['p' + b.id + ':' + t];
        it.g.appendChild(sv('g', { 'class': 'bt-key' + (st ? ' s-' + st : ''), transform: 'translate(' + cx + ',0)' },
          sv('rect', { x: 2, y: 2, rx: 5, ry: 5, width: b.cw[i] - 4, height: g.cellH - 4 }),
          sv('text', { x: b.cw[i] / 2, y: g.cellH / 2 + 0.5 }, t)));
        cx += b.cw[i];
      });
      it.from = self.cur[b.id] || { x: b.x, y: b.y, o: 0 };
      it.to = { x: b.x, y: b.y, o: 1 };
    });
    Object.keys(this.els).forEach(function (id) {
      if (seen[id]) return;
      self.gNodes.removeChild(self.els[id].g);
      delete self.els[id];
      delete self.cur[id];
    });

    // --- arrows and row titles are rebuilt; their geometry follows the boxes frame by frame
    this.gEdges.textContent = ''; this.gLinks.textContent = ''; this.gTitles.textContent = ''; this.gOver.textContent = '';
    var paths = [];
    L.edges.forEach(function (e) {
      var path = sv('path', { 'class': 'bt-edge' }), dot = sv('circle', { 'class': 'bt-edge-dot', r: 2.3 });
      self.gEdges.appendChild(path); self.gEdges.appendChild(dot);
      var p = L.boxes[e.from], acc = 0;
      for (var i = 0; i < e.slot; i++) acc += p.cw[i] || 0;
      var ax = e.slot === 0 ? Math.min(7, p.w / 2) : e.slot === e.slots - 1 ? p.w - Math.min(7, p.w / 2) : acc;
      paths.push(function (at) {
        var a = at(e.from), c = at(e.to), sx = a.x + ax, sy = a.y + g.cellH, ex = c.x + L.boxes[e.to].w / 2, ey = c.y, dy = (ey - sy) / 2;
        path.setAttribute('d', 'M' + sx + ' ' + sy + 'C' + sx + ' ' + (sy + dy) + ' ' + ex + ' ' + (ey - dy) + ' ' + ex + ' ' + ey);
        dot.setAttribute('cx', sx); dot.setAttribute('cy', sy);
        path.style.opacity = dot.style.opacity = Math.min(a.o, c.o);
      });
    });
    L.links.forEach(function (l) {
      var kept = l.kind === 'kept';
      var path = sv('path', { 'class': kept ? 'c24-kept' : 'bt-link', 'marker-end': 'url(#' + self.uid + (kept ? 'k' : 'a') + ')', 'data-link': l.from + '>' + l.to });
      self.gLinks.appendChild(path);
      var label = null;
      if (kept && !L.boxes[l.to]) { label = sv('text', { 'class': 'c24-rowtitle' }, l.to === NIL ? 'end' : '#' + l.to + '?'); self.gLinks.appendChild(label); }
      paths.push(function (at) {
        var a = at(l.from), sx = a.x + L.boxes[l.from].w, sy = a.y + g.cellH / 2, t = L.boxes[l.to] ? at(l.to) : null, d;
        if (!t) {                                         // the link leads nowhere drawable: the end of the chain
          d = 'M' + sx + ' ' + sy + 'H' + (sx + 14);
          label.setAttribute('x', sx + 18); label.setAttribute('y', sy + 3.5);
        } else if (Math.abs(t.y - a.y) < 1) {
          d = 'M' + sx + ' ' + sy + 'H' + (t.x - 1.5);
        } else {                                          // from the deleted row up into the chain
          var ex = t.x + Math.min(12, L.boxes[l.to].w / 2), ey = t.y + g.cellH + 2.5;
          d = 'M' + sx + ' ' + sy + 'C' + ex + ' ' + sy + ' ' + ex + ' ' + sy + ' ' + ex + ' ' + ey;
        }
        path.setAttribute('d', d);
        path.style.opacity = Math.min(a.o, t ? t.o : 1);
      });
    });
    L.titles.forEach(function (t) { self.gTitles.appendChild(sv('text', { 'class': 'c24-rowtitle', x: t.x, y: t.y + g.cellH / 2 + 3.5 }, t.text)); });
    if (db.root === NIL) this.gTitles.appendChild(sv('text', { 'class': 'c24-inner', x: L.W / 2, y: g.padTop + g.cellH / 2 }, 'the index is empty'));

    // --- the paused scan's saved handle: a pill over whatever box that id names today
    var scan = hl.scan && L.boxes[hl.scan.page] ? hl.scan : null;
    if (scan) {
      var text = scan.stale ? 'scan ✗' : 'scan', pw = Math.round(text.length * 5.6) + 22;
      var pill = sv('g', { 'class': 'c24-pill' + (scan.stale ? ' is-stale' : ''), 'data-scan': scan.page },
        sv('rect', { x: 0, y: -8, width: pw, height: 16, rx: 8, ry: 8 }), sv('path', { d: 'M6 7.5h8l-4 5z' }), sv('text', { x: pw / 2, y: 0.5 }, text),
        sv('title', {}, scan.stale ? 'the page handle the paused scan saved; the page behind it is no longer the one it meant' : 'the page handle the paused scan saved: it reads this page next'));
      this.gOver.appendChild(pill);
      paths.push(function (at) {
        var a = at(scan.page);
        pill.setAttribute('transform', 'translate(' + (a.x + 22) + ',' + (a.y - 13) + ')');
      });
    }
    this.svg.setAttribute('aria-label', describe(db));

    // --- animate
    if (this._raf) cancelAnimationFrame(this._raf);
    var t0 = null;
    function frame(now) {
      if (t0 === null) t0 = now;
      var t = duration > 0 ? Math.min(1, (now - t0) / duration) : 1, e = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
      L.order.forEach(function (b) {
        var it = self.els[b.id], c = self.cur[b.id] = { x: it.from.x + (it.to.x - it.from.x) * e, y: it.from.y + (it.to.y - it.from.y) * e, o: it.from.o + (it.to.o - it.from.o) * e };
        it.g.setAttribute('transform', 'translate(' + c.x.toFixed(2) + ',' + c.y.toFixed(2) + ')');
        it.g.style.opacity = c.o >= 1 ? '' : c.o.toFixed(3);
      });
      paths.forEach(function (fn) { fn(function (id) { return self.cur[id]; }); });
      self._raf = t < 1 ? requestAnimationFrame(frame) : 0;
    }
    if (duration > 0 && typeof requestAnimationFrame === 'function') { frame(performance.now()); } else { duration = 0; frame(0); }
    this._reveal(Object.keys(pages).concat(scan ? [scan.page] : []), duration);
    return this;
  };

  /** On a narrow screen: scroll sideways so that the boxes this step is about are in view. */
  Picture.prototype._reveal = function (ids, duration) {
    var sc = this.root, L = this.L, lo = Infinity, hi = -Infinity, s = this.scale;
    if (sc.scrollWidth <= sc.clientWidth + 1) return;
    ids.forEach(function (id) { var b = L.boxes[id]; if (b) { lo = Math.min(lo, b.x); hi = Math.max(hi, b.x + b.w); } });
    if (lo === Infinity) return;
    lo = lo * s - 20; hi = hi * s + 20;
    var left = sc.scrollLeft, target = left;
    if (hi - lo > sc.clientWidth || lo < left) target = lo;
    else if (hi > left + sc.clientWidth) target = hi - sc.clientWidth;
    if (target !== left) sc.scrollTo({ left: target, behavior: duration > 0 ? 'smooth' : 'auto' });
  };

  /** The picture in words (aria-label of the drawing; also what the page's tests read). */
  function describe(db) {
    var ch = chain(db).map(function (id) { return '#' + id + (page(db, id).state === 'half-dead' ? ' half-dead' : ''); });
    var dq = deletedQueue(db).map(function (id) { var p = page(db, id); return '#' + id + ' stamp ' + p.stamp + ' right link ' + (p.next === NIL ? 'end' : '#' + p.next); });
    var fl = freeList(db.pages).map(function (id) { return '#' + id; });
    return 'Leaf chain: ' + (ch.join(' → ') || 'empty') + '. Deleted, waiting: ' + (dq.join(', ') || 'none') + '. Free list: ' + (fl.join(' ') || 'empty') + '.';
  }

  window.Ch24 = {
    NIL: NIL, create: create, pack: pack, userKey: userKey, tidOf: tidOf,
    openSnapshot: openSnapshot, closeSnapshot: closeSnapshot, horizon: horizon, visible: visible, deadToAll: deadToAll,
    put: put, del: del, seek: seek, readPage: readPage, scanAll: scanAll, vacuum: vacuum,
    markHalfDead: markHalfDead, unlinkHalfDead: unlinkHalfDead, leftSibling: leftSibling, recycle: recycle,
    chain: chain, deletedQueue: deletedQueue, freeList: freeList, isLive: isLive, page: page,
    entryText: entryText, dump: dump, validate: validate,
    layout: layout, describe: describe, Picture: Picture
  };
})();

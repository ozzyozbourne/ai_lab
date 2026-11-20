/*
 * Chapter 24, chapter-local model: a JavaScript port of the chapter's Zig / Rust programs
 * (store, index, db, dump). The whole database is ONE plain object, so a step of the timeline can
 * hold a deep copy of it and the page can continue from whatever step is on screen.
 *
 * Every mutating function takes an optional `emit(type, info)` callback and calls it right after
 * each change worth showing; the page turns those calls into steps.
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

  window.Ch24 = {
    NIL: NIL, create: create, pack: pack, userKey: userKey, tidOf: tidOf,
    openSnapshot: openSnapshot, closeSnapshot: closeSnapshot, horizon: horizon, visible: visible, deadToAll: deadToAll,
    put: put, del: del, seek: seek, readPage: readPage, scanAll: scanAll, vacuum: vacuum,
    markHalfDead: markHalfDead, unlinkHalfDead: unlinkHalfDead, leftSibling: leftSibling, recycle: recycle,
    chain: chain, deletedQueue: deletedQueue, freeList: freeList, isLive: isLive, page: page,
    entryText: entryText, dump: dump, validate: validate
  };
})();

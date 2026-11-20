/*
 * Chapter 18 — chapter-local model: the table engine of zig/src/table.zig in
 * JavaScript, emitting BTViz steps.
 *
 * Why a local model? The page needs two cooperating structures per layout (an
 * index tree plus either a primary tree or a heap) and the exact cost counters
 * of the chapter's programs. The B+tree below is an insert-only port of the
 * chapter 07 tree the programs use (same split points, so the same shapes);
 * the self-tests in index.html compare its leaves and its counters with
 * expected_output.txt.
 *
 * Differences from the programs, all stated on the page: no `code` column and
 * no delete; customer and day are limited to 0..99 and ids to 1..999 so that
 * a composite key fits a JavaScript number:
 *     by_customer_day key = (customer * 100 + day) * 1000 + locator
 *     heap primary key    = id * 1000 + TID
 * Both orderings equal the programs' (column by column, locator last).
 *
 * Pure data, no DOM: also runs under node.
 */
(function (root) {
  'use strict';

  var NIL = -1, LOC = 1000, SLOTS = 4;

  function lowerBound(keys, key) {            // first i with keys[i] >= key
    var lo = 0, hi = keys.length;
    while (lo < hi) { var mid = lo + ((hi - lo) >> 1); if (keys[mid] < key) lo = mid + 1; else hi = mid; }
    return lo;
  }
  function upperBound(keys, key) {            // first i with keys[i] > key
    var lo = 0, hi = keys.length;
    while (lo < hi) { var mid = lo + ((hi - lo) >> 1); if (keys[mid] <= key) lo = mid + 1; else hi = mid; }
    return lo;
  }

  /* ------------------------------------------------- B+tree (insert only) */

  function Tree(order, prefix) {
    this.order = order; this.prefix = prefix;
    this.nodes = []; this.root = NIL; this.first = NIL; this.height = 0; this.count = 0;
  }
  var T = Tree.prototype;
  T.id = function (h) { return this.prefix + h; };
  T._new = function (leaf) {
    this.nodes.push(leaf ? { leaf: true, keys: [], vals: [], next: NIL } : { leaf: false, keys: [], children: [] });
    return this.nodes.length - 1;
  };
  T.put = function (key, val) {
    if (this.root === NIL) { this.root = this.first = this._new(true); this.height = 1; }
    var s = this._insert(this.root, key, val);
    if (s) {                                   // the root split: one more level
      var r = this._new(false);
      this.nodes[r].keys = [s.sep]; this.nodes[r].children = [this.root, s.right];
      this.root = r; this.height++;
    }
    this.count++;
  };
  T._insert = function (h, key, val) {
    var n = this.nodes[h], mid, right, r;
    if (n.leaf) {
      var i = lowerBound(n.keys, key);
      n.keys.splice(i, 0, key); n.vals.splice(i, 0, val);
      if (n.keys.length <= this.order - 1) return null;
      mid = n.keys.length >> 1;               // floor(M/2) stay, the rest move
      right = this._new(true); r = this.nodes[right];
      r.keys = n.keys.splice(mid); r.vals = n.vals.splice(mid);
      r.next = n.next; n.next = right;
      return { sep: r.keys[0], right: right };              // copy-up
    }
    var ci = upperBound(n.keys, key);
    var s = this._insert(n.children[ci], key, val);
    if (!s) return null;
    n.keys.splice(ci, 0, s.sep); n.children.splice(ci + 1, 0, s.right);
    if (n.keys.length <= this.order - 1) return null;
    mid = n.keys.length >> 1;
    var sep = n.keys[mid];
    right = this._new(false); r = this.nodes[right];
    r.keys = n.keys.splice(mid + 1); r.children = n.children.splice(mid + 1);
    n.keys.pop();                                             // push-up
    return { sep: sep, right: right };
  };
  /** Handles from the root to the leaf whose range contains `key`. */
  T.path = function (key) {
    var out = [], h = this.root;
    while (h !== NIL) {
      out.push(h);
      var n = this.nodes[h];
      if (n.leaf) break;
      h = n.children[upperBound(n.keys, key)];
    }
    return out;
  };
  T.get = function (key) {
    var p = this.path(key); if (!p.length) return undefined;
    var n = this.nodes[p[p.length - 1]], i = lowerBound(n.keys, key);
    return i < n.keys.length && n.keys[i] === key ? n.vals[i] : undefined;
  };
  /** Leaves in chain order, each an array of raw keys. */
  T.leaves = function () {
    var out = [], h = this.first;
    while (h !== NIL) { out.push(this.nodes[h].keys.slice()); h = this.nodes[h].next; }
    return out;
  };
  /** TreeView model; `fmt` turns a raw key into its label. */
  T.snapshot = function (fmt) {
    var self = this;
    if (this.root === NIL) return null;
    return (function copy(h) {
      var n = self.nodes[h];
      var m = { id: self.id(h), keys: n.keys.map(fmt), leaf: n.leaf };
      if (n.leaf) { if (n.next !== NIL) m.next = self.id(n.next); } else m.children = n.children.map(copy);
      return m;
    })(this.root);
  };

  /* ------------------------------------------------------------- the table */

  var LIMITS = { customer: 99, day: 99, id: 999, rows: 40 };

  function tidText(tid) { return '(' + Math.floor(tid / SLOTS) + ',' + (tid % SLOTS + 1) + ')'; }

  /** Table(layout): layout is 'clustered' or 'heap'. Order M = 4 everywhere. */
  function Table(layout) {
    this.layout = layout;
    this.primary = new Tree(4, layout === 'heap' ? 'hp' : 'cp');   // clustered: id -> row; heap: (id, TID)
    this.index = new Tree(4, layout === 'heap' ? 'hi' : 'ci');     // (customer, day, locator)
    this.heap = [];                                                // heap layout only: rows by TID
    this.rows = 0;
  }
  var P = Table.prototype;

  P.locText = function (loc) { return this.layout === 'heap' ? tidText(loc) : '#' + loc; };
  P.indexLabel = function (key) {
    var cd = Math.floor(key / LOC);
    return Math.floor(cd / 100) + '·' + (cd % 100) + '·' + this.locText(key % LOC);
  };
  P.primaryLabel = function (key) {
    return this.layout === 'heap' ? Math.floor(key / LOC) + '·' + tidText(key % LOC) : String(key);
  };
  P.rowAt = function (loc) { return this.layout === 'heap' ? this.heap[loc] : this.primary.get(loc); };
  P.hasId = function (id) {
    if (this.layout === 'clustered') return this.primary.get(id) !== undefined;
    return this.heap.some(function (r) { return r.id === id; });
  };

  /** Silent insert; returns false (and changes nothing) on a duplicate id. */
  P.insert = function (row) {
    if (this.hasId(row.id)) return false;
    var loc = row.id;
    if (this.layout === 'heap') { loc = this.heap.length; this.heap.push(row); this.primary.put(row.id * LOC + loc, 0); }
    else this.primary.put(row.id, row);
    this.index.put((row.customer * 100 + row.day) * LOC + loc, 0);
    this.rows++;
    return true;
  };

  P.snapshot = function () {
    var self = this;
    return {
      layout: this.layout,
      index: this.index.snapshot(function (k) { return self.indexLabel(k); }),
      primary: this.primary.snapshot(function (k) { return self.primaryLabel(k); }),
      heap: this.heap.map(function (r, tid) { return { tid: tid, text: tidText(tid), row: r }; })
    };
  };

  /* ------------------------------------------------------------ recording */

  function zero() { return { descents: 0, nodes: 0, entries: 0, fetches: 0, heapReads: 0 }; }
  function pages(c) { return c.nodes + c.heapReads; }
  function rowText(r) { return 'id ' + r.id + ', customer ' + r.customer + ', day ' + r.day + ', amount ' + r.amount; }
  function k(v, state) { return root.BTViz && root.BTViz.k ? root.BTViz.k(v, state) : String(v); }

  /** A recorder: steps share one table snapshot; counters and results grow. */
  function Rec(table) {
    this.t = table; this.snap = table.snapshot(); this.c = zero(); this.results = []; this.steps = [];
  }
  Rec.prototype.emit = function (caption, hl, log) {
    this.steps.push({
      caption: caption, log: log,
      state: { snap: this.snap, counters: root.BTViz ? root.BTViz.clone(this.c) : JSON.parse(JSON.stringify(this.c)), results: this.results.slice() },
      highlight: hl || {}
    });
  };
  /** Predict mode: asked on the first row fetch of a query. */
  Rec.prototype.ask = function () {
    if (this.c.fetches !== 1) return;
    var clustered = this.t.layout === 'clustered';
    this.steps[this.steps.length - 1].question = {
      prompt: 'The index entry matched and the query needs the whole row. What does this layout do with the locator?',
      choices: ['Search the primary tree for it (another descent)', 'Read the heap page it names (no search)', 'Nothing: the row is inside the index entry'],
      answer: clustered ? 0 : 1,
      explain: clustered ? 'In a clustered table the locator is the row id, a key of the primary tree, whose leaves hold the rows.'
                         : 'In a heap table the locator is a TID, the physical address (page, slot) of the row.'
    };
  };
  Rec.prototype.finish = function (extra) {
    this.steps.counters = this.c; this.steps.results = this.results;
    for (var key in extra || {}) this.steps[key] = extra[key];
    return this.steps;
  };

  function mk(key, value) { var o = {}; o[key] = value; return o; }

  /**
   * One root-to-leaf walk of `tree` (which = 'index' | 'primary'), one step per
   * node. Charges exactly what cursor.zig's chargeDescent charges.
   */
  Rec.prototype.descend = function (tree, which, key, what) {
    var path = tree.path(key), self = this;
    this.c.descents++;
    path.forEach(function (h, depth) {
      var n = tree.nodes[h];
      self.c.nodes++;
      var hl = { nodes: mk(tree.id(h), 'active') };
      if (depth > 0) hl.edges = mk(tree.id(h), 'active');
      var caption = n.leaf
        ? 'Leaf reached after ' + (depth + 1) + ' node' + (depth ? 's' : '') + ' (one descent). Binary search inside it for ' + what + '.'
        : 'Descent, level ' + depth + ': compare ' + what + ' with the separators and take child ' + upperBound(n.keys, key) + '. A separator only routes; entries are in the leaves.';
      self.emit(caption, mk(which, hl));
    });
    return path.length ? path[path.length - 1] : NIL;
  };

  /** The step "back to the row" for one index entry. */
  Rec.prototype.fetch = function (loc, entryHl) {
    var t = this.t, row = t.rowAt(loc);
    this.c.fetches++;
    if (t.layout === 'clustered') {
      var path = t.primary.path(loc), nodes = {}, edges = {};
      path.forEach(function (h, i) { nodes[t.primary.id(h)] = 'active'; if (i) edges[t.primary.id(h)] = 'active'; });
      this.c.descents++; this.c.nodes += path.length;
      this.emit('The locator ' + k('#' + loc, 'pointer') + ' is a <b>key</b>, not an address: to get the row, search the primary tree for id ' + loc +
        '. That is a second descent, ' + path.length + ' more node' + (path.length === 1 ? '' : 's') + '.',
        { index: entryHl, primary: { nodes: nodes, edges: edges, cursor: { node: t.primary.id(path[0]), label: loc } } },
        'row fetch #' + loc + ': descent of the primary tree');
      this.ask();
      this.results.push(row);
      this.emit('Row found in the primary leaf: ' + rowText(row) + '. In a clustered table the leaf <i>is</i> the row storage.',
        { index: entryHl, primary: { nodes: mk(t.primary.id(path[path.length - 1]), 'active'), keys: mk(t.primary.id(path[path.length - 1]) + ':' + loc, 'found') } });
    } else {
      this.c.heapReads++;
      this.results.push(row);
      this.emit('The locator ' + k(tidText(loc), 'pointer') + ' is an <b>address</b>: heap page ' + Math.floor(loc / SLOTS) + ', slot ' + (loc % SLOTS + 1) +
        '. Read that page, no search: ' + rowText(row) + '.',
        { index: entryHl, heap: mk(loc, 'found') }, 'row fetch ' + tidText(loc) + ': one heap page');
      this.ask();
    }
  };

  /**
   * Range scan of a tree in [lo, hi] exactly as cursor.zig does it; calls
   * onEntry(key, highlightOfTheEntry) for each key in range. With `limit` the
   * scan stops after that many entries (a probe of a unique index: limit 1).
   */
  Rec.prototype.scan = function (tree, which, lo, hi, what, label, onEntry, limit) {
    var h = this.descend(tree, which, lo, what), found = 0;
    var i = h === NIL ? 0 : lowerBound(tree.nodes[h].keys, lo);
    while (h !== NIL) {
      var n = tree.nodes[h];
      if (i < n.keys.length) {
        var key = n.keys[i], keyHl = mk(which, { nodes: mk(tree.id(h), 'active'), keys: mk(tree.id(h) + ':' + label(key), 'found') });
        if (key > hi) {
          this.emit('Next entry ' + k(label(key), 'compare') + ' is past the end of the range. Keys only grow from here, so the scan stops.',
            mk(which, { nodes: mk(tree.id(h), 'active'), keys: mk(tree.id(h) + ':' + label(key), 'compare') }));
          return found;
        }
        i++; found++; this.c.entries++;
        onEntry(key, keyHl[which]);
        if (found === limit) return found;
      } else {
        var from = h;
        h = n.next; i = 0;
        if (h !== NIL) {
          this.c.nodes++;
          this.emit('End of this leaf. Follow its <b>next</b> link to the sibling leaf: one more node, but no new descent.',
            mk(which, { nodes: mk(tree.id(h), 'active'), links: mk(tree.id(from), 'active') }));
        }
      }
    }
    this.emit('The leaf chain ends here: nothing more to scan.', {});
    return found;
  };

  Rec.prototype.summary = function () {
    var c = this.c;
    return c.descents + ' descent' + (c.descents === 1 ? '' : 's') + ', ' + c.nodes + ' tree nodes, ' + c.fetches + ' row fetch' + (c.fetches === 1 ? '' : 'es') +
      ', ' + c.heapReads + ' heap read' + (c.heapReads === 1 ? '' : 's') + ' = <b>' + pages(c) + ' page reads</b>';
  };

  /* --------------------------------------------------------------- queries */

  /**
   * WHERE customer = c [AND day BETWEEN dlo AND dhi].
   * mode 'fetch' = SELECT * (go back to the row); 'covering' = SELECT day.
   */
  P.queryCustomer = function (customer, dlo, dhi, mode) {
    var r = new Rec(this), t = this, name = t.layout === 'heap' ? 'heap + index' : 'clustered';
    var lo = (customer * 100 + dlo) * LOC, hi = (customer * 100 + dhi) * LOC + (LOC - 1);
    var where = 'customer = ' + customer + (dlo === 0 && dhi === LIMITS.day ? '' : dlo === dhi ? ' AND day = ' + dlo : ' AND day BETWEEN ' + dlo + ' AND ' + dhi);
    var what = 'the smallest possible key of the range, (' + customer + ', ' + dlo + ', any locator)';
    r.emit((mode === 'fetch' ? 'SELECT * ' : 'SELECT day ') + 'WHERE ' + where + ', ' + name + ' layout. The index is sorted by customer, then day, then locator, ' +
      'so the matching entries form one contiguous run. Seek its start.', {}, 'WHERE ' + where);
    var n = r.scan(t.index, 'index', lo, hi, what, function (key) { return t.indexLabel(key); }, function (key, hl) {
      var label = t.indexLabel(key), day = Math.floor(key / LOC) % 100;
      if (mode === 'fetch') {
        r.emit('Entry ' + k(label, 'found') + ' is in the range. The query wants the whole row, and the entry only holds customer, day and a locator: go and get the row.', { index: hl });
        r.fetch(key % LOC, hl);
      } else {
        r.results.push({ day: day, loc: t.locText(key % LOC) });
        r.emit('Entry ' + k(label, 'found') + ' is in the range, and the answer (day ' + day + ') is <b>inside the key</b>. Nothing to fetch: the scan never leaves the index.',
          { index: hl }, 'day ' + day + ' read from the index');
      }
    });
    r.emit('Done: ' + n + ' row' + (n === 1 ? '' : 's') + '. Cost: ' + r.summary() + '.' +
      (mode === 'fetch' && n > 0 ? (t.layout === 'clustered'
        ? ' Every row cost a full descent of the primary tree.' : ' Every row cost one heap page, however tall the trees are.') : ''), {}, 'done: ' + pages(r.c) + ' page reads');
    return r.finish({ found: n, what: (mode === 'fetch' ? 'SELECT * ' : 'SELECT day ') + 'WHERE ' + where });
  };

  /**
   * SELECT count(*) WHERE day = ?   The programs' countOnDay: `day` is the
   * second column and the first is free, so the matches are not one run of
   * the index. The whole leaf chain is read; no row is fetched.
   */
  P.queryDay = function (day) {
    var r = new Rec(this), t = this, name = t.layout === 'heap' ? 'heap + index' : 'clustered', count = 0;
    r.emit('SELECT count(*) WHERE day = ' + day + ', ' + name + ' layout. The index is sorted by customer <b>first</b>, and the query does not say which customer. ' +
      'Entries with day ' + day + ' can follow any customer, so they are scattered: there is no single place to seek to. Start at the smallest key and read everything.',
      {}, 'WHERE day = ' + day);
    r.scan(t.index, 'index', 0, Number.MAX_SAFE_INTEGER, 'the smallest possible key (the scan has no lower bound)', function (key) { return t.indexLabel(key); }, function (key, hl) {
      var label = t.indexLabel(key), cd = Math.floor(key / LOC), d = cd % 100;
      if (d === day) {
        count++;
        r.results.push({ counted: label });
        r.emit('Entry ' + k(label, 'found') + ' has day ' + day + ': count it (' + count + ' so far). The day is inside the key, so no row is fetched.', { index: hl }, 'counted ' + label);
      } else {
        hl.keys[Object.keys(hl.keys)[0]] = 'compare';
        r.emit('Entry ' + k(label, 'compare') + ' has day ' + d + ', not ' + day + ': read and thrown away. The scan cannot skip it or stop here, because a later customer may have day ' + day + ' again.', { index: hl });
      }
    });
    r.emit('Done: count = ' + count + '. Cost: ' + r.summary() + '. All ' + r.c.entries + ' entries of the index were read to find ' + count +
      '; the same index answers "customer = ?" by reading only the matching run.', {}, 'done: ' + pages(r.c) + ' page reads');
    return r.finish({ found: count, what: 'SELECT count(*) WHERE day = ' + day });
  };

  /** SELECT * WHERE id = ? */
  P.queryId = function (id) {
    var r = new Rec(this), t = this, row;
    if (t.layout === 'clustered') {
      r.emit('SELECT * WHERE id = ' + id + ', clustered layout. The primary tree is keyed by id and its leaves hold the rows.', {}, 'WHERE id = ' + id);
      var leaf = r.descend(t.primary, 'primary', id, 'id ' + id);
      row = t.primary.get(id);
      if (row) {
        r.results.push(row);
        r.emit('Key ' + k(id, 'found') + ' is in this leaf, and so is the row: ' + rowText(row) + '. The descent <b>ended at the row</b>; there is nothing to fetch.',
          { primary: { nodes: mk(t.primary.id(leaf), 'active'), keys: mk(t.primary.id(leaf) + ':' + id, 'found') } });
      } else {
        r.emit('Id ' + id + ' is not in ' + (leaf === NIL ? 'the (empty) tree' : 'this leaf') + ', so there is no such row.', leaf === NIL ? {} : { primary: { nodes: mk(t.primary.id(leaf), 'active') } });
      }
    } else {
      r.emit('SELECT * WHERE id = ' + id + ', heap + index layout. The primary key is just another index: entries (id, TID), no rows.', {}, 'WHERE id = ' + id);
      var n = r.scan(t.primary, 'primary', id * LOC, id * LOC + LOC - 1, '(' + id + ', any TID)', function (key) { return t.primaryLabel(key); }, function (key, hl) {
        r.emit('Entry ' + k(t.primaryLabel(key), 'found') + ' has the id. The descent ended at a <b>TID</b>, not at the row.', { primary: hl });
        r.fetch(key % LOC, undefined);
      }, 1);
      row = n ? r.results[0] : null;
      if (!n) r.emit('No entry with id ' + id + ': there is no such row, and the heap is never touched.', {});
    }
    r.emit((row ? 'Done: 1 row. ' : 'Done: no row. ') + 'Cost: ' + r.summary() + '.', {}, 'done: ' + pages(r.c) + ' page reads');
    return r.finish({ found: row ? 1 : 0, what: 'SELECT * WHERE id = ' + id });
  };

  /** INSERT, recorded: primary-key check, then the writes. Mutates the table. */
  P.insertSteps = function (row) {
    var r = new Rec(this), t = this, taken;
    r.emit('INSERT ' + rowText(row) + '. First the primary-key check: is id ' + row.id + ' already there? One descent, before anything is written.' +
      (t.layout === 'heap' ? ' The search key is (' + row.id + ', any TID): the TID is left out, because <i>any</i> entry with this id is a conflict.' : ''), {}, 'INSERT id ' + row.id);
    if (t.layout === 'clustered') {
      var leaf = r.descend(t.primary, 'primary', row.id, 'id ' + row.id);
      taken = t.primary.get(row.id) !== undefined;
      if (taken) r.emit('Id ' + k(row.id, 'deleted') + ' exists: <b>rejected</b>, duplicate primary key. Nothing was written.',
        { primary: { nodes: mk(t.primary.id(leaf), 'active'), keys: mk(t.primary.id(leaf) + ':' + row.id, 'deleted') } }, 'rejected: duplicate id');
    } else {
      taken = r.scan(t.primary, 'primary', row.id * LOC, row.id * LOC + LOC - 1, '(' + row.id + ', any TID)',
        function (key) { return t.primaryLabel(key); }, function (key, hl) {
          hl.keys[Object.keys(hl.keys)[0]] = 'deleted';
          r.emit('Entry ' + k(t.primaryLabel(key), 'deleted') + ' has the id: <b>rejected</b>, duplicate primary key. Nothing was written.', { primary: hl }, 'rejected: duplicate id');
        }, 1) > 0;
    }
    if (taken) return r.finish({ ok: false });

    // The programs charge each write's descent BEFORE the put (putNew calls
    // chargeDescent first), so the heights are read before the insert: a
    // split of the root during this insert does not add a node to its cost.
    var before = t.primary.height + t.index.height;
    t.insert(row);
    r.snap = t.snapshot();                     // from here on the picture shows the new table
    var loc = t.layout === 'heap' ? t.heap.length - 1 : row.id;
    var ikey = (row.customer * 100 + row.day) * LOC + loc;
    r.c.descents += 2; r.c.nodes += before;
    var hl = { index: { keys: mk('*:' + t.indexLabel(ikey), 'inserted') } };
    if (t.layout === 'clustered') {
      hl.primary = { keys: mk('*:' + row.id, 'inserted') };
      r.emit('No conflict. The row went <b>into the primary tree</b> (its leaf is the storage), and the index got the entry ' + k(t.indexLabel(ikey), 'inserted') +
        ' whose locator is the row id. Two more descents, one per tree.', hl, 'inserted #' + row.id);
    } else {
      hl.primary = { keys: mk('*:' + t.primaryLabel(row.id * LOC + loc), 'inserted') };
      hl.heap = mk(loc, 'inserted');
      r.emit('No conflict. The row went into the <b>next free heap slot</b>, which fixed its TID ' + k(tidText(loc), 'inserted') + '. Then both indexes got an entry ending in that TID: ' +
        k(t.primaryLabel(row.id * LOC + loc), 'inserted') + ' and ' + k(t.indexLabel(ikey), 'inserted') + '.', hl, 'inserted at ' + tidText(loc));
    }
    return r.finish({ ok: true });
  };

  /* ------------------------------------------------------- fixed scenario */

  /** The 12 rows of the chapter's programs (the `code` column is left out). */
  var DEMO_ROWS = [
    [10, 7, 12, 250], [20, 3, 4, 40], [5, 7, 12, 75], [6, 9, 2, 300], [12, 7, 3, 120], [30, 3, 9, 90],
    [7, 7, 21, 35], [17, 9, 15, 510], [3, 3, 4, 60], [25, 7, 17, 125], [1, 3, 28, 999], [15, 9, 2, 45]
  ].map(function (r) { return { id: r[0], customer: r[1], day: r[2], amount: r[3] }; });

  function demoTable(layout) {
    var t = new Table(layout);
    DEMO_ROWS.forEach(function (r) { t.insert(r); });
    return t;
  }

  /** Leaves as the programs print them: "(3,4,#3) (3,4,#20) | (3,9,#30) ...". */
  function leavesText(table, which) {
    var tree = table[which];
    return tree.leaves().map(function (keys) {
      return keys.map(function (key) {
        if (which === 'index') { var cd = Math.floor(key / LOC); return '(' + Math.floor(cd / 100) + ',' + (cd % 100) + ',' + table.locText(key % LOC) + ')'; }
        return table.layout === 'heap' ? '(' + Math.floor(key / LOC) + ',' + tidText(key % LOC) + ')' : String(key);
      }).join(' ');
    }).join(' | ');
  }

  /** "descents=6 tree nodes=21 index entries=5 row fetches=5 heap reads=0 -> 21 page reads" */
  function costText(c) {
    return 'descents=' + c.descents + ' tree nodes=' + c.nodes + ' index entries=' + c.entries + ' row fetches=' + c.fetches +
      ' heap reads=' + c.heapReads + ' -> ' + pages(c) + ' page reads';
  }

  var api = {
    Table: Table, Tree: Tree, LIMITS: LIMITS, SLOTS: SLOTS, DEMO_ROWS: DEMO_ROWS,
    demoTable: demoTable, leavesText: leavesText, costText: costText, pages: pages, tidText: tidText, rowText: rowText
  };
  root.Ch18 = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);

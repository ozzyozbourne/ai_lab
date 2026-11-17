/* Chapter 15, chapter-local helpers (the shared toolkit has no "pages with byte-sized
 * cells" view, and no model with sibling balancing):
 *
 *   Ch15.SplitMix64   the PRNG of common/ (BigInt), so workloads match the programs
 *   Ch15.packLeft / Ch15.evenOut / Ch15.PageTree
 *                     a line-by-line port of zig/src/pages.zig. With `tree.trace = []`
 *                     every phase of an operation is recorded for the Stepper.
 *   Ch15.SiblingView  parent dividers, leaf pages as byte bars, and the scratch strip;
 *                     cells keep their DOM node between renders, so they glide.
 *   Ch15.report*      the same tables the Zig/Rust programs print (for the self-tests).
 */
(function (root) {
  'use strict';
  var el = root.BTViz.el;

  /* ---------------------------------------------------------------- SplitMix64 */
  var M64 = (1n << 64n) - 1n;
  function SplitMix64(seed) { this.s = BigInt(seed) & M64; }
  SplitMix64.prototype.next = function () {
    this.s = (this.s + 0x9E3779B97F4A7C15n) & M64;
    var z = this.s;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & M64;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & M64;
    return z ^ (z >> 31n);
  };
  /* multiply-high: top 64 bits of next() * n */
  SplitMix64.prototype.below = function (n) { return Number((this.next() * BigInt(n)) >> 64n); };
  SplitMix64.prototype.range = function (lo, hi) { return lo + this.below(hi - lo); };
  SplitMix64.prototype.shuffle = function (items) {
    for (var i = items.length - 1; i >= 1; i--) {
      var j = this.below(i + 1), t = items[i];
      items[i] = items[j];
      items[j] = t;
    }
  };

  /* ------------------------------------------------------- the redistribution */
  function sum(sizes, from, to) {
    var t = 0;
    for (var i = from; i < to; i++) t += sizes[i];
    return t;
  }

  /** Fill pages from the left. Returns ends: ends[p] = index one past page p's last cell. */
  function packLeft(sizes, capacity) {
    var ends = [], used = 0;
    for (var i = 0; i < sizes.length; i++) {
      if (used + sizes[i] > capacity) { ends.push(i); used = 0; }
      used += sizes[i];
    }
    ends.push(sizes.length);
    return ends;
  }

  /** Move cells right, boundary by boundary from the right, while the right page does not
   *  become bigger than the left. `note(kind, info)` is called for every decision. */
  function evenOut(sizes, ends, note) {
    for (var k = ends.length - 1; k >= 1; k--) {
      var leftStart = k >= 2 ? ends[k - 2] : 0;
      var left = sum(sizes, leftStart, ends[k - 1]), right = sum(sizes, ends[k - 1], ends[k]);
      for (;;) {
        if (ends[k - 1] <= leftStart + 1) { if (note) note('keep', { k: k, left: left, right: right }); break; }
        var c = sizes[ends[k - 1] - 1];
        if (right !== 0 && right + c > left - c) { if (note) note('stop', { k: k, cell: ends[k - 1] - 1, left: left, right: right, c: c }); break; }
        ends[k - 1] -= 1;
        left -= c;
        right += c;
        if (note) note('move', { k: k, cell: ends[k - 1], left: left, right: right, c: c });
      }
    }
  }

  /* ------------------------------------------------------------------ PageTree */
  function PageTree(cfg) {
    cfg = cfg || {};
    this.cfg = {
      capacity: cfg.capacity || 4096,
      insertSiblings: cfg.insertSiblings || 3,
      quickAppend: cfg.quickAppend !== false,
      merge: cfg.merge || 'below_third'           // never | at_empty | below_third | below_half
    };
    this.pages = [{ cells: [], used: 0, live: true }];
    this.freeIds = [];
    this.dividers = [];                            // {child, key}
    this.rightmost = 0;
    this.count = 0;
    this.stats = { balances: 0, quickAppends: 0, allocated: 0, freed: 0, leafWrites: 0, parentWrites: 0, moved: 0, movedToOld: 0 };
    this.trace = null;
  }
  var P = PageTree.prototype;

  P._ev = function (type, info) {
    if (!this.trace) return;
    info = info || {};
    info.type = type;
    info.tree = this.snapshot();
    this.trace.push(info);
  };
  P.snapshot = function () {
    var self = this, kids = [];
    for (var i = 0; i < this.childCount(); i++) {
      var id = this.childAt(i), p = this.pages[id];
      kids.push({ id: id, used: p.used, cells: p.cells.map(function (c) { return { key: c.key, size: c.size }; }) });
    }
    return {
      capacity: this.cfg.capacity, children: kids, rightmost: this.rightmost,
      dividers: this.dividers.map(function (d) { return { child: d.child, key: d.key }; }),
      free: this.freeIds.slice(), stats: JSON.parse(JSON.stringify(self.stats))
    };
  };
  P._allocPage = function () {
    this.stats.allocated++;
    if (this.freeIds.length) {
      var id = this.freeIds.pop();
      this.pages[id].live = true;
      return id;
    }
    this.pages.push({ cells: [], used: 0, live: true });
    return this.pages.length - 1;
  };
  P._freePage = function (id) {
    var p = this.pages[id];
    p.cells = [];
    p.used = 0;
    p.live = false;
    this.freeIds.push(id);
    this.stats.freed++;
  };
  P.childCount = function () { return this.dividers.length + 1; };
  P.childAt = function (i) { return i < this.dividers.length ? this.dividers[i].child : this.rightmost; };
  P.findChild = function (key) {
    var lo = 0, hi = this.dividers.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (this.dividers[mid].key < key) lo = mid + 1; else hi = mid;
    }
    return lo;
  };
  function cellPos(cells, key) {
    var lo = 0, hi = cells.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (cells[mid].key < key) lo = mid + 1; else hi = mid;
    }
    return lo;
  }
  P.usedBytes = function () {
    var t = 0;
    for (var i = 0; i < this.childCount(); i++) t += this.pages[this.childAt(i)].used;
    return t;
  };
  P.fillPermille = function () { return Math.floor(this.usedBytes() * 1000 / (this.childCount() * this.cfg.capacity)); };
  P.fills = function () {
    var out = [];
    for (var i = 0; i < this.childCount(); i++) out.push(this.pages[this.childAt(i)].used / this.cfg.capacity);
    return out;
  };
  P.get = function (key) {
    var cells = this.pages[this.childAt(this.findChild(key))].cells, pos = cellPos(cells, key);
    return pos < cells.length && cells[pos].key === key ? cells[pos].size : null;
  };

  /** Returns false (and changes nothing) if the cell is larger than a third of a page. */
  P.put = function (key, size) {
    var cap = this.cfg.capacity;
    if (size <= 0 || size > Math.floor(cap / 3)) return false;
    var ci = this.findChild(key), id = this.childAt(ci), page = this.pages[id];
    var pos = cellPos(page.cells, key);
    var existing = pos < page.cells.length && page.cells[pos].key === key;
    var oldSize = existing ? page.cells[pos].size : 0;
    if (existing) page.cells[pos].size = size;
    else { page.cells.splice(pos, 0, { key: key, size: size }); this.count++; }
    page.used = page.used - oldSize + size;
    this._ev('insert', { key: key, size: size, page: id, existing: existing, overfull: page.used > cap });
    if (page.used <= cap) return true;
    var appended = !existing && pos === page.cells.length - 1;
    if (this.cfg.quickAppend && appended && ci === this.childCount() - 1) this._quickAppend();
    else this._balance(ci, this.cfg.insertSiblings, 'overflow');
    return true;
  };
  P._quickAppend = function () {
    var oldId = this.rightmost, newId = this._allocPage();
    var old = this.pages[oldId], cell = old.cells.pop();
    old.used -= cell.size;
    this.pages[newId].cells.push(cell);
    this.pages[newId].used = cell.size;
    this.dividers.push({ child: oldId, key: old.cells[old.cells.length - 1].key });
    this.rightmost = newId;
    this.stats.quickAppends++;
    this.stats.leafWrites++;
    this.stats.parentWrites++;
    this._ev('quick', { oldPage: oldId, newPage: newId, key: cell.key });
  };
  P.delete = function (key) {
    var ci = this.findChild(key), id = this.childAt(ci), page = this.pages[id];
    var pos = cellPos(page.cells, key);
    if (pos === page.cells.length || page.cells[pos].key !== key) return false;
    page.used -= page.cells.splice(pos, 1)[0].size;
    this.count--;
    var cap = this.cfg.capacity, m = this.cfg.merge, lone = this.childCount() === 1;
    var wants = !lone && (m === 'below_third' ? (cap - page.used) * 3 > cap * 2 : m === 'below_half' ? page.used * 2 < cap : false);
    this._ev('delete', { key: key, page: id, used: page.used, wants: wants, lone: lone, policy: m });
    if (lone || m === 'never') return true;
    var empty = page.used === 0;
    if (wants) { this._balance(ci, 3, 'underflow'); return true; }
    if (empty) this._removeEmpty(ci);
    return true;
  };
  P._removeEmpty = function (ci) {
    var id = this.childAt(ci), toRight = ci < this.dividers.length;
    if (toRight) this.dividers.splice(ci, 1);
    else this.rightmost = this.dividers.pop().child;
    this._freePage(id);
    this.stats.parentWrites++;
    this._ev('remove-empty', { page: id, toRight: toRight });
  };
  P._balance = function (ci, window, why) {
    var self = this, cap = this.cfg.capacity, s, p;
    var n = this.childCount(), cnt = Math.min(window, n);
    var start = Math.min(Math.max(0, ci - (window >> 1)), n - cnt);
    var oldIds = [], oldEnds = [], flat = [], from = [], sizes = [];
    for (s = 0; s < cnt; s++) {
      var id = this.childAt(start + s);
      oldIds.push(id);
      this.pages[id].cells.forEach(function (c) { flat.push({ key: c.key, size: c.size }); from.push(id); sizes.push(c.size); });
      oldEnds.push(flat.length);
    }
    var strip = function (ends, extra) {
      var o = { ids: oldIds.slice(), flat: flat.map(function (c, i) { return { key: c.key, size: c.size, from: from[i] }; }), ends: ends.slice(), oldEnds: oldEnds.slice() };
      for (var key in (extra || {})) o[key] = extra[key];
      return o;
    };
    this._ev('pick', { ids: oldIds.slice(), page: this.childAt(ci), why: why, window: window });
    this._ev('flatten', { strip: strip(oldEnds, { old: true }) });
    var ends = packLeft(sizes, cap);
    this._ev('pack', { strip: strip(ends), cnt: cnt });
    evenOut(sizes, ends, this.trace ? function (kind, info) {
      self._ev('even-' + kind, { strip: strip(ends, { focus: info.cell }), info: info });
    } : null);
    var newCnt = ends.length, same = newCnt === cnt;
    for (s = 0; same && s < cnt; s++) same = ends[s] === oldEnds[s];
    if (same) { this._ev('noop', { ids: oldIds.slice() }); return; }

    var reused = Math.min(cnt, newCnt), ids = oldIds.slice(0, reused), fresh = [], gone = [];
    while (ids.length < newCnt) { var nid = this._allocPage(); ids.push(nid); fresh.push(nid); }
    var lastIsRight = start + cnt === n;
    var oldDiv = lastIsRight ? cnt - 1 : cnt, newDiv = lastIsRight ? newCnt - 1 : newCnt;
    var moved = 0, movedToOld = 0, movedKeys = {};
    for (p = 0; p < newCnt; p++) {
      var first = p === 0 ? 0 : ends[p - 1];
      var oldFirst = p === 0 || p >= cnt ? 0 : oldEnds[p - 1];
      if (p >= cnt || first !== oldFirst || ends[p] !== oldEnds[p]) this.stats.leafWrites++;
      for (var i = first; i < ends[p]; i++) {
        if (from[i] !== ids[p]) { moved++; movedKeys[flat[i].key] = p < cnt ? 'old' : 'new'; if (p < cnt) movedToOld++; }
      }
      var page = this.pages[ids[p]];
      page.cells = flat.slice(first, ends[p]);
      page.used = sum(sizes, first, ends[p]);
    }
    this.stats.moved += moved;
    this.stats.movedToOld += movedToOld;
    for (s = reused; s < cnt; s++) { this._freePage(oldIds[s]); gone.push(oldIds[s]); }
    var nd = [];
    for (p = 0; p < newDiv; p++) {
      nd.push({ child: ids[p], key: p + 1 < newCnt ? flat[ends[p] - 1].key : this.dividers[start + cnt - 1].key });
    }
    Array.prototype.splice.apply(this.dividers, [start, oldDiv].concat(nd));
    if (lastIsRight) this.rightmost = ids[newCnt - 1];
    this.stats.balances++;
    this.stats.parentWrites++;
    this._ev('commit', { ids: ids, oldCnt: cnt, newCnt: newCnt, fresh: fresh, gone: gone, moved: moved, movedToOld: movedToOld, movedKeys: movedKeys });
  };

  /** Same text as Tree.dump in the Zig and Rust programs. */
  P.dump = function () {
    var out = 'parent:';
    this.dividers.forEach(function (d) { out += ' (p' + d.child + ', ' + d.key + ')'; });
    out += ' right=p' + this.rightmost + '\n';
    for (var i = 0; i < this.childCount(); i++) {
      var id = this.childAt(i), p = this.pages[id];
      out += '  p' + id + ' ' + String(p.used).padStart(3) + '/' + this.cfg.capacity + ':';
      p.cells.forEach(function (c) { out += ' ' + c.key + ':' + c.size; });
      out += '\n';
    }
    return out;
  };
  P.statsLine = function () {
    var s = this.stats;
    return 'stats: balances=' + s.balances + ' quick_appends=' + s.quickAppends + ' allocated=' + s.allocated + ' freed=' + s.freed +
      ' leaf_writes=' + s.leafWrites + ' parent_writes=' + s.parentWrites + ' moved=' + s.moved + ' moved_to_old=' + s.movedToOld;
  };

  /* -------------------------------------------- the programs' fixed scenario */
  var SCENARIO = [
    { text: 'put 10 20 30 40 (25 bytes each): one full leaf', puts: [[10, 25], [20, 25], [30, 25], [40, 25]] },
    { text: 'put 50: append fast path, nothing moves', puts: [[50, 25]] },
    { text: 'put 60 70 80: the right-most leaf fills up', puts: [[60, 20], [70, 30], [80, 25]] },
    { text: 'put 35: p0 overflows, 2 siblings in, 3 out (split)', puts: [[35, 20]] },
    { text: 'put 15: p0 overflows again, 3 in, 3 out (redistribution)', puts: [[15, 20]] },
    { text: 'delete 70: p2 is more than 2/3 free, 3 in, 3 out (redistribution)', deletes: [70] },
    { text: 'delete 80: 3 in, 2 out (merge), p2 goes to the free list', deletes: [80] }
  ];
  /** Section 2 of expected_output.txt, regenerated by the JS model. */
  function reportScenario() {
    var tree = new PageTree({ capacity: 100 }), out = '';
    SCENARIO.forEach(function (step) {
      (step.puts || []).forEach(function (c) { tree.put(c[0], c[1]); });
      (step.deletes || []).forEach(function (k) { tree.delete(k); });
      out += step.text + '\n' + tree.dump();
    });
    var show = function (v) { return v === null ? 'null' : String(v); };
    var keys = [];
    for (var k = 20; k < 50; k++) if (tree.get(k) !== null) keys.push(k);
    out += 'get 35 -> ' + show(tree.get(35)) + ', get 70 -> ' + show(tree.get(70)) + ', range [20, 50) -> ' + keys.join(' ') + '\n';
    return out + tree.statsLine() + '\n';
  }

  /* ------------------------------------------------ the programs' experiments */
  var sizeCache = [];
  function sizeOf(key) {
    if (sizeCache[key] === undefined) sizeCache[key] = 40 + new SplitMix64(key).below(161);
    return sizeCache[key];
  }
  function makeKeys(n, seed) {
    var keys = [];
    for (var i = 1; i <= n; i++) keys.push(i);
    if (seed !== null && seed !== undefined) new SplitMix64(seed).shuffle(keys);
    return keys;
  }
  var INSERT_POLICIES = [
    { label: 'split alone', siblings: 1, quick: false },
    { label: 'split alone + quick', siblings: 1, quick: true },
    { label: 'balance 2', siblings: 2, quick: false },
    { label: 'balance 3', siblings: 3, quick: false },
    { label: 'balance 3 + quick', siblings: 3, quick: true }
  ];
  var MERGE_POLICIES = [
    { label: 'never', merge: 'never' },
    { label: 'at empty', merge: 'at_empty' },
    { label: 'below 1/3 (balance 3)', merge: 'below_third' },
    { label: 'below 1/2 (balance 3)', merge: 'below_half' }
  ];
  var WORKLOADS = [
    { id: 'ascending', kind: 'insert', title: 'ascending keys', seed: null },
    { id: 'random', kind: 'insert', title: 'random order', seed: 15 },
    { id: 'delete-random', kind: 'delete', title: 'delete 90% of the keys in random order (counters: the deletes only)' },
    { id: 'delete-queue', kind: 'delete', title: 'delete the 90% smallest keys, a queue being drained' },
    { id: 'churn', kind: 'delete', title: null }
  ];
  function measure(label, tree, since) {
    var s = tree.stats;
    since = since || { balances: 0, leafWrites: 0, freed: 0, moved: 0, movedToOld: 0 };
    return {
      label: label, pages: tree.childCount(), fill: tree.fillPermille(), balances: s.balances - since.balances,
      writes: s.leafWrites - since.leafWrites, freed: s.freed - since.freed, moved: s.moved - since.moved,
      movedToOld: s.movedToOld - since.movedToOld, fills: tree.fills()
    };
  }
  /** Run one workload for every policy. Returns rows[policy][checkpoint]; the last
   *  checkpoint is the final state. `n` = number of keys (the programs use 20000). */
  function runWorkload(id, n, checkpoints) {
    checkpoints = checkpoints || 1;
    var w = WORKLOADS.filter(function (x) { return x.id === id; })[0];
    var policies = w.kind === 'insert' ? INSERT_POLICIES : MERGE_POLICIES;
    return policies.map(function (policy) {
      var tree, ops, since = null, rows = [], i;
      if (w.kind === 'insert') {
        tree = new PageTree({ insertSiblings: policy.siblings, quickAppend: policy.quick, merge: 'never' });
        ops = makeKeys(n, w.seed).map(function (key) { return function () { tree.put(key, sizeOf(key)); }; });
      } else {
        tree = new PageTree({ merge: policy.merge });
        makeKeys(n, 15).forEach(function (key) { tree.put(key, sizeOf(key)); });
        since = JSON.parse(JSON.stringify(tree.stats));
        var doomed = Math.floor(n / 10) * 9;
        if (id === 'delete-random') ops = makeKeys(n, 16).slice(0, doomed).map(function (key) { return function () { tree.delete(key); }; });
        else if (id === 'delete-queue') { ops = []; for (i = 1; i <= doomed; i++) ops.push((function (key) { return function () { tree.delete(key); }; })(i)); }
        else {
          var rng = new SplitMix64(17);
          ops = [];
          for (i = 0; i < 2 * n; i++) ops.push(function () { var key = rng.range(1, n + 1); if (!tree.delete(key)) tree.put(key, sizeOf(key)); });
        }
        if (checkpoints > 1) rows.push(measure(policy.label, tree, since));
      }
      var done = 0;
      for (var c = 1; c <= checkpoints; c++) {
        var until = Math.round(ops.length * c / checkpoints);
        for (; done < until; done++) ops[done]();
        var row = measure(policy.label, tree, since);
        row.ops = done;
        rows.push(row);
      }
      return rows;
    });
  }
  var TABLE_HEADER = 'policy                 pages   fill balances  writes   freed    moved   to old\n';
  function rowText(r) {
    var pad = function (v, w) { return String(v).padStart(w); };
    return r.label.padEnd(22) + pad(r.pages, 6) + pad(Math.floor(r.fill / 10), 5) + '.' + (r.fill % 10) + '%' +
      pad(r.balances, 9) + pad(r.writes, 8) + pad(r.freed, 8) + pad(r.moved, 9) + pad(r.movedToOld, 9) + '\n';
  }
  function tableText(id, n) {
    return TABLE_HEADER + runWorkload(id, n).map(function (rows) { return rowText(rows[rows.length - 1]); }).join('');
  }
  /** Sections 3 and 4 of expected_output.txt, as five thunks (one per table) so that a
   *  page can compute them between frames instead of blocking for the whole run. */
  function reportPoliciesParts(n) {
    return [
      function () { return '== 3. Overflow policies: ' + n + ' inserts, cells of 40..200 bytes, capacity 4096 ==\n-- ascending keys --\n' + tableText('ascending', n); },
      function () { return '-- random order --\n' + tableText('random', n); },
      function () {
        return '\n== 4. Underflow policies (tree built by ' + n + ' random inserts, balance 3 + quick) ==\n' +
          '-- delete 90% of the keys in random order (counters: the deletes only) --\n' + tableText('delete-random', n);
      },
      function () { return '-- delete the 90% smallest keys, a queue being drained --\n' + tableText('delete-queue', n); },
      function () { return '-- steady churn: ' + 2 * n + ' times, toggle a random key (delete it if present, else insert it) --\n' + tableText('churn', n); }
    ];
  }
  function reportPolicies(n) { return reportPoliciesParts(n).map(function (f) { return f(); }).join(''); }

  /* --------------------------------------------------------------- SiblingView */
  var CSS = [
    '.c15-view { position: relative; min-width: 0; }',
    '.c15-parent { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; font-size: .84rem; color: var(--bt-muted); min-height: 30px; }',
    '.c15-parent .bt-chip { transition: background-color var(--bt-dur), box-shadow var(--bt-dur); }',
    '.c15-canvas { position: relative; margin-top: 10px; transition: height var(--bt-dur); }',
    '.c15-page { position: absolute; transition: transform var(--bt-dur), opacity var(--bt-dur); }',
    '.c15-page-label { position: absolute; left: 0; top: 0; font: .76rem/16px var(--bt-mono); color: var(--bt-muted); white-space: nowrap; }',
    '.c15-page-label b { color: var(--bt-text); }',
    '.c15-page-label .is-over { color: var(--bt-key-deleted); font-weight: 700; }',
    '.c15-page-box { position: absolute; left: 0; top: 18px; height: 40px; border-radius: 6px; border: 1.5px solid var(--s, var(--bt-node)); background: var(--s-bg, var(--bt-free-bg)); transition: border-color var(--bt-dur), background-color var(--bt-dur); }',
    '.c15-page-over { position: absolute; top: 18px; height: 40px; border-radius: 0 6px 6px 0; border: 1.5px dashed var(--bt-key-deleted); border-left: 0; background: var(--bt-key-deleted-bg); opacity: 0; transition: opacity var(--bt-dur); }',
    '.c15-page.is-over .c15-page-over { opacity: 1; }',
    '.c15-strip-label { position: absolute; left: 0; font: .76rem/16px var(--bt-mono); color: var(--bt-muted); white-space: nowrap; transition: opacity var(--bt-dur); }',
    '.c15-strip-box { position: absolute; left: 0; right: 0; height: 48px; border-radius: 6px; border: 1.5px dashed var(--bt-border); background: var(--bt-surface-2); transition: opacity var(--bt-dur); }',
    '.c15-cut { position: absolute; width: 0; height: 56px; border-left: 2.5px solid var(--bt-split); transition: transform var(--bt-dur), opacity var(--bt-dur); }',
    '.c15-cut.is-old { border-left: 2px dashed var(--bt-muted); }',
    '.c15-sum { position: absolute; font: .74rem/16px var(--bt-mono); color: var(--bt-muted); text-align: center; white-space: nowrap; transition: transform var(--bt-dur), opacity var(--bt-dur); }',
    '.c15-cell { position: absolute; left: 0; top: 0; height: 32px; border-radius: 4px; overflow: hidden; display: flex; flex-direction: column; align-items: center; justify-content: center;',
    '  font: 600 .78rem/1.05 var(--bt-mono); color: var(--bt-text); background: var(--s-bg, var(--bt-key-bg)); box-shadow: inset 0 0 0 1.5px var(--s, var(--bt-node));',
    '  transition: transform var(--bt-dur) cubic-bezier(.3,.1,.2,1), width var(--bt-dur), opacity var(--bt-dur), background-color var(--bt-dur), box-shadow var(--bt-dur); }',
    '.c15-cell small { font-weight: 400; font-size: .62rem; color: var(--bt-muted); }',
    '.c15-cell.is-narrow { font-size: .66rem; }',
    '.c15-cell.is-narrow small { display: none; }',
    '.c15-free { margin-top: 8px; font-size: .82rem; color: var(--bt-muted); min-height: 26px; display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }',
    '.c15-stats { display: grid; grid-template-columns: 1fr auto; gap: 2px 12px; font-size: .84rem; }',
    '.c15-stats b { font-family: var(--bt-mono); text-align: right; }',
    '.c15-profile { display: grid; grid-template-columns: minmax(0, 11.5em) minmax(0, 1fr) 4.2em; gap: 6px 10px; align-items: center; font-size: .82rem; }',
    '.c15-profile svg { display: block; width: 100%; height: 34px; background: var(--bt-free-bg); border-radius: 4px; }',
    '.c15-profile path { fill: var(--bt-node-active); }',
    '.c15-profile .num { font-family: var(--bt-mono); text-align: right; }',
    '@media (max-width: 520px) { .c15-profile { grid-template-columns: minmax(0, 7.2em) minmax(0, 1fr) 3.6em; font-size: .74rem; } }'
  ].join('\n');
  var cssDone = false;

  /**
   * new Ch15.SiblingView(target).render(state)
   * state: { tree: PageTree.snapshot(), strip?: {ids, flat:[{key,size,from}], ends, oldEnds, old?, focus?},
   *          pages?: {id: state}, cells?: {key: state}, gone?: [key…] }
   */
  function SiblingView(target) {
    if (!cssDone) { document.head.appendChild(el('style', CSS)); cssDone = true; }
    var self = this;
    this.parent = el('div.c15-parent');
    this.canvas = el('div.c15-canvas');
    this.free = el('div.c15-free');
    this.root = el('div.c15-view', { role: 'img' }, this.parent, this.canvas, this.free);
    (typeof target === 'string' ? document.querySelector(target) : target).appendChild(this.root);
    this.cells = {};
    this.pageEls = {};
    this.cuts = [];
    this.sums = [];
    this.stripBox = el('div.c15-strip-box', { style: { opacity: 0 } });
    this.stripLabel = el('div.c15-strip-label', { style: { opacity: 0 } });
    this.canvas.append(this.stripBox, this.stripLabel);
    this.state = null;
    if (typeof ResizeObserver !== 'undefined') {
      var last = -1;
      new ResizeObserver(function () {
        var w = self.root.clientWidth;
        if (w !== last && self.state) { last = w; self._draw(true); }
      }).observe(this.root);
    }
  }
  SiblingView.prototype.render = function (state) {
    this.state = state;
    this._draw(false);
    return this;
  };
  SiblingView.prototype._draw = function (instant) {
    var st = this.state, tree = st.tree, cap = tree.capacity, self = this;
    var dur = instant ? 0 : root.BTViz.motion.duration();
    this.root.style.setProperty('--bt-dur', dur + 'ms');
    var W = Math.max(220, this.root.clientWidth);
    var hlPages = st.pages || {}, hlCells = st.cells || {}, strip = st.strip || null;

    /* parent row */
    this.parent.textContent = '';
    this.parent.appendChild(el('span', 'parent:'));
    tree.dividers.forEach(function (d) {
      self.parent.appendChild(el('span.bt-chip' + (hlPages[d.child] ? '.s-' + hlPages[d.child] : ''), '≤ ' + d.key + ' → p' + d.child));
    });
    this.parent.appendChild(el('span.bt-chip' + (hlPages[tree.rightmost] ? '.s-' + hlPages[tree.rightmost] : ''), (tree.dividers.length ? 'rest' : 'all keys') + ' → p' + tree.rightmost));

    /* page grid: each slot is 130% of a page wide so an overfull page can spill */
    var cols = W < 460 ? 1 : W < 760 ? 2 : 3, gap = 14;
    var slotW = Math.min(360, (W - gap * (cols - 1)) / cols), scale = slotW / (cap * 1.3), rowH = 70;
    var inStrip = {};
    if (strip) strip.ids.forEach(function (id) { inStrip[id] = true; });
    var seenPages = {}, seenCells = {}, pos = {};
    tree.children.forEach(function (child, i) {
      var x = (i % cols) * (slotW + gap), y = Math.floor(i / cols) * rowH;
      var pe = self.pageEls[child.id];
      if (!pe) {
        pe = self.pageEls[child.id] = { root: el('div.c15-page', { style: { opacity: 0 } }), label: el('div.c15-page-label'), box: el('div.c15-page-box'), over: el('div.c15-page-over') };
        pe.root.append(pe.label, pe.box, pe.over);
        pe.root.style.transform = 'translate(' + x + 'px,' + y + 'px)';
        self.canvas.insertBefore(pe.root, self.canvas.firstChild);
        void pe.root.offsetWidth;
      }
      seenPages[child.id] = true;
      var over = child.used > cap;
      pe.root.className = 'c15-page' + (over ? ' is-over' : '');
      pe.root.style.transform = 'translate(' + x + 'px,' + y + 'px)';
      pe.root.style.opacity = 1;
      pe.box.className = 'c15-page-box' + (hlPages[child.id] ? ' s-' + hlPages[child.id] : '');
      pe.box.style.width = cap * scale + 'px';
      pe.over.style.left = cap * scale + 'px';
      pe.over.style.width = cap * 0.3 * scale + 'px';
      pe.label.innerHTML = '<b>p' + child.id + '</b> ' + (inStrip[child.id] ? 'copied to scratch' : '<span class="' + (over ? 'is-over' : '') + '">' + child.used + '</span>/' + cap + ' bytes' + (over ? ' — overfull' : ''));
      if (inStrip[child.id]) return;
      var off = 0;
      child.cells.forEach(function (c) {
        pos[c.key] = { x: x + off * scale + 1.5, y: y + 22, w: c.size * scale - 3, size: c.size };
        off += c.size;
      });
    });
    Object.keys(this.pageEls).forEach(function (id) {
      if (seenPages[id]) return;
      var pe = self.pageEls[id];
      pe.root.style.opacity = 0;
      delete self.pageEls[id];
      setTimeout(function () { if (pe.root.parentNode) pe.root.parentNode.removeChild(pe.root); }, dur + 30);
    });
    var pagesH = Math.ceil(tree.children.length / cols) * rowH;

    /* scratch strip */
    var stripY = pagesH + 22, cutEls = this.cuts, sumEls = this.sums, nCuts = 0, nSums = 0;
    this.stripBox.style.top = stripY - 8 + 'px';
    this.stripLabel.style.top = stripY - 26 + 'px';
    this.stripBox.style.opacity = this.stripLabel.style.opacity = strip ? 1 : 0;
    if (strip) {
      var total = 0, gapPx = 10, ends = strip.ends;
      strip.flat.forEach(function (c) { total += c.size; });
      var sScale = Math.min(scale, (W - 12 - gapPx * (ends.length - 1)) / Math.max(1, total));
      this.stripLabel.textContent = 'scratch: ' + strip.flat.length + ' cells, ' + total + ' bytes' + (strip.old ? ' (dashed: old page boundaries)' : ' → ' + ends.length + ' page' + (ends.length > 1 ? 's' : ''));
      var x = 6, page = 0, segStart = x, segBytes = 0;
      var cut = function (cls) {
        var c = cutEls[nCuts] || (cutEls[nCuts] = self.canvas.appendChild(el('div.c15-cut')));
        c.className = 'c15-cut' + (cls ? ' ' + cls : '');
        c.style.transform = 'translate(' + (x + gapPx / 2 - 1) + 'px,' + (stripY - 12) + 'px)';
        c.style.opacity = 1;
        nCuts++;
      };
      var sumLabel = function () {
        var s = sumEls[nSums] || (sumEls[nSums] = self.canvas.appendChild(el('div.c15-sum')));
        s.textContent = '=' + segBytes;
        s.style.width = Math.max(30, x - segStart) + 'px';
        s.style.transform = 'translate(' + segStart + 'px,' + (stripY + 42) + 'px)';
        s.style.opacity = 1;
        nSums++;
      };
      strip.flat.forEach(function (c, i) {
        if (i === ends[page] && page < ends.length - 1) {
          sumLabel();
          cut(strip.old ? 'is-old' : '');
          x += gapPx;
          page++;
          segStart = x;
          segBytes = 0;
        }
        pos[c.key] = { x: x + 1, y: stripY, w: c.size * sScale - 2, size: c.size };
        x += c.size * sScale;
        segBytes += c.size;
      });
      sumLabel();
    }
    for (var i = nCuts; i < cutEls.length; i++) cutEls[i].style.opacity = 0;
    for (i = nSums; i < sumEls.length; i++) sumEls[i].style.opacity = 0;
    this.canvas.style.height = (strip ? stripY + 62 : pagesH + 4) + 'px';

    /* cells: one persistent node per key, moved with transforms */
    Object.keys(pos).forEach(function (key) {
      var p = pos[key], ce = self.cells[key];
      if (!ce) {
        ce = self.cells[key] = el('div.c15-cell', { style: { opacity: 0 } });
        ce.style.transform = 'translate(' + p.x + 'px,' + (p.y - 26) + 'px)';
        ce.style.width = Math.max(4, p.w) + 'px';
        self.canvas.appendChild(ce);
        void ce.offsetWidth;
      }
      seenCells[key] = true;
      ce.className = 'c15-cell' + (hlCells[key] ? ' s-' + hlCells[key] : '') + (p.w < 30 ? ' is-narrow' : '');
      ce.innerHTML = key + '<small>' + p.size + ' b</small>';
      ce.title = 'key ' + key + ', ' + p.size + ' bytes';
      ce.style.transform = 'translate(' + p.x + 'px,' + p.y + 'px)';
      ce.style.width = Math.max(4, p.w) + 'px';
      ce.style.opacity = 1;
    });
    Object.keys(this.cells).forEach(function (key) {
      if (seenCells[key]) return;
      var ce = self.cells[key];
      ce.style.opacity = 0;
      delete self.cells[key];
      setTimeout(function () { if (ce.parentNode) ce.parentNode.removeChild(ce); }, dur + 30);
    });

    /* free list */
    this.free.textContent = '';
    this.free.appendChild(el('span', 'free list:'));
    if (!tree.free.length) this.free.appendChild(el('span', 'empty'));
    tree.free.forEach(function (id) { self.free.appendChild(el('span.bt-chip.s-free', 'p' + id)); });
    this.root.setAttribute('aria-label', 'Parent with ' + tree.dividers.length + ' divider cells and ' + tree.children.length + ' leaf pages: ' +
      tree.children.map(function (c) { return 'p' + c.id + ' ' + c.used + ' of ' + cap + ' bytes'; }).join(', ') + (strip ? '. Cells of the siblings are in the scratch array.' : ''));
  };

  root.Ch15 = {
    SplitMix64: SplitMix64, packLeft: packLeft, evenOut: evenOut, PageTree: PageTree, SiblingView: SiblingView,
    SCENARIO: SCENARIO, reportScenario: reportScenario, reportPolicies: reportPolicies, reportPoliciesParts: reportPoliciesParts, runWorkload: runWorkload,
    WORKLOADS: WORKLOADS, INSERT_POLICIES: INSERT_POLICIES, MERGE_POLICIES: MERGE_POLICIES, sizeOf: sizeOf
  };
})(typeof window !== 'undefined' ? window : this);

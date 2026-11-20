/* Chapter 25, chapter-local helpers (classic script, defines window.CH25).
 *
 * 1. A JS port of the chapter's model: SplitMix64, the cache-line Trace (key
 *    array and side array, hints with lead time), the five lower-bound
 *    algorithms and the two layouts. It mirrors
 *    zig/src/{trace,search,layout,node}.zig line for line so that the page
 *    can reproduce the program's printed counts (see the self-tests).
 * 2. LineStrip: a small view that draws an array as a strip of 64-byte cache
 *    lines. The shared toolkit has no such component.
 */
(function () {
  'use strict';

  var LANES = 8;
  var SENTINEL = Infinity; // stands for maxInt(u64): never smaller than a needle

  // ------------------------------------------------------------ SplitMix64
  var MASK = (1n << 64n) - 1n;
  function SplitMix64(seed) { this.state = BigInt(seed); }
  SplitMix64.prototype.next = function () {
    this.state = (this.state + 0x9E3779B97F4A7C15n) & MASK;
    var z = this.state;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK;
    return z ^ (z >> 31n);
  };
  SplitMix64.prototype.below = function (n) { return Number((this.next() * BigInt(n)) >> 64n); };
  SplitMix64.prototype.chance = function (a, b) { return this.below(b) < a; };
  SplitMix64.prototype.shuffle = function (items) {
    for (var i = items.length - 1; i >= 1; i--) {
      var j = this.below(i + 1);
      var tmp = items[i]; items[i] = items[j]; items[j] = tmp;
    }
  };

  /** Strictly increasing keys with random gaps of 1..100 (same as the programs). */
  function makeKeys(n, seed) {
    var rng = new SplitMix64(seed), keys = [], key = 0;
    for (var i = 0; i < n; i++) { key += 1 + rng.below(100); keys.push(key); }
    return keys;
  }

  // ----------------------------------------------------------------- Trace
  // Two arrays, as in trace.zig: the KEY array (cmp, cmpBlock, prefetch) and a
  // SIDE array of 4-byte entries (side): the rank array or the child column.
  function Trace(stride) {
    this.stride = stride || 8;
    this.comparisons = 0; this.steps = 0; this.prefetches = 0; this.uncovered = 0;
    this.read = new Set(); this.sideRead = new Set();
    this.hinted = new Set(); // hints that have had at least one comparison of lead time
    this.pending = [];       // hints issued since the last comparison: too late for the next read
    this.probes = [];
    this.events = []; // for the step-by-step view only
  }
  Trace.prototype.lineOf = function (index) { return Math.floor(index * this.stride / 64); };
  Trace.prototype.readLine = function (line) {
    if (this.read.has(line)) return 'again';
    this.read.add(line);
    if (this.hinted.has(line)) return 'hinted';
    this.uncovered++;
    return this.pending.indexOf(line) >= 0 ? 'late' : 'cold';
  };
  Trace.prototype.settleHints = function () {
    for (var i = 0; i < this.pending.length; i++) this.hinted.add(this.pending[i]);
    this.pending = [];
  };
  Trace.prototype.cmp = function (index, info) {
    this.comparisons++; this.steps++; this.probes.push(index);
    var line = this.lineOf(index);
    this.events.push({ kind: 'cmp', index: index, line: line, how: this.readLine(line), info: info || {} });
    this.settleHints();
  };
  Trace.prototype.cmpBlock = function (index, count, info) {
    this.comparisons += count; this.steps++; this.probes.push(index);
    var line = this.lineOf(index);
    this.events.push({ kind: 'block', index: index, count: count, line: line, how: this.readLine(line), info: info || {} });
    this.settleHints();
  };
  Trace.prototype.prefetch = function (index, info) {
    this.prefetches++;
    var line = this.lineOf(index);
    this.pending.push(line);
    this.events.push({ kind: 'hint', index: index, line: line, useless: this.read.has(line), info: info || {} });
  };
  Trace.prototype.side = function (index, info) {
    var line = Math.floor(index * 4 / 64), fresh = !this.sideRead.has(line);
    if (fresh) { this.sideRead.add(line); this.uncovered++; }
    this.events.push({ kind: 'side', index: index, line: line, fresh: fresh, info: info || {} });
  };
  Trace.prototype.keyLines = function () { return this.read.size; };
  Trace.prototype.sideLines = function () { return this.sideRead.size; };
  Trace.prototype.linesRead = function () { return this.read.size + this.sideRead.size; };

  // ------------------------------------------------------------ algorithms
  function lowerBoundLinear(keys, key) {
    var count = 0;
    for (var i = 0; i < keys.length; i++) count += keys[i] < key ? 1 : 0;
    return count;
  }

  function lowerBoundClassic(keys, key, t) {
    var lo = 0, hi = keys.length;
    while (lo < hi) {
      var mid = lo + Math.floor((hi - lo) / 2);
      var less = keys[mid] < key;
      t.cmp(mid, { lo: lo, hi: hi, less: less });
      if (less) lo = mid + 1; else hi = mid;
    }
    return lo;
  }

  /** `at(i)` reads the key of element i, so the same loop serves `[]u64` and 16-byte entries. */
  function lowerBoundHalving(keys, key, prefetch, t) {
    if (keys.length === 0) return 0;
    var offset = 0, length = keys.length;
    while (length > 1) {
      var half = Math.floor(length / 2), mid = offset + half;
      if (prefetch) {
        var nextHalf = Math.floor((length - half) / 2);
        t.prefetch(offset + nextHalf, { which: 'lower' });
        t.prefetch(mid + nextHalf, { which: 'upper' });
      }
      var less = keys[mid] < key;
      t.cmp(mid, { offset: offset, length: length, half: half, less: less });
      if (less) offset = mid;
      length -= half;
    }
    var last = keys[offset] < key;
    t.cmp(offset, { offset: offset, length: 1, final: true, less: last });
    return offset + (last ? 1 : 0);
  }

  function rank8(keys, start, key) {
    var count = 0;
    for (var i = 0; i < LANES; i++) count += keys[start + i] < key ? 1 : 0;
    return count;
  }

  function padToLanes(sorted) {
    var padded = sorted.slice();
    while (padded.length % LANES !== 0) padded.push(SENTINEL);
    return padded;
  }

  function lowerBoundVector(padded, key, t) {
    var count = 0;
    for (var i = 0; i < padded.length; i += LANES) {
      var r = rank8(padded, i, key);
      count += r;
      t.cmpBlock(i, LANES, { r: r, count: count });
    }
    return count;
  }

  function Eytzinger(sorted) {
    var n = sorted.length, size = Math.ceil((n + 1) / LANES) * LANES;
    this.n = n;
    this.keys = new Array(size).fill(SENTINEL);
    this.keys[0] = null; // unused slot
    this.rank = new Array(n + 1).fill(0);
    this.rank[0] = n;
    var self = this, next = 0;
    (function fill(k) {
      if (k > n) return;
      fill(2 * k);
      self.keys[k] = sorted[next]; self.rank[k] = next; next++;
      fill(2 * k + 1);
    })(1);
  }
  Eytzinger.prototype.lowerBound = function (key, prefetch, t) {
    var k = 1;
    while (k <= this.n) {
      if (prefetch) t.prefetch(Math.min(8 * k, this.keys.length - 1), { from: k, clamped: 8 * k > this.keys.length - 1 });
      var less = this.keys[k] < key;
      t.cmp(k, { less: less, next: 2 * k + (less ? 1 : 0) });
      k = 2 * k + (less ? 1 : 0);
    }
    var end = k, ones = 0;
    while (k & 1) { k >>= 1; ones++; }
    k >>= 1;
    this.lastSlot = k; this.lastEnd = end; this.lastOnes = ones;
    t.side(k, { slot: k }); // the one read of the rank array
    return this.rank[k];
  };

  function BlockTree(sorted) {
    var n = sorted.length, slots = Math.ceil(n / LANES) * LANES, blocks = slots / LANES;
    this.n = n; this.blocks = blocks;
    this.keys = new Array(slots).fill(SENTINEL);
    this.rank = new Array(slots + 1).fill(n); // one extra entry: rank[slots] = n means "no key"
    var self = this, next = 0;
    (function fill(block) {
      if (block >= blocks) return;
      for (var j = 0; j < LANES; j++) {
        fill(block * 9 + j + 1);
        if (next < n) { self.keys[block * 8 + j] = sorted[next]; self.rank[block * 8 + j] = next; next++; }
      }
      fill(block * 9 + 9);
    })(0);
  }
  BlockTree.prototype.lowerBound = function (key, t) {
    var noKey = this.blocks * 8, slot = noKey, block = 0;
    while (block < this.blocks) {
      var r = rank8(this.keys, block * 8, key);
      if (r < 8) slot = block * 8 + r; // remembered, not looked up
      var child = block * 9 + r + 1;
      t.cmpBlock(block * 8, 8, { block: block, r: r, child: child, exists: child < this.blocks, slot: slot === noKey ? -1 : slot });
      block = child;
    }
    this.lastSlot = slot === noKey ? -1 : slot;
    t.side(slot, { slot: slot === noKey ? -1 : slot }); // the one read of the rank array
    return this.rank[slot];
  };

  /** Every searchable form of one sorted key set. */
  function Index(sorted) {
    this.sorted = sorted;
    this.padded = padToLanes(sorted);
    this.eytzinger = new Eytzinger(sorted);
    this.blocks = new BlockTree(sorted);
  }
  var ALGORITHMS = ['classic', 'halving', 'vector', 'eytzinger', 'blocktree'];
  function runOne(index, algorithm, needle, t, prefetch) {
    switch (algorithm) {
      case 'classic': return lowerBoundClassic(index.sorted, needle, t);
      case 'halving': case 'halving-aos': return lowerBoundHalving(index.sorted, needle, !!prefetch, t);
      case 'vector': return lowerBoundVector(index.padded, needle, t);
      case 'eytzinger': return index.eytzinger.lowerBound(needle, !!prefetch, t);
      case 'blocktree': return index.blocks.lowerBound(needle, t);
    }
    throw new Error('unknown algorithm ' + algorithm);
  }

  // ------------------------------------------- reproduce the program output
  function pad(s, width, left) {
    s = String(s);
    while (s.length < width) s = left ? s + ' ' : ' ' + s;
    return s;
  }
  function avg(total, count) {
    var h = Math.floor(total * 100 / count);
    return Math.floor(h / 100) + '.' + (h % 100 < 10 ? '0' : '') + (h % 100);
  }
  function Stats() {
    this.lookups = 0; this.comparisons = 0; this.steps = 0; this.keyLines = 0; this.sideLines = 0; this.lines = 0;
    this.maxLines = 0; this.prefetches = 0; this.uncovered = 0;
  }
  Stats.prototype.add = function (t) {
    this.lookups++; this.comparisons += t.comparisons; this.steps += t.steps;
    this.keyLines += t.keyLines(); this.sideLines += t.sideLines();
    this.lines += t.linesRead(); this.maxLines = Math.max(this.maxLines, t.linesRead());
    this.prefetches += t.prefetches; this.uncovered += t.uncovered;
  };

  function handKeys() { var k = []; for (var i = 1; i <= 15; i++) k.push(i * 10); return k; }

  /** Section 1 of expected_output.txt, the per-needle lines. */
  function handText() {
    var index = new Index(handKeys()), out = [];
    [70, 95, 999].forEach(function (needle) {
      out.push('needle ' + needle + ' -> index ' + lowerBoundLinear(index.sorted, needle));
      ALGORITHMS.forEach(function (a) {
        var t = new Trace();
        runOne(index, a, needle, t, false);
        out.push('  ' + pad(a, 9, true) + ' cmps ' + pad(t.comparisons, 2) + ' steps ' + t.steps +
          ' lines ' + t.linesRead() + ' (keys ' + t.keyLines() + ' + rank ' + t.sideLines() + ') probes ' + t.probes.join(' '));
      });
    });
    return out.join('\n');
  }

  /** Section 2: the five rows for one size, 1000 seeded lookups. Also returns the raw stats. */
  function sizeRows(n) {
    var index = new Index(makeKeys(n, 1000 + n));
    var stats = ALGORITHMS.map(function () { return new Stats(); });
    var rng = new SplitMix64(2000 + n), agree = 0, checksum = 0;
    for (var i = 0; i < 1000; i++) {
      var needle = rng.below(index.sorted[n - 1] + 50);
      var want = lowerBoundLinear(index.sorted, needle), all = true;
      ALGORITHMS.forEach(function (a, j) {
        var t = new Trace();
        if (runOne(index, a, needle, t, false) !== want) all = false;
        stats[j].add(t);
      });
      agree += all ? 1 : 0; checksum += want;
    }
    var text = ALGORITHMS.map(function (a, j) {
      var s = stats[j];
      return pad(n, 6) + '  ' + pad(a, 9, true) + ' ' + pad(avg(s.comparisons, s.lookups), 8) + ' ' +
        pad(avg(s.steps, s.lookups), 7) + ' ' + pad(avg(s.keyLines, s.lookups), 10) + ' ' + pad(avg(s.sideLines, s.lookups), 11) + ' ' +
        pad(avg(s.lines, s.lookups), 7) + ' ' + pad(s.maxLines, 10);
    }).join('\n');
    return { text: text, stats: stats, agree: agree, checksum: checksum };
  }

  /** Section 3: the aos / soa rows. */
  function nodeText() {
    var capacity = 255, keys = makeKeys(capacity, 3000);
    var order = keys.slice(), rng = new SplitMix64(3001);
    rng.shuffle(order); // the programs insert in this order; the sorted node is `keys` again
    var soaSearch = new Stats(), aosSearch = new Stats(), soaGet = new Stats(), aosGet = new Stats(), hits = 0;
    // get = lower bound, then the equality check on key i, then (SoA only, on a
    // hit) one read of the child column. See node.zig.
    function get(needle, t, soa) {
      var i = lowerBoundHalving(keys, needle, false, t);
      if (i === capacity) return false;
      t.cmp(i);
      if (keys[i] !== needle) return false;
      if (soa) t.side(i);
      return true;
    }
    for (var i = 0; i < 1000; i++) {
      var needle = rng.chance(1, 2) ? keys[rng.below(capacity)] : rng.below(keys[capacity - 1] + 50);
      var ss = new Trace(8), sa = new Trace(16), ts = new Trace(8), ta = new Trace(16);
      lowerBoundHalving(keys, needle, false, ss);
      lowerBoundHalving(keys, needle, false, sa);
      if (get(needle, ts, true)) hits++;
      get(needle, ta, false);
      soaSearch.add(ss); aosSearch.add(sa); soaGet.add(ts); aosGet.add(ta);
    }
    function row(name, stride, s, g) {
      var bytes = stride * capacity;
      return pad(name, 6, true) + ' ' + pad(stride, 10) + ' ' + pad(bytes, 10) + ' ' + pad(Math.ceil(bytes / 64), 10) + ' | ' +
        pad(avg(s.comparisons, s.lookups), 12) + ' ' + pad(avg(s.lines, s.lookups), 7) + ' | ' +
        pad(avg(g.comparisons, g.lookups), 9) + ' ' + pad(avg(g.keyLines, g.lookups), 10) + ' ' + pad(avg(g.sideLines, g.lookups), 12) + ' ' +
        pad(avg(g.lines, g.lookups), 7) + ' ' + pad(g.maxLines, 10);
    }
    return row('aos', 16, aosSearch, aosGet) + '\n' + row('soa', 8, soaSearch, soaGet) + '\n' +
      'found ' + hits + ' of 1000 needles; both layouts returned the same child every time';
  }

  /** Section 4: prefetch coverage rows for n = 4095. */
  function prefetchText() {
    var n = 4095, index = new Index(makeKeys(n, 1000 + n));
    var names = ['halving', 'halving+prefetch', 'eytzinger', 'eytzinger+prefetch'];
    var stats = names.map(function () { return new Stats(); });
    var rng = new SplitMix64(4000);
    for (var i = 0; i < 1000; i++) {
      var needle = rng.below(index.sorted[n - 1] + 50);
      var ts = [new Trace(), new Trace(), new Trace(), new Trace()];
      lowerBoundHalving(index.sorted, needle, false, ts[0]);
      lowerBoundHalving(index.sorted, needle, true, ts[1]);
      index.eytzinger.lowerBound(needle, false, ts[2]);
      index.eytzinger.lowerBound(needle, true, ts[3]);
      ts.forEach(function (t, j) { stats[j].add(t); });
    }
    return names.map(function (name, j) {
      var s = stats[j];
      return pad(name, 18, true) + ' ' + pad(avg(s.lines, s.lookups), 7) + ' ' +
        pad(avg(s.prefetches, s.lookups), 7) + ' ' + pad(avg(s.uncovered, s.lookups), 17);
    }).join('\n');
  }

  // -------------------------------------------------------------- LineStrip
  /** Draws `cells` as cache lines of `perLine` cells. Elements persist between
   *  renders, so state changes animate through CSS transitions.
   *
   *  render({ key, cells: [{text, sub, free}], perLine, lineLabel(i),
   *           cellState: {i: 'compare'|'found'|'seen'}, read: [lines], hinted: [lines],
   *           fresh: line | null, window: [lo, hi] | null })
   */
  function LineStrip(mount, options) {
    this.options = options || {};
    this.root = BTViz.el('div.cl-strip', { role: 'img' });
    mount.appendChild(this.root);
    this.key = null; this.cells = []; this.lines = [];
  }
  LineStrip.prototype.build = function (state) {
    var el = BTViz.el, self = this;
    this.root.textContent = '';
    this.cells = []; this.lines = [];
    this.root.classList.toggle('cl-wide', state.perLine < 8);
    for (var start = 0; start < state.cells.length; start += state.perLine) {
      var lineNo = start / state.perLine;
      var grid = el('div.cl-cells', { style: { gridTemplateColumns: 'repeat(' + state.perLine + ', minmax(0, 1fr))' } });
      for (var i = start; i < start + state.perLine && i < state.cells.length; i++) {
        var c = state.cells[i];
        var cell = el('div.cl-cell', {}, el('small', { text: String(c.sub) }), el('span', { text: c.text }));
        if (c.free) cell.classList.add('s-free', 'is-free');
        self.cells.push(cell);
        grid.appendChild(cell);
      }
      var badge = el('span.cl-badge');
      var line = el('div.cl-line', {}, el('div.cl-line-head', {}, el('span', { text: 'line ' + lineNo }), badge), grid);
      self.lines.push({ el: line, badge: badge });
      this.root.appendChild(line);
    }
    this.key = state.key;
  };
  LineStrip.prototype.render = function (state) {
    if (state.key !== this.key) this.build(state);
    var read = new Set(state.read || []), hinted = new Set(state.hinted || []);
    var win = state.window, cs = state.cellState || {};
    this.cells.forEach(function (cell, i) {
      var s = cs[i];
      cell.classList.toggle('s-compare', s === 'compare');
      cell.classList.toggle('s-found', s === 'found');
      cell.classList.toggle('is-seen', s === 'seen');
      cell.classList.toggle('is-out', !!win && (i < win[0] || i >= win[1]) && !s);
    });
    this.lines.forEach(function (line, i) {
      var r = read.has(i), h = hinted.has(i);
      line.el.classList.toggle('is-read', r);
      line.el.classList.toggle('is-hinted', h);
      line.el.classList.toggle('is-fresh', state.fresh === i);
      line.badge.textContent = r && h ? 'read, was hinted' : r ? 'read' : h ? 'hinted' : '';
    });
    this.root.setAttribute('aria-label', (state.read || []).length + ' of ' + this.lines.length + ' cache lines read');
  };

  /** A row of tiny squares, one per cache line: which lines did one lookup read? */
  function miniStrip(lineCount, read, hinted) {
    var wrap = BTViz.el('div.cl-mini', { role: 'img', 'aria-label': read.size + ' of ' + lineCount + ' key lines read' });
    for (var i = 0; i < lineCount; i++) {
      var sq = BTViz.el('i');
      if (read.has(i)) sq.className = 'is-read';
      else if (hinted && hinted.has(i)) sq.className = 'is-hinted';
      wrap.appendChild(sq);
    }
    return wrap;
  }

  window.CH25 = {
    LANES: LANES, SENTINEL: SENTINEL, ALGORITHMS: ALGORITHMS,
    SplitMix64: SplitMix64, makeKeys: makeKeys, handKeys: handKeys, Trace: Trace, Index: Index, runOne: runOne,
    lowerBoundLinear: lowerBoundLinear, avg: avg,
    handText: handText, sizeRows: sizeRows, nodeText: nodeText, prefetchText: prefetchText,
    LineStrip: LineStrip, miniStrip: miniStrip
  };
})();

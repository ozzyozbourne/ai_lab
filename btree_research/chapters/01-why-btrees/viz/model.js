/*
 * Chapter 01 model: a JavaScript port of the chapter's Zig/Rust code
 * (zig/src/{cost,sorted_array,bst,wide,height}.zig). The visualization is driven by
 * this model, and index.html checks it against the programs' expected_output.txt with
 * BTViz.selfTest, so the pictures cannot drift from the code.
 *
 * No DOM in this file: it also runs under node (`require('./model.js')`).
 */
(function (root) {
  'use strict';

  var C1 = {};

  /** The guide's canonical keys, in insert order. */
  C1.CANONICAL = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

  /* ------------------------------------------------------------------ height.zig */

  /** Fewest levels of a tree of order m that can hold n keys (every node full). */
  C1.minHeight = function (n, m) {
    var h = 0, capPlusOne = 1;
    while (capPlusOne - 1 < n) { capPlusOne *= m; h++; }
    return h;
  };

  /** Most levels a B-tree of order m (>= 3) can need for n keys (every node as empty as allowed). */
  C1.maxHeight = function (n, m) {
    if (n === 0) return 0;
    var minChildren = Math.ceil(m / 2), h = 1, power = 1;
    while (2 * power * minChildren - 1 <= n) { power *= minChildren; h++; }
    return h;
  };

  /** Largest order whose node ((M-1) entries + M pointers) fits in one page. */
  C1.orderForPage = function (pageBytes, entryBytes, pointerBytes) {
    return Math.floor((pageBytes + entryBytes) / (entryBytes + pointerBytes));
  };

  /* ------------------------------------------------------------ sorted_array.zig */

  /**
   * Binary search (lower bound, then one equality check) over sorted `keys` laid out on
   * pages of `perPage` entries. Returns
   *   {found, index, comparisons, pages: [page ids in first-touch order],
   *    probes: [{index, key, page, fresh, less, lo, hi, final}]}
   * `fresh` is true when the probe is the first one on its page (a page read).
   */
  C1.arraySearch = function (keys, perPage, target) {
    var lo = 0, hi = keys.length, probes = [], pages = [], comparisons = 0;
    function touch(i) {
      var p = Math.floor(i / perPage), fresh = pages.indexOf(p) < 0;
      if (fresh) pages.push(p);
      return { page: p, fresh: fresh };
    }
    while (lo < hi) {
      var mid = lo + Math.floor((hi - lo) / 2), t = touch(mid), less = keys[mid] < target;
      comparisons++;
      var probe = { index: mid, key: keys[mid], page: t.page, fresh: t.fresh, less: less, final: false };
      if (less) lo = mid + 1; else hi = mid;
      probe.lo = lo; probe.hi = hi;
      probes.push(probe);
    }
    var found = false;
    if (lo < keys.length) {
      var f = touch(lo);
      comparisons++;
      found = keys[lo] === target;
      probes.push({ index: lo, key: keys[lo], page: f.page, fresh: f.fresh, less: false, final: true, lo: lo, hi: lo, equal: found });
    }
    return { found: found, index: lo, comparisons: comparisons, pages: pages, probes: probes };
  };

  /** What a put of `key` into sorted `keys` costs: {index, exists, shifted, pagesRewritten, firstPage, lastPage}. */
  C1.arrayPutCost = function (keys, perPage, key) {
    var lo = 0, hi = keys.length;
    while (lo < hi) { var mid = lo + Math.floor((hi - lo) / 2); if (keys[mid] < key) lo = mid + 1; else hi = mid; }
    var exists = lo < keys.length && keys[lo] === key;
    if (exists) return { index: lo, exists: true, shifted: 0, pagesRewritten: 1, firstPage: Math.floor(lo / perPage), lastPage: Math.floor(lo / perPage) };
    var first = Math.floor(lo / perPage), last = Math.floor(keys.length / perPage); // slots [lo, len] are written
    return { index: lo, exists: false, shifted: keys.length - lo, pagesRewritten: last - first + 1, firstPage: first, lastPage: last };
  };

  /* --------------------------------------------------------------------- bst.zig */

  /** Unbalanced binary search tree. Nodes: {id, key, left, right}. */
  function Bst() { this.root = null; this.len = 0; }
  Bst.prototype.put = function (key) {
    var parent = null, cur = this.root, goLeft = false;
    while (cur) {
      if (key === cur.key) return false;
      parent = cur;
      goLeft = key < cur.key;
      cur = goLeft ? cur.left : cur.right;
    }
    var node = { id: 'b' + key, key: key, left: null, right: null };
    if (!parent) this.root = node; else if (goLeft) parent.left = node; else parent.right = node;
    this.len++;
    return true;
  };
  /** {found, path: [node…]}: one comparison and one page read per node on the path. */
  Bst.prototype.search = function (key) {
    var path = [], cur = this.root;
    while (cur) {
      path.push(cur);
      if (key === cur.key) return { found: true, path: path };
      cur = key < cur.key ? cur.left : cur.right;
    }
    return { found: false, path: path };
  };
  Bst.prototype.height = function () {
    var best = 0, stack = this.root ? [[this.root, 1]] : [];
    while (stack.length) {
      var top = stack.pop(), n = top[0], d = top[1];
      if (d > best) best = d;
      if (n.left) stack.push([n.left, d + 1]);
      if (n.right) stack.push([n.right, d + 1]);
    }
    return best;
  };
  C1.Bst = Bst;
  C1.bstFrom = function (keys) { var t = new Bst(); keys.forEach(function (k) { t.put(k); }); return t; };

  /* -------------------------------------------------------------------- wide.zig */

  /**
   * Build the tree that wide.zig only imagines: a balanced, evenly filled tree of order m
   * over sorted `keys`. Nodes are TreeView models: {id, keys, children, leaf}.
   */
  C1.wideBuild = function (keys, m) {
    var counter = 0;
    function build(lo, hi) {
      var size = hi - lo, id = 'w' + (counter++);
      var levels = C1.minHeight(size, m);
      if (levels <= 1) return { id: id, keys: keys.slice(lo, hi), children: [], leaf: true };
      var capPlusOne = Math.pow(m, levels - 1);
      var children = Math.floor((size + capPlusOne) / capPlusOne);
      var below = size - (children - 1), base = Math.floor(below / children), extra = below % children;
      var node = { id: id, keys: [], children: [], leaf: false }, start = lo;
      for (var c = 0; c < children; c++) {
        var len = base + (c < extra ? 1 : 0);
        node.children.push(build(start, start + len));
        if (c < children - 1) node.keys.push(keys[start + len]);
        start += len + 1;
      }
      return node;
    }
    return keys.length ? build(0, keys.length) : null;
  };

  /**
   * Search a tree built by wideBuild exactly like wide.zig's getTraced: scan the separators
   * left to right. Returns {found, comparisons, path: [{node, compared: [keys…], child, hit}]}.
   */
  C1.wideSearch = function (rootNode, target) {
    var path = [], comparisons = 0, node = rootNode;
    while (node) {
      var step = { node: node, compared: [], child: -1, hit: false };
      path.push(step);
      var i, next = null;
      if (node.leaf) {
        for (i = 0; i < node.keys.length; i++) {
          comparisons++;
          step.compared.push(node.keys[i]);
          if (node.keys[i] === target) { step.hit = true; return { found: true, comparisons: comparisons, path: path }; }
          if (node.keys[i] > target) break;
        }
        return { found: false, comparisons: comparisons, path: path };
      }
      for (i = 0; i < node.keys.length; i++) {
        comparisons++;
        step.compared.push(node.keys[i]);
        if (target === node.keys[i]) { step.hit = true; return { found: true, comparisons: comparisons, path: path }; }
        if (target < node.keys[i]) { step.child = i; next = node.children[i]; break; }
      }
      if (!next) { step.child = node.children.length - 1; next = node.children[step.child]; }
      node = next;
    }
    return { found: false, comparisons: comparisons, path: path };
  };

  C1.wideHeight = function (rootNode) { var h = 0; for (var n = rootNode; n; n = n.children[0]) h++; return h; };

  /* -------------------------------------------------------------------- prng.zig */

  /** SplitMix64, bit-identical to common/zig/prng.zig (BigInt arithmetic). */
  function SplitMix64(seed) { this.state = BigInt(seed); }
  var MASK = (1n << 64n) - 1n;
  SplitMix64.prototype.nextU64 = function () {
    this.state = (this.state + 0x9E3779B97F4A7C15n) & MASK;
    var z = this.state;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK;
    return z ^ (z >> 31n);
  };
  SplitMix64.prototype.below = function (n) { return Number((this.nextU64() * BigInt(n)) >> 64n); };
  SplitMix64.prototype.chance = function (num, den) { return this.below(den) < num; };
  SplitMix64.prototype.shuffle = function (items) {
    for (var i = items.length - 1; i >= 1; i--) {
      var j = this.below(i + 1), t = items[i];
      items[i] = items[j]; items[j] = t;
    }
  };
  C1.SplitMix64 = SplitMix64;

  /* ------------------------------------------------ whole key sets (figure 1) */

  /** `n` distinct keys (multiples of 5) in a seeded random order. */
  C1.randomKeys = function (n, seed) {
    var keys = [], i;
    for (i = 0; i < n; i++) keys.push((i + 1) * 5);
    new SplitMix64(seed).shuffle(keys);
    return keys;
  };

  /**
   * Look every key of `arrival` up once in all three structures and count page reads.
   * `bstOrder` is the insert order for the binary search tree (default: `arrival`).
   * Returns {n, array, bst, wide: {sum, avg, max}, fewest, tied, more}: the last three
   * count the keys for which the wide nodes read strictly fewer pages than both other
   * structures, tie with the better of the two, or read more than it.
   */
  C1.raceStats = function (arrival, perPage, bstOrder) {
    var sorted = arrival.slice().sort(function (a, b) { return a - b; });
    var bst = C1.bstFrom(bstOrder || arrival), wide = C1.wideBuild(sorted, perPage + 1);
    function lane() { return { sum: 0, avg: 0, max: 0 }; }
    function add(l, v) { l.sum += v; if (v > l.max) l.max = v; }
    var st = { n: sorted.length, array: lane(), bst: lane(), wide: lane(), fewest: 0, tied: 0, more: 0 };
    sorted.forEach(function (t) {
      var a = C1.arraySearch(sorted, perPage, t), b = bst.search(t), w = C1.wideSearch(wide, t);
      if (!a.found || !b.found || !w.found) throw new Error('structures disagree on ' + t);
      var ra = a.pages.length, rb = b.path.length, rw = w.path.length, other = Math.min(ra, rb);
      add(st.array, ra); add(st.bst, rb); add(st.wide, rw);
      if (rw < other) st.fewest++; else if (rw === other) st.tied++; else st.more++;
    });
    [st.array, st.bst, st.wide].forEach(function (l) { l.avg = st.n ? l.sum / st.n : 0; });
    return st;
  };

  /** Key-set sizes of the "growing key set" chart, and the seed of their random order. */
  C1.SCALE_SIZES = [40, 400, 4000, 40000];
  C1.SCALE_SEED = 7;

  /** raceStats for each size in C1.SCALE_SIZES (random insert order), at `perPage` keys per page. */
  C1.scaleRace = function (perPage) {
    return C1.SCALE_SIZES.map(function (n) { return C1.raceStats(C1.randomKeys(n, C1.SCALE_SEED), perPage); });
  };

  /* ------------------------------------------- main.zig: the text of the scenario */

  function padL(v, w) { return String(v).padStart(w, ' '); }
  function padR(v, w) { return String(v).padEnd(w, ' '); }

  /** Section 1 of expected_output.txt, regenerated by this model. */
  C1.reportHandExample = function () {
    var out = [], ins = C1.CANONICAL, sorted = ins.slice().sort(function (a, b) { return a - b; });
    out.push('== 1. Hand example: 12 keys ==');
    out.push('insert order: ' + ins.join(' '));
    out.push('sorted array: ' + sorted.join(' '));
    var arr = [], moves = 0;
    ins.forEach(function (k) { var c = C1.arrayPutCost(arr, 256, k); moves += c.shifted; arr.splice(c.index, 0, k); });
    out.push('  entries shifted by the 12 puts: ' + moves);
    var a = C1.arraySearch(sorted, 256, 17);
    out.push('  get(17): ' + a.comparisons + ' comparisons, ' + a.pages.length + ' page read');
    var t = C1.bstFrom(ins), s = t.search(17);
    out.push('BST, same insert order: height ' + t.height());
    out.push('  get(17): ' + s.path.length + ' comparisons, ' + s.path.length + ' page reads');
    var chain = C1.bstFrom(sorted), s2 = chain.search(30);
    out.push('BST, ascending insert order: height ' + chain.height());
    out.push('  get(30): ' + s2.path.length + ' comparisons, ' + s2.path.length + ' page reads');
    var w = C1.wideBuild(sorted, 4), ws = C1.wideSearch(w, 17);
    out.push('wide nodes, M = 4 (at most 3 keys per node): height ' + C1.minHeight(sorted.length, 4));
    out.push('  get(17): ' + ws.comparisons + ' comparisons, ' + ws.path.length + ' page reads');
    return out.join('\n') + '\n';
  };

  /** Section 3 of expected_output.txt (100000 keys, 1000 lookups), regenerated by this model. */
  C1.reportRace = function () {
    var N = 100000, LOOKUPS = 1000, keys = [], i;
    for (i = 0; i < N; i++) keys.push((i + 1) * 10);
    var rng = new SplitMix64(2024);
    rng.shuffle(keys);
    var tree = C1.bstFrom(keys);
    var sorted = keys.slice().sort(function (a, b) { return a - b; });
    var m = C1.orderForPage(4096, 16, 8), wide = C1.wideBuild(sorted, m);
    function lane() { return { c: 0, cMax: 0, p: 0, pMax: 0 }; }
    function add(l, c, p) { l.c += c; l.p += p; if (c > l.cMax) l.cMax = c; if (p > l.pMax) l.pMax = p; }
    var A = lane(), T = lane(), W = lane(), found = 0;
    for (i = 0; i < LOOKUPS; i++) {
      var key = rng.chance(1, 2) ? (rng.below(N) + 1) * 10 : rng.below(N * 10 + 10);
      var a = C1.arraySearch(sorted, 256, key), t = tree.search(key), w = C1.wideSearch(wide, key);
      if (a.found !== t.found || a.found !== w.found) throw new Error('structures disagree on ' + key);
      if (a.found) found++;
      add(A, a.comparisons, a.pages.length);
      add(T, t.path.length, t.path.length);
      add(W, w.comparisons, w.path.length);
    }
    function avg(total) { var h = Math.floor(total * 100 / LOOKUPS); return ' ' + padL(Math.floor(h / 100), 5) + '.' + String(h % 100).padStart(2, '0'); }
    function row(name, l) { return padR(name, 28) + avg(l.c) + ' ' + padL(l.cMax, 8) + avg(l.p) + ' ' + padL(l.pMax, 8); }
    return [
      '== 3. Race: ' + N + ' keys, ' + LOOKUPS + ' lookups ==',
      'lookups that found their key: ' + found,
      '                               comparisons      page reads',
      'structure                      avg      max     avg      max',
      row('sorted array, 256 per page', A),
      row('BST, random insert order', T),
      row('wide nodes, M = ' + m, W),
      'heights: BST ' + tree.height() + ', wide nodes ' + C1.wideHeight(wide) + '; the sorted array spans ' + Math.ceil(N / 256) + ' pages'
    ].join('\n') + '\n';
  };

  /** Section 5 of expected_output.txt, regenerated by this model. */
  C1.reportHeights = function () {
    var out = ['== 5. Height calculator: page reads per lookup ==',
      '          keys   binary best   M = 4 best   worst   M = 171 best   worst'];
    for (var n = 1000; n <= 1e12; n *= 1000) {
      out.push(padL(n, 14) + ' ' + padL(C1.minHeight(n, 2), 13) + ' ' + padL(C1.minHeight(n, 4), 12) + ' ' + padL(C1.maxHeight(n, 4), 7) +
        ' ' + padL(C1.minHeight(n, 171), 14) + ' ' + padL(C1.maxHeight(n, 171), 7));
    }
    return out.join('\n') + '\n';
  };

  root.C1 = C1;
  if (typeof module !== 'undefined' && module.exports) module.exports = C1;
})(typeof window !== 'undefined' ? window : globalThis);

/*
 * Chapter 29 — JavaScript models shared by the three visualization pages.
 *
 * Everything here mirrors zig/src/*.zig and rust/src/*.rs: the same SplitMix64
 * (BigInt, so the 64-bit arithmetic is exact), the same data generators, the
 * same integer k-means and the same (dist, id) tie-break. The pages check the
 * models against expected_output.txt with BTViz.selfTest.
 *
 * Also runs under node: `const Ch29 = require('./model.js')`.
 */
(function (root) {
  'use strict';

  /* ---------------------------------------------------------------- PRNG */
  var MASK = (1n << 64n) - 1n;
  function SplitMix64(seed) { this.s = BigInt(seed) & MASK; }
  SplitMix64.prototype.next = function () {
    this.s = (this.s + 0x9E3779B97F4A7C15n) & MASK;
    var z = this.s;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK;
    return z ^ (z >> 31n);
  };
  /** Integer in [0, n): top 64 bits of next() * n, as in common/prng. */
  SplitMix64.prototype.below = function (n) { return Number((this.next() * BigInt(n)) >> 64n); };
  SplitMix64.prototype.range = function (lo, hi) { return lo + this.below(hi - lo); };
  SplitMix64.prototype.shuffle = function (a) {
    for (var i = a.length - 1; i >= 1; i--) {
      var j = this.below(i + 1), t = a[i]; a[i] = a[j]; a[j] = t;
    }
  };

  /* ------------------------------------------------------------ zone map */
  var OPS = { eq: '=', ne: '!=', lt: '<', le: '<=', gt: '>', ge: '>=' };

  function verdict(all, some) { return all ? 'always_true' : some ? 'maybe' : 'always_false'; }
  /** Three-way test of `v <op> c` against a zone {min, max}. */
  function checkZone(z, op, c) {
    var inside = z.min <= c && c <= z.max, single = z.min === c && z.max === c;
    switch (op) {
      case 'eq': return verdict(single, inside);
      case 'ne': return verdict(!inside, !single);
      case 'ge': return verdict(z.min >= c, z.max >= c);
      case 'gt': return verdict(z.min > c, z.max > c);
      case 'le': return verdict(z.max <= c, z.min <= c);
      case 'lt': return verdict(z.max < c, z.min < c);
    }
    throw new Error('bad op ' + op);
  }
  function andPrune(a, b) {
    if (a === 'always_false' || b === 'always_false') return 'always_false';
    return a === 'always_true' && b === 'always_true' ? 'always_true' : 'maybe';
  }
  function compare(v, op, c) {
    switch (op) {
      case 'eq': return v === c; case 'ne': return v !== c;
      case 'lt': return v < c; case 'le': return v <= c;
      case 'gt': return v > c; case 'ge': return v >= c;
    }
    throw new Error('bad op ' + op);
  }
  /** filter: {op, c} or {op: 'between', lo, hi} (both ends inclusive). */
  function filterMatches(f, v) { return f.op === 'between' ? f.lo <= v && v <= f.hi : compare(v, f.op, f.c); }
  function filterCheck(f, z) {
    return f.op === 'between' ? andPrune(checkZone(z, 'ge', f.lo), checkZone(z, 'le', f.hi)) : checkZone(z, f.op, f.c);
  }
  function filterText(f) { return f.op === 'between' ? f.lo + ' <= v <= ' + f.hi : 'v ' + OPS[f.op] + ' ' + f.c; }
  /** Why a verdict holds, in words (used for captions). */
  function explain(f, z) {
    var r = 'min ' + z.min + ', max ' + z.max;
    var v = filterCheck(f, z), t = filterText(f);
    if (v === 'always_false') return r + ': no value in that range can satisfy ' + t;
    if (v === 'always_true') return r + ': every value in that range satisfies ' + t;
    return r + ': some values in that range satisfy ' + t + ' and some do not';
  }

  function ZoneMap(chunkSize) { this.chunkSize = chunkSize; this.values = []; this.zones = []; }
  ZoneMap.prototype.append = function (v) {
    this.values.push(v);
    var last = this.zones[this.zones.length - 1];
    if (last && last.count < this.chunkSize) {
      last.min = Math.min(last.min, v); last.max = Math.max(last.max, v); last.count++;
    } else this.zones.push({ min: v, max: v, count: 1 });
  };
  ZoneMap.prototype.chunk = function (i) {
    return this.values.slice(i * this.chunkSize, i * this.chunkSize + this.zones[i].count);
  };
  /** Scan with pruning. Returns totals plus one record per chunk. */
  ZoneMap.prototype.scan = function (f) {
    var s = { skipped: 0, all: 0, scanned: 0, rowsCompared: 0, matches: 0, chunks: [] }, self = this;
    this.zones.forEach(function (z, i) {
      var v = filterCheck(f, z), m = 0;
      if (v === 'always_false') s.skipped++;
      else if (v === 'always_true') { s.all++; m = z.count; }
      else {
        s.scanned++; s.rowsCompared += z.count;
        self.chunk(i).forEach(function (x) { if (filterMatches(f, x)) m++; });
      }
      s.matches += m;
      s.chunks.push({ verdict: v, matches: m });
    });
    return s;
  };

  var ZONE = { rows: 2000, chunk: 100, seed: 29 };
  var LAYOUTS = ['sorted', 'arrival', 'shuffled'];
  function buildLayout(layout, chunkSize) {
    var zm = new ZoneMap(chunkSize || ZONE.chunk), rng = new SplitMix64(ZONE.seed), i;
    if (layout === 'sorted') for (i = 0; i < ZONE.rows; i++) zm.append(i);
    else if (layout === 'arrival') for (i = 0; i < ZONE.rows; i++) zm.append(i + rng.below(300));
    else {
      var vs = [];
      for (i = 0; i < ZONE.rows; i++) vs.push(i);
      rng.shuffle(vs);
      vs.forEach(function (v) { zm.append(v); });
    }
    return zm;
  }
  var ZONE_FILTERS = [
    { op: 'eq', c: 777 }, { op: 'ge', c: 1500 }, { op: 'lt', c: 250 },
    { op: 'between', lo: 400, hi: 449 }, { op: 'ne', c: 777 }
  ];

  function pad(v, w, left) {
    var s = String(v);
    while (s.length < w) s = left ? s + ' ' : ' ' + s;
    return s;
  }
  /** The 15 table rows of section 1 of expected_output.txt. */
  function zoneReport() {
    var out = [];
    LAYOUTS.forEach(function (layout) {
      var zm = buildLayout(layout);
      ZONE_FILTERS.forEach(function (f) {
        var s = zm.scan(f);
        out.push(pad(layout, 9, true) + ' ' + pad(filterText(f).replace('v eq', 'v ='), 15, true) + ' ' + pad(s.skipped, 5) + ' ' +
          pad(s.all, 4) + ' ' + pad(s.scanned, 5) + ' ' + pad(s.rowsCompared, 14) + ' ' + pad(s.matches, 8));
      });
    });
    return out.join('\n');
  }

  /* ------------------------------------------------------------------ IVF */
  function dist2(a, b) {
    var s = 0;
    for (var i = 0; i < a.length; i++) { var d = a[i] - b[i]; s += d * d; }
    return s;
  }
  function hitLess(a, b) { return a.dist !== b.dist ? a.dist < b.dist : a.id < b.id; }
  function hitCmp(a, b) { return hitLess(a, b) ? -1 : hitLess(b, a) ? 1 : 0; }
  /** Offer a hit to a sorted top-k array (mutates `out`). */
  function topkOffer(out, k, hit) {
    if (out.length === k && !hitLess(hit, out[k - 1])) return;
    var i = out.length < k ? out.length : k - 1;
    while (i > 0 && hitLess(hit, out[i - 1])) { out[i] = out[i - 1]; i--; }
    out[i] = hit;
  }
  /** Brute force: exact k nearest of `points` (array of coordinate arrays). */
  function flatSearch(points, q, k) {
    var out = [];
    points.forEach(function (p, id) { topkOffer(out, k, { dist: dist2(p, q), id: id }); });
    return out;
  }
  function nearestCentroid(cents, v) {
    var best = { dist: Infinity, id: 0 };
    cents.forEach(function (c, i) { var h = { dist: dist2(c, v), id: i }; if (hitLess(h, best)) best = h; });
    return best.id;
  }
  /**
   * Integer k-means, the same steps as Ivf.build. Returns the index and, in
   * `history`, the centroids and assignment after every assignment step.
   */
  function buildIvf(points, nlist, seed, maxIter) {
    var n = points.length, dim = points[0].length, i, j, c;
    var perm = [];
    for (i = 0; i < n; i++) perm.push(i);
    new SplitMix64(seed).shuffle(perm);
    var cents = [];
    for (c = 0; c < nlist; c++) cents.push(points[perm[c]].slice());
    var assign = new Array(n).fill(-1), iterations = 0, history = [];
    for (;;) {
      var changed = 0;
      for (i = 0; i < n; i++) {
        c = nearestCentroid(cents, points[i]);
        if (assign[i] !== c) changed++;
        assign[i] = c;
      }
      history.push({ centroids: cents.map(function (x) { return x.slice(); }), assign: assign.slice(), changed: changed });
      if (changed === 0 || iterations === maxIter) break;
      var sums = [], counts = new Array(nlist).fill(0);
      for (c = 0; c < nlist; c++) sums.push(new Array(dim).fill(0));
      for (i = 0; i < n; i++) { counts[assign[i]]++; for (j = 0; j < dim; j++) sums[assign[i]][j] += points[i][j]; }
      for (c = 0; c < nlist; c++) {
        if (!counts[c]) continue;
        for (j = 0; j < dim; j++) cents[c][j] = Math.floor((2 * sums[c][j] + counts[c]) / (2 * counts[c]));
      }
      iterations++;
    }
    var lists = [];
    for (c = 0; c < nlist; c++) lists.push([]);
    assign.forEach(function (cc, id) { lists[cc].push(id); });
    return { points: points, nlist: nlist, centroids: cents, assign: assign, lists: lists, iterations: iterations, history: history };
  }
  function rankLists(index, q) {
    return index.centroids.map(function (c, i) { return { dist: dist2(c, q), id: i }; }).sort(hitCmp);
  }
  /** nprobe search. Returns {order, probes: [{list, scanned, top}], top, scanned}. */
  function ivfSearch(index, q, nprobe, k) {
    var order = rankLists(index, q), top = [], scanned = 0, probes = [];
    order.slice(0, Math.min(nprobe, index.nlist)).forEach(function (l) {
      index.lists[l.id].forEach(function (id) { scanned++; topkOffer(top, k, { dist: dist2(index.points[id], q), id: id }); });
      probes.push({ list: l.id, scanned: index.lists[l.id].length, top: top.slice() });
    });
    return { order: order, probes: probes, top: top, scanned: scanned };
  }
  function overlap(got, want) {
    return got.filter(function (g) { return want.some(function (w) { return w.id === g.id; }); }).length;
  }

  var IVF = { n: 240, nlist: 8, k: 5, nq: 24, blobs: 6, spread: 110, jitter: 40, blobSeed: 2901, trainSeed: 2902, querySeed: 2903, maxIter: 50 };
  function clamp(v) { return v < 0 ? 0 : v > 999 ? 999 : v; }
  function genBlobs(seed, n, blobs, spread) {
    var rng = new SplitMix64(seed), centres = [], pts = [], i, j;
    for (i = 0; i < blobs * 2; i++) centres.push(rng.range(150, 850));
    for (i = 0; i < n; i++) {
      var p = [];
      for (j = 0; j < 2; j++) {
        var off = rng.below(spread + 1) + rng.below(spread + 1);
        p.push(clamp(centres[(i % blobs) * 2 + j] + off - spread));
      }
      pts.push(p);
    }
    return pts;
  }
  function genNearData(seed, pts, nq, jitter) {
    var rng = new SplitMix64(seed), qs = [];
    for (var q = 0; q < nq; q++) {
      var src = rng.below(pts.length), p = [];
      for (var j = 0; j < 2; j++) p.push(clamp(pts[src][j] + rng.below(2 * jitter + 1) - jitter));
      qs.push(p);
    }
    return qs;
  }
  var scenarioCache = null;
  /** The 2-D scenario of section 3: {points, queries, index}. */
  function ivfScenario() {
    if (!scenarioCache) {
      var points = genBlobs(IVF.blobSeed, IVF.n, IVF.blobs, IVF.spread);
      scenarioCache = {
        points: points,
        queries: genNearData(IVF.querySeed, points, IVF.nq, IVF.jitter),
        index: buildIvf(points, IVF.nlist, IVF.trainSeed, IVF.maxIter)
      };
    }
    return scenarioCache;
  }
  /** Section 3 of expected_output.txt, regenerated by the JS model. */
  function ivfReport() {
    var s = ivfScenario(), ix = s.index, out = [];
    out.push('== 3. IVF in 2 dimensions: ' + IVF.n + ' points, ' + IVF.nlist + ' lists, k = ' + IVF.k + ', ' + IVF.nq + ' queries ==');
    out.push('k-means: assignments stopped changing after ' + ix.iterations + ' centroid updates');
    out.push('list  size  centroid');
    ix.centroids.forEach(function (c, i) { out.push(pad(i, 4) + ' ' + pad(ix.lists[i].length, 5) + '  (' + c[0] + ', ' + c[1] + ')'); });
    out.push('nprobe  vectors scanned  of brute force  true neighbours found  recall');
    [1, 2, 3, 4, 8].forEach(function (nprobe) {
      var scanned = 0, found = 0;
      s.queries.forEach(function (q) {
        var r = ivfSearch(ix, q, nprobe, IVF.k);
        scanned += r.scanned;
        found += overlap(r.top, flatSearch(s.points, q, IVF.k));
      });
      var total = IVF.nq * IVF.k;
      out.push(pad(nprobe, 6) + ' ' + pad(scanned, 16) + ' ' + pad(IVF.nq * IVF.n, 15) + ' ' + pad(found, 15) + ' / ' + pad(total, 4, true) + ' ' +
        pad(Math.floor(found * 100 / total), 6) + '%');
    });
    for (var q = 0; q < s.queries.length; q++) {
      var query = s.queries[q], best = flatSearch(s.points, query, 1)[0], order = rankLists(ix, query), home = ix.assign[best.id];
      if (home === order[0].id) continue;
      var rank = 0;
      while (order[rank].id !== home) rank++;
      out.push('first miss: query ' + q + ' at (' + query[0] + ', ' + query[1] + ')');
      out.push('  true nearest: id ' + best.id + ' at (' + s.points[best.id][0] + ', ' + s.points[best.id][1] + '), dist2 ' + best.dist + ', stored in list ' + home);
      out.push('  nearest centroid: list ' + order[0].id + ' (dist2 ' + order[0].dist + '); list ' + home + ' ranks ' + (rank + 1) + ' (dist2 ' + order[rank].dist + ')');
      out.push('  so nprobe must be at least ' + (rank + 1) + ' to find it');
      break;
    }
    return out.join('\n');
  }

  /**
   * Voronoi cell of centroid `c` clipped to box = [x0, y0, x1, y1], as a polygon.
   * Used only for drawing (floating point is fine here).
   */
  function voronoiCell(cents, c, box) {
    var poly = [[box[0], box[1]], [box[2], box[1]], [box[2], box[3]], [box[0], box[3]]], a = cents[c];
    cents.forEach(function (b, j) {
      if (j === c || !poly.length || (a[0] === b[0] && a[1] === b[1])) return;
      // Keep the side of the bisector where the point is nearer to a than to b.
      var nx = b[0] - a[0], ny = b[1] - a[1], lim = (b[0] * b[0] + b[1] * b[1] - a[0] * a[0] - a[1] * a[1]) / 2;
      var out = [];
      for (var i = 0; i < poly.length; i++) {
        var p = poly[i], q = poly[(i + 1) % poly.length];
        var dp = p[0] * nx + p[1] * ny - lim, dq = q[0] * nx + q[1] * ny - lim;
        if (dp <= 0) out.push(p);
        if ((dp < 0 && dq > 0) || (dp > 0 && dq < 0)) {
          var t = dp / (dp - dq);
          out.push([p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1])]);
        }
      }
      poly = out;
    });
    return poly;
  }

  /* ----------------------------------------------------- HNSW-like graph */
  /**
   * A small layered proximity graph in the spirit of HNSW. Not the real
   * construction algorithm: every point is simply linked to its nearest
   * points on each layer it belongs to (2*M on layer 0, M above), and the
   * links are made symmetric. Levels are drawn like a skip list: promote
   * with probability 1/M, as HNSW does with levelMult = 1 / ln(M).
   */
  function buildLayered(o) {
    var rng = new SplitMix64(o.seed), nodes = [], i, l;
    for (i = 0; i < o.n; i++) {
      var level = 0;
      var x = rng.range(20, o.width - 20), y = rng.range(20, o.height - 20);
      while (level < o.maxLevel && rng.below(o.m) === 0) level++;
      nodes.push({ id: i, x: x, y: y, level: level });
    }
    var layers = [];
    for (l = 0; l <= o.maxLevel; l++) {
      var members = nodes.filter(function (nd) { return nd.level >= l; });
      var want = l === 0 ? 2 * o.m : o.m, adj = {};
      members.forEach(function (a) { adj[a.id] = []; });
      members.forEach(function (a) {
        members.filter(function (b) { return b !== a; })
          .map(function (b) { return { dist: dist2([a.x, a.y], [b.x, b.y]), id: b.id }; })
          .sort(hitCmp).slice(0, want)
          .forEach(function (h) {
            if (adj[a.id].indexOf(h.id) < 0) adj[a.id].push(h.id);
            if (adj[h.id].indexOf(a.id) < 0) adj[h.id].push(a.id);
          });
      });
      layers.push({ level: l, members: members.map(function (m) { return m.id; }), adj: adj });
    }
    var top = o.maxLevel;
    while (top > 0 && !layers[top].members.length) top--;
    return { nodes: nodes, layers: layers, maxLevel: top, entry: layers[top].members[0], opts: o };
  }
  /**
   * Search: greedy on the upper layers, then a best-first search with `ef`
   * candidates on layer 0. Returns {result, truth, trace}; each trace event is
   * one thing a reader should see.
   */
  function layeredSearch(g, q, ef) {
    var d = function (id) { return dist2([g.nodes[id].x, g.nodes[id].y], q); };
    var trace = [], cur = g.entry, dcur = d(cur), computed = 1, l;
    trace.push({ type: 'enter', level: g.maxLevel, node: cur, dist: dcur });
    for (l = g.maxLevel; l >= 1; l--) {
      for (;;) {
        var nbrs = g.layers[l].adj[cur], best = cur, dbest = dcur;
        nbrs.forEach(function (id) { var dd = d(id); if (dd < dbest || (dd === dbest && id < best)) { best = id; dbest = dd; } });
        computed += nbrs.length;
        if (best === cur) { trace.push({ type: 'stuck', level: l, node: cur, nbrs: nbrs, dist: dcur }); break; }
        trace.push({ type: 'move', level: l, from: cur, to: best, nbrs: nbrs, dist: dbest });
        cur = best; dcur = dbest;
      }
      trace.push({ type: 'drop', level: l - 1, node: cur, dist: dcur });
    }
    // Layer 0: candidates C (to expand) and results W (best ef so far).
    var visited = {}, C = [{ dist: dcur, id: cur }], W = [{ dist: dcur, id: cur }];
    visited[cur] = true;
    while (C.length) {
      C.sort(hitCmp);
      var c = C.shift(), far = W[W.length - 1];
      if (hitLess(far, c)) { trace.push({ type: 'stop', level: 0, node: c.id, W: W.slice(), far: far.id }); break; }
      var fresh = [];
      g.layers[0].adj[c.id].forEach(function (id) {
        if (visited[id]) return;
        visited[id] = true; computed++;
        var h = { dist: d(id), id: id };
        fresh.push(id);
        if (W.length < ef || hitLess(h, W[W.length - 1])) {
          C.push(h); W.push(h); W.sort(hitCmp);
          if (W.length > ef) W.pop();
        }
      });
      trace.push({ type: 'expand', level: 0, node: c.id, fresh: fresh, W: W.slice(), visited: Object.keys(visited).map(Number) });
    }
    if (!trace.length || trace[trace.length - 1].type !== 'stop') trace.push({ type: 'stop', level: 0, node: null, W: W.slice(), far: null });
    var truth = flatSearch(g.nodes.map(function (nd) { return [nd.x, nd.y]; }), q, 1)[0];
    return { result: W[0], truth: truth, trace: trace, computed: computed };
  }
  var HNSW = { n: 56, m: 2, maxLevel: 2, width: 1000, height: 520, seed: 2907 };

  var Ch29 = {
    SplitMix64: SplitMix64, OPS: OPS,
    checkZone: checkZone, andPrune: andPrune, filterMatches: filterMatches, filterCheck: filterCheck,
    filterText: filterText, explain: explain, ZoneMap: ZoneMap, ZONE: ZONE, LAYOUTS: LAYOUTS,
    buildLayout: buildLayout, ZONE_FILTERS: ZONE_FILTERS, zoneReport: zoneReport,
    dist2: dist2, flatSearch: flatSearch, buildIvf: buildIvf, rankLists: rankLists, ivfSearch: ivfSearch,
    overlap: overlap, IVF: IVF, ivfScenario: ivfScenario, ivfReport: ivfReport, voronoiCell: voronoiCell,
    buildLayered: buildLayered, layeredSearch: layeredSearch, HNSW: HNSW
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = Ch29;
  root.Ch29 = Ch29;
})(typeof window !== 'undefined' ? window : globalThis);

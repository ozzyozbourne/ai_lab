/*
 * Chapter 14: the JavaScript twin of zig/src/split.zig, pages.zig and report.zig.
 * Same algorithm, same integer arithmetic, same PRNG draw order, so that the page
 * shows exactly what the programs print (index.html checks this with BTViz.selfTest).
 * Runs in the browser (global `SplitModel`) and under node (`require('./model.js')`).
 */
(function (root) {
  'use strict';

  /* ---------------- SplitMix64 (common/zig/prng.zig), on BigInt ---------------- */
  var M64 = (1n << 64n) - 1n;
  function SplitMix64(seed) { this.state = BigInt(seed) & M64; }
  SplitMix64.prototype.next = function () {
    this.state = (this.state + 0x9E3779B97F4A7C15n) & M64;
    var z = this.state;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & M64;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & M64;
    return z ^ (z >> 31n);
  };
  /* Integer in [0, n): top 64 bits of the 128-bit product. */
  SplitMix64.prototype.below = function (n) { return Number((this.next() * BigInt(n)) >> 64n); };
  SplitMix64.prototype.range = function (lo, hi) { return lo + this.below(hi - lo); };
  SplitMix64.prototype.shuffle = function (items) {
    for (var i = items.length - 1; i >= 1; i--) {
      var j = this.below(i + 1), t = items[i];
      items[i] = items[j];
      items[j] = t;
    }
  };

  /* ---------------- split.zig ---------------- */
  var SINGLE_VALUE_FILL = 96;

  /* Policy: {kind: 'half' | 'fill' | 'rightmost' | 'adaptive', ff: percent}. */
  function policyLabel(p) { return p.kind === 'half' ? 'half' : p.kind + '-' + p.ff; }

  /* Step 1: every gap whose two sides both fit, in page order. */
  function candidates(items, capacity) {
    var total = 0, left = 0, out = [], i;
    for (i = 0; i < items.length; i++) total += items[i].size;
    for (i = 0; i + 1 < items.length; i++) {
      left += items[i].size;
      var right = total - left;
      if (left <= capacity && right <= capacity) out.push({ firstRight: i + 1, left: left, right: right, delta: 0 });
    }
    return out;
  }
  /* fill === null: equal free space. Otherwise the left page should be fill% full. */
  function deltaOf(c, capacity, fill) {
    var lf = capacity - c.left, rf = capacity - c.right;
    return Math.abs(fill === null ? lf - rf : fill * lf - (100 - fill) * rf);
  }
  /* Step 2: best balance first; ties go to the leftmost gap. */
  function deltaSort(cands, capacity, fill) {
    cands.forEach(function (c) { c.delta = deltaOf(c, capacity, fill); });
    cands.sort(function (a, b) { return a.delta - b.delta || a.firstRight - b.firstRight; });
  }
  /* 1: bare-key separator; 2: the separator needs a tid. */
  function penaltyOf(items, c) { return items[c.firstRight - 1].key !== items[c.firstRight].key ? 1 : 2; }
  function defaultInterval(cands, tolerance) {
    for (var i = 1; i < cands.length; i++) {
      if (Math.abs(cands[i].left - cands[0].left) > tolerance || Math.abs(cands[i].right - cands[0].right) > tolerance) return i;
    }
    return cands.length;
  }
  function firstDistinct(items, cands, n) {
    for (var i = 0; i < n; i++) if (penaltyOf(items, cands[i]) === 1) return i;
    return -1;
  }
  function targetFill(policy, isRightmost) {
    if (policy.kind === 'half') return null;
    if (policy.kind === 'fill') return policy.ff;
    return isRightmost ? policy.ff : null;
  }

  /*
   * Decide where to cut. page = {capacity, upperKey: number | null}.
   * Returns the choice plus a `trace` of the intermediate results, which the
   * step-by-step figure turns into captions.
   */
  function chooseSplit(items, newIndex, page, policy) {
    var cands = candidates(items, page.capacity);
    var leftmost = cands[0], rightmost = cands[cands.length - 1];
    var isRightmost = page.upperKey === null;
    var fill = targetFill(policy, isRightmost);
    deltaSort(cands, page.capacity, fill);

    var pick = 0, strategy = 'default', interval = 1;
    var trace = { fill: fill, order: cands.map(function (c) { return c.firstRight; }), tolerance: null, defaultInterval: null, reason: 'space' };
    if (policy.kind === 'adaptive') {
      var oldBytes = leftmost.left + leftmost.right - items[newIndex].size;
      trace.tolerance = Math.floor(oldBytes / 20);
      interval = defaultInterval(cands, trace.tolerance);
      trace.defaultInterval = cands.slice(0, interval).map(function (c) { return c.firstRight; });
      var i = firstDistinct(items, cands, interval);
      if (i >= 0) {
        pick = i;
        trace.reason = 'default-distinct';
      } else if (items[leftmost.firstRight - 1].key !== items[rightmost.firstRight].key) {
        strategy = 'many_duplicates';
        interval = cands.length;
        pick = firstDistinct(items, cands, cands.length);
        trace.reason = 'many-duplicates';
      } else if (isRightmost || page.upperKey !== items[newIndex].key) {
        strategy = 'single_value';
        deltaSort(cands, page.capacity, SINGLE_VALUE_FILL);
        interval = 1;
        trace.reason = 'single-value';
        trace.fill = SINGLE_VALUE_FILL;
      } else trace.reason = 'run-continues';
    }
    var c = cands[pick];
    return { firstRight: c.firstRight, left: c.left, right: c.right, penalty: penaltyOf(items, c), strategy: strategy, interval: interval, trace: trace };
  }

  /* ---------------- pages.zig (insert only) ---------------- */
  function sepAtOrBelow(sep, key, tid) { return sep.key !== key ? sep.key < key : (sep.tid === null || sep.tid <= tid); }

  function Tree(capacity, policy) {
    this.capacity = capacity;
    this.policy = policy;
    this.leaves = [{ cells: [], used: 0 }];
    this.dir = [{ low: null, leaf: 0 }];
    this.len = 0;
    this.stats = { splits: 0, byStrategy: { default: 0, many_duplicates: 0, single_value: 0 } };
    this.lastSplit = null;   // {d, choice} of the most recent split, for captions
  }
  Tree.prototype.findDir = function (key, tid) {
    var lo = 1, hi = this.dir.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (sepAtOrBelow(this.dir[mid].low, key, tid)) lo = mid + 1; else hi = mid;
    }
    return lo - 1;
  };
  function lowerBound(cells, key, tid) {
    var lo = 0, hi = cells.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1, c = cells[mid];
      if (c.key < key || (c.key === key && c.tid < tid)) lo = mid + 1; else hi = mid;
    }
    return lo;
  }
  /* Returns true if the insert caused a split. */
  Tree.prototype.put = function (key, tid, size) {
    var d = this.findDir(key, tid), leaf = this.leaves[this.dir[d].leaf];
    var i = lowerBound(leaf.cells, key, tid), cell = { key: key, tid: tid, size: size };
    this.len++;
    if (leaf.used + size <= this.capacity) {
      leaf.cells.splice(i, 0, cell);
      leaf.used += size;
      return false;
    }
    var items = leaf.cells.slice();
    items.splice(i, 0, cell);
    var upperKey = d + 1 < this.dir.length ? this.dir[d + 1].low.key : null;
    var choice = chooseSplit(items, i, { capacity: this.capacity, upperKey: upperKey }, this.policy);
    var fr = choice.firstRight;
    this.leaves.push({ cells: items.slice(fr), used: choice.right });
    leaf.cells = items.slice(0, fr);
    leaf.used = choice.left;
    this.dir.splice(d + 1, 0, { low: { key: items[fr].key, tid: choice.penalty === 1 ? null : items[fr].tid }, leaf: this.leaves.length - 1 });
    this.stats.splits++;
    this.stats.byStrategy[choice.strategy]++;
    this.lastSplit = { d: d, choice: choice };
    return true;
  };
  /* Bytes used per page, in key order. */
  Tree.prototype.usedList = function () {
    var self = this;
    return this.dir.map(function (e) { return self.leaves[e.leaf].used; });
  };
  Tree.prototype.fill = function () {
    var f = { pages: 0, usedBytes: 0, minUsed: this.capacity, histogram: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], sepBytes: 0, tidSeps: 0 };
    for (var d = 0; d < this.dir.length; d++) {
      var used = this.leaves[this.dir[d].leaf].used, low = this.dir[d].low;
      f.pages++;
      f.usedBytes += used;
      f.minUsed = Math.min(f.minUsed, used);
      f.histogram[Math.min(9, Math.floor(used * 10 / this.capacity))]++;
      if (low) { f.sepBytes += low.tid === null ? 8 : 16; if (low.tid !== null) f.tidSeps++; }
    }
    f.avgPermille = Math.floor(f.usedBytes * 1000 / (f.pages * this.capacity));
    return f;
  };

  /* ---------------- report.zig ---------------- */
  var PAGE_CAPACITY = 4096;
  var WORKLOADS = ['ascending', 'random', 'dup-groups', 'dup-heavy'];
  var POLICIES = [{ kind: 'half', ff: 90 }, { kind: 'fill', ff: 90 }, { kind: 'rightmost', ff: 90 }, { kind: 'adaptive', ff: 90 }];

  /* The inserts of a workload as [{key, tid, size}], in arrival order. */
  function workloadOps(workload, n, seed) {
    var rng = new SplitMix64(seed), order = null, ops = [], i;
    if (workload === 'random') {
      order = [];
      for (i = 0; i < n; i++) order.push(i);
      rng.shuffle(order);
    }
    for (i = 0; i < n; i++) {
      var key = workload === 'ascending' ? i
        : workload === 'random' ? order[i]
        : workload === 'dup-groups' ? rng.below(Math.floor(n / 8))
        : rng.below(Math.floor(n / 1000) + 2);
      ops.push({ key: key, tid: i, size: rng.range(40, 121) });
    }
    return ops;
  }
  function runWorkload(workload, policy, n, seed) {
    var tree = new Tree(PAGE_CAPACITY, policy);
    workloadOps(workload, n, seed).forEach(function (op) { tree.put(op.key, op.tid, op.size); });
    return tree;
  }
  function pad(s, w) { s = String(s); while (s.length < w) s += ' '; return s; }
  function padLeft(s, w) { s = String(s); while (s.length < w) s = ' ' + s; return s; }

  /* Part 3 of expected_output.txt, without its headline. */
  function scenarioText(n, seed) {
    var out = '';
    WORKLOADS.forEach(function (w) {
      out += 'workload ' + w + '\n';
      POLICIES.forEach(function (p) {
        out += '  ' + pad(policyLabel(p), 13) + ' ' + runWorkload(w, p, n, seed).usedList().join(' ') + '\n';
      });
    });
    return out;
  }

  var HAND = {
    capacity: 100,
    newIndex: 5,
    items: [
      { key: 10, tid: 1, size: 18 }, { key: 20, tid: 1, size: 14 }, { key: 20, tid: 2, size: 14 },
      { key: 20, tid: 3, size: 14 }, { key: 20, tid: 4, size: 14 }, { key: 20, tid: 5, size: 12 },
      { key: 30, tid: 1, size: 20 }
    ]
  };
  /* The "choice when ..." lines of part 1 of expected_output.txt. */
  function handChoicesText(upperKey) {
    return POLICIES.map(function (p) {
      var c = chooseSplit(HAND.items, HAND.newIndex, { capacity: HAND.capacity, upperKey: upperKey }, p);
      return '  ' + pad(policyLabel(p), 13) + ' s=' + c.firstRight + '  left ' + padLeft(c.left, 2) + '  right ' + padLeft(c.right, 2) +
        '  separator ' + padLeft(8 * c.penalty, 2) + ' bytes  ' + c.strategy + '\n';
    }).join('');
  }

  var api = {
    SplitMix64: SplitMix64, SINGLE_VALUE_FILL: SINGLE_VALUE_FILL, PAGE_CAPACITY: PAGE_CAPACITY,
    WORKLOADS: WORKLOADS, POLICIES: POLICIES, HAND: HAND,
    policyLabel: policyLabel, candidates: candidates, deltaOf: deltaOf, penaltyOf: penaltyOf, targetFill: targetFill,
    chooseSplit: chooseSplit, Tree: Tree, workloadOps: workloadOps, runWorkload: runWorkload,
    scenarioText: scenarioText, handChoicesText: handChoicesText
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.SplitModel = api;
})(typeof window !== 'undefined' ? window : globalThis);

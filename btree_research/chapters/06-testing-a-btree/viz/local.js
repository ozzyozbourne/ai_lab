/* Chapter 06, chapter-local model: a JavaScript port of the chapter's fuzzer.
 *
 * Everything here mirrors zig/src (and rust/src) function for function, so
 * that the page reproduces the SAME seeds, steps and reproducers that
 * `zig build run` / `cargo run` print (index.html checks this with
 * BTViz.selfTest against ../expected_output.txt):
 *
 *   SplitMix64, opStream   common/zig/prng.zig, common/zig/ops.zig
 *   Tree                   base_insert.zig, base_delete.zig, base_validate.zig
 *                          (with the three fault seams of base_btree.zig `Bug`)
 *   swarm, generate,
 *   replay, huntShortest   fuzz.zig
 *   minimize               minimize.zig
 *
 * 64-bit arithmetic uses BigInt; values stay BigInt. Keys are handled as
 * their small INDEX k (a Number in [0, keySpace)): every key layout of the
 * fuzzer is strictly increasing in k, so a tree built from the indices has
 * exactly the shape and the answers of the tree built from the real 64-bit
 * keys. Only when a key is shown is the index turned into the real key
 * (`keyNamer`): exactly, as the programs print it, or in a compact form such
 * as 2^64 - 38 for the drawing. A classic script: defines window.Fuzz06.
 */
(function () {
  'use strict';
  var MASK = (1n << 64n) - 1n;

  /* ------------------------------------------------------------ SplitMix64 */
  function SplitMix64(seed) { this.state = BigInt.asUintN(64, BigInt(seed)); }
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
    for (var i = items.length; i > 1;) {
      i -= 1;
      var j = this.below(i + 1), t = items[i];
      items[i] = items[j]; items[j] = t;
    }
  };

  /* ------------------------------------------------- cases and generation */
  function swarm(seed) {
    var prng = new SplitMix64(seed);
    var keySpace = [4, 16, 64, 256][prng.below(4)];
    var count = 64 << prng.below(4);
    var put = 1 + prng.below(8);
    var del = prng.chance(1, 4) ? 0 : 1 + prng.below(8);
    var get = prng.chance(1, 2) ? 0 : 1 + prng.below(4);
    var range = prng.chance(1, 2) ? 0 : 1 + prng.below(2);
    var faultOneIn = [0, 0, 8, 2][prng.below(4)];
    var drain = prng.chance(1, 2);
    var streamSeed = prng.nextU64();
    var auxSeed = prng.nextU64();
    var keyLayout = prng.below(4);
    return { seed: seed, count: count, keySpace: keySpace, keyLayout: keyLayout,
             weights: { put: put, del: del, get: get, range: range },
             faultOneIn: faultOneIn, drain: drain, streamSeed: streamSeed, auxSeed: auxSeed };
  }

  /* fuzz.zig `KeyLayout`: where in the 64-bit key space the keys of a case lie. */
  var LAYOUTS = ['from 0', 'around 2^32', 'spread over u64', 'below 2^64'];
  var SUP = { '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴', '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹' };
  function pow2(n) { return '2' + String(n).replace(/[0-9]/g, function (d) { return SUP[d]; }); }

  /* The real key for index k, as a BigInt (`KeyLayout.key`). k may equal
   * keySpace: the exclusive upper bound of a range. */
  function realKey(c, k) {
    var ks = BigInt(c.keySpace), i = BigInt(k);
    if (c.keyLayout === 0) return i;
    if (c.keyLayout === 1) return (1n << 32n) - ks / 2n + i;
    if (c.keyLayout === 2) { var v = i * ((1n << 64n) / ks); return v > MASK ? MASK : v; }
    return MASK - ks + i;
  }
  /* The same key, short enough for a tree node: 2³²+5, 27·2⁵⁸, 2⁶⁴−38. */
  function shortKey(c, k) {
    if (c.keyLayout === 0) return String(k);
    if (c.keyLayout === 1) {
      var d = k - c.keySpace / 2;
      return pow2(32) + (d === 0 ? '' : d > 0 ? '+' + d : '−' + (-d));
    }
    if (c.keyLayout === 2) {
      if (k === 0) return '0';
      if (k === c.keySpace) return pow2(64) + '−1';
      return k + '·' + pow2(64 - Math.log2(c.keySpace));
    }
    return pow2(64) + '−' + (c.keySpace + 1 - k);
  }
  /* A function index -> text for the keys of `steps`. Steps made by
   * `generate` remember their case; a minimised reproducer has none (its
   * keys were renamed 1, 2, 3, ...) and prints as it is. */
  function keyNamer(steps, exact) {
    var c = steps.kase;
    if (!c) return String;
    return exact ? function (k) { return String(realKey(c, k)); } : function (k) { return shortKey(c, k); };
  }

  function describeCase(c) {
    return 'seed ' + c.seed + ': ' + c.count + ' ops on ' + c.keySpace + ' keys ' + LAYOUTS[c.keyLayout] + ', put:delete:get:range = ' +
      c.weights.put + ':' + c.weights.del + ':' + c.weights.get + ':' + c.weights.range + ', ' +
      (c.faultOneIn === 0 ? 'no faults' : 'fault in 1 of ' + c.faultOneIn + ' puts') +
      ', drain ' + (c.drain ? 'yes' : 'no');
  }

  /* Steps: {kind: 'put'|'delete'|'get'|'range', key, value (BigInt), lo, hi, fault (null | n)}.
   * key, lo and hi are key INDICES (see the note at the top of this file). */
  function generate(c) {
    var steps = [], alive = new Set();
    var aux = new SplitMix64(c.auxSeed), s = new SplitMix64(c.streamSeed);
    var w = c.weights, total = w.put + w.del + w.get + w.range;
    for (var n = 0; n < c.count; n++) {
      var r = s.below(total), step;
      if (r < w.put) {
        step = { kind: 'put', key: s.below(c.keySpace), value: s.nextU64(), fault: null };
        if (c.faultOneIn > 0 && aux.chance(1, c.faultOneIn)) step.fault = aux.below(3);
        alive.add(step.key);
      } else if ((r -= w.put) < w.del) {
        step = { kind: 'delete', key: s.below(c.keySpace), fault: null };
        alive.delete(step.key);
      } else if ((r -= w.del) < w.get) {
        step = { kind: 'get', key: s.below(c.keySpace), fault: null };
      } else {
        var a = s.below(c.keySpace), b = s.below(c.keySpace);
        step = { kind: 'range', lo: Math.min(a, b), hi: Math.max(a, b) + 1, fault: null };
      }
      steps.push(step);
    }
    if (c.drain) {
      var keys = Array.from(alive).sort(function (x, y) { return x - y; });
      aux.shuffle(keys);
      keys.forEach(function (key) { steps.push({ kind: 'delete', key: key, fault: null }); });
    }
    steps.kase = c;
    return steps;
  }

  function stepText(st, name) {
    name = name || String;
    var t = st.kind === 'put' ? 'put ' + name(st.key) + ' = ' + st.value
          : st.kind === 'range' ? 'range [' + name(st.lo) + ', ' + name(st.hi) + ')'
          : st.kind + ' ' + name(st.key);
    return st.fault === null ? t : t + ' (node allocation ' + st.fault + ' fails first)';
  }

  /* ------------------------------------------------------------- the tree */
  var BUGS = ['split_wrong_value', 'merge_leaks_node', 'borrow_forgets_child'];

  function Tree(order, bug) {
    this.order = order; this.bug = bug || 'none';
    this.maxKeys = order - 1; this.minKeys = Math.ceil(order / 2) - 1;
    this.root = null; this.len = 0;
    this.nextId = 1; this.live = 0;          // the pool's counters
    this.failAfter = null;                   // node-allocation fault switch
    this.leaked = [];                        // nodes the tree lost track of (for drawing only)
    this.events = [];                        // what the last operation did, in words
  }
  Tree.prototype.alloc = function (leaf) {
    if (this.failAfter !== null) {
      if (this.failAfter === 0) return null;
      this.failAfter -= 1;
    }
    this.live += 1;
    return { id: this.nextId++, leaf: leaf, keys: [], vals: [], children: [] };
  };
  Tree.prototype.free = function () { this.live -= 1; };

  function lowerBound(keys, key) {
    var lo = 0, hi = keys.length;
    while (lo < hi) { var mid = (lo + hi) >> 1; if (keys[mid] < key) lo = mid + 1; else hi = mid; }
    return lo;
  }

  Tree.prototype.get = function (key) {
    var node = this.root;
    while (node) {
      var i = lowerBound(node.keys, key);
      if (i < node.keys.length && node.keys[i] === key) return node.vals[i];
      if (node.leaf) return null;
      node = node.children[i];
    }
    return null;
  };

  /* Returns {ok: true, old} or {ok: false} (out of nodes; tree unchanged). */
  Tree.prototype.put = function (key, value) {
    this.events = [];
    if (!this.root) {
      var leaf = this.alloc(true);
      if (!leaf) return { ok: false };
      leaf.keys.push(key); leaf.vals.push(value);
      this.root = leaf; this.len = 1;
      return { ok: true, old: null };
    }
    var path = [], node = this.root;
    for (;;) {
      var i = lowerBound(node.keys, key);
      if (i < node.keys.length && node.keys[i] === key) {
        var old = node.vals[i]; node.vals[i] = value;
        this.events.push('overwrite');
        return { ok: true, old: old };
      }
      path.push({ node: node, index: i });
      if (node.leaf) break;
      node = node.children[i];
    }
    // Reserve: one node per full node in the unbroken run from the leaf up.
    var depth = path.length, need = 0;
    while (need < depth && path[depth - 1 - need].node.keys.length === this.maxKeys) need++;
    if (need === depth) need++;
    var spare = [], liveBefore = this.live, idBefore = this.nextId;
    for (var r = 0; r < need; r++) {
      var n = this.alloc(true);
      if (!n) { this.live = liveBefore; this.nextId = idBefore; return { ok: false }; }
      spare.push(n);
    }
    // Commit.
    var level = depth - 1, used = 0;
    path[level].node.keys.splice(path[level].index, 0, key);
    path[level].node.vals.splice(path[level].index, 0, value);
    this.len += 1;
    while (path[level].node.keys.length > this.maxKeys) {
      var left = path[level].node, right = spare[used++];
      var mid = left.keys.length >> 1;
      right.leaf = left.leaf;
      right.keys = left.keys.splice(mid + 1);
      right.vals = left.vals.splice(mid + 1);
      if (!left.leaf) right.children = left.children.splice(mid + 1);
      var medianVal = left.vals.pop(), medianKey = left.keys.pop();
      if (this.bug === 'split_wrong_value') medianVal = left.vals[mid - 1];      // SEAM
      this.events.push('split');
      if (level === 0) {
        var top = spare[used++];
        top.leaf = false; top.keys = [medianKey]; top.vals = [medianVal]; top.children = [left, right];
        this.root = top;
        this.events.push('root split');
        break;
      }
      level -= 1;
      var parent = path[level].node, at = path[level].index;
      parent.children.splice(at + 1, 0, right);
      parent.keys.splice(at, 0, medianKey);
      parent.vals.splice(at, 0, medianVal);
    }
    return { ok: true, old: null };
  };

  Tree.prototype.delete = function (key) {
    this.events = [];
    var removed = this.root ? this.removeFrom(this.root, key) : null;
    if (removed === null) return null;
    var root = this.root;
    this.len -= 1;
    if (root.keys.length === 0) {
      this.root = root.leaf ? null : root.children[0];
      this.free();
      this.events.push(this.root ? 'root shrink' : 'tree emptied');
    }
    return removed;
  };
  Tree.prototype.removeFrom = function (node, key) {
    var i = lowerBound(node.keys, key);
    var found = i < node.keys.length && node.keys[i] === key;
    if (node.leaf) {
      if (!found) return null;
      node.keys.splice(i, 1);
      return node.vals.splice(i, 1)[0];
    }
    var removed;
    if (found) {
      removed = node.vals[i];
      var pred = this.removeMax(node.children[i]);
      node.keys[i] = pred.key; node.vals[i] = pred.value;
      this.events.push('predecessor');
    } else {
      removed = this.removeFrom(node.children[i], key);
      if (removed === null) return null;
    }
    this.fixUnderflow(node, i);
    return removed;
  };
  Tree.prototype.removeMax = function (node) {
    if (node.leaf) return { key: node.keys.pop(), value: node.vals.pop() };
    var last = node.keys.length;
    var entry = this.removeMax(node.children[last]);
    this.fixUnderflow(node, last);
    return entry;
  };
  Tree.prototype.fixUnderflow = function (parent, i) {
    var child = parent.children[i], min = this.minKeys;
    if (child.keys.length >= min) return;
    var level = child.leaf ? 'leaf' : 'interior';
    var keepChild = this.bug !== 'borrow_forgets_child';                          // SEAM
    if (i > 0 && parent.children[i - 1].keys.length > min) {
      var left = parent.children[i - 1], sep = i - 1;
      var upKey = left.keys.pop(), upVal = left.vals.pop();
      var moved = left.leaf ? null : left.children.pop();
      child.keys.unshift(parent.keys[sep]); child.vals.unshift(parent.vals[sep]);
      parent.keys[sep] = upKey; parent.vals[sep] = upVal;
      if (moved) { if (keepChild) child.children.unshift(moved); else this.leaked.push(moved); }
      this.events.push('borrow from left (' + level + ')');
    } else if (i + 1 < parent.children.length && parent.children[i + 1].keys.length > min) {
      var right = parent.children[i + 1];
      var upK = right.keys.shift(), upV = right.vals.shift();
      var movedR = right.leaf ? null : right.children.shift();
      child.keys.push(parent.keys[i]); child.vals.push(parent.vals[i]);
      parent.keys[i] = upK; parent.vals[i] = upV;
      if (movedR) { if (keepChild) child.children.push(movedR); else this.leaked.push(movedR); }
      this.events.push('borrow from right (' + level + ')');
    } else {
      var at = i > 0 ? i - 1 : i;
      var l = parent.children[at], r = parent.children[at + 1];
      var sepKey = parent.keys.splice(at, 1)[0], sepVal = parent.vals.splice(at, 1)[0];
      parent.children.splice(at + 1, 1);
      l.keys.push(sepKey); l.vals.push(sepVal);
      l.keys = l.keys.concat(r.keys); l.vals = l.vals.concat(r.vals); l.children = l.children.concat(r.children);
      if (this.bug === 'merge_leaks_node') this.leaked.push({ id: r.id, leaf: true, keys: [], vals: [], children: [] }); // SEAM
      else this.free();
      this.events.push('merge (' + level + ')');
    }
  };

  /* base_validate.zig: null when sound, else {error, depth, firstKey}. */
  Tree.prototype.validate = function () {
    var self = this, count = 0, leafDepth = null, nodes = 0;
    function fail(error, depth, node) {
      return { error: error, depth: depth, firstKey: node && node.keys.length ? node.keys[0] : null, node: node ? node.id : null };
    }
    function check(node, lo, hi, depth) {
      nodes += 1;
      if (node.keys.length > self.maxKeys) return fail('NodeOverfull', depth, node);
      if (depth > 0 && node.keys.length < self.minKeys) return fail('NodeUnderfull', depth, node);
      count += node.keys.length;
      for (var i = 0; i < node.keys.length; i++) {
        var key = node.keys[i];
        if (i > 0 && node.keys[i - 1] >= key) return fail('KeysOutOfOrder', depth, node);
        if ((lo !== null && key <= lo) || (hi !== null && key >= hi)) return fail('KeyOutsideParentBounds', depth, node);
      }
      var want = node.leaf ? 0 : node.keys.length + 1;
      if (node.children.length < want) return fail('MissingChild', depth, node);
      if (node.children.length > want) return fail('UnexpectedChild', depth, node);
      if (node.leaf) {
        if (leafDepth !== null && leafDepth !== depth) return fail('LeavesAtDifferentDepths', depth, node);
        leafDepth = depth;
      }
      for (var c = 0; c < node.children.length; c++) {
        var bad = check(node.children[c], c === 0 ? lo : node.keys[c - 1], c === node.keys.length ? hi : node.keys[c], depth + 1);
        if (bad) return bad;
      }
      return null;
    }
    if (this.root) {
      if (this.root.keys.length === 0) return fail('EmptyRoot', 0, null);
      var bad = check(this.root, null, null, 0);
      if (bad) return bad;
    }
    if (count !== this.len) return fail('WrongKeyCount', 0, null);
    if (nodes !== this.live) return fail('NodeCountMismatch', 0, null);
    return null;
  };

  Tree.prototype.entries = function (lo, hi) {
    var out = [];
    (function walk(node) {
      if (!node) return;
      for (var i = 0; i <= node.keys.length; i++) {
        if (!node.leaf) walk(node.children[i]);
        if (i < node.keys.length && node.keys[i] >= lo && node.keys[i] < hi) out.push([node.keys[i], node.vals[i]]);
      }
    })(this.root);
    return out;
  };
  Tree.prototype.shape = function () {
    var s = { height: 0, nodes: 0, keys: 0 };
    for (var n = this.root; n; n = n.leaf ? null : n.children[0]) s.height++;
    (function walk(node) { if (!node) return; s.nodes++; s.keys += node.keys.length; node.children.forEach(walk); })(this.root);
    return s;
  };
  /* A BTViz.TreeView model. Leaked nodes are drawn as extra roots. */
  Tree.prototype.snapshot = function () {
    function snap(node) {
      return { id: 'n' + node.id, keys: node.keys.slice(), leaf: node.leaf, children: node.children.map(snap) };
    }
    if (!this.root && !this.leaked.length) return null;
    var roots = this.root ? [snap(this.root)] : [];
    this.leaked.forEach(function (node) {
      var s = snap(node);
      s.id = 'lost' + node.id; s.meta = { label: 'unreachable', state: 'deleted' };
      roots.push(s);
    });
    return roots.length === 1 ? roots[0] : roots;
  };

  /* --------------------------------------------------------------- oracle */
  function Oracle() { this.map = new Map(); }
  Oracle.prototype.get = function (key) { return this.map.has(key) ? this.map.get(key) : null; };
  Oracle.prototype.put = function (key, value) { var old = this.get(key); this.map.set(key, value); return old; };
  Oracle.prototype.delete = function (key) { var old = this.get(key); this.map.delete(key); return old; };
  Oracle.prototype.entries = function (lo, hi) {
    return Array.from(this.map.entries())
      .filter(function (e) { return e[0] >= lo && e[0] < hi; })
      .sort(function (a, b) { return a[0] - b[0]; });
  };
  function sameEntries(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) if (a[i][0] !== b[i][0] || a[i][1] !== b[i][1]) return false;
    return true;
  }

  /* --------------------------------------------------------------- replay */
  var KIND_TEXT = {
    wrong_result: 'wrong result (answer differs from the oracle)',
    wrong_contents: 'wrong contents (full scan differs from the oracle)',
    oom_changed_tree: 'a failed put changed the tree or its node accounting'
  };
  function failureText(f, name) {
    if (f.kind !== 'invariant') return KIND_TEXT[f.kind];
    return 'invariant ' + f.error + (f.firstKey === null ? '' : ' at depth ' + f.depth + ' (node starts with key ' + (name || String)(f.firstKey) + ')');
  }
  function sameKind(a, b) { return a.kind === b.kind && (a.kind !== 'invariant' || a.error === b.error); }

  /* Replays `steps`; returns {failure | null, frames?}. With `record`, one
   * frame per step is kept for the page: what was asked, both answers, the
   * verdicts and a drawable snapshot of both structures. */
  function replay(order, bug, steps, opts) {
    opts = opts || {};
    var checkValidate = opts.validate !== false, checkModel = opts.model !== false, sweepEvery = 16;
    var tree = new Tree(order, bug), oracle = new Oracle(), frames = opts.record ? [] : null;
    var failure = null, injected = 0, maxHeight = 0, maxKeys = 0, done = 0;
    for (var i = 0; i < steps.length && !failure; i++) {
      var st = steps[i], treeAnswer, oracleAnswer, ok = true, verdict = null, oom = false;
      if (st.kind === 'put') {
        tree.failAfter = st.fault;
        var res = tree.put(st.key, st.value);
        tree.failAfter = null;
        if (!res.ok) {
          injected += 1; oom = true;
          if ((checkValidate && tree.validate()) || tree.len !== oracle.map.size || tree.get(st.key) !== oracle.get(st.key)) {
            verdict = { kind: 'oom_changed_tree' };
          } else res = tree.put(st.key, st.value);
        }
        if (!verdict) {
          treeAnswer = res.old; oracleAnswer = oracle.put(st.key, st.value);
          ok = treeAnswer === oracleAnswer;
        }
      } else if (st.kind === 'delete') {
        treeAnswer = tree.delete(st.key); oracleAnswer = oracle.delete(st.key); ok = treeAnswer === oracleAnswer;
      } else if (st.kind === 'get') {
        treeAnswer = tree.get(st.key); oracleAnswer = oracle.get(st.key); ok = treeAnswer === oracleAnswer;
      } else {
        treeAnswer = tree.entries(st.lo, st.hi); oracleAnswer = oracle.entries(st.lo, st.hi);
        ok = sameEntries(treeAnswer, oracleAnswer);
      }
      var violation = null, swept = false;
      if (!verdict && checkModel && !ok) verdict = { kind: 'wrong_result' };
      if (!verdict && checkValidate) {
        violation = tree.validate();
        if (violation) verdict = { kind: 'invariant', error: violation.error, depth: violation.depth, firstKey: violation.firstKey, node: violation.node };
      }
      if (!verdict && checkModel) {
        if (tree.len !== oracle.map.size) verdict = { kind: 'wrong_contents' };
        else if (i + 1 === steps.length || (i + 1) % sweepEvery === 0) {
          swept = true;
          if (!sameEntries(tree.entries(0, Infinity), oracle.entries(0, Infinity))) verdict = { kind: 'wrong_contents' };
        }
      }
      if (verdict) { verdict.step = i; failure = verdict; }
      if (frames) {
        var bad = !!violation && violation.error !== 'NodeCountMismatch' && violation.error !== 'WrongKeyCount';
        frames.push({
          index: i, step: st, events: tree.events.slice(), oom: oom,
          treeAnswer: treeAnswer, oracleAnswer: oracleAnswer, answerOk: ok, swept: swept,
          tree: tree.snapshot(), treeEntries: bad ? null : tree.entries(0, Infinity),
          oracleEntries: oracle.entries(0, Infinity),
          live: tree.live, reachable: tree.shape().nodes, len: tree.len, failure: failure
        });
      }
      done = i + 1;
      if (!failure) { var sh = tree.shape(); maxHeight = Math.max(maxHeight, sh.height); maxKeys = Math.max(maxKeys, sh.keys); }
    }
    return { failure: failure, frames: frames, injected: injected, maxHeight: maxHeight, maxKeys: maxKeys, steps: done };
  }

  var stepCache = {};
  function stepsOf(seed) { return stepCache[seed] || (stepCache[seed] = generate(swarm(seed))); }

  function huntShortest(order, bug, firstSeed, seeds) {
    var census = { failingSeeds: 0, shortest: null };
    for (var seed = firstSeed; seed < firstSeed + seeds; seed++) {
      var f = replay(order, bug, stepsOf(seed)).failure;
      if (!f) continue;
      census.failingSeeds += 1;
      if (!census.shortest || f.step < census.shortest.failure.step) census.shortest = { seed: seed, failure: f };
    }
    return census;
  }

  /* ------------------------------------------------------------- minimize */
  function minimize(order, bug, original, target) {
    var current = original.slice(0, target.step + 1), failure = target, replays = 0;
    function accept(candidate) {
      replays += 1;
      var f = replay(order, bug, candidate).failure;
      if (!f || !sameKind(f, target)) return false;
      current = candidate.slice(0, f.step + 1); failure = f;
      return true;
    }
    function tryWithout(start, end) { return accept(current.slice(0, start).concat(current.slice(end))); }
    // Fast reduction: aligned chunks, halving.
    for (var chunk = Math.max(current.length >> 1, 1); ; chunk >>= 1) {
      for (var i = 0; i < current.length;) { if (!tryWithout(i, i + chunk)) i += chunk; }
      if (chunk === 1) break;
    }
    // Exhaustive finish: every contiguous block, longest first, until a whole
    // round removes nothing.
    for (var again = true; again;) {
      again = false;
      var n = current.length;
      for (var len = n - 1; len >= 1 && !again; len--) {
        for (var start = 0; start + len <= n && !again; start++) again = tryWithout(start, start + len);
      }
    }
    function copy() { return current.map(function (s) { return Object.assign({}, s); }); }
    // 1. forget injected faults
    var c = copy(); c.forEach(function (s) { s.fault = null; }); accept(c);
    // 2. rename keys 1, 2, 3, ... in order
    var seen = [];
    current.forEach(function (s) { if (s.kind === 'range') seen.push(s.lo, s.hi); else seen.push(s.key); });
    var distinct = Array.from(new Set(seen)).sort(function (a, b) { return a - b; });
    function rank(x) { return lowerBound(distinct, x) + 1; }
    c = copy();
    c.forEach(function (s) { if (s.kind === 'range') { s.lo = rank(s.lo); s.hi = rank(s.hi); } else s.key = rank(s.key); });
    accept(c);
    // 3. the n-th put writes n
    c = copy(); var n = 0;
    c.forEach(function (s) { if (s.kind === 'put') { n += 1; s.value = BigInt(n); } });
    accept(c);
    return { steps: current, failure: failure, replays: replays };
  }

  window.Fuzz06 = {
    BUGS: BUGS, SplitMix64: SplitMix64, swarm: swarm, describeCase: describeCase, generate: generate, stepsOf: stepsOf,
    stepText: stepText, keyNamer: keyNamer, realKey: realKey, shortKey: shortKey, Tree: Tree, replay: replay, huntShortest: huntShortest, minimize: minimize,
    failureText: failureText, sameKind: sameKind
  };
})();

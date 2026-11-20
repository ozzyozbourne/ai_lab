/*
 * Chapter 16 local helper (the shared toolkit has no component that shows
 * half-built levels with empty slots, so this file adds one).
 *
 *   1. A JS port of the chapter's programs: Tree (put), BulkLoader, report().
 *      report() reproduces expected_output.txt byte for byte; index.html
 *      checks that with BTViz.selfTest, so the picture cannot drift from the
 *      Zig and Rust code.
 *   2. bulkSteps(): the loader again, emitting one captioned snapshot per event.
 *   3. LevelView: draws a snapshot as rows of pages (needs the DOM and BTViz).
 *
 * Parts 1 and 2 also run under node: `const Ch16 = require('./local.js')`.
 */
(function (root) {
  'use strict';

  var NIL = -1;

  /* ====================================================================
   * 1. Model: same structure and same names as zig/src/bptree.zig
   * ================================================================== */

  function Tree(order) {
    this.order = order;
    this.nodes = [];      // {leaf, keys: [], slots: [], next}
    this.root = NIL;
    this.height = 0;
    this.count = 0;
    this.stats = { writes: 0, reads: 0, splits: 0 };
  }
  Tree.prototype.leafCap = function () { return this.order - 1; };
  Tree.prototype.innerCap = function () { return this.order; };
  Tree.prototype.leafMin = function () { return Math.max(1, Math.ceil(this.order / 2) - 1); };
  Tree.prototype.innerMin = function () { return Math.ceil(this.order / 2); };
  Tree.prototype.cap = function (leaf) { return leaf ? this.leafCap() : this.innerCap(); };
  Tree.prototype.min = function (leaf) { return leaf ? this.leafMin() : this.innerMin(); };
  Tree.prototype.allocNode = function (leaf) {
    this.nodes.push({ leaf: leaf, keys: [], slots: [], next: NIL });
    return this.nodes.length - 1;
  };
  function childIndex(node, key) {
    var i = 1;
    while (i < node.keys.length && node.keys[i] <= key) i++;
    return i - 1;
  }
  function lowerBound(node, key) {
    var i = 0;
    while (i < node.keys.length && node.keys[i] < key) i++;
    return i;
  }
  /** One-by-one insert with a 50/50 split, counting page reads, writes and splits. */
  Tree.prototype.put = function (key, value) {
    var nodes = this.nodes, st = this.stats;
    if (this.root === NIL) {
      var id0 = this.allocNode(true);
      nodes[id0].keys.push(key); nodes[id0].slots.push(value);
      this.root = id0; this.height = 1; this.count = 1; st.writes++;
      return;
    }
    var path = [], idx = [], id = this.root;
    for (;;) {
      path.push(id); st.reads++;
      var n = nodes[id];
      if (n.leaf) break;
      var ci = childIndex(n, key);
      idx.push(ci);
      id = n.slots[ci];
    }
    var leaf = nodes[id], pos = lowerBound(leaf, key);
    if (pos < leaf.keys.length && leaf.keys[pos] === key) { leaf.slots[pos] = value; st.writes++; return; }
    leaf.keys.splice(pos, 0, key); leaf.slots.splice(pos, 0, value);
    this.count++;
    var d = path.length - 1;
    for (;;) {
      var nodeId = path[d], node = nodes[nodeId];
      if (node.keys.length <= this.cap(node.leaf)) { st.writes++; return; }
      var keep = node.keys.length - Math.floor(node.keys.length / 2);
      var rightId = this.allocNode(node.leaf), right = nodes[rightId];
      right.keys = node.keys.splice(keep); right.slots = node.slots.splice(keep);
      if (node.leaf) { right.next = node.next; node.next = rightId; }
      st.writes += 2; st.splits++;
      var sep = right.keys[0];
      if (d === 0) {
        var r = this.allocNode(false);
        nodes[r].keys = [0, sep]; nodes[r].slots = [nodeId, rightId];
        this.root = r; this.height++; st.writes++;
        return;
      }
      d--;
      var parent = nodes[path[d]];
      parent.keys.splice(idx[d] + 1, 0, sep); parent.slots.splice(idx[d] + 1, 0, rightId);
    }
  };
  Tree.prototype.get = function (key) {
    if (this.root === NIL) return null;
    var n = this.nodes[this.root];
    while (!n.leaf) n = this.nodes[n.slots[childIndex(n, key)]];
    var pos = lowerBound(n, key);
    return pos < n.keys.length && n.keys[pos] === key ? n.slots[pos] : null;
  };
  /**
   * Experiment 3 of the programs: `count` random puts of keys that are in
   * neither the loaded set (multiples of 10) nor drawn before. Same stream as
   * report.zig / report.rs.
   */
  function randomInserts(tree, n, count) {
    var rng = SplitMix64(1616);
    function draw() { var hi = rng.below(n); return hi * 10 + 1 + rng.below(9); }
    for (var j = 0; j < count; j++) {
      var key = draw();
      while (tree.get(key) !== null) key = draw();
      tree.put(key, j);
    }
  }
  Tree.prototype.shape = function () {
    var s = { height: this.height, leaves: 0, inner: 0, entries: 0, pages: 0 }, nodes = this.nodes;
    if (this.root === NIL) return s;
    (function walk(id) {
      var n = nodes[id];
      if (n.leaf) { s.leaves++; s.entries += n.keys.length; } else { s.inner++; n.slots.forEach(walk); }
    })(this.root);
    s.pages = s.leaves + s.inner;
    return s;
  };
  /** Node ids per level, top level first. */
  Tree.prototype.levelIds = function () {
    var out = [], cur = this.root === NIL ? [] : [this.root], nodes = this.nodes;
    while (cur.length) {
      out.push(cur);
      var next = [];
      cur.forEach(function (id) { if (!nodes[id].leaf) next = next.concat(nodes[id].slots); });
      cur = next;
    }
    return out;
  };

  function fillTarget(cap, min, percent) {
    return Math.min(cap, Math.max(min, Math.floor(cap * percent / 100)));
  }

  /**
   * The bottom-up loader of zig/src/bulk.zig. `emit(kind, info)` is called
   * after every event so that bulkSteps() can take snapshots; the logic does
   * not depend on it.
   */
  function BulkLoader(tree, options, emit) {
    this.tree = tree;
    this.leafTarget = fillTarget(tree.leafCap(), tree.leafMin(), options.leafFill);
    this.innerTarget = fillTarget(tree.innerCap(), tree.innerMin(), options.innerFill);
    this.levels = [];     // {buf: [{key, slot}], pending, sealed, ids: [], written: {}}
    this.emit = emit || function () {};
  }
  BulkLoader.prototype.target = function (level) { return level === 0 ? this.leafTarget : this.innerTarget; };
  BulkLoader.prototype.add = function (key, value) {
    this.addPair(0, { key: key, slot: value });
    this.tree.count++;
  };
  BulkLoader.prototype.addPair = function (level, pair) {
    var started = false;
    if (level === this.levels.length) {
      this.levels.push({ buf: [], pending: NIL, sealed: 0, ids: [], written: {} });
      started = true;
    }
    if (this.levels[level].buf.length === this.target(level)) this.closeOpenPage(level, pair);
    this.levels[level].buf.push(pair);
    this.emit('push', { level: level, pair: pair, started: started });
  };
  BulkLoader.prototype.closeOpenPage = function (level, incoming) {
    var id = this.copyOut(level), lv = this.levels[level], old = lv.pending;
    lv.pending = id;
    lv.buf = [];                       // reset(.retain_capacity)
    this.emit('close', { level: level, id: id, incoming: incoming, old: old });
    if (old !== NIL) {
      if (level === 0) this.tree.nodes[old].next = id;
      this.seal(level, old);
    }
  };
  BulkLoader.prototype.copyOut = function (level) {
    var id = this.tree.allocNode(level === 0), node = this.tree.nodes[id], lv = this.levels[level];
    lv.buf.forEach(function (p) { node.keys.push(p.key); node.slots.push(p.slot); });
    lv.ids.push(id);
    return id;
  };
  /**
   * `from` says which call site sealed the page, so that the code panel can
   * light up the lines that really ran: undefined = closeOpenPage; in
   * finish, 'pending' (the pending page, before the last page of its level),
   * 'last' (the last page) or 'only' (the pending page is itself the last).
   */
  BulkLoader.prototype.seal = function (level, id, from) {
    this.tree.stats.writes++;
    this.levels[level].sealed++;
    this.levels[level].written[id] = true;
    this.emit('seal', { level: level, id: id, from: from });
    this.addPair(level + 1, { key: this.tree.nodes[id].keys[0], slot: id });
  };
  BulkLoader.prototype.finish = function () {
    var tree = this.tree;
    this.emit('end', {});
    for (var level = 0; level < this.levels.length; level++) {
      var lv = this.levels[level], leaf = level === 0, min = tree.min(leaf);
      if (lv.pending !== NIL && lv.buf.length < min) {
        var left = tree.nodes[lv.pending], total = left.keys.length + lv.buf.length;
        if (total <= tree.cap(leaf)) {
          lv.buf.forEach(function (p) { left.keys.push(p.key); left.slots.push(p.slot); });
          // Empty the buffer BEFORE the snapshot (bulk.zig sets lv.len = 0 in
          // this branch): the moved pairs must not be drawn in both pages.
          var appended = lv.buf.length;
          lv.buf = [];
          this.emit('merge', { level: level, id: lv.pending, moved: appended });
        } else {
          var keep = total - Math.floor(total / 2), moved = [];
          for (var i = keep; i < left.keys.length; i++) moved.push({ key: left.keys[i], slot: left.slots[i] });
          left.keys.length = keep; left.slots.length = keep;
          lv.buf = moved.concat(lv.buf);
          this.emit('share', { level: level, id: lv.pending, moved: moved.length });
        }
      }
      var pagesLeft = (lv.pending !== NIL ? 1 : 0) + (lv.buf.length > 0 ? 1 : 0);
      if (lv.sealed === 0 && pagesLeft === 1) {
        var rootId = lv.pending !== NIL ? lv.pending : this.copyOut(level);
        lv.buf = [];
        lv.pending = NIL;
        lv.written[rootId] = true;
        tree.stats.writes++;
        tree.root = rootId;
        tree.height = level + 1;
        this.emit('root', { level: level, id: rootId });
        return;
      }
      var pending = lv.pending;
      if (lv.buf.length > 0) {
        var id = this.copyOut(level);
        lv.buf = [];
        this.emit('last', { level: level, id: id });
        if (pending !== NIL) {
          if (leaf) tree.nodes[pending].next = id;
          this.seal(level, pending, 'pending');
        }
        lv.pending = NIL;
        this.seal(level, id, 'last');
      } else {
        lv.pending = NIL;
        this.seal(level, pending, 'only');
      }
    }
  };

  function bulkLoad(order, keys, options) {
    var tree = new Tree(order), loader = new BulkLoader(tree, options);
    keys.forEach(function (k) { loader.add(k.key, k.value); });
    loader.finish();
    return tree;
  }
  function insertAll(order, entries) {
    var tree = new Tree(order);
    entries.forEach(function (e) { tree.put(e.key, e.value); });
    return tree;
  }

  /** SplitMix64 exactly as common/zig/prng.zig (BigInt for the 64-bit maths). */
  function SplitMix64(seed) {
    var M = (1n << 64n) - 1n, s = BigInt(seed);
    var self = {
      next: function () {
        s = (s + 0x9E3779B97F4A7C15n) & M;
        var z = s;
        z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & M;
        z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & M;
        return z ^ (z >> 31n);
      },
      below: function (n) { return Number((self.next() * BigInt(n)) >> 64n); },
      shuffle: function (a) {
        for (var i = a.length - 1; i >= 1; i--) { var j = self.below(i + 1), t = a[i]; a[i] = a[j]; a[j] = t; }
      }
    };
    return self;
  }

  /* ---- report(): the text of expected_output.txt ---- */

  function dumpTree(tree) {
    var out = '';
    tree.levelIds().forEach(function (ids, depth) {
      out += '  level ' + (tree.height - 1 - depth) + ':';
      ids.forEach(function (id) {
        var n = tree.nodes[id];
        out += n.leaf ? ' [' + n.keys.join(' ') + ']' : ' (' + n.keys.slice(1).join(' ') + ')';
      });
      out += '\n';
    });
    return out + '  pages ' + tree.shape().pages + ', page writes ' + tree.stats.writes + ', splits ' + tree.stats.splits + '\n';
  }
  function leafFill(tree) {
    var s = tree.shape();
    return s.leaves ? Math.floor(s.entries * 100 / (s.leaves * tree.leafCap())) : 0;
  }
  function L(v, w) { return String(v).padEnd(w); }
  function R(v, w) { return String(v).padStart(w); }
  function row(name, t) {
    var s = t.shape();
    return L(name, 22) + R(s.height, 7) + R(s.leaves, 8) + R(s.inner, 7) + R(s.pages, 7) + R(leafFill(t), 10) + '%' +
      R(t.stats.writes, 13) + R(t.stats.reads, 12) + R(t.stats.splits, 8) + '\n';
  }
  function handExample() {
    var entries = [];
    for (var k = 1; k <= 13; k++) entries.push({ key: k, value: k * 10 });
    return 'bulk load, fill 100%:\n' + dumpTree(bulkLoad(4, entries, { leafFill: 100, innerFill: 100 })) +
      'one-by-one insert, ascending:\n' + dumpTree(insertAll(4, entries));
  }
  function report() {
    var out = 'Chapter 16: bulk loading\n\n== 1. Hand example: keys 1..13, order M = 4 ==\n' + handExample();
    var n = 10000, order = 16, entries = [], i;
    for (i = 0; i < n; i++) entries.push({ key: i * 10, value: i });
    out += '\n== 2. Building n = ' + n + ' keys, order M = ' + order + ' ==\n';
    out += 'method                 height  leaves  inner  pages  leaf fill  page writes  page reads  splits\n';
    out += row('bulk load 100%', bulkLoad(order, entries, { leafFill: 100, innerFill: 100 }));
    out += row('bulk load 90% / 70%', bulkLoad(order, entries, { leafFill: 90, innerFill: 70 }));
    out += row('insert, ascending', insertAll(order, entries));
    var perm = [];
    for (i = 0; i < n; i++) perm.push(i);
    SplitMix64(16).shuffle(perm);
    var t = new Tree(order);
    perm.forEach(function (p) { t.put(entries[p].key, entries[p].value); });
    out += row('insert, shuffled', t);
    var extra = 1000;
    out += '\n== 3. ' + extra + ' random inserts after the bulk load ==\n';
    out += 'leaf / inner fill  pages before  splits  page writes  pages after\n';
    [[100, 100], [90, 70], [70, 70]].forEach(function (f) {
      var b = bulkLoad(order, entries, { leafFill: f[0], innerFill: f[1] }), before = b.shape().pages;
      b.stats = { writes: 0, reads: 0, splits: 0 };
      randomInserts(b, n, extra);
      out += R(f[0], 4) + '% / ' + R(f[1], 3) + '%     ' + R(before, 12) + R(b.stats.splits, 8) + R(b.stats.writes, 13) + R(b.shape().pages, 13) + '\n';
    });
    return out;
  }

  /* ====================================================================
   * 2. Steps: run the loader and take a captioned snapshot after each event
   * ================================================================== */

  function kb(v, state) { return '<b class="bt-k' + (state ? ' s-' + state : '') + '">' + v + '</b>'; }
  function pid(id) { return '<code>p' + id + '</code>'; }
  function levelName(level) { return level === 0 ? 'the leaf level' : 'level ' + level; }

  /** Snapshot of everything LevelView draws. */
  function snapshot(loader, consumed, hl) {
    var tree = loader.tree;
    return {
      consumed: consumed,
      writes: tree.stats.writes,
      root: tree.root,
      hl: hl || {},
      levels: loader.levels.map(function (lv, li) {
        var leaf = li === 0;
        var pages = lv.ids.map(function (id) {
          var n = tree.nodes[id];
          return {
            id: 'p' + id, kind: lv.written[id] ? 'written' : 'pending', leaf: leaf,
            next: n.next === NIL ? null : 'p' + n.next,
            pairs: n.keys.map(function (key, i) { return { k: key, c: leaf ? null : 'p' + n.slots[i] }; })
          };
        });
        if (lv.buf.length) {
          pages.push({
            id: 'open' + li, kind: 'open', leaf: leaf, next: null,
            pairs: lv.buf.map(function (p) { return { k: p.key, c: leaf ? null : 'p' + p.slot }; })
          });
        }
        return { cap: tree.cap(leaf), target: loader.target(li), pages: pages };
      })
    };
  }

  /** A finished tree (bulk-loaded or insert-built) as a LevelView snapshot. */
  function treeSnapshot(tree, target) {
    var ids = tree.levelIds().reverse();
    return {
      consumed: tree.count, writes: tree.stats.writes, root: tree.root, hl: {},
      levels: ids.map(function (level, li) {
        var leaf = li === 0;
        return {
          cap: tree.cap(leaf), target: target ? target(leaf) : tree.cap(leaf),
          pages: level.map(function (id) {
            var n = tree.nodes[id];
            return {
              id: 'p' + id, kind: 'written', leaf: leaf, next: n.next === NIL ? null : 'p' + n.next,
              pairs: n.keys.map(function (key, i) { return { k: key, c: leaf ? null : 'p' + n.slots[i] }; })
            };
          })
        };
      })
    };
  }

  /**
   * bulkSteps(keys, order, {leafFill, innerFill}) → {steps, tree, loader}
   * Each step: {caption, state, phase, question?}. `phase` picks code lines
   * (window.CHAPTER_LINES in code.js): idle, start, push, close, seal while
   * keys arrive; end, merge, share, last, root, seal_pending, seal_last and
   * seal_only in finish (whose seals can again cause start, push, close and
   * seal one level up).
   */
  function bulkSteps(keys, order, options) {
    // `consumed` counts the keys that are in a page. It moves when the key is
    // stored, not when it arrives: while the loader closes a page to make
    // room, the arriving key is still the "next" one in the input strip.
    var tree = new Tree(order), steps = [], consumed = 0, asked = {}, repaired = {};
    var loader = new BulkLoader(tree, options, function (kind, info) {
      var level = info.level, lv = level === undefined ? null : loader.levels[level];
      var hl = { pages: {}, cells: {} }, caption = '', question = null, target, t;
      if (kind === 'push') {
        if (level === 0) consumed++;
        var openId = 'open' + level;
        hl.cells[openId + ':' + (lv.buf.length - 1)] = 'inserted';
        target = loader.target(level);
        if (level === 0) {
          caption = 'Key ' + kb(info.pair.key, 'inserted') + ' goes into the open leaf (' + lv.buf.length + ' of ' + target + ').' +
            (lv.buf.length === 1 && lv.ids.length === 0 ? ' No search and no descent: sorted input always belongs at the right edge.' : '') +
            (lv.buf.length === target ? ' The leaf has reached its fill target, but it stays open until another key arrives.' : '');
        } else {
          caption = (info.started ? 'The tree grows upward: ' + levelName(level) + ' is created for the first page finished below it. ' : '') +
            'The pair (' + kb(info.pair.key, 'inserted') + ' → ' + pid(info.pair.slot) + ') is added to the open page of ' + levelName(level) +
            ' (' + lv.buf.length + ' of ' + target + ').' +
            (lv.buf.length === 1 ? ' Its key sits in slot 0, which searches ignore: everything below the next separator goes to the first child anyway.' : '');
        }
      } else if (kind === 'close') {
        hl.pages['p' + info.id] = 'active';
        t = level === 0 ? 'leaf' : 'page';
        caption = 'The open ' + t + ' on ' + levelName(level) + ' is at its target and ' +
          (level === 0 ? 'key ' + kb(info.incoming.key) : 'another pair') + ' is waiting, so it becomes page ' + pid(info.id) +
          '. It is <em>pending</em>: complete, but not written yet. The buffer is recycled for the next page.';
        if (!asked['close' + (level === 0 ? 0 : 1)]) {
          asked['close' + (level === 0 ? 0 : 1)] = true;
          question = {
            prompt: 'The open ' + t + ' on ' + levelName(level) + ' is at its fill target and one more ' + (level === 0 ? 'key' : 'pair') + ' arrives. What does the loader do?',
            choices: ['Split the page in half', 'Close this page and start a new one to its right', 'Push the newcomer up to the parent'],
            answer: 1,
            explain: 'Sorted input never lands in the middle of a page, so nothing is ever split.'
          };
        }
      } else if (kind === 'seal') {
        hl.pages['p' + info.id] = 'found';
        var node = tree.nodes[info.id];
        caption = 'Page ' + pid(info.id) + ' is final' +
          (level === 0 && node.next !== NIL ? ': its right neighbour ' + pid(node.next) + ' has an id, so the leaf link can be filled in' : '') +
          '. It is written, once and for all (page write ' + tree.stats.writes + '). Its low key ' + kb(node.keys[0]) + ' and its id now go up one level.';
      } else if (kind === 'end') {
        caption = 'End of input. Each level still holds a pending page, an open page, or both. They are finished from the bottom up.';
      } else if (kind === 'share') {
        repaired[level] = true;
        hl.pages['p' + info.id] = 'merge';
        hl.pages['open' + level] = 'merge';
        caption = 'The last page on ' + levelName(level) + ' was under the minimum (' + tree.min(level === 0) + '). Its pending neighbour ' + pid(info.id) +
          ' has not been written yet, so it hands over ' + info.moved + ' pair' + (info.moved === 1 ? '' : 's') + ' and the two share evenly. No extra write.';
        question = {
          prompt: 'The input has ended and the last page on ' + levelName(level) + ' holds fewer pairs than the minimum. What now?',
          choices: ['Write it as it is', 'Take pairs from the pending page on its left', 'Split the pending page'],
          answer: 1,
          explain: 'This is why the previous page was held back: both can still change for free. PostgreSQL chooses the first answer and tolerates a small last page.'
        };
      } else if (kind === 'merge') {
        hl.pages['p' + info.id] = 'merge';
        caption = 'The last ' + info.moved + ' pair' + (info.moved === 1 ? '' : 's') + ' on ' + levelName(level) + ' cannot form a legal page, and together with pending page ' + pid(info.id) +
          ' they fit in one. They are appended to ' + pid(info.id) + ', which may go above its fill target.';
      } else if (kind === 'last') {
        hl.pages['p' + info.id] = 'active';
        var held = tree.nodes[info.id].keys.length;
        caption = 'The open page on ' + levelName(level) + ' becomes page ' + pid(info.id) + ', the last one on its level.' +
          (repaired[level] ? '' : ' It holds ' + held + ' pair' + (held === 1 ? '' : 's') + ', which is not below the minimum of ' +
            tree.min(level === 0) + ', so no repair is needed.');
      } else if (kind === 'root') {
        hl.pages['p' + info.id] = 'found';
        caption = 'Only one page exists on ' + levelName(level) + ', so it is the root: ' + pid(info.id) + ' is written (page write ' + tree.stats.writes +
          '). Done: ' + tree.stats.writes + ' pages, ' + tree.stats.writes + ' writes, 0 page reads, 0 splits.';
      }
      var phase = kind === 'push' && info.started ? 'start' : kind === 'seal' && info.from ? 'seal_' + info.from : kind;
      var step = { caption: caption, state: snapshot(loader, consumed, hl), phase: phase };
      if (question) step.question = question;
      steps.push(step);
    });

    steps.push({
      caption: 'The input is sorted. The loader will fill leaves left to right, to ' + loader.leafTarget + ' of ' + tree.leafCap() +
        ' keys each, and pass one pair up for every finished page (interior pages: ' + loader.innerTarget + ' of ' + tree.innerCap() + ' children).',
      state: snapshot(loader, 0, {}), phase: 'idle'
    });
    keys.forEach(function (key) { loader.add(key, key * 10); });
    if (keys.length) loader.finish();
    return { steps: steps, tree: tree, loader: loader };
  }

  /* ====================================================================
   * 3. LevelView: rows of pages with empty slots, drawn as SVG
   * ================================================================== */

  var viewUid = 0;

  /**
   * new LevelView(target, {ariaLabel}).render(state)
   * state: {levels: [{cap, target, pages: [{id, kind, leaf, next, pairs: [{k, c}]}]}], hl}
   *   kind: 'written' | 'pending' | 'open';  hl: {pages: {id: state}, cells: {'id:i': state}}
   */
  function LevelView(target, opts) {
    var BTViz = root.BTViz, el = BTViz.el;
    this.opts = opts || {};
    this.uid = 'lv' + (++viewUid);
    this.svg = el('svg', { class: 'c16-svg', role: 'img', 'aria-label': this.opts.ariaLabel || 'Tree levels' });
    this.root = el('div.c16-levels', { tabindex: 0, role: 'group', 'aria-label': (this.opts.ariaLabel || 'Tree levels') + ' (scrollable)' }, this.svg);
    (typeof target === 'string' ? document.querySelector(target) : target).appendChild(this.root);
  }

  LevelView.prototype.render = function (state) {
    var BTViz = root.BTViz, el = BTViz.el, svg = this.svg, uid = this.uid;
    var levels = state.levels, hl = state.hl || {}, hp = hl.pages || {}, hc = hl.cells || {};
    var maxLen = 1;
    levels.forEach(function (lv) { lv.pages.forEach(function (p) { p.pairs.forEach(function (q) { maxLen = Math.max(maxLen, String(q.k).length); }); }); });
    var CW = Math.max(26, maxLen * 8 + 12), CH = 28, GAP = 18, GUTTER = 52, LABEL = 15, ROW = CH + LABEL + 46, PAD = 8;
    var pos = {};   // page id → {x, y, w, level}
    var nLevels = Math.max(1, levels.length), width = GUTTER + 120;

    levels.forEach(function (lv, li) {
      var y = PAD + LABEL + (nLevels - 1 - li) * ROW, right = GUTTER - GAP;
      lv.pages.forEach(function (p) {
        var cells = Math.max(lv.cap, p.pairs.length), w = cells * CW, x = right + GAP;
        if (!p.leaf) {
          // Centre a parent over the children it has been told about.
          var lo = Infinity, hi = -Infinity;
          p.pairs.forEach(function (q) { var c = pos[q.c]; if (c) { lo = Math.min(lo, c.x); hi = Math.max(hi, c.x + c.w); } });
          if (lo < hi) x = Math.max(x, (lo + hi) / 2 - w / 2);
        }
        pos[p.id] = { x: x, y: y, w: w, cells: cells };
        right = x + w;
      });
      width = Math.max(width, right + PAD);
    });
    var height = PAD + nLevels * ROW - 30;

    while (svg.firstChild) svg.removeChild(svg.firstChild);
    svg.setAttribute('viewBox', '0 0 ' + width + ' ' + height);
    svg.style.minWidth = Math.round(width * 0.72) + 'px';
    svg.style.maxWidth = width + 'px';
    svg.appendChild(el('defs',
      el('pattern', { id: uid + 'hatch', width: 6, height: 6, patternUnits: 'userSpaceOnUse', patternTransform: 'rotate(45)' },
        el('line', { x1: 0, y1: 0, x2: 0, y2: 6, class: 'c16-hatch-line' })),
      el('marker', { id: uid + 'arrow', viewBox: '0 0 8 8', refX: 7, refY: 4, markerWidth: 6, markerHeight: 6, orient: 'auto' },
        el('path', { d: 'M0 .8L7.2 4L0 7.2z', class: 'c16-arrowhead' }))));
    var gEdges = el('g'), gPages = el('g');
    svg.appendChild(gEdges);
    svg.appendChild(gPages);

    if (!levels.length) {
      gPages.appendChild(el('text', { x: GUTTER, y: PAD + LABEL + 18, class: 'c16-rowlabel' }, 'empty tree'));
    }
    var animate = BTViz.motion.duration() > 0;
    levels.forEach(function (lv, li) {
      var y0 = PAD + LABEL + (nLevels - 1 - li) * ROW;
      gPages.appendChild(el('text', { x: 2, y: y0 + CH / 2 + 4, class: 'c16-rowlabel' }, li === 0 ? 'leaves' : 'level ' + li));
      lv.pages.forEach(function (p) {
        var g = pos[p.id], st = hp[p.id];
        var cls = 'c16-page is-' + p.kind + (st ? ' s-' + st : '');
        var group = el('g', { class: cls, transform: 'translate(' + g.x + ',' + g.y + ')' });
        group.appendChild(el('text', { x: 1, y: -5, class: 'c16-pagelabel' }, p.kind === 'open' ? 'open' : p.id));
        for (var i = 0; i < g.cells; i++) {
          var q = p.pairs[i], cst = hc[p.id + ':' + i];
          var ccls = 'c16-cell' + (q ? ' has-key' : i >= lv.target ? ' is-spare' : ' is-empty') + (cst ? ' s-' + cst : '') + (q && !p.leaf && i === 0 ? ' is-ignored' : '');
          var rect = el('rect', { x: i * CW, y: 0, width: CW, height: CH, class: ccls });
          if (!q && i >= lv.target) rect.style.fill = 'url(#' + uid + 'hatch)';
          group.appendChild(rect);
          if (q) {
            var text = el('text', { x: i * CW + CW / 2, y: CH / 2 + 4.5, class: 'c16-key' + (cst ? ' s-' + cst : '') + (!p.leaf && i === 0 ? ' is-ignored' : '') }, String(q.k));
            if (cst && animate) text.classList.add('is-new');
            group.appendChild(text);
          }
        }
        group.appendChild(el('rect', { x: 0, y: 0, width: g.w, height: CH, rx: 4, class: 'c16-frame' }));
        if (p.id === 'p' + state.root && state.root !== NIL) group.appendChild(el('text', { x: g.w + 6, y: CH / 2 + 4, class: 'c16-rowlabel' }, 'root'));
        gPages.appendChild(group);

        // downlinks: from each pair's cell to the child page it points to
        if (!p.leaf) p.pairs.forEach(function (pair, pi) {
          var c = pos[pair.c];
          if (!c) return;
          gEdges.appendChild(el('line', {
            x1: g.x + pi * CW + CW / 2, y1: g.y + CH, x2: c.x + c.w / 2, y2: c.y - LABEL + 1,
            class: 'c16-edge' + (hc[p.id + ':' + pi] ? ' s-inserted' : '')
          }));
        });
        // leaf chain
        if (p.leaf && p.next && pos[p.next]) {
          var nx = pos[p.next];
          gEdges.appendChild(el('line', {
            x1: g.x + g.w + 1, y1: g.y + CH / 2, x2: nx.x - 2, y2: nx.y + CH / 2,
            class: 'c16-link', 'marker-end': 'url(#' + uid + 'arrow)'
          }));
        }
      });
    });
    // Wide trees scroll inside the view: keep the page being worked on visible.
    var focus = Object.keys(hp)[0] || (Object.keys(hc)[0] || '').split(':')[0];
    if (focus && pos[focus] && this.root.scrollWidth > this.root.clientWidth) {
      var scale = svg.getBoundingClientRect().width / width;
      var centre = (pos[focus].x + pos[focus].w / 2) * scale;
      this.root.scrollLeft = Math.max(0, centre - this.root.clientWidth / 2);
    }
    return this;
  };

  var api = {
    NIL: NIL, Tree: Tree, BulkLoader: BulkLoader, fillTarget: fillTarget, bulkLoad: bulkLoad, insertAll: insertAll,
    SplitMix64: SplitMix64, randomInserts: randomInserts, report: report, handExample: handExample, dumpTree: dumpTree, leafFill: leafFill,
    bulkSteps: bulkSteps, treeSnapshot: treeSnapshot, LevelView: LevelView
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.Ch16 = api;
})(typeof window !== 'undefined' ? window : globalThis);

/*
 * Chapter 08 — chapter-local model: a JavaScript port of zig/src/{tree,bounds,cursor,
 * link_cursor,stack_cursor,scan}.zig on top of the chapter 07 B+tree port (base_local.js).
 *
 * The same code runs silently (self-tests, node) and with a recorder that turns every
 * move of a cursor into a BTViz step. Pure data, no DOM.
 */
(function (root) {
  'use strict';
  var C7 = root.Ch07 || (typeof require !== 'undefined' ? require('./base_local.js') : null);
  var NIL = C7.NIL, lowerBound = C7.lowerBound, upperBound = C7.upperBound;
  var kf = function (v, state) { return root.BTViz && root.BTViz.k ? root.BTViz.k(v, state) : String(v); };

  /* ------------------------------------------------------------------ tree */

  /** Tree = chapter 07 B+tree + a change counter (zig/src/tree.zig). */
  function Tree(order) { this.base = new C7.BPlus(order === undefined ? 4 : order); this.version = 0; }
  Tree.prototype.put = function (key, value, opts) {
    var steps = this.base.put(key, value, opts);
    if (steps.ok) this.version++;                 // a new entry: positions may have moved
    return steps;
  };
  Tree.prototype.delete = function (key, opts) {
    var steps = this.base.delete(key, opts);
    if (steps.ok) this.version++;
    return steps;
  };
  Tree.prototype.keys = function () { return this.base.keys(); };
  Tree.prototype.toJSON = function () {
    var b = this.base;
    return JSON.parse(JSON.stringify({ version: this.version, base: {
      order: b.order, slots: b.slots, freeHead: b.freeHead, live: b.live, root: b.root, firstLeaf: b.firstLeaf,
      lastLeaf: b.lastLeaf, height: b.height, count: b.count, stats: b.stats } }));
  };
  Tree.fromJSON = function (data) {
    var t = new Tree(data.base.order), copy = JSON.parse(JSON.stringify(data.base));
    Object.keys(copy).forEach(function (p) { t.base[p] = copy[p]; });
    t.version = data.version;
    return t;
  };
  Tree.build = function (order, keys) {
    var t = new Tree(order);
    keys.forEach(function (key) { t.put(key, key * 100, { steps: false }); });
    return t;
  };

  /* ---------------------------------------------------------------- bounds */

  // A bound is {kind: 'unbounded'} | {kind: 'included', key} | {kind: 'excluded', key}.
  var UNBOUNDED = { kind: 'unbounded' };
  function included(key) { return { kind: 'included', key: key }; }
  function excluded(key) { return { kind: 'excluded', key: key }; }
  function aboveLower(lo, key) { return lo.kind === 'unbounded' || (lo.kind === 'included' ? key >= lo.key : key > lo.key); }
  function belowUpper(hi, key) { return hi.kind === 'unbounded' || (hi.kind === 'included' ? key <= hi.key : key < hi.key); }
  function contains(lo, hi, key) { return aboveLower(lo, key) && belowUpper(hi, key); }
  /** "[6, 17)": square = included, round = excluded. */
  function rangeLabel(lo, hi) {
    return (lo.kind === 'unbounded' ? '(-inf' : (lo.kind === 'included' ? '[' : '(') + lo.key) + ', ' +
           (hi.kind === 'unbounded' ? '+inf)' : hi.key + (hi.kind === 'included' ? ']' : ')'));
  }
  /** Which seek puts a cursor on the first entry of the scan (zig/src/scan.zig). */
  function startSeek(lo, hi, direction) {
    var b = direction === 'forward' ? lo : hi;
    if (b.kind === 'unbounded') return { kind: direction === 'forward' ? 'first' : 'last' };
    if (direction === 'forward') return { kind: b.kind === 'included' ? 'ge' : 'gt', key: b.key };
    return { kind: b.kind === 'included' ? 'le' : 'lt', key: b.key };
  }
  var SEEK_TEXT = { first: 'the smallest key', last: 'the largest key', ge: 'the first key ≥ ', gt: 'the first key &gt; ', le: 'the last key ≤ ', lt: 'the last key &lt; ' };
  function seekText(t) { return SEEK_TEXT[t.kind] + (t.key === undefined ? '' : kf(t.key)); }
  function isForward(t) { return t.kind === 'first' || t.kind === 'ge' || t.kind === 'gt'; }

  /** Where a seek lands inside a leaf (zig/src/cursor.zig `landing`). */
  function landing(keys, t) {
    switch (t.kind) {
      case 'first': return { forward: 0 };
      case 'ge': return { forward: lowerBound(keys, t.key) };
      case 'gt': return { forward: upperBound(keys, t.key) };
      case 'last': return { backward: keys.length };
      case 'le': return { backward: upperBound(keys, t.key) };
      default: return { backward: lowerBound(keys, t.key) };
    }
  }

  /* ---------------------------------------------------------------- cursor */

  /**
   * Cursor(design): design is 'link' (leaf handle + index, sibling links) or 'stack'
   * (root-to-leaf path of frames {h, ci}, no sibling links). `state` is 'before', 'after'
   * or 'on' (then `key` is the saved key). `rec`, when set, receives one event per move:
   * {type, caption, hl: {nodes, edges, links, keys}, code}. `naive` switches the version
   * check off (to show the bug it prevents).
   */
  function Cursor(design) {
    this.design = design;
    this.state = 'before';
    this.key = null;
    this.version = 0;
    this.leaf = NIL;
    this.index = 0;
    this.frames = [];
    this.stats = { seeks: 0, reseeks: 0, visits: 0 };
    this.naive = false;
    this.rec = null;
  }
  var P = Cursor.prototype;
  P.toJSON = function () {
    return JSON.parse(JSON.stringify({ design: this.design, state: this.state, key: this.key, version: this.version,
      leaf: this.leaf, index: this.index, frames: this.frames, stats: this.stats, naive: this.naive }));
  };
  Cursor.fromJSON = function (data) {
    var c = new Cursor(data.design), copy = JSON.parse(JSON.stringify(data));
    Object.keys(copy).forEach(function (p) { c[p] = copy[p]; });
    return c;
  };
  P._emit = function (type, caption, hl, code) { if (this.rec) this.rec({ type: type, caption: caption, hl: hl || {}, code: code }); };
  function mk(key, value) { var o = {}; o[key] = value; return o; }
  function frameText(b, f) { return '(' + b.name(f.h) + ', child ' + f.ci + ')'; }

  /** Walks down from `start` to a leaf; the stack design pushes a frame per internal node. */
  P._descend = function (b, start, t, why) {
    var h = start;
    for (;;) {
      var n = b.node(h);
      this.stats.visits++;
      if (n.leaf) return h;
      var ci = t.kind === 'first' ? 0 : t.kind === 'last' ? n.keys.length : upperBound(n.keys, t.key);
      var text;
      if (t.key === undefined) text = (ci === 0 ? 'Left' : 'Right') + ' edge: take the ' + (ci === 0 ? 'first' : 'last') + ' child.';
      else if (ci === 0) text = kf(t.key) + ' &lt; ' + kf(n.keys[0], 'compare') + ': take child 0.';
      else if (ci === n.keys.length) text = kf(t.key) + ' ≥ ' + kf(n.keys[ci - 1], 'compare') + ': take the last child, ' + ci + '.';
      else text = kf(n.keys[ci - 1], 'compare') + ' ≤ ' + kf(t.key) + ' &lt; ' + kf(n.keys[ci], 'compare') + ': take child ' + ci + '.';
      if (this.design === 'stack') {
        this.frames.push({ h: h, ci: ci });
        text += ' Push the frame ' + frameText(b, this.frames[this.frames.length - 1]) + ' so the cursor can come back here.';
      } else {
        text += ' The link cursor remembers nothing about this node.';
      }
      this._emit('descend', (why || 'Descend. ') + 'Internal node ' + b.fmt(h) + ': ' + text, {
        nodes: mk(h, 'active'), edges: mk(n.children[ci], 'active'),
        keys: t.key === undefined ? [] : n.keys.slice(Math.max(0, ci - 1), Math.min(n.keys.length, ci + 1)).map(function (kv) { return [h, kv, 'compare']; })
      }, 'seek');
      why = '';
      h = n.children[ci];
    }
  };

  /** Position from scratch. Returns the key the cursor is on, or null. */
  P._seekPos = function (b, t) {
    this.frames = [];
    this.leaf = NIL;
    if (b.root === NIL) { this._emit('empty', 'The tree is empty: there is no entry to stand on.', {}, 'seek'); return null; }
    if (this.design === 'link' && t.key === undefined) {
      // The tree keeps handles of both ends of the chain: no descent.
      this.leaf = t.kind === 'first' ? b.firstLeaf : b.lastLeaf;
      this.stats.visits++;
      this._emit('jump', 'The tree keeps the handle of its ' + (t.kind === 'first' ? 'first' : 'last') + ' leaf, ' + b.name(this.leaf) +
        ': the link cursor goes there directly, without a descent.', { nodes: mk(this.leaf, 'active') }, 'seek');
    } else {
      this.leaf = this._descend(b, b.root, t, '');
    }
    var n = b.node(this.leaf), land = landing(n.keys, t), L = b.fmt(this.leaf);
    if (land.forward !== undefined) {
      var i = land.forward;
      this._emit('land', i < n.keys.length
        ? 'Leaf ' + L + ': binary search finds ' + seekText(t) + ' at index ' + i + '.'
        : 'Leaf ' + L + ': no key here qualifies (index ' + i + ' is past its end), so the answer is the first entry of the next leaf.',
        { nodes: mk(this.leaf, 'active'), keys: i < n.keys.length ? [[this.leaf, n.keys[i], 'compare']] : [] }, 'seek');
      return this._settleForward(b, i);
    }
    var count = land.backward;
    this._emit('land', count > 0
      ? 'Leaf ' + L + ': ' + (count === 1 ? '1 of its keys qualifies; ' : count + ' of its keys qualify; ') + seekText(t) + ' is the last of them, at index ' + (count - 1) + '.'
      : 'Leaf ' + L + ': no key here qualifies, so the answer is the last entry of the previous leaf.',
      { nodes: mk(this.leaf, 'active'), keys: count > 0 ? [[this.leaf, n.keys[count - 1], 'compare']] : [] }, 'seek');
    return this._settleBackward(b, count);
  };
  P._settleForward = function (b, start) {
    var i = start;
    for (;;) {
      var n = b.node(this.leaf);
      if (i < n.keys.length) { this.index = i; return n.keys[i]; }
      if (!this._moveLeaf(b, 'forward')) return null;
      i = 0;
    }
  };
  P._settleBackward = function (b, count) {
    var q = count;
    for (;;) {
      if (q > 0) { this.index = q - 1; return b.node(this.leaf).keys[this.index]; }
      if (!this._moveLeaf(b, 'backward')) return null;
      q = b.node(this.leaf).keys.length;
    }
  };
  /** To the neighbouring leaf: one sibling link, or pop / step / push on the path. */
  P._moveLeaf = function (b, dir) {
    var fwd = dir === 'forward', from = this.leaf, side = fwd ? 'right' : 'left';
    if (this.design === 'link') {
      var to = fwd ? b.node(from).next : b.node(from).prev;
      if (to === NIL) {
        this._emit('end', 'Leaf ' + b.name(from) + ' has no ' + (fwd ? 'next' : 'previous') + ' leaf (its link is nil): the cursor is off the ' + (fwd ? 'end' : 'start') + ' of the tree.',
          { nodes: mk(from, 'active') }, 'linkStep');
        this.leaf = NIL;
        return false;
      }
      this.stats.visits++;
      this.leaf = to;
      this._emit('link', 'End of leaf ' + b.name(from) + '. Follow its ' + (fwd ? '<code>next</code>' : '<code>prev</code>') + ' link to ' + b.fmt(to) +
        ': one move, and no internal node is touched.', { nodes: mk(to, 'active'), links: mk(fwd ? from : to, 'active') }, 'linkStep');
      return true;
    }
    while (this.frames.length) {
      var f = this.frames[this.frames.length - 1], parent = b.node(f.h);
      this.stats.visits++;                                   // back up in the parent
      if (fwd ? f.ci < parent.keys.length : f.ci > 0) {
        f.ci += fwd ? 1 : -1;
        var sub = parent.children[f.ci];
        this._emit('up', 'No sibling link is used. Back up to ' + b.fmt(f.h) + ', the top frame: it has a child to the ' + side +
          ', so the frame becomes ' + frameText(b, f) + '.', { nodes: mk(f.h, 'active'), edges: mk(sub, 'active') }, 'stackStep');
        this.leaf = this._descend(b, sub, { kind: fwd ? 'first' : 'last' }, 'Down the ' + (fwd ? 'left' : 'right') + ' edge of that subtree. ');
        this._emit('down', 'Arrive in leaf ' + b.fmt(this.leaf) + ', the ' + (fwd ? 'next' : 'previous') + ' leaf in key order.',
          { nodes: mk(this.leaf, 'active'), edges: mk(this.leaf, 'active') }, 'stackStep');
        return true;
      }
      this._emit('pop', 'Back up to ' + b.fmt(f.h) + ': the path came through its ' + (fwd ? 'last' : 'first') + ' child, so it has nothing further to the ' + side +
        '. Pop the frame and look one level higher.', { nodes: mk(f.h, 'active') }, 'stackStep');
      this.frames.pop();
    }
    this._emit('end', 'The stack is empty: even the root has no child further ' + side + '. The cursor is off the ' + (fwd ? 'end' : 'start') + ' of the tree.', {}, 'stackStep');
    this.leaf = NIL;
    return false;
  };

  /** seek(tree, target) → key or null (zig/src/cursor.zig). */
  P.seek = function (tree, t) {
    this.stats.seeks++;
    var found = this._seekPos(tree.base, t);
    if (found !== null) { this.state = 'on'; this.key = found; this.version = tree.version; return found; }
    this.state = isForward(t) ? 'after' : 'before';
    this.key = null;
    return null;
  };
  P.isStale = function (tree) { return this.state === 'on' && this.version !== tree.version; };
  P.entry = function (tree) {
    if (this.state !== 'on') return null;
    if (this.version === tree.version) return this.key;
    this.stats.seeks++; this.stats.reseeks++;
    var key = this.key, found = this._seekPos(tree.base, { kind: 'ge', key: key });
    if (found !== key) return null;                 // deleted: stay "on" the key, and stale
    this.version = tree.version;
    return found;
  };
  /** step(tree, 'forward' | 'backward') = next / prev. Returns the new key or null. */
  P.step = function (tree, dir) {
    var fwd = dir === 'forward', b = tree.base;
    if (this.state === (fwd ? 'after' : 'before')) return null;
    if (this.state !== 'on') return this.seek(tree, { kind: fwd ? 'first' : 'last' });
    if (this.version !== tree.version && !this.naive) {
      this.stats.reseeks++;
      this._emit('reseek', 'The tree has changed since this cursor computed its position (the cursor saw version ' + this.version + ', the tree is at version ' + tree.version +
        '). The saved (node, index) may point anywhere now, so it is thrown away. The saved key ' + kf(this.key, 'found') + ' still means something: seek ' +
        seekText({ kind: fwd ? 'gt' : 'lt', key: this.key }) + ' from the root.', { nodes: mk(b.root, 'active') }, 'reseek');
      return this.seek(tree, { kind: fwd ? 'gt' : 'lt', key: this.key });
    }
    var found = fwd ? this._settleForward(b, this.index + 1) : this._settleBackward(b, this.index);
    if (found !== null) { this.key = found; return found; }
    this.state = fwd ? 'after' : 'before';
    this.key = null;
    return null;
  };
  P.next = function (tree) { return this.step(tree, 'forward'); };
  P.prev = function (tree) { return this.step(tree, 'backward'); };
  /** Can the naive cursor even read its old position? (A freed or shrunken leaf: no.) */
  P.positionReadable = function (tree) {
    var s = tree.base.slots[this.leaf];
    return !!(s && s.used && s.node.leaf && this.index < s.node.keys.length);
  };
  /** "#7.0 #2.1": in node #7 the path goes down child 0, in node #2 child 1. */
  P.pathLabel = function () { return this.frames.map(function (f) { return '#' + f.h + '.' + f.ci; }).join(' '); };

  /* ------------------------------------------------------------------ scan */

  /** Runs a whole range scan. Returns {keys, cursor}. `rec` receives cursor and scan events. */
  function scan(tree, design, lo, hi, direction, rec) {
    var cur = new Cursor(design), keys = [], fwd = direction === 'forward';
    var emit = function (type, caption, hl, code) { if (rec) rec({ type: type, caption: caption, hl: hl || {}, code: code }, cur, keys); };
    cur.rec = rec ? function (ev) { rec(ev, cur, keys); } : null;
    var t = startSeek(lo, hi, direction), far = fwd ? hi : lo, near = fwd ? lo : hi;
    emit('start', 'Range ' + rangeLabel(lo, hi) + ', ' + direction + ', with the ' + (design === 'link' ? 'leaf-link' : 'stack') + ' cursor. A ' + direction +
      ' scan starts at the ' + (fwd ? 'lower' : 'upper') + ' bound, which is ' + near.kind + ': seek to ' + seekText(t) + '.',
      tree.base.root === NIL ? {} : { nodes: mk(tree.base.root, 'active') }, 'scan');
    var found = cur.seek(tree, t);
    for (;;) {
      if (found === null) {
        emit('stop', 'There is no further entry in this direction: the scan is finished.', {}, 'scan');
        break;
      }
      var inside = fwd ? belowUpper(hi, found) : aboveLower(lo, found);
      var where = tree.base.name(cur.leaf) + '[' + cur.index + ']';
      var test = far.kind === 'unbounded' ? 'there is no ' + (fwd ? 'upper' : 'lower') + ' bound to test'
        : kf(found) + (inside ? ' is inside' : ' is outside') + ' the ' + (fwd ? 'upper' : 'lower') + ' bound (' + (fwd ? (far.kind === 'included' ? '≤ ' : '&lt; ') : (far.kind === 'included' ? '≥ ' : '&gt; ')) + far.key + ')';
      if (!inside) {
        emit('stop', 'The cursor is on ' + kf(found, 'compare') + ' at ' + where + ', but ' + test + ': stop. Only this far bound is tested for each key; the near bound was settled by the seek.',
          { nodes: mk(cur.leaf, 'active'), keys: [[cur.leaf, found, 'compare']] }, 'scan');
        break;
      }
      keys.push(found);
      emit('return', 'The cursor is on ' + kf(found, 'found') + ' at ' + where + '; ' + test + ': return it.', { nodes: mk(cur.leaf, 'active') }, 'scan');
      found = cur.step(tree, direction);
    }
    cur.rec = null;
    return { keys: keys, cursor: cur };
  }

  /* ------------------------------------------------- program output (self-test) */

  var CANONICAL = C7.CANONICAL;
  function pad(s, n) { s = String(s); while (s.length < n) s += ' '; return s; }
  function padLeft(s, n) { s = String(s); while (s.length < n) s = ' ' + s; return s; }

  /** Sections 1 to 4 and 6 of ../expected_output.txt, produced by this model. */
  function scenarioText() {
    var tree = Tree.build(4, CANONICAL), out = {};
    out.s1 = '== 1. The tree: canonical keys, order M = 4 ==\n' + C7.dump(tree.base);

    var line = function (lo, hi, dir, note) {
      var keys = scan(tree, 'link', lo, hi, dir).keys;
      return pad(rangeLabel(lo, hi), 12) + ' :' + (keys.length ? keys.map(function (v) { return ' ' + v; }).join('') : ' (nothing)') + (note ? '   <- ' + note : '') + '\n';
    };
    var s2 = '== 2. Bounds matrix: every combination for the bounds 6 and 17 ==\n';
    [UNBOUNDED, included(6), excluded(6)].forEach(function (lo) {
      [UNBOUNDED, included(17), excluded(17)].forEach(function (hi) { s2 += line(lo, hi, 'forward', ''); });
    });
    s2 += 'edge cases:\n' +
      line(included(12), included(12), 'forward', 'one key') +
      line(excluded(12), excluded(15), 'forward', 'neighbours, both excluded') +
      line(included(13), included(14), 'forward', 'both bounds in one gap') +
      line(included(17), included(6), 'forward', 'inverted') +
      line(included(12), excluded(12), 'forward', 'half open, same key') +
      line(UNBOUNDED, excluded(0), 'forward', 'below the smallest u64');
    out.s2 = s2;                 // (the last line of the section needs u64::MAX, which a JS number cannot hold)

    out.s3 = '== 3. Backward: seek to the upper bound, step with prev ==\n' +
      line(UNBOUNDED, UNBOUNDED, 'backward', '') + line(included(6), excluded(17), 'backward', '') +
      line(excluded(6), included(17), 'backward', '') + line(included(13), UNBOUNDED, 'backward', '');

    var s4 = '== 4. Two cursor designs, one result ==\n' +
      'scan [5, 20] forward; "#0[2]" = leaf #0, entry 2; "#7.0" = in node #7, down child 0\nkey  link cursor  stack cursor\n';
    var link = new Cursor('link'), stack = new Cursor('stack');
    var a = link.seek(tree, { kind: 'ge', key: 5 });
    stack.seek(tree, { kind: 'ge', key: 5 });
    while (a !== null && a <= 20) {
      s4 += pad(a, 4) + ' #' + link.leaf + '[' + link.index + ']        ' + stack.pathLabel() + ' -> #' + stack.leaf + '[' + stack.index + ']\n';
      a = link.next(tree);
      stack.next(tree);
    }
    s4 += 'node visits (every move of a cursor to another node):\n';
    [[included(5), included(20), 'forward'], [included(5), included(20), 'backward'], [UNBOUNDED, UNBOUNDED, 'forward'], [included(12), included(12), 'forward']].forEach(function (c) {
      var x = scan(tree, 'link', c[0], c[1], c[2]), y = scan(tree, 'stack', c[0], c[1], c[2]);
      s4 += pad(rangeLabel(c[0], c[1]), 12) + ' ' + pad(c[2], 8) + ' : ' + padLeft(x.keys.length, 2) + ' entries, link ' + padLeft(x.cursor.stats.visits, 2) +
        ', stack ' + padLeft(y.cursor.stats.visits, 2) + '\n';
    });
    out.s4 = s4;

    var opt = function (v) { return v === null ? 'none' : String(v); };
    var s6 = '== 6. The tree changes under the cursor ==\n';
    link = new Cursor('link'); stack = new Cursor('stack');
    link.seek(tree, { kind: 'ge', key: 10 }); stack.seek(tree, { kind: 'ge', key: 10 });
    var onLink = link.next(tree), onStack = stack.next(tree);
    s6 += 'both cursors: seek >= 10, next. link on ' + onLink + ' at #' + link.leaf + '[' + link.index + '], stack on ' + onStack + ' at ' + stack.pathLabel() +
      ' -> #' + stack.leaf + '[' + stack.index + ']\n';
    s6 += 'put 11, 13, 14: leaf #1 fills up and splits\n  ';
    [11, 13, 14].forEach(function (key) { tree.put(key, key * 100, { steps: false }); });
    s6 += C7.dump(tree.base);
    var naive = Cursor.fromJSON(link.toJSON());
    naive.naive = true;
    var holds = tree.base.node(naive.leaf).keys[naive.index];
    s6 += '  the old position #' + link.leaf + '[' + link.index + '] now holds ' + holds + '; stepping from it would return ' + naive.next(tree) + ' a second time\n';
    s6 += '  link  next -> ' + link.next(tree) + ' (re-seek: first key > 12), now at #' + link.leaf + '[' + link.index + ']\n';
    s6 += '  stack next -> ' + stack.next(tree) + ' (re-seek: first key > 12), now at ' + stack.pathLabel() + ' -> #' + stack.leaf + '[' + stack.index + ']\n';
    var before = JSON.parse(JSON.stringify(tree.base.stats));
    [13, 14, 15, 17].forEach(function (key) { tree.delete(key, { steps: false }); });
    s6 += 'delete 13 (the entry under both cursors), 14, 15, 17: ' + (tree.base.stats.borrows - before.borrows) + ' borrow, ' + (tree.base.stats.merges - before.merges) + ' merges\n  ';
    s6 += C7.dump(tree.base);
    s6 += '  link  entry -> ' + opt(link.entry(tree)) + ' (deleted), next -> ' + opt(link.next(tree)) + ', prev -> ' + opt(link.prev(tree)) + '\n';
    s6 += '  stack entry -> ' + opt(stack.entry(tree)) + ' (deleted), prev -> ' + opt(stack.prev(tree)) + ', next -> ' + opt(stack.next(tree)) + '\n';
    var on12 = link.seek(tree, { kind: 'ge', key: 12 }), value = tree.base.get(12), reseeks = link.stats.reseeks;
    tree.put(12, 1212, { steps: false });
    s6 += '  link on ' + on12 + '=' + value + '; put 12=1212 (overwrite); entry -> ' + link.entry(tree) + '=' + tree.base.get(12) + ', re-seeks caused: ' + (link.stats.reseeks - reseeks) + '\n';
    s6 += '  re-seeks so far: link ' + link.stats.reseeks + ', stack ' + stack.stats.reseeks + '\n';
    s6 += 'delete every even key while scanning the whole tree forward:\n';
    [['link ', 'link'], ['stack', 'stack']].forEach(function (d) {
      var t = Tree.build(4, CANONICAL), cur = new Cursor(d[1]), got = [];
      for (var key = cur.seek(t, { kind: 'first' }); key !== null; key = cur.next(t)) {
        got.push(key);
        if (key % 2 === 0) t.delete(key, { steps: false });
      }
      s6 += '  ' + d[0] + ' returned:' + got.map(function (v) { return ' ' + v; }).join('') + ' | re-seeks ' + cur.stats.reseeks + ' | left:' +
        t.keys().map(function (v) { return ' ' + v; }).join('') + '\n';
    });
    out.s6 = s6;
    return out;
  }

  var api = {
    Tree: Tree, Cursor: Cursor, scan: scan, scenarioText: scenarioText, CANONICAL: CANONICAL, NIL: NIL,
    UNBOUNDED: UNBOUNDED, included: included, excluded: excluded, contains: contains, rangeLabel: rangeLabel,
    startSeek: startSeek, seekText: seekText
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.Ch08 = api;
})(typeof window !== 'undefined' ? window : globalThis);

/*
 * Chapter 28 local helpers (the shared toolkit has no radix-tree model or view).
 *
 *   ART28.Art         JS twin of zig/src/art.zig: same node layouts, same insert, same dump.
 *                     Its walks are recursive, like the Zig ones; the page limits a typed key
 *                     to 16 characters, far below art.zig's max_key_len of 512 bytes.
 *                     Everything that reaches an HTML sink (captions, log lines) is escaped
 *                     here: kb() / kc() for captions, esc(showBytes(...)) for the log.
 *   ART28.ArtView     SVG drawing of that tree
 *   ART28.Inspector   the physical layout of one inner node (keys[], index[256], children[])
 *   ART28.HashIndex, ART28.SortedIndex, ART28.splitmix, ART28.fnv1a
 *                     twins of the other chapter files, used by the comparison figure
 *                     and by the self-tests against expected_output.txt
 *
 * Classic script; needs ../../../assets/viz.js loaded first (uses BTViz.el / clone / esc).
 * The model part also runs under node for testing.
 */
(function (root) {
  'use strict';
  var BTViz = root.BTViz || (typeof require === 'function' ? require('../../../assets/viz.js') : null);
  var el = BTViz.el, esc = BTViz.esc, clone = BTViz.clone;
  var PREFIX_CAP = 7, EMPTY48 = 48;
  var CAP = { n4: 4, n16: 16, n48: 48, n256: 256 };
  var NAME = { prefix: 'prefix', n4: 'node4', n16: 'node16', n48: 'node48', n256: 'node256' };
  var NEXT = { n4: 'n16', n16: 'n48', n48: 'n256' };

  /* ---------------------------------------------------------------- bytes */

  /** UTF-8 bytes of a string. */
  function utf8(s) {
    var out = [], str = unescape(encodeURIComponent(s));
    for (var i = 0; i < str.length; i++) out.push(str.charCodeAt(i));
    return out;
  }
  /** keys.zig encodeStr: escape 0x00/0x01 with 0x01, append a 0x00 terminator. */
  function encodeStr(s) {
    var out = [];
    utf8(s).forEach(function (c) { if (c <= 1) out.push(1); out.push(c); });
    out.push(0);
    return out;
  }
  function printable(c) { return c >= 0x20 && c <= 0x7e && c !== 0x22 && c !== 0x27 && c !== 0x5c; }
  function hex2(c) { return (c < 16 ? '0' : '') + c.toString(16); }
  /** keys.zig writeBytes. */
  function fmtBytes(bytes) {
    return bytes.map(function (c) { return printable(c) ? String.fromCharCode(c) : '\\x' + hex2(c); }).join('');
  }
  /**
   * fmtBytes for captions and the log. HTML collapses a run of spaces and drops a space at the
   * edge of an inline box, so the keys " " and "  " would both be displayed as nothing. Spaces
   * that would be lost that way (first byte, last byte, next to another space) are shown as \x20.
   */
  function showBytes(bytes) {
    return bytes.map(function (c, i) {
      var lost = c === 0x20 && (i === 0 || i === bytes.length - 1 || bytes[i - 1] === 0x20 || bytes[i + 1] === 0x20);
      return lost ? '\\x20' : fmtBytes([c]);
    }).join('');
  }
  /** Short label for one byte inside a cell. */
  function cellText(c) { return printable(c) && c !== 0x20 ? String.fromCharCode(c) : hex2(c); }
  function cmpBytes(a, b) {
    var n = Math.min(a.length, b.length);
    for (var i = 0; i < n; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
    return a.length === b.length ? 0 : a.length < b.length ? -1 : 1;
  }
  function startsWith(a, p) {
    if (p.length > a.length) return false;
    for (var i = 0; i < p.length; i++) if (a[i] !== p[i]) return false;
    return true;
  }

  /* ------------------------------------------------- SplitMix64 and FNV-1a */

  var M64 = (1n << 64n) - 1n;
  /** common/zig/prng.zig, bit for bit. */
  function splitmix(seed) {
    var state = BigInt(seed);
    var r = {
      nextU64: function () {
        state = (state + 0x9E3779B97F4A7C15n) & M64;
        var z = state;
        z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & M64;
        z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & M64;
        return z ^ (z >> 31n);
      },
      below: function (n) { return Number((r.nextU64() * BigInt(n)) >> 64n); },
      range: function (lo, hi) { return lo + r.below(hi - lo); },
      shuffle: function (items) {
        for (var i = items.length - 1; i >= 1; i--) {
          var j = r.below(i + 1), t = items[i]; items[i] = items[j]; items[j] = t;
        }
      }
    };
    return r;
  }
  /** keys.zig fnv1a → BigInt. */
  function fnv1a(bytes) {
    var h = 0xcbf29ce484222325n;
    for (var i = 0; i < bytes.length; i++) h = ((h ^ BigInt(bytes[i])) * 0x100000001b3n) & M64;
    return h;
  }

  /* --------------------------------------------------------------- the ART */

  function Art() {
    this.root = null;          // null | {t:'leaf', v} | {t:'prefix', id, bytes, child} | inner node
    this.len = 0;
    this.grows = [0, 0, 0];
    this.prefixSplits = 0;
    this.nextId = 1;
    this.rec = null;           // step list while an operation is being recorded
    this.op = null;            // {key, text} of the operation being recorded
  }
  Art.prototype._id = function (kind) { return kind + (this.nextId++); };

  function isInner(r) { return r && (r.t === 'n4' || r.t === 'n16' || r.t === 'n48' || r.t === 'n256'); }
  function childCount(n) {
    return n.t === 'n4' || n.t === 'n16' ? n.keys.length : n.count;
  }
  function childOf(n, byte) {
    if (n.t === 'n4' || n.t === 'n16') { var i = n.keys.indexOf(byte); return i < 0 ? null : n.children[i]; }
    if (n.t === 'n48') return n.index[byte] === EMPTY48 ? null : n.children[n.index[byte]];
    return n.children[byte];
  }
  function setChild(n, byte, child) {
    if (n.t === 'n4' || n.t === 'n16') n.children[n.keys.indexOf(byte)] = child;
    else if (n.t === 'n48') n.children[n.index[byte]] = child;
    else n.children[byte] = child;
  }
  function addChild(n, byte, child) {
    if (n.t === 'n4' || n.t === 'n16') {
      var i = n.keys.length;
      while (i > 0 && n.keys[i - 1] > byte) i--;        // keep keys[] sorted
      n.keys.splice(i, 0, byte);
      n.children.splice(i, 0, child);
    } else if (n.t === 'n48') {
      n.children[n.count] = child; n.index[byte] = n.count; n.count++;
    } else { n.children[byte] = child; n.count++; }
  }
  /** First child with byte >= from, as {byte, child}, or null. */
  function nextChild(n, from) {
    var b;
    if (n.t === 'n4' || n.t === 'n16') {
      for (var i = 0; i < n.keys.length; i++) if (n.keys[i] >= from) return { byte: n.keys[i], child: n.children[i] };
      return null;
    }
    if (n.t === 'n48') {
      for (b = from; b < 256; b++) if (n.index[b] !== EMPTY48) return { byte: b, child: n.children[n.index[b]] };
      return null;
    }
    for (b = from; b < 256; b++) if (n.children[b]) return { byte: b, child: n.children[b] };
    return null;
  }
  function eachChild(n, fn) {
    var from = 0, bc;
    while ((bc = nextChild(n, from))) { fn(bc.byte, bc.child); from = bc.byte + 1; }
  }

  Art.prototype._newChain = function (rest, value) {
    var child = { t: 'leaf', v: value }, end = rest.length;
    while (end > 0) {
      var start = Math.floor((end - 1) / PREFIX_CAP) * PREFIX_CAP;
      child = { t: 'prefix', id: this._id('p'), bytes: rest.slice(start, end), child: child };
      end = start;
    }
    return child;
  };

  Art.prototype._grow = function (n) {
    var bigger, i;
    if (n.t === 'n4') {
      bigger = { t: 'n16', id: this._id('n'), keys: n.keys.slice(), children: n.children.slice() };
      this.grows[0]++;
    } else if (n.t === 'n16') {
      bigger = { t: 'n48', id: this._id('n'), count: n.keys.length, index: [], children: n.children.slice() };
      for (i = 0; i < 256; i++) bigger.index.push(EMPTY48);
      n.keys.forEach(function (k, pos) { bigger.index[k] = pos; });
      this.grows[1]++;
    } else {
      bigger = { t: 'n256', id: this._id('n'), count: n.count, children: [] };
      for (i = 0; i < 256; i++) bigger.children.push(n.index[i] === EMPTY48 ? null : n.children[n.index[i]]);
      this.grows[2]++;
    }
    return bigger;
  };

  /**
   * A model whose tree is exactly the tree of a recorded step state. The page uses it so that
   * Insert / Search / Ordered scan work on the tree that is drawn, wherever the reader has
   * stepped to, and not on the tree at the end of the recorded trace.
   * `maxValue` is the largest stored value (0 for an empty tree).
   */
  Art.fromState = function (state) {
    var t = new Art(), maxId = 0;
    t.root = clone(state.root || null);
    t.grows = state.grows.slice();
    t.prefixSplits = state.splits;
    t.maxValue = 0;
    (function walk(ref) {
      if (!ref) return;
      if (ref.t === 'leaf') { t.len++; t.maxValue = Math.max(t.maxValue, ref.v); return; }
      maxId = Math.max(maxId, +ref.id.slice(1));        // ids are 'p12' / 'n7'
      if (ref.t === 'prefix') walk(ref.child);
      else eachChild(ref, function (b, c) { walk(c); });
    })(t.root);
    t.nextId = maxId + 1;                               // new nodes must not collide with drawn ones
    return t;
  };

  function countLeaves(ref) {
    if (!ref) return 0;
    if (ref.t === 'leaf') return 1;
    if (ref.t === 'prefix') return countLeaves(ref.child);
    var n = 0;
    eachChild(ref, function (b, c) { n += countLeaves(c); });
    return n;
  }

  /* Recording. A step's state is everything the page draws. */
  Art.prototype._step = function (type, caption, d) {
    if (!this.rec) return;
    d = d || {};
    var drawn = d.root === undefined ? this.root : d.root;
    this.rec.push({
      type: type, caption: caption, log: d.log || null, question: d.question || null, hold: d.hold || 1,
      state: {
        root: clone(drawn),
        key: this.op ? this.op.key.slice() : [], depth: d.depth === undefined ? -1 : d.depth,
        keyState: d.keyState || 'compare',
        nodes: d.nodes || {}, cells: d.cells || {}, leaves: d.leaves || {},
        focus: d.focus || null, insp: d.insp || {},
        // The number of keys in the tree that is DRAWN. `this.len` only changes when put() returns,
        // but the steps that link the new leaf in already show it.
        len: countLeaves(drawn), grows: this.grows.slice(), splits: this.prefixSplits
      }
    });
  };
  function kb(bytes, state) { return '<b class="bt-k' + (state ? ' s-' + state : '') + '">' + esc(showBytes(bytes)) + '</b>'; }
  function kc(c, state) { return kb([c], state); }
  function inspScan(n, byte) {
    // Which array elements a lookup of `byte` reads in this layout.
    var o = { keys: {}, index: {}, children: {} }, i;
    if (n.t === 'n4' || n.t === 'n16') {
      for (i = 0; i < n.keys.length; i++) {
        if (n.keys[i] === byte) { o.keys[i] = 'found'; o.children[i] = 'found'; break; }
        o.keys[i] = 'compare';
      }
    } else if (n.t === 'n48') {
      o.index[byte] = n.index[byte] === EMPTY48 ? 'compare' : 'found';
      if (n.index[byte] !== EMPTY48) o.children[n.index[byte]] = 'found';
    } else o.children[byte] = n.children[byte] ? 'found' : 'compare';
    return o;
  }
  function scanWords(n) {
    return n.t === 'n4' || n.t === 'n16' ? 'scan the sorted <code>keys[]</code>'
      : n.t === 'n48' ? 'read <code>index[byte]</code>' : 'read <code>children[byte]</code>';
  }

  /**
   * Insert or overwrite (art.zig put / insertAt). Returns the list of recorded steps when
   * `record` is true, otherwise undefined. steps.old = previous value or null.
   */
  Art.prototype.put = function (key, value, record, text) {
    if (!key.length) throw new Error('empty key');
    var self = this, old = { v: null };
    this.rec = record ? [] : null;
    this.op = { key: key, text: text === undefined ? fmtBytes(key) : text };
    this._step('start', 'Insert ' + kb(key) + ' = ' + value + '. The key is ' + key.length +
      ' bytes; the tree will consume them left to right, starting at the root.', { depth: 0, log: 'put ' + esc(showBytes(key)) });

    function insertAt(ref, depth) {
      var i;
      if (!ref) {
        var chain = self._newChain(key.slice(depth), value);
        self._step('chain', 'The tree is empty. The whole key becomes one chain of prefix nodes (up to ' + PREFIX_CAP +
          ' bytes each) ending in the value. No inner node is needed for a single key.',
          { root: chain, depth: key.length, keyState: 'inserted', nodes: chainIds(chain, 'inserted'), log: 'new prefix chain' });
        return chain;
      }
      if (ref.t === 'leaf') {
        if (depth !== key.length) throw new Error('PrefixKey');
        old.v = ref.v;
        return { t: 'leaf', v: value };
      }
      if (ref.t === 'prefix') {
        for (i = 0; i < ref.bytes.length; i++) {
          if (depth + i === key.length) throw new Error('PrefixKey');
          if (ref.bytes[i] !== key[depth + i]) return splitPrefix(ref, i, depth + i);
        }
        var m = {}; m[ref.id] = 'active';
        // A 1-byte prefix compresses nothing; only say "path compression" when bytes are really skipped together.
        self._step('prefix-match', 'Prefix node ' + kb(ref.bytes) + ': ' + (ref.bytes.length > 1
          ? 'the next ' + ref.bytes.length + ' key bytes are the same, so all of them are skipped in one step. This is path compression.'
          : 'the next key byte matches the prefix, so the walk continues below it.'),
          { depth: depth + ref.bytes.length, nodes: m });
        ref.child = insertAt(ref.child, depth + ref.bytes.length);
        if (ref.child.t === 'leaf' && old.v !== null) {
          self._step('overwrite', 'The path ends in a leaf: the key already exists. Its value ' + old.v + ' is replaced by ' + value + '.',
            { depth: key.length, keyState: 'found', nodes: m });
        }
        return ref;
      }
      // inner node
      if (depth === key.length) throw new Error('PrefixKey');
      var byte = key[depth], child = childOf(ref, byte), nm = {}, cm = {};
      nm[ref.id] = 'active';
      if (child) {
        cm[ref.id + ':' + byte] = 'found';
        self._step('descend', NAME[ref.t] + ' (' + childCount(ref) + ' of ' + CAP[ref.t] + ' slots used): ' + scanWords(ref) +
          ' for byte ' + kc(byte, 'compare') + '. There is a child: follow it.',
          { depth: depth, nodes: nm, cells: cm, focus: ref.id, insp: inspScan(ref, byte) });
        var nc = insertAt(child, depth + 1);
        setChild(ref, byte, nc);
        if (nc.t === 'leaf' && old.v !== null) {
          self._step('overwrite', 'The path ends in a leaf: the key already exists. Its value ' + old.v + ' is replaced by ' + value + '.',
            { depth: key.length, keyState: 'found', nodes: nm, cells: cm });
        }
        return ref;
      }
      cm[ref.id + ':' + byte] = 'compare';
      self._step('no-child', NAME[ref.t] + ' (' + childCount(ref) + ' of ' + CAP[ref.t] + ' slots used): ' + scanWords(ref) +
        ' for byte ' + kc(byte, 'compare') + '. No child has that byte, so the key is new and branches off here.',
        { depth: depth, nodes: nm, focus: ref.id, insp: inspScan(ref, byte) });
      var chain2 = self._newChain(key.slice(depth + 1), value), node = ref;
      if (childCount(ref) === CAP[ref.t]) {
        var before = ref;
        node = self._grow(ref);
        // Show the copy before the new child is added. The parent still has to store the new reference.
        var tmpRoot = replaceRef(self.root, before, node), gm = {};
        gm[node.id] = 'split';
        self._step('grow', NAME[before.t] + ' is full (' + CAP[before.t] + ' of ' + CAP[before.t] + '). It is not split: its children are copied into a ' +
          NAME[node.t] + ', the old node is freed, and the parent stores the new reference. Nothing else in the tree changes.',
          { root: tmpRoot, depth: depth, nodes: gm, focus: node.id, hold: 2,
            log: { html: NAME[before.t] + ' → ' + NAME[node.t], state: 'split' },
            question: {
              prompt: NAME[before.t] + ' already has ' + CAP[before.t] + ' children and byte ' + kc(byte) + ' needs a slot. What happens?',
              choices: ['It splits into two ' + NAME[before.t] + ' nodes', 'It is copied into a ' + NAME[node.t], 'A second ' + NAME[before.t] + ' is chained behind it'],
              answer: 1,
              explain: 'A radix node never splits: every key byte maps to exactly one slot of exactly one node. A full node moves to the next larger layout.'
            } });
      }
      addChild(node, byte, chain2);
      var am = chainIds(chain2, 'inserted'), ac = {}, tmp2 = replaceRef(self.root, ref, node), ai = { keys: {}, index: {}, children: {} };
      am[node.id] = 'active'; ac[node.id + ':' + byte] = 'inserted';
      if (node.t === 'n4' || node.t === 'n16') { ai.keys[node.keys.indexOf(byte)] = 'inserted'; ai.children[node.keys.indexOf(byte)] = 'inserted'; }
      else if (node.t === 'n48') { ai.index[byte] = 'inserted'; ai.children[node.index[byte]] = 'inserted'; }
      else ai.children[byte] = 'inserted';
      self._step('add-child', 'Add a child for byte ' + kc(byte, 'inserted') + ' (' + childCount(node) + ' of ' + CAP[node.t] + ' slots used now)' +
        (node.t === 'n4' || node.t === 'n16' ? ', keeping <code>keys[]</code> sorted so that iteration stays in order' : '') + '. ' +
        (key.length - depth - 1 > 0 ? 'The remaining ' + (key.length - depth - 1) + ' key byte' + (key.length - depth - 1 > 1 ? 's go' : ' goes') + ' into a prefix chain below it.' : 'No key bytes remain, so the child is the value itself.'),
        { root: tmp2, depth: key.length, keyState: 'inserted', nodes: am, cells: ac, focus: node.id, insp: ai, log: 'add child ' + esc(showBytes([byte])) });
      return node;
    }

    function splitPrefix(p, i, at) {
      var pm = {}; pm[p.id] = 'split';
      self._step('mismatch', 'Prefix node ' + kb(p.bytes) + ': byte ' + (i + 1) + ' is ' + kc(p.bytes[i], 'deleted') + ' but the key has ' +
        kc(key[at], 'compare') + '. The new key leaves the shared path in the middle of this prefix.',
        { depth: at, nodes: pm, question: {
          prompt: 'The key differs from the prefix ' + kb(p.bytes) + ' at byte ' + (i + 1) + '. What does the tree do?',
          choices: ['Cut the prefix at that byte and put a Node4 there', 'Replace the prefix with the new key', 'Create a second root for the new key'],
          answer: 0,
          explain: 'Bytes before the mismatch stay shared; a Node4 branches on the two different bytes; the rest of each key hangs below it.'
        } });
      var chain = self._newChain(key.slice(at + 1), value);
      var branch = { t: 'n4', id: self._id('n'), keys: [], children: [] };
      var oldByte = p.bytes[i], restLen = p.bytes.length - i - 1, oldSide = p.child, result = branch, head = p.bytes.slice(0, i);
      if (restLen > 0 && i > 0) oldSide = { t: 'prefix', id: self._id('p'), bytes: p.bytes.slice(i + 1), child: p.child };
      self.prefixSplits++;
      if (i > 0) { p.bytes = head; p.child = branch; result = p; }
      else if (restLen > 0) { p.bytes = p.bytes.slice(1); oldSide = p; }
      addChild(branch, oldByte, oldSide);
      addChild(branch, key[at], chain);
      var nm = chainIds(chain, 'inserted'), cm = {};
      nm[branch.id] = 'split';
      cm[branch.id + ':' + key[at]] = 'inserted';
      self._step('split', 'Split the prefix. ' + (head.length ? 'The shared head ' + kb(head) + ' stays. ' : 'Nothing is shared before the mismatch, so no head remains. ') +
        'A new Node4 branches on ' + kc(oldByte) + ' (the old subtree' + (restLen ? ', behind its remaining prefix' : '') + ') and ' + kc(key[at], 'inserted') +
        ' (the new key' + (key.length - at - 1 ? ', behind a prefix with its last ' + (key.length - at - 1) + ' byte' + (key.length - at - 1 > 1 ? 's' : '') : '') + ').',
        { root: replaceRef(self.root, p, result), depth: key.length, keyState: 'inserted', nodes: nm, cells: cm, focus: branch.id, hold: 2,
          log: { html: 'split prefix at byte ' + (i + 1), state: 'split' } });
      return result;
    }

    this.root = insertAt(this.root, 0);
    if (old.v === null) this.len++;
    this._step('done', old.v === null
      ? 'Done. ' + kb(key, 'inserted') + ' is stored; the tree holds ' + this.len + ' key' + (this.len === 1 ? '' : 's') + '. No stored key was compared with the new key at any point.'
      : 'Done. The value of ' + kb(key, 'found') + ' was overwritten.', { depth: key.length, keyState: old.v === null ? 'inserted' : 'found' });
    var steps = this.rec;
    this.rec = null; this.op = null;
    if (steps) { steps.old = old.v; return steps; }
  };

  function chainIds(chain, state) {
    var m = {}, r = chain;
    while (r && r.t === 'prefix') { m[r.id] = state; r = r.child; }
    return m;
  }
  /** Copy of the tree under `rootRef` in which node `from` (by identity) is replaced by `to`. Used for mid-operation snapshots. */
  function replaceRef(rootRef, from, to) {
    if (rootRef === from) return to;
    if (!rootRef || rootRef.t === 'leaf') return rootRef;
    if (rootRef.t === 'prefix') {
      var c = replaceRef(rootRef.child, from, to);
      return c === rootRef.child ? rootRef : { t: 'prefix', id: rootRef.id, bytes: rootRef.bytes, child: c };
    }
    var copy = null;
    eachChild(rootRef, function (byte, child) {
      var c2 = replaceRef(child, from, to);
      if (c2 !== child) { if (!copy) copy = shallowInner(rootRef); setChild(copy, byte, c2); }
    });
    return copy || rootRef;
  }
  function shallowInner(n) {
    var o = { t: n.t, id: n.id };
    if (n.keys) o.keys = n.keys.slice();
    if (n.index) o.index = n.index.slice();
    if (n.count !== undefined) o.count = n.count;
    o.children = n.children.slice();
    return o;
  }

  /** Point lookup (art.zig lookup). Returns {value, steps} or, with record, a step list with .value/.nodes. */
  Art.prototype.lookup = function (key, record) {
    var ref = this.root, depth = 0, nodes = 0, value = null, why = '';
    this.rec = record ? [] : null;
    this.op = { key: key };
    this._step('start', 'Search ' + kb(key) + ': walk from the root, one node per step.', { depth: 0, log: 'get ' + esc(showBytes(key)) });
    for (;;) {
      var nm = {}, cm = {};
      if (!ref) { why = 'The tree is empty.'; break; }
      if (ref.t === 'leaf') {
        if (depth === key.length) value = ref.v; else why = 'A stored key ends here but the search key has more bytes.';
        break;
      }
      nodes++;
      nm[ref.id] = 'active';
      if (ref.t === 'prefix') {
        if (!startsWith(key.slice(depth), ref.bytes)) {
          nm[ref.id] = 'deleted';
          this._step('prefix-miss', 'Prefix node ' + kb(ref.bytes) + ' does not match the next key bytes ' + kb(key.slice(depth, depth + ref.bytes.length), 'compare') +
            '. Every key below this node starts with the prefix, so the search key cannot be here.', { depth: depth, keyState: 'deleted', nodes: nm });
          why = 'x';
          break;
        }
        this._step('prefix-match', 'Prefix node ' + kb(ref.bytes) + ' equals the next ' + (ref.bytes.length > 1 ? ref.bytes.length + ' key bytes: skip them.' : 'key byte: skip it.'),
          { depth: depth + ref.bytes.length, nodes: nm });
        depth += ref.bytes.length;
        ref = ref.child;
        continue;
      }
      if (depth === key.length) { why = 'The search key ends at an inner node; no stored key ends here.'; break; }
      var byte = key[depth], child = childOf(ref, byte);
      cm[ref.id + ':' + byte] = child ? 'found' : 'compare';
      this._step(child ? 'descend' : 'no-child', NAME[ref.t] + ': ' + scanWords(ref) + ' for byte ' + kc(byte, 'compare') + '. ' +
        (child ? 'Found: follow that child.' : 'There is no child for this byte, so the key is not in the tree.'),
        { depth: depth, keyState: child ? 'compare' : 'deleted', nodes: nm, cells: cm, focus: ref.id, insp: inspScan(ref, byte) });
      if (!child) { why = 'x'; break; }
      ref = child;
      depth++;
    }
    if (value !== null) {
      this._step('found', 'All ' + key.length + ' bytes are consumed and the path ends in a leaf: found, value ' + value + '. Nodes visited: ' + nodes + '.',
        { depth: key.length, keyState: 'found' });
    } else {
      this._step('not-found', (why !== 'x' ? why + ' ' : '') + 'Not found after visiting ' + nodes + ' node' + (nodes === 1 ? '' : 's') + '.',
        { depth: depth, keyState: 'deleted' });
    }
    var steps = this.rec;
    this.rec = null; this.op = null;
    if (steps) { steps.value = value; steps.nodes = nodes; return steps; }
    return { value: value, steps: nodes };
  };

  /** All entries in key order: [{key, value}] (art.zig Iterator, written recursively). */
  Art.prototype.entries = function () {
    var out = [];
    (function walk(ref, path) {
      if (!ref) return;
      if (ref.t === 'leaf') out.push({ key: path, value: ref.v });
      else if (ref.t === 'prefix') walk(ref.child, path.concat(ref.bytes));
      else eachChild(ref, function (b, c) { walk(c, path.concat([b])); });
    })(this.root, []);
    return out;
  };

  /** Ordered scan as a recorded timeline: one step per key, depth-first, smallest byte first. */
  Art.prototype.scanSteps = function () {
    var self = this, n = 0, seen = [];
    this.rec = [];
    this.op = { key: [] };
    this._step('start', 'Ordered scan. There are no links between leaves; instead walk depth-first and, in every inner node, visit the children in byte order.', { log: 'scan' });
    (function walk(ref, path, trail) {
      if (!ref) return;
      if (ref.t === 'leaf') {
        n++;
        seen.push(fmtBytes(path));
        self.op = { key: path };
        var nm = {};
        trail.forEach(function (id) { nm[id] = 'active'; });
        self._step('visit', 'Key ' + n + ': ' + kb(path, 'found') + ' = ' + ref.v + '. The key is not stored anywhere in one piece; it is rebuilt from the bytes along the highlighted path.',
          { depth: path.length, keyState: 'found', nodes: nm, log: esc(showBytes(path)) });
      } else if (ref.t === 'prefix') walk(ref.child, path.concat(ref.bytes), trail.concat([ref.id]));
      else eachChild(ref, function (b, c) { walk(c, path.concat([b]), trail.concat([ref.id])); });
    })(this.root, [], []);
    this.op = { key: [] };
    this._step('done', n ? 'Scan complete: ' + n + ' key' + (n === 1 ? '' : 's') + ' in ascending byte order. A hash index cannot do this without sorting.' : 'The tree is empty.', {});
    var steps = this.rec;
    this.rec = null; this.op = null;
    steps.keys = seen;
    return steps;
  };

  /** art.zig census. */
  Art.prototype.census = function () {
    var c = { prefix: 0, n4: 0, n16: 0, n48: 0, n256: 0, leaves: 0, slotsUsed: 0, slotsAllocated: 0, maxPath: 0 };
    (function walk(ref, path) {
      if (!ref) return;
      if (ref.t === 'leaf') { c.leaves++; c.maxPath = Math.max(c.maxPath, path); return; }
      c[ref.t]++;
      if (ref.t === 'prefix') { walk(ref.child, path + 1); return; }
      c.slotsUsed += childCount(ref);
      c.slotsAllocated += CAP[ref.t];
      eachChild(ref, function (b, ch) { walk(ch, path + 1); });
    })(this.root, 0);
    return c;
  };
  Art.prototype.censusLine = function () {
    var c = this.census();
    return 'nodes: prefix=' + c.prefix + ' node4=' + c.n4 + ' node16=' + c.n16 + ' node48=' + c.n48 + ' node256=' + c.n256 +
      '; leaves=' + c.leaves + '; longest path=' + c.maxPath + ' nodes';
  };

  /** art.zig dump, character for character. */
  Art.prototype.dump = function () {
    if (!this.root) return '(empty)\n';
    var out = '';
    (function walk(ref, indent) {
      if (ref.t === 'leaf') { out += 'leaf ' + ref.v + '\n'; return; }
      if (ref.t === 'prefix') { out += 'prefix "' + fmtBytes(ref.bytes) + '" -> '; walk(ref.child, indent); return; }
      out += NAME[ref.t] + ' [' + childCount(ref) + ']\n';
      eachChild(ref, function (b, c) {
        out += new Array(indent + 3).join(' ') + "'" + fmtBytes([b]) + "' -> ";
        walk(c, indent + 2);
      });
    })(this.root, 0);
    return out;
  };

  /* --------------------------------------------- hash index, sorted index */

  /** hash_index.zig: open addressing, linear probing, grow at 70%. Slots hold {key, hash, value} or null. */
  function HashIndex() { this.slots = []; this.len = 0; }
  HashIndex.prototype._probe = function (hash, key) {
    var mask = this.slots.length - 1, i = Number(hash & BigInt(mask)), steps = 1, path = [i];
    while (this.slots[i] && !(this.slots[i].hash === hash && cmpBytes(this.slots[i].key, key) === 0)) {
      i = (i + 1) & mask; steps++; path.push(i);
    }
    return { index: i, steps: steps, path: path };
  };
  HashIndex.prototype.lookup = function (key) {
    if (!this.slots.length) return { value: null, steps: 0, path: [] };
    var p = this._probe(fnv1a(key), key), s = this.slots[p.index];
    return { value: s ? s.value : null, steps: p.steps, path: p.path };
  };
  HashIndex.prototype.put = function (key, value) {
    var hash = fnv1a(key), s;
    if (this.slots.length) {
      s = this.slots[this._probe(hash, key).index];
      if (s) { var old = s.value; s.value = value; return old; }
    }
    if ((this.len + 1) * 10 > this.slots.length * 7) {
      var cap = Math.max(8, this.slots.length * 2), fresh = [], i;
      for (i = 0; i < cap; i++) fresh.push(null);
      this.slots.forEach(function (slot) {
        if (!slot) return;
        var j = Number(slot.hash & BigInt(cap - 1));
        while (fresh[j]) j = (j + 1) & (cap - 1);
        fresh[j] = slot;
      });
      this.slots = fresh;
    }
    this.slots[this._probe(hash, key).index] = { key: key, hash: hash, value: value };
    this.len++;
    return null;
  };

  /** sorted_index.zig: sorted array + binary search that counts whole-key comparisons. */
  function SortedIndex() { this.entries = []; }
  SortedIndex.prototype.lowerBound = function (key, trace) {
    var lo = 0, hi = this.entries.length, n = 0;
    while (lo < hi) {
      var mid = lo + ((hi - lo) >> 1);
      n++;
      if (trace) trace.push({ lo: lo, hi: hi, mid: mid });
      if (cmpBytes(this.entries[mid].key, key) < 0) lo = mid + 1; else hi = mid;
    }
    return { index: lo, compares: n };
  };
  SortedIndex.prototype.lookup = function (key) {
    var lb = this.lowerBound(key), steps = lb.compares;
    if (lb.index === this.entries.length) return { value: null, steps: steps };
    steps++;
    var e = this.entries[lb.index];
    return { value: cmpBytes(e.key, key) === 0 ? e.value : null, steps: steps };
  };
  SortedIndex.prototype.put = function (key, value) {
    var i = this.lowerBound(key).index;
    if (i < this.entries.length && cmpBytes(this.entries[i].key, key) === 0) {
      var old = this.entries[i].value; this.entries[i].value = value; return old;
    }
    this.entries.splice(i, 0, { key: key, value: value });
    return null;
  };

  var api = {
    Art: Art, HashIndex: HashIndex, SortedIndex: SortedIndex, splitmix: splitmix, fnv1a: fnv1a,
    encodeStr: encodeStr, utf8: utf8, fmtBytes: fmtBytes, showBytes: showBytes, cellText: cellText, cmpBytes: cmpBytes, startsWith: startsWith,
    CAP: CAP, NAME: NAME, NEXT: NEXT, EMPTY48: EMPTY48, isInner: isInner, childCount: childCount, eachChild: eachChild
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.ART28 = api;
  if (typeof document === 'undefined') return;

  /* ------------------------------------------------------- ArtView (SVG) */

  var CW = 24, CH = 26, VGAP = 38, HGAP = 18, PAD = 18, LABEL_H = 15;

  /**
   * new ART28.ArtView(target).render(state)
   * Prefix nodes are pills, inner nodes are rows of byte cells (free slots hatched for
   * node4/node16; node48/node256 wrap 16 used bytes per row), leaves are value chips.
   */
  function ArtView(target) {
    this.svg = el('svg', { class: 'a28-svg', role: 'img', 'aria-label': 'Adaptive radix tree' });
    this.scroller = el('div.a28-tree', { tabindex: 0 }, this.svg);
    // Phones draw no scrollbar, so say in words when part of the tree is outside the view.
    this.hint = el('div.a28-scrollhint', { 'aria-live': 'off' });
    var host = typeof target === 'string' ? document.querySelector(target) : target;
    host.appendChild(this.scroller);
    host.appendChild(this.hint);
    this.seen = {};
    this.W = 0;
    var self = this;
    window.addEventListener('resize', function () { self._fit(); });
    this.scroller.addEventListener('scroll', function () { self._hint(); });
  }
  ArtView.prototype._fit = function () {
    if (!this.W) return;
    var avail = this.scroller.clientWidth || this.W;
    // Below 0.75 the byte labels become unreadable; a wider tree scrolls sideways instead.
    var s = Math.max(0.75, Math.min(1, avail / this.W));
    this.svg.setAttribute('width', Math.floor(this.W * s));
    this.svg.setAttribute('height', Math.floor(this.H * s));
    this._hint();
  };
  /** Tell the reader on which side the tree continues beyond the visible part. */
  ArtView.prototype._hint = function () {
    var sc = this.scroller, over = sc.scrollWidth - sc.clientWidth;
    var left = over > 1 && sc.scrollLeft > 1, right = over > 1 && sc.scrollLeft < over - 1;
    sc.classList.toggle('more-left', left);
    sc.classList.toggle('more-right', right);
    this.hint.style.display = left || right ? '' : 'none';
    this.hint.textContent = left && right ? '← the tree continues on both sides: scroll sideways →'
      : left ? '← more of the tree to the left: scroll sideways'
      : right ? 'more of the tree to the right: scroll sideways →' : '';
  };

  function measure(ref) {
    var m = { ref: ref, kids: [], sw: 0 };
    if (ref.t === 'leaf') { m.w = Math.max(34, String(ref.v).length * 8 + 22); m.h = 22; m.sw = m.w; return m; }
    if (ref.t === 'prefix') {
      m.cells = ref.bytes.length; m.w = ref.bytes.length * (CW - 4) + 16; m.h = CH;
      m.kids.push({ m: measure(ref.child), ax: m.w / 2, ay: m.h });
      m.sw = Math.max(m.w, m.kids[0].m.sw);
      return m;
    }
    var bytes = [];
    eachChild(ref, function (b, c) { bytes.push({ b: b, c: c }); });
    var small = ref.t === 'n4' || ref.t === 'n16';
    var cols = small ? CAP[ref.t] : Math.min(16, bytes.length);
    var rows = small ? 1 : Math.ceil(bytes.length / 16);
    m.bytes = bytes; m.cols = cols; m.rows = rows; m.small = small;
    m.w = cols * CW; m.h = rows * CH;
    var total = 0;
    bytes.forEach(function (bc, i) {
      // In the wrapped layouts, leaf children are not drawn: there would be up to 256 of them.
      if (!small && bc.c.t === 'leaf') return;
      var km = measure(bc.c);
      m.kids.push({ m: km, ax: (i % 16) * CW + CW / 2, ay: m.h, byte: bc.b });
      total += km.sw;
    });
    if (m.kids.length) total += HGAP * (m.kids.length - 1);
    m.cw = total;
    m.sw = Math.max(m.w, total);
    m.hidden = bytes.length - m.kids.length;
    return m;
  }
  function place(m, left, top, out) {
    var x;
    if (!m.kids.length) x = left + (m.sw - m.w) / 2;
    else {
      var cl = left + (m.sw - (m.cw === undefined ? m.kids[0].m.sw : m.cw)) / 2;
      m.kids.forEach(function (k) { place(k.m, cl, top + m.h + VGAP, out); cl += k.m.sw + HGAP; });
      var a = m.kids[0].m, b = m.kids[m.kids.length - 1].m;
      x = (a.x + a.w / 2 + b.x + b.w / 2) / 2 - m.w / 2;
      x = Math.max(left, Math.min(left + m.sw - m.w, x));
    }
    m.x = Math.round(x); m.y = top;
    out.push(m);
    out.maxY = Math.max(out.maxY || 0, top + m.h);
  }

  ArtView.prototype.render = function (state) {
    var svg = this.svg, self = this;
    while (svg.firstChild) svg.removeChild(svg.firstChild);
    if (!state.root) {
      this.W = 220; this.H = 70;
      svg.setAttribute('viewBox', '0 0 220 70');
      svg.appendChild(el('text', { x: 110, y: 40, 'text-anchor': 'middle', class: 'a28-empty' }, 'empty tree'));
      this._fit();
      this.seen = {};
      return;
    }
    var top = measure(state.root), list = [];
    place(top, PAD, PAD + LABEL_H, list);
    this.W = top.sw + PAD * 2; this.H = list.maxY + PAD + 8;
    svg.setAttribute('viewBox', '0 0 ' + this.W + ' ' + this.H);
    var edges = el('g'), nodes = el('g'), seenNow = {}, animate = BTViz.motion.duration() > 0;
    var nodeState = state.nodes || {}, cellState = state.cells || {};

    list.forEach(function (m) {
      var r = m.ref, g, st, fresh;
      m.kids.forEach(function (k) {
        var x1 = m.x + k.ax, y1 = m.y + k.ay, x2 = k.m.x + k.m.w / 2, y2 = k.m.y - (k.m.ref.t === 'leaf' ? 0 : 0), my = (y1 + y2) / 2;
        var active = k.m.ref.id && nodeState[k.m.ref.id];
        edges.appendChild(el('path', { class: 'a28-edge' + (active ? ' s-' + nodeState[k.m.ref.id] : ''), d: 'M' + x1 + ' ' + y1 + 'C' + x1 + ' ' + my + ' ' + x2 + ' ' + my + ' ' + x2 + ' ' + y2 }));
      });
      if (r.t === 'leaf') {
        g = el('g', { class: 'a28-leaf', transform: 'translate(' + m.x + ',' + m.y + ')' },
          el('rect', { width: m.w, height: m.h, rx: 11 }),
          el('text', { x: m.w / 2, y: 15, 'text-anchor': 'middle' }, '= ' + r.v));
        nodes.appendChild(g);
        return;
      }
      st = nodeState[r.id];
      fresh = animate && self.seen && Object.keys(self.seen).length && !self.seen[r.id];
      seenNow[r.id] = 1;
      g = el('g', { class: 'a28-node a28-' + r.t + (st ? ' s-' + st : '') + (fresh ? ' is-new' : ''), transform: 'translate(' + m.x + ',' + m.y + ')' });
      if (r.t === 'prefix') {
        g.appendChild(el('rect', { class: 'a28-box', width: m.w, height: m.h, rx: 13 }));
        r.bytes.forEach(function (b, i) {
          g.appendChild(el('text', { class: 'a28-byte' + (cellText(b).length > 1 ? ' is-hex' : ''), x: 8 + i * (CW - 4) + (CW - 4) / 2, y: 18, 'text-anchor': 'middle' }, cellText(b)));
        });
        g.appendChild(el('svg:title', 'prefix node: ' + r.bytes.length + ' shared byte' + (r.bytes.length > 1 ? 's' : '') + ' "' + fmtBytes(r.bytes) + '"'));
      } else {
        // Right-aligned just left of the centre, where the edge from the parent arrives.
        g.appendChild(el('text', { class: 'a28-label', x: m.w / 2 - 7, y: -5, 'text-anchor': 'end' }, NAME[r.t] + ' ' + childCount(r) + '/' + CAP[r.t]));
        g.appendChild(el('rect', { class: 'a28-box', width: m.w, height: m.h, rx: 4 }));
        for (var i = 0; i < m.cols * m.rows; i++) {
          var bc = m.bytes[i], cx = (i % m.cols) * CW, cy = Math.floor(i / m.cols) * CH;
          if (!bc) {
            if (m.small) g.appendChild(el('rect', { class: 'a28-cell is-free', x: cx + 1.5, y: cy + 1.5, width: CW - 3, height: CH - 3, rx: 3 }));
            continue;
          }
          var cs = cellState[r.id + ':' + bc.b];
          g.appendChild(el('rect', { class: 'a28-cell' + (cs ? ' s-' + cs : ''), x: cx + 1.5, y: cy + 1.5, width: CW - 3, height: CH - 3, rx: 3 }));
          g.appendChild(el('text', { class: 'a28-byte' + (cellText(bc.b).length > 1 ? ' is-hex' : ''), x: cx + CW / 2, y: cy + 18, 'text-anchor': 'middle' }, cellText(bc.b)));
        }
        if (m.hidden) g.appendChild(el('text', { class: 'a28-note', x: 0, y: m.h + 13 }, m.hidden + ' leaf children not drawn'));
      }
      nodes.appendChild(g);
    });
    svg.appendChild(edges);
    svg.appendChild(nodes);
    this.seen = seenNow;
    this._fit();
    // keep the active node in view inside the scroller
    var act = svg.querySelector('.a28-node.s-active, .a28-node.s-split, .a28-node.s-inserted');
    if (act && this.scroller.scrollWidth > this.scroller.clientWidth + 1) {
      var a = act.getBoundingClientRect(), b = this.scroller.getBoundingClientRect();
      if (a.left < b.left + 8 || a.right > b.right - 8) this.scroller.scrollLeft += a.left - b.left - (b.width - a.width) / 2;
    }
    this._hint();
  };

  /* ------------------------------------------- Inspector (node layout) */

  /** new ART28.Inspector(target).render(node | null, insp) — draws keys[] / index[256] / children[] as they are in memory. */
  function Inspector(target) {
    this.root = el('div.bt-panel.a28-insp');
    (typeof target === 'string' ? document.querySelector(target) : target).appendChild(this.root);
  }
  function findNode(ref, id) {
    if (!ref || ref.t === 'leaf') return null;
    if (ref.id === id) return ref;
    if (ref.t === 'prefix') return findNode(ref.child, id);
    var hit = null;
    eachChild(ref, function (b, c) { if (!hit) hit = findNode(c, id); });
    return hit;
  }
  function childMark(c) { return !c ? '' : c.t === 'leaf' ? '=' + c.v : c.t === 'prefix' ? 'p' : 'n'; }
  function childTitle(c) {
    return !c ? 'free slot' : c.t === 'leaf' ? 'leaf (inlined value ' + c.v + ')' : c.t === 'prefix' ? 'prefix node "' + fmtBytes(c.bytes) + '"' : NAME[c.t];
  }
  function cell(text, state, title, extra) {
    return el('span', { class: 'a28-c' + (state ? ' s-' + state : '') + (extra ? ' ' + extra : ''), title: title || null }, text);
  }
  Inspector.prototype.render = function (rootRef, focusId, insp) {
    var n = focusId ? findNode(rootRef, focusId) : null, host = this.root, i;
    insp = insp || {};
    var ik = insp.keys || {}, ix = insp.index || {}, ic = insp.children || {};
    host.textContent = '';
    host.appendChild(el('div.bt-panel-title', 'Memory layout of the node being worked on'));
    var body = el('div.bt-panel-body');
    host.appendChild(body);
    var ladder = el('div.a28-ladder', { 'aria-label': 'The four layouts' });
    ['n4', 'n16', 'n48', 'n256'].forEach(function (t, j) {
      if (j) ladder.appendChild(el('span.a28-arrow', { 'aria-hidden': 'true' }, '→'));
      ladder.appendChild(el('span', { class: 'bt-chip' + (n && n.t === t ? ' s-active' : '') }, NAME[t]));
    });
    body.appendChild(ladder);
    if (!n || !isInner(n)) {
      body.appendChild(el('p.a28-hint', 'No inner node is involved in this step. Prefix nodes hold up to 7 bytes and one child; leaves are values stored inside the parent’s child slot.'));
      return;
    }
    body.appendChild(el('p.a28-hint', { html: '<b>' + NAME[n.t] + '</b>: ' + childCount(n) + ' of ' + CAP[n.t] + ' child slots used. ' + ({
      n4: 'Sorted key bytes next to their children. Finding a byte scans at most 4 entries.',
      n16: 'Same layout as node4 with 16 entries. Finding a byte scans at most 16 entries.',
      n48: '<code>index[byte]</code> holds a position in <code>children[]</code> (blank = no child). Two reads, no scan.',
      n256: '<code>children[byte]</code> directly. One read.'
    })[n.t] }));
    var grid;
    if (n.t === 'n4' || n.t === 'n16') {
      grid = el('div.a28-pairs');
      grid.appendChild(el('span.a28-pair.a28-rowlabels', el('span', 'keys[i]'), el('span', 'children[i]')));
      for (i = 0; i < CAP[n.t]; i++) {
        var used = i < n.keys.length;
        grid.appendChild(el('span.a28-pair',
          cell(used ? cellText(n.keys[i]) : '', used ? ik[i] : null, used ? 'keys[' + i + '] = 0x' + hex2(n.keys[i]) : 'free', used ? '' : 'is-free'),
          cell(used ? childMark(n.children[i]) : '', used ? ic[i] : null, used ? childTitle(n.children[i]) : 'free', used ? 'is-child' : 'is-free')));
      }
      body.appendChild(grid);
    } else if (n.t === 'n48') {
      body.appendChild(el('div.a28-gridlabel', 'index[256]: one byte per possible key byte, row = high hex digit'));
      grid = el('div.a28-grid');
      for (i = 0; i < 256; i++) {
        var slot = n.index[i];
        grid.appendChild(cell(slot === EMPTY48 ? '' : String(slot), ix[i], 'index[0x' + hex2(i) + '] = ' + (slot === EMPTY48 ? '48 (empty)' : slot), slot === EMPTY48 ? 'is-blank' : 'is-child'));
      }
      body.appendChild(grid);
      body.appendChild(el('div.a28-gridlabel', 'children[48]: filled in arrival order'));
      grid = el('div.a28-grid');
      for (i = 0; i < 48; i++) grid.appendChild(cell(i < n.count ? '●' : '', ic[i], i < n.count ? 'children[' + i + ']: ' + childTitle(n.children[i]) : 'free', i < n.count ? 'is-child' : 'is-free'));
      body.appendChild(grid);
    } else {
      body.appendChild(el('div.a28-gridlabel', 'children[256]: one slot per possible key byte, row = high hex digit'));
      grid = el('div.a28-grid');
      for (i = 0; i < 256; i++) grid.appendChild(cell(n.children[i] ? '●' : '', ic[i], 'children[0x' + hex2(i) + ']: ' + childTitle(n.children[i]), n.children[i] ? 'is-child' : 'is-free'));
      body.appendChild(grid);
    }
  };

  api.ArtView = ArtView;
  api.Inspector = Inspector;
})(typeof window !== 'undefined' ? window : globalThis);

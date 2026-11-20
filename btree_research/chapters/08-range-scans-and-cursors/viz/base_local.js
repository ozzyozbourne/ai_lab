/*
 * Copied from chapters/07-bplus-trees/viz/local.js; do not edit here.
 * The JavaScript port of the chapter 07 B+tree (window.Ch07). Chapter 08's own
 * model (cursors, scans) is in local.js and builds on this file unchanged.
 */
/*
 * Chapter 07 — chapter-local model. A line-for-line JavaScript port of the chapter's
 * B+tree (zig/src/{arena,insert,delete,validate,dump}.zig), emitting BTViz steps.
 *
 * Why not BTViz.models.BPlusTree? The shared model uses a different leaf minimum and
 * split point, has no `prev` links and no arena. This page must reproduce the exact
 * handles, free list and shapes that the Zig and Rust programs print, so it carries
 * its own model. The classic B-tree on the page is the shared BTViz.models.BTree.
 *
 * Pure data, no DOM: also runs under node (see the self-tests in index.html).
 */
(function (root) {
  'use strict';

  var NIL = -1;
  var kfmt = function (v, state) {
    return root.BTViz && root.BTViz.k ? root.BTViz.k(v, state) : String(v);
  };
  function mk(key, value) { var o = {}; o[key] = value; return o; }
  function plural(n, word) { return n + ' ' + word + (n === 1 ? '' : 's'); }

  /* ------------------------------------------------------------------ search */

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

  /* ------------------------------------------------------------------- model */

  /**
   * BPlus(order): order M = maximum number of children. Nodes live in `slots`
   * (the arena); a handle is an index into it. A slot is {used: true, node, gen}
   * or {used: false, next, gen}; `freeHead` starts the free list.
   */
  function BPlus(order) {
    if (!(this instanceof BPlus)) return new BPlus(order);
    this.order = order === undefined ? 4 : order;
    this.slots = [];
    this.freeHead = NIL;
    this.live = 0;
    this.root = NIL;
    this.firstLeaf = NIL;
    this.lastLeaf = NIL;
    this.height = 0;
    this.count = 0;
    this.stats = { leafSplits: 0, internalSplits: 0, borrows: 0, merges: 0 };
    this._rec = null;
  }
  var P = BPlus.prototype;

  P.maxKeys = function () { return this.order - 1; };
  P.minKeys = function () { return Math.ceil(this.order / 2) - 1; };
  P.node = function (h) { return this.slots[h].node; };

  // ---- arena ----
  P._alloc = function (node) {
    this.live++;
    if (this.freeHead !== NIL) {
      var h = this.freeHead, slot = this.slots[h];
      this.freeHead = slot.next;                      // pop the free list
      this.slots[h] = { used: true, node: node, gen: slot.gen + 1 };
      return h;
    }
    this.slots.push({ used: true, node: node, gen: 0 });
    return this.slots.length - 1;
  };
  P._free = function (h) {
    var slot = this.slots[h];
    this.slots[h] = { used: false, next: this.freeHead, gen: slot.gen };   // push
    this.freeHead = h;
    this.live--;
  };
  P.freeList = function () {
    var out = [];
    for (var h = this.freeHead; h !== NIL; h = this.slots[h].next) out.push(h);
    return out;
  };
  function newLeaf() { return { leaf: true, keys: [], vals: [], prev: NIL, next: NIL }; }
  function newInternal() { return { leaf: false, keys: [], children: [] }; }

  // ---- reads ----
  P.findLeaf = function (key) {
    var h = this.root;
    if (h === NIL) return NIL;
    for (;;) {
      var n = this.node(h);
      if (n.leaf) return h;
      h = n.children[upperBound(n.keys, key)];
    }
  };
  P.get = function (key) {
    var h = this.findLeaf(key);
    if (h === NIL) return null;
    var n = this.node(h), i = lowerBound(n.keys, key);
    return i < n.keys.length && n.keys[i] === key ? n.vals[i] : null;
  };
  /** All keys in order, by walking the leaf chain forward. */
  P.keys = function () {
    var out = [];
    for (var h = this.firstLeaf; h !== NIL; h = this.node(h).next) out.push.apply(out, this.node(h).keys);
    return out;
  };
  /** Separators in tree order; `stale` = no leaf holds that key any more. */
  P.separators = function () {
    var out = [], self = this;
    if (this.root === NIL) return out;
    (function walk(h) {
      var n = self.node(h);
      if (n.leaf) return;
      for (var i = 0; i < n.children.length; i++) {
        walk(n.children[i]);
        if (i < n.keys.length) out.push({ key: n.keys[i], node: h, stale: self.get(n.keys[i]) === null });
      }
    })(this.root);
    return out;
  };

  // ---- steps ----
  P._begin = function (record) { this._rec = record === false ? null : []; };
  P._end = function (extra) {
    var steps = this._rec || [];
    this._rec = null;
    for (var p in (extra || {})) steps[p] = extra[p];
    return steps;
  };
  P.id = function (h) { return 'h' + h + '.' + this.slots[h].gen; };
  P.name = function (h) { return '#' + h; };
  P.fmt = function (h) {
    var n = this.node(h);
    return this.name(h) + (n.leaf ? '(' : '[') + n.keys.join(' ') + (n.leaf ? ')' : ']');
  };
  /** Snapshot for the page: TreeView model + leaf chain + arena slots. */
  P.snapshot = function () {
    var self = this;
    var copy = function (h) {
      var n = self.node(h);
      var o = { id: self.id(h), keys: n.keys.slice(), leaf: n.leaf, children: n.leaf ? [] : n.children.map(copy), meta: { label: self.name(h) } };
      if (n.leaf) o.next = n.next === NIL ? null : self.id(n.next);
      return o;
    };
    var chain = [];
    for (var h = this.firstLeaf; h !== NIL; h = this.node(h).next) chain.push({ h: h, id: this.id(h), keys: this.node(h).keys.slice(), prev: this.node(h).prev });
    return {
      tree: this.root === NIL ? null : copy(this.root),
      chain: chain,
      arena: this.slots.map(function (s, h) { return s.used ? { h: h, state: s.node.leaf ? 'leaf' : 'internal' } : { h: h, state: 'free' }; }),
      free: this.freeList(),
      stale: this.root === NIL ? [] : this.separators().filter(function (s) { return s.stale; }).map(function (s) { return self.id(s.node) + ':' + s.key; }),
      height: this.height, count: this.count, nodes: this.live
    };
  };
  /** hl: {nodes, keys, edges, links, arena: {handle: state}, chain: {handle: state}}; keys use handles. */
  P._emit = function (type, caption, hl, extra) {
    if (!this._rec) return;
    var self = this, out = { nodes: {}, keys: {}, edges: {}, links: {}, arena: {}, chain: {} };
    hl = hl || {};
    var live = function (h) { return self.slots[h] && self.slots[h].used; };
    Object.keys(hl.nodes || {}).forEach(function (h) { if (live(h)) out.nodes[self.id(+h)] = hl.nodes[h]; });
    Object.keys(hl.edges || {}).forEach(function (h) { if (live(h)) out.edges[self.id(+h)] = hl.edges[h]; });
    Object.keys(hl.links || {}).forEach(function (h) { if (live(h)) out.links[self.id(+h)] = hl.links[h]; });
    (hl.keys || []).forEach(function (t) { if (live(t[0])) out.keys[self.id(t[0]) + ':' + t[1]] = t[2]; });
    out.arena = hl.arena || {};
    out.chain = hl.chain || {};
    var step = { type: type, caption: caption, state: this.snapshot(), highlight: out, log: null };
    for (var p in (extra || {})) step[p] = extra[p];
    this._rec.push(step);
  };

  /** Root-to-leaf path [{h, ci}] (ci = child index taken), emitting one step per internal node. */
  P._descend = function (key) {
    var path = [], h = this.root, K = kfmt(key);
    for (;;) {
      var n = this.node(h);
      if (n.leaf) { path.push({ h: h, ci: -1 }); return path; }
      var ci = upperBound(n.keys, key);
      var eq = ci > 0 && n.keys[ci - 1] === key;
      var text;
      if (ci === 0) text = K + ' &lt; ' + kfmt(n.keys[0], 'compare') + ': follow the leftmost child.';
      else if (ci === n.keys.length) text = K + ' ≥ ' + kfmt(n.keys[ci - 1], 'compare') + ': follow the rightmost child.';
      else text = kfmt(n.keys[ci - 1], 'compare') + ' ≤ ' + K + ' &lt; ' + kfmt(n.keys[ci], 'compare') + ': follow child ' + ci + '.';
      if (eq) text += ' The key equals a separator, and the search still goes on: a separator is only a signpost, the entry is in a leaf to the right.';
      this._emit('descend', 'Internal node ' + this.fmt(h) + ' holds separators only. ' + text, {
        nodes: mk(h, 'active'), edges: mk(n.children[ci], 'active'),
        keys: n.keys.slice(0, Math.min(n.keys.length, ci + 1)).map(function (kv) { return [h, kv, 'compare']; })
      }, { lines: { snippet: 'search', part: 'route' } });
      path.push({ h: h, ci: ci });
      h = n.children[ci];
    }
  };

  // ---- put ----
  /** put(key, value[, {steps: false}]) → steps; steps.old = previous value or null. */
  P.put = function (key, value, opts) {
    this._begin(opts && opts.steps);
    var K = kfmt(key), self = this, max = this.maxKeys();
    if (this.root === NIL) {
      var first = this._alloc(newLeaf());
      this.root = this.firstLeaf = this.lastLeaf = first;
      this.height = 1;
      this._emit('first-leaf', 'The tree is empty. Allocate the first leaf: slot ' + this.name(first) + ' of the arena. It is the root, the first leaf and the last leaf at once.',
        { nodes: mk(first, 'active'), arena: mk(first, 'inserted') }, { log: 'allocate ' + this.name(first) });
    }
    this._emit('start', 'Insert ' + K + ': walk from the root to the leaf whose key range contains it.', { nodes: mk(this.root, 'active') }, { log: 'put ' + key });
    var path = this._descend(key);
    var leafH = path[path.length - 1].h, leaf = this.node(leafH);
    var i = lowerBound(leaf.keys, key);
    if (i < leaf.keys.length && leaf.keys[i] === key) {
      var old = leaf.vals[i];
      leaf.vals[i] = value;
      this._emit('replace', kfmt(key, 'found') + ' is already in leaf ' + this.fmt(leafH) + '. Keys are unique, so <code>put</code> overwrites the value and the structure does not change.',
        { nodes: mk(leafH, 'found'), keys: [[leafH, key, 'found']] }, { log: 'overwrite ' + key });
      return this._end({ old: old, ok: false });
    }
    leaf.keys.splice(i, 0, key);
    leaf.vals.splice(i, 0, value);
    this.count++;
    var over = leaf.keys.length > max;
    this._emit('insert-leaf', 'Put ' + kfmt(key, 'inserted') + ' and its value into leaf ' + this.name(leafH) + ' at position ' + i + '. The leaf holds ' + plural(leaf.keys.length, 'key') +
      (over ? ', one more than the maximum of ' + max + '.' : ' (maximum ' + max + '). Nothing else changes.'),
      { nodes: mk(leafH, 'active'), keys: [[leafH, key, 'inserted']] });

    // Split overflowing nodes bottom-up along the path.
    for (var level = path.length - 1; level >= 0; level--) {
      var leftH = path[level].h, left = this.node(leftH);
      if (left.keys.length <= max) break;
      var mid = left.keys.length >> 1, right, rightH, sep, hl, question;
      if (left.leaf) {
        this._emit('overflow', 'Leaf ' + this.fmt(leftH) + ' overflows. Split it in the middle: ' + plural(mid, 'key') + ' stay, ' + plural(left.keys.length - mid, 'key') + ' move to a new leaf.',
          { nodes: mk(leftH, 'split'), keys: [[leftH, left.keys[mid], 'split']] }, { lines: { snippet: 'splitLeaf', part: 'divide' } });
        question = {
          prompt: 'The leaf splits at ' + kfmt(left.keys[mid], 'split') + '. What happens to that key?',
          choices: ['It moves up into the parent and leaves the leaf', 'A copy goes up; the key and its value stay in the new right leaf'],
          answer: 1,
          explain: 'Leaf split = copy-up. Values live only in leaves, so the entry cannot leave the leaf level.'
        };
        right = newLeaf();
        right.keys = left.keys.splice(mid);
        right.vals = left.vals.splice(mid);
        rightH = this._alloc(right);
        // Splice into the chain: left <-> right <-> old next.
        right.prev = leftH;
        right.next = left.next;
        left.next = rightH;
        if (right.next !== NIL) this.node(right.next).prev = rightH; else this.lastLeaf = rightH;
        this.stats.leafSplits++;
        sep = right.keys[0];                              // COPY-UP
      } else {
        this._emit('overflow', 'Internal node ' + this.fmt(leftH) + ' overflows too (' + plural(left.keys.length, 'separator') + ', maximum ' + max + '). Split it around ' + kfmt(left.keys[mid], 'split') + '.',
          { nodes: mk(leftH, 'split'), keys: [[leftH, left.keys[mid], 'split']] }, { lines: { snippet: 'splitInternal', part: 'divide' } });
        question = {
          prompt: 'The internal node splits around ' + kfmt(left.keys[mid], 'split') + '. Is that separator copied or moved?',
          choices: ['Moved: it goes up and is in neither half', 'Copied: it stays in one half as well'],
          answer: 0,
          explain: 'Internal split = push-up, exactly as in a classic B-tree. One separator per boundary is enough.'
        };
        right = newInternal();
        sep = left.keys[mid];                             // PUSH-UP
        right.keys = left.keys.splice(mid + 1);
        left.keys.pop();
        right.children = left.children.splice(mid + 1);
        rightH = this._alloc(right);
        this.stats.internalSplits++;
      }
      var how = left.leaf
        ? '<b>Copy-up</b>: ' + kfmt(sep, 'split') + ' is copied into the parent and <em>also stays</em> as the first key of ' + this.name(rightH) + '.'
        : '<b>Push-up</b>: ' + kfmt(sep, 'split') + ' moves into the parent and is in neither half.';
      var chainNote = left.leaf ? ' The new leaf is linked in after ' + this.name(leftH) + ' (next and prev on both sides).' : '';
      hl = { nodes: {}, keys: [], arena: mk(rightH, 'inserted'), chain: left.leaf ? mk(rightH, 'inserted') : {}, links: left.leaf ? mk(leftH, 'active') : {} };
      hl.nodes[leftH] = 'split'; hl.nodes[rightH] = 'split';
      var lines = left.leaf ? { snippet: 'splitLeaf', part: 'link' } : { snippet: 'splitInternal', part: 'pushup' };
      if (level === 0) {
        var nr = newInternal();
        nr.keys = [sep];
        nr.children = [leftH, rightH];
        var rootH = this._alloc(nr);
        this.root = rootH;
        this.height++;
        hl.nodes[rootH] = 'active'; hl.keys.push([rootH, sep, 'split']); hl.arena[rootH] = 'inserted';
        if (left.leaf) hl.keys.push([rightH, sep, 'split']);
        this._emit('root-grow', this.fmt(leftH) + ' keeps its handle, the upper half goes to new node ' + this.fmt(rightH) + '. ' + how + chainNote +
          ' The node that split was the root, so a new root ' + this.name(rootH) + ' is allocated above the halves: height ' + this.height + '.', hl,
          { lines: lines, question: question, log: { html: (left.leaf ? 'copy up ' : 'push up ') + sep + ', new root ' + this.name(rootH), state: 'split' } });
      } else {
        var parentH = path[level - 1].h, parent = this.node(parentH), pi = path[level - 1].ci;
        parent.keys.splice(pi, 0, sep);
        parent.children.splice(pi + 1, 0, rightH);
        hl.keys.push([parentH, sep, 'split']);
        if (left.leaf) hl.keys.push([rightH, sep, 'split']);
        this._emit('split', this.fmt(leftH) + ' keeps its handle, the upper half goes to new node ' + this.fmt(rightH) + '. ' + how + chainNote +
          ' The parent ' + this.name(parentH) + ' now has ' + plural(parent.keys.length, 'separator') + '.', hl,
          { lines: lines, question: question, log: { html: (left.leaf ? 'copy up ' : 'push up ') + sep + ' → ' + this.name(parentH), state: 'split' } });
      }
    }
    this._emit('done', 'Done: ' + plural(this.count, 'key') + ' in ' + plural(this.live, 'node') + ', height ' + this.height + '.',
      { keys: [[this.findLeaf(key), key, 'inserted']] });
    return this._end({ old: null, ok: true });
  };

  // ---- delete ----
  /** delete(key[, {steps: false}]) → steps; steps.removed = value or null. */
  P.delete = function (key, opts) {
    this._begin(opts && opts.steps);
    var K = kfmt(key), self = this, min = this.minKeys();
    if (this.root === NIL) {
      this._emit('not-found', 'The tree is empty: nothing to delete.', {}, { log: key + ' not found' });
      return this._end({ removed: null, ok: false });
    }
    this._emit('start', 'Delete ' + K + ': find its leaf. Entries are only in leaves, so there is no "delete from an internal node" case.', { nodes: mk(this.root, 'active') }, { log: 'delete ' + key });
    var path = this._descend(key);
    var leafH = path[path.length - 1].h, leaf = this.node(leafH);
    var i = lowerBound(leaf.keys, key);
    if (i === leaf.keys.length || leaf.keys[i] !== key) {
      this._emit('not-found', K + ' is not in leaf ' + this.fmt(leafH) + ', so it is not in the tree.', { nodes: mk(leafH, 'active') }, { log: key + ' not found' });
      return this._end({ removed: null, ok: false });
    }
    var sepHolder = this.separators().filter(function (s) { return s.key === key; })[0];
    this._emit('found', 'Found ' + kfmt(key, 'deleted') + ' in leaf ' + this.fmt(leafH) + '.', { nodes: mk(leafH, 'active'), keys: [[leafH, key, 'deleted']] }, { lines: { snippet: 'search', part: 'leaf' } });
    var removed = leaf.vals[i];
    leaf.keys.splice(i, 1);
    leaf.vals.splice(i, 1);
    this.count--;
    this._emit('remove', 'Removed. ' + (sepHolder
      ? 'The copy of ' + kfmt(key, 'compare') + ' in internal node ' + this.name(sepHolder.node) + ' <em>stays</em>: it is now a stale separator. It still routes correctly ("keys ≥ ' + key + ' are to the right"), it just names no existing key.'
      : 'No internal node was touched.') +
      (leaf.keys.length < min && path.length > 1 ? ' But the leaf now has ' + plural(leaf.keys.length, 'key') + ', below the minimum of ' + min + '.' : ''),
      { nodes: mk(leafH, leaf.keys.length < min && path.length > 1 ? 'merge' : 'active'), keys: sepHolder ? [[sepHolder.node, key, 'compare']] : [] },
      {});

    // Repair underfull nodes bottom-up.
    for (var level = path.length - 1; level > 0; level--) {
      var childH = path[level].h, child = this.node(childH);
      if (child.keys.length >= min) break;
      var parentH = path[level - 1].h, parent = this.node(parentH), ci = path[level - 1].ci;
      var leftH = ci > 0 ? parent.children[ci - 1] : NIL, rightH = ci < parent.keys.length ? parent.children[ci + 1] : NIL;
      var hl = { nodes: {}, keys: [], arena: {}, chain: {} }, moved, up;
      if (leftH !== NIL && this.node(leftH).keys.length > min) {
        var L = this.node(leftH);
        if (child.leaf) {
          moved = L.keys.pop();
          child.keys.unshift(moved);
          child.vals.unshift(L.vals.pop());
          parent.keys[ci - 1] = child.keys[0];
          hl.keys.push([childH, moved, 'inserted'], [parentH, moved, 'split']);
          this._note('borrow', 'The left sibling ' + this.name(leftH) + ' has a key to spare. Its last entry ' + kfmt(moved, 'inserted') + ' moves over, and the separator between the two leaves is overwritten with a fresh copy of ' + this.name(childH) + '\'s new first key, ' + kfmt(moved, 'split') + '.', hl, childH, leftH, 'left');
        } else {
          var down = parent.keys[ci - 1];
          up = L.keys.pop();
          child.keys.unshift(down);
          child.children.unshift(L.children.pop());
          parent.keys[ci - 1] = up;
          hl.keys.push([childH, down, 'inserted'], [parentH, up, 'split']);
          this._note('borrow', 'Internal node ' + this.name(childH) + ' is underfull; its left sibling can spare a separator. Rotate through the parent as in a classic B-tree: ' + kfmt(down, 'inserted') + ' comes down, ' + kfmt(up, 'split') + ' goes up, and one child changes parent.', hl, childH, leftH, null);
        }
        this.stats.borrows++;
        break;
      }
      if (rightH !== NIL && this.node(rightH).keys.length > min) {
        var R = this.node(rightH);
        if (child.leaf) {
          moved = R.keys.shift();
          child.keys.push(moved);
          child.vals.push(R.vals.shift());
          parent.keys[ci] = R.keys[0];
          hl.keys.push([childH, moved, 'inserted'], [parentH, R.keys[0], 'split']);
          this._note('borrow', 'The right sibling ' + this.name(rightH) + ' has a key to spare. Its first entry ' + kfmt(moved, 'inserted') + ' moves over, and the separator between the two leaves is overwritten with a copy of the sibling\'s new first key, ' + kfmt(R.keys[0], 'split') + '.', hl, childH, rightH, 'right');
        } else {
          var down2 = parent.keys[ci];
          up = R.keys.shift();
          child.keys.push(down2);
          child.children.push(R.children.shift());
          parent.keys[ci] = up;
          hl.keys.push([childH, down2, 'inserted'], [parentH, up, 'split']);
          this._note('borrow', 'Internal node ' + this.name(childH) + ' is underfull; its right sibling can spare a separator. Rotate through the parent: ' + kfmt(down2, 'inserted') + ' comes down, ' + kfmt(up, 'split') + ' goes up, and one child changes parent.', hl, childH, rightH, null);
        }
        this.stats.borrows++;
        break;
      }
      // Merge: always the right node of the pair INTO the left one.
      var li = leftH !== NIL ? ci - 1 : ci;
      var aH = parent.children[li], bH = parent.children[li + 1], a = this.node(aH), b = this.node(bH);
      var sep = parent.keys[li], text;
      if (a.leaf) {
        a.keys = a.keys.concat(b.keys);
        a.vals = a.vals.concat(b.vals);
        a.next = b.next;
        if (b.next !== NIL) this.node(b.next).prev = aH; else this.lastLeaf = aH;
        text = 'Neither sibling can spare a key, so leaf ' + this.name(bH) + ' is merged into ' + this.name(aH) + '. The separator ' + kfmt(sep, 'deleted') + ' between them was only a copy: it is <em>dropped</em>. ' + this.name(bH) + ' is unlinked from the chain';
        hl.chain[aH] = 'merge';
      } else {
        a.keys = a.keys.concat([sep], b.keys);
        a.children = a.children.concat(b.children);
        text = 'Neither sibling can spare a separator, so internal node ' + this.name(bH) + ' is merged into ' + this.name(aH) + '. The separator ' + kfmt(sep, 'merge') + ' between them is real routing information: it is <em>pulled down</em> into the merged node. ' + this.name(bH) + ' is freed';
        hl.keys.push([aH, sep, 'merge']);
      }
      parent.keys.splice(li, 1);
      parent.children.splice(li + 1, 1);
      this._free(bH);
      this.stats.merges++;
      hl.nodes[aH] = 'merge';
      hl.arena[bH] = 'deleted';
      path[level].h = aH;
      this._emit('merge', text + ' and its slot goes to the head of the free list. The parent ' + this.name(parentH) + ' lost a separator' +
        (parent.keys.length < min && level - 1 > 0 ? ' and is now underfull itself.' : '.'), hl,
        { lines: { snippet: 'merge', part: a.leaf ? 'leaf' : 'internal' },
          log: { html: 'merge ' + this.name(bH) + ' into ' + this.name(aH) + ', free ' + this.name(bH), state: 'merge' } });
    }

    // The root may be underfull but not empty.
    var rootNode = this.node(this.root);
    if (rootNode.keys.length === 0) {
      var oldRoot = this.root;
      if (rootNode.leaf) {
        this.root = this.firstLeaf = this.lastLeaf = NIL;
        this._free(oldRoot);
        this.height--;
        this._emit('root-shrink', 'That was the last entry. The root leaf ' + this.name(oldRoot) + ' is freed: the tree is empty and uses no nodes.',
          { arena: mk(oldRoot, 'deleted') }, { log: { html: 'free ' + this.name(oldRoot) + ' → empty tree', state: 'merge' } });
      } else {
        this.root = rootNode.children[0];
        this._free(oldRoot);
        this.height--;
        this._emit('root-shrink', 'The root ' + this.name(oldRoot) + ' has no separator left and only one child. That child, ' + this.name(this.root) + ', becomes the root and ' + this.name(oldRoot) + ' is freed: height ' + this.height + '. Every path got one level shorter at once.',
          { nodes: mk(this.root, 'active'), arena: mk(oldRoot, 'deleted') }, { log: { html: 'root removed, free ' + this.name(oldRoot) + ' → height ' + this.height, state: 'merge' } });
      }
    }
    this._emit('done', 'Done: ' + plural(this.count, 'key') + ' in ' + plural(this.live, 'node') + ', height ' + this.height + '.', {});
    return this._end({ removed: removed, ok: true });
  };
  P._note = function (type, caption, hl, childH, siblingH, part) {
    hl.nodes[childH] = 'merge';
    hl.nodes[siblingH] = 'active';
    this._emit(type, caption, hl, {
      lines: part ? { snippet: 'borrow', part: part } : null,
      log: { html: 'borrow from ' + this.name(siblingH), state: 'merge' }
    });
  };

  // ---- search ----
  P.search = function (key) {
    this._begin(true);
    var K = kfmt(key);
    if (this.root === NIL) {
      this._emit('not-found', 'The tree is empty.', {});
      return this._end({ found: false });
    }
    this._emit('start', 'Search for ' + K + ' in the B+tree. Every lookup ends in a leaf.', { nodes: mk(this.root, 'active') }, { log: 'get ' + key });
    var path = this._descend(key), h = path[path.length - 1].h, n = this.node(h);
    var i = lowerBound(n.keys, key), found = i < n.keys.length && n.keys[i] === key;
    this._emit(found ? 'found' : 'not-found', found
      ? 'Found ' + kfmt(key, 'found') + ' in leaf ' + this.fmt(h) + ', next to its value. ' + plural(path.length, 'node') + ' visited: always exactly the height of the tree.'
      : K + ' is not in leaf ' + this.fmt(h) + ', so it is not in the tree' + (this.separators().some(function (s) { return s.key === key; }) ? ' — even though an internal node still shows it as a (stale) separator.' : '.'),
      { nodes: mk(h, found ? 'found' : 'active'), keys: found ? [[h, key, 'found']] : [] }, { lines: { snippet: 'search', part: 'leaf' }, log: { html: found ? 'found ' + key : key + ' not found', state: found ? 'found' : null } });
    return this._end({ found: found });
  };

  // ---- validate (same checks as validate.zig; returns [] when valid) ----
  P.validate = function () {
    var errs = [], self = this, max = this.maxKeys(), min = this.minKeys();
    if (this.root === NIL) {
      if (this.firstLeaf !== NIL || this.lastLeaf !== NIL || this.height !== 0 || this.count !== 0) errs.push('BadRoot');
      if (this.live !== 0) errs.push('ArenaLeak');
    } else {
      var w = { expected: this.firstLeaf, prev: NIL, entries: 0, nodes: 0 };
      (function check(h, depth, lo, hi) {
        var n = self.node(h);
        w.nodes++;
        if (n.keys.length > max) errs.push('NodeOverfull ' + h);
        if (n.keys.length < (h === self.root ? 1 : min)) errs.push('NodeUnderfull ' + h);
        n.keys.forEach(function (kv, i) {
          if (i > 0 && n.keys[i - 1] >= kv) errs.push('KeysNotSorted ' + h);
          if ((lo !== null && kv < lo) || (hi !== null && kv >= hi)) errs.push('KeyOutOfBounds ' + h);
        });
        if (n.leaf) {
          if (depth !== self.height) errs.push('UnevenLeafDepth ' + h);
          if (w.expected !== h || n.prev !== w.prev) errs.push('BrokenLeafChain ' + h);
          w.prev = h; w.expected = n.next; w.entries += n.keys.length;
          return;
        }
        n.children.forEach(function (c, i) {
          if (!self.slots[c] || !self.slots[c].used) { errs.push('DanglingChild ' + h); return; }
          check(c, depth + 1, i === 0 ? lo : n.keys[i - 1], i === n.keys.length ? hi : n.keys[i]);
        });
      })(this.root, 1, null, null);
      if (w.expected !== NIL || w.prev !== this.lastLeaf) errs.push('BrokenLeafChain');
      if (w.entries !== this.count) errs.push('WrongCount');
      if (w.nodes !== this.live) errs.push('ArenaLeak');
    }
    if (this.freeList().length + this.live !== this.slots.length) errs.push('ArenaLeak');
    return errs;
  };

  /* ------------------------------------------- text output, as the programs print it */

  /** Same text as dump.zig / dump.rs. */
  function dump(t) {
    var out = 'height ' + t.height + ', ' + t.count + ' keys, ' + t.live + ' nodes\n';
    if (t.root === NIL) return out;
    for (var depth = 1; depth < t.height; depth++) {
      var line = '  level ' + (depth - 1) + ':', firstGroup = true;
      (function level(h, down) {
        if (down === 0) { line += ' ' + t.fmt(h); return; }
        if (down === 1) { if (!firstGroup) line += ' |'; firstGroup = false; }
        t.node(h).children.forEach(function (c) { level(c, down - 1); });
      })(t.root, depth - 1);
      out += line + '\n';
    }
    var leaves = [];
    for (var h = t.firstLeaf; h !== NIL; h = t.node(h).next) leaves.push(t.fmt(h));
    return out + '  leaves : ' + leaves.join(' <-> ') + '\n';
  }

  /** Reproduces sections 1 to 5 of expected_output.txt from this model. */
  function scenarioText() {
    var t = new BPlus(4), out = '';
    var report = function (before) {
      var s = t.stats, ev = [];
      var add = function (name, times) { if (times > 0) ev.push(name + (times > 1 ? ' x' + times : '')); };
      if (before.height === 0 && t.height === 1) add('first leaf', 1);
      add('leaf split (copy-up)', s.leafSplits - before.s.leafSplits);
      add('internal split (push-up)', s.internalSplits - before.s.internalSplits);
      add('merge', s.merges - before.s.merges);
      add('borrow', s.borrows - before.s.borrows);
      if (before.height !== 0 && t.height > before.height) add('new root', 1);
      if (t.height < before.height) add('root removed', 1);
      return ev.length ? ' ' + ev.join(', ') + '\n  ' + dump(t) : ' no structural change\n';
    };
    var snap = function () { return { s: JSON.parse(JSON.stringify(t.stats)), height: t.height }; };
    var seps = function () { return t.height < 2 ? ' none\n' : t.separators().map(function (s) { return ' ' + s.key + (s.stale ? '(stale)' : ''); }).join('') + '\n'; };
    var arena = function () {
      var fl = t.freeList();
      return 'arena: ' + t.slots.length + ' slots, ' + t.live + ' live, ' + fl.length + ' free; free list:' + fl.map(function (h) { return ' #' + h; }).join('') + '\n';
    };
    var opt = function (v) { return v === null ? 'null' : String(v); };

    out += '== 1. Build: canonical keys, order M = 4 (at most 3 keys per node) ==\n';
    CANONICAL.forEach(function (key) { var b = snap(); t.put(key, key * 100, { steps: false }); out += 'put ' + key + ':' + report(b); });
    out += '\n== 2. The leaf chain ==\nforward  (next links): ' + t.keys().join(' ') + '\nbackward (prev links), leaf handles:';
    for (var h = t.lastLeaf; h !== NIL; h = t.node(h).prev) out += ' #' + h;
    out += '\nseparators:' + seps();
    out += '\n== 3. Lookups always end in a leaf ==\n';
    [15, 12, 13].forEach(function (key) { out += 'get ' + key + ' = ' + opt(t.get(key)) + '\n'; });
    out += '\n== 4. Delete: stale separator, borrow, merge, shrink ==\n';
    DELETES.forEach(function (key) {
      var b = snap(); t.delete(key, { steps: false }); out += 'delete ' + key + ':' + report(b);
      if (key === 15) out += '  get 15 = ' + opt(t.get(15)) + ', but separators:' + seps();
    });
    out += '\n== 5. Handles: freed slots are reused ==\n' + arena();
    [11, 13, 14].forEach(function (key) { var b = snap(); t.put(key, key * 100, { steps: false }); out += 'put ' + key + ':' + report(b); });
    return out + arena();
  }

  /* ------------------------- section 7: the seeded model run (common/ops, in BigInt) */

  var MASK = (1n << 64n) - 1n;
  function OpStream(seed, count, keySpace) {
    this.state = BigInt(seed); this.remaining = count; this.keySpace = BigInt(keySpace);
  }
  OpStream.prototype.nextU64 = function () {       // SplitMix64
    this.state = (this.state + 0x9E3779B97F4A7C15n) & MASK;
    var z = this.state;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK;
    return z ^ (z >> 31n);
  };
  OpStream.prototype.below = function (n) { return (this.nextU64() * n) >> 64n; };   // multiply-high
  /** Default weights put 4, delete 2, get 3, range 1 (common/zig/ops.zig). */
  OpStream.prototype.next = function () {
    if (this.remaining === 0) return null;
    this.remaining--;
    var r = Number(this.below(10n)), ks = this.keySpace;
    if (r < 4) { var key = Number(this.below(ks)); return { op: 'put', key: key, value: this.nextU64() }; }
    if (r < 6) return { op: 'delete', key: Number(this.below(ks)) };
    if (r < 9) return { op: 'get', key: Number(this.below(ks)) };
    var a = Number(this.below(ks)), b = Number(this.below(ks));
    return { op: 'range', lo: Math.min(a, b), hi: Math.max(a, b) + 1 };
  };

  /** Reproduces section 7 of expected_output.txt (the tree side; the oracle is a Map). */
  function modelRunText() {
    var out = '';
    [3, 4, 16].forEach(function (order) {
      var t = new BPlus(order), oracle = new Map(), mismatches = 0, s = new OpStream(7, 20000, 500), op;
      while ((op = s.next()) !== null) {
        if (op.op === 'put') {
          var had = oracle.has(op.key) ? oracle.get(op.key) : null;
          oracle.set(op.key, op.value);
          if (t.put(op.key, op.value, { steps: false }).old !== had) mismatches++;
        } else if (op.op === 'delete') {
          var want = oracle.has(op.key) ? oracle.get(op.key) : null;
          oracle.delete(op.key);
          if (t.delete(op.key, { steps: false }).removed !== want) mismatches++;
        } else if (op.op === 'get') {
          if (t.get(op.key) !== (oracle.has(op.key) ? oracle.get(op.key) : null)) mismatches++;
        }
      }
      if (t.validate().length) mismatches++;
      var keys = t.keys();
      if (keys.length !== oracle.size || keys.some(function (kv) { return !oracle.has(kv); })) mismatches++;
      var st = t.stats, m = String(order);
      out += 'M=' + (m.length < 2 ? m + ' ' : m) + ' keys=' + t.count + ' height=' + t.height + ' nodes=' + t.live + ' slots=' + t.slots.length +
        ' | leaf splits=' + st.leafSplits + ' internal splits=' + st.internalSplits + ' borrows=' + st.borrows + ' merges=' + st.merges +
        ' | mismatches=' + mismatches + '\n';
    });
    return out;
  }

  var CANONICAL = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];
  var DELETES = [15, 17, 20, 25, 30, 12];

  var api = {
    BPlus: BPlus, dump: dump, scenarioText: scenarioText, modelRunText: modelRunText,
    lowerBound: lowerBound, upperBound: upperBound, CANONICAL: CANONICAL, DELETES: DELETES, NIL: NIL
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.Ch07 = api;
})(typeof window !== 'undefined' ? window : globalThis);

/* Chapter 04 local helpers (classic script, defines window.Ch04).
 *
 * Why a chapter-local model: the shared BTViz.models.BTree only splits
 * bottom-up. This chapter also needs the top-down variant, an explicit
 * "overflow" frame with M keys in the node, split counters, and fill
 * statistics. The model below follows zig/src/base_insert.zig and
 * zig/src/topdown.zig rule for rule (split point, what the left half keeps)
 * and emits the same step shape as the shared models, so the shared Stepper
 * and TreeView draw it. index.html checks it against BTViz.models.BTree and
 * against the text the Zig and Rust programs printed.
 */
(function () {
  'use strict';
  var k = BTViz.k;

  function lowerBound(keys, key) {
    var lo = 0, hi = keys.length;
    while (lo < hi) { var mid = lo + ((hi - lo) >> 1); if (keys[mid] < key) lo = mid + 1; else hi = mid; }
    return lo;
  }
  function box(keys) { return '<b class="bt-k">[' + keys.join(' ') + ']</b>'; }
  function plural(n, word) { return n + ' ' + word + (n === 1 ? '' : 's'); }

  /* ------------------------------------------------------------------ tree */
  function Tree(order, mode) {
    if (!(this instanceof Tree)) return new Tree(order, mode);
    this.order = order;
    this.mode = mode === 'top-down' ? 'top-down' : 'bottom-up';
    if (this.mode === 'top-down' && order % 2 !== 0) throw new Error('top-down splitting needs an even order');
    this.maxKeys = order - 1;
    this.minKeys = Math.ceil(order / 2) - 1;
    this.root = null;          // null = empty tree, as in the programs
    this.nextId = 1;
    this.size = 0;
    this.splits = 0;
    this.rootSplits = 0;
  }

  Tree.prototype._node = function (leaf) { return { id: 'n' + this.nextId++, keys: [], children: [], leaf: leaf }; };

  /* Plain-data copy for TreeView; null for the empty tree. */
  Tree.prototype.snapshot = function () {
    return (function copy(n) {
      return n && { id: n.id, keys: n.keys.slice(), leaf: n.leaf, children: n.children.map(copy) };
    })(this.root);
  };

  Tree.prototype.keys = function () {
    var out = [];
    (function walk(n) {
      if (!n) return;
      for (var i = 0; i <= n.keys.length; i++) {
        if (!n.leaf) walk(n.children[i]);
        if (i < n.keys.length) out.push(n.keys[i]);
      }
    })(this.root);
    return out;
  };

  Tree.prototype.has = function (key) {
    var n = this.root;
    while (n) {
      var i = lowerBound(n.keys, key);
      if (i < n.keys.length && n.keys[i] === key) return true;
      n = n.leaf ? null : n.children[i];
    }
    return false;
  };

  /* Shape and fill, like base_stats.zig, plus what the fill page draws. */
  Tree.prototype.stats = function () {
    var s = { height: 0, nodes: 0, leaves: 0, keys: 0, capacity: 0, splits: this.splits, rootSplits: this.rootSplits,
              buckets: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], leafFill: [] };
    var max = this.maxKeys, n;
    for (n = this.root; n; n = n.leaf ? null : n.children[0]) s.height++;
    (function walk(node) {
      if (!node) return;
      s.nodes++; s.keys += node.keys.length; s.capacity += max;
      // Ten buckets of node fill: (0,10], (10,20], ... (90,100].
      s.buckets[Math.min(9, Math.max(0, Math.ceil(node.keys.length * 10 / max) - 1))]++;
      if (node.leaf) { s.leaves++; s.leafFill.push(node.keys.length / max); }
      else node.children.forEach(walk);
    })(this.root);
    s.fillPermille = s.capacity ? Math.floor(s.keys * 1000 / s.capacity) : 0;
    return s;
  };

  /* [] when every invariant of chapter 03 holds, else messages. */
  Tree.prototype.validate = function () {
    var errors = [], self = this, leafDepth = null, count = 0;
    (function check(n, lo, hi, depth, isRoot) {
      if (!n) return;
      count += n.keys.length;
      if (n.keys.length > self.maxKeys) errors.push(n.id + ' overfull');
      if (!isRoot && n.keys.length < self.minKeys) errors.push(n.id + ' underfull');
      if (isRoot && n.keys.length === 0) errors.push('empty root');
      for (var i = 0; i < n.keys.length; i++) {
        if (i > 0 && n.keys[i - 1] >= n.keys[i]) errors.push(n.id + ' keys out of order');
        if ((lo !== null && n.keys[i] <= lo) || (hi !== null && n.keys[i] >= hi)) errors.push(n.id + ' key outside parent bounds');
      }
      if (n.leaf) {
        if (n.children.length) errors.push(n.id + ' leaf with children');
        if (leafDepth === null) leafDepth = depth; else if (leafDepth !== depth) errors.push('leaves at different depths');
        return;
      }
      if (n.children.length !== n.keys.length + 1) errors.push(n.id + ' wrong child count');
      n.children.forEach(function (c, i) {
        check(c, i === 0 ? lo : n.keys[i - 1], i === n.keys.length ? hi : n.keys[i], depth + 1, false);
      });
    })(this.root, null, null, 0, true);
    if (count !== this.size) errors.push('wrong key count');
    return errors;
  };

  /* insert(key[, {steps: false}]) -> array of steps with extra properties:
   *   .inserted  false when the key was already present
   *   .splits    nodes split by this insert
   *   .rootSplit true when the tree grew a level
   *   .summary   the line the programs print for this put */
  Tree.prototype.insert = function (key, opts) {
    var record = !(opts && opts.steps === false);
    var steps = [], self = this;
    var before = this.splits, beforeRoot = this.rootSplits;
    var push = !record ? function () {} : function (type, caption, highlight, extra) {
      var step = { type: type, caption: caption, state: self.snapshot(), highlight: highlight || {}, op: { kind: 'insert', key: key } };
      if (extra) for (var name in extra) step[name] = extra[name];
      steps.push(step);
    };
    steps.inserted = this.mode === 'top-down' ? this._topDown(key, push) : this._bottomUp(key, push);
    steps.splits = this.splits - before;
    steps.rootSplit = this.rootSplits > beforeRoot;
    steps.summary = 'put ' + key + ':' + (steps.splits === 0 ? ' no split' :
      ' ' + plural(steps.splits, 'split') + (steps.rootSplit ? ', the root split: height ' + this.stats().height : ''));
    if (record && steps.length) steps[steps.length - 1].summary = steps.summary;
    return steps;
  };

  function descendCaption(node, i, key) {
    var K = k(key, 'compare');
    var where = node.keys.length === 0 ? '' :
      i === 0 ? K + ' is smaller than ' + k(node.keys[0]) + ', so it belongs in the first child.' :
      i === node.keys.length ? K + ' is larger than ' + k(node.keys[i - 1]) + ', so it belongs in the last child.' :
      K + ' lies between ' + k(node.keys[i - 1]) + ' and ' + k(node.keys[i]) + ', so it belongs in the child between them.';
    return where;
  }
  function descendHighlight(node, i, key) {
    var h = { nodes: {}, keys: {}, edges: {}, cursor: { node: node.id, label: key } };
    h.nodes[node.id] = 'active';
    if (i > 0) h.keys[node.id + ':' + node.keys[i - 1]] = 'compare';
    if (i < node.keys.length) h.keys[node.id + ':' + node.keys[i]] = 'compare';
    if (!node.leaf) h.edges[node.children[i].id] = 'active';
    return h;
  }
  function existsStep(push, node, key) {
    var h = { nodes: {}, keys: {} };
    h.nodes[node.id] = 'active'; h.keys[node.id + ':' + key] = 'found';
    push('exists', 'Key ' + k(key, 'found') + ' is already in the tree. Keys are unique in this part of the guide: <code>put</code> overwrites the value and the structure stays as it is.',
      h, { log: 'put ' + key + ': already present, value overwritten' });
  }

  /* ---- bottom-up: insert into the leaf, then split upwards while a node is overfull */
  Tree.prototype._bottomUp = function (key, push) {
    var self = this, K = k(key, 'inserted');
    if (!this.root) {
      this.root = this._node(true);
      this.root.keys.push(key);
      this.size = 1;
      var h0 = { nodes: {}, keys: {} }; h0.nodes[this.root.id] = 'active'; h0.keys[this.root.id + ':' + key] = 'inserted';
      push('new-root', 'The tree is empty. ' + K + ' goes into a new leaf, which is also the root.', h0, { log: 'put ' + key + ': first node' });
      return true;
    }
    var path = [], node = this.root, i;
    push('start', 'Insert ' + k(key, 'compare') + '. An insert begins like a search: start at the root and walk down to the leaf where the key belongs.',
      { nodes: (function () { var o = {}; o[node.id] = 'active'; return o; })(), cursor: { node: node.id, label: key } }, { log: 'put ' + key });
    while (true) {
      i = lowerBound(node.keys, key);
      if (i < node.keys.length && node.keys[i] === key) { existsStep(push, node, key); return false; }
      path.push({ node: node, i: i });
      if (node.leaf) break;
      push('descend', descendCaption(node, i, key) + ' The path is remembered: a split below will need this node again.', descendHighlight(node, i, key));
      node = node.children[i];
    }
    var full = node.keys.length === this.maxKeys;
    var beforeKeys = node.keys.slice();
    node.keys.splice(i, 0, key);
    this.size++;
    var hl = { nodes: {}, keys: {} };
    hl.nodes[node.id] = full ? 'split' : 'active';
    hl.keys[node.id + ':' + key] = 'inserted';
    push('insert-leaf', 'New keys always go into a leaf. ' + K + ' is placed in sorted position' +
      (full ? '. The leaf now holds ' + (this.maxKeys + 1) + ' keys, one more than the ' + this.maxKeys + ' it may keep.' :
        '; the leaf holds ' + plural(node.keys.length, 'key') + ' of at most ' + this.maxKeys + ', so nothing else has to change.'),
      hl, {
        log: 'leaf ' + '[' + beforeKeys.join(' ') + '] takes ' + key,
        question: {
          prompt: 'Key ' + key + ' has reached the leaf ' + box(beforeKeys) + '. A node may hold at most ' + this.maxKeys + ' keys. Will the leaf have to split?',
          choices: ['No, there is room', 'Yes, it overflows'], answer: full ? 1 : 0,
          explain: 'The leaf had ' + plural(beforeKeys.length, 'key') + '. A split happens only when a node would hold more than ' + this.maxKeys + '.'
        }
      });

    var level = path.length - 1;
    while (path[level].node.keys.length > this.maxKeys) {
      var left = path[level].node;
      var all = left.keys.slice();
      var mid = Math.floor(all.length / 2), median = all[mid];
      var ho = { nodes: {} }; ho.nodes[left.id] = 'split';
      push('overflow', 'Node ' + box(all) + ' is overfull. It splits around its middle key: the keys below it stay, the keys above it move to a new node, and the middle key itself goes up to the parent' +
        (level === 0 ? ' (this node is the root, so a new root has to be made for it).' : '.'), ho, { log: { html: 'overflow ' + '[' + all.join(' ') + ']', state: 'split' } });
      var right = this._node(left.leaf);
      right.keys = left.keys.splice(mid + 1);
      left.keys.pop();                                   // the median leaves this node
      if (!left.leaf) right.children = left.children.splice(mid + 1);
      this.splits++;
      var question = {
        prompt: 'Node ' + box(all) + ' splits. Which key moves up?',
        choices: all.map(String), answer: mid,
        explain: 'The middle key, index ' + mid + ' of ' + all.length + ': ' + plural(mid, 'key') + ' stay' + (mid === 1 ? 's' : '') + ' on the left, ' + plural(all.length - 1 - mid, 'key') + ' go' + (all.length - 1 - mid === 1 ? 'es' : '') + ' right.'
      };
      var hs = { nodes: {}, keys: {} };
      hs.nodes[left.id] = 'split'; hs.nodes[right.id] = 'split'; hs.keys['*:' + median] = 'split';
      if (level === 0) {
        var newRoot = this._node(false);
        newRoot.keys = [median];
        newRoot.children = [left, right];
        this.root = newRoot;
        this.rootSplits++;
        push('root-grow', 'The root split, so ' + k(median, 'split') + ' has no parent to go to: a new root is created above the two halves ' + box(left.keys) + ' and ' + box(right.keys) +
          '. This is the only way the tree gets taller, and it happens at the top, so every leaf is still at the same depth.',
          hs, { log: { html: 'root split: ' + median + ' up, height ' + this.stats().height, state: 'split' }, question: question, hold: 2 });
        break;
      }
      level--;
      var parent = path[level].node, at = path[level].i;
      parent.children.splice(at + 1, 0, right);
      parent.keys.splice(at, 0, median);
      var over = parent.keys.length > this.maxKeys;
      push('split', k(median, 'split') + ' moves up into the parent, between the two halves ' + box(left.keys) + ' and ' + box(right.keys) + '. ' +
        (over ? 'The parent now holds ' + parent.keys.length + ' keys: it is overfull too, so the split repeats one level higher.' :
          'The parent has room for it, so the insert ends here.'),
        hs, { log: { html: 'split: ' + median + ' up, [' + left.keys.join(' ') + '] + [' + right.keys.join(' ') + ']', state: 'split' }, question: question, hold: 2 });
    }
    var n = this.splits;
    push('done', 'Done: ' + K + ' is in the tree. ' + (path[path.length - 1].node.keys.length <= this.maxKeys && n === this.splits ? '' : ''), { keys: (function () { var o = {}; o['*:' + key] = 'inserted'; return o; })() });
    return true;
  };

  /* ---- top-down (textbook, CLRS): split every full node BEFORE entering it */
  Tree.prototype._splitFull = function (left) {
    var mid = Math.floor(this.maxKeys / 2), median = left.keys[mid];
    var right = this._node(left.leaf);
    right.keys = left.keys.splice(mid + 1);
    left.keys.pop();
    if (!left.leaf) right.children = left.children.splice(mid + 1);
    this.splits++;
    return { right: right, median: median };
  };

  Tree.prototype._topDown = function (key, push) {
    var K = k(key, 'inserted');
    if (!this.root) {
      this.root = this._node(true);
      this.root.keys.push(key);
      this.size = 1;
      var h0 = { nodes: {}, keys: {} }; h0.nodes[this.root.id] = 'active'; h0.keys[this.root.id + ':' + key] = 'inserted';
      push('new-root', 'The tree is empty. ' + K + ' goes into a new leaf, which is also the root.', h0, { log: 'put ' + key + ': first node' });
      return true;
    }
    var node = this.root, self = this;
    function preemptQuestion(keys, what) {
      return {
        prompt: 'The ' + what + ' ' + box(keys) + ' is full (' + self.maxKeys + ' keys). What does top-down insertion do now?',
        choices: ['Go on; split later if it overflows', 'Split it now, before going on'], answer: 1,
        explain: 'Top-down never leaves a full node behind on the path, so that a median coming up from below always finds room. The price: this split may turn out to be unnecessary.'
      };
    }
    push('start', 'Insert ' + k(key, 'compare') + ', top-down. The rule: never walk into a full node. A full node on the path is split before it is entered.',
      { nodes: (function () { var o = {}; o[node.id] = 'active'; return o; })(), cursor: { node: node.id, label: key } }, { log: 'put ' + key });
    if (node.keys.length === this.maxKeys) {
      var allRoot = node.keys.slice();
      var hp = { nodes: {} }; hp.nodes[node.id] = 'split';
      push('preempt', 'The root ' + box(allRoot) + ' is full. It is split now, although nobody knows yet whether a key will come up from below.',
        hp, { log: { html: 'full root [' + allRoot.join(' ') + ']', state: 'split' }, question: preemptQuestion(allRoot, 'root') });
      var r = this._splitFull(node);
      var newRoot = this._node(false);
      newRoot.keys = [r.median];
      newRoot.children = [node, r.right];
      this.root = newRoot;
      this.rootSplits++;
      var hr = { nodes: {}, keys: {} };
      hr.nodes[node.id] = 'split'; hr.nodes[r.right.id] = 'split'; hr.keys['*:' + r.median] = 'split';
      push('root-grow', 'The middle key ' + k(r.median, 'split') + ' becomes a new root above the halves ' + box(node.keys) + ' and ' + box(r.right.keys) +
        '. Both halves hold ' + plural(this.minKeys, 'key') + ', the legal minimum: this is why top-down splitting needs an even order.',
        hr, { log: { html: 'root split: ' + r.median + ' up, height ' + this.stats().height, state: 'split' }, hold: 2 });
      node = newRoot;
    }
    while (true) {
      var i = lowerBound(node.keys, key);
      if (i < node.keys.length && node.keys[i] === key) { existsStep(push, node, key); return false; }
      if (node.leaf) {
        var beforeKeys = node.keys.slice();
        node.keys.splice(i, 0, key);
        this.size++;
        var hl = { nodes: {}, keys: {} }; hl.nodes[node.id] = 'active'; hl.keys[node.id + ':' + key] = 'inserted';
        push('insert-leaf', K + ' is placed in the leaf. There is always room: a full leaf would have been split before we entered it.',
          hl, { log: 'leaf [' + beforeKeys.join(' ') + '] takes ' + key });
        break;
      }
      var child = node.children[i];
      push('descend', descendCaption(node, i, key) + (child.keys.length === this.maxKeys ? ' That child is full.' : ' That child has room, so we may enter it.'),
        descendHighlight(node, i, key));
      if (child.keys.length === this.maxKeys) {
        var all = child.keys.slice();
        var hc = { nodes: {}, cursor: { node: node.id, label: key } }; hc.nodes[child.id] = 'split'; hc.nodes[node.id] = 'active';
        push('preempt', 'The child ' + box(all) + ' is full. It is split before we enter it. The node we stand in is not full (we made sure of that one step earlier), so it can take the middle key.',
          hc, { log: { html: 'full child [' + all.join(' ') + ']', state: 'split' }, question: preemptQuestion(all, 'child') });
        var s = this._splitFull(child);
        node.children.splice(i + 1, 0, s.right);
        node.keys.splice(i, 0, s.median);
        var hs = { nodes: {}, keys: {} };
        hs.nodes[child.id] = 'split'; hs.nodes[s.right.id] = 'split'; hs.keys['*:' + s.median] = 'split';
        push('split', k(s.median, 'split') + ' moves up between the halves ' + box(child.keys) + ' and ' + box(s.right.keys) + '. ' +
          (key === s.median ? 'It is the key we are inserting.' : k(key, 'compare') + ' is ' + (key > s.median ? 'larger' : 'smaller') + ' than ' + k(s.median) + ', so we continue in the ' + (key > s.median ? 'right' : 'left') + ' half.'),
          hs, { log: { html: 'split: ' + s.median + ' up, [' + child.keys.join(' ') + '] + [' + s.right.keys.join(' ') + ']', state: 'split' }, hold: 2 });
        if (key === s.median) { existsStep(push, node, key); return false; }
        if (key > s.median) child = s.right;
      }
      node = child;
    }
    push('done', 'Done: ' + K + ' is in the tree, in one pass from the root to the leaf. Nothing had to travel back up.', { keys: (function () { var o = {}; o['*:' + key] = 'inserted'; return o; })() });
    return true;
  };

  /* -------------------------------------------- text form, as the programs print it */
  function renderText(state, indent) {
    indent = indent || '';
    if (!state) return indent + '(empty)\n';
    var height = 0, n, out = '';
    for (n = state; n; n = n.children && n.children[0]) height++;
    for (var level = 0; level < height; level++) {
      var line = '', first = true;
      (function walk(node, remaining) {
        if (remaining === 0) { line += '[' + node.keys.join(' ') + ']'; return; }
        node.children.forEach(function (child, i) {
          if (remaining === 1) { if (i > 0) line += ' '; else if (!first) line += ' | '; first = false; }
          walk(child, remaining - 1);
        });
      })(state, level);
      out += indent + line + '\n';
    }
    return out;
  }

  /* ------------------------------ SplitMix64, bit for bit as common/zig/prng.zig */
  var MASK = (1n << 64n) - 1n;
  function SplitMix64(seed) { this.state = BigInt.asUintN(64, BigInt(seed)); }
  SplitMix64.prototype.nextU64 = function () {
    this.state = (this.state + 0x9E3779B97F4A7C15n) & MASK;
    var z = this.state;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK;
    return z ^ (z >> 31n);
  };
  SplitMix64.prototype.below = function (n) { return Number((this.nextU64() * BigInt(n)) >> 64n); };
  SplitMix64.prototype.shuffle = function (items) {
    for (var i = items.length - 1; i >= 1; i--) {
      var j = this.below(i + 1), t = items[i];
      items[i] = items[j]; items[j] = t;
    }
  };

  /* The keys 0 .. n-1, shuffled for 'random' (measure.zig, fillKeys). */
  function fillKeys(n, order, seed) {
    var keys = [];
    for (var i = 0; i < n; i++) keys.push(i);
    if (order === 'random') new SplitMix64(seed).shuffle(keys);
    return keys;
  }

  /* One row of the programs' table (scenario.zig, printRow). */
  function tableRow(order, keyOrder, variant, tree, puts, most) {
    function left(s, w) { s = String(s); while (s.length < w) s += ' '; return s; }
    function right(s, w) { s = String(s); while (s.length < w) s = ' ' + s; return s; }
    var s = tree.stats(), fill = s.fillPermille, rate = Math.floor(tree.splits * 10000 / puts);
    return right(order, 4) + '  ' + left(keyOrder, 9) + '  ' + left(variant, 9) + '  ' + right(s.height, 6) + '  ' + right(s.nodes, 6) + '  ' +
      right(Math.floor(fill / 10), 3) + '.' + (fill % 10) + '%  ' + right(tree.splits, 6) + '  ' + right(Math.floor(rate / 10), 11) + '.' + (rate % 10) + '  ' + right(most, 15);
  }

  window.Ch04 = { Tree: Tree, renderText: renderText, SplitMix64: SplitMix64, fillKeys: fillKeys, tableRow: tableRow, lowerBound: lowerBound };
})();

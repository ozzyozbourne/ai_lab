/* Chapter 03 model: everything the page draws is computed here, with the same
 * rules as zig/src and rust/src. A classic script; also loadable from node.
 *
 *   HandTree         build by hand (leaf / interior / fromSorted), no checks
 *   searchSteps      get, one step per decision          (base_search + trace)
 *   inOrderSteps     in-order traversal                  (base_search)
 *   validateSteps    the invariant walk                  (base_validate)
 *   CASES            the ten corruptions                 (broken)
 *   redBlack*        2-3-4 tree to red-black tree        (redblack)
 *   height helpers, SplitMix64                           (height, prng)
 */
(function (root) {
  'use strict';

  var uid = 0;
  function valueOf(key) { return key * 10; }
  function fmtKeys(keys) { return '[' + keys.join(' ') + ']'; }

  /* ------------------------------------------------------------ HandTree */
  function HandTree(M) {
    this.M = M;
    this.root = null;
    this.len = 0;        // keys the tree claims to hold
    this.created = 0;    // nodes ever created
    this.orphans = [];   // nodes nothing points to (only for drawing them)
  }
  HandTree.prototype.leaf = function (keys) {
    this.created++; this.len += keys.length;
    return { id: 'n' + (++uid), keys: keys.slice(), leaf: true, children: [] };
  };
  HandTree.prototype.interior = function (keys, children) {
    this.created++; this.len += keys.length;
    return { id: 'n' + (++uid), keys: keys.slice(), leaf: false, children: children.slice() };
  };
  /* Valid tree of minimal height from ascending keys (tree.zig: fromSorted). */
  HandTree.prototype.fromSorted = function (sorted) {
    if (!sorted.length) return this;
    this.root = this._build(sorted, minHeight(this.M, sorted.length), true);
    return this;
  };
  HandTree.prototype._build = function (keys, h, isRoot) {
    if (h === 1) return this.leaf(keys);
    var M = this.M, cap = maxKeys(M, h - 1);
    var n = isRoot ? 2 : Math.ceil(M / 2);
    while (Math.ceil((keys.length - (n - 1)) / n) > cap) n++;
    var below = keys.length - (n - 1), seps = [], kids = [], pos = 0;
    for (var i = 0; i < n; i++) {
      var take = Math.floor(below / n) + (i < below % n ? 1 : 0);
      kids.push(this._build(keys.slice(pos, pos + take), h - 1, false));
      pos += take;
      if (i + 1 < n) seps.push(keys[pos++]);
    }
    return this.interior(seps, kids);
  };
  /* What TreeView draws: the root, plus any orphan as a second root. */
  HandTree.prototype.model = function () {
    return this.orphans.length ? [this.root].concat(this.orphans) : this.root;
  };
  HandTree.prototype.get = function (key) {
    var node = this.root;
    while (node) {
      var i = lowerBound(node.keys, key);
      if (i < node.keys.length && node.keys[i] === key) return valueOf(key);
      if (node.leaf) return null;
      node = node.children[i];
    }
    return null;
  };

  var CANONICAL_KEYS = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];
  function canonical() {
    var t = new HandTree(4);
    t.root = t.interior([6, 10, 20], [t.leaf([1, 3, 5]), t.leaf([7]), t.leaf([12, 15, 17]), t.leaf([25, 30])]);
    return t;
  }
  function sparsest() {
    var t = new HandTree(4);
    t.root = t.interior([4], [t.interior([2], [t.leaf([1]), t.leaf([3])]), t.interior([6], [t.leaf([5]), t.leaf([7])])]);
    return t;
  }
  function fullest() {
    var t = new HandTree(4);
    t.root = t.interior([4, 8, 12], [t.leaf([1, 2, 3]), t.leaf([5, 6, 7]), t.leaf([9, 10, 11]), t.leaf([13, 14, 15])]);
    return t;
  }

  /* ------------------------------------------------------- text and shape */
  function heightOf(node) { var h = 0; for (var n = node; n; n = n.leaf ? null : n.children[0]) h++; return h; }
  function renderText(node, indent) {
    indent = indent || '';
    if (!node) return indent + '(empty)\n';
    var out = '', height = heightOf(node);
    for (var level = 0; level < height; level++) {
      var line = '', first = true;
      (function walk(n, remaining) {
        if (remaining === 0) { line += fmtKeys(n.keys); return; }
        n.children.forEach(function (child, i) {
          if (remaining === 1) { if (i > 0) line += ' '; else if (!first) line += ' | '; first = false; }
          walk(child, remaining - 1);
        });
      })(node, level);
      out += indent + line + '\n';
    }
    return out;
  }
  function shape(node, M) {
    var s = { height: heightOf(node), nodes: 0, leaves: 0, keys: 0, capacity: 0 };
    (function walk(n) {
      if (!n) return;
      s.nodes++; s.keys += n.keys.length; s.capacity += M - 1;
      if (n.leaf) s.leaves++; else n.children.forEach(walk);
    })(node);
    s.fill = s.capacity ? Math.floor(s.keys * 100 / s.capacity) : 0;
    return s;
  }
  function shapeText(s) {
    return 'shape: height=' + s.height + ' nodes=' + s.nodes + ' leaves=' + s.leaves + ' keys=' + s.keys + ' fill=' + s.fill + '%';
  }

  /* --------------------------------------------------------------- search */
  function lowerBound(keys, key) {
    var lo = 0, hi = keys.length;
    while (lo < hi) { var mid = lo + ((hi - lo) >> 1); if (keys[mid] < key) lo = mid + 1; else hi = mid; }
    return lo;
  }
  function rangeText(node, i) {
    var n = node.keys.length;
    if (n === 0) return 'all keys';
    if (i === 0) return 'the keys below ' + node.keys[0];
    if (i === n) return 'the keys above ' + node.keys[n - 1];
    return 'the keys between ' + node.keys[i - 1] + ' and ' + node.keys[i];
  }
  function plural(n, word) { return n + ' ' + word + (n === 1 ? '' : 's'); }

  /* One step per decision of `get`. steps.line is what explainGet prints. */
  function searchSteps(tree, key, k) {
    k = k || function (v) { return String(v); };
    var steps = [], pathNodes = {}, pathEdges = {}, line = 'get ' + key + ': ';
    var model = tree.model();
    function push(type, caption, node, keyStates, lines) {
      var nodes = {}, id;
      for (id in pathNodes) nodes[id] = pathNodes[id];
      var edges = {};
      for (id in pathEdges) edges[id] = pathEdges[id];
      steps.push({ type: type, caption: caption, state: model, lines: lines, nodesRead: Object.keys(pathNodes).length,
        highlight: { nodes: nodes, edges: edges, keys: keyStates || {}, cursor: node ? { node: node.id, label: key } : undefined } });
    }
    var node = tree.root;
    if (!node) {
      push('absent', 'The tree is empty: there is no root to read, so ' + k(key) + ' is absent.', null, {}, [2]);
      line += 'the tree is empty -> absent (0 nodes read)';
    }
    while (node) {
      pathNodes[node.id] = 'active';
      var nodesRead = Object.keys(pathNodes).length, kt = fmtKeys(node.keys);
      line += kt;
      push('read', 'Read node <b>' + kt + '</b> (node ' + nodesRead + ' on this path). Inside the node, binary search looks for the first key that is not smaller than ' + k(key) + '.', node, {}, [3, 4]);
      var lo = 0, hi = node.keys.length;
      while (lo < hi) {
        var mid = lo + ((hi - lo) >> 1), probe = node.keys[mid], ks = {};
        ks[node.id + ':' + probe] = 'compare';
        if (probe < key) {
          lo = mid + 1;
          push('probe', 'Compare with ' + k(probe, 'compare') + ': it is smaller than ' + k(key) + ', so the answer lies to its right.', node, ks, [4]);
        } else {
          hi = mid;
          push('probe', 'Compare with ' + k(probe, 'compare') + ': it is ' + (probe === key ? 'equal to ' : 'larger than ') + k(key) + ', so the answer is this key or one to its left.', node, ks, [4]);
        }
      }
      var i = lo, found = {};
      if (i < node.keys.length && node.keys[i] === key) {
        found[node.id + ':' + key] = 'found';
        push('found', 'Found ' + k(key, 'found') + ' at index ' + i + ' of this ' + (node.leaf ? 'leaf' : 'interior node') + '; its value is ' + valueOf(key) + '. ' +
          (node.leaf ? '' : 'In a B-tree a key that is stored in an interior node is stored nowhere else, so the search ends here. ') +
          'Nodes read: ' + nodesRead + '.', node, found, [5]);
        line += ' has it at index ' + i + ' -> value ' + valueOf(key);
        steps.found = true;
        break;
      }
      if (node.leaf) {
        push('absent', 'Not in this node, and a leaf has no children to continue in. ' + k(key) + ' is absent. Nodes read: ' + nodesRead + '.', node, {}, [6]);
        line += ' is a leaf without it -> absent';
        break;
      }
      var child = node.children[i];
      pathEdges[child.id] = 'active';
      push('descend', plural(i, 'key') + ' of this node ' + (i === 1 ? 'is' : 'are') + ' smaller than ' + k(key) + ', so follow child ' + i +
        '. That subtree holds exactly ' + rangeText(node, i) + '; ' + k(key) + ' cannot be anywhere else.', node, {}, [7]);
      line += ' child ' + i + ' -> ';
      node = child;
    }
    var read = Object.keys(pathNodes).length;
    steps.line = line + (tree.root ? ' (' + plural(read, 'node') + ' read)' : '');
    steps.found = !!steps.found;
    return steps;
  }

  /* ---------------------------------------------------- in-order traversal */
  function inOrderKeys(node) {
    var out = [];
    (function walk(n) {
      if (!n) return;
      for (var i = 0; i <= n.keys.length; i++) {
        if (!n.leaf) walk(n.children[i]);
        if (i < n.keys.length) out.push(n.keys[i]);
      }
    })(node);
    return out;
  }
  function inOrderSteps(tree, k) {
    k = k || function (v) { return String(v); };
    var steps = [], done = {}, out = [], model = tree.model();
    steps.push({ type: 'intro', state: model, highlight: {}, out: [], lines: [1],
      caption: 'In-order traversal: for every node, visit child 0, then key 0, then child 1, then key 1, and so on, ending with the last child.' });
    (function walk(n, parent) {
      for (var i = 0; i <= n.keys.length; i++) {
        if (!n.leaf) walk(n.children[i], n);
        if (i < n.keys.length) {
          var key = n.keys[i], ks = {}, id, nodes = {};
          for (id in done) ks[id] = 'found';
          ks[n.id + ':' + key] = 'compare';
          nodes[n.id] = 'active';
          out.push(key);
          steps.push({ type: 'visit', state: model, highlight: { nodes: nodes, keys: ks }, out: out.slice(), lines: [5],
            caption: 'Visit ' + k(key, 'compare') + (n.leaf ? ' in leaf ' : ' in interior node ') + '<b>' + fmtKeys(n.keys) + '</b>' +
              (n.leaf ? '.' : ': everything in child ' + i + ' has been visited, and everything in child ' + (i + 1) + ' is larger.') });
          done[n.id + ':' + key] = true;
        }
      }
    })(tree.root, null);
    var all = {}, id;
    for (id in done) all[id] = 'found';
    steps.push({ type: 'done', state: model, highlight: { keys: all }, out: out.slice(), lines: [],
      caption: 'Done: ' + plural(out.length, 'key') + ' in ascending order, although no node was sorted against another. The order is a consequence of the search-tree invariant.' });
    return steps;
  }

  /* -------------------------------------------------------------- validate */
  var RULES = [
    { id: 'order', text: 'Keys inside a node are strictly ascending', errors: ['KeysOutOfOrder'] },
    { id: 'bounds', text: 'Every key lies between the two separators above it', errors: ['KeyOutsideParentBounds'] },
    { id: 'max', text: 'A node holds at most M − 1 keys', errors: ['NodeOverfull'] },
    { id: 'min', text: 'A non-root node holds at least ⌈M/2⌉ − 1 keys; a root at least 1', errors: ['NodeUnderfull', 'EmptyRoot'] },
    { id: 'children', text: 'An interior node with n keys has n + 1 children; a leaf has none', errors: ['MissingChild', 'UnexpectedChild'] },
    { id: 'depth', text: 'All leaves are at the same depth', errors: ['LeavesAtDifferentDepths'] },
    { id: 'count', text: 'Bookkeeping: the key count matches', errors: ['WrongKeyCount'] },
    { id: 'nodes', text: 'Bookkeeping: every allocated node is reachable', errors: ['NodeCountMismatch'] }
  ];

  /* The walk of base_validate.zig, one step per node. Returns steps;
   * steps.error is the name of the first violation or null. */
  function validateSteps(tree, k) {
    k = k || function (v) { return String(v); };
    var M = tree.M, maxK = M - 1, minK = Math.ceil(M / 2) - 1;
    var steps = [], okNodes = {}, model = tree.model(), error = null, count = 0, reachable = 0, leafDepth = null;
    function push(caption, lines, node, bad, keyStates) {
      var nodes = {}, id;
      for (id in okNodes) nodes[id] = 'found';
      if (node) nodes[node.id] = bad ? 'deleted' : 'active';
      steps.push({ type: bad ? 'fail' : 'check', caption: caption, state: model, lines: lines, error: bad || null,
        highlight: { nodes: nodes, keys: keyStates || {} } });
    }
    function fail(name, caption, lines, node, keyStates) {
      error = name;
      push(caption + ' <b>validate returns ' + name + '</b> and stops: it reports the first violation it meets.', lines, node, name, keyStates);
    }
    function boundsText(lo, hi) {
      if (lo === null && hi === null) return 'any key is allowed here';
      if (lo === null) return 'keys must be below ' + hi;
      if (hi === null) return 'keys must be above ' + lo;
      return 'keys must lie between ' + lo + ' and ' + hi;
    }
    function check(node, lo, hi, isRoot, depth) {
      reachable++;
      var n = node.keys.length, kt = '<b>' + fmtKeys(node.keys) + '</b>', i, ks = {};
      var where = (isRoot ? 'the root ' : node.leaf ? 'leaf ' : 'interior node ') + kt;
      if (n > maxK) return fail('NodeOverfull', 'Check ' + where + ': ' + plural(n, 'key') + ', but a node of order ' + M + ' holds at most ' + maxK + '.', [2], node);
      if (!isRoot && n < minK) return fail('NodeUnderfull', 'Check ' + where + ': ' + plural(n, 'key') + ', but every node except the root needs at least ' + minK + '.', [3], node);
      count += n;
      for (i = 0; i < n; i++) {
        var key = node.keys[i];
        ks = {}; ks[node.id + ':' + key] = 'deleted';
        if (i > 0 && node.keys[i - 1] >= key) {
          return fail('KeysOutOfOrder', 'Check ' + where + ': ' + k(node.keys[i - 1]) + ' is followed by ' + k(key, 'deleted') + '. Keys must be strictly ascending, or binary search inside the node gives wrong answers.', [5], node, ks);
        }
        if ((lo !== null && key <= lo) || (hi !== null && key >= hi)) {
          return fail('KeyOutsideParentBounds', 'Check ' + where + ': the separators above say ' + boundsText(lo, hi) + ', but ' + k(key, 'deleted') + ' is not. A search for it turns into a different subtree and never arrives here.', [6], node, ks);
        }
      }
      var present = (node.children || []).filter(function (c) { return !!c; }).length;
      if (node.leaf) {
        if (present) return fail('UnexpectedChild', 'Check ' + where + ': it is marked as a leaf but has a child pointer.', [9], node);
        if (leafDepth !== null && leafDepth !== depth) {
          return fail('LeavesAtDifferentDepths', 'Check ' + where + ': this leaf is at depth ' + depth + ', the first leaf was at depth ' + leafDepth + '. The tree is no longer balanced, so the height bound does not hold.', [10], node);
        }
        leafDepth = depth;
        push('Check ' + where + ': ' + plural(n, 'key') + ' (allowed: ' + (isRoot ? 1 : minK) + ' to ' + maxK + '), ascending, ' + boundsText(lo, hi) +
          ' and they do; a leaf without children at depth ' + depth + '. All fine.', [2, 3, 5, 6, 9, 10], node);
        okNodes[node.id] = true;
        return true;
      }
      /* All child slots of this node first, the subtrees after that
       * (base_validate: Zig and Rust then name the same first error). */
      var slots = Math.max(node.children.length, n + 1);
      for (i = 0; i < slots; i++) {
        if (i <= n && !node.children[i]) {
          return fail('MissingChild', 'Check ' + where + ': its keys are fine, but ' + plural(n, 'key') + ' need ' + (n + 1) + ' children and child ' + i +
            ' is missing. A search for ' + rangeText(node, i).replace('the keys', 'a key') + ' would follow a pointer that is not there. validate looks at every child slot of a node before it visits the first child.', [14], node);
        }
        if (i > n && node.children[i]) {
          return fail('UnexpectedChild', 'Check ' + where + ': it has a child beyond the ' + (n + 1) + ' slots that ' + plural(n, 'key') + ' allow.', [15], node);
        }
      }
      push('Check ' + where + ': ' + plural(n, 'key') + ' (allowed: ' + (isRoot ? 1 : minK) + ' to ' + maxK + '), ascending, ' + boundsText(lo, hi) +
        (lo === null && hi === null ? '' : ' and they do') + '; all ' + (n + 1) + ' child slots are filled. Now the children, each with a narrower range.', [2, 3, 5, 6, 14, 15, 17], node);
      for (i = 0; i <= n; i++) {
        if (!check(node.children[i], i === 0 ? lo : node.keys[i - 1], i === n ? hi : node.keys[i], false, depth + 1)) return false;
      }
      okNodes[node.id] = true;
      return true;
    }
    if (tree.root) {
      if (tree.root.keys.length === 0) fail('EmptyRoot', 'The root has no keys. An empty tree has no root at all; a root with zero keys cannot route a search.', [1], tree.root);
      else check(tree.root, null, null, true, 0);
    }
    if (!error) {
      if (count !== tree.len) fail('WrongKeyCount', 'The walk met ' + plural(count, 'key') + ', but the tree claims to hold ' + tree.len + '. Every node is fine on its own; a key was lost or counted twice.', [22], null);
      else if (reachable !== tree.created) fail('NodeCountMismatch', 'The walk reached ' + plural(reachable, 'node') + ', but ' + tree.created + ' were allocated. A node that nothing points to is a leak' + (tree.orphans.length ? ' (drawn on the right)' : '') + '.', [23], tree.orphans[0] || null);
      else push('Every node passed, the walk met ' + plural(count, 'key') + ' (the tree claims ' + tree.len + ') and reached ' + plural(reachable, 'node') + ' (allocated: ' + tree.created + '). <b>validate: ok</b>', [22, 23], null);
    }
    steps.error = error;
    return steps;
  }
  function validateName(tree) { return validateSteps(tree).error; }

  /* The ten corruptions of broken.zig / broken.rs, on the canonical tree. */
  function leafAt(t, i) { return t.root.children[i]; }
  var CASES = [
    { what: 'leaf [12 15 17] reordered to [12 17 15]', expect: 'KeysOutOfOrder',
      apply: function (t) { leafAt(t, 2).keys = [12, 17, 15]; } },
    { what: 'leaf [7] holds 11 instead: sorted, but on the wrong side of separator 10', expect: 'KeyOutsideParentBounds',
      apply: function (t) { leafAt(t, 1).keys = [11]; } },
    { what: 'leaf [12 15 17] gets a fourth key, 18', expect: 'NodeOverfull',
      apply: function (t) { leafAt(t, 2).keys.push(18); t.len += 1; } },
    { what: 'leaf [7] loses its only key', expect: 'NodeUnderfull',
      apply: function (t) { leafAt(t, 1).keys = []; t.len -= 1; } },
    { what: "the root's key count is set to 0", expect: 'EmptyRoot',
      apply: function (t) { t.root.keys = []; t.root.meta = { label: '0 keys, 4 children' }; } },
    { what: 'leaf [12 15 17] becomes interior [15] above new leaves [12] and [17]', expect: 'LeavesAtDifferentDepths',
      apply: function (t) {
        var low = t.leaf([12]), high = t.leaf([17]), n = leafAt(t, 2);
        t.len -= 2;
        n.leaf = false; n.keys = [15]; n.children = [low, high];
      } },
    { what: "the root's last child pointer is erased", expect: 'MissingChild', searchable: false,
      apply: function (t) {
        var lost = t.root.children[3]; // still allocated, but out of reach: drawn as a second root
        lost.meta = { note: 'nothing points here any more' };
        t.orphans.push(lost);
        t.root.children[3] = null; t.root.meta = { note: 'child 3: pointer erased' };
      } },
    { what: 'leaf [7] gets a child pointer', expect: 'UnexpectedChild',
      apply: function (t) { leafAt(t, 1).children = [{ ref: leafAt(t, 0).id }]; leafAt(t, 1).meta = { note: 'leaf with a child pointer' }; } },
    { what: 'key 5 vanishes from leaf [1 3 5], the tree still claims 12 keys', expect: 'WrongKeyCount',
      apply: function (t) { leafAt(t, 0).keys.pop(); } },
    { what: 'a sixth node is allocated but nothing points to it', expect: 'NodeCountMismatch',
      apply: function (t) { var n = t.leaf([99]); n.meta = { note: 'nothing points here' }; t.orphans.push(n); t.len -= 1; } }
  ];
  function keysFound(t) {
    return CANONICAL_KEYS.filter(function (key) { return t.get(key) === valueOf(key); }).length;
  }
  /* The different keys stored in the nodes of `t`, and how many of them
   * `get` finds: counted on the tree itself, whatever keys it holds. */
  function storedFound(t) {
    var seen = {}, stored = 0, found = 0;
    preorder(t.root).forEach(function (n) {
      n.keys.forEach(function (key) {
        if (seen[key]) return;
        seen[key] = true; stored++;
        if (t.get(key) === valueOf(key)) found++;
      });
    });
    return { stored: stored, found: found };
  }
  /* Part 4 of the program output. */
  function brokenText() {
    var out = '';
    CASES.forEach(function (c, i) {
      var t = canonical();
      c.apply(t);
      var name = validateName(t);
      out += (i < 9 ? ' ' : '') + (i + 1) + '. ' + c.what + '\n    validate: ' + (name || 'ok') +
        (c.searchable === false ? '; get not tried (it could follow the erased pointer)' : '; get finds ' + keysFound(t) + ' of the 12 original keys') + '\n';
    });
    return out;
  }

  /* ------------------------------------------------------------- red-black */
  function describe(keys) {
    if (keys.length === 1) return keys[0] + ' black';
    if (keys.length === 2) return keys[1] + ' black, red left child ' + keys[0];
    return keys[1] + ' black, red children ' + keys[0] + ' and ' + keys[2];
  }
  /* 2-3-4 nodes in the order the programs describe them (parents first). */
  function preorder(node) {
    var out = [];
    (function walk(n) { if (!n) return; out.push(n); if (!n.leaf) n.children.forEach(walk); })(node);
    return out;
  }
  /* TreeView model in which the 2-3-4 nodes listed in `expanded` (a set of
   * ids) are drawn as black + red binary nodes and the others as they are. */
  function hybrid(node, expanded) {
    if (!node) return null;
    var sub = node.leaf ? [] : node.children.map(function (c) { return hybrid(c, expanded); });
    if (!expanded[node.id]) return { id: node.id, keys: node.keys.slice(), leaf: node.leaf, children: sub };
    function rb(key, color, left, right) {
      var kids = [];
      if (left) kids.push(right ? left : withSide(left, 'left'));
      if (right) kids.push(left ? right : withSide(right, 'right'));
      return { id: 'k' + key, keys: [key], color: color, leaf: !kids.length, children: kids };
    }
    function withSide(n, side) { var c = {}; for (var p in n) c[p] = n[p]; c.side = side; return c; }
    var k = node.keys;
    if (k.length === 1) return rb(k[0], 'black', sub[0], sub[1]);
    if (k.length === 2) return rb(k[1], 'black', rb(k[0], 'red', sub[0], sub[1]), sub[2]);
    return rb(k[1], 'black', rb(k[0], 'red', sub[0], sub[1]), rb(k[2], 'red', sub[2], sub[3]));
  }
  function redBlack(node) {
    var all = {};
    preorder(node).forEach(function (n) { all[n.id] = true; });
    return hybrid(node, all);
  }
  /* Red-black rules + search order. Returns a summary or throws an Error. */
  function rbCheck(rb) {
    var s = { nodes: 0, blackHeight: 0, shortest: 0, longest: 0 };
    if (!rb) return s;
    if (rb.color === 'red') throw new Error('RootIsRed');
    s.shortest = Infinity;
    function child(n, side) {
      for (var i = 0; i < n.children.length; i++) {
        var c = n.children[i];
        if (n.children.length === 2 ? i === (side === 'left' ? 0 : 1) : c.side === side) return c;
      }
      return null;
    }
    function walk(n, lo, hi, depth) {
      s.nodes++;
      var key = n.keys[0];
      if ((lo !== null && key <= lo) || (hi !== null && key >= hi)) throw new Error('KeysOutOfOrder');
      var black = [0, 0];
      ['left', 'right'].forEach(function (side, j) {
        var c = child(n, side);
        if (c) {
          if (n.color === 'red' && c.color === 'red') throw new Error('RedHasRedChild');
          black[j] = walk(c, j === 0 ? lo : key, j === 0 ? key : hi, depth + 1);
        } else { s.shortest = Math.min(s.shortest, depth); s.longest = Math.max(s.longest, depth); }
      });
      if (black[0] !== black[1]) throw new Error('BlackHeightDiffers');
      return black[0] + (n.color === 'black' ? 1 : 0);
    }
    s.blackHeight = walk(rb, null, null, 1);
    return s;
  }
  /* Part 6 of the program output. */
  function redBlackText(tree) {
    var out = '';
    preorder(tree.root).forEach(function (n) { out += '  ' + fmtKeys(n.keys) + ' -> ' + describe(n.keys) + '\n'; });
    var s = rbCheck(redBlack(tree.root));
    return out + 'red-black tree: ' + s.nodes + ' nodes, ' + s.blackHeight + ' black nodes on every path (B-tree height ' + heightOf(tree.root) +
      '), paths of ' + s.shortest + ' to ' + s.longest + ' nodes\n';
  }

  /* ---------------------------------------------------------------- height */
  /* Plain numbers: fine for the sizes this page uses (results below 2^53). */
  function minKeys(M, h) { return h === 0 ? 0 : 2 * Math.pow(Math.ceil(M / 2), h - 1) - 1; }
  function maxKeys(M, h) { return Math.pow(M, h) - 1; }
  function minHeight(M, n) { var h = 0; while (maxKeys(M, h) < n) h++; return h; }
  function maxHeight(M, n) { if (n === 0) return 0; var h = 1; while (minKeys(M, h + 1) <= n) h++; return h; }
  function heightsText() {
    var out = '';
    [12, 1000, 1000000, 1000000000].forEach(function (n) {
      out += '  n=' + n + ':';
      [4, 16, 256, 1024].forEach(function (M) { out += ' M=' + M + ': ' + minHeight(M, n) + '..' + maxHeight(M, n); });
      out += '\n';
    });
    return out;
  }

  /* ------------------------------------------------------------ SplitMix64 */
  /* common/zig/prng.zig with BigInt, so the oracle keys are the programs'. */
  function SplitMix64(seed) { this.state = BigInt(seed); }
  SplitMix64.prototype.next = function () {
    var mask = (1n << 64n) - 1n;
    this.state = (this.state + 0x9E3779B97F4A7C15n) & mask;
    var z = this.state;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & mask;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & mask;
    return z ^ (z >> 31n);
  };
  SplitMix64.prototype.below = function (n) { return Number((this.next() * BigInt(n)) >> 64n); };
  SplitMix64.prototype.chance = function (num, den) { return this.below(den) < num; };

  /* Part 7 of the program output. */
  function oracleText() {
    var prng = new SplitMix64(3), present = [], sorted = [], key;
    for (key = 0; key < 2000; key++) { present.push(prng.chance(3, 10)); if (present[key]) sorted.push(key); }
    var out = '== 7. Oracle check: ' + sorted.length + ' of the keys 0..1999 (seed 3), several orders ==\n';
    [3, 4, 5, 8].forEach(function (M) {
      var t = new HandTree(M).fromSorted(sorted), agree = 0;
      for (key = 0; key < 2000; key++) if (t.get(key) === (present[key] ? valueOf(key) : null)) agree++;
      var s = shape(t.root, M);
      out += '  M=' + M + ': height=' + s.height + ' (bounds ' + minHeight(M, sorted.length) + '..' + maxHeight(M, sorted.length) + ') nodes=' + s.nodes +
        ' fill=' + s.fill + '% validate ' + (validateName(t) || 'ok') + ', ' + agree + ' of 2000 lookups agree\n';
    });
    return out;
  }

  root.Ch03 = {
    HandTree: HandTree, CANONICAL_KEYS: CANONICAL_KEYS, canonical: canonical, sparsest: sparsest, fullest: fullest,
    valueOf: valueOf, fmtKeys: fmtKeys, renderText: renderText, shape: shape, shapeText: shapeText, heightOf: heightOf,
    lowerBound: lowerBound, searchSteps: searchSteps, inOrderKeys: inOrderKeys, inOrderSteps: inOrderSteps,
    RULES: RULES, validateSteps: validateSteps, validateName: validateName, CASES: CASES, keysFound: keysFound, storedFound: storedFound, brokenText: brokenText, plural: plural,
    describe: describe, preorder: preorder, hybrid: hybrid, redBlack: redBlack, rbCheck: rbCheck, redBlackText: redBlackText,
    minKeys: minKeys, maxKeys: maxKeys, minHeight: minHeight, maxHeight: maxHeight, heightsText: heightsText,
    SplitMix64: SplitMix64, oracleText: oracleText
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = root.Ch03;
})(typeof window !== 'undefined' ? window : globalThis);

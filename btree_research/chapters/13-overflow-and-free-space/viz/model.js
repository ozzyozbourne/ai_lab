/* Chapter 13 — a JavaScript model of zig/src/disk_btree.zig at page granularity.
 *
 * It keeps what decides the SHAPE of the file: which page is allocated or freed
 * when, how many bytes each leaf cell costs, where a full leaf is cut, what the
 * free list looks like. It does not keep the value bytes or the buffer pool.
 * Fed the sixteen operations of the programs' part 1, it must end with the tree
 * dump and the page map that expected_output.txt prints (index.html checks).
 *
 * Limit of this model, not of the format: keys are two characters, so there are
 * at most 100 of them and the tree never needs a third level. Interior splits and
 * freeing interior pages exist only in the Zig and Rust code and their tests.
 *
 * Classic script: defines window.Ch13.
 */
(function () {
  'use strict';

  var PAGE_SIZE = 4096, CAPACITY = 4076, KEY_LEN = 2;
  var MAX_LOCAL = 1088, MIN_LOCAL = 544, OVERFLOW_PAYLOAD = 4084, TRUNK_CAPACITY = 1021;
  var MAX_VALUE_LEN = 65536;
  var INTERIOR_CELL = 4 + KEY_LEN + 4 + 2;   // cell header, key, child id, slot

  /** Bytes of a value of `total` bytes that stay in the leaf cell (SQLite's rule). */
  function localLen(total) {
    if (total <= MAX_LOCAL) return total;
    var k = MIN_LOCAL + (total - MIN_LOCAL) % OVERFLOW_PAYLOAD;
    return k <= MAX_LOCAL ? k : MIN_LOCAL;
  }
  function overflowPages(total) { return Math.ceil((total - localLen(total)) / OVERFLOW_PAYLOAD); }
  /** What a leaf cell costs its page: cell header 4, key, value field, slot 2. */
  function cellCost(total) {
    var field = 4 + localLen(total) + (total > MAX_LOCAL ? 4 : 0);
    return 4 + KEY_LEN + field + 2;
  }
  /** The shortest prefix with at least half of the bytes (see splitPoint in the code). */
  function splitPoint(costs, minRight) {
    var total = 0, left = 0, last = costs.length - minRight, i;
    for (i = 0; i < costs.length; i++) total += costs[i];
    for (i = 0; i < last; i++) { left += costs[i]; if (2 * left >= total) return i + 1; }
    return last;
  }
  function clone(v) { return JSON.parse(JSON.stringify(v)); }
  function k(key, state) { return '<b class="bt-k' + (state ? ' s-' + state : '') + '">' + key + '</b>'; }
  function pg(id) { return '<b>page ' + id + '</b>'; }

  function Model() {
    this.s = {
      pages: [{ role: 'meta' }, { role: 'leaf', cells: [], next: null }],
      root: 1, freeHead: null, freeCount: 0, keyCount: 0,
      stats: { grown: 0, reused: 0, freed: 0, overflowWritten: 0, treeFreed: 0, leafSplits: 0, rootSplits: 0, rootCollapses: 0 }
    };
    this.steps = null;
  }

  Model.prototype.snapshot = function () { return clone(this.s); };
  Model.prototype.pageCount = function () { return this.s.pages.length; };

  /* ---- recording ------------------------------------------------------- */

  Model.prototype.emit = function (caption, highlight, log) {
    if (!this.steps) return;
    this.steps.push({ caption: caption, state: this.snapshot(), highlight: highlight || {}, log: log || null });
  };

  /* ---- the free list ---------------------------------------------------- */

  /** Take a page for a new owner. Returns {id, how, trunk}. */
  Model.prototype.alloc = function () {
    var s = this.s, id;
    if (s.freeHead === null) {
      id = s.pages.length;
      s.pages.push({ role: 'free' });
      s.stats.grown++;
      return { id: id, how: 'grow' };
    }
    var trunkId = s.freeHead, trunk = s.pages[trunkId];
    s.freeCount--; s.stats.reused++;
    if (trunk.ids.length === 0) {
      s.freeHead = trunk.next;
      return { id: trunkId, how: 'trunk-itself' };
    }
    id = trunk.ids.pop();
    return { id: id, how: 'trunk-entry', trunk: trunkId };
  };

  function sourceText(a) {
    if (a.how === 'grow') return 'The free list is empty, so the file grows: ' + pg(a.id) + ' is new.';
    if (a.how === 'trunk-itself') return 'The first trunk lists nothing more, so the trunk page itself, ' + pg(a.id) + ', is handed out and the free list moves on to the next trunk.';
    return 'Trunk page ' + a.trunk + ' gives up the last id it lists: ' + pg(a.id) + ' is reused. The file does not grow.';
  }

  /** Put page `id` on the free list. Returns 'trunk' (it became one) or 'listed'. */
  Model.prototype.free = function (id, was) {
    var s = this.s, head = s.freeHead;
    s.freeCount++; s.stats.freed++;
    if (head !== null && s.pages[head].ids.length < TRUNK_CAPACITY) {
      s.pages[head].ids.push(id);
      s.pages[id] = { role: 'free', was: was };
      return 'listed';
    }
    s.pages[id] = { role: 'trunk', next: head, ids: [] };
    s.freeHead = id;
    return 'trunk';
  };

  function freeText(id, how, head) {
    if (how === 'trunk') return pg(id) + ' is freed. There is no trunk with room, so the page itself becomes the first trunk of the free list (one page write).';
    return pg(id) + ' is freed: its id is appended to trunk page ' + head + '. The freed page is neither read nor written; its old bytes stay where they are.';
  }

  /* ---- helpers on the tree ---------------------------------------------- */

  Model.prototype.leafUsed = function (page) {
    var used = 0;
    page.cells.forEach(function (c) { used += cellCost(c.total); });
    return used;
  };

  /** The leaf that owns `key`: {id, index} with index = position in the root's children, or null. */
  Model.prototype.findLeaf = function (key) {
    var root = this.s.pages[this.s.root];
    if (root.role === 'leaf') return { id: this.s.root, index: null };
    var i = 0;
    while (i < root.keys.length && key >= root.keys[i]) i++;    // equal goes right
    return { id: root.children[i], index: i };
  };

  function cellIndex(page, key) {
    for (var i = 0; i < page.cells.length; i++) if (page.cells[i].key === key) return i;
    return -1;
  }

  Model.prototype.chainOf = function (cell) {
    var ids = [], id = cell.first;
    while (id !== null && id !== undefined) { ids.push(id); id = this.s.pages[id].next; }
    return ids;
  };

  Model.prototype.freeChain = function (key, ids) {
    var self = this;
    ids.forEach(function (id) {
      var head = self.s.freeHead;
      var how = self.free(id, 'overflow page of ' + key);
      var hl = { pages: {} }; hl.pages[id] = 'deleted';
      if (how === 'listed') hl.pages[self.s.freeHead] = 'inserted';
      self.emit('Nothing points at the old chain of ' + k(key) + ' any more. ' + freeText(id, how, head), hl, 'free page ' + id);
    });
  };

  /* ---- put --------------------------------------------------------------- */

  /** Insert or overwrite. `opts.steps === false` mutates without recording. Returns the steps. */
  Model.prototype.put = function (key, total, opts) {
    var self = this, s = this.s;
    this.steps = (opts && opts.steps === false) ? null : [];
    var before = clone(s.stats), pagesBefore = s.pages.length;
    var local = localLen(total), npages = overflowPages(total), cost = cellCost(total);
    var at = this.findLeaf(key), leafId = at.id;
    var oldIndex = cellIndex(s.pages[leafId], key);
    var old = oldIndex >= 0 ? s.pages[leafId].cells[oldIndex] : null;
    var oldChain = old ? this.chainOf(old) : [];
    var hl0 = { pages: {} }; hl0.pages[leafId] = 'active';

    var why;
    if (total <= MAX_LOCAL) {
      why = total + ' bytes are at most X = ' + MAX_LOCAL + ', so the whole value fits in the leaf cell.';
    } else {
      var kk = MIN_LOCAL + (total - MIN_LOCAL) % OVERFLOW_PAYLOAD;
      why = total + ' bytes are more than X = ' + MAX_LOCAL + ', so the value spills. K = ' + MIN_LOCAL + ' + (' + total + ' − ' + MIN_LOCAL + ') mod ' + OVERFLOW_PAYLOAD + ' = ' + kk +
        (kk <= MAX_LOCAL ? ', which is at most X: ' + kk + ' bytes stay in the leaf and the other ' + (total - local) + ' fill ' + npages + ' overflow page' + (npages > 1 ? 's' : '') + ' exactly.'
                         : ', which is more than X: only M = ' + MIN_LOCAL + ' bytes stay in the leaf and the other ' + (total - local) + ' go to ' + npages + ' overflow page' + (npages > 1 ? 's' : '') + ' (the last one is not full).');
    }
    this.emit((old ? 'Overwrite ' : 'Put ') + k(key, 'compare') + ' with a value of ' + total + ' bytes. Its leaf is ' + pg(leafId) + '. ' + why, hl0,
      (old ? 'overwrite ' : 'put ') + key + ' = ' + total + ' B');

    // 1. The chain first: the leaf must never point at pages that do not exist yet.
    var first = null, prev = null, written = local;
    for (var i = 0; i < npages; i++) {
      var a = this.alloc();
      var n = Math.min(total - written, OVERFLOW_PAYLOAD);
      s.pages[a.id] = { role: 'overflow', next: null, owner: key, part: i + 1, of: npages, bytes: n };
      if (prev === null) first = a.id; else s.pages[prev].next = a.id;
      s.stats.overflowWritten++;
      var hl = { pages: {} }; hl.pages[a.id] = 'inserted';
      this.emit(sourceText(a) + ' It becomes overflow page ' + (i + 1) + ' of ' + npages + ' and takes value bytes ' + written + ' to ' + (written + n - 1) +
        (prev === null ? '. The leaf does not point at it yet.' : '; ' + pg(prev) + ' now links to it.'), hl,
        'page ' + a.id + ' ← overflow ' + (i + 1) + '/' + npages + ' of ' + key + (a.how === 'grow' ? ' (file grows)' : ' (reused)'));
      written += n; prev = a.id;
    }
    var cell = { key: key, total: total, local: local, first: first };

    // 2. The leaf cell.
    var leaf = s.pages[leafId];
    var used = this.leafUsed(leaf), oldCost = old ? cellCost(old.total) : 0;
    if (used - oldCost + cost <= CAPACITY) {
      if (old) leaf.cells[oldIndex] = cell; else { leaf.cells.push(cell); leaf.cells.sort(byKey); }
      var hl1 = { pages: {}, cell: { page: leafId, key: key, state: 'inserted' } }; hl1.pages[leafId] = 'inserted';
      this.emit('The cell goes into leaf ' + pg(leafId) + ': key, the length ' + total + ', ' + local + ' value bytes' + (first !== null ? ' and the id of the first overflow page (' + first + ')' : '') +
        '. It costs the page ' + cost + ' bytes; the leaf now uses ' + this.leafUsed(leaf) + ' of ' + CAPACITY + '.', hl1, 'leaf ' + leafId + ': cell ' + key);
    } else {
      this.split(at, cell, old ? oldIndex : -1, used - oldCost + cost);
    }

    // 3. The old chain last, when no cell points at it any more.
    this.freeChain(key, oldChain);
    if (!old) s.keyCount++;
    this.done(before, pagesBefore, (old ? 'Overwrite' : 'Put') + ' of ' + k(key) + ' finished');
    return this.finish();
  };

  function byKey(a, b) { return a.key < b.key ? -1 : a.key > b.key ? 1 : 0; }

  Model.prototype.split = function (at, cell, oldIndex, needed) {
    var s = this.s, leafId = at.id, index = at.index, a, hl;
    hl = { pages: {} }; hl.pages[leafId] = 'split';
    this.emit('Leaf ' + pg(leafId) + ' has no room: with this cell it would need ' + needed + ' of ' + CAPACITY + ' bytes. It must split. "Full" is a number of bytes, as in chapter 12.', hl, 'leaf ' + leafId + ' is full');

    if (index === null) {
      // The root never splits: its content moves down first.
      a = this.alloc();
      s.pages[a.id] = s.pages[s.root];
      s.pages[s.root] = { role: 'interior', keys: [], children: [a.id] };
      s.stats.rootSplits++;
      leafId = a.id; index = 0;
      hl = { pages: {} }; hl.pages[a.id] = 'inserted'; hl.pages[s.root] = 'inserted';
      this.emit('The full leaf is the root, and the root keeps its page id. ' + sourceText(a) + ' The root\'s cells move there, and page ' + s.root + ' becomes an interior page with that one child.', hl,
        'root content → page ' + a.id);
    }
    var leaf = s.pages[leafId];
    var cells = leaf.cells.slice();
    if (oldIndex >= 0) cells[oldIndex] = cell; else { cells.push(cell); cells.sort(byKey); }
    var cut = splitPoint(cells.map(function (c) { return cellCost(c.total); }), 1);
    a = this.alloc();
    s.pages[a.id] = { role: 'leaf', cells: cells.slice(cut), next: leaf.next };
    leaf.cells = cells.slice(0, cut);
    leaf.next = a.id;
    s.stats.leafSplits++;
    hl = { pages: {}, cell: { page: (cellIndex(leaf, cell.key) >= 0 ? leafId : a.id), key: cell.key, state: 'inserted' } };
    hl.pages[leafId] = 'split'; hl.pages[a.id] = 'split';
    this.emit(sourceText(a) + ' The cells are cut where the left part first holds half of the bytes: ' + pg(leafId) + ' keeps ' + this.leafUsed(leaf) + ' bytes, ' + pg(a.id) + ' gets ' +
      this.leafUsed(s.pages[a.id]) + ' and is linked in after it.', hl, 'split leaf ' + leafId + ' → ' + leafId + ' + ' + a.id);

    var root = s.pages[s.root], sep = s.pages[a.id].cells[0].key;
    if ((root.keys.length + 1) * INTERIOR_CELL > CAPACITY) throw new Error('interior split: outside this model');
    root.keys.splice(index, 0, sep);
    root.children.splice(index + 1, 0, a.id);
    hl = { pages: {} }; hl.pages[s.root] = 'inserted';
    this.emit('A copy of the right half\'s first key, ' + k(sep, 'split') + ', goes into the root as the separator between ' + pg(leafId) + ' and ' + pg(a.id) + '.', hl, 'root: separator ' + sep);
  };

  /* ---- delete ------------------------------------------------------------ */

  Model.prototype.del = function (key, opts) {
    var s = this.s;
    this.steps = (opts && opts.steps === false) ? null : [];
    var before = clone(s.stats), pagesBefore = s.pages.length;
    var at = this.findLeaf(key), leafId = at.id, leaf = s.pages[leafId];
    var i = cellIndex(leaf, key), hl = { pages: {} };
    hl.pages[leafId] = 'active';
    if (i < 0) {
      this.emit('Delete ' + k(key, 'compare') + ': its leaf would be ' + pg(leafId) + ', and the key is not there. Nothing changes.', hl, 'delete ' + key + ': not found');
      var none = this.finish(); none.ok = false; return none;
    }
    var chain = this.chainOf(leaf.cells[i]);
    hl.cell = { page: leafId, key: key, state: 'deleted' };
    this.emit('Delete ' + k(key, 'deleted') + ': the cell is in leaf ' + pg(leafId) + (chain.length ? ', and its value continues in ' + chain.length + ' overflow page' + (chain.length > 1 ? 's' : '') + '.' : '.'), hl, 'delete ' + key);

    if (leaf.cells.length > 1 || at.index === null) {
      leaf.cells.splice(i, 1);
      hl = { pages: {} }; hl.pages[leafId] = 'deleted';
      this.emit('The cell is removed from ' + pg(leafId) + '. The leaf still uses ' + this.leafUsed(leaf) + ' of ' + CAPACITY + ' bytes' +
        (at.index === null ? '' : '; it stays where it is, however empty: pages are freed only when their LAST cell goes') + '.', hl, 'leaf ' + leafId + ': cell removed');
    } else {
      this.removeLeaf(at, key);
    }
    this.freeChain(key, chain);
    s.keyCount--;
    this.done(before, pagesBefore, 'Delete of ' + k(key) + ' finished');
    var steps = this.finish(); steps.ok = true; return steps;
  };

  Model.prototype.removeLeaf = function (at, key) {
    var s = this.s, leafId = at.id, index = at.index, root = s.pages[s.root], hl;
    var n = root.keys.length, next = s.pages[leafId].next;
    hl = { pages: {} }; hl.pages[leafId] = 'deleted';
    this.emit(k(key, 'deleted') + ' is the last cell of leaf ' + pg(leafId) + ': the whole page leaves the tree ("free at empty"). First every pointer to it has to go.', hl, 'leaf ' + leafId + ' is empty');

    if (index > 0) {
      var leftId = root.children[index - 1];
      s.pages[leftId].next = next;
      hl = { pages: {} }; hl.pages[leftId] = 'inserted'; hl.pages[leafId] = 'deleted';
      this.emit('The leaf chain: the left sibling ' + pg(leftId) + ' now links to ' + (next === null ? 'nothing (it is the last leaf)' : pg(next)) + ', past the leaf that goes.', hl, 'leaf ' + leftId + ': next → ' + (next === null ? '–' : next));
    }
    // One separator disappears with the pointer; no key moves between pages.
    var gone = index === n ? root.keys[n - 1] : root.keys[index];
    if (index === n) root.keys.pop(); else root.keys.splice(index, 1);
    root.children.splice(index, 1);
    hl = { pages: {} }; hl.pages[s.root] = 'inserted'; hl.pages[leafId] = 'deleted';
    this.emit('The parent: the pointer to ' + pg(leafId) + ' and the separator ' + k(gone, 'deleted') + ' are removed from the root. The neighbouring leaf inherits the empty key range; no key moves.', hl, 'root: separator ' + gone + ' removed');

    var head = s.freeHead, how = this.free(leafId, 'leaf');
    s.stats.treeFreed++;
    hl = { pages: {} }; hl.pages[leafId] = 'deleted';
    if (how === 'listed') hl.pages[s.freeHead] = 'inserted';
    this.emit('Only now, with no pointer left to it: ' + freeText(leafId, how, head), hl, 'free page ' + leafId);

    if (root.keys.length === 0) {
      var childId = root.children[0];
      s.pages[s.root] = s.pages[childId];
      s.stats.rootCollapses++; s.stats.treeFreed++;
      head = s.freeHead; how = this.free(childId, 'leaf');
      hl = { pages: {} }; hl.pages[s.root] = 'inserted'; hl.pages[childId] = 'deleted';
      if (how === 'listed') hl.pages[s.freeHead] = 'inserted';
      this.emit('The root is left with a single child and no key. The child\'s content is copied into the root page (the root keeps its id; the tree is one level lower) and ' + freeText(childId, how, head), hl,
        'root collapses; free page ' + childId);
    }
  };

  /* ---- bookkeeping ------------------------------------------------------- */

  Model.prototype.done = function (before, pagesBefore, text) {
    var st = this.s.stats, freed = st.freed - before.freed, reused = st.reused - before.reused, grew = this.s.pages.length - pagesBefore;
    this.emit(text + ': ' + freed + ' page' + (freed === 1 ? '' : 's') + ' freed, ' + reused + ' reused, the file grew by ' + grew + '. It has ' + this.s.pages.length + ' pages, ' +
      this.s.freeCount + ' of them free.', {}, null);
  };

  Model.prototype.finish = function () {
    var steps = this.steps || [];
    this.steps = null;
    return steps;
  };

  /* ---- what the programs print ------------------------------------------- */

  /** The text of `tree.dump()` in the Zig and Rust programs. */
  Model.prototype.dump = function () {
    var s = this.s, self = this, out = [];
    function leafLine(id, indent) {
      var p = s.pages[id];
      var cells = p.cells.map(function (c) {
        return c.key + ':' + c.total + (c.first === null ? '' : '=' + c.local + '+[' + self.chainOf(c).join(' ') + ']');
      });
      return indent + 'page ' + id + '  leaf      ' + p.cells.length + ' keys  ' + self.leafUsed(p) + '/' + CAPACITY + ' bytes  next ' + (p.next === null ? '-' : p.next) + '  |' +
        (cells.length ? ' ' + cells.join(' ') : '');
    }
    var root = s.pages[s.root];
    if (root.role === 'leaf') out.push(leafLine(s.root, ''));
    else {
      var line = 'page ' + s.root + '  interior  ' + root.keys.length + ' keys  ' + root.keys.length * INTERIOR_CELL + '/' + CAPACITY + ' bytes  |';
      root.children.forEach(function (c, i) { line += ' (' + c + ')' + (i < root.keys.length ? ' ' + root.keys[i] : ''); });
      out.push(line);
      root.children.forEach(function (c) { out.push(leafLine(c, '  ')); });
    }
    var free = 'free list: ' + s.freeCount + ' pages';
    for (var t = s.freeHead; t !== null; t = s.pages[t].next) free += ' | trunk ' + t + ':' + s.pages[t].ids.map(function (id) { return ' ' + id; }).join('');
    out.push(free);
    return out.join('\n');
  };

  /** One letter per page, as `page map:` prints them: M I L O T F. */
  Model.prototype.pageMap = function () {
    var letters = { meta: 'M', interior: 'I', leaf: 'L', overflow: 'O', trunk: 'T', free: 'F' };
    return this.s.pages.map(function (p) { return letters[p.role]; }).join(' ');
  };

  /** Problems with the model's own state ([] when it is consistent). */
  Model.prototype.validate = function () {
    var s = this.s, errors = [], seen = {}, self = this;
    function claim(id, role) {
      if (id === null || id === undefined || !s.pages[id]) { errors.push('bad page id ' + id); return false; }
      if (seen[id]) { errors.push('page ' + id + ' used as ' + seen[id] + ' and ' + role); return false; }
      if (s.pages[id].role !== role) errors.push('page ' + id + ' is ' + s.pages[id].role + ', expected ' + role);
      seen[id] = role; return true;
    }
    function leaf(id) {
      if (!claim(id, 'leaf')) return;
      var p = s.pages[id];
      if (self.leafUsed(p) > CAPACITY) errors.push('leaf ' + id + ' over capacity');
      p.cells.forEach(function (c) {
        var ids = self.chainOf(c);
        if (ids.length !== overflowPages(c.total)) errors.push('chain of ' + c.key + ' has the wrong length');
        ids.forEach(function (o) { claim(o, 'overflow'); });
      });
    }
    seen[0] = 'meta';
    var root = s.pages[s.root];
    if (root.role === 'leaf') leaf(s.root);
    else {
      claim(s.root, 'interior');
      if (root.keys.length === 0) errors.push('interior root without a key');
      root.children.forEach(function (c, i) {
        leaf(c);
        if (s.pages[c].cells.length === 0) errors.push('empty leaf ' + c);
        var want = i + 1 < root.children.length ? root.children[i + 1] : null;
        if (s.pages[c].next !== want) errors.push('leaf chain broken at ' + c);
      });
    }
    var listed = 0;
    for (var t = s.freeHead; t !== null; t = s.pages[t].next) {
      if (!claim(t, 'trunk')) break;
      listed += 1 + s.pages[t].ids.length;
      s.pages[t].ids.forEach(function (f) { claim(f, 'free'); });
    }
    if (listed !== s.freeCount) errors.push('free count ' + s.freeCount + ' but ' + listed + ' listed');
    for (var i = 0; i < s.pages.length; i++) if (!seen[i]) errors.push('page ' + i + ' has no role');
    return errors;
  };

  window.Ch13 = {
    Model: Model, localLen: localLen, overflowPages: overflowPages, cellCost: cellCost, splitPoint: splitPoint,
    PAGE_SIZE: PAGE_SIZE, CAPACITY: CAPACITY, MAX_LOCAL: MAX_LOCAL, MIN_LOCAL: MIN_LOCAL,
    OVERFLOW_PAYLOAD: OVERFLOW_PAYLOAD, TRUNK_CAPACITY: TRUNK_CAPACITY, MAX_VALUE_LEN: MAX_VALUE_LEN
  };
})();

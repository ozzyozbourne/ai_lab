/* Chapter 12, JS model: the same DiskBTree as zig/src/disk_btree.zig, with
 * the same buffer pool (CLOCK) under it, minus the bytes: a page is a list
 * of cells and every size is computed with the slotted page's arithmetic
 * (cell = 4 + key + value, slot = 2, page capacity = page size - 4 reserved
 * - 16 header). The tree code below makes the same pool calls in the same
 * order as the Zig and Rust programs, so the counters they print can be
 * checked against this model (see the self-tests on both pages).
 *
 * Classic script: defines window.CH12 (and module.exports under node).
 */
(function (root) {
  'use strict';

  var INVALID = 0xFFFFFFFF;

  function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  function kb(text, state) {
    return '<b class="bt-k' + (state ? ' s-' + state : '') + '">' + esc(text) + '</b>';
  }
  function clone(v) { return JSON.parse(JSON.stringify(v)); }

  // ---- buffer pool: chapter 09's CLOCK, bookkeeping only ---------------------

  function Pool(frameCount) {
    this.frames = [];
    for (var i = 0; i < frameCount; i++) this.frames.push({ page: null, pin: 0, ref: false, dirty: false });
    this.hand = 0;
    this.pageCount = 0;
    this.stats = { hits: 0, misses: 0, evictions: 0, writebacks: 0 };
    this.pager = { reads: 0, writes: 0, allocations: 0, syncs: 0 };
    this.onEvent = null;
  }
  Pool.prototype.emit = function (ev) { if (this.onEvent) this.onEvent(ev); };
  Pool.prototype.frameOf = function (id) {
    for (var f = 0; f < this.frames.length; f++) if (this.frames[f].page === id) return f;
    return -1;
  };
  Pool.prototype.takeFrame = function () {
    var n = this.frames.length;
    for (var steps = 0; steps < 2 * n; steps++) {
      var f = this.hand;
      var frame = this.frames[f];
      if (frame.page !== null) {
        if (frame.pin > 0) {
          this.hand = (this.hand + 1) % n;
          this.emit({ type: 'skip-pinned', frame: f, page: frame.page });
          continue;
        }
        if (frame.ref) {
          frame.ref = false;
          this.hand = (this.hand + 1) % n;
          this.emit({ type: 'second-chance', frame: f, page: frame.page });
          continue;
        }
        var victim = frame.page;
        var wrote = frame.dirty;
        if (frame.dirty) { this.pager.writes++; this.stats.writebacks++; }
        this.frames[f] = { page: null, pin: 0, ref: false, dirty: false };
        this.stats.evictions++;
        this.emit({ type: 'evict', frame: f, page: victim, wrote: wrote });
      }
      this.hand = (this.hand + 1) % n;
      return f;
    }
    throw new Error('AllFramesPinned');
  };
  Pool.prototype.fetch = function (id) {
    if (id >= this.pageCount) throw new Error('PageOutOfRange');
    var f = this.frameOf(id);
    if (f >= 0) {
      this.frames[f].pin++;
      this.frames[f].ref = true;
      this.stats.hits++;
      this.emit({ type: 'hit', frame: f, page: id });
      return;
    }
    this.stats.misses++;
    f = this.takeFrame();
    this.pager.reads++;
    this.frames[f] = { page: id, pin: 1, ref: true, dirty: false };
    this.emit({ type: 'miss', frame: f, page: id });
  };
  Pool.prototype.newPage = function () {
    var f = this.takeFrame();
    var id = this.pageCount++;
    this.pager.allocations++;
    this.frames[f] = { page: id, pin: 1, ref: true, dirty: false };
    this.emit({ type: 'new', frame: f, page: id });
    return id;
  };
  Pool.prototype.unpin = function (id, dirty) {
    var frame = this.frames[this.frameOf(id)];
    frame.pin--;
    if (dirty) frame.dirty = true;
    this.emit({ type: 'unpin', frame: this.frameOf(id), page: id, dirty: dirty });
  };
  Pool.prototype.flushAll = function () {
    for (var f = 0; f < this.frames.length; f++) {
      var frame = this.frames[f];
      if (frame.page === null || !frame.dirty) continue;
      this.pager.writes++;
      frame.dirty = false;
      this.emit({ type: 'write', frame: f, page: frame.page });
    }
    this.pager.syncs++;
    this.emit({ type: 'sync' });
  };
  Pool.prototype.pinned = function () {
    return this.frames.filter(function (fr) { return fr.pin > 0; }).length;
  };

  // ---- the tree ----------------------------------------------------------------

  var SIZES = {
    4096: { pageSize: 4096, maxKey: 256, maxValue: 1024 },
    // Not a real format: a toy page small enough that interior pages split
    // on screen. The rule "three cells always fit" still holds.
    512: { pageSize: 512, maxKey: 30, maxValue: 128 }
  };

  function Tree(opts) {
    opts = opts || {};
    var size = SIZES[opts.pageSize || 4096];
    this.pageSize = size.pageSize;
    this.capacity = size.pageSize - 4 - 16;
    this.maxKey = size.maxKey;
    this.maxValue = size.maxValue;
    this.pool = new Pool(opts.frames || 3);
    this.pages = {};          // id -> {leaf, cells: [{k, v}] | [{k, c}], link}
    this.root = 1;
    this.keyCount = 0;
    this.stats = { leaf: 0, interior: 0, root: 0 };
    this.steps = null;        // array while recording
    this.detail = opts.detail || 'tree';   // 'tree' | 'pool'
    this.why = '';
    this.orphans = [];        // pages that exist but have no parent yet (mid-split)
    this.mark = {};           // highlight of the step being recorded
    var self = this;
    this.pool.onEvent = function (ev) { self.onPoolEvent(ev); };
    // create(): metapage, root leaf, flush.
    var meta = this.pool.newPage();
    this.pool.unpin(meta, true);
    var rootId = this.pool.newPage();
    this.pages[rootId] = { leaf: true, cells: [], link: INVALID };
    this.pool.unpin(rootId, true);
    this.flush();
  }

  Tree.SIZES = SIZES;
  Tree.INVALID = INVALID;

  Tree.prototype.cost = function (page, cell) {
    return 4 + cell.k.length + (page.leaf ? cell.v : 4) + 2;
  };
  Tree.prototype.used = function (id) {
    var page = this.pages[id], sum = 0;
    for (var i = 0; i < page.cells.length; i++) sum += this.cost(page, page.cells[i]);
    return sum;
  };
  function search(page, key) {
    var lo = 0, hi = page.cells.length;
    while (lo < hi) {
      var mid = lo + ((hi - lo) >> 1);
      if (page.cells[mid].k < key) lo = mid + 1; else hi = mid;
    }
    return { found: lo < page.cells.length && page.cells[lo].k === key, index: lo };
  }
  function childAt(page, i) { return i === page.cells.length ? page.link : page.cells[i].c; }
  function childIndex(page, key) { var r = search(page, key); return r.found ? r.index + 1 : r.index; }
  function splitPoint(costs, minRight) {
    var total = 0, i;
    for (i = 0; i < costs.length; i++) total += costs[i];
    var last = costs.length - minRight, left = 0;
    for (i = 0; i < last; i++) {
      left += costs[i];
      if (2 * left >= total) return i + 1;
    }
    return last;
  }
  Tree.splitPoint = splitPoint;

  Tree.prototype.flush = function () {
    this.why = 'flush: the metapage (page 0) gets the current root id, page count and key count';
    this.pool.fetch(0);
    this.pool.unpin(0, true);
    this.why = 'flush: every dirty page is written, in frame order, one write at a time';
    this.pool.flushAll();
  };

  Tree.prototype.findLeaf = function (key, path) {
    var id = this.root;
    for (;;) {
      this.why = 'descend: pin page ' + id + ' to read it';
      this.pool.fetch(id);
      var page = this.pages[id];
      if (page.leaf) {
        this.why = 'page ' + id + ' is the leaf; it is unpinned (and pinned again by the caller)';
        this.pool.unpin(id, false);
        return id;
      }
      var index = childIndex(page, key);
      var child = childAt(page, index);
      var hl = { nodes: {}, keys: {}, edges: {} };
      hl.nodes['p' + id] = 'active';
      hl.edges['p' + child] = 'active';
      var text;
      if (index < page.cells.length) {
        hl.keys['p' + id + ':' + page.cells[index].k] = 'compare';
        text = kb(key) + ' is smaller than separator ' + kb(page.cells[index].k, 'compare') + ', so the key belongs to the child left of it: page ' + child + '.';
      } else if (page.cells.length > 0) {
        hl.keys['p' + id + ':' + page.cells[index - 1].k] = 'compare';
        text = kb(key) + ' is not smaller than the last separator ' + kb(page.cells[index - 1].k, 'compare') + ', so it belongs to the rightmost child: page ' + child + '.';
      } else {
        text = 'It has no separator yet, only its rightmost child: page ' + child + '.';
      }
      this.step('descend', 'Page ' + id + ' is an interior page. ' + text, hl, 'put');
      this.why = 'the child id is known, so page ' + id + ' is unpinned before the child is fetched';
      this.pool.unpin(id, false);
      if (path) path.push({ id: id, index: index });
      id = child;
    }
  };

  /* Insert or overwrite. `vlen` is the LENGTH of the value: the model keeps
   * no value bytes. Returns the recorded steps if `record` is true. */
  Tree.prototype.put = function (key, vlen, record) {
    if (key.length > this.maxKey) throw new Error('KeyTooLarge');
    if (vlen > this.maxValue) throw new Error('ValueTooLarge');
    this.steps = record ? [] : null;
    var cell = { k: key, v: vlen };
    var need = 4 + key.length + vlen + 2;
    this.step('start', 'Put key ' + kb(key, 'inserted') + ' with a value of ' + vlen + ' bytes. The cell costs ' + need +
      ' bytes of its page: 4 (cell header) + ' + key.length + ' (key) + ' + vlen + ' (value) + 2 (slot).', {}, 'put');

    var path = [];
    var leafId = this.findLeaf(key, path);
    this.why = 'pin the leaf to insert into it';
    this.pool.fetch(leafId);
    var leaf = this.pages[leafId];
    var r = search(leaf, key);
    var free = this.capacity - this.used(leafId);
    var freed = r.found ? this.cost(leaf, leaf.cells[r.index]) : 0;
    var hl = { nodes: {}, keys: {} };
    hl.nodes['p' + leafId] = 'active';
    if (need <= free + freed) {
      if (r.found) leaf.cells[r.index] = cell; else leaf.cells.splice(r.index, 0, cell);
      hl.keys['p' + leafId + ':' + key] = 'inserted';
      this.step('fit', 'Leaf page ' + leafId + ' has ' + free + ' free bytes' + (r.found ? ' (plus ' + freed + ' from the cell being replaced)' : '') +
        ' and the cell needs ' + need + ': it fits. One page changed, in memory only; the file is not touched until the page is evicted or flushed.', hl, 'put');
      this.why = 'the leaf was modified: unpin it as dirty';
      this.pool.unpin(leafId, true);
    } else {
      hl.nodes['p' + leafId] = 'split';
      this.step('full', 'Leaf page ' + leafId + ' has only ' + free + ' free bytes and the cell needs ' + need + '. The page is full, with ' +
        leaf.cells.length + ' cells in it: full is a number of bytes, not a number of keys. It must split.', hl, 'put');
      this.why = 'nothing was changed yet: unpin the leaf as clean';
      this.pool.unpin(leafId, false);
      this.splitAndInsert(path, leafId, cell);
    }
    if (!r.found) this.keyCount++;
    this.step('done', 'Done: ' + this.keyCount + ' keys in ' + this.pool.pageCount + ' pages (page 0 is the metapage). ' +
      'The changed pages are dirty in the buffer pool; nothing here made the change durable.', {}, 'put');
    var steps = this.steps;
    this.steps = null;
    return steps;
  };

  Tree.prototype.splitAndInsert = function (path, leafId, cell) {
    var id = leafId;
    if (path.length === 0) {
      id = this.pushRootDown();
      path.push({ id: this.root, index: 0 });
    }
    var carry = this.splitLeaf(id, cell);
    for (;;) {
      var parent = path.pop();
      if (this.insertSeparator(parent, carry)) return;
      if (path.length === 0) {
        parent = { id: this.pushRootDown(), index: parent.index };
        path.push({ id: this.root, index: 0 });
      }
      carry = this.splitInterior(parent, carry);
    }
  };

  Tree.prototype.pushRootDown = function () {
    this.why = 'the root is full: pin it to move its content down';
    this.pool.fetch(this.root);
    this.why = 'allocate the page that receives the root\'s content';
    var child = this.pool.newPage();
    var rootPage = this.pages[this.root];
    this.pages[child] = rootPage;
    this.pages[this.root] = { leaf: false, cells: [], link: child };
    this.stats.root++;
    var hl = { nodes: {} };
    hl.nodes['p' + this.root] = 'active';
    hl.nodes['p' + child] = 'split';
    this.step('root-down', 'The full page is the root, and the root must stay page ' + this.root + ' (the metapage and every reader find the tree there). ' +
      'So the root does not split: its content is copied to the new page ' + child + ', and page ' + this.root +
      ' becomes an interior page with no key and page ' + child + ' as its only child. The tree is one level taller; now page ' + child + ' splits like any other page.',
      hl, 'pushRootDown');
    this.why = 'both pages changed: unpin them as dirty';
    this.pool.unpin(child, true);
    this.pool.unpin(this.root, true);
    return child;
  };

  Tree.prototype.splitLeaf = function (id, cell) {
    this.why = 'pin the leaf that splits (the left half stays on this page)';
    this.pool.fetch(id);
    var old = this.pages[id];
    var r = search(old, cell.k);
    var cells = old.cells.slice();
    if (r.found) cells[r.index] = cell; else cells.splice(r.index, 0, cell);
    var self = this;
    var costs = cells.map(function (c) { return self.cost(old, c); });
    var k = splitPoint(costs, 1);
    this.why = 'allocate the page for the right half; with it, two pages are pinned at once';
    var right = this.pool.newPage();
    this.pages[right] = { leaf: true, cells: cells.slice(k), link: old.link };
    this.pages[id] = { leaf: true, cells: cells.slice(0, k), link: right };
    this.stats.leaf++;
    this.orphans.push(right);
    var total = costs.reduce(function (a, b) { return a + b; }, 0);
    var hl = { nodes: {}, keys: {}, links: {} };
    hl.nodes['p' + id] = 'split';
    hl.nodes['p' + right] = 'split';
    hl.keys['*:' + cell.k] = 'inserted';
    hl.links['p' + id] = 'active';
    this.step('split-leaf', 'The ' + cells.length + ' cells (the old ones and the new one) cost ' + total + ' bytes together. The left half is the shortest prefix with at least half of the bytes: ' +
      k + ' cells (' + this.used(id) + ' bytes) stay on page ' + id + ', ' + (cells.length - k) + ' cells (' + this.used(right) + ' bytes) go to the new page ' + right +
      '. The leaf chain now runs ' + id + ' → ' + right + '. No parent knows page ' + right + ' yet: if the process died here, a search from the root would never reach its keys.',
      hl, 'splitLeaf');
    this.why = 'both halves were written in memory: unpin them as dirty';
    this.pool.unpin(right, true);
    this.pool.unpin(id, true);
    return { sep: cells[k].k, left: id, right: right };
  };

  Tree.prototype.insertSeparator = function (parent, carry) {
    this.why = 'pin the parent to record the split in it';
    this.pool.fetch(parent.id);
    var page = this.pages[parent.id];
    var need = 4 + carry.sep.length + 4 + 2;
    var free = this.capacity - this.used(parent.id);
    var hl = { nodes: {}, keys: {}, edges: {} };
    if (need > free) {
      hl.nodes['p' + parent.id] = 'split';
      this.step('parent-full', 'Parent page ' + parent.id + ' has only ' + free + ' free bytes; the separator cell for ' + kb(carry.sep, 'split') + ' needs ' + need +
        ' (4 + ' + carry.sep.length + ' key + 4 child id + 2 slot). The parent must split too.', hl, 'insertSeparator');
      this.why = 'the parent is unchanged: unpin it as clean';
      this.pool.unpin(parent.id, false);
      return false;
    }
    if (parent.index === page.cells.length) page.link = carry.right; else page.cells[parent.index].c = carry.right;
    page.cells.splice(parent.index, 0, { k: carry.sep, c: carry.left });
    this.orphans = this.orphans.filter(function (o) { return o !== carry.right; });
    hl.nodes['p' + parent.id] = 'active';
    hl.keys['p' + parent.id + ':' + carry.sep] = 'split';
    hl.edges['p' + carry.right] = 'active';
    this.step('separator', 'The split is recorded in parent page ' + parent.id + ': the cell (' + kb(carry.sep, 'split') + ' → page ' + carry.left +
      ') is inserted, and the pointer after it now leads to page ' + carry.right + '. ' +
      (this.pages[carry.right].leaf ? 'The separator is a copy of the first key of page ' + carry.right + '; the key itself stays in the leaf.' : 'The separator moved up out of the split page.'),
      hl, 'insertSeparator');
    this.why = 'the parent changed: unpin it as dirty';
    this.pool.unpin(parent.id, true);
    return true;
  };

  Tree.prototype.splitInterior = function (parent, carry) {
    var id = parent.id;
    this.why = 'pin the interior page that splits';
    this.pool.fetch(id);
    var old = this.pages[id];
    var entries = old.cells.map(function (c) { return { k: c.k, c: c.c }; });
    var rightmost = old.link;
    entries.splice(parent.index, 0, { k: carry.sep, c: carry.left });
    if (parent.index + 1 < entries.length) entries[parent.index + 1].c = carry.right; else rightmost = carry.right;
    var self = this;
    var costs = entries.map(function (e) { return self.cost(old, e); });
    var k = splitPoint(costs, 2);
    this.why = 'allocate the page for the right half of the interior page';
    var right = this.pool.newPage();
    this.pages[id] = { leaf: false, cells: entries.slice(0, k), link: entries[k].c };
    this.pages[right] = { leaf: false, cells: entries.slice(k + 1), link: rightmost };
    this.stats.interior++;
    this.orphans = this.orphans.filter(function (o) { return o !== carry.right; });
    this.orphans.push(right);
    var hl = { nodes: {}, keys: {} };
    hl.nodes['p' + id] = 'split';
    hl.nodes['p' + right] = 'split';
    this.step('split-interior', 'Interior page ' + id + ' splits around the new separator, again by bytes: ' + k + ' cells stay on page ' + id + ', ' +
      (entries.length - k - 1) + ' go to the new page ' + right + ', and the middle key ' + kb(entries[k].k, 'split') +
      ' moves up to the parent. It is moved, not copied: an interior key is only a signpost, and the middle one is needed in neither half.', hl, 'splitInterior');
    this.why = 'both halves were written in memory: unpin them as dirty';
    this.pool.unpin(right, true);
    this.pool.unpin(id, true);
    return { sep: entries[k].k, left: id, right: right };
  };

  // ---- reading, the way the programs do it (same pool calls) -------------------

  Tree.prototype.get = function (key) {
    var leafId = this.findLeaf(key, null);
    this.pool.fetch(leafId);
    var r = search(this.pages[leafId], key);
    var v = r.found ? this.pages[leafId].cells[r.index].v : null;
    this.pool.unpin(leafId, false);
    return v;
  };

  Tree.prototype.height = function () {
    var levels = 1, id = this.root;
    for (;;) {
      this.pool.fetch(id);
      var page = this.pages[id];
      this.pool.unpin(id, false);
      if (page.leaf) return levels;
      id = childAt(page, 0);
      levels++;
    }
  };

  /* Same text as DiskBTree.dump. */
  Tree.prototype.dump = function () {
    var out = [], self = this;
    (function walk(id, depth) {
      self.pool.fetch(id);
      var page = self.pages[id];
      var n = page.cells.length;
      var head = new Array(depth + 1).join('  ') + 'page ' + id;
      if (page.leaf) {
        out.push(head + '  leaf      ' + n + ' keys  ' + self.used(id) + '/' + self.capacity + ' bytes  next ' +
          (page.link === INVALID ? '-' : page.link) + '  |' + page.cells.map(function (c) { return ' ' + c.k + ':' + c.v; }).join(''));
        self.pool.unpin(id, false);
        return;
      }
      var line = head + '  interior  ' + n + ' keys  ' + self.used(id) + '/' + self.capacity + ' bytes  |';
      var children = [];
      for (var i = 0; i <= n; i++) {
        children.push(childAt(page, i));
        line += ' (' + children[i] + ')' + (i < n ? ' ' + page.cells[i].k : '');
      }
      out.push(line);
      self.pool.unpin(id, false);
      children.forEach(function (c) { walk(c, depth + 1); });
    })(this.root, 0);
    return out.join('\n');
  };

  /* Invariants T2 to T8 of disk_btree.zig. Returns null or the error name. */
  Tree.prototype.validate = function () {
    var self = this, seen = { 0: true }, leaves = [], leafDepth = null, keys = 0, error = null;
    function fail(name) { if (!error) error = name; }
    (function visit(id, lo, hi, depth) {
      if (error) return;
      if (!(id in self.pages)) return fail('BadPage');
      if (seen[id]) return fail('PageReachedTwice');
      seen[id] = true;
      self.pool.fetch(id);
      self.pool.unpin(id, false);
      var page = self.pages[id], n = page.cells.length, i;
      for (i = 1; i < n; i++) if (!(page.cells[i - 1].k < page.cells[i].k)) return fail('BadPage');
      if (n > 0 && lo !== null && page.cells[0].k < lo) return fail('KeyOutOfBounds');
      if (n > 0 && hi !== null && !(page.cells[n - 1].k < hi)) return fail('KeyOutOfBounds');
      if (self.used(id) > self.capacity) return fail('BadPage');
      if (page.leaf) {
        if (n === 0 && id !== self.root) return fail('EmptyPage');
        if (leafDepth === null) leafDepth = depth;
        if (leafDepth !== depth) return fail('UnevenDepth');
        keys += n;
        leaves.push({ id: id, next: page.link });
        return;
      }
      if (n === 0) return fail('EmptyPage');
      for (i = 0; i <= n; i++) visit(childAt(page, i), i === 0 ? lo : page.cells[i - 1].k, i === n ? hi : page.cells[i].k, depth + 1);
    })(this.root, null, null, 0);
    if (error) return error;
    for (var i = 0; i < leaves.length; i++) {
      if (leaves[i].next !== (i + 1 < leaves.length ? leaves[i + 1].id : INVALID)) return 'LeafChainBroken';
    }
    for (var id = 0; id < this.pool.pageCount; id++) if (!seen[id]) return 'UnreachablePage';
    if (keys !== this.keyCount) return 'KeyCountMismatch';
    return null;
  };

  Tree.prototype.counters = function () {
    var h = this.height(), p = this.pool;
    return 'tree:  ' + this.keyCount + ' keys, ' + p.pageCount + ' pages, height ' + h + '; splits: ' + this.stats.leaf + ' leaf, ' + this.stats.interior + ' interior, ' + this.stats.root + ' root\n' +
      'pool:  ' + p.stats.hits + ' hits, ' + p.stats.misses + ' misses, ' + p.stats.evictions + ' evictions, ' + p.stats.writebacks + ' write-backs\n' +
      'pager: ' + p.pager.reads + ' reads, ' + p.pager.writes + ' writes, ' + p.pager.allocations + ' allocations, ' + p.pager.syncs + ' syncs';
  };

  // ---- snapshots for the views ---------------------------------------------------

  /* TreeView model. Pages that no parent points to yet (the right half of a
   * split whose parent is not updated) are drawn as extra roots. */
  Tree.prototype.snapshot = function () {
    var self = this;
    function node(id) {
      var page = self.pages[id];
      var f = self.pool.frameOf(id);
      var out = {
        id: 'p' + id,
        keys: page.cells.map(function (c) { return c.k; }),
        leaf: page.leaf,
        meta: { label: 'page ' + id, note: self.used(id) + ' / ' + self.capacity + ' B', dirty: f >= 0 && self.pool.frames[f].dirty }
      };
      if (page.leaf) {
        if (page.link !== INVALID) out.next = 'p' + page.link;
      } else {
        out.children = [];
        for (var i = 0; i <= page.cells.length; i++) out.children.push(node(childAt(page, i)));
      }
      return out;
    }
    var roots = [node(this.root)];
    this.orphans.forEach(function (id) { roots.push(node(id)); });
    return roots.length === 1 ? roots[0] : roots;
  };

  Tree.prototype.frameModel = function () {
    return { hand: this.pool.hand, frames: this.pool.frames.map(function (fr) {
      return fr.page === null ? { page: null } : { page: fr.page, pin: fr.pin, ref: fr.ref ? 1 : 0, dirty: fr.dirty };
    }) };
  };

  Tree.prototype.fill = function () {
    var ids = Object.keys(this.pages).map(Number).sort(function (a, b) { return a - b; }), self = this;
    return { labels: ids.map(function (id) { return 'p' + id; }), values: ids.map(function (id) { return self.used(id); }),
      cells: ids.map(function (id) { return self.pages[id].cells.length; }) };
  };

  Tree.prototype.step = function (type, caption, highlight, code) {
    if (!this.steps) return;
    this.mark = highlight || {};
    this.steps.push(this.makeStep(type, caption, highlight || {}, code, type === 'start' || type === 'done' ? null : caption));
  };

  Tree.prototype.makeStep = function (type, caption, highlight, code, log) {
    var p = this.pool;
    return {
      type: type, caption: caption, state: this.snapshot(), highlight: highlight, code: code,
      frames: this.frameModel(), fill: this.fill(),
      pinnedPages: p.frames.filter(function (fr) { return fr.pin > 0; }).map(function (fr) { return fr.page; }),
      cachedPages: p.frames.filter(function (fr) { return fr.page !== null; }).map(function (fr) { return fr.page; }),
      dirtyPages: p.frames.filter(function (fr) { return fr.dirty; }).map(function (fr) { return fr.page; }),
      counters: { hits: p.stats.hits, misses: p.stats.misses, evictions: p.stats.evictions, writebacks: p.stats.writebacks,
        reads: p.pager.reads, writes: p.pager.writes, allocations: p.pager.allocations, pages: p.pageCount },
      log: log ? { html: log, state: type.indexOf('split') >= 0 || type === 'root-down' ? 'split' : undefined } : undefined
    };
  };

  /* In 'pool' detail every buffer pool call becomes a step of its own. */
  Tree.prototype.onPoolEvent = function (ev) {
    if (!this.steps || this.detail !== 'pool') return;
    var name = ev.page === 0 ? 'page 0 (the metapage)' : 'page ' + ev.page;
    var text, state;
    switch (ev.type) {
      case 'hit': text = '<b>fetch ' + name + '</b>: it is cached in frame ' + ev.frame + ', so no file read. Its pin count goes up and its referenced bit is set.'; break;
      case 'miss': text = '<b>fetch ' + name + '</b>: not cached, so it is read from the file into frame ' + ev.frame + ' and pinned.'; state = 'compare'; break;
      case 'new': text = '<b>new page ' + ev.page + '</b>: the file grows by one zero-filled page; it is pinned in frame ' + ev.frame + ' without a read.'; state = 'inserted'; break;
      case 'unpin': text = '<b>unpin ' + name + '</b>' + (ev.dirty ? ' as <b>dirty</b>: the frame now differs from the file and must be written before it is reused.' : ' (not modified).'); state = ev.dirty ? 'dirty' : undefined; break;
      case 'skip-pinned': text = 'The clock hand is at frame ' + ev.frame + ': ' + name + ' is <b>pinned</b>, so it cannot be evicted. The hand moves on.'; break;
      case 'second-chance': text = 'The clock hand is at frame ' + ev.frame + ': ' + name + ' was used recently. Its referenced bit is cleared (its second chance) and the hand moves on.'; break;
      case 'evict': text = '<b>evict ' + name + '</b> from frame ' + ev.frame + (ev.wrote ? ': it is dirty, so it is <b>written to the file first</b>. This write happens in the middle of the operation, whenever the pool needs a frame, and not when the tree is in a consistent state.' : ': it is clean, so the frame is simply reused.'); state = ev.wrote ? 'deleted' : undefined; break;
      case 'write': text = '<b>write ' + name + '</b> (frame ' + ev.frame + ') to the file. Pages go out one at a time; a crash between two of these writes leaves a file with some new pages and some old ones.'; state = 'found'; break;
      case 'sync': text = '<b>sync</b>: ask the operating system to make the writes durable. Only now is the file up to date.'; state = 'found'; break;
      default: text = ev.type;
    }
    var caption = text + (this.why ? ' <span class="ch12-why">Why: ' + esc(this.why) + '.</span>' : '');
    var step = this.makeStep('pool-' + ev.type, caption, this.mark, null, text);
    if (state && step.log) step.log.state = state;
    step.event = ev;
    this.steps.push(step);
  };

  /* Flush as recorded steps (page 2). */
  Tree.prototype.flushSteps = function () {
    this.steps = [];
    this.mark = {};
    this.step('start', 'Flush: bring the file up to date. First the metapage is updated in memory, then every dirty page is written, in frame order.', {}, null);
    this.flush();
    this.step('done', 'Flushed and synced: every frame is clean, the file holds the whole tree.', {}, null);
    var steps = this.steps;
    this.steps = null;
    return steps;
  };

  /* The fixed scenario of the programs (demo.zig / demo.rs, part 1). */
  var SCENARIO = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15, 8, 22, 28, 14, 2, 27, 18, 9, 23, 11, 29, 4];
  function scenarioKey(n) { return (n < 10 ? '0' : '') + n; }
  function scenarioValueLen(n, pageSize) { return pageSize === 512 ? 37 + 3 * n : 300 + 24 * n; }

  /* Replays part 1 exactly as the programs run it (including the dumps and
   * the validate, which also go through the pool) and returns what they
   * print for it. */
  function replayPart1() {
    var tree = new Tree({ pageSize: 4096, frames: 3 });
    var firstSplitDump = null;
    SCENARIO.forEach(function (n) {
      var before = clone(tree.stats);
      tree.put(scenarioKey(n), scenarioValueLen(n, 4096), false);
      if (tree.stats.leaf !== before.leaf && tree.stats.root !== before.root) firstSplitDump = tree.dump();
    });
    var dump = tree.dump();
    var valid = tree.validate();
    var counters = tree.counters();
    return { tree: tree, firstSplitDump: firstSplitDump, dump: dump, valid: valid, counters: counters };
  }

  var api = { Tree: Tree, Pool: Pool, SCENARIO: SCENARIO, scenarioKey: scenarioKey, scenarioValueLen: scenarioValueLen, replayPart1: replayPart1, kb: kb, esc: esc };
  root.CH12 = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);

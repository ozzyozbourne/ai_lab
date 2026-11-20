/*
 * Chapter 27 — chapter-local models (no DOM; also runs under node).
 *
 *   Ch27.Device        the counted block device of zig/src/device.zig
 *   Ch27.BPlus         the instrumented B+tree (zig/src/base_*.zig), same split points,
 *                      same borrow/merge preference, same pin/dirty accounting
 *   Ch27.Lsm           the LSM-tree of zig/src/lsm.zig (memtable as a sorted array:
 *                      the skip list's shape never reaches the output)
 *   Ch27.Pair          both of them on one operation stream, with a per-operation
 *                      report that the page turns into frames, and the text of
 *                      sections 1 and 2 of the programs' output (for the self-test)
 *   Ch27.BufferedNode  page 2: one buffered (B-epsilon) node. Textbook model, JS only.
 *
 * Why not BTViz.models.BPlusTree? It has no block accounting. This page has to
 * reproduce the read/write counts that the Zig and Rust programs print.
 */
(function (root) {
  'use strict';

  function lowerBound(keys, key) {
    var lo = 0, hi = keys.length;
    while (lo < hi) { var mid = lo + ((hi - lo) >> 1); if (keys[mid] < key) lo = mid + 1; else hi = mid; }
    return lo;
  }
  function upperBound(keys, key) {
    var lo = 0, hi = keys.length;
    while (lo < hi) { var mid = lo + ((hi - lo) >> 1); if (keys[mid] <= key) lo = mid + 1; else hi = mid; }
    return lo;
  }
  function clone(v) { return JSON.parse(JSON.stringify(v)); }

  /* ================================================================ device */

  var INDEX = 0, DATA = 1;

  function Device() {
    this.reads = [0, 0]; this.writes = [0, 0];
    this.live = 0; this.peak = 0;
    this.pins = [];                  // [{id, kind, dirty}] of the operation in progress
    this.log = { read: [], written: [], created: [] };   // block ids, for the pictures
  }
  Device.prototype.totalReads = function () { return this.reads[0] + this.reads[1]; };
  Device.prototype.totalWrites = function () { return this.writes[0] + this.writes[1]; };
  Device.prototype.allocBlocks = function (n) { this.live += n; this.peak = Math.max(this.peak, this.live); };
  Device.prototype.freeBlocks = function (n) { this.live -= n; };
  Device.prototype.read = function (kind, n) { this.reads[kind] += n; };
  Device.prototype.write = function (kind, n) { this.writes[kind] += n; };
  Device.prototype.findPin = function (id) {
    for (var i = 0; i < this.pins.length; i++) if (this.pins[i].id === id) return i;
    return -1;
  };
  Device.prototype.pin = function (id, kind) {
    if (this.findPin(id) >= 0) return;
    this.read(kind, 1);
    this.log.read.push(id);
    this.pins.push({ id: id, kind: kind, dirty: false });
  };
  Device.prototype.pinNew = function (id, kind) {
    this.allocBlocks(1);
    this.log.created.push(id);
    this.pins.push({ id: id, kind: kind, dirty: true });
  };
  Device.prototype.markDirty = function (id) { this.pins[this.findPin(id)].dirty = true; };
  Device.prototype.release = function (id) {
    this.freeBlocks(1);
    var i = this.findPin(id);
    if (i >= 0) this.pins.splice(i, 1);
  };
  Device.prototype.endOp = function () {
    for (var i = 0; i < this.pins.length; i++) {
      if (this.pins[i].dirty) { this.write(this.pins[i].kind, 1); this.log.written.push(this.pins[i].id); }
    }
    this.pins = [];
  };
  Device.prototype.takeLog = function () {
    var l = this.log;
    this.log = { read: [], written: [], created: [] };
    return l;
  };

  /* ================================================================ B+tree */

  function BPlus(order) {
    this.order = order;
    this.nodes = {};               // id -> node; ids are never reused
    this.nextId = 0;
    this.root = -1; this.height = 0; this.count = 0;
    this.stats = { leafSplits: 0, internalSplits: 0, borrows: 0, merges: 0 };
    this.dev = new Device();
  }
  var B = BPlus.prototype;
  B.maxKeys = function () { return this.order - 1; };
  B.minKeys = function () { return Math.ceil(this.order / 2) - 1; };
  B.touch = function (id) { this.dev.pin(id, this.nodes[id].leaf ? DATA : INDEX); };
  B.dirty = function (id) { this.dev.markDirty(id); };
  B.allocNode = function (leaf) {
    var id = this.nextId++;
    this.nodes[id] = leaf ? { id: id, leaf: true, keys: [], vals: [], prev: -1, next: -1 }
                          : { id: id, leaf: false, keys: [], children: [] };
    this.dev.pinNew(id, leaf ? DATA : INDEX);
    return id;
  };
  B.freeNode = function (id) { this.dev.release(id); delete this.nodes[id]; };

  B.findLeaf = function (key) {
    var id = this.root;
    if (id < 0) return -1;
    for (;;) {
      this.touch(id);
      var n = this.nodes[id];
      if (n.leaf) return id;
      id = n.children[upperBound(n.keys, key)];
    }
  };
  B.get = function (key) {
    var id = this.findLeaf(key);
    this.dev.endOp();
    if (id < 0) return null;
    var n = this.nodes[id], i = lowerBound(n.keys, key);
    return i < n.keys.length && n.keys[i] === key ? n.vals[i] : null;
  };
  /** Entries with lo <= key < hi; the leaves walked are logged as read. */
  B.range = function (lo, hi) {
    var out = [];
    if (lo >= hi) return out;
    var id = this.findLeaf(lo);
    this.dev.endOp();
    if (id < 0) return out;
    var i = lowerBound(this.nodes[id].keys, lo);
    while (id >= 0) {
      var n = this.nodes[id];
      if (i < n.keys.length) {
        if (n.keys[i] >= hi) break;
        out.push({ key: n.keys[i], value: n.vals[i] });
        i++;
        continue;
      }
      id = n.next; i = 0;
      if (id >= 0) { this.dev.read(DATA, 1); this.dev.log.read.push(id); }
    }
    return out;
  };

  B.put = function (key, value) {
    if (this.root < 0) { this.root = this.allocNode(true); this.height = 1; }
    var r = this._insertInto(this.root, key, value);
    if (r.split) {
      var nr = this.allocNode(false), n = this.nodes[nr];
      n.keys = [r.split.separator]; n.children = [this.root, r.split.right];
      this.root = nr; this.height++;
    }
    if (!r.replaced) this.count++;
    this.dev.endOp();
    return r.replaced ? r.old : null;
  };
  B._insertInto = function (id, key, value) {
    this.touch(id);
    var n = this.nodes[id], i;
    if (n.leaf) {
      i = lowerBound(n.keys, key);
      this.dirty(id);
      if (i < n.keys.length && n.keys[i] === key) {
        var old = n.vals[i]; n.vals[i] = value;
        return { replaced: true, old: old };
      }
      n.keys.splice(i, 0, key); n.vals.splice(i, 0, value);
      if (n.keys.length <= this.maxKeys()) return {};
      return { split: this._splitLeaf(id) };
    }
    i = upperBound(n.keys, key);
    var r = this._insertInto(n.children[i], key, value);
    if (!r.split) return r;
    n.keys.splice(i, 0, r.split.separator); n.children.splice(i + 1, 0, r.split.right);
    this.dirty(id);
    if (n.keys.length <= this.maxKeys()) return {};
    return { split: this._splitInternal(id) };
  };
  B._splitLeaf = function (leftId) {
    var rightId = this.allocNode(true);
    var left = this.nodes[leftId], right = this.nodes[rightId];
    var mid = left.keys.length >> 1;          // floor(M/2) stay, the rest moves
    right.keys = left.keys.splice(mid); right.vals = left.vals.splice(mid);
    var oldNext = left.next;
    right.prev = leftId; right.next = oldNext; left.next = rightId;
    if (oldNext >= 0) {                        // the back link lives in a third leaf
      this.touch(oldNext); this.dirty(oldNext);
      this.nodes[oldNext].prev = rightId;
    }
    this.stats.leafSplits++;
    return { separator: right.keys[0], right: rightId };
  };
  B._splitInternal = function (leftId) {
    var rightId = this.allocNode(false);
    var left = this.nodes[leftId], right = this.nodes[rightId];
    var mid = left.keys.length >> 1, separator = left.keys[mid];
    right.keys = left.keys.splice(mid + 1); left.keys.pop();
    right.children = left.children.splice(mid + 1);
    this.stats.internalSplits++;
    return { separator: separator, right: rightId };
  };

  B.delete = function (key) {
    if (this.root < 0) return null;
    var removed = this._deleteFrom(this.root, key);
    if (removed !== null) {
      this.count--;
      var rootNode = this.nodes[this.root];
      if (rootNode.keys.length === 0) {
        var old = this.root;
        this.root = rootNode.leaf ? -1 : rootNode.children[0];
        this.freeNode(old);
        this.height--;
      }
    }
    this.dev.endOp();
    return removed;
  };
  B._deleteFrom = function (id, key) {
    this.touch(id);
    var n = this.nodes[id], i;
    if (n.leaf) {
      i = lowerBound(n.keys, key);
      if (i === n.keys.length || n.keys[i] !== key) return null;
      this.dirty(id);
      n.keys.splice(i, 1);
      return n.vals.splice(i, 1)[0];
    }
    i = upperBound(n.keys, key);
    var childId = n.children[i];
    var removed = this._deleteFrom(childId, key);
    if (removed === null) return null;
    if (this.nodes[childId].keys.length < this.minKeys()) this._rebalance(id, i);
    return removed;
  };
  B._rebalance = function (parentId, i) {
    var parent = this.nodes[parentId], min = this.minKeys();
    this.dirty(parentId);
    if (i > 0) {
      this.touch(parent.children[i - 1]);
      if (this.nodes[parent.children[i - 1]].keys.length > min) { this._borrowLeft(parent, i); return; }
    }
    if (i < parent.keys.length) this.touch(parent.children[i + 1]);
    if (i < parent.keys.length && this.nodes[parent.children[i + 1]].keys.length > min) this._borrowRight(parent, i);
    else if (i > 0) this._merge(parent, i - 1);
    else this._merge(parent, i);
  };
  B._borrowLeft = function (parent, i) {
    var left = this.nodes[parent.children[i - 1]], child = this.nodes[parent.children[i]];
    this.dirty(left.id); this.dirty(child.id);
    if (child.leaf) {
      child.keys.unshift(left.keys.pop()); child.vals.unshift(left.vals.pop());
      parent.keys[i - 1] = child.keys[0];
    } else {
      child.keys.unshift(parent.keys[i - 1]); child.children.unshift(left.children.pop());
      parent.keys[i - 1] = left.keys.pop();
    }
    this.stats.borrows++;
  };
  B._borrowRight = function (parent, i) {
    var child = this.nodes[parent.children[i]], right = this.nodes[parent.children[i + 1]];
    this.dirty(child.id); this.dirty(right.id);
    if (child.leaf) {
      child.keys.push(right.keys.shift()); child.vals.push(right.vals.shift());
      parent.keys[i] = right.keys[0];
    } else {
      child.keys.push(parent.keys[i]); child.children.push(right.children.shift());
      parent.keys[i] = right.keys.shift();
    }
    this.stats.borrows++;
  };
  B._merge = function (parent, li) {
    var left = this.nodes[parent.children[li]], right = this.nodes[parent.children[li + 1]];
    this.dirty(left.id);
    if (left.leaf) {
      left.keys = left.keys.concat(right.keys); left.vals = left.vals.concat(right.vals);
      left.next = right.next;
      if (right.next >= 0) {
        this.touch(right.next); this.dirty(right.next);
        this.nodes[right.next].prev = left.id;
      }
    } else {
      left.keys = left.keys.concat([parent.keys[li]], right.keys);
      left.children = left.children.concat(right.children);
    }
    parent.keys.splice(li, 1); parent.children.splice(li + 1, 1);
    this.freeNode(right.id);
    this.stats.merges++;
  };

  /** TreeView model. */
  B.snapshot = function () {
    var self = this;
    if (this.root < 0) return null;
    return (function walk(id) {
      var n = self.nodes[id];
      var m = { id: 'b' + id, keys: n.keys.slice(), leaf: n.leaf };
      if (n.leaf) { if (n.next >= 0) m.next = 'b' + n.next; } else m.children = n.children.map(walk);
      return m;
    })(this.root);
  };
  /** The lines of the programs' dumpTree. */
  B.dumpLines = function () {
    var self = this, lines = [];
    for (var depth = 1; depth <= this.height; depth++) {
      var parts = [];
      (function walk(id, d) {
        var n = self.nodes[id];
        if (d > 1) { n.children.forEach(function (c) { walk(c, d - 1); }); return; }
        parts.push(n.leaf ? '(' + n.keys.join(' ') + ')' : '[' + n.keys.join(' ') + ']');
      })(this.root, depth);
      lines.push('  level ' + depth + ': ' + parts.join(' '));
    }
    return lines;
  };

  /* =================================================================== LSM */

  var MAX_LEVELS = 12;

  function Lsm(cfg) {
    this.cfg = cfg;                 // {blockEntries, indexFanout, memtableEntries, l0Runs, growth}
    this.dev = new Device();
    this.mem = [];                  // [{key, value}] sorted; value null = tombstone
    this.l0 = [];                   // runs, oldest first
    this.levels = [];               // levels[n-1] = run or null
    for (var i = 0; i < MAX_LEVELS; i++) this.levels.push(null);
    this.nextRun = 0;
    this.stats = { flushes: 0, l0Compactions: 0, levelMerges: 0, versionsDropped: 0, tombstonesDropped: 0,
                   runsSkipped: 0, runsProbed: 0, probesWasted: 0 };
    this.memWrites = 0;             // puts and deletes absorbed by the memtable since the last flush
    this.onPhase = null;            // function (name, info): called around flush / compaction
  }
  var L = Lsm.prototype;
  L.dataBlocks = function (n) { return Math.ceil(n / this.cfg.blockEntries); };
  /** Blocks per index level, bottom level first; the last entry is the single root block. */
  L.indexLevels = function (n) {
    var levels = [], b = this.dataBlocks(n);
    do { b = Math.ceil(b / this.cfg.indexFanout); levels.push(b); } while (b > 1);
    return levels;
  };
  L.indexHeight = function (n) { return this.indexLevels(n).length; };
  L.indexBlocks = function (n) { return this.indexLevels(n).reduce(function (a, b) { return a + b; }, 0); };
  L.blocks = function (n) { return this.dataBlocks(n) + this.indexBlocks(n); };
  L.levelLimit = function (n) { return this.cfg.memtableEntries * this.cfg.l0Runs * Math.pow(this.cfg.growth, n); };
  L.deepestLevel = function () {
    var n = MAX_LEVELS;
    while (n > 0 && !this.levels[n - 1]) n--;
    return n;
  };
  L.slotsOnDevice = function () {
    var n = 0;
    this.l0.forEach(function (r) { n += r.slots.length; });
    this.levels.forEach(function (r) { if (r) n += r.slots.length; });
    return n;
  };
  L._phase = function (name, info) { if (this.onPhase) this.onPhase(name, info || {}); };

  L._memPut = function (key, value) {
    var keys = this.mem.map(function (s) { return s.key; }), i = lowerBound(keys, key);
    if (i < this.mem.length && this.mem[i].key === key) this.mem[i].value = value;
    else this.mem.splice(i, 0, { key: key, value: value });
  };
  L.put = function (key, value) { this._maintain(); this._memPut(key, value); this.memWrites++; };
  L.delete = function (key) { this._maintain(); this._memPut(key, null); this.memWrites++; };

  L._pending = function () {
    if (this.l0.length >= this.cfg.l0Runs) return 0;
    for (var n = 1; n < MAX_LEVELS; n++) {
      if (this.levels[n - 1] && this.levels[n - 1].slots.length > this.levelLimit(n)) return n;
    }
    return -1;
  };
  L._maintain = function () {
    var n;
    while ((n = this._pending()) >= 0) this._compact(n);
    if (this.mem.length < this.cfg.memtableEntries) return;
    this._flush();
    while ((n = this._pending()) >= 0) this._compact(n);
  };
  /** Writes `slots` as a run: one write per data block, then every index level. */
  L._buildRun = function (slots) {
    if (!slots.length) return null;
    var d = this.dataBlocks(slots.length), x = this.indexBlocks(slots.length);
    this.dev.allocBlocks(d + x);
    this.dev.write(DATA, d); this.dev.write(INDEX, x);
    return { id: this.nextRun++, slots: slots, min: slots[0].key, max: slots[slots.length - 1].key };
  };
  L._flush = function () {
    if (!this.mem.length) return;
    var run = this._buildRun(this.mem);
    this.mem = [];
    this.l0.push(run);
    this.stats.flushes++;
    var absorbed = this.memWrites;
    this.memWrites = 0;
    this._phase('flush', { run: run.id, blocks: this.blocks(run.slots.length), writes: absorbed, keys: run.slots.length });
  };
  L._compact = function (from) {
    var self = this;
    var dropTombstones = this.deepestLevel() <= from + 1;
    var inputs = from === 0 ? this.l0.slice().reverse() : [this.levels[from - 1]];   // newest first
    if (this.levels[from]) inputs.push(this.levels[from]);
    var readBlocks = 0;
    inputs.forEach(function (r) { readBlocks += self.blocks(r.slots.length); });
    this._phase('compact-read', { from: from, inputs: inputs.map(function (r) { return r.id; }), blocks: readBlocks });

    // Every block of every input is read exactly once.
    inputs.forEach(function (r) {
      self.dev.read(DATA, self.dataBlocks(r.slots.length));
      self.dev.read(INDEX, self.indexBlocks(r.slots.length));
    });
    // K-way merge, newest version of each key wins.
    var newest = {}, shadowed = 0, tombstones = 0;
    inputs.forEach(function (r) {
      r.slots.forEach(function (s) { if (s.key in newest) shadowed++; else newest[s.key] = s; });
    });
    var out = Object.keys(newest).map(Number).sort(function (a, b) { return a - b; })
      .map(function (k) { return newest[k]; })
      .filter(function (s) { if (s.value === null && dropTombstones) { tombstones++; return false; } return true; });
    this.stats.versionsDropped += shadowed; this.stats.tombstonesDropped += tombstones;
    var output = this._buildRun(out);

    var freed = 0;
    inputs.forEach(function (r) { freed += self.blocks(r.slots.length); });
    this.dev.freeBlocks(freed);
    if (from === 0) { this.l0 = []; this.stats.l0Compactions++; }
    else { this.levels[from - 1] = null; this.stats.levelMerges++; }
    this.levels[from] = output;
    this._phase('compact-write', {
      from: from, output: output ? output.id : null, blocks: output ? this.blocks(output.slots.length) : 0,
      shadowed: shadowed, tombstones: tombstones, kept: out.length, freed: freed
    });
  };

  function findInRun(run, key) {
    var keys = run.slots.map(function (s) { return s.key; }), i = lowerBound(keys, key);
    if (i === keys.length || keys[i] !== key) return undefined;      // absent
    return run.slots[i].value;                                       // value or null (tombstone)
  }
  /** Newest place first. Returns the value or null; `trail` (optional) records every place looked at. */
  L.get = function (key, trail) {
    var self = this, result, i;
    trail = trail || [];
    for (i = 0; i < this.mem.length; i++) if (this.mem[i].key === key) result = this.mem[i].value;
    trail.push({ where: 'memtable', result: result === undefined ? 'absent' : result === null ? 'tombstone' : 'hit' });
    function probe(run, where) {
      if (key < run.min || key > run.max) {
        self.stats.runsSkipped++;
        trail.push({ where: where, run: run.id, result: 'skipped' });
        return undefined;
      }
      // Root to data block, one block per index level: the rule the B+tree is charged by.
      var height = self.indexHeight(run.slots.length);
      self.dev.read(INDEX, height); self.dev.read(DATA, 1);
      self.stats.runsProbed++;
      var r = findInRun(run, key);
      if (r === undefined) self.stats.probesWasted++;
      trail.push({ where: where, run: run.id, result: r === undefined ? 'wasted' : r === null ? 'tombstone' : 'hit', index: height,
                   block: Math.floor(lowerBound(run.slots.map(function (s) { return s.key; }), key) / self.cfg.blockEntries) });
      return r;
    }
    for (i = this.l0.length - 1; i >= 0 && result === undefined; i--) result = probe(this.l0[i], 'level 0');
    for (i = 0; i < MAX_LEVELS && result === undefined; i++) {
      if (this.levels[i]) result = probe(this.levels[i], 'level ' + (i + 1));
    }
    return result === undefined ? null : result;
  };
  /** Entries with lo <= key < hi. `trail` records, per overlapping run, the blocks its cursor entered. */
  L.range = function (lo, hi, trail) {
    var self = this, out = [];
    trail = trail || [];
    if (lo >= hi) return out;
    var newest = {};
    this.mem.forEach(function (s) { if (s.key >= lo && s.key < hi) newest[s.key] = s; });
    function add(run, where) {
      if (!(run.min < hi && lo <= run.max)) { trail.push({ where: where, run: run.id, result: 'skipped' }); return; }
      var keys = run.slots.map(function (s) { return s.key; });
      var a = lowerBound(keys, lo), b = lowerBound(keys, hi);
      // The cursor pays for the block it starts in and for every block it
      // enters, including the one holding the first key >= hi.
      var first = Math.floor(a / self.cfg.blockEntries);
      var last = Math.floor(Math.min(b, keys.length - 1) / self.cfg.blockEntries);
      // On every index level: the block above `first` (the path down from the
      // root) and every further block the cursor moves under.
      var index = 0, span = self.cfg.indexFanout;
      for (var lv = self.indexHeight(keys.length); lv > 0; lv--) {
        index += Math.floor(last / span) - Math.floor(first / span) + 1;
        span *= self.cfg.indexFanout;
      }
      self.dev.read(DATA, last - first + 1);
      self.dev.read(INDEX, index);
      trail.push({ where: where, run: run.id, result: 'read', first: first, last: last, index: index,
                   blocks: last - first + 1 + index });
      for (var i = a; i < b; i++) if (!(keys[i] in newest)) newest[keys[i]] = run.slots[i];
    }
    for (var i = this.l0.length - 1; i >= 0; i--) add(this.l0[i], 'level 0');
    for (i = 0; i < MAX_LEVELS; i++) if (this.levels[i]) add(this.levels[i], 'level ' + (i + 1));
    Object.keys(newest).map(Number).sort(function (a, b) { return a - b; }).forEach(function (k) {
      if (newest[k].value !== null) out.push({ key: k, value: newest[k].value });
    });
    return out;
  };

  L.snapshot = function () {
    var deepest = this.deepestLevel();
    return {
      cfg: this.cfg,
      mem: clone(this.mem),
      l0: clone(this.l0),
      levels: clone(this.levels.slice(0, Math.max(deepest, 1))),
      limits: [1, 2, 3, 4, 5, 6].map(this.levelLimit, this)
    };
  };
  function slotText(s) { return (s.value === null ? '~' : '') + s.key; }
  function runText(r) { return '(' + r.slots.map(slotText).join(' ') + ')'; }
  /** The lines of the programs' dumpLsm. */
  L.dumpLines = function () {
    var lines = ['  memtable:' + this.mem.map(function (s) { return ' ' + slotText(s); }).join('')];
    lines.push('  level 0 (oldest first): ' + (this.l0.length ? this.l0.map(runText).join(' ') : '-'));
    for (var i = 0; i < this.deepestLevel(); i++) {
      lines.push('  level ' + (i + 1) + ': ' + (this.levels[i] ? runText(this.levels[i]) : '-'));
    }
    return lines;
  };

  /* ================================================================== pair */

  /** Both structures side by side. `order` M for the tree; the LSM gets blocks of M-1 slots. */
  function Pair(opts) {
    this.opts = opts;   // {order, memtableEntries, l0Runs, growth}
    this.tree = new BPlus(opts.order);
    this.lsm = new Lsm({ blockEntries: opts.order - 1, indexFanout: opts.order,
                         memtableEntries: opts.memtableEntries, l0Runs: opts.l0Runs, growth: opts.growth });
    this.live = {};     // oracle: key -> value
  }
  var P = Pair.prototype;
  P.counters = function () {
    var t = this.tree.dev, l = this.lsm.dev;
    return { bt: { r: t.totalReads(), w: t.totalWrites(), blocks: t.live },
             lsm: { r: l.totalReads(), w: l.totalWrites(), blocks: l.live } };
  };
  /**
   * Applies one operation {kind: 'put'|'delete'|'get'|'scan', key, value, hi} to both
   * structures and returns a report: what each one read and wrote, the phases of
   * the LSM's maintenance with a snapshot at each, and the trace line the Zig and
   * Rust programs print for this operation.
   */
  P.apply = function (op) {
    var tree = this.tree, lsm = this.lsm, self = this;
    var t0 = this.counters(), ts = clone(tree.stats), th = tree.height, ls = clone(lsm.stats);
    var rep = { op: op, treeBefore: tree.snapshot(), lsmBefore: lsm.snapshot(), phases: [], answer: '', ok: true };
    tree.dev.takeLog();
    lsm.onPhase = function (name, info) {
      info.name = name; info.lsm = lsm.snapshot(); info.counters = self.counters().lsm;
      rep.phases.push(info);
    };
    var name, a, b;
    if (op.kind === 'put') {
      name = 'put ' + op.key;
      rep.old = tree.put(op.key, op.value); lsm.put(op.key, op.value);
      this.live[op.key] = op.value;
    } else if (op.kind === 'delete') {
      name = 'delete ' + op.key;
      rep.old = tree.delete(op.key); lsm.delete(op.key);
      delete this.live[op.key];
    } else if (op.kind === 'get') {
      name = 'get ' + op.key;
      rep.trail = [];
      a = tree.get(op.key); b = lsm.get(op.key, rep.trail);
      rep.value = a;
      rep.ok = a === b && a === (op.key in this.live ? this.live[op.key] : null);
      rep.answer = ' = ' + (a === null ? 'none' : a);
    } else {
      name = 'scan [' + op.key + ',' + op.hi + ')';
      rep.trail = [];
      a = tree.range(op.key, op.hi); b = lsm.range(op.key, op.hi, rep.trail);
      rep.keys = a.map(function (e) { return e.key; });
      rep.ok = JSON.stringify(a) === JSON.stringify(b);
      rep.answer = ' =' + rep.keys.map(function (k) { return ' ' + k; }).join('');
    }
    lsm.onPhase = null;
    rep.treeLog = tree.dev.takeLog();
    rep.treeAfter = tree.snapshot(); rep.lsmAfter = lsm.snapshot();
    var t1 = this.counters();
    rep.before = t0; rep.after = t1;
    rep.delta = { bt: { r: t1.bt.r - t0.bt.r, w: t1.bt.w - t0.bt.w }, lsm: { r: t1.lsm.r - t0.lsm.r, w: t1.lsm.w - t0.lsm.w } };
    var notes = [];
    if (tree.stats.leafSplits > ts.leafSplits) notes.push('btree: leaf split.');
    if (tree.stats.internalSplits > ts.internalSplits) notes.push('btree: internal split.');
    if (tree.height > th && th > 0) notes.push('btree: new root.');
    if (tree.stats.borrows > ts.borrows) notes.push('btree: borrow.');
    if (tree.stats.merges > ts.merges) notes.push('btree: merge.');
    if (lsm.stats.flushes > ls.flushes) notes.push('lsm: flush.');
    if (lsm.stats.l0Compactions > ls.l0Compactions) notes.push('lsm: compact level 0 into level 1.');
    if (lsm.stats.levelMerges > ls.levelMerges) notes.push('lsm: merge a level down.');
    rep.notes = notes;
    function pad(s, n, left) { s = String(s); while (s.length < n) s = left ? ' ' + s : s + ' '; return s; }
    rep.name = name;
    rep.line = pad(name, 12) + '| btree r=' + rep.delta.bt.r + ' w=' + rep.delta.bt.w +
      ' | lsm r=' + pad(rep.delta.lsm.r, 2, true) + ' w=' + pad(rep.delta.lsm.w, 2, true) + ' |' +
      rep.answer + notes.map(function (n) { return ' ' + n; }).join('');
    return rep;
  };
  /** Section 2 of the programs' output. */
  P.dumpText = function () {
    var t = this.tree, l = this.lsm, lines = [];
    lines.push('B+tree: height ' + t.height + ', ' + t.dev.live + ' blocks');
    lines = lines.concat(t.dumpLines());
    lines.push('LSM: ' + l.dev.live + ' blocks on the device holding ' + l.slotsOnDevice() + ' slots, ' +
               l.mem.length + ' key(s) in the memtable');
    lines = lines.concat(l.dumpLines());
    lines.push('totals: btree reads=' + t.dev.totalReads() + ' writes=' + t.dev.totalWrites() +
               ' | lsm reads=' + l.dev.totalReads() + ' writes=' + l.dev.totalWrites());
    lines.push('lsm compaction dropped ' + l.stats.versionsDropped + ' stale version(s) and ' +
               l.stats.tombstonesDropped + ' tombstone(s)');
    return lines.join('\n');
  };
  P.save = function () {
    return clone({ opts: this.opts, tree: this.tree, lsm: { cfg: this.lsm.cfg, dev: this.lsm.dev, mem: this.lsm.mem, l0: this.lsm.l0,
                   levels: this.lsm.levels, nextRun: this.lsm.nextRun, stats: this.lsm.stats, memWrites: this.lsm.memWrites }, live: this.live });
  };
  Pair.restore = function (saved) {
    var s = clone(saved), p = new Pair(s.opts), k;
    for (k in s.tree) if (k !== 'dev') p.tree[k] = s.tree[k];
    for (k in s.tree.dev) p.tree.dev[k] = s.tree.dev[k];
    for (k in s.lsm) if (k !== 'dev') p.lsm[k] = s.lsm[k];
    for (k in s.lsm.dev) p.lsm.dev[k] = s.lsm.dev[k];
    p.live = s.live;
    return p;
  };

  /** The fixed scenario of the programs (section 1 of expected_output.txt). */
  var TRACE = [];
  [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15].forEach(function (k) { TRACE.push({ kind: 'put', key: k, value: k * 100 }); });
  TRACE.push({ kind: 'get', key: 15 }, { kind: 'get', key: 12 }, { kind: 'get', key: 13 },
             { kind: 'delete', key: 15 }, { kind: 'put', key: 20, value: 2001 },
             { kind: 'put', key: 11, value: 1100 }, { kind: 'put', key: 13, value: 1300 }, { kind: 'put', key: 14, value: 1400 },
             { kind: 'get', key: 15 }, { kind: 'get', key: 20 }, { kind: 'scan', key: 5, hi: 14 });
  var TRACE_OPTS = { order: 4, memtableEntries: 4, l0Runs: 2, growth: 2 };

  /* ===================================================== buffered (Bε) node */

  /**
   * One internal node of a B-epsilon tree: pivots, child leaves, and a buffer of
   * pending messages. Textbook model (Brodal & Fagerberg; Bender et al.), not taken
   * from any of the guide's code bases.
   *
   *   put / delete   append a message to the buffer (the node is in RAM: no leaf I/O)
   *   buffer full    flush: pick the child with the most pending messages, read that
   *                  leaf once, apply all of its messages in arrival order, write it
   *   get            newest message for the key in the buffer wins; otherwise read the leaf
   *
   * `counters.plain*` is what a B+tree with the same root in RAM would have done:
   * one leaf read and one leaf write for every single put or delete.
   */
  function BufferedNode(opts) {
    this.pivots = opts.pivots.slice();                  // k pivots -> k + 1 leaves
    this.capacity = opts.capacity;                      // messages the buffer holds
    this.leaves = [];
    for (var i = 0; i <= this.pivots.length; i++) this.leaves.push([]);
    this.buffer = [];                                   // [{seq, kind: 'put'|'delete', key}] oldest first
    this.seq = 0;
    this.counters = { messages: 0, flushes: 0, leafReads: 0, leafWrites: 0, nodeWrites: 0,
                      queryReads: 0, plainReads: 0, plainWrites: 0, moved: 0 };
    var self = this;
    (opts.keys || []).forEach(function (k) { self._applyToLeaf(self.childOf(k), { kind: 'put', key: k }); });
  }
  var N = BufferedNode.prototype;
  N.childOf = function (key) { return upperBound(this.pivots, key); };
  N._applyToLeaf = function (c, msg) {
    var leaf = this.leaves[c], i = lowerBound(leaf, msg.key), there = i < leaf.length && leaf[i] === msg.key;
    if (msg.kind === 'put' && !there) leaf.splice(i, 0, msg.key);
    if (msg.kind === 'delete' && there) leaf.splice(i, 1);
  };
  N.pending = function () {
    var counts = this.leaves.map(function () { return 0; }), self = this;
    this.buffer.forEach(function (m) { counts[self.childOf(m.key)]++; });
    return counts;
  };
  /** The child a flush would pick: most pending messages, leftmost on a tie. */
  N.victim = function () {
    var counts = this.pending(), best = 0;
    for (var i = 1; i < counts.length; i++) if (counts[i] > counts[best]) best = i;
    return best;
  };
  /** Moves every pending message of child `c` into its leaf. Returns the messages moved. */
  N.flush = function (c) {
    var self = this, moved = [], keep = [];
    this.buffer.forEach(function (m) { (self.childOf(m.key) === c ? moved : keep).push(m); });
    if (!moved.length) return moved;
    moved.forEach(function (m) { self._applyToLeaf(c, m); });      // oldest first: the newest wins
    this.buffer = keep;
    this.counters.flushes++;
    this.counters.leafReads++; this.counters.leafWrites++; this.counters.nodeWrites++;
    this.counters.moved += moved.length;
    return moved;
  };
  /**
   * Accepts one message. Returns {flushed: null | {child, moved}, msg}. The flush
   * happens BEFORE the message is appended, and only when the buffer is full.
   */
  N.send = function (kind, key) {
    var flushed = null;
    if (this.buffer.length >= this.capacity) {
      var c = this.victim();
      flushed = { child: c, moved: this.flush(c) };
    }
    var msg = { seq: this.seq++, kind: kind, key: key };
    this.buffer.push(msg);
    this.counters.messages++;
    this.counters.plainReads++; this.counters.plainWrites++;
    return { flushed: flushed, msg: msg };
  };
  /** {present, from: 'buffer' | 'leaf', child}. Reading the leaf costs one block. */
  N.get = function (key) {
    for (var i = this.buffer.length - 1; i >= 0; i--) {
      if (this.buffer[i].key === key) return { present: this.buffer[i].kind === 'put', from: 'buffer', child: this.childOf(key), seq: this.buffer[i].seq };
    }
    var c = this.childOf(key), leaf = this.leaves[c], j = lowerBound(leaf, key);
    this.counters.queryReads++;
    return { present: j < leaf.length && leaf[j] === key, from: 'leaf', child: c };
  };
  N.snapshot = function () {
    return clone({ pivots: this.pivots, capacity: this.capacity, leaves: this.leaves, buffer: this.buffer,
                   pending: this.pending(), counters: this.counters });
  };
  N.save = function () { return clone({ pivots: this.pivots, capacity: this.capacity, leaves: this.leaves, buffer: this.buffer, seq: this.seq, counters: this.counters }); };
  BufferedNode.restore = function (saved) {
    var s = clone(saved), n = new BufferedNode({ pivots: s.pivots, capacity: s.capacity });
    n.leaves = s.leaves; n.buffer = s.buffer; n.seq = s.seq; n.counters = s.counters;
    return n;
  };

  root.Ch27 = {
    Device: Device, BPlus: BPlus, Lsm: Lsm, Pair: Pair, BufferedNode: BufferedNode,
    TRACE: TRACE, TRACE_OPTS: TRACE_OPTS, lowerBound: lowerBound, upperBound: upperBound, clone: clone
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = root.Ch27;
})(typeof window !== 'undefined' ? window : globalThis);

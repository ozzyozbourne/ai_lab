/* Chapter 26 models, ported line by line from zig/src/slab.zig, btree.zig and buddy.zig.
 * Classic script: defines window.Ch26 = { Pool, Tree, Buddy }.
 * Every operation returns an array of BTViz steps ({caption, state, highlight, log}). */
(function () {
  'use strict';

  /* ---------------------------------------------------------------- handles
   * A handle is kept as {c, slab, slot}; its text form is "L0.3" / "I1.0". */
  function hName(h) { return h ? (h.c ? 'I' : 'L') + h.slab + '.' + h.slot : 'none'; }
  function hInt(h) { return ((h.c << 31) | (h.slab << 8) | h.slot) >>> 0; }
  function hHex(h) { return '0x' + ('00000000' + hInt(h).toString(16)).slice(-8); }
  function same(a, b) { return a && b && a.c === b.c && a.slab === b.slab && a.slot === b.slot; }

  /* ---------------------------------------------------------------- slab pool */
  function Pool(cls, slots) {
    this.c = cls; this.S = slots;
    this.slabs = [];          // id -> null | {used, free: [bool], items: [node]}
    this.slabCount = 0; this.live = 0; this.hint = 0; this.victim = null;
    this.nextBase = 0;        // only for the "pointer" column of the page: fake addresses
    this.releaseEmpty = true; // false: static policy, an empty slab is kept (TigerBeetle NodePool style)
    this.budget = Infinity;   // slabs the backing allocator will still hand out; 0 once frozen
    this.growFailures = 0;    // creates that failed because the backing allocator refused
    this.backingAllocs = 0; this.backingFrees = 0;   // calls that reached the backing allocator
  }
  Pool.prototype.freeSlots = function () { return this.slabCount * this.S - this.live; };
  Pool.prototype.hasSpace = function (id) {
    return this.victim !== id && this.slabs[id] && this.slabs[id].used < this.S;
  };
  /** -1 when the backing allocator refuses (the Zig version returns error.OutOfMemory). */
  Pool.prototype.addSlab = function () {
    if (this.budget === 0) return -1;
    this.budget--; this.backingAllocs++;
    var id = this.slabs.indexOf(null);
    if (id < 0) { id = this.slabs.length; this.slabs.push(null); }
    var free = [], items = [];
    for (var i = 0; i < this.S; i++) { free.push(true); items.push(null); }
    this.slabs[id] = { used: 0, free: free, items: items, base: (this.c ? 0x7a00 : 0x5500) + 0x40 * this.nextBase++ };
    this.slabCount++;
    this.hint = Math.min(this.hint, id);
    return id;
  };
  /** Static policy, init phase: size the directory once (one allocation), then create
   *  every slab. Nothing is freed on the way: a free would end the init phase. */
  Pool.prototype.reserve = function (count) {
    if (count > this.slabCount && !this.directorySized) { this.directorySized = true; this.backingAllocs++; }
    while (this.slabCount < count) if (this.addSlab() < 0) return false;
    return true;
  };
  /** Lowest free slot of the lowest slab that has one. `grew` reports a new slab.
   *  Returns null when every slab is full and no new slab can be had. */
  Pool.prototype.create = function (value) {
    var id = this.hint, grew = false;
    while (id < this.slabs.length && !this.hasSpace(id)) id++;
    if (id === this.slabs.length) {
      id = this.addSlab(); grew = true;
      if (id < 0) { this.growFailures++; return null; }
    }
    if (this.victim === null) this.hint = id;
    var slab = this.slabs[id], slot = slab.free.indexOf(true);
    slab.free[slot] = false; slab.items[slot] = value; slab.used++; this.live++;
    this.lastGrew = grew;
    return { c: this.c, slab: id, slot: slot };
  };
  /** What create() would return, without doing it (for the "predict" question). */
  Pool.prototype.peek = function () {
    var id = this.hint;
    while (id < this.slabs.length && !this.hasSpace(id)) id++;
    if (id === this.slabs.length) { var n = this.slabs.indexOf(null); return { c: this.c, slab: n < 0 ? id : n, slot: 0, grew: true, full: this.budget === 0 }; }
    return { c: this.c, slab: id, slot: this.slabs[id].free.indexOf(true), grew: false };
  };
  Pool.prototype.isLive = function (h) {
    var slab = h && h.c === this.c ? this.slabs[h.slab] : null;
    return !!slab && h.slot < this.S && !slab.free[h.slot];
  };
  Pool.prototype.get = function (h) {
    if (!this.isLive(h)) throw new Error('stale handle ' + hName(h));
    return this.slabs[h.slab].items[h.slot];
  };
  /** Returns true when the slab was released. */
  Pool.prototype.destroy = function (h) {
    if (!this.isLive(h)) throw new Error('stale handle ' + hName(h));
    var slab = this.slabs[h.slab];
    slab.free[h.slot] = true; slab.items[h.slot] = null; slab.used--; this.live--;
    if (this.victim !== h.slab) this.hint = Math.min(this.hint, h.slab);
    if (slab.used !== 0 || !this.releaseEmpty) return false;
    var other = this.victim === h.slab;
    for (var id = 0; id < this.slabs.length && !other; id++) other = id !== h.slab && this.hasSpace(id);
    if (!other) return false;           // the only free space left: keep it
    this.slabs[h.slab] = null; this.slabCount--; this.backingFrees++;
    return true;
  };
  Pool.prototype.vacuumBegin = function () {
    if (this.slabCount < 2 || this.freeSlots() < this.S) return false;
    var best = null;
    for (var id = 0; id < this.slabs.length; id++) {
      if (this.slabs[id] && (best === null || this.slabs[id].used <= this.slabs[best].used)) best = id;
    }
    this.victim = best; this.hint = 0;
    return true;
  };
  Pool.prototype.isVictim = function (h) { return this.victim !== null && this.victim === h.slab; };
  Pool.prototype.relocate = function (old) {
    var value = this.get(old), fresh = this.create(value);
    this.destroy(old);
    return fresh;
  };
  Pool.prototype.vacuumEnd = function () {
    var id = this.victim;
    if (this.slabs[id]) { this.slabs[id] = null; this.slabCount--; this.backingFrees++; }
    this.victim = null; this.hint = 0;
  };
  /** Same text as SlabPool.writeMap in the programs: "0[##.#] 1[released]". */
  Pool.prototype.map = function () {
    if (!this.slabs.length) return '(no slabs)';
    return this.slabs.map(function (slab, id) {
      return id + '[' + (slab ? slab.free.map(function (f) { return f ? '.' : '#'; }).join('') : 'released') + ']';
    }).join(' ');
  };
  /** MemoryMap model. `marks` maps handle names to highlight states. */
  Pool.prototype.view = function (marks) {
    var self = this, kind = this.c ? 'interior' : 'leaf', out = [];
    this.slabs.forEach(function (slab, id) {
      if (!slab) { out.push({ label: kind + ' slab ' + id + ' · released', slots: [] }); return; }
      out.push({
        label: kind + ' slab ' + id + (self.victim === id ? ' · VICTIM' : '') + ' · ' + slab.used + '/' + self.S + ' used',
        slots: slab.free.map(function (free, slot) {
          var name = (self.c ? 'I' : 'L') + id + '.' + slot;
          var state = (marks && marks[name]) || (free ? 'free' : self.victim === id ? 'merge' : 'used');
          return { state: state, label: slot, title: name + ': ' + (free ? 'free (bit = 1)' : 'used (bit = 0)') };
        })
      });
    });
    if (!out.length) out.push({ label: kind + ' pool · no slabs yet', slots: [] });
    return { slabs: out };
  };

  /* ---------------------------------------------------------------- B-tree on two pools
   * Top-down split / CLRS delete, order M (even). Node = {uid, keys: [], kids: [handle]}. */
  function Tree(M, slots, opts) {
    this.M = M; this.t = M / 2; this.K = M - 1;
    this.leaves = new Pool(0, slots); this.interiors = new Pool(1, slots);
    // Static policy (section 4 of the programs): the pools never release a slab, and
    // `phase` is the state of the StaticAllocator wrapper above the backing allocator.
    this.isStatic = !!(opts && opts.static);
    this.phase = 'init';
    if (this.isStatic) { this.leaves.releaseEmpty = false; this.interiors.releaseEmpty = false; }
    this.root = null; this.height = 0; this.count = 0; this.uid = 0;
    this.rec = null;         // step recorder while an operation runs
  }
  var T = Tree.prototype;
  T.pool = function (h) { return h.c ? this.interiors : this.leaves; };
  T.node = function (h) { return this.pool(h).get(h); };
  T.newNode = function (leaf) {
    return (leaf ? this.leaves : this.interiors).create({ uid: 'n' + this.uid++, keys: [], kids: [] });
  };
  /** What the page shows about the memory policy at this step. */
  T.policy = function () {
    var l = this.leaves, n = this.interiors;
    return { static: this.isStatic, phase: this.isStatic ? this.phase : 'growing',
      leafSlabs: l.slabCount, intSlabs: n.slabCount, slots: l.slabCount * l.S + n.slabCount * n.S, live: l.live + n.live,
      allocs: l.backingAllocs + n.backingAllocs, frees: l.backingFrees + n.backingFrees, refused: l.growFailures + n.growFailures };
  };
  T.freeNode = function (h) { return this.pool(h).destroy(h); };
  function lowerBound(keys, key) { var i = 0; while (i < keys.length && keys[i] < key) i++; return i; }

  /* ---- snapshots and steps */
  T.snapshot = function () {
    var self = this;
    function walk(h) {
      var n = self.node(h);
      return { id: n.uid, keys: n.keys.slice(), leaf: !h.c, meta: { label: hName(h) },
               children: h.c ? n.kids.map(walk) : [] };
    }
    return this.root ? walk(this.root) : null;
  };
  /** All keys in ascending order. */
  T.keys = function () {
    var self = this, out = [];
    (function walk(h) {
      var n = self.node(h);
      n.keys.forEach(function (k, i) { if (h.c) walk(n.kids[i]); out.push(k); });
      if (h.c) walk(n.kids[n.keys.length]);
    })(this.root || { c: 0, slab: -1, slot: 0 });
    return out;
  };
  T.has = function (key) { return this.keys().indexOf(key) >= 0; };
  /** Text dump identical to BTree.dump in the programs. */
  T.dump = function () {
    var self = this, out = [];
    function walk(h, depth) {
      var n = self.node(h);
      out.push(new Array(depth * 2 + 1).join(' ') + hName(h) + ' [' + n.keys.join(' ') + ']');
      if (h.c) n.kids.forEach(function (k) { walk(k, depth + 1); });
    }
    if (!this.root) return '(empty)\n';
    walk(this.root, 0);
    return out.join('\n') + '\n';
  };
  /** Record one step. opts: {nodes, keys, slots, focus, cursor, log, type, hold} */
  T.step = function (caption, opts) {
    if (!this.rec) return null;
    opts = opts || {};
    var self = this, nodes = {}, focus = opts.focus || null;
    Object.keys(opts.nodes || {}).forEach(function (name) {       // handle name -> uid
      var h = opts.nodes[name].h;
      if (self.pool(h).isLive(h)) nodes[self.node(h).uid] = opts.nodes[name].state;
    });
    var step = {
      caption: caption, type: opts.type || 'info', log: opts.log, hold: opts.hold,
      state: {
        tree: this.snapshot(),
        leaves: this.leaves.view(opts.slots), interiors: this.interiors.view(opts.slots),
        focus: focus ? { name: hName(focus), hex: hHex(focus), c: focus.c, slab: focus.slab, slot: focus.slot,
                         addr: this.pool(focus).slabs[focus.slab] ? this.pool(focus).slabs[focus.slab].base * 0x100 + 16 + focus.slot * (focus.c ? 72 : 56) : null,
                         moved: opts.movedFrom || null } : null,
        stats: { keys: this.count, height: this.height, leafMap: this.leaves.map(), intMap: this.interiors.map() },
        policy: this.policy()
      },
      highlight: { nodes: nodes, keys: opts.keys || {}, cursor: opts.cursor }
    };
    this.rec.push(step);
    return step;
  };
  function mark(h, state) { var o = {}; o[hName(h)] = { h: h, state: state }; return o; }
  function slotMark(h, state) { var o = {}; o[hName(h)] = state; return o; }
  function kk(v, s) { return '<b class="bt-k' + (s ? ' s-' + s : '') + '">' + v + '</b>'; }
  function hh(h) { return '<code>' + hName(h) + '</code>'; }

  T.run = function (fn) {
    this.rec = [];
    var result = fn.call(this), steps = this.rec;
    this.rec = null;
    steps.result = result;
    return steps;
  };
  T.idle = function (caption) {
    var self = this;
    return this.run(function () { self.step(caption, { type: 'idle' }); });
  };

  /* ---- static memory: reserve everything in init, then freeze (section 4 of the programs) */
  T.reserveAndFreeze = function (leafSlabs, intSlabs) {
    return this.run(function () {
      var S = this.leaves.S;
      this.step('<b>Static memory, phase init.</b> The tree is empty and owns no memory yet. While the allocator wrapper is in state <b>init</b>, requests pass through to the backing allocator. The plan: take everything the tree will ever need now.',
        { type: 'init', hold: 2 });
      this.leaves.reserve(leafSlabs);
      this.step('<code>leaves.reserve(' + leafSlabs + ')</code>: the slab directory is sized once for ' + leafSlabs + ' entries, then ' + leafSlabs + ' slabs of ' + S + ' leaf slots are created. Every slot is free (hatched). ' +
        this.leaves.backingAllocs + ' allocations, no free: a free during init would end the init phase.',
        { type: 'reserve', hold: 2, log: { html: 'reserve ' + leafSlabs + ' leaf slabs', state: 'inserted' } });
      this.interiors.reserve(intSlabs);
      this.step('<code>interiors.reserve(' + intSlabs + ')</code>: ' + intSlabs + ' slabs of ' + S + ' interior slots. The tree still holds no key, but all of its memory exists: ' +
        leafSlabs * S + ' leaf slots and ' + intSlabs * S + ' interior slots.',
        { type: 'reserve', hold: 2, log: { html: 'reserve ' + intSlabs + ' interior slabs', state: 'inserted' } });
      this.phase = 'static'; this.leaves.budget = 0; this.interiors.budget = 0;
      this.step('<code>freeze()</code>: init &rarr; <b>static</b>. From here on the backing allocator refuses every request, so the footprint of ' + (leafSlabs + intSlabs) +
        ' slabs can neither grow nor shrink, and a hidden allocation anywhere in the code would be caught. Inserts now only flip bits in these slabs. Press <b>Put</b>, or <b>Fill</b> to insert keys until the pool is dry.',
        { type: 'freeze', hold: 2, log: { html: 'freeze: init → static', state: 'lock-exclusive' } });
    });
  };

  /* ---- allocation with a step (and a predict question) */
  T.allocStep = function (leaf, why) {
    var pool = leaf ? this.leaves : this.interiors, guess = pool.peek();
    var wrong = [];
    pool.slabs.forEach(function (slab, id) {
      if (!slab) return;
      slab.free.forEach(function (f, slot) { if (f && !(id === guess.slab && slot === guess.slot) && wrong.length < 2) wrong.push({ c: pool.c, slab: id, slot: slot }); });
    });
    var h = this.newNode(leaf);
    if (!h) {
      // Only reachable under the static policy: the pool may not grow any more.
      var fail = this.step(why + ' Allocate ' + (leaf ? 'a leaf' : 'an interior node') + ': all ' + pool.slabCount * pool.S + ' slots of the ' + (leaf ? 'leaf' : 'interior') +
        ' pool are in use, so <code>create</code> asks the backing allocator for one more slab. The allocator is frozen (state <b>static</b>) and <b>refuses</b>: <code>create</code> returns OutOfMemory.',
        { type: 'refused', log: { html: 'create ' + (leaf ? 'leaf' : 'interior') + ': refused (frozen)', state: 'deleted' } });
      if (fail) fail.question = { prompt: 'A new ' + (leaf ? 'leaf' : 'interior node') + ' is needed, and the allocator was frozen after init. What does <code>create</code> return?',
        choices: ['a slot in a new slab', 'OutOfMemory: the pool is full and may not grow'], answer: 1,
        explain: 'After freeze() the backing allocator refuses every request, so the memory footprint cannot change.' };
      return null;
    }
    var grew = pool.lastGrew;
    var step = this.step(why + ' Allocate a ' + (leaf ? 'leaf' : 'interior node') + ': ' +
      (grew ? 'every slab is full, so a new slab ' + h.slab + ' is taken from the backing allocator, and its first slot is used.'
            : 'the lowest slab with a free slot is slab ' + h.slab + ', its lowest set bit is slot ' + h.slot + '. The bit is cleared.') +
      ' The new node is ' + hh(h) + ' = ' + hHex(h) + '.',
      { type: 'alloc', slots: slotMark(h, 'inserted'), focus: h, log: { html: 'create ' + hName(h) + (grew ? ' (new slab)' : ''), state: 'inserted' } });
    if (step) {
      var choices = [hName(h)], answer = 0;
      wrong.forEach(function (w) { choices.push(hName(w)); });
      choices.push(grew ? 'none: the pool is full, OutOfMemory' : 'a slot in a new slab');
      if (choices.length > 1) {
        // Fixed, order-independent shuffle so the right answer is not always first.
        answer = (h.slab + h.slot + choices.length) % choices.length;
        var tmp = choices[answer]; choices[answer] = choices[0]; choices[0] = tmp;
        step.question = { prompt: 'A new ' + (leaf ? 'leaf' : 'interior node') + ' is needed. Which handle will <code>create</code> return?',
          choices: choices, answer: answer, explain: 'Always the lowest slab that has a free slot, and the lowest free slot in it.' };
      }
    }
    return h;
  };

  /* ---- put */
  T.splitChild = function (parent, i) {
    var t = this.t, leftH = this.node(parent).kids[i], left = this.node(leftH);
    // Allocate the sibling BEFORE touching a key: if this fails, nothing is half-done.
    var rightH = this.allocStep(!leftH.c, 'Child ' + hh(leftH) + ' is full (' + this.K + ' keys), so it is split before the search enters it.');
    if (!rightH) return false;
    var right = this.node(rightH), p = this.node(parent);
    var median = left.keys[t - 1];
    right.keys = left.keys.slice(t);
    if (leftH.c) { right.kids = left.kids.slice(t); left.kids = left.kids.slice(0, t); }
    left.keys = left.keys.slice(0, t - 1);
    p.kids.splice(i + 1, 0, rightH);
    p.keys.splice(i, 0, median);
    var nodes = mark(leftH, 'split'); nodes[hName(rightH)] = { h: rightH, state: 'split' };
    var keys = {}; keys[p.uid + ':' + median] = 'split';
    this.step('The upper half moves to ' + hh(rightH) + ', the median ' + kk(median, 'split') + ' goes up into ' + hh(parent) +
      ', and the parent stores the new 4-byte handle next to the old one.',
      { type: 'split', nodes: nodes, keys: keys, focus: rightH, log: { html: 'split ' + hName(leftH) + ' → + ' + hName(rightH), state: 'split' } });
    return true;
  };
  /** The last step of a put that ran out of memory. Result of the operation: 'oom'. */
  T.oomStep = function (key) {
    this.step('<b>OutOfMemory</b>: ' + kk(key) + ' was not inserted. Nothing is half-done, because every split allocates its new node before it moves a key: the tree is valid and holds the same ' +
      this.count + ' keys. The footprint is still ' + this.leaves.slabCount + ' leaf and ' + this.interiors.slabCount + ' interior slabs. Delete a key to free a slot, or press Reset.',
      { type: 'oom', log: { html: 'put ' + key + ': OutOfMemory', state: 'deleted' } });
    return 'oom';
  };
  T.put = function (key) {
    return this.run(function () {
      if (!this.root) {
        var first = this.allocStep(true, 'The tree is empty.');
        if (!first) return this.oomStep(key);
        this.root = first;
        this.height = 1;
      }
      this.step('Insert ' + kk(key, 'inserted') + '. Top-down insertion: every full node on the path is split <i>before</i> it is entered, so each allocation happens before anything is changed.',
        { type: 'start', nodes: mark(this.root, 'active'), cursor: { node: this.node(this.root).uid, label: key } });
      if (this.node(this.root).keys.length === this.K) {
        var oldRoot = this.root;
        var newRoot = this.allocStep(false, 'The root ' + hh(this.root) + ' is full: the tree grows by one level.');
        if (!newRoot) return this.oomStep(key);
        this.node(newRoot).kids = [this.root];
        this.root = newRoot; this.height++;
        if (!this.splitChild(newRoot, 0)) {
          // Zig: `errdefer tree.freeNode(new_root)`. The half-built level is undone.
          this.root = oldRoot; this.height--;
          this.freeStep(newRoot, 'The new root was allocated, but the sibling for the split was refused, so the new root is given back (<code>errdefer</code>).');
          return this.oomStep(key);
        }
      }
      var h = this.root;
      for (;;) {
        var n = this.node(h), i = lowerBound(n.keys, key), keys = {};
        if (i < n.keys.length && n.keys[i] === key) {
          keys[n.uid + ':' + key] = 'found';
          this.step('Key ' + kk(key, 'found') + ' is already in ' + hh(h) + ': only its value is overwritten. No allocation.', { type: 'exists', nodes: mark(h, 'active'), keys: keys, focus: h });
          return false;
        }
        if (!h.c) {
          n.keys.splice(i, 0, key); this.count++;
          keys[n.uid + ':' + key] = 'inserted';
          this.step('Leaf ' + hh(h) + ' has room: ' + kk(key, 'inserted') + ' is written into it. Done: ' + this.count + ' keys, ' +
            this.leaves.live + ' leaves and ' + this.interiors.live + ' interior nodes.', { type: 'done', nodes: mark(h, 'active'), keys: keys, focus: h, log: { html: 'put ' + key + ' into ' + hName(h), state: 'inserted' } });
          return true;
        }
        var child = n.kids[i];
        if (this.node(child).keys.length === this.K) {
          if (!this.splitChild(h, i)) return this.oomStep(key);
          n = this.node(h);
          if (key === n.keys[i]) { keys[n.uid + ':' + key] = 'found'; this.step('The median that came up is the key itself: overwrite its value.', { type: 'exists', nodes: mark(h, 'active'), keys: keys, focus: h }); return false; }
          if (key > n.keys[i]) child = n.kids[i + 1];
        }
        this.step('In ' + hh(h) + ' the key belongs to child ' + (n.kids.indexOf(child)) + '. Follow the handle ' + hh(child) + ': slab directory entry ' + child.slab + ', then slot ' + child.slot + '.',
          { type: 'descend', nodes: mark(child, 'active'), cursor: { node: this.node(child).uid, label: key }, focus: child, slots: slotMark(child, 'active') });
        h = child;
      }
    });
  };

  /* ---- delete */
  T.freeStep = function (h, why) {
    var name = hName(h), released = this.freeNode(h);
    var marks = {}; marks[name] = 'deleted';
    this.step(why + ' Slot ' + '<code>' + name + '</code> is freed: its bit is set to 1. ' +
      (released ? 'That was the last node of slab ' + h.slab + ' and another slab still has room, so the whole slab goes back to the backing allocator.'
                : (this.isStatic ? 'The slot goes back to the <i>pool</i>, never to the allocator: a static pool keeps every slab, so the footprint does not shrink either.'
                : this.pool(h).slabs[h.slab].used === 0 ? 'The slab is now empty, but it is the only free space of the pool, so it is kept.'
                                                         : 'A hole: the next <code>create</code> that reaches this slab will reuse it.')),
      { type: 'free', slots: released ? {} : marks, log: { html: 'destroy ' + name + (released ? ' (slab released)' : ''), state: 'deleted' } });
  };
  T.merge = function (parent, i) {
    var p = this.node(parent), leftH = p.kids[i], rightH = p.kids[i + 1];
    var left = this.node(leftH), right = this.node(rightH), sep = p.keys[i];
    var nodes = mark(leftH, 'merge'); nodes[hName(rightH)] = { h: rightH, state: 'merge' };
    this.step('Both ' + hh(leftH) + ' and ' + hh(rightH) + ' are at the minimum, so nothing can be borrowed: they merge around the separator ' + kk(sep, 'merge') + '.',
      { type: 'merge', nodes: nodes, focus: rightH });
    left.keys = left.keys.concat([sep], right.keys);
    if (leftH.c) left.kids = left.kids.concat(right.kids);
    p.kids.splice(i + 1, 1); p.keys.splice(i, 1);
    this.freeStep(rightH, 'Everything now lives in ' + hh(leftH) + '.');
  };
  T.borrowLeft = function (parent, c) {
    var p = this.node(parent), leftH = p.kids[c - 1], childH = p.kids[c], left = this.node(leftH), child = this.node(childH);
    if (childH.c) child.kids.unshift(left.kids.pop());
    child.keys.unshift(p.keys[c - 1]);
    p.keys[c - 1] = left.keys.pop();
    var nodes = mark(leftH, 'merge'); nodes[hName(childH)] = { h: childH, state: 'active' };
    this.step('Child ' + hh(childH) + ' was at the minimum; its left sibling ' + hh(leftH) + ' can spare a key. Rotate right through the parent. No slot is allocated or freed.', { type: 'borrow', nodes: nodes });
  };
  T.borrowRight = function (parent, c) {
    var p = this.node(parent), childH = p.kids[c], rightH = p.kids[c + 1], child = this.node(childH), right = this.node(rightH);
    if (childH.c) child.kids.push(right.kids.shift());
    child.keys.push(p.keys[c]);
    p.keys[c] = right.keys.shift();
    var nodes = mark(rightH, 'merge'); nodes[hName(childH)] = { h: childH, state: 'active' };
    this.step('Child ' + hh(childH) + ' was at the minimum; its right sibling ' + hh(rightH) + ' can spare a key. Rotate left through the parent. No slot is allocated or freed.', { type: 'borrow', nodes: nodes });
  };
  T.edge = function (h, min) {
    while (h.c) { var n = this.node(h); h = n.kids[min ? 0 : n.keys.length]; }
    var leaf = this.node(h);
    return leaf.keys[min ? 0 : leaf.keys.length - 1];
  };
  T.deleteFrom = function (h, key) {
    var t = this.t, n = this.node(h), i = lowerBound(n.keys, key), found = i < n.keys.length && n.keys[i] === key, keys = {};
    if (!h.c) {
      if (found) {
        keys[n.uid + ':' + key] = 'deleted';
        this.step('Key ' + kk(key, 'deleted') + ' is in leaf ' + hh(h) + ', which can lose a key without underflow.', { type: 'remove', nodes: mark(h, 'active'), keys: keys, focus: h });
        n.keys.splice(i, 1);
      } else {
        this.step('Leaf ' + hh(h) + ' does not contain ' + kk(key) + ': nothing to delete.', { type: 'not-found', nodes: mark(h, 'active'), focus: h });
      }
      return found;
    }
    if (found) {
      keys[n.uid + ':' + key] = 'deleted';
      if (this.node(n.kids[i]).keys.length >= t) {
        var pred = this.edge(n.kids[i], false);
        this.step('Key ' + kk(key, 'deleted') + ' is in interior node ' + hh(h) + '. Replace it by its predecessor ' + kk(pred, 'compare') + ' and delete that from the left subtree.', { type: 'replace', nodes: mark(h, 'active'), keys: keys, focus: h });
        n.keys[i] = pred;
        return this.deleteFrom(n.kids[i], pred);
      }
      if (this.node(n.kids[i + 1]).keys.length >= t) {
        var succ = this.edge(n.kids[i + 1], true);
        this.step('Key ' + kk(key, 'deleted') + ' is in interior node ' + hh(h) + '. The left child is minimal, so replace it by its successor ' + kk(succ, 'compare') + ' and delete that from the right subtree.', { type: 'replace', nodes: mark(h, 'active'), keys: keys, focus: h });
        n.keys[i] = succ;
        return this.deleteFrom(n.kids[i + 1], succ);
      }
      var target = n.kids[i];
      this.merge(h, i);
      return this.deleteFrom(target, key);
    }
    var c = i, kids = n.kids;
    if (this.node(kids[c]).keys.length === t - 1) {
      if (c > 0 && this.node(kids[c - 1]).keys.length >= t) this.borrowLeft(h, c);
      else if (c < n.keys.length && this.node(kids[c + 1]).keys.length >= t) this.borrowRight(h, c);
      else if (c < n.keys.length) this.merge(h, c);
      else { this.merge(h, c - 1); c -= 1; }
    }
    var next = this.node(h).kids[c];
    this.step('Descend from ' + hh(h) + ' into ' + hh(next) + ', which now holds at least ' + t + ' keys or is about to be searched as a leaf.', { type: 'descend', nodes: mark(next, 'active'), cursor: { node: this.node(next).uid, label: key }, focus: next, slots: slotMark(next, 'active') });
    return this.deleteFrom(next, key);
  };
  T.delete = function (key) {
    return this.run(function () {
      if (!this.root) { this.step('The tree is empty.', { type: 'not-found' }); return false; }
      this.step('Delete ' + kk(key, 'deleted') + '. Top-down deletion: before entering a child, make sure it has a key to spare (borrow or merge). Deleting never allocates.',
        { type: 'start', nodes: mark(this.root, 'active'), cursor: { node: this.node(this.root).uid, label: key } });
      var removed = this.deleteFrom(this.root, key);
      if (removed) this.count--;
      if (this.node(this.root).keys.length === 0) {
        var old = this.root;
        this.root = old.c ? this.node(old).kids[0] : null;
        this.height--;
        this.freeStep(old, 'The root has no keys left' + (this.root ? ', so its only child ' + hh(this.root) + ' becomes the root.' : ': the tree is empty.'));
      }
      this.step((removed ? 'Deleted ' + kk(key) + '. ' : 'Key ' + kk(key) + ' was not present. ') + this.count + ' keys in ' + this.leaves.live + ' leaves and ' + this.interiors.live +
        ' interior nodes; free slots: ' + this.leaves.freeSlots() + ' leaf, ' + this.interiors.freeSlots() + ' interior.', { type: 'done', log: removed ? { html: 'delete ' + key, state: 'deleted' } : undefined });
      return removed;
    });
  };

  /* ---- vacuum */
  T.vacuum = function () {
    return this.run(function () {
      var self = this, moved = 0, S = this.leaves.S;
      function begin(pool, kind) {
        var free = pool.freeSlots(), ok = pool.vacuumBegin();
        self.step('<b>Vacuum, ' + kind + ' pool.</b> ' + free + ' free slot' + (free === 1 ? '' : 's') + ' in ' + pool.slabCount + ' slab' + (pool.slabCount === 1 ? '' : 's') + '. ' +
          (ok ? 'That is at least one whole slab (' + S + ' slots), so the emptiest slab, slab ' + pool.victim + ', becomes the victim. <code>create</code> will not allocate from it any more.'
              : 'Less than one whole slab (' + S + ' slots) could be saved' + (pool.slabCount < 2 ? ' (there is only one slab)' : '') + ': nothing to do.'),
          { type: ok ? 'victim' : 'no-victim', hold: 2, log: ok ? { html: kind + ' victim: slab ' + pool.victim, state: 'merge' } : undefined });
        return ok;
      }
      var lv = begin(this.leaves, 'leaf'), iv = begin(this.interiors, 'interior');
      function move(h, parentH, store) {
        var pool = self.pool(h);
        if (!pool.isVictim(h)) return h;
        var fresh = pool.relocate(h), released = !pool.slabs[h.slab];
        store(fresh);                 // rewrite the one handle that named the node
        moved++;
        self.step('Node ' + hh(h) + ' lives in the victim slab. Copy it to ' + hh(fresh) + ' (lowest free slot elsewhere) and rewrite the <b>one</b> handle that refers to it, in ' +
          (parentH ? hh(parentH) : 'the tree\'s <code>root</code> field') + '. ' + (released ? 'The victim slab is now empty and is released.' : ''),
          { type: 'relocate', nodes: mark(fresh, 'inserted'), slots: slotMark(fresh, 'inserted'), focus: fresh, movedFrom: hName(h),
            log: { html: 'move ' + hName(h) + ' → ' + hName(fresh), state: 'inserted' } });
        return fresh;
      }
      function walk(h) {
        if (!h.c) return;
        var n = self.node(h);
        n.kids.forEach(function (kid, i) { walk(move(kid, h, function (fresh) { n.kids[i] = fresh; })); });
      }
      if (this.root) walk(move(this.root, null, function (fresh) { self.root = fresh; }));
      if (lv) this.leaves.vacuumEnd();
      if (iv) this.interiors.vacuumEnd();
      this.step('Vacuum pass finished: ' + moved + ' node' + (moved === 1 ? '' : 's') + ' moved. Slabs now: ' + this.leaves.slabCount + ' leaf, ' + this.interiors.slabCount +
        ' interior. ' + (moved ? 'Run it again to evacuate the next slab.' : 'The pools are as dense as one-slab-at-a-time vacuum can make them.'), { type: 'done' });
      return moved;
    });
  };

  /* ---------------------------------------------------------------- buddy allocator */
  function Buddy(heapLog2, minLog2) {
    this.minBlock = 1 << minLog2; this.maxOrder = heapLog2 - minLog2; this.heap = 1 << heapLog2;
    var n = 1 << this.maxOrder;
    this.state = []; this.order = []; this.name = [];
    for (var i = 0; i < n; i++) { this.state.push('inside'); this.order.push(0); this.name.push(null); }
    this.lists = [];                       // per order: block numbers, most recently freed first
    for (var k = 0; k <= this.maxOrder; k++) this.lists.push([]);
    this.requested = 0; this.granted = 0; this.lens = {};
    this.pushFree(0, this.maxOrder);
    this.rec = null;
  }
  var B = Buddy.prototype;
  B.size = function (k) { return this.minBlock << k; };
  B.pushFree = function (block, k) { this.state[block] = 'free'; this.order[block] = k; this.name[block] = null; this.lists[k].unshift(block); };
  B.unlink = function (block) { var l = this.lists[this.order[block]]; l.splice(l.indexOf(block), 1); };
  B.orderFor = function (len) {
    var want = Math.max(len, this.minBlock), k = 0;
    if (want > this.heap) return null;
    while (this.size(k) < want) k++;
    return k;
  };
  B.freeBytes = function () { var self = this; return this.lists.reduce(function (sum, l, k) { return sum + l.length * self.size(k); }, 0); };
  B.largestFree = function () { for (var k = this.maxOrder; k >= 0; k--) if (this.lists[k].length) return this.size(k); return 0; };
  /** Same text as writeMap in the programs: "[128 used][128 free]". */
  B.map = function () {
    var out = '', block = 0;
    while (block < this.state.length) { out += '[' + this.size(this.order[block]) + ' ' + (this.state[block] === 'free' ? 'free' : 'used') + ']'; block += 1 << this.order[block]; }
    return out;
  };
  B.blocks = function (marks) {
    var out = [], block = 0;
    while (block < this.state.length) {
      var k = this.order[block];
      out.push({ id: 'b' + block + 'k' + k, block: block, order: k, size: this.size(k), free: this.state[block] === 'free', name: this.name[block],
                 len: this.lens[block], state: (marks && marks[block]) || null });
      block += 1 << k;
    }
    return out;
  };
  B.step = function (caption, marks, extra) {
    if (!this.rec) return;
    var self = this;
    var step = { caption: caption, state: { blocks: this.blocks(marks), lists: this.lists.map(function (l, k) { return { order: k, size: self.size(k), blocks: l.slice() }; }),
      stats: { requested: this.requested, granted: this.granted, free: this.freeBytes(), largest: this.largestFree() } } };
    for (var key in (extra || {})) step[key] = extra[key];
    this.rec.push(step);
    return step;
  };
  B.run = function (fn) { this.rec = []; var r = fn.call(this), steps = this.rec; this.rec = null; steps.result = r; return steps; };
  B.idle = function (caption) { return this.run(function () { this.step(caption); }); };
  B.alloc = function (len, name) {
    return this.run(function () {
      var k = this.orderFor(len), m = {};
      if (k === null) { this.step('A request for ' + len + ' bytes is larger than the heap: OutOfMemory.', null, { log: { html: 'alloc ' + len + ': OutOfMemory', state: 'deleted' } }); return null; }
      var first = this.step('Request <b>' + name + '</b> = ' + len + ' bytes. Round up to a power of two, at least the minimum block: <b>' + this.size(k) + ' bytes</b> (order ' + k + '). ' +
        (this.size(k) - len) + ' bytes will be lost to rounding.');
      var sizes = [];
      if (k > 0) sizes.push(this.size(k - 1));
      sizes.push(this.size(k));
      if (k < this.maxOrder) sizes.push(this.size(k + 1));
      first.question = { prompt: 'Request for ' + len + ' bytes. How large is the block that will be granted?',
        choices: sizes.map(function (v) { return v + ' bytes'; }), answer: sizes.indexOf(this.size(k)),
        explain: 'The smallest power of two that is at least ' + len + ' and at least the ' + this.minBlock + '-byte minimum.' };
      var j = k;
      while (j <= this.maxOrder && !this.lists[j].length) j++;
      if (j > this.maxOrder) {
        this.step('No free block of ' + this.size(k) + ' bytes or larger exists. ' + this.freeBytes() + ' bytes are free in total, but the largest free block is ' + this.largestFree() +
          ' bytes: <b>OutOfMemory</b>' + (this.freeBytes() >= this.size(k) ? ' through external fragmentation.' : '.'), null, { log: { html: 'alloc ' + len + ': OutOfMemory', state: 'deleted' } });
        return null;
      }
      var block = this.lists[j][0];
      this.unlink(block);
      this.state[block] = 'used'; this.order[block] = j;     // provisional, shrinks while splitting
      m[block] = 'compare';
      if (j > k) this.step('The free list of order ' + k + ' is empty. The smallest free block that is large enough has ' + this.size(j) + ' bytes: take it and split it.', m);
      while (j > k) {
        j--;
        var half = block + (1 << j);
        this.order[block] = j;
        this.pushFree(half, j);
        m = {}; m[block] = 'compare'; m[half] = 'split';
        this.step('Split: the left half (' + this.size(j) + ' bytes) is kept, the right half, its <b>buddy</b>, goes on the free list of order ' + j + '.', m);
      }
      this.name[block] = name; this.lens[block] = len;
      this.requested += len; this.granted += this.size(k);
      m = {}; m[block] = 'inserted';
      this.step('Block <b>' + name + '</b>: ' + this.size(k) + ' bytes at offset ' + block * this.minBlock + ' for a request of ' + len + '. Total requested ' + this.requested + ', granted ' + this.granted + '.',
        m, { log: { html: 'alloc ' + name + ' = ' + len + ' → ' + this.size(k) + ' at ' + block * this.minBlock, state: 'inserted' } });
      return block;
    });
  };
  B.free = function (start) {
    return this.run(function () {
      var block = start, k = this.order[block], name = this.name[block], m = {};
      this.requested -= this.lens[block]; this.granted -= this.size(k);
      delete this.lens[block];
      m[block] = 'deleted';
      this.step('Free block <b>' + name + '</b> (' + this.size(k) + ' bytes at offset ' + block * this.minBlock + ').', m);
      for (;;) {
        this.pushFree(block, k);
        m = {}; m[block] = 'free';
        if (k === this.maxOrder) {
          this.step('Nothing is left to merge with: the heap is one free block of ' + this.size(k) + ' bytes again.', m, { log: { html: 'free ' + name + ' (fully merged)', state: 'deleted' } });
          return;
        }
        // The buddy is the other half of the parent block: flip bit k of the block number.
        var buddy = block ^ (1 << k);
        if (this.state[buddy] !== 'free' || this.order[buddy] !== k) {
          m[buddy] = 'compare';
          this.step('Its buddy starts at offset ' + buddy * this.minBlock + ' (block number XOR ' + (1 << k) + '). ' +
            (this.state[buddy] === 'used' && this.order[buddy] === k
              ? 'That ' + this.size(k) + '-byte block is in use'
              // A buddy region of smaller blocks is never entirely free: its halves would have merged.
              : 'That ' + this.size(k) + '-byte region has been split into smaller blocks and at least one of them is still in use') +
            ', so merging stops. The block goes on the free list of order ' + k + '.', m, { log: { html: 'free ' + name, state: 'deleted' } });
          return;
        }
        m[block] = 'merge'; m[buddy] = 'merge';
        this.step('Its buddy at offset ' + buddy * this.minBlock + ' is free and whole: the two ' + this.size(k) + '-byte halves merge into one ' + this.size(k + 1) + '-byte block. Then look again, one order up.', m);
        this.unlink(block); this.unlink(buddy);
        this.state[block] = 'inside'; this.state[buddy] = 'inside';
        block = Math.min(block, buddy); k++;
      }
    });
  };

  window.Ch26 = { Pool: Pool, Tree: Tree, Buddy: Buddy, hName: hName, hHex: hHex, same: same };
})();

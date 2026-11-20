/* Chapter 30, figure 1: two small models that perform the SAME insert the way
 * the two engines do, and record what happens stage by stage.
 *
 *   CH30.Pg     PostgreSQL nbtree: a B-link B+tree. Every key is in a leaf;
 *               every page has a high key and a right link; a split is two
 *               steps (split, then tell the parent) with a flag in between;
 *               the root moves when it splits; one WAL record per step.
 *   CH30.Turso  Turso / SQLite index B-tree. Keys also live in interior
 *               pages; no sibling links, no high keys; an overfull page is
 *               rebalanced together with up to two siblings; the root keeps
 *               its page number; whole pages go to the WAL at commit.
 *
 * Both are SCHEMATIC: a page holds at most 4 entries (real pages are filled
 * by bytes, chapters 10 and 12), there is one inserter, keys are small
 * integers, and only the index is shown (not the table the row goes into).
 * What is modelled faithfully is the ORDER of the steps, which pages each
 * step touches, and the names: the WAL record names are chosen by the rule
 * of nbtinsert.c (INSERT_LEAF / INSERT_UPPER at :1343-1360, SPLIT_L when the
 * new tuple lands on the left page and SPLIT_R otherwise at :2080), and
 * Turso's output pages take their page numbers in ascending order
 * (btree.rs:4489-4513). Block numbers and split points are the models'.
 * The source lines are given with every step.
 *
 * Classic script: defines window.CH30 (and module.exports under node).
 */
(function (root) {
  'use strict';

  var CAP = 4;   // entries per page: keys in a leaf, downlinks (Postgres) or cells (Turso) above
  var PG = 'postgres/src/backend/access/nbtree/';
  var TU = 'turso/core/';

  function k(v, state) { return '<b class="bt-k' + (state ? ' s-' + state : '') + '">' + v + '</b>'; }
  function clone(v) { return JSON.parse(JSON.stringify(v)); }
  function sortedInsert(a, v) { var i = 0; while (i < a.length && a[i] < v) i++; a.splice(i, 0, v); return i; }

  /* A step: {stage 1..6, level (cascade round), chip, caption, refs[], state, highlight, wal[], dirty[]} */
  function Recorder(model) { this.model = model; this.steps = null; }
  Recorder.prototype.emit = function (stage, level, chip, caption, hl, refs, chipState) {
    if (!this.steps) return;
    this.steps.push({
      stage: stage, level: level, chip: chip, chipState: chipState || null, caption: caption, refs: refs || [],
      state: this.model.snapshot(), highlight: hl || {}, wal: this.model.wal.slice(), dirty: this.model.dirtyList()
    });
  };

  // =========================== PostgreSQL =====================================

  function Pg() {
    this.pages = {};
    this.next = 1;             // block 0 is the metapage
    this.orphans = [];         // right halves whose downlink is not in the parent yet
    this.wal = [];
    this.dirty = {};
    this.rec = new Recorder(this);
    this.meta = { root: this.alloc(true, 0) };
  }
  Pg.prototype.alloc = function (leaf, level) {
    var id = this.next++;
    this.pages[id] = { leaf: leaf, level: level, keys: [], children: [], high: null, right: null, incomplete: false };
    return id;
  };
  Pg.prototype.dirtyList = function () { return Object.keys(this.dirty).map(Number); };
  Pg.prototype.snapshot = function (locks) {
    var self = this;
    locks = locks || this.locks || {};
    function node(id) {
      var p = self.pages[id];
      // A leaf's name goes UNDER the box: above it, the edge from the parent
      // would run through the text.
      var name = 'blk ' + id + (id === self.meta.root ? ' · root' : '') + (p.incomplete ? ' · INCOMPLETE_SPLIT' : '');
      var out = { id: 'g' + id, keys: p.keys.slice(), leaf: p.leaf, meta: { dirty: !!self.dirty[id] } };
      if (p.leaf) out.meta.note = name; else out.meta.label = name;
      if (p.high !== null) out.highKey = p.high;
      if (p.right !== null) out.right = 'g' + p.right;
      if (locks[id]) out.meta.lock = locks[id];
      if (!p.leaf) out.children = p.children.map(node);
      return out;
    }
    var roots = [node(this.meta.root)];
    this.orphans.forEach(function (id) { roots.push(node(id)); });
    return roots.length === 1 ? roots[0] : roots;
  };
  /* Index of the downlink to follow: the last pivot that is <= key. */
  function pgChild(p, key) { var i = 0; while (i < p.keys.length && p.keys[i] <= key) i++; return i; }

  Pg.prototype.insert = function (key, record) {
    var rec = this.rec, self = this;
    rec.steps = record ? [] : null;
    this.wal = []; this.dirty = {}; this.locks = {};
    var stack = [], id = this.meta.root, p, hl;

    // ---- stage 1: find the leaf ---------------------------------------------
    for (;;) {
      p = this.pages[id];
      this.locks = {}; this.locks[id] = p.leaf ? 'X' : 'S';
      hl = { nodes: {}, keys: {}, edges: {}, cursor: { node: 'g' + id, label: key } };
      hl.nodes['g' + id] = 'active';
      var hk = p.high === null ? 'it has no high key (rightmost page), so there is nothing to the right'
        : k(key) + ' is below its high key ' + k(p.high, 'compare') + ', so the page was not split under us';
      if (p.high !== null) hl.keys['g' + id + ':high'] = 'compare';
      if (p.leaf) {
        rec.emit(1, 0, 'X-lock leaf ' + id, 'PostgreSQL: block ' + id + ' is a leaf; it is locked in <b>write</b> mode. <code>_bt_moveright</code> checks again: ' + hk +
          '. This is the page for ' + k(key, 'inserted') + '. Only this one page is locked; the pages above were released on the way down.',
          hl, [PG + 'nbtsearch.c:192-207', PG + 'nbtsearch.c:288-316'], 'lock-exclusive');
        break;
      }
      var i = pgChild(p, key);
      stack.push({ id: id, off: i });
      hl.edges['g' + p.children[i]] = 'active';
      rec.emit(1, 0, 'S-lock ' + id + ' → ' + p.children[i], 'PostgreSQL: <code>_bt_search</code> read-locks block ' + id + '. <code>_bt_moveright</code>: ' + hk +
        '. <code>_bt_binsrch</code> picks the downlink to block ' + p.children[i] + '. The pair (block ' + id + ', offset ' + (i + 1) +
        ') is pushed on a private stack as a <em>hint</em> for later, the lock on block ' + id + ' is dropped, and only then is the child locked.',
        hl, [PG + 'nbtsearch.c:142-143', PG + 'nbtsearch.c:155-174', PG + 'nbtsearch.c:185'], 'lock-shared');
      id = p.children[i];
    }

    // ---- stage 2: uniqueness --------------------------------------------------
    hl = { nodes: {}, keys: {} };
    hl.nodes['g' + id] = 'active';
    if (p.keys.indexOf(key) >= 0) {
      hl.keys['g' + id + ':' + key] = 'deleted';
      rec.emit(2, 0, 'duplicate!', 'PostgreSQL: <code>_bt_check_unique</code> finds ' + k(key, 'deleted') + ' on the locked leaf and asks the table whether that row is alive. It is: ' +
        '<b>duplicate key value violates unique constraint</b>. Nothing was changed. (Had the other row belonged to a transaction still running, the insert would release the page, wait for it, and search again.)',
        hl, [PG + 'nbtinsert.c:213-235', PG + 'nbtinsert.c:411'], 'deleted');
      this.locks = {};
      return this.finish(false);
    }
    rec.emit(2, 0, 'unique: ok', 'PostgreSQL: <code>_bt_check_unique</code>. The write lock on this leaf <em>is</em> the uniqueness lock: any other insert of ' + k(key) +
      ' must come to this same page and wait. No equal key is here, so the insert may proceed.',
      hl, [PG + 'nbtinsert.c:166-204', PG + 'nbtinsert.c:213', PG + 'nbtinsert.c:411'], 'found');

    // ---- stage 3: make room -----------------------------------------------------
    if (p.keys.length < CAP) {
      sortedInsert(p.keys, key);
      this.dirty[id] = true;
      this.wal.push('INSERT_LEAF blk ' + id);
      hl.keys['g' + id + ':' + key] = 'inserted';
      rec.emit(3, 0, 'fits: INSERT_LEAF', 'PostgreSQL: <code>_bt_findinsertloc</code> finds free space, so <code>_bt_insertonpg</code> adds the tuple inside a critical section, marks the buffer dirty and writes <b>one WAL record</b> (<code>XLOG_BTREE_INSERT_LEAF</code>) describing just this tuple. No split, so stages 4 and 5 are skipped.',
        hl, [PG + 'nbtinsert.c:1295-1304', PG + 'nbtinsert.c:1346', PG + 'nbtinsert.c:1407'], 'inserted');
    } else {
      hl.nodes['g' + id] = 'split';
      rec.emit(3, 0, 'leaf ' + id + ' is full', 'PostgreSQL: the leaf is full. Before splitting, <code>_bt_findinsertloc</code> tries to make room <em>on this page</em>: remove entries marked dead, bottom-up deletion, merge duplicates into posting lists. This model has nothing to remove, so the page must split.',
        hl, [PG + 'nbtinsert.c:915-916', PG + 'nbtinsert.c:1223-1231', PG + 'nbtinsert.c:2728']);
      this.split(id, key, null, stack, 0, -1);
    }
    this.locks = {};
    return this.finish(true);
  };

  /* Split page `id` while adding `key` (a leaf tuple, or a pivot with downlink
   * `child` that goes right after offset `off`). Then tell the parent. */
  Pg.prototype.split = function (id, key, child, stack, level, off) {
    var rec = this.rec, p = this.pages[id], rightmost = p.right === null;
    var right = this.alloc(p.leaf, p.level), r = this.pages[right], sep, cut, hl;
    // nbtinsert.c:2080: the record is SPLIT_L when the new tuple ends up on
    // the left page and SPLIT_R when it ends up on the right page. Leaf or
    // interior does not matter.
    var newItemOnLeft;
    this.locks = {}; this.locks[id] = 'X'; this.locks[right] = 'X';
    if (p.leaf) {
      var items = p.keys.slice();
      sortedInsert(items, key);
      // Rightmost leaf: leave the left page full (fillfactor 90), the append
      // optimisation. Otherwise cut in the middle.
      cut = rightmost ? CAP : Math.ceil(items.length / 2);
      sep = items[cut];
      newItemOnLeft = items.indexOf(key) < cut;
      hl = { nodes: {}, keys: {} };
      hl.nodes['g' + id] = 'split';
      rec.emit(4, level, 'split point: ' + cut + ' | ' + (items.length - cut), 'PostgreSQL: <code>_bt_findsplitloc</code> imagines the page with ' + k(key, 'inserted') + ' already on it and picks where to cut. ' +
        (rightmost ? 'This is the <b>rightmost</b> leaf, so it leaves the left page as full as the fill factor allows (keys arriving in ascending order would otherwise leave every page half empty).'
          : 'Not the rightmost page: the candidates near the middle are compared and the one giving the <b>shortest separator</b> wins.') +
        ' Left keeps ' + cut + ', right gets ' + (items.length - cut) + '. The new high key of the left page is ' + k(sep, 'split') +
        '; on a multi-column key <code>_bt_truncate</code> would drop the columns not needed to tell the two halves apart.',
        hl, [PG + 'nbtinsert.c:1565', PG + 'nbtsplitloc.c:130', PG + 'nbtinsert.c:1680']);
      r.keys = items.slice(cut);
      p.keys = items.slice(0, cut);
    } else {
      p.children.splice(off + 1, 0, child);
      p.keys.splice(off, 0, key);
      var lc = Math.ceil(p.children.length / 2);     // downlinks that stay left
      sep = p.keys[lc - 1];
      newItemOnLeft = off + 1 < lc;                  // the new pivot tuple carries downlink number off + 1
      r.children = p.children.slice(lc);
      r.keys = p.keys.slice(lc);
      p.children = p.children.slice(0, lc);
      p.keys = p.keys.slice(0, lc - 1);
      // The new pivot's child now has its downlink: its split is complete.
      this.pages[child === null ? id : this.leftOf(child)].incomplete = false;
      this.orphans = this.orphans.filter(function (o) { return o !== child; });
    }
    r.high = p.high; r.right = p.right;
    p.high = sep; p.right = right; p.incomplete = true;
    this.orphans.push(right);
    this.dirty[id] = true; this.dirty[right] = true;
    var record = newItemOnLeft ? 'SPLIT_L' : 'SPLIT_R';
    this.wal.push(record + ' blk ' + id + '+' + right);
    hl = { nodes: {}, keys: {}, links: {} };
    hl.nodes['g' + id] = 'split'; hl.nodes['g' + right] = 'split';
    hl.keys['g' + id + ':high'] = 'split'; hl.links['g' + id] = 'active';
    if (p.leaf) hl.keys['*:' + key] = 'inserted';
    rec.emit(4, level, record + ' → new blk ' + right, 'PostgreSQL: <code>_bt_split</code>. Both halves are built in private memory; only then is the new block ' + right +
      ' allocated (the last thing that can fail). In one critical section the left half is copied over block ' + id + ' (the left page never moves), the right half goes to block ' + right +
      ', the <b>right link</b> ' + id + ' → ' + right + ' is set, block ' + id + ' gets the flag <b>INCOMPLETE_SPLIT</b>' + (p.leaf ? '' : ' (and the child below loses its flag)') +
      ', and <b>one WAL record</b> covers all of it: <code>XLOG_BTREE_' + record + '</code>, because the new ' + (p.leaf ? 'tuple ' + k(key, 'inserted') : 'pivot ' + k(key, 'split')) +
      ' ended up on the <b>' + (newItemOnLeft ? 'left' : 'right') + '</b> page (the name says nothing about leaf or interior). ' +
      (p.leaf ? '' : 'This model cuts an interior page in the middle; the real <code>_bt_findsplitloc</code> leaves a rightmost interior page about 70% full. ') +
      'The parent knows nothing yet, and that is fine: a search arriving at block ' + id + ' with a key at or above ' +
      k(sep, 'split') + ' sees the high key and follows the right link.',
      hl, [PG + 'nbtinsert.c:1580', PG + 'nbtinsert.c:1739', PG + 'nbtinsert.c:1760-1770', PG + 'nbtinsert.c:1950-1959', PG + 'nbtinsert.c:2080-2081'].concat(p.leaf ? [] : [PG + 'nbtsplitloc.c:281-286']), 'split');
    this.insertParent(id, right, sep, stack, level);
  };
  /* The left sibling of `right` on its level (the page whose right link is it). */
  Pg.prototype.leftOf = function (right) {
    for (var id in this.pages) if (this.pages[id].right === right) return +id;
    return null;
  };

  Pg.prototype.insertParent = function (left, right, sep, stack, level) {
    var rec = this.rec, hl = { nodes: {}, keys: {}, edges: {} };
    if (stack.length === 0) {
      // The split page was the root: build a new level above it.
      var top = this.alloc(false, this.pages[left].level + 1), t = this.pages[top];
      t.children = [left, right]; t.keys = [sep];
      this.meta.root = top;
      this.pages[left].incomplete = false;
      this.orphans = [];
      this.dirty[top] = true; this.dirty[0] = true;
      this.wal.push('NEWROOT blk ' + top + ' + meta');
      this.locks = {}; this.locks[top] = 'X';
      hl.nodes['g' + top] = 'inserted'; hl.keys['g' + top + ':' + sep] = 'split';
      rec.emit(5, level, 'NEWROOT blk ' + top, 'PostgreSQL: the page that split was the root, so there is no parent. <code>_bt_newlevel</code> allocates block ' + top +
        ' as a <b>new root</b> with two downlinks (' + left + ' and ' + right + ') and the separator ' + k(sep, 'split') + ', then points the <b>metapage</b> at it. The flag on block ' + left +
        ' is cleared. New root, metapage and flag are one WAL record (<code>XLOG_BTREE_NEWROOT</code>). The root\'s block number has changed; the old root is now an ordinary page.',
        hl, [PG + 'nbtinsert.c:2158', PG + 'nbtinsert.c:2517-2522', PG + 'nbtinsert.c:2563', PG + 'nbtinsert.c:2595', PG + 'nbtinsert.c:2637'], 'inserted');
      return;
    }
    var ent = stack.pop(), parent = this.pages[ent.id];
    // _bt_getstackbuf: the remembered offset is only a hint; find the downlink to `left`.
    var off = parent.children.indexOf(left);
    this.locks = {}; this.locks[ent.id] = 'X'; this.locks[left] = 'X';
    if (parent.children.length < CAP) {
      parent.children.splice(off + 1, 0, right);
      parent.keys.splice(off, 0, sep);
      this.pages[left].incomplete = false;
      this.orphans = this.orphans.filter(function (o) { return o !== right; });
      this.dirty[ent.id] = true; this.dirty[left] = true;
      this.wal.push('INSERT_UPPER blk ' + ent.id);
      hl.nodes['g' + ent.id] = 'active'; hl.keys['g' + ent.id + ':' + sep] = 'split'; hl.edges['g' + right] = 'active';
      rec.emit(5, level, 'INSERT_UPPER blk ' + ent.id, 'PostgreSQL: <code>_bt_insert_parent</code>, a <b>second, separate</b> atomic action. The stack says the parent was block ' + ent.id +
        '; <code>_bt_getstackbuf</code> re-finds the downlink to block ' + left + ' there (it could have moved; the stack is only a hint). The new pivot (' + k(sep, 'split') + ' → block ' + right +
        ') goes right after it, and in the same critical section and the same WAL record the flag INCOMPLETE_SPLIT on block ' + left + ' is cleared. ' +
        'Had the process died between the two actions, the next <em>writer</em> passing block ' + left + ' would have finished the split (<code>_bt_finish_split</code>).',
        hl, [PG + 'nbtinsert.c:2223', PG + 'nbtinsert.c:2247-2249', PG + 'nbtinsert.c:1325-1327', PG + 'nbtinsert.c:1360', PG + 'nbtinsert.c:2270'], 'found');
      return;
    }
    hl.nodes['g' + ent.id] = 'split';
    rec.emit(5, level, 'parent ' + ent.id + ' is full', 'PostgreSQL: the parent, block ' + ent.id + ', has no room for the new pivot. <code>_bt_insertonpg</code> is the same function for every level: it calls <code>_bt_split</code> on the parent, and the insert climbs one level.',
      hl, [PG + 'nbtinsert.c:2247', PG + 'nbtinsert.c:1223-1231']);
    this.split(ent.id, sep, right, stack, level + 1, off);
  };

  Pg.prototype.finish = function (ok) {
    var rec = this.rec;
    if (ok) {
      var n = this.wal.length, pages = this.dirtyList();
      rec.emit(6, 0, 'commit: flush ' + n + ' WAL record' + (n === 1 ? '' : 's'), 'PostgreSQL: durability. Each step above already put its own small record into the WAL buffer (' + n + ' here: ' + this.wal.join(', ') +
        '). At commit <code>XLogFlush</code> forces the log to disk up to the commit record. The ' + pages.length + ' changed page' + (pages.length === 1 ? '' : 's') +
        ' stay dirty in shared buffers; a later checkpoint writes them. After a crash, replay repeats the records one by one (<code>btree_xlog_split</code>, ...), and a split whose parent record is missing is simply an incomplete split.',
        {}, ['postgres/src/backend/access/transam/xact.c:1548', PG + 'nbtxlog.c:247', PG + 'nbtxlog.c:1004'], 'found');
    }
    var steps = rec.steps;
    rec.steps = null;
    return steps;
  };

  Pg.prototype.keys = function () {
    var id = this.meta.root, out = [];
    while (!this.pages[id].leaf) id = this.pages[id].children[0];
    for (; id !== null; id = this.pages[id].right) out = out.concat(this.pages[id].keys);
    return out;
  };
  /* null, or a description of the first broken invariant. */
  Pg.prototype.validate = function () {
    var self = this, err = null, depth = null;
    (function visit(id, lo, hi, d) {
      var p = self.pages[id], i;
      if (err) return;
      if (p.incomplete) err = 'incomplete split left on ' + id;
      if (p.high !== hi) err = 'high key of ' + id + ' is ' + p.high + ', expected ' + hi;
      for (i = 0; i < p.keys.length; i++) {
        if ((lo !== null && p.keys[i] < lo) || (hi !== null && p.keys[i] >= hi)) err = 'key out of bounds on ' + id;
        if (i > 0 && p.keys[i - 1] >= p.keys[i]) err = 'keys not ascending on ' + id;
      }
      if (p.leaf) {
        if (p.keys.length > CAP) err = 'leaf ' + id + ' too full';
        if (depth === null) depth = d;
        if (depth !== d) err = 'uneven depth';
        return;
      }
      if (p.children.length > CAP || p.children.length !== p.keys.length + 1) err = 'bad fanout on ' + id;
      for (i = 0; i < p.children.length; i++) {
        var next = i + 1 < p.children.length ? p.children[i + 1] : null;
        if (next !== null && self.pages[p.children[i]].right !== next) err = 'right link of ' + p.children[i];
        visit(p.children[i], i === 0 ? lo : p.keys[i - 1], i === p.keys.length ? hi : p.keys[i], d + 1);
      }
    })(this.meta.root, null, null, 0);
    return err;
  };

  // ============================== Turso =======================================

  function Turso() {
    this.pages = {};
    this.next = 2;             // page 1 holds the schema; this index starts at page 2
    this.wal = [];
    this.dirty = {};
    this.overflow = null;      // {page, key}: a cell waiting in memory for balance
    this.rec = new Recorder(this);
    this.root = this.alloc(true);
  }
  Turso.prototype.alloc = function (leaf) {
    var id = this.next++;
    this.pages[id] = { leaf: leaf, keys: [], children: [] };
    return id;
  };
  Turso.prototype.dirtyList = function () { return Object.keys(this.dirty).map(Number); };
  Turso.prototype.snapshot = function () {
    var self = this;
    function node(id) {
      var p = self.pages[id];
      var name = 'page ' + id + (id === self.root ? ' · root' : '') + (self.pinned && self.pinned[id] ? ' · pinned' : '') +
        (self.overflow && self.overflow.page === id ? ' · overflow cell ' + self.overflow.key : '');
      var out = { id: 't' + id, keys: p.keys.slice(), leaf: p.leaf, meta: { dirty: !!self.dirty[id] } };
      if (p.leaf) out.meta.note = name; else out.meta.label = name;
      if (!p.leaf) out.children = p.children.map(node);
      return out;
    }
    return node(this.root);
  };

  Turso.prototype.insert = function (key, record) {
    var rec = this.rec;
    rec.steps = record ? [] : null;
    this.wal = []; this.dirty = {}; this.pinned = {}; this.overflow = null;
    var stack = [], id = this.root, p, hl, i, dup = false;

    // ---- stage 1: find the leaf ---------------------------------------------
    for (;;) {
      p = this.pages[id];
      this.pinned[id] = true;
      hl = { nodes: {}, keys: {}, edges: {}, cursor: { node: 't' + id, label: key } };
      hl.nodes['t' + id] = 'active';
      if (p.leaf) {
        dup = p.keys.indexOf(key) >= 0;
        rec.emit(1, 0, 'leaf ' + id + ' on the stack', 'Turso: page ' + id + ' is a leaf; a binary search over its cell pointers finds the slot for ' + k(key, 'inserted') +
          '. The cursor now holds the whole path as a <b>page stack</b>, every page on it pinned. There are no latches: in the WAL journal mode traced here one write transaction at a time is the rule, enforced by the WAL write lock. ' +
          'Each <code>read_page</code> on the way may have returned <code>IO</code> instead of a page; the seek then returns to the caller and is called again later (see figure 2).',
          hl, [TU + 'storage/btree.rs:6928', TU + 'storage/btree.rs:2364', TU + 'storage/pager.rs:3672', TU + 'storage/wal.rs:3587-3589'], 'active');
        break;
      }
      i = 0;
      while (i < p.keys.length && p.keys[i] < key) i++;
      if (i < p.keys.length && p.keys[i] === key) {
        dup = true;
        hl.keys['t' + id + ':' + key] = 'compare';
        rec.emit(1, 0, 'found in page ' + id, 'Turso: in an index B-tree the keys of interior pages are real entries, not copies. The seek finds ' + k(key, 'compare') + ' right here, in interior page ' + id + '.',
          hl, [TU + 'storage/btree.rs:2364'], 'compare');
        break;
      }
      stack.push({ id: id, idx: i });
      hl.edges['t' + p.children[i]] = 'active';
      rec.emit(1, 0, 'push ' + id + ' → ' + p.children[i], 'Turso: the cursor seeks. It pushes page ' + id + ' on its <b>page stack</b> (which pins it) and binary-searches it: ' +
        (i < p.keys.length ? k(key) + ' is below ' + k(p.keys[i], 'compare') + ', so it follows that cell\'s left child, page ' + p.children[i]
          : k(key) + ' is above every key, so it follows the right-most pointer, page ' + p.children[i]) +
        '. The parent stays pinned; there are no parent pointers and no sibling links on disk, so the stack is the only way back up.',
        hl, [TU + 'storage/btree.rs:6928', TU + 'storage/btree.rs:2364', TU + 'storage/btree.rs:8989'], 'active');
      id = p.children[i];
    }

    // ---- stage 2: uniqueness --------------------------------------------------
    hl = { nodes: {}, keys: {} };
    hl.nodes['t' + id] = 'active';
    if (dup) {
      hl.keys['t' + id + ':' + key] = 'deleted';
      rec.emit(2, 0, 'duplicate!', 'Turso: the B-tree does not know about uniqueness. The bytecode does: the seek above was issued by the <code>NoConflict</code> instruction (or by <code>IdxInsert</code> itself), which compares the entry under the cursor with the new key and raises <b>UNIQUE constraint failed</b>. Nothing was changed.',
        hl, [TU + 'vdbe/execute.rs:12963', TU + 'vdbe/execute.rs:12518-12549'], 'deleted');
      this.pinned = {};
      return this.finish(false);
    }
    rec.emit(2, 0, 'unique: ok', 'Turso: uniqueness is checked <em>outside</em> the tree, by the bytecode that drives it. The seek of stage 1 was that check: the cursor is not on an equal key, so <code>IdxInsert</code> moves to its <code>Insert</code> state. No page lock is needed, because no other write transaction exists in WAL mode.',
      hl, [TU + 'vdbe/execute.rs:12963', TU + 'vdbe/execute.rs:12518-12564', TU + 'storage/btree.rs:7012'], 'found');

    // ---- stage 3: make room -----------------------------------------------------
    this.dirty[id] = true;
    if (p.keys.length < CAP) {
      sortedInsert(p.keys, key);
      hl.keys['t' + id + ':' + key] = 'inserted';
      rec.emit(3, 0, 'fits: page ' + id + ' dirty', 'Turso: <code>insert_into_page</code> calls <code>add_dirty</code> on the leaf (the pager now knows the page id), and <code>insert_into_cell</code> finds enough free bytes: the cell is written into the cached page. <b>Nothing is logged now.</b> No balancing, so stages 4 and 5 are skipped.',
        hl, [TU + 'storage/btree.rs:3183', TU + 'storage/btree.rs:3293', TU + 'storage/pager.rs:3919'], 'inserted');
    } else {
      this.overflow = { page: id, key: key };
      hl.nodes['t' + id] = 'split';
      rec.emit(3, 0, 'overflow cell on ' + id, 'Turso: the leaf is full. <code>insert_into_cell</code> (through <code>_insert_into_cell</code>) does not touch the page bytes at all: the new cell ' + k(key, 'inserted') +
        ' is parked in <code>page.overflow_cells</code>, a list in memory next to the cached page. "This page has an overflow cell" is the definition of overfull: the write state becomes <code>Balancing</code> and the cursor calls <code>balance</code>. ' +
        '(An <em>overflow cell</em> is a whole cell waiting for a page. It is not the <em>overflow page</em> of chapter 13, which holds the tail of one large value.)',
        hl, [TU + 'storage/btree.rs:10325', TU + 'storage/btree.rs:10347-10368', TU + 'storage/btree.rs:3301', TU + 'storage/btree.rs:3307-3308', TU + 'storage/btree.rs:3364-3365'], 'split');
      sortedInsert(p.keys, key);    // from here on the model keeps the cell in the page's list
      this.balance(id, stack);
    }
    this.pinned = {};
    return this.finish(true);
  };

  /* The loop of balance(): from the overfull page upward. */
  Turso.prototype.balance = function (cur, stack) {
    var rec = this.rec, level = 0, hl;
    while (this.pages[cur].keys.length > CAP) {
      if (stack.length === 0) {
        // balance_root ("balance deeper"): the root keeps its page number.
        var child = this.alloc(this.pages[cur].leaf);
        this.pages[child] = this.pages[cur];
        this.pages[cur] = { leaf: false, keys: [], children: [child] };
        if (this.overflow && this.overflow.page === cur) this.overflow.page = child;
        this.dirty[child] = true; this.dirty[cur] = true;
        stack.push({ id: cur, idx: 0 });
        hl = { nodes: {} };
        hl.nodes['t' + cur] = 'active'; hl.nodes['t' + child] = 'split';
        rec.emit(4, level, 'balance_root: new page ' + child, 'Turso: the overfull page is the <b>root</b>. <code>balance_root</code> allocates page ' + child + ', copies the whole root into it (overflow cell included) and turns page ' + cur +
          ' into an empty interior page whose right-most pointer is page ' + child + '. The root\'s page number does not change, so the schema entry that names it stays valid. The tree is one level taller; page ' + child + ' is now balanced like any other page.',
          hl, [TU + 'storage/btree.rs:3451-3455', TU + 'storage/btree.rs:5410'], 'split');
        cur = child;
      }
      var ent = stack.pop();
      this.balanceNonRoot(ent.id, ent.idx, level);
      this.overflow = null;
      cur = ent.id;
      level++;
    }
  };

  Turso.prototype.balanceNonRoot = function (parentId, idx, level) {
    var rec = this.rec, self = this, par = this.pages[parentId], n = par.children.length;
    var first = n <= 3 ? 0 : idx === 0 ? 0 : idx === n - 1 ? n - 3 : idx - 1;
    var count = Math.min(3, n);
    var sibs = par.children.slice(first, first + count);
    var leaf = this.pages[sibs[0]].leaf;
    var hl = { nodes: {}, keys: {} };
    sibs.forEach(function (s) { hl.nodes['t' + s] = 'merge'; self.dirty[s] = true; self.pinned[s] = true; });
    hl.nodes['t' + par.children[idx]] = 'split';
    for (var d = first; d < first + count - 1; d++) hl.keys['t' + parentId + ':' + par.keys[d]] = 'compare';
    this.dirty[parentId] = true;
    rec.emit(4, level, 'siblings ' + sibs.join(', '), 'Turso: <code>balance_non_root</code> never looks at one page alone. It takes the overfull page ' + par.children[idx] + ' and up to two neighbours (' +
      (count === 1 ? 'it has none here' : 'here pages ' + sibs.join(', ')) + '), reads and pins them, and lifts the ' + (count - 1) + ' divider' + (count === 2 ? '' : 's') + ' between them out of the parent. ' +
      'The table-leaf shortcut <code>balance_quick</code> (append a new right leaf) does not apply to an index.',
      hl, [TU + 'storage/btree.rs:3462', TU + 'storage/btree.rs:3604', TU + 'storage/btree.rs:3693-3713', TU + 'storage/btree.rs:3766']);

    // One flat array: sibling cells, divider, sibling cells, divider, ...
    var flat = [], finalRight = null;
    sibs.forEach(function (s, j) {
      var p = self.pages[s];
      p.keys.forEach(function (key, t) { flat.push({ k: key, left: leaf ? null : p.children[t] }); });
      if (j < count - 1) flat.push({ k: par.keys[first + j], left: leaf ? null : p.children[p.keys.length] });
      else if (!leaf) finalRight = p.children[p.keys.length];
    });
    var pagesOut = Math.ceil((flat.length + 1) / (CAP + 1));
    var counts = [], rest = flat.length - (pagesOut - 1), j;
    for (j = 0; j < pagesOut; j++) { counts.push(Math.min(CAP, rest)); rest -= counts[j]; }           // pack left
    for (j = pagesOut - 1; j >= 1; j--) while (counts[j - 1] - counts[j] >= 2) { counts[j]++; counts[j - 1]--; }   // even out, right to left
    var ids = sibs.slice(0, pagesOut), fresh = [];
    while (ids.length < pagesOut) { var nid = this.alloc(leaf); ids.push(nid); fresh.push(nid); this.dirty[nid] = true; }
    // "Reassign page numbers in increasing order" (btree.rs:4489-4513): the
    // output pages, left to right, get the page numbers in ascending order.
    var treeOrder = ids.join(',');
    ids.sort(function (x, y) { return x - y; });
    var renumbered = ids.join(',') !== treeOrder;
    var pos = 0, dividers = [];
    ids.forEach(function (id2, jj) {
      var cells = flat.slice(pos, pos + counts[jj]);
      pos += counts[jj];
      var page = { leaf: leaf, keys: cells.map(function (c) { return c.k; }), children: [] };
      if (!leaf) page.children = cells.map(function (c) { return c.left; }).concat([jj < pagesOut - 1 ? flat[pos].left : finalRight]);
      if (jj < pagesOut - 1) dividers.push(flat[pos++].k);
      self.pages[id2] = page;
    });
    this.overflow = null;
    var before = { keys: par.keys.slice(first, first + count - 1) };
    hl = { nodes: {}, keys: {} };
    ids.forEach(function (id2) { hl.nodes['t' + id2] = fresh.indexOf(id2) >= 0 ? 'inserted' : 'merge'; });
    par.keys.splice.apply(par.keys, [first, count - 1].concat(dividers));
    par.children.splice.apply(par.children, [first, count].concat(ids));
    dividers.forEach(function (dk) { hl.keys['t' + parentId + ':' + dk] = 'split'; });
    rec.emit(4, level, count + ' pages → ' + pagesOut + (fresh.length ? ' (new ' + fresh.join(', ') + ')' : ''), 'Turso: all ' + flat.length + ' cells (the siblings\' cells, the dividers between them and the overflow cell) are laid out in one array and dealt out again: first packed to the left, then evened out from the right. ' +
      'Result: ' + counts.join(' + ') + ' cells on ' + pagesOut + ' page' + (pagesOut === 1 ? '' : 's') + ', with ' + (dividers.length ? dividers.map(function (dk) { return k(dk, 'split'); }).join(', ') : 'nothing') + ' going up as divider' + (dividers.length === 1 ? '' : 's') + '. ' +
      (fresh.length ? '<b>One page was allocated</b> (page ' + fresh.join(', ') + '): this is what a split looks like here.' : '<b>No page was allocated</b>: the neighbours had room, so the "split" turned into a redistribution. PostgreSQL never does this.') +
      ' The output pages, left to right, take the old and new page numbers in ascending order' + (renumbered ? ' (here that changes which number holds which cells: ' + ids.join(', ') + ')' : '') + '.' +
      ' The redistribution itself is pure computation, with no I/O and therefore no yield point. (The picture already shows the dividers in the parent; that is the next stage.)',
      hl, [TU + 'storage/btree.rs:3872', TU + 'storage/btree.rs:3992-4107', TU + 'storage/btree.rs:4200-4284', TU + 'storage/btree.rs:4293-4420', TU + 'storage/btree.rs:4428', TU + 'storage/btree.rs:4489-4513'], fresh.length ? 'split' : 'merge');

    hl = { nodes: {}, keys: {}, edges: {} };
    hl.nodes['t' + parentId] = par.keys.length > CAP ? 'split' : 'active';
    dividers.forEach(function (dk) { hl.keys['t' + parentId + ':' + dk] = 'split'; });
    ids.forEach(function (id2) { hl.edges['t' + id2] = 'active'; });
    var changed = dividers.join(',') !== before.keys.join(',');
    rec.emit(5, level, 'dividers ' + (dividers.join(', ') || '-') + ' → page ' + parentId, 'Turso: the parent, page ' + parentId + ', gets its dividers back: ' +
      (changed ? 'was ' + (before.keys.join(', ') || 'none') + ', now ' + (dividers.join(', ') || 'none') : 'the same keys as before') + '. Each divider is put in with the same <code>insert_into_cell</code> as a leaf cell' +
      (par.keys.length > CAP ? ', and this time the parent has no room: the divider becomes an <b>overflow cell of the parent</b>. That is how a split travels upward. The loop in <code>balance</code> pops the stack and starts again one level up.'
        : '; it fits, so <code>balance</code> finds this level in order and stops.') +
      ' There is no moment at which a page exists that the parent does not point to, and none is needed: nobody else can be looking.',
      hl, [TU + 'storage/btree.rs:4583-4592', TU + 'storage/btree.rs:4692', TU + 'storage/btree.rs:3429-3430'], par.keys.length > CAP ? 'split' : 'found');
    if (par.keys.length > CAP) this.overflow = { page: parentId, key: dividers[dividers.length - 1] };
  };

  Turso.prototype.finish = function (ok) {
    var rec = this.rec;
    if (ok) {
      var pages = this.dirtyList();
      this.wal = pages.map(function (id, i) { return 'frame: page ' + id + (i === pages.length - 1 ? ' (commit)' : ''); });
      rec.emit(6, 0, 'commit: ' + pages.length + ' page frame' + (pages.length === 1 ? '' : 's'), 'Turso: durability. Until now only cached pages changed and the pager kept a list of dirty page ids (' + pages.join(', ') +
        '). At commit <code>commit_wal_inner</code> turns each dirty page into a <b>whole-page WAL frame</b>, writes them, and fsyncs. The last frame carries the database size, which makes it the commit frame: readers and recovery accept frames only up to the last commit frame, so the ' +
        pages.length + ' page' + (pages.length === 1 ? '' : 's') + ' become visible together or not at all. The log says nothing about <em>why</em> the pages changed.',
        {}, [TU + 'storage/pager.rs:3421', TU + 'storage/pager.rs:4562', TU + 'storage/pager.rs:1228-1259', TU + 'storage/sqlite3_ondisk.rs:481-500'], 'found');
    }
    var steps = rec.steps;
    rec.steps = null;
    return steps;
  };

  Turso.prototype.keys = function () {
    var self = this, out = [];
    (function walk(id) {
      var p = self.pages[id];
      if (p.leaf) { out = out.concat(p.keys); return; }
      p.children.forEach(function (c, i) { walk(c); if (i < p.keys.length) out.push(p.keys[i]); });
    })(this.root);
    return out;
  };
  Turso.prototype.validate = function () {
    var self = this, err = null, depth = null, keys = this.keys();
    for (var i = 1; i < keys.length; i++) if (keys[i - 1] >= keys[i]) return 'keys not ascending at ' + keys[i];
    (function visit(id, d) {
      var p = self.pages[id];
      if (p.keys.length > CAP) err = 'page ' + id + ' too full';
      if (p.leaf) { if (depth === null) depth = d; if (depth !== d) err = 'uneven depth'; return; }
      if (p.children.length !== p.keys.length + 1) err = 'bad fanout on ' + id;
      p.children.forEach(function (c) { visit(c, d + 1); });
    })(this.root, 0);
    return err;
  };

  // ============================ the two together ================================

  var STAGES = [
    { n: 1, name: 'Find the leaf' },
    { n: 2, name: 'Check uniqueness' },
    { n: 3, name: 'Make room' },
    { n: 4, name: 'Split or rebalance' },
    { n: 5, name: 'Fix the parent' },
    { n: 6, name: 'Make it durable' }
  ];
  var START_KEYS = [50, 10, 30, 20, 15, 35, 75, 45, 65, 25, 40];

  function Pair() {
    this.pg = new Pg();
    this.turso = new Turso();
    for (var i = 0; i < START_KEYS.length; i++) { this.pg.insert(START_KEYS[i], false); this.turso.insert(START_KEYS[i], false); }
  }
  Pair.prototype.save = function () { return clone({ pg: plain(this.pg), turso: plain(this.turso) }); };
  Pair.prototype.restore = function (s) { s = clone(s); assign(this.pg, s.pg); assign(this.turso, s.turso); };
  function plain(m) { var o = {}; for (var key in m) if (key !== 'rec' && typeof m[key] !== 'function') o[key] = m[key]; return o; }
  function assign(m, o) { for (var key in o) m[key] = o[key]; }

  /* Insert `key` into both models and merge the two recordings into one
   * timeline: stage by stage (and, when a split climbs, level by level),
   * PostgreSQL first, then Turso. Each merged step carries both pictures. */
  Pair.prototype.insert = function (key) {
    var before = { pg: this.pg.snapshot({}), turso: this.turso.snapshot() };
    var a = this.pg.insert(key, true), b = this.turso.insert(key, true);
    function order(s) { return s.stage <= 3 ? s.stage : s.stage === 6 ? 1000 : 4 + 2 * s.level + (s.stage - 4); }
    var slots = {};
    a.forEach(function (s) { s.engine = 'pg'; (slots[order(s)] = slots[order(s)] || []).push(s); });
    b.forEach(function (s) { s.engine = 'turso'; (slots[order(s)] = slots[order(s)] || []).push(s); });
    var cur = { pg: { state: before.pg, highlight: {}, wal: [], dirty: [], events: [], last: 0 },
      turso: { state: before.turso, highlight: {}, wal: [], dirty: [], events: [], last: 0 } };
    var out = [{ engine: null, stage: 0, key: key, caption: '', refs: [], lanes: clone(cur) }];
    out[0].caption = 'Before the insert of ' + k(key, 'inserted') + '. Both engines hold the same keys in differently shaped trees. PostgreSQL (left) keeps every key in a leaf; each page shows its dashed <b>high key</b> and its <b>right link</b>. Turso (right) is an index B-tree: keys in interior pages are entries too, and pages have no links. Step forward to follow the insert through both.';
    Object.keys(slots).map(Number).sort(function (x, y) { return x - y; }).forEach(function (o) {
      slots[o].forEach(function (s) {
        var c = cur[s.engine];
        c.state = s.state; c.highlight = s.highlight; c.wal = s.wal; c.dirty = s.dirty; c.last = s.stage;
        c.events = c.events.concat([{ text: s.stage + ' · ' + s.chip, state: s.chipState || undefined }]);
        var other = cur[s.engine === 'pg' ? 'turso' : 'pg'];
        other.highlight = {};
        out.push({ engine: s.engine, stage: s.stage, key: key, caption: s.caption, refs: s.refs, lanes: clone(cur) });
      });
    });
    out.ok = a.length > 0 && a[a.length - 1].stage === 6;
    return out;
  };

  var api = { Pg: Pg, Turso: Turso, Pair: Pair, STAGES: STAGES, START_KEYS: START_KEYS, CAP: CAP };
  root.CH30 = root.CH30 || {};
  for (var name in api) root.CH30[name] = api[name];
  if (typeof module !== 'undefined' && module.exports) module.exports = root.CH30;
})(typeof window !== 'undefined' ? window : globalThis);

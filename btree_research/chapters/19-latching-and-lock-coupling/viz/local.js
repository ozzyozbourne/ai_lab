/* Chapter 19: the JavaScript model behind the visualization.
 *
 *   Ch19.Tree   the B+tree of the chapter's programs (same handles, same splits)
 *   Ch19.Sim    two threads, each one operation cut into small steps; the page
 *               decides which thread takes its next step
 *
 * Protocols: 'mutex', 'rwlock', 'coupling' are ports of the Zig / Rust code.
 * 'optimistic' (version counters) exists only here: the chapter's programs do
 * not implement it.
 *
 * Classic script, no modules. The model never touches the DOM.
 */
(function () {
  'use strict';

  var ORDER = 4, MAX_KEYS = ORDER - 1;

  /* ------------------------------------------------------------------ tree */

  function Tree(capacity) {
    this.capacity = capacity;
    this.nodes = [{ leaf: true, keys: [], children: [], next: null, version: 0 }];
    this.root = 0;
    this.count = 0;
  }

  Tree.build = function (capacity, keys) {
    var t = new Tree(capacity);
    keys.forEach(function (k) { t.put(k); });
    return t;
  };

  Tree.prototype.clone = function () {
    var t = new Tree(this.capacity);
    t.nodes = JSON.parse(JSON.stringify(this.nodes));
    t.root = this.root;
    t.count = this.count;
    return t;
  };

  /** Number of separators <= key: a key equal to a separator goes right. */
  function childIndex(keys, key) {
    var i = 0;
    while (i < keys.length && keys[i] <= key) i++;
    return i;
  }
  Tree.childIndex = childIndex;

  Tree.prototype.childFor = function (id, key) {
    var n = this.nodes[id];
    return n.children[childIndex(n.keys, key)];
  };

  Tree.prototype.path = function (key) {
    var path = [], id = this.root;
    for (;;) {
      path.push(id);
      if (this.nodes[id].leaf) return path;
      id = this.childFor(id, key);
    }
  };

  Tree.prototype.has = function (key) {
    var path = this.path(key);
    return this.nodes[path[path.length - 1]].keys.indexOf(key) >= 0;
  };

  /**
   * The part of put that is the same under every protocol (insert.zig / insert.rs).
   * `path`: the nodes the caller owns, top-down, ending at the leaf.
   * Returns {error: 'OutOfNodes', need, left} without changing anything, or
   * {existed, splits: [{left, right, separator}], newRoot, changed: [ids]}.
   */
  Tree.prototype.insertAtLeaf = function (path, topIsRoot, key) {
    var nodes = this.nodes, leaf = nodes[path[path.length - 1]];
    if (leaf.keys.indexOf(key) >= 0) return { existed: true, splits: [], newRoot: null, changed: [] };

    var splits = 0;
    while (splits < path.length && nodes[path[path.length - 1 - splits]].keys.length === MAX_KEYS) splits++;
    var grows = splits === path.length;
    if (grows && !topIsRoot) throw new Error('the caller does not own the node that absorbs the separator');
    var need = splits + (grows ? 1 : 0);
    if (nodes.length + need > this.capacity) return { error: 'OutOfNodes', need: need, left: this.capacity - nodes.length };

    leaf.keys.push(key);
    leaf.keys.sort(function (a, b) { return a - b; });
    this.count++;
    var out = { existed: false, splits: [], newRoot: null, changed: [path[path.length - 1]] };

    var level = path.length;
    while (level > 0 && nodes[path[level - 1]].keys.length > MAX_KEYS) {
      level--;
      var leftId = path[level], left = nodes[leftId], rightId = nodes.length;
      var mid = Math.floor(left.keys.length / 2), right, separator;
      if (left.leaf) {
        // copy-up: the separator stays in the right leaf
        right = { leaf: true, keys: left.keys.splice(mid), children: [], next: left.next, version: 0 };
        left.next = rightId;
        separator = right.keys[0];
      } else {
        // push-up: the separator is in neither half
        separator = left.keys[mid];
        right = { leaf: false, keys: left.keys.slice(mid + 1), children: left.children.slice(mid + 1), next: null, version: 0 };
        left.keys.length = mid;
        left.children.length = mid + 1;
      }
      nodes.push(right);
      out.splits.push({ left: leftId, right: rightId, separator: separator });
      out.changed.push(leftId, rightId);
      if (level > 0) {
        var parent = nodes[path[level - 1]], i = childIndex(parent.keys, separator);
        parent.keys.splice(i, 0, separator);
        parent.children.splice(i + 1, 0, rightId);
        out.changed.push(path[level - 1]);
      } else {
        nodes.push({ leaf: false, keys: [separator], children: [leftId, rightId], next: null, version: 0 });
        this.root = nodes.length - 1;
        out.newRoot = this.root;
        out.changed.push(this.root);
      }
    }
    return out;
  };

  /** Single-threaded put (plain.zig): the whole path may change. */
  Tree.prototype.put = function (key) {
    return this.insertAtLeaf(this.path(key), true, key);
  };

  Tree.prototype.height = function () {
    return this.path(0).length;
  };

  /** Same text as dump.zig / dump.rs. */
  Tree.prototype.dump = function () {
    var self = this, h = this.height();
    var out = 'height ' + h + ', ' + this.count + ' keys, ' + this.nodes.length + ' nodes\n';
    function text(id) {
      var n = self.nodes[id];
      return '#' + id + (n.leaf ? '(' : '[') + n.keys.join(' ') + (n.leaf ? ')' : ']');
    }
    function level(id, down, st) {
      if (down === 0) return ' ' + text(id);
      var s = '';
      if (down === 1) { if (!st.first) s += ' |'; st.first = false; }
      self.nodes[id].children.forEach(function (c) { s += level(c, down - 1, st); });
      return s;
    }
    for (var depth = 1; depth < h; depth++) out += '  level ' + (depth - 1) + ':' + level(this.root, depth - 1, { first: true }) + '\n';
    var id = this.path(-1)[h - 1], leaves = [];
    while (id !== null) { leaves.push(text(id)); id = this.nodes[id].next; }
    return out + '  leaves : ' + leaves.join(' -> ') + '\n';
  };

  /* ------------------------------------------------------------------- sim */

  var NAMES = { mutex: 'global mutex', rwlock: 'global rwlock', coupling: 'latch coupling', optimistic: 'optimistic (versions)' };

  function Sim(tree, protocol, ops) {
    var self = this;
    this.tree = tree;
    this.protocol = protocol;
    this.latches = {};            // node id or 'G' -> {x: thread id | null, s: [thread ids]}
    this.changed = [];            // nodes touched by the last step (for highlighting)
    this.insertedKey = null;
    this.threads = {};
    this.order = Object.keys(ops);
    this.order.forEach(function (tid) {
      var t = { id: tid, op: ops[tid], events: [], done: false, result: null, restarts: 0, pending: null, gen: null };
      self.threads[tid] = t;
      t.gen = program(self, t);
      fetch(t);
    });
  }
  Sim.NAMES = NAMES;

  function fetch(t) {
    var r = t.gen.next();
    if (r.done) { t.done = true; t.pending = null; } else t.pending = r.value;
  }

  Sim.prototype.latch = function (node) {
    return this.latches[node] || (this.latches[node] = { x: null, s: [] });
  };

  /** Can thread `tid` have what `need` asks for right now? */
  Sim.prototype.grantable = function (need) {
    if (!need) return true;
    var l = this.latch(need.node);
    if (need.mode === 'X') return l.x === null && l.s.length === 0;
    return l.x === null;          // 'S', and 'V' = "read the version: wait while a writer holds the node"
  };

  Sim.prototype.holders = function (node) {
    var l = this.latch(node);
    return (l.x !== null ? [l.x] : []).concat(l.s);
  };

  Sim.prototype.canStep = function (tid) {
    var t = this.threads[tid];
    return !t.done && this.grantable(t.pending.need);
  };

  Sim.prototype.blocked = function (tid) {
    var t = this.threads[tid];
    return !t.done && !this.grantable(t.pending.need);
  };

  Sim.prototype.allDone = function () {
    var self = this;
    return this.order.every(function (tid) { return self.threads[tid].done; });
  };

  /** Runs the next step of one thread. Returns {tid, text, caption} or null if it cannot run. */
  Sim.prototype.advance = function (tid) {
    var t = this.threads[tid];
    if (!this.canStep(tid)) return null;
    var step = t.pending;
    this.changed = [];
    this.insertedKey = null;
    var caption = step.run();
    t.events.push({ text: step.text, state: step.chip || null });
    fetch(t);
    return { tid: tid, text: step.text, caption: caption, mark: step.mark || null, kind: t.op.kind };
  };

  Sim.prototype.lock = function (t, node, mode) {
    var l = this.latch(node);
    if (mode === 'X') l.x = t.id; else l.s.push(t.id);
  };

  Sim.prototype.unlock = function (t, node) {
    var l = this.latch(node);
    if (l.x === t.id) {
      l.x = null;
      // Releasing an exclusive latch bumps the node's version: this is what an
      // optimistic reader compares against.
      if (node !== 'G') this.tree.nodes[node].version++;
    } else l.s.splice(l.s.indexOf(t.id), 1);
  };

  /** Nodes thread `tid` holds, with modes: [{node, mode}]. */
  Sim.prototype.held = function (tid) {
    var out = [];
    for (var node in this.latches) {
      var l = this.latches[node];
      if (l.x === tid) out.push({ node: node === 'G' ? 'G' : +node, mode: 'X' });
      else if (l.s.indexOf(tid) >= 0) out.push({ node: node === 'G' ? 'G' : +node, mode: 'S' });
    }
    return out;
  };

  /* ----------------------------------------------------- thread programs */

  function k(v) { return '<b class="bt-k">' + v + '</b>'; }
  function n(id) { return '<b>#' + id + '</b>'; }
  function opText(op) { return op.kind + ' ' + op.key; }
  function who(t) { return '<b>' + t.id + '</b> (' + opText(t.op) + ')'; }

  function describeInsert(sim, t, r, key) {
    if (r.error) {
      t.result = 'OutOfNodes';
      return who(t) + ' needs ' + r.need + ' new node' + (r.need === 1 ? '' : 's') + ' but the table has ' + r.left +
        ' left: <b>OutOfNodes</b>. All the nodes are requested before the first change, so the tree is untouched.';
    }
    if (r.existed) { t.result = 'overwrote'; return who(t) + ' finds ' + k(key) + ' already in the leaf and overwrites its value. No node changes shape.'; }
    t.result = 'inserted';
    sim.changed = r.changed;
    sim.insertedKey = key;
    if (!r.splits.length) return who(t) + ' inserts ' + k(key) + ' into the leaf, which has room. Nothing above the leaf changes.';
    var s = who(t) + ' inserts ' + k(key) + '; the leaf overflows. ';
    r.splits.forEach(function (sp) {
      s += n(sp.left) + ' splits into ' + n(sp.left) + ' and the new ' + n(sp.right) + ', separator ' + k(sp.separator) + ' goes to the parent. ';
    });
    if (r.newRoot !== null) s += 'The root itself split: ' + n(r.newRoot) + ' becomes the new root and the root id is updated.';
    return s;
  }

  function program(sim, t) {
    if (sim.protocol === 'mutex' || sim.protocol === 'rwlock') return globalProgram(sim, t);
    if (sim.protocol === 'coupling') return t.op.kind === 'get' ? coupledGet(sim, t) : coupledPut(sim, t);
    return t.op.kind === 'get' ? optimisticGet(sim, t) : optimisticPut(sim, t);
  }

  function* globalProgram(sim, t) {
    var tree = sim.tree, key = t.op.key, mutex = sim.protocol === 'mutex';
    var mode = mutex || t.op.kind === 'put' ? 'X' : 'S';
    yield {
      text: mutex ? 'lock tree' : 'lock tree ' + mode, chip: mode === 'X' ? 'lock-exclusive' : 'lock-shared', need: { node: 'G', mode: mode }, mark: 'lock',
      run: function () {
        sim.lock(t, 'G', mode);
        return who(t) + ' takes the tree-wide ' + (mutex ? 'mutex. A mutex has one mode: whoever holds it is alone, reader or not.'
          : (mode === 'S' ? 'lock in <b>shared</b> mode. Other readers may share it; a writer must wait.' : 'lock in <b>exclusive</b> mode. Everybody else must wait.'));
      }
    };
    if (t.op.kind === 'get') {
      yield {
        text: 'descend, read leaf', atLeaf: true, mark: 'work',
        run: function () {
          var found = tree.has(key);
          t.result = found ? 'found' : 'not found';
          return who(t) + ' walks from the root to the leaf with no latch on any node: the tree-wide lock already keeps writers out. ' + k(key) + ' is ' + (found ? 'found' : 'not there') + '.';
        }
      };
    } else {
      yield {
        text: 'descend, insert', atLeaf: true, mark: 'work',
        run: function () {
          return describeInsert(sim, t, tree.put(key), key) + ' Under the tree-wide lock this needs no latch.';
        }
      };
    }
    yield {
      text: 'unlock tree', mark: 'unlock',
      run: function () { sim.unlock(t, 'G'); return who(t) + ' releases the tree-wide lock and is done.'; }
    };
  }

  /** latchRoot of coupled.zig: read the root id, latch that node, look again. */
  function* latchRoot(sim, t, mode, out) {
    var tree = sim.tree, chip = mode === 'X' ? 'lock-exclusive' : 'lock-shared';
    for (;;) {
      var id = null, ok = false;
      yield {
        text: 'read root id', mark: 'rootLoad',
        run: function () {
          id = tree.root;
          return who(t) + ' reads the root id: ' + n(id) + '. It holds no latch yet, so this answer can go stale at any moment.';
        }
      };
      yield {
        text: 'latch ' + mode + ' #' + id, chip: chip, need: { node: id, mode: mode }, afterRootLoad: true, mark: 'rootLatch',
        run: function () {
          sim.lock(t, id, mode);
          return who(t) + ' latches ' + n(id) + ' in ' + (mode === 'X' ? 'exclusive' : 'shared') + ' mode.';
        }
      };
      yield {
        text: 'check root id', mark: 'rootCheck',
        run: function () {
          ok = tree.root === id;
          if (ok) return who(t) + ' reads the root id again: still ' + n(id) + '. The root id only changes under the exclusive latch of the current root, and ' + t.id + ' now holds a latch on it, so this is the real root.';
          sim.unlock(t, id);
          t.restarts++;
          return who(t) + ' reads the root id again: it is now ' + n(tree.root) + ', not ' + n(id) + '. The root split while ' + t.id +
            ' was not looking; ' + n(id) + ' is only the left half of the tree. ' + t.id + ' unlatches it and <b>starts again</b>.';
        }
      };
      if (ok) { out.id = id; return; }
    }
  }

  function* coupledGet(sim, t) {
    var tree = sim.tree, key = t.op.key, cur = {};
    yield* latchRoot(sim, t, 'S', cur);
    var id = cur.id;
    while (!tree.nodes[id].leaf) {
      var child = tree.childFor(id, key), parent = id;
      yield {
        text: 'latch S #' + child, chip: 'lock-shared', need: { node: child, mode: 'S' }, mark: 'getChild',
        run: (function (child, parent) {
          return function () {
            sim.lock(t, child, 'S');
            return who(t) + ' latches the child ' + n(child) + ' while still holding ' + n(parent) + '. For this moment it holds two latches: nobody can split ' + n(child) + ' in between, because that would need the exclusive latch on it.';
          };
        })(child, parent)
      };
      yield {
        text: 'unlatch #' + parent, mark: 'getRelease',
        run: (function (child, parent) {
          return function () { sim.unlock(t, parent); return who(t) + ' releases the parent ' + n(parent) + '. A reader never needs more than the node it is on.'; };
        })(child, parent)
      };
      id = child;
    }
    yield {
      text: 'read leaf #' + id, atLeaf: true, mark: 'getLeaf',
      run: function () {
        var found = tree.nodes[id].keys.indexOf(key) >= 0;
        t.result = found ? 'found' : 'not found';
        return who(t) + ' searches leaf ' + n(id) + ': ' + k(key) + ' is ' + (found ? 'found' : 'not there') + '.';
      }
    };
    yield {
      text: 'unlatch #' + id, mark: 'getLeaf',
      run: function () { sim.unlock(t, id); return who(t) + ' releases ' + n(id) + ' and is done.'; }
    };
  }

  function* coupledPut(sim, t) {
    var tree = sim.tree, key = t.op.key, cur = {};
    yield* latchRoot(sim, t, 'X', cur);
    var held = [cur.id], topIsRoot = true, id = cur.id;
    while (!tree.nodes[id].leaf) {
      var child = tree.childFor(id, key);
      yield {
        text: 'latch X #' + child, chip: 'lock-exclusive', need: { node: child, mode: 'X' }, mark: 'putChild',
        run: (function (child) {
          return function () { sim.lock(t, child, 'X'); return who(t) + ' latches the child ' + n(child) + ' exclusively, still holding ' + held.map(n).join(', ') + '.'; };
        })(child)
      };
      var safe = tree.nodes[child].keys.length < MAX_KEYS;
      yield {
        text: safe ? '#' + child + ' safe: release above' : '#' + child + ' full: keep above', chip: safe ? null : 'split', mark: 'putSafe',
        run: (function (child, safe) {
          return function () {
            var len = tree.nodes[child].keys.length;
            if (safe) {
              var released = held.slice();
              released.forEach(function (h) { sim.unlock(t, h); });
              held = [child];
              topIsRoot = false;
              return who(t) + ': ' + n(child) + ' holds ' + len + ' of ' + MAX_KEYS + ' keys, so it is <b>safe</b>: it can take one more key without splitting, and nothing above it can change. ' +
                t.id + ' releases ' + released.map(n).join(', ') + '.';
            }
            held.push(child);
            return who(t) + ': ' + n(child) + ' is <b>full</b> (' + len + ' of ' + MAX_KEYS + ' keys). If it splits, its parent gets a new separator, so ' + t.id +
              ' must keep the latch' + (held.length > 2 ? 'es' : '') + ' above it: ' + held.slice(0, -1).map(n).join(', ') + '.';
          };
        })(child, safe)
      };
      id = child;
    }
    yield {
      text: 'insert in #' + id, chip: 'inserted', atLeaf: true, mark: 'putInsert',
      run: function () { return describeInsert(sim, t, tree.insertAtLeaf(held, topIsRoot, key), key); }
    };
    yield {
      text: 'unlatch ' + held.map(function (h) { return '#' + h; }).join(' '), mark: 'putRelease',
      run: function () {
        var all = held.slice();
        all.forEach(function (h) { sim.unlock(t, h); });
        return who(t) + ' releases ' + all.map(n).join(', ') + ' (top-down) and is done.';
      }
    };
  }

  /* Optimistic descent with version counters (not in the Zig / Rust code).
   * A reader takes no latch. It remembers each node's version, and before it
   * trusts what it read there it checks that the version is unchanged. */
  function* optimisticDescent(sim, t, out) {
    var tree = sim.tree, key = t.op.key;
    for (;;) {
      var id = null, v = null, fail = false;
      yield {
        text: 'read root id', mark: 'optRoot',
        run: function () { id = tree.root; return who(t) + ' reads the root id: ' + n(id) + '. No latch.'; }
      };
      yield {
        text: 'read version #' + id, need: { node: id, mode: 'V' }, afterRootLoad: true, mark: 'optRoot',
        run: function () {
          v = tree.nodes[id].version;
          if (tree.root !== id) { fail = true; t.restarts++; return who(t) + ' sees that the root id changed to ' + n(tree.root) + ' and <b>starts again</b>.'; }
          return who(t) + ' notes that ' + n(id) + ' is at version <b>v' + v + '</b> (and still the root). It writes nothing to shared memory: other threads cannot even tell it is here.';
        }
      };
      while (!fail && !tree.nodes[id].leaf) {
        var child = tree.childFor(id, key), cv = null;
        yield {
          text: 'read version #' + child, need: { node: child, mode: 'V' }, mark: 'optChild',
          run: (function (child) {
            return function () {
              cv = tree.nodes[child].version;
              return who(t) + ' picks child ' + n(child) + ' from ' + n(id) + ' and notes its version <b>v' + cv + '</b>.';
            };
          })(child)
        };
        yield {
          text: 'validate #' + id, mark: 'optValidate',
          run: (function (child, parent, pv) {
            return function () {
              var now = tree.nodes[parent].version;
              if (now !== pv || sim.latch(parent).x !== null) {
                fail = true;
                t.restarts++;
                return who(t) + ' checks ' + n(parent) + ' again: it was v' + pv + ', it is ' + (now !== pv ? 'v' + now : 'being written') + '. A writer changed it, so the child pointer ' + t.id +
                  ' read may be stale. Everything read so far is thrown away: <b>start again</b>.';
              }
              return who(t) + ' checks ' + n(parent) + ' again: still v' + pv + ', so the pointer to ' + n(child) + ' was valid when it was read. Move down.';
            };
          })(child, id, v)
        };
        if (!fail) { id = child; v = cv; }
      }
      if (!fail) { out.id = id; out.v = v; return; }
    }
  }

  function* optimisticGet(sim, t) {
    var tree = sim.tree, key = t.op.key;
    for (;;) {
      var cur = {}, ok = false;
      yield* optimisticDescent(sim, t, cur);
      var found = false;
      yield {
        text: 'read leaf #' + cur.id, atLeaf: true, mark: 'optLeaf',
        run: function () {
          found = tree.nodes[cur.id].keys.indexOf(key) >= 0;
          return who(t) + ' searches leaf ' + n(cur.id) + ' without a latch: ' + k(key) + ' looks ' + (found ? 'present' : 'absent') + '. Not trusted yet.';
        }
      };
      yield {
        text: 'validate #' + cur.id, mark: 'optLeaf',
        run: function () {
          var now = tree.nodes[cur.id].version;
          if (now !== cur.v || sim.latch(cur.id).x !== null) {
            t.restarts++;
            return who(t) + ' checks leaf ' + n(cur.id) + ' again: it was v' + cur.v + ', it is ' + (now !== cur.v ? 'v' + now : 'being written') + '. The answer may be wrong: <b>start again</b>.';
          }
          ok = true;
          t.result = found ? 'found' : 'not found';
          return who(t) + ' checks leaf ' + n(cur.id) + ' again: still v' + cur.v + '. The answer stands: ' + k(key) + ' is ' + (found ? 'found' : 'not there') + '. Done, without one write to shared memory.';
        }
      };
      if (ok) return;
    }
  }

  function* optimisticPut(sim, t) {
    var tree = sim.tree, key = t.op.key;
    for (;;) {
      var cur = {}, state = '';
      yield* optimisticDescent(sim, t, cur);
      yield {
        text: 'latch X #' + cur.id, chip: 'lock-exclusive', need: { node: cur.id, mode: 'X' }, mark: 'optWrite',
        run: function () { sim.lock(t, cur.id, 'X'); return who(t) + ' latches only the leaf ' + n(cur.id) + ' exclusively. The internal nodes were crossed without latches.'; }
      };
      yield {
        text: 'validate #' + cur.id, atLeaf: true, mark: 'optWrite',
        run: function () {
          var leaf = tree.nodes[cur.id];
          if (leaf.version !== cur.v) {
            sim.unlock(t, cur.id);
            leaf.version--;       // nothing was written: do not count this as a change
            t.restarts++;
            state = 'restart';
            return who(t) + ' checks the leaf version: it was v' + cur.v + ', it is v' + leaf.version + '. Another writer got here first: unlatch and <b>start again</b>.';
          }
          if (leaf.keys.indexOf(key) < 0 && leaf.keys.length === MAX_KEYS) {
            sim.unlock(t, cur.id);
            leaf.version--;
            state = 'fallback';
            return who(t) + ': the leaf is unchanged but <b>full</b>. A split has to change the parent, which ' + t.id +
              ' never latched. It gives up the cheap path, unlatches, and starts again with exclusive latch coupling from the root.';
          }
          state = 'write';
          return who(t) + ': the leaf is still v' + cur.v + ' and will not split. The descent is confirmed.';
        }
      };
      if (state === 'restart') continue;
      if (state === 'fallback') { yield* coupledPut(sim, t); return; }
      yield {
        text: 'insert in #' + cur.id, chip: 'inserted', mark: 'optWrite',
        run: function () { return describeInsert(sim, t, tree.insertAtLeaf([cur.id], false, key), key); }
      };
      yield {
        text: 'unlatch #' + cur.id, mark: 'optWrite',
        run: function () {
          sim.unlock(t, cur.id);
          return who(t) + ' releases ' + n(cur.id) + ', which bumps its version to v' + tree.nodes[cur.id].version + '. Any reader that looked at the old version will notice and retry.';
        }
      };
      return;
    }
  }

  /* --------------------------------------------------------------- views */

  /** Everything a page needs to draw the current state (plain data). */
  Sim.prototype.view = function () {
    var self = this, tree = this.tree, hl = { nodes: {}, keys: {} };
    function badges(id) {
      var l = self.latch(id), out = [];
      if (l.x !== null) out.push({ mode: 'exclusive', label: l.x + ':X' });
      l.s.forEach(function (tid) { out.push({ mode: 'shared', label: tid + ':S' }); });
      self.order.forEach(function (tid) {
        var t = self.threads[tid];
        if (!t.done && t.pending.need && t.pending.need.node === id && !self.grantable(t.pending.need)) {
          out.push({ mode: t.pending.need.mode === 'X' ? 'exclusive' : 'shared', label: tid + ':' + (t.pending.need.mode === 'V' ? 'v' : t.pending.need.mode) + '?', blocked: true });
        }
      });
      return out;
    }
    function build(id) {
      var nd = tree.nodes[id], b = badges(id);
      // In the optimistic protocol the label also shows the node's version.
      var m = { id: 'n' + id, keys: nd.keys.slice(), leaf: nd.leaf, meta: { label: '#' + id + (self.protocol === 'optimistic' ? ' v' + nd.version : '') } };
      if (b.length) m.meta.lock = b;
      if (nd.leaf) { if (nd.next !== null) m.next = 'n' + nd.next; } else m.children = nd.children.map(build);
      var l = self.latch(id);
      if (l.x !== null) hl.nodes['n' + id] = 'lock-exclusive';
      else if (l.s.length) hl.nodes['n' + id] = 'lock-shared';
      return m;
    }
    var model = build(tree.root);
    this.changed.forEach(function (id) { if (!hl.nodes['n' + id]) hl.nodes['n' + id] = 'split'; });
    if (this.insertedKey !== null) hl.keys['*:' + this.insertedKey] = 'inserted';
    var g = this.latch('G');
    var lanes = this.order.map(function (tid) {
      var t = self.threads[tid], bl = self.blocked(tid), held = self.held(tid);
      var status;
      if (t.done) status = 'finished: ' + t.result + (t.restarts ? ', restarted ' + t.restarts + ' time' + (t.restarts === 1 ? '' : 's') : '');
      else if (bl) {
        var nd = t.pending.need;
        status = 'waiting for ' + (nd.node === 'G' ? 'the tree-wide lock' : (nd.mode === 'V' ? 'the writer on #' + nd.node : nd.mode + ' on #' + nd.node)) + ', held by ' + self.holders(nd.node).join(', ');
      } else status = 'next: ' + t.pending.text;
      if (!t.done && held.length) {
        status += ' · holds ' + held.map(function (h) { return (h.node === 'G' ? 'tree' : '#' + h.node) + ' ' + h.mode; }).join(', ');
      }
      return { id: tid, label: tid + ' · ' + opText(t.op), state: t.done ? 'done' : bl ? 'blocked' : 'running', canStep: !t.done && !bl, status: status, events: t.events.slice() };
    });
    return {
      tree: model, hl: hl, lanes: lanes, global: { x: g.x, s: g.s.slice(), waiting: this.order.filter(function (tid) {
        var t = self.threads[tid];
        return !t.done && t.pending.need && t.pending.need.node === 'G' && !self.grantable(t.pending.need);
      }) }
    };
  };

  /**
   * The experiment of probe.zig / probe.rs: run A up to `freeze` ('atLeaf' or
   * 'afterRootLoad'), then B until it finishes or has to wait, then A to the
   * end, then B to the end. Returns {outcome, trace: [{tid, caption, view, note}]}.
   */
  Sim.probe = function (tree, protocol, aOp, bOp, freeze) {
    var sim = new Sim(tree, protocol, { T1: aOp, T2: bOp });
    var trace = [], outcome = 'finishes', a = sim.threads.T1, b = sim.threads.T2, initial = sim.view();
    function run(tid, until) {
      var t = sim.threads[tid];
      while (!t.done && sim.canStep(tid) && !(until && until(t))) {
        var r = sim.advance(tid);
        trace.push({ tid: tid, caption: r.caption, mark: r.mark, kind: r.kind, view: sim.view() });
      }
    }
    run('T1', function (t) { return !!t.pending[freeze]; });
    var frozenAt = trace.length;
    run('T2');
    if (!b.done) {
      var need = b.pending.need;
      outcome = need.node === 'G' ? 'waits' : 'waits at #' + need.node;
    }
    var bStoppedAt = trace.length;
    run('T1');
    run('T2');
    if (!a.done || !b.done) throw new Error('probe did not finish');
    return { outcome: outcome, trace: trace, frozenAt: frozenAt, bStoppedAt: bStoppedAt, sim: sim, initial: initial };
  };

  window.Ch19 = { Tree: Tree, Sim: Sim, ORDER: ORDER, MAX_KEYS: MAX_KEYS, CANONICAL: [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15] };
})();

/* Chapter 20: a JavaScript model of the B-link tree of the Zig and Rust programs.
 *
 * Two layers, one code path:
 *   - the READER and the WRITER are small state machines that do one atomic
 *     piece of work per call (one node visit, step 1 of a split, step 2 ...),
 *     exactly the pieces between which the real code holds no latch or lets
 *     other threads in;
 *   - BLink.Tree.put / lookup simply run one machine to the end. The page's
 *     self-tests compare their result with the output of the programs, so the
 *     pictures cannot drift away from the code.
 *
 * All state is plain data (no prototypes, no cycles), so a snapshot is a deep
 * copy and stepping backwards is free.
 *
 * Differences from the programs: no node-table limit (nodes are appended to an
 * array) and no real latches (a latch is just "the writer holds node n").
 */
(function (global) {
  'use strict';

  /* ------------------------------------------------------------ tree data */
  function mkNode(id, level) {
    return { id: id, level: level, keys: [], vals: level === 0 ? [] : null, kids: level > 0 ? [] : null,
             high: null, right: null, inc: false };
  }
  function newTree(order) {
    return { order: order, nodes: [mkNode(0, 0)], root: 0, height: 1, heads: [0], count: 0 };
  }
  function alloc(t, level) { var n = mkNode(t.nodes.length, level); t.nodes.push(n); return n.id; }
  function lowerBound(keys, key) { var i = 0; while (i < keys.length && keys[i] < key) i++; return i; }
  function upperBound(keys, key) { var i = 0; while (i < keys.length && keys[i] <= key) i++; return i; }
  /** The key belongs to a node further right: the one comparison that detects a split. */
  function beyond(n, key) { return n.high !== null && key >= n.high; }

  /** STEP 1 of a split (insert.zig: halfSplit). */
  function halfSplit(t, leftId, rightId) {
    var l = t.nodes[leftId], r = t.nodes[rightId], mid = Math.floor(l.keys.length / 2), sep;
    if (l.level === 0) {
      r.keys = l.keys.splice(mid); r.vals = l.vals.splice(mid); sep = r.keys[0];
    } else {
      sep = l.keys[mid];
      r.keys = l.keys.splice(mid + 1); l.keys.pop(); r.kids = l.kids.splice(mid + 1);
    }
    r.high = l.high; r.right = l.right;
    l.high = sep; l.right = rightId; l.inc = true;
    return sep;
  }

  /** STEP 2 for one split (insert.zig: insertParent, one level of it).
   *  Returns the id of the parent if the parent itself was half split and still
   *  needs ITS step 2, else null. Appends what happened to `ev`. */
  function insertParentOnce(t, leftId, stack, abandon, ev) {
    var left = t.nodes[leftId], level = left.level, sep = left.high, rightId = left.right;
    var pid = stack[level + 1];
    if (pid === undefined || pid === null) {
      if (t.root === leftId) {
        var nr = alloc(t, level + 1), root = t.nodes[nr];
        root.keys = [sep]; root.kids = [leftId, rightId];
        t.heads[level + 1] = nr; t.height = level + 2; left.inc = false; t.root = nr;
        ev.push({ type: 'new-root', node: nr, left: leftId, right: rightId, sep: sep });
        return null;
      }
      pid = t.heads[level + 1];
    }
    var p, slot;
    for (;;) {
      p = t.nodes[pid];
      if (p.inc) { finishFully(t, pid, stack, abandon, ev); continue; }
      slot = p.kids.indexOf(leftId);
      if (slot >= 0) break;
      if (p.right === null) throw new Error('downlink of a split node not found');
      pid = p.right;
    }
    var pr = p.keys.length === t.order - 1 ? alloc(t, level + 1) : null;
    p.keys.splice(slot, 0, sep); p.kids.splice(slot + 1, 0, rightId);
    left.inc = false;
    ev.push({ type: 'downlink', parent: pid, left: leftId, right: rightId, sep: sep });
    if (pr === null) return null;
    var psep = halfSplit(t, pid, pr);
    ev.push({ type: 'half-split', left: pid, right: pr, sep: psep });
    return abandon ? null : pid;
  }
  /** Finish a split somebody else left half-done (insert.zig: finishSplit). */
  function finishFully(t, id, stack, abandon, ev) {
    var cur = id;
    while (cur !== null) cur = insertParentOnce(t, cur, stack, abandon, ev);
  }

  /* --------------------------------------------------------- text helpers */
  function K(v, st) { return '<b class="bt-k' + (st ? ' s-' + st : '') + '">' + v + '</b>'; }
  function N(id) { return '<b>#' + id + '</b>'; }
  function nid(id) { return 'n' + id; }
  function nodeText(n) { return '#' + n.id + (n.level === 0 ? '(' : '[') + n.keys.join(' ') + (n.level === 0 ? ')' : ']'); }
  function describe(t, ev) {
    return ev.map(function (e) {
      if (e.type === 'downlink') return 'downlink (' + K(e.sep) + ' → ' + N(e.right) + ') inserted into ' + N(e.parent) + ', flag on ' + N(e.left) + ' cleared';
      if (e.type === 'new-root') return 'new root ' + N(e.node) + ' built above ' + N(e.left) + ' and ' + N(e.right) + ', flag on ' + N(e.left) + ' cleared';
      return N(e.left) + ' overflowed and was half split into ' + N(e.left) + ' and ' + N(e.right);
    }).join('; ');
  }
  function hlOfEvents(ev, hl) {
    ev.forEach(function (e) {
      if (e.type === 'downlink') { hl.nodes[nid(e.parent)] = 'active'; hl.keys[nid(e.parent) + ':' + e.sep] = 'inserted'; hl.edges[nid(e.parent) + '>' + nid(e.right)] = 'active'; }
      if (e.type === 'new-root') { hl.nodes[nid(e.node)] = 'active'; hl.keys[nid(e.node) + ':' + e.sep] = 'inserted'; }
      if (e.type === 'half-split') { hl.nodes[nid(e.left)] = 'split'; hl.nodes[nid(e.right)] = 'split'; }
    });
  }
  function emptyHl() { return { nodes: {}, keys: {}, edges: {}, links: {} }; }

  /* --------------------------------------------------------------- reader */
  function newReader(t, key, follow) {
    return { key: key, follow: follow, next: t.root, done: false, value: null, missed: false, moves: 0, visited: 0, events: [] };
  }
  /** Is `key` really in the tree? (Walks the leaf level; used only to label a wrong answer.) */
  function present(t, key) {
    for (var id = t.heads[0]; id !== null; id = t.nodes[id].right) {
      var n = t.nodes[id], i = n.keys.indexOf(key);
      if (i >= 0) return { leaf: id, value: n.vals[i] };
    }
    return null;
  }
  /** One node visit under one shared latch (search.zig: Descent.step). */
  function readerStep(S) {
    var t = S.t, r = S.reader, n = t.nodes[r.next], hl = emptyHl(), out = { who: 'R', hl: hl };
    r.visited++;
    hl.cursor = { node: nid(n.id), label: r.key };
    hl.nodes[nid(n.id)] = 'active';
    if (r.follow && beyond(n, r.key)) {
      hl.keys[nid(n.id) + ':high'] = 'compare'; hl.links[nid(n.id)] = 'active';
      r.moves++; r.next = n.right;
      r.events.push({ text: '#' + n.id + ' → right', state: 'compare' });
      out.kind = 'r-right';
      out.caption = 'Reader latches ' + N(n.id) + ' and looks at the high key first: ' + K(r.key, 'compare') + ' ≥ ' + K(n.high, 'compare') +
        '. Every key from ' + n.high + ' upwards was moved out of this node by a split, so the reader releases the latch and follows the <b>right link</b> to ' + N(n.right) + '.';
      out.log = 'reader: #' + n.id + ', ' + r.key + ' ≥ high key ' + n.high + ', right link to #' + n.right;
      return out;
    }
    var ignored = !r.follow && beyond(n, r.key) ? ' It does not look at the high key ' + K(n.high) + ', which would have told it that ' + r.key + ' is not here any more.' : '';
    if (n.level > 0) {
      var child = n.kids[upperBound(n.keys, r.key)];
      hl.edges[nid(n.id) + '>' + nid(child)] = 'active';
      r.next = child;
      r.events.push({ text: '#' + n.id + ' ↓', state: 'lock-shared' });
      out.kind = 'r-down';
      out.caption = 'Reader takes a shared latch on ' + N(n.id) + ', finds that ' + K(r.key) + ' belongs under child ' + N(child) +
        ', and <b>releases the latch before going there</b>.' + ignored + ' Until its next step it holds no latch at all, only the number ' + child + '.';
      out.log = 'reader: #' + n.id + ', downlink to #' + child;
      return out;
    }
    var i = n.keys.indexOf(r.key);
    r.done = true;
    out.kind = 'r-leaf';
    if (i >= 0) {
      r.value = n.vals[i];
      hl.keys[nid(n.id) + ':' + r.key] = 'found';
      r.events.push({ text: '#' + n.id + ' found', state: 'found' });
      out.caption = 'Reader latches leaf ' + N(n.id) + (r.follow ? (n.high === null ? ' (no high key: the rightmost leaf)' : ' (' + r.key + ' < high key ' + n.high + ', so this is the right leaf)') : '') +
        ' and finds ' + K(r.key, 'found') + '.';
      out.log = { html: 'reader: #' + n.id + ', found ' + r.key, state: 'found' };
      return out;
    }
    var where = present(t, r.key);
    if (where) {
      r.missed = true;
      hl.nodes[nid(n.id)] = 'deleted'; hl.keys[nid(where.leaf) + ':' + r.key] = 'deleted';
      r.events.push({ text: '#' + n.id + ' MISSED', state: 'deleted' });
      out.caption = 'Reader searches leaf ' + N(n.id) + ' and does not find ' + K(r.key, 'deleted') + '.' + ignored +
        ' It answers "not found", but the key <b>is in the tree</b>, in ' + N(where.leaf) + '. Nothing crashed: without right links the answer is silently wrong.';
      out.log = { html: 'reader: #' + n.id + ', ' + r.key + ' MISSED (it is in #' + where.leaf + ')', state: 'deleted' };
      return out;
    }
    r.events.push({ text: '#' + n.id + ' absent', state: 'dim' });
    out.caption = 'Reader latches leaf ' + N(n.id) + '. ' + K(r.key) + ' is not there, and it is nowhere else either: the key is not in the tree.';
    out.log = 'reader: #' + n.id + ', ' + r.key + ' is not in the tree';
    return out;
  }

  /* --------------------------------------------------------------- writer */
  function newWriter(t, key, value, abandon) {
    return { key: key, value: value, abandon: !!abandon, phase: 'descend', at: t.root, held: null, stack: {}, done: false, events: [] };
  }
  /** One atomic piece of a put (insert.zig: put / moveRight / halfSplit / insertParent). */
  function writerStep(S) {
    var t = S.t, w = S.writer, hl = emptyHl(), out = { who: 'W', hl: hl }, ev = [], n;
    if (w.phase === 'descend') {
      n = t.nodes[w.at];
      hl.nodes[nid(n.id)] = 'active';
      if (n.inc) {
        var orphan = n.right;
        finishFully(t, n.id, w.stack, w.abandon, ev);
        hlOfEvents(ev, hl);
        w.events.push({ text: 'finish #' + n.id, state: 'inserted' });
        out.kind = 'w-finish';
        out.caption = 'Writer latches ' + N(n.id) + ' and sees <b>INCOMPLETE_SPLIT</b>: an earlier writer did step 1 and never did step 2, so ' + N(orphan) +
          ' has no downlink. A writer never walks past that. It finishes the other writer\'s split first: ' + describe(t, ev) + '.';
        out.log = { html: 'writer: finishes the split of #' + n.id, state: 'inserted' };
        return out;
      }
      if (beyond(n, w.key)) {
        hl.keys[nid(n.id) + ':high'] = 'compare'; hl.links[nid(n.id)] = 'active';
        w.at = n.right;
        w.events.push({ text: '#' + n.id + ' → right', state: 'compare' });
        out.kind = 'w-right';
        out.caption = 'Writer latches ' + N(n.id) + ': ' + K(w.key, 'compare') + ' ≥ high key ' + K(n.high, 'compare') + ', so it releases the latch and moves right to ' + N(n.right) + ', exactly like a reader.';
        out.log = 'writer: #' + n.id + ', right link to #' + n.right;
        return out;
      }
      if (n.level > 0) {
        w.stack[n.level] = n.id;
        var child = n.kids[upperBound(n.keys, w.key)];
        hl.edges[nid(n.id) + '>' + nid(child)] = 'active';
        w.at = child;
        w.events.push({ text: '#' + n.id + ' ↓', state: 'lock-shared' });
        out.kind = 'w-down';
        out.caption = 'Writer takes a shared latch on ' + N(n.id) + ', picks child ' + N(child) + ' for ' + K(w.key) +
          ', remembers ' + N(n.id) + ' as the probable parent, and releases the latch. Going down it holds one latch at a time, like a reader.';
        out.log = 'writer: #' + n.id + ', downlink to #' + child;
        return out;
      }
      w.held = n.id; w.phase = 'leaf';
      hl.nodes[nid(n.id)] = 'lock-exclusive';
      w.events.push({ text: 'X #' + n.id, state: 'lock-exclusive' });
      out.kind = 'w-latch';
      out.caption = 'Writer takes the <b>exclusive</b> latch on leaf ' + N(n.id) + ' and keeps it. A reader that wants ' + N(n.id) + ' now has to wait; every other node is free.';
      out.log = { html: 'writer: exclusive latch on #' + n.id, state: 'lock-exclusive' };
      return out;
    }
    if (w.phase === 'leaf') {
      n = t.nodes[w.held];
      var i = lowerBound(n.keys, w.key);
      if (n.keys[i] === w.key) {
        n.vals[i] = w.value;
        hl.keys[nid(n.id) + ':' + w.key] = 'inserted';
        finishWriter(w, 'overwrite ' + w.key, 'inserted');
        out.kind = 'w-insert';
        out.caption = K(w.key, 'inserted') + ' is already in ' + N(n.id) + ': the writer overwrites its value and releases the latch.';
        out.log = 'writer: overwrote ' + w.key + ' in #' + n.id;
        return out;
      }
      if (n.keys.length < t.order - 1) {
        n.keys.splice(i, 0, w.key); n.vals.splice(i, 0, w.value); t.count++;
        hl.keys[nid(n.id) + ':' + w.key] = 'inserted';
        finishWriter(w, 'insert ' + w.key, 'inserted');
        out.kind = 'w-insert';
        out.caption = N(n.id) + ' has room: the writer inserts ' + K(w.key, 'inserted') + ' and releases the latch. No split, nothing else to do.';
        out.log = { html: 'writer: inserted ' + w.key + ' into #' + n.id, state: 'inserted' };
        return out;
      }
      var rightId = alloc(t, 0);
      n.keys.splice(i, 0, w.key); n.vals.splice(i, 0, w.value); t.count++;
      var sep = halfSplit(t, n.id, rightId), r = t.nodes[rightId];
      hl.nodes[nid(n.id)] = 'split'; hl.nodes[nid(rightId)] = 'split';
      hl.keys['*:' + w.key] = 'inserted'; hl.links[nid(n.id)] = 'active';
      w.phase = w.abandon ? 'abandon' : 'step2';
      w.events.push({ text: 'step 1: #' + n.id + ' | #' + rightId, state: 'split' });
      out.kind = 'w-step1';
      out.caption = N(n.id) + ' is full, so it splits. <b>Step 1</b>, under the latch on ' + N(n.id) + ' alone: the new node ' + N(rightId) + ' receives the upper half (' + r.keys.join(' ') +
        ') together with the old high key and right link of ' + N(n.id) + '; then ' + N(n.id) + ' gets high key ' + K(sep, 'compare') + ', a right link to ' + N(rightId) +
        ' and the INCOMPLETE_SPLIT flag. The parent has not been touched, and the tree is already correct: ' + N(rightId) + ' is one right link away.';
      out.log = { html: 'writer: step 1, #' + n.id + ' split into #' + n.id + ' and #' + rightId + ' (high key ' + sep + ')', state: 'split' };
      return out;
    }
    if (w.phase === 'abandon') {
      n = t.nodes[w.held];
      hl.nodes[nid(n.id)] = 'split'; hl.nodes[nid(n.right)] = 'split';
      finishWriter(w, 'stopped', 'deleted');
      out.kind = 'w-abandon';
      out.caption = 'The writer <b>stops here</b>, between the two steps (think of a crash, or an error such as "disk full" before step 2). Its latch on ' + N(n.id) +
        ' is gone. ' + N(n.right) + ' has no downlink, and the flag on ' + N(n.id) + ' says so. This is a legal state of the tree.';
      out.log = { html: 'writer: stopped after step 1; #' + n.right + ' has no downlink', state: 'deleted' };
      return out;
    }
    // phase 'step2': the writer holds w.held (flagged) exclusively.
    var leftId = w.held, rightOf = t.nodes[leftId].right;
    var next = insertParentOnce(t, leftId, w.stack, w.abandon, ev);
    hlOfEvents(ev, hl);
    var last = ev[ev.length - 1], main = ev.filter(function (e) { return e.type !== 'half-split'; }).pop();
    w.events.push({ text: 'step 2: ' + (main.type === 'new-root' ? 'new root #' + main.node : 'downlink in #' + main.parent), state: 'inserted' });
    out.kind = main.type === 'new-root' ? 'w-root' : 'w-step2';
    out.caption = '<b>Step 2</b>: ' + (main.type === 'new-root'
      ? N(leftId) + ' was the root, so there is no parent to insert into. The writer builds a new root ' + N(main.node) + ' with the separator ' + K(main.sep, 'inserted') +
        ' above ' + N(leftId) + ' and ' + N(rightOf) + ', clears the flag and swings the root pointer.'
      : 'still holding ' + N(leftId) + ', the writer latches the parent ' + N(main.parent) + ', inserts the downlink (' + K(main.sep, 'inserted') + ' → ' + N(rightOf) +
        ') right after the downlink to ' + N(leftId) + ', and clears the flag on ' + N(leftId) + '. Flag and downlink change together, under the parent\'s latch.');
    out.log = { html: 'writer: step 2, ' + describe(t, [main]), state: 'inserted' };
    if (last.type === 'half-split') {
      out.caption += ' That made ' + N(last.left) + ' overfull, so the same thing happens one level up: step 1 splits it into ' + N(last.left) + ' and ' + N(last.right) + '.';
      if (next === null) {      // abandon mode: the parent's split is left half-done
        out.caption += ' The writer stops there; that split stays incomplete.';
        finishWriter(w, 'stopped', 'deleted');
      } else {
        w.held = next;
        out.caption += ' The writer lets go of ' + N(leftId) + ' and keeps ' + N(next) + ' for its step 2.';
      }
      return out;
    }
    out.caption += ' The writer releases its latches. The split is complete.';
    finishWriter(w, null);
    return out;
  }
  function finishWriter(w, text, state) {
    if (text) w.events.push({ text: text, state: state });
    w.held = null; w.done = true; w.phase = 'done';
  }

  /* ------------------------------------------------------------ simulator */
  function blocked(S, who) {
    return who === 'R' && !!S.reader && !S.reader.done && !!S.writer && S.writer.held !== null && S.writer.held === S.reader.next;
  }
  function canStep(S, who) {
    var op = who === 'R' ? S.reader : S.writer;
    return !!op && !op.done && !blocked(S, who);
  }
  /** Advance one thread by one atomic step. Mutates S; returns {caption, hl, log, kind, who}. */
  function advance(S, who) {
    if (!canStep(S, who)) throw new Error(who + ' cannot step');
    return who === 'R' ? readerStep(S) : writerStep(S);
  }

  /* ----------------------------------------------- sequential API (tests) */
  function Tree(order) { if (!(this instanceof Tree)) return new Tree(order); this.t = newTree(order || 4); }
  Tree.prototype.put = function (key, opts) {
    var S = { t: this.t, reader: null, writer: newWriter(this.t, key, key * 100, opts && opts.abandon) };
    while (!S.writer.done) writerStep(S);
    return this;
  };
  Tree.prototype.lookup = function (key, follow) {
    var S = { t: this.t, writer: null, reader: newReader(this.t, key, follow !== false) };
    while (!S.reader.done) readerStep(S);
    return { value: S.reader.value, moves: S.reader.moves, visited: S.reader.visited };
  };
  Tree.prototype.dump = function () { return dump(this.t); };
  Tree.prototype.incomplete = function () { return this.t.nodes.filter(function (n) { return n.inc; }).length; };

  /** Same text as dump.zig / dump.rs. */
  function dump(t) {
    var out = 'height ' + t.height + ', ' + t.count + ' keys, ' + t.nodes.length + ' nodes\n';
    for (var level = t.height - 1; level >= 0; level--) {
      out += '  level ' + level + ':';
      var leftInc = false;
      for (var id = t.heads[level]; id !== null; id = t.nodes[id].right) {
        var n = t.nodes[id];
        out += ' ' + nodeText(n) + (n.high !== null ? '<' + n.high : '') + (n.inc ? ' {incomplete}' : '') + (leftInc ? ' {no downlink}' : '') + (n.right !== null ? ' ->' : '');
        leftInc = n.inc;
      }
      out += '\n';
    }
    return out;
  }

  global.BLink = {
    Tree: Tree, newTree: newTree, newReader: newReader, newWriter: newWriter,
    canStep: canStep, blocked: blocked, advance: advance, dump: dump, present: present, nodeText: nodeText
  };
})(typeof window !== 'undefined' ? window : globalThis);

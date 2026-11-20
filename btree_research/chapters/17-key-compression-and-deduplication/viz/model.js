/* Chapter 17 visualization model: a JavaScript port of zig/src/tree.zig
 * (same byte accounting, same split-point rule, same deduplication pass), plus
 * a recorder that turns each operation into BTViz steps.
 *
 * Keys are restricted to printable ASCII by the page, so JavaScript string
 * comparison (UTF-16 code units) equals byte comparison.
 *
 * Classic script; also loadable from node for testing (module.exports).
 */
(function (root) {
  'use strict';

  var HEADER = 8, SLOT = 2, LEN = 2, TID = 6, CHILD = 4, COUNT = 2;
  // The largest TID that fits in the 6 bytes charged for one (max_tid in the
  // Zig and Rust programs). Well below 2^53, so a JS number holds it exactly.
  var MAX_TID = Math.pow(2, 48) - 1;
  function validTid(tid) { return typeof tid === 'number' && Math.floor(tid) === tid && tid >= 0 && tid <= MAX_TID; }

  /* ---- order --------------------------------------------------------- */

  // Key bytes first, then TID; a null TID (truncated) is minus infinity.
  function compareTuple(aKey, aTid, bKey, bTid) {
    if (aKey < bKey) return -1;
    if (aKey > bKey) return 1;
    if (aTid === null) return bTid === null ? 0 : -1;
    if (bTid === null) return 1;
    return aTid < bTid ? -1 : aTid > bTid ? 1 : 0;
  }

  function commonPrefixLen(a, b) {
    var n = Math.min(a.length, b.length), i = 0;
    while (i < n && a[i] === b[i]) i++;
    return i;
  }

  // lastLeft <= separator < firstRight
  function separator(truncate, lastLeft, firstRight) {
    if (truncate) {
      var n = commonPrefixLen(lastLeft.key, firstRight.key);
      if (n < firstRight.key.length) return { key: firstRight.key.slice(0, n + 1), tid: null };
    }
    return { key: lastLeft.key, tid: lastLeft.tids[lastLeft.tids.length - 1] };
  }

  /* ---- byte accounting ----------------------------------------------- */

  function sepSize(s) { return s ? SLOT + LEN + s.key.length + (s.tid !== null ? TID : 0) : 0; }
  function pivotSize(s) { return sepSize(s) + CHILD; }
  function leafCellSize(keyLen, nTids) {
    return SLOT + LEN + keyLen + (nTids === 1 ? TID : COUNT + nTids * TID);
  }
  function cellsSize(cells) {
    var t = 0;
    cells.forEach(function (c) { t += leafCellSize(c.key.length, c.tids.length); });
    return t;
  }
  function leafBytes(low, high, cells) { return HEADER + sepSize(low) + sepSize(high) + cellsSize(cells); }
  var INTERNAL_FIXED = HEADER + SLOT + LEN + CHILD;
  function internalBytes(low, high, seps) {
    var t = INTERNAL_FIXED + sepSize(low) + sepSize(high);
    seps.forEach(function (s) { t += pivotSize(s); });
    return t;
  }
  function usedBytes(p) {
    return p.leaf ? leafBytes(p.low, p.high, p.cells) : internalBytes(p.low, p.high, p.seps);
  }

  /* ---- text ---------------------------------------------------------- */

  function sepText(s, infinity) {
    if (!s) return infinity;
    return '"' + s.key + '"' + (s.tid !== null ? '@' + s.tid : '');
  }
  function cellText(c) {
    return c.key + '@' + (c.tids.length === 1 ? c.tids[0] : '[' + c.tids.join(',') + ']');
  }
  function tenths(num, den) {
    if (den === 0) return '-';
    var x = Math.floor((num * 10 + Math.floor(den / 2)) / den);
    return Math.floor(x / 10) + '.' + (x % 10);
  }
  function pad(s, w, left) {
    s = String(s);
    while (s.length < w) s = left ? s + ' ' : ' ' + s;
    return s;
  }
  function clone(v) { return JSON.parse(JSON.stringify(v)); }

  /* ---- the tree ------------------------------------------------------ */

  function Tree(cfg) {
    if (!(this instanceof Tree)) return new Tree(cfg);
    this.cfg = { pageSize: cfg.pageSize || 256, truncate: cfg.truncate !== false, dedup: cfg.dedup !== false };
    this.pages = [{ id: 0, leaf: true, low: null, high: null, right: null, cells: [], seps: [], children: [] }];
    this.root = 0;
    this.count = 0;
    this.counters = { leafSplits: 0, internalSplits: 0, dedupPasses: 0, postingSwaps: 0 };
  }

  Tree.prototype.maxCell = function () { return Math.floor((this.cfg.pageSize - HEADER) / 6); };
  Tree.prototype.maxKeyLen = function () { return this.maxCell() - (SLOT + LEN + TID + CHILD); };
  Tree.prototype.maxPostingTids = function (keyLen) {
    return Math.floor((this.maxCell() - (SLOT + LEN + COUNT) - keyLen) / TID);
  };

  // Number of separators strictly below the tuple.
  function childIndex(page, key, tid) {
    var lo = 0, hi = page.seps.length;
    while (lo < hi) {
      var mid = lo + ((hi - lo) >> 1), s = page.seps[mid];
      if (compareTuple(s.key, s.tid, key, tid) < 0) lo = mid + 1; else hi = mid;
    }
    return lo;
  }

  Tree.prototype.findLeaf = function (key, tid, path) {
    var id = this.root;
    for (;;) {
      var page = this.pages[id];
      if (page.leaf) return id;
      var i = childIndex(page, key, tid);
      if (path) path.push({ page: id, childIndex: i });
      id = page.children[i];
    }
  };

  function leafLowerBound(cells, key, tid) {
    var lo = 0, hi = cells.length;
    while (lo < hi) {
      var mid = lo + ((hi - lo) >> 1);
      if (compareTuple(cells[mid].key, cells[mid].tids[0], key, tid) < 0) lo = mid + 1; else hi = mid;
    }
    return lo;
  }

  function locate(cells, key, tid) {
    var i = leafLowerBound(cells, key, tid);
    if (i < cells.length && cells[i].tids[0] === tid && cells[i].key === key) return { kind: 'found', cell: i, pos: 0 };
    if (i > 0 && cells[i - 1].key === key) {
      var tids = cells[i - 1].tids;
      if (tid <= tids[tids.length - 1]) {
        var pos = 0;
        while (tids[pos] < tid) pos++;
        if (tids[pos] === tid) return { kind: 'found', cell: i - 1, pos: pos };
        return { kind: 'inside', cell: i - 1, pos: pos };
      }
    }
    return { kind: 'insertAt', at: i };
  }

  function swapIntoPosting(tids, pos, tid) {
    var evicted = tids.pop();
    tids.splice(pos, 0, tid);
    return evicted;
  }

  Tree.prototype.get = function (key) {
    var id = this.findLeaf(key, 0, null), out = [];
    var cell = leafLowerBound(this.pages[id].cells, key, 0);
    while (id !== null) {
      var p = this.pages[id];
      for (; cell < p.cells.length; cell++) {
        if (p.cells[cell].key !== key) return out;
        out = out.concat(p.cells[cell].tids);
      }
      id = p.right;
      cell = 0;
    }
    return out;
  };

  Tree.prototype.dedupPass = function (items) {
    var out = [], self = this;
    items.forEach(function (c) {
      var last = out[out.length - 1];
      if (last && last.key === c.key && last.tids.length + c.tids.length <= self.maxPostingTids(c.key.length)) {
        last.tids = last.tids.concat(c.tids);
      } else {
        out.push({ key: c.key, tids: c.tids.slice() });
      }
    });
    return out;
  };

  // Among cuts that leave both halves between 40% and 60% of the cell bytes:
  // the shortest separator; otherwise the most balanced cut.
  Tree.prototype.chooseLeafSplit = function (low, high, items) {
    var total = cellsSize(items), best = -1, bestScore = null, left = 0, candidates = [];
    for (var cut = 1; cut < items.length; cut++) {
      left += leafCellSize(items[cut - 1].key.length, items[cut - 1].tids.length);
      var sep = separator(this.cfg.truncate, items[cut - 1], items[cut]);
      var fence = sepSize(sep);
      if (HEADER + sepSize(low) + fence + left > this.cfg.pageSize) continue;
      if (HEADER + fence + sepSize(high) + (total - left) > this.cfg.pageSize) continue;
      var imbalance = Math.abs(2 * left - total);
      var inWindow = imbalance * 5 <= total;
      var score = inWindow ? [0, fence, imbalance] : [1, 0, imbalance];
      if (inWindow) candidates.push({ cut: cut, sep: sep });
      if (bestScore === null || lexLess(score, bestScore)) { best = cut; bestScore = score; }
    }
    return { cut: best, candidates: candidates };
  };
  function lexLess(a, b) {
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return a[i] < b[i];
    return false;
  }

  Tree.prototype.chooseInternalSplit = function (low, high, seps) {
    var total = 0, best = -1, bestImbalance = 0, left = 0;
    seps.forEach(function (s) { total += pivotSize(s); });
    for (var m = 0; m < seps.length; m++) {
      var s = seps[m], right = total - left - pivotSize(s);
      var fits = INTERNAL_FIXED + sepSize(low) + sepSize(s) + left <= this.cfg.pageSize &&
                 INTERNAL_FIXED + sepSize(s) + sepSize(high) + right <= this.cfg.pageSize;
      var imbalance = Math.abs(left - right);
      if (fits && (best < 0 || imbalance < bestImbalance)) { best = m; bestImbalance = imbalance; }
      left += pivotSize(s);
    }
    return best;
  };

  /* ---- snapshots and explanations for the recorder -------------------- */

  Tree.prototype.snapshot = function (overrides) {
    var pages = clone(this.pages);
    if (overrides) Object.keys(overrides).forEach(function (id) { pages[id].cells = clone(overrides[id]); });
    pages.forEach(function (p) { p.used = usedBytes(p); });
    return { root: this.root, pageSize: this.cfg.pageSize, pages: pages };
  };

  // Captions, log lines and quiz texts are all rendered as HTML by the
  // toolkit, and keys are typed by the reader: every key that goes into one of
  // them passes through esc() (or q(), which calls it). dump() and statsRow()
  // are plain text for the self-tests and stay unescaped.
  function q(s) { return '<b class="bt-k">' + esc(s) + '</b>'; }
  function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }
  function tupleText(key, tid) { return '(' + key + ', ' + tid + ')'; }

  // Why separator s is below / not below the tuple (key, tid), in words.
  function why(s, key, tid) {
    var st = sepText(s, '');
    if (s.key === key) {
      if (s.tid === null) return q(st) + ' has the same bytes and no TID (minus infinity), so it is below the tuple';
      return q(st) + ' has the same key, so the TIDs decide: ' + s.tid + (s.tid < tid ? ' &lt; ' : ' &ge; ') + tid;
    }
    var n = commonPrefixLen(s.key, key);
    if (n === s.key.length) return q(st) + ' is a prefix of ' + q(key) + ', and a prefix sorts first, so it is below the tuple';
    if (n === key.length) return q(key) + ' is a prefix of ' + q(st) + ', so the tuple is below it';
    return q(st) + ' differs from ' + q(key) + ' at byte ' + n + ': \'' + esc(s.key[n]) + '\' ' +
      (s.key[n] < key[n] ? '&lt;' : '&gt;') + ' \'' + esc(key[n]) + '\'';
  }

  // Which lines of the "order and routing" panel (viz/code.js, snippet
  // `compare`) decide at this page: the separators next to the chosen child.
  function routingLines(page, i, key) {
    var decided = 'bytes';
    [page.seps[i - 1], page.seps[i]].forEach(function (s) {
      if (s && s.key === key) decided = s.tid === null ? 'cut' : 'tid';
    });
    // Zig: 2-3 key bytes decide, 4 a truncated TID is minus infinity, 5-6 two
    // real TIDs; 16 is the binary search step. Rust: line 3 does all of it.
    var zig = decided === 'bytes' ? [[2, 3], 16] : decided === 'cut' ? [4, 16] : [[4, 6], 16];
    return { zig: zig, rust: [3, [8, 10]] };
  }

  // One step per internal page on the way down. `label` is already escaped.
  Tree.prototype.descendSteps = function (key, tid, rec, label) {
    var id = this.root;
    while (!this.pages[id].leaf) {
      var page = this.pages[id], i = childIndex(page, key, tid), parts = [], hl = { pages: {}, seps: {}, links: {} };
      hl.pages[id] = 'active';
      hl.links[id + ':' + i] = 'active';
      if (i > 0) { parts.push(why(page.seps[i - 1], key, tid)); hl.seps[id + ':' + (i - 1)] = 'found'; }
      if (i < page.seps.length) { parts.push(why(page.seps[i], key, tid)); hl.seps[id + ':' + i] = 'compare'; }
      rec.push({
        caption: label + ': page ' + id + ' has ' + i + ' separator' + (i === 1 ? '' : 's') + ' below ' + q(tupleText(key, tid)) +
          ', so follow child ' + i + ' (page ' + page.children[i] + '). ' + parts.join('; ') + '.',
        state: this.snapshot(), highlight: hl, lines: routingLines(page, i, key), log: label + ': page ' + id + ' -&gt; child ' + i
      });
      id = page.children[i];
    }
    return id;
  };

  Tree.prototype.getSteps = function (key) {
    var rec = [], label = esc('get ' + key);
    var id = this.descendSteps(key, 0, rec, label), tids = this.get(key), hl = { pages: {}, cells: {} };
    // Highlight every cell with this key along the leaf chain.
    var pid = id, any = false;
    while (pid !== null) {
      var p = this.pages[pid], stop = false;
      hl.pages[pid] = 'active';
      for (var c = 0; c < p.cells.length; c++) {
        if (p.cells[c].key === key) { hl.cells[pid + ':' + c] = 'found'; any = true; }
        else if (p.cells[c].key > key) { stop = true; break; }
      }
      if (stop) break;
      pid = p.right;
    }
    rec.push({
      caption: label + ': ' + (any ? 'the leaf scan collects TIDs [' + tids.join(', ') + '] in order, following the leaf chain while the key matches.'
        : 'no cell has this key. The search still ended on the only page that could hold it.'),
      state: this.snapshot(), highlight: hl, log: label + ' -&gt; [' + tids.join(',') + ']'
    });
    rec.result = tids;
    return rec;
  };

  /* ---- put ----------------------------------------------------------- */

  // opts.verbose: also record the descent. Returns the array of steps;
  // steps.ok is false when the tuple was already present, the key too long or
  // the TID not a whole number in 0 .. MAX_TID.
  Tree.prototype.put = function (key, tid, opts) {
    opts = opts || {};
    var rec = [], self = this, label = esc('put ' + key + '@' + tid);
    rec.ok = false;
    if (!validTid(tid)) {
      rec.push({ caption: label + ': a TID is a whole number from 0 to ' + MAX_TID + ' (2<sup>48</sup> &minus; 1): it has to fit in the 6 bytes every cell is charged for it. Nothing was inserted.',
        state: this.snapshot(), highlight: {}, log: label + ': TID out of range' });
      return rec;
    }
    if (key.length > this.maxKeyLen()) {
      rec.push({ caption: label + ': the key is longer than ' + this.maxKeyLen() + ' bytes, the limit for this page size (a pivot with a TID must fit in one sixth of a page).',
        state: this.snapshot(), highlight: {}, log: label + ': key too large' });
      return rec;
    }
    var path = [];
    var leafId = this.findLeaf(key, tid, path);
    if (opts.verbose) this.descendSteps(key, tid, rec, label);
    var leaf = this.pages[leafId], slot = locate(leaf.cells, key, tid), hl;
    if (slot.kind === 'found') {
      hl = { pages: {}, cells: {} };
      hl.pages[leafId] = 'active';
      hl.cells[leafId + ':' + slot.cell] = 'found';
      rec.push({ caption: label + ': this exact (key, TID) tuple is already in the index. Nothing to do.', state: this.snapshot(), highlight: hl, log: label + ': exists' });
      return rec;
    }
    rec.ok = true;
    this.count++;
    var need = leafCellSize(key.length, 1), used = usedBytes(leaf), at;

    // The cell list with the new tuple in place (swap applied if needed).
    var items = clone(leaf.cells), swapNote = '';
    if (slot.kind === 'insertAt') {
      at = slot.at;
      items.splice(at, 0, { key: key, tids: [tid] });
    } else {
      var evicted = swapIntoPosting(items[slot.cell].tids, slot.pos, tid);
      at = slot.cell + 1;
      items.splice(at, 0, { key: key, tids: [evicted] });
      this.counters.postingSwaps++;
      swapNote = ' TID ' + tid + ' falls inside the posting list, so it takes its place there and the list\'s largest TID, ' + evicted +
        ', is pushed out into a plain cell of its own (a posting list split). The list keeps its size.';
    }

    if (used + need <= this.cfg.pageSize) {
      leaf.cells = items;
      hl = { pages: {}, cells: {} };
      hl.pages[leafId] = 'active';
      hl.cells[leafId + ':' + at] = 'inserted';
      if (slot.kind === 'inside') hl.cells[leafId + ':' + slot.cell] = 'merge';
      rec.push({ caption: label + ': page ' + leafId + ' has room (' + used + ' + ' + need + ' &le; ' + this.cfg.pageSize + ' bytes), so the tuple becomes a plain cell.' + swapNote,
        state: this.snapshot(), highlight: hl, log: label + ': fits in page ' + leafId });
      return rec;
    }

    // Slow path. Step: the page does not have room.
    var over = {};
    over[leafId] = items;
    hl = { pages: {}, cells: {} };
    hl.pages[leafId] = 'split';
    hl.cells[leafId + ':' + at] = 'inserted';
    rec.push({ caption: label + ': page ' + leafId + ' is full (' + used + ' + ' + need + ' &gt; ' + this.cfg.pageSize + ' bytes).' + swapNote +
        (this.cfg.dedup ? ' Before splitting, try to make room by deduplicating.' : ' Deduplication is off, so the page must split.'),
      state: this.snapshot(over), highlight: hl, log: label + ': page ' + leafId + ' full' });

    if (this.cfg.dedup) {
      var before = items.length, merged = this.dedupPass(items);
      var bytes = leafBytes(leaf.low, leaf.high, merged);
      over[leafId] = merged;
      hl = { pages: {}, cells: {} };
      hl.pages[leafId] = bytes <= this.cfg.pageSize ? 'active' : 'split';
      merged.forEach(function (c, i) { if (c.tids.length > 1) hl.cells[leafId + ':' + i] = 'merge'; });
      items = merged;
      if (bytes <= this.cfg.pageSize) {
        leaf.cells = merged;
        this.counters.dedupPasses++;
        rec.push({ caption: label + ': the deduplication pass folds equal keys into posting lists: ' + before + ' cells become ' + merged.length +
            ', and the page shrinks to ' + bytes + ' bytes. The tuple fits; no split.',
          state: this.snapshot(), highlight: hl, log: label + ': dedup pass, ' + before + ' -> ' + merged.length + ' cells' });
        return rec;
      }
      rec.push({ caption: label + ': the deduplication pass ' + (merged.length < before ? 'turns ' + before + ' cells into ' + merged.length + ', but ' + bytes + ' bytes is still too much.'
          : 'finds nothing to merge.') + ' The page must split.',
        state: this.snapshot(over), highlight: hl, log: label + ': dedup not enough' });
    }

    // Split the leaf.
    var choice = this.chooseLeafSplit(leaf.low, leaf.high, items), cut = choice.cut;
    var sep = separator(this.cfg.truncate, items[cut - 1], items[cut]);
    var full = separator(false, items[cut - 1], items[cut]);
    hl = { pages: {}, cells: {} };
    hl.pages[leafId] = 'split';
    hl.cells[leafId + ':' + (cut - 1)] = 'compare';
    hl.cells[leafId + ':' + cut] = 'compare';
    var others = choice.candidates.filter(function (c) { return c.cut !== cut; }).map(function (c) { return sepText(c.sep, ''); });
    var explain;
    if (!this.cfg.truncate) explain = 'Truncation is off: the separator is the whole last-left tuple, ' + q(sepText(sep, '')) + ' (' + pivotSize(sep) + ' bytes as a pivot).';
    else if (sep.tid !== null) explain = 'The two keys are equal, so no byte can separate them: the separator is the last-left key with its TID, ' + q(sepText(sep, '')) + '.';
    else explain = 'They share ' + (sep.key.length - 1) + ' byte' + (sep.key.length === 2 ? '' : 's') + ', so the separator is ' + q(sepText(sep, '')) +
      ': ' + pivotSize(sep) + ' bytes as a pivot instead of ' + pivotSize(full) + ' for ' + q(sepText(full, '')) + '.';
    var splitStep = {
      caption: label + ': cut between ' + q(cellText(items[cut - 1])) + ' and ' + q(cellText(items[cut])) + '. ' + explain +
        (others.length ? ' Other cuts near the middle would give ' + others.map(q).join(', ') + '.' : ''),
      state: this.snapshot(over), highlight: hl, log: label + ': split page ' + leafId + ', separator ' + esc(sepText(sep, ''))
    };
    if (this.cfg.truncate && sep.tid === null) {
      var choices = [sepText(full, ''), '"' + items[cut].key + '"', sepText(sep, '')].filter(function (c, i, a) { return a.indexOf(c) === i; });
      splitStep.question = {
        prompt: 'The leaf splits between ' + q(cellText(items[cut - 1])) + ' and ' + q(cellText(items[cut])) + '. Which separator goes to the parent?',
        choices: choices.map(esc), answer: choices.indexOf(sepText(sep, '')),
        explain: 'The shortest string above the left key and not above the right key: the common prefix plus one byte.'
      };
    }
    rec.push(splitStep);

    var leftId = leafId, rightId = this.pages.length, notes = [];
    var newPages = [{ id: rightId, leaf: true, low: sep, high: leaf.high, right: leaf.right, cells: items.slice(cut), seps: [], children: [] }];
    var oldHigh = leaf.high;
    leaf.cells = items.slice(0, cut);
    leaf.high = sep;
    leaf.right = rightId;
    this.pages.push(newPages[0]);
    this.counters.leafSplits++;
    var changed = {}, newSep = null;
    changed[leftId] = 'split';
    changed[rightId] = 'split';
    void oldHigh;

    var level = path.length;
    for (;;) {
      if (level === 0) {
        var rootId = this.pages.length;
        this.pages.push({ id: rootId, leaf: false, low: null, high: null, right: null, cells: [], seps: [sep], children: [leftId, rightId] });
        this.root = rootId;
        newSep = rootId + ':0';
        notes.push('The page that split was the root, so a new root, page ' + rootId + ', is created above the two halves');
        break;
      }
      level--;
      var step = path[level], parent = this.pages[step.page], atSep = step.childIndex;
      if (usedBytes(parent) + pivotSize(sep) <= this.cfg.pageSize) {
        parent.seps.splice(atSep, 0, sep);
        parent.children.splice(atSep + 1, 0, rightId);
        newSep = step.page + ':' + atSep;
        notes.push('The separator ' + q(sepText(sep, '')) + ' goes into parent page ' + step.page);
        break;
      }
      var seps = parent.seps.slice(), kids = parent.children.slice();
      seps.splice(atSep, 0, sep);
      kids.splice(atSep + 1, 0, rightId);
      var m = this.chooseInternalSplit(parent.low, parent.high, seps), up = seps[m], newRight = this.pages.length;
      this.pages.push({ id: newRight, leaf: false, low: up, high: parent.high, right: parent.right, cells: [], seps: seps.slice(m + 1), children: kids.slice(m + 1) });
      parent.seps = seps.slice(0, m);
      parent.children = kids.slice(0, m + 1);
      parent.high = up;
      parent.right = newRight;
      this.counters.internalSplits++;
      changed[step.page] = 'split';
      changed[newRight] = 'split';
      notes.push('Parent page ' + step.page + ' overflows and splits too; its separator ' + q(sepText(up, '')) + ' moves up unchanged (internal splits never truncate)');
      sep = up;
      leftId = step.page;
      rightId = newRight;
    }
    hl = { pages: changed, seps: {}, fences: {} };
    hl.seps[newSep] = 'inserted';
    hl.fences[leafId + ':high'] = 'inserted';
    hl.fences[newPages[0].id + ':low'] = 'inserted';
    rec.push({
      caption: label + ': the left half keeps page ' + leafId + ', the right half is new page ' + newPages[0].id + '. ' + notes.join('. ') +
        '. The same separator is also the high fence of the left page and the low fence of the right one.',
      state: self.snapshot(), highlight: hl, log: label + ': new page ' + newPages[0].id
    });
    return rec;
  };

  /* ---- validate, stats, dump ------------------------------------------ */

  Tree.prototype.validate = function () {
    var errors = [], self = this, st = { depth: null, prevAt: [], entries: 0 };
    function same(a, b) { return (!a && !b) || (a && b && compareTuple(a.key, a.tid, b.key, b.tid) === 0); }
    function aboveLow(low, key, tid) { return !low || compareTuple(low.key, low.tid, key, tid) < 0; }
    function belowHigh(high, key, tid, inclusive) {
      if (!high) return true;
      var o = compareTuple(key, tid, high.key, high.tid);
      return o < 0 || (inclusive && o === 0);
    }
    (function check(id, low, high, depth) {
      var p = self.pages[id];
      if (!same(p.low, low) || !same(p.high, high)) errors.push('page ' + id + ': fence differs from the parent separator');
      if (usedBytes(p) > self.cfg.pageSize) errors.push('page ' + id + ': overflow');
      // One sibling chain per level: the pages of a level are met left to right.
      if (st.prevAt[depth] !== undefined && self.pages[st.prevAt[depth]].right !== id) errors.push('page ' + id + ': sibling chain');
      st.prevAt[depth] = id;
      if (p.leaf) {
        if (st.depth === null) st.depth = depth; else if (st.depth !== depth) errors.push('leaf depth');
        p.cells.forEach(function (c, i) {
          for (var t = 1; t < c.tids.length; t++) if (c.tids[t - 1] >= c.tids[t]) errors.push('posting order');
          if (leafCellSize(c.key.length, c.tids.length) > self.maxCell()) errors.push('cell too large');
          if (!c.tids.every(validTid)) errors.push('TID out of range');
          if (i > 0) {
            var pc = p.cells[i - 1];
            if (compareTuple(pc.key, pc.tids[pc.tids.length - 1], c.key, c.tids[0]) >= 0) errors.push('page ' + id + ': cell order');
          }
          if (!aboveLow(low, c.key, c.tids[0]) || !belowHigh(high, c.key, c.tids[c.tids.length - 1], true)) errors.push('page ' + id + ': tuple outside fences');
          st.entries += c.tids.length;
        });
        return;
      }
      if (p.children.length !== p.seps.length + 1 || !p.seps.length) errors.push('page ' + id + ': shape');
      p.seps.forEach(function (s, i) {
        if (!aboveLow(i === 0 ? low : p.seps[i - 1], s.key, s.tid) || !belowHigh(high, s.key, s.tid, false)) errors.push('page ' + id + ': separator order');
      });
      p.children.forEach(function (child, i) {
        check(child, i === 0 ? low : p.seps[i - 1], i === p.seps.length ? high : p.seps[i], depth + 1);
      });
    })(this.root, null, null, 0);
    st.prevAt.forEach(function (last) { if (self.pages[last].right !== null) errors.push('page ' + last + ': the last page of a level has a right link'); });
    if (st.entries !== this.count) errors.push('entry count');
    return errors;
  };

  Tree.prototype.stats = function () {
    var s = { height: 0, leafPages: 0, internalPages: 0, entries: this.count, leafCells: 0, postingCells: 0, seps: 0, sepBytes: 0, children: 0, usedBytes: 0 };
    for (var id = this.root; ; id = this.pages[id].children[0]) { s.height++; if (this.pages[id].leaf) break; }
    this.pages.forEach(function (p) {
      s.usedBytes += usedBytes(p);
      if (p.leaf) {
        s.leafPages++;
        s.leafCells += p.cells.length;
        p.cells.forEach(function (c) { if (c.tids.length > 1) s.postingCells++; });
      } else {
        s.internalPages++;
        s.children += p.children.length;
        s.seps += p.seps.length;
        p.seps.forEach(function (sep) { s.sepBytes += sep.key.length + (sep.tid !== null ? TID : 0); });
      }
    });
    return s;
  };

  // Same text as `dump` in zig/src/demo.zig and rust/src/demo.rs.
  Tree.prototype.dump = function () {
    var out = [], self = this;
    (function walk(id, depth) {
      var p = self.pages[id], ind = new Array(depth * 2 + 1).join(' ');
      out.push(ind + 'page ' + id + ' ' + (p.leaf ? 'leaf' : 'internal') + ' low=' + sepText(p.low, '-inf') + ' high=' + sepText(p.high, '+inf') +
        ' used=' + usedBytes(p) + '/' + self.cfg.pageSize);
      if (p.leaf) { out.push(ind + '  ' + p.cells.map(cellText).join(' ')); return; }
      out.push(ind + '  separators:' + p.seps.map(function (s) { return ' ' + sepText(s, ''); }).join(''));
      p.children.forEach(function (c) { walk(c, depth + 1); });
    })(this.root, 0);
    return out.join('\n') + '\n';
  };

  function configName(cfg) {
    return cfg.truncate ? (cfg.dedup ? 'truncate + dedup' : 'truncate') : (cfg.dedup ? 'dedup' : 'neither');
  }

  // Same text as `statsRow`.
  Tree.prototype.statsRow = function () {
    var s = this.stats();
    return '  ' + pad(configName(this.cfg), 16, true) + '  ' + pad(s.height, 6) + '  ' + pad(s.leafPages, 6) + '  ' + pad(s.internalPages, 8) +
      '  ' + pad(tenths(s.children, s.internalPages), 6) + '  ' + pad(tenths(s.sepBytes, s.seps), 9) + '  ' + pad(tenths(s.usedBytes, s.entries), 11) +
      '  ' + pad(this.counters.leafSplits, 11) + '  ' + pad(this.counters.dedupPasses, 12);
  };

  /* The fixed scenario of the Zig and Rust programs (demo.zig / demo.rs). */
  var SCENARIO = [
    ['cherry', 1], ['apple', 2], ['blackberry', 3], ['apple', 4], ['fig', 5], ['blueberry', 6],
    ['apple', 7], ['cherry', 8], ['grape', 9], ['apple', 10], ['banana', 11], ['cherry', 12],
    ['apple', 13], ['elderberry', 14], ['apple', 16], ['cherry', 17], ['apricot', 18], ['apple', 19],
    ['cranberry', 20], ['cherry', 21], ['apple', 22], ['date', 23], ['cherry', 24], ['apple', 25],
    ['grapefruit', 26], ['cherry', 27], ['apple', 28], ['blackcurrant', 29], ['cherry', 30], ['apple', 31],
    ['avocado', 32], ['cherry', 33], ['guava', 34], ['apple', 35], ['cherry', 36], ['coconut', 37],
    ['apple', 15], ['cherry', 9], ['apple', 1]
  ];

  var api = {
    Tree: Tree, SCENARIO: SCENARIO, SCENARIO_PAGE_SIZE: 256, MAX_TID: MAX_TID, validTid: validTid,
    compareTuple: compareTuple, commonPrefixLen: commonPrefixLen, separator: separator,
    sepSize: sepSize, pivotSize: pivotSize, leafCellSize: leafCellSize, usedBytes: usedBytes,
    sepText: sepText, cellText: cellText, tenths: tenths, pad: pad, configName: configName, esc: esc
  };
  root.Ch17Model = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);

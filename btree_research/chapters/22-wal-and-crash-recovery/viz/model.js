/* Chapter 22 visualization: the JavaScript models of both pages.
 *
 * Nothing here is a port of the Zig/Rust byte formats. The models work at the
 * level the pictures need: "page 2 holds these keys and links to page 4",
 * "record LSN 41 occupies log bytes 12336..16456". The page numbers, keys,
 * write order, LSNs and byte ranges are those printed by the chapter's
 * program (expected.js), and both pages check the models against that output.
 */
window.CH22 = (function () {
  'use strict';

  /* ---------------------------------------------------------------------
   * Page 1: the leaf split of part 1, with no log.
   * ------------------------------------------------------------------- */

  function leaf(keys, next) { return { kind: 'leaf', keys: keys, next: next }; }
  function interior(keys, children) { return { kind: 'interior', keys: keys, children: children }; }

  // The file after 11 puts and a flush (program: "11 keys are on disk").
  var OLD = {
    0: { kind: 'meta', root: 1, pages: 4, keys: 11 },
    1: interior(['20'], [2, 3]),
    2: leaf(['01', '03', '05', '06', '07', '10', '12', '17'], 3),
    3: leaf(['20', '25', '30'], null)
  };
  // The five page writes of "put 15, then flush", in the order the program issues them.
  var WRITES = [
    { page: 4, content: { kind: 'zero' }, what: 'page 4, all zeroes', why: 'the pager grows the file by one page for the new right leaf' },
    { page: 0, content: { kind: 'meta', root: 1, pages: 5, keys: 12 }, what: 'page 0, the metapage', why: 'it now says 5 pages and 12 keys' },
    { page: 1, content: interior(['12', '20'], [2, 4, 3]), what: 'page 1, the parent', why: 'it gained the separator 12 and a pointer to page 4' },
    { page: 2, content: leaf(['01', '03', '05', '06', '07', '10'], 4), what: 'page 2, the left half', why: 'keys 12 and 17 moved out; its sibling link now says page 4' },
    { page: 4, content: leaf(['12', '15', '17'], 3), what: 'page 4, the right half', why: 'it holds 12, the new key 15, and 17' }
  ];

  /** The file when exactly the writes in `mask` (bit i = write i + 1) reached the disk. */
  function diskFor(mask) {
    var disk = { count: 4, pages: {}, fresh: {} };
    for (var id in OLD) disk.pages[id] = OLD[id];
    WRITES.forEach(function (w, i) {
      if (!(mask & (1 << i))) return;
      disk.pages[w.page] = w.content;
      disk.fresh[w.page] = true;
      disk.count = Math.max(disk.count, w.page + 1);
    });
    return disk;
  }

  /**
   * What chapter 12's open + validate + full scan say about a file. The checks
   * run in the same order as DiskBTree.open and DiskBTree.validate, so the
   * first error found is the one the program prints.
   * -> { state: 'before' | 'after' | 'open' | 'invalid' | 'wrong', err, bad: page id or null }
   */
  function check(disk) {
    var meta = disk.pages[0];
    if (meta.root >= disk.count || meta.pages > disk.count) return { state: 'open', err: 'Corrupt', bad: 0 };
    var seen = { 0: true }, leaves = [], keys = [], leafDepth = null, result = null;
    function fail(err, bad) { if (!result) result = { state: 'invalid', err: err, bad: bad }; }
    function visit(id, lo, hi, depth) {
      if (result) return;
      if (id >= disk.count) return fail('BadPage', id);
      if (seen[id]) return fail('PageReachedTwice', id);
      seen[id] = true;
      var p = disk.pages[id];
      if (!p || p.kind === 'zero' || p.kind === 'meta') return fail('BadPage', id);
      var n = p.keys.length;
      if (n > 0 && ((lo !== null && p.keys[0] < lo) || (hi !== null && p.keys[n - 1] >= hi))) return fail('KeyOutOfBounds', id);
      if (p.kind === 'leaf') {
        if (n === 0 && id !== meta.root) return fail('EmptyPage', id);
        if (leafDepth === null) leafDepth = depth;
        if (leafDepth !== depth) return fail('UnevenDepth', id);
        keys = keys.concat(p.keys);
        leaves.push({ id: id, next: p.next });
        return;
      }
      if (n === 0) return fail('EmptyPage', id);
      for (var i = 0; i <= n && !result; i++) visit(p.children[i], i === 0 ? lo : p.keys[i - 1], i === n ? hi : p.keys[i], depth + 1);
    }
    visit(meta.root, null, null, 0);
    if (result) return result;
    for (var i = 0; i < leaves.length; i++) {
      var expected = i + 1 < leaves.length ? leaves[i + 1].id : null;
      if (leaves[i].next !== expected) return { state: 'invalid', err: 'LeafChainBroken', bad: leaves[i].id };
    }
    for (var id = 0; id < disk.count; id++) if (!seen[id]) return { state: 'invalid', err: 'UnreachablePage', bad: id };
    if (keys.length !== meta.keys) return { state: 'invalid', err: 'KeyCountMismatch', bad: 0 };
    var text = keys.join(' ');
    if (text === '01 03 05 06 07 10 12 17 20 25 30') return { state: 'before', err: null, bad: null };
    if (text === '01 03 05 06 07 10 12 15 17 20 25 30') return { state: 'after', err: null, bad: null };
    return { state: 'wrong', err: null, bad: null };
  }

  /** The same wording as the program's output. */
  function verdictText(v) {
    if (v.state === 'before' || v.state === 'after') return v.state;
    if (v.state === 'open') return 'open fails (' + v.err + ')';
    if (v.state === 'invalid') return 'invalid (' + v.err + ')';
    return 'valid tree, wrong contents';
  }

  /**
   * A BTViz.TreeView model of the file as a reader meets it: start at the
   * root, follow child pointers. Pages nobody points to are drawn as extra roots.
   */
  function treeModel(disk) {
    var drawn = {};
    function node(id) {
      var p = disk.pages[id], label = 'page ' + id, note = disk.fresh[id] ? 'new' : 'old';
      if (drawn[id]) return { id: 'p' + id + 'again', keys: ['page ' + id + ' again'], leaf: true, meta: { label: label } };
      drawn[id] = true;
      if (id >= disk.count || !p) return { id: 'p' + id, keys: ['not in the file'], leaf: true, meta: { label: label, note: 'missing' } };
      if (p.kind === 'zero') return { id: 'p' + id, keys: ['all zeroes'], leaf: true, meta: { label: label, note: 'new' } };
      if (p.kind === 'leaf') return { id: 'p' + id, keys: p.keys, leaf: true, meta: { label: label, note: note + ' · next ' + (p.next === null ? '–' : p.next) } };
      return { id: 'p' + id, keys: p.keys, leaf: false, children: p.children.map(node), meta: { label: label, note: note } };
    }
    var roots = [node(disk.pages[0].root)];
    for (var id = 1; id < disk.count; id++) if (!drawn[id]) roots.push(node(id));
    return roots.length === 1 ? roots[0] : roots;
  }

  /* ---------------------------------------------------------------------
   * Page 2: the same split through the log (part 2 of the program).
   * ------------------------------------------------------------------- */

  var PAGE = 4096;
  // The 13 storage calls of "put 15" and of the checkpoint after it.
  var CALLS = [
    { file: 'log', kind: 'write', page: 1 }, { file: 'log', kind: 'write', page: 2 }, { file: 'log', kind: 'write', page: 3 },
    { file: 'log', kind: 'write', page: 4 }, { file: 'log', kind: 'write', page: 5 }, { file: 'log', kind: 'sync' },
    { file: 'main', kind: 'write', page: 0 }, { file: 'main', kind: 'write', page: 1 }, { file: 'main', kind: 'write', page: 2 },
    { file: 'main', kind: 'write', page: 4 }, { file: 'main', kind: 'sync' },
    { file: 'log', kind: 'write', page: 0 }, { file: 'log', kind: 'sync' }
  ];
  // The five records of the commit: LSN, byte range in the log file, contents.
  var RECORDS = [
    { lsn: 39, from: 4096, to: 8216, page: 0 }, { lsn: 40, from: 8216, to: 12336, page: 1 },
    { lsn: 41, from: 12336, to: 16456, page: 2 }, { lsn: 42, from: 16456, to: 20576, page: 4 },
    { lsn: 43, from: 20576, to: 20600, commit: 4 }
  ];
  var MAIN_PAGES = [0, 1, 2, 4];
  var GENERATION = 2;

  /** Log pages a record's bytes lie on. */
  function recordPages(r) {
    var pages = [];
    for (var p = Math.floor(r.from / PAGE); p <= Math.floor((r.to - 1) / PAGE); p++) pages.push(p);
    return pages;
  }

  /**
   * The two files after the power fails once `calls` storage calls have
   * completed. mode 'drop': unsynced writes are lost; 'keep': they all
   * reached the disk; 'tear': each reached the disk in part (some of its
   * eight 512-byte sectors, never all and never none).
   *
   * A torn page is not usable: every record with bytes on a torn log page
   * fails its checksum, and a torn main page fails its page checksum. One
   * case depends on WHICH sectors were written: the log header lives in
   * sector 0 of its page. In the program's run (seed 22) the torn header
   * write did not include that sector, so the old header survives; the model
   * does the same. Either way the tree comes out the same.
   * -> { log: {page: true}, header: bool (new generation), main: {page: true} = new image on disk,
   *      tornLog: {page: true}, tornMain: {page: true}, tornHeader: bool }
   */
  function crashState(calls, mode) {
    var durable = { log: {}, main: {} }, pending = { log: [], main: [] }, torn = { log: {}, main: {} };
    for (var i = 0; i < calls; i++) {
      var c = CALLS[i];
      if (c.kind === 'write') pending[c.file].push(c.page);
      else { pending[c.file].forEach(function (p) { durable[c.file][p] = true; }); pending[c.file] = []; }
    }
    if (mode === 'keep') ['log', 'main'].forEach(function (f) { pending[f].forEach(function (p) { durable[f][p] = true; }); });
    if (mode === 'tear') ['log', 'main'].forEach(function (f) { pending[f].forEach(function (p) { torn[f][p] = true; }); });
    var header = !!durable.log[0], tornHeader = !!torn.log[0];
    delete durable.log[0];
    delete torn.log[0];
    return { log: durable.log, header: header, main: durable.main, tornLog: torn.log, tornMain: torn.main, tornHeader: tornHeader };
  }

  /**
   * Recovery on a crashed state.
   * -> { generation, valid: n records with an intact chain, brokenAt: index of the first bad record or null,
   *      why, committed: bool, replay: [page...], state: 'before' | 'after' | 'mixed' }
   */
  function recover(s) {
    var r = { generation: s.header ? GENERATION + 1 : GENERATION, valid: 0, brokenAt: null, why: '', committed: false, replay: [] };
    if (!s.header) {
      for (var i = 0; i < RECORDS.length; i++) {
        var missing = recordPages(RECORDS[i]).filter(function (p) { return !s.log[p]; });
        if (missing.length) {
          r.brokenAt = i;
          // The log file is reused: before this put it already had 28 pages
          // full of generation 1's records (LSN 1 to 38). A write that did
          // not reach the disk leaves those old bytes, not a hole.
          r.why = s.tornLog[missing[0]] ?
            'log page ' + missing[0] + ' is torn: some of its sectors hold the new bytes and some do not, so the checksum computed over the record does not match the one stored in it' :
            missing[0] === Math.floor(RECORDS[i].from / PAGE) ?
            'the new bytes of log page ' + missing[0] + ' never reached the disk. The log file is reused, so at this position still lies record LSN 1 of generation 1; the scan expects LSN ' + RECORDS[i].lsn + ' here and refuses it' :
            'the new bytes of log page ' + missing[0] + ' never reached the disk. The page still holds old bytes of generation 1, so the record\'s tail is not what its checksum was computed over';
          break;
        }
        r.valid++;
      }
      r.committed = r.valid === RECORDS.length;
    } else {
      r.brokenAt = 0;
      r.why = 'its bytes are intact and a moment ago it was a valid record, but its checksum chains from the old header, and the new header announces LSN ' + (RECORDS[RECORDS.length - 1].lsn + 1) + ' as its first record';
    }
    if (r.committed) r.replay = MAIN_PAGES.slice();
    var fresh = MAIN_PAGES.filter(function (p) { return r.committed || s.main[p]; }).length;
    r.state = fresh === MAIN_PAGES.length ? 'after' : fresh === 0 ? 'before' : 'mixed';
    return r;
  }

  /** Calls completed when the power fails right after page write number `n` (the program's N). */
  function callsForWrites(n) {
    var writes = 0;
    for (var i = 0; i < CALLS.length; i++) {
      if (writes === n) return i;
      if (CALLS[i].kind === 'write') writes++;
    }
    return CALLS.length - 1; // after the last write, before the last sync
  }

  /* ---------------------------------------------------------------------
   * The program's output, for the self-tests.
   * ------------------------------------------------------------------- */

  function expectedLines() { return String(window.CH22_EXPECTED || '').split('\n'); }

  /** Lines "N = 3: drop: before | keep: ..." of one part -> [{drop, keep, tear}] indexed by N. */
  function crashRows(part) {
    var rows = [], inPart = false;
    expectedLines().forEach(function (line) {
      if (line.indexOf('== Part') === 0) inPart = line.indexOf('== Part ' + part + ':') === 0;
      var m = /^N = (\d+): (.*)$/.exec(line);
      if (!inPart || !m) return;
      var row = {};
      m[2].split(' | ').forEach(function (cell) { var c = /^(\w+): (.*)$/.exec(cell); row[c[1]] = c[2]; });
      rows[+m[1]] = row;
    });
    return rows;
  }

  /** The 32 lines "01101 invalid (KeyOutOfBounds)" -> {mask: text}. */
  function subsetTable() {
    var table = {};
    expectedLines().forEach(function (line) {
      var re = /([01]{5}) (.*?)(?=\s{2,}[01]{5} |$)/g, m;
      if (!/^\s+[01]{5} /.test(line)) return;
      while ((m = re.exec(line))) {
        var mask = 0;
        for (var i = 0; i < 5; i++) if (m[1][i] === '1') mask |= 1 << i;
        table[mask] = m[2].trim();
      }
    });
    return table;
  }

  return {
    OLD: OLD, WRITES: WRITES, diskFor: diskFor, check: check, verdictText: verdictText, treeModel: treeModel,
    CALLS: CALLS, RECORDS: RECORDS, MAIN_PAGES: MAIN_PAGES, GENERATION: GENERATION, recordPages: recordPages,
    crashState: crashState, recover: recover, callsForWrites: callsForWrites,
    crashRows: crashRows, subsetTable: subsetTable
  };
})();

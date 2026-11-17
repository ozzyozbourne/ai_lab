/*
 * Chapter 21 model: a JavaScript port of the chapter's Zig/Rust code
 * (prng, crc32, page, sim_disk, doublewrite and the demo program `run`).
 * It is the model behind the visualization, and `runProgram()` reproduces
 * expected_output.txt byte for byte (checked with BTViz.selfTest), so the
 * picture cannot drift from the code. Also runs under node:
 *   const M = require('./model.js'); process.stdout.write(M.runProgram());
 */
(function (root) {
  'use strict';

  var PAGE_SIZE = 4096, SECTOR_SIZE = 512, SECTORS = 8, PAYLOAD_SIZE = PAGE_SIZE - 4;

  /* ---- SplitMix64 (common/zig/prng.zig), on BigInt ---- */
  var MASK64 = (1n << 64n) - 1n;
  function SplitMix64(seed) { this.state = BigInt(seed) & MASK64; }
  SplitMix64.prototype.nextU64 = function () {
    this.state = (this.state + 0x9E3779B97F4A7C15n) & MASK64;
    var z = this.state;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK64;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK64;
    return z ^ (z >> 31n);
  };
  /** Integer in [0, n): the top 64 bits of the 128-bit product. */
  SplitMix64.prototype.below = function (n) { return Number((this.nextU64() * BigInt(n)) >> 64n); };

  /* ---- CRC-32 (common/zig/crc32.zig) ---- */
  var TABLE = new Uint32Array(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var b = 0; b < 8; b++) c = (c & 1) ? (c >>> 1) ^ 0xEDB88320 : c >>> 1;
    TABLE[i] = c >>> 0;
  }
  function crc32Update(crc, bytes, len) {
    var c = ~crc >>> 0;
    for (var j = 0; j < len; j++) c = TABLE[(c ^ bytes[j]) & 0xFF] ^ (c >>> 8);
    return ~c >>> 0;
  }

  /* ---- page.zig ---- */
  function checksum(page, pageNo) {
    var no = new Uint8Array(8), v = BigInt(pageNo);
    for (var j = 0; j < 8; j++) no[j] = Number((v >> BigInt(8 * j)) & 0xFFn);
    return crc32Update(crc32Update(0, no, 8), page, PAYLOAD_SIZE);
  }
  function storedChecksum(page) {
    return (page[PAYLOAD_SIZE] | page[PAYLOAD_SIZE + 1] << 8 | page[PAYLOAD_SIZE + 2] << 16 | page[PAYLOAD_SIZE + 3] << 24) >>> 0;
  }
  function seal(page, pageNo) {
    var s = checksum(page, pageNo);
    for (var j = 0; j < 4; j++) page[PAYLOAD_SIZE + j] = (s >>> (8 * j)) & 0xFF;
  }
  function allZero(bytes) { for (var j = 0; j < bytes.length; j++) if (bytes[j] !== 0) return false; return true; }
  function verify(page, pageNo) {
    if (storedChecksum(page) === checksum(page, pageNo)) return 'ok';
    return allZero(page) ? 'blank' : 'corrupt';
  }
  function filled(letter) { return new Uint8Array(PAGE_SIZE).fill(letter.charCodeAt(0)); }
  function sealedPage(letter, pageNo) { var p = filled(letter); seal(p, pageNo); return p; }
  function hex8(n) { return ('00000000' + (n >>> 0).toString(16)).slice(-8); }

  /* ---- sim_disk.zig ---- */
  // Real Error subclasses, so an uncaught one shows a readable message.
  function storageError(name, text) {
    function E(detail) {
      var e = new Error(text + (detail ? ' (' + detail + ')' : ''));
      e.name = name;
      Object.setPrototypeOf(e, E.prototype);
      return e;
    }
    E.prototype = Object.create(Error.prototype);
    E.prototype.constructor = E;
    return E;
  }
  var PowerLoss = storageError('PowerLoss', 'the simulated disk has lost power');
  var OutOfBounds = storageError('OutOfBounds', 'page is at or beyond the size of the store');

  function SimDisk(seed) {
    this.durable = [];          // array of Uint8Array pages (holes are zero pages)
    this.pending = [];          // [{pageNo, data}] oldest first
    this.prng = new SplitMix64(seed);
    this.writesLeft = null;
    this.stats = { reads: 0, writes: 0, syncs: 0, crashes: 0 };
    this.lastMasks = [];        // what the last crash did: [{pageNo, fate, mask}]
  }
  SimDisk.prototype.isPoweredOff = function () { return this.writesLeft === 0; };
  SimDisk.prototype.readPage = function (pageNo) {
    if (this.isPoweredOff()) throw new PowerLoss();
    this.stats.reads++;
    for (var j = this.pending.length - 1; j >= 0; j--) {
      if (this.pending[j].pageNo === pageNo) return this.pending[j].data.slice();
    }
    if (pageNo >= this.size()) throw new OutOfBounds('page ' + pageNo + ', size ' + this.size());
    // A hole: below a pending write to a higher page but beyond the durable end.
    if (pageNo >= this.durable.length) return new Uint8Array(PAGE_SIZE);
    return this.durable[pageNo].slice();
  };
  SimDisk.prototype.writePage = function (pageNo, page) {
    if (this.isPoweredOff()) throw new PowerLoss();
    this.pending.push({ pageNo: pageNo, data: page.slice() });
    this.stats.writes++;
    if (this.writesLeft !== null) this.writesLeft--;
  };
  SimDisk.prototype.apply = function (w, mask) {
    while (this.durable.length <= w.pageNo) this.durable.push(new Uint8Array(PAGE_SIZE));
    var dst = this.durable[w.pageNo];
    for (var s = 0; s < SECTORS; s++) {
      if (!(mask & (1 << s))) continue;
      dst.set(w.data.subarray(s * SECTOR_SIZE, (s + 1) * SECTOR_SIZE), s * SECTOR_SIZE);
    }
  };
  SimDisk.prototype.sync = function () {
    if (this.isPoweredOff()) throw new PowerLoss();
    for (var j = 0; j < this.pending.length; j++) this.apply(this.pending[j], 0xFF);
    this.pending = [];
    this.stats.syncs++;
  };
  SimDisk.prototype.size = function () {
    var n = this.durable.length;
    this.pending.forEach(function (w) { n = Math.max(n, w.pageNo + 1); });
    return n;
  };
  SimDisk.prototype.powerOffAfterWrites = function (n) { this.writesLeft = n; };
  SimDisk.prototype.crash = function (mode) {
    var report = { dropped: 0, kept: 0, torn: 0 };
    this.lastMasks = [];
    for (var j = 0; j < this.pending.length; j++) {
      var w = this.pending[j];
      var fate = mode === 'random' ? ['drop', 'keep', 'tear'][this.prng.below(3)] : mode;
      var mask = 0;
      if (fate === 'drop') report.dropped++;
      else if (fate === 'keep') { mask = 0xFF; this.apply(w, mask); report.kept++; }
      else { mask = 1 + this.prng.below(254); this.apply(w, mask); report.torn++; }
      this.lastMasks.push({ pageNo: w.pageNo, fate: fate, mask: mask });
    }
    this.pending = [];
    this.writesLeft = null;
    this.stats.crashes++;
    return report;
  };
  /** readPage + verify; a page past the end counts as blank, PowerLoss passes through (page.zig readChecked). */
  SimDisk.prototype.readChecked = function (pageNo) {
    var page;
    try { page = this.readPage(pageNo); } catch (e) {
      if (!(e instanceof OutOfBounds)) throw e;
      return { page: new Uint8Array(PAGE_SIZE), check: 'blank' };
    }
    return { page: page, check: verify(page, pageNo) };
  };

  /* ---- doublewrite.zig ---- */
  function DoubleWrite(disk, slots) { this.disk = disk; this.slots = slots; }
  DoubleWrite.prototype.slotPage = function (i) { return i; };
  DoubleWrite.prototype.homePage = function (i) { return this.slots + i; };
  DoubleWrite.prototype.update = function (i, page) {
    seal(page, this.slotPage(i));
    this.disk.writePage(this.slotPage(i), page);
    this.disk.sync();
    seal(page, this.homePage(i));
    this.disk.writePage(this.homePage(i), page);
    this.disk.sync();
  };
  DoubleWrite.prototype.read = function (i) { return this.disk.readChecked(this.homePage(i)); };
  function samePayload(a, b) { for (var j = 0; j < PAYLOAD_SIZE; j++) if (a[j] !== b[j]) return false; return true; }
  /** Returns the report; `unrecoverable` is set instead of throwing. `noSync` leaves the repair pending. */
  DoubleWrite.prototype.recover = function (opts) {
    var report = { intact: 0, rolled_forward: 0, restored: 0, blank: 0, unrecoverable: false };
    for (var i = 0; i < this.slots; i++) {
      var slot = this.disk.readChecked(this.slotPage(i)), home = this.disk.readChecked(this.homePage(i));
      if (slot.check === 'ok') {
        if (home.check === 'ok' && samePayload(slot.page, home.page)) { report.intact++; continue; }
        seal(slot.page, this.homePage(i));
        this.disk.writePage(this.homePage(i), slot.page);
        if (home.check === 'ok') report.rolled_forward++; else report.restored++;
      } else if (home.check === 'ok') report.intact++;
      else if (home.check === 'blank') report.blank++;
      else { report.unrecoverable = true; return report; }
    }
    if (!(opts && opts.noSync)) this.disk.sync();
    return report;
  };

  /* ---- views for the visualization ---- */

  /** One character per sector, exactly as main.zig sectorMap: A/B vs the sealed references, '.', '?'. */
  function sectorMap(page, pageNo) {
    var refs = { A: sealedPage('A', pageNo), B: sealedPage('B', pageNo) }, out = '';
    for (var s = 0; s < SECTORS; s++) {
      var sec = page.subarray(s * SECTOR_SIZE, (s + 1) * SECTOR_SIZE), ch = '?';
      if (allZero(sec)) ch = '.';
      ['A', 'B'].forEach(function (l) {
        var r = refs[l].subarray(s * SECTOR_SIZE, (s + 1) * SECTOR_SIZE), eq = true;
        for (var j = 0; j < SECTOR_SIZE && eq; j++) eq = r[j] === sec[j];
        if (eq) ch = l;
      });
      out += ch;
    }
    return out;
  }
  /** Looser map for the sandbox (any letter): the first byte of each sector. */
  function letterMap(page) {
    var out = '';
    for (var s = 0; s < SECTORS; s++) {
      var sec = page.subarray(s * SECTOR_SIZE, (s + 1) * SECTOR_SIZE), c = sec[0];
      out += allZero(sec) ? '.' : (c >= 65 && c <= 90 ? String.fromCharCode(c) : '?');
    }
    return out;
  }
  /** Plain-data snapshot of a disk for the Stepper. */
  function snapshot(disk) {
    return {
      pending: disk.pending.map(function (w) { return { page: w.pageNo, map: letterMap(w.data) }; }),
      durable: disk.durable.map(function (p, n) {
        return { page: n, map: letterMap(p), check: verify(p, n), stored: hex8(storedChecksum(p)), computed: hex8(checksum(p, n)) };
      }),
      stats: { writes: disk.stats.writes, syncs: disk.stats.syncs, crashes: disk.stats.crashes },
      off: disk.isPoweredOff()
    };
  }

  /**
   * Regression checks for the Storage contract (the twins of the Zig/Rust tests
   * "a hole below a pending write reads as zeroes", "readChecked: ... PowerLoss
   * when the power is off" and "recover on a fresh store whose first update was
   * cut short"). Returns one line per check; see CONTRACT_EXPECTED.
   */
  function contractChecks() {
    var out = [];
    function attempt(fn) { try { return fn(); } catch (e) { return e instanceof Error ? e.name : 'threw a non-Error'; } }
    var d = new SimDisk(1);
    d.writePage(2, filled('A')); // not synced: the durable image is empty
    out.push('size=' + d.size() + ' durable=' + d.durable.length);
    out.push('read hole 1: ' + attempt(function () { return letterMap(d.readPage(1)); }));
    out.push('read 3: ' + attempt(function () { return letterMap(d.readPage(3)); }));
    out.push('checked 5: ' + attempt(function () { return d.readChecked(5).check; }));
    d.powerOffAfterWrites(0);
    out.push('power off, checked 5: ' + attempt(function () { return d.readChecked(5).check; }));

    // The sandbox sequence that used to throw: double write, "Write home", "Recover".
    d = new SimDisk(1);
    d.writePage(1, sealedPage('A', 1));
    out.push('recover: ' + attempt(function () { var r = new DoubleWrite(d, 1).recover(); return 'intact=' + r.intact + ' blank=' + r.blank; }));
    // A fresh 3-slot store whose first update stopped after the slot write.
    d = new SimDisk(1);
    var dw = new DoubleWrite(d, 3);
    d.powerOffAfterWrites(2);
    attempt(function () { dw.update(0, filled('A')); });
    d.crash('drop'); // the slot is durable, the home write is lost
    out.push('recover: ' + attempt(function () { var r = dw.recover(); return 'restored=' + r.restored + ' blank=' + r.blank; }));
    return out;
  }
  var CONTRACT_EXPECTED = [
    'size=3 durable=0',
    'read hole 1: ........',
    'read 3: OutOfBounds',
    'checked 5: blank',
    'power off, checked 5: PowerLoss',
    'recover: intact=1 blank=0',
    'recover: restored=1 blank=2'
  ];

  /* ---- main.zig `run`, line for line ---- */
  function runProgram() {
    var out = [];
    function line(s) { out.push(s); }
    function printRead(disk, pageNo) {
      var page;
      try { page = disk.readPage(pageNo); } catch (e) {
        if (!(e instanceof OutOfBounds)) throw e;
        line('read  page ' + pageNo + ' -> out of bounds (size=' + disk.size() + ')');
        return;
      }
      line('read  page ' + pageNo + ' -> ' + sectorMap(page, pageNo) + ' ' + verify(page, pageNo));
    }
    function printCrash(disk, mode) {
      var r = disk.crash(mode);
      line('crash(' + mode + '): dropped=' + r.dropped + ' kept=' + r.kept + ' torn=' + r.torn);
    }
    function tryUpdate(fn) { try { fn(); return 'ok'; } catch (e) { if (e instanceof PowerLoss) return 'PowerLoss'; throw e; } }

    line('Chapter 21: durability primitives');
    line('page = 4096 bytes = 8 sectors of 512; one letter per sector; SimDisk seed 2121');

    var disk = new SimDisk(2121);
    line(''); line('== 1. A write is not durable until sync ==');
    var page = sealedPage('A', 0);
    disk.writePage(0, page);
    line('write page 0 = A: pending=' + disk.pending.length + ' durable_pages=' + disk.durable.length);
    printRead(disk, 0);
    printCrash(disk, 'drop');
    printRead(disk, 0);
    disk.writePage(0, page);
    disk.sync();
    line('write page 0 = A, sync: pending=' + disk.pending.length + ' durable_pages=' + disk.durable.length);
    printCrash(disk, 'drop');
    printRead(disk, 0);

    line(''); line('== 2. A torn write, caught by the checksum ==');
    page = sealedPage('B', 0);
    disk.writePage(0, page);
    line('write page 0 = B: pending=' + disk.pending.length + ' durable_pages=' + disk.durable.length);
    printRead(disk, 0);
    printCrash(disk, 'tear');
    printRead(disk, 0);
    page = disk.readPage(0);
    line('checksum: stored=' + hex8(storedChecksum(page)) + ' computed=' + hex8(checksum(page, 0)));

    line(''); line('== 3. The checksum binds a page to its address ==');
    page = sealedPage('A', 0);
    line('page sealed for address 0: checksum=' + hex8(storedChecksum(page)));
    line('verified at address 0: ' + verify(page, 0));
    line('verified at address 1: ' + verify(page, 1) + ' (expected checksum ' + hex8(checksum(page, 1)) + ')');

    line(''); line('== 4. Double write: a second copy makes repair possible ==');
    var disk2 = new SimDisk(2121), dw = new DoubleWrite(disk2, 1);
    line('layout: slot = page ' + dw.slotPage(0) + ', home = page ' + dw.homePage(0));
    dw.update(0, filled('A'));
    line('update to A: writes=' + disk2.stats.writes + ' syncs=' + disk2.stats.syncs);
    disk2.powerOffAfterWrites(2);
    var res = tryUpdate(function () { dw.update(0, filled('B')); });
    line(res === 'ok' ? 'update to B: ok' : 'update to B, power off after 2 writes: ' + res);
    printCrash(disk2, 'tear');
    printRead(disk2, 0);
    printRead(disk2, 1);
    var r = dw.recover();
    line('recover: intact=' + r.intact + ' rolled_forward=' + r.rolled_forward + ' restored=' + r.restored + ' blank=' + r.blank);
    printRead(disk2, 1);

    var modes = ['drop', 'keep', 'tear', 'random'];
    function tally(o, check, pg) { if (check !== 'ok') o.corrupt++; else if (pg[0] === 65) o.old++; else o.new++; }
    function inPlace(crashAfter) {
      var o = { old: 0, new: 0, corrupt: 0 };
      modes.forEach(function (mode) {
        for (var seed = 0; seed < 100; seed++) {
          var d = new SimDisk(seed);
          var upd = function (letter) { var p = filled(letter); seal(p, 0); d.writePage(0, p); d.sync(); };
          upd('A');
          d.powerOffAfterWrites(crashAfter);
          tryUpdate(function () { upd('B'); });
          d.crash(mode);
          var rc = d.readChecked(0);
          tally(o, rc.check, rc.page);
        }
      });
      return o;
    }
    function doubleWrite(crashAfter) {
      var o = { old: 0, new: 0, corrupt: 0 };
      modes.forEach(function (mode) {
        for (var seed = 0; seed < 100; seed++) {
          var d = new SimDisk(seed), w = new DoubleWrite(d, 1);
          w.update(0, filled('A'));
          d.powerOffAfterWrites(crashAfter);
          tryUpdate(function () { w.update(0, filled('B')); });
          d.crash(mode);
          var rep = w.recover(), rc = w.read(0);
          tally(o, rep.unrecoverable ? 'corrupt' : rc.check, rc.page);
        }
      });
      return o;
    }
    line(''); line('== 5. Crash at every write: 4 crash modes x 100 seeds per line ==');
    line('in-place update (1 write, 1 sync):');
    var n, o;
    for (n = 0; n < 2; n++) { o = inPlace(n); line('  power off after ' + n + ' writes: old=' + o.old + ' new=' + o.new + ' corrupt=' + o.corrupt); }
    line('double write (2 writes, 2 syncs), after recover:');
    for (n = 0; n < 3; n++) { o = doubleWrite(n); line('  power off after ' + n + ' writes: old=' + o.old + ' new=' + o.new + ' corrupt=' + o.corrupt); }
    return out.join('\n') + '\n';
  }

  var api = {
    PAGE_SIZE: PAGE_SIZE, SECTOR_SIZE: SECTOR_SIZE, SECTORS: SECTORS,
    SplitMix64: SplitMix64, SimDisk: SimDisk, DoubleWrite: DoubleWrite, PowerLoss: PowerLoss, OutOfBounds: OutOfBounds,
    checksum: checksum, storedChecksum: storedChecksum, seal: seal, verify: verify,
    filled: filled, sealedPage: sealedPage, hex8: hex8,
    sectorMap: sectorMap, letterMap: letterMap, snapshot: snapshot, runProgram: runProgram,
    contractChecks: contractChecks, CONTRACT_EXPECTED: CONTRACT_EXPECTED
  };
  root.Ch21 = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);

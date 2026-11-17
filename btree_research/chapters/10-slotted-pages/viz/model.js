/*
 * Chapter 10 — JavaScript model of the slotted page.
 *
 * A byte-for-byte port of zig/src/slotted_page.zig (and rust/src/slotted_page.rs): same
 * header layout, same first-fit free list, same merge rules, same compaction. The page
 * size is a parameter so the visualization can show a 256-byte page, while the self-test
 * replays the programs' whole scenario on 4096 bytes and compares the printed text.
 *
 * Classic script: defines the global `Ch10`. Also loadable from node (`require`).
 */
(function (root) {
  'use strict';

  var HEADER_SIZE = 16, SLOT_SIZE = 2, CELL_HEADER_SIZE = 4, FREE_BLOCK_HEADER_SIZE = 4, MAX_FRAG_BYTES = 60;
  var OFF_CELL_COUNT = 0, OFF_CONTENT_START = 2, OFF_FIRST_FREE = 4, OFF_FRAG_BYTES = 6, OFF_KIND = 7;
  var SLIVER_MAX = FREE_BLOCK_HEADER_SIZE - 1;

  /** ASCII string -> array of byte values. */
  function bytesOf(s) {
    if (typeof s !== 'string') return s;
    var out = [];
    for (var i = 0; i < s.length; i++) out.push(s.charCodeAt(i) & 255);
    return out;
  }
  function strOf(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    return s;
  }
  /** memcmp order; a prefix sorts before a longer key. Returns <0, 0, >0. */
  function cmpBytes(a, b) {
    var n = Math.min(a.length, b.length);
    for (var i = 0; i < n; i++) if (a[i] !== b[i]) return a[i] - b[i];
    return a.length - b.length;
  }
  function cellSize(keyLen, valueLen) { return CELL_HEADER_SIZE + keyLen + valueLen; }

  function Page(size) {
    this.size = size || 4096;
    this.buf = new Uint8Array(this.size);
    this.wr16(OFF_CONTENT_START, this.size);
    this.maxCellSize = this.size - HEADER_SIZE - SLOT_SIZE;
    this.on = null;          // optional event hook used by the visualization
  }
  var P = Page.prototype;

  P.rd16 = function (off) { return this.buf[off] | (this.buf[off + 1] << 8); };
  P.wr16 = function (off, v) { this.buf[off] = v & 255; this.buf[off + 1] = (v >> 8) & 255; };
  P.emit = function (e) { if (this.on) this.on(e); };

  P.count = function () { return this.rd16(OFF_CELL_COUNT); };
  P.slot = function (i) { return this.rd16(HEADER_SIZE + i * SLOT_SIZE); };
  P.cellSizeAt = function (off) { return cellSize(this.rd16(off), this.rd16(off + 2)); };
  P.key = function (i) {
    var off = this.slot(i);
    return Array.prototype.slice.call(this.buf, off + CELL_HEADER_SIZE, off + CELL_HEADER_SIZE + this.rd16(off));
  };
  P.value = function (i) {
    var off = this.slot(i), start = off + CELL_HEADER_SIZE + this.rd16(off);
    return Array.prototype.slice.call(this.buf, start, start + this.rd16(off + 2));
  };

  /** Lower-bound binary search over the slot array. */
  P.search = function (wanted) {
    wanted = bytesOf(wanted);
    var lo = 0, hi = this.count();
    while (lo < hi) {
      var mid = lo + ((hi - lo) >> 1);
      var c = cmpBytes(this.key(mid), wanted);
      this.emit({ t: 'probe', mid: mid, lo: lo, hi: hi, less: c < 0, equal: c === 0 });
      if (c < 0) lo = mid + 1; else hi = mid;
    }
    var found = lo < this.count() && cmpBytes(this.key(lo), wanted) === 0;
    this.emit({ t: 'searched', found: found, index: lo });
    return { found: found, index: lo };
  };
  P.get = function (wanted) {
    var r = this.search(wanted);
    return r.found ? this.value(r.index) : null;
  };

  /** Insert or overwrite. Returns null on success, else 'PageFull' | 'CellTooLarge'. */
  P.put = function (k, v) {
    k = bytesOf(k); v = bytesOf(v);
    var r = this.search(k);
    if (!r.found) return this.insertAt(r.index, k, v);

    var off = this.slot(r.index);
    var oldSize = this.cellSizeAt(off), newSize = cellSize(k.length, v.length);
    if (newSize === oldSize) {
      this.buf.set(v, off + CELL_HEADER_SIZE + k.length);
      this.emit({ t: 'overwrite', index: r.index, off: off, size: newSize });
      return null;
    }
    if (newSize > this.maxCellSize) return this.refuse('CellTooLarge', newSize, this.maxCellSize);
    if (newSize > this.freeBytes() + oldSize) return this.refuse('PageFull', newSize, this.freeBytes() + oldSize);
    this.emit({ t: 'replace', index: r.index, oldSize: oldSize, newSize: newSize });
    this.deleteAt(r.index);
    return this.insertAt(r.index, k, v);
  };
  P.refuse = function (error, need, have) {
    this.emit({ t: 'refuse', error: error, need: need, have: have });
    return error;
  };

  P.delete = function (wanted) {
    var r = this.search(wanted);
    if (r.found) this.deleteAt(r.index);
    return r.found;
  };

  P.insertAt = function (index, k, v) {
    k = bytesOf(k); v = bytesOf(v);
    var n = this.count();
    var size = cellSize(k.length, v.length);
    if (size > this.maxCellSize) return this.refuse('CellTooLarge', size, this.maxCellSize);
    if (size + SLOT_SIZE > this.freeBytes()) return this.refuse('PageFull', size + SLOT_SIZE, this.freeBytes());

    var off = this.allocSpace(size);
    this.wr16(off, k.length);
    this.wr16(off + 2, v.length);
    this.buf.set(k, off + CELL_HEADER_SIZE);
    this.buf.set(v, off + CELL_HEADER_SIZE + k.length);

    var at = HEADER_SIZE + index * SLOT_SIZE, end = HEADER_SIZE + n * SLOT_SIZE;
    this.buf.copyWithin(at + SLOT_SIZE, at, end);
    this.wr16(at, off);
    this.wr16(OFF_CELL_COUNT, n + 1);
    this.emit({ t: 'inserted', index: index, off: off, size: size, moved: n - index });
    return null;
  };

  P.deleteAt = function (index) {
    var n = this.count();
    var off = this.slot(index), size = this.cellSizeAt(off);
    this.emit({ t: 'unslot', index: index, off: off, size: size, moved: n - 1 - index });

    var at = HEADER_SIZE + index * SLOT_SIZE, end = HEADER_SIZE + n * SLOT_SIZE;
    this.buf.copyWithin(at, at + SLOT_SIZE, end);
    this.buf.fill(0, end - SLOT_SIZE, end);
    this.wr16(OFF_CELL_COUNT, n - 1);

    if (n === 1) {
      this.wr16(OFF_CONTENT_START, this.size);
      this.wr16(OFF_FIRST_FREE, 0);
      this.buf[OFF_FRAG_BYTES] = 0;
      this.emit({ t: 'freed', how: 'reset', off: off, size: size });
    } else {
      this.freeSpace(off, size);
    }
  };

  P.compact = function (explicit) {
    if (explicit) this.emit({ t: 'compact-start' });
    var scratch = this.buf.slice();
    var top = this.size, n = this.count();
    for (var i = 0; i < n; i++) {
      var off = this.slot(i);
      var size = cellSize(scratch[off] | (scratch[off + 1] << 8), scratch[off + 2] | (scratch[off + 3] << 8));
      top -= size;
      this.buf.set(scratch.subarray(off, off + size), top);
      this.wr16(HEADER_SIZE + i * SLOT_SIZE, top);
    }
    this.buf.fill(0, HEADER_SIZE + n * SLOT_SIZE, top);
    this.wr16(OFF_CONTENT_START, top);
    this.wr16(OFF_FIRST_FREE, 0);
    this.buf[OFF_FRAG_BYTES] = 0;
    this.emit({ t: 'compacted', explicit: !!explicit });
  };

  P.stats = function () {
    var n = this.count(), contentStart = this.rd16(OFF_CONTENT_START);
    var s = {
      cellCount: n, contentStart: contentStart, gap: contentStart - (HEADER_SIZE + n * SLOT_SIZE),
      freeBlockCount: 0, freeBlockBytes: 0, largestFreeBlock: 0, fragBytes: this.buf[OFF_FRAG_BYTES], freeBytes: 0
    };
    for (var block = this.rd16(OFF_FIRST_FREE); block !== 0; block = this.rd16(block)) {
      var size = this.rd16(block + 2);
      s.freeBlockCount++;
      s.freeBlockBytes += size;
      s.largestFreeBlock = Math.max(s.largestFreeBlock, size);
    }
    s.freeBytes = s.gap + s.freeBlockBytes + s.fragBytes;
    return s;
  };
  P.freeBytes = function () { return this.stats().freeBytes; };
  P.fits = function (keyLen, valueLen) { return cellSize(keyLen, valueLen) + SLOT_SIZE <= this.freeBytes(); };
  P.freeBlocks = function () {
    var out = [];
    for (var block = this.rd16(OFF_FIRST_FREE); block !== 0; block = this.rd16(block)) out.push({ offset: block, size: this.rd16(block + 2) });
    return out;
  };

  // ---- the allocator inside the page ------------------------------------------------

  /**
   * First fit over the free list, without changing anything: the Zig/Rust code finds and
   * takes the block in one loop; here the two halves are separate so that the
   * visualization can show the decision before it is carried out.
   */
  P.findFreeBlock = function (size) {
    var prev = 0;
    for (var block = this.rd16(OFF_FIRST_FREE); block !== 0; prev = block, block = this.rd16(block)) {
      var blockSize = this.rd16(block + 2);
      if (blockSize < size) continue;
      var rest = blockSize - size;
      if (rest >= FREE_BLOCK_HEADER_SIZE) return { prev: prev, block: block, blockSize: blockSize, rest: rest, tail: true };
      if (this.buf[OFF_FRAG_BYTES] + rest > MAX_FRAG_BYTES) continue;
      return { prev: prev, block: block, blockSize: blockSize, rest: rest, tail: false };
    }
    return null;
  };

  P.allocSpace = function (size) {
    var slotsEnd = HEADER_SIZE + this.count() * SLOT_SIZE;
    var contentStart = this.rd16(OFF_CONTENT_START);
    var st = this.stats();

    // 1. Reuse a hole, but only if the gap can still take the new slot.
    var hit = contentStart - slotsEnd >= SLOT_SIZE ? this.findFreeBlock(size) : null;
    if (hit) {
      this.emit({ t: 'plan', how: hit.tail ? 'block-tail' : 'block-whole', size: size, block: hit.block, blockSize: hit.blockSize, rest: hit.rest, stats: st });
      if (hit.tail) {
        this.wr16(hit.block + 2, hit.rest);
        return hit.block + hit.rest;
      }
      this.buf[OFF_FRAG_BYTES] += hit.rest;
      this.wr16(hit.prev === 0 ? OFF_FIRST_FREE : hit.prev, this.rd16(hit.block));
      return hit.block;
    }
    // 2. Otherwise carve from the gap, compacting first if the gap alone is too small.
    if (contentStart - slotsEnd < size + SLOT_SIZE) {
      this.emit({ t: 'plan', how: 'compact', size: size, stats: st, noSlotRoom: contentStart - slotsEnd < SLOT_SIZE });
      this.compact(false);
      contentStart = this.rd16(OFF_CONTENT_START);
    } else {
      this.emit({ t: 'plan', how: 'gap', size: size, stats: st });
    }
    contentStart -= size;
    this.wr16(OFF_CONTENT_START, contentStart);
    return contentStart;
  };

  P.freeSpace = function (offset, size) {
    var start = offset, end = offset + size;
    var frag = this.buf[OFF_FRAG_BYTES];
    var contentStart = this.rd16(OFF_CONTENT_START);
    var info = { t: 'freed', off: offset, size: size, mergedNext: 0, mergedPrev: 0, absorbed: 0 };

    var prev = 0, next = this.rd16(OFF_FIRST_FREE);
    while (next !== 0 && next < start) { prev = next; next = this.rd16(next); }

    if (next !== 0 && end + SLIVER_MAX >= next) {
      frag -= next - end; info.absorbed += next - end; info.mergedNext = next;
      end = next + this.rd16(next + 2);
      next = this.rd16(next);
    }
    if (prev !== 0) {
      var prevEnd = prev + this.rd16(prev + 2);
      if (prevEnd + SLIVER_MAX >= start) {
        frag -= start - prevEnd; info.absorbed += start - prevEnd; info.mergedPrev = prev;
        start = prev;
        prev = this.predecessorOf(start);
      }
    }
    if (start <= contentStart + SLIVER_MAX) {
      frag -= start - contentStart; info.absorbed += start - contentStart;
      this.wr16(OFF_CONTENT_START, end);
      this.wr16(OFF_FIRST_FREE, next);
      info.how = 'gap';
    } else {
      this.wr16(start, next);
      this.wr16(start + 2, end - start);
      this.wr16(prev === 0 ? OFF_FIRST_FREE : prev, start);
      info.how = 'block';
    }
    this.buf[OFF_FRAG_BYTES] = frag;
    info.start = start; info.end = end;
    this.emit(info);
  };
  P.predecessorOf = function (block) {
    var prev = 0, cur = this.rd16(OFF_FIRST_FREE);
    while (cur !== block) { prev = cur; cur = this.rd16(cur); }
    return prev;
  };

  // ---- validation (same checks, same order, same error names) -----------------------

  /** Byte ownership map of the content area: 0 unclaimed, 1 cell, 2 free block. Null on error. */
  P.validate = function () {
    var n = this.count(), slotsEnd = HEADER_SIZE + n * SLOT_SIZE, contentStart = this.rd16(OFF_CONTENT_START);
    if (slotsEnd > contentStart || contentStart > this.size) return 'BadHeader';
    var owner = new Uint8Array(this.size), i, j;
    for (i = 0; i < n; i++) {
      var off = this.slot(i);
      if (off < contentStart || off + CELL_HEADER_SIZE > this.size) return 'SlotOutOfRange';
      var end = off + this.cellSizeAt(off);
      if (end > this.size) return 'SlotOutOfRange';
      for (j = off; j < end; j++) { if (owner[j]) return 'CellOverlap'; owner[j] = 1; }
    }
    var minStart = contentStart + FREE_BLOCK_HEADER_SIZE;
    for (var block = this.rd16(OFF_FIRST_FREE); block !== 0; block = this.rd16(block)) {
      if (block < minStart || block + FREE_BLOCK_HEADER_SIZE > this.size) return 'FreeListCorrupt';
      var size = this.rd16(block + 2);
      if (size < FREE_BLOCK_HEADER_SIZE || block + size > this.size) return 'FreeListCorrupt';
      for (j = block; j < block + size; j++) { if (owner[j]) return 'CellOverlap'; owner[j] = 2; }
      minStart = block + size + FREE_BLOCK_HEADER_SIZE;
    }
    var unclaimed = 0;
    for (j = contentStart; j < this.size; j++) if (!owner[j]) unclaimed++;
    if (unclaimed !== this.buf[OFF_FRAG_BYTES] || unclaimed > MAX_FRAG_BYTES) return 'FragmentMismatch';
    for (i = 1; i < n; i++) if (cmpBytes(this.key(i - 1), this.key(i)) >= 0) return 'KeysOutOfOrder';
    this._owner = owner;
    return null;
  };

  // ---- a plain-data picture of the page for BTViz.PageView / HexGrid ---------------

  P.view = function () {
    var n = this.count(), st = this.stats(), cells = [], slots = [], rows = [], i;
    for (i = 0; i < n; i++) {
      var off = this.slot(i), k = strOf(this.key(i)), v = strOf(this.value(i));
      var id = 'c:' + k;
      slots.push(id);
      cells.push({ id: id, off: off, len: this.cellSizeAt(off), label: k === '' ? '""' : k });
      rows.push({ slot: i, key: k, value: v, off: off, len: this.cellSizeAt(off) });
    }
    var blocks = this.freeBlocks();
    blocks.forEach(function (b) { cells.push({ id: 'f:' + b.offset, off: b.offset, len: b.size, label: 'free ' + b.size, dead: true, kind: 'free' }); });
    // Fragments are whatever the content area does not account for.
    var owner = new Uint8Array(this.size);
    cells.forEach(function (c) { for (var j = c.off; j < c.off + c.len; j++) owner[j] = 1; });
    var frags = [];
    for (var j = st.contentStart; j < this.size; j++) {
      if (owner[j]) continue;
      var from = j;
      while (j + 1 < this.size && !owner[j + 1]) j++;
      frags.push({ offset: from, size: j - from + 1 });
      cells.push({ id: 'x:' + from, off: from, len: j - from + 1, label: '', dead: true, kind: 'frag' });
    }
    return {
      size: this.size, headerSize: HEADER_SIZE, slotSize: SLOT_SIZE,
      header: [
        { name: 'n', len: 2, value: n }, { name: 'top', len: 2, value: st.contentStart },
        { name: 'ff', len: 2, value: this.rd16(OFF_FIRST_FREE) }, { name: 'fr', len: 1, value: st.fragBytes },
        { name: 'k', len: 1, value: this.buf[OFF_KIND] }, { name: 'user area', len: 8, value: '0' }
      ],
      slots: slots, cells: cells, rows: rows, blocks: blocks, frags: frags, stats: st,
      bytes: Array.prototype.slice.call(this.buf)
    };
  };

  // ---- the programs' fixed scenario, printed exactly like demo.zig / demo.rs -------

  var MASK64 = (typeof BigInt === 'function') ? (BigInt(1) << BigInt(64)) - BigInt(1) : null;

  /** common/ops: SplitMix64 + the operation stream, with BigInt for the 64-bit maths. */
  function OpStream(seed, count, keySpace) {
    this.state = BigInt(seed); this.remaining = count; this.keySpace = BigInt(keySpace);
  }
  OpStream.prototype.nextU64 = function () {
    this.state = (this.state + BigInt('0x9E3779B97F4A7C15')) & MASK64;
    var z = this.state;
    z = ((z ^ (z >> BigInt(30))) * BigInt('0xBF58476D1CE4E5B9')) & MASK64;
    z = ((z ^ (z >> BigInt(27))) * BigInt('0x94D049BB133111EB')) & MASK64;
    return z ^ (z >> BigInt(31));
  };
  OpStream.prototype.below = function (n) { return (this.nextU64() * BigInt(n)) >> BigInt(64); };
  OpStream.prototype.next = function () {   // default weights 4, 2, 3, 1
    if (this.remaining === 0) return null;
    this.remaining--;
    var r = Number(this.below(10));
    if (r < 4) { var key = this.below(this.keySpace); return { op: 'put', key: key, value: this.nextU64() }; }
    if (r < 6) return { op: 'delete', key: this.below(this.keySpace) };
    if (r < 9) return { op: 'get', key: this.below(this.keySpace) };
    var a = this.below(this.keySpace), b = this.below(this.keySpace);
    return { op: 'range', lo: a < b ? a : b, hi: (a > b ? a : b) + BigInt(1) };
  };
  /** workload.keyBytes: 8 bytes big-endian, then key % 5 bytes of 'x'. */
  function keyBytes(key) {
    var out = [], i;
    for (i = 7; i >= 0; i--) out.push(Number((key >> BigInt(8 * i)) & BigInt(255)));
    for (i = Number(key % BigInt(5)); i > 0; i--) out.push(120);
    return out;
  }
  /** workload.valueBytes: value % 40 bytes derived from the bits of value. */
  function valueBytes(value) {
    var out = [], len = Number(value % BigInt(40));
    for (var i = 0; i < len; i++) out.push((Number((value >> BigInt(8 * (i % 8))) & BigInt(255)) ^ i) & 255);
    return out;
  }
  function fnv1a64(bytes) {
    var h = BigInt('0xcbf29ce484222325'), prime = BigInt('0x100000001b3');
    for (var i = 0; i < bytes.length; i++) h = ((h ^ BigInt(bytes[i])) * prime) & MASK64;
    return ('0000000000000000' + h.toString(16)).slice(-16);
  }

  var PART_ONE = [
    ['put', 'mango', 'yellow'], ['put', 'apple', 'red'], ['put', 'kiwi', 'green'], ['put', 'cherry', 'dark red'],
    ['put', 'fig', 'purple'], ['delete', 'kiwi'], ['delete', 'apple'], ['put', 'banana', 'yellow'], ['put', 'pea', 'g'],
    ['delete', 'fig'], ['delete', 'mango'], ['compact']
  ];

  function describe(page) {
    var s = page.stats(), n = page.count(), line = '  cells=' + s.cellCount + ' content_start=' + s.contentStart + ' gap=' + s.gap + ' free_blocks=[';
    line += page.freeBlocks().map(function (b) { return b.offset + '+' + b.size; }).join(' ');
    line += '] frag=' + s.fragBytes + ' free=' + s.freeBytes + '\n  slots:';
    if (n === 0) line += ' (none)';
    for (var i = 0; i < n; i++) line += ' ' + strOf(page.key(i)) + '@' + page.slot(i);
    return line + '\n';
  }
  function describeShort(page) {
    var s = page.stats();
    return '  cells=' + s.cellCount + ' content_start=' + s.contentStart + ' gap=' + s.gap + ' free_blocks=' + s.freeBlockCount +
      ' (' + s.freeBlockBytes + ' bytes, largest ' + s.largestFreeBlock + ') frag=' + s.fragBytes + ' free=' + s.freeBytes + '\n';
  }
  function dumpRows(buf, start, end) {
    var out = '';
    for (var off = start; off < end; off += 16) {
      var row = buf.subarray(off, Math.min(off + 16, end)), hex = '', asc = '';
      for (var i = 0; i < 16; i++) {
        hex += i < row.length ? ('0' + row[i].toString(16)).slice(-2) + ' ' : '   ';
        if (i === 7) hex += ' ';
      }
      for (i = 0; i < row.length; i++) asc += row[i] >= 0x20 && row[i] <= 0x7e ? String.fromCharCode(row[i]) : '.';
      out += ('00000000' + off.toString(16)).slice(-8) + '  ' + hex + ' |' + asc + '|\n';
    }
    return out;
  }
  function repeat(ch, n) { var a = []; for (var i = 0; i < n; i++) a.push(ch.charCodeAt(0)); return a; }
  function name(i) { return 'k' + ('000' + i).slice(-3); }

  /** The complete stdout of `zig build run` / `cargo run`, recomputed by this model. */
  function demoText() {
    var out = '', page = new Page(4096), i;
    out += '== Part 1: one page, step by step ==\ninit\n' + describe(page);
    PART_ONE.forEach(function (s) {
      if (s[0] === 'put') { out += 'put ' + s[1] + '=' + s[2] + ' (' + cellSize(s[1].length, s[2].length) + '-byte cell)\n'; page.put(s[1], s[2]); }
      else if (s[0] === 'delete') { out += 'delete ' + s[1] + '\n'; page.delete(s[1]); }
      else { out += 'compact\n'; page.compact(false); }
      if (page.validate()) throw new Error('part 1: ' + page.validate());
      out += describe(page);
    });
    out += 'header and slot array:\n' + dumpRows(page.buf, 0, 32);
    out += 'content area:\n' + dumpRows(page.buf, page.stats().contentStart & ~15, 4096);

    page = new Page(4096);
    var filler = repeat('.', 96), n = 0;
    out += '\n== Part 2: fragmentation and automatic compaction ==\n';
    while (page.fits(4, filler.length)) { page.put(name(n), filler); n++; }
    out += 'fill with ' + cellSize(4, filler.length) + '-byte cells until the next one does not fit\n' + describeShort(page);
    for (i = 0; i < n; i += 2) page.delete(name(i));
    out += 'delete every other cell\n' + describeShort(page);
    out += 'put big (' + cellSize(3, 500) + '-byte cell): no free block and no gap is large enough, so the page compacts first\n';
    page.put('big', repeat('B', 500));
    out += describeShort(page);
    out += 'put huge (' + cellSize(4, 2000) + '-byte cell): ' + page.put('huge', repeat('H', 2000)) + ', page unchanged\n' + describeShort(page);
    if (page.validate()) throw new Error('part 2: ' + page.validate());

    page = new Page(4096);
    out += '\n== Part 3: 3000 random operations on one page ==\nseed=10 count=3000 key_space=300\n';
    var c = { puts: 0, full: 0, deletes: 0, deleteHits: 0, gets: 0, getHits: 0, ranges: 0, rangeCells: 0, maxBlocks: 0, maxFrag: 0 };
    var stream = new OpStream(10, 3000, 300), op;
    while ((op = stream.next())) {
      if (op.op === 'put') { c.puts++; if (page.put(keyBytes(op.key), valueBytes(op.value))) c.full++; }
      else if (op.op === 'delete') { c.deletes++; if (page.delete(keyBytes(op.key))) c.deleteHits++; }
      else if (op.op === 'get') { c.gets++; if (page.get(keyBytes(op.key)) !== null) c.getHits++; }
      else { c.ranges++; c.rangeCells += page.search(keyBytes(op.hi)).index - page.search(keyBytes(op.lo)).index; }
      var s = page.stats();
      c.maxBlocks = Math.max(c.maxBlocks, s.freeBlockCount);
      c.maxFrag = Math.max(c.maxFrag, s.fragBytes);
    }
    if (page.validate()) throw new Error('part 3: ' + page.validate());
    out += 'put: ' + c.puts + ' (' + c.full + ' refused with PageFull)\n';
    out += 'delete: ' + c.deletes + ' (' + c.deleteHits + ' found)\n';
    out += 'get: ' + c.gets + ' (' + c.getHits + ' found)\n';
    out += 'range: ' + c.ranges + ' (' + c.rangeCells + ' cells visited)\n';
    out += 'most free blocks at once: ' + c.maxBlocks + ', most fragment bytes at once: ' + c.maxFrag + '\n';
    out += describeShort(page) + 'fnv1a64 of the page: ' + fnv1a64(page.buf) + '\n';
    return out;
  }

  var Ch10 = {
    Page: Page, cellSize: cellSize, bytesOf: bytesOf, strOf: strOf, cmpBytes: cmpBytes, demoText: demoText, PART_ONE: PART_ONE,
    HEADER_SIZE: HEADER_SIZE, SLOT_SIZE: SLOT_SIZE, CELL_HEADER_SIZE: CELL_HEADER_SIZE,
    FREE_BLOCK_HEADER_SIZE: FREE_BLOCK_HEADER_SIZE, MAX_FRAG_BYTES: MAX_FRAG_BYTES
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = Ch10;
  root.Ch10 = Ch10;
})(typeof window !== 'undefined' ? window : globalThis);

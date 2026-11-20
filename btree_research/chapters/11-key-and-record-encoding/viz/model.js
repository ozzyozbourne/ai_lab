/* Chapter 11 — JS model of the encoders in zig/src and rust/src.
 *
 * A classic script (no modules): defines window.CH11. It also runs under node
 * (`node -e "require('./model.js')"`) so the self-test can be checked offline.
 *
 * The functions mirror the Zig/Rust ones name for name; `report()` rebuilds
 * sections 1 to 6 of expected_output.txt from this model, which is what the
 * page's self-test compares.
 */
(function (root) {
  'use strict';

  var MASK64 = (1n << 64n) - 1n;
  var SIGN = 1n << 63n;

  /* ---------- small helpers -------------------------------------------- */

  function hex(bytes) {
    return bytes.map(function (b) { return (b < 16 ? '0' : '') + b.toString(16); }).join(' ');
  }
  function padEnd(s, n) { s = String(s); while (s.length < n) s += ' '; return s; }
  function padStart(s, n) { s = String(s); while (s.length < n) s = ' ' + s; return s; }
  function quoted(bytes) {
    return '"' + bytes.map(function (c) {
      return c >= 0x20 && c <= 0x7e ? String.fromCharCode(c) : '\\x' + (c < 16 ? '0' : '') + c.toString(16);
    }).join('') + '"';
  }
  /** Text typed by the reader -> bytes. `\xNN` enters an arbitrary byte. */
  function textBytes(s) {
    var out = [], i = 0;
    while (i < s.length) {
      var m = /^\\x([0-9a-fA-F]{2})/.exec(s.slice(i));
      if (m) { out.push(parseInt(m[1], 16)); i += 4; continue; }
      var cp = s.codePointAt(i);
      i += cp > 0xffff ? 2 : 1;
      if (cp < 0x80) out.push(cp);
      else if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
      else if (cp < 0x10000) out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      else out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    }
    return out;
  }
  function compareBytes(a, b) {
    var n = Math.min(a.length, b.length);
    for (var i = 0; i < n; i++) if (a[i] !== b[i]) return { order: a[i] < b[i] ? -1 : 1, at: i, examined: i + 1 };
    return { order: a.length === b.length ? 0 : (a.length < b.length ? -1 : 1), at: n, examined: n };
  }

  /* ---------- varint.zig ------------------------------------------------ */

  function leb128(v) {           // v: BigInt in [0, 2^64)
    var out = [];
    while (v > 0x7fn) { out.push(Number(v & 0x7fn) | 0x80); v >>= 7n; }
    out.push(Number(v));
    return out;
  }
  function sqliteVarint(v) {
    var out = [];
    if (v >> 56n !== 0n) {       // nine bytes: the last one carries 8 bits
      out.unshift(Number(v & 0xffn)); v >>= 8n;
      for (var i = 0; i < 8; i++) { out.unshift(Number(v & 0x7fn) | 0x80); v >>= 7n; }
      return out;
    }
    out.unshift(Number(v & 0x7fn)); v >>= 7n;
    while (v > 0n) { out.unshift(Number(v & 0x7fn) | 0x80); v >>= 7n; }
    return out;
  }
  function zigzag(v) {           // v: BigInt i64 -> BigInt u64
    return ((v << 1n) ^ (v >> 63n)) & MASK64;
  }

  /* ---------- keycodec.zig ---------------------------------------------- */

  function u64be(u) {
    var out = [];
    for (var i = 7; i >= 0; i--) out.push(Number((u >> BigInt(8 * i)) & 0xffn));
    return out;
  }
  function encodeI64(v) { return u64be(BigInt.asUintN(64, v) ^ SIGN); }
  function f64bits(x) {
    var dv = new DataView(new ArrayBuffer(8));
    dv.setFloat64(0, x);
    return dv.getBigUint64(0);
  }
  var CANONICAL_NAN = 0x7ff8000000000000n;
  function encodeF64(x) {
    var bits = f64bits(x);
    if (x === 0) bits = 0n;                       // -0.0 -> +0.0
    if (x !== x) bits = CANONICAL_NAN;            // every NaN -> one NaN
    return u64be((bits & SIGN) === 0n ? bits | SIGN : (~bits) & MASK64);
  }
  function encodeBytes(s) {
    var out = [];
    s.forEach(function (c) { if (c <= 1) out.push(1); out.push(c); });
    out.push(0);
    return out;
  }
  function invert(bytes) { return bytes.map(function (b) { return b ^ 0xff; }); }

  var TAG_NULL_FIRST = 0x00, TAG_VALUE = 0x01, TAG_NULL_LAST = 0x02;

  /* ---------- the people table (row.zig + main.zig) --------------------- */

  /** (name ASC, score DESC NULLS LAST, id ASC) */
  var PEOPLE = [
    { id: 1, name: 'Anna', score: 7n }, { id: 2, name: 'Ann', score: 7n },
    { id: 3, name: 'Ann', score: -2n }, { id: 4, name: 'Ann', score: null },
    { id: 5, name: 'Bo', score: 300n }, { id: 6, name: 'Bo', score: 300n },
    { id: 7, name: '', score: 0n }, { id: 8, name: 'Anna', score: 256n }
  ];
  var ALL_FIXES = { bigEndian: true, signFlip: true, framing: true, descInvert: true };

  /** An i64 payload with some of the fixes switched off (to show what breaks). */
  function intPayload(v, fixes) {
    var u = BigInt.asUintN(64, v);
    if (fixes.signFlip) u ^= SIGN;
    var b = u64be(u);
    return fixes.bigEndian ? b : b.reverse();
  }

  /**
   * Key of one people row. Returns {bytes, roles}: roles[i] is
   * {col: 0|1|2, kind: 'tag'|'data'|'esc'|'term'} for colouring.
   */
  function encodeKey(row, fixes) {
    fixes = fixes || ALL_FIXES;
    var bytes = [], roles = [];
    function put(col, kind, list) { list.forEach(function (b) { bytes.push(b); roles.push({ col: col, kind: kind }); }); }

    var name = textBytes(row.name);
    if (fixes.framing) {
      put(0, 'tag', [TAG_VALUE]);
      name.forEach(function (c) { if (c <= 1) put(0, 'esc', [1]); put(0, 'data', [c]); });
      put(0, 'term', [0]);
    } else {
      put(0, 'data', name);                      // raw concatenation
    }

    if (row.score === null) {
      if (fixes.framing) put(1, 'tag', [TAG_NULL_LAST]);
    } else {
      var p = intPayload(row.score, fixes);
      if (fixes.framing) put(1, 'tag', [TAG_VALUE]);
      put(1, 'data', fixes.descInvert ? invert(p) : p);
    }

    if (fixes.framing) put(2, 'tag', [TAG_VALUE]);
    put(2, 'data', intPayload(BigInt(row.id), fixes));
    return { bytes: bytes, roles: roles };
  }

  /** The oracle: looks at values only. Same rules as row.compareRows. */
  function compareRows(a, b) {
    var c = compareBytes(textBytes(a.name), textBytes(b.name)).order;
    if (c !== 0) return c;
    if (a.score === null || b.score === null) {
      if (a.score !== b.score) return a.score === null ? 1 : -1;   // NULLS LAST, whatever the direction
    } else if (a.score !== b.score) {
      return a.score > b.score ? -1 : 1;                            // DESC
    }
    return a.id === b.id ? 0 : (a.id < b.id ? -1 : 1);
  }

  /* ---------- record.zig ------------------------------------------------ */

  function encodeRecord(row) {
    var name = textBytes(row.name);
    var types = leb128(BigInt(3 + name.length))
      .concat(row.score === null ? [0] : [1], [1]);
    var body = name.concat(row.score === null ? [] : leb128(zigzag(row.score)), leb128(zigzag(BigInt(row.id))));
    return { bytes: leb128(BigInt(types.length)).concat(types, body), headerLen: 1 + types.length };
  }
  /** Columns two records must decode before the comparator can answer. */
  function columnsDecoded(a, b) {
    if (compareBytes(textBytes(a.name), textBytes(b.name)).order !== 0) return 2;
    if (a.score !== b.score) return 4;
    return 6;
  }

  /* ---------- SplitMix64 (common/prng) ----------------------------------- */

  function SplitMix64(seed) { this.state = BigInt.asUintN(64, BigInt(seed)); }
  SplitMix64.prototype.next = function () {
    this.state = (this.state + 0x9E3779B97F4A7C15n) & MASK64;
    var z = this.state;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & MASK64;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & MASK64;
    return z ^ (z >> 31n);
  };
  SplitMix64.prototype.below = function (n) { return Number((this.next() * BigInt(n)) >> 64n); };
  SplitMix64.prototype.shuffle = function (items) {
    for (var i = items.length - 1; i >= 1; i--) {
      var j = this.below(i + 1), t = items[i]; items[i] = items[j]; items[j] = t;
    }
    return items;
  };

  /* ---------- insertion sort by key bytes, recorded as steps ------------- */

  /**
   * rows in arrival order -> {steps, order, comparisons, examined, columns}.
   * Each step's state: {order: [row index…], pair: [posA, posB] | null,
   * diff: byte index | null, sortedUpTo, done, verdict}.
   */
  function sortSteps(rows, fixes) {
    fixes = fixes || ALL_FIXES;
    var keys = rows.map(function (r) { return encodeKey(r, fixes); });
    var order = rows.map(function (_, i) { return i; });
    var steps = [], comparisons = 0, examined = 0, columns = 0;
    function label(i) { return 'id ' + rows[i].id; }
    function k(i) { return '<b class="bt-k">' + label(i) + '</b>'; }

    steps.push({
      caption: 'The rows in arrival order, each with its key bytes. Insertion sort will now order them using ' +
        '<b>nothing but byte comparisons</b>: it does not know which bytes are a name and which a number.',
      state: { order: order.slice(), pair: null, diff: null, sortedUpTo: 1, done: false, comparisons: 0, examined: 0 },
      log: 'start: ' + order.map(function (i) { return rows[i].id; }).join(' ')
    });

    for (var i = 1; i < order.length; i++) {
      var j = i;
      while (j > 0) {
        var a = order[j - 1], b = order[j];
        var c = compareBytes(keys[a].bytes, keys[b].bytes);
        comparisons++; examined += c.examined; columns += columnsDecoded(rows[a], rows[b]);
        var before = order.slice();
        var swap = c.order > 0;
        var where = c.at < Math.min(keys[a].bytes.length, keys[b].bytes.length)
          ? 'First difference at byte ' + c.at + ': <code>' + hex([keys[a].bytes[c.at]]) + '</code> ' + (c.order < 0 ? '&lt;' : '&gt;') +
            ' <code>' + hex([keys[b].bytes[c.at]]) + '</code>'
          : (c.order === 0 ? 'All ' + c.at + ' bytes are equal' : 'One key is a prefix of the other; the shorter one is smaller');
        var role = keys[a].roles[Math.min(c.at, keys[a].roles.length - 1)];
        var colName = ['name', 'score', 'id'][role.col];
        var meaning = !fixes.framing ? '' : ' (inside the <b>' + colName + '</b> column' +
          (role.kind === 'tag' ? ', at its tag byte' : role.kind === 'term' ? ', where the shorter name ends' : '') + ')';
        if (swap) { order[j - 1] = b; order[j] = a; }
        steps.push({
          caption: 'Compare ' + k(a) + ' with ' + k(b) + '. ' + where + meaning + '. ' +
            (swap ? 'The upper key is larger, so the two rows <b>swap</b>.' : 'They are already in order; this row has found its place.'),
          state: { order: before, pair: [j - 1, j], diff: c.at, sortedUpTo: i, done: false, swap: swap, comparisons: comparisons, examined: examined },
          log: label(a) + (c.order < 0 ? ' < ' : c.order > 0 ? ' > ' : ' = ') + label(b) + ' at byte ' + c.at,
          question: {
            prompt: 'Which key is smaller as a byte string: ' + label(a) + ' or ' + label(b) + '?',
            choices: [label(a) + ' (no swap)', label(b) + ' (swap)'],
            answer: swap ? 1 : 0,
            explain: where + '.'
          }
        });
        if (!swap) break;
        j--;
      }
    }

    var logical = rows.map(function (_, i2) { return i2; }).sort(function (x, y) { return compareRows(rows[x], rows[y]) || x - y; });
    var wrong = outOfPlace(order, logical);
    var ok = wrong.length === 0;
    var off = Object.keys(WHAT_BREAKS).filter(function (f) { return !fixes[f]; });
    var why = off.map(function (f) { return WHAT_BREAKS[f]; }).join(' ');
    steps.push({
      caption: ok
        ? 'Sorted with ' + comparisons + ' comparisons that looked at ' + examined + ' byte positions. The result is exactly the ' +
          'logical order (name ASC, score DESC NULLS LAST, id ASC). A comparator over records would have decoded ' + columns +
          ' column values to reach the same order.' +
          (off.length ? ' A fix is switched off, but these particular rows do not expose it: ' + why : '')
        : 'Sorted by bytes, but the result is not the logical order: <b>' + wrong.length + ' row' + (wrong.length === 1 ? ' is' : 's are') +
          ' out of place</b> (marked; the unmarked rows are still in the right order among themselves). ' + why +
          ' A B-tree built on these keys would return wrong range scans.',
      state: { order: order.slice(), pair: null, diff: null, sortedUpTo: order.length, done: true, wrong: wrong, ok: ok, comparisons: comparisons, examined: examined },
      log: (ok ? 'sorted: ' : 'WRONG: ') + order.map(function (r) { return rows[r].id; }).join(' '),
      hold: 2
    });
    return { steps: steps, order: order, logical: logical, keys: keys, comparisons: comparisons, examined: examined, columns: columns, ok: ok };
  }

  /** What goes wrong without each fix, in one sentence (the final caption of figure 1). */
  var WHAT_BREAKS = {
    bigEndian: '<b>Little-endian integers:</b> the first byte compared is the least significant one, so numbers are ordered by ' +
      'their low byte (256, low byte <code>00</code>, lands next to 0).',
    signFlip: '<b>No sign flip:</b> a negative number keeps its top bit set, so it is compared as if it were larger than every ' +
      'positive number.',
    framing: '<b>No tag and terminator:</b> nothing marks where a name ends, so the byte after a short name is compared with the ' +
      'first score byte of the other row ("Anna" against "Ann" plus a score), and a NULL score has no bytes at all.',
    descInvert: '<b>No inversion:</b> the score column sorts ascending although the key asks for DESC.'
  };

  /**
   * The rows that are out of place. A row is certainly fine if it belongs to
   * EVERY longest run of rows that are in logical order relative to each
   * other (every longest increasing subsequence of logical ranks); all other
   * rows are marked. So one displaced row is reported as one row, not as every
   * row it pushed down a position, and when two neighbours are swapped both
   * are marked, because either of them could be the one that moved.
   */
  function outOfPlace(order, logical) {
    var rank = {}, n = order.length, up = [], down = [], longest = 0, i, j;
    logical.forEach(function (r, pos) { rank[r] = pos; });
    var seq = order.map(function (r) { return rank[r]; });
    for (i = 0; i < n; i++) {                  // up[i]: longest increasing run ending at i
      up[i] = 1;
      for (j = 0; j < i; j++) if (seq[j] < seq[i] && up[j] + 1 > up[i]) up[i] = up[j] + 1;
      if (up[i] > longest) longest = up[i];
    }
    for (i = n - 1; i >= 0; i--) {             // down[i]: longest increasing run starting at i
      down[i] = 1;
      for (j = i + 1; j < n; j++) if (seq[i] < seq[j] && down[j] + 1 > down[i]) down[i] = down[j] + 1;
    }
    var onSome = [], perLevel = {};
    for (i = 0; i < n; i++) {
      onSome[i] = up[i] + down[i] - 1 === longest;
      if (onSome[i]) perLevel[up[i]] = (perLevel[up[i]] || 0) + 1;
    }
    // On every longest run = on some longest run, and alone at its position in it.
    return order.filter(function (_, pos) { return !(onSome[pos] && perLevel[up[pos]] === 1); });
  }

  /* ---------- "build one key" pipeline (figure 2) ------------------------ */

  function f64fromBits(bits) {
    var dv = new DataView(new ArrayBuffer(8));
    dv.setBigUint64(0, bits);
    return dv.getFloat64(0);
  }
  /**
   * What the reader typed -> {x, bits} or null. The bits are kept next to the
   * number because a JS number cannot be trusted to carry a NaN's sign and
   * payload. Accepted: a decimal number, inf, -inf, nan, -nan, and `0x` plus
   * up to 16 hex digits for a raw bit pattern (0xfff000000000beef is a NaN).
   */
  function parseFloatInput(s) {
    s = s.trim().toLowerCase();
    var hexBits = /^0x([0-9a-f]{1,16})$/.exec(s);
    if (hexBits) { var raw = BigInt('0x' + hexBits[1]); return { x: f64fromBits(raw), bits: raw }; }
    if (s === 'nan' || s === '+nan') return { x: NaN, bits: CANONICAL_NAN };
    if (s === '-nan') return { x: NaN, bits: CANONICAL_NAN | SIGN };
    if (/^[-+]?(inf|infinity)$/.test(s)) s = s.charAt(0) === '-' ? '-Infinity' : 'Infinity';
    else if (!/^[-+]?(\d+\.?\d*|\.\d+)(e[-+]?\d+)?$/.test(s)) return null;
    var x = Number(s);
    return { x: x, bits: f64bits(x) };
  }
  function parseIntInput(s) {
    s = s.trim();
    if (!/^[-+]?\d+$/.test(s)) return null;
    var v = BigInt(s);
    return v < -(1n << 63n) || v >= (1n << 63n) ? null : v;
  }

  /**
   * kind: 'int' | 'float' | 'text'; text: what the reader typed; desc: bool.
   * Returns steps whose state is {strips: [{label, bytes, marks}], record}.
   * `mark` names the code-panel lines to highlight (CHAPTER_CODE_LINES in code.js).
   */
  function keySteps(kind, text, desc) {
    var steps = [], strips = [];
    function push(label, bytes, marks, caption, lines) {
      strips = strips.concat([{ label: label, bytes: bytes, marks: marks || {} }]);
      steps.push({ caption: caption, state: { strips: strips }, mark: lines || null, snippet: kind });
    }
    function all(n, state) { var m = {}; for (var i = 0; i < n; i++) m[i] = state; return m; }
    var payload;

    if (kind === 'int') {
      var v = parseIntInput(text);
      if (v === null) return { error: 'Type a whole number between -2^63 and 2^63 - 1.' };
      var u = BigInt.asUintN(64, v);
      push('in memory (little-endian)', u64be(u).reverse(), {},
        'The number <b class="bt-k">' + v + '</b> as it sits in memory on most machines: two\'s complement, least significant byte first. ' +
        'Comparing these bytes left to right would compare the <i>least</i> significant byte first.', null);
      push('big-endian', u64be(u), {},
        'Step 1: most significant byte first. Now the first byte that differs between two keys is the most significant difference. ' +
        'This is already correct for unsigned numbers.', 'be');
      payload = encodeI64(v);
      var bin = function (b) { var t = b.toString(2); while (t.length < 8) t = '0' + t; return t.slice(0, 4) + ' ' + t.slice(4); };
      push('sign bit flipped', payload, { 0: 'compare' },
        'Step 2: flip the top bit of the first byte (<code>' + bin(u64be(u)[0]) + '</code> becomes <code>' + bin(payload[0]) + '</code>). In two\'s complement negative numbers have the top bit set, so they would sort <i>after</i> the ' +
        'positive ones. Flipping it moves ' + (v < 0n ? 'this negative number below' : 'this non-negative number above') +
        ' the other half and keeps the order inside each half.', 'flip');
    } else if (kind === 'float') {
      var parsed = parseFloatInput(text);
      if (parsed === null) return { error: 'Type a number, inf, -inf, nan, -nan, or raw bits as hex (0xfff000000000beef).' };
      var x = parsed.x, bits = parsed.bits;
      var shown = x !== x ? 'NaN' : (Object.is(x, -0) ? '-0.0' : String(x));
      push('IEEE 754 bits (big-endian)', u64be(bits), {},
        'The double <b class="bt-k">' + shown + '</b>: 1 sign bit, 11 exponent bits, 52 fraction bits. For non-negative numbers a larger ' +
        'bit pattern means a larger value. For negative numbers it is the other way round (sign-magnitude).', 'bits');
      if (x === 0 && bits !== 0n) {
        bits = 0n;
        push('-0.0 normalised to +0.0', u64be(bits), all(8, 'compare'),
          '-0.0 and +0.0 compare equal, so they must get the same key, or a lookup for 0.0 would miss a stored -0.0. ' +
          'The price: the sign of zero does not survive encoding.', 'zero');
      }
      if (x !== x && bits !== CANONICAL_NAN) {
        bits = CANONICAL_NAN;
        push('NaN made canonical', u64be(bits), all(8, 'compare'),
          'There are 2^53 - 2 different NaN bit patterns: either sign, and any non-zero fraction ("payload"). This one is not the ' +
          'usual <code>7f f8 00 ..</code>. All NaNs must be equal keys, so every NaN is replaced by that one pattern. ' +
          'The price: sign and payload of a NaN do not survive encoding.', 'nan');
      }
      payload = encodeF64(x);
      var neg = (bits & SIGN) !== 0n;
      push(neg ? 'negative: every bit inverted' : 'non-negative: sign bit set', payload, neg ? all(8, 'compare') : { 0: 'compare' },
        neg
          ? 'Negative: invert all 64 bits. That clears the top bit (negatives sort first) and reverses the order among negatives, ' +
            'which is what sign-magnitude needs.'
          : 'Non-negative: set the top bit, so every non-negative number sorts after every negative one. The other 63 bits already ' +
            'sort correctly.' + (x !== x ? ' The canonical NaN lands above +infinity.' : ''), 'sign');
    } else {
      var s = textBytes(text);
      if (s.length > 12) return { error: 'At most 12 bytes, so the strip stays readable.' };
      push('raw bytes', s, {},
        'The string ' + BTViz_esc(quoted(s)) + ' as bytes' + (s.length === 0 ? ' (none at all)' : '') + '. Bytewise comparison of raw strings is ' +
        'lexicographic order already. The trouble starts when another column follows: nothing marks where this one ends.', 'raw');
      var marks = {}, esc = [], n = 0;
      s.forEach(function (c) { if (c <= 1) { marks[esc.length] = 'compare'; esc.push(1); n++; } esc.push(c); });
      if (n > 0) {
        push('00 and 01 escaped', esc, marks,
          'Bytes <code>00</code> and <code>01</code> inside the data get an escape byte <code>01</code> in front (' + n + ' here), ' +
          'so they cannot be mistaken for the terminator. <code>00</code> becomes <code>01 00</code>, <code>01</code> becomes <code>01 01</code>, and ' +
          '<code>02</code> stays <code>02</code>: the order is preserved.', 'escape');
      }
      payload = encodeBytes(s);
      var tm = {}; tm[payload.length - 1] = 'inserted';
      push('terminator added', payload, tm,
        'A <code>00</code> terminator ends the column. It is the smallest possible byte, so a string sorts before every longer string ' +
        'it is a prefix of, whatever the next column contains.', 'term');
    }

    if (desc) {
      payload = invert(payload);
      push('DESC: every byte inverted', payload, all(payload.length, 'split'),
        'Descending column: invert every byte (<code>b ^ ff</code>). If a &lt; b as bytes then ~a &gt; ~b, so the order is exactly reversed.' +
        (kind === 'text' ? ' The terminator is now <code>ff</code>: a string sorts <i>after</i> its extensions, as descending requires.' : ''), 'desc');
    }
    var withTag = [TAG_VALUE].concat(payload), tagMark = { 0: 'found' };
    push('key column = tag + payload', withTag, tagMark,
      'Finally one tag byte in front: <code>01</code> = "a value follows". A NULL is the single byte <code>02</code> (NULLS LAST) or ' +
      '<code>00</code> (NULLS FIRST). The tag is never inverted, so where NULLs go does not depend on ASC or DESC. ' +
      'This column is ' + withTag.length + ' bytes; concatenate the columns and you have a composite key.', 'tag');
    steps[steps.length - 1].hold = 2;
    return { steps: steps, column: withTag };
  }
  function BTViz_esc(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }

  /* ---------- report(): sections 1 to 6 of expected_output.txt ----------- */

  function report() {
    var out = [];
    function line(s) { out.push(s); }

    line('== 1. varints: small numbers, few bytes ==');
    line(padEnd('value', 21) + padEnd('leb128', 31) + 'sqlite');
    [0n, 1n, 127n, 128n, 300n, 16383n, 16384n, 1n << 32n, MASK64].forEach(function (v) {
      line(padEnd(v, 21) + padEnd(hex(leb128(v)), 31) + hex(sqliteVarint(v)));
    });
    line('zigzag:' + [0n, -1n, 1n, -2n, 2n, -64n, 64n].map(function (v) { return ' ' + v + '->' + zigzag(v); }).join(''));
    var a = leb128(129n), c = leb128(256n);
    line('as bytes: leb128(129) = ' + hex(a) + ' ' + (compareBytes(a, c).order > 0 ? '>' : '<=') + ' leb128(256) = ' + hex(c) +
      ', but 129 < 256: varints are not sort keys');
    line('');

    line('== 2. integers as keys ==');
    var ints = [-2n, -1n, 0n, 1n, 256n];
    line('i64 values -2 -1 0 1 256, sorted by comparing the bytes of each encoding:');
    [['little-endian', { bigEndian: false, signFlip: false }], ['big-endian', { bigEndian: true, signFlip: false }],
      ['big-endian + sign flip', { bigEndian: true, signFlip: true }]].forEach(function (e) {
      var enc = ints.map(function (v) { return intPayload(v, e[1]); });
      var order = [0, 1, 2, 3, 4];
      for (var i = 1; i < order.length; i++) {
        for (var j = i; j > 0 && compareBytes(enc[order[j - 1]], enc[order[j]]).order > 0; j--) {
          var t = order[j]; order[j] = order[j - 1]; order[j - 1] = t;
        }
      }
      var sorted = order.every(function (idx, pos) { return idx === pos; });
      line('  ' + padEnd(e[0], 23) + ':' + order.map(function (idx) { return ' ' + ints[idx]; }).join('') + '  ' + (sorted ? '(correct)' : '(WRONG)'));
    });
    ints.forEach(function (v) { line('  ' + padStart(v, 4) + ' -> ' + hex(encodeI64(v))); });
    line('');

    line('== 3. floats as keys ==');
    var prev = null;
    [[-Infinity, '-inf'], [-1.5, '-1.5'], [-0, '-0.0'], [0, '0.0'], [1.5, '1.5'], [Infinity, '+inf'], [NaN, 'NaN']].forEach(function (f) {
      var e = encodeF64(f[0]);
      var rel = prev === null ? '' : ['  (< previous: BUG)', '  (= previous)', '  (> previous)'][compareBytes(e, prev).order + 1];
      line('  ' + padStart(f[1], 4) + ' -> ' + hex(e) + rel);
      prev = e;
    });
    line('');

    line('== 4. strings as keys ==');
    ['', 'a', 'a\\x00', 'a\\x01', 'a\\x02', 'ab', 'b'].forEach(function (s) {
      var b = textBytes(s);
      line('  ' + padEnd(quoted(b), 8) + ' -> ' + hex(encodeBytes(b)));
    });
    function pair(x, y) { return hex([1].concat(encodeBytes(textBytes(x)), [1], encodeBytes(textBytes(y)))); }
    line('  raw concatenation: ("a","b") and ("ab","") are both 61 62');
    line('  as key columns   : ("a","b") = ' + pair('a', 'b') + '   ("ab","") = ' + pair('ab', ''));
    line('');

    line('== 5. composite keys: (name ASC, score DESC NULLS LAST, id ASC) ==');
    var arrival = arrivalOrder();
    line('arrival order (ids):' + arrival.map(function (r) { return ' ' + r.id; }).join(''));
    var s = sortSteps(arrival);
    line('sorted by key bytes (' + s.comparisons + ' comparisons, ' + s.examined + ' byte positions examined):');
    s.order.forEach(function (i) {
      var r = arrival[i];
      line('  id ' + r.id + '  ' + padEnd(quoted(textBytes(r.name)), 6) + ' ' + padStart(r.score === null ? 'NULL' : r.score, 4) + '  ' + hex(s.keys[i].bytes));
    });
    line('sorted by record comparator (' + s.comparisons + ' comparisons, ' + s.columns + ' columns decoded):');
    line(' ' + s.logical.map(function (i) { return ' ' + arrival[i].id; }).join(''));
    line('same order: ' + (s.ok ? 'yes' : 'NO'));
    var keyBytes = 0, recBytes = 0;
    arrival.forEach(function (r, i) { keyBytes += s.keys[i].bytes.length; recBytes += encodeRecord(r).bytes.length; });
    line('space: 8 keys = ' + keyBytes + ' bytes of a 256-byte fixed buffer, 8 records = ' + recBytes + ' bytes');
    line('');

    line('== 6. one row, two encodings ==');
    var row = PEOPLE[0], rec = encodeRecord(row).bytes, key = encodeKey(row).bytes;
    var rowText = '(' + quoted(textBytes(row.name)) + ', ' + row.score + ', ' + row.id + ')';
    line('row    ' + rowText);
    line('record ' + hex(rec) + '  (' + rec.length + ' bytes)');
    line('key    ' + hex(key) + '  (' + key.length + ' bytes)');
    line('record -> ' + rowText + '   (self-describing)');
    line('key    -> ' + rowText + '   (needs the schema)');
    line('');
    return out.join('\n') + '\n';
  }

  /** The seeded shuffle of main.zig: SplitMix64(11) over row indices 0..7. */
  function arrivalOrder() {
    return new SplitMix64(11).shuffle([0, 1, 2, 3, 4, 5, 6, 7]).map(function (i) { return PEOPLE[i]; });
  }

  var CH11 = {
    hex: hex, quoted: quoted, textBytes: textBytes, compareBytes: compareBytes,
    leb128: leb128, sqliteVarint: sqliteVarint, zigzag: zigzag,
    encodeI64: encodeI64, encodeF64: encodeF64, encodeBytes: encodeBytes, invert: invert,
    PEOPLE: PEOPLE, ALL_FIXES: ALL_FIXES, encodeKey: encodeKey, encodeRecord: encodeRecord, compareRows: compareRows,
    SplitMix64: SplitMix64, arrivalOrder: arrivalOrder, sortSteps: sortSteps, keySteps: keySteps,
    parseIntInput: parseIntInput, parseFloatInput: parseFloatInput, outOfPlace: outOfPlace, report: report
  };
  root.CH11 = CH11;
  if (typeof module !== 'undefined' && module.exports) module.exports = CH11;
})(typeof window !== 'undefined' ? window : globalThis);

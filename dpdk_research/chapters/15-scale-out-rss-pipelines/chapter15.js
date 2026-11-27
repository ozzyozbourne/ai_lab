/* Chapter 15 widgets: Toeplitz bit-level stepper, RSS pipeline/RETA editor,
 * pipeline bottleneck simulator, reorder window (scripted + sandbox) and the
 * measured comparison chart. Vanilla JS on top of ../../assets/course.js. */
(function () {
  'use strict';
  var CJ = window.CourseJS, S = CJ.svg;

  /* ------------------------------------------------------------------ */
  /* Toeplitz in JS (same algorithm as rte_softrss)                      */
  /* ------------------------------------------------------------------ */
  var MS_KEY = [0x6d, 0x5a, 0x56, 0xda, 0x25, 0x5b, 0x0e, 0xc2, 0x41, 0x67, 0x25, 0x3d, 0x43, 0xa3,
    0x8f, 0xb0, 0xd0, 0xca, 0x2b, 0xcb, 0xae, 0x7b, 0x30, 0xb4, 0x77, 0xcb, 0x2d, 0xa3, 0x80, 0x30,
    0xf2, 0x0c, 0x6a, 0x42, 0xb7, 0x3b, 0xbe, 0xac, 0x01, 0xfa];
  var SYM_KEY = [];
  for (var k = 0; k < 40; k += 2) { SYM_KEY.push(0x6d, 0x5a); }

  function bytesToBits(bytes) {
    var bits = [];
    bytes.forEach(function (b) { for (var i = 7; i >= 0; i--) bits.push((b >> i) & 1); });
    return bits;
  }
  function window32(keyBits, i) {
    var v = 0;
    for (var j = 0; j < 32; j++) v = ((v << 1) | keyBits[i + j]) >>> 0;
    return v >>> 0;
  }
  /* tuple: {src:[4 bytes], dst:[4], sport, dport} -> 12 bytes, network order */
  function tupleBytes(t) {
    return t.src.concat(t.dst, [t.sport >> 8, t.sport & 255, t.dport >> 8, t.dport & 255]);
  }
  function toeplitz(bytes, keyBits) {
    var r = 0, bits = bytesToBits(bytes);
    for (var i = 0; i < bits.length; i++) if (bits[i]) r = (r ^ window32(keyBits, i)) >>> 0;
    return r >>> 0;
  }
  function hex8(v) { return '0x' + ('00000000' + (v >>> 0).toString(16)).slice(-8); }
  function parseIp(s) {
    var p = String(s).trim().split('.').map(Number);
    if (p.length !== 4 || p.some(function (x) { return !(x >= 0 && x <= 255) || isNaN(x); })) return null;
    return p;
  }
  function ipStr(a) { return a.join('.'); }
  var QCOL = ['c1', 'c2', 'c3', 'c5', 'c6', 'c4', 'c7', 'c1'];
  function qcls(q) { return 'svg-fill-' + QCOL[q % QCOL.length] + (q === 7 ? ' q8' : ''); }

  /* seeded PRNG so the 10k-flow histogram is stable */
  function mulberry(a) {
    return function () {
      a |= 0; a = (a + 0x6D2B79F5) | 0;
      var t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  /* ------------------------------------------------------------------ */
  /* Widget 1: Toeplitz bit by bit, with predict                         */
  /* ------------------------------------------------------------------ */
  function toeplitzWidget() {
    var root = document.getElementById('w-toeplitz');
    if (!root) return;
    var svg = root.querySelector('svg');
    var info = root.querySelector('.tz-info');
    var pred = root.querySelector('.tz-predict');
    var VEC = [
      { src: [66, 9, 149, 187], dst: [161, 142, 100, 80], sport: 2794, dport: 1766, want: 0x51ccc178 },
      { src: [199, 92, 111, 2], dst: [65, 69, 140, 83], sport: 14230, dport: 4739, want: 0xc626b0ea },
      { src: [24, 19, 198, 95], dst: [12, 22, 207, 184], sport: 12898, dport: 38024, want: 0x5c2b394a }
    ];
    var keyBits = bytesToBits(MS_KEY);
    var st = {};
    var CW = 19, CH = 14, X0 = 78;
    var cells = { inp: [], key: [], win: [], res: [] };

    function row(arr, y, n, cls) {
      for (var i = 0; i < n; i++) {
        var r = S.rect(svg, X0 + (i % 32) * CW, y + Math.floor(i / 32) * (CH + 4), CW - 2, CH, cls);
        r.setAttribute('rx', 2);
        var t = S.text(svg, X0 + (i % 32) * CW + (CW - 2) / 2, y + Math.floor(i / 32) * (CH + 4) + CH / 2 + 0.5, '', 'svg-label center mono tz-bit');
        arr.push({ r: r, t: t });
      }
    }
    S.text(svg, 4, 22, 'input tuple', 'svg-label small bold');
    S.text(svg, 4, 36, '96 bits', 'svg-label small muted');
    S.text(svg, 4, 50, 'src|dst|ports', 'svg-label small muted');
    row(cells.inp, 12, 96, 'svg-slot');
    S.text(svg, 4, 108, 'key bits', 'svg-label small bold');
    S.text(svg, 4, 122, '0..127', 'svg-label small muted');
    row(cells.key, 98, 128, 'svg-slot');
    S.text(svg, 4, 204, 'window', 'svg-label small bold');
    S.text(svg, 4, 218, 'key[i..i+31]', 'svg-label small muted');
    row(cells.win, 196, 32, 'svg-slot');
    S.text(svg, 4, 244, 'result', 'svg-label small bold');
    S.text(svg, 4, 258, '32 bits', 'svg-label small muted');
    row(cells.res, 236, 32, 'svg-slot');
    var cursor = S.rect(svg, 0, 0, CW, CH + 4, 'svg-highlight tz-cursor');
    cursor.setAttribute('fill', 'none');
    var foot = S.text(svg, X0, 282, '', 'svg-label mono');

    function readTuple() {
      var src = parseIp(root.querySelector('#tz-src').value), dst = parseIp(root.querySelector('#tz-dst').value);
      var sp = +root.querySelector('#tz-sport').value, dp = +root.querySelector('#tz-dport').value;
      if (!src || !dst || !(sp >= 0 && sp < 65536) || !(dp >= 0 && dp < 65536)) return null;
      return { src: src, dst: dst, sport: sp, dport: dp };
    }
    function reset() {
      var t = readTuple();
      if (!t) { info.innerHTML = '<span class="err">Check the tuple fields (IPv4 dotted quads, ports 0..65535).</span>'; return; }
      st.bits = bytesToBits(tupleBytes(t));
      st.i = 0; st.res = 0; st.flipped = 0; st.want = null;
      VEC.forEach(function (v) {
        if (ipStr(v.src) === ipStr(t.src) && ipStr(v.dst) === ipStr(t.dst) && v.sport === t.sport && v.dport === t.dport) st.want = v.want;
      });
      pred.innerHTML = ''; st.pending = false;
      draw();
    }
    function setBit(c, v, cls) {
      c.t.textContent = v;
      c.r.setAttribute('class', cls);
    }
    function draw() {
      var i;
      for (i = 0; i < 96; i++) setBit(cells.inp[i], st.bits[i], i < st.i ? 'svg-slot tz-done' + (st.bits[i] ? ' tz-one' : '') : (st.bits[i] ? 'svg-slot tz-one' : 'svg-slot'));
      var w = Math.min(st.i, 95);
      for (i = 0; i < 128; i++) setBit(cells.key[i], keyBits[i], (i >= w && i < w + 32 && st.i < 96) ? 'svg-slot tz-win' : 'svg-slot');
      var wv = window32(keyBits, w);
      for (i = 0; i < 32; i++) setBit(cells.win[i], (wv >>> (31 - i)) & 1, st.i < 96 && st.bits[w] ? 'svg-slot tz-win' : 'svg-slot tz-dim');
      for (i = 0; i < 32; i++) setBit(cells.res[i], (st.res >>> (31 - i)) & 1, (st.flipped >>> (31 - i)) & 1 ? 'svg-slot tz-flip' : 'svg-slot tz-res');
      if (st.i < 96) {
        cursor.setAttribute('x', X0 + (st.i % 32) * CW - 1);
        cursor.setAttribute('y', 12 + Math.floor(st.i / 32) * (CH + 4) - 2);
        cursor.setAttribute('class', 'svg-highlight tz-cursor');
      } else cursor.setAttribute('class', 'svg-hidden');
      var field = st.i < 32 ? 'src addr' : st.i < 64 ? 'dst addr' : st.i < 80 ? 'src port' : 'dst port';
      if (st.i < 96) {
        info.innerHTML = 'Input bit <strong>' + st.i + '</strong> (' + field + ') is <strong>' + st.bits[st.i] + '</strong>: ' +
          (st.bits[st.i] ? 'result ^= key bits ' + st.i + '..' + (st.i + 31) + ' (<code>' + hex8(wv) + '</code>)' : 'nothing to XOR, the window just slides one bit') +
          '. Result so far <code>' + hex8(st.res) + '</code>.';
        foot.textContent = '';
      } else {
        var idx = st.res & 127;
        info.innerHTML = 'Done: hash <strong><code>' + hex8(st.res) + '</code></strong>' +
          (st.want != null ? (st.res === st.want ? ' <span class="ok">matches the verification suite</span>' : ' <span class="err">expected ' + hex8(st.want) + '</span>') : '') +
          '. The NIC keeps the low 7 bits: <code>hash &amp; 127 = ' + idx + '</code> &rarr; RETA[' + idx + '] = queue <strong>' + (idx % 4) + '</strong> (RETA filled i % 4).';
        foot.textContent = 'hash ' + hex8(st.res) + '  ->  RETA index ' + idx + '  ->  queue ' + (idx % 4);
      }
    }
    function apply() {
      if (st.i >= 96) return;
      st.flipped = 0;
      if (st.bits[st.i]) {
        var wv = window32(keyBits, st.i);
        st.res = (st.res ^ wv) >>> 0;
        st.flipped = wv;
      }
      st.i++;
      draw();
    }
    function step() {
      if (st.pending || st.i >= 96) return;
      var predictOn = root.querySelector('#tz-pmode').checked;
      if (!predictOn || !st.bits[st.i]) { apply(); return; }
      /* predict: pick a result bit, ask its value after the XOR */
      var j = Math.floor(Math.random() * 32), wv = window32(keyBits, st.i);
      var before = (st.res >>> (31 - j)) & 1, wb = (wv >>> (31 - j)) & 1, after = before ^ wb;
      st.pending = true;
      pred.innerHTML = '<div class="predict"><div class="predict-q">Predict: input bit ' + st.i + ' is 1. Result bit ' + j +
        ' is ' + before + ' and window bit ' + j + ' is ' + wb + '. What is result bit ' + j + ' after this step?</div>' +
        '<div class="predict-opts"><button class="btn small" data-v="0">0</button> <button class="btn small" data-v="1">1</button></div><div class="predict-fb" aria-live="polite"></div></div>';
      CJ.$$('button[data-v]', pred).forEach(function (b) {
        b.addEventListener('click', function () {
          var ok = +b.getAttribute('data-v') === after;
          CJ.$$('button[data-v]', pred).forEach(function (x) { x.disabled = true; });
          pred.querySelector('.predict-fb').innerHTML = (ok ? '<strong style="color:var(--tip)">Correct.</strong> ' : '<strong style="color:var(--pitfall)">Not quite.</strong> ') +
            before + ' XOR ' + wb + ' = ' + after + '. Every result bit whose window bit is 1 flips.';
          setTimeout(function () { st.pending = false; pred.innerHTML = ''; apply(); }, 900);
        });
      });
    }
    root.querySelector('#tz-next').addEventListener('click', step);
    root.querySelector('#tz-nextset').addEventListener('click', function () {
      if (st.pending) return;
      while (st.i < 96 && !st.bits[st.i]) apply();
      step();
    });
    root.querySelector('#tz-end').addEventListener('click', function () {
      if (st.pending) return;
      while (st.i < 96) apply();
    });
    root.querySelector('#tz-reset').addEventListener('click', reset);
    root.querySelector('#tz-preset').addEventListener('change', function (e) {
      var v = VEC[+e.target.value];
      root.querySelector('#tz-src').value = ipStr(v.src);
      root.querySelector('#tz-dst').value = ipStr(v.dst);
      root.querySelector('#tz-sport').value = v.sport;
      root.querySelector('#tz-dport').value = v.dport;
      reset();
    });
    CJ.$$('input[type=text], input[type=number]', root).forEach(function (el) { el.addEventListener('change', reset); });
    reset();
  }

  /* ------------------------------------------------------------------ */
  /* Widget 2: RSS pipeline with an editable RETA                        */
  /* ------------------------------------------------------------------ */
  function rssWidget() {
    var root = document.getElementById('w-rss');
    if (!root) return;
    var svgR = root.querySelector('svg.rss-reta'), svgH = root.querySelector('svg.rss-hist');
    var out = root.querySelector('.rss-out');
    var reta = [], nq = 4, cellEls = [];
    var flows = [], rnd = mulberry(15);
    for (var f = 0; f < 10000; f++) {
      flows.push(tupleBytes({ src: [10, 0, (rnd() * 256) | 0, (rnd() * 256) | 0], dst: [192, 0, 2, 1], sport: 1024 + ((rnd() * 60000) | 0), dport: 443 }));
    }
    var hashCache = {};
    function keyBitsFor(name) { return bytesToBits(name === 'sym' ? SYM_KEY : MS_KEY); }
    function sortTuple(b) {
      /* SYMMETRIC_TOEPLITZ_SORT model: smaller address first, smaller port first */
      var s = b.slice(0, 4), d = b.slice(4, 8), sp = b.slice(8, 10), dp = b.slice(10, 12);
      function less(x, y) { for (var i = 0; i < x.length; i++) { if (x[i] !== y[i]) return x[i] < y[i]; } return false; }
      if (less(d, s)) { var t = s; s = d; d = t; }
      if (less(dp, sp)) { var u = sp; sp = dp; dp = u; }
      return s.concat(d, sp, dp);
    }
    function hashOf(bytes, mode) {
      var kb = keyBitsFor(mode.key);
      return toeplitz(mode.algo === 'sort' ? sortTuple(bytes) : bytes, kb);
    }
    function mode() { return { key: root.querySelector('#rss-key').value, algo: root.querySelector('#rss-algo').value }; }
    function flowHashes(m) {
      var id = m.key + '/' + m.algo;
      if (!hashCache[id]) hashCache[id] = flows.map(function (b) { return hashOf(b, m); });
      return hashCache[id];
    }
    function fillRR() { reta = []; for (var i = 0; i < 128; i++) reta.push(i % nq); }
    /* RETA grid 16 x 8 */
    var CW = 38, CH = 22;
    for (var i = 0; i < 128; i++) {
      (function (i) {
        var x = 6 + (i % 16) * CW, y = 6 + Math.floor(i / 16) * CH;
        var r = S.rect(svgR, x, y, CW - 3, CH - 3, '');
        r.setAttribute('rx', 3);
        r.style.cursor = 'pointer';
        var t = S.text(svgR, x + (CW - 3) / 2, y + (CH - 3) / 2 + 0.5, '', 'svg-label center small mono rss-cell-t');
        t.style.pointerEvents = 'none';
        r.addEventListener('click', function () { reta[i] = (reta[i] + 1) % nq; update(); });
        r.setAttribute('tabindex', '0');
        r.setAttribute('aria-label', 'RETA entry ' + i);
        r.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); reta[i] = (reta[i] + 1) % nq; update(); } });
        cellEls.push({ r: r, t: t });
      })(i);
    }
    var markF = S.rect(svgR, 0, 0, CW - 3, CH - 3, 'rss-mark-f'), markR = S.rect(svgR, 0, 0, CW - 3, CH - 3, 'rss-mark-r');
    [markF, markR].forEach(function (m) { m.setAttribute('rx', 3); m.style.pointerEvents = 'none'; });

    function readFlow() {
      var src = parseIp(root.querySelector('#rss-src').value), dst = parseIp(root.querySelector('#rss-dst').value);
      var sp = +root.querySelector('#rss-sport').value, dp = +root.querySelector('#rss-dport').value;
      if (!src || !dst || !(sp >= 0 && sp < 65536) || !(dp >= 0 && dp < 65536)) return null;
      return { src: src, dst: dst, sport: sp, dport: dp };
    }
    function place(m, idx) {
      m.setAttribute('x', 6 + (idx % 16) * CW);
      m.setAttribute('y', 6 + Math.floor(idx / 16) * CH);
    }
    function update() {
      var m = mode(), i;
      for (i = 0; i < 128; i++) {
        cellEls[i].r.setAttribute('class', qcls(reta[i]) + ' rss-cell');
        cellEls[i].t.textContent = reta[i];
      }
      var t = readFlow();
      if (!t) { out.innerHTML = '<span class="err">Check the flow fields.</span>'; return; }
      var fwd = hashOf(tupleBytes(t), m);
      var rev = hashOf(tupleBytes({ src: t.dst, dst: t.src, sport: t.dport, dport: t.sport }), m);
      place(markF, fwd & 127); place(markR, rev & 127);
      var qf = reta[fwd & 127], qr = reta[rev & 127];
      out.innerHTML =
        '<div><span class="rss-sw f"></span> forward ' + ipStr(t.src) + ':' + t.sport + ' &rarr; ' + ipStr(t.dst) + ':' + t.dport +
        ' &nbsp; hash <code>' + hex8(fwd) + '</code> &nbsp; &amp;127 = ' + (fwd & 127) + ' &rarr; queue <strong>' + qf + '</strong></div>' +
        '<div><span class="rss-sw r"></span> reply &nbsp; ' + ipStr(t.dst) + ':' + t.dport + ' &rarr; ' + ipStr(t.src) + ':' + t.sport +
        ' &nbsp; hash <code>' + hex8(rev) + '</code> &nbsp; &amp;127 = ' + (rev & 127) + ' &rarr; queue <strong>' + qr + '</strong></div>' +
        '<div>' + (qf === qr ? '<span class="ok">Both directions meet on one lcore</span> (a stateful app can keep the connection in per-lcore memory).' :
          '<span class="err">The two directions land on different lcores</span>: per-connection state would have to be shared.') + '</div>';
      /* histogram over 10k flows */
      var hs = flowHashes(m), cnt = [];
      for (i = 0; i < nq; i++) cnt.push(0);
      for (i = 0; i < hs.length; i++) cnt[reta[hs[i] & 127]]++;
      var ent = []; for (i = 0; i < nq; i++) ent.push(0);
      for (i = 0; i < 128; i++) ent[reta[i]]++;
      drawHist(cnt, ent);
    }
    function drawHist(cnt, ent) {
      S.clear(svgH);
      var W = 620, max = 10000 / nq * 2, bw = Math.min(70, (W - 60) / nq - 10);
      S.line(svgH, 40, 140, W, 140).setAttribute('class', 'svg-line');
      var yIdeal = 140 - (10000 / nq) / max * 120;
      var l = S.line(svgH, 40, yIdeal, W, yIdeal); l.setAttribute('class', 'svg-line dashed');
      S.text(svgH, W, yIdeal - 4, 'even share ' + Math.round(10000 / nq), 'svg-label small muted').setAttribute('text-anchor', 'end');
      for (var q = 0; q < nq; q++) {
        var h = Math.min(130, cnt[q] / max * 120), x = 50 + q * (bw + 10);
        S.rect(svgH, x, 140 - h, bw, h, qcls(q));
        S.text(svgH, x + bw / 2, 136 - h, CJ.fmt(cnt[q]), 'svg-label center small mono');
        S.text(svgH, x + bw / 2, 154, 'q' + q, 'svg-label center small bold');
        S.text(svgH, x + bw / 2, 168, ent[q] + ' ent', 'svg-label center small muted');
      }
    }
    root.querySelector('#rss-q').addEventListener('change', function (e) { nq = +e.target.value; fillRR(); update(); });
    root.querySelector('#rss-fill').addEventListener('click', function () { fillRR(); update(); });
    root.querySelector('#rss-drain').addEventListener('click', function () {
      var last = nq - 1, k = 0;
      for (var i = 0; i < 128; i++) if (reta[i] === last) { reta[i] = k % (nq - 1); k++; }
      update();
    });
    root.querySelector('#rss-swap').addEventListener('click', function () {
      var a = root.querySelector('#rss-src'), b = root.querySelector('#rss-dst'), c = root.querySelector('#rss-sport'), d = root.querySelector('#rss-dport');
      var t = a.value; a.value = b.value; b.value = t; t = c.value; c.value = d.value; d.value = t; update();
    });
    CJ.$$('select, input', root).forEach(function (el) { if (el.id !== 'rss-q') el.addEventListener('change', update); });
    fillRR(); update();
  }

  /* ------------------------------------------------------------------ */
  /* Widget 3: pipeline bottleneck and back-pressure                     */
  /* ------------------------------------------------------------------ */
  function pipeWidget() {
    var root = document.getElementById('w-pipe');
    if (!root) return;
    var svg = root.querySelector('svg');
    var GHZ = 2.4, RING = 1024, NICQ = 1024, BURST = 32;
    var SIM_PER_SEC = 0.0002; /* simulated seconds per real second at speed 1 */
    var stages = [
      { id: 'nic', name: 'NIC queue', x: 10 },
      { id: 'rx', name: 'RX lcore', x: 120 },
      { id: 'w0', name: 'worker 0', x: 330 },
      { id: 'w1', name: 'worker 1', x: 330 },
      { id: 'tx', name: 'TX lcore', x: 540 }
    ];
    var g = {};
    function box(x, y, w, h, label, c) { var b = S.box(svg, x, y, w, h, label, c); return b; }
    /* static drawing */
    g.nic = box(10, 95, 80, 50, 'NIC', 'c4');
    g.rx = box(120, 95, 90, 50, 'RX', 'c1');
    g.w0 = box(330, 30, 90, 50, 'worker 0', 'c1');
    g.w1 = box(330, 160, 90, 50, 'worker 1', 'c1');
    g.tx = box(540, 95, 90, 50, 'TX', 'c1');
    S.arrow(svg, 90, 120, 118, 120, 'c3');
    S.arrow(svg, 210, 110, 238, 70, 'c3'); S.arrow(svg, 210, 130, 238, 175, 'c3');
    S.arrow(svg, 300, 55, 328, 55, 'c3'); S.arrow(svg, 300, 185, 328, 185, 'c3');
    S.arrow(svg, 420, 55, 448, 110, 'c3'); S.arrow(svg, 420, 185, 448, 130, 'c3');
    S.arrow(svg, 510, 120, 538, 120, 'c3');
    S.arrow(svg, 630, 120, 660, 120, 'c3');
    function ringBar(x, y, label) {
      var o = {};
      S.rect(svg, x, y, 60, 22, 'svg-box c5');
      o.fill = S.rect(svg, x, y, 0, 22, 'svg-fill-c5 pipe-fill');
      o.fill.setAttribute('rx', 4);
      o.t = S.text(svg, x + 30, y + 12, '', 'svg-label center small mono');
      S.text(svg, x + 30, y - 6, label, 'svg-label center small muted');
      return o;
    }
    g.rNic = ringBar(20, 160, 'RX descriptors');
    g.rW0 = ringBar(240, 44, 'ring w0');
    g.rW1 = ringBar(240, 174, 'ring w1');
    g.rTx = ringBar(450, 109, 'ring tx');
    g.lab = {};
    ['rx', 'w0', 'w1', 'tx'].forEach(function (k) {
      var b = g[k];
      var x = +b.rect.getAttribute('x') + 45, y = +b.rect.getAttribute('y') + 64;
      g.lab[k] = S.text(svg, x, y, '', 'svg-label center small mono');
    });
    g.dropNic = S.text(svg, 50, 210, '', 'svg-label center small mono pipe-drop');
    g.dropRx = S.text(svg, 165, 85, '', 'svg-label center small mono pipe-drop');
    g.dropW = S.text(svg, 375, 240, '', 'svg-label center small mono pipe-drop');
    g.out = S.text(svg, 690, 112, '', 'svg-label center small mono');
    S.text(svg, 690, 135, 'Mpps out', 'svg-label center small muted');

    var stat = {
      out: root.querySelector('#pp-out'), bott: root.querySelector('#pp-bott'), drop: root.querySelector('#pp-drop')
    };
    function cyc(id) { return +root.querySelector('#pp-' + id).value; }
    var s;
    function resetState() {
      s = { nic: 0, w0: 0, w1: 0, tx: 0, next: 0, acc: { off: 0, rx: 0, w0: 0, w1: 0, tx: 0 },
        rate: { rx: 0, w0: 0, w1: 0, tx: 0, out: 0 }, busy: { rx: 0, w0: 0, w1: 0, tx: 0 },
        drop: { nic: 0, rx: 0, w: 0 }, dropRate: { nic: 0, rx: 0, w: 0 } };
    }
    function ewma(o, k, v, a) { o[k] = o[k] + (v - o[k]) * a; }
    function tick(dtReal) {
      var dt = dtReal * SIM_PER_SEC, wait = root.querySelector('#pp-policy').value === 'wait';
      var offered = +root.querySelector('#pp-load').value * 1e6;
      var cap = { rx: GHZ * 1e9 / cyc('rx'), w0: GHZ * 1e9 / cyc('w0'), w1: GHZ * 1e9 / cyc('w1'), tx: GHZ * 1e9 / cyc('tx') };
      var done = { rx: 0, w0: 0, w1: 0, tx: 0 }, d = { nic: 0, rx: 0, w: 0 };
      /* NIC: offered packets arrive in the RX descriptor ring */
      s.acc.off += offered * dt;
      var arr = Math.floor(s.acc.off); s.acc.off -= arr;
      var room = NICQ - s.nic, take = Math.min(arr, room);
      s.nic += take; d.nic += arr - take;
      /* TX first (downstream frees space), then workers, then RX */
      s.acc.tx += cap.tx * dt;
      var n = Math.min(Math.floor(s.acc.tx), s.tx); s.acc.tx -= n; if (s.acc.tx > BURST) s.acc.tx = BURST; s.tx -= n; done.tx = n;
      ['w0', 'w1'].forEach(function (w) {
        s.acc[w] += cap[w] * dt;
        var m = Math.min(Math.floor(s.acc[w]), s[w]);
        s.acc[w] -= m; if (s.acc[w] > BURST) s.acc[w] = BURST;
        s[w] -= m; done[w] = m;
        var fit = Math.min(m, RING - s.tx); s.tx += fit; d.w += m - fit;
      });
      s.acc.rx += cap.rx * dt;
      var budget = Math.min(Math.floor(s.acc.rx), s.nic), used = 0;
      while (budget - used > 0) {
        var b = Math.min(BURST, budget - used), tgt = s.next ? 'w1' : 'w0', space = RING - s[tgt];
        if (space >= b) { s[tgt] += b; }
        else if (wait) { if (space > 0) { s[tgt] += space; used += space; s.nic -= space; } break; }
        else { s[tgt] += space; d.rx += b - space; }
        used += b; s.nic -= b; s.next ^= 1;
      }
      s.acc.rx -= used; if (s.acc.rx > BURST) s.acc.rx = BURST;
      done.rx = used;
      /* smoothed rates in Mpps, busy = work done / capacity */
      var a = Math.min(1, dtReal * 3);
      ['rx', 'w0', 'w1', 'tx'].forEach(function (k) {
        ewma(s.rate, k, done[k] / dt / 1e6, a);
        ewma(s.busy, k, Math.min(1, done[k] / (cap[k] * dt)), a);
      });
      ewma(s.rate, 'out', done.tx / dt / 1e6, a);
      ['nic', 'rx', 'w'].forEach(function (k) { ewma(s.dropRate, k, d[k] / dt / 1e6, a); s.drop[k] += d[k]; });
    }
    function setBar(o, v, cap) {
      o.fill.setAttribute('width', Math.max(0, Math.min(60, 60 * v / cap)));
      o.t.textContent = v;
      o.fill.setAttribute('class', 'pipe-fill ' + (v / cap > 0.9 ? 'svg-fill-c4' : 'svg-fill-c5'));
    }
    function render() {
      setBar(g.rNic, s.nic, NICQ); setBar(g.rW0, s.w0, RING); setBar(g.rW1, s.w1, RING); setBar(g.rTx, s.tx, RING);
      var best = 'rx', bv = -1;
      ['rx', 'w0', 'w1', 'tx'].forEach(function (k) {
        g.lab[k].textContent = s.rate[k].toFixed(1) + ' Mpps, ' + Math.round(s.busy[k] * 100) + '% busy';
        if (s.busy[k] > bv) { bv = s.busy[k]; best = k; }
        g[k].rect.setAttribute('class', 'svg-box c1' + (s.busy[k] > 0.97 ? ' svg-highlight' : ''));
      });
      g.out.textContent = s.rate.out.toFixed(1);
      g.dropNic.textContent = s.dropRate.nic > 0.05 ? 'NIC drops ' + s.dropRate.nic.toFixed(1) + ' Mpps' : '';
      g.dropRx.textContent = s.dropRate.rx > 0.05 ? 'RX drops ' + s.dropRate.rx.toFixed(1) + ' Mpps' : '';
      g.dropW.textContent = s.dropRate.w > 0.05 ? 'worker drops ' + s.dropRate.w.toFixed(1) + ' Mpps' : '';
      stat.out.textContent = s.rate.out.toFixed(2);
      stat.bott.textContent = bv > 0.95 ? ({ rx: 'RX', w0: 'worker 0', w1: 'worker 1', tx: 'TX' })[best] : 'none (load below capacity)';
      stat.drop.textContent = (s.dropRate.nic + s.dropRate.rx + s.dropRate.w).toFixed(2);
    }
    ['rx', 'w0', 'w1', 'tx', 'load'].forEach(function (k) {
      CJ.bindRange('#pp-' + k, '#pp-' + k + 'o', function (v) { return k === 'load' ? v + ' Mpps' : v + ' cyc'; });
    });
    root.querySelector('#pp-preset').addEventListener('change', function (e) {
      var p = { bal: [40, 300, 300, 100, 30, 'drop'], slow: [40, 900, 300, 100, 30, 'drop'], slowwait: [40, 900, 300, 100, 30, 'wait'], light: [40, 300, 300, 100, 8, 'drop'] }[e.target.value];
      if (!p) return;
      ['rx', 'w0', 'w1', 'tx', 'load'].forEach(function (k, i) { var el = root.querySelector('#pp-' + k); el.value = p[i]; el.dispatchEvent(new Event('input')); });
      root.querySelector('#pp-policy').value = p[5];
      resetState();
    });
    root.querySelector('#pp-policy').addEventListener('change', resetState);
    resetState(); render();
    new CJ.Animator({
      root: root, autoplay: 'visible',
      onReset: function () { resetState(); render(); },
      onFrame: function (dt) { if (dt > 0) { tick(dt); render(); } }
    });
  }

  /* ------------------------------------------------------------------ */
  /* Reorder buffer model: a port of lib/reorder/rte_reorder.c           */
  /* ------------------------------------------------------------------ */
  function Rob(size) {
    this.size = size; this.order = []; this.ready = []; this.head = 0; this.min = 0; this.init = false;
    for (var i = 0; i < size; i++) this.order.push(null);
  }
  Rob.prototype.fillOverflow = function (n) {
    var adv = 0, rcap = this.size - 1; /* ring keeps one slot empty */
    while (adv < n && this.ready.length < rcap) {
      if (this.order[this.head] === null) { this.head = (this.head + 1) % this.size; adv++; }
      while (this.order[this.head] !== null) {
        this.ready.push(this.order[this.head]); this.order[this.head] = null; adv++;
        this.head = (this.head + 1) % this.size;
        if (this.ready.length >= rcap) break;
      }
    }
    this.min += adv;
    return adv;
  };
  Rob.prototype.insert = function (seq) {
    if (!this.init) { this.min = seq; this.init = true; }
    var off = (seq - this.min) >>> 0;
    if (off < this.size) { this.order[(this.head + off) % this.size] = seq; return 'ok'; }
    if (off < 2 * this.size) {
      if (this.fillOverflow(off + 1 - this.size) < off + 1 - this.size) return 'ENOSPC';
      off = (seq - this.min) >>> 0;
      this.order[(this.head + off) % this.size] = seq; return 'ok (early: window moved)';
    }
    return 'ERANGE';
  };
  Rob.prototype.drain = function () {
    var out = this.ready.splice(0);
    while (this.order[this.head] !== null) {
      out.push(this.order[this.head]); this.order[this.head] = null; this.min++;
      this.head = (this.head + 1) % this.size;
    }
    return out;
  };

  function robDraw(svg, rob, lastSeq, lastRes, outList) {
    S.clear(svg);
    S.text(svg, 10, 18, 'order buffer (window of ' + rob.size + ')', 'svg-label small bold');
    S.text(svg, 640, 18, 'min_seqn = ' + (rob.init ? rob.min : 'unset'), 'svg-label small mono').setAttribute('text-anchor', 'end');
    for (var k = 0; k < rob.size; k++) {
      var x = 10 + k * 78, slot = (rob.head + k) % rob.size, v = rob.order[slot];
      var r = S.rect(svg, x, 28, 70, 40, v === null ? 'svg-slot' : (v === lastSeq ? 'svg-slot full rob-new' : 'svg-slot full'));
      r.setAttribute('rx', 5);
      S.text(svg, x + 35, 50, v === null ? '-' : v, 'svg-label center bold mono');
      S.text(svg, x + 35, 82, rob.init ? 'seq ' + (rob.min + k) : '', 'svg-label center small muted');
    }
    S.text(svg, 10, 110, 'ready buffer (passed a gap, waiting for drain)', 'svg-label small bold');
    for (k = 0; k < rob.size - 1; k++) {
      var v2 = rob.ready[k];
      var r2 = S.rect(svg, 10 + k * 78, 120, 70, 30, v2 === undefined ? 'svg-slot' : 'svg-slot full');
      r2.setAttribute('rx', 5);
      S.text(svg, 45 + k * 78, 136, v2 === undefined ? '' : v2, 'svg-label center mono');
    }
    S.text(svg, 10, 178, 'last: ' + (lastRes || '-'), 'svg-label mono ' + (/ERANGE|ENOSPC/.test(lastRes || '') ? 'rob-err' : ''));
    S.text(svg, 10, 200, 'drained so far: ' + (outList.length ? outList.join(' ') : '-'), 'svg-label small mono');
  }

  function reorderWidget() {
    var root = document.getElementById('w-reorder');
    if (!root) return;
    var svg = root.querySelector('svg');
    var script = [
      { op: 'ins', v: 1, cap: 'min_seqn_set(b, 0), then insert 1: offset 1 inside the window, stored in slot 1.' },
      { op: 'ins', v: 0, cap: 'Insert 0: slot 0. Slots 0 and 1 are now contiguous from min_seqn.' },
      { op: 'ins', v: 3 }, { op: 'ins', v: 2 }, { op: 'ins', v: 5 }, { op: 'ins', v: 4 },
      { op: 'ins', v: 20, cap: 'Insert 20: offset 20 is more than twice the window (16).',
        predict: { question: 'What does rte_reorder_insert() return for 20?', options: ['0, stored in slot 20 % 8', '-1 with rte_errno = ERANGE', '-1 with rte_errno = ENOSPC'], answer: 1, explain: 'Offsets &ge; 2 &times; size are "vastly out of range": the caller still owns the mbuf and must send or free it.' } },
      { op: 'ins', v: 6 },
      { op: 'drain', cap: 'Drain: 0..6 leave in order. min_seqn becomes 7, the head of the window.' },
      { op: 'ins', v: 12, cap: 'Insert 12: offset 5, fits the window [7, 15).' },
      { op: 'ins', v: 16, cap: 'Insert 16: offset 9 is "early" (between size and 2 &times; size).',
        predict: { question: 'Where does the window go to make room for 16?', options: ['It waits: insert fails with ENOSPC', 'It slides 2 slots, skipping the missing 7 and 8', 'It drops 12'], answer: 1, explain: 'rte_reorder_fill_overflow() moves the head forward by offset + 1 - size = 2 slots. Empty slots are skipped: 7 and 8 are given up.' } },
      { op: 'ins', v: 7, cap: 'Insert 7: it arrived after the window moved past it.',
        predict: { question: 'What happens to 7 now?', options: ['ok, it fills the gap', 'ERANGE: it is late', 'it goes to the ready buffer'], answer: 1, explain: '7 - min_seqn (9) wraps to a huge unsigned offset: ERANGE. Late packets are the caller\'s to handle.' } },
      { op: 'drain', cap: 'Drain returns nothing: the head (9) is still missing. 12 and 16 wait.' },
      { op: 'ins', v: 9 }, { op: 'ins', v: 10 }, { op: 'ins', v: 11 },
      { op: 'drain', cap: 'Drain: 9 10 11 12 leave; the next gap is 13.' },
      { op: 'ins', v: 13 }, { op: 'ins', v: 14 }, { op: 'ins', v: 15 },
      { op: 'drain', cap: 'Drain: 13 14 15 16. Compare with the program output: identical.' }
    ];
    var steps = [{ caption: 'Empty reorder buffer of size 8 (rte_reorder_create(name, socket, 8)). Step through the same sequence as <code>distributor_reorder</code> Part 1.' }];
    script.forEach(function (s) {
      steps.push({
        caption: s.cap || (s.op === 'ins' ? 'Insert ' + s.v + '.' : 'Drain.'),
        predict: s.predict,
        run: function (ctx) {
          if (s.op === 'ins') { ctx.data.last = s.v; ctx.data.res = 'insert ' + s.v + ' -> ' + ctx.data.rob.insert(s.v); }
          else { var o = ctx.data.rob.drain(); ctx.data.out = ctx.data.out.concat(o); ctx.data.last = null; ctx.data.res = 'drain -> [' + o.join(' ') + ']'; }
          robDraw(svg, ctx.data.rob, ctx.data.last, ctx.data.res, ctx.data.out);
        }
      });
    });
    new CJ.Stepper(root, {
      reset: function (ctx) {
        ctx.data.rob = new Rob(8); ctx.data.rob.min = 0; ctx.data.rob.init = true;
        ctx.data.out = []; ctx.data.last = null; ctx.data.res = 'min_seqn_set(b, 0)';
        robDraw(svg, ctx.data.rob, null, ctx.data.res, []);
      },
      steps: steps, interval: 1600
    });
  }

  function reorderSandbox() {
    var root = document.getElementById('w-reorder-sb');
    if (!root) return;
    var svg = root.querySelector('svg');
    var rob, out, last, res;
    function reset() {
      rob = new Rob(+root.querySelector('#rs-size').value);
      if (root.querySelector('#rs-min').checked) { rob.min = 0; rob.init = true; res = 'min_seqn_set(b, 0)'; } else res = 'created; min_seqn will come from the first insert';
      out = []; last = null;
      robDraw(svg, rob, last, res, out);
    }
    function ins(v) {
      if (!(v >= 0)) return;
      last = v; res = 'insert ' + v + ' -> ' + rob.insert(v);
      robDraw(svg, rob, last, res, out);
    }
    root.querySelector('#rs-ins').addEventListener('click', function () { ins(+root.querySelector('#rs-seq').value); });
    root.querySelector('#rs-seq').addEventListener('keydown', function (e) { if (e.key === 'Enter') ins(+e.target.value); });
    root.querySelector('#rs-drain').addEventListener('click', function () {
      var o = rob.drain(); out = out.concat(o); last = null; res = 'drain -> [' + o.join(' ') + ']';
      robDraw(svg, rob, last, res, out);
    });
    root.querySelector('#rs-rand').addEventListener('click', function () {
      /* 8 packets of the next sequence numbers, shuffled a little */
      var base = rob.init ? rob.min + rob.ready.length : 0, a = [];
      for (var i = 0; i < 8; i++) a.push(base + i);
      for (i = 0; i < 8; i += 2) { if (Math.random() < 0.6) { var t = a[i]; a[i] = a[i + 1]; a[i + 1] = t; } }
      if (Math.random() < 0.3) a.splice((Math.random() * 8) | 0, 1); /* one lost */
      a.forEach(function (v) { last = v; res = 'insert ' + v + ' -> ' + rob.insert(v); });
      res = 'inserted ' + a.join(' ') + ' (last: ' + res.replace(/^insert \d+ -> /, '') + ')';
      robDraw(svg, rob, last, res, out);
    });
    root.querySelector('#rs-reset').addEventListener('click', reset);
    root.querySelector('#rs-size').addEventListener('change', reset);
    root.querySelector('#rs-min').addEventListener('change', reset);
    reset();
  }

  /* ------------------------------------------------------------------ */
  /* Measured comparison chart (data from code/expected_output.txt)      */
  /* ------------------------------------------------------------------ */
  function chart() {
    var el = document.getElementById('cmp-chart');
    if (!el || !window.CH15_CMP) return;
    var svg = el.querySelector('svg'), data = window.CH15_CMP;
    var max = 0;
    data.forEach(function (d) { max = Math.max(max, d.max); });
    max = Math.ceil(max / 5) * 5;
    var X0 = 210, W = 440, Y0 = 20, RH = 34;
    for (var t = 0; t <= max; t += 5) {
      var x = X0 + t / max * W;
      S.line(svg, x, Y0 - 6, x, Y0 + data.length * RH).setAttribute('class', 'svg-grid');
      S.text(svg, x, Y0 + data.length * RH + 16, t, 'svg-label center small muted');
    }
    S.text(svg, X0 + W / 2, Y0 + data.length * RH + 34, 'Mpps (median bar, min-max whisker, 5 runs)', 'svg-label center small muted');
    data.forEach(function (d, i) {
      var y = Y0 + i * RH;
      S.text(svg, X0 - 8, y + 13, d.label, 'svg-label small').setAttribute('text-anchor', 'end');
      S.rect(svg, X0, y + 2, d.med / max * W, 20, 'svg-fill-' + d.c).setAttribute('rx', 3);
      var x1 = X0 + d.min / max * W, x2 = X0 + d.max / max * W;
      S.line(svg, x1, y + 12, x2, y + 12).setAttribute('class', 'svg-line cmp-whisk');
      S.line(svg, x1, y + 6, x1, y + 18).setAttribute('class', 'svg-line cmp-whisk');
      S.line(svg, x2, y + 6, x2, y + 18).setAttribute('class', 'svg-line cmp-whisk');
      S.text(svg, x2 + 6, y + 13, d.med.toFixed(1), 'svg-label small mono');
    });
  }

  CJ.ready(function () {
    toeplitzWidget();
    rssWidget();
    pipeWidget();
    reorderWidget();
    reorderSandbox();
    chart();
  });
})();

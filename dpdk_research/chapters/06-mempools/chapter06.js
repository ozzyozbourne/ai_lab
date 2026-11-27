/* Chapter 6 widgets: cache trace (Stepper), pipeline cache animation
 * (Animator), pool memory map, pool sizing calculator.
 * Requires ../../assets/course.js. All colours come from course.css classes. */
(function () {
  'use strict';
  var CJ = window.CourseJS, S = CJ.svg;

  /* ======================================================================
   * Cache algorithms. new26 mirrors rte_mempool_do_generic_get/put() in
   * lib/mempool/rte_mempool.h (26.11). old is a simplified model of the
   * previous algorithm (flushthresh = 1.5 x size, DPDK 23.07 .. 26.03).
   * Each op returns a list of events {kind, n} for the drawing code.
   * c = {size, len, backend, held, calls}
   * ==================================================================== */
  function getNew(c, n) {
    var ev = [];
    if (n <= c.len) { c.len -= n; c.held += n; ev.push({ k: 'hit', n: n }); return ev; }
    var len = c.len, rem = n - len, half = Math.floor(c.size / 2);
    if (len) ev.push({ k: 'hit', n: len });
    c.len = 0; c.held += len;
    if (rem > half || c.backend < half) {
      if (c.backend < rem) { c.len = len; c.held -= len; ev = [{ k: 'fail', n: n }]; return ev; }
      c.backend -= rem; c.held += rem; c.calls++; ev.push({ k: 'direct-get', n: rem }); return ev;
    }
    c.backend -= half; c.calls++; ev.push({ k: 'refill', n: half });
    c.len = half - rem; c.held += rem;
    return ev;
  }
  function putNew(c, n) {
    var half = Math.floor(c.size / 2);
    c.held -= n;
    if (c.len + n <= c.size) { c.len += n; return [{ k: 'push', n: n }]; }
    if (n <= half) {
      c.backend += half; c.len = c.len - half + n; c.calls++;
      return [{ k: 'flush', n: half }, { k: 'push', n: n }];
    }
    c.backend += n; c.calls++; return [{ k: 'direct-put', n: n }];
  }
  function getOld(c, n) {
    var ev = [];
    if (n <= c.len) { c.len -= n; c.held += n; return [{ k: 'hit', n: n }]; }
    var len = c.len, rem = n - len;
    if (len) ev.push({ k: 'hit', n: len });
    c.len = 0; c.held += len;
    var want = c.size + rem;
    if (rem > 512 || c.backend < want) {
      if (c.backend < rem) { c.len = len; c.held -= len; return [{ k: 'fail', n: n }]; }
      c.backend -= rem; c.held += rem; c.calls++; ev.push({ k: 'direct-get', n: rem }); return ev;
    }
    c.backend -= want; c.calls++; ev.push({ k: 'refill', n: want });
    c.len = c.size; c.held += rem;
    return ev;
  }
  function putOld(c, n) {
    var thr = Math.floor(c.size * 3 / 2);
    c.held -= n;
    if (n > thr) { c.backend += n; c.calls++; return [{ k: 'direct-put', n: n }]; }
    if (c.len + n <= thr) { c.len += n; return [{ k: 'push', n: n }]; }
    var f = c.len; c.backend += f; c.len = n; c.calls++;
    return [{ k: 'flush', n: f }, { k: 'push', n: n }];
  }
  function flush(c) { var f = c.len; c.backend += f; c.len = 0; if (f) c.calls++; return f ? [{ k: 'flush', n: f }] : []; }
  var ALG = { 'new': { get: getNew, put: putNew }, old: { get: getOld, put: putOld } };

  /* ======================================================================
   * Widget 1: the measured trace, step by step (cache_explorer part A)
   * ==================================================================== */
  function traceWidget() {
    var root = document.getElementById('w-trace');
    if (!root) return;
    var svg = root.querySelector('svg');
    var alg = 'new';
    /* ops and the MEASURED results (cache.len, backend) from expected_output.txt */
    var OPS = [
      ['get', 1, 127, 3567], ['put', 1, 128, 3567], ['put', 100, 228, 3567], ['put', 50, 150, 3695],
      ['get', 150, 0, 3695], ['get', 32, 96, 3567], ['get', 200, 24, 3439], ['get', 200, 0, 3263],
      ['put', 200, 200, 3263], ['put', 200, 200, 3463], ['flush', 0, 0, 3663], ['put', 432, 0, 4095]
    ];
    var SIZE = 256, POOL = 4095, START_B = 3695, START_H = 400;
    var H = 230, TOP = 40;            /* bar geometry */
    var CMAX = 400;                   /* cache bar scale: room for old 1.5x zone */

    S.text(svg, 70, 22, 'application', 'svg-label center bold');
    var appBox = S.rect(svg, 15, TOP + 60, 110, 70, 'svg-box c1');
    var appTxt = S.text(svg, 70, TOP + 95, '', 'svg-label center mono');
    S.text(svg, 70, TOP + 150, 'objects held', 'svg-label center small muted');

    S.text(svg, 300, 22, 'per-lcore cache (size 256)', 'svg-label center bold');
    S.rect(svg, 260, TOP, 80, H, 'svg-box c7 dashed');
    var cBar = S.rect(svg, 260, TOP + H, 80, 0, 'svg-box c2');
    var cTxt = S.text(svg, 300, TOP + H + 16, '', 'svg-label center mono');
    function yC(v) { return TOP + H - v / CMAX * H; }
    S.line(svg, 252, yC(256), 348, yC(256)).setAttribute('class', 'svg-line');
    S.text(svg, 352, yC(256) + 4, 'size 256', 'svg-label small');
    var halfL = S.line(svg, 252, yC(128), 348, yC(128)); halfL.setAttribute('class', 'svg-line');
    halfL.setAttribute('stroke-dasharray', '3 4');
    S.text(svg, 352, yC(128) + 4, 'size/2', 'svg-label small muted');
    var thrL = S.line(svg, 252, yC(384), 348, yC(384)); thrL.setAttribute('class', 'svg-line');
    thrL.setAttribute('stroke-dasharray', '6 3');
    var thrT = S.text(svg, 352, yC(384) + 4, 'old flushthresh 384', 'svg-label small');

    S.text(svg, 590, 22, 'backend ring', 'svg-label center bold');
    S.rect(svg, 550, TOP, 80, H, 'svg-box c5 dashed');
    var bBar = S.rect(svg, 550, TOP + H, 80, 0, 'svg-box c5');
    var bTxt = S.text(svg, 590, TOP + H + 16, '', 'svg-label center mono');
    function yB(v) { return TOP + H - v / POOL * H; }

    var evG = S.group(svg);
    var drawn = { len: 0, backend: START_B, held: START_H };

    function setBars(st) {
      cBar.setAttribute('y', yC(st.len)); cBar.setAttribute('height', TOP + H - yC(st.len));
      cBar.setAttribute('class', 'svg-box ' + (st.len > SIZE ? 'c4' : 'c2'));
      bBar.setAttribute('y', yB(st.backend)); bBar.setAttribute('height', TOP + H - yB(st.backend));
      cTxt.textContent = 'len ' + Math.round(st.len);
      bTxt.textContent = Math.round(st.backend) + ' free';
      appTxt.textContent = Math.round(st.held);
    }
    function animateTo(st) {
      var from = { len: drawn.len, backend: drawn.backend, held: drawn.held };
      drawn = { len: st.len, backend: st.backend, held: st.held };
      CJ.tween({ from: from, to: drawn, duration: 450, onUpdate: setBars });
    }
    function drawEvents(evs) {
      S.clear(evG);
      var lanes = { hit: [255, 125, TOP + 80], push: [125, 255, TOP + 120], refill: [545, 345, TOP + 70],
        flush: [345, 545, TOP + 200], 'direct-get': [545, 125, TOP + 255], 'direct-put': [125, 545, TOP + 270],
        fail: [125, 125, TOP + 40] };
      var names = { hit: 'from cache', push: 'into cache', refill: 'refill', flush: 'flush bottom',
        'direct-get': 'bypass: backend to app', 'direct-put': 'bypass: app to backend', fail: 'FAIL' };
      evs.forEach(function (e) {
        var L = lanes[e.k]; if (!L) return;
        var cls = (e.k === 'refill' || e.k === 'flush') ? 'c5' : (e.k.indexOf('direct') === 0 ? 'c4' : 'c3');
        var y = L[2];
        if (e.k === 'direct-get' || e.k === 'direct-put') {
          var p = S.path(evG, e.k === 'direct-get'
            ? 'M545,' + (TOP + 235) + ' C 470,' + (y + 8) + ' 200,' + (y + 8) + ' 125,' + (TOP + 130)
            : 'M125,' + (TOP + 132) + ' C 200,' + (y + 4) + ' 470,' + (y + 4) + ' 545,' + (TOP + 240), 'svg-arrow flow ' + cls);
          S.text(evG, 335, y + 18, names[e.k] + ' ' + e.n, 'svg-label center small bold');
          return p;
        }
        S.arrow(evG, L[0], y, L[1], y, cls).setAttribute('class', 'svg-arrow flow ' + cls);
        S.text(evG, (L[0] + L[1]) / 2, y - 7, names[e.k] + ' ' + e.n, 'svg-label center small bold');
      });
    }
    function simulate(upto) {
      var c = { size: SIZE, len: 0, backend: START_B, held: START_H, calls: 0 }, evs = [];
      for (var i = 0; i < upto; i++) {
        var o = OPS[i];
        if (o[0] === 'flush') evs = flush(c);
        else evs = ALG[alg][o[0]](c, o[1]);
        if (alg === 'new' && (c.len !== o[2] || c.backend !== o[3]) && window.console)
          console.warn('trace model mismatch at step', i, c, o);
      }
      return { c: c, evs: evs };
    }

    var predicts = {
      4: { question: 'The cache holds 228. The app puts 50 more (228 + 50 &gt; 256). What is <code>cache.len</code> afterwards?',
        options: ['278: it can overshoot', '150: flush 128, then add 50', '50: flush everything'], answer: 1,
        explain: '26.11 never exceeds <code>size</code>. It flushes the bottom (coldest) <code>size/2</code> = 128 to the ring, slides the hot 100 down and adds the 50: 228 &minus; 128 + 50 = 150.' },
      7: { question: 'The cache holds 96; the app asks for 200. What is <code>cache.len</code> after the call?',
        options: ['0', '24', '96'], answer: 1,
        explain: 'It drains all 96, needs 104 more; 104 &le; size/2, so it refills 128 from the ring and hands out 104: 128 &minus; 104 = 24 stay cached.' },
      10: { question: 'The cache holds 200; the app puts 200 more. Where do they go?',
        options: ['Into the cache after a flush', 'Straight to the ring; cache stays 200'], answer: 1,
        explain: '200 &gt; size/2, so a flush of 128 would not make room. The request bypasses the cache and goes straight to the backend.' }
    };
    var steps = [{ caption: 'Start: pool of 4095, cache size 256 on lcore 0. The application already holds 400 objects taken with <code>cache=NULL</code>, so the ring has 3695.' }];
    var CAP = ['get 1: miss. Refill exactly size/2 = 128 from the ring, hand out 1, keep 127.',
      'put 1: fits on top of the cache (LIFO: this object is the next one handed out).',
      'put 100: 128 + 100 &le; 256, still fits.',
      'put 50: no room. Flush the bottom 128 (oldest, coldest) to the ring, keep the hot ones.',
      'get 150: a hit, all from the cache. The ring is not touched.',
      'get 32: miss. Refill 128, hand out 32, keep 96.',
      'get 200: drain 96, then refill 128 and hand out the remaining 104.',
      'get 200: drain 24; the remaining 176 &gt; size/2, so they come straight from the ring.',
      'put 200: 0 + 200 &le; 256, so even this big put lands in the cache.',
      'put 200: no room, and 200 &gt; size/2: bypass to the ring.',
      'rte_mempool_cache_flush(): everything cached goes back to the ring.',
      'put 432: the rest goes back directly. Pool full again: 4095.'];
    OPS.forEach(function (o, i) {
      var st = { caption: CAP[i] };
      if (predicts[i + 1]) st.predict = predicts[i + 1];
      steps.push(st);
    });
    var stepper = new CJ.Stepper(root, {
      steps: steps, interval: 2200,
      onStep: function (i) {
        var r = simulate(i);
        animateTo(r.c);
        drawEvents(i ? r.evs : []);
        var meas = i ? OPS[i - 1] : null;
        var out = root.querySelector('.trace-meas');
        if (out) out.innerHTML = i === 0 ? 'cache.len 0, ring 3695 (measured)' :
          (alg === 'new' ? 'measured on this machine: cache.len <strong>' + meas[2] + '</strong>, ring <strong>' + meas[3] + '</strong> (model agrees)'
            : 'previous algorithm (simulated): cache.len <strong>' + r.c.len + '</strong>, ring <strong>' + r.c.backend + '</strong>; 26.11 measured: ' + meas[2] + ' / ' + meas[3]);
        var calls = root.querySelector('.trace-calls');
        if (calls) calls.textContent = r.c.calls;
      }
    });
    function setAlg(a) {
      alg = a;
      thrL.style.display = thrT.style.display = a === 'old' ? '' : 'none';
      CJ.$$('[data-alg]', root).forEach(function (b) { b.setAttribute('aria-pressed', b.getAttribute('data-alg') === a ? 'true' : 'false'); });
      stepper.go(stepper.index);
    }
    CJ.$$('[data-alg]', root).forEach(function (b) { b.addEventListener('click', function () { setAlg(b.getAttribute('data-alg')); }); });
    setAlg('new');
  }

  /* ======================================================================
   * Widget 2: two lcores, Rx only gets and Tx only puts (pipeline), or both
   * do get+put (run to completion). Animator; counts ring accesses.
   * ==================================================================== */
  function pipeWidget() {
    var root = document.getElementById('w-pipe');
    if (!root) return;
    var svg = root.querySelector('svg');
    var alg = 'new', pattern = 'pipe', size = 128, BURST = 32, POOL = 8191;
    var lc, ring, tokens = [], acc = 0, objs = 0;

    S.text(svg, 340, 18, 'backend ring: the shared "warehouse"', 'svg-label center bold');
    var ringBox = S.rect(svg, 200, 28, 280, 34, 'svg-box c5');
    var ringTxt = S.text(svg, 340, 46, '', 'svg-label center mono');
    var cols = [{ x: 120, name: 'lcore 1 (Rx)' }, { x: 470, name: 'lcore 2 (Tx)' }];
    var CH = 150, CY = 100;
    cols.forEach(function (col, i) {
      var nt = S.text(svg, i ? col.x + 100 : col.x - 10, CY + 20, col.name, 'svg-label bold');
      nt.setAttribute('text-anchor', i ? 'start' : 'end');
      S.rect(svg, col.x, CY, 90, CH, 'svg-box c7 dashed');
      col.bar = S.rect(svg, col.x, CY + CH, 90, 0, 'svg-box c2');
      col.txt = S.text(svg, col.x + 45, CY + CH + 16, '', 'svg-label center mono small');
      col.calls = S.text(svg, col.x + 45, CY + CH + 32, '', 'svg-label center small');
      col.half = S.line(svg, col.x - 6, CY + CH / 2, col.x + 96, CY + CH / 2);
      col.half.setAttribute('class', 'svg-line'); col.half.setAttribute('stroke-dasharray', '3 4');
    });
    S.text(svg, 340, CY + 60, 'application', 'svg-label center bold');
    var appArrow = S.arrow(svg, 215, CY + 75, 465, CY + 75, 'c3');
    appArrow.setAttribute('class', 'svg-arrow flow c3');
    var appTxt = S.text(svg, 340, CY + 95, '', 'svg-label center small');
    var tokG = S.group(svg);

    function reset() {
      ring = POOL; acc = 0; objs = 0; tokens = []; S.clear(tokG);
      lc = [{ size: size, len: 0, backend: 0, held: 0, calls: 0 }, { size: size, len: 0, backend: 0, held: 0, calls: 0 }];
      draw();
    }
    function op(i, kind) {
      var c = lc[i]; c.backend = ring; c.size = size;
      var before = c.calls, evs = ALG[alg][kind](c, BURST);
      ring = c.backend;
      evs.forEach(function (e) {
        if (e.k === 'refill' || e.k === 'direct-get') spawn(i, true, e.n);
        if (e.k === 'flush' || e.k === 'direct-put') spawn(i, false, e.n);
      });
      return c.calls - before;
    }
    function spawn(i, up, n) {
      var x = cols[i].x + 45;
      var p = S.packet(tokG, x, up ? 64 : CY, 30, 14, 'c5', String(n));
      tokens.push({ p: p, x: x, y0: up ? 64 : CY, y1: up ? CY : 64, t: 0 });
    }
    function tick() {
      /* one "burst time": Rx gets a burst; Tx puts the burst it got earlier */
      if (pattern === 'pipe') {
        op(0, 'get'); op(1, 'put'); lc[0].held = 0; lc[1].held = 0;
      } else {
        op(0, 'get'); op(0, 'put'); op(1, 'get'); op(1, 'put');
      }
      objs += BURST;
    }
    function draw() {
      ringTxt.textContent = ring + ' free objects';
      cols.forEach(function (col, i) {
        var c = lc[i], cap = alg === 'old' ? size * 1.5 : size, h = CH * c.len / (size * 1.5);
        col.bar.setAttribute('y', CY + CH - h); col.bar.setAttribute('height', h);
        col.txt.textContent = 'len ' + c.len + ' / ' + cap;
        col.calls.textContent = 'ring calls: ' + c.calls;
        var hy = CY + CH - CH * (size / 2) / (size * 1.5);
        col.half.setAttribute('y1', hy); col.half.setAttribute('y2', hy);
      });
      var total = lc[0].calls + lc[1].calls;
      appTxt.textContent = pattern === 'pipe' ? 'Rx lcore hands each burst to Tx lcore' : 'each lcore gets and puts its own bursts';
      var o = root.querySelector('.pipe-rate');
      if (o) o.textContent = objs ? (1000 * total / objs).toFixed(1) : '0';
      var o2 = root.querySelector('.pipe-objs');
      if (o2) o2.textContent = CJ.fmt(objs);
    }
    var anim = new CJ.Animator({
      root: root, autoplay: 'visible',
      onReset: reset,
      onFrame: function (dt) {
        acc += dt;
        while (acc > 0.12) { acc -= 0.12; tick(); }
        tokens = tokens.filter(function (t) {
          t.t += dt * 2.2;
          if (t.t >= 1) { t.p.remove(); return false; }
          S.moveTo(t.p, t.x, CJ.lerp(t.y0, t.y1, CJ.ease.inOut(t.t)));
          return true;
        });
        draw();
      }
    });
    CJ.$$('[data-palg]', root).forEach(function (b) {
      b.addEventListener('click', function () {
        alg = b.getAttribute('data-palg');
        CJ.$$('[data-palg]', root).forEach(function (x) { x.setAttribute('aria-pressed', x === b ? 'true' : 'false'); });
        anim.reset();
      });
    });
    CJ.$$('[data-pat]', root).forEach(function (b) {
      b.addEventListener('click', function () {
        pattern = b.getAttribute('data-pat');
        CJ.$$('[data-pat]', root).forEach(function (x) { x.setAttribute('aria-pressed', x === b ? 'true' : 'false'); });
        anim.reset();
      });
    });
    CJ.bindRange('#pipe-size', '#pipe-size-o', function (v) { return v; }, function (v) { size = +v; anim.reset(); });
    reset();
  }

  /* ======================================================================
   * Widget 3: pool memory map (layout rules of rte_mempool_calc_obj_size()
   * and the default populate helper)
   * ==================================================================== */
  function gcd(a, b) { while (b) { var t = a % b; a = b; b = t; } return a; }
  function layout(elt, spread, cacheAlign) {
    var hdr = cacheAlign ? 64 : 24;                 /* sizeof(struct rte_mempool_objhdr) = 24 */
    var eltR = cacheAlign ? Math.ceil(elt / 64) * 64 : Math.ceil(elt / 8) * 8;
    var total = hdr + eltR;
    if (spread && cacheAlign) { var l = total / 64; while (gcd(l, 4) !== 1) l++; total = l * 64; }
    return { hdr: hdr, elt: eltR, trailer: total - hdr - eltR, total: total };
  }
  function memmapWidget() {
    var root = document.getElementById('w-memmap');
    if (!root) return;
    var svg = root.querySelector('svg');
    var st = { elt: 64, page: 4096, spread: true };
    var ROWS = 4, RW = 600, X = 60, Y0 = 34, RH = 34, GAP = 26;

    function render() {
      S.clear(svg);
      var L = layout(st.elt, st.spread, true);
      var sc = RW / 4096;
      S.text(svg, X, 18, st.page === 4096 ? 'four 4 KB pages (--no-huge)' : 'first 16 KB of one 2 MB hugepage', 'svg-label bold');
      var off = 0, objs = 0, starts = [0, 0, 0, 0], crossed = false;
      var END = ROWS * 4096;
      while (true) {
        var pageEnd = (Math.floor(off / st.page) + 1) * st.page;
        if (L.total <= st.page && off + L.total > pageEnd) { off = pageEnd; crossed = true; continue; }
        if (off + L.total > END) break;
        starts[(Math.floor((off + L.hdr) / 64)) % 4]++;
        objs++;
        var segs = [[L.hdr, 'c7'], [L.elt, 'c2'], [L.trailer, 'c3']], p = off;
        segs.forEach(function (sg) {
          var len = sg[0], cls = sg[1];
          while (len > 0) {
            var row = Math.floor(p / 4096), inRow = p % 4096, piece = Math.min(len, 4096 - inRow);
            if (row >= ROWS) break;
            var r = S.rect(svg, X + inRow * sc, Y0 + row * (RH + GAP), Math.max(piece * sc, 0.6), RH, 'svg-box ' + cls);
            r.setAttribute('rx', 1);
            p += piece; len -= piece;
          }
        });
        off += L.total;
      }
      for (var r = 0; r < ROWS; r++) {
        var y = Y0 + r * (RH + GAP);
        S.rect(svg, X, y, RW, RH, 'svg-box ghost');
        S.text(svg, X - 6, y + RH / 2 + 4, (r * 4) + 'K', 'svg-label small').setAttribute('text-anchor', 'end');
        if (st.page === 4096) {
          var pb = S.line(svg, X + RW, y - 4, X + RW, y + RH + 4); pb.setAttribute('class', 'svg-line svg-stroke-c4');
          pb.setAttribute('stroke-width', '2.5');
        }
      }
      if (st.page === 4096) S.text(svg, X + RW + 6, Y0 + 14, 'page', 'svg-label small');
      if (st.page === 4096) S.text(svg, X + RW + 6, Y0 + 28, 'end', 'svg-label small');
      /* stats */
      var perPage = st.page === 4096 ? Math.max(1, Math.floor(4096 / L.total)) : Math.floor(2097152 / L.total);
      var bytesPerObj = L.total > st.page ? L.total : st.page / perPage;
      var q = function (s) { return root.querySelector(s); };
      q('.mm-hdr').textContent = L.hdr; q('.mm-elt').textContent = L.elt;
      q('.mm-tr').textContent = L.trailer; q('.mm-tot').textContent = L.total;
      q('.mm-pp').textContent = CJ.fmt(perPage);
      q('.mm-bpo').textContent = CJ.fmt(Math.round(bytesPerObj));
      q('.mm-waste').textContent = Math.round(100 * (bytesPerObj - L.total) / bytesPerObj) + '%';
      q('.mm-ch').textContent = starts.join(' / ');
      CJ.$$('[data-mm-page]', root).forEach(function (b) { b.setAttribute('aria-pressed', +b.getAttribute('data-mm-page') === st.page ? 'true' : 'false'); });
      CJ.$$('[data-mm-spread]', root).forEach(function (b) { b.setAttribute('aria-pressed', (b.getAttribute('data-mm-spread') === '1') === st.spread ? 'true' : 'false'); });
    }
    CJ.$$('[data-mm-page]', root).forEach(function (b) { b.addEventListener('click', function () { st.page = +b.getAttribute('data-mm-page'); render(); }); });
    CJ.$$('[data-mm-spread]', root).forEach(function (b) { b.addEventListener('click', function () { st.spread = b.getAttribute('data-mm-spread') === '1'; render(); }); });
    var sel = root.querySelector('#mm-elt');
    sel.addEventListener('change', function () { st.elt = +sel.value; render(); });
    render();
  }

  /* ======================================================================
   * Widget 4: pool sizing calculator
   * ==================================================================== */
  function sizingWidget() {
    var root = document.getElementById('w-size');
    if (!root) return;
    var ids = ['ports', 'rxq', 'rxd', 'txd', 'lcores', 'cache', 'burst', 'extra'];
    function v(id) { return Math.max(0, parseInt(root.querySelector('#sz-' + id).value, 10) || 0); }
    function calc() {
      var rx = v('ports') * v('rxq') * v('rxd'), tx = v('ports') * v('rxq') * v('txd');
      var caches = v('lcores') * v('cache'), hands = v('lcores') * v('burst'), extra = v('extra');
      var n = rx + tx + caches + hands + extra;
      var pow = 1; while (pow < n + 1) pow *= 2;
      var q = function (s, t) { root.querySelector(s).textContent = t; };
      q('.sz-rx', CJ.fmt(rx)); q('.sz-tx', CJ.fmt(tx)); q('.sz-c', CJ.fmt(caches)); q('.sz-h', CJ.fmt(hands));
      q('.sz-e', CJ.fmt(extra)); q('.sz-n', CJ.fmt(n)); q('.sz-p', CJ.fmt(pow - 1));
      var mb4 = (n * 4096 / 1048576).toFixed(1), mb2 = (n * 2368 / 1048576).toFixed(1);
      q('.sz-mem', mb2 + ' MiB with hugepages vs ' + mb4 + ' MiB with --no-huge (2368 B vs 4096 B per default mbuf, measured)');
      var warn = root.querySelector('.sz-warn');
      warn.textContent = v('cache') > (pow - 1) ? 'cache_size larger than n: rte_mempool_create() fails with EINVAL' :
        (caches > n / 2 ? 'More than half the pool can sit in caches: consider a smaller cache.' : '');
    }
    ids.forEach(function (id) { root.querySelector('#sz-' + id).addEventListener('input', calc); });
    calc();
  }

  CJ.ready(function () {
    traceWidget();
    pipeWidget();
    memmapWidget();
    sizingWidget();
    if (window.Ch06ABA) window.Ch06ABA.mount('#w-aba');
  });
})();

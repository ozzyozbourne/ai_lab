/* Chapter 5 widgets: ring clock face (predict-then-step), modulo-2^32
 * odometer, sync-mode Gantt with measured bars, bulk vs burst slider.
 * Colours come only from course.css variables / classes. */
(function () {
'use strict';
var S = CourseJS.svg;
var NS = 'http://www.w3.org/2000/svg';
function el(tag, attrs, parent) { return S.el(tag, attrs || {}, parent); }
function txt(parent, x, y, s, cls, attrs) { return S.text(parent, x, y, s, cls || 'svg-label', attrs); }

/* =====================================================================
 * Widget 1: ring clock face. 16 slots, four indexes, locals of 2 cores.
 * ===================================================================== */
function ringClock() {
  var root = document.getElementById('w-clock');
  if (!root) return;
  var svg = root.querySelector('svg');
  var N = 16, CX = 175, CY = 196, R = 108;
  var slotG = [], slotLbl = [], marks = {};
  function ang(i) { return (-90 + i * 360 / N) * Math.PI / 180; }
  function pos(i, r) { return [CX + r * Math.cos(ang(i)), CY + r * Math.sin(ang(i))]; }
  // marker angle sits on the boundary *before* slot i (index i = next slot)
  function bpos(i, r) { var a = (-90 + (i - 0.5) * 360 / N) * Math.PI / 180; return [CX + r * Math.cos(a), CY + r * Math.sin(a)]; }

  txt(svg, CX, 376, 'ring: size 16, mask 0xf, capacity 15', 'svg-label small center muted');
  el('circle', { cx: CX, cy: CY, r: R + 24, 'class': 'svg-line', fill: 'none', 'stroke-dasharray': '2 4' }, svg);
  for (var i = 0; i < N; i++) {
    var p = pos(i, R);
    var g = el('g', { transform: 'translate(' + p[0] + ',' + p[1] + ') rotate(' + (i * 360 / N) + ')' }, svg);
    var r = el('rect', { x: -17, y: -13, width: 34, height: 26, rx: 4, 'class': 'svg-slot svg-fade' }, g);
    slotG.push(r);
    var q = pos(i, R);
    slotLbl.push(txt(svg, q[0], q[1], '', 'svg-label small center bold'));
    var qq = pos(i, R - 27);
    txt(svg, qq[0], qq[1], String(i), 'svg-label small center muted');
  }
  var defs = [
    ['ph', 'prod_head', 'c1', R + 50, true, 1], ['pt', 'prod_tail', 'c1', R + 24, false, 1],
    ['ch', 'cons_head', 'c2', R - 46, true, -1], ['ct', 'cons_tail', 'c2', R - 70, false, -1]
  ];
  defs.forEach(function (d) {
    var g = el('g', { 'class': 'svg-fade' }, svg);
    var c = el('circle', { r: 6, 'class': 'svg-fill-' + d[2] }, g);
    if (d[4]) { c.setAttribute('fill-opacity', '0.25'); c.setAttribute('class', 'svg-stroke-' + d[2]); c.setAttribute('stroke-width', '2.5'); }
    var t = txt(g, 0, 0, d[1], 'svg-label small center bold');
    marks[d[0]] = { g: g, t: t, r: d[3], dot: c, dir: d[5] };
  });
  // right panel
  var X = 404;
  txt(svg, X, 34, 'shared: struct rte_ring', 'svg-title');
  var sharedT = txt(svg, X, 56, '', 'svg-label mono');
  var sharedT2 = txt(svg, X, 74, '', 'svg-label mono');
  var boxes = [];
  ['core 1 (local variables)', 'core 2 (local variables)'].forEach(function (name, k) {
    var y = 96 + k * 92;
    var b = el('rect', { x: X - 6, y: y, width: 276, height: 80, rx: 6, 'class': 'svg-box c1 svg-fade' }, svg);
    txt(svg, X + 4, y + 18, name, 'svg-label small bold');
    var l1 = txt(svg, X + 4, y + 40, '', 'svg-label mono');
    var l2 = txt(svg, X + 4, y + 60, '', 'svg-label mono');
    boxes.push({ rect: b, l1: l1, l2: l2 });
  });
  var status = txt(svg, X, 300, '', 'svg-label bold');
  var status2 = txt(svg, X, 320, '', 'svg-label small muted');

  function draw(st) {
    for (var i = 0; i < N; i++) {
      var v = st.slots[i];
      slotG[i].setAttribute('class', 'svg-slot svg-fade' + (v ? ' full' : ''));
      slotG[i].style.stroke = st.hl[i] ? 'var(--accent)' : '';
      slotG[i].style.strokeWidth = st.hl[i] ? '3' : '';
      slotG[i].style.opacity = st.reading[i] ? '0.5' : '';
      slotLbl[i].textContent = v ? v.replace('obj', 'o') : '';
    }
    // stack markers at the same index so labels do not collide
    var seen = {};
    defs.forEach(function (d) {
      var m = marks[d[0]], idx = st[d[0]] & 15;
      var p = bpos(idx, m.r);
      m.g.setAttribute('transform', 'translate(' + p[0].toFixed(1) + ',' + p[1].toFixed(1) + ')');
      // label sits further along the same radius (outwards for prod, inwards for cons)
      var q = bpos(idx, m.r + m.dir * (d[4] ? 14 : 12));
      var ox = q[0] - p[0], oy = q[1] - p[1];
      var a = Math.atan2(oy, ox), w = 30;
      m.t.setAttribute('x', (ox + Math.cos(a) * w * Math.abs(Math.cos(a))).toFixed(1));
      m.t.setAttribute('y', (oy + Math.sin(a) * 4).toFixed(1));
      seen[idx] = 1;
    });
    sharedT.textContent = 'prod.head=' + st.ph + '  prod.tail=' + st.pt;
    sharedT2.textContent = 'cons.head=' + st.ch + '  cons.tail=' + st.ct;
    for (var k = 0; k < 2; k++) {
      var L = st.loc[k];
      boxes[k].l1.textContent = L ? L[0] : '-';
      boxes[k].l2.textContent = L ? L[1] : '';
      boxes[k].rect.setAttribute('class', 'svg-box svg-fade ' + (st.act[k] || 'c7'));
    }
    status.textContent = st.msg || '';
    status2.textContent = st.msg2 || '';
  }
  function base() {
    var s = { slots: [], hl: {}, reading: {}, ph: 3, pt: 3, ch: 0, ct: 0, loc: [null, null], act: ['', ''], msg: '', msg2: '' };
    for (var i = 0; i < N; i++) s.slots.push(null);
    s.slots[0] = 'obj1'; s.slots[1] = 'obj2'; s.slots[2] = 'obj3';
    return s;
  }
  function S0(ctx) { ctx.data.s.hl = {}; ctx.data.s.msg2 = ''; }
  var steps = [
    { caption: 'Start: the ring holds obj1..obj3. <code>prod_head = prod_tail = 3</code>, <code>cons_head = cons_tail = 0</code>. Filled outer dot = tail, hollow = head. An index names the <em>next</em> slot to use.',
      run: function (c) { c.data.s.msg = 'Ring holds 3 objects (entries = 3 - 0)'; } },
    { caption: '<b>SP enqueue, step 1.</b> The producer copies <code>prod_head</code> and <code>cons_tail</code> into locals and computes free space = capacity + cons_tail - prod_head = 15 + 0 - 3 = 12. One object fits, so <code>prod_next = 4</code>.',
      run: function (c) { var s = c.data.s; S0(c); s.loc[0] = ['prod_head=3 cons_tail=0', 'free=12  prod_next=4']; s.act[0] = 'c1'; s.msg = 'SP enqueue obj4: read indexes'; } },
    { caption: '<b>SP enqueue, step 2.</b> <code>prod_head</code> moves to 4 (a plain store: there is only one producer) and obj4 is copied into slot <code>3 &amp; 15 = 3</code>.',
      predict: { question: 'obj4 is now in slot 3. Where is <code>prod_tail</code>?', options: ['still 3', '4'], answer: 0,
        explain: 'Still 3. The producer has not published yet, so a consumer that reads prod_tail sees only 3 entries and cannot read obj4 before it is fully written.' },
      run: function (c) { var s = c.data.s; S0(c); s.ph = 4; s.slots[3] = 'obj4'; s.hl[3] = 1; s.loc[0] = ['prod_head=3 cons_tail=0', 'free=12  prod_next=4']; s.act[0] = 'c1'; s.msg = 'Slot 3 written; not yet visible'; } },
    { caption: '<b>SP enqueue, step 3.</b> <code>prod_tail = 4</code>, written with <em>release</em> ordering so the slot write is visible before the new tail. obj4 is now published.',
      run: function (c) { var s = c.data.s; S0(c); s.pt = 4; s.loc[0] = null; s.act[0] = ''; s.msg = 'Enqueue done: entries = 4 - 0 = 4'; } },
    { caption: '<b>SC dequeue, step 1.</b> The consumer copies <code>cons_head = 0</code> and <code>prod_tail = 4</code>: entries = 4 - 0 = 4. It wants 1, so <code>cons_next = 1</code>.',
      run: function (c) { var s = c.data.s; S0(c); s.loc[1] = ['cons_head=0 prod_tail=4', 'entries=4  cons_next=1']; s.act[1] = 'c2'; s.msg = 'SC dequeue: read indexes'; } },
    { caption: '<b>SC dequeue, step 2.</b> <code>cons_head = 1</code>; obj1 is copied out of slot 0 into the caller\'s array.',
      predict: { question: 'Could a producer overwrite slot 0 right now?', options: ['Yes, cons_head already moved past it', 'No, producers compute free space from cons_tail, which is still 0'], answer: 1,
        explain: 'Producers look at cons_tail, not cons_head. Until cons_tail moves, slot 0 still counts as used, so the consumer can finish reading it safely.' },
      run: function (c) { var s = c.data.s; S0(c); s.ch = 1; s.reading[0] = 1; s.hl[0] = 1; s.loc[1] = ['cons_head=0 prod_tail=4', 'entries=4  cons_next=1']; s.act[1] = 'c2'; s.msg = 'Reading obj1 from slot 0'; } },
    { caption: '<b>SC dequeue, step 3.</b> <code>cons_tail = 1</code> (release). Slot 0 is free again.',
      run: function (c) { var s = c.data.s; S0(c); s.ct = 1; s.slots[0] = null; s.reading = {}; s.loc[1] = null; s.act[1] = ''; s.msg = 'Dequeue done: entries = 4 - 1 = 3'; } },
    { caption: '<b>MP race, step 1.</b> Two producers on two cores both want to enqueue one object. Both read <code>prod_head = 4</code>, <code>cons_tail = 1</code> and both compute <code>prod_next = 5</code>.',
      run: function (c) { var s = c.data.s; S0(c); s.loc[0] = ['old_head=4 cons_tail=1', 'new_head=5 (obj5)']; s.loc[1] = ['old_head=4 cons_tail=1', 'new_head=5 (obj6)']; s.act = ['c1', 'c1']; s.msg = 'Two producers, same snapshot'; } },
    { caption: '<b>MP race, step 2.</b> Both try <code>CAS(&amp;prod.head, 4, 5)</code>. The CPU lets exactly one win. Core 1 wins: <code>prod_head = 5</code>. For core 2 the compare fails, because head is no longer 4.',
      predict: { question: 'Core 2\'s CAS failed. What does it do?', options: ['Returns 0: the enqueue failed', 'Retries: the failed CAS gave it the current head (5), so it recomputes free space and new_head = 6', 'Spins until core 1 has finished'], answer: 1,
        explain: 'A failed CAS writes the current value into old_head. The loop in __rte_ring_headtail_move_head_mt recomputes and tries again. Nothing is lost; core 2 just takes the next slot.' },
      run: function (c) { var s = c.data.s; S0(c); s.ph = 5; s.loc[0] = ['CAS(head, 4, 5): OK', 'my slots: 4'];
        s.loc[1] = ['CAS(head, 4, 5): FAILED', 'head is really 5']; s.act = ['c2', 'c4']; s.msg = 'Core 1 won the CAS'; } },
    { caption: '<b>MP race, step 3.</b> Core 2 retries with <code>old_head = 5</code>: <code>CAS(&amp;prod.head, 5, 6)</code> succeeds. Each core now owns one slot: core 1 slot 4, core 2 slot 5.',
      run: function (c) { var s = c.data.s; S0(c); s.ph = 6; s.loc[0] = ['CAS(head, 4, 5): OK', 'my slots: 4']; s.loc[1] = ['retry CAS(head, 5, 6): OK', 'my slots: 5']; s.act = ['c1', 'c1']; s.msg = 'Both reserved; prod_tail still 4'; } },
    { caption: '<b>MP race, step 4.</b> They copy in parallel. Core 2 happens to finish first: obj6 is in slot 5, while obj5 is still being written to slot 4.',
      run: function (c) { var s = c.data.s; S0(c); s.slots[5] = 'obj6'; s.slots[4] = 'obj5'; s.reading[4] = 1; s.hl[5] = 1; s.loc[0] = ['copying obj5 -> slot 4 ...', '']; s.loc[1] = ['obj6 -> slot 5: done', 'next: publish tail']; s.act = ['c3', 'c1']; s.msg = 'Copies in parallel'; } },
    { caption: '<b>MP race, step 5.</b> Core 2 wants to publish <code>prod_tail = 6</code>, but the rule is: you may move the tail only when it equals <em>your</em> old head.',
      predict: { question: 'prod_tail is 4 and core 2\'s old_head is 5. What happens?', options: ['Core 2 sets prod_tail = 6 now', 'Core 2 spins until prod_tail becomes 5'], answer: 1,
        explain: 'Tails move in reservation order. If core 2 published 6 now, a consumer could read slot 4 before core 1 finished writing obj5. So core 2 waits (rte_wait_until_equal_32 in __rte_ring_update_tail).' },
      run: function (c) { var s = c.data.s; S0(c); s.slots[5] = 'obj6'; s.slots[4] = 'obj5'; s.reading[4] = 1; s.loc[0] = ['copying obj5 -> slot 4 ...', '']; s.loc[1] = ['wait: prod_tail(4) != 5', 'spinning ...']; s.act = ['c3', 'c4']; s.msg = 'Core 2 waits for core 1'; s.msg2 = 'Preempt core 1 now and core 2 spins on.'; } },
    { caption: '<b>MP race, step 6.</b> Core 1 finishes its copy; <code>prod_tail == 4 ==</code> its old head, so it stores <code>prod_tail = 5</code>.',
      run: function (c) { var s = c.data.s; S0(c); s.slots[5] = 'obj6'; s.slots[4] = 'obj5'; s.reading = {}; s.pt = 5; s.loc[0] = ['prod_tail 4 == old_head 4', 'store prod_tail = 5: done']; s.loc[1] = ['wait: prod_tail == 5 ?', 'yes, go']; s.act = ['c2', 'c1']; s.msg = 'Core 1 published obj5'; } },
    { caption: '<b>MP race, step 7.</b> Now <code>prod_tail == 5 ==</code> core 2\'s old head, so it stores <code>prod_tail = 6</code>. obj5 and obj6 are visible, in reservation order.',
      run: function (c) { var s = c.data.s; S0(c); s.slots[5] = 'obj6'; s.slots[4] = 'obj5'; s.pt = 6; s.loc[0] = null; s.loc[1] = ['store prod_tail = 6: done', '']; s.act = ['', 'c2']; s.msg = 'Both published: entries = 6 - 1 = 5'; } }
  ];
  new CourseJS.Stepper(root, {
    reset: function (ctx) { ctx.data.s = base(); },
    steps: steps,
    onStep: function (i, ctx) { draw(ctx.data.s); },
    interval: 2600
  });
}

/* =====================================================================
 * Widget 2: the modulo-2^32 odometer.
 * ===================================================================== */
function odometer() {
  var root = document.getElementById('w-odo');
  if (!root) return;
  var svg = root.querySelector('svg');
  var SIZE = 8, MASK = 7, CAP = 7;
  var st = { pt: 0, ct: 0 };
  var slots = [], lbls = [];
  for (var i = 0; i < SIZE; i++) {
    slots.push(el('rect', { x: 40 + i * 62, y: 150, width: 54, height: 34, rx: 5, 'class': 'svg-slot svg-fade' }, svg));
    txt(svg, 67 + i * 62, 198, 'slot ' + i, 'svg-label small center muted');
    lbls.push(txt(svg, 67 + i * 62, 167, '', 'svg-label small center mono'));
  }
  txt(svg, 20, 24, 'prod.tail', 'svg-label bold');
  txt(svg, 20, 84, 'cons.head', 'svg-label bold');
  var dP = txt(svg, 110, 24, '', 'svg-label mono');
  var dC = txt(svg, 110, 84, '', 'svg-label mono');
  var hP = txt(svg, 110, 44, '', 'svg-label small mono muted');
  var sP = txt(svg, 250, 24, '', 'svg-label mono');
  var sC = txt(svg, 250, 84, '', 'svg-label mono');
  var hC = txt(svg, 110, 104, '', 'svg-label small mono muted');
  var mP = el('path', { 'class': 'svg-arrow c1' }, svg);
  var mC = el('path', { 'class': 'svg-arrow c2' }, svg);
  var out = root.querySelector('.odo-out');
  function hex(v) { return '0x' + ('00000000' + (v >>> 0).toString(16)).slice(-8); }
  function draw() {
    var pt = st.pt >>> 0, ct = st.ct >>> 0;
    var entries = (pt - ct) >>> 0;
    dP.textContent = String(pt); dC.textContent = String(ct);
    sP.textContent = 'slot = ' + pt + ' & 7 = ' + (pt & MASK);
    sC.textContent = 'slot = ' + ct + ' & 7 = ' + (ct & MASK);
    hP.textContent = hex(pt); hC.textContent = hex(ct);
    for (var i = 0; i < SIZE; i++) {
      var used = ((i - (ct & MASK) + SIZE) & MASK) < entries;
      slots[i].setAttribute('class', 'svg-slot svg-fade' + (used ? ' full' : ''));
      lbls[i].textContent = '';
    }
    for (var k = 0; k < entries; k++) { var v = String((ct + k) >>> 0); lbls[(ct + k) & MASK].textContent = v.length > 4 ? '\u2026' + v.slice(-3) : v; }
    var xp = 40 + (pt & MASK) * 62 + 4, xc = 40 + (ct & MASK) * 62 + 4;
    mP.setAttribute('d', 'M' + xp + ',122 L' + xp + ',146');
    mC.setAttribute('d', 'M' + (xc + 10) + ',122 L' + (xc + 10) + ',146');
    var naive = pt - ct; // plain JS subtraction: what a 64-bit signed calc gives
    out.innerHTML = '<b>uint32_t entries = prod.tail - cons.head</b> = ' + pt + ' - ' + ct + ' = <b>' + entries + '</b> (mod 2<sup>32</sup>)' +
      ' &nbsp;|&nbsp; free = capacity + cons.tail - prod.head = <b>' + ((CAP + ct - pt) >>> 0) + '</b>' +
      (naive !== entries ? '<br><span class="odo-bad">Signed 64-bit maths would say ' + naive + ': wrong. That is why the ring keeps the indexes as uint32_t.</span>' : '');
  }
  function btn(id, fn) { var b = root.querySelector('[data-act="' + id + '"]'); if (b) b.addEventListener('click', function () { fn(); draw(); }); }
  btn('enq', function () { var e = (st.pt - st.ct) >>> 0; var n = Math.min(3, CAP - e); st.pt = (st.pt + n) >>> 0; });
  btn('deq', function () { var e = (st.pt - st.ct) >>> 0; var n = Math.min(2, e); st.ct = (st.ct + n) >>> 0; });
  btn('jump', function () { st.ct = 4294967291; st.pt = (st.ct + 3) >>> 0; });
  btn('reset', function () { st.pt = 0; st.ct = 0; });
  draw();
}

/* =====================================================================
 * Widget 3: sync-mode Gantt. Three producers, one is preempted.
 * ===================================================================== */
function gantt() {
  var root = document.getElementById('w-gantt');
  if (!root) return;
  var svg = root.querySelector('svg.gantt');
  var T = 56, X0 = 64, W = 600, DX = W / T, LANE = [40, 82, 124], H = 26;
  var modeSel = root.querySelector('#g-mode'), pre = root.querySelector('#g-pre');
  var stats = root.querySelector('.g-stats');
  var KIND = { R: 'c1', C: 'c3', P: 'c2', S: 'c4', W: 'c6', X: 'c7', F: 'c6' };
  // simulate: returns cells[th][t] and visible[t]
  function simulate(mode, preempt) {
    var nth = 3, HTD = 4, cells = [[], [], []], visible = [];
    var th = [], res = [], tailpos = 0, inflight = 0, preDone = false;
    for (var k = 0; k < nth; k++) th.push({ ph: 'R', left: 0, seq: -1, pre: 0, ops: 0 });
    for (var t = 0; t < T; t++) {
      var reservedThisTick = false;
      for (k = 0; k < nth; k++) {
        var s = th[k];
        if (s.pre > 0) { s.pre--; cells[k][t] = 'X'; continue; }
        if (s.ph === 'R') {
          var ok = true, why = 'F';
          if (mode === 'hts' && inflight > 0) { ok = false; why = 'W'; }
          if (mode === 'rts' && res.length - tailpos >= HTD) { ok = false; why = 'W'; }
          if (ok && reservedThisTick) { ok = false; why = 'F'; }
          if (!ok) { cells[k][t] = why; continue; }
          reservedThisTick = true; s.seq = res.length; res.push(false); inflight++;
          cells[k][t] = 'R'; s.ph = 'C'; s.left = 2; continue;
        }
        if (s.ph === 'C') {
          cells[k][t] = 'C'; s.left--;
          if (preempt && !preDone && k === 1 && s.ops >= 1 && t >= 6) { preDone = true; s.pre = 16; }
          if (s.left === 0) s.ph = 'P';
          continue;
        }
        if (s.ph === 'P') {
          if (mode === 'mp') {
            var allPrev = true;
            for (var j = 0; j < s.seq; j++) if (!res[j]) { allPrev = false; break; }
            if (!allPrev) { cells[k][t] = 'S'; continue; }
          }
          cells[k][t] = 'P'; res[s.seq] = true; inflight--; s.ops++; s.ph = 'R';
        }
      }
      // tail position seen by consumers
      if (mode === 'rts') { if (inflight === 0) tailpos = res.length; }
      else { while (tailpos < res.length && res[tailpos]) tailpos++; }
      visible.push(tailpos);
    }
    var ops = th.map(function (s) { return s.ops; });
    return { cells: cells, visible: visible, ops: ops };
  }
  // static frame
  ['T1', 'T2', 'T3'].forEach(function (n, k) { txt(svg, 8, LANE[k] + H / 2 + 4, n, 'svg-label bold'); });
  txt(svg, 8, 186, 'tail', 'svg-label bold');
  txt(svg, 8, 200, '(visible)', 'svg-label small muted');
  el('line', { x1: X0, y1: 214, x2: X0 + W, y2: 214, 'class': 'svg-line' }, svg);
  for (var t = 0; t <= T; t += 8) { el('line', { x1: X0 + t * DX, y1: 210, x2: X0 + t * DX, y2: 218, 'class': 'svg-line' }, svg); txt(svg, X0 + t * DX, 232, String(t), 'svg-label small center muted'); }
  txt(svg, X0 + W, 250, 'time (ticks)', 'svg-label small muted', { 'text-anchor': 'end' });
  var cellG = el('g', {}, svg), visG = el('g', {}, svg);
  var cursor = el('line', { x1: X0, y1: 30, x2: X0, y2: 214, 'class': 'svg-line', 'stroke-dasharray': '3 3', style: 'stroke:var(--accent);stroke-width:2' }, svg);
  var sim, rects = [], visPath;
  function build() {
    S.clear(cellG); S.clear(visG); rects = [];
    sim = simulate(modeSel.value, pre.checked);
    for (var k = 0; k < 3; k++) for (var t = 0; t < T; t++) {
      var c = sim.cells[k][t]; if (!c) continue;
      var r = el('rect', { x: X0 + t * DX + 0.5, y: LANE[k], width: DX - 1, height: H, rx: 2, style: 'fill:var(--' + KIND[c] + ');opacity:0' }, cellG);
      if (c === 'X') r.setAttribute('style', 'fill:var(--c7-soft);stroke:var(--c7);opacity:0');
      r._t = t; rects.push(r);
    }
    var d = '', maxv = Math.max(1, sim.visible[T - 1]);
    visPath = el('path', { 'class': 'svg-line', fill: 'none', style: 'stroke:var(--c5);stroke-width:2' }, visG);
    visPath._pts = sim.visible.map(function (v, t) { return [X0 + (t + 1) * DX, 206 - 34 * v / maxv]; });
    visG._max = maxv;
  }
  function render(tt) {
    var shown = Math.min(T, Math.floor(tt));
    rects.forEach(function (r) { r.style.opacity = r._t < shown ? '0.9' : '0'; });
    var d = 'M' + X0 + ',206';
    for (var i = 0; i < shown; i++) d += ' L' + visPath._pts[i][0].toFixed(1) + ',' + visPath._pts[i][1].toFixed(1);
    visPath.setAttribute('d', d);
    cursor.setAttribute('x1', X0 + shown * DX); cursor.setAttribute('x2', X0 + shown * DX);
    var ops = [0, 0, 0];
    for (var k = 0; k < 3; k++) for (var t2 = 0; t2 < shown; t2++) if (sim.cells[k][t2] === 'P') ops[k]++;
    var spin = 0;
    for (k = 0; k < 3; k++) for (t2 = 0; t2 < shown; t2++) { var c = sim.cells[k][t2]; if (c === 'S' || c === 'W' || c === 'F') spin++; }
    stats.innerHTML = 'tick <b>' + shown + '</b> &nbsp; enqueues done: T1 <b>' + ops[0] + '</b>, T2 <b>' + ops[1] + '</b>, T3 <b>' + ops[2] +
      '</b> &nbsp; visible to consumer: <b>' + (shown ? sim.visible[shown - 1] : 0) + '</b> &nbsp; wasted (spin/wait) ticks: <b>' + spin + '</b>';
  }
  var anim = new CourseJS.Animator({
    root: root, autoplay: 'visible', speed: 1,
    onReset: function (a) { a.t = 0; build(); render(0); },
    onFrame: function (dt, t, a) { var tt = t * 8; if (tt > T + 12) { a.t = 0; tt = 0; } render(tt); }
  });
  function rebuild() { build(); render(anim.t * 8); }
  modeSel.addEventListener('change', rebuild);
  pre.addEventListener('change', rebuild);
  modeSel.addEventListener('change', highlightBars);
  // measured bars (ring_modes_bench, symmetric, burst 32)
  var bars = root.querySelector('svg.bars');
  var data = (window.CH05_BARS || []);
  var BX = 150, BW = 470, maxv = 0;
  data.forEach(function (d) { maxv = Math.max(maxv, d.a, d.b); });
  var barEls = [];
  data.forEach(function (d, i) {
    var y = 18 + i * 52;
    var g = el('g', { 'class': 'svg-fade' }, bars);
    txt(g, BX - 10, y + 20, d.mode, 'svg-label bold', { 'text-anchor': 'end' });
    [['a', 'c1', 0], ['b', 'c3', 22]].forEach(function (s) {
      var w = Math.max(2, BW * d[s[0]] / maxv);
      var r = el('rect', { x: BX, y: y + s[2], width: w, height: 18, rx: 4, 'class': 'svg-fill-' + s[1] }, g);
      var tt = document.createElementNS(NS, 'title');
      tt.textContent = d.mode + ', ' + (s[0] === 'a' ? '3 lcores on 3 CPUs' : '4 lcores on 1 CPU') + ': median ' + d[s[0]] + ' Mobj/s (min ' + d[s[0] + 'min'] + ', max ' + d[s[0] + 'max'] + ')';
      r.appendChild(tt);
      txt(g, BX + w + 6, y + s[2] + 13, d[s[0]].toFixed(1), 'svg-label small');
    });
    barEls.push({ g: g, key: d.key });
  });
  function highlightBars() { barEls.forEach(function (b) { b.g.style.opacity = (b.key === modeSel.value || b.key === 'sp') ? '1' : '0.45'; }); }
  highlightBars();
}

/* =====================================================================
 * Widget 4: bulk vs burst on a ring with 15 usable slots.
 * ===================================================================== */
function bulkBurst() {
  var root = document.getElementById('w-bulk');
  if (!root) return;
  var svg = root.querySelector('svg');
  var CAP = 15, SW = 32, X0 = 66;
  var rows = [{ y: 30, name: 'bulk' }, { y: 110, name: 'burst' }];
  rows.forEach(function (row) {
    txt(svg, 8, row.y + 18, row.name, 'svg-label bold');
    row.slots = [];
    for (var i = 0; i < CAP; i++) row.slots.push(el('rect', { x: X0 + i * SW, y: row.y, width: SW - 4, height: 28, rx: 4, 'class': 'svg-slot svg-fade' }, svg));
    row.over = el('g', {}, svg);
    row.res = txt(svg, X0, row.y + 50, '', 'svg-label mono');
  });
  var fill = root.querySelector('#bb-fill'), n = root.querySelector('#bb-n'), dir = root.querySelector('#bb-dir');
  function draw() {
    var used = +fill.value, req = +n.value, deq = dir.value === 'deq';
    var free = CAP - used;
    var room = deq ? used : free;
    rows.forEach(function (row) {
      var take = row.name === 'bulk' ? (req <= room ? req : 0) : Math.min(req, room);
      S.clear(row.over);
      for (var i = 0; i < CAP; i++) {
        var cls = 'svg-slot svg-fade', st = '';
        if (!deq) {
          if (i < used) cls += ' full';
          else if (i < used + take) st = 'fill:var(--c5-soft);stroke:var(--c5);stroke-width:2';
        } else {
          if (i < take) st = 'fill:var(--c2-soft);stroke:var(--c2);stroke-width:2;opacity:.55';
          else if (i < used) cls += ' full';
        }
        row.slots[i].setAttribute('class', cls); row.slots[i].setAttribute('style', st);
      }
      var miss = req - take;
      if (miss > 0) {
        var x = X0 + CAP * SW + 6;
        el('rect', { x: x, y: row.y - 3, width: 100, height: 34, rx: 5, style: 'fill:var(--c4-soft);stroke:var(--c4);stroke-dasharray:4 3' }, row.over);
        txt(row.over, x + 50, row.y + 14, miss + ' not ' + (deq ? 'there' : 'moved'), 'svg-label small center');
      }
      var fn = deq ? 'rte_ring_dequeue_' : 'rte_ring_enqueue_';
      var out = deq ? 'available' : 'free_space';
      var after = deq ? used - take : free - take;
      row.res.textContent = fn + row.name + '(r, objs, ' + req + ', &' + out + ') = ' + take + '   ' + out + ' = ' + after;
      row.res.style.fill = take === 0 ? 'var(--c4)' : '';
    });
    root.querySelector('#bb-fill-o').textContent = used + ' used / ' + free + ' free';
    root.querySelector('#bb-n-o').textContent = req;
  }
  [fill, n, dir].forEach(function (e) { e.addEventListener('input', draw); e.addEventListener('change', draw); });
  draw();
}

CourseJS.ready(function () { ringClock(); odometer(); gantt(); bulkBurst(); });
})();

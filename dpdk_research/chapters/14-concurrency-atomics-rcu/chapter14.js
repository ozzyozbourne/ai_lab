/* Chapter 14 widgets: memory-ordering playground, lock zoo, RCU grace-period
 * timeline, MESI ping-pong, per-lcore data layouts.
 * Requires ../../assets/course.js. All measured numbers below are copied
 * from code/expected_output.txt (the run captured on this machine). */
(function () {
  'use strict';
  var CJ = window.CourseJS, S = CJ.svg;

  /* Numbers from code/expected_output.txt ------------------------------- */
  var MEASURED = {
    litmus: { iters: 1000000,
      MP: { relaxed: 0, relacq: 0 },
      SB: { relaxed: 150288, relacq: 176609, fence: 0 } },
    counters: [            /* cycles per increment, median of 5, 3 workers */
      { id: 'shared-fa',  label: 'shared atomic, fetch_add',     v: 165.29 },
      { id: 'packed-fa',  label: 'packed array, fetch_add',      v: 236.32 },
      { id: 'padded-fa',  label: 'padded + guard, fetch_add',    v: 12.81 },
      { id: 'lv-fa',      label: 'lcore variable, fetch_add',    v: 12.81 },
      { id: 'packed-ls',  label: 'packed array, load+store',     v: 0.74 },
      { id: 'padded-ls',  label: 'padded + guard, load+store',   v: 0.71 },
      { id: 'lv-ls',      label: 'lcore variable, load+store',   v: 0.71 }
    ]
  };

  function segButtons(root, attr, onChange) {
    var btns = CJ.$$('[' + attr + ']', root);
    function set(v) {
      btns.forEach(function (b) { b.setAttribute('aria-pressed', b.getAttribute(attr) === v ? 'true' : 'false'); });
    }
    btns.forEach(function (b) {
      b.addEventListener('click', function () { set(b.getAttribute(attr)); onChange(b.getAttribute(attr)); });
    });
    return set;
  }

  /* =====================================================================
   * 1. Memory-ordering playground (predict, then step)
   * ===================================================================== */
  function orderingPlayground() {
    var root = document.getElementById('w-order');
    if (!root) return;
    var svg = root.querySelector('svg');
    var out = root.querySelector('.w-out');
    var cfg = { test: 'SB', mo: 'relaxed', arch: 'x86' };

    /* static layout */
    S.clear(svg);
    var core = [], buf = [];
    for (var c = 0; c < 2; c++) {
      var x = 20 + c * 340;
      var g = S.group(svg);
      S.rect(g, x, 14, 300, 132, 'svg-box c1');
      S.text(g, x + 12, 34, c === 0 ? 'T0 on lcore 1' : 'T1 on lcore 2', 'svg-label bold');
      var hl = S.rect(g, x + 8, 44, 284, 20, 'svg-box c3', { rx: 3, style: 'opacity:0' });
      var lines = [];
      for (var k = 0; k < 3; k++) lines.push(S.text(g, x + 14, 58 + k * 24, '', 'svg-label mono small'));
      var reg = S.text(g, x + 288, 34, '', 'svg-label mono bold', { 'text-anchor': 'end' });
      core.push({ hl: hl, lines: lines, reg: reg, x: x });
      S.rect(svg, x + 20, 160, 260, 44, 'svg-box c5');
      S.text(svg, x + 30, 176, 'store buffer (FIFO on x86)', 'svg-label small muted');
      var bg = S.group(svg);
      buf.push({ g: bg, x: x + 30 });
      S.arrow(svg, x + 150, 204, x + 150 + (c === 0 ? 60 : -60), 246, 'c5');
    }
    var bufTitles = CJ.$$('text', svg).filter(function (t) { return /store buffer/.test(t.textContent); });
    S.rect(svg, 150, 250, 380, 60, 'svg-box c2');
    S.text(svg, 340, 266, 'memory (what other cores can see)', 'svg-label small center muted');
    var memTxt = S.text(svg, 340, 292, '', 'svg-label mono bold center');
    var note = S.text(svg, 340, 336, '', 'svg-label small center');

    function code(test, mo, arch, who) {
      if (test === 'SB') {
        var st = mo === 'plain' ? (who ? 'y = 1;' : 'x = 1;')
          : 'store(&' + (who ? 'y' : 'x') + ', 1, ' + (mo === 'relacq' ? 'release' : 'relaxed') + ');';
        var ld = mo === 'plain' ? (who ? 'r2 = x;' : 'r1 = y;')
          : (who ? 'r2' : 'r1') + ' = load(&' + (who ? 'x' : 'y') + ', ' + (mo === 'relacq' ? 'acquire' : 'relaxed') + ');';
        return mo === 'fence' ? [st, 'fence(seq_cst);', ld] : [st, ld];
      }
      if (who === 0) {
        if (mo === 'plain') return ['flag = 1;   /* moved up by gcc -O2 */', 'data = 1;'];
        if (mo === 'fence') return ['store(&data, 1, relaxed);', 'fence(seq_cst);', 'store(&flag, 1, relaxed);'];
        return ['store(&data, 1, relaxed);', 'store(&flag, 1, ' + (mo === 'relacq' ? 'release' : 'relaxed') + ');'];
      }
      if (mo === 'plain') return ['r1 = flag;', 'r2 = data;'];
      if (mo === 'fence') return ['r1 = load(&flag, relaxed);', 'fence(seq_cst);', 'r2 = load(&data, relaxed);'];
      return ['r1 = load(&flag, ' + (mo === 'relacq' ? 'acquire' : 'relaxed') + ');', 'r2 = load(&data, relaxed);'];
    }

    /* Build the 6 frames of one interleaving for the current config. */
    function frames() {
      var F = [], st = { b0: [], b1: [], mem: {}, r1: '?', r2: '?', h0: -1, h1: -1 };
      var vars = cfg.test === 'SB' ? ['x', 'y'] : ['data', 'flag'];
      vars.forEach(function (v) { st.mem[v] = 0; });
      var fence = cfg.mo === 'fence', x86 = cfg.arch === 'x86';
      function snap(caption) {
        F.push({ b0: st.b0.slice(), b1: st.b1.slice(), mem: JSON.parse(JSON.stringify(st.mem)),
          r1: st.r1, r2: st.r2, h0: st.h0, h1: st.h1, caption: caption });
      }
      function drain(b, which) {          /* which: index to drain, default oldest */
        var i = which == null ? 0 : which;
        var e = b.splice(i, 1)[0];
        if (e) st.mem[e.v] = e.val;
        return e;
      }
      if (cfg.test === 'SB') {
        snap('x = y = 0, both store buffers empty. Each thread will store 1, then load the other variable.');
        st.b0.push({ v: 'x', val: 1 }); st.h0 = 0;
        if (fence) { drain(st.b0); st.h0 = 1; snap('T0 stores x = 1 into its store buffer, then the seq_cst fence waits until the buffer has drained: x = 1 is now in memory.'); }
        else snap('T0 stores x = 1. The store sits in T0\'s store buffer: T1 cannot see it yet.');
        st.b1.push({ v: 'y', val: 1 }); st.h1 = 0;
        if (fence) { drain(st.b1); st.h1 = 1; snap('T1 stores y = 1 and its fence drains it to memory before T1 may load anything.'); }
        else snap('T1 stores y = 1, also into its own store buffer. Memory still says x = 0, y = 0.');
        st.h0 = fence ? 2 : 1; st.r1 = st.mem.y;
        snap('T0 loads y. Loads do not wait for older stores to other addresses: T0 reads y from memory: r1 = ' + st.r1 + '.');
        st.h1 = fence ? 2 : 1; st.r2 = st.mem.x;
        snap('T1 loads x from memory: r2 = ' + st.r2 + '.');
        while (st.b0.length) drain(st.b0);
        while (st.b1.length) drain(st.b1);
        st.h0 = st.h1 = -1;
        snap('The store buffers drain. Final registers: r1 = ' + st.r1 + ', r2 = ' + st.r2 + '.');
      } else {
        snap('data = flag = 0. T0 publishes data, then raises flag. T1 checks flag, then reads data.');
        var plain = cfg.mo === 'plain';
        var first = plain ? 'flag' : 'data', second = plain ? 'data' : 'flag';
        st.b0.push({ v: first, val: 1 }); st.h0 = 0;
        snap(plain ? 'The compiler emitted the flag store FIRST (see the objdump of writer_plain). flag = 1 enters the store buffer.'
          : 'T0 stores data = 1 into its store buffer.');
        if (fence) { drain(st.b0); st.h0 = 2; st.b0.push({ v: 'flag', val: 1 });
          snap('The fence drains data = 1 to memory, then T0 stores flag = 1 into the buffer.'); }
        else if (cfg.mo === 'relacq' && !x86) { drain(st.b0); st.h0 = 1; st.b0.push({ v: 'flag', val: 1 });
          snap('Release store (Arm stlr): it may not become visible before data, so data = 1 is made visible first; flag = 1 waits in the buffer.'); }
        else { st.b0.push({ v: second, val: 1 }); st.h0 = 1;
          snap('T0 stores ' + second + ' = 1. The buffer now holds both stores, oldest first.'); }
        var e;
        if (x86 || st.b0.length < 2) { e = drain(st.b0);
          snap(x86 ? 'x86: the store buffer is FIFO. The OLDEST store (' + e.v + ') reaches memory first.'
            : 'The one store left (' + e.v + ') reaches memory.'); }
        else { var fi = st.b0[0].v === 'flag' ? 0 : 1; e = drain(st.b0, fi);
          snap('Arm (model): stores to different addresses may become visible in any order. flag reaches memory before data.'); }
        st.h1 = fence ? 2 : 1; st.r1 = st.mem.flag; st.r2 = st.mem.data;
        snap('T1 loads flag (r1 = ' + st.r1 + ') and then data (r2 = ' + st.r2 + ') from memory.');
        while (st.b0.length) drain(st.b0);
        st.h0 = st.h1 = -1;
        snap('Everything drains. Final: r1 = ' + st.r1 + ', r2 = ' + st.r2 + '.');
      }
      return F;
    }

    function allowed() {    /* is the "interesting" outcome allowed? */
      if (cfg.test === 'SB') return cfg.mo !== 'fence';
      if (cfg.arch === 'x86') return cfg.mo === 'plain';
      return cfg.mo === 'plain' || cfg.mo === 'relaxed';
    }

    var cur = [];
    function draw(i) {
      var f = cur[i] || cur[0];
      for (var c = 0; c < 2; c++) {
        var lines = code(cfg.test, cfg.mo, cfg.arch, c);
        core[c].lines.forEach(function (t, k) { t.textContent = lines[k] || ''; });
        var h = c === 0 ? f.h0 : f.h1;
        core[c].hl.style.opacity = h >= 0 ? 0.55 : 0;
        if (h >= 0) core[c].hl.setAttribute('y', 44 + h * 24);
        var reg = cfg.test === 'SB' ? (c === 0 ? 'r1 = ' + f.r1 : 'r2 = ' + f.r2)
          : (c === 0 ? '' : 'r1 = ' + f.r1 + ', r2 = ' + f.r2);
        core[c].reg.textContent = reg;
        S.clear(buf[c].g);
        (c === 0 ? f.b0 : f.b1).forEach(function (e, k) {
          S.rect(buf[c].g, buf[c].x + k * 92, 182, 84, 18, 'svg-box c3', { rx: 3 });
          S.text(buf[c].g, buf[c].x + 42 + k * 92, 191, e.v + ' = ' + e.val, 'svg-label small center mono');
        });
      }
      bufTitles.forEach(function (t) {
        t.textContent = cfg.arch === 'x86' ? 'store buffer (FIFO on x86)' : 'pending stores (Arm: any order)';
      });
      var m = f.mem;
      memTxt.textContent = Object.keys(m).map(function (k) { return k + ' = ' + m[k]; }).join('    ');
      var interesting = cfg.test === 'SB' ? '(r1, r2) = (0, 0)' : '(r1, r2) = (1, 0)';
      note.textContent = cfg.arch === 'x86' ? 'x86-TSO: model AND measurement on this VM'
        : 'Arm: what the architecture model allows. Not measured: this VM is x86.';
      var meas;
      var mo = cfg.mo;
      if (cfg.arch !== 'x86') meas = 'model-only (herd7 / the Arm ARM). No Arm hardware here, so no number.';
      else if (MEASURED.litmus[cfg.test][mo] != null)
        meas = 'litmus.c measured it <strong>' + CJ.fmt(MEASURED.litmus[cfg.test][mo]) + '</strong> times in ' +
          CJ.fmt(MEASURED.litmus.iters) + ' runs.';
      else if (mo === 'plain' && cfg.test === 'MP')
        meas = 'not a runtime test: the reordering is in the compiled code (<code>make objdump</code>, writer_plain).';
      else meas = 'not run by litmus.c for this combination.';
      out.innerHTML = 'Interesting outcome ' + interesting + ': <strong>' + (allowed() ? 'ALLOWED' : 'FORBIDDEN') +
        '</strong> for ' + (cfg.test === 'SB' ? 'store buffering' : 'message passing') + ' with ' +
        { plain: 'plain C accesses', relaxed: 'relaxed atomics', relacq: 'release/acquire', fence: 'seq_cst fences' }[mo] +
        ' on ' + (cfg.arch === 'x86' ? 'x86-TSO' : 'Arm') + '. ' + meas;
    }

    var steps = [];
    for (var s = 0; s < 6; s++) steps.push({ caption: '' });
    steps[5].predict = { question: '', options: ['r1 = 0, r2 = 0', 'r1 = 0, r2 = 1', 'r1 = 1, r2 = 0', 'r1 = 1, r2 = 1'], answer: 0, explain: '' };

    function rebuild() {
      cur = frames();
      cur.forEach(function (f, i) { steps[i].caption = f.caption; });
      var fin = cur[5];
      steps[5].predict.question = 'after everything drains, which registers does THIS interleaving end with?';
      steps[5].predict.answer = fin.r1 * 2 + fin.r2;
      steps[5].predict.explain = (allowed()
        ? 'This interleaving produces the "interesting" outcome, so the configuration allows it.'
        : 'Even this worst-case interleaving cannot produce the interesting outcome: the configuration forbids it.');
      if (stepper) { stepper.answered = {}; stepper.go(0); }
    }

    var stepper = null;
    rebuild();
    stepper = new CJ.Stepper(root, { steps: steps, interval: 2200, onStep: function (i) { draw(i); } });

    var selT = root.querySelector('[data-o="test"]'), selM = root.querySelector('[data-o="mo"]');
    selT.addEventListener('change', function () { cfg.test = selT.value; rebuild(); });
    selM.addEventListener('change', function () { cfg.mo = selM.value; rebuild(); });
    var setArch = segButtons(root, 'data-arch', function (v) { cfg.arch = v; rebuild(); });
    setArch('x86');
  }

  /* =====================================================================
   * 2. Lock zoo (animation)
   * ===================================================================== */
  function lockZoo() {
    var root = document.getElementById('w-locks');
    if (!root) return;
    var svg = root.querySelector('svg');
    var stats = root.querySelector('.w-out');
    var kind = 'spin';
    var CS = 0.55, NCORE = 3;
    var st;

    var cy = [60, 140, 220];
    function layout() {
      S.clear(svg);
      st.g = {};
      st.coreEl = [];
      for (var i = 0; i < NCORE; i++) {
        var g = S.group(svg);
        var circ = S.el('circle', { cx: 60, cy: cy[i], r: 26, 'class': 'svg-box c1' }, g);
        S.text(g, 60, cy[i], 'C' + (i + 1), 'svg-label center bold');
        var s1 = S.text(g, 96, cy[i] - 6, '', 'svg-label small');
        var s2 = S.text(g, 96, cy[i] + 10, '', 'svg-label small mono');
        st.coreEl.push({ circ: circ, s1: s1, s2: s2 });
      }
      st.wires = S.group(svg);
      st.lockBox = S.rect(svg, 290, 100, 190, 80, 'svg-box c5');
      st.lockT1 = S.text(svg, 385, 118, '', 'svg-label small center bold');
      st.lockT2 = S.text(svg, 385, 140, '', 'svg-label mono center');
      st.lockT3 = S.text(svg, 385, 162, '', 'svg-label small center');
      st.nodes = S.group(svg);
      S.rect(svg, 520, 110, 140, 60, 'svg-box c2');
      st.dataT1 = S.text(svg, 590, 128, kind === 'seq' ? 'config (64 B)' : 'protected counter', 'svg-label small center');
      st.dataT2 = S.text(svg, 590, 150, '0', 'svg-label mono center bold');
      st.flash = S.text(svg, 380, 270, '', 'svg-label small center');
    }

    function reset() {
      st = { t: 0, core: [], holder: -1, ticketNext: 0, serving: 0, transfers: 0, counter: 0,
        queue: [], sn: 0, writing: false, flashT: 0 };
      for (var i = 0; i < NCORE; i++)
        st.core.push({ state: 'think', timer: 0.2 + 0.35 * i, ticket: -1, acq: 0, reads: 0, retries: 0, begin: 0 });
      if (kind === 'seq') { st.core[0].timer = 0.6; }
      layout();
      render();
    }

    function acquireIfFree() {
      if (st.holder >= 0) return;
      var waiting = [];
      st.core.forEach(function (c, i) { if (c.state === 'wait') waiting.push(i); });
      if (!waiting.length) return;
      var win;
      if (kind === 'spin') {
        win = waiting[Math.floor(Math.random() * waiting.length)];
        st.transfers += waiting.length;           /* everyone races for the line */
      } else if (kind === 'ticket') {
        win = waiting.filter(function (i) { return st.core[i].ticket === st.serving; })[0];
        if (win == null) return;
        st.transfers += waiting.length;           /* all re-read now_serving */
      } else {                                     /* mcs: head of queue */
        win = st.queue[0];
        if (win == null) return;
        st.transfers += 1;                        /* only the successor's flag line */
      }
      st.holder = win;
      st.core[win].state = 'cs';
      st.core[win].timer = CS;
    }

    function step(dt) {
      st.t += dt;
      st.flashT = Math.max(0, st.flashT - dt);
      if (kind === 'seq') return stepSeq(dt);
      st.core.forEach(function (c, i) {
        c.timer -= dt;
        if (c.state === 'think' && c.timer <= 0) {
          c.state = 'wait';
          if (kind === 'ticket') c.ticket = st.ticketNext++;
          if (kind === 'mcs') st.queue.push(i);
        } else if (c.state === 'cs' && c.timer <= 0) {
          st.counter++; c.acq++;
          c.state = 'think'; c.timer = 0.15 + Math.random() * 0.45;
          st.holder = -1;
          if (kind === 'ticket') { st.serving++; c.ticket = -1; }
          if (kind === 'mcs') st.queue.shift();
        }
      });
      acquireIfFree();
    }

    function stepSeq(dt) {
      var w = st.core[0];
      w.timer -= dt;
      if (!st.writing && w.timer <= 0) { st.writing = true; st.sn++; w.timer = 0.7; w.state = 'cs'; }
      else if (st.writing && w.timer <= 0) { st.writing = false; st.sn++; st.counter++; w.acq++; w.timer = 1.1 + Math.random() * 0.6; w.state = 'think'; }
      for (var i = 1; i < NCORE; i++) {
        var r = st.core[i];
        r.timer -= dt;
        if (r.state === 'think' && r.timer <= 0) {
          if (st.sn & 1) { r.state = 'spinodd'; }
          else { r.state = 'read'; r.begin = st.sn; r.timer = 0.45; }
        } else if (r.state === 'spinodd') {
          if (!(st.sn & 1)) { r.state = 'read'; r.begin = st.sn; r.timer = 0.45; }
        } else if (r.state === 'read' && r.timer <= 0) {
          if (st.sn !== r.begin) { r.retries++; r.state = 'think'; r.timer = 0.05; r.flash = 0.5; st.flashT = 0.6; }
          else { r.reads++; r.state = 'think'; r.timer = 0.15 + Math.random() * 0.3; }
        }
        r.flash = Math.max(0, (r.flash || 0) - dt);
      }
    }

    function render() {
      S.clear(st.wires); S.clear(st.nodes);
      var col = { think: 'c7', wait: 'c4', cs: 'c2', read: 'c1', spinodd: 'c4' };
      st.core.forEach(function (c, i) {
        var el = st.coreEl[i];
        el.circ.setAttribute('class', 'svg-box ' + (col[c.state] || 'c1'));
        if (kind === 'seq') {
          el.s1.textContent = i === 0 ? (c.state === 'cs' ? 'writer: writing (sn odd)' : 'writer: idle')
            : (c.state === 'read' ? 'reader: copying (begin sn=' + c.begin + ')' : c.state === 'spinodd' ? 'reader: sn odd, waits' : (c.flash > 0 ? 'reader: sn changed, RETRY' : 'reader: between reads'));
          el.s2.textContent = i === 0 ? 'writes ' + c.acq : 'ok ' + c.reads + '  retries ' + c.retries;
          if (i > 0 && (c.state === 'read' || c.state === 'spinodd'))
            S.path(st.wires, 'M88,' + cy[i] + ' L288,140', 'svg-arrow c1 dashed flow');
          if (i === 0 && c.state === 'cs')
            S.path(st.wires, 'M88,' + cy[i] + ' Q 400,30 518,140', 'svg-arrow c2');
          return;
        }
        el.s1.textContent = { think: 'outside', wait: 'waiting (spinning)', cs: 'HOLDS the lock' }[c.state];
        el.s2.textContent = 'acquired ' + c.acq + (kind === 'ticket' && c.ticket >= 0 ? '  ticket ' + c.ticket : '');
        if (c.state === 'wait') {
          if (kind === 'mcs') {
            S.path(st.wires, 'M88,' + (cy[i] + 18) + ' L' + 198 + ',' + (cy[i] + 18), 'svg-arrow c3 dashed flow');
          } else {
            S.path(st.wires, 'M88,' + cy[i] + ' L288,140', 'svg-arrow c4 dashed flow');
          }
        }
        if (c.state === 'cs') S.path(st.wires, 'M88,' + cy[i] + ' Q 400,' + (cy[i] < 140 ? 30 : 250) + ' 518,140', 'svg-arrow c2');
      });
      if (kind === 'mcs') {   /* queue nodes (holder first) and links */
        st.queue.forEach(function (ci) {
          var held = st.core[ci].state === 'cs';
          S.rect(st.nodes, 200, cy[ci] + 6, 62, 24, 'svg-box ' + (held ? 'c2' : 'c3'), { rx: 4 });
          S.text(st.nodes, 231, cy[ci] + 18, held ? 'holder' : 'locked=1', 'svg-label small center');
        });
        for (var q = 0; q + 1 < st.queue.length; q++) {
          var a = st.queue[q], b = st.queue[q + 1];
          S.path(st.nodes, 'M262,' + (cy[a] + 18) + ' C 285,' + (cy[a] + 18) + ' 285,' + (cy[b] + 18) + ' 264,' + (cy[b] + 18), 'svg-arrow c5');
        }
      }
      var title = { spin: 'rte_spinlock_t', ticket: 'rte_ticketlock_t', mcs: 'rte_mcslock_t * (tail)', seq: 'rte_seqlock_t' }[kind];
      st.lockT1.textContent = title;
      if (kind === 'spin') { st.lockT2.textContent = 'locked = ' + (st.holder >= 0 ? 1 : 0); st.lockT3.textContent = 'one line, polled by all'; }
      else if (kind === 'ticket') { st.lockT2.textContent = 'next=' + st.ticketNext + ' serving=' + st.serving; st.lockT3.textContent = 'FIFO, one shared line'; }
      else if (kind === 'mcs') { st.lockT2.textContent = 'tail = ' + (st.queue.length ? 'C' + (st.queue[st.queue.length - 1] + 1) : 'NULL'); st.lockT3.textContent = 'waiters spin on own node'; }
      else { st.lockT2.textContent = 'sn = ' + st.sn + (st.sn & 1 ? ' (odd)' : ' (even)'); st.lockT3.textContent = 'readers never block the writer'; }
      st.dataT1.textContent = kind === 'seq' ? 'config version' : 'protected counter';
      st.dataT2.textContent = String(st.counter);
      if (kind === 'seq') {
        var ok = 0, rt = 0; st.core.forEach(function (c, i) { if (i) { ok += c.reads; rt += c.retries; } });
        stats.innerHTML = 'Writer updates: <strong>' + st.counter + '</strong> &middot; reader copies kept: <strong>' + ok +
          '</strong> &middot; retries: <strong>' + rt + '</strong>. Measured by seqlock_cfg.c (2 readers, 1 kHz writer, 0.5 s): 38,876 retries in 379 million reads, 0 torn copies.';
      } else {
        var acq = st.core.map(function (c) { return c.acq; });
        var tot = acq.reduce(function (a, b) { return a + b; }, 0) || 1;
        stats.innerHTML = 'Acquisitions C1/C2/C3: <strong>' + acq.join(' / ') + '</strong> (' +
          acq.map(function (a) { return Math.round(100 * a / tot) + '%'; }).join(' / ') + ') &middot; lock-line transfers caused by waiters: <strong>' +
          st.transfers + '</strong>' + (kind === 'spin' ? ' (winner is random: unfair)' : kind === 'ticket' ? ' (strict FIFO, but every waiter re-reads the line)' : ' (one hand-off write per acquisition)');
      }
    }

    st = { core: [] };
    var anim = new CJ.Animator({
      root: root, autoplay: 'visible', speed: 1,
      onReset: function () { reset(); },
      onFrame: function (dt) { if (dt > 0) step(dt); render(); }
    });
    segButtons(root, 'data-lock', function (v) { kind = v; anim.reset(); })('spin');
  }

  /* =====================================================================
   * 3. RCU grace-period timeline (interactive: drag)
   * ===================================================================== */
  function rcuTimeline() {
    var root = document.getElementById('w-rcu');
    if (!root) return;
    var svg = root.querySelector('svg');
    var out = root.querySelector('.w-out');
    var X0 = 96, X1 = 664, T = 100;
    function tx(t) { return X0 + (X1 - X0) * t / T; }
    function xt(x) { return (x - X0) * T / (X1 - X0); }
    var lanesY = [56, 104, 152];
    var readers, t0, broken;

    function init() {
      readers = [
        { name: 'reader lcore 1', blocks: [7, 6, 8, 7, 6, 7, 8, 6, 7, 7, 8, 6, 7, 6, 8], offline: false },
        { name: 'reader lcore 2', blocks: [5, 6, 5, 6, 5, 6, 5, 6, 5, 6, 5, 6, 5, 6, 5, 6, 5, 6, 5, 6], offline: false },
        { name: 'reader lcore 3', blocks: [6, 7, 34, 6, 7, 6, 7, 6, 7, 6], offline: false }
      ];
      t0 = 30; broken = false;
      var cb = root.querySelectorAll('input[type=checkbox]');
      cb.forEach(function (c) { c.checked = false; });
    }

    function sections(r) {
      var out = [], t = 0;
      r.blocks.forEach(function (len, i) { out.push({ s: t, e: t + len, i: i }); t += len; });
      return out;
    }

    function compute() {
      var res = { tfree: t0, last: -1 };
      readers.forEach(function (r, ri) {
        if (r.offline) return;
        var secs = sections(r);
        /* first quiescent state (end of an iteration) at or after t0 */
        var q = secs.filter(function (s) { return s.e >= t0; })[0];
        var tq = q ? q.e : T;
        if (tq > res.tfree) { res.tfree = tq; res.last = ri; }
      });
      if (broken) res.tfree = t0;
      return res;
    }

    var drag = null;
    function draw() {
      S.clear(svg);
      var res = compute();
      /* axis */
      S.line(svg, X0, 196, X1, 196, 'svg-line');
      for (var t = 0; t <= T; t += 10) {
        S.line(svg, tx(t), 196, tx(t), 201, 'svg-line');
        S.text(svg, tx(t), 213, String(t), 'svg-label small center muted');
      }
      S.text(svg, X1, 230, 'time (arbitrary units)', 'svg-label small muted', { 'text-anchor': 'end' });
      /* grace period band */
      if (!broken && res.tfree > t0)
        S.rect(svg, tx(t0), 32, tx(res.tfree) - tx(t0), 150, 'svg-box c5', { rx: 0, style: 'opacity:.35' });
      readers.forEach(function (r, ri) {
        var y = lanesY[ri];
        S.text(svg, 8, y + 4, r.name, 'svg-label small' + (r.offline ? ' muted' : ''));
        var g = S.group(svg, null, r.offline ? { style: 'opacity:.3' } : null);
        sections(r).forEach(function (s) {
          if (s.s >= T) return;
          var e = Math.min(s.e, T);
          var holdsOld = s.s < t0 && s.e > t0;
          var cls = 'c1';
          if (!r.offline && holdsOld) cls = broken ? 'c4' : 'c3';
          var rect = S.rect(g, tx(s.s) + 1, y - 12, Math.max(2, tx(e) - tx(s.s) - 2), 24, 'svg-box ' + cls, { rx: 3 });
          rect.style.cursor = 'ew-resize';
          rect.addEventListener('pointerdown', function (ev) { start(ev, { kind: 'block', r: ri, i: s.i, s: s.s }); });
          if (s.e <= T) S.line(g, tx(s.e), y - 16, tx(s.e), y + 16, 'svg-line', { style: 'stroke:var(--c2);stroke-width:2.5' });
          if (s.e - s.s >= 20) S.text(g, (tx(s.s) + tx(e)) / 2, y + 1, 'long critical section: drag me', 'svg-label small center');
        });
      });
      /* writer */
      var wl = S.line(svg, tx(t0), 26, tx(t0), 190, 'svg-line', { style: 'stroke:var(--c4);stroke-width:3;cursor:ew-resize' });
      S.text(svg, tx(t0) + 4, 22, 'swap at t=' + t0.toFixed(0) + (broken ? ', free at once' : ''), 'svg-label small bold');
      var handle = S.el('circle', { cx: tx(t0), cy: 26, r: 7, 'class': 'svg-fill-c4', style: 'cursor:ew-resize' }, svg);
      [wl, handle].forEach(function (el) { el.addEventListener('pointerdown', function (ev) { start(ev, { kind: 'writer' }); }); });
      if (!broken) {
        S.line(svg, tx(res.tfree), 26, tx(res.tfree), 190, 'svg-line', { style: 'stroke:var(--c2);stroke-width:3;stroke-dasharray:5 3' });
        S.text(svg, Math.min(tx(res.tfree) + 4, X1 - 90), 190, 'free(old)', 'svg-label small bold');
      }
      /* readout */
      var bad = 0;
      readers.forEach(function (r) { if (!r.offline) sections(r).forEach(function (s) { if (s.s < t0 && s.e > t0) bad++; }); });
      if (broken) {
        out.innerHTML = '<strong style="color:var(--pitfall)">Freed at the swap.</strong> ' + bad +
          ' critical section(s) (red) started before the swap and are still reading the old config: each one is a use-after-free. rcu_swap.c "broken" mode caught 4 of them in 9 ms.';
      } else {
        out.innerHTML = 'Grace period: <strong>' + (res.tfree - t0).toFixed(0) + '</strong> units, set by <strong>' +
          (res.last >= 0 ? readers[res.last].name : 'nobody (no online reader)') + '</strong>. Orange sections may hold the old pointer; the old config is freed at the green dashed line, after each online reader has passed a quiescent state (green tick). ' +
          'Measured by rcu_swap.c: median 0.66 &micro;s with 3 normal readers, 49.45 &micro;s when one reader holds its config for 50 &micro;s.';
      }
    }

    function svgX(ev) {
      var pt = svg.createSVGPoint(); pt.x = ev.clientX; pt.y = ev.clientY;
      return pt.matrixTransform(svg.getScreenCTM().inverse()).x;
    }
    function start(ev, what) {
      ev.preventDefault();
      drag = what;
      svg.setPointerCapture && svg.setPointerCapture(ev.pointerId);
    }
    svg.addEventListener('pointermove', function (ev) {
      if (!drag) return;
      var t = CJ.clamp(xt(svgX(ev)), 0, T);
      if (drag.kind === 'writer') t0 = Math.round(CJ.clamp(t, 1, T - 1));
      else {
        var r = readers[drag.r];
        r.blocks[drag.i] = Math.round(CJ.clamp(t - drag.s, 2, 70));
      }
      draw();
    });
    function end() { drag = null; }
    svg.addEventListener('pointerup', end);
    svg.addEventListener('pointercancel', end);
    /* keyboard: arrows move the writer */
    root.addEventListener('keydown', function (e) {
      if (e.target.closest('input')) return;
      if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
        e.preventDefault(); t0 = CJ.clamp(t0 + (e.key === 'ArrowLeft' ? -1 : 1), 1, T - 1); draw();
      }
    });
    if (!root.hasAttribute('tabindex')) root.tabIndex = 0;

    init();
    root.querySelector('[data-rcu="off3"]').addEventListener('change', function (e) { readers[2].offline = e.target.checked; draw(); });
    root.querySelector('[data-rcu="off1"]').addEventListener('change', function (e) { readers[0].offline = e.target.checked; draw(); });
    root.querySelector('[data-rcu="broken"]').addEventListener('change', function (e) { broken = e.target.checked; draw(); });
    root.querySelector('[data-rcu="reset"]').addEventListener('click', function () { init(); draw(); });
    draw();
  }

  /* =====================================================================
   * 4. MESI ping-pong (animation)
   * ===================================================================== */
  function mesi() {
    var root = document.getElementById('w-mesi');
    if (!root) return;
    var svg = root.querySelector('svg');
    var out = root.querySelector('.w-out');
    var bars = root.querySelector('.bars');
    var layoutMode = 'packed', inc = 'fa';
    var st;

    function reset() {
      st = { t: 0, next: 0.5, who: 0, owner: [ -1, -1 ], state: [['I', 'I'], ['I', 'I']], cnt: [0, 0],
        transfers: 0, moving: null, sb: [[], []] };
      draw();
    }
    /* line index used by core c: packed -> both use line 0; padded -> core c uses line c */
    function lineOf(c) { return layoutMode === 'packed' ? 0 : c; }

    function doWrite(c) {
      var L = lineOf(c), other = 1 - c;
      if (inc === 'ls') {           /* plain store goes to the store buffer first */
        st.sb[c].push(1);
        st.cnt[c]++;
        if (st.sb[c].length >= 4) commit(c, L, other);
        return;
      }
      st.cnt[c]++;
      commit(c, L, other);
    }
    function commit(c, L, other) {
      if (st.state[c][L] !== 'M') {
        if (st.state[other][L] === 'M' || st.state[other][L] === 'S') {
          st.transfers++;
          st.moving = { from: other, to: c, p: 0, L: L };
          st.state[other][L] = 'I';
        }
        st.state[c][L] = 'M';
      }
      st.sb[c] = [];
    }

    function step(dt) {
      st.t += dt;
      if (st.moving) { st.moving.p += dt / 0.35; if (st.moving.p >= 1) st.moving = null; }
      st.next -= dt;
      if (st.next <= 0) {
        doWrite(st.who);
        st.who = 1 - st.who;
        st.next = inc === 'ls' ? 0.22 : 0.55;
      }
    }

    function cacheLines(g, x, c) {
      var n = layoutMode === 'packed' ? 1 : 2;
      for (var L = 0; L < n; L++) {
        var y = 92 + L * 46;
        var s = st.state[c][L];
        var cls = s === 'M' ? 'c2' : s === 'S' ? 'c1' : 'c7';
        S.rect(g, x, y, 200, 36, 'svg-box ' + cls, { rx: 4 });
        S.text(g, x + 18, y + 19, s, 'svg-label center bold');
        if (s === 'I') {
          S.text(g, x + 100, y + 19, '(invalid: must fetch)', 'svg-label small center muted');
        } else if (layoutMode === 'packed') {
          S.text(g, x + 100, y + 19, 'A=' + st.cnt[0] + ' | B=' + st.cnt[1] + ' | ...', 'svg-label small mono center');
        } else {
          S.text(g, x + 100, y + 19, (L === 0 ? 'A=' + st.cnt[0] : 'B=' + st.cnt[1]) + ' | guard', 'svg-label small mono center');
        }
      }
    }

    function draw() {
      S.clear(svg);
      for (var c = 0; c < 2; c++) {
        var x = c === 0 ? 20 : 440;
        S.rect(svg, x - 6, 18, 232, 190, 'svg-box c1');
        S.text(svg, x + 4, 40, 'core ' + c + ' increments ' + (c === 0 ? 'A' : 'B'), 'svg-label bold');
        S.text(svg, x + 4, 60, 'L1: line state M / S / I', 'svg-label small muted');
        S.text(svg, x + 4, 78, layoutMode === 'packed' ? 'one line holds A and B' : 'A and B on separate lines', 'svg-label small muted');
        cacheLines(svg, x + 10, c);
        if (inc === 'ls') {
          S.text(svg, x + 10, 196, 'store buffer: ' + (st.sb[c].length ? st.sb[c].map(function () { return '+1'; }).join(' ') : '(empty)'), 'svg-label small mono');
        }
        if (st.who === c) S.el('circle', { cx: x + 214, cy: 34, r: 6, 'class': 'svg-fill-c3' }, svg);
      }
      S.rect(svg, 260, 120, 160, 40, 'svg-box c7');
      S.text(svg, 340, 140, 'interconnect', 'svg-label small center');
      S.path(svg, 'M232,140 L258,140', 'svg-line');
      S.path(svg, 'M422,140 L448,140', 'svg-line');
      if (st.moving) {
        var p = CJ.ease.inOut(Math.min(st.moving.p, 1));
        var xa = st.moving.from === 0 ? 230 : 450, xb = st.moving.to === 0 ? 230 : 450;
        var pk = S.packet(svg, CJ.lerp(xa, xb, p), 140, 44, 18, 'c4', 'line');
        void pk;
      }
      S.text(svg, 340, 236, 'line transfers so far: ' + st.transfers + '   (increments: ' + (st.cnt[0] + st.cnt[1]) + ')', 'svg-label small center bold');
      var key = (layoutMode === 'packed' ? 'packed' : 'padded') + '-' + inc;
      var m = MEASURED.counters.filter(function (r) { return r.id === key; })[0];
      out.innerHTML = 'Measured by counters.c on this VM (3 workers, median of 5): <strong>' + m.label + ' = ' + m.v +
        ' cycles/increment</strong>. ' + (inc === 'fa'
          ? (layoutMode === 'packed' ? 'Every locked add needs the line in M, so it ping-pongs.' : 'Each core keeps its own line in M: no traffic.')
          : 'Here plain stores were as cheap in the packed layout as in the padded one: the store buffer absorbs repeated stores to one address (the likely reason; the measurement only shows that it is cheap on this CPU). Locked RMWs cannot hide this way.');
      bars.querySelectorAll('.bar-row').forEach(function (r) { r.classList.toggle('sel', r.getAttribute('data-id') === key); });
    }

    /* measured bars, log scale */
    var max = Math.log10(300), min = Math.log10(0.5);
    bars.innerHTML = MEASURED.counters.map(function (r) {
      var w = 100 * (Math.log10(r.v) - min) / (max - min);
      return '<div class="bar-row" data-id="' + r.id + '"><span class="bar-lbl">' + r.label + '</span><span class="bar-track"><span class="bar-fill" style="width:' +
        w.toFixed(1) + '%"></span></span><span class="bar-val">' + r.v + '</span></div>';
    }).join('') + '<div class="bar-note">cycles per increment, log scale, from code/expected_output.txt</div>';

    var anim = new CJ.Animator({
      root: root, autoplay: 'visible',
      onReset: function () { reset(); },
      onFrame: function (dt) { if (dt > 0) step(dt); draw(); }
    });
    segButtons(root, 'data-layout', function (v) { layoutMode = v; anim.reset(); })('packed');
    segButtons(root, 'data-inc', function (v) { inc = v; anim.reset(); })('fa');
  }

  /* =====================================================================
   * 5. Per-lcore data layouts (click an lcore)
   * ===================================================================== */
  function layouts() {
    var root = document.getElementById('w-layout');
    if (!root) return;
    var svg = root.querySelector('svg');
    var out = root.querySelector('.w-out');
    var sel = 3, reader = false;
    var N = 8;

    function draw() {
      S.clear(svg);
      var rows = [
        { y: 30, name: 'packed uint64_t c[RTE_MAX_LCORE]' },
        { y: 110, name: 'padded: 1 line + RTE_CACHE_GUARD per lcore' },
        { y: 190, name: 'lcore variable (RTE_MAX_LCORE_VAR = 128 KiB apart)' }
      ];
      rows.forEach(function (r) { S.text(svg, 10, r.y, r.name, 'svg-label small bold'); });
      /* packed: one 64-byte line, 8 slots */
      S.rect(svg, 10, 40, 400, 40, 'svg-box c7', { rx: 2 });
      S.text(svg, 418, 64, '1 cache line (64 B)', 'svg-label small muted');
      for (var i = 0; i < N; i++) {
        var cls = reader ? 'c1' : (i === sel ? 'c3' : 'c4');
        S.rect(svg, 12 + i * 49.5, 42, 47, 36, 'svg-box ' + cls, { rx: 2, style: (reader || i === sel) ? '' : 'opacity:.75' });
        S.text(svg, 35 + i * 49.5, 60, 'lc' + i, 'svg-label small center mono');
      }
      /* padded: 8 x (line + guard) */
      for (i = 0; i < N; i++) {
        var x = 10 + i * 82;
        var c2 = reader ? 'c1' : (i === sel ? 'c3' : 'c7');
        S.rect(svg, x, 120, 38, 40, 'svg-box ' + c2, { rx: 2 });
        S.text(svg, x + 19, 140, 'lc' + i, 'svg-label small center mono');
        S.rect(svg, x + 40, 120, 38, 40, 'svg-box ghost', { rx: 2 });
        S.text(svg, x + 59, 140, 'guard', 'svg-label small center muted');
      }
      /* lcore var: 8 slices; inside each, several modules' variables */
      for (i = 0; i < N; i++) {
        var x2 = 10 + i * 82;
        S.rect(svg, x2, 200, 78, 56, 'svg-box ' + (i === sel && !reader ? 'c2' : 'c7'), { rx: 3, style: i === sel || reader ? '' : 'opacity:.6' });
        S.rect(svg, x2 + 4, 204, 22, 18, 'svg-box ' + (reader || i === sel ? 'c3' : 'c7'), { rx: 2 });
        S.text(svg, x2 + 15, 213, 'ctr', 'svg-label small center', { style: 'font-size:9px' });
        S.rect(svg, x2 + 28, 204, 22, 18, 'svg-box c5', { rx: 2 });
        S.text(svg, x2 + 39, 213, 'A', 'svg-label small center mono');
        S.rect(svg, x2 + 52, 204, 22, 18, 'svg-box c6', { rx: 2 });
        S.text(svg, x2 + 63, 213, 'B', 'svg-label small center mono');
        S.text(svg, x2 + 39, 242, 'lcore ' + i, 'svg-label small center');
      }
      S.text(svg, 10, 278, 'ctr = this counter; A, B = other modules\' lcore variables, packed next to it in the same per-lcore slice', 'svg-label small muted');
      if (reader) {
        out.innerHTML = 'The <strong>stats reader</strong> sums all 8 counters: packed touches <strong>1</strong> line, padded touches <strong>8</strong> lines (plus guards it skips), the lcore variable touches <strong>8</strong> slices that are 128 KiB apart. Reads are rare, so the cheap writes win.';
      } else {
        var others = [];
        for (i = 0; i < N; i++) if (i !== sel) others.push(i);
        out.innerHTML = 'lcore ' + sel + ' writes its counter. <strong>Packed:</strong> the line it writes also holds lcores ' + others.join(', ') +
          ': their cached copies become Invalid (red) and the next write on any of them pulls the line back. <strong>Padded:</strong> only line ' + sel +
          ' changes; the guard line keeps the adjacent-line prefetcher away. <strong>Lcore variable:</strong> only lcore ' + sel +
          '\'s slice changes, and that slice also holds lcore ' + sel + '\'s other variables (A, B), so its own working set stays together.';
      }
    }
    var btnRow = root.querySelector('.lc-btns');
    for (var i = 0; i < N; i++) {
      (function (k) {
        var b = document.createElement('button');
        b.type = 'button'; b.className = 'btn small'; b.textContent = 'lcore ' + k;
        b.setAttribute('data-lc', String(k));
        b.addEventListener('click', function () { sel = k; reader = false; mark(); draw(); });
        btnRow.appendChild(b);
      })(i);
    }
    var rb = document.createElement('button');
    rb.type = 'button'; rb.className = 'btn small'; rb.textContent = 'stats reader sums all';
    rb.setAttribute('data-lc', 'r');
    rb.addEventListener('click', function () { reader = true; mark(); draw(); });
    btnRow.appendChild(rb);
    function mark() {
      CJ.$$('[data-lc]', btnRow).forEach(function (b) {
        var on = reader ? b.getAttribute('data-lc') === 'r' : b.getAttribute('data-lc') === String(sel);
        b.setAttribute('aria-pressed', on ? 'true' : 'false');
      });
    }
    mark(); draw();
  }

  CJ.ready(function () {
    orderingPlayground();
    lockZoo();
    rcuTimeline();
    mesi();
    layouts();
    if (window.Ch06ABA) window.Ch06ABA.mount('#w-aba');
  });
})();

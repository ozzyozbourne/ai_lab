/* Chapter 11 widgets: evolving app, timer skiplist, service matrix,
 * keepalive watchdog, cmdline token matcher. Vanilla JS + course.js. */
CourseJS.ready(function () {
  'use strict';
  var S = CourseJS.svg;
  function $(id) { return document.getElementById(id); }
  function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }

  /* ================================================================
   * 1. The evolving app: architecture after each step
   * ================================================================ */
  (function () {
    var root = $('w-evo');
    if (!root) return;
    var svg = root.querySelector('svg');
    var cap = $('evo-cap');
    var lanes = [
      { id: 'l0', name: 'lcore 0 (main)', cls: 'c1' },
      { id: 'l1', name: 'lcore 1 (worker)', cls: 'c1' },
      { id: 'l2', name: 'lcore 2 (service)', cls: 'c5' },
      { id: 'intr', name: 'dpdk-intr thread', cls: 'c6' }
    ];
    /* chips: [lane, text, isNew, colour] */
    var steps = [
      { t: 'Step 1: one lcore does everything. The poll loop calls <code>rte_timer_manage()</code> every 100 us; the 1 s stats timer and the one-shot stop timer run <em>inside</em> it, between bursts.',
        chips: [['l0', 'poll loop: rx/rewrite/tx', 0, 'c3'], ['l0', 'rte_timer_manage()', 1, 'c2'], ['l0', 'stats timer 1 s', 1, 'c2'], ['l0', 'stop timer (SINGLE)', 1, 'c2'],
                ['intr', 'EAL: alarms, interrupts', 0, 'c6']] },
      { t: 'Step 2: the stats printing becomes a <em>service</em>. Lcore 2 is a service lcore (<code>-S 2</code>, also in <code>-l</code>); its runner calls <code>ch11_stats</code> in a tight loop. The forwarding lcore no longer prints.',
        chips: [['l0', 'poll loop', 0, 'c3'], ['l0', 'stop timer', 0, 'c2'], ['l2', 'service runner', 1, 'c5'], ['l2', 'ch11_stats service', 1, 'c5'],
                ['intr', 'EAL: alarms, interrupts', 0, 'c6']] },
      { t: 'Step 3: forwarding moves to worker lcore 1, which marks itself alive every pass. The main lcore turns into a control lcore: a 250 ms ping timer runs the keepalive state machine and the failure callback.',
        chips: [['l0', 'rte_timer_manage() + 1 ms sleep', 0, 'c2'], ['l0', 'keepalive ping 250 ms', 1, 'c4'], ['l0', 'failure callback', 1, 'c4'],
                ['l1', 'poll loop', 0, 'c3'], ['l1', 'mark_alive()', 1, 'c4'], ['l2', 'ch11_stats service', 0, 'c5'],
                ['intr', 'EAL: alarms, interrupts', 0, 'c6']] },
      { t: 'Step 4: the main lcore blocks in <code>cmdline_interact()</code>, so the timers move to the service lcore. A <code>ch11_housekeeping</code> service calls <code>rte_timer_manage()</code> there; the shell reads and writes shared counters and the burst size.',
        chips: [['l0', 'cmdline shell (stdin)', 1, 'c7'], ['l1', 'poll loop (burst from shell)', 0, 'c3'], ['l1', 'mark_alive()', 0, 'c4'],
                ['l2', 'housekeeping service', 1, 'c5'], ['l2', 'ping timer', 0, 'c4'], ['l2', '1 s snapshot timer', 1, 'c2'],
                ['intr', 'EAL: alarms, interrupts', 0, 'c6']] },
      { t: 'Step 5: before anything is launched, <code>rte_argparse</code> parses the options after <code>--</code> and <code>rte_cfgfile</code> reads <code>app.ini</code>. Defaults &lt; file &lt; command line. The shell is optional (<code>--shell</code>).',
        chips: [['l0', 'argparse + cfgfile (startup)', 1, 'c7'], ['l0', 'shell or wait', 0, 'c7'], ['l1', 'poll loop', 0, 'c3'], ['l1', 'mark_alive()', 0, 'c4'],
                ['l2', 'housekeeping service', 0, 'c5'], ['l2', 'timers', 0, 'c2'], ['intr', 'EAL: alarms, interrupts', 0, 'c6']] }
    ];
    var g = S.group(svg);
    function draw(k) {
      S.clear(g);
      var st = steps[k];
      lanes.forEach(function (ln, i) {
        var y = 14 + i * 58;
        var used = st.chips.some(function (c) { return c[0] === ln.id && ln.id !== 'intr'; }) || ln.id === 'intr';
        S.rect(g, 8, y, 150, 44, 'svg-box ' + (used ? ln.cls : 'ghost'));
        S.text(g, 83, y + 22, ln.name, 'svg-label center small bold');
        var x = 170;
        st.chips.filter(function (c) { return c[0] === ln.id; }).forEach(function (c) {
          var w = Math.max(90, c[1].length * 6.1 + 16);
          S.rect(g, x, y + 4, w, 36, 'svg-box ' + c[3] + (c[2] ? ' svg-highlight' : ''));
          S.text(g, x + w / 2, y + 22, c[1], 'svg-label center small' + (c[2] ? ' bold' : ''));
          if (c[2]) S.text(g, x + w - 4, y + 2, 'NEW', 'svg-label small bold', { 'text-anchor': 'end', style: 'fill:var(--accent)' });
          x += w + 8;
        });
        if (!used) S.text(g, 180, y + 22, '(not used yet)', 'svg-label small muted', { 'dominant-baseline': 'middle' });
      });
      cap.innerHTML = st.t;
      CourseJS.$$('.evo-btn', root).forEach(function (b, i) { b.classList.toggle('primary', i === k); b.setAttribute('aria-pressed', i === k); });
    }
    CourseJS.$$('.evo-btn', root).forEach(function (b, i) { b.addEventListener('click', function () { draw(i); }); });
    draw(0);
  })();

  /* ================================================================
   * 2. Timer skiplist: per-lcore sorted lists, manage, periodic, move
   * ================================================================ */
  (function () {
    var root = $('w-skip');
    if (!root) return;
    var svg = root.querySelector('svg');
    var g = S.group(svg);
    var LV = 3;                       /* levels drawn: 0..2 */
    function T(name, exp, lvl, type, period) { return { n: name, exp: exp, lvl: lvl, type: type, period: period || 0 }; }
    function insert(list, t) { list.push(t); list.sort(function (a, b) { return a.exp - b.exp; }); }
    function remove(list, name) { for (var i = 0; i < list.length; i++) if (list[i].n === name) return list.splice(i, 1)[0]; return null; }
    function draw(ctx) {
      var d = ctx.data;
      S.clear(g);
      S.text(g, 630, 14, 'now = ' + d.now, 'svg-label bold', { 'text-anchor': 'end' });
      [0, 1].forEach(function (lc) {
        var list = d.lists[lc];
        var base = 80 + lc * 120;               /* y of level 0 */
        S.text(g, 8, base - 64, 'lcore ' + lc + ' pending list', 'svg-label small bold');
        /* head tower */
        var hx = 20;
        for (var L = 0; L < LV; L++) {
          var r = S.rect(g, hx, base - L * 18 - 7, 30, 14, 'svg-slot', { rx: 2 });
          if (d.headHl === lc && L === 0) r.setAttribute('class', 'svg-slot svg-highlight');
        }
        S.text(g, hx + 15, base + 20, 'head', 'svg-label small center muted');
        var xs = list.map(function (t, i) { return 90 + i * 100; });
        /* links per level */
        for (L = 0; L < LV; L++) {
          var prevx = hx + 30;
          var y = base - L * 18;
          list.forEach(function (t, i) {
            if (t.lvl >= L) {
              S.arrow(g, prevx, y, xs[i] - 2, y, 'c7');
              prevx = xs[i] + 40;
            }
          });
          S.text(g, prevx + 4, y + 1, 'NULL', 'svg-label small muted', { 'dominant-baseline': 'middle', style: 'font-size:9px' });
        }
        list.forEach(function (t, i) {
          var cls = d.hl[t.n] || (t.type === 'P' ? 'c5' : 'c2');
          for (var L = 0; L <= t.lvl; L++) S.rect(g, xs[i], base - L * 18 - 7, 40, 14, 'svg-box ' + cls, { rx: 2 });
          S.text(g, xs[i] + 20, base + 20, t.n + ' @' + t.exp, 'svg-label small center bold');
          S.text(g, xs[i] + 20, base + 34, t.type === 'P' ? 'PERIODICAL +' + t.period : 'SINGLE', 'svg-label small center muted', { style: 'font-size:9px' });
        });
        if (!list.length) S.text(g, 90, base, '(empty)', 'svg-label small muted', { 'dominant-baseline': 'middle' });
      });
      var log = d.log.length ? 'last call: ' + d.log[d.log.length - 1] : '';
      S.text(g, 8, 282, log, 'svg-label small mono');
    }
    function reset(ctx) { ctx.data.lists = [[], []]; ctx.data.now = 0; ctx.data.hl = {}; ctx.data.log = []; ctx.data.headHl = -1; draw(ctx); }
    function clr(ctx) { ctx.data.hl = {}; ctx.data.headHl = -1; }
    function manage(ctx, lc) {
      var d = ctx.data, list = d.lists[lc], ran = [];
      while (list.length && list[0].exp <= d.now) {
        var t = list.shift();
        ran.push(t.n);
        if (t.type === 'P') { t.exp = t.exp + t.period; insert(list, t); d.hl[t.n] = 'c3'; }
      }
      d.log.push('manage(lcore ' + lc + '): ran ' + (ran.length ? ran.join(', ') : 'nothing'));
      if (!ran.length) d.headHl = lc;
    }
    new CourseJS.Stepper(root, {
      reset: reset,
      steps: [
        { caption: '<code>rte_timer_subsystem_init()</code>: every lcore gets its own empty pending list. The list is a <em>skiplist</em> sorted by expiry time; each timer has 1 to 10 levels of forward links (<code>sl_next[MAX_SKIPLIST_DEPTH]</code>), chosen at random when it is inserted.' },
        { caption: '<code>rte_timer_reset(&amp;A, 40, SINGLE, 0, cb, arg)</code>: A expires at now + 40 and is inserted into lcore 0\'s list.', run: function (ctx) { clr(ctx); insert(ctx.data.lists[0], T('A', 40, 0, 'S')); ctx.data.hl.A = 'c3'; ctx.data.log.push('reset A, expire 40'); draw(ctx); } },
        { caption: 'B is PERIODICAL with period 25, first expiry at 10. This one got 2 levels, so it is also linked from level 1.', run: function (ctx) { clr(ctx); insert(ctx.data.lists[0], T('B', 10, 1, 'P', 25)); ctx.data.hl.B = 'c3'; ctx.data.log.push('reset B, expire 10, period 25'); draw(ctx); } },
        { caption: 'C expires at 70 and drew 3 levels. Higher levels skip over many timers, so finding the insertion point costs about log(n) steps instead of n.', run: function (ctx) { clr(ctx); insert(ctx.data.lists[0], T('C', 70, 2, 'S')); ctx.data.hl.C = 'c3'; ctx.data.log.push('reset C, expire 70'); draw(ctx); } },
        { caption: 'D (expire 25, SINGLE) is placed between B and A. The search starts at the highest level of the head and drops a level whenever the next link would overshoot.',
          run: function (ctx) { clr(ctx); insert(ctx.data.lists[0], T('D', 25, 0, 'S')); ctx.data.hl.D = 'c3'; ctx.data.log.push('reset D, expire 25'); draw(ctx); },
          predict: { question: 'D expires at 25. Where does it go in lcore 0\'s list?', options: ['At the head, before B', 'Between B (10) and A (40)', 'At the end, after C'], answer: 1, explain: 'The list is sorted by <code>expire</code>: 10 &lt; 25 &lt; 40.' } },
        { caption: 'now = 5. The poll loop calls <code>rte_timer_manage()</code>: it compares the head\'s first expiry (10) with now and returns at once. This is why the call is cheap no matter how many timers are pending (about 42 cycles here for 10 or 100,000 timers, see exercise 3).',
          run: function (ctx) { clr(ctx); ctx.data.now = 5; manage(ctx, 0); draw(ctx); } },
        { caption: 'now = 30, manage again. Every timer with expire &lt;= now is unlinked and its callback runs: B then D. B is PERIODICAL, so it goes back in at <code>expire + period</code> = 10 + 25 = 35 (not now + 25: periodic timers do not drift). D is SINGLE and becomes STOPPED.',
          run: function (ctx) { clr(ctx); ctx.data.now = 30; manage(ctx, 0); draw(ctx); },
          predict: { question: 'now = 30. Which callbacks does this <code>rte_timer_manage()</code> run?', options: ['B only', 'B and D', 'B, D and A'], answer: 1, explain: 'B (10) and D (25) are due; A (40) is not.' } },
        { caption: '<code>rte_timer_reset(&amp;C, ..., tim_lcore = 1, ...)</code> from lcore 0: C is removed from lcore 0\'s list and inserted into lcore 1\'s list (under lcore 1\'s list lock). From now on only lcore 1\'s <code>rte_timer_manage()</code> can run C. Step 4 of the app uses exactly this to put timers on the service lcore.',
          run: function (ctx) { clr(ctx); var t = remove(ctx.data.lists[0], 'C'); t.exp = 70; insert(ctx.data.lists[1], t); ctx.data.hl.C = 'c3'; ctx.data.log.push('reset C on lcore 1'); draw(ctx); } },
        { caption: '<code>rte_timer_stop(&amp;A)</code>: A is unlinked and goes to STOPPED. Stopping or resetting a timer that is RUNNING on another lcore fails with -1 (use the <code>_sync</code> variants to spin until it succeeds).',
          run: function (ctx) { clr(ctx); remove(ctx.data.lists[0], 'A'); ctx.data.log.push('stop A'); draw(ctx); } },
        { caption: 'now = 40 on lcore 1: <code>rte_timer_manage()</code> there finds nothing due (C is at 70). Lcore 0 still owns B at 35. Each lcore only ever runs the timers in its own list.',
          run: function (ctx) { clr(ctx); ctx.data.now = 40; manage(ctx, 1); draw(ctx); } }
      ]
    });
  })();

  /* ================================================================
   * 3. Service mapping matrix
   * ================================================================ */
  (function () {
    var root = $('w-svc');
    if (!root) return;
    var svg = root.querySelector('svg');
    var tbody = $('svc-body');
    var msg = $('svc-msg');
    var LC = [2, 3];
    var svcs, lcores, gfx = S.group(svg);
    function init() {
      svcs = [
        { name: 'ch11_stats', mt: false, comp: true, app: true, map: [true, false] },
        { name: 'event_sw0_service', mt: false, comp: true, app: false, map: [true, false] },
        { name: 'mt_safe_demo', mt: true, comp: true, app: true, map: [false, true] }
      ];
      svcs.forEach(function (s) { s.calls = [0, 0]; s.busy = [0, 0]; s.lock = -1; s.lockT = 0; });
      lcores = LC.map(function () { return { started: true, cur: -1, t: 0, flash: '', inSvc: -1, hold: 0 }; });
    }
    function mappedCount(s) { return s.map.filter(Boolean).length; }
    function status(s) {
      if (!s.comp) return ['-ENOEXEC: component runstate is 0 (the driver is not ready)', 'warn'];
      if (!s.app) return ['-ENOEXEC: application runstate is 0 (rte_service_runstate_set(id, 1) not called)', 'warn'];
      var live = s.map.filter(function (m, i) { return m && lcores[i].started; }).length;
      if (!mappedCount(s)) return ['not mapped to any service lcore: never called', 'warn'];
      if (!live) return ['mapped only to stopped lcores: never called', 'warn'];
      if (live > 1 && !s.mt) return ['MT-unsafe on ' + live + ' lcores: serialized by a trylock, the loser skips (-EBUSY)', 'err'];
      if (live > 1) return ['MT-safe: runs on ' + live + ' lcores in parallel', 'ok'];
      return ['running', 'ok'];
    }
    function buildTable() {
      tbody.innerHTML = '';
      svcs.forEach(function (s, i) {
        var tr = document.createElement('tr');
        tr.innerHTML = '<td><code>' + s.name + '</code><br><span class="small muted">' + (s.mt ? 'MT_SAFE' : 'not MT-safe') + '</span></td>' +
          '<td class="c"><input type="checkbox" data-k="comp" data-i="' + i + '" aria-label="component runstate of ' + s.name + '"' + (s.comp ? ' checked' : '') + '></td>' +
          '<td class="c"><input type="checkbox" data-k="app" data-i="' + i + '" aria-label="application runstate of ' + s.name + '"' + (s.app ? ' checked' : '') + '></td>' +
          LC.map(function (l, j) { return '<td class="c"><input type="checkbox" data-k="map" data-j="' + j + '" data-i="' + i + '" aria-label="map ' + s.name + ' to lcore ' + l + '"' + (s.map[j] ? ' checked' : '') + '></td>'; }).join('') +
          '<td class="svc-st" id="svc-st-' + i + '"></td>' +
          '<td class="num nowrap" id="svc-calls-' + i + '">0</td>';
        tbody.appendChild(tr);
      });
      CourseJS.$$('input', tbody).forEach(function (cb) {
        cb.addEventListener('change', function () {
          var s = svcs[+cb.getAttribute('data-i')], k = cb.getAttribute('data-k');
          if (k === 'map') {
            var j = +cb.getAttribute('data-j');
            s.map[j] = cb.checked;
            say('rte_service_map_lcore_set(' + s.name + ', ' + LC[j] + ', ' + (cb.checked ? 1 : 0) + ') = 0');
          } else {
            s[k] = cb.checked;
            say((k === 'comp' ? 'rte_service_component_runstate_set' : 'rte_service_runstate_set') + '(' + s.name + ', ' + (cb.checked ? 1 : 0) + ') = 0');
          }
          refresh();
        });
      });
      CourseJS.$$('.svc-lc', root).forEach(function (b) {
        b.onclick = function () {
          var j = +b.getAttribute('data-j'), lc = lcores[j];
          if (lc.started) {
            /* rte_service_lcore_stop refuses if a running service is mapped only here */
            var blocker = svcs.filter(function (s) { return s.map[j] && s.comp && s.app && mappedCount(s) === 1; })[0];
            if (blocker) { say('rte_service_lcore_stop(' + LC[j] + ') = -EBUSY: ' + blocker.name + ' is running and lcore ' + LC[j] + ' is its only mapped lcore', true); return; }
            lc.started = false; say('rte_service_lcore_stop(' + LC[j] + ') = 0');
          } else { lc.started = true; say('rte_service_lcore_start(' + LC[j] + ') = 0'); }
          refresh();
        };
      });
    }
    function say(t, bad) { msg.innerHTML = '<code>' + esc(t) + '</code>'; msg.className = 'svc-msg' + (bad ? ' bad' : ''); }
    function refresh() {
      svcs.forEach(function (s, i) {
        var st = status(s), el = $('svc-st-' + i);
        el.textContent = st[0]; el.className = 'svc-st ' + st[1];
      });
      CourseJS.$$('.svc-lc', root).forEach(function (b) {
        var j = +b.getAttribute('data-j');
        b.textContent = 'lcore ' + LC[j] + ': ' + (lcores[j].started ? 'stop' : 'start');
      });
      drawSvg();
    }
    function runnable(s, j) { return s.comp && s.app && s.map[j] && lcores[j].started; }
    function drawSvg() {
      S.clear(gfx);
      LC.forEach(function (l, j) {
        var x = 10 + j * 320, lc = lcores[j];
        S.rect(gfx, x, 10, 300, 130, 'svg-box ' + (lc.started ? 'c5' : 'ghost'));
        S.text(gfx, x + 10, 28, 'service lcore ' + l + (lc.started ? ' (running service_runner_func)' : ' (stopped)'), 'svg-label small bold');
        var mapped = svcs.map(function (s, i) { return i; }).filter(function (i) { return svcs[i].map[j]; });
        if (!mapped.length) S.text(gfx, x + 150, 80, 'no services mapped', 'svg-label small center muted');
        mapped.forEach(function (i, k) {
          var s = svcs[i], y = 40 + k * 32;
          var cls = 'svg-box ' + (runnable(s, j) ? 'c2' : 'c7');
          if (lc.inSvc === i && lc.flash === 'run') cls += ' svg-highlight';
          var r = S.rect(gfx, x + 30, y, 200, 26, cls, { rx: 4 });
          if (lc.inSvc === i && lc.flash === 'busy') r.setAttribute('class', 'svg-box c4');
          S.text(gfx, x + 130, y + 13, s.name, 'svg-label small center mono');
          S.text(gfx, x + 270, y + 13, String(s.calls[j]), 'svg-label small center mono');
          if (lc.cur === i && lc.started) S.arrow(gfx, x + 6, y + 13, x + 26, y + 13, 'accent');
        });
        S.text(gfx, x + 270, 28, 'calls', 'svg-label small center muted');
      });
    }
    var anim = new CourseJS.Animator({
      root: root, autoplay: 'visible',
      onReset: function () { init(); buildTable(); refresh(); say('reset: three services, two service lcores'); },
      onFrame: function (dt) {
        var STEP = 0.55;
        lcores.forEach(function (lc, j) {
          if (!lc.started) { lc.cur = -1; lc.inSvc = -1; return; }
          lc.t += dt;
          if (lc.inSvc >= 0) {
            lc.hold -= dt;
            if (lc.hold <= 0) { var s0 = svcs[lc.inSvc]; if (s0.lock === j) s0.lock = -1; lc.inSvc = -1; lc.flash = ''; }
          }
          if (lc.t < STEP * (j ? 0.83 : 1)) return;
          lc.t = 0;
          var mapped = svcs.map(function (s, i) { return i; }).filter(function (i) { return svcs[i].map[j]; });
          if (!mapped.length) { lc.cur = -1; return; }
          var pos = mapped.indexOf(lc.cur);
          lc.cur = mapped[(pos + 1) % mapped.length];
          var s = svcs[lc.cur];
          if (!runnable(s, j)) { lc.inSvc = lc.cur; lc.flash = 'skip'; lc.hold = 0.2; return; }
          if (!s.mt) {
            if (s.lock !== -1 && s.lock !== j) { s.busy[j]++; lc.inSvc = lc.cur; lc.flash = 'busy'; lc.hold = 0.25; return; }
            s.lock = j;
          }
          s.calls[j]++; lc.inSvc = lc.cur; lc.flash = 'run'; lc.hold = 0.45;
        });
        svcs.forEach(function (s, i) {
          var el = $('svc-calls-' + i);
          if (el) el.innerHTML = (s.calls[0] + s.calls[1]) + (s.busy[0] + s.busy[1] ? '<br><span class="small" style="color:var(--pitfall)">' + (s.busy[0] + s.busy[1]) + ' busy</span>' : '');
        });
        drawSvg();
      }
    });
    root._anim = anim;
  })();

  /* ================================================================
   * 4. Keepalive watchdog (state machine of lib/eal/common/rte_keepalive.c)
   * ================================================================ */
  (function () {
    var root = $('w-ka');
    if (!root) return;
    var svg = root.querySelector('svg');
    var logEl = $('ka-log');
    var per = $('ka-per');
    var restart = $('ka-restart');
    CourseJS.bindRange(per, '#ka-per-out', function (v) { return v + ' ms'; });
    var NAMES = { 0: 'UNUSED', 1: 'ALIVE', 2: 'DEAD', 3: 'GONE', 4: 'MISSING' };
    var CLS = { 0: 'c7', 1: 'c2', 4: 'c3', 2: 'c4', 3: 'c4' };
    var cores, now, nextPing, pings, g = S.group(svg), boxes = [];
    var CORES = [1, 2, 3];
    function log(t, cls) {
      var d = document.createElement('div');
      d.innerHTML = '<span class="muted">t=' + (now / 1000).toFixed(2) + 's</span> ' + t;
      if (cls) d.className = cls;
      logEl.insertBefore(d, logEl.firstChild);
      while (logEl.childNodes.length > 40) logEl.removeChild(logEl.lastChild);
    }
    function build() {
      S.clear(g); boxes = [];
      S.rect(g, 10, 20, 150, 120, 'svg-box c1');
      S.text(g, 85, 40, 'lcore 0', 'svg-label center bold');
      S.text(g, 85, 58, 'ping timer', 'svg-label center small');
      g.ring = S.rect(g, 30, 74, 110, 12, 'svg-slot', { rx: 3 });
      g.bar = S.rect(g, 30, 74, 0, 12, 'svg-box c1', { rx: 3 });
      g.pings = S.text(g, 85, 110, 'pings: 0', 'svg-label center small mono');
      g.pulse = S.el('circle', { cx: 85, cy: 128, r: 5, 'class': 'svg-fill-c1', opacity: 0 }, g);
      CORES.forEach(function (lc, i) {
        var x = 200 + i * 145;
        var b = { x: x };
        b.rect = S.rect(g, x, 20, 130, 120, 'svg-box c2');
        S.text(g, x + 65, 38, 'lcore ' + lc + ' poll loop', 'svg-label center small bold');
        b.state = S.text(g, x + 65, 64, 'UNUSED', 'svg-label center bold mono');
        b.seen = S.text(g, x + 65, 88, '', 'svg-label center small');
        b.flag = S.el('circle', { cx: x + 65, cy: 116, r: 9, 'class': 'svg-fill-c2' }, g);
        b.flagTxt = S.text(g, x + 65, 133, 'mark_alive()', 'svg-label center small muted', { style: 'font-size:9px' });
        S.path(g, 'M160,' + (34 + i * 8) + ' L' + (172 + i * 6) + ',' + (34 + i * 8) + ' L' + (172 + i * 6) + ',' + (6 + i * 3) + ' L' + (x + 65) + ',' + (6 + i * 3) + ' L' + (x + 65) + ',17', 'svg-arrow c1 dashed');
        boxes.push(b);
      });
    }
    function render() {
      var P = +per.value;
      g.bar.setAttribute('width', Math.max(0, 110 * (1 - (nextPing - now) / P)));
      g.pings.textContent = 'pings: ' + pings;
      cores.forEach(function (c, i) {
        var b = boxes[i];
        b.state.textContent = NAMES[c.st];
        b.rect.setAttribute('class', 'svg-box ' + CLS[c.st] + (c.stalled ? ' dashed' : ''));
        b.seen.textContent = c.stalled ? 'STALLED (no marks)' : 'marking every pass';
        b.flag.setAttribute('opacity', c.st === 1 ? 1 : 0.15);
      });
      CourseJS.$$('.ka-stall', root).forEach(function (btn, i) { btn.textContent = (cores[i].stalled ? 'Resume' : 'Stall') + ' lcore ' + CORES[i]; btn.classList.toggle('primary', cores[i].stalled); });
    }
    function ping() {
      pings++;
      g.pulse.setAttribute('opacity', 1);
      setTimeout(function () { g.pulse.setAttribute('opacity', 0); }, 150);
      cores.forEach(function (c, i) {
        var lc = CORES[i], old = c.st;
        switch (c.st) {
          case 0: break;
          case 1: c.st = 4; c.lastAlive = now; break;               /* ALIVE -> MISSING */
          case 4: c.st = 2; log('EAL: Core MIA. Last seen ' + Math.round(now - c.lastAlive) + 'ms ago. (lcore ' + lc + ' MISSING -&gt; DEAD)', 'warn'); break;
          case 2: c.st = 3; log('EAL: Core died. Last seen ' + Math.round(now - c.lastAlive) + 'ms ago. (lcore ' + lc + ' DEAD -&gt; GONE)', 'err');
            log('<strong>failure callback(data, ' + lc + ')</strong>' + (restart.checked ? ': restarting the lcore\'s work' : ''), 'err');
            if (restart.checked) { c.stalled = false; }
            break;
          case 3: break;
        }
        if (old === 0 && c.st === 0) return;
      });
    }
    new CourseJS.Animator({
      root: root, autoplay: 'visible',
      onReset: function () {
        now = 0; pings = 0; nextPing = +per.value;
        cores = CORES.map(function () { return { st: 0, stalled: false, lastAlive: 0, markT: 0 }; });
        logEl.innerHTML = '';
        build(); render();
        log('rte_keepalive_register_core() x3: watched, state UNUSED until the first mark');
      },
      onFrame: function (dt) {
        var ms = dt * 1000;
        now += ms;
        cores.forEach(function (c) {
          if (c.stalled) return;
          c.markT += ms;
          if (c.markT >= 20) { c.markT = 0; c.st = 1; }         /* rte_keepalive_mark_alive(): state = ALIVE */
        });
        if (now >= nextPing) { ping(); nextPing = now + (+per.value); }
        render();
      }
    });
    CourseJS.$$('.ka-stall', root).forEach(function (btn, i) {
      btn.addEventListener('click', function () {
        var c = cores[i];
        c.stalled = !c.stalled;
        log(c.stalled ? 'lcore ' + CORES[i] + ' hangs: its loop stops calling mark_alive()' : 'lcore ' + CORES[i] + ' resumes marking');
        render();
      });
    });
  })();

  /* ================================================================
   * 5. cmdline: token-by-token matching of the step 4 instructions
   * ================================================================ */
  (function () {
    var root = $('w-cmd');
    if (!root) return;
    var input = $('cmd-in'), out = $('cmd-out'), res = $('cmd-res');
    var insts = [
      { f: 'cmd_show_parsed', toks: [{ t: 'str', v: 'show', field: 'show' }, { t: 'str', v: 'stats#keepalive', field: 'what' }] },
      { f: 'cmd_burst_parsed', toks: [{ t: 'str', v: 'set', field: 'set' }, { t: 'str', v: 'burst', field: 'burst' }, { t: 'num', v: 'UINT16', field: 'n', max: 65535 }] },
      { f: 'cmd_word_parsed', toks: [{ t: 'str', v: 'stall#help#quit', field: 'word' }] }
    ];
    function parseNum(w, max) {
      var m, n;
      if (/^0x[0-9a-f]+$/i.test(w)) n = parseInt(w.slice(2), 16);
      else if (/^0b[01]+$/i.test(w)) n = parseInt(w.slice(2), 2);
      else if ((m = /^[0-9]+$/.exec(w))) n = parseInt(w, 10);
      else return { ok: false, why: 'not a number' };
      if (n > max) return { ok: false, why: n + ' does not fit in uint16_t' };
      return { ok: true, val: n };
    }
    function update() {
      var line = input.value;
      var words = line.trim().length ? line.trim().split(/[ \t]+/) : [];
      var partial = line.length && !/\s$/.test(line) ? words[words.length - 1] : null;
      var full = [], anyTok = false, html = '', comp = [];
      insts.forEach(function (ins) {
        var i = 0, ok = true, row = '', fields = [];
        ins.toks.forEach(function (tk, k) {
          var w = words[k], cls, txt = tk.t === 'num' ? '&lt;' + tk.v + '&gt;' : tk.v.replace(/#/g, '|');
          if (!ok || w === undefined) { cls = 'tk-wait'; ok = false; }
          else if (tk.t === 'str') {
            var choices = tk.v.split('#');
            if (choices.indexOf(w) >= 0) { cls = 'tk-ok'; i++; fields.push(tk.field + '="' + w + '"'); }
            else { cls = 'tk-bad'; ok = false; }
          } else {
            var r = parseNum(w, tk.max);
            if (r.ok) { cls = 'tk-ok'; i++; fields.push(tk.field + '=' + r.val); }
            else { cls = 'tk-bad'; ok = false; txt += ' <small>(' + esc(r.why) + ')</small>'; }
          }
          /* completion candidates for the word being typed at this position */
          if (partial !== null && k === words.length - 1 && i === k && tk.t === 'str') {
            tk.v.split('#').forEach(function (c) { if (c.indexOf(partial) === 0 && c !== partial) comp.push(c); });
          }
          row += '<span class="tk ' + cls + '">' + txt + '</span>';
        });
        var extra = words.length > ins.toks.length;
        var matched = i === ins.toks.length && !extra;
        var verdict;
        if (matched) { full.push({ f: ins.f, fields: fields }); verdict = '<span class="tk-ok-t">full match</span>'; }
        else if (i > 0) { anyTok = true; verdict = '<span class="tk-bad-t">' + i + ' token(s) matched' + (extra && i === ins.toks.length ? ', then garbage' : '') + '</span>'; }
        else verdict = '<span class="muted">no token matched</span>';
        html += '<div class="cmd-row"><code class="cmd-f">' + ins.f + '</code> ' + row + ' ' + verdict + '</div>';
      });
      out.innerHTML = html;
      var r;
      if (!words.length) r = '<span class="muted">(empty line: nothing happens)</span>';
      else if (full.length > 1) r = '<span class="tk-bad-t">Ambiguous command</span>';
      else if (full.length === 1) r = 'calls <code>' + full[0].f + '(res = {' + esc(full[0].fields.join(', ')) + '})</code>';
      else if (anyTok) r = '<span class="tk-bad-t">Bad arguments</span> <span class="small muted">(an instruction matched its first token(s) but not all)</span>';
      else r = '<span class="tk-bad-t">Command not found</span>';
      if (comp.length) r += '<br><span class="small">TAB would offer: ' + comp.map(function (c) { return '<code>' + c + '</code>'; }).join(' ') + '</span>';
      res.innerHTML = r;
    }
    input.addEventListener('input', update);
    CourseJS.$$('.cmd-ex', root).forEach(function (b) {
      b.addEventListener('click', function () { input.value = b.getAttribute('data-v'); update(); input.focus(); });
    });
    update();
  })();
});

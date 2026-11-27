/* Chapter 4 widgets: TLB reach, VA -> IOVA mapping, EAL error decoder,
 * DPDK VA window animation, malloc heap stepper.
 * Data: window.CH04_ERRORS (from code/errors.tsv + expected_output.txt) and
 * window.CH04_SEGS (real va/iova pairs from memseg_walk run 3a). */
(function () {
  'use strict';
  CourseJS.ready(function () {
    var S = CourseJS.svg;
    var MB = 1 << 20;

    function fmtBytes(b) {
      if (b >= 1024 * 1024 * 1024) return CourseJS.fmt(b / (1024 * 1024 * 1024), b % (1 << 30) ? 1 : 0) + ' GB';
      if (b >= MB) return CourseJS.fmt(b / MB, b % MB ? 1 : 0) + ' MB';
      return CourseJS.fmt(b / 1024, 0) + ' KB';
    }
    function press(group, el) {
      Array.prototype.forEach.call(group.querySelectorAll('.btn'), function (b) {
        b.setAttribute('aria-pressed', b === el ? 'true' : 'false');
      });
    }

    /* ================================================================
     * 1. TLB reach
     * ================================================================ */
    (function () {
      var root = document.getElementById('w-tlb');
      if (!root) return;
      var svg = root.querySelector('svg');
      var PS = [
        { n: '4 KB', b: 4096, lv: ['PML4', 'PDPT', 'PD', 'PT'] },
        { n: '2 MB', b: 2 * MB, lv: ['PML4', 'PDPT', 'PD'] },
        { n: '1 GB', b: 1 << 30, lv: ['PML4', 'PDPT'] }
      ];
      var ENT = [64, 128, 256, 512, 1024, 1536, 2048];
      var WS = [8, 32, 128, 512, 2048, 8192, 32768, 131072];   /* MB */
      var st = { ps: 0 };
      var psGroup = document.getElementById('tlb-ps');
      var entIn = document.getElementById('tlb-ent'), wsIn = document.getElementById('tlb-ws');

      function draw() {
        var ps = PS[st.ps], ent = ENT[+entIn.value], ws = WS[+wsIn.value] * MB;
        document.getElementById('tlb-ent-o').textContent = ent;
        document.getElementById('tlb-ws-o').textContent = fmtBytes(ws);
        var pages = Math.ceil(ws / ps.b), reach = ent * ps.b, cover = Math.min(1, reach / ws);
        S.clear(svg);
        /* working-set bar */
        S.text(svg, 20, 18, 'working set ' + fmtBytes(ws) + ' = ' + CourseJS.fmt(pages) + ' pages of ' + ps.n, 'svg-label bold');
        var W = 600, x0 = 20, y0 = 30, H = 36;
        S.rect(svg, x0, y0, W, H, 'svg-box c4');
        var cw = Math.max(2, W * cover);
        S.rect(svg, x0, y0, cw, H, 'svg-box c2');
        if (pages <= 64) {
          for (var i = 1; i < pages; i++) S.line(svg, x0 + W * i / pages, y0, x0 + W * i / pages, y0 + H, 'svg-grid');
        }
        var lbl = cover >= 1 ? 'the TLB covers everything' : 'covered: ' + fmtBytes(reach);
        S.text(svg, x0 + Math.min(cw, W) / 2 < 90 ? x0 + 6 : x0 + Math.min(cw, W) / 2, y0 + H / 2, lbl,
          'svg-label small bold' + (x0 + Math.min(cw, W) / 2 < 90 ? '' : ' center')).setAttribute('dominant-baseline', 'middle');
        if (cover < 1) {
          S.text(svg, x0 + cw + (W - cw) / 2, y0 + H / 2, 'page walk on access', 'svg-label small center');
        }
        S.text(svg, 20, 86, 'TLB: ' + ent + ' entries x ' + ps.n + ' = reach ' + fmtBytes(reach), 'svg-label small muted');
        /* page walk */
        S.text(svg, 20, 118, 'TLB miss: the walk for one ' + ps.n + ' page', 'svg-label bold');
        var bx = 20, by = 132, bw = 86, bh = 40, gap = 14;
        var all = ['CR3', 'PML4', 'PDPT', 'PD', 'PT'];
        var prev = null;
        all.forEach(function (name, k) {
          var used = k === 0 || ps.lv.indexOf(name) >= 0;
          var x = bx + k * (bw + gap);
          var b = S.box(svg, x, by, bw, bh, name, used ? (k === 0 ? 'c7' : 'c6') : 'c7');
          if (!used) b.rect.classList.add('ghost', 'dashed');
          if (!used) b.label.classList.add('muted');
          if (used && prev !== null) S.arrow(svg, prev + bw, by + bh / 2, x - 2, by + bh / 2, 'c6');
          if (used) prev = x;
          if (used && k > 0) S.text(svg, x + bw / 2, by + bh + 14, 'read ' + k, 'svg-label small center muted');
        });
        var dx = bx + 5 * (bw + gap);
        var d = S.box(svg, dx, by, 90, bh, ps.n + ' page', 'c2');
        d.label.classList.add('small');
        S.arrow(svg, prev + bw, by + bh / 2, dx - 2, by + bh / 2, 'c2');
        S.text(svg, 20, 222, ps.lv.length + ' dependent table reads before the data load can start; then the TLB caches the result.',
          'svg-label small');
        S.text(svg, 20, 240, 'A hit skips all of it. Larger pages: fewer misses AND shorter walks.', 'svg-label small muted');
        document.getElementById('tlb-pages').textContent = CourseJS.fmt(pages);
        document.getElementById('tlb-reach').textContent = fmtBytes(reach);
        document.getElementById('tlb-miss').textContent = CourseJS.fmt((1 - cover) * 100, 1) + '%';
        document.getElementById('tlb-walk').textContent = ps.lv.length;
      }
      psGroup.addEventListener('click', function (e) {
        var b = e.target.closest('.btn');
        if (!b) return;
        st.ps = +b.getAttribute('data-i');
        press(psGroup, b);
        draw();
      });
      entIn.addEventListener('input', draw);
      wsIn.addEventListener('input', draw);
      press(psGroup, psGroup.querySelector('[data-i="0"]'));
      draw();
      CourseJS.onThemeChange(draw);
    })();

    /* ================================================================
     * 2. VA -> IOVA mapping, with predict
     * ================================================================ */
    (function () {
      var root = document.getElementById('w-iova');
      if (!root || !window.CH04_SEGS || !CH04_SEGS.length) return;
      var svg = root.querySelector('svg');
      var segs = CH04_SEGS.map(function (s) { return { va: parseInt(s.va, 16), iova: parseInt(s.iova, 16) }; });
      var N = segs.length, PG = 2 * MB;
      var modeGroup = document.getElementById('iova-mode');
      var verdict = document.getElementById('iova-verdict');
      var pred = document.getElementById('iova-predict');
      var mode = 'pa', busy = false, token = 0;
      var hex = function (v) { return '0x' + v.toString(16); };

      function mapping() {
        /* returns iova per VA page index */
        if (mode === 'va') return segs.map(function (s) { return s.va; });
        if (mode === 'pa') return segs.map(function (s) { return s.iova; });
        /* legacy: the same frames, but sorted by PA and handed out in that order */
        var sorted = segs.map(function (s) { return s.iova; }).sort(function (a, b) { return a - b; });
        return sorted;
      }
      var Y0 = 40, RH = 30, LX = 30, RX = 420, BW = 190;
      function draw(marks) {
        S.clear(svg);
        var io = mapping();
        S.text(svg, LX, 22, 'process VA (8 x 2 MB, in order)', 'svg-label bold');
        S.text(svg, RX, 22, mode === 'va' ? 'IOVA = VA (IOMMU translates)' : 'physical frames (IOVA = PA)', 'svg-label bold');
        /* right column ordered by address */
        var order = io.map(function (v, i) { return { v: v, i: i }; }).sort(function (a, b) { return a.v - b.v; });
        var rowOf = {};
        order.forEach(function (o, r) { rowOf[o.i] = r; });
        for (var i = 0; i < N; i++) {
          var y = Y0 + i * RH;
          var b = S.box(svg, LX, y, BW, RH - 6, 'VA ' + hex(segs[i].va), 'c1');
          b.label.classList.add('mono', 'small');
        }
        order.forEach(function (o, r) {
          var y = Y0 + r * RH;
          var b = S.box(svg, RX, y, BW, RH - 6, (mode === 'va' ? 'IOVA ' : 'PA ') + hex(o.v), 'c2');
          b.label.classList.add('mono', 'small');
          if (r > 0 && o.v !== order[r - 1].v + PG) {
            S.text(svg, RX + BW + 6, y - 2, 'gap', 'svg-label small muted');
          }
        });
        var pi = -1, pok = false;
        if (marks) Object.keys(marks).forEach(function (k) { pi = +k; pok = marks[k] === 'pair-good'; });
        for (var j = 0; j < N; j++) {
          var y1 = Y0 + j * RH + (RH - 6) / 2, y2 = Y0 + rowOf[j] * RH + (RH - 6) / 2;
          var cls = (pi >= 0 && (j === pi || j === pi + 1)) ? (pok ? 'c2' : 'c4') : 'c7';
          S.arrow(svg, LX + BW, y1, RX - 3, y2, cls);
        }
        if (marks) {
          Object.keys(marks).forEach(function (k) {
            if (marks[k] === 'pair-bad' || marks[k] === 'pair-good') {
              var i0 = +k, y = Y0 + i0 * RH - 3;
              var r = S.rect(svg, LX - 6, y, BW + 12, 2 * RH, 'svg-highlight');
              r.setAttribute('fill', 'none');
              S.text(svg, LX + BW / 2, Y0 + N * RH + 18,
                (marks[k] === 'pair-good' ? 'pages ' + i0 + '+' + (i0 + 1) + ': IOVA-adjacent' : 'pages ' + i0 + '+' + (i0 + 1) + ': not IOVA-adjacent'),
                'svg-label small center bold');
            }
          });
        }
        S.text(svg, LX, Y0 + N * RH + 40, 'A 3 MB zone needs two VA-neighbouring pages whose IOVAs are also neighbours: iova[i+1] = iova[i] + 2 MB.', 'svg-label small muted');
      }
      function findPair(io) {
        for (var i = 0; i + 1 < N; i++) if (io[i + 1] === io[i] + PG) return i;
        return -1;
      }
      function run(guess) {
        if (busy) return;
        busy = true;
        var my = ++token;
        var io = mapping(), hit = findPair(io), i = 0;
        verdict.className = 'verdict';
        verdict.textContent = 'Checking neighbouring pages ...';
        function step() {
          if (my !== token) return;
          if (i + 1 >= N || i > hit && hit >= 0) { finish(); return; }
          var m = {};
          m[i] = io[i + 1] === io[i] + PG ? 'pair-good' : 'pair-bad';
          draw(m);
          if (io[i + 1] === io[i] + PG) { finish(); return; }
          i++;
          setTimeout(step, 380);
        }
        function finish() {
          busy = false;
          var ok = hit >= 0;
          var right = (guess === 1) === ok;
          verdict.className = 'verdict ' + (ok ? 'good' : 'bad');
          var why;
          if (mode === 'pa') why = ok ? 'pages ' + hit + ' and ' + (hit + 1) + ' happen to be physical neighbours in the right order, and the captured run printed "OK" for exactly that range. Luck: when the heap grew page by page instead, the same request failed 5 out of 5 times.'
            : 'no VA neighbours are physical neighbours in ascending order (most sit 2 MB BELOW their predecessor). The heap cannot find 2 suitable pages: ENOMEM, as in the 5 tries of run 3b.';
          else if (mode === 'va') why = 'IOVA = VA, so VA-contiguous is IOVA-contiguous. Real run with --iova-mode=va: "OK".';
          else why = 'legacy mode sorts the pages by physical address before giving them VA slots, so physical neighbours become VA neighbours.';
          verdict.innerHTML = '<strong>' + (right ? 'Your prediction was right. ' : 'Not what you predicted. ') + '</strong>' +
            (ok ? 'Reservation succeeds: ' : 'Reservation fails (ENOMEM): ') + why;
        }
        step();
      }
      pred.addEventListener('click', function (e) {
        var b = e.target.closest('.btn');
        if (b) run(+b.getAttribute('data-p'));
      });
      modeGroup.addEventListener('click', function (e) {
        var b = e.target.closest('.btn');
        if (!b) return;
        token++; busy = false;
        mode = b.getAttribute('data-m');
        press(modeGroup, b);
        verdict.className = 'verdict';
        verdict.textContent = mode === 'pa' ? 'PA mode, the real pages of run 3a. Predict, then check.'
          : mode === 'va' ? 'VA mode: the device uses the same addresses as the CPU. Predict, then check.'
          : '--legacy-mem: same physical frames, handed out in sorted order. Predict, then check.';
        draw();
      });
      press(modeGroup, modeGroup.querySelector('[data-m="pa"]'));
      draw();
      CourseJS.onThemeChange(function () { draw(); });
    })();

    /* ================================================================
     * 3. EAL error decoder
     * ================================================================ */
    (function () {
      var root = document.getElementById('w-err');
      var data = window.CH04_ERRORS;
      if (!root || !data) return;
      var svg = root.querySelector('svg');
      var pick = document.getElementById('err-pick'), text = document.getElementById('err-text');
      var out = document.getElementById('err-out');
      var PH = ['parse args', 'config + lock', 'IPC + bus scan', 'IOVA mode', 'hugepage info', 'memory + heap', 'lcore threads', 'services + probe', 'your code'];
      data.forEach(function (d, i) {
        var o = document.createElement('option');
        o.value = i;
        o.textContent = d.id + ' - ' + d.key;
        pick.appendChild(o);
      });
      function timeline(phase) {
        S.clear(svg);
        var w = 66, g = 5, x0 = 4;
        PH.forEach(function (n, k) {
          var p = k + 1, x = x0 + k * (w + g);
          var cls = !phase ? 'c7' : p < phase ? 'c2' : p === phase ? 'c4' : 'c7';
          var r = S.rect(svg, x, 22, w, 40, 'svg-box ' + cls);
          if (phase && p > phase) r.classList.add('ghost');
          var words = n.split(' ');
          if (words.length > 1 && n.length > 9) {
            S.text(svg, x + w / 2, 36, words[0] + (words[1] === '+' ? ' +' : ''), 'svg-label small center');
            S.text(svg, x + w / 2, 51, words.slice(words[1] === '+' ? 2 : 1).join(' '), 'svg-label small center');
          } else {
            S.text(svg, x + w / 2, 43, n, 'svg-label small center');
          }
          S.text(svg, x + w / 2, 12, String(p), 'svg-label small center muted');
          if (p === phase) S.text(svg, x + w / 2, 78, 'fails here', 'svg-label small center bold');
        });
        S.text(svg, 4, 94, phase === 9 ? 'rte_eal_init() succeeded; the failure is in your own code' : 'rte_eal_init() phases, lib/eal/linux/eal.c', 'svg-label small muted');
      }
      function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
      function show(d, how) {
        timeline(d ? d.phase : 0);
        if (!d) {
          out.innerHTML = '<dt>result</dt><dd>No row of the part-1 catalogue matches. Port-start errors are in ch8, multi-process errors in ch16, and ch13 merges all tables. Rerun with <code>--log-level=lib.eal:debug</code> to see the phase, then add a row (Exercise 5).</dd>';
          return;
        }
        out.innerHTML =
          '<dt>matched</dt><dd><strong>' + d.id + '</strong> ' + esc(how) + '</dd>' +
          '<dt>phase</dt><dd>' + d.phase + ' - ' + esc(PH[d.phase - 1]) + '</dd>' +
          '<dt>trigger</dt><dd><code>' + esc(d.trigger) + '</code></dd>' +
          '<dt>cause</dt><dd>' + esc(d.cause) + '</dd>' +
          '<dt>fix</dt><dd>' + esc(d.fix) + '</dd>' +
          '<dt>rte_errno</dt><dd>' + esc(d.errno) + '</dd>' +
          '<dt>real log</dt><dd><pre>' + esc(d.log.join('\n')) + '</pre></dd>';
      }
      function decode() {
        var t = text.value.trim();
        if (!t) { show(data[+pick.value], '(picked from the list)'); return; }
        var lines = t.split('\n');
        for (var i = 0; i < data.length; i++) {
          var re = new RegExp(data[i].re, 'm');
          for (var k = 0; k < lines.length; k++) {
            if (re.test(lines[k])) { show(data[i], 'by the line "' + lines[k].trim().slice(0, 90) + '"'); return; }
          }
        }
        show(null);
      }
      pick.addEventListener('change', function () { text.value = ''; decode(); });
      document.getElementById('err-go').addEventListener('click', decode);
      text.addEventListener('keydown', function (e) { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) decode(); });
      pick.value = '2';
      decode();
      CourseJS.onThemeChange(decode);
    })();

    /* ================================================================
     * 4. DPDK VA window animation
     * ================================================================ */
    (function () {
      var root = document.getElementById('w-vawin');
      if (!root) return;
      var svg = root.querySelector('svg');
      var steps = root.querySelectorAll('#vawin-steps li');
      var cap = document.getElementById('vawin-cap');
      var SLOTS = 10, X0 = 190, SW = 36, Y = 70, H = 46;
      var STEP_T = 0.45;              /* seconds per alloc_seg step */
      /* script: t in seconds */
      var T_GROW0 = 1.5, GROW_PAGES = 3, T_GROW_END = T_GROW0 + GROW_PAGES * 7 * STEP_T + 0.6;
      var T_HOLD = T_GROW_END + 2.2, T_FREE_END = T_HOLD + 2.0, T_LOOP = T_FREE_END + 1.6;
      var slots = [], clock = 0, lastKey = '';

      function build() {
        S.clear(svg);
        S.text(svg, 10, 16, 'virtual addresses from 0x100000000 (default base)', 'svg-label small muted');
        var pre = [['config', 'c7'], ['fbarray memzone', 'c5'], ['fbarray memseg', 'c5']];
        pre.forEach(function (p, i) {
          var b = S.box(svg, 10 + i * 58, Y, 54, H, '', p[1]);
          S.text(svg, 37 + i * 58, Y + H + 14, p[0].split(' ')[0], 'svg-label small center');
          if (p[0].indexOf(' ') > 0) S.text(svg, 37 + i * 58, Y + H + 27, p[0].split(' ')[1], 'svg-label small center');
          b.label.textContent = '';
        });
        S.text(svg, X0, Y - 24, 'memseg list: 32768 slots x 2 MB = 64 GB reserved (PROT_NONE)', 'svg-label small bold');
        S.text(svg, X0, Y - 8, '0x100200000', 'svg-label small mono');
        slots = [];
        for (var i = 0; i < SLOTS; i++) {
          var r = S.rect(svg, X0 + i * SW, Y, SW - 4, H, 'svg-box c7 ghost svg-fade');
          var t = S.text(svg, X0 + i * SW + (SW - 4) / 2, Y + H / 2, i, 'svg-label small center muted');
          slots.push({ r: r, t: t });
        }
        S.text(svg, X0 + SLOTS * SW + 4, Y + H / 2, '... +' + (32768 - SLOTS) + ' slots', 'svg-label small').setAttribute('dominant-baseline', 'middle');
        S.text(svg, X0, Y + H + 16, 'grey: reserved VA, nothing mapped', 'svg-label small muted');
        S.text(svg, X0, Y + H + 30, 'green: hugepage mapped = a memseg, used bit set in the fbarray', 'svg-label small muted');
        svg._heap = S.text(svg, 10, Y + H + 58, '', 'svg-label bold');
        svg._ev = S.text(svg, 10, Y + H + 80, '', 'svg-label small mono');
      }
      function setSlot(i, on, cur) {
        var s = slots[i];
        s.r.setAttribute('class', 'svg-box svg-fade ' + (on ? 'c2' : 'c7 ghost') + (cur ? ' svg-highlight' : ''));
        s.t.setAttribute('class', 'svg-label small center' + (on ? ' bold' : ' muted'));
      }
      function render(t) {
        var mapped = 1, cur = -1, step = -1, caption, ev = '';
        if (t < T_GROW0) {
          caption = 'After rte_eal_init(): one page mapped (EAL\'s own allocations). Next: rte_zmalloc(5 MB).';
        } else if (t < T_GROW_END) {
          var k = Math.floor((t - T_GROW0) / STEP_T);
          var page = Math.min(GROW_PAGES - 1, Math.floor(k / 7));
          step = Math.min(6, k - page * 7);
          if (k >= GROW_PAGES * 7) { step = 7; page = GROW_PAGES - 1; }
          mapped = 1 + page + (step >= 6 ? 1 : 0);
          cur = 1 + page;
          caption = 'rte_zmalloc(5 MB): no free element is big enough, so alloc_seg() maps page ' + (cur) + ' of 3.';
          if (step === 7) { mapped = 4; caption = 'All 3 pages mapped; they become one new free element and the 5 MB block is cut from its end.'; ev = '[mem event] ALLOC addr=0x100400000 len=6144 KB'; }
        } else if (t < T_HOLD) {
          mapped = 4; step = 7;
          caption = 'Heap is 8 MB now. The 3 pages are not pinned (no -m), so they can be given back.';
          ev = '[mem event] ALLOC addr=0x100400000 len=6144 KB';
        } else if (t < T_FREE_END) {
          var f = Math.floor((t - T_HOLD) / 0.5);
          mapped = Math.max(1, 4 - Math.min(3, f + 1));
          caption = 'rte_free(): the element merges with its free neighbours; whole free pages are unmapped (munmap + hole re-reserved).';
          ev = '[mem event] FREE  addr=0x100400000 len=6144 KB';
        } else {
          mapped = 1;
          caption = 'Back to one page: heap 2 MB, exactly as in run 5a.';
          ev = '[mem event] FREE  addr=0x100400000 len=6144 KB';
        }
        var key = mapped + '|' + cur + '|' + step + '|' + caption;
        if (key === lastKey) return;
        lastKey = key;
        for (var i = 0; i < SLOTS; i++) setSlot(i, i < mapped, i === cur && step >= 0 && step < 7);
        Array.prototype.forEach.call(steps, function (li, j) { li.classList.toggle('on', j === step); });
        svg._heap.textContent = 'heap size ' + (mapped * 2) + ' MB, mapped pages: ' + mapped;
        svg._ev.textContent = ev;
        cap.textContent = caption;
      }
      build();
      new CourseJS.Animator({
        root: root,
        autoplay: 'visible',
        onReset: function () { clock = 0; lastKey = ''; render(0); },
        onFrame: function (dt) { clock += dt; if (clock > T_LOOP) clock = 0; render(clock); }
      });
      CourseJS.onThemeChange(function () { lastKey = ''; render(clock); });
    })();

    /* ================================================================
     * 5. Malloc heap stepper
     * ================================================================ */
    (function () {
      var root = document.getElementById('w-heap');
      if (!root) return;
      var svg = root.querySelector('svg');
      var KB = 1024, PAGE = 2048;            /* sizes in KB */
      var X0 = 20, W = 600, Y = 40, H = 54, HDR = 0.125;   /* header 128 B = 0.125 KB */
      var MAXKB = 3 * PAGE;
      function bucket(kb) {                  /* malloc_elem_free_list_index(), sizes in bytes */
        var b = kb * KB;
        if (b < 256) return 0;
        var log2 = Math.floor(Math.log2(b)) + 1;
        return Math.min(12, Math.floor((log2 - 8 + 1) / 2));
      }
      function draw(ctx) {
        S.clear(svg);
        var pages = ctx.data.pages, els = ctx.data.els;
        var sc = W / MAXKB;
        S.text(svg, X0, 18, 'heap socket_0: ' + pages + ' page' + (pages > 1 ? 's' : '') + ' mapped (' + pages * 2 + ' MB)', 'svg-label bold');
        for (var p = 0; p < 3; p++) {
          var r = S.rect(svg, X0 + p * PAGE * sc, Y, PAGE * sc, H, 'svg-box ' + (p < pages ? 'c7' : 'c7 ghost dashed'));
          r.setAttribute('fill-opacity', p < pages ? '0.15' : '0.05');
          S.text(svg, X0 + (p + 0.5) * PAGE * sc, Y + H + 14, p < pages ? 'page ' + p : 'not mapped', 'svg-label small center muted');
        }
        els.forEach(function (e) {
          var x = X0 + e.s * sc, w = e.z * sc;
          var cls = e.st === 'free' ? 'c2' : e.st === 'busy' ? 'c3' : 'c5';
          S.rect(svg, x + 1, Y + 4, Math.max(3, w - 2), H - 8, 'svg-box ' + cls + (e.st === 'free' ? ' ghost' : ''));
          S.rect(svg, x + 1, Y + 4, 5, H - 8, 'svg-box c7');               /* malloc_elem header */
          if (w > 50) {
            S.text(svg, x + w / 2 + 3, Y + H / 2 - 7, (e.name ? e.name + ' ' : '') + e.st.toUpperCase(), 'svg-label small center bold');
            S.text(svg, x + w / 2 + 3, Y + H / 2 + 9, e.z >= 1024 ? CourseJS.fmt(e.z / 1024, e.z % 1024 ? 2 : 0) + ' MB' : e.z + ' KB', 'svg-label small center');
          } else if (e.name) {
            S.text(svg, x + w / 2, Y - 6, e.name, 'svg-label small center');
          }
        });
        /* free list buckets */
        S.text(svg, X0, 140, 'free lists (13 size classes, powers of 4 from 256 B); a search starts at the request\'s class and moves up', 'svg-label small muted');
        var counts = []; for (var i = 0; i < 13; i++) counts.push(0);
        els.forEach(function (e) { if (e.st === 'free') counts[bucket(e.z - HDR)]++; });
        var LB = ['256B', '1K', '4K', '16K', '64K', '256K', '1M', '4M', '16M', '64M', '256M', '1G', 'more'];
        var bw = 44, bg = 2;
        for (var k = 0; k < 13; k++) {
          var bx = X0 + k * (bw + bg);
          S.rect(svg, bx, 150, bw, 34, 'svg-box ' + (counts[k] ? 'c2' : 'c7 ghost'));
          S.text(svg, bx + bw / 2, 162, String(k), 'svg-label small center muted');
          S.text(svg, bx + bw / 2, 177, counts[k] ? counts[k] + ' free' : '', 'svg-label small center bold');
          S.text(svg, bx + bw / 2, 198, '<' + LB[k], 'svg-label small center muted');
        }
        S.text(svg, X0, 222, 'legend: grey bar = malloc_elem header (128 B, not to scale)   green = FREE   orange = BUSY', 'svg-label small muted');
        if (ctx.data.ev) S.text(svg, X0, 242, ctx.data.ev, 'svg-label small bold');
      }
      new CourseJS.Stepper(root, {
        reset: function (ctx) {
          ctx.data.pages = 1;
          ctx.data.els = [{ s: 0, z: 8, st: 'busy', name: 'EAL' }, { s: 8, z: PAGE - 8, st: 'free' }];
          ctx.data.ev = '';
          draw(ctx);
        },
        steps: [
          { caption: 'After init: one 2 MB page. EAL\'s own 8 KB block sits at the start; the rest is one FREE element (one header + data).' },
          { caption: 'a = rte_malloc(512 KB): the block is cut from the END of the free element. The free element shrinks and stays on its list.',
            predict: { question: 'Where in the free element does the new 512 KB block go?', options: ['At its start', 'At its end'], answer: 1,
              explain: 'malloc_elem_alloc() places the new element at the end (elem_start_pt aligns down from the end), so only the free element\'s size changes.' },
            run: function (ctx, cur) { var f = ctx.data.els[1]; f.z -= 512; ctx.data.els.push({ s: f.s + f.z, z: 512, st: 'busy', name: 'a' }); if (cur) draw(ctx); } },
          { caption: 'b = rte_malloc(256 KB): again from the end of the free element, right in front of a.',
            run: function (ctx, cur) { var f = ctx.data.els[1]; f.z -= 256; ctx.data.els.splice(2, 0, { s: f.s + f.z, z: 256, st: 'busy', name: 'b' }); if (cur) draw(ctx); } },
          { caption: 'rte_free(a): a becomes FREE. Its only neighbour, b, is busy, so nothing merges: two free elements now.',
            run: function (ctx, cur) { ctx.data.els[3].st = 'free'; ctx.data.els[3].name = ''; if (cur) draw(ctx); } },
          { caption: 'rte_free(b): b merges with the free elements on both sides. Two free elements are never neighbours.',
            predict: { question: 'How many free elements are there after rte_free(b)?', options: ['1', '2', '3'], answer: 0,
              explain: 'malloc_elem_join_adjacent_free() merges b with the free element before it and the one after it.' },
            run: function (ctx, cur) { var e = ctx.data.els; e.splice(1, 3, { s: 8, z: PAGE - 8, st: 'free' }); if (cur) draw(ctx); } },
          { caption: 'big = rte_malloc(3 MB): no free element is big enough, so the heap grows. The size to map is the request plus its header, rounded up to whole pages: 4 MB = 2 pages. The new pages join the adjacent free element.',
            predict: { question: 'How many new 2 MB pages does the heap map for 3 MB?', options: ['1 (2 MB are already free)', '2', '3'], answer: 1,
              explain: 'alloc_more_mem_on_socket() rounds request + overhead up to whole pages without counting the free space already there: ceil(3 MB + 128 B, 2 MB) = 2 pages. Run 5a shows the same rule: 5 MB mapped 3 pages (6144 KB).' },
            run: function (ctx, cur) {
              ctx.data.pages = 3; var f = ctx.data.els[1]; f.z = 3 * PAGE - 8 - 3072;
              ctx.data.els.push({ s: 3 * PAGE - 3072, z: 3072, st: 'busy', name: 'big' });
              ctx.data.ev = '[mem event] ALLOC len=4096 KB (2 pages)'; if (cur) draw(ctx); } },
          { caption: 'rte_free(big): everything after EAL\'s block is one free element again. The pages that are completely free and were not pinned by -m are unmapped: the heap shrinks back to one page.',
            run: function (ctx, cur) { ctx.data.pages = 1; ctx.data.els = [{ s: 0, z: 8, st: 'busy', name: 'EAL' }, { s: 8, z: PAGE - 8, st: 'free' }];
              ctx.data.ev = '[mem event] FREE len=4096 KB (2 pages)'; if (cur) draw(ctx); } }
        ],
        onStep: function (i, ctx) { draw(ctx); }
      });
    })();
  });
})();

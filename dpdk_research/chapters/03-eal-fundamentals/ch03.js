/* Chapter 3 widgets: EAL layer cake, rte_eal_init step-through, lcore<->CPU
 * mapper, remote_launch swimlanes and the log routing tree.
 * Plain ES5, no network, works from file://. Colours only via course.css. */
CourseJS.ready(function () {
  var S = CourseJS.svg;
  function $(id) { return document.getElementById(id); }
  function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }

  /* ------------------------------------------------------------------ */
  /* Figure: EAL layer cake                                              */
  /* ------------------------------------------------------------------ */
  (function () {
    var ge = $('cake-eal'), go = $('cake-os');
    if (!ge || !go) return;
    var eal = [['lcores &', 'launch'], ['memory,', 'heap'], ['buses &', 'devices'], ['interrupts', '& alarms'],
               ['time', '(TSC)'], ['multi-', 'process'], ['logging', '(lib/log)']];
    var os = [['pthreads,', 'affinity'], ['hugetlbfs,', 'memfd'], ['sysfs,', 'VFIO, UIO'], ['epoll,', 'timerfd'],
              ['rdtsc,', 'clock_gettime'], ['shared file,', 'unix socket'], ['stderr,', 'syslog']];
    var w = 640 / 7;
    for (var i = 0; i < 7; i++) {
      var x = 10 + i * w + 3, bw = w - 6, cx = x + bw / 2;
      S.rect(ge, x, 132, bw, 50, 'svg-box c1');
      S.text(ge, cx, 150, eal[i][0], 'svg-label center small bold');
      S.text(ge, cx, 166, eal[i][1], 'svg-label center small bold');
      S.arrow(ge, cx, 184, cx, 224, 'c6');
      S.rect(go, x, 228, bw, 48, 'svg-box c6');
      S.text(go, cx, 245, os[i][0], 'svg-label center small');
      S.text(go, cx, 261, os[i][1], 'svg-label center small');
    }
    S.text(go, 18, 222, 'Linux', 'svg-label small muted');
  })();

  /* ------------------------------------------------------------------ */
  /* Widget 1: rte_eal_init step-through (real log lines)                */
  /* ------------------------------------------------------------------ */
  (function () {
    var root = $('w-init');
    if (!root) return;
    var svg = root.querySelector('svg');
    var logEl = $('init-log');
    var phases = [
      'main() calls rte_eal_init()',
      'parse log options',
      'detect CPUs and NUMA nodes',
      'parse EAL args: lcores, devices',
      'shared config (rte_config_init)',
      'interrupt thread, alarms, MP channel',
      'probe VFIO, scan buses',
      'decide IOVA mode',
      'memory: memzones, memsegs, heap',
      'timer: measure the TSC',
      'start lcore threads',
      'services, bus probe, telemetry',
      'return to main()'
    ];
    var rows = [];
    S.text(svg, 10, 14, 'phase', 'svg-label small muted');
    phases.forEach(function (p, i) {
      var y = 20 + i * 21;
      var r = S.rect(svg, 10, y, 290, 18, 'svg-box c7 svg-fade dim', { rx: 4 });
      var t = S.text(svg, 18, y + 9, (i ? i + '. ' : '') + p, 'svg-label small', { 'dominant-baseline': 'middle' });
      rows.push({ r: r, t: t });
    });
    /* right side: what exists */
    S.text(svg, 320, 14, 'what now exists', 'svg-label small muted');
    S.rect(svg, 318, 20, 316, 92, 'svg-box ghost');
    S.text(svg, 326, 34, '/var/run/dpdk/ch03-init/', 'svg-label small mono');
    S.rect(svg, 318, 118, 316, 92, 'svg-box ghost');
    S.text(svg, 326, 132, 'threads', 'svg-label small bold');
    S.rect(svg, 318, 216, 316, 80, 'svg-box ghost');
    S.text(svg, 326, 230, 'state', 'svg-label small bold');
    var items = {};
    function item(key, x, y, w, label, cls) {
      var g = S.group(svg, 'svg-fade svg-hidden');
      S.rect(g, x, y, w, 20, 'svg-box ' + cls, { rx: 4 });
      S.text(g, x + 6, y + 10, label, key.indexOf('s-') === 0 ? 'svg-label small' : 'svg-label small mono', { 'dominant-baseline': 'middle' });
      items[key] = g;
    }
    item('config', 326, 42, 96, 'config', 'c2');
    item('mp_socket', 428, 42, 96, 'mp_socket', 'c5');
    item('fbz', 326, 66, 150, 'fbarray_memzone', 'c2');
    item('fbn', 482, 66, 146, 'fbarray_nohugemem', 'c2');
    item('telsock', 326, 88, 150, 'dpdk_telemetry.v2', 'c5');
    item('t-main', 326, 140, 146, 'main (lcore 0)', 'c1');
    item('t-intr', 478, 140, 150, 'dpdk-intr', 'c6');
    item('t-mp', 326, 164, 146, 'dpdk-mp-msg', 'c6');
    item('t-w1', 478, 164, 150, 'dpdk-worker1', 'c1');
    item('t-tel', 326, 188, 146, 'dpdk-telemet-v2', 'c6');
    item('s-lc', 326, 238, 150, 'lcores 0,1 / control CPUs 2-3', 'c1');
    item('s-iova', 482, 238, 146, 'IOVA mode: VA', 'c3');
    item('s-heap', 326, 262, 150, '64 MB heap, socket 0', 'c2');
    item('s-tsc', 482, 262, 146, 'TSC: 2.7 GHz', 'c7');

    var L = [
      [],
      ['EAL: lib.eal log level changed from info to debug'],
      ['[<     0.001080>] EAL: Detected lcore 0 as core 0 on NUMA node 0', '... (lcores 1-3 the same way)',
       '[<     0.000008>] EAL: Detected CPU lcores: 4', '[<     0.000014>] EAL: Detected NUMA nodes: 1'],
      ['[<     0.000011>] EAL: Cores selected by core list: 0-1', '[<     0.000003>] EAL: lcore 0 mapped to physical core 0',
       '[<     0.000001>] EAL: lcore 1 mapped to physical core 1', '[<     0.000074>] EAL: Control threads will use cores: 2-3',
       '[<     0.000019>] EAL: Detected static linkage of DPDK'],
      ['[<     0.001383>] EAL: Ask a virtual area of 0x7000 bytes', '[<     0.000013>] EAL: Virtual area found at 0x100000000 (size = 0x7000)'],
      ['[<     0.000315>] EAL: Multi-process socket /var/run/dpdk/ch03-init/mp_socket'],
      ['[<     0.000118>] EAL: Probing VFIO support...', '[<     0.000016>] EAL: Module /sys/module/vfio not found! error 2 (No such file or directory)',
       '[<     0.000001>] EAL: VFIO modules not loaded, skipping VFIO support...'],
      ['[<     0.000004>] EAL: Bus pci wants IOVA as \'DC\'', '[<     0.000008>] EAL: Bus vdev wants IOVA as \'DC\'',
       '[<     0.000001>] EAL: Buses did not request a specific IOVA mode.',
       '[<     0.000000>] EAL: Physical addresses are unavailable, selecting IOVA as VA mode.',
       '[<     0.000000>] EAL: Selected IOVA mode \'VA\''],
      ['[<     0.000125>] EAL: Setting up physically contiguous memory...', '[<     0.000221>] EAL: Memseg list allocated at socket 0, page size 0x4kB',
       '[<     0.000017>] EAL: Using memfd for anonymous memory', '[<     0.000001>] EAL: VA reserved for memseg list at 0x1000f6000, size 4000000',
       '[<     0.000282>] EAL: Added 64M to heap on socket 0'],
      ['[<     0.100145>] EAL: TSC frequency is ~2700000 KHz', '[<     0.000225>] EAL: Allocated 64 bytes of per-lcore data with a 64-byte alignment'],
      ['[<     0.000044>] EAL: Main lcore 0 is ready (tid=7f7fdc687a00;cpuset=[0])', '[<     0.000185>] EAL: lcore 1 is ready (tid=7f7fd7ffc6c0;cpuset=[1])'],
      ['[<     0.000080>] EAL: Allocated 2112 bytes of per-lcore data with a 64-byte alignment', '(no devices to probe: --no-pci and no --vdev)'],
      ['rte_eal_init() returns 9: the number of EAL arguments', 'hello from core 1', 'hello from core 0']
    ];
    var show = [[], [], [], ['s-lc'], ['config'], ['mp_socket', 't-intr', 't-mp'], [], ['s-iova'],
                ['fbz', 'fbn', 's-heap'], ['s-tsc'], ['t-w1'], ['telsock', 't-tel'], []];

    function mark(i, cur) {
      rows[i].r.setAttribute('class', 'svg-box svg-fade ' + (cur ? 'c1 cur' : 'c2'));
      rows[i].t.setAttribute('class', 'svg-label small' + (cur ? ' bold' : ''));
    }
    new CourseJS.Stepper(root, {
      interval: 2200,
      reset: function (ctx) {
        rows.forEach(function (r) { r.r.setAttribute('class', 'svg-box c7 svg-fade dim'); r.t.setAttribute('class', 'svg-label small'); });
        Object.keys(items).forEach(function (k) { items[k].classList.add('svg-hidden'); });
        items['t-main'].classList.remove('svg-hidden');
        ctx.data.lines = [];
      },
      steps: phases.map(function (p, i) {
        var st = {
          caption: i === 0 ? 'Before init: only the main thread exists. <code>rte_eal_init(argc, argv)</code> is about to run the phases below, in this order.'
            : '<strong>Phase ' + i + ': ' + esc(p) + '.</strong> ' + [
              '', 'Logging works from here on, so every later phase can report problems.',
              'Reads <code>/sys/devices/system/cpu</code> to learn which CPUs and NUMA nodes exist.',
              'Parses the rest of the options. The lcore list is turned into lcore &rarr; cpuset entries, and the control-thread CPUs are computed.',
              'The primary creates and maps the shared configuration file and locks it, so a second process can find it (ch16).',
              'Starts the <code>dpdk-intr</code> thread (epoll on interrupts and alarm timerfds) and the multi-process socket and its <code>dpdk-mp-msg</code> thread.',
              'Looks for VFIO (none here), then runs every registered bus\'s scan: PCI is skipped by <code>--no-pci</code>, vdev finds nothing.',
              'Each bus votes PA, VA or DC (don\'t care); with no votes EAL decides itself (ch4).',
              'Reserves virtual address space and fills the heap: with <code>--no-huge</code> it is 4 KB-page memfd memory instead of hugepages (ch4).',
              'Finds out how fast the TSC ticks. Everything that converts cycles to time depends on this.',
              'Pins the main thread, creates one thread per worker lcore with its pipes, and waits until all report ready.',
              'Initialises service cores, probes devices (vdevs last), starts telemetry, and marks the config complete.',
              'Back in <code>main()</code>. helloworld launches its function on lcore 1, runs it on lcore 0 too, waits, and cleans up.'][i]
        };
        st.run = function (ctx, cur) {
          for (var k = 0; k < i; k++) mark(k, false);
          mark(i, cur);
          show[i].forEach(function (key) { items[key].classList.remove('svg-hidden'); });
          ctx.data.lines = ctx.data.lines.map(function (l) { return { t: l.t, cur: false }; })
            .concat(L[i].map(function (t) { return { t: t, cur: cur }; }));
        };
        if (i === 7) st.predict = {
          question: 'Both buses vote "DC" (don\'t care), and this run uses <code>--no-huge</code>, so EAL cannot learn physical addresses. Which IOVA mode will it select?',
          options: ['PA (physical addresses)', 'VA (IOVA = virtual address)', 'Init fails'], answer: 1,
          explain: 'With no bus preference EAL uses a heuristic: if physical addresses are unavailable, use VA. The log says exactly that.' };
        if (i === 9) st.predict = {
          question: 'This next phase takes 0.100 s of the 0.11 s total init time. What is it doing?',
          options: ['Sleeping 100 ms while it compares the TSC with the kernel clock', 'Zeroing the 64 MB heap', 'Waiting for the worker threads to start'],
          answer: 0, explain: 'get_tsc_freq() in lib/eal/linux/eal_timer.c sleeps 1/10 s and divides the TSC delta by the elapsed CLOCK_MONOTONIC_RAW time, because this VM does not report the frequency in a way EAL trusts.' };
        return st;
      }),
      onStep: function (i, ctx) {
        logEl.innerHTML = ctx.data.lines.length ? ctx.data.lines.map(function (l) {
          return '<span class="' + (l.cur ? 'cur' : '') + '">' + esc(l.t) + '</span>';
        }).join('\n') : '<span>(no log output yet)</span>';
        logEl.scrollTop = logEl.scrollHeight;
      }
    });
  })();

  /* ------------------------------------------------------------------ */
  /* Widget 2: lcore <-> CPU mapper                                      */
  /* ------------------------------------------------------------------ */
  (function () {
    var root = $('w-map');
    if (!root) return;
    var NCPU = 4, MAXL = 128;
    var svg = root.querySelector('svg');
    var input = $('map-in');
    var presets = ['-l 0-3', "--lcores='0,(1-3)@(1,2)'", '-l 2-3 -R', '-l 1-3 --main-lcore 3',
                   "--lcores='0@0,(1,2)@(1-3)'", "--lcores='(0-3)@0'", '-l 0-2 -S 2', '-l 0-5', '-c 0x6'];
    presets.forEach(function (p) {
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'btn small'; b.textContent = p;
      b.addEventListener('click', function () { input.value = p; draw(); });
      $('map-presets').appendChild(b);
    });

    /* "0-2,5" or "(1,2)" content -> sorted unique array, or throws */
    function parseSet(s) {
      var out = [];
      s.split(',').forEach(function (part) {
        part = part.trim();
        var m = /^(\d+)(?:-(\d+))?$/.exec(part);
        if (!m) throw new Error('cannot parse "' + part + '"');
        var a = +m[1], b = m[2] != null ? +m[2] : a;
        if (b < a) throw new Error('range "' + part + '" goes backwards');
        for (var k = a; k <= b; k++) if (out.indexOf(k) < 0) out.push(k);
      });
      return out.sort(function (x, y) { return x - y; });
    }
    function splitTop(s) {          /* split on commas outside parentheses */
      var parts = [], depth = 0, cur = '';
      for (var i = 0; i < s.length; i++) {
        var c = s[i];
        if (c === '(') depth++;
        if (c === ')') depth--;
        if (c === ',' && depth === 0) { parts.push(cur); cur = ''; } else cur += c;
      }
      parts.push(cur);
      return parts;
    }
    function side(s) {             /* "(1,2)" or "1-3" or "4" */
      s = s.trim();
      var grp = s[0] === '(';
      if (grp) {
        if (s[s.length - 1] !== ')') throw new Error('missing ")" in "' + s + '"');
        s = s.slice(1, -1);
      }
      return { set: parseSet(s), group: grp };
    }
    function parseLcores(str) {     /* -> {lcoreId: [cpus]} */
      var map = {};
      splitTop(str).forEach(function (el) {
        el = el.trim();
        if (!el) throw new Error('empty element in the lcore list');
        var at = el.indexOf('@'), left, right;
        if (at >= 0) { left = side(el.slice(0, at)); right = side(el.slice(at + 1)); }
        else left = side(el);
        left.set.forEach(function (lc) {
          if (map[lc]) throw new Error('lcore ' + lc + ' is given twice');
          map[lc] = right ? right.set.slice() : (left.group ? left.set.slice() : [lc]);
        });
      });
      return map;
    }
    function tokenize(s) {
      var t = [], re = /'([^']*)'|"([^"]*)"|(\S+)/g, m;
      /* glue quoted parts onto the token they belong to */
      s = s.replace(/=\s*'([^']*)'/g, '=$1').replace(/=\s*"([^"]*)"/g, '=$1');
      while ((m = re.exec(s))) t.push(m[1] != null ? m[1] : m[2] != null ? m[2] : m[3]);
      return t.map(function (x) { return x.replace(/^['"]|['"]$/g, ''); });
    }
    function cpustr(a) {           /* [0,1,2,5] -> "0-2,5" like EAL prints */
      var out = [], i = 0;
      while (i < a.length) {
        var j = i;
        while (j + 1 < a.length && a[j + 1] === a[j] + 1) j++;
        out.push(j > i ? a[i] + '-' + a[j] : String(a[i]));
        i = j + 1;
      }
      return out.join(',');
    }

    function analyse(text) {
      var tok = tokenize(text), r = { msgs: [], log: [], lcores: {}, main: null, svc: [], error: null };
      var lstr = null, mask = null, remap = null, mainOpt = null, svcStr = null;
      var i, a, v;
      function val() { if (a.indexOf('=') > 0) return a.slice(a.indexOf('=') + 1); i++; return tok[i]; }
      for (i = 0; i < tok.length; i++) {
        a = tok[i];
        if (a === '-l' || a === '--lcores' || a.indexOf('--lcores=') === 0) lstr = val();
        else if (/^-l\S/.test(a)) lstr = a.slice(2);
        else if (a === '-c' || a === '--coremask' || a.indexOf('--coremask=') === 0) mask = val();
        else if (a === '-R' || a === '--remap-lcore-ids') remap = 0;
        else if (a.indexOf('--remap-lcore-ids=') === 0) remap = +a.split('=')[1];
        else if (a === '--main-lcore' || a.indexOf('--main-lcore=') === 0) mainOpt = val();
        else if (a === '-S' || a === '--service-corelist' || a.indexOf('--service-corelist=') === 0) svcStr = val();
        else if (a === '-s') { v = val(); r.msgs.push(['warn', '-s is deprecated: use -S with a list of lcores']); svcStr = null; }
        else if (/^--?/.test(a)) r.msgs.push(['warn', 'ignored option "' + a + '" (the mapper only knows the lcore options)']);
      }
      try {
        if (lstr != null && mask != null) throw new Error('give either -l or -c, not both');
        if (mask != null) {
          r.msgs.push(['warn', "'-c <coremask>' option is deprecated, and will be removed in a future release. Use '-l <corelist>' instead."]);
          var n = parseInt(mask, 16), list = [];
          if (isNaN(n) || n <= 0) throw new Error('bad coremask "' + mask + '"');
          for (var b = 0; b < 31; b++) if (n & (1 << b)) list.push(b);
          lstr = list.join(',');
        }
        if (lstr == null) { lstr = '0-' + (NCPU - 1); r.msgs.push(['warn', 'no -l given: EAL uses every allowed CPU, one lcore each (-l 0-3 here)']); }
        var map = parseLcores(lstr);
        var ids = Object.keys(map).map(Number).sort(function (x, y) { return x - y; });
        /* CPU checks */
        var bad = [];
        ids.forEach(function (id) { map[id].forEach(function (c) { if (c >= NCPU && bad.indexOf(c) < 0) bad.push(c); }); });
        if (bad.length) {
          bad.forEach(function (c) { r.log.push('EAL: lcore ' + c + ' unavailable'); });
          throw new Error('invalid coremask or core-list parameter, please check specified cores are part of 0-' + (NCPU - 1));
        }
        if (remap != null) {
          var nm = {};
          ids.forEach(function (id, k) { nm[remap + k] = map[id]; });
          map = nm; ids = Object.keys(map).map(Number).sort(function (x, y) { return x - y; });
        }
        ids.forEach(function (id) { if (id >= MAXL) throw new Error('lcore id ' + id + ' >= RTE_MAX_LCORE (128)'); });
        var main = ids[0];
        if (mainOpt != null) {
          main = +mainOpt;
          if (ids.indexOf(main) < 0) throw new Error('Main lcore is not enabled for DPDK');
        }
        var svc = svcStr != null ? parseSet(svcStr) : [];
        svc.forEach(function (s) {
          if (ids.indexOf(s) < 0) r.msgs.push(['warn', 'service lcore ' + s + ' is not in -l: the course rule is to list it there too']);
          if (s === main) throw new Error('the main lcore cannot be a service lcore');
        });
        /* control threads: all CPUs minus every lcore cpuset; else main's */
        var used = [];
        ids.forEach(function (id) { map[id].forEach(function (c) { if (used.indexOf(c) < 0) used.push(c); }); });
        svc.forEach(function (s) { if (ids.indexOf(s) < 0 && s < NCPU && used.indexOf(s) < 0) used.push(s); });
        var ctl = [];
        for (var c = 0; c < NCPU; c++) if (used.indexOf(c) < 0) ctl.push(c);
        var ctlFallback = !ctl.length;
        if (ctlFallback) ctl = map[main].slice();
        /* per-CPU thread count */
        var per = [];
        for (c = 0; c < NCPU; c++) per.push(0);
        ids.forEach(function (id) { map[id].forEach(function (cc) { per[cc]++; }); });
        r.lcores = map; r.ids = ids; r.main = main; r.svc = svc; r.ctl = ctl; r.per = per;
        if (remap != null || (lstr.indexOf('@') < 0 && lstr.indexOf('(') < 0)) ids.forEach(function (id) { r.log.push('EAL: lcore ' + id + ' mapped to physical core ' + map[id][0]); });
        r.log.push('EAL: Control threads will use cores: ' + cpustr(ctl));
        r.log.push('EAL: Main lcore ' + main + ' is ready (cpuset=[' + cpustr(map[main]) + '])');
        ids.forEach(function (id) {
          if (id === main) return;
          r.log.push('EAL: lcore ' + id + ' is ready (cpuset=[' + cpustr(map[id]) + '])' + (svc.indexOf(id) >= 0 ? '   <- role SERVICE' : ''));
        });
        var over = [];
        per.forEach(function (n, cc) { if (n > 1) over.push(cc); });
        r.over = over;
        if (over.length) r.msgs.push(['bad', 'oversubscribed: CPU ' + over.join(', ') + ' can be used by more than one lcore thread. They time-share; never measure like this.']);
        if (ctlFallback) r.msgs.push(['warn', 'no CPU left for control threads: they share the main lcore\'s CPU ' + cpustr(ctl) + '.']);
        ids.forEach(function (id) { if (map[id].length > 1) r.msgs.push(['warn', 'lcore ' + id + ' floats over CPUs ' + cpustr(map[id]) + ': the kernel may move it.']); });
        if (remap != null) r.msgs.push(['good', '-R: lcore ids renumbered from ' + remap + ' (the CPUs stay the same).']);
        if (svc.length) r.msgs.push(['good', 'rte_lcore_count() = ' + ids.length + ', but RTE_LCORE_FOREACH visits only ' + (ids.length - svc.filter(function (s) { return ids.indexOf(s) >= 0; }).length) + ' (service lcores are skipped).']);
        if (!r.msgs.length) r.msgs.push(['good', 'one thread per CPU and a free CPU for control threads: a good layout.']);
      } catch (e) {
        r.error = e.message;
      }
      return r;
    }

    function draw() {
      var r = analyse(input.value);
      while (svg.firstChild) svg.removeChild(svg.firstChild);
      var msgs = $('map-msgs');
      msgs.innerHTML = '';
      function msg(kind, text) { var li = document.createElement('li'); li.innerHTML = '<span class="' + (kind === 'err' ? 'bad' : kind) + '">' + (kind === 'err' ? 'error' : kind === 'bad' ? 'problem' : kind === 'warn' ? 'note' : 'ok') + ':</span> ' + esc(text); msgs.appendChild(li); }
      r.msgs.forEach(function (m) { msg(m[0], m[1]); });
      if (r.error) {
        msg('err', r.error);
        S.text(svg, 320, 120, 'EAL: ' + r.error, 'svg-label center bold');
        S.text(svg, 320, 145, 'rte_eal_init() returns -1; the samples then panic', 'svg-label center small muted');
        $('map-n').textContent = '-'; $('map-main').textContent = '-'; $('map-ctl').textContent = '-'; $('map-over').textContent = '-';
        $('map-log').textContent = r.log.concat(['EAL: ' + r.error, 'EAL: Error parsing command line arguments.']).join('\n');
        return;
      }
      var ids = r.ids, n = ids.length;
      S.text(svg, 10, 14, 'lcores (EAL threads)', 'svg-label small muted');
      S.text(svg, 10, 160, 'CPUs', 'svg-label small muted');
      var cpuX = [], cw = 130;
      for (var c = 0; c < NCPU; c++) cpuX.push(30 + c * 150);
      var lw = Math.min(90, Math.floor(600 / n) - 8), lx = {};
      var total = n * (lw + 8) - 8, x0 = 320 - total / 2;
      var arrows = S.group(svg);
      ids.forEach(function (id, k) {
        var x = x0 + k * (lw + 8), isMain = id === r.main, isSvc = r.svc.indexOf(id) >= 0;
        lx[id] = x + lw / 2;
        S.rect(svg, x, 24, lw, 44, 'svg-box ' + (isSvc ? 'c5' : 'c1') + (isMain ? ' cur' : ''));
        S.text(svg, x + lw / 2, 40, 'lcore ' + id, 'svg-label center small bold');
        S.text(svg, x + lw / 2, 57, isMain ? 'main' : isSvc ? 'service' : 'worker', 'svg-label center small');
        r.lcores[id].forEach(function (cc) {
          var tx = cpuX[cc] + cw / 2;
          S.path(arrows, 'M' + (x + lw / 2) + ',68 C' + (x + lw / 2) + ',120 ' + tx + ',110 ' + tx + ',168',
                 'svg-arrow ' + (isSvc ? 'c5' : 'c1') + (r.lcores[id].length > 1 ? ' dashed' : ''));
        });
      });
      for (c = 0; c < NCPU; c++) {
        var over = r.per[c] > 1, ctl = r.ctl.indexOf(c) >= 0;
        S.rect(svg, cpuX[c], 172, cw, 44, 'svg-box ' + (over ? 'c4 flash' : r.per[c] ? 'c7' : 'c7 ghost'));
        S.text(svg, cpuX[c] + cw / 2, 188, 'CPU ' + c, 'svg-label center bold');
        S.text(svg, cpuX[c] + cw / 2, 205, r.per[c] + ' lcore thread' + (r.per[c] === 1 ? '' : 's'), 'svg-label center small');
        if (ctl) {
          S.rect(svg, cpuX[c] + 10, 224, cw - 20, 22, 'svg-box c6', { rx: 4 });
          S.text(svg, cpuX[c] + cw / 2, 235, 'control threads', 'svg-label center small');
        }
      }
      $('map-n').textContent = n;
      $('map-main').textContent = r.main;
      $('map-ctl').textContent = cpustr(r.ctl);
      $('map-over').textContent = r.over.length ? r.over.join(',') : 'none';
      $('map-log').textContent = 'What EAL logs with --log-level=lib.eal:debug (tids omitted):\n' + r.log.join('\n');
    }
    $('map-go').addEventListener('click', draw);
    input.addEventListener('keydown', function (e) { if (e.key === 'Enter') draw(); });
    draw();
  })();

  /* ------------------------------------------------------------------ */
  /* Widget 3: remote_launch swimlanes                                   */
  /* ------------------------------------------------------------------ */
  (function () {
    var root = $('w-launch');
    if (!root) return;
    var svg = root.querySelector('svg');
    S.rect(svg, 10, 8, 620, 58, 'svg-box c1');
    S.text(svg, 20, 26, 'main lcore 0', 'svg-label bold');
    var mainAct = S.text(svg, 20, 50, '', 'svg-label mono');
    S.text(svg, 20, 92, 'lcore_config[1]  (shared memory)', 'svg-label small muted');
    function field(x, w, name) {
      var r = S.rect(svg, x, 100, w, 46, 'svg-box c7 svg-fade');
      S.text(svg, x + 8, 114, name, 'svg-label small muted');
      var v = S.text(svg, x + 8, 135, '', 'svg-label mono');
      return { r: r, v: v, cls: 'c7' };
    }
    var F = { state: field(20, 120, 'state'), f: field(150, 150, 'f'), arg: field(310, 80, 'arg'), ret: field(400, 80, 'ret') };
    /* pipes */
    S.line(svg, 535, 66, 535, 196, 'svg-line', { style: 'stroke: var(--c5); stroke-dasharray: 4 3' });
    S.line(svg, 595, 66, 595, 196, 'svg-line', { style: 'stroke: var(--c5); stroke-dasharray: 4 3' });
    S.text(svg, 541, 112, 'pipe', 'svg-label small');
    S.text(svg, 541, 126, 'main to', 'svg-label small');
    S.text(svg, 541, 140, 'worker', 'svg-label small');
    S.text(svg, 601, 112, 'pipe', 'svg-label small');
    S.text(svg, 601, 126, 'worker', 'svg-label small');
    S.text(svg, 601, 140, 'to main', 'svg-label small');
    S.rect(svg, 10, 196, 620, 66, 'svg-box c1');
    S.text(svg, 20, 214, 'worker lcore 1 (thread dpdk-worker1)', 'svg-label bold');
    var wAct = S.text(svg, 20, 240, '', 'svg-label mono');
    S.text(svg, 470, 214, 'CPU', 'svg-label small muted');
    S.rect(svg, 500, 205, 120, 12, 'svg-slot', { rx: 3 });
    var cpu = S.rect(svg, 500, 205, 0, 12, 'svg-box c3', { rx: 3 });
    var token = S.el('circle', { cx: 535, cy: 70, r: 7, 'class': 'svg-fill-c5 svg-hidden' }, svg);
    var tw = null;

    function set(name, val, cls, flash) {
      F[name].v.textContent = val;
      F[name].r.setAttribute('class', 'svg-box svg-fade ' + (cls || 'c7') + (flash ? ' cur' : ''));
    }
    function cpuPct(p) { cpu.setAttribute('width', 120 * p / 100); }
    function fly(x, y0, y1, cur) {
      if (tw) { tw.cancel(); tw = null; }
      if (!cur) { token.classList.add('svg-hidden'); return; }
      token.classList.remove('svg-hidden');
      token.setAttribute('cx', x);
      tw = CourseJS.tween({ from: y0, to: y1, duration: 900, onUpdate: function (v) { token.setAttribute('cy', v); },
        onDone: function () { token.classList.add('svg-hidden'); } });
    }
    new CourseJS.Stepper(root, {
      interval: 2600,
      reset: function () {
        if (tw) { tw.cancel(); tw = null; }
        token.classList.add('svg-hidden');
        mainAct.textContent = 'running main() after rte_eal_init()';
        wAct.textContent = 'blocked in read() on its pipe: asleep in the kernel';
        cpuPct(0);
        set('state', 'WAIT', 'c2'); set('f', 'NULL'); set('arg', 'NULL'); set('ret', '0');
      },
      steps: [
        { caption: 'After init every worker sleeps in <code>read()</code> on its main-to-worker pipe. State is WAIT and it uses no CPU.' },
        { caption: '<code>rte_eal_remote_launch(work_square, NULL, 1)</code> first loads <code>state</code> with acquire order. It is WAIT, so the launch may proceed.',
          run: function (ctx, cur) { mainAct.textContent = 'remote_launch: load state (acquire): it is WAIT, go on'; set('state', 'WAIT', 'c2', cur); } },
        { caption: 'Main stores <code>arg</code>, then stores <code>f</code> with <em>release</em> order, so the worker that sees <code>f</code> also sees <code>arg</code>.',
          run: function (ctx, cur) { mainAct.textContent = 'remote_launch: arg = NULL; f = work_square (release)'; set('arg', 'NULL', 'c3', cur); set('f', 'work_square', 'c3', cur); } },
        { caption: 'Main writes one byte into the pipe (<code>eal_thread_wake_worker()</code>), then blocks reading the ack pipe. The worker\'s <code>read()</code> returns: the kernel wakes it up.',
          run: function (ctx, cur) { mainAct.textContent = 'write(pipe, 1 byte); read(ack pipe) ... waiting'; wAct.textContent = 'read() returned: awake'; fly(535, 70, 192, cur); } },
        { caption: 'The worker stores <code>state = RUNNING</code> (release) and writes the ack. Main\'s read returns and <code>rte_eal_remote_launch()</code> returns 0. The worker is already RUNNING at this point.',
          run: function (ctx, cur) { set('state', 'RUNNING', 'c3', cur); wAct.textContent = 'state = RUNNING (release); write(ack)'; mainAct.textContent = 'rte_eal_remote_launch() returned 0'; fly(595, 192, 70, cur); } },
        { caption: 'The worker loads <code>f</code> (acquire) and calls <code>f(arg)</code>. It now uses its CPU fully; main is free to do other work.',
          run: function () { wAct.textContent = 'ret = work_square(NULL);  ... computing'; cpuPct(100); mainAct.textContent = 'free: launch other workers, or do its own work'; } },
        { caption: 'A second launch on the same lcore sees RUNNING and returns <code>-EBUSY</code> (-16) immediately. Nothing is queued; the call did nothing.',
          run: function (ctx, cur) { mainAct.textContent = 'remote_launch(work_square, NULL, 1): state is RUNNING, returns -EBUSY'; set('state', 'RUNNING', 'c4', cur); },
          predict: { question: 'Main calls <code>rte_eal_remote_launch(work_square, NULL, 1)</code> again while lcore 1 is RUNNING. What happens?',
            options: ['It returns -EBUSY at once and does nothing', 'It waits until the worker is free, then launches', 'It queues the call to run next'], answer: 0,
            explain: 'The first thing remote_launch does is check state == WAIT; otherwise it returns -EBUSY. eal_tour printed "second launch while RUNNING returns -16".' } },
        { caption: '<code>work_square</code> returns 101. The worker stores <code>ret</code>, clears <code>f</code> and <code>arg</code>, stores <code>state = WAIT</code> (release) and goes back to <code>read()</code>.',
          run: function (ctx, cur) { set('ret', '101', 'c2', cur); set('f', 'NULL'); set('arg', 'NULL'); set('state', 'WAIT', 'c2', cur); wAct.textContent = 'back in read(): asleep'; cpuPct(0); } },
        { caption: '<code>rte_eal_wait_lcore(1)</code> spins until it loads WAIT (acquire), then returns <code>ret</code>. Calling it again returns the same value at once: <code>ret</code> stays until the next launch.',
          run: function () { mainAct.textContent = 'rte_eal_wait_lcore(1) returns 101'; },
          predict: { question: 'Main now calls <code>rte_eal_wait_lcore(1)</code>. What does it return?',
            options: ['0, meaning success', '101, the value work_square returned', 'WAIT, the new state'], answer: 1,
            explain: 'wait_lcore returns lcore_config[1].ret, the return value of the launched function (eal_tour printed rte_eal_wait_lcore(1) = 101).' } }
      ]
    });
  })();

  /* ------------------------------------------------------------------ */
  /* Widget 4: log routing tree                                          */
  /* ------------------------------------------------------------------ */
  (function () {
    var root = $('w-log');
    if (!root) return;
    var svg = root.querySelector('svg');
    var NAMES = ['', 'EMERG', 'ALERT', 'CRIT', 'ERR', 'WARNING', 'NOTICE', 'INFO', 'DEBUG'];
    var TYPES = [
      { n: 'lib.eal', d: 7 }, { n: 'lib.ethdev', d: 7 }, { n: 'lib.mempool', d: 7 },
      { n: 'pmd.net.null', d: 6 }, { n: 'pmd.net.ring', d: 6 },
      { n: 'user.ch03app', d: 7 }, { n: 'user.ch03app.rx', d: 5 }
    ];
    var sel = $('log-lvl');
    for (var i = 1; i <= 8; i++) {
      var o = document.createElement('option');
      o.value = i; o.textContent = i + ' ' + NAMES[i];
      if (i === 8) o.selected = true;
      sel.appendChild(o);
    }
    var input = $('log-in');
    ["--log-level='user.ch03*:debug' --log-level=lib.eal:warning", '--log-level=user.ch03app:debug',
     "--log-level='^pmd\\.net,8'", '--log-level=5', "--log-level='*:err' --log-level=lib.eal:info", ''].forEach(function (p) {
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'btn small'; b.textContent = p || '(no option)';
      b.addEventListener('click', function () { input.value = p; draw(); });
      $('log-presets').appendChild(b);
    });

    function lvl(s) {
      s = String(s).toLowerCase();
      if (/^\d+$/.test(s)) return +s;
      var map = { emerg: 1, alert: 2, crit: 3, critical: 3, err: 4, error: 4, warning: 5, warn: 5, notice: 6, info: 7, debug: 8 };
      return map[s] || -1;
    }
    function globRe(g) {           /* fnmatch(pattern, name, 0) */
      var re = '^';
      for (var i = 0; i < g.length; i++) {
        var c = g[i];
        if (c === '*') re += '.*';
        else if (c === '?') re += '.';
        else if (c === '[') { var j = g.indexOf(']', i + 1); if (j > i) { re += g.slice(i, j + 1); i = j; } else re += '\\['; }
        else re += c.replace(/[.+^${}()|\\]/g, '\\$&');
      }
      return new RegExp(re + '$');
    }
    function parse(text) {
      var rules = [], errs = [], re = /--log-level(?:=|\s+)('([^']*)'|"([^"]*)"|(\S+))/g, m;
      while ((m = re.exec(text))) {
        var arg = m[2] != null ? m[2] : m[3] != null ? m[3] : m[4], k, lv, rx;
        if ((k = arg.indexOf(',')) >= 0) {
          lv = lvl(arg.slice(k + 1));
          try { rx = new RegExp(arg.slice(0, k)); } catch (e) { errs.push('bad regex "' + arg.slice(0, k) + '"'); continue; }
          rules.push({ kind: 'regex', text: arg, test: rx, level: lv });
        } else if ((k = arg.indexOf(':')) >= 0) {
          lv = lvl(arg.slice(k + 1));
          rules.push({ kind: 'glob', text: arg, test: globRe(arg.slice(0, k)), level: lv });
        } else {
          lv = lvl(arg);
          rules.push({ kind: 'global', text: arg, level: lv });
        }
        if (lv <= 0) { errs.push('Invalid log level: ' + arg); rules.pop(); }
        else if (lv > 8) rules[rules.length - 1].level = 8;
      }
      return { rules: rules, errs: errs };
    }

    function draw() {
      var p = parse(input.value), msgLvl = +sel.value, global = 8;
      while (svg.firstChild) svg.removeChild(svg.firstChild);
      p.rules.forEach(function (r) { if (r.kind === 'global') global = r.level; });
      var eff = TYPES.map(function (t) {
        var level = t.d, by = 'default';
        p.rules.forEach(function (r, k) {
          if (r.kind !== 'global' && r.test.test(t.n)) { level = r.level; by = 'rule ' + (k + 1) + ' (' + r.text + ')'; }
        });
        return { n: t.n, level: level, by: by, pass: msgLvl <= global && msgLvl <= level };
      });
      /* tree: root -> group -> leaf */
      var groups = { lib: [0, 1, 2], pmd: [3, 4], user: [5, 6] };
      S.rect(svg, 10, 100, 110, 50, 'svg-box c7');
      S.text(svg, 65, 118, 'global level', 'svg-label center small');
      S.text(svg, 65, 136, global + ' ' + NAMES[global], 'svg-label center small bold');
      var gy = { lib: 40, pmd: 125, user: 195 };
      Object.keys(groups).forEach(function (g) {
        S.path(svg, 'M120,125 C140,125 140,' + gy[g] + ' 160,' + gy[g], 'svg-line');
        S.rect(svg, 160, gy[g] - 14, 70, 28, 'svg-box c7');
        S.text(svg, 195, gy[g], g + '.*', 'svg-label center small mono');
        groups[g].forEach(function (ix) {
          var y = 18 + ix * 32, e = eff[ix];
          S.path(svg, 'M230,' + gy[g] + ' C250,' + gy[g] + ' 250,' + (y + 12) + ' 270,' + (y + 12), 'svg-line');
          S.rect(svg, 270, y, 360, 26, 'svg-box ' + (e.pass ? 'c2' : 'c7 dim'), { rx: 4 });
          S.text(svg, 280, y + 13, e.n, 'svg-label small mono', { 'dominant-baseline': 'middle' });
          S.text(svg, 420, y + 13, e.level + ' ' + NAMES[e.level], 'svg-label small', { 'dominant-baseline': 'middle' });
          S.text(svg, 520, y + 13, e.pass ? 'printed' : 'dropped', 'svg-label small bold ' + (e.pass ? '' : 'muted'), { 'dominant-baseline': 'middle' });
          S.el('circle', { cx: 612, cy: y + 13, r: 6, 'class': e.pass ? 'svg-ok' : 'svg-no' }, svg);
        });
      });
      var ul = $('log-msgs');
      ul.innerHTML = '';
      function li(h) { var x = document.createElement('li'); x.innerHTML = h; ul.appendChild(x); }
      p.errs.forEach(function (e) { li('<span class="bad">error:</span> ' + esc(e) + ' (EAL would refuse to start)'); });
      if (!p.rules.length && !p.errs.length) li('No <code>--log-level</code>: every logtype keeps the level it registered with.');
      p.rules.forEach(function (r, k) {
        var hit = r.kind === 'global' ? 'sets the global level' :
          'matches ' + (eff.filter(function (e, ix) { return r.test.test(TYPES[ix].n); }).map(function (e) { return '<code>' + e.n + '</code>'; }).join(', ') || 'nothing in this tree');
        li('<span class="good">rule ' + (k + 1) + '</span> <code>' + esc(r.text) + '</code> (' + r.kind + ', level ' + r.level + '): ' + hit);
      });
      li('A level-' + msgLvl + ' (' + NAMES[msgLvl] + ') message is printed only if ' + msgLvl + ' &le; global (' + global + ') and ' + msgLvl + ' &le; the type\'s level. Printed for: ' +
         (eff.filter(function (e) { return e.pass; }).map(function (e) { return '<code>' + e.n + '</code>'; }).join(', ') || 'none') + '.');
    }
    $('log-go').addEventListener('click', draw);
    sel.addEventListener('change', draw);
    input.addEventListener('keydown', function (e) { if (e.key === 'Enter') draw(); });
    draw();
  })();
});

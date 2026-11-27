/* Chapter 13 widgets. Data captured on the course VM is in data.js
 * (window.CH13_DATA, generated from code/expected_output.txt). */
(function () {
  'use strict';
  var D = window.CH13_DATA || {};

  function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  function $(id) { return document.getElementById(id); }

  /* ------------------------------------------------------------------ */
  /* 1. Telemetry request / response stepper                             */
  /* ------------------------------------------------------------------ */
  function telWidget() {
    var root = $('w-tel');
    if (!root) return;
    var S = CourseJS.svg;
    var svg = root.querySelector('svg');
    var wire = $('tel-wire');
    var stClient = $('tel-st-client'), stConn = $('tel-st-conn'), stBytes = $('tel-st-bytes');
    var statsJson = (D.tel_stats || '').trim();
    var nullJson = (D.tel_null || '').trim();
    var hello = (D.hello || '').replace(/^hello: /, '').trim();

    S.rect(svg, 350, 10, 360, 282, 'svg-box c7 dashed');
    S.text(svg, 530, 28, 'DPDK process (telemetry_app)', 'svg-label center bold');
    var client = S.box(svg, 14, 112, 150, 60, 'client', 'c6');
    client.label.setAttribute('y', 128);
    S.text(svg, 89, 190, 'dpdk-telemetry.py', 'svg-label center small mono');
    var sock = S.box(svg, 190, 117, 136, 50, 'dpdk_telemetry.v2', 'c7');
    sock.label.setAttribute('class', 'svg-label center small mono');
    S.text(svg, 258, 184, 'SOCK_SEQPACKET', 'svg-label center small muted');
    var listener = S.box(svg, 365, 42, 160, 52, 'dpdk-telemet-v2', 'c6');
    var lsub = S.text(svg, 445, 86, 'blocked in accept()', 'svg-label center small');
    var handler = S.box(svg, 365, 120, 160, 52, 'client thread', 'c6');
    var hsub = S.text(svg, 445, 164, '', 'svg-label center small');
    var worker = S.box(svg, 365, 214, 160, 60, 'lcore 1 (worker)', 'c1');
    var wsub = S.text(svg, 445, 262, 'polling net_null 0 <-> 1', 'svg-label center small');
    var tbl = S.rect(svg, 540, 42, 160, 140, 'svg-box c5');
    S.text(svg, 620, 60, 'callbacks (sorted)', 'svg-label center small bold');
    var cmds = ['/ch13/echo', '/ch13/stats', '/eal/lcore/usage', '/ethdev/stats', '/help', '/mempool/info'];
    var cmdT = cmds.map(function (c, i) {
      return S.text(svg, 552, 80 + i * 17, c, 'svg-label small mono');
    });
    var dataBox = S.rect(svg, 540, 196, 160, 78, 'svg-box c2');
    var dataT1 = S.text(svg, 620, 216, 'struct rte_tel_data', 'svg-label center small bold');
    var dataT2 = S.text(svg, 620, 236, '', 'svg-label center small mono');
    var dataT3 = S.text(svg, 620, 254, '', 'svg-label center small mono');
    var a1 = S.arrow(svg, 164, 142, 188, 142, 'c6');
    var a2 = S.arrow(svg, 326, 142, 362, 142, 'c6');
    var a3 = S.path(svg, 'M445,94 L445,118', 'svg-arrow c6 dashed');
    var a4 = S.arrow(svg, 525, 146, 538, 120, 'c5');
    var a5 = S.path(svg, 'M525,240 Q532,240 538,236', 'svg-arrow c1 dashed');
    var msg = S.packet(svg, 89, 152, 72, 16, "c3", "req");
    [a3, a4, a5].forEach(function (e) { e.classList.add('svg-fade'); });

    function fly(fromX, fromY, toX, toY, label, cls, animate) {
      msg.label.textContent = label;
      msg.body.setAttribute('class', 'svg-packet ' + cls);
      msg.style.opacity = 1;
      if (!animate) { S.moveTo(msg, toX, toY); return; }
      S.moveTo(msg, fromX, fromY);
      CourseJS.tween({ from: { x: fromX, y: fromY }, to: { x: toX, y: toY }, duration: 700,
        onUpdate: function (v) { S.moveTo(msg, v.x, v.y); } });
    }

    new CourseJS.Stepper(root, {
      reset: function () {
        handler.style.opacity = 0.25;
        hsub.textContent = '';
        lsub.textContent = 'blocked in accept()';
        listener.rect.classList.remove('svg-highlight');
        handler.rect.classList.remove('svg-highlight');
        tbl.classList.remove('svg-highlight');
        dataBox.style.opacity = 0.25;
        dataT2.textContent = ''; dataT3.textContent = '';
        cmdT.forEach(function (t) { t.classList.remove('bold'); t.style.fill = ''; });
        [a3, a4, a5].forEach(function (e) { e.style.opacity = 0.15; });
        msg.style.opacity = 0;
        wsub.textContent = 'polling net_null 0 <-> 1';
        stClient.textContent = 'idle'; stConn.textContent = '0'; stBytes.textContent = '-';
        wire.textContent = '(nothing on the wire yet)';
      },
      steps: [
        { caption: 'The app is running. Its worker lcore polls; the telemetry listener thread sleeps in accept() on the socket file in /var/run/dpdk/ch13-tel/.' },
        { caption: 'The client calls connect(). accept() returns and the listener starts ONE new pthread for this connection (at most 10 at a time).',
          run: function (ctx, cur) {
            listener.rect.classList.add('svg-highlight');
            lsub.textContent = 'accept() -> pthread_create()';
            a3.style.opacity = 1;
            handler.style.opacity = 1;
            hsub.textContent = 'read() waits for a request';
            stClient.textContent = 'connected'; stConn.textContent = '1';
            fly(89, 152, 258, 142, 'conn', 'c6', cur);
            wire.textContent = 'client -> server: connect(AF_UNIX, SOCK_SEQPACKET, ".../dpdk_telemetry.v2")';
          } },
        { caption: 'The server speaks first: one message with the version, its pid and the largest reply it will ever send.',
          run: function (ctx, cur) {
            fly(445, 146, 89, 152, 'hello', 'c2', cur);
            stBytes.textContent = String(hello.length || 0);
            wire.textContent = 'server -> client (one recv), as printed by telclient.py:\n' + hello;
          } },
        { caption: 'The client sends the request "/ch13/stats" as one SEQPACKET message.',
          predict: { question: 'Which thread will run the tel_stats() callback?',
            options: ['the worker lcore, between two bursts', 'the client thread the listener just created', 'the main lcore'],
            answer: 1,
            explain: 'Callbacks run on the per-connection pthread. The lcores are never interrupted, which is why the callback must read their counters with atomics.' },
          run: function (ctx, cur) {
            fly(89, 152, 445, 146, '/ch13/stats', 'c3', cur);
            stClient.textContent = 'waiting for reply';
            wire.textContent = 'client -> server: "/ch13/stats"   (a parameter would follow a comma: "/ethdev/stats,0")';
          } },
        { caption: 'The handler splits the text at the first comma (cmd, params) and looks the command up in the sorted callback list, under a spinlock.',
          run: function () {
            handler.rect.classList.add('svg-highlight');
            hsub.textContent = 'lookup "/ch13/stats"';
            tbl.classList.add('svg-highlight');
            a4.style.opacity = 1;
            cmdT[1].classList.add('bold');
            cmdT[1].style.fill = CourseJS.cssVar('--accent');
          } },
        { caption: 'tel_stats() fills a struct rte_tel_data: a dict with nested port dicts. It reads the worker\'s counters with relaxed atomic loads while the worker keeps forwarding.',
          run: function () {
            dataBox.style.opacity = 1;
            a5.style.opacity = 1;
            dataT2.textContent = 'dict + uint values';
            dataT3.textContent = '+ 2 port containers';
            wsub.textContent = 'still polling (not stopped)';
          } },
        { caption: 'The library serialises the data to JSON and writes it with one write(): one recv() on the client gets the whole reply.',
          predict: { question: 'What would the client receive for the unknown command "/ch13/nothing"?',
            options: ['an error string such as "unknown command"', '{"/ch13/nothing": null}', 'the connection is closed'],
            answer: 1,
            explain: 'Unknown commands (and callbacks that return < 0) produce the command name with a null value. The connection stays open for the next request.' },
          run: function (ctx, cur) {
            fly(445, 146, 89, 152, 'JSON', 'c2', cur);
            stBytes.textContent = String(statsJson.length);
            stClient.textContent = 'got reply';
            wire.textContent = 'server -> client (real capture):\n' + statsJson + '\n\nand for an unknown command:\n' + nullJson;
          } }
      ]
    });
  }

  /* ------------------------------------------------------------------ */
  /* 2. Trace buffers                                                     */
  /* ------------------------------------------------------------------ */
  function traceWidget() {
    var root = $('w-trace');
    if (!root) return;
    var S = CourseJS.svg;
    var svg = root.querySelector('svg');
    var out = $('tr-out');
    var SIZE = { cfg: 48, burst: 16, str: 40 };   /* bytes incl. 8-byte header, padded */
    var ID = { cfg: 0, burst: 1, str: 2 };
    var NAME = { cfg: 'ch13.port_cfg', burst: 'ch13.burst', str: 'lib.eal.generic.string' };
    var CLS = { cfg: 'c1', burst: 'c3', str: 'c5' };
    var st;

    function reset() {
      var n = parseInt($('tr-size').value, 10);
      st = { n: n, tsc: 1000000, threads: [
        { name: 'main (trace_demo)', ev: [], head: 0, lost: 0, calls: 0 },
        { name: 'dpdk-worker1', ev: [], head: 0, lost: 0, calls: 0 }] };
      draw();
      out.textContent = 'Buffers reset (' + n + ' events each). Each thread writes only into its own buffer: no lock, no shared cache line.';
    }
    function draw() {
      S.clear(svg);
      var n = st.n, w = Math.min(50, 600 / n);
      st.threads.forEach(function (t, ti) {
        var y = 20 + ti * 92;
        S.text(svg, 10, y + 8, t.name, 'svg-label small bold');
        S.text(svg, 10, y + 74, 'stored ' + t.ev.filter(Boolean).length + '/' + n +
          '   overwritten/discarded ' + t.lost + '   calls ' + t.calls, 'svg-label small muted');
        for (var i = 0; i < n; i++) {
          var e = t.ev[i];
          var r = S.rect(svg, 100 + i * w, y + 16, w - 4, 40, 'svg-slot' + (e ? ' full' : ''));
          if (e) {
            r.setAttribute('class', 'svg-box ' + CLS[e.kind]);
            S.text(svg, 100 + i * w + (w - 4) / 2, y + 40, e.kind === 'burst' ? 'b' : e.kind === 'cfg' ? 'cfg' : 'str', 'svg-label center small');
          }
        }
        var hx = 100 + (t.head % n) * w + (w - 4) / 2;
        S.arrow(svg, hx, y + 70, hx, y + 60, 'accent');
      });
      S.text(svg, 100, 206, 'arrow = next write position; colour: blue slow path, orange fast path, purple generic', 'svg-label small muted');
    }
    function emit(kind, ti, count) {
      var fp = $('tr-fp').checked, mode = $('tr-mode').value;
      var t = st.threads[ti], msgs = [];
      for (var k = 0; k < count; k++) {
        t.calls++;
        st.tsc += 300 * 2.7 | 0;
        if (kind === 'burst' && !fp) { msgs.push('ch13.burst: compiled out (no RTE_ENABLE_TRACE_FP): the call is an empty inline function, nothing stored'); continue; }
        var full = t.ev.filter(Boolean).length >= st.n && t.head >= st.n;
        if (t.head >= st.n && mode === 'd') { t.lost++; msgs.push(NAME[kind] + ': buffer full, discard mode drops the NEW event'); continue; }
        var slot = t.head % st.n;
        if (t.ev[slot]) t.lost++;
        t.ev[slot] = { kind: kind, tsc: st.tsc };
        t.head++;
        var hdr = (BigInt(ID[kind]) << 48n) | (BigInt(st.tsc) & ((1n << 48n) - 1n));
        msgs.push(NAME[kind] + ' -> slot ' + slot + (full ? ' (overwrote the oldest)' : '') +
          ', header u64 = 0x' + hdr.toString(16).padStart(16, '0') + ' (id ' + ID[kind] + ' << 48 | tsc), ' + SIZE[kind] + ' bytes');
      }
      draw();
      out.textContent = msgs.slice(-4).join('\n');
    }
    root.querySelectorAll('[data-ev]').forEach(function (b) {
      b.addEventListener('click', function () {
        var ti = parseInt(b.getAttribute('data-th'), 10);
        emit(b.getAttribute('data-ev'), ti, b.textContent.indexOf('x4') >= 0 ? 4 : 1);
      });
    });
    $('tr-save').addEventListener('click', function () {
      var lines = ['rte_trace_save() -> <trace-dir>/<prefix>-<date>/', '  metadata      112293 bytes (TSDL text; size measured: 532 registered tracepoints)'];
      st.threads.forEach(function (t, i) {
        var bytes = 56;
        t.ev.forEach(function (e) { if (e) bytes += SIZE[e.kind]; });
        var kept = t.ev.filter(Boolean).sort(function (a, b) { return a.tsc - b.tsc; });
        lines.push('  channel0_' + i + '    ' + bytes + ' bytes = 56 (header+context) + ' + kept.length + ' events   [' + t.name + ']');
      });
      lines.push('Real run for comparison: trace_demo 144 B (2 events), trace_demo_fp 16144 B (1002 events).');
      out.textContent = lines.join('\n');
    });
    $('tr-reset').addEventListener('click', reset);
    $('tr-size').addEventListener('change', reset);
    $('tr-mode').addEventListener('change', reset);
    reset();
  }

  /* ------------------------------------------------------------------ */
  /* 3. Troubleshooting decision tree                                     */
  /* ------------------------------------------------------------------ */
  var TREE = {
    q: 'What do you see?',
    o: [
      ['The app starts but receives no packets', {
        q: 'Does /ethdev/stats,<port> show ipackets > 0?',
        o: [
          ['No, ipackets stays 0', {
            q: 'Is the port started and the link up? (/ethdev/info dev_started, /ethdev/link_status)',
            o: [
              ['No', { leaf: 'Start the port (ch8) and check the link: <code>rte_eth_link_get_nowait()</code>, LSC events (ch12). On tap, the kernel side must be up.' }],
              ['Yes', {
                q: 'Do ierrors or imissed grow when traffic arrives?',
                o: [
                  ['ierrors grows', { leaf: 'Frames are rejected by the PMD: too big for one mbuf without SCATTER (debug lab 2), bad CRC, wrong VLAN. Compare MTU, <code>rx_mbuf_size_min</code> and <code>rx_offloads</code> in /ethdev/info; read xstats for the exact error counter.' }],
                  ['imissed grows', { leaf: 'The RX ring overflows: nobody polls this queue, or not fast enough. Check that an lcore was launched for it and polls the right port/queue (/eal/lcore/usage).' }],
                  ['Neither', { leaf: 'Frames are filtered before any counter: destination MAC unknown with promiscuous off (debug lab 1), VLAN filter, or traffic goes to another port (check devargs and port ids, ch9). /ethdev/info promiscuous, /ethdev/macs.' }]
                ] }]
            ] }],
          ['Yes, but my app counts nothing', {
            leaf: 'You poll a different port/queue than the one receiving, or another lcore polls the same queue and steals the packets (debug lab 5). One queue = one lcore.' }]
        ] }],
      ['Traffic flows, then stops', {
        q: 'Is in_use of the mbuf pool (rte_mempool_in_use_count, /mempool/info) climbing towards its size?',
        o: [
          ['Yes', { leaf: 'A leak: a drop path that does not free, unsent TX leftovers not freed (debug lab 3). If in_use is LOWER than what you hold, suspect a double free (debug lab 4). Audit at a quiet moment.' }],
          ['No', {
            q: 'Does rx_nombuf grow?',
            o: [
              ['Yes', { leaf: 'The pool is too small for RX rings + caches + packets in flight. Size it as in ch6/ch8 (n &ge; ports &times; (rx_desc + tx_desc) + lcores &times; (cache + burst)).' }],
              ['No', { leaf: 'An lcore is stuck: keepalive (ch11) tells you which; attach gdb and run <code>thread apply all bt</code> (section 7).' }]
            ] }]
        ] }],
      ['Packets are dropped or the rate is too low', {
        q: 'Where are the drops counted?',
        o: [
          ['imissed / rx_missed_errors', { leaf: 'RX ring overflow: the lcore is too slow. Measure busy cycles (/eal/lcore/usage), check per-burst work (trace it), raise the burst size, add queues and lcores (ch15).' }],
          ['tx_burst returns less than asked', { leaf: 'TX ring full: the link or the peer is slower. Retry a bounded number of times, then free and count (ch8). Check link speed and tx descriptors.' }],
          ['an rte_ring between stages is full', { leaf: 'The consumer stage is the bottleneck: compare enqueue failures with the consumer lcore\'s busy ratio (ch5, ch15).' }],
          ['my own drop counter', { leaf: 'Your logic drops them: record why with a tracepoint (section 4) and look at the event order.' }]
        ] }],
      ['Counters do not add up, or change from run to run', {
        leaf: 'A data race: two lcores on one queue (debug lab 5), or shared counters written by several lcores without atomics (ch14). Give each lcore its own queue and its own statistics.' }],
      ['The process crashed', {
        q: 'Is there a core file?',
        o: [
          ['No', { leaf: '<code>ulimit -c</code> is 0, or <code>core_pattern</code> pipes to systemd-coredump (<code>coredumpctl list</code>), or no space. See section 8.' }],
          ['Yes, but mbufs look all-zero', { leaf: 'coredump_filter lacks bit 6 (hugetlb shared): gdb fills undumped memory with zeros. Restart with 0x73 and reproduce.' }],
          ['Yes, it looks sane', { leaf: '<code>bt</code>, <code>frame</code>, <code>p *m</code>; check the mbuf with <code>rte_mbuf_check()</code>; rebuild your app with ASan and <code>-DRTE_LIBRTE_MBUF_DEBUG</code> and reproduce.' }]
        ] }],
      ['It does not even start', { leaf: 'Decode the message with the error table in section 10 (EAL, memory, port init, tools).' }]
    ]
  };
  function treeWidget() {
    var root = $('w-tree');
    if (!root) return;
    var path = [];
    function render() {
      var node = TREE, crumbs = [];
      path.forEach(function (i) { crumbs.push(node.o[i][0]); node = node.o[i][1]; });
      $('tree-path').innerHTML = crumbs.length ? 'Path: ' + crumbs.map(esc).join(' &rarr; ') : 'Start here.';
      var opts = $('tree-opts'), leaf = $('tree-leaf');
      opts.innerHTML = ''; leaf.innerHTML = '';
      if (node.leaf) {
        $('tree-q').textContent = 'Check and fix:';
        leaf.innerHTML = '<div class="tree-leaf">' + node.leaf + '</div>';
      } else {
        $('tree-q').textContent = node.q;
        node.o.forEach(function (o, i) {
          var b = document.createElement('button');
          b.className = 'btn small'; b.type = 'button'; b.textContent = o[0];
          b.addEventListener('click', function () { path.push(i); render(); });
          opts.appendChild(b);
        });
      }
      if (path.length) {
        var back = document.createElement('button');
        back.className = 'btn small'; back.type = 'button'; back.textContent = '← back';
        back.addEventListener('click', function () { path.pop(); render(); });
        var re = document.createElement('button');
        re.className = 'btn small'; re.type = 'button'; re.textContent = 'start over';
        re.addEventListener('click', function () { path = []; render(); });
        opts.appendChild(back); opts.appendChild(re);
      }
    }
    render();
  }

  /* ------------------------------------------------------------------ */
  /* 4. Core-dump explorer                                                */
  /* ------------------------------------------------------------------ */
  function coreWidget() {
    var root = $('w-core');
    if (!root) return;
    var BITS = [
      [0, 'anon private'], [1, 'anon shared'], [2, 'file-backed private'], [3, 'file-backed shared'],
      [4, 'ELF headers'], [5, 'hugetlb private'], [6, 'hugetlb shared'], [7, 'DAX private'], [8, 'DAX shared']];
    function bitOf(cls) {
      if (/dd\)/.test(cls)) return -1;
      if (/^anon private/.test(cls)) return 0;
      if (/^anon shared/.test(cls)) return 1;
      if (/^file private/.test(cls)) return 2;
      if (/^file shared/.test(cls)) return 3;
      if (/^hugetlb private/.test(cls)) return 5;
      if (/^hugetlb shared/.test(cls)) return 6;
      return 0;
    }
    function parseMaps(txt) {
      var rows = [];
      (txt || '').split('\n').forEach(function (l) {
        var m = l.match(/^\s+(.+?)\s+(\d+) mappings\s+([\d.]+) MB/);
        if (m) rows.push({ cls: m[1], n: +m[2], mb: +m[3], bit: bitOf(m[1]) });
      });
      return rows;
    }
    var MAPS = { huge: parseMaps(D.maps_huge), nohuge: parseMaps(D.maps_nohuge) };
    var CORES = {};
    (D.cores || '').split('\n').forEach(function (l) {
      var m = l.match(/^\s+([A-D]) filter=(0x[0-9a-f]+)\s+core apparent\s+([\d.]+) MB, on disk\s+([\d.]+) MB/);
      if (m) CORES[m[1]] = { filter: parseInt(m[2], 16), app: m[3], disk: m[4] };
    });
    function measured(mode, f) {
      var want = mode === 'huge' ? ['A', 'B', 'C'] : ['D'];
      for (var i = 0; i < want.length; i++)
        if (CORES[want[i]] && CORES[want[i]].filter === f) return want[i];
      return null;
    }
    var bitsBox = $('core-bits');
    BITS.forEach(function (b) {
      var lab = document.createElement('label');
      lab.innerHTML = '<input type="checkbox" data-bit="' + b[0] + '"> bit ' + b[0] + ': ' + esc(b[1]);
      bitsBox.appendChild(lab);
    });
    function filter() {
      var f = 0;
      bitsBox.querySelectorAll('input').forEach(function (c) { if (c.checked) f |= 1 << +c.getAttribute('data-bit'); });
      return f;
    }
    function setFilter(f) {
      bitsBox.querySelectorAll('input').forEach(function (c) { c.checked = !!(f & (1 << +c.getAttribute('data-bit'))); });
      update();
    }
    function mode() { return root.querySelector('input[name=core-mode]:checked').value; }
    function update() {
      var f = filter(), md = mode(), rows = MAPS[md];
      $('core-hex').textContent = '0x' + f.toString(16);
      var html = '<thead><tr><th>mapping class (from smaps)</th><th class="num">mappings</th><th class="num">size MB</th><th>needs</th><th>in core?</th></tr></thead><tbody>';
      var dpdkIn = false;
      rows.forEach(function (r) {
        var inc = r.bit >= 0 && !!(f & (1 << r.bit));
        if ((md === 'huge' && r.bit === 6) || (md === 'nohuge' && r.bit === 1 && /memfd/.test(r.cls))) dpdkIn = inc;
        html += '<tr><td>' + esc(r.cls) + '</td><td class="num">' + r.n + '</td><td class="num">' + r.mb.toFixed(1) +
          '</td><td>' + (r.bit < 0 ? 'never (MADV_DONTDUMP)' : 'bit ' + r.bit) + '</td><td class="' + (inc ? 'in' : 'out') + '">' +
          (inc ? 'written' : 'skipped') + '</td></tr>';
      });
      $('core-table').innerHTML = html + '</tbody>';
      var m = measured(md, f), v = $('core-verdict'), g = $('core-gdb');
      var dpdkName = md === 'huge' ? 'hugetlb shared' : 'the --no-huge memfd (anon shared)';
      v.className = 'verdict ' + (dpdkIn ? 'ok' : 'bad');
      v.innerHTML = (dpdkIn ? 'DPDK memory (' + dpdkName + ') is written: <strong>p *m works</strong>.' :
        'DPDK memory (' + dpdkName + ') is NOT written: gdb shows zeros for mbufs, then "Cannot access memory".') +
        (m ? ' Measured core ' + m + ': ' + CORES[m].app + ' MB apparent, ' + CORES[m].disk + ' MB on disk (sparse).' :
          ' This exact setting was not measured on the course VM (measured: 0x33, 0x73, 0x7f with hugepages; 0x33 with --no-huge).');
      g.textContent = m ? ('gdb on core ' + m + ' (real output):\n' + (D['gdb_' + m] || '').replace(/^-- core [A-D]\n/, '')) : '(no captured gdb run for this setting)';
    }
    bitsBox.addEventListener('change', update);
    root.querySelectorAll('input[name=core-mode]').forEach(function (r) { r.addEventListener('change', update); });
    $('core-def').addEventListener('click', function () { setFilter(0x33); });
    $('core-rec').addEventListener('click', function () { setFilter(0x73); });
    setFilter(0x33);
  }

  /* ------------------------------------------------------------------ */
  /* 5. Debug lab triage                                                  */
  /* ------------------------------------------------------------------ */
  var LABS = [
    { key: 'promisc', title: '1 promisc_off',
      story: 'The upstream router sends every frame to our service MAC 02:13:00:00:00:fe (from the kernel side of ch13tap1). The app receives almost nothing.',
      causes: ['The tap interface is down, so the kernel never sends',
               'The port\'s receive filter drops frames for a MAC it was never told about, because promiscuous mode is off',
               'The RX ring overflows because the loop is too slow',
               'The mbuf pool is empty'],
      right: 1,
      why: 'ipackets is tiny (only the broadcasts arrive), ierrors and imissed are 0, /ethdev/info says promiscuous: 0, and /ethdev/macs lists only the port\'s own MAC. Nothing is counted as an error because filtering is not an error. Fix: <code>rte_eth_dev_mac_addr_add(port, &amp;svc, 0)</code> (or promiscuous mode).' },
    { key: 'mtu', title: '2 mtu_noscatter',
      story: 'The network now carries 9000-byte jumbo frames. The kernel side of ch13tap2 sends ten of them; the app sees none.',
      causes: ['The kernel never sent them',
               'They do not fit in one 2 KB mbuf, SCATTER is off and the MTU is 1500: the PMD drops them and counts ierrors',
               'They are dropped by the MAC filter',
               'The RX ring overflows (imissed)'],
      right: 1,
      why: 'ierrors = 10 (one per frame), imissed = 0, mtu 1500, scattered_rx 0, rx_offloads empty. Fix: <code>rxmode.mtu = 9000</code> and <code>RTE_ETH_RX_OFFLOAD_SCATTER</code> (after checking rx_offload_capa): each frame then arrives as a chain of 5 mbufs.' },
    { key: 'leak', title: '3 leak',
      story: 'A filter now forwards only IPv4 and drops the rest. Right after start the forwarder stops: rx stays at 8160 forever.',
      causes: ['net_null stopped producing packets',
               'The dropped mbufs are never freed: the pool is empty, so the PMD cannot allocate and RX returns 0',
               'The TX ring is full',
               'The lcore crashed'],
      right: 1,
      why: 'in_use = 8160 = exactly the number received; common_pool_count is stuck at 31 (less than one burst of 32), ipackets is frozen. net_null does not count rx_nombuf, a real NIC would. Fix: <code>rte_pktmbuf_free()</code> on the drop path.' },
    { key: 'dfree', title: '4 double_free',
      story: 'Every 100th packet is malformed and takes an error path. Later, some packets carry another packet\'s data, and the pool is short of mbufs.',
      causes: ['A plain leak',
               'The error path frees the mbuf and the cleanup label frees it again: the pool holds the same pointer twice',
               'A reference count overflow',
               'The per-lcore cache hides objects'],
      right: 1,
      why: 'rte_mbuf_check() is happy (a freed mbuf keeps refcnt 1). But in_use is 190 while 200 are held, the pool ring holds 321 entries for 311 free objects, and the audit finds 10 duplicate pointers and 64 missing mbufs (a whole bulk put was dropped when the ring was full). Fix: free in exactly one place.' },
    { key: 'twolc', title: '5 two_lcores_one_queue',
      story: 'To "use more cores", the forwarding function was launched on two lcores. 256 frames circulate on a net_ring loopback. The counters do not add up.',
      causes: ['net_ring statistics are approximate by design',
               'Both lcores poll and transmit on the same queue, whose ring is single-producer/single-consumer: mbufs are duplicated or lost and the PMD\'s plain counters lose updates',
               'lcore 2 was never started',
               'The pool is too small'],
      right: 1,
      why: 'The app counted more RX than the PMD, after the run the queue gives back 0 (or thousands of duplicates: it changes from run to run) and 256 mbufs are stuck in use. Fix: one queue per lcore (here one port pair each; with a NIC, RSS and one queue per lcore, ch15).' }
  ];
  function labWidget() {
    var root = $('w-lab');
    if (!root) return;
    var pick = $('lab-pick'), cur = 0;
    LABS.forEach(function (l, i) {
      var b = document.createElement('button');
      b.className = 'btn small'; b.type = 'button'; b.textContent = l.title;
      b.addEventListener('click', function () { show(i); });
      pick.appendChild(b);
    });
    function show(i) {
      cur = i;
      var l = LABS[i], d = D['lab_' + l.key] || {};
      pick.querySelectorAll('.btn').forEach(function (b, k) { b.classList.toggle('sel', k === i); });
      $('lab-story').textContent = l.story;
      $('lab-symptom').textContent = (d.cmd ? d.cmd + '\n' : '') + (d.symptom || '');
      var dg = $('lab-diags'); dg.innerHTML = '';
      $('lab-diag-out').textContent = '(choose a command)';
      (d.diags || []).forEach(function (x, k) {
        var b = document.createElement('button');
        b.className = 'btn small'; b.type = 'button';
        b.textContent = x[0].replace(/^python3 -I \.\.\/tq\.py \S+ /, 'telemetry ');
        b.title = x[0];
        b.addEventListener('click', function () {
          dg.querySelectorAll('.btn').forEach(function (bb) { bb.classList.remove('sel'); });
          b.classList.add('sel');
          $('lab-diag-out').textContent = '$ ' + x[0] + '\n' + x[1];
        });
        dg.appendChild(b);
      });
      var cs = $('lab-causes'); cs.innerHTML = '';
      $('lab-reveal').innerHTML = '';
      l.causes.forEach(function (c, k) {
        var b = document.createElement('button');
        b.className = 'btn small'; b.type = 'button'; b.textContent = c;
        b.addEventListener('click', function () { answer(k); });
        cs.appendChild(b);
      });
    }
    function answer(k) {
      var l = LABS[cur], d = D['lab_' + l.key] || {};
      $('lab-causes').querySelectorAll('.btn').forEach(function (b, j) {
        b.classList.remove('right', 'wrong');
        if (j === l.right) b.classList.add('right');
        else if (j === k) b.classList.add('wrong');
      });
      var ok = k === l.right;
      $('lab-reveal').innerHTML = '<div class="verdict ' + (ok ? 'ok' : 'bad') + '">' +
        (ok ? 'Right. ' : 'Not quite. ') + l.why + '</div>' +
        '<div class="tree-q">The fixed version (real output)</div><div class="mono-out">' + esc((d.fixed || '') + (d.extra ? '\n\n' + d.extra : '')) + '</div>';
    }
    show(0);
  }

  /* ------------------------------------------------------------------ */
  /* 6. Error decoder + table                                             */
  /* ------------------------------------------------------------------ */
  function errWidget() {
    var rows = D.errors || [];
    var tb = document.querySelector('#err-table tbody');
    if (tb) {
      tb.innerHTML = rows.map(function (r) {
        return '<tr><td>' + esc(r.msg) + '</td><td>' + r.cause + '</td><td>' + r.fix + '</td><td>' + r.from + '<br><span class="muted small">' + esc(r.phase) + '</span></td></tr>';
      }).join('');
    }
    var sel = $('err-pick'), ta = $('err-text'), outEl = $('err-out');
    if (!sel) return;
    sel.innerHTML = '<option value="">... or pick a known message</option>' + rows.map(function (r, i) {
      return '<option value="' + i + '">' + esc(r.from + ': ' + (r.msg.length > 70 ? r.msg.slice(0, 70) + '...' : r.msg)) + '</option>';
    }).join('');
    function norm(s) { return s.toLowerCase().replace(/0x[0-9a-f]+|\d+/g, '#').replace(/'[^']*'|"[^"]*"/g, '?').replace(/\s+/g, ' ').trim(); }
    function words(s) { return norm(s).split(/[^a-z#?_]+/).filter(function (w) { return w.length > 2; }); }
    function decode(text) {
      var tw = words(text);
      if (!tw.length) { outEl.innerHTML = '<dt>Nothing to decode</dt><dd>Paste a line of output.</dd>'; return; }
      var best = -1, score = 0;
      rows.forEach(function (r, i) {
        var rw = words(r.msg), hit = 0;
        rw.forEach(function (w) { if (tw.indexOf(w) >= 0) hit++; });
        var s = hit / Math.max(rw.length, 1) + (norm(text).indexOf(norm(r.msg).slice(0, 25)) >= 0 ? 1 : 0);
        if (s > score) { score = s; best = i; }
      });
      if (best < 0 || score < 0.34) {
        outEl.innerHTML = '<dt>No match</dt><dd>Not in the table. Re-run with <code>--log-level=lib.eal:debug</code> (or <code>pmd.net.*:debug</code>) to see the step that fails, and check ch16 for multi-process errors.</dd>';
        return;
      }
      var r = rows[best];
      outEl.innerHTML = '<dt>Best match (' + r.from + ', ' + esc(r.phase) + ')</dt><dd><code>' + esc(r.msg) + '</code></dd>' +
        '<dt>Cause</dt><dd>' + r.cause + '</dd><dt>Fix</dt><dd>' + r.fix + '</dd>';
    }
    $('err-go').addEventListener('click', function () { decode(ta.value); });
    sel.addEventListener('change', function () {
      if (sel.value === '') return;
      ta.value = rows[+sel.value].msg;
      decode(ta.value);
    });
  }

  /* ------------------------------------------------------------------ */
  /* 7. Fill the RTE_LOG_DP table from the measured output                */
  /* ------------------------------------------------------------------ */
  function logdpTable() {
    var lines = (D.logdp || '').split('\n').slice(1);
    lines.forEach(function (l, i) {
      var m = l.match(/([\d.]+) \[([\d.]+)\.\.([\d.]+)\]/);
      var cell = $('logdp-' + (i + 1));
      if (m && cell) cell.textContent = m[1] + ' [' + m[2] + '..' + m[3] + ']';
    });
  }

  CourseJS.ready(function () {
    telWidget();
    traceWidget();
    treeWidget();
    coreWidget();
    labWidget();
    errWidget();
    logdpTable();
  });
})();

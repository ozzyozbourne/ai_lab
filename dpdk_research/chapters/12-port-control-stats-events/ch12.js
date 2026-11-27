/* Chapter 12 widgets (vanilla JS on top of ../../assets/course.js).
 *  1. w-cb    RX/TX callback chain        Stepper with predict
 *  2. w-evt   event flow                  Animator + buttons
 *  3. w-qx    queue and port state explorer (predict OK / -EBUSY / -ENOTSUP)
 *  4. w-bond  bonding mode selector       Animator, real bonding hashes
 *  5. w-fail  failure signature board     counters per seeded fault + recovery
 * Colours only through CSS classes / variables (light and dark themes). */
(function () {
  'use strict';
  var S = CourseJS.svg;
  function $(id) { return document.getElementById(id); }
  function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }

  /* ==================================================================
   * 1. Callback chain inside rte_eth_rx_burst / rte_eth_tx_burst
   * ================================================================ */
  function cbChain() {
    var root = $('w-cb');
    if (!root) return;
    var svg = root.querySelector('svg');
    var X = { app: 60, pmd: 170, A: 290, B: 380, C: 470, out: 590 };
    // static frame
    S.box(svg, 10, 20, 100, 44, 'application', 'c1');
    S.text(svg, 60, 78, 'rx_burst(p0,q0)', 'svg-label small center mono');
    S.box(svg, 125, 20, 90, 44, 'PMD rx', 'c4');
    var bA = S.box(svg, 245, 20, 90, 44, 'A first_rx', 'c5');
    var bB = S.box(svg, 340, 20, 80, 44, 'B count', 'c5');
    var bC = S.box(svg, 425, 20, 90, 44, 'C stamp', 'c5');
    S.box(svg, 545, 20, 90, 44, 'app gets n', 'c1');
    S.arrow(svg, 110, 42, 123, 42, 'c7');
    S.arrow(svg, 215, 42, 243, 42, 'c7');
    S.arrow(svg, 335, 42, 338, 42, 'c7');
    S.arrow(svg, 420, 42, 423, 42, 'c7');
    S.arrow(svg, 515, 42, 543, 42, 'c7');
    S.text(svg, 380, 12, 'inside rte_eth_rx_burst(): callback list of (port 0, queue 0)', 'svg-label small center muted');
    // TX row
    S.box(svg, 10, 130, 100, 44, 'app work', 'c1');
    var bT = S.box(svg, 245, 130, 120, 44, 'T latency', 'c5');
    S.box(svg, 425, 130, 90, 44, 'PMD tx', 'c4');
    S.box(svg, 545, 130, 90, 44, 'wire / ring', 'c7');
    S.arrow(svg, 110, 152, 243, 152, 'c7');
    S.arrow(svg, 365, 152, 423, 152, 'c7');
    S.arrow(svg, 515, 152, 543, 152, 'c7');
    S.text(svg, 330, 122, 'inside rte_eth_tx_burst(p1,q0): TX callbacks run BEFORE the PMD', 'svg-label small center muted');
    var info = S.text(svg, 320, 208, '', 'svg-label small center');
    var counter = S.text(svg, 380, 78, '', 'svg-label small center mono');
    var lat = S.text(svg, 305, 190, '', 'svg-label small center mono');
    var pk = [];
    for (var i = 0; i < 4; i++) {
      var p = S.packet(svg, -40, -40, 20, 13, '', '');
      p.stamp = S.text(svg, -40, -40, '', 'svg-label small center mono');
      pk.push(p);
    }
    function place(x, y) {
      pk.forEach(function (p, k) { S.moveTo(p, x - 27 + k * 18, y); p.stamp.setAttribute('x', x - 27 + k * 18); p.stamp.setAttribute('y', y + 16); });
    }
    function hl(b, on) { b.rect.classList.toggle('svg-highlight', !!on); }
    new CourseJS.Stepper(root, {
      reset: function () {
        place(-100, -100);
        [bA, bB, bC, bT].forEach(function (b) { hl(b, false); });
        pk.forEach(function (p) { p.stamp.textContent = ''; p.body.classList.remove('dropped'); });
        info.textContent = 'registered: add_rx_callback(B), add_rx_callback(C), add_first_rx_callback(A); add_tx_callback(T) on port 1';
        counter.textContent = 'bursts=0';
        lat.textContent = '';
      },
      steps: [
        { caption: 'The app calls <code>rte_eth_rx_burst(0, 0, pkts, 32)</code>. Callbacks are a per-queue linked list kept by ethdev.' },
        { caption: 'The PMD fills the burst first: 4 packets. Callbacks only ever see what the driver already returned.',
          run: function () { place(170, 100); } },
        { caption: 'A runs first: <code>rte_eth_add_first_rx_callback()</code> puts it at the head of the list.',
          predict: { question: 'Registration order was B, C (add_rx_callback), then A (add_first_rx_callback). Which callback runs first?', options: ['A', 'B', 'C'], answer: 0,
            explain: 'add_rx_callback appends to the tail; add_first_rx_callback inserts at the head. The program printed the order <code>ABCT</code>.' },
          run: function (c) { place(290, 100); hl(bA, true); } },
        { caption: 'B counts bursts. Its return value becomes the new burst size for the next callback and the app.',
          run: function () { place(380, 100); hl(bB, true); counter.textContent = 'bursts=1'; } },
        { caption: 'C writes <code>rte_rdtsc()</code> into a private mbuf dynamic field (registered with <code>rte_mbuf_dynfield_register()</code>).',
          run: function () { place(470, 100); hl(bC, true); pk.forEach(function (p) { p.stamp.textContent = 't0'; }); } },
        { caption: 'rx_burst returns 4 to the app. The app now does W cycles of work per packet, for the whole burst.',
          run: function () { place(60, 100); } },
        { caption: 'The app calls tx_burst on port 1. T runs before the PMD and computes now - t0 for each packet.',
          predict: { question: 'W = 2000 cycles per packet, burst of 32. Roughly what latency does T report per packet?', options: ['about 2,000 cycles', 'about 33,000 cycles (half the burst)', 'about 64,000 cycles (the whole burst)'], answer: 2,
            explain: 'T runs only when the whole burst is handed to tx_burst, so every packet waited for all 32 packets of work: measured median 67,436 cycles = 2000 x 32 + ~2,200 overhead.' },
          run: function () { place(305, 155); hl(bT, true); lat.textContent = 'latency = now - t0  (67,436 cycles measured)'; } },
        { caption: 'The PMD sends what T returned. A callback may also drop packets: free some and return a smaller n.',
          run: function () { place(470, 155); } }
      ]
    });
  }

  /* ==================================================================
   * 2. Event flow: data path keeps polling, events run in other threads
   * ================================================================ */
  function evtFlow() {
    var root = $('w-evt');
    if (!root) return;
    var svg = root.querySelector('svg');
    var log = $('evt-log');
    var lanes = [
      { y: 30, name: 'lcore 1: rx/tx loop', c: 'c1' },
      { y: 75, name: 'lcore 2: rx/tx loop', c: 'c1' },
      { y: 130, name: 'dpdk-intr thread', c: 'c6' },
      { y: 175, name: 'main / control', c: 'c7' }
    ];
    lanes.forEach(function (l) {
      S.rect(svg, 165, l.y - 16, 465, 32, 'svg-box ' + l.c);
      S.text(svg, 157, l.y + 4, l.name, 'svg-label small mono').setAttribute('text-anchor', 'end');
    });
    var dots = [];
    for (var i = 0; i < 8; i++) {
      dots.push({ el: S.packet(svg, 0, -50, 12, 8, '', ''), lane: i % 2, x: 160 + i * 60 });
    }
    var cbBox = S.box(svg, 420, 117, 200, 26, '', 'c5');
    cbBox.rect.classList.add('svg-hidden');
    cbBox.rect.classList.add('svg-fade');
    var warn = S.text(svg, 390, 207, '', 'svg-label small center bold');
    var tokens = [];
    var stats = { evt: 0, polled: 0 };
    function addLog(s, cls) {
      var li = document.createElement('li');
      li.innerHTML = s;
      if (cls) li.className = cls;
      log.insertBefore(li, log.firstChild);
      while (log.children.length > 6) log.removeChild(log.lastChild);
    }
    function fire(kind) {
      var lane = (kind === 'NEW' || kind === 'DESTROY') ? 3 : 2;
      var x0 = 200;
      tokens.forEach(function (t) { if (t.lane === lane && t.x - 70 < x0) x0 = t.x - 70; });
      var tk = S.packet(svg, x0, lanes[lane].y, 56, 18, lane === 3 ? 'c2' : 'c5', kind);
      tokens.push({ el: tk, x: x0, lane: lane, kind: kind, done: false });
    }
    var anim = new CourseJS.Animator({
      root: root, autoplay: 'visible',
      onReset: function () {
        tokens.forEach(function (t) { t.el.remove(); });
        tokens = [];
        stats.evt = 0; stats.polled = 0;
        warn.textContent = '';
        if (log) log.innerHTML = '';
      },
      onFrame: function (dt) {
        dots.forEach(function (d) {
          d.x += dt * 160;
          if (d.x > 620) { d.x = 175; stats.polled++; }
          S.moveTo(d.el, d.x, lanes[d.lane].y);
          d.el.style.opacity = d.x < 175 ? 0 : 1;
        });
        tokens = tokens.filter(function (t) { return !t.done; });
        tokens.forEach(function (t) {
          t.x += dt * 140;
          if (t.x > 400 && !t.ran) {
            t.ran = true;
            stats.evt++;
            cbBox.rect.classList.remove('svg-hidden');
            cbBox.label.textContent = 'on_event(' + t.kind + ')';
            var thr = t.lane === 3 ? 'main (the thread that called probe/close)' : (t.kind === 'LSC*' ? 'dpdk-vhost-evt' : 'dpdk-intr');
            if (t.kind === 'UNSAFE') {
              warn.textContent = 'rte_eth_dev_close() on the port that raised the event, from its own callback: not allowed';
              warn.setAttribute('class', 'svg-label small center bold svg-fill-c4');
              addLog('<b>UNSAFE</b>: closing a port inside its own callback can deadlock or free memory the callback list is still walking. Defer with <code>rte_eal_alarm_set()</code>.', 'bad');
            } else if (t.kind === 'ALARM') {
              warn.textContent = 'deferred work runs later, outside any callback: safe to stop/close/reconfigure';
              warn.setAttribute('class', 'svg-label small center bold svg-fill-c2');
              addLog('alarm fired in <b>dpdk-intr</b>: deferred work may now call control-path APIs.');
            } else {
              warn.textContent = '';
              addLog('<b>' + t.kind + '</b> callback ran in <b>' + thr + '</b>; lcores 1 and 2 kept polling.');
            }
          }
          if (t.x > 620) {
            t.done = true;
            t.el.remove();
          } else {
            S.moveTo(t.el, t.x, lanes[t.lane].y);
            t.el.style.opacity = t.x < 200 ? 0 : 1;
          }
        });
        $('evt-n').textContent = stats.evt;
        $('evt-p').textContent = stats.polled;
      }
    });
    root.querySelectorAll('[data-evt]').forEach(function (b) {
      b.addEventListener('click', function () { fire(b.getAttribute('data-evt')); if (!anim.running) anim.play(); });
    });
  }

  /* ==================================================================
   * 3. Queue and port state explorer
   *    Results come from queue_ctl / runtime_reconf / port_ctl output
   *    ("probed") or from the PMD's eth_dev_ops table ("source").
   * ================================================================ */
  var PMD = {
    tap:  { name: 'net_tap', qStart: true, deferredHonoured: false, deferredSetup: true, runtimeCapa: false, mtu: 'OK', reta: '-ENOTSUP', mac: 'OK', outage: '214.5 us median (tap, stop+configure+setup+start)', stateWrite: true },
    pcap: { name: 'net_pcap', qStart: true, deferredHonoured: false, deferredSetup: true, runtimeCapa: false, mtu: '-ENOTSUP', reta: '-ENOTSUP', mac: '-ENOTSUP', src: true, outage: 'not measured', stateWrite: true },
    null: { name: 'net_null', qStart: false, deferredHonoured: false, deferredSetup: false, runtimeCapa: false, mtu: 'OK', reta: 'OK', mac: 'OK', outage: '10.4 us median (null)', stateWrite: true },
    ring: { name: 'net_ring', qStart: false, deferredHonoured: false, deferredSetup: false, runtimeCapa: false, mtu: '-ENOTSUP', reta: '-ENOTSUP', mac: '-ENOTSUP', outage: 'not measured', stateWrite: false },
    fs:   { name: 'net_failsafe (over net_tap)', qStart: true, deferredHonoured: true, deferredSetup: true, runtimeCapa: true, mtu: 'OK', reta: '-ENOTSUP', mac: 'OK', src: true, outage: 'not measured', stateWrite: true }
  };
  function qExplorer() {
    var root = $('w-qx');
    if (!root) return;
    var svg = root.querySelector('svg');
    var sel = $('qx-pmd'), pred = $('qx-predict'), out = $('qx-out'), choice = $('qx-choice');
    var st, pending = null;
    var stateNames = ['UNCONFIGURED', 'CONFIGURED', 'STARTED', 'STOPPED'];
    var boxes = [], qbox = [], qlbl = [];
    stateNames.forEach(function (n, i) {
      boxes.push(S.box(svg, 10 + i * 160, 14, 140, 34, n, 'c7'));
      if (i < 3) S.arrow(svg, 150 + i * 160, 31, 168 + i * 160, 31, 'c7');
    });
    S.text(svg, 330, 66, 'RX queues (rxq_state as ethdev records it)', 'svg-label small center muted');
    for (var q = 0; q < 2; q++) {
      qbox.push(S.rect(svg, 150 + q * 200, 78, 160, 40, 'svg-box c5'));
      qlbl.push(S.text(svg, 230 + q * 200, 98, '', 'svg-label small center mono'));
    }
    var gapBar = S.rect(svg, 10, 132, 0, 14, 'svg-box c4');
    var gapTxt = S.text(svg, 10, 160, '', 'svg-label small');
    function resetState() {
      st = { port: 0, q: [{ setup: false, def: false, s: 0 }, { setup: false, def: false, s: 0 }] };
      gapBar.setAttribute('width', 0); gapTxt.textContent = '';
      draw();
    }
    function draw() {
      boxes.forEach(function (b, i) { b.rect.classList.toggle('svg-highlight', i === st.port); });
      var p = PMD[sel.value];
      st.q.forEach(function (qq, i) {
        var s;
        if (!qq.setup) s = 'q' + i + ': not set up';
        else if (st.port !== 2) s = 'q' + i + ': set up' + (qq.def ? ' (deferred)' : '');
        else if (!p.stateWrite) s = 'q' + i + ': state 0 (never written)';
        else s = 'q' + i + ': ' + (qq.s ? 'STARTED' : 'STOPPED') + (qq.def ? ' [def]' : '');
        qlbl[i].textContent = s;
        qbox[i].setAttribute('class', 'svg-box ' + (qq.setup && st.port === 2 && qq.s && p.stateWrite ? 'c2' : (qq.setup ? 'c5' : 'c7')));
      });
    }
    // returns [rc, explanation, mutate()]
    function evaluate(api) {
      var p = PMD[sel.value], started = st.port === 2, q1 = st.q[1];
      switch (api) {
      case 'configure':
        if (started) return ['-EBUSY', 'rte_eth_dev_configure() on a started port: "Port N must be stopped to allow configuration". Changing queue count or offloads needs stop, configure, start.'];
        return ['OK', 'Port configured with 2 RX and 2 TX queues. Every queue must be set up again after configure.', function () { st.port = 1; st.q.forEach(function (x) { x.setup = false; x.def = false; }); }];
      case 'setup0':
        if (st.port === 0) return ['(crash or -EINVAL)', 'Queue setup before configure: on net_null it crashes (ch08 lifecycle_rules), on net_tap it returns -EINVAL. Always configure first.'];
        if (started) return ['-EBUSY', 'q0 is started and the PMD lacks RUNTIME_RX_QUEUE_SETUP for a started queue.'];
        return ['OK', 'q0 set up.', function () { st.q[0].setup = true; }];
      case 'setup1def':
        if (st.port === 0) return ['(crash or -EINVAL)', 'Configure first.'];
        if (started) return ['-EBUSY', 'Started port: setup needs RUNTIME_RX_QUEUE_SETUP and a stopped queue.'];
        if (!p.deferredSetup) return ['-ENOTSUP', '"Deferred start requested, but driver does not support Rx queue start": ethdev refuses rx_deferred_start=1 when the PMD has no rx_queue_start op (probed on net_null and net_ring). q1 stays NOT set up, yet dev_start still succeeds.'];
        return ['OK', 'q1 set up with rx_deferred_start = 1.', function () { q1.setup = true; q1.def = true; }];
      case 'start':
        if (st.port === 0) return ['-EINVAL', 'Not configured.'];
        if (started) return ['OK', 'Already started: ethdev logs and returns 0.'];
        return ['OK', p.deferredHonoured ? 'Started. This PMD honours rx_deferred_start: q1 stays STOPPED (probed: failsafe rxq_state [1,0]).' :
          (p.stateWrite ? 'Started. This PMD marks EVERY queue started and ignores rx_deferred_start (probed: tap and pcap rxq_state [1,1]).' : 'Started. net_ring never writes rxq_state on start (probed: [0,0]); queue state is meaningless here.'),
          function () { st.port = 2; st.q.forEach(function (x) { x.s = x.setup ? ((x.def && p.deferredHonoured) ? 0 : 1) : 1; }); }];
      case 'qstart':
      case 'qstop':
        if (!started) return ['-EINVAL', '"Port N must be started before start any queue": queue start/stop only on a started port.'];
        if (!q1.setup) return ['-EINVAL', '"Queue 1 has not been setup".'];
        if (!p.qStart) return ['-ENOTSUP', 'The PMD has no rx_queue_start/stop op.'];
        if (api === 'qstart') return ['OK', 'q1 STARTED. On tap/pcap this only flips the state the app reads; backlog that queued meanwhile is delivered now (stale frames).', function () { q1.s = 1; }];
        return ['OK', 'q1 STOPPED. On tap/pcap this is bookkeeping only: rx_burst on q1 still returns packets (probed: 124). Stop polling it first.', function () { q1.s = 0; }];
      case 'setup1rt':
        if (!started) return ['OK', 'Port not started: ordinary queue setup.', function () { q1.setup = true; q1.def = false; }];
        if (!p.runtimeCapa) return ['-EBUSY', 'dev_capa lacks RUNTIME_RX_QUEUE_SETUP (printed with rte_eth_dev_capability_name: "(none)").'];
        if (q1.s) return ['-EBUSY', 'Capability present, but the queue must be stopped first.'];
        return ['-EBUSY', 'failsafe ADVERTISES RUNTIME_RX_QUEUE_SETUP, but its tap sub-device refuses ("RX queue setup failed for sub_device 0") and q1 is released: afterwards "Queue 1 has not been setup". A composite PMD\'s capability is only as good as its members.', function () { q1.setup = false; }];
      case 'mtu':
        if (st.port === 0) return ['-EINVAL', '"Port must be configured before MTU set".'];
        return [p.mtu, p.mtu === 'OK' ? 'MTU changed live, no restart (probed on null and tap).' : 'No mtu_set op in this PMD' + (p.src ? ' (from the PMD source).' : ' (probed).')];
      case 'reta':
        return [p.reta, p.reta === 'OK' ? 'RETA updated live (port configured in RSS mode). Real NICs also allow this live.' : 'No reta_update op' + (p.src ? ' (from the PMD source).' : ' (probed).')];
      case 'mac':
        return [p.mac, p.mac === 'OK' ? 'MAC changed live. On tap the kernel interface address changes too.' : 'No mac_addr_set op' + (p.src ? ' (from the PMD source).' : ' (probed).')];
      case 'stop':
        if (!started) return ['OK', 'Not started: ethdev logs "already stopped" and returns 0.'];
        return ['OK', 'Stopped. Restart cost measured on this VM: ' + p.outage + '. Pause the data path before, resume after.', function () {
          st.port = 3; st.q.forEach(function (x) { x.s = 0; });
          var w = /null/.test(p.outage) ? 30 : (/tap/.test(p.outage) ? 600 : 0);
          gapBar.setAttribute('width', w);
          gapTxt.textContent = w ? 'traffic gap of one restart: ' + p.outage : 'traffic gap: not measured for this PMD';
        }];
      }
      return ['?', ''];
    }
    function apply(api) {
      var r = evaluate(api);
      out.innerHTML = '<code>' + esc(r[0]) + '</code> &mdash; ' + r[1];
      out.className = 'qx-out ' + (r[0] === 'OK' ? 'ok' : 'bad');
      if (r[2]) r[2]();
      draw();
    }
    root.querySelectorAll('[data-api]').forEach(function (b) {
      b.addEventListener('click', function () {
        var api = b.getAttribute('data-api');
        if (pred.checked) {
          pending = api;
          choice.hidden = false;
          out.className = 'qx-out';
          out.innerHTML = 'Predict the return code of <code>' + esc(b.textContent) + '</code> on ' + PMD[sel.value].name + ':';
        } else apply(api);
      });
    });
    choice.querySelectorAll('button').forEach(function (b) {
      b.addEventListener('click', function () {
        if (!pending) return;
        var r = evaluate(pending)[0], guess = b.textContent;
        var hit = (guess === r) || (guess === '-EINVAL' && /EINVAL/.test(r));
        choice.hidden = true;
        apply(pending);
        out.innerHTML = (hit ? '<b>Correct.</b> ' : '<b>Not quite</b> (you said ' + esc(guess) + '). ') + out.innerHTML;
        pending = null;
      });
    });
    sel.addEventListener('change', function () { resetState(); out.textContent = 'PMD changed: port back to UNCONFIGURED.'; out.className = 'qx-out'; });
    $('qx-reset').addEventListener('click', function () { resetState(); out.textContent = 'Reset.'; out.className = 'qx-out'; });
    resetState();
  }

  /* ==================================================================
   * 4. Bonding mode selector, with the PMD's real hash functions
   * ================================================================ */
  // the 16 flows of bonding_modes.c: src 10.12.1.i:1000+i -> 10.12.2.1:9
  function le16(b, o) { return b[o] | (b[o + 1] << 8); }
  function le32(b, o) { return (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) >>> 0; }
  function flowBytes(i) {
    var src = [2, 0x12, 0, 0, 0, 1], dst = [2, 0x12, 0, 0, 0, 2];
    var sip = [10, 12, 1, i], dip = [10, 12, 2, 1];
    var sp = 1000 + i, dp = 9;
    return { src: src, dst: dst, sip: sip, dip: dip, sp: [sp >> 8, sp & 255], dp: [dp >> 8, dp & 255] };
  }
  function etherHash(f) { return (le16(f.src, 0) ^ le16(f.dst, 0)) ^ (le16(f.src, 2) ^ le16(f.dst, 2)) ^ (le16(f.src, 4) ^ le16(f.dst, 4)); }
  function bondMember(mode, i, n) {
    var f = flowBytes(i), h;
    if (mode === 'l2') { h = etherHash(f); h ^= h >>> 8; return h % n; }
    var l3 = (le32(f.sip, 0) ^ le32(f.dip, 0)) >>> 0;
    if (mode === 'l23') h = (etherHash(f) ^ l3) >>> 0;
    else h = (l3 ^ (le16(f.sp, 0) ^ le16(f.dp, 0))) >>> 0;
    h = (h ^ (h >>> 16)) >>> 0; h = (h ^ (h >>> 8)) >>> 0;
    return h % n;
  }
  function bondWidget() {
    var root = $('w-bond');
    if (!root) return;
    var svg = root.querySelector('svg');
    var modeSel = $('bond-mode'), cable = $('bond-cable'), lscKind = $('bond-lsc');
    S.box(svg, 10, 70, 110, 60, 'app tx_burst', 'c1');
    S.box(svg, 190, 60, 130, 80, 'net_bonding', 'c5');
    var m0 = S.box(svg, 430, 20, 120, 50, 'member 0', 'c2');
    var m1 = S.box(svg, 430, 130, 120, 50, 'member 1', 'c2');
    var c0 = S.text(svg, 600, 45, '0', 'svg-label center bold mono');
    var c1 = S.text(svg, 600, 155, '0', 'svg-label center bold mono');
    S.arrow(svg, 120, 100, 188, 100, 'c7');
    var a0 = S.arrow(svg, 320, 90, 428, 45, 'c7');
    var a1 = S.arrow(svg, 320, 110, 428, 155, 'c7');
    var note = S.text(svg, 255, 190, '', 'svg-label small center');
    var x0 = S.text(svg, 490, 85, '', 'svg-label small center bold svg-fill-c4');
    var pk = [], cnt, seq, rr, acc, tlb;
    var COL = ['', 'c1', 'c2', 'c4', 'c5'];
    function activeOk(m) {
      // member 0 cable pulled: does the bond know?
      if (m !== 0 || !cable.checked) return true;
      return lscKind.value === 'tap';  // tap: bond never learns, still "active"
    }
    function linkUp(m) { return !(m === 0 && cable.checked); }
    function pick(i) {
      var mode = modeSel.value, bondSees0 = activeOk(0);
      var act = bondSees0 ? [0, 1] : [1];
      if (mode === 'rr') { var m = act[rr % act.length]; rr++; return [m]; }
      if (mode === 'ab') return [act[0]];
      if (mode === 'bc') return act.slice();
      if (mode === 'tlb') { // least-loaded (bytes) member, re-evaluated per packet
        var best = act[0]; act.forEach(function (x) { if (tlb[x] < tlb[best]) best = x; }); tlb[best] += 1; return [best];
      }
      var mm = bondMember(mode, i % 16, 2);
      if (act.length === 1) mm = act[0];
      return [mm];
    }
    function updNote() {
      var mode = modeSel.value, s = '';
      if (cable.checked) {
        s = lscKind.value === 'tap' ? 'member 0 is down, but net_tap raises no LSC: the bond keeps it active and loses its share'
                                    : 'member 0 raised LSC (or was polled): the bond removed it from the active list';
      } else s = { rr: 'round-robin: packet k -> member k % 2', ab: 'active-backup: only the primary transmits', bc: 'broadcast: every packet on every member (refcnt++)',
                  l2: 'L2: one MAC pair -> one hash -> one member (all 16 flows!)', l23: 'L23: MACs ^ IPs: the 16 src IPs split 8/8',
                  l34: 'L34: IP ^ ports: src IP and port change together, the XOR is even every time -> member 0',
                  tlb: 'TLB: each packet to the member with the least recent load (varies run to run)' }[mode];
      note.textContent = s;
      x0.textContent = cable.checked ? 'cable pulled' : '';
      m0.rect.setAttribute('class', 'svg-box ' + (cable.checked ? 'c4' : 'c2'));
    }
    var anim = new CourseJS.Animator({
      root: root, autoplay: 'visible',
      onReset: function () {
        pk.forEach(function (p) { p.g.remove(); });
        pk = []; cnt = [0, 0, 0]; seq = 0; rr = 0; acc = 0; tlb = [0, 0];
        c0.textContent = '0'; c1.textContent = '0';
        updNote();
      },
      onFrame: function (dt) {
        acc += dt;
        if (acc > 0.22 && pk.length < 40) {
          acc = 0;
          var i = seq++ % 16;
          pick(i).forEach(function (m) {
            var g = S.packet(svg, 120, 100, 18, 11, COL[1 + (i % 4)], '');
            pk.push({ g: g, t: 0, m: m, f: i });
          });
        }
        pk = pk.filter(function (p) {
          p.t += dt * 0.9;
          var x, y, ty = p.m === 0 ? 45 : 155;
          if (p.t < 0.4) { x = 120 + p.t / 0.4 * 135; y = 100; }
          else if (p.t < 1) { var u = (p.t - 0.4) / 0.6; x = 255 + u * 235; y = 100 + u * (ty - 100); }
          else {
            if (linkUp(p.m)) { cnt[p.m]++; } else { cnt[2]++; }
            p.g.remove();
            c0.textContent = cnt[0] + (cnt[2] && cable.checked ? ' (+' + cnt[2] + ' lost)' : '');
            c1.textContent = cnt[1];
            return false;
          }
          if (!linkUp(p.m) && p.t > 0.85) p.g.body.classList.add('dropped');
          S.moveTo(p.g, x, y);
          return true;
        });
      }
    });
    [modeSel, cable, lscKind].forEach(function (el) { el.addEventListener('change', function () { anim.reset(); if (!anim.running) anim.play(); }); });
    // static check table: the JS hash against the program's output
    var t = $('bond-check');
    if (t) {
      ['l2', 'l23', 'l34'].forEach(function (m) {
        var c = [0, 0];
        for (var k = 0; k < 1000; k++) c[bondMember(m, k % 16, 2)]++;
        var tr = document.createElement('tr');
        tr.innerHTML = '<td>' + m.toUpperCase() + '</td><td class="num">' + c[0] + '</td><td class="num">' + c[1] + '</td>';
        t.appendChild(tr);
      });
    }
  }

  /* ==================================================================
   * 5. Failure signature board
   * ================================================================ */
  var FAULTS = {
    healthy: { label: 'healthy', ctr: { rx: 'up', nombuf: 'flat', imissed: 'flat', oerr: 'flat', drops: 'flat', inuse: 'steady', link: 'UP' },
      sig: 'All drop counters flat, in_use steady at "RX rings + in flight".', rec: [] },
    pool_dry: { label: 'pool dry', ctr: { rx: 'flat', nombuf: 'up', imissed: 'flat*', oerr: 'flat', drops: 'flat', inuse: 'max', link: 'UP' },
      sig: 'ipackets stops, rx_nombuf climbs once per poll, in_use = pool size (measured: 255 received, rx_nombuf 193, in_use 255). With pcap infinite_rx the PMD returns 0 and counts NOTHING. *on a NIC the RX ring then fills and imissed climbs too.',
      rec: ['Find who holds mbufs: compare rte_mempool_in_use_count() with what you expect', 'Free them (here: the app releases its 255 held mbufs)', 'RX resumes on the next poll: 640 received in 20 polls, rx_nombuf stops growing', 'Fix the cause: size the pool for RX rings + TX rings + app rings + caches + in-flight'] },
    tx_drop: { label: 'TX full: drop', ctr: { rx: 'up', nombuf: 'flat', imissed: 'flat', oerr: 'flat**', drops: 'up', inuse: 'steady', link: 'UP' },
      sig: 'tx_burst returns less than asked; the app frees the rest. Measured: 4,793,005 app drops, oerrors 0 (net_ring does not count them; no PMD counts what tx_burst refused). The fast port still sent 5,173,376.',
      rec: ['Count your own TX drops: the PMD will not', 'Decide the policy per traffic class', 'Fix capacity: faster consumer, more TX queues, bigger rings'] },
    tx_retry: { label: 'TX full: retry', ctr: { rx: 'slow', nombuf: 'flat', imissed: 'up*', oerr: 'flat', drops: 'flat', inuse: 'steady', link: 'UP' },
      sig: 'No loss, but the lcore spins in the retry loop: the FAST port fell from 5,173,376 to 131,840 packets, exactly the slow port\'s rate. Head-of-line blocking. *its RX input backs up -> imissed on a NIC.',
      rec: ['Bound the retry (a few attempts or a time budget)', 'Then drop or buffer per destination, never block the shared loop', 'Measure loops/stalls: 4,120 loops vs 37,932,567 stalls here'] },
    tx_bp: { label: 'TX full: back-pressure', ctr: { rx: 'slow', nombuf: 'flat', imissed: 'up*', oerr: 'flat', drops: 'flat', inuse: 'steady', link: 'UP' },
      sig: 'Hold the unsent burst and stop taking new input for that path. Slow port 79,962, fast port 5,104,992, no app drops. The loss moves upstream: *the NIC RX ring fills and imissed climbs.',
      rec: ['Keep per-destination pending buffers (like rte_eth_tx_buffer)', 'Let RX drop at the NIC (imissed) instead of blocking every port', 'Alert on imissed, it is now your congestion signal'] },
    link_flap: { label: 'link flap', ctr: { rx: 'flat', nombuf: 'flat', imissed: 'flat', oerr: 'up', drops: 'flat', inuse: 'steady', link: 'DOWN' },
      sig: 'Link DOWN seen by polling 0 ms after `ip link set down`; oerrors +1,584 while down; zero LSC callbacks on net_tap (it never raises them).',
      rec: ['Detect: LSC callback where the PMD raises it, else poll rte_eth_link_get_nowait() (alarm every 50 ms)', 'Stop sending to the dead port (or let bonding/failsafe fail over)', 'On UP: resume; counters show the outage window'] },
    reset: { label: 'reset (INTR_RESET)', ctr: { rx: 'flat', nombuf: 'flat', imissed: 'flat', oerr: 'flat', drops: 'flat', inuse: 'steady', link: 'DOWN' },
      sig: 'The PMD raises RTE_ETH_EVENT_INTR_RESET (passive mode). The callback only sets a flag. Configure while started -> -EBUSY.',
      rec: ['Callback: set reset_pending, return', 'Control thread: pause the data path and WAIT for the ack', 'rte_eth_dev_stop()', 'rte_eth_dev_reset() (-ENOTSUP on every vdev here: fallback close + rte_dev_remove + rte_dev_probe)', 'configure + queue setup + start (all queues: reset forgets them)', 'Resume the data path: measured outage 0.140 ms, 5.85 M pkts in the next 50 ms'] }
  };
  function failBoard() {
    var root = $('w-fail');
    if (!root) return;
    var btns = $('fail-btns'), sig = $('fail-sig'), list = $('fail-rec'), run = $('fail-run');
    var keys = ['rx', 'nombuf', 'imissed', 'oerr', 'drops', 'inuse', 'link'];
    var cur = 'healthy', val = {}, timer = null, step = -1, recovering = false;
    Object.keys(FAULTS).forEach(function (k) {
      var b = document.createElement('button');
      b.className = 'btn small'; b.type = 'button'; b.textContent = FAULTS[k].label;
      b.addEventListener('click', function () { select(k); });
      b.setAttribute('data-k', k);
      btns.appendChild(b);
    });
    function select(k) {
      cur = k; step = -1; recovering = false;
      keys.forEach(function (x) { val[x] = 0; });
      btns.querySelectorAll('button').forEach(function (b) { b.classList.toggle('primary', b.getAttribute('data-k') === k); });
      sig.innerHTML = '<b>Signature:</b> ' + esc(FAULTS[k].sig);
      list.innerHTML = '';
      FAULTS[k].rec.forEach(function (r) { var li = document.createElement('li'); li.textContent = r; list.appendChild(li); });
      run.disabled = !FAULTS[k].rec.length;
    }
    function trendOf(x) {
      var t = FAULTS[cur].ctr[x];
      if (recovering && step >= FAULTS[cur].rec.length - 1) t = FAULTS.healthy.ctr[x];
      return t;
    }
    function tick() {
      keys.forEach(function (x) {
        var t = trendOf(x), el = $('fc-' + x), box = el.parentNode;
        if (x === 'link') { el.textContent = t; box.classList.toggle('alarm', t === 'DOWN'); return; }
        if (x === 'inuse') {
          val[x] = t === 'max' ? 255 : 66 + Math.round(Math.random() * 4);
          el.textContent = val[x] + (t === 'max' ? ' / 255' : '');
          box.classList.toggle('alarm', t === 'max');
          return;
        }
        var inc = /^up/.test(t) ? 40 + Math.random() * 30 : (t === 'slow' ? 3 : 0);
        if (x === 'rx' && t === 'up') inc = 900 + Math.random() * 200;
        val[x] += Math.round(inc);
        el.textContent = CourseJS.fmt(val[x]);
        box.classList.toggle('alarm', x !== 'rx' && inc > 0);
        box.classList.toggle('stall', x === 'rx' && inc < 100);
      });
    }
    run.addEventListener('click', function () {
      recovering = true; step = -1;
      var items = list.querySelectorAll('li');
      (function next() {
        step++;
        items.forEach(function (li, i) { li.classList.toggle('active', i === step); li.classList.toggle('done', i < step); });
        if (step < items.length - 1) setTimeout(next, 1100);
        else setTimeout(function () { items.forEach(function (li) { li.classList.add('done'); li.classList.remove('active'); }); }, 1100);
      })();
    });
    select('healthy');
    timer = setInterval(function () { if (!document.hidden) tick(); }, 400);
    tick();
  }

  CourseJS.ready(function () {
    cbChain();
    evtFlow();
    qExplorer();
    bondWidget();
    failBoard();
  });
})();

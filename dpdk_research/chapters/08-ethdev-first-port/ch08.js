/* Chapter 8 widgets: port state machine, descriptor ring, mbuf ownership,
 * fp_ops call path (stepper with predict) and the burst amortisation chart.
 * Vanilla JS on top of ../../assets/course.js. Colours only via CSS classes
 * or CSS variables, so light and dark themes both work. */
(function () {
  'use strict';
  var S = CourseJS.svg;

  function $(id) { return document.getElementById(id); }
  function setText(id, v) { var e = $(id); if (e) e.textContent = v; }
  function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;'); }

  /* =====================================================================
   * 1. Port state machine
   * =================================================================== */
  function stateMachine() {
    var root = $('w-state');
    if (!root) return;
    var svg = root.querySelector('svg');
    var nodes = {
      probed:     { x: 12,  y: 30,  label: 'probed', sub: 'not configured' },
      configured: { x: 190, y: 30,  label: 'configured', sub: 'queues not set up' },
      ready:      { x: 368, y: 30,  label: 'queues ready', sub: 'rx/tx_queue_setup done' },
      started:    { x: 546, y: 30,  label: 'started', sub: 'fast path live' },
      stopped:    { x: 368, y: 150, label: 'stopped', sub: 'config + queues kept' },
      closed:     { x: 12,  y: 150, label: 'closed', sub: 'port id released' }
    };
    var W = 162, H = 58;
    var edges = [
      ['probed', 'configured', 'configure()'],
      ['configured', 'ready', 'queue_setup()'],
      ['ready', 'started', 'start()'],
      ['started', 'stopped', 'stop()'],
      ['stopped', 'started', 'start()'],
      ['stopped', 'configured', 'configure()'],
      ['stopped', 'closed', 'close()']
    ];
    var eg = S.group(svg);
    function cx(n) { return nodes[n].x + W / 2; }
    function cy(n) { return nodes[n].y + H / 2; }
    // straight edges along the top row
    S.arrow(eg, 174, 59, 188, 59, 'c7');
    S.text(eg, 181, 20, 'configure()', 'svg-label small center mono muted');
    S.arrow(eg, 352, 59, 366, 59, 'c7');
    S.text(eg, 359, 102, 'queue_setup()', 'svg-label small center mono muted');
    S.arrow(eg, 530, 59, 544, 59, 'c7');
    S.text(eg, 537, 20, 'start()', 'svg-label small center mono muted');
    S.path(eg, 'M627,88 L627,179 L532,179', 'svg-arrow c7');
    S.text(eg, 640, 136, 'stop()', 'svg-label small mono muted');
    S.path(eg, 'M500,150 C520,120 560,110 590,90', 'svg-arrow c7');
    S.text(eg, 525, 128, 'start()', 'svg-label small mono muted');
    S.path(eg, 'M368,170 C330,150 300,120 276,90', 'svg-arrow c7');
    S.text(eg, 250, 140, 'configure()', 'svg-label small mono muted');
    S.arrow(eg, 366, 192, 176, 192, 'c7');
    S.text(eg, 271, 206, 'close()', 'svg-label small center mono muted');

    var boxes = {};
    Object.keys(nodes).forEach(function (k) {
      var n = nodes[k];
      var g = S.group(svg);
      var r = S.rect(g, n.x, n.y, W, H, 'svg-box c7 svg-fade');
      S.text(g, n.x + W / 2, n.y + 22, n.label, 'svg-label center bold');
      S.text(g, n.x + W / 2, n.y + 41, n.sub, 'svg-label center small muted');
      boxes[k] = r;
    });
    // fp_ops panel
    S.rect(svg, 12, 236, 696, 76, 'svg-box c1');
    S.text(svg, 24, 256, 'rte_eth_fp_ops[0]   (what rte_eth_rx_burst(0, ...) will call)', 'svg-label bold');
    var fpFn = S.text(svg, 24, 278, '', 'svg-label mono');
    var fpQ = S.text(svg, 24, 299, '', 'svg-label mono');
    var flash = S.rect(svg, 12, 236, 696, 76, 'svg-box c1 svg-fade', { style: 'fill:none;stroke-width:3;opacity:0' });

    var m, logEl = $('w-state-log');
    function resetModel() {
      m = { configured: false, ready: false, started: false, everStarted: false, closed: false, warned: false };
      logEl.innerHTML = '';
      draw();
      log('EAL probed net_null0 &rarr; port 0 exists. Click an API call.', 'muted');
    }
    function state() {
      if (m.closed) return 'closed';
      if (m.started) return 'started';
      if (m.everStarted && m.configured && m.ready) return 'stopped';
      if (m.ready) return 'ready';
      if (m.configured) return 'configured';
      return 'probed';
    }
    function draw() {
      var s = state();
      Object.keys(boxes).forEach(function (k) {
        boxes[k].setAttribute('class', 'svg-box svg-fade ' + (k === s ? 'c3 svg-highlight' : 'c7'));
      });
      if (m.started) {
        fpFn.textContent = '.rx_pkt_burst = eth_null_rx          (the PMD’s function)';
        fpQ.textContent = '.rxq.data     = dev->data->rx_queues  (the PMD’s queue structs)';
      } else {
        fpFn.textContent = '.rx_pkt_burst = dummy_eth_rx_burst   (logs once, rte_errno=ENOTSUP, returns 0)';
        fpQ.textContent = '.rxq.data     = dummy_queues_array[0]';
      }
      setText('w-state-now', s);
    }
    function pulse() {
      flash.style.opacity = '1';
      setTimeout(function () { flash.style.opacity = '0'; }, 450);
    }
    function log(html, cls) {
      var d = document.createElement('div');
      d.className = 'st-line ' + (cls || '');
      d.innerHTML = html;
      logEl.insertBefore(d, logEl.firstChild);
      while (logEl.children.length > 7) logEl.removeChild(logEl.lastChild);
    }
    // Each API returns {ret, msg, note, apply}
    var api = {
      configure: function () {
        if (m.closed) return { ret: -19, msg: 'ETHDEV: Invalid port_id=0' };
        if (m.started) return { ret: -16, msg: 'ETHDEV: Port 0 must be stopped to allow configuration' };
        return { ret: 0, note: m.everStarted ? 'Re-configured. Set the queues up again: their settings came from the old configuration.' : 'nb_rx_queues=1, nb_tx_queues=1 recorded; queue arrays allocated.',
          apply: function () { m.configured = true; m.ready = false; } };
      },
      setup: function () {
        if (m.closed) return { ret: -19, msg: 'ETHDEV: Invalid port_id=0' };
        if (!m.configured) return { ret: -22, msg: 'ETHDEV: Invalid Rx queue_id=0', note: 'That is net_tap. On net_null in 26.11 this very call crashes with SIGSEGV (see lifecycle_rules output).' };
        if (m.started) return { ret: -16, note: 'No RUNTIME_RX_QUEUE_SETUP capability: queues can only be (re)created while stopped.' };
        return { ret: 0, note: 'rx_queue_setup(0, 0, 1024, socket, NULL, pool) and tx_queue_setup(0, 0, 1024, socket, NULL).',
          apply: function () { m.ready = true; } };
      },
      start: function () {
        if (m.closed) return { ret: -19, msg: 'ETHDEV: Invalid port_id=0' };
        if (!m.configured) return { ret: -22, msg: 'ETHDEV: Device with port_id=0 is not configured.' };
        if (m.started) return { ret: 0, msg: 'ETHDEV: Device with port_id=0 already started' };
        var n = m.ready ? 'dev_start ran, then eth_dev_fp_ops_setup() copied the PMD’s burst functions into rte_eth_fp_ops[0].'
          : 'Returns 0: ethdev does NOT check that you set the queues up. The fast path now points at missing queues. Never do this.';
        return { ret: 0, note: n, fp: true, apply: function () { m.started = true; m.everStarted = true; if (!m.ready) m.ready = true; } };
      },
      rx: function () {
        if (m.started) return { ret: 32, rx: true, note: 'eth_null_rx allocated 32 mbufs from the pool. They are now yours: free them or send them.' };
        var r = { ret: 0, rx: true, note: 'dummy_eth_rx_burst: returns 0, rte_errno = ENOTSUP. Your loop just sees "no packets".' };
        if (!m.warned) { r.msg = 'ETHDEV: lcore 0 called rx_pkt_burst for not ready port 0  (+ stack dump, once)'; m.warned = true; }
        return r;
      },
      stop: function () {
        if (m.closed) return { ret: -19, msg: 'ETHDEV: Invalid port_id=0' };
        if (!m.started) return { ret: 0, msg: 'ETHDEV: Device with port_id=0 already stopped' };
        return { ret: 0, fp: true, note: 'eth_dev_fp_ops_reset() runs FIRST (dummies back, warn-once re-armed), then the PMD’s dev_stop.',
          apply: function () { m.started = false; m.warned = false; } };
      },
      close: function () {
        if (m.closed) return { ret: -19, msg: 'ETHDEV: Invalid port_id=0' };
        if (m.started) return { ret: -22, msg: 'ETHDEV: Cannot close started device (port 0)' };
        return { ret: 0, note: 'Queues and private data freed, port id 0 released: rte_eth_dev_is_valid_port(0) is now 0.',
          apply: function () { m.closed = true; m.started = false; } };
      }
    };
    var names = { configure: 'rte_eth_dev_configure(0, 1, 1, &amp;conf)', setup: 'rte_eth_rx/tx_queue_setup(0, 0, ...)',
      start: 'rte_eth_dev_start(0)', rx: 'rte_eth_rx_burst(0, 0, pkts, 32)', stop: 'rte_eth_dev_stop(0)', close: 'rte_eth_dev_close(0)' };
    var errname = { '0': '0', '-16': '-16 (EBUSY)', '-22': '-22 (EINVAL)', '-19': '-19 (ENODEV)', '32': '32' };
    function fmtRet(r) { return errname[String(r)] || String(r); }

    var predictOn = $('w-state-predict');
    var pBox = $('w-state-ask');
    function doCall(k) {
      var r = api[k]();
      var finish = function (guessOk) {
        log((r.msg ? '<div class="mono small muted">' + esc(r.msg) + '</div>' : '') +
          '<span class="mono">' + names[k] + '</span> &rarr; <b class="' + (r.ret < 0 ? 'err' : 'ok') + '">' + fmtRet(r.ret) + '</b>' +
          (guessOk === true ? ' <span class="ok">(your prediction was right)</span>' : guessOk === false ? ' <span class="err">(not what you predicted)</span>' : '') +
          (r.note ? '<div class="muted small">' + r.note + '</div>' : ''), '');
        if (r.apply) r.apply();
        if (r.fp) pulse();
        draw();
      };
      if (predictOn && predictOn.checked) {
        var opts = k === 'rx' ? ['0', '32'] : ['0', '-16 (EBUSY)', '-22 (EINVAL)', '-19 (ENODEV)'];
        pBox.innerHTML = '<span>Predict: <span class="mono">' + names[k] + '</span> returns&hellip;</span> ';
        opts.forEach(function (o) {
          var b = document.createElement('button');
          b.type = 'button'; b.className = 'btn small'; b.textContent = o;
          b.addEventListener('click', function () {
            pBox.innerHTML = '';
            finish(o === fmtRet(r.ret));
            setButtons(true);
          });
          pBox.appendChild(b);
        });
        setButtons(false);
      } else {
        finish(null);
      }
    }
    var btns = root.querySelectorAll('[data-api]');
    function setButtons(on) { Array.prototype.forEach.call(btns, function (b) { b.disabled = !on; }); }
    Array.prototype.forEach.call(btns, function (b) {
      b.addEventListener('click', function () { doCall(b.getAttribute('data-api')); });
    });
    $('w-state-reset').addEventListener('click', function () { pBox.innerHTML = ''; setButtons(true); resetModel(); });
    resetModel();
  }

  /* =====================================================================
   * 2. Descriptor ring (simplified)
   * =================================================================== */
  function descRing() {
    var root = $('w-desc');
    if (!root) return;
    var svg = root.querySelector('svg');
    var CX = 250, CY = 150, R = 105;
    S.box(svg, 8, 128, 92, 44, 'wire / NIC', 'c4');
    S.box(svg, 560, 128, 100, 44, 'lcore: app', 'c1');
    S.box(svg, 560, 30, 100, 40, 'mempool', 'c2');
    S.arrow(svg, 100, 150, 138, 150, 'c4');
    S.arrow(svg, 378, 150, 556, 150, 'c1');
    S.arrow(svg, 556, 56, 392, 86, 'c2 dashed');
    S.text(svg, 480, 90, 'refill', 'svg-label small muted');
    S.text(svg, 455, 140, 'rx_burst()', 'svg-label small mono');
    var ringG = S.group(svg), flyG = S.group(svg);
    var headArrow = S.path(svg, 'M0,0', 'svg-arrow c4');
    var tailArrow = S.path(svg, 'M0,0', 'svg-arrow c1');
    var headLbl = S.text(svg, 0, 0, 'NIC head', 'svg-label small center bold');
    var tailLbl = S.text(svg, 0, 0, 'SW tail', 'svg-label small center bold');
    S.text(svg, CX, CY - 6, 'Rx descriptor ring', 'svg-label center small bold');
    var fillLbl = S.text(svg, CX, CY + 12, '', 'svg-label center small mono');

    var rate = $('d-rate'), poll = $('d-poll'), burst = $('d-burst'), size = $('d-size'), empty = $('d-empty');
    CourseJS.bindRange(rate, '#d-rate-o', function (v) { return v + ' pkt/s'; });
    CourseJS.bindRange(poll, '#d-poll-o', function (v) { return (v / 10).toFixed(1) + ' s'; });
    CourseJS.bindRange(burst, '#d-burst-o', function (v) { return v; });
    CourseJS.bindRange(size, '#d-size-o', function (v) { return v; }, function () { if (anim) anim.reset(); });

    var st, slots;
    function slotPos(i, n, r) {
      var a = -Math.PI / 2 + 2 * Math.PI * i / n;
      return { x: CX + (r || R) * Math.cos(a), y: CY + (r || R) * Math.sin(a), a: a };
    }
    function build() {
      S.clear(ringG); S.clear(flyG);
      var n = parseInt(size.value, 10);
      slots = [];
      var w = n > 16 ? 14 : 20;
      for (var i = 0; i < n; i++) {
        var p = slotPos(i, n);
        var g = S.group(ringG);
        var r = S.rect(g, p.x - w / 2, p.y - w / 2, w, w, 'svg-slot', { rx: 3 });
        var t = S.text(g, p.x, p.y + 0.5, '', 'svg-label center small', { style: 'font-size:9px;font-weight:700' });
        slots.push({ r: r, t: t });
      }
      st = { n: n, desc: [], head: 0, tail: 0, acc: 0, pollT: 0, arrived: 0, written: 0, delivered: 0, refilled: 0, imissed: 0, nombuf: 0, polls: 0 };
      for (var k = 0; k < n; k++) st.desc.push({ armed: true, dd: false });
      draw();
    }
    function pointer(el, lbl, idx, outer, txt) {
      var p1 = slotPos(idx % st.n, st.n, R + (outer ? 40 : -38));
      var p2 = slotPos(idx % st.n, st.n, R + (outer ? 16 : -16));
      el.setAttribute('d', 'M' + p1.x.toFixed(1) + ',' + p1.y.toFixed(1) + ' L' + p2.x.toFixed(1) + ',' + p2.y.toFixed(1));
      var p3 = slotPos(idx % st.n, st.n, R + (outer ? 50 : -50));
      lbl.setAttribute('x', p3.x.toFixed(1)); lbl.setAttribute('y', p3.y.toFixed(1));
      lbl.textContent = txt;
    }
    function draw() {
      for (var i = 0; i < st.n; i++) {
        var d = st.desc[i], s = slots[i];
        s.r.setAttribute('class', d.dd ? 'svg-slot full' : (d.armed ? 'svg-slot' : 'svg-slot unarmed'));
        s.t.textContent = d.dd ? 'DD' : (d.armed ? '' : '∅');
      }
      pointer(headArrow, headLbl, st.head, true, 'NIC head');
      pointer(tailArrow, tailLbl, st.tail, false, 'SW tail');
      var done = st.desc.filter(function (d) { return d.dd; }).length;
      fillLbl.textContent = done + '/' + st.n + ' done';
      setText('d-arr', CourseJS.fmt(st.arrived));
      setText('d-del', CourseJS.fmt(st.delivered));
      setText('d-ref', CourseJS.fmt(st.refilled));
      setText('d-miss', CourseJS.fmt(st.imissed));
      setText('d-nomb', CourseJS.fmt(st.nombuf));
      var cap = parseInt(burst.value, 10) / (parseInt(poll.value, 10) / 10);
      setText('d-cap', cap.toFixed(1) + ' pkt/s');
      $('d-cap').parentNode.classList.toggle('bad', cap < parseFloat(rate.value));
    }
    function fly(fromX, fromY, toX, toY, cls) {
      var p = S.packet(flyG, fromX, fromY, 14, 9, cls);
      p.style.transition = 'transform .45s ease, opacity .45s';
      p.setAttribute('transform', '');
      p.style.transform = 'translate(' + fromX + 'px,' + fromY + 'px)';
      requestAnimationFrame(function () {
        requestAnimationFrame(function () {
          p.style.transform = 'translate(' + toX + 'px,' + toY + 'px)';
          p.style.opacity = '0.2';
        });
      });
      setTimeout(function () { if (p.parentNode) p.parentNode.removeChild(p); }, 520);
    }
    function arrive() {
      st.arrived++;
      var i = st.head % st.n, d = st.desc[i];
      var pos = slotPos(i, st.n);
      if (d.armed && !d.dd) {
        d.dd = true; d.armed = false;          // NIC wrote the packet into the buffer
        st.written++; st.head++;
        fly(100, 150, pos.x, pos.y);
      } else {
        st.imissed++;                         // no free descriptor: dropped in the NIC
        fly(100, 150, 110, 230, 'dropped');
      }
    }
    function rxBurst() {
      st.polls++;
      var b = parseInt(burst.value, 10), got = 0;
      // walk from the software tail while descriptors are done (DD set)
      while (got < b) {
        var i = st.tail % st.n, d = st.desc[i];
        if (!d.dd) break;
        // PMD: allocate a replacement mbuf BEFORE handing the full one over
        if (empty.checked) { st.nombuf++; break; }
        d.dd = false; d.armed = true;
        got++; st.tail++; st.delivered++; st.refilled++;
        var pos = slotPos(i, st.n);
        fly(pos.x, pos.y, 600, 150, 'c1');
      }
    }
    var anim = new CourseJS.Animator({
      root: root,
      autoplay: 'visible',
      onReset: function () { build(); },
      onFrame: function (dt) {
        st.acc += dt * parseFloat(rate.value);
        while (st.acc >= 1) { st.acc -= 1; arrive(); }
        st.pollT += dt;
        var P = parseInt(poll.value, 10) / 10;
        if (st.pollT >= P) { st.pollT = 0; rxBurst(); }
        draw();
      }
    });
    empty.addEventListener('change', draw);
  }

  /* =====================================================================
   * 3. mbuf ownership in a forwarding loop
   * =================================================================== */
  function ownership() {
    var root = $('w-own');
    if (!root) return;
    var svg = root.querySelector('svg');
    var TOTAL = 48, RXN = 8;
    var zones = {
      pool: { x: 10, y: 40, w: 150, h: 150, cols: 6, cls: 'c2', title: 'mempool (free)' },
      rx:   { x: 180, y: 40, w: 90, h: 150, cols: 2, cls: 'c4', title: 'Rx ring (armed)' },
      app:  { x: 290, y: 40, w: 120, h: 150, cols: 4, cls: 'c1', title: 'app: pkts[]' },
      tx:   { x: 430, y: 40, w: 120, h: 150, cols: 4, cls: 'c5', title: 'Tx ring' },
      leak: { x: 570, y: 40, w: 140, h: 150, cols: 5, cls: 'c7', title: 'leaked (nobody)' }
    };
    Object.keys(zones).forEach(function (k) {
      var z = zones[k];
      S.rect(svg, z.x, z.y, z.w, z.h, 'svg-box ' + z.cls + (k === 'leak' ? ' dashed' : ''));
      S.text(svg, z.x + z.w / 2, z.y - 12, z.title, 'svg-label center small bold');
      z.cnt = S.text(svg, z.x + z.w / 2, z.y + z.h + 16, '0', 'svg-label center mono');
    });
    S.text(svg, 360, 236, 'Each square is one mbuf. Total is always ' + TOTAL + ': pool + Rx ring + app + Tx ring + leaked.', 'svg-label center small muted');
    var tokG = S.group(svg);
    var toks = [];
    for (var i = 0; i < TOTAL; i++) {
      var r = S.rect(tokG, -6, -6, 12, 12, 'svg-packet', { rx: 2 });
      r.style.transition = 'transform .5s ease, fill .3s';
      toks.push({ el: r, z: 'pool' });
    }
    var freeTail = $('o-free'), cap = $('o-cap'), drain = $('o-drain'), bsz = $('o-burst');
    CourseJS.bindRange(cap, '#o-cap-o', function (v) { return v + ' slots'; });
    CourseJS.bindRange(drain, '#o-drain-o', function (v) { return v + ' pkts/tick'; });
    CourseJS.bindRange(bsz, '#o-burst-o', function (v) { return v; });
    var stats;
    function layout() {
      var per = {};
      toks.forEach(function (t) {
        var z = zones[t.z];
        var k = per[t.z] = (per[t.z] || 0) + 1;
        var idx = k - 1, col = idx % z.cols, row = Math.floor(idx / z.cols);
        var x = z.x + 14 + col * 23, y = z.y + 14 + row * 17;
        t.el.style.transform = 'translate(' + x + 'px,' + y + 'px)';
        t.el.setAttribute('class', 'svg-packet' + (t.z === 'leak' ? ' dropped' : t.z === 'pool' ? ' c2' : t.z === 'tx' ? ' c5' : ''));
      });
      Object.keys(zones).forEach(function (k) { zones[k].cnt.textContent = per[k] || 0; });
      var capv = parseInt(cap.value, 10);
      setText('o-txcap', (per.tx || 0) + ' / ' + capv);
      setText('o-sent', CourseJS.fmt(stats.sent));
      setText('o-unsent', CourseJS.fmt(stats.unsent));
      setText('o-nomb', CourseJS.fmt(stats.nombuf));
      setText('o-phase', stats.phase);
    }
    function move(from, to, n) {
      var c = 0;
      for (var i = 0; i < toks.length && c < n; i++) if (toks[i].z === from) { toks[i].z = to; c++; }
      return c;
    }
    function count(z) { return toks.filter(function (t) { return t.z === z; }).length; }
    var phase = 0, acc = 0;
    function tick() {
      var b = parseInt(bsz.value, 10), capv = parseInt(cap.value, 10);
      if (phase === 0) {
        // rte_eth_rx_burst: up to b armed buffers go to the app...
        var got = move('rx', 'app', Math.min(b, count('rx')));
        // ...and the PMD refills the ring from the pool
        var need = RXN - count('rx');
        var ref = move('pool', 'rx', need);
        if (ref < need) stats.nombuf += need - ref;
        stats.phase = 'rx_burst returned ' + got + ' (ring refilled with ' + ref + ')';
      } else if (phase === 1) {
        var n = count('app'), room = Math.max(0, capv - count('tx'));
        var s = move('app', 'tx', Math.min(n, room));
        stats.sent += s; stats.unsent += n - s;
        stats.phase = 'tx_burst(' + n + ') accepted ' + s + (n - s ? ', ' + (n - s) + ' still OURS' : '');
      } else if (phase === 2) {
        var left = count('app');
        if (left) {
          if (freeTail.checked) { move('app', 'pool', left); stats.phase = 'rte_pktmbuf_free_bulk(&pkts[sent], ' + left + ')'; }
          else { move('app', 'leak', left); stats.phase = left + ' mbufs forgotten: leaked'; }
        } else stats.phase = 'nothing left to free';
      } else {
        var d = move('tx', 'pool', parseInt(drain.value, 10));
        stats.phase = 'NIC sent ' + d + ' and the PMD freed them (lazily)';
      }
      phase = (phase + 1) % 4;
      layout();
    }
    new CourseJS.Animator({
      root: root,
      autoplay: 'visible',
      onReset: function () {
        toks.forEach(function (t) { t.z = 'pool'; });
        move('pool', 'rx', RXN);
        stats = { sent: 0, unsent: 0, nombuf: 0, phase: 'ready' };
        phase = 0; acc = 0;
        layout();
      },
      onFrame: function (dt) {
        acc += dt;
        if (acc >= 0.7) { acc = 0; tick(); }
      }
    });
  }

  /* =====================================================================
   * 4. fp_ops call path: predict, then step
   * =================================================================== */
  function fpops() {
    var root = $('w-fp');
    if (!root) return;
    var svg = root.querySelector('svg');
    var parts = {};
    function box(k, x, y, w, h, title, sub, cls) {
      var g = S.group(svg);
      var r = S.rect(g, x, y, w, h, 'svg-box svg-fade ' + cls);
      var t = S.text(g, x + w / 2, y + (sub ? h / 2 - 8 : h / 2), title, 'svg-label center mono bold');
      var s = sub ? S.text(g, x + w / 2, y + h / 2 + 10, sub, 'svg-label center small muted') : null;
      parts[k] = { r: r, t: t, s: s, cls: cls };
    }
    box('call', 10, 14, 250, 44, 'rte_eth_rx_burst(0, 0, pkts, 32)', 'inline, in your binary', 'c1');
    box('arr', 10, 92, 250, 120, '', '', 'c7');
    S.text(svg, 135, 108, 'rte_eth_fp_ops[RTE_MAX_ETHPORTS]', 'svg-label center small bold');
    var rows = [];
    for (var i = 0; i < 3; i++) {
      rows.push(S.rect(svg, 26, 118 + i * 30, 218, 24, 'svg-slot svg-fade', { rx: 3 }));
      S.text(svg, 36, 134 + i * 30, '[' + i + ']  Rx line | Tx line (128 B)', 'svg-label small mono');
    }
    box('qd', 320, 92, 170, 54, 'rxq.data[0]', 'void *qd (queue struct)', 'c5');
    box('fn', 320, 168, 170, 54, 'rx_pkt_burst', 'function pointer', 'c5');
    box('pmd', 540, 168, 170, 54, 'eth_null_rx(qd, ...)', 'the PMD, drivers/net/null', 'c4');
    box('q', 540, 92, 170, 54, 'struct null_queue', 'mb_pool, counters', 'c4');
    box('cb', 320, 246, 170, 46, 'rxq.clbk[0] == NULL?', 'Rx callbacks (ch12)', 'c7');
    box('ret', 540, 246, 170, 46, 'return nb_rx', 'trace point, then back', 'c3');
    S.arrow(svg, 135, 58, 135, 88, 'c7');
    S.arrow(svg, 244, 130, 316, 119, 'c7');
    S.arrow(svg, 244, 130, 316, 195, 'c7');
    S.arrow(svg, 490, 119, 536, 119, 'c7');
    S.arrow(svg, 490, 195, 536, 195, 'c7');
    S.arrow(svg, 625, 222, 625, 242, 'c7');
    S.arrow(svg, 536, 269, 494, 269, 'c7 dashed');
    var stopped = $('fp-stopped');
    function hl(keys) {
      Object.keys(parts).forEach(function (k) {
        var on = keys.indexOf(k) >= 0;
        parts[k].r.setAttribute('class', 'svg-box svg-fade ' + parts[k].cls + (on ? ' svg-highlight' : ''));
      });
    }
    function rowhl(on) { rows[0].setAttribute('class', 'svg-slot svg-fade' + (on ? ' full' : '')); }
    function setMode(ctx) {
      var dummy = stopped.checked;
      parts.pmd.t.textContent = dummy ? 'dummy_eth_rx_burst' : 'eth_null_rx(qd, ...)';
      parts.pmd.s.textContent = dummy ? 'lib/ethdev/ethdev_private.c' : 'the PMD, drivers/net/null';
      parts.q.t.textContent = dummy ? 'struct dummy_queue' : 'struct null_queue';
      parts.q.s.textContent = dummy ? 'only rx_warn_once' : 'mb_pool, counters';
      parts.ret.t.textContent = dummy ? 'return 0' : 'return 32';
      parts.ret.s.textContent = dummy ? 'rte_errno = ENOTSUP' : 'trace point, then back';
    }
    var step = new CourseJS.Stepper(root, {
      interval: 1800,
      reset: function (ctx) { setMode(ctx); hl([]); rowhl(false); },
      steps: [
        { caption: 'Your code calls <code>rte_eth_rx_burst()</code>. It is a <code>static inline</code> function in <code>rte_ethdev.h</code>, so its body is compiled into your program: no library call yet.',
          run: function (ctx, cur) { if (cur) hl(['call']); } },
        { caption: '<code>p = &amp;rte_eth_fp_ops[port_id];</code> One array index. Each element is exactly two 64-byte cache lines: Rx fields in the first, Tx fields in the second. In a release build there is <em>no</em> check that <code>port_id</code> is valid.',
          run: function (ctx, cur) { if (cur) { hl(['arr']); rowhl(true); } },
          predict: { question: 'How many checks on <code>port_id</code> and <code>queue_id</code> does a normal (non-debug) build perform here?',
            options: ['None', 'One: port_id < RTE_MAX_ETHPORTS', 'Both ids are validated'], answer: 0,
            explain: 'The checks exist only under <code>#ifdef RTE_ETHDEV_DEBUG_RX</code>. The fast path trusts you; a wrong id reads the wrong memory.' } },
        { caption: '<code>qd = p-&gt;rxq.data[queue_id];</code> A second load: the pointer to the PMD’s private queue structure, which <code>rx_queue_setup()</code> created.',
          run: function (ctx, cur) { if (cur) { hl(['qd', 'q']); rowhl(true); } } },
        { caption: '<code>nb_rx = p-&gt;rx_pkt_burst(qd, rx_pkts, nb_pkts);</code> One indirect call into the driver. <code>rte_eth_dev_start()</code> copied this pointer from the device; <code>rte_eth_dev_stop()</code> puts the dummy back.',
          run: function (ctx, cur) { if (cur) { hl(['fn', 'pmd']); rowhl(true); } },
          predict: { question: 'Tick "port stopped" and think: which function runs now?',
            options: ['eth_null_rx, it then checks a "started" flag', 'dummy_eth_rx_burst, which returns 0', 'The call crashes'], answer: 1,
            explain: 'Stopping swaps the pointer in <code>rte_eth_fp_ops[port]</code> to <code>dummy_eth_rx_burst</code>: it logs once per stop, sets <code>rte_errno = ENOTSUP</code> and returns 0. No flag is checked anywhere.' } },
        { caption: 'If any Rx callback is registered on this queue (<code>rte_eth_add_rx_callback</code>, used by pdump and latencystats), <code>rte_eth_call_rx_callbacks()</code> runs them on the received burst. Normally the pointer is NULL and this costs one load and one predictable branch.',
          run: function (ctx, cur) { if (cur) hl(['cb']); } },
        { caption: 'A trace point fires (empty or non-empty burst) and the count is returned. Total overhead of ethdev itself: two loads, one indirect call, one branch.',
          run: function (ctx, cur) { if (cur) hl(['ret', 'call']); } }
      ]
    });
    stopped.addEventListener('change', function () { step.go(step.index < 0 ? 0 : step.index); });
  }

  /* =====================================================================
   * 5. Burst amortisation chart (measured data from burst_sweep)
   * =================================================================== */
  function burstChart() {
    var root = $('w-burst');
    if (!root) return;
    var svg = root.querySelector('svg');
    var data = JSON.parse(root.getAttribute('data-sweep'));   // [[B, med, min, max], ...]
    var fit = JSON.parse(root.getAttribute('data-fit'));      // [a, c]
    var X0 = 60, X1 = 620, Y0 = 250, Y1 = 20, YMAX = 70;
    function xs(b) { return X0 + (Math.log(b) / Math.LN2) / 7 * (X1 - X0); }
    function ys(v) { return Y0 - Math.min(v, YMAX) / YMAX * (Y0 - Y1); }
    for (var v = 0; v <= YMAX; v += 10) {
      S.line(svg, X0, ys(v), X1, ys(v), 'svg-grid');
      S.text(svg, X0 - 8, ys(v) + 4, String(v), 'svg-label small', { 'text-anchor': 'end' });
    }
    [1, 2, 4, 8, 16, 32, 64, 128].forEach(function (b) {
      S.text(svg, xs(b), Y0 + 18, String(b), 'svg-label small center');
    });
    S.text(svg, (X0 + X1) / 2, Y0 + 38, 'burst size (packets per rx_burst / tx_burst call, log scale)', 'svg-label small center muted');
    S.text(svg, 14, 140, 'cycles per packet', 'svg-label small center muted', { transform: 'rotate(-90 14 140)' });
    var curve = S.path(svg, 'M0,0', 'svg-line', { style: 'stroke:var(--c5);stroke-width:2.5;fill:none' });
    var floor = S.path(svg, 'M0,0', 'svg-line', { style: 'stroke:var(--c5);stroke-dasharray:4 4;fill:none;opacity:.7' });
    data.forEach(function (d) {
      S.line(svg, xs(d[0]), ys(d[2]), xs(d[0]), ys(d[3]), 'svg-line', { style: 'stroke:var(--c3);stroke-width:1.5' });
      S.el('circle', { cx: xs(d[0]), cy: ys(d[1]), r: 5, 'class': 'svg-fill-c3' }, svg);
    });
    var cursor = S.line(svg, 0, Y1, 0, Y0, 'svg-line', { style: 'stroke:var(--accent);stroke-width:1.5;stroke-dasharray:3 3' });
    var fixedBar = S.rect(svg, 0, 0, 10, 0, 'svg-box c1', { rx: 1 });
    var perBar = S.rect(svg, 0, 0, 10, 0, 'svg-box c2', { rx: 1 });
    var aR = $('b-a'), cR = $('b-c'), bR = $('b-b');
    function model(b) { return parseFloat(aR.value) / b + parseFloat(cR.value); }
    function draw() {
      var a = parseFloat(aR.value), c = parseFloat(cR.value);
      setText('b-a-o', a.toFixed(1)); setText('b-c-o', c.toFixed(1));
      var d = '', i;
      for (i = 0; i <= 70; i++) {
        var b = Math.pow(2, i / 10);
        d += (i ? ' L' : 'M') + xs(b).toFixed(1) + ',' + ys(model(b)).toFixed(1);
      }
      curve.setAttribute('d', d);
      floor.setAttribute('d', 'M' + X0 + ',' + ys(c).toFixed(1) + ' L' + X1 + ',' + ys(c).toFixed(1));
      var B = Math.pow(2, parseInt(bR.value, 10));
      setText('b-b-o', B);
      var x = xs(B);
      cursor.setAttribute('x1', x); cursor.setAttribute('x2', x);
      var fixed = a / B, tot = fixed + c;
      fixedBar.setAttribute('x', x + 6); fixedBar.setAttribute('width', 10);
      fixedBar.setAttribute('y', ys(tot)); fixedBar.setAttribute('height', Math.max(0, ys(c) - ys(tot)));
      perBar.setAttribute('x', x + 6); perBar.setAttribute('width', 10);
      perBar.setAttribute('y', ys(c)); perBar.setAttribute('height', Math.max(0, Y0 - ys(c)));
      var meas = null;
      data.forEach(function (r) { if (r[0] === B) meas = r; });
      setText('b-meas', meas ? meas[1].toFixed(1) : '-');
      setText('b-model', tot.toFixed(1));
      setText('b-fixed', (100 * fixed / tot).toFixed(0) + '%');
      setText('b-mpps', meas ? (2.7e3 / meas[1]).toFixed(0) : '-');
      var sse = 0;
      data.forEach(function (r) { var e = r[1] - model(r[0]); sse += e * e; });
      setText('b-rms', Math.sqrt(sse / data.length).toFixed(1));
    }
    [aR, cR, bR].forEach(function (r) { r.addEventListener('input', draw); });
    $('b-fit').addEventListener('click', function () { aR.value = fit[0]; cR.value = fit[1]; draw(); });
    aR.value = fit[0]; cR.value = fit[1];
    draw();
  }

  CourseJS.ready(function () {
    stateMachine();
    descRing();
    ownership();
    fpops();
    burstChart();
  });
})();

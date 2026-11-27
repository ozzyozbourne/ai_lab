/* Chapter 9 widgets. Uses only ../../assets/course.js (CourseJS) and CSS
 * variables, so everything follows the light/dark theme and works offline.
 *
 *   1. backends   - "same app, many backends": pick a PMD, see its data path,
 *                   per-packet costs and the measured ladder number.
 *   2. devmodel   - device model explorer: add vdevs, type a devargs filter,
 *                   see which devices RTE_DEV_FOREACH / RTE_ETH_FOREACH_MATCHING_DEV
 *                   visit, with the parsing rules (and crashes) of DPDK 26.11.
 *   3. probe      - vdev probe pipeline, a predict-then-step Stepper.
 *   4. afxdp      - AF_XDP UMEM and its four rings, an Animator.
 *   5. ladder     - measured software-PMD ladder (median, min/max whiskers).
 *   6. fwdmodes   - what each testpmd forward mode does to one packet.
 */
(function () {
  'use strict';
  var CJ = window.CourseJS;
  var S = CJ.svg;

  /* Measured by code/ladder.sh on this VM (median of 5, Mpps). Kept in one
   * place: widget 1 and widget 5 both read it. */
  var LADDER = [
    { id: 'ring', name: 'ring', mode: 'io, 2 ports, tx_first', med: 315.48, min: 306.41, max: 317.57 },
    { id: 'nullrx', name: 'null rxonly', mode: 'rxonly, 2 ports', med: 132.84, min: 128.48, max: 136.14 },
    { id: 'null', name: 'null', mode: 'io, 2 ports', med: 107.04, min: 102.72, max: 112.94 },
    { id: 'nullcopy', name: 'null copy=1', mode: 'rxonly, 2 ports', med: 92.12, min: 85.18, max: 92.26 },
    { id: 'pcap', name: 'pcap', mode: 'io loop, infinite_rx', med: 56.99, min: 56.92, max: 57.06 },
    { id: 'memif', name: 'memif', mode: 'io loop, 2 processes', med: 9.75, min: 6.75, max: 10.00 },
    { id: 'vhost', name: 'vhost-user', mode: 'io loop, 2 processes', med: 7.94, min: 6.28, max: 8.08 },
    { id: 'tap', name: 'tap', mode: 'txonly into kernel', med: 3.06, min: 2.87, max: 3.11 },
    { id: 'afxdp', name: 'af_xdp', mode: 'io, veth pair, tx_first', med: 2.00, min: 1.87, max: 2.09 },
    { id: 'afpacket', name: 'af_packet', mode: 'io, veth pair, tx_first', med: 1.65, min: 1.54, max: 1.82 }
  ];
  function ladderOf(id) { for (var i = 0; i < LADDER.length; i++) if (LADDER[i].id === id) return LADDER[i]; return null; }

  function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }

  /* ================================================================
   * 1. Same app, many backends
   * ================================================================ */
  function initBackends() {
    var root = document.getElementById('w-backends');
    if (!root) return;
    var svg = root.querySelector('svg');
    var info = root.querySelector('.ch9-info');
    var B = {
      null: { title: 'net_null', ladder: 'null', ptr: 0, copy: 0, sys: 0,
        layers: ['net_null rx: alloc mbufs, set length', 'net_null tx: count, free mbufs'],
        kernel: null,
        text: 'RX allocates mbufs from your pool and sets their length; TX counts and frees them. No data moves at all, so this measures the cost of <em>your</em> loop plus mbuf alloc/free. <code>copy=1</code> adds one memcpy per packet each way.' },
      ring: { title: 'net_ring', ladder: 'ring', ptr: 1, copy: 0, sys: 0,
        layers: ['tx: rte_ring_enqueue_burst(mbuf pointers)', 'rx: rte_ring_dequeue_burst(same ring)'],
        kernel: null,
        text: 'TX enqueues mbuf <em>pointers</em> on an rte_ring, RX dequeues them. Nothing is allocated, copied or freed, so it is the fastest backend and also the least realistic. It does not count bytes (Rx-bps stays 0).' },
      pcap: { title: 'net_pcap', ladder: 'pcap', ptr: 0, copy: 1, sys: 1,
        layers: ['rx: libpcap reads a record, memcpy into an mbuf', 'tx: libpcap writes the record (fwrite)'],
        kernel: 'page cache (file I/O)',
        text: 'RX copies each record of a pcap file into an mbuf; TX appends to a pcap file through libpcap. With <code>infinite_rx=1</code> the file is loaded once into mbufs and replayed, which is why the ladder number is high. <code>rx_iface=</code> reads a live kernel interface instead.' },
      tap: { title: 'net_tap', ladder: 'tap', ptr: 0, copy: 1, sys: 1,
        layers: ['tx: writev() on the tap fd, one call per packet', 'rx: readv() into mbuf segments'],
        kernel: 'tap netdev ch09tap0 (full kernel stack)',
        text: 'A real kernel netdev appears (<code>ip link</code> shows it). Every packet crosses the user/kernel boundary with a <code>readv</code>/<code>writev</code> system call and a copy, so it is slow but shows up in <code>ip -s link</code> and works with any kernel tool.' },
      afpacket: { title: 'net_af_packet', ladder: 'afpacket', ptr: 0, copy: 1, sys: 1,
        layers: ['tx: copy into PACKET_MMAP TX ring, send() kick', 'rx: copy out of PACKET_MMAP RX ring'],
        kernel: 'AF_PACKET socket on veth ch09a',
        text: 'Attaches to an existing kernel interface (here a veth). The RX/TX rings are memory shared with the kernel (PACKET_MMAP); the PMD copies between those frames and mbufs, and a <code>send()</code> call kicks transmission. <code>qpairs=N,fanout_mode=hash</code> spreads flows across queues.' },
      afxdp: { title: 'net_af_xdp', ladder: 'afxdp', ptr: 0, copy: 1, sys: 1,
        layers: ['UMEM frames + fill / rx / tx / completion rings', 'XDP program redirects frames to the socket'],
        kernel: 'XDP hook on veth ch09b (copy mode)',
        text: 'An XDP program in the driver redirects frames into an AF_XDP socket whose buffers (UMEM) are shared with user space. On real NIC drivers this can be zero-copy; on a veth it runs in copy mode, so here it is only a little faster than af_packet. See the AF_XDP rings animation below.' }
    };
    var order = ['null', 'ring', 'pcap', 'tap', 'afpacket', 'afxdp'];
    var ctrl = root.querySelector('.ch9-backend-btns');
    var cur = 'null', g, pkts = [], pathY = [];
    order.forEach(function (k) {
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'btn small'; b.textContent = B[k].title;
      b.setAttribute('data-k', k);
      b.addEventListener('click', function () { select(k); });
      ctrl.appendChild(b);
    });

    function draw() {
      S.clear(svg);
      var be = B[cur];
      S.box(svg, 200, 10, 240, 44, 'your forwarding loop', 'c1');
      S.text(svg, 320, 70, 'rte_eth_rx_burst() / rte_eth_tx_burst()  (ethdev API, unchanged)', 'svg-label center small mono');
      S.line(svg, 60, 80, 580, 80, 'svg-line');
      S.box(svg, 140, 92, 360, 34, be.layers[0], 'c5');
      S.box(svg, 140, 132, 360, 34, be.layers[1], 'c5');
      if (be.kernel) {
        S.line(svg, 60, 178, 580, 178, 'svg-line');
        S.text(svg, 64, 174, 'user', 'svg-label small muted');
        S.text(svg, 64, 192, 'kernel', 'svg-label small muted');
        S.box(svg, 160, 198, 320, 34, be.kernel, 'c6');
      } else {
        S.text(svg, 320, 200, 'no kernel involved: everything stays in this process', 'svg-label center small muted');
      }
      S.arrow(svg, 300, 54, 300, 90, 'c3');
      S.arrow(svg, 340, 90, 340, 56, 'c3');
      pathY = be.kernel ? [30, 110, 150, 215] : [30, 110, 150];
      g = S.group(svg);
      pkts = [];
      for (var i = 0; i < 5; i++) pkts.push({ el: S.packet(g, 240, 30, 18, 11, null), t: i / 5 });
      CJ.$$('button', ctrl).forEach(function (b) { b.classList.toggle('primary', b.getAttribute('data-k') === cur); });
      var L = ladderOf(be.ladder);
      info.innerHTML = '<strong>' + be.title + '</strong>: ' + be.text +
        '<div class="ch9-costs"><span>pointer pass per pkt: <b>' + (be.ptr ? 'yes' : 'no') + '</b></span>' +
        '<span>data copy per pkt: <b>' + (be.copy ? 'yes' : (cur === 'null' ? 'only with copy=1' : 'no')) + '</b></span>' +
        '<span>system call / kernel: <b>' + (be.sys ? 'yes' : 'no') + '</b></span>' +
        '<span>measured here: <b>' + (L ? L.med.toFixed(2) + ' Mpps' : '-') + '</b> <span class="muted">(' + (L ? L.mode : '') + ')</span></span></div>';
    }
    function select(k) { cur = k; draw(); }
    draw();

    new CJ.Animator({
      root: root, autoplay: 'visible',
      onReset: function () { draw(); },
      onFrame: function (dt) {
        var L = ladderOf(B[cur].ladder);
        /* speed scales with log10 of the measured rate, so slow backends look slow */
        var v = 0.08 + 0.12 * Math.log10(1 + (L ? L.med : 1));
        var n = pathY.length - 1;
        pkts.forEach(function (p, i) {
          p.t = (p.t + dt * v) % 1;
          /* down through the layers on the left (rx), back up on the right (tx) */
          var u = p.t * 2, x, y, seg;
          if (u < 1) { seg = Math.min(n - 1, Math.floor(u * n)); var f = u * n - seg; x = 250 + i * 6; y = CJ.lerp(pathY[n - seg], pathY[n - seg - 1], f); }
          else { u -= 1; seg = Math.min(n - 1, Math.floor(u * n)); f = u * n - seg; x = 390 + i * 6; y = CJ.lerp(pathY[seg], pathY[seg + 1], f); }
          S.moveTo(p.el, x, y);
        });
      }
    });
  }

  /* ================================================================
   * 2. Device model explorer
   * ================================================================ */
  function initDevModel() {
    var root = document.getElementById('w-devmodel');
    if (!root) return;
    var svg = root.querySelector('svg');
    var input = root.querySelector('#dm-filter');
    var modeSel = root.querySelector('#dm-mode');
    var out = root.querySelector('.ch9-parse');
    var devs = [];
    var counters = {};
    var DRV = {
      net_null: { cls: 'eth' }, net_ring: { cls: 'eth' }, net_tap: { cls: 'eth' },
      net_pcap: { cls: 'eth' }, crypto_null: { cls: 'crypto' }
    };
    function randMac() {
      var h = [];
      for (var i = 0; i < 6; i++) h.push(('0' + Math.floor(Math.random() * 256).toString(16)).slice(-2).toUpperCase());
      h[0] = ((parseInt(h[0], 16) & 0xfe) | 0x02).toString(16).toUpperCase(); if (h[0].length < 2) h[0] = '0' + h[0];
      return h.join(':');
    }
    function add(drv) {
      var n = counters[drv] || 0; counters[drv] = n + 1;
      var d = { name: drv + n, drv: drv, bus: 'vdev', cls: DRV[drv].cls };
      if (d.cls === 'eth') {
        d.port = devs.filter(function (x) { return x.cls === 'eth'; }).length;
        d.mac = drv === 'net_ring' ? '00:00:00:00:00:00' : randMac();
      }
      devs.push(d);
      render();
    }
    CJ.$$('[data-add]', root).forEach(function (b) {
      b.addEventListener('click', function () { if (devs.length < 9) add(b.getAttribute('data-add')); });
    });
    root.querySelector('[data-reset]').addEventListener('click', function () {
      devs = []; counters = {}; add('net_null'); add('net_null'); add('net_ring'); add('crypto_null');
    });
    CJ.$$('[data-preset]', root).forEach(function (b) {
      b.addEventListener('click', function () {
        var p = b.getAttribute('data-preset');
        if (p === '@mac1') { var e = devs.filter(function (x) { return x.port === 1; })[0]; p = 'class=eth,mac=' + (e ? e.mac : '00:00:00:00:00:00'); }
        input.value = p; modeSel.value = b.getAttribute('data-mode') || modeSel.value; render();
      });
    });
    input.addEventListener('input', render);
    modeSel.addEventListener('change', render);

    /* kvargs-like split: "k=v,k2=v2" */
    function kv(str) {
      var o = {}, keys = [];
      str.split(',').forEach(function (p) {
        if (!p) return;
        var i = p.indexOf('=');
        var k = i < 0 ? p : p.slice(0, i), v = i < 0 ? null : p.slice(i + 1);
        o[k] = v; keys.push(k);
      });
      o._keys = keys;
      return o;
    }
    /* rte_devargs_layers_parse(): split on "/" followed by bus=|class=|driver= */
    function layers(str) {
      var parts = str.split(/\/(?=(?:bus|class|driver)=)/);
      var r = { bus: null, cls: null, drv: null, bus_str: null, cls_str: null, drv_str: null };
      for (var i = 0; i < parts.length; i++) {
        var k = kv(parts[i]), first = k._keys[0];
        if (first === 'bus') { r.bus = k.bus; r.bus_str = parts[i]; r.busKv = k; }
        else if (first === 'class') { r.cls = k['class']; r.cls_str = parts[i]; r.clsKv = k; }
        else if (first === 'driver') { r.drv = k.driver; r.drv_str = parts[i]; }
      }
      return r;
    }
    function legacy(str) {   /* "[bus:]name[,args]" */
      var bus = null, rest = str, m = /^(pci|vdev):(.*)$/.exec(str);
      if (m) { bus = m[1]; rest = m[2]; }
      var i = rest.indexOf(',');
      return { bus: bus, name: i < 0 ? rest : rest.slice(0, i), args: i < 0 ? '' : rest.slice(i + 1) };
    }
    function genericMatch(str) {
      if (str === '') return { err: 'no bus and no class layer: rte_dev_iterator_init() fails (EINVAL), the loop visits nothing' };
      var L = layers(str);
      if (L.bus && L.bus !== 'vdev' && L.bus !== 'pci') return { err: 'Could not find bus "' + L.bus + '" (-EFAULT)' };
      if (L.cls && L.cls !== 'eth') return { err: 'Could not find class "' + L.cls + '": only the eth class is registered as an rte_class in 26.11' };
      if (!L.bus && !L.cls) return { err: 'Either bus or class must be specified (EINVAL)' };
      var hit = devs.filter(function (d) {
        if (L.bus && d.bus !== L.bus) return false;
        if (L.busKv && L.busKv.name != null && d.name !== L.busKv.name) return false;
        if (L.cls && d.cls !== L.cls) return false;
        if (L.clsKv && L.clsKv.mac != null && d.mac !== L.clsKv.mac.toUpperCase()) return false;
        return true;
      });
      var warn = /\//.test(str) ? 'This filter has a "/": the string is split in place, so pass a writable buffer (a string literal crashes).' : '';
      return { hit: hit, state: 'bus_str=' + (L.bus_str || '(null)') + '  cls_str=' + (L.cls_str || '(null)'), warn: warn };
    }
    function ethMatch(str) {
      var eth = devs.filter(function (d) { return d.cls === 'eth'; });
      if (str.indexOf('class=eth,') === 0) {
        var k = kv(str.slice(10));
        var bad = k._keys.filter(function (x) { return x !== 'mac' && x !== 'representor'; });
        if (bad.length) return { err: 'eth class only knows the keys mac and representor: "' + bad[0] + '" makes rte_kvargs_parse() fail, no port matches', hit: [] };
        return { hit: eth.filter(function (d) { return k.mac == null || d.mac === k.mac.toUpperCase(); }),
          state: 'pure class filter: bus=(none)  cls_str="' + str.slice(10) + '"' };
      }
      if (/^(bus|class)=/.test(str)) {
        var L = layers(str);
        if (!L.drv_str) return { crash: true, err: 'SIGSEGV: rte_devargs_parse() leaves devargs.args NULL for a filter without a driver layer, and rte_eth_iterator_init() calls strlen() on it (DPDK 26.11). Use "class=eth,..." or the simplified "name" form.' };
        if (L.cls && L.cls !== 'eth') return { err: 'Could not find class "' + L.cls + '"' };
        return { hit: [], state: 'bus_str="name=" (empty device name) cls_str="+' + L.drv_str + '"', err: 'parses, but the bus part becomes "name=" with an empty name, so no port matches' };
      }
      var P = legacy(str);
      var d = devs.filter(function (x) { return x.name === P.name; })[0];
      if (!d) return { err: 'failed to parse device "' + str + '": no bus recognises "' + P.name + '" (-EFAULT)' };
      if (d.cls !== 'eth') return { hit: [], state: 'bus_str="name=' + P.name + '"', err: d.name + ' exists but is not an ethdev port' };
      return { hit: [d], state: 'bus_str="name=' + P.name + '"  cls_str="+' + P.args + '" (old-syntax args are ignored)' };
    }

    function render() {
      S.clear(svg);
      var str = input.value.trim();
      var mode = modeSel.value;
      var r = mode === 'eth' ? ethMatch(str) : genericMatch(str);
      var hitNames = (r.hit || []).map(function (d) { return d.name; });
      /* buses */
      S.box(svg, 10, 10, 110, 40, 'bus: vdev', 'c7');
      S.box(svg, 10, 214, 110, 40, 'bus: pci', 'c7');
      S.text(svg, 65, 270, '--no-pci: not scanned', 'svg-label center small muted');
      S.box(svg, 520, 40, 110, 40, 'class: eth', 'c4');
      var cb = S.box(svg, 520, 150, 115, 40, 'no rte_class', 'c7'); cb.label.setAttribute('class', 'svg-label center small');
      S.text(svg, 577, 204, 'crypto devices', 'svg-label center small muted');
      devs.forEach(function (d, i) {
        var y = 12 + i * 21, x = 170;
        var hit = hitNames.indexOf(d.name) >= 0;
        var rect = S.rect(svg, x, y, 300, 18, 'svg-box ' + (d.cls === 'eth' ? 'c3' : 'c2') + (hit ? ' svg-highlight' : ''), { rx: 4 });
        if (!hit && str !== '') rect.setAttribute('opacity', '0.55');
        S.text(svg, x + 6, y + 13, d.name + (d.port != null ? '  port ' + d.port : '') + (d.mac ? '  ' + d.mac : ''), 'svg-label small mono');
        S.path(svg, 'M120,30 C145,30 145,' + (y + 9) + ' ' + x + ',' + (y + 9), 'svg-line');
        var cy = d.cls === 'eth' ? 60 : 170;
        S.path(svg, 'M470,' + (y + 9) + ' C495,' + (y + 9) + ' 495,' + cy + ' 520,' + cy, 'svg-line');
      });
      var html = '';
      if (r.crash) html += '<div class="ch9-bad"><strong>Process dies:</strong> ' + esc(r.err) + '</div>';
      else {
        if (r.err) html += '<div class="ch9-bad">' + esc(r.err) + '</div>';
        if (r.state) html += '<div class="mono small">' + esc(r.state) + '</div>';
        if (r.hit) html += '<div>' + (mode === 'eth' ? 'ports visited: ' : 'devices visited: ') +
          '<strong>' + (r.hit.length ? r.hit.map(function (d) { return mode === 'eth' ? d.port + ' (' + d.name + ')' : d.name; }).join(', ') : 'none') + '</strong></div>';
        if (r.warn) html += '<div class="muted small">' + esc(r.warn) + '</div>';
      }
      out.innerHTML = html;
    }
    devs = []; add('net_null'); add('net_null'); add('net_ring'); add('crypto_null');
  }

  /* ================================================================
   * 3. vdev probe pipeline (predict, then step)
   * ================================================================ */
  function initProbe() {
    var root = document.getElementById('w-probe');
    if (!root) return;
    var svg = root.querySelector('svg');
    var stages = [
      { t: '--vdev string', s: ['net_null0,size=64', 'still just argv'] },
      { t: 'struct rte_devargs', s: ['bus=vdev name=net_null0', 'args="size=64"'] },
      { t: 'vdev bus scan', s: ['one rte_vdev_device', 'named "net_null0"'] },
      { t: 'driver match', s: ['"net_null0" starts', 'with "net_null"'] },
      { t: 'driver probe()', s: ['rte_kvargs_parse(', '"size=64", keys)'] },
      { t: 'ethdev port', s: ['port 0 allocated,', 'probing_finish()'] }
    ];
    var boxes = [];
    var BW = 196, BH = 74;
    function pos(i) { var col = i % 3, row = Math.floor(i / 3); return { x: 12 + col * 212, y: 14 + row * 104 }; }
    stages.forEach(function (st, i) {
      var P = pos(i);
      var g = S.group(svg, 'svg-fade');
      g.rect = S.rect(g, P.x, P.y, BW, BH, 'svg-box c7');
      g.t = S.text(g, P.x + BW / 2, P.y + 20, st.t, 'svg-label center bold');
      g.s1 = S.text(g, P.x + BW / 2, P.y + 42, st.s[0], 'svg-label center small mono');
      g.s2 = S.text(g, P.x + BW / 2, P.y + 60, st.s[1], 'svg-label center small mono');
      g.num = S.text(g, P.x + 12, P.y + 18, String(i + 1), 'svg-label small muted');
      boxes.push(g);
      if (i % 3 < 2) S.arrow(svg, P.x + BW, P.y + BH / 2, P.x + 212, P.y + BH / 2, 'c7');
    });
    S.path(svg, 'M' + (pos(2).x + BW / 2) + ',' + (pos(2).y + BH) + ' C' + (pos(2).x + BW / 2) + ',104 ' +
      (pos(3).x + BW / 2) + ',100 ' + (pos(3).x + BW / 2) + ',' + (pos(3).y - 2), 'svg-arrow c7');
    var marker = S.el('circle', { r: 7, 'class': 'svg-fill-c3 svg-pulse', cx: -50, cy: -50 }, svg);
    function lit(n, cls) {
      boxes.forEach(function (b, i) {
        b.rect.setAttribute('class', 'svg-box ' + (i < n ? 'c2' : i === n ? (cls || 'c3') + ' svg-highlight' : 'c7'));
      });
      var P = pos(n);
      marker.setAttribute('cx', P.x + BW - 12); marker.setAttribute('cy', P.y + 14);
    }
    new CJ.Stepper(root, {
      reset: function () {
        boxes.forEach(function (b) { b.rect.setAttribute('class', 'svg-box c7'); });
        marker.setAttribute('cx', -50); marker.setAttribute('cy', -50);
      },
      steps: [
        { caption: 'The application is started with <code>--vdev=net_null0,size=64</code>. Nothing has happened yet: it is just a string in <code>argv</code>.',
          run: function () { lit(0); } },
        { caption: '<code>rte_eal_init()</code> parses the option into a <code>struct rte_devargs</code> (bus, name, args) and adds it to the EAL devargs list. <code>rte_devargs_parse()</code> does the same split; <code>kvargs_demo</code> prints it.',
          run: function () { lit(1); } },
        { caption: 'Bus scan: the vdev bus walks the devargs that belong to it and creates one <code>struct rte_vdev_device</code> per entry. PCI would read sysfs instead; vdevs exist only because you named them.',
          run: function () { lit(2); } },
        { caption: 'Bus probe: for each device the vdev bus looks for a registered driver whose name (or alias) is a <em>prefix</em> of the device name. <code>net_null0</code> starts with <code>net_null</code>, so <code>RTE_PMD_REGISTER_VDEV(net_null, ...)</code> wins.',
          run: function () { lit(3); },
          predict: { question: 'You pass <code>--vdev=net_null_lab</code> (no digit at the end). What happens?',
            options: ['It is probed by net_null: matching is by name prefix', 'EAL rejects it: the name must end in a number', 'No driver is found and EAL init fails'],
            answer: 0, explain: 'vdev_probe_all_drivers() compares strncmp(device, driver->name, strlen(driver->name)). The trailing number is only a convention that keeps names unique; the chapter runs net_null_lab to show it.' } },
        { caption: 'The driver\'s <code>probe()</code> runs. It reads <code>rte_vdev_device_args()</code> ("size=64"), parses it with <code>rte_kvargs_parse()</code> against its own key list and fills its private config. An unknown key makes probe fail.',
          run: function () { lit(4); },
          predict: { question: '<code>--vdev=net_null0,colour=red</code>: what does <code>rte_eal_init()</code> do?',
            options: ['Ignores the unknown key and creates the port', 'Logs "Failed to probe device", still returns success, and the app has no port 0', 'Returns an error and the app exits'],
            answer: 1, explain: 'net_null passes a valid-key list to rte_kvargs_parse(), which returns NULL for "colour", so probe fails. The EAL logs "EAL: Failed to probe device net_null0" and "Bus (vdev) probe failed." but rte_eal_init() succeeds: check rte_eth_dev_count_avail() yourself (run.sh captures this).'} },
        { caption: 'The driver allocates an ethdev (<code>rte_eth_vdev_allocate()</code>), installs its <code>eth_dev_ops</code>, and calls <code>rte_eth_dev_probing_finish()</code>. The port gets the next free id (0) and is now visible to <code>RTE_ETH_FOREACH_DEV</code>. The same pipeline runs later for <code>rte_vdev_init()</code>, <code>rte_dev_probe()</code> and testpmd\'s <code>port attach</code>.',
          run: function () { lit(5, 'c4'); } }
      ]
    });
  }

  /* ================================================================
   * 4. AF_XDP: UMEM and the four rings
   * ================================================================ */
  function initAfxdp() {
    var root = document.getElementById('w-afxdp');
    if (!root) return;
    var svg = root.querySelector('svg');
    var NF = 16, RS = 8;
    var rate = root.querySelector('#ax-rate'), rateOut = root.querySelector('#ax-rate-out');
    var noFill = root.querySelector('#ax-nofill');
    var st = {};
    var RING = {
      fill: { x: 20, y: 150, label: 'fill ring (user -> kernel)', cls: 'c2' },
      rx: { x: 20, y: 60, label: 'rx ring (kernel -> user)', cls: 'c5' },
      tx: { x: 340, y: 60, label: 'tx ring (user -> kernel)', cls: 'c5' },
      comp: { x: 340, y: 150, label: 'completion ring (kernel -> user)', cls: 'c2' }
    };
    var gStatic, gDyn;
    CJ.bindRange(rate, rateOut, function (v) { return v + ' pkt/s'; });
    function build() {
      S.clear(svg);
      gStatic = S.group(svg); gDyn = S.group(svg);
      S.text(gStatic, 10, 16, 'user space (DPDK af_xdp PMD)', 'svg-label small muted');
      S.line(gStatic, 0, 236, 640, 236, 'svg-line dashed');
      S.text(gStatic, 10, 254, 'kernel: XDP program on veth, redirect into the socket', 'svg-label small muted');
      S.text(gStatic, 320, 30, 'UMEM: ' + NF + ' frames of shared memory', 'svg-label center small bold');
      Object.keys(RING).forEach(function (k) {
        var R = RING[k];
        S.text(gStatic, R.x, R.y - 6, R.label, 'svg-label small');
        for (var i = 0; i < RS; i++) S.rect(gStatic, R.x + i * 34, R.y, 30, 22, 'svg-slot', { rx: 3 });
      });
      S.rect(gStatic, 120, 268, 400, 26, 'svg-box c4', { rx: 4 });
      S.text(gStatic, 320, 285, 'wire / peer (veth ch09a)', 'svg-label center small');
    }
    function reset() {
      st = { free: [], fill: [], rx: [], app: [], tx: [], comp: [], t: 0, acc: 0, tacc: 0,
        recv: 0, sent: 0, drop: 0 };
      for (var i = 0; i < NF; i++) st.free.push(i);
      /* the PMD pre-fills the fill ring at start (reserve_fill_queue() in
       * rte_eth_af_xdp.c); here half full so the effect of not refilling shows quickly */
      while (st.fill.length < 4 && st.free.length) st.fill.push(st.free.shift());
      build();
      draw();
    }
    function slots(ring, arr) {
      var R = RING[ring];
      arr.forEach(function (f, i) {
        if (i >= RS) return;
        var x = R.x + i * 34 + 15, y = R.y + 11;
        S.rect(gDyn, x - 13, y - 9, 26, 18, 'svg-box ' + R.cls, { rx: 3 });
        S.text(gDyn, x, y + 1, '#' + f, 'svg-label center small mono');
      });
    }
    function draw() {
      S.clear(gDyn);
      slots('fill', st.fill); slots('rx', st.rx); slots('tx', st.tx); slots('comp', st.comp);
      S.text(gDyn, 320, 120, 'app holds: ' + (st.app.length ? st.app.map(function (f) { return '#' + f; }).join(' ') : '-') +
        '   free list: ' + st.free.length, 'svg-label center small mono');
      root.querySelector('#ax-recv').textContent = st.recv;
      root.querySelector('#ax-sent').textContent = st.sent;
      root.querySelector('#ax-drop').textContent = st.drop;
      root.querySelector('#ax-fill').textContent = st.fill.length;
    }
    /* one simulation tick: each stage moves at most one frame */
    function tick() {
      /* kernel: completion of a previous TX */
      if (st.tx.length) st.comp.push(st.tx.shift()), st.sent++;
      /* user: reclaim completed frames */
      if (st.comp.length > 1 || (st.comp.length && Math.random() < 0.5)) st.free.push(st.comp.shift());
      /* user: forward what it received (io mode): rx ring -> app -> tx ring */
      if (st.app.length && st.tx.length < RS) st.tx.push(st.app.shift());
      if (st.rx.length) st.app.push(st.rx.shift());
      /* user: refill the fill ring from free frames (unless the learner stops it) */
      if (!noFill.checked && st.fill.length < RS && st.free.length) st.fill.push(st.free.shift());
    }
    function arrive() {
      /* kernel: a packet arrives; it needs a frame from the fill ring */
      if (st.fill.length && st.rx.length < RS) { st.rx.push(st.fill.shift()); st.recv++; }
      else st.drop++;
    }
    reset();
    new CJ.Animator({
      root: root, autoplay: 'visible',
      onReset: reset,
      onFrame: function (dt) {
        st.acc += dt * parseFloat(rate.value);
        st.tacc += dt * 3;
        var changed = false;
        while (st.tacc >= 1) { st.tacc -= 1; tick(); changed = true; }
        while (st.acc >= 1) { st.acc -= 1; arrive(); changed = true; }
        if (changed) draw();
      }
    });
    noFill.addEventListener('change', draw);
  }

  /* ================================================================
   * 5. Ladder chart (median bar, min/max whisker), linear or log scale
   * ================================================================ */
  function initLadder() {
    var root = document.getElementById('w-ladder');
    if (!root) return;
    var svg = root.querySelector('svg');
    var tip = root.querySelector('.ch9-tip');
    var logSel = root.querySelector('#lad-log');
    function draw() {
      S.clear(svg);
      var log = logSel.checked, X0 = 150, W = 460, rowH = 28, top = 20;
      var maxV = 340;
      function sx(v) { return log ? X0 + W * Math.log10(Math.max(v, 1)) / Math.log10(maxV) : X0 + W * v / maxV; }
      var ticks = log ? [1, 3, 10, 30, 100, 300] : [0, 50, 100, 150, 200, 250, 300];
      ticks.forEach(function (t) {
        var x = sx(t);
        S.line(svg, x, top - 6, x, top + LADDER.length * rowH, 'svg-grid');
        S.text(svg, x, top + LADDER.length * rowH + 16, String(t), 'svg-label center small muted');
      });
      S.text(svg, X0 + W / 2, top + LADDER.length * rowH + 34, 'Mpps (median of 5 runs, whiskers = min..max)', 'svg-label center small');
      LADDER.forEach(function (r, i) {
        var y = top + i * rowH;
        var kernel = /tap|af_|memif|vhost/.test(r.name);
        S.text(svg, X0 - 8, y + 16, r.name, 'svg-label small', { 'text-anchor': 'end' });
        var bar = S.rect(svg, X0, y + 5, Math.max(2, sx(r.med) - X0), 16, 'svg-box ' + (kernel ? 'c6' : 'c3'), { rx: 3, tabindex: 0 });
        S.line(svg, sx(r.min), y + 13, sx(r.max), y + 13, 'svg-line', { style: 'stroke-width:2' });
        S.line(svg, sx(r.min), y + 8, sx(r.min), y + 18, 'svg-line', { style: 'stroke-width:2' });
        S.line(svg, sx(r.max), y + 8, sx(r.max), y + 18, 'svg-line', { style: 'stroke-width:2' });
        if (sx(r.max) > 560) S.text(svg, sx(r.min) - 6, y + 17, r.med.toFixed(1), 'svg-label small mono', { 'text-anchor': 'end' });
        else S.text(svg, sx(r.max) + 6, y + 17, r.med.toFixed(r.med < 10 ? 2 : 1), 'svg-label small mono');
        function show() { tip.innerHTML = '<strong>' + esc(r.name) + '</strong> (' + esc(r.mode) + '): median ' + r.med.toFixed(2) + ' Mpps, min ' + r.min.toFixed(2) + ', max ' + r.max.toFixed(2) + '.'; }
        bar.addEventListener('mouseenter', show); bar.addEventListener('focus', show); bar.addEventListener('click', show);
      });
    }
    logSel.addEventListener('change', draw);
    draw();
  }

  /* ================================================================
   * 6. Forward modes: one packet in, what comes out
   * ================================================================ */
  function initFwdModes() {
    var root = document.getElementById('w-fwd');
    if (!root) return;
    var out = root.querySelector('.ch9-fwd-out');
    var IN = { dmac: '02:00:00:00:00:02', smac: '02:00:00:00:00:01', sip: '10.9.0.1', dip: '10.9.1.1', sp: '1000', dp: '53', csum: '0x0000 (none)' };
    var PEER = '02:00:00:00:00:01';
    var TXMAC = '<port1 MAC>';
    var M = {
      io: { rx: 1, tx: 1, d: 'Forwards the mbuf unchanged to the peer port. Cheapest mode; measures the PMDs, not packet processing.', o: {} },
      mac: { rx: 1, tx: 1, d: 'Rewrites dst MAC to the peer (--eth-peer or 02:00:00:00:00:NN) and src MAC to the TX port\'s MAC. Use it when a real switch or DUT checks MACs.', o: { dmac: PEER, smac: TXMAC } },
      macswap: { rx: 1, tx: 1, d: 'Swaps dst and src MAC and sends back. With --port-topology=loop it is a reflector: the classic "loopback a traffic generator" setup.', o: { dmac: IN.smac, smac: IN.dmac } },
      '5tswap': { rx: 1, tx: 1, d: 'Swaps MACs, IPs and L4 ports: a reflector that also works through routers and NAT tests.', o: { dmac: IN.smac, smac: IN.dmac, sip: IN.dip, dip: IN.sip, sp: IN.dp, dp: IN.sp } },
      rxonly: { rx: 1, tx: 0, d: 'Receives and frees. Measures RX cost; with "set verbose 1" it is a packet dumper.', o: null },
      txonly: { rx: 0, tx: 1, d: 'Ignores RX and generates UDP packets (198.18.0.1 -> 198.18.0.2, port 9 -> 9; --txpkts sets length/segments, --txonly-multi-flow varies the source port).', gen: { dmac: PEER, smac: TXMAC, sip: '198.18.0.1', dip: '198.18.0.2', sp: '9 (49153+ with multi-flow)', dp: '9', csum: '0x0000' } },
      flowgen: { rx: 1, tx: 1, d: 'Generates packets for --flowgen-flows=N flows (destination IP 10.253.0.0 + i, i = 0..N-1) with fixed test MACs, and frees what it receives.', gen: { dmac: '00:01:02:03:04:01', smac: '00:01:02:03:04:00', sip: '10.254.0.0', dip: '10.253.0.0 + (i mod N)', sp: '1000', dp: '1001', csum: '0x0000' } },
      csum: { rx: 1, tx: 1, d: 'Parses L2/L3/L4, reads RX checksum flags (counts Bad-ipcsum/Bad-l4csum), recomputes checksums in software or asks for TX offload ("csum set ip|udp|tcp hw|sw"), then forwards.', o: { csum: 'recomputed (TCP) / left 0 (UDP)' } },
      icmpecho: { rx: 1, tx: 1, d: 'Answers ARP requests and ICMP echo requests (ping) addressed to the port, drops everything else. Our UDP packet is dropped.', o: null, drop: true },
      noisy: { rx: 1, tx: 1, d: 'A "noisy VNF": buffers packets in a FIFO (--noisy-tx-sw-buffer-size), flushes after a time, and touches a memory area (--noisy-lkup-*) to simulate cache pressure; inner forwarding is io/mac/macswap/5tswap.', o: {} },
      shared_rxq: { rx: 1, tx: 0, d: 'For PMDs with shared RX queues across ports: receives and reports which member port each packet came from, then frees.', o: null },
      recycle_mbufs: { rx: 1, tx: 1, d: 'Like io, but lets a PMD recycle TX-completed mbufs straight into an RX queue (rte_eth_recycle_mbufs); needs driver support (i40e, ixgbe...).', o: {} },
      ieee1588: { rx: 1, tx: 1, d: 'PTP test mode: enables timestamping and checks PTP frames. Only built with RTE_LIBRTE_IEEE1588; needs a NIC with timestamping (ch19).', o: null }
    };
    var bar = root.querySelector('.ch9-fwd-btns');
    Object.keys(M).forEach(function (k) {
      var b = document.createElement('button');
      b.type = 'button'; b.className = 'btn small'; b.textContent = k; b.setAttribute('data-m', k);
      b.addEventListener('click', function () { show(k); });
      bar.appendChild(b);
    });
    function row(label, a, b) {
      var chg = b != null && b !== a;
      return '<tr><td>' + label + '</td><td class="mono">' + esc(a) + '</td><td class="mono' + (chg ? ' ch9-chg' : '') + '">' + esc(b == null ? a : b) + '</td></tr>';
    }
    function show(k) {
      CJ.$$('button', bar).forEach(function (b) { b.classList.toggle('primary', b.getAttribute('data-m') === k); });
      var m = M[k], h = '<p><strong>' + k + '</strong>: ' + m.d + '</p>';
      h += '<p class="small muted">uses RX: ' + (m.rx ? 'yes' : 'no') + ' &middot; uses TX: ' + (m.tx ? 'yes' : 'no') + '</p>';
      if (m.gen) {
        h += '<div class="table-wrap"><table class="compact"><thead><tr><th>field</th><th>received</th><th>generated packet</th></tr></thead><tbody>';
        ['dmac', 'smac', 'sip', 'dip', 'sp', 'dp', 'csum'].forEach(function (f) { h += row(f, '(ignored)', m.gen[f]); });
        h += '</tbody></table></div>';
      } else if (m.o === null) {
        h += '<p class="ch9-bad">Packet is ' + (m.drop ? 'dropped (not ARP/ICMP echo)' : 'freed after RX: nothing is sent') + '.</p>';
      } else {
        h += '<div class="table-wrap"><table class="compact"><thead><tr><th>field</th><th>received</th><th>sent</th></tr></thead><tbody>';
        ['dmac', 'smac', 'sip', 'dip', 'sp', 'dp', 'csum'].forEach(function (f) { h += row(f, IN[f], m.o[f]); });
        h += '</tbody></table></div>';
      }
      out.innerHTML = h;
    }
    show('macswap');
  }

  CJ.ready(function () {
    initBackends();
    initDevModel();
    initProbe();
    initAfxdp();
    initLadder();
    initFwdModes();
  });
})();

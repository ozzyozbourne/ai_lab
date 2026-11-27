/* Chapter 7 widgets:
 *   w-anat  mbuf anatomy explorer (fields at byte offsets + live data window)
 *   w-chain chain view: chain, rte_pktmbuf_read across a boundary, linearize
 *   w-ref   refcnt and clone (multicast), then an external buffer + free_cb
 *   w-ol    ol_flags bit-board with offload recipes
 * Colours only via course.css variables / classes. Works from file://. */
(function () {
'use strict';
var S = CourseJS.svg;
function el(tag, attrs, parent) { return S.el(tag, attrs || {}, parent); }
function txt(parent, x, y, s, cls, attrs) { return S.text(parent, x, y, s, cls || 'svg-label', attrs); }
function setText(t, s) { t.textContent = s; }
function show(node, on) { node.style.display = on ? '' : 'none'; }

/* =====================================================================
 * Widget A: mbuf anatomy explorer
 * ===================================================================== */
var FIELDS = [
  ['buf_addr', 0, 8, 'const', 'buf_addr', 'Virtual address of the start of this segment\'s buffer (just after the private area). Set once by rte_pktmbuf_init() when the pool is created.'],
  ['buf_iova', 8, 8, 'const', 'buf_iova', 'IO address of the same buffer: what the NIC\'s DMA engine uses. With IOVA as VA (this machine) it equals buf_addr.'],
  ['data_off', 16, 2, 'rx', 'doff', 'Offset of the first data byte from buf_addr. rte_pktmbuf_mtod(m) = buf_addr + data_off. Fresh mbuf: RTE_PKTMBUF_HEADROOM = 128.'],
  ['refcnt', 18, 2, 'rx', 'ref', 'Reference count (16-bit, atomic). Free returns the mbuf to its pool only when it drops to 0. Read with rte_mbuf_refcnt_read().'],
  ['nb_segs', 20, 2, 'rx', 'segs', 'Number of segments in the chain. Meaningful only in the first segment.'],
  ['port', 22, 2, 'rx', 'port', 'Input port id, set by the RX driver. 65535 (RTE_MBUF_PORT_INVALID) when the mbuf did not come from a port.'],
  ['ol_flags', 24, 8, 'rx', 'ol_flags', 'Offload flags: RX status bits from the driver, TX request bits from the app, two internal bits, and dynamic flags. See the bit-board in section 10.'],
  ['packet_type', 32, 4, 'rx', 'ptype', 'Packet type: 4-bit nibbles for L2, L3, L4, tunnel and inner L2/L3/L4, filled by NICs that classify.'],
  ['pkt_len', 36, 4, 'rx', 'pkt_len', 'Total packet length: the sum of data_len over all segments. Only valid in the first segment.'],
  ['data_len', 40, 2, 'rx', 'dlen', 'Amount of data in THIS segment\'s buffer.'],
  ['vlan_tci', 42, 2, 'rx', 'vlan', 'VLAN TCI (CPU order), valid if RTE_MBUF_F_RX_VLAN is set (RX) or used for insertion with RTE_MBUF_F_TX_VLAN.'],
  ['hash', 44, 8, 'rx', 'hash', 'Union: RSS hash (hash.rss), flow director id, QoS scheduler fields, event TX-adapter queue, user tag.'],
  ['vlan_tci_outer', 52, 2, 'rx', 'ovl', 'Outer VLAN TCI for QinQ.'],
  ['buf_len', 54, 2, 'const', 'blen', 'Size of the segment buffer (headroom + data room). 2176 for RTE_MBUF_DEFAULT_BUF_SIZE.'],
  ['pool', 56, 8, 'const', 'pool', 'The mempool this mbuf came from. This is why rte_pktmbuf_free(m) needs no pool argument.'],
  ['next', 64, 8, 'tx', 'next', 'Next segment of a chained packet, NULL in the last (or only) segment. Second cache line: read on TX and when walking chains.'],
  ['tx_offload', 72, 8, 'tx', 'tx_offload', 'Bitfields for TX offloads: l2_len:7, l3_len:9, l4_len:8, tso_segsz:16, outer_l3_len:9, outer_l2_len:7.'],
  ['shinfo', 80, 8, 'tx', 'shinfo', 'Pointer to the shared info of an attached external buffer (refcnt + free callback).'],
  ['priv_size', 88, 2, 'const', 'priv', 'Size of the application private area between the mbuf and its buffer.'],
  ['timesync', 90, 2, 'tx', 'ts', 'Timesync flags for IEEE 1588 (PTP).'],
  ['dynfield1', 92, 36, 'dyn', 'dynfield1[9] (36 B)', 'Spare space handed out at run time by rte_mbuf_dynfield_register(): timestamps, sequence numbers, your own fields (section 11).']
];
var CAT = { 'const': ['c2', 'constant, set at pool creation'], rx: ['c3', 'written per packet by the RX path'], tx: ['c5', 'TX and slow path'], dyn: ['c7', 'dynamic fields'] };

function anatomy() {
  var root = document.getElementById('w-anat');
  if (!root) return;
  var svg = root.querySelector('svg');
  var info = root.querySelector('.ch7-info');
  var logEl = root.querySelector('.ch7-log');
  var X0 = 40, BW = 600 / 64;
  var rowY = [38, 116], RH = 40;
  var rects = {};
  var selected = null;

  // rows and rulers
  [0, 1].forEach(function (r) {
    txt(svg, 20, rowY[r] + RH / 2, 'CL' + r, 'svg-label small center bold');
    for (var b = 0; b <= 64; b += 8) {
      var x = X0 + b * BW;
      el('line', { x1: x, y1: rowY[r] - 4, x2: x, y2: rowY[r], 'class': 'svg-line' }, svg);
      txt(svg, x, rowY[r] - 11, String(b + r * 64), 'svg-label small center muted');
    }
  });
  FIELDS.forEach(function (f) {
    var r = f[1] >= 64 ? 1 : 0, off = f[1] - r * 64;
    var x = X0 + off * BW, w = f[2] * BW;
    var g = el('g', { 'class': 'ch7-field', tabindex: '0', role: 'button', 'aria-label': f[0] + ', offset ' + f[1] + ', ' + f[2] + ' bytes' }, svg);
    var rc = el('rect', { x: x + 0.5, y: rowY[r], width: w - 1, height: RH, rx: 3, 'class': 'svg-box ' + CAT[f[3]][0] + (f[3] === 'dyn' ? ' dashed' : '') }, g);
    var fs = w < 20 ? 8 : (w < 40 ? 9.5 : 11);
    txt(g, x + w / 2, rowY[r] + RH / 2, f[4], 'svg-label center', { style: 'font-size:' + fs + 'px' });
    rects[f[0]] = rc;
    function pick() { select(f[0]); }
    g.addEventListener('click', pick);
    g.addEventListener('mouseenter', pick);
    g.addEventListener('focus', pick);
    g.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(); } });
  });
  // group brackets under line 0
  function bracket(b0, b1, y, label) {
    var x0 = X0 + b0 * BW + 1, x1 = X0 + b1 * BW - 1;
    S.path(svg, 'M' + x0 + ',' + (y - 4) + ' L' + x0 + ',' + y + ' L' + x1 + ',' + y + ' L' + x1 + ',' + (y - 4), 'svg-line');
    txt(svg, (x0 + x1) / 2, y + 10, label, 'svg-label small center muted');
  }
  bracket(16, 24, rowY[0] + RH + 6, 'rearm_data: 1 store');
  bracket(32, 56, rowY[0] + RH + 6, 'rx_descriptor_fields1 (24 B)');

  // ----- buffer bar -----
  var BUF = 2176, HR = 128, BX = 40, BWID = 600, BY = 232, BH = 34;
  function bx(o) { return BX + o * BWID / BUF; }
  txt(svg, BX, 194, 'The buffer, to scale: buf_len = 2176 (128 headroom + 2048 data room)', 'svg-label small bold');
  var rHead = el('rect', { x: BX, y: BY, width: 10, height: BH, 'class': 'svg-slot' }, svg);
  var rData = el('rect', { x: BX, y: BY, width: 0, height: BH, 'class': 'svg-box c3' }, svg);
  var rTail = el('rect', { x: BX, y: BY, width: 10, height: BH, 'class': 'svg-slot' }, svg);
  var tHead = txt(svg, 0, BY + BH / 2, '', 'svg-label small center');
  var tData = txt(svg, 0, BY + BH / 2, '', 'svg-label small center bold');
  var tTail = txt(svg, 0, BY + BH / 2, '', 'svg-label small center');
  txt(svg, BX, BY + BH + 16, 'buf_addr', 'svg-label small mono');
  var endT = txt(svg, BX + BWID, BY + BH + 16, 'buf_addr + buf_len', 'svg-label small mono', { 'text-anchor': 'end' });
  endT.setAttribute('text-anchor', 'end');
  var mt = el('g', { 'class': 'svg-fade' }, svg);
  S.path(mt, 'M0,' + (BY - 16) + ' L0,' + (BY - 2), 'svg-arrow c3');
  var mtT = txt(mt, 4, BY - 14, 'mtod(m) = buf_addr + data_off', 'svg-label small mono');
  var nullT = txt(svg, BX + BWID / 2, BY + BH + 40, '', 'svg-label center bold', { 'class': 'svg-label center bold ch7-null' });

  var st = { off: HR, len: 0 };
  var stats = {};
  CourseJS.$$('[data-k]', root).forEach(function (s) { stats[s.getAttribute('data-k')] = s; });

  function draw() {
    var head = st.off, tail = BUF - st.off - st.len;
    rHead.setAttribute('width', Math.max(0, bx(st.off) - BX));
    rData.setAttribute('x', bx(st.off)); rData.setAttribute('width', Math.max(0, bx(st.off + st.len) - bx(st.off)));
    rTail.setAttribute('x', bx(st.off + st.len)); rTail.setAttribute('width', Math.max(0, BX + BWID - bx(st.off + st.len)));
    var wH = bx(st.off) - BX, wD = bx(st.off + st.len) - bx(st.off), wT = BX + BWID - bx(st.off + st.len);
    tHead.setAttribute('x', BX + wH / 2); setText(tHead, wH > 70 ? 'headroom ' + head : (wH > 22 ? String(head) : ''));
    tData.setAttribute('x', bx(st.off) + wD / 2); setText(tData, wD > 60 ? 'data ' + st.len : (wD > 22 ? String(st.len) : ''));
    tTail.setAttribute('x', bx(st.off + st.len) + wT / 2); setText(tTail, wT > 80 ? 'tailroom ' + tail : (wT > 22 ? String(tail) : ''));
    mt.setAttribute('transform', 'translate(' + bx(st.off) + ',0)');
    var anchorEnd = bx(st.off) > BX + BWID - 200;
    mtT.setAttribute('text-anchor', anchorEnd ? 'end' : 'start');
    mtT.setAttribute('x', anchorEnd ? -4 : 4);
    if (stats.off) stats.off.textContent = st.off;
    if (stats.len) stats.len.textContent = st.len;
    if (stats.pkt) stats.pkt.textContent = st.len;
    if (stats.head) stats.head.textContent = head;
    if (stats.tail) stats.tail.textContent = tail;
    if (selected) select(selected);
  }
  function flash(names) {
    names.forEach(function (n) {
      var r = rects[n]; if (!r) return;
      r.classList.add('svg-highlight');
      setTimeout(function () { r.classList.remove('svg-highlight'); if (selected === n) r.classList.add('svg-highlight'); }, 700);
    });
  }
  var nullTimer = null;
  function fail(msg) {
    setText(nullT, msg);
    nullT.classList.add('svg-pulse');
    clearTimeout(nullTimer);
    nullTimer = setTimeout(function () { setText(nullT, ''); nullT.classList.remove('svg-pulse'); }, 1800);
  }
  function log(html) { logEl.innerHTML = html; }

  function select(name) {
    if (selected && rects[selected]) rects[selected].classList.remove('svg-highlight');
    selected = name;
    rects[name].classList.add('svg-highlight');
    var f = FIELDS.filter(function (x) { return x[0] === name; })[0];
    var val = '';
    if (name === 'data_off') val = ' Current value: <strong>' + st.off + '</strong>.';
    if (name === 'data_len' || name === 'pkt_len') val = ' Current value: <strong>' + st.len + '</strong>.';
    if (name === 'buf_len') val = ' Value: <strong>2176</strong>.';
    if (name === 'refcnt' || name === 'nb_segs') val = ' Value: <strong>1</strong>.';
    info.innerHTML = '<code>' + f[0] + '</code> &middot; offset ' + f[1] + ', ' + f[2] + ' byte' + (f[2] > 1 ? 's' : '') +
      ', cache line ' + (f[1] >= 64 ? 1 : 0) + ' &middot; <em>' + CAT[f[3]][1] + '</em><br>' + f[5] + val;
  }

  var nSel = root.querySelector('#anat-n');
  function n() { return parseInt(nSel.value, 10); }
  function act(op) {
    var k = n(), head = st.off, tail = BUF - st.off - st.len;
    if (op === 'append') {
      if (k > tail) { log('<code>rte_pktmbuf_append(m, ' + k + ')</code> returns <strong class="ch7-bad">NULL</strong>: tailroom is ' + tail + '. Nothing changed.'); fail('append: NULL (tailroom ' + tail + ' < ' + k + ')'); return; }
      st.len += k; flash(['data_len', 'pkt_len']);
      log('<code>rte_pktmbuf_append(m, ' + k + ')</code> returns a pointer to the ' + k + ' new bytes at <code>mtod(m) + ' + (st.len - k) + '</code>. data_len and pkt_len grow; data_off does not move.');
    } else if (op === 'prepend') {
      if (k > head) { log('<code>rte_pktmbuf_prepend(m, ' + k + ')</code> returns <strong class="ch7-bad">NULL</strong>: headroom is only ' + head + '. Nothing changed.'); fail('prepend: NULL (headroom ' + head + ' < ' + k + ')'); return; }
      st.off -= k; st.len += k; flash(['data_off', 'data_len', 'pkt_len']);
      log('<code>rte_pktmbuf_prepend(m, ' + k + ')</code> returns the NEW start of data: data_off moves back by ' + k + ', the lengths grow by ' + k + '. Write your header there.');
    } else if (op === 'adj') {
      if (k > st.len) { log('<code>rte_pktmbuf_adj(m, ' + k + ')</code> returns <strong class="ch7-bad">NULL</strong>: only ' + st.len + ' data bytes.'); fail('adj: NULL (data_len ' + st.len + ' < ' + k + ')'); return; }
      st.off += k; st.len -= k; flash(['data_off', 'data_len', 'pkt_len']);
      log('<code>rte_pktmbuf_adj(m, ' + k + ')</code> strips ' + k + ' bytes from the front (removing a header): data_off moves forward. Returns the new start.');
    } else if (op === 'trim') {
      if (k > st.len) { log('<code>rte_pktmbuf_trim(m, ' + k + ')</code> returns <strong class="ch7-bad">-1</strong>: only ' + st.len + ' data bytes.'); fail('trim: -1 (data_len ' + st.len + ' < ' + k + ')'); return; }
      st.len -= k; flash(['data_len', 'pkt_len']);
      log('<code>rte_pktmbuf_trim(m, ' + k + ')</code> cuts ' + k + ' bytes from the tail and returns 0. data_off does not move.');
    } else {
      st.off = HR; st.len = 0; flash(['data_off', 'data_len', 'pkt_len']);
      log('<code>rte_pktmbuf_reset(m)</code>: data_off = 128, lengths 0, the state of a fresh mbuf from <code>rte_pktmbuf_alloc()</code>.');
    }
    draw();
  }
  CourseJS.$$('[data-op]', root).forEach(function (b) {
    b.addEventListener('click', function () { act(b.getAttribute('data-op')); });
  });
  draw();
  select('data_off');
  log('Pick a byte count, then press the buttons. The bar is drawn to scale; the orange box is the data.');
}

/* =====================================================================
 * Widget B: chain view (predict, then step)
 * ===================================================================== */
function chainView() {
  var root = document.getElementById('w-chain');
  if (!root) return;
  var svg = root.querySelector('svg');
  var SX = [20, 250, 480], SW = 180, PX = 4.5, MY = 20, MH = 86, DY = 128, DH = 26;
  var LEN = [20, 40, 40], FILL = ['H', 'a', 'b'];
  var segs = [];
  var names = ['hdr', 'p1', 'p2'];
  var layer = el('g', {}, svg);
  var arrows = [];
  // packet offset -> x in the chained picture
  function px(o) {
    if (o < 20) return SX[0] + o * PX;
    if (o < 60) return SX[1] + (o - 20) * PX;
    return SX[2] + (o - 60) * PX;
  }
  for (var i = 0; i < 3; i++) {
    var g = el('g', { 'class': 'svg-fade' }, layer);
    var box = el('rect', { x: SX[i], y: MY, width: SW, height: MH, rx: 6, 'class': 'svg-box c3' }, g);
    var t0 = txt(g, SX[i] + 8, MY + 16, 'seg ' + i + ': ' + names[i], 'svg-label small bold');
    var l1 = txt(g, SX[i] + 8, MY + 34, '', 'svg-label small mono');
    var l2 = txt(g, SX[i] + 8, MY + 50, '', 'svg-label small mono');
    var l3 = txt(g, SX[i] + 8, MY + 66, '', 'svg-label small mono');
    var l4 = txt(g, SX[i] + 8, MY + 80, '', 'svg-label small muted');
    var bar = el('rect', { x: SX[i], y: DY, width: LEN[i] * PX, height: DH, rx: 3, 'class': 'svg-slot full' }, g);
    var bt = txt(g, SX[i] + LEN[i] * PX / 2, DY + DH / 2, '', 'svg-label small center mono');
    segs.push({ g: g, box: box, t0: t0, l1: l1, l2: l2, l3: l3, l4: l4, bar: bar, bt: bt });
  }
  arrows.push(S.path(layer, 'M' + (SX[0] + SW) + ',' + (MY + 40) + ' L' + (SX[1] - 4) + ',' + (MY + 40), 'svg-arrow c3'));
  arrows.push(S.path(layer, 'M' + (SX[1] + SW) + ',' + (MY + 40) + ' L' + (SX[2] - 4) + ',' + (MY + 40), 'svg-arrow c3'));
  var aLbl = [txt(layer, (SX[0] + SW + SX[1]) / 2, MY + 32, 'next', 'svg-label small center muted'),
              txt(layer, (SX[1] + SW + SX[2]) / 2, MY + 32, 'next', 'svg-label small center muted')];
  var ruler = el('g', {}, svg);
  var win = el('g', { 'class': 'svg-fade' }, svg);
  // tmp buffer
  var TX = 20, TY = 214, TC = 16, TW = 22;
  txt(svg, TX, TY - 8, 'char tmp[16];  (stack buffer passed to rte_pktmbuf_read)', 'svg-label small muted');
  var cells = [], ctext = [];
  for (var c = 0; c < TC; c++) {
    cells.push(el('rect', { x: TX + c * TW, y: TY, width: TW - 2, height: 22, rx: 2, 'class': 'svg-slot svg-fade' }, svg));
    ctext.push(txt(svg, TX + c * TW + (TW - 2) / 2, TY + 11, '', 'svg-label small center mono'));
  }
  var res = txt(svg, TX, 268, '', 'svg-label bold');
  var res2 = txt(svg, TX, 286, '', 'svg-label small muted');
  var poolT = txt(svg, 660, 268, '', 'svg-label small', { 'text-anchor': 'end' });
  poolT.setAttribute('text-anchor', 'end');

  function byteChar(o) { // packet offset -> char, as in chain_demo.c
    if (o < 20) return 'H';
    if (o === 20) return '1';
    if (o < 60) return 'a';
    if (o === 60) return '2';
    return 'b';
  }
  function drawRuler(linear) {
    S.clear(ruler);
    var marks = linear ? [[0, SX[0]], [20, SX[0] + 20 * PX], [60, SX[0] + 60 * PX], [100, SX[0] + 100 * PX]]
                       : [[0, SX[0]], [20, SX[1]], [60, SX[2]], [100, SX[2] + 40 * PX]];
    marks.forEach(function (m) {
      el('line', { x1: m[1], y1: DY + DH + 2, x2: m[1], y2: DY + DH + 8, 'class': 'svg-line' }, ruler);
      txt(ruler, m[1], DY + DH + 18, String(m[0]), 'svg-label small center muted');
    });
    txt(ruler, 676, DY + DH + 34, 'packet offset', 'svg-label small muted', { 'text-anchor': 'end' }).setAttribute('text-anchor', 'end');
  }
  function windowAt(off, len, linear) {
    S.clear(win);
    var pieces = [];
    var o = off, end = Math.min(off + len, 100);
    while (o < end) {
      var segEnd = linear ? 100 : (o < 20 ? 20 : (o < 60 ? 60 : 100));
      var e = Math.min(segEnd, end);
      var x0 = linear ? SX[0] + o * PX : px(o);
      pieces.push([x0, (e - o) * PX]);
      o = e;
    }
    pieces.forEach(function (p) {
      el('rect', { x: p[0] - 1, y: DY - 5, width: p[1] + 2, height: DH + 10, rx: 4, fill: 'none', 'class': 'svg-highlight' }, win);
    });
    if (off + len > 100) {
      el('rect', { x: (linear ? SX[0] + off * PX : px(off)) - 1, y: DY - 5, width: (100 - off) * PX + 40, height: DH + 10, rx: 4, fill: 'none', 'class': 'svg-stroke-c4', 'stroke-width': 2, 'stroke-dasharray': '4 3' }, win);
    }
  }

  var st = new CourseJS.Stepper(root, {
    interval: 2600,
    reset: function (ctx) {
      ctx.data = { chained: 0, linear: false, read: null, anim: null };
    },
    steps: [
      { caption: 'Three separate mbufs from one pool: <code>hdr</code> (20 bytes of H), <code>p1</code> and <code>p2</code> (40 bytes each; the first byte of each is its segment number). Each is a complete 1-segment packet.' },
      { caption: '<code>rte_pktmbuf_chain(hdr, p1)</code>: <code>hdr->next = p1</code>, <code>hdr->nb_segs = 2</code>, <code>hdr->pkt_len = 60</code>. From now on <code>p1</code> is only a segment.',
        run: function (ctx) { ctx.data.chained = 1; } },
      { caption: '<code>rte_pktmbuf_chain(hdr, p2)</code>: nb_segs 3, pkt_len 100. Only the <strong>head</strong> carries pkt_len, nb_segs, ol_flags, port and packet_type; the copies left in p1/p2 are ignored.',
        run: function (ctx) { ctx.data.chained = 2; } },
      { caption: '<code>rte_pktmbuf_read(hdr, 24, 8, tmp)</code>: bytes 24..31 all sit in segment 1, so the function returns a pointer <em>into the mbuf</em> and tmp is untouched.',
        predict: { question: 'Bytes 24..31 of a chain whose segments hold bytes 0-19, 20-59 and 60-99. What does rte_pktmbuf_read return?', options: ['A pointer into segment 1 (no copy)', 'tmp, after copying 8 bytes', 'NULL'], answer: 0, explain: 'The range fits inside one segment, so it is contiguous in memory: no copy is needed.' },
        run: function (ctx) { ctx.data.read = { off: 24, len: 8, mode: 'ptr' }; } },
      { caption: '<code>rte_pktmbuf_read(hdr, 56, 16, tmp)</code>: the range crosses from segment 1 (4 bytes) into segment 2 (12 bytes). They are not adjacent in memory, so the bytes are <strong>copied into tmp</strong> and tmp is returned.',
        predict: { question: 'Now bytes 56..71. What comes back?', options: ['A pointer into segment 1', 'tmp, holding a copy of the 16 bytes', 'NULL'], answer: 1, explain: 'Segments are separate buffers. To give you 16 contiguous bytes the library must copy them into your buffer. chain_demo printed "aaaa2bbbbbbbbbbb".' },
        run: function (ctx, cur) { ctx.data.read = { off: 56, len: 16, mode: 'copy' }; if (cur) ctx.data.anim = 'copy'; } },
      { caption: '<code>rte_pktmbuf_read(hdr, 95, 10, tmp)</code>: 95 + 10 &gt; pkt_len (100). The function returns <strong>NULL</strong>; always check it before using the pointer.',
        run: function (ctx) { ctx.data.read = { off: 95, len: 10, mode: 'null' }; } },
      { caption: '<code>rte_pktmbuf_linearize(hdr)</code>: segment 0 has 2028 bytes of tailroom, so the library copies segments 1 and 2 into it and frees them. nb_segs 1, data_len 100, the packet is contiguous. (It fails with -1 if the first segment is too small.)',
        predict: { question: 'After linearize, how many of the three mbufs are still allocated?', options: ['3', '1', '0'], answer: 1, explain: 'The data moved into the head; the two emptied segments went back to the pool. chain_demo: "pool in_use after linearize : 1".' },
        run: function (ctx) { ctx.data.linear = true; ctx.data.read = null; } }
    ],
    onStep: function (i, ctx) { render(ctx.data); }
  });

  var gen = 0;
  function render(d) {
    gen++;
    var linear = d.linear;
    for (var i = 0; i < 3; i++) {
      var s = segs[i];
      var head = i === 0;
      var chained = d.chained >= i && d.chained > 0;
      var isPart = !head && d.chained >= i;
      s.box.setAttribute('class', 'svg-box ' + (head || !isPart ? 'c3' : 'c7'));
      var dl = linear && head ? 100 : LEN[i];
      var nseg = head ? (linear ? 1 : d.chained + 1) : 1;
      var plen = head ? (linear ? 100 : [20, 60, 100][d.chained]) : LEN[i];
      setText(s.l1, 'data_len=' + dl);
      setText(s.l2, 'pkt_len=' + plen + (isPart ? '  (ignored)' : ''));
      setText(s.l3, 'nb_segs=' + nseg + (isPart ? '  (ignored)' : ''));
      setText(s.l4, (head && d.chained > 0 && !linear) ? 'next = seg 1' : (i === 1 && d.chained === 2 && !linear ? 'next = seg 2' : 'next = NULL'));
      s.bar.setAttribute('width', dl * PX);
      s.bt.setAttribute('x', SX[i] + dl * PX / 2);
      setText(s.bt, linear && head ? 'H×20 1a…a 2b…b (100 bytes)' : (i === 0 ? 'H×20' : (i === 1 ? '1aaa… ×40' : '2bbb… ×40')));
      s.g.style.opacity = (!head && linear) ? '0' : '1';
      chained = chained; // eslint quiet
    }
    segs[0].box.setAttribute('class', 'svg-box c3 svg-highlight');
    if (d.chained === 0) segs[0].box.setAttribute('class', 'svg-box c3');
    arrows[0].style.opacity = aLbl[0].style.opacity = (d.chained >= 1 && !linear) ? '1' : '0';
    arrows[1].style.opacity = aLbl[1].style.opacity = (d.chained >= 2 && !linear) ? '1' : '0';
    drawRuler(linear);
    cells.forEach(function (c, k) { c.setAttribute('class', 'svg-slot svg-fade'); setText(ctext[k], ''); });
    S.clear(win);
    setText(res, ''); setText(res2, '');
    setText(poolT, 'pool in_use = ' + (linear ? 1 : 3));
    if (d.read) {
      windowAt(d.read.off, d.read.len, linear);
      if (d.read.mode === 'ptr') {
        setText(res, 'returns ' + 'mtod_offset(seg 1, 4): a pointer into the mbuf data');
        setText(res2, '"aaaaaaaa" read in place; tmp is unused');
      } else if (d.read.mode === 'copy') {
        var fill = function (k) {
          cells[k].setAttribute('class', 'svg-slot full svg-fade');
          setText(ctext[k], byteChar(56 + k));
        };
        if (d.anim === 'copy') {
          var k = 0, myGen = gen;
          var tick = function () { if (k < TC && myGen === gen) { fill(k); k++; setTimeout(tick, 90); } };
          tick();
        } else for (var q = 0; q < TC; q++) fill(q);
        setText(res, 'returns tmp: 4 bytes copied from seg 1 + 12 from seg 2');
        setText(res2, 'chain_demo output: "aaaa2bbbbbbbbbbb"');
      } else {
        setText(res, 'returns NULL: off + len (105) > pkt_len (100)');
        setText(res2, 'nothing is copied');
      }
    }
    d.anim = null;
  }
}

/* =====================================================================
 * Widget C: refcnt and clone, then external buffer
 * ===================================================================== */
function refcnt() {
  var root = document.getElementById('w-ref');
  if (!root) return;
  var svg = root.querySelector('svg');
  var A = el('g', {}, svg), B = el('g', {}, svg);
  // pools
  var poolY = 272, poolBoxes = [], poolT = [];
  ['data_pool', 'hdr_pool', 'clone_pool'].forEach(function (n, i) {
    var x = 20 + i * 225;
    poolBoxes.push(el('rect', { x: x, y: poolY, width: 205, height: 40, rx: 8, 'class': 'svg-box c2' }, svg));
    poolT.push(txt(svg, x + 102, poolY + 20, n, 'svg-label small center bold'));
  });
  function poolXY(i) { return [20 + i * 225 + 102, poolY + 20]; }

  // ---- group A: multicast ----
  var payG = el('g', {}, A);
  var payBox = el('rect', { x: 20, y: 30, width: 170, height: 46, rx: 6, 'class': 'svg-box c3' }, payG);
  txt(payG, 30, 48, 'payload (direct mbuf)', 'svg-label small bold');
  txt(payG, 30, 66, 'buf_addr → its own buffer', 'svg-label small muted');
  el('rect', { x: 20, y: 98, width: 170, height: 40, rx: 4, 'class': 'svg-slot full' }, payG);
  txt(payG, 105, 118, 'payload bytes (32 B)', 'svg-label small center mono');
  S.path(payG, 'M60,76 L60,95', 'svg-arrow c3');
  var badge = el('g', {}, payG);
  var badgeC = el('circle', { cx: 190, cy: 30, r: 17, 'class': 'svg-fill-c4' }, badge);
  var badgeT = txt(badge, 190, 30, '1', 'svg-label center bold ch7-badge-t');
  txt(payG, 210, 58, 'refcnt', 'svg-label small muted');
  var paySpot = el('g', {}, A); // holder to animate payload freeing
  var doneT = txt(A, 340, 130, '', 'svg-label center muted');
  var dests = [];
  for (var d = 0; d < 3; d++) {
    var y = 24 + d * 76;
    var g = el('g', {}, A);
    var link = S.curve(g, 250, y + 22, 194, 118, 8 - d * 8, 'c5 dashed');
    link.setAttribute('class', 'svg-arrow c5 dashed');
    var cb = el('rect', { x: 250, y: y, width: 140, height: 44, rx: 6, 'class': 'svg-box c5 dashed' }, g);
    txt(g, 320, y + 15, 'clone ' + d, 'svg-label small center bold');
    txt(g, 320, y + 31, 'INDIRECT, 128 B', 'svg-label small center muted');
    var hb = el('rect', { x: 450, y: y, width: 130, height: 44, rx: 6, 'class': 'svg-box c1' }, g);
    txt(g, 515, y + 15, 'hdr ' + d + ' (head)', 'svg-label small center bold');
    txt(g, 515, y + 31, '"DEST-' + d + ': "', 'svg-label small center mono');
    S.path(g, 'M450,' + (y + 22) + ' L394,' + (y + 22), 'svg-arrow c1');
    txt(g, 422, y + 16, 'next', 'svg-label small center muted');
    dests.push({ g: g });
  }
  // ---- group B: external buffer ----
  var emBox = el('g', {}, B);
  el('rect', { x: 20, y: 30, width: 170, height: 46, rx: 6, 'class': 'svg-box c3' }, emBox);
  txt(emBox, 30, 48, 'em (EXTERNAL)', 'svg-label small bold');
  txt(emBox, 30, 66, 'mbuf refcnt stays 1', 'svg-label small muted');
  var extBox = el('rect', { x: 20, y: 110, width: 200, height: 40, rx: 4, 'class': 'svg-box c6' }, B);
  txt(B, 110, 124, 'rte_malloc 1024 B', 'svg-label small center bold');
  txt(B, 110, 140, 'data (buf_len 1000)', 'svg-label small center muted');
  el('rect', { x: 196, y: 110, width: 24, height: 40, 'class': 'svg-box c4' }, B);
  txt(B, 208, 162, 'shinfo (24 B at the end)', 'svg-label small center muted');
  S.path(emBox, 'M60,76 L60,107', 'svg-arrow c3');
  var badgeB = el('g', {}, B);
  el('circle', { cx: 232, cy: 110, r: 17, 'class': 'svg-fill-c4' }, badgeB);
  var badgeBT = txt(badgeB, 232, 110, '1', 'svg-label center bold ch7-badge-t');
  var ecl = [];
  for (var e = 0; e < 2; e++) {
    var yy = 40 + e * 80;
    var gg = el('g', {}, B);
    el('rect', { x: 450, y: yy, width: 140, height: 44, rx: 6, 'class': 'svg-box c5 dashed' }, gg);
    txt(gg, 520, yy + 15, 'c' + (e + 1) + ' = clone(em)', 'svg-label small center bold');
    txt(gg, 520, yy + 31, 'points at ext buffer', 'svg-label small center muted');
    var lk = S.curve(gg, 450, yy + 22, 222, 130, 20 - e * 30, 'c5 dashed');
    lk.setAttribute('class', 'svg-arrow c5 dashed');
    ecl.push(gg);
  }
  var cbT = txt(B, 300, 220, '', 'svg-label bold ch7-cb');

  function fly(node, to, done) { // move node towards a pool and fade it out
    var bb = node.getBBox();
    var fx = bb.x + bb.width / 2, fy = bb.y + bb.height / 2;
    CourseJS.tween({ from: { k: 0 }, to: { k: 1 }, duration: 700, onUpdate: function (v) {
      node.setAttribute('transform', 'translate(' + ((to[0] - fx) * v.k) + ',' + ((to[1] - fy) * v.k) + ') scale(1)');
      node.style.opacity = String(1 - v.k);
    }, onDone: function () { node.style.display = 'none'; if (done) done(); } });
  }
  function appear(node) {
    node.style.opacity = '0';
    CourseJS.tween({ from: { k: 0 }, to: { k: 1 }, duration: 450, onUpdate: function (v) { node.style.opacity = String(v.k); } });
  }
  function bump(t) {
    t.classList.add('svg-pulse');
    setTimeout(function () { t.classList.remove('svg-pulse'); }, 900);
  }

  var stepper = new CourseJS.Stepper(root, {
    interval: 2400,
    reset: function (ctx) {
      ctx.data = { mode: 'A', ref: 1, dests: 0, freed: [], payFree: false, payGone: false, ext: 1, ecl: 0, eFree: [], cb: false, anim: [] };
    },
    steps: [
      { caption: '<code>payload = rte_pktmbuf_alloc(data_pool)</code> and 32 bytes of data. A fresh mbuf is <em>direct</em> (it uses its own buffer) and has refcnt 1.' },
      { caption: 'Destination 0: allocate <code>hdr 0</code> from hdr_pool, <code>clone 0 = rte_pktmbuf_clone(payload, clone_pool)</code>, then <code>rte_pktmbuf_chain(hdr0, clone0)</code>. The clone\'s buf_addr points into payload\'s buffer and payload\'s refcnt goes to 2.',
        run: function (ctx, cur) { ctx.data.dests = 1; ctx.data.ref = 2; if (cur) ctx.data.anim.push('d0'); } },
      { caption: 'Destinations 1 and 2 the same way. Three packets now share one payload buffer; nothing was copied. refcnt = 4 (1 for the payload itself + 3 clones).',
        run: function (ctx, cur) { ctx.data.dests = 3; ctx.data.ref = 4; if (cur) ctx.data.anim.push('d1', 'd2'); } },
      { caption: '<code>rte_pktmbuf_free(payload)</code>: the sender drops its own reference. refcnt 4 → 3 and the buffer stays: the clones still use it. data_pool in_use is still 1.',
        predict: { question: 'refcnt is 4. The program calls rte_pktmbuf_free(payload). What happens?', options: ['refcnt becomes 3; the buffer stays allocated', 'The buffer returns to data_pool; the clones now point at freed memory', 'Nothing: you cannot free an mbuf that has clones'], answer: 0, explain: 'Free means "drop one reference". The mbuf goes back to its pool only when the count reaches 0. clone_extbuf printed "free(payload) -> payload refcnt=3".' },
        run: function (ctx, cur) { ctx.data.ref = 3; ctx.data.payFree = true; if (cur) ctx.data.anim.push('ref'); } },
      { caption: 'The driver sends packet 0 and frees it: <code>hdr 0</code> goes back to hdr_pool, <code>clone 0</code> is detached (payload refcnt 3 → 2) and goes back to clone_pool.',
        run: function (ctx, cur) { ctx.data.freed.push(0); ctx.data.ref = 2; if (cur) ctx.data.anim.push('f0'); } },
      { caption: 'Packet 1 is freed: refcnt 2 → 1.',
        run: function (ctx, cur) { ctx.data.freed.push(1); ctx.data.ref = 1; if (cur) ctx.data.anim.push('f1'); } },
      { caption: 'Packet 2 is freed: the last clone detaches, refcnt reaches 0 and the <strong>payload mbuf returns to data_pool</strong>. All three pools are back to in_use = 0.',
        predict: { question: 'refcnt is 1 and the last packet is freed. Where does the payload mbuf end up?', options: ['Back in data_pool (refcnt hit 0)', 'In clone_pool, together with the clone', 'It stays allocated until the program frees it again'], answer: 0, explain: 'Detaching the last indirect mbuf drops the direct mbuf\'s refcnt to 0, and the library frees it into its own pool (m->pool).' },
        run: function (ctx, cur) { ctx.data.freed.push(2); ctx.data.ref = 0; ctx.data.payGone = true; if (cur) ctx.data.anim.push('f2'); } },
      { caption: 'Part B, external buffer. <code>rte_pktmbuf_ext_shinfo_init_helper()</code> puts the shared info (refcnt + free_cb) in the last 24 bytes of a 1024-byte rte_malloc buffer (buf_len 1000), and <code>rte_pktmbuf_attach_extbuf(em, ...)</code> makes mbuf <code>em</code> use it.',
        run: function (ctx) { ctx.data.mode = 'B'; } },
      { caption: 'Two clones of <code>em</code>. For an external buffer the count lives in <strong>shinfo</strong>: shinfo refcnt = 3, while em\'s own mbuf refcnt stays 1.',
        run: function (ctx, cur) { ctx.data.ecl = 2; ctx.data.ext = 3; if (cur) ctx.data.anim.push('e'); } },
      { caption: 'free(em), then free(c1): shinfo refcnt 3 → 2 → 1. The mbufs go back to their pool; the external memory stays.',
        run: function (ctx, cur) { ctx.data.eFree = ['em', 'c1']; ctx.data.ext = 1; if (cur) ctx.data.anim.push('ef'); } },
      { caption: 'free(c2): the last reference. The library calls <strong>your</strong> <code>free_cb(addr, opaque)</code>; here it calls rte_free(). The pool never owned that memory, so it could not free it itself.',
        predict: { question: 'shinfo refcnt is 1 and c2 is freed. Who releases the 1024-byte buffer?', options: ['The mbuf pool', 'The free_cb you registered in the shinfo', 'Nobody: it leaks'], answer: 1, explain: 'clone_extbuf printed ">>> ext_free_cb(addr=..., opaque="my 1 KiB buffer")" right after the last free.' },
        run: function (ctx, cur) { ctx.data.eFree = ['em', 'c1', 'c2']; ctx.data.ext = 0; ctx.data.cb = true; if (cur) ctx.data.anim.push('cb'); } }
    ],
    onStep: function (i, ctx) { render(ctx.data); }
  });

  function render(dt) {
    var anim = dt.anim; dt.anim = [];
    var isA = dt.mode === 'A';
    show(A, isA); show(B, !isA);
    // pools
    var inUse = isA ? [dt.payGone ? 0 : 1, dt.dests - dt.freed.length, dt.dests - dt.freed.length]
                    : [0, 0, (dt.eFree.indexOf('em') < 0 ? 1 : 0) + dt.ecl - dt.eFree.filter(function (x) { return x !== 'em'; }).length];
    ['data_pool', 'hdr_pool', 'clone_pool'].forEach(function (n, i) { setText(poolT[i], n + '  in_use = ' + inUse[i]); });
    if (isA) {
      setText(badgeT, String(dt.ref));
      if (anim.length) bump(badgeT);
      dests.forEach(function (o, k) {
        o.g.removeAttribute('transform'); o.g.style.opacity = '1';
        var visible = k < dt.dests && dt.freed.indexOf(k) < 0;
        o.g.style.display = visible || anim.indexOf('f' + k) >= 0 ? '' : 'none';
        if (anim.indexOf('d' + k) >= 0) appear(o.g);
        if (anim.indexOf('f' + k) >= 0) fly(o.g, poolXY(2));
      });
      payG.removeAttribute('transform');
      payG.style.opacity = '1';
      payG.style.display = dt.payGone && anim.indexOf('f2') < 0 ? 'none' : '';
      payBox.setAttribute('class', 'svg-box ' + (dt.payFree ? 'c7 dashed' : 'c3'));
      setText(doneT, dt.payGone ? 'every mbuf is back in its own pool (in_use = 0 everywhere)' : '');
      if (anim.indexOf('f2') >= 0) { setTimeout(function () { fly(payG, poolXY(0)); }, 500); }
    } else {
      setText(badgeBT, String(dt.ext));
      if (anim.length) bump(badgeBT);
      ecl.forEach(function (g, k) {
        g.removeAttribute('transform'); g.style.opacity = '1';
        var name = 'c' + (k + 1);
        var gone = dt.eFree.indexOf(name) >= 0;
        var animGone = (anim.indexOf('ef') >= 0 && name === 'c1') || (anim.indexOf('cb') >= 0 && name === 'c2');
        g.style.display = (k < dt.ecl && (!gone || animGone)) ? '' : 'none';
        if (anim.indexOf('e') >= 0) appear(g);
        if (animGone) fly(g, poolXY(2));
      });
      emBox.removeAttribute('transform');
      emBox.style.display = dt.eFree.indexOf('em') >= 0 && anim.indexOf('ef') < 0 ? 'none' : '';
      emBox.style.opacity = '1';
      if (anim.indexOf('ef') >= 0) fly(emBox, poolXY(2));
      extBox.setAttribute('class', 'svg-box ' + (dt.cb ? 'c7 dashed' : 'c6'));
      setText(cbT, dt.cb ? '>>> ext_free_cb(addr, "my 1 KiB buffer") → rte_free(addr)' : '');
      if (anim.indexOf('cb') >= 0) bump(cbT);
    }
  }
}

/* =====================================================================
 * Widget D: ol_flags bit-board
 * ===================================================================== */
var BITS = (function () {
  var b = [];
  function set(i, name, cat, desc) { b[i] = { name: name, cat: cat, desc: desc }; }
  for (var i = 0; i < 64; i++) set(i, '(unused)', 'res', 'Not assigned in 26.11 and not handed out as a dynamic flag.');
  set(0, 'RX_VLAN', 'rx', 'The packet had a VLAN tag; vlan_tci is valid.');
  set(1, 'RX_RSS_HASH', 'rx', 'hash.rss holds the NIC\'s RSS hash (ch15).');
  set(2, 'RX_FDIR', 'rx', 'Flow director matched; hash.fdir is valid.');
  set(3, 'RX_L4_CKSUM (bit A)', 'rx', '2-bit field with bit 8: UNKNOWN=0, BAD=bit 3, GOOD=bit 8, NONE=both. Test with RTE_MBUF_F_RX_L4_CKSUM_MASK.');
  set(4, 'RX_IP_CKSUM (bit A)', 'rx', '2-bit field with bit 7: UNKNOWN=0, BAD=bit 4, GOOD=bit 7, NONE=both. Test with RTE_MBUF_F_RX_IP_CKSUM_MASK.');
  set(5, 'RX_OUTER_IP_CKSUM_BAD', 'rx', 'Outer IP checksum of a tunnel packet is bad.');
  set(6, 'RX_VLAN_STRIPPED', 'rx', 'The NIC removed the VLAN tag from the data.');
  set(7, 'RX_IP_CKSUM (bit B)', 'rx', 'Second bit of the IP checksum status. GOOD = bit 7 alone.');
  set(8, 'RX_L4_CKSUM (bit B)', 'rx', 'Second bit of the L4 checksum status. GOOD = bit 8 alone.');
  set(9, 'RX_IEEE1588_PTP', 'rx', 'A PTP frame (ch19).');
  set(10, 'RX_IEEE1588_TMST', 'rx', 'The NIC timestamped this PTP frame.');
  set(13, 'RX_FDIR_ID', 'rx', 'hash.fdir.hi holds a flow director id.');
  set(14, 'RX_FDIR_FLX', 'rx', 'Flexible bytes reported in hash.fdir.');
  set(15, 'RX_QINQ_STRIPPED', 'rx', 'Both VLAN tags stripped.');
  set(16, 'RX_LRO', 'rx', 'Packet built by large receive offload.');
  set(18, 'RX_SEC_OFFLOAD', 'rx', 'Inline security processing was done (ch26).');
  set(19, 'RX_SEC_OFFLOAD_FAILED', 'rx', 'Inline security processing failed.');
  set(20, 'RX_QINQ', 'rx', 'Two VLAN tags; vlan_tci_outer is valid.');
  set(21, 'RX_OUTER_L4_CKSUM (bit A)', 'rx', '2-bit outer L4 checksum status with bit 22.');
  set(22, 'RX_OUTER_L4_CKSUM (bit B)', 'rx', '2-bit outer L4 checksum status with bit 21.');
  for (i = 23; i <= 40; i++) set(i, 'free for dynamic flags', 'dyn', 'RTE_MBUF_F_FIRST_FREE (23) .. RTE_MBUF_F_LAST_FREE (40). rte_mbuf_dynflag_register() hands these out at run time (section 11).');
  set(23, 'dynflag: ch07_sampled', 'dyn', 'dynfield_demo got bit 23 for "ch07_sampled" (first free bit). Another program may get another bit.');
  set(24, 'dynflag: rx_timestamp', 'dyn', 'rte_mbuf_dyn_rx_timestamp_register() got bit 24 in dynfield_demo.');
  set(25, 'dynflag: tx_timestamp', 'dyn', 'rte_mbuf_dyn_tx_timestamp_register() got bit 25 in dynfield_demo.');
  set(41, 'TX_OUTER_UDP_CKSUM', 'tx', 'Offload the outer UDP checksum of a tunnel packet.');
  set(42, 'TX_UDP_SEG', 'tx', 'UDP segmentation offload (USO).');
  set(43, 'TX_SEC_OFFLOAD', 'tx', 'Inline security offload for this packet.');
  set(44, 'TX_MACSEC', 'tx', 'Insert MACsec.');
  set(45, 'TX_TUNNEL (bit 0)', 'tx', 'Bits 45-48 = tunnel type: VXLAN=1, GRE=2, IPIP=3, GENEVE=4, ... Needed for inner checksums/TSO on tunnels.');
  set(46, 'TX_TUNNEL (bit 1)', 'tx', 'Tunnel type field, bit 1.');
  set(47, 'TX_TUNNEL (bit 2)', 'tx', 'Tunnel type field, bit 2.');
  set(48, 'TX_TUNNEL (bit 3)', 'tx', 'Tunnel type field, bit 3.');
  set(49, 'TX_QINQ', 'tx', 'Insert two VLAN tags (vlan_tci and vlan_tci_outer).');
  set(50, 'TX_TCP_SEG', 'tx', 'TCP segmentation offload (TSO). Implies TX_TCP_CKSUM; needs l2/l3/l4_len and tso_segsz.');
  set(51, 'TX_IEEE1588_TMST', 'tx', 'Ask the NIC to timestamp this PTP frame on transmit.');
  set(52, 'TX_L4 (bit 0)', 'tx', '2-bit L4 checksum request (bits 52-53): TCP=1, SCTP=2, UDP=3.');
  set(53, 'TX_L4 (bit 1)', 'tx', '2-bit L4 checksum request, bit 1.');
  set(54, 'TX_IP_CKSUM', 'tx', 'Compute the IPv4 header checksum. Set the checksum field to 0 first; set TX_IPV4 too.');
  set(55, 'TX_IPV4', 'tx', 'The (inner) packet is IPv4. Required with any TX offload.');
  set(56, 'TX_IPV6', 'tx', 'The (inner) packet is IPv6.');
  set(57, 'TX_VLAN', 'tx', 'Insert vlan_tci as a VLAN tag.');
  set(58, 'TX_OUTER_IP_CKSUM', 'tx', 'Compute the outer IPv4 checksum (needs outer_l2_len, outer_l3_len).');
  set(59, 'TX_OUTER_IPV4', 'tx', 'Outer header is IPv4.');
  set(60, 'TX_OUTER_IPV6', 'tx', 'Outer header is IPv6.');
  set(61, 'EXTERNAL', 'int', 'Internal: the mbuf uses an external buffer (attach_extbuf or a pinned extbuf pool).');
  set(62, 'INDIRECT', 'int', 'Internal: the mbuf is a clone attached to another mbuf\'s buffer.');
  return b;
})();
var BITCLS = { rx: 'svg-box c1', tx: 'svg-box c5', int: 'svg-box c4', dyn: 'svg-box ghost', res: 'svg-slot' };
var RECIPES = {
  rxgood: { title: 'RX: checksums verified by the NIC', bits: [1, 7, 8], code: '/* written by the PMD on RX; you only test them */\nif ((m->ol_flags &amp; RTE_MBUF_F_RX_IP_CKSUM_MASK) == RTE_MBUF_F_RX_IP_CKSUM_GOOD &amp;&amp;\n    (m->ol_flags &amp; RTE_MBUF_F_RX_L4_CKSUM_MASK) == RTE_MBUF_F_RX_L4_CKSUM_GOOD)\n        skip_software_checksum();\nuint32_t h = m->hash.rss;   /* valid: RTE_MBUF_F_RX_RSS_HASH */', lens: 'packet_type = 0x00000211 (L2_ETHER L3_IPV4 L4_UDP), set by NICs that classify', ptype: 0x211 },
  ipck: { title: 'TX: IPv4 header checksum', bits: [54, 55], code: 'm->l2_len = 14;                 /* Ethernet */\nm->l3_len = 20;                 /* IPv4, no options */\nm->ol_flags |= RTE_MBUF_F_TX_IPV4 | RTE_MBUF_F_TX_IP_CKSUM;\nip->hdr_checksum = 0;           /* the NIC fills it */\n/* port needs RTE_ETH_TX_OFFLOAD_IPV4_CKSUM */', lens: 'l2_len 14, l3_len 20' },
  udpck: { title: 'TX: IPv4 + UDP checksums', bits: [52, 53, 54, 55], code: 'm->l2_len = 14; m->l3_len = 20;\nm->ol_flags |= RTE_MBUF_F_TX_IPV4 | RTE_MBUF_F_TX_IP_CKSUM |\n               RTE_MBUF_F_TX_UDP_CKSUM;     /* 3 &lt;&lt; 52 */\nip->hdr_checksum = 0;\nudp->dgram_cksum = rte_ipv4_phdr_cksum(ip, m->ol_flags); /* pseudo-header seed (ch10/ch19) */', lens: 'l2_len 14, l3_len 20 (l4_len not needed for checksum only)' },
  tso: { title: 'TX: TCP segmentation (TSO)', bits: [50, 52, 54, 55], code: 'm->l2_len = 14; m->l3_len = 20; m->l4_len = 20;\nm->tso_segsz = 1448;            /* payload bytes per segment */\nm->ol_flags |= RTE_MBUF_F_TX_IPV4 | RTE_MBUF_F_TX_IP_CKSUM |\n               RTE_MBUF_F_TX_TCP_CKSUM | RTE_MBUF_F_TX_TCP_SEG;\n/* port needs RTE_ETH_TX_OFFLOAD_TCP_TSO */', lens: 'l2_len 14, l3_len 20, l4_len 20, tso_segsz 1448' },
  vxlan: { title: 'TX: VXLAN, outer IPv4 + inner IPv4/TCP checksums', bits: [45, 52, 54, 55, 58, 59], code: 'm->outer_l2_len = 14;           /* out_eth */\nm->outer_l3_len = 20;           /* out_ip */\nm->l2_len = 8 + 8 + 14;         /* out_udp + vxlan + in_eth */\nm->l3_len = 20;                 /* in_ip */\nm->ol_flags |= RTE_MBUF_F_TX_TUNNEL_VXLAN |\n               RTE_MBUF_F_TX_OUTER_IPV4 | RTE_MBUF_F_TX_OUTER_IP_CKSUM |\n               RTE_MBUF_F_TX_IPV4 | RTE_MBUF_F_TX_IP_CKSUM |\n               RTE_MBUF_F_TX_TCP_CKSUM;', lens: 'outer_l2_len 14, outer_l3_len 20, l2_len 30, l3_len 20' },
  vlan: { title: 'TX: insert a VLAN tag', bits: [57], code: 'm->vlan_tci = 100;              /* VID 100, PCP 0 */\nm->ol_flags |= RTE_MBUF_F_TX_VLAN;\n/* port needs RTE_ETH_TX_OFFLOAD_VLAN_INSERT; in software: rte_vlan_insert() (ch10) */', lens: 'vlan_tci 100' },
  clone: { title: 'Internal: a clone of an external-buffer mbuf', bits: [61, 62], code: '/* set by the library, never by you */\nstruct rte_mbuf *c = rte_pktmbuf_clone(em, clone_pool);\n/* RTE_MBUF_CLONED(c) and RTE_MBUF_HAS_EXTBUF(c) are both true */', lens: 'no lengths' },
  dyn: { title: 'Dynamic flags registered by dynfield_demo', bits: [23, 24, 25], code: 'int bit = rte_mbuf_dynflag_register(&amp;sampled_desc); /* 23 here */\nuint64_t sampled = RTE_BIT64(bit);\nm->ol_flags |= sampled;', lens: 'bit numbers are runtime values: look them up, never hard-code them' }
};

function olBoard() {
  var root = document.getElementById('w-ol');
  if (!root) return;
  var svg = root.querySelector('svg');
  var X0 = 62, SQ = 34, GAP = 4, Y0 = 18, RG = 44;
  var on = {};
  var cellG = [];
  var info = root.querySelector('.ch7-olinfo'), hex = root.querySelector('.ch7-hex'), code = root.querySelector('.ch7-olcode');
  for (var r = 0; r < 4; r++) {
    var hi = 63 - r * 16;
    txt(svg, 6, Y0 + r * RG + SQ / 2, hi + '..' + (hi - 15), 'svg-label small muted', { 'dominant-baseline': 'middle' }).setAttribute('dominant-baseline', 'middle');
    for (var c = 0; c < 16; c++) {
      (function (bit, x, y) {
        var g = el('g', { 'class': 'ch7-bit', tabindex: '0', role: 'button', 'aria-label': 'bit ' + bit + ' ' + BITS[bit].name }, svg);
        el('rect', { x: x, y: y, width: SQ, height: SQ, rx: 4, 'class': BITCLS[BITS[bit].cat] }, g);
        txt(g, x + SQ / 2, y + SQ / 2, String(bit), 'svg-label small center');
        g.addEventListener('click', function () { on[bit] = !on[bit]; describe(bit); paint(); });
        g.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); on[bit] = !on[bit]; describe(bit); paint(); } });
        g.addEventListener('mouseenter', function () { describe(bit); });
        cellG[bit] = g;
      })(hi - c, X0 + c * (SQ + GAP), Y0 + r * RG);
    }
  }
  function value() {
    var hiW = 0, loW = 0;
    for (var b = 0; b < 64; b++) if (on[b]) { if (b >= 32) hiW = (hiW | (1 << (b - 32))) >>> 0; else loW = (loW | (1 << b)) >>> 0; }
    function h8(v) { var s = v.toString(16); while (s.length < 8) s = '0' + s; return s; }
    return '0x' + h8(hiW) + h8(loW);
  }
  function paint() {
    var list = [];
    for (var b = 63; b >= 0; b--) {
      cellG[b].classList.toggle('lit', !!on[b]);
      if (on[b]) list.push(b);
    }
    hex.innerHTML = 'ol_flags = <strong>' + value() + '</strong> &middot; bits set: ' + (list.length ? list.join(', ') : 'none');
  }
  function describe(bit) {
    var B = BITS[bit];
    info.innerHTML = '<strong>bit ' + bit + '</strong> <code>' + (B.cat === 'rx' || B.cat === 'tx' || B.cat === 'int' ? 'RTE_MBUF_F_' : '') + B.name + '</code> &middot; ' + B.desc;
  }
  CourseJS.$$('[data-recipe]', root).forEach(function (btn) {
    btn.addEventListener('click', function () {
      var R = RECIPES[btn.getAttribute('data-recipe')];
      on = {};
      R.bits.forEach(function (b) { on[b] = true; });
      CourseJS.$$('[data-recipe]', root).forEach(function (x) { x.classList.toggle('primary', x === btn); });
      code.innerHTML = '<strong>' + R.title + '</strong> &middot; ' + R.lens + '<pre><code class="language-c">' + R.code + '</code></pre>';
      CourseJS.highlightAll(code);
      info.innerHTML = 'Lit bits: ' + R.bits.map(function (b) { return b + ' ' + BITS[b].name; }).join('; ') + '.';
      paint();
    });
  });
  var clr = root.querySelector('[data-clear]');
  if (clr) clr.addEventListener('click', function () { on = {}; paint(); code.innerHTML = ''; info.innerHTML = 'Cleared. Click squares to toggle single bits.'; CourseJS.$$('[data-recipe]', root).forEach(function (x) { x.classList.remove('primary'); }); });
  paint();
  info.innerHTML = 'Hover or click a square to read the bit; click a recipe to light the bits it needs.';
}

CourseJS.ready(function () {
  anatomy();
  chainView();
  refcnt();
  olBoard();
});
})();

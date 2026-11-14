/* Timeline page for one TSP simulator trace. Plain JavaScript, no libraries.
   Everything is drawn from the two embedded JSON blocks (trace, chip).
   buildModel() mirrors tsp/viz/model.py (summarise): keep the two in sync.
   Note: this file must never contain two consecutive slashes (the page is
   checked for protocol-relative references), so only block comments are used. */
(function () {
  'use strict';

  const trace = JSON.parse(document.getElementById('trace').textContent);
  const chip = JSON.parse(document.getElementById('chip').textContent);
  const TAGGED = new Set(['drive', 'sample', 'mem_read', 'mem_write', 'iw_row', 'matvec_row']);
  const NPAL = 8;

  /* ------------------------------------------------------------------ model */
  function valueOf(tag) {
    if (tag === undefined || tag === null) return '';
    const i = tag.lastIndexOf('#');
    return i < 0 ? tag : tag.slice(0, i);
  }
  function diagonal(d, cycle, pos) { return d === 'E' ? cycle - pos : cycle + pos; }
  function allLanes() {
    const out = [];
    for (const d of ['E', 'W']) for (let s = 0; s < chip.streams_per_dir; s++) out.push(d + s);
    return out;
  }

  function buildModel() {
    const events = trace.events;
    const P = chip.n_positions;
    const unitOrder = [];
    for (const s of chip.slices) for (const u of s.units) unitOrder.push(u);
    const unitSet = new Set(unitOrder);

    const issueCounts = new Map();
    for (const e of events) if (e.kind === 'issue') issueCounts.set(e.unit, (issueCounts.get(e.unit) || 0) + 1);
    const known = unitOrder.filter(u => issueCounts.has(u));
    const unknown = [...issueCounts.keys()].filter(u => !unitSet.has(u)).sort();
    const issueBlocksPerUnit = {};
    let nIssue = 0;
    for (const u of known.concat(unknown)) { issueBlocksPerUnit[u] = issueCounts.get(u); nIssue += issueCounts.get(u); }

    /* one flight per drive, in event order */
    const flights = [];
    const groups = new Map();
    for (const e of events) {
      if (e.kind !== 'drive') continue;
      const f = {
        dir: e.dir, stream: e.stream, lane: e.dir + e.stream, tag: e.tag, value: valueOf(e.tag),
        unit: e.unit, opcode: e.opcode, start_cycle: e.cycle, start_pos: e.pos,
        last_sample_cycle: null, last_sample_unit: null, n_samples: 0,
        end_cycle: null, end_reason: null, end_pos: null, subrow: 0, _by: null
      };
      const key = e.dir + '|' + e.stream + '|' + diagonal(e.dir, e.cycle, e.pos);
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(flights.length);
      flights.push(f);
    }
    /* each diagonal in flow order; a flight ends where the next one starts, or at the chip edge */
    const ordered = new Map();
    for (const [key, idxs] of groups) {
      const sign = key[0] === 'E' ? 1 : -1;
      const order = idxs.slice().sort((a, b) =>
        (sign * flights[a].start_pos - sign * flights[b].start_pos) || (a - b));
      ordered.set(key, order);
      for (let k = 0; k < order.length; k++) {
        const fa = flights[order[k]];
        if (k + 1 < order.length) {
          const fb = flights[order[k + 1]];
          fa.end_cycle = fb.start_cycle; fa.end_reason = 'overwritten'; fa.end_pos = fb.start_pos; fa._by = order[k + 1];
        } else if (fa.dir === 'E') {
          fa.end_cycle = fa.start_cycle + (P - fa.start_pos); fa.end_reason = 'edge'; fa.end_pos = P;
        } else {
          fa.end_cycle = fa.start_cycle + fa.start_pos + 1; fa.end_reason = 'edge'; fa.end_pos = -1;
        }
      }
    }
    function findFlight(d, stream, cycle, pos) {
      const order = ordered.get(d + '|' + stream + '|' + diagonal(d, cycle, pos));
      if (!order) return null;
      let found = null;
      for (const i of order) {
        const p = flights[i].start_pos;
        if (d === 'E' ? p <= pos : p >= pos) found = i; else break;
      }
      return found;
    }
    for (const e of events) {
      if (e.kind !== 'sample') continue;
      const i = findFlight(e.dir, e.stream, e.cycle, e.pos);
      if (i === null) continue;
      const f = flights[i];
      f.n_samples += 1;
      if (f.last_sample_cycle === null || e.cycle >= f.last_sample_cycle) { f.last_sample_cycle = e.cycle; f.last_sample_unit = e.unit; }
    }
    /* sub-rows: greedy, by (start_cycle, drive order) */
    const byLane = new Map();
    flights.forEach((f, i) => { if (!byLane.has(f.lane)) byLane.set(f.lane, []); byLane.get(f.lane).push(i); });
    const subrowCount = new Map();
    for (const [lane, idxs] of byLane) {
      const ends = [];
      idxs.slice().sort((a, b) => (flights[a].start_cycle - flights[b].start_cycle) || (a - b)).forEach(i => {
        const f = flights[i];
        let r = ends.findIndex(end => end <= f.start_cycle);
        if (r < 0) { r = ends.length; ends.push(0); }
        ends[r] = f.end_cycle;
        f.subrow = r;
      });
      subrowCount.set(lane, ends.length);
    }
    const laneOrder = allLanes();
    const laneSet = new Set(laneOrder);
    const lanesUsed = laneOrder.filter(l => byLane.has(l))
      .concat([...byLane.keys()].filter(l => !laneSet.has(l)).sort());
    const flightsPerLane = {}, subrowsPerLane = {};
    for (const l of lanesUsed) { flightsPerLane[l] = byLane.get(l).length; subrowsPerLane[l] = subrowCount.get(l); }

    const values = [], seen = new Set();
    for (const e of events) {
      if (TAGGED.has(e.kind) && e.tag !== undefined && e.tag !== null) {
        const v = valueOf(e.tag);
        if (!seen.has(v)) { seen.add(v); values.push(v); }
      }
    }
    return {
      summary: {
        n_cycles: trace.n_cycles,
        issue_blocks_per_unit: issueBlocksPerUnit,
        n_issue_blocks: nIssue,
        units_active: known.concat(unknown),
        flights: flights,
        n_flights: flights.length,
        flights_per_lane: flightsPerLane,
        subrows_per_lane: subrowsPerLane,
        lanes_used: lanesUsed,
        values: values
      },
      findFlight: findFlight,
      byLane: byLane
    };
  }

  const M = buildModel();
  const S = M.summary;
  const flights = S.flights;
  const valueIndex = new Map(S.values.map((v, i) => [v, i]));
  window.tspSummary = S;

  /* value carried by each instruction: first drive, else first sample, with the same (unit, issue cycle, opcode) */
  const instrValue = new Map();
  for (const kind of ['drive', 'sample']) {
    for (const e of trace.events) {
      if (e.kind !== kind || e.issue_cycle === undefined) continue;
      const k = e.unit + '|' + e.issue_cycle + '|' + e.opcode;
      if (!instrValue.has(k)) instrValue.set(k, valueOf(e.tag));
    }
  }
  const issuesByUnit = new Map();
  const slicePos = new Map();
  const sliceOfUnit = new Map();
  for (const s of chip.slices) { slicePos.set(s.name, s.pos); for (const u of s.units) sliceOfUnit.set(u, s.name); }
  for (const e of trace.events) {
    if (e.kind !== 'issue') continue;
    const k = e.unit + '|' + e.cycle + '|' + e.opcode;
    const it = {
      unit: e.unit, cycle: e.cycle, opcode: e.opcode, text: e.text || e.opcode,
      sample: e.sample_cycle, visible: e.visible_cycle,
      value: instrValue.has(k) ? instrValue.get(k) : null
    };
    if (!issuesByUnit.has(e.unit)) issuesByUnit.set(e.unit, []);
    issuesByUnit.get(e.unit).push(it);
  }
  for (const list of issuesByUnit.values()) list.sort((a, b) => a.cycle - b.cycle);

  let maxCycle = trace.n_cycles;
  for (const e of trace.events) maxCycle = Math.max(maxCycle, e.cycle + 1);
  for (const f of flights) maxCycle = Math.max(maxCycle, f.end_cycle);
  const NC = Math.max(1, trace.n_cycles, trace.occupancy.length);
  const SPAN = Math.max(NC, maxCycle);

  const evByCycle = [];
  for (const e of trace.events) {
    if (e.kind !== 'issue' && e.kind !== 'sample' && e.kind !== 'drive') continue;
    (evByCycle[e.cycle] || (evByCycle[e.cycle] = [])).push(e);
  }

  /* ----------------------------------------------------------------- colours */
  let C = {};
  let PAL = [];
  function readColours() {
    const cs = getComputedStyle(document.documentElement);
    const g = n => cs.getPropertyValue(n).trim();
    C = {
      bg: g('--bg'), panel: g('--panel'), text: g('--text'), text2: g('--text2'), muted: g('--muted'),
      grid: g('--grid'), rule: g('--rule'), sep: g('--sep'), cursor: g('--cursor'), hover: g('--hover'),
      neutral: g('--neutral'), mono: g('--mono')
    };
    PAL = [];
    for (let i = 0; i < NPAL; i++) PAL.push(g('--v' + i));
    hatch = null;
  }
  function colourFor(v) {
    if (v === null || v === undefined || !valueIndex.has(v)) return C.neutral;
    return PAL[valueIndex.get(v) % NPAL];
  }
  function inkOn(hex) {
    const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
    if (!m) return '#000';
    const lin = c => { c = parseInt(c, 16) / 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
    const L = 0.2126 * lin(m[1]) + 0.7152 * lin(m[2]) + 0.0722 * lin(m[3]);
    return L > 0.22 ? '#0b0b0b' : '#ffffff';
  }

  /* ------------------------------------------------------------------ header */
  function fmtTime(sec) {
    if (sec < 1e-6) return (sec * 1e9).toFixed(1) + ' ns';
    if (sec < 1e-3) return (sec * 1e6).toFixed(2) + ' µs';
    return (sec * 1e3).toFixed(3) + ' ms';
  }
  function fmtHz(hz) { return hz >= 1e9 ? (hz / 1e9) + ' GHz' : (hz / 1e6) + ' MHz'; }
  (function header() {
    const el = document.getElementById('facts');
    const parts = [
      ['Chip preset', chip.name + ' (' + chip.n_positions + ' positions, ' + chip.lanes + ' lanes, ' +
        chip.streams_per_dir + ' streams each way)'],
      ['Total', trace.n_cycles.toLocaleString('en-US') + ' cycles'],
      ['Instructions', S.n_issue_blocks.toLocaleString('en-US')],
      ['Flights', S.n_flights.toLocaleString('en-US') + ' (' + S.values.length + ' values)']
    ];
    for (const [k, v] of parts) {
      const b = document.createElement('b'); b.textContent = k + ': ';
      el.appendChild(b); el.appendChild(document.createTextNode(v + '   '));
    }
    const conv = document.createElement('span');
    conv.textContent = 'Conversion: ' + trace.n_cycles.toLocaleString('en-US') + ' cycles at ' + fmtHz(chip.clock_hz) +
      ' ≈ ' + fmtTime(trace.n_cycles / chip.clock_hz) +
      ' (the clock is a nominal published figure; the cycle latencies in this simulator are assumptions).';
    el.appendChild(document.createElement('br'));
    el.appendChild(conv);
  })();

  /* ------------------------------------------------------------------- state */
  const state = { cycle: 0, hl: null, showIdle: false, pxc: 4, playing: null };

  /* ------------------------------------------------------------- Gantt rows */
  const RULER_H = 22, UNIT_H = 18, SUB_H = 12, LANE_PAD = 4, GROUP_H = 18, PAD_L = 6;
  let rows = [];
  let totalH = 0;
  function buildRows() {
    rows = [];
    let y = RULER_H;
    rows.push({ type: 'group', label: 'Queues', y: y, h: GROUP_H }); y += GROUP_H;
    let band = 0;
    for (const s of chip.slices) {
      let any = false;
      for (const u of s.units) {
        if (!state.showIdle && !issuesByUnit.has(u)) continue;
        rows.push({ type: 'unit', unit: u, slice: s.name, label: u, y: y, h: UNIT_H, band: band % 2,
          items: issuesByUnit.get(u) || [], first: !any });
        y += UNIT_H; any = true;
      }
      if (any) band++;
    }
    for (const u of issuesByUnit.keys()) {
      if (!sliceOfUnit.has(u)) {
        rows.push({ type: 'unit', unit: u, slice: '?', label: u, y: y, h: UNIT_H, band: 0, items: issuesByUnit.get(u), first: true });
        y += UNIT_H;
      }
    }
    rows.push({ type: 'group', label: 'Stream lanes', y: y, h: GROUP_H }); y += GROUP_H;
    const lanes = state.showIdle ? allLanes().concat(S.lanes_used.filter(l => !allLanes().includes(l))) : S.lanes_used;
    for (const l of lanes) {
      const idxs = M.byLane.get(l) || [];
      const n = Math.max(1, S.subrows_per_lane[l] || 0);
      const h = n * SUB_H + LANE_PAD;
      rows.push({ type: 'lane', lane: l, label: l, y: y, h: h, nsub: n, items: idxs.map(i => flights[i]),
        first: l === 'W0' || l === lanes[0] });
      y += h;
    }
    totalH = y + RULER_H;
  }

  const gScroll = document.getElementById('gScroll');
  const gInner = document.getElementById('gInner');
  const canvas = document.getElementById('gCanvas');
  const gLabels = document.getElementById('gLabels');
  const ctx = canvas.getContext('2d');
  let viewW = 600, dpr = 1;
  let hatch = null;

  function layoutGantt() {
    buildRows();
    gLabels.textContent = '';
    gLabels.style.height = totalH + 'px';
    const head = document.createElement('div');
    head.className = 'lab group'; head.style.top = '0px'; head.style.height = RULER_H + 'px'; head.textContent = 'cycle';
    gLabels.appendChild(head);
    let nUnitBlocks = 0, nBars = 0;
    for (const r of rows) {
      const d = document.createElement('div');
      d.className = 'lab' + (r.type === 'group' ? ' group' : '');
      d.style.top = r.y + 'px'; d.style.height = r.h + 'px';
      d.textContent = r.label;
      if (r.type === 'unit') { d.title = r.unit + ' (' + r.items.length + ' instructions)'; nUnitBlocks += r.items.length; }
      if (r.type === 'lane') {
        d.title = (r.lane[0] === 'E' ? 'eastward' : 'westward') + ' stream ' + r.lane.slice(1) + ' (' + r.items.length + ' flights)';
        nBars += r.items.length;
      }
      gLabels.appendChild(d);
    }
    canvas.dataset.issueBlocks = String(nUnitBlocks);
    canvas.dataset.flightBars = String(nBars);
    sizeCanvas();
  }
  function sizeCanvas() {
    viewW = Math.max(100, gScroll.clientWidth);
    gInner.style.width = Math.ceil(SPAN * state.pxc + 2 * PAD_L) + 'px';
    gInner.style.height = totalH + 'px';
    dpr = Math.min(window.devicePixelRatio || 1, 32000 / Math.max(1, totalH), 32000 / viewW);
    canvas.width = Math.floor(viewW * dpr);
    canvas.height = Math.floor(totalH * dpr);
    canvas.style.width = viewW + 'px';
    canvas.style.height = totalH + 'px';
    document.getElementById('zoomLabel').textContent = fmtZoom(state.pxc);
    requestDraw();
  }
  function fmtZoom(p) { return (p >= 1 ? p.toFixed(p % 1 ? 1 : 0) : p.toFixed(2)) + ' px/cycle'; }

  let drawPending = false;
  function requestDraw() {
    if (drawPending) return;
    drawPending = true;
    requestAnimationFrame(() => { drawPending = false; drawGantt(); });
  }
  function xOf(c) { return PAD_L + c * state.pxc - gScroll.scrollLeft; }
  function tickStep() {
    const steps = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000];
    for (const s of steps) if (s * state.pxc >= 64) return s;
    return 100000;
  }
  function textW(s) { return ctx.measureText(s).width; }
  function getHatch() {
    if (hatch) return hatch;
    const p = document.createElement('canvas');
    p.width = 6; p.height = 6;
    const g = p.getContext('2d');
    g.strokeStyle = C.bg; g.lineWidth = 1.6; g.globalAlpha = 0.85;
    g.beginPath(); g.moveTo(0, 6); g.lineTo(6, 0); g.moveTo(-1, 1); g.lineTo(1, -1); g.moveTo(5, 7); g.lineTo(7, 5); g.stroke();
    hatch = ctx.createPattern(p, 'repeat');
    return hatch;
  }

  function drawGantt() {
    const W = viewW, pxc = state.pxc, sl = gScroll.scrollLeft;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = C.bg; ctx.fillRect(0, 0, W, totalH);
    const c0 = Math.max(0, Math.floor((sl - PAD_L) / pxc) - 1);
    const c1 = Math.min(SPAN, Math.ceil((sl + W) / pxc) + 1);
    const step = tickStep();
    const hl = state.hl;

    /* row backgrounds and separators */
    for (const r of rows) {
      if (r.type === 'unit' && r.band) { ctx.fillStyle = C.hover; ctx.fillRect(0, r.y, W, r.h); }
      if (r.type === 'group') { ctx.fillStyle = C.panel; ctx.fillRect(0, r.y, W, r.h); }
      if (r.first && r.type !== 'group') { ctx.fillStyle = C.rule; ctx.fillRect(0, r.y, W, 1); }
      if (r.type === 'lane') { ctx.fillStyle = C.grid; ctx.fillRect(0, r.y + r.h - 1, W, 1); }
    }
    /* vertical grid */
    ctx.fillStyle = C.grid;
    for (let c = Math.ceil(c0 / step) * step; c <= c1; c += step) ctx.fillRect(Math.round(xOf(c)), RULER_H, 1, totalH - 2 * RULER_H);
    /* rulers (top and bottom) */
    ctx.font = '10px ' + C.mono;
    ctx.textBaseline = 'middle';
    for (const top of [0, totalH - RULER_H]) {
      ctx.fillStyle = C.panel; ctx.fillRect(0, top, W, RULER_H);
      ctx.fillStyle = C.rule; ctx.fillRect(0, top === 0 ? RULER_H - 1 : top, W, 1);
      ctx.fillStyle = C.text2;
      for (let c = Math.ceil(c0 / step) * step; c <= c1; c += step) {
        const x = Math.round(xOf(c));
        ctx.fillRect(x, top === 0 ? RULER_H - 6 : top, 1, 6);
        ctx.fillText(String(c), x + 3, top + RULER_H / 2);
      }
    }
    /* group labels inside the canvas */
    ctx.font = '600 11px ' + C.mono;
    for (const r of rows) if (r.type === 'group') {
      ctx.fillStyle = C.text2;
      ctx.fillText(r.label === 'Queues' ? 'instruction queues, West → East' : 'stream lanes: E = eastward, W = westward',
        8, r.y + r.h / 2);
    }

    ctx.font = '10px ' + C.mono;
    let drawnBlocks = 0;
    for (const r of rows) {
      if (r.type === 'unit') {
        const items = r.items;
        for (let k = 0; k < items.length; k++) {
          const it = items[k];
          const vis = it.visible !== undefined ? it.visible : it.cycle;
          if (vis + 1 < c0 || it.cycle > c1) continue;
          drawnBlocks++;
          const dim = hl !== null && it.value !== hl;
          ctx.globalAlpha = dim ? 0.15 : 1;
          const x = xOf(it.cycle);
          const col = colourFor(it.value);
          const mid = r.y + r.h / 2;
          /* whisker issue -> visible, tick at the sample cycle */
          if (vis > it.cycle) {
            ctx.fillStyle = C.sep;
            ctx.fillRect(x + pxc, mid, (vis - it.cycle) * pxc, 1);
            ctx.fillRect(xOf(vis + 1) - 1, mid - 3, 1, 7);
            if (it.sample !== undefined && it.sample > it.cycle) ctx.fillRect(xOf(it.sample) + pxc / 2, mid - 2, 1, 5);
          }
          ctx.fillStyle = col;
          ctx.fillRect(x, r.y + 3, Math.max(1.5, pxc - (pxc > 3 ? 1 : 0)), r.h - 6);
          /* opcode label right of the block when there is room before the next block */
          const next = k + 1 < items.length ? xOf(items[k + 1].cycle) : Infinity;
          const tx = x + Math.max(pxc, 2) + 2;
          const tw = textW(it.opcode);
          if (tx + tw + 2 < next) {
            ctx.fillStyle = C.text;
            ctx.fillText(it.opcode, tx, r.y + 5.5);
          }
        }
      } else if (r.type === 'lane') {
        for (const f of r.items) {
          if (f.end_cycle < c0 || f.start_cycle > c1) continue;
          const dim = hl !== null && f.value !== hl;
          ctx.globalAlpha = dim ? 0.12 : 1;
          const col = colourFor(f.value);
          const y = r.y + LANE_PAD / 2 + f.subrow * SUB_H + 1, h = SUB_H - 2;
          const liveEnd = f.last_sample_cycle === null ? f.start_cycle : f.last_sample_cycle + 1;
          const xs = xOf(f.start_cycle), xl = xOf(liveEnd), xe = xOf(f.end_cycle);
          if (xe > xl) {
            ctx.globalAlpha = dim ? 0.06 : 0.42;
            ctx.fillStyle = col; ctx.fillRect(xl, y, xe - xl, h);
            ctx.fillStyle = getHatch(); ctx.fillRect(xl, y, xe - xl, h);
            ctx.globalAlpha = dim ? 0.12 : 1;
          }
          if (xl > xs) {
            ctx.fillStyle = col; ctx.fillRect(xs, y, Math.max(1, xl - xs - (pxc > 3 ? 0.5 : 0)), h);
            const tw = textW(f.value);
            if (tw + 6 < xl - xs) { ctx.fillStyle = inkOn(col); ctx.fillText(f.value, xs + 3, y + h / 2 + 0.5); }
          } else {
            /* never read: a thin solid start mark so the drive cycle is visible */
            ctx.fillStyle = col; ctx.fillRect(xs, y, Math.max(1, Math.min(2, pxc)), h);
          }
        }
      }
    }
    ctx.globalAlpha = 1;
    canvas.dataset.drawnBlocks = String(drawnBlocks);

    /* end of run (n_cycles): dead tails may continue past it until they leave the chip */
    if (SPAN > trace.n_cycles) {
      const xe = Math.round(xOf(trace.n_cycles));
      ctx.fillStyle = C.text2;
      for (let y = RULER_H; y < totalH - RULER_H; y += 6) ctx.fillRect(xe, y, 1, 3);
      ctx.font = '10px ' + C.mono;
      ctx.fillText('end of run', xe + 4, totalH - RULER_H - 8);
    }

    /* cursor */
    const cx = xOf(state.cycle);
    if (pxc >= 3) { ctx.fillStyle = C.cursor; ctx.globalAlpha = 0.12; ctx.fillRect(cx, RULER_H, pxc, totalH - 2 * RULER_H); ctx.globalAlpha = 1; }
    ctx.fillStyle = C.cursor;
    ctx.fillRect(Math.round(cx + pxc / 2) - 1, 0, 2, totalH);
    ctx.font = '600 10px ' + C.mono;
    const lab = String(state.cycle);
    const lw = textW(lab) + 8;
    const lx = Math.min(Math.max(0, cx + pxc / 2 - lw / 2), W - lw);
    ctx.fillRect(lx, 2, lw, RULER_H - 6);
    ctx.fillStyle = inkOn(C.cursor) === '#ffffff' ? '#ffffff' : '#0b0b0b';
    ctx.fillText(lab, lx + 4, RULER_H / 2 - 1);
  }

  /* hit testing on the canvas */
  function hitAt(mx, my) {
    const r = rows.find(r => my >= r.y && my < r.y + r.h);
    const cyc = Math.floor((mx + gScroll.scrollLeft - PAD_L) / state.pxc);
    if (!r) return { cycle: cyc };
    const slack = Math.max(0, (4 - state.pxc) / 2) / state.pxc;
    if (r.type === 'unit') {
      let best = null, bd = Infinity;
      for (const it of r.items) {
        const d = cyc < it.cycle ? it.cycle - cyc : (cyc > it.cycle ? cyc - it.cycle : 0);
        if (d <= slack + 0.0001 && d < bd) { best = it; bd = d; }
      }
      return { cycle: cyc, row: r, issue: best };
    }
    if (r.type === 'lane') {
      const sub = Math.floor((my - r.y - LANE_PAD / 2) / SUB_H);
      const fc = (mx + gScroll.scrollLeft - PAD_L) / state.pxc;
      const f = r.items.find(f => f.subrow === sub && fc >= f.start_cycle - slack && fc < f.end_cycle + slack);
      return { cycle: cyc, row: r, flight: f || null };
    }
    return { cycle: cyc, row: r };
  }
  function sliceAtPos(p) { return p >= 0 && p < chip.slices.length ? chip.slices[p].name : '(off chip)'; }
  function issueTip(it) {
    return it.unit + '  ' + it.opcode + '\n' + it.text + '\nissue ' + it.cycle +
      (it.sample !== undefined ? ' · sample ' + it.sample : '') +
      (it.visible !== undefined ? ' · visible ' + it.visible : '') +
      (it.value ? '\nvalue: ' + it.value : '');
  }
  function flightTip(f) {
    const lines = [f.tag + '   (lane ' + f.lane + ', ' + (f.dir === 'E' ? 'eastward' : 'westward') + ')'];
    lines.push('driven by ' + f.unit + ' ' + f.opcode + ' at pos ' + f.start_pos + ' (' + sliceAtPos(f.start_pos) + '), visible cycle ' + f.start_cycle);
    if (f.last_sample_cycle === null) lines.push('never read (all dead tail)');
    else lines.push('last read cycle ' + f.last_sample_cycle + ' by ' + f.last_sample_unit + ' (' + f.n_samples + ' read' + (f.n_samples === 1 ? '' : 's') + ')');
    if (f.end_reason === 'overwritten') {
      const by = flights[f._by];
      lines.push('overwritten at pos ' + f.end_pos + ' (' + sliceAtPos(f.end_pos) + ') in cycle ' + f.end_cycle + ' by ' + by.tag);
    } else {
      lines.push('leaves the chip at the ' + (f.dir === 'E' ? 'East' : 'West') + ' edge; gone from cycle ' + f.end_cycle);
    }
    return lines.join('\n');
  }

  const tip = document.getElementById('tip');
  function showTip(text, ev) {
    tip.textContent = text;
    tip.hidden = false;
    const pad = 12;
    const w = tip.offsetWidth, h = tip.offsetHeight;
    let x = ev.clientX + pad, y = ev.clientY + pad;
    if (x + w > window.innerWidth - 4) x = Math.max(4, ev.clientX - w - pad);
    if (y + h > window.innerHeight - 4) y = Math.max(4, ev.clientY - h - pad);
    tip.style.left = x + 'px'; tip.style.top = y + 'px';
  }
  function hideTip() { tip.hidden = true; }

  canvas.addEventListener('mousemove', ev => {
    const rect = canvas.getBoundingClientRect();
    const h = hitAt(ev.clientX - rect.left, ev.clientY - rect.top);
    if (h.issue) { showTip(issueTip(h.issue), ev); setHL(h.issue.value || null); }
    else if (h.flight) { showTip(flightTip(h.flight), ev); setHL(h.flight.value); }
    else { hideTip(); setHL(null); }
  });
  canvas.addEventListener('mouseleave', () => { hideTip(); setHL(null); });
  canvas.addEventListener('click', ev => {
    const rect = canvas.getBoundingClientRect();
    const h = hitAt(ev.clientX - rect.left, ev.clientY - rect.top);
    setCycle(h.cycle, false);
  });
  gScroll.addEventListener('scroll', requestDraw, { passive: true });

  /* zoom keeps the cycle at the centre of the view fixed */
  const ZOOMS = [0.05, 0.1, 0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32];
  function fitZoom() { return Math.min(32, Math.max(0.05, (gScroll.clientWidth - 2 * PAD_L) / SPAN)); }
  function setZoom(p) {
    const centre = (gScroll.scrollLeft + gScroll.clientWidth / 2 - PAD_L) / state.pxc;
    state.pxc = p;
    sizeCanvas();
    gScroll.scrollLeft = Math.max(0, centre * p + PAD_L - gScroll.clientWidth / 2);
    requestDraw();
  }
  document.getElementById('zoomIn').addEventListener('click', () => {
    const n = ZOOMS.find(z => z > state.pxc + 1e-9); if (n) setZoom(n);
  });
  document.getElementById('zoomOut').addEventListener('click', () => {
    const n = ZOOMS.slice().reverse().find(z => z < state.pxc - 1e-9); if (n) setZoom(n);
  });
  document.getElementById('zoomFit').addEventListener('click', () => setZoom(fitZoom()));

  /* --------------------------------------------------------------- chip view */
  const slicesEl = document.getElementById('slices');
  const cellsEl = document.getElementById('cells');
  const wrap = document.querySelector('.chipgrid-wrap');
  wrap.style.setProperty('--npos', String(chip.n_positions));
  let cellIndex = new Map();
  let touched = [];
  const sliceEls = [];

  (function buildSlices() {
    slicesEl.appendChild(document.createElement('div'));
    for (const s of chip.slices) {
      const d = document.createElement('div');
      d.className = 'slice kind-' + s.name.slice(0, 3);
      const n = document.createElement('span'); n.textContent = s.name;
      const op = document.createElement('span'); op.className = 'op';
      d.appendChild(n); d.appendChild(op);
      d.dataset.pos = String(s.pos);
      slicesEl.appendChild(d);
      sliceEls.push({ el: d, op: op, slice: s });
    }
  })();

  function buildCells() {
    cellsEl.textContent = '';
    cellIndex = new Map();
    touched = [];
    const lanes = state.showIdle ? allLanes() : S.lanes_used;
    let prevDir = null;
    for (const l of lanes) {
      const sep = prevDir !== null && l[0] !== prevDir;
      prevDir = l[0];
      const lab = document.createElement('div');
      lab.className = 'ln' + (sep ? ' lanesep' : '');
      lab.textContent = l;
      cellsEl.appendChild(lab);
      const arr = [];
      for (let p = 0; p < chip.n_positions; p++) {
        const c = document.createElement('div');
        c.className = 'c' + (sep ? ' lanesep' : '');
        c.dataset.lane = l; c.dataset.pos = String(p);
        cellsEl.appendChild(c);
        arr.push({ el: c, sep: sep, value: null, tag: null, flight: null });
      }
      cellIndex.set(l, arr);
    }
    if (!lanes.length) {
      const d = document.createElement('div');
      d.className = 'ln'; d.style.gridColumn = '1 / -1'; d.textContent = 'no stream activity';
      cellsEl.appendChild(d);
    }
  }

  function updateChip() {
    const t = state.cycle;
    for (const c of touched) { c.el.className = 'c' + (c.sep ? ' lanesep' : ''); c.el.style.background = ''; c.value = null; c.tag = null; c.flight = null; }
    touched = [];
    const occ = trace.occupancy[t] || [];
    for (const [d, s, p, tag] of occ) {
      const arr = cellIndex.get(d + s);
      if (!arr || !arr[p]) continue;
      const c = arr[p];
      const v = valueOf(tag);
      const fi = M.findFlight(d, s, t, p);
      const f = fi === null ? null : flights[fi];
      c.value = v; c.tag = tag; c.flight = f;
      c.el.style.background = colourFor(v);
      if (f && (f.last_sample_cycle === null || t > f.last_sample_cycle)) c.el.classList.add('dead');
      touched.push(c);
    }
    const evs = evByCycle[t] || [];
    const ops = new Map();
    for (const e of evs) {
      if (e.kind === 'drive' || e.kind === 'sample') {
        const arr = cellIndex.get(e.dir + e.stream);
        if (arr && arr[e.pos]) {
          arr[e.pos].el.classList.add(e.kind === 'drive' ? 'drv' : 'smp');
          if (!touched.includes(arr[e.pos])) touched.push(arr[e.pos]);
        }
      }
      const p = slicePos.has(sliceOfUnit.get(e.unit)) ? slicePos.get(sliceOfUnit.get(e.unit)) : e.pos;
      if (!ops.has(p)) ops.set(p, []);
      const tagged = e.kind === 'issue' ? e.opcode : e.opcode.toLowerCase();
      if (!ops.get(p).includes(tagged)) ops.get(p).push(tagged);
    }
    for (const s of sliceEls) {
      const o = ops.get(s.slice.pos);
      s.el.classList.toggle('active', !!o);
      s.op.textContent = o ? o.join(' ') : '';
    }
    applyHLCells();
    renderActivity(evs, t);
  }

  const activityEl = document.getElementById('activity');
  function renderActivity(evs, t) {
    activityEl.textContent = '';
    const head = document.createElement('div');
    head.className = 'row';
    const b = document.createElement('b');
    b.textContent = 'Cycle ' + t + ': ';
    head.appendChild(b);
    const counts = { issue: 0, sample: 0, drive: 0 };
    for (const e of evs) counts[e.kind]++;
    head.appendChild(document.createTextNode(counts.issue + ' issued, ' + counts.sample + ' stream reads, ' +
      counts.drive + ' stream drives, ' + (trace.occupancy[t] || []).length + ' occupied cells'));
    activityEl.appendChild(head);
    const MAXL = 40;
    let n = 0;
    for (const e of evs) {
      if (n++ >= MAXL) { const r = document.createElement('div'); r.className = 'row'; r.textContent = '… ' + (evs.length - MAXL) + ' more'; activityEl.appendChild(r); break; }
      const r = document.createElement('div');
      r.className = 'row';
      if (e.kind === 'issue') r.textContent = 'issue  ' + e.unit + ': ' + (e.text || e.opcode);
      else if (e.kind === 'drive') r.textContent = 'drive  ' + e.unit + ' ' + e.opcode + ' → ' + e.dir + e.stream + ' @' + e.pos + ' ' + e.tag;
      else r.textContent = 'read   ' + e.unit + ' ' + e.opcode + ' ← ' + e.dir + e.stream + ' @' + e.pos + ' ' + (e.tag || '(empty)') +
        (e.expect !== undefined && e.expect !== e.tag ? '  (expected ' + e.expect + ')' : '');
      activityEl.appendChild(r);
    }
  }

  cellsEl.addEventListener('mouseover', ev => {
    const el = ev.target.closest('.c');
    if (!el) return;
    const arr = cellIndex.get(el.dataset.lane);
    const c = arr && arr[Number(el.dataset.pos)];
    if (!c || c.tag === null) { setHL(null); return; }
    setHL(c.value);
  });
  cellsEl.addEventListener('mousemove', ev => {
    const el = ev.target.closest('.c');
    if (!el) { hideTip(); return; }
    const arr = cellIndex.get(el.dataset.lane);
    const p = Number(el.dataset.pos);
    const c = arr && arr[p];
    let s = 'lane ' + el.dataset.lane + ', pos ' + p + ' (' + sliceAtPos(p) + '), cycle ' + state.cycle;
    if (c && c.tag !== null) {
      s = c.tag + '\n' + s;
      if (c.flight) s += '\n' + (c.flight.last_sample_cycle !== null && state.cycle <= c.flight.last_sample_cycle ? 'live: read again by cycle ' + c.flight.last_sample_cycle : 'dead tail: not read again');
    } else s += '\nempty';
    showTip(s, ev);
  });
  cellsEl.addEventListener('mouseleave', () => { hideTip(); setHL(null); });
  slicesEl.addEventListener('mousemove', ev => {
    const el = ev.target.closest('.slice');
    if (!el) { hideTip(); return; }
    const s = chip.slices[Number(el.dataset.pos)];
    const evs = (evByCycle[state.cycle] || []).filter(e => sliceOfUnit.get(e.unit) === s.name);
    const lines = [s.name + '  (pos ' + s.pos + ')', 'units: ' + s.units.join(', ')];
    for (const e of evs) lines.push(e.kind + ' ' + e.unit + ' ' + (e.kind === 'issue' ? (e.text || e.opcode) : e.opcode + ' ' + e.dir + e.stream + ' ' + e.tag));
    showTip(lines.join('\n'), ev);
  });
  slicesEl.addEventListener('mouseleave', hideTip);

  /* --------------------------------------------------------------- highlight */
  const hlLabel = document.getElementById('hlLabel');
  function setHL(v) {
    if (v === '') v = null;
    if (v === state.hl) return;
    state.hl = v;
    hlLabel.textContent = v === null ? '' : 'Highlighted value: ' + v;
    requestDraw();
    applyHLCells();
  }
  function applyHLCells() {
    const v = state.hl;
    for (const c of touched) c.el.classList.toggle('dim', v !== null && c.value !== v);
  }

  /* ------------------------------------------------------------ cycle select */
  const slider = document.getElementById('slider');
  const cycleNum = document.getElementById('cycleNum');
  slider.max = String(NC - 1);
  cycleNum.max = String(NC - 1);
  function setCycle(c, follow) {
    c = Math.max(0, Math.min(NC - 1, Math.round(Number(c) || 0)));
    state.cycle = c;
    slider.value = String(c);
    cycleNum.value = String(c);
    updateChip();
    if (follow !== false) {
      const x = PAD_L + c * state.pxc;
      const sl = gScroll.scrollLeft, w = gScroll.clientWidth;
      if (x < sl + 20 || x > sl + w - 20) gScroll.scrollLeft = Math.max(0, x - w / 3);
    }
    requestDraw();
  }
  slider.addEventListener('input', () => setCycle(slider.value));
  cycleNum.addEventListener('change', () => setCycle(cycleNum.value));
  document.getElementById('first').addEventListener('click', () => setCycle(0));
  document.getElementById('last').addEventListener('click', () => setCycle(NC - 1));
  document.getElementById('prev').addEventListener('click', () => setCycle(state.cycle - 1));
  document.getElementById('next').addEventListener('click', () => setCycle(state.cycle + 1));
  const playBtn = document.getElementById('play');
  function stopPlay() { if (state.playing) { clearInterval(state.playing); state.playing = null; playBtn.textContent = 'Play'; playBtn.setAttribute('aria-label', 'Play'); } }
  playBtn.addEventListener('click', () => {
    if (state.playing) { stopPlay(); return; }
    if (state.cycle >= NC - 1) setCycle(0);
    playBtn.textContent = 'Pause'; playBtn.setAttribute('aria-label', 'Pause');
    state.playing = setInterval(() => { if (state.cycle >= NC - 1) stopPlay(); else setCycle(state.cycle + 1); }, 150);
  });
  document.addEventListener('keydown', ev => {
    const t = ev.target;
    if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT')) return;
    const big = ev.shiftKey ? 10 : 1;
    if (ev.key === 'ArrowRight') { setCycle(state.cycle + big); ev.preventDefault(); }
    else if (ev.key === 'ArrowLeft') { setCycle(state.cycle - big); ev.preventDefault(); }
    else if (ev.key === 'Home') { setCycle(0); ev.preventDefault(); }
    else if (ev.key === 'End') { setCycle(NC - 1); ev.preventDefault(); }
  });

  /* ------------------------------------------------------------- idle toggle */
  document.getElementById('showIdle').addEventListener('change', ev => {
    state.showIdle = ev.target.checked;
    layoutGantt();
    buildCells();
    updateChip();
  });

  /* ------------------------------------------------------------------ start */
  readColours();
  const mq = window.matchMedia('(prefers-color-scheme: dark)');
  const onScheme = () => { readColours(); requestDraw(); updateChip(); };
  if (mq.addEventListener) mq.addEventListener('change', onScheme);
  if (window.ResizeObserver) new ResizeObserver(() => sizeCanvas()).observe(gScroll);
  else window.addEventListener('resize', sizeCanvas);

  layoutGantt();
  const fz = fitZoom();
  state.pxc = fz >= 4 ? Math.min(fz, 24) : 4;
  sizeCanvas();
  buildCells();
  setCycle(0);
  document.body.dataset.ready = '1';
})();

/* pointer-chase — walking a linked list whose nodes are scattered vs walking a contiguous array.
 * <div class="figure-body" data-viz="pointer-chase" data-opts='{"nodes":12}'></div>
 * Options:
 *   nodes     2..32 nodes to visit (default 12)
 *   nodeBytes 8 | 16 | 32 bytes per node (default 16, so 4 nodes share a 64 B line)
 *   lines     memory size in 64 B lines (default max(nodes, 12)); must be >= nodes so each list node gets its own line
 *   seed      integer seed for the scatter (default 7)
 *   hitNs     simulated cost of a cache hit (default 1)
 *   missNs    simulated cost of a miss to DRAM (default 100)
 *   interval  seconds per step while playing (default 0.5)
 * Model: the cache starts cold and is big enough to keep every line it has loaded, so a miss happens on the first
 * touch of each line. Simulated time = misses × missNs + hits × hitNs. Not modelled (and noted in the figure):
 * array addresses are known in advance, so a real CPU prefetches and overlaps them; the list cannot do that. */
(window.BookQ ||= []).push((B) => B.viz.register("pointer-chase", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["nodes", "nodeBytes", "lines", "seed", "hitNs", "missNs", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `pointer-chase: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const N = opts.nodes ?? 12, NB = opts.nodeBytes ?? 16, LINES = opts.lines ?? Math.max(N, 12);
  viz.check(Number.isInteger(N) && N >= 2 && N <= 32, `pointer-chase: "nodes" must be an integer 2..32`);
  viz.check([8, 16, 32].includes(NB), `pointer-chase: "nodeBytes" must be 8, 16 or 32`);
  viz.check(Number.isInteger(LINES) && LINES >= N && LINES <= 64, `pointer-chase: "lines" must be an integer between nodes (${N}) and 64`);
  const HIT = opts.hitNs ?? 1, MISS = opts.missNs ?? 100;
  viz.check(HIT > 0 && MISS > 0, `pointer-chase: "hitNs" and "missNs" must be positive`);
  const PER = 64 / NB, SLOTS = LINES * PER;
  const rnd = B.rng(opts.seed ?? 7);
  // list: pick N distinct lines in random order, one node at a random slot in each
  const lineIds = [...Array(LINES).keys()];
  for (let i = lineIds.length - 1; i > 0; i--) { const j = rnd.int(i + 1); [lineIds[i], lineIds[j]] = [lineIds[j], lineIds[i]]; }
  const listSlots = lineIds.slice(0, N).map((l) => l * PER + rnd.int(PER));
  const arraySlots = [...Array(N).keys()];

  function stats(slots, k) {
    const seen = new Set();
    let misses = 0;
    for (let i = 0; i < k; i++) { const l = Math.floor(slots[i] / PER); if (!seen.has(l)) { seen.add(l); misses++; } }
    return { misses, hits: k - misses, ns: misses * MISS + (k - misses) * HIT, lines: seen };
  }

  let k = 0;
  const C = B.colors();
  const sides = [
    { key: "list", title: "Linked list", sub: `nodes scattered by the allocator · ${NB} B each · next = pointer`, slots: listSlots },
    { key: "array", title: "Array", sub: `nodes contiguous · ${NB} B each · next = i + 1`, slots: arraySlots },
  ].map((s) => {
    const canvas = h("canvas", { role: "img" });
    const cnt = B.counters([["acc", "visited"], ["miss", "misses", "bad"], ["ns", "simulated"]]);
    const el = h("div", { class: "viz-panel" }, h("p", { class: "viz-title" }, s.title, h("small", {}, s.sub)), canvas, cnt.el);
    return { ...s, canvas, cnt, el, k: B.canvas(canvas, 300, 100) };
  });
  const summary = h("p", { class: "readout", "aria-live": "off" });
  const player = B.player(root, {
    step: () => (k < N ? (k++, true) : false),
    back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; },
    atEnd: () => k === N,
    draw: () => draw(),
    interval: opts.interval ?? 0.5,
  });
  const legend = h("div", { class: "legend" });
  [["node", C.pos], ["visited node", C.heading], ["line loaded (miss)", C.line], ["free / other memory", "transparent"]].forEach(([t, c]) => {
    const i = h("i"); i.style.background = c; if (c === "transparent") i.style.outline = "1px solid " + C.border;
    legend.append(h("span", {}, i, t));
  });
  root.append(h("div", { class: "viz-panels" }, sides.map((s) => s.el)), summary,
    h("div", { class: "controls" }, player.el), legend,
    h("p", { class: "viz-note" }, `Model: ${MISS} ns per miss, ${HIT} ns per hit, cold cache. Real arrays do even better than this: the addresses are known ahead of time, so the prefetcher and out-of-order core overlap the misses. Each list miss must finish before the next address is known.`));

  function drawSide(s) {
    const W = s.k.width, ctx = s.k.ctx;
    const linesPerRow = W >= 560 ? Math.min(LINES, 12) : W >= 380 ? 6 : 4;
    const perRow = linesPerRow * PER, gapL = 6;
    const cw = (W - 6 - (linesPerRow - 1) * gapL) / perRow, ch = Math.max(14, Math.min(22, cw * 1.1));
    const rows = Math.ceil(LINES / linesPerRow), rowH = ch + 30;
    const H = rows * rowH + 6;
    if (Math.abs(s.k.height - H) > 0.5) s.k.fit(W, H);
    ctx.clearRect(0, 0, W, H);
    const pos = (slot) => {
      const line = Math.floor(slot / PER), r = Math.floor(line / linesPerRow), lc = line % linesPerRow;
      return { x: 3 + lc * (PER * cw + gapL) + (slot % PER) * cw, y: 18 + r * rowH };
    };
    const st = stats(s.slots, k);
    for (let l = 0; l < LINES; l++) {
      const { x, y } = pos(l * PER);
      if (st.lines.has(l)) { ctx.fillStyle = "rgba(124,196,255,.18)"; ctx.fillRect(x - 2, y - 3, PER * cw + 4, ch + 6); ctx.strokeStyle = C.line; ctx.lineWidth = 1.5; ctx.strokeRect(x - 2, y - 3, PER * cw + 4, ch + 6); }
      for (let j = 0; j < PER; j++) { ctx.strokeStyle = C.border; ctx.lineWidth = 1; ctx.strokeRect(x + j * cw + 1.5, y + 0.5, cw - 3, ch - 1); }
    }
    const idxOf = new Map(s.slots.map((sl, i) => [sl, i]));
    for (const [sl, i] of idxOf) {
      const { x, y } = pos(sl);
      ctx.fillStyle = i < k ? C.heading : C.pos; ctx.globalAlpha = i < k ? 1 : 0.85;
      ctx.fillRect(x + 1.5, y + 0.5, cw - 3, ch - 1); ctx.globalAlpha = 1;
      if (cw >= 13) { ctx.fillStyle = "#06121f"; ctx.font = "600 10px " + C.mono; ctx.textAlign = "center"; ctx.textBaseline = "middle"; ctx.fillText(String(i), x + cw / 2, y + ch / 2 + 1); ctx.textAlign = "start"; }
      if (i === k - 1) { ctx.strokeStyle = C.flag; ctx.lineWidth = 2.5; ctx.strokeRect(x, y - 1, cw, ch + 2); }
    }
    // arrows for the hops taken so far (list only: array hops are just "the next cell")
    if (s.key === "list") {
      for (let i = 0; i + 1 < N; i++) {
        const a = pos(s.slots[i]), b = pos(s.slots[i + 1]);
        const ax = a.x + cw / 2, ay = a.y, bx = b.x + cw / 2, by = b.y;
        const lift = 12 + Math.min(40, Math.abs(bx - ax) * 0.15);
        ctx.strokeStyle = i < k - 1 ? C.flag : "rgba(139,150,168,.35)"; ctx.lineWidth = i < k - 1 ? 1.75 : 1;
        // the curve's peak is (ay + 2·cy + by) / 4: keep it at least 3px below the canvas top
        const cy = Math.max(Math.min(ay, by) - lift, (12 - ay - by) / 2);
        ctx.beginPath(); ctx.moveTo(ax, ay); ctx.quadraticCurveTo((ax + bx) / 2, cy, bx, by); ctx.stroke();
        ctx.beginPath(); ctx.arc(bx, by, 2.2, 0, 7); ctx.fillStyle = ctx.strokeStyle; ctx.fill();
      }
    }
    s.cnt.set("acc", `${k}/${N}`);
    s.cnt.set("miss", st.misses);
    s.cnt.set("ns", st.ns + " ns");
    s.canvas.setAttribute("aria-label", `${s.title}: ${k} of ${N} nodes visited, ${st.misses} cache misses, ${st.ns} simulated nanoseconds.`);
    return st;
  }
  function draw() {
    const [a, b] = sides.map((s) => (s.k.width > 10 ? drawSide(s) : stats(s.slots, k)));
    summary.textContent = k === 0 ? `Predict: how many misses will each walk take for ${N} nodes?`
      : `after ${k} node${k === 1 ? "" : "s"}: list ${a.misses} misses (${a.ns} ns) vs array ${b.misses} misses (${b.ns} ns) → ${(a.ns / b.ns).toFixed(1)}× slower`;
  }
  sides.forEach((s) => B.onResize(s.el, (w) => { s.k.fit(w, s.k.height); drawSide(s); }));
  draw();
}));

/* ch02-prefetch — a sequential stream that the hardware prefetcher runs ahead of, versus a random chase that
 * stalls on every line. One idea: the prefetcher hides latency only when it can guess the next address.
 * <div class="figure-body" data-viz="ch02-prefetch" data-opts='{"latency":200,"distance":16}'></div>
 * Options:
 *   pattern   "sequential" | "random" (initial, default "sequential")
 *   latency   memory latency in cycles, 20..400 (default 200)
 *   distance  prefetch distance in lines, 0..32; 0 turns the prefetcher off (default 16)
 *   work      cycles of work per 64 B line, 2..32 (default 8)
 *   interval  seconds per step while playing (default 0.12)
 * Model (a teaching model, not a measurement): 128 lines = two 4 KiB pages of 64 lines. The core reads one line,
 * stalls until it has arrived, then works on it for `work` cycles. A streamer prefetcher trains on two
 * consecutive ascending lines and from then on keeps `distance` lines requested ahead, but never past the end
 * of the current 4 KiB page, so it has to retrain on the next page. Each request arrives `latency` cycles after
 * it is issued, and any number may be in flight (real cores have 10–20 fill buffers). The random pattern follows
 * a Sattolo single cycle, so its next address is unknown until the current line arrives: nothing to prefetch. */
(window.BookQ ||= []).push((B) => B.viz.register("ch02-prefetch", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["pattern", "latency", "distance", "work", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch02-prefetch: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const PATTERNS = ["sequential", "random"];
  let pat = PATTERNS.indexOf(opts.pattern ?? "sequential");
  viz.check(pat >= 0, `ch02-prefetch: "pattern" must be "sequential" or "random"`);
  let L = opts.latency ?? 200, D = opts.distance ?? 16;
  const W = opts.work ?? 8;
  viz.check(Number.isInteger(L) && L >= 20 && L <= 400, `ch02-prefetch: "latency" must be an integer 20..400`);
  viz.check(Number.isInteger(D) && D >= 0 && D <= 32, `ch02-prefetch: "distance" must be an integer 0..32`);
  viz.check(Number.isInteger(W) && W >= 2 && W <= 32, `ch02-prefetch: "work" must be an integer 2..32`);

  const LINES = 128, PAGE = 64, COLS = 16;
  // random visiting order: follow a Sattolo cycle over the 128 lines from line 0
  const rnd = B.rng(11), cyc = [...Array(LINES).keys()];
  for (let i = LINES - 1; i > 0; i--) { const j = rnd.int(i); [cyc[i], cyc[j]] = [cyc[j], cyc[i]]; }
  const randomOrder = [];
  for (let i = 0, k = 0; k < LINES; k++, i = cyc[i]) randomOrder.push(i);
  const seqOrder = [...Array(LINES).keys()];

  function simulate(order) {
    const req = new Array(LINES).fill(-1), rdy = new Array(LINES).fill(0), byPf = new Array(LINES).fill(false);
    const steps = [];
    let t = 0, last = -2, streak = 0, page = -1, misses = 0, stall = 0, pf = 0;
    for (const line of order) {
      const p = Math.floor(line / PAGE);
      if (p !== page) { page = p; streak = 0; }          // the streamer tracks one 4 KiB page at a time
      streak = line === last + 1 ? streak + 1 : 1;
      last = line;
      if (D > 0 && streak >= 2) {                         // trained: keep D lines requested ahead, inside this page
        for (let x = line + 1; x <= line + D && x < (p + 1) * PAGE; x++) {
          if (req[x] < 0) { req[x] = t; rdy[x] = t + L; byPf[x] = true; pf++; }
        }
      }
      let miss = false;
      if (req[line] < 0) { req[line] = t; rdy[line] = t + L; misses++; miss = true; }
      const wait = Math.max(0, rdy[line] - t);
      steps.push({ line, arrive: t, wait, start: t + wait, end: t + wait + W, miss });
      stall += wait;
      t += wait + W;
    }
    return { steps, req, rdy, byPf, total: t, misses, stall, pf };
  }

  let sims, k = 0;
  const recompute = () => { sims = [simulate(seqOrder), simulate(randomOrder)]; };
  recompute();
  const C = B.colors();
  const canvas = h("canvas", { role: "img" });
  const kc = B.canvas(canvas, 640, 300);
  const cnt = B.counters([["cyc", "cycle"], ["lines", "lines read"], ["miss", "demand misses", "bad"],
    ["stall", "stall cycles", "bad"], ["cpl", "cycles per line"], ["pf", "prefetches"]]);
  const hint = h("p", { class: "chart-meta" });

  function layout() {
    const w = kc.width, cell = Math.floor((w - 8) / COLS), gap = Math.max(2, Math.round(cell * 0.12));
    const rowsH = (LINES / COLS) * cell;
    return { cell, gap, gridTop: 18, pageGap: 14, tlTop: 18 + rowsH + 14 + 26, x0: Math.floor((w - cell * COLS) / 2) };
  }
  function cellXY(line, lo) {
    const r = Math.floor(line / COLS), c = line % COLS;
    return [lo.x0 + c * lo.cell, lo.gridTop + r * lo.cell + (line >= PAGE ? lo.pageGap : 0)];
  }

  function draw() {
    const sim = sims[pat], ctx = kc.ctx, lo = layout();
    ctx.clearRect(0, 0, kc.width, kc.height);
    const T = k === 0 ? 0 : sim.steps[k - 1].end;
    const done = new Set(sim.steps.slice(0, k).map((s) => s.line));
    ctx.font = `11px ${C.mono || "monospace"}`;
    ctx.fillStyle = C.dim; ctx.textBaseline = "alphabetic";
    ctx.fillText("page 0 · 4 KiB · 64 lines", lo.x0, lo.gridTop - 5);
    const [, y1] = cellXY(PAGE, lo);
    ctx.fillText("page 1 · the streamer stops at the page edge", lo.x0, y1 - 4);
    for (let line = 0; line < LINES; line++) {
      const [x, y] = cellXY(line, lo), s = lo.cell - lo.gap;
      const inflight = sim.req[line] >= 0 && sim.req[line] <= T && sim.rdy[line] > T;
      const arrived = sim.req[line] >= 0 && sim.req[line] <= T && sim.rdy[line] <= T;
      ctx.globalAlpha = 1;
      if (done.has(line)) { ctx.fillStyle = C.pos; ctx.globalAlpha = 0.35; ctx.fillRect(x, y, s, s); }
      else if (arrived) { ctx.fillStyle = C.hit; ctx.fillRect(x, y, s, s); }
      else if (inflight) {
        ctx.fillStyle = C.flag; ctx.globalAlpha = 0.25; ctx.fillRect(x, y, s, s);
        ctx.globalAlpha = 1; const f = (T - sim.req[line]) / L; ctx.fillRect(x, y + s * (1 - f), s, s * f);
      }
      ctx.globalAlpha = 1; ctx.strokeStyle = C.border; ctx.lineWidth = 1; ctx.strokeRect(x + 0.5, y + 0.5, s - 1, s - 1);
    }
    if (k > 0) {
      const st = sim.steps[k - 1], [x, y] = cellXY(st.line, lo), s = lo.cell - lo.gap;
      ctx.strokeStyle = st.wait > 0 ? C.miss : C.heading; ctx.lineWidth = 2.5; ctx.strokeRect(x + 1, y + 1, s - 2, s - 2);
    }
    // timeline: one strip per pattern, both on the same time scale
    const tmax = Math.max(sims[0].total, sims[1].total), tx0 = lo.x0, tw = lo.cell * COLS;
    PATTERNS.forEach((name, pi) => {
      const sm = sims[pi], y = lo.tlTop + pi * 34, upto = pi === pat ? k : 0;
      ctx.fillStyle = pi === pat ? C.text : C.dim; ctx.globalAlpha = 1;
      ctx.fillText(`${name}: ${B.fmtInt(sm.total)} cycles total`, tx0, y - 4);
      ctx.strokeStyle = C.border; ctx.lineWidth = 1; ctx.strokeRect(tx0 + 0.5, y + 0.5, (sm.total / tmax) * tw - 1, 13);
      for (let i = 0; i < upto; i++) {
        const st = sm.steps[i];
        if (st.wait > 0) { ctx.fillStyle = C.miss; ctx.fillRect(tx0 + (st.arrive / tmax) * tw, y + 1, Math.max(1, (st.wait / tmax) * tw), 12); }
        ctx.fillStyle = C.vel; ctx.fillRect(tx0 + (st.start / tmax) * tw, y + 1, Math.max(0.6, (W / tmax) * tw), 12);
      }
    });
    const st = sim.steps.slice(0, k);
    const stall = st.reduce((a, s) => a + s.wait, 0), misses = st.filter((s) => s.miss).length;
    const pfs = sim.req.filter((r, i) => sim.byPf[i] && r <= T && r >= 0).length;
    cnt.set("cyc", B.fmtInt(T)); cnt.set("lines", k + " / " + LINES); cnt.set("miss", misses);
    cnt.set("stall", B.fmtInt(stall)); cnt.set("cpl", k ? (T / k).toFixed(1) : "–"); cnt.set("pf", pfs);
    canvas.setAttribute("aria-label", `Prefetch model, ${PATTERNS[pat]}: ${k} of ${LINES} lines read, ${misses} demand misses, ` +
      `${stall} stall cycles. Totals: sequential ${sims[0].total} cycles, random ${sims[1].total} cycles.`);
    hint.textContent = `Model: ${L}-cycle memory, ${W} cycles of work per line. The prefetcher must run about ` +
      `${Math.ceil(L / W)} lines ahead (latency ÷ work) to hide the latency completely; it is set to ` +
      (D ? `${D}.` : "off.") + " Red = stalled, blue = working.";
  }

  const player = B.player(root, {
    step: () => (k < LINES ? (k++, true) : false), back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; }, atEnd: () => k === LINES, draw, interval: opts.interval ?? 0.12,
  });
  const latS = B.slider({ label: "memory latency", min: 20, max: 400, step: 10, value: L, format: (v) => v + " cycles",
    oninput: (v) => { L = v; recompute(); draw(); } });
  const distS = B.slider({ label: "prefetch distance", min: 0, max: 32, step: 1, value: D, format: (v) => (v ? v + " lines" : "off"),
    oninput: (v) => { D = v; recompute(); draw(); } });
  root.append(canvas, cnt.el, h("div", { class: "controls" }, player.el,
    B.segmented(["sequential", "random chase"], pat, (i) => { pat = i; k = Math.min(k, LINES); draw(); }, "Access pattern")),
  h("div", { class: "controls" }, latS, distS), hint);
  B.onResize(root, (w) => {
    const cw = Math.min(w, 720), cell = Math.floor((cw - 8) / COLS);
    kc.fit(cw, 18 + (LINES / COLS) * cell + 14 + 26 + 2 * 34 + 6);
    draw();
  });
  draw();
}));

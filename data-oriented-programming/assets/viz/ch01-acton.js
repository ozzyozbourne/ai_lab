/* ch01-acton — Mike Acton's cache-line arithmetic from "Data-Oriented Design and C++" (CppCon 2014), as a model.
 * <div class="figure-body" data-viz="ch01-acton" data-opts='{"items":32}'></div>
 * Options:
 *   items     8..64, multiple of 8 (default 32, Acton's count)
 *   miss      cycles per cache line fetched from memory, 100..400 (default 200, Acton's "~200")
 *   work      cycles of arithmetic per item, 10..80 (default 40, Acton's "Sqrt + math = ~40")
 *   interval  seconds per step while playing (default 0.25)
 * Model (Acton's back-of-the-envelope, made explicit):
 *   Object version: GameObject::UpdateFoo reads m_Velocity[2] (8 B at offset 8) and read-modify-writes m_Foo (4 B at
 *   offset 184), so each object costs two different 64 B lines. The objects are large and visited one at a time, so
 *   each miss is waited for: cycles = items × (2 × miss + work).
 *   Data version: FooUpdateIn {m_Velocity[2], m_Foo} is 12 B and FooUpdateOut {m_Foo} is 4 B, both in arrays. The loop
 *   streams through them, the prefetcher overlaps fetching with work, so the slower of the two wins:
 *   cycles = max(items × work, lines × miss). With Acton's numbers each 64 B input line holds 5.33 items
 *   = 5.33 × 40 ≈ 213 cycles of work, about one miss, so the memory cost hides behind the math. */
(window.BookQ ||= []).push((B) => B.viz.register("ch01-acton", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["items", "miss", "work", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch01-acton: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  let n = opts.items ?? 32, M = opts.miss ?? 200, W = opts.work ?? 40;
  viz.check(Number.isInteger(n) && n >= 8 && n <= 64 && n % 8 === 0, 'ch01-acton: "items" must be 8..64 and a multiple of 8');
  viz.check(M >= 100 && M <= 400, 'ch01-acton: "miss" must be 100..400');
  viz.check(W >= 10 && W <= 80, 'ch01-acton: "work" must be 10..80');
  const C = B.colors();

  const oop = (i) => ({ lines: 2 * i, used: 12 * i, cycles: i * (2 * M + W) });
  const dod = (i) => {
    const lines = Math.ceil((12 * i) / 64) + Math.ceil((4 * i) / 64);
    return { lines, used: 16 * i, cycles: i ? Math.max(i * W, lines * M) : 0 };
  };

  let k = 0;
  const panels = [
    { key: "oop", title: "GameObject::UpdateFoo", sub: "one 192 B object at a time; reads 8 B + 4 B", f: oop },
    { key: "dod", title: "UpdateFoos(in[], out[])", sub: "12 B FooUpdateIn + 4 B FooUpdateOut, in arrays", f: dod },
  ].map((p) => {
    const canvas = h("canvas", { role: "img" });
    const cnt = B.counters([["lines", "lines fetched"], ["use", "bytes used"], ["cyc", "cycles (model)"], ["per", "cycles/item"]]);
    const el = h("div", { class: "viz-panel" }, h("p", { class: "viz-title" }, p.title, h("small", {}, p.sub)), canvas, cnt.el);
    return { ...p, canvas, cnt, el, k: B.canvas(canvas, 300, 120) };
  });
  const summary = h("p", { class: "readout", "aria-live": "off" });
  const player = B.player(root, {
    step: () => (k < n ? (k++, true) : false),
    back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; },
    atEnd: () => k === n,
    draw: () => draw(),
    interval: opts.interval ?? 0.25,
  });
  const sItems = B.slider({ label: "items", min: 8, max: 64, step: 8, value: n, format: String, oninput: (v) => { n = v; k = Math.min(k, n); draw(); } });
  const sMiss = B.slider({ label: "cycles per miss", min: 100, max: 400, step: 25, value: M, format: String, oninput: (v) => { M = v; draw(); } });
  const sWork = B.slider({ label: "work per item", min: 10, max: 80, step: 5, value: W, format: String, oninput: (v) => { W = v; draw(); } });
  const legend = h("div", { class: "legend" });
  [["m_Velocity (read)", C.vel], ["m_Foo (read + write)", C.pos], ["line fetched", C.line]].forEach(([t, c]) => { const i = h("i"); i.style.background = c; legend.append(h("span", {}, i, t)); });
  const hatch = h("i", { class: "hatch" }); legend.append(h("span", {}, hatch, "fetched but unused"));
  root.append(h("div", { class: "viz-panels" }, panels.map((p) => p.el)), summary,
    h("div", { class: "controls" }, player.el, sItems, sMiss, sWork), legend,
    h("p", { class: "viz-note" }, "Acton's back-of-the-envelope model, not a measurement. Object version: two waited-for misses per item. " +
      "Array version: the prefetcher overlaps memory with math, so time = the larger of total work and total line fetches."));

  function hatchFill(ctx, x, y, w, hh) {
    ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, hh); ctx.clip();
    ctx.fillStyle = C.pad; ctx.fillRect(x, y, w, hh);
    ctx.strokeStyle = "#5b6676"; ctx.lineWidth = 1;
    for (let d = -hh; d < w; d += 4) { ctx.beginPath(); ctx.moveTo(x + d, y + hh); ctx.lineTo(x + d + hh, y); ctx.stroke(); }
    ctx.restore();
  }
  /** lines: [{fetched, segs:[[byteOff, size, color]]}] drawn as 64 B bars, `per` per row. */
  function drawLines(p, lines) {
    const ctx = p.k.ctx, Wd = p.k.width;
    const per = Wd >= 420 ? 12 : 6, gap = 4, lw = (Wd - (per - 1) * gap) / per, lh = 12, rowH = lh + 6;
    const H = Math.max(1, Math.ceil(lines.length / per)) * rowH + 4;
    if (Math.abs(p.k.height - H) > 0.5) p.k.fit(Wd, H);
    ctx.clearRect(0, 0, Wd, H);
    lines.forEach((ln, j) => {
      const x = (j % per) * (lw + gap), y = 2 + Math.floor(j / per) * rowH;
      if (ln.fetched) {
        hatchFill(ctx, x, y, lw, lh);
        for (const [off, size, color] of ln.segs) { ctx.fillStyle = color; ctx.fillRect(x + (off / 64) * lw, y, Math.max(1.5, (size / 64) * lw), lh); }
        ctx.strokeStyle = C.line; ctx.lineWidth = 1.5; ctx.strokeRect(x + 0.5, y + 0.5, lw - 1, lh - 1);
      } else {
        ctx.strokeStyle = C.border; ctx.lineWidth = 1; ctx.setLineDash([3, 3]); ctx.strokeRect(x + 0.5, y + 0.5, lw - 1, lh - 1); ctx.setLineDash([]);
      }
    });
  }

  function draw() {
    // object version: 3 lines per object; line 0 holds m_Velocity (offset 8), line 2 holds m_Foo (offset 184 = 56 in line 2)
    const a = [];
    for (let i = 0; i < n; i++) {
      const f = i < k;
      a.push({ fetched: f, segs: [[8, 8, C.vel]] }, { fetched: false, segs: [] }, { fetched: f, segs: [[56, 4, C.pos]] });
    }
    // data version: input lines (12 B records: 8 B velocity + 4 B foo), then output lines (4 B foo)
    const inLines = Math.ceil((12 * n) / 64), outLines = Math.ceil((4 * n) / 64);
    const b = [];
    const clip = (l, lo, hi, color) => {            // the part of byte range [lo, hi) inside line l
      const a0 = Math.max(lo, l * 64), a1 = Math.min(hi, l * 64 + 64);
      return a1 > a0 ? [[a0 - l * 64, a1 - a0, color]] : [];
    };
    for (let l = 0; l < inLines; l++) {
      const segs = [];
      for (let i = 0; i < n; i++) segs.push(...clip(l, 12 * i, 12 * i + 8, C.vel), ...clip(l, 12 * i + 8, 12 * i + 12, C.pos));
      b.push({ fetched: l < Math.ceil((12 * k) / 64), segs });
    }
    for (let l = 0; l < outLines; l++) b.push({ fetched: l < Math.ceil((4 * k) / 64), segs: [[0, 64, C.pos]] });

    [[panels[0], a], [panels[1], b]].forEach(([p, lines]) => {
      if (p.k.width > 10) drawLines(p, lines);
      const st = p.f(k);
      p.cnt.set("lines", st.lines);
      p.cnt.set("use", st.lines ? `${st.used} / ${st.lines * 64} B (${Math.round((100 * st.used) / (st.lines * 64))}%)` : "–");
      p.cnt.set("cyc", B.fmtInt(st.cycles));
      p.cnt.set("per", k ? (st.cycles / k).toFixed(0) : "–");
      p.canvas.setAttribute("aria-label", `${p.title}: ${k} of ${n} items, ${st.lines} cache lines fetched, ${st.used} bytes used, ${st.cycles} model cycles.`);
    });
    const A = oop(k), D = dod(k);
    summary.textContent = k === 0
      ? `Predict: with ${M}-cycle misses and ${W} cycles of math per item, how much faster is the array version?`
      : `after ${k} items: ${B.fmtInt(A.cycles)} vs ${B.fmtInt(D.cycles)} cycles → ${(A.cycles / D.cycles).toFixed(1)}× ` +
        `(array version: math ${B.fmtInt(k * W)} vs memory ${B.fmtInt(D.lines * M)} cycles, so ${k * W >= D.lines * M ? "math hides memory" : "memory is still the bound"})`;
  }

  panels.forEach((p) => B.onResize(p.el, (w) => { p.k.fit(w, p.k.height); draw(); }));
  draw();
}));

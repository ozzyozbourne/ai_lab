/* ch12-strip — run-to-run spread for MANY samples per row (30–50), drawn as a small histogram per row.
 * <div class="figure-body" data-viz="ch12-strip" data-bench="ch12-noise" data-opts='{"relative":true}'></div>
 * The shared bench-dist draws one dot per sample and stacks close dots vertically, which suits the harness's 7
 * samples; with 41 samples the stacks run into neighbouring rows. This figure bins the samples instead.
 * Options:
 *   labels, langs  filters (lists; labels also fix the row order)
 *   relative       true: x axis is % from each row's median (default true); false: absolute time
 *   clip           upper limit of the relative axis in percent (default: none); samples beyond it pile into the last bin, marked "≥"
 * Per row: a histogram of the samples (bar height = count, scaled to the fullest bin of that row), the median (tick),
 * min–max (thin line), and CV = sample stdev / mean, all computed from run.samples. */
(window.BookQ ||= []).push((B) => B.viz.register("ch12-strip", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["labels", "langs", "relative", "clip", "bench"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch12-strip: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  viz.check(opts.clip === undefined || (typeof opts.clip === "number" && opts.clip > 0), 'ch12-strip: "clip" must be a positive number (percent)');
  const src = B.benchSource(root, opts);
  if (src.missing) return viz.empty(root, `No benchmark data for "${src.id}" yet. Load assets/data/bench-chNN.js or run code/bench_all.sh.`);
  let runs = src.runs.filter((r) => Array.isArray(r.samples) && r.samples.length >= 2);
  if (opts.langs) runs = runs.filter((r) => opts.langs.includes(String(r.lang || "").toLowerCase()));
  if (opts.labels) runs = runs.filter((r) => opts.labels.includes(r.label));
  const LO = ["rust", "zig", "odin"];
  runs.sort((a, b) => (opts.labels ? opts.labels.indexOf(a.label) - opts.labels.indexOf(b.label) : 0) || LO.indexOf(a.lang) - LO.indexOf(b.lang));
  if (!runs.length) return viz.empty(root, "ch12-strip: no runs with samples.");
  const rows = runs.map((r) => {
    const s = [...r.samples].sort((a, b) => a - b), n = s.length, mean = s.reduce((a, b) => a + b, 0) / n;
    const sd = Math.sqrt(s.reduce((a, b) => a + (b - mean) ** 2, 0) / (n - 1));
    return { r, s, med: s[(n - 1) >> 1], cv: sd / mean };
  });
  let relative = opts.relative ?? true;
  const chart = B.chart(root, render);
  root.append(h("div", { class: "controls" }, B.segmented(["absolute time", "% from median"], relative ? 1 : 0, (i) => { relative = i === 1; chart.redraw(); }, "X axis")),
    B.benchMeta(src, `${rows[0].s.length} timed runs per row, binned · tick = median · CV = stdev/mean`));

  function render(W) {
    const narrow = W < 560, labelW = narrow ? 0 : Math.min(190, W * 0.27), statsW = narrow ? 0 : 140, rowH = narrow ? 50 : 34;
    const H = rows.length * rowH + 28, x0 = labelW + (narrow ? 2 : 10), x1 = W - statsW - 8;
    const val = (row, v) => (relative ? (100 * (v - row.med)) / row.med : v);
    let lo = Math.min(...rows.map((row) => val(row, row.s[0]))), hi = Math.max(...rows.map((row) => val(row, row.s[row.s.length - 1])));
    const clipped = relative && opts.clip !== undefined && hi > opts.clip;
    if (clipped) hi = opts.clip;
    const pad = (hi - lo) * 0.04 || 1;
    const x = B.scaleLinear(relative ? Math.min(lo - pad, -pad) : Math.max(0, lo - pad), hi + pad, x0, x1);
    const C = B.colors();
    const svg = B.svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img",
      "aria-label": "Histogram of timed runs per row: " + rows.map((row) => `${row.r.label} ${row.r.lang} median ${B.fmtNs(row.med)}, CV ${(row.cv * 100).toFixed(1)}%`).join("; ") });
    const grid = B.svg("g", { class: "grid" }), axis = B.svg("g", { class: "axis" });
    for (const t of x.ticks(narrow ? 4 : 6)) {
      grid.append(B.svg("line", { x1: x(t), x2: x(t), y1: 0, y2: H - 22 }));
      axis.append(B.svg("text", { x: x(t), y: H - 6, "text-anchor": "middle" }, relative ? (t > 0 ? "+" : "") + +t.toFixed(1) + "%" : B.fmtNs(t, 2)));
    }
    svg.append(grid, axis);
    const NB = Math.max(12, Math.round((x1 - x0) / 5)), bw = (x1 - x0) / NB;
    rows.forEach((row, i) => {
      const base = i * rowH + rowH - 4, barMax = narrow ? 22 : 24, color = B.langColor(row.r.lang);
      const name = `${row.r.label} · ${row.r.lang}`, stats = `${B.fmtNs(row.med)} · CV ${(row.cv * 100).toFixed(1)}%`;
      if (narrow) svg.append(B.svg("text", { x: 0, y: base - barMax - 4 }, name + "  ", B.svg("tspan", { class: "dim mono" }, stats)));
      else {
        svg.append(B.svg("text", { x: labelW, y: base - 6, "text-anchor": "end" }, name));
        svg.append(B.svg("text", { x: W - statsW, y: base - 6, class: "mono", style: "font-size:11px" }, stats));
      }
      const bins = new Array(NB).fill(0);
      let over = 0;
      for (const v of row.s) {
        const px = x(Math.min(val(row, v), hi + pad));
        const b = Math.max(0, Math.min(NB - 1, Math.floor((px - x0) / bw)));
        bins[b]++;
        if (clipped && val(row, v) > hi) over++;
      }
      const top = Math.max(...bins);
      svg.append(B.svg("line", { x1: x0, x2: x1, y1: base + 0.5, y2: base + 0.5, stroke: C.border }));
      bins.forEach((c, b) => {
        if (!c) return;
        const hh = Math.max(2, (barMax * c) / top);
        const rect = B.svg("rect", { x: x0 + b * bw + 0.5, y: base - hh, width: Math.max(1, bw - 1), height: hh, fill: color, "fill-opacity": 0.85 });
        rect.append(B.svg("title", {}, `${c} run${c > 1 ? "s" : ""}`));
        svg.append(rect);
      });
      if (over) svg.append(B.svg("text", { x: x1 + 2, y: base - 2, class: "mono", style: "font-size:10px" }, `≥ ${over}`));
      const mx = x(val(row, row.med));
      svg.append(B.svg("line", { x1: mx, x2: mx, y1: base - barMax - 2, y2: base + 3, stroke: C.heading, "stroke-width": 2 }));
    });
    return svg;
  }
}));

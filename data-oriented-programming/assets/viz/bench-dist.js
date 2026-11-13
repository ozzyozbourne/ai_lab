/* bench-dist — the spread of the individual timed runs behind each median (noise made visible).
 * <div class="figure-body" data-viz="bench-dist" data-bench="ch12-noise" data-opts='{"relative":false}'></div>
 * Uses run.samples (the sorted per-run times the harness prints). Options:
 *   labels, langs   filters (lists);  n  only runs with this n (default: largest n per label+lang)
 *   relative        true to start with the x axis as % difference from each row's median (default: true when
 *                   the medians differ by more than 5×, so rows stay readable)
 *   runs + source/machine/date/note   inline data instead of data-bench
 * Per row it shows every sample (dot), min–max (line), median (tick), and computes CV = stdev / mean.
 * Close samples stack vertically inside the row; with more than 12 samples per row the rows get taller, dots get
 * smaller and translucent, and a crowded cluster overlaps instead of growing (so 30–50 samples stay in their row). */
(window.BookQ ||= []).push((B) => B.viz.register("bench-dist", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["labels", "langs", "n", "relative", "runs", "source", "machine", "date", "note", "compilers", "bench"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `bench-dist: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const src = B.benchSource(root, opts);
  if (src.missing) return viz.empty(root, src.id ? `No benchmark data for "${src.id}" yet. Load assets/data/bench-chNN.js or run code/bench_all.sh.` : "bench-dist: give data-bench=\"id\" or inline \"runs\".");
  let runs = src.runs.filter((r) => r && Array.isArray(r.samples) && r.samples.length >= 2);
  if (opts.langs) runs = runs.filter((r) => opts.langs.map((x) => x.toLowerCase()).includes(String(r.lang || "").toLowerCase()));
  if (opts.labels) runs = runs.filter((r) => opts.labels.includes(r.label));
  if (opts.n !== undefined) runs = runs.filter((r) => r.n === opts.n);
  const best = new Map();
  for (const r of runs) { const key = r.label + "\u0000" + (r.lang || ""); if (!best.has(key) || r.n > best.get(key).n) best.set(key, r); }
  const LORDER = ["rust", "zig", "odin"], lrank = (l) => { const i = LORDER.indexOf(String(l || "").toLowerCase()); return i < 0 ? 9 : i; };
  runs = [...best.values()].sort((a, b) => (opts.labels ? opts.labels.indexOf(a.label) - opts.labels.indexOf(b.label) : 0) || lrank(a.lang) - lrank(b.lang));
  if (!runs.length) return viz.empty(root, "bench-dist: no runs with at least two samples.");
  const rows = runs.map((r) => {
    const s = [...r.samples].sort((a, b) => a - b), mean = s.reduce((a, b) => a + b, 0) / s.length;
    const sd = Math.sqrt(s.reduce((a, b) => a + (b - mean) ** 2, 0) / (s.length - 1));
    const med = s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2;
    return { r, s, med, cv: sd / mean, min: s[0], max: s[s.length - 1] };
  });
  const meds = rows.map((x) => x.med);
  const counts = [...new Set(rows.map((x) => x.s.length))].sort((a, b) => a - b);
  const many = counts[counts.length - 1] > 12;
  let relative = opts.relative ?? Math.max(...meds) / Math.min(...meds) > 5;
  const chart = B.chart(root, render);
  root.append(h("div", { class: "controls" }, B.segmented(["absolute time", "% from median"], relative ? 1 : 0, (i) => { relative = i === 1; chart.redraw(); }, "X axis")),
    B.benchMeta(src, `each dot is one timed run (${counts.length > 1 ? counts[0] + "–" + counts[counts.length - 1] : counts[0]} per row) · tick = median · CV = stdev/mean`));

  function render(W) {
    const narrow = W < 560, labelW = narrow ? 0 : Math.min(200, W * 0.28), statsW = narrow ? 0 : 150;
    const rowH = narrow ? (many ? 60 : 46) : many ? 44 : 30;
    // dots for close samples stack vertically inside the row's own band (never into a neighbour or label)
    const r = many ? 2.4 : 3.4, stepY = many ? 3.5 : 5;
    const up = narrow ? 6 : rowH / 2 - 4 - r, down = narrow ? rowH - 26 - r : rowH / 2 - 4 - r;
    const slots = [0];
    for (let k = 1; k * stepY <= Math.max(up, down); k++) { if (k * stepY <= down) slots.push(k * stepY); if (k * stepY <= up) slots.push(-k * stepY); }
    const H = rows.length * rowH + 30, x0 = labelW + (narrow ? 4 : 10), x1 = W - statsW - 10;
    const val = (row, v) => (relative ? (100 * (v - row.med)) / row.med : v);
    const lo = Math.min(...rows.map((row) => val(row, row.min))), hi = Math.max(...rows.map((row) => val(row, row.max)));
    const pad = (hi - lo) * 0.06 || 1;
    const x = B.scaleLinear(relative ? Math.min(lo - pad, -pad) : Math.max(0, lo - pad), hi + pad, x0, x1);
    const C = B.colors();
    const svg = B.svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img",
      "aria-label": "Run-to-run spread: " + rows.map((row) => `${row.r.label} ${row.r.lang || ""} median ${B.fmtNs(row.med)}, min ${B.fmtNs(row.min)}, max ${B.fmtNs(row.max)}, CV ${(row.cv * 100).toFixed(1)}%`).join("; ") });
    const grid = B.svg("g", { class: "grid" }), axis = B.svg("g", { class: "axis" });
    const row = {}; // tick labels left to right; overlapping ones are skipped
    for (const t of x.ticks(narrow ? 4 : 6)) {
      grid.append(B.svg("line", { x1: x(t), x2: x(t), y1: 0, y2: H - 24 }));
      axis.append(...[B.tickText(x(t), W, H - 8, relative ? (t > 0 ? "+" : "") + +t.toFixed(1) + "%" : B.fmtNs(t, 2), row)].filter(Boolean));
    }
    svg.append(grid, axis);
    rows.forEach((row, i) => {
      const yc = i * rowH + (narrow ? 30 : rowH / 2 + 2), color = row.r.lang ? B.langColor(row.r.lang) : C.accent;
      const name = row.r.label + (row.r.lang ? " · " + row.r.lang : "");
      const stats = `${B.fmtNs(row.med)} · CV ${(row.cv * 100).toFixed(1)}%`;
      if (narrow) svg.append(B.svg("text", { x: 0, y: yc - 12 }, name + "  ", B.svg("tspan", { class: "dim mono" }, stats)));
      else {
        svg.append(B.svg("text", { x: labelW, y: yc + 4, "text-anchor": "end" }, name));
        svg.append(B.svg("text", { x: W - statsW, y: yc + 4, class: "mono", style: "font-size:11px" }, stats));
      }
      svg.append(B.svg("line", { x1: x(val(row, row.min)), x2: x(val(row, row.max)), y1: yc, y2: yc, stroke: color, "stroke-opacity": 0.5, "stroke-width": 2 }));
      // first free slot; when every slot near px is taken, overlap in the least crowded one
      const placed = [];
      for (const v of row.s) {
        const px = x(val(row, v));
        const crowd = (dy) => placed.filter((p) => p.dy === dy && Math.abs(p.x - px) < 2 * r + 1).length;
        let dy = slots.find((d) => crowd(d) === 0);
        if (dy === undefined) dy = slots.reduce((a, d) => (crowd(d) < crowd(a) ? d : a));
        placed.push({ x: px, dy });
        const c = B.svg("circle", { cx: px, cy: yc + dy, r, fill: color, "fill-opacity": many ? 0.6 : 0.85 });
        c.append(B.svg("title", {}, B.fmtNs(v)));
        svg.append(c);
      }
      svg.append(B.svg("line", { x1: x(val(row, row.med)), x2: x(val(row, row.med)), y1: yc - 9, y2: yc + 9, stroke: C.heading, "stroke-width": 2 }));
    });
    return svg;
  }
}));

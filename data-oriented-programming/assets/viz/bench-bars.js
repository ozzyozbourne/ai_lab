/* bench-bars — horizontal bar chart of benchmark medians, grouped by label, one bar per language.
 * Measured:  <div class="figure-body" data-viz="bench-bars" data-bench="ch04-particles" data-opts='{"metric":"ns/n"}'></div>
 * Cited:     <div class="figure-body" data-viz="bench-bars" data-opts='{"source":"cited: Muratori 2023","metric":"value","unit":"cycles/shape",
 *              "runs":[{"label":"virtual calls","value":35},{"label":"switch","value":24},{"label":"table","value":3.5}]}'></div>
 * Options:
 *   metric  "ns" (median per run) | "ns/n" (per element) | "value" (run.value, for cited numbers). Default: "value" if every run has one, else "ns".
 *   unit    unit text for metric "value" (e.g. "cycles"); per  text after "/" for ns/n (default "elem")
 *   n       only runs with this n (default: the largest n of each label+lang)
 *   labels  list: which labels to show, in this order (also disables sorting)
 *   langs   list: which languages to show (default all, ordered Rust, Zig, Odin)
 *   sort    "value" (fastest first, default) | "none" (data order)
 *   log     true | false initial scale (default: log when max/min > 20)
 *   ratio   true to print "×k" relative to the fastest bar (default true)
 *   higherIsBetter  true for throughput-style values (changes the note and the ratio base)
 *   source, machine, date, note   caption fields for inline runs */
(window.BookQ ||= []).push((B) => B.viz.register("bench-bars", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["metric", "unit", "per", "n", "labels", "langs", "sort", "log", "ratio", "higherIsBetter", "runs", "source", "machine", "date", "note", "compilers", "bench"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `bench-bars: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const src = B.benchSource(root, opts);
  if (src.missing) return viz.empty(root, src.id ? `No benchmark data for "${src.id}" yet. Load assets/data/bench-chNN.js or run code/bench_all.sh.` : "bench-bars: give data-bench=\"id\" or inline \"runs\".");
  let runs = src.runs.filter((r) => r && typeof r.label === "string");
  const metric = opts.metric || (runs.every((r) => typeof r.value === "number") ? "value" : "ns");
  viz.check(["ns", "ns/n", "value"].includes(metric), `bench-bars: "metric" must be "ns", "ns/n" or "value"`);
  if (opts.langs) runs = runs.filter((r) => opts.langs.map((x) => x.toLowerCase()).includes(String(r.lang || "").toLowerCase()));
  if (opts.labels) runs = runs.filter((r) => opts.labels.includes(r.label));
  if (opts.n !== undefined) runs = runs.filter((r) => r.n === opts.n);
  // largest n per (label, lang)
  const best = new Map();
  for (const r of runs) {
    const key = r.label + "\u0000" + (r.lang || "");
    if (!best.has(key) || (r.n || 0) > (best.get(key).n || 0)) best.set(key, r);
  }
  runs = [...best.values()].filter((r) => Number.isFinite(B.benchValue(r, metric)) && B.benchValue(r, metric) > 0);
  if (!runs.length) return viz.empty(root, `bench-bars: no runs match (metric ${metric}${opts.n !== undefined ? ", n " + opts.n : ""}).`);
  const LORDER = ["rust", "zig", "odin"];
  const lrank = (l) => { const i = LORDER.indexOf(String(l || "").toLowerCase()); return i < 0 ? 9 : i; };
  const hib = !!opts.higherIsBetter;
  const groups = [];
  for (const r of runs) { let g = groups.find((x) => x.label === r.label); if (!g) groups.push((g = { label: r.label, bars: [] })); g.bars.push(r); }
  groups.forEach((g) => g.bars.sort((a, b) => lrank(a.lang) - lrank(b.lang)));
  const val = (r) => B.benchValue(r, metric);
  if (opts.labels) groups.sort((a, b) => opts.labels.indexOf(a.label) - opts.labels.indexOf(b.label));
  else if ((opts.sort || "value") === "value") {
    const key = (g) => (hib ? -Math.max(...g.bars.map(val)) : Math.min(...g.bars.map(val)));
    groups.sort((a, b) => key(a) - key(b));
  }
  const vals = runs.map(val), vmin = Math.min(...vals), vmax = Math.max(...vals);
  const bestVal = hib ? vmax : vmin;
  let log = opts.log ?? vmax / vmin > 20;
  const fmt = (v) => metric === "value" ? (Math.abs(v) >= 100 ? B.fmtInt(v) : +v.toPrecision(3)) + (opts.unit ? " " + opts.unit : "")
    : B.fmtNs(v) + (metric === "ns/n" ? "/" + (opts.per || "elem") : "");
  const langs = [...new Set(runs.map((r) => r.lang).filter(Boolean))].sort((a, b) => lrank(a) - lrank(b));

  const chart = B.chart(root, render);
  const controls = h("div", { class: "controls" }, B.segmented(["linear", "log scale"], log ? 1 : 0, (i) => { log = i === 1; chart.redraw(); }, "Scale"));
  if (langs.length) {
    const lg = h("div", { class: "legend" });
    langs.forEach((l) => { const i = h("i"); i.style.background = B.langColor(l); lg.append(h("span", {}, i, l[0].toUpperCase() + l.slice(1))); });
    controls.append(lg);
  }
  const unitNote = (hib ? "higher is better" : "lower is better") + (metric === "ns" ? " · median of each run" : metric === "ns/n" ? " · median ÷ n" : "");
  root.append(controls, B.benchMeta(src, unitNote));

  function render(W) {
    // measured widths: group labels (600 12px body) on the left, value texts (11px mono) after the bars
    const C = B.colors();
    const longest = Math.max(...groups.map((g) => B.textWidth(g.label, "600 12px " + C.body)));
    const narrow = W < 520 || longest + 8 > W * 0.45; // too long to sit beside the bars: put labels above them
    const labelW = narrow ? 0 : Math.ceil(longest) + 2;
    const valueText = (v) => fmt(v) + (opts.ratio === false || v === bestVal ? "" : "  ×" + B.fmtRatio(hib ? bestVal / v : v / bestVal));
    const barH = 16, gapIn = 3, gapG = narrow ? 14 : 12;
    const valueW = Math.min(W * 0.5, 10 + Math.max(...runs.map((r) => B.textWidth(valueText(val(r)), "11px " + C.mono))));
    let y = 4;
    const layout = groups.map((g) => {
      const top = y + (narrow ? 16 : 0);
      const gh = g.bars.length * (barH + gapIn) - gapIn;
      y = top + gh + gapG;
      return { g, top, gh };
    });
    const H = y + 18, x0 = labelW + (narrow ? 0 : 8), x1 = W - valueW;
    const x = log ? B.scaleLog(Math.pow(10, Math.floor(Math.log10(vmin))), Math.pow(10, Math.ceil(Math.log10(vmax))), x0, x1)
      : B.scaleLinear(0, vmax * 1.02, x0, x1);
    const svg = B.svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img",
      "aria-label": "Bar chart: " + groups.map((g) => g.label + " " + g.bars.map((r) => (r.lang ? r.lang + " " : "") + fmt(val(r))).join(", ")).join("; ") });
    const grid = B.svg("g", { class: "grid" }), axis = B.svg("g", { class: "axis" });
    const ticks = x.ticks(narrow ? 3 : 5);
    const row = {}; // tick labels left to right; overlapping ones are skipped
    for (const t of ticks) {
      grid.append(B.svg("line", { x1: x(t), x2: x(t), y1: 0, y2: H - 16 }));
      axis.append(...[B.tickText(x(t), W, H - 3, metric === "value" ? String(+t.toPrecision(3)) : B.fmtNs(t, 2), row)].filter(Boolean));
    }
    svg.append(grid, axis);
    for (const { g, top } of layout) {
      if (narrow) svg.append(B.svg("text", { x: 0, y: top - 4, style: "font-weight:600" }, g.label));
      else svg.append(B.svg("text", { x: labelW, y: top + (g.bars.length * (barH + gapIn)) / 2 + 2, "text-anchor": "end", style: "font-weight:600" }, g.label));
      g.bars.forEach((r, i) => {
        const yy = top + i * (barH + gapIn), v = val(r);
        const bar = B.svg("rect", { x: x0, y: yy, width: Math.max(2, x(v) - x0), height: barH, rx: 3, fill: r.lang ? B.langColor(r.lang) : B.colors().accent });
        bar.append(B.svg("title", {}, `${g.label}${r.lang ? " · " + r.lang : ""}: ${fmt(v)}${r.n ? " (n = " + B.fmtInt(r.n) + ")" : ""}`));
        svg.append(bar);
        svg.append(B.svg("text", { x: x(v) + 5, y: yy + barH / 2 + 4, class: "mono", style: "font-size:11px" }, valueText(v)));
      });
    }
    return svg;
  }
}));

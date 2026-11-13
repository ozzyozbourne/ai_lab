/* bench-line — benchmark value against problem size on a log₂ x axis, with optional cache-level bands.
 * <div class="figure-body" data-viz="bench-line" data-bench="ch02-sweep"
 *      data-opts='{"metric":"ns/n","xScale":4,"xUnit":"bytes","xLabel":"working set","bands":true}'></div>
 * Options:
 *   metric  "ns/n" (default) | "ns" | "value"; unit (for "value"); per (text after "/", default "elem")
 *   xScale  multiply run.n by this to get x (e.g. bytes per element; default 1)
 *   xUnit   "bytes" (format as KiB/MiB) | "count" (default)
 *   xLabel  axis title (default "n")
 *   series  "lang" | "label": what one line is (default "lang" if several languages, else "label")
 *   labels, langs   filters (lists)
 *   logY    true for a log y axis (default false; a toggle is shown)
 *   bands   true = this orb's L1d 48 KiB / L2 1.25 MiB / L3 54 MiB, or a list [{"label":"L1d","bytes":49152}, ...]
 *           (band edges are in x units, so use xUnit "bytes" with them)
 *   runs + source/machine/date/note   inline data instead of data-bench
 * Tap or hover anywhere on the plot to read the values at the nearest x. */
(window.BookQ ||= []).push((B) => B.viz.register("bench-line", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["metric", "unit", "per", "xScale", "xUnit", "xLabel", "series", "labels", "langs", "logY", "bands", "runs", "source", "machine", "date", "note", "compilers", "bench"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `bench-line: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const src = B.benchSource(root, opts);
  if (src.missing) return viz.empty(root, src.id ? `No benchmark data for "${src.id}" yet. Load assets/data/bench-chNN.js or run code/bench_all.sh.` : "bench-line: give data-bench=\"id\" or inline \"runs\".");
  const metric = opts.metric || "ns/n";
  viz.check(["ns", "ns/n", "value"].includes(metric), `bench-line: "metric" must be "ns", "ns/n" or "value"`);
  const xScale = opts.xScale ?? 1;
  viz.check(xScale > 0, `bench-line: "xScale" must be positive`);
  let runs = src.runs.filter((r) => r && r.n > 0);
  if (opts.langs) runs = runs.filter((r) => opts.langs.map((x) => x.toLowerCase()).includes(String(r.lang || "").toLowerCase()));
  if (opts.labels) runs = runs.filter((r) => opts.labels.includes(r.label));
  runs = runs.filter((r) => Number.isFinite(B.benchValue(r, metric)) && B.benchValue(r, metric) > 0);
  if (runs.length < 2) return viz.empty(root, "bench-line: need at least two runs with n > 0.");
  const langs = [...new Set(runs.map((r) => r.lang).filter(Boolean))];
  const by = opts.series || (langs.length > 1 ? "lang" : "label");
  viz.check(by === "lang" || by === "label", `bench-line: "series" must be "lang" or "label"`);
  const C = B.colors();
  const PAL = [C.pos, C.vel, C.hp, C.flag, C.line, C.miss];
  const series = [];
  for (const r of runs) {
    const name = String(r[by] ?? "");
    let s = series.find((x) => x.name === name);
    if (!s) series.push((s = { name, pts: [], color: by === "lang" ? B.langColor(name) : PAL[series.length % PAL.length] }));
    s.pts.push({ x: r.n * xScale, y: B.benchValue(r, metric), r });
  }
  series.forEach((s) => s.pts.sort((a, b) => a.x - b.x));
  const bytes = opts.xUnit === "bytes";
  // counts: powers of two as 32K / 8M / 1G (binary), other large values as 30k / 2.5M (decimal); never "3e4"
  const fx = (v) => {
    if (bytes) return B.fmtBytes(v);
    if (v < 1e4) return String(+v.toPrecision(4));
    const pow2 = Number.isInteger(Math.log2(v));
    const [k, units] = pow2 ? [1024, ["K", "M", "G", "T"]] : [1000, ["k", "M", "G", "T"]];
    let i = -1, x = v;
    while (x >= k && i < units.length - 1) { x /= k; i++; }
    return String(+x.toPrecision(3)) + units[i];
  };
  const fy = (v) => metric === "value" ? +v.toPrecision(3) + (opts.unit ? " " + opts.unit : "") : B.fmtNs(v) + (metric === "ns/n" ? "/" + (opts.per || "elem") : "");
  const fyTick = (v) => (metric === "value" ? String(+v.toPrecision(3)) : B.fmtNs(v, 2));
  let bands = [];
  if (opts.bands === true) bands = [{ label: "L1d", bytes: 48 * 1024 }, { label: "L2", bytes: 1.25 * 1048576 }, { label: "L3", bytes: 54 * 1048576 }];
  else if (Array.isArray(opts.bands)) bands = opts.bands;
  for (const b of bands) viz.check(b && typeof b.label === "string" && b.bytes > 0, `bench-line: each band needs "label" and positive "bytes"`);
  let logY = !!opts.logY;
  let sel = null;

  const all = series.flatMap((s) => s.pts);
  const xmin = Math.min(...all.map((p) => p.x)), xmax = Math.max(...all.map((p) => p.x));
  const ymin = Math.min(...all.map((p) => p.y)), ymax = Math.max(...all.map((p) => p.y));
  const readout = h("p", { class: "readout", "aria-live": "polite" }, "Tap or hover on the plot to read values.");
  const chart = B.chart(root, render);
  const lg = h("div", { class: "legend" });
  series.forEach((s) => { const i = h("i"); i.style.background = s.color; lg.append(h("span", {}, i, s.name)); });
  root.append(readout, h("div", { class: "controls" }, B.segmented(["linear y", "log y"], logY ? 1 : 0, (i) => { logY = i === 1; chart.redraw(); }, "Y scale"), lg),
    B.benchMeta(src, "lower is better" + (bands.length ? " · bands: this orb's cache sizes" : "")));

  function render(W) {
    const narrow = W < 520, H = narrow ? 260 : 320;
    const m = { l: narrow ? 52 : 64, r: 12, t: bands.length ? 22 : 10, b: 40 };
    const lx0 = Math.pow(2, Math.floor(Math.log2(xmin))), lx1 = Math.pow(2, Math.ceil(Math.log2(xmax)));
    const x = B.scaleLog(lx0, lx1, m.l, W - m.r, 2);
    const y = logY ? B.scaleLog(Math.pow(10, Math.floor(Math.log10(ymin))), Math.pow(10, Math.ceil(Math.log10(ymax))), H - m.b, m.t)
      : B.scaleLinear(0, ymax * 1.08, H - m.b, m.t);
    const svg = B.svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img",
      "aria-label": "Line chart: " + series.map((s) => s.name + ": " + s.pts.map((p) => fx(p.x) + " " + fy(p.y)).join(", ")).join("; ") });
    // bands
    const edges = [lx0, ...bands.map((b) => b.bytes).filter((b) => b > lx0 && b < lx1), lx1];
    // a region is named after the smallest cache level that holds its right edge (else it is DRAM)
    const sorted = [...bands].sort((a, b) => a.bytes - b.bytes);
    const names = edges.slice(1).map((e) => (sorted.find((b) => b.bytes >= e) || { label: "DRAM" }).label);
    if (bands.length) {
      const g = B.svg("g", { class: "band" });
      for (let i = 0; i + 1 < edges.length; i++) {
        const a = x(edges[i]), b = x(edges[i + 1]);
        g.append(B.svg("rect", { x: a, y: m.t, width: b - a, height: H - m.b - m.t, fill: i % 2 ? "rgba(124,196,255,.05)" : "rgba(124,196,255,.11)" }));
        if (b - a > 26) g.append(B.svg("text", { x: (a + b) / 2, y: m.t - 7, "text-anchor": "middle" }, names[i]));
        if (i > 0) g.append(B.svg("line", { x1: a, x2: a, y1: m.t, y2: H - m.b, stroke: C.line, "stroke-opacity": 0.5, "stroke-dasharray": "4 3" }));
      }
      svg.append(g);
    }
    const grid = B.svg("g", { class: "grid" }), axis = B.svg("g", { class: "axis" });
    const xt = x.ticks(), step = Math.ceil(xt.length / (narrow ? 4 : 8));
    // thin to every step-th tick, but always label the last one (the largest size is usually the point of the
    // chart); if it would collide with the previous label, drop that one instead
    const shown = xt.map((_, i) => i % step === 0);
    const last = xt.length - 1;
    if (last > 0 && !shown[last]) {
      shown[last] = true;
      const p = shown.lastIndexOf(true, last - 1);
      const gap = ((fx(xt[p]).length + fx(xt[last]).length) * 6.4) / 2 + 8;
      if (p >= 0 && x(xt[last]) - x(xt[p]) < gap) shown[p] = false;
    }
    xt.forEach((t, i) => {
      if (i % step && i !== last) return;
      grid.append(B.svg("line", { x1: x(t), x2: x(t), y1: m.t, y2: H - m.b }));
      // the first label must not slide left under the y-axis labels: start it at the plot's left edge at most
      const half = (fx(t).length * 6.4) / 2 + 1;
      if (shown[i]) axis.append(B.tickText(Math.max(x(t), m.l - 4 + half), W, H - m.b + 15, fx(t)));
    });
    for (const t of y.ticks(5)) {
      grid.append(B.svg("line", { x1: m.l, x2: W - m.r, y1: y(t), y2: y(t) }));
      axis.append(B.svg("text", { x: m.l - 6, y: y(t) + 4, "text-anchor": "end" }, fyTick(t)));
    }
    axis.append(B.svg("text", { x: (m.l + W - m.r) / 2, y: H - 6, "text-anchor": "middle" }, (opts.xLabel || "n") + " (log scale)"));
    axis.append(B.svg("line", { x1: m.l, x2: W - m.r, y1: H - m.b, y2: H - m.b }));
    svg.append(grid, axis);
    for (const s of series) {
      svg.append(B.svg("polyline", { points: s.pts.map((p) => x(p.x) + "," + y(p.y)).join(" "), fill: "none", stroke: s.color, "stroke-width": 2, "stroke-linejoin": "round" }));
      for (const p of s.pts) svg.append(B.svg("circle", { cx: x(p.x), cy: y(p.y), r: sel === p.x ? 4.5 : 3, fill: s.color, class: "pt" + (sel === p.x ? " sel" : "") }));
    }
    if (sel != null) svg.append(B.svg("line", { x1: x(sel), x2: x(sel), y1: m.t, y2: H - m.b, stroke: C.heading, "stroke-opacity": 0.4 }));
    const pick = (ev) => {
      const r = svg.getBoundingClientRect(), px = ((ev.clientX - r.left) / r.width) * W;
      let bestX = null, d = Infinity;
      for (const p of all) { const dd = Math.abs(x(p.x) - px); if (dd < d) { d = dd; bestX = p.x; } }
      if (bestX !== sel) { sel = bestX; select(); chart.redraw(); }
    };
    svg.addEventListener("pointermove", pick);
    svg.addEventListener("pointerdown", pick);
    return svg;
  }
  function select() {
    const at = series.map((s) => { const p = s.pts.find((q) => q.x === sel); return p ? `${s.name} ${fy(p.y)}` : null; }).filter(Boolean);
    readout.textContent = `${opts.xLabel || "n"} = ${fx(sel)}: ${at.join(" · ")}`;
  }
}));

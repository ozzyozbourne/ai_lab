/* ch07-sweep — measured branchy vs branchless filter time against the fraction kept (0..100%, a linear
 * axis, which bench-line's log2 x axis cannot show because it starts at 0).
 * <div class="figure-body" data-viz="ch07-sweep" data-bench="ch07-predict"></div>
 * Reads runs labelled "branchy P%" and "branchless P%" (P = 0, 10, ..., 100) from Book.data[data-bench].
 * Options: lang  initial language (default "rust"). A toggle switches language; tap the plot to read values. */
(window.BookQ ||= []).push((B) => B.viz.register("ch07-sweep", (root, opts) => {
  const { h, viz } = B;
  for (const k of Object.keys(opts)) viz.check(k === "lang", `ch07-sweep: unknown option "${k}" (known: lang)`);
  const src = B.benchSource(root, {});
  if (src.missing) return viz.empty(root, `No benchmark data for "${src.id}" yet. Load assets/data/bench-ch07.js.`);
  const parse = (r) => { const m = /^(branchy|branchless) (\d+)%$/.exec(r.label); return m ? { kind: m[1], p: +m[2], y: r.ns / r.n, lang: String(r.lang) } : null; };
  const pts = src.runs.map(parse).filter(Boolean);
  const langs = ["rust", "zig", "odin"].filter((l) => pts.some((p) => p.lang === l));
  viz.check(langs.length > 0, "ch07-sweep: no runs labelled \"branchy P%\" / \"branchless P%\"");
  let lang = Math.max(0, langs.indexOf(opts.lang || "rust")), sel = null;
  const C = B.colors();
  const COL = { branchy: C.miss, branchless: C.hit };
  const ymax = Math.max(...pts.map((p) => p.y)) * 1.08;
  const readout = h("p", { class: "readout", "aria-live": "polite" }, "Tap or hover on the plot to read values.");
  const chart = B.chart(root, render);
  const lg = h("div", { class: "legend" });
  for (const k of ["branchy", "branchless"]) { const i = h("i"); i.style.background = COL[k]; lg.append(h("span", {}, i, k)); }
  root.append(readout, h("div", { class: "controls" },
    B.segmented(langs.map((l) => l[0].toUpperCase() + l.slice(1)), lang, (i) => { lang = i; select(); chart.redraw(); }, "Language"), lg),
    B.benchMeta({ rec: src.rec, runs: pts.map((p) => ({ lang: p.lang })) }, "lower is better · one point per keep fraction"));

  function series(kind) { return pts.filter((p) => p.kind === kind && p.lang === langs[lang]).sort((a, b) => a.p - b.p); }
  function render(W) {
    const narrow = W < 520, H = narrow ? 250 : 300, m = { l: narrow ? 50 : 60, r: 12, t: 10, b: 40 };
    const x = B.scaleLinear(0, 100, m.l, W - m.r), y = B.scaleLinear(0, ymax, H - m.b, m.t);
    const svg = B.svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img",
      "aria-label": "Line chart, " + langs[lang] + ": " + ["branchy", "branchless"].map((k) => k + " " + series(k).map((p) => `${p.p}% ${p.y.toFixed(2)} ns`).join(", ")).join("; ") });
    const grid = B.svg("g", { class: "grid" }), axis = B.svg("g", { class: "axis" });
    for (const t of [0, 25, 50, 75, 100]) {
      grid.append(B.svg("line", { x1: x(t), x2: x(t), y1: m.t, y2: H - m.b }));
      axis.append(B.svg("text", { x: x(t), y: H - m.b + 15, "text-anchor": "middle" }, t + "%"));
    }
    for (const t of y.ticks(5)) {
      grid.append(B.svg("line", { x1: m.l, x2: W - m.r, y1: y(t), y2: y(t) }));
      axis.append(B.svg("text", { x: m.l - 6, y: y(t) + 4, "text-anchor": "end" }, B.fmtNs(t, 2)));
    }
    axis.append(B.svg("text", { x: (m.l + W - m.r) / 2, y: H - 6, "text-anchor": "middle" }, "fraction of elements kept (branch taken)"));
    axis.append(B.svg("line", { x1: m.l, x2: W - m.r, y1: H - m.b, y2: H - m.b }));
    svg.append(grid, axis);
    for (const k of ["branchy", "branchless"]) {
      const s = series(k);
      svg.append(B.svg("polyline", { points: s.map((p) => x(p.p) + "," + y(p.y)).join(" "), fill: "none", stroke: COL[k], "stroke-width": 2, "stroke-linejoin": "round" }));
      for (const p of s) svg.append(B.svg("circle", { cx: x(p.p), cy: y(p.y), r: sel === p.p ? 4.5 : 3, fill: COL[k], class: "pt" }));
    }
    if (sel != null) svg.append(B.svg("line", { x1: x(sel), x2: x(sel), y1: m.t, y2: H - m.b, stroke: C.heading, "stroke-opacity": 0.4 }));
    const pick = (ev) => {
      const r = svg.getBoundingClientRect(), px = ((ev.clientX - r.left) / r.width) * W;
      const p = Math.max(0, Math.min(100, Math.round((((px - m.l) / (W - m.r - m.l)) * 100) / 10) * 10));
      if (p !== sel) { sel = p; select(); chart.redraw(); }
    };
    svg.addEventListener("pointermove", pick);
    svg.addEventListener("pointerdown", pick);
    return svg;
  }
  function select() {
    if (sel == null) return;
    const at = ["branchy", "branchless"].map((k) => { const p = series(k).find((q) => q.p === sel); return p ? `${k} ${p.y.toFixed(2)} ns/elem` : null; }).filter(Boolean);
    readout.textContent = `${langs[lang]}, keep ${sel}%: ${at.join(" · ")}`;
  }
}));

/* latency-ladder — how long common operations take, on a log scale, with a human-scale view (1 ns → 1 s).
 * <div class="figure-body" data-viz="latency-ladder" data-opts='{"set":"2026","human":false}'></div>
 * Options:
 *   set     "classic" | "2026" | "orb" (initial preset, default "2026")
 *   human   true to start in "if 1 ns were 1 s" mode (default false)
 *   rows    custom rows [{"label","ns","note"}] (replaces the presets; adds no toggle)
 *   source  caption text for custom rows (or for rows read from bench data)
 * Rows from measured data instead (data-bench="id" on the element, or opts.bench):
 *   <div class="figure-body" data-viz="latency-ladder" data-bench="ch02-sweep" data-opts='{"lang":"rust","metric":"ns/n"}'></div>
 *   lang    which language's runs (default "rust")
 *   metric  "ns/n" (default) | "ns" | "value" (see Book.benchValue)
 *   labels  list: which run labels to show, in this order (default: every label, largest n of each)
 *   n       only runs with this n
 *   A row is {label: run.label, ns: metric value, note: run.note}. Missing data shows the grey "no data yet" box.
 *   For rows that need arithmetic across runs, compute them in a BookQ callback and write opts.rows (see ch02-ladder.js).
 * Preset values come from research/01-foundations-hardware.md §3.1 (classic table popularised by Jeff Dean /
 * Norvig, Google SRE handout and Bohsali 2026) and from a random pointer chase run on this orb (ch00 smoke). */
(window.BookQ ||= []).push((B) => B.viz.register("latency-ladder", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["set", "human", "rows", "source", "bench", "lang", "metric", "labels", "n"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `latency-ladder: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const SETS = {
    classic: { label: "~2012 classic", source: "Classic \"numbers every programmer should know\" (Norvig / Jeff Dean, jboner gist ~2012).", rows: [
      { label: "L1 cache reference", ns: 0.5 }, { label: "Branch mispredict", ns: 5 }, { label: "L2 cache reference", ns: 7 },
      { label: "Mutex lock/unlock", ns: 25 }, { label: "Main memory reference", ns: 100 },
      { label: "Read 1 MB sequentially from memory", ns: 250000 }] },
    "2026": { label: "2026", source: "Bohsali 2026 / Google SRE handout; 1 MB read at ~50 GB/s single-core (Chips and Cheese, Zen 4/5).", rows: [
      { label: "L1 cache reference", ns: 1 }, { label: "Branch mispredict", ns: 3 }, { label: "L2 cache reference", ns: 3 },
      { label: "L3 cache reference", ns: 15 }, { label: "Mutex lock/unlock", ns: 20 }, { label: "Main memory reference (DDR5)", ns: 80 },
      { label: "Read 1 MB sequentially from memory", ns: 20000, note: "≈50 GB/s" }] },
    orb: { label: "this orb (measured)", source: "Dependent random loads (Sattolo cycle, 4 KiB pages) on this orb's Xeon @ 2.6 GHz (Ice Lake-SP, KVM), Rust 1.100, taskset -c 2. DRAM figure includes TLB misses.", rows: [
      { label: "L1 hit (16 KiB working set)", ns: 1.51 }, { label: "L2 hit (256 KiB)", ns: 4.78 },
      { label: "L3 hit (2 MiB)", ns: 15.9 }, { label: "DRAM + TLB miss (32 MiB)", ns: 124 }] },
  };
  let setKey = opts.set ?? "2026";
  let rowsCustom = null;
  const benchId = !opts.rows && (root.dataset.bench || opts.bench);
  if (benchId) {
    const rec = B.bench(benchId);
    if (!rec) return viz.empty(root, `No benchmark data for "${benchId}" yet. Load assets/data/bench-chNN.js or run code/bench_all.sh.`);
    const lang = String(opts.lang || "rust").toLowerCase(), metric = opts.metric || "ns/n";
    viz.check(["ns", "ns/n", "value"].includes(metric), `latency-ladder: "metric" must be "ns", "ns/n" or "value"`);
    let rs = rec.runs.filter((r) => String(r.lang || "").toLowerCase() === lang && (opts.n === undefined || r.n === opts.n));
    const labels = opts.labels || [...new Set(rs.map((r) => r.label))];
    viz.check(Array.isArray(labels), `latency-ladder: "labels" must be a list`);
    rs = labels.map((l) => rs.filter((r) => r.label === l).sort((a, b) => b.n - a.n)[0]).filter(Boolean);
    const rows = rs.map((r) => ({ label: r.label, ns: B.benchValue(r, metric), note: r.note })).filter((r) => r.ns > 0);
    if (!rows.length) return viz.empty(root, `latency-ladder: no ${lang} runs in "${benchId}" match.`);
    rowsCustom = { label: "measured", rows,
      source: opts.source || [rec.source || "measured", rec.machine, rec.date, `${benchId}, ${lang}`].filter(Boolean).join(" · ") };
  } else if (opts.rows) {
    viz.check(Array.isArray(opts.rows) && opts.rows.length, `latency-ladder: "rows" must be a non-empty array`);
    for (const r of opts.rows) viz.check(r && typeof r.label === "string" && r.ns > 0, `latency-ladder: each row needs "label" and a positive "ns"`);
    rowsCustom = { label: "custom", source: opts.source || "", rows: opts.rows };
  } else {
    viz.check(setKey in SETS, `latency-ladder: "set" must be one of ${Object.keys(SETS).join(", ")}`);
  }
  let human = !!opts.human;
  const cur = () => rowsCustom || SETS[setKey];

  function humanTime(ns) { // 1 ns → 1 s
    const s = ns;
    if (s < 60) return (s < 10 ? +s.toFixed(1) : Math.round(s)) + " s";
    if (s < 3600) return +(s / 60).toFixed(1) + " min";
    if (s < 86400) return +(s / 3600).toFixed(1) + " h";
    if (s < 86400 * 365) return +(s / 86400).toFixed(1) + " days";
    return +(s / (86400 * 365)).toFixed(1) + " years";
  }
  const C = B.colors();
  const chart = B.chart(root, render);
  const note = h("p", { class: "chart-meta" });
  const controls = h("div", { class: "controls" });
  if (!rowsCustom) {
    const keys = Object.keys(SETS);
    controls.append(B.segmented(keys.map((k) => SETS[k].label), keys.indexOf(setKey), (i) => { setKey = keys[i]; update(); }, "Data set"));
  }
  controls.append(B.segmented(["real time", "if 1 ns were 1 s"], human ? 1 : 0, (i) => { human = i === 1; update(); }, "Time scale"));
  root.append(controls, note);

  function render(W) {
    const rows = cur().rows, narrow = W < 560;
    const vtext = (r) => (human ? humanTime(r.ns) : B.fmtNs(r.ns) + (r.note ? "  " + r.note : ""));
    const valueW = Math.min(W * 0.45, 12 + 7.2 * Math.max(...rows.map((r) => vtext(r).length)));
    const labelW = narrow ? 0 : Math.min(250, W * 0.36), barH = 18, rowH = narrow ? 44 : 30, top = 6;
    const H = top + rows.length * rowH + 26;
    const x0 = labelW + 4, x1 = W - valueW;
    const all = Object.values(SETS).flatMap((s) => s.rows).concat(rowsCustom ? rowsCustom.rows : []);
    const lo = Math.pow(10, Math.floor(Math.log10(Math.min(...all.map((r) => r.ns))))), hi = Math.pow(10, Math.ceil(Math.log10(Math.max(...all.map((r) => r.ns)))));
    const x = B.scaleLog(lo, hi, x0, x1);
    const svg = B.svg("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img",
      "aria-label": "Latency ladder, log scale: " + rows.map((r) => `${r.label} ${B.fmtNs(r.ns)}`).join("; ") });
    const g = B.svg("g", { class: "grid" });
    for (const t of x.ticks()) g.append(B.svg("line", { x1: x(t), x2: x(t), y1: top - 2, y2: H - 22 }));
    svg.append(g);
    const ax = B.svg("g", { class: "axis" });
    const row = {}; // tick labels left to right; overlapping ones are skipped
    for (const t of x.ticks()) {
      if (narrow && Math.log10(t) % 2 !== 0 && x.ticks().length > 6) continue;
      ax.append(...[B.tickText(x(t), W, H - 6, human ? humanTime(t) : B.fmtNs(t, 1), row)].filter(Boolean));
    }
    svg.append(ax);
    rows.forEach((r, i) => {
      const y = top + i * rowH + (narrow ? 18 : (rowH - barH) / 2);
      const t = Math.min(1, Math.log10(r.ns / lo) / Math.log10(hi / lo));
      const fill = t < 0.25 ? C.hit : t < 0.45 ? C.flag : t < 0.6 ? C.pos : C.miss;
      if (narrow) svg.append(B.svg("text", { x: x0, y: y - 5 }, r.label));
      else svg.append(B.svg("text", { x: labelW, y: y + barH / 2 + 4, "text-anchor": "end" }, r.label));
      svg.append(B.svg("rect", { x: x0, y, width: Math.max(2, x(r.ns) - x0), height: barH, rx: 3, fill }));
      svg.append(B.svg("text", { x: x(r.ns) + 6, y: y + barH / 2 + 4, class: "mono" }, vtext(r)));
    });
    return svg;
  }
  function update() {
    note.textContent = (human ? "Scaled so that 1 ns lasts 1 second. " : "Log scale: each grid line is 10× slower. ") + cur().source;
    chart.redraw();
  }
  update();
}));

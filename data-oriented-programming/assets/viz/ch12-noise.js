/* ch12-noise — how often does a noisy comparison pick the wrong winner?
 * <div class="figure-body" data-viz="ch12-noise" data-opts='{"effect":5,"cv":5,"runs":7}'></div>
 * Options:
 *   effect  true speed-up of B over A, in percent, 0.5..20 (default 5)
 *   cv      run-to-run noise as a coefficient of variation, in percent, 0.5..30 (default 5)
 *   runs    timed runs per side, odd 1..51 (default 7)
 *   spikes  true to start with VM spikes on (default false)
 *   trials  Monte Carlo trials per estimate, 200..5000 (default 2000)
 *   seed    integer seed (default 12)
 * Model: A takes 100 µs, B takes 100·(1 − effect) µs. Each timed run multiplies the true time by a lognormal
 * factor with the chosen CV (σ = sqrt(ln(1 + cv²))). With spikes on, 5% of runs are also stretched by a factor
 * drawn uniformly from 1.2..3 (an interrupt, a neighbour, a migration). The top panel shows one experiment:
 * every run of A and B, the true times (dashed), and each side's median (tick) and mean (ring). The bottom panel
 * estimates, over `trials` seeded experiments, how often three verdicts call A the winner, which is wrong:
 * one run each, the mean of the runs, and the median of the runs. All numbers come from this model. */
(window.BookQ ||= []).push((B) => B.viz.register("ch12-noise", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["effect", "cv", "runs", "spikes", "trials", "seed"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch12-noise: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  let effect = opts.effect ?? 5, cv = opts.cv ?? 5, runs = opts.runs ?? 7, spikes = !!opts.spikes;
  const trials = opts.trials ?? 2000, seed = opts.seed ?? 12;
  viz.check(typeof effect === "number" && effect >= 0.5 && effect <= 20, 'ch12-noise: "effect" must be 0.5..20 (percent)');
  viz.check(typeof cv === "number" && cv >= 0.5 && cv <= 30, 'ch12-noise: "cv" must be 0.5..30 (percent)');
  viz.check(Number.isInteger(runs) && runs >= 1 && runs <= 51 && runs % 2 === 1, 'ch12-noise: "runs" must be an odd integer 1..51');
  viz.check(Number.isInteger(trials) && trials >= 200 && trials <= 5000, 'ch12-noise: "trials" must be an integer 200..5000');
  viz.check(Number.isInteger(seed), 'ch12-noise: "seed" must be an integer');

  const TA = 100, SPIKE_P = 0.05;
  let shown = 0; // which sample experiment is drawn (Resample increments it)

  // ---- the model ----
  const gauss = (r) => { // Box–Muller from a seeded uniform source
    let u = 0; while (u === 0) u = r();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * r());
  };
  const sigma = () => Math.sqrt(Math.log(1 + (cv / 100) ** 2));
  const sample = (r, truth, s) => {
    let t = truth * Math.exp(s * gauss(r) - (s * s) / 2); // mean-preserving lognormal
    if (spikes && r() < SPIKE_P) t *= 1.2 + 1.8 * r();
    return t;
  };
  const median = (xs) => { const s = [...xs].sort((a, b) => a - b); return s[(s.length - 1) >> 1]; };
  const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
  const experiment = (r) => {
    const s = sigma(), tb = TA * (1 - effect / 100);
    const a = [], b = [];
    for (let i = 0; i < runs; i++) { a.push(sample(r, TA, s)); b.push(sample(r, tb, s)); }
    return { a, b };
  };
  function estimate() {
    const r = B.rng(seed * 7919 + 1);
    let single = 0, mn = 0, md = 0;
    for (let t = 0; t < trials; t++) {
      const { a, b } = experiment(r);
      if (a[0] <= b[0]) single++;
      if (mean(a) <= mean(b)) mn++;
      if (median(a) <= median(b)) md++;
    }
    return { single: single / trials, mean: mn / trials, median: md / trials };
  }
  // runs needed for the median to be wrong < 5% of the time (normal approximation, no spikes):
  // the median of k lognormal runs has log-sd ≈ 1.2533·σ/√k; wrong when the difference of two such medians
  // exceeds Δ = −ln(1 − effect), so k ≈ (1.645·√2·1.2533·σ / Δ)².
  const needed = () => {
    const d = -Math.log(1 - effect / 100), k = Math.ceil((1.645 * Math.SQRT2 * 1.2533 * sigma() / d) ** 2);
    return k % 2 ? k : k + 1;
  };

  // ---- view ----
  const C = B.colors();
  const canvas = h("canvas", { role: "img" });
  const k = B.canvas(canvas, 640, 260);
  const cnt = B.counters([["single", "one run each: wrong", "bad"], ["mean", `mean of ${runs}: wrong`, "bad"], ["median", `median of ${runs}: wrong`, "bad"], ["need", "runs for < 5% wrong (median, no spikes)"]]);
  const readout = h("p", { class: "readout" });
  const fmtPct = (v) => (v * 100).toFixed(v < 0.1 ? 1 : 0) + "%";
  const sEffect = B.slider({ label: "true effect", min: 0.5, max: 20, step: 0.5, value: effect, format: (v) => `B ${v}% faster`, oninput: (v) => { effect = v; update(); } });
  const sCv = B.slider({ label: "noise (CV)", min: 0.5, max: 30, step: 0.5, value: cv, format: (v) => v + "%", oninput: (v) => { cv = v; update(); } });
  const sRuns = B.slider({ label: "runs per side", min: 1, max: 51, step: 2, value: runs, format: String, oninput: (v) => { runs = v; update(); } });
  const seg = B.segmented(["no spikes", "VM spikes (5% of runs)"], spikes ? 1 : 0, (i) => { spikes = i === 1; update(); }, "Outliers");
  const resample = h("button", { type: "button", onclick: () => { shown++; draw(); } }, "New experiment");
  root.append(canvas, cnt.el, readout, h("div", { class: "controls" }, sEffect, sCv, sRuns, seg, resample),
    h("p", { class: "viz-note" }, `Model, not a measurement: lognormal run-to-run noise around a true time; ${trials} seeded experiments per estimate. B really is faster, so every "A wins" verdict is wrong.`));

  let est = null;
  function update() {
    est = estimate();
    const lab = (key, text) => { const o = cnt.outs[key]; if (o && o.parentElement) o.parentElement.firstChild.textContent = text + " "; };
    lab("mean", `mean of ${runs}: wrong`); lab("median", `median of ${runs}: wrong`);
    cnt.set("single", fmtPct(est.single)); cnt.set("mean", fmtPct(est.mean)); cnt.set("median", fmtPct(est.median));
    cnt.set("need", needed() > 999 ? "> 999" : needed());
    draw();
  }

  function draw() {
    const W = k.width, ctx = k.ctx, narrow = W < 520;
    const Hh = narrow ? 300 : 250;
    if (Math.abs(k.height - Hh) > 0.5) k.fit(W, Hh);
    ctx.clearRect(0, 0, W, Hh);
    const r = B.rng(seed + 1000 * (shown + 1));
    const ex = experiment(r), all = [...ex.a, ...ex.b];
    const tb = TA * (1 - effect / 100);
    const lo = Math.min(tb * 0.9, ...all), hi = Math.max(TA * 1.1, ...all);
    const labelW = narrow ? 0 : 54, x0 = labelW + 8, x1 = W - 10;
    const X = B.scaleLinear(lo - (hi - lo) * 0.03, hi + (hi - lo) * 0.03, x0, x1);
    ctx.font = "11px " + C.mono; ctx.textBaseline = "middle";
    // axis
    const axisY = narrow ? 128 : 112;
    ctx.strokeStyle = C.border; ctx.fillStyle = C.dim; ctx.lineWidth = 1;
    for (const t of X.ticks(narrow ? 4 : 7)) {
      ctx.beginPath(); ctx.moveTo(X(t) + 0.5, 8); ctx.lineTo(X(t) + 0.5, axisY - 6); ctx.stroke();
      ctx.textAlign = "center"; ctx.fillText(+t.toFixed(1) + " µs", X(t), axisY + 4);
    }
    const rowsY = narrow ? [34, 84] : [32, 76];
    const sides = [["A", ex.a, TA, C.pos], ["B", ex.b, tb, C.vel]];
    sides.forEach(([name, xs, truth, color], i) => {
      const y = rowsY[i];
      ctx.textAlign = "left"; ctx.fillStyle = color; ctx.font = "600 12px " + C.body;
      if (narrow) ctx.fillText(`${name}  (true ${truth.toFixed(1)} µs)`, x0, y - 20);
      else { ctx.fillText(name, 6, y - 6); ctx.font = "10px " + C.mono; ctx.fillStyle = C.dim; ctx.fillText(truth.toFixed(1) + " µs", 6, y + 8); }
      ctx.font = "11px " + C.mono;
      // true time
      ctx.setLineDash([4, 3]); ctx.strokeStyle = color; ctx.beginPath(); ctx.moveTo(X(truth), y - 16); ctx.lineTo(X(truth), y + 16); ctx.stroke(); ctx.setLineDash([]);
      // runs (stacked when close)
      const placed = [];
      xs.forEach((v, j) => {
        const px = X(v); let dy = 0;
        while (placed.some((p) => Math.abs(p.x - px) < 6 && p.dy === dy)) dy = dy <= 0 ? -dy + 6 : -dy;
        placed.push({ x: px, dy });
        ctx.fillStyle = color; ctx.globalAlpha = j === 0 ? 1 : 0.6;
        ctx.beginPath(); ctx.arc(px, y + Math.max(-14, Math.min(14, dy)), j === 0 ? 4.5 : 3.2, 0, 2 * Math.PI); ctx.fill(); ctx.globalAlpha = 1;
      });
      // median tick + mean ring
      ctx.strokeStyle = C.heading; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(X(median(xs)), y - 12); ctx.lineTo(X(median(xs)), y + 12); ctx.stroke();
      ctx.lineWidth = 1.5; ctx.beginPath(); ctx.arc(X(mean(xs)), y, 7, 0, 2 * Math.PI); ctx.stroke(); ctx.lineWidth = 1;
    });
    // bottom: wrong-winner rates
    const barTop = axisY + 26, barH = narrow ? 34 : 30, bx0 = narrow ? 8 : 150, bx1 = W - 60;
    const rows = [["one run each", est.single], [`mean of ${runs}`, est.mean], [`median of ${runs}`, est.median]];
    rows.forEach(([name, v], i) => {
      const y = barTop + i * barH;
      ctx.textAlign = "left"; ctx.fillStyle = C.text; ctx.font = "12px " + C.body;
      if (narrow) ctx.fillText(name, bx0, y + 6); else ctx.fillText(name, 8, y + 12);
      const by = narrow ? y + 14 : y + 4, bh = narrow ? 12 : 16;
      ctx.fillStyle = C.elev2; ctx.fillRect(bx0, by, bx1 - bx0, bh);
      ctx.fillStyle = C.miss; ctx.fillRect(bx0, by, (bx1 - bx0) * Math.min(1, v / 0.5), bh);
      ctx.fillStyle = C.heading; ctx.font = "11px " + C.mono; ctx.fillText(fmtPct(v), bx1 + 6, by + bh / 2);
    });
    ctx.fillStyle = C.dim; ctx.font = "10px " + C.mono; ctx.textAlign = "right";
    ctx.fillText("bar scale: 0 → 50% (a coin flip)", bx1, barTop + 3 * barH + (narrow ? 10 : 4));
    // this experiment's verdicts
    const v = (a, b) => (a <= b ? "A (wrong)" : "B (right)");
    readout.textContent = `This experiment: one run says ${v(ex.a[0], ex.b[0])}, mean says ${v(mean(ex.a), mean(ex.b))}, median says ${v(median(ex.a), median(ex.b))}. Big dots = the first run of each side; tick = median; ring = mean; dashed = true time.`;
    canvas.setAttribute("aria-label", `Simulated runs of A and B with B truly ${effect}% faster and ${cv}% noise; over ${trials} experiments a single run picks the wrong winner ${fmtPct(est.single)} of the time, the mean of ${runs} ${fmtPct(est.mean)}, the median of ${runs} ${fmtPct(est.median)}.`);
  }

  update();
  B.onResize(root, (w) => { k.fit(Math.max(260, w - 32), w < 520 ? 300 : 250); draw(); });
}));

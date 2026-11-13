/* ch08-simd-lanes — "sum of the positive values" over 16 small integers, done two ways:
 *   scalar: one element per step, a data-dependent branch per element
 *   lanes:  8 elements per step; a compare makes a lane mask, select keeps x or 0, eight accumulators, then one reduce
 * <div class="figure-body" data-viz="ch08-simd-lanes" data-opts='{}'></div>
 * Options:
 *   mode      "scalar" | "lanes" (default "lanes")
 *   seed      data seed (default 8)
 *   interval  seconds per step while playing (default 0.7)
 * Model: everything on screen is replayed from step 0. "Mispredicts" uses the simplest predictor there is
 * (guess the same outcome as last time), so it counts outcome changes; real predictors do better on patterns
 * and no better on random signs. Integers keep the sums exact, so both modes end on the same total. */
(window.BookQ ||= []).push((B) => B.viz.register("ch08-simd-lanes", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["mode", "seed", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch08-simd-lanes: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const MODES = ["scalar", "lanes"];
  let mode = MODES.indexOf(opts.mode ?? "lanes");
  viz.check(mode >= 0, 'ch08-simd-lanes: "mode" must be "scalar" or "lanes"');
  let seed = opts.seed ?? 8;
  viz.check(Number.isInteger(seed), 'ch08-simd-lanes: "seed" must be an integer');
  const N = 16, W = 8;
  let data = [], k = 0;
  const gen = () => { const r = B.rng(seed); data = Array.from({ length: N }, () => { const v = Math.floor(r() * 19) - 9; return v === 0 ? 1 : v; }); };
  gen();
  // lanes: 0 start · 1 cmp v0 · 2 select+add v0 · 3 cmp v1 · 4 select+add v1 · 5 reduce
  const last = () => (mode === 0 ? N : 2 * (N / W) + 1);

  function model(steps) {
    const st = { done: 0, branches: 0, mispred: 0, wasted: 0, ops: 0, acc: 0, lanes: new Array(W).fill(0), mask: null, vec: -1, phase: "", total: null, cur: -1, taken: null };
    if (mode === 0) {
      let prev = null;
      for (let i = 0; i < steps; i++) {
        const t = data[i] > 0;
        st.branches++; st.ops += t ? 3 : 2; // compare, branch, (add)
        if (prev !== null && t !== prev) st.mispred++;
        prev = t;
        if (t) st.acc += data[i];
        st.done = i + 1; st.cur = i; st.taken = t;
      }
      if (steps === N) st.total = st.acc;
    } else {
      for (let s = 1; s <= steps; s++) {
        if (s <= 2 * (N / W)) {
          const v = Math.floor((s - 1) / 2), xs = data.slice(v * W, v * W + W);
          st.vec = v; st.mask = xs.map((x) => x > 0);
          if (s % 2 === 1) { st.phase = "cmp"; st.ops++; }
          else {
            st.phase = "add"; st.ops += 2; st.done = (v + 1) * W;
            st.mask.forEach((m, j) => { if (m) st.lanes[j] += xs[j]; else st.wasted++; });
          }
        } else { st.phase = "reduce"; st.ops += 3; st.total = st.lanes.reduce((a, b) => a + b, 0); st.vec = -1; st.mask = null; }
      }
    }
    return st;
  }

  const C = B.colors();
  const chart = B.chart(root, render);
  const say = h("output", { class: "ch08-say", "aria-live": "polite" }, "–");
  const cnt = B.counters([["done", "elements"], ["ops", "instructions (model)"], ["br", "data branches"], ["mp", "mispredicts", "bad"], ["waste", "lanes adding 0"], ["sum", "sum", "good"]]);

  function render(w) {
    const st = model(k), narrow = w < 600, pad = 6;
    const cw = narrow ? (w - 2 * pad) / W : Math.min(56, (w - 2 * pad - 120) / W), ch = narrow ? 30 : 34;
    const x0 = narrow ? pad : 120, T = (x, y, s, o = {}) => B.svg("text", Object.assign({ x, y, fill: C.text, "font-family": C.mono, "font-size": narrow ? 11 : 13, "text-anchor": "middle" }, o), s);
    const label = (y, s) => (narrow ? T(pad, y - 4, s, { "text-anchor": "start", fill: C.dim, "font-size": 10 }) : T(x0 - 10, y + ch / 2 + 4, s, { "text-anchor": "end", fill: C.dim, "font-size": 12 }));
    const rowGap = narrow ? 20 : 12;
    const rows = mode === 0 ? 4 : 6;
    const H = rows * (ch + rowGap) + (narrow ? 16 : 6);
    const svg = B.svg("svg", { viewBox: `0 0 ${w} ${H}`, width: w, height: H, role: "img",
      "aria-label": mode === 0 ? `Scalar loop, ${st.done} of ${N} elements, sum so far ${st.acc}` : `8-lane loop, ${st.done} of ${N} elements, lane sums ${st.lanes.join(" ")}` });
    let y = narrow ? 14 : 6;
    // the input, as two 8-wide rows (= two vector registers' worth)
    for (let r = 0; r < N / W; r++) {
      svg.append(label(y, `x[${r * W}..${r * W + W})`));
      for (let j = 0; j < W; j++) {
        const i = r * W + j, v = data[i];
        const active = mode === 0 ? i === st.cur : r === st.vec;
        const done = i < st.done;
        svg.append(B.svg("rect", { x: x0 + j * cw + 1, y, width: cw - 2, height: ch, rx: 4,
          fill: active ? C.elev2 : "none", stroke: active ? C.accent : done ? C.border : C.dim, "stroke-width": active ? 2.5 : 1, opacity: done && !active ? 0.55 : 1 }));
        svg.append(T(x0 + j * cw + cw / 2, y + ch / 2 + 5, String(v), { fill: v > 0 ? C.hit : C.miss, "font-weight": 700 }));
      }
      y += ch + rowGap;
    }
    if (mode === 0) {
      svg.append(label(y, "branch"));
      const txt = st.cur < 0 ? "press Step" : `x[${st.cur}] = ${data[st.cur]} > 0 ? ${st.taken ? "yes → add" : "no → skip"}`;
      svg.append(T(x0 + 4, y + ch / 2 + 5, txt, { "text-anchor": "start", fill: st.cur < 0 ? C.dim : st.taken ? C.hit : C.miss }));
      y += ch + rowGap;
      svg.append(label(y, "accumulator"));
      svg.append(B.svg("rect", { x: x0 + 1, y, width: cw * 2 - 2, height: ch, rx: 4, fill: C.elev2, stroke: C.pos, "stroke-width": 2 }));
      svg.append(T(x0 + cw, y + ch / 2 + 5, String(st.acc), { fill: C.heading, "font-weight": 700 }));
      svg.append(T(x0 + cw * 2 + 8, y + ch / 2 + 5, "one add at a time, each waits for the last", { "text-anchor": "start", fill: C.dim, "font-size": narrow ? 10 : 12 }));
    } else {
      const xs = st.vec >= 0 ? data.slice(st.vec * W, st.vec * W + W) : null;
      svg.append(label(y, "mask x > 0"));
      for (let j = 0; j < W; j++) {
        const m = st.mask ? st.mask[j] : null;
        svg.append(B.svg("rect", { x: x0 + j * cw + 1, y, width: cw - 2, height: ch, rx: 4, fill: m === null ? "none" : m ? C.hit : C.elev2, opacity: m ? 0.85 : 1, stroke: C.border }));
        svg.append(T(x0 + j * cw + cw / 2, y + ch / 2 + 5, m === null ? "·" : m ? "1…1" : "0", { fill: m ? C.bg : C.dim, "font-size": narrow ? 10 : 12 }));
      }
      y += ch + rowGap;
      svg.append(label(y, "select(m, x, 0)"));
      for (let j = 0; j < W; j++) {
        const show = st.phase === "add" && xs;
        const v = show ? (st.mask[j] ? xs[j] : 0) : null;
        svg.append(B.svg("rect", { x: x0 + j * cw + 1, y, width: cw - 2, height: ch, rx: 4, fill: "none", stroke: C.border, "stroke-dasharray": v === 0 ? "4 3" : null }));
        svg.append(T(x0 + j * cw + cw / 2, y + ch / 2 + 5, v === null ? "·" : String(v), { fill: v === 0 ? C.dim : C.text }));
      }
      y += ch + rowGap;
      svg.append(label(y, "8 accumulators"));
      for (let j = 0; j < W; j++) {
        svg.append(B.svg("rect", { x: x0 + j * cw + 1, y, width: cw - 2, height: ch, rx: 4, fill: C.elev2, stroke: C.pos, "stroke-width": 2 }));
        svg.append(T(x0 + j * cw + cw / 2, y + ch / 2 + 5, String(st.lanes[j]), { fill: C.heading, "font-weight": 700 }));
      }
      y += ch + rowGap;
      svg.append(label(y, "reduce"));
      svg.append(T(x0 + 4, y + ch / 2 + 5, st.total === null ? "after the loop: add the 8 lanes once" : `${st.lanes.join(" + ")} = ${st.total}`,
        { "text-anchor": "start", fill: st.total === null ? C.dim : C.hit, "font-size": narrow ? 10 : 13 }));
    }
    return svg;
  }

  function draw() {
    const st = model(k);
    chart.redraw();
    cnt.set("done", `${st.done}/${N}`); cnt.set("ops", st.ops); cnt.set("br", st.branches); cnt.set("mp", st.mispred);
    cnt.set("waste", mode === 0 ? "–" : st.wasted); cnt.set("sum", st.total === null ? (mode === 0 ? st.acc + "…" : "…") : st.total);
    say.textContent = mode === 0
      ? (k === 0 ? "Scalar: one element per step, and a branch whose direction depends on the data." : k === N ? `Done in ${N} steps with ${st.branches} data-dependent branches. A last-outcome predictor would miss ${st.mispred} of them.` : `Step ${k}: element ${st.cur} ${st.taken ? "is positive, so the add runs" : "is not positive, so the branch skips the add"}.`)
      : (k === 0 ? "Lanes: 8 elements per step. No branch; the compare produces a mask instead." : st.phase === "cmp" ? `Compare all 8 lanes of vector ${st.vec} at once: the mask is all ones where x > 0.` : st.phase === "add" ? `Select keeps x where the mask is set and 0 elsewhere, then one vector add updates all 8 accumulators (${st.wasted} lanes so far added a useless 0).` : `One horizontal reduce at the end. Same sum as the scalar loop, ${last()} steps instead of ${N}, and no data branch to mispredict.`);
  }

  const player = B.player(root, {
    step: () => (k < last() ? (k++, true) : false), back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; }, atEnd: () => k === last(), draw, interval: opts.interval ?? 0.7,
  });
  const seg = B.segmented(["Scalar + branch", "8 lanes + mask"], mode, (i) => { mode = i; k = Math.min(k, last()); if (B.reducedMotion()) k = last(); draw(); }, "Execution");
  const shuffle = h("button", { type: "button", onclick: () => { seed++; gen(); if (B.reducedMotion()) k = last(); draw(); } }, "New data");
  root.append(say, cnt.el, h("div", { class: "controls" }, player.el, seg, shuffle));
  draw();
}));

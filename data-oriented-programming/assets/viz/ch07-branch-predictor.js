/* ch07-branch-predictor — a 2-bit saturating counter (or one counter per 2-bit global history) stepping
 * through the branch `if (x < 50)` over sorted, random and periodic input.
 * <div class="figure-body" data-viz="ch07-branch-predictor" data-opts='{}'></div>
 * Options:
 *   n          values 8..48 (default 32)
 *   seed       PRNG seed (default 7)
 *   penalty    mispredict cost in cycles (default 15)
 *   base       cycles per element when predicted (default 1)
 *   branchless cycles per element for the branchless version (default 2)
 *   interval   seconds per step while playing (default 0.35)
 * Model: state is a replay of the first k outcomes. Counter states 0 strongly not-taken, 1 weakly not-taken,
 * 2 weakly taken, 3 strongly taken; predict taken when state >= 2; +1 on taken, -1 on not-taken, saturating.
 * "History" mode keeps four such counters, picked by the outcomes of the previous two branches (a tiny
 * gshare without the hash). Every counter on screen is computed by the replay. */
(window.BookQ ||= []).push((B) => B.viz.register("ch07-branch-predictor", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["n", "seed", "penalty", "base", "branchless", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch07-branch-predictor: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const N = opts.n ?? 32;
  viz.check(Number.isInteger(N) && N >= 8 && N <= 48, 'ch07-branch-predictor: "n" must be an integer 8..48');
  const PEN = opts.penalty ?? 15, BASE = opts.base ?? 1, FLAT = opts.branchless ?? 2;
  viz.check([PEN, BASE, FLAT].every((v) => typeof v === "number" && v >= 0), "ch07-branch-predictor: penalty/base/branchless must be numbers >= 0");
  const T = 50;
  const MODES = ["sorted", "random", "alternating"];
  const STATE = ["strong not", "weak not", "weak taken", "strong taken"];

  function makeValues(mode) {
    const r = B.rng(opts.seed ?? 7);
    if (mode === 2) return Array.from({ length: N }, (_, i) => (i % 2 === 0 ? r.int(50) : 50 + r.int(50)));
    const v = Array.from({ length: N }, () => r.int(100));
    return mode === 0 ? v.sort((a, b) => a - b) : v;
  }
  let mode = 1, hist = false, k = 0, values = makeValues(mode);

  // ---- the model: replay the first k branches ----
  function replay(upto) {
    const ctr = hist ? [1, 1, 1, 1] : [1];
    let h2 = 0, miss = 0;
    const marks = [];
    let lastIdx = 0;
    for (let i = 0; i < upto; i++) {
      const taken = values[i] < T;
      const idx = hist ? h2 : 0;
      const pred = ctr[idx] >= 2;
      const ok = pred === taken;
      if (!ok) miss++;
      marks.push({ pred, ok, idx });
      ctr[idx] = Math.max(0, Math.min(3, ctr[idx] + (taken ? 1 : -1)));
      h2 = ((h2 << 1) | (taken ? 1 : 0)) & 3;
      lastIdx = idx;
    }
    return { ctr, h2, miss, marks, lastIdx };
  }

  const C = B.colors();
  const note = h("p", { class: "ch07-result", "aria-live": "polite" }, "–");
  const cnt = B.counters([["step", "branch"], ["miss", "mispredicts", "bad"], ["rate", "rate"], ["cyc", "branchy ≈"], ["flat", "branchless ≈", "good"]]);
  const chart = B.chart(root, render);

  function render(w) {
    const st = replay(k), narrow = w < 600;
    const perRow = narrow ? Math.ceil(N / 2) : N, rows = Math.ceil(N / perRow), pad = 6;
    const cw = (w - 2 * pad) / perRow, ch = 26, rowH = ch + 22;
    const stripH = rows * rowH + 18;
    const nCtr = hist ? 4 : 1, ctrRowH = 30, ctrTop = stripH + 22;
    const H = ctrTop + nCtr * ctrRowH + 8;
    const svg = B.svg("svg", { viewBox: `0 0 ${w} ${H}`, width: w, height: H, role: "img",
      "aria-label": `${MODES[mode]} input, ${k} of ${N} branches, ${st.miss} mispredicts` });
    const txt = (x, y, s, o = {}) => B.svg("text", Object.assign({ x, y, fill: C.text, "font-family": C.mono, "font-size": 11 }, o), s);
    svg.append(txt(pad, 11, "x < 50 ?  (filled = taken)    ✓/✗ = prediction", { fill: C.dim }));
    for (let i = 0; i < N; i++) {
      const r = Math.floor(i / perRow), c = i % perRow, x = pad + c * cw, y = 18 + r * rowH;
      const taken = values[i] < T, cur = i === k - 1;
      svg.append(B.svg("rect", { x: x + 1, y, width: cw - 2, height: ch, rx: 3, fill: taken ? C.pos : "none",
        "fill-opacity": taken ? 0.85 : 1, stroke: cur ? C.heading : taken ? C.pos : C.border, "stroke-width": cur ? 2.5 : 1 }));
      svg.append(txt(x + cw / 2, y + 17, String(values[i]), { "text-anchor": "middle", fill: taken ? "#06121f" : C.dim, "font-size": cw < 22 ? 9 : 11 }));
      const m = st.marks[i];
      if (m) svg.append(txt(x + cw / 2, y + ch + 14, m.ok ? "✓" : "✗", { "text-anchor": "middle", fill: m.ok ? C.hit : C.miss, "font-size": 13, "font-weight": 700 }));
    }
    // counter state(s)
    svg.append(txt(pad, ctrTop - 6, hist ? "one 2-bit counter per history (last two outcomes, N = not, T = taken)" : "one 2-bit saturating counter", { fill: C.dim }));
    const lab = narrow ? 34 : 44, bw = (w - 2 * pad - lab) / 4;
    for (let j = 0; j < nCtr; j++) {
      const y = ctrTop + j * ctrRowH;
      const hl = hist ? ["NN", "NT", "TN", "TT"][j] : "";
      if (hist) svg.append(txt(pad, y + 17, hl, { fill: st.h2 === j && k < N ? C.heading : C.dim, "font-weight": st.h2 === j ? 700 : 400 }));
      for (let s = 0; s < 4; s++) {
        const x = pad + (hist ? lab : 0) + s * (hist ? bw : (w - 2 * pad) / 4), bww = hist ? bw : (w - 2 * pad) / 4;
        const on = st.ctr[j] === s;
        svg.append(B.svg("rect", { x: x + 2, y, width: bww - 4, height: ctrRowH - 6, rx: 4, fill: on ? (s >= 2 ? C.pos : C.vel) : C.elev2,
          stroke: on ? C.heading : C.border, "stroke-width": on ? 2 : 1 }));
        svg.append(txt(x + bww / 2, y + 16, narrow ? ["SN", "WN", "WT", "ST"][s] : STATE[s], { "text-anchor": "middle", fill: on ? "#06121f" : C.dim, "font-weight": on ? 700 : 400 }));
      }
    }
    return svg;
  }

  function draw() {
    const st = replay(k);
    chart.redraw();
    const cyc = k * BASE + st.miss * PEN;
    cnt.set("step", `${k}/${N}`);
    cnt.set("miss", st.miss);
    cnt.set("rate", k ? Math.round((100 * st.miss) / k) + "%" : "–");
    cnt.set("cyc", B.fmtInt(cyc) + " cycles");
    cnt.set("flat", B.fmtInt(k * FLAT) + " cycles");
    if (k === 0) note.textContent = `Press Step or Play. Each value runs the branch "x < 50"; the counter starts at weak not-taken.`;
    else {
      const m = st.marks[k - 1], x = values[k - 1], taken = x < T;
      note.textContent = `x = ${x}: ${taken ? "taken" : "not taken"}; predicted ${m.pred ? "taken" : "not taken"} → ${m.ok ? "hit" : `mispredict, +${PEN} cycles`}.` +
        (k === N ? ` Total ${B.fmtInt(cyc)} vs ${B.fmtInt(N * FLAT)} cycles branchless (model: ${BASE} cycle/element predicted, ${PEN} per mispredict, ${FLAT} flat).` : "");
    }
    note.dataset.kind = k && !st.marks[k - 1].ok ? "bad" : "";
  }

  const player = B.player(root, {
    step: () => (k < N ? (k++, true) : false), back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; }, atEnd: () => k === N, draw, interval: opts.interval ?? 0.35, autoplay: false,
  });
  const seg = B.segmented(MODES, mode, (i) => { mode = i; values = makeValues(mode); k = 0; player.pause(); draw(); }, "Input order");
  const seg2 = B.segmented(["one counter", "counter per history"], 0, (i) => { hist = i === 1; k = 0; player.pause(); draw(); }, "Predictor");
  root.append(note, cnt.el, h("div", { class: "controls" }, player.el, seg, seg2));
  draw();
}));

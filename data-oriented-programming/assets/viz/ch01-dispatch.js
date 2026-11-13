/* ch01-dispatch — what the CPU does per shape: a vtable call, a switch, a table lookup, or per-kind arrays.
 * <div class="figure-body" data-viz="ch01-dispatch" data-opts='{"shapes":12}'></div>
 * Options:
 *   shapes    8..24 shapes (default 12)
 *   seed      integer seed for the random kind order (default 3)
 *   mode      0 vtable · 1 switch · 2 table · 3 per-kind arrays (default 0)
 *   sorted    start with the shapes sorted by kind (default false)
 *   penalty   initial mispredict penalty in cycles, 10..25 (default 16)
 *   heapGap   bytes between consecutive heap objects, 8|16|32 (default 32, what glibc malloc gave on this orb)
 *   interval  seconds per step while playing (default 0.6)
 * Model (all numbers below come from it, nothing is measured live):
 *   - Branch prediction: the vtable call and the switch jump are predicted with a "last target" predictor (it guesses the
 *     kind it saw last time). Real predictors use history, but on random kinds they cannot do much better. Table and
 *     per-kind loops have no data-dependent branch.
 *   - Cycles per shape = base + mispredicts × penalty. Base costs when every branch is predicted are round numbers that
 *     roughly match the sorted, in-cache runs on this orb: vtable 4, switch 3, table 2, per-kind 0.5 (vectorized).
 *   - Memory: byte-exact layouts. vtable: 16 B handle + a heap object (4 or 8 B) every heapGap bytes + an 8 B fn pointer
 *     from one of four vtables. switch/table: 12 B per element (tag padded to 4 + two f32). per-kind: 4 or 8 B.
 *     Lines are 64 B; "lines touched" counts distinct lines. Output stores (4 B per shape, the same everywhere) are left out. */
(window.BookQ ||= []).push((B) => B.viz.register("ch01-dispatch", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["shapes", "seed", "mode", "sorted", "penalty", "heapGap", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch01-dispatch: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const N = opts.shapes ?? 12;
  viz.check(Number.isInteger(N) && N >= 8 && N <= 24, 'ch01-dispatch: "shapes" must be an integer 8..24');
  let mode = opts.mode ?? 0;
  viz.check([0, 1, 2, 3].includes(mode), 'ch01-dispatch: "mode" must be 0, 1, 2 or 3');
  let penalty = opts.penalty ?? 16;
  viz.check(Number.isInteger(penalty) && penalty >= 10 && penalty <= 25, 'ch01-dispatch: "penalty" must be an integer 10..25');
  const GAP = opts.heapGap ?? 32;
  viz.check([8, 16, 32].includes(GAP), 'ch01-dispatch: "heapGap" must be 8, 16 or 32');
  let sorted = !!opts.sorted;

  const KINDS = ["Square", "Rectangle", "Triangle", "Circle"];
  const OBJ = [4, 8, 8, 4]; // bytes of the heap object / per-kind element
  const BASE = [4, 3, 2, 0.5];
  const MODES = ["vtable", "switch", "table", "per-kind arrays"];
  const rnd = B.rng(opts.seed ?? 3);
  const randomKinds = Array.from({ length: N }, () => rnd.int(4));
  const C = B.colors();
  const KC = [C.pos, C.vel, C.hp, C.flag];

  let kinds = [], order = [], k = 0;
  function build() {
    kinds = sorted ? [...randomKinds].sort((a, b) => a - b) : [...randomKinds];
    // processing order: input order, except per-kind arrays walk all squares, then all rectangles, ...
    order = mode === 3 ? [0, 1, 2, 3].flatMap((t) => kinds.map((x, i) => (x === t ? i : -1)).filter((i) => i >= 0)) : kinds.map((_, i) => i);
  }

  // per-kind array positions (byte offsets inside each kind's array)
  const kindPos = () => {
    const off = [0, 0, 0, 0], pos = [];
    kinds.forEach((t, i) => { pos[i] = off[t]; off[t] += OBJ[t]; });
    return { pos, len: off };
  };

  /** Everything the counters show after `steps` shapes. */
  function stats(steps) {
    const lines = new Set();
    let bytes = 0, miss = 0, cycles = 0, last = -1;
    const marks = [];
    const kp = kindPos();
    for (let s = 0; s < steps; s++) {
      const i = order[s], t = kinds[i];
      let mp = false;
      if (mode <= 1) { mp = last >= 0 && last !== t; if (last < 0) mp = true; last = t; } // first call: cold predictor
      marks[i] = mp;
      if (mp) miss++;
      cycles += BASE[mode] + (mp ? penalty : 0);
      if (mode === 0) {
        lines.add("h" + Math.floor((i * 16) / 64)); lines.add("o" + Math.floor((i * GAP) / 64)); lines.add("v" + t);
        bytes += 16 + OBJ[t] + 8;
      } else if (mode <= 2) {
        lines.add("a" + Math.floor((i * 12) / 64)); bytes += 12;
        if (mode === 2) { lines.add("coef"); bytes += 4; }
      } else {
        lines.add("k" + t + ":" + Math.floor(kp.pos[i] / 64)); bytes += OBJ[t];
      }
    }
    return { lines: lines.size, bytes, miss, cycles, marks };
  }

  const canvas = h("canvas", { role: "img" });
  const k2 = B.canvas(canvas, 640, 300);
  const cnt = B.counters([["n", "shapes"], ["miss", "mispredicts", "bad"], ["cyc", "cycles/shape (model)"], ["bytes", "bytes read/shape"], ["lines", "lines touched"]]);
  const readout = h("p", { class: "readout", "aria-live": "off" });
  const player = B.player(root, {
    step: () => (k < N ? (k++, true) : false),
    back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; },
    atEnd: () => k === N,
    draw: () => draw(),
    interval: opts.interval ?? 0.6,
  });
  const modeSeg = B.segmented(MODES, mode, (j) => { mode = j; build(); k = Math.min(k, N); draw(); }, "Dispatch");
  const orderSeg = B.segmented(["random order", "sorted by kind"], sorted ? 1 : 0, (j) => { sorted = j === 1; build(); draw(); }, "Order of the shapes");
  const pen = B.slider({ label: "mispredict penalty", min: 10, max: 25, step: 1, value: penalty, format: (v) => v + " cycles", oninput: (v) => { penalty = v; draw(); } });
  const legend = h("div", { class: "legend" });
  KINDS.forEach((name, t) => { const i = h("i"); i.style.background = KC[t]; legend.append(h("span", {}, i, name)); });
  [["predicted", C.hit], ["mispredicted", C.miss], ["64 B cache line", C.line]].forEach(([t, c]) => { const i = h("i"); i.style.background = c; legend.append(h("span", {}, i, t)); });
  root.append(h("div", { class: "controls" }, modeSeg, orderSeg), canvas, cnt.el, readout,
    h("div", { class: "controls" }, player.el, pen), legend,
    h("p", { class: "viz-note" }, `Toy model, not a measurement: cycles/shape = base (vtable 4, switch 3, table 2, per-kind 0.5) + mispredicts × penalty. ` +
      `The predictor guesses "same kind as last time". Memory is drawn to scale: one pixel width per byte in every row. Heap objects are ${GAP} B apart, as glibc malloc placed them on this orb.`));

  // ---------- drawing ----------
  function glyph(ctx, t, x, y, s, fill) {
    ctx.fillStyle = fill; ctx.beginPath();
    if (t === 0) ctx.rect(x - s * 0.36, y - s * 0.36, s * 0.72, s * 0.72);
    else if (t === 1) ctx.rect(x - s * 0.45, y - s * 0.26, s * 0.9, s * 0.52);
    else if (t === 2) { ctx.moveTo(x - s * 0.42, y + s * 0.34); ctx.lineTo(x + s * 0.42, y + s * 0.34); ctx.lineTo(x, y - s * 0.38); ctx.closePath(); }
    else ctx.arc(x, y, s * 0.38, 0, Math.PI * 2);
    ctx.fill();
  }
  function label(ctx, text, x, y, color, align, bg) {
    ctx.font = "11px " + C.mono; ctx.textAlign = align || "left"; ctx.textBaseline = "alphabetic";
    if (bg) {
      const w = ctx.measureText(text).width, x0 = align === "center" ? x - w / 2 : x;
      ctx.fillStyle = C.elev; ctx.fillRect(x0 - 2, y - 10, w + 4, 14);
    }
    ctx.fillStyle = color || C.dim; ctx.fillText(text, x, y); ctx.textAlign = "left";
  }
  function arrow(ctx, x1, y1, x2, y2, color) {
    ctx.strokeStyle = color; ctx.fillStyle = color; ctx.lineWidth = 1.75;
    ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
    const a = Math.atan2(y2 - y1, x2 - x1);
    ctx.beginPath(); ctx.moveTo(x2, y2); ctx.lineTo(x2 - 7 * Math.cos(a - 0.4), y2 - 7 * Math.sin(a - 0.4)); ctx.lineTo(x2 - 7 * Math.cos(a + 0.4), y2 - 7 * Math.sin(a + 0.4)); ctx.closePath(); ctx.fill();
  }
  /** A memory row drawn to scale: `cells` = [{off, size, color, cur}], line boundaries every 64 B. */
  function memRow(ctx, x0, y, s, total, cells, touched, rowH) {
    for (let l = 0; l * 64 < total; l++) {
      const lx = x0 + l * 64 * s, lw = Math.min(64, total - l * 64) * s;
      ctx.fillStyle = touched(l) ? "rgba(124,196,255,.16)" : "transparent"; ctx.fillRect(lx, y - 3, lw, rowH + 6);
      ctx.strokeStyle = touched(l) ? C.line : C.border; ctx.lineWidth = touched(l) ? 1.5 : 1; ctx.strokeRect(lx + 0.5, y - 3, lw - 1, rowH + 6);
    }
    for (const c of cells) {
      ctx.fillStyle = c.color; ctx.globalAlpha = c.done ? 1 : 0.55;
      ctx.fillRect(x0 + c.off * s + 0.5, y, Math.max(1, c.size * s - 1), rowH); ctx.globalAlpha = 1;
      if (c.cur) { ctx.strokeStyle = C.heading; ctx.lineWidth = 2; ctx.strokeRect(x0 + c.off * s - 1, y - 1, c.size * s + 1, rowH + 2); }
    }
  }

  function draw() {
    const W = k2.width, ctx = k2.ctx, narrow = W < 560;
    const X0 = 8, usable = W - 16;
    const st = stats(k), cur = k > 0 ? order[k - 1] : -1;
    const s = usable / (N * Math.max(GAP, 16)); // px per byte, the same in every row
    const cw = usable / N, sy = 34, rowH = 14;
    // height per mode
    const H = mode === 0 ? 232 : mode === 3 ? 226 : 192;
    if (Math.abs(k2.height - H) > 0.5) k2.fit(W, H);
    ctx.clearRect(0, 0, W, H);

    // shape stream (input order) + prediction marks
    label(ctx, mode === 3 ? (narrow ? "the shapes (stored by kind below)" : "the shapes (stored by kind below, so no tag is needed)") : "the shapes, in the order they are stored", X0, 12);
    kinds.forEach((t, i) => {
      const done = mode === 3 ? order.indexOf(i) < k : i < k;
      ctx.globalAlpha = done || i === cur ? 1 : 0.4;
      glyph(ctx, t, X0 + cw * (i + 0.5), sy, Math.min(cw, 26), KC[t]);
      ctx.globalAlpha = 1;
      if (i === cur) { ctx.strokeStyle = C.heading; ctx.lineWidth = 2; ctx.strokeRect(X0 + cw * i + 1, sy - 13, cw - 2, 26); }
      if (mode <= 1 && done) {
        ctx.font = "700 14px " + C.mono; ctx.fillStyle = st.marks[i] ? C.miss : C.hit; ctx.textAlign = "center";
        ctx.fillText(st.marks[i] ? "✗" : "✓", X0 + cw * (i + 0.5), sy + 30); ctx.textAlign = "left";
      }
    });
    if (mode >= 2) label(ctx, narrow ? "no branch: nothing to predict" : "no data-dependent branch: nothing to predict", X0, sy + 28, C.hit);

    const y1 = 86;
    if (mode === 0) {
      const y2 = y1 + 52, y3 = y2 + 56, bw = Math.min(150, (usable - 18) / 4);
      if (cur >= 0) {
        const hx = X0 + (cur * 16 + 4) * s, ox = X0 + (cur * GAP + OBJ[kinds[cur]] / 2) * s, vx = X0 + kinds[cur] * (bw + 6) + bw / 2;
        arrow(ctx, hx, y1 + rowH + 3, ox, y2 - 4, C.flag);
        arrow(ctx, X0 + (cur * 16 + 12) * s, y1 + rowH + 3, vx, y3 - 2, st.marks[cur] ? C.miss : C.hit);
      }
      label(ctx, narrow ? "handles: 16 B (data ptr + vtable ptr)" : "Vec<Box<dyn Shape>>: 16 B handles (data pointer + vtable pointer)", X0, y1 - 8);
      memRow(ctx, X0, y1, s, N * 16, kinds.flatMap((t, i) => [
        { off: i * 16, size: 8, color: KC[t], done: i < k, cur: i === cur },
        { off: i * 16 + 8, size: 8, color: C.dim, done: i < k, cur: false }]),
      (l) => [...Array(Math.min(k, N)).keys()].some((i) => Math.floor((i * 16) / 64) === l), rowH);
      label(ctx, narrow ? `heap: one object per shape, ${GAP} B apart` : `heap: one allocation per shape, ${GAP} B apart`, X0, y2 - 8, null, null, true);
      memRow(ctx, X0, y2, s, N * GAP, kinds.map((t, i) => ({ off: i * GAP, size: OBJ[t], color: KC[t], done: i < k, cur: i === cur })),
        (l) => [...Array(Math.min(k, N)).keys()].some((i) => Math.floor((i * GAP) / 64) === l), rowH);
      label(ctx, narrow ? "four vtables; the call jumps into one" : "four vtables (one per type); the call jumps to the area fn found there", X0, y3 - 10, null, null, true);
      KINDS.forEach((name, t) => {
        const bx = X0 + t * (bw + 6);
        const on = cur >= 0 && kinds[cur] === t, bad = on && st.marks[cur];
        ctx.fillStyle = on ? KC[t] : C.elev2; ctx.fillRect(bx, y3, bw, 28);
        ctx.strokeStyle = bad ? C.miss : on ? C.heading : C.border; ctx.lineWidth = bad ? 3 : 1; ctx.strokeRect(bx + 0.5, y3 + 0.5, bw - 1, 27);
        label(ctx, (narrow ? name.slice(0, 4) : name) + "::area", bx + bw / 2, y3 + 18, on ? "#06121f" : C.text, "center");
      });
    } else if (mode <= 2) {
      const y3 = y1 + 62, bw = Math.min(150, (usable - 18) / 4);
      if (cur >= 0) arrow(ctx, X0 + (cur * 12 + 2) * s, y1 + rowH + 3, X0 + kinds[cur] * (bw + 6) + bw / 2, y3 - 2, mode === 1 && st.marks[cur] ? C.miss : C.hit);
      label(ctx, narrow ? "12 B per shape: tag + width + height" : "Vec<ShapeEnum> / []FlatShape: 12 B per shape (tag padded to 4 B + two f32)", X0, y1 - 8);
      memRow(ctx, X0, y1, s, N * 12, kinds.flatMap((t, i) => [
        { off: i * 12, size: 4, color: C.dim, done: i < k, cur: false },
        { off: i * 12 + 4, size: 8, color: KC[t], done: i < k, cur: i === cur }]),
      (l) => [...Array(Math.min(k, N)).keys()].some((i) => Math.floor((i * 12) / 64) === l), rowH);
      label(ctx, narrow ? `${N * 12} B = ${Math.ceil((N * 12) / 64)} lines (vtable: ${Math.ceil((N * 16) / 64) + Math.ceil((N * GAP) / 64)})` : `the whole array is ${N * 12} B: ${Math.ceil((N * 12) / 64)} lines, vs ${Math.ceil((N * 16) / 64) + Math.ceil((N * GAP) / 64)} for handles + heap`, X0, y1 + rowH + 18, C.dim, null, true);
      label(ctx, mode === 1 ? (narrow ? "switch on the tag: a jump to predict" : "match / switch on the tag: a jump the CPU must predict") : (narrow ? "COEF[kind] × w × h: a load, no jump" : "COEF[kind] × width × height: a load, not a jump"), X0, y3 - 10, null, null, true);
      const vals = ["1", "1", "0.5", "π"];
      KINDS.forEach((name, t) => {
        const bx = X0 + t * (bw + 6);
        const on = cur >= 0 && kinds[cur] === t, bad = on && mode === 1 && st.marks[cur];
        ctx.fillStyle = on ? KC[t] : C.elev2; ctx.fillRect(bx, y3, bw, 28);
        ctx.strokeStyle = bad ? C.miss : on ? C.heading : C.border; ctx.lineWidth = bad ? 3 : 1; ctx.strokeRect(bx + 0.5, y3 + 0.5, bw - 1, 27);
        const txt = mode === 1 ? (narrow ? name : "case " + name) : (narrow ? "" : "COEF[" + t + "] = ") + vals[t];
        label(ctx, txt, bx + bw / 2, y3 + 18, on ? "#06121f" : C.text, "center");
      });
    } else {
      const kp = kindPos();
      KINDS.forEach((name, t) => {
        const y = y1 + t * 38;
        label(ctx, `${name.toLowerCase()}s: ${OBJ[t]} B each${narrow ? "" : ` (${t === 0 ? "side" : t === 3 ? "radius" : t === 1 ? "width, height" : "base, height"})`}`, X0, y - 8);
        const cells = kinds.map((x, i) => (x === t ? { off: kp.pos[i], size: OBJ[t], color: KC[t], done: order.indexOf(i) < k, cur: i === cur } : null)).filter(Boolean);
        memRow(ctx, X0, y, s, Math.max(kp.len[t], 1), cells,
          (l) => cells.some((c) => c.done && Math.floor(c.off / 64) === l), rowH);
      });
    }

    const n = Math.max(k, 1);
    cnt.set("n", `${k}/${N}`);
    cnt.set("miss", mode >= 2 ? "0 (no branch)" : st.miss);
    cnt.set("cyc", k ? (st.cycles / n).toFixed(1) : "–");
    cnt.set("bytes", k ? (st.bytes / n).toFixed(1) + " B" : "–");
    cnt.set("lines", st.lines);
    canvas.setAttribute("aria-label", `${MODES[mode]}, ${sorted ? "sorted" : "random"} order: ${k} of ${N} shapes done, ${st.miss} mispredicts, ` +
      `${k ? (st.cycles / n).toFixed(1) : 0} model cycles per shape, ${k ? (st.bytes / n).toFixed(1) : 0} bytes read per shape, ${st.lines} cache lines touched.`);
    if (k === 0) readout.textContent = `Predict: in "${MODES[mode]}" mode with ${sorted ? "sorted" : "random"} kinds, how many of the ${N} shapes will mispredict?`;
    else {
      const t = kinds[cur], name = KINDS[t];
      const why = mode === 0 ? `handle → heap ${name} → vtable → ${name}::area`
        : mode === 1 ? `load 12 B, jump to case ${name}`
          : mode === 2 ? `load 12 B, load COEF[${t}], two multiplies`
            : `next ${name.toLowerCase()} in its own array, same loop as the last one`;
      const pred = mode <= 1 ? (st.marks[cur] ? ` — mispredicted, +${penalty} cycles` : " — predicted") : "";
      readout.textContent = `shape ${cur}: ${why}${pred}`;
    }
  }

  build();
  B.onResize(root, (w) => { k2.fit(Math.max(280, w - 34), k2.height); draw(); });
  draw();
}));

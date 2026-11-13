/* ch10-spatial-grid — a counting sort into grid cells, one operation per step: count, prefix sum, scatter.
 * <div class="figure-body" data-viz="ch10-spatial-grid" data-opts='{"boids":10}'></div>
 * Options:
 *   boids   6..14 boids (default 10)
 *   seed    integer seed for the positions (default 4)
 *   interval  seconds per step while playing (default 0.7)
 * Model. A 3×2 world of unit cells, numbered row-major 0..5. The arrays are exactly the ones in
 * code/ch10-boids-spatial-hash: cell[i], start[0..cells] (cells + 1 entries), order[0..n). Phase 1 counts
 * (start[c] += 1), phase 2 turns the counts into an inclusive prefix sum, phase 3 walks the boids back to front and
 * does start[c] -= 1; order[start[c]] = i. At the end start[c]..start[c+1] is cell c's slice of order.
 * Every value shown comes from replaying the steps. Under reduced motion the still frame is the finished sort. */
(window.BookQ ||= []).push((B) => B.viz.register("ch10-spatial-grid", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["boids", "seed", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch10-spatial-grid: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const N = opts.boids ?? 10;
  viz.check(Number.isInteger(N) && N >= 6 && N <= 14, 'ch10-spatial-grid: "boids" must be an integer 6..14');
  const COLS = 3, ROWS = 2, CELLS = COLS * ROWS;
  const r = B.rng(opts.seed ?? 4);
  const px = [], py = [];
  // rejection sampling so no two boid markers overlap (minimum distance 0.32 cells)
  for (let i = 0, tries = 0; i < N && tries < 5000; tries++) {
    const a = 0.14 + r() * (COLS - 0.28), b = 0.16 + r() * (ROWS - 0.32);
    if (px.some((q, j) => (q - a) ** 2 + (py[j] - b) ** 2 < 0.32 ** 2)) continue;
    px.push(a); py.push(b); i++;
  }
  viz.check(px.length === N, "ch10-spatial-grid: could not place the boids; use fewer");
  const cellOf = (i) => Math.floor(py[i]) * COLS + Math.floor(px[i]);
  // steps: N count steps, CELLS + 1 prefix steps, N scatter steps
  const TOTAL = N + (CELLS + 1) + N;

  function model(k) {
    const start = new Array(CELLS + 1).fill(0), order = new Array(N).fill(null), cell = new Array(N).fill(null);
    let phase = "start", focus = null, sum = 0, writes = 0;
    for (let s = 0; s < k; s++) {
      if (s < N) { const i = s; cell[i] = cellOf(i); start[cell[i]]++; writes++; phase = "count"; focus = { boid: i, cell: cell[i] }; }
      else if (s < N + CELLS + 1) { const c = s - N; sum += start[c]; start[c] = sum; writes++; phase = "prefix"; focus = { cell: c, sum }; }
      else { const i = N - 1 - (s - N - CELLS - 1), c = cell[i]; start[c]--; order[start[c]] = i; writes += 2; phase = "scatter"; focus = { boid: i, cell: c, slot: start[c] }; }
    }
    return { start, order, cell, phase, focus, writes, done: k === TOTAL };
  }

  let k = 0;
  const C = B.colors();
  const CC = [C.pos, C.vel, C.hp, C.flag, C.line, C.miss];
  const canvas = h("canvas", { role: "img" });
  const kk = B.canvas(canvas, 640, 330);
  const cnt = B.counters([["phase", "phase"], ["step", "step"], ["writes", "array writes"], ["passes", "passes over boids"]]);
  const readout = h("p", { class: "readout", "aria-live": "polite" });
  const player = B.player(root, {
    step: () => (k < TOTAL ? (k++, true) : false), back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; }, atEnd: () => k === TOTAL, draw: () => draw(), interval: opts.interval ?? 0.7,
  });
  const jump = (to) => h("button", { type: "button", onclick: () => { player.pause(); k = to; draw(); } });
  const phases = h("div", { class: "group", role: "group", "aria-label": "Jump to phase" },
    Object.assign(jump(N), { textContent: "After count" }), Object.assign(jump(N + CELLS + 1), { textContent: "After prefix sum" }),
    Object.assign(jump(TOTAL), { textContent: "Done" }));
  root.append(canvas, cnt.el, readout, h("div", { class: "controls" }, player.el, phases),
    h("p", { class: "viz-note" }, "start has one more entry than there are cells, so cell c's slice is always start[c]..start[c+1], including the last cell. Cells are numbered row by row."));

  function draw() {
    const m = model(k), ctx = kk.ctx, W = kk.width, narrow = W < 520;
    ctx.clearRect(0, 0, W, kk.height);
    ctx.font = (narrow ? "11px " : "12px ") + C.mono; ctx.textBaseline = "middle";
    // world
    const ww = narrow ? W - 8 : 250, s = ww / COLS, wx = 4, wy = 20;
    ctx.fillStyle = C.dim; ctx.fillText("world (cell numbers)", wx, 9);
    for (let c = 0; c < CELLS; c++) {
      const cx = c % COLS, cy = Math.floor(c / COLS);
      const hot = m.focus && m.focus.cell === c;
      ctx.fillStyle = hot ? "rgba(96,165,250,.18)" : "transparent"; ctx.fillRect(wx + cx * s, wy + cy * s, s, s);
      ctx.strokeStyle = hot ? C.accent : C.border; ctx.lineWidth = hot ? 2 : 1; ctx.strokeRect(wx + cx * s + 0.5, wy + cy * s + 0.5, s - 1, s - 1);
      ctx.fillStyle = CC[c]; ctx.fillText(String(c), wx + cx * s + 5, wy + cy * s + 10);
    }
    for (let i = 0; i < N; i++) {
      const X = wx + px[i] * s, Y = wy + py[i] * s, f = m.focus && m.focus.boid === i;
      ctx.fillStyle = CC[cellOf(i)]; ctx.beginPath(); ctx.arc(X, Y, f ? 11 : 9, 0, 7); ctx.fill();
      if (f) { ctx.strokeStyle = C.heading; ctx.lineWidth = 2; ctx.stroke(); }
      ctx.fillStyle = "#06121f"; ctx.textAlign = "center"; ctx.fillText(String(i), X, Y + 0.5); ctx.textAlign = "start";
    }
    // arrays
    const ax = narrow ? 4 : 280, top = narrow ? wy + ROWS * s + 16 : 20, aw = W - ax - 4;
    const row = (label, vals, y, n, color, hi, sub) => {
      const bw = Math.min(34, (aw - (narrow ? 52 : 60)) / n), x0 = ax + (narrow ? 52 : 60);
      ctx.fillStyle = C.text; ctx.fillText(label, ax, y + 13);
      for (let j = 0; j < n; j++) {
        const v = vals[j];
        ctx.fillStyle = v === null ? C.elev2 || "rgba(127,127,127,.12)" : color(j, v);
        ctx.fillRect(x0 + j * bw + 1, y, bw - 2, 26);
        if (hi.includes(j)) { ctx.strokeStyle = C.heading; ctx.lineWidth = 2; ctx.strokeRect(x0 + j * bw + 1, y, bw - 2, 26); }
        ctx.fillStyle = v === null ? C.dim : "#06121f"; ctx.textAlign = "center";
        ctx.fillText(v === null ? "·" : String(v), x0 + j * bw + bw / 2, y + 13.5);
        ctx.fillStyle = C.dim; ctx.fillText(String(j), x0 + j * bw + bw / 2, y + 34); ctx.textAlign = "start";
      }
      if (sub) { ctx.fillStyle = C.dim; ctx.fillText(sub, ax, y + 34); }
      return { x0, bw };
    };
    const f = m.focus || {};
    const gap = 54;
    row("cell[i]", m.cell, top, N, (j, v) => CC[v], f.boid !== undefined ? [f.boid] : [], "i →");
    const st = row("start[c]", m.start, top + gap, CELLS + 1, (j) => (j < CELLS ? CC[j] : C.pad), f.cell !== undefined ? [f.cell] : [], "c →");
    const ord = row("order[p]", m.order, top + 2 * gap, N, (j, v) => CC[cellOf(v)], f.slot !== undefined ? [f.slot] : [], "p →");
    // brackets: each cell's slice of order, once the sort is done
    if (m.done) {
      for (let c = 0; c < CELLS; c++) {
        const a = m.start[c], e = m.start[c + 1];
        if (e <= a) continue;
        const y = top + 2 * gap + 42, x1 = ord.x0 + a * ord.bw + 2, x2 = ord.x0 + e * ord.bw - 2;
        ctx.strokeStyle = CC[c]; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(x1, y - 3); ctx.lineTo(x1, y); ctx.lineTo(x2, y); ctx.lineTo(x2, y - 3); ctx.stroke();
        ctx.fillStyle = CC[c]; ctx.textAlign = "center"; ctx.fillText("cell " + c, (x1 + x2) / 2, y + 10); ctx.textAlign = "start";
      }
    }
    const needH = top + 2 * gap + 60;
    if (Math.abs(kk.height - needH) > 1) { kk.fit(W, needH); return draw(); }
    void st;

    const label = { start: "–", count: "1 count", prefix: "2 prefix sum", scatter: "3 scatter" }[m.phase];
    cnt.set("phase", label); cnt.set("step", `${k}/${TOTAL}`); cnt.set("writes", m.writes);
    cnt.set("passes", m.phase === "start" ? 0 : m.phase === "count" ? 1 : m.phase === "prefix" ? "1 + cells" : "2 + cells");
    let msg;
    if (m.phase === "start") msg = `Predict: ${N} boids in ${CELLS} cells. After counting, what is the sum of start[]? After the prefix sum, what is start[${CELLS - 1}]?`;
    else if (m.phase === "count") msg = `count: boid ${f.boid} is in cell ${f.cell}, so start[${f.cell}] += 1 → ${m.start[f.cell]}`;
    else if (m.phase === "prefix") msg = `prefix sum: start[${f.cell}] = boids in cells 0..${f.cell} = ${f.sum}` + (f.cell === CELLS ? " (the extra entry stays 0 + total)" : "");
    else msg = `scatter (back to front): boid ${f.boid}, cell ${f.cell}: start[${f.cell}] -= 1 → ${f.slot}; order[${f.slot}] = ${f.boid}` + (m.done ? ". Done: cell c is order[start[c]..start[c+1]]." : "");
    readout.textContent = msg;
    canvas.setAttribute("aria-label", `Counting sort of ${N} boids into ${CELLS} cells, ${label}. start = [${m.start.join(", ")}], order = [${m.order.map((v) => (v === null ? "empty" : v)).join(", ")}].`);
  }
  B.onResize(root, (w) => { kk.fit(w, kk.height); draw(); });
  draw();
}));

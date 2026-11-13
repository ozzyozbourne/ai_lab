/* ch10-boids — a live boids flock on a uniform grid, with the distance checks of naive vs grid search counted.
 * <div class="figure-body" data-viz="ch10-boids" data-opts='{"boids":640}'></div>
 * Options:
 *   boids   initial boid count, 40..2000 (default 640; a slider changes it)
 *   cols    grid columns, 6..32 (default 16); rows    grid rows, 4..24 (default 10)
 *   seed    integer seed (default 10)
 *   mode    "grid" | "naive" initial search mode (default "grid")
 * Model. The same step as code/ch10-boids-spatial-hash: cells of size 1 = the neighbour radius, Reynolds'
 * cohesion / alignment / separation with the book's constants, speed clamp 2, dt 0.05, bouncing walls.
 * Every step rebuilds a counting-sort grid (count, prefix sum, scatter). The counters are computed from that
 * grid: naive checks = n², grid checks = Σ over boids of the boids in its 3×3 block. Both searches find the same
 * neighbours; only the work differs. Click or tap a boid to select it. Under reduced motion it shows a still frame
 * (after 80 steps from the seeded start) and plays only on request. */
(window.BookQ ||= []).push((B) => B.viz.register("ch10-boids", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["boids", "cols", "rows", "seed", "mode"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch10-boids: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const COLS = opts.cols ?? 16, ROWS = opts.rows ?? 10;
  viz.check(Number.isInteger(COLS) && COLS >= 6 && COLS <= 32, 'ch10-boids: "cols" must be an integer 6..32');
  viz.check(Number.isInteger(ROWS) && ROWS >= 4 && ROWS <= 24, 'ch10-boids: "rows" must be an integer 4..24');
  let N = opts.boids ?? 640;
  viz.check(Number.isInteger(N) && N >= 40 && N <= 2000, 'ch10-boids: "boids" must be an integer 40..2000');
  viz.check(opts.mode === undefined || opts.mode === "grid" || opts.mode === "naive", 'ch10-boids: "mode" must be "grid" or "naive"');
  let mode = opts.mode === "naive" ? 1 : 0;
  const SEED = opts.seed ?? 10;

  // the book's constants (see main.rs)
  const R2 = 1.0, SEP2 = 0.0625, COH = 0.02, ALI = 0.05, SEP = 0.5, MAXV = 2.0, DT = 0.05;
  const CELLS = COLS * ROWS;

  // ---- model: SoA columns, double-buffered ----
  let x, y, vx, vy, nx, ny, nvx, nvy, cell, start, order, nbr;
  let steps = 0, sel = 0, last = null;
  function spawn() {
    const r = B.rng(SEED);
    const col = () => new Float32Array(N);
    x = col(); y = col(); vx = col(); vy = col(); nx = col(); ny = col(); nvx = col(); nvy = col();
    cell = new Uint32Array(N); start = new Uint32Array(CELLS + 1); order = new Uint32Array(N); nbr = new Uint32Array(N);
    for (let i = 0; i < N; i++) { x[i] = r() * COLS; y[i] = r() * ROWS; vx[i] = r() * 2 - 1; vy[i] = r() * 2 - 1; }
    steps = 0; sel = Math.min(sel, N - 1);
    build(); last = measure();
  }
  const cxOf = (v) => Math.min(Math.floor(v), COLS - 1), cyOf = (v) => Math.min(Math.floor(v), ROWS - 1);
  function build() {           // counting sort: count, inclusive prefix sum, scatter back to front
    start.fill(0);
    for (let i = 0; i < N; i++) { cell[i] = cyOf(y[i]) * COLS + cxOf(x[i]); start[cell[i]]++; }
    let s = 0;
    for (let c = 0; c <= CELLS; c++) { s += start[c]; start[c] = s; }
    for (let i = N - 1; i >= 0; i--) order[--start[cell[i]]] = i;
  }
  const blockOf = (i) => {
    const cx = cxOf(x[i]), cy = cyOf(y[i]);
    return [Math.max(cx - 1, 0), Math.min(cx + 1, COLS - 1), Math.max(cy - 1, 0), Math.min(cy + 1, ROWS - 1)];
  };
  // grid checks per boid and neighbour counts (identical to what naive would find)
  function measure() {
    let checks = 0, found = 0, selChecks = 0;
    for (let i = 0; i < N; i++) {
      const [x0, x1, y0, y1] = blockOf(i);
      let k = 0, c = 0;
      for (let row = y0; row <= y1; row++) {
        const a = start[row * COLS + x0], e = start[row * COLS + x1 + 1];
        k += e - a;
        for (let p = a; p < e; p++) { const j = order[p], dx = x[j] - x[i], dy = y[j] - y[i]; if (dx * dx + dy * dy < R2) c++; }
      }
      checks += k; found += c; nbr[i] = c;
      if (i === sel) selChecks = k;
    }
    return { checks, found, selChecks };
  }
  function step() {
    build();
    for (let i = 0; i < N; i++) {
      const [x0, x1, y0, y1] = blockOf(i);
      let n = 0, sx = 0, sy = 0, ax = 0, ay = 0, qx = 0, qy = 0;
      for (let row = y0; row <= y1; row++) {
        for (let p = start[row * COLS + x0], e = start[row * COLS + x1 + 1]; p < e; p++) {
          const j = order[p], dx = x[j] - x[i], dy = y[j] - y[i], d2 = dx * dx + dy * dy;
          if (d2 < R2) { n++; sx += dx; sy += dy; ax += vx[j]; ay += vy[j]; if (d2 < SEP2) { qx -= dx; qy -= dy; } }
        }
      }
      const inv = 1 / n;
      let wx = vx[i] + COH * sx * inv + ALI * (ax * inv - vx[i]) + SEP * qx;
      let wy = vy[i] + COH * sy * inv + ALI * (ay * inv - vy[i]) + SEP * qy;
      const s2 = wx * wx + wy * wy;
      if (s2 > MAXV * MAXV) { const k = MAXV / Math.sqrt(s2); wx *= k; wy *= k; }
      let px = x[i] + wx * DT, py = y[i] + wy * DT;
      if (px < 0) { px = -px; wx = -wx; } else if (px > COLS) { px = 2 * COLS - px; wx = -wx; }
      if (py < 0) { py = -py; wy = -wy; } else if (py > ROWS) { py = 2 * ROWS - py; wy = -wy; }
      nx[i] = px; ny[i] = py; nvx[i] = wx; nvy[i] = wy;
    }
    [x, nx] = [nx, x]; [y, ny] = [ny, y]; [vx, nvx] = [nvx, vx]; [vy, nvy] = [nvy, vy];   // swap the buffers
    steps++;
    build(); last = measure();
    return true;
  }

  // ---- view ----
  const C = B.colors();
  const canvas = h("canvas", { role: "img", tabindex: "0" });
  const k = B.canvas(canvas, 640, 400);
  const cnt = B.counters([["n", "boids"], ["mode", "checks / step", "bad"], ["naive", "naive n²"], ["grid", "grid Σ 3×3"],
    ["ratio", "naive ÷ grid", "good"], ["found", "neighbour pairs"], ["useful", "useful checks"]]);
  const readout = h("p", { class: "readout", "aria-live": "polite" });
  const player = B.player(root, { step, reset: () => { spawn(); }, draw: () => draw(), interval: 1 / 30, still: "start" });
  const seg = B.segmented(["Grid search", "Naive search"], mode, (i) => { mode = i; draw(); }, "Search");
  const slider = B.slider({ label: "boids", min: 40, max: 2000, step: 40, value: N, format: (v) => String(v),
    oninput: (v) => { N = v; spawn(); warm(20); draw(); } });
  const legend = h("div", { class: "legend" });
  const sw = (t, c) => { const i = h("i"); i.style.background = c; legend.append(h("span", {}, i, t)); };
  sw("selected boid", C.heading); sw("checked by the selected boid", C.hp); sw("its neighbours (inside radius 1)", C.hit); sw("not checked", C.pad);
  root.append(canvas, cnt.el, readout, h("div", { class: "controls" }, player.el, seg, slider), legend,
    h("p", { class: "viz-note" }, "Click or tap a boid to select it. Both searches find the same neighbours; the counters show how many distance tests each one runs per step."));

  const warm = (s) => { for (let i = 0; i < s; i++) step(); };
  canvas.addEventListener("click", (ev) => {
    const r = canvas.getBoundingClientRect(), s = r.width / COLS;
    const px = (ev.clientX - r.left) / s, py = (ev.clientY - r.top) / s;
    let best = 0, bd = Infinity;
    for (let i = 0; i < N; i++) { const d = (x[i] - px) ** 2 + (y[i] - py) ** 2; if (d < bd) { bd = d; best = i; } }
    sel = best; last = measure(); draw();
  });

  function draw() {
    const ctx = k.ctx, W = k.width, s = W / COLS;
    ctx.clearRect(0, 0, W, k.height);
    const [x0, x1, y0, y1] = blockOf(sel);
    // the 3×3 block of the selected boid (grid mode) or the whole world (naive mode)
    ctx.fillStyle = "rgba(96,165,250,.13)";
    if (mode === 0) ctx.fillRect(x0 * s, y0 * s, (x1 - x0 + 1) * s, (y1 - y0 + 1) * s);
    else ctx.fillRect(0, 0, W, ROWS * s);
    ctx.strokeStyle = C.border; ctx.lineWidth = 1;
    for (let c = 0; c <= COLS; c++) { ctx.beginPath(); ctx.moveTo(Math.round(c * s) + 0.5, 0); ctx.lineTo(Math.round(c * s) + 0.5, ROWS * s); ctx.stroke(); }
    for (let r = 0; r <= ROWS; r++) { ctx.beginPath(); ctx.moveTo(0, Math.round(r * s) + 0.5); ctx.lineTo(W, Math.round(r * s) + 0.5); ctx.stroke(); }
    if (mode === 0) { ctx.strokeStyle = C.accent; ctx.lineWidth = 2; ctx.strokeRect(x0 * s + 1, y0 * s + 1, (x1 - x0 + 1) * s - 2, (y1 - y0 + 1) * s - 2); }
    // neighbour radius
    ctx.strokeStyle = C.hit; ctx.lineWidth = 1.2; ctx.setLineDash([4, 3]);
    ctx.beginPath(); ctx.arc(x[sel] * s, y[sel] * s, s, 0, 7); ctx.stroke(); ctx.setLineDash([]);
    const inBlock = (j) => { const cx = cxOf(x[j]), cy = cyOf(y[j]); return cx >= x0 && cx <= x1 && cy >= y0 && cy <= y1; };
    const rad = Math.max(1.6, Math.min(3.2, s * 0.09));
    let selNbr = 0;
    for (let j = 0; j < N; j++) {
      const dx = x[j] - x[sel], dy = y[j] - y[sel], near = dx * dx + dy * dy < R2;
      const checked = mode === 1 || inBlock(j);
      if (near) selNbr++;
      ctx.fillStyle = near ? C.hit : checked ? C.hp : C.pad;
      if (near && j !== sel) { ctx.strokeStyle = "rgba(127,219,160,.5)"; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(x[sel] * s, y[sel] * s); ctx.lineTo(x[j] * s, y[j] * s); ctx.stroke(); }
      // heading tick
      const sp = Math.hypot(vx[j], vy[j]) || 1;
      ctx.beginPath(); ctx.arc(x[j] * s, y[j] * s, rad, 0, 7); ctx.fill();
      ctx.strokeStyle = ctx.fillStyle; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(x[j] * s, y[j] * s); ctx.lineTo((x[j] + vx[j] / sp * 0.28) * s, (y[j] + vy[j] / sp * 0.28) * s); ctx.stroke();
    }
    ctx.fillStyle = C.heading; ctx.beginPath(); ctx.arc(x[sel] * s, y[sel] * s, rad + 2, 0, 7); ctx.fill();

    const naive = N * N, grid = last.checks;
    cnt.set("n", N);
    cnt.set("mode", B.fmtInt(mode === 0 ? grid : naive));
    cnt.set("naive", B.fmtInt(naive)); cnt.set("grid", B.fmtInt(grid));
    cnt.set("ratio", (naive / grid).toFixed(1) + "×");
    cnt.set("found", B.fmtInt(last.found));
    cnt.set("useful", Math.round(100 * last.found / (mode === 0 ? grid : naive)) + "%");
    const selCheck = mode === 0 ? last.selChecks : N;
    readout.textContent = `step ${steps} · selected boid ${sel} in cell (${cxOf(x[sel])}, ${cyOf(y[sel])}): ${selCheck} distance checks, ${selNbr} neighbours (itself included) · ${mode === 0 ? "3×3 block of cells" : "every boid"}`;
    canvas.setAttribute("aria-label", `${N} boids on a ${COLS} by ${ROWS} grid. ${mode === 0 ? "Grid" : "Naive"} search: ${B.fmtInt(mode === 0 ? grid : naive)} distance checks per step, versus ${B.fmtInt(mode === 0 ? naive : grid)} for the other search. Both find ${B.fmtInt(last.found)} neighbour pairs.`);
  }

  spawn(); warm(80);
  { // select the boid nearest the middle so its whole 3×3 block is visible
    let bd = Infinity;
    for (let i = 0; i < N; i++) { const d = (x[i] - COLS / 2) ** 2 + (y[i] - ROWS / 2) ** 2; if (d < bd) { bd = d; sel = i; } }
    last = measure();
  }
  B.onResize(root, (w) => { k.fit(w, Math.round(w * ROWS / COLS)); draw(); });
  draw();
}));

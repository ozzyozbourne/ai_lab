/* ch06-lifetimes — object lifetimes on a timeline, grouped into three arenas by phase (program, level, frame).
 * <div class="figure-body" data-viz="ch06-lifetimes" data-opts='{"levels":3,"framesPerLevel":6}'></div>
 * Options:
 *   levels          1..4 levels (default 3)
 *   framesPerLevel  3..10 frames per level (default 6)
 *   perFrame        1..6 temporary objects per frame (default 4)
 *   seed            integer seed (default 3)
 *   interval        seconds per frame while playing (default 0.35)
 * Model: program objects live for the whole run, level objects from their level's load to its end, frame objects
 * inside one frame. A cursor walks the timeline one frame at a time. Counters: objects created so far, the free()
 * calls a per-object allocator needs for everything that has died, and the resets the three arenas need instead
 * (one per finished frame, one per finished level, one at exit). "Bug" mode puts one level object into the frame
 * arena: everything after the first frame reset is a dangling reference, drawn in red. */
(window.BookQ ||= []).push((B) => B.viz.register("ch06-lifetimes", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["levels", "framesPerLevel", "perFrame", "seed", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch06-lifetimes: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const LV = opts.levels ?? 3, FPL = opts.framesPerLevel ?? 6, PF = opts.perFrame ?? 4;
  viz.check(Number.isInteger(LV) && LV >= 1 && LV <= 4, 'ch06-lifetimes: "levels" must be an integer 1..4');
  viz.check(Number.isInteger(FPL) && FPL >= 3 && FPL <= 10, 'ch06-lifetimes: "framesPerLevel" must be an integer 3..10');
  viz.check(Number.isInteger(PF) && PF >= 1 && PF <= 6, 'ch06-lifetimes: "perFrame" must be an integer 1..6');
  const T = LV * FPL; // timeline length in frames
  const rnd = B.rng(opts.seed ?? 3);

  // ---- objects: {lane, row, start, end} in frame units ----
  const objs = [];
  const PROG = 3, LEVROWS = 4;
  for (let r = 0; r < PROG; r++) objs.push({ lane: 0, row: r, start: 0, end: T });
  for (let l = 0; l < LV; l++) for (let r = 0; r < LEVROWS; r++) {
    const start = l * FPL + (r === 0 ? 0 : rnd.int(Math.max(1, FPL - 2)) + rnd());
    objs.push({ lane: 1, row: r, start, end: (l + 1) * FPL, level: l });
  }
  for (let f = 0; f < T; f++) for (let r = 0; r < PF; r++) {
    const a = rnd() * 0.6, b = a + 0.15 + rnd() * (0.85 - a);
    objs.push({ lane: 2, row: r, start: f + a, end: f + Math.min(b, 0.98) });
  }
  const victim = objs.find((o) => o.lane === 1 && o.row === 1 && o.level === 0); // the object the bug misplaces

  let t = 0, bug = 0;
  const C = B.colors();
  const laneColor = [C.hp, C.vel, C.pos];
  const laneName = ["program arena", "level arena", "frame arena"];
  const canvas = h("canvas", { role: "img" });
  const k = B.canvas(canvas, 640, 260);
  const cnt = B.counters([["n", "objects made"], ["free", "free() calls one by one", "bad"], ["reset", "arena resets", "good"], ["dang", "dangling uses", "bad"]]);
  const readout = h("p", { class: "readout" });
  const player = B.player(root, {
    step: () => (t < T ? (t++, true) : false),
    back: () => (t > 0 ? (t--, true) : false),
    reset: () => { t = 0; },
    atEnd: () => t === T,
    draw: () => draw(),
    interval: opts.interval ?? 0.35,
  });
  const seg = B.segmented(["Correct", "Bug: level object in frame arena"], 0, (i) => { bug = i; draw(); }, "Arena assignment");
  root.append(canvas, cnt.el, readout, h("div", { class: "controls" }, player.el, seg),
    h("p", { class: "viz-note" }, "Model: a frame's temporaries die inside the frame, a level's data dies when the level unloads, program data dies at exit. Each arena is freed with one reset at its phase boundary."));

  const firstReset = Math.floor(victim.start) + 1; // the frame reset that wipes the misplaced object
  function counts() {
    const made = objs.filter((o) => o.start < t || t === T).length;
    const dead = objs.filter((o) => o.end <= t).length;
    const resets = t + Math.floor(t / FPL) + (t === T ? 1 : 0);
    const dang = bug ? Math.max(0, Math.min(t, victim.end) - firstReset) : 0;
    return { made, dead, resets, dang };
  }

  function draw() {
    const W = k.width, ctx = k.ctx, narrow = W < 520;
    const labelW = narrow ? 0 : 104, top = narrow ? 44 : 22, laneGap = narrow ? 20 : 10;
    const rowH = narrow ? 7 : 9, rows = [PROG, LEVROWS, PF + 1];
    const laneH = rows.map((r) => r * rowH + 6);
    const Hh = top + laneH.reduce((a, b) => a + b, 0) + laneGap * 3 + 18;
    if (Math.abs(k.height - Hh) > 0.5) k.fit(W, Hh);
    ctx.clearRect(0, 0, W, Hh);
    const x0 = labelW + 6, x1 = W - 8, sx = (x1 - x0) / T;
    const X = (f) => x0 + f * sx;
    const laneY = []; let y = top;
    for (let L = 0; L < 3; L++) { laneY.push(y); y += laneH[L] + laneGap; }
    // level bands and frame ticks
    ctx.font = "10px " + C.mono; ctx.textBaseline = "alphabetic";
    for (let l = 0; l < LV; l++) {
      ctx.fillStyle = l % 2 ? "rgba(255,255,255,.025)" : "rgba(255,255,255,.055)";
      const bandTop = narrow ? top - 30 : top - 12;
      ctx.fillRect(X(l * FPL), bandTop, FPL * sx, y - bandTop - 8);
      ctx.fillStyle = C.dim; ctx.fillText(`level ${l + 1}`, X(l * FPL) + 3, narrow ? top - 19 : top - 3);
    }
    for (let L = 0; L < 3; L++) {
      const ly = laneY[L];
      if (narrow) { ctx.fillStyle = laneColor[L]; ctx.fillText(laneName[L], x0, ly - 2); }
      else { ctx.fillStyle = laneColor[L]; ctx.font = "600 11px " + C.body; ctx.fillText(laneName[L], 4, ly + laneH[L] / 2 + 4); ctx.font = "10px " + C.mono; }
      ctx.strokeStyle = C.border; ctx.lineWidth = 1; ctx.strokeRect(x0 + 0.5, ly + 0.5, x1 - x0, laneH[L] - 1);
      // reset marks at this arena's phase boundaries that the cursor has passed
      const marks = L === 2 ? [...Array(T).keys()].map((f) => f + 1) : L === 1 ? [...Array(LV).keys()].map((l) => (l + 1) * FPL) : [T];
      for (const m of marks) {
        if (m > t) continue;
        ctx.strokeStyle = laneColor[L]; ctx.globalAlpha = L === 2 ? 0.45 : 0.9; ctx.lineWidth = L === 2 ? 1 : 2;
        ctx.beginPath(); ctx.moveTo(X(m) - 0.5, ly - 2); ctx.lineTo(X(m) - 0.5, ly + laneH[L] + 2); ctx.stroke(); ctx.globalAlpha = 1;
      }
    }
    // object bars (only the part that has happened)
    for (const o of objs) {
      if (o.start >= t && !(t === T)) continue;
      const misplaced = bug && o === victim;
      const L = misplaced ? 2 : o.lane, row = misplaced ? PF : o.row;
      const yy = laneY[L] + 3 + row * rowH, end = Math.min(o.end, t);
      if (misplaced) {
        ctx.fillStyle = laneColor[2]; ctx.fillRect(X(o.start), yy, Math.max(1, (Math.min(end, firstReset) - o.start) * sx - 1), rowH - 2);
        if (end > firstReset) {
          ctx.fillStyle = C.miss; ctx.fillRect(X(firstReset), yy, (end - firstReset) * sx - 1, rowH - 2);
        }
        continue;
      }
      ctx.fillStyle = laneColor[L]; ctx.globalAlpha = o.end <= t ? 0.55 : 1;
      ctx.fillRect(X(o.start), yy, Math.max(1, (end - o.start) * sx - 1), rowH - 2); ctx.globalAlpha = 1;
    }
    // cursor
    ctx.strokeStyle = C.heading; ctx.lineWidth = 1.5; ctx.beginPath(); ctx.moveTo(X(t), top - 12); ctx.lineTo(X(t), y - laneGap + 4); ctx.stroke();
    ctx.fillStyle = C.dim; ctx.fillText(`frame ${Math.min(t, T)} / ${T}`, Math.min(X(t) + 4, W - 80), y + 6);
    const c = counts();
    cnt.set("n", c.made); cnt.set("free", c.dead); cnt.set("reset", c.resets); cnt.set("dang", c.dang);
    canvas.setAttribute("aria-label", `Timeline at frame ${t} of ${T}: ${c.made} objects made, ${c.dead} would need individual free calls, ${c.resets} arena resets free them instead.` + (bug ? ` Bug mode: ${c.dang} uses of a dangling level object.` : ""));
    readout.textContent = t === 0 ? "Predict: by the end, how many free() calls does a per-object allocator make, and how many resets do the three arenas make?"
      : bug && c.dang > 0 ? `The misplaced level object was wiped by the frame reset at the end of frame ${firstReset}; the level kept using it for ${c.dang} more frame${c.dang === 1 ? "" : "s"} (use after free).`
      : `${c.dead} objects have died: ${c.dead} free() calls one by one, or ${c.resets} resets (${Math.min(t, T)} frame + ${Math.floor(t / FPL)} level${t === T ? " + 1 program" : ""}).`;
  }
  B.onResize(root, (w) => { k.fit(w, k.height); draw(); });
  draw();
}));

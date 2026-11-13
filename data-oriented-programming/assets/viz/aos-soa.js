/* aos-soa — which 64-byte cache lines a loop touches under different particle layouts.
 * <div class="figure-body" data-viz="aos-soa" data-opts='{"entities":16,"layouts":["aos","hotcold","soa","aosoa"],"block":8,"reads":0}'></div>
 * Options (all optional, validated):
 *   entities  integer 1..64             number of particles (default 16)
 *   layouts   array of "aos" | "hotcold" | "soa" | "aosoa" (default ["aos","soa"]); one panel each
 *   block     4 | 8 | 16                AoSoA block size (default 8)
 *   reads     0 | 1 | 2 or a field list  initial access set: 0 = pos, 1 = pos+vel, 2 = every field (default 0);
 *             a list such as ["pos","hp"] adds a custom choice. Fields: pos (f32×3), vel (f32×3), hp (u32), alive (bool)
 *   interval  seconds per entity while playing (default 0.35)
 * Model: 4-byte cells, 16 per line. Separate arrays start on a fresh line. Every counter is computed from the
 * cell map: lines loaded = distinct lines holding a read field of entities 0..i, useful = bytes the loop reads. */
(window.BookQ ||= []).push((B) => B.viz.register("aos-soa", (root, opts) => {
  const { h, viz } = B;
  const FIELDS = { pos: 12, vel: 12, hp: 4, alive: 1 };
  const KNOWN = ["entities", "layouts", "block", "reads", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `aos-soa: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const N = opts.entities ?? 16;
  viz.check(Number.isInteger(N) && N >= 1 && N <= 64, `aos-soa: "entities" must be an integer 1..64, got ${JSON.stringify(opts.entities)}`);
  const BLOCK = opts.block ?? 8;
  viz.check([4, 8, 16].includes(BLOCK), `aos-soa: "block" must be 4, 8 or 16, got ${JSON.stringify(opts.block)}`);
  const layouts = opts.layouts ?? ["aos", "soa"];
  const TITLES = {
    aos: ["Array of Structs", "[N]Particle · 32 B each (pos, alive+3 pad, vel, hp)"],
    hotcold: ["Hot/cold split", "hot[N] {pos, vel} 24 B · cold[N] {hp, alive} 8 B"],
    soa: ["Struct of Arrays", "pos[N] · vel[N] · hp[N] · alive[N]"],
    aosoa: ["AoSoA, blocks of " + BLOCK, `x y z vx vy vz hp [${BLOCK}] + alive[${BLOCK}] + pad`],
  };
  viz.check(Array.isArray(layouts) && layouts.length >= 1 && layouts.length <= 4,
    `aos-soa: "layouts" must be a non-empty array of up to 4 of ${Object.keys(TITLES).join(", ")}`);
  for (const l of layouts) viz.check(l in TITLES, `aos-soa: unknown layout "${l}" (known: ${Object.keys(TITLES).join(", ")})`);
  viz.check(new Set(layouts).size === layouts.length, `aos-soa: "layouts" has duplicates`);
  const PRESETS = [
    { label: "reads pos", f: ["pos"] },
    { label: "pos+vel", f: ["pos", "vel"] },
    { label: "every field", f: ["pos", "vel", "hp", "alive"] },
  ];
  let mode = 0;
  if (Array.isArray(opts.reads)) {
    for (const f of opts.reads) viz.check(f in FIELDS, `aos-soa: unknown field "${f}" in "reads" (known: ${Object.keys(FIELDS).join(", ")})`);
    viz.check(opts.reads.length > 0, `aos-soa: "reads" must not be empty`);
    const key = [...opts.reads].sort().join();
    mode = PRESETS.findIndex((p) => [...p.f].sort().join() === key);
    if (mode < 0) { PRESETS.push({ label: opts.reads.join("+"), f: opts.reads.slice() }); mode = PRESETS.length - 1; }
  } else if (opts.reads !== undefined) {
    viz.check(Number.isInteger(opts.reads) && opts.reads >= 0 && opts.reads < 3, `aos-soa: "reads" must be 0, 1, 2 or a list of fields`);
    mode = opts.reads;
  }
  const interval = opts.interval ?? 0.35;
  viz.check(typeof interval === "number" && interval > 0.02 && interval < 10, `aos-soa: "interval" must be seconds between 0.02 and 10`);

  /* ---- memory model: cells {f, e, n (entities packed), pad (bytes)} ---- */
  function build(layout) {
    const cells = [];
    const align = () => { while (cells.length % 16) cells.push({ f: "gap" }); };
    const ent = (f, e) => cells.push({ f, e });
    if (layout === "aos") {
      for (let e = 0; e < N; e++) { ent("pos", e); ent("pos", e); ent("pos", e); cells.push({ f: "alive", e, n: 1, pad: 3 }); ent("vel", e); ent("vel", e); ent("vel", e); ent("hp", e); }
    } else if (layout === "hotcold") {
      for (let e = 0; e < N; e++) { for (let i = 0; i < 3; i++) ent("pos", e); for (let i = 0; i < 3; i++) ent("vel", e); }
      align();
      for (let e = 0; e < N; e++) { ent("hp", e); cells.push({ f: "alive", e, n: 1, pad: 3 }); }
    } else if (layout === "soa") {
      for (let e = 0; e < N; e++) for (let i = 0; i < 3; i++) ent("pos", e);
      align();
      for (let e = 0; e < N; e++) for (let i = 0; i < 3; i++) ent("vel", e);
      align();
      for (let e = 0; e < N; e++) ent("hp", e);
      align();
      for (let e = 0; e < N; e += 4) cells.push({ f: "alive", e, n: Math.min(4, N - e), packed: true });
    } else {
      for (let b = 0; b < N; b += BLOCK) {
        for (const f of ["pos", "pos", "pos", "vel", "vel", "vel", "hp"]) for (let j = 0; j < BLOCK; j++) b + j < N ? ent(f, b + j) : cells.push({ f: "unused" });
        for (let j = 0; j < BLOCK; j += 4) cells.push({ f: "alive", e: b + j, n: Math.max(0, Math.min(4, N - b - j)), packed: true });
        while (cells.length % 16) cells.push({ f: "pad" });
      }
    }
    align();
    cells.forEach((c, i) => (c.line = Math.floor(i / 16)));
    // lines[e][f] = Set of lines holding field f of entity e
    const lines = Array.from({ length: N }, () => ({}));
    for (const c of cells) {
      if (!(c.f in FIELDS)) continue;
      const n = c.n ?? 1;
      for (let e = c.e; e < c.e + n; e++) (lines[e][c.f] ||= new Set()).add(c.line);
    }
    return { layout, cells, lines, total: cells.length / 16 };
  }
  const models = layouts.map(build);

  let k = 0; // entities processed
  function stats(m) {
    const fs = PRESETS[mode].f, loaded = new Set(), fresh = new Set();
    for (let e = 0; e < k; e++) for (const f of fs) for (const l of m.lines[e][f] || []) {
      if (!loaded.has(l)) { loaded.add(l); if (e === k - 1) fresh.add(l); }
    }
    const useful = k * fs.reduce((s, f) => s + FIELDS[f], 0);
    return { loaded, fresh, fetched: loaded.size * 64, useful };
  }

  /* ---- DOM ---- */
  const C = B.colors();
  const panels = models.map((m) => {
    const canvas = h("canvas", { role: "img" });
    const cnt = B.counters([["lines", "lines"], ["bytes", "fetched"], ["eff", "useful"]]);
    const el = h("div", { class: "viz-panel" },
      h("p", { class: "viz-title" }, TITLES[m.layout][0], h("small", {}, TITLES[m.layout][1].replace(/\[N\]/g, "[" + N + "]"))),
      canvas, cnt.el);
    return { m, el, canvas, cnt, k: B.canvas(canvas, 300, 100) };
  });
  const readout = h("p", { class: "readout", "aria-live": "off" });
  const seg = B.segmented(PRESETS.map((p) => p.label), mode, (i) => { mode = i; draw(); }, "Fields the loop reads");
  const player = B.player(root, {
    step: () => (k < N ? (k++, true) : false),
    back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; },
    atEnd: () => k === N,
    draw: () => draw(),
    interval,
  });
  const legend = h("div", { class: "legend" });
  [["pos f32×3", C.pos], ["vel f32×3", C.vel], ["hp u32", C.hp], ["alive bool", C.flag], ["padding", null], ["other memory", "transparent"]].forEach(([t, c]) => {
    const i = h("i", { class: c ? null : "hatch" });
    if (c) i.style.background = c;
    if (c === "transparent") i.style.outline = "1px solid " + C.border;
    legend.append(h("span", {}, i, t));
  });
  root.classList.add("viz-aos-soa");
  root.append(h("div", { class: "viz-panels" }, panels.map((p) => p.el)), readout,
    h("div", { class: "controls" }, player.el, seg), legend);

  /* ---- drawing ---- */
  function hatch(ctx, x, y, w, hh) {
    ctx.fillStyle = C.pad; ctx.fillRect(x, y, w, hh);
    ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, hh); ctx.clip();
    ctx.strokeStyle = "rgba(255,255,255,.28)"; ctx.lineWidth = 1;
    for (let s = x - hh; s < x + w; s += 4) { ctx.beginPath(); ctx.moveTo(s, y + hh); ctx.lineTo(s + hh, y); ctx.stroke(); }
    ctx.restore();
  }
  const colorOf = (f) => ({ pos: C.pos, vel: C.vel, hp: C.hp, alive: C.flag }[f]);
  function drawPanel(p) {
    const W = p.k.width, ctx = p.k.ctx, m = p.m, st = stats(m), fs = PRESETS[mode].f;
    const labelW = 26, gap = 2, cw = Math.max(5, (W - labelW - 6) / 16 - gap), ch = Math.round(Math.min(22, Math.max(12, cw)));
    const rowH = ch + 7;
    const H = m.total * rowH + 4;
    if (Math.abs(p.k.height - H) > 0.5) p.k.fit(W, H);
    ctx.clearRect(0, 0, W, H);
    for (let l = 0; l < m.total; l++) {
      const y = 2 + l * rowH;
      ctx.fillStyle = C.dim; ctx.font = "10px " + C.mono; ctx.textBaseline = "middle";
      ctx.fillText("L" + l, 0, y + ch / 2 + 1);
      if (st.loaded.has(l)) {
        ctx.fillStyle = st.fresh.has(l) ? "rgba(124,196,255,.42)" : "rgba(124,196,255,.16)";
        ctx.fillRect(labelW - 3, y - 3, 16 * (cw + gap) + 4, ch + 6);
        ctx.strokeStyle = C.line; ctx.lineWidth = st.fresh.has(l) ? 2 : 1.25;
        ctx.strokeRect(labelW - 3, y - 3, 16 * (cw + gap) + 4, ch + 6);
      }
    }
    m.cells.forEach((c, i) => {
      const x = labelW + (i % 16) * (cw + gap), y = 2 + c.line * rowH;
      if (c.f === "gap" || c.f === "unused") {
        ctx.strokeStyle = C.border; ctx.lineWidth = 1;
        if (c.f === "unused") ctx.setLineDash([2, 2]);
        ctx.strokeRect(x + 0.5, y + 0.5, cw - 1, ch - 1); ctx.setLineDash([]);
        return;
      }
      if (c.f === "pad") { ctx.globalAlpha = 0.6; hatch(ctx, x, y, cw, ch); ctx.globalAlpha = 1; return; }
      const active = fs.includes(c.f);
      ctx.globalAlpha = active ? 1 : 0.38;
      if (c.f === "alive" && c.pad) {
        ctx.fillStyle = C.flag; ctx.fillRect(x, y, cw / 4, ch);
        ctx.globalAlpha = 0.6; hatch(ctx, x + cw / 4, y, (cw * 3) / 4, ch);
      } else if (c.f === "alive" && c.packed) {
        for (let j = 0; j < 4; j++) {
          if (j < c.n) { ctx.fillStyle = C.flag; ctx.fillRect(x + (j * cw) / 4 + 0.5, y, cw / 4 - 1, ch); }
          else { ctx.strokeStyle = C.border; ctx.strokeRect(x + (j * cw) / 4 + 0.5, y + 0.5, cw / 4 - 1, ch - 1); }
        }
      } else {
        ctx.fillStyle = colorOf(c.f); ctx.fillRect(x, y, cw, ch);
      }
      ctx.globalAlpha = 1;
      const n = c.n ?? 1;
      if (active && k > 0 && c.e <= k - 1 && k - 1 < c.e + n) {
        ctx.strokeStyle = "#fff"; ctx.lineWidth = 2; ctx.strokeRect(x + 1, y + 1, cw - 2, ch - 2);
      }
    });
    const eff = st.fetched ? Math.round((100 * st.useful) / st.fetched) : 0;
    p.cnt.set("lines", st.loaded.size + " / " + m.total);
    p.cnt.set("bytes", st.fetched + " B");
    p.cnt.set("eff", st.fetched ? eff + "%" : "–");
    p.canvas.setAttribute("aria-label", `${TITLES[m.layout][0]}: ${m.total} cache lines of 64 bytes. After ${k} of ${N} particles reading ${fs.join(", ")}: ${st.loaded.size} lines loaded, ${st.fetched} bytes fetched, ${eff}% of them used.`);
  }
  function draw() {
    panels.forEach((p) => { if (p.k.width > 10) drawPanel(p); });
    readout.textContent = `for i in 0..${N}: read ${PRESETS[mode].f.join(", ")}  ·  particle ${k}/${N}`;
  }
  panels.forEach((p) => B.onResize(p.el, (w) => { p.k.fit(w, p.k.height); drawPanel(p); }));
  draw();
}));

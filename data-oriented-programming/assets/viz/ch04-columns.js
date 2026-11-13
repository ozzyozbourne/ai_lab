/* ch04-columns — pick the fields a loop reads; see bytes fetched vs bytes used for each layout.
 * <div class="figure-body" data-viz="ch04-columns" data-opts='{"reads":"update","access":"seq","writes":true}'></div>
 * Options (all optional, validated):
 *   reads   "update" (pos+vel) | "every" | "pos" or a list of group keys: pos vel phys ids misc   (default "update")
 *   access  "seq" (a loop over all particles) | "random" (one whole record at a random index)      (default "seq")
 *   writes  true if the loop also writes pos (dirty lines are written back)                        (default true)
 *           Choosing a preset sets it: on for "update", off for the read-only "every" and "pos" passes.
 * Model: the chapter's 64-byte particle, 16 four-byte fields (px py pz vx vy vz mass age life size color id
 * flags seed emitter group). Every field has a byte address in each layout; a cache line is 64 bytes.
 *   AoS      i*64 + f*4                  (aligned, one particle = one line)
 *   hot/cold hot[i]: i*24 + f*4 (pos, vel) · cold[i]: i*40 + (f-6)*4, separate arrays
 *   SoA      column f (its own array) + i*4
 *   AoSoA-8  (i/8)*512 + f*32 + (i%8)*4
 * Sequential: distinct lines touched by particles 0..63 divided by 64 (exact: every layout repeats within 64).
 * Random: distinct lines of one record, averaged over records 0..63 (no reuse between random records).
 * Nothing is measured here; the measured numbers are in the chapter's bench charts. */
(window.BookQ ||= []).push((B) => B.viz.register("ch04-columns", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["reads", "access", "writes"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch04-columns: unknown option "${k}" (known: ${KNOWN.join(", ")})`);

  const FIELDS = ["px", "py", "pz", "vx", "vy", "vz", "mass", "age", "life", "size", "color", "id", "flags", "seed", "emitter", "group"];
  const GROUPS = [
    { key: "pos", label: "pos", f: [0, 1, 2], c: "pos" },
    { key: "vel", label: "vel", f: [3, 4, 5], c: "vel" },
    { key: "phys", label: "mass age life size", f: [6, 7, 8, 9], c: "hp" },
    { key: "ids", label: "color id", f: [10, 11], c: "flag" },
    { key: "misc", label: "flags seed emitter group", f: [12, 13, 14, 15], c: "line" },
  ];
  const groupOf = (f) => GROUPS.find((g) => g.f.includes(f));
  const PRESETS = { update: ["pos", "vel"], every: GROUPS.map((g) => g.key), pos: ["pos"] };

  let sel;
  const reads = opts.reads ?? "update";
  if (typeof reads === "string") {
    viz.check(reads in PRESETS, `ch04-columns: "reads" must be one of ${Object.keys(PRESETS).join(", ")} or a list of groups`);
    sel = new Set(PRESETS[reads]);
  } else {
    viz.check(Array.isArray(reads) && reads.length > 0, `ch04-columns: "reads" must be a preset name or a non-empty list`);
    for (const k of reads) viz.check(GROUPS.some((g) => g.key === k), `ch04-columns: unknown group "${k}" (known: ${GROUPS.map((g) => g.key).join(", ")})`);
    sel = new Set(reads);
  }
  let access = opts.access ?? "seq";
  viz.check(access === "seq" || access === "random", `ch04-columns: "access" must be "seq" or "random"`);
  let writes = opts.writes ?? true;
  viz.check(typeof writes === "boolean", `ch04-columns: "writes" must be true or false`);

  /* ---- the address model ---- */
  const FAR = 1 << 24; // separate arrays start far apart, on a line boundary
  const LAYOUTS = [
    { key: "aos", title: "AoS", sub: "[N]Particle, 64 B each", addr: (i, f) => i * 64 + f * 4 },
    { key: "hotcold", title: "Hot/cold", sub: "hot[N] 24 B · cold[N] 40 B",
      addr: (i, f) => (f < 6 ? i * 24 + f * 4 : FAR + i * 40 + (f - 6) * 4) },
    { key: "soa", title: "SoA", sub: "16 columns of f32/u32", addr: (i, f) => f * FAR + i * 4 },
    { key: "aosoa", title: "AoSoA-8", sub: "blocks of 8, 512 B each", addr: (i, f) => Math.floor(i / 8) * 512 + f * 32 + (i % 8) * 4 },
  ];
  const M = 64; // period of every layout above, in particles
  const lineOf = (a) => Math.floor(a / 64);
  const selFields = () => GROUPS.filter((g) => sel.has(g.key)).flatMap((g) => g.f);

  function stats(L) {
    const fs = selFields(), pos = [0, 1, 2];
    const usedB = fs.length * 4;
    if (access === "seq") {
      const lines = new Set(), dirty = new Set();
      for (let i = 0; i < M; i++) {
        for (const f of fs) lines.add(lineOf(L.addr(i, f)));
        if (writes) for (const f of pos) dirty.add(lineOf(L.addr(i, f)));
      }
      return { lines: lines.size / M, dirty: dirty.size / M, used: usedB };
    }
    let lines = 0, dirty = 0;
    for (let i = 0; i < M; i++) {
      lines += new Set(fs.map((f) => lineOf(L.addr(i, f)))).size;
      if (writes) dirty += new Set(pos.map((f) => lineOf(L.addr(i, f)))).size;
    }
    return { lines: lines / M, dirty: dirty / M, used: usedB };
  }

  /* ---- memory strips: the 16 lines that hold particles 0..15 in each layout ---- */
  const SHOW = 16;
  function strip(L) {
    const map = new Map(); // line -> Array(16) of {f, i}
    for (let i = 0; i < SHOW; i++) for (let f = 0; f < 16; f++) {
      const a = L.addr(i, f), l = lineOf(a);
      if (!map.has(l)) map.set(l, new Array(16).fill(null));
      map.get(l)[(a % 64) / 4] = { f, i };
    }
    return [...map.keys()].sort((a, b) => a - b).map((l) => ({ l, cells: map.get(l) }));
  }
  LAYOUTS.forEach((L) => { L.rows = strip(L); });

  /* ---- DOM ---- */
  const C = B.colors();
  const col = (g) => C[g.c];
  const REC = 5; // the record highlighted in random mode
  const panels = LAYOUTS.map((L) => {
    const canvas = h("canvas", { role: "img" });
    const cnt = B.counters([["fetch", "fetched"], ["used", "used"], ["eff", "useful"], ["lines", "lines"], ["wb", "written back"]]);
    const el = h("div", { class: "viz-panel ch04-col-panel" },
      h("p", { class: "viz-title" }, L.title, h("small", {}, L.sub)), canvas, cnt.el);
    return { L, el, canvas, cnt, k: B.canvas(canvas, 300, 120) };
  });

  const chips = h("div", { class: "group ch04-chips", role: "group", "aria-label": "Fields the loop reads" });
  const chipBtns = GROUPS.map((g) => {
    const b = h("button", { type: "button", "aria-pressed": String(sel.has(g.key)), onclick: () => {
      if (sel.has(g.key) && sel.size === 1) return; // keep at least one group
      sel.has(g.key) ? sel.delete(g.key) : sel.add(g.key);
      sync(); draw();
    } }, h("i", { class: "ch04-swatch", style: { background: col(g) } }), g.label);
    chips.append(b);
    return b;
  });
  const wbox = h("input", { type: "checkbox", onchange: () => { writes = wbox.checked; draw(); } });
  wbox.checked = writes;
  const wlabel = h("label", { class: "ch04-check" }, wbox, " loop writes pos");
  const presetNames = ["update", "every", "pos"];
  const presets = B.segmented(["update (pos+vel)", "every field", "pos only"], presetNames.indexOf(typeof reads === "string" ? reads : ""), (i) => {
    sel = new Set(PRESETS[presetNames[i]]);
    writes = presetNames[i] === "update"; // the chapter's update writes pos; the other two passes only read
    wbox.checked = writes;
    sync(); draw();
  }, "Preset field sets");
  const accessSeg = B.segmented(["loop over all", "random records"], access === "seq" ? 0 : 1, (i) => { access = i ? "random" : "seq"; draw(); }, "Access pattern");
  const summary = h("p", { class: "readout ch04-summary", "aria-live": "polite" });

  function sync() {
    chipBtns.forEach((b, j) => b.setAttribute("aria-pressed", String(sel.has(GROUPS[j].key))));
    const key = [...sel].sort().join();
    presets.set(presetNames.findIndex((p) => [...PRESETS[p]].sort().join() === key));
  }

  root.classList.add("ch04-columns");
  root.append(
    h("div", { class: "controls ch04-top" }, h("span", { class: "ch04-lab" }, "The loop reads:"), chips),
    h("div", { class: "controls ch04-top" }, presets, accessSeg, wlabel),
    h("div", { class: "viz-panels ch04-panels" }, panels.map((p) => p.el)),
    summary);

  /* ---- drawing ---- */
  function drawPanel(p, st, maxB) {
    const L = p.L, W = p.k.width, ctx = p.k.ctx, fs = new Set(selFields());
    const perRow = W >= 420 ? 4 : 2, gap = 4, labelW = 0;
    const lw = (W - labelW - gap * (perRow - 1)) / perRow, cw = lw / 16, ch = Math.max(9, Math.min(16, cw * 1.6));
    const rowsN = Math.ceil(L.rows.length / perRow), barY = rowsN * (ch + 6) + 10, barH = 14;
    const H = barY + barH * 2 + 26;
    if (Math.abs(p.k.height - H) > 0.5) p.k.fit(W, H);
    ctx.clearRect(0, 0, W, H);
    const touched = new Set();
    const recLines = new Set();
    for (const r of L.rows) for (const c of r.cells) if (c && fs.has(c.f)) {
      if (access === "seq") touched.add(r.l);
      else if (c.i === REC) recLines.add(r.l);
    }
    L.rows.forEach((r, j) => {
      const x0 = labelW + (j % perRow) * (lw + gap), y = Math.floor(j / perRow) * (ch + 6) + 2;
      const hot = access === "seq" ? touched.has(r.l) : recLines.has(r.l);
      if (hot) { ctx.fillStyle = "rgba(124,196,255,.22)"; ctx.fillRect(x0 - 1.5, y - 1.5, lw + 3, ch + 3); }
      r.cells.forEach((c, q) => {
        const x = x0 + q * cw;
        if (!c) { ctx.strokeStyle = C.border; ctx.strokeRect(x + 0.5, y + 0.5, cw - 1, ch - 1); return; }
        const g = groupOf(c.f);
        let a = fs.has(c.f) ? 1 : 0.22;
        if (access === "random" && c.i !== REC) a *= 0.35;
        ctx.globalAlpha = a; ctx.fillStyle = col(g);
        ctx.fillRect(x + 0.5, y, Math.max(1, cw - 1), ch);
        ctx.globalAlpha = 1;
      });
      if (hot) { ctx.strokeStyle = C.line; ctx.lineWidth = 1.5; ctx.strokeRect(x0 - 1.5, y - 1.5, lw + 3, ch + 3); }
    });
    // bar: bytes fetched (and written back) vs bytes used, per particle or per record
    const fetched = st.lines * 64, wb = st.dirty * 64, sx = (W - 2) / maxB;
    ctx.font = "11px " + C.mono; ctx.textBaseline = "middle";
    ctx.fillStyle = C.elev2 || C.border; ctx.fillRect(0, barY, fetched * sx, barH);
    ctx.fillStyle = C.hit; ctx.fillRect(0, barY, Math.min(st.used, fetched) * sx, barH);
    if (wb > 0) { ctx.fillStyle = C.miss; ctx.globalAlpha = 0.75; ctx.fillRect(0, barY + barH + 3, wb * sx, barH * 0.6); ctx.globalAlpha = 1; }
    ctx.strokeStyle = C.line; ctx.lineWidth = 1; ctx.strokeRect(0.5, barY + 0.5, Math.max(1, fetched * sx - 1), barH - 1);
    ctx.fillStyle = C.text;
    const unit = access === "seq" ? "per particle" : "per record";
    ctx.fillText(`${fmt(fetched)} B read ${unit}${wb ? ` + ${fmt(wb)} B written back` : ""}`, 0, barY + barH * 2 + 14);
    const eff = fetched ? Math.round((100 * st.used) / fetched) : 0;
    p.cnt.set("fetch", fmt(fetched) + " B");
    p.cnt.set("used", st.used + " B");
    p.cnt.set("eff", eff + "%");
    p.cnt.set("lines", access === "seq" ? fmt(st.lines * 1000) + " / 1000 particles" : fmt(st.lines) + " / record");
    p.cnt.set("wb", wb ? fmt(wb) + " B" : "0 B");
    p.canvas.setAttribute("aria-label", `${L.title}: the 16 cache lines holding particles 0 to 15. ` +
      `Reading ${[...sel].join(", ")} ${access === "seq" ? "in a loop" : "for one random record"}: ${fmt(fetched)} bytes fetched ${unit} for ${st.used} bytes used (${eff}%).`);
  }
  const fmt = (x) => (Number.isInteger(x) ? String(x) : x.toFixed(x < 10 ? 2 : 1).replace(/\.?0+$/, ""));

  function draw() {
    const all = panels.map((p) => stats(p.L));
    const maxB = Math.max(...all.map((s) => Math.max(s.lines * 64, s.dirty * 64, s.used)), 1);
    panels.forEach((p, j) => { if (p.k.width > 10) drawPanel(p, all[j], maxB); });
    const cost = all.map((s, j) => [LAYOUTS[j].title, (s.lines + s.dirty) * 64]);
    const best = cost.reduce((a, b) => (b[1] < a[1] ? b : a));
    const worst = cost.reduce((a, b) => (b[1] > a[1] ? b : a));
    summary.textContent = `Model, ${access === "seq" ? "per particle in a loop" : "per random record"}, reads + write-backs: ` +
      cost.map(([t, b]) => `${t} ${fmt(b)} B`).join(" · ") +
      (best[1] < worst[1] ? `. ${worst[0]} moves ${fmt(worst[1] / best[1])}× the bytes of ${best[0]}.` : ". All layouts move the same bytes.");
  }
  panels.forEach((p) => B.onResize(p.el, (w) => { p.k.fit(w, p.k.height); draw(); }));
  sync();
  draw();
}));

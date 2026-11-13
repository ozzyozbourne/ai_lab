/* ch08-false-sharing — two cores each increment their own u64 counter. Where the two counters live decides
 * whether the cache line holding them ping-pongs between the cores' L1 caches.
 * <div class="figure-body" data-viz="ch08-false-sharing" data-opts='{}'></div>
 * Options:
 *   layout    "packed" | "pad64" | "pad128" (default "packed")
 *   writes    total writes, even, 4..32 (default 16): core 0 and core 1 alternate, the worst case for sharing
 *   prefetch  true (default): model the L2 spatial prefetcher, which fetches the other 64-byte line of the
 *             128-byte-aligned pair on a miss, in shared state
 *   interval  seconds per step (default 0.6)
 * Model (MSI, per core, per 64-byte line): a write to a line this core holds Modified is a hit. Otherwise the core
 * sends a read-for-ownership: every other copy is invalidated (a Modified copy is first transferred core-to-core),
 * or the line comes from memory if no core has it. On a miss (state I) with prefetch on, the buddy line is pulled
 * in Shared state; if the other core holds it Modified, that copy is downgraded to Shared. All counters are
 * computed by replaying the writes from the start. */
(window.BookQ ||= []).push((B) => B.viz.register("ch08-false-sharing", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["layout", "writes", "prefetch", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch08-false-sharing: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const LAYOUTS = ["packed", "pad64", "pad128"];
  let lay = LAYOUTS.indexOf(opts.layout ?? "packed");
  viz.check(lay >= 0, 'ch08-false-sharing: "layout" must be "packed", "pad64" or "pad128"');
  const WRITES = opts.writes ?? 16;
  viz.check(Number.isInteger(WRITES) && WRITES >= 4 && WRITES <= 32 && WRITES % 2 === 0, 'ch08-false-sharing: "writes" must be an even integer 4..32');
  let prefetch = opts.prefetch ?? true;
  const LINES = 4; // memory shown: 4 × 64 B = two 128-byte pairs
  // which line and which u64 slot (0..7) each core's counter occupies
  const place = () => [[{ line: 0, slot: 0 }, { line: 0, slot: 1 }], [{ line: 0, slot: 0 }, { line: 1, slot: 0 }], [{ line: 0, slot: 0 }, { line: 2, slot: 0 }]][lay];
  let k = 0;

  function model(steps) {
    const S = [new Array(LINES).fill("I"), new Array(LINES).fill("I")];
    const st = { S, hits: 0, inval: 0, xfer: 0, mem: 0, snoop: 0, counts: [0, 0], ev: null };
    const P = place();
    for (let i = 0; i < steps; i++) {
      const c = i % 2, o = 1 - c, L = P[c].line, ev = { core: c, line: L, kind: "hit", buddy: null };
      const before = S[c][L];
      if (before === "M") { st.hits++; }
      else {
        if (S[o][L] !== "I") {
          if (S[o][L] === "M") { st.xfer++; ev.kind = "transfer"; } else ev.kind = before === "S" ? "upgrade" : "rfo";
          S[o][L] = "I"; st.inval++;
        } else if (before === "I") { st.mem++; ev.kind = "memory"; }
        else ev.kind = "upgrade";
        S[c][L] = "M";
        const bud = L ^ 1;
        if (prefetch && before === "I" && S[c][bud] === "I") {
          if (S[o][bud] === "M") { S[o][bud] = "S"; st.snoop++; ev.buddy = "snoop"; } else ev.buddy = "fill";
          S[c][bud] = "S";
        }
      }
      st.counts[c]++;
      st.ev = ev;
    }
    return st;
  }

  const C = B.colors();
  const stateColor = (s) => (s === "M" ? C.hit : s === "S" ? C.flag : C.dim);
  const chart = B.chart(root, render);
  const say = h("output", { class: "ch08-say", "aria-live": "polite" }, "–");
  const cnt = B.counters([["w", "writes"], ["hit", "L1 hits", "good"], ["inv", "invalidations", "bad"], ["x", "core→core transfers", "bad"], ["mem", "from memory"], ["sn", "prefetch snoops"]]);

  function render(w) {
    const st = model(k), narrow = w < 600, P = place(), pad = 6;
    const T = (x, y, s, o = {}) => B.svg("text", Object.assign({ x, y, fill: C.text, "font-family": C.mono, "font-size": narrow ? 10.5 : 12 }, o), s);
    const coreW = narrow ? (w - 3 * pad) / 2 : Math.min(260, (w - 60) / 2), lineH = 24, coreH = 34 + LINES * (lineH + 4);
    const H = coreH + 150;
    const svg = B.svg("svg", { viewBox: `0 0 ${w} ${H}`, width: w, height: H, role: "img",
      "aria-label": `Layout ${LAYOUTS[lay]}: after ${k} writes, ${st.inval} invalidations and ${st.xfer} core-to-core transfers` });
    const cx = [pad, w - pad - coreW];
    for (let c = 0; c < 2; c++) {
      const x = cx[c], active = st.ev && st.ev.core === c;
      svg.append(B.svg("rect", { x, y: 4, width: coreW, height: coreH, rx: 8, fill: C.elev, stroke: active ? C.accent : C.border, "stroke-width": active ? 2.5 : 1.5 }));
      svg.append(T(x + 8, 22, narrow ? `core ${c} · c${c}=${st.counts[c]}` : `core ${c} L1 · counter ${c} = ${st.counts[c]}`, { fill: c === 0 ? C.pos : C.vel, "font-weight": 700 }));
      for (let L = 0; L < LINES; L++) {
        const y = 32 + L * (lineH + 4), s = st.S[c][L], mine = P[c].line === L;
        svg.append(B.svg("rect", { x: x + 8, y, width: coreW - 16, height: lineH, rx: 4, fill: s === "I" ? "none" : C.elev2,
          stroke: stateColor(s), "stroke-width": s === "M" ? 2 : 1, "stroke-dasharray": s === "I" ? "3 4" : null }));
        svg.append(T(x + 14, y + 16, `line ${L}`, { fill: C.dim }));
        svg.append(T(x + coreW - 14, y + 16, s === "M" ? "M modified" : s === "S" ? "S shared" : "I invalid", { fill: stateColor(s), "text-anchor": "end", "font-weight": s === "I" ? 400 : 700 }));
        if (mine && !narrow) svg.append(T(x + 70, y + 16, "◀ mine", { fill: c === 0 ? C.pos : C.vel }));
      }
    }
    // the event arrow between the two caches
    if (st.ev && ["transfer", "upgrade", "rfo"].includes(st.ev.kind)) {
      const y = 32 + st.ev.line * (lineH + 4) + lineH / 2, from = st.ev.core === 0 ? cx[1] + 6 : cx[0] + coreW - 6, to = st.ev.core === 0 ? cx[0] + coreW - 6 : cx[1] + 6;
      if (!narrow) {
        svg.append(B.svg("line", { x1: from, y1: y, x2: to, y2: y, stroke: C.miss, "stroke-width": 3, "marker-end": "url(#ch08fs-arrow)" }));
      }
    }
    const defs = B.svg("defs", {}, B.svg("marker", { id: "ch08fs-arrow", viewBox: "0 0 10 10", refX: 9, refY: 5, markerWidth: 6, markerHeight: 6, orient: "auto-start-reverse" },
      B.svg("path", { d: "M0,0 L10,5 L0,10 z", fill: C.miss })));
    svg.append(defs);
    // memory: 4 lines × 8 u64 slots, pairs bracketed
    const my = coreH + 30, slotW = (w - 2 * pad) / (LINES * 8), slotH = 26;
    svg.append(T(pad, my - 8, narrow ? "memory: 4 × 64 B lines of 8 u64" : "memory: 4 lines of 64 B = 8 × u64 each; brackets = 128-byte pairs", { fill: C.dim }));
    for (let L = 0; L < LINES; L++) {
      for (let s = 0; s < 8; s++) {
        const x = pad + (L * 8 + s) * slotW;
        const who = P.findIndex((p) => p.line === L && p.slot === s);
        svg.append(B.svg("rect", { x: x + 0.5, y: my, width: slotW - 1, height: slotH, fill: who < 0 ? "none" : who === 0 ? C.pos : C.vel, opacity: who < 0 ? 1 : 0.9,
          stroke: C.border, "stroke-width": s === 0 ? 2 : 0.6 }));
        if (who >= 0 && slotW >= 18) svg.append(T(x + slotW / 2, my + 17, "c" + who, { "text-anchor": "middle", fill: C.bg, "font-weight": 700, "font-size": narrow ? 9 : 11 }));
      }
      svg.append(T(pad + L * 8 * slotW + 4 * slotW, my + slotH + 15, `line ${L}`, { "text-anchor": "middle", fill: C.dim }));
    }
    for (let p = 0; p < LINES / 2; p++) {
      const x1 = pad + p * 16 * slotW + 2, x2 = pad + (p + 1) * 16 * slotW - 2, yb = my + slotH + 24;
      svg.append(B.svg("path", { d: `M${x1},${yb} v6 H${x2} v-6`, stroke: C.flag, fill: "none", "stroke-width": 1.5 }));
      svg.append(T((x1 + x2) / 2, yb + 20, narrow ? "128 B pair" : "128-byte pair", { "text-anchor": "middle", fill: C.flag }));
    }
    return svg;
  }

  function draw() {
    const st = model(k);
    chart.redraw();
    cnt.set("w", `${k}/${WRITES}`); cnt.set("hit", st.hits); cnt.set("inv", st.inval); cnt.set("x", st.xfer); cnt.set("mem", st.mem); cnt.set("sn", prefetch ? st.snoop : "off");
    const e = st.ev;
    say.dataset.kind = e && ["transfer", "upgrade", "rfo"].includes(e.kind) ? "bad" : e && e.kind === "hit" ? "good" : "";
    say.textContent = !e ? "Each core will increment only its own counter. Press Play or Step."
      : `Core ${e.core} writes counter ${e.core} (line ${e.line}): ` + ({
        hit: "the line is already Modified in its own L1, so this is a hit. No other core hears about it.",
        memory: "no core has the line, so it comes from memory (a cold miss, paid once).",
        transfer: `core ${1 - e.core} holds the line Modified, so it is transferred core-to-core and core ${1 - e.core}'s copy is invalidated. Nothing logically shared, and the line moved anyway.`,
        rfo: `core ${1 - e.core} has a Shared copy (the prefetcher pulled it in), so this read-for-ownership invalidates it.`,
        upgrade: `this core only has a Shared copy, so it must invalidate core ${1 - e.core}'s copy before writing.`,
      })[e.kind] + (e.buddy === "snoop" ? ` The prefetcher also pulls line ${e.line ^ 1} (same 128-byte pair) and downgrades core ${1 - e.core}'s copy to Shared.` : e.buddy === "fill" ? ` The prefetcher also pulls line ${e.line ^ 1}, its 128-byte buddy, as Shared.` : "");
  }

  const player = B.player(root, {
    step: () => (k < WRITES ? (k++, true) : false), back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; }, atEnd: () => k === WRITES, draw, interval: opts.interval ?? 0.6,
  });
  const seg = B.segmented(["same line", "padded 64 B", "padded 128 B"], lay, (i) => { lay = i; draw(); }, "Counter layout");
  const pf = B.segmented(["prefetch pairs", "no prefetch"], prefetch ? 0 : 1, (i) => { prefetch = i === 0; draw(); }, "Spatial prefetcher");
  root.append(say, cnt.el, h("div", { class: "controls" }, player.el, seg, pf));
  draw();
}));

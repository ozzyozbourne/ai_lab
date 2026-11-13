/* ch07-existence — "alive" as a flag scanned with skips, vs membership in dense alive/dead tables with
 * rows moved by swap-and-pop.
 * <div class="figure-body" data-viz="ch07-existence" data-opts='{}'></div>
 * Options:
 *   n         entities 8..24 (default 16)
 *   seed      PRNG seed (default 3)
 *   perLine   entities per 64-byte cache line in the flag layout (default 3, i.e. 20-byte Entity)
 *   interval  seconds per step while playing (default 0.6)
 * Model: a fixed script of kills (entity ids). "Flag" mode: each step is one update pass position; the
 * cursor visits every slot, reads its flag (a branch), and skips dead ones. "Tables" mode: each step is
 * one kill: the row moves from alive to dead with swap-and-pop. Counters are computed from the state:
 * rows visited, branches, lines touched by one update pass, bytes read. */
(window.BookQ ||= []).push((B) => B.viz.register("ch07-existence", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["n", "seed", "perLine", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch07-existence: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const N = opts.n ?? 16;
  viz.check(Number.isInteger(N) && N >= 8 && N <= 24, 'ch07-existence: "n" must be an integer 8..24');
  const PER = opts.perLine ?? 3;
  viz.check(Number.isInteger(PER) && PER >= 1 && PER <= 8, 'ch07-existence: "perLine" must be an integer 1..8');
  const ENT = 20, BODY = 16;
  // kill script: half the entities, in random order
  const r = B.rng(opts.seed ?? 3);
  const ids = Array.from({ length: N }, (_, i) => i);
  for (let i = N - 1; i > 0; i--) { const j = r.int(i + 1); [ids[i], ids[j]] = [ids[j], ids[i]]; }
  const KILLS = ids.slice(0, Math.floor(N / 2));
  const NAMES = "ABCDEFGHIJKLMNOPQRSTUVWX".split("");

  let mode = 1, k = 0; // tables mode: k kills applied; flag mode: k = cursor position after all kills
  function tables(upto) {
    const alive = ids.slice().sort((a, b) => a - b), dead = [];
    let last = null;
    for (let s = 0; s < upto; s++) {
      const id = KILLS[s], row = alive.indexOf(id), lastRow = alive.length - 1;
      const moved = alive[lastRow];
      alive[row] = moved; alive.pop(); dead.push(id);
      last = { id, row, moved: row === lastRow ? null : moved, from: lastRow };
    }
    return { alive, dead, last };
  }
  const deadSet = new Set(KILLS);
  const steps = () => (mode === 0 ? N : KILLS.length);

  const C = B.colors();
  const note = h("p", { class: "ch07-result", "aria-live": "polite" }, "–");
  const cnt = B.counters([["step", "step"], ["visit", "rows visited"], ["br", "data branches", "bad"], ["lines", "lines per pass"], ["bytes", "bytes per pass"]]);
  const chart = B.chart(root, render);

  function cell(svg, x, y, w, hh, id, o) {
    svg.append(B.svg("rect", { x, y, width: w - 3, height: hh, rx: 4, fill: o.dead ? C.elev2 : C.pos, "fill-opacity": o.dead ? 1 : 0.85,
      stroke: o.hl ? C.heading : o.dead ? C.border : C.pos, "stroke-width": o.hl ? 2.5 : 1, "stroke-dasharray": o.dead ? "4 3" : null }));
    svg.append(B.svg("text", { x: x + (w - 3) / 2, y: y + hh / 2 + 4, "text-anchor": "middle", "font-family": C.mono, "font-size": w < 20 ? 10 : 12,
      fill: o.dead ? C.dim : "#06121f", "font-weight": 700 }, NAMES[id] + (o.flag != null ? (o.flag ? "·1" : "·0") : "")));
  }

  function render(w) {
    const pad = 6, narrow = w < 600;
    const perRow = narrow ? Math.ceil(N / 2) : N, cw = (w - 2 * pad) / perRow, ch = 30;
    const T = (x, y, s, o = {}) => B.svg("text", Object.assign({ x, y, fill: C.dim, "font-family": C.mono, "font-size": 11 }, o), s);
    if (mode === 0) {
      const rows = Math.ceil(N / perRow), rowH = ch + 34, H = 20 + rows * rowH + 8;
      const svg = B.svg("svg", { viewBox: `0 0 ${w} ${H}`, width: w, height: H, role: "img",
        "aria-label": `Flag layout: ${N} entities, ${N - deadSet.size} alive; cursor at ${k}` });
      svg.append(T(pad, 12, narrow ? `Entity[${N}] + alive flag (${ENT} B, ~${PER}/line)` : `Entity[${N}] with alive flag (${ENT} B each, ~${PER} per 64-B line)`));
      for (let i = 0; i < N; i++) {
        const rr = Math.floor(i / perRow), c = i % perRow, x = pad + c * cw, y = 20 + rr * rowH;
        const dead = deadSet.has(i), seen = i < k;
        cell(svg, x, y, cw, ch, i, { dead, flag: !dead, hl: i === k - 1 });
        if (seen) svg.append(T(x + (cw - 3) / 2, y + ch + 14, dead ? "skip" : "upd", { "text-anchor": "middle", fill: dead ? C.miss : C.hit, "font-size": 10 }));
        // cache line bracket
        if (i % PER === 0) {
          const end = Math.min(i + PER, N) - 1, sameRow = Math.floor(end / perRow) === rr;
          const x2 = sameRow ? pad + (end % perRow) * cw + cw - 3 : pad + perRow * cw - 3;
          const touched = i < k;
          svg.append(B.svg("line", { x1: x, x2, y1: y + ch + 22, y2: y + ch + 22, stroke: touched ? C.line : C.border, "stroke-width": touched ? 3 : 1.5 }));
        }
      }
      return svg;
    }
    const st = tables(k);
    const H = 20 + 2 * (ch + 30) + 10;
    const svg = B.svg("svg", { viewBox: `0 0 ${w} ${H}`, width: w, height: H, role: "img",
      "aria-label": `Tables: alive ${st.alive.map((i) => NAMES[i]).join(" ")}; dead ${st.dead.map((i) => NAMES[i]).join(" ")}` });
    const ox = pad + (narrow ? 44 : 52), lenW = narrow ? 44 : 56;
    const cw2 = Math.min(40, (w - ox - pad - lenW) / N);
    const drawRow = (label, list, y, dead) => {
      svg.append(T(pad, y + ch / 2 + 4, label, { fill: C.heading, "font-weight": 700, "font-size": narrow ? 10 : 11 }));
      list.forEach((id, row) => cell(svg, ox + row * cw2, y, cw2, ch, id, { dead, hl: st.last && (dead ? id === st.last.id : id === st.last.moved) }));
      svg.append(T(ox + list.length * cw2 + 4, y + ch / 2 + 4, `len ${list.length}`));
    };
    svg.append(T(pad, 12, narrow ? `alive/dead tables of Body (${BODY} B)` : `two tables of Body (${BODY} B, no flag); kill = swap-and-pop + push`));
    drawRow("alive", st.alive, 20, false);
    drawRow("dead", st.dead, 20 + ch + 30, true);
    if (st.last && st.last.moved != null) {
      const x1 = ox + st.last.from * cw2 + cw2 / 2, x2 = ox + st.last.row * cw2 + cw2 / 2, y = 20 + ch + 4;
      svg.append(B.svg("path", { d: `M${x1},${y} C${x1},${y + 16} ${x2},${y + 16} ${x2},${y + 2}`, fill: "none", stroke: C.flag, "stroke-width": 2 }));
      svg.append(B.svg("path", { d: `M${x2 - 4},${y + 8} L${x2},${y + 1} L${x2 + 4},${y + 8}`, fill: "none", stroke: C.flag, "stroke-width": 2 }));
    }
    return svg;
  }

  function draw() {
    chart.redraw();
    const live = N - deadSet.size;
    if (mode === 0) {
      const visited = k, br = k, lines = Math.ceil(k / PER);
      cnt.set("step", `${k}/${N}`); cnt.set("visit", visited); cnt.set("br", br);
      cnt.set("lines", lines); cnt.set("bytes", B.fmtInt(k * ENT) + " B");
      note.textContent = k === 0 ? `All kills applied: ${live} of ${N} alive, scattered. Step the update pass: every slot is loaded to test its flag.`
        : k === N ? `Pass done: ${N} flags tested to update ${live} entities. Every line was fetched, dead or not, and each test was a ${live}/${N} coin flip for the predictor.`
        : `Slot ${NAMES[k - 1]}: flag ${deadSet.has(k - 1) ? "0 → skip, but its line is already loaded" : "1 → update"}.`;
    } else {
      const st = tables(k), lines = Math.ceil((st.alive.length * BODY) / 64);
      cnt.set("step", `${k}/${KILLS.length} kills`); cnt.set("visit", st.alive.length); cnt.set("br", 0);
      cnt.set("lines", lines); cnt.set("bytes", B.fmtInt(st.alive.length * BODY) + " B");
      note.textContent = !st.last ? `Everyone starts in the alive table. Step to kill entities: each kill moves one row out.`
        : `Kill ${NAMES[st.last.id]}: row ${st.last.row} → dead table; ` +
          (st.last.moved != null ? `last row ${NAMES[st.last.moved]} moves from ${st.last.from} into the hole.` : `it was the last row, nothing moves.`) +
          ` The update loop now visits ${st.alive.length} rows and tests nothing.`;
    }
  }

  const player = B.player(root, {
    step: () => (k < steps() ? (k++, true) : false), back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; }, atEnd: () => k === steps(), draw, interval: opts.interval ?? 0.6, autoplay: false,
  });
  const seg = B.segmented(["flag + if", "alive/dead tables"], mode, (i) => { mode = i; k = 0; player.pause(); draw(); }, "Layout");
  root.append(note, cnt.el, h("div", { class: "controls" }, player.el, seg));
  draw();
}));

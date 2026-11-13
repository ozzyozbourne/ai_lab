/* ch09-archetypes — archetype storage: one table per component combination, SoA columns with aligned rows.
 * Adding or removing a component moves the entity's whole row to another table (swap-and-pop in the source,
 * append in the destination). A query visits only the tables whose type contains every queried component.
 * <div class="figure-body" data-viz="ch09-archetypes" data-opts='{}'></div>
 * Options:
 *   interval  seconds per step while playing (default 1.2)
 * Model: the state is a replay of an operation log of {add|remove, entity, component}. Bytes moved use the
 * chapter's component sizes (Entity 8 B, Pos 8 B, Vel 8 B, Hp 4 B). The query counters compare the archetype
 * query (tables matched, rows visited, no probes) with a sparse-set query over the same data (iterate the
 * smallest set, probe the others), both computed from the current state. */
(window.BookQ ||= []).push((B) => B.viz.register("ch09-archetypes", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch09-archetypes: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const COMP = ["P", "V", "H"], NAME = { P: "Pos", V: "Vel", H: "Hp" }, SIZE = { P: 8, V: 8, H: 4 }, ENT = 8;
  const TYPES = ["P", "PV", "PH", "PVH"]; // the combinations this world can reach (every entity has Pos)
  const START = { a: "PV", b: "P", c: "PV", d: "PH", e: "P", f: "PVH", g: "PV", h: "P" };
  const STORY = [
    { t: "add", e: "b", c: "V" }, { t: "add", e: "e", c: "H" }, { t: "rem", e: "c", c: "V" },
    { t: "add", e: "d", c: "V" }, { t: "rem", e: "f", c: "H" }, { t: "add", e: "h", c: "V" },
  ];
  const QUERIES = [["P", "V"], ["P", "V", "H"], ["P", "H"]];
  let ops = STORY.slice(), k = 0, q = 0, sel = "a";
  const typeOf = (set) => COMP.filter((c) => set.has(c)).join("");

  function replay(n) {
    const tables = Object.fromEntries(TYPES.map((t) => [t, []]));
    for (const [e, t] of Object.entries(START)) tables[t].push(e);
    let bytes = 0, moves = 0, last = null;
    const where = (e) => TYPES.find((t) => tables[t].includes(e));
    for (let i = 0; i < n; i++) {
      const op = ops[i], src = where(op.e), set = new Set(src);
      if (op.t === "add") set.add(op.c); else set.delete(op.c);
      const dst = typeOf(set);
      if (dst === src || !tables[dst]) { last = { kind: "noop", e: op.e, text: `${op.t === "add" ? "add" : "remove"} ${NAME[op.c]} on ${op.e}: no change of type` }; continue; }
      const rows = tables[src], row = rows.indexOf(op.e), lastE = rows[rows.length - 1];
      rows[row] = lastE; rows.pop();
      tables[dst].push(op.e);
      const shared = [...src].filter((c) => set.has(c));
      const b = ENT + shared.reduce((s, c) => s + SIZE[c], 0) + (op.t === "add" ? SIZE[op.c] : 0);
      bytes += b; moves += 1;
      last = { kind: "move", e: op.e, src, dst, row, filled: lastE !== op.e ? lastE : null, bytes: b,
        text: `${op.t === "add" ? "add" : "remove"} ${NAME[op.c]} on ${op.e}: row moves {${[...src].join(",")}} → {${[...dst].join(",")}} (${b} B copied)` +
          (lastE !== op.e ? `; ${lastE} swaps into row ${row} of the old table` : "") };
    }
    return { tables, bytes, moves, last, where };
  }

  const C = B.colors();
  const chart = B.chart(root, render);
  function render(w) {
    const st = replay(k), narrow = w < 600, pad = 6, gap = 10;
    const cols = narrow ? 1 : 2, tw = (w - 2 * pad - (cols - 1) * gap) / cols, rh = 24, hh = 46;
    const maxRows = Math.max(4, ...TYPES.map((t) => st.tables[t].length));
    const th = hh + maxRows * rh + 20;
    const H = Math.ceil(TYPES.length / cols) * (th + gap) + 4;
    const svg = B.svg("svg", { viewBox: `0 0 ${w} ${H}`, width: w, height: H, role: "img",
      "aria-label": "Archetype tables: " + TYPES.map((t) => `{${[...t].join(",")}} ${st.tables[t].length} rows`).join("; ") });
    const T = (x, y, s, o = {}) => B.svg("text", Object.assign({ x, y, fill: C.text, "font-family": C.mono, "font-size": 12 }, o), s);
    const query = QUERIES[q], L = st.last;
    TYPES.forEach((t, i) => {
      const x = pad + (i % cols) * (tw + gap), y = 2 + Math.floor(i / cols) * (th + gap);
      const match = query.every((c) => t.includes(c));
      const isSrc = L && L.kind === "move" && L.src === t, isDst = L && L.kind === "move" && L.dst === t;
      svg.append(B.svg("rect", { x, y, width: tw, height: th, rx: 8, fill: match ? C.elev2 : "none",
        stroke: match ? C.hit : C.border, "stroke-width": match ? 2.5 : 1, opacity: match ? 1 : 0.75 }));
      svg.append(T(x + 10, y + 18, `{${[...t].map((c) => NAME[c]).join(", ")}}`, { fill: C.heading, "font-weight": 700 }),
        T(x + tw - 10, y + 18, match ? "matches query" : `${st.tables[t].length} row${st.tables[t].length === 1 ? "" : "s"}`, { fill: match ? C.hit : C.dim, "text-anchor": "end", "font-size": 11 }));
      // column strips: entity, then one per component in the type
      const colsHere = ["E", ...t], cw = (tw - 20) / colsHere.length;
      colsHere.forEach((c, j) => {
        const cx = x + 10 + j * cw;
        svg.append(T(cx + 4, y + 38, c === "E" ? "entity" : NAME[c], { fill: c === "E" ? C.dim : c === "P" ? C.pos : c === "V" ? C.vel : C.hp, "font-size": 11 }));
      });
      st.tables[t].forEach((e, r) => {
        const ry = y + hh + r * rh, moved = isDst && L.e === e, filled = isSrc && L.filled === e && r === L.row;
        colsHere.forEach((c, j) => {
          const cx = x + 10 + j * cw, col = c === "E" ? C.dim : c === "P" ? C.pos : c === "V" ? C.vel : C.hp;
          const cell = B.svg("rect", { x: cx + 1, y: ry, width: cw - 2, height: rh - 3, rx: 3, fill: col, opacity: moved || filled ? 0.55 : 0.22,
            stroke: moved ? C.accent : filled ? C.flag : "none", "stroke-width": 2, style: "cursor:pointer" });
          cell.addEventListener("click", () => { sel = e; draw(); });
          svg.append(cell);
          if (c === "E") svg.append(T(cx + 6, ry + 15, e + (e === sel ? " ◂" : ""), { fill: C.heading, "font-weight": 700, "pointer-events": "none" }));
        });
      });
      if (isSrc) svg.append(T(x + 10, y + th - 4, `− ${L.e} left (swap-and-pop)`, { fill: C.miss, "font-size": 10.5 }));
      if (isDst) svg.append(T(x + 10, y + th - 4, `+ ${L.e} appended`, { fill: C.accent, "font-size": 10.5 }));
    });
    return svg;
  }

  const result = h("output", { class: "ch09-result", "aria-live": "polite" }, "–");
  const cnt = B.counters([["moves", "row moves"], ["bytes", "bytes copied", "bad"], ["tables", "tables matched", "good"],
    ["rows", "rows visited"], ["probes", "sparse-set probes for the same query"]]);
  const seg = B.segmented(QUERIES.map((x) => "query " + x.map((c) => NAME[c]).join("+")), 0, (i) => { q = i; draw(); }, "Query");
  const push = (t, c) => { ops = ops.slice(0, k).concat({ t, e: sel, c }); k++; player.pause(); draw(); };
  const btns = [["add", "V", "Add Vel"], ["rem", "V", "Remove Vel"], ["add", "H", "Add Hp"], ["rem", "H", "Remove Hp"]]
    .map(([t, c, label]) => { const b = h("button", { type: "button", onclick: () => push(t, c) }, label); b.op = [t, c]; return b; });

  function draw() {
    const st = replay(k);
    chart.redraw();
    result.textContent = st.last ? st.last.text : "Eight entities in four tables. Press Play, or tap a row and add or remove a component.";
    result.dataset.kind = st.last ? st.last.kind : "";
    const query = QUERIES[q], matched = TYPES.filter((t) => query.every((c) => t.includes(c)));
    const rows = matched.reduce((s, t) => s + st.tables[t].length, 0);
    const setSize = (c) => TYPES.filter((t) => t.includes(c)).reduce((s, t) => s + st.tables[t].length, 0);
    const smallest = Math.min(...query.map(setSize));
    cnt.set("moves", st.moves); cnt.set("bytes", st.bytes + " B");
    cnt.set("tables", matched.length + " of " + TYPES.length); cnt.set("rows", rows + " (all match)");
    cnt.set("probes", `${smallest} rows × ${query.length - 1} = ${smallest * (query.length - 1)}`);
    const cur = st.where(sel);
    for (const b of btns) b.disabled = b.op[1] === "P" || (b.op[0] === "add") === cur.includes(b.op[1]);
  }

  const player = B.player(root, {
    step: () => (k < ops.length ? (k++, true) : false), back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; ops = STORY.slice(); }, atEnd: () => k === ops.length, draw,
    interval: opts.interval ?? 1.2, loop: false,
  });
  root.append(result, cnt.el, h("div", { class: "controls" }, player.el, seg),
    h("div", { class: "controls" }, h("div", { class: "group", role: "group", "aria-label": "Change the selected entity" }, ...btns)));
  draw();
}));

/* ch09-sparse-set — one sparse set: a sparse array indexed by entity id, a dense array of ids and a
 * packed data array. Insert appends, remove swaps the last element into the hole and pops, lookup is
 * two dependent loads (sparse, then dense to confirm).
 * <div class="figure-body" data-viz="ch09-sparse-set" data-opts='{}'></div>
 * Options:
 *   ids       size of the id universe shown, 8..16 (default 12)
 *   interval  seconds per step while playing (default 1.1)
 * Model: the state is a replay of an operation log. The player steps through a scripted story; the
 * Insert / Remove / Lookup buttons append operations on the selected id at the current position, so Back
 * and Reset work for both. Every number on screen is computed by replaying the log. */
(window.BookQ ||= []).push((B) => B.viz.register("ch09-sparse-set", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["ids", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch09-sparse-set: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const U = opts.ids ?? 12;
  viz.check(Number.isInteger(U) && U >= 8 && U <= 16, 'ch09-sparse-set: "ids" must be an integer 8..16');
  const STORY = [
    { t: "ins", id: 3 }, { t: "ins", id: 7 }, { t: "ins", id: 1 }, { t: "ins", id: 9 }, { t: "ins", id: 4 },
    { t: "get", id: 7 }, { t: "rem", id: 3 }, { t: "get", id: 3 }, { t: "get", id: 4 }, { t: "rem", id: 4 },
    { t: "ins", id: 10 }, { t: "get", id: 2 },
  ].filter((o) => o.id < U);
  let ops = STORY.slice(), k = 0, sel = 7;

  // ---- the model: replay ops[0..n) ----
  function replay(n) {
    const sparse = new Array(U).fill(null), dense = [], data = [];
    let last = null, loads = 0, moved = 0, nextVal = 10;
    for (let i = 0; i < n; i++) {
      const op = ops[i], id = op.id, d = sparse[id];
      const has = d !== null && dense[d] === id;
      if (op.t === "ins") {
        if (has) { last = { kind: "noop", id, text: `insert ${id}: already present at dense[${d}], value overwritten` }; continue; }
        sparse[id] = dense.length; dense.push(id); data.push(nextVal); nextVal += 10;
        last = { kind: "ins", id, at: dense.length - 1, text: `insert ${id}: sparse[${id}] = ${dense.length - 1}, push ${id} onto dense, push its value onto data` };
      } else if (op.t === "rem") {
        if (!has) { loads += 1; last = { kind: "miss", id, text: `remove ${id}: sparse[${id}] is empty, nothing to do` }; continue; }
        const lastPos = dense.length - 1, lastId = dense[lastPos];
        loads += 2;
        if (lastPos !== d) { dense[d] = lastId; data[d] = data[lastPos]; sparse[lastId] = d; moved += 1; }
        dense.pop(); data.pop(); sparse[id] = null;
        last = lastPos !== d
          ? { kind: "rem", id, at: d, from: lastPos, movedId: lastId, text: `remove ${id}: last element (id ${lastId}) moves from dense[${lastPos}] into the hole at dense[${d}]; sparse[${lastId}] = ${d}; pop` }
          : { kind: "rem", id, at: d, from: d, movedId: null, text: `remove ${id}: it is already last, so just pop` };
      } else {
        if (d === null) { loads += 1; last = { kind: "miss", id, text: `lookup ${id}: sparse[${id}] is empty → not present (1 load)` }; continue; }
        loads += 2;
        last = has ? { kind: "hit", id, at: d, text: `lookup ${id}: sparse[${id}] = ${d}, dense[${d}] == ${id} → value ${data[d]} (2 dependent loads)` }
          : { kind: "miss", id, at: d, text: `lookup ${id}: dense[${d}] ≠ ${id} → not present` };
      }
    }
    return { sparse, dense, data, last, loads, moved };
  }

  const C = B.colors();
  // tween for the element that swap-and-pop moves (0 → 1), skipped under reduced motion
  let tw = 1;
  const anim = B.loop(root, (dt) => { tw = Math.min(1, tw + dt / 0.45); chart.redraw(); return tw < 1; }, { autoplay: false });
  const kick = () => { if (B.reducedMotion()) { tw = 1; return; } tw = 0; anim.play(); };

  const chart = B.chart(root, render);
  function render(w) {
    const st = replay(k), narrow = w < 600, pad = 8;
    const cw = Math.min(54, (w - 2 * pad - 70) / U), ch = 34, x0 = pad + (narrow ? 52 : 70);
    const rowY = { sparse: 34, dense: 126, data: 126 + ch + 8 };
    const H = rowY.data + ch + 30;
    const svg = B.svg("svg", { viewBox: `0 0 ${w} ${H}`, width: w, height: H, role: "img",
      "aria-label": `Sparse set with ${st.dense.length} members; dense order ${st.dense.join(", ") || "empty"}` });
    const T = (x, y, s, o = {}) => B.svg("text", Object.assign({ x, y, fill: C.text, "font-family": C.mono, "font-size": narrow ? 10.5 : 12 }, o), s);
    const L = st.last;
    const cx = (i) => x0 + i * cw;
    svg.append(T(pad, rowY.sparse + ch / 2 + 4, "sparse", { fill: C.dim }), T(pad, rowY.dense + ch / 2 + 4, "dense", { fill: C.dim }),
      T(pad, rowY.data + ch / 2 + 4, "data", { fill: C.dim }));
    // sparse row, indexed by id
    for (let id = 0; id < U; id++) {
      const v = st.sparse[id], focus = L && L.id === id, isSel = id === sel;
      const stroke = focus ? (L.kind === "miss" ? C.miss : L.kind === "hit" ? C.hit : C.accent) : isSel ? C.heading : C.border;
      const r = B.svg("rect", { x: cx(id) + 1, y: rowY.sparse, width: cw - 2, height: ch, rx: 4, fill: v === null ? "none" : C.elev2,
        stroke, "stroke-width": focus || isSel ? 2.5 : 1, style: "cursor:pointer" });
      r.addEventListener("click", () => { sel = id; draw(); });
      svg.append(r, T(cx(id) + cw / 2, rowY.sparse - 6, String(id), { fill: isSel ? C.heading : C.dim, "text-anchor": "middle", "font-size": 10 }),
        T(cx(id) + cw / 2, rowY.sparse + ch / 2 + 4, v === null ? "·" : String(v), { "text-anchor": "middle", fill: v === null ? C.dim : C.flag, "font-weight": 700, "pointer-events": "none" }));
    }
    // dense + data rows
    const n = st.dense.length;
    for (let i = 0; i < Math.max(n + 1, 1) && i < U; i++) {
      const live = i < n;
      svg.append(B.svg("rect", { x: cx(i) + 1, y: rowY.dense, width: cw - 2, height: ch, rx: 4, fill: live ? C.elev2 : "none", stroke: live ? C.pos : C.border, "stroke-dasharray": live ? null : "3 4" }),
        B.svg("rect", { x: cx(i) + 1, y: rowY.data, width: cw - 2, height: ch, rx: 4, fill: live ? C.elev2 : "none", stroke: live ? C.vel : C.border, "stroke-dasharray": live ? null : "3 4" }),
        T(cx(i) + cw / 2, rowY.data + ch + 14, String(i), { fill: C.dim, "text-anchor": "middle", "font-size": 10 }));
    }
    for (let i = 0; i < n; i++) {
      let x = cx(i);
      if (L && L.kind === "rem" && L.movedId !== null && i === L.at) x = cx(L.from) + (cx(L.at) - cx(L.from)) * ease(tw);
      svg.append(T(x + cw / 2, rowY.dense + ch / 2 + 4, String(st.dense[i]), { "text-anchor": "middle", fill: C.heading, "font-weight": 700 }),
        T(x + cw / 2, rowY.data + ch / 2 + 4, String(st.data[i]), { "text-anchor": "middle", fill: C.text }));
    }
    // arrows: every member's sparse slot points down at its dense slot; the focused one is bold
    for (let i = 0; i < n; i++) {
      const id = st.dense[i], focus = L && (L.id === id || L.movedId === id);
      if (!focus && narrow) continue;
      svg.append(B.svg("path", { d: `M${cx(id) + cw / 2},${rowY.sparse + ch} C${cx(id) + cw / 2},${rowY.sparse + ch + 30} ${cx(i) + cw / 2},${rowY.dense - 30} ${cx(i) + cw / 2},${rowY.dense - 2}`,
        fill: "none", stroke: focus ? (L.kind === "hit" ? C.hit : C.accent) : C.line, "stroke-width": focus ? 2.5 : 1, opacity: focus ? 1 : 0.45 }));
    }
    if (L && L.kind === "rem") {
      const gx = cx(L.from);
      svg.append(B.svg("rect", { x: gx + 1, y: rowY.dense, width: cw - 2, height: 2 * ch + 8, rx: 4, fill: "none", stroke: C.miss, "stroke-dasharray": "4 3", opacity: 1 - 0.6 * tw }),
        T(gx + cw / 2, rowY.dense - 6, "popped", { fill: C.miss, "text-anchor": "middle", "font-size": 10 }));
    }
    return svg;
  }
  const ease = (t) => t * t * (3 - 2 * t);

  const result = h("output", { class: "ch09-result", "aria-live": "polite" }, "–");
  const cnt = B.counters([["op", "step"], ["n", "members"], ["loads", "array loads"], ["moved", "elements moved", "good"], ["mem", "memory"]]);
  const push = (t) => { ops = ops.slice(0, k).concat({ t, id: sel }); k++; player.pause(); kick(); draw(); };
  const bI = h("button", { type: "button", onclick: () => push("ins") }, "Insert");
  const bR = h("button", { type: "button", onclick: () => push("rem") }, "Remove");
  const bL = h("button", { type: "button", onclick: () => push("get") }, "Lookup");
  const selOut = h("span", { class: "ch09-sel" });

  function draw() {
    const st = replay(k);
    chart.redraw();
    result.textContent = st.last ? st.last.text : "Empty set. Press Play, or tap an id in the sparse row and Insert it.";
    result.dataset.kind = st.last ? st.last.kind : "";
    cnt.set("op", k + "/" + ops.length); cnt.set("n", st.dense.length); cnt.set("loads", st.loads); cnt.set("moved", st.moved);
    cnt.set("mem", `${U * 4} B sparse + ${st.dense.length * 8} B dense + ${st.dense.length * 4} B data`);
    selOut.textContent = "selected id: " + sel;
    const present = st.sparse[sel] !== null;
    bI.disabled = present; bR.disabled = !present;
  }

  const player = B.player(root, {
    step: () => (k < ops.length ? (k++, kick(), true) : false), back: () => (k > 0 ? (k--, tw = 1, true) : false),
    reset: () => { k = 0; ops = STORY.slice(); tw = 1; }, atEnd: () => k === ops.length, draw,
    interval: opts.interval ?? 1.1, loop: false,
  });
  root.append(result, cnt.el, h("div", { class: "controls" }, player.el,
    h("div", { class: "group", role: "group", "aria-label": "Set operations on the selected id" }, selOut, bI, bR, bL)));
  draw();
}));

/* ch11-encodings — one construct, two encodings. A call, a block or a fn's parameter list grows one child at a time;
 * watch the node stay 13 bytes while the parser switches tag (call_one → call, block_two → block) and moves the
 * children into the shared extra array.
 * <div class="figure-body" data-viz="ch11-encodings" data-opts='{"kind":"call","n":2}'></div>
 * Options:
 *   kind  "call" | "block" | "fn" (default "call")
 *   n     0..6 initial number of children: arguments, statements or parameters (default 2)
 * Model: exactly the encodings of code/ch11-capstone-flat-ast-compiler (Tag enum comments). call: ≤1 argument →
 * call_one {lhs callee, rhs arg|0}; ≥2 → call {lhs callee, rhs → extra[r..r+2] = {start, end}}, arguments in
 * extra[start..end] (written first). block: ≤2 statements → block_two {lhs, rhs}; ≥3 → block {lhs..rhs = extra range}.
 * fn: always fn_decl {lhs → extra {name, n, params...}, rhs body}. Boxed sizes are the programs' measured
 * size_of(Node) = 40 B plus the child slice (8 B per pointer, 4 B per parameter symbol), one extra allocation if
 * non-empty. "Sized for the worst case" = tag + main_token + 7 u32 fields (callee + 6 children) = 33 B per node. */
(window.BookQ ||= []).push((B) => B.viz.register("ch11-encodings", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["kind", "n"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch11-encodings: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const KINDS = ["call", "block", "fn"];
  let kind = KINDS.indexOf(opts.kind ?? "call");
  viz.check(kind >= 0, 'ch11-encodings: "kind" must be "call", "block" or "fn"');
  let n = opts.n ?? 2;
  viz.check(Number.isInteger(n) && n >= 0 && n <= 6, 'ch11-encodings: "n" must be an integer 0..6');
  const C = B.colors();

  function model() {
    const child = ["a", "s", "p"][kind];
    const kids = Array.from({ length: n }, (_, i) => child + i);
    const m = { kids, cells: [], lhs: "", rhs: "", tag: "", ptr: null, src: "", boxed: 0, allocs: 1 };
    if (kind === 0) {
      m.src = "f(" + kids.join(", ") + ")";
      if (n <= 1) { m.tag = "call_one"; m.lhs = "n:f"; m.rhs = n ? "n:a0" : "0"; }
      else { m.tag = "call"; m.lhs = "n:f"; m.cells = [...kids.map((k) => "n:" + k), "start=0", "end=" + n]; m.rhs = "x" + n; m.ptr = { field: "rhs", at: n, len: 2, back: [0, n] }; }
      m.boxed = 40 + 8 * n; m.allocs += n > 0 ? 1 : 0;
    } else if (kind === 1) {
      m.src = "{ " + kids.map((k) => k + ";").join(" ") + (n ? " " : "") + "}";
      if (n <= 2) { m.tag = "block_two"; m.lhs = n > 0 ? "n:s0" : "0"; m.rhs = n > 1 ? "n:s1" : "0"; }
      else { m.tag = "block"; m.cells = kids.map((k) => "n:" + k); m.lhs = "x0"; m.rhs = "x" + n; m.ptr = { field: "lhs", at: 0, len: n }; }
      m.boxed = 40 + 8 * n; m.allocs += n > 0 ? 1 : 0;
    } else {
      m.src = "fn g(" + kids.join(", ") + ") { … }";
      m.tag = "fn_decl"; m.cells = ["sym:g", "n=" + n, ...kids.map((k) => "sym:" + k)]; m.lhs = "x0"; m.rhs = "n:body";
      m.ptr = { field: "lhs", at: 0, len: n + 2 };
      m.boxed = 40 + 4 * n; m.allocs += n > 0 ? 1 : 0;
    }
    m.flat = 13 + 4 * m.cells.length;
    return m;
  }

  const cnt = B.counters([["enc", "encoding"], ["node", "node"], ["extra", "extra"], ["flat", "flat total", "good"], ["boxed", "boxed"], ["allocs", "boxed allocations"]]);
  const chart = B.chart(root, render);
  const slider = B.slider({ label: "children", min: 0, max: 6, value: n, oninput: (v) => { n = v; chart.redraw(); sync(); } });
  root.append(cnt.el, h("div", { class: "controls" },
    B.segmented(["call f(…)", "block { … }", "fn params"], kind, (i) => { kind = i; chart.redraw(); sync(); }, "Construct"), slider));
  function sync() {
    const m = model();
    cnt.set("enc", m.tag); cnt.set("node", "13 B"); cnt.set("extra", 4 * m.cells.length + " B");
    cnt.set("flat", m.flat + " B"); cnt.set("boxed", m.boxed + " B"); cnt.set("allocs", m.allocs);
  }

  function render(W) {
    const m = model(), S = B.svg;
    const narrow = W < 520, pad = 8;
    const unit = Math.min((W - 2 * pad) / 13, narrow ? 26 : 34); // px per byte for the node row
    const g = S("svg", { viewBox: `0 0 ${W} 300`, width: W, height: 300, role: "img",
      "aria-label": `${m.src} encoded as ${m.tag}: a 13-byte node${m.cells.length ? ` plus ${m.cells.length} extra u32s` : ", nothing in extra"}` });
    const txt = (x, y, s, o = {}) => S("text", { x, y, fill: o.fill || C.text, "font-size": o.size || 11, "font-family": o.font || C.mono,
      "text-anchor": o.anchor || "start", "font-weight": o.bold ? 700 : null }, s);
    g.append(txt(pad, 16, m.src, { size: 13, bold: true, fill: C.heading }), txt(W - pad, 16, m.tag, { anchor: "end", size: 13, bold: true, fill: C.flag }));
    // node row
    const fields = [["tag", 1, m.tag, C.flag], ["main_token", 4, kind === 0 ? "tok (" : kind === 1 ? "tok {" : "tok fn", C.line], ["lhs", 4, m.lhs, C.pos], ["rhs", 4, m.rhs, C.vel]];
    let x = pad; const y0 = 40, hN = 34, fx = {};
    g.append(txt(pad, y0 - 6, "nodes[i] · 13 B", { fill: C.dim, size: 10 }));
    for (const [name, bytes, val, col] of fields) {
      const w = bytes * unit;
      g.append(S("rect", { x, y: y0, width: w - 2, height: hN, rx: 3, fill: C.elev2, stroke: col, "stroke-width": 1.5 }));
      g.append(txt(x + 3, y0 + 13, w < 30 ? name[0] : name, { size: 9, fill: C.dim }));
      if (bytes > 1) g.append(txt(x + 4, y0 + 27, val, { size: narrow ? 10 : 11 }));
      fx[name] = x + w / 2; x += w;
    }
    // extra row
    const y1 = 130, cw = Math.min(narrow ? 46 : 62, (W - 2 * pad) / Math.max(8, m.cells.length + 0.5));
    g.append(txt(pad, y1 - 8, m.cells.length ? `extra[0..${m.cells.length}] · ${4 * m.cells.length} B${narrow ? "" : " (this node's cells)"}` : narrow ? "extra: nothing (fits in lhs/rhs)" : "extra: nothing — both children fit in lhs/rhs", { fill: C.dim, size: 10 }));
    m.cells.forEach((c, i) => {
      const cx = pad + i * cw;
      const isPair = m.ptr && m.ptr.len === 2 && kind === 0 && i >= m.ptr.at;
      g.append(S("rect", { x: cx, y: y1, width: cw - 3, height: 30, rx: 3, fill: C.elev2, stroke: isPair ? C.vel : C.hp, "stroke-width": 1.3 }));
      g.append(txt(cx + 3, y1 + 11, "x" + i, { size: 9, fill: C.dim }));
      g.append(txt(cx + 3, y1 + 24, narrow ? c.replace(/^(start|end|sym:)=?/, "") : c, { size: narrow ? 9 : 10 }));
    });
    if (m.ptr) {
      const from = fx[m.ptr.field], tx = pad + m.ptr.at * cw + (cw - 3) / 2;
      g.append(S("path", { d: `M${from} ${y0 + hN} C ${from} ${y0 + hN + 30}, ${tx} ${y1 - 40}, ${tx} ${y1 - 2}`, fill: "none", stroke: m.ptr.field === "lhs" ? C.pos : C.vel, "stroke-width": 1.5 }));
      g.append(S("path", { d: `M${tx - 4} ${y1 - 8} L${tx} ${y1 - 1} L${tx + 4} ${y1 - 8}`, fill: "none", stroke: m.ptr.field === "lhs" ? C.pos : C.vel, "stroke-width": 1.5 }));
      if (m.ptr.back) { // start/end point back at the argument cells
        const bx = pad + m.ptr.at * cw;
        g.append(S("path", { d: `M${bx + cw / 2} ${y1 + 32} C ${bx + cw / 2} ${y1 + 52}, ${pad + 10} ${y1 + 52}, ${pad + 4} ${y1 + 33}`, fill: "none", stroke: C.vel, "stroke-dasharray": "3 3" }));
        g.append(txt(pad, y1 + 64, `{start, end} → args x0..x${m.ptr.back[1]}`, { size: 9, fill: C.dim }));
      }
    }
    // byte bars
    const y2 = 224, worst = 33, max = Math.max(m.boxed, worst, m.flat, 64);
    const lw = narrow ? 0 : 190, bw = W - 2 * pad - lw - 50, sx = (v) => (v / max) * bw;
    const bars = [["flat: node + extra", m.flat, C.hit], ["worst-case node", worst, C.pad], ["boxed: Node + slice", m.boxed, C.miss]];
    bars.forEach(([lab, v, col], i) => {
      const yy = narrow ? y2 - 14 + i * 30 : y2 + i * 26;
      g.append(txt(pad, narrow ? yy : yy + 12, lab, { size: 10, fill: C.dim }));
      const bx = pad + lw, by = narrow ? yy + 4 : yy;
      g.append(S("rect", { x: bx, y: by, width: Math.max(2, sx(v)), height: narrow ? 12 : 16, rx: 2, fill: col, opacity: 0.85 }));
      g.append(txt(bx + sx(v) + 4, by + (narrow ? 10 : 12), v + " B", { size: 10 }));
    });
    return g;
  }
  sync();
}));

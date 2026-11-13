/* ch05-pointer-vs-index — the same binary search tree stored as individually allocated nodes linked by
 * 8-byte pointers, and as one array of nodes linked by 4-byte indices, drawn to the same byte scale.
 * <div class="figure-body" data-viz="ch05-pointer-vs-index" data-opts='{"nodes":7}'></div>
 * Options:
 *   nodes  3..15 initial node count (default 7)
 *   heap   "fresh" | "aged" initial heap state (default "fresh")
 *   seed   integer seed for the aged heap (default 5)
 * Model (x86-64, glibc malloc): a pointer node {key u32, left, right: ?*Node} is 24 B with 4 B padding; malloc(24)
 * hands out a 32 B chunk (8 B header + 24 B payload, 16 B aligned). An index node {key, left, right: u32} is 12 B
 * and the nodes sit back to back in one array. "fresh": chunks come out in allocation order, one after another
 * (what this orb's glibc did for the Rust tree). "aged": after a lot of unrelated malloc/free traffic the
 * chunks land wherever there is a hole (seeded shuffle). Lines touched = distinct 64 B lines that hold a node. */
(window.BookQ ||= []).push((B) => B.viz.register("ch05-pointer-vs-index", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["nodes", "heap", "seed"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch05-pointer-vs-index: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  let n = opts.nodes ?? 7;
  viz.check(Number.isInteger(n) && n >= 3 && n <= 15, 'ch05-pointer-vs-index: "nodes" must be an integer 3..15');
  let aged = (opts.heap ?? "fresh") === "aged";
  viz.check(["fresh", "aged"].includes(opts.heap ?? "fresh"), 'ch05-pointer-vs-index: "heap" must be "fresh" or "aged"');
  const seed = opts.seed ?? 5;
  viz.check(Number.isInteger(seed), 'ch05-pointer-vs-index: "seed" must be an integer');

  const KEYS = [50, 30, 70, 20, 40, 60, 80, 10, 25, 35, 45, 55, 65, 75, 90]; // insertion order: a full tree at 15
  const PNODE = 24, CHUNK = 32, HDR = 8, INODE = 12, LINE = 64, BASE = 0x5a40;
  let sel = 0;

  function build() {
    const nodes = [];
    for (let i = 0; i < n; i++) {
      const key = KEYS[i];
      nodes.push({ key, left: -1, right: -1, depth: 0 });
      if (i === 0) continue;
      let at = 0, d = 1;
      for (;;) {
        const side = key < nodes[at].key ? "left" : "right";
        if (nodes[at][side] < 0) { nodes[at][side] = i; nodes[i].depth = d; break; }
        at = nodes[at][side]; d++;
      }
    }
    // in-order rank for the tree drawing
    let r = 0;
    const rank = (i) => { if (i < 0) return; rank(nodes[i].left); nodes[i].rank = r++; rank(nodes[i].right); };
    rank(0);
    // heap placement: chunk number for each node
    const heapChunks = Math.max(2 * n, 8);
    let chunks = [...Array(heapChunks).keys()];
    if (aged) {
      const rnd = B.rng(seed + n);
      for (let i = chunks.length - 1; i > 0; i--) { const j = rnd.int(i + 1); [chunks[i], chunks[j]] = [chunks[j], chunks[i]]; }
    }
    nodes.forEach((nd, i) => { nd.chunk = chunks[i]; nd.addr = BASE + nd.chunk * CHUNK + HDR; });
    const linesP = new Set(nodes.map((nd) => Math.floor((nd.chunk * CHUNK + HDR) / LINE))).size;
    const linesI = Math.ceil((n * INODE) / LINE);
    return { nodes, heapBytes: heapChunks * CHUNK, linesP, linesI };
  }

  const C = B.colors();
  const hex = (a) => "0x" + a.toString(16);
  const chart = B.chart(root, render);
  const readout = h("output", { class: "ch05-result", "aria-live": "polite" }, "–");
  const cnt = B.counters([["n", "nodes"], ["pb", "pointer tree", "bad"], ["ib", "index tree", "good"], ["ratio", "ratio"],
    ["lp", "lines touched (pointers)"], ["li", "lines touched (indices)"]]);

  function render(w) {
    const m = build(), narrow = w < 600, pad = 8;
    const perRow = narrow ? 2 : 4, lineW = (w - 2 * pad) / perRow, px = lineW / LINE; // pixels per byte
    const treeH = 34 + 30 * 3 + 16, rowH = 56, BOX = 30;
    const heapRows = Math.ceil(m.heapBytes / (LINE * perRow));
    const idxRows = Math.max(1, Math.ceil((n * INODE) / (LINE * perRow)));
    const y1 = treeH + 22, y2 = y1 + heapRows * rowH + 30;
    const H = y2 + idxRows * rowH + 12;
    const svg = B.svg("svg", { viewBox: `0 0 ${w} ${H}`, width: w, height: H, role: "img",
      "aria-label": `${n}-node tree: ${n * CHUNK} bytes as pointer nodes, ${n * INODE} bytes as index nodes` });
    const T = (x, y, s, o = {}) => B.svg("text", Object.assign({ x, y, fill: C.text, "font-family": C.mono, "font-size": 11 }, o), s);
    const pick = (i) => ({ onclick: () => { sel = i; draw(); }, style: "cursor:pointer" });
    // --- the tree itself ---
    const tx = (nd) => pad + 14 + (nd.rank + 0.5) * ((w - 2 * pad - 28) / n), ty = (nd) => 22 + nd.depth * 30;
    m.nodes.forEach((nd) => ["left", "right"].forEach((s) => {
      if (nd[s] >= 0) { const c = m.nodes[nd[s]]; svg.append(B.svg("line", { x1: tx(nd), y1: ty(nd), x2: tx(c), y2: ty(c), stroke: C.line, "stroke-width": 1.5 })); }
    }));
    m.nodes.forEach((nd, i) => {
      const g = B.svg("g", pick(i));
      g.append(B.svg("circle", { cx: tx(nd), cy: ty(nd), r: 12, fill: i === sel ? C.accent : C.elev2, stroke: C.pos, "stroke-width": 1.5 }),
        T(tx(nd), ty(nd) + 4, String(nd.key), { "text-anchor": "middle", fill: i === sel ? C.bg : C.heading, "font-weight": 700 }));
      svg.append(g);
    });
    // --- memory strips (same byte scale) ---
    const strip = (y0, rows, label) => {
      svg.append(T(pad, y0 - 8, label, { fill: C.heading, "font-weight": 700, "font-size": narrow ? 10.5 : 12 }));
      // the 64 B line borders are drawn after the chunks (see lines()), so they stay visible on top of them
      return () => { for (let r = 0; r < rows; r++) for (let c = 0; c < perRow; c++)
        svg.append(B.svg("rect", { x: pad + c * lineW, y: y0 + r * rowH, width: lineW, height: BOX + 2, fill: "none", stroke: C.border, "stroke-width": 1, "pointer-events": "none" })); };
    };
    const at = (byte, y0) => ({ x: pad + (byte % (LINE * perRow)) * px, y: y0 + Math.floor(byte / (LINE * perRow)) * rowH });
    const heapLines = strip(y1, heapRows, narrow ? "heap: one malloc per node, 32 B chunks" : "heap: one malloc per node (32 B chunk = 8 B header + 24 B node)");
    // rows of the modelled heap that hold no node are free heap (the aged heap may place nodes there)
    const usedRows = new Set(m.nodes.map((nd) => Math.floor((nd.chunk * CHUNK) / (LINE * perRow))));
    for (let r = 0; r < heapRows; r++) if (!usedRows.has(r))
      svg.append(T(pad + 6, y1 + r * rowH + 20, "free heap", { fill: C.dim, "font-size": narrow ? 10 : 11 }));
    const centers = [];
    m.nodes.forEach((nd, i) => {
      const p = at(nd.chunk * CHUNK, y1);
      svg.append(B.svg("rect", { x: p.x + 1, y: p.y + 1, width: HDR * px - 1, height: BOX, fill: C.pad, opacity: 0.7 }));
      const g = B.svg("g", pick(i));
      g.append(B.svg("rect", { x: p.x + HDR * px, y: p.y + 1, width: PNODE * px - 1, height: BOX, rx: 3, fill: i === sel ? C.accent : C.pos, opacity: i === sel ? 1 : 0.75 }),
        T(p.x + HDR * px + 4, p.y + 20, String(nd.key), { fill: C.bg, "font-weight": 700 }));
      svg.append(g);
      centers.push({ x: p.x + (HDR + PNODE / 2) * px, y: p.y + BOX + 1 });
    });
    // only the selected node's two links, drawn below the boxes (from its bottom edge to each child's)
    const arrows = (cs) => ["left", "right"].forEach((s) => {
      const j = m.nodes[sel] && m.nodes[sel][s];
      if (j == null || j < 0) return;
      const a = cs[sel], b = cs[j];
      const mx = (a.x + b.x) / 2, my = Math.max(a.y, b.y) + 20;
      svg.append(B.svg("path", { d: `M${a.x},${a.y} Q${mx},${my} ${b.x},${b.y}`, fill: "none", stroke: C.accent, "stroke-width": 2 }));
      svg.append(B.svg("circle", { cx: b.x, cy: b.y, r: 3, fill: C.accent }));
    });
    heapLines();
    arrows(centers);
    const idxLines = strip(y2, idxRows, narrow ? "one array: 12 B per node" : "one array, links are u32 indices: 12 B per node");
    const ic = [];
    m.nodes.forEach((nd, i) => {
      const p = at(i * INODE, y2);
      const g = B.svg("g", pick(i));
      g.append(B.svg("rect", { x: p.x + 0.5, y: p.y + 1, width: INODE * px - 1, height: BOX, rx: 2, fill: i === sel ? C.accent : C.vel, opacity: i === sel ? 1 : 0.8 }));
      if (INODE * px >= 18) g.append(T(p.x + INODE * px / 2, p.y + 20, String(nd.key), { fill: C.bg, "font-weight": 700, "text-anchor": "middle", "font-size": INODE * px < 24 ? 9 : 11 }));
      svg.append(g);
      ic.push({ x: p.x + (INODE * px) / 2, y: p.y + BOX + 1 });
    });
    idxLines();
    arrows(ic);
    return svg;
  }

  function draw() {
    const m = build();
    if (sel >= n) sel = 0;
    chart.redraw();
    const nd = m.nodes[sel], ptr = (j) => (j < 0 ? "null" : hex(m.nodes[j].addr)), idx = (j) => (j < 0 ? "none" : String(j));
    readout.textContent = `node ${nd.key}: pointer form {key ${nd.key}, left ${ptr(nd.left)}, right ${ptr(nd.right)}} at ${hex(nd.addr)} · ` +
      `index form nodes[${sel}] = {key ${nd.key}, left ${idx(nd.left)}, right ${idx(nd.right)}} (model addresses)`;
    cnt.set("n", n);
    cnt.set("pb", B.fmtBytes(n * CHUNK) + " (" + n * PNODE + " B nodes + " + n * HDR + " B headers)");
    cnt.set("ib", B.fmtBytes(n * INODE));
    cnt.set("ratio", ((n * CHUNK) / (n * INODE)).toFixed(2) + "×");
    cnt.set("lp", m.linesP); cnt.set("li", m.linesI);
  }

  const slider = B.slider({ label: "nodes", min: 3, max: 15, value: n, oninput: (v) => { n = v; draw(); } });
  root.append(readout, cnt.el, h("div", { class: "controls" }, slider,
    B.segmented(["fresh heap", "aged heap"], aged ? 1 : 0, (i) => { aged = i === 1; draw(); }, "Heap state")));
  draw();
}));

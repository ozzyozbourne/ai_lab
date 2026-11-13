/* ch06-arena — the same frame of short-lived allocations served by a bump arena and by a free-list heap.
 * <div class="figure-body" data-viz="ch06-arena" data-opts='{"frames":3,"perFrame":8}'></div>
 * Options:
 *   frames    1..6 frames to play (default 3)
 *   perFrame  2..12 allocations per frame (default 8)
 *   seed      integer seed for sizes and for the aged heap (default 6)
 *   interval  seconds per step while playing (default 0.45)
 * Model. Both panels get the identical request sequence: per frame, `perFrame` objects of 8..72 bytes, then the frame
 * ends. Arena: one dedicated 1 KiB block; an allocation rounds the bump pointer up to 8 and adds the size; the frame
 * ends with one reset (pointer back to 0). Heap: a 2 KiB heap that already holds long-lived objects (grey) from
 * earlier in the program, so its free space is a list of holes. malloc = 8 B header + payload rounded up to a
 * multiple of 16, minimum 32 B (glibc-like); first fit over the address-ordered free list, splitting a hole when at
 * least 32 B are left. free = put the chunk back and merge it with free neighbours. Every counter is computed from
 * this model; under reduced motion the still frame is the last frame just before its reset. Real allocators (size classes, per-thread caches) are faster than first fit but keep the same shape. */
(window.BookQ ||= []).push((B) => B.viz.register("ch06-arena", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["frames", "perFrame", "seed", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `ch06-arena: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const FRAMES = opts.frames ?? 3, PER = opts.perFrame ?? 8;
  viz.check(Number.isInteger(FRAMES) && FRAMES >= 1 && FRAMES <= 6, 'ch06-arena: "frames" must be an integer 1..6');
  viz.check(Number.isInteger(PER) && PER >= 2 && PER <= 12, 'ch06-arena: "perFrame" must be an integer 2..12');
  const ARENA = 1024, HEAP = 2048, LINE = 64;
  const rnd = B.rng(opts.seed ?? 6);

  // ---- request sequence (shared by both panels) ----
  const sizes = [];
  for (let f = 0; f < FRAMES; f++) { const fr = []; for (let i = 0; i < PER; i++) fr.push(8 + 8 * rnd.int(9)); sizes.push(fr); }
  const STEPS_PER_FRAME = PER + 1, TOTAL = FRAMES * STEPS_PER_FRAME;

  // ---- aged heap: long-lived blocks scattered through the heap, leaving holes ----
  const aged = [];
  for (let at = 0; at < HEAP;) {
    const hole = 32 + 16 * rnd.int(8);            // 32..144 B hole
    const used = 48 + 16 * rnd.int(10);           // 48..192 B long-lived block
    at += hole;
    if (at + used > HEAP - 64) break;
    aged.push({ start: at, size: used });
    at += used;
  }
  const chunkOf = (sz) => Math.max(32, Math.ceil((sz + 8) / 16) * 16);

  // ---- pure model: replay k steps from the start ----
  function model(k) {
    const arena = { ptr: 0, objs: [], resets: 0, allocs: 0, pad: 0, peak: 0 };
    let free = [];                                 // address-ordered holes {start, size}
    let prev = 0;
    for (const a of aged) { if (a.start > prev) free.push({ start: prev, size: a.start - prev }); prev = a.start + a.size; }
    if (prev < HEAP) free.push({ start: prev, size: HEAP - prev });
    const heap = { objs: [], frees: 0, allocs: 0, visited: 0, lastVisited: 0, failed: 0 };
    let last = null;
    for (let s = 0; s < k; s++) {
      const f = Math.floor(s / STEPS_PER_FRAME), i = s % STEPS_PER_FRAME;
      if (i < PER) {
        const sz = sizes[f][i];
        const start = Math.ceil(arena.ptr / 8) * 8;
        arena.pad += start - arena.ptr; arena.ptr = start + sz; arena.peak = Math.max(arena.peak, arena.ptr);
        arena.objs.push({ start, size: sz, frame: f, i }); arena.allocs++;
        const need = chunkOf(sz);
        let visited = 0, got = -1;
        for (let j = 0; j < free.length; j++) { visited++; if (free[j].size >= need) { got = j; break; } }
        heap.visited += visited; heap.lastVisited = visited; heap.allocs++;
        if (got >= 0) {
          const hole = free[got], start2 = hole.start;
          const take = hole.size - need >= 32 ? need : hole.size;
          if (take === hole.size) free.splice(got, 1); else { hole.start += take; hole.size -= take; }
          heap.objs.push({ start: start2, chunk: take, size: sz, frame: f, i });
        } else heap.failed++;
        last = { kind: "alloc", f, i, sz };
      } else {
        arena.objs = []; arena.ptr = 0; arena.resets++;
        for (const o of heap.objs) {                // free every object of the frame, one call each
          heap.frees++;
          free.push({ start: o.start, size: o.chunk });
        }
        heap.objs = [];
        free.sort((a, b) => a.start - b.start);
        const merged = [];
        for (const b of free) { const m = merged[merged.length - 1]; if (m && m.start + m.size === b.start) m.size += b.size; else merged.push({ ...b }); }
        free = merged;
        last = { kind: "end", f };
      }
    }
    const lines = (objs, startOf, sizeOf) => { const set = new Set(); for (const o of objs) for (let l = Math.floor(startOf(o) / LINE); l <= Math.floor((startOf(o) + sizeOf(o) - 1) / LINE); l++) set.add(l); return set.size; };
    const totalFree = free.reduce((t, b) => t + b.size, 0), largest = free.reduce((m, b) => Math.max(m, b.size), 0);
    return {
      arena, heap, free, last,
      arenaLines: lines(arena.objs, (o) => o.start, (o) => o.size),
      heapLines: lines(heap.objs, (o) => o.start, (o) => o.chunk),
      liveBytes: arena.objs.reduce((t, o) => t + o.size, 0),
      heapBytes: heap.objs.reduce((t, o) => t + o.chunk, 0),
      totalFree, largest, frag: totalFree ? 1 - largest / totalFree : 0,
    };
  }

  let k = 0;
  const C = B.colors();
  const frameColor = (f) => [C.pos, C.vel, C.hp, C.flag, C.line, C.hit][f % 6];

  const mk = (title, sub, defs) => {
    const canvas = h("canvas", { role: "img" });
    const cnt = B.counters(defs);
    const el = h("div", { class: "viz-panel" }, h("p", { class: "viz-title" }, title, h("small", {}, sub)), canvas, cnt.el);
    return { canvas, cnt, el, k: B.canvas(canvas, 320, 120) };
  };
  const A = mk("Frame arena", "1 KiB block · bump pointer · reset at frame end",
    [["alloc", "allocations"], ["live", "bytes live"], ["lines", "cache lines"], ["ops", "free() calls"], ["resets", "resets"]]);
  const H = mk("General-purpose heap", "2 KiB, already holding long-lived objects (grey)",
    [["alloc", "allocations"], ["live", "heap bytes"], ["lines", "cache lines", "bad"], ["visit", "holes searched", "bad"], ["ops", "free() calls", "bad"], ["frag", "fragmentation"]]);
  const readout = h("p", { class: "readout" });
  const player = B.player(root, {
    step: () => (k < TOTAL ? (k++, true) : false),
    back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; },
    atEnd: () => k === TOTAL,
    draw: () => draw(),
    interval: opts.interval ?? 0.45,
    still: "start",
  });
  // Reduced-motion still frame: the last frame fully allocated, just before its reset (the end state is empty).
  if (B.reducedMotion()) k = TOTAL - 1;
  const legend = h("div", { class: "legend" });
  const sw = (t, c, hatch) => { const i = h("i", hatch ? { class: "hatch" } : {}); if (!hatch) i.style.background = c; legend.append(h("span", {}, i, t)); };
  for (let f = 0; f < Math.min(FRAMES, 3); f++) sw(`frame ${f + 1} object`, frameColor(f));
  sw("long-lived (heap only)", C.pad); sw("header + rounding", null, true);
  const freeKey = h("span", {}, h("i", { style: { background: "transparent", outline: `1.5px dashed ${C.hit}` } }), "free hole (free list →)");
  legend.append(freeKey);
  root.append(h("div", { class: "viz-panels" }, A.el, H.el), readout, h("div", { class: "controls" }, player.el), legend,
    h("p", { class: "viz-note" }, "Model, not a measurement: 8-byte alignment in the arena; a glibc-like heap with 8 B headers, 16 B rounding and first fit. Real mallocs use size classes and per-thread caches, so they search less, but each object still gets a header, rounding and its own free()."));

  // Draws a byte range [start, start+len) as segments on a strip that wraps every `perRow` bytes.
  function strip(kk, total, perRow) {
    const W = kk.width, rows = Math.ceil(total / perRow), rowH = 30, top = 16;
    const Hh = top + rows * rowH + 4;
    if (Math.abs(kk.height - Hh) > 0.5) kk.fit(W, Hh);
    const sx = (W - 8) / perRow;
    const seg = (start, len, fn) => {
      for (let b = start; b < start + len;) {
        const r = Math.floor(b / perRow), e = Math.min(start + len, (r + 1) * perRow);
        fn(4 + (b - r * perRow) * sx, top + r * rowH, (e - b) * sx, r);
        b = e;
      }
    };
    const xy = (b) => { const r = Math.floor(b / perRow); return [4 + (b - r * perRow) * sx, top + r * rowH]; };
    return { W, Hh, rows, rowH, top, sx, seg, xy, cellH: 18 };
  }
  function grid(ctx, g, total, perRow) {
    for (let r = 0; r < g.rows; r++) {
      const y = g.top + r * g.rowH;
      ctx.strokeStyle = C.border; ctx.lineWidth = 1;
      ctx.strokeRect(4.5, y + 0.5, Math.min(perRow, total - r * perRow) * g.sx - 1, g.cellH);
      for (let b = LINE; b < perRow && r * perRow + b < total; b += LINE) {
        ctx.beginPath(); ctx.moveTo(4 + b * g.sx + 0.5, y); ctx.lineTo(4 + b * g.sx + 0.5, y + g.cellH); ctx.stroke();
      }
    }
  }
  function hatch(ctx, x, y, w, hh) {
    ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, hh); ctx.clip();
    ctx.strokeStyle = "rgba(139,150,168,.55)"; ctx.lineWidth = 1;
    for (let d = -hh; d < w; d += 4) { ctx.beginPath(); ctx.moveTo(x + d, y + hh); ctx.lineTo(x + d + hh, y); ctx.stroke(); }
    ctx.restore();
  }
  function drawArena(m) {
    const kk = A.k, ctx = kk.ctx, perRow = kk.width < 420 ? 256 : 512;
    const g = strip(kk, ARENA, perRow);
    ctx.clearRect(0, 0, kk.width, kk.height);
    grid(ctx, g, ARENA, perRow);
    for (const o of m.arena.objs) g.seg(o.start, o.size, (x, y, w) => { ctx.fillStyle = frameColor(o.frame); ctx.fillRect(x + 0.5, y + 2, Math.max(1, w - 1), g.cellH - 4); });
    const [px, py] = g.xy(Math.min(m.arena.ptr, ARENA - 1));
    ctx.fillStyle = C.heading; ctx.beginPath(); ctx.moveTo(px, py - 1); ctx.lineTo(px - 5, py - 9); ctx.lineTo(px + 5, py - 9); ctx.fill();
    ctx.font = "600 10px " + C.mono; ctx.textBaseline = "alphabetic"; ctx.textAlign = px > kk.width - 80 ? "right" : "left";
    ctx.fillText(`ptr = ${m.arena.ptr}`, px + (ctx.textAlign === "right" ? -8 : 8), py - 4); ctx.textAlign = "start";
    A.cnt.set("alloc", m.arena.allocs); A.cnt.set("live", m.liveBytes + " B"); A.cnt.set("lines", m.arenaLines);
    A.cnt.set("ops", 0); A.cnt.set("resets", m.arena.resets);
    A.canvas.setAttribute("aria-label", `Arena: bump pointer at byte ${m.arena.ptr}, ${m.arena.objs.length} live objects packed into ${m.arenaLines} cache lines, ${m.arena.resets} resets, no individual frees.`);
  }
  function drawHeap(m) {
    const kk = H.k, ctx = kk.ctx, perRow = kk.width < 420 ? 256 : 512;
    const g = strip(kk, HEAP, perRow);
    ctx.clearRect(0, 0, kk.width, kk.height);
    grid(ctx, g, HEAP, perRow);
    for (const a of aged) g.seg(a.start, a.size, (x, y, w) => { ctx.fillStyle = C.pad; ctx.fillRect(x + 0.5, y + 2, Math.max(1, w - 1), g.cellH - 4); });
    for (const o of m.heap.objs) {
      g.seg(o.start, o.chunk, (x, y, w) => hatch(ctx, x + 0.5, y + 2, Math.max(1, w - 1), g.cellH - 4));
      g.seg(o.start + 8, o.size, (x, y, w) => { ctx.fillStyle = frameColor(o.frame); ctx.fillRect(x, y + 2, Math.max(1, w), g.cellH - 4); });
    }
    ctx.setLineDash([3, 2]); ctx.strokeStyle = C.hit; ctx.lineWidth = 1.2;
    for (const b of m.free) g.seg(b.start, b.size, (x, y, w) => ctx.strokeRect(x + 1, y + 1.5, Math.max(1, w - 2), g.cellH - 3));
    ctx.setLineDash([]);
    // free list: arrows from each hole to the next, in address order
    ctx.strokeStyle = "rgba(127,219,160,.55)"; ctx.lineWidth = 1;
    for (let j = 0; j + 1 < m.free.length; j++) {
      const [ax, ay] = g.xy(m.free[j].start + Math.min(8, m.free[j].size / 2)), [bx, by] = g.xy(m.free[j + 1].start + 2);
      const yy = ay + g.cellH + 1, yb = by + g.cellH + 1;
      ctx.beginPath(); ctx.moveTo(ax, yy);
      if (ay === by) ctx.quadraticCurveTo((ax + bx) / 2, yy + 9, bx, yb); else ctx.bezierCurveTo(ax + 30, yy + 10, bx - 30, yb + 10, bx, yb);
      ctx.stroke(); ctx.beginPath(); ctx.arc(bx, yb, 1.8, 0, 7); ctx.fillStyle = C.hit; ctx.fill();
    }
    H.cnt.set("alloc", m.heap.allocs); H.cnt.set("live", m.heapBytes + " B");
    H.cnt.set("lines", m.heapLines); H.cnt.set("visit", m.heap.visited);
    H.cnt.set("ops", m.heap.frees); H.cnt.set("frag", Math.round(m.frag * 100) + "%");
    H.canvas.setAttribute("aria-label", `Heap: ${m.heap.objs.length} live objects using ${m.heapBytes} bytes with headers, spread over ${m.heapLines} cache lines; ${m.heap.visited} free-list holes searched and ${m.heap.frees} free calls so far; ${m.free.length} holes, fragmentation ${Math.round(m.frag * 100)}%.`);
  }
  function draw() {
    const m = model(k);
    if (A.k.width > 10) drawArena(m);
    if (H.k.width > 10) drawHeap(m);
    const L = m.last;
    if (!L) readout.textContent = `Predict: after ${PER} allocations, how many cache lines will each side touch, and how many calls does it take to free the frame?`;
    else if (L.kind === "alloc") readout.textContent = `frame ${L.f + 1}, alloc ${L.i + 1}/${PER}: ${L.sz} B. Arena: one add (ptr → ${m.arena.ptr}). Heap: ${chunkOf(L.sz)} B chunk, searched ${m.heap.lastVisited} hole${m.heap.lastVisited === 1 ? "" : "s"}.`;
    else readout.textContent = `end of frame ${L.f + 1}: arena reset = 1 store (ptr → 0). Heap: ${PER} free() calls, ${m.free.length} holes left, largest ${m.largest} of ${m.totalFree} B free.`;
  }
  [A, H].forEach((p) => B.onResize(p.el, (w) => { p.k.fit(w, p.k.height); draw(); }));
  draw();
}));

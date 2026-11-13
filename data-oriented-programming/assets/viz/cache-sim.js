/* cache-sim — a tiny set-associative LRU cache stepping through an address trace.
 * <div class="figure-body" data-viz="cache-sim" data-opts='{"sets":4,"ways":2,"line":16,"preset":0}'></div>
 * Options:
 *   sets    power of two 1..16 (default 4)
 *   ways    1..8 (default 2)
 *   line    line size in bytes, power of two 4..64 (default 16; small so the trace stays short)
 *   preset  initial trace index: 0 sequential u32, 1 loop that fits ×2, 2 loop too big ×2, 3 same-set stride (default 0)
 *   trace   custom list of byte addresses (adds a "custom" choice and starts on it)
 *   interval  seconds per access while playing (default 0.55)
 * Every miss is classified by re-running the trace: cold (first touch of the line), capacity (a fully
 * associative LRU cache of the same size would also miss), conflict (it would have hit). */
(window.BookQ ||= []).push((B) => B.viz.register("cache-sim", (root, opts) => {
  const { h, viz } = B;
  const KNOWN = ["sets", "ways", "line", "preset", "trace", "interval"];
  for (const k of Object.keys(opts)) viz.check(KNOWN.includes(k), `cache-sim: unknown option "${k}" (known: ${KNOWN.join(", ")})`);
  const pow2 = (v) => Number.isInteger(v) && v > 0 && (v & (v - 1)) === 0;
  const SETS = opts.sets ?? 4, WAYS = opts.ways ?? 2, LINE = opts.line ?? 16;
  viz.check(pow2(SETS) && SETS <= 16, `cache-sim: "sets" must be a power of two up to 16`);
  viz.check(Number.isInteger(WAYS) && WAYS >= 1 && WAYS <= 8, `cache-sim: "ways" must be an integer 1..8`);
  viz.check(pow2(LINE) && LINE >= 4 && LINE <= 64, `cache-sim: "line" must be a power of two 4..64`);
  const CAP = SETS * WAYS * LINE, OFF = Math.log2(LINE), IDX = Math.log2(SETS);
  const range = (a, b, s) => { const r = []; for (let v = a; v < b; v += s) r.push(v); return r; };
  const PRESETS = [
    { label: "sequential u32", trace: range(0, Math.min(CAP, 32 * 4), 4), why: "Walking u32s: one miss per line, then hits for the rest of it." },
    { label: "loop that fits ×2", trace: [...range(0, Math.floor((CAP * 3) / 4), LINE), ...range(0, Math.floor((CAP * 3) / 4), LINE)], why: `The working set (${(CAP * 3) / 4} B) fits in ${CAP} B, so the second pass hits.` },
    { label: "loop too big ×2", trace: [...range(0, CAP * 1.5, LINE), ...range(0, CAP * 1.5, LINE)], why: `${CAP * 1.5} B does not fit in ${CAP} B: LRU evicts each line just before it is needed again.` },
    { label: "same-set stride", trace: [].concat(...Array.from({ length: 3 }, () => range(0, SETS * LINE * (WAYS + 1), SETS * LINE))), why: `Stride ${SETS * LINE} B maps every access to set 0: ${WAYS + 1} lines fight over ${WAYS} ways while the other sets sit empty.` },
  ];
  let pi = opts.preset ?? 0;
  if (opts.trace !== undefined) {
    viz.check(Array.isArray(opts.trace) && opts.trace.length > 0 && opts.trace.length <= 200 && opts.trace.every((a) => Number.isInteger(a) && a >= 0),
      `cache-sim: "trace" must be 1..200 non-negative integer addresses`);
    PRESETS.push({ label: "custom", trace: opts.trace, why: "" });
    pi = PRESETS.length - 1;
  }
  viz.check(Number.isInteger(pi) && pi >= 0 && pi < PRESETS.length, `cache-sim: "preset" must be 0..${PRESETS.length - 1}`);
  const maxAddr = Math.max(...PRESETS.flatMap((p) => p.trace));
  const BITS = Math.max(8, Math.ceil(Math.log2(maxAddr + 1)));
  const interval = opts.interval ?? 0.55;

  /* ---- model: replay the first k accesses ---- */
  function simulate(trace, k) {
    const sets = Array.from({ length: SETS }, () => []); // each: [{tag, used}] most-recent-last
    const fa = []; // fully associative LRU of SETS*WAYS lines, for miss classification
    const seen = new Set();
    const res = [];
    for (let i = 0; i < k; i++) {
      const a = trace[i], lineNo = Math.floor(a / LINE), set = lineNo % SETS, tag = Math.floor(lineNo / SETS);
      const ways = sets[set], w = ways.findIndex((x) => x.tag === tag);
      const faHit = fa.indexOf(lineNo);
      if (faHit >= 0) fa.splice(faHit, 1);
      fa.push(lineNo);
      if (fa.length > SETS * WAYS) fa.shift();
      let kind, way, evicted = null;
      if (w >= 0) { kind = "hit"; const [x] = ways.splice(w, 1); ways.push(x); way = x.way; }
      else {
        kind = !seen.has(lineNo) ? "cold" : faHit >= 0 ? "conflict" : "capacity";
        if (ways.length < WAYS) { const used = new Set(ways.map((x) => x.way)); way = [...Array(WAYS).keys()].find((j) => !used.has(j)); }
        else { const v = ways.shift(); way = v.way; evicted = v.tag; }
        ways.push({ tag, way });
      }
      seen.add(lineNo);
      res.push({ a, set, tag, kind, way, evicted });
    }
    return { sets, res };
  }

  let k = 0;
  const trace = () => PRESETS[pi].trace;
  const C = B.colors();
  const addrEl = h("div", { class: "cs-addr" });
  const msg = h("p", { class: "cs-msg", "aria-live": "polite" });
  const table = h("table", { class: "cs-table" });
  const traceEl = h("div", { class: "cs-trace", "aria-label": "Address trace" });
  const cnt = B.counters([["acc", "accesses"], ["hit", "hits", "good"], ["miss", "misses", "bad"], ["kinds", "cold/capacity/conflict"], ["rate", "hit rate"]]);
  const why = h("p", { class: "viz-note" });
  const player = B.player(root, {
    step: () => (k < trace().length ? (k++, true) : false),
    back: () => (k > 0 ? (k--, true) : false),
    reset: () => { k = 0; },
    atEnd: () => k === trace().length,
    draw: () => draw(),
    interval,
  });
  const seg = B.segmented(PRESETS.map((p) => p.label), pi, (i) => { pi = i; k = 0; if (B.reducedMotion()) player.toEnd(); else draw(); }, "Address trace");
  root.classList.add("viz-cache-sim");
  root.append(
    h("p", { class: "viz-title" }, `${SETS} sets × ${WAYS} ways × ${LINE} B lines = ${CAP} B cache, LRU`),
    h("div", { class: "cs-top" }, addrEl),
    h("div", { class: "table-wrap" }, table), msg, cnt.el, traceEl,
    h("div", { class: "controls" }, player.el, seg), why);

  const hex = (v, d = 2) => "0x" + v.toString(16).padStart(d, "0");
  function draw() {
    const t = trace(), { sets, res } = simulate(t, k), last = res[k - 1];
    // address breakdown
    addrEl.replaceChildren();
    const legend = h("span", { class: "dim" }, `  tag ${BITS - IDX - OFF} b · index ${IDX} b · offset ${OFF} b`);
    if (last) {
      const bits = last.a.toString(2).padStart(BITS, "0");
      const row = h("span", { class: "cs-bits", "aria-label": `address ${last.a} in binary ${bits}` });
      [...bits].forEach((b, i) => row.append(h("span", { class: i < BITS - IDX - OFF ? "tag" : i < BITS - OFF ? "idx" : "off" }, b)));
      addrEl.append(h("div", {}, "address ", h("b", {}, hex(last.a, Math.ceil(BITS / 4))), ` = ${last.a}`, legend), row);
    } else addrEl.append(h("div", {}, "address –", legend));
    // cache table
    const head = h("tr", {}, h("th", {}, "set"), [...Array(WAYS).keys()].map((w) => h("th", {}, "way " + w)));
    const rows = sets.map((ways, s) => h("tr", {}, h("th", {}, String(s)), [...Array(WAYS).keys()].map((w) => {
      const x = ways.find((y) => y.way === w);
      const cls = [last && last.set === s ? "cur-set" : "", x ? "valid" : "empty", last && last.set === s && last.way === w ? (last.kind === "hit" ? "hit" : "miss") : ""].join(" ");
      if (!x) return h("td", { class: cls }, "—");
      const base = (x.tag * SETS + s) * LINE, age = ways.length - 1 - ways.indexOf(x);
      return h("td", { class: cls }, "tag " + hex(x.tag, 1), h("small", {}, `${base}–${base + LINE - 1}`), h("small", {}, age === 0 ? "most recent" : "LRU age " + age));
    })));
    table.replaceChildren(head, ...rows);
    // message
    if (!last) msg.textContent = `Press Step: ${t.length} accesses. Predict the hit rate first.`;
    else {
      const what = { hit: "hit", cold: "miss (cold: first touch of this line)", capacity: "miss (capacity: the working set is bigger than the cache)", conflict: "miss (conflict: a fully associative cache would have hit)" }[last.kind];
      msg.replaceChildren(`${hex(last.a)} → set ${last.set}, tag ${hex(last.tag, 1)}: `,
        h("b", { style: `color:${last.kind === "hit" ? C.hit : C.miss}` }, what), last.evicted != null ? `, evicted tag ${hex(last.evicted, 1)}` : "");
    }
    // counters (all from the replay)
    const hits = res.filter((r) => r.kind === "hit").length, misses = k - hits;
    const n = (kind) => res.filter((r) => r.kind === kind).length;
    cnt.set("acc", `${k}/${t.length}`);
    cnt.set("hit", hits);
    cnt.set("miss", misses);
    cnt.set("kinds", `${n("cold")}/${n("capacity")}/${n("conflict")}`);
    cnt.set("rate", k ? Math.round((100 * hits) / k) + "%" : "–");
    traceEl.replaceChildren(...t.map((a, i) => h("span", { class: i < k ? (res[i].kind === "hit" ? "hit" : "miss") + (i === k - 1 ? " cur" : "") : "" }, String(a))));
    why.textContent = PRESETS[pi].why;
  }
  draw();
}));

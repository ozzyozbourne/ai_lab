/* book.js — shared runtime for "Data-Oriented Design in Rust, Zig and Odin".
 * Classic script (NOT a module) so it works from file:// as well as GitHub Pages. Exposes window.Book.
 * FROZEN API after the foundation step. Chapter authors: read components.html ("API for chapter authors").
 *
 * Load order (all `defer`): vendor/prism → book.js → data/bench-chNN.js → viz/*.js → chapter scripts.
 * Anything that needs Book must go through the command queue, which is order-independent:
 *     (window.BookQ ||= []).push((B) => B.viz.register("ch03-thing", (root, opts) => { ... }));
 * Queued functions run once the page chrome is built; later pushes run immediately.
 */
(function () {
  "use strict";
  const Book = (window.Book = window.Book || {});
  Book.version = "1.0.0";
  Book.data = Book.data || {};

  /* ======================================================================
   * Manifest: the single source of truth for navigation and the cover TOC.
   * ==================================================================== */
  Book.TOTAL = 12;
  Book.chapters = [
    { n: 1, file: "01-the-data-is-the-problem.html", title: "The Data Is the Problem",
      blurb: "What data-oriented design is (and is not), from Llopis, Acton and Fabian to Kelley and Muratori, and the shapes benchmark that starts the book." },
    { n: 2, file: "02-the-machine.html", title: "The Machine",
      blurb: "Latency ladders, cache lines, prefetchers and TLBs: the hardware facts every later chapter leans on, plus the benchmark harness." },
    { n: 3, file: "03-size-alignment-padding.html", title: "Size, Alignment and Padding",
      blurb: "How Rust, Zig and Odin lay out structs, where padding hides, and how to shrink types without losing meaning." },
    { n: 4, file: "04-aos-soa-hot-cold.html", title: "AoS, SoA and Hot/Cold Splitting",
      blurb: "Turning arrays of structs inside out: hand-written SoA, MultiArrayList, #soa, AoSoA blocks, and when AoS still wins." },
    { n: 5, file: "05-indices-handles.html", title: "Indices, Handles and Generations",
      blurb: "Replace pointers with 32-bit indices, make them typed, and catch stale handles with generations and free lists." },
    { n: 6, file: "06-allocation-strategies.html", title: "Allocation Strategies",
      blurb: "Arenas, pools, frame and temp allocators, and static allocation, with each language's allocator story." },
    { n: 7, file: "07-branches-batches-existence.html", title: "Branches, Batches and Existence",
      blurb: "Where there is one there are many: batching, existence-based processing, and branchy versus branchless code measured honestly." },
    { n: 8, file: "08-simd-and-parallelism.html", title: "SIMD and Parallelism",
      blurb: "Autovectorization and its limits, explicit vectors in all three languages, threads, and false sharing." },
    { n: 9, file: "09-ecs-and-tables.html", title: "ECS and Thinking in Tables",
      blurb: "Relational thinking, sparse sets versus archetypes, and what columnar databases already knew." },
    { n: 10, file: "10-boids-spatial-hash.html", title: "Project: Boids with a Spatial Hash",
      blurb: "A mid-book project: SoA boids, a counting-sort uniform grid, cell-ordered neighbour search and threads." },
    { n: 11, file: "11-capstone-flat-ast-compiler.html", title: "Capstone: A Compiler Front End the Zig Way",
      blurb: "Tokens as SoA, a flat AST with an extra array, string interning, and a post-order evaluator, measured against a pointer tree." },
    { n: 12, file: "12-measure-and-know-when-not-to.html", title: "Measure, and Know When Not To",
      blurb: "Benchmark methodology, tools, noise, the critiques of DOD, a checklist, and a language comparison." },
    { n: null, file: "references.html", title: "References",
      blurb: "Every source cited in the book, grouped by topic, plus the raw research notes." },
  ];
  const pageFile = (() => {
    const f = decodeURIComponent(location.pathname.split("/").pop() || "");
    return f || "index.html";
  })();
  Book.current = Book.chapters.find((c) => c.file === pageFile) || null;

  /* ======================================================================
   * Motion, colours, formatting, DOM helpers
   * ==================================================================== */
  const rmq = matchMedia("(prefers-reduced-motion: reduce)");
  Book.reducedMotion = () => rmq.matches;
  Book.onMotionChange = (fn) => rmq.addEventListener("change", () => fn(rmq.matches));

  Book.colors = () => {
    const s = getComputedStyle(document.documentElement);
    const v = (n) => s.getPropertyValue("--" + n).trim();
    return {
      bg: v("bg"), elev: v("bg-elev"), elev2: v("bg-elev2"), border: v("border"), text: v("text"), dim: v("text-dim"),
      heading: v("heading"), accent: v("accent"), pos: v("c-pos"), vel: v("c-vel"), hp: v("c-hp"),
      flag: v("c-flag"), pad: v("c-pad"), hit: v("c-hit"), miss: v("c-miss"), line: v("c-line"),
      rust: v("lang-rust"), zig: v("lang-zig"), odin: v("lang-odin"), other: v("lang-other"),
      mono: v("font-mono"), body: v("font-body"),
    };
  };
  Book.langColor = (lang) => {
    const C = Book.colors();
    return C[String(lang || "").toLowerCase()] || C.other;
  };

  const sig = (v, d) => {
    const a = Math.abs(v);
    if (a >= 100 || Number.isInteger(v)) return v.toFixed(0);
    if (a < 1) return String(+v.toPrecision(Math.max(1, d - 1))); // 0.1 → "0.1", 0.42 → "0.42" (never "0")
    if (a >= 10) return v.toFixed(Math.max(0, d - 2));
    return v.toFixed(Math.max(0, d - 1));
  };
  /** 1234 -> "1.23 µs". Picks ns/µs/ms/s. */
  Book.fmtNs = (ns, digits = 3) => {
    const a = Math.abs(ns);
    if (a >= 1e9) return sig(ns / 1e9, digits) + " s";
    if (a >= 1e6) return sig(ns / 1e6, digits) + " ms";
    if (a >= 1e3) return sig(ns / 1e3, digits) + " µs";
    return sig(ns, digits) + " ns";
  };
  const trim = (x) => String(+x.toFixed(2));
  /** 1310720 -> "1.25 MiB" */
  Book.fmtBytes = (b) => {
    if (b < 1024) return b + " B";
    if (b < 1048576) return trim(b / 1024) + " KiB";
    if (b < 1073741824) return trim(b / 1048576) + " MiB";
    return trim(b / 1073741824) + " GiB";
  };
  Book.fmtInt = (n) => Math.round(n).toLocaleString("en-US");
  /** d significant digits, but never fewer than the integer part: (0.0123,2) "0.012", (1.234,2) "1.2", (12345,2) "12,345" */
  Book.fmtSig = (v, d = 2) => {
    if (!Number.isFinite(v)) return String(v);
    if (v === 0) return "0";
    if (Math.abs(v) >= Math.pow(10, d)) return Book.fmtInt(v);
    return String(+v.toPrecision(d));
  };
  /** Ratio text without the ×: 1.27 "1.3", 12.7 "13", 127 "127", 12727.2 "12,700" (3 significant digits above 1000). */
  Book.fmtRatio = (x) => {
    if (!Number.isFinite(x)) return "–";
    if (x < 9.95) return x.toFixed(1);
    if (x < 999.5) return x.toFixed(0);
    return Book.fmtInt(+x.toPrecision(3));
  };

  /** Seeded PRNG (mulberry32): const r = Book.rng(42); r() in [0,1); r.int(n) in [0,n). */
  Book.rng = (seed = 1) => {
    let a = seed >>> 0;
    const r = () => {
      a = (a + 0x6d2b79f5) >>> 0;
      let t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
    r.int = (n) => Math.floor(r() * n);
    return r;
  };

  /** Book.h("button", {class: "btn", onclick: fn, "aria-label": "x"}, "text", childNode, [more]) */
  function setAttrs(n, attrs) {
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v == null || v === false) continue;
      if (k.startsWith("on") && typeof v === "function") n.addEventListener(k.slice(2), v);
      else if (k === "style" && typeof v === "object") Object.assign(n.style, v);
      else if (k === "text") n.textContent = v;
      else if (k === "html") n.innerHTML = v;
      else n.setAttribute(k, v === true ? "" : String(v));
    }
  }
  Book.h = (tag, attrs, ...kids) => {
    const n = document.createElement(tag);
    setAttrs(n, attrs);
    for (const c of kids.flat(Infinity)) if (c != null && c !== false) n.append(c);
    return n;
  };
  const SVGNS = "http://www.w3.org/2000/svg";
  /** Same as Book.h but creates SVG elements. */
  Book.svg = (tag, attrs, ...kids) => {
    const n = document.createElementNS(SVGNS, tag);
    setAttrs(n, attrs);
    for (const c of kids.flat(Infinity)) if (c != null && c !== false) n.append(c);
    return n;
  };
  const h = Book.h;

  /** Segmented toggle. Returns the wrapper; wrapper.set(i) selects without calling onChange. */
  Book.segmented = (labels, initial, onChange, ariaLabel) => {
    const wrap = h("div", { class: "seg", role: "group", "aria-label": ariaLabel || null });
    const btns = labels.map((lab, i) => {
      const b = h("button", { type: "button", "aria-pressed": String(i === initial) }, lab);
      b.addEventListener("click", () => { wrap.set(i); onChange(i, lab); });
      return b;
    });
    wrap.append(...btns);
    wrap.set = (i) => btns.forEach((x, j) => x.setAttribute("aria-pressed", String(j === i)));
    return wrap;
  };

  /** Labelled range slider with a live <output>.
   * Book.slider({label, min, max, step, value, format: v => v + " B", oninput: v => ...}) -> element (.input, .output) */
  Book.slider = (o) => {
    const input = h("input", { type: "range", min: o.min, max: o.max, step: o.step || 1, value: o.value });
    const out = h("output", {}, (o.format || String)(+o.value));
    input.addEventListener("input", () => { out.textContent = (o.format || String)(+input.value); o.oninput && o.oninput(+input.value); });
    const el = h("label", { class: "slider" }, o.label ? h("span", {}, o.label) : null, input, out);
    el.input = input; el.output = out;
    return el;
  };

  /** Model-driven counters rendered as <output aria-live=polite>.
   * const c = Book.counters([["lines", "lines loaded"], ["bytes", "fetched", "bad"]]); c.set("lines", 3); root.append(c.el) */
  Book.counters = (defs) => {
    const outs = {};
    const el = h("div", { class: "counters" });
    for (const [key, label, cls] of defs) {
      outs[key] = h("output", { "aria-live": "polite" }, "–");
      el.append(h("span", { class: cls || null }, label + " ", outs[key]));
    }
    return { el, outs, set(key, v) { if (outs[key]) outs[key].textContent = String(v); } };
  };

  /* ======================================================================
   * Canvas, resize, loop, player
   * ==================================================================== */
  /** HiDPI canvas with a logical coordinate system. const k = Book.canvas(el, 1000, 360); draw in 0..1000 × 0..360.
   * k.fit(w, h) changes the logical size (clears the canvas). k.cssWidth() is the on-screen CSS width, so a
   * figure can pick a stacked layout below 600px: Book.onResize(el, (w) => { k.fit(w, heightFor(w)); draw(); }) */
  Book.canvas = (el, width, height) => {
    const ctx = el.getContext("2d");
    const k = {
      ctx, el, width, height,
      fit(w = k.width, hh = k.height) {
        k.width = w; k.height = hh;
        const dpr = Math.min(window.devicePixelRatio || 1, 3);
        el.width = Math.max(1, Math.round(w * dpr));
        el.height = Math.max(1, Math.round(hh * dpr));
        el.style.aspectRatio = w + " / " + hh;
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        return k;
      },
      cssWidth() {
        const w = el.getBoundingClientRect().width;
        return w || (el.parentElement && el.parentElement.getBoundingClientRect().width) || k.width;
      },
    };
    return k.fit();
  };

  /** Calls fn(cssWidth) now (if laid out) and whenever the element's width changes. */
  Book.onResize = (el, fn) => {
    let last = -1, raf = 0;
    const check = () => {
      const w = Math.round(el.getBoundingClientRect().width);
      if (w > 0 && w !== last) { last = w; fn(w); }
    };
    check();
    const ro = new ResizeObserver(() => { cancelAnimationFrame(raf); raf = requestAnimationFrame(check); });
    ro.observe(el);
    return ro;
  };

  /** rAF loop that runs only while `el` is on screen and never autoplays under reduced motion.
   * const loop = Book.loop(el, (dt, t) => { ...; return false to stop }, {autoplay}); loop.play(); loop.pause() */
  Book.loop = (el, frame, { autoplay = true } = {}) => {
    let raf = 0, last = 0, t = 0, wanted = autoplay && !Book.reducedMotion(), visible = false;
    const tick = (now) => {
      const dt = Math.min((now - (last || now)) / 1000, 0.1);
      last = now; t += dt;
      let keep;
      try { keep = frame(dt, t); } catch (err) { console.error("[book] loop frame failed", err); keep = false; }
      if (keep === false) { wanted = false; raf = 0; api.onstop && api.onstop(); return; }
      raf = requestAnimationFrame(tick);
    };
    const sync = () => {
      if (wanted && visible && !raf) { last = 0; raf = requestAnimationFrame(tick); }
      if ((!wanted || !visible) && raf) { cancelAnimationFrame(raf); raf = 0; }
    };
    new IntersectionObserver((es) => { visible = es[es.length - 1].isIntersecting; sync(); }).observe(el);
    Book.onMotionChange((reduce) => { if (reduce && wanted) { wanted = false; sync(); api.onstop && api.onstop(); } });
    const api = {
      play() { wanted = true; sync(); }, pause() { wanted = false; sync(); },
      get playing() { return wanted; }, onstop: null,
    };
    return api;
  };

  /** Standard Play/Pause · Step · Back · Reset controls driving a step-based model.
   * const p = Book.player(root, {
   *   step:  () => bool,   // advance one step; return false when already at the end
   *   back:  () => bool,   // optional; go back one step; return false at the start (omit to hide Back)
   *   reset: () => void,   // go to the start
   *   draw:  () => void,   // pure: state -> pixels/DOM (called after every change)
   *   atEnd: () => bool,   // optional; pressing Play at the end restarts from the beginning
   *   interval: 0.4,       // seconds per step while playing
   *   loop: true,          // restart from the beginning after the end (false: stop at the end)
   *   autoplay: true,      // ignored under reduced motion
   *   still: "end",        // reduced-motion still frame: "end" (run every step) or "start"
   * }); controls.append(p.el)
   * Returns {el, play(), pause(), playing, toEnd(), sync()}. */
  Book.player = (root, o) => {
    if (!o || typeof o.step !== "function" || typeof o.reset !== "function") throw new Error("Book.player needs {step, reset, draw}");
    const interval = o.interval || 0.4;
    const draw = () => o.draw && o.draw();
    let acc = 0, hold = 0;
    const loop = Book.loop(root, (dt) => {
      acc += dt;
      if (acc < interval) return;
      acc = 0;
      if (hold > 0) {                       // paused on the final frame for a moment
        if (--hold === 0) { o.reset(); draw(); }
        return;
      }
      if (o.step() === false) {
        if (o.loop === false) { sync(); return false; }
        hold = 3;
      }
      draw();
    }, { autoplay: o.autoplay !== false });
    const play = h("button", { type: "button", class: "play", "aria-label": "Play" }, "Play");
    const sync = () => {
      play.textContent = loop.playing ? "Pause" : "Play";
      play.setAttribute("aria-label", loop.playing ? "Pause" : "Play");
    };
    loop.onstop = sync;
    play.addEventListener("click", () => {
      if (loop.playing) loop.pause();
      else { if (o.atEnd && o.atEnd()) o.reset(); hold = 0; acc = interval; loop.play(); }
      sync(); draw();
    });
    const step = h("button", { type: "button", onclick: () => { loop.pause(); sync(); o.step(); draw(); } }, "Step");
    const back = o.back ? h("button", { type: "button", onclick: () => { loop.pause(); sync(); o.back(); draw(); } }, "Back") : null;
    const reset = h("button", { type: "button", onclick: () => { hold = 0; o.reset(); draw(); } }, "Reset");
    const el = h("div", { class: "group player", role: "group", "aria-label": "Animation controls" }, play, step, back, reset);
    const api = {
      el, sync,
      play() { loop.play(); sync(); }, pause() { loop.pause(); sync(); },
      get playing() { return loop.playing; },
      toEnd() { let i = 0; while (o.step() !== false && i++ < 100000); draw(); },
    };
    // Still frame after the figure's setup code has finished (a microtask), so draw() may use anything it defines later.
    if (Book.reducedMotion() && o.still !== "start") {
      queueMicrotask(() => { try { api.toEnd(); } catch (err) { console.error("[book] player still frame failed", err); } });
    }
    sync();
    return api;
  };

  /* ======================================================================
   * SVG chart helpers (used by bench-* and latency-ladder; available to chapters)
   * ==================================================================== */
  function niceTicks(d0, d1, n = 5) {
    const span = d1 - d0 || 1, raw = span / n, p = Math.pow(10, Math.floor(Math.log10(raw)));
    const step = [1, 2, 5, 10].map((m) => m * p).find((s) => span / s <= n) || 10 * p;
    const out = [];
    for (let v = Math.ceil(d0 / step) * step; v <= d1 + step * 1e-9; v += step) out.push(+v.toPrecision(12));
    return out;
  }
  Book.scaleLinear = (d0, d1, r0, r1) => {
    const f = (v) => r0 + ((v - d0) / (d1 - d0 || 1)) * (r1 - r0);
    f.ticks = (n) => niceTicks(d0, d1, n);
    f.domain = [d0, d1];
    return f;
  };
  Book.scaleLog = (d0, d1, r0, r1, base = 10) => {
    const l0 = Math.log(d0), l1 = Math.log(d1);
    const f = (v) => r0 + ((Math.log(Math.max(v, 1e-300)) - l0) / (l1 - l0 || 1)) * (r1 - r0);
    f.ticks = () => {
      const out = [], lb = Math.log(base);
      for (let e = Math.floor(l0 / lb - 1e-9); e <= Math.ceil(l1 / lb + 1e-9); e++) {
        const v = Math.pow(base, e);
        if (v >= d0 * 0.999 && v <= d1 * 1.001) out.push(v);
      }
      return out;
    };
    f.domain = [d0, d1];
    return f;
  };
  /** Rendered width in CSS px of `text` in a CSS font shorthand, e.g. Book.textWidth("SoA", "600 12px " + C.body). */
  let measureCtx = null;
  Book.textWidth = (text, font) => {
    measureCtx ||= document.createElement("canvas").getContext("2d");
    measureCtx.font = font;
    return measureCtx.measureText(String(text)).width;
  };
  /** Axis tick label centred on px but kept inside 0..W (labels at the plot edges would otherwise spill out of
   * the card on narrow screens). Width is estimated from the 11px axis font. Pass the same `row` object ({}) for
   * every label of one axis, in left-to-right order, and a label that would overlap the previous one is skipped
   * (returns null). */
  Book.tickText = (px, W, y, label, row) => {
    const half = (String(label).length * 6.4) / 2 + 1;
    const x = Math.min(Math.max(px, half), W - half);
    if (row) {
      if (row.right != null && x - half < row.right + 4) return null;
      row.right = x + half;
    }
    return Book.svg("text", { x, y, "text-anchor": "middle" }, label);
  };
  /** Re-renders an SVG at the container's real CSS width (so text stays 11–12px at 375px).
   * Book.chart(root, (width) => svgElement) -> {el, redraw()} */
  Book.chart = (root, render) => {
    const el = h("div", { class: "chart" });
    root.append(el);
    let w = 0;
    const redraw = () => { if (w > 0) el.replaceChildren(render(w)); };
    Book.onResize(el, (cw) => { w = cw; redraw(); });
    return { el, redraw };
  };

  /* ======================================================================
   * Benchmark data. code/bench_all.sh writes assets/data/bench.js and bench-chNN.js:
   *   Book.data["ch04-particles"] = {id, machine, date, source: "measured", compilers: {rust, zig, odin},
   *     runs: [{label: "AoS", lang: "rust", n: 1048576, ns: 123456, samples: [...7 sorted ns]}, ...]}
   * ns = median wall time of one whole run of the measured function (for n elements).
   * ==================================================================== */
  Book.bench = (id) => Book.data[id] || null;
  /** Resolves a chart's data: root[data-bench] → Book.data, else inline opts.runs. */
  Book.benchSource = (root, opts) => {
    const id = root.dataset.bench || opts.bench;
    if (id) {
      const rec = Book.data[id];
      return rec ? { id, rec, runs: rec.runs || [] } : { id, missing: true };
    }
    if (Array.isArray(opts.runs)) {
      return { id: null, rec: { source: opts.source || "inline", machine: opts.machine, date: opts.date, note: opts.note, compilers: opts.compilers }, runs: opts.runs };
    }
    return { id: null, missing: true };
  };
  /** Value of one run for a metric: "ns" (median total), "ns/n" (per element), "value" (cited numbers). */
  Book.benchValue = (r, metric) => {
    if (metric === "value") return r.value;
    if (metric === "ns/n") return r.ns / r.n;
    return r.ns;
  };
  /** Text under every bench chart: machine, compilers, date, source. */
  Book.benchMeta = (src, extra) => {
    const r = src.rec || {};
    const bits = [];
    if (r.source && r.source !== "measured") bits.push(r.source);
    if (r.machine) bits.push(r.machine);
    if (r.compilers) {
      const langs = new Set((src.runs || []).map((x) => String(x.lang || "").toLowerCase()));
      const cs = Object.entries(r.compilers).filter(([k]) => !langs.size || langs.has(k)).map(([, v]) => v);
      if (cs.length) bits.push(cs.join(" · "));
    }
    if (r.date) bits.push(r.date);
    if (r.note) bits.push(r.note);
    if (extra) bits.push(extra);
    return h("p", { class: "chart-meta" }, bits.join(" · "));
  };
  function fillRatios() {
    document.querySelectorAll("[data-bench-ratio]").forEach((el) => {
      const rec = Book.data[el.dataset.benchRatio];
      if (!rec) return; // keep the author's fallback text
      const lang = (el.dataset.lang || "rust").toLowerCase();
      const pick = (label) => {
        const rs = rec.runs.filter((r) => r.label === label && String(r.lang).toLowerCase() === lang);
        const n = el.dataset.n ? +el.dataset.n : Math.max(...rs.map((r) => r.n));
        return rs.find((r) => r.n === n);
      };
      const a = pick(el.dataset.num), b = pick(el.dataset.den);
      if (!a || !b) { console.warn("[book] data-bench-ratio: no runs for", el.dataset.num, "/", el.dataset.den, "in", rec.id); return; }
      const x = a.ns / b.ns;
      el.textContent = Book.fmtRatio(x) + "×";
      el.title = `${el.dataset.num} ${Book.fmtNs(a.ns)} / ${el.dataset.den} ${Book.fmtNs(b.ns)} (${lang}, n=${a.n})`;
    });
  }
  /** Absolute measured numbers in prose:
   *   <span data-bench-val="chNN-x" data-label="SoA" data-lang="rust" data-n="1048576" data-metric="ns/n" data-digits="2">0.80 ns</span>
   * data-metric: "ns" (median, Book.fmtNs) | "ns/n" (per element, Book.fmtNs) | "value" (run.value + " " + run.unit)
   *              | "ms" (median / 1e6 + " ms"). Default "ns".
   * data-lang default "rust"; data-n default: the largest n for that label/lang; data-digits: significant digits (2).
   * Missing data or no matching run: the fallback text stays and a console.warn names the binding. */
  // time with a unit picked like fmtNs, but exactly d significant digits (0.42 ns, 1.5 µs, 27 ms)
  const fmtTime = (ns, d) => {
    const a = Math.abs(ns);
    const [div, u] = a >= 1e9 ? [1e9, " s"] : a >= 1e6 ? [1e6, " ms"] : a >= 1e3 ? [1e3, " µs"] : [1, " ns"];
    return Book.fmtSig(ns / div, d) + u;
  };
  function fillVals(quiet) {
    document.querySelectorAll("[data-bench-val]").forEach((el) => {
      const id = el.dataset.benchVal, rec = Book.data[id];
      const what = `data-bench-val="${id}" label="${el.dataset.label}"`;
      if (!rec) { if (!quiet) console.warn("[book] " + what + ": no data loaded; keeping fallback text"); return; }
      const lang = (el.dataset.lang || "rust").toLowerCase(), metric = el.dataset.metric || "ns";
      const digits = Math.max(1, Math.min(6, parseInt(el.dataset.digits, 10) || 2));
      const rs = (rec.runs || []).filter((r) => r.label === el.dataset.label && String(r.lang || "").toLowerCase() === lang);
      const n = el.dataset.n ? +el.dataset.n : Math.max(...rs.map((r) => r.n || 0));
      const r = rs.find((x) => (x.n || 0) === n);
      if (!r) { console.warn("[book] " + what + ` lang=${lang} n=${el.dataset.n || "max"}: no such run; keeping fallback text`); return; }
      let text;
      if (metric === "value") {
        if (typeof r.value !== "number") { console.warn("[book] " + what + ": run has no numeric value"); return; }
        text = Book.fmtSig(r.value, digits) + (r.unit ? " " + r.unit : "");
      } else if (metric === "ms") text = Book.fmtSig(r.ns / 1e6, digits) + " ms";
      else if (metric === "ns/n") text = fmtTime(r.ns / r.n, digits);
      else if (metric === "ns") text = fmtTime(r.ns, digits);
      else { console.warn("[book] " + what + `: unknown data-metric "${metric}"`); return; }
      el.textContent = text;
      el.title = `${rec.id} · ${r.label} · ${lang} · n=${Book.fmtInt(r.n || 0)}${rec.source ? " · " + rec.source : ""}`;
    });
  }

  /* ======================================================================
   * Viz registry: <div class="figure-body" data-viz="name" data-opts='{...}'></div>
   * Mounted once, ~300px before it scrolls into view. data-viz-state = mounted | error | unknown.
   * ==================================================================== */
  const registry = new Map();
  let started = false;
  const io = new IntersectionObserver((es) => {
    for (const e of es) if (e.isIntersecting) { io.unobserve(e.target); mount(e.target); }
  }, { rootMargin: "300px 0px" });
  // data-expect="error" / "unknown" marks deliberate failures in components.html (logged as info, not error)
  function fail(el, name, err) {
    (el.dataset.expect === "error" ? console.info : console.error)('[book] figure "' + name + '" failed:', err);
    el.dataset.vizState = "error";
    el.replaceChildren(h("div", { class: "viz-error", role: "alert" },
      h("b", {}, 'Figure "' + name + '" failed to load.'), String((err && err.message) || err)));
  }
  function mount(el) {
    if (el.dataset.vizState) return;
    const name = el.dataset.viz, fn = registry.get(name);
    if (!fn) return;
    let opts = {};
    try { opts = el.dataset.opts ? JSON.parse(el.dataset.opts) : {}; }
    catch (err) { return fail(el, name, new Error("data-opts is not valid JSON: " + err.message)); }
    el.dataset.vizState = "mounting";
    el.replaceChildren(); // drop any static fallback content
    try { fn(el, opts); el.dataset.vizState = "mounted"; } catch (err) { fail(el, name, err); }
  }
  const sel = (name) => '[data-viz="' + CSS.escape(name) + '"]';
  Book.viz = {
    /** Register a figure. Names: shared figures use plain names, chapter figures use "chNN-*". */
    register(name, fn) {
      if (typeof fn !== "function") throw new Error("Book.viz.register(" + name + "): second argument must be a function");
      if (registry.has(name)) { console.warn('[book] duplicate figure name "' + name + '" ignored (first registration wins)'); return; }
      registry.set(name, fn);
      if (!started) return;
      document.querySelectorAll(sel(name)).forEach((el) => {
        if (el.dataset.vizState === "unknown") { delete el.dataset.vizState; el.replaceChildren(); }
        if (!el.dataset.vizState) io.observe(el);
      });
    },
    has: (name) => registry.has(name),
    names: () => [...registry.keys()].sort(),
    /** Mount everything now (used before printing and by tools/smoke.sh). */
    mountAll() {
      document.querySelectorAll("[data-viz]").forEach((el) => { if (!el.dataset.vizState) { io.unobserve(el); mount(el); } });
    },
    /** Show a neutral "no data yet" box instead of a chart (not an error). */
    empty(root, msg) {
      root.dataset.vizEmpty = "1";
      root.replaceChildren(h("div", { class: "viz-empty" }, msg));
    },
    /** Throw a readable error for bad data-opts (shown in the figure box). */
    check(cond, msg) { if (!cond) throw new Error(msg); },
  };
  function markUnknown() {
    document.querySelectorAll("[data-viz]").forEach((el) => {
      if (el.dataset.vizState || registry.has(el.dataset.viz)) return;
      el.dataset.vizState = "unknown";
      (el.dataset.expect === "unknown" ? console.info : console.warn)('[book] unknown figure "' + el.dataset.viz + '"');
      el.replaceChildren(h("div", { class: "viz-unknown", role: "note" },
        h("b", {}, 'Unknown figure "' + el.dataset.viz + '"'),
        "No figure with this data-viz name is registered. Check the name and that assets/viz/" + el.dataset.viz +
        ".js (or the chapter script that registers it) is loaded. Registered: " + Book.viz.names().join(", ")));
    });
  }

  /* ======================================================================
   * Code tabs (Rust | Zig | Odin), synced page-wide and remembered across pages
   * ==================================================================== */
  const LANG_KEY = "book.lang";
  const ORDER = ["rust", "zig", "odin"];
  const NAMES = { rust: "Rust", zig: "Zig", odin: "Odin", c: "C", bash: "Shell", text: "Output" };
  let tabSeq = 0;
  const storedLang = () => { try { return localStorage.getItem(LANG_KEY); } catch { return null; } };
  const langOf = (pre) => {
    if (pre.dataset.lang) return pre.dataset.lang;
    const m = /language-(\w+)/.exec(pre.querySelector("code")?.className || "");
    return m ? NAMES[m[1]] || m[1] : "Code";
  };
  function selectInBox(box, tab) {
    const tabs = [...box.querySelectorAll(':scope > [role="tablist"] > [role="tab"]')];
    for (const t of tabs) {
      const on = t === tab;
      t.setAttribute("aria-selected", String(on));
      t.tabIndex = on ? 0 : -1;
      const p = document.getElementById(t.getAttribute("aria-controls"));
      if (p) p.hidden = !on;
    }
    const file = box.querySelector(':scope > [role="tablist"] > .file');
    if (file) file.textContent = document.getElementById(tab.getAttribute("aria-controls"))?.dataset.file || "";
  }
  /** Switch every group that has `lang`; groups without it keep their current pane (or show their first). */
  function selectLang(lang, save) {
    const want = String(lang || "").toLowerCase();
    document.querySelectorAll(".code-tabs").forEach((box) => {
      const tabs = [...box.querySelectorAll(':scope > [role="tablist"] > [role="tab"]')];
      if (!tabs.length) return;
      const target = tabs.find((t) => t.dataset.lang.toLowerCase() === want)
        || tabs.find((t) => t.getAttribute("aria-selected") === "true") || tabs[0];
      selectInBox(box, target);
    });
    if (save && lang) try { localStorage.setItem(LANG_KEY, lang); } catch {}
  }
  Book.selectLang = (lang) => selectLang(lang, true);
  function initCodeTabs() {
    document.querySelectorAll(".code-tabs").forEach((box) => {
      if (box.querySelector(':scope > [role="tablist"]')) return;
      const pres = [...box.querySelectorAll(":scope > pre")];
      const rank = (p) => { const i = ORDER.indexOf(langOf(p).toLowerCase()); return i < 0 ? 99 : i; };
      pres.sort((a, b) => rank(a) - rank(b)).forEach((p) => box.append(p));
      const list = h("div", { role: "tablist", "aria-label": "Language" });
      pres.forEach((pre) => {
        const id = "code-" + ++tabSeq, lang = langOf(pre);
        pre.id = id; pre.dataset.lang = lang; pre.setAttribute("role", "tabpanel"); pre.tabIndex = 0;
        const tab = h("button", { type: "button", role: "tab", id: id + "-tab", "aria-controls": id, "data-lang": lang }, lang);
        pre.setAttribute("aria-labelledby", id + "-tab");
        tab.addEventListener("click", () => selectLang(lang, true));
        tab.addEventListener("keydown", (e) => {
          const ts = [...list.querySelectorAll('[role="tab"]')], i = ts.indexOf(tab);
          const j = e.key === "ArrowRight" ? (i + 1) % ts.length : e.key === "ArrowLeft" ? (i - 1 + ts.length) % ts.length
            : e.key === "Home" ? 0 : e.key === "End" ? ts.length - 1 : -1;
          if (j >= 0) { e.preventDefault(); selectLang(ts[j].dataset.lang, true); ts[j].focus(); }
        });
        list.append(tab);
      });
      if (pres.some((p) => p.dataset.file)) list.append(h("span", { class: "file" }));
      box.prepend(list);
    });
    const want = storedLang();
    document.querySelectorAll(".code-tabs").forEach((box) => {
      const first = box.querySelector('[role="tab"]');
      if (first) selectInBox(box, first);
    });
    if (want) selectLang(want, false);
  }
  function highlight() {
    const P = window.Prism;
    if (!P || !P.languages) return; // offline / missing: code stays readable, just uncoloured
    try {
      if (P.languages.odin && !P.languages.odin["builtin-type"]) {
        P.languages.insertBefore("odin", "keyword", {
          "builtin-type": /\b(?:u8|u16|u32|u64|u128|i8|i16|i32|i64|i128|f16|f32|f64|uint|int|uintptr|rawptr|bool|b8|b16|b32|b64|byte|rune|string|cstring|any|typeid|u16le|u32le|u64le|u16be|u32be|u64be)\b/,
        });
      }
      P.highlightAll && P.highlightAll();
    } catch (err) { console.warn("[book] Prism highlighting failed", err); }
  }

  /* ======================================================================
   * Page chrome: top bar, sidebar TOC (drawer on mobile), anchors, prev/next, numbering
   * ==================================================================== */
  const slug = (s) => s.toLowerCase().replace(/<[^>]+>/g, "").replace(/[^\w\s-]/g, "").trim().replace(/\s+/g, "-").slice(0, 60) || "section";
  const chapterLabel = (c) => (c.n ? "Chapter " + c.n : c.title);

  function buildChrome() {
    const body = document.body, main = document.querySelector("main");
    if (!main || body.dataset.chrome === "none") return;
    main.id = main.id || "main";
    const cur = Book.current, idx = cur ? Book.chapters.indexOf(cur) : -1;
    const withSidebar = body.dataset.sidebar !== "off";
    const prev = idx > 0 ? Book.chapters[idx - 1] : idx === 0 ? { file: "index.html", title: "Contents", n: null } : null;
    const next = idx >= 0 && idx < Book.chapters.length - 1 ? Book.chapters[idx + 1] : null;

    // headings: ids + anchors
    const used = new Set([...document.querySelectorAll("[id]")].map((e) => e.id));
    const heads = [...main.querySelectorAll("h2, h3")].filter((x) =>
      !x.closest(".figure, .callout, details, .recap, .chapter-nav, .no-toc") && !x.classList.contains("no-toc"));
    for (const hd of heads) {
      if (!hd.id) {
        let id = slug(hd.textContent), k = 2;
        while (used.has(id)) id = slug(hd.textContent) + "-" + k++;
        hd.id = id; used.add(id);
      }
      if (!hd.querySelector(".anchor")) hd.prepend(h("a", { class: "anchor", href: "#" + hd.id, "aria-label": "Link to this section" }, "#"));
    }

    // top bar
    const menuBtn = withSidebar ? h("button", { type: "button", class: "menu-btn", "aria-label": "Open contents", "aria-expanded": "false", "aria-controls": "book-sidebar" }, "☰") : null;
    const where = cur ? (cur.n ? h("span", { class: "where" }, h("span", { class: "long" }, "Chapter "), cur.n + " of " + Book.TOTAL) : h("span", { class: "where" }, cur.title)) : null;
    const nav = (c, cls, arrow) => c
      ? h("a", { class: "navbtn " + cls, href: c.file, "aria-label": (cls === "prev" ? "Previous: " : "Next: ") + (c.n ? chapterLabel(c) + ", " : "") + c.title, title: c.title }, arrow)
      : h("span", { class: "navbtn " + cls, "aria-disabled": "true", "aria-hidden": "true" }, arrow);
    const topbar = h("header", { class: "topbar" + (cur ? " has-nav" : "") },
      menuBtn,
      h("a", { class: "book-title", href: "index.html", "aria-label": "Data-Oriented Design in Rust, Zig and Odin: contents" },
        h("span", { class: "t-full" }, "Data-Oriented Design"), h("span", { class: "t-short" }, "DOD"), h("span", { class: "long" }, " in Rust, Zig & Odin")),
      where, h("span", { class: "spacer" }),
      cur ? nav(prev, "prev", "←") : null,
      cur ? nav(next, "next", "→") : null);
    body.prepend(h("a", { class: "skip-link", href: "#" + main.id }, "Skip to content"), topbar);

    // page grid + sidebar
    const page = h("div", { class: "page" + (withSidebar ? " has-sidebar" : "") });
    const content = h("div", { class: "content" });
    main.before(page);
    let sidebar = null, backdrop = null;
    if (withSidebar) {
      const tocLinks = new Map();
      const toc = h("ol", {}, heads.map((hd) => {
        const a = h("a", { href: "#" + hd.id }, [...hd.childNodes].filter((n) => !(n.classList && n.classList.contains("anchor"))).map((n) => n.textContent).join("").trim());
        tocLinks.set(hd, a);
        return h("li", { class: hd.tagName === "H3" ? "toc-h3" : "toc-h2" }, a);
      }));
      const chapters = h("ol", {}, h("li", {}, h("a", { href: "index.html", "aria-current": pageFile === "index.html" ? "page" : null }, h("span", { class: "num" }, "·"), "Contents")),
        Book.chapters.map((c) => h("li", {}, h("a", { href: c.file, "aria-current": c === cur ? "page" : null }, h("span", { class: "num" }, c.n ? String(c.n) : "·"), c.title))));
      const close = h("button", { type: "button", class: "sidebar-close", "aria-label": "Close contents" }, "×");
      sidebar = h("nav", { class: "sidebar", id: "book-sidebar", "aria-label": "Contents" }, close,
        heads.length ? [h("h2", { class: "no-toc" }, "On this page"), toc] : null,
        h("h2", { class: "no-toc" }, "Chapters"), chapters);
      backdrop = h("div", { class: "backdrop" });
      page.append(sidebar);
      const open = (on) => {
        sidebar.classList.toggle("open", on); backdrop.classList.toggle("open", on);
        menuBtn.setAttribute("aria-expanded", String(on));
        if (on) (sidebar.querySelector("a.active") || sidebar.querySelector("a")).focus({ preventScroll: true });
        else menuBtn.focus({ preventScroll: true });
      };
      menuBtn.addEventListener("click", () => open(!sidebar.classList.contains("open")));
      close.addEventListener("click", () => open(false));
      backdrop.addEventListener("click", () => open(false));
      document.addEventListener("keydown", (e) => { if (e.key === "Escape" && sidebar.classList.contains("open")) open(false); });
      sidebar.addEventListener("click", (e) => { if (e.target.closest("a") && sidebar.classList.contains("open")) open(false); });
      // scrollspy
      // The active section is the last heading above a line just under the top bar (the first one at the top of
      // the page, the last one at the very bottom). Recomputed on every scroll, so it never goes stale.
      if (heads.length) {
        let active = null, raf = 0;
        const update = () => {
          raf = 0;
          const line = (parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--topbar-h")) || 52) + 24;
          let cur = heads[0];
          for (const hd of heads) { if (hd.getBoundingClientRect().top <= line) cur = hd; else break; }
          if (innerHeight + scrollY >= document.documentElement.scrollHeight - 2) cur = heads[heads.length - 1];
          const a = tocLinks.get(cur);
          if (a !== active) {
            active && active.classList.remove("active");
            a.classList.add("active");
            active = a;
            if (!sidebar.classList.contains("open")) {
              const sr = sidebar.getBoundingClientRect(), ar = a.getBoundingClientRect();
              if (ar.top < sr.top || ar.bottom > sr.bottom) sidebar.scrollTop += ar.top - sr.top - sr.height / 3;
            }
          }
        };
        const queue = () => { if (!raf) raf = requestAnimationFrame(update); };
        addEventListener("scroll", queue, { passive: true });
        addEventListener("resize", queue);
        addEventListener("load", queue);
        queue();
      }
    }
    page.append(content);
    content.append(main);
    if (backdrop) body.append(backdrop);

    // prev / contents / next at the end of a chapter
    if (cur && !main.querySelector(".chapter-nav")) {
      const card = (c, cls, lab) => c
        ? h("a", { class: cls, href: c.file }, h("small", {}, lab), (c.n ? c.n + ". " : "") + c.title)
        : h("span", { class: cls + " empty" });
      main.append(h("nav", { class: "chapter-nav", "aria-label": "Chapter navigation" },
        card(prev, "prev", "← Previous"), h("a", { class: "toc", href: "index.html" }, "Contents"), card(next, "next", "Next →")));
    }
  }

  function numberThings() {
    const n = Book.current && Book.current.n;
    const pre = n ? n + "." : "";
    const main = document.querySelector("main");
    if (!main) return;
    const figIds = new Map();
    let i = 0;
    main.querySelectorAll("figure.figure").forEach((fig) => {
      const label = "Figure " + pre + ++i;
      fig.id = fig.id || "fig-" + (n || 0) + "-" + i;
      figIds.set(fig.id, label);
      const cap = fig.querySelector(":scope > figcaption");
      if (cap && !cap.querySelector(".fig-num")) cap.prepend(h("span", { class: "fig-num" }, label + "."), " ");
    });
    main.querySelectorAll("a.figref").forEach((a) => {
      const id = (a.getAttribute("href") || "").slice(1);
      if (figIds.has(id)) a.textContent = figIds.get(id); // replaces any no-JS fallback text
      else if (!a.textContent.trim()) a.textContent = "the figure";
      if (!figIds.has(id)) console.warn("[book] figref to missing figure #" + id);
    });
    let e = 0;
    main.querySelectorAll("details.exercise").forEach((d) => {
      const s = d.querySelector(":scope > summary");
      if (s && !s.querySelector(".ex-num")) s.prepend(h("span", { class: "ex-num" }, "Exercise " + pre + ++e));
    });
  }

  /* Static inline SVG diagrams shrink their text below ~8px on phones. Wide ones (viewBox ≥ 560) get a min-width
   * of 80% of their viewBox (max 640px) inside a horizontal scroller; any figure scroller that actually overflows
   * (including chapter ones such as .ch03-scroll) gets a visible "scroll sideways" hint and a right-edge fade. */
  function scrollableSvgs() {
    const main = document.querySelector("main");
    if (!main) return;
    const scrollers = new Set();
    main.querySelectorAll("svg[viewBox]").forEach((svg) => {
      if (svg.closest("[data-viz], .chart, .svg-scroll")) return;
      const parent = svg.parentElement, ox = getComputedStyle(parent).overflowX;
      if (ox === "auto" || ox === "scroll") { scrollers.add(parent); return; }
      const vbw = svg.viewBox.baseVal && svg.viewBox.baseVal.width;
      if (!vbw || vbw < 560) return;
      const wrap = h("div", { class: "svg-scroll" });
      svg.before(wrap); wrap.append(svg);
      svg.style.minWidth = Math.round(Math.min(vbw * 0.8, 640)) + "px";
      scrollers.add(wrap);
    });
    scrollers.forEach((sc) => {
      sc.classList.add("x-scroll");
      if (!sc.hasAttribute("tabindex")) { sc.tabIndex = 0; sc.setAttribute("role", "region"); sc.setAttribute("aria-label", "Diagram (scrolls sideways)"); }
      const hint = h("p", { class: "scroll-hint", "aria-hidden": "true" }, "Scroll sideways to see the whole diagram →");
      sc.after(hint);
      const sync = () => {
        const over = sc.scrollWidth > sc.clientWidth + 2;
        hint.classList.toggle("on", over);
        sc.classList.toggle("more", over && sc.scrollLeft + sc.clientWidth < sc.scrollWidth - 4);
      };
      sc.addEventListener("scroll", sync, { passive: true });
      new ResizeObserver(sync).observe(sc);
      sync();
    });
  }

  function decorate() {
    const titles = { note: "Note", pitfall: "Pitfall", version: "Version note", try: "Try it" };
    document.querySelectorAll(".callout").forEach((c) => {
      if (c.querySelector(":scope > .callout-title")) return;
      const kind = Object.keys(titles).find((k) => c.classList.contains(k)) || "note";
      c.prepend(h("p", { class: "callout-title" }, c.dataset.title || titles[kind]));
    });
    document.querySelectorAll(".recap").forEach((r) => {
      if (!r.querySelector(":scope > .recap-title")) r.prepend(h("p", { class: "recap-title" }, r.dataset.title || "In one sentence"));
    });
    // citations: [n] → #src-n, tooltip with the source text, back-reference from the source to its first use
    const seen = new Map();
    document.querySelectorAll("a.cite").forEach((a) => {
      const id = (a.getAttribute("href") || "").slice(1), li = id && document.getElementById(id);
      if (!li) { a.classList.add("broken"); console.warn("[book] citation to missing source #" + id); return; }
      const k = (seen.get(id) || 0) + 1;
      seen.set(id, k);
      a.id = a.id || "cite-" + id + "-" + k;
      a.title = a.title || li.textContent.replace(/\s+/g, " ").trim().slice(0, 160);
      if (k === 1 && !li.querySelector(".backref")) li.append(h("a", { class: "backref", href: "#" + a.id, "aria-label": "Back to first citation" }, "↩"));
    });
    // a bare data-bench element is a bench-bars chart
    document.querySelectorAll("[data-bench]:not([data-viz])").forEach((el) => { el.dataset.viz = "bench-bars"; });
    // cover TOC: <ol class="book-toc" data-book-toc></ol>
    document.querySelectorAll("ol[data-book-toc]").forEach((ol) => {
      if (ol.children.length) return;
      ol.append(...Book.chapters.map((c) => h("li", {}, h("a", { href: c.file },
        h("span", { class: "n" }, c.n ? String(c.n).padStart(2, "0") : "§"), h("span", { class: "t" }, c.title), h("span", { class: "b" }, c.blurb)))));
    });
  }

  /* ======================================================================
   * Startup
   * ==================================================================== */
  function runQueued(fn) {
    try { fn(Book); } catch (err) { console.error("[book] BookQ callback failed", err); }
  }
  function start() {
    if (started) return;
    try { buildChrome(); } catch (err) { console.error("[book] chrome failed", err); }
    decorate();
    numberThings();
    try { scrollableSvgs(); } catch (err) { console.error("[book] scrollable SVGs failed", err); }
    initCodeTabs();
    highlight();
    fillRatios();
    fillVals(true); // bench data scripts may still be loading; the load pass below warns
    started = true;
    const q = Array.isArray(window.BookQ) ? window.BookQ.splice(0) : [];
    window.BookQ = { push: (...fns) => { fns.forEach(runQueued); return 0; } };
    q.forEach(runQueued);
    document.querySelectorAll("[data-viz]").forEach((el) => { if (!el.dataset.vizState && registry.has(el.dataset.viz)) io.observe(el); });
    const late = () => setTimeout(() => { fillRatios(); fillVals(); markUnknown(); }, 0);
    if (document.readyState === "complete") late(); else window.addEventListener("load", late);
    if (location.hash) { const t = document.getElementById(decodeURIComponent(location.hash.slice(1))); t && requestAnimationFrame(() => t.scrollIntoView()); }
  }
  window.addEventListener("beforeprint", () => Book.viz.mountAll());
  window.BookQ = window.BookQ || [];
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();

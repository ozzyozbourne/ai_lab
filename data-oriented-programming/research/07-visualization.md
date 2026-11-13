# 07 — Visualization & Front-End Design Guide

How every chapter HTML file of the data-oriented design book is built: libraries, shared assets, component APIs, and the visual style guide.
Working prototype: a scratch page (not shipped with the book) that became `assets/book.css` and `assets/book.js`.
Checked 2026-11-13 in headless Chromium (agent-browser, 1280×720 @2x) over `file://`, with reduced motion turned on, and with `cdn.jsdelivr.net` blocked.

---

## 1. Decisions (TL;DR)

| Concern | Decision |
|---|---|
| Figures (2D) | **Vanilla `<canvas>` 2D** for animated memory/cache figures, and **inline SVG** for static diagrams. No framework. |
| Charts | Hand-drawn SVG bar charts from `Book.barChart` (to add). Use **D3 v7.9.2** only if a chapter needs scales and axes it can't easily draw itself. |
| 3D hero | **Three.js r187 (`0.187.0`)** through an ES-module import map from jsDelivr. One hero per chapter at most, and optional. |
| Code highlighting | **Prism 1.30.0**: core plus `rust`, `zig`, and `odin` components (all three ship in the official package). Manual mode, no autoloader. |
| Fonts | **Inter Variable** (body) + **JetBrains Mono** (code) from `@fontsource` on jsDelivr, falling back to system fonts. |
| Shared code | `assets/book.css` + `assets/book.js` (**classic script, not a module**), so they work over `file://`. |
| Theme | Dark-only, with semantic colour tokens as CSS custom properties. |
| Motion | Nothing autoplays under `prefers-reduced-motion: reduce`, and every figure shows a meaningful still frame. |
| Offline | Text, tabs, and every 2D figure work with no network. Code loses only its colours, and the 3D hero shows a fallback caption. |

### Why highlight.js and Shiki were rejected
- **highlight.js 11.12.0**: the core build has `rust` but **no Zig or Odin**. Those grammars exist only as third-party packages (`highlightjs-zig@1.0.2`, `highlightjs-odin@1.0.1`), which are harder to rely on long term.
- **Prism 1.30.0** ships `components/prism-zig.min.js` (owner RunDevelopment) and `components/prism-odin.min.js` (owner edukisto) in the official package. All three languages come from one pinned version and one CDN. The prototype produced 190 highlighted tokens across the three panes.
- **Shiki 4.6.0** gives VS Code-quality output but loads WASM and large grammars at runtime. That is too heavy for a static book that has to work from `file://`. It could be reconsidered later as a build-time step.
- Limitation: Prism's Odin grammar does not colour built-in types such as `f32`. This is acceptable. If it bothers us, add a few lines in `book.js` that extend `Prism.languages.odin`.

---

## 2. Exact CDN URLs (each returned HTTP 200 and loaded in the browser)

Pin exact versions. Never use `@latest`, and never use unversioned URLs.

```html
<!-- Fonts -->
<link rel="preconnect" href="https://cdn.jsdelivr.net" crossorigin>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@fontsource-variable/inter@5.3.0/index.min.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@fontsource/jetbrains-mono@5.3.0/index.min.css">

<!-- Prism (manual mode: book.js calls Prism.highlightAll after building tabs) -->
<script>window.Prism = { manual: true };</script>
<script defer src="https://cdn.jsdelivr.net/npm/prismjs@1.30.0/prism.min.js"></script>
<script defer src="https://cdn.jsdelivr.net/npm/prismjs@1.30.0/components/prism-rust.min.js"></script>
<script defer src="https://cdn.jsdelivr.net/npm/prismjs@1.30.0/components/prism-zig.min.js"></script>
<script defer src="https://cdn.jsdelivr.net/npm/prismjs@1.30.0/components/prism-odin.min.js"></script>
<!-- optional: prism-c.min.js (C), prism-clike is already in core; add prism-bash.min.js / prism-nasm.min.js if needed -->

<!-- Shared book runtime (relative path, classic script, AFTER Prism so defer order holds) -->
<script defer src="../assets/book.js"></script>

<!-- Three.js import map (only on pages with a 3D figure) -->
<script type="importmap">
{
  "imports": {
    "three": "https://cdn.jsdelivr.net/npm/three@0.187.0/build/three.module.js",
    "three/addons/": "https://cdn.jsdelivr.net/npm/three@0.187.0/examples/jsm/"
  }
}
</script>

<!-- D3 only if a chapter really needs it -->
<script defer src="https://cdn.jsdelivr.net/npm/d3@7.9.2/dist/d3.min.js"></script>
```

Verified details:
- `three@0.187.0/build/three.module.js` (659 KB) imports `./three.core.js` (1.47 MB) by a relative path, which jsDelivr serves correctly. The import map needs only the two entries shown. `THREE.REVISION === "187"` was confirmed at runtime.
- Addons resolve through the import map, e.g. `import { OrbitControls } from "three/addons/controls/OrbitControls.js"`. `examples/jsm/controls/OrbitControls.js` returned 200.
- The same files are mirrored at `https://unpkg.com/three@0.187.0/...` (200). jsDelivr stays the primary CDN.
- Google Fonts (`fonts.googleapis.com/css2?family=Inter...&family=JetBrains+Mono...`) also works. `@fontsource` is preferred because it keeps everything on one CDN and is version-pinned.
- Latest versions on npm at the time of writing: three 0.187.0, d3 7.9.2, prismjs 1.30.0, highlight.js 11.12.0, @fontsource(-variable) 5.3.0.

### `file://` caveat (important)
In Chromium, a page opened from `file://` **cannot import local ES modules**, because of CORS. Inline `<script type="module">` and module imports from **https CDNs** do work (confirmed in the prototype), and so do classic `<script src="local.js">` tags. Therefore:
- `assets/book.js` must stay a classic IIFE script that exposes `window.Book`.
- Three.js code lives in an inline `<script type="module">` inside the chapter, or loads from the CDN. Do not vendor Three into `assets/` and import it as a module, because that breaks for readers who double-click the HTML file.

### Offline fallback strategy
1. **The page must read correctly with zero network.** All prose and code are in the HTML. Tabs and 2D figures come from local `book.js`. Fonts fall back to `system-ui` and `ui-monospace`.
2. **Prism missing**: `book.js` checks `window.Prism`. Code stays plain monospace text, and tabs still work.
3. **Three missing**: wrap the hero in `try { await import("three") } catch {}`. The `.hero .fallback` caption stays visible until the script adds `.ready`.
4. **D3 missing**: avoid depending on it. If a chapter uses it, check `window.d3` and show the figure's static SVG/PNG instead.
5. Optional later step: a `tools/vendor.sh` that downloads the pinned Prism and font files into `assets/vendor/`. Classic scripts and CSS can be local; Three cannot, for the `file://` reason above.

Tested result with jsDelivr blocked: the hero showed its fallback caption, all three tabs worked, the AoS/SoA figure mounted and animated, and there were 0 Prism tokens (plain code). Nothing threw an error that broke the page.

---

## 3. Repository layout

```
book/
  index.html                 # TOC, uses the same book.css
  01-why-data-layout.html … 12-*.html
  assets/
    book.css                 # design tokens, typography, components
    book.js                  # window.Book: tabs, canvas/loop helpers, viz registry, built-in figures
    figures/*.svg|png        # static fallbacks / no-JS images
```

A chapter is "self-contained" in the sense that it is one HTML file with its prose, code, and chapter-specific figure code inline. It only depends on `assets/` for shared look and behaviour. When a figure is used in 2 or more chapters, move it into `book.js` as a registered viz.

---

## 4. Component APIs for chapter authors

### 4.1 Tabbed code (Rust | Zig | Odin)
```html
<div class="code-tabs">
<pre data-lang="Rust"><code class="language-rust">…</code></pre>
<pre data-lang="Zig"><code class="language-zig">…</code></pre>
<pre data-lang="Odin"><code class="language-odin">…</code></pre>
</div>
```
- Always use the tab order Rust, Zig, Odin. Leave a pane out if that language has no equivalent, and say so in the prose.
- Escape `&`, `<`, and `>` inside code (`&amp;mut`, `&lt;T&gt;`).
- The selection is synced across every tab group on the page and saved in `localStorage["book.lang"]`, so it carries across chapters. `Book.selectLang("Zig")` sets it from code.
- Accessibility: tabs use `role=tablist/tab/tabpanel`, the left/right arrow keys switch tabs, and panels are focusable so they can scroll.
- For a single-language block, use `<pre><code class="language-zig">` without the wrapper. `book.js` still highlights it.

### 4.2 Registered figures (lazy-mounted)
```html
<figure class="figure wide">
  <div class="figure-body" data-viz="aos-soa" data-opts='{"entities":16}'></div>
  <figcaption>One sentence that says what to notice.</figcaption>
</figure>
```
```js
// in book.js (shared) or in an inline <script> at the end of a chapter (one-off)
Book.viz.register("my-figure", (root, opts) => {
  const canvas = Book.h("canvas", { role: "img", "aria-label": "…what it shows…" });
  const { ctx } = Book.canvas(canvas, 1000, 360);     // logical 1000×360, HiDPI handled
  const C = Book.colors();                             // palette read from CSS tokens
  let state = init(opts);
  const draw = () => { /* pure: state -> pixels */ };
  const loop = Book.loop(root, (dt, t) => { advance(state, dt); draw(); /* return false to stop */ });
  root.append(canvas, Book.h("div", { class: "controls" },
      Book.h("button", { type: "button", onclick: () => loop.playing ? loop.pause() : loop.play() }, "Play/Pause"),
      Book.segmented(["AoS", "SoA"], 0, (i) => { state.layout = i; draw(); })));
  if (Book.reducedMotion()) finishInstantly(state);  // show the end state, never autoplay
  draw();
});
```
Helpers in `window.Book`:

| API | Purpose |
|---|---|
| `Book.viz.register(name, (root, opts) => void)` | Mounts every `[data-viz=name]` once, about 300px before it scrolls into view. `data-opts` is parsed as JSON. Errors are caught, and the figure shows "Figure failed to load." |
| `Book.canvas(el, w, h)` → `{ctx, width, height, fit}` | Fixed logical coordinates. Sets the backing store to the DPR (max 3) and sets `aspect-ratio`, so the canvas scales responsively with CSS width: 100%. |
| `Book.loop(el, (dt,t)=>bool?, {autoplay})` → `{play, pause, playing}` | rAF loop that runs **only while `el` is on screen**. It does not autoplay under reduced motion. Returning `false` stops it. `dt` is capped at 0.1s. |
| `Book.colors()` | Reads the CSS tokens (`pos, vel, hp, flag, pad, hit, miss, line, accent, text, dim, …`). |
| `Book.reducedMotion()`, `Book.onMotionChange(fn)` | Motion preference. |
| `Book.h(tag, attrs, ...children)` | Tiny DOM builder. `on*` attributes become event listeners. |
| `Book.segmented(labels, initial, onChange)` | Toggle group with `aria-pressed` (e.g. AoS/SoA, "reads pos / pos+vel"). |
| `Book.selectLang(lang)` | Switches every code-tab group. |

### 4.3 Built-in and planned figures (one registered viz per recurring concept)
| `data-viz` | Shows | Status |
|---|---|---|
| `aos-soa` | 16-slot (4 B) rows = 64 B cache lines. Lines light up as a loop touches fields. Shows "lines loaded / bytes fetched / % useful". The access-set toggle shows that AoS catches up when you touch every field. | **Built and verified** |
| `struct-padding` | Field-by-field byte grid of a struct with alignment padding hatched. Has a "reorder fields" button (Rust's `repr(Rust)` vs `repr(C)`) and a size readout. | Planned |
| `pointer-chase` | Heap nodes scattered across a memory strip with arrows, compared with a contiguous array. A cursor walks both, and the miss counter and simulated latency (≈100 ns per miss vs ≈1 ns per hit) tick up. | Planned |
| `cache-sim` | Small set-associative cache (sets × ways). Addresses split into tag/index/offset, with hit/miss colouring and a step-through trace (model: biosconfessions.com CPU Cache Explorer). | Planned |
| `gen-handles` | Slot array of `{gen, value}` plus a free list. Shows handles `(index, gen)` going stale after free/reuse, with a red "stale" check. | Planned |
| `ecs-archetypes` | Archetype tables (columns = components, rows = entities). Adding a component moves the row to another table, with an animated move. | Planned |
| `simd-lanes` | 4/8 lanes of a register. Scalar loop vs `f32x8`, and lane masks for branches. | Planned |
| `bench-bars` | Horizontal SVG bar chart from inline JSON (`{label, ns, note}`), with a log-scale toggle, the value printed on each bar, and the machine/compiler shown in the caption. | Planned |
| hero (inline module) | Three.js `InstancedMesh` of memory cells. A "cache line" wave lifts and brightens one row at a time. | **Built and verified** |

### 4.4 3D hero pattern
Use an inline `<script type="module">` with `await import("three")` inside `try/catch`, and a single `InstancedMesh`. That is one draw call even for thousands of cells, and works well for showing lots of memory. Cap `setPixelRatio` at 2. Stop rendering while the hero is off-screen (IntersectionObserver). Under reduced motion, render one frame. Mark the hero `aria-hidden="true"` because it is decorative; the explanation must also be in text or a 2D figure. Use `renderer.setAnimationLoop`, not a hand-written rAF loop.

---

## 5. Style guide

**Palette (dark only).** bg `#0d1117`, raised surface `#151b24`, code bg `#10151d`, border `#263040`, text `#d8dee9`, dim text `#8b96a8`, headings `#f2f5fa`, accent/links/focus `#7cc4ff`.

**Semantic data colours. Every chapter uses the same meanings:**
| Token | Colour | Meaning |
|---|---|---|
| `--c-pos` | `#ff8f6b` | 1st field / the "hot" data being iterated |
| `--c-vel` | `#6bd6a8` | 2nd field (also `--c-hit`, green = good) |
| `--c-hp` | `#c79bff` | 3rd field |
| `--c-flag` | `#ffd166` | bools/flags/tags |
| `--c-pad` | `#3a4352` + diagonal hatching | padding / wasted bytes (always hatched so it isn't conveyed by colour alone) |
| `--c-miss` | `#ff6b81` | cache miss / stale handle / error |
| `--c-line` | `#7cc4ff` | cache-line outline / "loaded" state |

Data that is not being touched is drawn at 38% opacity, so "touched vs untouched" reads at a glance.

**Typography.** Body is Inter at 17px/1.7 with a 72ch measure. h1 is 2.6rem/800 and h2 is 1.6rem. Code, numbers, addresses, and stats use JetBrains Mono. Figure labels on canvas are 11–15px in the logical coordinate space.

**Layout.** Prose stays in the 72ch column. Interactive figures use `.figure.wide` (up to 1100px) to break out of it. Each figure has a single-sentence `<figcaption>` that says what to notice, and the controls sit directly under the figure (Red Blob Games' controls → algorithm → visualization flow).

**Interaction rules (learned from the reference explainers):**
- *Ciechanowski*: one idea per figure, and many small figures beat one huge dashboard. Each figure has one or two controls (a slider or toggle) directly under it. Figures load lazily and pause off-screen.
- *Red Blob Games*: keep `state → draw()` pure and redraw everything on any change, since at this scale it is cheap and avoids bugs. Controls should be directly manipulable where possible (drag a struct field, scrub a slider).
- *Nicky Case / Explorable Explanations*: open with a hook, start small, build big. Put interactivity only where it beats a static picture. Gate later figures on concepts introduced earlier.
- *Josh Comeau*: polish through tokens (CSS variables), soft surfaces, and subtle easing. Respect `prefers-reduced-motion` everywhere.
- *Cache explorers* (e.g. biosconfessions CPU Cache Explorer): include Step and Back controls and visible counters (hits, misses, bytes) so the reader can verify the numbers rather than just watch.
- Every animated figure has **Play/Pause, Step, Reset**. Any metric shown should be computed by the model, not hard-coded.

**Accessibility checklist.**
- Each canvas has `role="img"` and an `aria-label` saying what it shows, and a figcaption with the conclusion.
- No information is carried by colour alone (padding is hatched, misses also get a label or count).
- Controls are real `<button>`s and `<input type=range>`s, keyboard-reachable, with a visible `:focus-visible` ring.
- Reduced motion: no autoplay; show the finished state (verified: the AoS/SoA figure renders "entity 16/16, 8 lines / 512 B / 38%" vs "3 lines / 192 B / 100%"); the hero renders a single still frame; CSS transitions are reduced to near zero.
- Contrast: body text is well above 7:1 on the background, and dim text is above 4.5:1 (estimated, not measured with a tool). Never put dim text on `--bg-elev` at sizes under 13px.

**Benchmark charts.** Bars are horizontal, sorted, and labelled with the value. Units are always shown (ns/elem or ms). Put a "lower is better" note in the caption, and say the machine/compiler/flags. Use a log scale when values differ by more than 20×.

---

## 6. Chapter HTML skeleton

```html
<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ch. N — Title · Data-Oriented Design</title>
<!-- fonts + prism + book.js + (optional) importmap — exactly as §2 -->
<link rel="stylesheet" href="assets/book.css">
</head><body><main>
  <p class="stat">Chapter N</p><h1>Title</h1>
  <div class="hero" id="hero" aria-hidden="true"><div class="fallback">3D figure unavailable</div></div>
  … prose, .code-tabs, <figure class="figure wide"><div class="figure-body" data-viz="…"></div><figcaption>…</figcaption></figure> …
  <nav class="chapter-nav"><a href="prev.html">←</a> <a href="index.html">Contents</a> <a href="next.html">→</a></nav>
</main>
<script>/* chapter-specific Book.viz.register(...) calls */</script>
<script type="module">/* optional hero, see proto.html */</script>
</body></html>
```
Note: chapter-specific `Book.viz.register` calls must run **after** `book.js` has loaded. Because `book.js` uses `defer`, either wrap those calls in `document.addEventListener("DOMContentLoaded", …)` or put them in a `<script defer src>`/inline module, since modules are deferred too.

---

## 7. Verification log (prototype)
| Check | Result |
|---|---|
| Open `proto.html` via `file://` | ✓. `THREE.REVISION` "187", Prism loaded, 190 tokens, 3 tabs, viz mounted, no console errors |
| Odin tab click | ✓. All groups switched; `localStorage["book.lang"] = "Odin"` |
| AoS/SoA animation mid-run | ✓. AoS 4 lines / 256 B / 38% useful vs SoA 2 lines / 128 B / 75% at entity 8 |
| `prefers-reduced-motion: reduce` | ✓. No autoplay; finished static state; button reads "Play" |
| jsDelivr blocked (offline) | ✓. Hero fallback caption visible, tabs work, figure works, code plain |

Not verified: Safari/Firefox (only Chromium was tested), GitHub Pages hosting (it is static, so it should behave like file:// or better), and screen-reader output.

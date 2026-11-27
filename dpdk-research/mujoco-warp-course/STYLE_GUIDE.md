# Style guide for chapter authors

This guide is how every chapter of the MuJoCo Warp course is built. The live reference is
`chapters/_template.html`: it uses every component below, and you can copy blocks from it. Where this guide and
`planning/course-plan.md` disagree on **page mechanics** (files, markup, assets), this guide wins. On **content**
(what a chapter teaches, which examples, which rules such as W1, G, O, D, A, I), the course plan wins.

One change from plan section 0.5: pages do **not** inline the design system. Every page links the shared
`assets/course.css` and `assets/course.js` and keeps only a small chapter-specific `<style>` and `<script>`.

---

## 1. Files and names

All paths are relative to the course root `dpdk-research/mujoco-warp-course/`.

| What | Path | Rule |
|---|---|---|
| Chapter page | `chapters/<slug>.html` | `<slug>` is the slug from `planning/course-plan.json`, e.g. `05-first-simulation`. |
| Example scripts | `examples/<slug>/exNN_name.py` | One file per numbered example. Use the names the course plan gives (`ex1_env_check.py`, `ex5b_pendulum_grid.py`); the pattern is `ex<number>[letter]_<snake_name>.py`. |
| Data for figures | `examples/<slug>/data/<name>.json` (and `.png`) | Written by an example's `--dump-json PATH` / `--dump-png DIR` flag (Rule D). |
| Helper snapshots | `examples/<slug>/my_env_stepNN.py` | Running-project snapshot (plan 0.10). Not shown as a code example. |
| Notebook spec | `notebooks/specs/<slug>.py` | Input for `tools/make_notebook.py`. |
| Notebook | `notebooks/<slug>.ipynb` | Generated. Never edit by hand. |
| Shared assets | `assets/course.css`, `assets/course.js`, `assets/favicon.svg` | Do not edit from a chapter. Ask the design-system owner. |

Links from a chapter: other chapters `NN-slug.html`, home `../index.html`, reference pages
`../reference/<name>.html`, notebook `../notebooks/<slug>.ipynb`.

The Open-in-Colab link is exactly

```
https://colab.research.google.com/github/ozzyozbourne/ai_lab/blob/master/dpdk-research/mujoco-warp-course/notebooks/<slug>.ipynb
```

---

## 2. Page skeleton

Start from a copy of `chapters/_template.html` and keep this order (plan 0.5 required blocks):

1. `<head>`: charset, viewport, `<title>Ch NN · Title</title>`, the one-line theme script, Google Fonts (Inter,
   JetBrains Mono), optional KaTeX CSS, `../assets/course.css`, favicon.
2. `.progress-bar`, `header.topbar` (brand, `.chap-count` "Ch NN of 30", `.topnav` prev/next, `.theme-toggle`,
   `.toc-toggle`).
3. `.layout` > `aside.toc` (with `<ol data-auto></ol>`: filled automatically from the `h2` of each `section.sec[id]`)
   + `main#main.content`.
4. Inside `main`, in order:
   1. `header.chapter-hero`: `.eyebrow` (Part, Chapter), `h1`, `.lede`, `.hero-meta` (level badge, time,
      prerequisites), `.learn-list`, `.hero-actions` with **Open in Colab** (`.btn.btn-colab`) and **Download
      notebook** (`.btn`, `download` attribute).
   2. `section.recap` "Before you start: recap" (3-6 bullets linking the owning chapter and section).
   3. `div.mw-breadcrumb[data-here="st-..."]` for Ch 7-23 (see 5.10).
   4. Content sections: `<section class="sec" id="kebab-id"><h2><span class="sec-num">N</span>Title</h2>...`.
      The `id` goes on the section; the TOC and the `#` anchors use it.
   5. Code examples, figures, callouts inside the sections.
   6. `section#quiz` "Check yourself" (>= 6 questions; Part-ending chapters add a "Part review" quiz).
   7. `section#exercises` (>= 2 auto-checked + 1 stretch).
   8. `section#summary` with `.takeaways` and the `p.stuck` links to `../reference/troubleshooting.html` and
      `../reference/course-map.html`.
   9. `section#source-map` with `table.source-map` (Concept | File | Function; every row W1-checked).
   10. `footer.chapter-footer`: `.complete-btn[data-slug]`, `nav.pager` (`a.prev`, `a.index`, `a.next`),
       `p.site-footer` with the pinned versions.
5. Scripts at the end of `<body>`, in this order, all `defer`:
   ```html
   <script defer src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
   <script defer src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/python.min.js"></script>
   <script defer src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/xml.min.js"></script>
   <script defer src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/bash.min.js"></script>
   <script defer src="https://cdnjs.cloudflare.com/ajax/libs/KaTeX/0.16.9/katex.min.js"></script>  <!-- only if you use math -->
   <script defer src="../assets/course.js"></script>
   <script>
   document.addEventListener("DOMContentLoaded", function () {
     MW.onReady(function () { /* chapter code: canvases, steppers with draw callbacks, ... */ });
   });
   </script>
   ```
   Other allowed CDN: Chart.js 4.4.1 from cdnjs. Always an exact version. The page must stay readable when CDNs
   fail (code is plain `<pre><code>`, math shows its TeX source).

First chapter: prev = `../index.html` ("Course home"). Last chapter: next = `../index.html`.

---

## 3. Writing rules

- Plain, short sentences. Define a term before using it; wrap its first use in the chapter in
  `<abbr class="gl" data-term="anchor-id" title="one-line definition">term</abbr>` (tap shows a popover with a link
  to `../reference/glossary.html#anchor-id`).
- Cite code as `mujoco_warp/_src/<file>.py` + function name, in a `.callout.source` or the source map. Grep the
  4.0.1 wheel first (rule W1). Never invent an API.
- Private names (`mujoco_warp._src...`) get `<span class="badge private-api">private API</span>` next to the example
  title. GPU-only parts get `<span class="badge gpu-only">GPU only</span>`; outputs that come from Colab get
  `<span class="badge colab-only">from Colab, not CPU-verified</span>`.
- Never quote GPU performance numbers in prose. Notebooks print the learner's own numbers.

---

## 4. Code examples

Every example exists three times, identical: the script `examples/<slug>/exNN_name.py`, a notebook cell, and a
block on the page.

### 4.1 Script conventions (plan 0.4)

- Module docstring: `"""Example N.K - what it shows.` + how to run + flags. Docstrings are shown on the page.
- Import order, then the log level right after `import warp`:
  ```python
  import mujoco
  import numpy as np
  import warp as wp
  wp.config.log_level = wp.LOG_WARNING
  import mujoco_warp as mjw
  ```
- Budget block: `ON_GPU = wp.get_device().is_cuda`, `NWORLD = 4096 if ON_GPU else 8`, `NSTEP = 1000 if ON_GPU else 50`.
- Paste the shared MJCF model (plan 0.6) into the script; scripts are standalone.
- Flags with argparse use `args, _ = parser.parse_known_args()` (plain `parse_args()` crashes inside Jupyter, which
  passes `-f kernel.json`).
- End by printing something concrete. Check `d.overflow.numpy().any()` when the scene has contacts.
- Guards: Rule G (GPU-only APIs print `skipped on CPU: ...`), Rule O (optional libraries in try/except,
  `matplotlib.use("Agg")`, numbers printed before plots).
- Line length <= 100, 4-space indent, f-strings.

### 4.2 Verify on CPU (required before you paste any output)

```bash
cd dpdk-research/mujoco-warp-course/examples/<slug> && python -I exNN_name.py
```

Warp prints `Warp CUDA warning: Could not find or load the NVIDIA CUDA driver...` to stderr on this CPU box; it is
not part of the expected output. Copy stdout verbatim into the page's "Expected output".

### 4.3 Page markup

```html
<figure class="code-example" data-file="ex03_ball_c.py">
  <div class="code-head">
    <span class="code-title">Example 5.3</span>
    <span class="code-file">examples/05-first-simulation/ex03_ball_c.py</span>
    <span class="spacer"></span>          <!-- course.js appends the Copy button here -->
  </div>
  <pre><code class="language-python"></code></pre>   <!-- filled by tools/sync_examples.py -->
  <div class="run-note"><span>Colab: notebook cell "Example 5.3"</span><span>CPU: <code>python -I ex03_ball_c.py</code></span></div>
  <details class="output">
    <summary>Expected output <span class="out-note">CPU run, nworld=8; GPU uses nworld=4096</span></summary>
<pre class="output">...stdout copied from the CPU run...</pre>
  </details>
</figure>
```

- `data-file` is the file name in `examples/<slug>/`. Run `python3 tools/sync_examples.py chapters/<slug>.html`
  to copy (HTML-escaped) file contents into the `<code>`. Re-run it after every edit of a script.
- To show only part of a long file add `data-excerpt="true"` and paste the lines yourself (`...` lines allowed);
  the checker verifies every shown line exists in the file. The full file must still be in the notebook.
- Short snippets that are not examples (MJCF fragments, shell lines, exercise stubs) use
  `<div class="code-block"><pre><code class="language-xml">...</code></pre></div>` (Copy button added
  automatically). Languages: `language-python`, `language-xml`, `language-bash`.
- Escape `<`, `>` and `&` inside hand-written code (`&lt;`).

---

## 5. Components (class names and markup)

All of these are in `chapters/_template.html`; copy from there.

### 5.1 Callouts

```html
<div class="callout note"><p class="callout-title">Note</p><p>...</p></div>
```

Variants: `note`, `tip`, `warning` (same look as `pitfall`), `pitfall`, `danger`, `deep-dive`, `source`, `version`
(dev tree vs 4.0.1 wheel), `recall` (title "Recall from Ch N", use the plan 0.9 recall line). Collapsible expert
material:

```html
<details class="callout deeper"><summary class="callout-title">Going deeper: title</summary><p>...</p></details>
```

### 5.2 Figures

```html
<figure class="fig">
  <div class="fig-frame">            <!-- add grid-bg for a dotted background, scroll-x for wide SVGs -->
    <svg viewBox="0 0 640 260" role="img" aria-labelledby="fNt fNd">
      <title id="fNt">Short title</title><desc id="fNd">One-sentence description.</desc>
      ...
    </svg>
  </div>
  <div class="fig-toolbar">...buttons, badges...</div>
  <div class="fig-caption-line" data-placeholder="Hover, tap or tab to a part."></div>
  <figcaption><span class="fig-num">Figure N.</span>Caption. Data source or "illustrative".</figcaption>
</figure>
```

Badges for figures: `badge illustrative` (hand-drawn or JS physics), `badge data-driven` (Rule D data).
Side-by-side figures: wrap in `<div class="fig-row">`.

### 5.3 SVG diagrams that work in both themes

- Never hard-code colours. Use the paint classes from `course.css`:
  - text: `s-label` (13px bold), `s-text`, `s-small` (11px muted), `s-muted`, `s-mono`
  - shapes: `s-box`, `s-box-2` (surface + border), `s-line`, `s-ink`, `s-dashed`, `s-surface`, `s-bg`
  - accents: `s-accent`, `s-accent-stroke`, `s-accent-soft`, `s-accent2`, `s-accent2-stroke`, `s-accent2-soft`,
    `s-warn`, `s-warn-stroke`, `s-danger`, `s-danger-stroke`, `s-ok`, `s-ok-stroke`, `s-purple`, `s-teal`
  - worlds: fill `s-w0` .. `s-w7`, stroke `s-ws0` .. `s-ws7` (world k is always `--world-k`, plan A.4)
  - arrowheads: `<marker ...><path d="M0 0L10 5L0 10z" class="s-arrowhead"/></marker>`; give marker ids a
    figure prefix (`f3-arrow`) so ids stay unique on the page.
  - `fill="currentColor"` also follows the text colour. White text on world-coloured fills is fine (`fill="#fff"`).
  - In inline `style` you may use `var(--accent)` etc.
- Give every diagram `role="img"` and a `<title>`; the checker counts `svg[role=img]` for the visual budget (>= 4).
- Use a `viewBox` and no fixed width; the frame scales it. Keep text >= 11px at 640 viewBox width. Diagrams wider
  than ~720 units go in `.fig-frame.scroll-x` (they scroll inside the frame on phones, never the page).
- **Interactive parts (Rule I):** put `class="hot"` and `data-info="HTML text"` on a `<g>`. course.js makes it
  focusable, shows the text in the figure's `.fig-caption-line` on hover, focus and tap (tap pins it), and moves
  between parts with the arrow keys.

### 5.4 Animations

- CSS utilities (add to SVG or HTML elements): `anim-flow` (marching dashes on a path), `anim-pulse`, `anim-float`,
  `anim-spin`, `anim-blink`, `anim-slide` (`--dx`), `anim-swing` (`--a0`, `--a1`; set `transform-origin` in viewBox
  units), `anim-glow`, `anim-grow-x`, `anim-fade-in`. Staggering: `delay-1` .. `delay-6`; speed: `speed-slow`,
  `speed-fast`. Scroll reveal: `reveal`.
- Put `data-anim` on the figure that holds looping CSS animations and add
  `<button class="btn btn-sm anim-toggle"></button>` in its toolbar: course.js wires Play/Pause, and under
  `prefers-reduced-motion` the animations start paused (Play still works).
- Custom keyframes in the chapter `<style>` must use a class that starts with `anim-` so the reduced-motion rule
  pauses them.
- Continuous motion in a `<canvas>`: `MW.canvasAnim(canvas, draw, opts)` (5.12). Algorithms: the stepper (Rule A).
- Budget per chapter: >= 2 animations and >= 2 interactive widgets (sliders, toggles, steppers, hot regions, tabs).

### 5.5 Stepper (Rule A)

Markup from the template: `.stepper` > `.stepper-head` (`h4`, `.stepper-fn` with the real `file.py::function`),
`.stepper-body` > `.stepper-fig` (SVG) + `.stepper-side` (`pre.stepper-code`, `table.stepper-vars`),
`.stepper-caption`, `.stepper-controls` (buttons `data-act="prev|next|play|reset"`, `input[type=range]`,
`.stepper-count`), and the frames as JSON:

```html
<script type="application/json" class="stepper-data">
[{"line": 4, "vars": {"cid": 0, "nacon": 1}, "caption": "HTML caption"}, ...]
</script>
```

- `line` is 1-based in `pre.stepper-code`. Changed `vars` are highlighted automatically.
- Show/hide SVG parts per frame with `data-steps="0,2-4"` (frames, `5-` = from 5 on); add the `step-active`
  class per frame with `data-active="1,3"` (style it in the chapter CSS).
- For computed drawings: add `data-manual` to the `.stepper` and call
  `MW.stepper(el, frames, {onFrame: (i, frame, figEl) => {...}})`; frames may carry a `draw(figEl, i)` function.
- `data-autoplay` starts playing (not under reduced motion); `data-interval="800"` sets ms per frame. Keyboard: left
  and right arrows. Below 640px the panels stack.

### 5.6 Tabs

```html
<div class="tabs" data-group="lang">          <!-- data-group: same tab label selected in every group -->
  <div class="tab-list"><button aria-selected="true">Python</button><button>MJCF</button></div>
  <div class="tab-panel">...</div>
  <div class="tab-panel">...</div>
</div>
```

### 5.7 Quiz

```html
<div class="quiz">
  <div class="quiz-head"><h3>Quiz</h3><span class="quiz-score"></span></div>
  <div class="quiz-q" data-answer="b">
    <p class="q">Question?</p>
    <ul class="choices">
      <li><button data-explain="Why this one is wrong.">Choice A</button></li>
      <li><button>Choice B</button></li>
    </ul>
    <div class="quiz-feedback">Explanation shown after answering.</div>
  </div>
  <button class="btn btn-sm quiz-reset" type="button">Reset quiz</button>
</div>
```

Keys are `a`, `b`, `c`, ... in order (or set `data-key`). At least 6 questions.

### 5.8 Exercises and solutions

```html
<div class="exercise">
  <div class="exercise-head"><h3>Exercise N.1: title</h3><span class="ex-level auto">Auto-checked</span></div>
  <p>Task.</p>
  <div class="code-block"><pre><code class="language-python">... assert ...</code></pre></div>
  <details class="solution"><summary>Show solution</summary><div class="solution-body">...</div></details>
</div>
```

`ex-level auto` for assert-based exercises (CPU-runnable), `ex-level stretch` for the open one. The notebook has the
stub cell and a collapsed solution cell (`["solution", ...]` in the spec).

### 5.9 Summary blocks, tables, stats, cards

- `div.takeaways` > `h3` + `ul`.
- Tables: always `<div class="table-wrap"><table>...</table></div>` (scrolls inside on phones). `td.num` right-aligns
  numbers. Source map: `table.source-map`.
- Stat tiles: `div.stats` > `div.stat` > `div.v` + `div.k`. Cards: `div.cards` > `a.card` (`.card-num`, `h3`, `p`).
- Math: `<span class="math">TeX</span>` inline, `<div class="math-block">TeX</div>` display (needs KaTeX).

### 5.10 Shared course components (plan Appendix A)

| Component | Markup / API | Notes |
|---|---|---|
| A.1 pipeline breadcrumb | `<div class="mw-breadcrumb" data-here="st-collision st-make_constraint"></div>` | Station ids: `st-sleep` (shown only when listed or with `data-sleep`), `st-kinematics`, `st-crb`, `st-collision`, `st-make_constraint`, `st-island`, `st-transmission`, `st-velocity`, `st-actuation`, `st-acceleration`, `st-solve`, `st-rne_post`, `st-integrate`; sensor taps and the control-callback socket are drawn automatically. Stations link to their owner chapter. |
| A.2 contact pool bar | `<div class="pool-bar" data-naconmax="24" data-worlds="0,0,1,2" data-overflow="3"></div>` or `MW.poolBar(el, {naconmax, worlds, overflow})` | Cells coloured by worldid, `nacon` pointer, red capacity line, fading overflow cells. |
| A.3 efc row strip | `<div class="efc-strip" data-njmax="16" data-rows='[[["eq",2],["friction",1],["limit",1],["contact",4,"c0"]]]'></div>` or `MW.efcStrip(el, {njmax, rows})` | One row per world; block kinds `eq`, `friction`, `limit`, `contact` (+ optional label). |
| A.4 palette | CSS tokens `--world-0..7`, `--accent`, `--accent-2`, `--warn`, `--danger`; `MW.worldColor(k)` | Dark-mode world colours are the light ones lightened 15%. |
| A.5 stepper | 5.5 | |
| A.7 world replay | `<figure class="fig replay" data-src="data-chNN-exK">` with `canvas`, `.replay-controls` (`.anim-toggle`, `input[type=range]`, `.replay-time`), `.fig-caption-line`, and `<script type="application/json" id="data-chNN-exK" data-json-file="examples/<slug>/data/x.json"></script>` | JSON: `{"nworld", "dt", "frames": [[per-world value]...], "kind": "pendulum2d"\|"height"\|"points2d", "labels"?, "zmin"/"zmax" (height), "bounds" (points2d)}`. Custom drawing: `MW.replay(el, data, {draw(ctx, frame, st, fi, highlighted)})`. |
| A.8 mini3d | `MW.mini3d(canvas, scene, {yaw, pitch, scale, perspective, label})`, helpers `MW.geo.box(c, half, fill)`, `MW.geo.sphere(c, r, fill, n)`, `MW.geo.grid(size, step)` | Scene: `{polys:[{pts, fill, stroke, alpha}], lines:[{a, b, color, width, dash}], points:[{p, r, fill, label}], labels:[{p, text}]}`; z is up; colours may be `"var(--world-1)"`. Drag / arrow keys rotate, `0` resets. |
| A.9 world grid | `<div data-world-grid="32"></div>` then `el._mwGrid.setState(w, state, label)` or `MW.worldGrid(el, n)` | States: `running`, `done`, `overflow`, `asleep`, `reset` (flash). Hover/tap/arrow keys write to the figure's `.fig-caption-line`. |
| A.6 launch-shape atlas | chapter-owned (Ch 7) | Build it from `.fig` + `.seg` buttons + SVG layouts. |

### 5.11 Controls

- Slider row: `<div class="control"><label for="x">label</label><input id="x" type="range" ...><output id="x-out">v</output></div>`.
- Segmented toggle: `<div class="seg"><button aria-pressed="true">A</button><button aria-pressed="false">B</button></div>`
  (you set `aria-pressed` in your handler).
- Buttons: `btn`, `btn-primary`, `btn-ghost`, `btn-sm`. Interactive panel: `div.widget` > `p.widget-title`.

### 5.12 JavaScript API (`window.MW`)

| Function | Use |
|---|---|
| `MW.onReady(fn)` | Run chapter code after components are initialised. |
| `MW.canvasAnim(canvas, draw, {height \| aspect, autoplay, toggle, staticT})` | `draw(ctx, st)` with `st = {t, dt, w, h, frame}` in CSS pixels. Handles DPR, resize, theme change, pausing off-screen and reduced motion (starts paused). Returns `{play, pause, toggle, reset, redraw, state}`. Wires the figure's `.anim-toggle`. |
| `MW.anim(container)` | Play/pause controller for CSS animations (automatic for `[data-anim]`). |
| `MW.stepper(el, frames, opts)` | 5.5. |
| `MW.replay`, `MW.mini3d`, `MW.worldGrid`, `MW.poolBar`, `MW.efcStrip`, `MW.breadcrumb` | 5.10. |
| `MW.css("--name")`, `MW.worldColor(k)`, `MW.resolveColor("var(--x)")` | Theme colours for canvas drawing (call inside `draw` so theme changes apply). |
| `MW.onTheme(fn)` | Called after the theme toggles. |
| `MW.readJSON(id)`, `MW.svgEl(tag, attrs, parent)`, `MW.$`, `MW.$$` | Small helpers. |
| `MW.reducedMotion` | `true` when the reader prefers reduced motion. |

---

## 6. Data-driven figures (Rule D)

1. Add `--dump-json PATH` (and/or `--dump-png DIR`) to the example; decimate (about 60 frames), round to 3 decimals,
   keep it under ~300 KB.
2. Write the file to `examples/<slug>/data/<name>.json` with the CPU run.
3. On the page: `<script type="application/json" id="data-chNN-exK" data-json-file="examples/<slug>/data/<name>.json"></script>`
   (empty) and run `tools/sync_examples.py` to embed it. Pages must work from `file://`, so never `fetch()` data.
4. Caption: script name, "mujoco-warp 4.0.1, CPU run", nworld and nstep. Badge `data-driven`.
5. PNGs: embed as `data:image/png;base64,...` (under 100 KB per chapter in total).

---

## 7. Notebooks

Write a spec and generate the notebook:

```python
# notebooks/specs/05-first-simulation.py
SLUG = "05-first-simulation"
TITLE = "Ch 05 · Your First MJWarp Simulation"
SETUP = {"render": True}          # only for notebooks that use mujoco.Renderer / MUJOCO_GL
CELLS = [
    ["md", "## 1. The four calls\n..."],
    ["example", "ex01_four_calls.py", "5.1"],
    ["writefile", "my_env.py", "examples/06-batched-data-layout/my_env_step06.py"],
    ["code", "# free-form cell"],
    ["md", "## Exercise 5.1\n..."],
    ["code", "# your code here\nassert ..."],
    ["solution", "...solution code...", "Exercise 5.1"],
]
```

```bash
python3 tools/make_notebook.py notebooks/specs/<slug>.py      # writes notebooks/<slug>.ipynb
```

The tool adds, automatically and in this order: a title cell with the Colab badge, a `!nvidia-smi` cell (GPU check),
and the standard setup cell of plan 0.4 rule S (driver check, pinned `!pip install "mujoco-warp[viewer]==4.0.1"
"mujoco-core[rendering]==4.0.1"` + the right `warp-lang` build + `mediapy matplotlib`, imports, log level, `ON_GPU`,
`GRAPH_COND`). Rules:

- Code in the notebook is device-agnostic: it uses `ON_GPU` budgets exactly like the scripts.
- Every example file appears as an `["example", ...]` cell (the checker looks for the file name in the notebook).
- Helper modules are embedded with `["writefile", ...]` so the notebook runs in an empty Colab `/content`.
- Fresh-process examples (Ch 18) run as `!python file.py` after a `writefile` cell.
- Never hand-edit `.ipynb`; edit the spec and regenerate.

---

## 8. Accessibility and layout

- Phone width (360-390px) must not scroll horizontally. Wide things scroll inside `.table-wrap`, `pre`,
  `.fig-frame.scroll-x`, `.mw-breadcrumb`.
- Every interactive SVG part: `.hot` + `data-info` (focus, tap, keyboard handled for you). Canvas widgets: give the
  canvas an `aria-label`, and put readouts in a `.fig-caption-line`, not a floating tooltip.
- Respect reduced motion: use `data-anim` / `MW.canvasAnim` / the stepper, never a bare `setInterval` loop.
- Colour is never the only signal: label worlds (`w0`) or states as text too.
- Images and diagrams: `<title>` + `aria-labelledby`, or `aria-label`.

---

## 9. Before you hand in

```bash
cd dpdk-research/mujoco-warp-course
# 1. run every example on CPU (4.2) and paste stdout into "Expected output"
# 2. copy scripts and data into the page
python3 tools/sync_examples.py chapters/<slug>.html
# 3. build the notebook
python3 tools/make_notebook.py notebooks/specs/<slug>.py
# 4. check links, files, drift and the visual budget (0 ERRORs required; read the WARNs)
python3 tools/check_chapter.py chapters/<slug>.html
```

Then open the page in a browser at 390px and desktop width, in light and dark mode, and click through every widget.
Planned-but-missing pages (other chapters, `reference/*`) are WARNs while the course is being written.

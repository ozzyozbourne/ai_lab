# Course assets: `course.css` and `course.js`

Every chapter lives at `chapters/NN-slug/index.html` and loads:

```html
<link rel="stylesheet" href="../../assets/course.css">
...
<script src="../../assets/course.js"></script>   <!-- end of <body> -->
<script> CourseJS.ready(function () { /* chapter widgets */ }); </script>
```

No external libraries, no modules, no fetch: everything works from `file://`.
Start from `_template/CHAPTER_TEMPLATE.html`. `assets/demo.html` shows every
component working; copy markup from it.

## Theme and colours

Light and dark come from CSS custom properties on `:root`
(dark under `@media (prefers-color-scheme: dark)` and `html[data-theme=dark]`).
A `button.theme-toggle` cycles auto, light, dark. **Never hard-code colours** in
chapters: use the variables or the `.svg-*` classes.

| Variable | Role |
|---|---|
| `--bg --surface --surface-2 --border --text --text-muted --heading` | page |
| `--accent --accent-soft` | links, active controls |
| `--note --tip --warn --pitfall --exercise --objective` (+ `-bg`) | callouts |
| `--c1` blue, cores/lcores | diagram roles |
| `--c2` green, memory/mempool | |
| `--c3` orange, packets/mbufs | |
| `--c4` red, NIC/hardware/drops | |
| `--c5` purple, rings/queues | |
| `--c6` teal, kernel/OS | |
| `--c7` grey, neutral | |
| `--c1-soft ... --c7-soft` | box fills |
| `--svg-stroke --svg-fill --svg-text --svg-grid` | default SVG |

Read a variable from JS with `CourseJS.cssVar('--c3')`; redraw canvases on
`CourseJS.onThemeChange(fn)`.

## Page structure classes

| Class | Use |
|---|---|
| `.topbar` (+ `.brand`, `.crumb`, `.toc-toggle`, `.theme-toggle`, `.progress-bar`) | sticky top bar |
| `.page` > `nav.sidebar[data-auto-toc]` + `main.content` | two-column layout; sidebar hides below 960px and opens with `.toc-toggle` |
| `.chapter-nav` > `a.prev` / `a.index` / `a.next` (`.dir`, `.ttl`), `.placeholder` | prev / index / next |
| `.chapter-header`, `.chapter-kicker`, `.chapter-subtitle`, `.meta-row` | title block |
| `.badge` (`.level-beginner/-intermediate/-advanced`), `.tag` (`.easy/.medium/.stretch/.api`) | pills |
| `h2 > .sec-num` | section number |
| `.key-term` | first use of a term |
| `.card-grid > a.card` (`.card-num .card-title .card-desc`) | course index |
| `.grid-2`, `.center`, `.muted`, `.small`, `.nowrap`, `.visually-hidden`, `.wide` | utilities |

Every `h2`/`h3` needs an `id`; the sidebar TOC and hover anchors are generated from them.

## Boxes

```html
<section class="objectives"><div class="box-title">Learning objectives</div><ul>...</ul></section>
<section class="tools-box"><div class="box-title">Tools for this chapter</div><ul>...</ul></section>
<div class="callout note"><div class="callout-title">Note</div><p>...</p></div>     <!-- note|tip|warning|pitfall -->
<div class="exercise"><div class="box-title">Exercise 1 <span class="tag easy">easy</span></div>
  <p>...</p><details><summary>Hint</summary><p>...</p></details></div>
<section class="summary-box"><div class="box-title">Summary</div><ul>...</ul></section>
<div class="box"><div class="box-title">Anything</div>...</div>
<details><summary>Peek ahead: full source</summary><pre><code class="language-c">...</code></pre></details>
```

## Code and output

```html
<div class="code-block">
  <div class="code-head"><span class="file">code/hello.c</span><span class="lang">C</span></div>
<pre data-lines data-hl="3,5-7"><code class="language-c">...escaped C...</code></pre>
</div>
<pre><code class="language-bash">make && ./run.sh</code></pre>
```

- Languages: `language-c` (C highlighter: keywords, types, `*_t`, `struct x`, ALL_CAPS macros,
  `rte_*()` calls in bold, strings, numbers, comments, preprocessor), and
  `language-bash|sh|console|make` (comments, strings, `$VARS`, `--options`).
- `data-lines` adds line numbers, `data-start="40"` changes the first number, `data-hl="..."` highlights lines.
- A Copy button is added to each `<pre>` (in the `.code-head` when present). Opt out: `<pre data-nocopy>`.
- Escape `<`, `>`, `&` in code (`&lt;stdio.h&gt;`).

Terminal output (always real, captured output):

```html
<div class="terminal" data-copy>
  <div class="term-bar"><span class="title">code/expected_output.txt</span></div>
<pre><span class="prompt">$ </span><span class="cmd">./hello -l 0 --no-pci ...</span>
<span class="dim">EAL: ...</span>
<span class="hl">important line</span> <span class="ok">ok</span> <span class="err">error</span></pre>
</div>
<p class="output-caption">What to notice.</p>
```

`data-copy` on `.terminal` copies only the `.cmd` spans.

## Tabs and tables

```html
<div class="tabs">
  <div class="tab-list"><button class="tab-btn" data-tab="a">main.c</button><button class="tab-btn" data-tab="b">Makefile</button></div>
  <div class="tab-panel" data-tab="a">...</div><div class="tab-panel" data-tab="b">...</div>
</div>
<div class="table-wrap"><table>...<td class="num">14.88</td>...</table></div>   <!-- table.compact for dense -->
```

## Diagrams (inline SVG)

```html
<figure class="diagram">
  <svg viewBox="0 0 720 200" role="img" aria-labelledby="f1t"><title id="f1t">...</title>
    <rect class="svg-box c4" x="20" y="70" width="120" height="60"/>
    <text class="svg-label center bold" x="80" y="100">NIC</text>
    <path class="svg-arrow c4" d="M140,100 L200,100"/>
  </svg>
  <figcaption><span class="fig-num"></span>Caption.</figcaption>   <!-- empty .fig-num -> "Figure N." -->
</figure>
```

Always set `viewBox` and no fixed width: the SVG scales to the column (390px phones too).
For wide diagrams that must not shrink, wrap the svg in `<div class="scroll-x">`.

| SVG class | Effect |
|---|---|
| `.svg-box` + `.c1..c7`, `.dashed`, `.ghost` | rectangle with role colour |
| `.svg-slot`, `.svg-slot.full` | ring/table slot, empty or filled |
| `.svg-label` + `.center .bold .small .muted .mono`; `.svg-title` | text (`.center` = middle anchor + baseline) |
| `.svg-arrow` + `.c1..c7 .accent .dashed .flow .both .no-head` | arrow with arrowhead marker (`.flow` = animated dashes) |
| `.svg-line`, `.svg-grid` | plain lines |
| `.svg-packet` (+ `.c1 .c2 .c4 .c5 .dropped`) | packet |
| `.svg-fill-cN`, `.svg-stroke-cN` | raw colours |
| `.svg-highlight` | thick accent outline |
| `.svg-fade` | smooth transitions of opacity/transform/fill |
| `.svg-pulse` | pulsing |
| `.svg-hidden` | opacity 0 |

Arrowhead markers (`#arrowhead`, `#arrowhead-c1..c7`, `#arrowhead-accent`, `#arrowtail`)
are injected by `course.js`.

`.diagram-legend > span > .sw` makes a colour legend.

## Interactive widgets

```html
<div class="widget" id="w1">
  <div class="widget-head"><span class="widget-title">Title</span><span class="badge">interactive</span></div>
  <div class="widget-body"><svg viewBox="0 0 640 180"></svg></div>
  <div class="controls"><label>rate <input type="range" id="r"> <output id="ro"></output></label></div> <!-- optional -->
</div>
```

`.stat-row > .stat > .stat-label + .stat-value (+ .stat-unit)` shows live numbers.
`.btn`, `.btn.primary`, `.btn.small` for buttons.

### `CourseJS.Stepper(root, options)`: step-through with predict

```js
new CourseJS.Stepper('#w1', {
  reset: function (ctx) { /* draw initial picture; ctx.data is scratch state */ },
  steps: [
    { caption: 'Initial state' },
    { caption: 'Enqueue 3', run: function (ctx, isCurrent) { /* apply ONLY this step's change */ } },
    { caption: 'Wrap', run: fn,
      predict: { question: 'Which slot?', options: ['1', '9'], answer: 0, explain: '9 &amp; 7 = 1' } }
  ],
  interval: 1800, loop: false,
  onStep: function (i, ctx) {}
});
```

Showing step *i* calls `reset(ctx)` then `steps[0..i].run(ctx, k === i)`, so Prev
and dot jumps work without undo code. A step with `predict` asks the learner first
("predict, then step"). Controls (first, prev, play/pause, next, dots), a caption
area and Left/Right/Space keys are added automatically. Methods: `go(i) next() prev()
first() play() pause() toggle()`, properties `index`, `length`.

### `CourseJS.Animator(options)`: continuous animation

```js
var anim = new CourseJS.Animator({
  root: '#w2',                 // adds Play/Pause, Reset, Speed to .controls
  autoplay: 'visible',         // false | true | 'visible'
  speed: 1, speeds: [0.25, 0.5, 1, 2, 4],
  onReset: function (anim) { /* (re)build state; also called once at start */ },
  onFrame: function (dt, t, anim) { /* dt seconds (x speed, capped 0.1) */ }
});
anim.play(); anim.pause(); anim.toggle(); anim.reset(); anim.setSpeed(2);
```

Pauses when the tab is hidden; no autoplay under `prefers-reduced-motion`.

### SVG builders: `CourseJS.svg`

```js
var S = CourseJS.svg;
S.el('circle', {cx: 10, cy: 10, r: 4, 'class': 'svg-fill-c3'}, svg);
var g   = S.group(svg, 'svg-fade');
var r   = S.rect(svg, x, y, w, h, 'svg-box c5');           // rx=6
var b   = S.box(svg, x, y, w, h, 'lcore 1', 'c1');         // b.rect, b.label
var t   = S.text(svg, x, y, 'label', 'svg-label center');
S.line(svg, x1, y1, x2, y2); S.arrow(svg, x1, y1, x2, y2, 'c3'); S.curve(svg, x1, y1, x2, y2, 30, 'c5');
S.path(svg, 'M0,0 L10,10', 'svg-line');
var p = S.packet(svg, x, y, 24, 14, 'c1', 'A');            // centred at x,y; p.body, p.label
S.moveTo(p, x2, y2);                                         // p._x, p._y hold the position
S.clear(group);
```

### Other helpers

```js
CourseJS.ready(fn);                      // after DOM + auto-init
CourseJS.$('#id'); CourseJS.$$('.q');    // query helpers (array)
CourseJS.tween({from: {x: 0}, to: {x: 100}, duration: 400, onUpdate: function (v) {...}, onDone: fn});
CourseJS.bindRange('#r', '#ro', function (v) { return v + ' Gb/s'; }, onInput);
CourseJS.fmt(14880952) // "14,880,952";  CourseJS.fmt(6.72, 1) // "6.7"
CourseJS.clamp, CourseJS.lerp, CourseJS.ease.inOut/out/in/linear, CourseJS.sleep(ms)
CourseJS.highlightC(src) / highlightShell(src)   // -> HTML string
CourseJS.highlightAll(root); CourseJS.addCopyButtons(root); CourseJS.initTabs(root); // after injecting HTML
CourseJS.copyText(text)
```

### Quiz (5-question check)

Declarative (preferred):

```html
<div class="quiz" data-quiz>
  <div class="quiz-head">Check your understanding</div>
  <div class="q" data-answer="1" data-explain="Why.">
    <div class="q-text">Question?</div>
    <div class="q-opts"><button class="q-opt">A</button><button class="q-opt">B</button></div>
  </div>
  <div class="controls"><button class="btn small quiz-reset" type="button">Reset</button></div>
</div>
```

`data-answer` is the 0-based index of the right option. Or from JS:
`CourseJS.quiz('#el', [{q, options: [...], answer, explain}], 'Title')`.

## Testing a chapter

Render with Playwright and check for errors and horizontal scroll:

```js
const { chromium } = require('playwright');
const b = await chromium.launch();
const p = await (await b.newContext({ viewport: {width: 390, height: 800}, colorScheme: 'dark' })).newPage();
p.on('pageerror', e => console.log(e.message));
await p.goto('file://' + path);
console.log(await p.evaluate(() => document.documentElement.scrollWidth));  // must equal 390
```

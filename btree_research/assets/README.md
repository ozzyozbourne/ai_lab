# BTViz — the shared visualization toolkit

Two files, no dependencies, no build step, works from `file://`:

| File | What it is |
| --- | --- |
| `viz.css` | colour tokens, page chrome, and the classes for every component |
| `viz.js` | one global, `BTViz` (classic script — **not** an ES module) |
| `demo.html` | every component in use; read its source next to this file |
| `selftest.js` | `node assets/selftest.js` — fuzzes the models against an oracle |

Rules of the house: vanilla JS + SVG, no CDN, no `fetch`, no modules, no frameworks. Light and dark
themes, phone width (380 px) without horizontal page scroll, `prefers-reduced-motion`, keyboard
operable. The toolkit handles all of that **if you use its components and tokens** instead of
hard-coding colours, sizes and timers.

---

## 1. Minimal chapter page (copy, paste, edit)

Save as `chapters/NN-slug/viz/index.html`. Paths assume that depth (`../../../assets/…`).

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Insertion and splitting</title>
<link rel="stylesheet" href="../../../assets/viz.css">
</head>
<body>

<p class="bt-lead">Insert keys and watch a full leaf split.</p>
<div id="fig"></div>

<!-- <script src="code.js"></script>   optional: defines window.CHAPTER_CODE, see 3.7 -->
<script src="../../../assets/viz.js"></script>
<script>
(function () {
  'use strict';
  BTViz.page({
    title: 'Insertion and splitting', chapter: 4,
    prev: '../../03-search/viz/index.html', next: '../../05-deletion-and-rebalancing/viz/index.html'
  });

  var fig = BTViz.figure('#fig', { title: 'Insert into a B-tree of order 4', side: true,
                                   legend: ['node-active', 'key-compare', 'key-inserted', 'split'] });
  var view = new BTViz.TreeView(fig.stage, { minHeight: 240 });
  var log  = new BTViz.Log(fig.side, { title: 'Events' });
  var tree = BTViz.models.BTree(4).insertMany([10, 20, 30]);

  var input = BTViz.el('input.bt-input', { type: 'number', 'aria-label': 'Key', placeholder: 'key' });
  var go = BTViz.el('button.bt-btn.bt-primary', { type: 'button', onclick: insert }, 'Insert');
  fig.toolbar.append(input, go);

  var steps = tree.insert(40);                     // real operation → list of steps
  var stepper = new BTViz.Stepper({
    mount: fig.controls, caption: fig.caption, root: fig.root, steps: steps,
    onStep: function (step, i) { view.render(step.state, step.highlight); log.sync(stepper ? stepper.steps : steps, i); }
  });

  function insert() {
    if (input.value === '') return;
    stepper.setSteps(tree.insert(+input.value), { play: true });
    input.value = '';
  }
  input.addEventListener('keydown', function (e) { if (e.key === 'Enter') insert(); });

  // The JS model must reproduce what the chapter's Zig/Rust program printed:
  BTViz.selfTest('final keys', tree.keys().join(' '), '10 20 30 40');
})();
</script>
</body>
</html>
```

`<script>` tags go at the **end of `<body>`**; `BTViz.page()` wraps whatever is already in the body.

---

## 2. The step format (the contract between models, Stepper and views)

A visualization is an array of steps. The Stepper only cares about `caption` and `state`/`apply`;
everything else is passed through to your `onStep`.

```js
{
  caption: 'Leaf <b class="bt-k">[10 | 20 | 30 | 40]</b> overflows…',  // HTML allowed
  state:   { ... },            // FULL snapshot of what to draw (plain data), or instead:
  apply:   function (s) { s.n++; },   // mutate a deep copy of the previous state (or return a new one)
  highlight: { ... },          // whatever your view's 2nd argument is
  log:     'split n3',         // or {html, state}; shown by Log.sync()
  hold:    2,                  // optional: stay on this step 2× longer while playing
  question: { prompt, choices: ['…', '…'], answer: 1, explain: '…' },   // optional, "predict" mode
  type, op, …                  // anything else you want in onStep
}
```

Snapshots are cached, so stepping **back**, scrubbing and restarting always work. Never mutate a
`state` you receive in `onStep`; treat snapshots as immutable. Prefer `state` (snapshot) steps —
the models emit them for you.

`onStep(step, index, info)` receives the step with `step.state` resolved, plus
`info = {prev, direction: -1|0|1, instant, stepper}`. Just call `view.render(...)` — views pick the
animation duration themselves (speed slider, scrubbing and reduced motion are handled for you).

---

## 3. API reference

### 3.1 Page chrome

**`BTViz.page({title, chapter, prev, next, index, guide, footer})`** → `{header, main, footer}`
Header with chapter badge + title, Prev / Index / Next links, theme toggle; wraps the body content in
`<main class="bt-main">`; footer with the same nav. `prev`/`next`/`index` are an href string or
`{href, title}`; `null` renders a disabled placeholder. `index` defaults to `../../../index.html`.
`chapter` is a number (`4` → "Chapter 4") or any string.

**`BTViz.figure(target, {title, side, legend})`** → `{root, toolbar, stage, side, caption, controls, legend}`
One card. Put views in `stage`, form controls in `toolbar` (hidden while empty), `Log`/`codePanel`
in `side` (only with `side: true`; it drops below the stage on narrow screens), and hand
`controls`/`caption`/`root` to a Stepper. A page may hold any number of figures.

```js
var fig = BTViz.figure('#fig', { title: 'Search', side: true, legend: ['key-compare', 'key-found'] });
```

**`BTViz.legend(target, items)`** — items are token names (`'split'`) or `{token, label, line}`.

**`BTViz.theme`** — `.get()` → `'light'|'dark'`, `.set('light'|'dark'|'auto')`, `.toggle()`,
`.onChange(fn)`, `.button()`. `page()` already adds the toggle; the choice is remembered in
`localStorage` and applied by setting `data-theme` on `<html>`.

Toolbar classes: `.bt-btn` (`.bt-primary`, `.bt-icon`), `.bt-input`, `.bt-select`,
`.bt-field` (label + control), `.bt-toolbar-sep`.

### 3.2 `BTViz.Stepper`

```js
var stepper = new BTViz.Stepper({
  steps: steps,                 // may be [] and set later
  onStep: function (step, i, info) { view.render(step.state, step.highlight); },
  mount: fig.controls,          // where the control bar goes (omit for a headless stepper)
  caption: fig.caption,         // element that receives step.caption
  root: fig.root,               // element that owns the keyboard shortcuts
  speed: 1, interval: 1100,     // ms per step at 1×
  loop: false, autoplay: false,
  predict: false,               // true/false: show the "Predict" checkbox (see below)
  initialState: {}              // base state for the first apply() step
});
```

| Method | |
| --- | --- |
| `setSteps(steps, {play, index})` | replace the timeline (use after every user operation) |
| `next()` `prev()` `restart()` `end()` `go(i)` | navigation; `go` across more than one step is instant |
| `play()` `pause()` `toggle()` `setSpeed(x)` | playback (0.25× … 4×) |
| `state(i)` | cached snapshot of step `i` |
| `index`, `steps`, `playing` | read-only properties |

Controls: restart, step back, play/pause, step forward, scrubber, "step i / n", speed slider.
Dragging the scrubber pauses playback and jumps straight to the chosen step.
Keyboard (focus anywhere in the figure, or nothing focused): <kbd>Space</kbd> play/pause,
<kbd>←</kbd>/<kbd>→</kbd> step, <kbd>Home</kbd>/<kbd>End</kbd>.

**Predict mode.** Give a step a `question`. When the reader ticks *Predict* and advances onto that
step, the stepper pauses, shows the prompt and the choices in the caption area, then reveals the
step with a ✓/✗ verdict. Optional `onAnswer(stepIndex, choiceIndex, ok)` in the options.

### 3.3 `BTViz.TreeView`

```js
var view = new BTViz.TreeView(fig.stage, { minHeight: 240 });
view.render(model, highlight);
```

**Model** (plain JSON; `tree.snapshot()` produces it):

```js
{ id: 'n1',                 // unique, stable across steps — drives the animation
  keys: [10, 20],           // numbers or strings
  children: [ {…}, {…}, {…} ],   // nested nodes, keys.length + 1 of them (omit / [] for a leaf)
  leaf: false,
  next: 'n7',               // optional: id of the next leaf → solid sibling arrow (B+tree)
  right: 'n7',              // optional: id of the right sibling → dashed right-link arrow (B-link)
  highKey: 30,              // optional: dashed "high key" cell at the right end
  meta: { label: 'page 12', // small text above the node (page id)
          note: 'lsn 40',   // small text below
          dirty: true,      // dirty dot
          lock: 'S',        // latch badge(s): 'S' | 'X' | 'S?' (waiting) | 'T2:X' | {mode, label, blocked} | [ … ]
          state: 'dirty' }  // default highlight state for this node
}
```

- **Binary trees**: by default an only child is centred under its parent, so left and right look the
  same. Either give the child a hint, `children: [{id: 'n9', keys: [9], side: 'right'}]`
  (`side: 'left' | 'right'`), or create the view with `binary: true` and write children positionally as
  `[left, right]` with `null` for a missing one (`children: [null, {…}]`). The child is then drawn to
  that side and its edge leaves the matching corner of the parent. `side` on a node that has siblings
  is ignored for placement; without either option nothing changes.
- **Forest**: pass an array of roots.
- **DAG / copy-on-write**: list a node under a second parent as `{ref: 'id'}` (or repeat the same
  node object); it is drawn once, under its first parent, with an extra edge from the second.
- `null` / empty model draws an "empty" node.

**Highlight** — states are the names in §4:

```js
{ nodes:  { n3: 'active', n4: 'split' },
  keys:   { 'n3:17': 'compare', '*:17': 'inserted', 'n3:high': 'compare' },  // 'nodeId:key', '*:key' = anywhere
  edges:  { n4: 'active', 'n1>n4': 'active' },    // child id, or 'parent>child' (needed in a DAG)
  links:  { n5: 'active' },                       // sibling arrow leaving n5
  cursor: { node: 'n3', label: 17 } }             // pill hovering over a node ("the key being searched")
```

Animation between successive `render()` calls: nodes are matched by `id` (move / resize / fade), keys
by value (a promoted key slides up into the parent, a B+tree separator copy grows out of its source),
new nodes emerge from the node their first key came from. First render is instant.

Options: `minHeight`, `maxHeight`, `zoom: 'fit' | number`, `minScale` (0.7 — fit never shrinks below
it; wider trees scroll inside the view), `toolbar` (zoom buttons), `onNodeClick(id, node)`,
`ariaLabel`, `binary` (false; see *Binary trees* above), and geometry `cellH`, `minCellW`, `charW`,
`hGap`, `vGap`.
Methods: `render(model, highlight)`, `highlight(h)` (states only, no re-layout), `setZoom(z)`,
`nodeEl(id)`, `destroy()`. Pan: drag, touch-scroll or scrollbars; zoom: buttons, pinch, or
<kbd>Ctrl</kbd>+wheel. The view scrolls itself to keep highlighted nodes visible.
`BTViz.TreeView.layout(model[, opts])` is the pure layout function (`{nodes: Map, order, edges, width, height}`);
`opts` takes the geometry options and `binary`.

Legible up to roughly 60 nodes; beyond that reduce the key range or raise the order.

### 3.4 `BTViz.PageView` — a slotted disk page

```js
var pv = new BTViz.PageView(fig.stage, { cols: 16 });
pv.render({
  size: 128, headerSize: 8, slotSize: 2,
  header: [{ name: 'n', len: 2, value: 3 }, …],          // optional labels over the header bytes
  slots: ['c2', 'c1', 'c3'],                              // cell ids in slot order
  cells: [{ id: 'c1', off: 116, len: 12, label: '30', dead: false }, …]
}, { cells: { c1: 'inserted' }, slots: { 1: 'inserted' }, pointers: [1] });   // pointers: [slot…] | 'all'
```

Bytes are matched by cell id, so inserting shifts slot entries and defragmenting slides cells.
The chips underneath show header / slots / free / cells / dead byte ranges. Keep `size` ≤ 256.
Use `BTViz.models.SlottedPage` (§3.9) to generate models and steps.

### 3.5 `BTViz.ArrayView`

```js
var av = new BTViz.ArrayView(fig.stage);
av.render({ values: [3, 8, 12, 17],       // null = empty slot
            states: { 2: 'compare' },     // by index
            pointers: { lo: 0, mid: 2, hi: 4 },   // may point one past the end
            range: [0, 4],                // cells outside [lo, hi) are dimmed
            capacity: 6,                  // optional: draw empty slots up to here
            ids: […] });                  // optional identities (default: the value)
```

Cells are matched by identity between renders, so inserting or removing a value makes the others
slide. The dashed slot outlines always stay underneath the cells, also when `capacity` grows later.
`BTViz.steps.binarySearch(values, target)` returns ready-made steps (`step.phase` is
`'init' | 'mid' | 'less' | 'greater' | 'done'`; `steps.index`, `steps.found`).

### 3.6 `BTViz.Log`

```js
var log = new BTViz.Log(fig.side, { title: 'Events', max: 200 });
log.add('split n3 → n3 + n8', 'split');      // html, optional state
log.clear();
log.sync(steps, i);                          // inside onStep: show step.log of steps[0..i]
```

### 3.7 `BTViz.codePanel`

```js
// viz/code.js — a classic script, no fetch:
window.CHAPTER_CODE = { search: { zig: "fn search(…) …", rust: "fn search(…) …" } };

var code = BTViz.codePanel(fig.side, 'search');            // by name from window.CHAPTER_CODE
var code = BTViz.codePanel(fig.side, { zig: '…', rust: '…' }, { title: 'search', maxHeight: 300 });
code.highlight([3, 4]);                       // same lines in both tabs
code.highlight({ zig: [3, [5, 7]], rust: 4 });  // per language; [a, b] = inclusive range
code.setTab('rust');
```

Common indentation and leading/trailing blank lines are stripped; line numbers start at 1.
Built-in tinting for `zig`, `rust`, `js`, `c` (keywords, types, numbers, strings, `//` comments,
calls, `@builtins`). The chosen tab is remembered and shared by all panels on the page.
Typical wiring: `onStep: function (s) { code.highlight(s.lines); }`.

### 3.8 More views

All of them are "dumb": call `render(model)` from `onStep`.

**`BTViz.Lanes`** — swim lanes with a "who steps next" button per lane.

```js
var lanes = new BTViz.Lanes(fig.stage, { onAdvance: function (id) { /* advance your model, re-render */ } });
lanes.render({ next: 'T2', lanes: [
  { id: 'T1', label: 'T1 · reader', state: 'blocked', status: 'waiting for latch', canStep: false,
    events: [{ text: 'latch S root', state: 'lock-shared' }] },
  { id: 'T2', label: 'T2 · writer', state: 'running', events: [] } ] });
```
Lane `state`: `running | blocked | done | aborted` or any highlight state.

**`BTViz.Timeline`** — records in a row plus a draggable (and keyboard-operable) crash marker.

```js
var tl = new BTViz.Timeline(fig.stage, { onCrash: function (n) { draw(n); } });   // n = records that survived
tl.render({ crash: 6, records: [{ label: 'insert 31', state: 'durable', sub: 'page 6' }, …] });
```
Record `state`: `pending | durable | lost | applied | torn` or any highlight state. `crash: null` hides the marker.

**`BTViz.FrameGrid`** — buffer-pool frames and a clock hand.

```js
new BTViz.FrameGrid(fig.stage).render({ hand: 2,
  frames: [{ page: 7, pin: 1, ref: 1, dirty: false }, { page: null }] });
```

**`BTViz.MemoryMap`** — fixed-size slots / slabs.

```js
new BTViz.MemoryMap(fig.stage, { cell: 30 }).render({ slabs: [
  { label: 'slab 0', slots: ['used', 'free', { state: 'handle', label: 7 }, { state: 'deleted' }] } ] });
```

**`BTViz.HexGrid`** — hex dump with offsets, coloured ranges and labels.

```js
new BTViz.HexGrid(fig.stage, { cols: 16 }).render({ bytes: [0x0d, 0, 0, …],
  ranges: [{ from: 0, len: 1, state: 'active', label: 'page type' }] });
```

**`BTViz.Chart`** — bar histogram or live line chart (SVG, axis labels, legend, direct value labels).

```js
var bars = new BTViz.Chart(fig.stage, { type: 'bar', xLabel: 'keys per leaf', yLabel: 'leaves' });
bars.render({ labels: [3, 4, 5], series: [{ name: 'sequential', values: [0, 75, 0] }, { name: 'random', values: [0, 20, 13] }] });

var line = new BTViz.Chart(fig.stage, { type: 'line', xLabel: 'inserts', yLabel: 'count' });
line.push({ splits: 3, merges: 1 }, 100);     // one point per series; label optional
```
Options: `height`, `yMax`, `maxPoints`, `legend: true`; series may set `token` (a colour token name).

**`BTViz.GraphView`** — 2D points and edges in your own coordinate units.

```js
var gv = new BTViz.GraphView(fig.stage, { height: 280, onNodeClick: fn });
gv.render({ nodes: [{ id: 'a', x: 0, y: 0 }, { id: 'q', x: 5, y: 2, label: 'query', shape: 'cross' }],
            edges: [{ from: 'a', to: 'b' }],
            regions: [{ points: [[0, 0], [4, 0], [2, 3]], state: 'merge' }] },
          { nodes: { a: 'active' }, edges: { 'a>b': 'active' } });
```
Shapes: `circle` (default), `square`, `diamond`, `cross`.
Options: `height`, `pad`, `r`, `ariaLabel`, `onNodeClick(id, node)` and `onPlaneClick(x, y, event)` —
called with the click position **in model coordinates** (the units of your nodes), e.g. to place a
query point. A click on a node goes to `onNodeClick` only when that is set, otherwise to
`onPlaneClick`. `gv.toModel(clientX, clientY)` → `{x, y}` does the same conversion for your own
pointer handlers.

### 3.9 Reference models — generate steps from real operations

Conventions (fixed for the whole guide): **order M = maximum number of children**; a node holds at
most M − 1 keys and, unless it is the root, at least ⌈M/2⌉ − 1; default M = 4. Splits happen on
overflow (bottom-up); underflow is repaired by borrowing from the left sibling, then the right,
else merging. In a B+tree the separators are **copies** (child *i+1* holds keys ≥ separator *i*),
leaves hold at most M − 1 keys and are chained through `next`.

`BPlusTree` has two leaf conventions, chosen with `{convention}`:

| | leaf minimum (non-root) | overflowing leaf of n = M keys splits into | M = 4 | M = 5 |
| --- | --- | --- | --- | --- |
| default | ⌈(M−1)/2⌉ | left ⌈n/2⌉, right ⌊n/2⌋ | min 2, split 2 + 2 | min 2, split 3 + 2 |
| `{convention: 'guide'}` | ⌈M/2⌉ − 1, as every other node | left ⌊n/2⌋ (the lower half), right ⌈n/2⌉ | min 1, split 2 + 2 | min 2, split 2 + 3 |

In both the separator is a copy of the right leaf's first key and a key equal to a separator is routed
right. **`'guide'` is the convention of PLAN.md and of the chapter 07 Zig/Rust programs** (it produces
the same tree shapes as that chapter's model for the same operations); use it whenever a page must
match what a chapter program prints. The default is kept for the pages that already rely on it.
`t.convention` reads back `'default'` or `'guide'`; `BTree` accepts the option and ignores it.

```js
var t = BTViz.models.BTree(4);            // or BTViz.models.BPlusTree(4); `new` is optional
var g = BTViz.models.BPlusTree(4, { convention: 'guide' });   // leaf minimum and split point of PLAN.md
t.insertMany([10, 20, 30]);               // silent
var steps = t.insert(40);                 // → array of steps; steps.ok === true
steps = t.delete(20);                     // steps.ok === false when the key was absent
steps = t.search(30);                     // steps.found
steps = bplus.scan(15, 60);               // B+tree only; steps.result = keys in range
t.insert(50, { steps: false });           // mutate without recording
t.snapshot();  t.keys();  t.has(30);  t.size;  t.height();  t.nodeCount();
t.limits();    // {maxKeys, minLeafKeys, minInternalKeys, maxChildren}
t.validate();  // [] when every invariant holds, else error strings
```

Options: `{detail: 'key'}` adds one `compare-key` step per key comparison (default: one `compare`
step per node); `{cmp}`; `{idPrefix}`; `{convention: 'guide'}` (B+tree only, see above).

Each step is `{type, caption, state, highlight, op: {kind, key}, log}` where `state` is a TreeView
model and `highlight` a TreeView highlight. Step `type`s:

| Operation | Types, in order of appearance |
| --- | --- |
| search | `start`, `compare`…, `found` \| `not-found` |
| insert | `start`, `compare`…, `exists` \| `insert-leaf`, then per overflow `overflow` + (`split` \| `root-grow`), `done` |
| delete (B-tree) | `start`, `compare`…, `not-found` \| `remove` \| (`found-internal`, `predecessor`, `replace`), then per underflow `underflow` + (`borrow-left` \| `borrow-right` \| `merge`), `root-shrink`, `done` |
| delete (B+tree) | as above without the predecessor steps |
| scan (B+tree) | `start`, `compare`…, `scan-leaf`…, `done` |

You may post-process steps (rewrite captions, attach `question`, `lines`, drop steps) before handing
them to the Stepper. To animate several operations in one timeline, concatenate their step arrays.

```js
var pg = BTViz.models.SlottedPage({ size: 128, headerSize: 8, slotSize: 2 });
pg.insert(30, 12);           // key, cell length in bytes[, label] → steps (find-slot, [defragment], write-cell, write-slot | full | exists)
pg.delete(30);               // find, remove-slot | not-found
pg.defragment();             // before, defragment
pg.snapshot();  pg.keys();  pg.freeSpace();  // {contiguous, total}
```

If your chapter needs a variant (proactive splitting, B-link, three-sibling balance…), write your
own model in the chapter and emit the same step shape — the views do not care where steps come from.

### 3.10 Helpers

| | |
| --- | --- |
| `BTViz.el('div.cls#id', {attrs}, …children)` | create DOM/SVG. Attrs: `class`, `text`, `html`, `style: {…}`, `dataset`, `onclick: fn`, anything else → attribute. SVG tag names get the SVG namespace automatically. |
| `BTViz.rng(seed)` | seeded PRNG: `r()`, `r.int(lo, hi)`, `r.pick(a)`, `r.shuffle(a)`, `r.sample(n, lo, hi)` (distinct). **Use it instead of `Math.random()`** so pages are reproducible. |
| `BTViz.k(value, state?)` | `<b class="bt-k s-compare">17</b>` for captions |
| `BTViz.esc(s)`, `BTViz.clone(v)` | HTML-escape; deep copy of plain data |
| `BTViz.selfTest(name, actual, expected, target?)` | → boolean. Strings compare ignoring trailing whitespace, everything else structurally. Shows a ✓/✗ badge at the end of `<main>` and `console.error`s on mismatch (so the Playwright check fails). Long names wrap inside the badge (the full name is also its tooltip). Results in `BTViz.selfTest.results`. |
| `BTViz.motion` | `.duration()` → ms for the current step (0 when scrubbing or reduced motion). Use it for your own animations; `.off = true` disables animation. |

---

## 4. Colour tokens and highlight states

Every semantic token `X` is a pair of CSS custom properties: `--bt-X` (strong: strokes, swatches)
and `--bt-X-bg` (soft fill; normal text stays readable on it). All pairs are contrast-checked in both
themes. Base tokens: `--bt-bg`, `--bt-surface`, `--bt-surface-2`, `--bt-text`, `--bt-muted`,
`--bt-border`, `--bt-accent`, `--bt-font`, `--bt-mono`.

| Highlight state (`s-…`) | Token | Use it for |
| --- | --- | --- |
| *(none)* | `node`, `key` | resting node / key |
| `active` | `node-active` | the node / edge / lane being worked on |
| `compare` | `key-compare` | key being compared, candidate, pending |
| `found` | `key-found` | search hit, success, durable |
| `inserted` | `key-inserted` | newly written key / cell |
| `deleted` | `key-deleted` | key about to disappear, lost, error |
| `split` | `split` | overflowing node, halves, promoted key |
| `merge` | `merge` | underflowing node, merged node |
| `dirty` | `page-dirty` | page modified in memory |
| `lock-shared`, `lock-exclusive` | same | latch / lock modes |
| `free` | `free` | free space, empty frame (hatched) |
| `pointer` | `pointer` | child pointers, slot entries |
| `dim` | — | de-emphasise |

The same state names work in every view (tree nodes and keys, array cells, page bytes, lanes,
records, frames, slots, hex ranges, graph nodes), in `.bt-chip`, `.bt-table tr`, `.bt-k`, and in
your own elements: add class `s-compare` and paint with `var(--s)` / `var(--s-bg)`.

Other reusable classes: `.bt-panel` + `.bt-panel-title` + `.bt-panel-body`, `.bt-chip`,
`.bt-lock.is-shared|.is-exclusive`, `.bt-table` inside `.bt-table-wrap`, `.bt-lead`, `kbd`, `code`.

---

## 5. Do and don't

**Do**
- Drive every frame from a model (the built-in ones or your own) and keep **stable node ids**.
- Write a caption for every step, in full sentences, using `BTViz.k()` for keys.
- Give every figure a legend listing exactly the states it uses.
- Rebuild the timeline with `stepper.setSteps(steps, {play: true})` after each user action.
- Use `BTViz.rng(seed)`; keep trees ≤ ~60 nodes and pages ≤ 256 bytes.
- Add `BTViz.selfTest(...)` calls comparing the JS model with your Zig/Rust program's output.
- Check your page with Playwright at 1280×800 and 390×844, light and dark, with no console errors.

**Don't**
- Don't use `<script type="module">`, `import`, `fetch`, CDNs or web fonts — `file://` must work.
- Don't hard-code colours, `setTimeout` animation chains or pixel widths; use tokens, the Stepper and
  the views. Don't put wide content directly in the page — views scroll inside themselves.
- Don't mutate snapshots, and don't reuse a node id for a different node within one timeline.
- Don't call `BTViz.page()` from `<head>`, and don't edit `viz.js` / `viz.css` for one chapter — put
  chapter-specific CSS in a `<style>` block using the tokens.
- Don't rely on colour alone: say in the caption what the highlight means.

## 6. Known limitations

- TreeView keys are primitives (numbers/strings) and are matched by value; a tree with duplicate
  keys in one node still renders, but the slide animation may pick either twin.
- In a DAG a shared child is positioned under its *first* parent only.
- The syntax tinting is line-based: no multi-line comments or Zig `\\` strings.
- `PageView` and `HexGrid` render one element per byte; keep them small.
- `Chart` is intentionally tiny: non-negative values, linear axis from 0, no tooltips beyond `<title>`.

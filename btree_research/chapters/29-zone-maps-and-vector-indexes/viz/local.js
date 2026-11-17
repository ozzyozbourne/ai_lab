/*
 * Chapter 29 — chapter-local view helpers (the shared toolkit has no
 * "interval per row" view, and GraphView reports clicks on nodes only).
 *
 *   Ch29.RangeBars(target, opts).render({domain, rows, band})
 *       one horizontal [min, max] bar per row on a shared number line
 *   Ch29.subnav(target, current)      links between the three pages
 *   Ch29.planeClick(graphView, a0, a1, fn)
 *       turn a click anywhere on a GraphView into data coordinates, using two
 *       anchor nodes whose data coordinates are known
 *   Ch29.kv(target, rows)             small two-column table of counters
 *   Ch29.sideLast(fig)                on narrow screens, put the figure's side
 *       panels below the caption and step controls, so the text that narrates
 *       the picture stays next to the picture
 *   Ch29.fixScrub(stepper)            work-around for a toolkit quirk: a click
 *       on the step slider during auto-play only paused (see the function)
 *
 * Colours come from the toolkit's state classes (s-found, s-compare, ...).
 */
(function () {
  'use strict';
  var el = BTViz.el, Ch29 = window.Ch29;

  var css = [
    '.c29-bars { min-width: 0; border: 1px solid var(--bt-border); border-radius: 6px; background: var(--bt-bg); overflow: hidden; }',
    '.c29-bars svg { display: block; max-width: 100%; font-family: var(--bt-mono); }',
    '.c29-bar rect { fill: var(--s-bg, var(--bt-key-bg)); stroke: var(--s, var(--bt-node)); stroke-width: 1.2; }',
    '.c29-bar.is-current rect { stroke-width: 2.6; }',
    '.c29-bar.is-pending rect { fill: none; stroke-dasharray: 3 2; opacity: .75; }',
    '.c29-bar text { font-size: 10.5px; fill: var(--bt-muted); }',
    '.c29-bar.is-current text, .c29-bar[class*="s-"] text.c29-note { fill: var(--s, var(--bt-text)); font-weight: 700; }',
    '.c29-band { fill: var(--bt-accent); fill-opacity: .13; }',
    '.c29-band-edge { stroke: var(--bt-accent); stroke-width: 1.5; }',
    '.c29-band-label { font-size: 11px; font-weight: 700; fill: var(--bt-accent); }',
    '.c29-axis { stroke: var(--bt-border); stroke-width: 1; }',
    '.c29-tick { font-size: 10px; fill: var(--bt-muted); }',
    '.c29-subnav { display: flex; flex-wrap: wrap; gap: 6px 8px; margin: 0 0 14px; font-size: .9rem; }',
    '.c29-subnav a, .c29-subnav span { padding: 3px 10px; border-radius: 999px; border: 1px solid var(--bt-border); text-decoration: none; }',
    '.c29-subnav span { background: var(--bt-accent-bg); border-color: var(--bt-accent); font-weight: 650; }',
    '.c29-grid3 { display: grid; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr)); gap: 12px; width: 100%; }',
    '.c29-grid3 h4 { margin: 0 0 4px; font-size: .86rem; }',
    '.c29-grid3 p { margin: 4px 0 0; font-size: .8rem; color: var(--bt-muted); }',
    '.c29-kv td:last-child { text-align: right; font-family: var(--bt-mono); font-variant-numeric: tabular-nums; }',
    '.c29-layers { display: grid; gap: 8px; width: 100%; }',
    '.c29-layer-title { font-size: .78rem; font-weight: 650; color: var(--bt-muted); margin: 0 0 2px; }',
    '.c29-plane { cursor: crosshair; }',
    '.c29-probe { display: grid; gap: 10px; grid-template-columns: minmax(0, 1fr); width: 100%; }',
    '@media (min-width: 1040px) { .c29-probe { grid-template-columns: minmax(0, 3fr) minmax(0, 2fr); align-items: start; } }',
    '.c29-probe .c29-layer-title { min-height: 2.6em; }',
    // Narrow screens: the toolkit stacks stage, side panels, caption, controls. Dissolve the body
    // wrapper so the side panels can be ordered after the caption and the controls.
    '@media (max-width: 820px) {',
    '  .bt-figure.c29-side-last { display: flex; flex-direction: column; }',
    '  .bt-figure.c29-side-last > .bt-figure-body { display: contents; }',
    '  .bt-figure.c29-side-last > .bt-figure-body > .bt-side { order: 1; }',
    '}'
  ].join('\n');
  document.head.appendChild(el('style', css));

  /**
   * rows:   [{label, min, max, state?, note?, current?, pending?}]
   * band:   {lo, hi, label?}   the predicate's interval, drawn across all rows
   * domain: [lo, hi]
   * opts:   {rowH = 16, labelW = 30, noteW = 40, axis = true}
   */
  function RangeBars(target, opts) {
    var self = this;
    this.opts = { rowH: 16, labelW: 30, noteW: 40, axis: true };
    for (var key in (opts || {})) this.opts[key] = opts[key];
    this.svg = el('svg', { role: 'img', 'aria-label': this.opts.ariaLabel || 'Value range of every chunk' });
    this.root = el('div.c29-bars', this.svg);
    (typeof target === 'string' ? document.querySelector(target) : target).appendChild(this.root);
    if (typeof ResizeObserver !== 'undefined') {
      var last = -1;
      new ResizeObserver(function () {
        var w = self.root.clientWidth;
        if (w !== last) { last = w; if (self.model) self.render(self.model); }
      }).observe(this.root);
    }
  }
  RangeBars.prototype.render = function (model) {
    this.model = model;
    var o = this.opts, svg = this.svg, rows = model.rows;
    var W = Math.max(180, this.root.clientWidth || 600), top = model.band ? 16 : 6;
    var H = top + rows.length * o.rowH + (o.axis ? 22 : 6);
    var x0 = o.labelW + 4, x1 = W - o.noteW - 6, lo = model.domain[0], hi = model.domain[1];
    var X = function (v) { return x0 + (Math.min(Math.max(v, lo), hi) - lo) / (hi - lo) * (x1 - x0); };
    svg.textContent = '';
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    svg.setAttribute('width', W);
    svg.setAttribute('height', H);
    var bottom = top + rows.length * o.rowH;
    if (model.band) {
      var b0 = X(model.band.lo), b1 = Math.max(X(model.band.hi), b0 + 1.5);
      svg.appendChild(el('rect', { class: 'c29-band', x: b0, y: top - 2, width: b1 - b0, height: bottom - top + 4 }));
      svg.appendChild(el('line', { class: 'c29-band-edge', x1: b0, x2: b0, y1: top - 2, y2: bottom + 2 }));
      svg.appendChild(el('line', { class: 'c29-band-edge', x1: b1, x2: b1, y1: top - 2, y2: bottom + 2 }));
      if (model.band.label) {
        var mid = (b0 + b1) / 2, anchor = mid < x0 + 60 ? 'start' : mid > x1 - 60 ? 'end' : 'middle';
        svg.appendChild(el('text', { class: 'c29-band-label', x: anchor === 'start' ? b0 : anchor === 'end' ? b1 : mid, y: 11, 'text-anchor': anchor }, model.band.label));
      }
    }
    rows.forEach(function (r, i) {
      var y = top + i * o.rowH, a = X(r.min), b = Math.max(X(r.max), a + 2);
      var g = el('g', { class: 'c29-bar' + (r.state ? ' s-' + r.state : '') + (r.current ? ' is-current' : '') + (r.pending ? ' is-pending' : '') },
        el('svg:title', r.label + ': min ' + r.min + ', max ' + r.max + (r.note ? ' — ' + r.note : '')));
      if (o.labelW) g.appendChild(el('text', { x: o.labelW, y: y + o.rowH / 2, 'text-anchor': 'end', 'dominant-baseline': 'central' }, r.label));
      g.appendChild(el('rect', { x: a, y: y + 2, width: b - a, height: o.rowH - 4, rx: 2 }));
      if (o.noteW && r.note) g.appendChild(el('text', { class: 'c29-note', x: W - 4, y: y + o.rowH / 2, 'text-anchor': 'end', 'dominant-baseline': 'central' }, r.note));
      svg.appendChild(g);
    });
    if (o.axis) {
      svg.appendChild(el('line', { class: 'c29-axis', x1: x0, x2: x1, y1: bottom + 4, y2: bottom + 4 }));
      var n = W < 420 ? 2 : 4;
      for (var t = 0; t <= n; t++) {
        var v = Math.round(lo + (hi - lo) * t / n);
        svg.appendChild(el('line', { class: 'c29-axis', x1: X(v), x2: X(v), y1: bottom + 4, y2: bottom + 8 }));
        svg.appendChild(el('text', { class: 'c29-tick', x: X(v), y: bottom + 18, 'text-anchor': t === 0 ? 'start' : t === n ? 'end' : 'middle' }, String(v)));
      }
    }
    return this;
  };

  function subnav(target, current) {
    var pages = [['index.html', '1 · Zone-map pruning'], ['ivf.html', '2 · IVF probing'], ['hnsw.html', '3 · Greedy graph descent'], ['../README.md', 'Chapter text']];
    var nav = el('nav.c29-subnav', { 'aria-label': 'Pages of this chapter' });
    pages.forEach(function (p) {
      nav.appendChild(p[0] === current ? el('span', { 'aria-current': 'page' }, p[1]) : el('a', { href: p[0] }, p[1]));
    });
    var host = typeof target === 'string' ? document.querySelector(target) : target;
    host.appendChild(nav);
  }

  /**
   * Call fn(x, y) in data coordinates when the GraphView is clicked anywhere.
   * a0 / a1: {id, x, y} of two nodes present in every render (opposite corners).
   */
  function planeClick(gv, a0, a1, fn) {
    gv.svg.classList.add('c29-plane');
    gv.svg.addEventListener('click', function (e) {
      var c0 = gv.svg.querySelector('g[data-id="' + a0.id + '"] circle'), c1 = gv.svg.querySelector('g[data-id="' + a1.id + '"] circle');
      if (!c0 || !c1) return;
      var box = gv.svg.getBoundingClientRect(), vb = gv.svg.viewBox.baseVal;
      var px = (e.clientX - box.left) * (vb.width / box.width), py = (e.clientY - box.top) * (vb.height / box.height);
      var sx0 = +c0.getAttribute('cx'), sy0 = +c0.getAttribute('cy'), sx1 = +c1.getAttribute('cx'), sy1 = +c1.getAttribute('cy');
      var x = a0.x + (px - sx0) / (sx1 - sx0) * (a1.x - a0.x), y = a0.y + (py - sy0) / (sy1 - sy0) * (a1.y - a0.y);
      var cl = function (v, lo, hi) { return Math.round(Math.min(Math.max(v, lo), hi)); };
      fn(cl(x, a0.x, a1.x), cl(y, a0.y, a1.y));
    });
  }

  /** rows: [[label, value, state?]] → a compact table inside `target` (replaces content). */
  function kv(target, rows) {
    var host = typeof target === 'string' ? document.querySelector(target) : target;
    host.textContent = '';
    var tb = el('tbody');
    rows.forEach(function (r) { tb.appendChild(el('tr', { class: r[2] ? 's-' + r[2] : null }, el('td', r[0]), el('td', String(r[1])))); });
    host.appendChild(el('div.bt-table-wrap', el('table.bt-table.c29-kv', tb)));
  }

  function sideLast(fig) { fig.root.classList.add('c29-side-last'); }

  /**
   * Toolkit quirk (assets/viz.js, Stepper._build): the step slider's handler calls pause() before it
   * reads the slider, and pause() writes the current step back into the slider when the stepper was
   * playing. So the first click on the slider during auto-play only paused. This chapter auto-plays
   * after most interactions, so remember the value the reader asked for (capture phase, before the
   * toolkit's handler) and go there afterwards if the toolkit did not. A no-op once the toolkit is fixed.
   */
  function fixScrub(stepper) {
    var scrub = stepper.ui && stepper.ui.scrub, host = stepper.ui && stepper.ui.root, wanted = null;
    if (!scrub || !host) return;
    host.addEventListener('input', function (e) { if (e.target === scrub) wanted = +scrub.value; }, true);
    host.addEventListener('input', function (e) {
      if (e.target !== scrub || wanted === null) return;
      if (stepper.index !== wanted) stepper.go(wanted, { instant: true });
      wanted = null;
    });
  }

  Ch29.RangeBars = RangeBars;
  Ch29.subnav = subnav;
  Ch29.planeClick = planeClick;
  Ch29.kv = kv;
  Ch29.sideLast = sideLast;
  Ch29.fixScrub = fixScrub;
})();

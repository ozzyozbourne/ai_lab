/*!
 * BTViz — shared visualization toolkit for "Understanding B-trees, from simple to complex".
 * Vanilla JS + SVG, no dependencies, no build step, works from file://.
 * Load with a classic script tag:  <script src="../../../assets/viz.js"></script>
 * Everything hangs off the global `BTViz`. API documentation: assets/README.md.
 * The model code (BTViz.models, BTViz.rng, BTViz.Stepper logic, BTViz.TreeView.layout)
 * also runs under node: `const BTViz = require('./viz.js')`.
 */
(function (root) {
  'use strict';

  var hasDOM = typeof document !== 'undefined' && typeof window !== 'undefined';
  var BTViz = { version: '1.0.0' };

  /* ======================================================================
   * 1. Small helpers
   * ==================================================================== */

  var SVG_NS = 'http://www.w3.org/2000/svg';
  var SVG_TAGS = {};
  ('svg g path rect circle ellipse line polyline polygon text tspan defs marker clipPath ' +
    'use pattern linearGradient radialGradient stop foreignObject').split(' ')
    .forEach(function (t) { SVG_TAGS[t] = 1; });

  /** Deep-copy plain data (objects, arrays, primitives). */
  function clone(v) {
    if (v === null || typeof v !== 'object') return v;
    if (Array.isArray(v)) return v.map(clone);
    var o = {};
    for (var k in v) if (Object.prototype.hasOwnProperty.call(v, k)) o[k] = clone(v[k]);
    return o;
  }

  /** Escape text for use inside HTML. */
  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }

  function resolve(target) {
    var t = typeof target === 'string' ? document.querySelector(target) : target;
    if (!t) throw new Error('BTViz: target element not found: ' + target);
    return t;
  }

  /**
   * Create a DOM or SVG element.
   *   el('div.bt-chip', {title: 'x', onclick: fn}, 'text', childNode, [more, children])
   * SVG tag names (svg, g, path, rect, circle, line, text, …) get the SVG namespace
   * automatically; prefix with "svg:" to force it (e.g. 'svg:title').
   */
  function el(tag, attrs) {
    var m = /^(svg:)?([a-zA-Z][\w-]*)((?:[.#][\w-]+)*)$/.exec(tag);
    if (!m) throw new Error('BTViz.el: bad tag "' + tag + '"');
    var isSvg = !!m[1] || SVG_TAGS[m[2]] === 1;
    var node = isSvg ? document.createElementNS(SVG_NS, m[2]) : document.createElement(m[2]);
    var classes = [];
    (m[3].match(/[.#][\w-]+/g) || []).forEach(function (p) {
      if (p[0] === '#') node.id = p.slice(1); else classes.push(p.slice(1));
    });
    var first = 1;
    var isAttrs = attrs && typeof attrs === 'object' && !Array.isArray(attrs) && !attrs.nodeType;
    if (isAttrs) {
      first = 2;
      for (var k in attrs) {
        var v = attrs[k];
        if (v === null || v === undefined || v === false) continue;
        if (k === 'class') classes.push(v);
        else if (k === 'text') node.textContent = v;
        else if (k === 'html') node.innerHTML = v;
        else if (k === 'style' && typeof v === 'object') {
          for (var p in v) {
            if (p.indexOf('--') === 0) node.style.setProperty(p, v[p]); else node.style[p] = v[p];
          }
        } else if (k === 'dataset') { for (var d in v) node.dataset[d] = v[d]; }
        else if (k.slice(0, 2) === 'on' && typeof v === 'function') node.addEventListener(k.slice(2), v);
        else node.setAttribute(k, v === true ? '' : v);
      }
    }
    if (classes.length) node.setAttribute('class', classes.join(' '));
    for (var i = first; i < arguments.length; i++) append(node, arguments[i]);
    return node;
  }
  function append(parent, child) {
    if (child === null || child === undefined || child === false) return;
    if (Array.isArray(child)) { child.forEach(function (c) { append(parent, c); }); return; }
    parent.appendChild(child.nodeType ? child : document.createTextNode(String(child)));
  }

  /**
   * Seeded PRNG (mulberry32). `const r = BTViz.rng(42); r(); r.int(1, 99); r.pick(a);
   * r.shuffle(a); r.sample(10, 1, 99)`. Same seed → same sequence, everywhere.
   */
  function rng(seed) {
    var a;
    if (typeof seed === 'string') {
      a = 2166136261;
      for (var i = 0; i < seed.length; i++) { a ^= seed.charCodeAt(i); a = Math.imul(a, 16777619); }
      a >>>= 0;
    } else a = (seed === undefined ? 1 : seed) >>> 0;
    var f = function () {
      a = (a + 0x6D2B79F5) >>> 0;
      var t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
    f.int = function (lo, hi) { return lo + Math.floor(f() * (hi - lo + 1)); };
    f.pick = function (arr) { return arr[Math.floor(f() * arr.length)]; };
    f.shuffle = function (arr) {
      var b = arr.slice();
      for (var i = b.length - 1; i > 0; i--) {
        var j = Math.floor(f() * (i + 1)), t = b[i]; b[i] = b[j]; b[j] = t;
      }
      return b;
    };
    /** n distinct integers in [lo, hi], in random order. */
    f.sample = function (n, lo, hi) {
      var span = hi - lo + 1, out = [], seen = {};
      n = Math.min(n, span);
      while (out.length < n) {
        var v = f.int(lo, hi);
        if (!seen[v]) { seen[v] = 1; out.push(v); }
      }
      return out;
    };
    return f;
  }

  /** `<b class="bt-k">17</b>` — an inline key for captions. Optional state: 'compare', 'found', … */
  function k(value, state) {
    return '<b class="bt-k' + (state ? ' s-' + state : '') + '">' + esc(value) + '</b>';
  }

  /* ---------------------------------------------------------------------
   * Motion: one place that decides how long animations take.
   * Stepper sets `speed`/`instant` around each onStep call; views read it.
   * ------------------------------------------------------------------- */
  var motion = {
    base: 450,        // ms at speed 1
    speed: 1,
    instant: false,   // true while scrubbing / jumping several steps
    off: false,       // set true to disable all animation (tests)
    reduced: function () {
      return hasDOM && !!window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    },
    duration: function (base) {
      if (this.off || this.instant || this.reduced()) return 0;
      return Math.max(90, (base || this.base) / (this.speed || 1));
    }
  };

  /* ======================================================================
   * 2. Theme
   * ==================================================================== */
  var theme = {
    storageKey: 'btviz-theme',
    _subs: [],
    _stored: function () { try { return window.localStorage.getItem(this.storageKey); } catch (e) { return null; } },
    /** Effective theme: 'light' or 'dark'. */
    get: function () {
      var a = document.documentElement.getAttribute('data-theme');
      if (a === 'light' || a === 'dark') return a;
      return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    },
    /** set('light' | 'dark' | 'auto') — 'auto' follows the OS again. */
    set: function (t) {
      var de = document.documentElement;
      try {
        if (t === 'auto') { de.removeAttribute('data-theme'); window.localStorage.removeItem(this.storageKey); }
        else { de.setAttribute('data-theme', t); window.localStorage.setItem(this.storageKey, t); }
      } catch (e) { if (t !== 'auto') de.setAttribute('data-theme', t); }
      this._notify();
    },
    toggle: function () { this.set(this.get() === 'dark' ? 'light' : 'dark'); },
    onChange: function (fn) { this._subs.push(fn); },
    _notify: function () { var t = this.get(); this._subs.forEach(function (fn) { fn(t); }); },
    /** Returns a ready-wired toggle <button>. */
    button: function () {
      var self = this;
      var icon = el('svg', { viewBox: '0 0 16 16', 'aria-hidden': 'true' },
        el('path', { d: 'M8 1.5a6.5 6.5 0 1 0 0 13zM8 3v10a5 5 0 0 1 0-10z', 'fill-rule': 'evenodd' }),
        el('circle', { cx: 8, cy: 8, r: 6.5, fill: 'none', stroke: 'currentColor', 'stroke-width': 1.2 }));
      var label = el('span');
      var b = el('button.bt-btn.bt-theme-toggle', { type: 'button', onclick: function () { self.toggle(); } }, icon, label);
      var sync = function (t) {
        label.textContent = t === 'dark' ? 'Dark' : 'Light';
        b.setAttribute('aria-label', 'Colour theme: ' + t + '. Switch to ' + (t === 'dark' ? 'light' : 'dark') + '.');
        b.title = 'Switch to ' + (t === 'dark' ? 'light' : 'dark') + ' theme';
      };
      sync(this.get());
      this.onChange(sync);
      return b;
    },
    _init: function () {
      var s = this._stored(), self = this;
      if (s === 'light' || s === 'dark') document.documentElement.setAttribute('data-theme', s);
      if (window.matchMedia) {
        var mq = window.matchMedia('(prefers-color-scheme: dark)');
        var cb = function () { self._notify(); };
        if (mq.addEventListener) mq.addEventListener('change', cb); else if (mq.addListener) mq.addListener(cb);
      }
    }
  };
  if (hasDOM) theme._init();

  /* ======================================================================
   * 3. Page chrome: page(), figure(), legend()
   * ==================================================================== */

  function navLink(spec, label, rel) {
    if (!spec) return el('span.bt-nav-off', { 'aria-hidden': 'true' }, label);
    var href = typeof spec === 'string' ? spec : spec.href;
    var title = typeof spec === 'string' ? null : spec.title;
    return el('a', { href: href, rel: rel || null, title: title || null }, label);
  }

  /**
   * Build the standard chapter page chrome around whatever is already in <body>.
   * Call it from a script at the END of <body>.
   *   BTViz.page({ title, chapter, prev, next, index, guide })
   * prev / next / index: 'href' or {href, title}. Returns {header, main, footer}.
   */
  function page(o) {
    o = o || {};
    var body = document.body;
    body.classList.add('bt-page');
    var index = o.index === undefined ? '../../../index.html' : o.index;
    var chap = o.chapter === undefined || o.chapter === null ? null :
      (typeof o.chapter === 'number' ? 'Chapter ' + o.chapter : String(o.chapter));
    if (o.title) document.title = (chap ? chap + ' — ' : '') + o.title;

    var mk = function () {
      return el('nav.bt-nav', { 'aria-label': 'Chapter navigation' },
        navLink(o.prev, '← Prev', 'prev'), navLink(index, 'Index', 'index'), navLink(o.next, 'Next →', 'next'));
    };
    var nav = mk();
    nav.appendChild(theme.button());
    var header = el('header.bt-header', el('div.bt-header-in',
      el('div.bt-header-titles',
        el('a.bt-guide', { href: index || '#' }, o.guide || 'Understanding B-trees'),
        el('h1', chap ? el('span.bt-chapter', chap) : null, o.title || '')),
      nav));

    var main = body.querySelector('main');
    if (!main) {
      main = el('main');
      Array.prototype.slice.call(body.childNodes).forEach(function (n) {
        if (n.nodeType === 1 && (n.tagName === 'SCRIPT' || n.tagName === 'HEADER' || n.tagName === 'FOOTER')) return;
        main.appendChild(n);
      });
      body.insertBefore(main, body.firstChild);
    }
    main.classList.add('bt-main');
    body.insertBefore(header, body.firstChild);

    var footNav = mk();
    footNav.setAttribute('aria-label', 'Chapter navigation (bottom)');
    var footer = el('footer.bt-footer', el('div.bt-footer-in',
      el('span', o.footer || 'Space: play/pause · ←/→: step · Home/End: first/last step'), footNav));
    main.parentNode.insertBefore(footer, main.nextSibling);
    return { header: header, main: main, footer: footer };
  }

  var LEGEND_LABELS = {
    'node': 'node', 'node-active': 'active node', 'key': 'key', 'key-compare': 'comparing',
    'key-found': 'found', 'key-inserted': 'inserted', 'key-deleted': 'deleted',
    'split': 'split / promoted', 'merge': 'underflow / merge', 'pointer': 'pointer',
    'page-dirty': 'dirty page', 'lock-shared': 'shared lock', 'lock-exclusive': 'exclusive lock',
    'free': 'free space'
  };

  /**
   * Fill `target` with legend entries. Items are token names ('key-compare', 'split', …)
   * or {token, label}.  BTViz.legend(fig.legend, ['key-compare', {token:'split', label:'median'}])
   */
  function legend(target, items) {
    var host = resolve(target);
    host.textContent = '';
    host.classList.add('bt-legend');
    (items || []).forEach(function (it) {
      var token = typeof it === 'string' ? it : it.token;
      var label = (typeof it === 'string' ? null : it.label) || LEGEND_LABELS[token] || token;
      var sw = el('span.bt-swatch', { style: { '--s': 'var(--bt-' + token + ')', '--s-bg': 'var(--bt-' + token + '-bg)' } });
      if (it === 'pointer' || it.line) sw.classList.add('is-line');
      if (token === 'free') sw.classList.add('is-hatch');
      host.appendChild(el('span.bt-legend-item', sw, label));
    });
    return host;
  }

  /**
   * Build one visualization card inside `target`.
   *   const fig = BTViz.figure('#fig1', { title, side: true, legend: [...] })
   * Returns { root, toolbar, stage, side, caption, controls, legend }.
   * Put your views in fig.stage, inputs in fig.toolbar, Log/code panel in fig.side,
   * and pass `mount: fig.controls, caption: fig.caption, root: fig.root` to a Stepper.
   */
  function figure(target, o) {
    o = o || {};
    var host = resolve(target);
    var f = {};
    f.toolbar = el('div.bt-toolbar');
    f.stage = el('div.bt-stage');
    f.side = o.side ? el('aside.bt-side') : null;
    f.caption = el('div.bt-caption', { 'aria-live': 'polite' });
    f.controls = el('div.bt-controls-slot');
    f.legend = el('div.bt-legend');
    f.root = el('figure.bt-figure', { tabindex: 0, 'aria-label': o.title || 'Visualization' },
      o.title ? el('figcaption.bt-figure-title', o.title) : null,
      f.toolbar,
      el('div.bt-figure-body' + (o.side ? '.has-side' : ''), f.stage, f.side),
      f.caption, f.controls, f.legend);
    if (o.legend) legend(f.legend, o.legend);
    host.appendChild(f.root);
    return f;
  }

  /* ======================================================================
   * 4. Stepper — timeline engine
   * ==================================================================== */

  var SPEEDS = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4];
  var ICONS = {
    restart: 'M2.5 3h2v10h-2zM13.5 3v10L6 8z',
    prev: 'M10.5 3v10L3.5 8zM11.5 3h2v10h-2z',
    next: 'M5.5 3v10l7-5zM2.5 3h2v10h-2z',
    play: 'M4.5 2.5v11l9-5.5z',
    pause: 'M4 3h3v10H4zM9 3h3v10H9z'
  };
  function iconBtn(name, label, fn) {
    var path = el('path', { d: ICONS[name] });
    var b = el('button.bt-btn.bt-icon', { type: 'button', 'aria-label': label, title: label, onclick: fn },
      el('svg', { viewBox: '0 0 16 16', 'aria-hidden': 'true' }, path));
    b._path = path;
    return b;
  }
  var steppers = [];
  var activeStepper = null;
  var docKeysInstalled = false;

  /**
   * new BTViz.Stepper({ steps, onStep(step, index, info), mount, caption, root,
   *                     speed, interval, loop, autoplay, keyboard, initialState })
   *
   * A step is {caption, state}  (full snapshot)  or  {caption, apply(state)}  (mutates a
   * deep copy of the previous step's state, or returns a new one). Any extra fields
   * (highlight, log, lines, …) are passed through untouched. Snapshots are cached, so
   * stepping backwards and scrubbing always work.
   */
  function Stepper(o) {
    o = o || {};
    this.o = o;
    this.steps = [];
    this._snap = [];
    this.index = -1;
    this.playing = false;
    this.speed = o.speed || 1;
    this.interval = o.interval || 1100;
    this.loop = !!o.loop;
    this.onStep = o.onStep || function () {};
    this._timer = null;
    this.predict = !!o.predict;     // "predict the next step" mode (steps with a `question`)
    this._answered = {};
    this._asking = null;
    this.ui = null;
    if (hasDOM && o.mount) this._build();
    steppers.push(this);
    if (!activeStepper) activeStepper = this;
    this.setSteps(o.steps || [], { play: !!o.autoplay });
  }

  Stepper.prototype._build = function () {
    var self = this, o = this.o, ui = this.ui = {};
    var mount = resolve(o.mount);
    ui.caption = o.caption ? resolve(o.caption) : null;
    ui.root = o.root ? resolve(o.root) : (mount.closest && mount.closest('.bt-figure')) || mount;
    var act = function (fn) { return function () { activeStepper = self; fn(); }; };
    ui.restart = iconBtn('restart', 'Restart (Home)', act(function () { self.restart(); }));
    ui.prev = iconBtn('prev', 'Step back (←)', act(function () { self.pause(); self.prev(); }));
    ui.play = iconBtn('play', 'Play (Space)', act(function () { self.toggle(); }));
    ui.play.classList.add('bt-primary');
    ui.next = iconBtn('next', 'Step forward (→)', act(function () { self.pause(); self.next(); }));
    ui.scrub = el('input.bt-scrub', {
      type: 'range', min: 0, max: 0, step: 1, value: 0, 'aria-label': 'Step',
      oninput: function () { activeStepper = self; self.pause(); self.go(+ui.scrub.value, { instant: true }); }
    });
    ui.count = el('span.bt-stepcount', { 'aria-live': 'off' });
    ui.speedOut = el('output');
    ui.speed = el('input', {
      type: 'range', min: 0, max: SPEEDS.length - 1, step: 1, 'aria-label': 'Playback speed',
      oninput: function () { self.setSpeed(SPEEDS[+ui.speed.value]); }
    });
    ui.bar = el('div.bt-controls', { role: 'group', 'aria-label': 'Playback controls' },
      el('span.bt-controls-buttons', ui.restart, ui.prev, ui.play, ui.next),
      ui.scrub, ui.count,
      el('label.bt-speed', 'Speed', ui.speed, ui.speedOut));
    ui.predict = el('input', { type: 'checkbox', onchange: function () { self.predict = ui.predict.checked; } });
    ui.predict.checked = this.predict;
    ui.predictWrap = el('label.bt-field.bt-predict', ui.predict, 'Predict');
    ui.predictWrap.title = 'Pause before some steps and ask what happens next';
    ui.bar.appendChild(ui.predictWrap);
    if (!ui.caption) {
      ui.caption = el('div.bt-caption', { 'aria-live': 'polite' });
      mount.appendChild(ui.caption);
    }
    mount.appendChild(ui.bar);
    this.setSpeed(this.speed);

    if (o.keyboard !== false) {
      ui.root.addEventListener('keydown', function (e) { self._key(e); });
      ui.root.addEventListener('pointerdown', function () { activeStepper = self; });
      ui.root.addEventListener('focusin', function () { activeStepper = self; });
      if (!docKeysInstalled) {
        docKeysInstalled = true;
        document.addEventListener('keydown', function (e) {
          var a = document.activeElement;
          if (a && a !== document.body && a !== document.documentElement) return;
          var s = activeStepper;
          if (!s || !s.ui || !s.ui.root.isConnected) return;
          var r = s.ui.root.getBoundingClientRect();
          if (r.bottom < 0 || r.top > window.innerHeight) return;
          s._key(e);
        });
      }
    }
  };

  Stepper.prototype._key = function (e) {
    if (e.defaultPrevented || e.altKey || e.ctrlKey || e.metaKey) return;
    var t = e.target, tag = t && t.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || (t && t.isContentEditable)) return;
    var isBtn = tag === 'BUTTON' || tag === 'A' || tag === 'SUMMARY';
    var arrows = e.key === 'ArrowLeft' || e.key === 'ArrowRight' || e.key === 'Home' || e.key === 'End';
    if (arrows && t && t.closest && t.closest('.bt-tree-scroll, .bt-code, .bt-log-body, .bt-array, [role="tab"]')) return;
    if (e.key === ' ' || e.key === 'k') { if (isBtn && e.key === ' ') return; this.toggle(); }
    else if (e.key === 'ArrowRight') { this.pause(); this.next(); }
    else if (e.key === 'ArrowLeft') { this.pause(); this.prev(); }
    else if (e.key === 'Home') this.restart();
    else if (e.key === 'End') { this.pause(); this.go(this.steps.length - 1, { instant: true }); }
    else return;
    activeStepper = this;
    e.preventDefault();
  };

  /** Replace the step list. opts: {index = 0, play = false}. */
  Stepper.prototype.setSteps = function (steps, opts) {
    opts = opts || {};
    this.pause();
    this.steps = steps || [];
    this._snap = [];
    this._answered = {};
    this._asking = null;
    this.index = -1;
    if (this.ui) {
      this.ui.scrub.max = Math.max(0, this.steps.length - 1);
      this.ui.predictWrap.style.display = this.o.predict !== undefined || this.steps.some(function (s) { return !!s.question; }) ? '' : 'none';
    }
    if (this.steps.length) this.go(opts.index || 0, { instant: !!opts.instant });
    else this._sync();
    if (opts.play && this.steps.length > 1) this.play();
    return this;
  };

  /** State snapshot at step i (computed lazily, cached). */
  Stepper.prototype.state = function (i) {
    var snap = this._snap;
    if (i < 0) return this.o.initialState === undefined ? {} : this.o.initialState;
    for (var j = snap.length; j <= i; j++) {
      var st = this.steps[j], prev = j > 0 ? snap[j - 1] : (this.o.initialState === undefined ? {} : this.o.initialState);
      if (st.state !== undefined) snap[j] = st.state;
      else if (typeof st.apply === 'function') {
        var base = clone(prev), r = st.apply(base);
        snap[j] = r === undefined ? base : r;
      } else snap[j] = prev;
    }
    return snap[i];
  };

  /** Jump to step i. info.instant suppresses animation in the views. */
  Stepper.prototype.go = function (i, info) {
    var n = this.steps.length;
    if (!n) return;
    i = clamp(i, 0, n - 1);
    var prev = this.index;
    this._asking = null;
    var instant = !!(info && info.instant) || Math.abs(i - prev) > 1 && prev >= 0;
    this.index = i;
    var step = {};
    for (var key in this.steps[i]) step[key] = this.steps[i][key];
    step.state = this.state(i);
    step.index = i;
    var saveSpeed = motion.speed, saveInstant = motion.instant;
    motion.speed = this.speed;
    motion.instant = instant;
    try {
      this.onStep(step, i, { prev: prev, direction: i > prev ? 1 : i < prev ? -1 : 0, instant: instant, stepper: this });
    } finally {
      motion.speed = saveSpeed;
      motion.instant = saveInstant;
    }
    this._sync(step);
  };
  Stepper.prototype.next = function () {
    var j = this.index + 1;
    if (j >= this.steps.length) return;
    var q = this.steps[j].question;
    if (q && this.predict && this.ui && !this._answered[j]) this._ask(j, q);
    else this.go(j);
  };
  /** Predict mode: show step j's question {prompt, choices, answer, explain?} instead of advancing. */
  Stepper.prototype._ask = function (j, q) {
    var self = this, cap = this.ui.caption;
    this.pause();
    if (this._asking === j) return;
    this._asking = j;
    var box = el('div.bt-quiz', el('div.bt-quiz-prompt', { html: '<span class="bt-chip s-compare">Predict</span> ' + (q.prompt || 'What happens next?') }));
    var row = el('div.bt-quiz-choices', { role: 'group', 'aria-label': 'Choices' });
    (q.choices || []).forEach(function (c, i) {
      row.appendChild(el('button.bt-btn', {
        type: 'button', html: c,
        onclick: function () {
          var ok = i === q.answer;
          self._answered[j] = true;
          self.go(j);
          var verdict = el('div.bt-quiz-verdict', { html: '<span class="bt-chip ' + (ok ? 's-found">✓ Correct' : 's-deleted">✗ Not quite') + '</span> ' +
            (ok ? '' : 'Answer: ' + q.choices[q.answer] + '. ') + (q.explain || '') });
          cap.insertBefore(verdict, cap.firstChild);
          if (typeof self.o.onAnswer === 'function') self.o.onAnswer(j, i, ok);
        }
      }));
    });
    box.appendChild(row);
    cap.textContent = '';
    cap.appendChild(box);
    var b = row.querySelector('button');
    if (b && this.ui.root.contains(document.activeElement)) b.focus();
  };
  Stepper.prototype.prev = function () { if (this.index > 0) this.go(this.index - 1); };
  Stepper.prototype.restart = function () { this.pause(); this.go(0, { instant: true }); };
  Stepper.prototype.end = function () { this.pause(); this.go(this.steps.length - 1, { instant: true }); };
  Stepper.prototype.toggle = function () { if (this.playing) this.pause(); else this.play(); };

  Stepper.prototype.play = function () {
    if (this.playing || this.steps.length < 2) return;
    if (this.index >= this.steps.length - 1) this.go(0, { instant: true });
    this.playing = true;
    this._schedule();
    this._sync();
  };
  Stepper.prototype.pause = function () {
    if (this._timer) { clearTimeout(this._timer); this._timer = null; }
    if (!this.playing) return;
    this.playing = false;
    this._sync();
  };
  Stepper.prototype._schedule = function () {
    var self = this, st = this.steps[this.index] || {};
    this._timer = setTimeout(function () {
      self._timer = null;
      if (!self.playing) return;
      if (self.index >= self.steps.length - 1) {
        if (self.loop) self.go(0, { instant: true }); else { self.pause(); return; }
      } else self.next();
      if (!self.playing) return;
      if (self.index >= self.steps.length - 1 && !self.loop) { self.pause(); return; }
      self._schedule();
    }, this.interval * (st.hold || 1) / this.speed);
  };
  /** Playback speed multiplier (0.25 … 4). */
  Stepper.prototype.setSpeed = function (x) {
    this.speed = x;
    if (this.ui) {
      var best = 0;
      SPEEDS.forEach(function (s, i) { if (Math.abs(s - x) < Math.abs(SPEEDS[best] - x)) best = i; });
      this.ui.speed.value = best;
      this.ui.speedOut.textContent = x + '×';
      this.ui.speed.setAttribute('aria-valuetext', x + ' times');
    }
  };
  Stepper.prototype._sync = function (step) {
    var ui = this.ui;
    if (!ui) return;
    var n = this.steps.length, i = this.index;
    ui.scrub.value = Math.max(0, i);
    ui.scrub.disabled = n < 2;
    ui.scrub.setAttribute('aria-valuetext', n ? 'step ' + (i + 1) + ' of ' + n : 'no steps');
    ui.count.textContent = n ? 'step ' + (i + 1) + ' / ' + n : 'no steps';
    ui.restart.disabled = ui.prev.disabled = i <= 0;
    ui.next.disabled = i >= n - 1;
    ui.play.disabled = n < 2;
    ui.play._path.setAttribute('d', this.playing ? ICONS.pause : ICONS.play);
    var lab = this.playing ? 'Pause (Space)' : 'Play (Space)';
    ui.play.setAttribute('aria-label', lab);
    ui.play.title = lab;
    if (step) ui.caption.innerHTML = step.caption || '';
    else if (!n) ui.caption.innerHTML = '';
  };
  Stepper.prototype.destroy = function () {
    this.pause();
    var i = steppers.indexOf(this);
    if (i >= 0) steppers.splice(i, 1);
    if (activeStepper === this) activeStepper = steppers[0] || null;
    if (this.ui && this.ui.bar.parentNode) this.ui.bar.parentNode.removeChild(this.ui.bar);
  };
  Stepper.SPEEDS = SPEEDS;

  /* ======================================================================
   * 5. Tree layout (pure) + TreeView (SVG)
   * ==================================================================== */

  var TREE_DEFAULTS = {
    cellH: 30, minCellW: 30, charW: 8, cellPadX: 9,
    hGap: 16, vGap: 50, padX: 14, padTop: 44, padBottom: 16
  };

  /**
   * Pure tidy layout of a tree, a forest (array of roots) or a DAG (a child listed under a
   * second parent, or a {ref: id} stub, becomes an extra edge to the already-placed node).
   * Returns {nodes: Map(id → info), order: [info…], edges: [{parent, child, ci}], width, height, depth}
   * where info = {id, node, depth, parent, childIndex, x, y, w, h, kw[], anchors[]}.
   */
  function layoutTree(model, opts) {
    var o = {};
    var key;
    for (key in TREE_DEFAULTS) o[key] = TREE_DEFAULTS[key];
    for (key in (opts || {})) if (opts[key] !== undefined && key in TREE_DEFAULTS) o[key] = opts[key];
    var nodes = new Map(), order = [], edges = [], maxDepth = 0;
    var keyW = function (kv) { return Math.max(o.minCellW, String(kv).length * o.charW + o.cellPadX * 2); };

    function measure(n, depth, parent, ci) {
      var keys = n.keys || [];
      var kw = keys.map(keyW), keysW = 0, i;
      for (i = 0; i < kw.length; i++) keysW += kw[i];
      var hasHk = n.highKey !== undefined && n.highKey !== null;
      var hkW = hasHk ? keyW(n.highKey) + 4 : 0;
      var w = keysW + hkW;
      if (w === 0) w = Math.round(o.minCellW * 1.8);
      var anchors = [], acc = 0, inset = Math.min(7, (keysW || w) / 2);
      if (!kw.length) anchors.push(w / 2);
      else for (i = 0; i <= kw.length; i++) {
        anchors.push(i === 0 ? inset : i === kw.length ? keysW - inset : acc);
        acc += kw[i] || 0;
      }
      var info = {
        id: n.id, node: n, depth: depth, parent: parent ? parent.id : null, childIndex: ci,
        x: 0, y: o.padTop + depth * (o.cellH + o.vGap), w: w, h: o.cellH,
        kw: kw, keysW: keysW, hkW: hkW, anchors: anchors, sw: w, cw: 0, kids: []
      };
      nodes.set(n.id, info);
      order.push(info);
      if (depth > maxDepth) maxDepth = depth;
      var ch = n.children || [];
      if (ch.length) {
        var cw = 0;
        for (i = 0; i < ch.length; i++) {
          var cid = ch[i].ref !== undefined ? ch[i].ref : ch[i].id;
          // DAG mode: a child that is already placed (or a {ref: id} stub) only gets an extra edge.
          if (ch[i].ref !== undefined || nodes.has(cid)) { edges.push({ parent: n.id, child: cid, ci: i, shared: true }); continue; }
          var c = measure(ch[i], depth + 1, n, i);
          info.kids.push(c);
          edges.push({ parent: n.id, child: cid, ci: i });
          cw += c.sw;
        }
        if (info.kids.length) {
          cw += o.hGap * (info.kids.length - 1);
          info.cw = cw;
          info.sw = Math.max(w, cw);
        }
      }
      return info;
    }
    function place(info, left) {
      if (!info.kids.length) { info.x = left + (info.sw - info.w) / 2; return; }
      var cl = left + (info.sw - info.cw) / 2;
      for (var i = 0; i < info.kids.length; i++) { place(info.kids[i], cl); cl += info.kids[i].sw + o.hGap; }
      var a = info.kids[0], b = info.kids[info.kids.length - 1];
      var cx = (a.x + a.w / 2 + b.x + b.w / 2) / 2;
      info.x = clamp(cx - info.w / 2, left, left + info.sw - info.w);
    }
    var roots = Array.isArray(model) ? model : [model];
    if (!roots.length || !roots[0]) roots = [{ id: '__empty', keys: [], leaf: true }];
    var left = o.padX;
    roots.forEach(function (r) {
      if (nodes.has(r.id)) return;
      var ri = measure(r, 0, null, 0);
      place(ri, left);
      left += ri.sw + o.hGap * 2.5;
    });
    order.forEach(function (i) { i.x = Math.round(i.x * 2) / 2; });
    return {
      nodes: nodes, order: order, edges: edges, depth: maxDepth + 1, opts: o,
      width: left - o.hGap * 2.5 + o.padX,
      height: o.padTop + (maxDepth + 1) * o.cellH + maxDepth * o.vGap + o.padBottom
    };
  }

  function lerpInto(cur, from, to, e) {
    for (var p in to) cur[p] = from[p] === undefined ? to[p] : from[p] + (to[p] - from[p]) * e;
  }
  function stateClass(base, state) { return state ? base + ' s-' + state : base; }
  var treeUid = 0;

  /**
   * new BTViz.TreeView(target, opts).render(model, highlight)
   *
   * model:     {id, keys:[…], children:[model…], leaf, next?: id, right?: id, highKey?, meta?}
   * highlight: {nodes: {id: state}, keys: {'id:key': state, '*:key': state},
   *             edges: {childId: state}, links: {fromId: state}, cursor: {node: id, label}}
   * opts:      {zoom: 'fit' | number, minScale, toolbar, minHeight, maxHeight, onNodeClick,
   *             ariaLabel, cellH, minCellW, charW, hGap, vGap}
   */
  function TreeView(target, opts) {
    var o = this.opts = { zoom: 'fit', minScale: 0.7, toolbar: true, minHeight: 0, maxHeight: 0, ariaLabel: 'Tree diagram', onNodeClick: null };
    var key;
    for (key in TREE_DEFAULTS) o[key] = TREE_DEFAULTS[key];
    for (key in (opts || {})) o[key] = opts[key];
    var self = this;
    this.uid = 'btv' + (++treeUid);
    this.zoom = o.zoom;
    this.scale = 1;
    this.W = 100; this.H = 60;
    this.nodes = new Map(); this.keys = new Map(); this.edges = new Map(); this.links = new Map();
    this._dying = [];
    this.cursor = null;
    this.hl = {};
    this.model = null;
    this.layout = null;
    this._raf = 0;
    this._first = true;

    var mk = function (cls) {
      return el('marker', { id: self.uid + cls, viewBox: '0 0 8 8', refX: 7, refY: 4, markerWidth: 7, markerHeight: 7, orient: 'auto' },
        el('path', { d: 'M0 .8L7.2 4L0 7.2z', class: 'bt-arrowhead' + (cls ? ' is-active' : '') }));
    };
    this.gEdges = el('g'); this.gLinks = el('g'); this.gNodes = el('g'); this.gKeys = el('g'); this.gOver = el('g');
    this.svg = el('svg', { class: 'bt-tree-svg', role: 'img', 'aria-label': o.ariaLabel },
      el('defs', mk(''), mk('a')), this.gEdges, this.gLinks, this.gNodes, this.gKeys, this.gOver);
    this.scroller = el('div.bt-tree-scroll', { tabindex: 0, role: 'group', 'aria-label': o.ariaLabel + ' (scrollable)' }, this.svg);
    if (o.minHeight) this.scroller.style.minHeight = o.minHeight + 'px';
    if (o.maxHeight) this.scroller.style.maxHeight = o.maxHeight + 'px';
    this.root = el('div.bt-tree', this.scroller);
    if (o.toolbar) {
      var zb = function (label, title, fn) { return el('button', { type: 'button', title: title, 'aria-label': title, onclick: fn }, label); };
      this.root.appendChild(el('div.bt-tree-tools', { role: 'group', 'aria-label': 'Zoom' },
        zb('−', 'Zoom out', function () { self.setZoom(self.scale / 1.25); }),
        zb('fit', 'Zoom to fit', function () { self.setZoom('fit'); }),
        zb('+', 'Zoom in', function () { self.setZoom(self.scale * 1.25); })));
    }
    resolve(target).appendChild(this.root);
    this._frameB = function (now) { self._frame(now); };
    this._gestures();
    if (typeof ResizeObserver !== 'undefined') {
      this._ro = new ResizeObserver(function () { self._applyZoom(); });
      this._ro.observe(this.scroller);
    }
    this._applyZoom();
  }
  TreeView.layout = layoutTree;

  /** 'fit' (never enlarges past 1×, never shrinks below opts.minScale) or a number 0.25…2. */
  TreeView.prototype.setZoom = function (z) {
    this.zoom = z === 'fit' ? 'fit' : clamp(z, 0.25, 2);
    this._applyZoom();
  };
  TreeView.prototype._applyZoom = function () {
    var avail = this.scroller.clientWidth || this.W;
    var s = this.zoom === 'fit' ? clamp(avail / this.W, this.opts.minScale, 1) : this.zoom;
    this.scale = s;
    this.svg.setAttribute('viewBox', '0 0 ' + this.W + ' ' + this.H);
    this.svg.setAttribute('width', Math.floor(this.W * s));
    this.svg.setAttribute('height', Math.floor(this.H * s));
  };

  /** Ctrl/⌘+wheel zooms, mouse drag pans, touch pans natively and pinches to zoom. */
  TreeView.prototype._gestures = function () {
    var self = this, sc = this.scroller, pts = new Map(), drag = null, pinch = null;
    sc.addEventListener('wheel', function (e) {
      if (!(e.ctrlKey || e.metaKey)) return;
      e.preventDefault();
      self.setZoom(self.scale * (e.deltaY < 0 ? 1.1 : 1 / 1.1));
    }, { passive: false });
    sc.addEventListener('pointerdown', function (e) {
      pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (e.pointerType === 'mouse' && e.button === 0) drag = { x: e.clientX, y: e.clientY, l: sc.scrollLeft, t: sc.scrollTop, moved: false };
      if (pts.size === 2) {
        var a = Array.from(pts.values());
        pinch = { d: Math.hypot(a[0].x - a[1].x, a[0].y - a[1].y) || 1, s: self.scale };
      }
    });
    sc.addEventListener('pointermove', function (e) {
      if (!pts.has(e.pointerId)) return;
      pts.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (pinch && pts.size === 2) {
        var a = Array.from(pts.values());
        self.setZoom(pinch.s * Math.hypot(a[0].x - a[1].x, a[0].y - a[1].y) / pinch.d);
      } else if (drag) {
        var dx = e.clientX - drag.x, dy = e.clientY - drag.y;
        if (!drag.moved && Math.abs(dx) + Math.abs(dy) < 4) return;
        drag.moved = true;
        sc.classList.add('is-panning');
        sc.scrollLeft = drag.l - dx;
        sc.scrollTop = drag.t - dy;
      }
    });
    var up = function (e) {
      pts.delete(e.pointerId);
      if (pts.size < 2) pinch = null;
      if (drag) { drag = null; sc.classList.remove('is-panning'); }
    };
    sc.addEventListener('pointerup', up);
    sc.addEventListener('pointercancel', up);
    sc.addEventListener('pointerleave', up);
  };

  TreeView.prototype._mkNode = function (id) {
    var o = this.opts, self = this;
    var it = { id: id, cur: null, from: null, to: null };
    it.rect = el('rect', { class: 'bt-node-box', rx: 7, ry: 7, height: o.cellH });
    it.label = el('text', { class: 'bt-node-label', x: 1, y: -5 });
    it.empty = el('text', { class: 'bt-node-empty', y: o.cellH / 2 });
    it.note = el('text', { class: 'bt-node-note', y: o.cellH + 13 });
    it.dirty = el('circle', { class: 'bt-node-dirty', r: 4.5, cx: 0, cy: 0 });
    it.lock = el('g');
    it.el = el('g', { class: 'bt-node', 'data-id': id }, it.rect, it.label, it.empty, it.note, it.dirty, it.lock);
    if (o.onNodeClick) {
      it.el.classList.add('is-clickable');
      it.el.addEventListener('click', function () { o.onNodeClick(id, it.model); });
    }
    it.write = function (c) {
      it.el.setAttribute('transform', 'translate(' + c.x.toFixed(2) + ',' + c.y.toFixed(2) + ')');
      it.rect.setAttribute('width', Math.max(0, c.w).toFixed(2));
      it.empty.setAttribute('x', c.w / 2);
      it.note.setAttribute('x', c.w / 2);
      it.lock.setAttribute('transform', 'translate(' + c.w.toFixed(2) + ',0)');
      it.el.style.opacity = c.o >= 1 ? '' : c.o.toFixed(3);
    };
    this.gNodes.appendChild(it.el);
    return it;
  };
  TreeView.prototype._mkKey = function (occ) {
    var o = this.opts;
    var it = { occ: occ.occ, vk: occ.vk, cur: null, from: null, to: null };
    it.rect = el('rect', { x: 2, y: 2, rx: 5, ry: 5, height: o.cellH - 4 });
    it.text = el('text', { y: o.cellH / 2 + 0.5 });
    it.el = el('g', { class: 'bt-key' }, it.rect, it.text);
    it.write = function (c) {
      it.el.setAttribute('transform', 'translate(' + c.x.toFixed(2) + ',' + c.y.toFixed(2) + ')');
      it.el.style.opacity = c.o >= 1 ? '' : c.o.toFixed(3);
    };
    this.gKeys.appendChild(it.el);
    return it;
  };
  TreeView.prototype._mkEdge = function (id) {
    var it = { id: id, cur: null, from: null, to: null };
    it.path = el('path', { class: 'bt-edge' });
    it.dot = el('circle', { class: 'bt-edge-dot', r: 2.3 });
    it.el = el('g', { class: 'bt-edge-g' }, it.path, it.dot);
    it.write = function (c) {
      var dy = (c.ey - c.sy) * 0.5;
      it.path.setAttribute('d', 'M' + c.sx.toFixed(2) + ' ' + c.sy.toFixed(2) + 'C' + c.sx.toFixed(2) + ' ' + (c.sy + dy).toFixed(2) +
        ' ' + c.ex.toFixed(2) + ' ' + (c.ey - dy).toFixed(2) + ' ' + c.ex.toFixed(2) + ' ' + c.ey.toFixed(2));
      it.dot.setAttribute('cx', c.sx.toFixed(2));
      it.dot.setAttribute('cy', c.sy.toFixed(2));
      it.el.style.opacity = c.o >= 1 ? '' : c.o.toFixed(3);
    };
    this.gEdges.appendChild(it.el);
    return it;
  };

  TreeView.prototype._purge = function () {
    this._dying.forEach(function (it) { if (it.el.parentNode) it.el.parentNode.removeChild(it.el); });
    this._dying = [];
  };

  /** Draw `model`, animating from whatever is on screen. Returns this. */
  TreeView.prototype.render = function (model, highlight, ropts) {
    var self = this, o = this.opts;
    if (this._raf) { cancelAnimationFrame(this._raf); this._raf = 0; }
    this._purge();
    var L = this.layout = layoutTree(model, o);
    this.model = model;
    var dur = ropts && ropts.duration !== undefined ? ropts.duration : motion.duration();
    if (this._first) dur = 0;
    var first = this._first;
    this._first = false;

    // Where did each key value live before / where does it live now (for spawn + absorb).
    var oldValNode = new Map(), newValNode = new Map();
    this.keys.forEach(function (it) { if (!oldValNode.has(it.vk)) oldValNode.set(it.vk, it.nodeId); });

    // Key occurrences of the new model, in absolute coordinates.
    var occs = [];
    L.order.forEach(function (info) {
      var x = info.x, cnt = {};
      (info.node.keys || []).forEach(function (kv, j) {
        var vk = (typeof kv)[0] + ':' + kv;
        var n = cnt[vk] = (cnt[vk] || 0) + 1;
        if (!newValNode.has(vk)) newValNode.set(vk, info.id);
        if (j === 0) info.vk0 = vk;
        occs.push({ occ: info.id + '|' + vk + (n > 1 ? '#' + n : ''), vk: vk, nodeId: info.id, raw: kv, text: String(kv), x: x, y: info.y, w: info.kw[j] });
        x += info.kw[j];
      });
      if (info.hkW) occs.push({ occ: info.id + '|hk', vk: 'hk:' + info.id, nodeId: info.id, hk: true, raw: info.node.highKey, text: String(info.node.highKey), x: x + 2, y: info.y, w: info.hkW - 2 });
    });

    // --- nodes
    var oldNodes = this.nodes, nextNodes = new Map();
    L.order.forEach(function (info) {
      var it = oldNodes.get(info.id);
      if (it) oldNodes.delete(info.id);
      else {
        it = self._mkNode(info.id);
        var src = info.vk0 !== undefined && oldValNode.has(info.vk0) ? oldNodes.get(oldValNode.get(info.vk0)) || nextNodes.get(oldValNode.get(info.vk0)) : null;
        it.cur = src ? { x: src.cur.x, y: src.cur.y, w: info.w, o: 0 } : { x: info.x, y: info.y, w: info.w, o: 0 };
      }
      it.from = clone(it.cur);
      it.to = { x: info.x, y: info.y, w: info.w, o: 1 };
      it.vk0 = info.vk0;
      it.model = info.node;
      self._decorate(it, info);
      nextNodes.set(info.id, it);
    });
    oldNodes.forEach(function (it) {
      var dst = it.vk0 !== undefined && newValNode.has(it.vk0) ? L.nodes.get(newValNode.get(it.vk0)) : null;
      it.from = clone(it.cur);
      it.to = dst ? { x: dst.x, y: dst.y, w: it.cur.w, o: 0 } : { x: it.cur.x, y: it.cur.y, w: it.cur.w, o: 0 };
      self._dying.push(it);
    });
    this.nodes = nextNodes;

    // --- keys (matched by node+value, then by value across nodes)
    var oldKeys = this.keys, nextKeys = new Map(), byVal = new Map(), pending = [];
    oldKeys.forEach(function (it) {
      it.claimed = false;
      if (!byVal.has(it.vk)) byVal.set(it.vk, []);
      byVal.get(it.vk).push(it);
    });
    var assign = function (it, oc) {
      it.from = clone(it.cur);
      it.to = { x: oc.x, y: oc.y, o: 1 };
      it.nodeId = oc.nodeId; it.raw = oc.raw; it.hk = !!oc.hk; it.occ = oc.occ;
      if (it.textValue !== oc.text) { it.text.textContent = oc.text; it.textValue = oc.text; }
      if (it.w !== oc.w) {
        it.w = oc.w;
        it.rect.setAttribute('width', Math.max(0, oc.w - 4));
        it.text.setAttribute('x', oc.w / 2);
      }
      nextKeys.set(oc.occ, it);
    };
    occs.forEach(function (oc) {
      var it = oldKeys.get(oc.occ);
      if (it && it.vk === oc.vk) { it.claimed = true; assign(it, oc); } else pending.push(oc);
    });
    pending.forEach(function (oc) {
      var cands = byVal.get(oc.vk) || [], it = null, i;
      for (i = 0; i < cands.length; i++) if (!cands[i].claimed) { it = cands[i]; break; }
      if (it) it.claimed = true;
      else {
        it = self._mkKey(oc);
        var src = cands[0];
        it.cur = src ? { x: src.from ? src.from.x : src.cur.x, y: src.from ? src.from.y : src.cur.y, o: 0.25 } : { x: oc.x, y: oc.y - (first ? 0 : 14), o: 0 };
      }
      assign(it, oc);
    });
    oldKeys.forEach(function (it) {
      if (it.claimed) return;
      it.from = clone(it.cur);
      it.to = { x: it.cur.x, y: it.cur.y, o: 0 };
      self._dying.push(it);
    });
    this.keys = nextKeys;

    // --- edges (keyed by child id)
    var oldEdges = this.edges, nextEdges = new Map();
    L.edges.forEach(function (e) {
      var p = L.nodes.get(e.parent), info = L.nodes.get(e.child);
      if (!p || !info) return;
      var eid = e.parent + '>' + e.child;
      var ax = p.anchors[Math.min(e.ci, p.anchors.length - 1)];
      var to = { sx: p.x + ax, sy: p.y + o.cellH, ex: info.x + info.w / 2, ey: info.y, o: 1 };
      var it = oldEdges.get(eid);
      if (it) oldEdges.delete(eid);
      else {
        it = self._mkEdge(eid);
        var pn = nextNodes.get(e.parent).from, cn = nextNodes.get(e.child).from;
        it.cur = { sx: pn.x + ax, sy: pn.y + o.cellH, ex: cn.x + cn.w / 2, ey: cn.y, o: 0 };
      }
      it.child = e.child;
      it.from = clone(it.cur);
      it.to = to;
      nextEdges.set(eid, it);
    });
    oldEdges.forEach(function (it) {
      it.from = clone(it.cur);
      it.to = { sx: it.cur.sx, sy: it.cur.sy, ex: it.cur.ex, ey: it.cur.ey, o: 0 };
      self._dying.push(it);
    });
    this.edges = nextEdges;

    // --- sibling links (next / right), redrawn from node positions every frame
    var want = new Map();
    L.order.forEach(function (info) {
      var n = info.node;
      if (n.next !== undefined && n.next !== null && L.nodes.has(n.next)) want.set(info.id + '>n', { from: info.id, to: n.next, kind: 'next' });
      if (n.right !== undefined && n.right !== null && L.nodes.has(n.right)) want.set(info.id + '>r', { from: info.id, to: n.right, kind: 'right' });
    });
    this.links.forEach(function (lk, key) { if (!want.has(key)) { lk.el.parentNode.removeChild(lk.el); self.links.delete(key); } });
    want.forEach(function (w, key) {
      var lk = self.links.get(key);
      if (!lk) {
        lk = { el: el('path', { class: 'bt-link' + (w.kind === 'right' ? ' is-right' : '') }) };
        self.gLinks.appendChild(lk.el);
        self.links.set(key, lk);
      }
      lk.from = w.from; lk.to = w.to; lk.kind = w.kind;
    });

    // --- canvas size, highlight, go
    this.W = Math.max(60, Math.ceil(L.width));
    this.H = Math.ceil(L.height);
    this._applyZoom();
    this.svg.setAttribute('aria-label', o.ariaLabel + ': ' + L.order.length + ' node' + (L.order.length === 1 ? '' : 's') + ', height ' + L.depth);
    this.highlight(highlight || {}, true);

    this._dur = dur;
    if (dur > 0 && hasDOM && typeof requestAnimationFrame === 'function') {
      this._t0 = performance.now();
      this._draw(0);
      this._raf = requestAnimationFrame(this._frameB);
    } else { this._draw(1); this._purge(); }
    this._reveal(dur);
    return this;
  };

  TreeView.prototype._decorate = function (it, info) {
    var meta = info.node.meta || {};
    it.meta = meta;
    it.label.textContent = meta.label === undefined || meta.label === null ? '' : String(meta.label);
    it.label.setAttribute('y', meta.lock ? -13 : -5);
    it.label.setAttribute('x', meta.dirty && !meta.lock ? 8 : 1);
    it.note.textContent = meta.note === undefined || meta.note === null ? '' : String(meta.note);
    it.empty.textContent = (info.node.keys || []).length || info.hkW ? '' : 'empty';
    it.dirty.style.display = meta.dirty ? '' : 'none';
    // latch badges: 'S' | 'X' | 'S?' (blocked) | 'T2:X' | {mode, label, blocked} | an array of those
    var locks = meta.lock === undefined || meta.lock === null || meta.lock === false ? [] : (Array.isArray(meta.lock) ? meta.lock : [meta.lock]);
    it.lock.textContent = '';
    var re = 10;
    locks.forEach(function (lk) {
      var isObj = lk && typeof lk === 'object';
      var mode = String(isObj ? (lk.mode || '') : lk);
      var blocked = (isObj && !!lk.blocked) || /\?$|blocked|wait/i.test(mode);
      var core = mode.replace(/\?$/, '');
      var ex = /^(x|excl)/i.test(core) || /[:\s]x$/i.test(core);
      var text = isObj && lk.label ? String(lk.label) : core.replace(/^shared$/i, 'S').replace(/^exclusive$/i, 'X').replace(/^(blocked|waiting)$/i, '…');
      var w = Math.max(18, text.length * 6.6 + 8);
      it.lock.appendChild(el('g', { class: 'bt-node-lock ' + (ex ? 'is-exclusive' : 'is-shared') + (blocked ? ' is-blocked' : ''), transform: 'translate(' + (re - w / 2) + ',0)' },
        el('rect', { x: -w / 2, y: -9, width: w, height: 18, rx: 9, ry: 9 }), el('text', { y: 0.5 }, text),
        el('svg:title', (blocked ? 'waiting for ' : 'holds ') + (ex ? 'exclusive' : 'shared') + ' latch')));
      re -= w + 2;
    });
  };

  /** Change highlight states without touching the layout. */
  TreeView.prototype.highlight = function (h, _internal) {
    h = this.hl = h || {};
    var hn = h.nodes || {}, hk = h.keys || {}, he = h.edges || {}, hlk = h.links || {}, self = this, o = this.opts;
    this.nodes.forEach(function (it, id) {
      var cls = stateClass('bt-node', hn[id] || it.meta.state);
      if (o.onNodeClick) cls += ' is-clickable';
      it.el.setAttribute('class', cls);
    });
    this.keys.forEach(function (it) {
      var st = it.hk ? hk[it.nodeId + ':high'] : (hk[it.nodeId + ':' + it.raw] || hk['*:' + it.raw]);
      it.el.setAttribute('class', stateClass(it.hk ? 'bt-key is-highkey' : 'bt-key', st));
    });
    this.edges.forEach(function (it, id) { it.el.setAttribute('class', stateClass('bt-edge-g', he[id] || he[it.child])); });
    this.links.forEach(function (lk) {
      var st = hlk[lk.from];
      lk.el.setAttribute('class', stateClass('bt-link' + (lk.kind === 'right' ? ' is-right' : ''), st));
      lk.el.setAttribute('marker-end', 'url(#' + self.uid + (st ? 'a' : '') + ')');
    });
    // cursor pill
    var c = h.cursor, info = c && this.layout ? this.layout.nodes.get(c.node) : null;
    if (info) {
      var cu = this.cursor;
      if (!cu) {
        cu = this.cursor = { cur: null };
        cu.rect = el('rect', { y: -37, height: 20, rx: 10, ry: 10 });
        cu.text = el('text', { y: -26.5 });
        cu.el = el('g', { class: 'bt-cursor' }, cu.rect, el('path', { d: 'M-5 -17.5L5 -17.5L0 -11z' }), cu.text);
        cu.write = function (v) {
          cu.el.setAttribute('transform', 'translate(' + v.x.toFixed(2) + ',' + v.y.toFixed(2) + ')');
          cu.el.style.opacity = v.o >= 1 ? '' : v.o.toFixed(3);
        };
        this.gOver.appendChild(cu.el);
      }
      var label = c.label === undefined ? '' : String(c.label);
      var w = Math.max(28, label.length * 7.6 + 16);
      cu.rect.setAttribute('x', -w / 2);
      cu.rect.setAttribute('width', w);
      cu.text.textContent = label;
      var to = { x: info.x + info.w / 2, y: info.y, o: 1 };
      if (!cu.cur) cu.cur = { x: to.x, y: to.y, o: 0 };
      cu.from = clone(cu.cur);
      cu.to = to;
    } else if (this.cursor) {
      this.cursor.from = clone(this.cursor.cur);
      this.cursor.to = { x: this.cursor.cur.x, y: this.cursor.cur.y, o: 0 };
    }
    if (!_internal) {
      if (this.cursor && !this._raf) { this.cursor.cur = clone(this.cursor.to); this.cursor.write(this.cursor.cur); }
      this._drawLinks();
    }
    return this;
  };

  TreeView.prototype._frame = function (now) {
    var t = this._dur ? Math.min(1, (now - this._t0) / this._dur) : 1;
    var e = t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
    this._draw(e);
    if (t < 1) this._raf = requestAnimationFrame(this._frameB);
    else { this._raf = 0; this._purge(); }
  };
  TreeView.prototype._draw = function (e) {
    var step = function (it) {
      if (!it.cur) it.cur = {};
      lerpInto(it.cur, it.from || it.to, it.to, e);
      it.write(it.cur);
    };
    this.nodes.forEach(step);
    this.keys.forEach(step);
    this.edges.forEach(step);
    this._dying.forEach(step);
    if (this.cursor && this.cursor.to) step(this.cursor);
    this._drawLinks();
  };
  TreeView.prototype._drawLinks = function () {
    var self = this, h = this.opts.cellH;
    this.links.forEach(function (lk) {
      var a = self.nodes.get(lk.from), b = self.nodes.get(lk.to);
      if (!a || !b || !a.cur || !b.cur) return;
      var x1 = a.cur.x + a.cur.w + 1, y1 = a.cur.y + h / 2, x2 = b.cur.x - 2, y2 = b.cur.y + h / 2;
      if (x2 < x1) { x1 = a.cur.x + a.cur.w / 2; y1 = a.cur.y + h; x2 = b.cur.x + b.cur.w / 2; y2 = b.cur.y + h + 1; }
      var d = x2 >= x1 && Math.abs(y1 - y2) < 1 ? 'M' + x1.toFixed(1) + ' ' + y1.toFixed(1) + 'L' + x2.toFixed(1) + ' ' + y2.toFixed(1)
        : 'M' + x1.toFixed(1) + ' ' + y1.toFixed(1) + 'Q' + ((x1 + x2) / 2).toFixed(1) + ' ' + (Math.max(y1, y2) + 26).toFixed(1) + ' ' + x2.toFixed(1) + ' ' + y2.toFixed(1);
      lk.el.setAttribute('d', d);
      lk.el.style.opacity = Math.min(a.cur.o, b.cur.o) >= 1 ? '' : Math.min(a.cur.o, b.cur.o).toFixed(3);
    });
  };

  /** Scroll the internal scroller so highlighted nodes are visible. */
  TreeView.prototype._reveal = function (dur) {
    var sc = this.scroller, L = this.layout, h = this.hl || {};
    if (!L || sc.scrollWidth <= sc.clientWidth + 1) return;
    var ids = Object.keys(h.nodes || {});
    if (h.cursor) ids.push(h.cursor.node);
    var lo = Infinity, hi = -Infinity;
    ids.forEach(function (id) {
      var i = L.nodes.get(id);
      if (i) { lo = Math.min(lo, i.x); hi = Math.max(hi, i.x + i.w); }
    });
    if (lo === Infinity) return;
    var off = (sc.scrollWidth - this.W * this.scale) / 2;
    lo = lo * this.scale + off - 24; hi = hi * this.scale + off + 24;
    var left = sc.scrollLeft, target = left;
    if (hi - lo > sc.clientWidth) target = lo;
    else if (lo < left) target = lo;
    else if (hi > left + sc.clientWidth) target = hi - sc.clientWidth;
    if (target !== left) {
      if (sc.scrollTo) sc.scrollTo({ left: target, behavior: dur > 0 ? 'smooth' : 'auto' });
      else sc.scrollLeft = target;
    }
  };

  /** The SVG <g> of a node (or null) — for tooltips or custom decoration. */
  TreeView.prototype.nodeEl = function (id) { var it = this.nodes.get(id); return it ? it.el : null; };
  TreeView.prototype.destroy = function () {
    if (this._raf) cancelAnimationFrame(this._raf);
    if (this._ro) this._ro.disconnect();
    if (this.root.parentNode) this.root.parentNode.removeChild(this.root);
  };

  /* ======================================================================
   * 6. ArrayView — a row of cells with index labels and pointer markers
   * ==================================================================== */

  /**
   * new BTViz.ArrayView(target, opts).render(model)
   * model: [v, …]  or  {values: [v | null, …], ids?: […], states?: {index: state},
   *                     pointers?: {name: index}, range?: [lo, hi) , capacity?}
   * Cells are matched between renders by ids[i] (default: the value), so inserting or
   * removing a value makes the others slide.
   */
  function ArrayView(target, opts) {
    this.opts = { cellW: 0, cellH: 34, gap: 4, indexBase: 0, showIndex: true, ariaLabel: 'Array' };
    for (var key in (opts || {})) this.opts[key] = opts[key];
    this.cells = new Map();
    this.ptrs = new Map();
    this.slots = [];
    this.idx = [];
    this.inner = el('div.bt-array-in');
    this.root = el('div.bt-array', { tabindex: 0, role: 'group', 'aria-label': this.opts.ariaLabel }, this.inner);
    resolve(target).appendChild(this.root);
  }
  ArrayView.prototype.render = function (model) {
    if (Array.isArray(model)) model = { values: model };
    var o = this.opts, self = this, vals = model.values || [];
    var cap = Math.max(model.capacity || 0, vals.length);
    var states = model.states || {}, range = model.range, ptrs = model.pointers || {};
    var maxLen = 2;
    vals.forEach(function (v) { if (v !== null && v !== undefined) maxLen = Math.max(maxLen, String(v).length); });
    var cw = o.cellW || Math.max(36, maxLen * 8.2 + 16), pitch = cw + o.gap;
    var dur = motion.duration();
    this.root.style.setProperty('--bt-dur', dur + 'ms');
    var px = function (i) { return i * pitch; };
    var tr = function (x, y) { return 'translate(' + x + 'px,' + y + 'px)'; };

    // static slot outlines + index labels (one extra column so a pointer can sit one-past-the-end)
    while (this.slots.length < cap) {
      var s = el('div.bt-aslot'), ix = el('div.bt-aidx');
      this.inner.appendChild(s); this.inner.appendChild(ix);
      this.slots.push(s); this.idx.push(ix);
    }
    this.slots.forEach(function (s, i) {
      var on = i < cap;
      s.style.display = self.idx[i].style.display = on ? '' : 'none';
      if (!on) return;
      s.style.width = cw + 'px'; s.style.height = o.cellH + 'px'; s.style.transform = tr(px(i), 0);
      var ix = self.idx[i];
      ix.style.width = cw + 'px'; ix.style.transform = tr(px(i), o.cellH + 2);
      ix.textContent = o.showIndex ? i + o.indexBase : '';
    });

    // value cells
    var seen = new Map(), cnt = {};
    vals.forEach(function (v, i) {
      if (v === null || v === undefined) return;
      var id = model.ids ? model.ids[i] : v;
      var key = (typeof id)[0] + ':' + id;
      cnt[key] = (cnt[key] || 0) + 1;
      if (cnt[key] > 1) key += '#' + cnt[key];
      var c = self.cells.get(key), fresh = !c;
      if (fresh) {
        c = el('div.bt-acell');
        c.style.opacity = '0';
        c.style.transform = tr(px(i), dur ? -12 : 0);
        self.inner.appendChild(c);
        self.cells.set(key, c);
        void c.offsetWidth;
      }
      if (c._rm) { clearTimeout(c._rm); c._rm = 0; }
      c.textContent = String(v);
      c.style.width = cw + 'px'; c.style.height = o.cellH + 'px';
      var st = states[i], cls = stateClass('bt-acell', st);
      if (range && (i < range[0] || i >= range[1]) && !st) cls += ' s-dim';
      c.className = cls;
      c.style.opacity = '';
      c.style.transform = tr(px(i), 0);
      seen.set(key, 1);
    });
    this.cells.forEach(function (c, key) {
      if (seen.has(key) || c._rm) return;
      c.style.opacity = '0';
      c._rm = setTimeout(function () { if (c.parentNode) c.parentNode.removeChild(c); self.cells.delete(key); }, dur + 20);
      if (!dur) { clearTimeout(c._rm); c.parentNode.removeChild(c); self.cells.delete(key); }
    });

    // pointer markers, stacked when several share an index
    var rowAt = {}, maxRow = 0, names = Object.keys(ptrs), top = o.cellH + (o.showIndex ? 18 : 4);
    var maxIdx = cap - 1;
    names.forEach(function (name) {
      var i = ptrs[name];
      if (i === null || i === undefined) return;
      maxIdx = Math.max(maxIdx, i);
      var row = rowAt[i] = (rowAt[i] === undefined ? 0 : rowAt[i] + 1);
      maxRow = Math.max(maxRow, row);
      var p = self.ptrs.get(name), fresh = !p;
      if (fresh) {
        p = el('div.bt-aptr', name);
        p.style.opacity = '0';
        p.style.transform = tr(px(i), top + row * 22);
        self.inner.appendChild(p);
        self.ptrs.set(name, p);
        void p.offsetWidth;
      }
      p.style.width = cw + 'px';
      p.style.opacity = '';
      p.style.transform = tr(px(i), top + row * 22);
    });
    this.ptrs.forEach(function (p, name) {
      if (ptrs[name] === null || ptrs[name] === undefined) { p.parentNode.removeChild(p); self.ptrs.delete(name); }
    });
    this.inner.style.width = ((maxIdx + 1) * pitch - o.gap) + 'px';
    this.inner.style.height = (top + (names.length ? (maxRow + 1) * 22 : 0) + 2) + 'px';

    // keep the first pointer / highlighted cell in view
    var focus = names.length ? ptrs[names[names.length - 1]] : null;
    if (focus !== null && focus !== undefined && this.root.scrollWidth > this.root.clientWidth + 1) {
      var x = px(focus), sl = this.root.scrollLeft;
      if (x < sl + 8 || x + cw > sl + this.root.clientWidth - 8) this.root.scrollLeft = Math.max(0, x - this.root.clientWidth / 2);
    }
    return this;
  };

  /* ======================================================================
   * 7. PageView — a fixed-size disk page as a byte grid
   * ==================================================================== */

  /**
   * new BTViz.PageView(target, opts).render(model, highlight)
   * model: {size, headerSize, slotSize, header?: [{name, len, value}], slots: [cellId, …],
   *         cells: [{id, off, len, label?, dead?}]}
   * highlight: {cells: {id: state}, slots: {index: state}, pointers: [slotIndex…] | 'all'}
   * opts: {cols = 16, maxCell = 30, minCell = 12, offsets = true, regions = true}
   */
  function PageView(target, opts) {
    this.opts = { cols: 16, maxCell: 30, minCell: 12, offsets: true, regions: true, ariaLabel: 'Disk page' };
    for (var key in (opts || {})) this.opts[key] = opts[key];
    var self = this;
    this.items = new Map();
    this.alt = new Map();
    this.altN = 0;
    this.size = 0;
    this.offs = el('div.bt-page-offs', { 'aria-hidden': 'true' });
    this.ptrSvg = el('svg', { class: 'bt-page-ptrs', 'aria-hidden': 'true' });
    this.hfLayer = el('div.bt-page-hf');
    this.grid = el('div.bt-page-grid', { role: 'img', 'aria-label': this.opts.ariaLabel });
    this.regions = el('div.bt-page-regions');
    this.root = el('div.bt-pageview', el('div.bt-page-wrap', this.opts.offsets ? this.offs : null, this.grid),
      this.opts.regions ? this.regions : null);
    this.root.style.setProperty('--cols', this.opts.cols);
    resolve(target).appendChild(this.root);
    if (typeof ResizeObserver !== 'undefined') {
      this._ro = new ResizeObserver(function () { self._fit(); });
      this._ro.observe(this.root);
    }
    this._fit();
  }
  PageView.prototype._fit = function () {
    var o = this.opts, w = this.root.clientWidth;
    if (!w) return;
    var c = clamp(Math.floor((w - (o.offsets ? 40 : 2)) / o.cols), o.minCell, o.maxCell);
    this.root.style.setProperty('--c', c + 'px');
  };
  PageView.prototype._pos = function (off) {
    var cols = this.opts.cols;
    return 'translate(calc(var(--c) * ' + (off % cols) + '), calc(var(--c) * ' + Math.floor(off / cols) + '))';
  };
  PageView.prototype.render = function (model, hl) {
    hl = hl || {};
    var self = this, o = this.opts, cols = o.cols;
    var size = model.size, hs = model.headerSize || 0, ss = model.slotSize || 2;
    var rows = Math.ceil(size / cols), i, j;
    var dur = motion.duration();
    this.root.style.setProperty('--bt-dur', dur + 'ms');
    this._fit();

    if (size !== this.size || hs !== this.hs) {       // (re)build the static background grid
      this.size = size; this.hs = hs;
      this.grid.textContent = '';
      this.items.clear();
      for (i = 0; i < size; i++) this.grid.appendChild(el('div.bt-byte' + (i < hs ? '.r-header' : '')));
      this.grid.appendChild(this.hfLayer);
      this.grid.appendChild(this.ptrSvg);
      this.offs.textContent = '';
      for (i = 0; i < rows; i++) this.offs.appendChild(el('div', String(i * cols)));
      this.ptrSvg.setAttribute('viewBox', '0 0 ' + cols + ' ' + rows);
      this.ptrSvg.setAttribute('preserveAspectRatio', 'none');
    }

    // header field labels
    this.hfLayer.textContent = '';
    var hoff = 0;
    (model.header || []).forEach(function (f) {
      var col = hoff % cols, span = Math.min(f.len, cols - col);
      var lab = el('div.bt-hf', { title: f.name + ' = ' + f.value + ' (bytes ' + hoff + '–' + (hoff + f.len - 1) + ')' }, f.name + '=' + f.value);
      lab.style.transform = self._pos(hoff);
      lab.style.width = 'calc(var(--c) * ' + span + ')';
      self.hfLayer.appendChild(lab);
      hoff += f.len;
    });

    // desired moving bytes
    var want = new Map(), cellById = new Map();
    var hc = hl.cells || {}, hsl = hl.slots || {};
    (model.cells || []).forEach(function (c) { cellById.set(c.id, c); });
    (model.slots || []).forEach(function (id, si) {
      for (j = 0; j < ss; j++) {
        want.set('s|' + id + '|' + j, {
          pos: hs + si * ss + j, cls: stateClass('bt-pb r-slot' + (j === 0 ? ' is-first' : ''), hsl[si]),
          label: j === 0 ? String(si) : null, span: ss, title: 'slot ' + si + ' → cell at ' + (cellById.has(id) ? cellById.get(id).off : '?')
        });
      }
    });
    (model.cells || []).forEach(function (c) {
      if (!self.alt.has(c.id)) self.alt.set(c.id, self.altN++ % 2);
      var base = 'bt-pb r-cell' + (c.dead ? ' r-dead' : '') + (self.alt.get(c.id) ? ' is-alt' : '');
      var label = c.label === undefined || c.label === null ? String(c.id) : String(c.label);
      for (j = 0; j < c.len; j++) {
        want.set('c|' + c.id + '|' + j, {
          pos: c.off + j, cls: stateClass(base + (j === 0 ? ' is-first' : ''), hc[c.id]),
          label: j === 0 ? label : null, span: c.len,
          title: (c.dead ? 'dead cell ' : 'cell ') + label + ': bytes ' + c.off + '–' + (c.off + c.len - 1)
        });
      }
    });
    want.forEach(function (w, key) {
      var it = self.items.get(key);
      if (!it) {
        it = { el: el('div') };
        it.el.style.opacity = '0';
        it.el.style.transform = self._pos(w.pos);
        self.grid.insertBefore(it.el, self.hfLayer);
        self.items.set(key, it);
        void it.el.offsetWidth;
      }
      if (it.rm) { clearTimeout(it.rm); it.rm = 0; }
      it.el.className = w.cls;
      it.el.title = w.title;
      it.el.style.opacity = '';
      it.el.style.transform = self._pos(w.pos);
      if (w.label !== null) {
        if (!it.lab) { it.lab = el('span.bt-pb-label'); it.el.appendChild(it.lab); }
        it.lab.textContent = w.label;
        it.lab.style.width = 'calc(var(--c) * ' + Math.min(w.span, cols - (w.pos % cols)) + ')';
        it.el.style.zIndex = '1';
      }
    });
    this.items.forEach(function (it, key) {
      if (want.has(key) || it.rm) return;
      var kill = function () { if (it.el.parentNode) it.el.parentNode.removeChild(it.el); self.items.delete(key); };
      it.el.style.opacity = '0';
      if (dur) it.rm = setTimeout(kill, dur + 20); else kill();
    });

    // slot → cell pointers
    this.ptrSvg.textContent = '';
    var list = hl.pointers === 'all' ? (model.slots || []).map(function (_, n) { return n; }) : (hl.pointers || []);
    list.forEach(function (si) {
      var c = cellById.get((model.slots || [])[si]);
      if (!c) return;
      var a = hs + si * ss, x1 = (a % cols) + ss / 2, y1 = Math.floor(a / cols) + 0.5;
      var x2 = (c.off % cols) + 0.5, y2 = Math.floor(c.off / cols) + 0.12;
      var g = el('g', { class: hsl[si] ? 's-' + hsl[si] : '' },
        el('line', { x1: x1, y1: y1, x2: x2, y2: y2 }), el('circle', { cx: x1, cy: y1, r: 0.13 }), el('circle', { cx: x2, cy: y2, r: 0.15 }));
      self.ptrSvg.appendChild(g);
    });

    // region summary chips
    if (o.regions) {
      var nslots = (model.slots || []).length, lower = hs + nslots * ss, upper = size, dead = 0;
      (model.cells || []).forEach(function (c) { upper = Math.min(upper, c.off); if (c.dead) dead += c.len; });
      var chip = function (token, text, hatch) {
        return el('span.bt-chip', el('span.bt-swatch' + (hatch ? '.is-hatch' : ''), { style: { '--s': 'var(--bt-' + token + ')', '--s-bg': 'var(--bt-' + token + '-bg)' } }), text);
      };
      this.regions.textContent = '';
      if (hs) this.regions.appendChild(chip('node', 'header 0–' + (hs - 1)));
      this.regions.appendChild(chip('pointer', nslots ? 'slots ' + hs + '–' + (lower - 1) + ' →' : 'slots (none) →'));
      this.regions.appendChild(chip('free', upper > lower ? 'free ' + lower + '–' + (upper - 1) + ' · ' + (upper - lower) + ' B' : 'free 0 B'));
      this.regions.appendChild(chip('key', upper < size ? '← cells ' + upper + '–' + (size - 1) : '← cells (none)'));
      if (dead) this.regions.appendChild(chip('free', 'dead ' + dead + ' B', true));
    }
    return this;
  };

  /* ======================================================================
   * 8. Log panel
   * ==================================================================== */

  /**
   * const log = new BTViz.Log(target, {title: 'Log', max: 200});
   * log.add('split n3', 'split'); log.clear();
   * log.sync(steps, i)  — show the `log` field of steps[0..i] (use inside onStep).
   */
  function Log(target, opts) {
    opts = opts || {};
    this.max = opts.max || 200;
    this.n = 0;
    this.body = el('div.bt-log-body', { role: 'log', 'aria-live': 'off', tabindex: 0, 'aria-label': opts.title || 'Log' });
    this.root = el('div.bt-panel.bt-log', el('div.bt-panel-title', opts.title || 'Log'), this.body);
    this.emptyText = opts.empty || 'Nothing yet.';
    resolve(target).appendChild(this.root);
    this.clear();
  }
  Log.prototype.clear = function () {
    this.n = 0;
    this.body.textContent = '';
    this.body.appendChild(el('div.bt-log-empty', this.emptyText));
    return this;
  };
  /** Append a line. `html` may contain markup; `state` is a highlight state name. */
  Log.prototype.add = function (html, state) {
    if (!this.n) this.body.textContent = '';
    this.n++;
    this.body.appendChild(el('div', { class: stateClass('bt-log-line', state) },
      el('span.bt-log-n', String(this.n)), el('span', { html: html })));
    while (this.body.childNodes.length > this.max) this.body.removeChild(this.body.firstChild);
    this.body.scrollTop = this.body.scrollHeight;
    return this;
  };
  Log.prototype.sync = function (steps, index) {
    this.clear();
    for (var i = 0; i <= index && i < steps.length; i++) {
      var s = steps[i];
      if (s.log) this.add(typeof s.log === 'string' ? s.log : s.log.html, typeof s.log === 'string' ? s.logState : s.log.state);
    }
    if (this.body.lastChild && this.n) this.body.lastChild.classList.add('is-current');
    return this;
  };

  /* ======================================================================
   * 9. Code panel (tabbed Zig / Rust with line highlighting)
   * ==================================================================== */

  var KEYWORDS = {
    zig: 'addrspace align allowzero and anyframe anytype asm break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable var volatile while null undefined true false',
    rust: 'as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while',
    js: 'break case catch class const continue default delete do else export extends false finally for function if import in instanceof let new null return static super switch this throw true try typeof undefined var void while yield',
    c: 'break case char const continue default do double else enum extern float for goto if inline int long return short signed sizeof static struct switch typedef union unsigned void volatile while'
  };
  var KWSETS = {};
  var TYPE_RE = /^(?:[iu](?:8|16|32|64|128|size)|f(?:16|32|64|80|128)|bool|void|usize|isize|anyerror|anyopaque|noreturn|type|comptime_int|comptime_float|str|char|String|Vec|Option|Result|Box|[A-Z][A-Za-z0-9]*)$/;
  var TOKEN_RE = /(\/\/.*$)|("(?:\\.|[^"\\])*"?)|('(?:\\.|[^'\\])')|(\b0[xob][0-9a-fA-F_]+\b|\b\d[\d_]*(?:\.\d[\d_]*)?(?:[iuf]\d+|usize|isize)?\b)|(@[A-Za-z_]\w*)|([A-Za-z_]\w*)|(\s+)|([^])/g;

  /** Tint one line of source. Returns HTML. Deliberately simple: comments, strings, numbers, keywords, types, calls. */
  function tintLine(line, lang) {
    var kws = KWSETS[lang];
    if (!kws) {
      kws = KWSETS[lang] = {};
      (KEYWORDS[lang] || '').split(' ').forEach(function (w) { if (w) kws[w] = 1; });
    }
    var out = '', m;
    TOKEN_RE.lastIndex = 0;
    while ((m = TOKEN_RE.exec(line)) !== null) {
      if (m[0] === '') { TOKEN_RE.lastIndex++; continue; }
      var t = esc(m[0]);
      if (m[1]) out += '<span class="tok-com">' + t + '</span>';
      else if (m[2] || m[3]) out += '<span class="tok-str">' + t + '</span>';
      else if (m[4]) out += '<span class="tok-num">' + t + '</span>';
      else if (m[5]) out += '<span class="tok-bi">' + t + '</span>';
      else if (m[6]) {
        if (kws[m[6]] === 1) out += '<span class="tok-kw">' + t + '</span>';
        else if (TYPE_RE.test(m[6])) out += '<span class="tok-type">' + t + '</span>';
        else if (/^\s*\(/.test(line.slice(TOKEN_RE.lastIndex)) || line.slice(TOKEN_RE.lastIndex, TOKEN_RE.lastIndex + 2) === '!(') out += '<span class="tok-fn">' + t + '</span>';
        else out += t;
      } else out += t;
    }
    return out;
  }

  var codePanels = [];
  var LANG_LABELS = { zig: 'Zig', rust: 'Rust', js: 'JavaScript', c: 'C', pseudo: 'Pseudocode' };

  /**
   * const code = BTViz.codePanel(target, {zig: '…', rust: '…'}, {title, active, maxHeight});
   * code.highlight([3, 4])                     same lines in every tab
   * code.highlight({zig: [3, [5, 7]], rust: 4})  per language; [a, b] is an inclusive range
   * code.setTab('rust')
   * The chosen tab is remembered and shared by every code panel on the page.
   */
  function codePanel(target, sources, opts) {
    opts = opts || {};
    if (typeof sources === 'string') {
      var table = root.CHAPTER_CODE || {};
      if (!table[sources]) throw new Error('BTViz.codePanel: no snippet "' + sources + '" in window.CHAPTER_CODE (load viz/code.js with a classic <script> tag before this script)');
      if (!opts.title) opts.title = sources;
      sources = table[sources];
    }
    var langs = Object.keys(sources);
    var panel = { langs: langs, active: null, lines: {}, pres: {}, tabs: {}, spec: null };
    var tablist = el('div.bt-tabs', { role: 'tablist', 'aria-label': opts.title || 'Source language' });
    panel.root = el('div.bt-panel.bt-codepanel', opts.title ? el('div.bt-panel-title', opts.title) : null, tablist);
    var uid = 'btc' + (codePanels.length + 1);
    langs.forEach(function (lang) {
      var src = String(sources[lang]).replace(/^\n+|\s+$/g, '').split('\n');
      var indent = Infinity;
      src.forEach(function (l) { if (l.trim()) indent = Math.min(indent, /^ */.exec(l)[0].length); });
      if (indent === Infinity) indent = 0;
      var code = el('code');
      panel.lines[lang] = src.map(function (l, i) {
        var span = el('span.bt-line', { 'data-n': i + 1, html: tintLine(l.slice(indent), lang) || ' ' });
        code.appendChild(span);
        return span;
      });
      var pre = el('pre.bt-code', { role: 'tabpanel', id: uid + '-p-' + lang, 'aria-labelledby': uid + '-t-' + lang, tabindex: 0 }, code);
      if (opts.maxHeight) pre.style.maxHeight = opts.maxHeight + 'px';
      panel.pres[lang] = pre;
      var tab = el('button.bt-tab', {
        type: 'button', role: 'tab', id: uid + '-t-' + lang, 'aria-controls': uid + '-p-' + lang,
        onclick: function () { setAll(lang); },
        onkeydown: function (e) {
          var i = langs.indexOf(lang), j = e.key === 'ArrowRight' ? i + 1 : e.key === 'ArrowLeft' ? i - 1 : -9;
          if (j === -9) return;
          j = (j + langs.length) % langs.length;
          setAll(langs[j]);
          panel.tabs[langs[j]].focus();
          e.preventDefault();
        }
      }, LANG_LABELS[lang] || lang);
      panel.tabs[lang] = tab;
      tablist.appendChild(tab);
      panel.root.appendChild(pre);
    });
    if (langs.length < 2) tablist.style.display = 'none';

    function setAll(lang) {
      try { window.localStorage.setItem('btviz-lang', lang); } catch (e) { /* private mode */ }
      codePanels.forEach(function (p) { p.setTab(lang); });
    }
    panel.setTab = function (lang) {
      if (langs.indexOf(lang) < 0) return panel;
      panel.active = lang;
      langs.forEach(function (l) {
        var on = l === lang;
        panel.pres[l].hidden = !on;
        panel.tabs[l].setAttribute('aria-selected', on ? 'true' : 'false');
        panel.tabs[l].tabIndex = on ? 0 : -1;
      });
      reveal();
      return panel;
    };
    function expand(spec) {
      var out = [];
      if (spec === null || spec === undefined) return out;
      (Array.isArray(spec) ? spec : [spec]).forEach(function (s) {
        if (Array.isArray(s)) for (var n = s[0]; n <= s[1]; n++) out.push(n); else out.push(s);
      });
      return out;
    }
    function reveal() {
      var pre = panel.pres[panel.active], first = pre && pre.querySelector('.is-hl');
      if (!first || pre.scrollHeight <= pre.clientHeight) return;
      var top = first.offsetTop - pre.offsetTop;
      if (top < pre.scrollTop + 8 || top > pre.scrollTop + pre.clientHeight - 40) pre.scrollTop = Math.max(0, top - pre.clientHeight / 3);
    }
    panel.highlight = function (spec) {
      panel.spec = spec;
      langs.forEach(function (l) {
        var want = {};
        var s = spec && typeof spec === 'object' && !Array.isArray(spec) ? spec[l] : spec;
        expand(s).forEach(function (n) { want[n] = 1; });
        panel.lines[l].forEach(function (span, i) { span.classList.toggle('is-hl', want[i + 1] === 1); });
      });
      reveal();
      return panel;
    };
    var stored = null;
    try { stored = window.localStorage.getItem('btviz-lang'); } catch (e) { /* ignore */ }
    codePanels.push(panel);
    resolve(target).appendChild(panel.root);
    panel.setTab(langs.indexOf(stored) >= 0 ? stored : langs.indexOf(opts.active) >= 0 ? opts.active : langs[0]);
    return panel;
  }

  /* ======================================================================
   * 10. Reference models: BTree, BPlusTree, SlottedPage
   *     Pure data + step emission. No DOM. Covered by assets/selftest.js.
   * ==================================================================== */

  function defaultCmp(a, b) { return a < b ? -1 : a > b ? 1 : 0; }
  function fmtKeys(keys) { return '[' + keys.join(' | ') + ']'; }

  function TreeBase() {}
  TreeBase.prototype._init = function (order, opts) {
    opts = opts || {};
    order = order === undefined || order === null ? 4 : Math.floor(order);
    if (!(order >= 3)) throw new Error('BTViz.models: order must be an integer ≥ 3 (max children per node)');
    this.order = order;
    this.cmp = opts.cmp || defaultCmp;
    this.detail = opts.detail || 'node';       // 'node' | 'key' — granularity of compare steps
    this.idPrefix = opts.idPrefix || 'n';
    this._nextId = 0;
    this.size = 0;
    this._rec = null;
    this._op = null;
    this.root = this._node(true);
  };
  TreeBase.prototype._node = function (leaf) {
    return { id: this.idPrefix + (++this._nextId), keys: [], children: [], leaf: leaf, next: null };
  };
  /** Plain JSON model of the current tree, ready for TreeView.render(). */
  TreeBase.prototype.snapshot = function () {
    var plus = this.kind === 'bplus';
    var copy = function (n) {
      var o = { id: n.id, keys: n.keys.slice(), leaf: n.leaf, children: n.children.map(copy) };
      if (plus && n.leaf) o.next = n.next ? n.next.id : null;
      return o;
    };
    return copy(this.root);
  };
  TreeBase.prototype.height = function () {
    var h = 1, n = this.root;
    while (!n.leaf) { n = n.children[0]; h++; }
    return h;
  };
  TreeBase.prototype.nodeCount = function () {
    var c = 0;
    (function walk(n) { c++; n.children.forEach(walk); })(this.root);
    return c;
  };
  TreeBase.prototype._lower = function (keys, key) {      // first i with keys[i] >= key
    var lo = 0, hi = keys.length;
    while (lo < hi) { var mid = (lo + hi) >> 1; if (this.cmp(keys[mid], key) < 0) lo = mid + 1; else hi = mid; }
    return lo;
  };
  TreeBase.prototype._begin = function (kind, key, opts) {
    this._rec = opts && opts.steps === false ? null : [];
    this._op = { kind: kind, key: key };
    this._cur = null;
  };
  TreeBase.prototype._end = function (ok, extra) {
    var steps = this._rec || [];
    this._rec = null;
    steps.ok = ok;
    for (var p in (extra || {})) steps[p] = extra[p];
    return steps;
  };
  /** Record a step (no-op when recording is off). hl = {nodes, keys, edges, links, cursor}. */
  TreeBase.prototype._emit = function (type, caption, hl, extra) {
    if (!this._rec) return;
    hl = hl || {};
    if (hl.cursor === undefined && this._cur) hl.cursor = { node: this._cur, label: this._op.key };
    if (hl.cursor && !this._has(hl.cursor.node)) delete hl.cursor;
    var step = { type: type, caption: caption, state: this.snapshot(), highlight: hl, op: this._op };
    step.log = extra && extra.log !== undefined ? extra.log : null;
    if (extra) for (var p in extra) step[p] = extra[p];
    this._rec.push(step);
  };
  TreeBase.prototype._has = function (id) {
    var found = false;
    (function walk(n) { if (n.id === id) found = true; else if (!found) n.children.forEach(walk); })(this.root);
    return found;
  };
  function hlKeys(node, keys, state, into) {
    into = into || {};
    keys.forEach(function (kv) { into[node.id + ':' + kv] = state; });
    return into;
  }
  /** Insert many keys without recording steps. Returns the tree. */
  TreeBase.prototype.insertMany = function (keys) {
    for (var i = 0; i < keys.length; i++) this.insert(keys[i], { steps: false });
    return this;
  };
  TreeBase.prototype.has = function (key) {
    return this.search(key, { steps: false }).found;
  };
  /** All keys in sorted order. */
  TreeBase.prototype.keys = function () {
    var out = [], plus = this.kind === 'bplus';
    (function walk(n) {
      if (n.leaf) { out.push.apply(out, n.keys); return; }
      for (var i = 0; i < n.children.length; i++) {
        walk(n.children[i]);
        if (!plus && i < n.keys.length) out.push(n.keys[i]);
      }
    })(this.root);
    return out;
  };
  TreeBase.prototype.limits = function () {
    var m = this.order;
    return this.kind === 'bplus'
      ? { maxKeys: m - 1, minLeafKeys: Math.ceil((m - 1) / 2), minInternalKeys: Math.ceil(m / 2) - 1, maxChildren: m }
      : { maxKeys: m - 1, minLeafKeys: Math.ceil(m / 2) - 1, minInternalKeys: Math.ceil(m / 2) - 1, maxChildren: m };
  };

  /** Walk root → target, emitting compare steps. Returns {path:[{node, idx}], found}. */
  TreeBase.prototype._descend = function (key, stopOnMatch) {
    var plus = this.kind === 'bplus', n = this.root, path = [], self = this, K = k(key);
    for (;;) {
      this._cur = n.id;
      var i = this._lower(n.keys, key);
      var eq = i < n.keys.length && this.cmp(n.keys[i], key) === 0;
      var ci = plus && eq ? i + 1 : i;                      // B+: equal keys live in the right subtree
      var looked = n.keys.slice(0, Math.min(n.keys.length, i + 1));
      if (this._rec && this.detail === 'key') {
        looked.forEach(function (kv) {
          var c = self.cmp(key, kv);
          var h = { nodes: {}, keys: {} };
          h.nodes[n.id] = 'active'; h.keys[n.id + ':' + kv] = 'compare';
          self._emit('compare-key', 'Compare ' + K + ' with ' + k(kv, 'compare') + ': ' + (c < 0 ? 'smaller — stop scanning.' : c > 0 ? 'larger — keep going.' : 'equal.'), h);
        });
      }
      var h2 = { nodes: {}, keys: hlKeys(n, looked, 'compare'), edges: {} };
      h2.nodes[n.id] = 'active';
      var where = n.leaf ? 'Leaf' : n === this.root ? 'Root' : 'Node';
      var text;
      if (eq && (stopOnMatch || n.leaf)) {
        path.push({ node: n, idx: i });
        return { path: path, found: true };
      }
      if (n.leaf) {
        path.push({ node: n, idx: i });
        this._emit('compare', where + ' ' + fmtKeys(n.keys) + ': ' + K + ' is not here' +
          (n.keys.length ? '; it would sit at position ' + i + '.' : ' (the leaf is empty).'), h2);
        return { path: path, found: false };
      }
      if (ci === 0) text = K + ' &lt; ' + k(n.keys[0], 'compare') + ' → follow the leftmost child.';
      else if (ci === n.keys.length) text = K + (plus ? ' ≥ ' : ' &gt; ') + k(n.keys[ci - 1], 'compare') + ' → follow the rightmost child.';
      else text = k(n.keys[ci - 1], 'compare') + (plus ? ' ≤ ' : ' &lt; ') + K + ' &lt; ' + k(n.keys[ci], 'compare') + ' → follow child ' + ci + ', between them.';
      h2.edges[n.children[ci].id] = 'active';
      this._emit('compare', where + ' ' + fmtKeys(n.keys) + ': ' + text, h2);
      path.push({ node: n, idx: ci });
      n = n.children[ci];
    }
  };

  /** search(key) → steps (steps.found is true/false). */
  TreeBase.prototype.search = function (key, opts) {
    this._begin('search', key, opts);
    var K = k(key);
    this._cur = this.root.id;
    this._emit('start', 'Search for ' + K + ': start at the root.', { nodes: mk1(this.root.id, 'active') }, { log: 'search ' + key });
    var d = this._descend(key, this.kind !== 'bplus');
    var last = d.path[d.path.length - 1];
    if (d.found) {
      this._emit('found', 'Found ' + k(key, 'found') + ' in ' + (last.node.leaf ? 'leaf' : 'internal node') + ' ' + fmtKeys(last.node.keys) + '.',
        { nodes: mk1(last.node.id, 'found'), keys: mk1(last.node.id + ':' + key, 'found') }, { log: { html: 'found ' + key, state: 'found' } });
    } else {
      this._emit('not-found', K + ' is not in the tree: the search ended in a leaf without finding it.',
        { nodes: mk1(last.node.id, 'active') }, { log: key + ' not found' });
    }
    return this._end(d.found, { found: d.found });
  };
  function mk1(key, v) { var o = {}; o[key] = v; return o; }

  /** Shared structural checks. Returns an array of error strings (empty = valid). */
  TreeBase.prototype.validate = function () {
    var errs = [], self = this, lim = this.limits(), plus = this.kind === 'bplus';
    var leafDepth = -1, count = 0, leaves = [];
    function walk(n, lo, hi, depth, isRoot) {
      var i, kn = n.keys.length;
      for (i = 0; i < kn; i++) {
        if (i > 0 && self.cmp(n.keys[i - 1], n.keys[i]) >= 0) errs.push(n.id + ': keys not strictly increasing ' + fmtKeys(n.keys));
        if (lo !== undefined && (plus ? self.cmp(n.keys[i], lo) < 0 : self.cmp(n.keys[i], lo) <= 0)) errs.push(n.id + ': key ' + n.keys[i] + ' below lower bound ' + lo);
        if (hi !== undefined && self.cmp(n.keys[i], hi) >= 0) errs.push(n.id + ': key ' + n.keys[i] + ' not below upper bound ' + hi);
      }
      if (kn > lim.maxKeys) errs.push(n.id + ': ' + kn + ' keys > max ' + lim.maxKeys);
      if (n.leaf) {
        if (n.children.length) errs.push(n.id + ': leaf has children');
        if (!isRoot && kn < lim.minLeafKeys) errs.push(n.id + ': leaf has ' + kn + ' keys < min ' + lim.minLeafKeys);
        if (leafDepth === -1) leafDepth = depth; else if (leafDepth !== depth) errs.push(n.id + ': leaf at depth ' + depth + ', expected ' + leafDepth);
        count += kn;
        leaves.push(n);
        return;
      }
      if (n.children.length !== kn + 1) errs.push(n.id + ': ' + n.children.length + ' children for ' + kn + ' keys');
      if (kn < 1) errs.push(n.id + ': internal node without keys');
      if (!isRoot && kn < lim.minInternalKeys) errs.push(n.id + ': internal node has ' + kn + ' keys < min ' + lim.minInternalKeys);
      if (!plus) count += kn;
      for (i = 0; i < n.children.length; i++) walk(n.children[i], i === 0 ? lo : n.keys[i - 1], i === kn ? hi : n.keys[i], depth + 1, false);
    }
    walk(this.root, undefined, undefined, 0, true);
    if (count !== this.size) errs.push('size is ' + this.size + ' but tree holds ' + count + ' keys');
    if (plus) {
      for (var i = 0; i < leaves.length; i++) {
        var want = i + 1 < leaves.length ? leaves[i + 1] : null;
        if (leaves[i].next !== want) errs.push(leaves[i].id + ': next pointer does not lead to the following leaf');
      }
    }
    return errs;
  };

  /* ----------------------------- B-tree --------------------------------- */

  /**
   * BTViz.models.BTree(order[, opts]) — classic B-tree; keys live in every node.
   * order = maximum number of children (≥ 3). Max keys = order − 1, min keys = ⌈order/2⌉ − 1.
   * insert / delete / search return an array of steps {type, caption, state, highlight, op, log};
   * the array also carries `.ok` (and `.found` for search). Pass {steps: false} to skip recording.
   */
  function BTree(order, opts) {
    if (!(this instanceof BTree)) return new BTree(order, opts);
    this.kind = 'btree';
    this._init(order, opts);
  }
  BTree.prototype = Object.create(TreeBase.prototype);
  BTree.prototype.constructor = BTree;

  BTree.prototype.insert = function (key, opts) {
    this._begin('insert', key, opts);
    var K = k(key), lim = this.limits();
    this._cur = this.root.id;
    this._emit('start', 'Insert ' + K + ': start at the root and walk down to the leaf where it belongs.', { nodes: mk1(this.root.id, 'active') }, { log: 'insert ' + key });
    var d = this._descend(key, true);
    var last = d.path[d.path.length - 1];
    if (d.found) {
      this._emit('exists', k(key, 'found') + ' is already in the tree — nothing to insert.',
        { nodes: mk1(last.node.id, 'found'), keys: mk1(last.node.id + ':' + key, 'found') }, { log: key + ' already present' });
      return this._end(false);
    }
    last.node.keys.splice(last.idx, 0, key);
    this.size++;
    var over = last.node.keys.length > lim.maxKeys;
    this._emit('insert-leaf', 'Insert ' + k(key, 'inserted') + ' into the leaf at position ' + last.idx + '. The leaf now holds ' +
      last.node.keys.length + ' key' + (last.node.keys.length === 1 ? '' : 's') + (over ? ' — one more than the maximum of ' + lim.maxKeys + '.' : ' (max ' + lim.maxKeys + ').'),
      { nodes: mk1(last.node.id, 'active'), keys: mk1(last.node.id + ':' + key, 'inserted') });
    this._cur = null;
    this._splitUp(d.path, key);
    this._emit('done', 'Done: ' + K + ' is in the tree. ' + this.size + ' key' + (this.size === 1 ? '' : 's') + ', height ' + this.height() + '.',
      { keys: mk1('*:' + key, 'inserted') });
    return this._end(true);
  };

  /** Split overflowing nodes bottom-up along `path`. Shared by BTree and (for internal nodes) BPlusTree. */
  TreeBase.prototype._splitUp = function (path, key) {
    var lim = this.limits(), plus = this.kind === 'bplus';
    for (var level = path.length - 1; level >= 0; level--) {
      var node = path[level].node;
      if (node.keys.length <= lim.maxKeys) break;
      var copyUp = plus && node.leaf;
      var mid = copyUp ? Math.ceil(node.keys.length / 2) : Math.floor(node.keys.length / 2);
      var med = node.keys[mid];
      var h = { nodes: mk1(node.id, 'split'), keys: mk1(node.id + ':' + med, 'split') };
      if (key !== undefined) h.keys[node.id + ':' + key] = h.keys[node.id + ':' + key] || 'inserted';
      this._emit('overflow', (node.leaf ? 'Leaf' : 'Node') + ' ' + fmtKeys(node.keys) + ' overflows (' + node.keys.length + ' keys, max ' + lim.maxKeys + '). Split it at ' + k(med, 'split') +
        (copyUp ? ': the right half starts there, and a copy goes up as the separator.' : ': the median moves up, the rest is divided in two.'), h);
      var right = this._node(node.leaf);
      if (copyUp) {
        right.keys = node.keys.splice(mid);
        right.next = node.next;
        node.next = right;
      } else {
        right.keys = node.keys.splice(mid + 1);
        node.keys.pop();
        if (!node.leaf) right.children = node.children.splice(mid + 1);
      }
      var hs = { nodes: {}, keys: {} };
      hs.nodes[node.id] = 'split'; hs.nodes[right.id] = 'split';
      if (level === 0) {
        var nr = this._node(false);
        nr.keys = [med];
        nr.children = [node, right];
        this.root = nr;
        hs.nodes[nr.id] = 'active';
        hs.keys[nr.id + ':' + med] = 'split';
        this._emit('root-grow', 'The root itself split, so a new root holding ' + k(med, 'split') + ' is created above the two halves. The tree is now ' + this.height() + ' levels tall — this is the only way a B-tree grows in height.', hs,
          { log: { html: 'root split → height ' + this.height(), state: 'split' } });
      } else {
        var parent = path[level - 1].node, pi = path[level - 1].idx;
        parent.keys.splice(pi, 0, med);
        parent.children.splice(pi + 1, 0, right);
        hs.keys[parent.id + ':' + med] = 'split';
        this._emit('split', 'Split into ' + fmtKeys(node.keys) + ' and ' + fmtKeys(right.keys) + '. ' + k(med, 'split') +
          (copyUp ? ' is copied up' : ' moves up') + ' into the parent, which now has ' + parent.keys.length + ' key' + (parent.keys.length === 1 ? '' : 's') + '.', hs,
          { log: { html: 'split ' + node.id + ' → ' + node.id + ' + ' + right.id + ', ' + (copyUp ? 'copy up ' : 'promote ') + med, state: 'split' } });
      }
    }
  };

  /** Restore minimum occupancy bottom-up along `path` (path[i].idx = child index taken at level i). */
  TreeBase.prototype._rebalance = function (path) {
    var lim = this.limits(), plus = this.kind === 'bplus';
    for (var level = path.length - 1; level > 0; level--) {
      var node = path[level].node;
      var min = node.leaf ? lim.minLeafKeys : lim.minInternalKeys;
      if (node.keys.length >= min) break;
      var parent = path[level - 1].node, ci = path[level - 1].idx;
      var left = ci > 0 ? parent.children[ci - 1] : null;
      var right = ci < parent.children.length - 1 ? parent.children[ci + 1] : null;
      var leafPlus = plus && node.leaf;
      var what = node.leaf ? 'Leaf' : 'Node';
      this._emit('underflow', what + ' ' + fmtKeys(node.keys) + ' underflows: ' + node.keys.length + ' key' + (node.keys.length === 1 ? '' : 's') + ', minimum is ' + min + '. Look at its siblings.',
        { nodes: mk1(node.id, 'merge') });
      var h = { nodes: {}, keys: {} }, moved, sep;
      if (left && left.keys.length > min) {
        if (leafPlus) {
          moved = left.keys.pop();
          node.keys.unshift(moved);
          parent.keys[ci - 1] = moved;
          h.keys[node.id + ':' + moved] = 'inserted'; h.keys[parent.id + ':' + moved] = 'split';
          sep = moved;
        } else {
          sep = parent.keys[ci - 1];
          moved = left.keys.pop();
          node.keys.unshift(sep);
          parent.keys[ci - 1] = moved;
          if (!node.leaf) node.children.unshift(left.children.pop());
          h.keys[node.id + ':' + sep] = 'inserted'; h.keys[parent.id + ':' + moved] = 'split';
        }
        h.nodes[node.id] = 'merge'; h.nodes[left.id] = 'active';
        this._emit('borrow-left', 'The left sibling has a key to spare. ' + (leafPlus
          ? 'Move its last key ' + k(moved, 'inserted') + ' over and update the separator in the parent to ' + k(moved, 'split') + '.'
          : 'Rotate through the parent: separator ' + k(sep, 'inserted') + ' comes down, the sibling\'s last key ' + k(moved, 'split') + ' goes up.'), h,
          { log: { html: 'borrow from left sibling ' + left.id, state: 'merge' } });
        break;
      }
      if (right && right.keys.length > min) {
        if (leafPlus) {
          moved = right.keys.shift();
          node.keys.push(moved);
          parent.keys[ci] = right.keys[0];
          h.keys[node.id + ':' + moved] = 'inserted'; h.keys[parent.id + ':' + right.keys[0]] = 'split';
          sep = right.keys[0];
        } else {
          sep = parent.keys[ci];
          moved = right.keys.shift();
          node.keys.push(sep);
          parent.keys[ci] = moved;
          if (!node.leaf) node.children.push(right.children.shift());
          h.keys[node.id + ':' + sep] = 'inserted'; h.keys[parent.id + ':' + moved] = 'split';
        }
        h.nodes[node.id] = 'merge'; h.nodes[right.id] = 'active';
        this._emit('borrow-right', 'The right sibling has a key to spare. ' + (leafPlus
          ? 'Move its first key ' + k(moved, 'inserted') + ' over and update the separator in the parent to ' + k(sep, 'split') + '.'
          : 'Rotate through the parent: separator ' + k(sep, 'inserted') + ' comes down, the sibling\'s first key ' + k(moved, 'split') + ' goes up.'), h,
          { log: { html: 'borrow from right sibling ' + right.id, state: 'merge' } });
        break;
      }
      // merge: always fold the right node of the pair into the left one
      var a = left ? left : node, b = left ? node : right, si = left ? ci - 1 : ci;
      sep = parent.keys.splice(si, 1)[0];
      parent.children.splice(si + 1, 1);
      if (leafPlus) {
        a.keys = a.keys.concat(b.keys);
        a.next = b.next;
      } else {
        a.keys = a.keys.concat([sep], b.keys);
        a.children = a.children.concat(b.children);
        h.keys[a.id + ':' + sep] = 'merge';
      }
      h.nodes[a.id] = 'merge';
      path[level].node = a;
      this._emit('merge', 'Neither sibling can spare a key, so merge with the ' + (left ? 'left' : 'right') + ' sibling into ' + fmtKeys(a.keys) + '. ' +
        (leafPlus ? 'Separator ' + k(sep) + ' is removed from the parent.' : 'Separator ' + k(sep, 'merge') + ' is pulled down from the parent into the merged node.') +
        ' The parent loses a key and a child.', h,
        { log: { html: 'merge ' + a.id + ' + ' + b.id, state: 'merge' } });
    }
    if (!this.root.leaf && this.root.keys.length === 0) {
      this.root = this.root.children[0];
      this._emit('root-shrink', 'The root has no keys left, so its only child becomes the new root. The tree is now ' + this.height() + ' level' + (this.height() === 1 ? '' : 's') + ' tall.',
        { nodes: mk1(this.root.id, 'active') }, { log: { html: 'root removed → height ' + this.height(), state: 'merge' } });
    }
  };

  BTree.prototype.delete = function (key, opts) {
    this._begin('delete', key, opts);
    var K = k(key);
    this._cur = this.root.id;
    this._emit('start', 'Delete ' + K + ': first find it, starting at the root.', { nodes: mk1(this.root.id, 'active') }, { log: 'delete ' + key });
    var d = this._descend(key, true), path = d.path;
    var last = path[path.length - 1], node = last.node, idx = last.idx;
    if (!d.found) {
      this._emit('not-found', K + ' is not in the tree — nothing to delete.', { nodes: mk1(node.id, 'active') }, { log: key + ' not found' });
      return this._end(false);
    }
    if (node.leaf) {
      this._emit('remove', 'Found ' + k(key, 'deleted') + ' in a leaf. Remove it.', { nodes: mk1(node.id, 'active'), keys: mk1(node.id + ':' + key, 'deleted') });
      node.keys.splice(idx, 1);
    } else {
      this._emit('found-internal', 'Found ' + k(key, 'deleted') + ' in an internal node. It cannot simply be removed — it separates two subtrees. Replace it with its predecessor: the largest key in the left subtree.',
        { nodes: mk1(node.id, 'active'), keys: mk1(node.id + ':' + key, 'deleted'), edges: mk1(node.children[idx].id, 'active') });
      var cur = node.children[idx];
      path.push({ node: cur, idx: 0 });
      while (!cur.leaf) {
        path[path.length - 1].idx = cur.children.length - 1;
        cur = cur.children[cur.children.length - 1];
        path.push({ node: cur, idx: 0 });
      }
      var pred = cur.keys[cur.keys.length - 1];
      this._cur = null;
      this._emit('predecessor', 'The predecessor is ' + k(pred, 'compare') + ', the last key of the rightmost leaf in the left subtree.',
        { nodes: mk1(cur.id, 'active'), keys: (function () { var o = mk1(cur.id + ':' + pred, 'compare'); o[node.id + ':' + key] = 'deleted'; return o; })() });
      node.keys[idx] = pred;
      cur.keys.pop();
      this._emit('replace', 'Move ' + k(pred, 'inserted') + ' up to take the place of ' + K + '. The key actually removed from a leaf is the predecessor.',
        { nodes: mk1(cur.id, 'active'), keys: mk1(node.id + ':' + pred, 'inserted') });
    }
    this.size--;
    this._cur = null;
    this._rebalance(path);
    this._emit('done', 'Done: ' + K + ' is gone. ' + this.size + ' key' + (this.size === 1 ? '' : 's') + ', height ' + this.height() + '.', {});
    return this._end(true);
  };

  /* ----------------------------- B+tree --------------------------------- */

  /**
   * BTViz.models.BPlusTree(order[, opts]) — all keys live in leaves; leaves are chained by `next`;
   * internal nodes hold separator copies (child i+1 holds keys ≥ separator i).
   * order = max children of an internal node; a leaf holds at most order − 1 keys.
   * Also has scan(lo, hi) → steps, walking the leaf chain.
   */
  function BPlusTree(order, opts) {
    if (!(this instanceof BPlusTree)) return new BPlusTree(order, opts);
    this.kind = 'bplus';
    this._init(order, opts);
  }
  BPlusTree.prototype = Object.create(TreeBase.prototype);
  BPlusTree.prototype.constructor = BPlusTree;

  BPlusTree.prototype.insert = function (key, opts) {
    this._begin('insert', key, opts);
    var K = k(key), lim = this.limits();
    this._cur = this.root.id;
    this._emit('start', 'Insert ' + K + ': walk down to the leaf that should hold it. Internal nodes only steer; data lives in the leaves.', { nodes: mk1(this.root.id, 'active') }, { log: 'insert ' + key });
    var d = this._descend(key, false);
    var last = d.path[d.path.length - 1];
    if (d.found) {
      this._emit('exists', k(key, 'found') + ' is already in this leaf — nothing to insert.',
        { nodes: mk1(last.node.id, 'found'), keys: mk1(last.node.id + ':' + key, 'found') }, { log: key + ' already present' });
      return this._end(false);
    }
    last.node.keys.splice(last.idx, 0, key);
    this.size++;
    var over = last.node.keys.length > lim.maxKeys;
    this._emit('insert-leaf', 'Insert ' + k(key, 'inserted') + ' into the leaf at position ' + last.idx + '. The leaf now holds ' + last.node.keys.length +
      ' key' + (last.node.keys.length === 1 ? '' : 's') + (over ? ' — one more than the maximum of ' + lim.maxKeys + '.' : ' (max ' + lim.maxKeys + ').'),
      { nodes: mk1(last.node.id, 'active'), keys: mk1(last.node.id + ':' + key, 'inserted') });
    this._cur = null;
    this._splitUp(d.path, key);
    this._emit('done', 'Done: ' + K + ' is in the tree. ' + this.size + ' key' + (this.size === 1 ? '' : 's') + ', height ' + this.height() + '.',
      { keys: mk1(this._leafFor(key).id + ':' + key, 'inserted') });
    return this._end(true);
  };
  BPlusTree.prototype._leafFor = function (key) {
    var n = this.root;
    while (!n.leaf) {
      var i = this._lower(n.keys, key);
      if (i < n.keys.length && this.cmp(n.keys[i], key) === 0) i++;
      n = n.children[i];
    }
    return n;
  };

  BPlusTree.prototype.delete = function (key, opts) {
    this._begin('delete', key, opts);
    var K = k(key);
    this._cur = this.root.id;
    this._emit('start', 'Delete ' + K + ': find its leaf, starting at the root.', { nodes: mk1(this.root.id, 'active') }, { log: 'delete ' + key });
    var d = this._descend(key, false), path = d.path;
    var last = path[path.length - 1], node = last.node;
    if (!d.found) {
      this._emit('not-found', K + ' is not in the tree — nothing to delete.', { nodes: mk1(node.id, 'active') }, { log: key + ' not found' });
      return this._end(false);
    }
    this._emit('remove', 'Found ' + k(key, 'deleted') + ' in its leaf. Remove it. (A copy used as a separator higher up may stay — separators only steer searches.)',
      { nodes: mk1(node.id, 'active'), keys: mk1(node.id + ':' + key, 'deleted') });
    node.keys.splice(last.idx, 1);
    this.size--;
    this._cur = null;
    this._rebalance(path);
    this._emit('done', 'Done: ' + K + ' is gone. ' + this.size + ' key' + (this.size === 1 ? '' : 's') + ', height ' + this.height() + '.', {});
    return this._end(true);
  };

  /** Range scan lo ≤ key ≤ hi along the leaf chain. steps.result = matching keys. */
  BPlusTree.prototype.scan = function (lo, hi, opts) {
    this._begin('scan', lo, opts);
    var self = this, out = [];
    this._cur = this.root.id;
    this._emit('start', 'Range scan ' + k(lo) + ' … ' + k(hi) + ': descend once to the leaf for ' + k(lo) + ', then follow the leaf chain.', { nodes: mk1(this.root.id, 'active') }, { log: 'scan ' + lo + '..' + hi });
    var d = this._descend(lo, false);
    var leaf = d.path[d.path.length - 1].node;
    this._cur = null;
    while (leaf) {
      var hit = leaf.keys.filter(function (kv) { return self.cmp(kv, lo) >= 0 && self.cmp(kv, hi) <= 0; });
      out = out.concat(hit);
      var past = leaf.keys.length && this.cmp(leaf.keys[leaf.keys.length - 1], hi) > 0;
      var h = { nodes: mk1(leaf.id, 'active'), keys: hlKeys(leaf, hit, 'found'), links: {} };
      var go = !past && leaf.next;
      if (go) h.links[leaf.id] = 'active';
      this._emit('scan-leaf', 'Leaf ' + fmtKeys(leaf.keys) + ': ' + (hit.length ? 'collect ' + hit.map(function (v) { return k(v, 'found'); }).join(' ') : 'nothing in range') + '. ' +
        (go ? 'Follow the sibling link to the next leaf — no need to go back up.' : past ? 'A key beyond ' + k(hi) + ' was seen: stop.' : 'This is the last leaf: stop.'), h);
      if (!go) break;
      leaf = leaf.next;
    }
    this._emit('done', 'Scan finished: ' + out.length + ' key' + (out.length === 1 ? '' : 's') + ' in range.', {});
    return this._end(true, { result: out });
  };

  /* --------------------------- Slotted page ------------------------------ */

  /**
   * BTViz.models.SlottedPage({size = 128, headerSize = 8, slotSize = 2}) — the classic slotted
   * page: header, slot array growing forward (kept sorted by key), cells growing backward.
   * insert(key, len[, label]) / delete(key) / defragment() return steps whose `state` is a
   * PageView model and whose `highlight` is a PageView highlight.
   */
  function SlottedPage(opts) {
    if (!(this instanceof SlottedPage)) return new SlottedPage(opts);
    opts = opts || {};
    this.size = opts.size || 128;
    this.headerSize = opts.headerSize === undefined ? 8 : opts.headerSize;
    this.slotSize = opts.slotSize || 2;
    this.cmp = opts.cmp || defaultCmp;
    this.slots = [];        // cell objects, in key order
    this.cells = [];        // all cells incl. dead ones: {id, key, off, len, label, dead}
    this._nextId = 0;
    this._rec = null;
  }
  SlottedPage.prototype.lower = function () { return this.headerSize + this.slots.length * this.slotSize; };
  SlottedPage.prototype.upper = function () {
    var u = this.size;
    this.cells.forEach(function (c) { if (c.off < u) u = c.off; });
    return u;
  };
  SlottedPage.prototype.deadBytes = function () {
    var d = 0;
    this.cells.forEach(function (c) { if (c.dead) d += c.len; });
    return d;
  };
  /** {contiguous, total} free bytes. */
  SlottedPage.prototype.freeSpace = function () {
    var c = this.upper() - this.lower();
    return { contiguous: c, total: c + this.deadBytes() };
  };
  SlottedPage.prototype.keys = function () { return this.slots.map(function (c) { return c.key; }); };
  SlottedPage.prototype.snapshot = function () {
    var m = {
      size: this.size, headerSize: this.headerSize, slotSize: this.slotSize,
      slots: this.slots.map(function (c) { return c.id; }),
      cells: this.cells.map(function (c) { return { id: c.id, key: c.key, off: c.off, len: c.len, label: c.label, dead: !!c.dead }; })
    };
    if (this.headerSize >= 8) {
      m.header = [
        { name: 'n', len: 2, value: this.slots.length }, { name: 'lo', len: 2, value: this.lower() },
        { name: 'hi', len: 2, value: this.upper() }, { name: 'frag', len: 2, value: this.deadBytes() }
      ];
    }
    return m;
  };
  SlottedPage.prototype._emit = function (type, caption, hl, log) {
    if (this._rec) this._rec.push({ type: type, caption: caption, state: this.snapshot(), highlight: hl || {}, log: log || null });
  };
  SlottedPage.prototype._find = function (key) {
    var lo = 0, hi = this.slots.length;
    while (lo < hi) { var mid = (lo + hi) >> 1; if (this.cmp(this.slots[mid].key, key) < 0) lo = mid + 1; else hi = mid; }
    return lo;
  };
  SlottedPage.prototype._finish = function (ok) { var s = this._rec || []; this._rec = null; s.ok = ok; return s; };
  SlottedPage.prototype._compact = function () {
    var live = this.cells.filter(function (c) { return !c.dead; }).sort(function (a, b) { return b.off - a.off; });
    var end = this.size;
    live.forEach(function (c) { end -= c.len; c.off = end; });
    this.cells = live;
  };
  SlottedPage.prototype.insert = function (key, len, label, opts) {
    this._rec = opts && opts.steps === false ? null : [];
    len = len || 8;
    var p = this._find(key), K = k(key), need = len + this.slotSize, hl;
    if (p < this.slots.length && this.cmp(this.slots[p].key, key) === 0) {
      hl = { slots: mk1(p, 'found'), cells: mk1(this.slots[p].id, 'found'), pointers: [p] };
      this._emit('exists', 'Key ' + K + ' is already on this page (slot ' + p + ').', hl);
      return this._finish(false);
    }
    var fs = this.freeSpace();
    this._emit('find-slot', 'Insert ' + K + ' (' + len + ' bytes): binary-search the slot array — it belongs at slot ' + p + '. Needed: ' + len + ' + ' + this.slotSize +
      ' bytes for the slot = ' + need + '; free: ' + fs.contiguous + ' contiguous' + (fs.total > fs.contiguous ? ', ' + fs.total + ' counting dead cells.' : '.'),
      { slots: p < this.slots.length ? mk1(p, 'compare') : {} }, 'insert ' + key + ' (' + len + ' B)');
    if (need > fs.total) {
      this._emit('full', 'Page full: ' + need + ' bytes needed but only ' + fs.total + ' free. In a B-tree this is where the page splits.', {}, { html: 'page full', state: 'deleted' });
      return this._finish(false);
    }
    if (need > fs.contiguous) {
      this._compact();
      this._emit('defragment', 'Enough space in total, but not in one piece. Defragment first: slide live cells to the end of the page and drop the dead ones.',
        {}, { html: 'defragment', state: 'merge' });
    }
    var cell = { id: 'c' + (++this._nextId), key: key, off: this.upper() - len, len: len, label: label === undefined || label === null ? String(key) : label, dead: false };
    this.cells.push(cell);
    this._emit('write-cell', 'Write the cell at the end of the free space: bytes ' + cell.off + '–' + (cell.off + len - 1) + '. Cell content grows backward from the end of the page.',
      { cells: mk1(cell.id, 'inserted') });
    this.slots.splice(p, 0, cell);
    this._emit('write-slot', (p < this.slots.length - 1 ? 'Shift slots ' + p + '… one place right and store' : 'Append') + ' the cell\'s offset (' + cell.off + ') ' +
      (p < this.slots.length - 1 ? 'in' : 'as') + ' slot ' + p + '. Only ' + this.slotSize + '-byte slots move — the cells stay put, yet the slot array is in key order.',
      { cells: mk1(cell.id, 'inserted'), slots: mk1(p, 'inserted'), pointers: [p] });
    return this._finish(true);
  };
  SlottedPage.prototype.delete = function (key, opts) {
    this._rec = opts && opts.steps === false ? null : [];
    var p = this._find(key), K = k(key);
    if (p >= this.slots.length || this.cmp(this.slots[p].key, key) !== 0) {
      this._emit('not-found', 'Key ' + K + ' is not on this page.', {});
      return this._finish(false);
    }
    var cell = this.slots[p];
    this._emit('find', 'Delete ' + K + ': binary search finds it at slot ' + p + ', pointing to the cell at offset ' + cell.off + '.',
      { slots: mk1(p, 'deleted'), cells: mk1(cell.id, 'deleted'), pointers: [p] }, 'delete ' + key);
    this.slots.splice(p, 1);
    cell.dead = true;
    var up = this.upper();
    if (cell.off === up) {
      // dead cells bordering the free space are reclaimed immediately
      var self = this, again = true;
      while (again) {
        again = false;
        up = this.upper();
        this.cells = this.cells.filter(function (c) { if (c.dead && c.off === up) { again = true; return false; } return true; });
        if (!self.cells.length) break;
      }
      this._emit('remove-slot', 'Remove slot ' + p + ' (later slots shift left). The cell bordered the free space, so its bytes are free again right away.', {});
    } else {
      this._emit('remove-slot', 'Remove slot ' + p + ' (later slots shift left). The cell\'s ' + cell.len + ' bytes become dead space in the middle of the cell area: nothing moves, so the page is now fragmented.',
        { cells: mk1(cell.id, 'deleted') });
    }
    return this._finish(true);
  };
  SlottedPage.prototype.defragment = function (opts) {
    this._rec = opts && opts.steps === false ? null : [];
    var dead = this.deadBytes();
    this._emit('before', dead ? 'Defragment: ' + dead + ' dead bytes are scattered between live cells.' : 'Defragment: there is no dead space, nothing to do.', {});
    if (dead) {
      this._compact();
      this._emit('defragment', 'Live cells slide to the end of the page; the slot array is rewritten with the new offsets. ' + dead + ' bytes rejoin the contiguous free space.',
        { pointers: 'all' }, { html: 'defragment: +' + dead + ' B', state: 'merge' });
    }
    return this._finish(true);
  };
  /** Returns an array of error strings (empty = valid). */
  SlottedPage.prototype.validate = function () {
    var errs = [], self = this, used = [];
    for (var i = 1; i < this.slots.length; i++) if (this.cmp(this.slots[i - 1].key, this.slots[i].key) >= 0) errs.push('slots not sorted at ' + i);
    this.slots.forEach(function (c) { if (c.dead || self.cells.indexOf(c) < 0) errs.push('slot points at dead/missing cell ' + c.id); });
    if (this.cells.filter(function (c) { return !c.dead; }).length !== this.slots.length) errs.push('live cell count != slot count');
    this.cells.forEach(function (c) {
      if (c.off < self.lower() || c.off + c.len > self.size) errs.push('cell ' + c.id + ' out of bounds');
      for (var b = c.off; b < c.off + c.len; b++) { if (used[b]) errs.push('cells overlap at byte ' + b); used[b] = 1; }
    });
    return errs;
  };

  /* ======================================================================
   * 11. Ready-made step generators
   * ==================================================================== */

  var steps = {
    /**
     * Lower-bound binary search over a sorted array, as ArrayView models.
     * Each step: {phase: 'init'|'mid'|'less'|'greater'|'done', caption, state, log}.
     * steps.index = first index with values[i] >= target; steps.found = exact match.
     */
    binarySearch: function (values, target) {
      var out = [], lo = 0, hi = values.length, T = k(target);
      var push = function (phase, caption, mid, states, log) {
        var ptrs = { lo: lo, hi: hi };
        if (mid !== null) ptrs.mid = mid;
        out.push({ phase: phase, caption: caption, log: log || null, state: { values: values.slice(), pointers: ptrs, states: states || {}, range: [lo, hi] } });
      };
      push('init', 'Search for ' + T + '. The answer lies in the half-open range [lo, hi) = [0, ' + hi + ').', null, {}, 'search ' + target);
      while (lo < hi) {
        var mid = lo + ((hi - lo) >> 1), v = values[mid];
        push('mid', 'mid = lo + (hi − lo) / 2 = ' + mid + '. Compare keys[' + mid + '] = ' + k(v, 'compare') + ' with ' + T + '.', mid, mk1(mid, 'compare'));
        if (v < target) {
          lo = mid + 1;
          push('less', k(v, 'compare') + ' &lt; ' + T + ': everything up to index ' + mid + ' is too small. lo = mid + 1 = ' + lo + '.', mid, mk1(mid, 'compare'), 'keys[' + mid + ']=' + v + ' < ' + target + ' → lo=' + lo);
        } else {
          hi = mid;
          push('greater', k(v, 'compare') + ' ≥ ' + T + ': the answer is at ' + mid + ' or to its left. hi = mid = ' + hi + '.', mid, mk1(mid, 'compare'), 'keys[' + mid + ']=' + v + ' ≥ ' + target + ' → hi=' + hi);
        }
      }
      var found = lo < values.length && values[lo] === target;
      push('done', 'lo = hi = ' + lo + ': ' + (found ? 'found ' + k(target, 'found') + ' at index ' + lo + '.'
        : T + ' is not present; index ' + lo + ' is where it would be inserted' + (lo < values.length ? ' (before ' + k(values[lo]) + ').' : ' (at the end).')),
        null, found ? mk1(lo, 'found') : {}, { html: found ? 'found at ' + lo : 'not found; insert at ' + lo, state: found ? 'found' : null });
      out[out.length - 1].state.range = null;
      out.index = lo;
      out.found = found;
      return out;
    }
  };

  /* ======================================================================
   * 12. More views: Lanes, Timeline, FrameGrid, MemoryMap, HexGrid, Chart, GraphView
   *     All are "dumb" views: call render(model) from a Stepper's onStep.
   * ==================================================================== */

  function swatch(token, solid) {
    var st = { '--s': 'var(--bt-' + token + ')', '--s-bg': 'var(--bt-' + token + (solid ? ')' : '-bg)') };
    return el('span.bt-swatch', { style: st });
  }
  function observeWidth(node, fn) {
    if (typeof ResizeObserver === 'undefined') return;
    var last = -1;
    new ResizeObserver(function () {
      var w = node.clientWidth;
      if (w !== last) { last = w; fn(); }
    }).observe(node);
  }

  /**
   * Swim lanes for threads / actors / engines, with a "who steps next" button per lane.
   * new BTViz.Lanes(target, {onAdvance(id), stepLabel = 'Step'}).render({
   *   lanes: [{id, label, state?: 'running'|'blocked'|'done'|<state>, status?: html,
   *            events?: [{text, state?, title?}], canStep?: bool}], next?: id })
   */
  var LANE_STATE = { running: 'active', blocked: 'compare', waiting: 'compare', done: 'found', aborted: 'deleted' };
  function Lanes(target, opts) {
    this.opts = opts || {};
    this.root = el('div.bt-lanes');
    resolve(target).appendChild(this.root);
  }
  Lanes.prototype.render = function (model) {
    var self = this, o = this.opts;
    var a = document.activeElement, focusId = a && this.root.contains(a) ? a.getAttribute('data-lane') : null;
    this.root.textContent = '';
    (model.lanes || []).forEach(function (ln) {
      var st = LANE_STATE[ln.state] || ln.state;
      var track = el('div.bt-lane-track');
      (ln.events || []).forEach(function (ev, i) {
        if (typeof ev === 'string') ev = { text: ev };
        track.appendChild(el('span', { class: stateClass('bt-chip', ev.state), title: ev.title || null, html: ev.text }));
      });
      if (!(ln.events || []).length) track.appendChild(el('span.bt-log-empty', 'no steps yet'));
      var btn = el('button.bt-btn', {
        type: 'button', 'data-lane': ln.id, disabled: ln.canStep === false,
        'aria-label': 'Advance ' + (ln.label || ln.id),
        onclick: function () { if (o.onAdvance) o.onAdvance(ln.id); }
      }, (o.stepLabel || 'Step') + ' ▸');
      if (model.next === ln.id) btn.classList.add('bt-primary');
      var lane = el('div', { class: stateClass('bt-lane', st) },
        el('div.bt-lane-head', el('strong', ln.label || ln.id),
          ln.state ? el('span', { class: stateClass('bt-chip', st) }, ln.state) : null,
          o.onAdvance ? btn : null),
        ln.status ? el('div.bt-lane-status', { html: ln.status }) : null, track);
      self.root.appendChild(lane);
      track.scrollLeft = track.scrollWidth;
    });
    if (focusId !== null) {
      var b = this.root.querySelector('button[data-lane="' + focusId + '"]:not(:disabled)') || this.root.querySelector('button:not(:disabled)');
      if (b) b.focus();
    }
    return this;
  };

  /**
   * Horizontal record timeline (WAL, event log) with a draggable crash scrubber.
   * new BTViz.Timeline(target, {onCrash(pos), cellW = 76, crashLabel = 'crash'}).render({
   *   records: [{label, sub?, state?: 'pending'|'durable'|'lost'|<state>, title?}],
   *   crash?: n })       // crash position n = "crash after the first n records"; null hides it
   */
  var REC_STATE = { pending: 'compare', durable: 'found', lost: 'deleted', applied: 'active', torn: 'dirty' };
  function Timeline(target, opts) {
    var self = this;
    this.opts = { cellW: 96, crashLabel: 'crash', ariaLabel: 'Timeline' };
    for (var key in (opts || {})) this.opts[key] = opts[key];
    this.crash = null;
    this.n = 0;
    this.row = el('div.bt-tl-row');
    this.handle = el('div.bt-tl-crash', { role: 'slider', tabindex: 0, 'aria-label': 'Crash point', 'aria-valuemin': 0 },
      el('span.bt-tl-grip', this.opts.crashLabel));
    this.inner = el('div.bt-tl-in', this.row, this.handle);
    this.root = el('div.bt-timeline', { role: 'group', 'aria-label': this.opts.ariaLabel }, this.inner);
    resolve(target).appendChild(this.root);
    var dragging = false;
    var at = function (e) {
      var r = self.inner.getBoundingClientRect();
      self._set(Math.round((e.clientX - r.left) / self.opts.cellW), true);
    };
    this.handle.addEventListener('pointerdown', function (e) { dragging = true; self.handle.setPointerCapture(e.pointerId); e.preventDefault(); self.handle.focus(); });
    this.handle.addEventListener('pointermove', function (e) { if (dragging) at(e); });
    this.handle.addEventListener('pointerup', function () { dragging = false; });
    this.handle.addEventListener('pointercancel', function () { dragging = false; });
    this.handle.addEventListener('keydown', function (e) {
      var d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : e.key === 'Home' ? -1e9 : e.key === 'End' ? 1e9 : 0;
      if (!d) return;
      e.preventDefault();
      e.stopPropagation();
      self._set((self.crash || 0) + d, true);
    });
  }
  Timeline.prototype._set = function (pos, notify) {
    pos = clamp(pos, 0, this.n);
    var changed = pos !== this.crash;
    this.crash = pos;
    this.handle.style.transform = 'translateX(' + (pos * this.opts.cellW) + 'px)';
    this.handle.setAttribute('aria-valuenow', pos);
    this.handle.setAttribute('aria-valuemax', this.n);
    this.handle.setAttribute('aria-valuetext', 'after record ' + pos + ' of ' + this.n);
    if (changed && notify && this.opts.onCrash) this.opts.onCrash(pos);
  };
  Timeline.prototype.render = function (model) {
    var o = this.opts, recs = model.records || [], row = this.row;
    this.n = recs.length;
    row.textContent = '';
    recs.forEach(function (r, i) {
      var st = REC_STATE[r.state] || r.state;
      row.appendChild(el('div', { class: stateClass('bt-tl-rec' + (r.state === 'lost' ? ' is-lost' : ''), st), title: r.title || ((r.state ? r.state + ': ' : '') + r.label), style: { width: (o.cellW - 6) + 'px' } },
        el('span.bt-tl-n', String(r.lsn === undefined ? i + 1 : r.lsn)), el('span.bt-tl-label', { html: r.label }),
        r.sub ? el('span.bt-tl-sub', { html: r.sub }) : (r.state ? el('span.bt-tl-sub', r.state) : null)));
    });
    this.inner.style.width = (Math.max(1, recs.length) * o.cellW + 8) + 'px';
    var show = model.crash !== null && (model.crash !== undefined || this.crash !== null);
    this.handle.style.display = show ? '' : 'none';
    if (show) this._set(model.crash !== undefined ? model.crash : this.crash, false);
    return this;
  };

  /**
   * Buffer-pool frames with a clock hand.
   * new BTViz.FrameGrid(target).render({ hand?: index,
   *   frames: [{page: id | null, pin?: n, dirty?: bool, ref?: 0|1, state?, note?}] })
   */
  function FrameGrid(target, opts) {
    this.opts = opts || {};
    this.root = el('div.bt-frames', { role: 'list', 'aria-label': this.opts.ariaLabel || 'Buffer pool frames' });
    resolve(target).appendChild(this.root);
  }
  FrameGrid.prototype.render = function (model) {
    var root = this.root;
    root.textContent = '';
    (model.frames || []).forEach(function (f, i) {
      var empty = f.page === null || f.page === undefined;
      var st = f.state || (empty ? 'free' : f.dirty ? 'dirty' : null);
      var hand = model.hand === i;
      root.appendChild(el('div', { class: stateClass('bt-frame' + (hand ? ' is-hand' : ''), st), role: 'listitem' },
        el('div.bt-frame-top', el('span', 'frame ' + i), hand ? el('span.bt-frame-hand', { title: 'clock hand' }, '◀ hand') : null),
        el('div.bt-frame-page', empty ? '—' : String(f.page)),
        el('div.bt-frame-bits',
          el('span', { title: 'pin count' }, 'pin ' + (f.pin || 0)),
          f.ref === undefined ? null : el('span', { title: 'reference bit' }, 'ref ' + (f.ref ? 1 : 0)),
          f.dirty ? el('span.bt-frame-dirty', 'dirty') : null),
        f.note ? el('div.bt-frame-note', { html: f.note }) : null));
    });
    return this;
  };

  /**
   * Fixed-size slots / slabs (allocator and pool pictures).
   * new BTViz.MemoryMap(target, {cell = 30}).render({slots: [slot…]})
   *                                        or .render({slabs: [{label, slots: [slot…]}]})
   * slot: 'free' | 'used' | 'handle' | {state, label?, title?}
   */
  var SLOT_STATE = { used: 'pointer', allocated: 'pointer', handle: 'active', free: 'free' };
  function MemoryMap(target, opts) {
    this.opts = { cell: 30 };
    for (var key in (opts || {})) this.opts[key] = opts[key];
    this.root = el('div.bt-memmap', { style: { '--mc': this.opts.cell + 'px' } });
    resolve(target).appendChild(this.root);
  }
  MemoryMap.prototype.render = function (model) {
    var root = this.root, n = 0;
    root.textContent = '';
    var slabs = model.slabs || [{ label: model.label, slots: model.slots || [] }];
    slabs.forEach(function (sl) {
      var grid = el('div.bt-mem-grid');
      (sl.slots || []).forEach(function (s) {
        if (typeof s === 'string') s = { state: s };
        var state = s.state || 'free', st = SLOT_STATE[state] || state;
        grid.appendChild(el('div', { class: stateClass('bt-mem-slot' + (state === 'free' ? ' is-free' : ''), st), title: s.title || ('slot ' + n + ': ' + state) },
          s.label === undefined || s.label === null ? '' : String(s.label)));
        n++;
      });
      root.appendChild(el('div.bt-mem-slab', sl.label ? el('div.bt-mem-label', sl.label) : null, grid));
    });
    return this;
  };

  /**
   * Hex dump with offsets, per-range colouring and labels.
   * new BTViz.HexGrid(target, {cols = 16, base = 16}).render({
   *   bytes: [n…] | Uint8Array, ranges?: [{from, len, state?, label?}], offset?: n })
   */
  function HexGrid(target, opts) {
    this.opts = { cols: 16, base: 16 };
    for (var key in (opts || {})) this.opts[key] = opts[key];
    this.grid = el('div.bt-hex-grid', { role: 'img' });
    this.labels = el('div.bt-page-regions');
    this.root = el('div.bt-hex', el('div.bt-hex-scroll', { tabindex: 0 }, this.grid), this.labels);
    resolve(target).appendChild(this.root);
  }
  HexGrid.prototype.render = function (model) {
    var o = this.opts, cols = o.cols, bytes = model.bytes || [], n = bytes.length, off0 = model.offset || 0;
    var grid = this.grid, labels = this.labels, own = new Array(n), i;
    (model.ranges || []).forEach(function (r, ri) { for (var b = r.from; b < r.from + r.len && b < n; b++) own[b] = ri; });
    grid.textContent = '';
    grid.style.gridTemplateColumns = 'auto repeat(' + cols + ', minmax(17px, 1fr))';
    grid.setAttribute('aria-label', 'Hex dump of ' + n + ' bytes');
    var pad = o.base === 16 ? 4 : 5;
    for (i = 0; i < n; i++) {
      if (i % cols === 0) grid.appendChild(el('div.bt-hex-off', ('0000' + (off0 + i).toString(o.base)).slice(-pad)));
      var v = bytes[i], r = own[i] === undefined ? null : model.ranges[own[i]];
      var cls = 'bt-hex-b' + (r ? ' in-range' : '') + (r && r.from === i ? ' is-first' : '');
      grid.appendChild(el('div', { class: stateClass(cls, r ? r.state || 'pointer' : null), title: 'offset ' + (off0 + i) + (r && r.label ? ' · ' + r.label : '') },
        v === null || v === undefined ? '··' : ('0' + (v & 255).toString(16)).slice(-2)));
    }
    labels.textContent = '';
    (model.ranges || []).forEach(function (r) {
      if (!r.label) return;
      labels.appendChild(el('span', { class: stateClass('bt-chip', r.state || 'pointer') },
        el('span.bt-swatch'), r.label + ' · ' + (off0 + r.from) + (r.len > 1 ? '–' + (off0 + r.from + r.len - 1) : '')));
    });
    return this;
  };

  /**
   * Small SVG charts: bar histogram and (live) multi-series line chart.
   * const c = new BTViz.Chart(target, {type: 'bar' | 'line', height = 220, xLabel, yLabel, yMax, maxPoints = 120});
   * c.render({labels: [..], series: [{name, values: [..], token?}]});
   * c.push({A: 3, B: 5}[, label])   — append one point per series (line charts; creates series on first use)
   */
  var SERIES_TOKENS = ['node-active', 'split', 'merge', 'key-compare', 'key-inserted', 'key-found', 'page-dirty'];
  function niceMax(v) {
    if (!(v > 0)) return 1;
    var p = Math.pow(10, Math.floor(Math.log10(v))), f = v / p;
    return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 4 ? 4 : f <= 5 ? 5 : 10) * p;
  }
  function fmtNum(v) {
    if (Math.abs(v) >= 1e6) return +(v / 1e6).toFixed(1) + 'M';
    if (Math.abs(v) >= 1e4) return +(v / 1e3).toFixed(1) + 'k';
    return String(+v.toFixed(2));
  }
  function Chart(target, opts) {
    var self = this;
    this.opts = { type: 'bar', height: 220, maxPoints: 120 };
    for (var key in (opts || {})) this.opts[key] = opts[key];
    this.data = { labels: [], series: [] };
    this.svg = el('svg', { class: 'bt-chart-svg', role: 'img' });
    this.legendEl = el('div.bt-legend.bt-chart-legend');
    this.root = el('div.bt-chart', this.svg, this.legendEl);
    resolve(target).appendChild(this.root);
    observeWidth(this.root, function () { self._draw(); });
  }
  Chart.prototype.render = function (data) {
    this.data = { labels: (data.labels || []).slice(), series: (data.series || []).map(function (s) { return { name: s.name, token: s.token, values: s.values.slice() }; }) };
    this._draw();
    return this;
  };
  Chart.prototype.push = function (point, label) {
    var d = this.data, max = this.opts.maxPoints;
    Object.keys(point).forEach(function (name) {
      var s = d.series.filter(function (x) { return x.name === name; })[0];
      if (!s) { s = { name: name, values: [] }; d.series.push(s); }
      s.values.push(point[name]);
      if (s.values.length > max) s.values.shift();
    });
    this._count = (this._count || 0) + 1;
    d.labels.push(label === undefined ? this._count : label);
    if (d.labels.length > max) d.labels.shift();
    this._draw();
    return this;
  };
  Chart.prototype.clear = function () { this._count = 0; this.data = { labels: [], series: [] }; this._draw(); return this; };
  Chart.prototype._draw = function () {
    var o = this.opts, d = this.data, svg = this.svg;
    var W = Math.max(240, this.root.clientWidth || 600), H = o.height;
    var m = { l: 44, r: 14, t: o.yLabel ? 28 : 16, b: o.xLabel ? 42 : 26 };
    var pw = W - m.l - m.r, ph = H - m.t - m.b, S = d.series.length, i, si;
    var n = 0, vmax = 0;
    d.series.forEach(function (s) { n = Math.max(n, s.values.length); s.values.forEach(function (v) { if (v > vmax) vmax = v; }); });
    if (o.type === 'bar') n = Math.max(n, d.labels.length);
    var ymax = o.yMax || niceMax(vmax);
    var Y = function (v) { return m.t + ph - (v / ymax) * ph; };
    svg.textContent = '';
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    svg.setAttribute('width', W);
    svg.setAttribute('height', H);
    svg.setAttribute('aria-label', (o.title || (o.type === 'bar' ? 'Bar chart' : 'Line chart')) + ': ' +
      d.series.map(function (s) { return s.name + ' ' + (s.values.length ? fmtNum(s.values[s.values.length - 1]) : ''); }).join(', '));
    for (i = 0; i <= 4; i++) {
      var v = ymax * i / 4, y = Y(v);
      svg.appendChild(el('line', { class: i ? 'bt-chart-grid' : 'bt-chart-axis', x1: m.l, x2: W - m.r, y1: y, y2: y }));
      svg.appendChild(el('text', { class: 'bt-chart-tick', x: m.l - 6, y: y, 'text-anchor': 'end', 'dominant-baseline': 'central' }, fmtNum(v)));
    }
    if (o.yLabel) svg.appendChild(el('text', { class: 'bt-chart-label', x: 4, y: 11 }, o.yLabel));
    if (o.xLabel) svg.appendChild(el('text', { class: 'bt-chart-label', x: m.l + pw / 2, y: H - 6, 'text-anchor': 'middle' }, o.xLabel));
    var every = Math.max(1, Math.ceil(n / Math.max(1, Math.floor(pw / 44))));
    var tok = function (s, idx) { return 'var(--bt-' + (s.token || SERIES_TOKENS[idx % SERIES_TOKENS.length]) + ')'; };
    if (o.type === 'bar') {
      var band = n ? pw / n : pw, bw = Math.min(46, band * 0.72 / Math.max(1, S));
      for (i = 0; i < n; i++) {
        var cx = m.l + band * (i + 0.5);
        if (i % every === 0 && d.labels[i] !== undefined) svg.appendChild(el('text', { class: 'bt-chart-tick', x: cx, y: m.t + ph + 14, 'text-anchor': 'middle' }, String(d.labels[i])));
        for (si = 0; si < S; si++) {
          var val = d.series[si].values[i] || 0, x = cx - bw * S / 2 + si * bw, top = Y(val);
          svg.appendChild(el('rect', { class: 'bt-chart-bar', x: x + 0.5, y: top, width: Math.max(1, bw - 1), height: Math.max(0, m.t + ph - top), rx: 2, style: { fill: tok(d.series[si], si) } },
            el('svg:title', d.series[si].name + ' · ' + d.labels[i] + ': ' + val)));
          if (n * S <= 16 && bw >= 16) svg.appendChild(el('text', { class: 'bt-chart-val', x: x + bw / 2, y: top - 4, 'text-anchor': 'middle' }, fmtNum(val)));
        }
      }
    } else {
      var X = function (idx) { return m.l + (n > 1 ? pw * idx / (n - 1) : pw / 2); };
      for (i = 0; i < n; i += every) if (d.labels[i] !== undefined) svg.appendChild(el('text', { class: 'bt-chart-tick', x: X(i), y: m.t + ph + 14, 'text-anchor': 'middle' }, String(d.labels[i])));
      d.series.forEach(function (s, idx) {
        if (!s.values.length) return;
        var pts = s.values.map(function (val, j) { return X(j).toFixed(1) + ',' + Y(val).toFixed(1); }).join(' ');
        svg.appendChild(el('polyline', { class: 'bt-chart-line', points: pts, style: { stroke: tok(s, idx) } }));
        var lx = X(s.values.length - 1), ly = Y(s.values[s.values.length - 1]);
        svg.appendChild(el('circle', { cx: lx, cy: ly, r: 3.5, style: { fill: tok(s, idx) } }));
        svg.appendChild(el('text', { class: 'bt-chart-val', x: Math.min(lx, W - m.r) - 6, y: ly - 7, 'text-anchor': 'end' }, fmtNum(s.values[s.values.length - 1])));
      });
    }
    var lg = this.legendEl;
    lg.textContent = '';
    if (S > 1 || o.legend) d.series.forEach(function (s, idx) {
      lg.appendChild(el('span.bt-legend-item', swatch(s.token || SERIES_TOKENS[idx % SERIES_TOKENS.length], true), s.name));
    });
  };

  /**
   * 2D points and edges (IVF cells, HNSW layers, any small graph).
   * new BTViz.GraphView(target, {height = 300, onNodeClick}).render({
   *   nodes: [{id, x, y, label?, state?, shape?: 'circle'|'square'|'diamond'|'cross', r?}],
   *   edges?: [{from, to, state?, dashed?}],
   *   regions?: [{points: [[x, y]…], state?, label?}] }, highlight?)
   * highlight: {nodes: {id: state}, edges: {'from>to': state}}. Coordinates are in your own units.
   */
  function GraphView(target, opts) {
    var self = this;
    this.opts = { height: 300, pad: 26, r: 6, ariaLabel: 'Graph' };
    for (var key in (opts || {})) this.opts[key] = opts[key];
    this.svg = el('svg', { class: 'bt-graph-svg', role: 'img', 'aria-label': this.opts.ariaLabel });
    this.root = el('div.bt-graph', this.svg);
    resolve(target).appendChild(this.root);
    observeWidth(this.root, function () { if (self.model) self.render(self.model, self.hl); });
  }
  GraphView.prototype.render = function (model, hl) {
    this.model = model; this.hl = hl = hl || {};
    var o = this.opts, svg = this.svg, self = this;
    var W = Math.max(200, this.root.clientWidth || 600), H = o.height;
    var x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
    var see = function (x, y) { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); };
    (model.nodes || []).forEach(function (n) { see(n.x, n.y); });
    (model.regions || []).forEach(function (r) { r.points.forEach(function (p) { see(p[0], p[1]); }); });
    if (x0 === Infinity) { x0 = y0 = 0; x1 = y1 = 1; }
    var sc = Math.min((W - o.pad * 2) / ((x1 - x0) || 1), (H - o.pad * 2) / ((y1 - y0) || 1));
    var ox = (W - (x1 - x0) * sc) / 2, oy = (H - (y1 - y0) * sc) / 2;
    var PX = function (x) { return ox + (x - x0) * sc; }, PY = function (y) { return oy + (y - y0) * sc; };
    svg.textContent = '';
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    svg.setAttribute('width', W);
    svg.setAttribute('height', H);
    var byId = {};
    (model.nodes || []).forEach(function (n) { byId[n.id] = n; });
    (model.regions || []).forEach(function (r) {
      svg.appendChild(el('polygon', { class: stateClass('bt-graph-region', r.state), points: r.points.map(function (p) { return PX(p[0]).toFixed(1) + ',' + PY(p[1]).toFixed(1); }).join(' ') }));
    });
    (model.edges || []).forEach(function (e) {
      var a = byId[e.from], b = byId[e.to];
      if (!a || !b) return;
      var st = (hl.edges || {})[e.from + '>' + e.to] || (hl.edges || {})[e.to + '>' + e.from] || e.state;
      svg.appendChild(el('line', { class: stateClass('bt-graph-edge' + (e.dashed ? ' is-dashed' : ''), st), x1: PX(a.x), y1: PY(a.y), x2: PX(b.x), y2: PY(b.y) }));
    });
    (model.nodes || []).forEach(function (n) {
      var st = (hl.nodes || {})[n.id] || n.state, r = n.r || o.r, x = PX(n.x), y = PY(n.y), shape;
      if (n.shape === 'square') shape = el('rect', { x: x - r, y: y - r, width: 2 * r, height: 2 * r, rx: 1.5 });
      else if (n.shape === 'diamond') shape = el('path', { d: 'M' + x + ' ' + (y - r * 1.3) + 'L' + (x + r * 1.3) + ' ' + y + 'L' + x + ' ' + (y + r * 1.3) + 'L' + (x - r * 1.3) + ' ' + y + 'z' });
      else if (n.shape === 'cross') shape = el('path', { class: 'is-cross', d: 'M' + (x - r) + ' ' + (y - r) + 'L' + (x + r) + ' ' + (y + r) + 'M' + (x - r) + ' ' + (y + r) + 'L' + (x + r) + ' ' + (y - r) });
      else shape = el('circle', { cx: x, cy: y, r: r });
      var g = el('g', { class: stateClass('bt-graph-node' + (o.onNodeClick ? ' is-clickable' : ''), st), 'data-id': n.id }, shape,
        el('svg:title', (n.label === undefined ? n.id : n.label) + (st ? ' (' + st + ')' : '')));
      if (n.label !== undefined && n.label !== null) {
        var right = x > W - 60;
        g.appendChild(el('text', { x: x + (right ? -(r + 4) : r + 4), y: y - r - 2, 'text-anchor': right ? 'end' : 'start' }, String(n.label)));
      }
      if (o.onNodeClick) g.addEventListener('click', function () { o.onNodeClick(n.id, n); });
      svg.appendChild(g);
    });
    return this;
  };

  /* ======================================================================
   * 13. selfTest — "the JS model reproduces what the Zig/Rust program printed"
   * ==================================================================== */

  function canon(v) {
    if (typeof v === 'string') return v.replace(/\r\n/g, '\n').split('\n').map(function (l) { return l.replace(/\s+$/, ''); }).join('\n').trim();
    return JSON.stringify(v, function (key, val) {
      if (val && typeof val === 'object' && !Array.isArray(val)) {
        var o = {};
        Object.keys(val).sort().forEach(function (p) { o[p] = val[p]; });
        return o;
      }
      return val;
    }, 1);
  }
  /**
   * BTViz.selfTest(name, actual, expected[, target]) → boolean.
   * Strings are compared ignoring trailing whitespace; everything else structurally.
   * Shows a ✓/✗ badge (in `target`, or a strip at the end of <main>) and console.error()s on mismatch.
   * Results accumulate in BTViz.selfTest.results = [{name, ok}].
   */
  function selfTest(name, actual, expected, target) {
    var a = canon(actual), e = canon(expected), ok = a === e;
    selfTest.results.push({ name: name, ok: ok });
    if (!ok && typeof console !== 'undefined') console.error('BTViz.selfTest FAILED: ' + name + '\n--- expected ---\n' + e + '\n--- actual ---\n' + a);
    if (!hasDOM) return ok;
    var host = target ? resolve(target) : document.querySelector('.bt-selftests');
    if (!host) {
      host = el('div.bt-selftests', { role: 'status', 'aria-label': 'Model self-tests' }, el('span.bt-selftests-title', 'Self-tests'));
      (document.querySelector('main') || document.body).appendChild(host);
    }
    var badge = el('span', { class: 'bt-chip bt-selftest ' + (ok ? 's-found' : 's-deleted'), 'data-ok': ok ? '1' : '0', title: ok ? 'JS model output matches the expected output' : 'Mismatch — see below and the console' },
      (ok ? '✓ ' : '✗ ') + name);
    host.appendChild(badge);
    if (!ok) host.appendChild(el('details.bt-selftest-diff', el('summary', name + ': expected vs actual'),
      el('pre.bt-code', 'expected:\n' + e + '\n\nactual:\n' + a)));
    return ok;
  }
  selfTest.results = [];

  /* ======================================================================
   * 14. Export
   * ==================================================================== */

  BTViz.el = el;
  BTViz.esc = esc;
  BTViz.clone = clone;
  BTViz.k = k;
  BTViz.rng = rng;
  BTViz.motion = motion;
  BTViz.theme = theme;
  BTViz.page = page;
  BTViz.figure = figure;
  BTViz.legend = legend;
  BTViz.Stepper = Stepper;
  BTViz.TreeView = TreeView;
  BTViz.ArrayView = ArrayView;
  BTViz.PageView = PageView;
  BTViz.Log = Log;
  BTViz.codePanel = codePanel;
  BTViz.tintLine = tintLine;
  BTViz.Lanes = Lanes;
  BTViz.Timeline = Timeline;
  BTViz.FrameGrid = FrameGrid;
  BTViz.MemoryMap = MemoryMap;
  BTViz.HexGrid = HexGrid;
  BTViz.Chart = Chart;
  BTViz.GraphView = GraphView;
  BTViz.selfTest = selfTest;
  BTViz.models = { BTree: BTree, BPlusTree: BPlusTree, SlottedPage: SlottedPage };
  BTViz.steps = steps;

  root.BTViz = BTViz;
  if (typeof module !== 'undefined' && module.exports) module.exports = BTViz;
})(typeof window !== 'undefined' ? window : globalThis);

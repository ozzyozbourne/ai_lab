/* =====================================================================
   course.js — dependency-free helpers for the DPDK course chapters.
   Load at the end of <body>:  <script src="../../assets/course.js"></script>
   Works from file:// (no modules, no fetch). Everything lives on
   window.CourseJS. Chapter scripts should run after this file, either in
   a later <script> tag or inside CourseJS.ready(fn).

   AUTOMATIC (runs on DOMContentLoaded, no code needed)
   - Syntax highlighting of <pre><code class="language-c"> (also lang-c,
     language-bash / language-sh / language-console / language-make).
     <pre data-lines> adds line numbers; <pre data-hl="3,5-7"> highlights lines.
   - Copy buttons on every <pre> outside .terminal/.output (opt out with
     data-nocopy). In a .terminal, data-copy on the .terminal copies only the
     .cmd spans (the commands), one per line.
   - Tabs: .tabs > .tab-list > button.tab-btn[data-tab=X] + .tab-panel[data-tab=X]
   - Quizzes: .quiz[data-quiz] with .q[data-answer=N][data-explain] blocks
     (see README). Score shown in .quiz-score.
   - Sidebar TOC: <nav class="sidebar" data-auto-toc> is filled from the
     h2[id] / h3[id] of <main>; the link of the visible section is .active.
   - Theme toggle: any button.theme-toggle cycles auto -> light -> dark
     (sets <html data-theme>, remembered in localStorage when available).
   - .toc-toggle opens the sidebar on phones; .progress-bar shows reading %.
   - Figure numbers: an empty <span class="fig-num"></span> in a figcaption
     becomes "Figure N."
   - SVG arrow markers are injected once: url(#arrowhead), #arrowhead-c1..c7,
     #arrowhead-accent, #arrowtail. Class .svg-arrow uses them automatically.

   API
   CourseJS.ready(fn)                    run fn after DOM + auto-init
   CourseJS.$(sel, root?) / $$(sel, root?)  querySelector / array of matches
   CourseJS.cssVar('--c1')               current computed value of a CSS var
   CourseJS.onThemeChange(fn)            fn() whenever light/dark flips
   CourseJS.clamp(v,a,b), lerp(a,b,t), ease.inOut(t)/out(t)/linear(t)
   CourseJS.fmt(n, digits?)              1234567 -> "1,234,567"; fmt(3.14159,2)
   CourseJS.sleep(ms)                    Promise
   CourseJS.tween({from,to,duration,ease,onUpdate(v,t),onDone}) -> {cancel()}
       from/to are numbers or {x:..,y:..} objects of numbers.

   CourseJS.highlightC(src) -> html      C tokens as <span class="tok-*">
   CourseJS.highlightShell(src) -> html
   CourseJS.highlightAll(root?)          re-run highlighting (idempotent)
   CourseJS.addCopyButtons(root?)        re-run copy buttons (idempotent)
   CourseJS.initTabs(root?)
   CourseJS.copyText(text) -> Promise

   CourseJS.svg  (all return the created element; parent may be null)
     .el(tag, attrs, parent)          generic SVG element; attrs.text sets textContent,
                                      attrs.class sets class
     .group(parent, cls?, attrs?)
     .rect(parent, x, y, w, h, cls?, attrs?)         rx=6 by default
     .box(parent, x, y, w, h, label, cls?, attrs?)   <g> with rect + centred text;
                                      returns g with g.rect / g.label
     .text(parent, x, y, str, cls?, attrs?)
     .line(parent, x1, y1, x2, y2, cls?, attrs?)
     .arrow(parent, x1, y1, x2, y2, cls?, attrs?)    path with marker-end
     .curve(parent, x1, y1, x2, y2, bend, cls?)      quadratic arrow
     .path(parent, d, cls?, attrs?)
     .packet(parent, x, y, w?, h?, cls?, label?)     small rounded packet (g)
     .moveTo(el, x, y)                 sets transform=translate(x,y) (el._x, el._y)
     .clear(el)                        remove all children
     .ensureDefs()                     inject arrow markers (automatic)

   new CourseJS.Stepper(root, options)  step-through animation
     root: element or selector of a .widget containing an <svg>. Missing
       .stepper-caption and .controls are created.
     options.steps: [{ caption: 'html', run(ctx, isCurrent), predict? }]
       Going to step i calls options.reset(ctx) then steps[0..i].run(ctx, k===i),
       so run() only needs to apply its own change (no undo code needed).
     options.reset(ctx)       put the picture back to its initial state
     options.interval = 1800  ms per step while playing
     options.loop = false
     options.onStep(i, ctx)   called after each step is shown
     step.predict = { question, options:[...], answer: idx, explain }
       "predict, then step": the learner must answer before the step is shown.
     ctx = { root, svg, stepper, data: {} }  (ctx.data is yours to use)
     methods: go(i), next(), prev(), first(), play(), pause(), toggle(),
       .index, .length. Keyboard: Left/Right/Space when the widget has focus.

   new CourseJS.Animator(options)  requestAnimationFrame loop
     options.onFrame(dt, t, anim)   dt = seconds since last frame * speed (<=0.1)
     options.onReset(anim)          called by reset() and once at construction
     options.root                   widget element/selector: adds Play/Pause,
                                    Reset and a speed <select> to its .controls
     options.speed = 1, options.speeds = [0.25,0.5,1,2,4]
     options.autoplay = false | true | 'visible' (play while on screen)
     methods: play(), pause(), toggle(), reset(), setSpeed(s), .running, .t
     Pauses automatically when the tab is hidden; respects reduced motion
     (no autoplay).

   CourseJS.quiz(el, [{ q, options:[...], answer, explain }])  build a quiz
   CourseJS.bindRange(input, output, fmt?, onInput?)  live slider readouts
   ===================================================================== */
(function () {
  'use strict';
  var SVGNS = 'http://www.w3.org/2000/svg';
  var CJ = {};
  var readyQueue = [];
  var isReady = false;

  /* ---------- small utilities ---------- */
  CJ.$ = function (sel, root) { return typeof sel === 'string' ? (root || document).querySelector(sel) : sel; };
  CJ.$$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };
  CJ.clamp = function (v, a, b) { return Math.max(a, Math.min(b, v)); };
  CJ.lerp = function (a, b, t) { return a + (b - a) * t; };
  CJ.ease = {
    linear: function (t) { return t; },
    inOut: function (t) { return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2; },
    out: function (t) { return 1 - Math.pow(1 - t, 3); },
    in: function (t) { return t * t * t; }
  };
  CJ.fmt = function (n, digits) {
    if (typeof n !== 'number' || !isFinite(n)) return String(n);
    var d = digits == null ? (Number.isInteger(n) ? 0 : 2) : digits;
    return n.toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d });
  };
  CJ.sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
  CJ.cssVar = function (name, el) {
    return getComputedStyle(el || document.documentElement).getPropertyValue(name).trim();
  };
  CJ.ready = function (fn) { if (isReady) fn(); else readyQueue.push(fn); };
  CJ.reducedMotion = function () {
    return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  };

  function safeGet(k) { try { return window.localStorage.getItem(k); } catch (e) { return null; } }
  function safeSet(k, v) { try { if (v == null) window.localStorage.removeItem(k); else window.localStorage.setItem(k, v); } catch (e) { /* ignore */ } }

  CJ.tween = function (o) {
    var from = o.from, to = o.to, dur = o.duration || 400, ease = o.ease || CJ.ease.inOut;
    var start = null, raf = 0, cancelled = false;
    function val(t) {
      if (typeof from === 'number') return CJ.lerp(from, to, t);
      var r = {}; for (var k in from) r[k] = CJ.lerp(from[k], to[k], t); return r;
    }
    function step(ts) {
      if (cancelled) return;
      if (start === null) start = ts;
      var t = CJ.clamp((ts - start) / dur, 0, 1);
      if (o.onUpdate) o.onUpdate(val(ease(t)), t);
      if (t < 1) raf = requestAnimationFrame(step); else if (o.onDone) o.onDone();
    }
    if (CJ.reducedMotion() || dur <= 0) { if (o.onUpdate) o.onUpdate(val(1), 1); if (o.onDone) o.onDone(); }
    else raf = requestAnimationFrame(step);
    return { cancel: function () { cancelled = true; cancelAnimationFrame(raf); } };
  };

  /* ---------- theme ---------- */
  var themeListeners = [];
  CJ.onThemeChange = function (fn) { themeListeners.push(fn); };
  function fireTheme() { themeListeners.forEach(function (f) { try { f(); } catch (e) { console.error(e); } }); }
  if (window.matchMedia) {
    var mq = window.matchMedia('(prefers-color-scheme: dark)');
    if (mq.addEventListener) mq.addEventListener('change', fireTheme);
  }
  var savedTheme = safeGet('dpdk-course-theme');
  if (savedTheme === 'light' || savedTheme === 'dark') document.documentElement.setAttribute('data-theme', savedTheme);
  function themeLabel() {
    var t = document.documentElement.getAttribute('data-theme');
    return t === 'light' ? 'Theme: light' : t === 'dark' ? 'Theme: dark' : 'Theme: auto';
  }
  function initThemeToggle() {
    CJ.$$('.theme-toggle').forEach(function (b) {
      if (b._cj) return; b._cj = true;
      b.textContent = themeLabel();
      b.addEventListener('click', function () {
        var cur = document.documentElement.getAttribute('data-theme');
        var nxt = cur === null ? 'light' : cur === 'light' ? 'dark' : null;
        if (nxt) document.documentElement.setAttribute('data-theme', nxt);
        else document.documentElement.removeAttribute('data-theme');
        safeSet('dpdk-course-theme', nxt);
        CJ.$$('.theme-toggle').forEach(function (x) { x.textContent = themeLabel(); });
        fireTheme();
      });
    });
  }

  /* ---------- syntax highlighting ---------- */
  function esc(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
  // wrap text in a span, but split at newlines so every line is self-contained
  function span(cls, text) {
    return text.split('\n').map(function (part) {
      return part ? '<span class="' + cls + '">' + esc(part) + '</span>' : '';
    }).join('\n');
  }
  function wordSet(s) { var o = Object.create(null); s.split(/\s+/).forEach(function (w) { if (w) o[w] = 1; }); return o; }
  var C_KW = wordSet('if else for while do switch case default break continue return goto sizeof typedef struct union enum ' +
    'static const volatile extern inline register restrict _Alignas _Alignof _Atomic _Static_assert static_assert ' +
    '__attribute__ __thread _Thread_local thread_local asm __asm__ typeof __typeof__ true false NULL alignof');
  var C_TYPES = wordSet('void char short int long float double signed unsigned bool _Bool size_t ssize_t ' +
    'uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t uintptr_t intptr_t ptrdiff_t off_t ' +
    'rte_be16_t rte_be32_t rte_be64_t rte_le16_t rte_le32_t rte_le64_t rte_iova_t phys_addr_t FILE pid_t ' +
    'unaligned_uint16_t unaligned_uint32_t unaligned_uint64_t pthread_t va_list');
  var C_RE = /(\/\*[\s\S]*?\*\/|\/\/[^\n]*)|("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')|(^[ \t]*#[ \t]*[A-Za-z_]+)|(<[\w./+-]+\.h>)|(\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)[uUlLfF]*\b)|([A-Za-z_]\w*)/gm;

  CJ.highlightC = function (src) {
    var out = '', last = 0, m, prevWord = '';
    C_RE.lastIndex = 0;
    while ((m = C_RE.exec(src)) !== null) {
      if (m.index > last) out += esc(src.slice(last, m.index));
      var t = m[0], after = src.slice(C_RE.lastIndex, C_RE.lastIndex + 40);
      if (m[1]) out += span('tok-com', t);
      else if (m[2]) out += span('tok-str', t);
      else if (m[3]) out += span('tok-pre', t);
      else if (m[4]) out += span('tok-str', t);
      else if (m[5]) out += span('tok-num', t);
      else {
        var cls = null;
        if (C_KW[t]) cls = 'tok-kw';
        else if (C_TYPES[t] || /_t$/.test(t) || prevWord === 'struct' || prevWord === 'union' || prevWord === 'enum') cls = 'tok-type';
        else if (/^[A-Z][A-Z0-9_]+$/.test(t)) cls = 'tok-macro';
        else if (/^\s*\(/.test(after)) cls = /^rte_/.test(t) ? 'tok-rte' : 'tok-fn';
        out += cls ? span(cls, t) : esc(t);
        prevWord = t;
        last = C_RE.lastIndex;
        continue;
      }
      prevWord = '';
      last = C_RE.lastIndex;
    }
    out += esc(src.slice(last));
    return out;
  };

  var SH_RE = /(#[^\n]*)|("(?:[^"\\]|\\.)*"|'[^']*')|(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$\(|\$\d)|((?:^|\s)--?[A-Za-z][\w-]*)|(\b\d+\b)/gm;
  CJ.highlightShell = function (src) {
    var out = '', last = 0, m;
    SH_RE.lastIndex = 0;
    while ((m = SH_RE.exec(src)) !== null) {
      // a '#' only starts a comment at line start or after whitespace
      if (m[1] && m.index > 0 && !/\s/.test(src[m.index - 1])) { SH_RE.lastIndex = m.index + 1; continue; }
      if (m.index > last) out += esc(src.slice(last, m.index));
      var t = m[0];
      if (m[1]) out += span('tok-com', t);
      else if (m[2]) out += span('tok-str', t);
      else if (m[3]) out += span('tok-macro', t);
      else if (m[4]) { var lead = t.match(/^\s*/)[0]; out += esc(lead) + span('tok-type', t.slice(lead.length)); }
      else out += span('tok-num', t);
      last = SH_RE.lastIndex;
    }
    out += esc(src.slice(last));
    return out;
  };

  function parseRanges(s) {
    var set = {};
    (s || '').split(',').forEach(function (p) {
      var r = p.trim().split('-').map(Number);
      if (!r[0]) return;
      for (var i = r[0]; i <= (r[1] || r[0]); i++) set[i] = 1;
    });
    return set;
  }
  function langOf(code) {
    var c = (code.className || '') + ' ' + (code.parentNode.getAttribute('data-lang') || '');
    var m = c.match(/(?:language|lang)-(\w+)/) || c.match(/^\s*(\w+)\s*$/);
    var l = m ? m[1] : (code.parentNode.getAttribute('data-lang') || '');
    if (/^(c|h|cpp)$/.test(l)) return 'c';
    if (/^(bash|sh|shell|console|make|makefile|meson)$/.test(l)) return 'sh';
    return '';
  }
  CJ.highlightAll = function (root) {
    CJ.$$('pre > code', root).forEach(function (code) {
      if (code._cjHl) return;
      var pre = code.parentNode;
      var lang = langOf(code);
      var html = lang === 'c' ? CJ.highlightC(code.textContent)
        : lang === 'sh' ? CJ.highlightShell(code.textContent) : null;
      var hl = pre.getAttribute('data-hl');
      var numbers = pre.hasAttribute('data-lines');
      if (html === null && !hl && !numbers) return;
      if (html === null) html = esc(code.textContent);
      if (hl || numbers) {
        var marks = parseRanges(hl);
        var lines = html.replace(/\n$/, '').split('\n');
        var start = parseInt(pre.getAttribute('data-start') || '1', 10);
        html = lines.map(function (ln, i) {
          var n = i + start;
          var body = (numbers ? '<span class="ln">' + n + '</span>' : '') + (ln || ' ');
          return marks[n] ? '<span class="hl-line">' + body + '</span>' : body;
        }).join('\n');
        if (numbers) pre.classList.add('line-numbers');
      }
      code.innerHTML = html;
      code._cjHl = true;
    });
  };

  /* ---------- copy to clipboard ---------- */
  CJ.copyText = function (text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    return new Promise(function (resolve, reject) {
      var ta = document.createElement('textarea');
      ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy') ? resolve() : reject(new Error('copy failed')); } catch (e) { reject(e); }
      document.body.removeChild(ta);
    });
  };
  function makeCopyBtn(getText) {
    var b = document.createElement('button');
    b.type = 'button'; b.className = 'copy-btn'; b.textContent = 'Copy';
    b.setAttribute('aria-label', 'Copy to clipboard');
    b.addEventListener('click', function () {
      CJ.copyText(getText()).then(function () {
        b.textContent = 'Copied'; b.classList.add('copied');
        setTimeout(function () { b.textContent = 'Copy'; b.classList.remove('copied'); }, 1400);
      }, function () { b.textContent = 'Press Ctrl+C'; });
    });
    return b;
  }
  function codeText(pre) {
    var c = pre.cloneNode(true);
    CJ.$$('.ln, .copy-btn', c).forEach(function (n) { n.remove(); });
    return c.textContent.replace(/\n$/, '');
  }
  CJ.addCopyButtons = function (root) {
    CJ.$$('pre', root).forEach(function (pre) {
      if (pre._cjCopy || pre.hasAttribute('data-nocopy')) return;
      if (pre.closest('.terminal, .output')) return;
      pre._cjCopy = true;
      var block = pre.closest('.code-block');
      var head = block && block.querySelector('.code-head');
      var btn = makeCopyBtn(function () { return codeText(pre); });
      if (head && !head.querySelector('.copy-btn')) { head.appendChild(btn); return; }
      // wrap so the button does not scroll with wide code
      var wrap = document.createElement('div');
      wrap.className = 'has-copy';
      pre.parentNode.insertBefore(wrap, pre);
      wrap.appendChild(pre);
      wrap.appendChild(btn);
    });
    CJ.$$('.terminal[data-copy], .output[data-copy]', root).forEach(function (t) {
      if (t._cjCopy) return; t._cjCopy = true;
      var bar = t.querySelector('.term-bar');
      var btn = makeCopyBtn(function () {
        return CJ.$$('.cmd', t).map(function (c) { return c.textContent; }).join('\n');
      });
      btn.style.marginLeft = 'auto'; btn.style.position = 'static';
      if (bar) bar.appendChild(btn); else t.insertBefore(btn, t.firstChild);
    });
  };

  /* ---------- tabs ---------- */
  CJ.initTabs = function (root) {
    CJ.$$('.tabs', root).forEach(function (tabs) {
      if (tabs._cj) return; tabs._cj = true;
      var btns = CJ.$$('.tab-btn', tabs).filter(function (b) { return b.closest('.tabs') === tabs; });
      var panels = CJ.$$('.tab-panel', tabs).filter(function (p) { return p.closest('.tabs') === tabs; });
      var list = tabs.querySelector('.tab-list');
      if (list) list.setAttribute('role', 'tablist');
      function select(name, focus) {
        btns.forEach(function (b) {
          var on = b.getAttribute('data-tab') === name;
          b.setAttribute('aria-selected', on ? 'true' : 'false');
          b.tabIndex = on ? 0 : -1;
          if (on && focus) b.focus();
        });
        panels.forEach(function (p) { p.hidden = p.getAttribute('data-tab') !== name; });
      }
      btns.forEach(function (b, i) {
        b.setAttribute('role', 'tab'); b.type = 'button';
        b.addEventListener('click', function () { select(b.getAttribute('data-tab')); });
        b.addEventListener('keydown', function (e) {
          var d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
          if (!d) return;
          e.preventDefault();
          select(btns[(i + d + btns.length) % btns.length].getAttribute('data-tab'), true);
        });
      });
      panels.forEach(function (p) { p.setAttribute('role', 'tabpanel'); });
      var initial = btns.filter(function (b) { return b.getAttribute('aria-selected') === 'true'; })[0] || btns[0];
      if (initial) select(initial.getAttribute('data-tab'));
    });
  };

  /* ---------- SVG builders ---------- */
  var S = {};
  S.el = function (tag, attrs, parent) {
    var e = document.createElementNS(SVGNS, tag);
    if (attrs) for (var k in attrs) {
      if (attrs[k] == null) continue;
      if (k === 'text') e.textContent = attrs[k];
      else e.setAttribute(k, attrs[k]);
    }
    if (parent) parent.appendChild(e);
    return e;
  };
  function withCls(a, cls) { a = a || {}; if (cls) a['class'] = (a['class'] ? a['class'] + ' ' : '') + cls; return a; }
  function merge(a, b) { var o = {}; var k; for (k in a) o[k] = a[k]; for (k in (b || {})) o[k] = b[k]; return o; }
  S.group = function (parent, cls, attrs) { return S.el('g', withCls(merge({}, attrs), cls), parent); };
  S.rect = function (parent, x, y, w, h, cls, attrs) {
    return S.el('rect', withCls(merge({ x: x, y: y, width: w, height: h, rx: 6 }, attrs), cls || 'svg-box'), parent);
  };
  S.text = function (parent, x, y, str, cls, attrs) {
    return S.el('text', withCls(merge({ x: x, y: y, text: str }, attrs), cls || 'svg-label'), parent);
  };
  S.box = function (parent, x, y, w, h, label, cls, attrs) {
    var g = S.group(parent, null, attrs);
    g.rect = S.rect(g, x, y, w, h, 'svg-box ' + (cls || ''));
    g.label = S.text(g, x + w / 2, y + h / 2, label, 'svg-label center');
    return g;
  };
  S.line = function (parent, x1, y1, x2, y2, cls, attrs) {
    return S.el('line', withCls(merge({ x1: x1, y1: y1, x2: x2, y2: y2 }, attrs), cls || 'svg-line'), parent);
  };
  S.path = function (parent, d, cls, attrs) { return S.el('path', withCls(merge({ d: d }, attrs), cls || 'svg-line'), parent); };
  S.arrow = function (parent, x1, y1, x2, y2, cls, attrs) {
    return S.path(parent, 'M' + x1 + ',' + y1 + ' L' + x2 + ',' + y2, 'svg-arrow' + (cls ? ' ' + cls : ''), attrs);
  };
  S.curve = function (parent, x1, y1, x2, y2, bend, cls) {
    var mx = (x1 + x2) / 2, my = (y1 + y2) / 2, dx = x2 - x1, dy = y2 - y1, len = Math.hypot(dx, dy) || 1;
    var cx = mx - dy / len * (bend || 30), cy = my + dx / len * (bend || 30);
    return S.path(parent, 'M' + x1 + ',' + y1 + ' Q' + cx + ',' + cy + ' ' + x2 + ',' + y2, 'svg-arrow' + (cls ? ' ' + cls : ''));
  };
  S.packet = function (parent, x, y, w, h, cls, label) {
    w = w || 26; h = h || 16;
    var g = S.group(parent, 'svg-fade');
    g.body = S.el('rect', { x: -w / 2, y: -h / 2, width: w, height: h, rx: 3, 'class': 'svg-packet' + (cls ? ' ' + cls : '') }, g);
    if (label != null) g.label = S.text(g, 0, 0.5, label, 'svg-label small center', { style: 'fill:#fff;font-weight:700;font-size:10px' });
    S.moveTo(g, x, y);
    return g;
  };
  S.moveTo = function (el, x, y) { el._x = x; el._y = y; el.setAttribute('transform', 'translate(' + x + ',' + y + ')'); return el; };
  S.clear = function (el) { while (el && el.firstChild) el.removeChild(el.firstChild); return el; };
  S.ensureDefs = function () {
    if (document.getElementById('arrowhead')) return;
    var svg = S.el('svg', { 'class': 'course-svg-defs', 'aria-hidden': 'true', width: 0, height: 0, focusable: 'false' });
    var defs = S.el('defs', null, svg);
    function marker(id, cls, reverse) {
      var m = S.el('marker', { id: id, viewBox: '0 0 10 10', refX: reverse ? 1 : 9, refY: 5, markerWidth: 7, markerHeight: 7,
        orient: 'auto-start-reverse', markerUnits: 'strokeWidth' }, defs);
      S.el('path', { d: 'M0,0 L10,5 L0,10 z', 'class': 'svg-arrowhead' + (cls ? ' ' + cls : '') }, m);
    }
    marker('arrowhead', '');
    marker('arrowtail', '', true);
    ['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'accent'].forEach(function (c) { marker('arrowhead-' + c, c); });
    document.body.insertBefore(svg, document.body.firstChild);
  };
  CJ.svg = S;

  /* ---------- Stepper ---------- */
  function ensurePart(root, cls, before) {
    var el = root.querySelector(':scope > .' + cls);
    if (!el) {
      el = document.createElement('div'); el.className = cls;
      if (before) root.insertBefore(el, before); else root.appendChild(el);
    }
    return el;
  }
  function btn(label, title, cls) {
    var b = document.createElement('button');
    b.type = 'button'; b.className = 'btn small' + (cls ? ' ' + cls : ''); b.textContent = label;
    if (title) { b.title = title; b.setAttribute('aria-label', title); }
    return b;
  }

  function Stepper(root, opts) {
    if (!(this instanceof Stepper)) return new Stepper(root, opts);
    root = CJ.$(root);
    if (!root) throw new Error('Stepper: root not found');
    this.opts = opts = opts || {};
    this.steps = opts.steps || [];
    this.length = this.steps.length;
    this.index = -1;
    this.timer = null;
    this.answered = {};
    this.root = root;
    this.ctx = { root: root, svg: root.querySelector('svg'), stepper: this, data: {} };
    var controls = ensurePart(root, 'controls');
    this.caption = ensurePart(root, 'stepper-caption', controls);
    this.caption.setAttribute('aria-live', 'polite');
    var self = this;
    var bFirst = btn('⏮', 'First step'), bPrev = btn('◀ Prev', 'Previous step'),
      bPlay = btn('▶ Play', 'Play', 'primary'), bNext = btn('Next ▶', 'Next step');
    var dots = document.createElement('div'); dots.className = 'stepper-dots';
    var frag = document.createDocumentFragment();
    [bFirst, bPrev, bPlay, bNext, dots].forEach(function (x) { frag.appendChild(x); });
    controls.insertBefore(frag, controls.firstChild);
    this.dots = this.steps.map(function (s, i) {
      var d = document.createElement('button'); d.type = 'button';
      d.setAttribute('aria-label', 'Step ' + (i + 1));
      d.addEventListener('click', function () { self.pause(); self.go(i); });
      dots.appendChild(d); return d;
    });
    this.b = { first: bFirst, prev: bPrev, play: bPlay, next: bNext };
    bFirst.addEventListener('click', function () { self.pause(); self.first(); });
    bPrev.addEventListener('click', function () { self.pause(); self.prev(); });
    bNext.addEventListener('click', function () { self.pause(); self.next(); });
    bPlay.addEventListener('click', function () { self.toggle(); });
    if (!root.hasAttribute('tabindex')) root.tabIndex = 0;
    root.addEventListener('keydown', function (e) {
      if (e.target.closest && e.target.closest('input, select, textarea, .predict')) return;
      if (e.key === 'ArrowRight') { e.preventDefault(); self.pause(); self.next(); }
      else if (e.key === 'ArrowLeft') { e.preventDefault(); self.pause(); self.prev(); }
      else if (e.key === ' ' && e.target === root) { e.preventDefault(); self.toggle(); }
    });
    this.go(0);
  }
  Stepper.prototype.go = function (i) {
    i = CJ.clamp(i, 0, this.length - 1);
    var step = this.steps[i];
    if (step && step.predict && !this.answered[i] && i > this.index) { this.pause(); this.ask(i); return; }
    this.clearPredict();
    if (this.opts.reset) this.opts.reset(this.ctx);
    for (var k = 0; k <= i; k++) if (this.steps[k].run) this.steps[k].run(this.ctx, k === i);
    this.index = i;
    this.caption.innerHTML = '<span class="step-count">' + (i + 1) + '/' + this.length + '</span>' + (step.caption || '');
    this.dots.forEach(function (d, k) { d.classList.toggle('on', k === i); });
    this.b.prev.disabled = this.b.first.disabled = i === 0;
    this.b.next.disabled = i === this.length - 1;
    if (this.opts.onStep) this.opts.onStep(i, this.ctx);
  };
  Stepper.prototype.next = function () {
    if (this.index < this.length - 1) this.go(this.index + 1);
    else if (this.opts.loop) this.go(0);
    else this.pause();
  };
  Stepper.prototype.prev = function () { if (this.index > 0) this.go(this.index - 1); };
  Stepper.prototype.first = function () { this.go(0); };
  Stepper.prototype.play = function () {
    var self = this;
    if (this.timer) return;
    if (this.index >= this.length - 1 && !this.opts.loop) this.go(0);
    this.b.play.textContent = '⏸ Pause'; this.b.play.title = 'Pause';
    this.timer = setInterval(function () {
      self.next();
      if (self.index >= self.length - 1 && !self.opts.loop) self.pause();
    }, this.opts.interval || 1800);
  };
  Stepper.prototype.pause = function () {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.b.play.textContent = '▶ Play'; this.b.play.title = 'Play';
  };
  Stepper.prototype.toggle = function () { if (this.timer) this.pause(); else this.play(); };
  Stepper.prototype.clearPredict = function () { if (this.predictEl) { this.predictEl.remove(); this.predictEl = null; } };
  Stepper.prototype.ask = function (i) {
    var self = this, p = this.steps[i].predict;
    this.clearPredict();
    var box = document.createElement('div');
    box.className = 'predict';
    var q = document.createElement('div'); q.className = 'predict-q'; q.innerHTML = 'Predict: ' + p.question;
    var opts = document.createElement('div'); opts.className = 'predict-opts';
    var fb = document.createElement('div'); fb.className = 'predict-fb'; fb.setAttribute('aria-live', 'polite');
    box.appendChild(q); box.appendChild(opts); box.appendChild(fb);
    (p.options || []).forEach(function (o, k) {
      var b = btn(o, null);
      b.addEventListener('click', function () {
        CJ.$$('button', opts).forEach(function (x) { x.disabled = true; });
        var ok = p.answer == null || k === p.answer;
        fb.innerHTML = (ok ? '<strong style="color:var(--tip)">Correct.</strong> ' : '<strong style="color:var(--pitfall)">Not quite.</strong> ') + (p.explain || '');
        var go = btn('Show step ▶', null, 'primary');
        go.style.marginTop = '.5rem';
        go.addEventListener('click', function () { self.answered[i] = true; self.go(i); });
        fb.appendChild(document.createElement('br')); fb.appendChild(go);
        go.focus();
      });
      opts.appendChild(b);
    });
    this.caption.parentNode.insertBefore(box, this.caption.nextSibling);
    this.predictEl = box;
  };
  CJ.Stepper = Stepper;

  /* ---------- Animator ---------- */
  function Animator(opts) {
    if (!(this instanceof Animator)) return new Animator(opts);
    this.opts = opts = opts || {};
    this.speed = opts.speed || 1;
    this.running = false;
    this.t = 0;
    this._raf = 0; this._last = null;
    var self = this;
    this._loop = function (ts) {
      if (!self.running) return;
      if (self._last === null) self._last = ts;
      var dt = Math.min((ts - self._last) / 1000, 0.1) * self.speed;
      self._last = ts;
      self.t += dt;
      try { if (opts.onFrame) opts.onFrame(dt, self.t, self); }
      catch (e) { self.pause(); throw e; }
      if (self.running) self._raf = requestAnimationFrame(self._loop);
    };
    var root = opts.root ? CJ.$(opts.root) : null;
    this.root = root;
    if (root && opts.controls !== false) {
      var controls = ensurePart(root, 'controls');
      var bPlay = btn('▶ Play', 'Play', 'primary'), bReset = btn('↺ Reset', 'Reset');
      var lab = document.createElement('label'); lab.textContent = 'Speed';
      var sel = document.createElement('select');
      (opts.speeds || [0.25, 0.5, 1, 2, 4]).forEach(function (s) {
        var o = document.createElement('option'); o.value = s; o.textContent = s + '×';
        if (s === self.speed) o.selected = true; sel.appendChild(o);
      });
      lab.appendChild(sel);
      var frag = document.createDocumentFragment();
      frag.appendChild(bPlay); frag.appendChild(bReset); frag.appendChild(lab);
      controls.insertBefore(frag, controls.firstChild);
      bPlay.addEventListener('click', function () { self.toggle(); });
      bReset.addEventListener('click', function () { self.reset(); });
      sel.addEventListener('change', function () { self.setSpeed(parseFloat(sel.value)); });
      this._bPlay = bPlay;
    }
    document.addEventListener('visibilitychange', function () {
      if (document.hidden && self.running) { self._resumeOnShow = true; self.pause(); }
      else if (!document.hidden && self._resumeOnShow) { self._resumeOnShow = false; self.play(); }
    });
    if (opts.onReset) opts.onReset(this);
    var auto = opts.autoplay && !CJ.reducedMotion();
    if (auto === 'visible' && root && 'IntersectionObserver' in window) {
      var userPaused = false;
      if (this._bPlay) this._bPlay.addEventListener('click', function () { userPaused = !self.running; });
      new IntersectionObserver(function (es) {
        es.forEach(function (e) {
          if (e.isIntersecting && !userPaused) self.play();
          else if (!e.isIntersecting) self.pause();
        });
      }, { threshold: 0.2 }).observe(root);
    } else if (auto) this.play();
  }
  Animator.prototype._label = function () {
    if (!this._bPlay) return;
    this._bPlay.textContent = this.running ? '⏸ Pause' : '▶ Play';
    this._bPlay.title = this.running ? 'Pause' : 'Play';
  };
  Animator.prototype.play = function () {
    if (this.running) return;
    this.running = true; this._last = null;
    this._raf = requestAnimationFrame(this._loop);
    this._label();
  };
  Animator.prototype.pause = function () {
    this.running = false; cancelAnimationFrame(this._raf); this._label();
  };
  Animator.prototype.toggle = function () { if (this.running) this.pause(); else this.play(); };
  Animator.prototype.reset = function () {
    this.t = 0; this._last = null;
    if (this.opts.onReset) this.opts.onReset(this);
    if (!this.running && this.opts.onFrame) this.opts.onFrame(0, 0, this);
  };
  Animator.prototype.setSpeed = function (s) { this.speed = s > 0 ? s : 1; };
  CJ.Animator = Animator;

  /* ---------- Quiz ---------- */
  function wireQuiz(quiz) {
    if (quiz._cj) return; quiz._cj = true;
    var qs = CJ.$$('.q', quiz);
    var head = quiz.querySelector('.quiz-head');
    var score = quiz.querySelector('.quiz-score');
    if (head && !score) { score = document.createElement('span'); score.className = 'quiz-score'; head.appendChild(score); }
    var right = 0, done = 0;
    function upd() { if (score) score.textContent = right + ' / ' + qs.length + (done === qs.length ? ' — done' : ''); }
    qs.forEach(function (q) {
      var ans = parseInt(q.getAttribute('data-answer'), 10);
      var opts = CJ.$$('.q-opt', q);
      var ex = q.querySelector('.q-explain');
      if (!ex) { ex = document.createElement('div'); ex.className = 'q-explain'; q.appendChild(ex); }
      ex.setAttribute('aria-live', 'polite');
      var explainHtml = q.getAttribute('data-explain') || ex.innerHTML;
      ex.innerHTML = ''; ex.hidden = true;
      opts.forEach(function (o, k) {
        o.type = 'button';
        o.addEventListener('click', function () {
          opts.forEach(function (x) { x.disabled = true; });
          opts[ans] && opts[ans].classList.add('correct');
          if (k !== ans) o.classList.add('wrong'); else right++;
          done++;
          ex.hidden = false;
          ex.innerHTML = (k === ans ? '<strong style="color:var(--tip)">Correct.</strong> ' : '<strong style="color:var(--pitfall)">Not quite.</strong> ') + explainHtml;
          upd();
        });
      });
    });
    var reset = quiz.querySelector('.quiz-reset');
    if (reset) reset.addEventListener('click', function () {
      right = 0; done = 0;
      qs.forEach(function (q) {
        CJ.$$('.q-opt', q).forEach(function (o) { o.disabled = false; o.classList.remove('correct', 'wrong'); });
        var ex = q.querySelector('.q-explain'); if (ex) ex.hidden = true;
      });
      upd();
    });
    upd();
  }
  CJ.quiz = function (el, questions, title) {
    el = CJ.$(el);
    el.classList.add('quiz');
    el.innerHTML = '<div class="quiz-head">' + (title || 'Check your understanding') + '<span class="quiz-score"></span></div>';
    questions.forEach(function (q) {
      var d = document.createElement('div');
      d.className = 'q'; d.setAttribute('data-answer', q.answer);
      d.setAttribute('data-explain', q.explain || '');
      var t = document.createElement('div'); t.className = 'q-text'; t.innerHTML = q.q; d.appendChild(t);
      var os = document.createElement('div'); os.className = 'q-opts';
      q.options.forEach(function (o) {
        var b = document.createElement('button'); b.className = 'q-opt'; b.innerHTML = o; os.appendChild(b);
      });
      d.appendChild(os); el.appendChild(d);
    });
    wireQuiz(el);
    return el;
  };

  /* ---------- range binding ---------- */
  CJ.bindRange = function (input, output, fmt, onInput) {
    input = CJ.$(input); output = CJ.$(output);
    function upd() {
      var v = parseFloat(input.value);
      if (output) output.textContent = fmt ? fmt(v) : String(v);
      if (onInput) onInput(v);
    }
    input.addEventListener('input', upd);
    upd();
    return upd;
  };

  /* ---------- page chrome: TOC, progress, figures ---------- */
  function initToc() {
    var side = document.querySelector('.sidebar[data-auto-toc]');
    var main = document.querySelector('main') || document.body;
    if (side && !side._cj) {
      side._cj = true;
      var list = side.querySelector('ol, ul');
      if (!list) {
        var t = document.createElement('div'); t.className = 'toc-title'; t.textContent = 'On this page';
        side.appendChild(t);
        list = document.createElement('ol'); side.appendChild(list);
      }
      var curLi = null;
      CJ.$$('h2[id], h3[id]', main).forEach(function (h) {
        var a = document.createElement('a');
        a.href = '#' + h.id;
        var clone = h.cloneNode(true);
        CJ.$$('.anchor', clone).forEach(function (n) { n.remove(); });
        a.textContent = clone.textContent.trim();
        var li = document.createElement('li'); li.appendChild(a);
        if (h.tagName === 'H3' && curLi) {
          var sub = curLi.querySelector('ol');
          if (!sub) { sub = document.createElement('ol'); curLi.appendChild(sub); }
          sub.appendChild(li);
        } else { list.appendChild(li); curLi = li; }
      });
    }
    // add hover anchors to headings
    CJ.$$('h2[id], h3[id]', main).forEach(function (h) {
      if (h.querySelector('.anchor')) return;
      var a = document.createElement('a'); a.className = 'anchor'; a.href = '#' + h.id; a.textContent = '#';
      a.setAttribute('aria-label', 'Link to this section');
      h.appendChild(a);
    });
    // scroll spy
    var links = CJ.$$('.sidebar a[href^="#"]');
    if (links.length && 'IntersectionObserver' in window) {
      var map = {};
      links.forEach(function (a) { map[decodeURIComponent(a.getAttribute('href').slice(1))] = a; });
      var visible = {};
      var io = new IntersectionObserver(function (es) {
        es.forEach(function (e) { visible[e.target.id] = e.isIntersecting; });
        var first = CJ.$$('h2[id], h3[id]', main).filter(function (h) { return visible[h.id]; })[0];
        if (first && map[first.id]) {
          links.forEach(function (a) { a.classList.remove('active'); });
          map[first.id].classList.add('active');
        }
      }, { rootMargin: '-56px 0px -60% 0px' });
      CJ.$$('h2[id], h3[id]', main).forEach(function (h) { io.observe(h); });
    }
    CJ.$$('.toc-toggle').forEach(function (b) {
      if (b._cj) return; b._cj = true;
      b.addEventListener('click', function () { document.body.classList.toggle('toc-open'); });
    });
    CJ.$$('.sidebar a').forEach(function (a) {
      a.addEventListener('click', function () { document.body.classList.remove('toc-open'); });
    });
  }
  function initProgress() {
    var bar = document.querySelector('.progress-bar');
    if (!bar) return;
    function upd() {
      var h = document.documentElement.scrollHeight - window.innerHeight;
      bar.style.width = (h > 0 ? CJ.clamp(window.scrollY / h, 0, 1) * 100 : 0) + '%';
    }
    window.addEventListener('scroll', upd, { passive: true });
    window.addEventListener('resize', upd);
    upd();
  }
  function initFigures() {
    var n = 0;
    CJ.$$('figcaption .fig-num').forEach(function (s) {
      n++;
      if (!s.textContent.trim()) s.textContent = 'Figure ' + n + '.';
    });
  }

  function init() {
    try {
      S.ensureDefs();
      initThemeToggle();
      CJ.highlightAll();
      CJ.addCopyButtons();
      CJ.initTabs();
      CJ.$$('.quiz[data-quiz]').forEach(wireQuiz);
      initToc();
      initProgress();
      initFigures();
    } catch (e) { console.error('course.js init failed:', e); }
    isReady = true;
    readyQueue.splice(0).forEach(function (fn) {
      try { fn(); } catch (e) { console.error(e); }
    });
  }
  window.CourseJS = CJ;
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();

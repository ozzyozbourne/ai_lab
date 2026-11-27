/* =====================================================================
   MuJoCo Warp course - shared behaviour (assets/course.js)
   Vanilla JS, no framework. Load at the end of <body> (or with defer),
   AFTER highlight.js:  <script defer src="../assets/course.js"></script>
   Public API on window.MW (see STYLE_GUIDE.md section 6):
     MW.stepper(el, frames, opts)      algorithm stepper (Rule A)
     MW.canvasAnim(canvas, draw, opts) requestAnimationFrame loop with DPR + pause
     MW.anim(container)                play/pause controller for CSS animations
     MW.worldGrid(el, n, opts)         per-world tile grid (A.9)
     MW.poolBar(el, opts)              contact pool bar (A.2)
     MW.efcStrip(el, opts)             efc row strip (A.3)
     MW.replay(el, data, opts)         world replay player (A.7)
     MW.mini3d(canvas, scene, opts)    tiny 3-D renderer (A.8)
     MW.breadcrumb(el, here)           pipeline breadcrumb (A.1)
     MW.css(name)                      resolve a CSS custom property to a colour
     MW.worldColor(k)                  colour of world k
     MW.reducedMotion                  true when the reader asked for less motion
   ===================================================================== */
(function () {
  "use strict";
  var doc = document, root = doc.documentElement;
  root.classList.remove("no-js");
  var MW = window.MW = window.MW || {};
  var mq = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : { matches: false };
  MW.reducedMotion = !!mq.matches;

  function $(sel, el) { return (el || doc).querySelector(sel); }
  function $$(sel, el) { return Array.prototype.slice.call((el || doc).querySelectorAll(sel)); }
  function store(key, val) {
    try {
      if (val === undefined) return window.localStorage.getItem(key);
      if (val === null) window.localStorage.removeItem(key); else window.localStorage.setItem(key, val);
    } catch (e) { return null; }
    return null;
  }
  function svgEl(tag, attrs, parent) {
    var e = doc.createElementNS("http://www.w3.org/2000/svg", tag);
    for (var k in attrs) if (attrs[k] !== undefined && attrs[k] !== null) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }
  function readJSON(idOrEl) {
    var el = typeof idOrEl === "string" ? doc.getElementById(idOrEl) : idOrEl;
    if (!el) return null;
    try { return JSON.parse(el.textContent); } catch (e) { console.warn("MW: bad JSON in", el.id, e); return null; }
  }
  MW.$ = $; MW.$$ = $$; MW.svgEl = svgEl; MW.readJSON = readJSON; MW.store = store;

  MW.css = function (name, el) {
    var v = getComputedStyle(el || root).getPropertyValue(name).trim();
    return v || "#888";
  };
  MW.worldColor = function (k) { return MW.css("--world-" + (((k % 8) + 8) % 8)); };
  function resolveColor(c, el) {
    if (typeof c === "string" && c.indexOf("var(") === 0) return MW.css(c.slice(4, -1).split(",")[0].trim(), el);
    return c;
  }
  MW.resolveColor = resolveColor;
  var themeListeners = [];
  MW.onTheme = function (fn) { themeListeners.push(fn); };
  function fireTheme() { themeListeners.forEach(function (fn) { try { fn(); } catch (e) { console.error(e); } }); }
  if (window.matchMedia) {
    var dmq = window.matchMedia("(prefers-color-scheme: dark)");
    if (dmq.addEventListener) dmq.addEventListener("change", fireTheme);
  }

  /* ---------- theme toggle ---------- */
  function effectiveTheme() {
    var t = root.getAttribute("data-theme");
    if (t === "light" || t === "dark") return t;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }
  function initTheme() {
    var saved = store("mwc-theme");
    if (saved === "light" || saved === "dark") root.setAttribute("data-theme", saved);
    $$(".theme-toggle").forEach(function (b) {
      b.setAttribute("aria-label", "Toggle dark mode");
      b.addEventListener("click", function () {
        var next = effectiveTheme() === "dark" ? "light" : "dark";
        root.setAttribute("data-theme", next);
        store("mwc-theme", next);
        fireTheme();
      });
    });
  }

  /* ---------- reading progress + scrollspy TOC ---------- */
  function initProgress() {
    var bar = $(".progress-bar");
    if (!bar) { bar = doc.createElement("div"); bar.className = "progress-bar"; doc.body.prepend(bar); }
    var ticking = false;
    function update() {
      var h = doc.documentElement.scrollHeight - window.innerHeight;
      var p = h > 0 ? Math.min(1, Math.max(0, window.scrollY / h)) : 0;
      bar.style.transform = "scaleX(" + p + ")";
      var tp = $(".toc-progress");
      if (tp) tp.textContent = Math.round(p * 100) + "% read";
      ticking = false;
    }
    window.addEventListener("scroll", function () { if (!ticking) { ticking = true; requestAnimationFrame(update); } }, { passive: true });
    window.addEventListener("resize", update);
    update();
  }
  function initToc() {
    var toc = $(".toc");
    if (!toc) return;
    // headings without an id borrow the id of their <section> (our pages put ids on sections)
    $$(".content section[id] > h2:not([id]), .content section[id] > h3:not([id])").forEach(function (h) {
      var sec = h.parentNode; var sid = sec.id; sec.removeAttribute("id"); sec.setAttribute("data-sec", sid); h.id = sid;
    });
    var list = $("ol[data-auto]", toc);
    var heads = $$(".content h2[id]" + (list && list.getAttribute("data-auto") === "h3" ? ", .content h3[id]" : ""));
    if (list && !list.children.length) {
      var cur = null;
      heads.forEach(function (h) {
        var li = doc.createElement("li"), a = doc.createElement("a");
        a.href = "#" + h.id;
        var num = $(".sec-num", h), c = h.cloneNode(true);
        $$(".sec-num, .anchor", c).forEach(function (x) { x.parentNode.removeChild(x); });
        a.textContent = (num ? num.textContent.trim() + ". " : "") + (h.getAttribute("data-toc") || c.textContent.trim());
        li.appendChild(a);
        if (h.tagName === "H3" && cur) {
          var sub = $("ol", cur) || cur.appendChild(doc.createElement("ol"));
          sub.appendChild(li);
        } else { list.appendChild(li); cur = li; }
      });
    }
    var links = $$("a[href^='#']", toc);
    var byId = {};
    links.forEach(function (a) { byId[decodeURIComponent(a.getAttribute("href").slice(1))] = a; });
    var targets = links.map(function (a) { return doc.getElementById(decodeURIComponent(a.getAttribute("href").slice(1))); }).filter(Boolean);
    function spy() {
      var y = window.scrollY + (parseInt(getComputedStyle(root).scrollPaddingTop, 10) || 80) + 10;
      var active = null;
      targets.forEach(function (t) { if (t.getBoundingClientRect().top + window.scrollY <= y) active = t; });
      links.forEach(function (a) { a.classList.remove("active"); a.removeAttribute("aria-current"); });
      if (active && byId[active.id]) { byId[active.id].classList.add("active"); byId[active.id].setAttribute("aria-current", "true"); }
    }
    var t = false;
    window.addEventListener("scroll", function () { if (!t) { t = true; requestAnimationFrame(function () { spy(); t = false; }); } }, { passive: true });
    spy();
    var btn = $(".toc-toggle");
    if (btn) {
      btn.setAttribute("aria-expanded", "false");
      btn.addEventListener("click", function () {
        var open = doc.body.classList.toggle("toc-open");
        btn.setAttribute("aria-expanded", open ? "true" : "false");
      });
      toc.addEventListener("click", function (e) { if (e.target.closest("a")) { doc.body.classList.remove("toc-open"); btn.setAttribute("aria-expanded", "false"); } });
      doc.addEventListener("keydown", function (e) { if (e.key === "Escape") doc.body.classList.remove("toc-open"); });
      doc.addEventListener("click", function (e) {
        if (doc.body.classList.contains("toc-open") && !e.target.closest(".toc") && !e.target.closest(".toc-toggle")) doc.body.classList.remove("toc-open");
      });
    }
  }
  function initAnchors() {
    $$(".content h2[id], .content h3[id]").forEach(function (h) {
      if ($(".anchor", h)) return;
      var a = doc.createElement("a"); a.className = "anchor"; a.href = "#" + h.id; a.textContent = "#";
      a.setAttribute("aria-label", "Link to this section"); h.appendChild(a);
    });
  }

  /* ---------- code: highlight, copy ---------- */
  var COPY_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>';
  function highlight() {
    if (!window.hljs) return;
    $$("pre code[class*='language-']").forEach(function (c) {
      if (c.dataset.highlighted || c.closest(".stepper-code")) return;
      try { window.hljs.highlightElement(c); } catch (e) { /* keep plain text */ }
    });
  }
  function copyText(text, btn) {
    function ok() {
      var old = btn.innerHTML; btn.classList.add("copied"); btn.innerHTML = COPY_SVG + "Copied";
      setTimeout(function () { btn.classList.remove("copied"); btn.innerHTML = old; }, 1500);
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(ok, function () { fallback(); });
    } else fallback();
    function fallback() {
      var ta = doc.createElement("textarea"); ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
      doc.body.appendChild(ta); ta.select();
      try { doc.execCommand("copy"); ok(); } catch (e) { btn.textContent = "Select + Ctrl-C"; }
      doc.body.removeChild(ta);
    }
  }
  function initCopy() {
    $$(".code-example, .code-block").forEach(function (box) {
      var pre = $$("pre", box).filter(function (p) { return !p.classList.contains("output"); })[0];
      if (!pre) return;
      var btn = $(".copy-btn", box);
      if (!btn) {
        btn = doc.createElement("button"); btn.type = "button"; btn.className = "copy-btn";
        btn.innerHTML = COPY_SVG + "Copy";
        var head = $(".code-head", box);
        if (head) head.appendChild(btn); else box.insertBefore(btn, box.firstChild);
      }
      btn.setAttribute("aria-label", "Copy code to clipboard");
      btn.addEventListener("click", function () { copyText(pre.innerText.replace(/\n$/, ""), btn); });
    });
  }
  function initMath() {
    if (!window.katex) return;
    $$(".math, .math-block").forEach(function (el) {
      if (el.dataset.rendered) return;
      try {
        window.katex.render(el.textContent, el, { displayMode: el.classList.contains("math-block"), throwOnError: false });
        el.dataset.rendered = "1";
      } catch (e) { /* leave TeX source visible */ }
    });
  }

  /* ---------- tabs ---------- */
  var uid = 0;
  function initTabs() {
    $$(".tabs").forEach(function (tabs) {
      var list = $(".tab-list", tabs);
      var btns = $$("[role='tab'], .tab-list > button", tabs).filter(function (b) { return b.parentNode === list; });
      var panels = $$(".tab-panel", tabs).filter(function (p) { return p.parentNode === tabs; });
      if (!list || !btns.length) return;
      list.setAttribute("role", "tablist");
      var group = tabs.getAttribute("data-group");
      btns.forEach(function (b, i) {
        var id = "mwtab" + (++uid);
        b.setAttribute("role", "tab"); b.id = b.id || id; b.type = "button";
        if (panels[i]) { panels[i].setAttribute("role", "tabpanel"); panels[i].setAttribute("aria-labelledby", b.id); panels[i].id = panels[i].id || id + "p"; b.setAttribute("aria-controls", panels[i].id); }
        b.addEventListener("click", function () { select(i, true); });
        b.addEventListener("keydown", function (e) {
          var n = btns.length, j = -1;
          if (e.key === "ArrowRight") j = (i + 1) % n; else if (e.key === "ArrowLeft") j = (i - 1 + n) % n;
          else if (e.key === "Home") j = 0; else if (e.key === "End") j = n - 1;
          if (j >= 0) { e.preventDefault(); select(j, true); btns[j].focus(); }
        });
      });
      function select(i, user) {
        btns.forEach(function (b, k) { b.setAttribute("aria-selected", k === i ? "true" : "false"); b.tabIndex = k === i ? 0 : -1; });
        panels.forEach(function (p, k) { p.hidden = k !== i; });
        if (user && group) {
          var label = btns[i].textContent.trim(); store("mwc-tab-" + group, label);
          $$(".tabs[data-group='" + group + "']").forEach(function (o) { if (o !== tabs && o._mwSelectByLabel) o._mwSelectByLabel(label); });
        }
      }
      tabs._mwSelectByLabel = function (label) { btns.forEach(function (b, k) { if (b.textContent.trim() === label) select(k, false); }); };
      var start = Math.max(0, btns.findIndex(function (b) { return b.getAttribute("aria-selected") === "true"; }));
      select(start, false);
      if (group && store("mwc-tab-" + group)) tabs._mwSelectByLabel(store("mwc-tab-" + group));
    });
  }

  /* ---------- quiz ---------- */
  function initQuiz() {
    $$(".quiz").forEach(function (quiz) {
      var qs = $$(".quiz-q", quiz);
      var score = $(".quiz-score", quiz);
      function updateScore() {
        if (!score) return;
        var done = qs.filter(function (q) { return q.classList.contains("answered"); });
        var right = qs.filter(function (q) { return q.classList.contains("is-right"); }).length;
        score.textContent = right + " / " + qs.length + " correct" + (done.length < qs.length ? " (" + (qs.length - done.length) + " left)" : "");
      }
      qs.forEach(function (q, qi) {
        var p = $(".q", q); if (p && !p.getAttribute("data-n")) p.setAttribute("data-n", "Q" + (qi + 1));
        var ans = (q.getAttribute("data-answer") || "").toLowerCase();
        var fb = $(".quiz-feedback", q);
        if (fb) fb.setAttribute("aria-live", "polite");
        $$(".choices button", q).forEach(function (b, i) {
          var key = (b.getAttribute("data-key") || String.fromCharCode(97 + i)).toLowerCase();
          b.setAttribute("data-key", key); b.type = "button";
          if (!$(".key", b)) { var k = doc.createElement("span"); k.className = "key"; k.textContent = key.toUpperCase(); b.insertBefore(k, b.firstChild); }
          b.addEventListener("click", function () {
            if (q.classList.contains("answered")) return;
            var right = key === ans;
            q.classList.add("answered", right ? "is-right" : "is-wrong");
            $$(".choices button", q).forEach(function (o) {
              o.disabled = true;
              if (o.getAttribute("data-key") === ans) o.classList.add("correct");
            });
            if (!right) b.classList.add("wrong");
            if (fb) {
              var why = b.getAttribute("data-explain");
              var head = right ? "Correct. " : "Not quite. ";
              if (!fb.dataset.base) fb.dataset.base = fb.innerHTML;
              fb.innerHTML = "<strong>" + head + "</strong>" + (why ? why + " " : "") + fb.dataset.base;
            }
            updateScore();
          });
        });
      });
      $$(".quiz-reset", quiz).forEach(function (r) {
        r.addEventListener("click", function () {
          qs.forEach(function (q) {
            q.classList.remove("answered", "is-right", "is-wrong");
            var fb = $(".quiz-feedback", q); if (fb && fb.dataset.base !== undefined) fb.innerHTML = fb.dataset.base;
            $$(".choices button", q).forEach(function (o) { o.disabled = false; o.classList.remove("correct", "wrong"); });
          });
          updateScore();
        });
      });
      updateScore();
    });
  }

  /* ---------- glossary taps ---------- */
  function initGlossary() {
    var pop = null;
    function close() { if (pop) { pop.remove(); pop = null; } }
    $$("abbr.gl").forEach(function (a) {
      a.tabIndex = 0;
      a.setAttribute("role", "button");
      function open(e) {
        e.preventDefault(); e.stopPropagation();
        var same = pop && pop._for === a; close(); if (same) return;
        pop = doc.createElement("div"); pop.className = "gl-pop"; pop._for = a; pop.setAttribute("role", "tooltip");
        var term = a.getAttribute("data-term") || a.textContent.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-");
        var href = a.getAttribute("data-href") || "../reference/glossary.html#" + term;
        pop.innerHTML = "<strong></strong> <span></span><br><a>Glossary entry</a>";
        pop.querySelector("strong").textContent = a.textContent.trim() + ":";
        pop.querySelector("span").textContent = a.getAttribute("title") || "";
        pop.querySelector("a").href = href;
        doc.body.appendChild(pop);
        var r = a.getBoundingClientRect();
        var left = Math.min(window.scrollX + r.left, window.scrollX + doc.documentElement.clientWidth - pop.offsetWidth - 16);
        pop.style.left = Math.max(16, left) + "px";
        pop.style.top = (window.scrollY + r.bottom + 6) + "px";
      }
      a.addEventListener("click", open);
      a.addEventListener("keydown", function (e) { if (e.key === "Enter" || e.key === " ") open(e); });
    });
    doc.addEventListener("click", function (e) { if (pop && !e.target.closest(".gl-pop")) close(); });
    doc.addEventListener("keydown", function (e) { if (e.key === "Escape") close(); });
  }

  /* ---------- hot regions in figures (Rule I: hover + tap + keyboard -> caption line) ---------- */
  function initHot() {
    $$(".fig, .widget").forEach(function (fig) {
      var hots = $$(".hot[data-info]", fig);
      if (!hots.length) return;
      var line = $(".fig-caption-line", fig);
      if (!line) { line = doc.createElement("div"); line.className = "fig-caption-line"; line.setAttribute("data-placeholder", "Hover, tap or tab to a part of the figure."); (fig.querySelector("figcaption") || fig).insertAdjacentElement(fig.querySelector("figcaption") ? "beforebegin" : "beforeend", line); }
      line.setAttribute("aria-live", "polite");
      var pinned = null;
      function show(h) { line.innerHTML = h ? h.getAttribute("data-info") : ""; }
      hots.forEach(function (h, i) {
        h.setAttribute("tabindex", "0");
        if (!h.getAttribute("role")) h.setAttribute("role", "button");
        if (!h.getAttribute("aria-label") && h.getAttribute("data-label")) h.setAttribute("aria-label", h.getAttribute("data-label"));
        h.addEventListener("mouseenter", function () { if (!pinned) show(h); });
        h.addEventListener("mouseleave", function () { show(pinned); });
        h.addEventListener("focus", function () { show(h); });
        h.addEventListener("blur", function () { show(pinned); });
        h.addEventListener("click", function () {
          if (pinned === h) { h.classList.remove("pinned"); pinned = null; fig.classList.remove("dim-others"); }
          else { if (pinned) pinned.classList.remove("pinned"); pinned = h; h.classList.add("pinned"); fig.classList.add("dim-others"); }
          show(pinned || h);
        });
        h.addEventListener("keydown", function (e) {
          var j = -1;
          if (e.key === "ArrowRight" || e.key === "ArrowDown") j = (i + 1) % hots.length;
          if (e.key === "ArrowLeft" || e.key === "ArrowUp") j = (i - 1 + hots.length) % hots.length;
          if (e.key === "Enter" || e.key === " ") { e.preventDefault(); h.dispatchEvent(new MouseEvent("click")); }
          if (j >= 0) {
            e.preventDefault();
            // skip hot regions that are not displayed (e.g. the wide SVG while a narrow variant is shown)
            var back = e.key === "ArrowLeft" || e.key === "ArrowUp";
            for (var k = 0; k < hots.length && !hots[j].getClientRects().length; k++) j = (j + (back ? hots.length - 1 : 1)) % hots.length;
            hots[j].focus();
          }
        });
      });
    });
  }

  /* ---------- CSS animation controller ---------- */
  var PLAY_ICONS = '<svg class="i-pause" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><rect x="6" y="5" width="4" height="14" rx="1"/><rect x="14" y="5" width="4" height="14" rx="1"/></svg>' +
    '<svg class="i-play" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M7 5v14l12-7z"/></svg>';
  MW.anim = function (container) {
    var btn = $(".anim-toggle", container);
    var ctl = {
      playing: !MW.reducedMotion,
      set: function (on) {
        ctl.playing = on;
        container.classList.toggle("is-paused", !on);
        if (MW.reducedMotion) container.classList.toggle("reduced-play", on);
        if (btn) { btn.setAttribute("aria-pressed", on ? "true" : "false"); btn.setAttribute("aria-label", on ? "Pause animation" : "Play animation"); var l = $(".lbl", btn); if (l) l.textContent = on ? "Pause" : "Play"; }
        if (container._mwOnToggle) container._mwOnToggle(on);
      },
      toggle: function () { ctl.set(!ctl.playing); }
    };
    if (btn) {
      if (!btn.innerHTML.trim()) btn.innerHTML = PLAY_ICONS + '<span class="lbl">Pause</span>';
      btn.type = "button";
      btn.addEventListener("click", ctl.toggle);
    }
    container._mwAnim = ctl;
    ctl.set(ctl.playing);
    return ctl;
  };
  function initAnims() {
    $$("[data-anim]").forEach(function (c) { if (!c._mwAnim) MW.anim(c); });
  }
  function initReveal() {
    var els = $$(".reveal");
    if (!els.length) return;
    if (!("IntersectionObserver" in window)) { els.forEach(function (e) { e.classList.add("in"); }); return; }
    var io = new IntersectionObserver(function (ents) {
      ents.forEach(function (en) { if (en.isIntersecting) { en.target.classList.add("in"); io.unobserve(en.target); } });
    }, { rootMargin: "0px 0px -10% 0px" });
    els.forEach(function (e) { io.observe(e); });
  }

  /* ---------- canvas animation helper ---------- */
  // draw(ctx, state) where state = {t, dt, w, h, frame, dpr}. Returns a controller.
  // opts: {autoplay: true, staticT: 0, toggle: button element or selector, height: css px, aspect: w/h}
  MW.canvasAnim = function (canvas, draw, opts) {
    opts = opts || {};
    var ctx = canvas.getContext("2d");
    var st = { t: opts.staticT || 0, dt: 0, w: 0, h: 0, frame: 0, dpr: 1 };
    var raf = 0, last = 0, visible = true, playing = false;
    function resize() {
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.style.width = "100%"; canvas.style.display = "block";
      var w = canvas.getBoundingClientRect().width || canvas.parentNode.clientWidth || 300;
      var h = opts.aspect ? w / opts.aspect : (opts.height || canvas.clientHeight || 200);
      canvas.style.height = h + "px";
      canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
      st.w = w; st.h = h; st.dpr = dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      render();
    }
    function render() { ctx.clearRect(0, 0, st.w, st.h); draw(ctx, st); }
    function loop(ts) {
      if (!playing || !visible) { raf = 0; return; }
      st.dt = last ? Math.min(0.05, (ts - last) / 1000) : 0; last = ts;
      st.t += st.dt; st.frame++;
      render();
      raf = requestAnimationFrame(loop);
    }
    function kick() { if (playing && visible && !raf) { last = 0; raf = requestAnimationFrame(loop); } }
    var ctl = {
      state: st,
      play: function () { playing = true; sync(); kick(); },
      pause: function () { playing = false; sync(); },
      toggle: function () { playing ? ctl.pause() : ctl.play(); },
      reset: function () { st.t = opts.staticT || 0; st.frame = 0; render(); },
      redraw: render,
      resize: resize,
      get playing() { return playing; }
    };
    var btn = typeof opts.toggle === "string" ? $(opts.toggle) : opts.toggle;
    if (!btn) { var fig = canvas.closest(".fig, .widget"); btn = fig && $(".anim-toggle", fig); }
    function sync() {
      if (!btn) return;
      btn.setAttribute("aria-pressed", playing ? "true" : "false");
      btn.setAttribute("aria-label", playing ? "Pause animation" : "Play animation");
      var l = $(".lbl", btn); if (l) l.textContent = playing ? "Pause" : "Play";
    }
    if (btn) { if (!btn.innerHTML.trim()) btn.innerHTML = PLAY_ICONS + '<span class="lbl">Pause</span>'; btn.type = "button"; btn.addEventListener("click", ctl.toggle); }
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (e) { visible = e[0].isIntersecting; kick(); }).observe(canvas);
    }
    if ("ResizeObserver" in window) {
      var lastW = 0;
      new ResizeObserver(function () { var w = canvas.clientWidth; if (Math.abs(w - lastW) > 1) { lastW = w; resize(); } }).observe(canvas.parentNode);
    } else window.addEventListener("resize", resize);
    MW.onTheme(render);
    resize();
    if (opts.autoplay !== false && !MW.reducedMotion) ctl.play(); else sync();
    return ctl;
  };

  /* ---------- stepper (A.5) ---------- */
  // Markup: see chapters/_template.html. frames = [{line: 3, vars: {k: v}, caption: "html", show: "0,2-4"}...]
  // Declarative: elements inside .stepper-fig with data-steps="0,2-4" are shown only on those frames,
  // and data-active="1,3" gets class "step-active" on those frames.
  function parseSteps(s) {
    var out = {};
    String(s).split(",").forEach(function (part) {
      part = part.trim(); if (!part) return;
      var m = part.split("-");
      var a = parseInt(m[0], 10), b = m.length > 1 ? (m[1] === "" ? 9999 : parseInt(m[1], 10)) : a;
      for (var i = a; i <= Math.min(b, 9999); i++) out[i] = true;
    });
    return out;
  }
  MW.stepper = function (el, frames, opts) {
    opts = opts || {};
    if (!frames) { var js = $("script.stepper-data", el); frames = js ? readJSON(js) : []; }
    frames = frames || [];
    var n = frames.length, i = 0, timer = 0;
    var fig = $(".stepper-fig", el), code = $(".stepper-code", el), vars = $(".stepper-vars", el);
    var cap = $(".stepper-caption", el), count = $(".stepper-count", el), range = $(".stepper-controls input[type='range']", el);
    var btn = function (a) { return $("[data-act='" + a + "']", el); };
    if (code && !$(".ln", code)) {
      var src = code.textContent.replace(/^\n/, "").replace(/\s+$/, "").split("\n");
      code.textContent = "";
      src.forEach(function (l, k) { var s = doc.createElement("span"); s.className = "ln"; s.setAttribute("data-line", k + 1); s.textContent = l || " "; code.appendChild(s); });
    }
    var shows = fig ? $$("[data-steps]", fig).map(function (e) { return [e, parseSteps(e.getAttribute("data-steps"))]; }) : [];
    var acts = fig ? $$("[data-active]", fig).map(function (e) { return [e, parseSteps(e.getAttribute("data-active"))]; }) : [];
    if (range) { range.min = 0; range.max = Math.max(0, n - 1); range.step = 1; range.setAttribute("aria-label", "Scrub through steps"); }
    var prevVars = {};
    function render() {
      var f = frames[i] || {};
      shows.forEach(function (p) { p[0].style.display = p[1][i] ? "" : "none"; });
      acts.forEach(function (p) { p[0].classList.toggle("step-active", !!p[1][i]); });
      if (code) $$(".ln", code).forEach(function (l) { l.classList.toggle("cur", +l.getAttribute("data-line") === f.line); });
      if (vars && f.vars) {
        var rows = "";
        Object.keys(f.vars).forEach(function (k) {
          var v = f.vars[k], ch = i > 0 && prevVars[k] !== undefined && String(prevVars[k]) !== String(v);
          rows += "<tr><th>" + esc(k) + "</th><td" + (ch ? " class='changed'" : "") + ">" + esc(String(v)) + "</td></tr>";
        });
        vars.innerHTML = "<tbody>" + rows + "</tbody>";
      }
      prevVars = i > 0 && frames[i - 1] ? frames[i - 1].vars || {} : {};
      if (cap) cap.innerHTML = f.caption || "";
      if (count) count.textContent = (i + 1) + " / " + n;
      if (range) range.value = i;
      if (btn("prev")) btn("prev").disabled = i === 0;
      if (btn("next")) btn("next").disabled = i >= n - 1;
      if (typeof f.draw === "function") f.draw(fig, i);
      if (opts.onFrame) opts.onFrame(i, f, fig);
    }
    function esc(s) { return s.replace(/[&<>]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]; }); }
    function go(k) { i = Math.max(0, Math.min(n - 1, k)); render(); }
    function stop() { clearInterval(timer); timer = 0; setPlayLabel(false); }
    function setPlayLabel(on) { var b = btn("play"); if (b) { b.textContent = on ? "Pause" : "Play"; b.setAttribute("aria-pressed", on ? "true" : "false"); } }
    function play() {
      if (timer) { stop(); return; }
      if (i >= n - 1) go(0);
      setPlayLabel(true);
      timer = setInterval(function () { if (i >= n - 1) stop(); else go(i + 1); }, opts.interval || +el.getAttribute("data-interval") || 1100);
    }
    if (btn("prev")) btn("prev").addEventListener("click", function () { stop(); go(i - 1); });
    if (btn("next")) btn("next").addEventListener("click", function () { stop(); go(i + 1); });
    if (btn("reset")) btn("reset").addEventListener("click", function () { stop(); go(0); });
    if (btn("play")) btn("play").addEventListener("click", play);
    if (range) range.addEventListener("input", function () { stop(); go(+range.value); });
    el.tabIndex = el.tabIndex >= 0 ? el.tabIndex : 0;
    el.addEventListener("keydown", function (e) {
      if (e.target.tagName === "INPUT") return;
      if (e.key === "ArrowRight") { e.preventDefault(); stop(); go(i + 1); }
      if (e.key === "ArrowLeft") { e.preventDefault(); stop(); go(i - 1); }
    });
    render();
    var ctl = { go: go, play: play, stop: stop, get index() { return i; }, frames: frames };
    el._mwStepper = ctl;
    if (el.hasAttribute("data-autoplay") && !MW.reducedMotion) play();
    return ctl;
  };
  function initSteppers() { $$(".stepper").forEach(function (s) { if (!s._mwStepper && !s.hasAttribute("data-manual")) MW.stepper(s); }); }

  /* ---------- world grid (A.9) ---------- */
  MW.worldGrid = function (el, n, opts) {
    opts = opts || {};
    el.classList.add("world-grid");
    el.setAttribute("role", "group");
    var tiles = [], line = opts.caption || (el.closest(".fig, .widget") && $(".fig-caption-line", el.closest(".fig, .widget")));
    el.innerHTML = "";
    for (var k = 0; k < n; k++) {
      var t = doc.createElement("div");
      t.className = "world-tile world-" + (k % 8); t.tabIndex = k === 0 ? 0 : -1;
      t.setAttribute("data-state", opts.state || "running"); t.setAttribute("data-world", k);
      t.setAttribute("aria-label", "world " + k);
      el.appendChild(t); tiles.push(t);
    }
    function describe(t) {
      if (!line) return;
      var k = t.getAttribute("data-world");
      line.textContent = "world " + k + ": " + t.getAttribute("data-state") + (t.getAttribute("data-label") ? " (" + t.getAttribute("data-label") + ")" : "");
    }
    el.addEventListener("mouseover", function (e) { var t = e.target.closest(".world-tile"); if (t) describe(t); });
    el.addEventListener("focusin", function (e) { var t = e.target.closest(".world-tile"); if (t) describe(t); });
    el.addEventListener("click", function (e) {
      var t = e.target.closest(".world-tile"); if (!t) return;
      tiles.forEach(function (o) { if (o !== t) o.classList.remove("pinned"); });
      t.classList.toggle("pinned"); describe(t);
      if (opts.onSelect) opts.onSelect(+t.getAttribute("data-world"));
    });
    el.addEventListener("keydown", function (e) {
      var t = e.target.closest(".world-tile"); if (!t) return;
      var k = +t.getAttribute("data-world"), cols = Math.max(1, Math.round(el.clientWidth / (t.offsetWidth + 4))), j = -1;
      if (e.key === "ArrowRight") j = k + 1; if (e.key === "ArrowLeft") j = k - 1;
      if (e.key === "ArrowDown") j = k + cols; if (e.key === "ArrowUp") j = k - cols;
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); t.click(); }
      if (j >= 0 && j < n) { e.preventDefault(); t.tabIndex = -1; tiles[j].tabIndex = 0; tiles[j].focus(); }
    });
    var api = {
      tiles: tiles,
      setState: function (w, state, label) {
        var t = tiles[w]; if (!t) return;
        if (state === "reset") { t.setAttribute("data-state", "running"); void t.offsetWidth; }
        t.setAttribute("data-state", state);
        if (label !== undefined) { t.setAttribute("data-label", label); t.textContent = label; }
      },
      setAll: function (state, label) { for (var k = 0; k < n; k++) api.setState(k, state, label); }
    };
    el._mwGrid = api;
    return api;
  };

  /* ---------- contact pool bar (A.2) ---------- */
  // opts: {naconmax, worlds: [worldid per filled slot], overflow: number of dropped contacts, cell: 14}
  MW.poolBar = function (el, opts) {
    var cell = opts.cell || 14, cap = opts.naconmax, filled = opts.worlds || [], over = opts.overflow || 0;
    var total = cap + over;
    var avail = Math.max(cell * 8, (el.clientWidth || 600) - 4);
    var perRow = Math.max(8, Math.floor(avail / cell));
    var rows = Math.ceil(total / perRow), pad = 14;
    var W = Math.min(total, perRow) * cell, H = rows * (cell + 10) + pad;
    el.innerHTML = "";
    var svg = svgEl("svg", { viewBox: "0 -" + pad + " " + (W + 4) + " " + (H + 4), role: "img", "aria-label": opts.label || ("contact pool: " + filled.length + " of " + cap + " slots used" + (over ? ", " + over + " overflowed" : "")) }, el);
    svg.style.maxWidth = (W + 4) + "px";
    for (var s = 0; s < total; s++) {
      var r = Math.floor(s / perRow), c = s % perRow, x = c * cell, y = r * (cell + 10);
      var cls = "pool-cell ", fill = null;
      if (s < filled.length && s < cap) fill = MW.worldColor(filled[s]);
      else if (s >= cap) cls += "pool-overflow";
      else cls += "pool-empty";
      var rect = svgEl("rect", { x: x, y: y, width: cell, height: cell, rx: 2, "class": cls }, svg);
      if (fill) rect.style.fill = fill;
      if (s >= cap) { rect.setAttribute("opacity", Math.max(.2, 1 - (s - cap) / Math.max(1, over))); }
      if (s === cap) svgEl("line", { x1: x, y1: y - 4, x2: x, y2: y + cell + 4, "class": "pool-cap" }, svg);
      if (s === Math.min(filled.length, cap) && s < cap) svgEl("path", { d: "M" + (x + cell / 2) + " " + (y - 2) + " l-5 -8 h10 z", "class": "pool-ptr" }, svg);
    }
    if (filled.length >= cap && over === 0) {
      var rr = Math.floor((cap - 1) / perRow), cc = (cap - 1) % perRow;
      svgEl("line", { x1: (cc + 1) * cell, y1: rr * (cell + 10) - 4, x2: (cc + 1) * cell, y2: rr * (cell + 10) + cell + 4, "class": "pool-cap" }, svg);
    }
    return svg;
  };

  /* ---------- efc row strip (A.3) ---------- */
  // opts: {njmax, rows: [[["eq",2],["friction",1],["limit",1],["contact",4,"c3"]], ...], cell: 14}
  MW.efcStrip = function (el, opts) {
    var cell = opts.cell || 14, nj = opts.njmax, rows = opts.rows || [];
    var lab = 26, W = lab + nj * cell + 30, H = rows.length * (cell + 8);
    el.innerHTML = "";
    var svg = svgEl("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": opts.label || "efc rows per world" }, el);
    rows.forEach(function (blocks, w) {
      var y = w * (cell + 8), x = lab;
      var t = svgEl("text", { x: 0, y: y + cell - 3, "class": "s-small s-mono" }, svg); t.textContent = "w" + w;
      var used = 0;
      blocks.forEach(function (b) {
        for (var k = 0; k < b[1]; k++) {
          var over = used >= nj;
          var r = svgEl("rect", { x: x, y: y, width: cell - 1, height: cell, rx: 2, "class": over ? "pool-overflow" : "efc-" + b[0] }, svg);
          if (over) r.setAttribute("opacity", .45);
          x += cell; used++;
        }
        if (b[2]) { var tl = svgEl("text", { x: x - b[1] * cell + 2, y: y + cell - 3, "class": "s-mono", fill: "#fff", "font-size": 8 }, svg); tl.textContent = b[2]; }
      });
      for (; used < nj; used++, x += cell) svgEl("rect", { x: x, y: y, width: cell - 1, height: cell, rx: 2, "class": "pool-empty" }, svg);
    });
    svgEl("line", { x1: lab + nj * cell - .5, y1: -3, x2: lab + nj * cell - .5, y2: H - 5, "class": "pool-cap" }, svg);
    var tt = svgEl("text", { x: lab + nj * cell + 4, y: 10, "class": "s-small s-mono" }, svg); tt.textContent = "njmax";
    return svg;
  };

  /* ---------- world replay player (A.7) ---------- */
  // data: {nworld, dt, frames: [[per-world value(s)]...], kind: "pendulum2d"|"points2d"|"height"|"tiles", labels}
  // opts: {draw(ctx, frame, st) custom, grid: worldGrid api, height, cols}
  MW.replay = function (el, data, opts) {
    opts = opts || {};
    if (!data) data = readJSON(el.getAttribute("data-src"));
    if (!data || !data.frames || !data.frames.length) { el.insertAdjacentHTML("beforeend", "<p class='muted small'>Replay data missing.</p>"); return null; }
    var canvas = $("canvas", el), range = $("input[type='range']", el), tlabel = $(".replay-time", el);
    var line = $(".fig-caption-line", el), playBtn = $(".anim-toggle", el);
    var nf = data.frames.length, W = data.nworld, fi = 0, acc = 0, hi = -1;
    var fps = opts.fps || (data.dt ? Math.min(30, 1 / data.dt) : 20);
    if (range) { range.min = 0; range.max = nf - 1; range.value = 0; range.setAttribute("aria-label", "Replay time"); }
    var kind = data.kind || "points2d";
    var cols = opts.cols || (kind === "height" ? Math.min(W, 16) : Math.ceil(Math.sqrt(W)));
    function cellOf(w, st) {
      var rowsN = Math.ceil(W / cols), cw = st.w / cols, ch = st.h / rowsN;
      return { x: (w % cols) * cw, y: Math.floor(w / cols) * ch, w: cw, h: ch };
    }
    function drawFrame(ctx, st) {
      var fr = data.frames[fi];
      if (opts.draw) { opts.draw(ctx, fr, st, fi, hi); }
      else if (kind === "pendulum2d") {
        for (var w = 0; w < W; w++) {
          var c = cellOf(w, st), a = Array.isArray(fr[w]) ? fr[w][0] : fr[w];
          var cx = c.x + c.w / 2, cy = c.y + c.h * .25, L = Math.min(c.w, c.h) * .55;
          var bx = cx + L * Math.sin(a), by = cy + L * Math.cos(a);
          ctx.strokeStyle = MW.css("--border-strong"); ctx.lineWidth = Math.max(1, L / 18);
          ctx.globalAlpha = hi >= 0 && hi !== w ? .3 : 1;
          ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(bx, by); ctx.stroke();
          ctx.fillStyle = MW.worldColor(w); ctx.beginPath(); ctx.arc(bx, by, Math.max(1.5, L / 6), 0, 6.283); ctx.fill();
        }
        ctx.globalAlpha = 1;
      } else if (kind === "height") {
        var zmin = data.zmin !== undefined ? data.zmin : 0, zmax = data.zmax || 1;
        for (var w2 = 0; w2 < W; w2++) {
          var c2 = cellOf(w2, st), z = Array.isArray(fr[w2]) ? fr[w2][0] : fr[w2];
          var y = c2.y + c2.h - 4 - (z - zmin) / (zmax - zmin) * (c2.h - 8);
          ctx.globalAlpha = hi >= 0 && hi !== w2 ? .3 : 1;
          ctx.fillStyle = MW.css("--border"); ctx.fillRect(c2.x + 2, c2.y + c2.h - 3, c2.w - 4, 2);
          ctx.fillStyle = MW.worldColor(w2); ctx.beginPath(); ctx.arc(c2.x + c2.w / 2, y, Math.max(1.5, Math.min(c2.w, c2.h) / 8), 0, 6.283); ctx.fill();
        }
        ctx.globalAlpha = 1;
      } else { // points2d: fr[w] = [x, y] in data.bounds [xmin, xmax, ymin, ymax]
        var b = data.bounds || [-1, 1, -1, 1];
        for (var w3 = 0; w3 < W; w3++) {
          var p = fr[w3];
          var px = (p[0] - b[0]) / (b[1] - b[0]) * st.w, py = st.h - (p[1] - b[2]) / (b[3] - b[2]) * st.h;
          ctx.globalAlpha = hi >= 0 && hi !== w3 ? .3 : 1;
          ctx.fillStyle = MW.worldColor(w3); ctx.beginPath(); ctx.arc(px, py, w3 === hi ? 6 : 4, 0, 6.283); ctx.fill();
        }
        ctx.globalAlpha = 1;
      }
      if (opts.grid) for (var g = 0; g < W; g++) { /* grids are driven by opts.onFrame */ }
      if (opts.onFrame) opts.onFrame(fi, fr);
      if (range) range.value = fi;
      if (tlabel) tlabel.textContent = "t = " + (fi * (data.dt || 0)).toFixed(2) + " s";
    }
    var anim = MW.canvasAnim(canvas, function (ctx, st) {
      if (anim && anim.playing && st.dt) {
        acc += st.dt * fps;
        while (acc >= 1) { acc -= 1; fi = (fi + 1) % nf; }
      }
      drawFrame(ctx, st);
    }, { aspect: opts.aspect || (kind === "points2d" ? 16 / 9 : Math.min(3, Math.max(1.2, (kind === "height" ? 0.45 : 1) * cols / Math.ceil(W / cols)))), toggle: playBtn, autoplay: opts.autoplay });
    if (range) range.addEventListener("input", function () { fi = +range.value; anim.pause(); anim.redraw(); });
    function pick(e) {
      if (kind === "points2d") return;
      var r = canvas.getBoundingClientRect(), st = anim.state;
      var x = (e.clientX - r.left), y = (e.clientY - r.top);
      var rowsN = Math.ceil(W / cols), w = Math.floor(y / (st.h / rowsN)) * cols + Math.floor(x / (st.w / cols));
      return w >= 0 && w < W ? w : -1;
    }
    function say(w) { if (line) line.textContent = w >= 0 ? ((data.labels && data.labels[w]) || ("world " + w)) + ": value " + JSON.stringify(data.frames[fi][w]) : ""; }
    canvas.tabIndex = 0;
    canvas.setAttribute("role", "img");
    canvas.addEventListener("mousemove", function (e) { var w = pick(e); if (w !== undefined && hi < 0) say(w); });
    canvas.addEventListener("click", function (e) { var w = pick(e); if (w === undefined) return; hi = hi === w ? -1 : w; say(hi); anim.redraw(); });
    canvas.addEventListener("keydown", function (e) {
      if (e.key === "ArrowRight") { hi = (hi + 1) % W; } else if (e.key === "ArrowLeft") { hi = (hi - 1 + W) % W; }
      else if (e.key === " ") { e.preventDefault(); anim.toggle(); return; } else return;
      e.preventDefault(); say(hi); anim.redraw();
    });
    return { anim: anim, go: function (k) { fi = k; anim.redraw(); }, get frame() { return fi; } };
  };
  function initReplays() { $$(".replay[data-src]").forEach(function (r) { if (!r._mw) r._mw = MW.replay(r); }); }

  /* ---------- mini3d (A.8) ---------- */
  // scene: {polys: [{pts: [[x,y,z],...], fill: "var(--world-0)", stroke, alpha}], lines: [{a:[x,y,z], b:[...], color, width, dash}],
  //         points: [{p:[x,y,z], r, fill, label}], labels: [{p, text}]}  (z is up, MuJoCo convention)
  // opts: {yaw, pitch, scale, perspective: 0..1, gizmo: true, aspect, onChange}
  MW.mini3d = function (canvas, scene, opts) {
    opts = opts || {};
    var yaw = opts.yaw !== undefined ? opts.yaw : -0.7, pitch = opts.pitch !== undefined ? opts.pitch : 0.45;
    var y0 = yaw, p0 = pitch;
    function rot(v) {
      var cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
      var x1 = cy * v[0] - sy * v[1], y1 = sy * v[0] + cy * v[1], z1 = v[2];
      // camera looks along +y after yaw, tilted down by pitch: returns [screen x, depth (far = larger), screen up]
      return [x1, cp * y1 - sp * z1, sp * y1 + cp * z1];
    }
    function proj(v, st) {
      var r = rot(v), s = (opts.scale || 1) * Math.min(st.w, st.h) * 0.32;
      var persp = opts.perspective ? 1 / (1 + r[1] * 0.15 * opts.perspective) : 1;
      return [st.w / 2 + r[0] * s * persp, st.h / 2 - r[2] * s * persp, r[1]];
    }
    var light = [0.4, -0.6, 0.7];
    function shade(color, pts) {
      if (pts.length < 3) return color;
      var a = rot(pts[0]), b = rot(pts[1]), c = rot(pts[2]);
      var u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]], v = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
      var nrm = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
      var l = Math.hypot(nrm[0], nrm[1], nrm[2]) || 1;
      var d = Math.abs((nrm[0] * light[0] + nrm[1] * light[1] + nrm[2] * light[2]) / l);
      return { base: color, k: 0.6 + 0.4 * d };
    }
    function draw(ctx, st) {
      var sc = typeof scene === "function" ? scene(st) : scene;
      var items = [];
      (sc.polys || []).forEach(function (p) {
        var pr = p.pts.map(function (q) { return proj(q, st); });
        var depth = pr.reduce(function (s, q) { return s + q[2]; }, 0) / pr.length;
        items.push({ t: "p", d: depth, pr: pr, p: p });
      });
      (sc.lines || []).forEach(function (L) {
        var a = proj(L.a, st), b = proj(L.b, st);
        items.push({ t: "l", d: (a[2] + b[2]) / 2 - 0.001, a: a, b: b, L: L });
      });
      (sc.points || []).forEach(function (P) { var a = proj(P.p, st); items.push({ t: "o", d: a[2] - 0.002, a: a, P: P }); });
      items.sort(function (m, n) { return n.d - m.d; });
      items.forEach(function (it) {
        if (it.t === "p") {
          var col = resolveColor(it.p.fill || "var(--surface-3)", canvas), sh = shade(col, it.p.pts);
          ctx.beginPath(); it.pr.forEach(function (q, k) { k ? ctx.lineTo(q[0], q[1]) : ctx.moveTo(q[0], q[1]); }); ctx.closePath();
          ctx.globalAlpha = it.p.alpha !== undefined ? it.p.alpha : 1;
          ctx.fillStyle = col; ctx.fill();
          if (sh.k !== undefined) { ctx.fillStyle = "rgba(0,0,0," + (1 - sh.k) * 0.8 + ")"; ctx.fill(); }
          ctx.globalAlpha = 1;
          if (it.p.stroke !== false) { ctx.strokeStyle = resolveColor(it.p.stroke || "var(--border-strong)", canvas); ctx.lineWidth = 1; ctx.stroke(); }
        } else if (it.t === "l") {
          ctx.strokeStyle = resolveColor(it.L.color || "var(--text)", canvas); ctx.lineWidth = it.L.width || 2;
          ctx.setLineDash(it.L.dash || []); ctx.beginPath(); ctx.moveTo(it.a[0], it.a[1]); ctx.lineTo(it.b[0], it.b[1]); ctx.stroke(); ctx.setLineDash([]);
        } else {
          ctx.fillStyle = resolveColor(it.P.fill || "var(--accent)", canvas);
          ctx.beginPath(); ctx.arc(it.a[0], it.a[1], it.P.r || 4, 0, 6.283); ctx.fill();
          if (it.P.label) { ctx.fillStyle = MW.css("--text"); ctx.font = "600 12px " + MW.css("--font-sans"); ctx.fillText(it.P.label, it.a[0] + 7, it.a[1] - 6); }
        }
      });
      (sc.labels || []).forEach(function (lb) {
        var a = proj(lb.p, st); ctx.fillStyle = resolveColor(lb.color || "var(--text)", canvas);
        ctx.font = "600 12px " + MW.css("--font-sans"); ctx.fillText(lb.text, a[0] + 4, a[1] - 4);
      });
      if (opts.gizmo !== false) {
        var o = [42, st.h - 36], axes = [[[1, 0, 0], "#e15759", "x"], [[0, 1, 0], "#59a14f", "y"], [[0, 0, 1], "#4e79a7", "z"]];
        axes.forEach(function (ax) {
          var r = rot(ax[0]);
          ctx.strokeStyle = ax[1]; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(o[0], o[1]); ctx.lineTo(o[0] + r[0] * 22, o[1] - r[2] * 22); ctx.stroke();
          ctx.fillStyle = ax[1]; ctx.font = "700 11px " + MW.css("--font-mono"); ctx.fillText(ax[2], o[0] + r[0] * 28 - 3, o[1] - r[2] * 28 + 4);
        });
      }
    }
    var anim = MW.canvasAnim(canvas, draw, { aspect: opts.aspect || 16 / 10, autoplay: !!opts.animate, toggle: opts.toggle });
    var drag = null;
    canvas.classList.add("mini3d"); canvas.tabIndex = 0;
    canvas.setAttribute("aria-label", (opts.label || "3-D view") + ". Drag or use arrow keys to rotate, 0 to reset.");
    canvas.addEventListener("pointerdown", function (e) { drag = [e.clientX, e.clientY, yaw, pitch]; canvas.setPointerCapture(e.pointerId); });
    canvas.addEventListener("pointermove", function (e) {
      if (!drag) return;
      yaw = drag[2] + (e.clientX - drag[0]) * 0.01;
      pitch = Math.max(-1.5, Math.min(1.5, drag[3] + (e.clientY - drag[1]) * 0.01));
      anim.redraw(); if (opts.onChange) opts.onChange(yaw, pitch);
    });
    canvas.addEventListener("pointerup", function () { drag = null; });
    canvas.addEventListener("keydown", function (e) {
      var k = e.key;
      if (k === "ArrowLeft") yaw -= .1; else if (k === "ArrowRight") yaw += .1;
      else if (k === "ArrowUp") pitch = Math.min(1.5, pitch + .1); else if (k === "ArrowDown") pitch = Math.max(-1.5, pitch - .1);
      else if (k === "0") { yaw = y0; pitch = p0; } else return;
      e.preventDefault(); anim.redraw();
    });
    return {
      anim: anim, redraw: anim.redraw,
      setScene: function (s) { scene = s; anim.redraw(); },
      setView: function (y, p) { yaw = y; pitch = p; anim.redraw(); },
      project: function (v) { return proj(v, anim.state); }
    };
  };
  // geometry helpers for mini3d scenes
  MW.geo = {
    box: function (c, h, fill) { // centre, half-sizes -> 6 polys
      var x = c[0], y = c[1], z = c[2], a = h[0], b = h[1], d = h[2];
      var v = [[x - a, y - b, z - d], [x + a, y - b, z - d], [x + a, y + b, z - d], [x - a, y + b, z - d],
               [x - a, y - b, z + d], [x + a, y - b, z + d], [x + a, y + b, z + d], [x - a, y + b, z + d]];
      return [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 3, 7, 4]].map(function (f) {
        return { pts: f.map(function (i) { return v[i]; }), fill: fill };
      });
    },
    sphere: function (c, r, fill, n) { // lat-long quads
      n = n || 10; var out = [];
      for (var i = 0; i < n; i++) for (var j = 0; j < 2 * n; j++) {
        var t0 = Math.PI * i / n, t1 = Math.PI * (i + 1) / n, p0 = Math.PI * j / n, p1 = Math.PI * (j + 1) / n;
        var P = function (t, p) { return [c[0] + r * Math.sin(t) * Math.cos(p), c[1] + r * Math.sin(t) * Math.sin(p), c[2] + r * Math.cos(t)]; };
        out.push({ pts: [P(t0, p0), P(t0, p1), P(t1, p1), P(t1, p0)], fill: fill, stroke: false });
      }
      return out;
    },
    grid: function (size, step, z) { // floor grid lines
      var L = []; z = z || 0;
      for (var s = -size; s <= size + 1e-9; s += step) {
        L.push({ a: [s, -size, z], b: [s, size, z], color: "var(--border)", width: 1 });
        L.push({ a: [-size, s, z], b: [size, s, z], color: "var(--border)", width: 1 });
      }
      return L;
    }
  };

  /* ---------- pipeline breadcrumb (A.1) ---------- */
  var STATIONS = [
    ["st-sleep", "sleep", "sleep.wake / update_sleep (only with sleep, Ch 21)", "ghost", "21-islands-and-sleep"],
    ["st-kinematics", "kinematics", "kinematics, com_pos, camlight, flex, tendon", "", "11-equations-of-motion-kinematics-mass-matrix"],
    ["st-crb", "crb", "crb, tendon_armature; factor_m only with fwd_position(factorize=True)", "", "11-equations-of-motion-kinematics-mass-matrix"],
    ["st-collision", "collision", "broadphase + narrowphase -> d.contact", "", "15-geometry-toolkit-and-broadphase"],
    ["st-make_constraint", "constraint", "make_constraint -> efc rows", "", "19-constraints-as-optimization"],
    ["st-island", "island", "island.island (only with sleep)", "ghost", "21-islands-and-sleep"],
    ["st-transmission", "transmission", "actuator moments / lengths", "", "12-forces-actuators-tendons"],
    ["tap:sensor_pos", "pos", "sensor_pos", "tap", "14-sensors-delays-inverse-dynamics"],
    ["st-velocity", "velocity", "com_vel, passive, rne, tendon_bias", "", "12-forces-actuators-tendons"],
    ["tap:sensor_vel", "vel", "sensor_vel", "tap", "14-sensors-delays-inverse-dynamics"],
    ["cb:control", "ctrl cb", "control callback socket", "tap", "08-resets-state-and-control"],
    ["st-actuation", "actuation", "fwd_actuation", "", "12-forces-actuators-tendons"],
    ["st-acceleration", "accel", "qfrc_smooth + factor_solve_i (factor happens here inside _forward)", "", "11-equations-of-motion-kinematics-mass-matrix"],
    ["st-solve", "solve", "constraint solver (CG / Newton)", "", "20-solvers-cg-newton"],
    ["st-rne_post", "rne_post", "rne_postconstraint (when requested)", "", "14-sensors-delays-inverse-dynamics"],
    ["tap:sensor_acc", "acc", "sensor_acc", "tap", "14-sensors-delays-inverse-dynamics"],
    ["st-integrate", "integrate", "_advance / integrator", "", "13-integrators"]
  ];
  MW.STATIONS = STATIONS;
  MW.breadcrumb = function (el, here) {
    var hs = {}; String(here || "").split(/[\s,]+/).forEach(function (h) { if (h) hs[h] = true; });
    var showSleep = !!hs["st-sleep"] || el.hasAttribute("data-sleep");
    var showIsland = showSleep || !!hs["st-island"] || el.hasAttribute("data-sleep");
    var list = STATIONS.filter(function (s) { return (s[0] !== "st-sleep" || showSleep) && (s[0] !== "st-island" || showIsland); });
    var x = 4, items = [];
    list.forEach(function (s) { var w = s[3] === "tap" ? 30 : Math.max(58, s[1].length * 6.6 + 18); items.push([s, x, w]); x += w + 8; });
    el.innerHTML = "";
    var svg = svgEl("svg", { viewBox: "0 0 " + x + " 58", role: "img", "aria-label": "MJWarp pipeline: " + list.map(function (s) { return s[1]; }).join(", ") + (here ? ". This chapter: " + Object.keys(hs).join(", ") : "") }, el);
    svgEl("line", { x1: 4, y1: 22, x2: x - 8, y2: 22, "class": "belt" }, svg);
    items.forEach(function (it, idx) {
      var s = it[0], gx = it[1], w = it[2];
      var a = svgEl("a", { href: s[4] + ".html" }, svg);
      var g = svgEl("g", { "class": "station" + (s[3] === "tap" ? " tap" : "") + (s[3] === "ghost" ? " ghost" : "") + (hs[s[0]] ? " here" : ""), id: s[0].indexOf("st-") === 0 ? s[0] : null }, a);
      var tt = svgEl("title", {}, g); tt.textContent = s[1] + ": " + s[2];
      if (s[3] === "tap") {
        svgEl("circle", { cx: gx + w / 2, cy: 22, r: 6 }, g);
        var tx = svgEl("text", { x: gx + w / 2, y: 44, "text-anchor": "middle" }, g); tx.textContent = s[1];
      } else {
        svgEl("rect", { x: gx, y: 8, width: w, height: 28, rx: 7 }, g);
        var t = svgEl("text", { x: gx + w / 2, y: 26, "text-anchor": "middle" }, g); t.textContent = s[1];
        var nn = svgEl("text", { x: gx + w / 2, y: 52, "text-anchor": "middle", "class": "s-small" }, g); nn.textContent = String(idx + 1);
        nn.style.fontSize = "9px";
      }
    });
    var leg = doc.createElement("p"); leg.className = "bc-legend";
    leg.textContent = "Pipeline of mjw.step (forward.py::_forward). Highlighted: this chapter. Blue dots are sensor taps / the control callback. Click a station to open its chapter.";
    el.appendChild(leg);
    return svg;
  };
  /* sideways-scrolling frames must be reachable by keyboard (Safari/Firefox do not focus them by default) */
  function initScrollFrames() {
    $$(".fig-frame.scroll-x, .mw-breadcrumb").forEach(function (f) {
      if (f.hasAttribute("tabindex")) return;
      f.setAttribute("tabindex", "0");
      if (!f.getAttribute("role")) f.setAttribute("role", "region");
      if (!f.getAttribute("aria-label")) {
        var fig = f.closest("figure"), cap = fig && fig.querySelector("figcaption");
        var lbl = f.classList.contains("mw-breadcrumb") ? "Pipeline breadcrumb" : (cap ? cap.textContent.trim().replace(/\s+/g, " ").slice(0, 80) : "Figure");
        f.setAttribute("aria-label", lbl + " (scrolls sideways)");
      }
    });
  }
  function initBreadcrumbs() { $$(".mw-breadcrumb").forEach(function (b) { MW.breadcrumb(b, b.getAttribute("data-here")); }); }
  function initDeclarative() {
    $$(".pool-bar[data-naconmax]").forEach(function (el) {
      var draw = function () { MW.poolBar(el, { naconmax: +el.getAttribute("data-naconmax"), worlds: (el.getAttribute("data-worlds") || "").split(",").filter(Boolean).map(Number), overflow: +el.getAttribute("data-overflow") || 0 }); };
      draw(); MW.onTheme(draw);
    });
    $$(".efc-strip[data-njmax]").forEach(function (el) {
      var rows = []; try { rows = JSON.parse(el.getAttribute("data-rows")); } catch (e) { /* empty */ }
      MW.efcStrip(el, { njmax: +el.getAttribute("data-njmax"), rows: rows });
    });
    $$("[data-world-grid]").forEach(function (el) { if (!el._mwGrid) MW.worldGrid(el, +el.getAttribute("data-world-grid")); });
  }

  /* ---------- chapter completion (per-reader convenience) ---------- */
  function doneSet() { try { return JSON.parse(store("mwc-done") || "[]"); } catch (e) { return []; } }
  MW.doneSet = doneSet;
  function initComplete() {
    $$(".complete-btn[data-slug]").forEach(function (b) {
      var slug = b.getAttribute("data-slug");
      function sync() { var on = doneSet().indexOf(slug) >= 0; b.setAttribute("aria-pressed", on ? "true" : "false"); b.textContent = on ? "Completed ✓" : "Mark chapter as complete"; }
      b.type = "button";
      b.addEventListener("click", function () {
        var s = doneSet(), k = s.indexOf(slug);
        if (k >= 0) s.splice(k, 1); else s.push(slug);
        store("mwc-done", JSON.stringify(s)); sync();
      });
      sync();
    });
    var items = $$(".chapter-item[data-slug]");
    if (items.length) {
      var s = doneSet();
      items.forEach(function (it) { it.classList.toggle("is-done", s.indexOf(it.getAttribute("data-slug")) >= 0); });
      var bar = $(".course-progress > span"), txt = $(".course-progress-text");
      var n = items.filter(function (it) { return it.classList.contains("is-done"); }).length;
      if (bar) bar.style.width = (100 * n / items.length) + "%";
      if (txt) txt.textContent = n + " of " + items.length + " chapters completed";
    }
  }

  function boot() {
    initTheme(); initProgress(); initToc(); initAnchors(); highlight(); initCopy(); initMath(); initTabs();
    initQuiz(); initGlossary(); initHot(); initAnims(); initReveal(); initSteppers(); initBreadcrumbs();
    initDeclarative(); initReplays(); initComplete(); initScrollFrames();
    if (mq.addEventListener) mq.addEventListener("change", function () { MW.reducedMotion = mq.matches; });
    doc.dispatchEvent(new CustomEvent("mw:ready"));
    MW.ready = true;
  }
  // MW.onReady(fn): run chapter code after the shared components are initialised.
  MW.onReady = function (fn) { if (MW.ready) fn(); else doc.addEventListener("mw:ready", fn); };
  if (doc.readyState === "loading") doc.addEventListener("DOMContentLoaded", boot); else boot();
  // highlight.js / KaTeX may load after us; retry once on window load
  window.addEventListener("load", function () { highlight(); initMath(); });
})();
